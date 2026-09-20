// BridgeShell.swift — Settings-window shell chrome for The Bridge (v4 / #283).
// The "stage" window surface (solid canvas + carbon-fibre weave on the OUTER
// SHELL only), the collapsible section-nav (icon rail ↔ labeled rail), the
// opaque content pane, the titlebar + footbar, and the custom vector glyphs.
// Reconciled to the v4 geometry + material system plus the #283 Part 1
// restraint contract (weave not under panes; flat cards live in BridgeThemeV2).
//
// All geometry comes from BridgeTokens.Space/Radius and all color/material from
// the W1 tokens (Weave / glassControl / bevelControl / hairline / fg* / ok …);
// nothing here hardcodes a covered palette value or chrome dimension.

import AppKit
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

    /// Sidebar collapse/expand control — `bridge.settings.chrome.sidebar.toggle`.
    public static let sidebarToggle = "\(root).chrome.sidebar.toggle"

    /// Opaque content pane (no carbon weave) — `bridge.settings.chrome.content.pane`.
    public static let contentPane = "\(root).chrome.content.pane"

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
        /// Palette Search / favorites / create live on Command Bridge, not Settings.
        public static let searchPaletteHint = id("search.palette.hint")
        /// The command master–detail list.
        public static let list          = id("list")
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
        /// Dismiss control on an inbox row. Ported live into MemoryMemosTab (absorbed the
        /// old Inbox tab's disposition row — 2026-07-03 3-tab redesign).
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
        /// Open-in-Notion control. Ported live into MemoryMemosTab's "Filed in Notion" card
        /// (2026-07-03 3-tab redesign; the old standalone Notion tab is retired).
        public static let notionOpen     = id("notion.open")
        // NOTE (2026-07-03 integration cleanup): inboxList/inboxRow, notionList/notionRow/
        // notionRefresh, agentList/agentRow/agentScopeFilter/agentTypeFilter/agentPinButton/
        // agentForgetButton, surfacingCard, injectGlobalToggle/injectClientNameField/
        // injectAddOverride/injectRemoveOverride, and processingPane/processingMode/
        // processingApple/processingParakeet/processingOllama/processingProviderSave/
        // processingProviderStatus were removed here — all orphaned once
        // MemoryNotionTab/MemoryAgentTab/MemoryProcessingTab/MemorySurfacingSettingsCard
        // were deleted in the 3-tab redesign (Memos/Recall/Settings replace them; see
        // the Settings/Recall/Memos nested enums below for the live successors).
        // Pre-cockpit Process ids (process.list/preview/pipeline/dryRun/execute) were removed:
        // the PKT-MEM-106 0b cockpit replaced them with the `Process.*` nested enum below, and
        // they were orphaned (no view/test/manifest references).

        // ── 2026-07-03 redesign: Settings tab (Memos/Recall/Settings consolidation) ──
        // Fresh `settings.*` slugs for MemorySettingsTab — the real implementation of
        // the old Processing tab + the Agent tab's inline surfacing card, now merged
        // into one Settings tab per the mockup (page-memory.jsx SettingsTab). Distinct
        // from the legacy `processing.*`/`agent.inject.*` slugs above (now orphaned)
        // so the AX contract for the live tab doesn't collide with dead code.
        public enum Settings {
            private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
            /// Settings pane root.
            public static let pane = id("settings.pane")
            /// Curator routing card + mode picker + connected-agent banner.
            public static let curatorMode = id("settings.curator.mode")
            public static let curatorBanner = id("settings.curator.banner")
            /// Transcription ladder toggles.
            public static let ladderApple = id("settings.ladder.apple")
            public static let ladderSpeechAnalyzer = id("settings.ladder.speechAnalyzer")
            public static let ladderParakeet = id("settings.ladder.parakeet")
            /// Cloud enhancement card.
            public static let cloudBaseURL = id("settings.cloud.baseURL")
            public static let cloudModel = id("settings.cloud.model")
            public static let cloudEnabled = id("settings.cloud.enabled")
            public static let cloudKeyInput = id("settings.cloud.keyInput")
            public static let cloudKeySave = id("settings.cloud.keySave")
            public static let cloudKeyDelete = id("settings.cloud.keyDelete")
            public static let cloudKeyStatus = id("settings.cloud.keyStatus")
            /// Handshake memory inject card.
            public static let injectGlobal = id("settings.inject.global")
            public static let injectClientName = id("settings.inject.clientName")
            public static let injectAdd = id("settings.inject.add")
            // NOTE: no per-row container id (injectOverrideRow) — a container-level
            // .accessibilityIdentifier shadows descendant ids in the raw AX tree (Loop 1
            // finding, memory-swiftui-uiiter-log.md). The row is locatable via its Remove
            // button's id below, or by its client-name text.
            public static func injectRemove(_ client: String) -> String { id("settings.inject.remove.\(client)") }
        }

        // ── 2026-07-03 redesign: Recall tab (single-column MemoryStore browser) ──
        // Fresh `recall.*` slugs for MemoryRecallTab — replaces the old
        // `agent.*` ids above (now orphaned) with a naming scheme aligned to the
        // renamed tab. Same MemoryStore-backed list, just a new AX contract to
        // match the mockup's `.mem-recall-list` single-column card layout
        // (page-memory.jsx `function RecallTab()`).
        public enum Recall {
            private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
            /// List container.
            public static let list = id("recall.list")
            // NOTE: deliberately no per-row id here (mirrors MemorySettingsTab's
            // overrideRow precedent) — a card-level .accessibilityIdentifier shadows
            // every descendant control's own id in the raw AX tree (Loop 1 finding,
            // memory-swiftui-uiiter-log.md). Rows are locatable by their expand/pin/
            // forget button ids below, or by text content.
            /// Search-by-content field.
            public static let searchField = id("recall.search")
            /// Show full text / Show summary expand toggle on a row.
            public static let expandToggle = id("recall.expand")
            /// Pin / unpin on a row.
            public static let pinButton = id("recall.pin")
            /// Soft-forget on a row.
            public static let forgetButton = id("recall.forget")
            /// Empty state (no matches / no memories).
            public static let emptyState = id("recall.empty")
        }

        // ── 2026-07-03 redesign: Memos tab (twin master-detail, page-memory.jsx
        //    `MemosTab()`) — consolidates the old Process cockpit + Inbox triage
        //    queue. Fresh `memos.*` slugs for the new list/detail chrome; the
        //    underlying cockpit engine (intent tags, confirm, registry sheet,
        //    transcript expand/collapse, title rename/cloud) keeps its existing
        //    `process.*` ids above — only truly NEW controls get ids here.
        public enum Memos {
            private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
            /// Left-column memo list container (the twin master-detail list pane).
            public static let list = id("memos.list")
            /// Search-by-title/transcript field.
            public static let search = id("memos.search")
            /// Status filter pill bar (All/Review/Active/Filed).
            public static let filterBar = id("memos.filterBar")
            // NOTE (Loop 1 P1 fix, memory-swiftui-uiiter-log.md): deliberately no
            // card-level ids here for the Status card or the Process-this-memo card —
            // a card-level .accessibilityIdentifier shadows every descendant control's
            // own id in the raw AX tree (the same hazard already caught and fixed in
            // MemorySettingsTab Loop 1 and MemoryRecallTab Loop 1). Both cards are
            // locatable via their own descendant control ids (statusStepper,
            // technicalDetailsToggle/Body, Process.processLocal/.processCloud/.dryRun/
            // .refreshPreview) or by text content.
            /// The plain-language step row itself.
            public static let statusStepper = id("memos.statusStepper")
            /// "Technical details" disclosure toggle + body.
            public static let technicalDetailsToggle = id("memos.technicalDetails.toggle")
            public static let technicalDetailsBody = id("memos.technicalDetails.body")
        }

        // ── PKT-MEM-106 0b Process cockpit AX contract ──────────────────
        // Stable per-zone/row/command identifiers keyed by memoId/intentId. Uses the
        // codebase `bridge.settings.memory.process.*` convention (the well-formedness
        // invariant, SettingsAXIdentifierTests.swift:190) — the packet's `memoryProcess.*`
        // shorthand maps to the `process.*` control slug here. Stable across filter/sort/relaunch.
        public enum Process {
            private static func id(_ slug: String) -> String { BridgeAXID.control(.memory, slug) }
            public static let memoList         = id("process.memoList")
            public static let centerPane       = id("process.centerPane")
            public static let intentTags       = id("process.intentTags")
            public static func intentTagCheckbox(_ intentId: String) -> String { id("process.intentTag.\(intentId)") }
            public static let confirmButton    = id("process.confirmButton")
            public static let confirmSummary   = id("process.confirmSummary")
            public static let transcriptExpand = id("process.transcriptExpand")
            public static let transcriptCollapse = id("process.transcriptCollapse")
            public static let activityDrawer   = id("process.activityDrawer")
            public static let activityDrawerToggle = id("process.activityDrawerToggle")
            public static let activityDrawerCollapse = id("process.activityDrawerCollapse")
            public static let registryConfigureSheet = id("process.registryConfigureSheet")
            public static func memoRow(_ memoId: String) -> String { id("process.memoRow.\(memoId)") }
            public static func registryRow(entity: String, rowId: String) -> String { id("process.registryRow.\(entity).\(rowId)") }
            // PKT-MEM-114 P3b — detail-inspector title controls: operator rename (→ pinned
            // `.edited`) + the MANUAL Tier-3 cloud-title button (shown only when canRunCloud).
            public static let titleRename      = id("process.titleRename")
            public static let titleCloud       = id("process.titleCloud")
            /// PKT-MEM-124 — memo-level dry-run preview (voice_memo_process dryRun:true).
            public static let dryRun           = id("process.dryRun")
            /// PKT-MEM-121 — explicit Re-run Understand (invalidates triage + bypasses cache).
            public static let refreshPreview   = id("process.refreshPreview")
            /// PKT-MEM-122 — agent triage session banner + end control.
            public static let triageBanner       = id("process.triageBanner")
            public static let triageEndSession   = id("process.triageEndSession")
            /// W1 — opt-in Understand (inspect-only select until operator confirms).
            public static let processLocal       = id("process.processLocal")
            public static let processCloud       = id("process.processCloud")
            public static let processPrompt      = id("process.processPrompt")
            public static func intentInspector(_ intentId: String) -> String { id("process.intentInspector.\(intentId)") }
            /// PKT-MEM-134 — live agent processing badge (considering/committed) on an
            /// activity-drawer row, keyed by the event's `Identifiable.id` (== `eventId`).
            public static func liveProcessingBadge(_ eventId: String) -> String { id("process.liveProcessingBadge.\(eventId)") }
        }
    }
}

