// MouseClickModuleTests.swift — PKT-765 (v2.2 · 3.3.1)
// TheBridge · Tests
//
// CGEvent mouse posting requires AX grant. Tests focus on registration, tier,
// input validation, and graceful capability_missing surfacing. Live
// AX-incompatible-app validation (e.g. Adobe-class) belongs to QA.

import Foundation
import MCP
import TheBridgeLib

func runMouseClickModuleTests() async {
    print("\n\u{1F5B1}\u{FE0F} MouseClickModule Tests")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await MouseClickModule.register(on: router)

    await test("MouseClickModule registers mouse_click") {
        let tools = await router.registrations(forModule: "computer")
        try expect(tools.contains(where: { $0.name == "mouse_click" }),
                   "Missing mouse_click")
    }

    await test("MouseClickModule.moduleName is 'computer'") {
        try expect(MouseClickModule.moduleName == "computer",
                   "Expected 'computer', got '\(MouseClickModule.moduleName)'")
    }

    await test("mouse_click is notify tier") {
        let tools = await router.registrations(forModule: "computer")
        let tool = tools.first(where: { $0.name == "mouse_click" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("mouse_click rejects missing x") {
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object(["y": .double(100)])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error for missing x")
        }
        try expect(err.lowercased().contains("x"), "Expected x-required error: \(err)")
    }

    await test("mouse_click rejects missing y") {
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object(["x": .double(100)])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error for missing y")
        }
        try expect(err.lowercased().contains("y"), "Expected y-required error: \(err)")
    }

    await test("mouse_click rejects unknown button name") {
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object([
                "x": .double(100),
                "y": .double(100),
                "button": .string("scrollUp")
            ])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("Expected error code for invalid button")
        }
        try expect(code == "invalid_input", "Expected invalid_input, got \(code)")
    }

    await test("mouse_click returns capability_missing or success on valid input") {
        // Far-corner coords to avoid disturbing on-screen UI if AX is granted.
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object([
                "x": .double(0),
                "y": .double(0)
            ])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        if case .string(let code) = dict["code"] {
            try expect(
                code == "capability_missing" || code == "event_create_failed",
                "Unexpected error code: \(code)"
            )
            if code == "capability_missing" {
                try expect(dict["settingsHint"] != nil,
                           "capability_missing must surface settingsHint")
            }
        } else if case .bool(let success) = dict["success"] {
            try expect(success == true, "success path should be true")
        } else {
            throw TestError.assertion("Response missing both code and success: \(dict.keys)")
        }
    }
}
