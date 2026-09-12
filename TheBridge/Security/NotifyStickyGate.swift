// NotifyStickyGate.swift — persist Notify only on explicit Always Allow
// TheBridge · Security
//
// #264 LIVE FAIL on installed 2bd375aa (PR #269): clean-prefs
// `standing_orders_delete` rewrote `tierOverrides` + `moduleTierOverrides`
// to notify without an Always Allow tap. PR #269 added
// `.foreground` + `.authenticationRequired` on `ALWAYS_ALLOW` so a
// "silent background" action could not persist. That made ALWAYS_ALLOW
// the **unique foreground** category action. Time Sensitive delivery +
// LSUIElement activation then invoked it (no tap) → persist + surface
// clear → Confirm gone (`windows=0`).
//
// This gate is the hermetic sticky contract. `persistNotifySticky` refuses
// implicit / escalate / default-button sources even if a caller passes them.

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
    public static func allowsPersist(source: NotifyStickyDecisionSource) -> Bool {
        switch source {
        case .confirmSurface, .notificationAlwaysAllow, .requestApproval:
            return true
        case .implicitForeground, .pendingEscalate, .defaultButton:
            return false
        }
    }

    public static func uniqueForegroundActionIdentifier(
        actions: [ConfirmBannerActionSpec]
    ) -> String? {
        let ids = actions.filter { $0.options.contains(.foreground) }.map(\.identifier)
        return ids.count == 1 ? ids[0] : nil
    }

    /// PR #269 layout that caused the LIVE sticky rewrite.
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

    /// Classify a UN action. Unique-foreground ALWAYS_ALLOW is implicit.
    public static func sourceForNotificationAction(
        identifier: String,
        categoryActions: [ConfirmBannerActionSpec]
    ) -> NotifyStickyDecisionSource? {
        guard identifier == alwaysAllowActionIdentifier else { return nil }
        if uniqueForegroundActionIdentifier(actions: categoryActions)
            == alwaysAllowActionIdentifier {
            return .implicitForeground
        }
        return .notificationAlwaysAllow
    }
}
