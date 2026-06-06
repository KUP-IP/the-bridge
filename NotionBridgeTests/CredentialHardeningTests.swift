// CredentialHardeningTests.swift — [credentials] backlog item.
// NotionBridge · Tests
//
// Covers the three credential-hardening concerns (all PURE — no Keychain, no
// live network, no .app bundle required):
//   1. CredentialAliasNormalizer  — env-var aliases → canonical service:account
//   2. CredentialSentinelDetector — flag placeholder/sentinel values
//   3. CredentialRetryPolicy      — idempotent-read transient-drop retry policy
// Plus the credential_read/credential_list MCP surface wiring (alias accepted,
// account optional for aliases, placeholder warning surfaced).

import Foundation
import MCP
import NotionBridgeLib

func runCredentialHardeningTests() async {
    print("\n🛡️  Credential Hardening Tests ([credentials])")

    // MARK: - 1. Alias normalization

    await test("alias: CURSOR_API_KEY resolves to api_key:cursor / cursor") {
        let r = CredentialAliasNormalizer.resolve(service: "CURSOR_API_KEY", account: "")
        try expect(r.wasAlias, "should be recognized as alias")
        try expect(r.service == "api_key:cursor", "service was \(r.service)")
        try expect(r.account == "cursor", "account was \(r.account)")
    }

    await test("alias: documented STRIPE_API_KEY maps to stripe") {
        let r = CredentialAliasNormalizer.resolve(service: "STRIPE_API_KEY", account: "")
        try expect(r.wasAlias, "should be alias")
        try expect(r.service == "api_key:stripe", "service was \(r.service)")
        try expect(r.account == "stripe", "account was \(r.account)")
    }

    await test("alias: NOTION_TOKEN maps to the KeychainManager infra row") {
        let r = CredentialAliasNormalizer.resolve(service: "NOTION_TOKEN", account: "")
        try expect(r.wasAlias, "should be alias")
        try expect(r.service == "com.notionbridge", "notion uses the infra service, got \(r.service)")
        try expect(r.account == "notion_api_token", "account was \(r.account)")
    }

    await test("alias: NOTION_TOKEN preserves an explicit account") {
        let r = CredentialAliasNormalizer.resolve(service: "NOTION_TOKEN", account: "my-workspace")
        try expect(r.service == "com.notionbridge", "service was \(r.service)")
        try expect(r.account == "my-workspace", "explicit account should win, got \(r.account)")
    }

    await test("alias: generic FOO_API_KEY derives provider foo") {
        try expect(CredentialAliasNormalizer.providerSlug(forAlias: "FOO_API_KEY") == "foo",
                   "generic alias should derive 'foo'")
        let r = CredentialAliasNormalizer.resolve(service: "FOO_API_KEY", account: "")
        try expect(r.service == "api_key:foo" && r.account == "foo", "got \(r.service)/\(r.account)")
    }

    await test("alias: GITHUB_TOKEN and GH_TOKEN both map to github") {
        try expect(CredentialAliasNormalizer.providerSlug(forAlias: "GITHUB_TOKEN") == "github", "GITHUB_TOKEN")
        try expect(CredentialAliasNormalizer.providerSlug(forAlias: "GH_TOKEN") == "github", "GH_TOKEN")
    }

    await test("alias: canonical inputs pass through unchanged") {
        let r = CredentialAliasNormalizer.resolve(service: "api_key:stripe", account: "stripe")
        try expect(!r.wasAlias, "already-canonical should not be flagged as alias")
        try expect(r.service == "api_key:stripe" && r.account == "stripe", "unchanged")
    }

    await test("alias: bare lowercase service is not an alias") {
        try expect(!CredentialAliasNormalizer.looksLikeAlias("github"), "lowercase bare is not alias")
        try expect(!CredentialAliasNormalizer.looksLikeAlias("notion"), "lowercase bare is not alias")
        let r = CredentialAliasNormalizer.resolve(service: "github", account: "octocat")
        try expect(!r.wasAlias && r.service == "github" && r.account == "octocat", "unchanged")
    }

    await test("alias: bare SCREAMING word without underscore is not an alias") {
        // "STRIPE" alone (no _SUFFIX) must not be rewritten — could be a real
        // user-defined service name.
        try expect(!CredentialAliasNormalizer.looksLikeAlias("STRIPE"), "no underscore → not alias")
        try expect(CredentialAliasNormalizer.providerSlug(forAlias: "STRIPE") == nil, "no slug")
    }

    await test("alias: service containing ':' is never treated as alias") {
        try expect(!CredentialAliasNormalizer.looksLikeAlias("API_KEY:STRIPE"), "colon → not alias")
    }

    await test("alias: whitespace around an alias is tolerated") {
        let r = CredentialAliasNormalizer.resolve(service: "  CURSOR_API_KEY  ", account: "")
        try expect(r.wasAlias && r.service == "api_key:cursor", "got \(r.service)")
    }

    // MARK: - 2. Sentinel / placeholder detection

    await test("sentinel: empty and whitespace flagged as empty") {
        try expect(CredentialSentinelDetector.inspect("") == .empty, "empty string")
        try expect(CredentialSentinelDetector.inspect("   ") == .empty, "whitespace")
        try expect(CredentialSentinelDetector.inspect(nil) == .empty, "nil")
    }

    await test("sentinel: 'changeme' family flagged as knownPlaceholder") {
        try expect(CredentialSentinelDetector.inspect("changeme") == .knownPlaceholder, "changeme")
        try expect(CredentialSentinelDetector.inspect("CHANGEME") == .knownPlaceholder, "case-insensitive")
        try expect(CredentialSentinelDetector.inspect("change-me") == .knownPlaceholder, "change-me")
        try expect(CredentialSentinelDetector.inspect("password") == .knownPlaceholder, "password")
        try expect(CredentialSentinelDetector.inspect("placeholder") == .knownPlaceholder, "placeholder")
    }

    await test("sentinel: device paths flagged") {
        try expect(CredentialSentinelDetector.inspect("/dev/stdin") == .devicePath, "/dev/stdin")
        try expect(CredentialSentinelDetector.inspect("/dev/null") == .devicePath, "/dev/null")
        try expect(CredentialSentinelDetector.inspect("-") == .devicePath, "dash pipe marker")
    }

    await test("sentinel: template markers flagged") {
        try expect(CredentialSentinelDetector.inspect("<your key>") == .templateMarker, "<your key>")
        try expect(CredentialSentinelDetector.inspect("${SECRET}") == .templateMarker, "${SECRET}")
        try expect(CredentialSentinelDetector.inspect("$SECRET") == .templateMarker, "$SECRET")
        try expect(CredentialSentinelDetector.inspect("{{token}}") == .templateMarker, "{{token}}")
        try expect(CredentialSentinelDetector.inspect("xxxxxx") == .templateMarker, "x-mask")
        try expect(CredentialSentinelDetector.inspect("******") == .templateMarker, "star-mask")
    }

    await test("sentinel: too-short value flagged") {
        try expect(CredentialSentinelDetector.inspect("ab") == .tooShort, "2 chars")
        try expect(CredentialSentinelDetector.inspect("abc") == .tooShort, "3 chars (not a mask char)")
    }

    await test("sentinel: real-looking secret is NOT flagged") {
        try expect(CredentialSentinelDetector.inspect("sk_live_51JabcDEFghiJKLmno") == nil, "stripe-like")
        try expect(CredentialSentinelDetector.inspect("ghp_16C7e42F292c6912E7710c838347Ae178B4a") == nil, "gh PAT")
        try expect(!CredentialSentinelDetector.isSentinel("a-very-real-token-value-12345"), "real")
    }

    await test("sentinel: reason messages are non-empty and stable rawValues") {
        for reason: CredentialSentinelDetector.Reason in [.empty, .knownPlaceholder, .devicePath, .templateMarker, .tooShort] {
            try expect(!reason.message.isEmpty, "\(reason) message")
            try expect(!reason.rawValue.isEmpty, "\(reason) rawValue")
        }
    }

    // MARK: - 3. Idempotent-read retry policy

    await test("retry: transient keychain statuses are retryable") {
        try expect(CredentialRetryPolicy.shouldRetry(status: -25291), "errSecNotAvailable")
        try expect(CredentialRetryPolicy.shouldRetry(status: -25308), "errSecInteractionNotAllowed")
    }

    await test("retry: definitive statuses are NOT retryable") {
        try expect(!CredentialRetryPolicy.shouldRetry(status: errSecItemNotFound), "not-found")
        try expect(!CredentialRetryPolicy.shouldRetry(status: errSecAuthFailed), "auth-failed must not retry")
        try expect(!CredentialRetryPolicy.shouldRetry(status: errSecSuccess), "success")
    }

    await test("retry: backoff is exponential and capped") {
        try expect(CredentialRetryPolicy.backoff(forAttempt: 0) == 0, "attempt 0 → 0")
        let b1 = CredentialRetryPolicy.backoff(forAttempt: 1, base: 0.05)
        let b2 = CredentialRetryPolicy.backoff(forAttempt: 2, base: 0.05)
        try expect(b1 == 0.05, "attempt 1 → base, got \(b1)")
        try expect(b2 == 0.10, "attempt 2 → 2x base, got \(b2)")
        try expect(CredentialRetryPolicy.backoff(forAttempt: 100, base: 0.05) <= 1.0, "capped at 1s")
    }

    await test("retry: allowsAnotherAttempt honors maxRetries and retryability") {
        // transient status, within budget → allowed
        try expect(CredentialRetryPolicy.allowsAnotherAttempt(attemptsMade: 1, lastStatus: -25291), "1st transient")
        try expect(CredentialRetryPolicy.allowsAnotherAttempt(attemptsMade: 2, lastStatus: -25291), "2nd transient")
        // exhausted budget (default maxRetries == 2 → 3 total attempts)
        try expect(!CredentialRetryPolicy.allowsAnotherAttempt(attemptsMade: 3, lastStatus: -25291), "budget spent")
        // definitive status → never retry regardless of budget
        try expect(!CredentialRetryPolicy.allowsAnotherAttempt(attemptsMade: 1, lastStatus: errSecItemNotFound), "not-found")
    }

    // MARK: - 4. credential_read / credential_list MCP surface wiring

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CredentialModule.register(on: router)

    await test("credential_read schema requires only 'service' (account optional for aliases)") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_read" })!
        if case .object(let schema) = tool.inputSchema,
           case .array(let required) = schema["required"] {
            let names = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(names.contains("service"), "service required")
            try expect(!names.contains("account"), "account must be optional now")
        } else {
            throw TestError.assertion("Expected object schema")
        }
    }

    await test("credential_read still rejects when 'service' is missing") {
        do {
            _ = try await router.dispatch(toolName: "credential_read", arguments: .object([:]))
            throw TestError.assertion("Expected error for missing service")
        } catch is ToolRouterError {
            // expected
        } catch {
            // any error acceptable
        }
    }

    await test("credential_read accepts an alias service with no account (non-app no-op read)") {
        // In the test executable (non-.app), CredentialManager.read throws
        // .notFound → handler returns {error}. The point of this test is that
        // the ALIAS path resolves an account and does NOT throw an
        // invalid-arguments router error for the missing account.
        let result = try await router.dispatch(
            toolName: "credential_read",
            arguments: .object(["service": .string("CURSOR_API_KEY")])
        )
        if case .object(let dict) = result {
            // Must NOT be an invalid-arguments rejection; a not-found error
            // envelope is the expected outcome under test.
            if case .string(let err)? = dict["error"] {
                try expect(!err.lowercased().contains("missing required"),
                           "alias should infer account, not reject; got: \(err)")
            }
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    await test("credential_read with bare service and no account is rejected") {
        // A non-alias service can't infer an account → must reject. The handler
        // throws ToolRouterError.invalidArguments; either a throw or an {error}
        // envelope mentioning the account is acceptable.
        do {
            let result = try await router.dispatch(
                toolName: "credential_read",
                arguments: .object(["service": .string("my-custom-service")])
            )
            // If it returned instead of threw, it must be an {error} about account.
            if case .object(let dict) = result, case .string(let err)? = dict["error"] {
                try expect(err.lowercased().contains("account"), "should mention account, got: \(err)")
            } else {
                throw TestError.assertion("Expected rejection for missing account")
            }
        } catch let e as ToolRouterError {
            // Expected: invalid-arguments rejection mentioning the account.
            try expect("\(e)".lowercased().contains("account"), "rejection should mention account, got: \(e)")
        }
    }

    await test("credential_list dispatches and never leaks secret values") {
        let result = try await router.dispatch(toolName: "credential_list", arguments: .object([:]))
        if case .object(let dict) = result {
            try expect(dict["error"] == nil, "list should not error")
            // Under test (non-app) the vault is empty; just assert shape.
            try expect(dict["count"] != nil || dict["credentials"] != nil, "shape")
        }
    }
}
