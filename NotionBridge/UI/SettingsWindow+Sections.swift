// SettingsWindow+Sections.swift — Settings Section Views
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Each section is an extension on SettingsView for clean separation.

import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

extension SettingsView {
    /// Factory Reset confirmation — skills defaults, env-based Notion token, restart guidance.
    var factoryResetConfirmationMessage: String {
        """
        This will clear: SSE port, stored credentials (Notion workspace tokens and Stripe), onboarding state, and macOS permissions for Notion Bridge.

        Skills are cleared to an empty list (add skills from Settings or via MCP when ready).

        If the app is launched with NOTION_API_TOKEN or NOTION_API_KEY in the environment, Notion may still resolve a token after reset (developer convenience). Unset those variables for a fully clean test.

        Restart the app after reset so permission and connection status stay accurate.
        """
    }

    // MARK: - Permissions

    var permissionsSection: some View {
        Form {
            Section("System permissions") {
                PermissionView(permissionManager: permissionManager)
            }

            // PKT-363 D3 + D4: Configurable sensitive paths editor
            SensitivePathsEditor()

            Section {
                // PKT-362 D3: Uses animatedRecheckAll() for per-row animated feedback
                Button(isRecheckingPermissions ? "Re-checking\u{2026}" : "Re-check All Permissions") {
                    isRecheckingPermissions = true
                    permissionActionMessage = nil
                    Task {
                        await permissionManager.animatedRecheckAll()
                        isRecheckingPermissions = false
                        permissionActionMessage = "Permission state refreshed at \(Date().formatted(date: .omitted, time: .standard))."
                    }
                }
                .disabled(isRecheckingPermissions)

                if let lastCheckedAt = permissionManager.lastCheckedAt {
                    Text("Last refreshed: \(lastCheckedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(BridgeColors.muted)
                }

                // PKT-362 D4: User-facing language, no tccutil/bundle ID references
                Button("Reset All Permissions") {
                    showTCCResetDialog = true
                }
                .foregroundStyle(BridgeColors.error)
                .confirmationDialog(
                    "Reset all permissions for NotionBridge?",
                    isPresented: $showTCCResetDialog,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task {
                            let resetResult = await resetTCCPermissions()
                            permissionActionMessage = resetResult.message
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // PKT-362 D4: Plain-language copy — no mention of tccutil,
                    // bundle IDs, or internal implementation details.
                    Text("This will reset all system permissions for NotionBridge. You\u{2019}ll need to re-grant each permission after resetting.")
                }

                if let permissionActionMessage {
                    Text(permissionActionMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Connections

    var connectionsSection: some View {
        Form {
            // 1. Server status
            Section("Server") {
                LabeledContent("Status") {
                    HStack(spacing: BridgeSpacing.xs) {
                        Circle()
                            .fill(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                            .frame(width: 8, height: 8)
                        Text(statusBar.isServerRunning ? "Running" : "Stopped")
                            .foregroundStyle(statusBar.isServerRunning ? BridgeColors.success : BridgeColors.error)
                    }
                }
                LabeledContent("Tools", value: "\(statusBar.activeToolCount) active")
                LabeledContent("Uptime", value: statusBar.uptimeString)
            }

            // 2. Integrated Tools
            Section("Integrated tools") {
                IntegratedToolsContent()
            }

            // 3. Connected Clients
            Section("Connected clients") {
                if statusBar.connectedClients.isEmpty {
                    Text("No clients connected")
                        .foregroundStyle(BridgeColors.secondary)
                } else {
                    ConnectedClientsContent(clients: statusBar.connectedClients)
                }
            }

            // 4. Remote Access
            Section("Remote access") {
                ConnectionSetupView()
            }

            // 5. App Control
            Section("App control") {
                HStack {
                    Text("Launch at login")
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Spacer()
                }
                        .onChange(of: launchAtLogin) { _, enabled in
                            guard !isApplyingLaunchAtLoginChange else { return }
                            launchAtLoginError = nil
                            let service = SMAppService.mainApp
                            do {
                                if enabled {
                                    if service.status == .enabled {
                                        return
                                    }
                                    try? service.unregister()
                                    try service.register()
                                } else {
                                    if service.status == .notRegistered {
                                        return
                                    }
                                    try service.unregister()
                                }
                            } catch {
                                let ns = error as NSError
                                NSLog(
                                    "[LaunchAtLogin] failed enabled=\(enabled) domain=\(ns.domain) code=\(ns.code) description=\(ns.localizedDescription) status=\(service.status.rawValue)"
                                )
                                let notPermitted = (ns.domain == NSPOSIXErrorDomain && ns.code == EPERM)
                                    || ns.localizedDescription.localizedCaseInsensitiveContains("operation not permitted")
                                if notPermitted {
                                    launchAtLoginError = enabled
                                        ? "Could not enable Launch at login. Operation not permitted."
                                        : "Could not disable Launch at login. Operation not permitted."
                                } else {
                                    launchAtLoginError = enabled
                                        ? "Could not enable Launch at login."
                                        : "Could not disable Launch at login."
                                }
                                isApplyingLaunchAtLoginChange = true
                                launchAtLogin.toggle()
                                isApplyingLaunchAtLoginChange = false
                            }
                        }
                HStack(spacing: 20) {
                    Button {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                    } label: {
                        Label("Check Updates", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        restartApp(reopenSettings: true)
                    } label: {
                        Label("Restart Bridge", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }

                if let err = launchAtLoginError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Allow Notion Bridge in System Settings → General → Login Items (and Login Items / Background Items if shown). Install from /Applications/Notion Bridge.app.")
                            .font(.caption2)
                            .foregroundStyle(BridgeColors.secondary)
                        Button("Open Login Items…") {
                            Self.openLoginItemsSystemSettings()
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Tools

    // PKT-366 F9: Skills manager for Skills tab

    var toolsSection: some View {
        ToolRegistryView(
            tools: statusBar.toolInfoList,
            onToggle: { _, _ in
                let disabled = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
                statusBar.activeToolCount = statusBar.toolInfoList.count - disabled.count
            },
            notificationDenied: permissionManager.notificationStatus != .granted
        )
    }

    // MARK: - Commands (cmd-ux, Change A + B)

    /// Settings → **Commands** (the single, de-duplicated tab — the old
    /// redundant "Skills" tab was removed in Change A; this IS the
    /// command manager). It stacks, top-to-bottom:
    ///
    ///   (a) the persisted master Toggle that live-registers /
    ///       unregisters the global hot-key via the AppDelegate (no
    ///       relaunch);
    ///   (b) a status row driven by the pure `CommandsSettingsStatus`
    ///       ("Active — ⌃⌥⌘C" / red "⚠ unavailable" / "Disabled"), the
    ///       glyph read LIVE from the registered combo;
    ///   (c) the in-Settings hot-key RECORDER (Change B): shows the
    ///       current combo, "Record shortcut" enters capture, the next
    ///       valid chord live-rebinds via `AppDelegate.setCommandsHotkey`,
    ///       and "Reset to default" restores `productionDefault`;
    ///   (d) the FULL existing `SkillsView` CRUD list — add / edit /
    ///       delete a command is unchanged (Commands ARE the enabled
    ///       Skills; the page body is what the palette copies).
    ///
    /// The status string mapping is the pure `CommandsSettingsStatus`
    /// and the recorded-chord mapping is the pure `HotkeyConfig.from`
    /// (both unit-tested headlessly); only the SwiftUI rendering + the
    /// raw `NSEvent` capture gesture are the operator-smoke ceiling.
    var commandsSection: some View {
        let disabledTools = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
        let current = commandsHotkeyConfig
        // cmd-ux W2: drive the status off the OBSERVED structured
        // register outcome so a TRUE ⌃⌥⌘C collision shows a specific,
        // actionable message ("⚠ ⌃⌥⌘C is in use by another app — record a
        // different shortcut") DISTINCT from a plumbing failure — fixing
        // the Bug-2 residual where any non-registered state read the
        // same generic, accusatory copy. The pure
        // `CommandsSettingsStatus` mapping stays the single source of the
        // strings; this only feeds it the live observed status.
        let status = CommandsSettingsStatus(
            enabled: commandsPaletteEnabled,
            lastRegisterStatus: commandsLastRegisterStatus,
            hotkey: current.displayString
        )
        return Form {
            Section("Commands palette") {
                Toggle("Enable Commands palette", isOn: Binding(
                    get: { commandsPaletteEnabled },
                    set: { newValue in
                        commandsPaletteEnabled = newValue
                        (NSApp.delegate as? AppDelegate)?.setCommandsPaletteEnabled(newValue)
                    }
                ))
                .help("Global hot-key command box. Type a command, press \u{23CE} to copy its body to the clipboard.")

                HStack(spacing: BridgeSpacing.xs) {
                    Image(systemName: status.isWarning
                          ? "exclamationmark.triangle.fill"
                          : (commandsPaletteEnabled ? "checkmark.circle.fill" : "minus.circle"))
                        .foregroundStyle(status.isWarning
                                         ? Color.red
                                         : (commandsPaletteEnabled ? Color.green : Color.secondary))
                    Text(status.message)
                        .font(.callout)
                        .foregroundStyle(status.isWarning ? Color.red : Color.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Commands palette status: \(status.message)")

                // (c) Change B: in-Settings hot-key recorder.
                // W4 (3.4.1): kbd-chip display when not recording; explicit
                // Retry button instead of the "toggle off/on" workaround copy.
                HStack(spacing: BridgeSpacing.sm) {
                    Text("Shortcut")
                    Spacer()
                    if isRecordingHotkey {
                        HotkeyRecorderField(
                            currentDisplay: current.displayString,
                            isRecording: $isRecordingHotkey,
                            onCapture: { keyCode, mods in
                                guard let cfg = HotkeyConfig.from(
                                    keyCode: keyCode, cocoaModifiers: mods
                                ) else { return false }
                                _ = (NSApp.delegate as? AppDelegate)?.setCommandsHotkey(cfg)
                                return true
                            }
                        )
                        .frame(width: 150)
                    } else {
                        BridgeKbdChips(displayString: current.displayString)
                    }
                    Button(isRecordingHotkey ? "Press shortcut\u{2026}" : "Record shortcut") {
                        isRecordingHotkey.toggle()
                    }
                    .disabled(!commandsPaletteEnabled)
                    Button("Reset to default") {
                        isRecordingHotkey = false
                        _ = (NSApp.delegate as? AppDelegate)?
                            .setCommandsHotkey(.productionDefault)
                    }
                    .disabled(!commandsPaletteEnabled)
                    if status.isWarning {
                        Button {
                            (NSApp.delegate as? AppDelegate)?.retryHotkeyRegistration()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Retry registering this shortcut now.")
                        .accessibilityLabel("Retry shortcut registration")
                    }
                }
                .help("Click \u{201C}Record shortcut\u{201D}, then press the new combo. A modifier (\u{2318}/\u{2325}/\u{2303}/\u{21E7}) is required.")
            }

            Section {
                SkillsView(
                    skillsManager: skillsManager,
                    fetchSkillDisabled: disabledTools.contains("fetch_skill")
                )
            } header: {
                Text("Skills here can be flipped into routing discovery, the Commands palette, or both. Routing surfaces a skill in the discovery list so agents can find it by name. Palette surfaces it under the global hot-key — pressing the shortcut and selecting a command copies that skill's page body to your clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials (PKT-372)

    var credentialsSection: some View {
        CredentialsView()
    }

    // MARK: - Advanced

    var advancedSection: some View {
        Form {
            Section("Version") {
                LabeledContent("App Version", value: "v\(appVersion)")
                LabeledContent("MCP protocol", value: BridgeConstants.mcpProtocolVersion)
                LabeledContent("Notion API", value: BridgeConstants.notionAPIVersion)
                LabeledContent("macOS", value: BridgeConstants.minimumMacOSMarketing)
            }

            Section("Network") {
                HStack(spacing: BridgeSpacing.xs) {
                    Text("Local MCP port")
                    Spacer()
                    TextField(String(BridgeConstants.defaultSSEPort), text: $ssePortInput)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .onChange(of: ssePortInput) { _, _ in
                            ssePortSaveSuccess = false
                        }
                        .accessibilityLabel("Local MCP server port")
                    Button("Default") {
                        ssePortInput = String(BridgeConstants.defaultSSEPort)
                        ssePortError = nil
                        ssePortSaveSuccess = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Set the field to \(BridgeConstants.defaultSSEPort) (does not save)")
                    Button("Save") {
                        saveSSEPort()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let ssePortError {
                    Text(ssePortError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }


            Section("Local server") {
                LabeledContent("Streamable HTTP") {
                    Text(verbatim: "http://localhost:\(ssePort)/mcp")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                LabeledContent("Legacy SSE") {
                    Text(verbatim: "http://localhost:\(ssePort)/sse")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                LabeledContent("Health Check") {
                    Text(verbatim: "http://localhost:\(ssePort)/health")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
            Section("Paths") {
                LabeledContent("Config File") {
                    Text(ConfigManager.shared.configFileURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                LabeledContent("Log Directory") {
                    Button {
                        // PKT-1 v3.5: BridgePaths.logs is the canonical home.
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: BridgePaths.logs.path)
                    } label: {
                        Text("~/Library/Logs/The Bridge/")
                            .font(.system(.caption, design: .monospaced))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                LabeledContent("Screen Output") {
                    Text(screenOutputDir)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }

            Section("Maintenance") {
                Button("Reset Onboarding") {
                    showResetConfirmation = true
                }
                .font(.caption)
                .confirmationDialog(
                    "Reset Onboarding?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: OnboardingResumeKey.stepRaw)
                        UserDefaults.standard.set(false, forKey: BridgeDefaults.hasCompletedOnboarding)
                        NotificationCenter.default.post(name: .resetOnboarding, object: nil)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will restart the setup wizard. Your settings and data will not be affected.")
                }

                Button("Reset Background Items") {
                    showResetBackgroundItemsConfirmation = true
                }
                .font(.caption)
                .confirmationDialog(
                    "Reset Background Items?",
                    isPresented: $showResetBackgroundItemsConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task {
                            let result = await JobsManager.shared.resetBackgroundItems()
                            await MainActor.run { resetBackgroundItemsMessage = result.message }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will re-register all scheduled background jobs with launchd, resetting BTM attribution to Notion Bridge.")
                }

                if let resetBackgroundItemsMessage {
                    Text(resetBackgroundItemsMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                }

                Button("Factory Reset", role: .destructive) {
                    showFactoryResetConfirmation = true
                }
                .confirmationDialog(
                    "Factory Reset Notion Bridge?",
                    isPresented: $showFactoryResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Factory Reset", role: .destructive) {
                        Task {
                            let result = await performFactoryReset()
                            factoryResetMessage = result.message
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(factoryResetConfirmationMessage)
                }

                if let factoryResetMessage {
                    Text(factoryResetMessage)
                        .font(.caption)
                        .foregroundStyle(BridgeColors.secondary)
                }
            }

            Section("Support") {
                Button("Export Diagnostics to Clipboard") {
                    exportDiagnostics()
                }
                .font(.caption)
                Text("Copies system info, tool list, and permission status for bug reports.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }

            Section("About") {
                HStack(spacing: BridgeSpacing.xs) {
                    Image(systemName: "bridge.fill")
                        .foregroundStyle(.purple)
                    Text("Notion Bridge")
                        .fontWeight(.medium)
                    Text("\u{2014} Local MCP server connecting AI assistants to your Mac.")
                        .foregroundStyle(BridgeColors.secondary)
                }
                .font(.callout)

                Link(destination: URL(string: "https://kup.solutions")!) {
                    HStack(spacing: BridgeSpacing.xxs) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text("kup.solutions")
                            .font(.caption)
                    }
                }

                Text("\u{00A9} 2026 KUP Solutions. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(BridgeColors.muted)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ssePortInput = String(ssePort)
            ssePortError = nil
        }
        .confirmationDialog(
            "Port saved",
            isPresented: $showSSEPortRestartPrompt,
            titleVisibility: .visible
        ) {
            Button("Restart Notion Bridge") {
                ssePortRevertOnCancel = nil
                restartApp(reopenSettings: true)
            }
            Button("Cancel", role: .cancel) {
                if let revert = ssePortRevertOnCancel {
                    ConfigManager.shared.ssePort = revert
                    ssePortInput = String(revert)
                }
                ssePortRevertOnCancel = nil
            }
        } message: {
            Text("Restart to listen on the new port. Cancel restores the previous port in config.")
        }
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
        case .warning: return .orange
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


// MARK: - Jobs Section (Jobs Surface v1.10.0)

extension SettingsView {
    @ViewBuilder
    var jobsSection: some View {
        JobsView()
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
