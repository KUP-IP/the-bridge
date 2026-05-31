// CloudPasskeyGate.swift — WS-C (Mac-side cloud access · auth-passdown)
// NotionBridge · Modules · Cloud
//
// The mandatory local passkey gate from NL-3 D-NL3.5 / step 7: AFTER a
// delegated capability validates, the Mac requires a fresh local passkey
// (platform authenticator / Secure Enclave, e.g. Touch ID) assertion
// BEFORE it reads the Keychain item or uses the client credential.
// Validation-passes-but-no-passkey ⇒ NO Keychain read, request fails
// closed.
//
// The real platform-authenticator assertion (LocalAuthentication /
// AuthenticationServices) is the live-only ceiling; this module defines
// the injectable `PasskeyGate` protocol so BridgeCloudManager depends on
// the seam, and tests inject a fake that approves/denies deterministically
// — no Secure Enclave, no UI.

import Foundation

/// Why a passkey gate did not let an operation proceed. Machine-readable
/// so the manager can fail closed with a specific, auditable reason.
public enum PasskeyGateOutcome: Sendable, Equatable {
    /// A fresh assertion succeeded (or one within the freshness window was
    /// reused, D-NL3.6) — proceed to Keychain access.
    case approved
    /// The user denied / cancelled the assertion — fail closed, no
    /// Keychain read.
    case denied
    /// The local authenticator is unavailable / errored — fail closed.
    case unavailable
}

/// Mac-local passkey gate. The control plane authorizes *what* may run;
/// this gate is where the human at the Mac authorizes *that it runs now*
/// (D-NL3.5). A valid capability alone is never sufficient to touch a
/// Tier-1 secret — `assert(...)` must return `.approved` first.
public protocol PasskeyGate: Sendable {
    /// Request a fresh local passkey assertion for `request`. Returns the
    /// outcome; the caller MUST treat anything other than `.approved` as
    /// fail-closed (no Keychain access).
    func assert(for request: CloudExecutionRequest) async -> PasskeyGateOutcome
}

/// A deterministic in-memory passkey gate for tests and headless flows.
/// Records every assertion it was asked for so tests can prove the gate
/// was actually consulted (and consulted with the right, credential-free
/// request).
public actor FakePasskeyGate: PasskeyGate {
    private let outcome: PasskeyGateOutcome
    private(set) public var assertedRequests: [CloudExecutionRequest] = []

    public init(outcome: PasskeyGateOutcome) {
        self.outcome = outcome
    }

    public func assert(for request: CloudExecutionRequest) async -> PasskeyGateOutcome {
        assertedRequests.append(request)
        return outcome
    }

    /// Number of times the gate was asked to assert — lets a test prove
    /// the gate ran (denied path) or did NOT run (e.g. capability rejected
    /// upstream so the gate must never be reached).
    public func assertionCount() -> Int { assertedRequests.count }
}
