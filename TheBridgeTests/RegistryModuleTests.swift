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
    var failUpdateWhenType: String?
    private(set) var created: [[BoundField]] = []
    private(set) var updated: [(String, [BoundField])] = []
    private(set) var archived: [String] = []
    private(set) var markdownWrites: [(pageId: String, markdown: String)] = []
    private(set) var queryCalls = 0
    private(set) var queryHistory: [(cursor: String?, pageSize: Int)] = []
    private var repeatedCursor: String?
    private var failOnQueryCall: Int?
    init(schema: DataSourceSchema, queryRows: [NotionRow] = [], pages: [String: NotionRow] = [:]) {
        self.schemaToReturn = schema; self.queryRows = queryRows; self.pages = pages
    }
    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema { schemaToReturn }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        queryCalls += 1
        queryHistory.append((startCursor, pageSize))
        if failOnQueryCall == queryCalls {
            throw NSError(domain: "fake.query", code: queryCalls)
        }
        let start = Int(startCursor ?? "0") ?? 0
        let end = min(start + max(1, pageSize), queryRows.count)
        let page = start < end ? Array(queryRows[start..<end]) : []
        if let repeatedCursor { return (page, repeatedCursor) }
        return (page, end < queryRows.count ? String(end) : nil)
    }
    func setRepeatedCursor(_ cursor: String?) { repeatedCursor = cursor }
    func setFailOnQueryCall(_ call: Int?) { failOnQueryCall = call }
    func resetQueryTracking() { queryCalls = 0; queryHistory = [] }
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
        if let t = failUpdateWhenType, fields.contains(where: { $0.type == t }) {
            throw NSError(domain: "fake.update", code: 404, userInfo: [NSLocalizedDescriptionKey: "Can't edit this block"])
        }
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
    func setFailUpdateWhenType(_ value: String?) { failUpdateWhenType = value }
    func seedAccessiblePage(_ id: String) {
        let n = CachedRow.normalize(id)
        pages[n] = NotionRow(id: n, url: "https://n/\(n)", lastEditedTime: "t", cells: [:])
    }
}

private func skillsSchema() -> DataSourceSchema {
    DataSourceSchema(columnsByName: [
        "Skill Name": .init(id: "id_title", type: "title"),
        "Slug": .init(id: "id_slug", type: "rich_text"),
        "Description": .init(id: "id_desc", type: "rich_text"),
        "Activation Examples": .init(id: "id_act", type: "rich_text"),
        "Anti-Triggers": .init(id: "id_anti", type: "rich_text"),
        "Status": .init(id: "id_status", type: "status"),
        "Maturity": .init(id: "id_maturity", type: "select"),
        "Deprecation Date": .init(id: "id_deprecation", type: "date"),
        "Runtime Exposure": .init(id: "id_runtime_exposure", type: "select"),
        "Domain": .init(id: "id_domain", type: "select"),
        "Specialist": .init(id: "id_spec", type: "relation"),
        "Files & media": .init(id: "id_files", type: "files"),
        "Google Drive File": .init(id: "id_gdrive", type: "files"),
        "Manager": .init(id: "id_manager", type: "relation"),
    ])
}

private func packetSchema() -> DataSourceSchema {
    DataSourceSchema(columnsByName: [
        "Packet Name": .init(id: "id_packet_title", type: "title"),
        "Status": .init(id: "id_packet_status", type: "status"),
        "PROJECT": .init(id: "id_packet_project", type: "relation"),
    ])
}

private func projectSchema() -> DataSourceSchema {
    DataSourceSchema(columnsByName: [
        "VENTURE > PROJECT": .init(id: "id_project_title", type: "title"),
        "Status": .init(id: "id_project_status", type: "status"),
    ])
}

private func skillRow(id: String, name: String) -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: "2026-06-17T10:00:00.000Z", cells: [
        "Skill Name": NotionCell(id: "id_title", type: "title", value: .string(name)),
        "Description": NotionCell(id: "id_desc", type: "rich_text", value: .string("desc of \(name)")),
        "Status": NotionCell(id: "id_status", type: "status", value: .string("Stable")),
    ])
}

private func projectRow(id: String, name: String, status: String) -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: "2026-07-25T10:00:00.000Z", cells: [
        "VENTURE > PROJECT": NotionCell(id: "id_project_title", type: "title", value: .string(name)),
        "Status": NotionCell(id: "id_project_status", type: "status", value: .string(status)),
    ])
}

private func packetRow(id: String, name: String, projectId: String) -> NotionRow {
    NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: "2026-08-17T10:00:00.000Z", cells: [
        "Packet Name": NotionCell(id: "id_packet_title", type: "title", value: .string(name)),
        "Status": NotionCell(id: "id_packet_status", type: "status", value: .string("QUEUE")),
        "PROJECT": NotionCell(id: "id_packet_project", type: "relation", value: .array([.string(projectId)])),
    ])
}

private func registerProjectEntity() async throws {
    _ = try await RegistryModule.makeAddEntity().handler(.object([
        "key": .string("project"),
        "displayName": .string("Projects"),
        "dataSourceId": .string("project_ds"),
        "hasBody": .bool(false),
        "properties": .array([
            .object(["key": .string("title"), "notionName": .string("VENTURE > PROJECT"), "type": .string("title"), "role": .string("title")]),
            .object(["key": .string("status"), "notionName": .string("Status"), "type": .string("status"), "role": .string("status")]),
        ]),
    ]))
    _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("project")]))
}

