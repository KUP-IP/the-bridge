// BridgeShell.swift — Settings-window shell chrome for The Bridge (v4).
// The "stage" window surface (solid canvas + carbon-fibre weave), the section-
// nav sidebar, the titlebar + footbar, and the custom vector glyphs (bow /
// crossed tools / two gears / key). Reconciled to the v4 geometry + material
// system in design/the-bridge-design-system/project — the `.bw-*` shell rules
// in bridge-ui.css + the Settings.html layout + tokens.css — the SSOT.
//
// All geometry comes from BridgeTokens.Space/Radius and all color/material from
// the W1 tokens (Weave / glassControl / bevelControl / hairline / fg* / ok …);
// nothing here hardcodes a covered palette value or chrome dimension.

import SwiftUI

// MARK: - PKT-1005 (Pillar C): stable AX-identifier convention

/// Central namespace for the Settings UI's accessibility identifiers
/// (PKT-1005). Before this packet there were ZERO `accessibilityIdentifier`
/// usages anywhere in `TheBridge/UI`, so on-device AX reads had to match on
/// volatile display labels. These ids are LABEL-INDEPENDENT and STABLE —
/// keyed off the `SettingsSection` case name and a fixed control slug — so the
/// headless UI-validation harness can target controls deterministically.
///
/// Convention: `bridge.settings.<section>.<control>` for per-section controls;
/// `bridge.settings.<chrome>` for shared chrome (nav row, title bar). The
/// `<section>` segment is the enum CASE NAME (e.g. `skills`, `orders`), never
/// the display label, so the id never churns when the chrome label changes.
public enum BridgeAXID {
    /// Root prefix for every Settings AX id.
    public static let root = "bridge.settings"

    /// Sidebar nav row for a section — `bridge.settings.nav.<caseName>`.
    public static func navRow(_ section: SettingsSection) -> String {
        "\(root).nav.\(String(describing: section))"
    }

    /// The section H1 title in the titlebar — `bridge.settings.title`.
    public static let titleBar = "\(root).title"

    /// A per-section control id — `bridge.settings.<caseName>.<control>`.
    public static func control(_ section: SettingsSection, _ control: String) -> String {
        "\(root).\(String(describing: section)).\(control)"
    }

    // ── Skills section control slugs (Pillar C priority surface) ─────────
    public enum Skills {
        private static func id(_ slug: String) -> String {
            BridgeAXID.control(.skills, slug)
        }
        /// Whole Skills section root container.
        public static let root          = id("root")
        /// The skills list / sidebar within the Skills detail.
        public static let list          = id("list")
        /// "List in routing index" toggle.
        public static let toggleRouting  = id("toggle.routing")
        /// "Enabled" toggle.
        public static let toggleEnabled  = id("toggle.enabled")
        /// The body-cache card refresh / cache control.
        public static let cacheRefresh   = id("cache.refresh")
        /// The body-cache status indicator.
        public static let cacheIndicator = id("cache.indicator")
        /// Visibility status indicator badge in the detail header.
        public static let statusIndicator = id("status.indicator")
        /// A skill row's disclosure / nav chevron.
        public static let navChevron     = id("nav.chevron")
        /// The delete / Trash control.
        public static let trash          = id("trash")
        /// The metadata grid container (3 cells post-PKT-1005 finding 1).
        public static let metadataGrid   = id("metadata.grid")
    }

