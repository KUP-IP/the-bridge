// VoiceMemoCloudParseTests.swift — FRONTIER cloud Understand parse (Voice Curator W2)
// TheBridge · Tests
//
// Covers the REAL frontier cloud parse rung (`MemoryHubCloudParser` +
// `CloudParseProvider`):
//  • a canned strict-JSON completion ⇒ a mapped VoiceMemoPlan with the parsed
//    summary + typed intents (provenance .cloud once the router stamps it)
//  • the WHOLE transcript is sent (a >4000-char transcript appears IN FULL in the
//    request body — NO 4000-char truncation; frontier large context)
//  • Bearer auth + /chat/completions path + 20s timeout; the key is header-only
//  • non-2xx / transport throw (timeout) / garbage JSON / zero intents ⇒ parse()
//    returns nil ⇒ the router degrades to Local/Heuristic with degraded == true
//  • a fenced ```json block is tolerated (fences stripped before JSON parse)
//  • CloudParseProvider.isAvailable() is false when the provider is disabled or
//    has no Keychain key
//
// The HTTP call is an injected `CloudChatTransport` stub — NO real socket. Provider
// config + key live in a hermetic temp home. The key is asserted NEVER in the body.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Hermetic home + stubs

private func withCloudParseTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("VoiceMemoCloudParse-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? fm.removeItem(at: tmp) }
    return try await body()
}

/// Injected cloud chat transport stub — never opens a socket. Returns a canned
/// `(Data, HTTPURLResponse)` with a chosen status, or throws to simulate a
/// network failure/timeout. Records the last request so a test can assert the
/// URL / headers / body (e.g. the WHOLE transcript made it through uncapped).
private final class StubCloudTransport: CloudChatTransport, @unchecked Sendable {
    let status: Int
    let payload: Data
    let throwError: Error?
    private(set) var lastRequest: URLRequest?

    init(status: Int = 200, json: String = "", throwError: Error? = nil) {
        self.status = status
        self.payload = Data(json.utf8)
        self.throwError = throwError
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        if let throwError { throw throwError }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (payload, response)
    }
}

/// A fully-runnable cloud provider (enabled + model + valid base URL) ⇒ `canRunCloud == true`.
private func runnableProvider(model: String = "gpt-4o-mini") -> MemoryHubProvider {
    MemoryHubProvider(id: MemoryHubProviderConfigStore.openAICompatibleId,
                      baseURL: MemoryHubProviderConfigStore.defaultBaseURL,
                      model: model, enabled: true)
}

/// Wrap an inner JSON string as the `content` of an OpenAI-compatible chat
/// completion (one choice, assistant message). `content` is JSON-escaped.
private func chatCompletionJSON(_ content: String) -> String {
    let escaped = content
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"\(escaped)\"}}]}"
}

/// A strict-JSON routing-plan body the model would emit (becomes the completion content).
private func planJSON(summary: String, intentsJSON: String) -> String {
    let escapedSummary = summary.replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"summary\":\"\(escapedSummary)\",\"intents\":\(intentsJSON)}"
}

