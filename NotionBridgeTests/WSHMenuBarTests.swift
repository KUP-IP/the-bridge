// WSHMenuBarTests.swift — WS-H (v2.3, PKT-804)
// Criteria-as-tests for the menu-bar quick-page deep-link contract.
// Visual placement (icon row present, Restart bottom-left / Quit bottom-right)
// is build-verified + structurally deterministic in DashboardView; the
// routing + navigation-state contracts are asserted here.

import Foundation
import NotionBridgeLib

func runWSHMenuBarTests() async {
    print("\n\u{1F9ED} WS-H Menu-Bar Quick-Page Tests (PKT-804)")

    await test("SettingsSection exposes the v3.5 deep-link targets") {
        let ids = Set(SettingsSection.allCases.map(\.rawValue))
        // PKT-3 v3.5: 9-section sidebar with Standing Orders pinned top
        // and Skills promoted to its own section.
        try expect(ids.contains("Standing Orders"), "missing Standing Orders section")
        try expect(ids.contains("Commands"), "missing Commands section")
        try expect(ids.contains("Skills"), "Skills must exist as its own top-level section")
        try expect(ids.contains("Tools"), "missing Tools section")
        try expect(ids.contains("Connections"), "missing Connections section")
    }

    await test("Deep-link icons map to the expected SF Symbols") {
        try expect(SettingsSection.commands.icon == "command", "commands icon: \(SettingsSection.commands.icon)")
        try expect(SettingsSection.tools.icon == "hammer", "tools icon: \(SettingsSection.tools.icon)")
        try expect(SettingsSection.connections.icon == "network", "connections icon: \(SettingsSection.connections.icon)")
        try expect(SettingsSection.standingOrders.icon == "scroll", "standingOrders icon: \(SettingsSection.standingOrders.icon)")
        try expect(SettingsSection.skills.icon == "sparkles", "skills icon: \(SettingsSection.skills.icon)")
    }

    await test("SettingsSection is Identifiable + CaseIterable + stable raw ids") {
        for s in SettingsSection.allCases {
            try expect(s.id == s.rawValue, "id != rawValue for \(s)")
        }
        // PKT-3 v3.5: 9 sections (Standing Orders + Commands + Connections +
        // Skills + Permissions + Credentials + Tools + Jobs + Advanced).
        // WS-E (Mac-side cloud access): +Remote Access (after Connections) → 10.
        try expect(SettingsSection.allCases.count == 10, "expected 10 sections, got \(SettingsSection.allCases.count)")
        try expect(SettingsSection.commands.icon == "command",
                   "commands icon: \(SettingsSection.commands.icon)")
        try expect(SettingsSection.commands.id == SettingsSection.commands.rawValue,
                   "commands id must equal rawValue")
    }

    await test("SettingsSection sidebar order opens to most-visited (Standing Orders)") {
        // PKT-3 v3.5: order is Standing Orders → Commands → Connections →
        // Skills → Permissions → Credentials → Tools → Jobs → Advanced.
        // WS-E: Remote Access inserted directly after Connections (its
        // natural sibling — both are "how this Mac is reachable").
        let order = SettingsSection.allCases.map(\.rawValue)
        let expected = ["Standing Orders", "Commands", "Connections", "Remote Access",
                        "Skills", "Permissions", "Credentials", "Tools", "Jobs", "Advanced"]
        try expect(order == expected, "sidebar order drifted: \(order)")
    }

    await test("SettingsNavigation defaults to Standing Orders (sidebar top)") {
        let nav = await MainActor.run { SettingsNavigation() }
        let section = await MainActor.run { nav.section }
        try expect(section == .standingOrders, "default section was \(section)")
    }

    await test("SettingsNavigation.go deep-link sets section + anchor") {
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.go(.credentials, anchor: "notion") }
        let (sec, anch) = await MainActor.run { (nav.section, nav.anchor) }
        try expect(sec == .credentials, "expected .credentials, got \(sec)")
        try expect(anch == "notion", "expected anchor 'notion', got \(String(describing: anch))")
    }

    await test("SettingsNavigation deep-link mutation holds (commands / tools)") {
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.section = .commands }
        let afterCommands = await MainActor.run { nav.section }
        try expect(afterCommands == .commands, "expected .commands, got \(afterCommands)")
        await MainActor.run { nav.section = .tools }
        let afterTools = await MainActor.run { nav.section }
        try expect(afterTools == .tools, "expected .tools, got \(afterTools)")
    }

    await test("Shared SettingsNavigation singleton is reachable") {
        let s = await MainActor.run { SettingsNavigation.shared.section }
        try expect(SettingsSection.allCases.contains(s), "shared.section not a valid case: \(s)")
    }
}
