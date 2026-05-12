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

// ============================================================
// MARK: - Wave 2 types (PKT-784 W2 v2.2 · 2.1.1)
// ============================================================
//
// git_show + git_blame + git_apply_patch structured envelopes.
// Wave 3 repo-ops (git_worktree / git_create_branch / git_merge)
// deferred to PKT-784 follow-up dispatch per Decision #15.

public struct GitShowFileChange: Sendable, Equatable {
    public let path: String
    public let status: String         // single-char: A, M, D, R, C, T, U, X, B, or "?"
    public let insertions: Int
    public let deletions: Int
    public let isBinary: Bool
    public let origPath: String?      // for R*/C* renames/copies

    public init(path: String, status: String, insertions: Int, deletions: Int, isBinary: Bool, origPath: String?) {
        self.path = path
        self.status = status
        self.insertions = insertions
        self.deletions = deletions
        self.isBinary = isBinary
        self.origPath = origPath
    }
}

public struct GitShowResult: Sendable {
    public let sha: String
    public let author: String
    public let authorEmail: String
    public let date: String           // ISO 8601
    public let subject: String
    public let body: String
    public let files: [GitShowFileChange]
}

public struct GitBlameLine: Sendable, Equatable {
    public let lineNo: Int
    public let sha: String
    public let author: String
    public let authorTime: Int        // unix timestamp seconds
    public let content: String

    public init(lineNo: Int, sha: String, author: String, authorTime: Int, content: String) {
        self.lineNo = lineNo
        self.sha = sha
        self.author = author
        self.authorTime = authorTime
        self.content = content
    }
}

public struct GitApplyOutcome: Sendable {
    public let ok: Bool
    public let applied: [String]
    public let rejected: [String]
    public let commitSha: String?
    public let stderr: String
}

// ============================================================
// MARK: - Wave 2 parsers (PKT-784 W2)
// ============================================================

extension GitRuntime {

    /// Parse `git show --pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1f%b%x00 --raw --numstat <ref>` output.
    /// Returns nil when the NUL header terminator is missing (malformed input).
    nonisolated public static func parseShowOutput(_ text: String) -> GitShowResult? {
        guard let nulIdx = text.firstIndex(of: "\u{0}") else { return nil }
        let header = String(text[..<nulIdx])
        let rest = String(text[text.index(after: nulIdx)...])
        let fields = header.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return nil }
        let sha     = fields[0]
        let author  = fields[1]
        let email   = fields[2]
        let date    = fields[3]
        let subject = fields[4]
        let body    = fields[5]

        var statuses: [String: (status: String, origPath: String?)] = [:]
        var counts:   [String: (ins: Int, dels: Int, binary: Bool)] = [:]
        var ordered: [String] = []

