// SettingsWindow+Sections.swift — Settings Section Views
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Each section is an extension on SettingsView for clean separation.

import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

extension SettingsView {
    // MARK: - Merged composite sections (Settings Redesign PKT-A)
    //
    // The 10→7 collapse folds five legacy panes into three merged sections.
    // PKT-A lands MINIMAL-BUT-FUNCTIONAL composites of the EXISTING section
    // views (each child keeps its own scroll + state); the polished single-
    // surface merges are later per-page packets (B/F/G). A lightweight
    // segmented tab switches between the two child surfaces, and the deep-link
    // `anchor` selects which tab opens first.

    /// Orders = Standing Orders doctrine + Commands palette config.
    /// Anchor `commands` opens the Commands tab.
    @ViewBuilder
    var ordersSection: some View {
        BridgeMergedSection(
            anchor: nav.anchor,
            tabs: [
                .init(id: "orders",   title: "Orders",   anchors: ["orders", "doctrine", "standing"]) {
                    AnyView(StandingOrdersSection())
                },
                .init(id: "commands", title: "Commands", anchors: ["commands", "command", "palette"]) {
                    AnyView(CommandsSection())
                },
            ]
        )
    }

    /// Security = Credentials (Vault) + Permissions (Gates).
    /// Anchor `gates`/`permissions` opens the Gates tab; everything else
    /// (incl. a credential-row slug like "notion") opens Vault.
    @ViewBuilder
    var securitySection: some View {
        BridgeMergedSection(
            anchor: nav.anchor,
            tabs: [
                .init(id: "vault", title: "Vault", anchors: ["vault", "credentials", "credential"]) {
                    AnyView(credentialsSection)
                },
                .init(id: "gates", title: "Gates", anchors: ["gates", "permissions", "permission", "privacy"]) {
                    AnyView(permissionsSection)
                },
            ]
        )
    }

    /// Connection = Connections (Local clients) + Remote Access.
    /// Anchor `remote` opens the Remote tab; everything else opens Local.
    @ViewBuilder
    var connectionSection: some View {
        BridgeMergedSection(
            anchor: nav.anchor,
            tabs: [
                .init(id: "local",  title: "Local",  anchors: ["local", "connections", "connection"]) {
                    AnyView(connectionsSection)
                },
                .init(id: "remote", title: "Remote", anchors: ["remote", "remoteaccess", "cloud"]) {
                    AnyView(RemoteAccessSection())
                },
            ]
        )
    }

    /// Factory Reset confirmation — skills defaults, env-based Notion token, restart guidance.
    var factoryResetConfirmationMessage: String {
        """
        This will clear: SSE port, stored credentials (Notion workspace tokens and Stripe), onboarding state, and macOS permissions for Notion Bridge.

        Skills are cleared to an empty list (add skills from Settings or via MCP when ready).

        If the app is launched with NOTION_API_TOKEN or NOTION_API_KEY in the environment, Notion may still resolve a token after reset (developer convenience). Unset those variables for a fully clean test.

        Restart the app after reset so permission and connection status stay accurate.
        """
    }

    // MARK: - Permissions (PKT-876 v3.6.1 — Liquid Glass reskin)

    var permissionsSection: some View {
        PermissionsSection(
            permissionManager: permissionManager,
            liveTools: statusBar.toolInfoList,
            isRecheckingPermissions: $isRecheckingPermissions,
            permissionActionMessage: $permissionActionMessage,
            showTCCResetDialog: $showTCCResetDialog,
            onResetTCC: {
                await resetTCCPermissions()
            }
        )
    }

    // MARK: - Connections (PKT-876 v3.6.1 — Liquid Glass reskin)

    var connectionsSection: some View {
        ConnectionsSection(
            statusBar: statusBar,
            permissionManager: permissionManager,
            launchAtLogin: $launchAtLogin,
            launchAtLoginError: $launchAtLoginError,
            isApplyingLaunchAtLoginChange: $isApplyingLaunchAtLoginChange
        )
    }

    // MARK: - Tools

    // PKT-366 F9: Skills manager for Skills tab

