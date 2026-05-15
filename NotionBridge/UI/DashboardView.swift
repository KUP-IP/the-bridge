// DashboardView.swift — Liquid Glass Status Popover
// Notion Bridge v2: macOS Tahoe 26 — Liquid Glass design language
// PKT-353: Full rewrite — content-first, monochrome, no pills, no dividers,
//   BridgeTheme design system, content-adaptive sizing, quit relocated to context menu.
// PKT-354: Added Screen Recording permission indicator (green/red).
// PKT-366 F12: Full TCC permissions display (Accessibility, Screen Recording,
//   Notifications, Contacts, Full Disk Access).
// Dashboard TCC rows use the same PermissionManager probes as Settings (single source of truth).

import SwiftUI
import AppKit

/// Status popover for the menu bar app.
/// Shows server status (primary), connected clients (secondary), permissions, and stats.
/// Styled with BridgeTheme. Liquid Glass chrome provided automatically by macOS 26 SDK.
public struct DashboardView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager
    let onOpenSettings: () -> Void

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        onOpenSettings: @escaping () -> Void
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self.onOpenSettings = onOpenSettings
    }

    /// Version from Bundle (single source of truth — Info.plist)
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            headerSection
            statusSection
            clientsSection
            permissionsSection
            statsSection
            quitSection
        }
        .frame(minWidth: 260, maxWidth: 320)
        .padding(.vertical, BridgeSpacing.xs)
        .task {
            await permissionManager.checkAllAsync()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: BridgeSpacing.xs) {
            Text("Notion Bridge")
                .font(.headline)
                .foregroundStyle(BridgeColors.primary)
            Spacer()
            Text("v\(appVersion)")
                .bridgeSecondary()
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.monochrome)
                    .font(.callout)
                    .foregroundStyle(BridgeColors.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Settings (\u{2318},)")
        }
        .bridgeRow()
    }

    // MARK: - Server Status (Primary)

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Server")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            HStack(spacing: BridgeSpacing.xs) {
                Circle()
                    .fill(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                    .frame(width: 8, height: 8)
                Text(statusBar.isServerRunning ? "Running" : "Stopped")
                    .bridgeLabel()
                if statusBar.isServerRunning {
                    Text("\u{00B7} \(statusBar.uptimeString)")
                        .bridgeSecondary()
                }
                Spacer()
            }
        }
        .bridgeRow()
    }

    // MARK: - Connected Clients (Secondary)

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Connected Clients")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .bridgeSecondary()
            } else {
                ForEach(statusBar.connectedClients, id: \.name) { client in
                    HStack(spacing: BridgeSpacing.xs) {
                        Circle()
                            .fill(BridgeColors.success)
                            .frame(width: 6, height: 6)
                        Text("\(client.name) \(client.version)")
                            .font(.caption)
                            .foregroundStyle(BridgeColors.primary)
                        Spacer()
                        Text(relativeTime(from: client.connectedAt))
                            .font(.caption2)
                            .foregroundStyle(BridgeColors.muted)
                    }
                }
            }
        }
        .bridgeRow()
    }

    // MARK: - Permissions (F12 — aligned with PermissionManager / Settings)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: BridgeSpacing.xs) {
            Text("Permissions")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.primary)

            ForEach(PermissionManager.Grant.v1Cases) { grant in
                permissionRow(grant: grant)
            }
        }
        .bridgeRow()
    }

    private func permissionRow(grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        let dotColor = dashboardPermissionDotColor(status)
        let captionColor = dashboardPermissionCaptionColor(status)
        return HStack(spacing: BridgeSpacing.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(grant.displayName)
                .font(.caption)
                .foregroundStyle(BridgeColors.primary)
            Spacer()
            Text(permissionManager.statusLabel(for: grant))
                .font(.caption)
                .foregroundStyle(captionColor)
        }
    }

    private func dashboardPermissionDotColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: BridgeColors.success
        case .denied: BridgeColors.error
        case .unknown, .partiallyGranted, .restartRecommended: Color.orange
        }
    }

    private func dashboardPermissionCaptionColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: BridgeColors.success
        case .denied: BridgeColors.error
        case .unknown, .partiallyGranted, .restartRecommended: Color.orange
        }
    }

    // MARK: - Stats (Tertiary)

    private var statsSection: some View {
        HStack(spacing: BridgeSpacing.md) {
            statItem(label: "Tools", value: "\(statusBar.activeToolCount)")
            statItem(label: "Calls", value: "\(statusBar.totalToolCalls)")
        }
        .bridgeRow()
    }

    // PKT-547: Replaced single right-aligned "Quit Notion Bridge" with a
    // left-aligned pair — Restart Bridge (faded blue) + Quit Bridge (faded red).
    // Restart uses the shared NSApplication.restartBridge() utility in
    // BridgeUtilities.swift so DashboardView and PermissionView stay in sync.
    private var quitSection: some View {
        HStack(spacing: BridgeSpacing.sm) {
            Button("Restart Bridge") {
                NSApp.restartBridge()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.blue.opacity(0.7))

            Button("Quit Bridge") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.red.opacity(0.6))

            Spacer()
        }
        .bridgeRow()
    }

    private func statItem(label: String, value: String) -> some View {
        HStack(spacing: BridgeSpacing.xxs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(BridgeColors.muted)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(BridgeColors.secondary)
        }
    }

    // MARK: - Helpers

    /// Compact relative timestamp formatter
    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
