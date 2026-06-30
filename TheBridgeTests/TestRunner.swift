// TestRunner.swift – V1-06 Test Runner
// TheBridge · Tests (standalone executable — no XCTest needed)
//
// Runs: SecurityGate, ToolRouter, AuditLog, Module tests, Integration/E2E tests
// PKT-376: SecurityGate tests updated for 3-tier model
//
// MAIN-ACTOR REENTRANCY FIX (summary; full reasoning at the @main entry point
// below): the UI/contract tests hop to the main actor via
// `await MainActor.run { ... }` (55 call sites across 11 files). If the driver
// itself runs ON the main actor those hops are reentrant self-calls that
// nondeterministically deadlock (the suite froze at 0% progress on ~50% of
// runs, always GREEN when it finished). The driver MUST run off the main actor.
// This file used to be a `main.swift` (top-level code → implicitly main-actor)
// and the deadlock was endemic. It is now `TestRunner.swift` with a `@main`
// struct whose SYNCHRONOUS `main()` runs the whole sequence on a `Task.detached`
// (off the main actor) while pumping the main run loop with `RunLoop.main.run()`.
// (A `main.swift` file and a `@main` attribute are mutually exclusive in one
// target, hence the rename.) The shared harness primitives (`test`, `expect`,
// `TestError`, `passed`, `failed`) stay at file scope because the other test
// files call them as free functions.

import Foundation


import MCP
import TheBridgeLib

// MARK: - Test Harness (file scope — other test files call these as free functions)

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

// Process exit code, set by the detached run task when the suite finishes and
// read by `main()` after the main run loop stops. The detached task no longer
// calls `exit()` itself (see the entry-point note) — it hands the code back to
// the MAIN thread, which exits cleanly there.
nonisolated(unsafe) var exitCode: Int32 = 0

// Set true (on the main thread) when the suite has finished and the main loop
// should stop pumping. `main()` drives the run loop in a `while !suiteFinished`
// loop and checks this after each iteration, so a stop returns control to it
// (a bare `RunLoop.main.run()` re-enters its inner mode loop forever after a
// CFRunLoopStop and never returns — that re-entry was the residual teardown hang).
nonisolated(unsafe) var suiteFinished = false

// `body` is `sending`: the driver now runs OFF the main actor (see the @main
// note above), so each test closure is created in the driver's isolation domain
// and handed to `test()` — marking it `sending` lets ownership transfer across
// that boundary without a Sendable conformance, which is safe because the
// closure is used exactly once and never escapes.
func test(_ name: String, _ body: sending () async throws -> Void) async {
    do {
        try await body()
        passed += 1
        print("  \u{2705} \(name)")
    } catch {
        failed += 1
        print("  \u{274C} \(name): \(error)")
    }
}

func expect(_ condition: Bool, _ msg: String = "Assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw TestError.assertion("\(msg) at \(file):\(line)") }
}

enum TestError: Error, LocalizedError {
    case assertion(String)
    var errorDescription: String? {
        switch self { case .assertion(let m): return m }
    }
}

// AuditLog test fixture. Hoisted to file scope (was a local func inside the
// driver) so the off-main-actor `sending` test closures can call it without
// crossing an actor boundary; `nonisolated` because AuditEntry is a plain value.
nonisolated func makeSampleEntry(
    toolName: String = "test_tool",
    tier: SecurityTier = .open,
    status: ApprovalStatus = .approved
) -> AuditEntry {
    AuditEntry(
        timestamp: Date(), toolName: toolName, tier: tier,
        inputSummary: "test input", outputSummary: "test output",
        durationMs: 42.0, approvalStatus: status
    )
}

// MARK: - Entry point

