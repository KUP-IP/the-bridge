// SettingsWindow.swift — macOS Settings/Preferences Window
// V1.2.0: Sidebar NavigationSplitView layout (replaces TabView).
// Jobs tab removed. Content restructured per UI/UX audit.
// BridgeTheme design system adopted. Bug fixes applied.
//
// History:
// V1-QUALITY-C2: Original tabbed Settings window (General, Permissions,
//   Connections, Tools, Jobs, Advanced). Opens via gear icon or Cmd+,.
// V1.2.0: NavigationSplitView sidebar, Jobs removed, App Identity +
//   Security Model moved to Advanced, Reset Onboarding moved to Advanced,
//   status indicator added to General, BridgeTheme tokens adopted,
//   Build Target uses runtime version, "Since now" timestamp fixed.
// PKT-362 D2: Removed static Sensitive Paths section from Permissions tab.
// PKT-363 D3: Added configurable Sensitive Paths list editor.
// PKT-363 D4: Restore Defaults merge + zero-path confirmation guard.
// PKT-362 D3: Re-check All uses animatedRecheckAll() for per-row feedback.
// PKT-362 D4: Reset TCC dialog rewritten with user-facing language.

import SwiftUI
import ServiceManagement
import AppKit

// Notification names moved to NotionBridge/Core/BridgeNotifications.swift

/// Manages the Settings NSWindow. Opens via gear icon in popover or Cmd+,.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let statusBar: StatusBarController
    private let permissionManager: PermissionManager

    /// cmd-ux W1 (instance-identity fix): the AppDelegate's ONE
    /// `@Observable` CommandsController, passed in directly at construction.
    /// Previously `show()` re-resolved this via `(NSApp.delegate as?
    /// AppDelegate)?.commandsController ?? CommandsController()`. When that
    /// cast returned a non-AppDelegate delegate (the `@NSApplicationDelegate-
    /// Adaptor` instance the launch registration runs on is not guaranteed to
    /// be the exact object `NSApp.delegate` hands back here), the `??`
    /// silently fell back to a BRAND-NEW controller — instance B — that no
    /// registration path ever publishes into. The launch
    /// `publishRegistration(.registered)` updated the AppDelegate's instance
    /// A, but the Settings UI observed the fresh instance B (forever
    /// `.unattempted`), so the header latched the false "⚠ Shortcut not
    /// active". Holding the AppDelegate's instance directly makes the
    /// registering controller and the UI-observed controller the SAME object
    /// — a true single source of truth, with no fragile delegate cast and no
    /// fresh-instance fallback.
    private let commandsController: CommandsController

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        commandsController: CommandsController
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self.commandsController = commandsController
    }

    /// Show the Settings window, or bring it to front if already open.
    /// WS-H (PKT-804): `section` deep-links the menu-bar quick-page straight
    /// to a Settings section; nil keeps the last-selected section.
    public func show(section: SettingsSection? = nil) {
        if let section {
            SettingsNavigation.shared.section = section
        }
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // cmd-ux W1: inject the AppDelegate's single observable
        // `CommandsController` into the SwiftUI environment ON THE ROOT
        // VIEW. SettingsView is hosted via NSHostingController in a plain
        // NSWindow (NOT a SwiftUI WindowGroup), so there is no scene to
        // inherit an `.environment` from — it MUST be applied here, to
        // the exact view passed into NSHostingController(rootView:).
        // SettingsView reads it via `@Environment`; this is what makes
        // the Commands status row reactive (Bug 2 structural fix).
        //
        // Instance-identity fix: `commandsController` is now the AppDelegate's
        // ONE instance, handed in at construction (see the stored property
        // above) — NOT re-resolved here via a `NSApp.delegate` cast that
        // could fall back to a fresh, never-published instance the UI would
        // then observe forever as `.unattempted`.
        let settingsView = SettingsView(
            statusBar: statusBar,
            permissionManager: permissionManager
        )
        .environment(commandsController)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "The Bridge Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // v3.7.2: the square-ish default the operator settled on — frame ≈
        // 1080×908 (content 1080×880; a standard non-full-size titlebar adds
        // ~28pt). Replaces the old tall "match macOS System Settings" 720×900.
        // Set the resize bounds FIRST so the content size below isn't clamped
        // by the prior 900-wide ceiling (that cap was the latent bug — it would
        // have squeezed a fresh build back to 900 wide).
        window.minSize = NSSize(width: 760, height: 600)
        window.maxSize = NSSize(width: 1600, height: 1300)
        window.setContentSize(NSSize(width: 1080, height: 880))
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // NO frame autosave (by design): open at the preferred square on EVERY
        // launch and on first install, centered on the active screen. A stale
        // autosaved frame — or a window-manager (Magnet) snap — must never
        // override the default. The window stays drag-resizable for the
        // session; it simply resets to the square next launch.
        // v3.7.6: system-tethered appearance — leave window.appearance UNSET so
        // the window follows the system (Light→titanium, Dark→carbon) and live-
        // adapts. Paint the dynamic canvas backing so a resize never flashes
        // system white and the chrome tracks the appearance too.
        window.backgroundColor = BridgeTokens.canvasNSColor
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[Settings] Window opened")
    }
}

