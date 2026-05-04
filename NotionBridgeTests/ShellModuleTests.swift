// ShellModuleTests.swift – V1-04 ShellModule Tests
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

// MARK: - ShellModule Tests

func runShellModuleTests() async {
    print("\n🐚 ShellModule Tests")

    // Set up a fresh router with SecurityGate + AuditLog
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ShellModule.register(on: router)

    // Verify registration
    await test("ShellModule registers 2 tools") {
        let tools = await router.registrations(forModule: "shell")
        try expect(tools.count == 2, "Expected 2 shell tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("shell_exec"), "Missing shell_exec")
        try expect(names.contains("run_script"), "Missing run_script")
    }

    await test("shell_exec tier is request") {
        let tools = await router.registrations(forModule: "shell")
        let shellExec = tools.first(where: { $0.name == "shell_exec" })!
        try expect(shellExec.tier == .request, "Expected request, got \(shellExec.tier.rawValue)")
    }

    await test("run_script tier is request") {
        let tools = await router.registrations(forModule: "shell")
        let runScript = tools.first(where: { $0.name == "run_script" })!
        try expect(runScript.tier == .request, "Expected request, got \(runScript.tier.rawValue)")
    }

    // shell_exec: basic command
    await test("shell_exec runs echo and returns stdout") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo hello_notionbridge")])
        )
        if case .object(let dict) = result,
           case .string(let stdout) = dict["stdout"],
           case .int(let exitCode) = dict["exitCode"],
           case .bool(let success) = dict["success"],
           case .string(let status) = dict["status"] {
            try expect(stdout.contains("hello_notionbridge"), "stdout should contain hello_notionbridge")
            try expect(exitCode == 0, "Expected exit code 0, got \(exitCode)")
            try expect(success, "Expected success true for exit 0")
            try expect(status == "success", "Expected success status, got \(status)")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: stderr capture
    await test("shell_exec captures stderr") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo err_msg >&2")])
        )
        if case .object(let dict) = result,
           case .string(let stderr) = dict["stderr"] {
            try expect(stderr.contains("err_msg"), "stderr should contain err_msg")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: exit code
    await test("shell_exec returns non-zero exit code") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("exit 42")])
        )
        if case .object(let dict) = result,
           case .int(let exitCode) = dict["exitCode"],
           case .bool(let success) = dict["success"],
           case .string(let status) = dict["status"],
           case .string(let reason) = dict["terminationReason"] {
            try expect(exitCode == 42, "Expected exit code 42, got \(exitCode)")
            try expect(!success, "Expected success false for non-zero exit")
            try expect(status == "failed", "Expected failed status, got \(status)")
            try expect(reason == "non_zero_exit", "Expected non_zero_exit reason, got \(reason)")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: duration is returned
    await test("shell_exec returns duration field") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo fast")])
        )
        if case .object(let dict) = result,
           case .double(let duration) = dict["duration"] {
            try expect(duration >= 0, "Duration should be non-negative")
        } else {
            throw TestError.assertion("Expected duration field in result")
        }
    }

    // shell_exec: working directory
    await test("shell_exec respects workingDir") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("pwd"),
                "workingDir": .string("/tmp")
            ])
        )
        if case .object(let dict) = result,
           case .string(let stdout) = dict["stdout"] {
            try expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/private/tmp"
                     || stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp",
                     "Expected /tmp, got \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: timeout (use short timeout with sleep)
    await test("shell_exec timeout terminates long-running process") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("sleep 10 && echo done"),
                "timeout": .int(1)
            ])
        )
        if case .object(let dict) = result,
           case .int(let exitCode) = dict["exitCode"],
           case .bool(let timedOut) = dict["timedOut"],
           case .string(let reason) = dict["terminationReason"] {
            // Process terminated by signal should have non-zero exit code
            try expect(exitCode != 0, "Expected non-zero exit code for timed-out process")
            try expect(timedOut, "Expected timedOut true")
            try expect(reason == "timeout_killed", "Expected timeout_killed reason, got \(reason)")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    await test("shell_exec merges env and summarizes long stdout") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("printf '%s\n' \"$NB_TEST_ENV\"; printf 'line1\nline2\nline3\nline4\n'"),
                "env": .object(["NB_TEST_ENV": .string("bridge-env-ok")]),
                "stdoutHeadLines": .int(2),
                "stdoutTailLines": .int(1)
            ])
        )
        if case .object(let dict) = result,
           case .string(let stdout) = dict["stdout"],
           case .int(let lineCount) = dict["stdoutLineCount"],
           case .bool(let truncated) = dict["stdoutTruncated"] {
            try expect(stdout.contains("bridge-env-ok"), "stdout should include merged env value")
            try expect(stdout.contains("line4"), "stdout should include tail line")
            try expect(lineCount >= 5, "Expected at least 5 stdout lines")
            try expect(truncated, "Expected summarized stdout to be marked truncated")
        } else {
            throw TestError.assertion("Expected stdout summary metadata")
        }
    }

    // shell_exec: missing command param
    await test("shell_exec rejects missing command") {
        do {
            _ = try await router.dispatch(
                toolName: "shell_exec",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing command")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // run_script: rejects unapproved script
    await test("run_script rejects unapproved script name") {
        let result = try await router.dispatch(
            toolName: "run_script",
            arguments: .object(["scriptName": .string("nonexistent_xyz_script.sh")])
        )
        if case .object(let dict) = result,
           case .string(let error) = dict["error"] {
            try expect(error.contains("not on the approved list") || error.contains("does not exist") || error.contains("No approved scripts"),
                       "Expected rejection message, got: \(error)")
        } else {
            throw TestError.assertion("Expected error object for unapproved script")
        }
    }

    // run_script: missing scriptName param
    await test("run_script rejects missing scriptName") {
        do {
            _ = try await router.dispatch(
                toolName: "run_script",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing scriptName")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // Verify tier assignment for high-risk shell execution.
    await test("shell_exec is registered at request tier") {
        let tools = await router.allRegistrations()
        let shellExec = tools.first(where: { $0.name == "shell_exec" })!
        try expect(shellExec.tier == .request, "shell_exec must be request tier")
    }

    // P2-3: Path traversal prevention in run_script (PKT-373)
    await test("run_script rejects path traversal attempts") {
        let result = try await router.dispatch(
            toolName: "run_script",
            arguments: .object(["scriptName": .string("../../etc/passwd")])
        )
        if case .object(let dict) = result,
           case .string(let error) = dict["error"] {
            try expect(error.contains("outside") || error.contains("traversal") || error.contains("not on the approved list") || error.contains("does not exist") || error.contains("Invalid"),
                       "Expected path traversal rejection, got: \(error)")
        } else {
            throw TestError.assertion("Expected error object for path traversal attempt")
        }
    }

    // P2-3: run_script rejects absolute path injection (PKT-373)
    await test("run_script rejects absolute path in scriptName") {
        let result = try await router.dispatch(
            toolName: "run_script",
            arguments: .object(["scriptName": .string("/etc/passwd")])
        )
        if case .object(let dict) = result,
           case .string(let error) = dict["error"] {
            try expect(error.contains("outside") || error.contains("not on the approved list") || error.contains("does not exist") || error.contains("Invalid") || error.contains("absolute"),
                       "Expected rejection for absolute path, got: \(error)")
        } else {
            throw TestError.assertion("Expected error object for absolute path attempt")
        }
    }

}
