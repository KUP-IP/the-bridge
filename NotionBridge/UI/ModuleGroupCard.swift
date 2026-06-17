// ModuleGroupCard.swift — PKT-877 · v4 Tools-page table (feat/v4-redesign)
// NotionBridge · UI
//
// The LIVE Tools page: `ModuleGroupList` — the v4 database/table view that
// renders one `BridgeToolTable` per super-section (Mac & system, Apple apps,
// Web & data, Local dev, Bridge), each holding a stack of family disclosure
// rows (`BridgeToolGroupRow`) that expand to per-tool rows (`BridgeToolRow`)
// with an editable Open·Notify·Confirm tier pill (`BridgeTierPill`) and an
// enable toggle. Faithful port of `design/.../pages/page-tools.jsx`:
//   .searchf + .seg subtle  → search well + BridgeSegmented family filter
//   .tile (Enabled/Families) → BridgeStatStrip + BridgeStatTile (live counts)
//   .card-label super-section → bridgeCap() label + mono · count
//   .tbl / .trow / .tier-pill / .toggle → BridgeToolTable/Group/Row + BridgeTierPill
//   .tl-warn unmet-dependency  → BridgeBanner(.warn) with a Fix dep-link
// Counts bind to the ACTUAL registry (never the design-time "209 / 29").
//
// Wiring: instantiated by `SettingsWindow+Sections.swift::toolsSection`
// (the off-limits composite). Per-tool/family toggles persist to
// `BridgeDefaults.disabledTools`; tier cycles to `BridgeDefaults.tierOverrides`
// + `.moduleTierOverrides`, posting `.notionBridgeTierOverridesDidChange`.
//
// W4 history: replaced the pre-v4 grouped-glass-card stack (`ModuleGroupCard`)
// and the flat per-module `ToolRegistryView`, both retired in the v4 resurface
// once the table became the single live surface (QA: zero instantiations).

import SwiftUI

// MARK: - Full grouped list

/// The Tools database/table view. Builds the per-section `BridgeToolTable`
/// stack from the live tool list + the user's per-tool disabled set, and
/// writes per-tool toggles back to `BridgeDefaults.disabledTools`.
public struct ModuleGroupList: View {
    let tools: [ToolInfo]
    @ObservedObject var nav: SettingsNavigation

