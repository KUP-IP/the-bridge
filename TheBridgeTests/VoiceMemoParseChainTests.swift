// VoiceMemoParseChainTests.swift — FRONTIER-FIRST Understand chain (Phase 1, W1)
// TheBridge · Tests
//
// Covers the parse provider-chain abstraction + plan provenance:
//  • providers(for:) chain ORDER + shape per curator mode
//  • parse() walks the chain: first available rung that yields a plan wins
//  • .auto is FRONTIER-FIRST (Cloud → Local → Heuristic) by availability
//  • degraded set IFF an earlier AVAILABLE rung returned nil at runtime
//  • the heuristic floor is always available and never nil (guaranteed)
//  • provenance is stamped from the winning rung
//  • .agent / .heuristics resolve to the floor
//
// All rungs are injected STUBS via `VoiceMemoParseRouter.providerOverride` — no
// real network / Ollama / agent. The REAL CloudParseProvider is unavailable in
// the hermetic test env (no providers.json / Keychain key), so the production
// chains are also exercised offline here; the real cloud parse path (request
// shape, JSON map, degrade-on-failure) is covered in VoiceMemoCloudParseTests.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Stub provider (controllable availability + canned/nil plan)

private struct StubParseProvider: VoiceMemoParseProvider {
    let provenance: ParseProvenance
    let available: Bool
    /// nil ⇒ this rung fails at runtime (returns nil from parse) even if available.
    let yieldsPlan: Bool
    /// Records that parse() was actually invoked (to assert short-circuit).
    let onParse: (@Sendable () -> Void)?

    init(
        provenance: ParseProvenance,
        available: Bool,
        yieldsPlan: Bool,
        onParse: (@Sendable () -> Void)? = nil
    ) {
        self.provenance = provenance
        self.available = available
        self.yieldsPlan = yieldsPlan
        self.onParse = onParse
    }

    func isAvailable() -> Bool { available }

    func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        onParse?()
        guard yieldsPlan else { return nil }
        // Provenance is (re)stamped by the router from `self.provenance`; seed a
        // distinct sentinel title so we can also confirm the winning rung's plan
        // is the one returned.
        return VoiceMemoPlan(
            generatedTitle: "stub-\(provenance.rawValue)",
            skipMemoryKeep: false,
            summary: "s",
            actions: [],
            intents: [VoiceMemoIntent(kind: .review, confidence: 0.5)],
            provenance: provenance,
            degraded: false
        )
    }
}

/// A thread-safe invocation flag for short-circuit assertions.
private final class InvocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var hit = false
    func mark() { lock.lock(); hit = true; lock.unlock() }
    var wasHit: Bool { lock.lock(); defer { lock.unlock() }; return hit }
}

// MARK: - Mode helper

/// Set the curator mode in UserDefaults for the duration of `body`, then restore.
/// Also force the local-Ollama routing flag OFF (and restore it) so the REAL
/// production chain's `LocalParseProvider.isAvailable()` is deterministic
/// regardless of suite order (an earlier suite that flipped the flag on must not
/// leak into these tests). Stub-injected tests bypass `providers(for:)` so this
/// is a no-op for them; real-chain tests rely on it.
private func withCuratorMode(_ mode: VoiceMemoCuratorMode, _ body: () async -> Void) async {
    let modeKey = BridgeDefaults.voiceMemoCuratorMode
    let ollamaKey = BridgeDefaults.voiceMemoOllamaRouting
    let priorMode = UserDefaults.standard.string(forKey: modeKey)
    let priorOllama = UserDefaults.standard.object(forKey: ollamaKey)
    UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    UserDefaults.standard.set(false, forKey: ollamaKey)
    defer {
        if let priorMode { UserDefaults.standard.set(priorMode, forKey: modeKey) }
        else { UserDefaults.standard.removeObject(forKey: modeKey) }
        if let priorOllama { UserDefaults.standard.set(priorOllama, forKey: ollamaKey) }
        else { UserDefaults.standard.removeObject(forKey: ollamaKey) }
    }
    await body()
}

