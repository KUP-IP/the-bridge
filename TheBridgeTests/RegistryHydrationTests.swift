// RegistryHydrationTests.swift — Packet Runner v1 · packet-registry-v1 (FR-1/§8.3)
// TheBridge · Tests
//
// Hermetic (fake gateway + temp home) coverage for the one-hop hydration
// envelope: primary (relations excluded) + body + curated relation projections
// + provenance + unresolved-relation warnings. Exercises the PRD §10.4 checklist:
// missing relations, inaccessible relations, stale/offline cache, no recursive
// hydration, explicit deeper body fetch.

import Foundation
import MCP
import TheBridgeLib

// 32-hex dashless Notion ids (the fake normalizes via CachedRow.normalize).
private let pktID  = "aaaa1111aaaa1111aaaa1111aaaa1111"
private let projID = "bbbb2222bbbb2222bbbb2222bbbb2222"
private let sk1ID  = "cccc3333cccc3333cccc3333cccc3333"
private let sk2ID  = "dddd4444dddd4444dddd4444dddd4444"
private let depID  = "eeee5555eeee5555eeee5555eeee5555"
private let deepID = "ffff6666ffff6666ffff6666ffff6666"

private actor HydrationGateway: RegistryNotionGateway {
    var pages: [String: NotionRow] = [:]
    var inaccessible: Set<String> = []
    var failNetwork = false
    private(set) var pageCalls = 0
    private(set) var markdownCalls = 0

    func put(_ r: NotionRow) { pages[CachedRow.normalize(r.id)] = r }
    func setInaccessible(_ ids: [String]) { inaccessible = Set(ids.map { CachedRow.normalize($0) }) }
    func setFail(_ v: Bool) { failNetwork = v }

    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema { DataSourceSchema(columnsByName: [:]) }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) { ([], nil) }
    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        pageCalls += 1
        let n = CachedRow.normalize(pageId)
        if failNetwork { throw Err.offline }
        if inaccessible.contains(n) { throw Err.forbidden }
        guard let r = pages[n] else { throw Err.notFound }
        return r
    }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow { throw Err.notFound }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow { throw Err.notFound }
    func archive(pageId: String, workspace: String?) async throws {}
    func markdown(pageId: String, workspace: String?) async throws -> String {
        markdownCalls += 1
        if failNetwork { throw Err.offline }
        return "# packet body \(pageId)"
    }
    enum Err: Error { case offline, notFound, forbidden }
}

private func packetEntity(hasBody: Bool = true) -> RegistryEntity {
    RegistryEntity(
        key: "packet", displayName: "Packets", dataSourceId: "ds_packets", workspace: nil,
        properties: [
            RegistryProperty(key: "title", notionName: "Packet Name", notionPropertyId: "p_title", type: "title", role: .title),
            RegistryProperty(key: "status", notionName: "Status", notionPropertyId: "p_status", type: "status", role: .status),
            RegistryProperty(key: "executionClass", notionName: "Execution Class", notionPropertyId: "p_xc", type: "select"),
            RegistryProperty(key: "project", notionName: "PROJECT", notionPropertyId: "p_proj", type: "relation", role: .relation),
            RegistryProperty(key: "skills", notionName: "SKILLS", notionPropertyId: "p_skills", type: "relation", role: .relation),
            RegistryProperty(key: "blockedBy", notionName: "Blocked by", notionPropertyId: "p_bb", type: "relation", role: .relation),
            RegistryProperty(key: "blocking", notionName: "Blocking", notionPropertyId: "p_bl", type: "relation", role: .relation),
            RegistryProperty(key: "event", notionName: "EVENT", notionPropertyId: "p_evt", type: "relation", role: .relation),
        ],
        cacheTTLSeconds: 3600, hasBody: hasBody)
}

