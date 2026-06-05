// SwiftBuildModule.swift — FB [buildtools]: swift_build / swift_test / make_run
// NotionBridge · Modules · swift/
//
// First-class build/test MCP tools that wrap the EXISTING BgProcessRuntime
// (bg_process_start + poll-status + tail-on-failure) into a single blocking
// call. Long builds routinely exceed the ~60s MCP transport request cap when
// run through `shell_exec`, which forced executors to hand-roll the
// nohup → bg_process_start → poll bg_process_status → bg_process_logs dance
// on every invocation. These wrappers do that dance once, in typed Swift:
//
//   1. start the command as a detached bg_process job (own process group);
//   2. poll bg_process_status on a fixed interval until the job is terminal
//      OR a wall-clock cap is reached (then the job is left running and the
//      caller is handed the jobId to keep polling / kill);
//   3. on completion, return the exit code plus a tail of stdout AND stderr
//      (tail-on-failure surfaces the error context inline without a second
//      round-trip to bg_process_logs).
//
// Thin + typed: all process lifecycle lives in BgProcessRuntime. This module
// only builds the command line, drives the poll loop (SwiftBuildRunner), and
// shapes the result envelope. Tier .request — spawning detached processes is
// privileged, identical to the underlying bg_process_* tools.

import Foundation
import MCP

// MARK: - Runner core (pure, testable)

/// Outcome of driving a bg_process job to completion (or to the wall-clock
/// cap). Pure value type so the poll/assemble logic is unit-testable against
/// a real BgProcessRuntime running fast shell commands.
public struct SwiftBuildResult: Sendable, Equatable {
    public let jobId: String
    public let command: String
    public let label: String
    /// True iff the job reached a terminal state before `timedOut`.
    public let completed: Bool
    /// True iff the poll loop hit the wall-clock cap with the job still running.
    public let timedOut: Bool
    /// Terminal status raw value ("done"|"failed"|"killed"|"unknown"); nil if
    /// still running at timeout.
    public let status: String?
    /// Process exit code; nil while running. 0 ⇒ success.
    public let exitCode: Int32?
    /// True iff the job completed with exitCode == 0.
    public let succeeded: Bool
    public let stdoutTail: String
    public let stderrTail: String
    /// Total byte size of each stream (so the caller knows if the tail is
    /// truncated and can page the rest via bg_process_logs).
    public let stdoutBytes: Int
    public let stderrBytes: Int

    public init(
        jobId: String, command: String, label: String,
        completed: Bool, timedOut: Bool, status: String?,
        exitCode: Int32?, succeeded: Bool,
        stdoutTail: String, stderrTail: String,
        stdoutBytes: Int, stderrBytes: Int
    ) {
        self.jobId = jobId; self.command = command; self.label = label
        self.completed = completed; self.timedOut = timedOut; self.status = status
        self.exitCode = exitCode; self.succeeded = succeeded
        self.stdoutTail = stdoutTail; self.stderrTail = stderrTail
        self.stdoutBytes = stdoutBytes; self.stderrBytes = stderrBytes
    }
}

/// Drives BgProcessRuntime: start → poll → tail. No tool/MCP knowledge.
public enum SwiftBuildRunner {

    /// Default tail size, in bytes, returned for each stream.
    public static let defaultTailBytes = 8192
    /// Default wall-clock cap (seconds) before the loop returns control with
    /// the job still running. Generous — release builds can take minutes.
    public static let defaultTimeoutSec: Double = 600
    /// Poll interval (seconds) between bg_process_status reads.
    public static let pollIntervalSec: Double = 0.25

    /// Read the last `tailBytes` of one stream via the runtime's paginated
    /// logs API, returning (text, totalBytes). Reads from the tail offset so
    /// only the relevant chunk crosses the actor boundary.
    static func tail(
        _ runtime: BgProcessRuntime, id: String, stream: String, tailBytes: Int
    ) async -> (text: String, total: Int) {
        // Probe totalBytes with a zero-length read (n=0 is clamped to an empty
        // chunk but the page still reports totalBytes), then read the tail.
        guard let probe = try? await runtime.logs(id: id, stream: stream, cursor: 0, n: 0) else {
            return ("", 0)
        }
        let total = probe.totalBytes
        let start = max(0, total - tailBytes)
        guard let page = try? await runtime.logs(id: id, stream: stream, cursor: start, n: tailBytes) else {
            return ("", total)
        }
        return (page.text, total)
    }

