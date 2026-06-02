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

    /// PKT-879 (v3.6.4): posted when the onboarding wizard completes its
    /// final step. Observers (AppDelegate) bring attention to the menu
    /// bar so the user lands in the Dashboard popover, not raw Settings.
    static let onboardingDidComplete = Notification.Name("com.notionbridge.onboardingDidComplete")

    /// WS-F: posted by `AppDelegate.application(_:open:options:)` after a
    /// `bridge-auth://callback` URL is handled — the auth code has been
    /// exchanged for a WorkOS token and persisted to the Keychain. The
    /// in-flight `EnableCloudAccessFlow` observes this to advance from
    /// `.signingIn` to `.provisioning`. The `userInfo` carries no secret
    /// material — only a `success: Bool` under `cloudAuthSuccessKey`.
    static let cloudAuthCallbackReceived = Notification.Name("com.notionbridge.cloudAuthCallbackReceived")
}

/// `userInfo` key on `.cloudAuthCallbackReceived` carrying whether the code
/// exchange succeeded (`Bool`). Never carries the token itself.
public let cloudAuthSuccessKey = "success"
