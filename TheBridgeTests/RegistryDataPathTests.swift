// RegistryDataPathTests.swift — Data-Source Registry (Wave 2)
// TheBridge · Tests
//
// The live data path against a deterministic in-memory gateway (no network):
//   - RegistrySchemaBinder: bind-by-name → ids, unmatched + type-drift.
//   - RegistryReader: miss→fetch+cache, fresh hit (no refetch), forceRefresh,
//     stale→refetch, offline→serve stale, list caches + offline fallback,
//     rename-safe projection by bound id.
//   - RegistryWriter: create-then-update split, update, unknown/unbound errors,
//     delete = archive + cache evict.
//   - RegistryRateLimiter: spacing ≥ minInterval across rapid acquires.
//
// Hermetic: cache routed through BridgePaths.overrideHomeForTesting.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Fake gateway

private actor FakeRegistryGateway: RegistryNotionGateway {
    var schemaToReturn = DataSourceSchema(columnsByName: [:])
    var pages: [String: NotionRow] = [:]
    var queryRows: [NotionRow] = []
    var failNetwork = false
    private(set) var pageCalls = 0
    private(set) var queryCalls = 0
    private(set) var created: [[BoundField]] = []
    private(set) var updated: [(id: String, fields: [BoundField])] = []
    private(set) var archived: [String] = []
    private var nextId = 1

    func setFail(_ v: Bool) { failNetwork = v }
    func putPage(_ row: NotionRow) { pages[row.id] = row }
    func setQueryRows(_ rows: [NotionRow]) { queryRows = rows }
    func setSchema(_ s: DataSourceSchema) { schemaToReturn = s }

    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema {
        if failNetwork { throw FakeError.offline }
        return schemaToReturn
    }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        queryCalls += 1
        if failNetwork { throw FakeError.offline }
        return (queryRows, nil)
    }
    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        pageCalls += 1
        if failNetwork { throw FakeError.offline }
        guard let row = pages[CachedRow.normalize(pageId)] ?? pages[pageId] else { throw FakeError.notFound }
        return row
    }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        if failNetwork { throw FakeError.offline }
        created.append(fields)
        let id = "newid\(nextId)pad000000000000000000000"; nextId += 1
        let row = Self.row(id: String(id.prefix(32)), fields: fields)
        pages[row.id] = row
        return row
    }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        if failNetwork { throw FakeError.offline }
        updated.append((pageId, fields))
        let norm = CachedRow.normalize(pageId)
        var cells = (pages[norm] ?? pages[pageId])?.cells ?? [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        let row = NotionRow(id: norm, url: "https://n/\(norm)", lastEditedTime: "2026-06-17T12:00:00.000Z", cells: cells)
        pages[norm] = row
        return row
    }
    func archive(pageId: String, workspace: String?) async throws {
        if failNetwork { throw FakeError.offline }
        archived.append(pageId)
        pages[CachedRow.normalize(pageId)] = nil
    }
    func markdown(pageId: String, workspace: String?) async throws -> String {
        if failNetwork { throw FakeError.offline }
        return "# Body of \(pageId)\n\npossessed."
    }

    enum FakeError: Error { case offline, notFound }

    static func row(id: String, fields: [BoundField]) -> NotionRow {
        var cells: [String: NotionCell] = [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        return NotionRow(id: id, url: "https://n/\(id)", lastEditedTime: "2026-06-17T10:00:00.000Z", cells: cells)
    }
}

// MARK: - Fixtures

private func widgetEntity(ttl: Int = 3600) -> RegistryEntity {
    RegistryEntity(
        key: "widget", displayName: "Widgets", dataSourceId: "ds_widget", workspace: nil,
        properties: [
            RegistryProperty(key: "name", notionName: "Name", notionPropertyId: "p_name", type: "title", role: .title),
            RegistryProperty(key: "status", notionName: "Status", notionPropertyId: "p_status", type: "status", role: .status),
            RegistryProperty(key: "count", notionName: "Count", notionPropertyId: "p_count", type: "number"),
        ],
        cacheTTLSeconds: ttl, hasBody: true)
}

