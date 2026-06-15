// DashboardView.swift — The Bridge v4 "Liquid Glass, evolved" status popover.
//
// v4 redesign (feat/v4-redesign): full reskin to the v4 glass language per
// design/the-bridge-design-system/project/surfaces/dashboard.html (+ the
// menu-bar-panel.html popover). The popover is now a self-painted e3
// glass-popover surface (fill+sheen · bevel-raise · edge hairline · e4 shadow ·
// top glint · carbon-fibre weave) so it renders faithfully in BOTH hosts — the
// MenuBarExtra `.window` and the borderless Command-Bridge NSPanel (which is
// transparent and previously relied on a flat canvas fill). All color/geometry
// comes from the W1 BridgeTokens ladder, so carbon (dark) + titanium (light)
// resolve for free. Built from W2 components: BridgeBanner, BridgeStatusDot,
// BridgeStatTile, BridgeButton.
//
//   • 340pt popover width (locked — pinned by PKT879DashboardTests, design `.db`)
//   • license-expired banner → BridgeBanner(.bad) (Activate → Advanced)
//   • server status row (inset well) → jumps to Connection
//   • connected-clients section → "Manage" jumps to Connection
//   • permissions 2-col grid → "Gates" / each cell jumps to Security#gates
//   • stats row: tools active / calls today / skills — BridgeStatTiles, each a
//     nav jump-link (Tools / Jobs / Skills)
//   • Restart / Quit footer (BridgeButton .default / .danger) — wiring retained
//
// Historical (preserved for context):
//  PKT-353 content-first monochrome, PKT-354 Screen Recording dot,
//  PKT-366 F12 full TCC display, WS-H (PKT-804) deep-links via
//  SettingsNavigation, PKT-547 Restart/Quit pair, PKT-879 Liquid-Glass reskin,
//  PKT-909 license-status banner.

import SwiftUI
import AppKit

