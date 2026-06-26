// MemoryHubCloudTitle.swift — Tier-3 cloud memo title (PKT-MEM-114 P3b)
// TheBridge · Modules · VoiceMemo
//
// MANUAL-ONLY cloud title polish: an OpenAI-compatible chat-completions POST that asks for a
// concise (≤8-word) intent-led title for a voice memo. This is the curator's ONLY net-new
// network path and is strictly gated behind an explicit operator button in the cockpit
// inspector (NEVER auto, NEVER on a sweep). Locked decision (1): Tier-3 cloud runs only on a
// per-memo action. On any failure / non-2xx / timeout it returns nil and the caller keeps the
// existing title — cloud is optional quality polish, not a trust gate, so it queues NO review.
//
// The HTTP call is behind a tiny injectable `CloudChatTransport` seam so the title logic
// (request shape, parsing, sanitize/cap) is unit-tested with a stub — the harness never opens
// a socket. The API KEY is read from the Keychain at call time and is NEVER logged.

import Foundation

/// Minimal transport seam for the Tier-3 cloud chat-completions POST. The live impl wraps
/// `URLSession`; tests inject a stub returning a canned `(Data, HTTPURLResponse)` (or throwing
/// to simulate a network failure/timeout). Keeping this protocol tiny keeps the title logic
/// (build request → parse → sanitize) testable with no real network.
public protocol CloudChatTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live transport: a bounded `URLSession` data task. Non-HTTP responses surface as
/// `URLError(.badServerResponse)` so the caller treats them as a failure (keep the title).
public struct URLSessionCloudChatTransport: CloudChatTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Tier-3 cloud title generator. Pure, manual-only, edited-pinned. The cockpit calls
/// `improve(...)` from the explicit "Improve title (cloud)" button (which is itself gated on
/// `MemoryHubProviderConfigStore.canRunCloud(provider)`); this type re-checks the gate and the
/// key, builds the request, parses + sanitizes the completion, and caches a `.cloud` title via
/// the edited-pinned store `put()` (so it never clobbers a human rename).
public enum MemoryHubCloudTitler {
    /// ≤8 words, mirroring the heuristic/local cap (`MemoryHubMemoTitler.maxWords`).
    static let maxWords = 8

    /// System prompt: concise, intent-led, no quotes — matches the Tier-1/Tier-2 title style.
    static let systemPrompt =
        "Return only a concise (≤8 words) intent-led title for this voice memo. No quotes."

    /// Test/override hook for the transport. nil ⇒ the real `URLSession`-backed transport.
    nonisolated(unsafe) public static var transportOverride: CloudChatTransport?

    /// Errors are intentionally coarse — the caller only needs "it failed, keep the title".
    public enum CloudTitleError: Error, Equatable {
        case notRunnable          // provider disabled / no model / bad base URL
        case missingKey           // no API key in the Keychain
        case badURL               // base URL + path did not form a request URL
        case httpStatus(Int)      // non-2xx
        case emptyCompletion      // 2xx but no usable title content
    }

    /// Run Tier-3 once for a memo. Returns the cached `.cloud` `MemoTitle` on success, or throws
    /// `CloudTitleError` / rethrows the transport error on any failure (the caller swallows it,
    /// surfaces a small inline status, and keeps the existing title). NEVER queues a review.
    ///
    /// `keyProvider` defaults to the Keychain lookup for this provider; tests inject a constant.
    /// The key is used only as the bearer header — it is never returned or logged.
    @discardableResult
    public static func improve(
        memoId: String,
        transcript: String,
        provider: MemoryHubProvider,
        now: Date = Date(),
        keyProvider: (() -> String?)? = nil,
        transport providedTransport: CloudChatTransport? = nil
    ) async throws -> MemoTitle {
        guard MemoryHubProviderConfigStore.canRunCloud(provider) else { throw CloudTitleError.notRunnable }

        let key = (keyProvider?() ?? KeychainManager.shared.read(
            key: MemoryHubProviderConfigStore.keychainKey(for: provider.id)))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { throw CloudTitleError.missingKey }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try buildRequest(provider: provider, transcript: trimmedTranscript, apiKey: key)

        let transport = providedTransport ?? transportOverride ?? URLSessionCloudChatTransport()
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw CloudTitleError.httpStatus(response.statusCode)
        }

        guard let content = parseCompletionContent(data) else { throw CloudTitleError.emptyCompletion }
        let title = sanitize(content)
        guard !title.isEmpty, title != "Untitled memo" else { throw CloudTitleError.emptyCompletion }

        let prior = MemoryHubMemoTitleStore.title(for: memoId)
        let memoTitle = MemoTitle(
            title: title,
            provenance: .cloud,
            intentCount: prior?.intentCount ?? 0,
            transcriptHash: MemoryHubActivityLog.sha256Hex(trimmedTranscript),
            generatedAt: ISO8601DateFormatter().string(from: now)
        )
        MemoryHubMemoTitleStore.put(memoTitle, memoId: memoId)   // edited-pinned: survives a rename
        return MemoryHubMemoTitleStore.title(for: memoId) ?? memoTitle
    }

    /// Build the OpenAI-compatible `POST <baseURL>/chat/completions` request: Bearer auth, the
    /// concise-title system+user messages, low temperature, a tight token cap, and the locked
    /// 20s timeout (`MemoryHubPreview.cloudTimeoutSeconds`). The key is set only as the header.
    static func buildRequest(provider: MemoryHubProvider, transcript: String, apiKey: String) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a trailing slash on the base URL so "…/v1" and "…/v1/" both resolve.
        guard let url = URL(string: base.hasSuffix("/") ? "\(base)chat/completions" : "\(base)/chat/completions") else {
            throw CloudTitleError.badURL
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
                ["role": "user", "content": String(transcript.prefix(6000))],
            ],
            "temperature": 0.2,
            "max_tokens": 24,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Pull `choices[0].message.content` from an OpenAI-compatible chat-completions response.
    /// Returns nil when the JSON is malformed or carries no string content.
    static func parseCompletionContent(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sanitize a raw completion into a clean title: drop surrounding quotes / placeholder
    /// tokens (`VoiceMemoParser.sanitizeTitle`), then cap to `maxWords` with an ellipsis.
    /// Reuses `MemoryHubMemoTitler.clean` so cloud titles match the heuristic/local style exactly.
    static func sanitize(_ raw: String) -> String {
        let dequoted = VoiceMemoParser.sanitizeTitle(raw, fallback: "")
        guard !dequoted.isEmpty else { return "" }
        return MemoryHubMemoTitler.clean(dequoted, maxWords: maxWords)
    }
}
