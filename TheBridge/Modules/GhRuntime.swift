// GhRuntime.swift — PKT-742 (Bridge v2.2 · 2.2): GitHub CLI runtime
// TheBridge · Modules · dev/
//
// Thin runtime layer over the `gh` CLI. Provides:
//   - capability detection (PATH lookup + `gh auth status` probe)
//   - synchronous invocation for fast ops (Process + waitUntilExit)
//   - parsing helpers for `gh auth status` output (account / scopes)
//
// Background invocation for long ops is delegated to BgProcessRuntime in
// GhModule.swift; this file stays MCP-framework-agnostic so it is unit-testable
// without tool-router setup.

import Foundation

// MARK: - Errors

public enum GhError: Error, LocalizedError, Equatable, Sendable {
    case capabilityMissing(String)
    case invalidArgument(String)
    case spawnFailed(String)
    case ghFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let r): return "capability_missing: \(r)"
        case .invalidArgument(let r):  return "invalid_argument: \(r)"
        case .spawnFailed(let r):      return "spawn_failed: \(r)"
        case .ghFailed(let c, let e):  return "gh_failed (exit=\(c)): \(e)"
        }
    }
}

// MARK: - Value types

public struct GhInvocationResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Double
}

public struct GhCapability: Sendable {
    public let ok: Bool
    public let path: String?
    public let version: String?
    public let account: String?
    public let scopes: [String]
    public let reason: String?
}

// MARK: - Runtime

public actor GhRuntime {
    public static let shared = GhRuntime()

    private let resolvedPath: String?

    public init(ghPath: String? = nil) {
        if let p = ghPath {
            self.resolvedPath = FileManager.default.isExecutableFile(atPath: p) ? p : nil
        } else {
            self.resolvedPath = GhRuntime.locateGh()
        }
    }

    /// Resolved path to the `gh` binary, or nil if unavailable.
    public var path: String? { resolvedPath }

    /// Locate `gh` by checking common Homebrew + system paths, then `/usr/bin/which`.
    nonisolated static func locateGh() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fallback: /usr/bin/which gh (no shell needed).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["gh"]
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

    // MARK: - Capability

    public func capabilityCheck() async -> GhCapability {
        guard let path = resolvedPath else {
            return GhCapability(
                ok: false, path: nil, version: nil, account: nil, scopes: [],
                reason: "gh CLI not found on PATH (checked /opt/homebrew/bin/gh, /usr/local/bin/gh, /usr/bin/gh, /usr/bin/which gh)"
            )
        }
        // version
        let v: GhInvocationResult
        do { v = try await runGh(["--version"]) }
        catch { v = GhInvocationResult(exitCode: -1, stdout: "", stderr: "\(error)", durationMs: 0) }
        let version = v.stdout.split(separator: "\n").first.map(String.init)

        // auth status (writes to stderr in older gh, stdout in newer — parse both)
        let a: GhInvocationResult
        do { a = try await runGh(["auth", "status"]) }
        catch { a = GhInvocationResult(exitCode: -1, stdout: "", stderr: "\(error)", durationMs: 0) }

        if a.exitCode != 0 {
            let detail = (a.stderr.isEmpty ? a.stdout : a.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GhCapability(
                ok: false, path: path, version: version, account: nil, scopes: [],
                reason: "gh auth status exit=\(a.exitCode): \(detail)"
            )
        }
        let combined = a.stdout + "\n" + a.stderr
        return GhCapability(
            ok: true, path: path, version: version,
            account: GhRuntime.parseAccount(combined),
            scopes: GhRuntime.parseScopes(combined),
            reason: nil
        )
    }

    // MARK: - Invocation

    /// Run `gh <args>` synchronously. Throws .capabilityMissing when gh path is unresolved.
    public func runGh(_ args: [String], stdin: String? = nil) async throws -> GhInvocationResult {
        guard let path = resolvedPath else {
            throw GhError.capabilityMissing("gh CLI not on PATH")
        }
        return try await GhRuntime.spawn(executable: path, args: args, stdin: stdin)
    }

    nonisolated static func spawn(
        executable: String,
        args: [String],
        stdin: String? = nil
    ) async throws -> GhInvocationResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GhInvocationResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                // Inherit env so gh sees HOME/keyring + GH_TOKEN if set.
                p.environment = ProcessInfo.processInfo.environment
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError  = errPipe
                if let stdin = stdin {
                    let inPipe = Pipe()
                    p.standardInput = inPipe
                    DispatchQueue.global().async {
                        if let data = stdin.data(using: .utf8) {
                            try? inPipe.fileHandleForWriting.write(contentsOf: data)
                        }
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let started = Date()
                do {
                    try p.run()
                    // Drain stdout and stderr concurrently to prevent pipe-buffer
                    // deadlock when output exceeds ~64 KB (same fix as GitRuntime.spawn).
                    let outBox = _GhPipeDataBox()
                    let errBox = _GhPipeDataBox()
                    let ioGroup = DispatchGroup()
                    ioGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }
                    ioGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        ioGroup.leave()
                    }
                    p.waitUntilExit()
                    ioGroup.wait()
                    let out = String(data: outBox.data, encoding: .utf8) ?? ""
                    let err = String(data: errBox.data, encoding: .utf8) ?? ""
                    let dur = Date().timeIntervalSince(started) * 1000.0
                    cont.resume(returning: GhInvocationResult(
                        exitCode: p.terminationStatus,
                        stdout: out, stderr: err, durationMs: dur
                    ))
                } catch {
                    cont.resume(throwing: GhError.spawnFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Parsers (nonisolated so unit tests can call without await)

    /// Parse the active account from `gh auth status` output.
    /// Matches lines like: `Logged in to github.com account NAME (...)`.
    nonisolated public static func parseAccount(_ text: String) -> String? {
        let pattern = #"account\s+([A-Za-z0-9][A-Za-z0-9_\-]*)"#
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Parse the OAuth scope list from `gh auth status` output.
    /// Matches: `Token scopes: 'a', 'b', 'c'`.
    nonisolated public static func parseScopes(_ text: String) -> [String] {
        let pattern = #"Token scopes?:\s*([^\n\r]+)"#
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else {
            return []
        }
        let line = String(text[range])
        return line.split(separator: ",").compactMap { piece in
            let s = piece.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            return s.isEmpty ? nil : s
        }
    }

    /// Pull the first GitHub URL out of arbitrary text (used to extract PR/issue URL from gh stdout).
    nonisolated public static func firstGitHubURL(in text: String) -> String? {
        let pattern = #"https://github\.com/[^\s\"']+"#
        guard let r = try? NSRegularExpression(pattern: pattern),
              let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range, in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)\n"))
    }
}

private final class _GhPipeDataBox: @unchecked Sendable {
    var data = Data()
}
