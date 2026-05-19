// CommandPaletteTests.swift — cmd-w3 (Commands palette: search + gate + wiring)
// NotionBridge · Tests
//
// Covers the GUI-FREE W3 glue that joins the W1 spike GUI shell to the
// W2 data layer:
//   (A) CommandPaletteSearch       — fuzzy match / deterministic ranking
//   (B) command-not-found          — empty result + .notFound commit
//   (C) CommandsManager integration via the INJECTED BodyFetcher
//       (synthetic recorded /markdown — zero network)
//   (D) CommandsPaletteGate        — default-OFF / fail-closed env gate
//   (E) AppDelegate gating ON/OFF  — the pure decision (no NSApp launch),
//       same proof shape as the streamableHTTP connector-gating test
//   (F) CommandPaletteCoordinator  — search + commit (paste/notFound/
//       unavailable + offline-fallback) joining (A)+(C)
//
// HONEST GUI CEILING (NOT faked here): the Carbon hot-key actually
// firing, the non-activating NSPanel receiving keystrokes, and a real
// cross-app Cmd-V paste require a live WindowServer/login session and
// are an explicit operator manual-smoke (see the W3 report). Only the
// injectable, deterministic logic is asserted. The imported spike's 21
// GUI-free units are retained verbatim in CommandBoxSpikeTests.swift.

import Foundation
import AppKit
import NotionBridgeLib

// Synthetic /markdown JSON envelope helper (file-scoped @Sendable so it
// can be captured by the @Sendable BodyFetcher closures under Swift 6).
@Sendable private func mdJSON(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["markdown": s])
    return String(data: data, encoding: .utf8)!
}

private enum PaletteTestError: Error { case boom }

// A private, uniquely-keyed UserDefaults suite so the registry-provider
// tests never read/write the process-global `com.notionbridge.skills`
// (the same isolation discipline the SecurityGate flakefix established).
@Sendable private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suite = "kup.solutions.notion-bridge.cmd-sb.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    return (d, suite)
}

