// MemoryModuleTests.swift — Unified Memory subsystem · FOUNDATION (Wave 1)
// NotionBridge · Tests
//
// Covers the MemoryStore (SQLite + FTS5) and the memory_* MCP tools against a
// TEMP DB path (never the real config-dir memory.sqlite, never the shared
// singleton). Each store-level test instantiates a fresh MemoryStore(path:)
// pointed at a unique temp file and tears it down. Module tests register the
// tools on a throwaway router with a temp-backed store and invoke handlers
// directly off the registration (the dispatch gate is not the unit here).
//
// Coverage:
//   • store insert/get round-trip
//   • FTS recall + salience ranking ORDER
//   • dedup: exact-hash refresh (no dup) + near-duplicate supersede
//   • use-promotes: recall bumps useCount + reorders on the next recall
//   • pin-to-top
//   • forget tombstone excluded from recall + list
//   • scope/entity filter
//   • module registration + tiering + handler round-trip on both registrations

import Foundation
import MCP
import NotionBridgeLib

// MARK: - Temp-DB helpers

/// A fresh MemoryStore over a unique temp file. Caller is responsible for
/// nothing — the OS reclaims the temp dir, and `cleanup` removes the file +
/// WAL/SHM siblings so a re-run never collides.
private func makeTempStore() -> (store: MemoryStore, url: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-memory-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("memory.sqlite")
    return (MemoryStore(path: url), url)
}

private func cleanup(_ url: URL) {
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        try? fm.removeItem(at: url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix))
    }
    try? fm.removeItem(at: url.deletingLastPathComponent())
}

private func makeMemoryRouter(_ store: MemoryStore) async -> ToolRouter {
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await MemoryModule.register(on: router, store: store)
    return router
}

private func callMemoryHandler(_ router: ToolRouter, _ name: String, _ args: Value) async throws -> Value {
    let regs = await router.registrations(forModule: "memory")
    guard let reg = regs.first(where: { $0.name == name }) else {
        throw TestError.assertion("tool \(name) not registered")
    }
    return try await reg.handler(args)
}

private func memObjField(_ v: Value, _ key: String) -> Value? {
    if case .object(let d) = v { return d[key] }
    return nil
}

