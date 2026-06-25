// SettingsUIValidationHarness.swift — PKT-1005 (Pillar D)
// TheBridge · Modules
//
// The headless UI-validation harness core. PKT-1005 establishes a repeatable,
// scriptable path to open The Bridge's Settings window (bridge_open_settings),
// deep-link to a section (bridge_settings_navigate), and AX-assert that the
// section's stable accessibilityIdentifiers (BridgeAXID, Pillar C) are present.
//
// This type is the PURE-LOGIC core of that loop: it owns the per-section
// expected-id MANIFEST and a `validate` routine that compares a set of
// identifiers observed in a live `ax_tree` read against the manifest, returning
// a pass/fail report naming any missing ids. The on-device driver script
// (scripts/pkt1005-ui-validate.sh) supplies the observed ids from real ax_tree
// output; unit tests supply synthetic sets. Keeping the manifest here — next to
// the views' BridgeAXID convention — means a rename that breaks one breaks the
// tests, so the harness can never silently drift out of sync with the UI.

import Foundation

/// Per-section pass/fail result for the headless UI-validation harness.
public struct SettingsSectionValidationReport: Sendable, Equatable {
    public let section: SettingsSection
    /// Identifiers the manifest expected for this section.
    public let expected: [String]
    /// Expected identifiers NOT found in the observed `ax_tree` read.
    public let missing: [String]
    public var passed: Bool { missing.isEmpty }

    public init(section: SettingsSection, expected: [String], missing: [String]) {
        self.section = section
        self.expected = expected
        self.missing = missing
    }
}

/// Pure-logic core of the PKT-1005 headless UI-validation harness.
public enum SettingsUIValidationHarness {

    /// The expected stable AX identifiers per section. Every section has at
    /// least its root container id (`bridge.settings.<section>.root`, applied by
    /// `SettingsView.detailContent`) plus the shared-chrome nav-row + title-bar
    /// ids. The Skills section — the Pillar C priority surface — additionally
    /// instruments its toggles, cache controls, indicators, nav chevrons,
    /// Trash, and metadata grid.
    public static var expectedIdentifiers: [SettingsSection: [String]] {
        var map: [SettingsSection: [String]] = [:]
        for section in SettingsSection.allCases {
            // Shared chrome present for every section + the section root.
            var ids: [String] = [
                BridgeAXID.navRow(section),
                BridgeAXID.titleBar,
                BridgeAXID.control(section, "root"),
            ]
            // Per-section inner-control ids. Skills was the Pillar-C priority
            // surface (PKT-1005 wave plan); the other six sections' key controls
            // were instrumented in PKT-1005 remainder (b) under the SAME
            // BridgeAXID convention, so the harness can assert them by id too.
            switch section {
            case .skills:
                // NB: `BridgeAXID.Skills.root` == `BridgeAXID.control(.skills, "root")`,
                // already added by the shared-chrome loop above — not repeated here.
                ids.append(contentsOf: [
                    BridgeAXID.Skills.list,
                    BridgeAXID.Skills.toggleRouting,
                    BridgeAXID.Skills.toggleEnabled,
                    BridgeAXID.Skills.cacheIndicator,
                    BridgeAXID.Skills.statusIndicator,
                    BridgeAXID.Skills.trash,
                    BridgeAXID.Skills.metadataGrid,
                ])
            case .orders:   // displays "Commands"
                ids.append(contentsOf: [
                    BridgeAXID.Commands.header,
                    BridgeAXID.Commands.toggleEnabled,
                    BridgeAXID.Commands.shortcutEditor,
                    BridgeAXID.Commands.list,
                ])
            case .jobs:
                ids.append(contentsOf: [
                    BridgeAXID.Jobs.newJob,
                    BridgeAXID.Jobs.pauseAll,
                    BridgeAXID.Jobs.search,
                    BridgeAXID.Jobs.list,
                ])
            case .tools:
                ids.append(contentsOf: [
                    BridgeAXID.Tools.list,
                ])
            case .security:
                ids.append(contentsOf: [
                    BridgeAXID.Security.recheckAll,
                    BridgeAXID.Security.grantsList,
                    BridgeAXID.Security.addCredential,
                    BridgeAXID.Security.credentialsList,
                    BridgeAXID.Security.togglePolicy,
                ])
            case .connection:
                ids.append(contentsOf: [
                    BridgeAXID.Connection.clientsList,
                    BridgeAXID.Connection.toggleRemote,
                ])
            case .memory:
                ids.append(contentsOf: [
                    BridgeAXID.Memory.tabBar,
                    BridgeAXID.Memory.tab("process"),
                    BridgeAXID.Memory.tab("inbox"),
                    BridgeAXID.Memory.tab("notion"),
                    BridgeAXID.Memory.tab("agent"),
                    BridgeAXID.Memory.tab("processing"),
                    // PKT-MEM-106 0b Process cockpit zones (replace the pre-cockpit
                    // process.list / process.preview surfaces).
                    BridgeAXID.Memory.Process.memoList,
                    BridgeAXID.Memory.Process.intentTable,
                    BridgeAXID.Memory.Process.detailInspector,
                    BridgeAXID.Memory.Process.activityStrip,
                    BridgeAXID.Memory.processingPane,
                    BridgeAXID.Memory.processingProviderSave,
                    BridgeAXID.Memory.processingProviderStatus,
                    BridgeAXID.Memory.inboxList,
                    BridgeAXID.Memory.dismiss,
                    BridgeAXID.Memory.notionList,
                    BridgeAXID.Memory.agentList,
                    BridgeAXID.Memory.agentScopeFilter,
                    BridgeAXID.Memory.agentTypeFilter,
                ])
            case .datasources:
                // Match the control slugs DataSourcesSection actually emits.
                ids.append(contentsOf: [
                    BridgeAXID.control(.datasources, "introspect"),
                    BridgeAXID.control(.datasources, "clearCache"),
                    BridgeAXID.control(.datasources, "proposal.confirm"),
                ])
            // NB: a former duplicate `.memory` switch arm (PKT-977 Memory-inspector ids
            // settings.autoInject / entries.refresh / entries.scopeFilter) was dead code —
            // unreachable after the first `.memory` arm, and those ids are no longer set by
            // any live view (grep-verified). Removed to keep the manifest↔view lock honest;
            // the single `.memory` arm above carries every rendered Memory id.
            case .advanced:
                ids.append(contentsOf: [
                    BridgeAXID.Advanced.checkUpdates,
                    BridgeAXID.Advanced.exportDiagnostics,
                    BridgeAXID.Advanced.toggleLaunchAtLogin,
                    BridgeAXID.Advanced.savePort,
                    BridgeAXID.Advanced.factoryReset,
                ])
            }
            map[section] = ids
        }
        return map
    }

    /// Validate a single section's observed identifiers against the manifest.
    public static func validate(
        section: SettingsSection,
        observedIdentifiers: Set<String>
    ) -> SettingsSectionValidationReport {
        let expected = expectedIdentifiers[section] ?? []
        let missing = expected.filter { !observedIdentifiers.contains($0) }
        return SettingsSectionValidationReport(section: section, expected: expected, missing: missing)
    }

    /// Validate every section against one observed-id set (e.g. the union of
    /// ax_tree reads taken after deep-linking to each section in turn).
    public static func validateAll(
        observedIdentifiers: Set<String>
    ) -> [SettingsSectionValidationReport] {
        SettingsSection.allCases.map { validate(section: $0, observedIdentifiers: observedIdentifiers) }
    }
}
