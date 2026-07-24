// ToolRouter.swift – Tool Registration & Dispatch
// TheBridge · Server
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

// MARK: - Remote Control-Plane Predicate

public enum RemoteControlPlanePolicy {
    /// Tools whose local-only contract is unconditional. Unlike the broader
    /// broker hardening switch, these can never be invoked through a tunnel.
    public static let alwaysBlockedTools: Set<String> = [
        "connections_reset",
    ]

    public static let blockedModules: Set<String> = [
        "shell",
        "applescript",
        "computer",
        "credential",
    ]

    public static let controlWriteTools: Set<String> = [
        "standing_orders_save",
        "standing_orders_delete",
        "doctrine_sync",
        "commands_create",
        "commands_update",
        "commands_delete",
        "connections_reset",
    ]

    public static func isBlocked(tool: ToolRegistration) -> Bool {
        blockedModules.contains(tool.module) || controlWriteTools.contains(tool.name)
    }

    public static func isAlwaysBlocked(tool: ToolRegistration) -> Bool {
        alwaysBlockedTools.contains(tool.name)
    }

    public static func requiresGovernedSession(tool: ToolRegistration, effectiveTier: SecurityTier) -> Bool {
        tool.tier != .open || effectiveTier != .open
    }
}

public enum BrokerBootstrapToolOrdering {
    public static let priority: [String] = [
        "bridge_initialize",
        "bridge_status",
        "tools_list",
        "session_info",
    ]

    public static func prioritize(_ registrations: [ToolRegistration]) -> [ToolRegistration] {
        let rank = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($0.element, $0.offset) })
        return registrations.sorted { lhs, rhs in
            let lhsRank = rank[lhs.name] ?? Int.max
            let rhsRank = rank[rhs.name] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsKey = lhs.name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            let rhsKey = rhs.name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
    }
}

/// One actor-isolated view of the enabled tool registry. A revision changes
/// whenever registration changes, so callers can distinguish a real dynamic
/// surface update from ordering instability.
public struct ToolManifestSnapshot: Sendable {
    public let revision: UInt64
    public let registrations: [ToolRegistration]
}

private struct DispatchMissKey: Hashable {
    let session: String
    let safeToolName: String
}

private enum DispatchMissTelemetry {
    static let eventType = "dispatch_miss"
    static let windowSeconds: TimeInterval = 60

    static func safeToolName(_ raw: String) -> String {
        let lower = raw.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let secretMarkers = ["sk-", "sk_", "secret", "bearer", "token", "api_key", "apikey"]
        let looksSecret = secretMarkers.contains { lower.contains($0) }
        let bytes = Array(raw.utf8)
        let isIdentifier = !bytes.isEmpty
            && bytes.count <= 128
            && bytes[0].isASCIIAlpha
            && bytes.allSatisfy { $0.isASCIIAlphaNumeric || $0 == 95 }
        guard isIdentifier, !looksSecret else {
            return "<invalid-name:\(stableDigest(raw))>"
        }
        return raw
    }