private func packetRow(id: String, title: String, project: [String] = [], skills: [String] = [],
                       blockedBy: [String] = [], edited: String = "2026-06-20T10:00:00.000Z") -> NotionRow {
    func rel(_ pid: String, _ ids: [String]) -> NotionCell { NotionCell(id: pid, type: "relation", value: .array(ids.map { .string($0) })) }
    return NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: edited, cells: [
        "Packet Name": NotionCell(id: "p_title", type: "title", value: .string(title)),
        "Status": NotionCell(id: "p_status", type: "status", value: .string("QUEUE")),
        "Execution Class": NotionCell(id: "p_xc", type: "select", value: .string("AUTO")),
        "PROJECT": rel("p_proj", project),
        "SKILLS": rel("p_skills", skills),
        "Blocked by": rel("p_bb", blockedBy),
        "Blocking": rel("p_bl", []),
        "EVENT": rel("p_evt", []),
    ])
}

private func targetRow(id: String, title: String, status: String, version: String? = nil, extraRelation: String? = nil) -> NotionRow {
    var cells: [String: NotionCell] = [
        "Name": NotionCell(id: "t_title", type: "title", value: .string(title)),
        "Status": NotionCell(id: "t_status", type: "status", value: .string(status)),
    ]
    if let v = version { cells["Version"] = NotionCell(id: "t_ver", type: "rich_text", value: .string(v)) }
    // A relation cell on the TARGET — proves hydrate never follows a second hop.
    if let e = extraRelation { cells["Sub"] = NotionCell(id: "t_sub", type: "relation", value: .array([.string(e)])) }
    return NotionRow(id: CachedRow.normalize(id), url: "https://n/\(id)", lastEditedTime: "t", cells: cells)
}

private func withTempHomeHydrate(_ body: () async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-reghydrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? FileManager.default.removeItem(at: tmp) }
    try await body()
}

