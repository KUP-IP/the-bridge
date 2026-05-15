// BridgeNotifications.swift — Shared Notification.Name constants
// NotionBridge · Core
//
// Centralizes notification names used across Security, Server, and UI layers.
// Previously defined in SettingsWindow.swift (UI) but posted from SecurityGate (Security).

import Foundation

public extension Notification.Name {
    /// Reset onboarding wizard state (PKT-349 B2).
    static let resetOnboarding = Notification.Name("com.notionbridge.resetOnboarding")

    /// Credentials feature toggle changed (enable/disable Keychain tools).
    static let notionBridgeCredentialsFeatureDidChange = Notification.Name("com.notionbridge.credentialsFeatureDidChange")

    /// Posted when `com.notionbridge.tierOverrides` changes (e.g. Request-tier **Always Allow** → notify).
    static let notionBridgeTierOverridesDidChange = Notification.Name("com.notionbridge.tierOverridesDidChange")

    /// Remote access config changed (tunnel URL saved or bearer token generated/cleared).
    /// Observers should invalidate active MCP sessions and rebuild validation pipelines.
    static let remoteAccessConfigDidChange = Notification.Name("com.notionbridge.remoteAccessConfigDidChange")

    /// Posted after any job mutation (create, delete, pause, resume, update, import) so the Jobs UI can reload.
    static let jobsDidChange = Notification.Name("com.notionbridge.jobsDidChange")

}