func runVoiceMemoCloudParseTests() async {
    print("\n\u{2601}\u{FE0F}  Voice Memo Cloud Parse Tests (FRONTIER-FIRST W2)")

    // Always clear any leaked transport override.
    defer { MemoryHubCloudParser.transportOverride = nil }

    // ── success: strict JSON ⇒ mapped plan ────────────────────────────────────

    await test("cloud parse: canned strict JSON ⇒ plan with parsed summary + intents") {
        try await withCloudParseTempHome {
            let intents = """
            [{"kind":"reminder","entityKey":null,"entityHint":null,"title":"Call Bob","body":"about the deck","dueISO8601":"2026-07-01T09:00:00Z","fields":{},"confidence":0.95},
             {"kind":"memory_keep","entityKey":"memory","entityHint":null,"title":"Deck notes","body":"keep these","dueISO8601":null,"fields":{"status":"Inbox"},"confidence":0.9}]
            """
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "Plan the board deck and remind to call Bob.", intentsJSON: intents)))
            let plan = try await MemoryHubCloudParser.parse(
                transcript: "remind me to call Bob about the deck, and keep the deck notes",
                fallbackTitle: "Memo", recordingPath: "/tmp/rec.m4a",
                provider: runnableProvider(), keyProvider: { "sk-test-123" }, transport: stub)
            try expect(plan.provenance == .cloud, "the parser stamps .cloud provenance: \(plan.provenance)")
            try expect(plan.summary == "Plan the board deck and remind to call Bob.", "summary mapped: \(plan.summary)")
            try expect(plan.intents.count == 2, "both intents mapped: \(plan.intents.count)")
            try expect(plan.intents.first?.kind == .reminder, "first intent is a reminder")
            try expect(plan.intents.first?.dueISO8601 == "2026-07-01T09:00:00Z", "due date mapped")
            try expect(plan.intents.first?.confidence == 0.95, "confidence mapped: \(plan.intents.first?.confidence ?? -1)")
            let keep = plan.intents.first { $0.kind == .memoryKeep }
            try expect(keep?.entityKey == "memory", "memory_keep entityKey mapped")
            try expect(keep?.fields["status"] == "Inbox", "intent fields mapped: \(keep?.fields ?? [:])")
            try expect(plan.skipMemoryKeep == false, "a memory_keep lane ⇒ skipMemoryKeep is false")
            try expect(!plan.generatedTitle.isEmpty, "a title is derived from the summary")
        }
    }

    await test("cloud parse: NO memory_keep lane ⇒ skipMemoryKeep is true") {
        try await withCloudParseTempHome {
            let intents = """
            [{"kind":"reminder","title":"Water plants","body":null,"dueISO8601":null,"fields":{},"confidence":0.9}]
            """
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "Water the plants.", intentsJSON: intents)))
            let plan = try await MemoryHubCloudParser.parse(
                transcript: "remind me to water the plants", fallbackTitle: "Memo", recordingPath: "",
                provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            try expect(plan.skipMemoryKeep == true, "no memory_keep lane ⇒ skip is true")
            try expect(plan.intents.count == 1, "single reminder intent")
        }
    }

    // ── WHOLE transcript (no 4000 cap) ────────────────────────────────────────

    await test("cloud parse: WHOLE >4000-char transcript is sent uncapped (frontier large context)") {
        try await withCloudParseTempHome {
            // Build a >4000-char transcript with a UNIQUE sentinel near the very end
            // so any prefix(4000) truncation would drop it.
            let sentinel = "ZZ_TAIL_SENTINEL_9f3a_ZZ"
            let longBody = String(repeating: "the quarterly review went well and we shipped on time. ", count: 120)
            let transcript = longBody + " " + sentinel
            try expect(transcript.count > 4000, "transcript must exceed the old 4000 cap: \(transcript.count)")

            let intents = """
            [{"kind":"review","title":"Quarterly review","body":null,"dueISO8601":null,"fields":{},"confidence":0.7}]
            """
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "Quarterly review recap.", intentsJSON: intents)))
            _ = try await MemoryHubCloudParser.parse(
                transcript: transcript, fallbackTitle: "Memo", recordingPath: "",
                provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)

            let body = stub.lastRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try expect(body.contains(sentinel), "the TAIL of a >4000-char transcript must be in the request body (no truncation)")
            // Spot-check the length actually exceeds 4000 in the serialized body too.
            try expect(body.count > 4000, "serialized request body carries the full long transcript: \(body.count)")
        }
    }

    // ── request shape: bearer + path + timeout, key never in body ─────────────

    await test("cloud parse: POST /chat/completions, Bearer auth, 20s timeout, key header-only") {
        try await withCloudParseTempHome {
            let intents = """
            [{"kind":"review","title":"x","fields":{},"confidence":0.5}]
            """
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "s", intentsJSON: intents)))
            _ = try await MemoryHubCloudParser.parse(
                transcript: "body text", fallbackTitle: "Memo", recordingPath: "",
                provider: runnableProvider(), keyProvider: { "sk-secret" }, transport: stub)
            let req = stub.lastRequest
            try expect(req?.httpMethod == "POST", "POST request")
            try expect(req?.url?.absoluteString.hasSuffix("/chat/completions") == true,
                       "targets /chat/completions: \(String(describing: req?.url?.absoluteString))")
            try expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret", "bearer auth header")
            try expect(req?.timeoutInterval == MemoryHubPreview.cloudTimeoutSeconds, "bounded by the 20s cloud timeout")
            let body = req?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try expect(body.contains("gpt-4o-mini"), "request body carries the provider model")
            try expect(body.contains("STRICT JSON"), "request body carries the strict-JSON system prompt")
            try expect(!body.contains("sk-secret"), "the key is the header only — NEVER in the body")
        }
    }

    // ── fenced ```json tolerated ──────────────────────────────────────────────

    await test("cloud parse: a fenced ```json block is tolerated (fences stripped)") {
        try await withCloudParseTempHome {
            let inner = planJSON(
                summary: "Fenced plan.",
                intentsJSON: "[{\"kind\":\"agent_memory\",\"title\":\"note\",\"fields\":{},\"confidence\":0.8}]")
            let fenced = "```json\n\(inner)\n```"
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON(fenced))
            let plan = try await MemoryHubCloudParser.parse(
                transcript: "agents should know we shipped", fallbackTitle: "Memo", recordingPath: "",
                provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            try expect(plan.intents.count == 1, "fenced JSON mapped to one intent")
            try expect(plan.intents.first?.kind == .agentMemory, "agent_memory lane mapped from fenced block")
            try expect(plan.summary == "Fenced plan.", "summary parsed from inside the fence")
        }
    }

    // ── failure modes ⇒ throw ─────────────────────────────────────────────────

    await test("cloud parse: non-2xx ⇒ throws httpStatus") {
        try await withCloudParseTempHome {
            let stub = StubCloudTransport(status: 429, json: "{\"error\":\"rate_limited\"}")
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudParser.CloudParseError {
                threw = true
                try expect(err == .httpStatus(429), "surfaces the non-2xx status: \(err)")
            }
            try expect(threw, "non-2xx ⇒ throws (provider degrades)")
        }
    }

    await test("cloud parse: transport throw (timeout) ⇒ rethrows") {
        try await withCloudParseTempHome {
            let stub = StubCloudTransport(throwError: URLError(.timedOut))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            } catch {
                threw = true
                try expect((error as? URLError)?.code == .timedOut, "rethrows the transport timeout: \(error)")
            }
            try expect(threw, "a transport timeout ⇒ throws (provider degrades)")
        }
    }

    await test("cloud parse: garbage (non-JSON) content ⇒ throws unparseable") {
        try await withCloudParseTempHome {
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON("this is not json at all"))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudParser.CloudParseError {
                threw = true
                try expect(err == .unparseable, "garbage content ⇒ unparseable: \(err)")
            }
            try expect(threw, "garbage JSON ⇒ throws (provider degrades)")
        }
    }

    await test("cloud parse: empty intents array ⇒ throws (zero usable intents)") {
        try await withCloudParseTempHome {
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "nothing actionable", intentsJSON: "[]")))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudParser.CloudParseError {
                threw = true
                // mapPlan returns nil when intents are empty ⇒ .unparseable
                // (or .noIntents if a future map keeps the array but drops all rows).
                try expect(err == .unparseable || err == .noIntents, "empty intents ⇒ throws: \(err)")
            }
            try expect(threw, "zero intents ⇒ throws (provider degrades)")
        }
    }

    await test("cloud parse: only-unknown-lane intents ⇒ throws (all dropped)") {
        try await withCloudParseTempHome {
            // A lane the taxonomy doesn't know is dropped by the mapper; if that
            // leaves zero intents, the parse throws so the chain degrades.
            let intents = "[{\"kind\":\"teleport\",\"title\":\"x\",\"fields\":{},\"confidence\":0.9}]"
            let stub = StubCloudTransport(status: 200,
                json: chatCompletionJSON(planJSON(summary: "s", intentsJSON: intents)))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { "sk-test" }, transport: stub)
            } catch {
                threw = true
            }
            try expect(threw, "all-unknown-lane ⇒ zero mapped intents ⇒ throws")
        }
    }

    await test("cloud parse: missing key ⇒ throws missingKey (no transport call)") {
        try await withCloudParseTempHome {
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON(planJSON(summary: "s", intentsJSON: "[]")))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: runnableProvider(), keyProvider: { nil }, transport: stub)
            } catch let err as MemoryHubCloudParser.CloudParseError {
                threw = true
                try expect(err == .missingKey, "no key ⇒ missingKey: \(err)")
            }
            try expect(threw, "missing key ⇒ throws before any send")
            try expect(stub.lastRequest == nil, "transport must NOT be called without a key")
        }
    }

    await test("cloud parse: disabled provider ⇒ throws notRunnable") {
        try await withCloudParseTempHome {
            let disabled = MemoryHubProvider(id: MemoryHubProviderConfigStore.openAICompatibleId,
                                             baseURL: MemoryHubProviderConfigStore.defaultBaseURL,
                                             model: "gpt-4o-mini", enabled: false)
            let stub = StubCloudTransport(status: 200, json: chatCompletionJSON(planJSON(summary: "s", intentsJSON: "[]")))
            var threw = false
            do {
                _ = try await MemoryHubCloudParser.parse(
                    transcript: "t", fallbackTitle: "Memo", recordingPath: "",
                    provider: disabled, keyProvider: { "sk-test" }, transport: stub)
            } catch let err as MemoryHubCloudParser.CloudParseError {
                threw = true
                try expect(err == .notRunnable, "disabled provider ⇒ notRunnable: \(err)")
            }
            try expect(threw, "disabled provider ⇒ throws (provider unavailable)")
        }
    }

    // ── CloudParseProvider availability + degrade integration ─────────────────

    await test("CloudParseProvider.isAvailable() false: no provider configured") {
        try await withCloudParseTempHome {
            // Hermetic home: no providers.json written ⇒ load().first == nil.
            try expect(!CloudParseProvider().isAvailable(), "no configured provider ⇒ unavailable")
        }
    }

    await test("CloudParseProvider.isAvailable() false: provider enabled but no Keychain key") {
        try await withCloudParseTempHome {
            try MemoryHubProviderConfigStore.upsert(runnableProvider())
            // No saveKey ⇒ keyConfigured == false ⇒ unavailable even though canRunCloud is true.
            try expect(MemoryHubProviderConfigStore.canRunCloud(runnableProvider()), "config is runnable")
            try expect(!CloudParseProvider().isAvailable(), "runnable config but no key ⇒ unavailable")
        }
    }

    await test("CloudParseProvider.isAvailable() false: key present but provider disabled") {
        try await withCloudParseTempHome {
            let disabled = MemoryHubProvider(id: MemoryHubProviderConfigStore.openAICompatibleId,
                                             baseURL: MemoryHubProviderConfigStore.defaultBaseURL,
                                             model: "gpt-4o-mini", enabled: false)
            try MemoryHubProviderConfigStore.upsert(disabled)
            _ = MemoryHubProviderConfigStore.saveKey(providerId: disabled.id, apiKey: "sk-test")
            defer { _ = MemoryHubProviderConfigStore.deleteKey(providerId: disabled.id) }
            try expect(!CloudParseProvider().isAvailable(), "key present but disabled ⇒ unavailable")
        }
    }

    await test("router degrades to heuristic when the REAL cloud rung fails at runtime") {
        // Router↔parser integration: the cloud rung wraps the REAL
        // `MemoryHubCloudParser` (with an injected key + a non-2xx transport), so
        // its parse() returns nil; the router must fall PAST the available cloud
        // rung to the heuristic floor and mark the plan degraded. Driven through
        // the PUBLIC parse() API. Key is injected (NOT the Keychain) so this is
        // hermetic and order-independent.
        VoiceMemoParseRouter.providerOverride = { _ in [
            RealCloudParserRung(transport: StubCloudTransport(status: 500, json: "{}")),
            HeuristicParseProvider(),
        ] }
        defer { VoiceMemoParseRouter.providerOverride = nil }
        let plan = await withCuratorModeLocal(.cloud) {
            await VoiceMemoParseRouter.parse(transcript: "remind me to ship the build", fallbackTitle: "Memo")
        }
        try expect(plan.provenance == .heuristic, "fell through to heuristic floor: \(plan.provenance)")
        try expect(plan.degraded == true, "an AVAILABLE cloud rung returned nil ⇒ degraded")
        try expect(!plan.intents.isEmpty, "heuristic floor still yields intents")
    }

    await test("router uses the REAL cloud plan when the transport succeeds") {
        // Happy path: the cloud rung wraps the REAL `MemoryHubCloudParser` over a
        // 2xx strict-JSON completion ⇒ the router returns the CLOUD plan with the
        // parser's mapped summary/intents, provenance .cloud, not degraded.
        let intents = "[{\"kind\":\"reminder\",\"title\":\"Ship build\",\"fields\":{},\"confidence\":0.95}]"
        let okTransport = StubCloudTransport(status: 200,
            json: chatCompletionJSON(planJSON(summary: "Ship the build today.", intentsJSON: intents)))
        VoiceMemoParseRouter.providerOverride = { _ in [
            RealCloudParserRung(transport: okTransport),
            HeuristicParseProvider(),
        ] }
        defer { VoiceMemoParseRouter.providerOverride = nil }
        let plan = await withCuratorModeLocal(.cloud) {
            await VoiceMemoParseRouter.parse(transcript: "remind me to ship the build", fallbackTitle: "Memo")
        }
        try expect(plan.provenance == .cloud, "cloud success ⇒ .cloud provenance: \(plan.provenance)")
        try expect(plan.degraded == false, "cloud won on the first rung ⇒ not degraded")
        try expect(plan.summary == "Ship the build today.", "the cloud plan's summary is returned")
        try expect(plan.intents.first?.kind == .reminder, "the cloud plan's intents are returned")
    }

    // ── CloudParseProvider availability with REAL provider config + Keychain ───
    // (Kept separate from the router-integration tests so a Keychain hiccup can't
    //  mask the router behavior. Asserts the production isAvailable() wiring.)

    await test("CloudParseProvider.isAvailable() true with configured provider + saved Keychain key") {
        try await withCloudParseTempHome {
            try MemoryHubProviderConfigStore.upsert(runnableProvider())
            let saved = MemoryHubProviderConfigStore.saveKey(
                providerId: MemoryHubProviderConfigStore.openAICompatibleId, apiKey: "sk-test")
            defer { _ = MemoryHubProviderConfigStore.deleteKey(providerId: MemoryHubProviderConfigStore.openAICompatibleId) }
            // Guard the Keychain precondition explicitly: if the harness Keychain is
            // unavailable, skip the availability assertion rather than flake.
            guard saved, MemoryHubProviderConfigStore.keyConfigured(providerId: MemoryHubProviderConfigStore.openAICompatibleId) else {
                print("    ⏭️  Keychain unavailable in this harness — skipping isAvailable() positive assertion")
                return
            }
            try expect(CloudParseProvider().isAvailable(), "configured provider + saved key ⇒ available")
        }
    }
}

