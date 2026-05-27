// ToolDepLinks.swift — Live dep-link derivation for Settings cross-page chips.
// PKT-876 v3.6.1 (locked decision Q1).
//
// Credentials and Permissions render "↗ Used by" / "↗ Required by" chips
// pointing into Tools. The chips are derived from the live ToolInfo list
// (via StatusBarController.toolInfoList) at render time so they are always
// accurate — no static tables to keep in sync. A small mapping from
// credential slug → tool modules and from permission grant → tool modules
// captures the audit-fact that "stripe" credential gates the `stripe`
// module, "Accessibility" gates the `accessibility` + `chrome` modules,
// etc. The chips themselves are `BridgeDepLink` (BridgeThemeV2).

import SwiftUI

// MARK: - Credential → tool modules

/// Maps a credential service slug (the key under which the secret is
/// stored in Keychain, e.g. "api_key:stripe" or "notion") to the tool
/// modules that depend on it. Returning multiple modules is fine; the
/// derivation collapses them into a single chip count.
public enum CredentialToolDependencies {
    public static func modules(forCredentialService service: String) -> [String] {
        // Normalize "api_key:stripe" → "stripe".
        let lower = service.lowercased()
        let normalized = lower.hasPrefix("api_key:")
            ? String(lower.dropFirst("api_key:".count))
            : lower

        switch normalized {
        case "notion":
            return ["notion"]
        case "stripe":
            return ["stripe", "payment"]
        case "openai":
            return ["openai"]
        case "github", "gh":
            return ["gh", "git"]
        default:
            // Default: assume a module of the same name exists (e.g.
            // "anthropic", "linear", etc.). Live ToolInfo filter will
            // drop the chip if no tools actually match the module.
            return [normalized]
        }
    }
}

// MARK: - Permission → tool modules

/// Maps a TCC grant to the tool modules whose tools require it. Mirrors
/// the audit-fact in `design/permissions.html`. Like the credential map
/// above, the chip count is derived from live ToolInfo filtered to the
/// listed modules — so if the registry drops a tool, the chip count
/// updates automatically.
public enum PermissionToolDependencies {
    public static func modules(forGrant grant: PermissionManager.Grant) -> [String] {
        switch grant {
        case .accessibility:    return ["accessibility", "ax", "chrome", "mouseClick", "cgEvent", "syntheticInput"]
        case .screenRecording:  return ["screen", "chrome"]
        case .fullDiskAccess:   return ["file"]
        case .contacts:         return ["contacts"]
        case .notifications:    return []  // not tool-gated; banners only
        case .automation:       return ["applescript", "spotlight"]
        }
    }
}

// MARK: - Dep-link derivation

public struct DepLinkChip: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let variant: BridgeDepLink.Variant
    public let section: SettingsSection
    public let anchor: String?

    public init(
        id: String,
        label: String,
        variant: BridgeDepLink.Variant,
        section: SettingsSection,
        anchor: String?
    ) {
        self.id = id
        self.label = label
        self.variant = variant
        self.section = section
        self.anchor = anchor
    }
}

public enum ToolDepLinks {
    /// Build "used by" chips for a credential row from the live ToolInfo
    /// list. The chip count is exact — equal to the number of tools in
    /// the dependent modules. Variant is `.bad` if no live tools match
    /// (credential is orphaned — wasted secret) so the user sees they
    /// can safely remove it.
    @MainActor
    public static func usedByChips(
        forCredentialService service: String,
        liveTools: [ToolInfo]
    ) -> [DepLinkChip] {
        let modules = Set(CredentialToolDependencies.modules(forCredentialService: service))
        let matched = liveTools.filter { modules.contains($0.module.lowercased()) }
        let normalizedName = service.lowercased().hasPrefix("api_key:")
            ? String(service.lowercased().dropFirst("api_key:".count))
            : service.lowercased()

        if matched.isEmpty {
            return [
                DepLinkChip(
                    id: "cred-orphan-\(normalizedName)",
                    label: "no tools registered",
                    variant: .bad,
                    section: .tools,
                    anchor: normalizedName
                )
            ]
        }

        // Group by module so we get "28 notion tools" rather than 28
        // individual chips. Stable alphabetical ordering for deterministic
        // rendering in snapshot tests.
        let byModule = Dictionary(grouping: matched, by: { $0.module.lowercased() })
        return byModule.keys.sorted().map { mod in
            let count = byModule[mod]?.count ?? 0
            let plural = count == 1 ? "tool" : "tools"
            return DepLinkChip(
                id: "cred-\(normalizedName)-\(mod)",
                label: "\(count) \(mod) \(plural)",
                variant: .info,
                section: .tools,
                anchor: mod
            )
        }
    }

    /// Build "required by" chips for a permission row from the live
    /// ToolInfo list. Same shape as `usedByChips`. If the grant gates no
    /// modules (e.g. notifications), returns an empty list so the row
    /// stays clean.
    @MainActor
    public static func requiredByChips(
        forGrant grant: PermissionManager.Grant,
        liveTools: [ToolInfo],
        permissionGranted: Bool
    ) -> [DepLinkChip] {
        let modules = Set(PermissionToolDependencies.modules(forGrant: grant))
        guard !modules.isEmpty else { return [] }
        let matched = liveTools.filter { modules.contains($0.module.lowercased()) }
        guard !matched.isEmpty else { return [] }
        let byModule = Dictionary(grouping: matched, by: { $0.module.lowercased() })
        return byModule.keys.sorted().map { mod in
            let count = byModule[mod]?.count ?? 0
            let plural = count == 1 ? "tool" : "tools"
            let label = permissionGranted
                ? "\(count) \(mod) \(plural)"
                : "\(count) \(mod) \(plural) — disabled"
            return DepLinkChip(
                id: "perm-\(grant.id)-\(mod)",
                label: label,
                variant: permissionGranted ? .info : .bad,
                section: .tools,
                anchor: mod
            )
        }
    }
}

// MARK: - Chip row

/// A single horizontally-scrolling row of dep-link chips. Used by the
/// Credential and Permission row layouts; navigation is wired through
/// SettingsNavigation.shared so a tap routes to the target Settings
/// section + anchor without intermediate plumbing.
public struct BridgeDepLinkRow: View {
    public let label: String
    public let chips: [DepLinkChip]
    public init(label: String, chips: [DepLinkChip]) {
        self.label = label
        self.chips = chips
    }

    public var body: some View {
        if chips.isEmpty { EmptyView() } else {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                ForEach(chips) { chip in
                    BridgeDepLink(chip.label, variant: chip.variant) {
                        SettingsNavigation.shared.go(chip.section, anchor: chip.anchor)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }
}
