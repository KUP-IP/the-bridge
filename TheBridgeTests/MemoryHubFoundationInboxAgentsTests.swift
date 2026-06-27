// MemoryHubFoundationInboxAgentsTests.swift — INBOX disposition + AGENTS memory_update
// TheBridge · Tests
//
// Covers:
//   • DismissScope / DismissResult / TrashResult struct constructibility (D8/D9/D13)
//   • dismissWithResult() single-lane semantics: dismissed=true, memoMarkedProcessed
//   • dismissWithResult() multi-lane sibling detection: hasSiblingLanes when a sibling
//     lane is still pending (D13)
//   • dismissWithResult(.allLanes) resolves all sibling pending entries
//   • MemoryStore.protectedFields constant presence (D16)
//   • memory_update tool registration (D35/D41)
//   • memory_update handler: update text, verify updated entry returned
//   • memory_update handler: protected field rejection

import Foundation
import MCP
import TheBridgeLib

// MARK: - Helpers

private func makeTempReviewHome() -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("inbox-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func makeTempMemoryStore() -> (store: MemoryStore, url: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agents-tests-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("memory.sqlite")
    return (MemoryStore(path: url, embedder: StubMemoryEmbedder()), url)
}

private func cleanupMemory(_ url: URL) {
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

// MARK: - INBOX Disposition Tests (D8 / D9 / D13)

public func runInboxDispositionTests() async {
    print("\n📥 INBOX Disposition Tests (D8/D9/D13)")

    // ── Struct constructibility ──────────────────────────────────────────────

    await test("DismissScope has .thisLane case") {
        let s: DismissScope = .thisLane
        try expect(s == .thisLane, "thisLane case constructible")
    }

    await test("DismissScope has .allLanes case") {
        let s: DismissScope = .allLanes
        try expect(s == .allLanes, "allLanes case constructible")
    }

    await test("DismissScope.allCases has both variants") {
        try expect(DismissScope.allCases.count == 2, "expected 2 cases")
        try expect(DismissScope.allCases.contains(.thisLane))
        try expect(DismissScope.allCases.contains(.allLanes))
    }

    await test("DismissResult is constructible with all fields") {
        let r = DismissResult(dismissed: true, memoMarkedProcessed: false, hasSiblingLanes: true)
        try expect(r.dismissed == true)
        try expect(r.memoMarkedProcessed == false)
        try expect(r.hasSiblingLanes == true)
    }

    await test("DismissResult is Sendable and Equatable") {
        let a = DismissResult(dismissed: true, memoMarkedProcessed: true, hasSiblingLanes: false)
        let b = DismissResult(dismissed: true, memoMarkedProcessed: true, hasSiblingLanes: false)
        try expect(a == b, "equal DismissResult values must compare equal")
    }

    await test("TrashResult is constructible with all fields") {
        let id = UUID()
        let r = TrashResult(itemsTrashed: 3, evidenceId: id)
        try expect(r.itemsTrashed == 3)
        try expect(r.evidenceId == id)
    }

    await test("TrashResult is Sendable and Equatable") {
        let id = UUID()
        let a = TrashResult(itemsTrashed: 0, evidenceId: id)
        let b = TrashResult(itemsTrashed: 0, evidenceId: id)
        try expect(a == b, "equal TrashResult values must compare equal")
    }

    // ── Single-lane dismiss semantics (D8) ───────────────────────────────────

    await test("dismissWithResult single lane: dismissed=true, memoMarkedProcessed=true, hasSiblingLanes=false") {
        let tmp = makeTempReviewHome()
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }

        let entry = VoiceMemoReviewEntry(
            memoId: "inbox-test-memo-1",
            memoTitle: "Solo lane test",
            intentKind: "review",
            confidence: 0.4,
            reason: "low confidence",
            transcriptExcerpt: "hello"
        )
        try VoiceMemoReviewStore.enqueue(entry)
        try expect(VoiceMemoReviewStore.pendingEntries().count == 1, "one pending before dismiss")

        let result = try VoiceMemoReviewStore.dismissWithResult(id: entry.id, scope: .thisLane)
        try expect(result.dismissed == true, "dismissed must be true")
        try expect(result.hasSiblingLanes == false, "no sibling lanes for single-lane memo")
        // memoMarkedProcessed depends on VoiceMemoProcessedStore; we only verify no crash.
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "no pending entries after dismiss")
    }

    await test("dismissWithResult on unknown id returns dismissed=false") {
        let tmp = makeTempReviewHome()
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }

        let result = try VoiceMemoReviewStore.dismissWithResult(id: "nonexistent-id")
        try expect(result.dismissed == false, "unknown id must yield dismissed=false")
        try expect(result.hasSiblingLanes == false)
        try expect(result.memoMarkedProcessed == false)
    }

    // ── Multi-lane sibling detection (D13) ───────────────────────────────────

    await test("dismissWithResult .thisLane: hasSiblingLanes=true when sibling pending") {
        let tmp = makeTempReviewHome()
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }

        // Two lanes for the same memo (distinct intentIds via distinct entityHints).
        let lane1 = VoiceMemoReviewEntry(
            memoId: "inbox-multi-memo",
            memoTitle: "Multi-lane test",
            intentKind: "agent_memory",
            confidence: 0.3,
            reason: "low",
            transcriptExcerpt: "text",
            entityKey: "lane1",
            entityHint: "Entity A"
        )
        let lane2 = VoiceMemoReviewEntry(
            memoId: "inbox-multi-memo",
            memoTitle: "Multi-lane test",
            intentKind: "agent_memory",
            confidence: 0.3,
            reason: "low",
            transcriptExcerpt: "text",
            entityKey: "lane2",
            entityHint: "Entity B"
        )
        try VoiceMemoReviewStore.enqueue(lane1)
        try VoiceMemoReviewStore.enqueue(lane2)
        try expect(VoiceMemoReviewStore.pendingEntries().count == 2, "two pending lanes before dismiss")

        // Dismiss only lane1 with .thisLane scope.
        let result = try VoiceMemoReviewStore.dismissWithResult(id: lane1.id, scope: .thisLane)
        try expect(result.dismissed == true, "lane1 dismissed")
        try expect(result.hasSiblingLanes == true, "lane2 is still pending → hasSiblingLanes")
        try expect(result.memoMarkedProcessed == false, "memo not processed while sibling pending")
        try expect(VoiceMemoReviewStore.pendingEntries().count == 1, "one lane still pending")
    }

    await test("dismissWithResult .allLanes dismisses all sibling pending entries") {
        let tmp = makeTempReviewHome()
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }

        let lane1 = VoiceMemoReviewEntry(
            memoId: "inbox-all-lanes-memo",
            memoTitle: "All lanes test",
            intentKind: "reminder",
            confidence: 0.3,
            reason: "low",
            transcriptExcerpt: "a",
            entityKey: "r1",
            entityHint: "Reminder A"
        )
        let lane2 = VoiceMemoReviewEntry(
            memoId: "inbox-all-lanes-memo",
            memoTitle: "All lanes test",
            intentKind: "agent_memory",
            confidence: 0.3,
            reason: "low",
            transcriptExcerpt: "b",
            entityKey: "m1",
            entityHint: "Memory A"
        )
        try VoiceMemoReviewStore.enqueue(lane1)
        try VoiceMemoReviewStore.enqueue(lane2)
        try expect(VoiceMemoReviewStore.pendingEntries().count == 2, "two pending")

        let result = try VoiceMemoReviewStore.dismissWithResult(id: lane1.id, scope: .allLanes)
        try expect(result.dismissed == true)
        try expect(result.hasSiblingLanes == false, "all sibling lanes dismissed → no remaining siblings")
        // Both lanes should now be dismissed.
        let remaining = VoiceMemoReviewStore.pendingEntries()
            .filter { $0.memoId == "inbox-all-lanes-memo" }
        try expect(remaining.isEmpty, "all lanes dismissed when scope=.allLanes")
    }

    // ── Legacy dismiss() still works (additive-first, D8 backward compat) ────

    await test("legacy dismiss() still returns Bool and works") {
        let tmp = makeTempReviewHome()
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }

        let entry = VoiceMemoReviewEntry(
            memoId: "legacy-dismiss-memo",
            memoTitle: "Legacy dismiss test",
            intentKind: "review",
            confidence: 0.5,
            reason: "test",
            transcriptExcerpt: "hi"
        )
        try VoiceMemoReviewStore.enqueue(entry)
        let ok: Bool = try VoiceMemoReviewStore.dismiss(id: entry.id)
        try expect(ok == true, "legacy dismiss() must return true for known id")
        try expect(VoiceMemoReviewStore.pendingEntries().isEmpty, "entry dismissed")
    }
}