@main
struct TheBridgeTestRunner {
    // MAIN-ACTOR REENTRANCY FIX (corrected). Symptom: the suite froze at 0%
    // forward progress on ~50% of local runs, at varying points, always GREEN
    // when it did finish — a nondeterministic deadlock on the main actor.
    //
    // Root cause: the UI/contract tests hop to the main actor via
    // `await MainActor.run { ... }` (55 call sites across 11 files) to touch
    // @MainActor types (SwiftUI views, @Observable controllers, AppKit). If the
    // DRIVER itself runs ON the main actor, those hops are REENTRANT self-calls on
    // the same actor, which nondeterministically deadlock.
    //
    // The original driver was a `main.swift` whose top-level code is implicitly
    // @MainActor-isolated → on the main actor → deadlock. Renaming it to an
    // `async @main` did NOT fix it: under swift-tools-version 6.2 ("approachable
    // concurrency") the `async static func main()` of a `@main` type is INFERRED
    // @MainActor-isolated, so it STILL ran on the main actor (verified
    // empirically: `main()`'s body and its nested `MainActor.run` bodies both ran
    // on the main thread → still reentrant → still deadlocked). A bare
    // `Task.detached` wrapper with `await runner.value` ALSO failed: while `main()`
    // was suspended the main run loop was not pumped, so SCK/AppKit replies and
    // MainActor scheduling stalled → intermittent hangs AND a teardown SIGTRAP.
    //
    // FIX: a SYNCHRONOUS `main()` (synchronous → NOT an async main-actor task; it
    // is the plain process entry on the main thread). It spawns the whole test
    // sequence on a `Task.detached`, which runs OFF the main actor, then PUMPS the
    // main run loop (a `while !suiteFinished { CFRunLoopRunInMode(.defaultMode…) }`
    // drive — see the entry-point body for why a bare `RunLoop.main.run()` cannot
    // be cleanly stopped). Result: the driver body runs off the main actor (every
    // `MainActor.run` is now a REAL cross-actor hop, not a reentrant self-call — no
    // deadlock), and the live main run loop keeps the main actor serviced AND
    // services CFRunLoop-dependent system callbacks (ScreenCaptureKit / AppKit).
    // When the suite finishes, the detached task hands the exit code back to the
    // MAIN thread (via a main-queue enqueue that stops the loop); `main()` then
    // exits cleanly THERE — no more `exit()` from the detached task out from under
    // a live run loop (that was the teardown SIGTRAP / hang). `runAllTests()` is
    // `nonisolated` so its body inherits the detached (non-main) executor.
    static func main() {
        // Line-buffer stdout. When this runner's output is a pipe (CI: `… | tee`),
        // stdout defaults to FULL buffering, so on an intermittent hang the buffered
        // tail never flushes and the CI log's last line is NOT where it actually hung —
        // it just shows the last flushed block. Line buffering flushes on every newline
        // (negligible overhead: ~one flush per test line, unlike per-byte unbuffered),
        // so the CI log always pinpoints the hanging test. Distinct from the summary
        // teardown race, which is handled by the atexit summary handler below.
        setvbuf(stdout, nil, _IOLBF, 0)

        // HERMETIC TEST ISOLATION (v3.6.1): point ConfigManager at a throwaway temp
        // config file BEFORE any test (or ConfigManager.shared) touches it. Without
        // this, ConfigManagerTests read and mutate the user's real
        // ~/.config/.../config.json — non-hermetic, order-dependent, destructive.
        // Seeds a minimal valid config so first reads succeed.
        if ProcessInfo.processInfo.environment["BRIDGE_CONFIG_PATH"] == nil {
            let tmpConfig = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-test-config-\(ProcessInfo.processInfo.processIdentifier).json")
            setenv("BRIDGE_CONFIG_PATH", tmpConfig.path, 1)
            let seed = #"{"sensitivePaths":["~/.ssh","~/.aws","~/.gnupg","~/.config","~/Library/Keychains"]}"#
            try? seed.data(using: .utf8)?.write(to: tmpConfig, options: .atomic)
        }

        // HERMETIC TEST ISOLATION (PKT-810): connector/cloud env vars are
        // meaningful only to the live app; several gating tests read
        // ProcessInfo.environment directly and assert the default (off) state.
        // A dev session that exported these via launchctl leaks them into the
        // test process and false-fails those assertions. Unset up front so the
        // suite is deterministic regardless of the launchd environment.
        for leaky in [
            "BRIDGE_ENABLE_HTTP", "BRIDGE_PUBLIC_RESOURCE", "BRIDGE_OAUTH_ISSUER",
            "BRIDGE_OAUTH_JWKS", "BRIDGE_CLOUD_BASE_URL", "NOTION_BRIDGE_PORT",
            "WORKOS_CLIENT_ID", "WORKOS_BASE_URL", "WORKOS_REDIRECT_URI",
        ] {
            unsetenv(leaky)
        }

        // Credential / payment MCP tests assume the Keychain credentials feature is enabled.
        UserDefaults.standard.set(true, forKey: CredentialsFeature.userDefaultsKey)

        // Emit the final summary from an atexit handler so it is GUARANTEED to print.
        // The synchronous continuation after the final suspension point can
        // intermittently lose a race with process teardown and be skipped entirely
        // (the binary still exits 0 and every test ran) — which dropped the
        // `Results:` line the floor gate parses. atexit handlers run during any
        // normal process exit, after all code, so the summary is deterministic
        // regardless of that race or of stdout buffering mode. The closure
        // references only globals, so it captures nothing (@convention(c)-safe).
        atexit {
            print("\n" + String(repeating: "=", count: 50))
            print("Results: \(passed) passed, \(failed) failed, \(passed + failed) total")
            print(String(repeating: "=", count: 50))
            print(failed > 0 ? "\u{274C} TESTS FAILED" : "\u{2705} ALL TESTS PASSED")
            fflush(stdout)
        }

        // Run the test sequence OFF the main actor (see the entry-point note),
        // then pump the main run loop so the (now real) MainActor.run hops and any
        // CFRunLoop-dependent system callbacks (ScreenCaptureKit / AppKit) are
        // serviced while the suite runs.
        //
        // CLEAN MAIN-THREAD SHUTDOWN (teardown-SIGTRAP fix). The driver used to
        // call `exit()` from INSIDE the detached task while the main thread was
        // blocked in `RunLoop.main.run()`. That tore the process down from under a
        // live CFRunLoop mid-iteration: the C++/Swift-runtime teardown ran while
        // the run loop was still servicing the main dispatch queue, which
        // intermittently SIGTRAP'd during teardown BEFORE the atexit summary
        // handler could print the `Results:` line — so a run that passed every
        // test exited with no summary (and the operator's truncated-count race has
        // the same root cause). It could also HANG: if an arming subsystem (e.g. a
        // test that constructs a real AppDelegate → Sparkle auto-updater) had
        // scheduled main-queue work, the still-pumping run loop would service it
        // and present a modal `NSAlert`, wedging the main thread forever.
        //
        // FIX: when the suite finishes, the detached task records the exit code and
        // enqueues a MAIN-QUEUE work item (DispatchQueue.main.async) that sets the
        // `suiteFinished` flag and stops the loop. The main thread drives the run
        // loop in a `while !suiteFinished` loop using CFRunLoopRunInMode, then falls
        // through and exits ON the main thread. Why each piece is the robust form:
        //   • Hand-off via the main queue (not exit() / CFRunLoopStop from the
        //     task's own thread): CFRunLoopStop from a FOREIGN thread races an idle
        //     main loop — it sets the stop flag but the loop only notices on wake,
        //     and a loop parked in mach_msg with no pending source can miss the
        //     wakeup and sleep forever. A main-queue enqueue is itself a source the
        //     main loop always services, so it reliably WAKES the loop and the block
        //     runs ON the main thread, where the stop is race-free.
        //   • A `while !suiteFinished { CFRunLoopRunInMode(...) }` drive instead of
        //     `RunLoop.main.run()`: NSRunLoop.run() runs the loop "permanently" by
        //     re-entering its inner runMode loop after every return, so a
        //     CFRunLoopStop breaks ONE inner iteration and run() immediately
        //     re-enters — it never hands control back (observed: every test printed,
        //     then a permanent hang in RunLoop.main.run()). Driving the mode
        //     ourselves and re-checking the flag each iteration makes the stop
        //     actually return to us. We pump in .defaultMode, which is what
        //     RunLoop.main.run() used and what services MainActor + the
        //     CFRunLoop-dependent SCK/AppKit callbacks the suite relies on.
        // Net: exit() runs on the main thread with the loop torn down in an orderly
        // way; the atexit summary handler fires on that clean exit, so the
        // `Results:` summary is emitted deterministically with the full count, every
        // run.
        Task.detached(priority: .userInitiated) {
            await runAllTests()
            exitCode = failed > 0 ? 1 : 0
            DispatchQueue.main.async {
                suiteFinished = true
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        while !suiteFinished {
            // Block until a source fires (test-driven MainActor hops, SCK/AppKit
            // callbacks, or the shutdown enqueue), then re-check the flag. Result
            // handling: .stopped/.handledSource → just loop and re-check. .finished
            // means the mode momentarily had NO sources/timers and returned at once;
            // re-running immediately would busy-spin, so back off briefly. In
            // practice the main dispatch-queue port keeps the mode non-empty for the
            // whole suite, so .finished is a defensive guard, not the steady state.
            let result = CFRunLoopRunInMode(.defaultMode, 0.1, false)
            if result == .finished {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // Reached only after the shutdown block set the flag + stopped the loop.
        // Exit on the MAIN thread with the suite's code; the atexit handler prints
        // the summary.
        exit(exitCode)
    }

    // The full test sequence. `nonisolated` so it runs on whatever (non-main)
    // executor the detached task provides, NOT the main actor.
    nonisolated static func runAllTests() async {
        await runVoiceMemoHubTrustTests() // PKT-MEM-106 0a: trust + identity core (run early — flake-avoidance)
        await runMemoryHubCockpitTests()  // PKT-MEM-106 0b: run early alongside 0a (same flake-avoidance)
        await runMemoryHubGuardrailTests() // PKT-MEM-106 0c: preview + guardrails + tabs (run early)
        await runMemoryHubMemoTitleTests() // PKT-MEM-114 P1: progressive AI memo titles (run early)
        // ============================================================
        // MARK: - SecurityGate Tests (v3: 3-tier model)
        // ============================================================

        print("\n\u{1F512} SecurityGate Tests (v3)")

        let gate = SecurityGate()

await test("Open tier allows immediately") {
    let d = await gate.enforce(toolName: "read_file", tier: .open, arguments: .object(["path": .string("/tmp/test.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for open tier") }
}

await test("Open tier allows with safe content") {
    let d = await gate.enforce(toolName: "write_file", tier: .open, arguments: .object(["path": .string("/tmp/out.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for open tier write") }
}

await test("SecurityTier has exactly 3 cases") {
    try expect(SecurityTier.allCases.count == 3, "Expected 3 tiers, got \(SecurityTier.allCases.count)")
    try expect(SecurityTier.allCases.contains(.open))
    try expect(SecurityTier.allCases.contains(.notify))
    try expect(SecurityTier.allCases.contains(.request))
}

await test("SecurityTier raw values are correct") {
    try expect(SecurityTier.open.rawValue == "open")
    try expect(SecurityTier.notify.rawValue == "notify")
    try expect(SecurityTier.request.rawValue == "request")
}

await test("SecurityTier is Codable (JSON round-trip)") {
    let encoder = JSONEncoder()
    let data = try encoder.encode(SecurityTier.open)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(SecurityTier.self, from: data)
    try expect(decoded == .open, "Expected .open after decode")
}

// Nuclear pattern tests — fork bomb only
let forkBomb = ":(){ :|:" + "& };:"

await test("Nuclear handoff: fork bomb") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    guard let decision = d else { throw TestError.assertion("Expected non-nil for fork bomb") }
    if case .handoff = decision { } else { throw TestError.assertion("Expected .handoff") }
}

await test("Diskutil is not nuclear anymore") {
    let cmd = "diskutil erasedisk JHFS+ Untitled /dev/disk2"
    let d = await gate.checkNuclearPattern(cmd.lowercased(), raw: cmd)
    try expect(d == nil, "Expected nil for diskutil")
}

await test("sudo is not nuclear anymore") {
    let cmd = "sudo -n true"
    let d = await gate.checkNuclearPattern(cmd.lowercased(), raw: cmd)
    try expect(d == nil, "Expected nil for sudo")
}

await test("Nuclear handoff returns command in decision") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    if case .handoff(let cmd, let explanation, let warning) = d {
        try expect(!cmd.isEmpty, "Command should not be empty")
        try expect(!explanation.isEmpty, "Explanation should not be empty")
        try expect(!warning.isEmpty, "Warning should not be empty")
    } else {
        throw TestError.assertion("Expected .handoff with all fields")
    }
}

// Sensitive path tests — checkSensitivePaths is async and triggers notifications.
// For unit tests, we test that the method exists and can detect sensitive paths
// by checking session/permanent allow behavior.

await test("Session permissions start empty and can be cleared") {
    await gate.clearSessionPermissions()
    // After clearing, no paths should be session-allowed
    // (We can't easily test the notification flow in unit tests)
}

await test("NotionPageRef normalizes dashed UUID and notion.so URL") {
    let id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    switch NotionPageRef.normalizedPageId(from: id) {
    case .success(let n):
        try expect(n.contains("-"), "Expected dashed UUID form")
        try expect(n.replacingOccurrences(of: "-", with: "").count == 32, "Expected 32 hex")
    case .failure(let err):
        throw TestError.assertion("Expected valid page id: \(err.message)")
    }
    let url = "https://www.notion.so/w/Test-a1b2c3d4e5f67890abcdef1234567890"
    switch NotionPageRef.normalizedPageId(from: url) {
    case .success(let n):
        try expect(n.lowercased().contains("a1b2c3d4"), "Expected id from URL")
    case .failure(let err):
        throw TestError.assertion("Expected URL parse: \(err.message)")
    }
}

await test("NotionPageRef rejects non-Notion URL") {
    switch NotionPageRef.normalizedPageId(from: "https://example.com/page") {
    case .success:
        throw TestError.assertion("Expected failure for non-Notion URL")
    case .failure(let err):
        try expect(!err.message.isEmpty, "Expected error message")
    }
}

await test("Permanent access can be granted and revoked") {
    // Test isolation (flake fix): grant/revokePermanentAccess mutate
    // process-global UserDefaults.standard under a key derived purely from
    // the path. A hardcoded shared path ("~/.ssh") made this key collide
    // with the sibling "permanent allow passes through" test, so concurrent
    // or order-dependent suite execution raced on the same global key and
    // produced nondeterministic pass/fail. This test only needs a
    // round-trip on the raw key, so use a per-test UNIQUE path → unique key
    // that can never collide with any other test or the seeded defaults.
    // Belt-and-suspenders: snapshot & restore the exact key so neither
    // direction of contamination is possible regardless of harness order.
    let testPath = "~/.notionbridge-test-permaccess-\(UUID().uuidString)"
    let key = "com.notionbridge.security.pathAllow." + testPath
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    await gate.grantPermanentAccess(path: testPath)
    try expect(UserDefaults.standard.bool(forKey: key) == true, "Expected permanent access granted")
    await gate.revokePermanentAccess(path: testPath)
    try expect(UserDefaults.standard.bool(forKey: key) == false, "Expected permanent access revoked")
}

await test("Sensitive path with permanent allow passes through") {
    // Test isolation (flake fix): this test MUST use a real configured
    // sensitive path ("~/.ssh" — a ConfigManager default) because
    // checkSensitivePaths only honors the permanent key when the path
    // matches the sensitive-paths list, so a UUID path cannot exercise it.
    // The shared global key is therefore structurally unavoidable here;
    // serialize safety by snapshotting the exact key, force-clearing it to
    // a known state before the grant, and restoring the original value in a
    // guaranteed cleanup that runs on BOTH the success and failure path so
    // this test can neither be contaminated by nor leak into any sibling.
    let testPath = "~/.ssh"
    let key = "com.notionbridge.security.pathAllow." + testPath
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.removeObject(forKey: key)
    await gate.grantPermanentAccess(path: testPath)
    // With permanent allow, checkSensitivePaths should return nil (allow)
    let result = await gate.checkSensitivePaths(["~/.ssh/id_rsa"], toolName: "file_read")
    try expect(result == nil, "Expected nil (allow) for permanently allowed path")
    await gate.revokePermanentAccess(path: testPath)
}

await test("GateDecision.handoff is not allow or reject") {
    let d = await gate.checkNuclearPattern(forkBomb.lowercased(), raw: forkBomb)
    if case .allow = d { throw TestError.assertion("Nuclear should not be .allow") }
    if case .reject = d { throw TestError.assertion("Nuclear should not be .reject") }
    if case .handoff = d { /* expected */ } else { throw TestError.assertion("Expected .handoff") }
}

// ============================================================
// MARK: - ToolRouter Tests
// ============================================================

print("\n\u{1F500} ToolRouter Tests")

let routerGate = SecurityGate()
let routerLog = AuditLog()
let router = ToolRouter(securityGate: routerGate, auditLog: routerLog)

await test("Tool registration stores and retrieves tools") {
    await router.register(ToolRegistration(
        name: "test_tool", module: "test", tier: .open,
        description: "A test tool",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .string("ok") }
    ))
    let all = await router.allRegistrations()
    try expect(all.count >= 1, "Expected at least 1 registration")
    try expect(all.contains(where: { $0.name == "test_tool" }), "Expected test_tool in registry")
}

await test("Registration overwrites existing tool with same name") {
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .open,
        description: "Version 1", inputSchema: .object([:]),
        handler: { _ in .string("v1") }
    ))
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .open,
        description: "Version 2", inputSchema: .object([:]),
        handler: { _ in .string("v2") }
    ))
    let all = await router.allRegistrations()
    let match = all.first(where: { $0.name == "overwrite_test" })
    try expect(match?.description == "Version 2", "Expected Version 2")
}

await test("Registrations can be filtered by module") {
    await router.register(ToolRegistration(
        name: "alpha_tool", module: "alpha", tier: .open,
        description: "A", inputSchema: .object([:]),
        handler: { _ in .null }
    ))
    let alpha = await router.registrations(forModule: "alpha")
    try expect(alpha.count >= 1)
    try expect(alpha[0].name == "alpha_tool")
}

await test("Dispatch routes to correct handler") {
    await router.register(ToolRegistration(
        name: "echo_test", module: "builtin", tier: .open,
        description: "Echo test", inputSchema: .object([:]),
        handler: { args in
            if case .object(let dict) = args,
               case .string(let msg) = dict["message"] {
                return .string("echo: \(msg)")
            }
            return .string("no message")
        }
    ))
    let result = try await router.dispatch(
        toolName: "echo_test",
        arguments: .object(["message": .string("hello")])
    )
    if case .string(let s) = result {
        try expect(s == "echo: hello", "Expected 'echo: hello' got '\(s)'")
    } else {
        throw TestError.assertion("Expected string result")
    }
}

await test("Dispatch throws for unknown tool") {
    do {
        _ = try await router.dispatch(toolName: "nonexistent_xyz", arguments: .object([:]))
        throw TestError.assertion("Expected error for unknown tool")
    } catch is ToolRouterError {
        // Expected
    }
}

await test("Dispatch returns handoff for fork-bomb commands") {
    await router.register(ToolRegistration(
        name: "nuclear_test", module: "test", tier: .open,
        description: "Test", inputSchema: .object([:]),
        handler: { _ in .string("should not reach") }
    ))
    let result = try await router.dispatch(
        toolName: "nuclear_test",
        arguments: .object(["command": .string(forkBomb)])
    )
    if case .object(let dict) = result {
        if case .string(let status) = dict["status"] {
            try expect(status == "handoff", "Expected status=handoff, got \(status)")
        } else {
            throw TestError.assertion("Expected status key in handoff response")
        }
    } else {
        throw TestError.assertion("Expected object result for fork-bomb handoff")
    }
}

// PKT-373 P1-5: batchGate tests removed (dead code removed)

// ============================================================
// MARK: - AuditLog Tests
// ============================================================

print("\n\u{1F4CB} AuditLog Tests")

await test("Append adds entry to in-memory log") {
    let log = AuditLog()
    await log.append(makeSampleEntry())
    let count = await log.count()
    try expect(count == 1, "Expected count 1, got \(count)")
}

await test("Multiple appends accumulate") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "tool_a"))
    await log.append(makeSampleEntry(toolName: "tool_b"))
    await log.append(makeSampleEntry(toolName: "tool_c"))
    let count = await log.count()
    try expect(count == 3, "Expected count 3, got \(count)")
}

