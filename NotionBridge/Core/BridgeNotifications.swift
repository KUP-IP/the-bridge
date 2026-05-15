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

    // MARK: - Cursor agent surface (PKT-3.4.2)

    /// Posted when a Cursor agent run state changes (start, status update, completion, failure, cancel).
    /// Observers: menu bar pill (recount), Dashboard Agents surface (reload row), notification dispatcher.
    /// userInfo: ["runId": String, "status": String (CursorRunStatus.rawValue)].
    static let cursorAgentStateDidChange = Notification.Name("com.notionbridge.cursorAgentStateDidChange")

    /// Posted when the daily cost ledger crosses a soft or hard cap threshold.
    /// userInfo: ["tier": "soft"|"hard", "totalCents": Int, "thresholdCents": Int, "dateLocal": String].
    /// Observers: Dashboard banner, notification dispatcher (CURSOR_AGENT_NEEDS_APPROVAL or auto-pause).
    static let cursorAgentCostCapTripped = Notification.Name("com.notionbridge.cursorAgentCostCapTripped")

    /// Posted when the heartbeat watchdog escalates a run (no SSE event for N→yellow / 2N→red).
    /// userInfo: ["runId": String, "level": "yellow"|"red", "silentForSeconds": Int].
    /// At "red" level, dispatcher emits the CURSOR_AGENT_STALLED user notification.
    static let cursorAgentDidStall = Notification.Name("com.notionbridge.cursorAgentDidStall")

    /// Posted for every CursorEvent received from the sidecar (PKT-3.4.1-RESCUE).
    /// userInfo: ["runId": String, "kind": String, "eventId": String,
    ///            "timestamp": String, "payload": [String: String]].
    /// Observers: Dashboard agents surface (live token stream), heartbeat watchdog (reset).
    static let cursorAgentEventReceived = Notification.Name("com.notionbridge.cursorAgentEventReceived")
}
