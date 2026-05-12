// CursorNotificationDispatcher.swift — PKT-3.4.2 Wave 3 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// User-notification dispatcher for Cursor agent run events. Subscribes to the
// three Notification.Name constants posted by CursorAgentRegistry (Wave 2) and
// CursorCostLedger (Wave 1) and maps them to UNNotificationRequest emissions
// against the four categories registered in
// NotificationContentExtension/Info.plist:
//
//   • CURSOR_AGENT_READY            — run succeeded
//   • CURSOR_AGENT_FAILED           — run failed / cancelled
//   • CURSOR_AGENT_STALLED          — heartbeat watchdog escalated to .red
//   • CURSOR_AGENT_NEEDS_APPROVAL   — daily cost cap (soft or hard) crossed
//
// Authorization (.alert + .sound + .badge) is requested lazily on the first
// emission so a fresh Bridge install does not show a permission dialog at
// launch. Wave 5 wires watchdog escalation + cost-cap auto-pause side
// effects; this dispatcher is the user-facing surface only.
//
// Testability: build* methods are nonisolated-from-tests and pure — they take
// inputs and return UNNotificationRequest with deterministic content/userInfo.
// `deliverFn` and `authorizeFn` are stored closures that tests can swap to
// capture emitted requests without touching UNUserNotificationCenter.

import Foundation
import UserNotifications

// MARK: - Category identifiers

/// Identifiers must match `NotificationContentExtension/Info.plist`
/// > `NSExtensionAttributes > UNNotificationExtensionCategory`.
public enum CursorNotificationCategory {
    public static let ready          = "CURSOR_AGENT_READY"
    public static let failed         = "CURSOR_AGENT_FAILED"
    public static let stalled        = "CURSOR_AGENT_STALLED"
    public static let needsApproval  = "CURSOR_AGENT_NEEDS_APPROVAL"

    public static let all: [String] = [ready, failed, stalled, needsApproval]
}

/// userInfo keys for cursor notifications. Mirrors the PKT-552/553
/// convention used by SecurityGate notifications (categoryType + structured
/// payload) so the Content Extension can read either family identically.
public enum CursorNotificationUserInfoKey {
    public static let categoryType     = "categoryType"
    public static let runId            = "runId"
    public static let runtime          = "runtime"
    public static let model            = "model"
    public static let repoPath         = "repoPath"
    public static let status           = "status"
    public static let costCents        = "costCents"
    public static let errorMessage     = "errorMessage"
    public static let silentForSeconds = "silentForSeconds"
    public static let tier             = "tier"
    public static let totalCents       = "totalCents"
    public static let thresholdCents   = "thresholdCents"
    public static let dateLocal        = "dateLocal"
}

// MARK: - Dispatcher

@MainActor
public final class CursorNotificationDispatcher {

    // MARK: Singleton

    public static let shared = CursorNotificationDispatcher()

    // MARK: Injectable seams (tests replace these)

