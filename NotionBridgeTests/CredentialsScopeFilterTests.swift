// CredentialsScopeFilterTests.swift — v3.6.0 D1
//
// Regression guard for the v3.5.0 audit finding: "Stored credentials" surfaced
// every system keychain item (Apple system services, Chrome Safe Storage, Spark,
// etc.) because `isKeychainItemManagedByThisApp` defaulted-true on absent
// `kSecAttrAccessGroup`. The fix flipped that branch to return false; Bridge-
// saved items continue to surface via the metadata-flag and com.notionbridge
// fallback paths in `shouldSurfaceCredentialFromKeychainItem`.

import Foundation
import NotionBridgeLib
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
}
