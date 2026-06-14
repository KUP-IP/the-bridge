// PermissionsSection.swift — Security · Gates tab body (Settings-Redesign PKT-security).
//
// This is the **Gates** tab inside the merged Security page. The bespoke
// `SecuritySection` composite owns the single posture header (replacing this
// file's old gold orb-hero) and the tab bar; this view is hero-less and renders
// the access gates that govern what tools can do:
//   1. **Always-Allow grants** — module-scoped `moduleTierOverrides` (the literal
//      "Always Allow"), each with its tier chip + a Revoke affordance that clears
//      the grant so the module's tools fall back to their registered defaults.
//      (Per-tool tiers are owned by the Tools page; the posture header shows their
//      counts read-only with a "Manage in Tools" link — NOT duplicated here.)
//   2. **System access (TCC)** — the re-homed macOS grants: one LED-row per grant
//      w/ health dot, remediation, "required by" dep chips, Allow/Open-Settings;
//      the sensitive-paths editor; and the destructive "Reset all permissions".
//
// VIEW LAYER ONLY. Every TCC binding is preserved verbatim: PermissionManager,
// the ForEach(PermissionManager.Grant.v1Cases) iteration, status/recheck/grant
// actions, statusBar.toolInfoList → liveTools, and the
// systemIcon()/remediation()/statusColor() helpers. Dep-link chips are derived
// live via ToolDepLinks.requiredByChips. The Always-Allow grants read/write the
// SAME `BridgeDefaults.moduleTierOverrides` the router + Tools use (revoke posts
// `.notionBridgeTierOverridesDidChange`) — no fork of the tier model.

import SwiftUI
import AppKit

public struct PermissionsSection: View {
    let permissionManager: PermissionManager
    let liveTools: [ToolInfo]
    @Binding var isRecheckingPermissions: Bool
    @Binding var permissionActionMessage: String?
    @Binding var showTCCResetDialog: Bool
    let onResetTCC: () async -> (message: String, didFail: Bool)

