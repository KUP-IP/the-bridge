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
    var failMarkdownWrite = false
    private(set) var created: [[BoundField]] = []
    private(set) var updated: [(String, [BoundField])] = []
    private(set) var archived: [String] = []
    private(set) var markdownWrites: [(pageId: String, markdown: String)] = []
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
    func writeMarkdown(pageId: String, workspace: String?, markdown: String) async throws {
        if failMarkdownWrite { throw NSError(domain: "fake.markdown", code: 500) }
        markdownWrites.append((pageId, markdown))
    }
    func setFailMarkdownWrite(_ value: Bool) { failMarkdownWrite = value }
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

private func packetSchema() -> DataSourceSchema {
    DataSourceSchema(columnsByName: [
        "Packet Name": .init(id: "id_packet_title", type: "title"),
        "Status": .init(id: "id_packet_status", type: "status"),
        "PROJECT": .init(id: "id_packet_project", type: "relation"),
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
    try? await RegistryCreateIdempotencyStore.shared.resetForTesting()
    try await body()
}

private func obj(_ v: Value) -> [String: Value] { if case .object(let o) = v { return o } else { return [:] } }

func runRegistryModuleTests() async {
    print("\n\u{1F9F0} Data-Source Registry — Module (MCP tool surface)")

    // MARK: - Registration

    await test("RegistryModule registers exactly 12 tools with expected names") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        try expect(tools.count == 12, "expected 12 registry tools, got \(tools.count)")
        let names = Set(tools.map { $0.name })
        try expect(names == ["registry_entities", "registry_add_entity", "registry_remove_entity", "registry_introspect",
                             "registry_list", "registry_find", "registry_get", "registry_create", "registry_update", "registry_delete", "registry_possess",
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
        try expect(tier("registry_get") == .open && tier("registry_list") == .open && tier("registry_find") == .open && tier("registry_entities") == .open && tier("registry_possess") == .open,
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

    // MARK: - registry_find (convergent resolve-before-write)

    await test("registry_find exact match → single row id") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000001", name: "Alpha"),
            skillRow(id: "ffff0000000000000000000000000002", name: "Beta"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Alpha")]),
            ]))
            try expect(obj(out)["count"] == .int(1), "exactly one match")
            guard case .array(let rows)? = obj(out)["rows"], let r0 = rows.first else { throw TestError.assertion("no rows") }
            try expect(obj(r0)["id"] == .string("ffff0000000000000000000000000001"), "the correct row id")
            try expect(obj(r0)["title"] == .string("Alpha"), "and its title")
        }
    }

    await test("registry_find no match → empty result, NOT an error") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000003", name: "Alpha"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("DoesNotExist")]),
            ]))
            try expect(obj(out)["count"] == .int(0), "zero matches")
            guard case .array(let rows)? = obj(out)["rows"] else { throw TestError.assertion("rows missing") }
            try expect(rows.isEmpty, "empty rows array, no throw")
        }
    }

    await test("registry_find ambiguous → multiple row ids") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000004", name: "Dup"),
            skillRow(id: "ffff0000000000000000000000000005", name: "Dup"),
            skillRow(id: "ffff0000000000000000000000000006", name: "Other"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Dup")]),
            ]))
            try expect(obj(out)["count"] == .int(2), "two ambiguous matches")
            guard case .array(let rows)? = obj(out)["rows"] else { throw TestError.assertion("rows missing") }
            let ids = Set(rows.compactMap { r -> String? in if case .string(let s)? = obj(r)["id"] { return s } else { return nil } })
            try expect(ids == ["ffff0000000000000000000000000004", "ffff0000000000000000000000000005"], "both dup ids: \(ids.sorted())")
        }
    }

    await test("registry_find matches by BOUND property id after introspect (rename-safe)") {
        // Introspect binds Notion 'Description' → canonical key 'summary'. A find
        // predicate on 'summary' must match via the bound id, not the raw name.
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000007", name: "Zeta"),   // summary = "desc of Zeta"
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            // Case-insensitive scalar match on the id-resolved canonical key.
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["summary": .string("DESC OF ZETA")]),
            ]))
            try expect(obj(out)["count"] == .int(1), "matched by bound id, case-insensitive")
            guard case .array(let rows)? = obj(out)["rows"], let r0 = rows.first else { throw TestError.assertion("no rows") }
            try expect(obj(r0)["id"] == .string("ffff0000000000000000000000000007"), "the Zeta row")
        }
    }

    await test("registry_find AND semantics: all predicates must match") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000008", name: "Multi"),   // status = "Stable"
        ])
        try await withRegistryModuleEnv(fake) {
            let hit = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Multi"), "status": .string("Stable")]),
            ]))
            try expect(obj(hit)["count"] == .int(1), "both predicates satisfied → match")
            let miss = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Multi"), "status": .string("Deprecated")]),
            ]))
            try expect(obj(miss)["count"] == .int(0), "one predicate fails → no match")
        }
    }

    await test("registry_find unknown entity → invalidArguments error") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            do {
                _ = try await RegistryModule.makeFind().handler(.object([
                    "entity": .string("ghost"),
                    "where": .object(["name": .string("x")]),
                ]))
                throw TestError.assertion("expected unknown-entity error")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
        }
    }

    await test("registry_find empty/missing where → invalidArguments error") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            do {
                _ = try await RegistryModule.makeFind().handler(.object(["entity": .string("skill"), "where": .object([:])]))
                throw TestError.assertion("expected empty-where error")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
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

    await test("registry_create creates body-bearing packet with relation and verbatim Markdown body") {
        let fake = ModFakeGateway(schema: packetSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("session"),
                "displayName": .string("Packets"),
                "dataSourceId": .string("packet_ds"),
                "hasBody": .bool(true),
                "properties": .array([
                    .object(["key": .string("name"), "notionName": .string("Packet Name"), "type": .string("title"), "role": .string("title")]),
                    .object(["key": .string("status"), "notionName": .string("Status"), "type": .string("status"), "role": .string("status")]),
                    .object(["key": .string("project"), "notionName": .string("PROJECT"), "type": .string("relation"), "role": .string("relation")]),
                ]),
            ]))
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("session")]))
            let markdown = """
            # Approved Proposal

            Keep this **exact** wording.

            - First item
            - [Linked item](https://example.com)

            > Quoted source text

            ```json
            {"copy":"verbatim"}
            ```
            """
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("session"),
                "fields": .object([
                    "name": .string("Bridge Tool Surface Completeness and Policy Coherence"),
                    "status": .string("QUEUE"),
                    "project": .array([.string("37fcbb58-889e-81f1-867e-d71b11dd9baf")]),
                ]),
                "bodyMarkdown": .string(markdown),
            ]))
            try expect(obj(out)["created"] == .bool(true), "created")
            try expect(obj(out)["partialFailure"] == .bool(false), "not partial")
            let created = await fake.created
            let updated = await fake.updated
            try expect(created.count == 1 && created[0].contains(where: { $0.notionName == "Packet Name" && $0.isTitle }), "title created")
            try expect(updated.count == 1, "non-title fields patched")
            try expect(updated[0].1.contains(where: { $0.notionName == "PROJECT" && $0.type == "relation" }), "PROJECT relation patched normally")
            let writes = await fake.markdownWrites
            try expect(writes.count == 1, "one body write")
            try expect(writes[0].markdown == markdown, "markdown body must be passed verbatim")
            let bodyWrite = obj(obj(out)["bodyWrite"] ?? .null)
            try expect(bodyWrite["requested"] == .bool(true) && bodyWrite["succeeded"] == .bool(true), "body write receipt")
        }
    }

    await test("registry_create remains compatible for property-only creates") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Property Only")]),
            ]))
            try expect(obj(out)["created"] == .bool(true), "created")
            let writes = await fake.markdownWrites
            try expect(writes.isEmpty, "no body write for property-only create")
        }
    }

    await test("registry_create rejects bodyMarkdown for non-body entity before row creation") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("project"),
                "dataSourceId": .string("project_ds"),
                "hasBody": .bool(false),
                "properties": .array([
                    .object(["key": .string("name"), "notionName": .string("Skill Name"), "type": .string("title"), "role": .string("title")]),
                ]),
            ]))
            var threw = false
            do {
                _ = try await RegistryModule.makeCreate().handler(.object([
                    "entity": .string("project"),
                    "fields": .object(["name": .string("No Body")]),
                    "bodyMarkdown": .string("# Should not create"),
                ]))
            } catch { threw = true }
            try expect(threw, "bodyMarkdown on non-body entity must fail")
            try expect(await fake.created.isEmpty, "must fail before row creation")
        }
    }

    await test("registry_create reports explicit partial failure when body write fails") {
        let fake = ModFakeGateway(schema: skillsSchema())
        await fake.setFailMarkdownWrite(true)
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Body Fails")]),
                "bodyMarkdown": .string("# Missing body"),
            ]))
            try expect(obj(out)["created"] == .bool(false), "partial failure must not be success")
            try expect(obj(out)["partialFailure"] == .bool(true), "partial failure flag")
            try expect(obj(out)["reason"] == .string("body_write_failed"), "structured reason")
            try expect(await fake.created.count == 1, "row was created before body failed")
        }
    }

    await test("registry_create idempotencyKey prevents duplicate create on retry") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let args: Value = .object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Retry Safe")]),
                "bodyMarkdown": .string("# Same body"),
                "idempotencyKey": .string("approved-proposal-123"),
            ])
            let first = try await RegistryModule.makeCreate().handler(args)
            let second = try await RegistryModule.makeCreate().handler(args)
            try expect(obj(first)["created"] == .bool(true), "first creates")
            try expect(obj(second)["created"] == .bool(false), "retry returns existing")
            try expect(obj(second)["idempotentReplay"] == .bool(true), "replay flagged")
            try expect(await fake.created.count == 1, "no duplicate row create")
            try expect(await fake.markdownWrites.count == 1, "no duplicate body write after successful replay")
        }
    }

    await test("registry_create rejects oversized bodyMarkdown before row creation") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let tooLarge = String(repeating: "x", count: RegistryModule.maxBodyMarkdownCharacters + 1)
            var threw = false
            do {
                _ = try await RegistryModule.makeCreate().handler(.object([
                    "entity": .string("skill"),
                    "fields": .object(["name": .string("Too Large")]),
                    "bodyMarkdown": .string(tooLarge),
                ]))
            } catch { threw = true }
            try expect(threw, "oversized body must fail")
            try expect(await fake.created.isEmpty, "oversized body must fail before create")
        }
    }

    await test("registry_create schema exposes bodyMarkdown and idempotencyKey") {
        let reg = RegistryModule.makeCreate()
        let schema = obj(reg.inputSchema)
        let props = obj(schema["properties"] ?? .null)
        try expect(props["bodyMarkdown"] != nil, "bodyMarkdown discoverable")
        try expect(props["idempotencyKey"] != nil, "idempotencyKey discoverable")
        try expect(reg.description.contains("bodyMarkdown initializes"), "description explains body behavior")
        try expect(reg.description.contains("Max 100000"), "description documents max payload size")
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
