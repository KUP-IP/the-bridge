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
import NotionBridgeLib

// Synthetic /markdown JSON envelope helper (file-scoped @Sendable so it
// can be captured by the @Sendable BodyFetcher closures under Swift 6).
@Sendable private func mdJSON(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["markdown": s])
    return String(data: data, encoding: .utf8)!
}

private enum PaletteTestError: Error { case boom }

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
}
