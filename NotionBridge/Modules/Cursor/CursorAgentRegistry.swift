// CursorAgentRegistry.swift — PKT-3.4.2 Wave 2 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Observable in-memory registry of active + recently-completed Cursor agent
// runs. Single source of truth for the menu bar pill, the (Wave 3) notification
// dispatcher, the (Wave 4) standalone CursorAgentsWindow, and the (Wave 5)
// heartbeat watchdog.
//
// Architecture: `@MainActor` `ObservableObject` with `@Published` state so
// SwiftUI views can observe directly. NotificationCenter `cursorAgentStateDidChange`
// is posted on every mutation so non-SwiftUI consumers (AppKit, notification
// dispatcher) can subscribe without holding an ObservedObject reference.
//
// Wave 2 (this packet) ships the data + observability surface. The real event
// source — SSE-style `CursorEvent` stream from `CursorRuntime` — lands in
// PKT-3.4.1.W2 (sidecar @cursor/sdk wiring) and PKT-774 Wave 5 (event →
// `upsert(...)` adapter + heartbeat watchdog scan).

import Foundation
#if canImport(Combine)
import Combine
#endif

// MARK: - State

/// Snapshot of one tracked Cursor agent run plus health metadata.
public struct CursorAgentRegistryState: Sendable, Equatable, Identifiable {
    public var id: String { run.id }
    public let run: CursorRun
    /// Timestamp of the most recent SSE event for this run (or upsert time).
    /// Used by the Wave 5 watchdog to escalate silent runs.
    public let lastHeartbeat: Date
    /// Heartbeat-watchdog health.
    public let healthLevel: HealthLevel
    /// Most recent error message, if any (cleared on successful state transition).
    public let lastErrorMessage: String?

    public enum HealthLevel: String, Codable, Sendable, CaseIterable {
        /// Heartbeat fresh (< N minutes since last event).
        case healthy
        /// No event for ≥ N minutes — row turns yellow.
        case yellow
        /// No event for ≥ 2N minutes — row turns red, dispatcher emits CURSOR_AGENT_STALLED.
        case red
    }

    public init(
        run: CursorRun,
        lastHeartbeat: Date = Date(),
        healthLevel: HealthLevel = .healthy,
        lastErrorMessage: String? = nil
    ) {
        self.run = run
        self.lastHeartbeat = lastHeartbeat
        self.healthLevel = healthLevel
        self.lastErrorMessage = lastErrorMessage
    }
}

// MARK: - Counts

/// Compact summary used by the menu bar pill.
public struct CursorAgentCounts: Sendable, Equatable {
    public let running: Int
    public let ready: Int
    public let error: Int

    public init(running: Int = 0, ready: Int = 0, error: Int = 0) {
        self.running = running
        self.ready = ready
        self.error = error
    }

    public var total: Int { running + ready + error }
    public var anyActive: Bool { total > 0 }
}

// MARK: - Registry

@MainActor
public final class CursorAgentRegistry: ObservableObject {

    // MARK: Singleton

    public static let shared = CursorAgentRegistry()

    // MARK: Published state

    /// Keyed by `CursorRun.id`. SwiftUI observers re-render on any mutation.
    @Published public private(set) var states: [String: CursorAgentRegistryState] = [:]

    // MARK: Init

    public init() {}

    // MARK: Read API

    /// All currently-tracked runs, sorted newest-started first.
    public var allStates: [CursorAgentRegistryState] {
        states.values.sorted { $0.run.startedAt > $1.run.startedAt }
    }

    /// Active runs (status .running or .queued).
    public var runningStates: [CursorAgentRegistryState] {
        allStates.filter { $0.run.status == .running || $0.run.status == .queued }
    }

    /// Recently-completed runs (succeeded).
    public var readyStates: [CursorAgentRegistryState] {
        allStates.filter { $0.run.status == .succeeded }
    }

    /// Runs in an error state (failed, cancelled, or watchdog .red).
    public var errorStates: [CursorAgentRegistryState] {
        allStates.filter {
            $0.run.status == .failed
                || $0.run.status == .cancelled
                || $0.healthLevel == .red
        }
    }

