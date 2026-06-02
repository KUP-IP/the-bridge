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
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 11) {
            // Status glyph — small filled dot, green when on, dim when off.
            Circle()
                .fill(isEnabled ? Color(red: 0.243, green: 0.788, blue: 0.478)
                                : Color.white.opacity(0.18))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolName)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.95))
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.0001))  // hit-test only
        )
        .accessibilityElement(children: .combine)
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
    public let onPerToolChange: (String, Bool) -> Void
    public let onMasterChange: (Bool) -> Void
    public let onDepLinkTapped: (ModuleGroupDependency) -> Void

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
        onPerToolChange: @escaping (String, Bool) -> Void,
        onMasterChange: @escaping (Bool) -> Void,
        onDepLinkTapped: @escaping (ModuleGroupDependency) -> Void
    ) {
        self.group = group
        self.toolDescriptions = toolDescriptions
        self.onPerToolChange = onPerToolChange
        self.onMasterChange = onMasterChange
        self.onDepLinkTapped = onDepLinkTapped
        let saved = ModuleGroupCard.savedExpandState(forGroupId: group.id.rawValue)
        let initial: Bool = {
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

    public var body: some View {
        BridgeGlassCard(cornerRadius: 12, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if isExpanded {
                    if !group.dependencies.isEmpty {
                        depChipRow
                    }
                    Divider().background(Color.white.opacity(0.06))
                    toolList
                }
            }
        }
        .opacity(group.masterState == .off ? 0.62 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: group.masterState)
    }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 12) {
            iconSquare
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                HStack(spacing: 6) {
                    countBadge
                    Text(group.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.5))
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

    private var iconSquare: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: group.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
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
            bg = Color(red: 0.243, green: 0.788, blue: 0.478).opacity(0.14)
            stroke = Color(red: 0.243, green: 0.788, blue: 0.478).opacity(0.28)
            fg = Color(red: 0.490, green: 0.863, blue: 0.627)
        case .off:
            label = "0 of \(group.total) active"
            bg = Color.white.opacity(0.06)
            stroke = Color.white.opacity(0.10)
            fg = Color.white.opacity(0.65)
        case .partial:
            label = "\(group.enabledCount) of \(group.total) active"
            bg = Color(red: 0.960, green: 0.768, blue: 0.318).opacity(0.14)
            stroke = Color(red: 0.960, green: 0.768, blue: 0.318).opacity(0.28)
            fg = Color(red: 0.960, green: 0.812, blue: 0.486)
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
            .foregroundStyle(Color.white.opacity(0.42))
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
    }

    private var depChipRow: some View {
        HStack(spacing: 6) {
            Text("depends on")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.46))
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
        VStack(spacing: 0) {
            ForEach(group.tools, id: \.self) { toolName in
                ModuleGroupToolRow(
                    toolName: toolName,
                    description: toolDescriptions[toolName] ?? "",
                    isEnabled: Binding(
                        get: { !group.disabledNames.contains(toolName) },
                        set: { onPerToolChange(toolName, $0) }
                    )
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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

    private var groups: [ModuleGroup] {
        ModuleGroupDerivation.deriveGroups(
            registeredToolNames: tools.map(\.name),
            disabledNames: disabledTools
        )
    }

    public var body: some View {
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
                }
            }
            .padding(BridgeSpacing.md)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification
        )) { _ in
            let fresh = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
            if fresh != disabledTools { disabledTools = fresh }
        }
    }

    private var hero: some View {
        let total = tools.count
        let active = total - disabledTools.intersection(tools.map(\.name)).count
        let disabled = total - active
        return BridgeGlassCard(cornerRadius: 12, padding: 13) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool registry")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                    Text("\(groups.count) modules · MCP v1.0 · grouped by source")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                heroStat(value: total, label: "total", emphasis: .neutral)
                heroStat(value: active, label: "active", emphasis: .on)
                heroStat(value: disabled, label: "disabled", emphasis: .off)
            }
        }
    }

    private enum HeroEmphasis { case neutral, on, off }
    private func heroStat(value: Int, label: String, emphasis: HeroEmphasis) -> some View {
        let valueColor: Color = {
            switch emphasis {
            case .on:      return Color(red: 0.490, green: 0.863, blue: 0.627)
            case .off:     return Color.white.opacity(0.45)
            case .neutral: return Color.white
            }
        }()
        return VStack(alignment: .center, spacing: 0) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.62))
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
        switch dep.route {
        case "permissions":  nav.go(.permissions)
        case "credentials":  nav.go(.credentials)
        case "connections":  nav.go(.connections)
        default: break
        }
    }
}
