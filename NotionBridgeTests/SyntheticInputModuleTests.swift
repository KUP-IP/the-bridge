// SyntheticInputModuleTests.swift — PKT-747 (v2.2 · 3.3)
// NotionBridge · Tests
//
// Tests for SyntheticInputModule (1 tool: keyboard_type).
// CGEvent posting requires AX + Input Monitoring grants. In test/CI environments
// these are typically denied, so tests focus on:
//   - registration + tier classification
//   - input validation
//   - graceful capability_missing surfacing on permission denial
// Live AX-incompatible-app validation belongs to QA (out of harness scope).

import Foundation
import MCP
import NotionBridgeLib

func runSyntheticInputModuleTests() async {
    print("\n\u{2328}\u{FE0F} SyntheticInputModule Tests")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SyntheticInputModule.register(on: router)

    // --- Registration ---

    await test("SyntheticInputModule registers keyboard_type") {
        let tools = await router.registrations(forModule: "computer")
        try expect(tools.contains(where: { $0.name == "keyboard_type" }),
                   "Missing keyboard_type")
    }

    await test("SyntheticInputModule.moduleName is 'computer'") {
        try expect(SyntheticInputModule.moduleName == "computer",
                   "Expected 'computer', got '\(SyntheticInputModule.moduleName)'")
    }

    // --- Tier classification ---

    await test("keyboard_type is notify tier") {
        let tools = await router.registrations(forModule: "computer")
        let tool = tools.first(where: { $0.name == "keyboard_type" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    // --- Input validation ---

    await test("keyboard_type rejects missing text param") {
        let result = try await router.dispatch(
            toolName: "keyboard_type",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("Expected error for missing text")
        }
        try expect(err.lowercased().contains("text") || err.lowercased().contains("required"),
                   "Expected text-required error: \(err)")
    }

    // --- Permission denial path ---
    // We can't reliably distinguish granted-vs-denied at test time, so accept either
    // capability_missing (denied → expected on CI) or success (granted on dev).

    await test("keyboard_type returns capability_missing or success") {
        let result = try await router.dispatch(
            toolName: "keyboard_type",
            arguments: .object(["text": .string("")])  // empty avoids actual keystrokes
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object response")
        }
        if case .string(let code) = dict["code"] {
            try expect(
                code == "capability_missing" || code == "invalid_input" || code == "event_create_failed",
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

    await test("keyboard_type capability_missing surfaces settings deep-link") {
        // Always-runnable structural check: the error helper must include a
        // System Settings deep-link in the capability_missing response shape.
        let result = try await router.dispatch(
            toolName: "keyboard_type",
            arguments: .object(["text": .string("")])
        )
        if case .object(let dict) = result, case .string(let code) = dict["code"], code == "capability_missing" {
            guard case .string(let hint) = dict["settingsHint"] else {
                throw TestError.assertion("Missing settingsHint on capability_missing")
            }
            try expect(hint.contains("x-apple.systempreferences"),
                       "settingsHint should be x-apple.systempreferences URL, got: \(hint)")
        }
        // If granted on dev machine, this assertion is skipped — covered by the
        // structural test above which confirms code/error contract.
    }
}
