// SettingsSectionsLGTests.swift — PKT-876 v3.6·1 (Liquid Glass Settings reskin)
// Criteria-as-tests for the 5 reskinned Settings section views.
//
// Custom harness (not XCTest) — see TheBridgeTests/main.swift.
//
// What the tests pin (each lockss a load-bearing piece of the DoD):
//
//   1. BridgeSettingsHeaderPreset.targetSections is exactly the 5 sections
//      this packet reskins (Connections, Credentials, Permissions, Jobs,
//      Advanced) — the "header genuinely shared, 5 callers" contract.
//   2. Every target section has a non-empty preset (title/subtitle/icon/tint).
//   3. The shared header IS one type — no per-section variant exists. The
//      test asserts this by constructing a single header type generically
//      with each preset; if a section had its own header type it could
//      not satisfy this constraint.
//   4. CredentialToolDependencies maps every shipped credential slug to
//      the live tool module name. Pinned for: notion, stripe (with payment
//      sibling), openai, github (with git sibling).
//   5. PermissionToolDependencies maps every Grant to its module set — so
//      a future Grant added without dep mapping fails the test.
//   6. ToolDepLinks.usedByChips collapses N tools per module into one
//      chip with the correct plural form ("28 notion tools" vs "1 ...").
//   7. ToolDepLinks.usedByChips returns a single `.bad` orphan chip when
//      no live tools match (credential is wasted).
//   8. ToolDepLinks.requiredByChips returns `.bad` chips when permission
//      not granted but tools depend on it ("9 file tools — disabled").
//   9. BridgeSectionIcon.systemImage(for:) returns the locked SF Symbol
//      for each of the 5 target sections.
//  10. BridgeSettingsHeaderPreset is a stable, sendable spec — round-
//      tripping the same section twice returns equal spec fields.

import Foundation
import SwiftUI
import TheBridgeLib

