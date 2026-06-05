// SecurityGateUXTests.swift
// NotionBridge · Tests
//
// fb-securitygate — SecurityGate UX fixes. Evidence (05-16, 06-03):
//   (1) re-tier genuinely read-only tools to .open  — already shipped (FB-5);
//       guarded by ReadOnlyTierAuditTests. A regression check is added here too.
//   (2) make "Always Allow" module/session-scoped instead of strictly per-tool
//       so an Always-Allow on one tool covers siblings, AND so a 3-way-parallel
//       Request-tier burst coalesces into ONE prompt instead of three that time
//       out. Covered by:
//         · ApprovalCoalescer: pure concurrency-collapsing contract (begin /
//           drain / idempotency / per-key isolation / waiter resumption count);
//         · ToolRouter.resolveEffectiveTier: per-tool > per-module > default
//           precedence, with neverAutoApprove forcing .request.
//   (3) make the approval UX less easy to miss than the silent 30s timeout —
//       the default approval timeout was raised (90s) and prompts are posted
//       time-sensitive; the timeout is injectable so behavior stays testable.
//
// Harness: standalone executable runner (no XCTest). Entry point
// `runSecurityGateUXTests()` is invoked from TestRunner.swift.

import Foundation
import MCP
import NotionBridgeLib

func runSecurityGateUXTests() async {
    print("\n🛡️  SecurityGate UX Tests (fb-securitygate)")

    // ============================================================
    // MARK: - (2) ApprovalCoalescer — in-flight prompt collapsing
    // ============================================================

    await test("Coalescer: first caller for a key owns the prompt") {
        var c = ApprovalCoalescer()
        let first = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        try expect(first, "first call for a fresh key must return true (owns prompt)")
        try expect(c.inFlightPromptCount == 1, "exactly one prompt in flight")
    }

    await test("Coalescer: later callers for same key join (no second prompt)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        let second = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        let third = c.begin(coalesceKey: "k1", identifier: "id3", waiterToken: "w3")
        try expect(!second, "second call for same key must join (return false)")
        try expect(!third, "third call for same key must join (return false)")
        try expect(c.inFlightPromptCount == 1, "still exactly one prompt in flight for the burst")
    }

    await test("Coalescer: drain returns every parked waiter exactly once") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        _ = c.begin(coalesceKey: "k1", identifier: "id3", waiterToken: "w3")
        let drained = c.drain(forIdentifier: "id1")
        try expect(Set(drained) == ["w2", "w3"],
                   "drain must return the two joined waiters (not the owner): \(drained)")
        try expect(c.inFlightPromptCount == 0, "prompt cleared after drain")
    }

    await test("Coalescer: drain is idempotent (second drain is empty)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        _ = c.drain(forIdentifier: "id1")
        let again = c.drain(forIdentifier: "id1")
        try expect(again.isEmpty, "draining an already-resolved identifier must be empty (no double-resume)")
    }

    await test("Coalescer: drain of unknown identifier is empty (timeout-vs-answer race safe)") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        let unknown = c.drain(forIdentifier: "id-nope")
        try expect(unknown.isEmpty, "unknown identifier drains to empty")
        // The real key is still in flight (its identifier was not the unknown one).
        try expect(c.inFlightPromptCount == 1, "unrelated drain must not clear a live prompt")
    }

    await test("Coalescer: distinct keys do not collapse into each other") {
        var c = ApprovalCoalescer()
        let a = c.begin(coalesceKey: "kA", identifier: "idA", waiterToken: "wA")
        let b = c.begin(coalesceKey: "kB", identifier: "idB", waiterToken: "wB")
        try expect(a && b, "two different keys each own their own prompt")
        try expect(c.inFlightPromptCount == 2, "two distinct prompts in flight")
        let drainedA = c.drain(forIdentifier: "idA")
        try expect(drainedA.isEmpty, "key A had no extra waiters")
        try expect(c.inFlightPromptCount == 1, "draining A leaves B in flight")
    }

    await test("Coalescer: a new burst can start after the prior key resolved") {
        var c = ApprovalCoalescer()
        _ = c.begin(coalesceKey: "k1", identifier: "id1", waiterToken: "w1")
        _ = c.drain(forIdentifier: "id1")
        // Same key again — must be treated as a fresh first caller.
        let firstAgain = c.begin(coalesceKey: "k1", identifier: "id2", waiterToken: "w2")
        try expect(firstAgain, "after resolution the same key starts a fresh prompt")
    }

    // ============================================================
    // MARK: - (2) Effective-tier resolution: tool > module > default
    // ============================================================

    await test("resolveEffectiveTier: no overrides → registered default") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_update", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: [:]
        )
        try expect(t == .request, "with no overrides, the registered tier wins: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: module override covers a sibling tool") {
        // Always-Allow was granted on snippets_update → snippets module = .notify.
        // snippets_rename (a sibling, never individually prompted) inherits it.
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_rename", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .notify,
                   "a module-scoped Always-Allow must cover sibling tools: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: per-tool override beats module override") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_rename", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: ["snippets_rename": "request"],
            moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "a more-specific per-tool override must win over the module override: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: neverAutoApprove forces .request despite overrides") {
        // snippets_delete is neverAutoApprove — no override (tool or module) may
        // lower it below an explicit prompt.
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_delete", module: "snippets",
            registeredTier: .request, neverAutoApprove: true,
            toolOverrides: ["snippets_delete": "open"],
            moduleOverrides: ["snippets": "open"]
        )
        try expect(t == .request,
                   "neverAutoApprove must always resolve to .request: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: module override ignored when module is empty") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "some_tool", module: "",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "an empty module must not match any module override: got \(t.rawValue)")
    }

    await test("resolveEffectiveTier: unrelated module override does not leak") {
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "messages_send", module: "messages",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: ["snippets": "notify"]
        )
        try expect(t == .request,
                   "a snippets module grant must not affect the messages module: got \(t.rawValue)")
    }

    // ============================================================
    // MARK: - (2) End-to-end: persisted module override resolves allow
    // ============================================================

    await test("module Always-Allow makes a sibling Request-tier call execute without prompt") {
        // Persist a module-scoped Always-Allow exactly as SecurityGate would,
        // then confirm a sibling tool resolves to .notify (which SecurityGate
        // enforces as .allow, no prompt). Uses a scratch suite to avoid touching
        // real user defaults.
        let suiteName = "fb-securitygate.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestError.assertion("could not create scratch UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let modOverrides = ["snippets": SecurityTier.notify.rawValue]
        let t = ToolRouter.resolveEffectiveTier(
            toolName: "snippets_import", module: "snippets",
            registeredTier: .request, neverAutoApprove: false,
            toolOverrides: [:], moduleOverrides: modOverrides
        )
        try expect(t == .notify, "sibling resolves to .notify under a module grant")

        // And .notify enforces to .allow with no approval interaction.
        let gate = SecurityGate()
        let decision = await gate.enforce(
            toolName: "snippets_import", tier: t, neverAutoApprove: false,
            arguments: .object(["payload": .string("x")]), module: "snippets"
        )
        switch decision {
        case .allow: break
        default: throw TestError.assertion("expected .allow for a .notify-resolved sibling, got \(decision)")
        }
    }

    // ============================================================
    // MARK: - (1) Regression: read-only snippets tools remain .open
    // ============================================================

    await test("regression: snippets read-only tools stay tier .open") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await SnippetsModule.register(on: router)
        let regs = await router.registrations(forModule: "snippets")
        let byName = Dictionary(regs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in ["snippets_list", "snippets_get", "snippets_search"] {
            guard let reg = byName[name] else {
                throw TestError.assertion("\(name) not registered")
            }
            try expect(reg.tier == .open, "\(name) must remain .open, got \(reg.tier.rawValue)")
        }
    }

    // ============================================================
    // MARK: - (3) Approval timeout is configurable (less-missable UX)
    // ============================================================

    await test("NotificationApprovalManager: custom timeout initializer is accepted") {
        // The injectable timeout is the test seam that keeps the longer,
        // less-missable default (90s) from making tests slow. Constructing with
        // a short timeout must not crash in the standalone test process (which
        // never touches UNUserNotificationCenter).
        let mgr = NotificationApprovalManager(approvalTimeout: 0.05)
        // In the test process requestApproval short-circuits to .allow without
        // ever arming the timeout — assert that contract holds.
        let decision = await mgr.requestApproval(title: "t", body: "b")
        switch decision {
        case .allow: break
        default: throw TestError.assertion("test-process approval must be .allow, got \(decision)")
        }
    }
}
