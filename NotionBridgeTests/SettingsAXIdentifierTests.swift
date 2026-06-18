// SettingsAXIdentifierTests.swift — PKT-1005 (Pillar C + D)
// NotionBridge · Tests
//
// HEADLESSLY TESTED:
//   • BridgeAXID convention: the stable, label-independent accessibility-
//     identifier scheme `bridge.settings.<section>.<control>` for the Settings
//     UI. Before PKT-1005 there were ZERO accessibilityIdentifier usages in
//     NotionBridge/UI, so on-device AX reads matched on volatile labels. These
//     tests LOCK the id strings so the SwiftUI views and the headless
//     UI-validation harness agree on the exact same identifiers.
//   • SettingsUIValidationHarness: the pure-logic core of the headless harness
//     (Pillar D). Given a set of AX identifiers observed in a live ax_tree read,
//     it reports per-section pass/fail against the expected-id manifest. The
//     on-device driver (scripts/pkt1005-ui-validate.sh) feeds it real ax_tree
//     output; here we exercise the logic with synthetic id sets.
//
// LOCK invariant: if a future commit renames an id in the views without
// updating the manifest (or vice-versa), the convention tests fail loudly —
// the harness would otherwise silently stop finding the control on-device.

import Foundation
import NotionBridgeLib

