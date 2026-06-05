// SwiftBuildModuleTests.swift — FB [buildtools]
// Coverage for SwiftBuildRunner (the start→poll→tail wrapper logic) and
// SwiftBuildModule (swift_build / swift_test / make_run MCP surface).
//
// Hermetic: SwiftBuildRunner is driven against a real BgProcessRuntime
// rooted at a per-test temp baseDir running fast /bin/bash builtins
// (true / false / echo / sleep) — no live swift/make invocation, no network,
// no collision with the production jobs directory.

import Foundation
import MCP
import NotionBridgeLib

private func sbTempDir(_ tag: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NBT-swiftbuild-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func runSwiftBuildModuleTests() async {
    print("\n\u{1F528} SwiftBuildModule Tests (FB [buildtools])")

    // ------------------------------------------------------------------
    // Registration + tier
    // ------------------------------------------------------------------
    await test("SwiftBuildModule registers swift_build/swift_test/make_run under module=\"swift\"") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("reg"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        let names = Set((await router.registrations(forModule: "swift")).map { $0.name })
        let expected: Set<String> = ["swift_build", "swift_test", "make_run"]
        try expect(expected.isSubset(of: names), "missing tools — got \(names.sorted())")
        await runtime.purgeAll()
    }

    await test("all swift module tools are tier .request") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("tier"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        for reg in await router.registrations(forModule: "swift") {
            try expect(reg.tier == .request, "\(reg.name) expected .request, got \(reg.tier.rawValue)")
        }
        await runtime.purgeAll()
    }

    await test("every swift tool has an explicit ToolAnnotationCatalog entry") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("ann"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        let missing = (await router.registrations(forModule: "swift"))
            .map(\.name).filter { ToolAnnotationCatalog.annotations(for: $0) == nil }
        try expect(missing.isEmpty, "missing annotations: \(missing.sorted())")
        await runtime.purgeAll()
    }

    await test("swift tool inputSchema property keys are all camelCase") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("schema"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        func camelOK(_ k: String) -> Bool {
            guard let f = k.first, f.isLowercase else { return false }
            return k.allSatisfy { $0.isLetter || $0.isNumber }
        }
        var bad: [String] = []
        for reg in await router.registrations(forModule: "swift") {
            guard case .object(let top) = reg.inputSchema,
                  case .object(let props)? = top["properties"] else { continue }
            for key in props.keys where !camelOK(key) { bad.append("\(reg.name).\(key)") }
        }
        try expect(bad.isEmpty, "non-camelCase keys: \(bad.sorted())")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // Command construction
    // ------------------------------------------------------------------
    await test("swiftCommand builds an exec'd `swift <sub>` line with quoted args") {
        let cmd = SwiftBuildModule.swiftCommand(subcommand: "build", args: ["-c", "release"])
        try expect(cmd == "exec swift build '-c' 'release'", "got: \(cmd)")
    }

    await test("swiftCommand with no args is just `exec swift <sub>`") {
        let cmd = SwiftBuildModule.swiftCommand(subcommand: "test", args: [])
        try expect(cmd == "exec swift test", "got: \(cmd)")
    }

    await test("swiftCommand shell-quotes args containing spaces / quotes (injection-safe)") {
        let cmd = SwiftBuildModule.swiftCommand(subcommand: "test", args: ["--filter", "My Tests; rm -rf /"])
        // The single argument must survive as ONE shell token, no metachar leak.
        try expect(cmd.contains("'My Tests; rm -rf /'"), "unsafe quoting: \(cmd)")
    }

    await test("makeCommand builds `exec make <target> <args>` quoted") {
        let cmd = SwiftBuildModule.makeCommand(target: "test-floor", args: [])
        try expect(cmd == "exec make 'test-floor'", "got: \(cmd)")
        let cmd2 = SwiftBuildModule.makeCommand(target: "build", args: ["-j4"])
        try expect(cmd2 == "exec make 'build' '-j4'", "got: \(cmd2)")
    }

    await test("makeCommand with nil target omits the target token") {
        let cmd = SwiftBuildModule.makeCommand(target: nil, args: [])
        try expect(cmd == "exec make", "got: \(cmd)")
    }

    // ------------------------------------------------------------------
    // parseCommon
    // ------------------------------------------------------------------
    await test("parseCommon extracts args/cwd/env/label/timeoutSec/tailBytes") {
        let parsed = SwiftBuildModule.parseCommon(.object([
            "args": .array([.string("-c"), .string("debug")]),
            "cwd": .string("/tmp/proj"),
            "env": .object(["FOO": .string("bar")]),
            "label": .string("mybuild"),
            "timeoutSec": .int(42),
            "tailBytes": .int(123)
        ]))
        try expect(parsed.args == ["-c", "debug"], "args: \(parsed.args)")
        try expect(parsed.cwd == "/tmp/proj", "cwd: \(String(describing: parsed.cwd))")
        try expect(parsed.env["FOO"] == "bar", "env: \(parsed.env)")
        try expect(parsed.label == "mybuild", "label: \(String(describing: parsed.label))")
        try expect(parsed.timeoutSec == 42, "timeoutSec: \(parsed.timeoutSec)")
        try expect(parsed.tailBytes == 123, "tailBytes: \(parsed.tailBytes)")
    }

    await test("parseCommon falls back to defaults on empty input") {
        let parsed = SwiftBuildModule.parseCommon(.object([:]))
        try expect(parsed.args.isEmpty, "args should be empty")
        try expect(parsed.cwd == nil, "cwd should be nil")
        try expect(parsed.label == nil, "label should be nil")
        try expect(parsed.timeoutSec == SwiftBuildRunner.defaultTimeoutSec, "timeout default")
        try expect(parsed.tailBytes == SwiftBuildRunner.defaultTailBytes, "tail default")
    }

    await test("parseCommon accepts a double timeoutSec") {
        let parsed = SwiftBuildModule.parseCommon(.object(["timeoutSec": .double(2.5)]))
        try expect(parsed.timeoutSec == 2.5, "got \(parsed.timeoutSec)")
    }

    await test("parseCommon ignores non-positive timeoutSec / tailBytes (keeps default)") {
        let parsed = SwiftBuildModule.parseCommon(.object([
            "timeoutSec": .int(0), "tailBytes": .int(-5)
        ]))
        try expect(parsed.timeoutSec == SwiftBuildRunner.defaultTimeoutSec, "timeout default kept")
        try expect(parsed.tailBytes == SwiftBuildRunner.defaultTailBytes, "tail default kept")
    }

    // ------------------------------------------------------------------
    // Runner core — success / failure / tail / timeout
    // ------------------------------------------------------------------
    await test("SwiftBuildRunner.run reports success (exit 0) and completed=true") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("ok"))
        let r = try await SwiftBuildRunner.run(
            runtime: runtime, command: "true", workingDir: nil, env: [:],
            label: "t", timeoutSec: 10, tailBytes: 4096, pollIntervalSec: 0.02
        )
        try expect(r.completed, "expected completed")
        try expect(!r.timedOut, "should not time out")
        try expect(r.succeeded, "expected succeeded")
        try expect(r.exitCode == 0, "exitCode \(String(describing: r.exitCode))")
        try expect(r.status == "done", "status \(String(describing: r.status))")
        try expect(!r.jobId.isEmpty, "empty jobId")
        await runtime.purgeAll()
    }

    await test("SwiftBuildRunner.run captures a non-zero exit code (tail-on-failure)") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("fail"))
        let r = try await SwiftBuildRunner.run(
            runtime: runtime, command: "exit 7", workingDir: nil, env: [:],
            label: "t", timeoutSec: 10, tailBytes: 4096, pollIntervalSec: 0.02
        )
        try expect(r.completed, "expected completed")
        try expect(!r.succeeded, "expected NOT succeeded")
        try expect(r.exitCode == 7, "exitCode \(String(describing: r.exitCode))")
        try expect(r.status == "failed", "status \(String(describing: r.status))")
        await runtime.purgeAll()
    }

    await test("SwiftBuildRunner.run captures stdout AND stderr tails") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("tails"))
        let r = try await SwiftBuildRunner.run(
            runtime: runtime,
            command: "echo OUTLINE; echo ERRLINE 1>&2; exit 3",
            workingDir: nil, env: [:],
            label: "t", timeoutSec: 10, tailBytes: 4096, pollIntervalSec: 0.02
        )
        try expect(r.completed, "expected completed")
        try expect(r.exitCode == 3, "exitCode \(String(describing: r.exitCode))")
        try expect(r.stdoutTail.contains("OUTLINE"), "stdout tail missing OUTLINE: \(r.stdoutTail)")
        try expect(r.stderrTail.contains("ERRLINE"), "stderr tail missing ERRLINE: \(r.stderrTail)")
        try expect(r.stdoutBytes > 0, "stdoutBytes should be > 0")
        try expect(r.stderrBytes > 0, "stderrBytes should be > 0")
        await runtime.purgeAll()
    }

    await test("SwiftBuildRunner.run tail returns only the last tailBytes of a large stream") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("trunc"))
        // Emit ~2000 'x' bytes, then a sentinel at the very end.
        let r = try await SwiftBuildRunner.run(
            runtime: runtime,
            command: "head -c 2000 /dev/zero | tr '\\0' 'x'; echo TAILMARK",
            workingDir: nil, env: [:],
            label: "t", timeoutSec: 10, tailBytes: 32, pollIntervalSec: 0.02
        )
        try expect(r.completed, "expected completed")
        // tail is capped to 32 bytes but totalBytes reflects the full stream.
        try expect(r.stdoutTail.count <= 32, "tail not capped: len=\(r.stdoutTail.count)")
        try expect(r.stdoutBytes > 100, "totalBytes should reflect full stream: \(r.stdoutBytes)")
        try expect(r.stdoutTail.contains("TAILMARK"), "tail should include the END of stream: \(r.stdoutTail)")
        await runtime.purgeAll()
    }

    await test("SwiftBuildRunner.run returns timedOut + jobId when the cap is hit (job left running)") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("timeout"))
        let r = try await SwiftBuildRunner.run(
            runtime: runtime, command: "sleep 30", workingDir: nil, env: [:],
            label: "t", timeoutSec: 0.3, tailBytes: 1024, pollIntervalSec: 0.05
        )
        try expect(r.timedOut, "expected timedOut")
        try expect(!r.completed, "should not be completed")
        try expect(!r.succeeded, "should not be succeeded")
        try expect(r.exitCode == nil, "exitCode should be nil while running")
        try expect(r.status == nil, "status should be nil while running")
        try expect(!r.jobId.isEmpty, "jobId must be handed back so caller can poll/kill")
        // The job should still be running — verify via the runtime, then clean up.
        let live = try await runtime.status(id: r.jobId)
        try expect(live.status == .running, "job should still be running, got \(live.status.rawValue)")
        _ = try? await runtime.kill(id: r.jobId, force: true)
        await runtime.purgeAll()
    }

    await test("SwiftBuildRunner.run honours env (passes vars to the child)") {
        let runtime = BgProcessRuntime(baseDir: sbTempDir("env"))
        let r = try await SwiftBuildRunner.run(
            runtime: runtime, command: "echo \"$FB_MARKER\"", workingDir: nil,
            env: ["FB_MARKER": "buildtools-ok"],
            label: "t", timeoutSec: 10, tailBytes: 4096, pollIntervalSec: 0.02
        )
        try expect(r.stdoutTail.contains("buildtools-ok"), "env not passed: \(r.stdoutTail)")
        await runtime.purgeAll()
    }

    // ------------------------------------------------------------------
    // Module envelope shapes via dispatch
    // ------------------------------------------------------------------
    await test("swift_build dispatch returns the success envelope for a fast no-op command") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("disp-build"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        // Override args so the wrapper runs `swift 'true'`? No — we instead
        // drive the runner directly above. Here we assert the ENVELOPE shape:
        // since `swift` may not be installed, the job still starts (bash -c
        // 'exec swift build ...') and terminates quickly (exec failure → 127);
        // the envelope must still be well-formed with ok=true + a jobId.
        let result = try await router.dispatch(toolName: "swift_build", arguments: .object([
            "args": .array([.string("--help")]),
            "timeoutSec": .int(20),
            "tailBytes": .int(2048)
        ]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object") }
        guard case .bool(let ok) = d["ok"], ok else { throw TestError.assertion("expected ok=true, got \(d)") }
        guard case .string(let tool) = d["tool"], tool == "swift_build" else { throw TestError.assertion("wrong tool: \(d)") }
        guard case .string(let jobId) = d["jobId"], !jobId.isEmpty else { throw TestError.assertion("missing jobId: \(d)") }
        guard case .string(let cmd) = d["command"], cmd.hasPrefix("exec swift build") else { throw TestError.assertion("command shape: \(d)") }
        // completed/timedOut/succeeded must all be present booleans.
        guard case .bool = d["completed"] else { throw TestError.assertion("missing completed: \(d)") }
        guard case .bool = d["timedOut"] else { throw TestError.assertion("missing timedOut: \(d)") }
        guard case .bool = d["succeeded"] else { throw TestError.assertion("missing succeeded: \(d)") }
        await runtime.purgeAll()
    }

    await test("make_run dispatch composes `exec make <target>` and returns a well-formed envelope") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("disp-make"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(toolName: "make_run", arguments: .object([
            "target": .string("nonexistent-target-xyz"),
            "cwd": .string(NSTemporaryDirectory()),
            "timeoutSec": .int(20)
        ]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object") }
        guard case .bool(let ok) = d["ok"], ok else { throw TestError.assertion("expected ok=true, got \(d)") }
        guard case .string(let cmd) = d["command"], cmd.hasPrefix("exec make 'nonexistent-target-xyz'") else {
            throw TestError.assertion("command shape: \(d)")
        }
        guard case .string(let jobId) = d["jobId"], !jobId.isEmpty else { throw TestError.assertion("missing jobId") }
        // With no Makefile in the temp cwd, make fails — but the wrapper still
        // returns a clean ok=true envelope carrying the captured non-zero exit.
        if case .bool(let completed) = d["completed"], completed {
            if case .bool(let succeeded) = d["succeeded"] {
                try expect(!succeeded, "make with no Makefile should not succeed: \(d)")
            }
        }
        await runtime.purgeAll()
    }

    await test("swift_test dispatch defaults to no extra args (full suite invocation shape)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        let runtime = BgProcessRuntime(baseDir: sbTempDir("disp-test"))
        await SwiftBuildModule.register(on: router, runtime: runtime)
        let result = try await router.dispatch(toolName: "swift_test", arguments: .object([
            "timeoutSec": .int(20)
        ]))
        guard case .object(let d) = result else { throw TestError.assertion("expected object") }
        guard case .string(let cmd) = d["command"] else { throw TestError.assertion("missing command") }
        // No default args ⇒ bare `exec swift test`.
        try expect(cmd == "exec swift test", "expected bare swift test, got: \(cmd)")
        await runtime.purgeAll()
    }
}
