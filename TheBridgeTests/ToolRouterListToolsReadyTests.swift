// ToolRouterListToolsReadyTests.swift — FB-4 registration gate
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

func runToolRouterListToolsReadyTests() async {
    print("\n\u{1F6A6} ToolRouter ListTools registration gate (FB-4)")

    await test("registrationsForListTools is empty until markModulesRegistrationComplete") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await BridgeAutomationModule.register(on: router)
        let before = await router.registrationsForListTools(disabledNames: [])
        try expect(before.isEmpty, "expected empty list before registration complete")
        try expect(await router.isModulesRegistrationComplete() == false, "flag should be false")
        await router.markModulesRegistrationComplete()
        let after = await router.registrationsForListTools(disabledNames: [])
        try expect(after.count == 3, "expected 3 automation tools after registration complete, got \(after.count)")
        try expect(await router.isModulesRegistrationComplete(), "flag should be true")
    }

    await test("enabledRegistrations is unchanged by registration gate (dispatch still works)") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await BridgeAutomationModule.register(on: router)
        let regs = await router.enabledRegistrations(disabledNames: [])
        try expect(regs.count == 3, "dispatch registry should still expose automation tools")
    }
}
