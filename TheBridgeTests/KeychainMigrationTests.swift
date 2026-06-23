// KeychainMigrationTests.swift — WS-5c migration safety + WS-5b cadence guard.
// TheBridge · Tests
//
// WS-5c + the-bridge rename: the Keychain service chain is
// `com.notionbridge` → `kup.solutions.notion-bridge` → `kup.solutions.the-bridge`.
// Each rename MUST be zero-loss: an item written under ANY prior service has to
// still read back. This test
// proves the round-trip end-to-end against the REAL Keychain (the standalone
// test executable is not an .app bundle, so KeychainManager normally no-ops; we
// flip the documented test escape hatch to exercise real SecItem CRUD), then
// cleans up under BOTH services.
//
// WS-5b: a property guard that the SAME due-gated path the periodic timer +
// wake observer call never double-runs within the 7-day window — recording a
// run flips `isDue` to false, so a second timer fire is a no-op.

import Foundation
import TheBridgeLib
import Security

func runKeychainMigrationTests() async {
    print("\n\u{1F510} WS-5c KeychainManager Migration Tests")

    let legacyService = "com.notionbridge"
    let priorService = "kup.solutions.notion-bridge"   // prior canonical, now a legacy fallback
    let newService = "kup.solutions.the-bridge"        // current canonical (product name)
    let enableKey = "com.notionbridge.tests.enableKeychainOpsOutsideApp"

    // Helper: raw write directly to the Keychain under an explicit service,
    // bypassing KeychainManager entirely (simulates a pre-rename stored item).
    func rawWrite(account: String, value: String, service: String) -> OSStatus {
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(delete as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    func rawRead(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func rawDelete(account: String, service: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }

    // Unique account so concurrent / repeat runs never collide.
    let account = "ws5c_migration_probe_\(UUID().uuidString)"
    let secret = "sk_live_migration_proof_\(UUID().uuidString)"

    // Probe whether the real Keychain is writable in THIS process. On CI /
    // sandboxes without a usable login keychain, SecItemAdd returns an error
    // (e.g. errSecMissingEntitlement / -34018); we then skip the live round-trip
    // rather than fail. The CRUCIAL invariant — KeychainManager reads the legacy
    // service — is still asserted via the pure constant check below.
    UserDefaults.standard.set(true, forKey: enableKey)
    let probeStatus = rawWrite(account: account, value: secret, service: legacyService)
    let keychainWritable = (probeStatus == errSecSuccess)
    if keychainWritable { rawDelete(account: account, service: legacyService) }

    await test("WS-5c: KeychainManager.service is the clean professional name") {
        try expect(KeychainManager.service == newService,
                   "Canonical service must be \(newService), got \(KeychainManager.service)")
        try expect(KeychainManager.legacyService == legacyService,
                   "Legacy service constant must remain \(legacyService) for migration + vault surfacing")
        // the-bridge rename: the prior canonical AND the original infra service
        // are both retained as legacy fallbacks (zero-loss migration chain).
        try expect(KeychainManager.legacyServices.contains(priorService),
                   "Prior canonical \(priorService) must be a legacy fallback after the the-bridge rename")
        try expect(KeychainManager.legacyServices.contains(legacyService),
                   "Original infra service \(legacyService) must stay in the chain (CredentialManager vault surfacing)")
    }

    if keychainWritable {
        await test("WS-5c: item written under OLD service reads back after rename (ZERO LOSS)") {
            defer {
                rawDelete(account: account, service: legacyService)
                rawDelete(account: account, service: newService)
            }
            // 1. Simulate a pre-rename stored credential: write under OLD service.
            let writeStatus = rawWrite(account: account, value: secret, service: legacyService)
            try expect(writeStatus == errSecSuccess, "Legacy write failed: \(writeStatus)")
            // Confirm it is NOT yet under the new service.
            try expect(rawRead(account: account, service: newService) == nil,
                       "Precondition: item must not exist under new service yet")

            // 2. KeychainManager.read must transparently find + return it.
            let readBack = KeychainManager.shared.read(key: account)
            try expect(readBack == secret,
                       "KeychainManager.read must read the legacy item back. Got \(String(describing: readBack))")

            // 3. NON-DESTRUCTIVE proof: the OLD copy is still present (never
            //    deleted by the migration) AND a NEW copy now exists.
            try expect(rawRead(account: account, service: legacyService) == secret,
                       "Legacy copy must be RETAINED (non-destructive migration)")
            try expect(rawRead(account: account, service: newService) == secret,
                       "Migration must have copied the value forward to the new service")
        }

        await test("WS-5c: save mirrors to BOTH services (vault surfacing + zero loss)") {
            let acct = "ws5c_save_probe_\(UUID().uuidString)"
            let val = "tok_\(UUID().uuidString)"
            defer {
                rawDelete(account: acct, service: legacyService)
                rawDelete(account: acct, service: newService)
            }
            try expect(KeychainManager.shared.save(key: acct, value: val), "save must succeed")
            try expect(rawRead(account: acct, service: newService) == val,
                       "Canonical copy must be written")
            try expect(rawRead(account: acct, service: legacyService) == val,
                       "Legacy mirror must be written so CredentialManager vault surfacing keeps working")
        }

        await test("WS-5c: delete clears BOTH services (no stale legacy copy)") {
            let acct = "ws5c_delete_probe_\(UUID().uuidString)"
            let val = "tok_\(UUID().uuidString)"
            defer {
                rawDelete(account: acct, service: legacyService)
                rawDelete(account: acct, service: newService)
            }
            _ = KeychainManager.shared.save(key: acct, value: val)
            try expect(KeychainManager.shared.delete(key: acct), "delete must succeed")
            try expect(rawRead(account: acct, service: newService) == nil,
                       "Canonical copy must be gone")
            try expect(rawRead(account: acct, service: legacyService) == nil,
                       "Legacy copy must be gone too")
        }

        await test("WS-5c: exists finds a legacy-only item (migration-aware existence)") {
            let acct = "ws5c_exists_probe_\(UUID().uuidString)"
            let val = "tok_\(UUID().uuidString)"
            defer {
                rawDelete(account: acct, service: legacyService)
                rawDelete(account: acct, service: newService)
            }
            // Only the legacy copy exists (pre-rename item, never read yet).
            try expect(rawWrite(account: acct, value: val, service: legacyService) == errSecSuccess)
            try expect(KeychainManager.shared.exists(key: acct) == true,
                       "exists must union both services so a legacy-only item is found")
        }

        await test("WS-5c: allKeys unions canonical + legacy services") {
            let newOnly = "ws5c_allkeys_new_\(UUID().uuidString)"
            let legacyOnly = "ws5c_allkeys_legacy_\(UUID().uuidString)"
            defer {
                rawDelete(account: newOnly, service: newService)
                rawDelete(account: newOnly, service: legacyService)
                rawDelete(account: legacyOnly, service: legacyService)
                rawDelete(account: legacyOnly, service: newService)
            }
            _ = rawWrite(account: newOnly, value: "a", service: newService)
            _ = rawWrite(account: legacyOnly, value: "b", service: legacyService)
            let keys = Set(KeychainManager.shared.allKeys())
            try expect(keys.contains(newOnly), "allKeys must include canonical-service keys")
            try expect(keys.contains(legacyOnly), "allKeys must include legacy-service keys (union)")
        }

        await test("WS-5c: update routes through save → writes BOTH services") {
            let acct = "ws5c_update_probe_\(UUID().uuidString)"
            defer {
                rawDelete(account: acct, service: legacyService)
                rawDelete(account: acct, service: newService)
            }
            // update on a fresh key falls back to save (both services written).
            try expect(KeychainManager.shared.update(key: acct, value: "v1"), "update/save must succeed")
            try expect(rawRead(account: acct, service: newService) == "v1")
            try expect(rawRead(account: acct, service: legacyService) == "v1")
            // updating again keeps both services in sync.
            try expect(KeychainManager.shared.update(key: acct, value: "v2"))
            try expect(rawRead(account: acct, service: newService) == "v2")
            try expect(rawRead(account: acct, service: legacyService) == "v2")
        }
    } else {
        await test("WS-5c: live Keychain unavailable in this process — round-trip SKIPPED (constants verified)") {
            print("    \u{2139}\u{FE0F}  SecItemAdd probe returned OSStatus \(probeStatus); skipping live round-trip.")
            try expect(true)
        }
    }

    UserDefaults.standard.removeObject(forKey: enableKey)

    // ── WS-5b: timer/wake cadence guard (pure policy, no real clock) ──────────
    await test("WS-5b: recordRun flips isDue OFF → periodic timer + wake never double-run") {
        let name = "ws5b-cadence-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }

        let now = Date()
        // First fire (e.g. on launch): never run → due.
        try expect(CredentialAutoValidatePolicy.isDue(
            enabled: true,
            lastRun: CredentialAutoValidatePolicy.lastRun(defaults: suite),
            now: now) == true, "First check must be due")

        // The run records its timestamp.
        CredentialAutoValidatePolicy.recordRun(now, defaults: suite)

        // A subsequent timer fire / wake event one hour later must NOT re-run.
        let oneHourLater = now.addingTimeInterval(60 * 60)
        try expect(CredentialAutoValidatePolicy.isDue(
            enabled: true,
            lastRun: CredentialAutoValidatePolicy.lastRun(defaults: suite),
            now: oneHourLater) == false, "Within 7d window the timer/wake must be a no-op (no double-run)")

        // Only after the 7-day cadence elapses does it become due again.
        let eightDaysLater = now.addingTimeInterval(8 * 24 * 60 * 60)
        try expect(CredentialAutoValidatePolicy.isDue(
            enabled: true,
            lastRun: CredentialAutoValidatePolicy.lastRun(defaults: suite),
            now: eightDaysLater) == true, "After 7d the next timer/wake fire re-validates")
    }
}
