// ConnectionsSection.swift — Settings → Connection → Local clients surface.
//
// Settings Redesign (PKT-connection): this is no longer a standalone pane with
// its own hero/lifecycle/integrations chrome. It is the LOCAL-CLIENTS body of
// the merged Connection page (ConnectionSection composite below in
// SettingsWindow+Sections.swift), which owns the live status strip and racks
// Local clients above Remote access.
//
// What stays here (the trusted loopback surface, PKT-810 model):
//   • The loopback `127.0.0.1:{ssePort}/mcp` endpoint as a copyable card with a
//     plain "local clients connect with no token" line.
//   • Transport detail (Streamable HTTP / Legacy SSE / stdio) folded into a
//     COLLAPSED disclosure inside that card — not its own full card.
//   • Per-client rows with last-seen, and a teach empty-state when none.
//
// What moved OUT (relocations are Wave-3 deep-link repoints, but the heavy
// chrome is gone now): the server-status orb hero (→ status strip), the Stripe
// integrations tile (Stripe is being cut from the product), and the lifecycle
// card (Launch-at-login / Check-for-Updates → Advanced). Restart + Copy-loopback
// live on the status strip. Every store call and async load is preserved.

import SwiftUI
import ServiceManagement
import AppKit
import Darwin

public struct ConnectionsSection: View {
    let statusBar: StatusBarController

    @State private var copiedEndpoint = false
    @State private var showTransports = false

    // Bridge lifecycle (self-contained: the merged Connection composite no longer
    // threads these through). `launchAtLogin` is the same @AppStorage key the
    // AppDelegate reads at startup, so this stays the single source of truth.
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var isApplyingLaunchAtLoginChange = false
    @State private var showLifecycle = false

    public init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    private var port: Int { ConfigManager.shared.ssePort }
    private var endpoint: String { "127.0.0.1:\(port)/mcp" }

    public var body: some View {
        // Hosted inside the ConnectionSection composite's outer scroll — no inner
        // ScrollView (it would nest scrolls). The composite supplies pane padding.
        VStack(spacing: BridgeTokens.Space.cardGap) {
            loopbackCard
            clientsCard
            lifecycleCard
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    // MARK: - Loopback MCP endpoint (PKT-810: bearer-exempt on loopback)

    private var loopbackCard: some View {
        let running = statusBar.isServerRunning
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Local clients")
                    Spacer()
                    BridgeDepLink("Configure ports") {
                        SettingsNavigation.shared.go(.advanced, anchor: "ports")
                    }
                }

                // Copyable loopback endpoint.
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg3)
                        .frame(width: 30, height: 30)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
                        .accessibilityHidden(true)
                    Text("http://\(endpoint)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(BridgeTokens.fg1)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { copyEndpoint() } label: {
                        Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(copiedEndpoint ? BridgeTokens.okText : BridgeTokens.fg3)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy loopback endpoint")
                    .accessibilityLabel(copiedEndpoint ? "Copied loopback endpoint" : "Copy loopback endpoint")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))

