// BridgeNotificationDeepLink.swift — userInfo keys for notification tap → Settings
// TheBridge · Modules · PKT-MEM-104

import Foundation

/// Keys written into `UNNotificationContent.userInfo` so `NotificationApprovalManager`
/// can open a Settings section when the operator taps the banner.
public enum BridgeNotificationDeepLink {
    public static let settingsSectionKey = "bridgeSettingsSection"
    public static let settingsAnchorKey = "bridgeSettingsAnchor"

    public static func userInfo(section: String, anchor: String?) -> [String: Any] {
        var info: [String: Any] = [settingsSectionKey: section]
        if let anchor, !anchor.isEmpty { info[settingsAnchorKey] = anchor }
        return info
    }
}
