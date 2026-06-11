// SecurityGate.swift – PKT-376: Security Model v3
// NotionBridge · Security
// 3-tier model:
// - Open: execute immediately
// - Notify: execute immediately + fire-and-forget notification
// - Request: actionable pre-execution approval (Allow / Deny / Always Allow)
//   - Safe commands (read-only): auto-allow for shell/cli tools
//   - Always Allow (notifications): persists tier override to Notify (not learned prefixes).
//   - `neverAutoApprove` tools: no Always Allow action (use Tool Registry).
//   - Alert fallback: Allow/Deny only — tier change via Tool Registry.
// - Sensitive path: Allow = session; Always Allow = permanent path allow (no tier override).
// - Nuclear handoff for fork bomb patterns only

import Foundation
import UserNotifications
import MCP

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Execution Notification Context (PKT-552)

/// Structured context for Notify-tier fire-and-forget notifications.
/// Populated by ToolRouter from tool arguments; consumed by NotificationApprovalManager
/// to populate notification `userInfo` (contract with PKT-553 Content Extension).
public struct ExecutionNotificationContext: Sendable {
    public let toolName: String
    public let argumentsSummary: String
    public let notionPageURL: String?
    public let notionBlockURL: String?
    public let riskLevel: String

    public init(
        toolName: String,
        argumentsSummary: String = "",
        notionPageURL: String? = nil,
        notionBlockURL: String? = nil,
        riskLevel: String = "low"
    ) {
        self.toolName = toolName
        self.argumentsSummary = argumentsSummary
        self.notionPageURL = notionPageURL
        self.notionBlockURL = notionBlockURL
        self.riskLevel = riskLevel
    }
}

// MARK: - Security Tier (v3: 3-tier model)

/// Three security tiers replacing the previous 2-tier system.
///
/// - `open`: Execute immediately. No user interaction. Used for read-only operations.
/// - `notify`: Execute immediately and send fire-and-forget notification after execution.
/// - `request`: Request explicit approval before execution.
///
/// Nuclear pattern enforcement remains runtime-driven by `SecurityGate.enforce()`.
public enum SecurityTier: String, Sendable, CaseIterable, Codable {
    case open = "open"
    case notify = "notify"
    case request = "request"
}

// MARK: - Gate Decision

/// Result of a security gate evaluation.
public enum GateDecision: Sendable {
    case allow
    case reject(reason: String)
    case handoff(command: String, explanation: String, warning: String)
}

// MARK: - SecurityGate Actor

