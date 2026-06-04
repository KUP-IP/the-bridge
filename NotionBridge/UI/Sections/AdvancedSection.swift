// AdvancedSection.swift — Settings → Advanced pane.
// v3.7.2 bundle-3 redesign. Mirrors design/.../the-bridge/Advanced.jsx +
// advanced.css and the approved StandingOrdersSection language: a custom
// glass hero (orb + title/sub + actions), kv-grid About card, port-input
// Network card, copyable mono endpoint rows, reveal-in-Finder path rows,
// and a 2-col Maintenance grid with a blue export tile + red danger tiles.
//
// VIEW LAYER ONLY — every binding is preserved verbatim: version/about
// strings, SSE port edit + validation, copy endpoint rows, reveal-in-Finder
// path rows, maintenance/danger tiles (export, reset onboarding, reset
// background items, factory reset), and the LicenseCard state machine.

import SwiftUI
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

    /// PKT-909 W3 — License card lives as a sibling card inside
    /// Advanced. Self-hosted state via LicenseCardHost so the
    /// AdvancedSection signature is unchanged.
    @StateObject private var licenseHost = LicenseCardHost()

    /// Transient "copied" flash, keyed by the copied row's value so the
    /// check-mark lands on the row the user actually clicked.
    @State private var copiedKey: String? = nil

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                aboutCard
                licenseCard
                networkCard
                localEndpointsCard
                systemPathsCard
                maintenanceCard
            }
            .padding(20)
        }
        .task { await licenseHost.load() }
        .onReceive(NotificationCenter.default.publisher(for: .licenseStateDidChange)) { _ in
            Task { await licenseHost.load() }
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

    // MARK: - Hero (orb + title/sub + actions, mirrors so-hero)

    private var hero: some View {
        BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.accent.opacity(0.22))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 1))
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.accentLink)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Advanced")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Build info, network ports, local endpoints, on-disk paths, and maintenance. For power users.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                versionTile
                adIconButton("square.and.arrow.up", help: "Export diagnostics", action: onExportDiagnostics)
            }
        }
    }

    private var versionTile: some View {
        VStack(spacing: 3) {
            Text("v\(appVersion)")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(BridgeTokens.gold)
            Text("VERSION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
    }

    private func adIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(BridgeTokens.fg3)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - About (kv-grid)

    private var aboutCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("About")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                    kvRow("App version", appVersion, mono: false)
                    kvRow("MCP protocol", BridgeConstants.mcpProtocolVersion, mono: false)
                    kvRow("Notion API", BridgeConstants.notionAPIVersion, mono: false)
                    kvRow("macOS", "macOS \(BridgeConstants.minimumMacOSMarketing)", mono: false)
                    kvRow("Bundle", Bundle.main.bundleIdentifier ?? "—", mono: true)
                }
            }
        }
    }

    @ViewBuilder
    private func kvRow(_ key: String, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(BridgeTokens.fg1)
                .monospacedDigit()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - License (PKT-909 W3)

    private var licenseCard: some View {
        LicenseCard(
            state: licenseHost.uiState,
            pasteField: Binding(
                get: { licenseHost.pasteField },
                set: { licenseHost.pasteField = $0 }
            ),
            onActivate: { Task { await licenseHost.activate() } },
            onDeactivate: { Task { await licenseHost.deactivate() } },
            onBuy: { licenseHost.openBuyPage() }
        )
    }

    // MARK: - Network (port input)

    private var networkCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Network")
                HStack(spacing: 8) {
                    Text("Local MCP port")
                        .font(.system(size: 13))
                        .foregroundStyle(BridgeTokens.fg2)
                        .frame(width: 150, alignment: .leading)
                    TextField(String(BridgeConstants.defaultSSEPort), text: $ssePortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: ssePortInput) { _, _ in ssePortSaveSuccess = false }
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
                            .foregroundStyle(BridgeTokens.ok)
                            .transition(.opacity)
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
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
    }

    // MARK: - Local endpoints (copyable mono rows)

    private var localEndpointsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Local endpoints")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                    copyRow("Streamable HTTP", "http://localhost:\(ssePort)/mcp")
                    copyRow("Legacy SSE", "http://localhost:\(ssePort)/sse")
                    copyRow("Health check", "http://localhost:\(ssePort)/health")
                }
            }
        }
    }

    @ViewBuilder
    private func copyRow(_ label: String, _ url: String) -> some View {
        GridRow(alignment: .center) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
                .gridColumnAlignment(.leading)
            HStack(spacing: 8) {
                monoChip(url)
                copyButton(url)
            }
        }
    }

    // MARK: - System paths (reveal-in-Finder rows)

    private var systemPathsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("System paths")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                    pathRow("Config", ConfigManager.shared.configFileURL.path)
                    pathRow("Logs", BridgePaths.logs.path)
                    pathRow("Screen output", screenOutputDir)
                }
            }
        }
    }

    @ViewBuilder
    private func pathRow(_ label: String, _ path: String) -> some View {
        GridRow(alignment: .center) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(BridgeTokens.fg3)
                .gridColumnAlignment(.leading)
            HStack(spacing: 8) {
                monoChip(path, truncateMiddle: true)
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                        .frame(width: 27, height: 27)
                        .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(label) in Finder")
                copyButton(path)
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
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copiedKey = value }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if copiedKey == value { withAnimation { copiedKey = nil } }
            }
        } label: {
            Image(systemName: copiedKey == value ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copiedKey == value ? BridgeTokens.ok : BridgeTokens.fg3)
                .frame(width: 27, height: 27)
                .background(BridgeTokens.chipFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel("Copy to clipboard")
    }

    // MARK: - Maintenance (2-col grid of tiles)

    private var maintenanceCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                BridgeCardLabel("Maintenance")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    maintTile(
                        title: "Export diagnostics",
                        subtitle: "A redacted bundle with logs, settings (no secrets), and recent tool calls — useful for bug reports.",
                        actionLabel: "Export\u{2026}",
                        style: .export,
                        action: onExportDiagnostics
                    )
                    maintTile(
                        title: "Reset onboarding",
                        subtitle: "Re-run the first-launch wizard on next start. Workspace credentials preserved.",
                        actionLabel: "Reset",
                        style: .neutral,
                        action: { showResetConfirmation = true }
                    )
                    maintTile(
                        title: "Reset background items",
                        subtitle: "Re-register scheduled jobs with launchd.",
                        actionLabel: "Reset",
                        style: .neutral,
                        action: { showResetBackgroundItemsConfirmation = true }
                    )
                    maintTile(
                        title: "Factory reset",
                        subtitle: "Wipe all local Bridge state — commands, snippets, jobs, paths, credentials. Cannot be undone.",
                        actionLabel: "Factory reset\u{2026}",
                        style: .danger,
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

    private enum MaintStyle { case export, neutral, danger }

    @ViewBuilder
    private func maintTile(
        title: String,
        subtitle: String,
        actionLabel: String,
        style: MaintStyle,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = {
            switch style {
            case .export:  return BridgeTokens.accent
            case .neutral: return Color.white
            case .danger:  return BridgeTokens.bad
            }
        }()
        let titleColor: Color = {
            switch style {
            case .export:  return BridgeTokens.accentLink
            case .neutral: return BridgeTokens.fg1
            case .danger:  return BridgeTokens.badText
            }
        }()
        let fill: Color = style == .neutral ? BridgeTokens.chipFill : tint.opacity(0.07)
        let stroke: Color = style == .neutral ? BridgeTokens.hairline : tint.opacity(0.22)

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
                switch style {
                case .export:
                    Button(actionLabel, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(BridgeTokens.accent)
                case .neutral:
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                case .danger:
                    Button(actionLabel, role: .destructive, action: action)
                        .buttonStyle(.bordered)
                        .tint(BridgeTokens.bad)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: 0.5))
    }
}
