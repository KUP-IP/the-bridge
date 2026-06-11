// StandingOrdersSection.swift — Settings → Orders (doctrine sub-area + composite host).
// PKT-9 UI v3.5 · v3.7.6 redesign · Settings-Redesign PKT-orders:
//
// This file now hosts BOTH the bespoke `OrdersSection` composite (the merged
// Orders | Commands page that replaces the generic BridgeMergedSection) AND the
// doctrine sub-area body `StandingOrdersBody`. The composite owns the persistent
// draft/selection state and feeds it to the two tab bodies as bindings, so a tab
// switch NEVER tears down an unsaved doctrine draft or the Commands selection.
//
// Real save/load/compose/routing logic preserved verbatim. The on-disk path
// (standing-orders/), the MCP standing_orders_* tools, and the "Standing Orders /
// constitution" wording all stay — only the section/tab label is "Orders".

import SwiftUI
import AppKit

// MARK: - Orders composite (bespoke merged page — replaces BridgeMergedSection)

/// The merged **Orders** Settings page: one shared header, a segmented
/// `Orders | Commands` strip (anchor-driven + `@AppStorage`-persisted), a
/// per-tab meta row, and the selected tab body filling the remaining height.
///
/// Persistent state for BOTH tabs lives HERE so switching tabs preserves an
/// unsaved doctrine draft and the Commands selection (the bodies are recreated
/// on switch but read their state from these bindings).
public struct OrdersSection: View {
    /// Deep-link anchor (e.g. `commands`) selecting the starting tab.
    let anchor: String?

    private enum Tab: String, Hashable, CaseIterable { case orders, commands }

    @AppStorage("settings.orders.selectedTab") private var storedTab: String = Tab.orders.rawValue
    @State private var selection: Tab

    // ── Doctrine (Orders tab) persistent state ──────────────────────────────
    @State private var snapshot: StandingOrdersStore.Snapshot? = nil
    @State private var draft: String = ""
    @State private var loadError: String? = nil
    @State private var cachedRouting: [RoutingSkillSummary] = []
    @State private var loaded = false

    // ── Commands tab persistent state ───────────────────────────────────────
    @AppStorage(BridgeDefaults.commandsPaletteEnabled) private var paletteEnabled: Bool = true
    @State private var commands: [CommandStore.Command] = []
    @State private var selectedSlug: String? = nil

    public init(anchor: String?) {
        self.anchor = anchor
        let initial = OrdersSection.tab(for: anchor)
            ?? Tab(rawValue: UserDefaults.standard.string(forKey: "settings.orders.selectedTab") ?? "")
            ?? .orders
        self._selection = State(initialValue: initial)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            tabBar
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .task {
            await loadDoctrine()
            await refreshCachedRouting()
        }
        .onChange(of: anchor) { _, newAnchor in
            if let t = OrdersSection.tab(for: newAnchor) { setTab(t) }
        }
    }