// MARK: - Settings Navigation

/// Top-level section identity for the Settings window. Hoisted out of
/// SettingsView (WS-H, PKT-804) so the menu-bar quick-page can deep-link
/// directly to a section.
///
/// Settings Redesign PKT-A (2026-06-10): collapsed 10 → 7 sections in
/// conceptual-flow order (Orders → Skills → Jobs → Tools → Security →
/// Connection → Advanced). The merges fold:
///   • Commands           → Orders   (sub-area, anchor `commands`)
///   • Credentials        → Security (Vault tab,  anchor `vault`)
///   • Permissions        → Security (Gates tab,  anchor `gates`)
///   • Connections        → Connection (anchor `local`)
///   • Remote Access      → Connection (anchor `remote`)
///
/// **rawValue is decoupled from the display label.** rawValue is the STABLE
/// deep-link / MCP `bridge_settings_navigate` identifier and must not churn
/// (e.g. `orders` keeps the legacy "Standing Orders" id so existing
/// automations still resolve via the MCP back-compat aliases). The UI
/// (sidebar + title bar) renders `displayName` instead — "Commands",
/// "Security", "Connection".
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case orders     = "Standing Orders"   // display "Commands"; stable legacy MCP id
    case skills     = "Skills"
    case jobs       = "Jobs"
    case tools      = "Tools"
    case security   = "Security"          // Credentials + Permissions merged
    case connection = "Connection"        // Connections + Remote Access merged
    case advanced   = "Advanced"

    public var id: String { rawValue }

    /// The human label shown in the sidebar + title bar. Decoupled from
    /// `rawValue` so the deep-link/MCP ids stay stable while the chrome can
    /// show the snappier redesign names.
    public var displayName: String {
        switch self {
        case .orders:     return "Commands"
        case .skills:     return "Skills"
        case .jobs:       return "Jobs"
        case .tools:      return "Tools"
        case .security:   return "Security"
        case .connection: return "Connection"
        case .advanced:   return "Advanced"
        }
    }

    public var icon: String {
        switch self {
        case .orders:     return "command"
        case .skills:     return "sparkles"
        case .jobs:       return "clock.badge.checkmark"
        case .tools:      return "hammer"
        case .security:   return "lock.shield"
        case .connection: return "network"
        case .advanced:   return "wrench.and.screwdriver"
        }
    }
}

/// Shared selection model so the menu-bar quick-page can drive which Settings
/// section is shown even when the window is already open (WS-H, PKT-804).
///
/// PKT-A: opens by default to .orders (the Commands page — top of the
/// conceptual-flow sidebar order). The deep-link API also accepts an optional
/// `anchor` string so cross-page nav can land on a sub-section (e.g.
/// Vault/Gates inside Security, Local/Remote inside Connection, or a
/// credential row by slug).
@MainActor
public final class SettingsNavigation: ObservableObject {
    public static let shared = SettingsNavigation()
    @Published public var section: SettingsSection = .orders
    @Published public var anchor: String? = nil
    public init() {}

    /// Programmatic deep-link. Used by Dashboard rows + dep-link chips.
    public func go(_ section: SettingsSection, anchor: String? = nil) {
        self.section = section
        self.anchor = anchor
    }
}

// MARK: - Settings View

