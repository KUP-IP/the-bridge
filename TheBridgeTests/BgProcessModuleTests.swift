// BgProcessModuleTests.swift — Tool-Dev (PRJCT-2754)
// TheBridge · Tests
//
// Unit + live-round-trip tests for the detached-background-execution family:
// bg_run (.request) / bg_poll (.open, read-only) / bg_kill (.notify). Unlike the
// EventKit/AppleScript modules these tools have NO injectable seam — they spawn
// REAL detached shells via /bin/bash. That is exactly what we want to verify, so
// these tests drive the live handlers against a HERMETIC temp home
// (BridgePaths.overrideHomeForTesting) so the file-backed job triple
// (<ts-uuid>.{log,done,pid}) lands in a throwaway dir, never the user's real
// ~/Library/Application Support/The Bridge/bg-process. Commands are trivial and
// short (echo / sleep) so the suite stays fast and never leaves stray processes.

import Foundation
import MCP
import TheBridgeLib

private func bgWithTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("BgProcess-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}

/// Dispatch a tool by name on a freshly-registered router and return the result.
private func bgDispatch(_ router: ToolRouter, _ name: String, _ args: Value) async throws -> Value {
    try await router.dispatch(toolName: name, arguments: args)
}

/// Pull a string field out of an `.object` result.
private func bgString(_ v: Value, _ key: String) -> String? {
    guard case .object(let d) = v, case .string(let s) = d[key] else { return nil }
    return s
}

private func bgInt(_ v: Value, _ key: String) -> Int? {
    guard case .object(let d) = v else { return nil }
    if case .int(let i) = d[key] { return i }
    if case .double(let dbl) = d[key] { return Int(dbl) }
    return nil
}

/// Poll bg_poll until status != "running" or the attempt budget is exhausted.
/// Uses real (short) sleeps because the worker is a genuine detached process.
private func bgPollUntilDone(_ router: ToolRouter, jobId: String, maxAttempts: Int = 100) async throws -> Value {
    var last: Value = .null
    for _ in 0..<maxAttempts {
        last = try await bgDispatch(router, "bg_poll", .object(["jobId": .string(jobId)]))
        if bgString(last, "status") != "running" { return last }
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    }
    return last
}

func runBgProcessModuleTests() async {
    print("\n\u{2699}\u{FE0F} BgProcessModule Tests (bg_run / bg_poll / bg_kill — PRJCT-2754)")

    // Build a router with ONLY this module registered (registration/tier checks
    // don't need the full surface; dispatch checks don't either).
    func makeRouter() async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BgProcessModule.register(on: router)
        return router
    }

    // MARK: Registration / tiers

    await test("BgProcessModule registers exactly 3 tools (bg_run/bg_poll/bg_kill)") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "bgprocess")
        try expect(tools.count == 3, "Expected 3 bgprocess tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names == ["bg_run", "bg_poll", "bg_kill"], "Unexpected tool names: \(names.sorted())")
    }

    await test("bg_run is tier .request, bg_poll is .open, bg_kill is .notify") {
        let router = await makeRouter()
        let tools = await router.registrations(forModule: "bgprocess")
        func tier(_ n: String) -> SecurityTier? { tools.first(where: { $0.name == n })?.tier }
        try expect(tier("bg_run") == .request, "bg_run must be .request, got \(String(describing: tier("bg_run")))")
        try expect(tier("bg_poll") == .open, "bg_poll must be .open, got \(String(describing: tier("bg_poll")))")
        try expect(tier("bg_kill") == .notify, "bg_kill must be .notify, got \(String(describing: tier("bg_kill")))")
    }

    await test("all 3 bgprocess tools carry an EXPLICIT annotation entry") {
        for name in ["bg_run", "bg_poll", "bg_kill"] {
            try expect(ToolAnnotationCatalog.annotations(for: name) != nil,
                       "\(name) missing an annotation entry (audit invariant)")
        }
    }

    await test("bg_poll annotation is read-only + idempotent + non-destructive (closed world)") {
        let ann = ToolAnnotationCatalog.annotations(for: "bg_poll")
        try expect(ann?.readOnlyHint == true && ann?.destructiveHint == false
                   && ann?.idempotentHint == true && ann?.openWorld == false,
                   "bg_poll annotation mismatch: \(String(describing: ann))")
    }

    await test("bg_run annotation requiresConfirmation (mirrors .request); bg_poll/bg_kill do not") {
        // Mirror invariant: requiresConfirmation == (tier == .request || neverAutoApprove).
        try expect(ToolAnnotationCatalog.annotations(for: "bg_run")?.requiresConfirmation == true,
                   "bg_run must requiresConfirmation (it is .request)")
        try expect(ToolAnnotationCatalog.annotations(for: "bg_poll")?.requiresConfirmation == false,
                   "bg_poll must NOT requiresConfirmation (it is .open)")
        try expect(ToolAnnotationCatalog.annotations(for: "bg_kill")?.requiresConfirmation == false,
                   "bg_kill must NOT requiresConfirmation (it is .notify)")
    }

    // MARK: Input validation

    await test("bg_run rejects a missing command") {
        let router = await makeRouter()
        do {
            _ = try await bgDispatch(router, "bg_run", .object([:]))
            throw TestError.assertion("expected invalidArguments for missing command")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("bg_poll on an unknown job returns status not_found (no throw)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            let r = try await bgDispatch(router, "bg_poll", .object(["jobId": .string("20200101-000000000-deadbeef")]))
            try expect(bgString(r, "status") == "not_found", "expected not_found, got \(bgString(r, "status") ?? "nil")")
        }
    }

    await test("bg_poll rejects a malformed jobId (path-traversal guard)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            do {
                _ = try await bgDispatch(router, "bg_poll", .object(["jobId": .string("../../etc/passwd")]))
                throw TestError.assertion("expected malformed-jobId rejection")
            } catch is ToolRouterError {
                // expected — the charset guard refuses '/' and '.'
            }
        }
    }

    // MARK: bg_run shape + path confinement

    await test("bg_run returns {jobId,pid,logPath,donePath} immediately, paths under bg-process/") {
        try await bgWithTempHome { tmp in
            let router = await makeRouter()
            let r = try await bgDispatch(router, "bg_run", .object(["command": .string("echo hi")]))
            try expect(bgString(r, "status") == "started", "expected status=started, got \(bgString(r, "status") ?? "nil")")
            let jobId = bgString(r, "jobId")
            try expect(jobId != nil && !jobId!.isEmpty, "missing jobId")
            try expect(bgInt(r, "pid") ?? 0 > 0, "missing/invalid pid")
            let logPath = bgString(r, "logPath") ?? ""
            let donePath = bgString(r, "donePath") ?? ""
            let bgDir = BridgePaths.applicationSupport(.bgProcess).standardizedFileURL.path
            try expect(logPath.hasPrefix(bgDir + "/"), "logPath not confined to bg-process dir: \(logPath)")
            try expect(donePath.hasPrefix(bgDir + "/"), "donePath not confined to bg-process dir: \(donePath)")
            try expect(logPath.hasSuffix(".log") && donePath.hasSuffix(".done"), "unexpected path suffixes")
            // The temp home must actually be where the job landed.
            try expect(logPath.hasPrefix(tmp.standardizedFileURL.path), "job did not land under the hermetic temp home")
            // pid sidecar exists.
            let pidPath = logPath.replacingOccurrences(of: ".log", with: ".pid")
            try expect(FileManager.default.fileExists(atPath: pidPath), "pid sidecar not written")
        }
    }

    // MARK: LIVE round-trip — bg_run → bg_poll(running?) → exit + exitCode + output

    await test("LIVE: bg_run → bg_poll reaches exited with exitCode 0 + captured output") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            // Print a marker, then exit 0. Short enough to finish fast.
            let run = try await bgDispatch(router, "bg_run", .object([
                "command": .string("echo BRIDGE_BG_MARKER; exit 0")
            ]))
            let jobId = try { () -> String in
                guard let j = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }
                return j
            }()
            let final = try await bgPollUntilDone(router, jobId: jobId)
            try expect(bgString(final, "status") == "exited",
                       "expected exited, got \(bgString(final, "status") ?? "nil")")
            try expect(bgInt(final, "exitCode") == 0,
                       "expected exitCode 0, got \(String(describing: bgInt(final, "exitCode")))")
            // Combined output captured to the log → surfaced in tail.
            let tail = bgString(final, "tail") ?? ""
            try expect(tail.contains("BRIDGE_BG_MARKER"), "expected marker in tail, got: \(tail)")
            // duration reported for a terminal job.
            if case .object(let d) = final {
                try expect(d["duration"] != nil, "expected a duration on an exited job")
            }
        }
    }

    await test("LIVE: bg_run preserves single quotes (no double-escape regression)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            // An apostrophe inside double quotes must round-trip verbatim. The
            // pre-fix code escaped the command once for an inner single-quote
            // context that does not exist, then the whole worker again for the
            // launcher, so this surfaced corrupted as `it'\''s` in the log.
            let run = try await bgDispatch(router, "bg_run", .object([
                "command": .string("echo \"it's a 'quoted' test\"")
            ]))
            let jobId = try { () -> String in
                guard let j = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }
                return j
            }()
            let final = try await bgPollUntilDone(router, jobId: jobId)
            try expect(bgString(final, "status") == "exited",
                       "expected exited, got \(bgString(final, "status") ?? "nil")")
            try expect(bgInt(final, "exitCode") == 0,
                       "expected exitCode 0, got \(String(describing: bgInt(final, "exitCode")))")
            let tail = bgString(final, "tail") ?? ""
            try expect(tail.contains("it's a 'quoted' test"),
                       "apostrophe/quote corrupted in output: \(tail)")
            try expect(!tail.contains("'\\''"),
                       "output shows shell double-escaping: \(tail)")
        }
    }

    await test("LIVE: a non-zero exit is reported with the real exit code") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            let run = try await bgDispatch(router, "bg_run", .object([
                "command": .string("exit 7")
            ]))
            guard let jobId = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }
            let final = try await bgPollUntilDone(router, jobId: jobId)
            try expect(bgString(final, "status") == "exited", "expected exited, got \(bgString(final, "status") ?? "nil")")
            try expect(bgInt(final, "exitCode") == 7, "expected exitCode 7, got \(String(describing: bgInt(final, "exitCode")))")
            if case .object(let d) = final, case .bool(let success) = d["success"] {
                try expect(success == false, "non-zero exit must report success=false")
            }
        }
    }

    // MARK: LIVE — bg_kill SIGTERMs a running job

    await test("LIVE: bg_kill SIGTERMs a long-running job (status leaves running)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            // A 60s sleep — guaranteed still running when we poll + kill.
            let run = try await bgDispatch(router, "bg_run", .object([
                "command": .string("sleep 60")
            ]))
            guard let jobId = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }

            // Give the worker a moment to be alive, then assert running.
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            let polled = try await bgDispatch(router, "bg_poll", .object(["jobId": .string(jobId)]))
            try expect(bgString(polled, "status") == "running",
                       "expected running before kill, got \(bgString(polled, "status") ?? "nil")")

            // SIGTERM it.
            let killed = try await bgDispatch(router, "bg_kill", .object(["jobId": .string(jobId)]))
            try expect(bgString(killed, "status") == "signalled",
                       "expected signalled, got \(bgString(killed, "status") ?? "nil")")
            try expect(bgString(killed, "signal") == "SIGTERM",
                       "expected SIGTERM, got \(bgString(killed, "signal") ?? "nil")")

            // After the signal the process dies; poll must leave 'running'
            // (SIGTERM has no shell sentinel write, so the honest terminal state
            // is either 'terminated' or — if the trapped shell recorded $?=143 —
            // 'exited'. Either is acceptable; what's NOT acceptable is 'running'.)
            let after = try await bgPollUntilDone(router, jobId: jobId, maxAttempts: 60)
            try expect(bgString(after, "status") != "running",
                       "job must not still be running after SIGTERM, got \(bgString(after, "status") ?? "nil")")
        }
    }

    await test("bg_kill is idempotent on an already-exited job (already_exited, no signal)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            let run = try await bgDispatch(router, "bg_run", .object(["command": .string("exit 0")]))
            guard let jobId = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }
            _ = try await bgPollUntilDone(router, jobId: jobId) // wait until terminal
            let killed = try await bgDispatch(router, "bg_kill", .object(["jobId": .string(jobId)]))
            let status = bgString(killed, "status")
            try expect(status == "already_exited" || status == "already_terminated",
                       "expected already_exited/already_terminated, got \(status ?? "nil")")
        }
    }

    await test("bg_kill on an unknown job returns not_found (no throw)") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            let r = try await bgDispatch(router, "bg_kill", .object(["jobId": .string("20200101-000000000-cafebabe")]))
            try expect(bgString(r, "status") == "not_found", "expected not_found, got \(bgString(r, "status") ?? "nil")")
        }
    }

    // MARK: env + label passthrough

    await test("LIVE: bg_run threads env into the detached command + echoes label") {
        try await bgWithTempHome { _ in
            let router = await makeRouter()
            let run = try await bgDispatch(router, "bg_run", .object([
                "command": .string("echo VAL=$BRIDGE_BG_TESTVAR"),
                "env": .object(["BRIDGE_BG_TESTVAR": .string("xyzzy")]),
                "label": .string("my-build")
            ]))
            try expect(bgString(run, "label") == "my-build", "label not echoed back")
            guard let jobId = bgString(run, "jobId") else { throw TestError.assertion("no jobId") }
            let final = try await bgPollUntilDone(router, jobId: jobId)
            let tail = bgString(final, "tail") ?? ""
            try expect(tail.contains("VAL=xyzzy"), "env var not threaded into worker; tail: \(tail)")
        }
    }
}