func runRegistryHydrationTests() async {
    print("\n\u{1F9EA} Packet Runner — registry hydration (packet-registry-v1 / §8.3)")

    await test("Hydrate/shape: packet → packet-registry-v1 envelope (primary+body+relations+provenance)") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "Build X", project: [projID], skills: [sk1ID, sk2ID], blockedBy: [depID]))
            await gw.put(targetRow(id: projID, title: "Project Alpha", status: "Active"))
            await gw.put(targetRow(id: sk1ID, title: "executor", status: "Stable", version: "8.1.0"))
            await gw.put(targetRow(id: sk2ID, title: "orchestrator", status: "Stable", version: "7.1.0"))
            await gw.put(targetRow(id: depID, title: "Dep packet", status: "DONE"))
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(), pageId: pktID)
            guard case .object(let o) = env.asValue() else { throw TestError.assertion("not object") }
            try expect(o["schemaVersion"] == .string("packet-registry-v1"), "schemaVersion literal")
            guard case .object(let prim)? = o["primary"] else { throw TestError.assertion("no primary") }
            try expect(prim["title"] == .string("Build X"), "primary title")
            try expect(prim["lastEditedTime"] == .string("2026-06-20T10:00:00.000Z"), "lastEditedTime carried")
            try expect(prim["id"] == .string("aaaa1111-aaaa-1111-aaaa-1111aaaa1111"), "primary id rendered dashed-canonical")
            guard case .object(let pp)? = prim["properties"] else { throw TestError.assertion("no props") }
            try expect(pp["status"] == .string("QUEUE") && pp["executionClass"] == .string("AUTO"), "non-relation props present")
            try expect(pp["project"] == nil && pp["skills"] == nil && pp["title"] == nil, "relations + title excluded from primary.properties")
            try expect(o["body"] == .string("# packet body \(pktID)"), "primary body loaded")
            guard case .object(let rel)? = o["relations"] else { throw TestError.assertion("no relations") }
            for slot in ["project", "skills", "blockedBy", "blocking", "event"] { try expect(rel[slot] != nil, "slot \(slot) present") }
            if case .array(let p)? = rel["project"], case .object(let p0) = p.first {
                try expect(p0["title"] == .string("Project Alpha") && p0["status"] == .string("Active"), "project → {title,status}")
            } else { throw TestError.assertion("project item missing") }
            if case .array(let s)? = rel["skills"] {
                try expect(s.count == 2, "two skills, got \(s.count)")
                if case .object(let s0) = s.first {
                    try expect(s0["name"] == .string("executor") && s0["version"] == .string("8.1.0") && s0["status"] == .string("Stable"), "skill → {name,version,status}")
                }
            } else { throw TestError.assertion("skills missing") }
            try expect(rel["blocking"] == .array([]) && rel["event"] == .array([]), "absent relations are empty arrays")
            guard case .object(let prov)? = o["provenance"] else { throw TestError.assertion("no provenance") }
            try expect(prov["source"] == .string("notion"), "provenance source=notion")
            if case .string(let f)? = prov["fetchedAt"] { try expect(!f.isEmpty, "fetchedAt stamped") } else { throw TestError.assertion("no fetchedAt") }
            try expect(env.warnings.isEmpty, "no warnings on the happy path")
        }
    }

    await test("Hydrate/missing: a relation id with no page is omitted + warned (never guessed)") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P", project: [projID]))   // projID page NOT put
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(), pageId: pktID)
            try expect(env.relations["project"]?.isEmpty ?? true, "missing project omitted (no guessed row)")
            try expect(env.warnings.count == 1 && env.warnings[0].contains(projID), "exactly one warning naming the missing id")
        }
    }

    await test("Hydrate/inaccessible: a throwing target AND an archived target are both omitted + warned") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P", project: [projID], blockedBy: [depID]))
            await gw.setInaccessible([projID])                                   // throws (forbidden)
            await gw.put(NotionRow(id: CachedRow.normalize(depID), url: "u", lastEditedTime: "t", cells: [:], archived: true))  // archived
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(), pageId: pktID)
            try expect((env.relations["project"]?.isEmpty ?? true) && (env.relations["blockedBy"]?.isEmpty ?? true), "both omitted")
            try expect(env.warnings.count == 2, "two warnings (inaccessible + archived), got \(env.warnings.count)")
        }
    }

    await test("Hydrate/offline: a warm primary still hydrates from cache when the network is down") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "Warm", project: []))
            let reader = RegistryReader(gateway: gw, cache: RegistryRowCache())
            _ = try await reader.hydrate(entity: packetEntity(), pageId: pktID)   // warm the cache
            await gw.setFail(true)
            let env = try await reader.hydrate(entity: packetEntity(), pageId: pktID)  // offline → cached primary
            guard case .object(let o) = env.asValue(), case .object(let prim)? = o["primary"] else { throw TestError.assertion("no primary") }
            try expect(prim["title"] == .string("Warm"), "primary served from cache offline")
            try expect(o["schemaVersion"] == .string("packet-registry-v1"), "valid envelope offline")
        }
    }

    await test("Hydrate/one-hop: primary + each DISTINCT relation fetched once; no second hop") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P", project: [projID], skills: [sk1ID, sk1ID]))  // sk1 listed twice → dedup
            await gw.put(targetRow(id: projID, title: "Proj", status: "Active", extraRelation: deepID)) // target has its own relation
            await gw.put(targetRow(id: sk1ID, title: "skill", status: "Stable", version: "1"))
            await gw.put(targetRow(id: deepID, title: "DEEP", status: "x"))      // must never be fetched
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(), pageId: pktID, forceRefresh: true)
            let calls = await gw.pageCalls
            try expect(calls == 3, "primary(1) + project(1) + skill(1, deduped) = 3, got \(calls)")
            // The project item carries no nested relations/body (one hop, projection only).
            if case .object(let p0)? = env.relations["project"]?.first {
                try expect(p0["relations"] == nil && p0["body"] == nil && p0["Sub"] == nil, "relation item has no nested hop/body")
            } else { throw TestError.assertion("project item missing") }
        }
    }

    await test("Hydrate/deeper: relation bodies are NOT loaded; a deeper body needs an explicit possess") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P", project: [projID]))
            await gw.put(targetRow(id: projID, title: "Proj", status: "Active"))
            let reader = RegistryReader(gateway: gw, cache: RegistryRowCache())
            _ = try await reader.hydrate(entity: packetEntity(), pageId: pktID, forceRefresh: true)
            try expect(await gw.markdownCalls == 1, "only the primary body fetched, got \(await gw.markdownCalls)")
            let body = try await reader.body(entity: packetEntity(), pageId: projID)   // explicit deeper read
            try expect(body.contains("packet body"), "explicit deeper body fetch returns markdown")
            try expect(await gw.markdownCalls == 2, "the deeper body was a separate, explicit call")
        }
    }

    await test("Hydrate/body-gate: a body-less entity yields empty body + no markdown call") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P"))
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(hasBody: false), pageId: pktID, forceRefresh: true)
            try expect(env.body.isEmpty, "no body for a body-less entity")
            try expect(await gw.markdownCalls == 0, "markdown never called")
        }
    }

    await test("Hydrate/fail-closed: a target with no status omits status (never guessed)") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "P", project: [projID]))
            await gw.put(NotionRow(id: CachedRow.normalize(projID), url: "u", lastEditedTime: "t",
                cells: ["Name": NotionCell(id: "t_title", type: "title", value: .string("No-Status Project"))]))  // no Status cell
            let env = try await RegistryReader(gateway: gw, cache: RegistryRowCache()).hydrate(entity: packetEntity(), pageId: pktID)
            guard case .object(let p0)? = env.relations["project"]?.first else { throw TestError.assertion("project item missing") }
            try expect(p0["title"] == .string("No-Status Project"), "title still projected")
            try expect(p0["status"] == nil, "status omitted, not guessed")
            try expect(env.warnings.isEmpty, "a present-but-statusless target is not a warning")
        }
    }

    await test("Hydrate/module: registry_hydrate tool returns the envelope via the MCP surface") {
        try await withTempHomeHydrate {
            let gw = HydrationGateway()
            await gw.put(packetRow(id: pktID, title: "Tool Path", project: [projID]))
            await gw.put(targetRow(id: projID, title: "Proj", status: "Active"))
            let prior = RegistryModule.gatewayProvider
            RegistryModule.gatewayProvider = { gw }
            defer { RegistryModule.gatewayProvider = prior }
            // Register the packet entity (UNBOUND — projection falls back to name match).
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("packet"), "displayName": .string("Packets"), "dataSourceId": .string("ds_packets"), "hasBody": .bool(true),
                "properties": .array([
                    .object(["key": .string("title"), "notionName": .string("Packet Name"), "type": .string("title"), "role": .string("title")]),
                    .object(["key": .string("status"), "notionName": .string("Status"), "type": .string("status"), "role": .string("status")]),
                    .object(["key": .string("executionClass"), "notionName": .string("Execution Class"), "type": .string("select")]),
                    .object(["key": .string("project"), "notionName": .string("PROJECT"), "type": .string("relation"), "role": .string("relation")]),
                    .object(["key": .string("skills"), "notionName": .string("SKILLS"), "type": .string("relation"), "role": .string("relation")]),
                    .object(["key": .string("blockedBy"), "notionName": .string("Blocked by"), "type": .string("relation"), "role": .string("relation")]),
                    .object(["key": .string("blocking"), "notionName": .string("Blocking"), "type": .string("relation"), "role": .string("relation")]),
                    .object(["key": .string("event"), "notionName": .string("EVENT"), "type": .string("relation"), "role": .string("relation")]),
                ]),
            ]))
            let out = try await RegistryModule.makeHydrate().handler(.object(["entity": .string("packet"), "id": .string(pktID)]))
            guard case .object(let o) = out else { throw TestError.assertion("not object") }
            try expect(o["schemaVersion"] == .string("packet-registry-v1"), "tool emits the envelope")
            if case .object(let rel)? = o["relations"], case .array(let p)? = rel["project"], case .object(let p0) = p.first {
                try expect(p0["title"] == .string("Proj"), "tool path projects the relation")
            } else { throw TestError.assertion("relation projection missing via tool") }
        }
    }

    await test("Hydrate/unknown-entity: registry_hydrate on an unconfigured entity throws") {
        try await withTempHomeHydrate {
            var threw = false
            do { _ = try await RegistryModule.makeHydrate().handler(.object(["entity": .string("nope"), "id": .string(pktID)])) }
            catch { threw = true }
            try expect(threw, "unknown entity surfaces an invalid-arguments error")
        }
    }
}
