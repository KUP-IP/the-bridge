// LicenseRevocationTests.swift — PKT-909 (Sell/Distribute v3 · 1) W4
//
// Drive `LicenseRevocationClient` through an injected transport so we
// never hit the network. Covers:
//   • happy path (active / revoked / refunded JSON shapes)
//   • non-2xx → nil
//   • non-JSON body → nil
//   • transport returns nil → nil
//   • short / long id rejected client-side without a transport call

import Foundation
import NotionBridgeLib

private final class StubTransport: LicenseRevocationTransport, @unchecked Sendable {
    var nextResponse: (Data, Int)?
    var calls: Int = 0
    var lastBody: Data?

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> (Data, Int)? {
        calls += 1
        lastBody = body
        return nextResponse
    }
}

private func makeJSON(_ obj: [String: Any]) -> Data {
    return try! JSONSerialization.data(withJSONObject: obj)
}

func runLicenseRevocationTests() async {
    print("\n\u{1F310} PKT-909 W4 License Revocation Client")

    await test("Revocation: 200 + active body → .active") {
        let t = StubTransport()
        t.nextResponse = (makeJSON([
            "status": "active",
            "expiresAt": NSNull(),
            "checkedAt": 1_700_000_000
        ]), 200)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r != nil)
        try expect(r?.status == .active)
        try expect(r?.expiresAt == nil)
    }

    await test("Revocation: 200 + revoked body → .revoked") {
        let t = StubTransport()
        t.nextResponse = (makeJSON([
            "status": "revoked",
            "expiresAt": NSNull(),
            "checkedAt": 1_700_000_000
        ]), 200)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r?.status == .revoked)
    }

    await test("Revocation: 200 + refunded body with expiresAt → fully parsed") {
        let t = StubTransport()
        t.nextResponse = (makeJSON([
            "status": "refunded",
            "expiresAt": 1_900_000_000,
            "checkedAt": 1_700_000_000
        ]), 200)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r?.status == .refunded)
        try expect(r?.expiresAt == 1_900_000_000)
    }

    await test("Revocation: 500 → nil (caller keeps offline state)") {
        let t = StubTransport()
        t.nextResponse = (Data(), 500)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r == nil)
    }

    await test("Revocation: non-JSON 200 body → nil") {
        let t = StubTransport()
        t.nextResponse = (Data("<html>".utf8), 200)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r == nil)
    }

    await test("Revocation: transport returns nil → nil (no signal)") {
        let t = StubTransport()
        t.nextResponse = nil
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ord_test_001")
        try expect(r == nil)
    }

    await test("Revocation: too-short id rejected client-side (no transport call)") {
        let t = StubTransport()
        t.nextResponse = (makeJSON(["status": "active", "checkedAt": 0]), 200)
        let c = LicenseRevocationClient(transport: t)
        let r = await c.check(licenseId: "ab")
        try expect(r == nil)
        try expect(t.calls == 0, "transport was called for a short id")
    }

    await test("Revocation: request body is the documented {id,v} shape") {
        let t = StubTransport()
        t.nextResponse = (makeJSON(["status": "active", "checkedAt": 0]), 200)
        let c = LicenseRevocationClient(transport: t)
        _ = await c.check(licenseId: "ord_real_id_001")
        let body = t.lastBody ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        try expect((obj["id"] as? String) == "ord_real_id_001")
        try expect((obj["v"] as? Int) == 1)
    }
}