    var toolsSection: some View {
        // PKT-877 (Bridge v3.6·2): replace the flat 162-toggle list with
        // the grouped card stack. Per-tool toggles inside expanded cards
        // remain functional, and disabling a whole group triggers the
        // dispatch-time fail-closed safety contract (see ToolRouter +
        // ModuleGroupGate). The active-count badge in the status bar is
        // kept in sync via the same `BridgeDefaults.disabledTools` write
        // path the new list uses.
        ModuleGroupList(
            tools: statusBar.toolInfoList,
            nav: SettingsNavigation.shared
        )
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let disabled = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
            statusBar.activeToolCount = statusBar.toolInfoList.count - disabled.count
        }
    }

    // MARK: - Credentials (PKT-876 v3.6.1 — Liquid Glass reskin)

    var credentialsSection: some View {
        CredentialsSection(
            liveTools: statusBar.toolInfoList,
            anchor: nav.anchor
        )
    }

    // MARK: - Advanced (PKT-876 v3.6.1 — Liquid Glass reskin)

    var advancedSection: some View {
        AdvancedSection(
            statusBar: statusBar,
            permissionManager: permissionManager,
            appVersion: appVersion,
            ssePort: ssePort,
            ssePortInput: $ssePortInput,
            ssePortError: $ssePortError,
            ssePortSaveSuccess: $ssePortSaveSuccess,
            showSSEPortRestartPrompt: $showSSEPortRestartPrompt,
            ssePortRevertOnCancel: $ssePortRevertOnCancel,
            showResetConfirmation: $showResetConfirmation,
            showResetBackgroundItemsConfirmation: $showResetBackgroundItemsConfirmation,
            resetBackgroundItemsMessage: $resetBackgroundItemsMessage,
            showFactoryResetConfirmation: $showFactoryResetConfirmation,
            factoryResetMessage: $factoryResetMessage,
            onSaveSSEPort: { saveSSEPort() },
            onPerformFactoryReset: { await performFactoryReset() },
            onExportDiagnostics: { exportDiagnostics() },
            factoryResetConfirmationMessage: factoryResetConfirmationMessage,
            screenOutputDir: screenOutputDir
        )
    }


    // MARK: - Token Management

    /// Save token with validation and error handling (PKT-350: F1).
    func saveToken() {
        let validation = NotionTokenResolver.validateTokenFormat(newTokenValue)
        guard validation.valid else {
            tokenError = validation.error
            return
        }
        do {
            try NotionTokenResolver.writeToken(newTokenValue)
            tokenError = nil
            tokenSaveSuccess = true
            isEditingToken = false
            newTokenValue = ""
            NotificationCenter.default.post(name: .notionTokenDidChange, object: nil)
        } catch {
            tokenError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Persist SSE port to config.json (config -> env -> default fallback model).
    func saveSSEPort() {
        let trimmed = ssePortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            ssePortError = "Port must be a number between 1 and 65535."
            return
        }
        let previous = ConfigManager.shared.ssePort
        guard port != previous else {
            ssePortError = nil
            ssePortSaveSuccess = false
            return
        }
        ConfigManager.shared.ssePort = port
        ssePortInput = String(ConfigManager.shared.ssePort)
        ssePortError = nil
        ssePortSaveSuccess = false
        ssePortRevertOnCancel = previous
        showSSEPortRestartPrompt = true
    }

    /// Full local reset for pre-ship recovery/testing.
    func performFactoryReset() async -> (message: String, didFail: Bool) {
        var failures: [String] = []

        // 1) Clear app-scoped UserDefaults.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        } else {
            failures.append("user defaults")
        }

        // PKT-485: Restore default skills after clearing UserDefaults.
        skillsManager.resetToDefaults()

        // 2) Remove config file.
        let configURL = ConfigManager.shared.configFileURL
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try FileManager.default.removeItem(at: configURL)
            } catch {
                failures.append("config.json")
            }
        }

        // 3) Remove all saved keychain items for Notion Bridge.
        if !KeychainManager.shared.deleteAll() {
            failures.append("keychain")
        }

        // 3b) Drop in-memory Notion workspace clients so Settings/MCP match cleared storage without restart.
        await NotionClientRegistry.shared.resetAfterFactoryReset()
        await ConnectionHealthChecker.shared.invalidateAll()

        // 4) Reset TCC grants for current + legacy bundle IDs.
        let tccReset = await resetTCCPermissions()
        if tccReset.didFail {
            failures.append("TCC")
        }

        await permissionManager.recheckAllForTruth()
        NotificationCenter.default.post(name: .notionTokenDidChange, object: nil)
        UserDefaults.standard.set(false, forKey: BridgeDefaults.hasCompletedOnboarding)

        // PKT-485: Trigger onboarding window after factory reset.
        NotificationCenter.default.post(name: .resetOnboarding, object: nil)

        if failures.isEmpty {
            return ("Factory reset complete. Restart Notion Bridge, then re-grant permissions.", false)
        }
        return ("Factory reset finished with issues: \(failures.joined(separator: ", ")).", true)
    }

    // MARK: - Diagnostics

    func exportDiagnostics() {
        let lines = [
            "Notion Bridge Diagnostics",
            "========================",
            "App Version: v\(appVersion)",
            "MCP protocol: \(BridgeConstants.mcpProtocolVersion)",
            "Notion API: \(BridgeConstants.notionAPIVersion)",
            "Build Target: \(buildTargetString)",
            "Port: \(ssePort)",
            "Server Running: \(statusBar.isServerRunning)",
            "Tools Active: \(statusBar.activeToolCount)",
            "Uptime: \(statusBar.uptimeString)",
            "",
            "Permissions:",
            "  Accessibility: \(permissionManager.accessibilityStatus)",
            "  Screen Recording: \(permissionManager.screenRecordingStatus)",
            "  Full Disk Access: \(permissionManager.fullDiskAccessStatus)",
            "  Automation: \(permissionManager.automationStatus)",
            "  Contacts: \(permissionManager.contactsStatus)",
            "  Notifications: \(permissionManager.notificationStatus)",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
    }


    /// Opens System Settings to Login Items (tries Ventura+ URL first, then legacy Privacy pane).
    fileprivate static func openLoginItemsSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LoginItems"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Permissions Helpers

    func resetTCCPermissions() async -> (message: String, didFail: Bool) {
        let ids = ["kup.solutions.notion-bridge", "solutions.kup.keepr"]
        var failures: [String] = []

        for id in ids {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "All", id]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failures.append(id)
                }
            } catch {
                failures.append(id)
            }
        }

        await permissionManager.recheckAllForTruth()
        if failures.isEmpty {
            return (
                message: "Permissions reset. Re-grant each permission in System Settings → Privacy & Security, then quit and reopen Notion Bridge.",
                didFail: false
            )
        }
        return (message: "Reset partially failed. Some permissions may need to be reset manually in System Settings.", didFail: true)
    }
}

