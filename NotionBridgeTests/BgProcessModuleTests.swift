// BgProcessModuleTests.swift — PKT-744 (Bridge v2.2 · 1.1)
// Coverage for BgProcessRuntime + BgProcessModule (dev/bg_process_*).
//
// All tests run hermetically against a per-test temp baseDir so they cannot
// collide with the production ~/Library/Application Support/NotionBridge/jobs/
// directory or with each other.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - Helpers

private func makeTempBaseDir(_ tag: String = "bg") -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NotionBridgeTests-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Poll the runtime until `predicate` is true, up to `timeoutSec` seconds.
private func pollUntil(
    timeoutSec: Double,
    pollIntervalMs: UInt64 = 50,
    _ predicate: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if try await predicate() { return true }
        try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
    }
    return try await predicate()
}

private func waitForTerminal(
    _ runtime: BgProcessRuntime,
    id: String,
    timeoutSec: Double = 10
) async throws -> BgProcessJobMeta {
    _ = await pollUntil(timeoutSec: timeoutSec) {
        let m = try? await runtime.status(id: id)
        return (m?.status ?? .running) != .running
    }
    return try await runtime.status(id: id)
}

func runBgProcessModuleTests() async {
    print("\n\u{1F500} BgProcessModule Tests (PKT-744 v2.2 · 1.1)")

    // ------------------------------------------------------------------
    // 1) Tool registration: 5 tools, module = "dev", tier = .request
    // ------------------------------------------------------------------
    await test("BgProcessModule registers 5 tools under module=\"dev\"") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("reg"))
        await BgProcessModule.register(on: router, runtime: runtime)
        let regs = await router.registrations(forModule: "dev")
        let names = Set(regs.map { $0.name })
        let expected: Set<String> = [
            "bg_process_start",
            "bg_process_status",
            "bg_process_logs",
            "bg_process_kill",
            "bg_process_list",
        ]
        try expect(expected.isSubset(of: names),
            "missing tools — got \(names.sorted())")
        await runtime.purgeAll()
    }

    await test("bg_process_* tier policy: list .open, control .request (FB-5)") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("tier"))
        await BgProcessModule.register(on: router, runtime: runtime)
        let regs = await router.registrations(forModule: "dev")
        let bgRegs = regs.filter { $0.name.hasPrefix("bg_process_") }
        try expect(bgRegs.count >= 5, "expected >=5 bg_process_* tools, got \(bgRegs.count)")
        // FB-5: read-only bg_process_list is .open; process-control tools .request.
        for r in bgRegs {
            if r.name == "bg_process_list" {
                try expect(r.tier == .open,
                    "\(r.name) tier expected .open, got \(r.tier.rawValue)")
            } else {
                try expect(r.tier == .request,
                    "\(r.name) tier expected .request, got \(r.tier.rawValue)")
            }
        }
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 2) Capability check is OK on macOS
    // ------------------------------------------------------------------
    await test("capabilityCheck is OK with writable temp baseDir") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("cap"))
        let cap = await runtime.capabilityCheck()
        try expect(cap.ok, "capability missing: \(cap.reason ?? "unknown")")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 3) start() returns valid meta (id, pid, pgid, status=running)
    // ------------------------------------------------------------------
    await test("start returns valid meta with id, pid, pgid, status=running") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("start"))
        let meta = try await runtime.start(command: "sleep 1", label: "unit-test")
        try expect(!meta.id.isEmpty, "id should not be empty")
        try expect(meta.pid > 0, "pid should be positive, got \(meta.pid)")
        try expect(meta.pgid == meta.pid,
            "pgid expected to equal pid (POSIX_SPAWN_SETPGROUP w/ pgrp=0); got pgid=\(meta.pgid) pid=\(meta.pid)")
        try expect(meta.status == .running, "expected .running, got \(meta.status.rawValue)")
        try expect(meta.label == "unit-test")
        // Drain by waiting for terminal.
        _ = try await waitForTerminal(runtime, id: meta.id)
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 4) Lifecycle: short echo command -> done with exitCode 0
    // ------------------------------------------------------------------
    await test("lifecycle: echo command -> done with exitCode 0") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("echo"))
        let meta = try await runtime.start(command: "echo hello-bg")
        let final = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        try expect(final.status == .done, "expected .done, got \(final.status.rawValue)")
        try expect(final.exitCode == 0, "expected exitCode=0, got \(String(describing: final.exitCode))")
        try expect(final.endedAt != nil, "endedAt should be set")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 5) Lifecycle: nonzero exit -> failed
    // ------------------------------------------------------------------
    await test("lifecycle: exit 7 -> failed with exitCode 7") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("fail"))
        let meta = try await runtime.start(command: "exit 7")
        let final = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        try expect(final.status == .failed, "expected .failed, got \(final.status.rawValue)")
        try expect(final.exitCode == 7, "expected exitCode=7, got \(String(describing: final.exitCode))")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 6) Long-running lifecycle: sleep 2 -> done (exceeds typical request budget)
    // ------------------------------------------------------------------
    await test("long-running sleep 2 lifecycle completes as done") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("long"))
        let meta = try await runtime.start(command: "sleep 2 && echo ok")
        // Status should still be running shortly after start.
        let mid = try await runtime.status(id: meta.id)
        try expect(mid.status == .running, "mid-run status should be running, got \(mid.status.rawValue)")
        let final = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 8)
        try expect(final.status == .done, "expected .done, got \(final.status.rawValue)")
        try expect(final.exitCode == 0)
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 7) Kill cascade: SIGTERM -> killed
    // ------------------------------------------------------------------
    await test("kill SIGTERM transitions running -> killed") {
        let runtime = BgProcessRuntime(
            baseDir: makeTempBaseDir("kill"),
            killGracePeriodSec: 1
        )
        let meta = try await runtime.start(command: "sleep 30")
        // brief delay so the child is fully resident
        try? await Task.sleep(nanoseconds: 100_000_000)
        let killed = try await runtime.kill(id: meta.id, force: false)
        try expect(killed.killSignal != nil, "killSignal should be set after kill()")
        let final = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        try expect(final.status == .killed,
            "expected .killed, got \(final.status.rawValue) (signal=\(String(describing: final.killSignal)))")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 8) Logs pagination by byte cursor
    // ------------------------------------------------------------------
    await test("logs pagination via cursor + n returns sequential bytes") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("logs"))
        // Produce ~600 bytes deterministically.
        let meta = try await runtime.start(
            command: "for i in $(seq 1 40); do printf 'line-%02d-payload\\n' \"$i\"; done"
        )
        let final = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        try expect(final.status == .done)

        // First page: 100 bytes from offset 0.
        let p1 = try await runtime.logs(id: meta.id, stream: "stdout", cursor: 0, n: 100)
        try expect(p1.cursor == 0, "first cursor expected 0, got \(p1.cursor)")
        try expect(p1.bytes == 100, "expected 100 bytes, got \(p1.bytes)")
        try expect(p1.totalBytes >= 600, "expected totalBytes>=600, got \(p1.totalBytes)")
        try expect(!p1.eof, "first page should not be EOF")
        try expect(p1.nextCursor == 100)

        // Second page from p1.nextCursor.
        let p2 = try await runtime.logs(id: meta.id, stream: "stdout", cursor: p1.nextCursor, n: 100)
        try expect(p2.cursor == 100)
        try expect(p2.bytes == 100)

        // Concatenation should match a single big read.
        let big = try await runtime.logs(id: meta.id, stream: "stdout", cursor: 0, n: 200)
        try expect(big.text == p1.text + p2.text, "paginated reads should equal contiguous read")
        await runtime.purgeAll()
    }

    await test("logs invalid stream rejected") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("logs2"))
        let meta = try await runtime.start(command: "echo hi")
        _ = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        do {
            _ = try await runtime.logs(id: meta.id, stream: "banana", cursor: 0, n: 16)
            throw TestError.assertion("expected invalid stream to throw")
        } catch {
            // expected
        }
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 9) list() filter by status
    // ------------------------------------------------------------------
    await test("list filter by status returns only matching jobs") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("list-status"))
        let done1 = try await runtime.start(command: "true")
        let done2 = try await runtime.start(command: "echo done2")
        _ = try await waitForTerminal(runtime, id: done1.id, timeoutSec: 5)
        _ = try await waitForTerminal(runtime, id: done2.id, timeoutSec: 5)
        let running = try await runtime.start(command: "sleep 5")

        let runningOnly = await runtime.list(filter: .running, label: nil)
        try expect(runningOnly.contains(where: { $0.id == running.id }))
        try expect(!runningOnly.contains(where: { $0.id == done1.id }))
        try expect(!runningOnly.contains(where: { $0.id == done2.id }))

        let doneOnly = await runtime.list(filter: .done, label: nil)
        try expect(doneOnly.contains(where: { $0.id == done1.id }))
        try expect(doneOnly.contains(where: { $0.id == done2.id }))
        try expect(!doneOnly.contains(where: { $0.id == running.id }))

        // Cleanup the still-running job before purge.
        _ = try? await runtime.kill(id: running.id, force: true)
        _ = try await waitForTerminal(runtime, id: running.id, timeoutSec: 5)
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 10) list() filter by label
    // ------------------------------------------------------------------
    await test("list filter by label returns only matching jobs") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("list-label"))
        let a = try await runtime.start(command: "true", label: "alpha")
        let b = try await runtime.start(command: "true", label: "beta")
        let c = try await runtime.start(command: "true", label: "alpha")
        _ = try await waitForTerminal(runtime, id: a.id, timeoutSec: 5)
        _ = try await waitForTerminal(runtime, id: b.id, timeoutSec: 5)
        _ = try await waitForTerminal(runtime, id: c.id, timeoutSec: 5)

        let alphas = await runtime.list(filter: nil, label: "alpha")
        let alphaIds = Set(alphas.map { $0.id })
        try expect(alphaIds.contains(a.id))
        try expect(alphaIds.contains(c.id))
        try expect(!alphaIds.contains(b.id))
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 11) Atomic meta.json round-trip via list() / status() after start
    // ------------------------------------------------------------------
    await test("meta.json round-trips via list and status after start") {
        let baseDir = makeTempBaseDir("meta")
        let runtime = BgProcessRuntime(baseDir: baseDir)
        let meta = try await runtime.start(command: "echo persisted", label: "persist")
        // meta.json should already be on disk while job is still tracked.
        let metaURL = baseDir.appendingPathComponent(meta.id, isDirectory: true)
            .appendingPathComponent("meta.json")
        try expect(FileManager.default.fileExists(atPath: metaURL.path),
            "meta.json missing at \(metaURL.path)")

        // Construct a fresh runtime against the same baseDir and confirm status reads back.
        let runtime2 = BgProcessRuntime(baseDir: baseDir)
        // Allow first runtime to drain.
        _ = try await waitForTerminal(runtime, id: meta.id, timeoutSec: 5)
        let viaStatus = try await runtime2.status(id: meta.id)
        try expect(viaStatus.id == meta.id)
        try expect(viaStatus.command == "echo persisted")
        try expect(viaStatus.label == "persist")
        let viaList = await runtime2.list(filter: nil, label: nil)
        try expect(viaList.contains(where: { $0.id == meta.id }))
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 12) Orphan reconciliation: bogus pid -> status flips to .unknown
    // ------------------------------------------------------------------
    await test("reconcileOrphans flips dead-pid running jobs to .unknown") {
        let baseDir = makeTempBaseDir("orphan")
        let runtime = BgProcessRuntime(baseDir: baseDir)
        // Hand-craft a meta.json with an absurd pid that is guaranteed to be dead.
        let id = "19990101-000000-deadbeef"
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stdout").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stderr").path, contents: Data())
        let bogusMeta = BgProcessJobMeta(
            id: id,
            pid: 2_147_483_640,  // far above any real pid
            pgid: 2_147_483_640,
            command: "# fake-orphan",
            workingDir: nil,
            label: "orphan-test",
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: nil,
            exitCode: nil,
            status: .running,
            killSignal: nil,
            lastReconcileAt: nil,
            note: nil
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(bogusMeta)
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        let result = await runtime.reconcileOrphans(now: Date())
        try expect(result.reconciled >= 1, "expected reconciled >=1, got \(result.reconciled)")
        let after = try await runtime.status(id: id)
        try expect(after.status == .unknown,
            "expected .unknown after reconcile, got \(after.status.rawValue)")
        try expect(after.lastReconcileAt != nil, "lastReconcileAt should be stamped")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 13) reconcileOrphans cleans up old terminal jobs (cleanupTTL)
    // ------------------------------------------------------------------
    await test("reconcileOrphans cleans terminal jobs older than cleanupTTL") {
        let baseDir = makeTempBaseDir("cleanup")
        // Tiny TTL so we can synthesize a stale terminal job.
        let runtime = BgProcessRuntime(baseDir: baseDir, cleanupTTL: 60)
        let id = "19990101-000000-cafebabe"
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stdout").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stderr").path, contents: Data())
        let staleMeta = BgProcessJobMeta(
            id: id,
            pid: 1,
            pgid: 1,
            command: "# stale-terminal",
            workingDir: nil,
            label: nil,
            startedAt: Date().addingTimeInterval(-7200),
            endedAt: Date().addingTimeInterval(-7200),
            exitCode: 0,
            status: .done,
            killSignal: nil,
            lastReconcileAt: nil,
            note: nil
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(staleMeta)
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        let result = await runtime.reconcileOrphans(now: Date())
        try expect(result.cleaned >= 1, "expected cleaned >=1, got \(result.cleaned)")
        try expect(!FileManager.default.fileExists(atPath: dir.path),
            "job dir should have been removed")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 14) Empty / invalid command rejected
    // ------------------------------------------------------------------
    await test("start rejects empty command") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("empty"))
        do {
            _ = try await runtime.start(command: "   ")
            throw TestError.assertion("expected empty command to throw")
        } catch {
            // expected
        }
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // 15) status() throws notFound for unknown id
    // ------------------------------------------------------------------
    await test("status throws notFound for unknown id") {
        let runtime = BgProcessRuntime(baseDir: makeTempBaseDir("notfound"))
        do {
            _ = try await runtime.status(id: "this-id-does-not-exist")
            throw TestError.assertion("expected notFound to throw")
        } catch {
            // expected
        }
        await runtime.purgeAll()
    }
}
