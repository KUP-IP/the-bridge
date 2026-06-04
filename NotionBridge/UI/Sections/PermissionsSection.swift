// PermissionsSection.swift — Settings → Permissions pane (v3.7.2 redesign).
// Mirrors design/design-system/project/ui_kits/the-bridge/Permissions.jsx +
// permissions.css against the approved StandingOrdersSection reference:
//   - so-hero glass header: gold orb + "X/Y granted" stat + re-check action
//   - System grants (TCC): one LED-row per grant w/ health dot, remediation
//     sub-text, "required by" dep-link chips, and an Allow/Open-Settings button
//   - Sensitive-paths editor card (delegates to existing SensitivePathsEditor)
//   - Permission management: Reset all (destructive)
//
// VIEW LAYER ONLY. Every binding is preserved verbatim: PermissionManager,
// the ForEach(PermissionManager.Grant.v1Cases) iteration, status/recheck/grant
// actions, statusBar.toolInfoList → liveTools, and the
// systemIcon()/remediation()/statusColor() helpers. Dep-link chips are derived
// live via ToolDepLinks.requiredByChips (locked decision Q1). Carbon canvas.

import SwiftUI
import AppKit

public struct PermissionsSection: View {
    let permissionManager: PermissionManager
    let liveTools: [ToolInfo]
    @Binding var isRecheckingPermissions: Bool
    @Binding var permissionActionMessage: String?
    @Binding var showTCCResetDialog: Bool
    let onResetTCC: () async -> (message: String, didFail: Bool)