    /// Start `command` and block until terminal or the wall-clock cap.
    ///
    /// - Returns: a `SwiftBuildResult`. On a start failure the BgProcessError
    ///   propagates to the caller (the module turns it into a structured
    ///   error envelope).
    public static func run(
        runtime: BgProcessRuntime,
        command: String,
        workingDir: String?,
        env: [String: String],
        label: String,
        timeoutSec: Double,
        tailBytes: Int,
        pollIntervalSec: Double = pollIntervalSec
    ) async throws -> SwiftBuildResult {
        let meta = try await runtime.start(
            command: command, workingDir: workingDir, env: env, label: label
        )
        let id = meta.id
        let deadline = Date().addingTimeInterval(timeoutSec)

        var terminal: BgProcessJobMeta? = nil
        while Date() < deadline {
            if let m = try? await runtime.status(id: id), m.status != .running {
                terminal = m
                break
            }
            let ns = UInt64(max(0.01, pollIntervalSec) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
        // One final read in case the job finished exactly at the boundary.
        if terminal == nil, let m = try? await runtime.status(id: id), m.status != .running {
            terminal = m
        }

        let (outTail, outTotal) = await tail(runtime, id: id, stream: "stdout", tailBytes: tailBytes)
        let (errTail, errTotal) = await tail(runtime, id: id, stream: "stderr", tailBytes: tailBytes)

        if let m = terminal {
            let code = m.exitCode
            return SwiftBuildResult(
                jobId: id, command: command, label: label,
                completed: true, timedOut: false,
                status: m.status.rawValue,
                exitCode: code,
                succeeded: (m.status == .done && code == 0),
                stdoutTail: outTail, stderrTail: errTail,
                stdoutBytes: outTotal, stderrBytes: errTotal
            )
        } else {
            // Still running at the cap — hand the caller the jobId so they can
            // keep polling or kill it. NOT a failure of the wrapper.
            return SwiftBuildResult(
                jobId: id, command: command, label: label,
                completed: false, timedOut: true,
                status: nil, exitCode: nil, succeeded: false,
                stdoutTail: outTail, stderrTail: errTail,
                stdoutBytes: outTotal, stderrBytes: errTotal
            )
        }
    }
}

// MARK: - MCP module

public enum SwiftBuildModule {
    public static let moduleName = "swift"

    /// Build a `swift build`/`swift test` command line from the typed pieces.
    /// `subcommand` is the swift verb ("build"/"test"); extra args are
    /// shell-quoted and appended. `exec` replaces the bash shell so signals
    /// from bg_process_kill reach the compiler/test process directly.
    public static func swiftCommand(subcommand: String, args: [String]) -> String {
        var parts = ["swift", subcommand]
        parts.append(contentsOf: args.map { GhModule.shellQuote($0) })
        return "exec " + parts.joined(separator: " ")
    }

    public static func makeCommand(target: String?, args: [String]) -> String {
        var parts = ["make"]
        if let t = target, !t.isEmpty { parts.append(GhModule.shellQuote(t)) }
        parts.append(contentsOf: args.map { GhModule.shellQuote($0) })
        return "exec " + parts.joined(separator: " ")
    }

    /// Shared argument extraction for all three tools.
    public struct CommonArgs {
        public var args: [String] = []
        public var cwd: String? = nil
        public var env: [String: String] = [:]
        public var label: String? = nil
        public var timeoutSec: Double = SwiftBuildRunner.defaultTimeoutSec
        public var tailBytes: Int = SwiftBuildRunner.defaultTailBytes
    }

    public static func parseCommon(_ arguments: Value) -> CommonArgs {
        var out = CommonArgs()
        guard case .object(let obj) = arguments else { return out }
        if case .array(let extra) = obj["args"] {
            for v in extra { if case .string(let s) = v { out.args.append(s) } }
        }
        if case .string(let s) = obj["cwd"], !s.isEmpty { out.cwd = s }
        if case .object(let e) = obj["env"] {
            for (k, v) in e { if case .string(let s) = v { out.env[k] = s } }
        }
        if case .string(let s) = obj["label"], !s.isEmpty { out.label = s }
        // Accept double or int for timeout.
        if case .double(let d) = obj["timeoutSec"], d > 0 { out.timeoutSec = d }
        else if case .int(let i) = obj["timeoutSec"], i > 0 { out.timeoutSec = Double(i) }
        if case .int(let n) = obj["tailBytes"], n > 0 { out.tailBytes = n }
        return out
    }

    static func resultToValue(_ tool: String, _ r: SwiftBuildResult) -> Value {
        var dict: [String: Value] = [
            "ok":          .bool(true),
            "tool":        .string(tool),
            "jobId":       .string(r.jobId),
            "label":       .string(r.label),
            "command":     .string(r.command),
            "completed":   .bool(r.completed),
            "timedOut":    .bool(r.timedOut),
            "succeeded":   .bool(r.succeeded),
            "stdoutTail":  .string(r.stdoutTail),
            "stderrTail":  .string(r.stderrTail),
            "stdoutBytes": .int(r.stdoutBytes),
            "stderrBytes": .int(r.stderrBytes)
        ]
        if let s = r.status { dict["status"] = .string(s) }
        if let c = r.exitCode { dict["exitCode"] = .int(Int(c)) }
        if r.timedOut {
            dict["hint"] = .string("still running at the wall-clock cap — keep polling bg_process_status / bg_process_logs with id=\(r.jobId), or bg_process_kill it")
        }
        return .object(dict)
    }

    static func errorValue(_ tool: String, status: String, reason: String) -> Value {
        .object([
            "ok":     .bool(false),
            "status": .string(status),
            "tool":   .string(tool),
            "error":  .string(reason)
        ])
    }

    /// Map a thrown BgProcessError → structured error envelope.
    static func bgErrorEnvelope(_ tool: String, _ error: Error) -> Value {
        if let e = error as? BgProcessError {
            switch e {
            case .capabilityMissing(let m):
                return errorValue(tool, status: "capability_missing", reason: m)
            case .invalidArgument(let m):
                return errorValue(tool, status: "invalid_argument", reason: m)
            default:
                return errorValue(tool, status: "failed", reason: e.localizedDescription)
            }
        }
        return errorValue(tool, status: "failed", reason: "\(error)")
    }

    /// Shared handler body for the swift_* tools.
    static func handleSwift(
        tool: String, subcommand: String, defaultArgs: [String],
        arguments: Value, runtime: BgProcessRuntime
    ) async -> Value {
        let c = parseCommon(arguments)
        let effectiveArgs = c.args.isEmpty ? defaultArgs : c.args
        let command = swiftCommand(subcommand: subcommand, args: effectiveArgs)
        let label = c.label ?? tool
        do {
            let r = try await SwiftBuildRunner.run(
                runtime: runtime, command: command, workingDir: c.cwd,
                env: c.env, label: label, timeoutSec: c.timeoutSec, tailBytes: c.tailBytes
            )
            return resultToValue(tool, r)
        } catch {
            return bgErrorEnvelope(tool, error)
        }
    }

    /// Shared handler body for make_run.
    static func handleMake(arguments: Value, runtime: BgProcessRuntime) async -> Value {
        let tool = "make_run"
        let c = parseCommon(arguments)
        let target: String? = {
            if case .object(let obj) = arguments, case .string(let s) = obj["target"], !s.isEmpty { return s }
            return nil
        }()
        let command = makeCommand(target: target, args: c.args)
        let label = c.label ?? tool
        do {
            let r = try await SwiftBuildRunner.run(
                runtime: runtime, command: command, workingDir: c.cwd,
                env: c.env, label: label, timeoutSec: c.timeoutSec, tailBytes: c.tailBytes
            )
            return resultToValue(tool, r)
        } catch {
            return bgErrorEnvelope(tool, error)
        }
    }

    public static func register(
        on router: ToolRouter,
        runtime: BgProcessRuntime = BgProcessRuntime.shared
    ) async {

        // MARK: swift_build
        await router.register(ToolRegistration(
            name: "swift_build",
            module: moduleName,
            tier: .request,
            description: "Run `swift build` under bg_process supervision and BLOCK until it finishes (or a wall-clock cap), returning the exit code plus a tail of stdout/stderr. Use this instead of `shell_exec` for SwiftPM builds: long compiles exceed shell_exec's ~60s request timeout, and this wrapper does the bg_process_start → poll bg_process_status → tail-on-failure dance for you in one call. Default args ['-c','release']; override via `args`. If the build is still running at `timeoutSec` the job keeps running and the returned jobId can be polled with bg_process_status / bg_process_logs or terminated with bg_process_kill.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Args to `swift build`. Default: ['-c','release'].")
                    ]),
                    "cwd": .object(["type": .string("string"), "description": .string("Working directory (tilde-expanded). Default: bridge process cwd.")]),
                    "env": .object(["type": .string("object"), "description": .string("Env vars (string values) merged onto the bridge environment.")]),
                    "label": .object(["type": .string("string"), "description": .string("bg_process label (default 'swift_build').")]),
                    "timeoutSec": .object(["type": .string("number"), "description": .string("Wall-clock cap before returning control with the job still running. Default 600.")]),
                    "tailBytes": .object(["type": .string("integer"), "description": .string("Max bytes of stdout/stderr tail to return per stream. Default 8192.")])
                ])
            ]),
            handler: { arguments in
                await handleSwift(
                    tool: "swift_build", subcommand: "build", defaultArgs: ["-c", "release"],
                    arguments: arguments, runtime: runtime
                )
            }
        ))

        // MARK: swift_test
        await router.register(ToolRegistration(
            name: "swift_test",
            module: moduleName,
            tier: .request,
            description: "Run `swift test` under bg_process supervision and BLOCK until it finishes (or a wall-clock cap), returning the exit code plus a tail of stdout/stderr. Use this instead of `shell_exec` for SwiftPM test runs that exceed shell_exec's ~60s request timeout — the wrapper handles bg_process_start → poll bg_process_status → tail-on-failure in one call. No default args (runs the whole suite); override via `args` (e.g. ['--filter','MyTests']). If still running at `timeoutSec` the returned jobId can be polled with bg_process_status / bg_process_logs or terminated with bg_process_kill.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Args to `swift test` (e.g. ['--filter','MyTests']). Default: none (full suite).")
                    ]),
                    "cwd": .object(["type": .string("string"), "description": .string("Working directory (tilde-expanded). Default: bridge process cwd.")]),
                    "env": .object(["type": .string("object"), "description": .string("Env vars (string values) merged onto the bridge environment.")]),
                    "label": .object(["type": .string("string"), "description": .string("bg_process label (default 'swift_test').")]),
                    "timeoutSec": .object(["type": .string("number"), "description": .string("Wall-clock cap before returning control with the job still running. Default 600.")]),
                    "tailBytes": .object(["type": .string("integer"), "description": .string("Max bytes of stdout/stderr tail to return per stream. Default 8192.")])
                ])
            ]),
            handler: { arguments in
                await handleSwift(
                    tool: "swift_test", subcommand: "test", defaultArgs: [],
                    arguments: arguments, runtime: runtime
                )
            }
        ))

        // MARK: make_run — thin wrapper for projects driven by a Makefile.
        await router.register(ToolRegistration(
            name: "make_run",
            module: moduleName,
            tier: .request,
            description: "Run `make <target>` under bg_process supervision and BLOCK until it finishes (or a wall-clock cap), returning the exit code plus a tail of stdout/stderr. The Makefile-driven sibling of swift_build/swift_test for projects whose build/test entry point is a make target (e.g. `make build`, `make test-floor`). Avoids shell_exec's ~60s request timeout by doing the bg_process_start → poll → tail dance in one call. If still running at `timeoutSec` the returned jobId can be polled with bg_process_status / bg_process_logs or terminated with bg_process_kill.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "target": .object(["type": .string("string"), "description": .string("Make target to run (e.g. 'build', 'test-floor'). Omit to run the default target.")]),
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Extra args appended after the target (e.g. ['-j4'] or VAR=value overrides).")
                    ]),
                    "cwd": .object(["type": .string("string"), "description": .string("Working directory (tilde-expanded). Default: bridge process cwd.")]),
                    "env": .object(["type": .string("object"), "description": .string("Env vars (string values) merged onto the bridge environment.")]),
                    "label": .object(["type": .string("string"), "description": .string("bg_process label (default 'make_run').")]),
                    "timeoutSec": .object(["type": .string("number"), "description": .string("Wall-clock cap before returning control with the job still running. Default 600.")]),
                    "tailBytes": .object(["type": .string("integer"), "description": .string("Max bytes of stdout/stderr tail to return per stream. Default 8192.")])
                ])
            ]),
            handler: { arguments in
                await handleMake(arguments: arguments, runtime: runtime)
            }
        ))
    }
}