// MARK: - Integrated Tools Content

/// Displays Notion + Stripe integration status with provider labels,
/// multi-state indicators, and detail text (masked credential / primary badge).
private struct IntegratedToolsContent: View {
    @State private var notionConnection: BridgeConnection?
    @State private var stripeConnection: BridgeConnection?

    var body: some View {
        Group {
            integrationRow(
                icon: "network",
                provider: "Notion Workspace",
                connection: notionConnection
            )
            integrationRow(
                icon: "creditcard",
                provider: "Stripe API",
                connection: stripeConnection
            )
        }
        .task { await loadConnections() }
    }

    private func integrationRow(icon: String, provider: String, connection: BridgeConnection?) -> some View {
        let status = connection?.status ?? .notConfigured
        return LabeledContent {
            HStack(spacing: 6) {
                Image(systemName: status.systemImage)
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor(status))
                    .symbolEffect(.pulse, isActive: status == .checking)
                if status != .disconnected {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(statusColor(status))
                }
            }
        } label: {
            Label(provider, systemImage: icon)
        }
        .accessibilityLabel("\(provider): \(status.label)")
    }

    private func statusColor(_ status: BridgeConnectionStatus) -> Color {
        switch status {
        case .connected: return BridgeColors.success
        case .warning: return BridgeTokens.warn
        case .disconnected, .invalid: return BridgeColors.error
        case .notConfigured: return BridgeColors.secondary
        case .checking: return BridgeColors.secondary
        }
    }


    private func loadConnections() async {
        // PKT-440: Invalidate stale cache so re-validation fetches fresh results
        await ConnectionHealthChecker.shared.invalidateAll()

        do {
            // Phase 1: Instant snapshot with last-known status (PKT-440)
            let workspace = try await ConnectionRegistry.shared.listConnections(kind: .workspace, validateLive: false)
            let api = try await ConnectionRegistry.shared.listConnections(kind: .api, validateLive: false)
            let snapshotNotion = workspace.first { $0.provider == .notion }
            let snapshotStripe = api.first { $0.provider == .stripe }
            await MainActor.run {
                notionConnection = snapshotNotion
                stripeConnection = snapshotStripe
            }

            // Phase 2: Live validation — stream real statuses in as they resolve
            await withTaskGroup(of: Void.self) { group in
                if let conn = snapshotNotion {
                    group.addTask {
                        if let validated = try? await ConnectionRegistry.shared.validateConnection(id: conn.id) {
                            await MainActor.run { notionConnection = validated }
                        }
                    }
                }
                if let conn = snapshotStripe {
                    group.addTask {
                        if let validated = try? await ConnectionRegistry.shared.validateConnection(id: conn.id) {
                            await MainActor.run { stripeConnection = validated }
                        }
                    }
                }
            }
        } catch {
            // Silently handle — indicators stay as not configured
        }
    }
}

