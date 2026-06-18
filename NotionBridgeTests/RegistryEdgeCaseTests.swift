// RegistryEdgeCaseTests.swift — Data-Source Registry · adversarial edge cases
// NotionBridge · Tests
//
// Hardening suite: probes the ways the registry architecture could break under
// real-world inputs and concurrency. Each test asserts the DESIRED behavior, so
// a not-yet-handled edge fails here first and drives the fix. Hermetic (fake
// gateway + temp home).

import Foundation
import MCP
import NotionBridgeLib

// MARK: - Configurable fake gateway (supports multi-page query + failures)

private actor EdgeGateway: RegistryNotionGateway {
    var schemaToReturn = DataSourceSchema(columnsByName: [:])
    var pagesByCursor: [[NotionRow]] = []     // page 0, page 1, …
    var infinitePage: [NotionRow]? = nil      // if set, every query returns this + a cursor (runaway probe)
    var pages: [String: NotionRow] = [:]
    var failNetwork = false
    private(set) var queryCalls = 0
    private(set) var lastCreate: [BoundField] = []
    private(set) var lastUpdate: [BoundField] = []

    init() {}
    func setSchema(_ s: DataSourceSchema) { schemaToReturn = s }
    func setPages(_ p: [[NotionRow]]) { pagesByCursor = p }
    func setInfinite(_ rows: [NotionRow]) { infinitePage = rows }
    func putPage(_ r: NotionRow) { pages[r.id] = r }
    func setFail(_ v: Bool) { failNetwork = v }

    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema {
        if failNetwork { throw Err.offline }; return schemaToReturn
    }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        queryCalls += 1
        if failNetwork { throw Err.offline }
        if let inf = infinitePage { return (inf, "more") } // never terminates → exercises the cap
        let idx = startCursor.flatMap { Int($0) } ?? 0
        guard idx < pagesByCursor.count else { return ([], nil) }
        let next = (idx + 1 < pagesByCursor.count) ? String(idx + 1) : nil
        return (pagesByCursor[idx], next)
    }
    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        if failNetwork { throw Err.offline }
        guard let r = pages[CachedRow.normalize(pageId)] ?? pages[pageId] else { throw Err.notFound }
        return r
    }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        lastCreate = fields
        var cells: [String: NotionCell] = [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        return NotionRow(id: "edgecreated0000000000000000000aa", url: "u", lastEditedTime: "t", cells: cells)
    }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        lastUpdate = fields
        var cells = (pages[CachedRow.normalize(pageId)])?.cells ?? [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        return NotionRow(id: CachedRow.normalize(pageId), url: "u", lastEditedTime: "t2", cells: cells)
    }
    func archive(pageId: String, workspace: String?) async throws { if failNetwork { throw Err.offline }; pages[CachedRow.normalize(pageId)] = nil }
    func markdown(pageId: String, workspace: String?) async throws -> String { if failNetwork { throw Err.offline }; return "# body \(pageId)" }
    enum Err: Error { case offline, notFound }
}

private func edgeEntity(ttl: Int = 3600) -> RegistryEntity {
    RegistryEntity(
        key: "edge", displayName: "Edge", dataSourceId: "ds_edge", workspace: nil,
        properties: [
            RegistryProperty(key: "name", notionName: "Name", notionPropertyId: "p_name", type: "title", role: .title),
            RegistryProperty(key: "status", notionName: "Status", notionPropertyId: "p_status", type: "status", role: .status),
            RegistryProperty(key: "notes", notionName: "Notes", notionPropertyId: "p_notes", type: "rich_text"),
            RegistryProperty(key: "tags", notionName: "Tags", notionPropertyId: "p_tags", type: "multi_select"),
            RegistryProperty(key: "links", notionName: "Links", notionPropertyId: "p_links", type: "relation", role: .relation),
        ],
        cacheTTLSeconds: ttl, hasBody: true)
}

private func edgeRow(id: String, name: String, edited: String = "2026-06-17T10:00:00.000Z") -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: edited, cells: [
        "Name": NotionCell(id: "p_name", type: "title", value: .string(name)),
        "Status": NotionCell(id: "p_status", type: "status", value: .string("Active")),
    ])
}

private func withTempHomeEdge(_ body: () async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-regedge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? FileManager.default.removeItem(at: tmp) }
    try await body()
}

private func jsonCanon(_ obj: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "<bad>"
}

