// ModuleGroupCard.swift — PKT-877 (Bridge v3.6·2)
// NotionBridge · UI
//
// The Tools-page grouped card. One card per ModuleGroup; renders the
// master toggle (PartialToggle), dep-link chips (BridgeDepLink), the
// partial-state count badge, and (when expanded) the per-tool toggles.
//
// Visual language: `BridgeGlassCard` shell + the colour tokens from the
// locked `design/tools.html` mock. The per-tool list is kept lean — only
// monospaced name + one-line description + a small toggle — so the page
// can scroll the full 162-tool surface without paging.
//
// W4 wiring: `ModuleGroupList` replaces the flat-toggle list inside
// `SettingsWindow+Sections.swift::toolsSection`.

import SwiftUI

// MARK: - Helpers

/// Bridge between the core `TripleStateLike` (which Core/ModuleGroup uses
/// because it cannot import SwiftUI) and the SwiftUI-side `TripleState`
/// from BridgeThemeV2. Centralised here so the rest of the UI only sees
/// `TripleState`.
extension TripleStateLike {
    fileprivate var ui: TripleState {
        switch self {
        case .off:     return .off
        case .partial: return .partial
        case .on:      return .on
        }
    }
}

// MARK: - Per-tool row

private struct ModuleGroupToolRow: View {
    let toolName: String
    let description: String
    /// EFFECTIVE security tier ("open" / "notify" / "request"), incl. per-tool
    /// and module-grant overrides. Drives the interactive gate pill below.
    let tier: String?
    /// Cycle this tool's security gate (Open → Notify → Request → Open).
    let onTierTap: () -> Void
    @Binding var isEnabled: Bool

    /// Label + colours for the current effective security gate. Restores the
    /// 3-state control (Open/Notify/Request) the flat ToolRegistryView had
    /// before the grouped-card redesign dropped it to a static "confirm" pill.
    private var tierTriple: (label: String, bg: Color, stroke: Color, fg: Color) {
        switch (tier ?? "open") {
        case "request": return ("REQUEST", BridgeTokens.bad.opacity(0.16), BridgeTokens.bad.opacity(0.30), BridgeTokens.badText)
        case "notify":  return ("NOTIFY",  BridgeTokens.warn.opacity(0.16), BridgeTokens.warn.opacity(0.30), BridgeTokens.warnText)
        default:        return ("OPEN",    BridgeTokens.ok.opacity(0.14),   BridgeTokens.ok.opacity(0.28),   BridgeTokens.okText)
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            // Status glyph — 7px filled dot with an emerald glow when on,
            // dim when off (design `.tl-glyph.on` / `.off`).
            Circle()
                .fill(isEnabled ? BridgeTokens.ok
                                : BridgeTokens.fg5)
                .frame(width: 7, height: 7)
                .shadow(color: isEnabled ? BridgeTokens.ok.opacity(0.6) : .clear,
                        radius: 2.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolName)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg1)
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Truncate-with-reveal (density tenet): the full
                        // description surfaces on hover rather than wrapping.
                        .help(description)
                }
            }
            Spacer(minLength: 8)

            // Interactive security-gate pill: tap to cycle Open → Notify →
            // Request. Restores the per-tool gate control lost in the
            // grouped-card redesign (was a static, non-tappable "confirm" pill).
            Button(action: onTierTap) {
                Text(tierTriple.label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tierTriple.bg, in: Capsule())
                    .overlay(Capsule().strokeBorder(tierTriple.stroke, lineWidth: 0.5))
                    .foregroundStyle(tierTriple.fg)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .help("Security gate — tap to cycle Open → Notify → Request")
            // VoiceOver: expose the gate as its own operable element with a
            // value + cycle action, so the tier is both audible and changeable
            // (the row's combined element otherwise drops it). a11y label binds
            // the tool name per the legibility/accessibility floor.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(toolName) security gate")
            .accessibilityValue(tierTriple.label.capitalized)
            .accessibilityHint("Cycles Open, Notify, Request")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTierTap() }

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .tint(BridgeTokens.ok)
                .controlSize(.mini)
                .labelsHidden()
                // Bind the tool name as the switch's a11y label (the row's
                // .contain element no longer narrates it for this control).
                .accessibilityLabel("\(toolName) enabled")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(isEnabled ? 1.0 : 0.52)
        // Full-row hit-test target (token-hygiene: no raw Color.white —
        // contentShape gives the hover/tap area without a painted fill).
        .contentShape(Rectangle())
        // Keep the tool name/switch as a group but DON'T collapse children,
        // so the tier chip's own a11y element + cycle action stay operable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(toolName) — \(isEnabled ? "enabled" : "disabled")")
    }
}

// MARK: - Group card

