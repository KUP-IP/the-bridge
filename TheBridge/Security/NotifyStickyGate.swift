// NotifyStickyGate.swift — persist Notify only on explicit Always Allow
// TheBridge · Security
//
// #264 LIVE FAIL on installed b8045b61 (PR #271): clean-prefs
// `standing_orders_delete` rewrote `tierOverrides` + `moduleTierOverrides`
// to notify without an Always Allow tap. PR #271 refused unique-foreground
// ALWAYS_ALLOW, then removed `.foreground` so the live category classified
// as `.notificationAlwaysAllow` (explicit persist). Time Sensitive +
// LSUIElement activate still invoked ALWAYS_ALLOW with no tap → persist
// + surface clear → Confirm gone (`windows=0`).
//
// UN cannot prove a tap. Banner ALWAYS_ALLOW is implicit. Persist only
// from Confirm-surface tap (`.confirmSurface`) or the gate's explicit
// `.alwaysAllow` provider return (`.requestApproval`).

import Foundation
import UserNotifications

/// Compact-banner action + options used by `registerCategories` and tests.
public struct ConfirmBannerActionSpec: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let options: UNNotificationActionOptions

    public init(identifier: String, title: String, options: UNNotificationActionOptions) {
        self.identifier = identifier
        self.title = title
        self.options = options
    }
}

/// Persist eligibility + unique-foreground detection for Confirm stickies.
public enum NotifyStickyGate {
    public static let alwaysAllowActionIdentifier = "ALWAYS_ALLOW"
    public static let allowActionIdentifier = "ALLOW_ACTION"
    public static let cancelActionIdentifier = "CANCEL_ACTION"

    /// Sources that may write per-tool + module Notify.
    /// UN / Time Sensitive / default-button / pending escalate never qualify.
    public static func allowsPersist(source: NotifyStickyDecisionSource) -> Bool {
        switch source {
        case .confirmSurface, .requestApproval:
            return true
        case .notificationAlwaysAllow, .implicitForeground, .pendingEscalate, .defaultButton:
            return false
        }
    }

    public static func uniqueForegroundActionIdentifier(
        actions: [ConfirmBannerActionSpec]
    ) -> String? {
        let ids = actions.filter { $0.options.contains(.foreground) }.map(\.identifier)
        return ids.count == 1 ? ids[0] : nil
    }

    /// PR #269 layout that caused the first LIVE sticky rewrite.
    public static var pr269UniqueForegroundLayout: [ConfirmBannerActionSpec] {
        [
            ConfirmBannerActionSpec(
                identifier: allowActionIdentifier,
                title: "Allow",
                options: []
            ),
            ConfirmBannerActionSpec(
                identifier: alwaysAllowActionIdentifier,
                title: "Always Allow",
                options: [.authenticationRequired, .foreground]
            ),
            ConfirmBannerActionSpec(
                identifier: cancelActionIdentifier,
                title: "Cancel",
                options: [.destructive]
            ),
        ]
    }

    /// Classify a UN action. Banner ALWAYS_ALLOW is never a proven tap —
    /// unique-foreground or not (LIVE on b8045b61 after unique-foreground
    /// was removed).
    public static func sourceForNotificationAction(
        identifier: String,
        categoryActions: [ConfirmBannerActionSpec]
    ) -> NotifyStickyDecisionSource? {
        guard identifier == alwaysAllowActionIdentifier else { return nil }
        _ = categoryActions
        return .implicitForeground
    }
}
