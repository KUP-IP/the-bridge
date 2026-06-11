// SettingsWindow+Sections.swift — Settings Section Views
// V3-QUALITY D1-D5: Extracted from SettingsWindow.swift monolith.
// Each section is an extension on SettingsView for clean separation.

import AppKit
import Darwin
import Foundation
import LocalAuthentication
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
    /// Bespoke single-surface composite (replaces the generic BridgeMergedSection
    /// for this section): one shared header, a segmented Orders | Commands strip,
    /// a per-tab meta row, and unsaved-draft-safe tab switching. The deep-link
    /// `anchor` selects the starting tab (e.g. `commands` → Commands).
    @ViewBuilder
    var ordersSection: some View {
        OrdersSection(anchor: nav.anchor)
    }

    /// Security = the merged Vault (credentials) + Gates (access) page.
    /// Bespoke single-surface composite (replaces the generic BridgeMergedSection
    /// for this section): one posture header (Touch-ID reveal status · #stored ·
    /// #attention · read-only tool tier counts OPEN/NOTIFY/REQUEST with a Manage-
    /// in-Tools link) over a segmented Vault | Gates strip. Anchor `gates`/
    /// `permissions` opens Gates; everything else (incl. a credential-row slug
    /// like "notion") opens Vault.
    @ViewBuilder
    var securitySection: some View {
        SecuritySection(
            anchor: nav.anchor,
            liveTools: statusBar.toolInfoList,
            vault: { AnyView(credentialsSection) },
            gates: { AnyView(permissionsSection) }
        )
    }

    /// Connection = Connections (Local clients) + Remote Access.
    /// Bespoke single-surface composite (replaces the generic BridgeMergedSection
    /// for this section): a live status strip on top (server-running dot · clients
    /// count · last-seen · calls-today · Restart + Copy-loopback) over a single
    /// scroll that racks Local clients above Remote access. The deep-link `anchor`
    /// (`remote`/`cloud`) auto-scrolls to the Remote-access block.
    @ViewBuilder
    var connectionSection: some View {
        ConnectionSection(anchor: nav.anchor, statusBar: statusBar)
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
        ConnectionsSection(statusBar: statusBar)
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

// MARK: - Jobs Section (PKT-876 v3.6.1 — Liquid Glass reskin)

extension SettingsView {
    @ViewBuilder
    var jobsSection: some View {
        JobsSection()
    }
}

// MARK: - Security composite (bespoke merged page — replaces BridgeMergedSection)

/// The merged **Security** Settings page: ONE bespoke posture header (replacing
/// both legacy orb-heroes) over a segmented `Vault | Gates` strip, with the
/// account-level **License** card pinned beneath the header.
///
/// Posture header (left→right): a 44 `lock.shield` gold orb · "Security" title +
/// subtitle · stat tiles STORED / ATTENTION + read-only tool tier counts
/// OPEN/NOTIFY/REQUEST (Tools owns those — a "Manage in Tools" link, never an
/// edit here) · a Touch-ID-to-reveal chip. It subscribes to BOTH the credentials-
/// changed and tier-overrides-changed notifications so the counts live-update.
///
/// PKT-W3-license: License (entitlement / billing posture) was relocated here
/// from Advanced. It sits directly under the posture header — above the tab bar
/// — because the activation state machine governs the whole app, not one tab.
/// Its `LicenseCardHost` state machine is carried verbatim (self-hosted via the
/// `@StateObject` below, the `.task` initial load, and the
/// `.licenseStateDidChange` refresh); the license-activation contract is
/// unchanged.
///
/// The two tab bodies (`CredentialsSection`, `PermissionsSection`) are hero-less
/// and self-contained; this composite only owns the header, the License card,
/// the tab bar, and the deep-link anchor → starting-tab resolution.
struct SecuritySection: View {
    let anchor: String?
    let liveTools: [ToolInfo]
    let vault: () -> AnyView
    let gates: () -> AnyView

    private enum Tab: String, Hashable, CaseIterable { case vault, gates }

    @State private var selection: Tab

    /// PKT-W3-license — License card lives under the posture header inside
    /// Security. Self-hosted state via LicenseCardHost so the SecuritySection
    /// signature is unchanged.
    @StateObject private var licenseHost = LicenseCardHost()

    // Posture metrics — recomputed on the change notifications below.
    @State private var storedCount: Int = 0
    @State private var attentionCount: Int = 0
    @State private var tierCounts: (open: Int, notify: Int, request: Int) = (0, 0, 0)

    /// Mirrored read-only in the header chip; the editable toggle lives in the
    /// Vault policy card (same @AppStorage key — single source of truth).
    @AppStorage(CredentialRevealGate.requireTouchIDKey) private var requireTouchID = true

    init(
        anchor: String?,
        liveTools: [ToolInfo],
        vault: @escaping () -> AnyView,
        gates: @escaping () -> AnyView
    ) {
        self.anchor = anchor
        self.liveTools = liveTools
        self.vault = vault
        self.gates = gates
        self._selection = State(initialValue: SecuritySection.tab(for: anchor) ?? .vault)
    }

    var body: some View {
        VStack(spacing: 0) {
            postureHeader
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            licenseCard
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
            tabBar
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider().background(BridgeTokens.hairlineFaint)

            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .task { refreshMetrics() }
        .task { await licenseHost.load() }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeCredentialsFeatureDidChange)) { _ in
            refreshMetrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeTierOverridesDidChange)) { _ in
            refreshTierCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .licenseStateDidChange)) { _ in
            Task { await licenseHost.load() }
        }
        .onChange(of: anchor) { _, newAnchor in
            if let t = SecuritySection.tab(for: newAnchor) { selection = t }
        }
    }

    // MARK: License (PKT-W3-license — relocated from Advanced)

    /// Account-level entitlement posture. Pinned under the posture header so the
    /// activation state machine (trial / licensed / expired / grandfathered) is
    /// visible from either tab. The LicenseCard API and its host are unchanged —
    /// this is the same component that previously rendered inside Advanced.
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

    // MARK: Posture header

    private var postureHeader: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .security)
        return BridgeGlassCard(cornerRadius: BridgeTokens.Radius.card, padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(BridgeTokens.gold.opacity(0.20))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BridgeTokens.gold.opacity(0.85))
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Stored secrets and the gates that govern what tools can do.")
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                postureMetrics
                touchIDChip
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var postureMetrics: some View {
        HStack(spacing: 10) {
            statTile(value: "\(storedCount)", label: "stored", color: BridgeTokens.okText)
            statTile(
                value: "\(attentionCount)",
                label: "attention",
                color: attentionCount > 0 ? BridgeTokens.warnText : BridgeTokens.fg4
            )
            tierCountTile
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// Read-only tri-segment tile of tool tier counts (OPEN · NOTIFY · REQUEST),
    /// tapping through to the Tools page where they are actually managed. Tools
    /// owns the tier model — this is a posture mirror, never an editor.
    private var tierCountTile: some View {
        Button {
            SettingsNavigation.shared.go(.tools)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text("\(tierCounts.open)").foregroundStyle(BridgeTokens.okText)
                    Text("·").foregroundStyle(BridgeTokens.fg5)
                    Text("\(tierCounts.notify)").foregroundStyle(BridgeTokens.warnText)
                    Text("·").foregroundStyle(BridgeTokens.fg5)
                    Text("\(tierCounts.request)").foregroundStyle(BridgeTokens.badText)
                }
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                HStack(spacing: 3) {
                    Text("GATES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(BridgeTokens.fg4)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BridgeTokens.fg5)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Open / Notify / Request tool counts — manage per-tool gates in Tools")
        .accessibilityLabel("Tool gates: \(tierCounts.open) open, \(tierCounts.notify) notify, \(tierCounts.request) request. Manage in Tools.")
    }

    /// Touch-ID reveal status chip — surfaces the reveal gate BEFORE the user hits
    /// Copy/Rotate. Reads `requireTouchID`; on a device without biometrics the
    /// reveal passes through (matches CredentialRevealGate.shouldGate).
    private var touchIDChip: some View {
        let available = SecuritySection.biometricAvailable
        let (text, tone): (String, Color) = {
            if !available { return ("Touch ID unavailable", BridgeTokens.fg4) }
            return requireTouchID
                ? ("Touch ID to reveal: On", BridgeTokens.okText)
                : ("Touch ID to reveal: Off", BridgeTokens.fg4)
        }()
        return HStack(spacing: 5) {
            Image(systemName: "touchid")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(BridgeTokens.chipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Vault", .vault)
            tabButton("Gates", .gates)
        }
        .padding(2)
        .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security section tabs")
    }

    private func tabButton(_ label: String, _ value: Tab) -> some View {
        let on = selection == value
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selection = value }
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? BridgeTokens.fg1 : BridgeTokens.fg3)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(minHeight: 28)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BridgeTokens.accent.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(BridgeTokens.accent.opacity(0.45), lineWidth: 0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Tab body

    @ViewBuilder private var tabBody: some View {
        switch selection {
        case .vault: vault()
        case .gates: gates()
        }
    }

    // MARK: Metrics

    private func refreshMetrics() {
        refreshCredentialCounts()
        refreshTierCounts()
    }

    private func refreshCredentialCounts() {
        guard let entries = try? CredentialManager.shared.list() else {
            storedCount = 0
            attentionCount = 0
            return
        }
        storedCount = entries.count
        let store = CredentialHealthStore()
        let health = store.load()
        attentionCount = entries.filter { entry in
            if entry.type == .card {
                return CredentialCardExpiry.health(
                    expMonth: entry.metadata.expMonth,
                    expYear: entry.metadata.expYear
                ).needsAttention
            }
            let key = CredentialHealthStore.key(service: entry.service, account: entry.account)
            return (health[key] ?? .unchecked).health.needsAttention
        }.count
    }

    /// Tool tier counts from the SAME resolution Tools/router use (per-tool
    /// override > module grant > registered default). Read-only mirror.
    private func refreshTierCounts() {
        let toolOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides) as? [String: String]) ?? [:]
        let moduleOverrides = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]
        var open = 0, notify = 0, request = 0
        for tool in liveTools {
            let tier = ToolTierResolution.effectiveTier(
                toolName: tool.name,
                module: tool.module,
                registeredTier: tool.tier,
                toolOverrides: toolOverrides,
                moduleOverrides: moduleOverrides
            )
            switch tier {
            case "open": open += 1
            case "notify": notify += 1
            case "request": request += 1
            default: break
            }
        }
        tierCounts = (open, notify, request)
    }

    /// True when this device can evaluate a biometric (or passcode-fallback)
    /// policy — drives the header chip's "Touch ID unavailable" state. When false
    /// the reveal gate passes through (matches CredentialManager's fallback path).
    static var biometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: Deep-link anchor → tab

    /// Resolve a deep-link anchor to a tab (gates/permissions aliases open Gates;
    /// vault/credential aliases open Vault). Returns nil when the anchor names
    /// neither (caller keeps the default Vault tab; a credential slug like
    /// "notion" still reaches the Vault body via SettingsNavigation).
    private static func tab(for anchor: String?) -> Tab? {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
            !raw.isEmpty else { return nil }
        switch raw {
        case "gates", "gate", "permissions", "permission", "privacy", "access": return .gates
        case "vault", "credentials", "credential", "secrets": return .vault
        default: return nil
        }
    }
}

