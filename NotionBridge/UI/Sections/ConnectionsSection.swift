// ConnectionsSection.swift — Liquid Glass reskin of Settings → Connections.
// PKT-876 v3.6.1. Per design/connections.html:
//   - Glass-hero header with server status pill
//   - Integrated tools (Notion + Stripe) as glass rows
//   - Active clients
//   - Bridge lifecycle (Launch at login, etc.)

import SwiftUI
import ServiceManagement
import AppKit
import Darwin

public struct ConnectionsSection: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager
    @Binding var launchAtLogin: Bool
    @Binding var launchAtLoginError: String?
    @Binding var isApplyingLaunchAtLoginChange: Bool

    @State private var notionConnection: BridgeConnection?
    @State private var stripeConnection: BridgeConnection?

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        launchAtLogin: Binding<Bool>,
        launchAtLoginError: Binding<String?>,
        isApplyingLaunchAtLoginChange: Binding<Bool>
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self._launchAtLogin = launchAtLogin
        self._launchAtLoginError = launchAtLoginError
        self._isApplyingLaunchAtLoginChange = isApplyingLaunchAtLoginChange
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                integratedToolsCard
                activeClientsCard
                lifecycleCard
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await loadConnections() }
    }

    // MARK: - Header (shared component)

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .connections)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: spec.subtitle,
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            serverStatusPill
        }
    }

    private var serverStatusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusBar.isServerRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusBar.isServerRunning ? "Server running" : "Server stopped")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusBar.isServerRunning ? Color.green : Color.red)
                Text("uptime \(statusBar.uptimeString)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Integrated tools

    private var integratedToolsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Integrated tools")
                connectionRow(
                    icon: "network",
                    iconColor: Color.white.opacity(0.85),
                    name: "Notion",
                    subtitle: connectionSubtitle(notionConnection, fallback: "Not configured"),
                    status: notionConnection?.status ?? .notConfigured,
                    manageAnchor: "notion"
                )
                Divider().background(Color.white.opacity(0.08))
                connectionRow(
                    icon: "creditcard",
                    iconColor: Color(red: 0.62, green: 0.55, blue: 0.92),
                    name: "Stripe",
                    subtitle: connectionSubtitle(stripeConnection, fallback: "Not configured"),
                    status: stripeConnection?.status ?? .notConfigured,
                    manageAnchor: "stripe"
                )
            }
        }
    }

    private func connectionSubtitle(_ conn: BridgeConnection?, fallback: String) -> String {
        guard let conn else { return fallback }
        if let masked = conn.maskedCredential {
            return masked
        }
        return conn.id
    }

    @ViewBuilder
    private func connectionRow(
        icon: String,
        iconColor: Color,
        name: String,
        subtitle: String,
        status: BridgeConnectionStatus,
        manageAnchor: String
    ) -> some View {
        HStack(spacing: 12) {
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
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .medium))
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusBadge(status)
            BridgeDepLink("Manage credential") {
                SettingsNavigation.shared.go(.credentials, anchor: manageAnchor)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: BridgeConnectionStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .connected: return ("Connected", Color.green)
            case .warning: return ("Warning", Color.orange)
            case .disconnected: return ("Disconnected", Color.red)
            case .invalid: return ("Invalid", Color.red)
            case .notConfigured: return ("Not configured", Color.secondary)
            case .checking: return ("Checking\u{2026}", Color.secondary)
            }
        }()
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    // MARK: - Active clients

    private var activeClientsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Active clients")
                    Spacer()
                    Text("\(statusBar.connectedClients.count) connected \u{00B7} \(statusBar.activeToolCount) tools")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if statusBar.connectedClients.isEmpty {
                    Text("No clients connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(statusBar.connectedClients, id: \.name) { client in
                        clientRow(client)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clientRow(_ client: ConnectedClient) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 26, height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.62, green: 0.55, blue: 0.92))
            }
            Text(client.name)
                .font(.system(size: 13))
            Spacer()
            Text(relativeTimestamp(from: client.connectedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 2)
    }

    private func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Bridge lifecycle

    private var lifecycleCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Bridge lifecycle")
                lifecycleToggleRow(
                    title: "Launch at login",
                    subtitle: "Registers Bridge with macOS via SMAppService.",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, enabled in
                    applyLaunchAtLoginChange(enabled: enabled)
                }
                if let err = launchAtLoginError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
                Divider().background(Color.white.opacity(0.08))
                HStack(spacing: 10) {
                    Button {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        NSApp.restartBridge()
                    } label: {
                        Label("Restart Bridge", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func lifecycleToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func applyLaunchAtLoginChange(enabled: Bool) {
        guard !isApplyingLaunchAtLoginChange else { return }
        launchAtLoginError = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return }
                try? service.unregister()
                try service.register()
            } else {
                if service.status == .notRegistered { return }
                try service.unregister()
            }
        } catch {
            let ns = error as NSError
            let notPermitted = (ns.domain == NSPOSIXErrorDomain && ns.code == EPERM)
                || ns.localizedDescription.localizedCaseInsensitiveContains("operation not permitted")
            launchAtLoginError = notPermitted
                ? (enabled ? "Could not enable Launch at login. Operation not permitted."
                           : "Could not disable Launch at login. Operation not permitted.")
                : (enabled ? "Could not enable Launch at login."
                           : "Could not disable Launch at login.")
            isApplyingLaunchAtLoginChange = true
            launchAtLogin.toggle()
            isApplyingLaunchAtLoginChange = false
        }
    }

    // MARK: - Data load

    private func loadConnections() async {
        await ConnectionHealthChecker.shared.invalidateAll()
        do {
            let workspace = try await ConnectionRegistry.shared.listConnections(kind: .workspace, validateLive: false)
            let api = try await ConnectionRegistry.shared.listConnections(kind: .api, validateLive: false)
            let snapshotNotion = workspace.first { $0.provider == .notion }
            let snapshotStripe = api.first { $0.provider == .stripe }
            await MainActor.run {
                notionConnection = snapshotNotion
                stripeConnection = snapshotStripe
            }
            await withTaskGroup(of: Void.self) { group in
                if let conn = snapshotNotion {
                    group.addTask {
                        if let validated = try? await ConnectionRegistry.shared.validateConnection(id: conn.id) {
                            await MainActor.run { notionConnection = validated }
                        }
                    }
                }
                if let conn = snapshotStripe {
                    group.addTask {
                        if let validated = try? await ConnectionRegistry.shared.validateConnection(id: conn.id) {
                            await MainActor.run { stripeConnection = validated }
                        }
                    }
                }
            }
        } catch {
            // silent — indicators stay as not configured
        }
    }
}
