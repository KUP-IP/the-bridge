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
    /// Registered security tier ("open" / "notify" / "request"). Drives the
    /// "confirm" tier pill the design shows for tools that prompt before
    /// running. `nil`/"open" renders no pill.
    let tier: String?
    @Binding var isEnabled: Bool

    /// The design's `.tl-pill.confirm` — anything past the plain `open`
    /// tier confirms / notifies before dispatch.
    private var isConfirmTier: Bool {
        guard let tier else { return false }
        return tier != "open"
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
                }
            }
            Spacer(minLength: 8)

            // Tier / state pill (design `.tl-meta`): a "confirm" pill for
            // notify/request-tier tools, an "off" pill when disabled.
            if isConfirmTier {
                toolPill("confirm",
                         bg: BridgeTokens.warn.opacity(0.16),
                         stroke: BridgeTokens.warn.opacity(0.30),
                         fg: BridgeTokens.warnText)
            }
            if !isEnabled {
                toolPill("off",
                         bg: BridgeTokens.bad.opacity(0.10),
                         stroke: BridgeTokens.bad.opacity(0.20),
                         fg: BridgeTokens.badText)
            }

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .tint(BridgeTokens.ok)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(isEnabled ? 1.0 : 0.52)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.0001))  // hit-test only
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toolName) — \(isEnabled ? "enabled" : "disabled")")
    }

    private func toolPill(_ label: String, bg: Color, stroke: Color, fg: Color) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            .foregroundStyle(fg)
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
        onDepLinkTapped: @escaping (ModuleGroupDependency) -> Void
    ) {
        self.group = group
        self.toolDescriptions = toolDescriptions
        self.toolTiers = toolTiers
        self.forceExpanded = forceExpanded
        self.onPerToolChange = onPerToolChange
        self.onMasterChange = onMasterChange
        self.onDepLinkTapped = onDepLinkTapped
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.18), .clear],
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
        let label: String
        let bg: Color
        let stroke: Color
        let fg: Color
        switch group.masterState {
        case .on:
            label = "\(group.total) of \(group.total) active"
            bg = BridgeTokens.ok.opacity(0.14)
            stroke = BridgeTokens.ok.opacity(0.28)
            fg = BridgeTokens.okText
        case .off:
            label = "0 of \(group.total) active"
            bg = BridgeTokens.chipFill
            stroke = BridgeTokens.hairline
            fg = BridgeTokens.fg3
        case .partial:
            label = "\(group.enabledCount) of \(group.total) active"
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

    public init(tools: [ToolInfo], nav: SettingsNavigation = .shared) {
        self.tools = tools
        self.nav = nav
    }

    /// Tool name → description lookup, derived from the live `ToolInfo`
    /// list once per render. Avoids recomputing inside each row.
    private var descriptions: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.description) })
    }

    /// Tool name → security tier lookup, feeding the per-row "confirm" pill.
    private var tiers: [String: String] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.tier) })
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

    /// The `ModuleGroupID` a Tools dep-link chip's `anchor` targets, resolved
    /// against the live tool list (so it tracks the chip's module → group). nil
    /// when there is no anchor or it maps to no on-screen group. Drives both the
    /// `ScrollViewReader` scroll target and the matching card's auto-expand.
    private var anchoredGroupID: ModuleGroupID? {
        ModuleGroupDerivation.groupID(
            forAnchor: nav.anchor,
            registeredTools: tools.map { (name: $0.name, module: $0.module) }
        )
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // PKT-934 W1: card-stack spacing aligned to the BridgeSpacing
                // grid (sm) so the Tools and Jobs card pages share one tier;
                // was an off-grid literal 10.
                VStack(alignment: .leading, spacing: BridgeSpacing.sm) {
                    hero
                    ForEach(groups) { group in
                        ModuleGroupCard(
                            group: group,
                            toolDescriptions: descriptions,
                            toolTiers: tiers,
                            // Deep-link: auto-expand the chip's target group.
                            forceExpanded: group.id == anchoredGroupID,
                            onPerToolChange: { toolName, enabled in
                                setEnabled(toolName, enabled)
                            },
                            onMasterChange: { enabled in
                                setGroupEnabled(group, enabled: enabled)
                            },
                            onDepLinkTapped: { dep in
                                handleDepLink(dep)
                            }
                        )
                        // Scroll anchor id — the resolved group id, so the
                        // ScrollViewReader can jump straight to the target card.
                        .id(group.id)
                    }
                }
                .padding(BridgeSpacing.md)
            }
            // Deep-link: scroll the chip's target group into view. Fires on first
            // appear (chip tapped from another page → Tools just rendered) and on
            // every later anchor change (operator already on Tools). The anchor is
            // cleared after consuming so re-selecting the same chip re-triggers.
            .onAppear { scrollToAnchorIfNeeded(proxy) }
            .onChange(of: nav.anchor) { _, _ in scrollToAnchorIfNeeded(proxy) }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )) { _ in
            let fresh = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
            if fresh != disabledTools { disabledTools = fresh }
        }
    }

    /// Scroll the anchored group's card to the top, then clear the consumed
    /// anchor so the same chip can re-trigger later. No-op when the anchor maps
    /// to no on-screen group (e.g. an orphaned-credential chip).
    private func scrollToAnchorIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = anchoredGroupID else { return }
        // A tiny hop lets the ForEach lay out the cards before we scroll —
        // matches the cross-page nav timing (the section view appears, THEN we
        // jump). withAnimation keeps the jump legible rather than instant.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: .top)
            }
            // Clear the consumed anchor so re-tapping the same chip re-fires the
            // onChange (and so a later visit doesn't re-jump unexpectedly).
            nav.anchor = nil
        }
    }

    private var hero: some View {
        let total = tools.count
        let active = total - disabledTools.intersection(tools.map(\.name)).count
        let disabled = total - active
        return BridgeGlassCard(cornerRadius: 12, padding: 16) {
            HStack(spacing: 16) {
                // Orb — mirrors the StandingOrders hero icon tile.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(BridgeTokens.accentLink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tool registry")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("\(groups.count) modules · MCP v1.0 · grouped by source. Toggle a module or an individual tool.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    heroStat(value: total, label: "total", emphasis: .neutral)
                    heroStat(value: active, label: "active", emphasis: .on)
                    heroStat(value: disabled, label: "disabled", emphasis: .off)
                }
            }
        }
    }

    private enum HeroEmphasis { case neutral, on, off }
    private func heroStat(value: Int, label: String, emphasis: HeroEmphasis) -> some View {
        let valueColor: Color = {
            switch emphasis {
            case .on:      return BridgeTokens.okText
            case .off:     return BridgeTokens.fg4
            case .neutral: return BridgeTokens.fg1
            }
        }()
        return VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
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
        switch dep.route {
        case "permissions":  nav.go(.permissions)
        case "credentials":  nav.go(.credentials)
        case "connections":  nav.go(.connections)
        default: break
        }
    }
}
