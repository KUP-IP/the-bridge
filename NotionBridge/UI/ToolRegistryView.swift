// ToolRegistryView.swift — Tool Registry Tab
// NotionBridge · UI
// Displays all registered MCP tools grouped by module with enable/disable toggles.
// V1.3.0 + PKT-376: 3-state tier toggle, Reset to Defaults, search removed.
//
// History:
// PKT-350 F2: Original tool registry with grouped modules and toggles.
// V1.2.0: Search bar, moduleDisplayNames dictionary, filteredGroups.
// V1.3.0: PKT-366 F1 tappable Open/Notify tier toggle per tool,
//          F4 "Reset to Defaults" button, F5 search bar removed.

import SwiftUI

/// Tool Registry tab for Settings window.
/// Shows all MCP tools grouped by module with toggle controls and tier overrides.
///
/// PKT-366/PKT-376 additions:
/// - Tappable Open/Notify/Request toggle per tool. Persisted to `com.notionbridge.tierOverrides`.
/// - F4: "Reset to Defaults" clears all tier overrides.
/// - F5: Search bar removed.
struct ToolRegistryView: View {
    let tools: [ToolInfo]
    let onToggle: (String, Bool) -> Void

    /// F7: Whether notification permission is denied/not determined.
    /// When true AND any tool has Notify tier, a warning banner is shown.
    var notificationDenied: Bool = false

    @State private var credentialFeatureEpoch = 0

    /// v4 table view: which module groups are expanded (by module key).
    @State private var expandedModules: Set<String> = []
    /// v4 search box — narrows visible modules/tools by name + description.
    @State private var searchText: String = ""

