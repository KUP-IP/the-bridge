// BridgeAutomationModuleTests.swift — FB-AUTOMATION (on-device automation kit)
// NotionBridge · Tests
//
// Covers:
//   • BridgeSettingsAutomation.resolveSection — raw-value / case-name / alias
//     parsing, and rejection of unknown / ambiguous input.
//   • bridge_settings_navigate — registration, tier (.open), section validation,
//     happy-path (selection model updated even with no app host present).
//   • bridge_focus_settings — registration, tier (.notify), no-app-host outcome.
//   • mouse_click axPath additions — the coordinate-free path no longer requires
//     x/y, and a bad axPath surfaces a clear error (capability_missing first when
//     AX is not granted, which is the CI default).
//
// All UI-touching assertions run on the main actor, matching WSHMenuBarTests.

import Foundation
import MCP
import NotionBridgeLib

func runBridgeAutomationModuleTests() async {
    print("\n\u{1F9F0} BridgeAutomationModule Tests (FB-AUTOMATION)")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await BridgeAutomationModule.register(on: router)
    await MouseClickModule.register(on: router)

    // MARK: - Registration + tiers

    await test("BridgeAutomationModule registers both Settings tools") {
        let tools = await router.registrations(forModule: "automation")
        try expect(tools.contains { $0.name == "bridge_settings_navigate" }, "missing bridge_settings_navigate")
        try expect(tools.contains { $0.name == "bridge_focus_settings" }, "missing bridge_focus_settings")
    }

    await test("BridgeAutomationModule.moduleName is 'automation'") {
        try expect(BridgeAutomationModule.moduleName == "automation",
                   "expected 'automation', got '\(BridgeAutomationModule.moduleName)'")
    }

    await test("bridge_settings_navigate is .open tier (read-only nav)") {
        let tools = await router.registrations(forModule: "automation")
        let t = tools.first { $0.name == "bridge_settings_navigate" }!
        try expect(t.tier == .open, "expected .open, got \(t.tier.rawValue)")
    }

    await test("bridge_focus_settings is .notify tier") {
        let tools = await router.registrations(forModule: "automation")
        let t = tools.first { $0.name == "bridge_focus_settings" }!
        try expect(t.tier == .notify, "expected .notify, got \(t.tier.rawValue)")
    }

    // MARK: - Section resolution

    await test("resolveSection accepts the human raw value") {
        let s = await MainActor.run { BridgeSettingsAutomation.resolveSection("Standing Orders") }
        try expect(s == .orders, "expected .orders, got \(String(describing: s))")
    }

    await test("resolveSection accepts the enum case name + display name (case-insensitive)") {
        let s1 = await MainActor.run { BridgeSettingsAutomation.resolveSection("orders") }
        try expect(s1 == .orders, "case-name parse failed: \(String(describing: s1))")
        let s2 = await MainActor.run { BridgeSettingsAutomation.resolveSection("SECURITY") }
        try expect(s2 == .security, "uppercase parse failed: \(String(describing: s2))")
        let s3 = await MainActor.run { BridgeSettingsAutomation.resolveSection("Connection") }
        try expect(s3 == .connection, "display-name parse failed: \(String(describing: s3))")
    }

    await test("resolveSection accepts common shorthands") {
        let perm = await MainActor.run { BridgeSettingsAutomation.resolveSection("privacy") }
        try expect(perm == .security, "privacy→security failed: \(String(describing: perm))")
        let cred = await MainActor.run { BridgeSettingsAutomation.resolveSection("vault") }
        try expect(cred == .security, "vault→security failed: \(String(describing: cred))")
    }

    await test("resolveSection rejects unknown / empty input") {
        let bad = await MainActor.run { BridgeSettingsAutomation.resolveSection("nonsense") }
        try expect(bad == nil, "expected nil for unknown section, got \(String(describing: bad))")
        let empty = await MainActor.run { BridgeSettingsAutomation.resolveSection("   ") }
        try expect(empty == nil, "expected nil for empty section")
    }

    // V2: the FIVE retired pre-redesign section names MUST keep resolving to
    // their merged home + the tab anchor, so external automations driving
    // bridge_settings_navigate don't silently break (market safety).
    await test("resolveSection keeps back-compat aliases for the 5 retired sections") {
        let cases: [(String, SettingsSection, String?)] = [
            ("Credentials",   .security,   "vault"),
            ("Permissions",   .security,   "gates"),
            ("Remote Access", .connection, "remote"),
            ("Connections",   .connection, "local"),
            ("Commands",      .orders,     "commands"),
        ]
        for (name, expectedSection, expectedAnchor) in cases {
            let resolved = await MainActor.run {
                BridgeSettingsAutomation.resolveSectionWithAnchor(name)
            }
            try expect(resolved?.section == expectedSection,
                       "legacy '\(name)' must resolve to \(expectedSection), got \(String(describing: resolved?.section))")
            try expect(resolved?.anchor == expectedAnchor,
                       "legacy '\(name)' must anchor '\(String(describing: expectedAnchor))', got \(String(describing: resolved?.anchor))")
            // The plain resolver still returns the section (no anchor).
            let plain = await MainActor.run { BridgeSettingsAutomation.resolveSection(name) }
            try expect(plain == expectedSection,
                       "plain resolveSection('\(name)') must still resolve to \(expectedSection)")
        }
    }

    await test("sectionRawValues covers all SettingsSection cases") {
        let raws = await MainActor.run { BridgeSettingsAutomation.sectionRawValues }
        let cases = SettingsSection.allCases.map(\.rawValue)
        try expect(Set(raws) == Set(cases), "sectionRawValues drifted from SettingsSection")
    }

    await test("sectionDisplayNames are the 7 friendly redesign labels") {
        let names = await MainActor.run { BridgeSettingsAutomation.sectionDisplayNames }
        try expect(names == ["Orders", "Skills", "Jobs", "Tools",
                             "Security", "Connection", "Advanced"],
                   "sectionDisplayNames drift: \(names)")
    }

    // MARK: - bridge_settings_navigate behaviour

    await test("bridge_settings_navigate rejects missing section") {
        let result = try await router.dispatch(
            toolName: "bridge_settings_navigate",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("expected invalid_input code for missing section")
        }
        try expect(code == "invalid_input", "expected invalid_input, got \(code)")
        try expect(dict["validSections"] != nil, "error should list validSections")
    }

    await test("bridge_settings_navigate rejects unknown section") {
        let result = try await router.dispatch(
            toolName: "bridge_settings_navigate",
            arguments: .object(["section": .string("does-not-exist")])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("expected invalid_input code for unknown section")
        }
        try expect(code == "invalid_input", "expected invalid_input, got \(code)")
    }

    await test("bridge_settings_navigate updates the shared selection model") {
        // Seed a different section so we can prove the call mutated it.
        await MainActor.run { SettingsNavigation.shared.go(.advanced) }
        let result = try await router.dispatch(
            toolName: "bridge_settings_navigate",
            arguments: .object(["section": .string("Tools"), "anchor": .string("screen")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        try expect(dict["success"] != nil, "missing success key")
        if case .string(let sec) = dict["section"] {
            try expect(sec == "Tools", "expected section 'Tools', got \(sec)")
        } else {
            throw TestError.assertion("response missing section")
        }
        let nav = await MainActor.run { (SettingsNavigation.shared.section, SettingsNavigation.shared.anchor) }
        try expect(nav.0 == .tools, "selection model section not updated: \(nav.0)")
        try expect(nav.1 == "screen", "selection model anchor not updated: \(String(describing: nav.1))")
    }

    // MARK: - bridge_focus_settings behaviour

    await test("bridge_focus_settings returns a structured outcome") {
        // No AppDelegate host in the test harness → windowFound is false but the
        // tool must still return a non-throwing structured success envelope.
        let result = try await router.dispatch(
            toolName: "bridge_focus_settings",
            arguments: .object(["openIfNeeded": .bool(false)])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        try expect(dict["success"] != nil, "missing success key")
        try expect(dict["windowFound"] != nil, "missing windowFound key")
        try expect(dict["activated"] != nil, "missing activated key")
    }

    // MARK: - mouse_click axPath additions (coordinate-space fix)

    await test("mouse_click no longer requires x/y when axPath is provided") {
        // With AX ungranted (CI default) this returns capability_missing, NOT an
        // invalid_input about a missing x/y — proving axPath bypasses the x/y
        // requirement. If AX IS granted, a bogus path yields ax_element_not_found.
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object(["axPath": .string("/AXApplication:Nope/AXWindow:Nope")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        if case .string(let code) = dict["code"] {
            try expect(
                code == "capability_missing" || code == "ax_element_not_found",
                "unexpected code for axPath click: \(code)"
            )
        } else if case .bool(let ok) = dict["success"] {
            // Extremely unlikely (path is bogus) but not a failure of THIS test.
            try expect(ok == true, "success path should be true")
        } else {
            throw TestError.assertion("response missing code and success: \(dict.keys)")
        }
    }

    await test("mouse_click still requires x when neither axPath nor x provided") {
        let result = try await router.dispatch(
            toolName: "mouse_click",
            arguments: .object(["y": .double(10)])
        )
        guard case .object(let dict) = result, case .string(let err) = dict["error"] else {
            throw TestError.assertion("expected error for missing x without axPath")
        }
        try expect(err.lowercased().contains("x"), "expected x-required error: \(err)")
    }
}