func runSettingsAXIdentifierTests() async {
    print("\n\u{1F517} Settings AX-Identifier Tests (PKT-1005 Pillar C/D)")

    // MARK: - BridgeAXID convention

    await test("PKT-1005: nav-row ids key off the section CASE NAME, not the label") {
        // .orders displays "Commands" but its id segment is the case name `orders`
        // (the stable deep-link identity) — proving label-independence.
        let ordersID = await MainActor.run { BridgeAXID.navRow(.orders) }
        try expect(ordersID == "bridge.settings.nav.orders",
                   "expected bridge.settings.nav.orders, got \(ordersID)")
        let skillsID = await MainActor.run { BridgeAXID.navRow(.skills) }
        try expect(skillsID == "bridge.settings.nav.skills", "got \(skillsID)")
    }

    await test("PKT-1005: every section has a unique, well-formed nav-row id") {
        let ids = await MainActor.run { SettingsSection.allCases.map { BridgeAXID.navRow($0) } }
        try expect(Set(ids).count == SettingsSection.allCases.count, "nav-row ids not unique: \(ids)")
        for id in ids {
            try expect(id.hasPrefix("bridge.settings.nav."), "malformed nav id: \(id)")
        }
    }

    await test("PKT-1005: the title-bar id is the fixed shared-chrome anchor") {
        let id = await MainActor.run { BridgeAXID.titleBar }
        try expect(id == "bridge.settings.title", "got \(id)")
    }

    await test("PKT-1005: control() composes section + control slug") {
        let id = await MainActor.run { BridgeAXID.control(.security, "root") }
        try expect(id == "bridge.settings.security.root", "got \(id)")
    }

    await test("PKT-1005: Skills control slugs match the documented convention") {
        let pairs: [(String, String)] = await MainActor.run {
            [
                (BridgeAXID.Skills.root,            "bridge.settings.skills.root"),
                (BridgeAXID.Skills.list,            "bridge.settings.skills.list"),
                (BridgeAXID.Skills.toggleRouting,   "bridge.settings.skills.toggle.routing"),
                (BridgeAXID.Skills.toggleEnabled,   "bridge.settings.skills.toggle.enabled"),
                (BridgeAXID.Skills.cacheRefresh,    "bridge.settings.skills.cache.refresh"),
                (BridgeAXID.Skills.cacheIndicator,  "bridge.settings.skills.cache.indicator"),
                (BridgeAXID.Skills.statusIndicator, "bridge.settings.skills.status.indicator"),
                (BridgeAXID.Skills.navChevron,      "bridge.settings.skills.nav.chevron"),
                (BridgeAXID.Skills.trash,           "bridge.settings.skills.trash"),
                (BridgeAXID.Skills.metadataGrid,    "bridge.settings.skills.metadata.grid"),
            ]
        }
        for (got, want) in pairs {
            try expect(got == want, "Skills id drift: got \(got), want \(want)")
        }
    }

    // MARK: - Headless UI-validation harness (Pillar D) — pure logic

    await test("PKT-1005: harness manifest covers all 7 sections with a root id") {
        let manifest = SettingsUIValidationHarness.expectedIdentifiers
        try expect(manifest.count == SettingsSection.allCases.count,
                   "manifest must cover all 7 sections, has \(manifest.count)")
        for section in SettingsSection.allCases {
            let ids = manifest[section] ?? []
            let rootID = await MainActor.run { BridgeAXID.control(section, "root") }
            try expect(ids.contains(rootID),
                       "section \(section) manifest missing its root id \(rootID)")
        }
    }

    await test("PKT-1005: harness PASSES a section when all expected ids are observed") {
        // Simulate an on-device ax_tree read that surfaced every expected id.
        let observed = Set(SettingsUIValidationHarness.expectedIdentifiers[.skills] ?? [])
        let report = SettingsUIValidationHarness.validate(section: .skills, observedIdentifiers: observed)
        try expect(report.passed, "expected pass; missing=\(report.missing)")
        try expect(report.missing.isEmpty, "expected no missing ids, got \(report.missing)")
    }

    await test("PKT-1005: harness FAILS a section and names the missing ids") {
        // Drop the Trash id from the observed set — the harness must catch it.
        let expected = SettingsUIValidationHarness.expectedIdentifiers[.skills] ?? []
        let trashID = await MainActor.run { BridgeAXID.Skills.trash }
        let observed = Set(expected.filter { $0 != trashID })
        let report = SettingsUIValidationHarness.validate(section: .skills, observedIdentifiers: observed)
        try expect(!report.passed, "expected fail when an id is missing")
        try expect(report.missing == [trashID],
                   "expected exactly the trash id missing, got \(report.missing)")
    }

    // MARK: - Findings 1 & 2 lock (operator-ratified)

    await test("PKT-1005 finding 2: Skills exposes exactly the TWO ratified detail toggles") {
        // The Skills manifest must contain List-in-routing + Enabled and NO
        // palette toggle id — the "Show in Commands palette" detail toggle was
        // removed (the inCommandPalette backend flag is retained, just not
        // surfaced as a detail toggle).
        let ids = SettingsUIValidationHarness.expectedIdentifiers[.skills] ?? []
        let routing = await MainActor.run { BridgeAXID.Skills.toggleRouting }
        let enabled = await MainActor.run { BridgeAXID.Skills.toggleEnabled }
        try expect(ids.contains(routing), "Skills must expose the routing toggle id")
        try expect(ids.contains(enabled), "Skills must expose the enabled toggle id")
        // There must be NO palette toggle id anywhere in the manifest.
        try expect(!ids.contains(where: { $0.contains("toggle.palette") || $0.contains("commandPalette") }),
                   "the 'Show in Commands palette' detail toggle must NOT be surfaced (finding 2)")
        // Exactly two toggle.* ids for Skills.
        let toggleIDs = ids.filter { $0.contains(".toggle.") }
        try expect(toggleIDs.count == 2, "expected exactly 2 Skills toggles, got \(toggleIDs)")
    }

    await test("PKT-1005 finding 1: the metadata-grid id is present (Page cell removed → 3 cells)") {
        // The grid keeps its id; the redundant "Page" cell is dropped in the
        // view (Kind · Visibility · Source). The on-device ax_tree read confirms
        // the visual cell count; here we lock that the grid id is part of the
        // contract so the harness can locate it.
        let ids = SettingsUIValidationHarness.expectedIdentifiers[.skills] ?? []
        let grid = await MainActor.run { BridgeAXID.Skills.metadataGrid }
        try expect(ids.contains(grid), "Skills manifest must expose the metadata-grid id")
    }

    // MARK: - PKT-1005 remainder (b): inner-control coverage for the other 6 sections

    await test("PKT-1005(b): the 6 non-Skills sections' control ids follow the convention") {
        // Each id must be `bridge.settings.<caseName>.<slug>` — keyed off the
        // stable SettingsSection case name (note .orders displays "Commands").
        let checks: [(String, String)] = await MainActor.run {
            [
                (BridgeAXID.Commands.toggleEnabled,         "bridge.settings.orders.toggle.enabled"),
                (BridgeAXID.Commands.shortcutEditor,        "bridge.settings.orders.shortcut.editor"),
                (BridgeAXID.Commands.header,                "bridge.settings.orders.header"),
                (BridgeAXID.Commands.list,                  "bridge.settings.orders.list"),
                (BridgeAXID.Jobs.newJob,                    "bridge.settings.jobs.new"),
                (BridgeAXID.Jobs.pauseAll,                  "bridge.settings.jobs.pause.all"),
                (BridgeAXID.Jobs.search,                    "bridge.settings.jobs.search"),
                (BridgeAXID.Jobs.row,                       "bridge.settings.jobs.row"),
                (BridgeAXID.Tools.list,                     "bridge.settings.tools.list"),
                (BridgeAXID.Tools.groupRow,                 "bridge.settings.tools.group.row"),
                (BridgeAXID.Security.recheckAll,            "bridge.settings.security.recheck.all"),
                (BridgeAXID.Security.addCredential,         "bridge.settings.security.credential.add"),
                (BridgeAXID.Security.togglePolicy,          "bridge.settings.security.toggle.policy"),
                (BridgeAXID.Connection.toggleRemote,        "bridge.settings.connection.toggle.remote"),
                (BridgeAXID.Connection.clientRow,           "bridge.settings.connection.client.row"),
                (BridgeAXID.Advanced.toggleLaunchAtLogin,   "bridge.settings.advanced.toggle.launchAtLogin"),
                (BridgeAXID.Advanced.savePort,              "bridge.settings.advanced.port.save"),
                (BridgeAXID.Advanced.factoryReset,          "bridge.settings.advanced.factory.reset"),
            ]
        }
        for (got, want) in checks {
            try expect(got == want, "AX-id drift: got \(got), want \(want)")
        }
    }

    await test("PKT-1005(b): every section's manifest carries at least one inner-control id") {
        // Shared chrome (nav + title + root) = 3 ids; remainder (b) means every
        // section now also exposes section-specific controls (> 3 manifest ids).
        let manifest = SettingsUIValidationHarness.expectedIdentifiers
        for section in SettingsSection.allCases {
            let ids = manifest[section] ?? []
            try expect(ids.count > 3,
                       "section \(section) must expose inner-control ids beyond the 3 shared-chrome ids, has \(ids.count)")
            // No id may be empty (an unprovided axID passes "" — must never reach the manifest).
            try expect(!ids.contains(""), "section \(section) manifest must not carry an empty id")
        }
    }

    await test("PKT-1005(b): all manifest ids across all sections are well-formed + unique-per-section") {
        let manifest = SettingsUIValidationHarness.expectedIdentifiers
        for section in SettingsSection.allCases {
            let ids = manifest[section] ?? []
            for id in ids {
                try expect(id.hasPrefix("bridge.settings."), "malformed id in \(section): \(id)")
            }
            try expect(Set(ids).count == ids.count, "duplicate id within \(section) manifest: \(ids)")
        }
    }

    await test("PKT-1005: harness validateAll aggregates per-section reports") {
        // Feed the union of every section's expected ids → all sections pass.
        var union = Set<String>()
        for ids in SettingsUIValidationHarness.expectedIdentifiers.values { union.formUnion(ids) }
        let reports = SettingsUIValidationHarness.validateAll(observedIdentifiers: union)
        try expect(reports.count == SettingsSection.allCases.count, "expected 7 reports")
        try expect(reports.allSatisfy { $0.passed }, "all sections should pass with the full union")
    }
}
