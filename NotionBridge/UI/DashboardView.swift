// DashboardView.swift — Liquid Glass Status Popover
// PKT-879 (v3.6.4): Full Liquid Glass reskin per design/dashboard.html.
//   • 300pt popover width
//   • every status row is a clickable jump-link via SettingsNavigation
//   • status dot has a soft pulse glow
//   • permission cells in two-column grid (4/6 visible: accessibility,
//     screenRecording, notifications, contacts, fullDiskAccess, automation)
//   • stats row: tools active / calls today / skills (each navigates)
// Restart / Quit buttons retained at the bottom (existing behavior).
//
// Historical (preserved for context):
//  PKT-353 content-first monochrome, PKT-354 Screen Recording dot,
//  PKT-366 F12 full TCC display, WS-H (PKT-804) deep-links via
//  SettingsNavigation, PKT-547 Restart/Quit pair.

import SwiftUI
import AppKit

/// Status popover for the menu bar app — v3.6.4 Liquid Glass reskin.
public struct DashboardView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager
    let onOpenSettings: (SettingsSection) -> Void

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        onOpenSettings: @escaping (SettingsSection) -> Void
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self.onOpenSettings = onOpenSettings
    }

    /// Version from Bundle (single source of truth — Info.plist)
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// PKT-909 (Sell/Distribute v3 · 1) — license-status banner. Visible
    /// only when the license has lapsed (trial-expired or
    /// license-expired); silent for trial-active / licensed /
    /// grandfathered states so the popover stays clean for paid users.
    @State private var licenseStatus: LicenseStatus = .trial(daysRemaining: 30)

    public var body: some View {
        VStack(spacing: 0) {
            headerSection
            if !licenseStatus.isActive {
                licenseExpiredBanner
            }
            divider
            statusRow
            divider
            clientsSection
            divider
            permissionsSection
            divider
            statsRow
            divider
            actionsRow
        }
        .frame(width: PKT879Dashboard.popoverWidth)
        .padding(.vertical, 6)
        .task {
            await permissionManager.checkAllAsync()
            await refreshLicenseStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .licenseStateDidChange)) { _ in
            Task { await refreshLicenseStatus() }
        }
    }

    private func refreshLicenseStatus() async {
        self.licenseStatus = await LicenseManager.shared.currentStatus()
    }

    private var licenseExpiredBanner: some View {
        Button {
            onOpenSettings(.advanced)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(licenseStatus.pillLabel)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("Activate \u{2192}")
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(0.85)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.18))
            .foregroundStyle(Color.red.opacity(0.95))
            .accessibilityLabel("Bridge license expired. Open Settings → Advanced → License to activate.")
        }
        .buttonStyle(.plain)
        .help("Bridge tools are disabled until a license is activated.")
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "bridge.fill")
                .font(.system(size: 18))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("The Bridge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(versionLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            quickLink(.commands,        systemImage: "command", help: "Open Commands")
            quickLink(.tools,           systemImage: "hammer",  help: "Open Tools")
            quickLink(.connections,     systemImage: "gearshape", help: "Open Settings (\u{2318},)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var versionLine: String {
        if buildNumber.isEmpty {
            return "v\(appVersion)"
        }
        return "v\(appVersion) \u{00B7} build \(buildNumber)"
    }

    private func quickLink(_ section: SettingsSection, systemImage: String, help: String) -> some View {
        Button {
            onOpenSettings(section)
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 10)
    }

    // MARK: - Server Status Row (primary)

    private var statusRow: some View {
        Button {
            onOpenSettings(.connections)
        } label: {
            HStack(spacing: 10) {
                StatusPulseDot(color: statusBar.isServerRunning ? .green : .red,
                               radius: PKT879Dashboard.statusDotSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusBar.isServerRunning ? "Server running" : "Server stopped")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                    Text(statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\u{2197}")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle())
        .accessibilityLabel("Server " + (statusBar.isServerRunning ? "running" : "stopped") + ". Open Connections.")
    }

    private var statusSubtitle: String {
        if statusBar.isServerRunning {
            return "Streamable HTTP \u{00B7} uptime \(statusBar.uptimeString)"
        }
        return "Tap to open Connections"
    }

    // MARK: - Connected Clients

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow(
                title: "Connected clients \u{00B7} \(statusBar.connectedClients.count)",
                actionTitle: "View all",
                action: { onOpenSettings(.connections) }
            )
            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                ForEach(statusBar.connectedClients.prefix(4), id: \.name) { client in
                    clientRow(client)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func clientRow(_ client: ConnectedClient) -> some View {
        HStack(spacing: 10) {
            StatusPulseDot(color: .green, radius: 6)
            Text("\(client.name) \(client.version)")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text(relativeTime(from: client.connectedAt))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: - Permissions (two-col grid)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow(
                title: "Permissions \u{00B7} \(grantedCount)/\(PermissionManager.Grant.v1Cases.count)",
                actionTitle: "Review",
                action: { onOpenSettings(.permissions) }
            )

            // PKT-879: Two-column grid (LazyVGrid mirrors mock spec).
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(PermissionManager.Grant.v1Cases) { grant in
                    permissionCell(grant: grant)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private var grantedCount: Int {
        PermissionManager.Grant.v1Cases
            .filter { permissionManager.status(for: $0) == .granted }
            .count
    }

    private func permissionCell(grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        return Button {
            onOpenSettings(.permissions)
            SettingsNavigation.shared.anchor = grant.rawValue
        } label: {
            HStack(spacing: 6) {
                StatusPulseDot(color: dotColor(status), radius: 5)
                Text(grant.displayName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 5))
        .help(permissionManager.statusLabel(for: grant))
        .accessibilityLabel("\(grant.displayName), \(permissionManager.statusLabel(for: grant)). Open Permissions.")
    }

    private func dotColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .unknown, .partiallyGranted, .restartRecommended: return .orange
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statButton(value: "\(statusBar.activeToolCount)", label: "tools active",
                       section: .tools)
            statButton(value: "\(statusBar.totalToolCalls)", label: "calls today",
                       section: .jobs)
            statButton(value: "\(skillsCount)", label: "skills",
                       section: .skills)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Skills count for the stats row. Derived from `SkillsManager`'s
    /// persisted state (UserDefaults-backed) — reading it here is cheap
    /// and the row navigates correctly even if the value is stale.
    private var skillsCount: Int {
        SkillsManager().skills.count
    }

    private func statButton(value: String, label: String, section: SettingsSection) -> some View {
        Button {
            onOpenSettings(section)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 6))
        .accessibilityLabel("\(value) \(label). Navigate to \(section.rawValue).")
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 6) {
            Button("Restart Bridge") {
                NSApp.restartBridge()
            }
            .buttonStyle(PKT879PillButtonStyle(tone: .neutral))

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(PKT879PillButtonStyle(tone: .danger))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Caption row

    private func captionRow(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(red: 0.47, green: 0.63, blue: 0.86))
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
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

// MARK: - Constants (PKT-879 contract surface — pinned by tests)

/// Layout constants exposed for snapshot/contract tests so the design pass
/// can pin spec values (popover width, dot size). Keeping them in one place
/// gives a single source of truth and avoids drift between docs and code.
public enum PKT879Dashboard {
    /// Locked popover width per design/dashboard.html (300px).
    public static let popoverWidth: CGFloat = 300

    /// Status dot radius for the primary server row.
    public static let statusDotSize: CGFloat = 9
}

// MARK: - Status pulse dot

/// A filled dot with a soft outer glow. The glow runs a slow opacity
/// pulse on green dots ("server running") — for other states the dot is
/// static so an error doesn't read as a "thinking" indicator. Animation
/// is suppressed under reduce-motion (handled by SwiftUI automatically
/// when the user has the system flag set; we also add a guard in the
/// animation modifier).
public struct StatusPulseDot: View {
    public let color: Color
    public let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: Bool = false

    public init(color: Color, radius: CGFloat = 9) {
        self.color = color
        self.radius = radius
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: radius, height: radius)
            .shadow(color: color.opacity(phase ? 0.65 : 0.30),
                    radius: phase ? 5 : 3)
            .onAppear {
                guard !reduceMotion, isPulsable else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    phase = true
                }
            }
    }

    /// We only pulse the green ("ok") dot; red/orange remain steady so
    /// they read as warnings, not as activity indicators.
    private var isPulsable: Bool {
        let cgColor = color.cgColor ?? NSColor.green.cgColor
        // Use a coarse heuristic — exact green wins, others don't.
        // For accessibility this only changes whether the glow oscillates.
        guard let components = cgColor.components, components.count >= 3 else { return false }
        return components[1] > components[0] && components[1] > components[2]
    }
}

// MARK: - Hover row button style

/// A button style that gives a row a subtle hover highlight matching the
/// Liquid Glass mock (white opacity 0.05 on hover, transparent at rest).
struct PKT879HoverRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovering || configuration.isPressed ? 0.06 : 0.0))
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

// MARK: - Pill button (Restart / Quit)

struct PKT879PillButtonStyle: ButtonStyle {
    enum Tone { case neutral, danger }
    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(border, lineWidth: 0.5)
                    )
            )
            .foregroundStyle(foreground)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Color.primary
        case .danger:  return Color(red: 1.0, green: 0.61, blue: 0.61)
        }
    }
    private var border: Color {
        switch tone {
        case .neutral: return Color.white.opacity(0.16)
        case .danger:  return Color.red.opacity(0.30)
        }
    }
    private func background(pressed: Bool) -> Color {
        switch tone {
        case .neutral: return Color.white.opacity(pressed ? 0.14 : 0.08)
        case .danger:  return Color.red.opacity(pressed ? 0.18 : 0.10)
        }
    }
}
