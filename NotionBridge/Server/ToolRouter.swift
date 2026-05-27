// ToolRouter.swift – Tool Registration & Dispatch
// NotionBridge · Server
// PKT-376: Updated for 3-tier security model + .handoff support

import Foundation
import MCP

// MARK: - Tool Metadata (v3.0·0.5, PKT — agentic-usability)

/// Structured, agent-facing selection signals. Optional and additive — a
/// registration without metadata still works (renderer falls back to the
/// raw `description`). These fields do NOT reach the MCP wire as distinct
/// keys (the protocol carries only name/title/description/inputSchema/
/// annotations); `BridgeToolDescriptionRenderer` folds them deterministically
/// into the `description` string, and `title` populates the otherwise-unused
/// MCP `Tool.Annotations.title`.
public struct ToolMetadata: Sendable, Equatable, Hashable {
    /// Short human title (e.g. "Notion Page Read"). nil → derived from name.
    public let title: String?
    /// 1–N concise "use this when …" clauses.
    public let whenToUse: [String]
    /// 1–N "do not use for … (use X)" clauses — steers away from misuse.
    public let whenNotToUse: [String]
    /// Sibling tool names an agent commonly needs alongside / instead.
    public let relatedTools: [String]

    public init(
        title: String? = nil,
        whenToUse: [String] = [],
        whenNotToUse: [String] = [],
        relatedTools: [String] = []
    ) {
        self.title = title
        self.whenToUse = whenToUse
        self.whenNotToUse = whenNotToUse
        self.relatedTools = relatedTools
    }
}

// MARK: - Tool Registration

/// Metadata + handler for a single registered tool.
public struct ToolRegistration: Sendable {
    public let name: String
    public let module: String
    public let tier: SecurityTier
    public let neverAutoApprove: Bool
    public let description: String
    public let inputSchema: Value
    /// Optional structured selection signals (v3.0·0.5). Additive: nil for
    /// the existing 162 call sites; the renderer degrades to `description`.
    public let metadata: ToolMetadata?
    public let handler: @Sendable (Value) async throws -> Value

    public init(
        name: String,
        module: String,
        tier: SecurityTier,
        neverAutoApprove: Bool = false,
        description: String,
        inputSchema: Value,
        metadata: ToolMetadata? = nil,
        handler: @escaping @Sendable (Value) async throws -> Value
    ) {
        self.name = name
        self.module = module
        self.tier = tier
        self.neverAutoApprove = neverAutoApprove
        self.description = description
        self.inputSchema = inputSchema
        self.metadata = metadata
        self.handler = handler
    }
}

// PKT-373 P1-5: ExecutionPlanEntry removed (was dead code)

// MARK: - ToolRouter Actor