func runVoiceMemoParseChainTests() async {
    print("\n\u{1F3D4}\u{FE0F} Voice Memo Parse Chain Tests (FRONTIER-FIRST W1)")

    // Always clear the override after each test block so production chains aren't
    // affected by a leaked stub.
    defer { VoiceMemoParseRouter.providerOverride = nil }

    // ── providers(for:) chain order + shape per mode ──────────────────────────

    await test("providers(.auto) is frontier-first: cloud → local → heuristic") {
        let chain = VoiceMemoParseRouter.providers(for: .auto)
        try expect(chain.map { $0.provenance } == [.cloud, .local, .heuristic],
                   "auto chain must be [cloud, local, heuristic], got \(chain.map { $0.provenance })")
    }

    await test("providers(.cloud) is [cloud, heuristic]") {
        let chain = VoiceMemoParseRouter.providers(for: .cloud)
        try expect(chain.map { $0.provenance } == [.cloud, .heuristic],
                   "cloud chain must be [cloud, heuristic], got \(chain.map { $0.provenance })")
    }

    await test("providers(.local) is [local, heuristic]") {
        let chain = VoiceMemoParseRouter.providers(for: .local)
        try expect(chain.map { $0.provenance } == [.local, .heuristic])
    }

    await test("providers(.heuristics) is [heuristic] only") {
        let chain = VoiceMemoParseRouter.providers(for: .heuristics)
        try expect(chain.map { $0.provenance } == [.heuristic])
    }

    await test("providers(.agent) is [heuristic] floor (agent parses out-of-process)") {
        let chain = VoiceMemoParseRouter.providers(for: .agent)
        try expect(chain.map { $0.provenance } == [.heuristic])
    }

    await test("every mode's chain ends in the heuristic floor") {
        for mode in VoiceMemoCuratorMode.allCases {
            let chain = VoiceMemoParseRouter.providers(for: mode)
            try expect(chain.last?.provenance == .heuristic,
                       "mode \(mode) chain must end in heuristic")
        }
    }

    // ── parse(): winner selection + provenance stamp ──────────────────────────

    await test(".auto picks Cloud when cloud is available + yields") {
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: true, yieldsPlan: true),
            StubParseProvider(provenance: .local, available: true, yieldsPlan: true),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true),
        ] }
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "hello", fallbackTitle: "F")
            // Note: assertions inside an async closure can't `throw` out to `test`,
            // so funnel through a captured flag checked after.
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .cloud, "expected cloud winner, got \(String(describing: chainResult?.0))")
        try expect(chainResult?.1 == false, "no earlier available rung failed ⇒ not degraded")
        try expect(chainResult?.2 == "stub-cloud", "cloud rung's plan must be returned")
    }

    await test(".auto degrades to Local when cloud available but returns nil") {
        let cloudHit = InvocationFlag()
        let localHit = InvocationFlag()
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: true, yieldsPlan: false, onParse: { cloudHit.mark() }),
            StubParseProvider(provenance: .local, available: true, yieldsPlan: true, onParse: { localHit.mark() }),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true),
        ] }
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "hello", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(cloudHit.wasHit, "cloud parse() should have been attempted")
        try expect(localHit.wasHit, "local parse() should have been attempted after cloud nil")
        try expect(chainResult?.0 == .local, "expected local winner")
        try expect(chainResult?.1 == true, "an earlier AVAILABLE rung returned nil ⇒ degraded")
    }

    await test(".auto skips UNavailable cloud without marking degraded") {
        let cloudHit = InvocationFlag()
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: false, yieldsPlan: true, onParse: { cloudHit.mark() }),
            StubParseProvider(provenance: .local, available: true, yieldsPlan: true),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true),
        ] }
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "hello", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(!cloudHit.wasHit, "an UNavailable rung must NOT have parse() called")
        try expect(chainResult?.0 == .local, "expected local winner (cloud unavailable)")
        try expect(chainResult?.1 == false, "skipping an UNavailable rung is NOT a degrade")
    }

    await test(".auto falls to Heuristic floor when cloud+local both fail (degraded)") {
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: true, yieldsPlan: false),
            StubParseProvider(provenance: .local, available: true, yieldsPlan: false),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true),
        ] }
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "hello", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .heuristic, "expected heuristic floor winner")
        try expect(chainResult?.1 == true, "two earlier available rungs failed ⇒ degraded")
    }

    await test("winner short-circuits: later rungs' parse() not called") {
        let localHit = InvocationFlag()
        let heuristicHit = InvocationFlag()
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: true, yieldsPlan: true),
            StubParseProvider(provenance: .local, available: true, yieldsPlan: true, onParse: { localHit.mark() }),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true, onParse: { heuristicHit.mark() }),
        ] }
        await withCuratorMode(.auto) {
            _ = await VoiceMemoParseRouter.parse(transcript: "hello", fallbackTitle: "F")
        }
        try expect(!localHit.wasHit, "local parse() must not run once cloud wins")
        try expect(!heuristicHit.wasHit, "heuristic parse() must not run once cloud wins")
    }

    // ── mode-specific routing ────────────────────────────────────────────────

    await test(".heuristics resolves to the floor (provenance .heuristic, not degraded)") {
        // Real production chain (override nil) — heuristics mode is floor-only.
        VoiceMemoParseRouter.providerOverride = nil
        await withCuratorMode(.heuristics) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "remind me to call Bob", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .heuristic, "heuristics mode must produce .heuristic provenance")
        try expect(chainResult?.1 == false, "floor-only chain is never degraded")
    }

    await test(".agent in-process preview resolves to the heuristic floor") {
        VoiceMemoParseRouter.providerOverride = nil
        await withCuratorMode(.agent) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "just some note", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .heuristic, "agent in-process preview uses the floor")
        try expect(chainResult?.1 == false)
    }

    await test(".auto with the REAL cloud (unavailable in hermetic env) falls through offline") {
        // The real CloudParseProvider is unavailable here (no providers.json /
        // Keychain key ⇒ isAvailable==false). With no Ollama model configured in
        // the hermetic test env, Local is also unavailable, so production .auto
        // must land on the heuristic floor with NO degrade (unavailable rungs
        // don't degrade).
        VoiceMemoParseRouter.providerOverride = nil
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParseRouter.parse(transcript: "remind me to ship", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .heuristic, "real .auto chain falls to heuristic offline")
        try expect(chainResult?.1 == false, "stub-unavailable cloud is skipped, not a degrade")
    }

    // ── heuristic floor guarantees ───────────────────────────────────────────

    await test("HeuristicParseProvider is always available and never nil") {
        let h = HeuristicParseProvider()
        try expect(h.isAvailable(), "heuristic must always be available")
        let plan = await h.parse(transcript: "remind me to water plants", fallbackTitle: "F", recordingPath: "")
        try expect(plan != nil, "heuristic must never return nil")
        try expect(plan?.provenance == .heuristic, "heuristic stamps .heuristic")
        try expect(plan?.intents.isEmpty == false, "heuristic always yields ≥1 intent")
    }

    await test("CloudParseProvider is unavailable + nil with no provider configured (hermetic)") {
        // W2: the cloud rung is REAL, but in the hermetic test env there is no
        // providers.json / Keychain key, so isAvailable() is false and parse()
        // returns nil — the production .auto/.cloud chains still fall through
        // offline exactly as before. (Behavioral cloud parsing is covered in
        // VoiceMemoCloudParseTests with an injected transport + provider.)
        let c = CloudParseProvider()
        try expect(!c.isAvailable(), "cloud rung must be unavailable with no provider/key")
        let plan = await c.parse(transcript: "x", fallbackTitle: "F", recordingPath: "")
        try expect(plan == nil, "cloud rung must return nil when unavailable")
        try expect(c.provenance == .cloud, "cloud provenance is .cloud")
    }

    await test("VoiceMemoPlan defaults provenance .heuristic + not degraded") {
        // Locks the model default so every pre-existing constructor stays heuristic.
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [])
        try expect(plan.provenance == .heuristic, "default provenance must be .heuristic")
        try expect(plan.degraded == false, "default degraded must be false")
    }

    await test("ParseProvenance is Codable round-trip for all cases") {
        for p in [ParseProvenance.agent, .cloud, .local, .heuristic] {
            let data = try JSONEncoder().encode(p)
            let back = try JSONDecoder().decode(ParseProvenance.self, from: data)
            try expect(back == p, "round-trip failed for \(p)")
        }
    }

    await test("parseWithOptionalOllama shim routes through the chain (provenance stamped)") {
        // The retained shim must now yield a provenance-stamped plan (chain walk),
        // proving processOne / ReviewResolver callers also get FRONTIER-FIRST.
        VoiceMemoParseRouter.providerOverride = { _ in [
            StubParseProvider(provenance: .cloud, available: true, yieldsPlan: true),
            StubParseProvider(provenance: .heuristic, available: true, yieldsPlan: true),
        ] }
        await withCuratorMode(.auto) {
            let plan = await VoiceMemoParser.parseWithOptionalOllama(transcript: "hi", fallbackTitle: "F")
            chainResult = (plan.provenance, plan.degraded, plan.generatedTitle)
        }
        try expect(chainResult?.0 == .cloud, "shim must stamp the winning rung's provenance")
        VoiceMemoParseRouter.providerOverride = nil
    }
}

// File-scope sink for async-closure results (the harness `test` closure can't
// receive a throw raised inside a nested `await body()` closure). Each test
// writes here inside `withCuratorMode`, then asserts after the closure returns.
private nonisolated(unsafe) var chainResult: (ParseProvenance, Bool, String)?