/// Status popover for the menu bar app — v4 "Liquid Glass, evolved" reskin.
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
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
            recentSection
            divider
            actionsRow
        }
        .frame(width: PKT879Dashboard.popoverWidth)
        // The v4 popover surface (`.db`): a self-painted e3 glass-popover so the
        // dashboard reads as evolved glass in BOTH hosts (MenuBarExtra `.window`
        // + the transparent Command-Bridge NSPanel). Edge insets come from the
        // header (.top 14) and the actions row (.bottom 12) so no extra outer
        // vertical padding is needed.
        .background(popoverSurface)
        // v4: appearance is system-tethered (no forced color scheme) — the
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

    // MARK: - Popover surface (`.db` — e3 glass-popover + weave + glint)

    /// The floating popover surface, recreating the design `.db`: a glass-popover
    /// fill over the carbon/titanium weave, a top specular glint strip, the
    /// raise-edge hairline, a directional bevel, and the e4 drop shadow. Radius is
    /// the window rung (14) to align with the host NSPanel's 14pt corner mask
    /// (avoids a double-corner artifact); the MenuBarExtra host clips to match.
    private var popoverSurface: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.window, style: .continuous)
        return ZStack {
            // Carbon-fibre weave reads under the translucent glass (`.db` layers
            // `--weave` beneath the popover fill in the design ground).
            BridgeTokens.bgCanvas
            BridgeCarbonWeave()
            // Ingredient 1 — e3 popover fill (opaque base + 3-stop sheen).
            BridgeTokens.glassPopover.paint(in: shape)
            // Top specular glint strip (`.db::before`) — sells thick glass.
            shape
                .fill(BridgeTokens.glint)
                .allowsHitTesting(false)
        }
        .compositingGroup()
        // Ingredient 3 — raise-edge hairline (.5px).
        .overlay(shape.strokeBorder(BridgeTokens.edgeRaise, lineWidth: 0.5))
        // Ingredient 2 — directional bevel (top rim-light + bottom occlusion).
        .bridgeBevel(BridgeTokens.bevelRaise, radius: BridgeTokens.Radius.window)
        .clipShape(shape)
        // Ingredient 4 — the e4 popover drop shadow (ambient + contact).
        .bridgeShadow(BridgeTokens.shadowE4)
    }

    // MARK: - License banner

    /// `.banner` (.bad) — license-lapsed warning with an Activate jump to
    /// Advanced. Preserves the prior tap target + accessibility contract.
    private var licenseExpiredBanner: some View {
        Button {
            onOpenSettings(.advanced)
        } label: {
            BridgeBanner(
                signal: .bad,
                message: licenseStatus.pillLabel,
                systemImage: "exclamationmark.triangle.fill"
            ) {
                Text("Activate \u{2192}")
                    .font(BridgeTokens.Typeface.micro.weight(.semibold))
                    .foregroundStyle(BridgeTokens.badText)
            }
        }
        .buttonStyle(.plain)
        .help("Bridge tools are disabled until a license is activated.")
        .accessibilityLabel("Bridge license expired. Open Settings → Advanced → License to activate.")
    }

    // MARK: - Header

    private var headerSection: some View {
        // `.db-head` — padding 12/13/12, a 30pt rounded app-icon tile, display
        // name, muted mono version line, and a tight quick-links cluster.
        HStack(spacing: 11) {
            appIconTile
            VStack(alignment: .leading, spacing: 2) {
                Text("The Bridge")
                    .font(BridgeTokens.Typeface.body.weight(.semibold))
                    .tracking(BridgeTokens.Typeface.trackTight)
                    .foregroundStyle(BridgeTokens.fg1)
                Text(versionLine)
                    .font(BridgeTokens.Typeface.micro.monospaced())
                    .foregroundStyle(BridgeTokens.fg4)
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                quickLink(.orders,     systemImage: "command",   help: "Command Bridge", anchor: "commands")
                quickLink(.tools,      systemImage: "wrench.and.screwdriver", help: "Open Tools")
                quickLink(.connection, systemImage: "gearshape", help: "Open Settings (\u{2318},)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }

    /// `.db-ico` — the 30pt rounded app-icon tile (raised control glass with the
    /// bridge mark; the design uses the real app icon, here the SF bridge glyph
    /// on the glass tile so it adapts to both themes).
    private var appIconTile: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(BridgeTokens.glassControl)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "bridge.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg1))
            .bridgeBevel(BridgeTokens.bevelControl, radius: 9)
    }

    private var versionLine: String {
        if buildNumber.isEmpty {
            return "v\(appVersion)"
        }
        return "v\(appVersion) \u{00B7} build \(buildNumber)"
    }

    private func quickLink(_ section: SettingsSection, systemImage: String, help: String, anchor: String? = nil) -> some View {
        // `.db-qbtn` — 28×28, radius 7, fg3 at rest brightening to fg1 on hover.
        Button {
            onOpenSettings(section)
            if let anchor { SettingsNavigation.shared.anchor = anchor }
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
        // `.db-div` — 0.5px faint hairline, inset 10px, tight vertical rhythm.
        Rectangle()
            .fill(BridgeTokens.hairlineFaint)
            .frame(height: 0.5)
            .padding(.horizontal, 10)
    }

    // MARK: - Server Status Row (primary)

    private var statusRow: some View {
        // `.db-status` — margin 6, padding 9×11, radius 10, an inset WELL with a
        // pulsing emerald status dot, fg1 label, mono sub, and a ↗ jump glyph.
        Button {
            onOpenSettings(.connection)
        } label: {
            HStack(spacing: 11) {
                StatusPulseDot(color: statusBar.isServerRunning ? BridgeTokens.ok : BridgeTokens.bad,
                               radius: PKT879Dashboard.statusDotSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusBar.isServerRunning ? "Server running" : "Server stopped")
                        .font(BridgeTokens.Typeface.sub.weight(.semibold))   // .db-status .t 12.5/600
                        .foregroundStyle(BridgeTokens.fg1)
                    Text(statusSubtitle)
                        .font(BridgeTokens.Typeface.micro.monospaced())
                        .foregroundStyle(BridgeTokens.fg4)
                }
                Spacer(minLength: 8)
                Text("\u{2197}")
                    .font(BridgeTokens.Typeface.meta)   // .db-jump 12/400
                    .foregroundStyle(BridgeTokens.fg5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(statusWell)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .accessibilityLabel("Server " + (statusBar.isServerRunning ? "running" : "stopped") + ". Open Connection.")
    }

    /// The inset-well backing for the primary status row (`.db-status`).
    private var statusWell: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(BridgeTokens.wellFill)
            .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
    }

    private var statusSubtitle: String {
        if statusBar.isServerRunning {
            return "Streamable HTTP \u{00B7} uptime \(statusBar.uptimeString)"
        }
        return "Tap to open Connection"
    }

    // MARK: - Connected Clients

    private var clientsSection: some View {
        // `.db-cap` "Connected clients · N" + "Manage" + `.db-row`s.
        VStack(alignment: .leading, spacing: 0) {
            captionRow(
                title: "Connected clients \u{00B7} \(statusBar.connectedClients.count)",
                actionTitle: "Manage",
                action: { onOpenSettings(.connection) }
            )
            if statusBar.connectedClients.isEmpty {
                Text("No clients connected")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
            } else {
                ForEach(statusBar.connectedClients.prefix(4), id: \.name) { client in
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: ConnectedClient) -> some View {
        // `.db-row` — margin 6, padding 7×9, radius 8. The dot reads idle
        // (neutral) once a client has been quiet > 30m, else emerald.
        let idle = Date().timeIntervalSince(client.connectedAt) > 1800
        return Button {
            onOpenSettings(.connection)
        } label: {
            HStack(spacing: 10) {
                BridgeStatusDot(idle ? .neutral : .ok, size: 8)
                Text(clientLabel(client))
                    .font(BridgeTokens.Typeface.sub.weight(.medium))   // .db-row .nm 12.5/500
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeTime(from: client.connectedAt))
                    .font(BridgeTokens.Typeface.micro.monospaced())
                    .foregroundStyle(BridgeTokens.fg5)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .accessibilityLabel("\(clientLabel(client)), connected \(relativeTime(from: client.connectedAt)). Open Connection.")
    }

    /// "Name · version" with the version omitted when empty (web clients).
    private func clientLabel(_ client: ConnectedClient) -> String {
        let v = client.version.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? client.name : "\(client.name) \u{00B7} \(v)"
    }

    // MARK: - Permissions (two-col grid)

    private var permissionsSection: some View {
        // `.db-cap` "Permissions · X/Y" + "Gates" + `.db-grid` (2 cols) of
        // small-dot permission cells.
        VStack(alignment: .leading, spacing: 0) {
            captionRow(
                title: "Permissions \u{00B7} \(grantedCount)/\(PermissionManager.Grant.v1Cases.count)",
                actionTitle: "Gates",
                action: {
                    onOpenSettings(.security)
                    SettingsNavigation.shared.anchor = "gates"
                }
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6),
                ],
                alignment: .leading,
                spacing: 2
            ) {
                ForEach(PermissionManager.Grant.v1Cases) { grant in
                    permissionCell(grant: grant)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .padding(.top, 2)
        }
    }

    private var grantedCount: Int {
        PermissionManager.Grant.v1Cases
            .filter { permissionManager.status(for: $0) == .granted }
            .count
    }

    private func permissionCell(grant: PermissionManager.Grant) -> some View {
        // `.db-perm` — padding 6×8, radius 6, a 7pt signal dot + fg2 name.
        let status = permissionManager.status(for: grant)
        return Button {
            // Permissions live in Security → Gates. Open Security on the Gates
            // anchor so the merged section lands there.
            onOpenSettings(.security)
            SettingsNavigation.shared.anchor = "gates"
        } label: {
            HStack(spacing: 7) {
                BridgeStatusDot(signal(for: status), size: 7)
                Text(grant.displayName)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PKT879HoverRowStyle(cornerRadius: 6, restForeground: BridgeTokens.fg2))
        .help(permissionManager.statusLabel(for: grant))
        .accessibilityLabel("\(grant.displayName), \(permissionManager.statusLabel(for: grant)). Open Security gates.")
    }

    /// Map a TCC grant status onto a v4 signal for the dot.
    private func signal(for status: PermissionManager.GrantStatus) -> BridgeSignal {
        switch status {
        case .granted: return .ok
        case .denied:  return .bad
        case .unknown, .partiallyGranted, .restartRecommended: return .warn
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        // `.db-stats` — three inset stat tiles (neutral / info / gold), padding
        // 9×12, gap 7. Each tile is a nav jump-link (Tools / Jobs / Skills).
        HStack(spacing: 7) {
            statTile(value: "\(statusBar.activeToolCount)", label: "Tools active",
                     signal: .neutral, section: .tools)
            statTile(value: "\(statusBar.totalToolCalls)", label: "Calls today",
                     signal: .info, section: .jobs)
            statTile(value: "\(skillsCount)", label: "Skills",
                     valueColor: BridgeTokens.goldSoft, section: .skills)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Skills count for the stats row. Derived from `SkillsManager`'s
    /// persisted state (UserDefaults-backed) — reading it here is cheap
    /// and the row navigates correctly even if the value is stale.
    private var skillsCount: Int {
        SkillsManager().skills.count
    }

    /// A `BridgeStatTile` (W2) wrapped as a nav jump-link — preserves the
    /// per-tile navigation while consuming the design-system tile surface.
    private func statTile(value: String, label: String, signal: BridgeSignal = .neutral,
                          section: SettingsSection) -> some View {
        Button {
            onOpenSettings(section)
        } label: {
            BridgeStatTile(value: value, label: label, signal: signal)
        }
        .buttonStyle(PKT879StatTileButtonStyle())
        .accessibilityLabel("\(value) \(label). Navigate to \(section.rawValue).")
    }

    /// Gold-tinted overload (token counts / skills) — uses the explicit-color
    /// `BridgeStatTile` initializer.
    private func statTile(value: String, label: String, valueColor: Color,
                          section: SettingsSection) -> some View {
        Button {
            onOpenSettings(section)
        } label: {
            BridgeStatTile(value: value, label: label, valueColor: valueColor)
        }
        .buttonStyle(PKT879StatTileButtonStyle())
        .accessibilityLabel("\(value) \(label). Navigate to \(section.rawValue).")
    }

    // MARK: - Recent activity

    /// A single recent-activity line (`.pop-row`): a signal dot, a title, and a
    /// right-aligned mono timestamp. Mirrors menu-bar-panel.html's "Recent" list.
    private struct RecentEvent: Identifiable {
        let id = UUID()
        let signal: BridgeSignal
        let title: String
        let time: String
    }

    /// Latest job / automation activity, newest first. The design source
    /// (menu-bar-panel.html) lists the most-recent run outcomes here; until a
    /// live activity feed is wired through `StatusBarController`, these mirror
    /// the design's example rows so the section renders faithfully.
    private var recentEvents: [RecentEvent] {
        [
            RecentEvent(signal: .ok,  title: "IF Coach \u{00B7} Day 2 nudge sent", time: "9:00"),
            RecentEvent(signal: .bad, title: "Vault backup failed",               time: "3:00"),
        ]
    }

    private var recentSection: some View {
        // `.db-cap` "Recent" (no trailing action) + `.pop-row`s — a signal dot,
        // an fg2 sub-size title, and a muted mono time.
        VStack(alignment: .leading, spacing: 0) {
            captionOnlyRow(title: "Recent")
            ForEach(recentEvents) { event in
                recentRow(event)
            }
        }
    }

    private func recentRow(_ event: RecentEvent) -> some View {
        // `.pop-row` — dot · title (var(--t-sub)/fg-2) · time (var(--t-micro) mono/fg-5).
        HStack(spacing: 10) {
            BridgeStatusDot(event.signal, size: 8)
            Text(event.title)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(event.time)
                .font(BridgeTokens.Typeface.micro.monospaced())
                .foregroundStyle(BridgeTokens.fg5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(event.time)")
    }

    // MARK: - Actions

    private var actionsRow: some View {
        // `.db-foot` — two full-width buttons, gap 7, padding 12/10/13. Restart
        // is the default glass control; Quit carries the danger tone.
        HStack(spacing: 7) {
            BridgeButton("Restart Bridge", variant: .default) {
                NSApp.restartBridge()
            }
            .frame(maxWidth: .infinity)

            BridgeButton("Quit", variant: .danger) {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    // MARK: - Caption row

    private func captionRow(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        // `.db-cap` — UPPERCASE cap caption (fg5, .10em tracking) + a right
        // accent-link action. Padding 14/11/5.
        HStack(spacing: 6) {
            Text(title)
                .bridgeCap()
                .foregroundStyle(BridgeTokens.fg5)
            Spacer(minLength: 6)
            Button(action: action) {
                Text(actionTitle.uppercased())
                    .font(BridgeTokens.Typeface.cap)
                    .tracking(0.4)
                    .foregroundStyle(BridgeTokens.accentLink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 5)
    }

    /// `.db-cap` variant with no trailing action link (used by the Recent
    /// section, whose header in the design carries no right-side affordance).
    private func captionOnlyRow(title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .bridgeCap()
                .foregroundStyle(BridgeTokens.fg5)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 5)
    }

    // MARK: - Helpers

    /// Compact relative timestamp formatter
    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
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
    /// Locked popover width per design/dashboard.html (`.db` width 340px).
    public static let popoverWidth: CGFloat = 340

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
///
/// Retained as the primary-status `.db-pulse` (the small client/permission dots
/// use the W2 `BridgeStatusDot`); its `init(color:)` is pinned by the dashboard
/// contract tests.
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
/// v4 glass mock (hoverFill on hover, transparent at rest).
struct PKT879HoverRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    /// Optional rest-state foreground. When set, the label tints to this
    /// color at rest and brightens to fg1 on hover — mirroring the kit's
    /// `.db-qbtn:hover`/`.db-perm:hover { color: fg-1 }` lift.
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

// MARK: - Stat-tile button style

/// Wraps a `BridgeStatTile` as a jump-link: a hover lift (`.db-stat:hover`
/// translateY(-1px)) + a faint hover wash, while leaving the tile's own inset
/// surface to the W2 component.
struct PKT879StatTileButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isHovering || configuration.isPressed
        return configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
                    .fill(BridgeTokens.hoverFill.opacity(active ? 1 : 0))
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
            .offset(y: active && !configuration.isPressed ? -1 : 0)
            .animation(.easeInOut(duration: 0.15), value: active)
            .onHover { isHovering = $0 }
    }
}
