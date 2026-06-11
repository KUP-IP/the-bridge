// AdvancedSection.swift — Settings → Advanced pane.
// Settings Redesign Wave 2 (PKT-advanced). The titlebar now carries the
// section name, so the bespoke 50×50 glass hero is gone — a single subtitle
// intro line opens the page. The seven stacked cards collapse to two:
//
//   • System  — Startup & Updates (Launch-at-login + Check-for-Updates) /
//                About / Network / Local endpoints / System paths as labeled
//                sub-groups; the metadata sub-groups all build from ONE
//                `metaRow` primitive (read-only value · copyable mono chip ·
//                path-with-reveal). Version is single-sourced here (the About
//                "App version" row) — the old gold hero versionTile and its
//                duplicate export icon are gone.
//   • Maintenance — Export pulled OUT of the destructive grid into its own
//                diagnostic row; the three reset/wipe actions stay grouped as
//                a Danger zone (role:.destructive + confirmation dialogs).
//
// License has been relocated to the Security page (PKT-W3-license) — it is an
// account/entitlement posture concern, not a system internal.
//
// Startup & Updates relocated FROM the Connection page (PKT-W3-lifecycle): the
// Launch-at-login toggle (SMAppService registration) and the Check-for-Updates
// button are app-lifecycle concerns, not connectivity. The SMAppService wiring
// (`applyLaunchAtLoginChange`) and the `checkForUpdates()` call are preserved
// verbatim — `launchAtLogin` remains the same @AppStorage key the AppDelegate
// reads at startup, so this stays the single source of truth.
//
// VIEW LAYER ONLY — every binding is preserved verbatim: launch-at-login
// registration, version/about strings, SSE port edit + validation, copy
// endpoint rows, reveal-in-Finder path rows, and the maintenance/danger tiles
// (export, reset onboarding, reset background items, factory reset).

import SwiftUI
import ServiceManagement
import AppKit

public struct AdvancedSection: View {
    let statusBar: StatusBarController
    let permissionManager: PermissionManager
    let appVersion: String
    let ssePort: Int
    @Binding var ssePortInput: String
    @Binding var ssePortError: String?
    @Binding var ssePortSaveSuccess: Bool
    @Binding var showSSEPortRestartPrompt: Bool
    @Binding var ssePortRevertOnCancel: Int?
    @Binding var showResetConfirmation: Bool
    @Binding var showResetBackgroundItemsConfirmation: Bool
    @Binding var resetBackgroundItemsMessage: String?
    @Binding var showFactoryResetConfirmation: Bool
    @Binding var factoryResetMessage: String?
    let onSaveSSEPort: () -> Void
    let onPerformFactoryReset: () async -> (message: String, didFail: Bool)
    let onExportDiagnostics: () -> Void
    let factoryResetConfirmationMessage: String
    let screenOutputDir: String

    public init(
        statusBar: StatusBarController,
        permissionManager: PermissionManager,
        appVersion: String,
        ssePort: Int,
        ssePortInput: Binding<String>,
        ssePortError: Binding<String?>,
        ssePortSaveSuccess: Binding<Bool>,
        showSSEPortRestartPrompt: Binding<Bool>,
        ssePortRevertOnCancel: Binding<Int?>,
        showResetConfirmation: Binding<Bool>,
        showResetBackgroundItemsConfirmation: Binding<Bool>,
        resetBackgroundItemsMessage: Binding<String?>,
        showFactoryResetConfirmation: Binding<Bool>,
        factoryResetMessage: Binding<String?>,
        onSaveSSEPort: @escaping () -> Void,
        onPerformFactoryReset: @escaping () async -> (message: String, didFail: Bool),
        onExportDiagnostics: @escaping () -> Void,
        factoryResetConfirmationMessage: String,
        screenOutputDir: String
    ) {
        self.statusBar = statusBar
        self.permissionManager = permissionManager
        self.appVersion = appVersion
        self.ssePort = ssePort
        self._ssePortInput = ssePortInput
        self._ssePortError = ssePortError
        self._ssePortSaveSuccess = ssePortSaveSuccess
        self._showSSEPortRestartPrompt = showSSEPortRestartPrompt
        self._ssePortRevertOnCancel = ssePortRevertOnCancel
        self._showResetConfirmation = showResetConfirmation
        self._showResetBackgroundItemsConfirmation = showResetBackgroundItemsConfirmation
        self._resetBackgroundItemsMessage = resetBackgroundItemsMessage
        self._showFactoryResetConfirmation = showFactoryResetConfirmation
        self._factoryResetMessage = factoryResetMessage
        self.onSaveSSEPort = onSaveSSEPort
        self.onPerformFactoryReset = onPerformFactoryReset
        self.onExportDiagnostics = onExportDiagnostics
        self.factoryResetConfirmationMessage = factoryResetConfirmationMessage
        self.screenOutputDir = screenOutputDir
    }

