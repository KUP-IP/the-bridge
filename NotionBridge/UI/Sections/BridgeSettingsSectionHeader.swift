// BridgeSettingsSectionHeader.swift — Shared Liquid Glass hero header for
// every Settings section pane (PKT-876, v3.6.1).
//
// One component, five callers. Renders the section's icon in a colored
// glass tile + title + subtitle + an optional trailing accessory (status
// pill, count, action). No section-specific branching lives in here —
// each caller supplies the parts it needs, the header just lays them out.

import SwiftUI

/// Liquid-Glass section hero used by Connections, Credentials, Permissions,
/// Jobs, and Advanced. The header is purely presentational — no per-section
/// switch inside — so all five sections share a single visual contract.
public struct BridgeSettingsSectionHeader<Accessory: View>: View {
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let tint: Color
    private let accessory: Accessory

    public init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
    }

    public var body: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.85))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer()
                accessory
            }
        }
        // v3.6.0 D6/v3.6·6: a single combined heading per section keeps the
        // VoiceOver rotor uncluttered (title + subtitle in one rotor stop,
        // the decorative icon hidden, the accessory left as its own element).
        .accessibilityElement(children: .contain)
    }
}

extension BridgeSettingsSectionHeader where Accessory == EmptyView {
    /// Convenience init for headers without a trailing accessory — keeps
    /// the call-site free of `accessory: { EmptyView() }` boilerplate.
    public init(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            accessory: { EmptyView() }
        )
    }
}

// MARK: - Per-section presets

/// Centralized tint/icon/copy for each section the header renders. The
/// header itself doesn't switch on `SettingsSection` — this enum provides
/// the inputs callers feed in, and the snapshot tests assert that every
/// real section (Connections, Credentials, Permissions, Jobs, Advanced)
/// has a preset defined.
public enum BridgeSettingsHeaderPreset {
    public struct Spec: Sendable {
        public let title: String
        public let subtitle: String
        public let systemImage: String
        public let tint: Color

        public init(title: String, subtitle: String, systemImage: String, tint: Color) {
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.tint = tint
        }
    }

    public static func spec(for section: SettingsSection) -> Spec {
        switch section {
        case .connections:
            return Spec(
                title: "Connections",
                subtitle: "Server, integrated tools, and active MCP clients.",
                systemImage: BridgeSectionIcon.systemImage(for: .connections),
                tint: NotionPalette.green
            )
        case .credentials:
            return Spec(
                title: "Credentials",
                subtitle: "Tokens stored in your macOS Keychain. Bridge never writes plaintext to disk.",
                systemImage: BridgeSectionIcon.systemImage(for: .credentials),
                tint: NotionPalette.orange
            )
        case .permissions:
            return Spec(
                title: "Permissions",
                subtitle: "System grants (TCC) and sensitive paths.",
                systemImage: BridgeSectionIcon.systemImage(for: .permissions),
                tint: NotionPalette.blue
            )
        case .jobs:
            return Spec(
                title: "Jobs",
                subtitle: "Scheduled background automations triggered by launchd.",
                systemImage: BridgeSectionIcon.systemImage(for: .jobs),
                tint: NotionPalette.purple
            )
        case .advanced:
            return Spec(
                title: "Advanced",
                subtitle: "Network ports, local endpoints, system paths, and maintenance.",
                systemImage: BridgeSectionIcon.systemImage(for: .advanced),
                tint: NotionPalette.gray
            )
        // Non-target sections still get a preset so the header stays a
        // single, unbranched component if a future caller adopts it.
        case .standingOrders:
            return Spec(
                title: "Standing Orders",
                subtitle: "Loaded by every MCP client at session start.",
                systemImage: BridgeSectionIcon.systemImage(for: .standingOrders),
                tint: NotionPalette.purple
            )
        case .commands:
            return Spec(
                title: "Commands",
                subtitle: "Global command palette and shortcuts.",
                systemImage: BridgeSectionIcon.systemImage(for: .commands),
                tint: NotionPalette.blue
            )
        case .skills:
            return Spec(
                title: "Skills",
                subtitle: "Routing skills surfaced to MCP clients.",
                systemImage: BridgeSectionIcon.systemImage(for: .skills),
                tint: NotionPalette.yellow
            )
        case .tools:
            return Spec(
                title: "Tools",
                subtitle: "Every tool the server exposes.",
                systemImage: BridgeSectionIcon.systemImage(for: .tools),
                tint: NotionPalette.brown
            )
        case .remoteAccess:
            return Spec(
                title: "Remote Access",
                subtitle: "Reach this Mac from the cloud — capability-scoped, passkey-gated.",
                systemImage: BridgeSectionIcon.systemImage(for: .remoteAccess),
                tint: NotionPalette.blue
            )
        }
    }

    /// Sections this packet (PKT-876) actually reskins. Used by the
    /// snapshot tests to lock the "one header, 5 callers" contract.
    public static let targetSections: [SettingsSection] = [
        .connections, .credentials, .permissions, .jobs, .advanced
    ]
}