    @State private var disabledTools: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? []
    )
    /// Per-tool gate overrides (BridgeDefaults.tierOverrides) — restored so the
    /// grouped Tools page can manage security gates again.
    @State private var tierOverrides: [String: String] =
        (UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides) as? [String: String]) ?? [:]
    /// Per-module "Always Allow" grants (BridgeDefaults.moduleTierOverrides).
    @State private var moduleTierOverrides: [String: String] =
        (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]

    /// v4 database view: which family rows are expanded (by group id). Seeded
    /// from the persisted `moduleGroupExpanded` default so a family the operator
    /// left open stays open across launches — the per-card expand state the
    /// pre-v4 `ModuleGroupCard` stack persisted, carried into the table.
    @State private var expandedGroups: Set<ModuleGroupID> = ModuleGroupList.seedExpanded()
    /// v4 search box — narrows the visible families/tools by name + description.
    /// Pure view-side filter; no controller/persistence wiring touched.
    @State private var searchText: String = ""
    /// v4 family-category filter ("All" + the design's super-sections). Pure
    /// view-side; derived category labels, never persisted.
    @State private var categoryFilter: String = ToolFamilyCategory.allLabel
    /// (PKT-1006 R2) The tool to flash when arrived-at via a Command Bridge
    /// deep-link ("group:tool" anchor). Cleared after a beat.
    @State private var deepLinkedTool: String?

    public init(tools: [ToolInfo], nav: SettingsNavigation = .shared) {
        self.tools = tools
        self.nav = nav
    }

    /// Seed the expanded-family set from the persisted per-group expand map,
    /// so families the operator left open survive a relaunch (mirrors the old
    /// `ModuleGroupCard.savedExpandState`). Closed/absent → collapsed.
    private static func seedExpanded() -> Set<ModuleGroupID> {
        let dict = UserDefaults.standard
            .dictionary(forKey: BridgeDefaults.moduleGroupExpanded) ?? [:]
        var open: Set<ModuleGroupID> = []
        for (key, value) in dict {
            if (value as? Bool) == true, let id = ModuleGroupID(rawValue: key) {
                open.insert(id)
            }
        }
        return open
    }

    /// Toggle + persist a family's expand state (same `moduleGroupExpanded`
    /// dictionary key the pre-v4 card stack wrote, so expand state is shared).
    private func toggleExpanded(_ id: ModuleGroupID) {
        let nowOpen: Bool
        if expandedGroups.contains(id) { expandedGroups.remove(id); nowOpen = false }
        else { expandedGroups.insert(id); nowOpen = true }
        var dict = UserDefaults.standard
            .dictionary(forKey: BridgeDefaults.moduleGroupExpanded) ?? [:]
        dict[id.rawValue] = nowOpen
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.moduleGroupExpanded)
    }

    /// Tool name → description lookup, derived from the live `ToolInfo`
    /// list once per render. Avoids recomputing inside each row.
    private var descriptions: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.description) })
    }

    /// Tool name → EFFECTIVE security tier (per-tool override > module grant >
    /// registered default), feeding the interactive per-row gate pill. Uses the
    /// shared ToolTierResolution so the UI can never disagree with the router.
    private var tiers: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { tool in
            (tool.name, ToolTierResolution.effectiveTier(
                toolName: tool.name,
                module: tool.module,
                registeredTier: tool.tier,
                toolOverrides: tierOverrides,
                moduleOverrides: moduleTierOverrides))
        })
    }

    /// Tool name → (module, registered tier) for cycle/base resolution.
    private var toolMeta: [String: (module: String, registered: String)] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.name, ($0.module, $0.tier)) })
    }

    private func nextTier(after current: String) -> String {
        switch current {
        case "open": return "notify"
        case "notify": return "request"
        default: return "open"
        }
    }

    /// Cycle a tool's security gate and persist. Landing back on the tool's base
    /// (its module grant if one exists, else the registered default) clears the
    /// per-tool override so it follows the grant/default. Mirrors the legacy
    /// ToolRegistryView behaviour and posts the same change notification so the
    /// router + other surfaces pick it up live.
    private func cycleTier(_ toolName: String) {
        guard let meta = toolMeta[toolName] else { return }
        let current = ToolTierResolution.effectiveTier(
            toolName: toolName, module: meta.module, registeredTier: meta.registered,
            toolOverrides: tierOverrides, moduleOverrides: moduleTierOverrides)
        let base = moduleTierOverrides[meta.module] ?? meta.registered
        let next = nextTier(after: current)
        if next == base {
            tierOverrides.removeValue(forKey: toolName)
        } else {
            tierOverrides[toolName] = next
        }
        UserDefaults.standard.set(tierOverrides, forKey: BridgeDefaults.tierOverrides)
        NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
    }

    /// The representative tier for a family pill: the MOST-SEVERE effective tier
    /// across the family's tools (Confirm > Notify > Open), so the family pill
    /// communicates the strongest gate any member runs at. Display-only — the
    /// family pill is not interactive (a family-wide tier write isn't part of the
    /// model); per-tool pills remain the editable control via `cycleTier`.
    private func familyTier(for group: ModuleGroup) -> BridgeTier {
        var strongest: BridgeTier = .open
        for name in group.tools {
            let raw = tiers[name] ?? "open"
            let t = BridgeTier(rawValue: raw) ?? .open
            if severity(t) > severity(strongest) { strongest = t }
        }
        return strongest
    }
    private func severity(_ t: BridgeTier) -> Int {
        switch t { case .open: return 0; case .notify: return 1; case .confirm: return 2 }
    }

    /// A `.bad`-severity dependency means a required permission/credential is
    /// missing — surfaces the family's "grant access" banner (parity with the
    /// pre-v4 `ModuleGroupCard.unmetDependency`).
    private func unmetDependency(for group: ModuleGroup) -> ModuleGroupDependency? {
        group.dependencies.first { $0.severity == .bad }
    }

    private var groups: [ModuleGroup] {
        // Display the grouped cards alphabetically by group name (case-
        // insensitive), mirroring the legacy ToolRegistryView's
        // `dict.keys.sorted()`. The dispatch-side `deriveGroups` order is
        // left untouched (it feeds the safety gate); only the UI list sorts.
        ModuleGroupDerivation.deriveGroups(
            registeredToolNames: tools.map(\.name),
            disabledNames: disabledTools
        )
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // ── v4 derived view-model ──

    /// Live total / active / family counts — bound to the ACTUAL registry, never
    /// the design-time "209 / 29". Active = registered minus disabled.
    private var totalCount: Int { tools.count }
    private var activeCount: Int {
        totalCount - disabledTools.intersection(tools.map(\.name)).count
    }
    private var familyCount: Int { groups.count }

    /// The category filter segments: "All" + every category that actually has a
    /// family present in the live registry (so an empty category never shows).
    private var categorySegments: [String] {
        let present = ToolFamilyCategory.allCases.filter { cat in
            groups.contains { ToolFamilyCategory.category(for: $0.id) == cat }
        }
        return [ToolFamilyCategory.allLabel] + present.map(\.label)
    }

    /// Groups after the search + category filter. Search matches a family name,
    /// its subtitle, or any member tool name/description (so a tool search keeps
    /// its family visible). Category narrows to the chosen super-section.
    private var visibleGroups: [ModuleGroup] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return groups.filter { group in
            if categoryFilter != ToolFamilyCategory.allLabel,
               ToolFamilyCategory.category(for: group.id).label != categoryFilter {
                return false
            }
            guard !q.isEmpty else { return true }
            if group.displayName.lowercased().contains(q) { return true }
            if group.subtitle.lowercased().contains(q) { return true }
            return group.tools.contains { name in
                name.lowercased().contains(q)
                    || (descriptions[name] ?? "").lowercased().contains(q)
            }
        }
    }

    /// Visible groups bucketed by category, in the declared category order, so
    /// the table mirrors the design's super-section grouping ("Mac & system" …).
    private var sectionedGroups: [(category: ToolFamilyCategory, groups: [ModuleGroup])] {
        let vis = visibleGroups
        return ToolFamilyCategory.allCases.compactMap { cat in
            let members = vis.filter { ToolFamilyCategory.category(for: $0.id) == cat }
            return members.isEmpty ? nil : (cat, members)
        }
    }

    /// When searching, a family with a query hit shows only its matching tools;
    /// otherwise all of the family's tools. Keeps a tool-name search legible.
    private func visibleTools(in group: ModuleGroup) -> [String] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return group.tools }
        // If the family itself matched by name/subtitle, show all its tools.
        if group.displayName.lowercased().contains(q)
            || group.subtitle.lowercased().contains(q) { return group.tools }
        let hits = group.tools.filter {
            $0.lowercased().contains(q) || (descriptions[$0] ?? "").lowercased().contains(q)
        }
        return hits.isEmpty ? group.tools : hits
    }

    // ── Layout ──

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: BridgeTokens.Space.s5) {
                    pageHead
                    filterBar
                    if sectionedGroups.isEmpty {
                        BridgeEmptyStateView(
                            systemImage: "magnifyingglass",
                            title: "No tools match",
                            message: "No family or tool matches your search and filter. Clear them to see the full surface.")
                    } else {
                        ForEach(sectionedGroups, id: \.category) { section in
                            categorySection(section.category, groups: section.groups)
                        }
                    }
                }
                .padding(.vertical, BridgeTokens.Space.paneV)
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Deep-link: expand + scroll the chip's target family into view. Fires
            // on first appear (chip tapped from another page) and on every later
            // anchor change (operator already on Tools). The anchor is cleared
            // after consuming so re-selecting the same chip re-triggers.
            .onAppear { scrollToAnchorIfNeeded(proxy) }
            .onChange(of: nav.anchor) { _, _ in scrollToAnchorIfNeeded(proxy) }
        }
        // Live external edits to the disabled set (e.g. SecurityGate "Always
        // Allow" or another surface) reflect here.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )) { _ in
            let fresh = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
            if fresh != disabledTools { disabledTools = fresh }
        }
        // Live external edits to the tier overrides keep the pills accurate.
        .onReceive(NotificationCenter.default.publisher(
            for: .notionBridgeTierOverridesDidChange
        )) { _ in
            tierOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides) as? [String: String]) ?? [:]
            moduleTierOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]
        }
    }

    /// Page header: title + supporting copy, with the live stat strip
    /// (enabled/total · families) on the trailing edge. Counts come from the
    /// real registry — never the design-time "209 / 29 families".
    private var pageHead: some View {
        HStack(alignment: .top, spacing: BridgeTokens.Space.s4) {
            BridgeListIconTile(systemImage: "wrench.and.screwdriver.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text("Tools")
                    .font(BridgeTokens.Typeface.onb)
                    .foregroundStyle(BridgeTokens.fg1)
                Text("Per-family and per-tool control across the full surface. Set the security tier each tool runs at.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            BridgeStatStrip(spacing: BridgeTokens.Space.s3) {
                BridgeStatTile(value: "\(activeCount)/\(totalCount)", label: "Enabled", signal: .ok)
                BridgeStatTile(value: "\(familyCount)", label: "Families", signal: .info)
            }
            .fixedSize()
        }
    }

    /// Search field + family-category segmented filter (design's `.searchf` +
    /// `.seg`). Both are pure view-side controls — no controller wiring.
    private var filterBar: some View {
        HStack(spacing: BridgeTokens.Space.s3) {
            HStack(spacing: BridgeTokens.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg5)
                TextField("Search \(totalCount) tools…", text: $searchText)
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
            .padding(.horizontal, BridgeTokens.Space.s3)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(searchWell)

            BridgeSegmented(
                selection: $categoryFilter,
                options: categorySegments.map { ($0, $0) }
            )
            .fixedSize()
        }
    }

    private var searchWell: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
        return shape
            .fill(BridgeTokens.wellFill)
            .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    /// One super-section: an UPPERCASE category label (with a mono live family
    /// count) over a single `BridgeToolTable` holding that category's families.
    @ViewBuilder
    private func categorySection(_ category: ToolFamilyCategory,
                                 groups sectionGroups: [ModuleGroup]) -> some View {
        VStack(alignment: .leading, spacing: BridgeTokens.Space.s2) {
            HStack(spacing: 6) {
                Text(category.label).bridgeCap()
                    .foregroundStyle(BridgeTokens.fg4)
                Text("· \(sectionGroups.count)")
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg5)
            }
            // design `.card-label` left nudge (margin '4px 2px 8px').
            .padding(.leading, 2)

            BridgeToolTable(columns: ["Family · tool", "On", "Tier", ""]) {
                ForEach(sectionGroups) { group in
                    familyGroup(group)
                        // Scroll/expand anchor — the resolved group id, so the
                        // deep-link can jump straight to the family.
                        .id(group.id)
                }
            }
        }
    }

    /// One family disclosure row + (when expanded) its per-tool rows, built from
    /// the W2 table primitives. Master toggle, count, family tier pill, per-tool
    /// tier pills + toggles all bind to the SAME wiring the card stack used.
    @ViewBuilder
    private func familyGroup(_ group: ModuleGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        BridgeToolGroup(
            isExpanded: isExpanded,
            header: BridgeToolGroupRow(
                name: group.displayName,
                desc: group.subtitle,
                systemImage: group.systemImage,
                isExpanded: isExpanded,
                activeCount: group.enabledCount,
                totalCount: group.total,
                tier: familyTier(for: group),
                isOn: Binding(
                    get: { group.masterState != .off },
                    set: { setGroupEnabled(group, enabled: $0) }
                ),
                onToggleExpand: { toggleExpanded(group.id) }
                // Family tier pill is display-only (no `onTierTap`): a family-wide
                // tier write isn't part of the model. Per-tool pills are editable.
            )
        ) {
            // Unmet-dependency guard: when an enabled family needs a permission /
            // credential it doesn't have, surface the "grant access" banner the
            // pre-v4 card carried — tapping it routes via `handleDepLink`. Keeps
            // the cross-page fix flow the redesign would otherwise drop.
            if let dep = unmetDependency(for: group), group.masterState != .off {
                BridgeBanner(
                    signal: .warn,
                    message: "Enabled, but won't function until you grant \(dep.label).",
                    systemImage: "exclamationmark.triangle"
                ) {
                    Button("Fix") { handleDepLink(dep) }
                        .buttonStyle(.plain)
                        .font(BridgeTokens.Typeface.meta.weight(.semibold))
                        .foregroundStyle(BridgeTokens.warnText)
                }
                .padding(.horizontal, BridgeToolTableMetrics.hPad)
                .padding(.top, BridgeTokens.Space.s3)
                .padding(.bottom, 2)
            }
            ForEach(visibleTools(in: group), id: \.self) { name in
                BridgeToolRow(
                    name: name,
                    desc: descriptions[name] ?? "",
                    tier: BridgeTier(rawValue: tiers[name] ?? "open") ?? .open,
                    isOn: Binding(
                        get: { !group.disabledNames.contains(name) },
                        set: { setEnabled(name, $0) }
                    ),
                    onTierTap: { cycleTier(name) }
                )
                // (PKT-1006 R2) Per-tool scroll anchor + arrival highlight, so a
                // Command Bridge Tool result can deep-link to the exact tool row
                // (not just its family) — ready to toggle / set its gate.
                .id(Self.toolAnchorID(name))
                .background(
                    RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                        .fill(deepLinkedTool == name ? BridgeTokens.accent.opacity(0.14) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                        .strokeBorder(deepLinkedTool == name ? BridgeTokens.accent.opacity(0.4) : Color.clear,
                                      lineWidth: 1)
                )
            }
        }
    }

    /// The `ModuleGroupID` a Tools dep-link chip's `anchor` targets, resolved
    /// against the live tool list. Drives the deep-link expand + scroll.
    private var anchoredGroupID: ModuleGroupID? {
        ModuleGroupDerivation.groupID(
            forAnchor: nav.anchor,
            registeredTools: tools.map { (name: $0.name, module: $0.module) }
        )
    }

    /// Stable per-tool scroll id for a Command Bridge Tool deep-link.
    private static func toolAnchorID(_ name: String) -> String { "tool.\(name)" }

    /// Parse a Command Bridge Tool anchor of the form "group:tool" → the tool
    /// name (if it resolves to a live registered tool). Returns nil for the
    /// legacy chip anchors (a bare module/group id), which are handled by
    /// `anchoredGroupID`.
    private var anchoredToolName: String? {
        guard let raw = nav.anchor?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.contains(":") else { return nil }
        let toolPart = String(raw.split(separator: ":", maxSplits: 1).last ?? "")
        guard !toolPart.isEmpty,
              tools.contains(where: { $0.name == toolPart }) else { return nil }
        return toolPart
    }

    /// Expand + scroll the anchored target into view, then clear the consumed
    /// anchor so the same chip can re-trigger later. Handles BOTH the Command
    /// Bridge "group:tool" deep-link (R2 — expand the family + scroll to the
    /// exact tool row + flash it) AND the legacy family-only chip anchors. No-op
    /// when the anchor maps to nothing on-screen.
    private func scrollToAnchorIfNeeded(_ proxy: ScrollViewProxy) {
        // 1) Command Bridge tool deep-link ("group:tool") — land on the exact tool.
        if let toolName = anchoredToolName {
            let groupID = ModuleGroupDerivation.resolve(toolName: toolName)
            // Clear any view-side filter that would hide the tool's family/row.
            if categoryFilter != ToolFamilyCategory.allLabel {
                categoryFilter = ToolFamilyCategory.allLabel
            }
            if !searchText.isEmpty { searchText = "" }
            expandedGroups.insert(groupID)
            deepLinkedTool = toolName
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(Self.toolAnchorID(toolName), anchor: .center)
                }
                nav.anchor = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if deepLinkedTool == toolName {
                    withAnimation(.easeOut(duration: 0.4)) { deepLinkedTool = nil }
                }
            }
            return
        }
        // 2) Legacy family-only chip anchor — expand + scroll the family.
        guard let target = anchoredGroupID else { return }
        // Land the operator on an OPEN family (matches the pre-v4 forceExpanded).
        expandedGroups.insert(target)
        // A tiny hop lets the ForEach lay out the rows before we scroll.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
            nav.anchor = nil
        }
    }

    // MARK: Mutators

    private func setEnabled(_ name: String, _ enabled: Bool) {
        if enabled { disabledTools.remove(name) } else { disabledTools.insert(name) }
        persistDisabled()
    }

    private func setGroupEnabled(_ group: ModuleGroup, enabled: Bool) {
        if enabled {
            disabledTools.subtract(group.tools)
        } else {
            disabledTools.formUnion(group.tools)
        }
        persistDisabled()
    }

    private func persistDisabled() {
        UserDefaults.standard.set(Array(disabledTools), forKey: BridgeDefaults.disabledTools)
    }

    private func handleDepLink(_ dep: ModuleGroupDependency) {
        // PKT-A: the legacy routes now fold into the merged sections —
        // Permissions → Security/Gates · Credentials → Security/Vault ·
        // Connections → Connection/Local.
        switch dep.route {
        case "permissions":  nav.go(.security, anchor: "gates")
        case "credentials":  nav.go(.security, anchor: "vault")
        case "connections":  nav.go(.connection, anchor: "local")
        default: break
        }
    }
}

