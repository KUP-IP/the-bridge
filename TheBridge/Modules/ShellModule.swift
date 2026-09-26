// ShellModule.swift – V1-04 Shell Command Execution
// TheBridge · Modules
//
// Two tools: shell_exec (request), run_script (request).
// Auto-escalation and forbidden path enforcement handled by SecurityGate.

import Darwin
import Foundation
import MCP

// MARK: - ShellModule

/// Provides shell command execution and approved script running.
/// Security enforcement (tier gating, auto-escalation, forbidden paths)
/// is handled by SecurityGate at the ToolRouter dispatch level.
public enum ShellModule {

    public static let moduleName = "shell"

    private final class TimeoutFlag: @unchecked Sendable {
        var value = false
    }

    private static func valueToString(_ value: Value) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func valueToInt(_ value: Value?) -> Int? {
        if case .int(let i) = value { return i }
        if case .double(let d) = value { return Int(d) }
        return nil
    }

    private static func lineSummary(_ text: String, head: Int?, tail: Int?) -> (text: String, lineCount: Int, truncated: Bool) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let lineCount = text.isEmpty ? 0 : lines.count
        let headCount = head.map { max(0, $0) }
        let tailCount = tail.map { max(0, $0) }
        guard headCount != nil || tailCount != nil else { return (text, lineCount, false) }
        let h = headCount ?? 0
        let t = tailCount ?? 0
        if lineCount <= h + t || lineCount == 0 { return (text, lineCount, false) }
        var kept: [String] = []
        if h > 0 { kept.append(contentsOf: lines.prefix(h)) }
        kept.append("… [truncated \(lineCount - h - t) middle lines] …")
        if t > 0 { kept.append(contentsOf: lines.suffix(t)) }
        return (kept.joined(separator: "\n"), lineCount, true)
    }

    /// Register all ShellModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: shell_exec – request
        await router.register(ToolRegistration(
            name: "shell_exec",
            module: moduleName,
            tier: .request,
            description: "Run a shell command. Returns {stdout, stderr, exitCode, duration}. Pass timeout (seconds) to override the 600s default for long builds/migrations. Escalates for sudo/rm -rf patterns. Prefer dedicated tools when available: file_list (not ls), file_read (not cat), file_write (not echo >), file_copy (not cp), file_move (not mv), dir_create (not mkdir), file_metadata (not stat), process_list (not ps), clipboard_read/clipboard_write (not pbcopy/pbpaste), screen_capture (not screencapture), credential_read (not security), applescript_exec (not osascript), url_open (not open http(s)/notion URLs — those fail C0 as worktree_target_unresolved). If a dedicated tool is not available on this connection, shell_exec is the correct fallback. Use shell_exec directly for git, make, build tools, package managers, and commands with no dedicated tool equivalent.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute")
                    ]),
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string("Timeout in seconds (default: 600, i.e. 10 minutes). Background commands ending in & are capped at 5s.")
                    ]),
                    "workingDir": .object([
                        "type": .string("string"),
                        "description": .string("Working directory for command execution")
                    ]),
                    "env": .object([
                        "type": .string("object"),
                        "description": .string("Optional environment variables to merge into the process environment. Values must be strings.")
                    ]),
                    "loginShell": .object([
                        "type": .string("boolean"),
                        "description": .string("Run bash as a login shell (-lc) so shell profile PATH/tooling is loaded. Default false.")
                    ]),
                    "stdoutHeadLines": .object([
                        "type": .string("integer"),
                        "description": .string("Optional number of stdout lines to keep from the head of large output.")
                    ]),
                    "stdoutTailLines": .object([
                        "type": .string("integer"),
                        "description": .string("Optional number of stdout lines to keep from the tail of large output.")
                    ]),
                    "stderrHeadLines": .object([
                        "type": .string("integer"),
                        "description": .string("Optional number of stderr lines to keep from the head of large output.")
                    ]),
                    "stderrTailLines": .object([
                        "type": .string("integer"),
                        "description": .string("Optional number of stderr lines to keep from the tail of large output.")
                    ]),
                    "ownerSession": .object([
                        "type": .string("string"),
                        "description": .string("Runtime worktree owner session. Required only when the operation resolves inside a claimed Git worktree.")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let command) = args["command"] else {
                    throw ToolRouterError.invalidArguments(toolName: "shell_exec", reason: "missing required 'command' parameter")
                }

                // v1.7.0: Cap timeout for background commands (F2)
                let isBackground = command.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("&")
                let timeout: Int = {
                    if case .int(let t) = args["timeout"] { return isBackground ? min(t, 5) : t }
                    // v1.9.0 F1+E2: raised default 30 -> 600 to cover builds/migrations
                    return isBackground ? 5 : 600
                }()

                let workingDir: String? = {
                    if case .string(let dir) = args["workingDir"] { return dir }
                    return nil
                }()

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                let loginShell: Bool = { if case .bool(let b) = args["loginShell"] { return b }; return false }()
                process.arguments = [loginShell ? "-lc" : "-c", command]

                // Deterministic PATH bootstrap so common developer tools (node/npm, brew, etc.)
                // are discoverable when running from a GUI app context that may not inherit a login shell.
                var env = ProcessInfo.processInfo.environment
                let defaultPathParts = [
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                    "/opt/homebrew/bin", "/opt/homebrew/sbin",
                    "/usr/local/bin", "/usr/local/sbin"
                ]
                let defaultPath = defaultPathParts.joined(separator: ":")
                if let existing = env["PATH"], !existing.isEmpty {
                    env["PATH"] = defaultPath + ":" + existing
                } else {
                    env["PATH"] = defaultPath
                }
                if case .object(let envArgs) = args["env"] {
                    for (key, value) in envArgs {
                        if let stringValue = Self.valueToString(value) {
                            env[key] = stringValue
                        }
                    }
                }
                process.environment = env

                if let dir = workingDir {
                    process.currentDirectoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let startedAt = Date()
                let startTime = ContinuousClock.now
                let timeoutFlag = TimeoutFlag()

                do {
                    try process.run()
                } catch {
                    let receipt = ProcessLifecycleTruth.classifyShell(
                        command: command,
                        timedOut: false,
                        pid: 0,
                        pidAlive: false,
                        processGroupAlive: false,
                        exitCode: -1,
                        signaled: nil,
                        launchError: error.localizedDescription,
                        startedAt: startedAt,
                        endedAt: Date(),
                        now: Date()
                    )
                    return Self.lifecycleValue(
                        receipt: receipt,
                        stdout: "",
                        stderr: error.localizedDescription,
                        success: false,
                        status: "launch_failed",
                        timedOut: false,
                        timeoutSeconds: timeout,
                        terminationReason: "launch_failed",
                        durationSec: 0,
                        isBackground: isBackground,
                        stdoutLineCount: 0,
                        stderrLineCount: 1,
                        stdoutTruncated: false,
                        stderrTruncated: false
                    )
                }

                // Timeout: SIGTERM then, if still running after 1s, SIGKILL on the
                // requested pid. Process-group ownership stays with BgProcessRuntime;
                // this is residual request-window truth for shell_exec only.
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        timeoutFlag.value = true
                        let pid = process.processIdentifier
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            if process.isRunning {
                                _ = Darwin.kill(pid, SIGKILL)
                            }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeout),
                    execute: timeoutItem
                )

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()
                timeoutItem.cancel()

                let elapsed = ContinuousClock.now - startTime
                let durationSec = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
                let rawStdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let rawStderr = String(data: stderrData, encoding: .utf8) ?? ""
                let stdoutSummary = Self.lineSummary(
                    rawStdout,
                    head: Self.valueToInt(args["stdoutHeadLines"]),
                    tail: Self.valueToInt(args["stdoutTailLines"])
                )
                let stderrSummary = Self.lineSummary(
                    rawStderr,
                    head: Self.valueToInt(args["stderrHeadLines"]),
                    tail: Self.valueToInt(args["stderrTailLines"])
                )
                let pid = process.processIdentifier
                let signaled: Int32? = process.terminationReason == .uncaughtSignal
                    ? process.terminationStatus : nil
                let pidAlive = ProcessLifecycleTruth.processAlive(pid)
                let pgid = pid > 0 ? getpgid(pid) : Int32(-1)
                let groupAlive = ProcessLifecycleTruth.processGroupAlive(pgid > 0 ? pgid : pid)
                let timedOut = timeoutFlag.value
                let receipt = ProcessLifecycleTruth.classifyShell(
                    command: command,
                    timedOut: timedOut,
                    pid: pid,
                    pidAlive: pidAlive,
                    processGroupAlive: groupAlive,
                    exitCode: process.terminationStatus,
                    signaled: signaled,
                    launchError: nil,
                    startedAt: startedAt,
                    endedAt: Date(),
                    now: Date()
                )
                let success = process.terminationStatus == 0 && !timedOut && !receipt.stillRunning
                let terminationReason: String
                if let outcome = receipt.timeoutOutcome {
                    switch outcome {
                    case .verifiedGroupTermination:
                        terminationReason = "timeout_killed"
                    case .requestTimeoutWorkloadContinuing, .ambiguous:
                        terminationReason = outcome.rawValue
                    }
                } else if success {
                    terminationReason = "exited"
                } else if signaled != nil {
                    terminationReason = "signaled"
                } else {
                    terminationReason = "non_zero_exit"
                }
                // Compat: verified timeout kill keeps the historical timeout_killed token
                // in `status` while `terminationReason` carries the classified outcome.
                let statusToken: String
                if success {
                    statusToken = "success"
                } else if timedOut {
                    statusToken = receipt.stillRunning ? "timed_out_still_running" : "timed_out"
                } else if receipt.state == .launchFailed {
                    statusToken = "launch_failed"
                } else {
                    statusToken = "failed"
                }

                return Self.lifecycleValue(
                    receipt: receipt,
                    stdout: stdoutSummary.text,
                    stderr: stderrSummary.text,
                    success: success,
                    status: statusToken,
                    timedOut: timedOut,
                    timeoutSeconds: timeout,
                    terminationReason: terminationReason,
                    durationSec: durationSec,
                    isBackground: isBackground,
                    stdoutLineCount: stdoutSummary.lineCount,
                    stderrLineCount: stderrSummary.lineCount,
                    stdoutTruncated: stdoutSummary.truncated,
                    stderrTruncated: stderrSummary.truncated
                )
            }
        ))

        // MARK: run_script – request
        await router.register(ToolRegistration(
            name: "run_script",
            module: moduleName,
            tier: .request,
            description: "Compatibility surface for allow-listed scripts. Execution currently fails closed because arbitrary scripts cannot prove a complete worktree mutation target set; use shell_exec with an explicit command and workingDir.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scriptName": .object([
                        "type": .string("string"),
                        "description": .string("Name of the script file to execute (e.g., cleanup.py)")
                    ]),
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Optional arguments to pass to the script")
                    ]),
                    "ownerSession": .object([
                        "type": .string("string"),
                        "description": .string("Runtime worktree owner session. Reserved for a future verifiable run_script mutation-target contract; currently cannot override fail-closed behavior.")
                    ])
                ]),
                "required": .array([.string("scriptName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let scriptName) = args["scriptName"] else {
                    throw ToolRouterError.invalidArguments(toolName: "run_script", reason: "missing required 'scriptName' parameter")
                }

                // Validate scripts directory exists
                let scriptsDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".mcp_scripts")
                guard FileManager.default.fileExists(atPath: scriptsDir.path) else {
                    return .object([
                        "error": .string("Scripts directory does not exist: \(scriptsDir.path)")
                    ])
                }

                // Load approved scripts list
                let approvedListPath = scriptsDir.appendingPathComponent(".approved_scripts")
                let approvedScripts: [String]
                if FileManager.default.fileExists(atPath: approvedListPath.path),
                   let data = FileManager.default.contents(atPath: approvedListPath.path),
                   let content = String(data: data, encoding: .utf8) {
                    approvedScripts = content.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                } else {
                    return .object([
                        "error": .string("No approved scripts list found at \(approvedListPath.path)")
                    ])
                }

                // Reject if not on approved list
                guard approvedScripts.contains(scriptName) else {
                    return .object([
                        "error": .string("Script '\(scriptName)' is not on the approved list. Approved: \(approvedScripts.joined(separator: ", "))")
                    ])
                }

                let scriptPath = scriptsDir.appendingPathComponent(scriptName)

                // PKT-373 P1-2: Path traversal prevention -- resolve to canonical path
                let resolvedPath = scriptPath.standardizedFileURL.path
                let resolvedDir = scriptsDir.standardizedFileURL.path
                guard resolvedPath.hasPrefix(resolvedDir + "/") || resolvedPath == resolvedDir else {
                    return .object([
                        "error": .string("Path traversal blocked: resolved path is outside scripts directory")
                    ])
                }

                guard FileManager.default.fileExists(atPath: scriptPath.path) else {
                    return .object([
                        "error": .string("Script file not found: \(scriptPath.path)")
                    ])
                }

                // Parse optional args
                var scriptArgs: [String] = []
                if case .array(let argsArray) = args["args"] {
                    for arg in argsArray {
                        if case .string(let s) = arg {
                            scriptArgs.append(s)
                        }
                    }
                }

                let process = Process()
                process.executableURL = scriptPath
                process.arguments = scriptArgs
                process.currentDirectoryURL = scriptsDir

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()

                // PKT-373 P1-3: Timeout enforcement (default 30s, matching shell_exec)
                let scriptTimeout: Int = {
                    if case .int(let t) = args["timeout"] { return max(1, t) }
                    return 30
                }()
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(scriptTimeout),
                    execute: timeoutItem
                )

                // PKT-373 P0-3: Read pipes BEFORE waitUntilExit to prevent deadlock
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()
                timeoutItem.cancel()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return .object([
                    "stdout": .string(stdout),
                    "stderr": .string(stderr),
                    "exitCode": .int(Int(process.terminationStatus))
                ])
            }
        ))
    }

    private static func lifecycleValue(
        receipt: ProcessLifecycleReceipt,
        stdout: String,
        stderr: String,
        success: Bool,
        status: String,
        timedOut: Bool,
        timeoutSeconds: Int,
        terminationReason: String,
        durationSec: Double,
        isBackground: Bool,
        stdoutLineCount: Int,
        stderrLineCount: Int,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) -> Value {
        var obj: [String: Value] = [
            "stdout": .string(stdout),
            "stderr": .string(stderr),
            "exitCode": .int(Int(receipt.exitCode ?? -1)),
            "success": .bool(success),
            "status": .string(status),
            "timedOut": .bool(timedOut),
            "timeoutSeconds": .int(timeoutSeconds),
            "terminationReason": .string(terminationReason),
            "duration": .double(durationSec),
            "backgroundCommand": .bool(isBackground),
            "recoveryHint": .string(isBackground
                ? "Background commands (trailing &) are capped at 5s by the MCP request. For work that must outlive the request, use bg_run (detached, returns immediately) and poll it with bg_poll."
                : "For long-running work, increase timeout — or use bg_run to launch it detached (returns a jobId immediately) and poll with bg_poll / stop with bg_kill."),
            "stdoutLineCount": .int(stdoutLineCount),
            "stderrLineCount": .int(stderrLineCount),
            "stdoutTruncated": .bool(stdoutTruncated),
            "stderrTruncated": .bool(stderrTruncated),
            "terminalState": .string(receipt.state.rawValue),
            "stillRunning": .bool(receipt.stillRunning),
            "descendantCleanup": .string(receipt.descendantCleanup.rawValue),
            "commandHash": .string(receipt.commandHash),
            "supervisorPid": .int(Int(receipt.supervisorPid)),
            "observedAt": .double(receipt.observedAt.timeIntervalSince1970)
        ]
        if let outcome = receipt.timeoutOutcome {
            obj["timeoutOutcome"] = .string(outcome.rawValue)
        }
        if let signal = receipt.signal {
            obj["signal"] = .int(Int(signal))
        }
        if let launchError = receipt.launchError {
            obj["launchError"] = .string(launchError)
        }
        if let pid = receipt.rootPid {
            obj["rootPid"] = .int(Int(pid))
        }
        if let pgid = receipt.pgid {
            obj["pgid"] = .int(Int(pgid))
        }
        return .object(obj)
    }
}
