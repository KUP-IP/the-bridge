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

    /// v3.7.2 redesign: LED-badged glass icon tile + grant name + status badge +
    /// action, matching design/permissions.css `.pm-grant`/`.pm-gled`.
    /// PKT-362 D1: name + status only, no DisclosureGroup verbosity.
    /// PKT-362 D3: amber LED + "Checking…" while grantCheckingState is active.
    private func permissionRow(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus
    ) -> some View {
        let isChecking = permissionManager.grantCheckingState[grant] ?? false

        return HStack(spacing: 12) {
            // LED-badged glass icon tile (.pm-gicon + .pm-gled)
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(BridgeTokens.chipFill)
                        .frame(width: 34, height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
                        )
                    Image(systemName: rowIcon(for: grant))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg2)
                }
                let dot = isChecking ? BridgeTokens.warn : statusColor(status)
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(BridgeTokens.bgRaised, lineWidth: 2))
                    .shadow(color: dot.opacity(0.7), radius: 3)
                    .offset(x: 3, y: -3)
            }
            .frame(width: 34, height: 34)

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
        // D3: Animate row transitions (checking ↔ result) with 0.3s fade
        .animation(.easeInOut(duration: 0.3), value: isChecking)
    }

    /// SF Symbol per TCC grant for the row's glass icon tile.
    private func rowIcon(for grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility:   return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .fullDiskAccess:  return "internaldrive"
        case .contacts:        return "person.crop.circle"
        case .notifications:   return "bell.badge"
        case .automation:      return "gearshape.2"
        case .reminders:       return "checklist"
        case .calendar:        return "calendar"
        }
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
            .foregroundStyle(BridgeTokens.fg3)

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
                    .foregroundStyle(capability.enabled ? BridgeTokens.accent : BridgeTokens.fg3)
            }
        }
    }

    // MARK: - D6 Restart Banner

    /// PKT-362 D6: Shows grant progress + single "Restart The Bridge" prompt.
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

            Button("Restart The Bridge") {
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
                .foregroundStyle(BridgeTokens.fg3)
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
        case .contacts, .notifications, .reminders, .calendar:
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
        case .reminders:
            let status = permissionManager.status(for: .reminders)
            Task {
                if status == .unknown {
                    _ = await permissionManager.requestRemindersAccess()
                    let resolvedStatus = permissionManager.status(for: .reminders)
                    if resolvedStatus != .granted,
                       let url = PermissionManager.Grant.reminders.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } else if let url = PermissionManager.Grant.reminders.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .calendar:
            let status = permissionManager.status(for: .calendar)
            Task {
                if status == .unknown {
                    _ = await permissionManager.requestCalendarAccess()
                    let resolvedStatus = permissionManager.status(for: .calendar)
                    if resolvedStatus != .granted,
                       let url = PermissionManager.Grant.calendar.systemSettingsURL {
                        NSWorkspace.shared.open(url)
                    }
                } else if let url = PermissionManager.Grant.calendar.systemSettingsURL {
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
