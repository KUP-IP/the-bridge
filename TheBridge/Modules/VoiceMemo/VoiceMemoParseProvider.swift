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
// per-intent commit — all unchanged. The cloud rung (W2) is a REAL OpenAI-
// compatible frontier call (`MemoryHubCloudParser`) reusing `CloudChatTransport`.

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

// MARK: - Cloud (frontier API) — REAL (W2)

/// Frontier cloud (OpenAI-compatible API) Understand rung — the zero-marginal-cost
/// / best-quality arm. Availability is the loaded provider's config gate
/// (`canRunCloud` ∧ a Keychain key); `parse` delegates to `MemoryHubCloudParser`,
/// which one-shots the WHOLE transcript (frontier large context — no 4000-char
/// cap) into a strict-JSON `VoiceMemoPlan`. It returns nil on ANY failure (non-2xx
/// / timeout / unparseable JSON / zero intents) so the chain gracefully degrades to
/// Local → Heuristic (`degraded == true`). The router stamps `.cloud` provenance;
/// the API key is read from the Keychain at call time and is NEVER logged.
public struct CloudParseProvider: VoiceMemoParseProvider {
    public init() {}

    public var provenance: ParseProvenance { .cloud }

    /// The loaded provider slot (first in `providers.json`). nil ⇒ never configured.
    private var loadedProvider: MemoryHubProvider? {
        MemoryHubProviderConfigStore.load().first
    }

    /// Cheap gate: a configured provider that `canRunCloud` (enabled + model + valid
    /// base URL) AND has a Keychain API key. No network here.
    public func isAvailable() -> Bool {
        guard let provider = loadedProvider else { return false }
        return MemoryHubProviderConfigStore.canRunCloud(provider)
            && MemoryHubProviderConfigStore.keyConfigured(providerId: provider.id)
    }

    /// Frontier parse over the WHOLE transcript. Returns nil on any throw (the
    /// router then degrades to local/heuristic). Provenance is (re)stamped `.cloud`
    /// by the router, so we do not set it here.
    public func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        guard let provider = loadedProvider else { return nil }
        return try? await MemoryHubCloudParser.parse(
            transcript: transcript,
            fallbackTitle: fallbackTitle,
            recordingPath: recordingPath,
            provider: provider
        )
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
