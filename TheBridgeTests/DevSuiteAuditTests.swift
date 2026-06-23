// DevSuiteAuditTests.swift — Dev-suite audit (every-angle-of-attack)
// TheBridge · Tests
//
// Cross-tool invariants for the surviving `module == "dev"` surface:
// DevModule, GhModule, GitModule, CodeEditModule, ArtifactModule.
//
// Per-module behavioural tests live in the module-specific files; this
// file locks suite-wide contracts so a future Dev tool cannot regress
// them: annotation coverage, camelCase param keys, non-thin rendered
// descriptions, required-field schema sanity, requiresConfirmation /
// tier coherence, and BridgeToolAliases did-you-mean recovery.

import Foundation
import MCP
import TheBridgeLib

/// Build a router carrying ONLY the surviving Dev-suite modules.
private func makeDevRouter() async -> ToolRouter {
    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())

    await DevModule.register(on: router)
    await GhModule.register(on: router)
    await GitModule.register(on: router)
    await CodeEditModule.register(on: router)
    await ArtifactModule.register(on: router)
    return router
}

private func camelCaseKeyOK(_ key: String) -> Bool {
    guard let first = key.first, first.isLowercase else { return false }
    return key.allSatisfy { $0.isLetter || $0.isNumber }
}

func runDevSuiteAuditTests() async {
    print("\n\u{1F50E} Dev-Suite Audit (cross-tool invariants)")

    // The authoritative tool inventory under module="dev" for the surviving
    // modules. Sprint A wave notes:
    //   • W2 #8: `dev_module_info` REMOVED (scaffold placeholder).
    //   • W2 #7: gh_issue_open / gh_pr_open / gh_actions_runs gain
    //     renamed siblings (1-cycle aliases keep old names live).
    //   • W3 #6: git_worktree gains split siblings.
    //   • W4 #5: file_str_replace / file_apply_patch gain a merged `file_edit`.
    // This test is wave-tolerant: it asserts every CURRENTLY-LIVE dev tool
    // is in the expected superset, and that no surprise tools showed up.
    // Wave-specific containment is exercised by per-module tests.
    let expectedDevTools: Set<String> = [
        // gh_* (renames keep old name as deprecation alias):
        "gh_pr_create",
        "gh_pr_status", "gh_pr_comment", "gh_pr_merge",
        "gh_actions_runs", "gh_actions_runs_list",
        "gh_check_status",
        "gh_issue_open", "gh_issue_create",
        "gh_issue_comment", "gh_issue_close",
        "git_status", "git_diff", "git_log", "git_show", "git_blame",
        "git_apply_patch",
        // git_worktree split (alias kept):
        "git_worktree", "git_worktree_list", "git_worktree_add", "git_worktree_remove",
        "git_create_branch", 
        "code_search",
        // file_edit merge:
        "file_edit",
        "http_fetch", "diff_render",
        "file_zip", "file_unzip", "file_hash"
    ]

    await test("Dev module surface is a subset of the post-Sprint-A expected superset") {
        let router = await makeDevRouter()
        let live = Set((await router.registrations(forModule: "dev")).map(\.name))
        let extra = live.subtracting(expectedDevTools)
        try expect(extra.isEmpty, "UNEXPECTED tools registered under dev (not in Sprint A expected superset): \(extra.sorted())")
        // Floor check: removed tools must NOT be present.
        try expect(!live.contains("dev_module_info"),
                   "dev_module_info should be removed (Sprint A · mcp-builder #8)")
    }

    await test("every Dev tool has an EXPLICIT ToolAnnotationCatalog entry (zero implicit defaults)") {
        let router = await makeDevRouter()
        let regs = await router.registrations(forModule: "dev")
        let missing = regs.map(\.name).filter { ToolAnnotationCatalog.annotations(for: $0) == nil }
        try expect(missing.isEmpty,
                   "Dev tools missing explicit annotations (fail-closed backstop would mask them): \(missing.sorted())")
    }

    await test("every Dev tool inputSchema property key is camelCase") {
        let router = await makeDevRouter()
        var violations: [String] = []
        for reg in await router.registrations(forModule: "dev") {
            guard case .object(let top) = reg.inputSchema,
                  case .object(let props)? = top["properties"] else { continue }
            for key in props.keys where !camelCaseKeyOK(key) {
                violations.append("\(reg.name).\(key)")
            }
        }
        try expect(violations.isEmpty,
                   "non-camelCase Dev schema keys (route legacy forms via BridgeToolAliases): \(violations.sorted())")
    }

    await test("every Dev tool rendered MCP description is non-thin and within char budget") {
        let router = await makeDevRouter()
        var thin: [String] = []
        var overBudget: [String] = []
        for reg in await router.registrations(forModule: "dev") {
            let rendered = BridgeToolDescriptionRenderer.render(reg)
            // v3.0·0.5 contract: a rendered description must carry real
            // selection guidance, not be empty/one-word.
            if rendered.trimmingCharacters(in: .whitespacesAndNewlines).count < 24 {
                thin.append("\(reg.name) (len=\(rendered.count))")
            }
            if rendered.count > BridgeToolDescriptionRenderer.charBudget {
                overBudget.append(reg.name)
            }
        }
        try expect(thin.isEmpty, "Dev tools with thin descriptions: \(thin.sorted())")
        try expect(overBudget.isEmpty, "Dev tools over the \(BridgeToolDescriptionRenderer.charBudget)-char budget: \(overBudget.sorted())")
    }

    await test("every Dev tool inputSchema is a well-formed JSON-schema object") {
        let router = await makeDevRouter()
        var bad: [String] = []
        for reg in await router.registrations(forModule: "dev") {
            guard case .object(let top) = reg.inputSchema else { bad.append("\(reg.name): not object"); continue }
            guard case .string(let t)? = top["type"], t == "object" else {
                bad.append("\(reg.name): type != object"); continue
            }
            // `required` (when present) must be an array of strings that
            // each name a declared property — a misnamed required key is a
            // latent always-fails contract.
            if case .array(let req)? = top["required"] {
                guard case .object(let props)? = top["properties"] else {
                    if !req.isEmpty { bad.append("\(reg.name): required set but no properties") }
                    continue
                }
                for r in req {
                    guard case .string(let rk) = r else { bad.append("\(reg.name): non-string required entry"); continue }
                    if props[rk] == nil { bad.append("\(reg.name): required '\(rk)' not in properties") }
                }
            }
        }
        try expect(bad.isEmpty, "malformed Dev inputSchemas: \(bad.sorted())")
    }

    await test("Dev tool requiresConfirmation annotation mirrors tier/neverAutoApprove") {
        let router = await makeDevRouter()
        for reg in await router.registrations(forModule: "dev") {
            guard let ann = ToolAnnotationCatalog.annotations(for: reg.name) else { continue }
            let shouldConfirm = reg.tier == .request || reg.neverAutoApprove
            try expect(ann.requiresConfirmation == shouldConfirm,
                       "\(reg.name): requiresConfirmation=\(ann.requiresConfirmation) but tier=\(reg.tier.rawValue) nap=\(reg.neverAutoApprove)")
        }
    }

    await test("read-only Dev tools are annotated non-destructive") {
        // Spot-check the read-only contract on the obvious read-only tools.
        // dev_module_info removed by Sprint A · mcp-builder #8.
        let readOnly = ["git_status", "git_diff", "git_log",
                        "git_show", "git_blame", "code_search", "file_hash",
                        "diff_render"]
        for name in readOnly {
            guard let a = ToolAnnotationCatalog.annotations(for: name) else {
                throw TestError.assertion("\(name) has no annotation")
            }
            try expect(a.readOnlyHint == true && a.destructiveHint == false,
                       "\(name) must be read-only & non-destructive, got ro=\(a.readOnlyHint) destr=\(a.destructiveHint)")
        }
    }

    await test("mutating Dev tools are annotated non-read-only") {
        let mutating = ["gh_pr_merge",
                        "gh_issue_close", "git_apply_patch", 
                        "git_create_branch",
                        "file_zip", "file_unzip", "http_fetch"]
        for name in mutating {
            guard let a = ToolAnnotationCatalog.annotations(for: name) else {
                throw TestError.assertion("\(name) has no annotation")
            }
            try expect(a.readOnlyHint == false,
                       "\(name) mutates/spawns — readOnlyHint must be false")
        }
    }

    // ---- did-you-mean recovery on Dev tools -----------------------------
    // The central BridgeToolAliases layer applies to ALL tools at the
    // dispatchFormatted error path. Verify it actually fires for a Dev
    // tool when a known wrong key is sent alongside a missing required arg.

    await test("dispatchFormatted surfaces did-you-mean on a Dev tool with a known misnomer key") {
        let router = await makeDevRouter()
        // git_show requires 'ref'. Send the canonical wrong key
        // 'commit_hash' (a harvested misnomer) → handler throws invalidArguments
        // → central recovery must append the did-you-mean hint.
        let (text, isError) = await router.dispatchFormatted(
            toolName: "file_hash",
            arguments: .object(["page_id": .string("abc123")])
        )
        try expect(isError, "missing required 'ref' must be an error")
        try expect(text.contains("did you mean") && text.contains("page_id→pageId"),
                   "central misnomer recovery did not fire for Dev tool: \(text)")
    }

    await test("dispatchFormatted does NOT inject a false did-you-mean on clean Dev keys") {
        let router = await makeDevRouter()
        // Clean (correct) call with no misnomer → no hint, success path.
        // dev_module_info was removed in Sprint A · #8; use git_status as
        // a safe read-only no-arg substitute (working tree may be dirty
        // in CI, but the dispatch succeeds with structured output either way).
        let (text, isError) = await router.dispatchFormatted(
            toolName: "git_status",
            arguments: .object([:])
        )
        // git_status may return non-error or structured error depending on
        // working tree; the assertion targets the did-you-mean recovery,
        // not git_status's success branch.
        _ = isError
        try expect(!text.contains("did you mean"), "false did-you-mean on a clean call: \(text)")
    }

    await test("unknown Dev-looking tool name routes through structured unknownTool error") {
        let router = await makeDevRouter()
        let (text, isError) = await router.dispatchFormatted(
            toolName: "git_nonexistent_xyz",
            arguments: .object([:])
        )
        try expect(isError, "unknown tool must be an error")
        try expect(text.lowercased().contains("git_nonexistent_xyz"),
                   "error should name the unknown tool: \(text)")
    }
}
