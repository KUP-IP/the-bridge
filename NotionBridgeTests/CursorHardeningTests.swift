// CursorHardeningTests.swift — PKT-3.4.3 (Bridge v2.2)
// Coverage for the Wave 1 hardening envelope on top of PKT-3.4.1's CursorModule.
//
// Scope (Wave 1 of 3.4.3):
//   - SensitiveRepoMatcher unit (default glob, user-extensible, non-match, nil/empty)
//   - PromptRedactor unit (built-in rules, count, ruleIds, hash, clean passthrough)
//   - CursorRuntime.evaluateGates() integration (queue audit, force-local on sensitive)
//   - Scenario G3: redaction rule match + count + ruleIds logged; no matched value in audit
//   - Scenario H1: sensitive-repo path forces runtime=local (cloud disabled)
//
// Out of Wave 1 scope (deferred to W2/W3-LIVE):
//   - End-to-end run with redacted prompt actually dispatched to sidecar (needs W2 IPC)
//   - AI LOGS DS write of audit entries (needs W2 NotionAPIClient path)
//   - Worktree-aware concurrency (needs running spawn surface — W2)
//   - Lifecycle archival (needs AI LOGS rows to archive — W2)

import Foundation
import NotionBridgeLib

func runCursorHardeningTests() async {
    print("\n\u{1F6E1}  CursorHardening Tests (PKT-3.4.3 v2.2 · 3.4.3 Wave 1)")

    let testDefaultsSuite = "com.notionbridge.tests.cursor-hardening-\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: testDefaultsSuite)!

    // ------------------------------------------------------------------
    // 1) SensitiveRepoMatcher
    // ------------------------------------------------------------------

    await test("SensitiveRepoMatcher matches default `~/Developer/secure/*`") {
        let verdict = SensitiveRepoMatcher.evaluate(
            repoPath: "~/Developer/secure/test-repo",
            defaults: testDefaults
        )
        try expect(verdict.isSensitive, "expected sensitive=true for ~/Developer/secure/test-repo")
        try expect(verdict.forceLocal, "expected forceLocal=true")
        try expect(verdict.requiresExtraApproval, "expected requiresExtraApproval=true")
        try expect(verdict.matchedPattern?.contains("secure") == true,
            "expected matched pattern to reference 'secure', got '\(verdict.matchedPattern ?? "nil")'")
    }

    await test("SensitiveRepoMatcher matches expanded `/Users/.../Developer/secure/...`") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let verdict = SensitiveRepoMatcher.evaluate(
            repoPath: "\(home)/Developer/secure/customer-data",
            defaults: testDefaults
        )
        try expect(verdict.isSensitive, "expanded path should match")
        try expect(verdict.forceLocal)
    }

    await test("SensitiveRepoMatcher does NOT match `~/Developer/notion-bridge`") {
        let verdict = SensitiveRepoMatcher.evaluate(
            repoPath: "~/Developer/notion-bridge",
            defaults: testDefaults
        )
        try expect(!verdict.isSensitive, "notion-bridge should not match sensitive default")
        try expect(!verdict.forceLocal)
        try expect(verdict.matchedPattern == nil)
    }

    await test("SensitiveRepoMatcher accepts user-extended globs via UserDefaults") {
        testDefaults.set(["~/work/clients/*"], forKey: SensitiveRepoMatcher.userDefaultsKey)
        defer { testDefaults.removeObject(forKey: SensitiveRepoMatcher.userDefaultsKey) }
        let v1 = SensitiveRepoMatcher.evaluate(repoPath: "~/work/clients/acme", defaults: testDefaults)
        try expect(v1.isSensitive, "user-extended glob should match")
        let v2 = SensitiveRepoMatcher.evaluate(repoPath: "~/work/personal/blog", defaults: testDefaults)
        try expect(!v2.isSensitive, "non-matching path should not trip")
    }

    await test("SensitiveRepoMatcher returns notSensitive for nil/empty path") {
        let v1 = SensitiveRepoMatcher.evaluate(repoPath: nil, defaults: testDefaults)
        try expect(!v1.isSensitive)
        let v2 = SensitiveRepoMatcher.evaluate(repoPath: "", defaults: testDefaults)
        try expect(!v2.isSensitive)
    }

    // ------------------------------------------------------------------
    // 2) PromptRedactor — Scenario G3
    // ------------------------------------------------------------------

    await test("[G3] PromptRedactor scrubs AWS access key + logs count + ruleId") {
        let key = "AKIAIOSFODNN7EXAMPLE"
        let prompt = "Please use AWS credentials: \(key) to fetch the bucket contents."
        let result = PromptRedactor.redact(prompt, defaults: testDefaults)
        try expect(!result.scrubbed.contains(key),
            "scrubbed prompt must NOT contain the original key; got: \(result.scrubbed)")
        try expect(result.scrubbed.contains("[REDACTED:aws-access-key-id]"),
            "expected redaction placeholder; got: \(result.scrubbed)")
        try expect(result.count >= 1, "expected count >= 1, got \(result.count)")
        try expect(result.ruleIds.contains("aws-access-key-id"),
            "expected aws-access-key-id ruleId hit; got \(result.ruleIds)")
        try expect(result.promptHash.count == 64,
            "expected sha256 hex (64 chars); got \(result.promptHash.count)")
    }

    await test("[G3] PromptRedactor scrubs GitHub PAT") {
        let prompt = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 — DO NOT SHARE"
        let result = PromptRedactor.redact(prompt, defaults: testDefaults)
        try expect(!result.scrubbed.contains("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz"))
        try expect(result.ruleIds.contains("github-pat"))
        try expect(result.count >= 1)
    }

    await test("[G3] PromptRedactor passthrough on clean prompt") {
        let prompt = "Refactor the foo function in bar.swift to use async/await."
        let result = PromptRedactor.redact(prompt, defaults: testDefaults)
        try expect(result.scrubbed == prompt, "clean prompt should not be mutated")
        try expect(result.count == 0)
        try expect(result.ruleIds.isEmpty)
        try expect(result.promptHash.count == 64)
    }

    await test("[G3] PromptRedactor never echoes matched value in audit fields") {
        let secret = "AKIAIOSFODNN7EXAMPLE"
        let prompt = "Use \(secret) to authenticate"
        let result = PromptRedactor.redact(prompt, defaults: testDefaults)
        try expect(!result.scrubbed.contains(secret))
        try expect(!result.ruleIds.contains(where: { $0.contains(secret) }))
        try expect(!result.promptHash.contains(secret))
    }

    await test("PromptRedactor sha256Hex matches known fixture (RFC reference)") {
        // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let hash = PromptRedactor.sha256Hex("hello")
        try expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "sha256(hello) mismatch; got \(hash)")
    }

    await test("PromptRedactor accepts user-extensible rules via UserDefaults dict") {
        testDefaults.set(["custom-secret": "SUPER[A-Z0-9]+"], forKey: PromptRedactor.userDefaultsKey)
        defer { testDefaults.removeObject(forKey: PromptRedactor.userDefaultsKey) }
        let result = PromptRedactor.redact("My SUPERSECRET42 token", defaults: testDefaults)
        try expect(result.ruleIds.contains("custom-secret"),
            "expected custom-secret rule to fire; got \(result.ruleIds)")
        try expect(!result.scrubbed.contains("SUPERSECRET42"))
    }

    // ------------------------------------------------------------------
    // 3) CursorRuntime.evaluateGates — Scenario H1 integration
    // ------------------------------------------------------------------

    await test("[H1] CursorRuntime.evaluateGates forces local on sensitive-repo + cloud") {
        let rt = CursorRuntime(sidecarRoot: URL(fileURLWithPath: "/tmp/cursor-sidecar-h1-\(UUID().uuidString)"))
        let verdict = await rt.evaluateGates(
            prompt: "harmless prompt",
            runtime: .cloud,
            repoPath: "~/Developer/secure/customer-vault"
        )
        try expect(verdict.effectiveRuntime == .local,
            "expected cloud->local override; got \(verdict.effectiveRuntime)")
        try expect(verdict.sensitivity.isSensitive)
        try expect(verdict.sensitivity.forceLocal)
        try expect(verdict.auditQueued.forcedLocal,
            "audit entry should record forcedLocal=true")
        try expect(verdict.auditQueued.sensitiveRepoMatched?.contains("secure") == true)
    }

    await test("[H1] CursorRuntime.evaluateGates leaves cloud as-is on non-sensitive repo") {
        let rt = CursorRuntime(sidecarRoot: URL(fileURLWithPath: "/tmp/cursor-sidecar-h1b-\(UUID().uuidString)"))
        let verdict = await rt.evaluateGates(
            prompt: "harmless prompt",
            runtime: .cloud,
            repoPath: "~/Developer/notion-bridge"
        )
        try expect(verdict.effectiveRuntime == .cloud,
            "expected cloud preserved; got \(verdict.effectiveRuntime)")
        try expect(!verdict.sensitivity.isSensitive)
        try expect(!verdict.auditQueued.forcedLocal)
        try expect(verdict.auditQueued.sensitiveRepoMatched == nil)
    }

    await test("CursorRuntime.evaluateGates enqueues audit entry observable via pendingRedactionAudits()") {
        let rt = CursorRuntime(sidecarRoot: URL(fileURLWithPath: "/tmp/cursor-sidecar-aud-\(UUID().uuidString)"))
        _ = await rt.drainPendingRedactionAudits()
        _ = await rt.evaluateGates(
            prompt: "AKIAIOSFODNN7EXAMPLE is the key",
            runtime: .local,
            repoPath: "~/Developer/notion-bridge"
        )
        let pending = await rt.pendingRedactionAudits()
        try expect(pending.count == 1, "expected 1 queued audit; got \(pending.count)")
        try expect(pending[0].count >= 1, "audit count should reflect redaction count")
        try expect(pending[0].ruleIds.contains("aws-access-key-id"))
        try expect(pending[0].promptHash.count == 64)
    }

    await test("CursorRuntime.drainPendingRedactionAudits empties the queue") {
        let rt = CursorRuntime(sidecarRoot: URL(fileURLWithPath: "/tmp/cursor-sidecar-drain-\(UUID().uuidString)"))
        _ = await rt.evaluateGates(prompt: "p1", runtime: .local, repoPath: nil)
        _ = await rt.evaluateGates(prompt: "p2", runtime: .local, repoPath: nil)
        let drained = await rt.drainPendingRedactionAudits()
        try expect(drained.count == 2)
        let afterDrain = await rt.pendingRedactionAudits()
        try expect(afterDrain.isEmpty, "queue should be empty after drain; got \(afterDrain.count)")
    }

    // Clean up suite-scoped defaults
    testDefaults.removePersistentDomain(forName: testDefaultsSuite)
}
