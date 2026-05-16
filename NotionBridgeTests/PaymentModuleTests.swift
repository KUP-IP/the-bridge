// PaymentModuleTests.swift – PKT-381 PaymentModule Tests
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

private func unwrapTool(named name: String, from tools: [ToolRegistration]) throws -> ToolRegistration {
    guard let tool = tools.first(where: { $0.name == name }) else {
        throw TestError.assertion("Missing tool \(name)")
    }
    return tool
}

func runPaymentModuleTests() async {
    print("\n💳 PaymentModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await PaymentModule.register(on: router)

    await test("PaymentModule registers 1 tool") {
        let tools = await router.registrations(forModule: "payment")
        try expect(tools.count == 1, "Expected 1 payment tool, got \(tools.count)")
        try expect(tools.first?.name == "payment_execute", "Expected payment_execute tool")
    }

    await test("payment_execute tier is request") {
        let tools = await router.registrations(forModule: "payment")
        let tool = try unwrapTool(named: "payment_execute", from: tools)
        try expect(tool.tier == .request, "Expected request tier, got \(tool.tier.rawValue)")
    }

    await test("payment_execute has neverAutoApprove enabled") {
        let tools = await router.registrations(forModule: "payment")
        let tool = try unwrapTool(named: "payment_execute", from: tools)
        try expect(tool.neverAutoApprove, "Expected neverAutoApprove == true")
    }

    await test("payment_execute required schema fields are present") {
        let tools = await router.registrations(forModule: "payment")
        let tool = try unwrapTool(named: "payment_execute", from: tools)
        guard case .object(let schema) = tool.inputSchema,
              case .array(let required) = schema["required"] else {
            throw TestError.assertion("Expected object schema with required array")
        }
        let requiredNames = required.compactMap { value -> String? in
            if case .string(let name) = value { return name }
            return nil
        }
        // v3.0·0.5: keys renamed to camelCase (Q1); snake forms remain
        // accepted by the handler as legacy aliases (Q2).
        try expect(requiredNames.contains("credentialService"), "Missing required field: credentialService")
        try expect(requiredNames.contains("credentialAccount"), "Missing required field: credentialAccount")
        try expect(requiredNames.contains("amount"), "Missing required field: amount")
        try expect(requiredNames.contains("idempotencyKey"), "Missing required field: idempotencyKey")
    }

    await test("PaymentModule uses module name payment") {
        let tools = await router.registrations(forModule: "payment")
        for tool in tools {
            try expect(tool.module == "payment", "Expected module payment, got \(tool.module)")
        }
    }

    await test("PaymentModule default amount ceiling is 50000") {
        try expect(PaymentModule.amountCeiling == 50_000, "Expected amount ceiling 50000")
    }

    await test("payment_execute rejects missing required params") {
        do {
            _ = try await router.dispatch(
                toolName: "payment_execute",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        }
    }
}