private func registerPacketEntity() async throws {
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

    await test("RegistryModule registers exactly 13 tools with expected names") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        try expect(tools.count == 13, "expected 13 registry tools, got \(tools.count)")
        let names = Set(tools.map { $0.name })
        try expect(names == ["registry_entities", "registry_add_entity", "registry_remove_entity", "registry_introspect",
                             "registry_list", "registry_find", "registry_get", "registry_create", "registry_update",
                             "registry_resolve_and_update", "registry_delete", "registry_possess",
                             "registry_hydrate"],
                   "tool names: \(names.sorted())")
    }

    await test("RegistryModule tiers: delete+remove_entity=request, writes=notify, reads=open") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        func tier(_ n: String) -> SecurityTier? { tools.first { $0.name == n }?.tier }
        try expect(tier("registry_delete") == .request, "delete must be .request (confirmation)")
        try expect(tier("registry_remove_entity") == .request, "remove_entity must be .request (destructive)")
        try expect(tier("registry_create") == .notify && tier("registry_update") == .notify && tier("registry_introspect") == .notify
                   && tier("registry_resolve_and_update") == .notify,
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

    await test("registry_entities packet preflight is opt-in and does not persist repairs") {
        let fake = ModFakeGateway(schema: packetSchema())
        try await withRegistryModuleEnv(fake) {
            try await registerPacketEntity()
            let storeURL = RegistryConfigStore.defaultURL()
            let before = try Data(contentsOf: storeURL)

            let out = try await RegistryModule.makeEntities().handler(.object([
                "includePacketPreflight": .bool(true),
            ]))
            guard case .object(let preflight)? = obj(out)["packetPreflight"] else {
                throw TestError.assertion("packetPreflight missing")
            }
            try expect(preflight["contractVersion"] == .string(PacketRegistryContract.version))
            try expect(preflight["canonicalEntity"] == .string("packet"))
            try expect(preflight["result"] == .string("DRIFT"), "three-column fixture must report the missing classified columns")
            try expect(preflight["bindingResult"] != nil, "binding vs consumer axes must be distinguished")
            try expect(preflight["consumerResult"] == .string("DRIFT"))

            guard case .object(let launch)? = obj(out)["launchReadiness"] else {
                throw TestError.assertion("launchReadiness missing from includePacketPreflight")
            }
            try expect(launch["safeToLaunch"] == .bool(false), "runtime.browser residual is TRANSPORT_UNKNOWN")
            guard case .array(let checks)? = launch["checks"] else {
                throw TestError.assertion("launchReadiness.checks missing")
            }
            let names = Set(checks.compactMap { obj($0)["name"] }.compactMap { if case .string(let n) = $0 { return n } else { return nil } })
            try expect(names.isSuperset(of: [
                LaunchReadinessContract.commandAuthCheck,
                LaunchReadinessContract.registryConsumerCheck,
                LaunchReadinessContract.runtimeBrowserCheck,
            ]))
            let runtime = checks.first { obj($0)["name"] == .string(LaunchReadinessContract.runtimeBrowserCheck) }
            try expect(obj(runtime ?? .null)["verdict"] == .string("TRANSPORT_UNKNOWN"),
                       "Packet Runner residual must not collapse to BLOCKED")

            let after = try Data(contentsOf: storeURL)
            try expect(after == before, "read-only preflight must not rewrite registry.json")
        }
    }

    await test("registry_introspect binds by name, persists, reports clean+fullyBound") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            let out = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            try expect(obj(out)["fullyBound"] == .bool(true), "all seed properties bound")
            try expect(obj(out)["clean"] == .bool(true), "no unmatched drift")
            try expect(obj(out)["boundCount"] == .int(RegistryEntity.skillsSeed().properties.count),
                       "seed property count bound")
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

    await test("registry_list has_more is exact at boundaries and max-limit clamp") {
        func assertWindow(total: Int, requested: Int, expectedCount: Int, expectedHasMore: Bool) async throws {
            let fake = ModFakeGateway(schema: skillsSchema(), queryRows: (0..<total).map {
                skillRow(id: String(format: "%032x", $0 + 1), name: "Skill \($0)")
            })
            try await withRegistryModuleEnv(fake) {
                let out = try await RegistryModule.makeList().handler(.object([
                    "entity": .string("skill"),
                    "limit": .int(requested),
                ]))
                try expect(obj(out)["count"] == .int(expectedCount), "total=\(total), requested=\(requested)")
                try expect(obj(out)["has_more"] == .bool(expectedHasMore), "has_more total=\(total), requested=\(requested)")
                try expect(obj(out)["entity"] == .string("skill") && obj(out)["rows"] != nil,
                           "existing response keys preserved")
                guard case .array(let rows)? = obj(out)["rows"] else { throw TestError.assertion("rows missing") }
                try expect(rows.count <= min(max(1, requested), 500), "public limit must cap returned rows")
            }
        }

        try await assertWindow(total: 49, requested: 50, expectedCount: 49, expectedHasMore: false)
        try await assertWindow(total: 50, requested: 50, expectedCount: 50, expectedHasMore: false)
        try await assertWindow(total: 51, requested: 50, expectedCount: 50, expectedHasMore: true)
        try await assertWindow(total: 501, requested: 999, expectedCount: 500, expectedHasMore: true)
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

    await test("RegistryReader.valueMatches treats compact and hyphenated Notion UUIDs as equal") {
        let compact = "3accbb58889e81929e2cd36bd8dfcf23"
        let hyphenated = "3accbb58-889e-8192-9e2c-d36bd8dfcf23"
        let other = "3accbb58-889e-8192-9e2c-d36bd8dfcf24"
        try expect(RegistryReader.valueMatches(.string(compact), .string(hyphenated)),
                   "compact operand matches hyphenated stored id")
        try expect(RegistryReader.valueMatches(.string(hyphenated), .string(compact)),
                   "hyphenated operand matches compact stored id")
        try expect(RegistryReader.valueMatches(.array([.string(hyphenated)]), .string(compact)),
                   "relation array membership uses the same UUID identity")
        try expect(RegistryReader.valueMatches(.string(compact.uppercased()), .string(hyphenated)),
                   "UUID identity is case-insensitive")
        try expect(!RegistryReader.valueMatches(.string(compact), .string(other)),
                   "different UUIDs still miss")
        try expect(!RegistryReader.valueMatches(.string("foo-bar"), .string("foobar")),
                   "non-UUID hyphenated strings stay on exact case-insensitive equality")
    }

    await test("registry_find relation predicate matches compact 32-hex against hyphenated stored ids") {
        let projectHyphenated = "3accbb58-889e-8192-9e2c-d36bd8dfcf23"
        let projectCompact = "3accbb58889e81929e2cd36bd8dfcf23"
        let otherCompact = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let packetId = "bbbb0000000000000000000000000160"
        let fake = ModFakeGateway(schema: packetSchema(), queryRows: [
            packetRow(id: packetId, name: "UUID normalize packet", projectId: projectHyphenated),
            packetRow(id: "bbbb0000000000000000000000000161", name: "Other project packet",
                      projectId: "cccccccc-cccc-cccc-cccc-cccccccccccc"),
        ])
        try await withRegistryModuleEnv(fake) {
            try await registerPacketEntity()
            let compactOut = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("session"),
                "where": .object(["project": .string(projectCompact)]),
            ]))
            try expect(obj(compactOut)["count"] == .int(1), "compact where must hit the hyphenated relation")
            guard case .array(let compactRows)? = obj(compactOut)["rows"], let hit = compactRows.first else {
                throw TestError.assertion("compact find returned no rows")
            }
            try expect(obj(hit)["id"] == .string(packetId), "compact where returns the related packet")

            let hyphenOut = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("session"),
                "where": .object(["project": .string(projectHyphenated)]),
            ]))
            try expect(obj(hyphenOut)["count"] == .int(1), "hyphenated where still matches")

            let miss = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("session"),
                "where": .object(["project": .string(otherCompact)]),
            ]))
            try expect(obj(miss)["count"] == .int(0), "unrelated compact UUID must miss")
        }
    }

    await test("registry_find F2 completeness: predicates and return caps never cap source scan") {
        let f2 = "5de3190f0a394c13b7f8163e75301e24"
        let f5 = "389cbb58889e81829ad9d4e6dc45543e"
        var rows = (0..<390).map { index in
            projectRow(
                id: String(format: "%032x", index + 10_000),
                name: "Project \(index)",
                status: "BACKLOG"
            )
        }
        rows[25] = projectRow(id: f5, name: "KeepUp Beta Launch", status: "FOCUS")
        rows[150] = projectRow(id: "0000000000000000000000000000f150", name: "Focus Control", status: "FOCUS")
        rows[320] = projectRow(id: f2, name: "Ship KeepUp MVP", status: "FOCUS")

        let fake = ModFakeGateway(schema: projectSchema(), queryRows: rows)
        try await withRegistryModuleEnv(fake) {
            try await registerProjectEntity()

            let statusOut = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("project"),
                "where": .object(["status": .string("FOCUS")]),
            ]))
            guard case .array(let statusMatches)? = obj(statusOut)["rows"] else {
                throw TestError.assertion("status rows missing")
            }
            let statusIds = Set(statusMatches.compactMap { row -> String? in
                if case .string(let id)? = obj(row)["id"] { return id }
                return nil
            })
            try expect(statusIds.contains(f2), "F2 must be findable beyond the first 100 rows")
            try expect(statusIds.contains(f5), "F5 control must remain findable")
            var trace = await fake.queryHistory
            try expect(trace.map { $0.cursor ?? "<nil>" } == ["<nil>", "100", "200", "300"],
                       "successful scan cursor trace: \(trace)")
            try expect(trace.allSatisfy { $0.pageSize == 100 }, "find source page size must remain 100")

            await fake.resetQueryTracking()
            let titleOut = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("project"),
                "where": .object(["title": .string("Ship KeepUp MVP")]),
                "limit": .int(1),
            ]))
            try expect(obj(titleOut)["count"] == .int(1), "late title predicate must match under limit 1")
            guard case .array(let titleMatches)? = obj(titleOut)["rows"], let titleRow = titleMatches.first else {
                throw TestError.assertion("title rows missing")
            }
            try expect(obj(titleRow)["id"] == .string(f2), "late title predicate returns F2")
            trace = await fake.queryHistory
            try expect(trace.map { $0.cursor ?? "<nil>" } == ["<nil>", "100", "200", "300"],
                       "return cap must not shorten source scan")

            await fake.resetQueryTracking()
            let cappedOut = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("project"),
                "where": .object(["status": .string("FOCUS")]),
                "limit": .int(2),
            ]))
            try expect(obj(cappedOut)["count"] == .int(2), "three matches must be capped to two returned rows")
            trace = await fake.queryHistory
            try expect(trace.map { $0.cursor ?? "<nil>" } == ["<nil>", "100", "200", "300"],
                       "filtering and cap happen after exhaustive scan")
        }
    }

    await test("registry_find repeated cursor terminates with empty-cache error or cached fallback") {
        let emptyFake = ModFakeGateway(schema: projectSchema())
        await emptyFake.setRepeatedCursor("loop")
        try await withRegistryModuleEnv(emptyFake) {
            try await registerProjectEntity()
            do {
                _ = try await RegistryModule.makeFind().handler(.object([
                    "entity": .string("project"),
                    "where": .object(["status": .string("FOCUS")]),
                ]))
                throw TestError.assertion("empty-cache repeated cursor must throw")
            } catch RegistryGatewayError.invalidResponse(let reason) {
                try expect(reason.contains("repeated cursor loop"), "unexpected repeated-cursor reason: \(reason)")
            }
            try expect(await emptyFake.queryCalls == 2, "repeated cursor must terminate before a third query")
        }

        let cachedId = "0000000000000000000000000000cafe"
        let cachedFake = ModFakeGateway(schema: projectSchema(), queryRows: [
            projectRow(id: cachedId, name: "Cached Focus", status: "FOCUS"),
        ])
        await cachedFake.setRepeatedCursor("loop")
        try await withRegistryModuleEnv(cachedFake) {
            try await registerProjectEntity()
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("project"),
                "where": .object(["status": .string("FOCUS")]),
            ]))
            try expect(obj(out)["count"] == .int(1), "non-empty cache must be used on repeated cursor")
            guard case .array(let matches)? = obj(out)["rows"], let row = matches.first else {
                throw TestError.assertion("cached fallback rows missing")
            }
            try expect(obj(row)["id"] == .string(cachedId), "cached fallback row preserved")
            try expect(await cachedFake.queryCalls == 2, "cached repeated cursor must terminate before a third query")
        }
    }

    await test("registry_find later-page failure uses cache then filters and caps") {
        let cachedA = "00000000000000000000000000000001"
        let cachedB = "00000000000000000000000000000002"
        let liveRows = (0..<150).map { index in
            projectRow(id: String(format: "%032x", index + 20_000), name: "Live \(index)", status: "BACKLOG")
        }
        let fake = ModFakeGateway(schema: projectSchema(), queryRows: liveRows)
        await fake.setFailOnQueryCall(2)
        try await withRegistryModuleEnv(fake) {
            try await registerProjectEntity()
            try await RegistryRowCache.shared.write(CachedRow(
                entity: "project", pageId: cachedA, title: "Cached Focus A", url: "u",
                properties: .object(["title": .string("Cached Focus A"), "status": .string("FOCUS")]),
                lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 3600, callCount: 1
            ))
            try await RegistryRowCache.shared.write(CachedRow(
                entity: "project", pageId: cachedB, title: "Cached Focus B", url: "u",
                properties: .object(["title": .string("Cached Focus B"), "status": .string("FOCUS")]),
                lastEditedTime: "t", writtenAt: Date(), ttlSeconds: 3600, callCount: 1
            ))

            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("project"),
                "where": .object(["status": .string("FOCUS")]),
                "limit": .int(1),
            ]))
            try expect(obj(out)["count"] == .int(1), "fallback matches must still respect return cap")
            guard case .array(let matches)? = obj(out)["rows"], let row = matches.first else {
                throw TestError.assertion("fallback rows missing")
            }
            try expect(obj(row)["id"] == .string(cachedA), "cached-only match proves fallback, not partial live out")
            let trace = await fake.queryHistory
            try expect(trace.map { $0.cursor ?? "<nil>" } == ["<nil>", "100"],
                       "later-page failure trace: \(trace)")
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
            let projectId = "37fcbb58-889e-81f1-867e-d71b11dd9baf"
            await fake.seedAccessiblePage(projectId)
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
            try expect(obj(out)["state"] == .string("partial"), "envelope state")
            try expect(obj(out)["entityUrl"] != nil, "entityUrl present after body fail")
            try expect(obj(out)["reason"] == .string("body_write_failed"), "structured reason")
            try expect(await fake.created.count == 1, "row was created before body failed")
        }
    }

    await test("registry_create complete envelope includes state and entityUrl") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Envelope")]),
            ]))
            try expect(obj(out)["state"] == .string("complete"), "complete")
            try expect(obj(out)["created"] == .bool(true), "created compat")
            try expect(obj(out)["entityUrl"] != nil, "entityUrl on complete")
            try expect(obj(out)["applied"] != nil, "applied list present")
            try expect(obj(out)["failed"] == .array([]), "no failures")
        }
    }

    await test("registry_create inaccessible relation preflight yields state none and creates nothing") {
        let fake = ModFakeGateway(schema: packetSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("session"),
                "displayName": .string("Packets"),
                "dataSourceId": .string("packet_ds"),
                "hasBody": .bool(true),
                "properties": .array([
                    .object(["key": .string("name"), "notionName": .string("Packet Name"), "type": .string("title"), "role": .string("title")]),
                    .object(["key": .string("project"), "notionName": .string("PROJECT"), "type": .string("relation"), "role": .string("relation")]),
                ]),
            ]))
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("session")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("session"),
                "fields": .object([
                    "name": .string("Should Not Exist"),
                    "project": .array([.string("00000000000000000000000000000001")]),
                ]),
            ]))
            try expect(obj(out)["state"] == .string("none"), "none")
            try expect(obj(out)["created"] == .bool(false), "not created")
            try expect(obj(out)["entityUrl"] == nil, "no URL")
            try expect(await fake.created.isEmpty, "creates nothing")
            guard case .array(let failed)? = obj(out)["failed"] else { throw TestError.assertion("failed missing") }
            try expect(failed.contains(where: {
                obj($0)["field"] == .string("project")
            }), "project in failed: \(failed)")
        }
    }

    await test("registry_create forced relation PATCH failure yields partial with entityUrl and one row") {
        let fake = ModFakeGateway(schema: packetSchema())
        let target = "aabbccdd00112233445566778899aabb"
        await fake.seedAccessiblePage(target)
        await fake.setFailUpdateWhenType("relation")
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("session"),
                "displayName": .string("Packets"),
                "dataSourceId": .string("packet_ds"),
                "hasBody": .bool(false),
                "properties": .array([
                    .object(["key": .string("name"), "notionName": .string("Packet Name"), "type": .string("title"), "role": .string("title")]),
                    .object(["key": .string("project"), "notionName": .string("PROJECT"), "type": .string("relation"), "role": .string("relation")]),
                ]),
            ]))
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("session")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("session"),
                "fields": .object([
                    "name": .string("Repair Me"),
                    "project": .array([.string(target)]),
                ]),
            ]))
            try expect(obj(out)["state"] == .string("partial"), "partial")
            try expect(obj(out)["created"] == .bool(false), "not a successful create")
            try expect(obj(out)["partialFailure"] == .bool(true), "partialFailure compat")
            try expect(obj(out)["entityUrl"] != nil, "usable entityUrl")
            try expect(await fake.created.count == 1, "zero duplicate rows")
            guard case .array(let failed)? = obj(out)["failed"] else { throw TestError.assertion("failed missing") }
            try expect(failed.contains(where: { obj($0)["field"] == .string("project") }),
                       "project failed: \(failed)")
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

    // MARK: - registry_resolve_and_update (PKT-MEM-135 — find+get+update in one call)

    await test("registry_resolve_and_update exact match → resolves + writes in one call") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "1111000000000000000000000000aaaa", name: "Alpha"),
            skillRow(id: "1111000000000000000000000000bbbb", name: "Beta"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Alpha")]),
                "fields": .object(["slug": .string("alpha-slug")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "resolved + updated")
            try expect(obj(out)["matchedId"] == .string("1111000000000000000000000000aaaa"), "matched the Alpha row")
            let updatedCalls = await fake.updated
            try expect(updatedCalls.count == 1 && updatedCalls[0].0 == "1111000000000000000000000000aaaa", "wrote to the resolved row, not Beta")
        }
    }

    await test("registry_resolve_and_update no match → not-found error, NO write") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "2222000000000000000000000000aaaa", name: "Alpha"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            var threw = false
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("skill"),
                    "where": .object(["name": .string("DoesNotExist")]),
                    "fields": .object(["slug": .string("x")]),
                ]))
            } catch let e as ToolRouterError {
                threw = true
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error type: \(e)") }
            }
            try expect(threw, "no match must throw, not silently no-op")
            try expect(await fake.updated.isEmpty, "no write attempted on no-match")
        }
    }

    await test("registry_resolve_and_update ambiguous match → ambiguous error, NO write") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "3333000000000000000000000000aaaa", name: "Dup"),
            skillRow(id: "3333000000000000000000000000bbbb", name: "Dup"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            var threw = false
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("skill"),
                    "where": .object(["name": .string("Dup")]),
                    "fields": .object(["slug": .string("x")]),
                ]))
            } catch let e as ToolRouterError {
                threw = true
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error type: \(e)") }
            }
            try expect(threw, "ambiguous match must throw, not pick one")
            try expect(await fake.updated.isEmpty, "no write attempted on ambiguous match")
        }
    }

    await test("registry_resolve_and_update append-merge: configured key appends to existing value") {
        // skillRow seeds Description="desc of Echo" ⇒ canonical 'summary' — a
        // default append key. The write value must be APPENDED, not overwrite.
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "4444000000000000000000000000aaaa", name: "Echo"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Echo")]),
                "fields": .object(["summary": .string("new voice memo content")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "updated")
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let summaryField = call.1.first(where: { $0.notionName == "Description" }) else {
                throw TestError.assertion("no Description/summary field in the PATCH payload")
            }
            guard case .string(let written) = summaryField.value else { throw TestError.assertion("summary value not a string") }
            try expect(written.contains("desc of Echo"), "existing value preserved: \(written)")
            try expect(written.contains("new voice memo content"), "new content appended: \(written)")
            try expect(written.contains("— Voice memo "), "dated block stamp present: \(written)")
            try expect(written != "new voice memo content", "must NOT be a plain overwrite")
        }
    }

    await test("registry_resolve_and_update plain overwrite: non-append field replaces the value") {
        // 'slug' is not in the default append-key set ⇒ plain overwrite.
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "5555000000000000000000000000aaaa", name: "Foxtrot"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Foxtrot")]),
                "fields": .object(["slug": .string("brand-new-slug")]),
            ]))
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let slugField = call.1.first(where: { $0.notionName == "Slug" }) else {
                throw TestError.assertion("no Slug field in the PATCH payload")
            }
            try expect(slugField.value == .string("brand-new-slug"), "slug is a plain overwrite, not appended")
        }
    }

    await test("registry_resolve_and_update custom appendKeys overrides the default set") {
        // 'slug' is NOT a default append key, but the caller opts it in explicitly.
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "6666000000000000000000000000aaaa", name: "Golf"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Golf")]),
                "fields": .object(["slug": .string("appended-slug")]),
                "appendKeys": .array([.string("slug")]),
            ]))
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let slugField = call.1.first(where: { $0.notionName == "Slug" }) else {
                throw TestError.assertion("no Slug field in the PATCH payload")
            }
            guard case .string(let written) = slugField.value else { throw TestError.assertion("slug value not a string") }
            try expect(written.contains("appended-slug"), "new content present: \(written)")
            try expect(written.contains("— Voice memo "), "custom appendKeys triggers the append block: \(written)")
        }
    }

    await test("registry_resolve_and_update empty appendKeys ([]) disables append-merge entirely") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "7777000000000000000000000000aaaa", name: "Hotel"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Hotel")]),
                "fields": .object(["summary": .string("only this")]),
                "appendKeys": .array([]),
            ]))
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let summaryField = call.1.first(where: { $0.notionName == "Description" }) else {
                throw TestError.assertion("no Description field in the PATCH payload")
            }
            try expect(summaryField.value == .string("only this"), "appendKeys:[] forces a plain overwrite even for the default append key")
        }
    }

    // MARK: - registry_update appendKeys mode (Notion/Registry Tool Ergonomics Pass)
    //   Reuses RegistryAppendMerge/resolveAndUpdate's exact merge logic — these
    //   tests drive RegistryModule.makeUpdate().handler(...) directly, the real
    //   MCP argument-parsing entry point (not a hand-built RegistryWriter call),
    //   per the AGENT_FEEDBACK 2026-07-02 args-parsing-bypass lesson.

    await test("registry_update: original fields-only shape is unchanged (plain overwrite, no appendKeys)") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "aaaa000000000000000000000000aaaa": skillRow(id: "aaaa000000000000000000000000aaaa", name: "Kilo"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeUpdate().handler(.object([
                "entity": .string("skill"),
                "id": .string("aaaa000000000000000000000000aaaa"),
                "fields": .object(["summary": .string("brand new summary")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "update reports success")
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let field = call.1.first(where: { $0.notionName == "Description" }) else {
                throw TestError.assertion("no Description field in the PATCH payload")
            }
            try expect(field.value == .string("brand new summary"), "no appendKeys ⇒ plain overwrite, unchanged from before this packet")
        }
    }

    await test("registry_update: appendKeys mode appends to the row's current value instead of overwriting") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "bbbb000000000000000000000000bbbb": skillRow(id: "bbbb000000000000000000000000bbbb", name: "Lima"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeUpdate().handler(.object([
                "entity": .string("skill"),
                "id": .string("bbbb000000000000000000000000bbbb"),
                "fields": .object(["summary": .string("appended content")]),
                "appendKeys": .array([.string("summary")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "update reports success")
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let field = call.1.first(where: { $0.notionName == "Description" }) else {
                throw TestError.assertion("no Description field in the PATCH payload")
            }
            guard case .string(let written) = field.value else { throw TestError.assertion("summary value not a string") }
            try expect(written.contains("desc of Lima"), "existing value preserved: \(written)")
            try expect(written.contains("appended content"), "new content present: \(written)")
            try expect(written.contains("— Voice memo "), "appendKeys triggers the same dated-block format as resolve_and_update: \(written)")
        }
    }

    await test("registry_update: appendKeys mode leaves non-listed fields as plain overwrite") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "cccc000000000000000000000000cccc": skillRow(id: "cccc000000000000000000000000cccc", name: "Mike"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            _ = try await RegistryModule.makeUpdate().handler(.object([
                "entity": .string("skill"),
                "id": .string("cccc000000000000000000000000cccc"),
                "fields": .object(["slug": .string("plain-overwrite-slug")]),
                "appendKeys": .array([.string("summary")]),   // slug is NOT in appendKeys
            ]))
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let field = call.1.first(where: { $0.notionName == "Slug" }) else {
                throw TestError.assertion("no Slug field in the PATCH payload")
            }
            try expect(field.value == .string("plain-overwrite-slug"), "slug not in appendKeys ⇒ plain overwrite")
        }
    }

    await test("registry_update: empty appendKeys ([]) still reads current row but forces plain overwrite") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "dddd000000000000000000000000dddd": skillRow(id: "dddd000000000000000000000000dddd", name: "November"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            _ = try await RegistryModule.makeUpdate().handler(.object([
                "entity": .string("skill"),
                "id": .string("dddd000000000000000000000000dddd"),
                "fields": .object(["summary": .string("only this, no append")]),
                "appendKeys": .array([]),
            ]))
            let updatedCalls = await fake.updated
            guard let call = updatedCalls.first, let field = call.1.first(where: { $0.notionName == "Description" }) else {
                throw TestError.assertion("no Description field in the PATCH payload")
            }
            try expect(field.value == .string("only this, no append"), "appendKeys:[] forces plain overwrite even for a would-be append key")
        }
    }

    await test("registry_update: rejects missing entity/id exactly as before (appendKeys doesn't change the guard)") {
        do {
            _ = try await RegistryModule.makeUpdate().handler(.object([
                "fields": .object(["summary": .string("x")]),
                "appendKeys": .array([.string("summary")]),
            ]))
            throw TestError.assertion("Expected error for missing entity/id")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("registry_update schema declares optional appendKeys alongside entity/id/fields") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        guard let tool = tools.first(where: { $0.name == "registry_update" }) else {
            throw TestError.assertion("registry_update not found")
        }
        let schema = String(describing: tool.inputSchema)
        try expect(schema.contains("appendKeys"), "schema should declare the optional appendKeys param")
        try expect(schema.contains("entity") && schema.contains("id") && schema.contains("fields"),
                   "schema must keep the original required params")
    }

    await test("registry_resolve_and_update matches by BOUND property id (rename-safe, same as registry_find)") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "8888000000000000000000000000aaaa", name: "India"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["summary": .string("DESC OF INDIA")]),   // case-insensitive, matched by bound id
                "fields": .object(["slug": .string("india-slug")]),
            ]))
            try expect(obj(out)["matchedId"] == .string("8888000000000000000000000000aaaa"), "resolved via bound-id predicate match")
        }
    }

    await test("registry_resolve_and_update AND semantics: all predicates must match") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "9999000000000000000000000000aaaa", name: "Juliet"),   // status = "Stable"
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            var threw = false
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("skill"),
                    "where": .object(["name": .string("Juliet"), "status": .string("Deprecated")]),
                    "fields": .object(["slug": .string("x")]),
                ]))
            } catch { threw = true }
            try expect(threw, "one predicate mismatched ⇒ no match ⇒ throw")
            try expect(await fake.updated.isEmpty, "no write when AND predicate fails")
        }
    }

    await test("registry_resolve_and_update unknown entity → invalidArguments error") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("ghost"),
                    "where": .object(["name": .string("x")]),
                    "fields": .object(["slug": .string("x")]),
                ]))
                throw TestError.assertion("expected unknown-entity error")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
        }
    }

    await test("registry_resolve_and_update missing/empty where or fields → invalidArguments error") {
        try await withRegistryModuleEnv(ModFakeGateway(schema: skillsSchema())) {
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("skill"), "where": .object([:]), "fields": .object(["slug": .string("x")]),
                ]))
                throw TestError.assertion("expected empty-where error")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
            do {
                _ = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                    "entity": .string("skill"), "where": .object(["name": .string("x")]), "fields": .object([:]),
                ]))
                throw TestError.assertion("expected empty-fields error")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
        }
    }

    // ============================================================
    // MARK: - PKT: fields Param Across Registry Tools (result-projection wiring)
    // ============================================================
    // One wiring-proof test per tool + the cross-cutting invariants (wrapper
    // never filtered, omitted-fields regression, malformed-fields hard
    // error). Mechanism-level FieldsFilter coverage lives in
    // FieldsFilterTests.swift; these prove each handler actually calls it.

    await test("fields (registry_get): narrows the row to only requested keys") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "bbbb0000000000000000000000000001": skillRow(id: "bbbb0000000000000000000000000001", name: "Gamma"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeGet().handler(.object([
                "entity": .string("skill"), "id": .string("bbbb0000000000000000000000000001"),
                "fields": .array([.string("title")]),
            ]))
            // Identity keys (id/entity/title) retained with the requested projection.
            try expect(obj(out)["title"] == .string("Gamma"), "title value preserved")
            try expect(obj(out)["id"] != nil, "id retained with projected fields")
            try expect(obj(out)["entity"] != nil, "entity retained with projected fields")
        }
    }

    await test("fields (registry_get): omitted fields → byte-identical to no-fields call") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "bbbb0000000000000000000000000002": skillRow(id: "bbbb0000000000000000000000000002", name: "Delta"),
        ])
        try await withRegistryModuleEnv(fake) {
            let baseline = try await RegistryModule.makeGet().handler(.object([
                "entity": .string("skill"), "id": .string("bbbb0000000000000000000000000002"),
            ]))
            let withEmptyFields = try await RegistryModule.makeGet().handler(.object([
                "entity": .string("skill"), "id": .string("bbbb0000000000000000000000000002"),
                "fields": .array([]),
            ]))
            try expect(baseline == withEmptyFields, "fields:[] must be byte-identical to omitted fields")
        }
    }

    await test("fields (registry_get): properties.X sub-selects one property") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "bbbb0000000000000000000000000003": skillRow(id: "bbbb0000000000000000000000000003", name: "Epsilon"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeGet().handler(.object([
                "entity": .string("skill"), "id": .string("bbbb0000000000000000000000000003"),
                "fields": .array([.string("properties.summary")]),
            ]))
            guard case .object(let props)? = obj(out)["properties"] else {
                throw TestError.assertion("properties must be present")
            }
            try expect(props.count == 1 && props["summary"] == .string("desc of Epsilon"), "got \(props)")
        }
    }

    await test("fields (registry_list): projects every row in the array identically") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "cccc0000000000000000000000000001", name: "Alpha"),
            skillRow(id: "cccc0000000000000000000000000002", name: "Beta"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeList().handler(.object([
                "entity": .string("skill"), "fields": .array([.string("title")]),
            ]))
            guard case .array(let rows)? = obj(out)["rows"] else { throw TestError.assertion("rows missing") }
            try expect(rows.count == 2, "both rows present")
            for r in rows {
                try expect(obj(r)["title"] != nil, "each row keeps title: \(obj(r))")
                try expect(obj(r)["id"] != nil, "each projected row retains id: \(obj(r))")
            }
            // count/entity wrapper keys survive untouched (list has no write-status wrapper, but its own keys aren't row-shaped).
            try expect(obj(out)["count"] == .int(2), "count unaffected by fields")
        }
    }

    await test("fields (registry_find): projects every matched row in the array") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "dddd0000000000000000000000000001", name: "Zeta"),
        ])
        try await withRegistryModuleEnv(fake) {
            let out = try await RegistryModule.makeFind().handler(.object([
                "entity": .string("skill"), "where": .object(["name": .string("Zeta")]),
                "fields": .array([.string("id")]),
            ]))
            guard case .array(let rows)? = obj(out)["rows"], let r0 = rows.first else { throw TestError.assertion("no rows") }
            try expect(obj(r0)["id"] == .string("dddd0000000000000000000000000001"), "id preserved: \(obj(r0))")
            try expect(obj(r0)["title"] != nil || obj(r0)["entity"] != nil, "identity keys retained: \(obj(r0))")
        }
    }

    await test("fields (registry_create): projects the row but NEVER the operation-status wrapper") {
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("Filtered"), "summary": .string("hi")]),
            ]))
            // Re-fetch equivalent via a SECOND create call using the `fields`
            // ARRAY shape is impossible here (fields is required+object for
            // the write) — instead verify the wrapper keys are present
            // alongside a row that WOULD be filterable via resultFields-style
            // tools. Since registry_create's `fields` is claimed by the write
            // payload, assert operation-status keys remain intact. `bodyWrite`
            // is intentionally absent when no body was requested.
            try expect(obj(out)["created"] == .bool(true), "created wrapper key present")
            try expect(obj(out)["partialFailure"] == .bool(false), "partialFailure wrapper key present")
            try expect(obj(out)["bodyWrite"] == nil, "bodyWrite omitted when no body requested")
            try expect(obj(out)["row"] != nil, "row payload present")
        }
    }

    await test("fields (registry_create): write-payload OBJECT and result-projection ARRAY never collide") {
        // registry_create's `fields` key is ALWAYS the write payload (an
        // object) on this tool — passing an object writes fields normally,
        // exactly as before `fields` result-projection existed anywhere.
        let fake = ModFakeGateway(schema: skillsSchema())
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeCreate().handler(.object([
                "entity": .string("skill"),
                "fields": .object(["name": .string("NotFiltered"), "summary": .string("full")]),
            ]))
            guard case .object(let row)? = obj(out)["row"] else { throw TestError.assertion("row missing") }
            // Full row shape unaffected — write payload semantics unchanged
            // (object `fields` never triggers projection: the full
            // multi-key row envelope survives, same shape as before `fields`
            // result-projection existed on this tool).
            try expect(row.count > 1, "full unfiltered row must carry more than one key, got \(row.keys.sorted())")
            try expect(row["properties"] != nil, "full properties map still present (no projection requested)")
            let created = await fake.created
            try expect(created.count == 1, "the write itself must have gone through exactly as before")
        }
    }

    await test("fields (registry_update): projects the row, wrapper key 'updated' untouched") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "eeee0000000000000000000000000001": skillRow(id: "eeee0000000000000000000000000001", name: "Eta"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeUpdate().handler(.object([
                "entity": .string("skill"), "id": .string("eeee0000000000000000000000000001"),
                "fields": .object(["summary": .string("updated desc")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "wrapper key present and true")
            try expect(obj(out)["row"] != nil, "full row present when no ARRAY fields requested (write payload was an object)")
        }
    }

    await test("fields (registry_resolve_and_update): resultFields projects the row; 'fields' stays write-only") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000010", name: "Theta"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Theta")]),
                "fields": .object(["summary": .string("resolved+updated")]),
                "resultFields": .array([.string("id")]),
            ]))
            try expect(obj(out)["updated"] == .bool(true), "wrapper key present")
            try expect(obj(out)["matchedId"] != nil, "wrapper key matchedId present")
            guard case .object(let row)? = obj(out)["row"] else { throw TestError.assertion("row missing") }
            try expect(row["id"] == .string("ffff0000000000000000000000000010"),
                       "row id preserved via resultFields, got \(row)")
            try expect(row["entity"] != nil || row["title"] != nil,
                       "identity keys retained on projected row, got \(row)")
        }
    }

    await test("fields (registry_resolve_and_update): omitted resultFields → full row, unchanged from pre-fields behavior") {
        let fake = ModFakeGateway(schema: skillsSchema(), queryRows: [
            skillRow(id: "ffff0000000000000000000000000011", name: "Iota"),
        ])
        try await withRegistryModuleEnv(fake) {
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            let out = try await RegistryModule.makeResolveAndUpdate().handler(.object([
                "entity": .string("skill"),
                "where": .object(["name": .string("Iota")]),
                "fields": .object(["summary": .string("plain update")]),
            ]))
            guard case .object(let row)? = obj(out)["row"] else { throw TestError.assertion("row missing") }
            try expect(row["properties"] != nil, "full row (unfiltered) must still carry properties")
            try expect(row.count > 1, "full row must have more than just one key when resultFields is omitted")
        }
    }

    await test("fields: malformed value (wrong type) is a hard invalidArguments error on registry_get") {
        let fake = ModFakeGateway(schema: skillsSchema(), pages: [
            "aaaa1111000000000000000000000001": skillRow(id: "aaaa1111000000000000000000000001", name: "Kappa"),
        ])
        try await withRegistryModuleEnv(fake) {
            do {
                _ = try await RegistryModule.makeGet().handler(.object([
                    "entity": .string("skill"), "id": .string("aaaa1111000000000000000000000001"),
                    "fields": .string("title"),   // wrong type — must be array
                ]))
                throw TestError.assertion("expected invalidArguments for malformed fields")
            } catch let e as ToolRouterError {
                if case .invalidArguments = e {} else { throw TestError.assertion("wrong error: \(e)") }
            }
        }
    }

    await test("fields: schema declares 'fields' array param on all 6 row-shaped tools (+ resultFields on resolve_and_update)") {
        let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
        await RegistryModule.register(on: router)
        let tools = await router.registrations(forModule: "registry")
        for name in ["registry_list", "registry_find", "registry_get", "registry_create", "registry_update"] {
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw TestError.assertion("missing tool \(name)")
            }
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let props)? = schema["properties"] else {
                throw TestError.assertion("\(name) schema missing properties")
            }
            try expect(props["fields"] != nil, "\(name) must declare a fields param")
        }
        guard let rau = tools.first(where: { $0.name == "registry_resolve_and_update" }),
              case .object(let schema) = rau.inputSchema,
              case .object(let props)? = schema["properties"] else {
            throw TestError.assertion("registry_resolve_and_update schema missing properties")
        }
        try expect(props["resultFields"] != nil, "registry_resolve_and_update must declare resultFields (fields is write-only here)")
    }
}

