// SessionModule.swift – V1-04 Session Tools (complete)
// TheBridge · Modules

import Foundation
import MCP

// MARK: - SessionModule

/// Provides session tools: tools_list, tools_search, session_info, audit_recent, session_clear.
public enum SessionModule {

    public static let auditRecentDefaultLimit = 20
    public static let auditRecentMaximumLimit = 100
    public static let toolSearchDefaultLimit = 8
    public static let toolSearchMaximumLimit = 25

    public struct RuntimeDiagnostics: Sendable {
        public let connections: Int
        public let activeClients: Int

        public init(connections: Int, activeClients: Int) {
            self.connections = connections
            self.activeClients = activeClients
        }
    }

    public static let moduleName = "session"

    /// Register all session module tools on the given router.
    /// V1-04: now accepts auditLog for session_info and session_clear.
    public static func register(
        on router: ToolRouter,
        auditLog: AuditLog,
        diagnosticsProvider: (@Sendable () async -> RuntimeDiagnostics)? = nil
    ) async {
        // Captured HERE (register() runs once, at server boot) rather than as a
        // lazily-initialized `static let` referenced only inside the handler
        // closures below — a lazy static's first-access moment is whenever a
        // client first calls session_info/session_clear, not process launch,
        // so uptime silently measured "time since first call" instead of
        // "time since boot".
        let sessionStartTime = Date()

        // tools_list – open (V1-03, preserved)
        await router.register(ToolRegistration(
            name: "tools_list",
            module: moduleName,
            tier: .open,
            description: "List registered MCP tools. COMPACT by default (name, module, tier, one-line summary) to stay well under client output-token caps. Pass module to scope to one family, or detail:true for rendered descriptions and exact exposed input schemas. Use tools_search to find one tool or retrieve its schema without listing the full catalog.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "module": .object([
                        "type": .string("string"),
                        "description": .string("Optional module name to filter by. If omitted, returns all tools. Scoping to a module implies detail:true.")
                    ]),
                    "detail": .object([
                        "type": .string("boolean"),
                        "description": .string("When true (or when `module` is set) each entry carries full description, input schema, tier, and output. Default false returns a compact summary so the full catalog stays under the ~25k MCP output cap.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let moduleFilter: String?
                var wantDetail = false
                if case .object(let args) = arguments {
                    if case .string(let m) = args["module"] { moduleFilter = m } else { moduleFilter = nil }
                    if case .bool(let d) = args["detail"] { wantDetail = d }
                } else {
                    moduleFilter = nil
                }
                // Scoping to a single module implies the caller wants full detail.
                let fullDetail = wantDetail || (moduleFilter != nil)

                let registrations: [ToolRegistration]
                if let filter = moduleFilter {
                    registrations = BrokerBootstrapToolOrdering.prioritize(
                        await router.registrations(forModule: filter)
                    )
                } else {
                    registrations = BrokerBootstrapToolOrdering.prioritize(
                        await router.allRegistrations()
                    )
                }

                return .array(registrations.map {
                    fullDetail ? toolDetailValue($0) : compactToolValue($0)
                })
            }
        ))

        // tools_search — open. Native MCP hosts commonly defer schemas until a
        // model asks for one tool by name; this gives Bridge clients the same
        // bounded, deterministic discovery path without requiring a full
        // tools_list payload.
        await router.register(ToolRegistration(
            name: "tools_search",
            module: moduleName,
            tier: .open,
            description: "Find registered Bridge tools by name, module, description, or selection metadata without listing the entire catalog. Pass select:<tool_name> in query, or select directly, to retrieve one exact tool's rendered description and complete exposed input schema.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search terms, or select:<tool_name> for an exact schema lookup. Required unless select is supplied.")
                    ]),
                    "select": .object([
                        "type": .string("string"),
                        "description": .string("Exact tool name to retrieve. Case-insensitive; takes precedence over query.")
                    ]),
                    "module": .object([
                        "type": .string("string"),
                        "description": .string("Optional exact module-family filter, matched case-insensitively.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum search matches to return (default 8, range 1...25). Ignored for an exact selection.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Find a Bridge Tool",
                whenToUse: [
                    "You know a capability or tool name but need the exact registered tool.",
                    "You need one tool's schema without expanding the full catalog."
                ],
                whenNotToUse: [
                    "You already know the exact tool and its arguments.",
                    "You need a complete module inventory (use tools_list with module)."
                ],
                relatedTools: ["tools_list", "session_info"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    return toolSearchArgumentError("arguments must be an object")
                }

                let moduleFilter: String?
                if let value = args["module"] {
                    guard case .string(let module) = value else {
                        return toolSearchArgumentError("module must be a string")
                    }
                    let trimmed = module.trimmingCharacters(in: .whitespacesAndNewlines)
                    moduleFilter = trimmed.isEmpty ? nil : trimmed
                } else {
                    moduleFilter = nil
                }

                let explicitSelect: String?
                if let value = args["select"] {
                    guard case .string(let select) = value else {
                        return toolSearchArgumentError("select must be a string")
                    }
                    let trimmed = select.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return toolSearchArgumentError("select must not be empty")
                    }
                    explicitSelect = trimmed
                } else {
                    explicitSelect = nil
                }

                let rawQuery: String?
                if let value = args["query"] {
                    guard case .string(let query) = value else {
                        return toolSearchArgumentError("query must be a string")
                    }
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    rawQuery = trimmed.isEmpty ? nil : trimmed
                } else {
                    rawQuery = nil
                }

                let limit: Int
                if let value = args["limit"] {
                    guard case .int(let requested) = value else {
                        return toolSearchArgumentError("limit must be an integer")
                    }
                    limit = max(1, min(requested, toolSearchMaximumLimit))
                } else {
                    limit = toolSearchDefaultLimit
                }

                let registrations = BrokerBootstrapToolOrdering.prioritize(
                    await router.allRegistrations()
                ).filter { registration in
                    guard let moduleFilter else { return true }
                    return normalizedSearchText(registration.module) == normalizedSearchText(moduleFilter)
                }

                let prefixedSelect = rawQuery.flatMap { selectTarget(from: $0) }
                if let target = explicitSelect ?? prefixedSelect {
                    if let registration = registrations.first(where: {
                        normalizedSearchText($0.name) == normalizedSearchText(target)
                    }) {
                        return .object([
                            "mode": .string("select"),
                            "catalog": .string("registered"),
                            "found": .bool(true),
                            "select": .string(registration.name),
                            "tool": toolDetailValue(registration)
                        ])
                    }

                    let suggestions = searchMatches(
                        registrations: registrations,
                        query: target,
                        limit: min(5, toolSearchMaximumLimit)
                    ).map { match in
                        searchResultValue(match)
                    }
                    return .object([
                        "mode": .string("select"),
                        "catalog": .string("registered"),
                        "found": .bool(false),
                        "select": .string(target),
                        "message": .string("No registered tool named '\(target)'."),
                        "suggestions": .array(suggestions)
                    ])
                }

                guard let query = rawQuery else {
                    return toolSearchArgumentError("provide a non-empty query or select")
                }

                let matches = searchMatches(
                    registrations: registrations,
                    query: query,
                    limit: limit
                )
                return .object([
                    "mode": .string("search"),
                    "catalog": .string("registered"),
                    "query": .string(query),
                    "module": moduleFilter.map(Value.string) ?? .null,
                    "count": .int(matches.count),
                    "limit": .int(limit),
                    "matches": .array(matches.map { searchResultValue($0) })
                ])
            }
        ))

        // session_info – open (V1-04; PKT-1065B: explicit field scopes)
        await router.register(ToolRegistration(
            name: "session_info",
            module: moduleName,
            tier: .open,
            description: "Return this bridge PROCESS's diagnostics. IMPORTANT — scopes differ per field: "
                + "`uptimeSeconds` is the whole bridge process's uptime (not a per-caller session). "
                + "`connections`/`activeClients` count ONLY live HTTP (/mcp) + legacy SSE network sessions; "
                + "a stdio-attached client (e.g. this local MCP connection) is NOT counted, so 0 clients is "
                + "expected and normal when the only caller is on stdio — it does NOT contradict bridge_status. "
                + "`toolCalls`/`auditLogSize` are the audit-log entry count accumulated since process start (or "
                + "the last session_clear). This tool describes the LOCAL bridge process; `bridge_status` "
                + "describes the CLOUD tunnel channel — the two are orthogonal. See the `scopes` field in the "
                + "response for the authoritative per-field definitions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let uptime = max(0, Date().timeIntervalSince(sessionStartTime))
                let auditSize = await auditLog.count()
                // No diagnostics provider (e.g. stdio-only assembly / unit tests) means
                // there is no HTTP/SSE server to enumerate network sessions — report 0,
                // NOT a fabricated 1. The `scopes` field explains why 0 is correct.
                let diagnostics = await diagnosticsProvider?() ?? RuntimeDiagnostics(connections: 0, activeClients: 0)
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let seconds = Int(uptime) % 60
                let uptimeStr = String(format: "%dh %dm %ds", hours, minutes, seconds)

                return .object([
                    "uptime": .string(uptimeStr),
                    "uptimeSeconds": .double(uptime),
                    "connections": .int(diagnostics.connections),
                    "toolCalls": .int(auditSize),
                    "activeClients": .int(diagnostics.activeClients),
                    "auditLogSize": .int(auditSize),
                    // Explicit per-field scope so a caller never has to guess why, e.g.,
                    // activeClients is 0 while bridge_status reports the tunnel online.
                    "scopes": .object([
                        "uptimeSeconds": .string("Whole bridge PROCESS uptime in seconds (not a per-caller session)."),
                        "uptime": .string("Same as uptimeSeconds, formatted as 'Hh Mm Ss'."),
                        "connections": .string("Count of live HTTP (/mcp) + legacy SSE network sessions. Excludes stdio callers."),
                        "activeClients": .string("Same population as `connections`: HTTP + legacy SSE sessions only. A stdio-attached caller is NOT counted, so 0 is normal and does not conflict with bridge_status."),
                        "toolCalls": .string("Audit-log entry count since process start or last session_clear. Equal to auditLogSize."),
                        "auditLogSize": .string("Number of audit-log entries retained for this process (since start or last session_clear)."),
                        "note": .string("session_info describes the LOCAL bridge process; bridge_status describes the CLOUD tunnel channel. They are independent — neither implies the other.")
                    ])
                ])
            }
        ))

        // audit_recent — open (PKT-1116). Read-only projection of the
        // already-retained in-memory audit trail. Deliberately omits
        // `inputSummary`: agents need the refusal/result trail, not a replay of
        // caller-supplied material. Credential-tool output summaries are also
        // redacted defensively even though ToolRouter normally stores only an
        // object-key summary.
        await router.register(ToolRegistration(
            name: "audit_recent",
            module: moduleName,
            tier: .open,
            description: "Return the most-recent in-memory audit entries so an agent can diagnose why a tool call was approved, rejected, escalated, or failed. Filter by exact tool name, approval status, or security tier. Input summaries are never returned; credential-tool output summaries are redacted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum entries to return (default 20, range 1...100).")
                    ]),
                    "tool": .object([
                        "type": .string("string"),
                        "description": .string("Optional exact tool-name filter.")
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(ApprovalStatus.allCases.map { .string($0.rawValue) }),
                        "description": .string("Optional approval status: approved | rejected | escalated | error.")
                    ]),
                    "tier": .object([
                        "type": .string("string"),
                        "enum": .array(SecurityTier.allCases.map { .string($0.rawValue) }),
                        "description": .string("Optional security tier: open | notify | request.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Recent Audit Trail",
                whenToUse: ["Diagnose why a recent Bridge tool call was blocked, escalated, or failed."],
                whenNotToUse: ["Clearing audit history (use session_clear with explicit confirmation)."],
                relatedTools: ["session_info", "session_clear"]
            ),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let object) = arguments { args = object } else { args = [:] }

                let limit: Int = {
                    guard case .int(let requested) = args["limit"] else {
                        return auditRecentDefaultLimit
                    }
                    return max(1, min(requested, auditRecentMaximumLimit))
                }()
                let toolFilter: String? = {
                    guard case .string(let value) = args["tool"], !value.isEmpty else { return nil }
                    return value
                }()
                let statusFilter: ApprovalStatus?
                if case .string(let raw) = args["status"] {
                    guard let parsed = ApprovalStatus(rawValue: raw) else {
                        return .object(["error": .string("Invalid status '\(raw)'. Expected approved, rejected, escalated, or error.")])
                    }
                    statusFilter = parsed
                } else {
                    statusFilter = nil
                }
                let tierFilter: SecurityTier?
                if case .string(let raw) = args["tier"] {
                    guard let parsed = SecurityTier(rawValue: raw) else {
                        return .object(["error": .string("Invalid tier '\(raw)'. Expected open, notify, or request.")])
                    }
                    tierFilter = parsed
                } else {
                    tierFilter = nil
                }

                // Use AuditLog's indexed read seams for the first available
                // filter, then compose any remaining predicates locally.
                var entries: [AuditEntry]
                if let toolFilter {
                    entries = await auditLog.entries(forTool: toolFilter)
                } else if let statusFilter {
                    entries = await auditLog.entries(withStatus: statusFilter)
                } else if let tierFilter {
                    entries = await auditLog.entries(forTier: tierFilter)
                } else {
                    entries = await auditLog.allEntries()
                }
                if let toolFilter { entries.removeAll { $0.toolName != toolFilter } }
                if let statusFilter { entries.removeAll { $0.approvalStatus != statusFilter } }
                if let tierFilter { entries.removeAll { $0.tier != tierFilter } }

                let recent = entries
                    .sorted { $0.timestamp > $1.timestamp }
                    .prefix(limit)
                    .map(auditEntryValue)
                return .object([
                    "entries": .array(Array(recent)),
                    "count": .int(recent.count),
                    "limit": .int(limit),
                    "inputSummaryIncluded": .bool(false)
                ])
            }
        ))

        // session_clear – notify (V1-04)
        await router.register(ToolRegistration(
            name: "session_clear",
            module: moduleName,
            tier: .notify,
            description: "Clear this session's audit log. Requires confirm: true. Irreversible for the current session only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "confirm": .object([
                        "type": .string("boolean"),
                        "description": .string("Must be true to confirm session clear")
                    ])
                ]),
                "required": .array([.string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .bool(let confirm) = args["confirm"],
                      confirm else {
                    return .object([
                        "error": .string("session_clear requires confirm: true"),
                        "cleared": .bool(false)
                    ])
                }

                let previousUptime = max(0, Date().timeIntervalSince(sessionStartTime))
                let previousAuditSize = await auditLog.count()
                await auditLog.clear()

                return .object([
                    "cleared": .bool(true),
                    "previousUptimeSeconds": .double(previousUptime),
                    "previousAuditLogSize": .int(previousAuditSize)
                ])
            }
        ))
    }

    // MARK: Tool discovery projections

    private struct ToolSearchMatch {
        let registration: ToolRegistration
        let score: Int
        let reasons: [String]
    }

    private static func compactToolValue(_ registration: ToolRegistration) -> Value {
        .object([
            "name": .string(registration.name),
            "module": .string(registration.module),
            "tier": .string(registration.tier.rawValue),
            "summary": .string(summarizeToolDescription(registration))
        ])
    }

    /// Mirrors the fields an MCP client receives for one registration rather
    /// than returning the raw source schema. In particular, this includes
    /// routed-skill receipt inputs added by MCPToolFactory.
    private static func toolDetailValue(_ registration: ToolRegistration) -> Value {
        let inputSchema = MCPToolFactory.inputSchema(for: registration)
        let inputs: Value
        if case .object(let schema) = inputSchema,
           case .object(let properties) = schema["properties"] {
            let required: Set<String>
            if case .array(let values) = schema["required"] {
                required = Set(values.compactMap {
                    if case .string(let name) = $0 { return name }
                    return nil
                })
            } else {
                required = []
            }
            inputs = .array(properties.keys.sorted().map { name in
                let property = properties[name] ?? .null
                let type: String
                if case .object(let object) = property,
                   case .string(let value) = object["type"] {
                    type = value
                } else {
                    type = "unknown"
                }
                return .object([
                    "name": .string(name),
                    "type": .string(type),
                    "required": .bool(required.contains(name))
                ])
            })
        } else {
            inputs = .array([])
        }

        var result: [String: Value] = [
            "name": .string(registration.name),
            "title": .string(BridgeToolDescriptionRenderer.title(registration)),
            "module": .string(registration.module),
            "tier": .string(registration.tier.rawValue),
            "description": .string(BridgeToolDescriptionRenderer.render(registration)),
            "inputs": inputs,
            "inputSchema": inputSchema,
            "output": .string("Value")
        ]
        if let metadata = registration.metadata {
            result["selection"] = .object([
                "whenToUse": .array(metadata.whenToUse.map(Value.string)),
                "whenNotToUse": .array(metadata.whenNotToUse.map(Value.string)),
                "relatedTools": .array(metadata.relatedTools.map(Value.string))
            ])
        }
        return .object(result)
    }

    private static func searchResultValue(_ match: ToolSearchMatch) -> Value {
        var fields: [String: Value] = [
            "name": .string(match.registration.name),
            "title": .string(BridgeToolDescriptionRenderer.title(match.registration)),
            "module": .string(match.registration.module),
            "tier": .string(match.registration.tier.rawValue),
            "summary": .string(summarizeToolDescription(match.registration)),
            "matchReasons": .array(match.reasons.map(Value.string))
        ]
        if let relatedTools = match.registration.metadata?.relatedTools,
           !relatedTools.isEmpty {
            fields["relatedTools"] = .array(relatedTools.map(Value.string))
        }
        return .object(fields)
    }

    private static func toolSearchArgumentError(_ message: String) -> Value {
        .object([
            "status": .string("error"),
            "error": .string("tools_search: \(message)")
        ])
    }

    private static func selectTarget(from query: String) -> String? {
        let prefix = "select:"
        let normalized = normalizedSearchText(query)
        guard normalized.hasPrefix(prefix) else { return nil }
        let target = String(query.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    private static func searchMatches(
        registrations: [ToolRegistration],
        query: String,
        limit: Int
    ) -> [ToolSearchMatch] {
        let normalizedQuery = normalizedSearchText(query)
        let tokens = searchTokens(query)
        guard !normalizedQuery.isEmpty, !tokens.isEmpty else { return [] }

        return registrations.compactMap { registration in
            searchMatch(
                registration: registration,
                normalizedQuery: normalizedQuery,
                tokens: tokens
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsName = normalizedSearchText(lhs.registration.name)
            let rhsName = normalizedSearchText(rhs.registration.name)
            if lhsName != rhsName { return lhsName < rhsName }
            return lhs.registration.name.utf8.lexicographicallyPrecedes(rhs.registration.name.utf8)
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func searchMatch(
        registration: ToolRegistration,
        normalizedQuery: String,
        tokens: [String]
    ) -> ToolSearchMatch? {
        let name = normalizedSearchText(registration.name)
        let module = normalizedSearchText(registration.module)
        let title = normalizedSearchText(BridgeToolDescriptionRenderer.title(registration))
        let description = normalizedSearchText(BridgeToolDescriptionRenderer.render(registration))
        let metadata = registration.metadata.map {
            normalizedSearchText(
                ($0.whenToUse + $0.whenNotToUse + $0.relatedTools)
                    .joined(separator: " ")
            )
        } ?? ""

        var score = 0
        var reasons: [String] = []
        func record(_ reason: String, _ points: Int) {
            score += points
            if !reasons.contains(reason) { reasons.append(reason) }
        }

        if name == normalizedQuery {
            record("exact_name", 10_000)
        } else if name.hasPrefix(normalizedQuery) {
            record("name_prefix", 4_000)
        } else if name.contains(normalizedQuery) {
            record("name_contains", 2_500)
        }
        if module == normalizedQuery {
            record("exact_module", 1_500)
        }
        if title.contains(normalizedQuery) {
            record("title_match", 800)
        }
        if description.contains(normalizedQuery) {
            record("description_match", 400)
        }
        if metadata.contains(normalizedQuery) {
            record("selection_metadata_match", 300)
        }

        for token in tokens {
            var matched = false
            if name.contains(token) {
                record("name_match", 160)
                matched = true
            }
            if module.contains(token) {
                record("module_match", 80)
                matched = true
            }
            if title.contains(token) {
                record("title_match", 45)
                matched = true
            }
            if description.contains(token) {
                record("description_match", 20)
                matched = true
            }
            if metadata.contains(token) {
                record("selection_metadata_match", 15)
                matched = true
            }
            guard matched else { return nil }
        }

        return ToolSearchMatch(registration: registration, score: score, reasons: reasons)
    }

    private static func summarizeToolDescription(_ registration: ToolRegistration) -> String {
        let rendered = BridgeToolDescriptionRenderer.render(registration)
        let oneLine = rendered
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
        return oneLine.count <= 100 ? oneLine : String(oneLine.prefix(99)) + "…"
    }

    private static func searchTokens(_ value: String) -> [String] {
        var seen: Set<String> = []
        return normalizedSearchText(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Public pure projection for secrecy/shape tests. `inputSummary` and
    /// `governanceNote` are intentionally absent from the wire response.
    public static func auditEntryValue(_ entry: AuditEntry) -> Value {
        let outputSummary = entry.toolName.hasPrefix("credential_")
            ? "<redacted: credential tool>"
            : entry.outputSummary
        return .object([
            "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
            "toolName": .string(entry.toolName),
            "tier": .string(entry.tier.rawValue),
            "approvalStatus": .string(entry.approvalStatus.rawValue),
            "outputSummary": .string(outputSummary),
            "durationMs": .double(entry.durationMs),
            "origin": entry.origin.map { .string($0.rawValue) } ?? .null,
            "transportSessionId": entry.transportSessionId.map(Value.string) ?? .null,
            "eventType": entry.eventType.map(Value.string) ?? .null,
            "reportedClientName": entry.reportedClientName.map(Value.string) ?? .null,
            "reportedClientVersion": entry.reportedClientVersion.map(Value.string) ?? .null
        ])
    }
}
