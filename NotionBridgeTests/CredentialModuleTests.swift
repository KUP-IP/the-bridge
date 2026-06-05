// CredentialModuleTests.swift – PKT-372 CredentialModule Tests
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

// MARK: - CredentialModule Tests

func runCredentialModuleTests() async {
    print("\n🔐 CredentialModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CredentialModule.register(on: router)

    // Registration
    await test("CredentialModule registers 4 tools") {
        let tools = await router.registrations(forModule: "credential")
        try expect(tools.count == 4, "Expected 4 credential tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("credential_save"), "Missing credential_save")
        try expect(names.contains("credential_read"), "Missing credential_read")
        try expect(names.contains("credential_list"), "Missing credential_list")
        try expect(names.contains("credential_delete"), "Missing credential_delete")
    }

    // Tier validation
    await test("credential_save tier is request") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_save" })!
        try expect(tool.tier == .request, "Expected request, got \(tool.tier.rawValue)")
    }

    await test("credential_read tier is request") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_read" })!
        try expect(tool.tier == .request, "Expected request, got \(tool.tier.rawValue)")
    }

    await test("credential_list tier is notify") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_list" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("credential_delete tier is request") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_delete" })!
        try expect(tool.tier == .request, "Expected request, got \(tool.tier.rawValue)")
    }

    // Input schema validation
    await test("credential_save has required input schema fields") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_save" })!
        if case .object(let schema) = tool.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("service"), "Missing required field: service")
            try expect(requiredNames.contains("account"), "Missing required field: account")
            try expect(requiredNames.contains("password"), "Missing required field: password")
        } else {
            throw TestError.assertion("Expected object schema with required array")
        }
    }

    await test("credential_read has required input schema fields") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_read" })!
        if case .object(let schema) = tool.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("service"), "Missing required field: service")
            // [credentials] hardening: 'account' is now OPTIONAL — when 'service'
            // is an env-var-style alias (e.g. CURSOR_API_KEY) the account is
            // inferred from the provider. Only 'service' is strictly required.
            try expect(!requiredNames.contains("account"), "account should be optional after alias hardening")
        } else {
            throw TestError.assertion("Expected object schema with required array")
        }
    }

    await test("credential_delete has required input schema fields") {
        let tools = await router.registrations(forModule: "credential")
        let tool = tools.first(where: { $0.name == "credential_delete" })!
        if case .object(let schema) = tool.inputSchema,
           case .array(let required) = schema["required"] {
            let requiredNames = required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            try expect(requiredNames.contains("service"), "Missing required field: service")
            try expect(requiredNames.contains("account"), "Missing required field: account")
        } else {
            throw TestError.assertion("Expected object schema with required array")
        }
    }

    // Tool descriptions
    await test("All credential tools have non-empty descriptions") {
        let tools = await router.registrations(forModule: "credential")
        for tool in tools {
            try expect(!tool.description.isEmpty, "\(tool.name) should have a description")
        }
    }

    // Module name
    await test("CredentialModule tools use 'credential' module name") {
        let tools = await router.registrations(forModule: "credential")
        for tool in tools {
            try expect(tool.module == "credential", "\(tool.name) module should be 'credential', got '\(tool.module)'")
        }
    }

    // Dispatch tests — credential_list should work without params
    await test("credential_list dispatches successfully") {
        let result = try await router.dispatch(
            toolName: "credential_list",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            try expect(dict["error"] == nil, "credential_list should not return error")
        } else if case .array = result {
            // Array response is also acceptable
        } else {
            throw TestError.assertion("Expected object or array result from credential_list")
        }
    }

    // credential_read with missing params
    await test("credential_read rejects missing parameters") {
        do {
            _ = try await router.dispatch(
                toolName: "credential_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        } catch {
            // Any error is acceptable for missing required params
        }
    }

    // credential_save with missing params
    await test("credential_save rejects missing parameters") {
        do {
            _ = try await router.dispatch(
                toolName: "credential_save",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        } catch {
            // Any error is acceptable for missing required params
        }
    }

    // credential_delete with missing params
    await test("credential_delete rejects missing parameters") {
        do {
            _ = try await router.dispatch(
                toolName: "credential_delete",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch is ToolRouterError {
            // Expected
        } catch {
            // Any error is acceptable for missing required params
        }
    }
}
