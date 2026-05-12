// CursorHeartbeatWatchdog.swift — PKT-3.4.2 Wave 5a (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Periodic timer that escalates the health of registered Cursor agents based
// on how long it has been since their last heartbeat (last SSE event). When
// PKT-3.4.1.W2 wires the real SSE stream, `CursorAgentRegistry.touch(id:at:)`
// will fire on every event; this watchdog catches the absence of those events
// and escalates the row's `healthLevel` per the original packet spec:
//
//   silent for ≥ yellowThreshold (default 5 min) → `.yellow`
//   silent for ≥ redThreshold    (default 10 min) → `.red`
//
// The registry's `setHealth(.red, for:)` automatically posts the
// `.cursorAgentDidStall` notification (Wave 2 / Wave 3 contract) which the
// notification dispatcher then renders as `CURSOR_AGENT_STALLED`.
//
// Uses `DispatchSource.makeTimerSource(queue: .main)` so the tick handler runs
// on the main actor without crossing a Sendable boundary (we `assumeIsolated`
// inside the handler). Idempotent `start()` / `stop()`.

import Foundation

@MainActor
public final class CursorHeartbeatWatchdog {

    public static let shared = CursorHeartbeatWatchdog()

    // MARK: - Config

    /// Seconds of silence before escalating a healthy row to yellow.
    public var yellowThresholdSeconds: TimeInterval = 5 * 60

    /// Seconds of silence before escalating a row to red (also posts cursorAgentDidStall).
    public var redThresholdSeconds: TimeInterval = 10 * 60

    /// How often the watchdog wakes up to re-evaluate.
    public var tickIntervalSeconds: TimeInterval = 30

    // MARK: - State

    private var timer: DispatchSourceTimer?
    private let registry: CursorAgentRegistry

    public init(registry: CursorAgentRegistry = .shared) {
        self.registry = registry
    }

    public var isRunning: Bool { timer != nil }

    // MARK: - Lifecycle

    /// Start the periodic watchdog. Idempotent — safe to call multiple times.
    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + tickIntervalSeconds,
            repeating: tickIntervalSeconds,
            leeway: .seconds(5)
        )
        t.setEventHandler {
            // Timer is scheduled on .main, so we are on the main thread here.
            MainActor.assumeIsolated {
                CursorHeartbeatWatchdog.shared.tick(now: Date())
            }
        }
        t.resume()
        timer = t
        print("[CursorHeartbeatWatchdog] Started (yellow=\(Int(yellowThresholdSeconds))s, red=\(Int(redThresholdSeconds))s, tick=\(Int(tickIntervalSeconds))s)")
    }

    /// Stop the watchdog. Idempotent.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Tick

    /// Single tick — evaluate all registered states and escalate as needed.
    /// Exposed `public` so tests can drive synthetic ticks deterministically.
    public func tick(now: Date = Date()) {
        let states = registry.allStates
        for state in states {
            // Only escalate active agents — succeeded/failed/cancelled rows are terminal.
            switch state.run.status {
            case .running, .queued:
                break
            case .succeeded, .failed, .cancelled, .unknown:
                continue
            }
            let silentFor = now.timeIntervalSince(state.lastHeartbeat)
            if silentFor >= redThresholdSeconds {
                if state.healthLevel != .red {
                    registry.setHealth(.red, for: state.run.id)
                }
            } else if silentFor >= yellowThresholdSeconds {
                if state.healthLevel == .healthy {
                    registry.setHealth(.yellow, for: state.run.id)
                }
            }
        }
    }
}
