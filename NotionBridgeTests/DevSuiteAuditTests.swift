// DevSuiteAuditTests.swift — Dev-suite audit (every-angle-of-attack)
// NotionBridge · Tests
//
// Cross-tool invariants for the entire `module == "dev"` surface (the
// authoritative Dev suite: DevModule, BgProcessModule, DevServerModule,
// GhModule, GitModule, LspModule, CodeEditModule, WranglerModule,
// ArtifactModule, PlaywrightModule, VitestModule, LighthouseModule).
//
// Per-module behavioural tests live in the module-specific files; this
// file locks suite-wide contracts so a future Dev tool cannot regress
// them: annotation coverage, camelCase param keys, non-thin rendered
// descriptions, required-field schema sanity, requiresConfirmation /
// tier coherence, and BridgeToolAliases did-you-mean recovery.

import Foundation
import MCP
import NotionBridgeLib

/// Build a router carrying ONLY the Dev-suite modules, with hermetic
/// runtimes where a module would otherwise touch shared singletons.
private func makeDevRouter() async -> ToolRouter {
    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NBT-devsuite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let bg = BgProcessRuntime(baseDir: base)

    await DevModule.register(on: router)
    await BgProcessModule.register(on: router, runtime: bg)
    await DevServerModule.register(on: router)
    await GhModule.register(on: router)
    await GitModule.register(on: router)
    await LspModule.register(on: router)
    await CodeEditModule.register(on: router)
    await WranglerModule.register(on: router)
    await ArtifactModule.register(on: router)
    await PlaywrightModule.register(on: router, bgRuntime: bg, probeOverride: { true })
    await VitestModule.register(on: router, bgRuntime: bg, probeOverride: { true })
    await LighthouseModule.register(on: router, bgRuntime: bg, probeOverride: { true })
    return router
}

private func camelCaseKeyOK(_ key: String) -> Bool {
    guard let first = key.first, first.isLowercase else { return false }
    return key.allSatisfy { $0.isLetter || $0.isNumber }
}

func runDevSuiteAuditTests() async {
    print("\n\u{1F50E} Dev-Suite Audit (cross-tool invariants)")

    // The authoritative tool inventory (48 tools), derived from the
    // module: field on every ToolRegistration. If a Dev module adds or
    // removes a tool this set must move WITH it — a silent drop is caught
    // here, not just by the global floor gate.
    let expectedDevTools: Set<String> = [
        "dev_module_info",
        "bg_process_start", "bg_process_status", "bg_process_logs",
        "bg_process_kill", "bg_process_list",
        "port_inspect", "devserver_start", "devserver_stop", "devserver_health",
        "gh_pr_open", "gh_pr_status", "gh_pr_comment", "gh_pr_merge",
        "gh_actions_runs", "gh_check_status",
        "gh_issue_open", "gh_issue_comment", "gh_issue_close",
        "git_status", "git_diff", "git_log", "git_show", "git_blame",
        "git_apply_patch", "git_worktree", "git_create_branch", "git_merge",
        "lsp_diagnostics", "lsp_hover", "lsp_references", "lsp_definition",
        "lsp_rename", "lsp_session_list",
        "code_search", "file_str_replace", "file_apply_patch",
        "wrangler_d1_status",
        "http_fetch", "diff_render", "file_watch", "tree_sitter_query",
        "file_zip", "file_unzip", "file_hash",
        "playwright_run", "vitest_run", "lighthouse_run"
    ]

    await test("Dev suite registers exactly the 48 authoritative tools under module=\"dev\"") {
        let router = await makeDevRouter()
        let live = Set((await router.registrations(forModule: "dev")).map(\.name))
        let missing = expectedDevTools.subtracting(live)
        let extra = live.subtracting(expectedDevTools)
        try expect(missing.isEmpty, "Dev tools MISSING from registration: \(missing.sorted())")
        try expect(extra.isEmpty, "UNEXPECTED tools registered under dev: \(extra.sorted())")
        try expect(expectedDevTools.count == 48,
                   "authoritative inventory drift: expected-set has \(expectedDevTools.count)")
        try expect(live.count == 48, "expected 48 dev tools, got \(live.count)")
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
        let readOnly = ["dev_module_info", "git_status", "git_diff", "git_log",
                        "git_show", "git_blame", "code_search", "file_hash",
                        "diff_render", "lsp_diagnostics", "lsp_hover",
                        "wrangler_d1_status", "port_inspect", "bg_process_status",
                        "bg_process_logs", "bg_process_list", "devserver_health"]
        for name in readOnly {
            guard let a = ToolAnnotationCatalog.annotations(for: name) else {
                throw TestError.assertion("\(name) has no annotation")
            }
            try expect(a.readOnlyHint == true && a.destructiveHint == false,
                       "\(name) must be read-only & non-destructive, got ro=\(a.readOnlyHint) destr=\(a.destructiveHint)")
        }
    }

    await test("mutating Dev tools are annotated non-read-only") {
        let mutating = ["bg_process_start", "bg_process_kill", "devserver_start",
                        "devserver_stop", "gh_pr_open", "gh_pr_merge",
                        "gh_issue_close", "git_apply_patch", "git_merge",
                        "git_create_branch", "file_str_replace", "file_apply_patch",
                        "file_zip", "file_unzip", "lsp_rename", "http_fetch",
                        "playwright_run", "vitest_run", "lighthouse_run"]
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
        // bg_process_status requires 'id'. Send the canonical wrong key
        // 'page_id' (a harvested misnomer) → handler throws invalidArguments
        // → central recovery must append the did-you-mean hint.
        let (text, isError) = await router.dispatchFormatted(
            toolName: "bg_process_status",
            arguments: .object(["page_id": .string("x")])
        )
        try expect(isError, "missing required 'id' must be an error")
        try expect(text.contains("did you mean") && text.contains("page_id→pageId"),
                   "central misnomer recovery did not fire for Dev tool: \(text)")
    }

    await test("dispatchFormatted does NOT inject a false did-you-mean on clean Dev keys") {
        let router = await makeDevRouter()
        // Clean (correct) call with no misnomer → no hint, success path.
        let (text, isError) = await router.dispatchFormatted(
            toolName: "dev_module_info",
            arguments: .object([:])
        )
        try expect(!isError, "dev_module_info happy path should not be an error: \(text)")
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
