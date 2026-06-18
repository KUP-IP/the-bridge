// LicenseUITests.swift — PKT-909 (Sell/Distribute v3 · 1) W3
//
// UI snapshot-state contracts (no AppKit launch). LicenseCard is purely
// driven by a `LicenseUIState`; these tests pin the
// `LicenseStatus → LicenseUIState.Kind` mapping and the pill labels.

import Foundation
import TheBridgeLib

func runLicenseUITests() async {
    print("\n\u{1F9F0} PKT-909 W3 License UI")

    await test("UIState.from(.trial(n)) → .trial(daysRemaining:n)") {
        let s = LicenseUIState.from(.trial(daysRemaining: 7), canPasteActivate: true)
        if case .trial(let d) = s.kind { try expect(d == 7) }
        else { throw TestError.assertion("wrong kind") }
        try expect(s.canPasteActivate)
        try expect(s.lastError == nil)
    }

    await test("UIState.from(.trialExpired) → .trialExpired") {
        let s = LicenseUIState.from(.trialExpired, canPasteActivate: true)
        if case .trialExpired = s.kind { /* ok */ }
        else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState.from(.licensed) → .licensed with subject + nil expiry display") {
        let payload = LicenseTokenPayload(
            id: "ord_1", sub: "buyer@example.com", kind: "paid",
            iat: 1_700_000_000, exp: nil
        )
        let s = LicenseUIState.from(.licensed(payload: payload), canPasteActivate: true)
        if case .licensed(let sub, let exp) = s.kind {
            try expect(sub == "buyer@example.com")
            try expect(exp == nil)
        } else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState.from(.licensed) with exp → .licensed with formatted expiry") {
        let payload = LicenseTokenPayload(
            id: "ord_1", sub: "buyer@example.com", kind: "paid",
            iat: 1_700_000_000, exp: 1_800_000_000
        )
        let s = LicenseUIState.from(.licensed(payload: payload), canPasteActivate: true)
        if case .licensed(_, let exp) = s.kind {
            try expect(exp != nil)
            try expect(!(exp ?? "").isEmpty, "expected non-empty date string")
        } else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState.from(.licenseExpired) → .licenseExpired with expired-at display") {
        let payload = LicenseTokenPayload(
            id: "ord_1", sub: "buyer@example.com", kind: "paid",
            iat: 1_700_000_000, exp: 1_700_001_000
        )
        let s = LicenseUIState.from(.licenseExpired(payload: payload), canPasteActivate: true)
        if case .licenseExpired(let sub, _) = s.kind {
            try expect(sub == "buyer@example.com")
        } else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState.from(.grandfathered) → .grandfathered") {
        let s = LicenseUIState.from(.grandfathered, canPasteActivate: true)
        if case .grandfathered = s.kind { /* ok */ }
        else { throw TestError.assertion("wrong kind") }
    }

    await test("UIState: canPasteActivate=false is preserved") {
        let s = LicenseUIState.from(.trial(daysRemaining: 5), canPasteActivate: false)
        try expect(!s.canPasteActivate)
    }

    await test("UIState: lastError is preserved through .from(...)") {
        let s = LicenseUIState.from(.trial(daysRemaining: 1), canPasteActivate: true, lastError: "bad key")
        try expect(s.lastError == "bad key")
    }

    await test("Notification.Name.licenseStateDidChange is exposed under com.notionbridge namespace") {
        try expect(Notification.Name.licenseStateDidChange.rawValue.hasPrefix("com.notionbridge."))
    }
}
