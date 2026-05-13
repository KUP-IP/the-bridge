// CursorAutoPauseController.swift — PKT-3.4.2 Wave 5b (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Cost-cap auto-pause / terminate side effects. Subscribes to the
// `.cursorAgentCostCapTripped` notification emitted by `CursorCostLedger`
// when a `record(...)` call crosses the soft or hard threshold, and reacts:
//
// - tier="soft" → cancel every running **cloud** agent (local agents continue
//   running since their cost is $0). Sets `pausedAt` so the Dashboard banner +
//   any other consumers can render a Resume / Cancel-all surface.
//
// - tier="hard" → cancel **every** running agent (cloud + local). Sets
//   `lockedAt` so the new-run modal can disable Submit until midnight rollover
//   or an explicit `unlock()` (admin / test override).
//
// Runtime cancellation is best-effort: local sidecar availability, API auth,
// and cloud runtime state can still fail independently of this controller's
// state-machine update.
//
// Testability: `cancelFn` + `runningStatesProvider` are injectable closures
// (defaults bound to `CursorRuntime.shared.agentCancel` + `CursorAgentRegistry.shared.runningStates`).
//
// Thread model: `@MainActor` (matches CursorAgentRegistry / dispatcher / watchdog).

import Foundation

@MainActor
public final class CursorAutoPauseController: ObservableObject {

    public static let shared = CursorAutoPauseController()

    // MARK: Published state

    /// Non-nil when the soft cap has been tripped (cloud agents auto-cancelled).
    /// Cleared by `unlock()` or midnight rollover.
    @Published public private(set) var pausedAt: Date?

    /// Non-nil when the hard cap has been tripped (all agents auto-cancelled,
    /// new-run modal Submit disabled).
    @Published public private(set) var lockedAt: Date?

    /// Convenience: `lockedAt != nil`.
    public var isLocked: Bool { lockedAt != nil }

    /// Convenience: `pausedAt != nil || lockedAt != nil`.
    public var isPaused: Bool { pausedAt != nil || lockedAt != nil }

    // MARK: Injectable surfaces (defaults bind to live singletons)

    /// Cancel a single run by id. Defaults to `CursorRuntime.shared.agentCancel`.
    /// Tests can swap this to a recorder that captures invocations.
    /// Default is assigned in `init()` because the closure captures the
    /// actor-isolated `CursorRuntime.shared` and cannot be evaluated as a
    /// stored-property default expression under Swift 6 strict concurrency.
    public var cancelFn: (String) async throws -> Void

    /// Snapshot of currently running registry states. Defaults to
    /// `CursorAgentRegistry.shared.runningStates`. Tests inject a fixture.
    public var runningStatesProvider: () -> [CursorAgentRegistryState]

    // MARK: Observer wiring

    private var observerToken: NSObjectProtocol?
    public private(set) var isObserving: Bool = false

    public init() {
        self.cancelFn = { id in
            _ = try await CursorRuntime.shared.agentCancel(id: id)
        }
        self.runningStatesProvider = {
            CursorAgentRegistry.shared.runningStates
        }
    }

    /// Begin observing `.cursorAgentCostCapTripped`. Idempotent.
    public func start() {
        guard !isObserving else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .cursorAgentCostCapTripped,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable primitives inside the observer (runs on main),
            // so the non-Sendable Notification never crosses isolation.
            let tier = note.userInfo?["tier"] as? String ?? ""
            MainActor.assumeIsolated {
                self?.handleCapTripped(tier: tier, at: Date())
            }
        }
        observerToken = token
        isObserving = true
    }

    /// Stop observing. Idempotent.
    public func stop() {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
        observerToken = nil
        isObserving = false
    }

    // MARK: Public handler (also exposed for direct test invocation)

    /// Process a cap-tripped event. Public so tests can invoke directly without
    /// going through NotificationCenter (the W3 dispatcher follows the same pattern).
    public func handleCapTripped(tier: String, at: Date = Date()) {
        switch tier {
        case "soft":
            pausedAt = at
            cancelRunning(cloudOnly: true)
        case "hard":
            lockedAt = at
            // Hard implies the soft pause condition is also true.
            if pausedAt == nil { pausedAt = at }
            cancelRunning(cloudOnly: false)
        default:
            // "under" or unknown — no-op.
            break
        }
    }

    /// Manual override: clears pause + lock. Intended for admin / test use, or
    /// the daily midnight rollover when callers want to reset without restart.
    public func unlock() {
        pausedAt = nil
        lockedAt = nil
    }

    // MARK: Cancellation fan-out

    private func cancelRunning(cloudOnly: Bool) {
        let targets = runningStatesProvider().filter { state in
            cloudOnly ? state.run.runtime == .cloud : true
        }
        guard !targets.isEmpty else { return }
        let cancel = cancelFn
        for state in targets {
            let runId = state.run.id
            Task {
                do {
                    try await cancel(runId)
                } catch {
                    // Runtime cancellation is best-effort; swallow + log so
                    // banner state stays correct if the sidecar/API rejects.
                    print("[CursorAutoPause] cancel failed for \(runId): \(error)")
                }
            }
        }
    }
}