    private let refreshTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    public init(
        permissionManager: PermissionManager,
        liveTools: [ToolInfo],
        isRecheckingPermissions: Binding<Bool>,
        permissionActionMessage: Binding<String?>,
        showTCCResetDialog: Binding<Bool>,
        onResetTCC: @escaping () async -> (message: String, didFail: Bool)
    ) {
        self.permissionManager = permissionManager
        self.liveTools = liveTools
        self._isRecheckingPermissions = isRecheckingPermissions
        self._permissionActionMessage = permissionActionMessage
        self._showTCCResetDialog = showTCCResetDialog
        self.onResetTCC = onResetTCC
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                grantsCard
                sensitivePathsCard
                managementCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task { await permissionManager.checkAllAsync() }
        .onReceive(refreshTimer) { _ in
            Task { await permissionManager.checkAllAsync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionManager.checkAllAsync() }
        }
        .confirmationDialog(
            "Reset all permissions for The Bridge?",
            isPresented: $showTCCResetDialog,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task {
                    let result = await onResetTCC()
                    permissionActionMessage = result.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all system permissions for The Bridge. You\u{2019}ll need to re-grant each permission after resetting.")
        }
    }

    // MARK: - Hero (so-hero: orb + stat + actions)

    private var granted: Int {
        PermissionManager.Grant.v1Cases.filter {
            permissionManager.status(for: $0) == .granted
        }.count
    }
    private var total: Int { PermissionManager.Grant.v1Cases.count }

    private var hero: some View {
        let allGood = granted == total
        return BridgeGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BridgeTokens.gold.opacity(0.20))
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(BridgeTokens.gold.opacity(0.42), lineWidth: 1))
                    Image(systemName: "lock.shield")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.gold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Permissions")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                    Text("macOS TCC grants Bridge holds. Each gates a group of tools \u{2014} revoke any and its tools go dark.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Spacer(minLength: 8)
                statTile(
                    value: "\(granted)/\(total)",
                    label: "granted",
                    color: allGood ? BridgeTokens.ok : BridgeTokens.warn
                )
                pmIconButton(
                    isRecheckingPermissions ? "hourglass" : "arrow.counterclockwise",
                    help: "Re-check all permissions"
                ) {
                    runRecheckAll()
                }
                .disabled(isRecheckingPermissions)
            }
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(BridgeTokens.fg4)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func pmIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
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

    private func runRecheckAll() {
        isRecheckingPermissions = true
        permissionActionMessage = nil
        Task {
            await permissionManager.animatedRecheckAll()
            isRecheckingPermissions = false
            permissionActionMessage = "Refreshed at \(Date().formatted(date: .omitted, time: .standard))"
        }
    }

    // MARK: - Grants card (System grants · TCC)

    private var grantsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BridgeCardLabel("System grants · TCC")
                    Spacer()
                    if let lastCheckedAt = permissionManager.lastCheckedAt {
                        Text("Last checked \(relativeTime(lastCheckedAt))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.fg4)
                    } else if isRecheckingPermissions {
                        Text("Re-checking\u{2026}")
                            .font(.system(size: 11.5))
                            .foregroundStyle(BridgeTokens.warnText)
                    }
                }
                .padding(.bottom, 4)

                ForEach(Array(PermissionManager.Grant.v1Cases.enumerated()), id: \.element.id) { idx, grant in
                    grantRow(grant: grant)
                    if idx < PermissionManager.Grant.v1Cases.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.horizontal, -2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func grantRow(grant: PermissionManager.Grant) -> some View {
        let status = permissionManager.status(for: grant)
        let isChecking = permissionManager.grantCheckingState[grant] ?? false
        let isGranted = status == .granted
        HStack(alignment: .top, spacing: 12) {
            grantIcon(grant: grant, status: status, isChecking: isChecking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(grant.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BridgeTokens.fg1)
                    statusBadge(status: status, isChecking: isChecking)
                }
                Text(remediation(for: grant))
                    .font(.system(size: 11.5))
                    .foregroundStyle(BridgeTokens.fg3)
                    .lineLimit(2)
                BridgeDepLinkRow(
                    label: "REQUIRED BY",
                    chips: ToolDepLinks.requiredByChips(
                        forGrant: grant,
                        liveTools: liveTools,
                        permissionGranted: isGranted
                    )
                )
            }
            Spacer(minLength: 8)
            if status != .granted && !isChecking {
                Button(actionLabel(grant: grant, status: status)) {
                    openSettings(for: grant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(BridgeTokens.accent)
            }
        }
        .padding(.vertical, 11)
        .animation(.easeInOut(duration: 0.3), value: isChecking)
    }

    /// LED-badged glass icon tile: emerald (granted) / amber (unknown·partial) /
    /// red (denied). The dot sits top-right with a colored glow, mirroring
    /// `.pm-gled` from permissions.css.
    @ViewBuilder
    private func grantIcon(
        grant: PermissionManager.Grant,
        status: PermissionManager.GrantStatus,
        isChecking: Bool
    ) -> some View {
        let dot = isChecking ? BridgeTokens.warn : statusColor(status)
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: systemIcon(for: grant))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.80))
            }
            Circle()
                .fill(dot)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(BridgeTokens.bgRaised, lineWidth: 2))
                .shadow(color: dot.opacity(0.7), radius: 3)
                .offset(x: 3, y: -3)
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private func statusBadge(status: PermissionManager.GrantStatus, isChecking: Bool) -> some View {
        let (text, color): (String, Color) = {
            if isChecking { return ("Checking\u{2026}", BridgeTokens.warn) }
            switch status {
            case .granted: return ("Granted", BridgeTokens.ok)
            case .denied: return ("Not granted", BridgeTokens.warn)
            case .unknown: return ("Unknown", BridgeTokens.warn)
            case .partiallyGranted: return ("Partial", BridgeTokens.warn)
            case .restartRecommended: return ("Restart needed", BridgeTokens.warn)
            }
        }()
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    private func systemIcon(for grant: PermissionManager.Grant) -> String {
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

    private func remediation(for grant: PermissionManager.Grant) -> String {
        switch grant {
        case .accessibility:   return "Required for AX automation + global hotkey delivery."
        case .screenRecording: return "For screen capture + OCR tools."
        case .fullDiskAccess:  return "Read protected paths (~/Library, ~/Documents)."
        case .contacts:        return "Resolve handles in messages + relationship tools."
        case .notifications:   return "Bridge alerts in the menu bar + Notification Center."
        case .automation:      return "AppleEvents for cross-app automation."
        case .reminders:       return "List, create, and complete iCloud Reminders."
        case .calendar:        return "Read and create calendar events."
        }
    }

    /// LED health-dot color per status — emerald granted / amber unknown·partial·
    /// restart / red denied. Mirrors PermissionView.statusColor logic + the
    /// `.pm-gled` tones in permissions.css.
    private func statusColor(_ status: PermissionManager.GrantStatus) -> Color {
        switch status {
        case .granted:            return BridgeTokens.ok
        case .denied:             return BridgeTokens.bad
        case .unknown:            return BridgeTokens.warn
        case .partiallyGranted:   return BridgeTokens.warn
        case .restartRecommended: return BridgeTokens.warn
        }
    }

    private func actionLabel(grant: PermissionManager.Grant, status: PermissionManager.GrantStatus) -> String {
        switch grant {
        case .automation, .fullDiskAccess: return "Open Settings"
        case .contacts, .notifications, .reminders, .calendar: return status == .unknown ? "Allow" : "Open Settings"
        case .accessibility, .screenRecording: return "Allow"
        }
    }

    private func openSettings(for grant: PermissionManager.Grant) {
        // PKT-876: defer to live PermissionManager APIs for behavior parity.
        // Mirrors PermissionView.openSystemSettings.
        switch grant {
        case .accessibility:
            _ = permissionManager.requestAccessibilityAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .automation:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
            Task { await permissionManager.recheckAllForTruth() }
        case .notifications:
            Task {
                _ = await permissionManager.requestNotificationAccess()
                if permissionManager.status(for: .notifications) != .granted,
                   let url = PermissionManager.Grant.notifications.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .contacts:
            Task {
                _ = await permissionManager.requestContactsAccess()
                if permissionManager.status(for: .contacts) != .granted,
                   let url = PermissionManager.Grant.contacts.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .reminders:
            Task {
                _ = await permissionManager.requestRemindersAccess()
                if permissionManager.status(for: .reminders) != .granted,
                   let url = PermissionManager.Grant.reminders.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .calendar:
            Task {
                _ = await permissionManager.requestCalendarAccess()
                if permissionManager.status(for: .calendar) != .granted,
                   let url = PermissionManager.Grant.calendar.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                await permissionManager.recheckAllForTruth()
            }
        case .screenRecording:
            _ = permissionManager.requestScreenRecordingAccess()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await permissionManager.recheckAllForTruth()
            }
        case .fullDiskAccess:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
            Task { await permissionManager.recheckAllForTruth() }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    // MARK: - Sensitive paths card

    private var sensitivePathsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("Sensitive paths")
                    Spacer()
                    Text("Enforced by file tools")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                }
                SensitivePathsEditor()
            }
        }
    }

    // MARK: - Management card

    private var managementCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                BridgeCardLabel("Permission management")
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        showTCCResetDialog = true
                    } label: {
                        Label("Reset all permissions", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(BridgeTokens.bad)
                    Spacer()
                }
                if let msg = permissionActionMessage {
                    Text(msg)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg3)
                }
                Text("Reset clears Bridge\u{2019}s TCC grants so macOS re-prompts on next use.")
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
            }
        }
    }
}
