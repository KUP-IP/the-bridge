// RegistryConfigTests.swift — Data-Source Registry (vertical slice v0)
// NotionBridge · Tests
//
// Coverage for the registry config model + store (Wave 1, additive):
//   - RegistryConfig.defaultSeed: Skills is entity #1 (Decision 7), unbound
//     property ids (Decision 5), title-role + hasBody contract.
//   - RegistryEntity binding: applying(bindings:) → isFullyBound.
//   - RegistryConfig.upsert: replace-in-place vs append.
//   - RegistryConfigStore: missing→seed, save→load round-trip, seedIfMissing,
//     corrupt→throws / loadOrSeed→seed, upsertEntity persistence.
//   - Forwards-tolerant decode (unknown keys + missing fields default).
//
// Hermetic: each store test uses a fresh temp file path; no shared state.

import Foundation
import MCP
import NotionBridgeLib

private func withTempRegistryStore(_ body: (RegistryConfigStore, URL) async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-registrycfg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let url = tmp.appendingPathComponent("registry.json", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try await body(RegistryConfigStore(storeURL: url), url)
}

func runRegistryConfigTests() async {
    print("\n\u{1F5C3}\u{FE0F} Data-Source Registry — Config (model + store)")

    // MARK: - Seed model

    await test("Seed: Skills is entity #1 with the expected shape") {
        let cfg = RegistryConfig.defaultSeed()
        try expect(cfg.schemaVersion == 1, "schemaVersion 1")
        try expect(cfg.entities.count == 1, "one seeded entity")
        guard let skill = cfg.entity("skill") else {
            throw TestError.assertion("missing 'skill' entity")
        }
        try expect(skill.displayName == "Skills", "displayName Skills")
        try expect(skill.hasBody, "skills are body-possessable (hasBody)")
        try expect(skill.dataSourceId == "b6ff6ea5-3917-4af7-9c36-278dc8bfb21f",
                   "seeded Keepr/Skills data source id")
        try expect(skill.workspace == nil, "workspace nil → primary connection")
        try expect(skill.cacheTTLSeconds == 6 * 3600, "skills TTL 6h")
    }

    await test("Seed: title property is role-tagged and addressable by key") {
        let skill = RegistryEntity.skillsSeed()
        guard let title = skill.titleProperty else {
            throw TestError.assertion("no title property")
        }
        try expect(title.key == "name", "title key is 'name'")
        try expect(title.notionName == "Skill Name", "title notionName")
        try expect(title.type == "title", "title type")
        try expect(skill.property("summary")?.notionName == "Description",
                   "summary maps to Notion 'Description'")
        try expect(skill.property("nope") == nil, "unknown key → nil")
    }

    await test("Seed: property ids are UNBOUND (Decision 5 — never shipped)") {
        let skill = RegistryEntity.skillsSeed()
        try expect(skill.properties.allSatisfy { !$0.isBound },
                   "no property ships a hardcoded id")
        try expect(!skill.isFullyBound, "seed is not fully bound until introspect")
    }

    // MARK: - Binding

    await test("Binding: applying(bindings:) binds ids → isFullyBound") {
        let skill = RegistryEntity.skillsSeed()
        var bindings: [String: String] = [:]
        for (i, p) in skill.properties.enumerated() { bindings[p.key] = "prop_\(i)" }
        let bound = skill.applying(bindings: bindings)
        try expect(bound.isFullyBound, "all properties bound")
        try expect(bound.property("name")?.notionPropertyId == "prop_0", "name bound to prop_0")
        // Original is unchanged (value semantics).
        try expect(!skill.isFullyBound, "binding does not mutate the source")
    }

    await test("Binding: partial bindings leave the rest unbound") {
        let bound = RegistryEntity.skillsSeed().applying(bindings: ["name": "prop_title"])
        try expect(bound.property("name")?.isBound == true, "name bound")
        try expect(bound.property("summary")?.isBound == false, "summary still unbound")
        try expect(!bound.isFullyBound, "not fully bound with one binding")
    }

    await test("Property.bound(to:) treats empty id as still-unbound") {
        let p = RegistryProperty(key: "x", notionName: "X", type: "rich_text")
        try expect(!p.bound(to: "").isBound, "empty id → unbound")
        try expect(p.bound(to: "prop_1").isBound, "non-empty id → bound")
    }

    // MARK: - upsert

    await test("Config.upsert: replace-in-place by key, else append") {
        var cfg = RegistryConfig.defaultSeed()
        try expect(cfg.entities.count == 1, "starts with skills")
        var skill = cfg.entity("skill")!
        skill.displayName = "Renamed Skills"
        cfg.upsert(skill)
        try expect(cfg.entities.count == 1, "replace-in-place, no dup")
        try expect(cfg.entity("skill")?.displayName == "Renamed Skills", "replaced")
        cfg.upsert(RegistryEntity(key: "contact", displayName: "Contacts",
                                  dataSourceId: "ds_c", properties: [], cacheTTLSeconds: 3600))
        try expect(cfg.entities.count == 2, "new key appended")
    }

    // MARK: - Store

    await test("Store: missing file → seed (not persisted yet)") {
        try await withTempRegistryStore { store, _ in
            let exists = await store.exists()
            try expect(!exists, "no file before first save")
            let cfg = try await store.load()
            try expect(cfg.entity("skill") != nil, "missing load returns seed")
        }
    }

    await test("Store: save → load round-trips equal") {
        try await withTempRegistryStore { store, _ in
            var cfg = RegistryConfig.defaultSeed()
            cfg.upsert(RegistryEntity(key: "project", displayName: "Projects",
                                      dataSourceId: "ds_p",
                                      properties: [RegistryProperty(key: "title",
                                                                    notionName: "Title",
                                                                    notionPropertyId: "ptitle",
                                                                    type: "title", role: .title)],
                                      cacheTTLSeconds: 300))
            try await store.save(cfg)
            let exists = await store.exists()
            try expect(exists, "file exists after save")
            let loaded = try await store.load()
            try expect(loaded == cfg, "round-trips byte-equal as model")
            try expect(loaded.entity("project")?.isFullyBound == true, "bound project survives")
        }
    }

    await test("Store: seedIfMissing writes seed once, then is idempotent") {
        try await withTempRegistryStore { store, _ in
            let first = try await store.seedIfMissing()
            try expect(first.entity("skill") != nil, "seed written")
            // Mutate on disk, then seedIfMissing must NOT overwrite.
            var cfg = first
            cfg.upsert(RegistryEntity(key: "memory", displayName: "Memory",
                                      dataSourceId: "ds_m", properties: [], cacheTTLSeconds: 21600))
            try await store.save(cfg)
            let second = try await store.seedIfMissing()
            try expect(second.entity("memory") != nil, "existing file preserved, not reseeded")
        }
    }

    await test("Store: corrupt file → load throws, loadOrSeed returns seed") {
        try await withTempRegistryStore { store, url in
            try Data("{ not json".utf8).write(to: url)
            var threw = false
            do { _ = try await store.load() } catch { threw = true }
            try expect(threw, "corrupt file must throw from load()")
            let seeded = await store.loadOrSeed()
            try expect(seeded.entity("skill") != nil, "loadOrSeed degrades to seed")
        }
    }

    await test("Store: upsertEntity persists across a fresh store instance") {
        try await withTempRegistryStore { store, url in
            try await store.seedIfMissing()
            _ = try await store.upsertEntity(
                RegistryEntity(key: "contact", displayName: "Contacts",
                               dataSourceId: "ds_c", properties: [], cacheTTLSeconds: 3600))
            // New store over the SAME path → must see the persisted entity.
            let store2 = RegistryConfigStore(storeURL: url)
            let cfg = try await store2.load()
            try expect(cfg.entity("contact") != nil, "upsert persisted to disk")
            try expect(cfg.entity("skill") != nil, "seed entity still present")
        }
    }

    // MARK: - Forwards-tolerant decode

    await test("Decode: unknown keys ignored + missing fields default") {
        let json = """
        {"schemaVersion":2,"entities":[{"key":"skill","dataSourceId":"ds_x",
        "properties":[{"key":"name","notionName":"Name","type":"title","role":"title",
        "futureField":true}],"surpriseKey":42}],"anotherSurprise":"x"}
        """
        let cfg = try JSONDecoder().decode(RegistryConfig.self, from: Data(json.utf8))
        try expect(cfg.schemaVersion == 2, "schemaVersion read")
        let e = cfg.entity("skill")
        try expect(e != nil, "entity decoded despite unknown keys")
        try expect(e?.displayName == "", "missing displayName defaults empty")
        try expect(e?.cacheTTLSeconds == 3600, "missing TTL defaults 3600")
        try expect(e?.hasBody == false, "missing hasBody defaults false")
        try expect(e?.property("name")?.role == .title, "property role decoded")
        try expect(e?.property("name")?.isBound == false, "missing id → unbound")
    }
}
