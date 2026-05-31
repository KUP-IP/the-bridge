// DelegatedCapability.swift — WS-C (Mac-side cloud access · auth-passdown)
// NotionBridge · Modules · Cloud
//
// The Mac-side validation half of the NL-3 cloud→Mac delegation protocol
// (docs/neutral-layer/NL-3-cloud-mac-delegation-authpassdown.md). The
// cloud control plane MINTS a short-lived, scoped, owner-bound,
// device-bound capability (NL-3 step 4); this file models that capability
// as it arrives at the Mac and the local VALIDATOR that the Mac runs
// before it will touch any Keychain item or client credential
// (NL-3 step 6).
//
// Hard invariants enforced here (from NL-3 / Decision D3):
//   • A capability carries NO raw credential material — it is an
//     *authorization to ask the Mac to act*, never the secret itself
//     (D-NL3.3). `DelegatedCapability` has no field that can hold a
//     client secret, and `CloudExecutionRequest` (the value that crosses
//     toward execution) is asserted credential-free by the manager.
//   • Validation rejects expired, out-of-scope, and wrong-owner /
//     wrong-device capabilities and accepts only a fully matching one
//     (D-NL3.4, D-NL3.6, step 6). Every negative branch fails closed.
//   • Validation success is necessary but NOT sufficient: the passkey
//     gate (see CloudPasskeyGate) still runs before Keychain access
//     (D-NL3.5). That ordering is owned by BridgeCloudManager.
//
// Pure value + protocol logic — no cloudflared, no network, no Keychain —
// so the whole surface is unit-testable headlessly.

import Foundation

// MARK: - Capability model

/// A short-lived, scoped, owner-bound, device-bound capability minted by
/// the cloud control plane authorizing exactly ONE local operation against
/// ONE connection on ONE device (NL-3 step 4).
///
/// Deliberately contains **no credential field**: per D-NL3.3 the raw
/// Tier-1 client credential is resolved only on the Mac, from Keychain,
/// after the passkey gate — it is never transmitted in, referenced by, or
/// derivable from this token. The cloud-facing path therefore *cannot*
/// carry a secret even by mistake.
public struct DelegatedCapability: Sendable, Equatable {
    /// Stable owner principal (IdP subject / `owner_id`). The capability is
    /// bound to whoever the cloud authenticated; client-app identity is
    /// never substituted for this (D-NL3.2).
    public let ownerID: String
    /// Audience: the specific Mac node `device_id` this capability is for
    /// (`aud`). A capability minted for device A is unusable on device B
    /// (D-NL3.4).
    public let deviceID: String
    /// The connection this capability authorizes touching (e.g. a client's
    /// Stripe connection id).
    public let connectionID: String
    /// The single operation authorized (e.g. "post_invoice").
    public let operation: String
    /// Hash of the bound request parameters — ties the capability to one
    /// concrete call so it cannot be re-aimed at a different payload.
    public let paramsHash: String
    /// Unique token id (`jti`) for replay defense / denylist (D-NL3.7).
    public let jti: String
    /// Issued-at instant (`iat`).
    public let issuedAt: Date
    /// Expiry instant (`exp`). Per D-NL3.6 the cloud sets TTL ≤ 120s; the
    /// Mac additionally enforces a hard ceiling at validation time.
    public let expiresAt: Date

    public init(
        ownerID: String,
        deviceID: String,
        connectionID: String,
        operation: String,
        paramsHash: String,
        jti: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.ownerID = ownerID
        self.deviceID = deviceID
        self.connectionID = connectionID
        self.operation = operation
        self.paramsHash = paramsHash
        self.jti = jti
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// The (connection, operation, params) tuple this capability is scoped
    /// to. Compared structurally against the operation actually requested.
    public var scope: CapabilityScope {
        CapabilityScope(
            connectionID: connectionID,
            operation: operation,
            paramsHash: paramsHash
        )
    }
}

/// The scope triple a capability authorizes. The requested operation must
/// match this exactly (NL-3 step 6: "`scope` matches the requested
/// operation + `params_hash`").
public struct CapabilityScope: Sendable, Equatable, Hashable {
    public let connectionID: String
    public let operation: String
    public let paramsHash: String

    public init(connectionID: String, operation: String, paramsHash: String) {
        self.connectionID = connectionID
        self.operation = operation
        self.paramsHash = paramsHash
    }
}

// MARK: - Local execution context

/// The identity + scope context the Mac validates a capability against.
/// Built from THIS device's registered identity and the operation the Mac
/// was actually asked to perform — never from caller-supplied fields.
public struct LocalNodeContext: Sendable, Equatable {
    /// The owner this Mac node belongs to.
    public let ownerID: String
    /// This device's `device_id`.
    public let deviceID: String