func runRegistryEdgeCaseTests() async {
    print("\n\u{1F9EA} Data-Source Registry — Edge cases (hardening)")

    // ───────────────────────── Codec ─────────────────────────

    await test("Edge/codec: rich_text > 2000 chars splits into ≤2000-char runs") {
        let long = String(repeating: "x", count: 5001)
        guard let payload = RegistryPropertyCodec.encode(type: "rich_text", value: .string(long)),
              let runs = payload["rich_text"] as? [[String: Any]] else { throw TestError.assertion("no rich_text runs") }
        try expect(runs.count == 3, "5001 chars → 3 runs (2000+2000+1001), got \(runs.count)")
        for r in runs {
            let c = ((r["text"] as? [String: Any])?["content"] as? String) ?? ""
            try expect(c.count <= 2000, "each run ≤2000, got \(c.count)")
        }
        let joined = runs.compactMap { (($0["text"] as? [String: Any])?["content"] as? String) }.joined()
        try expect(joined == long, "runs concatenate back to the original")
    }

    await test("Edge/codec: title > 2000 chars also splits into runs") {
        let long = String(repeating: "T", count: 4000)
        guard let payload = RegistryPropertyCodec.encode(type: "title", value: .string(long)),
              let runs = payload["title"] as? [[String: Any]] else { throw TestError.assertion("no title runs") }
        try expect(runs.count == 2, "4000 → 2 runs, got \(runs.count)")
    }

    await test("Edge/codec: select/status with unicode + emoji names round-trip") {
        for t in ["select", "status"] {
            let payload = RegistryPropertyCodec.encode(type: t, value: .string("𝐀 🔴"))!
            let name = ((payload[t] as? [String: Any])?["name"] as? String)
            try expect(name == "𝐀 🔴", "\(t) keeps unicode name")
            let decoded = RegistryPropertyCodec.decode(type: t, property: [t: ["name": "𝐀 🔴"]])
            try expect(decoded == .string("𝐀 🔴"), "\(t) decodes unicode name")
        }
    }

    await test("Edge/codec: multi_select from array AND comma-string") {
        let a = RegistryPropertyCodec.encode(type: "multi_select", value: .array([.string("x"), .string("y")]))!
        let b = RegistryPropertyCodec.encode(type: "multi_select", value: .string("x, y"))!
        try expect(jsonCanon(a) == jsonCanon(b), "array and comma-string produce the same payload")
    }

    await test("Edge/codec: null clears writable fields; unsupported types → nil") {
        try expect(jsonCanon(RegistryPropertyCodec.encode(type: "rich_text", value: .null)!) == jsonCanon(["rich_text": []]), "rich_text null → []")
        try expect(RegistryPropertyCodec.encode(type: "formula", value: .string("x")) == nil, "formula not writable")
        try expect(RegistryPropertyCodec.encode(type: "button", value: .string("x")) == nil, "button not writable")
        try expect(RegistryPropertyCodec.encode(type: "place", value: .string("x")) == nil, "place (unknown) not writable")
        try expect(RegistryPropertyCodec.decode(type: "place", property: ["place": ["name": "X"]]) == .null, "unknown type decodes to null, not garbage")
    }

    await test("Edge/codec: relation/people encode ids; decode ids back") {
        let payload = RegistryPropertyCodec.encode(type: "relation", value: .array([.string("id1"), .string("id2")]))!
        try expect(jsonCanon(payload) == jsonCanon(["relation": [["id": "id1"], ["id": "id2"]]]), "relation ids")
        let decoded = RegistryPropertyCodec.decode(type: "people", property: ["people": [["id": "u1"], ["id": "u2"]]])
        try expect(decoded == .array([.string("u1"), .string("u2")]), "people ids decode")
    }

    await test("Edge/codec: rich_text with newlines/quotes/unicode round-trips") {
        let s = "line1\nline2 \"q\" — café 🚀"
        let payload = RegistryPropertyCodec.encode(type: "rich_text", value: .string(s))!
        let content = (((payload["rich_text"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String)
        try expect(content == s, "special chars preserved")
    }

    // ───────────────────────── Projection ─────────────────────────

    await test("Edge/projection: empty-title row → title \"\" (not crash)") {
        let row = NotionRow(id: "p1", url: "u", lastEditedTime: "t", cells: ["Name": NotionCell(id: "p_name", type: "title", value: .string(""))])
        let (title, _) = RegistryReader.project(row, entity: edgeEntity())
        try expect(title == "", "empty title projects to empty string")
    }

    await test("Edge/projection: row with NO title cell → title \"\"") {
        let row = NotionRow(id: "p2", url: "u", lastEditedTime: "t", cells: ["Status": NotionCell(id: "p_status", type: "status", value: .string("Active"))])
        let (title, props) = RegistryReader.project(row, entity: edgeEntity())
        try expect(title == "", "no title cell → empty")
        try expect(props == .object(["status": .string("Active")]), "only present cells projected")
    }

    // ───────────────────────── Cache ─────────────────────────

    await test("Edge/cache: concurrent incrementCallCount loses no ticks (actor-serialized)") {
        try await withTempHomeEdge {
            let cache = RegistryRowCache()
            try await cache.write(CachedRow(entity: "edge", pageId: "cc11111111111111111111111111feed", title: "t", url: "u", properties: .object([:]), lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 3600, callCount: 1))
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<20 { g.addTask { _ = await cache.incrementCallCount(entity: "edge", pageId: "cc11111111111111111111111111feed") } }
            }
            let final = await cache.read(entity: "edge", pageId: "cc11111111111111111111111111feed")?.callCount
            try expect(final == 21, "1 + 20 concurrent increments = 21, got \(final ?? -1)")
        }
    }

    await test("Edge/cache: a corrupt cache file degrades to a miss (never throws)") {
        try await withTempHomeEdge {
            let dir = try BridgePaths.ensureApplicationSupport(.registryCache).appendingPathComponent("edge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: dir.appendingPathComponent("dead000000000000000000000000feed.json"))
            let got = await RegistryRowCache().read(entity: "edge", pageId: "dead000000000000000000000000feed")
            try expect(got == nil, "corrupt file → nil (hint, not truth)")
        }
    }

    // ───────────────────────── Reader pagination ─────────────────────────

    await test("Edge/reader: list FOLLOWS next_cursor across pages (no silent truncation)") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.setPages([
                [edgeRow(id: "aa00000000000000000000000000001", name: "A"), edgeRow(id: "aa00000000000000000000000000002", name: "B")],
                [edgeRow(id: "aa00000000000000000000000000003", name: "C"), edgeRow(id: "aa00000000000000000000000000004", name: "D")],
                [edgeRow(id: "aa00000000000000000000000000005", name: "E")],
            ])
            let rows = try await RegistryReader(gateway: gw).list(entity: edgeEntity(), limit: 100)
            try expect(rows.count == 5, "all 5 rows across 3 pages, got \(rows.count)")
            try expect(Set(rows.map { $0.title }) == ["A", "B", "C", "D", "E"], "every page included")
        }
    }

    await test("Edge/reader: list respects a row LIMIT and stops paginating (no runaway)") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.setInfinite([edgeRow(id: "bb00000000000000000000000000001", name: "X")]) // never terminates
            let rows = try await RegistryReader(gateway: gw).list(entity: edgeEntity(), limit: 50)
            try expect(rows.count <= 50, "limit honored (no infinite loop), got \(rows.count)")
            let calls = await gw.queryCalls
            try expect(calls < 100, "did not spin unbounded, \(calls) calls")
        }
    }

    await test("Edge/reader: a trashed (archived) page reads as not-found + evicts cache") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            let id = "ba00000000000000000000000000001"
            await gw.putPage(edgeRow(id: id, name: "Live"))
            let cache = RegistryRowCache()
            let reader = RegistryReader(gateway: gw, cache: cache)
            _ = try await reader.get(entity: edgeEntity(), pageId: id)                 // cache it live
            try expect(await cache.read(entity: "edge", pageId: id) != nil, "cached while live")
            // The page is now archived in Notion (soft-deleted elsewhere).
            await gw.putPage(NotionRow(id: CachedRow.normalize(id), url: "u", lastEditedTime: "t", cells: [:], archived: true))
            var threw = false
            do { _ = try await reader.get(entity: edgeEntity(), pageId: id, forceRefresh: true) }
            catch let e as RegistryReader.RegistryReadError { threw = (e == .deleted(CachedRow.normalize(id))) }
            try expect(threw, "archived page surfaces a deleted error (not live data)")
            try expect(await cache.read(entity: "edge", pageId: id) == nil, "cache evicted for the deleted row")
        }
    }

    await test("Edge/reader: offline mid-list serves the on-disk cache") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.setPages([[edgeRow(id: "cc00000000000000000000000000001", name: "Cached")]])
            let reader = RegistryReader(gateway: gw)
            _ = try await reader.list(entity: edgeEntity())          // warm
            await gw.setFail(true)
            let offline = try await reader.list(entity: edgeEntity()) // serve cache
            try expect(offline.count == 1 && offline.first?.title == "Cached", "offline list from cache")
        }
    }

    // ───────────────────────── Writer ─────────────────────────

    await test("Edge/writer: a >2000-char field WRITE chunks into multiple runs") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.putPage(edgeRow(id: "dd00000000000000000000000000001", name: "x"))
            _ = try await RegistryWriter(gateway: gw).update(entity: edgeEntity(), pageId: "dd00000000000000000000000000001",
                fields: ["notes": .string(String(repeating: "z", count: 4500))])
            let env = LiveRegistryGateway.encodeEnvelope(await gw.lastUpdate)
            let runs = (env["Notes"] as? [String: Any])?["rich_text"] as? [[String: Any]]
            try expect((runs?.count ?? 0) >= 3, "long notes split into ≥3 runs, got \(runs?.count ?? 0)")
        }
    }

    await test("Edge/writer: envelope keys by NAME (percent-encoded ids don't write)") {
        // A real Notion property whose id is `AH\`N` is returned as `AH%60N`;
        // that encoded id silently no-ops as a WRITE key, so the envelope must
        // key by the property NAME instead.
        let fields = [BoundField(propertyId: "AH%60N", notionName: "Description", type: "rich_text", value: .string("hi"), isTitle: false)]
        let env = LiveRegistryGateway.encodeEnvelope(fields)
        try expect(env["Description"] != nil, "keyed by name")
        try expect(env["AH%60N"] == nil, "NOT keyed by the percent-encoded id")
        // An unbound field (no id) is skipped even if it has a name.
        let unbound = [BoundField(propertyId: "", notionName: "X", type: "rich_text", value: .string("y"), isTitle: false)]
        try expect(LiveRegistryGateway.encodeEnvelope(unbound).isEmpty, "unbound field skipped")
    }

    await test("Edge/gateway: updateBody WRAPS in {properties}; createBody does not (NotionClient asymmetry)") {
        let fields = [BoundField(propertyId: "p1", notionName: "Description", type: "rich_text", value: .string("hi"), isTitle: false)]
        let upd = (try? JSONSerialization.jsonObject(with: LiveRegistryGateway.updateBody(fields))) as? [String: Any] ?? [:]
        try expect(upd["properties"] != nil, "updateBody wraps under ‘properties’ (updatePage sends the body unwrapped)")
        try expect((upd["properties"] as? [String: Any])?["Description"] != nil, "the field sits under properties")
        let cre = (try? JSONSerialization.jsonObject(with: LiveRegistryGateway.createBody(fields))) as? [String: Any] ?? [:]
        try expect(cre["properties"] == nil, "createBody is RAW (createPage wraps internally)")
        try expect(cre["Description"] != nil, "the field is top-level for create")
    }

    await test("Edge/writer: clearing a field to null emits the Notion clear payload") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.putPage(edgeRow(id: "ee00000000000000000000000000001", name: "x"))
            _ = try await RegistryWriter(gateway: gw).update(entity: edgeEntity(), pageId: "ee00000000000000000000000000001",
                fields: ["notes": .null, "tags": .null])
            let env = LiveRegistryGateway.encodeEnvelope(await gw.lastUpdate)
            try expect(jsonCanon(env["Notes"] as Any) == jsonCanon(["rich_text": []]), "notes cleared")
            try expect(jsonCanon(env["Tags"] as Any) == jsonCanon(["multi_select": []]), "tags cleared")
        }
    }

    // ───────────────────────── Config concurrency ─────────────────────────

    await test("Edge/config: concurrent upserts do not lose updates (serialized)") {
        try await withTempHomeEdge {
            _ = try await RegistryConfigStore.shared.seedIfMissing()
            await withTaskGroup(of: Void.self) { g in
                for i in 0..<12 {
                    g.addTask {
                        _ = try? await RegistryConfigStore.shared.upsertEntity(
                            RegistryEntity(key: "e\(i)", displayName: "E\(i)", dataSourceId: "ds\(i)", properties: [], cacheTTLSeconds: 60))
                    }
                }
            }
            let cfg = try await RegistryConfigStore.shared.load()
            let added = (0..<12).filter { cfg.entity("e\($0)") != nil }.count
            try expect(added == 12, "all 12 concurrent upserts persisted, got \(added)")
            try expect(cfg.entity("skill") != nil, "the seed entity survived the concurrent writes")
        }
    }

    // ───────────────────────── Module / VM ─────────────────────────

    await test("Edge/module: registry_get on a deleted row refetches and surfaces not-found") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.putPage(edgeRow(id: "ff00000000000000000000000000001", name: "Doomed"))
            let reader = RegistryReader(gateway: gw)
            _ = try await reader.get(entity: edgeEntity(), pageId: "ff00000000000000000000000000001") // cache it
            try await RegistryWriter(gateway: gw).delete(entity: edgeEntity(), pageId: "ff00000000000000000000000000001") // archive + evict
            var threw = false
            do { _ = try await reader.get(entity: edgeEntity(), pageId: "ff00000000000000000000000000001", forceRefresh: true) }
            catch { threw = true }
            try expect(threw, "get after delete (force) surfaces the 404")
        }
    }

    await test("Edge/possess: a body-less entity errors clearly via the module") {
        try await withTempHomeEdge {
            let prior = RegistryModule.gatewayProvider
            RegistryModule.gatewayProvider = { EdgeGateway() }
            defer { RegistryModule.gatewayProvider = prior }
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("nobody"), "dataSourceId": .string("ds_x"), "hasBody": .bool(false),
                "properties": .array([.object(["key": .string("t"), "notionName": .string("T"), "type": .string("title"), "role": .string("title")])]),
            ]))
            var threw = false
            do { _ = try await RegistryModule.makePossess().handler(.object(["entity": .string("nobody"), "id": .string("x")])) }
            catch { threw = true }
            try expect(threw, "possess on a body-less entity throws")
        }
    }

    await test("Edge/limiter: a 30-call burst stays spaced and never deadlocks") {
        let limiter = RegistryRateLimiter(maxRequestsPerSecond: 100) // 10ms spacing
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<30 { g.addTask { await limiter.acquire() } }
        }
        let elapsed = start.duration(to: .now)
        try expect(elapsed >= .milliseconds(250), "30 calls @10ms ≈ ≥290ms; got \(elapsed)")
        try expect(elapsed < .seconds(5), "did not deadlock")
    }

    // ───────────────────────── Round 2: deeper probes ─────────────────────────

    await test("Edge/cache: a path-traversal entity key is sanitized + still round-trips") {
        try await withTempHomeEdge {
            let cache = RegistryRowCache()
            let evil = "../../../etc/evil"
            try await cache.write(CachedRow(entity: evil, pageId: "ab00000000000000000000000000feed", title: "contained", url: "u", properties: .object([:]), lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 60))
            // Reads back via the SAME sanitized key (consistent).
            let got = await cache.read(entity: evil, pageId: "ab00000000000000000000000000feed")
            try expect(got?.title == "contained", "sanitized key round-trips")
            // Nothing escaped the registry-cache dir.
            let cacheRoot = BridgePaths.applicationSupport(.registryCache).path
            try expect(!FileManager.default.fileExists(atPath: "/etc/evil"), "no parent-escape write")
            try expect(FileManager.default.fileExists(atPath: cacheRoot), "stayed under registry-cache")
        }
    }

    await test("Edge/binder: an empty live schema → every property unmatched, not bound") {
        let r = RegistrySchemaBinder.bind(edgeEntity(), to: DataSourceSchema(columnsByName: [:]))
        try expect(!r.isClean && !r.entity.isFullyBound, "empty schema binds nothing")
        try expect(r.drift.count == 5, "all 5 properties reported unmatched, got \(r.drift.count)")
    }

    await test("Edge/binder: re-introspect CLEARS a dropped column's stale id (authoritative)") {
        // edgeEntity ships ids pre-set; bind against a schema MISSING "Status".
        var cols: [String: DataSourceSchema.Column] = [
            "Name": .init(id: "n2", type: "title"),
            "Notes": .init(id: "no2", type: "rich_text"),
            "Tags": .init(id: "tg2", type: "multi_select"),
            "Links": .init(id: "lk2", type: "relation"),
        ]
        let r = RegistrySchemaBinder.bind(edgeEntity(), to: DataSourceSchema(columnsByName: cols))
        try expect(r.entity.property("status")?.isBound == false, "dropped Status column → id cleared")
        try expect(r.entity.property("name")?.notionPropertyId == "n2", "present column rebinds to the LIVE id")
        try expect(!r.entity.isFullyBound, "entity not fully bound while a column is missing")
        try expect(r.drift.contains(.unmatched(key: "status", notionName: "Status")), "drift names the dropped column")
        cols["Status"] = .init(id: "st2", type: "status")
        let r2 = RegistrySchemaBinder.bind(r.entity, to: DataSourceSchema(columnsByName: cols))
        try expect(r2.entity.isFullyBound && !r2.hasDrift, "re-adding the column rebinds it clean")
    }

    await test("Edge/writer: create with NO title issues a single create (no follow-up update)") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            _ = try await RegistryWriter(gateway: gw).create(entity: edgeEntity(), fields: ["status": .string("Active")])
            let creates = await gw.lastCreate
            let updates = await gw.lastUpdate
            try expect(creates.count == 1 && !creates[0].isTitle, "single create carried the status field")
            try expect(updates.isEmpty, "no follow-up update when there is no title to seed first")
        }
    }

    await test("Edge/writer: an all-non-encodable write is rejected (never an empty no-op)") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.putPage(edgeRow(id: "ac00000000000000000000000000001", name: "x"))
            var threw = false
            // .array is not coercible into a rich_text payload → would encode to nothing.
            do { _ = try await RegistryWriter(gateway: gw).update(entity: edgeEntity(), pageId: "ac00000000000000000000000000001", fields: ["notes": .array([.string("a")])]) }
            catch let e as RegistryWriter.RegistryWriteError { threw = (e == .noWritableFields(entity: "edge")) }
            try expect(threw, "a write that would encode to {} is rejected")
        }
    }

    await test("Edge/cache: complex Value (relation arrays + nested) round-trips through JSON") {
        try await withTempHomeEdge {
            let props: Value = .object([
                "links": .array([.string("id1"), .string("id2")]),
                "tags": .array([.string("a"), .string("b")]),
                "meta": .object(["n": .double(1.5), "ok": .bool(true)]),
            ])
            let cache = RegistryRowCache()
            try await cache.write(CachedRow(entity: "edge", pageId: "ad00000000000000000000000000feed", title: "t", url: "u", properties: props, lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 60))
            let got = await cache.read(entity: "edge", pageId: "ad00000000000000000000000000feed")
            try expect(got?.properties == props, "nested arrays/objects survive the cache round-trip")
        }
    }

    await test("Edge/module: registry_add_entity upserts (re-add same key replaces, no dup)") {
        try await withTempHomeEdge {
            let prior = RegistryModule.gatewayProvider
            RegistryModule.gatewayProvider = { EdgeGateway() }
            defer { RegistryModule.gatewayProvider = prior }
            func add(_ name: String) async throws {
                _ = try await RegistryModule.makeAddEntity().handler(.object([
                    "key": .string("dup"), "displayName": .string(name), "dataSourceId": .string("ds_d"),
                    "properties": .array([.object(["key": .string("t"), "notionName": .string("T"), "type": .string("title"), "role": .string("title")])]),
                ]))
            }
            try await add("First"); try await add("Second")
            let out = try await RegistryModule.makeEntities().handler(.object([:]))
            guard case .object(let o) = out, case .array(let arr)? = o["entities"] else { throw TestError.assertion("no entities") }
            let dups = arr.filter { if case .object(let e) = $0, e["key"] == .string("dup") { return true } else { return false } }
            try expect(dups.count == 1, "exactly one ‘dup’ entity (upsert, not append), got \(dups.count)")
            if case .object(let e) = dups[0] { try expect(e["displayName"] == .string("Second"), "latest displayName wins") }
        }
    }

    await test("Edge/cache: a pathological 400-char entity key still writes + reads (capped filename)") {
        try await withTempHomeEdge {
            let cache = RegistryRowCache()
            let huge = String(repeating: "k", count: 400)
            try await cache.write(CachedRow(entity: huge, pageId: "af00000000000000000000000000feed", title: "ok", url: "u", properties: .object([:]), lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 60))
            let got = await cache.read(entity: huge, pageId: "af00000000000000000000000000feed")
            try expect(got?.title == "ok", "over-long key capped + round-trips (no FS error)")
        }
    }

    await test("Edge/introspect: a failed schema fetch leaves config UNCHANGED (fail-safe)") {
        try await withTempHomeEdge {
            let gw = EdgeGateway(); await gw.setFail(true)
            let prior = RegistryModule.gatewayProvider
            RegistryModule.gatewayProvider = { gw }
            defer { RegistryModule.gatewayProvider = prior }
            // skill is seeded + unbound; introspect should throw (offline) and NOT persist a partial/cleared binding.
            var threw = false
            do { _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")])) }
            catch { threw = true }
            try expect(threw, "introspect surfaces the schema-fetch failure")
            let out = try await RegistryModule.makeEntities().handler(.object([:]))
            if case .object(let o) = out, case .array(let arr)? = o["entities"], case .object(let e)? = arr.first {
                try expect(e["fullyBound"] == .bool(false), "config untouched — skill still unbound (no half-write)")
                try expect((e["properties"].flatMap { if case .array(let p) = $0 { return p.count } else { return nil } }) == 8, "all 8 props intact")
            } else { throw TestError.assertion("entities missing") }
        }
    }

    await test("Edge/codec: non-coercible value SKIPS multi_select/relation/people (no silent clear)") {
        // .bool/.object are caller mistakes — must be skipped (nil), NOT turned
        // into a clearing write that wipes the existing list (data-loss guard).
        try expect(RegistryPropertyCodec.encode(type: "multi_select", value: .bool(true)) == nil, "bool→multi_select skipped")
        try expect(RegistryPropertyCodec.encode(type: "relation", value: .object(["x": .string("y")])) == nil, "object→relation skipped")
        try expect(RegistryPropertyCodec.encode(type: "people", value: .bool(false)) == nil, "bool→people skipped")
        // .null still CLEARS (deliberate); coercible inputs still produce the list.
        try expect(jsonCanon(RegistryPropertyCodec.encode(type: "multi_select", value: .null)!) == jsonCanon(["multi_select": []]), "null→multi_select clears")
        try expect(jsonCanon(RegistryPropertyCodec.encode(type: "relation", value: .array([.string("id1")]))!) == jsonCanon(["relation": [["id": "id1"]]]), "array→relation ids")
    }

    await test("Edge/codec: textRuns chunks by UTF-16 units (emoji-safe, no grapheme split)") {
        let emoji = String(repeating: "😀", count: 1500) // each 😀 = 2 UTF-16 units → 3000 units
        guard let payload = RegistryPropertyCodec.encode(type: "rich_text", value: .string(emoji)),
              let runs = payload["rich_text"] as? [[String: Any]] else { throw TestError.assertion("no runs") }
        try expect(runs.count == 2, "3000 UTF-16 units → 2 runs, got \(runs.count)")
        for r in runs {
            let c = ((r["text"] as? [String: Any])?["content"] as? String) ?? ""
            try expect(c.utf16.count <= 2000, "each run ≤2000 UTF-16 units, got \(c.utf16.count)")
        }
        let joined = runs.compactMap { (($0["text"] as? [String: Any])?["content"] as? String) }.joined()
        try expect(joined == emoji, "runs reassemble to the original (no split grapheme)")
    }

    await test("Edge/cache: a path-traversal pageId is sanitized + contained") {
        try await withTempHomeEdge {
            let cache = RegistryRowCache()
            let evilId = "../../../tmp/escape"
            try await cache.write(CachedRow(entity: "edge", pageId: evilId, title: "contained", url: "u", properties: .object([:]), lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 60))
            try expect(await cache.read(entity: "edge", pageId: evilId)?.title == "contained", "sanitized pageId round-trips")
            try expect(!FileManager.default.fileExists(atPath: "/tmp/escape.json"), "no write escaped the cache dir")
        }
    }

    await test("Edge/reader: two concurrent gets on the same key both succeed + agree") {
        try await withTempHomeEdge {
            let gw = EdgeGateway()
            await gw.putPage(edgeRow(id: "ae00000000000000000000000000001", name: "Race"))
            let reader = RegistryReader(gateway: gw)
            async let a = reader.get(entity: edgeEntity(), pageId: "ae00000000000000000000000000001")
            async let b = reader.get(entity: edgeEntity(), pageId: "ae00000000000000000000000000001")
            let (ra, rb) = try await (a, b)
            try expect(ra.title == "Race" && rb.title == "Race", "both gets return the row")
            try expect(ra.pageId == rb.pageId, "consistent cache key")
        }
    }
}