    @State private var disabledTools: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? []
    )

    /// User tier overrides. Keys are tool names, values are tier raw values.
    /// Tools not in this map inherit their registered default tier.
    @State private var tierOverrides: [String: String] = (
        UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides) as? [String: String]
    ) ?? [:]

    /// fb-securitygate: module-scoped "Always Allow" grants (module name → tier
    /// rawValue). A module grant covers every tool in that module; a per-tool
    /// override takes precedence over it. Written by SecurityGate when the user
    /// picks "Always Allow" — surfaced + individually revocable below.
    @State private var moduleTierOverrides: [String: String] = (
        UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]
    ) ?? [:]

    private static let coreTools: Set<String> = ["echo", "session_info", "tools_list"]

    /// Brand-correct display names for modules whose `.capitalized` form is wrong.
    /// Modules not in this dictionary fall through to `.capitalized`.
    private static let moduleDisplayNames: [String: String] = [
        "applescript": "AppleScript",
        "builtin": "Built-in",
    ]

    /// Returns the display-safe name for a module key.
    private func displayName(for module: String) -> String {
        Self.moduleDisplayNames[module] ?? module.capitalized
    }

    private var groupedTools: [(module: String, tools: [ToolInfo])] {
        let dict = Dictionary(grouping: tools, by: { $0.module })
        return dict.keys.sorted().map { ($0, dict[$0]!.sorted(by: { $0.name < $1.name })) }
    }

    /// Effective tier for a tool — per-tool override > per-module grant >
    /// registered default (mirrors `ToolRouter.resolveEffectiveTier`). Without
    /// the module layer, a sibling tool covered by a module grant would have
    /// displayed its registered default while actually resolving to the grant.
    private func effectiveTier(for tool: ToolInfo) -> String {
        ToolTierResolution.effectiveTier(
            toolName: tool.name,
            module: tool.module,
            registeredTier: tool.tier,
            toolOverrides: tierOverrides,
            moduleOverrides: moduleTierOverrides
        )
    }

    /// Where a tool's effective tier comes from — drives the row annotation that
    /// distinguishes a module grant from the tool's own override.
    private func tierSource(for tool: ToolInfo) -> ToolTierSource {
        ToolTierResolution.source(
            toolName: tool.name,
            module: tool.module,
            toolOverrides: tierOverrides,
            moduleOverrides: moduleTierOverrides
        )
    }

    /// Whether any tool is set to a tier that emits notifications.
    private var hasNotificationTierTools: Bool {
        tools.contains {
            let tier = effectiveTier(for: $0)
            return tier == "notify" || tier == "request"
        }
    }

    private func nextTier(after current: String) -> String {
        switch current {
        case "open":
            return "notify"
        case "notify":
            return "request"
        default:
            return "open"
        }
    }

    // MARK: v4 derived view-model

    /// Map a tier rawValue ("open"/"notify"/"request") to the UI `BridgeTier`.
    /// The domain rawValue "request" round-trips to `.confirm` (label "Confirm").
    private func uiTier(_ raw: String) -> BridgeTier { BridgeTier(rawValue: raw) ?? .open }

    /// Live total / active counts — bound to the ACTUAL registry.
    private var liveTotal: Int { tools.count }
    private var liveActive: Int { tools.filter { effectiveToolEnabled($0) }.count }

    /// Modules after the search filter (matches module name, tool name, or
    /// description). Pure view-side — no wiring touched.
    private var filteredGroups: [(module: String, tools: [ToolInfo])] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groupedTools }
        return groupedTools.compactMap { group in
            if displayName(for: group.module).lowercased().contains(q) { return group }
            let hits = group.tools.filter {
                $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : (group.module, hits)
        }
    }

    var body: some View {
        if tools.isEmpty {
            BridgeEmptyStateView(
                systemImage: "hammer",
                title: "Tool registry",
                message: "Tools will appear here once the server is running.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: BridgeTokens.Space.s5) {
                    // Live stat strip — enabled/total bound to the real registry.
                    BridgeStatStrip {
                        BridgeStatTile(value: "\(liveActive)/\(liveTotal)", label: "Enabled", signal: .ok)
                        BridgeStatTile(value: "\(groupedTools.count)", label: "Modules", signal: .info)
                    }

                    // F7: Cross-dependency guard — notifications denied while
                    // Notify/Confirm-tier tools exist.
                    if notificationDenied && hasNotificationTierTools {
                        BridgeBanner(
                            signal: .warn,
                            message: "Notification permission is not granted. Notify and Confirm tiers cannot prompt or alert.",
                            systemImage: "exclamationmark.triangle")
                    }

                    // Search.
                    searchField

                    // Per-module tables.
                    if filteredGroups.isEmpty {
                        BridgeEmptyStateView(
                            systemImage: "magnifyingglass",
                            title: "No tools match",
                            message: "No module or tool matches your search.")
                    } else {
                        BridgeToolTable(columns: ["Module · tool", "On", "Tier", ""]) {
                            ForEach(filteredGroups, id: \.module) { group in
                                moduleGroup(group)
                            }
                        }
                    }

                    // fb-securitygate-revoke-ui: active module-scoped "Always
                    // Allow" grants, each individually revocable.
                    if !moduleTierOverrides.isEmpty {
                        moduleGrantsSection
                    }

                    // F4: Reset to Defaults.
                    if !tierOverrides.isEmpty || !moduleTierOverrides.isEmpty {
                        resetButton
                    }
                }
                .padding(.vertical, BridgeTokens.Space.paneV)
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(credentialFeatureEpoch)
            .onReceive(NotificationCenter.default.publisher(for: .notionBridgeCredentialsFeatureDidChange)) { _ in
                credentialFeatureEpoch += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .notionBridgeTierOverridesDidChange)) { _ in
                tierOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides) as? [String: String]) ?? [:]
                moduleTierOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]
            }
        }
    }

    // MARK: v4 subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(BridgeTokens.fg5)
            TextField("Search \(liveTotal) tools…", text: $searchText)
                .textFieldStyle(.plain)
                .font(BridgeTokens.Typeface.base)
                .foregroundStyle(BridgeTokens.fg1)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                .fill(BridgeTokens.wellFill)
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)))
    }

    /// One module's disclosure row + (when expanded) its per-tool rows, built
    /// from the W2 table primitives. The module master toggle enables/disables
    /// every member; the count + tier pill summarize the module; per-tool rows
    /// carry the editable tier pill + enable toggle. ALL existing wiring is
    /// preserved (disabledTools, tierOverrides, module grants, onToggle).
    @ViewBuilder
    private func moduleGroup(_ group: (module: String, tools: [ToolInfo])) -> some View {
        let isExpanded = expandedModules.contains(group.module)
        let active = enabledCount(in: group.tools)
        let total = group.tools.count
        // Module pill = the most-severe effective tier across the module.
        let moduleTier = group.tools
            .map { uiTier(effectiveTier(for: $0)) }
            .max(by: { tierRank($0) < tierRank($1) }) ?? .open

        BridgeToolGroup(
            isExpanded: isExpanded,
            header: BridgeToolGroupRow(
                name: displayName(for: group.module),
                desc: moduleDescription(group.tools),
                systemImage: "shippingbox",
                isExpanded: isExpanded,
                activeCount: active,
                totalCount: total,
                tier: moduleTier,
                isOn: Binding(
                    get: { active > 0 },
                    set: { setModuleEnabled(group.tools, enabled: $0) }
                ),
                onToggleExpand: { toggleModule(group.module) }
            )
        ) {
            ForEach(group.tools) { tool in
                toolTableRow(tool)
            }
        }
    }

    /// A single nested tool row — the v4 replacement for the old `toolRow`,
    /// preserving the enable toggle + the tappable 3-tier cycle + the core-lock /
    /// credential-gate semantics.
    @ViewBuilder
    private func toolTableRow(_ tool: ToolInfo) -> some View {
        let isCoreProtected = Self.coreTools.contains(tool.name)
        let gatedCredentials = credentialModuleGateActive(for: tool)
        let isEnabled = effectiveToolEnabled(tool)
        let currentTier = effectiveTier(for: tool)

        BridgeToolRow(
            name: tool.name,
            desc: gatedCredentials
                ? "Enable Keychain credentials to use this tool."
                : (tierSource(for: tool) == .moduleGrant
                    ? "tier via \(displayName(for: tool.module)) module grant"
                    : tool.description),
            tier: uiTier(currentTier),
            isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if gatedCredentials { return }
                    if isCoreProtected { return }
                    if newValue { disabledTools.remove(tool.name) }
                    else { disabledTools.insert(tool.name) }
                    persistDisabledTools()
                    onToggle(tool.name, newValue)
                }
            ),
            onTierTap: {
                if isCoreProtected || gatedCredentials { return }
                // Base = what the tool resolves to WITHOUT its own override.
                let base = moduleTierOverrides[tool.module] ?? tool.tier
                let newTier = nextTier(after: currentTier)
                if newTier == base {
                    tierOverrides.removeValue(forKey: tool.name)
                } else {
                    tierOverrides[tool.name] = newTier
                }
                persistTierOverrides()
                NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
            }
        )
        .opacity(isCoreProtected ? 0.7 : 1)
    }

    /// The module-grants section: active "Always Allow" grants, each revocable.
    private var moduleGrantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Module grants").bridgeCap().foregroundStyle(BridgeTokens.fg4)
                Text("· \(moduleTierOverrides.count)")
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg5)
            }
            .padding(.leading, 2)
            VStack(spacing: 8) {
                ForEach(moduleTierOverrides.keys.sorted(), id: \.self) { module in
                    moduleGrantRow(module)
                }
            }
            Text("“Always Allow” grants apply to every tool in a module. A tool’s own tier override takes precedence over its module grant.")
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private var resetButton: some View {
        Button {
            tierOverrides.removeAll()
            persistTierOverrides()
            // fb-securitygate: also clear module-scoped grants so a reset is
            // complete — otherwise a module grant would outlive the per-tool
            // overrides the user just cleared.
            moduleTierOverrides.removeAll()
            persistModuleTierOverrides()
            NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset to defaults")
            }
            .font(BridgeTokens.Typeface.base600)
            .foregroundStyle(BridgeTokens.warnText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(BridgeTokens.warn.opacity(0.14)))
            .overlay(Capsule().strokeBorder(BridgeTokens.warn.opacity(0.30), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Severity ordering for the module-summary tier pill.
    private func tierRank(_ t: BridgeTier) -> Int {
        switch t { case .open: return 0; case .notify: return 1; case .confirm: return 2 }
    }

    /// A short module description from the busiest tool names (keeps the row's
    /// sub-line meaningful without a per-module copy table).
    private func moduleDescription(_ tools: [ToolInfo]) -> String {
        tools.prefix(4).map(\.name).joined(separator: " · ")
    }

    private func toggleModule(_ module: String) {
        if expandedModules.contains(module) { expandedModules.remove(module) }
        else { expandedModules.insert(module) }
    }

    /// Enable/disable every NON-core, non-gated tool in a module. Mirrors the
    /// per-tool write path (disabledTools + onToggle) so the master toggle and
    /// the per-tool toggles share one source of truth.
    private func setModuleEnabled(_ moduleTools: [ToolInfo], enabled: Bool) {
        for tool in moduleTools {
            if Self.coreTools.contains(tool.name) { continue }
            if credentialModuleGateActive(for: tool) { continue }
            if enabled { disabledTools.remove(tool.name) }
            else { disabledTools.insert(tool.name) }
            onToggle(tool.name, enabled)
        }
        persistDisabledTools()
    }

    private func credentialModuleGateActive(for tool: ToolInfo) -> Bool {
        tool.module == "credential" && !CredentialsFeature.isEnabled
    }

    private func effectiveToolEnabled(_ tool: ToolInfo) -> Bool {
        guard !disabledTools.contains(tool.name) else { return false }
        if credentialModuleGateActive(for: tool) { return false }
        return true
    }

    private func enabledCount(in tools: [ToolInfo]) -> Int {
        tools.filter { effectiveToolEnabled($0) }.count
    }

    private func persistDisabledTools() {
        UserDefaults.standard.set(Array(disabledTools), forKey: BridgeDefaults.disabledTools)
    }

    /// Persist tier overrides to UserDefaults.
    private func persistTierOverrides() {
        UserDefaults.standard.set(tierOverrides, forKey: BridgeDefaults.tierOverrides)
    }

    /// A single revocable module-scoped "Always Allow" grant.
    @ViewBuilder
    private func moduleGrantRow(_ module: String) -> some View {
        let tier = moduleTierOverrides[module] ?? SecurityTier.notify.rawValue
        BridgeListRow(
            title: displayName(for: module),
            subtitle: "Covers every \(displayName(for: module)) tool",
            systemImage: "checkmark.shield",
            trailing: {
                BridgeTierPill(uiTier(tier))
                BridgeButton("Revoke", variant: .danger) {
                    revokeModuleGrant(module)
                }
            }
        )
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BridgeTokens.wellFill)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5)))
    }

    /// Revoke ONE module grant; sibling tools fall back to their per-tool
    /// override (if any) or their registered default.
    private func revokeModuleGrant(_ module: String) {
        moduleTierOverrides.removeValue(forKey: module)
        persistModuleTierOverrides()
        NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
    }

    /// Persist module grants; remove the key entirely when empty so an absent
    /// key keeps meaning "no module overrides" (matches `ToolRouter`'s read).
    private func persistModuleTierOverrides() {
        if moduleTierOverrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.moduleTierOverrides)
        } else {
            UserDefaults.standard.set(moduleTierOverrides, forKey: BridgeDefaults.moduleTierOverrides)
        }
    }
}
