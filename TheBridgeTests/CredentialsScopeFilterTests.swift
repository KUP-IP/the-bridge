// CredentialsScopeFilterTests.swift — v3.6.0 D1
//
// Regression guard for the v3.5.0 audit finding: "Stored credentials" surfaced
// every system keychain item (Apple system services, Chrome Safe Storage, Spark,
// etc.) because `isKeychainItemManagedByThisApp` defaulted-true on absent
// `kSecAttrAccessGroup`. The fix flipped that branch to return false; Bridge-
// saved items continue to surface via the metadata-flag and com.notionbridge
// fallback paths in `shouldSurfaceCredentialFromKeychainItem`.

import Foundation
import TheBridgeLib
import Security

func runCredentialsScopeFilterTests() async {
    print("\n\u{1F510} D1 Credentials Scope Filter Tests")

    let expected = "ABC1234567.kup.solutions.notion-bridge"

    await test("D1: item with NO access group attribute → NOT ours") {
        // The bug we just fixed. System keychain items typically lack
        // kSecAttrAccessGroup; pre-fix they returned true → leaked into UI.
        let item: [String: Any] = [
            kSecAttrService as String: "Com.Apple.Scopedbookmarksagent.Xpc",
            kSecAttrAccount as String: "system-account"
        ]
        try expect(
            CredentialManager.matchesAccessGroup(item: item, expected: expected) == false,
            "Items without kSecAttrAccessGroup must not be treated as ours"
        )
    }

    await test("D1: item with matching access group → ours") {
        let item: [String: Any] = [
            kSecAttrAccessGroup as String: expected,
            kSecAttrService as String: "com.notionbridge",
            kSecAttrAccount as String: "stripe-secret"
        ]
        try expect(
            CredentialManager.matchesAccessGroup(item: item, expected: expected) == true
        )
    }

    await test("D1: item with DIFFERENT access group → NOT ours") {
        let item: [String: Any] = [
            kSecAttrAccessGroup as String: "OTHER123.com.example.app",
            kSecAttrService as String: "Chrome Safe Storage"
        ]
        try expect(
            CredentialManager.matchesAccessGroup(item: item, expected: expected) == false
        )
    }

    await test("D1: item with empty-string access group → NOT ours") {
        let item: [String: Any] = [
            kSecAttrAccessGroup as String: "",
            kSecAttrService as String: "Spark"
        ]
        try expect(
            CredentialManager.matchesAccessGroup(item: item, expected: expected) == false
        )
    }

    await test("D1: item with non-string access group value → NOT ours") {
        // Defensive: SecItemCopyMatching has been observed to return Data
        // instead of String for kSecAttrAccessGroup in some edge cases.
        let item: [String: Any] = [
            kSecAttrAccessGroup as String: Data([0x41, 0x42, 0x43]),
            kSecAttrService as String: "Com.Apple.Assistant"
        ]
        try expect(
            CredentialManager.matchesAccessGroup(item: item, expected: expected) == false
        )
    }

    // ── PKT-933: query scoping + migration helpers ─────────────────────────

    await test("PKT-933: applyingAccessGroup injects kSecAttrAccessGroup when entitled") {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc",
            kSecAttrAccount as String: "acct"
        ]
        let scoped = CredentialManager.applyingAccessGroup(base, group: expected)
        try expect(scoped[kSecAttrAccessGroup as String] as? String == expected,
                   "Access group must be set when a group is provided")
        // Original keys preserved.
        try expect(scoped[kSecAttrService as String] as? String == "svc")
        try expect(scoped[kSecAttrAccount as String] as? String == "acct")
    }

    await test("PKT-933: applyingAccessGroup is a no-op when group is nil") {
        // Pre-entitlement / unsigned / test contexts → nil group → unchanged
        // query, so behavior falls back to the read-time post-filter.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "svc"
        ]
        let scoped = CredentialManager.applyingAccessGroup(base, group: nil)
        try expect(scoped[kSecAttrAccessGroup as String] == nil,
                   "No access group must be added when group is nil")
        try expect(scoped.count == base.count)
    }

    await test("PKT-933: needsAccessGroupMigration false when attribute absent (implicit default group)") {
        // Items written before the entitlement live in the implicit default
        // group, which equals our declared group — nothing to move.
        let item: [String: Any] = [
            kSecAttrService as String: "com.notionbridge",
            kSecAttrAccount as String: "stripe-secret"
        ]
        try expect(
            CredentialManager.needsAccessGroupMigration(item: item, expected: expected) == false,
            "Absent access-group attribute must not be flagged for migration"
        )
    }

    await test("PKT-933: needsAccessGroupMigration false when already in our group") {
        let item: [String: Any] = [kSecAttrAccessGroup as String: expected]
        try expect(
            CredentialManager.needsAccessGroupMigration(item: item, expected: expected) == false
        )
    }

    await test("PKT-933: needsAccessGroupMigration true when in a different group") {
        let item: [String: Any] = [kSecAttrAccessGroup as String: "OTHER123.com.example.app"]
        try expect(
            CredentialManager.needsAccessGroupMigration(item: item, expected: expected) == true
        )
    }
}