    static func safeLabel(_ raw: String?, maxBytes: Int) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if ["secret", "bearer", "token", "api_key", "apikey", "sk-", "sk_"].contains(where: lower.contains) {
            return "<redacted>"
        }
        var result = ""
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 0x20, scalar.value != 0x7f else { continue }
            let next = String(scalar)
            guard result.utf8.count + next.utf8.count <= maxBytes else { break }
            result.append(next)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableDigest(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

private extension UInt8 {
    var isASCIIAlpha: Bool { (65...90).contains(self) || (97...122).contains(self) }
    var isASCIIAlphaNumeric: Bool { isASCIIAlpha || (48...57).contains(self) }
}

// PKT-373 P1-5: ExecutionPlanEntry removed (was dead code)

// MARK: - ToolRouter Actor

/// Central dispatch hub. Every tool call flows through here.
public actor ToolRouter {
    private var registry: [String: ToolRegistration] = [:]
    private var manifestRevision: UInt64 = 0
    /// FB-4: withhold `tools/list` until `BridgeModuleRegistry` finishes so
    /// clients never cache a partial surface during startup registration.
    private var modulesRegistrationComplete = false
    private var routingManifestSessionIDs: Set<String> = []
    private var dispatchMissWindows: [DispatchMissKey: Date] = [:]
    private let securityGate: SecurityGate
    private let auditLog: AuditLog
    private let sessionRegistry: SessionRegistry

    /// PKT-909 (Sell/Distribute v3 · 1) — license-gate seam. Production
    /// callers default to `LicenseManager.shared.currentStatus`; tests
    /// can inject a fixed status to drive the trial-expired gate
    /// without touching the shared singleton. Stored as an
    /// `@Sendable` async-returning closure so the actor can call it
    /// without crossing isolation boundaries.
    public typealias LicenseStatusProvider = @Sendable () async -> LicenseStatus
    private var licenseStatusProvider: LicenseStatusProvider

    public init(
        securityGate: SecurityGate,
        auditLog: AuditLog,
        sessionRegistry: SessionRegistry = .shared,
        licenseStatusProvider: @escaping LicenseStatusProvider = { await LicenseManager.shared.currentStatus() }
    ) {
        self.securityGate = securityGate
        self.auditLog = auditLog
        self.sessionRegistry = sessionRegistry
        self.licenseStatusProvider = licenseStatusProvider
    }

    /// Replace the license-status provider (test-only). Production
    /// dispatch never calls this; the default provider tracks the
    /// shared LicenseManager.
    public func setLicenseStatusProvider(_ p: @escaping LicenseStatusProvider) {
        self.licenseStatusProvider = p
    }

    // MARK: Registration

    /// Register a tool. Overwrites any existing registration with the same name.
    public func register(_ tool: ToolRegistration) {
        registry[tool.name] = tool
        manifestRevision &+= 1
    }

    /// Remove a tool registration by name.
    public func deregister(name: String) {
        if registry.removeValue(forKey: name) != nil {
            manifestRevision &+= 1
        }
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

    /// Mark module registration finished — `registrationsForListTools` stays empty until this runs.
    public func markModulesRegistrationComplete() {
        modulesRegistrationComplete = true
    }

    public func isModulesRegistrationComplete() -> Bool {
        modulesRegistrationComplete
    }

    /// Test/diagnostic seam for PKT-1094: a session is marked only after a
    /// successful bridge_initialize / fetch_skill / routing-skill manifest call.
    /// Marks may be transport session ids or verified principal keys.
    public func hasRoutingManifestMarker(sessionID: String) -> Bool {
        routingManifestSessionIDs.contains(sessionID)
    }

    public func markRoutingManifestFetched(sessionID: String) {
        routingManifestSessionIDs.insert(sessionID)
    }

    private func isGoverned(_ context: ToolDispatchContext) async -> Bool? {
        try? await sessionRegistry.isGoverned(
            transportSessionId: context.transportSessionId,
            principalKey: context.governancePrincipal
        )
    }

    private func hasRoutingManifestMarker(context: ToolDispatchContext) -> Bool {
        if let sessionID = context.transportSessionId,
           !sessionID.isEmpty,
           routingManifestSessionIDs.contains(sessionID) {
            return true
        }
        if let principal = context.governancePrincipal,
           routingManifestSessionIDs.contains(principal) {
            return true
        }
        return false
    }

    private func markRoutingManifestFetched(context: ToolDispatchContext) {
        if let sessionID = context.transportSessionId, !sessionID.isEmpty {
            routingManifestSessionIDs.insert(sessionID)
        }
        if let principal = context.governancePrincipal {
            routingManifestSessionIDs.insert(principal)
        }
    }

    /// Surface for MCP `tools/list` — empty until startup registration completes (FB-4).
    public func registrationsForListTools(disabledNames: Set<String>) -> [ToolRegistration] {
        toolManifestSnapshot(disabledNames: disabledNames).registrations
    }

    /// Atomic, revisioned source for every MCP `tools/list` transport.
    public func toolManifestSnapshot(disabledNames: Set<String>) -> ToolManifestSnapshot {
        guard modulesRegistrationComplete else {
            return ToolManifestSnapshot(revision: manifestRevision, registrations: [])
        }
        let registrations = BrokerBootstrapToolOrdering.prioritize(
            enabledRegistrations(disabledNames: disabledNames)
        )
        return ToolManifestSnapshot(revision: manifestRevision, registrations: registrations)
    }

    // MARK: Dispatch

    /// Dispatch a single tool call through the security -> execute -> audit pipeline.
    /// Returns the tool result or throws on rejection / handler error.
    /// For nuclear commands, returns a handoff response (not an error).
    public func dispatch(toolName: String, arguments: Value) async throws -> Value {
        try await dispatch(
            toolName: toolName,
            arguments: arguments,
            context: ToolDispatchContext.current ?? .localDefault
        )
    }

    public func dispatch(
        toolName: String,
        arguments: Value,
        context: ToolDispatchContext
    ) async throws -> Value {
        try await ToolDispatchContext.$current.withValue(context) {
            try await dispatchInner(toolName: toolName, arguments: arguments, context: context)
        }
    }

    private func dispatchInner(
        toolName: String,
        arguments: Value,
        context: ToolDispatchContext
    ) async throws -> Value {
        let start = ContinuousClock.now

        guard let tool = registry[toolName] else {
            let safeName = DispatchMissTelemetry.safeToolName(toolName)
            let session = context.transportSessionId ?? "<none>:\(context.origin.rawValue)"
            let key = DispatchMissKey(session: session, safeToolName: safeName)
            let now = Date()
            let shouldAudit: Bool
            if let windowStart = dispatchMissWindows[key],
               now.timeIntervalSince(windowStart) < DispatchMissTelemetry.windowSeconds {
                shouldAudit = false
            } else {
                dispatchMissWindows[key] = now
                shouldAudit = true
            }
            if dispatchMissWindows.count > 1_024 {
                dispatchMissWindows = dispatchMissWindows.filter {
                    now.timeIntervalSince($0.value) < DispatchMissTelemetry.windowSeconds
                }
            }
            if shouldAudit {
                await auditLog.append(AuditEntry(
                    timestamp: now,
                    toolName: safeName,
                    tier: .open,
                    inputSummary: "",
                    outputSummary: "ERROR: unknown tool",
                    durationMs: Self.elapsedMs(since: start),
                    approvalStatus: .error,
                    origin: context.origin,
                    transportSessionId: context.transportSessionId,
                    eventType: DispatchMissTelemetry.eventType,
                    reportedClientName: DispatchMissTelemetry.safeLabel(context.client, maxBytes: 128),
                    reportedClientVersion: DispatchMissTelemetry.safeLabel(context.clientVersion, maxBytes: 64)
                ))
            }
            throw ToolRouterError.unknownTool(toolName)
        }

        // PKT-909 — Sell/Distribute v3 · 1: trial-expired gate. Checked
        // BEFORE everything else (tier / module-gate / handler) so an
        // elapsed trial cannot be bypassed by any tool-specific code
        // path. The check is a sync snapshot read off the LicenseManager
        // actor; status is recomputed every time the actor mutates so
        // we never block dispatch on a slow disk roundtrip.
        let licenseStatus = await licenseStatusProvider()
        if !licenseStatus.isActive {
            let kind: String
            switch licenseStatus {
            case .licenseExpired: kind = "license-expired"
            default:              kind = "trial-expired"
            }
            // Audit-log the rejection so it surfaces in AI LOGS exactly
            // like the moduleGroupDisabled path.
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: \(kind)",
                durationMs: ms,
                approvalStatus: .rejected,
                transportSessionId: context.transportSessionId
            ))
            throw BridgeToolError.trialExpired(toolName: toolName, kind: kind)
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
                approvalStatus: .rejected,
                transportSessionId: context.transportSessionId
            ))
            throw BridgeToolError.moduleGroupDisabled(
                toolName: toolName,
                groupDisplayName: gate.groupID.displayName
            )
        }

