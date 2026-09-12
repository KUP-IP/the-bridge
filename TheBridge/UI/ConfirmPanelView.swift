// ConfirmPanelView.swift — sticky Confirm body (Deny / Allow / Always Allow)
// TheBridge · UI
//
// Hosted in a dedicated NSPanel (`ConfirmPanelController`) so LSUIElement
// MenuBarExtra popover failure cannot hide the actions. Same submit path
// as the SECURITY_APPROVAL notification (`PendingApprovalSurface.submit`).
//
// #262: Always Allow is the visual primary (full-width + hint). It is not
// the keyboard default — #264 / PR #267 owns Return-key / compact-banner
// ordering. Dashboard uses the same card stack under a louder section header.

import SwiftUI

/// Visual-primary Always Allow that is **not** a SwiftUI `Button`.
/// The first `Button` in an NSHostingController becomes AppKit's
/// default button after layout; a Return / Focus / activate misfire
/// then persisted notify stickies without an Always Allow tap (#264).
public struct ConfirmAlwaysAllowControl: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Text(ConfirmPresentation.alwaysAllowTitle)
            .font(BridgeTokens.Typeface.base600)
            .foregroundStyle(BridgeTokens.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BridgeTokens.accent)
            )
            .contentShape(Rectangle())
            .onTapGesture { action() }
            // Do not add `.isButton` — AppKit promotes the first accessibility
            // button to `defaultButtonCell` after layout and can performClick
            // it on LSUIElement activate (#264 LIVE).
            .accessibilityAction(named: Text(ConfirmPresentation.alwaysAllowTitle)) {
                action()
            }
            .accessibilityIdentifier("confirm-always-allow")
            .accessibilityLabel(ConfirmPresentation.alwaysAllowTitle)
    }
}

/// Shared Confirm cards — Dashboard popover and the sticky panel.
public struct ConfirmCardStack: View {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(prompts) { prompt in
                ConfirmCard(prompt: prompt)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-panel-body")
    }
}

/// Dashboard / Security Confirm section chrome — hierarchy so Always Allow
/// is not a quiet chip under the header.
public struct ConfirmDashboardSection: View {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BridgeTokens.warnText)
                Text(ConfirmDelivery.dashboardSectionTitle)
                    .font(BridgeTokens.Typeface.body.weight(.semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text("\(prompts.count)")
                    .font(BridgeTokens.Typeface.micro.weight(.bold).monospaced())
                    .foregroundStyle(BridgeTokens.warnText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(BridgeTokens.warn.opacity(0.22))
                    )
                    .accessibilityLabel("\(prompts.count) waiting")
            }
            ConfirmCardStack(prompts: prompts)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-dashboard-section")
        .accessibilityLabel(ConfirmDelivery.dashboardSectionTitle)
    }
}

public struct ConfirmCard: View {
    let prompt: PendingApprovalPrompt

    public init(prompt: PendingApprovalPrompt) {
        self.prompt = prompt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BridgeTokens.warnText)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Confirm")
                            .font(BridgeTokens.Typeface.micro.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                        if prompt.origin == .remote {
                            Text("remote")
                                .font(BridgeTokens.Typeface.micro.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(BridgeTokens.warnText)
                        }
                    }
                    Text(prompt.toolName)
                        .font(BridgeTokens.Typeface.body.weight(.semibold))
                        .foregroundStyle(BridgeTokens.fg1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .foregroundStyle(BridgeTokens.warnText)
            Text(prompt.title)
                .font(BridgeTokens.Typeface.sub.weight(.semibold))
                .foregroundStyle(BridgeTokens.fg1)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.body)
                .font(BridgeTokens.Typeface.micro.monospaced())
                .foregroundStyle(BridgeTokens.fg3)
                .lineLimit(4)
            if prompt.allowAlwaysAllow {
                VStack(alignment: .leading, spacing: 4) {
                    ConfirmAlwaysAllowControl {
                        PendingApprovalSurface.shared.submit(id: prompt.id, decision: .alwaysAllow)
                    }
                    Text(ConfirmDelivery.alwaysAllowHint)
                        .font(BridgeTokens.Typeface.micro)
                        .foregroundStyle(BridgeTokens.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("confirm-always-allow-hint")
                }
            }
            HStack(spacing: 8) {
                BridgeButton(ConfirmPresentation.denyTitle, variant: .danger) {
                    PendingApprovalSurface.shared.submit(id: prompt.id, decision: .deny)
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("confirm-deny")
                BridgeButton(ConfirmPresentation.allowTitle) {
                    PendingApprovalSurface.shared.submit(id: prompt.id, decision: .allow)
                }
                .accessibilityIdentifier("confirm-allow")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(BridgeTokens.warn.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(BridgeTokens.warn.opacity(0.55), lineWidth: 1.5)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(BridgeTokens.warn)
                .frame(width: 4)
                .padding(.vertical, 10)
                .padding(.leading, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm \(prompt.toolName)")
    }
}

/// Standalone Confirm window contents (no Dashboard chrome).
public struct ConfirmPanelView: View {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(BridgeTokens.warnText)
                Text(ConfirmDelivery.panelHeadline)
                    .font(BridgeTokens.Typeface.body.weight(.semibold))
                    .foregroundStyle(BridgeTokens.fg1)
                    .accessibilityAddTraits(.isHeader)
            }
            ConfirmCardStack(prompts: prompts)
        }
        .padding(16)
        .frame(width: 400)
        .background(BridgeTokens.bgCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("confirm-panel")
        .accessibilityLabel(ConfirmDelivery.panelHeadline)
    }
}
