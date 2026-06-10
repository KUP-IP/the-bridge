// ConnectionsSection.swift — Settings → Connections pane.
// v3.7.2 bundle-2 redesign: near-pixel match to the locked design mockup
// (design/.../Connections.jsx + connections.css). Orb hero with live server
// status, transport status display, integration health grid, active-clients
// list, and Bridge-lifecycle card. Carbon canvas, royal-blue / emerald / gold
// accents. Every store call, binding, toggle, and async load is preserved.

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

    @State private var copiedEndpoint = false

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

    private var port: Int { ConfigManager.shared.ssePort }
    private var endpoint: String { "127.0.0.1:\(port)/mcp" }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                transportCard
                integrationsCard
                activeClientsCard
                lifecycleCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await loadConnections() }
    }

    // MARK: - Hero (server status orb)

    private var hero: some View {
        let running = statusBar.isServerRunning
        let orbColor = running ? BridgeTokens.ok : BridgeTokens.bad
        return BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(orbColor.opacity(0.20))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(orbColor.opacity(0.42), lineWidth: 1))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(running ? BridgeTokens.okText : BridgeTokens.badText)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(running ? "Server running" : "Server stopped")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    heroSubtitle
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(statusBar.connectedClients.count)", label: "clients", color: BridgeTokens.ok)
                    statTile(value: statusBar.totalToolCalls.formatted(), label: "calls today", color: BridgeTokens.gold)
                }
                HStack(spacing: 4) {
                    iconButton("arrow.clockwise", help: "Restart Bridge") { NSApp.restartBridge() }
                    iconButton(copiedEndpoint ? "checkmark" : "doc.on.doc", help: "Copy endpoint") { copyEndpoint() }
                }
            }
        }
    }

    private var heroSubtitle: some View {
        let running = statusBar.isServerRunning
        return HStack(spacing: 0) {
            Text(running
                 ? "Local Streamable HTTP · uptime \(statusBar.uptimeString) · "
                 : "MCP transport idle · ")
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
            Button {
                SettingsNavigation.shared.go(.advanced, anchor: "ports")
            } label: {
                Text("configure ports")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BridgeTokens.accentLink)
            }
            .buttonStyle(.plain)
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyEndpoint() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("http://\(endpoint)", forType: .string)
        copiedEndpoint = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedEndpoint = false
        }
    }

    // MARK: - Transport status
    //
    // NOT a selector. Transport is not a single user-selectable runtime
    // setting: the one `SSEServer` NIO listener on `ssePort` serves BOTH the
    // Streamable HTTP `/mcp` endpoint and the legacy SSE `/sse` path
    // concurrently and unconditionally (see ServerManager.runSSE), while
    // stdio is a separate, per-client transport that is always active
    // (ServerManager.run). All three run whenever the server is up — there is
    // no ConfigManager/BridgeDefaults setting that turns one on instead of
    // another. So this card is an informational status display of which
    // transports are ACTIVE, styled like the redesign's tiles but with no
    // radio/selection affordance to imply a choice that doesn't exist.

    private var transportCard: some View {
        let running = statusBar.isServerRunning
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Transport")
                    Spacer()
                    Text("How clients reach Bridge. All transports run together.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                HStack(spacing: 8) {
                    transportTile(
                        name: "Streamable HTTP",
                        endpoint: "127.0.0.1:\(port)/mcp",
                        state: running ? .active : .idle
                    )
                    transportTile(
                        name: "Legacy SSE",
                        endpoint: "127.0.0.1:\(port)/sse",
                        state: running ? .active : .idle
                    )
                    transportTile(
                        name: "stdio",
                        endpoint: "spawned per-client",
                        state: .perClient
                    )
                }
            }
        }
    }

    /// Live state of a transport surface. `active` = listening now,
    /// `idle` = server stopped, `perClient` = spawned on demand (no listener).
    private enum TransportState { case active, idle, perClient }

    private func transportTile(name: String, endpoint: String, state: TransportState) -> some View {
        HStack(spacing: 10) {
            transportDot(state)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(endpoint)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            transportStateLabel(state)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BridgeTokens.wellFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func transportDot(_ state: TransportState) -> some View {
        switch state {
        case .active:
            Circle().fill(BridgeTokens.ok).frame(width: 8, height: 8)
                .shadow(color: BridgeTokens.ok.opacity(0.5), radius: 3)
        case .idle:
            Circle().fill(BridgeTokens.fg4.opacity(0.6)).frame(width: 8, height: 8)
        case .perClient:
            Circle()
                .strokeBorder(BridgeTokens.fg4.opacity(0.7), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func transportStateLabel(_ state: TransportState) -> some View {
        switch state {
        case .active:
            transportStatePill("Active", color: BridgeTokens.ok)
        case .idle:
            transportStatePill("Idle", color: BridgeTokens.fg4)
        case .perClient:
            transportStatePill("Per-client", color: BridgeTokens.fg4)
        }
    }

    private func transportStatePill(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    // MARK: - Integration health grid

    private var integrationsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    BridgeCardLabel("Integrated tools")
                    Spacer()
                    BridgeDepLink("Manage credentials") {
                        SettingsNavigation.shared.go(.security, anchor: "vault")
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    integrationTile(
                        connection: notionConnection,
                        name: "Notion",
                        // Real branded Notion "N" mark (adaptive ink).
                        mark: { NotionMark().frame(width: 19, height: 19) },
                        tileTint: BridgeTokens.chipFill,
                        fallbackSub: "Not configured · add a workspace token",
                        anchor: "notion"
                    )
                    integrationTile(
                        connection: stripeConnection,
                        name: "Stripe",
                        // Real branded Stripe "S" mark in brand purple #635BFF.
                        mark: { StripeMark().frame(width: 19, height: 19) },
                        tileTint: BridgeServiceMarkTokens.stripePurple.opacity(0.16),
                        fallbackSub: "Not configured · add an API key",
                        anchor: "stripe"
                    )
                }
            }
        }
    }

    private func integrationTile<Mark: View>(
        connection: BridgeConnection?,
        name: String,
        @ViewBuilder mark: () -> Mark,
        tileTint: Color,
        fallbackSub: String,
        anchor: String
    ) -> some View {
        let status = connection?.status ?? .notConfigured
        let (badgeText, badgeColor) = badgeStyle(for: status)
        let sub = integrationSubtitle(connection, fallback: fallbackSub)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tileTint)
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                    // Real branded service mark (true vector), sized to the tile.
                    mark()
                }
                Spacer()
                statusBadge(badgeText, color: badgeColor)
            }
            .padding(.bottom, 10)

            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg1)
            Text(sub)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg3)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minHeight: 32, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                .padding(.top, 9)

            HStack(spacing: 6) {
                Text(toolsLabel(for: connection))
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg3)
                Spacer()
                Button {
                    // PKT-A: Credentials folded into Security/Vault; the
                    // per-service slug passes through to the Vault child.
                    SettingsNavigation.shared.go(.security, anchor: anchor)
                } label: {
                    HStack(spacing: 3) {
                        Text("Manage")
                        Text("↗").opacity(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BridgeTokens.accentLink)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground(for: status), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(tileBorder(for: status), lineWidth: 0.5))
    }

    private func tileBackground(for status: BridgeConnectionStatus) -> Color {
        switch status {
        case .disconnected, .invalid: return BridgeTokens.bad.opacity(0.05)
        default: return BridgeTokens.wellFill
        }
    }

    private func tileBorder(for status: BridgeConnectionStatus) -> Color {
        switch status {
        case .disconnected, .invalid: return BridgeTokens.bad.opacity(0.30)
        case .warning: return BridgeTokens.warn.opacity(0.22)
        default: return BridgeTokens.hairlineFaint
        }
    }

    private func toolsLabel(for connection: BridgeConnection?) -> String {
        guard let connection, !connection.capabilities.isEmpty else {
            return connection?.status == .notConfigured || connection == nil ? "unavailable" : "ready"
        }
        let n = connection.capabilities.count
        return "\(n) tool\(n == 1 ? "" : "s")"
    }

    private func integrationSubtitle(_ conn: BridgeConnection?, fallback: String) -> String {
        guard let conn else { return fallback }
        if let summary = conn.summary, !summary.isEmpty { return summary }
        if let masked = conn.maskedCredential, !masked.isEmpty {
            return conn.isPrimary ? "Primary · \(masked)" : masked
        }
        return conn.id
    }

    private func badgeStyle(for status: BridgeConnectionStatus) -> (String, Color) {
        switch status {
        case .connected:     return ("Connected", BridgeTokens.ok)
        case .warning:       return ("Attention", BridgeTokens.warn)
        case .disconnected:  return ("Disconnected", BridgeTokens.bad)
        case .invalid:       return ("Invalid", BridgeTokens.bad)
        case .notConfigured: return ("Not configured", BridgeTokens.fg4)
        case .checking:      return ("Checking\u{2026}", BridgeTokens.fg4)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    // MARK: - Active clients

    private var activeClientsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Active clients")
                    Spacer()
                    Text("\(statusBar.connectedClients.count) connected · \(statusBar.activeToolCount) tools exposed")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                if statusBar.connectedClients.isEmpty {
                    Text("No clients connected")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(statusBar.connectedClients.enumerated()), id: \.element.name) { index, client in
                        clientRow(client)
                        if index < statusBar.connectedClients.count - 1 {
                            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func clientRow(_ client: ConnectedClient) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BridgeTokens.chipFill)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BridgeTokens.accentLink)
            }
            Text(clientName(client))
                .font(.system(size: 13.5))
                .foregroundStyle(BridgeTokens.fg2)
            Spacer()
            Text(relativeTimestamp(from: client.connectedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg4)
            Circle()
                .fill(BridgeTokens.ok)
                .frame(width: 8, height: 8)
                .shadow(color: BridgeTokens.ok.opacity(0.5), radius: 3)
        }
        .padding(.vertical, 7)
    }

    private func clientName(_ client: ConnectedClient) -> String {
        let v = client.version.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? client.name : "\(client.name) · \(v)"
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
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Bridge lifecycle")
                lifecycleToggleRow(
                    title: "Launch at login",
                    subtitle: "Registers Bridge with macOS via SMAppService. Approve in System Settings → Login Items if blocked.",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, enabled in
                    applyLaunchAtLoginChange(enabled: enabled)
                }
                if let err = launchAtLoginError {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.warnText)
                        .padding(.top, 1)
                }
                Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                HStack(spacing: 10) {
                    Button {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BridgeTokens.accent)
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

    private func lifecycleToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BridgeTokens.ok)
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