// MARK: - Connected Clients Content

/// Displays connected MCP clients with resolved names and no version numbers.
/// Resolves client identifiers against workspace connection names.
private struct ConnectedClientsContent: View {
    let clients: [ConnectedClient]
    @State private var connectionNames: [String: String] = [:]

    var body: some View {
        ForEach(clients, id: \.name) { client in
            LabeledContent(resolvedName(for: client)) {
                Text("Since \(relativeTimestamp(from: client.connectedAt))")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }
        }
        .task { await loadConnectionNames() }
    }

    private static let clientDisplayNames: [String: String] = [
        "notion-mcp-client": "Notion API"
    ]

    private func resolvedName(for client: ConnectedClient) -> String {
        if let mapped = Self.clientDisplayNames[client.name] {
            return mapped
        }
        for (_, connName) in connectionNames {
            if client.name.localizedCaseInsensitiveContains(connName)
                || connName.localizedCaseInsensitiveContains(client.name) {
                return connName
            }
        }
        return client.name
    }

    private func loadConnectionNames() async {
        do {
            let connections = try await ConnectionRegistry.shared.listConnections(kind: .workspace, validateLive: false)
            await MainActor.run {
                var names: [String: String] = [:]
                for conn in connections {
                    names[conn.id] = conn.name
                }
                connectionNames = names
            }
        } catch {
            // Fall back to raw client names
        }
    }

    private func relativeTimestamp(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}


// MARK: - Jobs Section (PKT-876 v3.6.1 — Liquid Glass reskin)

extension SettingsView {
    @ViewBuilder
    var jobsSection: some View {
        JobsSection()
    }
}

// MARK: - Merged-section tab host (Settings Redesign PKT-A)

/// Minimal segmented host for the three merged Settings sections (Orders,
/// Security, Connection). It renders a compact picker over N tabs and shows
/// the selected tab's existing child view verbatim — the polished single-
/// surface composites are later per-page packets. A deep-link `anchor`
/// selects the starting tab (e.g. `gates` → Security's Gates tab); when the
/// anchor doesn't name a tab it is passed through unchanged to the child via
/// `SettingsNavigation` (so e.g. a credential-row slug still lands inside the
/// Vault view). The leading inset matches the title bar's traffic-light
/// gutter so the picker doesn't sit under the section title.
struct BridgeMergedSection: View {
    struct Tab: Identifiable {
        let id: String
        let title: String
        /// Normalized anchor strings (lowercased, no spaces) that open this tab.
        let anchors: [String]
        let content: () -> AnyView
    }

    let anchor: String?
    let tabs: [Tab]

    @State private var selection: String

