// SessionPersistenceTests.swift — ITEM [session] MCP session durability
// NotionBridge · Tests
//
// Covers the server-side session-durability slice:
//   • SessionPersistenceStore: upsert/touch/remove round-trip, atomic-write
//     durability across a fresh store instance (the "restart" simulation),
//     corrupt-file recovery, clean-shutdown marker + dirty-run liveness, and
//     the resume lookup decision (unknown vs resumable / clean vs unclean).
//   • SSEServer.resumableReconnectResponse: the pure 404 + resume-signal
//     response builder (header + stable reason token; clean vs unclean phrasing).
//   • recordCleanShutdownSync: the synchronous applicationWillTerminate
//     fallback preserves rows + stamps the clean marker.

import Foundation
import MCP
import NotionBridgeLib

func runSessionPersistenceTests() async {
    print("\n🔧 Session Persistence / Durability Tests")

    // Each test gets a private temp store URL so nothing touches the real
    // on-disk durability snapshot.
    func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active-sessions.json", isDirectory: false)
    }

    // MARK: - Store round-trip + restart durability

    await test("upsert persists a session that survives a fresh store (restart)") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(
            sessionID: "sess-A",
            clientName: "Cursor",
            clientVersion: "1.2.3",
            transport: "streamable-http",
            protocolVersion: "2025-06-18"
        ))
        let firstCount = await store.count
        try expect(firstCount == 1, "expected 1 persisted, got \(firstCount)")

        // Simulate an app restart: a brand-new store instance over the same URL.
        let reloaded = SessionPersistenceStore(storeURL: url)
        let persisted = await reloaded.persistedSessions()
        try expect(persisted.count == 1, "session did not survive restart")
        try expect(persisted.first?.sessionID == "sess-A", "wrong session id reloaded")
        try expect(persisted.first?.clientName == "Cursor", "client name not preserved")
    }

    await test("upsert is idempotent by sessionID (no duplicate rows)") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "dup", transport: "streamable-http"))
        await store.upsert(PersistedSession(sessionID: "dup", clientName: "renamed", transport: "streamable-http"))
        let count = await store.count
        try expect(count == 1, "expected dedup to 1 row, got \(count)")
        let row = await store.persistedSessions().first
        try expect(row?.clientName == "renamed", "upsert should refresh existing row")
    }

    await test("remove drops a session from the durable snapshot") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "x", transport: "streamable-http"))
        await store.upsert(PersistedSession(sessionID: "y", transport: "streamable-http"))
        await store.remove(sessionID: "x")
        let ids = await store.persistedSessions().map(\.sessionID)
        try expect(ids == ["y"], "remove left wrong rows: \(ids)")

        // Removal persists across restart.
        let reloaded = SessionPersistenceStore(storeURL: url)
        let reloadedIDs = await reloaded.persistedSessions().map(\.sessionID)
        try expect(reloadedIDs == ["y"], "removal not durable: \(reloadedIDs)")
    }

    await test("touch updates lastAccessedAt and persists") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        await store.upsert(PersistedSession(
            sessionID: "t",
            transport: "streamable-http",
            createdAt: t0,
            lastAccessedAt: t0
        ))
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        await store.touch(sessionID: "t", at: t1)
        let reloaded = SessionPersistenceStore(storeURL: url)
        let row = await reloaded.persistedSessions().first
        try expect(row?.lastAccessedAt == t1, "touch did not persist new timestamp")
        try expect(row?.createdAt == t0, "touch must not alter createdAt")
    }

    await test("touch on unknown id is a safe no-op") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.touch(sessionID: "never-existed")
        let count = await store.count
        try expect(count == 0, "touch must not create a row")
    }

    // MARK: - Corrupt-file recovery

    await test("corrupt snapshot recovers to empty + preserves the bad file") {
        let url = tempStoreURL()
        try Data("{ this is not json".utf8).write(to: url)
        let store = SessionPersistenceStore(storeURL: url)
        let count = await store.count
        try expect(count == 0, "corrupt file should recover to empty store")
        // A .corrupt-* backup should exist alongside.
        let dir = url.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try expect(entries.contains { $0.contains("corrupt-") }, "corrupt backup not preserved: \(entries)")
    }

    // MARK: - Resume lookup decision

    await test("resumeLookup returns .unknown for a never-seen id") {
        let store = SessionPersistenceStore(storeURL: tempStoreURL())
        let result = await store.resumeLookup(sessionID: "forged")
        try expect(result == .unknown, "expected .unknown, got \(result)")
    }

    await test("resumeLookup returns .resumable for a persisted id (unclean prior run)") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "r", clientName: "C", transport: "streamable-http"))
        // No clean shutdown recorded yet ⇒ cleanShutdown false.
        let result = await store.resumeLookup(sessionID: "r")
        guard case .resumable(let session, let clean) = result else {
            throw TestError.assertion("expected .resumable, got \(result)")
        }
        try expect(session.sessionID == "r", "wrong session in resume lookup")
        try expect(clean == false, "no marker ⇒ cleanShutdown should be false")
    }

    await test("resumeLookup reports clean=true after a clean shutdown") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "r2", transport: "streamable-http"))
        await store.recordCleanShutdown(reason: "server stop")
        // Clean shutdown preserves rows.
        let count = await store.count
        try expect(count == 1, "clean shutdown must preserve rows for resume")
        let result = await store.resumeLookup(sessionID: "r2")
        guard case .resumable(_, let clean) = result else {
            throw TestError.assertion("expected .resumable, got \(result)")
        }
        try expect(clean == true, "clean marker ⇒ cleanShutdown should be true")
    }

    // MARK: - Clean-shutdown marker + dirty-run liveness

    await test("fresh store with no writes reports prior run ended cleanly") {
        let store = SessionPersistenceStore(storeURL: tempStoreURL())
        let clean = await store.priorRunEndedCleanly()
        try expect(clean == true, "a fresh store has no dirty run")
    }

    await test("dirty run (a write, no clean shutdown) reports unclean after restart") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "live", transport: "streamable-http"))
        // Simulate a CRASH: no recordCleanShutdown; reload.
        let reloaded = SessionPersistenceStore(storeURL: url)
        let clean = await reloaded.priorRunEndedCleanly()
        try expect(clean == false, "a dirty run with no clean marker is unclean")
    }

    await test("clean shutdown then restart reports prior run ended cleanly") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "live", transport: "streamable-http"))
        await store.recordCleanShutdown(reason: "server stop")
        let reloaded = SessionPersistenceStore(storeURL: url)
        let clean = await reloaded.priorRunEndedCleanly()
        try expect(clean == true, "clean shutdown should be reported as clean")
        let marker = await reloaded.lastShutdownMarker()
        try expect(marker?.cleanlyEnded == true, "marker.cleanlyEnded should be true")
        try expect(marker?.activeSessionsAtShutdown == 1, "marker should record active count")
    }

    await test("recordCleanShutdownSync preserves rows and stamps clean marker") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "sync-A", transport: "streamable-http"))
        await store.upsert(PersistedSession(sessionID: "sync-B", transport: "streamable-http"))
        // The synchronous applicationWillTerminate fallback.
        SessionPersistenceStore.recordCleanShutdownSync(reason: "app quit", url: url)
        let reloaded = SessionPersistenceStore(storeURL: url)
        let count = await reloaded.count
        try expect(count == 2, "sync marker must preserve rows, got \(count)")
        let clean = await reloaded.priorRunEndedCleanly()
        try expect(clean == true, "sync marker should stamp clean")
        // A reconnect still resolves to resumable+clean.
        let result = await reloaded.resumeLookup(sessionID: "sync-A")
        guard case .resumable(_, let isClean) = result, isClean else {
            throw TestError.assertion("post-sync reconnect should be .resumable(clean), got \(result)")
        }
    }

    await test("clearAllSessions empties the durable snapshot") {
        let url = tempStoreURL()
        let store = SessionPersistenceStore(storeURL: url)
        await store.upsert(PersistedSession(sessionID: "a", transport: "streamable-http"))
        await store.upsert(PersistedSession(sessionID: "b", transport: "streamable-http"))
        await store.clearAllSessions()
        let count = await store.count
        try expect(count == 0, "clearAllSessions should empty rows")
    }

    // MARK: - Resumable reconnect response builder (pure)

    await test("resumableReconnectResponse is a 404 carrying the resume header + reason") {
        let resp = SSEServer.resumableReconnectResponse(priorSessionID: "abc-123", cleanShutdown: true)
        try expect(resp.statusCode == 404, "resumable reconnect is still a 404, got \(resp.statusCode)")
        let headers = resp.headers
        try expect(headers[SSEServer.resumableHeaderName] == "true",
                   "missing resumable header: \(headers)")
        try expect(headers[SSEServer.priorSessionHeaderName] == "abc-123",
                   "prior session id not echoed: \(headers)")
        // The stable reason token must appear in the JSON-RPC error message.
        let body = resp.bodyData ?? Data()
        let text = String(data: body, encoding: .utf8) ?? ""
        try expect(text.contains(SSEServer.resumeSignalReason),
                   "resume reason token missing from body: \(text)")
    }

    await test("resumableReconnectResponse distinguishes clean vs unclean restart") {
        let clean = SSEServer.resumableReconnectResponse(priorSessionID: "s", cleanShutdown: true)
        let unclean = SSEServer.resumableReconnectResponse(priorSessionID: "s", cleanShutdown: false)
        let cleanText = String(data: clean.bodyData ?? Data(), encoding: .utf8) ?? ""
        let uncleanText = String(data: unclean.bodyData ?? Data(), encoding: .utf8) ?? ""
        try expect(cleanText.contains("restarted"), "clean phrasing missing: \(cleanText)")
        try expect(uncleanText.contains("unexpected"), "unclean phrasing missing: \(uncleanText)")
        // Both still carry the recoverable signal.
        try expect(clean.headers[SSEServer.resumableHeaderName] == "true", "clean missing resumable header")
        try expect(unclean.headers[SSEServer.resumableHeaderName] == "true", "unclean missing resumable header")
    }

    await test("the resumable signal is distinct from the opaque hard-404 message") {
        // The hard-404 (truly unknown id) message is the literal
        // "Session not found or expired"; the resumable one must NOT be that.
        let resumable = SSEServer.resumableReconnectResponse(priorSessionID: "p", cleanShutdown: false)
        let text = String(data: resumable.bodyData ?? Data(), encoding: .utf8) ?? ""
        try expect(!text.contains("Session not found or expired"),
                   "resumable response must not reuse the opaque hard-404 message")
        try expect(text.contains("Re-initialize"),
                   "resumable response should instruct the client to re-initialize")
    }
}
