// WSHMenuBarTests.swift — WS-H (v2.3, PKT-804)
// Criteria-as-tests for the menu-bar quick-page deep-link contract.
// Visual placement (icon row present, Restart bottom-left / Quit bottom-right)
// is build-verified + structurally deterministic in DashboardView; the
// routing + navigation-state contracts are asserted here.

import Foundation
import NotionBridgeLib

func runWSHMenuBarTests() async {
    print("\n\u{1F9ED} WS-H Menu-Bar Quick-Page Tests (PKT-804)")

    await test("SettingsSection exposes the 3 deep-link targets") {
        let ids = Set(SettingsSection.allCases.map(\.rawValue))
        try expect(ids.contains("Skills"), "missing Skills section")
        try expect(ids.contains("Tools"), "missing Tools section")
        try expect(ids.contains("Connections"), "missing Connections (Settings home) section")
    }

    await test("Deep-link icons map to the expected SF Symbols") {
        try expect(SettingsSection.skills.icon == "book.closed", "skills icon: \(SettingsSection.skills.icon)")
        try expect(SettingsSection.tools.icon == "hammer", "tools icon: \(SettingsSection.tools.icon)")
        try expect(SettingsSection.connections.icon == "network", "connections icon: \(SettingsSection.connections.icon)")
    }

    await test("SettingsSection is Identifiable + CaseIterable + stable raw ids") {
        for s in SettingsSection.allCases {
            try expect(s.id == s.rawValue, "id != rawValue for \(s)")
        }
        // cmd-ux: + the new "Commands" section (8 total).
        try expect(SettingsSection.allCases.count == 8, "expected 8 sections, got \(SettingsSection.allCases.count)")
        try expect(SettingsSection.commands.icon == "command",
                   "commands icon: \(SettingsSection.commands.icon)")
        try expect(SettingsSection.commands.id == SettingsSection.commands.rawValue,
                   "commands id must equal rawValue")
    }

    await test("SettingsNavigation defaults to Connections (Settings home)") {
        let nav = await MainActor.run { SettingsNavigation() }
        let section = await MainActor.run { nav.section }
        try expect(section == .connections, "default section was \(section)")
    }

    await test("SettingsNavigation deep-link mutation holds (skills / tools)") {
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.section = .skills }
        let afterSkills = await MainActor.run { nav.section }
        try expect(afterSkills == .skills, "expected .skills, got \(afterSkills)")
        await MainActor.run { nav.section = .tools }
        let afterTools = await MainActor.run { nav.section }
        try expect(afterTools == .tools, "expected .tools, got \(afterTools)")
    }

    await test("Shared SettingsNavigation singleton is reachable") {
        let s = await MainActor.run { SettingsNavigation.shared.section }
        try expect(SettingsSection.allCases.contains(s), "shared.section not a valid case: \(s)")
    }
}