    init(anchor: String?, tabs: [Tab]) {
        self.anchor = anchor
        self.tabs = tabs
        // Resolve the starting tab from the deep-link anchor (if any).
        let initial = BridgeMergedSection.tab(for: anchor, in: tabs) ?? tabs.first?.id ?? ""
        self._selection = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(tab.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, BridgeTokens.Space.paneH)
            .padding(.top, BridgeTokens.Space.cardGap)
            .padding(.bottom, BridgeTokens.Space.cardGap)
            .accessibilityLabel("Section tabs")

            Divider().background(BridgeTokens.hairlineFaint)

            ForEach(tabs) { tab in
                if tab.id == selection {
                    tab.content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // React to a deep-link landing while the section is already on screen.
        .onChange(of: anchor) { _, newAnchor in
            if let id = BridgeMergedSection.tab(for: newAnchor, in: tabs) {
                selection = id
            }
        }
    }

    /// Resolve which tab a deep-link anchor opens. Returns nil when the anchor
    /// is nil or names something other than a tab (e.g. a credential slug),
    /// in which case the caller keeps the default/first tab and the child view
    /// still receives the raw anchor through `SettingsNavigation`.
    static func tab(for anchor: String?, in tabs: [Tab]) -> String? {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
            !raw.isEmpty else { return nil }
        for tab in tabs where tab.id == raw || tab.anchors.contains(raw) {
            return tab.id
        }
        return nil
    }
}

// MARK: - Hotkey Recorder Field (Change B + cmd-ux W2 click-to-focus)

/// A focusable field that captures the next physical key-down (with held
/// modifiers) and hands `(keyCode, Cocoa ModifierFlags)` to `onCapture`.
///
/// cmd-ux W2 — Bug-1 STRUCTURAL FIX: the field itself is now the click
/// target. `mouseDown` enters recording AND synchronously takes first
/// responder (`window?.makeFirstResponder(self)`) — so capture works
/// STANDALONE with a single click, with NO dependence on a separate
/// SwiftUI Button and NO reliance on the fragile best-effort async
/// `makeFirstResponder` that was the *only* prior focus path (the root
/// cause of "the recorder cannot capture"). `acceptsFirstResponder` is
/// true whenever the focus model says recording (click-initiated OR the
/// secondary button). The async `updateNSView` focus grab is KEPT only
/// as a redundant belt for the button path; the click path no longer
/// needs it. Escape cancels.
///
/// PURE / HEADLESS: the focus/recording transitions are the unit-tested
/// `RecorderFocusModel` (in CommandsController.swift); the chord→config
/// mapping is `HotkeyConfig.from` + `CommandsController.setHotkey`. ONLY
/// the raw `NSEvent`/`mouseDown` gesture reaching this NSView on a live
/// WindowServer is the documented operator-smoke ceiling.
///
/// `onCapture` returns whether the chord was accepted (a valid
/// modifier+key); a rejected chord (modifier-less / pure-modifier) keeps
/// the field in capture mode so the user can immediately try again.
struct HotkeyRecorderField: NSViewRepresentable {
    let currentDisplay: String
    @Binding var isRecording: Bool
    /// `(carbonVirtualKeyCode, NSEvent.ModifierFlags) -> accepted`.
    let onCapture: (UInt32, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.onCapture = { code, mods in
            let accepted = onCapture(code, mods)
            if accepted { isRecording = false }
            return accepted
        }
        v.onCancel = { isRecording = false }
        // The standalone click path: the NSView tells SwiftUI it entered
        // recording so the @Binding (and the secondary button label)
        // stay in sync — focus is already taken synchronously in
        // mouseDown, so this binding write is cosmetic, not load-bearing.
        v.onBeginRecording = { isRecording = true }
        return v
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.applyRecording(isRecording, currentDisplay: currentDisplay)
        if isRecording {
            // Redundant BELT for the secondary "Record shortcut" button
            // path (which flips the binding without a click on the
            // field). Grab focus only if we don't already hold it. The
            // click path does NOT depend on this — mouseDown already
            // made the field first responder synchronously.
            DispatchQueue.main.async {
                guard let window = nsView.window,
                      window.firstResponder !== nsView else { return }
                window.makeFirstResponder(nsView)
            }
        }
        nsView.needsDisplay = true
    }

    /// The AppKit capture surface. Owns the `RecorderFocusModel` (pure,
    /// unit-tested) for its recording/first-responder state; `mouseDown`
    /// is the standalone entry; `keyDown` forwards the raw
    /// `(keyCode, modifierFlags)` to the pure chord mapping. Holds NO
    /// mapping/validation logic itself.
    final class RecorderNSView: NSView {
        private var focus = RecorderFocusModel()
        private var display: String = ""
        /// Returns whether the chord was accepted.
        var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Bool)?
        var onCancel: (() -> Void)?
        /// Fired when a click enters recording so SwiftUI's @Binding
        /// (and the secondary button label) follow the standalone path.
        var onBeginRecording: (() -> Void)?

        /// True ⟺ the pure focus model says recording — so a click that
        /// enters recording ALSO makes the field eligible for first
        /// responder in the same run-loop turn (Bug-1 fix).
        override var acceptsFirstResponder: Bool { focus.acceptsFirstResponder }

        /// AppKit virtual keycode for Escape (kVK_Escape) — named here so
        /// this SwiftUI file needn't import Carbon for a single constant.
        private static let escapeKeyCode: UInt16 = 53

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // VoiceOver: present as a button-like control with a clear
            // label/role so assistive tech is not a regression (the old
            // bare NSView exposed nothing actionable).
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            refreshAccessibility()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

        /// Reconcile with SwiftUI's binding (the secondary button path
        /// flips `isRecording` without a click). Idempotent.
        ///
        /// W4-3.4.2 H5 fix: when the binding transitions FALSE→TRUE and
        /// this view is already in a window hierarchy, grab first
        /// responder SYNCHRONOUSLY in the same run-loop turn instead of
        /// relying on the SwiftUI-side async retry that could fire
        /// before the view lands in a window (silent no-op). For freshly
        /// mounted views — when `window` is still nil — the
        /// `didMoveToWindow` override below picks up the slack.
        func applyRecording(_ recording: Bool, currentDisplay: String) {
            let wasRecording = focus.isRecording
            focus.setRecording(recording)
            display = recording ? "Press shortcut\u{2026}" : currentDisplay
            if recording, !wasRecording, let window {
                window.makeFirstResponder(self)
            }
            refreshAccessibility()
        }

        /// W4-3.4.2 H5 fix: when the view is mounted into a window AND
        /// the focus model already says recording (the W4 conditional-
        /// render path mounts the view fresh on the operator's Record
        /// button click — `applyRecording(true, …)` ran in the same
        /// runloop turn as mount, but no `window` existed yet to grab
        /// focus on), grab first responder here. This is the reliable
        /// signal that the WindowServer is ready to route key events.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focus.isRecording, let window {
                window.makeFirstResponder(self)
            }
        }