// MARK: - The stage (the window surface: solid canvas + carbon-fibre weave)

/// The Settings-window OUTER SHELL surface. Canvas + carbon-fibre weave sit
/// behind titlebar / sidebar / footbar only. Content panes (`BridgeContentPane`)
/// paint an opaque `bgRaised` fill on top so the weave never reads under cards
/// (#283). This is the SSOT `.bw-window` ground: solid fill (carbon in dark,
/// titanium in light) + weave as texture, NO gradient. Color enters the UI
/// only through small accents (blue/gold) + the signals.
///
/// Note on the `Elevation.window` rung: the *window shell* is canvas + weave
/// (NOT a `--glass-window` fill); the window's 14pt rounding, `--edge-window`
/// border, e4 shadow and window blur are drawn by the host `NSWindow` chrome
/// (SettingsWindow.swift), not painted here. `Elevation.window` is reserved
/// for genuinely floating in-app modal/popover surfaces.
public struct BridgeStage: View {
    public init() {}

    public var body: some View {
        ZStack {
            BridgeTokens.bgCanvas
            // Weave.placement is `.outerShell` — content panes cover this.
            BridgeCarbonWeave()
        }
        .ignoresSafeArea()
    }
}

/// Opaque Settings content pane. Solid raised fill, no carbon weave, no glass
/// sheen. Later slices compose cards on this ground via `BridgeContentCard`.
public struct BridgeContentPane<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BridgeTokens.ContentCard.fill)
            .accessibilityIdentifier(BridgeAXID.contentPane)
    }
}

