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

    private func tierColor(_ tier: String) -> Color {
        switch tier {
        case "open":
            return BridgeTokens.ok
        case "notify":
            return BridgeTokens.warn
        default:
            return BridgeTokens.bad
        }
    }

    var body: some View {
        if tools.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "hammer")
                    .font(.system(size: 48))
                    .foregroundStyle(.gray.opacity(0.5))
                Text("Tool Registry")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("Tools will appear here once the server is running.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        } else {
            Form {
                // F7: Cross-dependency warning — notifications denied + Notify-tier tools exist
                if notificationDenied && hasNotificationTierTools {
                    Section {
                        Label("Notification permission is not granted. Notify/Request tiers cannot prompt or alert.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(BridgeTokens.warn)
                    }
                }

                Section {
                    HStack(spacing: 16) {
                        tierHintDot(.green, label: "Open")
                        tierHintDot(.orange, label: "Notify")
                        tierHintDot(.red, label: "Request")
                    }
                    .font(.caption)
                } header: {
                    Text("Security Tiers")
                        .font(.headline)
                }

                ForEach(groupedTools, id: \.module) { group in
                    Section {
                        ForEach(group.tools) { tool in
                            toolRow(tool)
                        }
                    } header: {
                        HStack {
                            Text(displayName(for: group.module))
                                .font(.headline)
                            Spacer()
                            Text("\(enabledCount(in: group.tools))/\(group.tools.count)")
                                .font(.caption)
                                .foregroundStyle(BridgeColors.secondary)
                        }
                    }
                }

                // fb-securitygate-revoke-ui: surface active module-scoped
                // "Always Allow" grants with a per-module revoke, so a user who
                // granted module-wide can pull back ONE module without the
                // blanket Reset nuking every override.
                if !moduleTierOverrides.isEmpty {
                    Section {
                        ForEach(moduleTierOverrides.keys.sorted(), id: \.self) { module in
                            moduleGrantRow(module)
                        }
                    } header: {
                        Text("Module Grants")
                            .font(.headline)
                    } footer: {
                        Text("“Always Allow” grants that apply to every tool in a module. A tool’s own tier override takes precedence over its module grant.")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.secondary)
                    }
                }

                // F4: Reset to Defaults — keep this after the tool list.
                if !tierOverrides.isEmpty || !moduleTierOverrides.isEmpty {
                    Section {
                        Button {
                            tierOverrides.removeAll()
                            persistTierOverrides()
                            // fb-securitygate: also clear module-scoped
                            // "Always Allow" grants so a reset is complete —
                            // otherwise a module grant would silently outlive
                            // the per-tool overrides the user just cleared.
                            moduleTierOverrides.removeAll()
                            persistModuleTierOverrides()
                            NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Reset to Defaults")
                            }
                        }
                        .foregroundStyle(BridgeTokens.warn)
                    }
                }
            }
            .formStyle(.grouped)
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

    @ViewBuilder
    private func toolRow(_ tool: ToolInfo) -> some View {
        let isCoreProtected = Self.coreTools.contains(tool.name)
        let gatedCredentials = credentialModuleGateActive(for: tool)
        let isEnabled = effectiveToolEnabled(tool)
        let currentTier = effectiveTier(for: tool)

        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if gatedCredentials { return }
                    if newValue {
                        disabledTools.remove(tool.name)
                    } else {
                        disabledTools.insert(tool.name)
                    }
                    persistDisabledTools()
                    onToggle(tool.name, newValue)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(isCoreProtected || gatedCredentials)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .fontWeight(.medium)

                    // Tappable 3-state tier toggle (Open -> Notify -> Request).
                    Button {
                        // Base = what the tool resolves to WITHOUT its own
                        // override: the module grant if one exists, else the
                        // registered default. Landing back on the base clears the
                        // per-tool override so the tool follows the grant/default.
                        let base = moduleTierOverrides[tool.module] ?? tool.tier
                        let newTier = nextTier(after: currentTier)
                        if newTier == base {
                            tierOverrides.removeValue(forKey: tool.name)
                        } else {
                            tierOverrides[tool.name] = newTier
                        }
                        persistTierOverrides()
                    } label: {
                        Text(currentTier)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(tierColor(currentTier).opacity(0.15))
                            .foregroundStyle(tierColor(currentTier))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Dimmed when tool is disabled (per Interaction spec)
                    .opacity(isEnabled ? 1.0 : 0.4)

                    if isCoreProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(BridgeColors.secondary)
                    }
                }

                // Distinguish a tier inherited from a module-wide grant from the
                // tool's own override (the tappable chip above is the per-tool one).
                if tierSource(for: tool) == .moduleGrant {
                    Text("tier via \(displayName(for: tool.module)) module grant")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.secondary)
                }

                if !isEnabled {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                        .lineLimit(3)
                }

                if gatedCredentials {
                    Text("Enable Keychain credentials under Settings → Credentials to use these tools.")
                        .font(.caption2)
                        .foregroundStyle(BridgeTokens.warn)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func tierHintDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(BridgeColors.secondary)
        }
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: module))
                    .fontWeight(.medium)
                Text("Covers every \(displayName(for: module)) tool")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.secondary)
            }
            Spacer()
            Text(tier)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tierColor(tier).opacity(0.15))
                .foregroundStyle(tierColor(tier))
                .clipShape(Capsule())
            Button {
                revokeModuleGrant(module)
            } label: {
                Text("Revoke")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BridgeTokens.bad)
        }
        .padding(.vertical, 2)
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
