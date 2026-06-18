// DataSourcesViewModelTests.swift — Data-Source Registry (Wave 4)
// NotionBridge · Tests
//
// The Settings → "Data Sources" pane USER SCENARIOS, exercised through the
// view-model contract (the codebase tests UI at the view-model layer — cf.
// SkillManagementUIScenarioTests). Covers the Decision-5 onboarding flow
// (load → propose → review drift → confirm), per-entity TTL, cache clear, and
// error handling — PLUS back-end↔front-end ALIGNMENT: the pane's view-model and
// the registry_* MCP tools read/write the SAME config + gateway, so a binding
// made in the UI is the binding the tools see (and vice-versa).
//
// Hermetic: temp home + injected fake gateway; @MainActor view-model accessed
// via MainActor.run hops.

import Foundation
import MCP
import NotionBridgeLib

private actor VMFakeGateway: RegistryNotionGateway {
    var schemaToReturn: DataSourceSchema
    var offline = false
    init(schema: DataSourceSchema) { self.schemaToReturn = schema }
    func setOffline(_ v: Bool) { offline = v }
    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema {
        if offline { throw NSError(domain: "vmfake", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"]) }
        return schemaToReturn
    }
    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) { ([], nil) }
    func page(pageId: String, workspace: String?) async throws -> NotionRow { throw NSError(domain: "vmfake", code: 404) }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow { throw NSError(domain: "vmfake", code: 405) }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow { throw NSError(domain: "vmfake", code: 405) }
    func archive(pageId: String, workspace: String?) async throws {}
    func markdown(pageId: String, workspace: String?) async throws -> String { "" }
}

private func fullSkillsSchema() -> DataSourceSchema {
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

private func withVMEnv(_ fake: VMFakeGateway, _ body: (DataSourcesViewModel) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-dsvm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    let prior = RegistryModule.gatewayProvider
    RegistryModule.gatewayProvider = { fake }
    defer {
        RegistryModule.gatewayProvider = prior
        BridgePaths.overrideHomeForTesting(nil)
        try? FileManager.default.removeItem(at: tmp)
    }
    let vm = await MainActor.run { DataSourcesViewModel() }
    try await body(vm)
}

func runDataSourcesViewModelTests() async {
    print("\n\u{1F5A5}\u{FE0F} Data-Source Registry — Settings pane scenarios (view-model + BE↔FE alignment)")

    // MARK: - Load

    await test("Scenario: initial load shows Skills as entity #1 (unbound)") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            let (count, key, bound) = await MainActor.run {
                (vm.entities.count, vm.entities.first?.key, vm.entities.first?.isFullyBound)
            }
            try expect(count == 1, "one seeded entity")
            try expect(key == "skill", "skill entity #1")
            try expect(bound == false, "unbound until introspect")
        }
    }

    // MARK: - Remove data source (pane affordance + seed guard)

    await test("Scenario: remove a non-seed data source via the pane (forgets binding, seed remains)") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            // Add a second entity through the SAME shared store the tools use.
            _ = try await RegistryModule.makeAddEntity().handler(.object([
                "key": .string("project"),
                "dataSourceId": .string("f6d6ae1d-bfb4-4494-be18-c46e87dea149"),
                "properties": .array([
                    .object(["key": .string("title"), "notionName": .string("Name"), "type": .string("title"), "role": .string("title")]),
                ]),
            ]))
            await vm.load()
            let before = await MainActor.run { vm.entities.map { $0.key }.sorted() }
            try expect(before == ["project", "skill"], "pane sees both, got \(before)")
            await vm.removeEntity("project")
            let (after, status) = await MainActor.run { (vm.entities.map { $0.key }, vm.status) }
            try expect(after == ["skill"], "project removed, seed remains, got \(after)")
            try expect(status.contains("Removed"), "status reflects removal: \(status)")
        }
    }

    await test("Scenario: isSeed flags the Skills seed (extra-confirm guard) and not others") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            let (seed, notSeed) = await MainActor.run { (vm.isSeed("skill"), vm.isSeed("project")) }
            try expect(seed, "‘skill’ is the seed (pane shows the firm confirm)")
            try expect(!notSeed, "‘project’ is not the seed")
        }
    }

    // MARK: - Bind a data source (Decision 5: shipped seed is an UNBOUND template)

    await test("Scenario: the shipped seed ships UNBOUND to any data source (Decision 5)") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            let (dsid, boundToSource, fullyBound) = await MainActor.run {
                (vm.entities.first?.dataSourceId,
                 vm.entities.first?.isBoundToSource,
                 vm.entities.first?.isFullyBound)
            }
            try expect(dsid == "", "seed dataSourceId is empty (no hardcoded id)")
            try expect(boundToSource == false, "seed not bound to a source")
            try expect(fullyBound == false, "seed not fully bound (property ids unresolved)")
        }
    }

    await test("Scenario: setDataSource with a raw 32-hex id binds + persists the entity") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.setDataSource("skill", idOrURL: "b6ff6ea539174af79c36278dc8bfb21f")
            let (dsid, boundToSource, status) = await MainActor.run {
                (vm.entities.first?.dataSourceId, vm.entities.first?.isBoundToSource, vm.status)
            }
            try expect(dsid == "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f", "raw hex normalized to dashed uuid, got \(dsid ?? "nil")")
            try expect(boundToSource == true, "entity now bound to a source")
            try expect(status.contains("Introspect"), "status nudges to Introspect: \(status)")
            // Persisted across a fresh view-model (shared store).
            try await withFreshVM { vm2 in
                await vm2.load()
                let dsid2 = await MainActor.run { vm2.entities.first?.dataSourceId }
                try expect(dsid2 == "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f", "binding survived to disk")
            }
        }
    }

    await test("Scenario: setDataSource extracts the id from a notion.so URL") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.setDataSource("skill", idOrURL: "https://www.notion.so/myws/Skills-b6ff6ea539174af79c36278dc8bfb21f?v=2f1c0d9e4a5b4c6d8e7f0a1b2c3d4e5f")
            let dsid = await MainActor.run { vm.entities.first?.dataSourceId }
            try expect(dsid == "2f1c0d9e-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
                       "last 32-hex run (the ?v= view id) extracted + normalized, got \(dsid ?? "nil")")
        }
    }

    await test("Scenario: setDataSource with garbage leaves the entity unbound + sets an error status") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.setDataSource("skill", idOrURL: "not a notion id")
            let (dsid, boundToSource, status) = await MainActor.run {
                (vm.entities.first?.dataSourceId, vm.entities.first?.isBoundToSource, vm.status)
            }
            try expect(dsid == "", "still unbound after a bad id")
            try expect(boundToSource == false, "not bound to a source")
            try expect(status.lowercased().contains("couldn't read") || status.lowercased().contains("couldn’t read"),
                       "error surfaced in status: \(status)")
        }
    }

    await test("Unit: parseDataSourceId handles dashed id, bare hex, URL, and rejects junk") {
        let dashed = DataSourcesViewModel.parseDataSourceId("b6ff6ea5-3917-4af7-9c36-278dc8bfb21f")
        try expect(dashed == "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f", "dashed id round-trips, got \(dashed ?? "nil")")
        let bare = DataSourcesViewModel.parseDataSourceId("B6FF6EA539174AF79C36278DC8BFB21F")
        try expect(bare == "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f", "bare uppercase hex normalized, got \(bare ?? "nil")")
        let url = DataSourcesViewModel.parseDataSourceId("notion.so/Page-aaaa0000aaaa0000aaaa0000aaaa0000")
        try expect(url == "aaaa0000-aaaa-0000-aaaa-0000aaaa0000", "id pulled from slug, got \(url ?? "nil")")
        try expect(DataSourcesViewModel.parseDataSourceId("") == nil, "empty → nil")
        try expect(DataSourcesViewModel.parseDataSourceId("nope, no id here") == nil, "no 32-hex run → nil")
        try expect(DataSourcesViewModel.parseDataSourceId("dead") == nil, "short hex run → nil")
    }

    // MARK: - Propose → review → confirm (Decision 5)

    await test("Scenario: propose binding sets a CLEAN proposal but does NOT persist") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            let (hasProposal, fully, clean, entityStillUnbound) = await MainActor.run {
                (vm.proposal != nil, vm.proposal?.fullyBound, vm.proposal?.clean, vm.entities.first?.isFullyBound)
            }
            try expect(hasProposal, "proposal present")
            try expect(fully == true, "proposal fully bound")
            try expect(clean == true, "proposal clean (no missing columns)")
            try expect(entityStillUnbound == false, "entity NOT persisted yet (still unbound)")
        }
    }

    await test("Scenario: confirm persists the proposal; entity becomes fully bound") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            let ok = await vm.confirmProposal()
            try expect(ok, "confirm succeeded")
            let (proposalCleared, bound) = await MainActor.run {
                (vm.proposal == nil, vm.entities.first?.isFullyBound)
            }
            try expect(proposalCleared, "proposal cleared after confirm")
            try expect(bound == true, "entity now fully bound + persisted")
            // Persisted across a fresh view-model.
            try await withFreshVM { vm2 in
                await vm2.load()
                let bound2 = await MainActor.run { vm2.entities.first?.isFullyBound }
                try expect(bound2 == true, "binding survived to a fresh view-model (on disk)")
            }
        }
    }

    await test("Scenario: a missing column surfaces drift; proposal is not clean") {
        var cols = fullSkillsSchema().columnsByName
        cols["Specialist"] = nil   // drop a column → unmatched
        try await withVMEnv(VMFakeGateway(schema: DataSourceSchema(columnsByName: cols))) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            let (clean, fully, drift) = await MainActor.run {
                (vm.proposal?.clean, vm.proposal?.fullyBound, vm.proposal?.drift ?? [])
            }
            try expect(clean == false, "missing column → not clean")
            try expect(fully == false, "not fully bound")
            try expect(drift.contains { $0.contains("no column named") }, "drift names the missing column: \(drift)")
        }
    }

    await test("Scenario: type drift is reported but the proposal stays clean (id resolves)") {
        var cols = fullSkillsSchema().columnsByName
        cols["Status"] = .init(id: "id_status", type: "select")  // declared status, live select
        try await withVMEnv(VMFakeGateway(schema: DataSourceSchema(columnsByName: cols))) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            let (clean, fully, drift) = await MainActor.run {
                (vm.proposal?.clean, vm.proposal?.fullyBound, vm.proposal?.drift ?? [])
            }
            try expect(clean == true, "all names matched → clean")
            try expect(fully == true, "fully bound")
            try expect(drift.contains { $0.contains("type drift") }, "type drift surfaced: \(drift)")
        }
    }

    await test("Scenario: cancel discards the proposal, entity unchanged") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            await MainActor.run { vm.cancelProposal() }
            let (cleared, bound, status) = await MainActor.run {
                (vm.proposal == nil, vm.entities.first?.isFullyBound, vm.status)
            }
            try expect(cleared, "proposal cleared")
            try expect(bound == false, "entity still unbound")
            try expect(status == "Cancelled", "status reflects cancel")
        }
    }

    await test("Scenario: setTTL updates + persists the entity TTL") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.setTTL("skill", seconds: 99)
            let ttl = await MainActor.run { vm.entities.first?.cacheTTLSeconds }
            try expect(ttl == 99, "TTL updated to 99")
            try await withFreshVM { vm2 in
                await vm2.load()
                let ttl2 = await MainActor.run { vm2.entities.first?.cacheTTLSeconds }
                try expect(ttl2 == 99, "TTL persisted to disk")
            }
        }
    }

    await test("Scenario: introspection failure (offline) clears proposal + sets error status") {
        let fake = VMFakeGateway(schema: fullSkillsSchema())
        try await withVMEnv(fake) { vm in
            await vm.load()
            await fake.setOffline(true)
            await vm.proposeIntrospection("skill")
            let (proposal, status) = await MainActor.run { (vm.proposal, vm.status) }
            try expect(proposal == nil, "no proposal on failure")
            try expect(status.lowercased().contains("failed") || status.lowercased().contains("offline"),
                       "error surfaced in status: \(status)")
        }
    }

    // MARK: - BE↔FE alignment

    await test("Alignment: a binding confirmed in the UI is seen by the registry_entities TOOL") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            await vm.load()
            await vm.proposeIntrospection("skill")
            _ = await vm.confirmProposal()
            // Same config + gateway seam → the MCP tool reflects the UI's write.
            let out = try await RegistryModule.makeEntities().handler(.object([:]))
            guard case .object(let o) = out, case .array(let arr)? = o["entities"], let first = arr.first,
                  case .object(let e) = first else { throw TestError.assertion("tool returned no entities") }
            try expect(e["fullyBound"] == .bool(true), "tool sees the UI-confirmed binding")
        }
    }

    await test("Alignment: a binding made by the registry_introspect TOOL is seen by the pane") {
        try await withVMEnv(VMFakeGateway(schema: fullSkillsSchema())) { vm in
            // Tool binds first…
            _ = try await RegistryModule.makeIntrospect().handler(.object(["entity": .string("skill")]))
            // …then the pane loads and reflects it.
            await vm.load()
            let bound = await MainActor.run { vm.entities.first?.isFullyBound }
            try expect(bound == true, "pane sees the tool-made binding (shared config)")
        }
    }
}

// Re-enter the CURRENT env (temp home + gateway already set) with a brand-new
// view-model to prove on-disk persistence.
private func withFreshVM(_ body: (DataSourcesViewModel) async throws -> Void) async throws {
    let vm = await MainActor.run { DataSourcesViewModel() }
    try await body(vm)
}
