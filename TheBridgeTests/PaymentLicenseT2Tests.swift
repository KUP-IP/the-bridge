// PaymentLicenseT2Tests.swift — PKT-1014 (T2 coverage sweep)
// TheBridge · Tests
//
// Comprehensive coverage sweep over:
//   A — Stripe checkout/payment-link edge cases and error envelope
//   B — LicenseManager + LicenseToken extended edge cases
//   C — LicenseRevocationClient extended coverage
//   D — LicenseUIState/LicenseCard headless behavior
//   E — LicenseStatus property coverage
//   F — LicenseCardHost pure state transitions (no AppKit)
//   G — BridgeCheckout URL / metadata completeness
//
// All tests are headless (no network, no Keychain write, no AppKit launch).
// Stripe calls go through a URLProtocol stub; revocation calls go through
// the LicenseRevocationTransport stub already proven in
// LicenseRevocationTests.swift.

import Foundation
import CryptoKit
import TheBridgeLib

// MARK: - Shared fixtures

private func makePaidPayload(
    id: String = "ord_t2",
    sub: String = "t2@example.com",
    iat: Int64 = 1_700_000_000,
    exp: Int64? = nil
) -> LicenseTokenPayload {
    LicenseTokenPayload(id: id, sub: sub, kind: "paid", iat: iat, exp: exp)
}

private func makeKeyPair() -> (priv: Curve25519.Signing.PrivateKey, pub: Curve25519.Signing.PublicKey) {
    let p = Curve25519.Signing.PrivateKey()
    return (p, p.publicKey)
}

// MARK: - A — Stripe extended edge cases

// URLProtocol stub reused across Stripe sub-tests; registered/unregistered
// per function to avoid cross-test state.
private final class T2StripeMock: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let err = Self.error {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let h = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try h(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() { handler = nil; error = nil }
}

private func makeT2Session() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [T2StripeMock.self]
    return URLSession(configuration: cfg)
}

private func t2Response(url: URL = URL(string: "https://api.stripe.com/v1/x")!, code: Int, json: String) -> (HTTPURLResponse, Data) {
    let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    return (r, Data(json.utf8))
}

