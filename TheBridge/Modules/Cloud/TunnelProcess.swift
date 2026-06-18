// TunnelProcess.swift — WS-C (Mac-side cloud access)
// TheBridge · Modules · Cloud
//
// The injectable seam for the cloudflared tunnel binary. NL-2 / NL-3
// describe a persistent outbound connection FROM the Mac that the control
// plane delivers capabilities over (NL-3 step 5: "the established
// control-plane↔node channel … persistent outbound connection from the
// Mac"). BridgeCloudManager owns the lifecycle of that channel through
// this protocol so it never references the real `cloudflared` process in
// code that needs to be unit-tested — tests inject a fake that drives
// start/stop/health deterministically (no real cloudflared, no network).

import Foundation

/// Health of the underlying tunnel transport as last observed.
public enum TunnelHealth: Sendable, Equatable {
    /// Not started / fully stopped.
    case down
    /// Process up and the channel is established + reachable.
    case healthy
    /// Process up but the channel is impaired (e.g. heartbeat missed) —
    /// drives `CloudConnectionState.degraded`.
    case impaired
}

/// Errors a tunnel lifecycle operation can surface.
public enum TunnelError: Error, Sendable, Equatable {
    /// The tunnel failed to come up (binary missing, auth failed, etc.).
    case failedToStart(String)
    /// A stop was requested on a tunnel that was not running.
    case notRunning
}

/// Lifecycle + health interface for the Mac↔cloud tunnel. The production
/// conformer wraps the `cloudflared` process; tests use `FakeTunnelProcess`.
/// An actor so concurrent start/stop/health calls are serialized.
public protocol TunnelProcess: Sendable {
    /// Bring the tunnel up. Throws `TunnelError.failedToStart` on failure.
    func start() async throws
    /// Tear the tunnel down. Throws `TunnelError.notRunning` if it wasn't up.
    func stop() async throws
    /// Probe current transport health (does not change state).
    func health() async -> TunnelHealth
}

/// Deterministic in-memory tunnel for tests. Scripted to start
/// successfully or fail, and to report a chosen health, so every
/// `CloudConnectionState` transition can be exercised without cloudflared.
public actor FakeTunnelProcess: TunnelProcess {
    private var running = false
    private let startSucceeds: Bool
    private var reportedHealth: TunnelHealth

    /// - Parameters:
    ///   - startSucceeds: whether `start()` brings the tunnel up or throws.
    ///   - health: the health reported once running (default `.healthy`).
    public init(startSucceeds: Bool = true, health: TunnelHealth = .healthy) {
        self.startSucceeds = startSucceeds
        self.reportedHealth = health
    }

    public func start() async throws {
        guard startSucceeds else {
            throw TunnelError.failedToStart("fake tunnel scripted to fail")
        }
        running = true
    }

    public func stop() async throws {
        guard running else { throw TunnelError.notRunning }
        running = false
    }

    public func health() async -> TunnelHealth {
        running ? reportedHealth : .down
    }

    /// Test seam: flip the reported health of an already-running tunnel to
    /// drive the degraded/recovered transitions.
    public func setHealth(_ health: TunnelHealth) {
        reportedHealth = health
    }

    public func isRunning() -> Bool { running }
}
