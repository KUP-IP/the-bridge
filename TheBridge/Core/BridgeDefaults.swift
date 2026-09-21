// BridgeDefaults.swift — Shared UserDefaults key constants
// TheBridge · Core
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

    /// fb-securitygate: Per-MODULE tier overrides. Dictionary<String /* module
    /// name */, String /* SecurityTier rawValue */>. Written by SecurityGate
    /// when the user picks "Always Allow" on a Request-tier tool — the grant is
    /// scoped to the whole module so it covers sibling tools, not just the one
    /// tool that happened to be prompted (e.g. an Always-Allow during a
    /// 3-way-parallel snippets operation now covers all snippets_* siblings).
    /// Read by ToolRouter when resolving a tool's effective tier: a per-tool
    /// override (more specific) wins over a per-module override, which wins over
    /// the registered default. `neverAutoApprove` is not an execution floor
    /// (#258) — Always Allow and Tools-UI overrides apply to every tool.
    /// ABSENT ⇒ no module overrides.
    public static let moduleTierOverrides = "com.notionbridge.moduleTierOverrides"

    /// Retired issue #126 send-only mode key. No longer read or written.
    /// Do not migrate or clear operator prefs; Settings → Tools now owns the
    /// ordinary open/notify/request override for `messages_send`.
    public static let messagesSendApprovalMode = "com.notionbridge.messagesSendApprovalMode"

    /// Retired with `messagesSendApprovalMode`. Left defined so a future key
    /// reuse cannot collide with leftover operator prefs.
    public static let messagesSendApprovalGeneration = "com.notionbridge.messagesSendApprovalGeneration"

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

    /// Emergency, monotonic denylist for Notion-backed skills. Encoded [String]
    /// of normalized Notion page UUIDs. This may only reduce exposure; it can
    /// never enroll or promote a skill.
    public static let skillExposureEmergencyDenylist = "com.notionbridge.skillExposure.emergencyDenylist"

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

    /// Per-client Standing Orders overlays. Data (JSON-encoded
    /// `[String /* client name */ : String /* addendum markdown */]`).
    /// An optional operator-authored addendum appended to the composed
    /// handshake instructions when a client of that name connects. ABSENT
    /// or empty ⇒ no overlay (the default for every install — composition
    /// is byte-identical to the pre-overlay payload). Written/read by
    /// `ClientOverlayStore`.
    public static let standingOrdersClientOverlays = "com.notionbridge.standingOrdersClientOverlays"

    /// Wave 2 (PKT-977): when true, append the memory handshake slice to
    /// `initialize.instructions` for connecting MCP clients. Default OFF —
    /// memory remains opt-in via `bridge://memory` until the operator enables this.
    public static let memoryHandshakeAutoInject = "com.notionbridge.memory.handshakeAutoInject"

    public static var memoryHandshakeAutoInjectEffective: Bool {
        UserDefaults.standard.bool(forKey: memoryHandshakeAutoInject)
    }

    /// Wave 2 (PKT-977 Q1): per-client memory auto-inject overrides. Data
    /// (JSON-encoded `[String /* clientName */ : Bool /* override */]`).
    /// When a per-client entry is present, it overrides the global
    /// `memoryHandshakeAutoInject` flag for that specific client. ABSENT or
    /// empty map ⇒ no per-client override (global flag governs). Written/read
    /// by `MemoryAutoInjectClientStore`.
    public static let memoryAutoInjectClientOverrides = "com.notionbridge.memory.autoInjectClientOverrides"

    // MARK: - Wave 1 Broker

    /// Bridge Evolution W1: when enabled, remote tunnel-origin callers cannot
    /// invoke local control-plane tools even after OAuth. This is opt-in: the
    /// normal connector posture is full tool parity, with each call still
    /// governed by bridge_initialize and the tool's SecurityGate tier.
    public static let brokerRemoteControlPlaneBlock = "com.notionbridge.broker.remoteControlPlaneBlock"

    public static var brokerRemoteControlPlaneBlockEnabled: Bool {
        if UserDefaults.standard.object(forKey: brokerRemoteControlPlaneBlock) == nil { return false }
        return UserDefaults.standard.bool(forKey: brokerRemoteControlPlaneBlock)
    }

    /// Bridge Evolution W1: remote notify/request-tier tools require the caller
    /// to have completed bridge_initialize for the current transport session.
    /// This remains fail-closed even when the optional origin-based control-
    /// plane block is disabled for full connector tool parity.
    public static let brokerRemoteGovernedSessionRequired = "com.notionbridge.broker.remoteGovernedSessionRequired"

    public static var brokerRemoteGovernedSessionRequiredEnabled: Bool {
        if UserDefaults.standard.object(forKey: brokerRemoteGovernedSessionRequired) == nil { return true }
        return UserDefaults.standard.bool(forKey: brokerRemoteGovernedSessionRequired)
    }

    /// Bridge Evolution W1: when enabled, successful tool results from a
    /// transport session that has not called bridge_initialize carry an advisory
    /// governance annotation. Missing key defaults ON.
    public static let brokerAdvisoryAnnotation = "com.notionbridge.broker.advisoryAnnotation"

    public static var brokerAdvisoryAnnotationEnabled: Bool {
        if UserDefaults.standard.object(forKey: brokerAdvisoryAnnotation) == nil { return true }
        return UserDefaults.standard.bool(forKey: brokerAdvisoryAnnotation)
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

    /// D0 / #140: developer publication workflow. Bool. ABSENT ⇒ OFF.
    /// Standard mode must not show GitHub, branch, commit, or push controls.
    public static let commandsDeveloperPublication = "com.notionbridge.commandsDeveloperPublication"

    // MARK: - Settings shell (#283)

    /// Settings sidebar labeled-rail vs icon-rail. Bool. ABSENT ⇒ collapsed
    /// (icon rail) so the standard window (1080×880) is the zero-scroll
    /// collapsed chrome. Expanding the labeled rail may grow the window.
    public static let settingsSidebarExpanded = "com.notionbridge.settings.sidebarExpanded"

    // MARK: - Onboarding & Legal

    /// Whether the user has completed the onboarding wizard. Bool.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Whether the user has accepted legal terms. Bool.
    public static let hasAcceptedLegalTerms = "hasAcceptedLegalTerms"

    // MARK: - Bridge Cloud Access (WS-F)

    /// Master ON/OFF for Bridge Cloud Access. Bool. Written by the Remote
    /// Access toggle; the Enable flow reverts it to `false` on `.failed`.
    /// ABSENT ⇒ OFF.
    public static let cloudAccessEnabled = "com.notionbridge.cloudAccessEnabled"

    /// WS-D (PKT-921): effective ON/OFF read of `cloudAccessEnabled`.
    /// `ServerManager.setup()` consults this at launch to decide whether to
    /// register the cloud-gated `bridge_status` tool + start the heartbeat.
    /// ABSENT ⇒ `false` (cloud access off), matching the key's documented
    /// default so a default install is byte-for-byte its prior self.
    public static var cloudAccessEnabledValue: Bool {
        UserDefaults.standard.bool(forKey: cloudAccessEnabled)
    }

    /// The cloudflared tunnel hostname surfaced after a successful provision
    /// (`.connected`). String. Written by the Enable flow on success; read by
    /// RemoteAccessView to populate the MCP URL row. ABSENT ⇒ no URL yet.
    public static let cloudTunnelHostname = "com.notionbridge.cloudTunnelHostname"

    /// WS-G (PKT-923): one-time gate for the FirstRunCloudAccessModal. Bool.
    /// Written `true` when the user dismisses the first-run guide (the "Got it"
    /// button); read by RemoteAccessSection before presenting the sheet on the
    /// first transition to `.online`. ABSENT ⇒ not yet seen (modal shows once).
    public static let hasSeenCloudAccessFirstRun = "com.notionbridge.hasSeenCloudAccessFirstRun"

    // MARK: - Wake tunnel heal (LaunchAgent cloudflared)

    /// When true, `NSWorkspace.didWake` may kickstart the cloudflared LaunchAgent
    /// so remote connectors recover after lid sleep. ABSENT ⇒ ON.
    public static let tunnelWakeHealEnabled = "com.notionbridge.tunnelWakeHeal.enabled"

    public static var tunnelWakeHealEnabledValue: Bool {
        if UserDefaults.standard.object(forKey: tunnelWakeHealEnabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: tunnelWakeHealEnabled)
    }

    /// LaunchAgent label for `launchctl kickstart -k gui/<uid>/<label>`.
    /// ABSENT ⇒ `TunnelLaunchAgentHealer.defaultLabel` (`com.kup.cloudflared-bridge`).
    public static let tunnelLaunchAgentLabel = "com.notionbridge.tunnelWakeHeal.launchAgentLabel"

    public static var tunnelLaunchAgentLabelValue: String {
        let raw = UserDefaults.standard.string(forKey: tunnelLaunchAgentLabel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? TunnelLaunchAgentHealer.defaultLabel : raw
    }

    /// Minimum seconds between wake kickstarts. ABSENT or ≤0 ⇒ 90.
    public static let tunnelWakeHealThrottleSeconds = "com.notionbridge.tunnelWakeHeal.throttleSeconds"

    public static var tunnelWakeHealThrottleSecondsValue: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: tunnelWakeHealThrottleSeconds)
        return stored > 0 ? stored : TunnelLaunchAgentHealer.defaultThrottleSeconds
    }

    /// Last successful kickstart time (TimeInterval since reference date).
    public static let tunnelWakeHealLastKickAtKey = "com.notionbridge.tunnelWakeHeal.lastKickAt"

    public static var tunnelWakeHealLastKickAt: Date? {
        let raw = UserDefaults.standard.double(forKey: tunnelWakeHealLastKickAtKey)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    public static func recordTunnelWakeHealKick(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: tunnelWakeHealLastKickAtKey)
    }

    // MARK: - Voice memo transcription

    /// When true, memos without a `.txt` sidecar are transcribed via FluidAudio Parakeet v3.
    public static let voiceMemoParakeetTranscription = "com.notionbridge.voiceMemo.parakeetTranscription"

    /// When true, extract Apple embedded `tsrp` transcript before Parakeet fallback.
    public static let voiceMemoAppleTranscript = "com.notionbridge.voiceMemo.appleTranscript"

    /// When true, use SpeechAnalyzer between Apple tsrp and Parakeet. DEFAULT OFF.
    public static let voiceMemoSpeechAnalyzerTranscription = "com.notionbridge.voiceMemo.speechAnalyzerTranscription"

    /// Voice memo curator Understand routing: auto | heuristics | agent | cloud.
    public static let voiceMemoCuratorMode = "com.notionbridge.voiceMemo.curatorMode"

    /// When Notion Memory `memory_keep` fails: `off` | `review` | `agentMemory`.
    /// Default (absent) = `review` — never silently substitute agent memory (SC8).
    public static let voiceMemoMemoryFallbackPolicy = "com.notionbridge.voiceMemo.memoryFallbackPolicy"

    public enum VoiceMemoMemoryFallbackPolicy: String, Sendable {
        case off
        case review
        case agentMemory
    }

    public static var voiceMemoMemoryFallbackPolicyEffective: VoiceMemoMemoryFallbackPolicy {
        let raw = UserDefaults.standard.string(forKey: voiceMemoMemoryFallbackPolicy)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "off", "none", "fail": return .off
        case "agentmemory", "agent_memory", "agent-memory": return .agentMemory
        default: return .review
        }
    }

    /// Parakeet transcription defaults ON when unset (Wave 2).
    public static var voiceMemoParakeetTranscriptionEffective: Bool {
        if UserDefaults.standard.object(forKey: voiceMemoParakeetTranscription) == nil { return true }
        return UserDefaults.standard.bool(forKey: voiceMemoParakeetTranscription)
    }

    /// Apple tsrp extraction defaults ON when unset (Memory Hub Wave 1).
    public static var voiceMemoAppleTranscriptEffective: Bool {
        if UserDefaults.standard.object(forKey: voiceMemoAppleTranscript) == nil { return true }
        return UserDefaults.standard.bool(forKey: voiceMemoAppleTranscript)
    }

    /// SpeechAnalyzer transcription defaults OFF when unset (Wave 7).
    public static var voiceMemoSpeechAnalyzerTranscriptionEffective: Bool {
        UserDefaults.standard.bool(forKey: voiceMemoSpeechAnalyzerTranscription)
    }

}