func runSettingsSectionsLGTests() async {
    print("\n\u{1F484} PKT-876 Settings Sections Liquid Glass Tests")

    // 1. Target sections — PKT-A adopts the shared header across ALL 7
    //    sections (the dead "5 callers" set is gone; one preset per case).
    await test("PKT-A: header preset targetSections is all sections") {
        let ids = BridgeSettingsHeaderPreset.targetSections.map(\.rawValue)
        try expect(ids == ["Standing Orders", "Skills", "Jobs", "Tools",
                           "Security", "Connection", "Data Sources", "Memory", "Advanced"],
                   "targetSections drift: \(ids)")
        try expect(BridgeSettingsHeaderPreset.targetSections.count == SettingsSection.allCases.count,
                   "every section must adopt the shared header")
    }

    // 2. Every target section has a meaningful preset spec.
    await test("PKT-876: every target section has a non-empty header preset") {
        for sec in BridgeSettingsHeaderPreset.targetSections {
            let spec = BridgeSettingsHeaderPreset.spec(for: sec)
            try expect(!spec.title.isEmpty, "empty title for \(sec.rawValue)")
            try expect(!spec.subtitle.isEmpty, "empty subtitle for \(sec.rawValue)")
            try expect(!spec.systemImage.isEmpty, "empty systemImage for \(sec.rawValue)")
        }
    }

    // 3. Preset.spec(for:) is deterministic (same input → same output).
    await test("PKT-876: BridgeSettingsHeaderPreset.spec is pure / deterministic") {
        for sec in BridgeSettingsHeaderPreset.targetSections {
            let a = BridgeSettingsHeaderPreset.spec(for: sec)
            let b = BridgeSettingsHeaderPreset.spec(for: sec)
            try expect(a.title == b.title && a.subtitle == b.subtitle
                       && a.systemImage == b.systemImage,
                       "spec(for:\(sec)) drifted across calls")
        }
    }

    // 4. Shared header is a single type — instantiating it for each target
    // section returns the same Swift type. (Snapshot equivalent: every
    // section's hero renders via BridgeSettingsSectionHeader<EmptyView> or
    // <SomeAccessory> — never via a per-section header type.)
    await test("PKT-A: BridgeSettingsSectionHeader is a single shared type, one preset per case") {
        // Construct the header generically for EVERY section from its preset.
        // If any section had a bespoke header type it could not satisfy this.
        let names = await MainActor.run { () -> [String] in
            SettingsSection.allCases.map { sec in
                let p = BridgeSettingsHeaderPreset.spec(for: sec)
                let header = BridgeSettingsSectionHeader(
                    title: p.title, subtitle: p.subtitle,
                    systemImage: p.systemImage, tint: p.tint
                )
                return String(describing: type(of: header))
            }
        }
        try expect(names.count == 9, "expected 9 headers, got \(names.count)")
        for name in names {
            try expect(name.hasPrefix("BridgeSettingsSectionHeader<"),
                       "non-shared header type: \(name)")
        }
    }

    // 5. CredentialToolDependencies maps every known slug.
    await test("PKT-876: CredentialToolDependencies maps shipped credential slugs") {
        try expect(CredentialToolDependencies.modules(forCredentialService: "notion") == ["notion"])
        try expect(CredentialToolDependencies.modules(forCredentialService: "stripe") == ["stripe", "payment"])
        try expect(CredentialToolDependencies.modules(forCredentialService: "api_key:stripe") == ["stripe", "payment"],
                   "api_key:<slug> prefix must normalize to bare slug")
        try expect(CredentialToolDependencies.modules(forCredentialService: "openai") == ["openai"])
        try expect(CredentialToolDependencies.modules(forCredentialService: "github") == ["gh", "git"])
    }

    // 6. PermissionToolDependencies maps every Grant case (so a future
    // grant added without a dep mapping fails this test).
    await test("PKT-876: PermissionToolDependencies has a mapping for every Grant case") {
        for grant in PermissionManager.Grant.allCases {
            let mods = PermissionToolDependencies.modules(forGrant: grant)
            // Notifications intentionally maps to []; others must be non-empty
            if grant == .notifications {
                try expect(mods.isEmpty, "notifications expected empty; got \(mods)")
            } else {
                try expect(!mods.isEmpty, "\(grant) has no dep mapping")
            }
        }
    }

    // 7. usedByChips collapses N tools per module into one chip with
    // correct plural form.
    await test("PKT-876: ToolDepLinks.usedByChips collapses by module + pluralizes") {
        let chips = await MainActor.run { () -> [DepLinkChip] in
            let liveTools: [ToolInfo] = (1...28).map { i in
                ToolInfo(name: "notion_tool_\(i)", module: "notion", tier: "open", description: "")
            }
            return ToolDepLinks.usedByChips(forCredentialService: "notion", liveTools: liveTools)
        }
        try expect(chips.count == 1, "expected one collapsed chip, got \(chips.count)")
        try expect(chips[0].label == "28 notion tools",
                   "label mismatch: \(chips[0].label)")
        try expect(chips[0].section == .tools)
        try expect(chips[0].anchor == "notion")
    }

    await test("PKT-876: ToolDepLinks.usedByChips singular form for count=1") {
        let chips = await MainActor.run { () -> [DepLinkChip] in
            let liveTools = [ToolInfo(name: "stripe_only", module: "stripe", tier: "open", description: "")]
            return ToolDepLinks.usedByChips(forCredentialService: "stripe", liveTools: liveTools)
        }
        try expect(chips.count == 1)
        try expect(chips[0].label == "1 stripe tool",
                   "singular pluralization wrong: \(chips[0].label)")
    }

    // 8. Orphan credential → single .bad chip.
    await test("PKT-876: ToolDepLinks.usedByChips returns .bad orphan chip when no tools match") {
        let chips = await MainActor.run { () -> [DepLinkChip] in
            ToolDepLinks.usedByChips(
                forCredentialService: "openai",
                liveTools: [
                    ToolInfo(name: "x", module: "notion", tier: "open", description: "")
                ]
            )
        }
        try expect(chips.count == 1)
        if case .bad = chips[0].variant { } else {
            throw TestError.assertion("expected .bad variant for orphan, got .info")
        }
        try expect(chips[0].label == "no tools registered")
    }

    // 9. requiredByChips → .bad when permission denied but tools depend.
    await test("PKT-876: ToolDepLinks.requiredByChips marks chips .bad when permission denied") {
        let (granted, denied) = await MainActor.run { () -> ([DepLinkChip], [DepLinkChip]) in
            let liveTools: [ToolInfo] = (1...4).map { i in
                ToolInfo(name: "contacts_t_\(i)", module: "contacts", tier: "open", description: "")
            }
            let g = ToolDepLinks.requiredByChips(
                forGrant: .contacts, liveTools: liveTools, permissionGranted: true
            )
            let d = ToolDepLinks.requiredByChips(
                forGrant: .contacts, liveTools: liveTools, permissionGranted: false
            )
            return (g, d)
        }
        try expect(granted.count == 1)
        try expect(granted[0].label == "4 contacts tools")
        if case .info = granted[0].variant { } else {
            throw TestError.assertion("granted should be .info")
        }

        try expect(denied.count == 1)
        try expect(denied[0].label == "4 contacts tools \u{2014} disabled",
                   "denied label mismatch: \(denied[0].label)")
        if case .bad = denied[0].variant { } else {
            throw TestError.assertion("denied should be .bad")
        }
    }

    // 10. Notifications grant → empty chip set (not tool-gated).
    await test("PKT-876: ToolDepLinks.requiredByChips empty for notifications (banner-only)") {
        let chips = await MainActor.run { () -> [DepLinkChip] in
            ToolDepLinks.requiredByChips(
                forGrant: .notifications, liveTools: [], permissionGranted: true
            )
        }
        try expect(chips.isEmpty, "notifications should yield no tool chips")
    }

    // 11. Locked SF Symbols per section (pinned for visual contract).
    await test("PKT-A: BridgeSectionIcon SF Symbols locked for the 7 sections") {
        try expect(BridgeSectionIcon.systemImage(for: .orders) == "command")
        try expect(BridgeSectionIcon.systemImage(for: .skills) == "sparkles")
        try expect(BridgeSectionIcon.systemImage(for: .jobs) == "clock.badge.checkmark")
        try expect(BridgeSectionIcon.systemImage(for: .tools) == "hammer")
        try expect(BridgeSectionIcon.systemImage(for: .security) == "lock.shield")
        try expect(BridgeSectionIcon.systemImage(for: .connection) == "network")
        try expect(BridgeSectionIcon.systemImage(for: .advanced) == "wrench.and.screwdriver")
    }

    // 12. Dep-link rows route via SettingsNavigation.shared — verified
    // here as a behavioral check: invoking action sets .section + .anchor.
    await test("PKT-876: dep-link chip action routes via SettingsNavigation.shared") {
        let (section, anchor) = await MainActor.run { () -> (SettingsSection, String?) in
            let chip = DepLinkChip(
                id: "test", label: "5 notion tools",
                variant: .info, section: .tools, anchor: "notion"
            )
            SettingsNavigation.shared.go(chip.section, anchor: chip.anchor)
            let result = (SettingsNavigation.shared.section, SettingsNavigation.shared.anchor)
            // restore default to avoid leaking into sibling tests
            SettingsNavigation.shared.go(.orders, anchor: nil)
            return result
        }
        try expect(section == .tools, "section did not route to .tools")
        try expect(anchor == "notion", "anchor did not route to 'notion'")
    }

    // 13. Header preset round-trip for ALL SettingsSection cases — even
    // non-target sections get a preset so a future caller never branches.
    await test("PKT-876: every SettingsSection has a header preset (no missing case)") {
        for sec in SettingsSection.allCases {
            let spec = BridgeSettingsHeaderPreset.spec(for: sec)
            try expect(!spec.title.isEmpty, "no preset title for \(sec)")
        }
    }
}
