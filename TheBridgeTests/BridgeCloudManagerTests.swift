// BridgeCloudManagerTests.swift — WS-C + WS-E (Mac-side cloud access)
// TheBridge · Tests (custom harness — no XCTest; see main.swift)
//
// Covers the auth-passdown seam (NL-3) end-to-end against fakes — no real
// cloudflared, no Secure Enclave, no network:
//
//   • CloudConnectionState machine driven off the fake TunnelProcess:
//     disabled → connecting → online; start-failure → offline;
//     online ⇄ degraded as health flaps; disable → disabled.
//   • Delegated-capability validation: rejects expired / out-of-scope /
//     wrong-owner / wrong-device / over-TTL / revoked; accepts a valid one.
//   • Passkey gate: denied ⇒ blocked (no authorize); approved ⇒ proceeds.
//     A rejected capability must NEVER reach the passkey gate.
//   • No-raw-credential invariant: the value crossing toward execution
//     (CloudExecutionRequest) carries no secret; the capability has no
//     credential field; the fake gate only ever sees the credential-free
//     request.
//   • WS-E: the Remote Access section + the new sidebar enum case
//     instantiate and carry a header preset (no missing switch case).

import Foundation
import SwiftUI
import TheBridgeLib

// Deterministic fixtures (no clock, no network).
private let cloudNow = Date(timeIntervalSince1970: 1_700_000_000)
private let cloudNode = LocalNodeContext(ownerID: "owner-1", deviceID: "device-A")

private func makeCapability(
    ownerID: String = "owner-1",
    deviceID: String = "device-A",
    connectionID: String = "conn-1",
    operation: String = "post_invoice",
    paramsHash: String = "ph-1",
    jti: String = "jti-1",
    issuedAt: Date = cloudNow,
    ttl: TimeInterval = 60
) -> DelegatedCapability {
    DelegatedCapability(
        ownerID: ownerID, deviceID: deviceID, connectionID: connectionID,
        operation: operation, paramsHash: paramsHash, jti: jti,
        issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(ttl)
    )
}

private func matchingScope(
    connectionID: String = "conn-1",
    operation: String = "post_invoice",
    paramsHash: String = "ph-1"
) -> CapabilityScope {
    CapabilityScope(connectionID: connectionID, operation: operation, paramsHash: paramsHash)
}

