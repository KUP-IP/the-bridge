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

    await test("AccessibilityModule registers the post-Sprint-A AX surface") {
        let tools = await router.registrations(forModule: "accessibility")
        let names = Set(tools.map(\.name))
        // Post Sprint A: 5 live tools — ax_tree, ax_inspect (renamed
        // primary), ax_query (one-cycle alias of ax_inspect), revived
        // ax_focused_app (NEW dedicated tool — audit #11), ax_perform_action.
        try expect(names.contains("ax_tree"), "Missing ax_tree")
        try expect(names.contains("ax_inspect"), "Missing ax_inspect (Sprint A · #11 primary)")
        try expect(names.contains("ax_query"), "Missing ax_query (Sprint A · #11 alias)")
        try expect(names.contains("ax_focused_app"),
                   "Missing ax_focused_app (Sprint A · #11 revival)")
        try expect(names.contains("ax_perform_action"), "Missing ax_perform_action")
        // Removed in W2 (Sprint A · mcp-builder #1):
        try expect(!names.contains("ax_find_element"),
                   "ax_find_element should be removed (Sprint A · mcp-builder #1)")
        try expect(!names.contains("ax_element_info"),
                   "ax_element_info should be removed (Sprint A · mcp-builder #1)")
    }

    // Sprint A · mcp-builder #11 — ax_query → ax_inspect alias forwarding.

    await test("ax_query is a DEPRECATED alias of ax_inspect") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_query" }) else {
            throw TestError.assertion("ax_query alias must be registered (1-cycle)")
        }
        try expect(tool.description.hasPrefix("DEPRECATED"),
                   "ax_query must be marked DEPRECATED, got: \(tool.description.prefix(80))")
        try expect(tool.description.contains("ax_inspect"),
                   "ax_query description must point at ax_inspect")
    }

    await test("ax_inspect is open tier (Sprint A · #11 primary)") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_inspect" }) else {
            throw TestError.assertion("ax_inspect must be registered")
        }
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_focused_app is open tier (Sprint A · #11 revival, 0-arg)") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_focused_app" }) else {
            throw TestError.assertion("ax_focused_app must be registered (revived)")
        }
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_focused_app description does NOT mark DEPRECATED (revived)") {
        let tools = await router.registrations(forModule: "accessibility")
        guard let tool = tools.first(where: { $0.name == "ax_focused_app" }) else {
            throw TestError.assertion("ax_focused_app must be registered (revived)")
        }
        try expect(!tool.description.contains("DEPRECATED"),
                   "Revived ax_focused_app must NOT be marked deprecated")
    }

    await test("ax_query and ax_inspect have identical dispatch (alias forwarding)") {
        let viaAlias = try await router.dispatch(toolName: "ax_query",
                                                  arguments: .object(["mode": .string("focused_app")]))
        let viaPrimary = try await router.dispatch(toolName: "ax_inspect",
                                                    arguments: .object(["mode": .string("focused_app")]))
        if case .object(let a) = viaAlias, case .object(let b) = viaPrimary {
            // Both routes share the same handler; on the same call they
            // must produce the same key-set (modulo timing-flake which is
            // irrelevant — focusedAppPayload is deterministic per process).
            if case .string(let ae) = a["error"], case .string(let be) = b["error"] {
                try expect(ae == be, "alias error parity mismatch: \(ae) vs \(be)")
            } else {
                try expect(Set(a.keys) == Set(b.keys),
                           "alias key-set parity mismatch: \(Set(a.keys)) vs \(Set(b.keys))")
            }
        } else {
            throw TestError.assertion("Both routes must return object responses")
        }
    }

    await test("ax_focused_app (revived) returns same shape as ax_inspect(focused_app)") {
        let direct = try await router.dispatch(toolName: "ax_focused_app", arguments: .object([:]))
        let viaInspect = try await router.dispatch(toolName: "ax_inspect",
                                                    arguments: .object(["mode": .string("focused_app")]))
        if case .object(let a) = direct, case .object(let b) = viaInspect {
            if case .string(let ae) = a["error"], case .string(let be) = b["error"] {
                try expect(ae == be, "focused_app helper error parity: \(ae) vs \(be)")
            } else {
                try expect(Set(a.keys) == Set(b.keys),
                           "focused_app helper key-set parity: \(Set(a.keys)) vs \(Set(b.keys))")
            }
        } else {
            throw TestError.assertion("Both routes must return object responses")
        }
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
