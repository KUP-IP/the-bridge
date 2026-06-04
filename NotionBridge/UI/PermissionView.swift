// PermissionView.swift — TCC Grant Status Display
// V1-02: Shows green/red status per grant with "Open System Settings" deep links
// for all six v1 TCC grants.
// PKT-341: Added rebuild note explaining TCC grant invalidation
// PKT-349 B3: Added permission pre-triggers for Automation and Contacts grants
//   (mirrors D2 pattern from OnboardingWindow.swift)
// PKT-357 F14: Auto-refresh permission status every 2s while view is visible
// BUGFIX: Automation button always opens System Settings > Automation pane.
//   Previous approach (tccutil reset + silent re-probe) is unreliable on
//   macOS Sequoia — prompts are suppressed and the button appeared to do nothing.
//   Now consistently opens the Automation settings pane for manual grant.
// PKT-362 D1: Stripped DisclosureGroup verbosity — name + status icon only.
//   Remediation text conditional on non-granted state.
// PKT-362 D3: Animated per-row re-check feedback via grantCheckingState.
// PKT-362 D6: Batched restart banner when needsRestart flag is set.

import SwiftUI
import AppKit
import os.log

private let permLog = Logger(subsystem: "kup.solutions.notion-bridge", category: "PermissionView")

/// Displays the V1 TCC permission status grid.
/// PKT-362 D1: Clean rows — name + status icon only, no DisclosureGroup.
/// PKT-362 D3: Per-row animated "Checking…" state from grantCheckingState.
/// PKT-362 D6: Restart banner when needsRestart is true.
public struct PermissionView: View {
    let permissionManager: PermissionManager

    // PKT-357 F14: Timer publisher for auto-refresh (throttled — manual Re-check + activation still immediate)
    private let refreshTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var previousGrantStatus: [PermissionManager.Grant: PermissionManager.GrantStatus] = [:]
    @State private var recentlyGranted: Set<PermissionManager.Grant> = []

