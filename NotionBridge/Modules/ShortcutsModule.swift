// ShortcutsModule.swift — PKT-959 (Bridge v3.7·F): shortcuts_* MCP tools
// NotionBridge · Modules
//
// Two thin wrappers around Apple's `/usr/bin/shortcuts` CLI (verified working
// in the v3.7·E audit, PKT-958 — NO entitlement required; the CLI is the
// supported, sandbox-friendly entry point):
//   - shortcuts_list — list shortcut names (+ folders, via `--folders`)
//   - shortcuts_run  — run a shortcut by name, optional input (temp-file via
//     `--input-path`), capture stdout (`--output-path -`)
//
// TIERS (packet directive):
//   - shortcuts_list → .open   (read-only enumeration)
//   - shortcuts_run  → .notify (a Shortcut can do ANYTHING — file writes, web
//     requests, app automation — so it is treated as destructive and is NEVER
//     auto-executed silently; .notify surfaces every run to the operator)
//
// Mirrors GhModule/GhRuntime's process-seam pattern but routes ALL process
// invocation through an injectable `ShortcutsRunning` protocol so the unit
// tests never touch the real CLI (RemindersModule's mock-seam discipline).
// Production uses `CLIShortcutsRunner` (spawns `/usr/bin/shortcuts`); tests
// inject a deterministic mock.

import Foundation
import MCP

// MARK: - Process seam (injectable)

/// Result of one `shortcuts` CLI invocation. Decoupled from `Process` so the
/// mock seam can drive every branch (success, non-zero exit, stderr).
public struct ShortcutsInvocationResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Errors surfaced by the runner seam.
public enum ShortcutsError: Error, LocalizedError, Equatable, Sendable {
    case capabilityMissing(String)
    case spawnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let r): return "capability_missing: \(r)"
        case .spawnFailed(let r):       return "spawn_failed: \(r)"
        }
    }
}

/// Injectable seam over the `shortcuts` CLI. `path` is nil when the CLI is not
/// available (capability_missing short-circuit). `run` executes one argv and
/// returns the captured result. Input passing is handled by the caller (it
/// stages a temp file and forwards `--input-path`), so the seam stays trivial.
public protocol ShortcutsRunning: Sendable {
    /// Resolved path to the `shortcuts` binary, or nil if unavailable.
    var path: String? { get async }
    /// Run `shortcuts <args>` and capture stdout/stderr/exit. Throws
    /// `ShortcutsError.capabilityMissing` when the CLI path is unresolved.
    func run(_ args: [String]) async throws -> ShortcutsInvocationResult
}

// MARK: - Production runner (spawns /usr/bin/shortcuts)

/// Live implementation. Spawns the macOS `shortcuts` CLI off the main actor.
/// Not exercised by the unit tests — those inject the mock.
public final class CLIShortcutsRunner: ShortcutsRunning, @unchecked Sendable {
    private let resolvedPath: String?

    public init(shortcutsPath: String? = nil) {
        if let p = shortcutsPath {
            self.resolvedPath = FileManager.default.isExecutableFile(atPath: p) ? p : nil
        } else {
            self.resolvedPath = CLIShortcutsRunner.locate()
        }
    }

    public var path: String? { get async { resolvedPath } }

    /// The macOS `shortcuts` CLI ships at `/usr/bin/shortcuts`. Fall back to a
    /// `/usr/bin/which` probe for non-standard layouts.
    nonisolated static func locate() -> String? {
        let candidates = ["/usr/bin/shortcuts", "/usr/local/bin/shortcuts"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["shortcuts"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let s = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) { return s }
            }
        } catch {
            // ignore — capability missing
        }
        return nil
    }

    public func run(_ args: [String]) async throws -> ShortcutsInvocationResult {
        guard let path = resolvedPath else {
            throw ShortcutsError.capabilityMissing("shortcuts CLI not on PATH")
        }
        return try await CLIShortcutsRunner.spawn(executable: path, args: args)
    }

    nonisolated static func spawn(
        executable: String,
        args: [String]
    ) async throws -> ShortcutsInvocationResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShortcutsInvocationResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.environment = ProcessInfo.processInfo.environment
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError  = errPipe
                do {
                    try p.run()
                    p.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(returning: ShortcutsInvocationResult(
                        exitCode: p.terminationStatus, stdout: out, stderr: err
                    ))
                } catch {
                    cont.resume(throwing: ShortcutsError.spawnFailed(error.localizedDescription))
                }
            }
        }
    }
}

