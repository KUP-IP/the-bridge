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

    await test("Gate: unset environment is DISABLED (default-OFF)") {
        try expect(!CommandsPaletteGate(environment: [:]).isEnabled,
                   "an unset BRIDGE_ENABLE_COMMANDS must keep the palette OFF")
    }

    await test("Gate: exactly \"1\" enables the palette") {
        try expect(CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": "1"]).isEnabled,
                   "literal \"1\" must enable the palette")
    }

    await test("Gate: any non-\"1\" value stays DISABLED (fail-closed)") {
        for v in ["0", "true", "TRUE", "yes", "on", " 1", "1 ", "", "enable"] {
            try expect(!CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": v]).isEnabled,
                       "value \"\(v)\" must NOT enable the palette (fail-closed)")
        }
    }

    await test("Gate: env key is the BRIDGE_ENABLE_* family name") {
        try expect(CommandsPaletteGate.enableEnvKey == "BRIDGE_ENABLE_COMMANDS",
                   "gate env key must be BRIDGE_ENABLE_COMMANDS")
    }

    await test("Gate is Equatable / value-typed (deterministic under test)") {
        try expect(CommandsPaletteGate(environment: [:]) == CommandsPaletteGate(environment: ["X": "y"]),
                   "two disabled gates compare equal")
        try expect(CommandsPaletteGate(environment: ["BRIDGE_ENABLE_COMMANDS": "1"])
                       != CommandsPaletteGate(environment: [:]),
                   "enabled vs disabled must differ")
    }

    // ============================================================
    // MARK: (E) AppDelegate gating decision — no NSApp launch
    //   Same proof shape as the streamableHTTP connector-gating test:
    //   a PURE static decision, both arms, with NO GUI side effects.
    // ============================================================

    await test("AppDelegate.shouldStartCommandsPalette: OFF when env unset") {
        try expect(!AppDelegate.shouldStartCommandsPalette(environment: [:]),
                   "default (unset) env must NOT start the palette — app byte-for-byte unchanged")
    }

    await test("AppDelegate.shouldStartCommandsPalette: ON only with =1") {
        try expect(AppDelegate.shouldStartCommandsPalette(environment: ["BRIDGE_ENABLE_COMMANDS": "1"]),
                   "BRIDGE_ENABLE_COMMANDS=1 must start the palette")
        try expect(!AppDelegate.shouldStartCommandsPalette(environment: ["BRIDGE_ENABLE_COMMANDS": "true"]),
                   "\"true\" must NOT start the palette (fail-closed, mirrors HTTP gate)")
    }

    await test("AppDelegate gating decision matches CommandsPaletteGate exactly") {
        for env in [[:], ["BRIDGE_ENABLE_COMMANDS": "1"], ["BRIDGE_ENABLE_COMMANDS": "0"]] {
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
}
