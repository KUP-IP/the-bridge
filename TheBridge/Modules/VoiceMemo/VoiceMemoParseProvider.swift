// VoiceMemoParseProvider.swift — FRONTIER-FIRST Understand provider chain (Phase 1, W1)
// TheBridge · Modules · VoiceMemo
//
// The curator's Understand step is inverted from local-first to FRONTIER-FIRST:
// a connected MCP agent (out-of-process) or a cloud API produces the routing
// intents FIRST (zero marginal cost / best quality); local Ollama + the
// deterministic heuristic are the in-a-pinch floor. Each rung conforms to
// `VoiceMemoParseProvider`; `VoiceMemoParseRouter` walks the ordered chain and
// stamps `plan.provenance` / `plan.degraded`.
//
// TRUST INVARIANT: a provider only changes WHO produces the `VoiceMemoPlan`.
// The produced plan feeds the EXISTING election / guardrails / processed-gate /
// per-intent commit — all unchanged. The cloud rung is a STUB this wave (W2
// implements the real OpenAI-compatible call by reusing `CloudChatTransport`).

import Foundation

/// One arm of the Understand chain. `parse` returns nil when the rung is
/// unavailable or fails at runtime, so the router falls through to the next rung.
/// `isAvailable()` is the cheap config/precondition check used to decide the
/// chain shape and the `degraded` flag (an earlier available rung that returns
/// nil at runtime ⇒ degraded).
public protocol VoiceMemoParseProvider: Sendable {
    /// The provenance stamped on a plan this provider produces.
    var provenance: ParseProvenance { get }
    /// Cheap precondition gate — true when this rung COULD run for the current
    /// config (not a guarantee it succeeds; `parse` may still return nil).
    func isAvailable() -> Bool
    /// Produce a plan, or nil when unavailable / failed (⇒ fall through).
    func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan?
}

// MARK: - Cloud (frontier API) — STUB this wave

/// Tier-3 cloud (frontier API) Understand rung. STUB for W1: never available and
/// always returns nil, so `.auto`/`.cloud` chains fall straight through to the
/// local/heuristic floor with no behavior change. W2 replaces the body with a
/// real OpenAI-compatible chat-completions call that reuses the injectable
/// `CloudChatTransport` seam (see `MemoryHubCloudTitle.swift`) and the
/// `MemoryHubProviderConfigStore` gate (`canRunCloud` + Keychain key), stamping
/// `.cloud` provenance. Keeping the rung in the chain now means W2 is a pure
/// body swap with no router/model churn.
public struct CloudParseProvider: VoiceMemoParseProvider {
    public init() {}

    public var provenance: ParseProvenance { .cloud }

    /// STUB: cloud is not wired this wave. W2 returns
    /// `MemoryHubProviderConfigStore.canRunCloud(provider) && keyConfigured`.
    public func isAvailable() -> Bool { false }

    /// STUB: W1 never produces a cloud plan. W2 builds + sends the request and
    /// maps the completion into a `VoiceMemoPlan` (provenance `.cloud`), or nil
    /// on any non-2xx / timeout / parse failure (⇒ degrade to local/heuristic).
    public func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        nil
    }
}

// MARK: - Local (Ollama) — in-a-pinch fallback

/// Local Ollama Understand rung. Availability is the EXISTING gate
/// (`voiceMemoOllamaRoutingEffective ∧ shouldUseLocalOllama() ∧ a routing model`);
/// `parse` delegates to `VoiceMemoParser.ollamaParse` (the verbatim-extracted
/// Ollama body), which returns nil on an unhealthy daemon / generation or
/// JSON-parse failure. The plan is stamped `.local` by `ollamaParse`.
public struct LocalParseProvider: VoiceMemoParseProvider {
    public init() {}

    public var provenance: ParseProvenance { .local }

    public func isAvailable() -> Bool {
        BridgeDefaults.voiceMemoOllamaRoutingEffective
            && VoiceMemoCuratorRouter.shouldUseLocalOllama()
            && BridgeDefaults.ollamaRoutingModelEffective != nil
    }

    public func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        await VoiceMemoParser.ollamaParse(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            recordingPath: recordingPath
        )
    }
}

// MARK: - Heuristic — guaranteed floor

/// Deterministic heuristic Understand rung — the GUARANTEED FLOOR. Always
/// available and NEVER nil: it wraps `VoiceMemoParser.parse` (pure phrase
/// matching, no network/LLM). Stamps `.heuristic`. Every chain ends here so the
/// curator always has intents to feed the election.
public struct HeuristicParseProvider: VoiceMemoParseProvider {
    public init() {}

    public var provenance: ParseProvenance { .heuristic }

    public func isAvailable() -> Bool { true }

    public func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        var plan = VoiceMemoParser.parse(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            recordingPath: recordingPath.isEmpty ? nil : recordingPath
        )
        plan.provenance = .heuristic
        return plan
    }
}
