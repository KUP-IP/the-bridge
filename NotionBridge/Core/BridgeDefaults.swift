// BridgeDefaults.swift — Shared UserDefaults key constants
// NotionBridge · Core
//
// Centralizes UserDefaults keys used across multiple files.
// Prevents silent key-mismatch bugs from typos in raw string literals.

import Foundation

/// Canonical UserDefaults keys shared across Security, Server, UI, and Module layers.
public enum BridgeDefaults {
    // MARK: - Tool & Security Configuration

    /// Per-tool tier overrides (Open/Notify/Request). Dictionary<String, String>.
    /// Written by SecurityGate (Always Allow), read by ToolRouter and ToolRegistryView.
    public static let tierOverrides = "com.notionbridge.tierOverrides"

    /// User-disabled tool names. Array<String>.
    /// Written by ToolRegistryView, read by CredentialsFeature and ListTools handlers.
    public static let disabledTools = "com.notionbridge.disabledTools"

    // MARK: - Skills

    /// Encoded skills list. Data (JSON-encoded [Skill]).
    /// Written by SkillsManager and SkillsModule, read at startup.
    public static let skills = "com.notionbridge.skills"

    // MARK: - Commands Palette (cmd-ux)

    /// Master on/off for the Commands palette (global-hotkey command box).
    /// Bool. Written by Settings → Commands, read by `CommandsPaletteGate`.
    /// ABSENT ⇒ ON (default-enabled): the gate treats a missing key as
    /// `true` so a fresh install gets the palette without any opt-in. An
    /// explicit `BRIDGE_ENABLE_COMMANDS` env var still overrides this pref.
    public static let commandsPaletteEnabled = "com.notionbridge.commandsPaletteEnabled"

    // MARK: - Onboarding & Legal

    /// Whether the user has completed the onboarding wizard. Bool.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Whether the user has accepted legal terms. Bool.
    public static let hasAcceptedLegalTerms = "hasAcceptedLegalTerms"
}
