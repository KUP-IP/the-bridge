// ConnectionsSection.swift — Settings → Connection → Local clients surface.
//
// Settings Redesign (PKT-connection): this is no longer a standalone pane with
// its own hero/lifecycle/integrations chrome. It is the LOCAL-CLIENTS body of
// the merged Connection page (ConnectionSection composite below in
// SettingsWindow+Sections.swift), which owns the live status strip and racks
// Local clients above Remote access.
//
// v4 "Liquid Glass, evolved" reskin (PKT-connection): repainted onto the W1
// token ladder + W2 component kit (BridgeGlassCard, BridgeListRow +
// BridgeListIconTile, BridgeStatusDot, BridgeBadge, BridgeEmptyStateView,
// BridgeButton). Faithful to design/the-bridge-design-system/project/pages/
// page-connection.jsx — the "Local endpoint" card (copyable loopback + a
// Transports DISCLOSURE) and the "Clients" card (per-client rows with a
// Live/Idle dot + mono `version · seen` sub-line). Both themes resolve for free
// through the adaptive tokens. Every store call + async load is preserved.
//
// What stays here (the trusted loopback surface, PKT-810 model):
//   • The loopback `127.0.0.1:{ssePort}/mcp` endpoint as a copyable card with a
//     plain "local clients connect with no token" line.
//   • Transport detail (Streamable HTTP / Legacy SSE / stdio) folded into a
//     COLLAPSED disclosure inside that card — not its own full card.
//   • Per-client rows with last-seen, and a teach empty-state when none.
//
// What moved OUT: the server-status orb hero (→ status strip), the Stripe
// integrations tile (Stripe is being cut from the product), and the Bridge
// lifecycle controls — the Launch-at-login toggle and Check-for-Updates button
// now live on the Advanced page (PKT-W3-lifecycle: app lifecycle, not
// connectivity). Restart + Copy-loopback live on the status strip. Every store
// call and async load is preserved.

import SwiftUI
import AppKit

public struct ConnectionsSection: View {
    let statusBar: StatusBarController

    @State private var copiedEndpoint = false
    @State private var showTransports = false

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

                // Copyable loopback endpoint — an inset well (`.cnp-endpoint`):
                // icon tile · mono URL (accent-link) · copy affordance.
                endpointWell

                Text("Local clients on this Mac connect with no token. Paste this endpoint into Claude Desktop or Claude Code.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)

                transportsDisclosure(running: running)
            }
        }
    }

    /// The loopback endpoint inset well (`.cnp-endpoint` in the design): a
    /// recessed `wellFill` row with the mono URL in the accent-link ink and a
    /// check-confirm copy button. Mirrors the Remote directory-URL row so both
    /// halves of the page read as siblings.
    private var endpointWell: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 10) {
            BridgeListIconTile(systemImage: "desktopcomputer")
                .accessibilityHidden(true)
            Text("http://\(endpoint)")
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.accentLink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            copyButton(
                copied: copiedEndpoint,
                help: "Copy loopback endpoint",
                label: copiedEndpoint ? "Copied loopback endpoint" : "Copy loopback endpoint",
                action: copyEndpoint
            )
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(shape.fill(BridgeTokens.wellFill))
        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
    }

    /// Shared check-confirm copy affordance (the `.btn.sm` copy in the design):
    /// a small borderless button that flips its glyph + ink to the ok signal on
    /// copy. Reused by the endpoint well.
    private func copyButton(copied: Bool, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(copied ? BridgeTokens.okText : BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
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
                withAnimation(.easeInOut(duration: 0.15)) { showTransports.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg4)
                        .rotationEffect(.degrees(showTransports ? 90 : 0))
                    Text("Transports")
                        .font(BridgeTokens.Typeface.cap)
                        .textCase(.uppercase)
                        .tracking(BridgeTokens.Typeface.trackCap)
                        .foregroundStyle(showTransports ? BridgeTokens.fg1 : BridgeTokens.fg3)
                    Text("· all run together when the server is up")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
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

    /// A transport status row, built on `BridgeListRow`: a status dot leading,
    /// the transport name + mono endpoint, and a signal badge trailing. The dot
    /// + badge carry the state (emerald active · neutral idle/per-client).
    private func transportRow(name: String, endpoint: String, state: TransportState) -> some View {
        BridgeListRow(
            title: name,
            subtitle: endpoint,
            subtitleMono: true,
            leading: { BridgeStatusDot(transportSignal(state)).frame(width: 28, height: 28) },
            trailing: { transportBadge(state) }
        )
        .background(transportRowWell)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(transportStateText(state)), \(endpoint)")
    }

    private var transportRowWell: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return shape.fill(BridgeTokens.wellFill)
            .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private func transportSignal(_ state: TransportState) -> BridgeSignal {
        switch state {
        case .active:    return .ok
        case .idle:      return .neutral
        case .perClient: return .neutral
        }
    }

    private func transportStateText(_ state: TransportState) -> String {
        switch state {
        case .active:    return "Active"
        case .idle:      return "Idle"
        case .perClient: return "Per-client"
        }
    }

    @ViewBuilder
    private func transportBadge(_ state: TransportState) -> some View {
        switch state {
        case .active:    BridgeBadge("Active", tone: .ok)
        case .idle:      BridgeBadge("Idle", tone: .neutral)
        case .perClient: BridgeBadge("Per-client", tone: .neutral)
        }
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
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Connected clients")
                    Spacer()
                    Text("\(statusBar.connectedClients.count) connected · \(statusBar.activeToolCount) tools exposed")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                }
                if statusBar.connectedClients.isEmpty {
                    emptyClients
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(statusBar.connectedClients.enumerated()), id: \.element.name) { _, client in
                            clientRow(client)
                        }
                    }
                }
            }
        }
    }

    /// Teach empty-state: zero clients is the moment to point at the setup path.
    /// Uses the shared `BridgeEmptyStateView` (centered glyph · title · copy).
    private var emptyClients: some View {
        BridgeEmptyStateView(
            systemImage: "bolt.horizontal.circle",
            title: "No clients connected yet",
            message: "Add the loopback endpoint above to Claude Desktop or Claude Code, then restart the client to connect."
        )
        .accessibilityElement(children: .combine)
    }

    /// One connected-client row on `BridgeListRow`: a glyph tile leading, the
    /// client name + a mono `connect-time · last-ping` sub-line, and a live
    /// emerald status dot trailing (the design's per-client "Live" signal).
    private func clientRow(_ client: ConnectedClient) -> some View {
        BridgeListRow(
            title: clientName(client),
            subtitle: clientSubtitle(client),
            subtitleMono: true,
            systemImage: "bolt.horizontal.circle",
            trailing: {
                BridgeBadge("Live", tone: .ok, showsDot: true)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clientName(client)), \(clientSubtitle(client)), live")
    }

    private func clientName(_ client: ConnectedClient) -> String {
        let v = client.version.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? client.name : "\(client.name) · \(v)"
    }

    /// The mono sub-line: connect-time + last-ping (relative). When the connect
    /// time is recent the two collapse to one fragment.
    private func clientSubtitle(_ client: ConnectedClient) -> String {
        "connected \(relativeTimestamp(from: client.connectedAt)) · last ping \(relativeTimestamp(from: client.connectedAt))"
    }

    private func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