    public init(ownerID: String, deviceID: String) {
        self.ownerID = ownerID
        self.deviceID = deviceID
    }
}

/// The credential-free request value that crosses toward local execution
/// AFTER a capability is validated and the passkey gate passes. It names
/// what to do — never how to authenticate. There is intentionally no field
/// that can carry a client secret (D-NL3.3): the secret is resolved from
/// Keychain in-process, downstream of this value.
public struct CloudExecutionRequest: Sendable, Equatable {
    public let ownerID: String
    public let deviceID: String
    public let scope: CapabilityScope
    public let jti: String

    public init(ownerID: String, deviceID: String, scope: CapabilityScope, jti: String) {
        self.ownerID = ownerID
        self.deviceID = deviceID
        self.scope = scope
        self.jti = jti
    }
}

// MARK: - Validation outcome

/// Why a delegated capability was rejected at the Mac. Machine-readable so
/// the manager can branch + audit distinctly. Every case is a fail-closed
/// branch (NL-3 step 6).
public enum CapabilityRejection: String, Sendable, Equatable {
    case expired
    case notYetValid
    case ttlExceedsCeiling      // minted with a TTL above the local hard ceiling
    case ownerMismatch          // sub != this node's owner
    case deviceMismatch         // aud != this device_id
    case scopeMismatch          // requested operation/connection/params != capability scope
    case revoked                // jti present in the local denylist
}

public enum CapabilityValidation: Sendable, Equatable {
    case valid(CloudExecutionRequest)
    case rejected(CapabilityRejection)
}

// MARK: - Validator

/// Validates a delegated capability locally on the Mac before ANY Keychain
/// / client-credential access (NL-3 step 6). Pure and deterministic: the
/// "now" instant and the revoked-`jti` set are injected so every branch is
/// unit-testable without a clock or network.
///
/// Order of checks is fail-closed and independent — any single failure
/// rejects with a specific reason and no execution request is produced.
public struct DelegatedCapabilityValidator: Sendable {

    /// Hard local ceiling on capability lifetime, independent of whatever
    /// TTL the cloud claims. NL-3 D-NL3.6 sets the cloud TTL ≤ 120s; the
    /// Mac refuses to honor anything minted with a longer window so a
    /// misbehaving/compromised control plane can't widen the replay
    /// surface.
    public static let maxTTL: TimeInterval = 120

    public init() {}

    /// Validate `capability` for `node` against the operation actually
    /// requested (`requestedScope`).
    ///
    /// - Parameters:
    ///   - capability: the cloud-minted token as received.
    ///   - node: this Mac node's verified owner + device identity.
    ///   - requestedScope: the scope of the operation the Mac was asked to
    ///     run — must match the capability's scope exactly.
    ///   - now: current instant (injectable for tests).
    ///   - revokedJTIs: the local `jti` denylist (D-NL3.7).
    /// - Returns: `.valid(CloudExecutionRequest)` only when owner, device,
    ///   scope, freshness, and revocation ALL pass; otherwise
    ///   `.rejected(reason)`.
    public func validate(
        _ capability: DelegatedCapability,
        for node: LocalNodeContext,
        requestedScope: CapabilityScope,
        now: Date,
        revokedJTIs: Set<String> = []
    ) -> CapabilityValidation {
        // 1. Owner binding (D-NL3.2). A capability for another owner can
        //    never act through this node.
        guard capability.ownerID == node.ownerID else {
            return .rejected(.ownerMismatch)
        }
        // 2. Device binding (D-NL3.4). aud must be THIS device.
        guard capability.deviceID == node.deviceID else {
            return .rejected(.deviceMismatch)
        }
        // 3. Revocation (D-NL3.7) — jti denylist checked before honoring.
        guard !revokedJTIs.contains(capability.jti) else {
            return .rejected(.revoked)
        }
        // 4. Minted-TTL ceiling (D-NL3.6). Reject a token whose own
        //    iat→exp window exceeds the local hard ceiling, regardless of
        //    current time.
        let mintedTTL = capability.expiresAt.timeIntervalSince(capability.issuedAt)
        guard mintedTTL <= Self.maxTTL else {
            return .rejected(.ttlExceedsCeiling)
        }
        // 5. Not-yet-valid guard (clock skew / future-dated iat).
        guard now >= capability.issuedAt else {
            return .rejected(.notYetValid)
        }
        // 6. Freshness (D-NL3.6 / step 6). exp must not have passed.
        guard now < capability.expiresAt else {
            return .rejected(.expired)
        }
        // 7. Scope match (step 6). The requested operation must be exactly
        //    the one the capability authorizes.
        guard capability.scope == requestedScope else {
            return .rejected(.scopeMismatch)
        }
        // All checks passed — emit the credential-free execution request.
        return .valid(
            CloudExecutionRequest(
                ownerID: capability.ownerID,
                deviceID: capability.deviceID,
                scope: capability.scope,
                jti: capability.jti
            )
        )
    }
}
