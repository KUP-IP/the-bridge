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

    public static func register(on router: ToolRouter) async {
        await router.register(makeDevModuleInfo())
    }

    // MARK: - Tool factories

    /// Placeholder scaffold tool — confirms the dev/ module is wired and discoverable.
    /// Replaced/extended by real dev primitives in v2.2 follow-up packets.
    private static func makeDevModuleInfo() -> ToolRegistration {
        ToolRegistration(
            name: "dev_module_info",
            module: moduleName,
            tier: .open,
            description: "Return metadata about the dev/ module scaffold (PKT-738, v2.2). Placeholder — real dev primitives land in v2.2 follow-up packets.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { _ in
                .object([
                    "module": .string(moduleName),
                    "status": .string("scaffold"),
                    "introduced": .string("v2.2 · PKT-738"),
                    "purpose": .string("Foundation for v2.2 dev primitives (code-edit, cursor/, computer/ helpers)."),
                    "version": .string(AppVersion.marketing)
                ])
            }
        )
    }
}