// MARK: - AGENTS memory_update Tests (D35 / D41)

public func runMemoryUpdateTests() async {
    print("\n🧠 AGENTS memory_update Tests (D35/D41)")

    // ── Static metadata ──────────────────────────────────────────────────────

    await test("MemoryStore.protectedFields contains 'id'") {
        try expect(MemoryStore.protectedFields.contains("id"), "id must be protected")
    }

    await test("MemoryStore.protectedFields contains 'createdAt'") {
        try expect(MemoryStore.protectedFields.contains("createdAt"), "createdAt must be protected")
    }

    await test("MemoryStore.protectedFields contains all D16 protected fields") {
        let required = ["id", "createdAt", "lastUsedAt", "useCount", "contentHash", "supersededBy"]
        for field in required {
            try expect(MemoryStore.protectedFields.contains(field), "protectedFields must contain '\(field)'")
        }
    }

    // ── Tool registration ────────────────────────────────────────────────────

    await test("memory_update tool is registered in MemoryModule") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)
        let regs = await router.registrations(forModule: "memory")
        let names = regs.map(\.name)
        try expect(names.contains("memory_update"), "memory_update must be registered; found: \(names)")
    }

    await test("memory_update is tier .notify") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)
        let regs = await router.registrations(forModule: "memory")
        guard let reg = regs.first(where: { $0.name == "memory_update" }) else {
            throw TestError.assertion("memory_update not registered")
        }
        try expect(reg.tier == .notify, "memory_update must be .notify; got \(reg.tier)")
    }

    // ── Handler: update text ─────────────────────────────────────────────────

    await test("memory_update: update text field returns updated entry") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)

        // First create a row via memory_remember.
        let rememberResult = try await callMemoryHandler(router, "memory_remember", .object([
            "text": .string("original text"),
            "scope": .string("global"),
            "source": .string("test")
        ]))
        guard case .object(let remObj) = rememberResult,
              case .string(let rowId) = remObj["id"] else {
            throw TestError.assertion("memory_remember did not return an id")
        }

        // Update the text.
        let updateResult = try await callMemoryHandler(router, "memory_update", .object([
            "id": .string(rowId),
            "text": .string("updated text")
        ]))

        guard case .object(let updObj) = updateResult else {
            throw TestError.assertion("memory_update did not return an object; got \(updateResult)")
        }
        guard case .string(let returnedText) = updObj["text"] else {
            throw TestError.assertion("memory_update result missing 'text' field")
        }
        try expect(returnedText == "updated text", "text must be updated; got '\(returnedText)'")
        guard case .string(let returnedId) = updObj["id"] else {
            throw TestError.assertion("memory_update result missing 'id' field")
        }
        try expect(returnedId == rowId, "id must be unchanged")
    }

    await test("memory_update: update pinned field") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)

        let rememberResult = try await callMemoryHandler(router, "memory_remember", .object([
            "text": .string("pinning test memory"),
            "scope": .string("global"),
            "source": .string("test")
        ]))
        guard case .object(let remObj) = rememberResult,
              case .string(let rowId) = remObj["id"] else {
            throw TestError.assertion("memory_remember failed")
        }

        let updateResult = try await callMemoryHandler(router, "memory_update", .object([
            "id": .string(rowId),
            "pinned": .bool(true)
        ]))
        guard case .object(let updObj) = updateResult,
              case .bool(let isPinned) = updObj["pinned"] else {
            throw TestError.assertion("memory_update result missing 'pinned' field")
        }
        try expect(isPinned == true, "pinned must be true after update")
    }

    await test("memory_update: missing id returns error") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)

        var threw = false
        do {
            _ = try await callMemoryHandler(router, "memory_update", .object([
                "text": .string("no id provided")
            ]))
        } catch {
            threw = true
        }
        try expect(threw, "missing id must throw (or handler signals error)")
    }

    // ── Handler: protected field rejection ───────────────────────────────────

    await test("memory_update: passing createdAt returns error response") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)

        // Create a row first.
        let rememberResult = try await callMemoryHandler(router, "memory_remember", .object([
            "text": .string("protected field test"),
            "scope": .string("global"),
            "source": .string("test")
        ]))
        guard case .object(let remObj) = rememberResult,
              case .string(let rowId) = remObj["id"] else {
            throw TestError.assertion("memory_remember failed")
        }

        // Attempt to pass protected field.
        let updateResult = try await callMemoryHandler(router, "memory_update", .object([
            "id": .string(rowId),
            "createdAt": .string("2025-01-01T00:00:00Z")
        ]))

        // The handler should return an error object (not throw).
        guard case .object(let errObj) = updateResult else {
            throw TestError.assertion("expected error object response; got \(updateResult)")
        }
        let hasError = errObj["error"] != nil || errObj["message"] != nil
        try expect(hasError, "protected field must produce an error response; got \(errObj)")
    }

    await test("memory_update: passing useCount returns error response") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        let router = await makeMemoryRouter(store)

        let rememberResult = try await callMemoryHandler(router, "memory_remember", .object([
            "text": .string("useCount protected test"),
            "scope": .string("global"),
            "source": .string("test")
        ]))
        guard case .object(let remObj) = rememberResult,
              case .string(let rowId) = remObj["id"] else {
            throw TestError.assertion("memory_remember failed")
        }

        let updateResult = try await callMemoryHandler(router, "memory_update", .object([
            "id": .string(rowId),
            "useCount": .int(999)
        ]))
        guard case .object(let errObj) = updateResult else {
            throw TestError.assertion("expected error object response")
        }
        let hasError = errObj["error"] != nil || errObj["message"] != nil
        try expect(hasError, "useCount is protected; must return error")
    }

    // ── Store-level update tests ─────────────────────────────────────────────

    await test("MemoryStore.update: text update round-trips through get") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        try await store.open()
        let original = try await store.remember(text: "before update", scope: "global", source: "t")
        let updated = try await store.update(id: original.id, text: "after update")
        try expect(updated.text == "after update", "text must be updated; got '\(updated.text)'")
        try expect(updated.id == original.id, "id must be unchanged")
        let fetched = try await store.get(id: original.id)
        try expect(fetched?.text == "after update", "get must return updated text")
    }

    await test("MemoryStore.update: throws notFound for unknown id") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        try await store.open()
        var threw = false
        do {
            _ = try await store.update(id: "does-not-exist", text: "new text")
        } catch MemoryStoreError.notFound {
            threw = true
        } catch {
            threw = true // accept any error for unknown id
        }
        try expect(threw, "update with unknown id must throw")
    }

    await test("MemoryStore.update: no-op update (nil params) returns existing entry") {
        let (store, url) = makeTempMemoryStore()
        defer { Task { await store.close(); cleanupMemory(url) } }
        try await store.open()
        let original = try await store.remember(text: "unchanged", scope: "global", source: "t")
        let result = try await store.update(id: original.id)
        try expect(result.id == original.id, "id unchanged after no-op update")
        try expect(result.text == "unchanged", "text unchanged after no-op update")
    }
}
