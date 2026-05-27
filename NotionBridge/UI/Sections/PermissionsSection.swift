// PermissionsSection.swift — Liquid Glass reskin of Settings → Permissions.
// PKT-876 v3.6.1. Per design/permissions.html:
//   - Glass-hero header with "X of Y granted" pill
//   - System grants (TCC) — one glass row per grant w/ "Required by" chips
//   - Sensitive paths card (delegates to existing SensitivePathsEditor)
//   - Permission management actions (Re-check, Reset)
//
// Dep-link chips ("required by") are derived from the live ToolInfo list
// via ToolDepLinks.requiredByChips at render time (locked decision Q1).

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
                header
                grantsCard
                sensitivePathsCard
                managementCard
            }
            .padding(18)
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

    // MARK: - Header

    private var header: some View {
        let spec = BridgeSettingsHeaderPreset.spec(for: .permissions)
        let granted = PermissionManager.Grant.v1Cases.filter {
            permissionManager.status(for: $0) == .granted
        }.count
        let total = PermissionManager.Grant.v1Cases.count
        return BridgeSettingsSectionHeader(
            title: spec.title,
            subtitle: spec.subtitle,
            systemImage: spec.systemImage,
            tint: spec.tint
        ) {
            grantTotalsPill(granted: granted, total: total)
        }
    }

    @ViewBuilder
    private func grantTotalsPill(granted: Int, total: Int) -> some View {
        let allGood = granted == total
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(granted) / \(total)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(allGood ? Color.green : Color.orange)
            Text("granted")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grants card

    private var grantsCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BridgeCardLabel("System grants (TCC)")
                    Spacer()
                    Button(isRecheckingPermissions ? "Re-checking\u{2026}" : "Re-check all") {
                        isRecheckingPermissions = true
                        permissionActionMessage = nil
                        Task {
                            await permissionManager.animatedRecheckAll()
                            isRecheckingPermissions = false
                            permissionActionMessage = "Refreshed at \(Date().formatted(date: .omitted, time: .standard))"
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRecheckingPermissions)
                }
                ForEach(Array(PermissionManager.Grant.v1Cases.enumerated()), id: \.element.id) { idx, grant in
                    grantRow(grant: grant)
                    if idx < PermissionManager.Grant.v1Cases.count - 1 {
                        Divider().background(Color.white.opacity(0.08))
                    }
                }
                if let lastCheckedAt = permissionManager.lastCheckedAt {
                    HStack {
                        Spacer()
                        Text("Last checked \(relativeTime(lastCheckedAt))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
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
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                Image(systemName: systemIcon(for: grant))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(grant.displayName)
                    .font(.system(size: 13.5))
                Text(remediation(for: grant))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Spacer()
            statusBadge(status: status, isChecking: isChecking)
            if status != .granted && !isChecking {
                Button(actionLabel(grant: grant, status: status)) {
                    openSettings(for: grant)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(status: PermissionManager.GrantStatus, isChecking: Bool) -> some View {
        let (text, color): (String, Color) = {
            if isChecking { return ("Checking\u{2026}", Color.yellow) }
            switch status {
            case .granted: return ("Granted", Color.green)
            case .denied: return ("Not granted", Color.orange)
            case .unknown: return ("Unknown", Color.orange)
            case .partiallyGranted: return ("Partial", Color.orange)
            case .restartRecommended: return ("Restart needed", Color.orange)
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
        }
    }

    private func actionLabel(grant: PermissionManager.Grant, status: PermissionManager.GrantStatus) -> String {
        switch grant {
        case .automation, .fullDiskAccess: return "Open Settings"
        case .contacts, .notifications:    return status == .unknown ? "Allow" : "Open Settings"
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
                    Text("Protected by file tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Spacer()
                }
                if let msg = permissionActionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Reset clears Bridge\u{2019}s TCC grants so macOS re-prompts on next use.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