    /// Transient "copied" flash, keyed by the copied row's value so the
    /// check-mark lands on the row the user actually clicked.
    @State private var copiedKey: String? = nil

    // Bridge lifecycle (relocated from Connection, PKT-W3-lifecycle).
    // `launchAtLogin` is the same @AppStorage key the AppDelegate reads at
    // startup, so this stays the single source of truth for the login item.
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var isApplyingLaunchAtLoginChange = false

    // Advanced density targets (spec: pad 20→16, inter-card gap 14→10). Kept
    // local so they don't perturb the shared BridgeTokens.Space scale other
    // pages share.
    private let paneInset: CGFloat = 16
    private let cardGap: CGFloat = 10

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: cardGap) {
                intro
                systemCard
                maintenanceCard
            }
            .padding(paneInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .confirmationDialog(
            "Port saved",
            isPresented: $showSSEPortRestartPrompt,
            titleVisibility: .visible
        ) {
            Button("Restart Notion Bridge") {
                ssePortRevertOnCancel = nil
                NSApp.restartBridge()
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
            Text("Re-register scheduled background jobs with launchd.")
        }
        .confirmationDialog(
            "Factory Reset Notion Bridge?",
            isPresented: $showFactoryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Factory Reset", role: .destructive) {
                Task {
                    let result = await onPerformFactoryReset()
                    factoryResetMessage = result.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(factoryResetConfirmationMessage)
        }
    }

    // MARK: - Intro (titlebar carries the section name; this is the one-line lede)

    private var intro: some View {
        Text("Build info, network ports, local endpoints, on-disk paths, and maintenance. For power users.")
            .font(.system(size: 12.5))
            .foregroundStyle(BridgeTokens.fg3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - System (About + Network + Local endpoints + System paths)
    //
    // One card, four labeled sub-groups. About owns the canonical version
    // readout; the metadata sub-groups (About, Endpoints, Paths) all flow
    // through the single `metaRow` primitive so columns align everywhere.

    private var systemCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 18) {
                subGroup("Startup & Updates") {
                    startupAndUpdates
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                subGroup("About") {
                    metaGrid {
                        metaRow("App version", value: .text(appVersion))
                        metaRow("MCP protocol", value: .text(BridgeConstants.mcpProtocolVersion))
                        metaRow("Notion API", value: .text(BridgeConstants.notionAPIVersion))
                        metaRow("macOS", value: .text("macOS \(BridgeConstants.minimumMacOSMarketing)"))
                        metaRow("Bundle", value: .copyable(Bundle.main.bundleIdentifier ?? "—"))
                    }
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                subGroup("Network") {
                    networkControls
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                subGroup("Local endpoints") {
                    metaGrid {
                        metaRow("Streamable HTTP", value: .copyable("http://localhost:\(ssePort)/mcp"))
                        metaRow("Legacy SSE", value: .copyable("http://localhost:\(ssePort)/sse"))
                        metaRow("Health check", value: .copyable("http://localhost:\(ssePort)/health"))
                    }
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                subGroup("System paths") {
                    metaGrid {
                        metaRow("Config", value: .path(ConfigManager.shared.configFileURL.path))
                        metaRow("Logs", value: .path(BridgePaths.logs.path))
                        metaRow("Screen output", value: .path(screenOutputDir))
                    }
                }
            }
        }
    }

    // MARK: - Startup & Updates (relocated from Connection, PKT-W3-lifecycle)
    //
    // App-lifecycle controls — Launch-at-login (SMAppService registration) and a
    // manual Check-for-Updates trigger. NOT connectivity, so they live with the
    // system internals rather than the loopback endpoint surface. The SMAppService
    // wiring (`applyLaunchAtLoginChange`) and the `checkForUpdates()` call are
    // preserved exactly as they ran on Connection.

    private var startupAndUpdates: some View {
        VStack(alignment: .leading, spacing: 12) {
            launchToggleRow(
                title: "Launch at login",
                subtitle: "Registers Bridge with macOS via SMAppService. Approve in System Settings → Login Items if blocked.",
                isOn: $launchAtLogin
            )
            .onChange(of: launchAtLogin) { _, enabled in
                applyLaunchAtLoginChange(enabled: enabled)
            }
            if let err = launchAtLoginError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.warnText)
            }
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
            Button {
                (NSApp.delegate as? AppDelegate)?.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(BridgeTokens.accent)
        }
    }

    private func launchToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(BridgeTokens.accent)
        }
    }

    private func applyLaunchAtLoginChange(enabled: Bool) {
        guard !isApplyingLaunchAtLoginChange else { return }
        launchAtLoginError = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { return }
                try? service.unregister()
                try service.register()
            } else {
                if service.status == .notRegistered { return }
                try service.unregister()
            }
        } catch {
            let ns = error as NSError
            let notPermitted = (ns.domain == NSPOSIXErrorDomain && ns.code == EPERM)
                || ns.localizedDescription.localizedCaseInsensitiveContains("operation not permitted")
            launchAtLoginError = notPermitted
                ? (enabled ? "Could not enable Launch at login. Operation not permitted."
                           : "Could not disable Launch at login. Operation not permitted.")
                : (enabled ? "Could not enable Launch at login."
                           : "Could not disable Launch at login.")
            isApplyingLaunchAtLoginChange = true
            launchAtLogin.toggle()
            isApplyingLaunchAtLoginChange = false
        }
    }

    /// A labeled sub-group: small-caps label + its content, used inside the
    /// single System card to keep four concerns in one card boundary.
    @ViewBuilder
    private func subGroup<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BridgeCardLabel(label)
            content()
        }
    }

    private func metaGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
            content()
        }
    }

    // MARK: - Network controls (port input)

    private var networkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Local MCP port")
                    .font(.system(size: 13))
                    .foregroundStyle(BridgeTokens.fg2)
                    .frame(width: 130, alignment: .leading)
                TextField(String(BridgeConstants.defaultSSEPort), text: $ssePortInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: ssePortInput) { _, _ in ssePortSaveSuccess = false }
                    .accessibilityLabel("Local MCP port")
                Button("Save", action: onSaveSSEPort)
                    .buttonStyle(.borderedProminent)
                    .tint(BridgeTokens.accent)
                    .controlSize(.small)
                Button("Restore default") {
                    ssePortInput = String(BridgeConstants.defaultSSEPort)
                    ssePortError = nil
                    ssePortSaveSuccess = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if ssePortSaveSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.okText)
                        .transition(.opacity)
                        .accessibilityLabel("Port saved")
                }
                Spacer(minLength: 0)
            }
            if let ssePortError {
                Text(ssePortError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.warnText)
            }
            Text("Changes apply after Restart Bridge.")
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg3)
        }
    }

    // MARK: - Unified meta row (read-only · copyable mono chip · path+reveal)

    /// The single value treatment a `metaRow` can render.
    private enum MetaValue {
        /// Plain read-only fact (e.g. the canonical App version).
        case text(String)
        /// Monospaced, copyable value (bundle id, endpoint URL).
        case copyable(String)
        /// On-disk path: middle-truncated mono chip + reveal-in-Finder + copy.
        case path(String)
    }

    @ViewBuilder
    private func metaRow(_ label: String, value: MetaValue) -> some View {
        switch value {
        case .text(let v):
            GridRow {
                rowLabel(label)
                Text(v)
                    .font(.system(size: 13))
                    .foregroundStyle(BridgeTokens.fg1)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(label): \(v)")
            }
        case .copyable(let v):
            GridRow(alignment: .center) {
                rowLabel(label)
                HStack(spacing: 8) {
                    monoChip(v)
                    copyButton(v, label: label)
                }
            }
        case .path(let v):
            GridRow(alignment: .center) {
                rowLabel(label)
                pathValue(label: label, path: v)
            }
        }
    }

    private func rowLabel(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12.5))
            .foregroundStyle(BridgeTokens.fg3)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func pathValue(label: String, path: String) -> some View {
        if path.isEmpty {
            // Empty/error state: no path resolved → muted "Not set", no
            // reveal/copy affordances pointing at nothing.
            Text("Not set")
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(label): not set")
        } else {
            HStack(spacing: 8) {
                monoChip(path, truncateMiddle: true)
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                        .frame(width: 27, height: 27)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(label) in Finder")
                copyButton(path, label: label)
            }
        }
    }

    // MARK: - Shared mono chip + copy button

    private func monoChip(_ value: String, truncateMiddle: Bool = false) -> some View {
        Text(value)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(BridgeTokens.fg2)
            .lineLimit(1)
            .truncationMode(truncateMiddle ? .middle : .tail)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private func copyButton(_ value: String, label: String) -> some View {
        let copied = copiedKey == value
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copiedKey = value }
            // VoiceOver announce on copy (the checkmark is otherwise visual-only).
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: "\(label) copied", .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if copiedKey == value { withAnimation { copiedKey = nil } }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copied ? BridgeTokens.okText : BridgeTokens.fg3)
                .frame(width: 27, height: 27)
                .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel("Copy \(label)")
        .accessibilityValue(copied ? "Copied" : "")
    }

    // MARK: - Maintenance (Export diagnostic row + Danger zone)

    private var maintenanceCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Export is a benign diagnostic — pulled out of the destructive
                // grid into its own row above the danger zone.
                subGroup("Maintenance") {
                    exportRow
                }

                Divider().overlay(BridgeTokens.hairlineFaint)

                // Danger zone: the three reset/wipe actions, each gated by a
                // confirmation dialog (role:.destructive preserved on confirm).
                VStack(alignment: .leading, spacing: 10) {
                    BridgeCardLabel("Danger zone")
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        dangerTile(
                            title: "Reset onboarding",
                            subtitle: "Re-run the first-launch wizard on next start. Workspace credentials preserved.",
                            actionLabel: "Reset",
                            destructive: false,
                            action: { showResetConfirmation = true }
                        )
                        dangerTile(
                            title: "Reset background items",
                            subtitle: "Re-register scheduled jobs with launchd.",
                            actionLabel: "Reset",
                            destructive: false,
                            action: { showResetBackgroundItemsConfirmation = true }
                        )
                        dangerTile(
                            title: "Factory reset",
                            subtitle: "Wipe all local Bridge state — commands, snippets, jobs, paths, credentials. Cannot be undone.",
                            actionLabel: "Factory reset\u{2026}",
                            destructive: true,
                            action: { showFactoryResetConfirmation = true }
                        )
                    }
                    if let factoryResetMessage {
                        Text(factoryResetMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    if let resetBackgroundItemsMessage {
                        Text(resetBackgroundItemsMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                }
            }
        }
    }

    /// Export diagnostics — a labeled row, not a danger tile. Single trigger
    /// (the hero icon button that duplicated it is gone).
    private var exportRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export diagnostics")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                Text("A redacted bundle with logs, settings (no secrets), and recent tool calls — useful for bug reports.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg3)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Export\u{2026}", action: onExportDiagnostics)
                .buttonStyle(.borderedProminent)
                .tint(BridgeTokens.accent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private func dangerTile(
        title: String,
        subtitle: String,
        actionLabel: String,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Neutral resets use the adaptive chip fill (no raw Color.white — that
        // breaks on titanium); the irreversible factory reset reads red via the
        // signal token + role:.destructive, so it is never color-alone.
        let titleColor: Color = destructive ? BridgeTokens.badText : BridgeTokens.fg1
        let fill: Color = destructive ? BridgeTokens.bad.opacity(0.07) : BridgeTokens.chipFill
        let stroke: Color = destructive ? BridgeTokens.bad.opacity(0.22) : BridgeTokens.hairline

        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(titleColor)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(BridgeTokens.fg3)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Group {
                if destructive {
                    Button(actionLabel, role: .destructive, action: action)
                        .buttonStyle(.bordered)
                        .tint(BridgeTokens.bad)
                } else {
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control).strokeBorder(stroke, lineWidth: 0.5))
    }
}
