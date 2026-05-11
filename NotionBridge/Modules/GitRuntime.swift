// GitRuntime.swift — PKT-740 W1 (Bridge v2.2 · 2.1): git CLI runtime
// NotionBridge · Modules · dev/
//
// Thin runtime layer over the `git` CLI for the read-only triumvirate
// (git_status / git_diff / git_log). Mirrors GhRuntime structure:
//   - capability detection (PATH lookup + `git --version` probe)
//   - synchronous invocation with optional working directory
//   - parsers for porcelain v2 status and US/RS-delimited log
//
// PKT-740 Wave 1 ships the read-only triumvirate per PM Re-Route #21
// Type A fallback path. Waves 2–3 (git_show/git_blame/git_apply_patch +
// git_worktree/git_create_branch/git_merge) deferred to PKT-740.1 spawn
// per honest-partial Decision #15 — bandwidth call documented in packet.

import Foundation

// MARK: - Errors

public enum GitError: Error, LocalizedError, Equatable, Sendable {
    case capabilityMissing(String)
    case invalidArgument(String)
    case spawnFailed(String)
    case gitFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let r): return "capability_missing: \(r)"
        case .invalidArgument(let r):   return "invalid_argument: \(r)"
        case .spawnFailed(let r):       return "spawn_failed: \(r)"
        case .gitFailed(let c, let e):  return "git_failed (exit=\(c)): \(e)"
        }
    }
}

// MARK: - Value types

public struct GitInvocationResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Double
}

public struct GitCapability: Sendable {
    public let ok: Bool
    public let path: String?
    public let version: String?
    public let reason: String?
}

public struct GitFileStatus: Sendable, Equatable {
    public let path: String
    public let origPath: String?      // for renames/copies
    public let indexStatus: String    // single-char: ., M, A, D, R, C, U
    public let worktreeStatus: String // same
    public let kind: String           // tracked|untracked|ignored|unmerged
}

public struct GitStatusSummary: Sendable {
    public let branch: String?
    public let upstream: String?
    public let oid: String?
    public let ahead: Int
    public let behind: Int
    public let files: [GitFileStatus]
    public let clean: Bool
}

public struct GitLogCommit: Sendable, Equatable {
    public let sha: String
    public let author: String
    public let authorEmail: String
    public let date: String       // ISO 8601
    public let subject: String
}

// MARK: - Runtime

