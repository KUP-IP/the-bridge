// MemoryHubCloudParse.swift — FRONTIER cloud Understand parse (Voice Curator W2)
// TheBridge · Modules · VoiceMemo
//
// The frontier rung of the FRONTIER-FIRST Understand chain: an OpenAI-compatible
// chat-completions POST that extracts a full voice-memo routing plan (summary +
// typed intents) as STRICT JSON over the WHOLE transcript. Unlike the Tier-3
// cloud TITLE polish (`MemoryHubCloudTitle.swift`, ≤8-word title only), this
// produces the entire `VoiceMemoPlan` that feeds the curator's election. It is
// the zero-marginal-cost / best-quality arm; local Ollama + the deterministic
// heuristic are the in-a-pinch floor below it.
//
// REUSE: the HTTP call goes through the SAME injectable `CloudChatTransport` seam
// and the SAME `MemoryHubProviderConfigStore` provider gate + Keychain key as the
// cloud titler, so the request shape / parse / map is unit-tested with a stub —
// the harness never opens a socket. The API KEY is read from the Keychain at call
// time and is NEVER logged. Frontier large-context: the WHOLE transcript is sent
// (NO 4000-char cap — long-transcript LOCAL chunking is a separate Phase-2 scope).
//
// CONTRACT: on ANY failure (non-2xx / timeout / unparseable JSON / zero intents)
// this THROWS, so `CloudParseProvider.parse` returns nil and the router degrades
// to Local → Heuristic with `degraded == true`. Provenance is stamped by the
// router (`.cloud`), NOT here.

import Foundation

/// Frontier cloud plan extractor. Pure, stateless: builds the request, sends it
/// through the injectable transport, parses the strict-JSON completion into a
/// `VoiceMemoPlan`, or throws on any failure (the provider swallows the throw and
/// the chain degrades). NEVER queues a review — degradation is silent + graceful.
public enum MemoryHubCloudParser {

    /// System prompt: STRICT JSON only (no prose), mapping the transcript to a
    /// summary + typed routing intents. The lane vocabulary mirrors
    /// `VoiceMemoIntentKind.rawValue` exactly so the mapper can switch on it.
    static let systemPrompt = """
    Extract a voice-memo routing plan as STRICT JSON, no prose: \
    {"summary": string, "intents": [{"kind": "reminder|memory_keep|agent_memory|registry_update|review", \
    "entityKey": string|null, "entityHint": string|null, "title": string|null, "body": string|null, \
    "dueISO8601": string|null, "fields": object<string,string>, "confidence": number}]}
    """

    /// Test/override hook for the transport. nil ⇒ the real `URLSession`-backed
    /// transport. Mirrors `MemoryHubCloudTitler.transportOverride` so tests inject
    /// a canned `(Data, HTTPURLResponse)` (or a throwing stub) with no real socket.
    nonisolated(unsafe) public static var transportOverride: CloudChatTransport?

    /// Errors are intentionally coarse — the caller only needs "it failed, degrade".
    public enum CloudParseError: Error, Equatable {
        case notRunnable          // provider disabled / no model / bad base URL
        case missingKey           // no API key in the Keychain
        case badURL               // base URL + path did not form a request URL
        case httpStatus(Int)      // non-2xx
        case unparseable          // 2xx but content was not strict-JSON we could map
        case noIntents            // parsed OK but yielded zero usable intents
    }

    /// Run the frontier parse once for a memo's transcript. Returns a mapped
    /// `VoiceMemoPlan` on success (provenance left at the model default — the
    /// router overwrites it to `.cloud`), or throws `CloudParseError` / rethrows
    /// the transport error on ANY failure. The key is used only as the bearer
    /// header — it is never returned or logged.
    ///
    /// `keyProvider` defaults to the Keychain lookup for this provider; tests
    /// inject a constant. `transport` defaults to `transportOverride ?? URLSession`.
    public static func parse(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String,
        provider: MemoryHubProvider,
        keyProvider: (() -> String?)? = nil,
        transport providedTransport: CloudChatTransport? = nil
    ) async throws -> VoiceMemoPlan {
        guard MemoryHubProviderConfigStore.canRunCloud(provider) else { throw CloudParseError.notRunnable }

        let key = (keyProvider?() ?? KeychainManager.shared.read(
            key: MemoryHubProviderConfigStore.keychainKey(for: provider.id)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw CloudParseError.missingKey }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try buildRequest(provider: provider, transcript: trimmedTranscript, apiKey: key)

        let transport = providedTransport ?? transportOverride ?? URLSessionCloudChatTransport()
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw CloudParseError.httpStatus(response.statusCode)
        }

        guard let content = parseCompletionContent(data) else { throw CloudParseError.unparseable }
        guard let plan = mapPlan(
            content,
            transcript: trimmedTranscript,
            fallbackTitle: fallbackTitle,
            recordingPath: recordingPath
        ) else { throw CloudParseError.unparseable }
        guard !plan.intents.isEmpty else { throw CloudParseError.noIntents }
        return plan
    }

