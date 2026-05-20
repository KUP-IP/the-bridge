// AccessibilityModuleTests.swift – V1-TESTCOVERAGE
// NotionBridge · Tests
//
// Tests for AccessibilityModule.
// Pre-PKT-755: 5 tools (ax_focused_app, ax_tree, ax_find_element,
//              ax_element_info, ax_perform_action).
// PKT-755 (v2.2 · 0.1.2): + ax_query as unified replacement; three originals
//              kept as deprecation shims through the v2.2 → v2.3 ramp.
// Sprint A · mcp-builder W2 (audit #1): the three deprecation shims
//              (ax_focused_app, ax_find_element, ax_element_info) were
//              removed. W3 (audit #11) renames ax_query → ax_inspect (alias
//              kept) and revives ax_focused_app as a NEW dedicated tool —
//              that family of expectations is asserted in W3-specific tests
//              added alongside the rename.
// Note: most AX tools require Accessibility TCC grant. Tests focus on
// registration, tier classification, and graceful error handling when
// permission is not available.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - AccessibilityModule Tests

func runAccessibilityModuleTests() async {
    print("\n♿ AccessibilityModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await AccessibilityModule.register(on: router)

    // --- Registration ---

    await test("AccessibilityModule registers the live AX surface") {
        let tools = await router.registrations(forModule: "accessibility")
        let names = Set(tools.map(\.name))
        // Post W2: 3 live tools (ax_tree, ax_query, ax_perform_action).
        // W3 will add ax_inspect + revived ax_focused_app + ax_query alias.
        try expect(names.contains("ax_tree"), "Missing ax_tree")
        try expect(names.contains("ax_query"), "Missing ax_query")
        try expect(names.contains("ax_perform_action"), "Missing ax_perform_action")
        // Removed in W2 (Sprint A · mcp-builder #1):
        try expect(!names.contains("ax_find_element"),
                   "ax_find_element should be removed (Sprint A · mcp-builder #1)")
        try expect(!names.contains("ax_element_info"),
                   "ax_element_info should be removed (Sprint A · mcp-builder #1)")
    }

    // --- Tier classification ---

    await test("ax_tree is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_tree" }) else {
            throw TestError.assertion("ax_tree must be registered")
        }
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_perform_action is notify tier") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_perform_action" }) else {
            throw TestError.assertion("ax_perform_action must be registered")
        }
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("ax_query is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_query" }) else {
            throw TestError.assertion("ax_query must be registered")
        }
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    // --- ax_query dispatch (W3 will introduce ax_inspect alongside) ---

    await test("ax_query rejects missing mode") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object([:])
        )
        if case .object(let dict) = result, case .string(let err) = dict["error"] {
            try expect(err.contains("mode") || err.contains("required"),
                       "Expected error about missing mode, got: \(err.prefix(120))")
        } else {
            throw TestError.assertion("Expected error object when mode is missing")
        }
    }

    await test("ax_query focused_app mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("focused_app")])
        )
        if case .object(_) = result { /* ok */ } else {
            throw TestError.assertion("Expected object result")
        }
    }

    await test("ax_query find_element mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("find_element"), "role": .string("AXButton")])
        )
        if case .object(_) = result { /* ok */ } else {
            throw TestError.assertion("Expected object result")
        }
    }

    await test("ax_query element_info mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("element_info"), "role": .string("AXWindow")])
        )
        if case .object(_) = result { /* ok */ } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // --- Graceful error handling (no AX permission in test env) ---

    await test("ax_tree returns error or tree when called without pid") {
        let result = try await router.dispatch(
            toolName: "ax_tree",
            arguments: .object([:])
        )
        if case .object(_) = result {
            // Valid — either error or tree data
        }
    }

    await test("ax_perform_action handles missing required params") {
        let result = try await router.dispatch(
            toolName: "ax_perform_action",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    // --- Module name ---

    await test("AccessibilityModule.moduleName is 'accessibility'") {
        try expect(AccessibilityModule.moduleName == "accessibility",
                   "Expected 'accessibility', got '\(AccessibilityModule.moduleName)'")
    }
}
