// AccessibilityModuleTests.swift – V1-TESTCOVERAGE
// TheBridge · Tests
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
import TheBridgeLib

// MARK: - AccessibilityModule Tests

func runAccessibilityModuleTests() async {
    print("\n♿ AccessibilityModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await AccessibilityModule.register(on: router)

    // --- Registration ---

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

    // --- axcrash: bounded-traversal helper (TraversalBudget) ---
    //
    // These pin the contract that makes a deep/large/slow AX tree non-fatal:
    // the budget must clamp depth to a hard ceiling, stop at the depth limit,
    // stop at the node cap, stop at the wall-clock deadline, and honor
    // cooperative cancellation — independently of any live AX tree. The
    // companion threading fix (every AX read on @MainActor) is structurally
    // enforced by the compiler, so the budget logic is the unit-testable core.

    await test("TraversalBudget clamps requested depth to the hard ceiling") {
        try await MainActor.run {
            let b = AccessibilityModule.TraversalBudget(
                requestedDepth: AccessibilityModule.TraversalLimits.maxDepthCeiling + 5_000)
            try expect(b.maxDepth == AccessibilityModule.TraversalLimits.maxDepthCeiling,
                       "Expected clamp to \(AccessibilityModule.TraversalLimits.maxDepthCeiling), got \(b.maxDepth)")
        }
    }

    await test("TraversalBudget clamps negative requested depth to zero") {
        try await MainActor.run {
            let b = AccessibilityModule.TraversalBudget(requestedDepth: -10)
            try expect(b.maxDepth == 0, "Negative depth must clamp to 0, got \(b.maxDepth)")
            // At depth 0 it must refuse to descend (single-node read only).
            try expect(b.canDescend(currentDepth: 0) == false,
                       "depth-0 budget must not descend")
            try expect(b.truncation == .depth,
                       "Stopping at the depth limit must record .depth")
        }
    }

    await test("TraversalBudget stops descent at the depth limit") {
        try await MainActor.run {
            let b = AccessibilityModule.TraversalBudget(requestedDepth: 3)
            try expect(b.canDescend(currentDepth: 0), "should descend at depth 0")
            try expect(b.canDescend(currentDepth: 2), "should descend at depth 2 (< 3)")
            try expect(b.canDescend(currentDepth: 3) == false, "must stop at depth 3 (== maxDepth)")
            try expect(b.truncation == .depth, "depth stop must set .depth reason")
        }
    }

    await test("TraversalBudget stops at the node-count cap") {
        try await MainActor.run {
            // Tiny node cap so we can exhaust it deterministically.
            let b = AccessibilityModule.TraversalBudget(requestedDepth: 100, maxNodes: 3)
            try expect(b.admit(), "1st admit within cap")
            try expect(b.admit(), "2nd admit within cap")
            try expect(b.admit(), "3rd admit within cap")
            try expect(b.admit() == false, "4th admit must be refused (cap == 3)")
            try expect(b.truncation == .nodeCount, "node-cap stop must set .node_count reason")
            try expect(b.visited == 3, "visited must not exceed the cap, got \(b.visited)")
            // canDescend must also report the exhausted node budget.
            try expect(b.canDescend(currentDepth: 0) == false,
                       "exhausted node budget must block descent")
        }
    }

    await test("TraversalBudget stops at the wall-clock deadline") {
        try await MainActor.run {
            // Construct with a deadline already in the past via timeBudget=0.
            let base = Date()
            let b = AccessibilityModule.TraversalBudget(
                requestedDepth: 100, timeBudget: 0, now: base)
            // Evaluate "now" one second after the (zero-budget) deadline.
            let later = base.addingTimeInterval(1)
            try expect(b.canDescend(currentDepth: 0, now: later) == false,
                       "expired time budget must block descent")
            try expect(b.truncation == .time, "time stop must set .time reason")
        }
    }

    await test("TraversalBudget honors cooperative cancellation") {
        // Run the canDescend check inside an already-cancelled Task so
        // Task.isCancelled is true on the main actor.
        let reason: AccessibilityModule.TruncationReason? = await {
            let t = Task { @MainActor () -> AccessibilityModule.TruncationReason? in
                // Spin until this task observes its own cancellation.
                while !Task.isCancelled { await Task.yield() }
                let b = AccessibilityModule.TraversalBudget(requestedDepth: 100)
                _ = b.canDescend(currentDepth: 0)
                return b.truncation
            }
            t.cancel()
            return await t.value
        }()
        try expect(reason == .cancelled, "cancellation must set .cancelled reason, got \(String(describing: reason))")
    }

    await test("TraversalBudget within all limits does not mark truncation") {
        try await MainActor.run {
            let b = AccessibilityModule.TraversalBudget(requestedDepth: 5, maxNodes: 100)
            try expect(b.admit(), "root admit")
            try expect(b.canDescend(currentDepth: 0), "should descend at depth 0")
            try expect(b.canDescend(currentDepth: 4), "should descend at depth 4 (< 5)")
            try expect(b.truncation == nil, "no limit hit must leave truncation == nil")
        }
    }

    // --- PKT-1005 remainder (a): identifier is queryable in serialized output ---
    //
    // ax_tree (elementDict) and ax_inspect mode=find_element (findElementPayload)
    // both route through serializedElementAttributes. Before PKT-1005 those two
    // serializers emitted role/title/description/geometry but NOT the AX
    // identifier (kAXIdentifierAttribute) — so a live ax_tree / ax_inspect read
    // could only match on volatile labels, never on a stable BridgeAXID. These
    // tests pin that the shared serializer now ALWAYS emits `identifier` when
    // present and OMITS it when absent, without needing a live AX tree / TCC.

    await test("PKT-1005(a): serialized element emits identifier when present") {
        let d = AccessibilityModule.serializedElementAttributes(
            role: "AXButton", path: "/AXApplication:The Bridge/AXButton:Skills",
            title: "Skills", description: nil,
            identifier: "bridge.settings.nav.skills",
            position: nil, size: nil)
        guard case .string(let id)? = d["identifier"] else {
            throw TestError.assertion("serialized element must carry an 'identifier' key")
        }
        try expect(id == "bridge.settings.nav.skills",
                   "identifier must round-trip the BridgeAXID, got \(id)")
    }

    await test("PKT-1005(a): serialized element OMITS identifier when absent") {
        let d = AccessibilityModule.serializedElementAttributes(
            role: "AXGroup", path: "/AXApplication:The Bridge/AXGroup",
            title: nil, description: nil, identifier: nil,
            position: nil, size: nil)
        try expect(d["identifier"] == nil,
                   "an element with no AX identifier must not emit an 'identifier' key")
        // Sanity: role is still always present.
        guard case .string(let r)? = d["role"] else {
            throw TestError.assertion("role must always be present")
        }
        try expect(r == "AXGroup", "role must round-trip, got \(r)")
    }

    await test("PKT-1005(a): identifier survives alongside the full attribute set") {
        // Mirrors a real instrumented control: role + title + geometry + id.
        let d = AccessibilityModule.serializedElementAttributes(
            role: "AXCheckBox", path: "/AXApplication:The Bridge/AXCheckBox:Enabled",
            title: "Enabled", description: "toggle",
            identifier: "bridge.settings.skills.toggle.enabled",
            position: (x: 12, y: 34), size: (w: 56, h: 20))
        guard case .string(let id)? = d["identifier"] else {
            throw TestError.assertion("identifier must coexist with the rest of the attributes")
        }
        try expect(id == "bridge.settings.skills.toggle.enabled", "got \(id)")
        // The id must not clobber the other serialized fields.
        try expect(d["title"] != nil && d["width"] != nil && d["path"] != nil,
                   "identifier emission must be additive, not destructive")
    }
}
