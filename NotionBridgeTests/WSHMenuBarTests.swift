// WSHMenuBarTests.swift — WS-H (v2.3, PKT-804)
// Criteria-as-tests for the menu-bar quick-page deep-link contract.
// Visual placement (icon row present, Restart bottom-left / Quit bottom-right)
// is build-verified + structurally deterministic in DashboardView; the
// routing + navigation-state contracts are asserted here.

import Foundation
import NotionBridgeLib

func runWSHMenuBarTests() async {
    print("\n\u{1F9ED} WS-H Menu-Bar Quick-Page Tests (PKT-804)")

    await test("SettingsSection exposes the redesign deep-link targets") {
        let ids = Set(SettingsSection.allCases.map(\.rawValue))
        // Settings Redesign PKT-A: 7-section sidebar in conceptual-flow order.
        // rawValue stays the STABLE deep-link id (orders keeps "Standing
        // Orders"); the display label is decoupled (`displayName`).
        try expect(ids.contains("Standing Orders"), "missing Orders section (rawValue 'Standing Orders')")
        try expect(ids.contains("Skills"), "Skills must exist as its own top-level section")
        try expect(ids.contains("Tools"), "missing Tools section")
        try expect(ids.contains("Security"), "missing Security section (Credentials + Permissions merged)")
        try expect(ids.contains("Connection"), "missing Connection section (Connections + Remote Access merged)")
    }

    await test("Display names are the snappy redesign labels (decoupled from rawValue)") {
        // IA change 2026-06-12: the page is "Commands" (doctrine moved to
        // Connection); the rawValue stays the stable legacy "Standing Orders" id.
        try expect(SettingsSection.orders.displayName == "Commands",
                   "orders display: \(SettingsSection.orders.displayName)")
        try expect(SettingsSection.orders.rawValue == "Standing Orders",
                   "orders rawValue must stay the stable legacy id")
        try expect(SettingsSection.security.displayName == "Security")
        try expect(SettingsSection.connection.displayName == "Connection")
    }

    await test("Deep-link icons map to the expected SF Symbols") {
        // PKT-A keeps SF Symbols this pass for the surviving + merged cases.
        try expect(SettingsSection.tools.icon == "hammer", "tools icon: \(SettingsSection.tools.icon)")
        try expect(SettingsSection.connection.icon == "network", "connection icon: \(SettingsSection.connection.icon)")
        try expect(SettingsSection.orders.icon == "command", "orders icon: \(SettingsSection.orders.icon)")
        try expect(SettingsSection.skills.icon == "sparkles", "skills icon: \(SettingsSection.skills.icon)")
        try expect(SettingsSection.security.icon == "lock.shield", "security icon: \(SettingsSection.security.icon)")
        try expect(SettingsSection.jobs.icon == "clock.badge.checkmark", "jobs icon: \(SettingsSection.jobs.icon)")
        try expect(SettingsSection.advanced.icon == "wrench.and.screwdriver", "advanced icon: \(SettingsSection.advanced.icon)")
    }

    await test("SettingsSection is Identifiable + CaseIterable + stable raw ids") {
        for s in SettingsSection.allCases {
            try expect(s.id == s.rawValue, "id != rawValue for \(s)")
        }
        // PKT-A: 7 sections (Orders + Skills + Jobs + Tools + Security +
        // Connection + Advanced). Commands folds into Orders;
        // Credentials+Permissions→Security; Connections+Remote Access→Connection.
        try expect(SettingsSection.allCases.count == 7, "expected 7 sections, got \(SettingsSection.allCases.count)")
        try expect(SettingsSection.tools.icon == "hammer",
                   "tools icon: \(SettingsSection.tools.icon)")
        try expect(SettingsSection.tools.id == SettingsSection.tools.rawValue,
                   "tools id must equal rawValue")
    }

    await test("SettingsSection sidebar order is the conceptual flow") {
        // PKT-A: order is Orders → Skills → Jobs → Tools → Security →
        // Connection → Advanced (conceptual flow: who the agent is → what it
        // knows → what runs → what it can do → what's gated/stored → how
        // agents reach it → everything else). rawValues carry the stable ids.
        let order = SettingsSection.allCases.map(\.rawValue)
        let expected = ["Standing Orders", "Skills", "Jobs", "Tools",
                        "Security", "Connection", "Advanced"]
        try expect(order == expected, "sidebar order drifted: \(order)")
        let labels = SettingsSection.allCases.map(\.displayName)
        let expectedLabels = ["Commands", "Skills", "Jobs", "Tools",
                              "Security", "Connection", "Advanced"]
        try expect(labels == expectedLabels, "display-label order drifted: \(labels)")
    }

    await test("SettingsNavigation defaults to Orders (sidebar top)") {
        let nav = await MainActor.run { SettingsNavigation() }
        let section = await MainActor.run { nav.section }
        try expect(section == .orders, "default section was \(section)")
    }

    await test("SettingsNavigation.go deep-link sets section + anchor") {
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.go(.security, anchor: "notion") }
        let (sec, anch) = await MainActor.run { (nav.section, nav.anchor) }
        try expect(sec == .security, "expected .security, got \(sec)")
        try expect(anch == "notion", "expected anchor 'notion', got \(String(describing: anch))")
    }

    await test("SettingsNavigation deep-link mutation holds (orders / tools)") {
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.section = .orders }
        let afterOrders = await MainActor.run { nav.section }
        try expect(afterOrders == .orders, "expected .orders, got \(afterOrders)")
        await MainActor.run { nav.section = .tools }
        let afterTools = await MainActor.run { nav.section }
        try expect(afterTools == .tools, "expected .tools, got \(afterTools)")
    }

    await test("Shared SettingsNavigation singleton is reachable") {
        let s = await MainActor.run { SettingsNavigation.shared.section }
        try expect(SettingsSection.allCases.contains(s), "shared.section not a valid case: \(s)")
    }
}