/// Settings-shell geometry contract (#283). Standard window is the collapsed
/// (icon-rail) size; expanding the labeled rail may grow width. Zero scroll
/// of SHELL chrome when collapsed — sidebar rows + title + foot fit in
/// `settingsWindowH` without a sidebar ScrollView.
public enum SettingsShellLayout {
    public static func sidebarWidth(expanded: Bool) -> CGFloat {
        expanded ? BridgeTokens.Space.sidebarW : BridgeTokens.Space.sidebarCollapsedW
    }

    public static func contentSize(sidebarExpanded: Bool) -> CGSize {
        CGSize(
            width: BridgeTokens.Space.settingsWindowW
                + (sidebarExpanded ? BridgeTokens.Space.sidebarExpandDelta : 0),
            height: BridgeTokens.Space.settingsWindowH
        )
    }

    /// Titlebar + footbar — the horizontal chrome bands.
    public static var chromeBandHeight: CGFloat {
        BridgeTokens.Space.titleBar + BridgeTokens.Space.footBar
    }

    /// Sidebar column height at the collapsed (icon-rail) density: one row
    /// per section + the collapse toggle, 1pt gaps, 6/10 vertical padding.
    /// Must stay below `settingsWindowH − chromeBandHeight` so the rail
    /// never scrolls at the standard window size.
    public static var collapsedSidebarColumnHeight: CGFloat {
        let rows = CGFloat(SettingsSection.allCases.count)
        let gaps = max(0, rows - 1)
        let toggleRow: CGFloat = BridgeTokens.Space.navItemH + 8
        return 6 + BridgeTokens.Space.s3
            + rows * BridgeTokens.Space.navItemH
            + gaps
            + toggleRow
    }