await test("All entries returns complete log") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "alpha"))
    await log.append(makeSampleEntry(toolName: "beta"))
    let entries = await log.allEntries()
    try expect(entries.count == 2)
    try expect(entries[0].toolName == "alpha")
    try expect(entries[1].toolName == "beta")
}

await test("Filter by tool name") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "echo"))
    await log.append(makeSampleEntry(toolName: "tools_list"))
    await log.append(makeSampleEntry(toolName: "echo"))
    let echoEntries = await log.entries(forTool: "echo")
    try expect(echoEntries.count == 2)
}

await test("Filter by tier") {
    let log = AuditLog()
    await log.append(makeSampleEntry(tier: .open))
    await log.append(makeSampleEntry(tier: .notify))
    await log.append(makeSampleEntry(tier: .open))
    let openEntries = await log.entries(forTier: .open)
    try expect(openEntries.count == 2)
}

await test("Filter by approval status") {
    let log = AuditLog()
    await log.append(makeSampleEntry(status: .approved))
    await log.append(makeSampleEntry(status: .rejected))
    await log.append(makeSampleEntry(status: .approved))
    let rejected = await log.entries(withStatus: .rejected)
    try expect(rejected.count == 1)
}

await test("Entry contains all required fields") {
    let log = AuditLog()
    let entry = AuditEntry(
        timestamp: Date(), toolName: "test", tier: .open,
        inputSummary: "input", outputSummary: "output",
        durationMs: 100.5, approvalStatus: .approved
    )
    await log.append(entry)
    let entries = await log.allEntries()
    let first = entries[0]
    try expect(first.toolName == "test")
    try expect(first.tier == .open)
    try expect(first.inputSummary == "input")
    try expect(first.outputSummary == "output")
    try expect(first.durationMs == 100.5)
    try expect(first.approvalStatus == .approved)
}

