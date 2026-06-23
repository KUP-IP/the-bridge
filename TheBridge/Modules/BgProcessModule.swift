// BgProcessModule.swift — Tool-Dev (PRJCT-2754): detached background execution
// TheBridge · Modules
//
// Three tools — bg_run (.request) / bg_poll (.open, read-only) / bg_kill (.notify) —
// that give an agent a non-blocking way to launch a long-running shell command,
// poll its progress, and stop it. They are the dedicated answer to shell_exec's
// transport-cap problem: shell_exec MUST read the child to completion within the
// MCP request window (and caps trailing-& commands at 5s), so a multi-minute
// build/migration cannot run through it. bg_run returns IMMEDIATELY with the
// job's file paths; the work continues detached and is observed via bg_poll.
//
// DESIGN (file-backed, stateless job state — no in-process registry):
//   • All state lives under BridgePaths.applicationSupport(.bgProcess)
//     ("…/The Bridge/bg-process/") as a flat triple keyed by jobId:
//       <ISO-ts>-<uuid>.log   — combined stdout+stderr (created on spawn)
//       <ISO-ts>-<uuid>.done  — written ONLY on exit; contains the exit code
//       <ISO-ts>-<uuid>.pid   — the detached child's PID (sidecar)
//     Because the sentinel/exit-code is a file, job state survives a Bridge
//     restart — bg_poll re-derives status purely from the filesystem + a
//     kill(pid,0) liveness probe, exactly like ShellModule reads PATH from the
//     environment rather than holding process handles.
//   • bg_run spawns `nohup bash -[l]c "{ <cmd> ; } > LOG 2>&1; echo $? > DONE" &`
//     fully detached (mirrors the Process/Pipe/PATH-bootstrap pattern of
//     ShellModule.shell_exec). The launcher shell prints the child PID and exits
//     at once; we read ONLY that tiny PID line — we never attach to or
//     readDataToEndOfFile() the child's pipes, so the call cannot block and no
//     waited pipe is captured across the detached spawn (strict-concurrency safe).
//   • bg_poll(jobId,tailLines?): .done present ⇒ exited + exitCode + tail +
//     duration; else pid alive (kill(pid,0)==0) ⇒ running + tail; else (pid dead,
//     no sentinel) ⇒ terminated (killed/crashed without writing the sentinel).
//   • bg_kill(jobId,force?): read the pid sidecar ⇒ SIGTERM (SIGKILL when force).
//
// PATH-CONFINEMENT: bg_poll / bg_kill resolve the jobId to a canonical path under
// the bg-process dir and refuse anything that escapes it (mirrors run_script's
// canonical-path traversal guard). A jobId is additionally constrained to the
// `<ts>-<uuid>` charset so "../" can never reach the path layer in the first place.

import Foundation
import Darwin
import MCP

// MARK: - BgProcessModule

public enum BgProcessModule {

    public static let moduleName = "bgprocess"

    // MARK: Value helpers (mirror ShellModule)

    private static func valueToString(_ value: Value?) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func valueToInt(_ value: Value?) -> Int? {
        if case .int(let i) = value { return i }
        if case .double(let d) = value { return Int(d) }
        return nil
    }

    private static func valueToBool(_ value: Value?) -> Bool {
        if case .bool(let b) = value { return b }
        return false
    }

    // MARK: Paths + jobId

    /// Canonical bg-process base directory, created on demand.
    private static func ensureBaseDir() throws -> URL {
        try BridgePaths.ensureApplicationSupport(.bgProcess)
    }