func runPaymentLicenseT2Tests() async {
    print("\n\u{1F9EA} PKT-1014 T2 — Stripe/License/UI coverage sweep")

    // ─── A: Stripe edge cases ─────────────────────────────────────────────

    await test("Stripe A1: createPaymentIntent rejects zero amount before network") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { _ in throw TestError.assertion("network must NOT be called for zero amount") }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "sk_test" })
        do {
            _ = try await client.createPaymentIntent(amount: 0, currency: "usd",
                paymentMethod: "pm_x", idempotencyKey: "k1", description: nil, metadata: nil)
            throw TestError.assertion("expected invalidAmount")
        } catch let e as StripeError {
            if case .invalidAmount = e { } else { throw TestError.assertion("expected .invalidAmount, got \(e)") }
        }
    }

    await test("Stripe A2: createPaymentIntent rejects missing idempotency key") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { _ in throw TestError.assertion("network must NOT be called") }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "sk_test" })
        do {
            _ = try await client.createPaymentIntent(amount: 100, currency: "usd",
                paymentMethod: "pm_x", idempotencyKey: "   ", description: nil, metadata: nil)
            throw TestError.assertion("expected missingIdempotencyKey")
        } catch let e as StripeError {
            if case .missingIdempotencyKey = e { } else { throw TestError.assertion("expected .missingIdempotencyKey, got \(e)") }
        }
    }

    await test("Stripe A3: empty API key throws authenticationFailed before network") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { _ in throw TestError.assertion("network must NOT be called") }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "   " })
        do {
            _ = try await client.createPaymentIntent(amount: 100, currency: "usd",
                paymentMethod: "pm_x", idempotencyKey: "k1", description: nil, metadata: nil)
            throw TestError.assertion("expected authenticationFailed")
        } catch let e as StripeError {
            if case .authenticationFailed = e { } else { throw TestError.assertion("expected .authenticationFailed, got \(e)") }
        }
    }

    await test("Stripe A4: nil API key throws authenticationFailed") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { _ in throw TestError.assertion("network must NOT be called") }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { nil })
        do {
            _ = try await client.createPaymentIntent(amount: 100, currency: "usd",
                paymentMethod: "pm_x", idempotencyKey: "k1", description: nil, metadata: nil)
            throw TestError.assertion("expected authenticationFailed")
        } catch let e as StripeError {
            if case .authenticationFailed = e { } else { throw TestError.assertion("expected .authenticationFailed, got \(e)") }
        }
    }

    await test("Stripe A5: retrievePaymentIntent parses a well-formed response") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { req in
            try expect(req.url?.absoluteString.contains("payment_intents/pi_retrieve_01") == true)
            let json = #"{"id":"pi_retrieve_01","amount":5000,"currency":"usd","status":"requires_capture","created":1700000000}"#
            return t2Response(url: req.url!, code: 200, json: json)
        }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "sk_test" })
        let r = try await client.retrievePaymentIntent(id: "pi_retrieve_01")
        try expect(r.id == "pi_retrieve_01")
        try expect(r.amount == 5000)
        try expect(r.status == "requires_capture")
    }

    await test("Stripe A6: parseStripeError maps 401 to authenticationFailed") {
        let err = StripeClient.parseStripeError(statusCode: 401, data: Data())
        if case .authenticationFailed = err { } else { throw TestError.assertion("expected .authenticationFailed, got \(err)") }
    }

    await test("Stripe A7: parseStripeError maps 403 to authenticationFailed") {
        let err = StripeClient.parseStripeError(statusCode: 403, data: Data())
        if case .authenticationFailed = err { } else { throw TestError.assertion("expected .authenticationFailed, got \(err)") }
    }

    await test("Stripe A8: parseStripeError maps 500 with no JSON to processingError") {
        let err = StripeClient.parseStripeError(statusCode: 500, data: Data("<html>".utf8))
        if case .processingError = err { } else { throw TestError.assertion("expected .processingError, got \(err)") }
    }

    await test("Stripe A9: parseStripeError maps insufficient_funds code explicitly") {
        let json = #"{"error":{"type":"card_error","code":"insufficient_funds","message":"Declined"}}"#
        let err = StripeClient.parseStripeError(statusCode: 402, data: Data(json.utf8))
        if case .insufficientFunds = err { } else { throw TestError.assertion("expected .insufficientFunds, got \(err)") }
    }

    await test("Stripe A10: formURLEncoded produces deterministic sorted output") {
        // Same input → same output on every call (keys sorted alphabetically).
        let fields = ["z_key": "val_z", "a_key": "val_a", "m_key": "val_m"]
        let a = StripeClient.formURLEncoded(fields)
        let b = StripeClient.formURLEncoded(fields)
        try expect(a == b, "formURLEncoded must be deterministic")
        try expect(a.hasPrefix("a_key="), "keys must be sorted: a first, got: \(a)")
    }

    await test("Stripe A11: createCheckoutSession returns invalidResponse when Stripe omits url field") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        // Stripe returns a session id but no url — malformed response.
        T2StripeMock.handler = { req in
            let json = #"{"id":"cs_no_url"}"#
            return t2Response(url: req.url!, code: 200, json: json)
        }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "sk_test" })
        do {
            _ = try await client.createCheckoutSession(priceID: "price_x",
                                                       successURL: "https://ok", cancelURL: "https://no")
            throw TestError.assertion("expected invalidResponse")
        } catch let e as StripeError {
            if case .invalidResponse = e { } else { throw TestError.assertion("expected .invalidResponse, got \(e)") }
        }
    }

    await test("Stripe A12: createCheckoutSession with no idempotency key still POSTs") {
        _ = URLProtocol.registerClass(T2StripeMock.self)
        defer { URLProtocol.unregisterClass(T2StripeMock.self); T2StripeMock.reset() }
        T2StripeMock.handler = { req in
            // No Idempotency-Key header required
            let json = #"{"id":"cs_no_idem","url":"https://checkout.stripe.com/pay/cs_no_idem"}"#
            return t2Response(url: req.url!, code: 200, json: json)
        }
        let client = StripeClient(session: makeT2Session(), apiKeyProvider: { "sk_test" })
        let s = try await client.createCheckoutSession(priceID: "price_x", successURL: "https://ok", cancelURL: "https://no")
        try expect(s.id == "cs_no_idem")
    }

    await test("Stripe A13: StripeError.amountExceedsCeiling description mentions amounts") {
        let e = StripeError.amountExceedsCeiling(amount: 99000, ceiling: 50000)
        let desc = e.localizedDescription
        try expect(desc.contains("99000"), "description must mention the given amount: \(desc)")
        try expect(desc.contains("50000"), "description must mention the ceiling: \(desc)")
    }

    // ─── B: LicenseManager + LicenseToken extended edge cases ────────────

    await test("License B1: trial boundary — exactly 1 second before expiry → still trial (1 day)") {
        let s = LicenseState(firstLaunchAt: 0)
        let justBefore = Date(timeIntervalSince1970: TimeInterval(LicenseManager.trialDuration - 1))
        let status = LicenseManager.computeStatus(state: s) { justBefore }
        if case .trial(let d) = status {
            try expect(d >= 1, "expected >=1 day remaining, got \(d)")
        } else { throw TestError.assertion("expected .trial, got \(status)") }
    }

    await test("License B2: grandfathered state with a token present → .grandfathered wins") {
        // The grandfather flag has higher precedence than any stored token.
        let (priv, _) = makeKeyPair()
        let payload = makePaidPayload()
        let token = try LicenseToken.encode(payload: payload, signedBy: priv)
        let s = LicenseState(
            firstLaunchAt: 0,
            token: LicenseState.StoredToken(raw: token, payload: payload),
            grandfathered: true
        )
        let status = LicenseManager.computeStatus(state: s) { Date() }
        if case .grandfathered = status { } else { throw TestError.assertion("expected .grandfathered, got \(status)") }
    }

    await test("License B3: acknowledgeTrialExpired is idempotent (no throw on double call)") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-t2-ack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        try BridgePaths.ensureApplicationSupport()
        let (_, pub) = makeKeyPair()
        let mgr = LicenseManager(publicKey: pub) { Date() }
        _ = try await mgr.loadOrInit()
        // First acknowledge: sets the flag.
        try await mgr.acknowledgeTrialExpired()
        try expect(await mgr.currentState().trialExpiredAcknowledged == true)
        // Second acknowledge: no-op, no throw.
        try await mgr.acknowledgeTrialExpired()
        try expect(await mgr.currentState().trialExpiredAcknowledged == true)
    }

    await test("License B4: LicenseToken verify rejects empty token string") {
        let (_, pub) = makeKeyPair()
        do {
            _ = try LicenseToken.verify("", publicKey: pub)
            throw TestError.assertion("expected throw on empty token")
        } catch is LicenseVerifyError { /* ok */ }
    }

    await test("License B5: LicenseToken verify rejects token with multiple dots") {
        let (_, pub) = makeKeyPair()
        do {
            _ = try LicenseToken.verify("a.b.c", publicKey: pub)
            throw TestError.assertion("expected throw on multi-dot token")
        } catch let e as LicenseVerifyError {
            if case .malformed = e { } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("License B6: LicenseTokenPayload validate rejects empty id") {
        let p = LicenseTokenPayload(id: "", sub: "x@y.com", kind: "paid", iat: 1, exp: nil)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .malformed = e { } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("License B7: LicenseTokenPayload validate rejects empty sub") {
        let p = LicenseTokenPayload(id: "ord_x", sub: "", kind: "paid", iat: 1, exp: nil)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .malformed = e { } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("License B8: LicenseTokenPayload validate rejects iat == 0") {
        let p = LicenseTokenPayload(id: "ord_x", sub: "a@b.com", kind: "paid", iat: 0, exp: nil)
        do { try p.validate(); throw TestError.assertion("expected throw") }
        catch let e as LicenseVerifyError {
            if case .malformed = e { } else { throw TestError.assertion("wrong error: \(e)") }
        }
    }

    await test("License B9: LicenseTokenPayload 'grandfather' kind is accepted by validate") {
        let p = LicenseTokenPayload(id: "ord_x", sub: "a@b.com", kind: "grandfather", iat: 1, exp: nil)
        try p.validate()   // must not throw
    }

    await test("License B10: base64url round-trip for 0 bytes") {
        let data = Data()
        let s = LicenseToken.base64url(data)
        let back = LicenseToken.base64urlDecode(s) ?? Data([0xFF])
        try expect(back == data, "round-trip failed for empty data")
    }

    await test("License B11: base64url round-trip for 3 bytes (no padding needed in base64)") {
        let data = Data([0xAA, 0xBB, 0xCC])
        let s = LicenseToken.base64url(data)
        try expect(!s.contains("="), "base64url must have no padding")
        let back = LicenseToken.base64urlDecode(s) ?? Data()
        try expect(back == data, "round-trip failed for 3-byte input")
    }

    await test("License B12: base64url encodes + chars as - and / as _") {
        // Craft data that base64-encodes to contain + and /
        // 0xFB = 11111011 ; 0xFF = 11111111 → in base64 this is "+/..."
        let data = Data([0xFB, 0xFF, 0xFE])
        let b64 = LicenseToken.base64url(data)
        try expect(!b64.contains("+"), "base64url must not contain +")
        try expect(!b64.contains("/"), "base64url must not contain /")
    }

    await test("License B13: LicenseState Codable preserves grandfathered:true") {
        let s = LicenseState(firstLaunchAt: 9_999, grandfathered: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(s)
        let back = try JSONDecoder().decode(LicenseState.self, from: data)
        try expect(back.grandfathered == true)
        try expect(back.firstLaunchAt == 9_999)
    }

    await test("License B14: LicensePublicKey.bundled() is nil (fail-closed committed build)") {
        // Mirrors LicenseCLITests "injection seam is fail-closed" — confirmed here
        // as a coverage invariant for the T2 sweep.
        try expect(LicensePublicKey.bundledBase64URL.isEmpty,
                   "committed build must not embed a live key")
        try expect(LicensePublicKey.bundled() == nil,
                   "bundled() must return nil when bundledBase64URL is empty")
    }

    // ─── C: LicenseRevocationClient extended coverage ────────────────────

    await test("Revocation C1: exact min-length id (4 chars) is accepted") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            var called = false
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
                called = true
                let j = #"{"status":"active","checkedAt":1700000000}"#
                return (Data(j.utf8), 200)
            }
        }
        let t = StubT()
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ab12")
        try expect(t.called, "transport must be called for a 4-char id")
        try expect(r?.status == .active)
    }

    await test("Revocation C2: exact max-length id (128 chars) is accepted") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            var called = false
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
                called = true
                let j = #"{"status":"active","checkedAt":1700000000}"#
                return (Data(j.utf8), 200)
            }
        }
        let id = String(repeating: "x", count: 128)
        let t = StubT()
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: id)
        try expect(t.called, "transport must be called for a 128-char id")
        try expect(r != nil)
    }

    await test("Revocation C3: over-max-length id (129 chars) is rejected client-side") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            var called = false
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? { called = true; return nil }
        }
        let id = String(repeating: "x", count: 129)
        let t = StubT()
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: id)
        try expect(!t.called, "transport must NOT be called for an over-max id")
        try expect(r == nil)
    }

    await test("Revocation C4: id with only whitespace is rejected client-side") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            var called = false
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? { called = true; return nil }
        }
        let t = StubT()
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "   ")
        try expect(!t.called)
        try expect(r == nil)
    }

    await test("Revocation C5: LicenseRevocationResponse Codable round-trip") {
        let resp = LicenseRevocationResponse(status: .revoked, expiresAt: nil, checkedAt: 1_800_000_000)
        let enc = JSONEncoder()
        let data = try enc.encode(resp)
        let back = try JSONDecoder().decode(LicenseRevocationResponse.self, from: data)
        try expect(back == resp)
    }

    await test("Revocation C6: unknown status string in JSON → decode returns nil (not a crash)") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
                // "suspended" is not a known LicenseRevocationStatus case
                let j = #"{"status":"suspended","checkedAt":1700000000}"#
                return (Data(j.utf8), 200)
            }
        }
        let c = LicenseRevocationClient(transport: StubT())
        let r = await c.check(licenseId: "ord_unknown_status")
        // Decode should fail gracefully (nil), not crash.
        try expect(r == nil, "unknown status must yield nil (graceful decode failure)")
    }

    await test("Revocation C7: checkedAt is preserved in a non-nil response") {
        final class StubT: LicenseRevocationTransport, @unchecked Sendable {
            func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
                // Numeric literals in JSON must NOT use Swift-style underscores.
                let j = #"{"status":"active","checkedAt":1750000000}"#
                return (Data(j.utf8), 200)
            }
        }
        let c = LicenseRevocationClient(transport: StubT())
        let r = await c.check(licenseId: "ord_check_at")
        try expect(r != nil, "expected a parsed response")
        try expect(r?.checkedAt == 1_750_000_000)
    }

    // ─── D: LicenseUIState headless behavior ─────────────────────────────

    await test("UIState D1: .from(.trial(0)) is NOT a valid input but .from handles it (floor at 1 in manager)") {
        // LicenseManager always floors days at 1; this tests the UIState path directly.
        let s = LicenseUIState.from(.trial(daysRemaining: 0), canPasteActivate: true)
        if case .trial(let d) = s.kind { try expect(d == 0) }   // UIState mirrors exactly
        else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState D2: Equatable — two identical snapshots are equal") {
        let payload = makePaidPayload()
        let a = LicenseUIState.from(.licensed(payload: payload), canPasteActivate: true, lastError: nil)
        let b = LicenseUIState.from(.licensed(payload: payload), canPasteActivate: true, lastError: nil)
        try expect(a == b)
    }

    await test("UIState D3: Equatable — different lastError makes states unequal") {
        let a = LicenseUIState.from(.trial(daysRemaining: 5), canPasteActivate: true, lastError: nil)
        let b = LicenseUIState.from(.trial(daysRemaining: 5), canPasteActivate: true, lastError: "bad key")
        try expect(a != b)
    }

    await test("UIState D4: .from(.licensed) with nil exp → expiresAtDisplay == nil") {
        let payload = makePaidPayload(exp: nil)
        let s = LicenseUIState.from(.licensed(payload: payload), canPasteActivate: true)
        if case .licensed(_, let exp) = s.kind {
            try expect(exp == nil, "perpetual license must have nil expiresAtDisplay")
        } else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState D5: .from(.licenseExpired) with nil exp → expiredAtDisplay == nil") {
        // licenseExpired with no exp field (unusual but structurally possible if
        // the manager has a stored token whose payload has been cleared to nil exp).
        let payload = makePaidPayload(exp: nil)
        let s = LicenseUIState.from(.licenseExpired(payload: payload), canPasteActivate: false)
        if case .licenseExpired(_, let exp) = s.kind {
            try expect(exp == nil, "should pass through nil expiry display")
        } else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState D6: canPasteActivate is independently propagated for all status kinds") {
        let statuses: [LicenseStatus] = [
            .trial(daysRemaining: 3),
            .trialExpired,
            .licensed(payload: makePaidPayload()),
            .licenseExpired(payload: makePaidPayload(exp: 1_700_000_001)),
            .grandfathered
        ]
        for status in statuses {
            let yes = LicenseUIState.from(status, canPasteActivate: true)
            let no  = LicenseUIState.from(status, canPasteActivate: false)
            try expect(yes.canPasteActivate, "canPasteActivate:true must propagate for \(status)")
            try expect(!no.canPasteActivate, "canPasteActivate:false must propagate for \(status)")
        }
    }

    await test("UIState D7: .from preserves lastError for licenseExpired") {
        let payload = makePaidPayload(exp: 1_700_000_001)
        let s = LicenseUIState.from(.licenseExpired(payload: payload),
                                    canPasteActivate: true,
                                    lastError: "token rejected")
        try expect(s.lastError == "token rejected")
    }

    // ─── E: LicenseStatus property coverage ─────────────────────────────

    await test("Status E1: isLicensedOrGrandfathered — licensed → true") {
        let status = LicenseStatus.licensed(payload: makePaidPayload())
        try expect(status.isLicensedOrGrandfathered)
    }

    await test("Status E2: isLicensedOrGrandfathered — grandfathered → true") {
        try expect(LicenseStatus.grandfathered.isLicensedOrGrandfathered)
    }

    await test("Status E3: isLicensedOrGrandfathered — trial → false") {
        try expect(!LicenseStatus.trial(daysRemaining: 10).isLicensedOrGrandfathered)
    }

    await test("Status E4: isLicensedOrGrandfathered — trialExpired → false") {
        try expect(!LicenseStatus.trialExpired.isLicensedOrGrandfathered)
    }

    await test("Status E5: isLicensedOrGrandfathered — licenseExpired → false") {
        try expect(!LicenseStatus.licenseExpired(payload: makePaidPayload()).isLicensedOrGrandfathered)
    }

    await test("Status E6: pillLabel for .licensed → 'Licensed'") {
        try expect(LicenseStatus.licensed(payload: makePaidPayload()).pillLabel == "Licensed")
    }

    await test("Status E7: pillLabel for .licenseExpired → 'License expired'") {
        try expect(LicenseStatus.licenseExpired(payload: makePaidPayload()).pillLabel == "License expired")
    }

    await test("Status E8: pillLabel for .trial(0) → '0 days left'") {
        // Edge: manager always floors at 1; status enum itself has no such floor.
        // Pill label format must handle zero.
        try expect(LicenseStatus.trial(daysRemaining: 0).pillLabel == "Trial — 0 days left")
    }

    await test("Status E9: isActive — licenseExpired → false") {
        try expect(!LicenseStatus.licenseExpired(payload: makePaidPayload()).isActive)
    }

    await test("Status E10: isActive — all active variants are exhaustive") {
        let activeStatuses: [LicenseStatus] = [
            .trial(daysRemaining: 1),
            .licensed(payload: makePaidPayload()),
            .grandfathered
        ]
        for s in activeStatuses {
            try expect(s.isActive, "expected isActive for \(s)")
        }
    }

    // ─── F: LicenseCardHost pure state transitions (no AppKit startup) ───

    await test("CardHost F1: initial uiState is a 30-day trial (before load() fires)") {
        // LicenseCardHost.init() seeds a 30-day trial as the "before load" snapshot.
        let host = await MainActor.run { LicenseCardHost() }
        let state = await MainActor.run { host.uiState }
        if case .trial(let d) = state.kind {
            try expect(d == 30, "expected 30-day default, got \(d)")
        } else { throw TestError.assertion("expected .trial(30), got \(state.kind)") }
    }

    await test("CardHost F2: initial pasteField is empty") {
        let host = await MainActor.run { LicenseCardHost() }
        let field = await MainActor.run { host.pasteField }
        try expect(field.isEmpty, "initial pasteField must be empty")
    }

    await test("CardHost F3: activate() with empty pasteField is a no-op (no mutation)") {
        let host = await MainActor.run { LicenseCardHost() }
        let before = await MainActor.run { host.uiState }
        await host.activate()
        let after = await MainActor.run { host.uiState }
        // Kind must not change when field is empty.
        try expect(before.kind == after.kind, "activate() with empty field must not change kind")
    }

    // ─── G: BridgeCheckout completeness ──────────────────────────────────

    await test("Checkout G1: product constant is 'the-bridge'") {
        try expect(BridgeCheckout.product == "the-bridge")
    }

    await test("Checkout G2: successURL contains session_id placeholder") {
        try expect(BridgeCheckout.successURL.contains("{CHECKOUT_SESSION_ID}"),
                   "successURL must carry the Stripe session_id template token")
    }

    await test("Checkout G3: cancelURL is a non-empty HTTPS URL") {
        try expect(!BridgeCheckout.cancelURL.isEmpty)
        try expect(BridgeCheckout.cancelURL.hasPrefix("https://"))
    }

    await test("Checkout G4: brandMetadata default channel is 'in-app'") {
        let md = BridgeCheckout.brandMetadata(appVersion: "4.0.0")
        try expect(md["channel"] == "in-app", "default channel must be 'in-app'")
    }

    await test("Checkout G5: brandMetadata respects custom channel") {
        let md = BridgeCheckout.brandMetadata(appVersion: "4.0.0", channel: "web")
        try expect(md["channel"] == "web")
    }

    await test("Checkout G6: priceID whitespace-only env → nil") {
        try expect(BridgeCheckout.priceID({ "   \t\n" }) == nil,
                   "whitespace-only env value must yield nil")
    }

    await test("Checkout G7: paymentLinkURL trims leading/trailing whitespace") {
        let url = BridgeCheckout.paymentLinkURL({ "  https://buy.stripe.com/x  " })
        try expect(url == "https://buy.stripe.com/x", "expected trimmed value, got \(url ?? "nil")")
    }

    await test("Checkout G8: priceID with surrounding newlines is trimmed") {
        let id = BridgeCheckout.priceID({ "\nprice_live_abc\n" })
        try expect(id == "price_live_abc", "expected trimmed price id, got \(id ?? "nil")")
    }
}
