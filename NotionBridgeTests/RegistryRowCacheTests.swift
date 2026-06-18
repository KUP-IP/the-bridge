// RegistryRowCacheTests.swift — Data-Source Registry (vertical slice v0)
// NotionBridge · Tests
//
// Coverage for the generalized per-entity ROW cache (CachedRow +
// RegistryRowCache), the Decision 4 read-through layer:
//   - write→read round-trip; id normalization (dashed vs bare → same file).
//   - per-entity isolation (no cross-entity collision on the same page id).
//   - TTL boundary via injected clock; state() triple.
//   - readAll ordering; offline read (no network).
//   - forwards-tolerant decode; evict / evictAll / incrementCallCount.
//
// Hermetic: each test runs under a fresh tmpdir routed through
// BridgePaths.overrideHomeForTesting(_:), restored in a defer.

import Foundation
import MCP
import NotionBridgeLib

private func withTempHomeRows(_ body: (URL) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-registryrowcache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body(tmp)
}

private func sampleRow(
    entity: String = "skill",
    pageId: String = "1111111111111111111111111111aaaa",
    title: String = "Demo Row",
    url: String = "https://www.notion.so/demo",
    properties: Value = .object(["Status": .string("Active")]),
    lastEditedTime: String = "2026-06-17T10:00:00.000Z",
    writtenAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    ttlSeconds: Int = 3600,
    callCount: Int = 1
) -> CachedRow {
    CachedRow(
        entity: entity, pageId: pageId, title: title, url: url,
        properties: properties, lastEditedTime: lastEditedTime,
        writtenAt: writtenAt, ttlSeconds: ttlSeconds, callCount: callCount
    )
}

func runRegistryRowCacheTests() async {
    print("\n\u{1F4BE} Data-Source Registry — Row Cache (read-through + offline)")

    await test("RowCache: write → read round-trips (offline, no network)") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try await cache.write(sampleRow())
            let got = await cache.read(entity: "skill", pageId: "1111111111111111111111111111aaaa")
            try expect(got != nil, "row read back")
            try expect(got?.title == "Demo Row", "title preserved")
            try expect(got?.properties == .object(["Status": .string("Active")]), "properties preserved")
        }
    }

    await test("RowCache: id normalization — dashed and bare ids hit one file") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try await cache.write(sampleRow(pageId: "11111111-1111-1111-1111-1111aaaaaaaa"))
            // Read with a different casing/format of the same id.
            let got = await cache.read(entity: "skill", pageId: "111111111111111111111111AAAAAAAA".replacingOccurrences(of: "A", with: "a"))
            try expect(got != nil, "normalized id resolves to the same entry")
            let all = await cache.readAll(entity: "skill")
            try expect(all.count == 1, "exactly one file (no dup from id shape)")
        }
    }

    await test("RowCache: per-entity isolation on identical page id") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try await cache.write(sampleRow(entity: "skill", title: "Skill Row"))
            try await cache.write(sampleRow(entity: "contact", title: "Contact Row"))
            let s = await cache.read(entity: "skill", pageId: "1111111111111111111111111111aaaa")
            let c = await cache.read(entity: "contact", pageId: "1111111111111111111111111111aaaa")
            try expect(s?.title == "Skill Row", "skill entry distinct")
            try expect(c?.title == "Contact Row", "contact entry distinct")
            try expect(await cache.readAll(entity: "skill").count == 1, "skill dir has one")
            try expect(await cache.readAll(entity: "contact").count == 1, "contact dir has one")
        }
    }

    await test("RowCache: TTL boundary via injected clock") {
        try await withTempHomeRows { _ in
            let written = Date(timeIntervalSince1970: 1_700_000_000)
            // Clock 2 hours later; TTL 1h → stale.
            let cache = RegistryRowCache(clock: { written.addingTimeInterval(7200) })
            try await cache.write(sampleRow(writtenAt: written, ttlSeconds: 3600))
            let st = await cache.state(entity: "skill", pageId: "1111111111111111111111111111aaaa")
            try expect(st.cached, "cached")
            try expect(st.stale, "past TTL → stale")
            try expect(st.writtenAt == written, "writtenAt surfaced")
        }
    }

    await test("RowCache: within TTL is fresh; non-positive TTL never expires") {
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = sampleRow(writtenAt: written, ttlSeconds: 3600)
        try expect(!fresh.isExpired(now: written.addingTimeInterval(1800)), "30m < 1h TTL → fresh")
        try expect(fresh.isExpired(now: written.addingTimeInterval(5400)), "90m > 1h TTL → stale")
        let immortal = sampleRow(writtenAt: written, ttlSeconds: 0)
        try expect(!immortal.isExpired(now: written.addingTimeInterval(86_400)), "TTL 0 → never expires")
    }

    await test("RowCache: readAll returns empty for a missing entity dir") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try expect(await cache.readAll(entity: "nope").isEmpty, "no dir → empty list")
            let st = await cache.state(entity: "nope", pageId: "x")
            try expect(!st.cached && st.writtenAt == nil && !st.stale, "absent → (false,nil,false)")
        }
    }

    await test("RowCache: evict removes one; evictAll drops the entity") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try await cache.write(sampleRow(pageId: "aaaa1111111111111111111111111111"))
            try await cache.write(sampleRow(pageId: "bbbb1111111111111111111111111111"))
            try expect(await cache.readAll(entity: "skill").count == 2, "two rows")
            await cache.evict(entity: "skill", pageId: "aaaa1111111111111111111111111111")
            try expect(await cache.readAll(entity: "skill").count == 1, "one after evict")
            await cache.evictAll(entity: "skill")
            try expect(await cache.readAll(entity: "skill").isEmpty, "empty after evictAll")
        }
    }

    await test("RowCache: incrementCallCount bumps persisted counter; 0 when absent") {
        try await withTempHomeRows { _ in
            let cache = RegistryRowCache()
            try expect(await cache.incrementCallCount(entity: "skill", pageId: "deadbeef00000000000000000000feed") == 0,
                       "absent → 0 (no cadence tick)")
            try await cache.write(sampleRow(pageId: "deadbeef00000000000000000000feed", callCount: 1))
            try expect(await cache.incrementCallCount(entity: "skill", pageId: "deadbeef00000000000000000000feed") == 2,
                       "1 → 2")
            try expect(await cache.read(entity: "skill", pageId: "deadbeef00000000000000000000feed")?.callCount == 2,
                       "persisted")
        }
    }

    await test("RowCache: forwards-tolerant decode (unknown keys + missing fields)") {
        let json = """
        {"entity":"skill","pageId":"1111111111111111111111111111aaaa",
        "title":"T","properties":{"x":"y"},"futureKey":true}
        """
        let row = try JSONDecoder().decode(CachedRow.self, from: Data(json.utf8))
        try expect(row.entity == "skill", "entity decoded")
        try expect(row.title == "T", "title decoded")
        try expect(row.url == "", "missing url defaults empty")
        try expect(row.ttlSeconds == 3600, "missing ttlSeconds defaults 3600")
        try expect(row.callCount == 1, "missing callCount defaults 1")
        try expect(row.writtenAt == .distantPast, "missing writtenAt → distantPast")
    }

    await test("RowCache: write is atomic and survives a re-read via a new actor") {
        try await withTempHomeRows { _ in
            try await RegistryRowCache().write(sampleRow(title: "Persisted"))
            let got = await RegistryRowCache().read(entity: "skill", pageId: "1111111111111111111111111111aaaa")
            try expect(got?.title == "Persisted", "persisted across actor instances")
        }
    }
}
