// RegistryConfigTests.swift — Data-Source Registry (vertical slice v0)
// TheBridge · Tests
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
import TheBridgeLib

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

    await test("RegistryConfig: packet is canonical with session compatibility alias") {
        let legacy = RegistryEntity(
            key: "session",
            displayName: "PACKETS",
            dataSourceId: "packets-ds",
            properties: [],
            cacheTTLSeconds: 3600,
            hasBody: true
        )
        let legacyConfig = RegistryConfig(entities: [legacy])
        try expect(legacyConfig.entity("packet")?.key == "packet")
        try expect(legacyConfig.entity("packet")?.dataSourceId == "packets-ds")

        let canonical = RegistryEntity(
            key: "packet",
            displayName: legacy.displayName,
            dataSourceId: legacy.dataSourceId,
            properties: legacy.properties,
            cacheTTLSeconds: legacy.cacheTTLSeconds,
            hasBody: legacy.hasBody
        )
        let canonicalConfig = RegistryConfig(entities: [canonical])
        try expect(canonicalConfig.entity("session")?.key == "packet")

        var actualSession = legacy
        actualSession.displayName = "Sessions"
        try expect(RegistryConfig(entities: [actualSession]).entity("packet") == nil,
                   "a real Sessions entity must never be mistaken for PACKETS")
    }

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
        // Decision 5: the shipped seed is an UNBOUND template — it carries NO
        // hardcoded data-source id (the customer binds their own via the pane).
        try expect(skill.dataSourceId == "", "seed ships unbound (no hardcoded data-source id)")
        try expect(!skill.isBoundToSource, "isBoundToSource false until the customer binds it")
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
        try expect(skill.property("files")?.notionName == "Files & media",
                   "files maps to Notion 'Files & media'")
        try expect(skill.property("files")?.type == "files", "files type")
        try expect(skill.property("googleDriveFile")?.notionName == "Google Drive File",
                   "googleDriveFile maps to Notion 'Google Drive File'")
        try expect(skill.property("manager")?.notionName == "Manager",
                   "manager maps to Notion 'Manager'")
        try expect(skill.property("manager")?.role == .relation, "manager is a relation")
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

    await test("Config.mergeSkillSeedProperties: appends files/googleDriveFile/manager without duplicating") {
        var old = RegistryEntity.skillsSeed()
        old.properties.removeAll { ["files", "googleDriveFile", "manager"].contains($0.key) }
        try expect(old.property("files") == nil, "pre-#254 seed has no files key")
        var cfg = RegistryConfig(entities: [old])
        try expect(cfg.mergeSkillSeedProperties(), "missing seed keys are appended")
        let merged = cfg.entity("skill")!
        try expect(merged.property("files")?.notionName == "Files & media")
        try expect(merged.property("googleDriveFile")?.type == "files")
        try expect(merged.property("manager")?.role == .relation)
        try expect(merged.property("specialist") != nil, "existing keys survive")
        try expect(!cfg.mergeSkillSeedProperties(), "second pass is a no-op")
    }

    await test("Store.load: older skill entity picks up new seed properties") {
        try await withTempRegistryStore { store, url in
            var old = RegistryEntity.skillsSeed()
            old.properties.removeAll { $0.key == "files" || $0.key == "googleDriveFile" || $0.key == "manager" }
            try await store.save(RegistryConfig(entities: [old]))
            let loaded = try await store.load()
            try expect(loaded.entity("skill")?.property("files") != nil,
                       "load merges Files & media onto an older skill entity")
            try expect(loaded.entity("skill")?.property("manager") != nil,
                       "load merges Manager")
            // Persisted so a subsequent load does not depend on in-memory merge.
            let onDisk = try JSONDecoder().decode(RegistryConfig.self, from: Data(contentsOf: url))
            try expect(onDisk.entity("skill")?.property("files") != nil, "merge is written through")
        }
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

    await test("Config.upsert: PACKETS session alias converges to one canonical persisted key") {
        let legacy = RegistryEntity(
            key: "session", displayName: "PACKETS", dataSourceId: "packets-ds",
            properties: [RegistryProperty(key: "name", notionName: "Packet Name", type: "title")],
            cacheTTLSeconds: 300, hasBody: true)
        var cfg = RegistryConfig(entities: [legacy])
        cfg.upsert(legacy)
        try expect(cfg.entities.filter(PacketRegistryContract.isPacketEntity).count == 1)
        try expect(cfg.entities.last?.key == "packet")
        try expect(cfg.entity("session")?.key == "packet")

        var legacyOnly = RegistryConfig(entities: [legacy])
        try expect(legacyOnly.removeEntity(key: "packet"), "canonical request removes legacy persisted alias")
        try expect(legacyOnly.entities.isEmpty)
    }

    await test("Config.canonicalizePacketAliases: packet+session same DS becomes one packet") {
        let packet = RegistryEntity(
            key: "packet", displayName: "PACKETS", dataSourceId: "packets-ds",
            properties: [RegistryProperty(key: "name", notionName: "Packet Name", type: "title")],
            cacheTTLSeconds: 300, hasBody: true)
        let session = RegistryEntity(
            key: "session", displayName: "PACKETS", dataSourceId: "packets-ds",
            properties: packet.properties, cacheTTLSeconds: 300, hasBody: true)
        var cfg = RegistryConfig(entities: [session, packet])
        try expect(cfg.canonicalizePacketAliases(), "dual PACKETS rows must change")
        try expect(cfg.entities.filter(PacketRegistryContract.isPacketEntity).count == 1)
        try expect(cfg.entities.contains(where: { $0.key == "packet" }))
        try expect(!cfg.entities.contains(where: { $0.key == "session" }))
        try expect(cfg.entity("session")?.key == "packet")
        try expect(!cfg.canonicalizePacketAliases(), "second pass is a no-op")
    }

    await test("Config.canonicalizePacketAliases: genuine Sessions entity is left beside packet") {
        let packet = RegistryEntity(
            key: "packet", displayName: "PACKETS", dataSourceId: "packets-ds",
            properties: [RegistryProperty(key: "name", notionName: "Packet Name", type: "title")],
            cacheTTLSeconds: 300, hasBody: true)
        let sessions = RegistryEntity(
            key: "session", displayName: "Sessions", dataSourceId: "sessions-ds",
            properties: [RegistryProperty(key: "name", notionName: "Session Name", type: "title")],
            cacheTTLSeconds: 300)
        var cfg = RegistryConfig(entities: [sessions, packet])
        try expect(!cfg.canonicalizePacketAliases(), "genuine Sessions is not packet-shaped")
        try expect(cfg.entity("session")?.dataSourceId == "sessions-ds")
        try expect(cfg.entity("packet")?.dataSourceId == "packets-ds")
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

    await test("Store: load heals packet+session duplicate into one canonical packet and rewrites disk") {
        try await withTempRegistryStore { store, url in
            let packet = RegistryEntity(
                key: "packet", displayName: "PACKETS", dataSourceId: "packets-ds",
                properties: [RegistryProperty(key: "name", notionName: "Packet Name", type: "title")],
                cacheTTLSeconds: 300, hasBody: true)
            let session = RegistryEntity(
                key: "session", displayName: "PACKETS", dataSourceId: "packets-ds",
                properties: packet.properties, cacheTTLSeconds: 300, hasBody: true)
            let dual = RegistryConfig(entities: [session, packet])
            try JSONEncoder().encode(dual).write(to: url)
            let loaded = try await store.load()
            try expect(loaded.entities.filter(PacketRegistryContract.isPacketEntity).count == 1)
            try expect(loaded.entities.contains(where: { $0.key == "packet" }))
            try expect(!loaded.entities.contains(where: { $0.key == "session" }))
            try expect(loaded.entity("session")?.key == "packet")
            let onDisk = try JSONDecoder().decode(RegistryConfig.self, from: Data(contentsOf: url))
            try expect(onDisk.entities.filter(PacketRegistryContract.isPacketEntity).count == 1,
                       "load must persist the healed config")
            try expect(onDisk.entities.contains(where: { $0.key == "packet" }))
        }
    }

    await test("Store: load keeps a genuine Sessions entity beside packet") {
        try await withTempRegistryStore { store, url in
            let packet = RegistryEntity(
                key: "packet", displayName: "PACKETS", dataSourceId: "packets-ds",
                properties: [RegistryProperty(key: "name", notionName: "Packet Name", type: "title")],
                cacheTTLSeconds: 300, hasBody: true)
            let sessions = RegistryEntity(
                key: "session", displayName: "Sessions", dataSourceId: "sessions-ds",
                properties: [RegistryProperty(key: "name", notionName: "Session Name", type: "title")],
                cacheTTLSeconds: 300)
            try await store.save(RegistryConfig(entities: [sessions, packet]))
            let loaded = try await store.load()
            try expect(loaded.entity("session")?.dataSourceId == "sessions-ds")
            try expect(loaded.entity("packet")?.dataSourceId == "packets-ds")
            try expect(loaded.entities.count == 2)
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
