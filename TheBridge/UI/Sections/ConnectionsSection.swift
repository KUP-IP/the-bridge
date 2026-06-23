// ConnectionsSection.swift — Settings → Connection → Local clients surface.
//
// Settings Redesign (PKT-connection): this is no longer a standalone pane with
// its own hero/lifecycle/integrations chrome. It is the LOCAL-CLIENTS body of
// the merged Connection page (ConnectionSection composite below in
// SettingsWindow+Sections.swift), which owns the live status strip and racks
// Local clients above Remote access.
//
// v4 "Liquid Glass, evolved" reskin (PKT-connection): repainted onto the W1
// token ladder + W2 component kit. Faithful to
// design/the-bridge-design-system/project/pages/page-connection.jsx — the
// HEADLINE Agent-handshake doctrine (global standing orders handed at connect,
// previewed via BridgePeek, edited in a BridgeFloat overlay with Preview|Edit
// tabs), the per-client Clients card (colored initial tile · `version ·
// transport · seen` mono subline · Live/Idle badge · per-client standing-orders
// PROFILE selector · row EXPANSION revealing the handed-tier line + View
// doctrine / Reset to global + the per-client CONNECT SNIPPET), and the "Local
// endpoint" card (copyable loopback + a Transports DISCLOSURE). Both themes
// resolve for free through the adaptive tokens. Every store call + async load is
// preserved.
//
// Standing-orders model note (IA change 2026-06-12): the GLOBAL default doctrine
// shown in the handshake peek and edited in the Preview|Edit overlay is now
// STORE-BACKED — it loads from and saves to the real `StandingOrdersStore` (the
// same single-document store the standing_orders_* MCP tools and the handshake
// `instructions` read), reusing the optimistic-concurrency load/save wiring that
// used to live in the Commands page's doctrine editor. Editing it here persists
// to disk and is delivered to every MCP client at the next handshake. The
// trusted/locked profiles remain read-only DESIGN PRESETS (`defaultDoctrine`).
// Per-client profile *assignment* is still design-ahead session `@State` (the
// operator is building that backend) and is called out in the packet receipt.
//
// What stays here (the trusted loopback surface, PKT-810 model):
//   • The loopback `127.0.0.1:{ssePort}/mcp` endpoint as a copyable card with a
//     loopback-no-token honesty line.
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

// MARK: - Standing-orders profile model (design CN_PROFILES / CN_DOCTRINES)

/// The three standing-orders profiles a client can be handed at connect, ported
/// 1:1 from the design's `CN_PROFILES`. Each carries a `BridgeTier` (so the dot
/// + pill reuse the W2 tier ink) plus the design's own `tierLabel` headline
/// ("Balanced"/"Open"/"Confirm-all") and one-line `desc`.
enum CnProfile: String, CaseIterable, Identifiable, Hashable {
    case global, trusted, locked

    var id: String { rawValue }

    /// The display name shown in the selector + the expanded "Handed …" pill.
    var name: String {
        switch self {
        case .global:  return "Global default"
        case .trusted: return "Trusted dev"
        case .locked:  return "Locked down"
        }
    }

    /// The W2 security tier this profile maps to — drives the tier-color dot
    /// (`CN_TIERCOLOR`) and the tier pill ink/fill/border.
    var tier: BridgeTier {
        switch self {
        case .global:  return .notify
        case .trusted: return .open
        case .locked:  return .confirm
        }
    }

    /// The design's `tierLabel` headline (distinct from `BridgeTier.label`).
    var tierLabel: String {
        switch self {
        case .global:  return "Balanced"
        case .trusted: return "Open"
        case .locked:  return "Confirm-all"
        }
    }

    /// The one-line posture summary shown in the expanded row + the selector.
    var desc: String {
        switch self {
        case .global:  return "reads run free · writes notify · irreversible confirms"
        case .trusted: return "reads + writes run free · sends and deletes confirm"
        case .locked:  return "every non-read call asks first · no standing grants"
        }
    }

