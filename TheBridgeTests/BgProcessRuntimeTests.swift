// BgProcessRuntimeTests.swift — v4 audit remediation #3 (PRJCT-2754)
// TheBridge · Tests
//
// First-ever coverage for the BgProcessRuntime actor (PKT-744): the async
// process-lifecycle primitive that owns posix_spawn children, per-job meta.json,
// the SIGTERM→SIGKILL kill cascade, orphan reconciliation on relaunch, and the
// terminal-job TTL sweep. These were entirely untested.
//
// HERMETIC: every test constructs its OWN runtime via the
// init(baseDir:cleanupTTL:killGracePeriodSec:) seam pointed at a throwaway temp
// dir — no shared singleton, no real ~/Library/Application Support, no network.
// Children are short (sleep ≤30s) and every test purges its runtime (cancels
// watchers + pending SIGKILL timers, removes the base dir) in teardown so no
// stray process or file survives.

import Foundation
import Darwin   // Darwin.kill / SIGKILL / SIGTERM for liveness probes + external-signal cases
import TheBridgeLib

// MARK: - Hermetic helpers

/// Run `body` against a fresh runtime rooted at a unique temp dir, then purge.
private func rtWithTemp(
    cleanupTTL: TimeInterval = 7 * 24 * 3600,
    killGracePeriodSec: Int = 5,
    _ body: (BgProcessRuntime, URL) async throws -> Void
) async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory
        .appendingPathComponent("BgRuntime-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let rt = BgProcessRuntime(baseDir: base, cleanupTTL: cleanupTTL, killGracePeriodSec: killGracePeriodSec)
    do {
        try await body(rt, base)
    } catch {
        await rt.purgeAll()
        try? fm.removeItem(at: base)
        throw error
    }
    await rt.purgeAll()
    try? fm.removeItem(at: base)
}

/// Encode a hand-built meta.json into <base>/<id>/meta.json using the SAME
/// encoder settings BgProcessRuntime.writeMeta uses (iso8601 dates), so the
/// runtime's readMeta decodes it back identically. Encoding the REAL struct (not
/// raw JSON) keeps the fixture correct if fields change.
private func seedMeta(_ meta: BgProcessJobMeta, baseDir: URL) throws {
    let dir = baseDir.appendingPathComponent(meta.id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(meta)
    try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
}

/// A PID that is guaranteed dead: spawn `/usr/bin/true`, wait for it to exit and
/// be reaped, then return its (now-defunct) pid. kill(pid, 0) on it returns ESRCH.
private func reapedDeadPid() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? p.run()
    p.waitUntilExit()
    // Process reaps the child in waitUntilExit, so this pid is now free.
    return p.processIdentifier
}

