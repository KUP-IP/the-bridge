// ShellModuleTests.swift – V1-04 ShellModule Tests
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - ShellModule Tests

private func shellTestErrorCode(
    _ operation: () async throws -> Void
) async -> String? {
    do {
        try await operation()
        return nil
    } catch let error as WorktreeOwnershipError {
        return error.code
    } catch {
        return nil
    }
}

func runShellModuleTests() async {
    print("\n🐚 ShellModule Tests")

    // Set up a fresh router with SecurityGate + AuditLog
    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ShellModule.register(on: router)
    let c0Router = ToolRouter(
        securityGate: gate,
        auditLog: log,
        worktreeOwnershipEnabled: true
    )
    await ShellModule.register(on: c0Router)
    let nonGitWorkingDirectory = FileManager.default.temporaryDirectory.path

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
            arguments: .object([
                "command": .string("echo hello_notionbridge"),
                "workingDir": .string(nonGitWorkingDirectory)
            ])
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
            arguments: .object([
                "command": .string("echo err_msg >&2"),
                "workingDir": .string(nonGitWorkingDirectory)
            ])
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
            arguments: .object([
                "command": .string("exit 42"),
                "workingDir": .string(nonGitWorkingDirectory)
            ])
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
            arguments: .object([
                "command": .string("echo fast"),
                "workingDir": .string(nonGitWorkingDirectory)
            ])
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
                "workingDir": .string(nonGitWorkingDirectory),
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
                "workingDir": .string(nonGitWorkingDirectory),
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

    await test("bounded process output preserves both ends of one oversized read") {
        let output = BoundedProcessOutput(limit: 10)
        output.append(Data("abcdefghijklmnop".utf8))
        let snapshot = output.snapshot()
        try expect(snapshot.truncated, "Expected oversized single read to be marked truncated")
        try expect(snapshot.totalBytes == 16, "Expected all 16 source bytes to be counted")
        try expect(snapshot.capturedBytes == 10, "Expected capture to remain at the configured limit")
        try expect(snapshot.lineCount == 1, "Expected full-stream line accounting despite truncation")
        try expect(snapshot.text.hasPrefix("abcde"), "Expected retained head from oversized read")
        try expect(snapshot.text.hasSuffix("lmnop"), "Expected retained tail from oversized read")
        try expect(snapshot.text.contains("output truncated"), "Expected an explicit omitted-output marker")
    }

    await test("shell_exec drains stderr while stdout remains open") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("printf '%*s' 131072 '' >&2; printf 'drained-ok'"),
                "workingDir": .string(nonGitWorkingDirectory),
                "timeout": .int(3)
            ])
        )
        guard case .object(let dict) = result,
              case .string(let stdout) = dict["stdout"],
              case .int(let stderrBytes) = dict["stderrBytes"],
              case .bool(let timedOut) = dict["timedOut"],
              case .bool(let success) = dict["success"] else {
            throw TestError.assertion("Expected concurrent-drain result metadata")
        }
        try expect(stdout.contains("drained-ok"), "Expected stdout after large stderr write")
        try expect(stderrBytes >= 131_072, "Expected the complete stderr stream to be drained")
        try expect(!timedOut, "Concurrent drain must not hit the request timeout")
        try expect(success, "Command should succeed after both pipes drain")
    }

    await test("shell_exec caps oversized stream while reporting full byte count") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("printf '%*s' 1100000 ''"),
                "workingDir": .string(nonGitWorkingDirectory),
                "timeout": .int(5)
            ])
        )
        guard case .object(let dict) = result,
              case .string(let stdout) = dict["stdout"],
              case .int(let stdoutBytes) = dict["stdoutBytes"],
              case .int(let capturedBytes) = dict["stdoutCapturedBytes"],
              case .bool(let truncated) = dict["stdoutTruncated"],
              case .bool(let captureTruncated) = dict["stdoutCaptureTruncated"] else {
            throw TestError.assertion("Expected bounded stdout metadata")
        }
        try expect(stdoutBytes >= 1_100_000, "Expected total source bytes despite capture cap")
        try expect(capturedBytes <= 1_000_000, "Captured bytes must stay within the documented cap")
        try expect(truncated && captureTruncated, "Oversized capture must be explicitly marked")
        try expect(stdout.contains("output truncated"), "Returned stdout should label the omitted range")
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

    // run_script: opaque script execution fails closed before handler invocation.
    await test("run_script fails closed without a verifiable target contract") {
        let code = await shellTestErrorCode {
            _ = try await c0Router.dispatch(
                toolName: "run_script",
                arguments: .object(["scriptName": .string("nonexistent_xyz_script.sh")])
            )
        }
        try expect(code == "worktree_target_unresolved")
    }

    // run_script: missing scriptName remains fail-closed at the shared guard.
    await test("run_script missing scriptName remains fail closed") {
        let code = await shellTestErrorCode {
            _ = try await c0Router.dispatch(
                toolName: "run_script",
                arguments: .object([:])
            )
        }
        try expect(code == "worktree_target_unresolved")
    }

    // Verify tier assignment for high-risk shell execution.
    await test("shell_exec is registered at request tier") {
        let tools = await router.allRegistrations()
        let shellExec = tools.first(where: { $0.name == "shell_exec" })!
        try expect(shellExec.tier == .request, "shell_exec must be request tier")
    }

    // Opaque run_script arguments cannot bypass the shared fail-closed guard.
    await test("run_script path traversal remains fail closed") {
        let code = await shellTestErrorCode {
            _ = try await c0Router.dispatch(
                toolName: "run_script",
                arguments: .object(["scriptName": .string("../../etc/passwd")])
            )
        }
        try expect(code == "worktree_target_unresolved")
    }

    await test("run_script absolute path remains fail closed") {
        let code = await shellTestErrorCode {
            _ = try await c0Router.dispatch(
                toolName: "run_script",
                arguments: .object(["scriptName": .string("/etc/passwd")])
            )
        }
        try expect(code == "worktree_target_unresolved")
    }

}