public actor GitRuntime {
    public static let shared = GitRuntime()

    private let resolvedPath: String?

    public init(gitPath: String? = nil) {
        if let p = gitPath {
            self.resolvedPath = FileManager.default.isExecutableFile(atPath: p) ? p : nil
        } else {
            self.resolvedPath = GitRuntime.locateGit()
        }
    }

    public var path: String? { resolvedPath }

    /// Locate `git` via common Apple/Homebrew paths, then `/usr/bin/which`.
    nonisolated static func locateGit() -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["git"]
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

    public func capabilityCheck() async -> GitCapability {
        guard let path = resolvedPath else {
            return GitCapability(ok: false, path: nil, version: nil,
                reason: "git CLI not found on PATH (checked /usr/bin/git, /opt/homebrew/bin/git, /usr/local/bin/git, /usr/bin/which git)")
        }
        let v: GitInvocationResult
        do { v = try await runGit(["--version"], cwd: nil) }
        catch { v = GitInvocationResult(exitCode: -1, stdout: "", stderr: "\(error)", durationMs: 0) }
        guard v.exitCode == 0 else {
            return GitCapability(ok: false, path: path, version: nil,
                reason: "git --version exit=\(v.exitCode): \(v.stderr)")
        }
        let version = v.stdout.split(separator: "\n").first.map(String.init)
        return GitCapability(ok: true, path: path, version: version, reason: nil)
    }

    // MARK: - Invocation

    /// Run `git <args>` synchronously. Throws .capabilityMissing when git path is unresolved.
    public func runGit(_ args: [String], cwd: String? = nil, stdin: String? = nil) async throws -> GitInvocationResult {
        guard let path = resolvedPath else {
            throw GitError.capabilityMissing("git CLI not on PATH")
        }
        return try await GitRuntime.spawn(executable: path, args: args, cwd: cwd, stdin: stdin)
    }

    nonisolated static func spawn(executable: String, args: [String], cwd: String?, stdin: String?) async throws -> GitInvocationResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GitInvocationResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.environment = ProcessInfo.processInfo.environment
                if let cwd = cwd, !cwd.isEmpty {
                    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                }
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
                    p.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    let dur = Date().timeIntervalSince(started) * 1000.0
                    cont.resume(returning: GitInvocationResult(
                        exitCode: p.terminationStatus, stdout: out, stderr: err, durationMs: dur))
                } catch {
                    cont.resume(throwing: GitError.spawnFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Parsers (nonisolated — unit-testable without await)

    /// Parse `git status --porcelain=v2 --branch` output into a structured summary.
    /// Header lines begin with `#`; entries begin with `1`, `2`, `u`, `?`, or `!`.
    nonisolated public static func parsePorcelainV2(_ text: String) -> GitStatusSummary {
        var branch: String?
        var upstream: String?
        var oid: String?
        var ahead = 0
        var behind = 0
        var files: [GitFileStatus] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { continue }
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                branch = (name == "(detached)") ? nil : name
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.oid ") {
                let v = String(line.dropFirst("# branch.oid ".count))
                oid = (v == "(initial)") ? nil : v
            } else if line.hasPrefix("# branch.ab ") {
                let tail = line.dropFirst("# branch.ab ".count)
                for p in tail.split(separator: " ") {
                    if p.hasPrefix("+") { ahead = Int(p.dropFirst()) ?? 0 }
                    else if p.hasPrefix("-") { behind = Int(p.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") {
                // 1 XY sub mH mI mW hH hI path
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count >= 9 else { continue }
                let xy = String(parts[1])
                let path = String(parts[8])
                files.append(GitFileStatus(
                    path: path, origPath: nil,
                    indexStatus: xy.first.map(String.init) ?? ".",
                    worktreeStatus: xy.dropFirst().first.map(String.init) ?? ".",
                    kind: "tracked"))
            } else if line.hasPrefix("2 ") {
                // 2 XY sub mH mI mW hH hI X<score> path<TAB>origPath
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count >= 10 else { continue }
                let xy = String(parts[1])
                let combined = String(parts[9])
                let pieces = combined.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let path = String(pieces[0])
                let orig = pieces.count > 1 ? String(pieces[1]) : nil
                files.append(GitFileStatus(
                    path: path, origPath: orig,
                    indexStatus: xy.first.map(String.init) ?? ".",
                    worktreeStatus: xy.dropFirst().first.map(String.init) ?? ".",
                    kind: "tracked"))
            } else if line.hasPrefix("u ") {
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count >= 11 else { continue }
                let xy = String(parts[1])
                let path = String(parts[10])
                files.append(GitFileStatus(
                    path: path, origPath: nil,
                    indexStatus: xy.first.map(String.init) ?? "U",
                    worktreeStatus: xy.dropFirst().first.map(String.init) ?? "U",
                    kind: "unmerged"))
            } else if line.hasPrefix("? ") {
                files.append(GitFileStatus(
                    path: String(line.dropFirst(2)), origPath: nil,
                    indexStatus: "?", worktreeStatus: "?", kind: "untracked"))
            } else if line.hasPrefix("! ") {
                files.append(GitFileStatus(
                    path: String(line.dropFirst(2)), origPath: nil,
                    indexStatus: "!", worktreeStatus: "!", kind: "ignored"))
            }
        }
        let clean = files.isEmpty && ahead == 0 && behind == 0
        return GitStatusSummary(
            branch: branch, upstream: upstream, oid: oid,
            ahead: ahead, behind: behind, files: files, clean: clean)
    }

    /// Parse `git log --pretty=format:%H<US>%an<US>%ae<US>%aI<US>%s<RS>` output.
    /// Records are separated by `\u{1E}` (RS); fields by `\u{1F}` (US).
    nonisolated public static func parseLog(_ text: String) -> [GitLogCommit] {
        var commits: [GitLogCommit] = []
        let records = text.split(separator: "\u{1E}", omittingEmptySubsequences: true)
        for rec in records {
            let trimmed = rec.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let fields = trimmed.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { continue }
            commits.append(GitLogCommit(
                sha: fields[0], author: fields[1], authorEmail: fields[2],
                date: fields[3], subject: fields[4]))
        }
        return commits
    }
}
