// BridgeNotifications.swift — Shared Notification.Name constants
// TheBridge · Core
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

    /// Retired issue #126 send-only mode notification. Nothing posts or observes
    /// this after `messages_send` returned to the ordinary 3-tier ladder.
    static let messagesSendApprovalModeDidChange = Notification.Name("com.notionbridge.messagesSendApprovalModeDidChange")

    /// Remote access config changed (tunnel URL saved or bearer token generated/cleared).
    /// Observers should invalidate active MCP sessions and rebuild validation pipelines.
    static let remoteAccessConfigDidChange = Notification.Name("com.notionbridge.remoteAccessConfigDidChange")

    /// Settings requested a local governed-session rebind. Carries no token or
    /// session material; AppDelegate routes it to the live ServerManager.
    static let bridgeConnectionResetRequested = Notification.Name("com.notionbridge.bridgeConnectionResetRequested")


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

    /// WS-D (PKT-921): posted when `BridgeDefaults.cloudAccessEnabled` flips
    /// (the Enable flow reached `.connected` → ON, or reverted to OFF on
    /// failure/cancel). `AppDelegate` observes this to start/stop the cloud
    /// health heartbeat + register/deregister the `bridge_status` MCP tool on
    /// the running `ServerManager` WITHOUT a relaunch. The `userInfo` carries
    /// the new boolean under `cloudAccessEnabledKey`.
    static let cloudAccessEnabledDidChange = Notification.Name("com.notionbridge.cloudAccessEnabledDidChange")

    /// In-flight Request-tier Confirm prompts changed (posted / resolved).
    /// Dashboard, menu-bar badge, and Security ATTENTION refresh from this.
    static let pendingApprovalSurfaceDidChange = Notification.Name("com.notionbridge.pendingApprovalSurfaceDidChange")

    /// Operator tapped Allow / Always Allow / Deny on the menu-bar Confirm card.
    /// `NotificationApprovalManager` resumes the same path as SECURITY_APPROVAL.
    static let pendingApprovalSurfaceSubmit = Notification.Name("com.notionbridge.pendingApprovalSurfaceSubmit")

    /// Banner tap / swipe-away / ATTENTION click — present the Confirm body
    /// without resolving. Observers (AppDelegate) show the sticky panel.
    static let pendingApprovalSurfacePresentBody = Notification.Name("com.notionbridge.pendingApprovalSurfacePresentBody")

    /// Confirm NSPanel presented or ordered out. `WindowTracker` re-evaluates
    /// accessory vs regular — `orderOut` does not fire `willClose`.
    static let confirmPanelDidChange = Notification.Name("com.notionbridge.confirmPanelDidChange")
}

/// `userInfo` key on `.cloudAccessEnabledDidChange` carrying the new
/// enabled-state (`Bool`).
public let cloudAccessEnabledKey = "enabled"

/// `userInfo` key on `.cloudAuthCallbackReceived` carrying whether the code
/// exchange succeeded (`Bool`). Never carries the token itself.
public let cloudAuthSuccessKey = "success"