// MARK: - Module

/// Provides the `shortcuts_*` MCP tools through an injectable CLI seam.
public enum ShortcutsModule {

    public static let moduleName = "shortcuts"

    /// Register `shortcuts_list` + `shortcuts_run`. `runner` defaults to the
    /// live CLI; tests inject a mock seam.
    public static func register(
        on router: ToolRouter,
        runner: ShortcutsRunning = CLIShortcutsRunner()
    ) async {
        await router.register(makeList(runner: runner))
        await router.register(makeRun(runner: runner))
    }

    // ===========================================================
    // MARK: - Tool factories
    // ===========================================================

    static func makeList(runner: ShortcutsRunning) -> ToolRegistration {
        ToolRegistration(
            name: "shortcuts_list",
            module: moduleName,
            tier: .open,
            description: "List the user's Apple Shortcuts by name via `shortcuts list`. "
                + "Set folders:true to list shortcut FOLDERS instead of shortcuts. "
                + "Optionally scope to one folder with folderName (or \"none\" for shortcuts in no folder). "
                + "Read-only enumeration — returns { count, shortcuts:[names] } (or { count, folders:[names] }).",
            inputSchema: schemaObj([
                "folders":    boolProp("List folders instead of shortcuts (default false)."),
                "folderName": strProp("Scope to one folder by name/identifier, or \"none\" for shortcuts not in a folder.")
            ], required: []),
            handler: { arguments in
                let obj = objectArgs(arguments)
                if let cap = await ensureCapability("shortcuts_list", runner: runner) { return cap }

                var args: [String] = ["list"]
                if case .bool(true) = obj["folders"] { args.append("--folders") }
                if case .string(let folder) = obj["folderName"], !folder.isEmpty {
                    args.append(contentsOf: ["--folder-name", folder])
                }
                do {
                    let r = try await runner.run(args)
                    if r.exitCode != 0 { return failedValue("shortcuts_list", r) }
                    let names = parseLines(r.stdout)
                    let key = (args.contains("--folders")) ? "folders" : "shortcuts"
                    return .object([
                        "ok":     .bool(true),
                        "tool":   .string("shortcuts_list"),
                        "count":  .int(names.count),
                        key:      .array(names.map { .string($0) })
                    ])
                } catch let e as ShortcutsError {
                    return shortcutsErrorValue("shortcuts_list", e)
                } catch {
                    return invalidArgsValue("shortcuts_list", error.localizedDescription)
                }
            }
        )
    }

