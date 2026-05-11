// GitModule.swift — PKT-740 W1 (Bridge v2.2 · 2.1): git_* CLI wrapper tools
// NotionBridge · Modules · dev/
//
// Read-only triumvirate (Wave 1 — PM Type A fallback path per Re-Route #21):
//   - git_status (porcelain v2 → structured GitStatusSummary)
//   - git_diff   (range/paths/stat → raw diff or structured stat)
//   - git_log    (range/paths/maxCount → structured commits)
//
// Waves 2–3 (git_show / git_blame / git_apply_patch + git_worktree /
// git_create_branch / git_merge) deferred to PKT-740.1 follow-up per
// honest-partial Decision #15 — bandwidth call documented in packet output.
//
// All tools are tier `.request` per packet spec. Each handler:
//   1. Calls capabilityCheck() and short-circuits with capability_missing.
//   2. Builds git args from typed input schema.
//   3. Invokes runtime.runGit(args, cwd:) synchronously (fast read ops).
//   4. Returns a structured Value envelope: ok, tool, status, ...

import Foundation
import MCP

public enum GitModule {
    public static let moduleName = "dev"

    public static func register(
        on router: ToolRouter,
        runtime: GitRuntime = GitRuntime.shared
    ) async {
        await router.register(makeStatus(runtime: runtime))
        await router.register(makeDiff(runtime: runtime))
        await router.register(makeLog(runtime: runtime))
    }

    // ============================================================
    // MARK: - Tool factories
    // ============================================================