    public init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PermissionManager.Grant.v1Cases) { grant in
                permissionRow(
                    grant: grant,
                    status: permissionManager.status(for: grant)
                )
            }

            // PKT-798 (WS-C): not-yet-live capability gates
            upcomingCapabilitiesSection

            // PKT-362 D6: Batched restart banner
            if permissionManager.needsRestart {
                restartBanner
                    .padding(.top, 4)
            }

            // PKT-484: csreq mismatch banner — shown when TCC says granted but probe fails
            if permissionManager.hasCsreqMismatch {
                csreqMismatchBanner
                    .padding(.top, 4)
            }

        }
        // PKT-357 F14: Check permissions on appear
        // V1-PATCH-003: checkAll() is now async (automation probes off main thread)
        .task {
            await permissionManager.checkAllAsync()
            await MainActor.run { captureGrantTransitions() }
        }
        // PKT-369 N3: Auto-refresh every 2s with async variant (includes notifications)
        .onReceive(refreshTimer) { _ in
            Task {
                await permissionManager.checkAllAsync()
                await MainActor.run { captureGrantTransitions() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // PKT-369 N3: Use async variant for complete permission check
            Task {
                await permissionManager.checkAllAsync()
                await MainActor.run { captureGrantTransitions() }
            }
        }
    }

    // MARK: - Row

    /// PKT-362 D1: Grant name, status dot, label, and action — no extra description copy.
    /// PKT-362 D3: Yellow "Checking…" indicator when grantCheckingState is active.
    private func permissionRow(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> some View {
        let isChecking = permissionManager.grantCheckingState[grant] ?? false

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // D3: Yellow circle during check, normal status color otherwise
                Circle()
                    .fill(isChecking ? BridgeTokens.warn : statusColor(status))
                    .frame(width: 8, height: 8)

                Text(grant.displayName)
                    .font(.callout)

                Spacer()

                // D3: "Checking…" label during animated recheck
                if isChecking {
                    Text("Checking\u{2026}")
                        .font(.caption)
                        .foregroundStyle(BridgeTokens.warn)
                } else if recentlyGranted.contains(grant) {
                    Text("\u{2713} Granted")
                        .font(.caption)
                        .foregroundStyle(BridgeTokens.ok)
                } else {
                    Text(permissionManager.statusLabel(for: grant))
                        .font(.caption)
                        .foregroundStyle(status == .granted ? BridgeTokens.ok : BridgeTokens.warn)
                }

                // D1: Action button only for non-granted, non-checking states
                if status != .granted && !isChecking {
                    Button(actionButtonTitle(for: grant, status: status)) {
                        permLog.notice("Button tapped for grant: \(grant.displayName)")
                        openSystemSettings(for: grant)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.accent)
                }
            }

            // D1: DisclosureGroup REMOVED — probe/evidence data available via
            // Diagnostics export in Advanced settings or debugDetail(for:) API.
        }
        // D3: Animate row transitions (checking ↔ result) with 0.3s fade
        .animation(.easeInOut(duration: 0.3), value: isChecking)
    }

    // MARK: - PKT-798 (WS-C) Upcoming Capability Gates

    /// Network Listening (remote MCP, WS-F) + Microphone (Handy STT, WS-E).
    /// Both are feature-flagged OFF by default — the app never requests the
    /// underlying macOS permission until WS-E/WS-F flip BRIDGE_ENABLE_VOICE
    /// / BRIDGE_ENABLE_HTTP. These rows are informational only; there is no
    /// action button and no probe is ever issued from here.
    private struct UpcomingCapability: Identifiable {
        let id: String
        let name: String
        let enabled: Bool
    }

    private var upcomingCapabilities: [UpcomingCapability] {
        let flags = BridgeFeatureFlags()
        return [
            UpcomingCapability(id: "network-listening",
                               name: "Network Listening",
                               enabled: flags.httpEnabled),
            UpcomingCapability(id: "microphone",
                               name: "Microphone",
                               enabled: flags.voiceEnabled),
        ]
    }

    @ViewBuilder
    private var upcomingCapabilitiesSection: some View {
        Divider()
            .padding(.vertical, 2)

        Text("Upcoming capabilities")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        ForEach(upcomingCapabilities) { capability in
            HStack(spacing: 8) {
                Circle()
                    .fill(capability.enabled ? BridgeTokens.accent : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)

                Text(capability.name)
                    .font(.callout)

                Spacer()

                Text(capability.enabled
                     ? "Enabled \u{2014} wiring pending"
                     : "Not requested (feature disabled)")
                    .font(.caption)
                    .foregroundStyle(capability.enabled ? BridgeTokens.accent : .secondary)
            }
        }
    }

    // MARK: - D6 Restart Banner

    /// PKT-362 D6: Shows grant progress + single "Restart NotionBridge" prompt.
    /// Displays progress state when partial grants, confirmation when all granted.
    @ViewBuilder
    private var restartBanner: some View {
        let grantedCount = PermissionManager.Grant.v1Cases.filter {
            permissionManager.status(for: $0) == .granted
        }.count
        let totalCount = PermissionManager.Grant.v1Cases.count
        let allGranted = grantedCount == totalCount

        VStack(spacing: 6) {
            if allGranted {
                Label("All permissions granted \u{2014} restart to apply changes.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.ok)
            } else {
                Label("\(grantedCount) of \(totalCount) granted \u{2014} grant remaining permissions, then restart.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(BridgeTokens.warn)
            }

            Button("Restart Notion Bridge") {
                NSApp.restartBridge()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(allGranted ? BridgeTokens.ok.opacity(0.1) : BridgeTokens.warn.opacity(0.1))
        )
    }

    // MARK: - PKT-484 csreq Mismatch Banner

    /// PKT-484: Shows warning when TCC csreq mismatch is detected.
    /// Explains the issue and offers "Reset & Re-authorize" button.
    @ViewBuilder
    private var csreqMismatchBanner: some View {
        let targets = permissionManager.csreqMismatchTargets.map(\.name).joined(separator: ", ")

        VStack(spacing: 6) {
            Label("Automation mismatch detected", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BridgeTokens.warn)

            Text("\(targets): TCC database shows granted but runtime probe fails. This happens when macOS stores a stale code signature (csreq) from a previous build.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("⚠️ This will reset ALL automation permissions. You will be prompted to re-authorize each app.")
                .font(.caption2)
                .foregroundStyle(BridgeTokens.warn)
                .multilineTextAlignment(.center)

            Button("Reset & Re-authorize") {
                Task {
                    await permissionManager.resetAndReauthorizeAutomation()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(BridgeTokens.warn)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(BridgeTokens.warn.opacity(0.1))
        )
    }

    // MARK: - Helpers

    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return BridgeTokens.ok
        case .denied: return BridgeTokens.warn
        case .unknown: return BridgeTokens.warn
        case .partiallyGranted: return BridgeTokens.warn
        case .restartRecommended: return BridgeTokens.warn
        }
    }

    private func actionButtonTitle(
        for grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> String {
        switch grant {
        case .automation, .fullDiskAccess:
            return "Open Settings"
        case .contacts, .notifications:
            return status == .unknown ? "Allow" : "Open Settings"
        case .accessibility, .screenRecording:
            return "Allow"
        }
    }

    @MainActor
    private func captureGrantTransitions() {
        for grant in PermissionManager.Grant.v1Cases {
            let current = permissionManager.status(for: grant)
            if let previous = previousGrantStatus[grant],
               previous == .denied,
               current == .granted {
                recentlyGranted.insert(grant)
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    _ = await MainActor.run {
                        recentlyGranted.remove(grant)
                    }
                }
            }
            previousGrantStatus[grant] = current
        }
    }

    // PKT-547: restartApp() moved to BridgeUtilities.swift as
    // NSApplication.restartBridge() so DashboardView and PermissionView
    // share the same restart implementation.

    // MARK: - Deep Links

    /// Opens the relevant System Settings pane for the given TCC grant.
    /// Strategy per grant:
    /// - Accessibility, Screen Recording: Trigger native macOS prompt (reliable on Sequoia).
    /// - Automation: Always open System Settings > Automation pane. The previous approach
    ///   (tccutil reset + NSAppleScript re-probe) is unreliable on macOS Sequoia — prompts
    ///   are silently suppressed and the button appeared to do nothing. Direct Settings
    ///   navigation is the only reliable path for users to grant Automation targets.
    /// - Contacts: Trigger native Contacts prompt.
    /// - Full Disk Access: Always open System Settings (no native prompt exists).
    private func openSystemSettings(for grant: PermissionManager.Grant) {
        switch grant {
        case .accessibility:
            // Trigger the native macOS prompt only — do NOT also open System Settings.
            _ = permissionManager.requestAccessibilityAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .automation:
            // Always open System Settings > Automation pane directly.
            // tccutil reset + re-probe is unreliable on macOS Sequoia — prompts get
            // silently suppressed, making the button appear to do nothing.
            // The checkAutomation() probes running on the 2s timer will register the
            // app in TCC so it appears in the Automation list.
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            permLog.notice("[AUTOMATION] Attempting to open: \(urlString)")
            if let url = URL(string: urlString) {
                permLog.notice("[AUTOMATION] URL created successfully: \(url.absoluteString)")
                let result = NSWorkspace.shared.open(url)
                permLog.notice("[AUTOMATION] NSWorkspace.shared.open returned: \(result)")
            } else {
                permLog.error("[AUTOMATION] Failed to create URL from string: \(urlString)")
            }
            Task {
                await permissionManager.recheckAllForTruth()
            }
        case .notifications:
            let status = permissionManager.status(for: .notifications)
            Task {
                if status == .unknown {
                    _ = await permissionManager.requestNotificationAccess()
                    let resolvedStatus = permissionManager.status(for: .notifications)
                    if resolvedStatus != .granted,
                       let url = PermissionManager.Grant.notifications.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } else if let url = PermissionManager.Grant.notifications.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .contacts:
            let status = permissionManager.status(for: .contacts)
            Task {
                if status == .unknown {
                    _ = await permissionManager.requestContactsAccess()
                    let resolvedStatus = permissionManager.status(for: .contacts)
                    if resolvedStatus != .granted,
                       let url = PermissionManager.Grant.contacts.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } else if let url = PermissionManager.Grant.contacts.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .screenRecording:
            // Trigger the native Screen Recording prompt only — do NOT also open System Settings.
            _ = permissionManager.requestScreenRecordingAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .fullDiskAccess:
            // Full Disk Access: no native prompt exists — must open System Settings directly.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
            Task {
                await permissionManager.recheckAllForTruth()
            }
        }
    }
}

// MARK: - Onboarding: Auto Permissions (PKT-388)

private enum AutoGrantProgressState {
    case pending
    case prompting
    case granted
    case denied
}

struct AutoPermissionsStepView: View {
    let permissionManager: PermissionManager
    let onResolved: (() -> Void)?

    @State private var isGrantingAll = false
    @State private var progressState: [PermissionManager.Grant: AutoGrantProgressState] = [:]
    /// Defers probes on appear — user taps Re-check or Grant All first (avoids stale/misleading granted state).
    @State private var userInitiatedProbe = false

    init(permissionManager: PermissionManager, onResolved: (() -> Void)? = nil) {
        self.permissionManager = permissionManager
        self.onResolved = onResolved
    }

    private var autoGrants: [PermissionManager.Grant] {
        PermissionManager.Grant.v1Cases.filter(\.isAutoGrantable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 2: Auto Permissions")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Tap “Re-check Status” or “Grant All” to verify permission state. Until then, indicators may not reflect what System Settings shows. Grant All triggers Contacts, Notifications, and Automation prompts up front.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                ForEach(autoGrants) { grant in
                    autoPermissionRow(for: grant)
                }
            }

            HStack(spacing: 10) {
                Button(isGrantingAll ? "Granting…" : "Grant All") {
                    Task { await runGrantAllSequentially() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(isGrantingAll)

                Button("Re-check Status") {
                    Task {
                        userInitiatedProbe = true
                        await permissionManager.recheckAllForTruth()
                        syncProgressFromManager()
                        notifyResolvedIfNeeded()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGrantingAll)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard userInitiatedProbe else { return }
            Task {
                await permissionManager.recheckAllForTruth()
                syncProgressFromManager()
                notifyResolvedIfNeeded()
            }
        }
    }

    private func autoPermissionRow(for grant: PermissionManager.Grant) -> some View {
        let state = uiState(for: grant)
        let status = permissionManager.status(for: grant)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(for: state))
                    .frame(width: 9, height: 9)

                Text(grant.displayName)
                    .font(.callout)

                Spacer()

                Text(label(for: state, status: status))
                    .font(.caption)
                    .foregroundStyle(color(for: state))
            }

            Text(permissionManager.remediation(for: grant))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if needsRemediation(status: status) {
                Button("Open \(grant.displayName) Settings") {
                    openSettings(for: grant)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(BridgeTokens.accent)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private func uiState(for grant: PermissionManager.Grant) -> AutoGrantProgressState {
        if let inFlightState = progressState[grant], inFlightState == .prompting {
            return inFlightState
        }
        return baselineState(for: grant)
    }

    private func baselineState(for grant: PermissionManager.Grant) -> AutoGrantProgressState {
        if !userInitiatedProbe { return .pending }
        switch permissionManager.status(for: grant) {
        case .granted:
            return .granted
        case .denied, .partiallyGranted, .restartRecommended:
            return .denied
        case .unknown:
            return .pending
        }
    }

    private func syncProgressFromManager() {
        for grant in autoGrants {
            progressState[grant] = baselineState(for: grant)
        }
    }

    private func notifyResolvedIfNeeded() {
        guard autoGrants.allSatisfy({ permissionManager.status(for: $0).isAutoResolved }) else {
            return
        }
        onResolved?()
    }

    private func runGrantAllSequentially() async {
        guard !isGrantingAll else { return }
        userInitiatedProbe = true
        isGrantingAll = true
        defer { isGrantingAll = false }

        await permissionManager.recheckAllForTruth()

        for grant in autoGrants {
            if permissionManager.status(for: grant).isAutoResolved {
                progressState[grant] = baselineState(for: grant)
                continue
            }

            withAnimation {
                progressState[grant] = .prompting
            }

            switch grant {
            case .contacts:
                _ = await permissionManager.requestContactsAccess()
                if permissionManager.status(for: .contacts) != .granted,
                   let url = PermissionManager.Grant.contacts.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            case .notifications:
                _ = await permissionManager.requestNotificationAccess()
            case .automation:
                await permissionManager.requestAutomationAccess()
            default:
                break
            }

            await permissionManager.recheckAllForTruth()
            withAnimation {
                progressState[grant] = baselineState(for: grant)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        syncProgressFromManager()
        notifyResolvedIfNeeded()
    }

    private func color(for state: AutoGrantProgressState) -> Color {
        switch state {
        case .pending: return BridgeTokens.warn
        case .prompting: return BridgeTokens.warn
        case .granted: return BridgeTokens.ok
        case .denied: return BridgeTokens.bad
        }
    }

    private func label(for state: AutoGrantProgressState, status: PermissionManager.GrantStatus) -> String {
        switch state {
        case .pending:
            return userInitiatedProbe ? "Pending" : "Not verified"
        case .prompting: return "Prompting…"
        case .granted: return "Granted"
        case .denied:
            if status == .partiallyGranted {
                return "Denied (Partial)"
            }
            return "Denied"
        }
    }

    private func needsRemediation(status: PermissionManager.GrantStatus) -> Bool {
        switch status {
        case .denied, .partiallyGranted:
            return true
        case .granted, .unknown, .restartRecommended:
            return false
        }
    }

    private func openSettings(for grant: PermissionManager.Grant) {
        guard let url = grant.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Onboarding: Manual Permissions (PKT-388)

struct ManualPermissionsStepView: View {
    let permissionManager: PermissionManager

    private var manualGrants: [PermissionManager.Grant] {
        PermissionManager.Grant.v1Cases.filter { !$0.isAutoGrantable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 3: Manual Permissions")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("These permissions must be enabled manually in System Settings. Use each deep link, grant access, then return and re-check. The Permissions tab can stay stale until you restart after a TCC reset.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                ForEach(manualGrants) { grant in
                    manualPermissionRow(for: grant)
                }
            }

            Button("Re-check Status") {
                Task { await permissionManager.recheckAllForTruth() }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            await permissionManager.recheckAllForTruth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionManager.recheckAllForTruth() }
        }
    }

    private func manualPermissionRow(for grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 9, height: 9)

                Text(grant.displayName)
                    .font(.callout)

                Spacer()

                Text(permissionManager.statusLabel(for: grant))
                    .font(.caption)
                    .foregroundStyle(status == .granted ? BridgeTokens.ok : BridgeTokens.warn)
            }

            Text(manualInstruction(for: grant))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Open \(grant.displayName) Settings") {
                guard let url = grant.systemSettingsURL else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(BridgeTokens.accent)
        }
    }

    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted: return BridgeTokens.ok
        case .denied: return BridgeTokens.bad
        case .unknown, .partiallyGranted, .restartRecommended: return BridgeTokens.warn
        }
    }

    private func manualInstruction(for grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility:
            return "System Settings > Privacy & Security > Accessibility: enable Notion Bridge."
        case .screenRecording:
            return "System Settings > Privacy & Security > Screen Recording: enable Notion Bridge."
        case .fullDiskAccess:
            return "System Settings > Privacy & Security > Full Disk Access: enable Notion Bridge."
        case .automation, .notifications, .contacts:
            return permissionManager.remediation(for: grant)
        }
    }
}

private extension PermissionManager.GrantStatus {
    var isAutoResolved: Bool {
        switch self {
        case .granted, .denied, .partiallyGranted:
            return true
        case .unknown, .restartRecommended:
            return false
        }
    }
}
