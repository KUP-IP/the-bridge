// PKT1010OnboardingTests.swift — PKT-1010 (Packet C activation + onboarding UX polish)
//
// Token trim + validate tests for `OnboardingTokenValidator`.
// The validator is a pure, public enum with no SwiftUI or AppKit surface,
// so every case runs without a main actor or window server.
//
// Coverage:
//   • Whitespace trimming (leading space, trailing newline, both, tabs)
//   • Valid ntn_ token — accepted
//   • Valid secret_ token — accepted (legacy Notion public-integration format)
//   • Short token — rejected with a descriptive error
//   • Wrong prefix (random string, nbn_, ntN_ case-mismatch) — rejected
//   • Empty / whitespace-only — rejected
//   • trimmedToken helper returns the trimmed form

import Foundation
import TheBridgeLib

func runPKT1010OnboardingTests() async {
    print("\n\u{1F511} PKT-1010 Onboarding Token Validator Tests")

    // MARK: - trimmedToken helper

    await test("PKT-1010 trimmedToken: trims leading space") {
        let result = OnboardingTokenValidator.trimmedToken(" ntn_abc123def456ghi789")
        try expect(result == "ntn_abc123def456ghi789", "Got: \(result)")
    }

    await test("PKT-1010 trimmedToken: trims trailing newline") {
        let result = OnboardingTokenValidator.trimmedToken("ntn_abc123def456ghi789\n")
        try expect(result == "ntn_abc123def456ghi789", "Got: \(result)")
    }

    await test("PKT-1010 trimmedToken: trims leading + trailing whitespace") {
        let result = OnboardingTokenValidator.trimmedToken("  ntn_abc123def456ghi789  ")
        try expect(result == "ntn_abc123def456ghi789", "Got: \(result)")
    }

    await test("PKT-1010 trimmedToken: trims tab characters") {
        let result = OnboardingTokenValidator.trimmedToken("\tntn_abc123def456ghi789\t")
        try expect(result == "ntn_abc123def456ghi789", "Got: \(result)")
    }

    await test("PKT-1010 trimmedToken: leaves already-clean token unchanged") {
        let token = "ntn_abc123def456ghi789"
        let result = OnboardingTokenValidator.trimmedToken(token)
        try expect(result == token, "Got: \(result)")
    }

    // MARK: - validateFormat: valid tokens

    await test("PKT-1010 validateFormat: valid ntn_ token is accepted") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("ntn_abc123def456ghi789")
        try expect(valid, "Expected valid, got error: \(error ?? "nil")")
        try expect(error == nil, "Expected nil error")
    }

    await test("PKT-1010 validateFormat: valid secret_ token is accepted") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("secret_abc123def456ghi789xyz")
        try expect(valid, "Expected valid, got error: \(error ?? "nil")")
        try expect(error == nil, "Expected nil error")
    }

    await test("PKT-1010 validateFormat: ntn_ token with leading space is accepted after trim") {
        // The validator itself trims before checking — same behavior as save path.
        let (valid, error) = OnboardingTokenValidator.validateFormat(" ntn_abc123def456ghi789")
        try expect(valid, "Expected valid after trim, got: \(error ?? "nil")")
    }

    await test("PKT-1010 validateFormat: ntn_ token with trailing newline is accepted after trim") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("ntn_abc123def456ghi789\n")
        try expect(valid, "Expected valid after trim, got: \(error ?? "nil")")
    }

    // MARK: - validateFormat: rejected tokens

    await test("PKT-1010 validateFormat: empty string is rejected") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("")
        try expect(!valid, "Expected invalid for empty string")
        try expect(error != nil, "Expected non-nil error message")
    }

    await test("PKT-1010 validateFormat: whitespace-only string is rejected") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("   \n\t  ")
        try expect(!valid, "Expected invalid for whitespace-only")
        try expect(error != nil, "Expected non-nil error message")
    }

    await test("PKT-1010 validateFormat: too-short token is rejected") {
        // Under 20 chars even with correct prefix
        let (valid, error) = OnboardingTokenValidator.validateFormat("ntn_short")
        try expect(!valid, "Expected invalid for short token")
        guard let err = error else {
            throw TestError.assertion("Expected non-nil error for short token")
        }
        try expect(!err.isEmpty, "Error message should not be empty")
    }

    await test("PKT-1010 validateFormat: wrong prefix 'nbn_' is rejected") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("nbn_abc123def456ghi789xyz")
        try expect(!valid, "Expected invalid for wrong prefix nbn_")
        try expect(error != nil, "Expected error message for wrong prefix")
    }

    await test("PKT-1010 validateFormat: wrong prefix 'NTN_' (uppercase) is rejected") {
        // Notion tokens are case-sensitive; the validator should not accept uppercase.
        let (valid, _) = OnboardingTokenValidator.validateFormat("NTN_abc123def456ghi789xyz")
        try expect(!valid, "Expected invalid for uppercase NTN_ prefix")
    }

    await test("PKT-1010 validateFormat: random string without prefix is rejected") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("this_is_not_a_notion_token_at_all")
        try expect(!valid, "Expected invalid for random string")
        try expect(error != nil, "Expected error message")
    }

    await test("PKT-1010 validateFormat: error message is user-readable (non-empty, no debug noise)") {
        let (_, error) = OnboardingTokenValidator.validateFormat("bad")
        guard let err = error else {
            throw TestError.assertion("Expected non-nil error")
        }
        try expect(err.count > 5, "Error message too short: \(err)")
        // Should not expose internal type names
        try expect(!err.contains("OnboardingTokenValidator"), "Error leaks type name: \(err)")
    }

    // MARK: - return value shape

    await test("PKT-1010 validateFormat: returns (true, nil) on success") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("ntn_abc123def456ghi789")
        try expect(valid == true)
        try expect(error == nil)
    }

    await test("PKT-1010 validateFormat: returns (false, String) on failure") {
        let (valid, error) = OnboardingTokenValidator.validateFormat("bad")
        try expect(valid == false)
        try expect(error != nil)
    }
}