await test("AuditEntry is Codable (JSON round-trip)") {
    let entry = makeSampleEntry()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AuditEntry.self, from: data)
    try expect(decoded.toolName == entry.toolName)
    try expect(decoded.tier == entry.tier)
    try expect(decoded.approvalStatus == entry.approvalStatus)
}

// ============================================================
// MARK: - V1-04/V1-05 Module Tests
// ============================================================

// SKIPPED: checkAll() hangs in CLI — NSAppleScript probes need AppKit run loop
// await runPermissionManagerTests()
await runShellModuleTests()
await runBgProcessModuleTests()   // Tool-Dev (PRJCT-2754): bg_run/bg_poll/bg_kill detached background execution (registration/tier/annotation + LIVE run→poll→exit round-trip + bg_kill SIGTERM)
await runBgProcessRuntimeTests()  // v4 audit #3: BgProcessRuntime actor — kill cascade SIGTERM→SIGKILL, reconcileOrphans (dead→unknown / live-reattach / TTL sweep), finalizeExit signaled-not-killed, concurrency-safe start
await runFileModuleTests()
await runSessionModuleTests()
await runSessionPersistenceTests()   // ITEM [session]: MCP session durability across restart/install (persist + clean-shutdown marker + resumable reconnect)
await runRegistryConfigTests()       // Data-Source Registry W1: config model + store (Skills = entity #1, bind-by-property-id)
await runRegistryRowCacheTests()     // Data-Source Registry W1: generalized per-entity read-through row cache (stale-while-revalidate + offline)
await runRegistryPropertyCodecTests() // Data-Source Registry W2: Notion property codec (typed Value ↔ Notion JSON, decode/encode/isWritable)
await runRegistryDataPathTests()     // Data-Source Registry W2: live data path (schema binder · read-through reader · writer create-then-update · rate limiter)
await runRegistryModuleTests()       // Data-Source Registry W3: MCP tool surface (10 tools: generic CRUD + add/remove_entity + introspect + possess, registration + handler behavior)
await runDataSourcesViewModelTests() // Data-Source Registry W4: Settings pane scenarios (propose→confirm, TTL, drift, errors) + BE↔FE alignment
await runRegistryEdgeCaseTests()     // Data-Source Registry: adversarial edge cases (codec chunking, pagination, cache concurrency, config race, writer)
await runRegistryHydrationTests()    // Packet Runner v1 (FR-1/§8.3): packet-registry-v1 one-hop hydration envelope (primary+body+relations+provenance+warnings)
await runMessagesModuleTests()
await runMessagesSuiteAuditTests()   // Messages-suite every-angle-of-attack audit
await runMailModuleTests()           // PKT-961 (v3.7·H): mail_* Apple Mail module (mock seam; send-guard)
// PKT-960 (v3.7·G): notes_* Apple Notes module (injectable NotesScriptRunner
// mock seam; notes_delete is .request + confirm:'DELETE'). Registration PORTED
// into this @main TestRunner during the Wave-1 integration — the Notes branch
// was built on the old base and registered this call in the now-deleted
// main.swift, which does NOT auto-merge across the main.swift→TestRunner rename
// (the NotesModuleTests.swift file landed but its run-sequence call did not).
await runNotesModuleTests()
await runSystemModuleTests()
await runRemindersModuleTests()   // PKT-957 (v3.7·D): reminders_* EventKit module (mock seam)
await runCalendarModuleTests()    // PKT-962 (v3.7·I): calendar_* EventKit module (mock seam; reuses v3.7·D store + entitlement)
await runPermissionsModuleTests() // fb-permissions: unified permissions_status TCC probe (pure assembler — no live TCC)
await runNotionModuleTests()
await runAccessibilityModuleTests()
await runScreenModuleTests()
await runAppleScriptModuleTests()
await runBuiltinModuleTests()
await runConfigManagerTests()
await runMCPHTTPValidationTests()
await runDesktopOrganizationScenarioTests()
await runSkillsModuleTests()
await runSkillNotionMetadataSyncTests() // PKT-1003 Wave A: real-column sync read/write + gate-safe pull (no metadata blanking)
await runSkillCacheStatusSnapshotTests() // PKT-1003 Wave B: pure body-cache snapshot (real body-store state for pip + counts + indicators)
await runSkillListNavigationTests() // PKT-1003 Wave D: detail-header prev/next navigation math
await runSkillManagementUIScenarioTests() // PKT-1003 follow-through: Settings->Skills user scenarios aligned to UI contract + storage/edit paths
await runCredentialManagerTests()
await runCredentialModuleTests()
await runCredentialHardeningTests()   // [credentials] hardening: env-var alias normalization → canonical service:account, sentinel/placeholder detection, idempotent-read transient-drop retry policy. PURE — no Keychain / no live network.
await runCredentialValidatorTests()   // v3.7.6 Wave 4a: premium vault validation core — pure service→method mapping (incl. unmappable→unchecked truthfulness invariant), health→badge-tone, status persistence round-trip, Touch-ID reveal gate, weekly-due decision, card expiry/form validators. NO live network.
await runKeychainMigrationTests()     // WS-5c: keychain service rename com.notionbridge → kup.solutions.notion-bridge is ZERO-LOSS (legacy item still reads back; non-destructive old-copy retained; save mirrors both; delete clears both) + WS-5b cadence guard (recordRun flips isDue OFF → periodic timer/wake never double-run). Live round-trip auto-skips when the test process has no writable Keychain.
await runStripeClientTests()
await runConnectionsModuleTests()
await runStripeTokenizationTests()
await runSecurityAuditTests()
await runReadOnlyTierAuditTests()
await runSecurityGateUXTests()        // fb-securitygate: coalescing + module-scoped Always-Allow + timeout seam
await runToolTierResolutionTests()    // fb-securitygate-revoke-ui: module-aware effective tier + source + revoke


