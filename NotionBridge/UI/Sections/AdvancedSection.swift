// AdvancedSection.swift — Liquid Glass reskin of Settings → Advanced.
// PKT-876 v3.6.1. Per design/advanced.html:
//   - Glass-hero header
//   - About card (kv-grid)
//   - Network card (port input)
//   - Local endpoints (copyable mono rows)
//   - System paths (reveal-in-finder rows)
//   - Maintenance (danger cards: export, reset onboarding, reset background items, factory reset)

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

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                aboutCard
                licenseCard
                networkCard
                localEndpointsCard
                systemPathsCard
                maintenanceCard
            }
            .padding(18)
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

    // MARK: - Header

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .advanced)
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: spec.subtitle,
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            Text("v\(appVersion)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("About")
                kvRow("App version", "\(appVersion)")
                kvRow("MCP protocol", BridgeConstants.mcpProtocolVersion)
                kvRow("Notion API", BridgeConstants.notionAPIVersion)
                kvRow("macOS", "macOS \(BridgeConstants.minimumMacOSMarketing)")
                kvRowMono("Bundle", Bundle.main.bundleIdentifier ?? "—")
            }
        }
    }

    @ViewBuilder
    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func kvRowMono(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
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

    // MARK: - Network

    private var networkCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Network")
                HStack(spacing: 8) {
                    Text("Local MCP port")
                        .font(.system(size: 13))
                        .frame(width: 140, alignment: .leading)
                    TextField(String(BridgeConstants.defaultSSEPort), text: $ssePortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: ssePortInput) { _, _ in ssePortSaveSuccess = false }
                    Button("Save", action: onSaveSSEPort)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Default") {
                        ssePortInput = String(BridgeConstants.defaultSSEPort)
                        ssePortError = nil
                        ssePortSaveSuccess = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                if let ssePortError {
                    Text(ssePortError).font(.caption2).foregroundStyle(.orange)
                }
                Text("Changes apply after Restart Bridge.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Local endpoints

    private var localEndpointsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Local endpoints")
                endpointRow("Streamable HTTP", "http://localhost:\(ssePort)/mcp")
                endpointRow("Legacy SSE", "http://localhost:\(ssePort)/sse")
                endpointRow("Health check", "http://localhost:\(ssePort)/health")
            }
        }
    }

    @ViewBuilder
    private func endpointRow(_ label: String, _ url: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(url)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
                .foregroundStyle(Color.white.opacity(0.86))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Copy endpoint URL to clipboard")
            Spacer()
        }
    }

    // MARK: - System paths

    private var systemPathsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("System paths")
                pathRow("Config", ConfigManager.shared.configFileURL.path)
                pathRow("Logs", BridgePaths.logs.path)
                pathRow("Screen output", screenOutputDir)
            }
        }
    }

    @ViewBuilder
    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
                .foregroundStyle(Color.white.opacity(0.86))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
            Spacer()
        }
    }

    // MARK: - Maintenance

    private var maintenanceCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Maintenance")
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    dangerCardTile(
                        title: "Export diagnostics",
                        subtitle: "Copy a redacted bundle to the clipboard for bug reports.",
                        actionLabel: "Export",
                        primary: true,
                        tint: NotionPalette.blue,
                        action: onExportDiagnostics
                    )
                    dangerCardTile(
                        title: "Reset onboarding",
                        subtitle: "Re-run the first-launch wizard on next start.",
                        actionLabel: "Reset",
                        primary: false,
                        tint: NotionPalette.gray,
                        action: { showResetConfirmation = true }
                    )
                    dangerCardTile(
                        title: "Reset background items",
                        subtitle: "Re-register scheduled jobs with launchd.",
                        actionLabel: "Reset",
                        primary: false,
                        tint: NotionPalette.gray,
                        action: { showResetBackgroundItemsConfirmation = true }
                    )
                    dangerCardTile(
                        title: "Factory reset",
                        subtitle: "Wipe all local Bridge state. Cannot be undone.",
                        actionLabel: "Factory reset\u{2026}",
                        primary: false,
                        tint: NotionPalette.red,
                        action: { showFactoryResetConfirmation = true },
                        isDestructive: true
                    )
                }
                if let factoryResetMessage {
                    Text(factoryResetMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let resetBackgroundItemsMessage {
                    Text(resetBackgroundItemsMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func dangerCardTile(
        title: String,
        subtitle: String,
        actionLabel: String,
        primary: Bool,
        tint: Color,
        action: @escaping () -> Void,
        isDestructive: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isDestructive ? Color(red: 1.0, green: 0.61, blue: 0.61) : tint.opacity(0.95))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Group {
                if primary {
                    Button(actionLabel, role: isDestructive ? .destructive : nil, action: action)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(actionLabel, role: isDestructive ? .destructive : nil, action: action)
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.5)
        )
    }
}

