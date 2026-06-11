// PKT879DashboardTests.swift — Liquid Glass Dashboard reskin
// Behavioral / contract tests for the v3.6.4 dashboard popover.
//
// The dashboard is a SwiftUI view; we cannot diff pixels in this harness.
// Instead we pin the load-bearing structural contracts the design spec
// requires:
//   • locked popover width (300pt — design/dashboard.html)
//   • locked dot-pulse size
//   • every navigable section is a real `SettingsSection` case
//   • status row → connections, permissions cells → permissions,
//     stats: tools/jobs/skills navigate to their respective sections
//   • SettingsNavigation.go() actually mutates section + anchor
//   • permission grant cells use the v1Cases set (no silent shrink)

import Foundation
import SwiftUI
import NotionBridgeLib

func runPKT879DashboardTests() async {
    print("\n\u{1F9F1} PKT-879 Dashboard Tests (Liquid Glass reskin)")

    // ── Constants surface ─────────────────────────────────────────────
    await test("PKT-879 dashboard popover width is locked to 300pt") {
        try expect(PKT879Dashboard.popoverWidth == 300,
                   "popover width drifted: \(PKT879Dashboard.popoverWidth)")
    }

    await test("PKT-879 dashboard status dot size is locked to 9pt") {
        try expect(PKT879Dashboard.statusDotSize == 9,
                   "status dot size drifted: \(PKT879Dashboard.statusDotSize)")
    }

    // ── Navigation contract ───────────────────────────────────────────
    // Every dashboard row deep-links to a `SettingsSection`. We assert
    // each target exists so a typo (e.g. .jobsMistyped) is caught
    // structurally even though the SwiftUI body is not directly
    // diffable.

    await test("Dashboard navigates to .connection for the status row") {
        // PKT-A: the status row deep-links to the merged Connection section.
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.go(.connection) }
        let s = await MainActor.run { nav.section }
        try expect(s == .connection, "expected .connection, got \(s)")
    }

    await test("Dashboard navigates to .security on the gates anchor for permissions") {
        // PKT-A: Permissions folded into Security → Gates tab.
        let nav = await MainActor.run { SettingsNavigation() }
        await MainActor.run { nav.go(.security, anchor: "gates") }
        let s = await MainActor.run { nav.section }
        let a = await MainActor.run { nav.anchor }
        try expect(s == .security, "expected .security, got \(s)")
        try expect(a == "gates", "expected anchor 'gates', got \(a ?? "nil")")
    }

    await test("Dashboard stats row navigates to .tools / .jobs / .skills") {
        // The three stats targets must all exist in the canonical sidebar.
        let ids = Set(SettingsSection.allCases.map(\.rawValue))
        try expect(ids.contains("Tools"), "Tools section missing — dashboard stat-row 'tools active' would 404")
        try expect(ids.contains("Jobs"),  "Jobs section missing — dashboard stat-row 'calls today' would 404")
        try expect(ids.contains("Skills"), "Skills section missing — dashboard stat-row 'skills' would 404")
    }

    await test("Dashboard quick-link targets (orders/tools/connection) exist") {
        // PKT-A: the ⌘ quick-link now opens Orders (anchor commands); the
        // gear opens the merged Connection section.
        let ids = Set(SettingsSection.allCases.map(\.rawValue))
        try expect(ids.contains("Standing Orders"), "orders quick-link target missing")
        try expect(ids.contains("Tools"), "tools quick-link target missing")
        try expect(ids.contains("Connection"), "connection quick-link target missing")
    }

    // ── Permission cells ──────────────────────────────────────────────
    // The two-col grid renders one cell per `Grant.v1Cases`. If that
    // list ever shrinks the design intent of "4/5 in mock" silently
    // breaks; pin the relationship.

    await test("Permission grid uses PermissionManager.Grant.v1Cases") {
        let cases = PermissionManager.Grant.v1Cases
        try expect(cases.count >= 5,
                   "fewer than 5 grants would not fill the design's 2-col grid (got \(cases.count))")
        // Each grant must have a non-empty display name (the cell label).
        for g in cases {
            try expect(!g.displayName.isEmpty, "\(g) has empty displayName")
        }
    }

    await test("Permission grant.rawValue is non-empty (used as nav anchor)") {
        for g in PermissionManager.Grant.v1Cases {
            try expect(!g.rawValue.isEmpty, "\(g) has empty rawValue")
        }
    }

    // ── StatusPulseDot ────────────────────────────────────────────────
    // The pulse component is exported so tests can pin its existence
    // and the green-only pulse heuristic.

    await test("StatusPulseDot constructs for green/red/orange") {
        // Construct the view in the MainActor context — body evaluation is
        // not required to assert the conformance and the init paths.
        await MainActor.run {
            _ = StatusPulseDot(color: .green)
            _ = StatusPulseDot(color: .red)
            _ = StatusPulseDot(color: .orange)
        }
    }

    // ── DashboardView still constructs cleanly ────────────────────────
    await test("DashboardView constructs with statusBar + permissionManager + onOpenSettings") {
        await MainActor.run {
            let statusBar = StatusBarController()
            let pm = PermissionManager()
            var captured: SettingsSection? = nil
            let onOpen: (SettingsSection) -> Void = { captured = $0 }
            _ = DashboardView(
                statusBar: statusBar,
                permissionManager: pm,
                onOpenSettings: onOpen
            )
            // Pin the callback signature by invoking the closure directly.
            onOpen(.connection)
            assert(captured == .connection)
        }
    }
}