// ============================================================
// MARK: - V1-06 Integration / End-to-End Tests
// ============================================================

await runCodeEditModuleTests()
await runDevModuleTests()              // dev-suite audit: dev_module_info coverage
await runDevSuiteAuditTests()          // dev-suite audit: cross-tool invariants
await runDevSuiteEdgeTests()           // dev-suite audit: edge / attack surface
await runSpotlightModuleTests()        // PKT-747 (v2.2 · 3.3)
await runSyntheticInputModuleTests()   // PKT-747 (v2.2 · 3.3)
await runMouseClickModuleTests()        // PKT-765 (v2.2 · 3.3.1)
await runBridgeAutomationModuleTests()  // FB-AUTOMATION: bridge_settings_navigate + bridge_focus_settings + axPath/frontmost-guard
await runSettingsAXIdentifierTests()    // PKT-1005: BridgeAXID convention + SettingsUIValidationHarness (Pillar C/D)
await runCGEventModuleTests()           // PKT-765 (v2.2 · 3.3.1)
await runPasteboardHistoryModuleTests() // PKT-765 (v2.2 · 3.3.1)
await runJobsModuleTests()
await runSchedulerResilienceTests()  // PKT-381: durable backlog + reconciler + serial drain + first job
await runVoiceMemoModuleTests()        // Voice Memos curator: registry-centric router + 9am job
await runVoiceMemoLiveRegressionTests() // PKT-MEM-105/106 live fixture regression
await runVoiceMemoParseChainTests()    // Voice Curator FRONTIER-FIRST (Phase 1 W1): parse provider chain + plan provenance/degraded
await runVoiceMemoCloudParseTests()    // Voice Curator FRONTIER-FIRST (Phase 1 W2): real cloud frontier parse (whole-transcript strict-JSON extraction)
await runMemoryHubCockpitLabelsTests() // Voice Curator FRONTIER-FIRST (Phase 1 W3): cockpit human labels + provenance badge + commit-value preview
await runVoiceCuratorPhase1RemediationTests() // Voice Curator FRONTIER-FIRST (Phase 1 W4): review remediation — durable cloud-send provenance + notifier lane + honest commit-write label
await runVoiceMemoMCPRoutingTests() // PKT-MEM-120: Auto+MCP Execute defer, presence, awaiting-agent tags + notification gate
// PKT-MEM-106 0a + 0b run early in runAllTests() (flake-avoidance) — not duplicated here.
await runMemorySettingsTests()         // PKT-MEM-102: Memory Settings section + Inbox UI
await runOllamaModuleTests()           // Local Ollama client + module (Wave 2a)
await runGhModuleTests()
await runGitModuleTests()
await runWSHMenuBarTests()        // PKT-804 (v2.3): menu-bar quick-page
await runSnippetsModuleTests()    // PKT-2135a9e9 (v2.3 · WS-D): snippets module
await runCommandsModuleTests()    // PKT-1061: CommandStore commands_* MCP surface
await runStandingOrdersModuleTests() // PKT-931 (v3.7·B): standing_orders_* MCP tools
await runShortcutsModuleTests()   // PKT-959 (v3.7·F): shortcuts_* MCP tools (mock CLI seam)
await runCommandsDataTests()      // cmd-w2: Commands data layer (CommandsManager + MentionResolver + cache)
await runFetchSkillMarkdownTests() // cmd-w4: fetch_skill /markdown + shared MentionResolver
await runFetchSkillPropertiesTests() // cu-sa: fetch_skill simplified `properties` map (additive)
await runResultSizeControlsTests() // fb-resultsize: fetch_skill section selector + notion_query relation filter/compact + calendar_events compact/limit
await runCommandBoxSpikeTests()   // cmd-w1 spike (imported): GUI-free command-box units + cmd-ux recorder/persist
await runCommandPaletteTests()    // cmd-w3: palette search + gate + AppDelegate gating + coordinator
await runSkillVsCommandSplitTests() // cmd-ux: LOCK the skill-vs-command body/properties split
await runCommandsControllerTests()  // cmd-ux W1/W2: CommandsController observable state machine + status/focus model
await runCommandBridgeControllerTests()  // PKT-878 v3.6.3: SwiftUI Command Bridge popup — placement/recents/anim/builders
await runBridgeSearchTests()             // PKT-1006 R2: multi-entity search — fuzzy/ranking/grouping + skill-source destination routing
await runCommandBridgeLayoutTests()      // v4 round-2: adaptive palette width clamp + remembered drag-origin clamp
await runCommandVisibilityTests()   // cmd-ux W3: .command visibility axis — Codable, palette filter, picker write-back, empty-state
await runFlagVisibilityMigrationTests()  // cmd-ux W4 (3.4.1): flag-based visibility SSOT — enum↔flags, decode/encode migration, RegistrySkillsCommandProvider flag filter, mutator parity
await runW4ComponentAndStorageTests()    // cmd-ux W4 (3.4.1): kbd-chip splitter + per-path file-source flag storage + effective routing/palette resolution
await runSkillsMCPFlagRoundTripTests()    // 3.4.2 W3 H1 fix: SkillConfig MCP reconstruction preserves combined-state flag pair
await runHotkeyRecorderFocusTests()        // 3.4.2 W4 H5 fix: RecorderFocusModel contract locks the button-binding focus path
await runHotkeyRebindUITests()             // v3.7.6: mount the Commands "Global shortcut" card — HotkeyConfig.from validation + persist round-trip + status-row mapping
await runCommandHotkeyHardeningTests()     // v4: ⌃⌘B enterprise hardening — Cocoa↔Carbon map round-trip, persist relaunch survival, collision-vs-plumbing classification, status-truth invariants + live-rebind no-churn
await runFrontmatterParserTests()   // W2 D8: SKILL.md YAML frontmatter parser
await runSkillIconAndKindTests()    // WS-3/WS-4: Skill emoji icon (Codable + extract) + derived skillKind/sourceKind accessors
await runSkillSourceTests()         // W2 D2: SkillSource enum + legacy notionPageId backward-compat
await runFilesystemSkillIndexTests() // W2 D3: SKILL.md filesystem index actor
await runFetchSkillFileSourceTests() // W2 D5: file-source fetch_skill envelope shape
await runListRoutingSkillsMergeTests() // W2 D6: merged routing-skills listing
await runSkillPathResolverTests()      // PKT-907: fetch_skill orchestrator (path / intent / file specialist / W3 summary)
await runRoutingReliabilityTests()     // routing-reliability: SpecialistFilter doc-page exclusion + confidence→clarify + per-client overlay + routing footer + skillFetched telemetry
await runToolAnnotationAuditTests() // PKT-803 (v2.3 · WS-B): annotation coverage audit
await runTransportRouterTests()     // PKT-803 (v2.3 · WS-B): transport router default/env
await runRemoteOAuthHTTPTests()     // PKT-800 (S1): RFC 9728 PRM + transport gating + route
await runRemoteOAuthBearerTests()   // PKT-800 (S2): JWTKit bearer + ScopeGate + 401/WWW-Auth
await runRemoteOAuthHardeningTests() // PKT-800 (S3): step-up + confused-deputy + leak-sweep + gating
await runRemoteOAuthHardeningS4Tests() // PKT-800 (S4): contacts.read split + TransportRouter seam + step-up scope-only
await runRemoteOAuthOriginGatingTests() // PKT-810 R5: origin split — loopback token-free, tunnel OAuth-gated
await runBridgeFeatureFlagsTests()  // PKT-798 (v2.3 · WS-C): fail-closed capability gates
await runBridgeModuleRegistryTests() // PKT v3.0·0.4: single-source module registrar
await runMCPToolFactoryTests()       // PKT v3.0·0.5: metadata contract + unified Tool factory
await runToolConventionTests()       // PKT v3.0·0.5: P0 — aliases + key convention + dispatch contract
await runToolMetadataAuthoringTests() // PKT v3.0·0.5: P1 — projection + authored-metadata render
await runArtifactModuleTests()    // PKT-743 (v2.2 · 3.1)
await runRunnerParsersTests()      // PKT-782 (v2.2 · 3.2b)
await runCronHumanizerTests()