    /// The default doctrine markdown for this profile (`CN_DOCTRINES`). The
    /// `.global` body is the editable one; the other two are read-only presets.
    var defaultDoctrine: String {
        switch self {
        case .global:
            return """
            ## Doctrine
            - **Least privilege** — request the narrowest tool tier that completes the task
            - **Confirm before irreversible** — send, pay, or delete always prompt
            - **Cite the source** — every fetched body links back to its Notion page or file

            ## Escalation
            Below the confidence floor (`0.80`) the agent stops and asks rather than guessing.
            """
        case .trusted:
            return """
            ## Doctrine
            - **Move fast** — file, git and notion tools run at Open
            - **Still confirm** — outbound messages, mail and payments always prompt
            - **Full context** — the whole skill index is offered, not just routing

            ## Scope
            For an agent on a machine you control. Read + write run freely; only sends and deletes confirm.
            """
        case .locked:
            return """
            ## Doctrine
            - **Confirm everything** — all non-read tools run at Confirm
            - **No standing grants** — always-allow is ignored for this client
            - **Routing only** — palette-only skills are hidden

            ## Scope
            The strictest doctrine — for an untrusted or shared client. Every write, send and delete is confirmed.
            """
        }
    }
}

/// Per-client connect metadata derived from a live `ConnectedClient`. The live
/// MCP `clientInfo` only carries name + version + connect time, so the colored
/// initial, brand tint, transport label, and connect snippet are derived from
/// the client name (matching the design's `CN_CLIENTS` look). Unknown clients
/// get a neutral fallback tile + a generic loopback snippet — never blank.
private struct CnClientMeta {
    let initial: String
    let color: Color
    let transport: String
    let snippetLabel: String
    let snippet: String

    /// Derive the brand chrome for a client name (case-insensitive contains).
    static func derive(name: String, endpoint: String) -> CnClientMeta {
        let lower = name.lowercased()
        let url = "http://\(endpoint)"
        if lower.contains("claude") && lower.contains("code") {
            return CnClientMeta(
                initial: "CC", color: NotionPalette.purple, transport: "stdio",
                snippetLabel: "terminal",
                snippet: "claude mcp add the-bridge --transport http \(url)")
        }
        if lower.contains("claude") {
            return CnClientMeta(
                initial: "C", color: NotionPalette.orange, transport: "Streamable HTTP",
                snippetLabel: "claude_desktop_config.json",
                snippet: "\"the-bridge\": {\n  \"url\": \"\(url)\"\n}")
        }
        if lower.contains("cursor") {
            return CnClientMeta(
                initial: "Cu", color: NotionPalette.blue, transport: "Streamable HTTP",
                snippetLabel: ".cursor/mcp.json",
                snippet: "\"the-bridge\": {\n  \"url\": \"\(url)\"\n}")
        }
        if lower.contains("raycast") {
            return CnClientMeta(
                initial: "R", color: NotionPalette.red, transport: "Streamable HTTP",
                snippetLabel: "Raycast → MCP servers",
                snippet: url)
        }
        // Neutral fallback for any other MCP client.
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        return CnClientMeta(
            initial: initial, color: NotionPalette.gray, transport: "Streamable HTTP",
            snippetLabel: "MCP client config",
            snippet: "\"the-bridge\": {\n  \"url\": \"\(url)\"\n}")
    }
}

public struct ConnectionsSection: View {
    let statusBar: StatusBarController

    @State private var copiedEndpoint = false
    @State private var showTransports = false