    /// Per-module "Always Allow" grants (BridgeDefaults.moduleTierOverrides) —
    /// the SAME store the router + Tools read. Seeded from defaults; refreshed on
    /// the tier-change notification so a grant added/revoked elsewhere reflects here.
    @State private var moduleGrants: [String: String] =
        (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]

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
            VStack(spacing: BridgeSpacing.sm) {
                alwaysAllowCard
                systemAccessLabel
                grantsCard
                sensitivePathsCard
                managementCard
            }
            .padding(BridgeTokens.Space.paneH)
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
        .onReceive(NotificationCenter.default.publisher(for: .notionBridgeTierOverridesDidChange)) { _ in
            reloadGrants()
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

    // MARK: - Always-Allow grants (module-scoped, the literal "Always Allow")

    private var granted: Int {
        PermissionManager.Grant.v1Cases.filter {
            permissionManager.status(for: $0) == .granted
        }.count
    }
    private var total: Int { PermissionManager.Grant.v1Cases.count }

    /// Module ids that currently hold an Always-Allow grant whose value parses to
    /// a real `SecurityTier` — sorted for a stable list.
    private var activeGrantModules: [String] {
        moduleGrants.compactMap { (module, raw) in
            SecurityTier(rawValue: raw) != nil ? module : nil
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var alwaysAllowCard: some View {
        BridgeGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BridgeCardLabel("Always-Allow grants")
                    Spacer()
                    BridgeDepLink("MANAGE IN TOOLS", variant: .info) {
                        SettingsNavigation.shared.go(.tools)
                    }
                    .accessibilityLabel("Manage per-tool gates in Tools")
                }
                if activeGrantModules.isEmpty {
                    // Design source: a centered "No standing grants" empty state.
                    BridgeEmptyStateView(
                        systemImage: "checkmark.shield",
                        title: "No standing grants",
                        message: "No module is set to Always-Allow. Tools follow their per-tool gates (Open · Notify · Confirm), which you manage on the Tools page."
                    )
                } else {
                    Text("These modules skip the gate prompt — every tool in the module is auto-approved at the granted tier. Revoke to return its tools to their per-tool gates.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BridgeTokens.fg4)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 6) {
                        ForEach(activeGrantModules, id: \.self) { module in
                            grantModuleRow(module)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func grantModuleRow(_ module: String) -> some View {
        let tierRaw = moduleGrants[module] ?? ""
        let tier = SecurityTier(rawValue: tierRaw) ?? .notify
        // SecurityTier rawValues (open/notify/request) round-trip with BridgeTier.
        let pillTier = BridgeTier(rawValue: tier.rawValue) ?? .notify
        let toolCount = liveTools.filter { ModuleGroupDerivation.resolve(toolName: $0.name).displayName == module }.count
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 12) {
            moduleIcon(module)
            VStack(alignment: .leading, spacing: 2) {
                Text(module)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(BridgeTokens.fg1)
                Text(toolCount == 1 ? "1 tool auto-approved" : "\(toolCount) tools auto-approved")
                    .font(.system(size: 11))
                    .foregroundStyle(BridgeTokens.fg4)
            }
            Spacer(minLength: 8)
            // W2 `.tier-pill` — read-only tier indicator (open=emerald · notify=
            // accent · confirm=amber). The Always-Allow tier is shown, not edited.
            BridgeTierPill(pillTier)
                .accessibilityLabel("Always-Allow tier: \(pillTier.label.lowercased())")
            revokeButton(module)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        // Recessed well per the design source (var(--well) + faint hairline).
        .background(
            shape.fill(BridgeTokens.wellFill)
                .overlay(shape.strokeBorder(BridgeTokens.hairlineFaint, lineWidth: 0.5))
        )
    }

    /// Danger-tinted Revoke pill (W1 bad signal tokens) — clears the grant so the
    /// module's tools fall back to their per-tool gates.
    @ViewBuilder
    private func revokeButton(_ module: String) -> some View {
        Button {
            revokeGrant(module)
        } label: {
            Text("Revoke")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BridgeTokens.badText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(BridgeTokens.bad.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(BridgeTokens.bad.opacity(0.30), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Revoke the Always-Allow grant for \(module) — its tools return to their per-tool gates")
        .accessibilityLabel("Revoke Always-Allow for \(module)")
    }

    @ViewBuilder
    private func moduleIcon(_ module: String) -> some View {
        let symbol = ModuleGroupID(rawValue: module)?.systemImage
            ?? ModuleGroupID.allCases.first(where: { $0.displayName == module })?.systemImage
            ?? "shippingbox"
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(BridgeTokens.chipFill)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
                )
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(BridgeTokens.fg2)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func revokeGrant(_ module: String) {
        moduleGrants.removeValue(forKey: module)
        UserDefaults.standard.set(moduleGrants, forKey: BridgeDefaults.moduleTierOverrides)
        NotificationCenter.default.post(name: .notionBridgeTierOverridesDidChange, object: nil)
    }

    private func reloadGrants() {
        moduleGrants = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides) as? [String: String]) ?? [:]
    }

    // MARK: - System access (TCC) — re-homed section label

    private var systemAccessLabel: some View {
        HStack(spacing: 8) {
            Text("SYSTEM ACCESS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(BridgeTokens.fg4)
            Text("\(granted)/\(total) granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted == total ? BridgeTokens.okText : BridgeTokens.warnText)
            Spacer()
            recheckButton
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var recheckButton: some View {
        Button {
            runRecheckAll()
        } label: {
            HStack(spacing: 4) {
                if isRecheckingPermissions {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold))
                }
                Text("Re-check").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(BridgeTokens.fg2)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(BridgeTokens.chipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(BridgeTokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isRecheckingPermissions)
        .help("Re-check all macOS system-access grants")
        .accessibilityLabel("Re-check all system permissions")
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
                    BridgeCardLabel("TCC grants")
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
                            .fill(BridgeTokens.hairline)
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
                let label = actionLabel(grant: grant, status: status)
                // Design grammar: an "Allow" affordance is the primary blue CTA;
                // "Open Settings" is the neutral raised-glass default.
                BridgeButton(
                    label,
                    variant: label == "Allow" ? .primary : .default
                ) {
                    openSettings(for: grant)
                }
                .accessibilityLabel("\(label) — \(grant.displayName)")
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
                    .fill(BridgeTokens.chipFill)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(BridgeTokens.hairline, lineWidth: 0.5)
                    )
                Image(systemName: systemIcon(for: grant))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BridgeTokens.fg2)
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

    /// Inline status badge — a W2 signal dot + label. Granted=emerald, denied=red,
    /// checking/unknown/partial/restart=amber (the design's `.badge` + `.dot`).
    @ViewBuilder
    private func statusBadge(status: PermissionManager.GrantStatus, isChecking: Bool) -> some View {
        let (text, signal): (String, BridgeSignal) = {
            if isChecking { return ("Checking\u{2026}", .warn) }
            switch status {
            case .granted: return ("Granted", .ok)
            case .denied: return ("Not granted", .bad)
            case .unknown: return ("Unknown", .warn)
            case .partiallyGranted: return ("Partial", .warn)
            case .restartRecommended: return ("Restart needed", .warn)
            }
        }()
        HStack(spacing: 5) {
            BridgeStatusDot(signal, size: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(signal.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
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
                    BridgeButton(
                        "Reset all permissions",
                        systemImage: "arrow.counterclockwise",
                        variant: .danger
                    ) {
                        showTCCResetDialog = true
                    }
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
