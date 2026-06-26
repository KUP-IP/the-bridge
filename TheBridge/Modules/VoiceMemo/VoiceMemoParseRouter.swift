// VoiceMemoParseRouter.swift — FRONTIER-FIRST Understand chain walk (Phase 1, W1)
// TheBridge · Modules · VoiceMemo
//
// Reads the operator's curator mode and walks an ordered provider chain. The
// FIRST rung that is `isAvailable()` AND whose `parse()` returns non-nil wins;
// its `provenance` is stamped onto the plan. The chain is FRONTIER-FIRST: for
// `.auto` it is [cloud, local, heuristic] so the zero-marginal-cost / best-
// quality rung is tried first and local Ollama / heuristics are the floor.
//
// `degraded` is set true when a HIGHER-preference rung was available by config
// but returned nil at runtime (so we fell past it). The heuristic floor is
// always available and never nil, guaranteeing the walk terminates with intents.
//
// TRUST INVARIANT: the router only changes WHO produces the plan — the produced
// plan feeds the EXISTING election / guardrails / processed-gate / commit, all
// unchanged.

import Foundation

public enum VoiceMemoParseRouter {

    /// Test seam: when set, `parse` uses this provider list instead of
    /// `providers(for:)`. Lets the harness inject stub rungs (controllable
    /// availability + canned/nil plans) with NO real network / Ollama / agent.
    /// nil ⇒ the production `providers(for:)` chain. Matches the
    /// `transportOverride` injection pattern used elsewhere in the hub.
    nonisolated(unsafe) public static var providerOverride: (@Sendable (VoiceMemoCuratorMode) -> [VoiceMemoParseProvider])?

    /// The ordered Understand chain for a curator mode (FRONTIER-FIRST):
    ///   .cloud      → [Cloud, Heuristic]
    ///   .local      → [Local, Heuristic]
    ///   .heuristics → [Heuristic]
    ///   .agent      → [Heuristic]   (the connected agent parses out-of-process;
    ///                                the in-process preview uses the floor)
    ///   .auto       → [Cloud, Local, Heuristic]   (frontier-first)
    /// Heuristic is ALWAYS last so every chain has a guaranteed non-nil floor.
    public static func providers(for mode: VoiceMemoCuratorMode) -> [VoiceMemoParseProvider] {
        switch mode {
        case .cloud:
            return [CloudParseProvider(), HeuristicParseProvider()]
        case .local:
            return [LocalParseProvider(), HeuristicParseProvider()]
        case .heuristics:
            return [HeuristicParseProvider()]
        case .agent:
            return [HeuristicParseProvider()]
        case .auto:
            return [CloudParseProvider(), LocalParseProvider(), HeuristicParseProvider()]
        }
    }

    /// Walk the mode-ordered chain and return the winning plan with `provenance`
    /// stamped (and `degraded` set per the rule above). Reads
    /// `VoiceMemoCuratorRouter.effectiveMode()`.
    public static func parse(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String? = nil
    ) async -> VoiceMemoPlan {
        let mode = VoiceMemoCuratorRouter.effectiveMode()
        let chain = (providerOverride ?? { providers(for: $0) })(mode)
        return await walk(chain, transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath)
    }

    /// Walk an explicit chain (used by `parse` and directly by tests). The first
    /// available rung that yields a plan wins; an earlier available rung that
    /// returned nil marks the result `degraded`.
    static func walk(
        _ chain: [VoiceMemoParseProvider],
        transcript: String,
        fallbackTitle: String,
        recordingPath: String?
    ) async -> VoiceMemoPlan {
        let path = recordingPath ?? ""
        var degraded = false
        for provider in chain {
            guard provider.isAvailable() else { continue }
            if var plan = await provider.parse(transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: path) {
                plan.provenance = provider.provenance
                plan.degraded = degraded
                return plan
            }
            // Available by config but returned nil at runtime ⇒ we fall PAST a
            // higher-preference rung: every later winner is a graceful degrade.
            degraded = true
        }
        // Defensive floor: the chain SHOULD always end in HeuristicParseProvider
        // (always available, never nil), so this is unreachable in practice. If a
        // caller passes a chain with no terminating floor, synthesize the
        // heuristic plan directly so the curator never returns without intents.
        var plan = VoiceMemoParser.parse(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            recordingPath: path.isEmpty ? nil : path
        )
        plan.provenance = .heuristic
        plan.degraded = degraded
        return plan
    }
}
