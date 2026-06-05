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
        // Edge insets come from .pop-head (top 14) and .pop-actions (bottom 12)
        // per kit.css; no extra outer vertical padding so the spec stays exact.
        // v3.7.6: appearance is system-tethered (no forced color scheme) — the
        // adaptive BridgeTokens follow Light/Dark live.
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
            .background(BridgeTokens.bad.opacity(0.18))
            .foregroundStyle(BridgeTokens.bad.opacity(0.95))
            .accessibilityLabel("Bridge license expired. Open Settings → Advanced → License to activate.")
        }
        .buttonStyle(.plain)
        .help("Bridge tools are disabled until a license is activated.")
    }

    // MARK: - Header

    private var headerSection: some View {
        // kit.css .pop-head — padding 14 14 10, 22px mark, display title,
        // muted version line, and a tight (3pt) quick-links cluster.
        HStack(spacing: 10) {
            Image(systemName: "bridge.fill")
                .font(.system(size: 18))
                .foregroundStyle(BridgeTokens.fg1)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("The Bridge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(versionLine)
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                quickLink(.commands,    systemImage: "command",   help: "Command Bridge")
                quickLink(.tools,       systemImage: "wrench.and.screwdriver", help: "Open Tools")
                quickLink(.connections, systemImage: "gearshape", help: "Open Settings (\u{2318},)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var versionLine: String {
        if buildNumber.isEmpty {
            return "v\(appVersion)"
        }
        return "v\(appVersion) \u{00B7} build \(buildNumber)"
    }

    private func quickLink(_ section: SettingsSection, systemImage: String, help: String) -> some View {
        // kit.css .ql — 28×28, radius 7, fg .6 at rest brightening on hover.
        Button {
            onOpenSettings(section)
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 7, restForeground: BridgeTokens.fg3))
        .help(help)
        .accessibilityLabel(help)
    }

    private var divider: some View {
        // kit.css .pop-divider — 0.5px hairline, margin 2px 8px.
        Rectangle()
            .fill(BridgeTokens.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: - Server Status Row (primary)

    private var statusRow: some View {
        // kit.css .status-row — margin 0 6px, padding 8px 10px, radius 8,
        // emerald pulse dot, .92 label, .5 sub, .34 chevron.
        Button {
            onOpenSettings(.connections)
        } label: {
            HStack(spacing: 10) {
                StatusPulseDot(color: statusBar.isServerRunning ? BridgeTokens.ok : BridgeTokens.bad,
                               radius: PKT879Dashboard.statusDotSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusBar.isServerRunning ? "Server running" : "Server stopped")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text(statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                Text("\u{2197}")
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle())
        .padding(.horizontal, 6)
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
        // kit.css "CONNECTED CLIENTS · N" cap + .pclient rows (dot · name · time).
        VStack(alignment: .leading, spacing: 0) {
            captionRow(
                title: "Connected clients \u{00B7} \(statusBar.connectedClients.count)",
                actionTitle: "View all",
                action: { onOpenSettings(.connections) }
            )
            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            } else {
                ForEach(statusBar.connectedClients.prefix(4), id: \.name) { client in
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: ConnectedClient) -> some View {
        // .pclient — padding 6×10, margin 0 8, radius 6. Dot reads idle
        // (gray) once a client has been quiet > 30m, else emerald.
        let idle = Date().timeIntervalSince(client.connectedAt) > 1800
        return HStack(spacing: 10) {
            StatusPulseDot(color: idle ? BridgeTokens.fg5 : BridgeTokens.ok, radius: 9)
            Text(clientLabel(client))
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(relativeTime(from: client.connectedAt))
                .font(.system(size: 10.5))
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)   // .pclient inner padding
        .padding(.horizontal, 8)    // .pclient margin 0 8px
    }

    /// "Name · version" with the version omitted when empty (web clients).
    private func clientLabel(_ client: ConnectedClient) -> String {
        let v = client.version.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? client.name : "\(client.name) \u{00B7} \(v)"
    }

    // MARK: - Permissions (two-col grid)

    private var permissionsSection: some View {
        // kit.css "PERMISSIONS · X/Y" cap + .perm-grid (2 cols, gap 2×8,
        // padding 4×8) of small-dot permission cells.
        VStack(alignment: .leading, spacing: 0) {
            captionRow(
                title: "Permissions \u{00B7} \(grantedCount)/\(PermissionManager.Grant.v1Cases.count)",
                actionTitle: "Review",
                action: { onOpenSettings(.permissions) }
            )

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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
                StatusPulseDot(color: dotColor(status), radius: 7)
                Text(grant.displayName)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 5, restForeground: BridgeTokens.fg2))
        .help(permissionManager.statusLabel(for: grant))
        .accessibilityLabel("\(grant.displayName), \(permissionManager.statusLabel(for: grant)). Open Permissions.")
    }

    private func dotColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return BridgeTokens.ok
        case .denied: return BridgeTokens.bad
        case .unknown, .partiallyGranted, .restartRecommended: return BridgeTokens.warn
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        // kit.css .stat-row — three stats (value in fg1 over a muted label),
        // padding 6 12 10, gap 14.
        HStack(spacing: 14) {
            statButton(value: "\(statusBar.activeToolCount)", label: "tools active",
                       section: .tools)
            statButton(value: "\(statusBar.totalToolCalls)", label: "calls today",
                       section: .jobs)
            statButton(value: "\(skillsCount)", label: "skills",
                       section: .skills)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// Skills count for the stats row. Derived from `SkillsManager`'s
    /// persisted state (UserDefaults-backed) — reading it here is cheap
    /// and the row navigates correctly even if the value is stale.
    private var skillsCount: Int {
        SkillsManager().skills.count
    }

    private func statButton(value: String, label: String, section: SettingsSection) -> some View {
        // .stat — value (fg1, 13.5/semibold) stacked over a .62 label.
        Button {
            onOpenSettings(section)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 6))
        .accessibilityLabel("\(value) \(label). Navigate to \(section.rawValue).")
    }

    // MARK: - Actions

    private var actionsRow: some View {
        // kit.css .pop-actions — two 30pt buttons, gap 6, padding 8 10 12.
        // Quit carries the red-tinted danger tone.
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
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Caption row

    private func captionRow(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        // kit.css .cap — uppercase 10.5/600 caption, .10em tracking, fg .40,
        // with a right-aligned accent-link action. Padding 6 14 4.
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.05)
                .foregroundStyle(BridgeTokens.fg4)
            Spacer(minLength: 6)
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(BridgeTokens.accentLink)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
            // v3.7 fix: animation scoped to the shadow value, not a
            // withAnimation transaction in onAppear. The transaction
            // form was leaking the implicit animation to MenuBarExtra's
            // panel-resize during first render — the dashboard card
            // oscillated to upper-left then back to its anchor on every
            // popover open. Scoping with .animation(_:value:) confines
            // the animation to the shadow opacity/radius mutation only.
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: phase
            )
            .onAppear {
                guard !reduceMotion, isPulsable else { return }
                phase = true
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
    /// Optional rest-state foreground. When set, the label tints to this
    /// color at rest and brightens to fg1 on hover — mirroring the kit's
    /// `.ql:hover`/`.perm-cell:hover { color:#fff }` lift.
    var restForeground: Color? = nil
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering || configuration.isPressed
        return configuration.label
            .modifier(RestForeground(color: restForeground.map { active ? BridgeTokens.fg1 : $0 }))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(active ? BridgeTokens.hoverFill : Color.clear)
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }

    /// Applies a foreground tint only when a rest color is configured, so
    /// rows that set their own per-element colors are left untouched.
    private struct RestForeground: ViewModifier {
        let color: Color?
        func body(content: Content) -> some View {
            if let color { content.foregroundStyle(color) } else { content }
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
        case .danger:  return BridgeTokens.badText
        }
    }
    private var border: Color {
        switch tone {
        case .neutral: return BridgeTokens.hairlineStrong
        case .danger:  return BridgeTokens.bad.opacity(0.30)
        }
    }
    private func background(pressed: Bool) -> Color {
        switch tone {
        case .neutral: return pressed ? BridgeTokens.selectionFill : BridgeTokens.chipFill
        case .danger:  return BridgeTokens.bad.opacity(pressed ? 0.18 : 0.10)
        }
    }
}
