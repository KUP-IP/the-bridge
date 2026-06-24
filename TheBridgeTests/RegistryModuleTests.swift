// RegistryModuleTests.swift — Data-Source Registry (Wave 3)
// TheBridge · Tests
//
// The MCP tool surface: registration (8 tools, names, tiers) + handler behavior
// driven directly against an injected fake gateway (no security gate, no live
// Notion). Hermetic: config under a temp home; gatewayProvider restored after.

import Foundation
import MCP
import TheBridgeLib

private actor ModFakeGateway: RegistryNotionGateway {
    var schemaToReturn: DataSourceSchema
    var queryRows: [NotionRow]
    var pages: [String: NotionRow]
    private(set) var created: [[BoundField]] = []
    private(set) var updated: [(String, [BoundField])] = []
    private(set) var archived: [String] = []
    init(schema: DataSourceSchema, queryRows: [NotionRow] = [], pages: [String: NotionRow] = [:]) {
        self.schemaToReturn = schema; self.queryRows = queryRows; self.pages = pages
    }
    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema { schemaToReturn }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) { (queryRows, nil) }
    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        guard let r = pages[CachedRow.normalize(pageId)] ?? pages[pageId] else { throw NSError(domain: "fake", code: 404) }
        return r
    }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        created.append(fields)
        var cells: [String: NotionCell] = [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        return NotionRow(id: "createdid000000000000000000000aa", url: "u", lastEditedTime: "t", cells: cells)
    }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        updated.append((pageId, fields))
        var cells = (pages[CachedRow.normalize(pageId)])?.cells ?? [:]
        for f in fields { cells[f.notionName] = NotionCell(id: f.propertyId, type: f.type, value: f.value) }
        return NotionRow(id: CachedRow.normalize(pageId), url: "u", lastEditedTime: "t2", cells: cells)
    }
    func archive(pageId: String, workspace: String?) async throws { archived.append(pageId) }
    func markdown(pageId: String, workspace: String?) async throws -> String { "# Possessed \(pageId)" }
}

private func skillsSchema() -> DataSourceSchema {
    DataSourceSchema(columnsByName: [
        "Skill Name": .init(id: "id_title", type: "title"),
        "Slug": .init(id: "id_slug", type: "rich_text"),
        "Description": .init(id: "id_desc", type: "rich_text"),
        "Activation Examples": .init(id: "id_act", type: "rich_text"),
        "Anti-Triggers": .init(id: "id_anti", type: "rich_text"),
        "Status": .init(id: "id_status", type: "status"),
        "Domain": .init(id: "id_domain", type: "select"),
        "Specialist": .init(id: "id_spec", type: "relation"),
    ])
}

private func skillRow(id: String, name: String) -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: "2026-06-17T10:00:00.000Z", cells: [
        "Skill Name": NotionCell(id: "id_title", type: "title", value: .string(name)),
        "Description": NotionCell(id: "id_desc", type: "rich_text", value: .string("desc of \(name)")),
        "Status": NotionCell(id: "id_status", type: "status", value: .string("Stable")),
    ])
}