// MARK: - Family categories (the design's super-sections)

/// The design groups families under super-section labels ("Mac & system",
/// "Apple apps", "Web & data", "Local dev", "Bridge"). The live `ModuleGroup`
/// model has no category, so this maps each `ModuleGroupID` to its section —
/// the labels + filter segments come from here, but every COUNT (families,
/// tools, enabled) is bound to the live registry, never the design-time totals.
enum ToolFamilyCategory: String, CaseIterable, Hashable {
    case macSystem
    case appleApps
    case webData
    case localDev
    case bridge

    static let allLabel = "All"

    var label: String {
        switch self {
        case .macSystem: return "Mac & system"
        case .appleApps: return "Apple apps"
        case .webData:   return "Web & data"
        case .localDev:  return "Local dev"
        case .bridge:    return "Bridge"
        }
    }

    /// Map a family id to its super-section. Mirrors the design's grouping;
    /// anything new falls into `.macSystem` (the system catch-all's home).
    static func category(for id: ModuleGroupID) -> ToolFamilyCategory {
        switch id {
        case .file, .shell, .accessibility, .screen, .synthetic, .clipboard,
             .system, .applescript, .bgProcess:
            return .macSystem
        case .messages, .notes, .contacts, .reminders, .calendar:
            return .appleApps
        case .notion, .chrome, .http, .connections, .stripe, .payment, .credential:
            return .webData
        case .git, .gh, .lsp, .devserver:
            return .localDev
        case .skills, .jobs, .memory, .snippets:
            return .bridge
        }
    }
}