    /// Closure that delivers a built request. Real app posts via
    /// `UNUserNotificationCenter.current().add(...)`; tests capture it.
    public var deliverFn: (UNNotificationRequest) -> Void = { request in
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Closure that requests authorization (.alert/.sound/.badge). Real app
    /// hits the live center; tests stub to `true`.
    public var authorizeFn: (UNAuthorizationOptions) async -> Bool = { options in
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: options)
        } catch {
            return false
        }
    }

    /// Snapshot a single registry state by run id. Default reads from
    /// `CursorAgentRegistry.shared`; tests inject a fixture lookup.
    public var stateLookup: (String) -> CursorAgentRegistryState? = { id in
        CursorAgentRegistry.shared.state(for: id)
    }

    // MARK: Observer state

    private var observerTokens: [NSObjectProtocol] = []
    private var didRequestAuthorization = false

    /// True after `start()` succeeds and before `stop()` is called.
    public private(set) var isObserving = false

    // MARK: Init

    public init() {}

    // MARK: Lifecycle

    /// Subscribe to the three Cursor `Notification.Name` constants. Idempotent.
    public func start() {
        guard !isObserving else { return }
        let center = NotificationCenter.default

        // The observer queue is OperationQueue.main, which runs on the main
        // thread. We bridge to MainActor synchronously via assumeIsolated so
        // the (non-Sendable) Notification value never crosses an actor hop.
        observerTokens.append(center.addObserver(
            forName: .cursorAgentStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable primitives BEFORE crossing the isolation
            // boundary; `Notification` itself is not Sendable.
            let runId = (note.userInfo?["runId"] as? String) ?? ""
            let statusRaw = (note.userInfo?["status"] as? String) ?? ""
            MainActor.assumeIsolated {
                self?.handleStateChange(runId: runId, statusRaw: statusRaw)
            }
        })

        observerTokens.append(center.addObserver(
            forName: .cursorAgentCostCapTripped,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let tier = (note.userInfo?["tier"] as? String) ?? "soft"
            let total = (note.userInfo?["totalCents"] as? Int) ?? 0
            let threshold = (note.userInfo?["thresholdCents"] as? Int) ?? 0
            let dateLocal = (note.userInfo?["dateLocal"] as? String) ?? ""
            MainActor.assumeIsolated {
                self?.handleCostCap(
                    tier: tier,
                    totalCents: total,
                    thresholdCents: threshold,
                    dateLocal: dateLocal
                )
            }
        })

        observerTokens.append(center.addObserver(
            forName: .cursorAgentDidStall,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let runId = (note.userInfo?["runId"] as? String) ?? ""
            let level = (note.userInfo?["level"] as? String) ?? ""
            let silentFor = (note.userInfo?["silentForSeconds"] as? Int) ?? 0
            MainActor.assumeIsolated {
                self?.handleStall(
                    runId: runId,
                    level: level,
                    silentForSeconds: silentFor
                )
            }
        })

        isObserving = true
    }

    /// Unsubscribe and reset observer state. Idempotent.
    public func stop() {
        let center = NotificationCenter.default
        for token in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()
        isObserving = false
    }

    // MARK: Handlers (internal — tests call directly)

    /// Map a registry state change to a READY or FAILED notification. No-op
    /// for transient statuses (running / queued / unknown) — those drive the
    /// menu bar pill + Dashboard surface but never OS alerts.
    public func handleStateChange(runId: String, statusRaw: String) {
        guard !runId.isEmpty, let status = CursorRunStatus(rawValue: statusRaw) else { return }
        let state = stateLookup(runId)
        switch status {
        case .succeeded:
            emit(buildReadyRequest(runId: runId, state: state))
        case .failed, .cancelled:
            emit(buildFailedRequest(runId: runId, state: state))
        case .running, .queued, .unknown:
            return
        }
    }

    /// Map a cost-cap trip to a NEEDS_APPROVAL notification.
    public func handleCostCap(tier: String, totalCents: Int, thresholdCents: Int, dateLocal: String) {
        emit(buildCostCapRequest(
            tier: tier,
            totalCents: totalCents,
            thresholdCents: thresholdCents,
            dateLocal: dateLocal
        ))
    }

    /// Map a watchdog stall (level=red) to a STALLED notification. yellow
    /// transitions are visual-only (menu bar / Dashboard row tint).
    public func handleStall(runId: String, level: String, silentForSeconds: Int) {
        guard !runId.isEmpty, level == "red" else { return }
        let state = stateLookup(runId)
        emit(buildStallRequest(
            runId: runId,
            silentForSeconds: silentForSeconds,
            state: state
        ))
    }

    // MARK: Builders (pure — testable in isolation)

    public func buildReadyRequest(runId: String, state: CursorAgentRegistryState?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = CursorNotificationCategory.ready
        content.title = "Cursor agent ready"
        content.body = bodyForReady(state: state)
        content.sound = .default
        content.userInfo = baseUserInfo(
            category: CursorNotificationCategory.ready,
            runId: runId,
            state: state
        )
        return UNNotificationRequest(
            identifier: identifier(category: CursorNotificationCategory.ready, key: runId),
            content: content,
            trigger: nil
        )
    }

    public func buildFailedRequest(runId: String, state: CursorAgentRegistryState?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = CursorNotificationCategory.failed
        content.title = "Cursor agent failed"
        content.body = bodyForFailed(state: state)
        content.sound = .default
        var info = baseUserInfo(
            category: CursorNotificationCategory.failed,
            runId: runId,
            state: state
        )
        info[CursorNotificationUserInfoKey.errorMessage] = state?.lastErrorMessage ?? ""
        content.userInfo = info
        return UNNotificationRequest(
            identifier: identifier(category: CursorNotificationCategory.failed, key: runId),
            content: content,
            trigger: nil
        )
    }

    public func buildStallRequest(runId: String, silentForSeconds: Int, state: CursorAgentRegistryState?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = CursorNotificationCategory.stalled
        content.title = "Cursor agent stalled"
        let minutes = max(1, silentForSeconds / 60)
        let repo = state?.run.repoPath ?? runId
        content.body = "No activity for \(minutes) min · \(repo)"
        content.sound = .default
        var info = baseUserInfo(
            category: CursorNotificationCategory.stalled,
            runId: runId,
            state: state
        )
        info[CursorNotificationUserInfoKey.silentForSeconds] = silentForSeconds
        content.userInfo = info
        return UNNotificationRequest(
            identifier: identifier(category: CursorNotificationCategory.stalled, key: runId),
            content: content,
            trigger: nil
        )
    }

    public func buildCostCapRequest(tier: String, totalCents: Int, thresholdCents: Int, dateLocal: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = CursorNotificationCategory.needsApproval
        let dollars = String(format: "$%.2f", Double(totalCents) / 100.0)
        let cap = String(format: "$%.2f", Double(thresholdCents) / 100.0)
        if tier == "hard" {
            content.title = "Cursor hard cap reached"
            content.body = "Daily spend \(dollars) crossed \(cap) hard cap — cloud runs terminated."
        } else {
            content.title = "Cursor soft cap reached"
            content.body = "Daily spend \(dollars) crossed \(cap) soft cap — cloud runs paused."
        }
        content.sound = .default
        let info: [String: Any] = [
            CursorNotificationUserInfoKey.categoryType: CursorNotificationCategory.needsApproval,
            CursorNotificationUserInfoKey.tier: tier,
            CursorNotificationUserInfoKey.totalCents: totalCents,
            CursorNotificationUserInfoKey.thresholdCents: thresholdCents,
            CursorNotificationUserInfoKey.dateLocal: dateLocal,
        ]
        content.userInfo = info
        return UNNotificationRequest(
            identifier: identifier(
                category: CursorNotificationCategory.needsApproval,
                key: "\(tier)-\(dateLocal)"
            ),
            content: content,
            trigger: nil
        )
    }

    // MARK: Helpers

    private func baseUserInfo(category: String, runId: String, state: CursorAgentRegistryState?) -> [String: Any] {
        var info: [String: Any] = [
            CursorNotificationUserInfoKey.categoryType: category,
            CursorNotificationUserInfoKey.runId: runId,
        ]
        if let s = state {
            info[CursorNotificationUserInfoKey.runtime] = s.run.runtime.rawValue
            info[CursorNotificationUserInfoKey.model] = s.run.model
            info[CursorNotificationUserInfoKey.repoPath] = s.run.repoPath ?? ""
            info[CursorNotificationUserInfoKey.status] = s.run.status.rawValue
            info[CursorNotificationUserInfoKey.costCents] = s.run.costCents ?? 0
        } else {
            info[CursorNotificationUserInfoKey.runtime] = ""
            info[CursorNotificationUserInfoKey.model] = ""
            info[CursorNotificationUserInfoKey.repoPath] = ""
            info[CursorNotificationUserInfoKey.status] = ""
            info[CursorNotificationUserInfoKey.costCents] = 0
        }
        return info
    }

    private func bodyForReady(state: CursorAgentRegistryState?) -> String {
        guard let s = state else { return "Run completed" }
        var parts: [String] = []
        if let repo = s.run.repoPath, !repo.isEmpty { parts.append(repo) }
        parts.append(s.run.model)
        if let c = s.run.costCents { parts.append(String(format: "$%.2f", Double(c) / 100.0)) }
        return parts.isEmpty ? "Run completed" : parts.joined(separator: " · ")
    }

    private func bodyForFailed(state: CursorAgentRegistryState?) -> String {
        if let msg = state?.lastErrorMessage, !msg.isEmpty { return msg }
        if let repo = state?.run.repoPath, !repo.isEmpty { return "Failed: \(repo)" }
        return "Agent run failed"
    }

    private func identifier(category: String, key: String) -> String {
        // Stable-ish identifier — Notion Center collapses repeats by id, so we
        // include a coarse timestamp to allow multiple alerts per run when the
        // user genuinely wants distinct prompts (e.g. retry after failure).
        "cursor-\(category)-\(key)-\(Int(Date().timeIntervalSince1970))"
    }

    // MARK: Emit

    private func emit(_ request: UNNotificationRequest) {
        let deliver = self.deliverFn
        if didRequestAuthorization {
            deliver(request)
            return
        }
        didRequestAuthorization = true
        let authorize = self.authorizeFn
        Task { @MainActor in
            _ = await authorize([.alert, .sound, .badge])
            deliver(request)
        }
    }
}
