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

    public init(statusBar: StatusBarController, permissionManager: PermissionManager) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
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
        let commandsController = (NSApp.delegate as? AppDelegate)?.commandsController
            ?? CommandsController()

        let settingsView = SettingsView(
            statusBar: statusBar,
            permissionManager: permissionManager
        )
        .environment(commandsController)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "The Bridge Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
/// PKT-3 v3.5: 9-section sidebar reordered by most-visited-first, with
/// Standing Orders pinned top and Skills promoted to its own section
/// (was previously inline under Commands). Order matches design/shell.js
/// and the locked HTML mocks.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case standingOrders = "Standing Orders"
    case commands       = "Commands"
    case connections    = "Connections"
    case remoteAccess   = "Remote Access"
    case skills         = "Skills"
    case permissions    = "Permissions"
    case credentials    = "Credentials"
    case tools          = "Tools"
    case jobs           = "Jobs"
    case advanced       = "Advanced"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .standingOrders: return "scroll"
        case .commands:       return "command"
        case .connections:    return "network"
        case .remoteAccess:   return "cloud"
        case .skills:         return "sparkles"
        case .permissions:    return "lock.shield"
        case .credentials:    return "key.fill"
        case .tools:          return "hammer"
        case .jobs:           return "clock.badge.checkmark"
        case .advanced:       return "wrench.and.screwdriver"
        }
    }
}

/// Shared selection model so the menu-bar quick-page can drive which Settings
/// section is shown even when the window is already open (WS-H, PKT-804).
///
/// PKT-3 v3.5: opens by default to .standingOrders (top of the new
/// most-visited sidebar order). The deep-link API also accepts an
/// optional `anchor` string so cross-page nav can land on a sub-section
/// (e.g. credential row by slug).
@MainActor
public final class SettingsNavigation: ObservableObject {
    public static let shared = SettingsNavigation()
    @Published public var section: SettingsSection = .standingOrders
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
    @State var launchAtLoginError: String?
    @State var isApplyingLaunchAtLoginChange = false
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
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $nav.section) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .tint(NotionPalette.blue)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch nav.section {
        case .standingOrders: StandingOrdersSection()
        case .commands: CommandsSection()
        case .connections: connectionsSection
        case .remoteAccess: RemoteAccessSection()
        case .skills: SkillsSection()
        case .permissions: permissionsSection
        case .credentials: credentialsSection
        case .tools: toolsSection
        case .jobs: jobsSection
        case .advanced: advancedSection
        }
    }

    // MARK: - Shared Properties

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.marketing
    }

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false

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
        commandsController?.lastRegisterStatus ?? .unattempted
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