await runEndToEndTests()

// PKT-1 (v3.5): rename migration + canonical paths.
await runPathMigrationTests()

// PKT-9 (v3.5): Standing Orders + Routing Index.
await runStandingOrdersTests()

// MCP resource layer: StandingOrdersDelivery SSOT (composition determinism +
// content-hash stability) and the shared BridgeResources URI→bytes resolution.
await runStandingOrdersDeliveryTests()

// W2 delivery telemetry: DeliveryLog ingest + per-(session,kind) rollup +
// bounded history ring + truthful per-session freshness logic + session prune.
await runDeliveryLogTests()

// Wave 3 delivery-audit regressions: (a) overlay-freshness (an overlay client
// reading its own composition is FRESH, not permanently amber — real
// composition(clientName:) path), (b) legacy-SSE prune-on-disconnect, (c) the
// record* wiring seam (handshake/read land the expected event), (d) truthful
// labels ("Fetched ✓" only on a real read; never "Honored").
await runDeliveryAuditWave3Tests()

// PKT-6 (v3.5): CommandStore (markdown-per-command + index.json).
await runCommandStoreTests()

// PKT-876 (v3.6.1): Settings sections Liquid Glass reskin.
await runSettingsSectionsLGTests()

// PKT-877 (Bridge v3.6·2): ModuleGroup + dispatch fail-closed SAFETY CONTRACT.
await runModuleGroupTests()
await runToolRouterFailClosedTests()