/// Enforces security policies on every tool call.
/// No tool can bypass this gate — it is not optional.
public actor SecurityGate {

    // MARK: Nuclear Patterns

    private static let normalizedForkBomb = ":(){:|:&};:"

    // MARK: Command-Aware Classification (V1-PATCH-001)

    /// Read-only commands that are safe to execute without notification.
    private static let safeCommandPatterns: [String] = [
        // File inspection (read-only)
        #"^cat\s"#,
        #"^head\s"#,
        #"^tail\s"#,
        #"^less\s"#,
        #"^more\s"#,
        #"^wc[\s]"#,
        #"^file\s"#,
        #"^stat\s"#,
        #"^md5\s"#,
        #"^shasum\s"#,
        // Directory listing and search
        #"^ls(\s|$)"#,
        #"^find\s"#,
        #"^tree(\s|$)"#,
        #"^du[\s]"#,
        #"^df(\s|$)"#,
        // System info (read-only)
        #"^uptime$"#,
        #"^whoami$"#,
        #"^pwd$"#,
        #"^hostname"#,
        #"^uname"#,
        #"^id(\s|$)"#,
        #"^groups(\s|$)"#,
        #"^w$"#,
        #"^who$"#,
        #"^date"#,
        #"^cal(\s|$)"#,
        #"^sw_vers"#,
        #"^system_profiler"#,
        #"^sysctl\s"#,
        #"^vm_stat"#,
        #"^top\s+-l"#,
        #"^ps[\s]"#,
        #"^ioreg"#,
        #"^pmset\s+-g"#,
        // Environment (read-only)
        #"^echo\s"#,
        #"^printf\s"#,
        #"^env$"#,
        #"^printenv"#,
        #"^which\s"#,
        #"^type\s"#,
        // Network diagnostics (read-only)
        #"^ifconfig"#,
        #"^networksetup\s+-(get|list)"#,
        #"^scutil\s+--"#,
        #"^nslookup\s"#,
        #"^dig\s"#,
        #"^ping\s+-c"#,
        #"^traceroute\s"#,
        #"^netstat"#,
        #"^lsof\s+-i"#,
        // Disk info (read-only)
        #"^diskutil\s+(list|info)"#,
        // Process/service listing (read-only)
        #"^launchctl\s+list"#,
        // Preferences reading
        #"^defaults\s+read"#,
        // Spotlight (read-only)
        #"^mdls\s"#,
        #"^mdfind\s"#,
        // Developer tools (read-only / version checks)
        #"^xcode-select\s+-p"#,
        #"^xcodebuild\s+-version"#,
        #"^swift\s+--version"#,
        #"^swiftc\s+--version"#,
        #"^python3?\s+--version"#,
        #"^pip3?\s+(list|show|freeze)"#,
        #"^node\s+--version"#,
        #"^npm\s+(list|ls|outdated|view)"#,
        // Git (read-only)
        #"^git\s+(status|log|diff|branch|remote|show|stash\s+list|tag|describe)"#,
        // SQLite read-only
        #"^sqlite3\s+.*-readonly"#,
        // Make (dry-run only)
        #"^make\s+-n"#,
    ]

    // MARK: Sensitive Paths

    // PKT-363 D2: sensitivePaths moved to ConfigManager (config.json-backed)

    private let approvalManager: NotificationApprovalManager
    private var sessionAllowedPaths: Set<String> = []

    private static let permanentAllowPrefix = "com.notionbridge.security.pathAllow."

    public init() {
        self.approvalManager = NotificationApprovalManager()

        // PKT-363 D1: Seed sensitivePaths defaults on first launch with new schema
        ConfigManager.shared.seedDefaultsIfNeeded()
    }

    // MARK: Permission Setup

    public func requestNotificationPermission() async {
        await approvalManager.requestPermission()
    }

    // MARK: Enforcement

    /// Evaluate a tool call against all security policies.
    ///
    /// **Enforcement order (PKT-376):**
    /// 1. Nuclear pattern check (fork bomb only)
    /// 2. Safe command auto-allow for shell/cli tools
    /// 3. Sensitive path check
    /// 4. Tier-based logic — Open = allow, Notify = allow, Request = approval
    ///
    /// - Parameter module: the owning module name (fb-securitygate). Used so an
    ///   "Always Allow" decision can be persisted module-scoped — covering
    ///   sibling tools — instead of only the single prompted tool. Defaults to
    ///   `""` (no module scope) for the rare caller without a registration.
    public func enforce(
        toolName: String,
        tier: SecurityTier,
        neverAutoApprove: Bool = false,
        arguments: Value,
        module: String = ""
    ) async -> GateDecision {
        let allStrings = extractStrings(from: arguments)
        let combined = allStrings.joined(separator: " ")
        let detail = requestDetail(toolName: toolName, arguments: arguments, fallback: combined)
        let lowered = detail.lowercased()

        // 1. Nuclear pattern check (highest priority)
        if let handoff = checkNuclearPattern(lowered, raw: combined) {
            return handoff
        }

        // 2. Command-aware classification for shell execution tools
        if toolName == "shell_exec" || toolName == "cli_exec" {
            if checkSafeCommand(detail) {
                return .allow
            }
        }

        // 3. Sensitive path check
        if let sensitiveResult = await checkSensitivePaths(allStrings, toolName: toolName) {
            return sensitiveResult
        }

        // 4. Tier-based logic
        switch tier {
        case .open:
            return .allow
        case .notify:
            return .allow
        case .request:
            // Learned command prefixes no longer bypass Request prompts — use Tool Registry
            // (tier override) or per-call approval. `neverAutoApprove` tools use notification
            // category NO_ALWAYS (no Always Allow action); alert fallback is Allow/Deny only.
            return await requestToolTierApproval(
                toolName: toolName,
                module: module,
                detail: detail,
                neverAutoApprove: neverAutoApprove
            )
        }
    }

    // MARK: Nuclear Check

    public func checkNuclearPattern(_ lowered: String, raw: String) -> GateDecision? {
        let normalized = lowered.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        if normalized.contains(SecurityGate.normalizedForkBomb) {
            return makeHandoff(raw)
        }
        return nil
    }

    private func makeHandoff(_ raw: String) -> GateDecision {
        let safeCommand = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return .handoff(
            command: safeCommand,
            explanation: "This command matches a fork-bomb pattern that can destabilize your system. For safety, it must be run manually in Terminal.",
            warning: "Fork bomb pattern detected. This is not an error — the command has been prepared for manual execution.\n\nOpen Terminal.app and paste:\n\n    \(safeCommand)\n\nReview carefully before executing."
        )
    }

    // MARK: Command Classification (V1-PATCH-001)

    private func checkSafeCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in SecurityGate.safeCommandPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Sensitive Path Check

    public func checkSensitivePaths(_ strings: [String], toolName: String) async -> GateDecision? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        for str in strings {
            let expanded: String
            if str.hasPrefix("~/") {
                expanded = home + str.dropFirst(1)
            } else if str.hasPrefix("~") {
                expanded = home + str.dropFirst(1)
            } else {
                expanded = str
            }

            // PKT-363 D2: Dynamic read from config-backed list (fallback to defaults on error)
            for sensitive in ConfigManager.shared.sensitivePaths {
                let expandedSensitive: String
                if sensitive.hasPrefix("~/") {
                    expandedSensitive = home + String(sensitive.dropFirst(1))
                } else {
                    expandedSensitive = sensitive
                }

                let matches = expanded.hasPrefix(expandedSensitive) ||
                              expanded.hasPrefix(expandedSensitive + "/") ||
                              str.hasPrefix(sensitive) ||
                              str.hasPrefix(sensitive + "/")

                guard matches else { continue }

                let key = SecurityGate.permanentAllowPrefix + sensitive
                if UserDefaults.standard.bool(forKey: key) {
                    return nil
                }

                if sessionAllowedPaths.contains(sensitive) {
                    return nil
                }

                // Sensitive path approvals must not set global tool tier overrides.
                // Option B: Allow = session only; Always Allow = permanent path grant (UserDefaults).
                let body = String("Access sensitive path: \(sensitive)".prefix(120))
                let approval = await approvalManager.requestApproval(
                    title: "Notion Bridge wants to \(toolName)",
                    body: body,
                    allowAlwaysAllowAction: true
                )
                switch approval {
                case .allow:
                    sessionAllowedPaths.insert(sensitive)
                    return nil
                case .alwaysAllow:
                    grantPermanentAccess(path: sensitive)
                    return nil
                case .deny:
                    return .reject(reason: "Sensitive path access denied (\(sensitive)): user declined or timed out")
                }
            }
        }
        return nil
    }

    // MARK: Notification Approval (Request-tier tools)

    /// Request-tier tool prompt.
    ///
    /// **Always Allow** (fb-securitygate) now persists a *module-scoped* override
    /// (`moduleTierOverrides[module] = notify`) so the grant covers every sibling
    /// tool in the same module — not just the one tool that happened to be
    /// prompted. The legacy per-tool `tierOverrides[toolName]` is written too so
    /// the Tool Registry UI keeps showing the change on the prompted tool. When
    /// the registration carries no module name (rare), it falls back to the
    /// per-tool override only.
    private func requestToolTierApproval(
        toolName: String,
        module: String,
        detail: String,
        neverAutoApprove: Bool
    ) async -> GateDecision {
        let truncated = String(detail.prefix(120))
        let decision = await approvalManager.requestApproval(
            title: "Notion Bridge wants to \(toolName)",
            body: truncated,
            allowAlwaysAllowAction: !neverAutoApprove
        )

        switch decision {
        case .allow:
            return .allow
        case .alwaysAllow:
            persistNotifyTierOverride(toolName: toolName, module: module)
            return .allow
        case .deny:
            return .reject(reason: "User denied via notification (or approval timeout)")
        }
    }

    /// Persist an Always-Allow grant. Writes the legacy per-tool override and,
    /// when a module name is present, a module-scoped override so sibling tools
    /// in the same module are covered (fb-securitygate point 2).
    private func persistNotifyTierOverride(toolName: String, module: String) {
        let perTool = BridgeDefaults.tierOverrides
        var toolDict = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        toolDict[toolName] = SecurityTier.notify.rawValue
        UserDefaults.standard.set(toolDict, forKey: perTool)

        if !module.isEmpty {
            let perModule = BridgeDefaults.moduleTierOverrides
            var modDict = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
            modDict[module] = SecurityTier.notify.rawValue
            UserDefaults.standard.set(modDict, forKey: perModule)
        }

        NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestDetail(toolName: String, arguments: Value, fallback: String) -> String {
        guard case .object(let dict) = arguments else {
            return normalizeWhitespace(fallback)
        }

        let keyCandidatesByTool: [String: [String]] = [
            "shell_exec": ["command"],
            "cli_exec": ["command"],
            "run_script": ["scriptName"],
            "applescript_exec": ["script"],
            "messages_send": ["recipient", "body"],
        ]

        let keyCandidates = keyCandidatesByTool[toolName] ?? ["command", "script", "scriptName"]
        let parts = keyCandidates.compactMap { key -> String? in
            if case .string(let value) = dict[key] {
                let normalized = normalizeWhitespace(value)
                return normalized.isEmpty ? nil : normalized
            }
            return nil
        }

        if parts.isEmpty {
            return normalizeWhitespace(fallback)
        }
        return parts.joined(separator: " ")
    }

    // MARK: Session Management

    public func grantPermanentAccess(path: String) {
        let key = SecurityGate.permanentAllowPrefix + path
        UserDefaults.standard.set(true, forKey: key)
    }

    public func revokePermanentAccess(path: String) {
        let key = SecurityGate.permanentAllowPrefix + path
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: Fire-and-Forget Notification (F2)

    /// F2: Sends a fire-and-forget macOS notification when a Notify-tier tool executes.
    /// This is informational only — no approval actions. Additive to the existing approval flow.
    /// Called by ToolRouter after successful execution of a Notify-tier tool.
    /// PKT-552: Notify-tier fire-and-forget with structured context.
    /// Populates `userInfo` with tool + Notion deep-link metadata (contract with PKT-553).
    public func sendExecutionNotification(context: ExecutionNotificationContext) async {
        await approvalManager.sendFireAndForget(context: context)
    }

    /// Legacy overload retained for backward compatibility.
    public func sendExecutionNotification(toolName: String) async {
        await sendExecutionNotification(
            context: ExecutionNotificationContext(toolName: toolName)
        )
    }

    public func clearSessionPermissions() {
        sessionAllowedPaths.removeAll()
    }

    // MARK: String Extraction

    private func extractStrings(from value: Value) -> [String] {
        var results: [String] = []
        switch value {
        case .string(let s):
            results.append(s)
        case .object(let dict):
            for (_, v) in dict {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .array(let arr):
            for v in arr {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .int, .double, .bool, .null:
            break
        case .data:
            break
        }
        return results
    }
}

// MARK: - ApprovalCoalescer (fb-securitygate point 2)

/// Pure bookkeeping for in-flight approval coalescing, extracted so the
/// concurrency-collapsing contract is unit-testable without a live
/// notification center or continuations.
///
/// Concurrent Request-tier calls that share the same `coalesceKey` (same
/// prompt) must collapse into ONE notification: the first caller posts the
/// prompt; later callers park as *waiters* and are all resolved with the same
/// decision when the user answers (or the prompt times out). This type tracks
/// only the relationships (key → servicing identifier, identifier → key, key →
/// waiter tokens). The owning manager maps tokens/identifiers to the actual
/// continuations.
public struct ApprovalCoalescer: Sendable {
    private var keyToIdentifier: [String: String] = [:]
    private var identifierToKey: [String: String] = [:]
    private var keyToWaiters: [String: [String]] = [:]

    public init() {}

    /// Register interest in `coalesceKey`.
    /// - Returns `true` iff this is the FIRST caller — it owns the prompt under
    ///   `identifier` and must post the notification. `false` means an identical
    ///   prompt is already in flight; the caller parked as a waiter and must NOT
    ///   post a second notification.
    public mutating func begin(coalesceKey: String, identifier: String, waiterToken: String) -> Bool {
        if keyToIdentifier[coalesceKey] != nil {
            keyToWaiters[coalesceKey, default: []].append(waiterToken)
            return false
        }
        keyToIdentifier[coalesceKey] = identifier
        identifierToKey[identifier] = coalesceKey
        return true
    }

    /// Drain and clear all waiter tokens parked behind the prompt that
    /// `identifier` was servicing. Returns `[]` if the identifier is unknown
    /// (already resolved) — making the resolve path idempotent.
    public mutating func drain(forIdentifier identifier: String) -> [String] {
        guard let key = identifierToKey.removeValue(forKey: identifier) else { return [] }
        keyToIdentifier.removeValue(forKey: key)
        return keyToWaiters.removeValue(forKey: key) ?? []
    }

    /// Number of distinct prompts currently in flight (test introspection).
    public var inFlightPromptCount: Int { keyToIdentifier.count }
}

// MARK: - NotificationApprovalManager

/// Manages UNUserNotificationCenter-based approval flow.
/// Falls back to synchronous NSAlert if notification permission is denied.
/// Thread safety: NSLock via nonisolated synchronous helpers (Swift 6 safe).
public final class NotificationApprovalManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {

    public enum ApprovalDecision: Sendable {
        case allow
        case deny
        case alwaysAllow
    }

    private let center: UNUserNotificationCenter?
    private var hasPermission: Bool = false
    /// fb-securitygate (point 3): the silent 30s auto-deny was too easy to miss.
    /// Default raised to 90s so the prompt does not vanish out from under a user
    /// who steps away briefly. Injectable for deterministic tests.
    private let approvalTimeout: TimeInterval
    private let isTestProcess: Bool

    private let lock = NSLock()
    private var pendingApprovals: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]

    // fb-securitygate (point 2): in-flight coalescing. Concurrent Request-tier
    // calls that share the same prompt (same title+body, e.g. a 3-way-parallel
    // snippets_delete) collapse into ONE notification. The first caller posts
    // the prompt; later callers with the same coalesce key park here and are all
    // resumed with the SAME decision when the user answers (or it times out).
    // This fixes the "3 separate prompts that time out" failure: the user
    // answers once and every coalesced caller honors that single answer.
    // Relationship bookkeeping lives in the pure `ApprovalCoalescer`; this map
    // resolves the opaque waiter tokens back to their parked continuations.
    private var coalescer = ApprovalCoalescer()
    private var waiterContinuations: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    /// fb-securitygate (race fix): decisions for waiter tokens that were drained
    /// by the owner BEFORE they parked their continuation. `parkCoalescedWaiter`
    /// consumes this and resumes immediately, so a lost wakeup can't hang a waiter.
    private var resolvedWaiters: [String: ApprovalDecision] = [:]

    static let categoryIdentifier = "SECURITY_APPROVAL"
    static let categoryIdentifierNoAlways = "SECURITY_APPROVAL_NO_ALWAYS"
    static let allowActionIdentifier = "ALLOW_ACTION"
    static let cancelActionIdentifier = "CANCEL_ACTION"
    static let alwaysAllowActionIdentifier = "ALWAYS_ALLOW"

    // PKT-552: Notify-tier category + action identifiers.
    static let notifyNotionCategoryIdentifier = "NOTIFY_NOTION"
    static let notifyGenericCategoryIdentifier = "NOTIFY_GENERIC"
    static let openPageActionIdentifier = "OPEN_PAGE_ACTION"
    static let silenceActionIdentifier = "SILENCE_ACTION"
    static let requireApprovalActionIdentifier = "REQUIRE_APPROVAL_ACTION"

    /// UserNotifications is only reliable when running as a bundled app process.
    /// CLI test executables (e.g. swift run NotionBridgeTests) can crash when calling
    /// UNUserNotificationCenter.current(), so we avoid touching it in that context.
    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    /// Detect standalone test executable runs to keep tests non-interactive.
    private static var runningInTestProcess: Bool {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("notionbridgetests") { return true }
        return CommandLine.arguments.joined(separator: " ").lowercased().contains("notionbridgetests")
    }

    public override convenience init() {
        self.init(approvalTimeout: 90)
    }

    /// fb-securitygate: timeout-injecting designated initializer (test seam).
    /// Production uses the 90s default via the convenience `init()`.
    public init(approvalTimeout: TimeInterval) {
        self.approvalTimeout = approvalTimeout
        self.isTestProcess = Self.runningInTestProcess
        if Self.canUseUserNotifications {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
        super.init()
        if let center {
            center.delegate = self
            registerCategories()
            // PKT-548: Seed hasPermission from actual macOS notification state at init.
            // Fixes cold-start bug where hasPermission starts false every launch,
            // causing Request-tier tool calls to fall through to NSAlert modal
            // fallback (no Always Allow action) instead of the notification path,
            // even when the user has granted notifications in System Settings.
            Task { [weak self] in
                await self?.syncHasPermissionFromSettings()
            }
        }
    }

    /// PKT-548: Query notificationSettings() and seed hasPermission from the
    /// actual macOS grant state. Mirrors PermissionManager.checkNotifications so
    /// that both permission sources converge to the same truth at app launch.
    ///
    /// macOS may leave authorizationStatus at .notDetermined even when the user
    /// has granted notifications via System Settings, until requestAuthorization()
    /// is called once in-process. This handles that cold-start sync gap.
    private func syncHasPermissionFromSettings() async {
        guard let center else { return }
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[SecurityGate] Init requestAuthorization error: \(error.localizedDescription)")
            }
            settings = await center.notificationSettings()
        }
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        default:
            granted = false
        }
        hasPermission = granted
        print("[SecurityGate] Init seed: hasPermission=\(granted) (authorizationStatus=\(settings.authorizationStatus.rawValue))")
    }

    // MARK: Thread-Safe Helpers (nonisolated — safe from async contexts)

    private nonisolated func storePending(
        forKey key: String,
        continuation: CheckedContinuation<ApprovalDecision, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        pendingApprovals[key] = continuation
    }

    private nonisolated func removePending(forKey key: String) -> CheckedContinuation<ApprovalDecision, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingApprovals.removeValue(forKey: key)
    }

    // MARK: Coalescing Helpers (fb-securitygate point 2)

    /// Synchronously claim or join the prompt identified by `coalesceKey`.
    ///
    /// - If no prompt with that key is in flight, records `identifier` as the
    ///   servicing notification: `isFirst == true`. The caller owns the prompt
    ///   and must post the notification + store its pending continuation under
    ///   `identifier`.
    /// - If a prompt is already in flight, allocates a `waiterToken`:
    ///   `isFirst == false`. The caller must park its continuation via
    ///   `parkCoalescedWaiter(token:continuation:)` and must NOT post a second
    ///   notification.
    ///
    /// No continuation crosses this boundary, so the decision happens with no
    /// `await` in between — a concurrent burst elects exactly one owner.
    public nonisolated func reserveCoalesced(
        coalesceKey: String,
        identifier: String
    ) -> (isFirst: Bool, waiterToken: String) {
        lock.lock()
        defer { lock.unlock() }
        let waiterToken = UUID().uuidString
        let isFirst = coalescer.begin(
            coalesceKey: coalesceKey,
            identifier: identifier,
            waiterToken: waiterToken
        )
        return (isFirst, waiterToken)
    }

    /// Park a joined waiter's continuation under its opaque token, to be resumed
    /// when the owner's prompt resolves (`drainCoalescedWaiters`).
    public nonisolated func parkCoalescedWaiter(
        token: String,
        continuation: CheckedContinuation<ApprovalDecision, Never>
    ) {
        lock.lock()
        if let decision = resolvedWaiters.removeValue(forKey: token) {
            lock.unlock()
            // fb-securitygate (race fix): the owner already resolved this key
            // before we parked — resume now instead of parking forever.
            continuation.resume(returning: decision)
            return
        }
        waiterContinuations[token] = continuation
        lock.unlock()
    }

    /// Drain all extra waiters parked under the coalesce key that `identifier`
    /// was servicing, returning their continuations so the caller can resume
    /// each with the resolved decision. The FIRST caller's own continuation is
    /// NOT included — it is resumed via the regular `pendingApprovals` path
    /// keyed by `identifier`. Idempotent: returns `[]` for an unknown identifier.
    public nonisolated func drainCoalescedWaiters(
        forIdentifier identifier: String,
        decision: ApprovalDecision
    ) -> [CheckedContinuation<ApprovalDecision, Never>] {
        lock.lock()
        defer { lock.unlock() }
        let tokens = coalescer.drain(forIdentifier: identifier)
        var parked: [CheckedContinuation<ApprovalDecision, Never>] = []
        for token in tokens {
            if let continuation = waiterContinuations.removeValue(forKey: token) {
                parked.append(continuation)
            } else {
                // fb-securitygate (race fix): owner resolved before this waiter
                // parked — buffer the decision so parkCoalescedWaiter resumes it.
                resolvedWaiters[token] = decision
            }
        }
        return parked
    }

    // MARK: Setup

    private func registerCategories() {
        guard let center else { return }
        // PKT-549: Action ordering — Always Allow first (visible in compact banner),
        // Allow second, Cancel third (destructive/red). macOS only shows first 2 actions
        // without expanding the notification, so Always Allow + Allow must lead.
        let alwaysAllowAction = UNNotificationAction(
            identifier: Self.alwaysAllowActionIdentifier,
            title: "Always Allow",
            options: []
        )
        let allowAction = UNNotificationAction(
            identifier: Self.allowActionIdentifier,
            title: "Allow",
            options: []
        )
        let cancelAction = UNNotificationAction(
            identifier: Self.cancelActionIdentifier,
            title: "Cancel",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [alwaysAllowAction, allowAction, cancelAction],
            intentIdentifiers: [],
            options: []
        )
        let categoryNoAlways = UNNotificationCategory(
            identifier: Self.categoryIdentifierNoAlways,
            actions: [allowAction, cancelAction],
            intentIdentifiers: [],
            options: []
        )
        // PKT-552: Notify-tier categories.
        let openPageAction = UNNotificationAction(
            identifier: Self.openPageActionIdentifier,
            title: "Open Page",
            options: [.foreground]
        )
        let silenceAction = UNNotificationAction(
            identifier: Self.silenceActionIdentifier,
            title: "Silence",
            options: []
        )
        let requireApprovalAction = UNNotificationAction(
            identifier: Self.requireApprovalActionIdentifier,
            title: "Require Approval",
            options: []
        )
        let notifyNotionCategory = UNNotificationCategory(
            identifier: Self.notifyNotionCategoryIdentifier,
            actions: [openPageAction, silenceAction, requireApprovalAction],
            intentIdentifiers: [],
            options: []
        )
        let notifyGenericCategory = UNNotificationCategory(
            identifier: Self.notifyGenericCategoryIdentifier,
            actions: [silenceAction, requireApprovalAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([
            category,
            categoryNoAlways,
            notifyNotionCategory,
            notifyGenericCategory
        ])
    }

    // MARK: Fire-and-Forget (F2)

    /// PKT-552: Notify-tier fire-and-forget with structured context.
    /// Selects `NOTIFY_NOTION` category (Open Page + Silence + Require Approval) when a
    /// `notionPageURL` is present; otherwise `NOTIFY_GENERIC` (Silence + Require Approval).
    /// `userInfo` carries the full context for PKT-553 Content Extension rendering.
    public func sendFireAndForget(context: ExecutionNotificationContext) async {
        guard !isTestProcess, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "The Bridge"
        content.body = "\"\(context.toolName)\" was called"
        content.sound = .default
        content.categoryIdentifier = context.notionPageURL != nil
            ? Self.notifyNotionCategoryIdentifier
            : Self.notifyGenericCategoryIdentifier
        // userInfo schema (contract with PKT-553 Content Extension):
        //   toolName, argumentsSummary, notionPageURL, notionBlockURL, riskLevel, categoryType
        var userInfo: [String: Any] = [
            "toolName": context.toolName,
            "argumentsSummary": context.argumentsSummary,
            "riskLevel": context.riskLevel,
            "categoryType": "notify"
        ]
        userInfo["notionPageURL"] = context.notionPageURL ?? NSNull()
        userInfo["notionBlockURL"] = context.notionBlockURL ?? NSNull()
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Legacy overload retained for non-Notify callers.
    public func sendFireAndForget(title: String, body: String) async {
        guard !isTestProcess, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    // PKT-552: Persist a tier override from a notification action handler.
    // Used by Silence (→ "open") and Require Approval (→ "request").
    static func persistTierOverride(toolName: String, tier: String) {
        let key = BridgeDefaults.tierOverrides
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[toolName] = tier
        UserDefaults.standard.set(dict, forKey: key)
        NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
    }

    public func requestPermission() async {
        guard let center else {
            hasPermission = false
            return
        }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[SecurityGate] Notification permission request error: \(error.localizedDescription)")
        }
        // PKT-548: Use notificationSettings() as source-of-truth after the call,
        // mirroring PermissionManager.requestNotificationAccess (N2). The Bool
        // return from requestAuthorization is unreliable when authorization was
        // already determined externally — it returns false (with UNErrorDomain
        // error 1) even though the permission IS granted.
        let settings = await center.notificationSettings()
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            granted = true
        default:
            granted = false
        }
        hasPermission = granted
        if granted {
            print("[SecurityGate] Notification permission active (authorizationStatus=\(settings.authorizationStatus.rawValue))")
        } else {
            print("[SecurityGate] Notification permission not granted — NSAlert fallback will be used (authorizationStatus=\(settings.authorizationStatus.rawValue))")
        }
    }

    // MARK: Approval Request

    public func requestApproval(
        title: String,
        body: String,
        allowAlwaysAllowAction: Bool = true
    ) async -> ApprovalDecision {
        if isTestProcess {
            return .allow
        }
        // PKT-548: Diagnostic log to surface which approval path is chosen.
        // Helps diagnose cases where Request-tier tool calls fall back to NSAlert
        // despite notifications being granted at the OS level.
        let path = hasPermission ? "notification" : "alert-fallback"
        print("[SecurityGate] Approval path: \(path) for \(title)")
        if hasPermission {
            return await requestViaNotification(
                title: title,
                body: body,
                allowAlwaysAllowAction: allowAlwaysAllowAction
            )
        } else {
            return await requestViaAlert(title: title, body: body)
        }
    }

    private func requestViaNotification(
        title: String,
        body: String,
        allowAlwaysAllowAction: Bool
    ) async -> ApprovalDecision {
        guard let center else {
            return await requestViaAlert(title: title, body: body)
        }

        let identifier = UUID().uuidString
        // fb-securitygate (point 2): coalesce identical concurrent prompts. The
        // key folds in whether the prompt offers Always Allow so a NO_ALWAYS
        // prompt never silently inherits an Always-Allow-capable one's answer.
        let coalesceKey = "\(allowAlwaysAllowAction ? "1" : "0")\u{1}\(title)\u{1}\(body)"

        // Phase 1 (synchronous): claim or join the prompt BEFORE any await so a
        // concurrent burst deterministically elects exactly one owner.
        let reservation = reserveCoalesced(coalesceKey: coalesceKey, identifier: identifier)

        guard reservation.isFirst else {
            // Joined an in-flight prompt — do NOT post a second notification.
            // Park and await the shared decision (resolved by the owner's
            // delegate/timeout path via drainCoalescedWaiters).
            print("[SecurityGate] Coalesced into in-flight approval prompt: \(title)")
            return await withCheckedContinuation { continuation in
                parkCoalescedWaiter(token: reservation.waiterToken, continuation: continuation)
            }
        }

        // Phase 2 (owner): post the notification (await OUTSIDE any spawned Task
        // so the non-Sendable `center` is never captured into a child closure).
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = allowAlwaysAllowAction
            ? Self.categoryIdentifier
            : Self.categoryIdentifierNoAlways
        // fb-securitygate (point 3): a pre-execution approval is not
        // informational — raise it to time-sensitive so macOS surfaces it even
        // under Focus / Do Not Disturb, making the silent-timeout failure mode
        // far harder to miss.
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await center.add(request)
        } catch {
            print("[SecurityGate] Failed to deliver notification: \(error.localizedDescription)")
            // Owner + every joined waiter fall back to the synchronous alert so
            // none of them hang. The owner's decision is shared with the group.
            let decision = await requestViaAlert(title: title, body: body)
            let waiters = drainCoalescedWaiters(forIdentifier: identifier, decision: decision)
            for w in waiters { w.resume(returning: decision) }
            return decision
        }

        // Phase 3 (owner): await the user's answer, with a timeout that denies
        // the whole coalesced group. `self` is the only capture in the timeout
        // Task — `center`/`request` are not — so it is concurrency-clean.
        return await withCheckedContinuation { continuation in
            storePending(forKey: identifier, continuation: continuation)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.approvalTimeout))
                // Only acts if still pending — a user answer already removed it.
                if let owner = self.removePending(forKey: identifier) {
                    let waiters = self.drainCoalescedWaiters(forIdentifier: identifier, decision: .deny)
                    owner.resume(returning: .deny)
                    for w in waiters { w.resume(returning: .deny) }
                    print("[SecurityGate] Approval timed out (\(Int(self.approvalTimeout))s) — denied by default (\(waiters.count + 1) caller(s))")
                }
            }
        }
    }

    @MainActor
    private func requestViaAlert(title: String, body: String) async -> ApprovalDecision {
        #if canImport(AppKit)
        guard NSApp != nil else {
            print("[SecurityGate] No NSApplication context for approval alert — denying by default")
            return .deny
        }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .allow : .deny
        #else
        return .deny
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo

        // PKT-552: Notify-tier action handlers — no pending continuation to resume.
        switch response.actionIdentifier {
        case Self.openPageActionIdentifier:
            let urlString = (userInfo["notionBlockURL"] as? String)
                ?? (userInfo["notionPageURL"] as? String)
            #if canImport(AppKit)
            if let urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                print("[SecurityGate] Opened Notion deep link: \(urlString)")
            } else {
                print("[SecurityGate] Open Page: no URL in userInfo")
            }
            #endif
            completionHandler()
            return
        case Self.silenceActionIdentifier:
            if let toolName = userInfo["toolName"] as? String {
                NotificationApprovalManager.persistTierOverride(toolName: toolName, tier: "open")
                print("[SecurityGate] Silenced tool: \(toolName) → tier=open")
            }
            completionHandler()
            return
        case Self.requireApprovalActionIdentifier:
            if let toolName = userInfo["toolName"] as? String {
                NotificationApprovalManager.persistTierOverride(toolName: toolName, tier: "request")
                print("[SecurityGate] Required approval for tool: \(toolName) → tier=request")
            }
            completionHandler()
            return
        default:
            break
        }

        let decision: ApprovalDecision
        switch response.actionIdentifier {
        case Self.allowActionIdentifier:
            decision = .allow
        case Self.alwaysAllowActionIdentifier:
            decision = .alwaysAllow
        default:
            decision = .deny
        }

        // fb-securitygate (point 2): a single user answer resolves the first
        // caller AND every coalesced waiter parked behind the same prompt.
        let waiters = drainCoalescedWaiters(forIdentifier: identifier, decision: decision)
        if let continuation = removePending(forKey: identifier) {
            continuation.resume(returning: decision)
        }
        for w in waiters { w.resume(returning: decision) }

        if waiters.isEmpty {
            print("[SecurityGate] Notification response: \(decision) for \(identifier)")
        } else {
            print("[SecurityGate] Notification response: \(decision) for \(identifier) (+\(waiters.count) coalesced)")
        }

        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