    // ── Commands section control slugs (enum case `.orders`) ─────────────
    // Displays "Commands"; the id segment stays the stable `orders` case name.
    public enum Commands {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.orders, slug) }
        /// The consolidated header container.
        public static let header        = id("header")
        /// The Command Bridge master switch (global hot-key on/off).
        public static let toggleEnabled = id("toggle.enabled")
        /// The recordable global-shortcut editor field.
        public static let shortcutEditor = id("shortcut.editor")
        /// The command master–detail list.
        public static let list          = id("list")
    }

    // ── Jobs section control slugs (enum case `.jobs`) ───────────────────
    public enum Jobs {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.jobs, slug) }
        /// Primary "New job" button.
        public static let newJob        = id("new")
        /// "Pause all" button.
        public static let pauseAll      = id("pause.all")
        /// The job-search field.
        public static let search        = id("search")
        /// The scrollable jobs list.
        public static let list          = id("list")
        /// A single job list row (shared id; one per row).
        public static let row           = id("row")
    }

    // ── Tools section control slugs (enum case `.tools`) ─────────────────
    public enum Tools {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.tools, slug) }
        /// The module-group browser container (the whole tools list).
        public static let list          = id("list")
        /// A single module-group card row (shared id; one per group).
        public static let groupRow       = id("group.row")
        /// A dependency-link "Fix" button.
        public static let depFix         = id("dep.fix")
    }

    // ── Security section control slugs (enum case `.security`) ───────────
    // The merged Vault (credentials) + Gates (permissions) page.
    public enum Security {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.security, slug) }
        /// "Re-check all" permission button.
        public static let recheckAll    = id("recheck.all")
        /// The permission-grants grid container.
        public static let grantsList    = id("grants.list")
        /// A single permission grant tile (shared id; one per grant).
        public static let grantRow       = id("grant.row")
        /// Primary "Add credential" button.
        public static let addCredential  = id("credential.add")
        /// "Validate all" credentials button.
        public static let validateAll    = id("credential.validate.all")
        /// The stored-credentials list container.
        public static let credentialsList = id("credentials.list")
        /// A single stored-credential row (shared id; one per credential).
        public static let credentialRow  = id("credential.row")
        /// The credential auto-validate policy toggle.
        public static let togglePolicy   = id("toggle.policy")
    }

    // ── Connection section control slugs (enum case `.connection`) ───────
    // The merged Local (connections) + Remote (cloud access) page.
    public enum Connection {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.connection, slug) }
        /// The connected-clients list container.
        public static let clientsList   = id("clients.list")
        /// A single connected-client row (shared id; one per client).
        public static let clientRow      = id("client.row")
        /// The "Enable remote access" master toggle.
        public static let toggleRemote   = id("toggle.remote")
        /// The "Add to Claude" primary button.
        public static let addToClaude    = id("claude.add")
    }

    // ── Advanced section control slugs (enum case `.advanced`) ───────────
    public enum Advanced {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.advanced, slug) }
        /// "Check for updates" button.
        public static let checkUpdates  = id("updates.check")
        /// "Export diagnostics" button.
        public static let exportDiagnostics = id("diagnostics.export")
        /// The launch-at-login toggle.
        public static let toggleLaunchAtLogin = id("toggle.launchAtLogin")
        /// The SSE-port "Save" primary button.
        public static let savePort      = id("port.save")
        /// "Restart The Bridge" button.
        public static let restart       = id("restart")
        /// "Factory Reset" destructive button.
        public static let factoryReset  = id("factory.reset")
    }

    // ── Memory section control slugs (enum case `.memory`) ─────────────
    public enum Memory {
        private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
        /// Tab bar container.
        public static let tabBar        = id("tab.bar")
        /// Inbox tab button.
        public static func tab(_ name: String) -> String { id("tab.\(name)") }
        /// Voice memo review list container.
        public static let inboxList     = id("inbox.list")
        /// A single inbox row (shared id).
        public static let inboxRow      = id("inbox.row")
        /// Dismiss control on an inbox row.
        public static let dismiss       = id("inbox.dismiss")
        /// Reveal in Finder control.
        public static let revealInFinder = id("inbox.reveal")
        /// File as Memory disposition.
        public static let fileAsMemory   = id("inbox.fileAsMemory")
        /// Retry routing disposition.
        public static let retryRouting   = id("inbox.retryRouting")
        /// Mark handled disposition.
        public static let markHandled    = id("inbox.markHandled")
        /// Add reminder disposition.
        public static let addReminder    = id("inbox.addReminder")
        /// Agent should know disposition.
        public static let agentRemember  = id("inbox.agentRemember")
        /// Inbox filter chip bar.
        public static let inboxFilterBar = id("inbox.filterBar")
        /// Notion tab list container.
        public static let notionList     = id("notion.list")
        /// A Notion Memory row.
        public static let notionRow      = id("notion.row")
        /// Open-in-Notion control.
        public static let notionOpen     = id("notion.open")
        /// Agent tab list container.
        public static let agentList      = id("agent.list")
        /// An agent memory row.
        public static let agentRow       = id("agent.row")
        /// Agent scope filter menu.
        public static let agentScopeFilter = id("agent.filter.scope")
        /// Agent type filter menu.
        public static let agentTypeFilter  = id("agent.filter.type")
        // Pre-cockpit Process ids (process.list/preview/pipeline/dryRun/execute) were removed:
        // the PKT-MEM-106 0b cockpit replaced them with the `Process.*` nested enum below, and
        // they were orphaned (no view/test/manifest references).
        /// Processing settings pane.
        public static let processingPane   = id("processing.pane")
        /// Curator mode picker.
        public static let processingMode   = id("processing.mode")
        public static let processingApple  = id("processing.apple")
        public static let processingParakeet = id("processing.parakeet")
        public static let processingOllama = id("processing.ollama")
        // PKT-MEM-106 0c — OpenAI-compatible provider key controls.
        public static let processingProviderSave   = id("processing.provider.save")
        public static let processingProviderStatus = id("processing.provider.status")

        // ── PKT-MEM-106 0b Process cockpit AX contract ──────────────────
        // Stable per-zone/row/command identifiers keyed by memoId/intentId. Uses the
        // codebase `bridge.settings.memory.process.*` convention (the well-formedness
        // invariant, SettingsAXIdentifierTests.swift:190) — the packet's `memoryProcess.*`
        // shorthand maps to the `process.*` control slug here. Stable across filter/sort/relaunch.
        public enum Process {
            private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
            public static let memoList         = id("process.memoList")
            public static let intentTable      = id("process.intentTable")
            public static let detailInspector  = id("process.detailInspector")
            public static let activityStrip    = id("process.activityStrip")
            public static func memoRow(_ memoId: String) -> String { id("process.memoRow.\(memoId)") }
            public static func intentRow(_ intentId: String) -> String { id("process.intentRow.\(intentId)") }
            public static func registryRow(entity: String, rowId: String) -> String { id("process.registryRow.\(entity).\(rowId)") }
            public static func commit(_ intentId: String) -> String { id("process.commit.\(intentId)") }
            public static func primaryOverride(_ intentId: String) -> String { id("process.primaryOverride.\(intentId)") }
        }
    }
}