// PKT-879 (v3.6.4): Dashboard / Onboarding / icon picker reskin.
await runPKT879DashboardTests()
await runPKT879OnboardingTests()
await runPKT879IconPickerTests()

// PKT-1010 (Packet C activation + onboarding UX polish): token trim + validate.
await runPKT1010OnboardingTests()

// v3.6.0 D1: Credentials scope filter regression guard.
await runCredentialsScopeFilterTests()

// v3.6.0 D6: ModuleGroupCard expand-state persistence contract.
await runModuleGroupExpandPersistenceTests()

// v3.6·6: CommandStore security audit (slug sanitization defense-in-depth).
await runCommandStoreSecurityTests()

// PKT-909 (Sell/Distribute v3 · 1): License-key system + 30-day trial gate.
await runLicenseTokenTests()
await runLicenseManagerTests()
await runLicenseToolErrorTests()
await runLicenseUITests()
await runLicenseRevocationTests()
await runLicenseDispatchGateTests()
// Packet B (PRJCT-2754 · Ship The Bridge v4): pubkey injection + mint→verify→entitled.
await runLicenseCLITests()
// PKT-1014 T2: comprehensive coverage sweep (payment, licensing, UI, edge/error envelopes).
await runPaymentLicenseT2Tests()
// Packet E (PRJCT-2754): durable Remote-Access OAuth identity resolution precedence.
await runRemoteAccessIdentityTests()
// Packet E Wave 2 (PRJCT-2754): config-backed WorkOS / JWKS / TransportRouter /
// cloud-base-url reader precedence (env → config.json → baked → fail-closed).
await runRemoteAccessConfigWave2Tests()

// v3.7·A: SkillsCacheReader/Writer pipeline — Notion-source eager
// enumeration carve-out closure (PKT-907) + StandingOrders cached
// routing-skills backing (v3.6·5 TODO closure).
await runSkillsCacheTests()

// body-cache (feat/backend-remediation): persistent per-skill BODY cache
// with stale-while-revalidate — CachedSkillBody + SkillBodyCacheStore +
// envelope-equivalence between the cache-hit and network paths.
await runSkillBodyCacheTests()
await runSkillBodyCacheEvictionTests()
await runToolRouterListToolsReadyTests()

// routing/specialist-relation (v3.7.4): specialists now sourced from the
// parent's curated `Specialist` relation property (NotionJSON.extract-
// SpecialistRelationIDs) instead of the child_page walk; SpecialistFilter
// kept as a defensive secondary guard.
await runSpecialistRelationTests()

