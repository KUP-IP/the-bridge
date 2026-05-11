// GhModule.swift — PKT-742 (Bridge v2.2 · 2.2): gh_* CLI wrapper tools
// NotionBridge · Modules · dev/
//
// Nine thin wrappers around the `gh` CLI:
//   - gh_pr_open / gh_pr_status / gh_pr_comment / gh_pr_merge
//   - gh_actions_runs / gh_check_status
//   - gh_issue_open / gh_issue_comment / gh_issue_close
//
// All tools are tier `.request` (every wrapper can mutate github.com state
// or read repo data on the user's behalf). Each handler:
//   1. Calls runtime.capabilityCheck() and short-circuits with
//      `{ ok:false, status:"capability_missing" }` if gh isn't auth'd.
//   2. Builds gh args from the typed input schema.
//   3. Either runs synchronously (default) and returns parsed JSON / URL,
//      or, when `background: true`, delegates to BgProcessRuntime.start and
//      returns a job id (caller polls via bg_process_status / bg_process_logs).
//   4. Returns a structured Value envelope: ok, tool, status, ...

import Foundation
import MCP

public enum GhModule {
    public static let moduleName = "dev"

    public static func register(
        on router: ToolRouter,
        runtime: GhRuntime = GhRuntime.shared,
        bgRuntime: BgProcessRuntime = BgProcessRuntime.shared
    ) async {
        await router.register(makePrOpen(runtime: runtime, bgRuntime: bgRuntime))
        await router.register(makePrStatus(runtime: runtime))
        await router.register(makePrComment(runtime: runtime))
        await router.register(makePrMerge(runtime: runtime, bgRuntime: bgRuntime))
        await router.register(makeActionsRuns(runtime: runtime))
        await router.register(makeCheckStatus(runtime: runtime))
        await router.register(makeIssueOpen(runtime: runtime))
        await router.register(makeIssueComment(runtime: runtime))
        await router.register(makeIssueClose(runtime: runtime))
    }

    // ===========================================================
    // MARK: - Tool factories
    // ===========================================================

