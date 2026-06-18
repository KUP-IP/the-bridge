// ShortcutsModuleTests.swift
// TheBridge · Tests
//
// PKT-959 (v3.7·F): unit tests for the shortcuts_* tool family against the
// injectable `ShortcutsRunning` CLI seam — NO live /usr/bin/shortcuts. The
// mock records the argv it was handed and replays a scripted result, so we
// assert both the command construction (list flags, run name, --input-path,
// --output-path -) and the parsed envelopes (list parsing, output capture,
// failure surfacing, capability-missing short-circuit).

import Foundation
import MCP
import TheBridgeLib

// MARK: - In-memory mock seam

/// Deterministic in-memory `ShortcutsRunning`. `available` drives the
/// capability_missing branch; `result` is the canned invocation result;
/// `lastArgs` captures the argv the module built so tests can assert it.
final class MockShortcutsRunner: ShortcutsRunning, @unchecked Sendable {
    var available: Bool
    var result: ShortcutsInvocationResult
    private(set) var lastArgs: [String] = []
    private(set) var callCount = 0

    init(available: Bool = true,
         result: ShortcutsInvocationResult = ShortcutsInvocationResult(exitCode: 0, stdout: "", stderr: "")) {
        self.available = available
        self.result = result
    }

    var path: String? { get async { available ? "/usr/bin/shortcuts" : nil } }

    func run(_ args: [String]) async throws -> ShortcutsInvocationResult {
        callCount += 1
        lastArgs = args
        if !available { throw ShortcutsError.capabilityMissing("shortcuts CLI not on PATH") }
        return result
    }
}