/// A router rung that drives the REAL `MemoryHubCloudParser` with an INJECTED key
/// (no Keychain) + an injected transport. Available iff a transport is set. Used to
/// prove the router↔parser integration (map + degrade) hermetically — the
/// production gate (`CloudParseProvider.isAvailable`) is asserted separately with a
/// real provider config + Keychain.
private struct RealCloudParserRung: VoiceMemoParseProvider {
    let transport: CloudChatTransport
    var provenance: ParseProvenance { .cloud }
    func isAvailable() -> Bool { true }
    func parse(transcript: String, fallbackTitle: String, recordingPath: String) async -> VoiceMemoPlan? {
        try? await MemoryHubCloudParser.parse(
            transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath,
            provider: runnableProvider(), keyProvider: { "sk-test" }, transport: transport)
    }
}

/// Set the curator mode in UserDefaults for the duration of `body`, then restore.
/// Returns the body's value. (File-scoped copy of the chain-suite helper; here we
/// drive the PUBLIC `VoiceMemoParseRouter.parse` API rather than the internal
/// `walk`. Ollama routing is forced OFF so the Local rung is deterministically
/// unavailable regardless of suite order.)
private func withCuratorModeLocal<T>(_ mode: VoiceMemoCuratorMode, _ body: () async -> T) async -> T {
    let modeKey = BridgeDefaults.voiceMemoCuratorMode
    let ollamaKey = BridgeDefaults.voiceMemoOllamaRouting
    let priorMode = UserDefaults.standard.string(forKey: modeKey)
    let priorOllama = UserDefaults.standard.object(forKey: ollamaKey)
    UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    UserDefaults.standard.set(false, forKey: ollamaKey)
    defer {
        if let priorMode { UserDefaults.standard.set(priorMode, forKey: modeKey) }
        else { UserDefaults.standard.removeObject(forKey: modeKey) }
        if let priorOllama { UserDefaults.standard.set(priorOllama, forKey: ollamaKey) }
        else { UserDefaults.standard.removeObject(forKey: ollamaKey) }
    }
    return await body()
}