// MARK: - Connection composite (bespoke merged page — replaces BridgeMergedSection)

/// The merged **Connection** Settings page: a live STATUS STRIP on top over a
/// single scroll that racks **Local clients** above **Remote access** — mirroring
/// how trust narrows (loopback is trusted and token-exempt; cloud is gated).
///
/// Status strip (left→right): one dot+label vocabulary driven by
/// `statusBar.isServerRunning` (Online/Stopped) · connected-client count ·
/// last-seen (most-recent client) · calls-today as muted meta · trailing icon
/// actions Restart + Copy-loopback. It replaces BOTH legacy orb-heroes
/// (ConnectionsSection + RemoteAccessSection), reclaiming ~120pt above the fold.
///
/// The two bodies (`ConnectionsSection` = Local, `RemoteAccessSection` = Remote)
/// are hero-less; this composite owns the strip and the deep-link anchor →
/// scroll-target resolution (`remote`/`cloud` scrolls to the Remote block).
struct ConnectionSection: View {
    let anchor: String?
    let statusBar: StatusBarController

    @State private var copiedLoopback = false

    private static let remoteAnchorID = "connection.remote"

    private var port: Int { ConfigManager.shared.ssePort }
    private var loopbackURL: String { "http://127.0.0.1:\(port)/mcp" }

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
                .padding(.horizontal, BridgeTokens.Space.paneH)
                .padding(.top, BridgeTokens.Space.cardGap)
                .padding(.bottom, 10)

