// MemoryRoutingAppendixTests.swift — PKT-MEM-115 scopedMemory appendix
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runMemoryRoutingAppendixTests() async {
    print("\n[MemoryRoutingAppendix]")

    await test("ScopeMap: focus-keepr maps to project + global") {
        let scopes = MemoryRoutingScopeMap.scopes(for: "focus-keepr")
        try expect(scopes == ["project", "global"], "got \(scopes)")
    }

    await test("ScopeMap: project-keepr alias maps to project + global") {
        let scopes = MemoryRoutingScopeMap.scopes(for: "project-keepr")
        try expect(scopes == ["project", "global"], "got \(scopes)")
    }

    await test("ScopeMap: unknown parent falls back to global") {
        let scopes = MemoryRoutingScopeMap.scopes(for: "unknown-keeper")
        try expect(scopes == ["global"], "got \(scopes)")
    }

    await test("ScopeMap: parentSlug strips child path") {
        try expect(MemoryRoutingScopeMap.parentSlug(from: "mac-keepr/files") == "mac-keepr")
    }

    await test("ScopeMap: entity hint denylist drops common verbs") {
        let hint = MemoryRoutingScopeMap.extractEntityHint(
            from: "make install copy bridge build",
            scopes: ["mac"],
            liveEntities: []
        )
        try expect(hint == nil, "denylisted tokens should not produce entity, got \(String(describing: hint))")
    }

    await test("ScopeMap: entity hint prefers live entity match") {
        let hint = MemoryRoutingScopeMap.extractEntityHint(
            from: "install the-bridge copy",
            scopes: ["mac"],
            liveEntities: ["the-bridge"]
        )
        try expect(hint == "the-bridge", "got \(String(describing: hint))")
    }

    await test("RowFormatter: includes source and created date") {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let entry = MemoryEntry(
            scope: "mac", entity: "the-bridge", text: "Use make install-copy",
            type: .fact, pinned: false, useCount: 2,
            createdAt: now, lastUsedAt: now, source: "cursor", contentHash: "h"
        )
        let row = MemoryRowFormatter.rowLine(entry)
        try expect(row.contains("source: cursor"), "row must include source; got \(row)")
        try expect(row.contains("used 2×"), "row must include use count; got \(row)")
        try expect(row.contains("the-bridge"), "row must include entity; got \(row)")
    }

    await test("Appendix: omits scopedMemory when no hits") {
        let store = try await makeTempMemoryStore()
        defer { Task { await store.close() } }
        let base: Value = .object(["name": .string("mac-keepr"), "content": .string("body")])
        let out = await MemoryRoutingAppendix.attach(to: base, parent: "mac-keepr", intent: "install", store: store)
        guard case .object(let obj) = out else {
            try expect(false, "expected object envelope")
            return
        }
        try expect(obj["scopedMemory"] == nil, "must omit scopedMemory on zero hits")
    }

    await test("Appendix: attaches scopedMemory for mac scope recall") {
        let store = try await makeTempMemoryStore()
        defer { Task { await store.close() } }
        _ = try await store.remember(
            text: "Use make install-copy for agent sessions",
            scope: "mac",
            type: .fact,
            source: "cursor"
        )
        let base: Value = .object(["name": .string("mac-keepr"), "content": .string("body")])
        let out = await MemoryRoutingAppendix.attach(
            to: base,
            parent: "mac-keepr",
            intent: "make install-copy",
            store: store
        )
        guard case .object(let obj) = out,
              case .object(let appendix)? = obj["scopedMemory"] else {
            try expect(false, "expected scopedMemory object")
            return
        }
        guard case .string(let markdown)? = appendix["markdown"] else {
            try expect(false, "expected markdown string")
            return
        }
        try expect(markdown.contains("make install-copy"), "markdown must include memory text")
        try expect(markdown.contains("source: cursor"), "markdown must include provenance")
    }

    await test("Appendix: post-cache freshness — second attach sees new row") {
        let store = try await makeTempMemoryStore()
        defer { Task { await store.close() } }
        let base: Value = .object(["name": .string("mac-keepr"), "content": .string("cached")])
        let first = await MemoryRoutingAppendix.attach(to: base, parent: "mac-keepr", intent: "zzznomatch", store: store)
        guard case .object(let firstObj) = first else {
            try expect(false, "first attach failed")
            return
        }
        try expect(firstObj["scopedMemory"] == nil, "no memory yet")

        _ = try await store.remember(text: "Fresh fact after cache", scope: "mac", type: .fact, source: "test")
        let second = await MemoryRoutingAppendix.attach(to: base, parent: "mac-keepr", intent: "", store: store)
        guard case .object(let secondObj) = second,
              case .object(let appendix)? = secondObj["scopedMemory"],
              case .string(let markdown)? = appendix["markdown"] else {
            try expect(false, "second attach should include new memory")
            return
        }
        try expect(markdown.contains("Fresh fact after cache"), "appendix must reflect post-cache insert")
    }

    await test("Appendix: skips error envelopes") {
        let store = try await makeTempMemoryStore()
        defer { Task { await store.close() } }
        let err: Value = .object(["error": .string("nope")])
        let out = await MemoryRoutingAppendix.attach(to: err, parent: "mac-keepr", intent: nil, store: store)
        guard case .object(let obj) = out else {
            try expect(false, "expected object")
            return
        }
        try expect(obj["scopedMemory"] == nil, "must not attach to error envelopes")
        try expect(obj["error"] != nil, "error key preserved")
    }
}

private func makeTempMemoryStore() async throws -> MemoryStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-memory-appendix-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("memory.sqlite")
    let store = MemoryStore(path: url, embedder: StubMemoryEmbedder())
    try await store.open()
    return store
}
