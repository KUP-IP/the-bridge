// StandingOrdersDeliveryTests.swift — MCP resource layer SSOT.
//
// Covers the StandingOrdersDelivery single source of truth: composition
// determinism + content-hash stability, the routing-index carve-out, and the
// BridgeResources URI → bytes resolution that BOTH transports share. These
// are file-I/O hermetic via withTempHome (per-test throwaway HOME), so the
// composed instructions reflect a known on-disk Standing Orders body.

import Foundation
import TheBridgeLib

func runStandingOrdersDeliveryTests() async {
    print("\n[StandingOrdersDelivery]")

    await test("Delivery: composition is deterministic for identical state") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nbe terse")
            let a = StandingOrdersDelivery.composition()
            let b = StandingOrdersDelivery.composition()
            try expect(a == b, "two reads of the same state must be Equatable-equal")
            try expect(a.instructionsMarkdown == b.instructionsMarkdown)
            try expect(a.contentHash == b.contentHash)
            try expect(a.routingIndexMarkdown == b.routingIndexMarkdown)
        }
    }

    await test("Delivery: contentHash is a 64-hex SHA256 of instructionsMarkdown") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nhash me")
            let c = StandingOrdersDelivery.composition()
            try expect(c.contentHash.count == 64, "SHA256 hex is 64 chars, got \(c.contentHash.count)")
            try expect(c.contentHash.allSatisfy { $0.isHexDigit }, "hash must be all hex")
            // Recompute independently against the same string via the public helper.
            let expected = StandingOrdersDelivery.sha256Hex(c.instructionsMarkdown)
            try expect(c.contentHash == expected, "hash must be SHA256 of instructionsMarkdown")
        }
    }

    await test("Delivery: contentHash changes when standing orders change") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nversion one")
            let h1 = StandingOrdersDelivery.composition().contentHash
            _ = try StandingOrdersStore.shared.write("# Orders\n\nversion two")
            let h2 = StandingOrdersDelivery.composition().contentHash
            try expect(h1 != h2, "content hash must track instruction content")
        }
    }

    await test("Delivery: instructionsMarkdown prepends orders and embeds routing index") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# MY ORDERS\n\ndo the thing")
            let c = StandingOrdersDelivery.composition()
            // Orders body leads; routing index (the SSOT routing markdown) is
            // present and identical to routingIndexMarkdown.
            try expect(c.instructionsMarkdown.hasPrefix("# MY ORDERS"),
                       "orders must lead the composed payload")
            try expect(c.instructionsMarkdown.contains(c.routingIndexMarkdown),
                       "the routing index must be embedded verbatim in instructions")
            try expect(c.instructionsMarkdown.contains("\n\n---\n\n"),
                       "orders and routing index are joined by the standard separator")
        }
    }

    await test("Delivery: missing doctrine is explicit INCOMPLETE, never silent routing-only") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            let c = StandingOrdersDelivery.composition()
            try expect(c.initializationReceipt.initializationState == .incomplete)
            try expect(c.initializationReceipt.issues.contains { $0.contains("orders.md is missing") })
            try expect(c.instructionsMarkdown.contains(c.routingIndexMarkdown),
                       "routing remains available for recovery")
            try expect(c.instructionsMarkdown.contains("## Bridge initialization receipt"))
            try expect(c.instructionsMarkdown.contains("- Initialization: INCOMPLETE"))
            try expect(c.instructionsMarkdown != c.routingIndexMarkdown,
                       "missing doctrine must not masquerade as routing-only success")
        }
    }

    await test("Delivery: tokenCount is a positive chars/4 estimate over instructions") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nsome content worth estimating")
            let c = StandingOrdersDelivery.composition()
            try expect(c.tokenCount == c.instructionsMarkdown.count / 4,
                       "tokenCount must be chars/4 of instructionsMarkdown")
            try expect(c.tokenCount > 0)
        }
    }

    await test("Delivery: clientName hook does not alter content (overlays deferred)") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nuniform across clients")
            let base = StandingOrdersDelivery.composition(clientName: nil)
            let named = StandingOrdersDelivery.composition(clientName: "claude-code-9.9.9")
            try expect(base == named, "clientName is a hook only — content must be identical today")
        }
    }

    // MARK: - BridgeResources (shared URI → bytes resolution)

    await test("Resources: list advertises the three bridge:// resources") {
        let uris = Set(BridgeResources.list.map { $0.uri })
        try expect(uris == [BridgeResources.standingOrdersURI,
                            BridgeResources.routingSkillsURI,
                            BridgeResources.memoryURI],
                   "exactly the three canonical resources, got \(uris)")
        try expect(BridgeResources.list.allSatisfy { $0.mimeType == "text/markdown" },
                   "all resources are text/markdown")
    }

    await test("Resources: dictionary projection matches the typed list shape") {
        let dicts = BridgeResources.listAsDictionaries
        try expect(dicts.count == 3)
        let dictURIs = Set(dicts.compactMap { $0["uri"] as? String })
        let typedURIs = Set(BridgeResources.list.map { $0.uri })
        try expect(dictURIs == typedURIs, "legacy dict projection must carry the same URIs")
        try expect(dicts.allSatisfy { ($0["mimeType"] as? String) == "text/markdown" })
    }

    await test("Resources: read resolves each URI to the matching SSOT bytes") {
        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nresolve me")
            let c = StandingOrdersDelivery.composition()
            let orders = try await BridgeResources.markdown(for: BridgeResources.standingOrdersURI)
            let routing = try await BridgeResources.markdown(for: BridgeResources.routingSkillsURI)
            try expect(orders == c.instructionsMarkdown,
                       "standing-orders resource == composed instructions (byte-identical)")
            try expect(routing == c.routingIndexMarkdown,
                       "routing-skills resource == routing index alone")
        }
    }

    await test("Resources: read of an unknown URI throws") {
        do {
            _ = try await BridgeResources.markdown(for: "bridge://does-not-exist")
            try expect(false, "expected throw for unknown URI")
        } catch {
            // expected — MCPError.invalidParams
        }
    }

    // MARK: - bridge://memory resource (renderer is PURE; actor read is bridged)

    await test("Memory resource: appears in BOTH list shapes as text/markdown") {
        // Typed list.
        let typed = BridgeResources.list.first { $0.uri == BridgeResources.memoryURI }
        try expect(typed != nil, "bridge://memory must be in the typed list")
        try expect(typed?.name == "Memory")
        try expect(typed?.mimeType == "text/markdown")
        try expect(typed?.description == "Recent salient memories the agent has stored")
        // Dictionary projection.
        let dict = BridgeResources.listAsDictionaries.first { ($0["uri"] as? String) == BridgeResources.memoryURI }
        try expect(dict != nil, "bridge://memory must be in the dictionary projection")
        try expect((dict?["name"] as? String) == "Memory")
        try expect((dict?["mimeType"] as? String) == "text/markdown")
    }

    await test("Memory resource: empty slice renders the one-line notice") {
        let md = StandingOrdersDelivery.renderMemoryMarkdown([])
        try expect(md == "No memories stored yet.", "empty state must be the single notice line, got \(md)")
    }

    await test("Memory resource: renders slice grouped by scope with type/entity/use") {
        let now = Date()
        let entries: [MemoryEntry] = [
            MemoryEntry(scope: "people", entity: "isaiah", text: "prefers concise replies",
                        type: .preference, pinned: true, useCount: 3,
                        createdAt: now, lastUsedAt: now, source: "t", contentHash: "h1"),
            MemoryEntry(scope: "people", entity: nil, text: "no entity here",
                        type: .fact, pinned: false, useCount: 0,
                        createdAt: now, lastUsedAt: now, source: "t", contentHash: "h2"),
            MemoryEntry(scope: "project", entity: "atlas", text: "ships in Q3",
                        type: .decision, pinned: false, useCount: 1,
                        createdAt: now, lastUsedAt: now, source: "t", contentHash: "h3"),
        ]
        let md = StandingOrdersDelivery.renderMemoryMarkdown(entries)

        // Scope headers present, first-appearance order (people before project).
        try expect(md.contains("## people"), "people scope header")
        try expect(md.contains("## project"), "project scope header")
        try expect(md.range(of: "## people")!.lowerBound < md.range(of: "## project")!.lowerBound,
                   "scopes follow first-appearance (ranked) order")

        // Row shape: [type] text · entity · source · date · used N×
        try expect(md.contains("- [preference] prefers concise replies · isaiah"),
                   "entity row present; got:\n\(md)")
        try expect(md.contains("source: t"), "row must include source; got:\n\(md)")
        try expect(md.contains("used 3×"), "use count present; got:\n\(md)")
        // No entity → entity segment omitted; source + date always present.
        try expect(md.contains("- [fact] no entity here · source: t"), "no-entity row includes source; got:\n\(md)")
        try expect(!md.contains("- [fact] no entity here · isaiah"), "no-entity row must not include a fake entity segment")
        // useCount 1 still renders (only 0 is omitted).
        try expect(md.contains("- [decision] ships in Q3 · atlas"),
                   "decision row with entity; got:\n\(md)")
        try expect(md.contains("used 1×"), "decision use count")
    }

    await test("Memory resource: read via temp-store actor bridges cleanly (pinned-first, non-empty)") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-memory-resource-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("memory.sqlite")
        let store = MemoryStore(path: url)
        defer {
            Task { await store.close() }
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix))
            }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let pinned = try await store.remember(text: "pin me to the top", scope: "global", source: "t")
        _ = try await store.remember(text: "ordinary salient fact", scope: "global", source: "t")
        try await store.pin(id: pinned.id, true)

        // Drive the PURE renderer over the actor's slice — same path
        // BridgeResources.memoryMarkdown() takes, minus the shared singleton
        // (tests never touch MemoryStore.shared).
        let slice = try await store.handshakeSlice(limit: 20)
        let md = StandingOrdersDelivery.renderMemoryMarkdown(slice)
        try expect(md != "No memories stored yet.", "seeded store must render real rows")
        try expect(md.contains("## global"), "scope header present")
        try expect(md.contains("pin me to the top"), "pinned entry surfaced")
        // Pinned leads its scope group (handshakeSlice emits pinned-first).
        try expect(md.range(of: "pin me to the top")!.lowerBound
                   < md.range(of: "ordinary salient fact")!.lowerBound,
                   "pinned entry must render before the unpinned one")
    }

    await test("asyncComposition: per-client override ON injects memory block") {
        let injectStore = MemoryAutoInjectClientStore.shared
        injectStore.resetForTesting()
        defer { injectStore.resetForTesting() }

        try await withDeliveryTempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\nwave3 inject")

            let memStore = MemoryStore.shared
            try await memStore.open()
            _ = try await memStore.remember(text: "inject me at handshake", scope: "global", source: "cursor")

            UserDefaults.standard.set(false, forKey: BridgeDefaults.memoryHandshakeAutoInject)
            injectStore.setOverride(true, forClient: "cursor")

            let sync = StandingOrdersDelivery.composition(clientName: "cursor")
            let injected = await StandingOrdersDelivery.asyncComposition(clientName: "cursor")
            try expect(injected.instructionsMarkdown.contains("## Memory"),
                       "cursor override must inject memory section")
            try expect(injected.instructionsMarkdown.contains("inject me at handshake"),
                       "injected slice must include salient memory")
            try expect(sync.instructionsMarkdown != injected.instructionsMarkdown,
                       "injected composition must differ from sync when override ON")
        }
    }

    await test("MemoryAutoInjectClientStore: seedWave3DefaultsIfNeeded is idempotent") {
        let store = MemoryAutoInjectClientStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        UserDefaults.standard.set(false, forKey: BridgeDefaults.memoryHandshakeAutoInject)
        MemoryAutoInjectClientStore.seedWave3DefaultsIfNeeded()
        try expect(store.override(forClient: "cursor") == true, "first seed sets cursor ON")
        store.setOverride(false, forClient: "cursor")
        MemoryAutoInjectClientStore.seedWave3DefaultsIfNeeded()
        try expect(store.override(forClient: "cursor") == false,
                   "seed must not overwrite non-empty override map")
    }
}

// MARK: - Test helpers (local, not exported)

private func withDeliveryTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("StandingOrdersDelivery-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