    /// Allowed jobId charset: lowercase hex, digits, and a single dash separator
    /// (`yyyyMMdd-HHmmssSSS-<uuid8>`). Rejecting everything else means a hostile
    /// jobId ("../../etc/passwd") never reaches the filesystem layer.
    private static func isWellFormedJobId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return id.allSatisfy { allowed.contains($0) }
    }

    private static func makeJobId() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        // Millisecond precision so two jobs started in the same second never
        // collide on the timestamp prefix (the uuid suffix is the real key).
        f.dateFormat = "yyyyMMdd-HHmmssSSS"
        let stamp = f.string(from: Date())
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return "\(stamp)-\(suffix)"
    }

    /// Resolve a jobId to the canonical {log,done,pid} URLs, confined to the
    /// bg-process dir. Throws if the id is malformed or resolves outside the dir.
    private static func resolvePaths(jobId: String) throws -> (log: URL, done: URL, pid: URL) {
        guard isWellFormedJobId(jobId) else {
            throw ToolRouterError.invalidArguments(toolName: "bg_process", reason: "malformed jobId")
        }
        let base = try ensureBaseDir()
        let baseResolved = base.standardizedFileURL.path
        func confined(_ ext: String) throws -> URL {
            let url = base.appendingPathComponent("\(jobId).\(ext)")
            let resolved = url.standardizedFileURL.path
            guard resolved.hasPrefix(baseResolved + "/") else {
                throw ToolRouterError.invalidArguments(toolName: "bg_process", reason: "path traversal blocked")
            }
            return url
        }
        return (try confined("log"), try confined("done"), try confined("pid"))
    }

    // MARK: Tail

    /// Return the last `tailLines` lines of `text` (whole text when nil/<=0).
    private static func tail(_ text: String, lines: Int?) -> String {
        guard let n = lines, n > 0 else { return text }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard parts.count > n else { return text }
        return parts.suffix(n).joined(separator: "\n")
    }

    private static func readFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: PATH bootstrap (mirrors ShellModule)

    private static func bootstrappedPath() -> String {
        let defaultPathParts = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin"
        ]
        let defaultPath = defaultPathParts.joined(separator: ":")
        if let existing = ProcessInfo.processInfo.environment["PATH"], !existing.isEmpty {
            return defaultPath + ":" + existing
        }
        return defaultPath
    }

    /// Register all BgProcessModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: bg_run — request
        await router.register(ToolRegistration(
            name: "bg_run",
            module: moduleName,
            tier: .request,
            description: "Launch a shell command DETACHED and return immediately (does not block). Use this — not shell_exec — for work that outlives the MCP request window: long builds, migrations, test suites, watchers. Returns {jobId, pid, logPath, donePath, status:'started'}. The command's combined stdout+stderr streams to logPath; on exit the exit code is written to donePath. Poll progress with bg_poll(jobId); stop it with bg_kill(jobId). Set loginShell:true to load your shell profile PATH/tooling.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute detached.")
                    ]),
                    "workingDir": .object([
                        "type": .string("string"),
                        "description": .string("Optional working directory for command execution.")
                    ]),
                    "env": .object([
                        "type": .string("object"),
                        "description": .string("Optional environment variables to merge into the process environment. Values must be strings.")
                    ]),
                    "loginShell": .object([
                        "type": .string("boolean"),
                        "description": .string("Run bash as a login shell (-lc) so shell profile PATH/tooling is loaded. Default false.")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Optional human-readable label echoed back for your own tracking.")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let command) = args["command"] else {
                    throw ToolRouterError.invalidArguments(toolName: "bg_run", reason: "missing required 'command' parameter")
                }
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ToolRouterError.invalidArguments(toolName: "bg_run", reason: "command is empty")
                }

                let jobId = makeJobId()
                let paths = try resolvePaths(jobId: jobId)
                // Touch the log so bg_poll has something to read even before the
                // child's first write, and so its path is reported truthfully.
                FileManager.default.createFile(atPath: paths.log.path, contents: Data())

                let loginShell = valueToBool(args["loginShell"])
                let innerFlag = loginShell ? "-lc" : "-c"

                // The worker shell runs the command in a SUBSHELL `( … )`,
                // redirects ALL output to the log, then writes the exit code to the
                // .done sentinel — that write is the atomic "finished" signal
                // bg_poll keys on. The subshell (NOT a `{ …; }` group) is
                // load-bearing: a group runs in the SAME shell, so a user command
                // ending in `exit N` would terminate the worker before it reaches
                // the sentinel write, leaving the job stuck looking "terminated". A
                // subshell confines the user `exit` so `$?` is captured and the
                // sentinel is always written.
                //
                // `command` is embedded RAW: the single `escapedWorker` transform
                // below single-quote-escapes the ENTIRE worker for the launcher's
                // `'…'` wrapping, which already passes the user command through
                // verbatim. Escaping the command a SECOND time here would
                // double-escape any embedded single quote and corrupt a command
                // like `echo "it's"` (regression-tested in BgProcessModuleTests).
                let logPath = paths.log.path
                let donePath = paths.done.path
                let workerScript = "( \(command) ) > '\(logPath)' 2>&1; echo $? > '\(donePath)'"
                let escapedWorker = workerScript.replacingOccurrences(of: "'", with: "'\\''")

                // Launcher: start the worker via nohup, fully detached (its own
                // stdio → /dev/null), background it, and print ONLY the child PID.
                // The launcher shell exits the instant it prints the PID, so the
                // PID-capture below returns immediately and we never hold the
                // child's pipes (strict-concurrency safe: no waited pipe is
                // captured across the detached spawn).
                let launcher = "nohup bash \(innerFlag) '\(escapedWorker)' </dev/null >/dev/null 2>&1 & echo $!"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", launcher]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = bootstrappedPath()
                if case .object(let envArgs) = args["env"] {
                    for (key, value) in envArgs {
                        if let stringValue = valueToString(value) { env[key] = stringValue }
                    }
                }
                process.environment = env

                if let dir = valueToString(args["workingDir"]), !dir.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                }

                let pidPipe = Pipe()
                process.standardOutput = pidPipe
                process.standardError = Pipe()

                try process.run()
                // The launcher exits right after `echo $!`, so this returns at once.
                let pidData = pidPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let pidString = String(data: pidData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let pid = Int32(pidString), pid > 0 else {
                    return .object([
                        "error": .string("failed to launch detached process (no pid returned)"),
                        "status": .string("failed"),
                        "jobId": .string(jobId)
                    ])
                }

                // Persist the pid sidecar so bg_poll / bg_kill can find the child
                // across a Bridge restart (file-backed, stateless job state).
                try? pidString.write(to: paths.pid, atomically: true, encoding: .utf8)

                return .object([
                    "jobId": .string(jobId),
                    "pid": .int(Int(pid)),
                    "logPath": .string(paths.log.path),
                    "donePath": .string(paths.done.path),
                    "status": .string("started"),
                    "label": valueToString(args["label"]).map { Value.string($0) } ?? .null
                ])
            }
        ))

        // MARK: bg_poll — open (read-only)
        await router.register(ToolRegistration(
            name: "bg_poll",
            module: moduleName,
            tier: .open,
            description: "Check on a detached job started by bg_run. Returns {jobId, status, exitCode?, tail, logPath, duration?}. status is 'running' while the process is alive, 'exited' once it finished (with exitCode + duration in seconds), or 'terminated' if the process died without recording an exit code (killed/crashed). tail is the last tailLines lines of combined output (default 50). Poll repeatedly until status != 'running'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "jobId": .object([
                        "type": .string("string"),
                        "description": .string("The jobId returned by bg_run.")
                    ]),
                    "tailLines": .object([
                        "type": .string("integer"),
                        "description": .string("Number of trailing log lines to include (default 50).")
                    ])
                ]),
                "required": .array([.string("jobId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let jobId) = args["jobId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "bg_poll", reason: "missing required 'jobId' parameter")
                }
                let paths = try resolvePaths(jobId: jobId)

                // A job exists iff its log file exists (created at spawn).
                guard FileManager.default.fileExists(atPath: paths.log.path) else {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("not_found"),
                        "error": .string("no such job (log file absent)")
                    ])
                }

                let tailLines = valueToInt(args["tailLines"]) ?? 50
                let logText = readFile(paths.log)
                let tailText = tail(logText, lines: tailLines)
                let startDate = fileModificationDate(paths.pid) ?? fileModificationDate(paths.log)

                // Terminal: the .done sentinel exists ⇒ the worker finished and
                // recorded its exit code.
                if FileManager.default.fileExists(atPath: paths.done.path) {
                    let doneRaw = readFile(paths.done).trimmingCharacters(in: .whitespacesAndNewlines)
                    let exitCode = Int(doneRaw) ?? -1
                    let endDate = fileModificationDate(paths.done)
                    var out: [String: Value] = [
                        "jobId": .string(jobId),
                        "status": .string("exited"),
                        "exitCode": .int(exitCode),
                        "success": .bool(exitCode == 0),
                        "tail": .string(tailText),
                        "logPath": .string(paths.log.path),
                        "logLineCount": .int(logText.isEmpty ? 0 : logText.split(separator: "\n", omittingEmptySubsequences: false).count)
                    ]
                    if let s = startDate, let e = endDate {
                        out["duration"] = .double(max(0, e.timeIntervalSince(s)))
                    }
                    return .object(out)
                }

                // Not terminal: probe pid liveness. kill(pid,0)==0 ⇒ alive (or a
                // zombie we still own); ESRCH ⇒ gone without a sentinel ⇒ terminated.
                let pidString = readFile(paths.pid).trimmingCharacters(in: .whitespacesAndNewlines)
                let pid = Int32(pidString) ?? -1
                let alive = pid > 0 && Darwin.kill(pid, 0) == 0

                if alive {
                    var out: [String: Value] = [
                        "jobId": .string(jobId),
                        "status": .string("running"),
                        "pid": .int(Int(pid)),
                        "tail": .string(tailText),
                        "logPath": .string(paths.log.path)
                    ]
                    if let s = startDate {
                        out["duration"] = .double(max(0, Date().timeIntervalSince(s)))
                    }
                    return .object(out)
                }

                // pid dead AND no sentinel ⇒ killed/crashed before recording exit.
                return .object([
                    "jobId": .string(jobId),
                    "status": .string("terminated"),
                    "tail": .string(tailText),
                    "logPath": .string(paths.log.path),
                    "note": .string("process is no longer running and wrote no exit code (killed or crashed)")
                ])
            }
        ))

        // MARK: bg_kill — notify
        await router.register(ToolRegistration(
            name: "bg_kill",
            module: moduleName,
            tier: .notify,
            description: "Stop a detached job started by bg_run. Sends SIGTERM by default; pass force:true to send SIGKILL. Returns {jobId, status, signal}. Idempotent: a job that already exited returns status 'already_exited' without signalling.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "jobId": .object([
                        "type": .string("string"),
                        "description": .string("The jobId returned by bg_run.")
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Send SIGKILL instead of SIGTERM. Default false.")
                    ])
                ]),
                "required": .array([.string("jobId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let jobId) = args["jobId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "bg_kill", reason: "missing required 'jobId' parameter")
                }
                let paths = try resolvePaths(jobId: jobId)

                guard FileManager.default.fileExists(atPath: paths.log.path) else {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("not_found"),
                        "error": .string("no such job (log file absent)")
                    ])
                }

                // Already terminal — nothing to signal (idempotent).
                if FileManager.default.fileExists(atPath: paths.done.path) {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("already_exited")
                    ])
                }

                let pidString = readFile(paths.pid).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let pid = Int32(pidString), pid > 0 else {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("no_pid"),
                        "error": .string("no recorded pid for job")
                    ])
                }

                // Already dead (no sentinel) — report terminated, don't signal.
                guard Darwin.kill(pid, 0) == 0 else {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("already_terminated")
                    ])
                }

                let force = valueToBool(args["force"])
                let signal: Int32 = force ? SIGKILL : SIGTERM
                let rc = Darwin.kill(pid, signal)
                guard rc == 0 else {
                    return .object([
                        "jobId": .string(jobId),
                        "status": .string("kill_failed"),
                        "signal": .string(force ? "SIGKILL" : "SIGTERM"),
                        "error": .string("kill(\(pid), \(signal)) failed: \(String(cString: strerror(errno)))")
                    ])
                }
                return .object([
                    "jobId": .string(jobId),
                    "pid": .int(Int(pid)),
                    "status": .string("signalled"),
                    "signal": .string(force ? "SIGKILL" : "SIGTERM")
                ])
            }
        ))
    }
}