func runMemoryModuleTests() async {
    print("\n\u{1F9E0} MemoryModule Tests (Unified Memory · Wave 1)")

    // MARK: - Store: insert + get round-trip

    await test("MemoryStore: remember + get round-trip") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let e = try await store.remember(text: "Isaiah prefers concise replies",
                                         scope: "people", entity: "isaiah",
                                         type: .preference, source: "test")
        try expect(!e.id.isEmpty, "id should be set")
        try expect(e.scope == "people" && e.entity == "isaiah")
        try expect(e.type == .preference)
        try expect(e.useCount == 0, "fresh entry starts at useCount 0")
        let got = try await store.get(id: e.id)
        try expect(got?.text == "Isaiah prefers concise replies", "get must round-trip text")
        try expect(got?.contentHash == e.contentHash, "contentHash persisted")
    }

    await test("MemoryStore: get returns nil for unknown id") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let got = try await store.get(id: "does-not-exist")
        try expect(got == nil, "unknown id must be nil")
    }

    // MARK: - FTS recall + ranking order

    await test("MemoryStore: FTS recall matches on query terms") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "The deploy pipeline runs on GitHub Actions",
                                     scope: "project", source: "t")
        _ = try await store.remember(text: "Coffee order is oat flat white",
                                     scope: "people", source: "t")
        let hits = try await store.recall(query: "deploy pipeline")
        try expect(hits.count == 1, "expected exactly 1 FTS hit, got \(hits.count)")
        try expect(hits.first?.text.contains("GitHub Actions") == true)
    }

    await test("MemoryStore: recall ranks decision-type above reference-type at equal freshness") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        // Same query term, same recency, differ only by type weight.
        _ = try await store.remember(text: "alpha reference note", scope: "project",
                                     type: .reference, source: "t")
        _ = try await store.remember(text: "alpha decision note", scope: "project",
                                     type: .decision, source: "t")
        let hits = try await store.recall(query: "alpha")
        try expect(hits.count == 2, "expected both alpha entries")
        try expect(hits.first?.type == .decision,
                   "decision must outrank reference by type weight; got \(hits.first?.type as Any)")
    }

    await test("MemoryStore: empty query falls back to salience-ranked recents") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "first", scope: "global", source: "t")
        _ = try await store.remember(text: "second", scope: "global", source: "t")
        let hits = try await store.recall(query: "")
        try expect(hits.count == 2, "empty query should return the live set, got \(hits.count)")
    }

    // MARK: - Dedup / supersede

    await test("MemoryStore: identical text refreshes in place (no duplicate row)") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let a = try await store.remember(text: "lives in Brooklyn", scope: "people",
                                         entity: "sam", source: "client-A")
        let b = try await store.remember(text: "lives in Brooklyn", scope: "people",
                                         entity: "sam", source: "client-B")
        try expect(a.id == b.id, "identical text must refresh the same row")
        try expect(b.useCount == a.useCount + 1, "refresh bumps useCount")
        try expect(b.source == "client-B", "refresh updates source")
        let all = try await store.list(scope: "people", entity: "sam")
        try expect(all.count == 1, "must not create a duplicate row, got \(all.count)")
    }

    await test("MemoryStore: near-duplicate supersedes old + tombstones it (recall returns only fresh)") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let old = try await store.remember(
            text: "favorite programming language is Swift and Rust",
            scope: "people", entity: "dev", source: "t")
        let new = try await store.remember(
            text: "favorite programming language is Swift and Rust mostly",
            scope: "people", entity: "dev", source: "t")
        try expect(new.id != old.id, "supersede inserts a NEW row")
        try expect(new.supersedesId == old.id, "new row points supersedesId at old")
        // The old row is tombstoned → only the fresh text is live.
        let live = try await store.list(scope: "people", entity: "dev")
        try expect(live.count == 1, "stale superseded row must be tombstoned out of list")
        try expect(live.first?.id == new.id, "live row is the fresh one")
        let recalled = try await store.recall(query: "favorite programming language", scope: "people", entity: "dev")
        try expect(recalled.count == 1, "recall must not surface the tombstoned predecessor")
    }

    await test("MemoryStore: distinct text in same scope does NOT dedup") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "birthday is in March", scope: "people", entity: "k", source: "t")
        _ = try await store.remember(text: "works at a hospital downtown", scope: "people", entity: "k", source: "t")
        let all = try await store.list(scope: "people", entity: "k")
        try expect(all.count == 2, "unrelated facts must both persist, got \(all.count)")
    }

    // MARK: - Use-promotes (recall bumps useCount + reorders)

    await test("MemoryStore: recall promotes returned rows (useCount bumps + reorders)") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "shared keyword north", scope: "project", source: "t")
        _ = try await store.remember(text: "shared keyword south", scope: "project", source: "t")

        // First recall: both returned, each promoted once.
        let first = try await store.recall(query: "keyword")
        try expect(first.count == 2)
        try expect(first.allSatisfy { $0.useCount == 1 }, "recall must bump useCount to 1")

        // Promote ONLY 'north' several more times by querying its unique term.
        for _ in 0..<3 { _ = try await store.recall(query: "north") }

        // Now a shared-term recall should rank 'north' first (higher useCount
        // term dominates frequency contribution at equal recency).
        let again = try await store.recall(query: "keyword")
        try expect(again.first?.text.contains("north") == true,
                   "heavily-used entry must rank first after promotion; got \(again.first?.text as Any)")
    }

    // MARK: - Pin to top

    await test("MemoryStore: pinned entry sorts to the top of recall") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let a = try await store.remember(text: "topic apple low signal", scope: "global", source: "t")
        let b = try await store.remember(text: "topic apple high signal repeated apple apple", scope: "global", source: "t")
        // Without a pin, 'b' (more term hits) would likely lead. Pin 'a'.
        try await store.pin(id: a.id, true)
        let hits = try await store.recall(query: "apple")
        try expect(hits.first?.id == a.id, "pinned entry must be first regardless of score")
        try expect(hits.contains { $0.id == b.id }, "non-pinned match still present")
    }

    await test("MemoryStore: unpin restores normal ranking") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let a = try await store.remember(text: "gamma one", scope: "global", source: "t")
        try await store.pin(id: a.id, true)
        try await store.pin(id: a.id, false)
        let got = try await store.get(id: a.id)
        try expect(got?.pinned == false, "unpin must clear the pinned flag")
    }

    // MARK: - Forget tombstone

    await test("MemoryStore: forget tombstones (soft) — excluded from recall + list, still get-able") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let e = try await store.remember(text: "ephemeral secret token", scope: "global", source: "t")
        try await store.forget(id: e.id)
        let recalled = try await store.recall(query: "ephemeral secret")
        try expect(recalled.isEmpty, "forgotten entry must not appear in recall")
        let listed = try await store.list(scope: "global")
        try expect(listed.isEmpty, "forgotten entry must not appear in list")
        // Soft-delete: row still exists for audit / supersede chains.
        let still = try await store.get(id: e.id)
        try expect(still != nil, "forget is SOFT — get must still return the tombstoned row")
        try expect(still?.expiresAt != nil, "tombstone sets expiresAt")
    }

    // MARK: - Scope / entity filter

    await test("MemoryStore: recall + list honor scope and entity filters") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "shared term zeta", scope: "people", entity: "x", source: "t")
        _ = try await store.remember(text: "shared term zeta", scope: "project", entity: "y", source: "t")

        let peopleOnly = try await store.recall(query: "zeta", scope: "people")
        try expect(peopleOnly.count == 1 && peopleOnly.first?.scope == "people",
                   "scope filter must restrict recall")

        let entityOnly = try await store.recall(query: "zeta", scope: "project", entity: "y")
        try expect(entityOnly.count == 1 && entityOnly.first?.entity == "y",
                   "entity filter must restrict recall")

        let listScoped = try await store.list(scope: "project")
        try expect(listScoped.count == 1 && listScoped.first?.scope == "project",
                   "scope filter must restrict list")
    }

    // MARK: - handshakeSlice extension point

    await test("MemoryStore: handshakeSlice returns pinned-first and does NOT promote") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let a = try await store.remember(text: "slice fact one", scope: "global", source: "t")
        _ = try await store.remember(text: "slice fact two", scope: "global", source: "t")
        try await store.pin(id: a.id, true)
        let slice = try await store.handshakeSlice(limit: 5)
        try expect(slice.first?.id == a.id, "pinned must lead the handshake slice")
        // Passive read: must not have bumped useCount.
        let reread = try await store.get(id: a.id)
        try expect(reread?.useCount == 0, "handshakeSlice must not use-promote (passive surface)")
    }

    // MARK: - Module registration + tiering

    await test("MemoryModule registers exactly 4 tools") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let router = await makeMemoryRouter(store)
        let tools = await router.registrations(forModule: "memory")
        try expect(tools.count == 4, "expected 4 memory tools, got \(tools.count)")
    }

    await test("memory tiering: remember=.notify (write), recall=.open (read-only)") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let router = await makeMemoryRouter(store)
        let tools = await router.registrations(forModule: "memory")
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expect(byName["memory_remember"]?.tier == .notify, "remember must be .notify")
        try expect(byName["memory_recall"]?.tier == .open, "recall must be .open")
    }

    // MARK: - Module handler round-trip

    await test("memory_remember handler stores; memory_recall handler retrieves") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let router = await makeMemoryRouter(store)

        let stored = try await callMemoryHandler(router, "memory_remember", .object([
            "text": .string("project Atlas ships in Q3"),
            "scope": .string("project"),
            "entity": .string("atlas"),
            "type": .string("decision")
        ]))
        try expect(memObjField(stored, "id") != nil, "remember must return an id")
        try expect(memObjField(stored, "type") == .string("decision"))

        let recalled = try await callMemoryHandler(router, "memory_recall", .object([
            "query": .string("Atlas ships"),
            "scope": .string("project")
        ]))
        try expect(memObjField(recalled, "count") == .int(1), "recall should find the stored memory")
        if case .array(let arr)? = memObjField(recalled, "memories"), let first = arr.first {
            try expect(memObjField(first, "text") == .string("project Atlas ships in Q3"))
        } else {
            throw TestError.assertion("recall returned no memories array")
        }
    }

    await test("memory_remember handler rejects missing text") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let router = await makeMemoryRouter(store)
        do {
            _ = try await callMemoryHandler(router, "memory_remember", .object(["scope": .string("global")]))
            throw TestError.assertion("expected an error for missing text")
        } catch let e as ToolRouterError {
            if case .invalidArguments = e { /* ok */ } else {
                throw TestError.assertion("expected invalidArguments, got \(e)")
            }
        }
    }

    // MARK: - Wave 2: export / import / consolidation / client source

    await test("MemoryStore: exportJSON round-trips through importJSON") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "export me", scope: "global", source: "t")
        let json = try await store.exportJSON()
        let (store2, url2) = makeTempStore()
        defer { Task { await store2.close(); cleanup(url2) } }
        let result = try await store2.importJSON(json)
        try expect(result.imported == 1 && result.skipped == 0, "import should land one row")
        let recalled = try await store2.recall(query: "export", scope: "global", entity: nil, limit: 5)
        try expect(recalled.count == 1, "imported memory must be recallable")
    }

    await test("MemoryStore: importJSON skips duplicate contentHash in same scope") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        _ = try await store.remember(text: "dup check", scope: "mac", source: "t")
        let json = try await store.exportJSON()
        let result = try await store.importJSON(json)
        try expect(result.imported == 0 && result.skipped == 1, "duplicate must skip")
    }

    await test("MemoryStore: consolidationSweep tombstones stale reference rows") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }
        let staleSeconds = 60.0 * 60 * 24 * 90 + 3600
        let staleDate = Date().addingTimeInterval(-staleSeconds)
        let staleRef = MemoryEntry(
            scope: "global", text: "old ref link", type: .reference,
            lastUsedAt: staleDate, source: "test", contentHash: "stale-ref-hash"
        )
        let envelope = MemoryStore.ExportEnvelope(entries: [staleRef])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(envelope), encoding: .utf8)!
        _ = try await store.importJSON(json)

        let pinned = try await store.remember(text: "pinned ref", scope: "global", type: .reference, source: "t")
        try await store.pin(id: pinned.id, true)

        let report = try await store.consolidationSweep(now: Date())
        try expect(report.referenceDemoted == 1, "stale reference must demote once, got \(report.referenceDemoted)")
        let gone = try await store.recall(query: "old ref link", scope: "global", entity: nil, limit: 5)
        try expect(!gone.contains { $0.text == "old ref link" }, "tombstoned reference must not recall")
        let stillLive = try await store.recall(query: "pinned", scope: "global", entity: nil, limit: 5)
        try expect(stillLive.contains { $0.id == pinned.id }, "pinned reference must survive sweep")
    }

    await test("MemoryModule.argumentsWithClientSource injects client when source omitted") {
        let args = MemoryModule.argumentsWithClientSource(.object(["text": .string("x")]), clientName: "cursor-vscode")
        try expect(memObjField(args, "source") == .string("cursor-vscode"))
        let kept = MemoryModule.argumentsWithClientSource(
            .object(["text": .string("x"), "source": .string("explicit")]),
            clientName: "cursor-vscode"
        )
        try expect(memObjField(kept, "source") == .string("explicit"), "explicit source must win")
    }
}