func runBridgeCloudManagerTests() async {
    print("\n\u{2601} BridgeCloudManager / Auth-Passdown Tests (WS-C + WS-E)")

    // MARK: - CloudConnectionState machine (fake TunnelProcess)

    await test("Cloud: default state is .disabled") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(), passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow }
        )
        let s = await mgr.state
        try expect(s == .disabled, "expected .disabled, got \(s)")
    }

    await test("Cloud: enable with a healthy tunnel → .online") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow }
        )
        let s = await mgr.enable()
        try expect(s == .online, "expected .online after healthy enable, got \(s)")
    }

    await test("Cloud: enable when the tunnel fails to start → .offline") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: false),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow }
        )
        let s = await mgr.enable()
        try expect(s == .offline, "start-failure must land .offline, got \(s)")
    }

    await test("Cloud: impaired transport health drives .degraded; recovery → .online") {
        let tunnel = FakeTunnelProcess(startSucceeds: true, health: .healthy)
        let mgr = BridgeCloudManager(
            tunnel: tunnel, passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow }
        )
        _ = await mgr.enable()
        await tunnel.setHealth(.impaired)
        let degraded = await mgr.refreshHealth()
        try expect(degraded == .degraded, "impaired health must be .degraded, got \(degraded)")
        await tunnel.setHealth(.healthy)
        let online = await mgr.refreshHealth()
        try expect(online == .online, "recovered health must be .online, got \(online)")
    }

    await test("Cloud: disable stops the tunnel and returns to .disabled") {
        let tunnel = FakeTunnelProcess(startSucceeds: true, health: .healthy)
        let mgr = BridgeCloudManager(
            tunnel: tunnel, passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow }
        )
        _ = await mgr.enable()
        let s = await mgr.disable()
        try expect(s == .disabled, "disable must land .disabled, got \(s)")
        try expect(await tunnel.isRunning() == false, "tunnel must be stopped after disable")
    }

    // MARK: - Capability validation (accept + reject matrix)

    let validator = DelegatedCapabilityValidator()

    await test("Capability: a fully-matching capability is accepted (credential-free request)") {
        let result = validator.validate(
            makeCapability(), for: cloudNode,
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(10)
        )
        guard case .valid(let req) = result else {
            throw TestError.assertion("valid capability must accept, got \(result)")
        }
        try expect(req.ownerID == "owner-1" && req.deviceID == "device-A", "request identity must echo the node binding")
        try expect(req.scope == matchingScope(), "request scope must match the capability scope")
    }

    await test("Capability: expired capability is rejected (.expired)") {
        let result = validator.validate(
            makeCapability(ttl: 60), for: cloudNode,
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(120)
        )
        guard case .rejected(.expired) = result else {
            throw TestError.assertion("expired capability must reject .expired, got \(result)")
        }
    }

    await test("Capability: wrong-owner capability is rejected (.ownerMismatch)") {
        let result = validator.validate(
            makeCapability(ownerID: "owner-2"), for: cloudNode,
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(10)
        )
        guard case .rejected(.ownerMismatch) = result else {
            throw TestError.assertion("wrong owner must reject .ownerMismatch, got \(result)")
        }
    }

    await test("Capability: wrong-device capability is rejected (.deviceMismatch)") {
        let result = validator.validate(
            makeCapability(deviceID: "device-B"), for: cloudNode,
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(10)
        )
        guard case .rejected(.deviceMismatch) = result else {
            throw TestError.assertion("wrong device must reject .deviceMismatch, got \(result)")
        }
    }

    await test("Capability: out-of-scope request is rejected (.scopeMismatch)") {
        let result = validator.validate(
            makeCapability(operation: "post_invoice"), for: cloudNode,
            requestedScope: matchingScope(operation: "delete_everything"),
            now: cloudNow.addingTimeInterval(10)
        )
        guard case .rejected(.scopeMismatch) = result else {
            throw TestError.assertion("out-of-scope must reject .scopeMismatch, got \(result)")
        }
    }

    await test("Capability: an over-TTL capability is rejected (.ttlExceedsCeiling)") {
        let result = validator.validate(
            makeCapability(ttl: 600), for: cloudNode,   // 10 min > 120s ceiling
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(10)
        )
        guard case .rejected(.ttlExceedsCeiling) = result else {
            throw TestError.assertion("over-TTL capability must reject .ttlExceedsCeiling, got \(result)")
        }
    }

    await test("Capability: a revoked jti is rejected (.revoked)") {
        let result = validator.validate(
            makeCapability(jti: "jti-bad"), for: cloudNode,
            requestedScope: matchingScope(), now: cloudNow.addingTimeInterval(10),
            revokedJTIs: ["jti-bad"]
        )
        guard case .rejected(.revoked) = result else {
            throw TestError.assertion("revoked jti must reject .revoked, got \(result)")
        }
    }

    // MARK: - Passkey gate: denied ⇒ blocked, approved ⇒ proceeds

    await test("Passkey: denied gate blocks execution (no authorize), gate WAS consulted") {
        let gate = FakePasskeyGate(outcome: .denied)
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: gate, node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()
        let decision = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(), requestedScope: matchingScope()
        )
        guard case .refused(.passkeyGate(.denied)) = decision else {
            throw TestError.assertion("denied passkey must refuse, got \(decision)")
        }
        try expect(await gate.assertionCount() == 1, "the passkey gate must have been consulted exactly once")
    }

    await test("Passkey: approved gate proceeds to an authorized credential-free request") {
        let gate = FakePasskeyGate(outcome: .approved)
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: gate, node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()
        let decision = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(), requestedScope: matchingScope()
        )
        guard case .authorized(let req) = decision else {
            throw TestError.assertion("approved passkey + valid cap must authorize, got \(decision)")
        }
        try expect(req.jti == "jti-1", "authorized request must carry the capability jti")
    }

    await test("Passkey: an unavailable authenticator fails closed (.passkeyGate(.unavailable))") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: FakePasskeyGate(outcome: .unavailable),
            node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()
        let decision = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(), requestedScope: matchingScope()
        )
        guard case .refused(.passkeyGate(.unavailable)) = decision else {
            throw TestError.assertion("unavailable authenticator must fail closed, got \(decision)")
        }
    }

    await test("AuthPassdown: a REJECTED capability never reaches the passkey gate") {
        let gate = FakePasskeyGate(outcome: .approved)
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: gate, node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()
        // Wrong owner ⇒ capability rejected upstream of the gate.
        let decision = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(ownerID: "intruder"), requestedScope: matchingScope()
        )
        guard case .refused(.capabilityRejected(.ownerMismatch)) = decision else {
            throw TestError.assertion("bad capability must be refused before the gate, got \(decision)")
        }
        try expect(await gate.assertionCount() == 0, "the passkey gate must NOT run for a rejected capability (no UI prompt)")
    }

    await test("AuthPassdown: an offline manager refuses delegated execution (.notOnline)") {
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: false),
            passkeyGate: FakePasskeyGate(outcome: .approved),
            node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()   // lands .offline
        let decision = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(), requestedScope: matchingScope()
        )
        guard case .refused(.notOnline(.offline)) = decision else {
            throw TestError.assertion("offline manager must refuse .notOnline, got \(decision)")
        }
    }

    await test("AuthPassdown: a consumed jti cannot be replayed (single-use)") {
        let gate = FakePasskeyGate(outcome: .approved)
        let mgr = BridgeCloudManager(
            tunnel: FakeTunnelProcess(startSucceeds: true, health: .healthy),
            passkeyGate: gate, node: cloudNode, now: { cloudNow.addingTimeInterval(10) }
        )
        _ = await mgr.enable()
        let first = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(jti: "once"), requestedScope: matchingScope()
        )
        guard case .authorized = first else {
            throw TestError.assertion("first redemption must authorize, got \(first)")
        }
        let replay = await mgr.authorizeDelegatedExecution(
            capability: makeCapability(jti: "once"), requestedScope: matchingScope()
        )
        guard case .refused(.capabilityRejected(.revoked)) = replay else {
            throw TestError.assertion("a consumed jti must be rejected on replay, got \(replay)")
        }
    }

    // MARK: - No raw credential reaches the cloud-facing path (D3)

    await test("NoCredentialLeak: the cloud-facing execution request carries no secret material") {
        // Reflect over CloudExecutionRequest's fields; assert none of them
        // is, or could hold, a raw credential. The type is intentionally
        // limited to identity + scope + jti.
        let req = CloudExecutionRequest(
            ownerID: "owner-1", deviceID: "device-A",
            scope: matchingScope(), jti: "jti-1"
        )
        let mirror = Mirror(reflecting: req)
        let fieldNames = Set(mirror.children.compactMap(\.label))
        try expect(fieldNames == ["ownerID", "deviceID", "scope", "jti"],
                   "CloudExecutionRequest gained an unexpected field (possible secret leak): \(fieldNames)")
        // Defensive: no field name hints at credential material.
        for name in fieldNames {
            let lower = name.lowercased()
            try expect(!lower.contains("secret") && !lower.contains("token")
                       && !lower.contains("credential") && !lower.contains("password")
                       && !lower.contains("key"),
                       "CloudExecutionRequest field '\(name)' looks credential-bearing")
        }
    }

    await test("NoCredentialLeak: the delegated capability itself carries no credential field") {
        let cap = makeCapability()
        let mirror = Mirror(reflecting: cap)
        let fieldNames = Set(mirror.children.compactMap(\.label))
        // The capability is an authorization-to-ask, never the secret.
        try expect(fieldNames == [
            "ownerID", "deviceID", "connectionID", "operation",
            "paramsHash", "jti", "issuedAt", "expiresAt",
        ], "DelegatedCapability gained an unexpected field (possible secret leak): \(fieldNames)")
        for name in fieldNames {
            let lower = name.lowercased()
            try expect(!lower.contains("secret") && !lower.contains("credential")
                       && !lower.contains("password") && !lower.contains("accesstoken"),
                       "DelegatedCapability field '\(name)' looks credential-bearing")
        }
    }

    // MARK: - WS-E → PKT-A: Remote Access folded into Connection

    await test("PKT-A: Remote Access folds into the merged Connection section") {
        // The standalone .remoteAccess sidebar case was retired in the 10→7
        // redesign; Remote Access is now a sub-area of Connection. The merged
        // Connection section exists with a fully-populated header preset...
        try expect(SettingsSection.allCases.contains(.connection),
                   "the sidebar enum must include .connection")
        try expect(SettingsSection.connection.rawValue == "Connection",
                   "raw value drift: \(SettingsSection.connection.rawValue)")
        try expect(!SettingsSection.connection.icon.isEmpty, "connection must have a sidebar icon")
        try expect(BridgeSectionIcon.systemImage(for: .connection) == "network",
                   "connection SF Symbol drift")
        let spec = BridgeSettingsHeaderPreset.spec(for: .connection)
        try expect(!spec.title.isEmpty && !spec.subtitle.isEmpty && !spec.systemImage.isEmpty,
                   "connection header preset must be fully populated")
        // ...and the retired "Remote Access" name still resolves (back-compat)
        // to Connection on the `remote` anchor (market safety, spec V2).
        let resolved = await MainActor.run {
            BridgeSettingsAutomation.resolveSectionWithAnchor("Remote Access")
        }
        try expect(resolved?.section == .connection,
                   "legacy 'Remote Access' must resolve to .connection")
        try expect(resolved?.anchor == "remote",
                   "legacy 'Remote Access' must anchor 'remote', got \(String(describing: resolved?.anchor))")
    }

    await test("WS-E: RemoteAccessSection instantiates for each display state") {
        let names = await MainActor.run { () -> [String] in
            let disabled = RemoteAccessSection(displayState: .disabled)
            let online = RemoteAccessSection(displayState: .online)
            let degraded = RemoteAccessSection(displayState: .degraded)
            return [disabled, online, degraded].map { String(describing: type(of: $0)) }
        }
        for name in names {
            try expect(name == "RemoteAccessSection", "unexpected section type: \(name)")
        }
    }
}
