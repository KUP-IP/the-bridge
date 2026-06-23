// CommandsDataTests.swift — cmd-w2 (Commands data layer)
// TheBridge · Tests
//
// Synthetic-fixture matrix for the Commands data layer. ZERO network /
// ZERO live Notion: every fetch is driven through CommandsManager's
// injectable BodyFetcher with recorded `/markdown` JSON strings, and
// every MentionResolver title-lookup is an injected closure.
//
// Coverage:
//   • CommandsManager: fetch+cache miss/hit, offline-fallback, manual
//     resync (single + all), forceResync, invalid page id, /markdown
//     JSON-envelope vs raw-markdown decode, full Command assembly.
//   • MentionResolver subtype matrix: page (resolved title), page
//     (unresolved → [link]), user, date, database, inline-link, unknown
//     subtype, multiple mentions in one body, mention adjacent to
//     markdown, one-lookup-per-distinct-url caching, never-drop /
//     never-throw invariants, empty input.

import Foundation
import TheBridgeLib

func runCommandsDataTests() async {
    print("\n\u{1F4DF} CommandsData Tests (cmd-w2 · data layer)")

    // ── synthetic /markdown JSON helpers ─────────────────────────────
    // (mdJSON is a file-scoped @Sendable free function — see bottom of
    // file — so it can be captured by the @Sendable BodyFetcher closures
    // under Swift 6 strict concurrency.)
    // A valid 32-hex page id (dashed form is what NotionPageRef yields).
    let pid = "11112222333344445555666677778888"
    let pidDashed = "11112222-3333-4444-5555-666677778888"

    // ============================================================
    // MARK: MentionResolver — subtype matrix
    // ============================================================

    await test("MentionResolver: page mention with resolved title → [Title](url)") {
        let body = #"See <mention-page url="https://www.notion.so/abc"/> now."#
        let out = await MentionResolver.resolve(markdown: body) { _ in "My Page" }
        try expect(out == "See [My Page](https://www.notion.so/abc) now.", "got: \(out)")
    }

    await test("MentionResolver: page mention with UNRESOLVED title → [link](url)") {
        let body = #"<mention-page url="https://www.notion.so/abc"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == "[link](https://www.notion.so/abc)", "got: \(out)")
    }

    await test("MentionResolver: page mention with empty/whitespace title → [link](url)") {
        let body = #"<mention-page url="https://www.notion.so/abc"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in "   " }
        try expect(out == "[link](https://www.notion.so/abc)", "got: \(out)")
    }

    await test("MentionResolver: user mention → [link](user://id)") {
        let body = #"hi <mention-user url="user://u-9"/>!"#
        let out = await MentionResolver.resolve(markdown: body) { _ in "ShouldNotBeUsed" }
        try expect(out == "hi [link](user://u-9)!", "got: \(out)")
    }

    await test("MentionResolver: date mention → [link](url) (modelled subtype)") {
        let body = #"due <mention-date url="date://2026-05-18"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == "due [link](date://2026-05-18)", "got: \(out)")
    }

    await test("MentionResolver: database mention → [link](url) (modelled subtype)") {
        let body = #"in <mention-database url="https://www.notion.so/db1"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == "in [link](https://www.notion.so/db1)", "got: \(out)")
    }

    await test("MentionResolver: inline-link mention → [link](url) (modelled subtype)") {
        let body = #"ref <mention-inline-link url="https://ex.com/x"/> end"#
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == "ref [link](https://ex.com/x) end", "got: \(out)")
    }

    await test("MentionResolver: unknown subtype with url → [link](url)") {
        let body = #"<mention-frobnicate url="weird://z"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == "[link](weird://z)", "got: \(out)")
    }

    await test("MentionResolver: unknown subtype WITHOUT url → verbatim pass-through (never drop)") {
        let body = "before <mention-mystery foo=\"bar\"/> after"
        let out = await MentionResolver.resolve(markdown: body) { _ in nil }
        try expect(out == body, "content must survive byte-for-byte; got: \(out)")
    }

    await test("MentionResolver: page mention WITHOUT url → verbatim pass-through (never drop)") {
        let body = #"x <mention-page id="noUrlHere"/> y"#
        let out = await MentionResolver.resolve(markdown: body) { _ in "T" }
        try expect(out == body, "got: \(out)")
    }

    await test("MentionResolver: multiple mixed mentions in one body") {
        let body = #"<mention-page url="https://www.notion.so/p1"/> + <mention-user url="user://u1"/> + <mention-date url="d://1"/>"#
        let out = await MentionResolver.resolve(markdown: body) { url in
            url == "https://www.notion.so/p1" ? "Page One" : nil
        }
        try expect(out == "[Page One](https://www.notion.so/p1) + [link](user://u1) + [link](d://1)", "got: \(out)")
    }

    await test("MentionResolver: mention immediately adjacent to markdown") {
        let body = #"**bold**<mention-page url="https://www.notion.so/p"/>`code`"#
        let out = await MentionResolver.resolve(markdown: body) { _ in "P" }
        try expect(out == "**bold**[P](https://www.notion.so/p)`code`", "got: \(out)")
    }

    await test("MentionResolver: one title lookup per DISTINCT url (caching rule)") {
        let body = #"<mention-page url="https://www.notion.so/same"/> <mention-page url="https://www.notion.so/same"/> <mention-page url="https://www.notion.so/other"/>"#
        let counter = LookupCounter()
        let out = await MentionResolver.resolve(markdown: body) { url in
            await counter.bump(url)
            return url.hasSuffix("same") ? "S" : "O"
        }
        let distinct = await counter.distinctCount()
        try expect(distinct == 2, "expected 2 distinct lookups, got \(distinct)")
        try expect(out == "[S](https://www.notion.so/same) [S](https://www.notion.so/same) [O](https://www.notion.so/other)", "got: \(out)")
    }

    await test("MentionResolver: no mentions → input returned unchanged") {
        let body = "plain markdown **with** no mentions and a < bracket"
        let out = await MentionResolver.resolve(markdown: body) { _ in "x" }
        try expect(out == body, "got: \(out)")
    }

    await test("MentionResolver: empty string → empty (never throws)") {
        let out = await MentionResolver.resolve(markdown: "") { _ in nil }
        try expect(out == "", "got: \(out)")
    }

    await test("MentionResolver: title with ] and newline is sanitized, content kept") {
        let body = #"<mention-page url="u://1"/>"#
        let out = await MentionResolver.resolve(markdown: body) { _ in "Ti]tle\nbreak" }
        try expect(out == #"[Ti\]tle break](u://1)"#, "got: \(out)")
    }

    await test("MentionResolver.scan classifies the full subtype matrix") {
        let body = #"<mention-page url="a"/><mention-user url="b"/><mention-date url="c"/><mention-database url="d"/><mention-inline-link url="e"/><mention-zzz url="f"/>"#
        let kinds = MentionResolver.scan(body).map(\.kind)
        try expect(kinds == [.page, .user, .date, .database, .link, .unknown], "got: \(kinds)")
    }

    // ============================================================
    // MARK: CommandsManager — fetch / cache / fallback / resync
    // ============================================================

    await test("CommandsManager: cache MISS fetches via injected fetcher + resolves mentions") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(
            titleLookup: { _ in "Linked" },
            fetcher: { _ in
                await fetchCalls.bump()
                return mdJSON(#"body <mention-page url="https://www.notion.so/q"/>"#)
            }
        )
        let out = try await mgr.body(forPageId: pid)
        let n = await fetchCalls.value()
        try expect(n == 1, "expected 1 fetch, got \(n)")
        try expect(out == "body [Linked](https://www.notion.so/q)", "got: \(out)")
    }

    await test("CommandsManager: cache HIT does not re-fetch (TTL fresh)") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(fetcher: { _ in
            await fetchCalls.bump()
            return mdJSON("hello")
        })
        _ = try await mgr.body(forPageId: pid)
        _ = try await mgr.body(forPageId: pid)
        let n = await fetchCalls.value()
        try expect(n == 1, "expected exactly 1 fetch (2nd served from cache), got \(n)")
    }

    await test("CommandsManager: offline-fallback serves last good body when refresh fails") {
        let mode = FetchMode()
        let mgr = CommandsManager(fetcher: { _ in
            if await mode.shouldFail() { throw TestFetchError.boom }
            return mdJSON("GOOD-V1")
        })
        let first = try await mgr.body(forPageId: pid)
        try expect(first == "GOOD-V1", "got: \(first)")
        await mode.startFailing()
        // forceResync → live fetch attempted; it fails; fallback to cache.
        let fallback = try await mgr.body(forPageId: pid, forceResync: true)
        try expect(fallback == "GOOD-V1", "offline-fallback must serve last good; got: \(fallback)")
    }

    await test("CommandsManager: fetch fails with NO prior cache → .unavailable") {
        let mgr = CommandsManager(fetcher: { _ in throw TestFetchError.boom })
        do {
            _ = try await mgr.body(forPageId: pid)
            throw TestError.assertion("expected throw")
        } catch let e as CommandsFetchError {
            guard case .unavailable = e else {
                throw TestError.assertion("expected .unavailable, got \(e)")
            }
        }
    }

    await test("CommandsManager: invalid page id → .invalidPageId (no fetch attempted)") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(fetcher: { _ in
            await fetchCalls.bump(); return "x"
        })
        do {
            _ = try await mgr.body(forPageId: "not-a-valid-id")
            throw TestError.assertion("expected throw")
        } catch let e as CommandsFetchError {
            guard case .invalidPageId = e else {
                throw TestError.assertion("expected .invalidPageId, got \(e)")
            }
        }
        let n = await fetchCalls.value()
        try expect(n == 0, "fetcher must not be called for an invalid id; got \(n)")
    }

    await test("CommandsManager: manual resync(pageId:) forces a live re-fetch") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(fetcher: { _ in
            await fetchCalls.bump(); return mdJSON("v\(await fetchCalls.value())")
        })
        _ = try await mgr.body(forPageId: pid)            // fetch 1
        _ = try await mgr.body(forPageId: pid)            // cache hit
        await mgr.resync(pageId: pidDashed)               // drop entry
        _ = try await mgr.body(forPageId: pid)            // fetch 2
        let n = await fetchCalls.value()
        try expect(n == 2, "expected 2 fetches across resync, got \(n)")
    }

    await test("CommandsManager: resyncAll() drops every cached body") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(fetcher: { _ in
            await fetchCalls.bump(); return mdJSON("x")
        })
        _ = try await mgr.body(forPageId: pid)
        await mgr.resyncAll()
        _ = try await mgr.body(forPageId: pid)
        let n = await fetchCalls.value()
        try expect(n == 2, "expected 2 fetches after resyncAll, got \(n)")
    }

    await test("CommandsManager: forceResync=true bypasses fresh cache") {
        let fetchCalls = CallCounter()
        let mgr = CommandsManager(fetcher: { _ in
            await fetchCalls.bump(); return mdJSON("x")
        })
        _ = try await mgr.body(forPageId: pid)
        _ = try await mgr.body(forPageId: pid, forceResync: true)
        let n = await fetchCalls.value()
        try expect(n == 2, "forceResync must bypass cache; got \(n)")
    }

    await test("CommandsManager: accepts raw markdown (non-JSON) from fetcher") {
        let mgr = CommandsManager(
            titleLookup: { _ in "T" },
            fetcher: { _ in #"raw md <mention-page url="https://www.notion.so/z"/>"# }
        )
        let out = try await mgr.body(forPageId: pid)
        try expect(out == "raw md [T](https://www.notion.so/z)", "got: \(out)")
    }

    await test("CommandsManager: decodes /markdown JSON envelope correctly") {
        let mgr = CommandsManager(fetcher: { _ in mdJSON("ENVELOPE-OK") })
        let out = try await mgr.body(forPageId: pid)
        try expect(out == "ENVELOPE-OK", "got: \(out)")
    }

    await test("CommandsManager.markdownString decodes JSON + raw fallback") {
        try expect(CommandsManager.markdownString(fromMarkdownJSON: mdJSON("A")) == "A")
        try expect(CommandsManager.markdownString(fromMarkdownJSON: "not json at all") == "not json at all")
    }

    await test("CommandsManager.command assembles a full Command (id normalized, body resolved)") {
        let mgr = CommandsManager(
            titleLookup: { _ in nil },
            fetcher: { _ in mdJSON(#"<mention-page url="https://www.notion.so/p"/> tail"#) }
        )
        let cmd = try await mgr.command(
            pageId: pid, name: "Greet", abbreviation: "gm",
            group: "Daily", tags: ["a", "b"], source: "synthetic"
        )
        try expect(cmd.id == pidDashed, "id should be normalized dashed; got \(cmd.id)")
        try expect(cmd.name == "Greet" && cmd.abbreviation == "gm" && cmd.group == "Daily")
        try expect(cmd.tags == ["a", "b"] && cmd.source == "synthetic")
        try expect(cmd.text == "[link](https://www.notion.so/p) tail", "got: \(cmd.text)")
    }

    await test("CommandCache: TTL-expired entry is a miss for get() but lastKnown() still serves") {
        let cache = CommandCache()
        let old = Date().addingTimeInterval(-CommandCache.ttlSeconds - 5)
        await cache.set("k", body: "STALE", now: old)
        let fresh = await cache.get("k")           // expired → nil
        let stale = await cache.lastKnown("k")     // still there
        try expect(fresh == nil, "expired get() must miss; got \(String(describing: fresh))")
        try expect(stale == "STALE", "lastKnown must serve expired; got \(String(describing: stale))")
    }

    await test("Command model is Codable round-trip stable") {
        let c = Command(id: pidDashed, name: "N", abbreviation: "ab", group: "G",
                         text: "body", tags: ["t"], source: "synthetic")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Command.self, from: data)
        try expect(back == c, "round-trip mismatch")
    }
}

// MARK: - Test support actors / errors (file-scoped)

private actor CallCounter {
    private var n = 0
    func bump() { n += 1 }
    func value() -> Int { n }
}

private actor LookupCounter {
    private var urls: [String] = []
    func bump(_ u: String) { urls.append(u) }
    func distinctCount() -> Int { Set(urls).count }
}

private actor FetchMode {
    private var failing = false
    func startFailing() { failing = true }
    func shouldFail() -> Bool { failing }
}

private enum TestFetchError: Error { case boom }

/// Synthetic `/markdown` JSON envelope builder. File-scoped + @Sendable so
/// it can be captured inside the @Sendable BodyFetcher closures.
@Sendable private func mdJSON(_ markdown: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["markdown": markdown])
    return String(data: data, encoding: .utf8)!
}