        for raw in rest.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix(":") {
                // :<mode> <mode> <hash> <hash> <STATUS>\t<path>[\t<origPath>]
                guard let tabIdx = line.firstIndex(of: "\t") else { continue }
                let head = String(line[..<tabIdx])
                let tail = String(line[line.index(after: tabIdx)...])
                let parts = head.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                guard let statusBlob = parts.last else { continue }
                let firstChar = statusBlob.first.map(String.init) ?? "?"
                let pathPieces = tail.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let path: String
                let orig: String?
                if pathPieces.count == 2 {
                    orig = pathPieces[0]
                    path = pathPieces[1]
                } else {
                    orig = nil
                    path = pathPieces[0]
                }
                statuses[path] = (firstChar, orig)
                if !ordered.contains(path) { ordered.append(path) }
            } else if !line.isEmpty {
                // numstat: <ins>\t<dels>\t<path>  (binary uses "-" for both counts)
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                let path = parts[2]
                let binary = (parts[0] == "-" && parts[1] == "-")
                let ins = binary ? 0 : (Int(parts[0]) ?? 0)
                let dels = binary ? 0 : (Int(parts[1]) ?? 0)
                counts[path] = (ins, dels, binary)
                if !ordered.contains(path) { ordered.append(path) }
            }
        }

        var files: [GitShowFileChange] = []
        for p in ordered {
            let s = statuses[p]
            let c = counts[p]
            files.append(GitShowFileChange(
                path: p,
                status: s?.status ?? "?",
                insertions: c?.ins ?? 0,
                deletions: c?.dels ?? 0,
                isBinary: c?.binary ?? false,
                origPath: s?.origPath))
        }

        return GitShowResult(
            sha: sha, author: author, authorEmail: email,
            date: date, subject: subject, body: body, files: files)
    }

    /// Parse `git blame --porcelain` output into per-line entries.
    /// Porcelain layout: a header line `<sha> <origLine> <finalLine> [<groupCount>]` followed by
    /// metadata lines (`author`, `author-time`, etc.) and a content line prefixed with `\t`.
    /// Lines after the first in a group repeat only `<sha> <origLine> <finalLine>` + `\t<content>`.
    nonisolated public static func parseBlamePorcelain(_ text: String) -> [GitBlameLine] {
        var out: [GitBlameLine] = []
        var authors: [String: String] = [:]
        var authorTimes: [String: Int] = [:]
        var currentSha: String = ""
        var currentFinalLine: Int = 0

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("\t") {
                let content = String(line.dropFirst(1))
                out.append(GitBlameLine(
                    lineNo: currentFinalLine,
                    sha: currentSha,
                    author: authors[currentSha] ?? "",
                    authorTime: authorTimes[currentSha] ?? 0,
                    content: content))
            } else if line.hasPrefix("author ") {
                authors[currentSha] = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                authorTimes[currentSha] = Int(line.dropFirst("author-time ".count)) ?? 0
            } else {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if parts.count >= 3 {
                    let candidate = parts[0]
                    if candidate.count >= 7,
                       candidate.allSatisfy({ $0.isHexDigit }),
                       let finalLine = Int(parts[2]) {
                        currentSha = candidate
                        currentFinalLine = finalLine
                    }
                }
            }
        }
        return out
    }

    /// Extract `+++ b/<path>` headers from a unified diff so callers can surface
    /// applied/rejected paths in the `git_apply_patch` envelope.
    nonisolated public static func parseDiffTargets(_ diff: String) -> [String] {
        var paths: [String] = []
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++ b/") {
                let p = String(line.dropFirst("+++ b/".count))
                if !paths.contains(p) { paths.append(p) }
            } else if line.hasPrefix("+++ ") && !line.hasPrefix("+++ /dev/null") {
                let p = String(line.dropFirst(4))
                if !paths.contains(p) { paths.append(p) }
            }
        }
        return paths
    }
}

// ============================================================
// MARK: - PKT-784 Wave 3 (repo-ops) types + parsers
// ============================================================
// Appended for git_worktree / git_create_branch / git_merge.

public struct GitWorktreeEntry: Sendable, Equatable {
    public let path: String
    public let head: String?       // sha at HEAD, nil for bare
    public let branch: String?     // ref like refs/heads/main, nil if detached/bare
    public let bare: Bool
    public let detached: Bool
    public let locked: Bool
    public let lockReason: String?
    public let prunable: Bool
    public let prunableReason: String?

    public init(path: String, head: String? = nil, branch: String? = nil,
                bare: Bool = false, detached: Bool = false,
                locked: Bool = false, lockReason: String? = nil,
                prunable: Bool = false, prunableReason: String? = nil) {
        self.path = path; self.head = head; self.branch = branch
        self.bare = bare; self.detached = detached
        self.locked = locked; self.lockReason = lockReason
        self.prunable = prunable; self.prunableReason = prunableReason
    }
}

public struct GitMergeHunk: Sendable, Equatable {
    public let startLine: Int       // 1-based, line of `<<<<<<<`
    public let endLine: Int         // 1-based, line of `>>>>>>>`
    public let ours: [String]
    public let theirs: [String]