                Text("Local clients on this Mac connect with no token. Paste this endpoint into Claude Desktop or Claude Code.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)

                transportsDisclosure(running: running)
            }
        }
    }

    // MARK: - Transports (collapsed disclosure inside the loopback card)
    //
    // NOT a selector. The one `SSEServer` NIO listener on `ssePort` serves BOTH
    // the Streamable HTTP `/mcp` endpoint and the legacy SSE `/sse` path
    // concurrently and unconditionally; stdio is a separate, per-client transport
    // spawned on demand. All three run whenever the server is up — there is no
    // setting that turns one on instead of another. This is an INFORMATIONAL
    // status display, demoted to a collapsed disclosure so it costs zero vertical
    // until the user expands it.

    @ViewBuilder
    private func transportsDisclosure(running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showTransports.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg4)
                        .rotationEffect(.degrees(showTransports ? 90 : 0))
                    Text("Transports")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg3)
                    Text("All run together when the server is up")
                        .font(.system(size: 11))
                        .foregroundStyle(BridgeTokens.fg5)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transports detail")
            .accessibilityValue(showTransports ? "Expanded" : "Collapsed")

            if showTransports {
                VStack(spacing: 6) {
                    transportRow(name: "Streamable HTTP", endpoint: "127.0.0.1:\(port)/mcp", state: running ? .active : .idle)
                    transportRow(name: "Legacy SSE", endpoint: "127.0.0.1:\(port)/sse", state: running ? .active : .idle)
                    transportRow(name: "stdio", endpoint: "spawned per-client", state: .perClient)
                }
                .padding(.top, 6)
            }
        }
    }

    /// Live state of a transport surface. `active` = listening now,
    /// `idle` = server stopped, `perClient` = spawned on demand (no listener).
    private enum TransportState { case active, idle, perClient }

    private func transportRow(name: String, endpoint: String, state: TransportState) -> some View {
        HStack(spacing: 10) {
            transportDot(state)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg2)
                Text(endpoint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            transportStatePill(state)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(transportStateText(state)), \(endpoint)")
    }

    @ViewBuilder
    private func transportDot(_ state: TransportState) -> some View {
        switch state {
        case .active:
            Circle().fill(BridgeTokens.ok).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(BridgeTokens.fg4.opacity(0.6)).frame(width: 7, height: 7)
        case .perClient:
            Circle().strokeBorder(BridgeTokens.fg4.opacity(0.7), lineWidth: 1.5).frame(width: 7, height: 7)
        }
    }

    private func transportStateText(_ state: TransportState) -> String {
        switch state {
        case .active:    return "Active"
        case .idle:      return "Idle"
        case .perClient: return "Per-client"
        }
    }

    private func transportStatePill(_ state: TransportState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .active:    return ("Active", BridgeTokens.okText)
            case .idle:      return ("Idle", BridgeTokens.fg4)
            case .perClient: return ("Per-client", BridgeTokens.fg4)
            }
        }()
        return Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(color)
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

    // MARK: - Connected clients

    private var clientsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Connected clients")
                    Spacer()
                    Text("\(statusBar.connectedClients.count) connected · \(statusBar.activeToolCount) tools exposed")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                if statusBar.connectedClients.isEmpty {
                    emptyClients
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

    /// Teach empty-state: zero clients is the moment to point at the setup path.
    private var emptyClients: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No clients connected yet")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
            Text("Add the loopback endpoint above to Claude Desktop or Claude Code, then restart the client to connect.")
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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
            .accessibilityHidden(true)
            Text(clientName(client))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(clientName(client))
            Spacer(minLength: 8)
            Text(relativeTimestamp(from: client.connectedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg4)
            Circle()
                .fill(BridgeTokens.ok)
                .frame(width: 7, height: 7)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clientName(client)), connected \(relativeTimestamp(from: client.connectedAt))")
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

    // MARK: - Bridge lifecycle (collapsed — app lifecycle, not connectivity)
    //
    // Kept on this page (not relocated this pass — cross-page relocations are
    // deferred). Demoted to a collapsed disclosure so it costs minimal vertical:
    // Launch-at-login + Check-for-Updates. Restart lives on the status strip.

    private var lifecycleCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showLifecycle.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BridgeTokens.fg4)
                            .rotationEffect(.degrees(showLifecycle ? 90 : 0))
                        BridgeCardLabel("Bridge lifecycle")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bridge lifecycle")
                .accessibilityValue(showLifecycle ? "Expanded" : "Collapsed")

                if showLifecycle {
                    VStack(alignment: .leading, spacing: 12) {
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
                        }
                        Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
                        Button {
                            (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                        } label: {
                            Label("Check for Updates", systemImage: "arrow.down.circle")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .tint(BridgeTokens.accent)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private func lifecycleToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BridgeTokens.accent)
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
}