    static func makeStatus(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_status",
            module: moduleName,
            tier: .request,
            description: "Run `git status --porcelain=v2 --branch` and return a STRUCTURED summary instead of raw stdout: branch, upstream, OID, ahead/behind counts, and per-file entries with indexStatus/worktreeStatus/kind (tracked|untracked|ignored|unmerged). Use `cwd` to target a specific worktree (defaults to Bridge process cwd).",
            inputSchema: schemaObj([
                "cwd": strProp("Working directory (absolute path). Defaults to Bridge process cwd."),
                "includeIgnored": boolProp("Include ignored files (passes --ignored)."),
                "untrackedMode": enumProp(["no", "normal", "all"], "Untracked-files reporting mode (default 'normal').")
            ], required: []),
            handler: { arguments in
                if let capVal = await ensureCapability("git_status", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_status", "expected object arguments")
                }
                let cwd = stringArg(obj, "cwd")
                let mode: String = stringArg(obj, "untrackedMode") ?? "normal"
                var args: [String] = ["status", "--porcelain=v2", "--branch", "--untracked-files=\(mode)"]
                if case .bool(true) = obj["includeIgnored"] {
                    args.append("--ignored")
                }
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    if r.exitCode != 0 { return failedValue("git_status", r, hint: nil) }
                    let summary = GitRuntime.parsePorcelainV2(r.stdout)
                    return statusValueFromSummary(summary, raw: r)
                } catch let e as GitError {
                    return gitErrorValue("git_status", e)
                } catch {
                    return invalidArgsValue("git_status", error.localizedDescription)
                }
            }
        )
    }

    static func makeDiff(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_diff",
            module: moduleName,
            tier: .request,
            description: "Run `git diff [<range>] [-- <paths>]` and return structured output. `range` can be a single ref, A..B, A...B, or omitted (worktree vs index). `stat: true` returns parsed --stat per-file +/- counts instead of raw diff. `cached: true` diffs index vs HEAD. Raw diff body is capped at `maxBytes` (default 200000).",
            inputSchema: schemaObj([
                "cwd":      strProp("Working directory (absolute path)."),
                "range":    strProp("Git ref or range (e.g. 'HEAD~1', 'main..HEAD', 'a...b'). Omit for worktree-vs-index."),
                "paths":    arrStrProp("Restrict to these paths (passed after `--`)."),
                "stat":     boolProp("Return --stat summary (parsed per-file insertions/deletions) instead of raw diff."),
                "cached":   boolProp("Diff the index against HEAD (passes --cached)."),
                "maxBytes": intProp("Truncate raw diff body to this many bytes (default 200000; min 1024; max 2000000).")
            ], required: []),
            handler: { arguments in
                if let capVal = await ensureCapability("git_diff", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_diff", "expected object arguments")
                }
                let cwd = stringArg(obj, "cwd")
                var args: [String] = ["diff"]
                let stat: Bool = { if case .bool(true) = obj["stat"] { return true }; return false }()
                if stat { args.append("--stat") }
                if case .bool(true) = obj["cached"] { args.append("--cached") }
                if let range = stringArg(obj, "range") { args.append(range) }
                let paths: [String] = arrStringArg(obj, "paths")
                if !paths.isEmpty {
                    args.append("--")
                    args.append(contentsOf: paths)
                }
                let byteCap: Int = {
                    if case .int(let n) = obj["maxBytes"] { return max(1024, min(n, 2_000_000)) }
                    return 200_000
                }()
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    // git diff: exit 0 = no diff, 1 = diff present (NOT failure), >1 = real error.
                    if r.exitCode != 0 && r.exitCode != 1 {
                        return failedValue("git_diff", r, hint: "git diff exit code > 1 indicates an error")
                    }
                    var dict: [String: Value] = [
                        "ok":         .bool(true),
                        "tool":       .string("git_diff"),
                        "exitCode":   .int(Int(r.exitCode)),
                        "hasDiff":    .bool(r.exitCode == 1 || !r.stdout.isEmpty),
                        "durationMs": .int(Int(r.durationMs.rounded()))
                    ]
                    if stat {
                        dict["statRaw"] = .string(r.stdout)
                        dict["files"]   = .array(parseDiffStat(r.stdout).map { f in
                            .object([
                                "path":       .string(f.path),
                                "insertions": .int(f.insertions),
                                "deletions":  .int(f.deletions)
                            ])
                        })
                    } else {
                        let totalBytes = r.stdout.utf8.count
                        let truncated = totalBytes > byteCap
                        let body = truncated ? String(r.stdout.prefix(byteCap)) : r.stdout
                        dict["diff"]       = .string(body)
                        dict["truncated"]  = .bool(truncated)
                        dict["totalBytes"] = .int(totalBytes)
                    }
                    if !r.stderr.isEmpty { dict["stderr"] = .string(r.stderr) }
                    return .object(dict)
                } catch let e as GitError {
                    return gitErrorValue("git_diff", e)
                } catch {
                    return invalidArgsValue("git_diff", error.localizedDescription)
                }
            }
        )
    }

    static func makeLog(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_log",
            module: moduleName,
            tier: .request,
            description: "Run `git log` and return a STRUCTURED array of commits {sha, author, authorEmail, date(ISO 8601), subject}. Supports range, path filter, maxCount (default 20, max 1000).",
            inputSchema: schemaObj([
                "cwd":      strProp("Working directory (absolute path)."),
                "range":    strProp("Git ref or range (e.g. 'HEAD~10..HEAD', 'main', 'a..b'). Omit for HEAD."),
                "paths":    arrStrProp("Restrict log to these paths (passed after `--`)."),
                "maxCount": intProp("Maximum commits to return (default 20, max 1000).")
            ], required: []),
            handler: { arguments in
                if let capVal = await ensureCapability("git_log", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_log", "expected object arguments")
                }
                let cwd = stringArg(obj, "cwd")
                let maxN: Int = {
                    if case .int(let n) = obj["maxCount"] { return Swift.max(1, Swift.min(n, 1000)) }
                    return 20
                }()
                // RS = 0x1E (record separator), US = 0x1F (field separator)
                let fmt = "--pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"
                var args: [String] = ["log", fmt, "--max-count=\(maxN)"]
                if let range = stringArg(obj, "range") { args.append(range) }
                let paths = arrStringArg(obj, "paths")
                if !paths.isEmpty {
                    args.append("--")
                    args.append(contentsOf: paths)
                }
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    if r.exitCode != 0 { return failedValue("git_log", r, hint: nil) }
                    let commits = GitRuntime.parseLog(r.stdout)
                    let arr: [Value] = commits.map { c in
                        .object([
                            "sha":         .string(c.sha),
                            "author":      .string(c.author),
                            "authorEmail": .string(c.authorEmail),
                            "date":        .string(c.date),
                            "subject":     .string(c.subject)
                        ])
                    }
                    return .object([
                        "ok":         .bool(true),
                        "tool":       .string("git_log"),
                        "exitCode":   .int(Int(r.exitCode)),
                        "count":      .int(commits.count),
                        "commits":    .array(arr),
                        "durationMs": .int(Int(r.durationMs.rounded()))
                    ])
                } catch let e as GitError {
                    return gitErrorValue("git_log", e)
                } catch {
                    return invalidArgsValue("git_log", error.localizedDescription)
                }
            }
        )
    }

    // ============================================================
    // MARK: - Status Value builder
    // ============================================================

    static func statusValueFromSummary(_ s: GitStatusSummary, raw: GitInvocationResult) -> Value {
        let fileVals: [Value] = s.files.map { f in
            var d: [String: Value] = [
                "path":           .string(f.path),
                "indexStatus":    .string(f.indexStatus),
                "worktreeStatus": .string(f.worktreeStatus),
                "kind":           .string(f.kind)
            ]
            if let o = f.origPath { d["origPath"] = .string(o) }
            return .object(d)
        }
        var dict: [String: Value] = [
            "ok":         .bool(true),
            "tool":       .string("git_status"),
            "exitCode":   .int(Int(raw.exitCode)),
            "clean":      .bool(s.clean),
            "ahead":      .int(s.ahead),
            "behind":     .int(s.behind),
            "files":      .array(fileVals),
            "fileCount":  .int(s.files.count),
            "durationMs": .int(Int(raw.durationMs.rounded()))
        ]
        if let b = s.branch   { dict["branch"]   = .string(b) }
        if let u = s.upstream { dict["upstream"] = .string(u) }
        if let o = s.oid      { dict["oid"]      = .string(o) }
        return .object(dict)
    }

    // ============================================================
    // MARK: - diff --stat parsing
    // ============================================================

    public struct DiffStatFile: Sendable, Equatable {
        public let path: String
        public let insertions: Int
        public let deletions: Int
    }

    /// Parse `git diff --stat` output into per-file insertion/deletion counts.
    /// Lines look like:  " path/to/file.swift | 12 +++++++-----"
    /// Final summary line " 3 files changed, 12 insertions(+), 5 deletions(-)" is skipped.
    public static func parseDiffStat(_ text: String) -> [DiffStatFile] {
        var out: [DiffStatFile] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let isSummary = (line.contains(" file") || line.contains(" files "))
                && (line.contains("changed") || line.contains("insertion") || line.contains("deletion"))
            if isSummary { continue }
            guard let barIdx = line.firstIndex(of: "|") else { continue }
            let pathPart = String(line[..<barIdx]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: barIdx)...]).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Bin") {
                out.append(DiffStatFile(path: pathPart, insertions: 0, deletions: 0))
                continue
            }
            var inserts = 0, deletes = 0
            for c in rest {
                if c == "+" { inserts += 1 }
                else if c == "-" { deletes += 1 }
            }
            out.append(DiffStatFile(path: pathPart, insertions: inserts, deletions: deletes))
        }
        return out
    }

    // ============================================================
    // MARK: - Shared helpers
    // ============================================================

    static func ensureCapability(_ tool: String, runtime: GitRuntime) async -> Value? {
        let cap = await runtime.capabilityCheck()
        if cap.ok { return nil }
        return capabilityMissingValue(tool, cap.reason ?? "git capability missing", path: cap.path)
    }

    // MARK: - Envelope builders

    public static func capabilityMissingValue(_ tool: String, _ reason: String, path: String?) -> Value {
        var dict: [String: Value] = [
            "ok":     .bool(false),
            "status": .string("capability_missing"),
            "tool":   .string(tool),
            "error":  .string(reason)
        ]
        if let p = path { dict["path"] = .string(p) }
        return .object(dict)
    }

    public static func invalidArgsValue(_ tool: String, _ reason: String) -> Value {
        .object([
            "ok":     .bool(false),
            "status": .string("invalid_argument"),
            "tool":   .string(tool),
            "error":  .string(reason)
        ])
    }

    public static func failedValue(_ tool: String, _ r: GitInvocationResult, hint: String?) -> Value {
        let trimmedErr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let errMsg = trimmedErr.isEmpty ? "git exited \(r.exitCode)" : trimmedErr
        var dict: [String: Value] = [
            "ok":       .bool(false),
            "status":   .string("failed"),
            "tool":     .string(tool),
            "exitCode": .int(Int(r.exitCode)),
            "stdout":   .string(r.stdout),
            "stderr":   .string(r.stderr),
            "error":    .string(errMsg)
        ]
        if let h = hint { dict["hint"] = .string(h) }
        return .object(dict)
    }

    public static func gitErrorValue(_ tool: String, _ e: GitError) -> Value {
        switch e {
        case .capabilityMissing(let r): return capabilityMissingValue(tool, r, path: nil)
        case .invalidArgument(let r):   return invalidArgsValue(tool, r)
        case .spawnFailed(let r):
            return .object([
                "ok":     .bool(false),
                "status": .string("failed"),
                "tool":   .string(tool),
                "error":  .string("spawn failed: \(r)")
            ])
        case .gitFailed(let code, let err):
            return .object([
                "ok":       .bool(false),
                "status":   .string("failed"),
                "tool":     .string(tool),
                "exitCode": .int(Int(code)),
                "error":    .string(err)
            ])
        }
    }

    // MARK: - Schema helpers

    static func strProp(_ desc: String) -> Value {
        .object(["type": .string("string"), "description": .string(desc)])
    }
    static func intProp(_ desc: String) -> Value {
        .object(["type": .string("integer"), "description": .string(desc)])
    }
    static func boolProp(_ desc: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(desc)])
    }
    static func arrStrProp(_ desc: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(desc)
        ])
    }
    static func enumProp(_ values: [String], _ desc: String) -> Value {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(desc)
        ])
    }
    static func schemaObj(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type":       .string("object"),
            "properties": .object(properties),
            "required":   .array(required.map { .string($0) })
        ])
    }

    // MARK: - Arg readers

    static func stringArg(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s) = obj[key], !s.isEmpty { return s }
        return nil
    }
    static func arrStringArg(_ obj: [String: Value], _ key: String) -> [String] {
        guard case .array(let arr) = obj[key] else { return [] }
        return arr.compactMap { v in
            if case .string(let s) = v, !s.isEmpty { return s }
            return nil
        }
    }
}