    public static var collapsedFitsWithoutScroll: Bool {
        chromeBandHeight + collapsedSidebarColumnHeight <= BridgeTokens.Space.settingsWindowH
    }

    /// Grow the Settings window when the labeled rail expands. Collapse
    /// never shrinks — the operator may have resized.
    @MainActor
    public static func applyWindowGrowth(sidebarExpanded: Bool) {
        guard sidebarExpanded else { return }
        guard let window = NSApp.windows.first(where: { $0.title == "The Bridge Settings" }) else {
            return
        }
        let target = contentSize(sidebarExpanded: true)
        let current = window.contentRect(forFrameRect: window.frame).size
        if current.width + 0.5 < target.width {
            window.setContentSize(NSSize(width: target.width, height: max(current.height, target.height)))
        }
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
///
/// #283: Codex / Cursor / Claude Code collapse — icon rail ↔ labeled rail.
/// Collapsed width is `Space.sidebarCollapsedW` (52); expanded is
/// `Space.sidebarW` (188). Rows are a VStack (no ScrollView) so the rail
/// cannot scroll at the standard window size.
public struct BridgeSectionNav: View {
    @Binding public var selection: SettingsSection
    @Binding public var isExpanded: Bool
    @State private var reviewBadgeCount: Int = MemoryReviewBadgeCounter.shared.pendingCount

    public init(selection: Binding<SettingsSection>, isExpanded: Binding<Bool>) {
        self._selection = selection
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(spacing: 1) {
            ForEach(SettingsSection.allCases) { section in
                BridgeSectionNavItem(
                    section: section,
                    isSelected: section == selection,
                    isExpanded: isExpanded,
                    badgeCount: section == .memory ? reviewBadgeCount : 0,
                    action: { selection = section }
                )
            }
            Spacer(minLength: 0)   // `.bw-side-spacer` — pin rows to the top
            sidebarToggle
        }
        // `.bw-sidebar`: padding 6px 10px 10px, over the inset `--well` fill
        // with a `--hair-faint` trailing rule. Width follows expand state.
        .padding(.top, 6)
        .padding(.bottom, BridgeTokens.Space.s3)        // 10
        .padding(.horizontal, isExpanded ? BridgeTokens.Space.s3 : 8)
        .frame(width: SettingsShellLayout.sidebarWidth(expanded: isExpanded))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BridgeTokens.wellFill)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(width: 0.5)
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
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

    private var sidebarToggle: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: isExpanded ? 9 : 0) {
                Image(systemName: isExpanded ? "sidebar.leading" : "sidebar.left")
                    .font(.system(size: 13))
                    .frame(width: 15, height: 15)
                    .foregroundStyle(BridgeTokens.fg3)
                if isExpanded {
                    Text("Collapse")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, isExpanded ? 9 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: BridgeTokens.Space.navItemH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse sidebar" : "Expand sidebar")
        .accessibilityLabel(isExpanded ? "Collapse sidebar" : "Expand sidebar")
        .accessibilityIdentifier(BridgeAXID.sidebarToggle)
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
    var isExpanded: Bool = true
    var badgeCount: Int = 0
    let action: () -> Void
    @State private var hovering = false

    // `.bw-nav` row radius (SSOT bridge-ui.css = 7px).
    private let rowRadius: CGFloat = 7

    var body: some View {
        Button(action: action) {
            HStack(spacing: isExpanded ? 9 : 0) {   // `.bw-nav` gap: 9px when labeled
                ZStack(alignment: .topTrailing) {
                    icon
                        .frame(width: 15, height: 15)   // `.bw-nav svg` 15×15
                        .opacity(isSelected ? 1 : 0.9)
                        .foregroundStyle(isSelected ? BridgeTokens.accentLink : BridgeTokens.fg3)
                    if !isExpanded && badgeCount > 0 {
                        Circle()
                            .fill(BridgeTokens.warn)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                if isExpanded {
                    Text(section.displayName)
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
            }
            .padding(.horizontal, isExpanded ? 9 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: BridgeTokens.Space.navItemH)   // 30
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "" : section.displayName)
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

    /// `.bw-nav` background ladder. Selected = a flat control fill + hairline
    /// (#283: no bevel stacking on shell chrome). Hover = the faint `--hover`
    /// wash. The glyph alone carries the accent-link tint.
    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: rowRadius, style: .continuous)
        if isSelected {
            shape
                .fill(BridgeTokens.glassControl)
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