    public init(startLine: Int, endLine: Int, ours: [String], theirs: [String]) {
        self.startLine = startLine; self.endLine = endLine
        self.ours = ours; self.theirs = theirs
    }
}

public struct GitMergeConflictFile: Sendable, Equatable {
    public let file: String
    public let hunks: [GitMergeHunk]

    public init(file: String, hunks: [GitMergeHunk]) {
        self.file = file; self.hunks = hunks
    }
}

extension GitRuntime {

    /// Parse `git worktree list --porcelain` into structured entries.
    /// Entries are separated by blank lines; each entry has lines like:
    ///   worktree <abs path>
    ///   HEAD <sha>
    ///   branch refs/heads/<name>     OR     detached
    ///   bare                                (alternative branch line)
    ///   locked [<reason>]
    ///   prunable [<reason>]
    public nonisolated static func parseWorktreeList(_ porcelain: String) -> [GitWorktreeEntry] {
        var out: [GitWorktreeEntry] = []
        var path: String? = nil
        var head: String? = nil
        var branch: String? = nil
        var bare = false
        var detached = false
        var locked = false
        var lockReason: String? = nil
        var prunable = false
        var prunableReason: String? = nil

        func flush() {
            guard let p = path else { return }
            out.append(GitWorktreeEntry(
                path: p, head: head, branch: branch,
                bare: bare, detached: detached,
                locked: locked, lockReason: lockReason,
                prunable: prunable, prunableReason: prunableReason
            ))
            path = nil; head = nil; branch = nil
            bare = false; detached = false
            locked = false; lockReason = nil
            prunable = false; prunableReason = nil
        }

        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                flush()
                continue
            }
            if let spaceIdx = line.firstIndex(of: " ") {
                let key = String(line[..<spaceIdx])
                let rest = String(line[line.index(after: spaceIdx)...])
                switch key {
                case "worktree": path = rest
                case "HEAD":     head = rest
                case "branch":   branch = rest
                case "locked":   locked = true; lockReason = rest
                case "prunable": prunable = true; prunableReason = rest
                default: break
                }
            } else {
                switch line {
                case "bare":     bare = true
                case "detached": detached = true
                case "locked":   locked = true
                case "prunable": prunable = true
                default: break
                }
            }
        }
        flush()
        return out
    }

    /// Parse 2-way merge conflict markers in a file's content into structured hunks.
    /// Recognizes:
    ///   <<<<<<< <label>
    ///   <ours lines>
    ///   =======
    ///   <theirs lines>
    ///   >>>>>>> <label>
    ///
    /// Notes:
    ///   - Ignores `|||||||` (diff3-style base markers).
    ///   - Line numbers are 1-based.
    ///   - Malformed marker groups are skipped.
    public nonisolated static func parseConflictMarkers(in content: String) -> [GitMergeHunk] {
        var out: [GitMergeHunk] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("<<<<<<<") {
                let startLine = i + 1
                var ours: [String] = []
                var theirs: [String] = []
                var sawSep = false
                var sawBase = false
                var j = i + 1
                var endLine: Int? = nil
                while j < lines.count {
                    let l = lines[j]
                    if l.hasPrefix(">>>>>>>") {
                        endLine = j + 1
                        break
                    } else if l.hasPrefix("=======") && !sawSep {
                        sawSep = true
                    } else if l.hasPrefix("|||||||") {
                        // diff3 base marker — entering base section
                        sawBase = true
                    } else if sawBase && !sawSep {
                        // diff3 base content — skip until ======= separator
                    } else {
                        if sawSep { theirs.append(l) } else { ours.append(l) }
                    }
                    j += 1
                }
                if let e = endLine, sawSep {
                    out.append(GitMergeHunk(
                        startLine: startLine, endLine: e,
                        ours: ours, theirs: theirs
                    ))
                    i = j + 1
                    continue
                } else {
                    i += 1
                    continue
                }
            }
            i += 1
        }
        return out
    }
}