    // ── Agent-handshake / per-client standing-orders state ──────────────────
    /// The editable GLOBAL doctrine, STORE-BACKED: loaded from `StandingOrdersStore`
    /// on appear and rewritten on Save. The `defaultDoctrine` seed is only a
    /// pre-load placeholder shown for the brief moment before the async read lands.
    @State private var globalDoctrine = CnProfile.global.defaultDoctrine
    /// The in-flight Edit-tab draft (committed to the store + `globalDoctrine` on Save).
    @State private var doctrineDraft = CnProfile.global.defaultDoctrine
    /// The last-read store snapshot — carries the hash for optimistic-concurrency
    /// writes (so a Save can't silently stomp an out-of-band edit). nil until loaded.
    @State private var doctrineSnapshot: StandingOrdersStore.Snapshot? = nil
    /// One-shot load guard so re-renders don't re-read (and clobber an open draft).
    @State private var doctrineLoaded = false
    /// A transient store-load/save error surfaced in the overlay, if any.
    @State private var doctrineError: String? = nil
    /// Per-client profile assignment, keyed by client name. Absent ⇒ `.global`.
    /// (Design-ahead: session-scoped until the per-client backend lands.)
    @State private var clientProfiles: [String: CnProfile] = [:]
    /// The currently-expanded client row (name), or nil.
    @State private var openClient: String? = nil
    /// The doctrine overlay target profile, or nil when closed.
    @State private var docView: CnProfile? = nil
    /// The overlay's Preview|Edit tab (Edit is offered for `.global` only).
    @State private var docTab: DocTab = .preview
    /// Per-client connect-snippet copy confirmations, keyed by client name.
    @State private var copiedSnippet: String? = nil

    private enum DocTab: Hashable { case preview, edit }

    public init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    private var port: Int { ConfigManager.shared.ssePort }
    private var endpoint: String { "127.0.0.1:\(port)/mcp" }

    /// The profile assigned to a client (defaulting to `.global`).
    private func profile(for client: ConnectedClient) -> CnProfile {
        clientProfiles[client.name] ?? .global
    }

    /// Live client count + how many carry a non-global override (the handshake
    /// "N of M clients overridden" summary).
    private var liveCount: Int { statusBar.connectedClients.count }
    private var overrideCount: Int {
        statusBar.connectedClients.filter { profile(for: $0) != .global }.count
    }

    public var body: some View {
        // Hosted inside the ConnectionSection composite's outer scroll — no inner
        // ScrollView (it would nest scrolls). The composite supplies pane padding.
        VStack(spacing: BridgeTokens.Space.cardGap) {
            handshakeCard
            clientsCard
            loopbackCard
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        // Load the store-backed global doctrine once on appear.
        .task { await loadDoctrine() }
        // The doctrine overlay (`.scrim` + `.float`) floats over the whole page.
        .overlay { doctrineOverlay }
    }

    // MARK: - Agent handshake (the design's headline section)
    //
    // The global standing-orders doctrine handed to every agent the moment it
    // connects: a Global-default badge + a Balanced tier-pill + the "N of M
    // clients overridden" summary, over a BridgePeek preview that expands into
    // the editable doctrine overlay.

    private var handshakeCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(BridgeTokens.fg3)
                        .accessibilityHidden(true)
                    BridgeCardLabel("Agent handshake")
                    Text("handed to an agent the moment it connects")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    BridgeBadge("Global default", tone: .info, showsDot: true)
                    cnTierPill(text: CnProfile.global.tierLabel, tier: CnProfile.global.tier)
                    Spacer(minLength: 8)
                    Text("\(overrideCount) of \(liveCount) clients overridden below")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                }