// MARK: - The stage (the window surface: solid canvas + carbon-fibre weave)

/// The Settings-window surface, full-bleed behind every glass card. This is the
/// SSOT `.bw-window` ground verbatim: `background-color: var(--canvas)` +
/// `background-image: var(--weave)` — a SOLID fill (carbon in dark, titanium in
/// light) with the faint carbon-fibre weave layered as texture, NO gradient.
/// Color enters the UI only through small accents (blue/gold) + the signals.
///
/// Note on the `Elevation.window` rung: in the locked design the *window shell*
/// is canvas + weave (NOT a `--glass-window` fill); the window's 14pt rounding,
/// `--edge-window` border, e4 shadow and window blur are drawn by the host
/// `NSWindow` chrome (SettingsWindow.swift), not painted here — so no glass fill
/// is applied to the stage. `Elevation.window` is reserved for any genuinely
/// floating in-app modal/popover surface.
public struct BridgeStage: View {
    public init() {}

    public var body: some View {
        ZStack {
            BridgeTokens.bgCanvas
            BridgeCarbonWeave()
        }
        .ignoresSafeArea()
    }
}

/// Subtle diagonal cross-hatch evoking carbon fibre, layered over the canvas
/// fill (tokens.css `--weave`). Faint by design and now fully token-driven via
/// `BridgeTokens.Weave`: a +45° highlight hatch and a -45° shade hatch, both at
/// the `Weave.step` (4pt) cadence. The DARK branch resolves to white@.02 /
/// black@.22 (the unchanged carbon weave); LIGHT resolves to the titanium
/// whisper (white@.45 / rgba(15,18,28,.022)) — no value is hardcoded here.
/// Drawn once per size in a `Canvas`.
struct BridgeCarbonWeave: View {
    var body: some View {
        // Pull the two hatch colors + the step straight from the W1 tokens so
        // the appearance flip lives in one place (BridgeTokens.Weave) and this
        // view never re-derives a palette value. Captured by value into the
        // cheap, deterministic Canvas closure.
        let step      = BridgeTokens.Weave.step
        let highlight = BridgeTokens.Weave.highlight
        let shadow    = BridgeTokens.Weave.shadow
        return Canvas { ctx, size in
            var light = Path()   // +45° highlight hatch
            var dark = Path()    // -45° shade hatch (offset half a step)
            var x: CGFloat = -size.height
            while x < size.width {
                light.move(to: CGPoint(x: x, y: 0));    light.addLine(to: CGPoint(x: x + size.height, y: size.height))
                dark.move(to: CGPoint(x: x + step / 2, y: 0));  dark.addLine(to: CGPoint(x: x + step / 2 + size.height, y: size.height))
                x += step
            }
            ctx.stroke(light, with: .color(highlight), lineWidth: 1)
            ctx.stroke(dark,  with: .color(shadow),    lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Custom vector glyphs (the four the operator flagged)

/// The four hero nav glyphs drawn from the design system's inline SVG
/// (Lucide/Tabler idiom), translated to a 24-grid SwiftUI path. Stroked with
/// the ambient foreground style so they inherit nav state colors.
public struct BridgeVectorIcon: View {
    public enum Glyph: Sendable { case skills, tools, advanced, credentials }
    public let glyph: Glyph
    public init(_ glyph: Glyph) { self.glyph = glyph }

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = (glyph == .advanced ? 1.4 : 1.8) * size / 24.0
            BridgeIconShape(glyph: glyph)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct BridgeIconShape: Shape {
    let glyph: BridgeVectorIcon.Glyph

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24.0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func ring(_ cx: CGFloat, _ cy: CGFloat, _ rr: CGFloat) -> CGRect {
            CGRect(x: (cx - rr) * s, y: (cy - rr) * s, width: 2 * rr * s, height: 2 * rr * s)
        }
        var path = Path()

        switch glyph {
        case .skills: // bow & arrow
            // arrow fletching (top-right) + shaft + nock (bottom-left)
            path.move(to: p(17, 3)); path.addLine(to: p(21, 3)); path.addLine(to: p(21, 7))
            path.move(to: p(21, 3)); path.addLine(to: p(6, 18))
            path.move(to: p(3, 18)); path.addLine(to: p(6, 18)); path.addLine(to: p(6, 21))
            // bow arc (three cubic segments + closing chord)
            path.move(to: p(16.5, 20))
            path.addCurve(to: p(19, 13.5),  control1: p(18.08, 18.42), control2: p(19, 15.9))
            path.addCurve(to: p(10.5, 5),   control1: p(19, 8.69),     control2: p(15.31, 5))
            path.addCurve(to: p(4, 7.5),    control1: p(8.08, 5),      control2: p(5.58, 5.91))
            path.addLine(to: p(16.5, 20))

        case .tools: // crossed hammer + wrench
            path.move(to: p(3, 21)); path.addLine(to: p(7, 21)); path.addLine(to: p(20, 8))
            path.addQuadCurve(to: p(16, 4), control: p(18.2, 5.8)) // ≈ a1.5 1.5 0 0 0 -4 -4
            path.addLine(to: p(3, 17)); path.addLine(to: p(3, 21))
            path.move(to: p(14.5, 5.5)); path.addLine(to: p(18.5, 9.5))
            path.move(to: p(12, 8)); path.addLine(to: p(7, 3)); path.addLine(to: p(3, 7)); path.addLine(to: p(8, 12))
            path.move(to: p(7, 8)); path.addLine(to: p(5.5, 9.5))
            path.move(to: p(16, 12)); path.addLine(to: p(21, 17)); path.addLine(to: p(17, 21)); path.addLine(to: p(12, 16))
            path.move(to: p(16, 17)); path.addLine(to: p(14.5, 18.5))

        case .advanced: // two gears
            path.addEllipse(in: ring(9, 9, 2.6))
            path.move(to: p(9, 3));    path.addLine(to: p(9, 4.6))
            path.move(to: p(9, 13.4)); path.addLine(to: p(9, 15))
            path.move(to: p(3, 9));    path.addLine(to: p(4.6, 9))
            path.move(to: p(13.4, 9)); path.addLine(to: p(15, 9))
            path.move(to: p(5.1, 5.1)); path.addLine(to: p(6.2, 6.2))
            path.move(to: p(11.8, 11.8)); path.addLine(to: p(12.9, 12.9))
            path.move(to: p(5.1, 12.9)); path.addLine(to: p(6.2, 11.8))
            path.move(to: p(11.8, 6.2)); path.addLine(to: p(12.9, 5.1))
            path.addEllipse(in: ring(16.5, 16.5, 1.9))
            path.move(to: p(16.5, 12.9)); path.addLine(to: p(16.5, 13.9))
            path.move(to: p(16.5, 20.1)); path.addLine(to: p(16.5, 19.1))
            path.move(to: p(12.9, 16.5)); path.addLine(to: p(13.9, 16.5))
            path.move(to: p(20.1, 16.5)); path.addLine(to: p(19.1, 16.5))
            path.move(to: p(14.4, 14.4)); path.addLine(to: p(15.1, 15.1))
            path.move(to: p(18.6, 18.6)); path.addLine(to: p(17.9, 17.9))
            path.move(to: p(14.4, 18.6)); path.addLine(to: p(15.1, 17.9))
            path.move(to: p(18.6, 14.4)); path.addLine(to: p(17.9, 15.1))

        case .credentials: // key
            path.addEllipse(in: ring(7.5, 15.5, 5.5))
            path.move(to: p(21, 2)); path.addLine(to: p(11.4, 11.6))
            path.move(to: p(15.5, 7.5)); path.addLine(to: p(18.5, 10.5)); path.addLine(to: p(22, 7)); path.addLine(to: p(19, 4))
        }
        return path
    }
}

// MARK: - Section nav (custom 188px .secnav)

/// The locked design's left section-nav. Replaces the native
/// NavigationSplitView sidebar so we control the glass + custom icons while
/// keeping `nav.section` as the single selection source (deep-link safe).
public struct BridgeSectionNav: View {
    @Binding public var selection: SettingsSection
    @State private var reviewBadgeCount: Int = MemoryReviewBadgeCounter.shared.pendingCount

    public init(selection: Binding<SettingsSection>) { self._selection = selection }

    public var body: some View {
        VStack(spacing: 1) {
            ForEach(SettingsSection.allCases) { section in
                BridgeSectionNavItem(
                    section: section,
                    isSelected: section == selection,
                    badgeCount: section == .memory ? reviewBadgeCount : 0,
                    action: { selection = section }
                )
            }
            Spacer(minLength: 0)   // `.bw-side-spacer` — pin rows to the top
        }
        // `.bw-sidebar`: padding 6px 10px 10px, 188pt wide, over the inset
        // `--well` fill with a `--hair-faint` trailing rule (SSOT bridge-ui.css).
        .padding(.top, 6)
        .padding(.bottom, BridgeTokens.Space.s3)        // 10
        .padding(.horizontal, BridgeTokens.Space.s3)    // 10
        .frame(width: BridgeTokens.Space.sidebarW)      // 188
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BridgeTokens.wellFill)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(width: 0.5)
        }
        // Restore the keyboard navigation NavigationSplitView's List gave us
        // for free: Up/Down arrows move `selection` to the previous/next
        // SettingsSection. Clamps at the ends (no wrap); mouse clicking and
        // the per-item visual states are untouched.
        .focusable()
        // Keep keyboard navigation (Up/Down arrows) but suppress the system
        // blue focus ring that otherwise outlines the whole sidebar — the
        // trailing hairline above is the only border we want (operator feedback).
        .focusEffectDisabled()
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onAppear { refreshReviewBadge() }
        .onReceive(NotificationCenter.default.publisher(for: .voiceMemoReviewDidChange)) { _ in
            refreshReviewBadge()
        }
    }

    private func refreshReviewBadge() {
        MemoryReviewBadgeCounter.shared.refresh()
        reviewBadgeCount = MemoryReviewBadgeCounter.shared.pendingCount
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = SettingsSection.allCases
        guard let current = sections.firstIndex(of: selection) else { return }
        switch direction {
        case .up:
            let next = max(sections.startIndex, current - 1)
            selection = sections[next]
        case .down:
            let next = min(sections.index(before: sections.endIndex), current + 1)
            selection = sections[next]
        default:
            break
        }
    }
}

struct BridgeSectionNavItem: View {
    let section: SettingsSection
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void
    @State private var hovering = false

    // `.bw-nav` row radius (SSOT bridge-ui.css = 7px).
    private let rowRadius: CGFloat = 7

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {   // `.bw-nav` gap: 9px
                icon
                    .frame(width: 15, height: 15)   // `.bw-nav svg` 15×15
                    .opacity(isSelected ? 1 : 0.9)  // svg opacity .9 → 1 on `.on`
                    // Selected glyph picks up the royal-blue link ink
                    // (`.bw-nav.on svg { color: var(--accent-link) }`).
                    .foregroundStyle(isSelected ? BridgeTokens.accentLink : BridgeTokens.fg3)
                Text(section.displayName)
                    // `.bw-nav` text: 13 / medium, fg-3 → fg-1 (hover/selected).
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(BridgeTokens.fg1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BridgeTokens.warnText.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(BridgeTokens.warnText.opacity(0.45), lineWidth: 0.5))
                        .accessibilityLabel("\(badgeCount) pending review")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)   // `.bw-nav` padding: 0 9px
            .frame(height: BridgeTokens.Space.navItemH)   // 30
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isSelected)   // --fast .15s
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .accessibilityLabel(section.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // PKT-1005 (Pillar C): stable, label-independent AX id for each sidebar
        // nav row — `bridge.settings.nav.<sectionCaseName>` (e.g. `…nav.skills`).
        // The convention keys off the SettingsSection CASE NAME, not the
        // display label, so the id is stable even if the chrome label churns.
        .accessibilityIdentifier(BridgeAXID.navRow(section))
    }

    @ViewBuilder private var icon: some View {
        // PKT-A: keep SF Symbols this pass; the three surviving custom vector
        // glyphs (skills / tools / advanced) stay. The merged Security +
        // Connection sections render their SF Symbols (lock.shield / network).
        switch section {
        case .skills:   BridgeVectorIcon(.skills)
        case .tools:    BridgeVectorIcon(.tools)
        case .advanced: BridgeVectorIcon(.advanced)
        default:        Image(systemName: section.icon).font(.system(size: 13))
        }
    }

    /// Row ink: fg-1 when selected OR hovered, fg-3 at rest (`.bw-nav` rules).
    private var textColor: Color {
        (isSelected || hovering) ? BridgeTokens.fg1 : BridgeTokens.fg3
    }

    /// `.bw-nav` background ladder. Selected = the raised neutral control thumb
    /// per the LOCKED SSOT (`.bw-nav.on { background: var(--glass-control);
    /// box-shadow: var(--bevel-control); border: .5px solid var(--hair); }`) —
    /// the accent stays reserved for primary actions/links/focus (the glyph
    /// alone carries the accent-link tint). Hover = the faint `--hover` wash.
    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
        if isSelected {
            shape
                .fill(BridgeTokens.glassControl)
                .bridgeBevel(BridgeTokens.bevelControl, radius: rowRadius)
                .overlay(shape.strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        } else if hovering {
            shape.fill(BridgeTokens.hoverFill)
        } else {
            shape.fill(Color.clear)
        }
    }
}

// MARK: - Hero titlebar + footbar

/// 38px titlebar (Settings Redesign PKT-A, B2.2): section name only,
/// LEADING-aligned beside the native traffic lights, NO bottom hairline.
/// Transparent + draggable; sits inside the full-size-content window. The
/// leading inset clears the traffic-light cluster (`Space.trafficGutter`),
/// and the section name is the canonical page H1 (was a centered
/// "The Bridge › {section}" breadcrumb at 44px).
public struct BridgeTitleBar: View {
    public let title: String
    public init(title: String) { self.title = title }

