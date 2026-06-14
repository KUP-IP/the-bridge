// ToolMetadataAuthoringTests.swift — v3.0·0.5 (PKT — agentic-usability)
// P1: notion_query projection helper + end-to-end proof that authored
// ToolMetadata on real registrations renders into the MCP description.

import Foundation
import MCP
import NotionBridgeLib

func runToolMetadataAuthoringTests() async {
    print("\n\u{1F516} Tool metadata authoring + projection (PKT v3.0·0.5 · P1)")

    await test("NotionQueryProjection.pick: lossless, missing keys skipped, deterministic") {
        let props: [String: Any] = [
            "Status": ["type": "status", "status": ["name": "Done"]],
            "Name": ["type": "title", "title": []],
        ]
        let a = NotionQueryProjection.pick(props, keys: ["Status", "Absent"])
        try expect(a.count == 1 && a["Status"] != nil, "expected only Status, got \(a.keys.sorted())")
        try expect(a["Status"]!.contains("Done"), "raw JSON not preserved: \(a["Status"]!)")
        let b = NotionQueryProjection.pick(props, keys: ["Status", "Absent"])
        try expect(a == b, "non-deterministic projection")
        try expect(NotionQueryProjection.pick(props, keys: []).isEmpty, "empty keys → empty")
    }

    // End-to-end: authored metadata must reach the rendered MCP description.
    let gate = SecurityGate(); let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await BridgeModuleRegistry.registerStaticFeatureModules(
        on: router,
        registerSession: { await SessionModule.register(on: $0, auditLog: log) })
    let regs = await router.allRegistrations()

    func tool(_ name: String) -> Tool? {
        guard let r = regs.first(where: { $0.name == name }) else { return nil }
        return MCPToolFactory.tool(for: r)
    }

    await test("notion_query: authored steers render into MCP description + title") {
        guard let t = tool("notion_query") else { throw TestError.assertion("notion_query not registered") }
        let d = t.description ?? ""
        try expect(d.contains("When to use:"), "no whenToUse in: \(d)")
        try expect(d.contains("notion_datasource_get"), "no related-tool steer in: \(d)")
        try expect(t.annotations.title == "Notion: Query Data Source", "title: \(String(describing: t.annotations.title))")
    }

    await test("notion_comment_create: 2000-char + discussion steers rendered") {
        guard let t = tool("notion_comment_create") else { throw TestError.assertion("not registered") }
        let d = t.description ?? ""
        try expect(d.contains("2000"), "no size steer in: \(d)")
        try expect(d.contains("notion_discussion_create"), "no threaded-reply steer in: \(d)")
    }
}