private func withRegistryModuleEnv(_ fake: ModFakeGateway, _ body: () async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-regmodule-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    let prior = RegistryModule.gatewayProvider
    RegistryModule.gatewayProvider = { fake }
    defer {
        RegistryModule.gatewayProvider = prior
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body()
}

private func obj(_ v: Value) -> [String: Value] { if case .object(let o) = v { return o } else { return [:] } }

func runRegistryModuleTests() async {
    print("\n\u{1F9F0} Data-Source Registry — Module (MCP tool surface)")

    // MARK: - Registration

    await test("RegistryModule registers exactly 11 tools with expected names") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        try expect(tools.count == 11, "expected 11 registry tools, got \(tools.count)")
        let names = Set(tools.map { $0.name })
        try expect(names == ["registry_entities", "registry_add_entity", "registry_remove_entity", "registry_introspect",
                             "registry_list", "registry_get", "registry_create", "registry_update", "registry_delete", "registry_possess",
                             "registry_hydrate"],
                   "tool names: \(names.sorted())")
    }

    await test("RegistryModule tiers: delete+remove_entity=request, writes=notify, reads=open") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        func tier(_ n: String) -> SecurityTier? { tools.first { $0.name == n }?.tier }
        try expect(tier("registry_delete") == .request, "delete must be .request (confirmation)")
        try expect(tier("registry_remove_entity") == .request, "remove_entity must be .request (destructive)")
        try expect(tier("registry_create") == .notify && tier("registry_update") == .notify && tier("registry_introspect") == .notify,
                   "writes are .notify")
        try expect(tier("registry_get") == .open && tier("registry_list") == .open && tier("registry_entities") == .open && tier("registry_possess") == .open,
                   "reads are .open")
    }

    // MARK: - Handlers (direct, gate-free)

    await test("registry_entities returns the seed with Skills entity #1") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeEntities().handler(.object([:]))
            let entities = obj(out)["entities"]
            guard case .array(let arr)? = entities, let first = arr.first else { throw TestError.assertion("no entities") }
            try expect(obj(first)["key"] == .string("skill"), "skill entity #1")
            try expect(obj(first)["fullyBound"] == .bool(false), "seed unbound until introspect")
        }
    }

    await test("registry_entities ships the seed UNBOUND to a data source (Decision 5: no hardcoded id)") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeEntities().handler(.object([:]))
            guard case .array(let arr)? = obj(out)["entities"], let first = arr.first else { throw TestError.assertion("no entities") }
            try expect(obj(first)["dataSourceId"] == .string(""), "seed ships with an empty dataSourceId (customer binds their own)")
            try expect(obj(first)["fullyBound"] == .bool(false), "and is not fully bound")
        }
    }

    await test("registry_introspect binds by name, persists, reports clean+fullyBound") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            try expect(obj(out)["fullyBound"] == .bool(true), "all 8 properties bound")
            try expect(obj(out)["clean"] == .bool(true), "no unmatched drift")
            try expect(obj(out)["boundCount"] == .int(8), "8 bound")
            // Persisted: a fresh entities call now shows fullyBound true.
            let after = try await RegistryModule.makeEntities().handler(.object([:]))
            if case .array(let arr)? = obj(after)["entities"], let first = arr.first {
                try expect(obj(first)["fullyBound"] == .bool(true), "binding persisted to config")
            } else { throw TestError.assertion("entities missing after introspect") }
        }
    }

    await test("registry_list projects rows via the bound/name map") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "aaaa0000000000000000000000000001", name: "Alpha"),
            skillRow(id: "aaaa0000000000000000000000000002", name: "Beta"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeList().handler(.object(["entity": .string("skill")]))
            try expect(obj(out)["count"] == .int(2), "two rows")
            guard case .array(let rows)? = obj(out)["rows"], let r0 = rows.first else { throw TestError.assertion("no rows") }
            try expect(obj(r0)["title"] == .string("Alpha"), "projected title")
            try expect(obj(obj(r0)["properties"] ?? .null)["summary"] == .string("desc of Alpha"),
                       "projected canonical key ‘summary’ ← Notion ‘Description’")
        }
    }

    await test("registry_get returns one projected row by id") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "bbbb0000000000000000000000000001": skillRow(id: "bbbb0000000000000000000000000001", name: "Gamma"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeGet().handler(.object(["entity": .string("skill"), "id": .string("bbbb0000000000000000000000000001")]))
            try expect(obj(out)["title"] == .string("Gamma"), "got the row")
        }
    }

    await test("registry_create requires binding then create-then-update") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            // bind first (persists), then create.
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Newbie"), "summary": .string("hi")]),
            ]))
            try expect(obj(out)["created"] == .bool(true), "created")
            let createdCalls = await fake.created.count
            let updatedCalls = await fake.updated.count
            try expect(createdCalls == 1 && updatedCalls == 1, "create-then-update (title create + rest patch)")
        }
    }

    await test("registry_possess loads the body of a body-bearing entity") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makePossess().handler(.object(["entity": .string("skill"), "id": .string("cccc0000000000000000000000000001")]))
            guard case .string(let body)? = obj(out)["body"] else { throw TestError.assertion("no body") }
            try expect(body.contains("Possessed"), "possessed body returned")
        }
    }

    await test("registry_add_entity registers a new entity (Decision 5 add flow)") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("project"),
                "displayName": .string("Projects"),
                "dataSourceId": .string("f6d6ae1d-bfb4-4494-be18-c46e87dea149"),
                "hasBody": .bool(false),
                "cacheTTLSeconds": .int(300),
                "properties": .array([
                    .object(["key": .string("title"), "notionName": .string("VENTURE > PROJECT"), "type": .string("title"), "role": .string("title")]),
                    .object(["key": .string("status"), "notionName": .string("Status"), "type": .string("status"), "role": .string("status")]),
                ]),
            ]))
            try expect(obj(out)["added"] == .bool(true), "added")
            // Persisted: registry_entities now lists 2 entities incl. project.
            let after = try await RegistryModule.makeEntities().handler(.object([:]))
            guard case .array(let arr)? = obj(after)["entities"] else { throw TestError.assertion("no entities") }
            let keys = arr.compactMap { e -> String? in if case .string(let k)? = obj(e)["key"] { return k } else { return nil } }
            try expect(Set(keys) == ["skill", "project"], "skill + project configured, got \(keys)")
        }
    }

    await test("registry_remove_entity removes a non-seed entity (add → remove → gone)") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            // Add a second entity, then remove it.
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("project"),
                "dataSourceId": .string("f6d6ae1d-bfb4-4494-be18-c46e87dea149"),
                "properties": .array([
                    .object(["key": .string("title"), "notionName": .string("Name"), "type": .string("title"), "role": .string("title")]),
                ]),
            ]))
            let out = try await RegistryModule.makeRemoveEntity().handler(.object(["entity": .string("project")]))
            try expect(obj(out)["removed"] == .bool(true), "removed")
            // Persisted: registry_entities no longer lists project (skill seed remains).
            let after = try await RegistryModule.makeEntities().handler(.object([:]))
            guard case .array(let arr)? = obj(after)["entities"] else { throw TestError.assertion("no entities") }
            let keys = arr.compactMap { e -> String? in if case .string(let k)? = obj(e)["key"] { return k } else { return nil } }
            try expect(keys == ["skill"], "only the skill seed remains, got \(keys)")
        }
    }

    await test("registry_remove_entity refuses the seeded Skills entity without confirm") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            var threw = false
            do { _ = try await RegistryModule.makeRemoveEntity().handler(.object(["entity": .string("skill")])) }
            catch { threw = true }
            try expect(threw, "removing the seed without confirm:true must throw")
            // Still present.
            let after = try await RegistryModule.makeEntities().handler(.object([:]))
            if case .array(let arr)? = obj(after)["entities"] {
                try expect(arr.count == 1, "skill seed must survive a guarded removal attempt")
            } else { throw TestError.assertion("entities missing") }
        }
    }

    await test("registry_remove_entity removes the seed WITH confirm:true") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeRemoveEntity().handler(.object(["entity": .string("skill"), "confirm": .bool(true)]))
            try expect(obj(out)["removed"] == .bool(true), "seed removed with explicit confirm")
            let after = try await RegistryModule.makeEntities().handler(.object([:]))
            if case .array(let arr)? = obj(after)["entities"] {
                try expect(arr.isEmpty, "registry now empty after confirmed seed removal, got \(arr.count)")
            } else { throw TestError.assertion("entities missing") }
        }
    }

    await test("registry_remove_entity rejects unknown entity") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            var threw = false
            do { _ = try await RegistryModule.makeRemoveEntity().handler(.object(["entity": .string("ghost")])) }
            catch { threw = true }
            try expect(threw, "removing an unknown entity must throw")
        }
    }

    await test("registry handlers reject unknown entity") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            var threw = false
            do { _ = try await RegistryModule.makeList().handler(.object(["entity": .string("nope")])) }
            catch { threw = true }
            try expect(threw, "unknown entity must throw")
        }
    }
}
