// BridgeCloudManager.swift — WS-C (Mac-side cloud access)
// NotionBridge · Modules · Cloud
//
// The Mac-side coordinator for Bridge Cloud Access. Owns two things:
//
//   1. The cloudflared tunnel LIFECYCLE + a `CloudConnectionState` state
//      machine (disabled → connecting → online/offline; online ⇄ degraded
//      as transport health flaps). The tunnel is reached only through the
//      injectable `TunnelProcess` seam so this whole actor is unit-testable
//      with a fake (no real cloudflared, no network).
//
//   2. The AUTH-PASSDOWN enforcement point for a cloud-originated request
//      that needs local execution (NL-3 steps 6–8): it (a) validates the
//      delegated capability locally (short-lived, scoped, owner-bound,
//      device-bound) and ONLY THEN (b) enforces the mandatory local
//      passkey gate BEFORE anything downstream may read the Keychain /
//      client credential. Either step failing ⇒ fail closed. The value it
//      hands downstream (`CloudExecutionRequest`) carries NO credential
//      material — upholding D3 ("raw client creds never leave the Mac /
//      never reach the cloud-facing path").
//
// An `actor` so tunnel state and the in-flight `jti` set are race-free.

import Foundation

/// Connection state of Bridge Cloud Access, as a strict machine.
///
///   .disabled    — cloud access off (default). No tunnel.
///   .connecting  — tunnel start in progress.
///   .online      — tunnel up + transport healthy; ready to accept
///                  delegated requests.
///   .degraded    — tunnel up but transport impaired; still "on" but
///                  not fully healthy (NL-3 channel heartbeat missed).
///   .offline     — tunnel start failed or dropped while enabled.
public enum CloudConnectionState: String, Sendable, Equatable {
    case disabled
    case connecting
    case online
    case degraded
    case offline
}

/// Why a cloud-delegated local execution was refused at the Mac. Wraps the
/// two fail-closed gates (capability validation + passkey) plus the
/// not-online guard, so a caller/audit can see exactly which boundary
/// stopped the request. NONE of these branches ever reaches Keychain.
public enum CloudDelegationRefusal: Sendable, Equatable {
    /// Cloud access is not online (disabled/connecting/offline) — a
    /// delegated request cannot be served. (Degraded is allowed: the
    /// channel is up, just impaired.)
    case notOnline(CloudConnectionState)
    /// The delegated capability failed local validation (expired,
    /// out-of-scope, wrong owner/device, revoked, …).
    case capabilityRejected(CapabilityRejection)
    /// The capability validated but the mandatory passkey gate did not
    /// approve (denied / unavailable) — D-NL3.5 fail-closed.
    case passkeyGate(PasskeyGateOutcome)
}

/// Outcome of attempting to admit a cloud-delegated request for local
/// execution. `.authorized` carries the credential-FREE execution request
/// that downstream Keychain-resolution code consumes; `.refused` carries
/// the boundary that fired. Reaching `.authorized` is the ONLY path that
/// permits a subsequent Keychain read.
public enum CloudDelegationDecision: Sendable, Equatable {
    case authorized(CloudExecutionRequest)
    case refused(CloudDelegationRefusal)
}