                // Peek → editable doctrine overlay (Preview | Edit).
                BridgePeek(maxHeight: 132, onExpand: { openDoc(.global) }) {
                    BridgeMarkdown(globalDoctrine)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Global standing-orders doctrine, tap to view or edit")
            }
        }
    }

    /// A tier pill carrying CUSTOM text (the profile name or `tierLabel`) rather
    /// than the canonical `BridgeTier.label`. Mirrors `BridgeTierPill`'s look —
    /// tier-color dot + ink on a translucent tier-tinted capsule — but lets the
    /// label diverge as the design's `.tier-pill` does ("Balanced", "Trusted
    /// dev"). (`BridgeTierPill` hardcodes `tier.label`, so it can't carry these.)
    private func cnTierPill(text: String, tier: BridgeTier) -> some View {
        let pill = Capsule(style: .continuous)
        return HStack(spacing: 4) {
            Circle().fill(tier.ink).frame(width: 5, height: 5)
            Text(text).font(BridgeTokens.Typeface.cap)
        }
        .foregroundStyle(tier.ink)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(pill.fill(cnTierFill(tier)))
        .overlay(pill.strokeBorder(cnTierBorder(tier), lineWidth: 0.5))
    }

    /// The tier pill's translucent fill, matching `BridgeTier.pillFill` (which is
    /// fileprivate to the kit, so re-derived here from the public signal tokens).
    private func cnTierFill(_ tier: BridgeTier) -> Color {
        switch tier {
        case .open:    return BridgeTokens.ok.opacity(0.16)
        case .notify:  return BridgeTokens.accent.opacity(0.16)
        case .confirm: return BridgeTokens.warn.opacity(0.16)
        }
    }

    private func cnTierBorder(_ tier: BridgeTier) -> Color {
        switch tier {
        case .open:    return BridgeTokens.ok.opacity(0.32)
        case .notify:  return BridgeTokens.accentBorder
        case .confirm: return BridgeTokens.warn.opacity(0.34)
        }
    }

    // MARK: - Clients (per-client standing orders + connect snippet)

    private var clientsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Clients")
                    Spacer()
                    Text("standing orders assigned per client · \(liveCount) live · \(liveCount) known")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if statusBar.connectedClients.isEmpty {
                    emptyClients
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(statusBar.connectedClients.enumerated()), id: \.element.name) { _, client in
                            clientRow(client)
                                .accessibilityIdentifier(BridgeAXID.Connection.clientRow)   // PKT-1005 remainder (b)
                        }
                    }
                    .accessibilityIdentifier(BridgeAXID.Connection.clientsList)   // PKT-1005 remainder (b)
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
            message: "Add the loopback endpoint below to Claude Desktop or Claude Code, then restart the client to connect."
        )
        .accessibilityElement(children: .combine)
    }

    /// One connected-client row (`.cnp-row`): a colored INITIAL tile, the client
    /// name + a Live/Idle badge, a mono `version · transport · seen` sub-line, a
    /// per-client PROFILE selector, and a chevron that expands the row to the
    /// handed-tier line + View-doctrine / Reset-to-global + the connect snippet.
    @ViewBuilder
    private func clientRow(_ client: ConnectedClient) -> some View {
        let meta = CnClientMeta.derive(name: client.name, endpoint: endpoint)
        let prof = profile(for: client)
        let isOpen = openClient == client.name
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            // ── row head ──
            // The tile + name + subtitle + chevron form the expand affordance; the
            // profile selector is an INDEPENDENT sibling (a Menu nested inside an
            // expand Button would have its taps swallowed — the design's
            // CnProfileSelect stops row-head propagation for the same reason).
            HStack(spacing: 11) {
                expandHead(client, meta: meta, prof: prof, isOpen: isOpen)
                Spacer(minLength: 8)
                profileSelector(for: client, current: prof)
                expandChevron(client, isOpen: isOpen)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            // ── expanded body ──
            if isOpen {
                clientExpansion(client, meta: meta, prof: prof)
            }
        }
        .background(shape.fill(isOpen ? BridgeTokens.wellFillDeep : BridgeTokens.wellFill))
        .overlay(shape.strokeBorder(isOpen ? BridgeTokens.edgeRaise : BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: 10)
    }

    /// The tap-to-expand head: the colored tile + name + Live badge + the mono
    /// `version · transport · seen` sub-line, as a borderless Button toggling the
    /// row open. Kept separate from the profile Menu so neither swallows the
    /// other's taps.
    private func expandHead(_ client: ConnectedClient, meta: CnClientMeta, prof: CnProfile, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                openClient = isOpen ? nil : client.name
            }
        } label: {
            HStack(spacing: 11) {
                clientTile(meta)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(client.name)
                            .font(BridgeTokens.Typeface.body.weight(.semibold))
                            .foregroundStyle(BridgeTokens.fg1)
                            .lineLimit(1)
                        BridgeBadge("Live", tone: .ok, showsDot: true)
                    }
                    Text(clientSubtitle(client, meta: meta))
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(client.name) \(client.version), live, standing orders \(prof.name)")
        .accessibilityHint(isOpen ? "Collapse" : "Expand")
    }

    /// The expand chevron — its own tap target so the row toggles from the right
    /// edge too (rotates 90° when open).
    private func expandChevron(_ client: ConnectedClient, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                openClient = isOpen ? nil : client.name
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BridgeTokens.fg4)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    /// The colored initial tile (`.cnp-tile`): a 30×30 brand-tinted square with
    /// the white initial and an inset top rim-light.
    private func clientTile(_ meta: CnClientMeta) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(meta.color)
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                    .blendMode(.plusLighter)
            )
            .overlay(
                Text(meta.initial)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }

    /// The mono `version · transport · seen` sub-line (`.cnp-csub`).
    private func clientSubtitle(_ client: ConnectedClient, meta: CnClientMeta) -> String {
        let v = client.version.trimmingCharacters(in: .whitespaces)
        let ver = v.isEmpty ? "" : "\(v) · "
        return "\(ver)\(meta.transport) · \(relativeTimestamp(from: client.connectedAt))"
    }

    /// The expanded body (`.cnp-exp`): a hairline, the "Handed <tier-pill> on
    /// connect — <desc>" line with View-doctrine / Reset-to-global, and the
    /// per-client connect snippet code well.
    private func clientExpansion(_ client: ConnectedClient, meta: CnClientMeta, prof: CnProfile) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)

            // "Handed <tier-pill> on connect — <desc>" with the actions trailing.
            HStack(alignment: .center, spacing: 8) {
                Text("Handed")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                cnTierPill(text: prof.name, tier: prof.tier)
                Text("on connect — \(prof.desc)")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                BridgeButton("View doctrine", systemImage: "arrow.up.left.and.arrow.down.right",
                             variant: .default) {
                    openDoc(prof)
                }
                if prof != .global {
                    BridgeButton("Reset to global", variant: .default) {
                        clientProfiles[client.name] = .global
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // Card label "CONNECT SNIPPET" (uppercase + tracked) followed by
                // the snippet source in plain case (fg5) — filenames must NOT be
                // uppercased, so the two are separate Text runs.
                HStack(spacing: 0) {
                    Text("Connect snippet").bridgeCap()
                        .foregroundStyle(BridgeTokens.fg4)
                    Text("  · \(meta.snippetLabel)")
                        .font(BridgeTokens.Typeface.cap)
                        .foregroundStyle(BridgeTokens.fg5)
                }

                connectSnippetWell(client: client, meta: meta)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 13)
    }

    /// The connect-snippet code well (`.cnp-snip`): a recessed `wellFillDeep`
    /// block with the mono snippet + a check-confirm Copy button.
    private func connectSnippetWell(client: ConnectedClient, meta: CnClientMeta) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
        let copied = copiedSnippet == client.name
        return HStack(alignment: .top, spacing: 10) {
            Text(meta.snippet)
                .font(BridgeTokens.Typeface.mono)
                .foregroundStyle(BridgeTokens.fg2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            BridgeButton(copied ? "Copied" : "Copy",
                         systemImage: copied ? "checkmark" : nil,
                         variant: .default) {
                copySnippet(meta.snippet, for: client.name)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(shape.fill(BridgeTokens.wellFillDeep))
        .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
    }

    /// The per-client standing-orders PROFILE selector (`CnProfileSelect`): a
    /// compact dropdown with a leading tier-color dot + the profile name. The
    /// menu lists all three profiles, each a tier-color dot + name + tierLabel,
    /// with a checkmark on the current one. Uses the native `Menu` (the platform
    /// dropdown idiom) so keyboard + VoiceOver come for free.
    private func profileSelector(for client: ConnectedClient, current: CnProfile) -> some View {
        Menu {
            ForEach(CnProfile.allCases) { p in
                Button {
                    clientProfiles[client.name] = p
                } label: {
                    Label {
                        Text("\(p.name) — \(p.tierLabel)")
                    } icon: {
                        if p == current { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(current.tier.ink)
                    .frame(width: 7, height: 7)
                    .shadow(color: current.tier.ink.opacity(0.6), radius: 2.5)
                Text(current.name)
                    .font(BridgeTokens.Typeface.meta.weight(.medium))
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            .padding(.leading, 10).padding(.trailing, 9).padding(.vertical, 6)
            .frame(minWidth: 132, alignment: .leading)
            .background(profileSelectorChrome)
            .contentShape(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Standing orders for \(client.name)")
        .accessibilityValue(current.name)
    }

    private var profileSelectorChrome: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous)
        return shape.fill(BridgeTokens.glassControl)
            .overlay(shape.strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.control)
    }

    // MARK: - Doctrine overlay (Preview | Edit)
    //
    // The full `.scrim` + `.float` overlay a peek / View-doctrine expands into:
    // a header with a gate glyph, "Standing orders · <name>", the tier pill, a
    // Preview|Edit segment (Edit only for the global default; presets are
    // read-only), a Save (disabled until the draft is dirty), and a Close ·esc.
    // Body is the rendered doctrine (Preview) or an editable mono textarea (Edit).

    @ViewBuilder
    private var doctrineOverlay: some View {
        if let target = docView {
            BridgeFloat(onDismiss: closeDoc) {
                doctrineFloatHeader(target)
            } body: {
                doctrineFloatBody(target)
            }
            // esc-to-close: a hidden default-cancel button captures the key.
            .background(
                Button("", action: closeDoc)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            )
        }
    }

    @ViewBuilder
    private func doctrineFloatHeader(_ target: CnProfile) -> some View {
        Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(BridgeTokens.fg2)
            .accessibilityHidden(true)
        Text("Standing orders · \(target.name)")
            .font(BridgeTokens.Typeface.name)
            .foregroundStyle(BridgeTokens.fg1)
            .lineLimit(1)
        cnTierPill(text: target.tierLabel, tier: target.tier)
        if target == .global {
            BridgeSegmented(
                selection: $docTab,
                options: [(DocTab.preview, "Preview"), (DocTab.edit, "Edit")])
                .fixedSize()
        } else {
            Text("read-only · profile preset")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
        }
        Spacer(minLength: 8)
        if target == .global && docTab == .edit {
            BridgeButton("Save", systemImage: "checkmark", variant: .primary,
                         isEnabled: doctrineDraft != globalDoctrine) {
                Task { await saveDoctrine() }
            }
        }
        BridgeButton("Close", variant: .default, action: closeDoc)
    }

    @ViewBuilder
    private func doctrineFloatBody(_ target: CnProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Surface a store load/save failure (global only — presets can't fail).
            if target == .global, let err = doctrineError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(BridgeTokens.badText)
                    Text(err)
                        .font(BridgeTokens.Typeface.sub)
                        .foregroundStyle(BridgeTokens.badText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(BridgeTokens.bad.opacity(0.10), in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.input))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.input).strokeBorder(BridgeTokens.bad.opacity(0.30), lineWidth: 0.5))
            }
            if target == .global && docTab == .edit {
                doctrineEditor
            } else {
                BridgeMarkdown(doctrineBody(target))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The editable doctrine textarea (`<textarea>` in the design): a recessed
    /// mono `wellFillDeep` editor bound to the draft.
    private var doctrineEditor: some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.input, style: .continuous)
        return TextEditor(text: $doctrineDraft)
            .font(BridgeTokens.Typeface.mono)
            .foregroundStyle(BridgeTokens.fg2)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(shape.fill(BridgeTokens.wellFillDeep))
            .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.input)
            .accessibilityLabel("Doctrine markdown")
    }

    /// The doctrine body for a profile — the live edited global, or a preset.
    private func doctrineBody(_ target: CnProfile) -> String {
        target == .global ? globalDoctrine : target.defaultDoctrine
    }

    /// Open the doctrine overlay for a profile, seeding the Edit draft from the
    /// current global doctrine and resetting to the Preview tab.
    private func openDoc(_ target: CnProfile) {
        doctrineDraft = globalDoctrine
        docTab = .preview
        docView = target
    }

    private func closeDoc() { docView = nil }

    // MARK: - Store-backed global doctrine (StandingOrdersStore)
    //
    // The global default doctrine is the SAME single-document standing orders the
    // handshake `instructions` and the standing_orders_* MCP tools read. Load/save
    // reuse the optimistic-concurrency wiring (`read` carries a hash; `write`
    // passes `expectedHash`) lifted from the former Commands-page doctrine editor.

    /// Load the global doctrine from the store once on appear. Seeds the editor
    /// snapshot (for the optimistic-concurrency hash), the previewed body, and the
    /// Edit draft — but never clobbers an in-flight draft the user already opened.
    private func loadDoctrine() async {
        guard !doctrineLoaded else { return }
        do {
            try StandingOrdersStore.shared.seedIfEmpty()
            let s = try StandingOrdersStore.shared.read()
            await MainActor.run {
                self.doctrineSnapshot = s
                self.globalDoctrine = s.markdown
                // Only seed the draft if the overlay isn't already mid-edit.
                if self.docView == nil || self.docTab != .edit {
                    self.doctrineDraft = s.markdown
                }
                self.doctrineError = nil
                self.doctrineLoaded = true
            }
        } catch {
            await MainActor.run { self.doctrineError = error.localizedDescription }
        }
    }

    /// Persist the edited draft to the store (optimistic concurrency via the
    /// snapshot hash), then mirror it into `globalDoctrine` and return to Preview.
    /// A `write` also fans out a `resources/updated` notification so connected MCP
    /// clients re-fetch the new doctrine — i.e. the edit is delivered, not just
    /// shown.
    private func saveDoctrine() async {
        // Without a snapshot we have no hash to guard against; refuse rather than
        // risk stomping (the load runs on appear, so this is the rare race).
        guard let s = doctrineSnapshot else {
            await MainActor.run { self.doctrineError = "Standing orders not loaded yet — reopen and try again." }
            return
        }
        do {
            let new = try StandingOrdersStore.shared.write(doctrineDraft, expectedHash: s.hash)
            await MainActor.run {
                self.doctrineSnapshot = new
                self.globalDoctrine = new.markdown
                self.doctrineError = nil
                self.docTab = .preview
            }
        } catch {
            await MainActor.run { self.doctrineError = error.localizedDescription }
        }
    }

    // MARK: - Loopback MCP endpoint (PKT-810: bearer-exempt on loopback)

    private var loopbackCard: some View {
        let running = statusBar.isServerRunning
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    BridgeCardLabel("Local endpoint")
                    Spacer()
                    Text("loopback · never exposed")
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg5)
                }

                // Copyable loopback endpoint — an inset well (`.cnp-endpoint`):
                // icon tile · mono URL (accent-link) · copy affordance.
                endpointWell

                // Loopback honesty: local clients are token-exempt; the bearer
                // applies only off-loopback (the design's `Configure port` link).
                (
                    Text("Local clients on this Mac connect with ")
                    + Text("no token").foregroundColor(BridgeTokens.fg2).bold()
                    + Text(" — the bearer applies only off-loopback.")
                )
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg4)
                .fixedSize(horizontal: false, vertical: true)

                BridgeDepLink("Configure port") {
                    SettingsNavigation.shared.go(.advanced, anchor: "ports")
                }

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
    // until the user expands it. (The design draws three interactive toggles; the
    // backend truth is one listener — so we keep the disclosure honest rather
    // than offer switches that wouldn't do anything.)

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

    /// Copy a per-client connect snippet with a brief check-confirm.
    private func copySnippet(_ snippet: String, for clientName: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        copiedSnippet = clientName
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedSnippet == clientName { copiedSnippet = nil }
        }
    }

    private func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "connected now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