/// One module group rendered as a collapsible glass card. Master toggle
/// cycles per-tool state for ALL members in the group; the partial chip
/// shows "N of M enabled" when at least one member is in a different
/// state from its siblings.
public struct ModuleGroupCard: View {
    public let group: ModuleGroup
    public let toolDescriptions: [String: String]
    public let toolTiers: [String: String]
    public let onPerToolChange: (String, Bool) -> Void
    public let onMasterChange: (Bool) -> Void
    public let onDepLinkTapped: (ModuleGroupDependency) -> Void
    /// Cycle a member tool's security gate (Open → Notify → Request).
    public let onTierTap: (String) -> Void

    /// Deep-link auto-expand signal. `true` when this card is the target of a
    /// Tools dep-link chip (its group == the resolved anchor); the card expands
    /// itself so the operator lands on an OPEN card, not a collapsed one. Driven
    /// by `ModuleGroupList` off `SettingsNavigation.anchor`. Default `false`
    /// preserves the persisted-expand cold-launch behaviour for every other card.
    public let forceExpanded: Bool

    @State private var isExpanded: Bool

    /// v3.6.0 D6: per-group expand state persists in BridgeDefaults
    /// (`moduleGroupExpanded` dictionary keyed by group id). Cold-launch
    /// default is collapsed for every group — the previous "expanded if
    /// any tool on" rule made the page a wall-of-toggles for users with
    /// most modules enabled. Off groups still auto-collapse on each load
    /// regardless of the saved value (DoD invariant).
    public init(
        group: ModuleGroup,
        toolDescriptions: [String: String],
        toolTiers: [String: String] = [:],
        forceExpanded: Bool = false,
        onPerToolChange: @escaping (String, Bool) -> Void,
        onMasterChange: @escaping (Bool) -> Void,
        onDepLinkTapped: @escaping (ModuleGroupDependency) -> Void,
        onTierTap: @escaping (String) -> Void
    ) {
        self.group = group
        self.toolDescriptions = toolDescriptions
        self.toolTiers = toolTiers
        self.forceExpanded = forceExpanded
        self.onPerToolChange = onPerToolChange
        self.onMasterChange = onMasterChange
        self.onDepLinkTapped = onDepLinkTapped
        self.onTierTap = onTierTap
        let saved = ModuleGroupCard.savedExpandState(forGroupId: group.id.rawValue)
        let initial: Bool = {
            // Deep-link target → start expanded so the chip lands on an open card.
            if forceExpanded { return true }
            // Off groups always collapse, regardless of saved state.
            if group.masterState == .off { return false }
            // Use saved value if present, otherwise default to collapsed.
            return saved ?? false
        }()
        self._isExpanded = State(initialValue: initial)
    }

    private static func savedExpandState(forGroupId id: String) -> Bool? {
        let dict = UserDefaults.standard
            .dictionary(forKey: BridgeDefaults.moduleGroupExpanded) ?? [:]
        return dict[id] as? Bool
    }

