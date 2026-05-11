// RunnerSupport.swift — PKT-781 (Bridge v2.2 · 3.2a)
// Shared scaffold for runner modules (Playwright / Vitest / Lighthouse):
//   1. RunnerProbe — `npx --no-install <runner> --version` with timeout; never installs.
//   2. RunnerToolImpl.handle — common handler body (probe → build argv → bg_process spawn).
// Boundary: no JSON parsing (PKT-3.2b); no e2e (PKT-3.2c).

import Foundation
import MCP

enum RunnerProbe {
    /// `npx --no-install <runner> --version`. Returns true iff exit==0 within timeoutSec.
    static func npxProbe(_ runner: String, timeoutSec: Double = 5) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["npx", "--no-install", runner, "--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeoutSec)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning { proc.terminate(); return false }
        return proc.terminationStatus == 0
    }
}

enum RunnerToolImpl {
    /// Common runner-tool handler. Returns:
    ///   ok=true  { tool, background:true, jobId, pid, label, command, hint }
    ///   ok=false { status: capability_missing | invalid_argument | failed, tool, error }
    static func handle(
        toolName: String,
        runnerName: String,
        defaultArgs: [String],
        arguments: Value,
        bgRuntime: BgProcessRuntime,
        probeOverride: (@Sendable () async -> Bool)?
    ) async -> Value {
        guard case .object(let obj) = arguments else {
            return errorValue(toolName, status: "invalid_argument", reason: "expected object arguments")
        }

        // Probe capability. `??` autoclosure cannot host async, so branch explicitly.
        let available: Bool
        if let override = probeOverride {
            available = await override()
        } else {
            available = await RunnerProbe.npxProbe(runnerName)
        }
        guard available else {
            return errorValue(toolName, status: "capability_missing",
                reason: "`npx --no-install \(runnerName)` failed — \(runnerName) is not installed on PATH or in a discoverable node_modules tree. Install with the appropriate package manager and retry; this tool will never install on its own.")
        }

        // Build argv: --no-install <runner> <user args or defaults>.
        var argv: [String] = ["--no-install", runnerName]
        if case .array(let extra) = obj["args"] {
            for v in extra { if case .string(let s) = v { argv.append(s) } }
        } else {
            argv.append(contentsOf: defaultArgs)
        }
        let quoted = argv.map { GhModule.shellQuote($0) }.joined(separator: " ")
        let command = "exec /usr/bin/env npx \(quoted)"

        let cwd: String? = {
            if case .string(let s) = obj["cwd"], !s.isEmpty { return s }
            return nil
        }()
        var envDict: [String: String] = [:]
        if case .object(let e) = obj["env"] {
            for (k, v) in e { if case .string(let s) = v { envDict[k] = s } }
        }
        let label: String = {
            if case .string(let s) = obj["label"], !s.isEmpty { return s }
            return toolName
        }()

        do {
            let meta = try await bgRuntime.start(command: command, workingDir: cwd, env: envDict, label: label)
            return .object([
                "ok":         .bool(true),
                "tool":       .string(toolName),
                "background": .bool(true),
                "jobId":      .string(meta.id),
                "pid":        .int(Int(meta.pid)),
                "label":      .string(label),
                "command":    .string(command),
                "hint":       .string("poll bg_process_status / bg_process_logs / bg_process_kill with id=\(meta.id)")
            ])
        } catch {
            return errorValue(toolName, status: "failed", reason: "bg_process_start failed: \(error)")
        }
    }

    static func errorValue(_ tool: String, status: String, reason: String) -> Value {
        .object([
            "ok":     .bool(false),
            "status": .string(status),
            "tool":   .string(tool),
            "error":  .string(reason)
        ])
    }
}