    static func makeRun(runner: ShortcutsRunning) -> ToolRegistration {
        ToolRegistration(
            name: "shortcuts_run",
            module: moduleName,
            tier: .notify,
            description: "Run an Apple Shortcut by name via `shortcuts run <name>` and capture its text output. "
                + "Optional `input` is written to a temp file and passed with --input-path. "
                + "Output is streamed to stdout (--output-path -) and returned as `output`. "
                + "SAFETY: a Shortcut can do anything (write files, hit the network, drive apps), so this is a "
                + ".notify-tier action — never auto-executed silently. Returns { ok, output, exitCode }.",
            inputSchema: schemaObj([
                "name":  strProp("Shortcut name or identifier to run (required)."),
                "input": strProp("Optional text input passed to the shortcut via a temp file (--input-path).")
            ], required: ["name"]),
            handler: { arguments in
                let obj = objectArgs(arguments)
                guard case .string(let name) = obj["name"], !name.isEmpty else {
                    return invalidArgsValue("shortcuts_run", "required: name (non-empty string)")
                }
                if let cap = await ensureCapability("shortcuts_run", runner: runner) { return cap }

                // Optional input → temp file (the CLI takes --input-path, not stdin).
                var inputPath: String? = nil
                if case .string(let input) = obj["input"], !input.isEmpty {
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("bridge-shortcut-input-\(UUID().uuidString).txt")
                    do {
                        try input.data(using: .utf8)?.write(to: tmp, options: .atomic)
                        inputPath = tmp.path
                    } catch {
                        return invalidArgsValue("shortcuts_run", "could not stage input file: \(error.localizedDescription)")
                    }
                }
                defer {
                    if let inputPath { try? FileManager.default.removeItem(atPath: inputPath) }
                }

                var args: [String] = ["run", name]
                if let inputPath { args.append(contentsOf: ["--input-path", inputPath]) }
                // `-` streams the shortcut output to stdout so we can capture it.
                args.append(contentsOf: ["--output-path", "-"])

                do {
                    let r = try await runner.run(args)
                    if r.exitCode != 0 { return failedValue("shortcuts_run", r) }
                    var dict: [String: Value] = [
                        "ok":       .bool(true),
                        "tool":     .string("shortcuts_run"),
                        "name":     .string(name),
                        "exitCode": .int(Int(r.exitCode)),
                        "output":   .string(r.stdout)
                    ]
                    if !r.stderr.isEmpty { dict["stderr"] = .string(r.stderr) }
                    return .object(dict)
                } catch let e as ShortcutsError {
                    return shortcutsErrorValue("shortcuts_run", e)
                } catch {
                    return invalidArgsValue("shortcuts_run", error.localizedDescription)
                }
            }
        )
    }

    // ===========================================================
    // MARK: - Shared helpers
    // ===========================================================

    /// Returns a `capability_missing` envelope value if the CLI is unavailable; nil otherwise.
    static func ensureCapability(_ tool: String, runner: ShortcutsRunning) async -> Value? {
        if await runner.path != nil { return nil }
        return capabilityMissingValue(
            tool,
            "shortcuts CLI not found (expected /usr/bin/shortcuts). Apple Shortcuts requires macOS 12+."
        )
    }

    /// Split CLI stdout into trimmed, non-empty lines (one shortcut/folder per line).
    public static func parseLines(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Envelope builders

    public static func capabilityMissingValue(_ tool: String, _ reason: String) -> Value {
        .object([
            "ok":     .bool(false),
            "status": .string("capability_missing"),
            "tool":   .string(tool),
            "error":  .string(reason)
        ])
    }

    public static func invalidArgsValue(_ tool: String, _ reason: String) -> Value {
        .object([
            "ok":     .bool(false),
            "status": .string("invalid_argument"),
            "tool":   .string(tool),
            "error":  .string(reason)
        ])
    }

    public static func failedValue(_ tool: String, _ r: ShortcutsInvocationResult) -> Value {
        let trimmedErr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let errMsg = trimmedErr.isEmpty ? "shortcuts exited \(r.exitCode)" : trimmedErr
        return .object([
            "ok":       .bool(false),
            "status":   .string("failed"),
            "tool":     .string(tool),
            "exitCode": .int(Int(r.exitCode)),
            "stdout":   .string(r.stdout),
            "stderr":   .string(r.stderr),
            "error":    .string(errMsg)
        ])
    }

    public static func shortcutsErrorValue(_ tool: String, _ e: ShortcutsError) -> Value {
        switch e {
        case .capabilityMissing(let r): return capabilityMissingValue(tool, r)
        case .spawnFailed(let r):
            return .object([
                "ok":     .bool(false),
                "status": .string("failed"),
                "tool":   .string(tool),
                "error":  .string("spawn failed: \(r)")
            ])
        }
    }

    // MARK: - Schema + arg helpers

    static func objectArgs(_ arguments: Value) -> [String: Value] {
        if case .object(let obj) = arguments { return obj }
        return [:]
    }

    static func strProp(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    static func boolProp(_ desc: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    static func schemaObj(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type":       .string("object"),
            "properties": .object(properties),
            "required":   .array(required.map { .string($0) })
        ])
    }
}
