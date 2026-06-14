// MCPToolFactoryTests.swift — v3.0·0.5 (PKT — agentic-usability)
// Enforces the keystone: one factory, deterministic render, behavior-
// preserving for metadata-less tools, title for every tool, and (by
// construction, since both transports call the one pure factory) byte-
// identical tool metadata across stdio and HTTP.

import Foundation
import MCP
import NotionBridgeLib

func runMCPToolFactoryTests() async {
    print("\n\u{1F3ED} MCPToolFactory + renderer (PKT v3.0·0.5)")

    func reg(_ name: String, desc: String, meta: ToolMetadata? = nil) -> ToolRegistration {
        ToolRegistration(
            name: name, module: "test", tier: .open,
            description: desc, inputSchema: .object(["type": .string("object")]),
            metadata: meta, handler: { _ in .object([:]) }
        )
    }

    await test("renderer: metadata-less == trimmed raw description (behavior-preserving)") {
        let r = reg("x_y", desc: "  Do the thing.  ")
        try expect(BridgeToolDescriptionRenderer.render(r) == "Do the thing.",
                   "got \(BridgeToolDescriptionRenderer.render(r))")
    }

    await test("renderer: deterministic + folds metadata in stable order") {
        let r = reg("x_y", desc: "Core.", meta: ToolMetadata(
            whenToUse: ["editing a page"], whenNotToUse: ["reading (use x_read)"],
            relatedTools: ["x_read", "x_list"]))
        let a = BridgeToolDescriptionRenderer.render(r)
        let b = BridgeToolDescriptionRenderer.render(r)
        try expect(a == b, "non-deterministic")
        try expect(a == "Core. — When to use: editing a page — Not for: reading (use x_read) — Related: x_read, x_list", "got: \(a)")
    }

    await test("renderer: hard char budget enforced") {
        let big = String(repeating: "z", count: 5000)
        let r = reg("x_y", desc: big)
        let out = BridgeToolDescriptionRenderer.render(r)
        try expect(out.count <= BridgeToolDescriptionRenderer.charBudget,
                   "budget breached: \(out.count)")
        try expect(out.hasSuffix("\u{2026}"), "truncation marker missing")
    }

    await test("title: derived from snake name, explicit metadata wins") {
        try expect(BridgeToolDescriptionRenderer.title(reg("notion_page_read", desc: "d")) == "Notion Page Read",
                   "derive failed: \(BridgeToolDescriptionRenderer.title(reg("notion_page_read", desc: "d")))")
        try expect(BridgeToolDescriptionRenderer.title(reg("x", desc: "d", meta: ToolMetadata(title: "Custom"))) == "Custom",
                   "explicit title ignored")
    }

    await test("factory: pure/deterministic (⇒ stdio == HTTP by construction)") {
        let r = reg("notion_page_read", desc: "Read a page.")
        try expect(MCPToolFactory.tool(for: r) == MCPToolFactory.tool(for: r),
                   "factory not deterministic — transports could diverge")
    }

    await test("factory over full registry: behavior-preserving + every tool titled") {
        let gate = SecurityGate(); let log = AuditLog()
        let router = ToolRouter(securityGate: gate, auditLog: log)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            registerSession: { await SessionModule.register(on: $0, auditLog: log) })
        let regs = await router.allRegistrations()
        try expect(regs.count == BridgeConstants.staticFeatureModuleToolCount,
                   "count drift \(regs.count) vs \(BridgeConstants.staticFeatureModuleToolCount)")
        for rg in regs {
            let t = MCPToolFactory.tool(for: rg)
            try expect(t.name == rg.name, "name mismatch \(t.name)")
            try expect(!(t.description ?? "").isEmpty, "empty description for \(rg.name)")
            try expect(!(t.annotations.title ?? "").isEmpty, "no title for \(rg.name)")
            // annotation hints unchanged vs catalog (only title is added)
            let cat = ToolAnnotationCatalog.resolved(for: rg.name).mcp
            try expect(t.annotations.readOnlyHint == cat.readOnlyHint
                       && t.annotations.destructiveHint == cat.destructiveHint
                       && t.annotations.openWorldHint == cat.openWorldHint,
                       "annotation hint drift for \(rg.name)")
        }
    }
}