            Divider().background(BridgeTokens.hairlineFaint)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: BridgeTokens.Space.cardGap) {
                        ConnectionsSection(statusBar: statusBar)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                        remoteHeader
                            .id(Self.remoteAnchorID)
                        RemoteAccessSection()
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, BridgeTokens.Space.paneV)
                }
                .onAppear { scrollIfRemote(proxy) }
                .onChange(of: anchor) { _, _ in scrollIfRemote(proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    // MARK: Status strip

    private var statusStrip: some View {
        let running = statusBar.isServerRunning
        let dot = running ? BridgeTokens.ok : BridgeTokens.bad
        let label = running ? "Online" : "Stopped"
        let labelText = running ? BridgeTokens.okText : BridgeTokens.badText
        return BridgeGlassCard(cornerRadius: BridgeTokens.Radius.card, padding: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 9, height: 9)
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(labelText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Server \(label)")

                metaSeparator
                clientsMeta
                if let seen = lastSeen {
                    metaSeparator
                    Text(seen)
                        .font(.system(size: 12))
                        .foregroundStyle(BridgeTokens.fg4)
                        .accessibilityLabel("Last seen \(seen)")
                }
                metaSeparator
                Text("\(statusBar.totalToolCalls.formatted()) calls today")
                    .font(.system(size: 12))
                    .foregroundStyle(BridgeTokens.fg4)
                    .lineLimit(1)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    iconButton("arrow.clockwise", help: "Restart Bridge", label: "Restart Bridge") {
                        NSApp.restartBridge()
                    }
                    iconButton(copiedLoopback ? "checkmark" : "doc.on.doc",
                               help: "Copy loopback endpoint",
                               label: copiedLoopback ? "Copied loopback endpoint" : "Copy loopback endpoint",
                               tint: copiedLoopback ? BridgeTokens.okText : BridgeTokens.fg3) {
                        copyLoopback()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var clientsMeta: some View {
        let n = statusBar.connectedClients.count
        return Text(n == 0 ? "No clients" : "\(n) client\(n == 1 ? "" : "s")")
            .font(.system(size: 12, weight: n == 0 ? .regular : .medium))
            .foregroundStyle(n == 0 ? BridgeTokens.fg4 : BridgeTokens.fg2)
            .lineLimit(1)
            .accessibilityLabel(n == 0 ? "No clients connected" : "\(n) clients connected")
    }

    private var metaSeparator: some View {
        Text("·")
            .font(.system(size: 12))
            .foregroundStyle(BridgeTokens.fg5)
            .accessibilityHidden(true)
    }

    /// Most-recent client connection as a relative "last-seen" string. Nil when
    /// no clients are connected (the field is hidden in that case).
    private var lastSeen: String? {
        guard let latest = statusBar.connectedClients.map(\.connectedAt).max() else { return nil }
        let interval = Date().timeIntervalSince(latest)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func iconButton(_ systemImage: String, help: String, label: String,
                            tint: Color = BridgeTokens.fg3, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func copyLoopback() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(loopbackURL, forType: .string)
        copiedLoopback = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copiedLoopback = false
        }
    }

    // MARK: Remote-access separator header (scroll target)

    private var remoteHeader: some View {
        HStack(spacing: 8) {
            Text("REMOTE ACCESS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(BridgeTokens.fg4)
            Rectangle().fill(BridgeTokens.hairlineFaint).frame(height: 0.5)
        }
        .padding(.horizontal, BridgeTokens.Space.paneH)
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Deep-link anchor → scroll target

    private func scrollIfRemote(_ proxy: ScrollViewProxy) {
        guard let raw = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
            !raw.isEmpty else { return }
        switch raw {
        case "remote", "remoteaccess", "cloud":
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(Self.remoteAnchorID, anchor: .top)
            }
        default:
            break
        }
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
