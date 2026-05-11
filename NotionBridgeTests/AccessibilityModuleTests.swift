// AccessibilityModuleTests.swift – V1-TESTCOVERAGE
// NotionBridge · Tests
//
// Tests for AccessibilityModule.
// Pre-PKT-755: 5 tools (ax_focused_app, ax_tree, ax_find_element,
//              ax_element_info, ax_perform_action).
// Post-PKT-755 (v2.2 · 0.1.2): 6 tools — ax_query is added; the three
//              collapsed query tools remain as deprecation shims through
//              the v2.3 ramp.
// Note: most AX tools require Accessibility TCC grant. Tests focus on
// registration, tier classification, deprecation markers, payload-parity
// integration spot-checks, and graceful error handling when permission
// is not available.

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

    await test("AccessibilityModule registers 6 tools (PKT-755: +ax_query)") {
        let tools = await router.registrations(forModule: "accessibility")
        try expect(tools.count == 6, "Expected 6 accessibility tools, got \(tools.count)")
    }

    await test("AccessibilityModule tool names are correct") {
        let tools = await router.registrations(forModule: "accessibility")
        let names = Set(tools.map(\.name))
        try expect(names.contains("ax_focused_app"), "Missing ax_focused_app")
        try expect(names.contains("ax_tree"), "Missing ax_tree")
        try expect(names.contains("ax_find_element"), "Missing ax_find_element")
        try expect(names.contains("ax_element_info"), "Missing ax_element_info")
        try expect(names.contains("ax_perform_action"), "Missing ax_perform_action")
        try expect(names.contains("ax_query"), "Missing ax_query")
    }

    // --- Tier classification ---

    await test("ax_focused_app is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_focused_app" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_tree is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_tree" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_find_element is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_find_element" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_element_info is open tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_element_info" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("ax_perform_action is notify tier") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_perform_action" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("ax_query is open tier (PKT-755)") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_query" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    // --- PKT-755: deprecated tool descriptions carry the [DEPRECATED ...] prefix ---

    await test("ax_focused_app description carries DEPRECATED v2.2 PKT-755 prefix") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_focused_app" })!
        try expect(tool.description.contains("[DEPRECATED v2.2 · PKT-755"),
                   "Expected DEPRECATED prefix, got: \(tool.description.prefix(80))")
        try expect(tool.description.contains("ax_query"),
                   "Description should reference ax_query, got: \(tool.description.prefix(120))")
    }

    await test("ax_find_element description carries DEPRECATED v2.2 PKT-755 prefix") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_find_element" })!
        try expect(tool.description.contains("[DEPRECATED v2.2 · PKT-755"),
                   "Expected DEPRECATED prefix, got: \(tool.description.prefix(80))")
        try expect(tool.description.contains("ax_query"),
                   "Description should reference ax_query, got: \(tool.description.prefix(120))")
    }

    await test("ax_element_info description carries DEPRECATED v2.2 PKT-755 prefix") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_element_info" })!
        try expect(tool.description.contains("[DEPRECATED v2.2 · PKT-755"),
                   "Expected DEPRECATED prefix, got: \(tool.description.prefix(80))")
        try expect(tool.description.contains("ax_query"),
                   "Description should reference ax_query, got: \(tool.description.prefix(120))")
    }

    await test("ax_query description does NOT carry DEPRECATED prefix") {
        let tools = await router.registrations(forModule: "accessibility")
        let tool = tools.first(where: { $0.name == "ax_query" })!
        try expect(!tool.description.contains("[DEPRECATED"),
                   "ax_query is the replacement and must not be marked deprecated")
    }

    await test("ax_tree and ax_perform_action descriptions are NOT deprecated") {
        let tools = await router.registrations(forModule: "accessibility")
        let tree = tools.first(where: { $0.name == "ax_tree" })!
        let perform = tools.first(where: { $0.name == "ax_perform_action" })!
        try expect(!tree.description.contains("[DEPRECATED"), "ax_tree must not be deprecated")
        try expect(!perform.description.contains("[DEPRECATED"), "ax_perform_action must not be deprecated")
    }

    // --- Graceful error handling (no AX permission in test env) ---

    await test("ax_focused_app returns success or a structured error") {
        let result = try await router.dispatch(
            toolName: "ax_focused_app",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                // notTrusted, noFocusedApp, or other AXModuleError paths (headless/CI varies)
                try expect(
                    err.contains("Accessibility") || err.contains("permission") || err.contains("trusted")
                        || err.contains("No focused application") || err.contains("not found"),
                    "Error should be a known AX-module user message, got: \(err.prefix(120))"
                )
            } else {
                try expect(dict["name"] != nil && dict["bundleId"] != nil,
                           "Success path should include name and bundleId")
            }
        }
    }

    await test("ax_tree returns error or tree when called without pid") {
        let result = try await router.dispatch(
            toolName: "ax_tree",
            arguments: .object([:])
        )
        if case .object(_) = result {
            // Valid — either error or tree data
        }
    }

    await test("ax_find_element handles missing search criteria") {
        let result = try await router.dispatch(
            toolName: "ax_find_element",
            arguments: .object([:])
        )
        if case .object(_) = result {
            // Graceful response
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

    // --- PKT-755: ax_query mode dispatch ---

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

    await test("ax_query rejects unknown mode") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("nonsense")])
        )
        if case .object(let dict) = result, case .string(let err) = dict["error"] {
            try expect(err.contains("Unknown mode") || err.contains("Expected"),
                       "Expected unknown-mode error, got: \(err.prefix(120))")
        } else {
            throw TestError.assertion("Expected error object on unknown mode")
        }
    }

    await test("ax_query focused_app mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("focused_app")])
        )
        if case .object(_) = result {
            // ok — either success or AXModuleError-shaped response
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    await test("ax_query find_element mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("find_element"), "role": .string("AXButton")])
        )
        if case .object(_) = result { } else {
            throw TestError.assertion("Expected object result")
        }
    }

    await test("ax_query element_info mode dispatches") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("element_info"), "role": .string("AXWindow")])
        )
        if case .object(_) = result { } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // --- PKT-755: deprecation warning marker on shim responses ---

    await test("ax_focused_app shim emits _deprecated warning (PKT-755)") {
        let result = try await router.dispatch(
            toolName: "ax_focused_app",
            arguments: .object([:])
        )
        if case .object(let dict) = result, case .string(let warn) = dict["_deprecated"] {
            try expect(warn.contains("PKT-755") && warn.contains("ax_query"),
                       "Expected deprecation warning citing PKT-755 + ax_query, got: \(warn.prefix(160))")
        } else {
            throw TestError.assertion("Missing _deprecated warning on ax_focused_app shim")
        }
    }

    await test("ax_find_element shim emits _deprecated warning (PKT-755)") {
        let result = try await router.dispatch(
            toolName: "ax_find_element",
            arguments: .object(["role": .string("AXButton")])
        )
        if case .object(let dict) = result, case .string(let warn) = dict["_deprecated"] {
            try expect(warn.contains("PKT-755") && warn.contains("ax_query"),
                       "Expected deprecation warning, got: \(warn.prefix(160))")
        } else {
            throw TestError.assertion("Missing _deprecated warning on ax_find_element shim")
        }
    }

    await test("ax_element_info shim emits _deprecated warning (PKT-755)") {
        let result = try await router.dispatch(
            toolName: "ax_element_info",
            arguments: .object(["role": .string("AXWindow")])
        )
        if case .object(let dict) = result, case .string(let warn) = dict["_deprecated"] {
            try expect(warn.contains("PKT-755") && warn.contains("ax_query"),
                       "Expected deprecation warning, got: \(warn.prefix(160))")
        } else {
            throw TestError.assertion("Missing _deprecated warning on ax_element_info shim")
        }
    }

    await test("ax_query payload does NOT include _deprecated marker") {
        let result = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("focused_app")])
        )
        if case .object(let dict) = result {
            try expect(dict["_deprecated"] == nil,
                       "ax_query is the replacement and must not emit _deprecated marker")
        }
    }

    // --- PKT-755 DoD: integration spot-check —
    //     each shim returns the same payload as the corresponding ax_query
    //     direct call, modulo the injected `_deprecated` marker.
    //     Comparison strategy: extract the `error` key (TCC-denied / headless
    //     test env) or both success-key sets, and assert equality.

    func errorText(_ v: Value) -> String? {
        if case .object(let d) = v, case .string(let e) = d["error"] { return e }
        return nil
    }

    func keySet(_ v: Value) -> Set<String> {
        if case .object(let d) = v {
            return Set(d.keys.filter { $0 != "_deprecated" })
        }
        return []
    }

    await test("PKT-755 parity: ax_focused_app shim matches ax_query(focused_app)") {
        let shim = try await router.dispatch(toolName: "ax_focused_app", arguments: .object([:]))
        let direct = try await router.dispatch(toolName: "ax_query", arguments: .object(["mode": .string("focused_app")]))
        if let se = errorText(shim), let de = errorText(direct) {
            try expect(se == de, "Error text parity failed: shim=\(se) direct=\(de)")
        } else {
            try expect(keySet(shim) == keySet(direct),
                       "Key-set parity failed: shim=\(keySet(shim)) direct=\(keySet(direct))")
        }
    }

    await test("PKT-755 parity: ax_find_element shim matches ax_query(find_element)") {
        let args: Value = .object(["role": .string("AXButton")])
        let shim = try await router.dispatch(toolName: "ax_find_element", arguments: args)
        let direct = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("find_element"), "role": .string("AXButton")])
        )
        if let se = errorText(shim), let de = errorText(direct) {
            try expect(se == de, "Error text parity failed: shim=\(se) direct=\(de)")
        } else {
            try expect(keySet(shim) == keySet(direct),
                       "Key-set parity failed: shim=\(keySet(shim)) direct=\(keySet(direct))")
        }
    }

    await test("PKT-755 parity: ax_element_info shim matches ax_query(element_info)") {
        let args: Value = .object(["role": .string("AXWindow")])
        let shim = try await router.dispatch(toolName: "ax_element_info", arguments: args)
        let direct = try await router.dispatch(
            toolName: "ax_query",
            arguments: .object(["mode": .string("element_info"), "role": .string("AXWindow")])
        )
        if let se = errorText(shim), let de = errorText(direct) {
            try expect(se == de, "Error text parity failed: shim=\(se) direct=\(de)")
        } else {
            try expect(keySet(shim) == keySet(direct),
                       "Key-set parity failed: shim=\(keySet(shim)) direct=\(keySet(direct))")
        }
    }

    // --- Module name ---

    await test("AccessibilityModule.moduleName is 'accessibility'") {
        try expect(AccessibilityModule.moduleName == "accessibility",
                   "Expected 'accessibility', got '\(AccessibilityModule.moduleName)'")
    }
}