/// Central dispatch hub. Every tool call flows through here.
public actor ToolRouter {
    private var registry: [String: ToolRegistration] = [:]
    private let securityGate: SecurityGate
    private let auditLog: AuditLog
    public init(
        securityGate: SecurityGate,
        auditLog: AuditLog
    ) {
        self.securityGate = securityGate
        self.auditLog = auditLog
    }

    // MARK: Registration

    /// Register a tool. Overwrites any existing registration with the same name.
    public func register(_ tool: ToolRegistration) {
        registry[tool.name] = tool
    }

    /// Remove a tool registration by name.
    public func deregister(name: String) {
        registry.removeValue(forKey: name)
    }

    /// All currently registered tools.
    public func allRegistrations() -> [ToolRegistration] {
        Array(registry.values)
    }

    /// Registrations filtered by module name.
    public func registrations(forModule module: String) -> [ToolRegistration] {
        registry.values.filter { $0.module == module }
    }

    /// Enabled registrations excluding disabled tools (PKT-350: F2).
    public func enabledRegistrations(disabledNames: Set<String>) -> [ToolRegistration] {
        registry.values.filter { !disabledNames.contains($0.name) }
    }

    // MARK: Dispatch

    /// Dispatch a single tool call through the security -> execute -> audit pipeline.
    /// Returns the tool result or throws on rejection / handler error.
    /// For nuclear commands, returns a handoff response (not an error).
    public func dispatch(toolName: String, arguments: Value) async throws -> Value {
        let start = ContinuousClock.now

        guard let tool = registry[toolName] else {
            throw ToolRouterError.unknownTool(toolName)
        }

        // PKT-877 — SAFETY CONTRACT: fail closed when the tool's entire
        // ModuleGroup is currently disabled by the user. This is checked
        // BEFORE tier resolution / security gate / handler so disabling a
        // group cannot leak through any code path. The check is pure and
        // consumes the live registry — exactly the same source the UI
        // groups derive from — so dispatch state cannot drift from what
        // the user sees on the Tools page.
        let registeredNames = Array(registry.keys)
        let disabledNames = Set(
            UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? []
        )
        let gate = ModuleGroupGate.isToolGated(
            toolName: toolName,
            registeredToolNames: registeredNames,
            disabledNames: disabledNames
        )
        if gate.gated {
            // Audit-log the gated dispatch so the failure is observable in
            // AI LOGS, then throw the structured error. We use `.rejected`
            // (parity with SecurityGate.reject) to keep the audit schema
            // consistent.
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: module group '\(gate.groupID.displayName)' disabled",
                durationMs: ms,
                approvalStatus: .rejected
            ))
            throw BridgeToolError.moduleGroupDisabled(
                toolName: toolName,
                groupDisplayName: gate.groupID.displayName
            )
        }

        if tool.module == CredentialModule.moduleName && !CredentialsFeature.isEnabled {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "Credentials are disabled. Turn on “Keychain credentials” in Notion Bridge Settings → Credentials."
            )
        }

        // F1: Resolve effective tier — user override takes precedence over registered default.
        // Overrides are stored as [String: String] in UserDefaults by ToolRegistryView.
        let overrides = UserDefaults.standard.dictionary(
            forKey: BridgeDefaults.tierOverrides
        ) as? [String: String] ?? [:]
        let overriddenTier = overrides[toolName].flatMap { SecurityTier(rawValue: $0) } ?? tool.tier
        let effectiveTier: SecurityTier = tool.neverAutoApprove ? .request : overriddenTier

        // SecurityGate enforcement (async for request-tier approvals)
        let decision = await securityGate.enforce(
            toolName: toolName,
            tier: effectiveTier,
            neverAutoApprove: tool.neverAutoApprove,
            arguments: arguments
        )

        switch decision {
        case .allow:
            break // proceed to execution

        case .reject(let reason):
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: \(reason)",
                durationMs: ms,
                approvalStatus: .rejected
            ))
            throw ToolRouterError.securityRejection(toolName: toolName, reason: reason)

        case .handoff(let command, let explanation, let warning):
            // Nuclear handoff: return a helpful response, NOT an error
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "HANDOFF: \(command)",
                durationMs: ms,
                approvalStatus: .escalated
            ))
            return .object([
                "status": .string("handoff"),
                "command": .string(command),
                "explanation": .string(explanation),
                "warning": .string(warning),
                "action_required": .string("Run this command manually in Terminal.app")
            ])
        }

        // Execute handler
        do {
            let result = try await tool.handler(arguments)

            // F2 + PKT-552: Fire-and-forget Notify-tier notification with structured context.
            // Runs after successful execution — informational only.
            if effectiveTier == .notify {
                let context = ToolRouter.makeExecutionContext(
                    toolName: toolName,
                    arguments: arguments,
                    summary: stringifySummary(arguments)
                )
                await securityGate.sendExecutionNotification(context: context)
            }

            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: stringifySummary(result),
                durationMs: ms,
                approvalStatus: .approved
            ))
            return result
        } catch {
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "ERROR: \(error.localizedDescription)",
                durationMs: ms,
                approvalStatus: .error
            ))
            throw error
        }
    }

    // PKT-373 P1-5: batchGate removed (was dead code, never wired into dispatch pipeline)

    // MARK: PKT-552: Notify-tier Deep Link Construction

    /// Known Notion tool names (from NotionModule). Tools in this set with a
    /// `pageId` or `blockId` argument receive a `notion.so` deep link in their
    /// execution notification context.
    private static let notionToolNames: Set<String> = [
        "notion_page_read", "notion_page_create", "notion_page_update", "notion_page_move",
        "notion_page_markdown_read", "notion_blocks_append", "notion_block_read",
        "notion_block_update", "notion_block_delete", "notion_database_get",
        "notion_datasource_get", "notion_datasource_create", "notion_datasource_update",
        "notion_query", "notion_search", "notion_comments_list", "notion_comment_create",
        "notion_users_list", "notion_file_upload", "notion_connections_list",
        "notion_token_introspect",
        // v1.9.1 E5 + E3:
        "notion_discussion_create", "notion_code_block_append"
    ]

    private static func dehyphenate(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "")
    }

    /// Build the execution notification context for a tool call. For Notion tools
    /// with a pageId/blockId argument, constructs `https://notion.so/{id}` (with
    /// `#{blockId}` fragment when applicable) for the Open Page deep-link action.
    static func makeExecutionContext(
        toolName: String,
        arguments: Value,
        summary: String
    ) -> ExecutionNotificationContext {
        var pageURL: String? = nil
        var blockURL: String? = nil

        if notionToolNames.contains(toolName), case .object(let dict) = arguments {
            var pageId: String? = nil
            if case .string(let s) = dict["pageId"], !s.isEmpty { pageId = s }
            var blockId: String? = nil
            if case .string(let s) = dict["blockId"], !s.isEmpty { blockId = s }

            if let pid = pageId {
                let dehy = dehyphenate(pid)
                pageURL = "https://notion.so/\(dehy)"
                if let bid = blockId {
                    blockURL = "https://notion.so/\(dehy)#\(dehyphenate(bid))"
                }
            } else if let bid = blockId {
                // No pageId in args — use blockId as the page identifier best-effort.
                let dehy = dehyphenate(bid)
                pageURL = "https://notion.so/\(dehy)"
            }
        }

        return ExecutionNotificationContext(
            toolName: toolName,
            argumentsSummary: summary,
            notionPageURL: pageURL,
            notionBlockURL: blockURL,
            riskLevel: "low"
        )
    }

        // MARK: CallTool Dispatch Helper

    /// Dispatch a tool call and format the result as a CallTool-compatible tuple.
    /// Centralizes the dispatch → JSON encode → text conversion pipeline
    /// used by ServerManager (stdio), SSEServer (Streamable HTTP), and legacy RPC.
    /// Returns: (text: String, isError: Bool)
    public func dispatchFormatted(toolName: String, arguments: Value) async -> (text: String, isError: Bool) {
        do {
            let result = try await dispatch(toolName: toolName, arguments: arguments)
            let text: String
            switch result {
            case .string(let s):
                text = s
            default:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(result),
                   let json = String(data: data, encoding: .utf8) {
                    text = json
                } else {
                    text = String(describing: result)
                }
            }
            let structuredFailure: Bool = {
                if case .object(let dict) = result {
                    if case .bool(let success) = dict["success"], success == false { return true }
                    if case .string(let status) = dict["status"], ["failed", "error", "partial_or_unverified"].contains(status) { return true }
                    if case .string = dict["error"] { return true }
                }
                return false
            }()
            return (text: text, isError: structuredFailure)
        } catch {
            // v3.0·0.5: central param-misnomer recovery. If the agent sent
            // a known wrong key, append a did-you-mean so it self-corrects
            // without reading source. Applies to all 162 tools at once.
            var msg = "Error: \(error.localizedDescription)"
            if case .object(let argDict) = arguments,
               let hint = BridgeToolAliases.didYouMean(providedKeys: Array(argDict.keys)) {
                msg += " — \(hint)"
            }
            return (text: msg, isError: true)
        }
    }

    // MARK: Helpers

    private func stringifySummary(_ value: Value) -> String {
        switch value {
        case .string(let s):
            return s.count > 200 ? String(s.prefix(200)) + "..." : s
        case .object(let dict):
            let keys = dict.keys.sorted().joined(separator: ", ")
            return "{\(keys)}"
        case .array(let arr):
            return "[\(arr.count) items]"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return String(b)
        case .null:
            return "null"
        case .data:
            return "<binary data>"
        }
    }
}

// MARK: - Errors

public enum ToolRouterError: Error, LocalizedError {
    case unknownTool(String)
    case invalidArguments(toolName: String, reason: String)
    case securityRejection(toolName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidArguments(let name, let reason):
            return "\(name): \(reason)"
        case .securityRejection(let name, let reason):
            return "Security gate rejected \(name): \(reason)"
        }
    }
}