    /// Compact counts used by the menu bar pill.
    public var counts: CursorAgentCounts {
        var r = 0, w = 0, e = 0
        for s in states.values {
            if s.healthLevel == .red {
                e += 1
                continue
            }
            switch s.run.status {
            case .running, .queued:
                r += 1
            case .succeeded:
                w += 1
            case .failed, .cancelled:
                e += 1
            case .unknown:
                break
            }
        }
        return CursorAgentCounts(running: r, ready: w, error: e)
    }

    public func state(for id: String) -> CursorAgentRegistryState? {
        states[id]
    }

    // MARK: Write API

    /// Insert or update a run. Heartbeat defaults to now. Resets health to .healthy
    /// (the watchdog will re-escalate as needed). Clears `lastErrorMessage` unless
    /// the run status is .failed.
    public func upsert(_ run: CursorRun, heartbeatAt: Date = Date()) {
        let prior = states[run.id]
        let errorMsg: String? = (run.status == .failed) ? prior?.lastErrorMessage : nil
        let newState = CursorAgentRegistryState(
            run: run,
            lastHeartbeat: heartbeatAt,
            healthLevel: .healthy,
            lastErrorMessage: errorMsg
        )
        states[run.id] = newState
        postStateChange(runId: run.id, status: run.status)
    }

    /// Bump only the heartbeat timestamp (called when a non-status SSE event arrives).
    /// Resets health to .healthy. No-op if the run is unknown.
    public func touch(id: String, at: Date = Date()) {
        guard var s = states[id] else { return }
        s = CursorAgentRegistryState(
            run: s.run,
            lastHeartbeat: at,
            healthLevel: .healthy,
            lastErrorMessage: s.lastErrorMessage
        )
        states[id] = s
        postStateChange(runId: id, status: s.run.status)
    }

    /// Record an error message against an existing run. Does not change run status
    /// (caller should follow with `upsert(...)` to set status=.failed).
    public func recordError(id: String, message: String, at: Date = Date()) {
        guard var s = states[id] else { return }
        s = CursorAgentRegistryState(
            run: s.run,
            lastHeartbeat: at,
            healthLevel: s.healthLevel,
            lastErrorMessage: message
        )
        states[id] = s
        postStateChange(runId: id, status: s.run.status)
    }

    /// Set the heartbeat-watchdog health level for a run.
    /// Wave 5 watchdog calls this and (at .red) the dispatcher emits CURSOR_AGENT_STALLED.
    public func setHealth(_ level: CursorAgentRegistryState.HealthLevel, for id: String) {
        guard var s = states[id] else { return }
        guard s.healthLevel != level else { return }
        s = CursorAgentRegistryState(
            run: s.run,
            lastHeartbeat: s.lastHeartbeat,
            healthLevel: level,
            lastErrorMessage: s.lastErrorMessage
        )
        states[id] = s
        postStateChange(runId: id, status: s.run.status)
        if level == .red {
            let silentFor = Int(Date().timeIntervalSince(s.lastHeartbeat))
            NotificationCenter.default.post(
                name: .cursorAgentDidStall,
                object: nil,
                userInfo: [
                    "runId": id,
                    "level": level.rawValue,
                    "silentForSeconds": silentFor
                ]
            )
        }
    }

    public func remove(id: String) {
        guard let s = states.removeValue(forKey: id) else { return }
        postStateChange(runId: id, status: s.run.status)
    }

    /// Test-only / admin-only reset.
    public func clear() {
        let ids = Array(states.keys)
        states.removeAll()
        for id in ids {
            postStateChange(runId: id, status: .unknown)
        }
    }

    // MARK: Private

    private func postStateChange(runId: String, status: CursorRunStatus) {
        NotificationCenter.default.post(
            name: .cursorAgentStateDidChange,
            object: nil,
            userInfo: [
                "runId": runId,
                "status": status.rawValue
            ]
        )
    }
}
