// CGEventModuleTests.swift — PKT-765 (v2.2 · 3.3.1)
// NotionBridge · Tests
//
// CGEvent posting requires AX grant. Tests focus on registration, tier,
// input validation, and graceful capability_missing surfacing.

import Foundation
import MCP
import NotionBridgeLib

func runCGEventModuleTests() async {
    print("\n\u{1F39B}\u{FE0F} CGEventModule Tests")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CGEventModule.register(on: router)

    await test("CGEventModule registers cgevent_send") {
        let tools = await router.registrations(forModule: "computer")
        try expect(tools.contains(where: { $0.name == "cgevent_send" }),
                   "Missing cgevent_send")
    }

    await test("CGEventModule.moduleName is 'computer'") {
        try expect(CGEventModule.moduleName == "computer",
                   "Expected 'computer', got '\(CGEventModule.moduleName)'")
    }

    await test("cgevent_send is notify tier") {
        let tools = await router.registrations(forModule: "computer")
        let tool = tools.first(where: { $0.name == "cgevent_send" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("cgevent_send rejects missing type") {
        let result = try await router.dispatch(
            toolName: "cgevent_send",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error for missing type")
        }
        try expect(err.lowercased().contains("type"),
                   "Expected type-required error: \(err)")
    }

    await test("cgevent_send rejects unknown event type") {
        let result = try await router.dispatch(
            toolName: "cgevent_send",
            arguments: .object(["type": .string("hover")])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("Expected code on error response")
        }
        // invalid_input when AX is trusted; capability_missing when not.
        try expect(
            code == "invalid_input" || code == "capability_missing",
            "Unexpected code: \(code)"
        )
    }

    await test("cgevent_send key_press requires keyCode") {
        let result = try await router.dispatch(
            toolName: "cgevent_send",
            arguments: .object(["type": .string("key_press")])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("Expected code on error response")
        }
        try expect(
            code == "invalid_input" || code == "capability_missing",
            "Unexpected code: \(code)"
        )
    }

    await test("cgevent_send returns capability_missing or success on scroll(0,0)") {
        let result = try await router.dispatch(
            toolName: "cgevent_send",
            arguments: .object([
                "type":         .string("scroll"),
                "scrollDeltaX": .int(0),
                "scrollDeltaY": .int(0)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        if case .string(let code) = dict["code"] {
            try expect(
                code == "capability_missing" || code == "event_create_failed",
                "Unexpected code: \(code)"
            )
            if code == "capability_missing" {
                try expect(dict["settingsHint"] != nil,
                           "settingsHint missing on capability_missing")
            }
        } else if case .bool(let success) = dict["success"] {
            try expect(success == true, "success path should be true")
        } else {
            throw TestError.assertion("Response missing both code and success")
        }
    }
}