public actor BridgeCloudManager {

    // MARK: Dependencies (all injected — fakes in tests)

    private let tunnel: TunnelProcess
    private let passkeyGate: PasskeyGate
    private let validator: DelegatedCapabilityValidator
    private let node: LocalNodeContext
    /// Injectable clock so capability freshness is deterministic in tests.
    private let now: @Sendable () -> Date

    // MARK: State

    private(set) public var state: CloudConnectionState = .disabled
    /// Local `jti` denylist (D-NL3.7) + consumed-token set. A capability
    /// whose `jti` is here is rejected as revoked/replayed.
    private var revokedJTIs: Set<String> = []

    public init(
        tunnel: TunnelProcess,
        passkeyGate: PasskeyGate,
        node: LocalNodeContext,
        validator: DelegatedCapabilityValidator = DelegatedCapabilityValidator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tunnel = tunnel
        self.passkeyGate = passkeyGate
        self.node = node
        self.validator = validator
        self.now = now
    }

    // MARK: - Tunnel lifecycle / state machine

    /// Enable Bridge Cloud Access: transition disabled/offline →
    /// connecting, start the tunnel, then resolve to online/degraded
    /// (start succeeded) or offline (start failed). Idempotent when already
    /// online/degraded.
    @discardableResult
    public func enable() async -> CloudConnectionState {
        if state == .online || state == .degraded { return state }
        state = .connecting
        do {
            try await tunnel.start()
            await refreshHealth()
        } catch {
            state = .offline
        }
        return state
    }

    /// Disable Bridge Cloud Access: stop the tunnel and return to
    /// `.disabled`. Safe to call from any state (a not-running stop is
    /// swallowed — the end state is still `.disabled`).
    @discardableResult
    public func disable() async -> CloudConnectionState {
        try? await tunnel.stop()
        state = .disabled
        return state
    }

    /// Re-probe transport health and reconcile the state machine. Only
    /// meaningful while "on": maps healthy→online, impaired→degraded,
    /// down→offline. No-op when `.disabled` (an explicitly-off manager
    /// stays off).
    @discardableResult
    public func refreshHealth() async -> CloudConnectionState {
        guard state != .disabled else { return state }
        switch await tunnel.health() {
        case .healthy:  state = .online
        case .impaired: state = .degraded
        case .down:     state = .offline
        }
        return state
    }

    // MARK: - Revocation (D-NL3.7)

    /// Add a `jti` to the local denylist (revocation / mark-consumed).
    public func revoke(jti: String) {
        revokedJTIs.insert(jti)
    }

    // MARK: - Auth-passdown enforcement (NL-3 steps 6–8)

    /// Admit (or refuse) a cloud-delegated request for LOCAL execution.
    ///
    /// Enforcement order is strict and fail-closed:
    ///   0. Cloud must be online or degraded (channel up). Otherwise refuse
    ///      — a request cannot be served with no channel.
    ///   1. Validate the capability locally (owner, device, freshness,
    ///      TTL ceiling, revocation, scope). Any failure ⇒ refuse, and the
    ///      passkey gate is NEVER consulted (no UI prompt for a bogus cap).
    ///   2. Enforce the mandatory passkey gate (D-NL3.5). Only `.approved`
    ///      proceeds; denied/unavailable ⇒ refuse, fail closed.
    ///
    /// Only `.authorized` is returned when BOTH gates pass — and only that
    /// value (which holds NO credential) is permitted to flow toward
    /// Keychain resolution. This method itself never touches the Keychain
    /// or any client credential.
    ///
    /// - Parameters:
    ///   - capability: the cloud-minted delegated capability as received.
    ///   - requestedScope: the scope of the operation actually requested —
    ///     must match the capability's scope.
    public func authorizeDelegatedExecution(
        capability: DelegatedCapability,
        requestedScope: CapabilityScope
    ) async -> CloudDelegationDecision {
        // 0. Channel must be up.
        guard state == .online || state == .degraded else {
            return .refused(.notOnline(state))
        }

        // 1. Local capability validation — fail closed, no passkey prompt
        //    on rejection.
        let validation = validator.validate(
            capability,
            for: node,
            requestedScope: requestedScope,
            now: now(),
            revokedJTIs: revokedJTIs
        )
        let executionRequest: CloudExecutionRequest
        switch validation {
        case .rejected(let reason):
            return .refused(.capabilityRejected(reason))
        case .valid(let req):
            executionRequest = req
        }

        // 2. Mandatory passkey gate BEFORE any Keychain access (D-NL3.5).
        let gate = await passkeyGate.assert(for: executionRequest)
        guard gate == .approved else {
            return .refused(.passkeyGate(gate))
        }

        // Both gates passed. Consume the jti (single-use, D-NL3.7) and
        // emit the credential-free execution request.
        revokedJTIs.insert(executionRequest.jti)
        return .authorized(executionRequest)
    }
}