public struct SettingsView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager

    @ObservedObject var nav: SettingsNavigation

    /// cmd-ux W1: the single observable Commands source of truth,
    /// injected by `SettingsWindowController` onto the root view. Read
    /// here so the Commands status row + recorder glyph re-render the
    /// instant registration / hotkey / enabled state changes. Optional
    /// because the type is environment-injected (and SwiftUI previews /
    /// any non-injected host would otherwise crash) — a nil controller
    /// falls back to the persisted snapshot, exactly the old behaviour.
    @Environment(CommandsController.self) private var commandsController: CommandsController?

    // Token editing state (PKT-350 F1)
    @State var isEditingToken = false
    @State var newTokenValue = ""
    @State var tokenError: String?
    @State var tokenSaveSuccess = false
    @State var showResetConfirmation = false
    @State var showFactoryResetConfirmation = false
    @State var isRecheckingPermissions = false
    @State var permissionActionMessage: String?
    @State var ssePortInput = String(ConfigManager.shared.ssePort)
    @State var ssePortError: String?
    @State var ssePortSaveSuccess = false
    @State var showSSEPortRestartPrompt = false
    @State var ssePortRevertOnCancel: Int?
    @State var factoryResetMessage: String?
    @State var showResetBackgroundItemsConfirmation = false
    @State var resetBackgroundItemsMessage: String?
    @State var showTCCResetDialog = false

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        nav: SettingsNavigation = .shared
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self.nav = nav
    }

    public var body: some View {
        ZStack {
            BridgeStage()
            VStack(spacing: 0) {
                BridgeTitleBar(title: nav.section.displayName)
                HStack(spacing: 0) {
                    BridgeSectionNav(selection: $nav.section)
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                BridgeFootBar(version: "v\(appVersion) · build \(AppVersion.build)")
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        // v3.7.6: system-tethered appearance — no forced color scheme.
    }

    @ViewBuilder
    private var detailContent: some View {
        switch nav.section {
        case .orders: commandsSection
        case .skills: SkillsSection()
        case .jobs: jobsSection
        case .tools: toolsSection
        case .security: securitySection
        case .connection: connectionSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Shared Properties

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }

    /// cmd-ux: the persisted Commands-palette master toggle. Default
    /// `true` (palette ships ON) — matches `CommandsPaletteGate`'s
    /// default-enabled contract when the key has never been written.
    @AppStorage(BridgeDefaults.commandsPaletteEnabled) var commandsPaletteEnabled: Bool = true

    /// cmd-ux W1: whether the global hot-key is currently registered
    /// (drives Active vs "⚠ Shortcut unavailable"). Now read from the
    /// OBSERVED `CommandsController` — accessing its `@Observable`
    /// property inside the view body registers a dependency, so the
    /// status row re-renders the instant registration state changes.
    /// This is the structural fix for Bug 2: the old plain-computed
    /// `NSApp.delegate` snapshot was evaluated once and never re-read,
    /// so a working hot-key could still show "⚠ unavailable". A nil
    /// controller (non-injected host) falls back to the prior snapshot.
    var commandsPaletteRegistered: Bool {
        if let c = commandsController { return c.isRegistered }
        return (NSApp.delegate as? AppDelegate)?.isCommandsPaletteHotkeyRegistered ?? false
    }

    /// cmd-ux W1: the combo the recorder should DISPLAY — read from the
    /// OBSERVED controller so a just-recorded combo (or a rebind that
    /// fell back to the prior working combo) shows immediately and
    /// truthfully. Nil controller falls back to the persisted value.
    var commandsHotkeyConfig: HotkeyConfig {
        if let c = commandsController { return c.hotkeyConfig }
        return (NSApp.delegate as? AppDelegate)?.commandsHotkeyConfig ?? HotkeyConfig.loadPersisted()
    }

    /// cmd-ux W1/W2: the structured outcome of the last registration
    /// attempt, observed live. Drives the precise status message (a true
    /// combo collision vs a plumbing failure vs disabled). Nil controller
    /// degrades to `.unattempted` (generic mapping, prior behaviour).
    var commandsLastRegisterStatus: HotkeyRegisterStatus {
        // Trust the live box (via AppDelegate) for the value; observe the
        // controller for reactivity. The mirror can be transiently reset to
        // .unattempted while the hot-key is in fact registered.
        let observed = commandsController?.lastRegisterStatus
        return (NSApp.delegate as? AppDelegate)?.commandsLastRegisterStatus ?? observed ?? .unattempted
    }

    /// Change B: when true the recorder control is in capture mode —
    /// the next valid key-down with modifiers becomes the new combo.
    @State var isRecordingHotkey = false

    var ssePort: Int {
        ConfigManager.shared.ssePort
    }

    var maskedTokenLabel: String {
        let masked = NotionTokenResolver.maskedToken()
        if masked == "Not configured" {
            return "Not configured \u{26A0}\u{FE0F}"
        }
        return masked
    }

    /// Minimum OS matching SwiftPM deployment (not the machine's runtime version).
    var buildTargetString: String {
        "macOS \(BridgeConstants.minimumMacOSMarketing)"
    }

    /// Compact relative timestamp — mirrors DashboardView.relativeTime pattern.
    /// Fixes "Since now" edge case: returns "just now" for durations < 60s.
    func relativeTimestamp(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }

    // MARK: - Skills state (must be in struct body)
    @State var skillsManager = SkillsManager()
    // PKT-375: Screen output directory state
    @State var screenOutputDir: String = ConfigManager.shared.screenOutputDir
}
