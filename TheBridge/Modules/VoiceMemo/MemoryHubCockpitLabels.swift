// MemoryHubCockpitLabels.swift — pure, UI-free human labels for the Process cockpit (W3)
// TheBridge · Modules · VoiceMemo
//
// Voice Curator FRONTIER-FIRST W3 — cockpit UX remediation. The cockpit used to
// render raw enum `rawValue`s (jargon: `memory_keep`, `agent_memory`, `parakeet`,
// `suppressed`). These pure functions map domain enums → operator-legible text so
// the SwiftUI `MemoryProcessTab` shows sight, not jargon. They are deliberately
// UI-free (no SwiftUI import) so the W3 test suite asserts them directly.

import Foundation

/// Human-legible labels for the Process triage cockpit. Pure mappings — no state,
/// no I/O — so every branch is unit-asserted.
public enum MemoryHubCockpitLabels {

    /// Intent lane → operator-facing noun. Replaces `kind.rawValue` everywhere the
    /// cockpit shows a lane (intent rows + the "Commit — …" inspector header).
    public static func intentKind(_ kind: VoiceMemoIntentKind) -> String {
        switch kind {
        case .reminder:       return "Reminder"
        case .memoryKeep:     return "Memory"
        case .agentMemory:    return "Agent note"
        case .registryUpdate: return "Update record"
        case .review:         return "Needs review"
        }
    }

    /// Election status token → operator phrase. The cockpit shows `primary` /
    /// `suppressed` / `review`; only `suppressed` reads as jargon, so it becomes
    /// "Held for review" (it is the lane the election did not pick — a human still can).
    public static func intentStatus(_ status: String) -> String {
        switch status {
        case "primary":    return "Primary"
        case "suppressed": return "Held for review"
        case "review":     return "Needs review"
        default:           return status
        }
    }

    /// Transcript source → operator-facing provenance for the memo-row subtitle.
    /// `parakeet` is the on-device Apple model; `sidecar` is a previously-cached
    /// transcript; `none` (or a memo with no resolved transcript) reads plainly.
    public static func transcriptSource(_ source: VoiceMemoTranscriptSource, hasTranscript: Bool) -> String {
        guard hasTranscript else { return "No transcript" }
        switch source {
        case .apple:    return "Apple"
        case .parakeet: return "On-device"
        case .sidecar:  return "Cached"
        case .none:     return "No transcript"
        }
    }

    /// Which Understand-chain arm produced the plan → an inspector provenance badge.
    public static func provenanceBadge(_ provenance: ParseProvenance, degraded: Bool) -> String {
        if degraded {
            return "Parsed locally — degraded; reconnect or add credits for full quality"
        }
        switch provenance {
        case .agent:     return "Parsed by Claude (agent)"
        case .cloud:     return "Parsed by cloud"
        case .local:     return "Parsed locally (on-device model)"
        case .heuristic: return "Parsed locally (rules)"
        }
    }

    /// Compact provenance chip for memo list rows.
    public static func provenanceShort(_ provenance: ParseProvenance, degraded: Bool) -> String {
        if degraded { return "Degraded" }
        switch provenance {
        case .cloud: return "Cloud"
        case .local: return "Local"
        case .heuristic: return "Rules"
        case .agent: return "Agent"
        }
    }

    public static func diffBadgeLabel(_ badge: String) -> String {
        switch badge {
        case "added": return "Added"
        case "changed": return "Changed"
        case "demoted": return "Demoted"
        default: return badge.capitalized
        }
    }

    public static func awaitingAgentLabel() -> String { "Awaiting agent" }

    /// Pre-await status line shown the instant a memo is selected, BEFORE `voice_memo_get`
    /// resolves its transcript. When the memo has no transcript yet, selecting it triggers
    /// an on-device transcription run (first run may DOWNLOAD the Parakeet model) — without
    /// a distinct signal that reads as a hang. Returns a legible "transcribing" line in that
    /// case; otherwise the generic preview-loading line. Pure (no I/O), so it is unit-asserted.
    public static func selectStatus(hasTranscript: Bool) -> String {
        hasTranscript
            ? "Loading preview…"
            : "Transcribing on-device… (first run may download the model)"
    }

    /// Shown when `voice_memo_get` returns but the transcript is still empty (e.g. on-device
    /// transcription is disabled and there is no Apple transcript) — an actionable next step
    /// instead of an empty card. Pure constant surfaced as a function for test symmetry.
    public static func unresolvedTranscriptMessage() -> String {
        "No transcript yet — enable on-device transcription in Processing, or run voice_memo_transcript_refresh"
    }
}
