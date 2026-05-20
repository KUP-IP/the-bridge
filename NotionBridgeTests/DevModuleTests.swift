// DevModuleTests.swift — Dev-suite audit (every-angle-of-attack)
// NotionBridge · Tests
//
// Sprint A · mcp-builder #8 removed `dev_module_info` — a scaffold
// placeholder whose own description said "Real dev primitives land in
// follow-up packets." The dev/ module is now populated with real tools
// (code_search, file_str_replace, file_apply_patch, lsp_*, playwright_run,
// vitest_run, lighthouse_run) registered by sibling modules under
// module="dev", so the discovery placeholder no longer serves a purpose.
// These tests now assert the removal (and that DevModule.register is a
// no-op that leaves the dev/ surface to its sibling modules).

import Foundation
import MCP
import NotionBridgeLib

func runDevModuleTests() async {
    print("\n\u{1F9F0} DevModule Tests (Sprint A · mcp-builder #8 — placeholder removed)")

    await test("DevModule.register no longer registers dev_module_info (Sprint A · #8)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        let names = Set((await router.registrations(forModule: "dev")).map { $0.name })
        try expect(!names.contains("dev_module_info"),
                   "dev_module_info should be removed by Sprint A · mcp-builder #8")
    }

    await test("dev_module_info has NO catalog entry (Sprint A · #8)") {
        try expect(ToolAnnotationCatalog.annotations(for: "dev_module_info") == nil,
                   "dev_module_info catalog entry should be removed alongside the registration")
    }

    await test("DevModule.moduleName is still 'dev' (sibling modules use it)") {
        try expect(DevModule.moduleName == "dev",
                   "DevModule.moduleName must stay 'dev' — PlaywrightModule / VitestModule / "
                   + "LighthouseModule / CodeEditModule / LspModule still pass it to ToolRegistration")
    }

    await test("Dispatching dev_module_info now throws unknownTool") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await DevModule.register(on: router)
        do {
            _ = try await router.dispatch(toolName: "dev_module_info", arguments: .object([:]))
            throw TestError.assertion("dev_module_info should no longer dispatch")
        } catch is ToolRouterError {
            // expected — unknownTool
        } catch let e as TestError {
            throw e
        }
    }
}
