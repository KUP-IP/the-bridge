// StandingOrdersSection.swift — Settings → Standing Orders pane.
// PKT-9 UI v3.5 · v3.7.6 redesign: single-panel Preview/Edit toggle editor with
// an "Open" → centered full-panel overlay, bottom-pinned token meter, gold token
// stat, adaptive titanium/carbon chrome. Real save/load/compose/routing logic
// preserved verbatim.

import SwiftUI
import AppKit

public struct StandingOrdersSection: View {
    @State private var snapshot: StandingOrdersStore.Snapshot? = nil
    @State private var draft: String = ""
    @State private var loadError: String? = nil
    @State private var saveMessage: String? = nil
    @State private var saveIsError: Bool = false
    @State private var selectedTemplate: StandingOrdersStore.Template? = nil
    @State private var cachedRouting: [RoutingSkillSummary] = []

    /// Which view the single editor panel shows (Preview = rendered markdown,
    /// Edit = raw mono TextEditor). Defaults to Preview, mirroring the design.
    private enum PanelMode: Hashable { case preview, edit }
    @State private var mode: PanelMode = .preview

    /// Whether the editor is expanded into the centered full-panel overlay.
    @State private var expanded = false

    /// The live delivery telemetry the "Delivery audit" card reads. Observing
    /// the @Observable singleton makes the card live-update as the transports
    /// record handshakes / resource reads / reminders calls.
    @State private var deliveryLog = DeliveryLog.shared
    /// Whether the debug timeline (recent raw events) is expanded.
    @State private var timelineExpanded = false

