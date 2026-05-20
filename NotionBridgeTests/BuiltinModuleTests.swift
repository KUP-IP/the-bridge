// BuiltinModuleTests.swift – V1-TESTCOVERAGE
// NotionBridge · Tests
//
// Sprint A · mcp-builder #8 removed the production `echo` tool from
// ServerManager (session_info covers connectivity health). These tests
// register a LOCAL echo replica into a private router to exercise the
// pure registration/dispatch plumbing of ToolRouter — the historical name
// is retained for git history continuity but it no longer asserts
// anything about the production tool surface.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - BuiltinModule Tests (echo)

func runBuiltinModuleTests() async {
    print("\n🔧 BuiltinModule Tests (echo)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)

    // Register echo exactly as ServerManager does
    await router.register(ToolRegistration(
        name: "echo",
        module: "builtin",
        tier: .open,
        description: "Echoes back the input message. Useful for connectivity testing.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "message": .object([
                    "type": .string("string"),
                    "description": .string("The message to echo back")
                ])
            ]),
            "required": .array([.string("message")])
        ]),
        handler: { arguments in
            guard case .object(let args) = arguments,
                  case .string(let message) = args["message"] else {
                return .object(["error": .string("Missing 'message' parameter")])
            }
            return .object(["echo": .string(message)])
        }
    ))

    // --- Registration ---

    await test("Echo tool is registered in builtin module") {
        let tools = await router.registrations(forModule: "builtin")
        try expect(tools.count == 1, "Expected 1 builtin tool, got \(tools.count)")
        try expect(tools[0].name == "echo", "Expected 'echo', got '\(tools[0].name)'")
    }

    // --- Tier classification ---

    await test("echo is open tier") {
        let tools = await router.registrations(forModule: "builtin")
        let tool = tools.first(where: { $0.name == "echo" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    // --- Functional tests ---

    await test("echo returns input message") {
        let result = try await router.dispatch(
            toolName: "echo",
            arguments: .object(["message": .string("hello from test")])
        )
        if case .object(let dict) = result,
           case .string(let echoed) = dict["echo"] {
            try expect(echoed == "hello from test",
                       "Expected 'hello from test', got '\(echoed)'")
        } else {
            throw TestError.assertion("Expected object with echo key")
        }
    }

    await test("echo handles empty message") {
        let result = try await router.dispatch(
            toolName: "echo",
            arguments: .object(["message": .string("")])
        )
        if case .object(let dict) = result,
           case .string(let echoed) = dict["echo"] {
            try expect(echoed == "", "Expected empty string, got '\(echoed)'")
        } else {
            throw TestError.assertion("Expected object with echo key")
        }
    }

    await test("echo handles special characters") {
        let special = "Hello, 世界! 🌉"
        let result = try await router.dispatch(
            toolName: "echo",
            arguments: .object(["message": .string(special)])
        )
        if case .object(let dict) = result,
           case .string(let echoed) = dict["echo"] {
            try expect(echoed == special, "Special characters should be preserved")
        } else {
            throw TestError.assertion("Expected object with echo key")
        }
    }

    await test("echo returns error for missing message") {
        let result = try await router.dispatch(
            toolName: "echo",
            arguments: .object([:])
        )
        if case .object(let dict) = result,
           case .string(let err) = dict["error"] {
            try expect(err.contains("message"), "Error should mention 'message' param")
        } else {
            throw TestError.assertion("Expected error object for missing message")
        }
    }
}
