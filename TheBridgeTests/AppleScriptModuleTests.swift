// AppleScriptModuleTests.swift – V1-TESTCOVERAGE
// TheBridge · Tests
//
// Tests for AppleScriptModule (1 tool: applescript_exec).
// NSAppleScript runs in-process — no TCC needed for basic scripts.

import Foundation
import MCP
import TheBridgeLib

// MARK: - AppleScriptModule Tests

func runAppleScriptModuleTests() async {
    print("\n🍎 AppleScriptModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await AppleScriptModule.register(on: router)

    // --- Registration ---

    await test("AppleScriptModule registers 1 tool") {
        let tools = await router.registrations(forModule: "applescript")
        try expect(tools.count == 1, "Expected 1 applescript tool, got \(tools.count)")
    }

    await test("applescript_exec is registered") {
        let tools = await router.registrations(forModule: "applescript")
        let names = Set(tools.map(\.name))
        try expect(names.contains("applescript_exec"), "Missing applescript_exec")
    }

    // --- Tier classification ---

    await test("applescript_exec is request tier") {
        let tools = await router.registrations(forModule: "applescript")
        let tool = tools.first(where: { $0.name == "applescript_exec" })!
        try expect(tool.tier == .request, "Expected request, got \(tool.tier.rawValue)")
    }

    // --- Functional tests ---

    await test("applescript_exec runs simple math") {
        let result = try await router.dispatch(
            toolName: "applescript_exec",
            arguments: .object(["script": .string("return 2 + 2")])
        )
        if case .object(let dict) = result,
           case .string(let output) = dict["result"] {
            try expect(output == "4", "Expected '4', got '\(output)'")
        } else {
            throw TestError.assertion("Expected object with result key")
        }
    }

    await test("applescript_exec runs string concatenation") {
        let result = try await router.dispatch(
            toolName: "applescript_exec",
            arguments: .object(["script": .string("return \"hello\" & \" \" & \"world\"")])
        )
        if case .object(let dict) = result,
           case .string(let output) = dict["result"] {
            try expect(output == "hello world", "Expected 'hello world', got '\(output)'")
        } else {
            throw TestError.assertion("Expected object with result key")
        }
    }

    await test("applescript_exec returns error for invalid script") {
        let result = try await router.dispatch(
            toolName: "applescript_exec",
            arguments: .object(["script": .string("this is not valid applescript $$$$")])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            } else if case .int(let errNum) = dict["errorNumber"] {
                try expect(errNum != 0, "Error number should be non-zero")
            }
        } else {
            throw TestError.assertion("Expected error object for invalid script")
        }
    }

    await test("applescript_exec rejects missing script param") {
        do {
            _ = try await router.dispatch(
                toolName: "applescript_exec",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing script")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // --- Module name ---

    await test("AppleScriptModule.moduleName is 'applescript'") {
        try expect(AppleScriptModule.moduleName == "applescript",
                   "Expected 'applescript', got '\(AppleScriptModule.moduleName)'")
    }
}
