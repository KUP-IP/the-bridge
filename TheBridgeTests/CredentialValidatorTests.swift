// CredentialValidatorTests.swift — v3.7.6 Wave 4a (premium Credentials vault).
//
// PURE-LOGIC coverage for the credential validation core. NO live network, NO
// Keychain writes, NO flakiness — every assertion is against the deterministic
// helpers in CredentialHealth.swift (the validator's network paths are gated on
// `isAppBundle` and never run under this standalone test executable).
//
// Covers:
//   • validator service→method mapping (Notion / Stripe / card / unmappable),
//   • the TRUTHFULNESS INVARIANT (unmappable/unvalidated → never `.valid`),
//   • health→badge-tone mapping (valid→ok, expiring→warn, revoked/error→bad,
//     unchecked→neutral),
//   • status-persistence round-trip (CredentialHealthStore via a throwaway
//     UserDefaults suite — never the shared defaults),
//   • the Touch-ID-reveal gate decision helper (ON gates / OFF passes),
//   • the weekly-due decision helper (toggle + >7d).

import Foundation
import TheBridgeLib

func runCredentialValidatorTests() async {
    print("\n\u{1F510} Credential Validator Tests (Wave 4a)")

    // MARK: - Service → method mapping

    await test("Map: notion API key → notionTokenIntrospect") {
        let m = CredentialValidationMapper.method(forService: "notion", type: .apiKey, account: "KUP")
        guard case .notionTokenIntrospect(let conn) = m else {
            throw TestError.assertion("Expected .notionTokenIntrospect, got \(m)")
        }
        try expect(conn == "KUP", "Expected connection from account, got \(conn)")
    }

    await test("Map: api_key:stripe → stripeAccountFetch") {
        let m = CredentialValidationMapper.method(forService: "api_key:stripe", type: .apiKey, account: "stripe")
        try expect(m == .stripeAccountFetch, "Expected .stripeAccountFetch, got \(m)")
    }

    await test("Map: api_key:notion slug normalizes to notion introspect") {
        let m = CredentialValidationMapper.method(forService: "api_key:notion", type: .apiKey, account: "primary")
        guard case .notionTokenIntrospect = m else {
            throw TestError.assertion("Expected .notionTokenIntrospect for api_key:notion, got \(m)")
        }
    }

    await test("Map: card type → cardExpiry regardless of slug") {
        let m = CredentialValidationMapper.method(forService: "card", type: .card, account: "card-1234")
        try expect(m == .cardExpiry, "Expected .cardExpiry, got \(m)")
    }

    await test("Map: generic API key → unsupported (no real check)") {
        let m = CredentialValidationMapper.method(forService: "api_key:acme", type: .apiKey, account: "acme")
        try expect(m == .unsupported, "Expected .unsupported for unknown provider, got \(m)")
    }

    await test("Map: arbitrary password → unsupported") {
        let m = CredentialValidationMapper.method(forService: "internal-portal", type: .password, account: "admin")
        try expect(m == .unsupported, "Expected .unsupported for password, got \(m)")
    }

    await test("isValidatable: notion/stripe true; generic false") {
        try expect(CredentialValidationMapper.isValidatable(service: "notion", type: .apiKey, account: "w"))
        try expect(CredentialValidationMapper.isValidatable(service: "api_key:stripe", type: .apiKey, account: "stripe"))
        try expect(!CredentialValidationMapper.isValidatable(service: "api_key:acme", type: .apiKey, account: "acme"))
    }

    // MARK: - Truthfulness invariant

    await test("Truthfulness: unsupported method maps to .unchecked (never .valid)") {
        // The view/validator turn .unsupported into .unchecked. Assert the
        // mapping is .unsupported and that .unchecked is NOT .valid.
        let m = CredentialValidationMapper.method(forService: "api_key:acme", type: .apiKey, account: "acme")
        try expect(m == .unsupported)
        let defaultRecord = CredentialHealthRecord.unchecked
        try expect(defaultRecord.health == .unchecked, "Default record must be .unchecked")
        try expect(defaultRecord.health != .valid, "Unvalidated credential must NEVER be .valid")
        try expect(defaultRecord.checkedAt == nil, "Unchecked record must have nil checkedAt")
    }

    await test("Truthfulness: absent persisted record defaults to .unchecked") {
        let suite = makeEphemeralDefaults()
        let store = CredentialHealthStore(defaults: suite)
        let rec = store.record(service: "api_key:acme", account: "acme")
        try expect(rec.health == .unchecked, "No record → .unchecked")
        try expect(rec.health != .valid)
    }

    // MARK: - Health → badge tone

    await test("Tone: valid → ok") {
        try expect(CredentialHealth.valid.badgeTone == .ok)
    }
    await test("Tone: expiring → warn") {
        try expect(CredentialHealth.expiring(days: 12).badgeTone == .warn)
    }
    await test("Tone: revoked → bad") {
        try expect(CredentialHealth.revoked.badgeTone == .bad)
    }
    await test("Tone: error → bad") {
        try expect(CredentialHealth.error("boom").badgeTone == .bad)
    }
    await test("Tone: unchecked → neutral") {
        try expect(CredentialHealth.unchecked.badgeTone == .neutral)
    }

    await test("Badge label is truthful per state") {
        try expect(CredentialHealth.valid.badgeLabel == "Valid")
        try expect(CredentialHealth.revoked.badgeLabel == "Revoked")
        try expect(CredentialHealth.unchecked.badgeLabel == "Unchecked")
        try expect(CredentialHealth.expiring(days: 12).badgeLabel == "Expires in 12d")
        try expect(CredentialHealth.expiring(days: 0).badgeLabel == "Expired")
    }

    await test("needsAttention: revoked/expiring/error true; valid/unchecked false") {
        try expect(CredentialHealth.revoked.needsAttention)
        try expect(CredentialHealth.expiring(days: 5).needsAttention)
        try expect(CredentialHealth.error("x").needsAttention)
        try expect(!CredentialHealth.valid.needsAttention)
        try expect(!CredentialHealth.unchecked.needsAttention)
    }

    await test("requiresReconnect: revoked/error true; others false") {
        try expect(CredentialHealth.revoked.requiresReconnect)
        try expect(CredentialHealth.error("x").requiresReconnect)
        try expect(!CredentialHealth.valid.requiresReconnect)
        try expect(!CredentialHealth.expiring(days: 5).requiresReconnect)
        try expect(!CredentialHealth.unchecked.requiresReconnect)
    }

    // MARK: - ConnectionHealth + StripeError mapping

    await test("mapConnectionHealth: healthy→valid, error→revoked, unconfigured→unchecked") {
        try expect(CredentialValidator.mapConnectionHealth(.healthy) == .valid)
        try expect(CredentialValidator.mapConnectionHealth(.error) == .revoked)
        try expect(CredentialValidator.mapConnectionHealth(.unconfigured) == .unchecked)
        try expect(CredentialValidator.mapConnectionHealth(.checking) == .unchecked)
        // warning maps to expiring (a soft, attention-worthy state — not valid).
        if case .expiring = CredentialValidator.mapConnectionHealth(.warning) {} else {
            throw TestError.assertion("Expected .warning → .expiring")
        }
    }

    await test("mapStripeError: authenticationFailed→revoked; others→error") {
        try expect(CredentialValidator.mapStripeError(.authenticationFailed) == .revoked)
        if case .error = CredentialValidator.mapStripeError(.rateLimited) {} else {
            throw TestError.assertion("Expected non-auth StripeError → .error")
        }
    }

    // MARK: - Card expiry math (pure, fixed `now`)

    await test("Card expiry: far future → valid") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        let h = CredentialCardExpiry.health(expMonth: 12, expYear: 2030, now: now)
        try expect(h == .valid, "Got \(h)")
    }

    await test("Card expiry: within 60d window → expiring") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        // Expires end of June 2026 → cutoff July 1 2026 → ~27 days out.
        let h = CredentialCardExpiry.health(expMonth: 6, expYear: 2026, now: now)
        guard case .expiring(let days) = h else {
            throw TestError.assertion("Expected .expiring, got \(h)")
        }
        try expect(days > 0 && days <= 60, "Days out of window: \(days)")
    }

    await test("Card expiry: past cutoff → revoked") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        let h = CredentialCardExpiry.health(expMonth: 1, expYear: 2026, now: now)
        try expect(h == .revoked, "Expected revoked for past card, got \(h)")
    }

    await test("Card expiry: missing data → unchecked (truthful)") {
        let h = CredentialCardExpiry.health(expMonth: nil, expYear: nil)
        try expect(h == .unchecked, "Missing expiry → unchecked, got \(h)")
        try expect(h != .valid, "Must never default a card to valid")
    }

    // MARK: - Persistence round-trip

    await test("Persistence: set then record round-trips a valid verdict") {
        let suite = makeEphemeralDefaults()
        let store = CredentialHealthStore(defaults: suite)
        let when = fixedDate(year: 2026, month: 6, day: 1)
        store.set(CredentialHealthRecord(health: .valid, checkedAt: when), service: "notion", account: "KUP")
        let rec = store.record(service: "notion", account: "KUP")
        try expect(rec.health == .valid, "Expected valid, got \(rec.health)")
        try expect(rec.checkedAt == when, "checkedAt did not round-trip")
    }

    await test("Persistence: error(reason) survives encode/decode") {
        let suite = makeEphemeralDefaults()
        let store = CredentialHealthStore(defaults: suite)
        store.set(CredentialHealthRecord(health: .error("timed out"), checkedAt: nil), service: "api_key:stripe", account: "stripe")
        let rec = store.record(service: "api_key:stripe", account: "stripe")
        try expect(rec.health == .error("timed out"), "error reason did not round-trip: \(rec.health)")
    }

    await test("Persistence: prune drops records for deleted credentials") {
        let suite = makeEphemeralDefaults()
        let store = CredentialHealthStore(defaults: suite)
        store.set(CredentialHealthRecord(health: .valid), service: "notion", account: "KUP")
        store.set(CredentialHealthRecord(health: .revoked), service: "api_key:stripe", account: "stripe")
        // Keep only notion.
        let keep: Set<String> = [CredentialHealthStore.key(service: "notion", account: "KUP")]
        store.prune(keeping: keep)
        let loaded = store.load()
        try expect(loaded.count == 1, "Expected 1 record after prune, got \(loaded.count)")
        try expect(loaded[CredentialHealthStore.key(service: "notion", account: "KUP")] != nil)
        try expect(loaded[CredentialHealthStore.key(service: "api_key:stripe", account: "stripe")] == nil)
    }

    await test("Persistence: key is stable service|account") {
        try expect(CredentialHealthStore.key(service: "notion", account: "KUP") == "notion|KUP")
    }

    // MARK: - Touch-ID reveal gate

    await test("Reveal gate: ON gates the reveal") {
        try expect(CredentialRevealGate.shouldGate(requireTouchID: true) == true)
    }
    await test("Reveal gate: OFF passes through") {
        try expect(CredentialRevealGate.shouldGate(requireTouchID: false) == false)
    }
    await test("Reveal gate: isRequired reads the persisted flag (defaults ON)") {
        let suite = makeEphemeralDefaults()
        try expect(CredentialRevealGate.isRequired(defaults: suite) == true, "Absent key defaults ON")
        suite.set(false, forKey: CredentialRevealGate.requireTouchIDKey)
        try expect(CredentialRevealGate.isRequired(defaults: suite) == false, "Explicit opt-out is honored")
        suite.set(true, forKey: CredentialRevealGate.requireTouchIDKey)
        try expect(CredentialRevealGate.isRequired(defaults: suite) == true)
    }
    await test("Weekly: isEnabled reads the persisted flag (defaults ON)") {
        let suite = makeEphemeralDefaults()
        try expect(CredentialAutoValidatePolicy.isEnabled(defaults: suite) == true, "Absent key defaults ON")
        suite.set(false, forKey: CredentialAutoValidatePolicy.enabledKey)
        try expect(CredentialAutoValidatePolicy.isEnabled(defaults: suite) == false, "Explicit opt-out is honored")
    }

    // MARK: - Weekly auto-validate decision

    await test("Weekly: toggle OFF → never due") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        try expect(CredentialAutoValidatePolicy.isDue(enabled: false, lastRun: nil, now: now) == false)
        let old = fixedDate(year: 2026, month: 1, day: 1)
        try expect(CredentialAutoValidatePolicy.isDue(enabled: false, lastRun: old, now: now) == false)
    }

    await test("Weekly: ON + never run → due") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        try expect(CredentialAutoValidatePolicy.isDue(enabled: true, lastRun: nil, now: now) == true)
    }

    await test("Weekly: ON + >7d since last run → due") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        try expect(CredentialAutoValidatePolicy.isDue(enabled: true, lastRun: eightDaysAgo, now: now) == true)
    }

    await test("Weekly: ON + <=7d since last run → not due") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        try expect(CredentialAutoValidatePolicy.isDue(enabled: true, lastRun: threeDaysAgo, now: now) == false)
    }

    await test("Weekly: lastRun persistence round-trips") {
        let suite = makeEphemeralDefaults()
        try expect(CredentialAutoValidatePolicy.lastRun(defaults: suite) == nil)
        let when = fixedDate(year: 2026, month: 6, day: 4)
        CredentialAutoValidatePolicy.recordRun(when, defaults: suite)
        try expect(CredentialAutoValidatePolicy.lastRun(defaults: suite) == when)
    }

    // MARK: - Card form validators (carried from retired CredentialsView)

    await test("Card validation: Luhn accepts a valid test number") {
        try expect(CredentialCardValidation.luhn("4242424242424242") == true)
    }
    await test("Card validation: Luhn rejects a bad number") {
        try expect(CredentialCardValidation.luhn("4242424242424241") == false)
        try expect(CredentialCardValidation.luhn("abcd") == false)
    }
    await test("Card validation: parseExpiry parses MM/YY") {
        let parsed = CredentialCardValidation.parseExpiry("08/29")
        try expect(parsed?.0 == 8 && parsed?.1 == 2029, "Got \(String(describing: parsed))")
        try expect(CredentialCardValidation.parseExpiry("13/29") == nil, "Month 13 invalid")
        try expect(CredentialCardValidation.parseExpiry("8-29") == nil, "Bad separator")
    }
    await test("Card validation: isExpiryPast against fixed now") {
        let now = fixedDate(year: 2026, month: 6, day: 4)
        try expect(CredentialCardValidation.isExpiryPast(month: 1, year: 2026, now: now) == true)
        try expect(CredentialCardValidation.isExpiryPast(month: 12, year: 2030, now: now) == false)
        try expect(CredentialCardValidation.isExpiryPast(month: 6, year: 2026, now: now) == false, "Current month not past")
    }
}

// MARK: - Local helpers

/// A throwaway UserDefaults suite — NEVER the shared defaults (hermetic).
private func makeEphemeralDefaults() -> UserDefaults {
    let name = "cred-validator-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func fixedDate(year: Int, month: Int, day: Int) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day
    c.hour = 12
    return Calendar.current.date(from: c)!
}