    /// Build the OpenAI-compatible `POST <baseURL>/chat/completions` request:
    /// Bearer auth, the strict-JSON system prompt + the WHOLE transcript as user
    /// content, low temperature, a generous token cap (the plan can be large), and
    /// the locked 20s timeout (`MemoryHubPreview.cloudTimeoutSeconds`). The key is
    /// set only as the header. NO transcript cap — frontier large context.
    static func buildRequest(provider: MemoryHubProvider, transcript: String, apiKey: String) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a trailing slash on the base URL so "…/v1" and "…/v1/" both resolve.
        guard let url = URL(string: base.hasSuffix("/") ? "\(base)chat/completions" : "\(base)/chat/completions") else {
            throw CloudParseError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = MemoryHubPreview.cloudTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": provider.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                // WHOLE transcript — frontier large context (no prefix cap).
                ["role": "user", "content": transcript],
            ],
            "temperature": 0.1,
            "max_tokens": 2048,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Pull `choices[0].message.content` from an OpenAI-compatible chat-completions
    /// response. Returns nil when the JSON is malformed or carries no string content.
    static func parseCompletionContent(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Map the model's strict-JSON content into a `VoiceMemoPlan`. Tolerates a
    /// fenced ```json block (strips fences before JSON parse). The title is derived
    /// from the summary via `VoiceMemoParser.sanitizeTitle` (so cloud titles match
    /// the heuristic/local style); each intent maps its lane + fields (default `[:]`).
    /// Returns nil when the content is not an object with a usable `intents` array.
    static func mapPlan(
        _ content: String,
        transcript: String,
        fallbackTitle: String,
        recordingPath: String
    ) -> VoiceMemoPlan? {
        let jsonText = stripCodeFences(content)
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let summary = (root["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generatedTitle = VoiceMemoParser.sanitizeTitle(summary.isEmpty ? nil : summary, fallback: fallbackTitle)

        guard let rawIntents = root["intents"] as? [[String: Any]] else { return nil }
        var intents: [VoiceMemoIntent] = []
        for raw in rawIntents {
            guard let kindString = raw["kind"] as? String,
                  let kind = VoiceMemoIntentKind(rawValue: kindString) else { continue }
            let confidence = doubleValue(raw["confidence"]) ?? 0.75
            let fields = stringMap(raw["fields"])
            intents.append(VoiceMemoIntent(
                kind: kind,
                confidence: confidence,
                entityKey: nonEmptyString(raw["entityKey"]),
                entityHint: nonEmptyString(raw["entityHint"]),
                title: nonEmptyString(raw["title"]) ?? generatedTitle,
                body: nonEmptyString(raw["body"]) ?? (summary.isEmpty ? nil : summary),
                dueISO8601: nonEmptyString(raw["dueISO8601"]),
                fields: fields
            ))
        }
        guard !intents.isEmpty else { return nil }

        // `skipMemoryKeep` mirrors the local arm: true when no memory_keep lane was
        // produced (the curator skips the Keep OS write only when the model omits it).
        let skipMemoryKeep = !intents.contains { $0.kind == .memoryKeep }
        return VoiceMemoPlan(
            generatedTitle: generatedTitle,
            skipMemoryKeep: skipMemoryKeep,
            summary: summary,
            actions: [],
            intents: intents,
            provenance: .cloud,
            degraded: false
        )
    }

    // MARK: - JSON coercion helpers

    /// Strip a leading/trailing Markdown code fence (```json … ``` or ``` … ```) so
    /// a fenced completion still parses. No-op when there is no fence.
    static func stripCodeFences(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        // Drop the opening fence line (``` or ```json), keep everything after the
        // first newline; then drop a trailing fence if present.
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...])
        } else {
            t = String(t.dropFirst(3))
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("```") {
            t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// Accept a JSON number expressed as Double, Int, or numeric String.
    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A non-empty trimmed string, or nil (so JSON `null` / "" become Swift nil).
    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Coerce a JSON object into `[String: String]`, stringifying scalar values and
    /// dropping non-scalar entries. nil/absent ⇒ `[:]`.
    private static func stringMap(_ any: Any?) -> [String: String] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String { out[k] = s }
            else if let i = v as? Int { out[k] = String(i) }
            else if let d = v as? Double { out[k] = String(d) }
            else if let b = v as? Bool { out[k] = b ? "true" : "false" }
        }
        return out
    }
}
