// LicenseManagerTests.swift — PKT-909 (Sell/Distribute v3 · 1)
//
// Coverage:
//   W1 — LicenseToken: encode/decode round-trip, signature accept,
//         tamper-detect (payload, signature), wrong-key reject, malformed
//         payload reject, schema-version reject.
//   W2 — LicenseManager: fresh-install seeds firstLaunchAt; trial day
//         math (29 / 1 / 0=expired); grandfather sentinel triggers
//         grandfathered:true (THE SAFETY TEST); grandfather sticky
//         across loadOrInit calls; paid activation flips status to
//         licensed; deactivate goes back to trial; license.json round-
//         trips on disk; loadOrInit idempotent.
//   W5 — BridgeToolError.trialExpired is constructible + carries the
//         tool name.

import Foundation
import CryptoKit
import NotionBridgeLib

// MARK: - Test fixture helpers

/// Sandbox HOME for a single test. The default homeRoot override is
/// per-process; tests serialise their use here.
@discardableResult
private func withTempHome(_ body: (URL) async throws -> Void) async throws -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-licensetest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body(tmp)
    return tmp
}

private func makeKey() -> (priv: Curve25519.Signing.PrivateKey, pub: Curve25519.Signing.PublicKey) {
    let p = Curve25519.Signing.PrivateKey()
    return (p, p.publicKey)
}

private func samplePayload(exp: Int64? = nil, kind: String = "paid") -> LicenseTokenPayload {
    return LicenseTokenPayload(
        id: "ord_test_001",
        sub: "tester@example.com",
        kind: kind,
        iat: 1_700_000_000,
        exp: exp
    )
}

// MARK: - W1 — LicenseToken tests