    static func makePrOpen(runtime: GhRuntime, bgRuntime: BgProcessRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_pr_open",
            module: moduleName,
            tier: .request,
            description: "Open a GitHub pull request via `gh pr create`. Requires title (or fill: true). Returns the new PR URL on success. Long runs (e.g., `--fill` against many commits) can be sent to bg_process by passing background: true — the tool returns a bg_process job id immediately.",
            inputSchema: schemaObj([
                "title":     strProp("PR title (required unless fill: true)."),
                "body":      strProp("PR body (markdown)."),
                "base":      strProp("Base branch (default: repo default)."),
                "head":      strProp("Head branch (default: current branch)."),
                "repo":      strProp("Optional OWNER/REPO override."),
                "draft":     boolProp("Open as draft."),
                "fill":      boolProp("Fill title/body from commit messages."),
                "labels":    arrStrProp("Labels to apply."),
                "assignees": arrStrProp("Assignees by login."),
                "reviewers": arrStrProp("Reviewers (users or 'org/team')."),
                "background": boolProp("Run via bg_process_start and return jobId immediately.")
            ], required: []),
            handler: { arguments in
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("gh_pr_open", "expected object arguments")
                }
                if let cap = await ensureCapability("gh_pr_open", runtime: runtime) { return cap }

                var args: [String] = ["pr", "create"]
                appendStr(&args, obj, "title", "--title")
                appendStr(&args, obj, "body", "--body")
                appendStr(&args, obj, "base", "--base")
                appendStr(&args, obj, "head", "--head")
                appendStr(&args, obj, "repo", "--repo")
                if case .bool(true) = obj["draft"] { args.append("--draft") }
                if case .bool(true) = obj["fill"]  { args.append("--fill") }
                appendArr(&args, obj, "labels", "--label")
                appendArr(&args, obj, "assignees", "--assignee")
                appendArr(&args, obj, "reviewers", "--reviewer")

                if !args.contains("--fill") && !args.contains("--title") {
                    return invalidArgsValue("gh_pr_open", "title is required (or pass fill: true)")
                }

                if case .bool(true) = obj["background"] {
                    return await runInBackground("gh_pr_open", ghArgs: args,
                        runtime: runtime, bgRuntime: bgRuntime, label: "gh_pr_open")
                }
                return await runSync("gh_pr_open", ghArgs: args, runtime: runtime,
                                     parseURL: true, parseJSON: false)
            }
        )
    }

    static func makePrStatus(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_pr_status",
            module: moduleName,
            tier: .request,
            description: "Get the status of a pull request via `gh pr view --json ...`. Returns parsed JSON: number, title, state, isDraft, mergeable, mergeStateStatus, statusCheckRollup, headRefName, baseRefName, author, createdAt, updatedAt, url. If `number` is omitted, gh reads the PR for the current branch.",
            inputSchema: schemaObj([
                "number": intProp("PR number. Omit to use current branch's PR."),
                "repo":   strProp("Optional OWNER/REPO override.")
            ], required: []),
            handler: { arguments in
                if let cap = await ensureCapability("gh_pr_status", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("gh_pr_status", "expected object arguments")
                }
                let fields = "number,title,state,isDraft,mergeable,mergeStateStatus,statusCheckRollup,headRefName,baseRefName,author,createdAt,updatedAt,url,additions,deletions,changedFiles"
                var args: [String] = ["pr", "view"]
                if case .int(let n) = obj["number"] { args.append(String(n)) }
                appendStr(&args, obj, "repo", "--repo")
                args.append(contentsOf: ["--json", fields])
                return await runSync("gh_pr_status", ghArgs: args, runtime: runtime,
                                     parseURL: false, parseJSON: true)
            }
        )
    }

    static func makePrComment(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_pr_comment",
            module: moduleName,
            tier: .request,
            description: "Add a top-level comment to a pull request via `gh pr comment <number> --body ...`. Returns the comment URL.",
            inputSchema: schemaObj([
                "number": intProp("PR number (required)."),
                "body":   strProp("Comment body markdown (required)."),
                "repo":   strProp("Optional OWNER/REPO override.")
            ], required: ["number", "body"]),
            handler: { arguments in
                if let cap = await ensureCapability("gh_pr_comment", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments,
                      case .int(let number) = obj["number"],
                      case .string(let body) = obj["body"], !body.isEmpty else {
                    return invalidArgsValue("gh_pr_comment", "required: number (int), body (non-empty string)")
                }
                var args: [String] = ["pr", "comment", String(number), "--body", body]
                appendStr(&args, obj, "repo", "--repo")
                return await runSync("gh_pr_comment", ghArgs: args, runtime: runtime,
                                     parseURL: true, parseJSON: false)
            }
        )
    }

    static func makePrMerge(runtime: GhRuntime, bgRuntime: BgProcessRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_pr_merge",
            module: moduleName,
            tier: .request,
            description: "Merge a pull request via `gh pr merge`. method: 'merge'|'squash'|'rebase' (default 'merge'). auto: enable auto-merge after checks pass. deleteBranch: delete the head branch after merge. background: true — spawn via bg_process and return jobId (recommended for `auto: true` since it can wait minutes for required checks).",
            inputSchema: schemaObj([
                "number":       intProp("PR number (required)."),
                "repo":         strProp("Optional OWNER/REPO override."),
                "method":       enumProp(["merge", "squash", "rebase"], "Merge method (default 'merge')."),
                "auto":         boolProp("Enable auto-merge after required checks pass."),
                "deleteBranch": boolProp("Delete the head branch after merging."),
                "subject":      strProp("Optional commit subject (squash/merge only)."),
                "bodyText":     strProp("Optional commit body text."),
                "background":   boolProp("Run via bg_process_start and return jobId immediately.")
            ], required: ["number"]),
            handler: { arguments in
                if let cap = await ensureCapability("gh_pr_merge", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments,
                      case .int(let number) = obj["number"] else {
                    return invalidArgsValue("gh_pr_merge", "required: number (int)")
                }
                var args: [String] = ["pr", "merge", String(number)]
                appendStr(&args, obj, "repo", "--repo")
                let method: String = {
                    if case .string(let m) = obj["method"] { return m }
                    return "merge"
                }()
                switch method {
                case "squash": args.append("--squash")
                case "rebase": args.append("--rebase")
                default:       args.append("--merge")
                }
                if case .bool(true) = obj["auto"]         { args.append("--auto") }
                if case .bool(true) = obj["deleteBranch"] { args.append("--delete-branch") }
                appendStr(&args, obj, "subject", "--subject")
                appendStr(&args, obj, "bodyText", "--body")

                if case .bool(true) = obj["background"] {
                    return await runInBackground("gh_pr_merge", ghArgs: args,
                        runtime: runtime, bgRuntime: bgRuntime, label: "gh_pr_merge")
                }
                return await runSync("gh_pr_merge", ghArgs: args, runtime: runtime,
                                     parseURL: false, parseJSON: false)
            }
        )
    }

    static func makeActionsRuns(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_actions_runs",
            module: moduleName,
            tier: .request,
            description: "List recent GitHub Actions runs via `gh run list --json ...`. Filter by branch, status ('queued'|'in_progress'|'completed'|'success'|'failure'|...), workflow (name or filename). Default limit 20.",
            inputSchema: schemaObj([
                "repo":     strProp("Optional OWNER/REPO override."),
                "branch":   strProp("Filter by branch name."),
                "status":   strProp("Filter by run status."),
                "workflow": strProp("Filter by workflow name or filename (e.g. 'CI' or 'ci.yml')."),
                "limit":    intProp("Max runs to return (default 20)."),
                "event":    strProp("Filter by event (push, pull_request, workflow_dispatch, ...).")
            ], required: []),
            handler: { arguments in
                if let cap = await ensureCapability("gh_actions_runs", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("gh_actions_runs", "expected object arguments")
                }
                let fields = "databaseId,name,displayTitle,status,conclusion,workflowName,headBranch,event,createdAt,updatedAt,url,headSha,number"
                var args: [String] = ["run", "list"]
                appendStr(&args, obj, "repo", "--repo")
                appendStr(&args, obj, "branch", "--branch")
                appendStr(&args, obj, "status", "--status")
                appendStr(&args, obj, "workflow", "--workflow")
                appendStr(&args, obj, "event", "--event")
                let limit: Int = {
                    if case .int(let n) = obj["limit"] { return max(1, min(n, 200)) }
                    return 20
                }()
                args.append(contentsOf: ["--limit", String(limit), "--json", fields])
                let result = await runSync("gh_actions_runs", ghArgs: args, runtime: runtime,
                                           parseURL: false, parseJSON: true)
                // Wrap parsed array with `count` for caller convenience.
                if case .object(var dict) = result, case .array(let arr) = dict["json"] {
                    dict["count"] = .int(arr.count)
                    dict["runs"]  = .array(arr)
                    return .object(dict)
                }
                return result
            }
        )
    }

    static func makeCheckStatus(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_check_status",
            module: moduleName,
            tier: .request,
            description: "Summarize check-run status against a git ref via `gh api repos/{owner}/{repo}/commits/{ref}/check-runs`. ref defaults to 'HEAD'. Returns counts (total, passing, failing, pending, neutral) plus per-check name/status/conclusion/url.",
            inputSchema: schemaObj([
                "ref":  strProp("Git ref (branch, tag, or SHA). Default 'HEAD'."),
                "repo": strProp("Optional OWNER/REPO override (default: current repo).")
            ], required: []),
            handler: { arguments in
                if let cap = await ensureCapability("gh_check_status", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments else {
                    return invalidArgsValue("gh_check_status", "expected object arguments")
                }
                let ref: String = {
                    if case .string(let s) = obj["ref"], !s.isEmpty { return s }
                    return "HEAD"
                }()
                // Resolve repo slug if not provided.
                var slug: String? = nil
                if case .string(let s) = obj["repo"], !s.isEmpty { slug = s }
                if slug == nil {
                    do {
                        let r = try await runtime.runGh(["repo", "view", "--json", "nameWithOwner"])
                        if r.exitCode == 0,
                           let v = parseJSONString(r.stdout),
                           case .object(let d) = v,
                           case .string(let s) = d["nameWithOwner"] {
                            slug = s
                        } else {
                            return failedValue("gh_check_status", r,
                                hint: "could not resolve current repo — pass `repo: 'OWNER/REPO'`")
                        }
                    } catch let e as GhError {
                        return ghErrorValue("gh_check_status", e)
                    } catch {
                        return invalidArgsValue("gh_check_status", error.localizedDescription)
                    }
                }
                guard let resolvedSlug = slug else {
                    return invalidArgsValue("gh_check_status", "missing repo slug")
                }
                let endpoint = "repos/\(resolvedSlug)/commits/\(ref)/check-runs"
                let args = ["api", endpoint, "--paginate"]
                do {
                    let r = try await runtime.runGh(args)
                    if r.exitCode != 0 { return failedValue("gh_check_status", r, hint: nil) }
                    guard let parsed = parseJSONString(r.stdout) else {
                        return failedValue("gh_check_status", r,
                            hint: "could not parse JSON from gh api response")
                    }
                    return summarizeCheckRuns(parsed, ref: ref, slug: resolvedSlug, raw: r)
                } catch let e as GhError {
                    return ghErrorValue("gh_check_status", e)
                } catch {
                    return invalidArgsValue("gh_check_status", error.localizedDescription)
                }
            }
        )
    }

    static func makeIssueOpen(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_issue_open",
            module: moduleName,
            tier: .request,
            description: "Open a new GitHub issue via `gh issue create`. Returns the issue URL.",
            inputSchema: schemaObj([
                "title":     strProp("Issue title (required)."),
                "body":      strProp("Issue body markdown."),
                "repo":      strProp("Optional OWNER/REPO override."),
                "labels":    arrStrProp("Labels to apply."),
                "assignees": arrStrProp("Assignees by login."),
                "milestone": strProp("Optional milestone name.")
            ], required: ["title"]),
            handler: { arguments in
                if let cap = await ensureCapability("gh_issue_open", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments,
                      case .string(let title) = obj["title"], !title.isEmpty else {
                    return invalidArgsValue("gh_issue_open", "required: title (non-empty string)")
                }
                var args: [String] = ["issue", "create", "--title", title]
                appendStr(&args, obj, "body", "--body")
                appendStr(&args, obj, "repo", "--repo")
                appendStr(&args, obj, "milestone", "--milestone")
                appendArr(&args, obj, "labels", "--label")
                appendArr(&args, obj, "assignees", "--assignee")
                // Body is required by `gh issue create` non-interactively; default to empty if missing.
                if !args.contains("--body") {
                    args.append(contentsOf: ["--body", ""])
                }
                return await runSync("gh_issue_open", ghArgs: args, runtime: runtime,
                                     parseURL: true, parseJSON: false)
            }
        )
    }

    static func makeIssueComment(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_issue_comment",
            module: moduleName,
            tier: .request,
            description: "Add a comment to a GitHub issue via `gh issue comment <number> --body ...`. Returns the comment URL.",
            inputSchema: schemaObj([
                "number": intProp("Issue number (required)."),
                "body":   strProp("Comment body markdown (required)."),
                "repo":   strProp("Optional OWNER/REPO override.")
            ], required: ["number", "body"]),
            handler: { arguments in
                if let cap = await ensureCapability("gh_issue_comment", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments,
                      case .int(let number) = obj["number"],
                      case .string(let body) = obj["body"], !body.isEmpty else {
                    return invalidArgsValue("gh_issue_comment", "required: number (int), body (non-empty string)")
                }
                var args: [String] = ["issue", "comment", String(number), "--body", body]
                appendStr(&args, obj, "repo", "--repo")
                return await runSync("gh_issue_comment", ghArgs: args, runtime: runtime,
                                     parseURL: true, parseJSON: false)
            }
        )
    }

    static func makeIssueClose(runtime: GhRuntime) -> ToolRegistration {
        ToolRegistration(
            name: "gh_issue_close",
            module: moduleName,
            tier: .request,
            description: "Close a GitHub issue via `gh issue close <number>`. Optional closing comment and reason ('completed' | 'not planned').",
            inputSchema: schemaObj([
                "number":  intProp("Issue number (required)."),
                "repo":    strProp("Optional OWNER/REPO override."),
                "comment": strProp("Optional closing comment."),
                "reason":  enumProp(["completed", "not planned"], "Close reason.")
            ], required: ["number"]),
            handler: { arguments in
                if let cap = await ensureCapability("gh_issue_close", runtime: runtime) { return cap }
                guard case .object(let obj) = arguments,
                      case .int(let number) = obj["number"] else {
                    return invalidArgsValue("gh_issue_close", "required: number (int)")
                }
                var args: [String] = ["issue", "close", String(number)]
                appendStr(&args, obj, "repo", "--repo")
                appendStr(&args, obj, "comment", "--comment")
                appendStr(&args, obj, "reason", "--reason")
                return await runSync("gh_issue_close", ghArgs: args, runtime: runtime,
                                     parseURL: false, parseJSON: false)
            }
        )
    }

    // ===========================================================
    // MARK: - Shared helpers
    // ===========================================================

    /// Returns a `capability_missing` envelope value if gh isn't available; nil otherwise.
    static func ensureCapability(_ tool: String, runtime: GhRuntime) async -> Value? {
        let cap = await runtime.capabilityCheck()
        if cap.ok { return nil }
        return capabilityMissingValue(tool, cap.reason ?? "gh capability missing", path: cap.path)
    }

    static func runSync(
        _ tool: String,
        ghArgs: [String],
        runtime: GhRuntime,
        parseURL: Bool,
        parseJSON: Bool
    ) async -> Value {
        do {
            let r = try await runtime.runGh(ghArgs)
            if r.exitCode != 0 { return failedValue(tool, r, hint: nil) }
            var dict: [String: Value] = [
                "ok":         .bool(true),
                "tool":       .string(tool),
                "exitCode":   .int(Int(r.exitCode)),
                "durationMs": .int(Int(r.durationMs.rounded()))
            ]
            if parseURL, let u = GhRuntime.firstGitHubURL(in: r.stdout) {
                dict["url"] = .string(u)
            }
            if parseJSON, let v = parseJSONString(r.stdout) {
                dict["json"] = v
            } else {
                dict["stdout"] = .string(r.stdout)
            }
            if !r.stderr.isEmpty { dict["stderr"] = .string(r.stderr) }
            return .object(dict)
        } catch let e as GhError {
            return ghErrorValue(tool, e)
        } catch {
            return invalidArgsValue(tool, error.localizedDescription)
        }
    }

    static func runInBackground(
        _ tool: String,
        ghArgs: [String],
        runtime: GhRuntime,
        bgRuntime: BgProcessRuntime,
        label: String
    ) async -> Value {
        guard let path = await runtime.path else {
            return capabilityMissingValue(tool, "gh CLI not on PATH", path: nil)
        }
        let quoted = ghArgs.map { shellQuote($0) }.joined(separator: " ")
        let cmd = "exec \(shellQuote(path)) \(quoted)"
        do {
            let meta = try await bgRuntime.start(
                command: cmd, workingDir: nil, env: [:], label: label
            )
            return .object([
                "ok":         .bool(true),
                "tool":       .string(tool),
                "background": .bool(true),
                "jobId":      .string(meta.id),
                "pid":        .int(Int(meta.pid)),
                "label":      .string(label),
                "command":    .string(cmd),
                "hint":       .string("poll bg_process_status / bg_process_logs with id=\(meta.id)")
            ])
        } catch {
            return .object([
                "ok":     .bool(false),
                "status": .string("failed"),
                "tool":   .string(tool),
                "error":  .string("bg_process_start failed: \(error)")
            ])
        }
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

    public static func failedValue(_ tool: String, _ r: GhInvocationResult, hint: String?) -> Value {
        let trimmedErr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let errMsg = trimmedErr.isEmpty ? "gh exited \(r.exitCode)" : trimmedErr
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

    public static func ghErrorValue(_ tool: String, _ e: GhError) -> Value {
        switch e {
        case .capabilityMissing(let r): return capabilityMissingValue(tool, r, path: nil)
        case .invalidArgument(let r):  return invalidArgsValue(tool, r)
        case .spawnFailed(let r):
            return .object([
                "ok":     .bool(false),
                "status": .string("failed"),
                "tool":   .string(tool),
                "error":  .string("spawn failed: \(r)")
            ])
        case .ghFailed(let code, let err):
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

    // MARK: - Arg builders

    static func appendStr(_ args: inout [String], _ obj: [String: Value], _ key: String, _ flag: String) {
        if case .string(let s) = obj[key], !s.isEmpty {
            args.append(flag)
            args.append(s)
        }
    }
    static func appendArr(_ args: inout [String], _ obj: [String: Value], _ key: String, _ flag: String) {
        guard case .array(let arr) = obj[key] else { return }
        for v in arr {
            if case .string(let s) = v, !s.isEmpty {
                args.append(flag)
                args.append(s)
            }
        }
    }

    // MARK: - JSON helpers

    public static func parseJSONString(_ raw: String) -> Value? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) else {
            return nil
        }
        return jsonAnyToValue(any)
    }

    public static func jsonAnyToValue(_ any: Any) -> Value {
        if let n = any as? NSNull { _ = n; return .null }
        if let s = any as? String { return .string(s) }
        // NSNumber may carry a Bool, Int, or Double — disambiguate via objCType.
        if let n = any as? NSNumber {
            let cls = String(cString: n.objCType)
            if cls == "c" || cls == "B" { return .bool(n.boolValue) }
            if let i = Int(exactly: n.int64Value), Double(i) == n.doubleValue {
                return .int(i)
            }
            // Fall back to string for non-integer doubles since MCP Value lacks .double in this codebase.
            return .string("\(n.doubleValue)")
        }
        if let arr = any as? [Any] { return .array(arr.map { jsonAnyToValue($0) }) }
        if let dict = any as? [String: Any] {
            var out: [String: Value] = [:]
            for (k, v) in dict { out[k] = jsonAnyToValue(v) }
            return .object(out)
        }
        return .null
    }

    static func summarizeCheckRuns(_ parsed: Value, ref: String, slug: String, raw: GhInvocationResult) -> Value {
        var total = 0, passing = 0, failing = 0, pending = 0, neutral = 0
        var entries: [Value] = []
        if case .object(let dict) = parsed,
           case .array(let runs) = dict["check_runs"] {
            total = runs.count
            for run in runs {
                guard case .object(let r) = run else { continue }
                let status: String = {
                    if case .string(let s) = r["status"] { return s }
                    return "unknown"
                }()
                let conclusion: String? = {
                    if case .string(let s) = r["conclusion"] { return s }
                    return nil
                }()
                let name: String = {
                    if case .string(let s) = r["name"] { return s }
                    return "<unnamed>"
                }()
                let urlStr: String? = {
                    if case .string(let s) = r["html_url"] { return s }
                    return nil
                }()
                if status != "completed" {
                    pending += 1
                } else {
                    switch conclusion ?? "" {
                    case "success":           passing += 1
                    case "failure", "timed_out", "action_required", "cancelled":
                                              failing += 1
                    case "neutral", "skipped":
                                              neutral += 1
                    default:                  pending += 1
                    }
                }
                var e: [String: Value] = [
                    "name":   .string(name),
                    "status": .string(status)
                ]
                if let c = conclusion { e["conclusion"] = .string(c) }
                if let u = urlStr     { e["url"] = .string(u) }
                entries.append(.object(e))
            }
        }
        let allGreen = (failing == 0 && pending == 0 && total > 0)
        return .object([
            "ok":         .bool(true),
            "tool":       .string("gh_check_status"),
            "ref":        .string(ref),
            "repo":       .string(slug),
            "total":      .int(total),
            "passing":    .int(passing),
            "failing":    .int(failing),
            "pending":    .int(pending),
            "neutral":    .int(neutral),
            "allGreen":   .bool(allGreen),
            "checks":     .array(entries),
            "exitCode":   .int(Int(raw.exitCode)),
            "durationMs": .int(Int(raw.durationMs.rounded()))
        ])
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
