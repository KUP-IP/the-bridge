// AdvancedSection.swift — Settings → Advanced pane.
//
// The Bridge v4 redesign (PKT-advanced). Faithful recreation of
// design/the-bridge-design-system/project/pages/page-advanced.jsx in the
// "Liquid Glass, evolved" language — built entirely from W1 BridgeTokens +
// W2 components (BridgeGlassCard · BridgeCardLabel · BridgeBadge · BridgeInput ·
// BridgeButton · BridgeBadge · BridgeListIconTile). Both themes (carbon /
// titanium) come free from the adaptive tokens.
//
// LAYOUT (matches the JSX top-to-bottom):
//   • meta strip — the SINGLE home for app identity (version · build · MCP ·
//                  macOS) + an "Up to date" signal badge, with Check-for-updates
//                  and Export-diagnostics living here (the JSX audit pulls Export
//                  out of the danger grid and kills the version triplication).
//   • System card — Startup & updates (Launch-at-login) / About / Network
//                  (SSE port via BridgeInput + endpoint) / Paths, as labeled
//                  sub-groups sharing ONE `metaRow` primitive so columns align.
//   • Maintenance card — the one loud card: a benign Routine sub-group, then a
//                  red-edged Danger zone (reset onboarding · reset background
//                  items · factory reset) with an inline factory-reset confirm.
//
// VIEW LAYER ONLY — every binding / action is preserved verbatim:
//   launch-at-login registration (SMAppService `applyLaunchAtLoginChange`),
//   `checkForUpdates()`, the SSE port edit + validation + save (`onSaveSSEPort`)
//   + restore-default, copy-endpoint rows, reveal-in-Finder path rows, the four
//   confirmationDialogs (port restart · reset onboarding · reset background
//   items · factory reset → `onPerformFactoryReset`), and `onExportDiagnostics`.
// `launchAtLogin` is the same @AppStorage key the AppDelegate reads at startup,
// so it stays the single source of truth for the login item.

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

    // Endpoint column key width — the JSX `.k { width: 118px }`, widened a touch
    // so the longest labels ("Streamable HTTP", "Reset background items") clear.
    private let keyColumnWidth: CGFloat = 130

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: cardGap) {
                metaStrip
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

    // MARK: - Meta strip (single home for app identity + global actions)
    //
    // Mirrors the JSX `.avp-meta`: a glyph + "System" + an "Up to date" badge,
    // then a mono identity line (version · build · MCP · macOS), then the two
    // global actions — Check for updates and Export diagnostics. Version is
    // single-sourced HERE (the JSX audit "kill triplication").

    private var metaStrip: some View {
        HStack(spacing: 12) {
            // Identity label + signal badge.
            HStack(spacing: 9) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(BridgeTokens.fg2)
                Text("System")
                    .font(BridgeTokens.Typeface.body)
                    .foregroundStyle(BridgeTokens.fg1)
                BridgeBadge("Up to date", tone: .ok, showsDot: true)
            }
            .fixedSize()

            // Mono identity readout (version · build · MCP · macOS).
            Text(identityLine)
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg4)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel("The Bridge \(appVersion), build \(AppVersion.build), MCP \(BridgeConstants.mcpProtocolVersion), macOS \(BridgeConstants.minimumMacOSMarketing)")

            Spacer(minLength: 8)

            BridgeButton("Check for updates", systemImage: "arrow.down.circle") {
                (NSApp.delegate as? AppDelegate)?.checkForUpdates()
            }
            BridgeButton("Export diagnostics", systemImage: "square.and.arrow.up", action: onExportDiagnostics)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    /// The mono identity string: `The Bridge 3.7.11 (57) · MCP 1.0 · macOS 15.5`.
    private var identityLine: String {
        "The Bridge \(appVersion) (\(AppVersion.build))  ·  MCP \(BridgeConstants.mcpProtocolVersion)  ·  macOS \(BridgeConstants.minimumMacOSMarketing)"
    }

    // MARK: - System (Startup & Updates + About + Network + Paths)
    //
    // One card, labeled sub-groups. The metadata sub-groups (About, Endpoints,
    // Paths) all flow through the single `metaRow` primitive so columns align.

    private var systemCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 18) {
                subGroup("Startup & updates") {
                    startupAndUpdates
                }

                groupDivider()

                subGroup("About") {
                    metaGrid {
                        metaRow("App version", value: .text("\(appVersion) (\(AppVersion.build))"))
                        metaRow("MCP protocol", value: .text(BridgeConstants.mcpProtocolVersion))
                        metaRow("Notion API", value: .text(BridgeConstants.notionAPIVersion))
                        metaRow("macOS", value: .text("macOS \(BridgeConstants.minimumMacOSMarketing)"))
                        metaRow("Bundle", value: .copyable(Bundle.main.bundleIdentifier ?? "—"))
                    }
                }

                groupDivider()

                subGroup("Network") {
                    networkControls
                }

                groupDivider()

                subGroup("Local endpoints") {
                    metaGrid {
                        metaRow("Streamable HTTP", value: .copyable("http://localhost:\(ssePort)/mcp"))
                        metaRow("Legacy SSE", value: .copyable("http://localhost:\(ssePort)/sse"))
                        metaRow("Health check", value: .copyable("http://localhost:\(ssePort)/health"))
                    }
                }

                groupDivider()

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

    /// A faint .5px in-card divider (the JSX `.avp-group .line` weave).
    private func groupDivider() -> some View {
        Rectangle()
            .fill(BridgeTokens.hairlineFaint)
            .frame(height: 0.5)
    }

    // MARK: - Startup & Updates (Launch-at-login)
    //
    // App-lifecycle control — Launch-at-login (SMAppService registration). The
    // SMAppService wiring (`applyLaunchAtLoginChange`) is preserved verbatim; the
    // manual Check-for-Updates trigger now lives in the meta strip (the JSX puts
    // both global actions up top), so the same `checkForUpdates()` action fires
    // from a single home.

    private var startupAndUpdates: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.warnText)
            }
        }
    }

    private func launchToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(subtitle)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            BridgeToggle(isOn: isOn)
                .accessibilityLabel(title)
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
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            content()
        }
    }

    /// A card-label rendered in a non-default ink. `BridgeCardLabel` bakes its
    /// own `fg3` foreground onto a `Text`, which an outer `.foregroundStyle`
    /// can't override — so the red Maintenance / Danger-zone labels are rendered
    /// inline with the same caps treatment (`Text.bridgeCap()`).
    private func coloredCardLabel(_ label: String, color: Color) -> some View {
        Text(label)
            .bridgeCap()
            .foregroundStyle(color)
    }

    // MARK: - Network controls (SSE port input via BridgeInput)
    //
    // The JSX `.avp-row` for the port: a mono input, a primary Save (gated on a
    // dirty + valid port), Restore-default link, and an apply-note. The save +
    // validation wiring is preserved verbatim — `onSaveSSEPort` and the
    // `ssePort*` bindings are untouched; only the controls are reskinned to
    // BridgeInput + BridgeButton.

    private var networkControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("Local MCP port")
                    .font(BridgeTokens.Typeface.base)
                    .foregroundStyle(BridgeTokens.fg3)
                    .frame(width: keyColumnWidth, alignment: .leading)

                BridgeInput(String(BridgeConstants.defaultSSEPort), text: $ssePortInput, mono: true)
                    .frame(width: 96)
                    .onChange(of: ssePortInput) { _, _ in ssePortSaveSuccess = false }
                    .accessibilityLabel("Local MCP port")

                BridgeButton("Save", variant: .primary, isEnabled: portSaveEnabled, action: onSaveSSEPort)

                BridgeButton("Restore default", variant: .link) {
                    ssePortInput = String(BridgeConstants.defaultSSEPort)
                    ssePortError = nil
                    ssePortSaveSuccess = false
                }

                if ssePortSaveSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(BridgeTokens.okText)
                        .transition(.opacity)
                        .accessibilityLabel("Port saved")
                }
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.15), value: ssePortSaveSuccess)

            if let ssePortError {
                Text(ssePortError)
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.warnText)
                    .padding(.leading, keyColumnWidth + 10)
            } else {
                Text("Applies after Restart Bridge — clients reconnect.")
                    .font(BridgeTokens.Typeface.sub)
                    .foregroundStyle(BridgeTokens.fg4)
                    .padding(.leading, keyColumnWidth + 10)
            }
        }
    }

    /// Save is enabled only when the field differs from the live port and parses
    /// to a valid registered/dynamic port (1024–65535) — mirrors the JSX
    /// `portDirty && portValid` gate. Validation of the *committed* value still
    /// flows through `onSaveSSEPort` (which owns `ssePortError`); this is just the
    /// inline affordance gate.
    private var portSaveEnabled: Bool {
        let trimmed = ssePortInput.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else { return false }
        let dirty = value != ssePort
        let valid = (1024...65535).contains(value)
        return dirty && valid
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
                    .font(BridgeTokens.Typeface.base)
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
            .font(BridgeTokens.Typeface.meta)
            .foregroundStyle(BridgeTokens.fg3)
            .frame(width: keyColumnWidth, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private func pathValue(label: String, path: String) -> some View {
        if path.isEmpty {
            // Empty/error state: no path resolved → muted italic "Not set", no
            // reveal/copy affordances pointing at nothing (JSX `.unset`).
            Text("Not set")
                .font(BridgeTokens.Typeface.meta.italic())
                .foregroundStyle(BridgeTokens.fg5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(label): not set")
        } else {
            HStack(spacing: 8) {
                monoChip(path, truncateMiddle: true)
                iconButton(systemImage: "folder", help: "Reveal in Finder",
                           accessibility: "Reveal \(label) in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
                copyButton(path, label: label)
            }
        }
    }

    // MARK: - Shared mono chip + copy / icon buttons (JSX `.avp-chip` / `.avp-ibtn`)

    /// The recessed well chip that holds a mono value (`.avp-chip` — wellFill +
    /// inset bevel + faint hairline).
    private func monoChip(_ value: String, truncateMiddle: Bool = false) -> some View {
        Text(value)
            .font(BridgeTokens.Typeface.mono)
            .foregroundStyle(BridgeTokens.fg2)
            .lineLimit(1)
            .truncationMode(truncateMiddle ? .middle : .tail)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
            .bridgeBevel(BridgeTokens.bevelInset, radius: BridgeTokens.Radius.control)
            .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    /// The 27×27 ghost icon button (`.avp-ibtn`): borderless, hover-fills, with a
    /// transient "copied" check.
    private func copyButton(_ value: String, label: String) -> some View {
        let copied = copiedKey == value
        return iconButton(
            systemImage: copied ? "checkmark" : "doc.on.doc",
            help: "Copy",
            accessibility: "Copy \(label)",
            tint: copied ? BridgeTokens.okText : BridgeTokens.fg4,
            accessibilityValue: copied ? "Copied" : ""
        ) {
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
        }
    }

    /// Shared ghost icon button matching the JSX `.avp-ibtn` (27×27, no border,
    /// hover fill via the hoverFill token).
    private func iconButton(
        systemImage: String,
        help: String,
        accessibility: String,
        tint: Color = BridgeTokens.fg4,
        accessibilityValue: String = "",
        action: @escaping () -> Void
    ) -> some View {
        IconGhostButton(
            systemImage: systemImage,
            help: help,
            accessibility: accessibility,
            tint: tint,
            accessibilityValue: accessibilityValue,
            action: action
        )
    }

    // MARK: - Maintenance (Routine actions + Danger zone with inline confirm)
    //
    // The one loud card. Benign "Routine" actions sit above the red-edged Danger
    // zone. The three reset/wipe actions each fire the SAME confirmation-dialog
    // bindings as before; the factory reset uses BridgeButton(.danger) and an
    // inline confirm note, matching the JSX `.avp-confirm`.

    private var maintenanceCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Header: a red-toned label + a quiet note ("resets confirm…").
                HStack(spacing: 8) {
                    coloredCardLabel("Maintenance", color: BridgeTokens.badText)
                    Text("resets confirm before running")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                    Spacer(minLength: 0)
                }

                groupDivider()

                // Danger zone: the three reset/wipe actions, each gated by a
                // confirmation dialog (role:.destructive preserved on confirm).
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BridgeTokens.badText)
                        coloredCardLabel("Danger zone", color: BridgeTokens.badText)
                        Spacer(minLength: 0)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        dangerTile(
                            systemImage: "arrow.counterclockwise",
                            title: "Reset onboarding",
                            subtitle: "Re-run the first-launch wizard on next start. Workspace credentials preserved.",
                            actionLabel: "Reset",
                            destructive: false,
                            action: { showResetConfirmation = true }
                        )
                        dangerTile(
                            systemImage: "clock.arrow.circlepath",
                            title: "Reset background items",
                            subtitle: "Re-register scheduled jobs with launchd.",
                            actionLabel: "Reset",
                            destructive: false,
                            action: { showResetBackgroundItemsConfirmation = true }
                        )
                        dangerTile(
                            systemImage: "trash",
                            title: "Factory reset",
                            subtitle: "Wipe all local Bridge state — commands, snippets, jobs, paths, credentials. Cannot be undone.",
                            actionLabel: "Factory reset\u{2026}",
                            destructive: true,
                            action: { showFactoryResetConfirmation = true }
                        )
                    }

                    if let factoryResetMessage {
                        Text(factoryResetMessage)
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                    if let resetBackgroundItemsMessage {
                        Text(resetBackgroundItemsMessage)
                            .font(BridgeTokens.Typeface.sub)
                            .foregroundStyle(BridgeTokens.fg3)
                    }
                }
            }
        }
        // Red-edged card per JSX `.avp-danger` — a faint bad-tinted border over
        // the standard glass card, so Maintenance reads as the loud one.
        .overlay(
            RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
                .strokeBorder(BridgeTokens.bad.opacity(0.24), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func dangerTile(
        systemImage: String,
        title: String,
        subtitle: String,
        actionLabel: String,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Neutral resets use the adaptive chip fill (no raw Color.white — that
        // breaks on titanium); the irreversible factory reset reads red via the
        // signal token + BridgeButton(.danger), so it is never color-alone.
        let titleColor: Color = destructive ? BridgeTokens.badText : BridgeTokens.fg1
        let fill: Color = destructive ? BridgeTokens.bad.opacity(0.07) : BridgeTokens.chipFill
        let stroke: Color = destructive ? BridgeTokens.bad.opacity(0.22) : BridgeTokens.hairline

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                BridgeListIconTile(systemImage: systemImage)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(titleColor)
            }
            Text(subtitle)
                .font(BridgeTokens.Typeface.sub)
                .foregroundStyle(BridgeTokens.fg3)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
            BridgeButton(actionLabel, variant: destructive ? .danger : .default, action: action)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BridgeTokens.Radius.control, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
    }
}

// MARK: - Ghost icon button (JSX `.avp-ibtn`)
//
// A 27×27 borderless square that fills on hover (hoverFill) and dims when
// disabled — the copy / reveal affordance used inside the meta-row chips. Split
// out as a real View so the @State hover wrapper actually drives updates.

private struct IconGhostButton: View {
    let systemImage: String
    let help: String
    let accessibility: String
    var tint: Color = BridgeTokens.fg4
    var accessibilityValue: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(hovering ? BridgeTokens.fg1 : tint)
                .frame(width: 27, height: 27)
                .background(shape.fill(hovering ? BridgeTokens.hoverFill : Color.clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help(help)
        .accessibilityLabel(accessibility)
        .accessibilityValue(accessibilityValue)
    }
}
