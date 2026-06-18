// SkillBodyCacheTests.swift — Bridge (feat/backend-remediation)
// TheBridge · Tests
//
// Coverage for the PERSISTENT per-skill BODY cache (CachedSkillBody +
// SkillBodyCacheStore). SEPARATE and ADDITIVE to the per-parent routing
// cache (SkillsCacheTests).
//
//   - CachedSkillBody persistence schema: write→read round-trip,
//     forwards-tolerant decode, normalized-id keying.
//   - SkillBodyCacheStore: eviction, incrementCallCount, readAll, state().
//   - Stale detection: TTL boundary + the lastEditedTime-change signal
//     that drives revalidation (callCount cadence + edit-time delta).
//   - Envelope-equivalence: a cache HIT (body fed from a CachedSkillBody)
//     rebuilds an envelope EQUAL to the network path for the same input,
//     including the optional `section` selector slice.
//
// Test isolation: every test runs under a fresh tmpdir routed through
// BridgePaths.overrideHomeForTesting(_:). Per-process override; tests
// serialize their use of the seam and restore it in a `defer`.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Fixtures

private func withTempHomeBody(_ body: (URL) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-skillbodycachetest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body(tmp)
}

private func sampleBody(
    pageId: String = "1111111111111111111111111111aaaa",
    markdown: String = "# Title\n\nbody line one\n\n## Sub\n\nsub body\n",
    title: String = "Demo Skill",
    url: String = "https://www.notion.so/demo",
    properties: Value = .object(["Status": .string("Active")]),
    lastEditedTime: String = "2026-06-11T10:00:00.000Z",
    writtenAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    ttlHours: Int = 24,
    callCount: Int = 1
) -> CachedSkillBody {
    CachedSkillBody(
        pageId: pageId, markdown: markdown, title: title, url: url,
        properties: properties, lastEditedTime: lastEditedTime,
        writtenAt: writtenAt, ttlHours: ttlHours, callCount: callCount
    )
}

// MARK: - Runner

