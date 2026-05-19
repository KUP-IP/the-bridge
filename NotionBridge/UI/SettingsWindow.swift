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

        let settingsView = SettingsView(
            statusBar: statusBar,
            permissionManager: permissionManager
        )

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Notion Bridge Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 900))
        window.minSize = NSSize(width: 640, height: 720)
        window.maxSize = NSSize(width: 900, height: 1100)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("NotionBridgeSettings.v2")
        if window.frame.size == .zero || window.frame.origin == .zero {
            window.center()
        }
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
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case connections = "Connections"
    case credentials = "Credentials"
    case permissions = "Permissions"
    case tools = "Tools"
    case commands = "Commands"
    case jobs = "Jobs"
    case advanced = "Advanced"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .connections: return "network"
        case .permissions: return "lock.shield"
        case .tools: return "hammer"
        case .commands: return "command"
        case .credentials: return "key.fill"
        case .jobs: return "clock.badge.checkmark"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// Shared selection model so the menu-bar quick-page can drive which Settings
/// section is shown even when the window is already open (WS-H, PKT-804).
@MainActor
public final class SettingsNavigation: ObservableObject {
    public static let shared = SettingsNavigation()
    @Published public var section: SettingsSection = .connections
    public init() {}
}

// MARK: - Settings View

public struct SettingsView: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager

    @ObservedObject var nav: SettingsNavigation

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
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch nav.section {
        case .connections: connectionsSection
        case .permissions: permissionsSection
        case .tools: toolsSection
        case .commands: commandsSection
        case .credentials: credentialsSection
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

    /// cmd-ux: whether the global hot-key is currently registered (drives
    /// the Active vs "⚠ Shortcut unavailable" status row). Read live from
    /// the AppDelegate's `CommandBoxController`; `false` when the palette
    /// is off or registration failed (combo owned by another app).
    var commandsPaletteRegistered: Bool {
        (NSApp.delegate as? AppDelegate)?.isCommandsPaletteHotkeyRegistered ?? false
    }

    /// Change B: the combo the recorder should DISPLAY — the live
    /// controller's config when running, else the persisted value
    /// (falls back to `productionDefault`). Re-read on each render so a
    /// just-recorded combo shows immediately.
    var commandsHotkeyConfig: HotkeyConfig {
        (NSApp.delegate as? AppDelegate)?.commandsHotkeyConfig ?? HotkeyConfig.loadPersisted()
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