        if tool.module == CredentialModule.moduleName && !CredentialsFeature.isEnabled {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "Credentials are disabled. Turn on “Keychain credentials” in The Bridge Settings → Credentials."
            )
        }

        if toolName == CalendarRegistryModule.toolName && !CalendarRegistryFeature.isEnabled {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "Calendar–Registry pairing is disabled. Set BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1 and an allowlist for a private smoke session only."
            )
        }

        // F1: Resolve effective tier — user override takes precedence over registered default.
        // Overrides are stored as [String: String] in UserDefaults by ToolRegistryView.
        //
        // fb-securitygate (point 2): resolution precedence is
        //   per-tool override  >  per-module override  >  registered default.
        // The per-module override is written when the user picks "Always Allow"
        // on a Request-tier tool, so the grant covers sibling tools in the same
        // module rather than only the one that was prompted.
        //
        // Calendar–Registry private-smoke hatch: with sync env + AUTO_APPROVE=1,
        // downgrade Request→Notify for the attended automation window only.
        let registeredTier: SecurityTier
        let neverAutoApprove: Bool
        if toolName == CalendarRegistryModule.toolName && CalendarRegistryFeature.autoApproveEnabled {
            registeredTier = .notify
            neverAutoApprove = false
        } else {
            registeredTier = tool.tier
            neverAutoApprove = tool.neverAutoApprove
        }
        let effectiveTier = ToolRouter.resolveEffectiveTier(
            toolName: toolName,
            module: tool.module,
            registeredTier: registeredTier,
            neverAutoApprove: neverAutoApprove
        )

        if context.origin == .remote,
           RemoteControlPlanePolicy.isAlwaysBlocked(tool: tool)
            || (BridgeDefaults.brokerRemoteControlPlaneBlockEnabled
                && RemoteControlPlanePolicy.isBlocked(tool: tool)) {
            let governed = await isGoverned(context)
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: control_plane_remote_blocked",
                durationMs: Self.elapsedMs(since: start),
                approvalStatus: .rejected,
                governed: governed,
                origin: context.origin,
                transportSessionId: context.transportSessionId,
                governanceNote: "control_plane_remote_blocked"
            ))
            return .object([
                "ok": .bool(false),
                "error": .string("control_plane_remote_blocked"),
                "tool": .string(toolName),
                "origin": .string(context.origin.rawValue),
                "message": .string("Remote tunnel callers cannot invoke this local control-plane tool.")
            ])
        }

        if context.origin == .remote,
           BridgeDefaults.brokerRemoteGovernedSessionRequiredEnabled,
           RemoteControlPlanePolicy.requiresGovernedSession(tool: tool, effectiveTier: effectiveTier) {
            let governed = await isGoverned(context)
            if governed != true {
                await auditLog.append(AuditEntry(
                    timestamp: Date(),
                    toolName: toolName,
                    tier: effectiveTier,
                    inputSummary: stringifySummary(arguments),
                    outputSummary: "REJECTED: ungoverned_remote_session",
                    durationMs: Self.elapsedMs(since: start),
                    approvalStatus: .rejected,
                    governed: governed,
                    origin: context.origin,
                    transportSessionId: context.transportSessionId,
                    governanceNote: "ungoverned_remote_session"
                ))
                return .object([
                    "ok": .bool(false),
                    "error": .string("ungoverned_remote_session"),
                    "tool": .string(toolName),
                    "origin": .string(context.origin.rawValue),
                    "message": .string("Remote callers must call bridge_initialize before invoking notify/request-tier tools.")
                ])
            }
        }

        // PKT-1094: per-tool routing manifest gate. Runs AFTER the broker's
        // origin-level gates above (control-plane block, governed-remote-session)
        // so a foundational "you're not initialized" rejection always takes
        // precedence over this finer-grained "you haven't fetched THIS tool's
        // governing skill route" one — calling bridge_initialize satisfies both
        // at once (it is itself a manifest-marker tool), so there is no case
        // where reordering costs a legitimate caller an extra round trip.
        // Remote OAuth principals share the marker across Mcp-Session-Id churn.
        // No correlatable identity (nil transport + nil principal) keeps the
        // legacy skip — same as the prior `if let sessionID` gate.
        let hasCorrelatableIdentity =
            (context.transportSessionId?.isEmpty == false)
            || (context.governancePrincipal != nil)
        if hasCorrelatableIdentity,
           ToolSkillBindingRegistry.requiresManifestFetch(toolName),
           !hasRoutingManifestMarker(context: context) {
            let binding = ToolSkillBindingRegistry.binding(for: toolName)
            let governance = binding?.governanceSummary ?? "unregistered"
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: routing manifest required (\(governance))",
                durationMs: ms,
                approvalStatus: .rejected,
                transportSessionId: context.transportSessionId
            ))
            throw ToolRouterError.routingManifestRequired(
                toolName: toolName,
                governingSkills: governance
            )
        }

        // SecurityGate enforcement (async for request-tier approvals)
        let decision = await securityGate.enforce(
            toolName: toolName,
            tier: effectiveTier,
            neverAutoApprove: neverAutoApprove,
            arguments: arguments,
            module: tool.module
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
                approvalStatus: .rejected,
                transportSessionId: context.transportSessionId
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
                approvalStatus: .escalated,
                transportSessionId: context.transportSessionId
            ))
            return .object([
                "status": .string("handoff"),
                "command": .string(command),
                "explanation": .string(explanation),
                "warning": .string(warning),
                "action_required": .string("Run this command manually in Terminal.app")
            ])
        }

        // Execute handler. A non-downgradable Request-tier approval mints a
        // server-issued receipt bound to the exact arguments and scopes it to
        // this handler invocation. Nested read-only dispatches inherit it; a
        // caller cannot manufacture it through MCP arguments.
        let exactApprovalReceipt: SecurityApprovalReceipt? =
            effectiveTier == .request && neverAutoApprove
            ? SecurityApprovalReceipt.issue(toolName: toolName, arguments: arguments, context: context)
            : nil
        do {
            let invokeHandler: @Sendable () async throws -> Value = {
                try await tool.handler(arguments)
            }
            let result: Value
            if let exactApprovalReceipt {
                result = try await SecurityApprovalReceipt.$current.withValue(
                    exactApprovalReceipt,
                    operation: invokeHandler
                )
            } else {
                result = try await invokeHandler()
            }
            let governed = await isGoverned(context)
            let governanceNote: String?
            let returnedResult: Value
            if Self.shouldAnnotateGovernance(
                toolName: toolName,
                context: context,
                governed: governed
            ) {
                governanceNote = "ungoverned_session"
                returnedResult = Self.annotatedResult(result)
            } else {
                governanceNote = nil
                returnedResult = result
            }

            if ToolSkillBindingRegistry.callSatisfiesManifestMarker(toolName: toolName, result: result) {
                markRoutingManifestFetched(context: context)
            }

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
                outputSummary: stringifySummary(returnedResult),
                durationMs: ms,
                approvalStatus: .approved,
                governed: governed,
                origin: context.origin,
                transportSessionId: context.transportSessionId,
                governanceNote: governanceNote
            ))
            return returnedResult
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
                approvalStatus: .error,
                transportSessionId: context.transportSessionId
            ))
            throw error
        }
    }

    // PKT-373 P1-5: batchGate removed (was dead code, never wired into dispatch pipeline)

    // MARK: fb-securitygate: Effective-Tier Resolution

    /// Resolve a tool's effective security tier from the registered default and
    /// the two override layers, with precedence:
    ///   per-tool override  >  per-module override  >  registered default.
    ///
    /// `neverAutoApprove` tools always resolve to `.request` — no override (tool
    /// or module) can lower a step-up-consent tool below an explicit prompt.
    ///
    /// Pure (reads UserDefaults snapshots passed in) so it is unit-testable
    /// without a live router or notification center.
    public static func resolveEffectiveTier(
        toolName: String,
        module: String,
        registeredTier: SecurityTier,
        neverAutoApprove: Bool,
        toolOverrides: [String: String]? = nil,
        moduleOverrides: [String: String]? = nil
    ) -> SecurityTier {
        if neverAutoApprove { return .request }

        let tools = toolOverrides ?? (UserDefaults.standard.dictionary(
            forKey: BridgeDefaults.tierOverrides
        ) as? [String: String] ?? [:])
        if let raw = tools[toolName], let t = SecurityTier(rawValue: raw) {
            return t
        }

        let modules = moduleOverrides ?? (UserDefaults.standard.dictionary(
            forKey: BridgeDefaults.moduleTierOverrides
        ) as? [String: String] ?? [:])
        if !module.isEmpty, let raw = modules[module], let t = SecurityTier(rawValue: raw) {
            return t
        }

        return registeredTier
    }

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
        await dispatchFormatted(
            toolName: toolName,
            arguments: arguments,
            context: ToolDispatchContext.current ?? .localDefault
        )
    }

    public func dispatchFormatted(
        toolName: String,
        arguments: Value,
        context: ToolDispatchContext
    ) async -> (text: String, isError: Bool) {
        do {
            let result = try await dispatch(toolName: toolName, arguments: arguments, context: context)
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
            let acceptedKeys: Set<String> = {
                guard let registration = registry[toolName],
                      case .object(let schema) = registration.inputSchema,
                      case .object(let properties)? = schema["properties"] else {
                    return []
                }
                return Set(properties.keys)
            }()
            if case .object(let argDict) = arguments,
               let hint = BridgeToolAliases.didYouMean(
                   providedKeys: Array(argDict.keys),
                   acceptedKeys: acceptedKeys
               ) {
                msg += " — \(hint)"
            }
            return (text: msg, isError: true)
        }
    }

    // MARK: Helpers

    private static func shouldAnnotateGovernance(
        toolName: String,
        context: ToolDispatchContext,
        governed: Bool?
    ) -> Bool {
        guard BridgeDefaults.brokerAdvisoryAnnotationEnabled else { return false }
        guard context.transportSessionId?.isEmpty == false else { return false }
        guard toolName != BridgeInitializeModule.toolName else { return false }
        return governed != true
    }

    private static func annotatedResult(_ result: Value) -> Value {
        let governance: Value = .object([
            "initialized": .bool(false),
            "note": .string("This transport session has not called bridge_initialize; result is advisory-only until initialized.")
        ])
        if case .object(var dict) = result {
            dict["governance"] = governance
            return .object(dict)
        }
        return .object([
            "result": result,
            "governance": governance
        ])
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
            + Double(duration.components.seconds) * 1000.0
    }

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
    case routingManifestRequired(toolName: String, governingSkills: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidArguments(let name, let reason):
            return "\(name): \(reason)"
        case .securityRejection(let name, let reason):
            return "Security gate rejected \(name): \(reason)"
        case .routingManifestRequired(let name, let governingSkills):
            return "\(name) requires a routing manifest before dispatch. Fetch the governing skill route first (\(governingSkills)) or run bridge_initialize for this session."
        }
    }
}
