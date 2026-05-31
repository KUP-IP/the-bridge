// RemoteAccessSection.swift — WS-E (Mac-side cloud access · Settings)
// NotionBridge · UI · Sections
//
// Settings → Remote Access pane. Surfaces Bridge Cloud Access: the
// cloudflared-backed Mac↔cloud tunnel (WS-C `BridgeCloudManager`) and the
// auth-passdown security posture from NL-3 (capability-gated + passkey-
// gated local execution; raw client credentials never leave the Mac).
//
// Static layout for this slice — it mirrors the glass-card structure of
// StandingOrdersSection / ConnectionsSection so it drops into the existing
// sidebar without new design primitives. The live wiring to a running
// `BridgeCloudManager` instance is a later slice; this compiles, renders,
// and states the security contract the user is opting into.

import SwiftUI

public struct RemoteAccessSection: View {
    /// Mirrors the WS-C `CloudConnectionState` machine for display. Static
    /// in this slice (defaults to `.disabled`); a later slice binds it to a
    /// live `BridgeCloudManager`.
    public enum DisplayState: String, Sendable, Equatable {
        case disabled   = "Disabled"
        case connecting = "Connecting\u{2026}"
        case online     = "Online"
        case degraded   = "Degraded"
        case offline    = "Offline"

        var dotColor: Color {
            switch self {
            case .online:     return .green
            case .degraded:   return .orange
            case .connecting: return .yellow
            case .offline:    return .red
            case .disabled:   return .secondary
            }
        }
    }

    @State private var displayState: DisplayState
    @State private var cloudAccessEnabled: Bool

    public init(displayState: DisplayState = .disabled) {
        self._displayState = State(initialValue: displayState)
        self._cloudAccessEnabled = State(initialValue: displayState != .disabled)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                statusCard
                securityCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(NotionPalette.blue.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "cloud")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NotionPalette.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote Access")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Reach this Mac from the cloud over a private tunnel. Every remote action is capability-scoped and passkey-gated — your credentials never leave this machine.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Bridge Cloud Access")
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Remote Access")
                            .font(.system(size: 13, weight: .medium))
                        Text("Starts a cloudflared tunnel so cloud agents can delegate work to this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $cloudAccessEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: cloudAccessEnabled) { _, on in
                            // Static slice: reflect intent locally only.
                            displayState = on ? .connecting : .disabled
                        }
                }
                Divider().background(Color.white.opacity(0.08))
                statusRow
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(displayState.dotColor)
                .frame(width: 8, height: 8)
            Text(displayState.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(displayState.dotColor)
            Spacer()
            Text("Tunnel: cloudflared")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Security posture

    private var securityCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("How remote actions stay safe")
                postureRow(
                    icon: "checkmark.shield",
                    title: "Capability-scoped",
                    detail: "The cloud can only ask this Mac to run one short-lived, pre-scoped operation at a time — never browse freely."
                )
                Divider().background(Color.white.opacity(0.08))
                postureRow(
                    icon: "touchid",
                    title: "Passkey-gated",
                    detail: "Before any stored credential is used, this Mac requires a fresh local passkey (Touch ID) approval."
                )
                Divider().background(Color.white.opacity(0.08))
                postureRow(
                    icon: "lock.fill",
                    title: "Credentials stay local",
                    detail: "Raw client credentials live only in this Mac's Keychain. They are never sent to, or stored by, the cloud."
                )
            }
        }
    }

    @ViewBuilder
    private func postureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NotionPalette.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