    private static func persistExpandState(forGroupId id: String, expanded: Bool) {
        var dict = UserDefaults.standard
            .dictionary(forKey: BridgeDefaults.moduleGroupExpanded) ?? [:]
        dict[id] = expanded
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.moduleGroupExpanded)
    }

    /// A `.bad`-severity dependency means a required permission/credential is
    /// missing — surface the design's amber `.tl-warn` banner so the operator
    /// knows the enabled tools won't function until it's granted.
    private var unmetDependency: ModuleGroupDependency? {
        group.dependencies.first { $0.severity == .bad }
    }

    public var body: some View {
        BridgeGlassCard(cornerRadius: 12, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    if !group.dependencies.isEmpty {
                        depChipRow
                    }
                    Divider().background(BridgeTokens.hairlineFaint)
                    if let dep = unmetDependency, group.masterState != .off {
                        warnBanner(for: dep)
                    }
                    toolList
                }
            }
        }
        .opacity(group.masterState == .off ? 0.62 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: group.masterState)
        // Deep-link: when this card becomes the chip target while already
        // on-screen (e.g. the operator was already on Tools), expand it.
        .onChange(of: forceExpanded) { _, nowTarget in
            if nowTarget && !isExpanded {
                isExpanded = true
                ModuleGroupCard.persistExpandState(forGroupId: group.id.rawValue, expanded: true)
            }
        }
    }

    private func warnBanner(for dep: ModuleGroupDependency) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(BridgeTokens.warnText)
            (Text("Tools are enabled but won't function until you grant ")
                + Text("\(dep.label).").foregroundColor(BridgeTokens.warnText))
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.warnText.opacity(0.92))
            Spacer(minLength: 0)
            BridgeDepLink(dep.label,
                          variant: .info,
                          action: { onDepLinkTapped(dep) })
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(BridgeTokens.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(BridgeTokens.warn.opacity(0.26), lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                HStack(spacing: 6) {
                    countBadge
                    Text(group.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)

            chevron

            PartialToggle(state: Binding(
                get: { group.masterState.ui },
                set: { newState in
                    // PartialToggle cycles: partial → on, on → off, off → on.
                    // Propagate the user's intent as a uniform on/off for
                    // every member; the partial state itself is derived
                    // and never the *target* of a write.
                    onMasterChange(newState == .on)
                }
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
            ModuleGroupCard.persistExpandState(
                forGroupId: group.id.rawValue,
                expanded: isExpanded
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.displayName) tool group, \(group.enabledCount) of \(group.total) enabled, " +
            (isExpanded ? "expanded" : "collapsed")
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Per-group accent — the design's `acc-*` icon-tile tint. Drawn ONLY
    /// from the canonical BridgeTokens (no raw colours); each module maps to
    /// the nearest signal/accent token so the registry reads as a colour-
    /// coded surface, matching the locked mock's hue-per-source treatment.
    private var accent: Color {
        switch group.id {
        case .file, .git, .gh, .snippets, .lsp:                 return BridgeTokens.okText
        case .notion, .contacts, .connections, .http, .devserver: return BridgeTokens.accentLink
        case .messages, .reminders, .calendar, .notes:          return BridgeTokens.warnText
        case .screen, .applescript, .shell, .synthetic, .bgProcess: return BridgeTokens.badText
        case .chrome, .accessibility, .clipboard, .system:      return BridgeTokens.accentLink
        case .stripe, .payment, .credential:                    return BridgeTokens.gold
        case .skills, .jobs, .memory:                           return BridgeTokens.gold
        }
    }

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(accent.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
            )
            .overlay(
                // top rim highlight — matches the design's inset sheen.
                // Token-hygiene: hairlineStrong is white@0.16 on carbon (≈ the
                // prior 0.18 literal) and a subtle dark edge on titanium, so the
                // sheen reads in BOTH themes instead of vanishing on light.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(
                        LinearGradient(colors: [BridgeTokens.hairlineStrong, .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .overlay(
                Image(systemName: group.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            )
            .frame(width: 30, height: 30)
    }

    private var countBadge: some View {
        // Compact `N/M` glyph (was the verbose "N of M active") so the header
        // stays legible at half-width in the 2-up grid; colour already encodes
        // active vs partial vs off, and the master toggle echoes it. The word
        // "active"/"of" are dropped — the colour + slash carry the meaning.
        let label: String
        let bg: Color
        let stroke: Color
        let fg: Color
        switch group.masterState {
        case .on:
            label = "\(group.total)/\(group.total)"
            bg = BridgeTokens.ok.opacity(0.14)
            stroke = BridgeTokens.ok.opacity(0.28)
            fg = BridgeTokens.okText
        case .off:
            label = "0/\(group.total)"
            bg = BridgeTokens.chipFill
            stroke = BridgeTokens.hairline
            fg = BridgeTokens.fg3
        case .partial:
            label = "\(group.enabledCount)/\(group.total)"
            bg = BridgeTokens.warn.opacity(0.14)
            stroke = BridgeTokens.warn.opacity(0.28)
            fg = BridgeTokens.warnText
        }
        return Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(bg, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            .foregroundStyle(fg)
            .monospacedDigit()
            .fixedSize()
            .help("\(group.enabledCount) of \(group.total) tools active")
            .accessibilityHidden(true)  // header element narrates the full count
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BridgeTokens.fg4)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
    }

    private var depChipRow: some View {
        HStack(spacing: 6) {
            Text("depends on")
                .font(.system(size: 11))
                .foregroundStyle(BridgeTokens.fg4)
            ForEach(group.dependencies, id: \.self) { dep in
                BridgeDepLink(
                    dep.label,
                    variant: dep.severity == .bad ? .bad : .info,
                    action: { onDepLinkTapped(dep) }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var toolList: some View {
        VStack(spacing: 1) {
            ForEach(group.tools, id: \.self) { toolName in
                ModuleGroupToolRow(
                    toolName: toolName,
                    description: toolDescriptions[toolName] ?? "",
                    tier: toolTiers[toolName],
                    onTierTap: { onTierTap(toolName) },
                    isEnabled: Binding(
                        get: { !group.disabledNames.contains(toolName) },
                        set: { onPerToolChange(toolName, $0) }
                    )
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Full grouped list

/// Replaces the flat 162-toggle `ToolRegistryView`. Builds the grouped
/// card stack from the live tool list + the user's per-tool disabled set,
/// and writes per-tool toggles back to `BridgeDefaults.disabledTools`.
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
            HStack(spacing: 8) {
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
            .padding(.horizontal, 10)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(category.label).bridgeCap()
                    .foregroundStyle(BridgeTokens.fg4)
                Text("· \(sectionGroups.count)")
                    .font(BridgeTokens.Typeface.mono)
                    .foregroundStyle(BridgeTokens.fg5)
            }
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
                .padding(.top, 10)
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

    /// Expand + scroll the anchored family to the top, then clear the consumed
    /// anchor so the same chip can re-trigger later. No-op when the anchor maps
    /// to no on-screen family (e.g. an orphaned-credential chip).
    private func scrollToAnchorIfNeeded(_ proxy: ScrollViewProxy) {
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
