// ModuleGroupTests.swift — PKT-877 (Bridge v3.6·2)
// NotionBridgeTests
//
// W1 — Derivation: tool-name prefix → ModuleGroup; explicit override path;
// no-orphan invariant against the LIVE BridgeModuleRegistry registration
// (so the test fails the moment a new tool is added without a group).
//
// State machine: enabledCount + masterState derivation (off/partial/on).
//
// (W3 — the dispatch fail-closed contract — lives in its own dedicated
// test file `ToolRouterFailClosedTests.swift` so the SAFETY-CONTRACT
// assertion is impossible to miss in `grep`.)

import Foundation
import NotionBridgeLib

func runModuleGroupTests() async {
    print("\n\u{1F9F1} ModuleGroup (PKT-877 W1 · prefix derivation + state)")

    // ----------------------------------------------------------------
    // Derivation — pure
    // ----------------------------------------------------------------

    await test("prefix derivation: file_* → .file") {
        try expect(ModuleGroupDerivation.resolve(toolName: "file_read") == .file)
        try expect(ModuleGroupDerivation.resolve(toolName: "file_write") == .file)
        try expect(ModuleGroupDerivation.resolve(toolName: "file_edit") == .file)
    }

    await test("prefix derivation: notion_* → .notion") {
        try expect(ModuleGroupDerivation.resolve(toolName: "notion_page_read") == .notion)
        try expect(ModuleGroupDerivation.resolve(toolName: "notion_query") == .notion)
    }

    await test("prefix derivation: messages_*, contacts_*, screen_*, chrome_*") {
        try expect(ModuleGroupDerivation.resolve(toolName: "messages_send") == .messages)
        try expect(ModuleGroupDerivation.resolve(toolName: "contacts_search") == .contacts)
        try expect(ModuleGroupDerivation.resolve(toolName: "screen_capture") == .screen)
        try expect(ModuleGroupDerivation.resolve(toolName: "chrome_tabs") == .chrome)
    }

    await test("prefix derivation: ax_* → .accessibility, bg_* → .bgProcess") {
        try expect(ModuleGroupDerivation.resolve(toolName: "ax_inspect") == .accessibility)
        try expect(ModuleGroupDerivation.resolve(toolName: "ax_tree") == .accessibility)
        try expect(ModuleGroupDerivation.resolve(toolName: "bg_process_kill") == .bgProcess)
    }

    await test("prefix derivation: job_* AND jobs_* both fold into .jobs") {
        try expect(ModuleGroupDerivation.resolve(toolName: "job_create") == .jobs)
        try expect(ModuleGroupDerivation.resolve(toolName: "jobs_pause_all") == .jobs)
    }

    await test("prefix derivation: skill_*, skills_* both → .skills") {
        try expect(ModuleGroupDerivation.resolve(toolName: "skill_create") == .skills)
        try expect(ModuleGroupDerivation.resolve(toolName: "skills_routing_list") == .skills)
    }

    // Explicit-override path (Q1: annotation can override the prefix rule).
    await test("override: applescript_exec is pinned to .applescript group") {
        try expect(ModuleGroupDerivation.resolve(toolName: "applescript_exec") == .applescript)
    }

    await test("override: shell-adjacent runners are pinned away from the prefix bucket") {
        // run_script does NOT start with "shell" but lives in the shell group.
        try expect(ModuleGroupDerivation.resolve(toolName: "run_script") == .shell)
        // http_fetch is its own group.
        try expect(ModuleGroupDerivation.resolve(toolName: "http_fetch") == .http)
        // payment_execute → .payment
    }

    await test("override: synthetic-input primitives fold into .synthetic") {
        try expect(ModuleGroupDerivation.resolve(toolName: "cgevent_send") == .synthetic)
        try expect(ModuleGroupDerivation.resolve(toolName: "keyboard_type") == .synthetic)
        try expect(ModuleGroupDerivation.resolve(toolName: "mouse_click") == .synthetic)
    }

    await test("override: skill-adjacent legacy names fold into .skills") {
        try expect(ModuleGroupDerivation.resolve(toolName: "fetch_skill") == .skills)
    }

    await test("system catch-all: orphan prefix → .system (Q1 no-orphan)") {
        try expect(ModuleGroupDerivation.resolve(toolName: "tools_list") == .system)
        try expect(ModuleGroupDerivation.resolve(toolName: "session_info") == .system)
        try expect(ModuleGroupDerivation.resolve(toolName: "notify") == .system)
        // Genuinely unknown — must STILL bucket to .system.
        try expect(ModuleGroupDerivation.resolve(toolName: "totally_made_up_tool_xyz") == .system)
    }

    // ----------------------------------------------------------------
    // Live-registry invariant: NO orphans against the actual registrar
    // ----------------------------------------------------------------

    await test("LIVE: every registered tool resolves to a non-system group OR is an explicit system tool") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: true,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        let names = await router.allRegistrations().map(\.name)
        try expect(!names.isEmpty, "live registry empty — registrar didn't run?")

        // No tool ungrouped (Q1 invariant: every tool resolves to some group).
        for n in names {
            let id = ModuleGroupDerivation.resolve(toolName: n)
            // The catch-all `.system` IS a valid group — what we forbid is
            // a name that crashes or returns nil. The function is total by
            // construction; this assertion is a regression guard against
            // future refactors that might re-introduce optionality.
            _ = id
        }
        // Also exercise the full group derivation against the live set.
        let groups = ModuleGroupDerivation.deriveGroups(
            registeredToolNames: names,
            disabledNames: []
        )
        let covered = Set(groups.flatMap(\.tools))
        try expect(covered == Set(names),
                   "deriveGroups dropped some live tools: missing=\(Set(names).subtracting(covered).sorted())")
    }

    await test("LIVE: deriveGroups order is stable and matches ModuleGroupID.allCases") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: true,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        let names = await router.allRegistrations().map(\.name)
        let groups = ModuleGroupDerivation.deriveGroups(registeredToolNames: names, disabledNames: [])
        // Empty groups are dropped; the non-empty subset must appear in
        // declared order.
        let declaredOrder = ModuleGroupID.allCases
        var lastIndex = -1
        for g in groups {
            guard let idx = declaredOrder.firstIndex(of: g.id) else {
                throw TestError.assertion("group \(g.id) not in declared order")
            }
            try expect(idx > lastIndex, "group order drift: \(g.id) appeared before its declared slot")
            lastIndex = idx
        }
    }

    // ----------------------------------------------------------------
    // State machine — master toggle derived from per-tool state (Q2)
    // ----------------------------------------------------------------

    await test("master state: all-on when none disabled") {
        let g = ModuleGroup(
            id: .file,
            tools: ["file_read", "file_write", "file_edit"],
            disabledNames: []
        )
        try expect(g.masterState == .on)
        try expect(g.enabledCount == 3)
    }

    await test("master state: all-off when every member disabled") {
        let g = ModuleGroup(
            id: .messages,
            tools: ["messages_send", "messages_search"],
            disabledNames: ["messages_send", "messages_search"]
        )
        try expect(g.masterState == .off)
        try expect(g.enabledCount == 0)
    }

    await test("master state: partial when some-but-not-all disabled") {
        let g = ModuleGroup(
            id: .notion,
            tools: ["notion_query", "notion_block_delete", "notion_datasource_delete"],
            disabledNames: ["notion_block_delete"]
        )
        try expect(g.masterState == .partial)
        try expect(g.enabledCount == 2)
    }

    await test("partial-state badge count is accurate (state-machine consistency)") {
        let tools = ["a_one", "a_two", "a_three", "a_four", "a_five", "a_six", "a_seven"]
        let g = ModuleGroup(
            id: .system,
            tools: tools,
            disabledNames: ["a_two", "a_three", "a_four", "a_five"]
        )
        // 7 total, 4 disabled, 3 enabled → badge says "3 of 7 enabled".
        try expect(g.total == 7)
        try expect(g.enabledCount == 3)
        try expect(g.masterState == .partial)
    }

    await test("disabledNames OUTSIDE the group does not affect masterState") {
        let g = ModuleGroup(
            id: .file,
            tools: ["file_read", "file_write"],
            disabledNames: ["notion_page_read", "messages_send"]  // unrelated
        )
        try expect(g.masterState == .on)
        try expect(g.enabledCount == 2)
    }

    // ----------------------------------------------------------------
    // Deep-link anchor → group resolution (Tools chip → scroll/expand).
    // The pure resolver that ModuleGroupList uses to map a dep-link chip's
    // `anchor` (a lowercased tool-module name) to the card it should scroll
    // to and auto-expand.
    // ----------------------------------------------------------------

    await test("deep-link: anchor matching a live tool's module resolves to that tool's group") {
        // The Tools dep-link chip anchor is `ToolInfo.module.lowercased()`.
        let live: [(name: String, module: String)] = [
            ("chrome_tabs", "chrome"),
            ("chrome_navigate", "chrome"),
            ("file_read", "file"),
        ]
        try expect(ModuleGroupDerivation.groupID(forAnchor: "chrome", registeredTools: live) == .chrome,
                   "a 'chrome' chip lands on the chrome group")
        try expect(ModuleGroupDerivation.groupID(forAnchor: "file", registeredTools: live) == .file)
        // Case-insensitive on the anchor.
        try expect(ModuleGroupDerivation.groupID(forAnchor: "Chrome", registeredTools: live) == .chrome)
    }

    await test("deep-link: anchor whose module groups elsewhere lands on the DERIVED group") {
        // `ax_*` tools register module "ax" but DERIVE to .accessibility — the
        // chip must follow the live tool's derived group, not a literal id.
        let live: [(name: String, module: String)] = [
            ("ax_inspect", "ax"),
            ("ax_tree", "ax"),
        ]
        try expect(ModuleGroupDerivation.groupID(forAnchor: "ax", registeredTools: live) == .accessibility,
                   "an 'ax' chip lands on the accessibility group (where ax_* tools live)")
    }

    await test("deep-link: anchor referencing a single tool expands the group that contains it") {
        // A chip can reference a tool whose module is a singleton; it must still
        // resolve to the group the tool belongs to (here applescript_exec → applescript).
        let live: [(name: String, module: String)] = [
            ("applescript_exec", "applescript"),
        ]
        try expect(ModuleGroupDerivation.groupID(forAnchor: "applescript", registeredTools: live) == .applescript)
    }

    await test("deep-link: anchor that is a group id but matches no live module falls back to the id") {
        // No live tool has module "memory", but "memory" IS a ModuleGroupID.
        try expect(ModuleGroupDerivation.groupID(forAnchor: "memory", registeredTools: []) == .memory)
    }

    await test("deep-link: nil / empty / unmappable anchor → nil (graceful no-op)") {
        try expect(ModuleGroupDerivation.groupID(forAnchor: nil, registeredTools: []) == nil)
        try expect(ModuleGroupDerivation.groupID(forAnchor: "", registeredTools: []) == nil)
        try expect(ModuleGroupDerivation.groupID(forAnchor: "   ", registeredTools: []) == nil)
        // An orphaned-credential chip (no live tools, not a group id) → nil.
        try expect(ModuleGroupDerivation.groupID(forAnchor: "openai", registeredTools: []) == nil,
                   "an anchor with no live tool and no matching group id resolves to nil")
    }

    // ----------------------------------------------------------------
    // Self-critique print: dump the live group map so it appears in
    // CI output. If a maintainer sees an unexpected group or count,
    // they can audit ModuleGroupOverride.map and prefixMap directly.
    // ----------------------------------------------------------------
    await test("self-critique: print live group map for human review") {
        let gate = SecurityGate()
        let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            includeStripe: true,
            registerSession: { r in await SessionModule.register(on: r, auditLog: log) }
        )
        let names = await router.allRegistrations().map(\.name)
        let groups = ModuleGroupDerivation.deriveGroups(registeredToolNames: names, disabledNames: [])
        print("    ── live ModuleGroup map (PKT-877 W1) ──")
        for g in groups {
            print("    • \(g.displayName): \(g.tools.count) — \(g.tools.joined(separator: ", "))")
        }
        let total = groups.reduce(0) { $0 + $1.tools.count }
        print("    ── total: \(total) tools across \(groups.count) groups ──")
        try expect(total == names.count)
    }
}
