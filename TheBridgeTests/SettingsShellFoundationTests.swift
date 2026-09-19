// SettingsShellFoundationTests.swift — #283 / parent #282
// TheBridge · Tests
//
// HEADLESS contract for the Settings-shell design-system foundation:
//   • carbon weave is a shell texture only (never under content panes)
//   • content cards are hairline OR a single soft shadow (no bevel / dual)
//   • sidebar icon rail ↔ labeled rail widths
//   • collapsed chrome fits the standard window without a sidebar scroll
//   • product names elsewhere stay put (npass / Notion / MCP / Sparkle)
//
// Evidence: Source-level structural tests. No Installed / Released claim.

import Foundation
import SwiftUI
import TheBridgeLib

func runSettingsShellFoundationTests() async {
    print("\n\u{1F3D7} Settings Shell Foundation Tests (#283)")

    await test("#283: collapsed sidebar is an icon rail, expanded is labeled") {
        try expect(SettingsShellLayout.sidebarWidth(expanded: false) == 52,
                   "collapsed width \(SettingsShellLayout.sidebarWidth(expanded: false))")
        try expect(SettingsShellLayout.sidebarWidth(expanded: true) == 188,
                   "expanded width \(SettingsShellLayout.sidebarWidth(expanded: true))")
        try expect(SettingsShellLayout.sidebarWidth(expanded: true)
                    - SettingsShellLayout.sidebarWidth(expanded: false)
                    == BridgeTokens.Space.sidebarExpandDelta,
                   "expand delta must match Space.sidebarExpandDelta")
    }

    await test("#283: standard window is collapsed size; expand may grow width") {
        let collapsed = SettingsShellLayout.contentSize(sidebarExpanded: false)
        let expanded = SettingsShellLayout.contentSize(sidebarExpanded: true)
        try expect(collapsed.width == 1080 && collapsed.height == 880,
                   "collapsed window \(collapsed)")
        try expect(expanded.width == 1080 + 136 && expanded.height == 880,
                   "expanded window \(expanded) — height must not grow")
        try expect(expanded.width > collapsed.width, "expand grows width")
    }

    await test("#283: collapsed sidebar chrome fits standard window with zero scroll") {
        try expect(SettingsShellLayout.collapsedFitsWithoutScroll,
                   "sidebar column \(SettingsShellLayout.collapsedSidebarColumnHeight) + chrome \(SettingsShellLayout.chromeBandHeight) must fit in \(BridgeTokens.Space.settingsWindowH)")
        try expect(!SettingsSection.allCases.isEmpty, "sidebar must list sections")
        // No ScrollView in the rail: row count × navItemH stays under pane height.
        let paneH = BridgeTokens.Space.settingsWindowH - SettingsShellLayout.chromeBandHeight
        try expect(SettingsShellLayout.collapsedSidebarColumnHeight <= paneH,
                   "rail \(SettingsShellLayout.collapsedSidebarColumnHeight) > pane \(paneH)")
    }

    await test("#283: weave placement contract forbids content-pane hatch") {
        try expect(BridgeTokens.Weave.placement == .outerShell)
        try expect(BridgeTokens.Weave.placement != .contentPane)
        try expect(BridgeTokens.Weave.Placement.contentPane.rawValue == "contentPane",
                   "forbidden case must remain so later slices cannot silently move weave")
    }

    await test("#283: ContentCard depth is one cue (hairline or single shadow)") {
        try expect(BridgeTokens.ContentCard.shadowLayerCount == 1)
        try expect(BridgeContentCard<EmptyView>.Depth.hairline.rawValue == "hairline")
        try expect(BridgeContentCard<EmptyView>.Depth.softShadow.rawValue == "softShadow")
        try expect(BridgeTokens.ContentCard.softShadow.y == 2,
                   "single soft shadow y \(BridgeTokens.ContentCard.softShadow.y)")
    }

    await test("#283: sidebar persist key + default is collapsed") {
        try expect(BridgeDefaults.settingsSidebarExpanded
                    == "com.notionbridge.settings.sidebarExpanded")
        let suiteName = "bridge.tests.settings.shell.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        try expect(suite.object(forKey: BridgeDefaults.settingsSidebarExpanded) == nil,
                   "fresh defaults must not seed the sidebar key")
        try expect(suite.bool(forKey: BridgeDefaults.settingsSidebarExpanded) == false,
                   "absent key reads as false — icon rail / standard window")
    }

    await test("#283: SettingsSection product labels are unchanged") {
        // Slice must not rename product surfaces reserved by the epic.
        let labels = SettingsSection.allCases.map(\.displayName)
        try expect(labels.contains("Commands"))
        try expect(labels.contains("Skills"))
        try expect(labels.contains("Jobs"))
        try expect(labels.contains("Tools"))
        try expect(labels.contains("Data Sources"))
        try expect(!labels.contains(where: { $0.localizedCaseInsensitiveContains("npass") }),
                   "do not rename npass into the sidebar")
        try expect(!labels.contains("Vault"), "vault migration is a later slice")
    }

    await test("#283: chrome AX ids stay label-independent") {
        let toggle = await MainActor.run { BridgeAXID.sidebarToggle }
        let pane = await MainActor.run { BridgeAXID.contentPane }
        try expect(toggle.hasPrefix("bridge.settings.chrome."))
        try expect(pane.hasPrefix("bridge.settings.chrome."))
        let manifest = SettingsUIValidationHarness.expectedIdentifiers
        for section in SettingsSection.allCases {
            let ids = manifest[section] ?? []
            try expect(ids.contains(toggle), "\(section) missing sidebar toggle id")
            try expect(ids.contains(pane), "\(section) missing content pane id")
        }
    }
}
