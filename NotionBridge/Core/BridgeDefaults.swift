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

    /// v3.6.0 D6: per-ModuleGroup expand/collapse state on the Tools page.
    /// Dictionary<String /* group raw id */, Bool>. Missing entry: collapsed
    /// (the v3.6.0 default — was "expanded if any tool in the group is on",
    /// which became a wall-of-toggles for users with most groups enabled).
    /// Written by ModuleGroupCard on user toggle; read at view construction.
    public static let moduleGroupExpanded = "com.notionbridge.moduleGroupExpanded"

    // MARK: - Skills

    /// Encoded skills list. Data (JSON-encoded [Skill]).
    /// Written by SkillsManager and SkillsModule, read at startup.
    public static let skills = "com.notionbridge.skills"

    /// W2 D7: per-path enable state for file-source skills (SKILL.md
    /// files in `Bundle.module/skills/` or the user dir). The .md file
    /// itself is read-only here — toggling never mutates it. Value is a
    /// Dictionary<String /* absolute file path */, Bool>. Missing entry
    /// → enabled by default.
    public static let fileSkillEnabled = "com.notionbridge.fileSkillEnabled"

    /// W4 (3.4.1): per-path flag-based visibility for file-source skills,
    /// mirroring `routingDiscoverable` on the Skill struct. Dictionary
    /// <String /* absolute file path */, Bool>. Missing entry: the
    /// default is derived from the SKILL.md frontmatter (`visibility:
    /// routing` → true, anything else → false); explicit toggles win.
    public static let fileSkillRoutingDiscoverable = "com.notionbridge.fileSkillRoutingDiscoverable"

    /// W4 (3.4.1): per-path flag-based palette membership for
    /// file-source skills, mirroring `inCommandPalette` on the Skill
    /// struct. Dictionary <String /* absolute file path */, Bool>.
    /// Missing entry: false (no file-source skill auto-promotes into
    /// the hot-key palette — it requires explicit operator opt-in
    /// because palette commit requires a Notion page id to fetch the
    /// body; file-source palette membership is currently advisory
    /// until a file-source commit pipeline lands).
    public static let fileSkillInCommandPalette = "com.notionbridge.fileSkillInCommandPalette"

    /// v3.7·1: Time-to-live (in hours) for entries in the on-disk skills
    /// cache (`BridgePaths.applicationSupport(.skillsCache)`). Int. Reads
    /// older than the TTL still return their data — flagged `stale: true`
    /// in the routing payload — and a follow-on `refreshAll()` heals them.
    /// Missing/<=0 entry: defaults to 24 hours via
    /// `skillsCacheTTLHoursEffective`.
    public static let skillsCacheTTLHours = "com.notionbridge.skillsCacheTTLHours"

    /// Effective skills-cache TTL in hours. Reads `UserDefaults` and
    /// falls back to 24 when missing or non-positive.
    public static var skillsCacheTTLHoursEffective: Int {
        let raw = UserDefaults.standard.integer(forKey: skillsCacheTTLHours)
        return raw > 0 ? raw : 24
    }

    // MARK: - Commands Palette (cmd-ux)

    /// Master on/off for the Commands palette (global-hotkey command box).
    /// Bool. Written by Settings → Commands, read by `CommandsPaletteGate`.
    /// ABSENT ⇒ ON (default-enabled): the gate treats a missing key as
    /// `true` so a fresh install gets the palette without any opt-in. An
    /// explicit `BRIDGE_ENABLE_COMMANDS` env var still overrides this pref.
    public static let commandsPaletteEnabled = "com.notionbridge.commandsPaletteEnabled"

    /// Persisted `HotkeyConfig` for the Commands-palette global hot-key.
    /// Data (JSON-encoded `HotkeyConfig`). Written by Settings → Commands
    /// (the in-Settings recorder), read at hot-key registration. ABSENT or
    /// corrupt ⇒ `HotkeyConfig.productionDefault` (the gate falls back so a
    /// fresh install / decode failure never loses the palette).
    public static let commandsHotkey = "com.notionbridge.commandsHotkey"

    // MARK: - Onboarding & Legal

    /// Whether the user has completed the onboarding wizard. Bool.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Whether the user has accepted legal terms. Bool.
    public static let hasAcceptedLegalTerms = "hasAcceptedLegalTerms"
}