func runBgProcessRuntimeTests() async {
    print("\n\u{1F9F5} BgProcessRuntime Tests (kill cascade · reconcileOrphans · finalizeExit — v4 audit #3)")

    // 1) reconcileOrphans flips a dead status=.running job to .unknown.
    await test("reconcileOrphans: a .running job whose pid is dead flips to .unknown") {
        try await rtWithTemp { rt, base in
            let deadPid = reapedDeadPid()
            let id = "20200101-000000-deadbeef"
            try seedMeta(BgProcessJobMeta(
                id: id, pid: deadPid, pgid: deadPid, command: "sleep 999",
                workingDir: nil, label: nil, startedAt: Date(timeIntervalSinceNow: -120),
                status: .running
            ), baseDir: base)

            let summary = await rt.reconcileOrphans()
            try expect(summary.reconciled == 1, "expected 1 reconciled, got \(summary.reconciled)")
            try expect(summary.stillRunning == 0, "expected 0 stillRunning, got \(summary.stillRunning)")

            let meta = try await rt.status(id: id)
            try expect(meta.status == .unknown, "dead running job must reconcile to .unknown, got \(meta.status)")
            try expect(meta.endedAt != nil, "reconciled job must stamp endedAt")
            try expect(meta.lastReconcileAt != nil, "reconciled job must stamp lastReconcileAt")
        }
    }

    // 2) reconcileOrphans keeps a live job running + reattaches a watcher across
    //    a FRESH runtime over the same baseDir (simulating a Bridge relaunch).
    await test("reconcileOrphans: a live job stays running + watcher reattaches across a fresh runtime") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("BgRuntime-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Runtime A starts a real long-lived child.
        let rtA = BgProcessRuntime(baseDir: base, killGracePeriodSec: 1)
        var jobId = ""
        do {
            let meta = try await rtA.start(command: "sleep 30")
            jobId = meta.id
            try expect(meta.status == .running, "fresh job should be .running")
        } catch {
            await rtA.purgeAll(); try? fm.removeItem(at: base)
            throw error
        }

        // Runtime B is a brand-new actor over the SAME baseDir — it has no
        // in-memory watcher for the job. reconcileOrphans must see it live and
        // reattach a watcher so the eventual exit is still reaped.
        let rtB = BgProcessRuntime(baseDir: base, killGracePeriodSec: 1)
        do {
            let summary = await rtB.reconcileOrphans()
            try expect(summary.stillRunning == 1, "live job must be counted stillRunning, got \(summary.stillRunning)")
            try expect(summary.reconciled == 0, "live job must NOT be reconciled, got \(summary.reconciled)")
            let meta = try await rtB.status(id: jobId)
            try expect(meta.status == .running, "live job must remain .running after reconcile, got \(meta.status)")

            // Prove the reattached watcher finalizes the exit: kill via rtB and
            // poll meta until it leaves .running.
            _ = try await rtB.kill(id: jobId, force: true)
            var terminal = false
            for _ in 0..<60 {
                let m = try await rtB.status(id: jobId)
                if m.status != .running { terminal = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try expect(terminal, "reattached watcher must finalize the killed job out of .running")
        } catch {
            await rtA.purgeAll(); await rtB.purgeAll(); try? fm.removeItem(at: base)
            throw error
        }
        await rtA.purgeAll(); await rtB.purgeAll(); try? fm.removeItem(at: base)
    }

    // 3) reconcileOrphans cleans terminal jobs older than cleanupTTL, keeps recent.
    await test("reconcileOrphans: terminal jobs older than cleanupTTL are removed, recent ones kept") {
        // Tiny TTL so a job "ended" 10s ago is already past it.
        try await rtWithTemp(cleanupTTL: 5) { rt, base in
            let oldId = "20200101-000000-aaaaaaaa"
            let newId = "20200101-000000-bbbbbbbb"
            // Old terminal job — ended well beyond the 5s TTL.
            try seedMeta(BgProcessJobMeta(
                id: oldId, pid: 1, pgid: 1, command: "echo old", workingDir: nil, label: nil,
                startedAt: Date(timeIntervalSinceNow: -100),
                endedAt: Date(timeIntervalSinceNow: -60), exitCode: 0, status: .done
            ), baseDir: base)
            // Recent terminal job — ended just now, inside the TTL.
            try seedMeta(BgProcessJobMeta(
                id: newId, pid: 2, pgid: 2, command: "echo new", workingDir: nil, label: nil,
                startedAt: Date(timeIntervalSinceNow: -3),
                endedAt: Date(), exitCode: 1, status: .failed
            ), baseDir: base)

            let summary = await rt.reconcileOrphans()
            try expect(summary.cleaned == 1, "exactly the stale terminal job should be cleaned, got \(summary.cleaned)")

            let oldDir = base.appendingPathComponent(oldId).path
            let newDir = base.appendingPathComponent(newId).path
            try expect(!FileManager.default.fileExists(atPath: oldDir), "stale terminal job dir must be removed")
            try expect(FileManager.default.fileExists(atPath: newDir), "recent terminal job dir must survive")
            // The recent one is still readable.
            let recent = try await rt.status(id: newId)
            try expect(recent.status == .failed, "recent job meta must remain intact")
        }
    }

    // 4) kill cascade escalates SIGTERM → SIGKILL on a TERM-ignoring child.
    await test("kill cascade: a TERM-ignoring child is escalated to SIGKILL after the grace period") {
        try await rtWithTemp(killGracePeriodSec: 1) { rt, _ in
            // Child traps (ignores) SIGTERM and would otherwise sleep 30s.
            let meta = try await rt.start(command: "trap '' TERM; sleep 30")
            let id = meta.id
            let pid = meta.pid
            try? await Task.sleep(nanoseconds: 300_000_000) // let the trap install
            try expect(Darwin.kill(pid, 0) == 0, "child should be alive before kill")

            // Soft kill (SIGTERM). The trap swallows it, so the 1s-grace timer
            // must escalate to SIGKILL.
            _ = try await rt.kill(id: id, force: false)

            // Wait out the grace + a margin, then the process group must be gone.
            var gone = false
            for _ in 0..<60 { // up to ~6s
                if Darwin.kill(pid, 0) != 0 { gone = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try expect(gone, "TERM-ignoring child must be SIGKILLed after the grace period")

            // meta should reflect the escalation: killSignal == SIGKILL.
            var sawSigkill = false
            for _ in 0..<30 {
                let m = try await rt.status(id: id)
                if m.killSignal == SIGKILL { sawSigkill = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try expect(sawSigkill, "escalation must record killSignal == SIGKILL in meta")
        }
    }

    // 5) finalizeExit: a child that is signaled WITHOUT a prior runtime.kill is
    //    .failed, not .killed (killSignal stays nil ⇒ not an intentional kill).
    await test("finalizeExit: signaled-without-prior-kill resolves to .failed, not .killed") {
        try await rtWithTemp { rt, _ in
            let meta = try await rt.start(command: "sleep 30")
            let id = meta.id
            let pid = meta.pid
            try? await Task.sleep(nanoseconds: 300_000_000)
            try expect(Darwin.kill(pid, 0) == 0, "child should be alive")

            // Signal it EXTERNALLY (not via rt.kill), so the runtime never sets
            // killSignal. The watcher's finalizeExit sees WIFSIGNALED with
            // killSignal == nil ⇒ must classify as .failed. Signal the whole
            // process group (pgid == pid, set by POSIX_SPAWN_SETPGROUP) so the
            // spawned bash AND its `sleep` child both die — no orphaned sleep.
            _ = Darwin.kill(-pid, SIGKILL)

            var final: BgProcessStatus = .running
            for _ in 0..<60 {
                let m = try await rt.status(id: id)
                if m.status != .running { final = m.status; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try expect(final == .failed,
                       "externally-signaled job (no prior kill) must be .failed, got \(final)")
        }
    }

    // 6) start is concurrency-safe: N parallel starts yield N distinct ids/dirs.
    await test("start: N concurrent launches produce N distinct jobIds + distinct dirs") {
        try await rtWithTemp { rt, base in
            let n = 12
            let ids: [String] = await withTaskGroup(of: String?.self) { group in
                for i in 0..<n {
                    group.addTask {
                        // Trivial fast commands; pgid==pid per spawn.
                        (try? await rt.start(command: "echo job-\(i)"))?.id
                    }
                }
                var collected: [String] = []
                for await maybe in group { if let id = maybe { collected.append(id) } }
                return collected
            }
            try expect(ids.count == n, "expected \(n) successful starts, got \(ids.count)")
            try expect(Set(ids).count == n, "jobIds must be distinct — got \(Set(ids).count) unique of \(n)")
            // Each id has its own dir with a meta.json.
            for id in ids {
                let metaPath = base.appendingPathComponent(id).appendingPathComponent("meta.json").path
                try expect(FileManager.default.fileExists(atPath: metaPath), "missing meta.json for \(id)")
            }
            // The runtime lists exactly n jobs.
            let listed = await rt.list()
            try expect(listed.count == n, "runtime.list() must report \(n) jobs, got \(listed.count)")
        }
    }
}