func runShortcutsModuleTests() async {
    print("\n\u{1F500} ShortcutsModule Tests (PKT-959 v3.7·F)")

    // Helper: build a router with the two tools registered over a mock runner.
    func makeRouter(_ runner: ShortcutsRunning) async -> ToolRouter {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await ShortcutsModule.register(on: router, runner: runner)
        return router
    }

    // ------------------------------------------------------------------
    // 1) Registration + tier policy
    // ------------------------------------------------------------------
    await test("ShortcutsModule registers 2 tools under module=\"shortcuts\" with correct tiers") {
        let router = await makeRouter(MockShortcutsRunner())
        let regs = await router.registrations(forModule: "shortcuts")
        let byName = Dictionary(uniqueKeysWithValues: regs.map { ($0.name, $0) })
        try expect(regs.count == 2, "expected 2 shortcuts_* tools, got \(regs.count)")
        guard let list = byName["shortcuts_list"], let run = byName["shortcuts_run"] else {
            throw TestError.assertion("missing shortcuts_list / shortcuts_run — got \(byName.keys.sorted())")
        }
        try expect(list.tier == .open, "shortcuts_list tier expected .open, got \(list.tier.rawValue)")
        try expect(run.tier == .notify, "shortcuts_run tier expected .notify, got \(run.tier.rawValue)")
    }

    await test("shortcuts_run schema declares name required; shortcuts_list none") {
        let router = await makeRouter(MockShortcutsRunner())
        let regs = await router.registrations(forModule: "shortcuts")
        guard let run = regs.first(where: { $0.name == "shortcuts_run" }),
              case .object(let runSchema) = run.inputSchema,
              case .array(let runReq) = runSchema["required"] else {
            throw TestError.assertion("missing shortcuts_run required[]")
        }
        let runNames = runReq.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        try expect(runNames == ["name"], "shortcuts_run required expected [name], got \(runNames)")

        guard let list = regs.first(where: { $0.name == "shortcuts_list" }),
              case .object(let listSchema) = list.inputSchema,
              case .array(let listReq) = listSchema["required"] else {
            throw TestError.assertion("missing shortcuts_list required[]")
        }
        try expect(listReq.isEmpty, "shortcuts_list should have no required fields")
    }

    // ------------------------------------------------------------------
    // 2) shortcuts_list — parses one-name-per-line stdout + builds argv
    // ------------------------------------------------------------------
    await test("shortcuts_list parses names and builds `list` argv") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(
            exitCode: 0,
            stdout: "Send iMessage to Contact\nTurn Text Into Audio\n  Start Pomodoro  \n\n",
            stderr: ""
        ))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(toolName: "shortcuts_list", arguments: .object([:]))
        guard case .object(let dict) = result else { throw TestError.assertion("expected object") }
        if case .bool(let ok) = dict["ok"] { try expect(ok == true) } else { throw TestError.assertion("missing ok") }
        if case .int(let n) = dict["count"] { try expect(n == 3, "expected 3 names, got \(n)") }
        else { throw TestError.assertion("missing count") }
        guard case .array(let names) = dict["shortcuts"] else { throw TestError.assertion("missing shortcuts[]") }
        let strs = names.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        try expect(strs == ["Send iMessage to Contact", "Turn Text Into Audio", "Start Pomodoro"],
            "trimmed/non-empty parse expected, got \(strs)")
        try expect(runner.lastArgs == ["list"], "argv expected [list], got \(runner.lastArgs)")
    }

    await test("shortcuts_list folders:true uses --folders and returns folders[]") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(
            exitCode: 0, stdout: "Personal\nWork\n", stderr: ""
        ))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "shortcuts_list",
            arguments: .object(["folders": .bool(true)])
        )
        guard case .object(let dict) = result else { throw TestError.assertion("expected object") }
        try expect(runner.lastArgs == ["list", "--folders"], "argv expected [list, --folders], got \(runner.lastArgs)")
        guard case .array(let folders) = dict["folders"] else { throw TestError.assertion("missing folders[]") }
        try expect(folders.count == 2, "expected 2 folders")
        // The shortcuts key must NOT be present when listing folders.
        try expect(dict["shortcuts"] == nil, "folders listing should not carry shortcuts[]")
    }

    await test("shortcuts_list folderName forwards --folder-name") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(exitCode: 0, stdout: "A\n", stderr: ""))
        let router = await makeRouter(runner)
        _ = try await router.dispatch(
            toolName: "shortcuts_list",
            arguments: .object(["folderName": .string("Work")])
        )
        try expect(runner.lastArgs == ["list", "--folder-name", "Work"],
            "argv expected [list, --folder-name, Work], got \(runner.lastArgs)")
    }

    // ------------------------------------------------------------------
    // 3) shortcuts_run — output capture + argv (run <name> --output-path -)
    // ------------------------------------------------------------------
    await test("shortcuts_run captures stdout output and builds run argv") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(
            exitCode: 0, stdout: "Hello from the shortcut", stderr: ""
        ))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "shortcuts_run",
            arguments: .object(["name": .string("My Shortcut")])
        )
        guard case .object(let dict) = result else { throw TestError.assertion("expected object") }
        if case .bool(let ok) = dict["ok"] { try expect(ok == true) } else { throw TestError.assertion("missing ok") }
        if case .string(let out) = dict["output"] {
            try expect(out == "Hello from the shortcut", "output capture mismatch: \(out)")
        } else { throw TestError.assertion("missing output") }
        // No input → argv is run <name> --output-path -
        try expect(runner.lastArgs == ["run", "My Shortcut", "--output-path", "-"],
            "argv mismatch: \(runner.lastArgs)")
    }

    // ------------------------------------------------------------------
    // 4) shortcuts_run — input passing via temp file (--input-path)
    // ------------------------------------------------------------------
    await test("shortcuts_run passes input via --input-path temp file (then cleans up)") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(exitCode: 0, stdout: "ok", stderr: ""))
        let router = await makeRouter(runner)
        _ = try await router.dispatch(
            toolName: "shortcuts_run",
            arguments: .object(["name": .string("Echo"), "input": .string("payload-123")])
        )
        // argv: run Echo --input-path <tmp> --output-path -
        let a = runner.lastArgs
        try expect(a.count == 6, "expected 6 argv tokens, got \(a)")
        try expect(a[0] == "run" && a[1] == "Echo", "head argv mismatch: \(a)")
        try expect(a[2] == "--input-path", "expected --input-path at [2], got \(a)")
        let tmpPath = a[3]
        try expect(tmpPath.contains("bridge-shortcut-input-"), "temp input path expected, got \(tmpPath)")
        try expect(a[4] == "--output-path" && a[5] == "-", "expected trailing --output-path -, got \(a)")
        // The temp file is removed via defer after the run returns.
        try expect(!FileManager.default.fileExists(atPath: tmpPath),
            "input temp file should be cleaned up, still present at \(tmpPath)")
    }

    // ------------------------------------------------------------------
    // 5) shortcuts_run — run-failure surfaces a structured failed envelope
    // ------------------------------------------------------------------
    await test("shortcuts_run non-zero exit returns failed envelope with stderr") {
        let runner = MockShortcutsRunner(result: ShortcutsInvocationResult(
            exitCode: 1, stdout: "", stderr: "Couldn't find shortcut named \"Nope\""
        ))
        let router = await makeRouter(runner)
        let result = try await router.dispatch(
            toolName: "shortcuts_run",
            arguments: .object(["name": .string("Nope")])
        )
        guard case .object(let dict) = result else { throw TestError.assertion("expected object") }
        if case .bool(let ok) = dict["ok"] { try expect(ok == false, "expected ok=false") }
        else { throw TestError.assertion("missing ok") }
        if case .string(let status) = dict["status"] {
            try expect(status == "failed", "expected status=failed, got \(status)")
        } else { throw TestError.assertion("missing status") }
        if case .string(let err) = dict["error"] {
            try expect(err.contains("Couldn't find shortcut"), "error should carry stderr, got \(err)")
        } else { throw TestError.assertion("missing error") }
    }

    await test("shortcuts_run missing name returns invalid_argument (no CLI call)") {
        let runner = MockShortcutsRunner()
        let router = await makeRouter(runner)
        let result = try await router.dispatch(toolName: "shortcuts_run", arguments: .object([:]))
        guard case .object(let dict) = result, case .string(let status) = dict["status"] else {
            throw TestError.assertion("expected status field")
        }
        try expect(status == "invalid_argument", "expected invalid_argument, got \(status)")
        try expect(runner.callCount == 0, "invalid args must short-circuit before any CLI call")
    }

    // ------------------------------------------------------------------
    // 6) capability_missing short-circuit (CLI unavailable)
    // ------------------------------------------------------------------
    await test("capability_missing when shortcuts CLI is unavailable") {
        let runner = MockShortcutsRunner(available: false)
        let router = await makeRouter(runner)
        // list
        let listResult = try await router.dispatch(toolName: "shortcuts_list", arguments: .object([:]))
        guard case .object(let l) = listResult, case .string(let lStatus) = l["status"] else {
            throw TestError.assertion("expected status on list")
        }
        try expect(lStatus == "capability_missing", "list expected capability_missing, got \(lStatus)")
        // run
        let runResult = try await router.dispatch(
            toolName: "shortcuts_run", arguments: .object(["name": .string("X")])
        )
        guard case .object(let r) = runResult, case .string(let rStatus) = r["status"] else {
            throw TestError.assertion("expected status on run")
        }
        try expect(rStatus == "capability_missing", "run expected capability_missing, got \(rStatus)")
        // Capability check happens before invocation → no CLI run attempted.
        try expect(runner.callCount == 0, "capability_missing must short-circuit before run()")
    }

    // ------------------------------------------------------------------
    // 7) parseLines pure helper
    // ------------------------------------------------------------------
    await test("parseLines trims, drops empties, preserves order") {
        let parsed = ShortcutsModule.parseLines("  One \n\nTwo\n   \nThree\n")
        try expect(parsed == ["One", "Two", "Three"], "got \(parsed)")
        try expect(ShortcutsModule.parseLines("").isEmpty, "empty stdout → no names")
        try expect(ShortcutsModule.parseLines("\n  \n").isEmpty, "whitespace-only → no names")
    }
}