    // MARK: Header (shared section header — replaces both bespoke heroes)

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .orders)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: "Doctrine your clients load at session start, and the commands you fire from the Command Bridge.",
            systemImage: spec.systemImage,
            tint: spec.tint
        )
    }

    // MARK: Tab strip + per-tab meta row

    private var tabBar: some View {
        HStack(spacing: 12) {
            segmented
            Spacer(minLength: 12)
            metaRow
        }
    }

    /// Segmented `Orders | Commands` control — mirrors the doctrine mode toggle
    /// visual at full-section scope, focus-ring suppressed to match the sidebar.
    private var segmented: some View {
        HStack(spacing: 0) {
            tabButton("Orders", .orders)
            tabButton("Commands", .commands)
        }
        .padding(2)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orders section tabs")
    }

    private func tabButton(_ label: String, _ value: Tab) -> some View {
        let on = selection == value
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { setTab(value) }
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(minHeight: 28)
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
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Per-tab meta: Orders → token + skills stats; Commands → command/favorite
    /// counts + the labeled Command Bridge master switch (was the unlabeled hero
    /// toggle).
    @ViewBuilder private var metaRow: some View {
        switch selection {
        case .orders:
            HStack(spacing: 8) {
                metaStat(value: "\(snapshot?.estimatedTokens ?? 0)", label: "tokens", color: BridgeTokens.gold)
                metaStat(value: "\(cachedRouting.count)", label: "skills", color: BridgeTokens.okText)
            }
        case .commands:
            HStack(spacing: 10) {
                metaStat(value: "\(commands.count)", label: "commands", color: BridgeTokens.accentLink)
                metaStat(value: "\(favoriteCount)", label: "favorites", color: BridgeTokens.gold)
                commandBridgeSwitch
            }
        }
    }

    private func metaStat(value: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// The Command Bridge master switch — now a LABELED control (the hero
    /// toggle had only a tooltip). Destructive-global affordance deserves a
    /// visible label + a11y label.
    private var commandBridgeSwitch: some View {
        HStack(spacing: 8) {
            Text("Command Bridge")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
            Toggle("", isOn: $paletteEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: paletteEnabled) { _, newValue in
                    (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .help("Enable the global Command Bridge popup hot-key.")
        .accessibilityLabel("Command Bridge global hot-key")
        .accessibilityValue(paletteEnabled ? "on" : "off")
    }

    // MARK: Tab body

    @ViewBuilder private var tabBody: some View {
        switch selection {
        case .orders:
            StandingOrdersBody(
                snapshot: $snapshot,
                draft: $draft,
                loadError: $loadError,
                cachedRouting: $cachedRouting
            )
        case .commands:
            CommandsSection(
                commands: $commands,
                selectedSlug: $selectedSlug
            )
        }
    }

    // MARK: Tab selection

    private func setTab(_ t: Tab) {
        selection = t
        storedTab = t.rawValue
    }

    /// Resolve a deep-link anchor to a tab (Commands aliases open Commands;
    /// doctrine/standing/orders open Orders). Returns nil when the anchor names
    /// neither (caller keeps the persisted/default tab).
    private static func tab(for anchor: String?) -> Tab? {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
            !raw.isEmpty else { return nil }
        switch raw {
        case "commands", "command", "palette": return .commands
        case "orders", "doctrine", "standing", "standingorders": return .orders
        default: return nil
        }
    }

    private var favoriteCount: Int { commands.filter { $0.keySlot != nil }.count }

    // MARK: Doctrine load + routing (lifted from the old StandingOrdersSection)

    private func loadDoctrine() async {
        guard !loaded else { return }
        do {
            try StandingOrdersStore.shared.seedIfEmpty()
            let s = try StandingOrdersStore.shared.read()
            await MainActor.run {
                self.snapshot = s
                // Never blow away an in-flight draft the user already started.
                if self.draft.isEmpty { self.draft = s.markdown }
                self.loadError = nil
                self.loaded = true
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }
    }

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

// MARK: - Standing Orders body (doctrine tab — no hero)

/// The doctrine editor body for the Orders tab. Reads its persistent
/// draft/snapshot/routing state from the composite via bindings so a tab switch
/// preserves an unsaved draft. The single-panel Preview/Edit toggle, the "Open"
/// full overlay, and the bottom-pinned token meter are kept; the editor is now
/// FLEXIBLE-height (min 240, grows) and a card-footer Save with a dirty dot is
/// visible in BOTH modes. Delivery-audit + Templates collapse into one
/// default-collapsed disclosure.
struct StandingOrdersBody: View {
    @Binding var snapshot: StandingOrdersStore.Snapshot?
    @Binding var draft: String
    @Binding var loadError: String?
    @Binding var cachedRouting: [RoutingSkillSummary]

    @State private var saveMessage: String? = nil
    @State private var saveIsError: Bool = false
    @State private var selectedTemplate: StandingOrdersStore.Template? = nil

    private enum PanelMode: Hashable { case preview, edit }
    @State private var mode: PanelMode = .preview
    @State private var expanded = false

    /// The live delivery telemetry the "Delivery audit" sub-section reads.
    @State private var deliveryLog = DeliveryLog.shared
    @State private var timelineExpanded = false
    /// The merged Audit & Templates disclosure — default collapsed (~200px back).
    @State private var auditTemplatesExpanded = false

    private let tokenBudget = 4000

    /// Unsaved-edits flag — drives the dirty dot + Save enable.
    private var isDirty: Bool { snapshot != nil && draft != snapshot?.markdown }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let err = loadError { errorBanner(err) }
                editorCard
                auditTemplatesDisclosure
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .overlay { expandOverlay }
    }

    // MARK: Editor card (single-panel Preview/Edit toggle + footer Save)

    private var editorCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    modeToggle
                    Spacer()
                    soIconButton("doc.on.doc", help: "Copy composed preview") { copyComposed() }
                    soIconButton("arrow.counterclockwise", help: "Revert to saved") {
                        draft = snapshot?.markdown ?? ""; saveMessage = nil
                    }
                    openButton
                }
                panelBody(expandedStyle: false)
                    .frame(minHeight: 240, maxHeight: .infinity)
                tokenMeter
                saveFooter
            }
        }
    }

    /// Card-footer Save — visible in BOTH Preview and Edit (the old layout hid
    /// Save in Preview, silently stranding edits). A dirty dot signals unsaved
    /// changes; the inline message reuses the existing save/error copy.
    private var saveFooter: some View {
        HStack(spacing: 8) {
            if isDirty {
                Circle()
                    .fill(BridgeTokens.warnText)
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }
            Button("Save") { Task { await save() } }
                .buttonStyle(.borderedProminent).tint(BridgeTokens.accent)
                .disabled(snapshot == nil || !isDirty)
                .accessibilityLabel("Save standing orders")
            if let msg = saveMessage {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(saveIsError ? BridgeTokens.badText : BridgeTokens.okText)
                    .lineLimit(1)
            }
            Spacer()
        }
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
        .accessibilityLabel(help)
    }

    /// Segmented [Preview | Edit] control.
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
                .frame(minHeight: 28)
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
        .accessibilityAddTraits(on ? [.isSelected] : [])
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
            .frame(minHeight: 28)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open full panel")
        .accessibilityLabel("Open full panel")
    }

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
            TextEditor(text: $draft)
                .font(.system(size: expandedStyle ? 13 : 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(expandedStyle ? 13 : 10)
                .background(BridgeTokens.wellFillDeep, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Standing orders markdown editor")
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

    private func meterTextColor(_ frac: Double) -> Color {
        frac >= 0.9 ? BridgeTokens.badText : BridgeTokens.fg3
    }

    // MARK: Expand overlay (centered full panel)

    @ViewBuilder private var expandOverlay: some View {
        if expanded {
            ZStack {
                // Material scrim so the float reads as modal in light/titanium
                // (the old flat bgCanvas@0.6 was a pale wash in light mode).
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .overlay(BridgeTokens.bgCanvas.opacity(0.35).ignoresSafeArea())
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
                saveFooter
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

    // MARK: Audit & Templates (one default-collapsed disclosure — ~200px back)

    private var auditTemplatesDisclosure: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: auditTemplatesExpanded ? 14 : 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { auditTemplatesExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: auditTemplatesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BridgeTokens.fg3)
                        BridgeCardLabel("Audit & Templates")
                        Spacer()
                        Text("\(deliveryLog.sessions().count) connected")
                            .font(.system(size: 11))
                            .foregroundStyle(BridgeTokens.fg4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Audit and Templates")
                .accessibilityValue(auditTemplatesExpanded ? "expanded" : "collapsed")

                if auditTemplatesExpanded {
                    deliveryAuditSection
                    Divider().overlay(BridgeTokens.hairline)
                    templatesSection
                }
            }
        }
    }

    // MARK: Delivery audit · active sessions

    private var deliveryAuditSection: some View {
        let sessions = deliveryLog.sessions()
        let events = deliveryLog.timeline(limit: 30)
        return VStack(alignment: .leading, spacing: 10) {
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

    private func sessionRow(_ row: SessionAudit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            freshnessDot(row.isFresh)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.clientName ?? "Unknown client")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                HStack(spacing: 6) {
                    if let delivered = DeliveryAuditLabels.deliveredLabel(for: row),
                       let at = row.deliveredAt {
                        Text("\(delivered) · \(relativeTime(at))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    if let fetched = DeliveryAuditLabels.fetchedLabel(for: row),
                       let readAt = row.lastResourceReadAt {
                        Text("\(fetched) · \(relativeTime(readAt))")
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
                        .font(.system(size: 11))
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
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(eventKindColor(ev.kind))
                                .frame(width: 86, alignment: .leading)
                            Text(ev.clientName ?? "—")
                                .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg3)
                                .lineLimit(1)
                            if let uri = ev.uri {
                                Text(uri)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(BridgeTokens.fg4)
                                    .lineLimit(1)
                                    .help(uri)
                            }
                            Spacer(minLength: 4)
                            Text(relativeTime(ev.at))
                                .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg4)
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
        case .memoryToolCall: return "memory"
        }
    }

    private func eventKindColor(_ kind: DeliveryEventKind) -> Color {
        switch kind {
        case .handshakeDelivered: return BridgeTokens.infoText
        case .resourceRead: return BridgeTokens.okText
        case .reminderToolCall: return BridgeTokens.warnText
        case .skillFetched: return BridgeTokens.infoText
        case .memoryToolCall: return BridgeTokens.infoText
        }
    }

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

    // MARK: Templates

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BridgeCardLabel("Templates")
                Spacer()
                Text("Replace the body with a starter — copy your current orders first to keep a record.")
                    .font(.system(size: 11)).foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Replace the body with a starter — copy your current orders first to keep a record.")
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
                    .accessibilityLabel("Apply \(t.label) template")
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        BridgeGlassCard {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BridgeTokens.badText)
                Text(message).font(.callout)
                Spacer()
            }
        }
    }

    // MARK: Logic (unchanged)

    private var composedText: String {
        let body = draft.isEmpty ? (snapshot?.markdown ?? "") : draft
        let composed = StandingOrdersComposer.compose(standingOrders: body, skills: cachedRouting)
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