func runLicenseTokenTests() async {
    print("\n\u{1F511} PKT-909 W1 LicenseToken (Ed25519)")

    await test("LicenseTokenPayload: canonical JSON has sorted keys") {
        // Use a non-nil exp so the field is emitted (Optional.none is
        // omitted by JSONEncoder, which is fine — we just need a
        // multi-field payload to assert ordering).
        let p = samplePayload(exp: 1_800_000_000)
        let s = String(data: try p.canonicalJSON(), encoding: .utf8) ?? ""
        // sortedKeys produces alphabetical: exp,iat,id,kind,sub,v
        try expect(s.contains("\"exp\":1800000000"), "missing exp in canonical output: \(s)")
        if let expIdx = s.range(of: "\"exp\""),
           let iatIdx = s.range(of: "\"iat\"") {
            try expect(expIdx.lowerBound < iatIdx.lowerBound, "sortedKeys did not emit exp before iat")
        }
        // Canonical encoding determinism: two encodings produce
        // byte-identical output.
        let a = try p.canonicalJSON()
        let b = try p.canonicalJSON()
        try expect(a == b, "canonicalJSON not deterministic")
    }

    await test("LicenseTokenPayload: validate accepts a well-formed payload") {
        try samplePayload().validate()
    }

    await test("LicenseTokenPayload: validate rejects unsupported version") {
        let p = LicenseTokenPayload(v: 999, id: "x", sub: "y", kind: "paid", iat: 1, exp: nil)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .unsupportedVersion(let n) = e { try expect(n == 999) }
            else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("LicenseTokenPayload: validate rejects bad kind") {
        let p = LicenseTokenPayload(id: "x", sub: "y", kind: "free", iat: 1, exp: nil)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .malformed = e { /* ok */ } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("LicenseTokenPayload: validate rejects exp < iat") {
        let p = LicenseTokenPayload(id: "x", sub: "y", kind: "paid", iat: 100, exp: 50)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .malformed = e { /* ok */ } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("LicenseToken: encode + verify round-trip succeeds") {
        let (priv, pub) = makeKey()
        let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
        let parsed = try LicenseToken.verify(token, publicKey: pub)
        try expect(parsed.id == "ord_test_001")
        try expect(parsed.sub == "tester@example.com")
        try expect(parsed.kind == "paid")
    }

    await test("LicenseToken: verify rejects payload tampering") {
        let (priv, pub) = makeKey()
        let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
        // Flip one character in the payload half (before the '.')
        let dot = token.firstIndex(of: ".")!
        var arr = Array(token)
        let i = token.distance(from: token.startIndex, to: dot) - 1
        // Replace last char of payload with a different char (still
        // base64url-legal) — the signature is now over a different bytestring.
        arr[i] = (arr[i] == "A") ? "B" : "A"
        let tampered = String(arr)
        do {
            _ = try LicenseToken.verify(tampered, publicKey: pub)
            throw TestError.assertion("tampered token verified — should not have")
        } catch let e as LicenseVerifyError {
            // Either bad signature (most likely) OR malformed if the
            // flipped char decoded to invalid JSON. Both are correct
            // "reject" outcomes.
            switch e {
            case .badSignature, .malformed, .invalidBase64: break
            default: throw TestError.assertion("wrong reject reason: \(e)")
            }
        }
    }

    await test("LicenseToken: verify rejects signature tampering") {
        let (priv, pub) = makeKey()
        let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
        let dot = token.firstIndex(of: ".")!
        let i = token.index(after: dot)
        var arr = Array(token)
        let idx = token.distance(from: token.startIndex, to: i)
        arr[idx] = (arr[idx] == "A") ? "B" : "A"
        let tampered = String(arr)
        do {
            _ = try LicenseToken.verify(tampered, publicKey: pub)
            throw TestError.assertion("tampered signature verified — should not have")
        } catch is LicenseVerifyError { /* ok */ }
    }

    await test("LicenseToken: verify rejects wrong key") {
        let (priv, _) = makeKey()
        let (_, otherPub) = makeKey()
        let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
        do {
            _ = try LicenseToken.verify(token, publicKey: otherPub)
            throw TestError.assertion("verified under wrong key")
        } catch LicenseVerifyError.badSignature { /* ok */ }
    }

    await test("LicenseToken: verify rejects malformed (no dot)") {
        let (_, pub) = makeKey()
        do {
            _ = try LicenseToken.verify("nodothere", publicKey: pub)
            throw TestError.assertion("expected throw")
        } catch let e as LicenseVerifyError {
            if case .malformed = e { /* ok */ } else { throw TestError.assertion("wrong: \(e)") }
        }
    }

    await test("LicenseToken: verify rejects invalid base64") {
        let (_, pub) = makeKey()
        do {
            _ = try LicenseToken.verify("!!!.@@@", publicKey: pub)
            throw TestError.assertion("expected throw")
        } catch LicenseVerifyError.invalidBase64 { /* ok */ }
    }

    await test("LicenseToken: base64url round-trip preserves bytes (incl. unpadded)") {
        // 1 byte → needs 2 padding chars in standard base64; base64url
        // strips them. Round-trip must restore.
        let data = Data([0xFE])
        let s = LicenseToken.base64url(data)
        try expect(!s.contains("="))
        let back = LicenseToken.base64urlDecode(s)
        try expect(back == data)
    }

    // STATE codable round-trip
    await test("LicenseState: Codable round-trip preserves all fields") {
        let s = LicenseState(
            firstLaunchAt: 1_700_000_000,
            token: LicenseState.StoredToken(raw: "raw.token", payload: samplePayload(exp: 1_800_000_000)),
            trialExpiredAcknowledged: true,
            grandfathered: false
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(s)
        let dec = JSONDecoder()
        let back = try dec.decode(LicenseState.self, from: data)
        try expect(back == s)
    }

    await test("LicenseState: decode is forwards-tolerant with missing optional fields") {
        // No trialExpiredAcknowledged, no grandfathered, no token, no version
        let json = #"{"firstLaunchAt":1700000000}"#.data(using: .utf8)!
        let dec = JSONDecoder()
        let s = try dec.decode(LicenseState.self, from: json)
        try expect(s.firstLaunchAt == 1_700_000_000)
        try expect(s.token == nil)
        try expect(s.trialExpiredAcknowledged == false)
        try expect(s.grandfathered == false)
        try expect(s.version == LicenseState.currentVersion)
    }
}

// MARK: - W2 — LicenseManager + trial timer + grandfather

func runLicenseManagerTests() async {
    print("\n\u{1F4C5} PKT-909 W2 LicenseManager (trial timer + grandfather)")

    // Pure derivation tests (no disk / actor)
    await test("Pure: fresh trial at t=0 → 30 days remaining") {
        let s = LicenseState(firstLaunchAt: 0)
        let status = LicenseManager.computeStatus(state: s) { Date(timeIntervalSince1970: 0) }
        if case .trial(let days) = status {
            try expect(days == 30, "expected 30 got \(days)")
        } else { throw TestError.assertion("expected .trial got \(status)") }
    }

    await test("Pure: trial at t=29d+23h59m → 1 day remaining (ceil floor=1)") {
        let s = LicenseState(firstLaunchAt: 0)
        // 1 second before 30d boundary
        let oneSecBefore = Date(timeIntervalSince1970: TimeInterval(LicenseManager.trialDuration - 1))
        let status = LicenseManager.computeStatus(state: s) { oneSecBefore }
        if case .trial(let days) = status {
            try expect(days == 1, "expected 1 got \(days)")
        } else { throw TestError.assertion("expected .trial got \(status)") }
    }

    await test("Pure: trial at t=exactly 30d → .trialExpired (inclusive boundary)") {
        let s = LicenseState(firstLaunchAt: 0)
        let endsAt = Date(timeIntervalSince1970: TimeInterval(LicenseManager.trialDuration))
        let status = LicenseManager.computeStatus(state: s) { endsAt }
        if case .trialExpired = status { /* ok */ }
        else { throw TestError.assertion("expected .trialExpired got \(status)") }
    }

    await test("Pure: grandfathered state → .grandfathered regardless of token") {
        let s = LicenseState(firstLaunchAt: 0, grandfathered: true)
        let status = LicenseManager.computeStatus(state: s) { Date() }
        if case .grandfathered = status { /* ok */ }
        else { throw TestError.assertion("expected .grandfathered got \(status)") }
    }

    await test("Pure: licensed token without exp → .licensed perpetually") {
        let s = LicenseState(
            firstLaunchAt: 0,
            token: LicenseState.StoredToken(raw: "x.y", payload: samplePayload(exp: nil))
        )
        let status = LicenseManager.computeStatus(state: s) { Date(timeIntervalSince1970: 9_999_999_999) }
        if case .licensed = status { /* ok */ }
        else { throw TestError.assertion("expected .licensed got \(status)") }
    }

    await test("Pure: licensed token with elapsed exp → .licenseExpired") {
        let s = LicenseState(
            firstLaunchAt: 0,
            token: LicenseState.StoredToken(raw: "x.y", payload: samplePayload(exp: 1_700_000_000))
        )
        let status = LicenseManager.computeStatus(state: s) { Date(timeIntervalSince1970: 1_800_000_000) }
        if case .licenseExpired = status { /* ok */ }
        else { throw TestError.assertion("expected .licenseExpired got \(status)") }
    }

    await test("Status: pill labels are non-empty + correct shape") {
        try expect(LicenseStatus.trial(daysRemaining: 7).pillLabel == "Trial — 7 days left")
        try expect(LicenseStatus.trial(daysRemaining: 1).pillLabel == "Trial — 1 day left")
        try expect(LicenseStatus.trialExpired.pillLabel == "Trial expired")
        try expect(LicenseStatus.grandfathered.pillLabel == "Licensed (3.x)")
    }

    await test("Status.isActive: trial+licensed+grandfathered → true; expired → false") {
        try expect(LicenseStatus.trial(daysRemaining: 1).isActive)
        try expect(LicenseStatus.licensed(payload: samplePayload()).isActive)
        try expect(LicenseStatus.grandfathered.isActive)
        try expect(!LicenseStatus.trialExpired.isActive)
        try expect(!LicenseStatus.licenseExpired(payload: samplePayload()).isActive)
    }

    // Disk I/O + actor tests
    try? await withTempHome { _ in
        await test("Disk: loadOrInit on fresh dir creates license.json + .trial") {
            try BridgePaths.ensureApplicationSupport()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { now }
            let status = try await mgr.loadOrInit()
            if case .trial = status { /* ok */ }
            else { throw TestError.assertion("expected .trial got \(status)") }
            try expect(FileManager.default.fileExists(atPath: LicenseManager.fileURL().path),
                       "license.json was not created")
            // Disk state reflects what we hold in memory
            let onDisk = LicenseManager.loadFromDisk { now }
            try expect(onDisk?.firstLaunchAt == 1_700_000_000)
            try expect(onDisk?.grandfathered == false)
        }
    }

    // CRITICAL SAFETY TEST — grandfather sentinel
    try? await withTempHome { _ in
        await test("SAFETY: PathMigration sentinel present → grandfathered:true on loadOrInit") {
            try BridgePaths.ensureApplicationSupport()
            // Plant the sentinel BEFORE loadOrInit
            let sentinelURL = BridgePaths.applicationSupport.appendingPathComponent(PathMigration.sentinelName)
            try "v3.5 done".write(to: sentinelURL, atomically: true, encoding: .utf8)
            try expect(LicenseManager.migrationSentinelExists())

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { now }
            let status = try await mgr.loadOrInit()

            if case .grandfathered = status { /* ok */ }
            else { throw TestError.assertion("SAFETY CONTRACT VIOLATED: expected .grandfathered but got \(status)") }

            // Inspect the on-disk state — grandfathered MUST be persisted
            let onDisk = LicenseManager.loadFromDisk { now }
            try expect(onDisk?.grandfathered == true,
                       "SAFETY CONTRACT VIOLATED: grandfathered not persisted")
        }
    }

    try? await withTempHome { _ in
        await test("SAFETY: grandfathered state is sticky across loadOrInit calls") {
            try BridgePaths.ensureApplicationSupport()
            let sentinelURL = BridgePaths.applicationSupport.appendingPathComponent(PathMigration.sentinelName)
            try "v3.5 done".write(to: sentinelURL, atomically: true, encoding: .utf8)

            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { Date() }
            _ = try await mgr.loadOrInit()

            // Now delete the sentinel and call loadOrInit again — the
            // user must remain grandfathered (sticky).
            try FileManager.default.removeItem(at: sentinelURL)
            let mgr2 = LicenseManager(publicKey: pub) { Date() }
            let status = try await mgr2.loadOrInit()
            if case .grandfathered = status { /* ok */ }
            else { throw TestError.assertion("SAFETY CONTRACT VIOLATED: grandfathered not sticky — became \(status)") }
        }
    }

    try? await withTempHome { _ in
        await test("Fresh install (no sentinel) → trial NOT grandfathered") {
            try BridgePaths.ensureApplicationSupport()
            try expect(!LicenseManager.migrationSentinelExists())
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { now }
            let status = try await mgr.loadOrInit()
            if case .trial = status { /* ok */ }
            else { throw TestError.assertion("expected .trial got \(status)") }
            let onDisk = LicenseManager.loadFromDisk { now }
            try expect(onDisk?.grandfathered == false)
        }
    }

    try? await withTempHome { _ in
        await test("Activate: paste valid token → .licensed + persisted") {
            try BridgePaths.ensureApplicationSupport()
            let (priv, pub) = makeKey()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let mgr = LicenseManager(publicKey: pub) { now }
            _ = try await mgr.loadOrInit()
            let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)

            let status = try await mgr.activate(token: token)
            if case .licensed(let p) = status {
                try expect(p.id == "ord_test_001")
            } else { throw TestError.assertion("expected .licensed got \(status)") }

            // Persisted
            let onDisk = LicenseManager.loadFromDisk { now }
            try expect(onDisk?.token?.payload.id == "ord_test_001")
        }
    }

    try? await withTempHome { _ in
        await test("Activate: pasted-token signed by WRONG key throws + does NOT mutate state") {
            try BridgePaths.ensureApplicationSupport()
            let (wrongPriv, _)  = makeKey()
            let (_, correctPub) = makeKey()
            let mgr = LicenseManager(publicKey: correctPub) { Date() }
            _ = try await mgr.loadOrInit()
            let token = try LicenseToken.encode(payload: samplePayload(), signedBy: wrongPriv)

            do {
                _ = try await mgr.activate(token: token)
                throw TestError.assertion("activate accepted token signed by wrong key")
            } catch LicenseVerifyError.badSignature { /* ok */ }

            let pre = await mgr.currentState()
            try expect(pre.token == nil, "state was mutated despite bad signature")
        }
    }

    try? await withTempHome { _ in
        await test("Deactivate: licensed → no token; status returns to trial/expired") {
            try BridgePaths.ensureApplicationSupport()
            let (priv, pub) = makeKey()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let mgr = LicenseManager(publicKey: pub) { now }
            _ = try await mgr.loadOrInit()
            let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
            _ = try await mgr.activate(token: token)

            let after = try await mgr.deactivate()
            if case .trial = after { /* ok */ }
            else { throw TestError.assertion("expected .trial after deactivate got \(after)") }
            let post = await mgr.currentState()
            try expect(post.token == nil)
        }
    }

    try? await withTempHome { _ in
        await test("loadOrInit idempotent: calling twice does not bump firstLaunchAt") {
            try BridgePaths.ensureApplicationSupport()
            let t1 = Date(timeIntervalSince1970: 1_700_000_000)
            let t2 = Date(timeIntervalSince1970: 1_700_000_500)   // 500s later
            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { t1 }
            _ = try await mgr.loadOrInit()
            // Simulate a relaunch with a fresh actor and a different clock
            let mgr2 = LicenseManager(publicKey: pub) { t2 }
            _ = try await mgr2.loadOrInit()
            let onDisk = LicenseManager.loadFromDisk { t2 }
            try expect(onDisk?.firstLaunchAt == Int64(t1.timeIntervalSince1970),
                       "firstLaunchAt was bumped on a second load — trial would restart")
        }
    }

    try? await withTempHome { _ in
        await test("Activate clears trialExpiredAcknowledged flag") {
            try BridgePaths.ensureApplicationSupport()
            let (priv, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { Date() }
            _ = try await mgr.loadOrInit()
            try await mgr.acknowledgeTrialExpired()
            try expect(await mgr.currentState().trialExpiredAcknowledged == true)
            let token = try LicenseToken.encode(payload: samplePayload(), signedBy: priv)
            _ = try await mgr.activate(token: token)
            try expect(await mgr.currentState().trialExpiredAcknowledged == false)
        }
    }

    try? await withTempHome { _ in
        await test("Factory reset removes license.json") {
            try BridgePaths.ensureApplicationSupport()
            let (_, pub) = makeKey()
            let mgr = LicenseManager(publicKey: pub) { Date() }
            _ = try await mgr.loadOrInit()
            try expect(FileManager.default.fileExists(atPath: LicenseManager.fileURL().path))
            try await mgr.factoryReset()
            try expect(!FileManager.default.fileExists(atPath: LicenseManager.fileURL().path))
        }
    }
}

// MARK: - W5 — Trial-expired dispatch gate (end-to-end)

func runLicenseDispatchGateTests() async {
    print("\n\u{1F50C} PKT-909 W5 ToolRouter trial-gate")

    // Build a minimal router with one trivial tool. The license provider
    // is the seam — we drive trial-active vs trial-expired without
    // touching LicenseManager.shared.
    func build(provider: @escaping ToolRouter.LicenseStatusProvider) async -> ToolRouter {
        let gate = SecurityGate()
        let log  = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log, licenseStatusProvider: provider)
        await router.register(ToolRegistration(
            name: "test_noop",
            module: "test",
            tier: .open,
            neverAutoApprove: false,
            description: "noop for tests",
            inputSchema: .object([:]),
            handler: { _ in .object(["ok": .bool(true)]) }
        ))
        return router
    }

    await test("Dispatch: trial-active → handler runs (returns ok:true)") {
        let router = await build { .trial(daysRemaining: 5) }
        let r = try await router.dispatch(toolName: "test_noop", arguments: .object([:]))
        if case .object(let dict) = r, case .bool(let ok) = dict["ok"] ?? .null {
            try expect(ok)
        } else { throw TestError.assertion("expected ok:true got \(r)") }
    }

    await test("Dispatch: trial-expired → throws BridgeToolError.trialExpired(trial-expired)") {
        let router = await build { .trialExpired }
        do {
            _ = try await router.dispatch(toolName: "test_noop", arguments: .object([:]))
            throw TestError.assertion("dispatch returned successfully under expired trial")
        } catch let err as BridgeToolError {
            if case .trialExpired(let name, let kind) = err {
                try expect(name == "test_noop")
                try expect(kind == "trial-expired")
            } else {
                throw TestError.assertion("wrong BridgeToolError case: \(err)")
            }
        }
    }

    await test("Dispatch: license-expired → throws BridgeToolError.trialExpired(license-expired)") {
        let payload = LicenseTokenPayload(id: "x", sub: "y", kind: "paid", iat: 1, exp: 2)
        let router = await build { .licenseExpired(payload: payload) }
        do {
            _ = try await router.dispatch(toolName: "test_noop", arguments: .object([:]))
            throw TestError.assertion("dispatch returned successfully under expired license")
        } catch let err as BridgeToolError {
            if case .trialExpired(_, let kind) = err {
                try expect(kind == "license-expired",
                           "expected 'license-expired' kind, got '\(kind)'")
            } else {
                throw TestError.assertion("wrong BridgeToolError case: \(err)")
            }
        }
    }

    await test("Dispatch: grandfathered → handler runs (SAFETY CONTRACT)") {
        let router = await build { .grandfathered }
        let r = try await router.dispatch(toolName: "test_noop", arguments: .object([:]))
        if case .object = r { /* ok */ }
        else { throw TestError.assertion("expected object got \(r)") }
    }

    await test("Dispatch: licensed → handler runs") {
        let payload = LicenseTokenPayload(id: "x", sub: "y", kind: "paid", iat: 1, exp: nil)
        let router = await build { .licensed(payload: payload) }
        let r = try await router.dispatch(toolName: "test_noop", arguments: .object([:]))
        if case .object = r { /* ok */ }
        else { throw TestError.assertion("expected object got \(r)") }
    }
}

// MARK: - W5 — BridgeToolError.trialExpired

func runLicenseToolErrorTests() async {
    print("\n\u{1F6AB} PKT-909 W5 BridgeToolError.trialExpired")

    await test("BridgeToolError.trialExpired: carries tool name + kind") {
        let err: BridgeToolError = .trialExpired(toolName: "messages_send", kind: "trial-expired")
        if case .trialExpired(let name, let kind) = err {
            try expect(name == "messages_send")
            try expect(kind == "trial-expired")
        } else { throw TestError.assertion("pattern mismatch") }
    }

    await test("BridgeToolError.trialExpired: errorDescription is non-empty + names tool") {
        let err: BridgeToolError = .trialExpired(toolName: "shell_exec", kind: "trial-expired")
        let s = err.errorDescription ?? ""
        try expect(s.contains("shell_exec"))
        try expect(s.contains("trial"))
    }

    await test("BridgeToolError.trialExpired: Equatable distinguishes kind") {
        let a: BridgeToolError = .trialExpired(toolName: "x", kind: "trial-expired")
        let b: BridgeToolError = .trialExpired(toolName: "x", kind: "license-expired")
        try expect(a != b)
    }
}