    private let tokenBudget = 4000

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                if let err = loadError { errorBanner(err) }
                editorCard
                deliveryAuditCard
                templatesCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay { expandOverlay }
        .task {
            await load()
            await refreshCachedRouting()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    Image(systemName: "scroll")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.accentLink)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Standing Orders")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("Your portable identity. Loaded by every MCP client at session start — edit once, applied everywhere.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    statTile(value: "\(snapshot?.estimatedTokens ?? 0)", label: "tokens", color: BridgeTokens.gold)
                    statTile(value: "\(cachedRouting.count)", label: "skills", color: BridgeTokens.ok)
                }
                HStack(spacing: 4) {
                    soIconButton("doc.on.doc", help: "Copy composed preview") { copyComposed() }
                    soIconButton("arrow.counterclockwise", help: "Revert to saved") {
                        draft = snapshot?.markdown ?? ""; saveMessage = nil
                    }
                }
            }
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

    private func soIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - Editor card (single-panel Preview/Edit toggle)
    //
    // One panel, switched by a segmented [Preview | Edit] toggle on the left of
    // the header; an "Open" button on the right expands the panel into a
    // centered full overlay. The token meter is pinned to the bottom of the card.

    private var editorCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    modeToggle
                    Spacer()
                    openButton
                }
                panelBody(expandedStyle: false)
                    .frame(height: 286)
                tokenMeter
            }
        }
    }

    /// Segmented [Preview | Edit] control — mirrors the design's `.cm-tabs`.
    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeTab("Preview", .preview)
            modeTab("Edit", .edit)
        }
        .padding(2)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    private func modeTab(_ label: String, _ value: PanelMode) -> some View {
        let on = mode == value
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { mode = value }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BridgeTokens.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Open" → expand the panel into the centered full overlay.
    private var openButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { expanded = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Open").font(.system(size: 12))
            }
            .foregroundStyle(BridgeTokens.fg2)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open full panel")
    }

    /// The single panel body — renders whichever mode is active. `expandedStyle`
    /// drives the larger typography used inside the full overlay.
    @ViewBuilder private func panelBody(expandedStyle: Bool) -> some View {
        switch mode {
        case .preview:
            ScrollView {
                SOMarkdownView(markdown: composedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(expandedStyle ? 18 : 14)
            }
            .background(BridgeTokens.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(BridgeTokens.accent.opacity(0.24), lineWidth: 0.5))
            .frame(maxHeight: .infinity)
        case .edit:
            VStack(alignment: .leading, spacing: 9) {
                TextEditor(text: $draft)
                    .font(.system(size: expandedStyle ? 13 : 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(expandedStyle ? 13 : 10)
                    .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                    .frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent).tint(BridgeTokens.accent)
                        .disabled(snapshot == nil || draft == snapshot?.markdown)
                    if let msg = saveMessage {
                        Text(msg).font(.caption)
                            .foregroundStyle(saveIsError ? BridgeTokens.bad : BridgeTokens.ok)
                    }
                    Spacer()
                }
            }
        }
    }

    private var tokenMeter: some View {
        let tokens = snapshot?.estimatedTokens ?? 0
        let frac = min(1.0, Double(tokens) / Double(tokenBudget))
        return HStack(spacing: 9) {
            Text("\(tokens) of \(tokenBudget.formatted()) tokens")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(meterTextColor(frac))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BridgeTokens.chipFill)
                    // green → branded blue (mid) → gold (90%) → red (last 10%),
                    // gradient mapped across the FULL track so the fill reveals
                    // the colour at its current position (mirrors the design CSS).
                    Capsule()
                        .fill(LinearGradient(
                            stops: [
                                .init(color: BridgeTokens.ok, location: 0.0),
                                .init(color: BridgeTokens.accentStrong, location: 0.5),
                                .init(color: BridgeTokens.gold, location: 0.9),
                                .init(color: BridgeTokens.bad, location: 1.0),
                            ],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width)
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(4, geo.size.width * frac))
                        }
                }
            }
            .frame(height: 6)
        }
    }

    /// The meter count text goes red once over the budget — matching the
    /// design's `.so-meter-num.danger`.
    private func meterTextColor(_ frac: Double) -> Color {
        frac >= 0.9 ? BridgeTokens.badText : BridgeTokens.fg3
    }

    // MARK: - Expand overlay (centered full panel)

    @ViewBuilder private var expandOverlay: some View {
        if expanded {
            ZStack {
                BridgeTokens.bgCanvas.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { collapse() }
                floatPanel
                    .padding(EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24))
                    .transition(.scale(scale: 0.93).combined(with: .opacity))
            }
            .onExitCommand { collapse() }
        }
    }

    private var floatPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                modeToggle
                Spacer()
                Button(action: collapse) {
                    HStack(spacing: 6) { Text("esc"); Text("✕") }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(BridgeTokens.fg3)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 11) {
                panelBody(expandedStyle: true)
                tokenMeter
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(BridgeTokens.bgRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.55), radius: 50, y: 24)
    }

    private func collapse() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { expanded = false }
    }

    // MARK: - Delivery audit · active sessions
    //
    // Truthful telemetry of what the server actually DID per connected client:
    // the handshake we DELIVERED (token count + when), the bridge:// resource
    // it FETCHED (when), and a freshness dot (emerald = the last read served the
    // current composition hash, amber = the orders changed since). We never
    // claim "Honored" — the server cannot observe whether a client obeyed the
    // orders, only what we shipped and what was read back.

    private var deliveryAuditCard: some View {
        let sessions = deliveryLog.sessions()
        let events = deliveryLog.timeline(limit: 30)
        return BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    BridgeCardLabel("Delivery audit · active sessions")
                    Spacer()
                    Text("\(sessions.count) connected")
                        .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg4)
                }

                if sessions.isEmpty {
                    Text("No clients connected.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sessions) { row in
                            sessionRow(row)
                        }
                    }
                }

                if !events.isEmpty {
                    Divider().overlay(BridgeTokens.hairline)
                    debugTimeline(events)
                }
            }
        }
    }

    private func sessionRow(_ row: SessionAudit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            freshnessDot(row.isFresh)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.clientName ?? "Unknown client")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                HStack(spacing: 6) {
                    if let tokens = row.deliveredTokens, let at = row.deliveredAt {
                        Text("Delivered · \(tokens) tok · \(relativeTime(at))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    // Truthful: only show "Fetched ✓" when a read actually
                    // happened. Absence is NOT rendered as "not honored".
                    if let readAt = row.lastResourceReadAt {
                        Text("Fetched ✓ · \(relativeTime(readAt))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.okText)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    /// Freshness dot: emerald when the last read served the CURRENT composition
    /// hash, amber when the orders changed since the last read. No read yet →
    /// a muted neutral dot (we say nothing about freshness we can't assert).
    @ViewBuilder private func freshnessDot(_ isFresh: Bool?) -> some View {
        let color: Color = {
            switch isFresh {
            case .some(true): return BridgeTokens.ok
            case .some(false): return BridgeTokens.warn
            case .none: return BridgeTokens.fg5
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5))
            .help(freshnessHelp(isFresh))
    }

    private func freshnessHelp(_ isFresh: Bool?) -> String {
        switch isFresh {
        case .some(true): return "Last read served the current Standing Orders."
        case .some(false): return "Standing Orders changed since this client last read them."
        case .none: return "No resource read yet for this session."
        }
    }

    @ViewBuilder private func debugTimeline(_ events: [DeliveryEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { timelineExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: timelineExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Debug timeline")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                    Text("\(events.count) recent")
                        .font(.system(size: 10))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                .foregroundStyle(BridgeTokens.fg3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if timelineExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(events) { ev in
                        HStack(spacing: 8) {
                            Text(eventKindLabel(ev.kind))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(eventKindColor(ev.kind))
                                .frame(width: 86, alignment: .leading)
                            Text(ev.clientName ?? "—")
                                .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg3)
                                .lineLimit(1)
                            if let uri = ev.uri {
                                Text(uri)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(BridgeTokens.fg4)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(relativeTime(ev.at))
                                .font(.system(size: 10)).foregroundStyle(BridgeTokens.fg4)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(10)
                .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func eventKindLabel(_ kind: DeliveryEventKind) -> String {
        switch kind {
        case .handshakeDelivered: return "delivered"
        case .resourceRead: return "fetched"
        case .reminderToolCall: return "reminder"
        case .skillFetched: return "skill"
        }
    }

    private func eventKindColor(_ kind: DeliveryEventKind) -> Color {
        switch kind {
        case .handshakeDelivered: return BridgeTokens.infoText
        case .resourceRead: return BridgeTokens.okText
        case .reminderToolCall: return BridgeTokens.warnText
        case .skillFetched: return BridgeTokens.infoText
        }
    }

    /// Compact relative time ("just now", "3m ago", "2h ago", "1d ago").
    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        return "\(h / 24)d ago"
    }

    // MARK: - Templates

    private var templatesCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Templates")
                    Spacer()
                    Text("Replace the body with a starter — copy your current orders first to keep a record.")
                        .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg4)
                }
                HStack(spacing: 10) {
                    ForEach(StandingOrdersStore.Template.allCases, id: \.self) { t in
                        Button {
                            draft = t.body; selectedTemplate = t
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(t.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(BridgeTokens.fg1)
                                Text(snippet(of: t.body))
                                    .font(.system(size: 11.5)).foregroundStyle(BridgeTokens.fg3)
                                    .lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(
                                selectedTemplate == t ? BridgeTokens.accent.opacity(0.07) : BridgeTokens.wellFill,
                                in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                selectedTemplate == t ? BridgeTokens.accent.opacity(0.45) : BridgeTokens.hairline,
                                lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        BridgeGlassCard {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BridgeTokens.bad)
                Text(message).font(.callout)
                Spacer()
            }
        }
    }

    // MARK: - Logic (unchanged)

    private var composedText: String {
        let body = draft.isEmpty ? (snapshot?.markdown ?? "") : draft
        let composed = StandingOrdersComposer.compose(standingOrders: body, skills: cachedRoutingSkills())
        return composed.text
    }

    private func copyComposed() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(composedText, forType: .string)
        saveMessage = "Composed preview copied"
        saveIsError = false
    }

    private func snippet(of s: String) -> String {
        s.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .prefix(2)
            .joined(separator: " ")
    }

    private func load() async {
        do {
            try StandingOrdersStore.shared.seedIfEmpty()
            let s = try StandingOrdersStore.shared.read()
            await MainActor.run {
                self.snapshot = s
                self.draft = s.markdown
                self.loadError = nil
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

    private func save() async {
        guard let s = snapshot else { return }
        do {
            let new = try StandingOrdersStore.shared.write(draft, expectedHash: s.hash)
            await MainActor.run {
                self.snapshot = new
                self.saveMessage = "Saved · \(new.estimatedTokens) tokens"
                self.saveIsError = false
            }
        } catch {
            await MainActor.run {
                self.saveMessage = error.localizedDescription
                self.saveIsError = true
            }
        }
    }

    private func cachedRoutingSkills() -> [RoutingSkillSummary] { cachedRouting }

    private func refreshCachedRouting() async {
        let manager = await MainActor.run { SkillsManager() }
        let parents = await SkillsCacheReader.shared.readAll()
        let parentByName: [String: CachedParent] = Dictionary(
            uniqueKeysWithValues: parents.map { ($0.parentTitle.lowercased(), $0) }
        )
        let summaries: [RoutingSkillSummary] = await MainActor.run {
            manager.routingSkillsForDiscovery.map { skill in
                let cached = parentByName[skill.name.lowercased()]
                let summary = skill.summary.isEmpty ? (cached?.parentTitle ?? skill.name) : skill.summary
                return RoutingSkillSummary(
                    slug: skill.name.lowercased().replacingOccurrences(of: " ", with: "-"),
                    name: skill.name,
                    domain: nil,
                    maturity: nil,
                    description: summary,
                    triggers: skill.triggerPhrases,
                    antiTriggers: skill.antiTriggerPhrases
                )
            }
        }
        await MainActor.run { self.cachedRouting = summaries }
    }
}

// MARK: - Lightweight markdown renderer (composed preview, "for human eyes")

/// Renders the composed standing-orders markdown as rich blocks — H1/H2 display
/// headers, bullet/numbered lists, and paragraphs with inline emphasis/code —
/// mirroring the design's `.so-preview`. Inline syntax (**bold**, `code`, *em*)
/// is parsed via AttributedString; block structure is line-driven.
struct SOMarkdownView: View {
    let markdown: String

    private enum Block: Identifiable {
        case h1(String), h2(String), bullet(String), numbered(String, String), paragraph(String), spacer
        var id: String { UUID().uuidString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
    }

    @ViewBuilder private func row(_ block: Block) -> some View {
        switch block {
        case .h1(let t):
            Text(inline(t)).font(.system(size: 19, weight: .semibold)).foregroundStyle(BridgeTokens.fg1)
                .padding(.bottom, 1)
        case .h2(let t):
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(BridgeTokens.hairline).frame(height: 0.5).padding(.top, 4)
                Text(inline(t)).font(.system(size: 14, weight: .semibold)).foregroundStyle(BridgeTokens.fg1)
            }
        case .bullet(let t):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(BridgeTokens.infoText.opacity(0.8))
                Text(inline(t)).foregroundStyle(BridgeTokens.fg2)
            }.font(.system(size: 12.5))
        case .numbered(let n, let t):
            HStack(alignment: .top, spacing: 8) {
                Text("\(n).").foregroundStyle(BridgeTokens.infoText.opacity(0.8)).monospacedDigit()
                Text(inline(t)).foregroundStyle(BridgeTokens.fg2)
            }.font(.system(size: 12.5))
        case .paragraph(let t):
            Text(inline(t)).font(.system(size: 12.5)).foregroundStyle(BridgeTokens.fg2)
                .fixedSize(horizontal: false, vertical: true)
        case .spacer:
            Spacer().frame(height: 2)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    private func parse() -> [Block] {
        var out: [Block] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(.spacer); continue }
            if line.hasPrefix("## ") { out.append(.h2(String(line.dropFirst(3)))) }
            else if line.hasPrefix("### ") { out.append(.h2(String(line.dropFirst(4)))) }
            else if line.hasPrefix("# ") { out.append(.h1(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if let m = line.firstMatch(of: /^(\d+)\.\s+(.*)$/) {
                out.append(.numbered(String(m.1), String(m.2)))
            }
            else { out.append(.paragraph(line)) }
        }
        return out
    }
}
