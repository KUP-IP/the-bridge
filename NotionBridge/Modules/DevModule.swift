// DevModule.swift — Developer / NotionBridge dev primitives MCP tools
// NotionBridge · Modules
//
// History:
//   PKT-738 (v2.2 · 0.1) — Initial scaffold. Foundation packet for v2.2 dev primitives.
//                          Surfaces module in `notion_modules_list` for dependent packets.
//
// Status: SCAFFOLD. Real dev tooling (code-edit, cursor/, computer/ helpers) lands in follow-up packets.
//
// Tier assignments:
//   dev_module_info → .open (read-only metadata)

import Foundation
import MCP

public enum DevModule {
    public static let moduleName = "dev"

    // MARK: - Registration

    // Sprint A · mcp-builder #8: dev_module_info removed. It was a
    // self-described scaffold placeholder ("Real dev tooling lands in
    // follow-up packets"); the dev/ module is now populated with real
    // primitives (code_search, file_str_replace/apply_patch, lsp_*,
    // playwright_run, vitest_run, lighthouse_run) so the discovery
    // placeholder serves no purpose. Audit §3 marked this for silent
    // removal — no deprecation alias needed.
    public static func register(on router: ToolRouter) async {
        // No-op: the dev/ module surface is composed entirely of tools
        // registered by sibling modules (PlaywrightModule, VitestModule,
        // LighthouseModule, CodeEditModule, LspModule) that pass
        // `module: "dev"` to ToolRegistration. This explicit empty
        // register(on:) call is retained for symmetry with other module
        // entry points and for forward-compat with future scaffold tools.
        _ = router
    }
}