/// Write a skills-registry JSON array (the exact `com.notionbridge.skills`
/// shape) into `defaults[key]`. Mirrors how `manage_skill` / SkillsManager
/// persist — name + notionPageId + enabled (+ benign extra fields the
/// provider's tolerant decoder must ignore).
@Sendable private func seedRegistry(
    _ defaults: UserDefaults, key: String,
    _ rows: [(name: String, pageId: String, enabled: Bool)]
) {
    let arr: [[String: Any]] = rows.map {
        [
            "name": $0.name,
            "notionPageId": $0.pageId,
            "enabled": $0.enabled,
            // Extra persisted fields the provider must tolerate/ignore:
            "visibility": "standard",
            "summary": "ignored-by-palette",
            "triggerPhrases": ["t1"],
            "antiTriggerPhrases": [],
            "platform": "notion",
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: arr)
    defaults.set(data, forKey: key)
}

func runCommandPaletteTests() async {
    print("\n\u{1F5C3}\u{FE0F}  CommandPalette Tests (cmd-w3 · palette wiring)")

    // A valid 32-hex page id; NotionPageRef normalizes to the dashed form.
    let pidSig  = "aaaa1111bbbb2222cccc3333dddd4444"
    let pidAddr = "11112222333344445555666677778888"

    func descriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(id: pidSig, name: "Email Signature",
                              abbreviation: "sig", group: "Email",
                              tags: ["personal", "footer"]),
            CommandDescriptor(id: pidAddr, name: "Mailing Address",
                              abbreviation: "addr", group: "Personal",
                              tags: ["home"]),
            CommandDescriptor(id: "cccc1111dddd2222eeee3333ffff4444",
                              name: "Standup Update", abbreviation: "su",
                              group: "Work", tags: ["daily", "agenda"]),
        ]
    }

    // ============================================================
    // MARK: (A) CommandPaletteSearch — fuzzy match + ranking
    // ============================================================

    await test("Search: empty query returns ALL descriptors (stable order)") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "")
        try expect(r.count == 3, "empty query must show every command, got \(r.count)")
        try expect(r.allSatisfy { $0.score == 0 }, "empty query rows score 0")
        // Stable tie-break: score↓ then name↑ → addr/sig/standup by name.
        try expect(r.map { $0.descriptor.name } == ["Email Signature", "Mailing Address", "Standup Update"],
                   "empty-query order must be name-ascending, got \(r.map { $0.descriptor.name })")
    }

    await test("Search: blank/whitespace query is treated as empty") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "   \n ")
        try expect(r.count == 3, "whitespace-only query == empty (show all)")
    }

    await test("Search: exact abbreviation match scores highest (1000)") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "sig")
        try expect(r.first?.descriptor.id == pidSig, "exact abbr must rank #1")
        try expect(r.first?.score == 1000, "exact abbr == 1000, got \(r.first?.score ?? -1)")
    }

    await test("Search: exact abbreviation match is case-insensitive") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "SIG")
        try expect(r.first?.descriptor.id == pidSig && r.first?.score == 1000,
                   "uppercase query must still exact-match the abbreviation")
    }

    await test("Search: abbreviation prefix beats name prefix") {
        // "s" is an abbr-prefix of "sig"/"su" (800) and a name-prefix of
        // "Standup Update" (500) — an abbr-prefix row must outrank it.
        let r = CommandPaletteSearch.rank(descriptors(), query: "s")
        try expect(r.first?.score == 800, "abbr-prefix (800) must outrank name-prefix (500)")
        try expect(["sig", "su"].contains(r.first?.descriptor.abbreviation ?? ""),
                   "top hit must be an abbr-prefix row")
    }

    await test("Search: exact name match scores 700") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "Email Signature")
        try expect(r.first?.descriptor.id == pidSig, "exact name must match")
        try expect(r.first?.score == 700, "exact name == 700, got \(r.first?.score ?? -1)")
    }

    await test("Search: name prefix scores 500") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "Mail")
        try expect(r.first?.descriptor.id == pidAddr, "name-prefix must match Mailing Address")
        try expect(r.first?.score == 500, "name prefix == 500, got \(r.first?.score ?? -1)")
    }

    await test("Search: fuzzy subsequence in name matches (no prefix)") {
        // "alig" is a subsequence of "mailing address" but not a prefix.
        let r = CommandPaletteSearch.rank(descriptors(), query: "alig")
        try expect(r.contains { $0.descriptor.id == pidAddr },
                   "fuzzy subsequence in name must still match")
        let row = r.first { $0.descriptor.id == pidAddr }!
        try expect(row.score <= 200 && row.score > 0,
                   "name-subsequence score is in (0,200], got \(row.score)")
    }

    await test("Search: tighter subsequence outranks looser one (gap penalty)") {
        let tight = CommandDescriptor(id: "d1", name: "abxx", abbreviation: "zzz")
        let loose = CommandDescriptor(id: "d2", name: "axxxxxxxxxb", abbreviation: "yyy")
        let r = CommandPaletteSearch.rank([loose, tight], query: "ab")
        try expect(r.first?.descriptor.id == "d1",
                   "the more compact subsequence must rank first, got \(r.map { $0.descriptor.id })")
    }

    await test("Search: matches group/tags haystack as a last resort") {
        // "agnd" is a subsequence of the tag "agenda" only.
        let r = CommandPaletteSearch.rank(descriptors(), query: "agnd")
        try expect(r.count == 1, "only the tag-bearing row should match, got \(r.count)")
        try expect(r.first?.descriptor.abbreviation == "su", "must be the Standup row (tag 'agenda')")
        try expect((r.first?.score ?? 0) <= 100, "tag-haystack score is <=100")
    }

    await test("Search: non-matching query yields zero results (filtered)") {
        let r = CommandPaletteSearch.rank(descriptors(), query: "zzzzqqqq")
        try expect(r.isEmpty, "a query matching nothing must produce an empty list")
    }

    await test("Search: deterministic tie-break by (score, name, id)") {
        let a = CommandDescriptor(id: "id-2", name: "Same", abbreviation: "x1")
        let b = CommandDescriptor(id: "id-1", name: "Same", abbreviation: "x2")
        // Both score identically on "same" (exact name == 700). Tie-break
        // is name↑ (equal) then id↑ → id-1 before id-2, regardless of input order.
        let r1 = CommandPaletteSearch.rank([a, b], query: "same")
        let r2 = CommandPaletteSearch.rank([b, a], query: "same")
        try expect(r1.map { $0.descriptor.id } == ["id-1", "id-2"], "tie-break must be id-ascending")
        try expect(r1.map { $0.descriptor.id } == r2.map { $0.descriptor.id },
                   "ranking must be input-order-independent (deterministic)")
    }

    await test("Search: isSubsequence / gapPenalty primitives are correct") {
        try expect(CommandPaletteSearch.isSubsequence(Array("ace"), of: Array("abcde")),
                   "ace ⊆ abcde must be true")
        try expect(!CommandPaletteSearch.isSubsequence(Array("aec"), of: Array("abcde")),
                   "out-of-order aec must NOT be a subsequence")
        try expect(CommandPaletteSearch.gapPenalty(Array("ab"), in: Array("ab")) == 0,
                   "adjacent match has zero gap penalty")
        try expect((CommandPaletteSearch.gapPenalty(Array("ab"), in: Array("axxb")) ?? -1) == 2,
                   "two interleaved chars → gap penalty 2")
        try expect(CommandPaletteSearch.gapPenalty(Array("qz"), in: Array("abc")) == nil,
                   "no subsequence → nil penalty")
    }

    await test("Search.best returns the single top descriptor or nil") {
        try expect(CommandPaletteSearch.best(descriptors(), query: "sig")?.id == pidSig,
                   "best() must return the #1 ranked descriptor")
        try expect(CommandPaletteSearch.best(descriptors(), query: "no-such") == nil,
                   "best() must be nil when nothing matches")
        try expect(CommandPaletteSearch.best([], query: "anything") == nil,
                   "best() on an empty catalog must be nil")
    }

    await test("CommandDescriptor is Codable round-trip stable") {
        let d = CommandDescriptor(id: pidSig, name: "Email Signature",
                                  abbreviation: "sig", group: "Email",
                                  tags: ["a", "b"])
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(CommandDescriptor.self, from: data)
        try expect(back == d, "Codable round-trip must preserve the descriptor")
    }

    // ============================================================
    // MARK: (D) CommandsPaletteGate — default-OFF / fail-closed
    // ============================================================

    // cmd-ux: the palette is now ON BY DEFAULT, governed by a persisted
    // master toggle. The env var only FORCE-overrides ("1" on / "0" off);
    // anything else defers to the persisted pref, which DEFAULTS TO TRUE
    // when the key has never been written. The pref reader is injected so
    // these stay PURE (no UserDefaults.standard coupling).

    await test("Gate: unset env + unwritten pref is ENABLED (default-ON)") {
        let g = CommandsPaletteGate(environment: [:], persistedPreference: { nil })
        try expect(g.isEnabled,
                   "an unset env + never-written pref must default the palette ON")
    }

    await test("Gate: env \"1\" force-enables regardless of the pref") {
        try expect(CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": "1"],
                                       persistedPreference: { false }).isEnabled,
                   "env \"1\" must force ON even when the pref is false")
    }

    await test("Gate: env \"0\" force-DISABLES regardless of the pref (kill-switch)") {
        try expect(!CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": "0"],
                                        persistedPreference: { true }).isEnabled,
                   "env \"0\" must force OFF even when the pref is true")
    }

    await test("Gate: non-decisive env value defers to the persisted pref") {
        for v in ["true", "TRUE", "yes", "on", " 1", "1 ", "", "enable"] {
            try expect(CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": v],
                                           persistedPreference: { true }).isEnabled,
                       "value \"\(v)\" is not a force-override → pref(true) ⇒ ON")
            try expect(!CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": v],
                                            persistedPreference: { false }).isEnabled,
                       "value \"\(v)\" is not a force-override → pref(false) ⇒ OFF")
        }
    }

    await test("Gate: persisted pref decides when no env override") {
        try expect(CommandsPaletteGate(environment: [:], persistedPreference: { true }).isEnabled,
                   "pref true (no env) ⇒ ON")
        try expect(!CommandsPaletteGate(environment: [:], persistedPreference: { false }).isEnabled,
                   "pref false (no env) ⇒ OFF")
    }

    await test("Gate: defaultEnabled is true (palette ships ON)") {
        try expect(CommandsPaletteGate.defaultEnabled,
                   "the shipping default must be ON")
        try expect(BridgeDefaults.commandsPaletteEnabled == "com.notionbridge.commandsPaletteEnabled",
                   "persisted master-toggle key identity guard")
    }

    await test("Gate: env key is the BRIDGE_ENABLE_* family name") {
        try expect(CommandsPaletteGate.enableEnvKey == "BRIDGE_ENABLE_COMMANDS",
                   "gate env key must be BRIDGE_ENABLE_COMMANDS")
    }

    await test("Gate is Equatable / value-typed (deterministic under test)") {
        try expect(CommandsPaletteGate(environment: [:], persistedPreference: { false })
                       == CommandsPaletteGate(environment: ["X": "y"], persistedPreference: { false }),
                   "two disabled gates compare equal")
        try expect(CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": "1"], persistedPreference: { false })
                       != CommandsPaletteGate(environment: [:], persistedPreference: { false }),
                   "enabled vs disabled must differ")
    }

    // ============================================================
    // MARK: (E) AppDelegate gating decision — no NSApp launch
    //   Same proof shape as the streamableHTTP connector-gating test:
    //   a PURE static decision, both arms, with NO GUI side effects.
    // ============================================================

    // cmd-ux: default-ON. The test process never writes
    // `commandsPaletteEnabled`, so the unwritten pref ⇒ defaultEnabled
    // (true). The env force-overrides are deterministic regardless.

    await test("AppDelegate.shouldStartCommandsPalette: ON when env unset (default-ON)") {
        // No env override + the test process never wrote the pref key ⇒
        // the gate's defaultEnabled (true) decides.
        UserDefaults.standard.removeObject(forKey: BridgeDefaults.commandsPaletteEnabled)
        try expect(AppDelegate.shouldStartCommandsPalette(environment: [:]),
                   "the palette now ships ON — an unset env + unwritten pref must start it")
    }

    await test("AppDelegate.shouldStartCommandsPalette: env \"0\" force-OFF, \"1\" force-ON") {
        try expect(AppDelegate.shouldStartCommandsPalette(environment: ["BRIDGE_ENABLE_COMMANDS": "1"]),
                   "BRIDGE_ENABLE_COMMANDS=1 must force the palette on")
        try expect(!AppDelegate.shouldStartCommandsPalette(environment: ["BRIDGE_ENABLE_COMMANDS": "0"]),
                   "BRIDGE_ENABLE_COMMANDS=0 must force the palette off (kill-switch)")
    }

    await test("AppDelegate gating decision matches CommandsPaletteGate exactly") {
        // The env force-override arms are pref-independent, so the
        // AppDelegate static must equal the gate for the same env.
        for env in [["BRIDGE_ENABLE_COMMANDS": "1"], ["BRIDGE_ENABLE_COMMANDS": "0"]] {
            try expect(AppDelegate.shouldStartCommandsPalette(environment: env)
                           == CommandsPaletteGate(environment: env).isEnabled,
                       "the AppDelegate decision must delegate to the single-source gate for \(env)")
        }
    }

    // ============================================================
    // MARK: (C)+(F) Coordinator: search + commit via injected W2 manager
    // ============================================================

    await test("Coordinator.search ranks the provider's descriptor list") {
        let mgr = CommandsManager(fetcher: { _ in mdJSON("unused") })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let r = await coord.search("sig")
        try expect(r.first?.descriptor.id == pidSig, "coordinator must rank via CommandPaletteSearch")
    }

    await test("Coordinator.commit(descriptor) fetches the resolved body via CommandsManager") {
        nonisolated(unsafe) var calledWith: [String] = []
        let mgr = CommandsManager(fetcher: { id in
            calledWith.append(id)
            return mdJSON("=== resolved signature body ===")
        })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let result = await coord.commit(descriptors()[0])  // Email Signature
        guard case .paste(let body) = result else {
            throw TestError.assertion("expected .paste, got \(result)")
        }
        try expect(body == "=== resolved signature body ===",
                   "commit must return the W2-resolved body, got \(body)")
        try expect(calledWith.count == 1, "exactly one fetch (no duplicate fetch/cache layer)")
    }

    await test("Coordinator.commit(query:) resolves the best match then fetches its body") {
        nonisolated(unsafe) var fetchedId = ""
        let mgr = CommandsManager(fetcher: { id in fetchedId = id; return mdJSON("addr-body") })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let result = await coord.commit(query: "addr")
        guard case .paste(let body) = result else {
            throw TestError.assertion("expected .paste for a matching query, got \(result)")
        }
        try expect(body == "addr-body", "must paste the best-match body")
        try expect(fetchedId.replacingOccurrences(of: "-", with: "") == pidAddr,
                   "must fetch the BEST match's page id (normalized), got \(fetchedId)")
    }

    await test("Coordinator.commit(query:) returns .notFound for an unmatched query (NO paste)") {
        nonisolated(unsafe) var fetched = false
        let mgr = CommandsManager(fetcher: { _ in fetched = true; return mdJSON("x") })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let result = await coord.commit(query: "zzzz-no-such")
        guard case .notFound(let q) = result else {
            throw TestError.assertion("expected .notFound, got \(result)")
        }
        try expect(q == "zzzz-no-such", "the unmatched query must be echoed back")
        try expect(!fetched, "a not-found commit must NOT fetch — never paste a guessed command")
    }

    await test("Coordinator.commit(query:) on an empty catalog is .notFound") {
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider([]), manager: mgr)
        let result = await coord.commit(query: "anything")
        guard case .notFound = result else {
            throw TestError.assertion("empty catalog commit must be .notFound, got \(result)")
        }
    }

    await test("Coordinator.commit surfaces .unavailable when fetch fails with no cache") {
        let mgr = CommandsManager(fetcher: { _ in throw PaletteTestError.boom })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let result = await coord.commit(descriptors()[0])
        guard case .unavailable(let name, let reason) = result else {
            throw TestError.assertion("expected .unavailable, got \(result)")
        }
        try expect(name == "Email Signature", "unavailable must name the command")
        try expect(!reason.isEmpty, "unavailable must carry a reason")
    }

    await test("Coordinator.commit consumes the W2 TTL cache (no duplicate fetch on repeat)") {
        // Proves the palette CONSUMES CommandsManager and does NOT add its
        // own fetch/cache layer: a 2nd commit of the same command within
        // the W2 TTL must be served from the W2 cache (fetcher called once).
        nonisolated(unsafe) var calls = 0
        let mgr = CommandsManager(fetcher: { _ in
            calls += 1
            return mdJSON("BODY-v\(calls)")
        })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let r1 = await coord.commit(descriptors()[1])
        let r2 = await coord.commit(descriptors()[1])
        try expect(r1 == .paste("BODY-v1"), "first commit fetches + caches via W2, got \(r1)")
        try expect(r2 == .paste("BODY-v1"),
                   "second commit must be the W2-cached body (NOT a re-fetch), got \(r2)")
        try expect(calls == 1, "the W2 fetcher must run exactly once — no duplicate cache layer, got \(calls)")
    }

    await test("Coordinator.commit propagates W2 contract: resync eviction + failed refetch ⇒ .unavailable") {
        // Honest W2 contract: `resync(pageId:)` EVICTS the entry (it does
        // not merely expire it), so a subsequent failing live fetch has
        // nothing to offline-fall-back to and CommandsManager surfaces
        // `.unavailable`. The coordinator must faithfully propagate that
        // (the offline-fallback-on-EXPIRY path is covered by W2's own
        // CommandsDataTests with an injected clock — not reachable
        // deterministically through the coordinator's no-clock commit()).
        nonisolated(unsafe) var attempt = 0
        let mgr = CommandsManager(fetcher: { _ in
            attempt += 1
            if attempt == 1 { return mdJSON("ONLY-ONCE") }
            throw PaletteTestError.boom
        })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        _ = await coord.commit(descriptors()[1])          // populate W2 cache
        await mgr.resync(pageId: descriptors()[1].id)     // EVICT the entry
        let result = await coord.commit(descriptors()[1]) // refetch → throws
        guard case .unavailable(let name, _) = result else {
            throw TestError.assertion("evicted + failed refetch must be .unavailable, got \(result)")
        }
        try expect(name == "Mailing Address", "unavailable must name the command")
    }

    await test("Coordinator.commit resolves Notion mention tags via W2 (plain-text body)") {
        let mgr = CommandsManager(
            titleLookup: { _ in nil },
            fetcher: { _ in mdJSON(#"start <mention-page url="https://www.notion.so/p"/> end"#) }
        )
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(descriptors()), manager: mgr)
        let result = await coord.commit(descriptors()[0])
        guard case .paste(let body) = result else {
            throw TestError.assertion("expected .paste, got \(result)")
        }
        try expect(body == "start [link](https://www.notion.so/p) end",
                   "the pasted body must be the W2 mention-resolved plain text, got \(body)")
    }

    await test("CommandPaletteCommitResult is Equatable (case + payload)") {
        try expect(CommandPaletteCommitResult.paste("a") == .paste("a"))
        try expect(CommandPaletteCommitResult.paste("a") != .paste("b"))
        try expect(CommandPaletteCommitResult.notFound(query: "q") == .notFound(query: "q"))
        try expect(CommandPaletteCommitResult.paste("a") != .notFound(query: "a"))
    }

    await test("StaticCommandDescriptorProvider default is the safe empty list") {
        let empty = await StaticCommandDescriptorProvider().descriptors()
        try expect(empty.isEmpty,
                   "the production-default provider must be empty (no operator DS wired yet) — fail-safe, never a crash")
    }

    // ============================================================
    // MARK: (G) RegistrySkillsCommandProvider — palette ← skills registry
    //   The descriptor source is now the EXISTING skills registry
    //   (`com.notionbridge.skills`). Every ENABLED entry is a selectable
    //   command. Driven entirely off an ISOLATED UserDefaults suite —
    //   zero process-global / network coupling.
    // ============================================================

    await test("RegistryProvider maps ENABLED registry entries → descriptors") {
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Email Signature", pageId: pidSig, enabled: true),
            (name: "Mailing Address", pageId: pidAddr, enabled: true),
        ])
        let provider = RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills)
        let got = await provider.descriptors()
        try expect(got.count == 2, "both enabled entries must map, got \(got.count)")
        let byId = Dictionary(uniqueKeysWithValues: got.map { ($0.id, $0) })
        try expect(byId[pidSig]?.name == "Email Signature",
                   "page id must come from notionPageId; name from the registry name")
        try expect(byId[pidSig]?.abbreviation == "Email Signature",
                   "name is BOTH the descriptor name AND the abbreviation/trigger (registry has no short form)")
    }

    await test("RegistryProvider EXCLUDES disabled entries") {
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "On Skill", pageId: pidSig, enabled: true),
            (name: "Off Skill", pageId: pidAddr, enabled: false),
        ])
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.count == 1, "only the enabled entry is selectable, got \(got.count)")
        try expect(got.first?.id == pidSig, "the disabled entry must be filtered out")
    }

    await test("RegistryProvider drops entries with a blank page id") {
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Has Page", pageId: pidSig, enabled: true),
            (name: "No Page", pageId: "   ", enabled: true),
        ])
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.count == 1 && got.first?.id == pidSig,
                   "a page-id-less row can never resolve a body — not a command, got \(got.map { $0.name })")
    }

    await test("RegistryProvider on a MISSING registry key → empty (no crash)") {
        let (_, suite) = makeIsolatedDefaults()  // nothing seeded
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.isEmpty, "an unset registry must yield an empty list, got \(got.count)")
    }

    await test("RegistryProvider on MALFORMED registry data → empty (no crash)") {
        let (d, suite) = makeIsolatedDefaults()
        d.set(Data("not json".utf8), forKey: BridgeDefaults.skills)
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.isEmpty, "corrupt registry bytes must fail safe to empty, got \(got.count)")
    }

    await test("RegistryProvider tolerates legacy rows missing the 'enabled' flag") {
        // SkillsManager treats a missing `enabled` as enabled; the
        // provider's decoder must mirror that exactly.
        let (d, suite) = makeIsolatedDefaults()
        let legacy: [[String: Any]] = [["name": "Legacy", "notionPageId": pidSig]]
        d.set(try JSONSerialization.data(withJSONObject: legacy), forKey: BridgeDefaults.skills)
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.count == 1 && got.first?.name == "Legacy",
                   "a legacy row with no 'enabled' key must default to enabled, got \(got.map { $0.name })")
    }

    await test("RegistryProvider feeds CommandPaletteSearch end-to-end (registry name == abbreviation ⇒ exact-abbr 1000)") {
        // The provider maps the registry NAME onto BOTH descriptor.name
        // AND descriptor.abbreviation (registry rows have no short form).
        // CommandPaletteSearch scores an exact abbreviation match 1000
        // (it dominates exact-name 700). So an exact registry-name query
        // is ALSO an exact-abbreviation match and must score 1000 — the
        // correct invariant for this name-is-the-trigger projection.
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Email Signature", pageId: pidSig, enabled: true),
            (name: "Mailing Address", pageId: pidAddr, enabled: true),
        ])
        let mgr = CommandsManager(fetcher: { _ in mdJSON("body") })
        let coord = CommandPaletteCoordinator(
            provider: RegistrySkillsCommandProvider(suiteName: suite, storageKey: BridgeDefaults.skills),
            manager: mgr)
        let ranked = await coord.search("Email Signature")
        try expect(ranked.first?.descriptor.id == pidSig && ranked.first?.score == 1000,
                   "an exact registry-name query is an exact-abbr match ⇒ #1 @ 1000, got \(ranked.first?.score ?? -1)")
        // And a strict name-PREFIX still resolves that entry (sanity that
        // the projection is genuinely searchable, not just exact-keyed).
        let pref = await coord.search("Email Sign")
        try expect(pref.first?.descriptor.id == pidSig,
                   "a registry-name prefix must still rank the entry first, got \(pref.first?.descriptor.name ?? "nil")")
    }

    await test("RegistryProvider maps EVERY enabled entry (no skill/command kind filter)") {
        // Slice decision: there is no skill-vs-command distinction — every
        // enabled registry entry is selectable, regardless of visibility.
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Routing-ish", pageId: pidSig, enabled: true),
            (name: "Standard-ish", pageId: pidAddr, enabled: true),
            (name: "Third", pageId: "cccc1111dddd2222eeee3333ffff4444", enabled: true),
        ])
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.count == 3,
                   "all three enabled entries are selectable commands, got \(got.count)")
    }

    await test("RegistryProvider default storageKey is the shared BridgeDefaults.skills") {
        // The provider must read the SAME key SkillsManager / manage_skill
        // write — proven by seeding that exact key and using the default
        // (un-overridden) storageKey on an isolated suite.
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Shared Key Skill", pageId: pidSig, enabled: true),
        ])
        let got = await RegistrySkillsCommandProvider(suiteName: suite).descriptors()
        try expect(got.count == 1 && got.first?.name == "Shared Key Skill",
                   "the provider's default key must be com.notionbridge.skills, got \(got.map { $0.name })")
        try expect(BridgeDefaults.skills == "com.notionbridge.skills",
                   "registry key identity guard")
    }

    await test("RegistryProvider preserves registry order (stable descriptor list)") {
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Zebra", pageId: pidSig, enabled: true),
            (name: "Apple", pageId: pidAddr, enabled: true),
        ])
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.map { $0.name } == ["Zebra", "Apple"],
                   "the provider must not re-order; ranking is CommandPaletteSearch's job, got \(got.map { $0.name })")
    }

    await test("RegistryProvider empty registry → palette opens, search safe (no crash)") {
        let (d, suite) = makeIsolatedDefaults()
        d.set(try JSONSerialization.data(withJSONObject: [[String: Any]]()), forKey: BridgeDefaults.skills)
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let coord = CommandPaletteCoordinator(
            provider: RegistrySkillsCommandProvider(suiteName: suite, storageKey: BridgeDefaults.skills),
            manager: mgr)
        let ranked = await coord.search("anything")
        try expect(ranked.isEmpty, "empty registry → no rows (and no crash), got \(ranked.count)")
        let commit = await coord.commit(query: "anything")
        guard case .notFound = commit else {
            throw TestError.assertion("empty registry commit must be .notFound, got \(commit)")
        }
    }

    // ============================================================
    // MARK: (H) Clipboard-only commit — CommandBoxController.applyCommit
    //   The on-Enter behaviour: .paste → WRITE the body to the clipboard
    //   (replace contents, NO save/restore); .notFound / .unavailable →
    //   write NOTHING. Driven through an InMemoryClipboard so the write
    //   is read back in-test (now headlessly verifiable). NO panel / NO
    //   hot-key constructed — only the pure commit decision.
    // ============================================================

    await test("applyCommit(.paste) WRITES the resolved body to the clipboard") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        await ctrl.applyCommit(.paste("=== resolved body ==="))
        try expect(cb.readString() == "=== resolved body ===",
                   "the clipboard must hold exactly the resolved body, got \(cb.readString() ?? "nil")")
        try expect(cb.writeCount == 1, "exactly one clipboard write, got \(cb.writeCount)")
    }

    await test("applyCommit(.paste) does NOT preserve the prior clipboard (replace-only)") {
        // The corrected invariant superseding the deleted save/restore:
        // the user WANTS the body on the clipboard; the original is gone.
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        await ctrl.applyCommit(.paste("new-body"))
        try expect(cb.readString() == "new-body",
                   "there is NO restore — prior clip must be overwritten, got \(cb.readString() ?? "nil")")
    }

    await test("applyCommit(.notFound) writes NOTHING (no guessed command on the clipboard)") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        await ctrl.applyCommit(.notFound(query: "zzz-no-such"))
        try expect(cb.writeCount == 0, "a not-found commit must NOT write, got writeCount=\(cb.writeCount)")
        try expect(cb.readString() == "user-prior-clip",
                   "the clipboard must be left untouched on no-match, got \(cb.readString() ?? "nil")")
    }

    await test("applyCommit(.unavailable) writes NOTHING (no destructive clobber)") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        await ctrl.applyCommit(.unavailable(name: "Some Skill", reason: "fetch failed"))
        try expect(cb.writeCount == 0, "an unavailable commit must NOT write, got \(cb.writeCount)")
        try expect(cb.readString() == "user-prior-clip", "clipboard untouched on unavailable")
    }

    await test("applyCommit(.paste) with an EMPTY body writes nothing (no blank clobber)") {
        let cb = InMemoryClipboard(initial: "user-prior-clip")
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        await ctrl.applyCommit(.paste(""))
        try expect(cb.writeCount == 0,
                   "an empty resolved body must NOT blank-clobber the clipboard, got \(cb.writeCount)")
        try expect(cb.readString() == "user-prior-clip", "clipboard untouched on empty body")
    }

    await test("applyCommit(.paste) preserves exact markdown bytes onto the clipboard") {
        let cb = InMemoryClipboard()
        let mgr = CommandsManager(fetcher: { _ in mdJSON("x") })
        let ctrl = await CommandBoxController(
            clipboard: cb,
            coordinator: CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(), manager: mgr))
        let body = "# H1\n\n- a — b\n[link](https://www.notion.so/p)\n✅ ünïçødé"
        await ctrl.applyCommit(.paste(body))
        try expect(cb.readString() == body,
                   "the resolved markdown must reach the clipboard byte-for-byte, got \(cb.readString() ?? "nil")")
    }

    await test("Coordinator(query) → applyCommit writes the W2-resolved body end-to-end") {
        // The full headless path: typed query → registry fuzzy match →
        // W2 body fetch+resolve → clipboard write (read back in-test).
        let (d, suite) = makeIsolatedDefaults()
        seedRegistry(d, key: BridgeDefaults.skills, [
            (name: "Email Signature", pageId: pidSig, enabled: true),
        ])
        nonisolated(unsafe) var fetched = ""
        let mgr = CommandsManager(fetcher: { id in
            fetched = id
            return mdJSON("RESOLVED SIGNATURE BODY")
        })
        let coord = CommandPaletteCoordinator(
            provider: RegistrySkillsCommandProvider(suiteName: suite, storageKey: BridgeDefaults.skills),
            manager: mgr)
        let cb = InMemoryClipboard()
        let ctrl = await CommandBoxController(clipboard: cb, coordinator: coord)
        let result = await coord.commit(query: "Email Signature")
        await ctrl.applyCommit(result)
        try expect(cb.readString() == "RESOLVED SIGNATURE BODY",
                   "the end-to-end path must land the W2-resolved body on the clipboard, got \(cb.readString() ?? "nil")")
        try expect(fetched.replacingOccurrences(of: "-", with: "") == pidSig,
                   "must fetch the matched registry entry's page id, got \(fetched)")
    }

    // ============================================================
    // MARK: (I) P2 — pure ↑/↓ selection state machine
    //   The results-list selection logic, extracted out of the AppKit
    //   panel. Exhaustively asserted: empty list, top-row preselect,
    //   clamp at both ends (no wrap), and re-clamp when results shrink.
    // ============================================================

    await test("Selection: empty list ⇒ nil (nothing selected)") {
        var s = CommandPaletteSelection(count: 0)
        try expect(s.selectedIndex == nil, "empty results must select nothing")
        s.move(.down); s.move(.up)
        try expect(s.selectedIndex == nil, "arrows on an empty list are a no-op")
    }

    await test("Selection: non-empty list preselects the top row (index 0)") {
        let s = CommandPaletteSelection(count: 5)
        try expect(s.selectedIndex == 0, "top row must be preselected, got \(String(describing: s.selectedIndex))")
    }

    await test("Selection: ↓ advances and CLAMPS at the bottom (no wrap)") {
        var s = CommandPaletteSelection(count: 3)
        s.move(.down); try expect(s.selectedIndex == 1)
        s.move(.down); try expect(s.selectedIndex == 2)
        s.move(.down); try expect(s.selectedIndex == 2, "↓ at the last row must clamp, not wrap")
    }

    await test("Selection: ↑ retreats and CLAMPS at the top (no wrap)") {
        var s = CommandPaletteSelection(count: 3)
        s.move(.down); s.move(.down)        // → index 2
        s.move(.up);  try expect(s.selectedIndex == 1)
        s.move(.up);  try expect(s.selectedIndex == 0)
        s.move(.up);  try expect(s.selectedIndex == 0, "↑ at the first row must clamp, not wrap")
    }

    await test("Selection: shrinking results re-clamps a stale index into range") {
        var s = CommandPaletteSelection(count: 5)
        s.move(.down); s.move(.down); s.move(.down)   // index 3
        s.updateResultCount(2)                        // list shrank to 2
        try expect(s.selectedIndex == 1,
                   "a stale index past the end must clamp to the new last row, got \(String(describing: s.selectedIndex))")
        s.updateResultCount(0)
        try expect(s.selectedIndex == nil, "results emptying must clear the selection")
        s.updateResultCount(4)
        try expect(s.selectedIndex == 0, "results re-appearing must preselect the top row")
    }

    await test("Selection: updateResultCount preserves an in-range index") {
        var s = CommandPaletteSelection(count: 5)
        s.move(.down); s.move(.down)                  // index 2
        s.updateResultCount(5)                        // same count
        try expect(s.selectedIndex == 2, "an in-range selection must survive a same-size refresh")
        s.updateResultCount(4)
        try expect(s.selectedIndex == 2, "still in range after a small shrink ⇒ unchanged")
    }

    await test("Selection: negative counts are treated as empty (defensive)") {
        var s = CommandPaletteSelection(count: -3)
        try expect(s.selectedIndex == nil, "a negative count must behave as empty")
        s.updateResultCount(-1)
        try expect(s.selectedIndex == nil && s.count == 0, "negative refresh clamps to empty")
    }

    await test("Selection: select(index:) seats directly + clamps both ends (mouse click, O(1))") {
        var s = CommandPaletteSelection(count: 5)
        s.select(index: 3)
        try expect(s.selectedIndex == 3, "a click on row 3 must select 3, got \(String(describing: s.selectedIndex))")
        s.select(index: 99)
        try expect(s.selectedIndex == 4, "an out-of-range click clamps to the last row, got \(String(describing: s.selectedIndex))")
        s.select(index: -7)
        try expect(s.selectedIndex == 0, "a negative click clamps to the first row, got \(String(describing: s.selectedIndex))")
        // Equivalence with the old O(n) step-down re-seat it replaces.
        var stepped = CommandPaletteSelection(count: 5)
        for _ in 0..<3 { stepped.move(.down) }
        var seated = CommandPaletteSelection(count: 5)
        seated.select(index: 3)
        try expect(stepped == seated, "select(index:) must equal the stepped re-seat it replaced")
    }

    await test("Selection: select(index:) on an empty list keeps nil") {
        var s = CommandPaletteSelection(count: 0)
        s.select(index: 2)
        try expect(s.selectedIndex == nil, "selecting into an empty list must stay nil")
    }

    // ============================================================
    // MARK: (J) P2 — pure commit → UI presentation mapping
    //   Each CommandPaletteCommitResult → the EXACT inline message +
    //   whether the panel stays open + whether it's an auto-dismiss
    //   confirmation. The AppKit label/timer is the operator-smoke
    //   ceiling; THIS decision is asserted exhaustively.
    // ============================================================

    await test("Presenter: .paste ⇒ \"Copied ‹name›\", panel DISMISSES (confirmation)") {
        let p = CommandPalettePresenter.present(.paste("body"), name: "Email Signature")
        try expect(p.message == "Copied Email Signature", "got '\(p.message)'")
        try expect(p.staysOpen == false, "a successful copy must dismiss the panel")
        try expect(p.isConfirmation, "a copy is a flash-then-dismiss confirmation")
    }

    await test("Presenter: .notFound ⇒ \"No match for ‹query›\", panel STAYS, no copy") {
        let p = CommandPalettePresenter.present(.notFound(query: "zzz"), name: "ignored")
        try expect(p.message == "No match for zzz", "got '\(p.message)'")
        try expect(p.staysOpen, "no-match must keep the panel open for a retry")
        try expect(!p.isConfirmation, "no-match is not a copy confirmation")
    }

    await test("Presenter: .unavailable ⇒ \"‹name› unavailable — offline?\", panel STAYS") {
        let p = CommandPalettePresenter.present(
            .unavailable(name: "Mailing Address", reason: "boom"), name: "ignored")
        try expect(p.message == "Mailing Address unavailable — offline?", "got '\(p.message)'")
        try expect(p.staysOpen, "unavailable must keep the panel open")
        try expect(!p.isConfirmation)
    }

    await test("Presenter: empty-query no-op ⇒ blank message, panel STAYS, no copy") {
        let p = CommandPalettePresenter.emptyQueryNoOp
        try expect(p.message.isEmpty, "an empty-query Enter shows nothing")
        try expect(p.staysOpen && !p.isConfirmation, "it is a pure no-op")
    }

    await test("Presenter: empty-registry message + dismiss delay constants") {
        try expect(CommandPalettePresenter.emptyRegistryMessage
                       == "No commands yet — add skills in Settings → Commands",
                   "got '\(CommandPalettePresenter.emptyRegistryMessage)'")
        try expect(CommandPalettePresenter.confirmationDismissMillis == 900,
                   "the confirmation auto-dismiss is ~900ms, got \(CommandPalettePresenter.confirmationDismissMillis)")
    }

    await test("CommandPalettePresentation / arrow / selection are Equatable value types") {
        try expect(CommandPaletteArrow.up != CommandPaletteArrow.down)
        try expect(CommandPaletteSelection(count: 3) == CommandPaletteSelection(count: 3))
        try expect(CommandPalettePresenter.present(.paste("a"), name: "n")
                       == CommandPalettePresenter.present(.paste("b"), name: "n"),
                   "presentation depends on name+case, not the body bytes")
    }

    // ============================================================
    // MARK: (K) P2 — pure Settings status row + multi-monitor math
    // ============================================================

    await test("CommandsSettingsStatus: enabled + registered ⇒ \"Active — ⌃B\"") {
        let st = CommandsSettingsStatus(enabled: true, isRegistered: true, hotkey: "⌃B")
        try expect(st == .active(hotkey: "⌃B"))
        try expect(st.message == "Active — ⌃B", "got '\(st.message)'")
        try expect(!st.isWarning, "the active state is not a warning")
    }

    await test("CommandsSettingsStatus: enabled + NOT registered ⇒ red shortcut-unavailable") {
        let st = CommandsSettingsStatus(enabled: true, isRegistered: false, hotkey: "⌃B")
        try expect(st == .shortcutUnavailable)
        try expect(st.message == "⚠ Shortcut unavailable (in use by another app)",
                   "got '\(st.message)'")
        try expect(st.isWarning, "an unavailable shortcut must render as a warning")
    }

    await test("CommandsSettingsStatus: disabled ⇒ \"Disabled\", no warning (regardless of registration)") {
        for reg in [true, false] {
            let st = CommandsSettingsStatus(enabled: false, isRegistered: reg, hotkey: "⌃B")
            try expect(st == .disabled, "off ⇒ .disabled even if isRegistered=\(reg)")
            try expect(st.message == "Disabled" && !st.isWarning)
        }
    }

    await test("placementOrigin centres horizontally + ~28% up the visible frame") {
        let frame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let size = CGSize(width: 560, height: 320)
        let o = CommandBoxController.placementOrigin(screenVisibleFrame: frame, panelSize: size)
        try expect(o.x == frame.midX - 280, "x must centre the panel, got \(o.x)")
        try expect(o.y == frame.minY + 800 * 0.28, "y must sit ~28% up, got \(o.y)")
    }

    await test("pickScreenFrame: prefers the screen containing the key window") {
        let s0 = CGRect(x: 0, y: 0, width: 1000, height: 800)        // main
        let s1 = CGRect(x: 1000, y: 0, width: 1000, height: 800)     // second
        let keyOnS1 = CGRect(x: 1400, y: 300, width: 200, height: 200)
        let hit = CommandBoxController.pickScreenFrame(
            screens: [s0, s1], keyWindowFrame: keyOnS1,
            mouseLocation: CGPoint(x: 10, y: 10), mainScreenFrame: s0)
        try expect(hit == s1, "the panel must open on the key window's screen, got \(String(describing: hit))")
    }

    await test("pickScreenFrame: falls back to the mouse's screen, then main") {
        let s0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let s1 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let mouseHit = CommandBoxController.pickScreenFrame(
            screens: [s0, s1], keyWindowFrame: nil,
            mouseLocation: CGPoint(x: 1500, y: 400), mainScreenFrame: s0)
        try expect(mouseHit == s1, "no key window ⇒ use the mouse's screen, got \(String(describing: mouseHit))")
        let mainHit = CommandBoxController.pickScreenFrame(
            screens: [s0, s1], keyWindowFrame: nil,
            mouseLocation: CGPoint(x: -50, y: -50), mainScreenFrame: s0)
        try expect(mainHit == s0, "off-screen mouse + no key window ⇒ main, got \(String(describing: mainHit))")
    }

    await test("AppDelegate.setCommandsPaletteEnabled persists the master toggle live") {
        // The live Settings entrypoint must write the persisted pref the
        // gate consults (no relaunch). We assert the PERSISTED side-effect
        // headlessly (the hot-key register/unregister itself is the
        // operator-smoke ceiling — a Carbon registration needs a live
        // WindowServer). Snapshot+restore the global key so this can
        // neither contaminate nor be contaminated by a sibling test.
        let key = BridgeDefaults.commandsPaletteEnabled
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let delegate = await AppDelegate()
        await delegate.setCommandsPaletteEnabled(false)
        try expect(UserDefaults.standard.bool(forKey: key) == false,
                   "disabling via Settings must persist false")
        try expect(!CommandsPaletteGate(environment: [:]).isEnabled,
                   "the gate must observe the persisted-off pref (no env override)")
        await delegate.setCommandsPaletteEnabled(true)
        try expect(UserDefaults.standard.bool(forKey: key) == true,
                   "re-enabling via Settings must persist true")
        try expect(CommandsPaletteGate(environment: [:]).isEnabled,
                   "the gate must observe the persisted-on pref")
    }
}
