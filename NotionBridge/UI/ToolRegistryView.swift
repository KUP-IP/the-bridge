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

    /// Effective tier for a tool, considering user overrides.
    private func effectiveTier(for tool: ToolInfo) -> String {
        tierOverrides[tool.name] ?? tool.tier
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

                // F4: Reset to Defaults — keep this after the tool list.
                if !tierOverrides.isEmpty {
                    Section {
                        Button {
                            tierOverrides.removeAll()
                            persistTierOverrides()
                            // fb-securitygate: also clear module-scoped
                            // "Always Allow" grants so a reset is complete —
                            // otherwise a module grant would silently outlive
                            // the per-tool overrides the user just cleared.
                            UserDefaults.standard.removeObject(forKey: BridgeDefaults.moduleTierOverrides)
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
                        let newTier = nextTier(after: currentTier)
                        if newTier == tool.tier {
                            // Reverted to registered default — remove override
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
}