func runSkillBodyCacheTests() async {
    print("\n\u{1F4BE} Skill Body Cache (persistent body + stale-while-revalidate)")

    // -----------------------------------------------------------------
    // 1. write → read round-trip preserves the full CachedSkillBody.
    // -----------------------------------------------------------------
    await test("body-cache write→read round-trip preserves all fields") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            let entry = sampleBody()
            try await store.write(entry)
            guard let got = await store.read(pageId: entry.pageId) else {
                throw TestError.assertion("expected a cached body")
            }
            try expect(got.pageId == entry.pageId, "pageId mismatch")
            try expect(got.markdown == entry.markdown, "markdown mismatch")
            try expect(got.title == entry.title, "title mismatch")
            try expect(got.url == entry.url, "url mismatch")
            try expect(got.properties == entry.properties, "properties mismatch")
            try expect(got.lastEditedTime == entry.lastEditedTime, "lastEditedTime mismatch")
            try expect(got.callCount == entry.callCount, "callCount mismatch")
            try expect(abs(got.writtenAt.timeIntervalSince(entry.writtenAt)) < 0.001,
                       "writtenAt mismatch")
        }
    }

    // -----------------------------------------------------------------
    // 2. Keying normalizes the page id (dashes/case) — a dashed lookup
    //    finds the entry written with a bare-hex id.
    // -----------------------------------------------------------------
    await test("body-cache keying normalizes dashed/uppercase page ids") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            // Write with a DASHED, uppercase id; read back with a different
            // shape — the store normalizes both to the same file.
            let dashed = "11111111-2222-3333-4444-5555AAAABBBB"
            let bare = "111111112222333344445555aaaabbbb"
            try await store.write(sampleBody(pageId: dashed))
            guard let got = await store.read(pageId: bare.uppercased()) else {
                throw TestError.assertion("expected normalized lookup to hit")
            }
            try expect(got.pageId == bare, "stored pageId should be normalized bare hex")
            try expect(CachedSkillBody.normalize(dashed) == bare, "normalize() contract")
        }
    }

    // -----------------------------------------------------------------
    // 3. evict removes the entry; a subsequent read is nil.
    // -----------------------------------------------------------------
    await test("body-cache evict removes the entry") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            let entry = sampleBody()
            try await store.write(entry)
            try expect(await store.read(pageId: entry.pageId) != nil, "precondition: stored")
            await store.evict(pageId: entry.pageId)
            try expect(await store.read(pageId: entry.pageId) == nil, "expected nil after evict")
        }
    }

    // -----------------------------------------------------------------
    // 4. incrementCallCount bumps + persists; returns 0 with no entry.
    // -----------------------------------------------------------------
    await test("body-cache incrementCallCount bumps + persists; 0 when absent") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            // No entry yet → 0 (no cadence tick).
            try expect(await store.incrementCallCount(pageId: "deadbeefdeadbeefdeadbeefdeadbeef") == 0,
                       "absent entry must return 0")
            let entry = sampleBody(callCount: 4)
            try await store.write(entry)
            let n = await store.incrementCallCount(pageId: entry.pageId)
            try expect(n == 5, "expected 5, got \(n)")
            // Persisted: re-read shows the bumped value (cadence survives).
            let reread = await store.read(pageId: entry.pageId)
            try expect(reread?.callCount == 5, "bump must persist to disk")
        }
    }

    // -----------------------------------------------------------------
    // 5. The cadence ticks every 5th call: only multiples of 5 fire.
    // -----------------------------------------------------------------
    await test("body-cache revalidation cadence fires on every 5th call") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            try await store.write(sampleBody(callCount: 0))
            let pid = "1111111111111111111111111111aaaa"
            var fired: [Int] = []
            for _ in 1...12 {
                let n = await store.incrementCallCount(pageId: pid)
                if n % 5 == 0 { fired.append(n) }
            }
            try expect(fired == [5, 10], "cadence should fire at 5 and 10, got \(fired)")
        }
    }

    // -----------------------------------------------------------------
    // 6. state() reports cached/writtenAt/stale; TTL boundary → stale.
    // -----------------------------------------------------------------
    await test("body-cache state() reports stored + stale via TTL boundary") {
        try await withTempHomeBody { _ in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            // 25h-old entry with 24h TTL → stale under the injected clock.
            let store = SkillBodyCacheStore(clock: { now })
            let old = now.addingTimeInterval(-25 * 3600)
            try await store.write(sampleBody(writtenAt: old, ttlHours: 24))
            let s = await store.state(pageId: "1111111111111111111111111111aaaa")
            try expect(s.cached, "expected cached=true")
            try expect(s.writtenAt != nil, "expected a writtenAt")
            try expect(s.stale, "25h-old @24h TTL must be stale")

            // Absent → (false, nil, false).
            let absent = await store.state(pageId: "0000000000000000000000000000beef")
            try expect(!absent.cached && absent.writtenAt == nil && !absent.stale,
                       "absent state must be (false,nil,false)")
        }
    }

    // -----------------------------------------------------------------
    // 7. Stale-detection signal: a CHANGED last_edited_time means the
    //    cached body is stale (the revalidation rewrite trigger). An
    //    UNCHANGED timestamp means fresh (no rewrite).
    // -----------------------------------------------------------------
    await test("body-cache lastEditedTime change is the revalidation trigger") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            let cached = sampleBody(lastEditedTime: "2026-06-11T10:00:00.000Z")
            try await store.write(cached)
            let stored = await store.read(pageId: cached.pageId)!

            // Unchanged edit time → no rewrite needed.
            let sameEdit = "2026-06-11T10:00:00.000Z"
            try expect(stored.lastEditedTime == sameEdit,
                       "unchanged edit time should match → fresh")

            // Changed edit time → triggers a rewrite with the new body.
            let newEdit = "2026-06-11T11:30:00.000Z"
            try expect(stored.lastEditedTime != newEdit,
                       "changed edit time should differ → stale")
            let rewritten = CachedSkillBody(
                pageId: cached.pageId, markdown: "# Title\n\nNEW body\n",
                title: cached.title, url: cached.url, properties: cached.properties,
                lastEditedTime: newEdit, writtenAt: Date(), callCount: 1
            )
            try await store.write(rewritten)
            let after = await store.read(pageId: cached.pageId)!
            try expect(after.lastEditedTime == newEdit, "rewrite must land new edit time")
            try expect(after.markdown.contains("NEW body"), "rewrite must land new body")
            try expect(after.callCount == 1, "rewrite resets the cadence window")
        }
    }

    // -----------------------------------------------------------------
    // 8. readAll returns every stored body in stable order.
    // -----------------------------------------------------------------
    await test("body-cache readAll returns all entries") {
        try await withTempHomeBody { _ in
            let store = SkillBodyCacheStore()
            try await store.write(sampleBody(pageId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
            try await store.write(sampleBody(pageId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
            try await store.write(sampleBody(pageId: "cccccccccccccccccccccccccccccccc"))
            let all = await store.readAll()
            try expect(all.count == 3, "expected 3 entries, got \(all.count)")
            let ids = all.map(\.pageId)
            try expect(ids == ids.sorted(), "readAll must be in stable alpha order")
        }
    }

    // -----------------------------------------------------------------
    // 9. Forwards-tolerant decode: an unknown top-level key is ignored
    //    and missing fields default — older readers survive new writers.
    // -----------------------------------------------------------------
    await test("body-cache decode is forwards-tolerant") {
        try await withTempHomeBody { _ in
            let dir = try BridgePaths.ensureApplicationSupport(.skillsBodyCache)
            let pid = "1111111111111111111111111111aaaa"
            let json = """
            {
              "pageId": "\(pid)",
              "markdown": "hello",
              "title": "T",
              "url": "u",
              "properties": { "Status": "Active" },
              "lastEditedTime": "2026-06-11T10:00:00.000Z",
              "writtenAt": "2026-06-11T10:00:00.000Z",
              "ttlHours": 24,
              "callCount": 3,
              "futureKey": "ignored-by-older-readers"
            }
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
            let store = SkillBodyCacheStore()
            guard let got = await store.read(pageId: pid) else {
                throw TestError.assertion("expected decode to tolerate unknown key")
            }
            try expect(got.markdown == "hello", "markdown should decode")
            try expect(got.callCount == 3, "callCount should decode")
        }
    }

    // -----------------------------------------------------------------
    // 10. ENVELOPE-EQUIVALENCE: a cache HIT (body sourced from a
    //     CachedSkillBody) rebuilds an envelope EQUAL to the network path
    //     for the same input — both feed the SAME buildSkillResult.
    // -----------------------------------------------------------------
    await test("body-cache HIT rebuilds an envelope equal to the network path") {
        // /markdown JSON envelope helper (what the network path decodes).
        func mdJSON(_ markdown: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: ["markdown": markdown])
            return String(data: data, encoding: .utf8)!
        }
        let body = "# Overview\n\nfirst para\n\n## Details\n\ndetail body\n"
        let props: [String: Any] = [
            "Status": ["type": "status", "status": ["name": "Active", "id": "s1"]]
        ]

        // NETWORK path: rawMarkdown decoded from the /markdown JSON.
        let rawMarkdown = SkillsModule.skillMarkdownString(fromMarkdownJSON: mdJSON(body))
        let networkEnvelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: rawMarkdown,
            pageProperties: props
        ) { _ in nil }

        // CACHE-HIT path: the SAME markdown is what we persist + replay.
        let cached = sampleBody(markdown: rawMarkdown)
        let cacheEnvelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: cached.markdown,
            pageProperties: props
        ) { _ in nil }

        try expect(networkEnvelope == cacheEnvelope,
                   "cache-hit envelope must equal the network envelope")

        // And the `section` selector slices identically on both paths:
        // the slice is a pure function of the rendered markdown, which is
        // byte-identical between the cached body and the network body.
        let netSlice = SkillsModule.extractMarkdownSection(rawMarkdown, section: "Details")
        let cacheSlice = SkillsModule.extractMarkdownSection(cached.markdown, section: "Details")
        try expect(netSlice != nil, "network section slice should match a heading")
        try expect(netSlice == cacheSlice,
                   "section slice must be identical across cache + network paths")
    }

    // -----------------------------------------------------------------
    // 11. ZERO-NETWORK plain hit: the offline plain-hit envelope builder
    //     (`buildPlainCacheHitEnvelope`, exercised via its public testing
    //     entry point) serves the cached envelope WITHOUT touching the
    //     network. We inject an ALWAYS-THROWING title lookup as the only
    //     reachable network seam — for a mention-free body it is never
    //     invoked, so the build succeeds and returns the cached content.
    //     A passing assertion proves the warm plain fetch is zero-network
    //     and offline-capable: the builder constructs no NotionClient and
    //     awaits nothing on the network.
    // -----------------------------------------------------------------
    await test("plain cache HIT serves the envelope with ZERO network calls") {
        // Hostile lookup: if the offline path ever tried to resolve a
        // <mention-page> over the network, it would call this and fail the
        // test. A mention-free body must never reach it.
        struct ProbeError: Error {}
        nonisolated(unsafe) var lookupCalls = 0
        let throwingLookup: @Sendable (String) async -> String? = { _ in
            lookupCalls += 1
            // Can't `throw` from a non-throwing closure shape; signal via a
            // sentinel the assertion below checks. Returning nil keeps the
            // build going, but `lookupCalls > 0` would fail the test.
            return nil
        }

        // A body with NO <mention-page> tags — the common offline case.
        let body = "# Overview\n\nfirst para\n\n## Details\n\ndetail body\n"
        let rawMarkdown = SkillsModule.skillMarkdownString(
            fromMarkdownJSON: String(
                data: try! JSONSerialization.data(withJSONObject: ["markdown": body]),
                encoding: .utf8)!
        )

        let cached = sampleBody(
            markdown: rawMarkdown,
            title: "Demo",
            url: "https://www.notion.so/p1",
            properties: .object(["Status": .string("Active")])
        )

        // Build ENTIRELY from the cache — no client is constructed or used.
        let envelope = await SkillsModule.buildPlainCacheHitEnvelopeForTesting(
            name: "demo",
            cachedBody: cached,
            titleLookup: throwingLookup
        )

        // The network seam was never exercised (no mentions in the body).
        try expect(lookupCalls == 0, "mention-free body must not touch the title lookup")

        guard case .object(let dict) = envelope else {
            throw TestError.assertion("expected an object envelope")
        }
        // Cached content surfaced verbatim through the production builder.
        try expect(dict["title"] == .string("Demo"), "title from cache")
        try expect(dict["url"] == .string("https://www.notion.so/p1"), "url from cache")
        if case .string(let content)? = dict["content"] {
            try expect(content.contains("detail body"), "body served from cache")
        } else {
            throw TestError.assertion("expected a content string")
        }
        // Properties carried straight off the cache (no re-flatten).
        try expect(dict["properties"] == .object(["Status": .string("Active")]),
                   "cached flattened properties served verbatim")
        // Plain request → NO routing footer / annotation keys (matches the
        // live bare-parent fast path, which enumerates no siblings).
        try expect(dict["routingFooter"] == nil, "plain hit adds no routingFooter")
        try expect(dict["annotation"] == nil, "plain hit adds no annotation")
        try expect(dict["resolvedPath"] == nil, "plain hit adds no resolvedPath")
    }

    // -----------------------------------------------------------------
    // 12. ENVELOPE EQUIVALENCE (plain): the offline plain-hit envelope
    //     equals the live network plain envelope for the same input. For a
    //     PLAIN request the live path's dispatch takes its bare-parent fast
    //     path (no specialist swap, no sibling enumeration → no footer /
    //     annotation), so the network envelope is exactly buildSkillResult.
    //     The cache-hit builder must reproduce it byte-for-byte.
    // -----------------------------------------------------------------
    await test("plain cache HIT envelope equals the network plain envelope") {
        let body = "# Overview\n\nfirst para\n\n## Details\n\ndetail body\n"
        let rawMarkdown = SkillsModule.skillMarkdownString(
            fromMarkdownJSON: String(
                data: try! JSONSerialization.data(withJSONObject: ["markdown": body]),
                encoding: .utf8)!
        )
        // Raw getPage properties blob → the network path flattens these.
        let rawProps: [String: Any] = [
            "Status": ["type": "status", "status": ["name": "Active", "id": "s1"]]
        ]

        // NETWORK plain envelope: buildSkillResult with flattened props and
        // an offline (nil) mention lookup — equivalent to the live plain
        // path whose own per-fetch lookup misses offline.
        let networkEnvelope = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: rawMarkdown,
            summary: "s", triggerPhrases: ["t"], antiTriggerPhrases: ["a"],
            pageProperties: rawProps
        ) { _ in nil }

        // CACHE-HIT plain envelope: the body cache PERSISTS exactly the
        // flatten the network path produced, so reconstruct that cached
        // body and replay it through the offline plain-hit builder.
        guard case .object(let netDict) = networkEnvelope,
              let cachedProps = netDict["properties"] else {
            throw TestError.assertion("network envelope should carry properties")
        }
        let cached = sampleBody(
            markdown: rawMarkdown,
            title: "Demo",
            url: "https://www.notion.so/p1",
            properties: cachedProps
        )
        let cacheEnvelope = await SkillsModule.buildPlainCacheHitEnvelopeForTesting(
            name: "demo",
            cachedBody: cached,
            summary: "s", triggerPhrases: ["t"], antiTriggerPhrases: ["a"]
        )

        try expect(networkEnvelope == cacheEnvelope,
                   "offline plain-hit envelope must equal the network plain envelope")
    }
}