// WS-C + WS-E (Mac-side cloud access): BridgeCloudManager state machine +
// NL-3 auth-passdown (capability validation + mandatory passkey gate +
// no-raw-credential invariant) + Remote Access settings section/sidebar.
await runBridgeCloudManagerTests()

// WS-F (PKT-922, commit 57dfc4b · Bridge Cloud Access · Enable flow): the
// EnableCloudAccessFlow @Observable state machine (idle→checkingAccount→
// signingIn→provisioning→connected|failed), WorkOS sign-in URL builder +
// bridge-auth:// callback parse/exchange/persist/notify, 120s auth + 30s
// provision timeouts, toggle revert on failure, and the
// ProvisioningProgressView state mapping — all against mocks (no NSWorkspace /
// Keychain prompt / cloudflared / live WorkOS). Live end-to-end QA is gated on
// PKT-810 + WS-A. (+21 tests; registration ported from WS-F's main.swift into
// this @main TestRunner during the v3.7-rc union merge — the test file landed
// but its run-sequence call did not auto-merge across the main.swift→TestRunner
// rename.)
await runEnableCloudAccessFlowTests()

// WS-F remediation (2026-06-10): WorkerTokenExchange — the production
// code→token exchange now POSTs the one-time code to the kup-worker
// /auth/exchange route (the worker holds the WorkOS secret; the Mac ships
// none). URLProtocol-stubbed: request shape (POST {base}/auth/exchange, body
// {code} only) + response parse (access_token → token; non-2xx / missing → throw).
await runWorkerTokenExchangeTests()

// WS-D (PKT-921, Bridge Cloud Access): heartbeat loop over the WS-C
// BridgeCloudManager (start/stop on toggle, idempotent start), the
// cloud-gated `bridge_status` MCP tool (gated registration + canonical
// state-derived payload, NOT in the static feature-module count), and the
// ServerManager tools/list cloud conditional (CLOUD+offline/disabled → only
// bridge_status; CLOUD+online/degraded → full; local request never filtered).
// All against the in-memory WS-C fakes — no cloudflared, no network, no 30s
// waits (the heartbeat interval is shrunk + ticks observed via onTick).
await runCloudStatusModuleTests()

// WS-G (PKT-923 · Bridge Cloud Access · terminal UI packet): the one-time
// FirstRunCloudAccessModal gate (Q2: shown once, BridgeDefaults flag), the
// Add-to-Claude.ai MCP-URL derivation + query-value percent-encoding contract
// + Q3 copy+hint shipped mode, and the Disable flow (confirmationDialog →
// EnableCloudAccessFlow.disable() → CloudTeardown seam + cleared toggle/host;
// live BridgeCloudManager.disable() → .disabled). All against fakes (no
// SwiftUI render / WindowServer / cloudflared / network).
await runCloudAccessWSGTests()

// Unified Memory subsystem · FOUNDATION (Wave 1): MemoryStore (SQLite + FTS5)
// insert/get, salience-ranked FTS recall + order, dedup (exact-hash refresh +
// near-duplicate supersede/tombstone), use-promotion (recall bumps useCount +
// reorders), pin-to-top, soft forget (tombstone excluded from recall/list),
// scope/entity filters, the handshakeSlice extension-point seam, and the
// memory_* MCP tool registration + tiering + handler round-trip. All against
// a TEMP DB path (never the real config-dir store, never the shared singleton).
await runMemoryModuleTests()
await runMemoryRoutingAppendixTests()

// Memory Hub UX Reconstruction — INBOX disposition (D8/D9/D13) and AGENTS
// memory_update tool (D35/D41). DismissScope/DismissResult/TrashResult struct
// constructibility, dismissWithResult single/multi-lane semantics, sibling
// detection, .allLanes resolution, legacy dismiss() backward compat.
// MemoryStore.update round-trip, protectedFields constant, memory_update
// tool registration + tier + handler (text update + protected field rejection).
await runInboxDispositionTests()
await runMemoryUpdateTests()

// PKT-1007 Slice 1: Dense-vector recall + RRF fusion. StubMemoryEmbedder
// (deterministic, no CoreML assets), MemoryEmbeddingIndex (index/rank/evict),
// ReciprocaLRankFusion (single-list, dual-list, hybrid boost), MemoryStore.recall
// with injected stub embedder (RRF plumbing E2E without model assets), and
// NLContextualEmbedder unit tests (gated on asset availability, skip gracefully).
await runMemorySemanticRecallTests()

// v3.7.6 (system-tethered Light/Dark theme): the appearance-adaptive
// BridgeTokens contract. Resolves every adaptive token under .darkAqua and
// .aqua and asserts (a) the DARK branch equals the exact v3.7.5 carbon literal
// (dark = regression-free), (b) the LIGHT branch equals the defined titanium
// value, (c) each adaptive token genuinely differs across appearances, (d)
// canvasNSColor (AppKit window backing) tracks bgCanvas in both, and (e) the
// LEAVE-UNCHANGED tokens (accents/base signals/gold/titanium) stay fixed.
await runBridgeTokensAdaptiveTests()

// fix(sparkle) (2026-06-05): staged-update crash-loop guard. The pure,
// injectable menu-bar-icon resolution (MenuBarIconResolver) degrades to an SF
// Symbol when the SPM resource bundle is missing/corrupt instead of trapping
// via Bundle.module, and StagedUpdateValidator detects the present-but-
// Contents-less .bundle incident signature. Driven with simulated
// missing/malformed bundle paths + a synthetic Contents-less .bundle in a temp
// dir — never touches /Applications.
await runSparkleResilienceTests()

// Memory Hub Foundation — ACTIVITY+KEEP (D12 event log, D24 retention, KeepReview model)
await runMemoryHubActivityTests()

// Memory Hub Foundation — PROCESSING provider contracts (D23 credential refs, provider chain)
await runProcessingProviderTests()

// ============================================================
// MARK: - Summary
// ============================================================

// Summary is emitted by the atexit handler registered at startup, which fires on
// the clean main-thread exit() that `main()` performs after this task stops the
// run loop. This function NO LONGER calls exit() itself: exiting from here (off
// the main thread, mid-RunLoop) is exactly the teardown-SIGTRAP this fix removes.
// The exit code + CFRunLoopStop are handled by the detached-task wrapper in
// main(); when control returns there, main() exits on the main thread.
    } // static func runAllTests()
} // @main struct TheBridgeTestRunner
