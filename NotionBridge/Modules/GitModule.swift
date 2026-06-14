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
        await Self.registerWave2(on: router, runtime: runtime)
        await Self.registerWave3(on: router, runtime: runtime)
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

// ============================================================
// MARK: - Wave 2 (PKT-784): inspect tools
// ============================================================
//
// git_show / git_blame / git_apply_patch under module="dev" tier .request.
// Additive on PKT-740 W1 (ad1cd17). Wave 3 (worktree/create_branch/merge)
// deferred to PKT-784 follow-up dispatch per Decision #15.

extension GitModule {

    public static func registerWave2(
        on router: ToolRouter,
        runtime: GitRuntime = GitRuntime.shared
    ) async {
        await router.register(makeShow(runtime: runtime))
        await router.register(makeBlame(runtime: runtime))
        await router.register(makeApplyPatch(runtime: runtime))
    }

    // ------------------------------------------------------------
    // MARK: - git_show
    // ------------------------------------------------------------

    static func makeShow(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_show",
            module: moduleName,
            tier: .request,
            description: "Run `git show <ref>` and return a STRUCTURED envelope: {sha, author, authorEmail, date(ISO 8601), subject, body, files:[{path, status, insertions, deletions, isBinary, origPath?}], diff?}. Use `includeDiff:true` to also return the raw diff body (capped at maxBytes, default 200000). `ref` defaults to HEAD when omitted.",
            inputSchema: schemaObj([
                "cwd":         strProp("Working directory (absolute path)."),
                "ref":         strProp("Commit-ish to show (default: HEAD)."),
                "paths":       arrStrProp("Restrict to these paths (passed after `--`)."),
                "includeDiff": boolProp("Also return the raw diff body (default false)."),
                "maxBytes":    intProp("Truncate raw diff body to this many bytes (default 200000; min 1024; max 2000000).")
            ], required: []),
            handler: { arguments in
                if let capVal = await ensureCapability("git_show", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_show", "expected object arguments")
                }
                let cwd = stringArg(obj, "cwd")
                let ref = stringArg(obj, "ref") ?? "HEAD"
                let includeDiff: Bool = { if case .bool(true) = obj["includeDiff"] { return true }; return false }()
                let byteCap: Int = {
                    if case .int(let n) = obj["maxBytes"] { return Swift.max(1024, Swift.min(n, 2_000_000)) }
                    return 200_000
                }()
                let paths = arrStringArg(obj, "paths")
                let fmt = "--pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1f%b%x00"
                var args: [String] = ["show", fmt, "--raw", "--numstat", ref]
                if !paths.isEmpty {
                    args.append("--")
                    args.append(contentsOf: paths)
                }
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    if r.exitCode != 0 { return failedValue("git_show", r, hint: nil) }
                    guard let parsed = GitRuntime.parseShowOutput(r.stdout) else {
                        return failedValue("git_show", r, hint: "could not parse show output (missing NUL header terminator)")
                    }
                    var dict: [String: Value] = [
                        "ok":          .bool(true),
                        "tool":        .string("git_show"),
                        "exitCode":    .int(Int(r.exitCode)),
                        "sha":         .string(parsed.sha),
                        "author":      .string(parsed.author),
                        "authorEmail": .string(parsed.authorEmail),
                        "date":        .string(parsed.date),
                        "subject":     .string(parsed.subject),
                        "body":        .string(parsed.body),
                        "fileCount":   .int(parsed.files.count),
                        "files":       .array(parsed.files.map { f in
                            var d: [String: Value] = [
                                "path":       .string(f.path),
                                "status":     .string(f.status),
                                "insertions": .int(f.insertions),
                                "deletions":  .int(f.deletions),
                                "isBinary":   .bool(f.isBinary)
                            ]
                            if let o = f.origPath { d["origPath"] = .string(o) }
                            return .object(d)
                        }),
                        "durationMs":  .int(Int(r.durationMs.rounded()))
                    ]
                    if includeDiff {
                        var diffArgs: [String] = ["show", "--format=", ref]
                        if !paths.isEmpty {
                            diffArgs.append("--")
                            diffArgs.append(contentsOf: paths)
                        }
                        let d2 = try await runtime.runGit(diffArgs, cwd: cwd)
                        if d2.exitCode == 0 || d2.exitCode == 1 {
                            let totalBytes = d2.stdout.utf8.count
                            let truncated = totalBytes > byteCap
                            let body = truncated ? String(d2.stdout.prefix(byteCap)) : d2.stdout
                            dict["diff"] = .string(body)
                            dict["diffTruncated"] = .bool(truncated)
                            dict["diffTotalBytes"] = .int(totalBytes)
                        }
                    }
                    return .object(dict)
                } catch let e as GitError {
                    return gitErrorValue("git_show", e)
                } catch {
                    return invalidArgsValue("git_show", error.localizedDescription)
                }
            }
        )
    }

    // ------------------------------------------------------------
    // MARK: - git_blame
    // ------------------------------------------------------------

    static func makeBlame(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_blame",
            module: moduleName,
            tier: .request,
            description: "Run `git blame --porcelain <file>` (optionally `-L <start>,<end>`) and return a STRUCTURED array: [{lineNo, sha, author, authorTime(unix seconds), content}]. `file` is required; `startLine`/`endLine` form an optional inclusive range.",
            inputSchema: schemaObj([
                "cwd":       strProp("Working directory (absolute path)."),
                "file":      strProp("Path to file to blame (relative to cwd or absolute)."),
                "startLine": intProp("Inclusive start line for `-L start,end` range. Omit for full file."),
                "endLine":   intProp("Inclusive end line for `-L start,end` range. Omit for full file."),
                "rev":       strProp("Optional commit-ish to blame from (default: HEAD).")
            ], required: ["file"]),
            handler: { arguments in
                if let capVal = await ensureCapability("git_blame", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_blame", "expected object arguments")
                }
                guard let file = stringArg(obj, "file") else {
                    return invalidArgsValue("git_blame", "'file' is required")
                }
                let cwd = stringArg(obj, "cwd")
                var args: [String] = ["blame", "--porcelain"]
                if case .int(let s) = obj["startLine"] {
                    let e: Int = {
                        if case .int(let ev) = obj["endLine"] { return ev }
                        return s
                    }()
                    args.append("-L")
                    args.append("\(Swift.max(1, s)),\(Swift.max(s, e))")
                }
                if let rev = stringArg(obj, "rev") { args.append(rev) }
                args.append("--")
                args.append(file)
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    if r.exitCode != 0 { return failedValue("git_blame", r, hint: nil) }
                    let entries = GitRuntime.parseBlamePorcelain(r.stdout)
                    return .object([
                        "ok":         .bool(true),
                        "tool":       .string("git_blame"),
                        "exitCode":   .int(Int(r.exitCode)),
                        "file":       .string(file),
                        "lineCount":  .int(entries.count),
                        "lines":      .array(entries.map { e in
                            .object([
                                "lineNo":     .int(e.lineNo),
                                "sha":        .string(e.sha),
                                "author":     .string(e.author),
                                "authorTime": .int(e.authorTime),
                                "content":    .string(e.content)
                            ])
                        }),
                        "durationMs": .int(Int(r.durationMs.rounded()))
                    ])
                } catch let e as GitError {
                    return gitErrorValue("git_blame", e)
                } catch {
                    return invalidArgsValue("git_blame", error.localizedDescription)
                }
            }
        )
    }

    // ------------------------------------------------------------
    // MARK: - git_apply_patch
    // ------------------------------------------------------------

    static func makeApplyPatch(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_apply_patch",
            module: moduleName,
            tier: .request,
            description: "Apply a unified diff via `git apply` (reading patch from stdin). Returns {ok, applied:[paths], rejected?:[paths], commitSha?}. Pass `index:true` to also stage hunks (--index). Pass `check:true` for dry-run validation. When `commit:true` AND apply succeeds, runs a follow-up `git commit -m <message>` (default 'apply patch via git_apply_patch').",
            inputSchema: schemaObj([
                "cwd":           strProp("Working directory (absolute path)."),
                "diff":          strProp("Unified diff body (required; sent as git apply stdin)."),
                "index":         boolProp("Pass --index so the patch updates both working tree AND index."),
                "check":         boolProp("Pass --check for dry-run validation (no files written)."),
                "p":             intProp("Strip count for diff path prefixes (-p<n>; default 1)."),
                "commit":        boolProp("After successful apply, run `git commit -m <message>`. Requires index:true to stage changes."),
                "commitMessage": strProp("Commit message used when commit:true (default 'apply patch via git_apply_patch').")
            ], required: ["diff"]),
            handler: { arguments in
                if let capVal = await ensureCapability("git_apply_patch", runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("git_apply_patch", "expected object arguments")
                }
                guard let diff = stringArg(obj, "diff") else {
                    return invalidArgsValue("git_apply_patch", "'diff' is required")
                }
                let cwd = stringArg(obj, "cwd")
                let stripN: Int = {
                    if case .int(let n) = obj["p"] { return Swift.max(0, n) }
                    return 1
                }()
                var args: [String] = ["apply", "-p\(stripN)"]
                if case .bool(true) = obj["index"] { args.append("--index") }
                if case .bool(true) = obj["check"] { args.append("--check") }
                args.append("-")
                let appliedPaths = GitRuntime.parseDiffTargets(diff)
                do {
                    let r = try await runtime.runGit(args, cwd: cwd, stdin: diff)
                    if r.exitCode != 0 {
                        var fail = failedValue("git_apply_patch", r, hint: "git apply rejected the patch")
                        if case .object(var dict) = fail {
                            dict["rejected"] = .array(appliedPaths.map { .string($0) })
                            fail = .object(dict)
                        }
                        return fail
                    }
                    var dict: [String: Value] = [
                        "ok":           .bool(true),
                        "tool":         .string("git_apply_patch"),
                        "exitCode":     .int(Int(r.exitCode)),
                        "applied":      .array(appliedPaths.map { .string($0) }),
                        "appliedCount": .int(appliedPaths.count),
                        "durationMs":   .int(Int(r.durationMs.rounded()))
                    ]
                    if case .bool(true) = obj["commit"] {
                        let msg = stringArg(obj, "commitMessage") ?? "apply patch via git_apply_patch"
                        let c = try await runtime.runGit(["commit", "-m", msg], cwd: cwd)
                        if c.exitCode != 0 {
                            dict["commitOk"] = .bool(false)
                            dict["commitError"] = .string(c.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            let hr = try await runtime.runGit(["rev-parse", "HEAD"], cwd: cwd)
                            if hr.exitCode == 0 {
                                dict["commitSha"] = .string(hr.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            dict["commitOk"] = .bool(true)
                        }
                    }
                    return .object(dict)
                } catch let e as GitError {
                    return gitErrorValue("git_apply_patch", e)
                } catch {
                    return invalidArgsValue("git_apply_patch", error.localizedDescription)
                }
            }
        )
    }
}

// ============================================================
// MARK: - PKT-784 Wave 3 (repo-ops): git_create_branch
// ============================================================

extension GitModule {

    public static func registerWave3(
        on router: ToolRouter,
        runtime: GitRuntime,
        bgRuntime: BgProcessRuntime = BgProcessRuntime.shared
    ) async {
        await router.register(makeCreateBranch(runtime: runtime))
    }

    static func makeCreateBranch(runtime: GitRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "git_create_branch",
            module: moduleName,
            tier: .request,
            description: "Create a new branch via `git branch <name> [<fromRef>]`. Pass switch:true to also check it out via `git switch <name>`. Returns {branch, fromRef, switched, switchError?}.",
            inputSchema: schemaObj([
                "branch":  strProp("New branch name (required)."),
                "fromRef": strProp("Optional ref to branch from (defaults to HEAD)."),
                "switch":  boolProp("Also check out the new branch after creation."),
                "force":   boolProp("Pass -f to overwrite an existing branch of the same name."),
                "cwd":     strProp("Optional working directory.")
            ], required: ["branch"]),
            handler: { arguments in
                let tool = "git_create_branch"
                if let capVal = await ensureCapability(tool, runtime: runtime) { return capVal }
                guard case .object(let obj) = arguments,
                      let branch = stringArg(obj, "branch") else {
                    return invalidArgsValue(tool, "required: branch (non-empty string)")
                }
                let cwd = stringArg(obj, "cwd")
                let fromRef = stringArg(obj, "fromRef")
                var args: [String] = ["branch"]
                if case .bool(true) = obj["force"] { args.append("-f") }
                args.append(branch)
                if let r = fromRef, !r.isEmpty { args.append(r) }
                do {
                    let r = try await runtime.runGit(args, cwd: cwd)
                    if r.exitCode != 0 { return failedValue(tool, r, hint: "git branch creation failed") }
                    var switched = false
                    var switchErr: String? = nil
                    if case .bool(true) = obj["switch"] {
                        let sw = try await runtime.runGit(["switch", branch], cwd: cwd)
                        if sw.exitCode == 0 {
                            switched = true
                        } else {
                            switchErr = sw.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    var out: [String: Value] = [
                        "ok":         .bool(true),
                        "tool":       .string(tool),
                        "exitCode":   .int(Int(r.exitCode)),
                        "branch":     .string(branch),
                        "fromRef":    .string(fromRef?.isEmpty == false ? fromRef! : "HEAD"),
                        "switched":   .bool(switched),
                        "durationMs": .int(Int(r.durationMs.rounded()))
                    ]
                    if let s = switchErr { out["switchError"] = .string(s) }
                    return .object(out)
                } catch let e as GitError {
                    return gitErrorValue(tool, e)
                } catch {
                    return invalidArgsValue(tool, error.localizedDescription)
                }
            }
        )
    }

}