    public var body: some View {
        HStack(spacing: 0) {
            Text(title)
                // `.bw-titletext`: 13 / semibold, fg-2, -.1px tracking.
                .font(BridgeTokens.Typeface.base600)
                .tracking(-0.1)
                .foregroundStyle(BridgeTokens.fg2)
                .allowsHitTesting(false)   // keep the titlebar draggable
                // PKT-1005 (Pillar C): the section H1 is the per-section title
                // anchor — `bridge.settings.title` (its STRING VALUE is the
                // displayName, which the harness reads to confirm the active
                // section after a deep-link).
                .accessibilityIdentifier(BridgeAXID.titleBar)
            Spacer(minLength: 0)
        }
        // Leading inset clears the native traffic-light cluster (`--traffic-gutter`
        // = 78); transparent + no bottom hairline so the canvas/weave shows through.
        .padding(.leading, BridgeTokens.Space.trafficGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: BridgeTokens.Space.titleBar)   // 38
    }
}

/// 30px footbar (`.bw-foot`): integrated into the canvas — NO `chipFill` slab
/// background, just a faint `--hair-faint` top rule (the SSOT bridge-ui.css
/// `border-top`). Keeps the slim version readout + emerald health dot on the
/// trailing edge.
public struct BridgeFootBar: View {
    public let version: String
    public init(version: String) { self.version = version }

    public var body: some View {
        HStack(spacing: 10) {   // `.bw-foot` gap: 10px
            Text("The Bridge").foregroundStyle(BridgeTokens.fg4)
            Spacer(minLength: 0)
            Text(version).foregroundStyle(BridgeTokens.fg4)
            // `.dot.ok` — emerald fill + the soft glow (token `ok` @ ~55%).
            Circle().fill(BridgeTokens.ok).frame(width: 7, height: 7)
                .shadow(color: BridgeTokens.ok.opacity(0.55), radius: 4)
        }
        .font(BridgeTokens.Typeface.micro)   // foot meta: 10.5 (was 11)
        .padding(.horizontal, BridgeTokens.Space.s4)   // 14
        .frame(height: BridgeTokens.Space.footBar)     // 30
        // `.bw-foot` faint top rule — integrate into the canvas without a slab.
        .overlay(alignment: .top) {
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
    }
}
