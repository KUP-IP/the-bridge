// BridgeAutomationModuleTests.swift — FB-AUTOMATION (on-device automation kit)
// TheBridge · Tests
//
// Covers:
//   • BridgeSettingsAutomation.resolveSection — raw-value / case-name / alias
//     parsing, and rejection of unknown / ambiguous input.
//   • bridge_settings_navigate — registration, tier (.open), section validation,
//     happy-path (selection model updated even with no app host present).
//   • mouse_click axPath additions — the coordinate-free path no longer requires
//     x/y, and a bad axPath surfaces a clear error (capability_missing first when
//     AX is not granted, which is the CI default).
//
// All UI-touching assertions run on the main actor, matching WSHMenuBarTests.

import Foundation
import MCP
import TheBridgeLib

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
    }

    // PKT-1005 (Pillar A): the cold-open tool must be registered.
    await test("PKT-1005: BridgeAutomationModule registers bridge_open_settings") {
        let tools = await router.registrations(forModule: "automation")
        try expect(tools.contains { $0.name == "bridge_open_settings" }, "missing bridge_open_settings")
    }

    await test("PKT-1005: bridge_open_settings is .open tier") {
        let tools = await router.registrations(forModule: "automation")
        let t = tools.first { $0.name == "bridge_open_settings" }!
        try expect(t.tier == .open, "expected .open, got \(t.tier.rawValue)")
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

    await test("sectionDisplayNames are the friendly redesign labels") {
        // IA change 2026-06-12: the top page's label is "Commands" (the
        // standing-orders doctrine moved to Connection).
        // Data-Source Registry (2026-06-17): + "Data Sources".
        let names = await MainActor.run { BridgeSettingsAutomation.sectionDisplayNames }
        try expect(names == ["Commands", "Skills", "Jobs", "Tools",
                             "Security", "Connection", "Data Sources", "Memory", "Advanced"],
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

    // PKT-1005 (Pillar A): bridge_open_settings accepts an OPTIONAL section
    // (cold open at last-selected) and updates the selection model when one is
    // given. In the headless test process there is no AppDelegate-owned window
    // host, so `opened` is false and a `note` is surfaced — but the selection
    // model still moves, proving the deep-link wiring is correct.
    await test("PKT-1005: bridge_open_settings deep-links the selection model (headless: opened=false + note)") {
        await MainActor.run { SettingsNavigation.shared.go(.advanced) }
        let result = try await router.dispatch(
            toolName: "bridge_open_settings",
            arguments: .object(["section": .string("Skills")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        if case .string(let sec) = dict["section"] {
            try expect(sec == "Skills", "expected section 'Skills', got \(sec)")
        } else {
            throw TestError.assertion("response missing section")
        }
        // Headless: no window host → opened=false with an explanatory note.
        if case .bool(let opened) = dict["opened"] {
            try expect(opened == false, "headless test should report opened=false")
        } else {
            throw TestError.assertion("response missing opened bool")
        }
        try expect(dict["note"] != nil, "headless open should surface a note")
        let nav = await MainActor.run { SettingsNavigation.shared.section }
        try expect(nav == .skills, "selection model not deep-linked: \(nav)")
    }

    await test("PKT-1005: bridge_open_settings allows omitted section (open at last-selected)") {
        let result = try await router.dispatch(
            toolName: "bridge_open_settings",
            arguments: .object([:])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        // No section arg is valid (not invalid_input) — success key present.
        try expect(dict["success"] != nil, "omitted section should be accepted")
        try expect(dict["code"] == nil, "omitted section must NOT be an invalid_input error")
    }

    await test("PKT-1005: bridge_open_settings rejects an unknown section") {
        let result = try await router.dispatch(
            toolName: "bridge_open_settings",
            arguments: .object(["section": .string("does-not-exist")])
        )
        guard case .object(let dict) = result, case .string(let code) = dict["code"] else {
            throw TestError.assertion("expected invalid_input code for unknown section")
        }
        try expect(code == "invalid_input", "expected invalid_input, got \(code)")
    }

    // PKT-1005 (Pillar B): the host-detection fix. In the headless test process
    // no Settings NSWindow exists, so navigate() must report windowOpened=false
    // based on the ACTUAL absence of a Settings window — NOT crash, and NOT
    // claim a host when there is none. (On-device, with a window open, the same
    // codepath reports true; that arm is exercised in the on-device receipt.)
    await test("PKT-1005: navigate() host-detection is window-presence based (headless → false)") {
        let opened = await MainActor.run {
            BridgeSettingsAutomation.navigate(to: .security, anchor: nil)
        }
        try expect(opened == false, "headless: no Settings NSWindow → host-present must be false")
        // Selection model still updated regardless of host presence.
        let nav = await MainActor.run { SettingsNavigation.shared.section }
        try expect(nav == .security, "navigate() must update the selection model even with no host")
    }

    await test("PKT-1005: openSettings(section:) core returns opened=false headless but moves selection") {
        let outcome = await MainActor.run {
            BridgeSettingsAutomation.openSettings(section: .tools, anchor: "screen")
        }
        try expect(outcome.opened == false, "headless: no window host → opened=false")
        try expect(outcome.section == .tools, "outcome should echo the requested section")
        let nav = await MainActor.run { (SettingsNavigation.shared.section, SettingsNavigation.shared.anchor) }
        try expect(nav.0 == .tools, "selection section not set: \(nav.0)")
        try expect(nav.1 == "screen", "selection anchor not set: \(String(describing: nav.1))")
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