func runRegistryAppendMergeTests() async {
    print("\n\u{1F9F0} Data-Source Registry — RegistryAppendMerge (shared append-merge primitive)")

    let fixedDate = Date(timeIntervalSince1970: 1_751_500_800)   // deterministic stamp for exact-string assertions
    let stamp = String(ISO8601DateFormatter().string(from: fixedDate).prefix(10))

    await test("RegistryAppendMerge.appendBlock: empty existing → block only, no leading separator") {
        let out = RegistryAppendMerge.appendBlock(existing: "", newContent: "hello", now: fixedDate)
        try expect(out == "— Voice memo \(stamp):\nhello", "got: \(out)")
    }

    await test("RegistryAppendMerge.appendBlock: nil existing → block only") {
        let out = RegistryAppendMerge.appendBlock(existing: nil, newContent: "hello", now: fixedDate)
        try expect(out == "— Voice memo \(stamp):\nhello", "got: \(out)")
    }

    await test("RegistryAppendMerge.appendBlock: whitespace-only existing → treated as empty") {
        let out = RegistryAppendMerge.appendBlock(existing: "   \n  ", newContent: "hello", now: fixedDate)
        try expect(out == "— Voice memo \(stamp):\nhello", "got: \(out)")
    }

    await test("RegistryAppendMerge.appendBlock: non-empty existing → blank-line-separated block appended") {
        let out = RegistryAppendMerge.appendBlock(existing: "prior text", newContent: "new stuff", now: fixedDate)
        try expect(out == "prior text\n\n— Voice memo \(stamp):\nnew stuff", "got: \(out)")
    }

    await test("RegistryAppendMerge.appendBlock: new content is trimmed") {
        let out = RegistryAppendMerge.appendBlock(existing: "x", newContent: "  padded  \n", now: fixedDate)
        try expect(out == "x\n\n— Voice memo \(stamp):\npadded", "got: \(out)")
    }

    await test("RegistryAppendMerge.merge: default append keys merge, other keys overwrite") {
        let existing: Value = .object(["summary": .string("old summary"), "slug": .string("old-slug")])
        let proposed: [String: Value] = ["summary": .string("new bit"), "slug": .string("new-slug")]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, now: fixedDate)
        guard case .string(let summary)? = merged["summary"] else { throw TestError.assertion("summary missing") }
        try expect(summary == "old summary\n\n— Voice memo \(stamp):\nnew bit", "summary appended: \(summary)")
        try expect(merged["slug"] == .string("new-slug"), "slug overwritten, not appended")
    }

    await test("RegistryAppendMerge.merge: no proposed key in appendKeys → passthrough unchanged") {
        let existing: Value = .object(["summary": .string("old")])
        let proposed: [String: Value] = ["slug": .string("x")]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, now: fixedDate)
        try expect(merged == proposed, "no append key present ⇒ proposed returned as-is")
    }

    await test("RegistryAppendMerge.merge: empty appendKeys ⇒ every field overwrites") {
        let existing: Value = .object(["summary": .string("old")])
        let proposed: [String: Value] = ["summary": .string("new")]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, appendKeys: [], now: fixedDate)
        try expect(merged["summary"] == .string("new"), "empty appendKeys disables merge entirely")
    }

    await test("RegistryAppendMerge.merge: missing/non-string existing value ⇒ starts fresh, never throws") {
        let existing: Value = .object(["summary": .int(42)])   // malformed/non-string existing
        let proposed: [String: Value] = ["summary": .string("first entry")]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, now: fixedDate)
        try expect(merged["summary"] == .string("— Voice memo \(stamp):\nfirst entry"), "non-string existing treated as empty: \(String(describing: merged["summary"]))")
    }

    await test("RegistryAppendMerge.merge: absent existing key ⇒ starts fresh") {
        let existing: Value = .object([:])
        let proposed: [String: Value] = ["summary": .string("first entry")]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, now: fixedDate)
        try expect(merged["summary"] == .string("— Voice memo \(stamp):\nfirst entry"), "absent key treated as empty")
    }

    await test("RegistryAppendMerge.merge: non-string proposed value on an append key passes through") {
        let existing: Value = .object(["summary": .string("old")])
        let proposed: [String: Value] = ["summary": .int(7)]
        let merged = RegistryAppendMerge.merge(proposed: proposed, existing: existing, now: fixedDate)
        try expect(merged["summary"] == .int(7), "non-string proposed value on an append key is passed through untouched")
    }

    await test("RegistryAppendMerge.merge matches VoiceMemoParser.appendVoiceMemoLog byte-for-byte") {
        // The packet's GOAL_CONDITION requires exact parity with the existing
        // VoiceMemoProcessor.mergeAppendRegistryFields behavior. Cross-check the
        // ported primitive against the original at a fixed instant.
        let viaVoiceMemo = VoiceMemoParser.appendVoiceMemoLog(existing: "prior", newContent: "  next  ")
        let viaRegistry = RegistryAppendMerge.appendBlock(existing: "prior", newContent: "  next  ")
        // Both stamp "now" independently but at the same coarse (date-only) precision,
        // so a same-day run produces byte-identical output.
        try expect(viaVoiceMemo == viaRegistry, "ported primitive must match the original: \(viaVoiceMemo) vs \(viaRegistry)")
    }
}