private func widgetRow(id: String, name: String, status: String, count: Double, edited: String = "2026-06-17T10:00:00.000Z") -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: edited, cells: [
        "Name": NotionCell(id: "p_name", type: "title", value: .string(name)),
        "Status": NotionCell(id: "p_status", type: "status", value: .string(status)),
        "Count": NotionCell(id: "p_count", type: "number", value: .double(count)),
    ])
}

private func withTempHomeReg(_ body: (RegistryRowCache) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-regdatapath-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? FileManager.default.removeItem(at: tmp) }
    try await body(RegistryRowCache())
}

func runRegistryDataPathTests() async {
    print("\n\u{1F517} Data-Source Registry — Live data path (binder · reader · writer · limiter)")

    // MARK: - Binder

    await test("Binder: matches by name → binds ids, isClean, no drift") {
        let schema = DataSourceSchema(columnsByName: [
            "Skill Name": .init(id: "id_title", type: "title"),
            "Slug": .init(id: "id_slug", type: "rich_text"),
            "Description": .init(id: "id_desc", type: "rich_text"),
            "Activation Examples": .init(id: "id_act", type: "rich_text"),
            "Anti-Triggers": .init(id: "id_anti", type: "rich_text"),
            "Status": .init(id: "id_status", type: "status"),
            "Domain": .init(id: "id_domain", type: "select"),
            "Specialist": .init(id: "id_spec", type: "relation"),
        ])
        let r = RegistrySchemaBinder.bind(.skillsSeed(), to: schema)
        try expect(r.isClean, "all matched")
        try expect(!r.hasDrift, "no drift")
        try expect(r.entity.isFullyBound, "fully bound")
        try expect(r.entity.property("name")?.notionPropertyId == "id_title", "title bound by name")
    }

    await test("Binder: missing column → unmatched drift; entity not clean") {
        let schema = DataSourceSchema(columnsByName: ["Name": .init(id: "p1", type: "title")])
        let r = RegistrySchemaBinder.bind(widgetEntity(), to: schema)
        try expect(!r.isClean, "unmatched present → not clean")
        try expect(r.drift.contains(.unmatched(key: "status", notionName: "Status")), "Status unmatched")
        try expect(r.drift.contains(.unmatched(key: "count", notionName: "Count")), "Count unmatched")
        try expect(r.entity.property("name")?.isBound == true, "matched one still binds")
    }

    await test("Binder: type drift detected but still clean (id resolves)") {
        let schema = DataSourceSchema(columnsByName: [
            "Name": .init(id: "p_name", type: "title"),
            "Status": .init(id: "p_status", type: "select"),   // declared status, live select
            "Count": .init(id: "p_count", type: "number"),
        ])
        let r = RegistrySchemaBinder.bind(widgetEntity(), to: schema)
        try expect(r.isClean, "all names matched → clean")
        try expect(r.hasDrift, "but type drift surfaced")
        try expect(r.drift.contains(.typeMismatch(key: "status", expected: "status", actual: "select")),
                   "status type drift")
    }

    // MARK: - Reader

    await test("Reader.get: miss → fetch+cache; fresh hit → no refetch") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.putPage(widgetRow(id: "aaaa0000000000000000000000000001", name: "W1", status: "Active", count: 3))
            let reader = RegistryReader(gateway: gw, cache: cache)
            let first = try await reader.get(entity: widgetEntity(), pageId: "aaaa0000000000000000000000000001")
            try expect(first.title == "W1", "projected title")
            try expect(first.properties == .object(["name": .string("W1"), "status": .string("Active"), "count": .double(3)]),
                       "projected by canonical keys")
            try expect(await gw.pageCalls == 1, "one fetch on miss")
            _ = try await reader.get(entity: widgetEntity(), pageId: "aaaa0000000000000000000000000001")
            try expect(await gw.pageCalls == 1, "fresh hit → no second fetch")
        }
    }

    await test("Reader.get: forceRefresh refetches even when fresh") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.putPage(widgetRow(id: "aaaa0000000000000000000000000002", name: "W2", status: "Active", count: 1))
            let reader = RegistryReader(gateway: gw, cache: cache)
            _ = try await reader.get(entity: widgetEntity(), pageId: "aaaa0000000000000000000000000002")
            _ = try await reader.get(entity: widgetEntity(), pageId: "aaaa0000000000000000000000000002", forceRefresh: true)
            try expect(await gw.pageCalls == 2, "forceRefresh fetches again")
        }
    }

    await test("Reader.get: offline with cached copy → serve cache (no throw)") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.putPage(widgetRow(id: "aaaa0000000000000000000000000003", name: "W3", status: "Done", count: 9))
            let reader = RegistryReader(gateway: gw, cache: cache)
            _ = try await reader.get(entity: widgetEntity(ttl: 0), pageId: "aaaa0000000000000000000000000003") // ttl 0 = never stale here, but force a refresh path next
            await gw.setFail(true)
            // Even with ttl 0 (never expires) the cached copy serves; flip to a stale entity to exercise the offline-refresh branch:
            let staleEntity = widgetEntity(ttl: 1)
            // re-read with stale TTL: cache exists (from prior write under same entity key 'widget'), refresh fails → serve stale
            let got = try await reader.get(entity: staleEntity, pageId: "aaaa0000000000000000000000000003")
            try expect(got.title == "W3", "served stale offline copy")
        }
    }

    await test("Reader.list: caches rows; offline → serves cached list") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.setQueryRows([
                widgetRow(id: "bbbb0000000000000000000000000001", name: "A", status: "Active", count: 1),
                widgetRow(id: "bbbb0000000000000000000000000002", name: "B", status: "Done", count: 2),
            ])
            let reader = RegistryReader(gateway: gw, cache: cache)
            let live = try await reader.list(entity: widgetEntity())
            try expect(live.count == 2, "two rows listed + cached")
            await gw.setFail(true)
            let offline = try await reader.list(entity: widgetEntity())
            try expect(offline.count == 2, "offline list served from cache")
            try expect(await gw.queryCalls == 2, "queried twice (2nd failed → cache)")
        }
    }

    await test("Reader.project: rename-safe — matches by bound id, not name") {
        // The live row's Notion NAME changed ("Name" → "Renamed"), but the id is
        // the same. Projection must still find it via the bound id.
        var entity = widgetEntity()
        let renamedRow = NotionRow(id: "cccc0000000000000000000000000001", url: "u", lastEditedTime: "t", cells: [
            "Renamed": NotionCell(id: "p_name", type: "title", value: .string("StillMe")),
        ])
        let (title, _) = RegistryReader.project(renamedRow, entity: entity)
        try expect(title == "StillMe", "projected via bound id despite rename")
        entity.properties[0].notionPropertyId = nil  // unbound → falls back to name match (which now fails)
        let (title2, _) = RegistryReader.project(renamedRow, entity: entity)
        try expect(title2 == "", "unbound + renamed → no match (fallback by name)")
    }

    await test("Reader.body: possess loads the page body when hasBody") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            let reader = RegistryReader(gateway: gw, cache: cache)
            let body = try await reader.body(entity: widgetEntity(), pageId: "dddd0000000000000000000000000001")
            try expect(body.contains("possessed"), "body loaded")
            var noBody = widgetEntity(); noBody.hasBody = false
            try expect(try await reader.body(entity: noBody, pageId: "x").isEmpty, "no body when hasBody false")
        }
    }

    // MARK: - Writer

    await test("Writer.create: create-then-update (title-only create, PATCH rest)") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            let writer = RegistryWriter(gateway: gw, cache: cache)
            // count is fractional: an integral .double round-trips through the
            // cache's JSON as `7` and MCP's Value decodes it back as .int (JSON-
            // identical on the wire, different Value case) — 7.5 stays .double so
            // the in-memory and on-disk projections compare equal.
            let cr = try await writer.create(entity: widgetEntity(),
                fields: ["name": .string("New"), "status": .string("Active"), "count": .double(7.5)])
            let created = await gw.created
            let updated = await gw.updated
            try expect(created.count == 1, "one create")
            try expect(created[0].count == 1 && created[0][0].isTitle, "create carried TITLE only")
            try expect(updated.count == 1, "one follow-up update")
            try expect(updated[0].fields.count == 2, "update carried the 2 non-title fields")
            try expect(cr.title == "New", "returned row cached + projected")
            let fullProjection: Value = .object(["name": .string("New"), "status": .string("Active"), "count": .double(7.5)])
            try expect(cr.properties == fullProjection, "returned row carries the full projection, got \(cr.properties)")
            // Cache warmed.
            let cached = await cache.read(entity: "widget", pageId: cr.pageId)
            try expect(cached != nil, "post-create cache populated at key \(cr.pageId)")
            try expect(cached?.properties == fullProjection, "cache holds the full projection")
        }
    }

    await test("Writer.update: PATCHes by id and refreshes cache") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.putPage(widgetRow(id: "eeee0000000000000000000000000001", name: "Old", status: "Active", count: 1))
            let writer = RegistryWriter(gateway: gw, cache: cache)
            let cr = try await writer.update(entity: widgetEntity(), pageId: "eeee0000000000000000000000000001",
                fields: ["status": .string("Done")])
            try expect(cr.properties == .object(["name": .string("Old"), "status": .string("Done"), "count": .double(1)]),
                       "merged update projected")
            try expect(await gw.updated.first?.fields.first?.propertyId == "p_status", "keyed by property id")
        }
    }

    await test("Writer: unknown field → error; unbound field → error") {
        try await withTempHomeReg { cache in
            let writer = RegistryWriter(gateway: FakeRegistryGateway(), cache: cache)
            do { _ = try await writer.update(entity: widgetEntity(), pageId: "x", fields: ["nope": .string("v")]); try expect(false, "should throw") }
            catch let e as RegistryWriter.RegistryWriteError { try expect(e == .unknownFields(entity: "widget", keys: ["nope"]), "unknown field error") }

            var unbound = widgetEntity(); unbound.properties[1].notionPropertyId = nil // status unbound
            do { _ = try await writer.update(entity: unbound, pageId: "x", fields: ["status": .string("v")]); try expect(false, "should throw") }
            catch let e as RegistryWriter.RegistryWriteError { try expect(e == .notFullyBound(entity: "widget", unbound: ["status"]), "unbound field error") }
        }
    }

    await test("Writer.delete: archives + evicts cache") {
        try await withTempHomeReg { cache in
            let gw = FakeRegistryGateway()
            await gw.putPage(widgetRow(id: "ffff0000000000000000000000000001", name: "Doomed", status: "Active", count: 0))
            let reader = RegistryReader(gateway: gw, cache: cache)
            _ = try await reader.get(entity: widgetEntity(), pageId: "ffff0000000000000000000000000001") // warm cache
            try expect(await cache.read(entity: "widget", pageId: "ffff0000000000000000000000000001") != nil, "cached")
            let writer = RegistryWriter(gateway: gw, cache: cache)
            try await writer.delete(entity: widgetEntity(), pageId: "ffff0000000000000000000000000001")
            try expect(await gw.archived.contains("ffff0000000000000000000000000001"), "archived")
            try expect(await cache.read(entity: "widget", pageId: "ffff0000000000000000000000000001") == nil, "evicted")
        }
    }

    // MARK: - Rate limiter

    await test("RateLimiter: spaces rapid acquires by ≥ minInterval") {
        let limiter = RegistryRateLimiter(maxRequestsPerSecond: 50) // 20ms spacing
        let start = ContinuousClock.now
        for _ in 0..<5 { await limiter.acquire() }
        let elapsed = start.duration(to: .now)
        // 5 acquires reserve slots at 0,20,40,60,80ms → ≥ ~80ms total.
        try expect(elapsed >= .milliseconds(70), "5 acquires took \(elapsed), expected ≥70ms")
    }

    await test("RateLimiter: disabled (≤0) never waits") {
        let limiter = RegistryRateLimiter(maxRequestsPerSecond: 0)
        let start = ContinuousClock.now
        for _ in 0..<10 { await limiter.acquire() }
        try expect(start.duration(to: .now) < .milliseconds(50), "disabled limiter is instant")
    }
}
