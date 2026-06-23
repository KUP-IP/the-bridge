// CredentialManagerTests.swift – PKT-372 CredentialManager Tests
// TheBridge · Tests
//
// Note: CredentialManager.isAppBundle is false in test runner (standalone binary,
// not .app bundle). CRUD operations return dummy data / empty results without
// touching Keychain. These tests validate type system, metadata encoding, error
// handling, and non-app-bundle code paths. Full Keychain integration tests
// require running from the .app bundle.

import Foundation
import MCP
import TheBridgeLib

// MARK: - CredentialManager Tests

func runCredentialManagerTests() async {
    print("\n🔑 CredentialManager Tests")

    // ============================================================
    // Type System Tests
    // ============================================================

    await test("CredentialType has expected cases") {
        let allCases = CredentialType.allCases
        try expect(allCases.count == 4, "Expected 4 credential types, got \(allCases.count)")
        try expect(allCases.contains(.apiKey))
        try expect(allCases.contains(.password))
        try expect(allCases.contains(.card))
        try expect(allCases.contains(.unknown))
    }

    await test("CredentialType raw values are correct") {
        try expect(CredentialType.apiKey.rawValue == "api_key")
        try expect(CredentialType.password.rawValue == "password")
        try expect(CredentialType.card.rawValue == "card")
        try expect(CredentialType.unknown.rawValue == "unknown")
    }

    await test("CredentialType is Codable (JSON round-trip)") {
        let encoder = JSONEncoder()
        let data = try encoder.encode(CredentialType.card)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CredentialType.self, from: data)
        try expect(decoded == .card, "Expected .card after decode")
    }

    // ============================================================
    // CredentialMetadata Tests
    // ============================================================

    await test("CredentialMetadata encodes to JSON") {
        let meta = CredentialMetadata(
            brand: "visa",
            last4: "4242",
            expMonth: 12,
            expYear: 2028,
            stripePm: "pm_1Abc123"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let json = String(data: data, encoding: .utf8)!
        try expect(json.contains("visa"), "JSON should contain brand")
        try expect(json.contains("4242"), "JSON should contain last4")
        try expect(json.contains("pm_1Abc123"), "JSON should contain stripe_pm")
    }

    await test("CredentialMetadata round-trips through JSON") {
        let meta = CredentialMetadata(
            brand: "mastercard",
            last4: "5555",
            expMonth: 6,
            expYear: 2030,
            stripePm: "pm_xyz"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CredentialMetadata.self, from: data)
        try expect(decoded.brand == "mastercard")
        try expect(decoded.last4 == "5555")
        try expect(decoded.expMonth == 6)
        try expect(decoded.expYear == 2030)
        try expect(decoded.stripePm == "pm_xyz")
    }

    await test("CredentialMetadata empty init for password type") {
        let meta = CredentialMetadata.empty
        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CredentialMetadata.self, from: data)
        try expect(decoded.brand == nil)
        try expect(decoded.last4 == nil)
        try expect(decoded.stripePm == nil)
    }

    // ============================================================
    // CredentialEntry Tests (via save return value)
    // ============================================================

    await test("CredentialEntry stores all fields (password type via save)") {
        let manager = CredentialManager.shared
        let entry = try await manager.save(
            service: "nb-entry-test-\(UUID().uuidString)",
            account: "user@example.com",
            password: "s3cret!",
            type: .password,
            metadata: .empty
        )
        try expect(entry.service.hasPrefix("nb-entry-test-"))
        try expect(entry.account == "user@example.com")
        try expect(entry.type == .password)
        try expect(entry.password == nil, "Save return should not expose password")
    }

    await test("CredentialEntry card type with metadata (via save)") {
        let manager = CredentialManager.shared
        let meta = CredentialMetadata(
            brand: "visa",
            last4: "4242",
            expMonth: 12,
            expYear: 2028,
            stripePm: nil
        )
        let entry = try await manager.save(
            service: "nb-card-entry-\(UUID().uuidString)",
            account: "my_card",
            password: "4242424242424242",
            type: .card,
            metadata: meta
        )
        try expect(entry.type == .card)
        // In non-app-bundle path, metadata is passed through as-is
        try expect(entry.metadata.brand == "visa")
        try expect(entry.metadata.last4 == "4242")
    }

    // ============================================================
    // CredentialError Tests
    // ============================================================

    await test("CredentialError cases exist") {
        // All 7 error cases from CredentialError enum
        let errors: [CredentialError] = [
            .keychainError(errSecItemNotFound),
            .notFound,
            .encodingError("test"),
            .biometricFailed("test"),
            .biometricUnavailable,
            .stripeTokenizationFailed("test"),
            .stripeKeyMissing,
        ]
        try expect(errors.count == 7, "Expected 7 error cases, got \(errors.count)")
    }

    await test("CredentialError localizedDescription is non-empty") {
        let error = CredentialError.notFound
        try expect(!error.localizedDescription.isEmpty, "Error description should not be empty")
    }

    await test("CredentialError invalidType case") {
        let error = CredentialError.invalidType("unknown")
        try expect(error.localizedDescription.contains("unknown"))
    }

    // ============================================================
    // CredentialManager Singleton & Non-App-Bundle Paths
    // ============================================================

    await test("CredentialManager.shared is accessible") {
        let manager = CredentialManager.shared
        _ = manager // Verify no crash on access
    }

    // In test runner (not .app bundle), isAppBundle is false.
    // save() returns a dummy CredentialEntry without touching Keychain.
    await test("CredentialManager save returns entry (non-app-bundle path)") {
        let manager = CredentialManager.shared
        let service = "nb-test-\(UUID().uuidString)"
        let entry = try await manager.save(
            service: service,
            account: "testuser",
            password: "s3cret!",
            type: .password,
            metadata: .empty
        )
        try expect(entry.service == service, "Entry service should match")
        try expect(entry.account == "testuser", "Entry account should match")
        try expect(entry.type == .password, "Entry type should be password")
    }

    await test("CredentialManager save card returns entry with type .card") {
        let manager = CredentialManager.shared
        let service = "nb-card-\(UUID().uuidString)"
        let meta = CredentialMetadata(
            brand: "visa",
            last4: "4242",
            expMonth: 12,
            expYear: 2028,
            stripePm: nil
        )
        let entry = try await manager.save(
            service: service,
            account: "my_visa",
            password: "4242424242424242",
            type: .card,
            metadata: meta
        )
        try expect(entry.type == .card, "Entry type should be card")
    }

    // read() throws .notFound in non-app-bundle context (no Keychain access)
    await test("CredentialManager read throws notFound (non-app-bundle path)") {
        let manager = CredentialManager.shared
        do {
            _ = try manager.read(service: "nonexistent-\(UUID().uuidString)", account: "nobody")
            throw TestError.assertion("Expected notFound error")
        } catch let error as CredentialError {
            if case .notFound = error { /* expected */ }
            else { throw TestError.assertion("Expected .notFound, got \(error)") }
        }
    }

    // list() returns empty array in non-app-bundle context
    await test("CredentialManager list returns empty (non-app-bundle path)") {
        let manager = CredentialManager.shared
        let entries = try manager.list()
        try expect(entries.isEmpty, "Expected empty list in non-app-bundle context")
    }

    await test("CredentialManager list with type filter returns empty (non-app-bundle path)") {
        let manager = CredentialManager.shared
        let passwords = try manager.list(type: .password)
        let cards = try manager.list(type: .card)
        try expect(passwords.isEmpty, "Expected empty password list")
        try expect(cards.isEmpty, "Expected empty card list")
    }

    // deleteCredential() returns true in non-app-bundle context (no-op success)
    await test("CredentialManager delete returns true (non-app-bundle path)") {
        let manager = CredentialManager.shared
        let result = try await manager.deleteCredential(
            service: "nb-del-\(UUID().uuidString)",
            account: "delme"
        )
        try expect(result == true, "Expected true from delete in non-app-bundle context")
    }
}