        // MARK: Standalone click-to-record (Bug-1 structural fix)

        override func mouseDown(with event: NSEvent) {
            // Enter recording AND take first responder synchronously —
            // no async hop, no separate Button required. This is the
            // single, reliable focus path the old code lacked.
            focus.clickToRecord()
            display = "Press shortcut\u{2026}"
            window?.makeFirstResponder(self)
            onBeginRecording?()
            refreshAccessibility()
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            guard focus.isRecording else { super.keyDown(with: event); return }
            // Escape cancels capture without changing the binding.
            if event.keyCode == Self.escapeKeyCode {
                focus.escape()
                onCancel?()
                refreshAccessibility()
                needsDisplay = true
                return
            }
            let accepted = onCapture?(UInt32(event.keyCode),
                                      event.modifierFlags) ?? false
            focus.captured(accepted: accepted)
            refreshAccessibility()
            needsDisplay = true
        }

        // MARK: VoiceOver

        private func refreshAccessibility() {
            if focus.isRecording {
                setAccessibilityLabel("Recording shortcut. Press the new key combination, or press Escape to cancel.")
            } else {
                setAccessibilityLabel("Keyboard shortcut: \(display.isEmpty ? "none" : display). Click to record a new shortcut.")
            }
            setAccessibilityValue(display)
        }

        override func draw(_ dirtyRect: NSRect) {
            // Clear, visible recording state: accent treatment + an
            // accent border while capturing; a resting fill otherwise.
            let recording = focus.isRecording
            let bg = recording
                ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : NSColor.unemphasizedSelectedContentBackgroundColor
            bg.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 6, yRadius: 6)
            path.fill()
            if recording {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13,
                                         weight: recording ? .semibold : .regular),
                .foregroundColor: recording
                    ? NSColor.controlAccentColor
                    : NSColor.labelColor
            ]
            let str = NSAttributedString(string: display, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ))
        }
    }
}
