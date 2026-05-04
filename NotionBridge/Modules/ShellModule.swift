// ShellModule.swift – V1-04 Shell Command Execution
// NotionBridge · Modules
//
// Two tools: shell_exec (request), run_script (request).
// Auto-escalation and forbidden path enforcement handled by SecurityGate.

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
            description: "Run a shell command. Returns {stdout, stderr, exitCode, duration}. Pass timeout (seconds) to override the 600s default for long builds/migrations. Escalates for sudo/rm -rf patterns. Prefer dedicated tools when available: file_list (not ls), file_read (not cat), file_write (not echo >), file_copy (not cp), file_move (not mv), dir_create (not mkdir), file_metadata (not stat), process_list (not ps), clipboard_read/clipboard_write (not pbcopy/pbpaste), screen_capture (not screencapture), credential_read (not security), applescript_exec (not osascript). If a dedicated tool is not available on this connection, shell_exec is the correct fallback. Use shell_exec directly for git, make, build tools, package managers, and commands with no dedicated tool equivalent.",
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

                let startTime = ContinuousClock.now
                let timeoutFlag = TimeoutFlag()

                try process.run()

                // Timeout enforcement — terminate process if it exceeds the limit. The response explicitly
                // reports timeout state so agents can distinguish killed work from ordinary non-zero exits.
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        timeoutFlag.value = true
                        process.terminate()
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
                let exitCode = Int(process.terminationStatus)
                let timedOut = timeoutFlag.value
                let success = exitCode == 0 && !timedOut
                let terminationReason: String = timedOut
                    ? "timeout_killed"
                    : (success ? "exited" : "non_zero_exit")

                return .object([
                    "stdout": .string(stdoutSummary.text),
                    "stderr": .string(stderrSummary.text),
                    "exitCode": .int(exitCode),
                    "success": .bool(success),
                    "status": .string(success ? "success" : (timedOut ? "timed_out" : "failed")),
                    "timedOut": .bool(timedOut),
                    "timeoutSeconds": .int(timeout),
                    "terminationReason": .string(terminationReason),
                    "duration": .double(durationSec),
                    "backgroundCommand": .bool(isBackground),
                    "recoveryHint": .string(isBackground ? "Background commands are capped at 5s by the MCP request. Redirect output to a log file and poll the log or process separately." : "For long-running work, increase timeout or run a detached command that writes to a log path."),
                    "stdoutLineCount": .int(stdoutSummary.lineCount),
                    "stderrLineCount": .int(stderrSummary.lineCount),
                    "stdoutTruncated": .bool(stdoutSummary.truncated),
                    "stderrTruncated": .bool(stderrSummary.truncated)
                ])
            }
        ))

        // MARK: run_script – request
        await router.register(ToolRegistration(
            name: "run_script",
            module: moduleName,
            tier: .request,
            description: "Run an allow-listed script from NotionBridge's scripts folder. Requires user approval. Last resort after dedicated tools and shell_exec.",
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
}
