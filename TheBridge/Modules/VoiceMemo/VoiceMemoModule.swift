// VoiceMemoModule.swift — MCP tools for the Registry-Centric Voice Router
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP

public enum VoiceMemoModule {
    public static let moduleName = "voice"

    /// Hermetic seam for MCP settings-tool tests. Production always uses
    /// `UserDefaults.standard`; tests supply a unique suite and restore nil.
    nonisolated(unsafe) public static var settingsDefaultsOverrideForTesting: UserDefaults?

    public static func register(on router: ToolRouter) async {
        await router.register(makeList(on: router))
        await router.register(makeProcess(on: router))
        await router.register(makeSettingsGet())
        await router.register(makeSettingsSet())
        await router.register(makeReviewList())
        await router.register(makeReviewDismiss())
        await router.register(makeReviewResolve(on: router))
        await router.register(makeTranscriptRefresh())
        await router.register(makeGet(on: router))
        await router.register(makeCommit(on: router))
        await router.register(makeTriageOpen())
        await router.register(makeTriageAwait())
    }

    private static func makeList(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_list",
            module: moduleName,
            tier: .open,
            description: "List Voice Memos recordings discovered on disk with optional date/transcript/processed filters, limit/cursor pagination, and curator/backlog health. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "includeProcessed": .object([
                        "type": .string("boolean"),
                        "description": .string("Include memos already processed (default false)."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Max memos to return (default 50, max 500)."),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string("Opaque pagination cursor from a prior nextCursor."),
                    ]),
                    "dateFrom": .object([
                        "type": .string("string"),
                        "description": .string("ISO-8601 lower bound on recordedAt (inclusive)."),
                    ]),
                    "dateTo": .object([
                        "type": .string("string"),
                        "description": .string("ISO-8601 upper bound on recordedAt (inclusive)."),
                    ]),
                    "hasTranscript": .object([
                        "type": .string("boolean"),
                        "description": .string("When set, only memos with/without a transcript body."),
                    ]),
                    "transcriptContains": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring match against title + known transcript text."),
                    ]),
                    "sort": .object([
                        "type": .string("string"),
                        "description": .string("recordedAt_desc (default) or recordedAt_asc."),
                    ]),
                    "includeHealth": .object([
                        "type": .string("boolean"),
                        "description": .string("Include curator job status + backlog counts (default true)."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo List",
                whenToUse: [
                    "inspect unprocessed Voice Memos before running the curator",
                    "date-scoped triage without downloading the full backlog",
                    "debug discovery paths and transcript sidecars",
                ],
                whenNotToUse: ["routing writes — use voice_memo_process"],
                relatedTools: ["voice_memo_process", "voice_memo_settings_get"]
            ),
            handler: { args in
                let obj: [String: Value]
                if case .object(let o) = args { obj = o } else { obj = [:] }

                var query = VoiceMemoListQuery()
                if case .bool(let b)? = obj["includeProcessed"] { query.includeProcessed = b }
                if case .int(let n)? = obj["limit"] { query.limit = n }
                if case .double(let d)? = obj["limit"] { query.limit = Int(d) }
                if case .string(let c)? = obj["cursor"] { query.cursor = c }
                if case .bool(let b)? = obj["hasTranscript"] { query.hasTranscript = b }
                if case .string(let s)? = obj["transcriptContains"] { query.transcriptContains = s }
                if case .string(let sort)? = obj["sort"] {
                    query.sortAscending = sort.lowercased().contains("asc")
                }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let isoBasic = ISO8601DateFormatter()
                if case .string(let from)? = obj["dateFrom"] {
                    query.dateFrom = iso.date(from: from) ?? isoBasic.date(from: from)
                }
                if case .string(let to)? = obj["dateTo"] {
                    query.dateTo = iso.date(from: to) ?? isoBasic.date(from: to)
                }
                var includeHealth = true
                if case .bool(let b)? = obj["includeHealth"] { includeHealth = b }

                let all = VoiceMemoDiscovery.listRecordings(roots: VoiceMemoDiscovery.defaultRecordingRoots())
                let page = VoiceMemoListFilter.page(recordings: all, query: query)

                var result: [String: Value] = [
                    "count": .int(page.memos.count),
                    "totalMatched": .int(page.totalMatched),
                    "hasMore": .bool(page.hasMore),
                    "memos": .array(page.memos.map { memo in
                        .object([
                            "id": .string(memo.id),
                            "title": .string(memo.title),
                            "path": .string(memo.path),
                            "recordedAt": .string(ISO8601DateFormatter().string(from: memo.recordedAt)),
                            "hasTranscript": .bool(memo.hasTranscript),
                            "transcriptSource": .string(memo.transcriptSource.rawValue),
                            "processed": .bool(VoiceMemoProcessedStore.isProcessed(id: memo.id)),
                        ])
                    }),
                ]
                if let next = page.nextCursor { result["nextCursor"] = .string(next) }

                if includeHealth {
                    let unprocessed = all.filter { !VoiceMemoProcessedStore.isProcessed(id: $0.id) }.count
                    let pendingReview = VoiceMemoReviewStore.pendingEntries().count
                    result["health"] = .object([
                        "unprocessedCount": .int(unprocessed),
                        "pendingReviewCount": .int(pendingReview),
                        "backlogHealthy": .bool(unprocessed < 50),
                    ])
                }
                return .object(result)
            }
        )
    }

    private static func makeProcess(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_process",
            module: moduleName,
            tier: .notify,
            description: """
            Registry-centric Voice Memos curator: discover recordings → resolve transcript (sidecar → Apple tsrp → SpeechAnalyzer opt-in → Parakeet) → parse → route intents. \
            Lanes: reminder (Apple Reminders), memory_keep (Notion Memory registry entity), agent_memory (memory_remember), \
            registry_update (contact/project/packet). Skips memory_keep when the memo says not to create a memory. \
            Idempotent via processed manifest. Use dryRun:true to preview without writes.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "description": .string("batch (default: unprocessed only) or single"),
                    ]),
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Process one memo by stable id or path."),
                    ]),
                    "dryRun": .object([
                        "type": .string("boolean"),
                        "description": .string("Preview routing without writes (default false)."),
                    ]),
                    "minConfidence": .object([
                        "type": .string("number"),
                        "description": .string("Minimum intent confidence for auto-write (default 0.85)."),
                    ]),
                    "recordingsRoot": .object([
                        "type": .string("string"),
                        "description": .string("Optional override path to scan for Voice Memos recordings (testing / custom install)."),
                    ]),
                    "forceReprocess": .object([
                        "type": .string("boolean"),
                        "description": .string("Re-run even if the memo is in processed.json (default false)."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Process",
                whenToUse: [
                    "morning batch processing of Voice Memos into Keep OS registry lanes",
                    "route a memo to reminders, memory_keep, or entity updates without storing full transcripts"
                ],
                whenNotToUse: [
                    "live speech-to-text without the transcription ladder (use voice_memo_process which resolves sidecar → Apple → SpeechAnalyzer → Parakeet)",
                    "Notion Meeting Notes AI (not API-automatable)"
                ],
                relatedTools: ["voice_memo_list", "voice_memo_review_list", "reminders_create", "registry_create", "registry_update", "memory_remember"]
            ),
            handler: { args in try await VoiceMemoProcessor.process(args: args, router: router) }
        )
    }

    private static func settingsSnapshot(
        defaults: UserDefaults,
        useProductionEffectiveAccessors: Bool
    ) -> Value {
        let rawMode = defaults.string(forKey: BridgeDefaults.voiceMemoCuratorMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let curatorMode: VoiceMemoCuratorMode = {
            if rawMode == "local" { return .heuristics }
            return rawMode.flatMap(VoiceMemoCuratorMode.init(rawValue:)) ?? .auto
        }()

        let appleTranscript = useProductionEffectiveAccessors
            ? BridgeDefaults.voiceMemoAppleTranscriptEffective
            : (defaults.object(forKey: BridgeDefaults.voiceMemoAppleTranscript) == nil
                ? true
                : defaults.bool(forKey: BridgeDefaults.voiceMemoAppleTranscript))
        let parakeetTranscription = useProductionEffectiveAccessors
            ? BridgeDefaults.voiceMemoParakeetTranscriptionEffective
            : (defaults.object(forKey: BridgeDefaults.voiceMemoParakeetTranscription) == nil
                ? true
                : defaults.bool(forKey: BridgeDefaults.voiceMemoParakeetTranscription))
        let speechAnalyzerTranscription = useProductionEffectiveAccessors
            ? BridgeDefaults.voiceMemoSpeechAnalyzerTranscriptionEffective
            : defaults.bool(forKey: BridgeDefaults.voiceMemoSpeechAnalyzerTranscription)

        return .object([
            "curatorMode": .string(curatorMode.rawValue),
            "appleTranscript": .bool(appleTranscript),
            "speechAnalyzerTranscription": .bool(speechAnalyzerTranscription),
            "parakeetTranscription": .bool(parakeetTranscription),
        ])
    }

    private static func settingsContext() -> (defaults: UserDefaults, production: Bool) {
        if let override = settingsDefaultsOverrideForTesting {
            return (override, false)
        }
        return (.standard, true)
    }

    private static func makeSettingsGet() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_settings_get",
            module: moduleName,
            tier: .open,
            description: "Read the effective Voice Memo curator mode and transcription/routing toggles. Returns curatorMode, appleTranscript, speechAnalyzerTranscription, and parakeetTranscription.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Settings Get",
                whenToUse: ["inspect the effective curator routing and transcription ladder settings"],
                whenNotToUse: ["change settings — use voice_memo_settings_set"],
                relatedTools: ["voice_memo_settings_set", "voice_memo_process"]
            ),
            handler: { _ in
                let context = settingsContext()
                return settingsSnapshot(
                    defaults: context.defaults,
                    useProductionEffectiveAccessors: context.production)
            }
        )
    }

    private static func makeSettingsSet() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_settings_set",
            module: moduleName,
            tier: .notify,
            description: "Partially update Voice Memo curator settings. Valid curatorMode values come from VoiceMemoCuratorMode.allCases; omitted keys are unchanged. Returns the complete post-write effective snapshot.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "curatorMode": .object([
                        "type": .string("string"),
                        "description": .string("Curator mode: auto | heuristics | agent | cloud."),
                    ]),
                    "appleTranscript": .object([
                        "type": .string("boolean"),
                        "description": .string("Use Apple embedded transcript before fallback transcription."),
                    ]),
                    "speechAnalyzerTranscription": .object([
                        "type": .string("boolean"),
                        "description": .string("Use SpeechAnalyzer between Apple tsrp and Parakeet (default false)."),
                    ]),
                    "parakeetTranscription": .object([
                        "type": .string("boolean"),
                        "description": .string("Use Parakeet as the transcription fallback."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Settings Set",
                whenToUse: ["change one or more curator routing or transcription ladder settings"],
                whenNotToUse: ["read settings without changing them — use voice_memo_settings_get"],
                relatedTools: ["voice_memo_settings_get", "voice_memo_process"]
            ),
            handler: { arguments in
                guard case .object(let args) = arguments else {
                    return .object([
                        "error": .string("Expected an object of optional Voice Memo settings."),
                        "code": .string("invalid_input"),
                    ])
                }

                let validModes = VoiceMemoCuratorMode.allCases.map(\.rawValue)
                var requestedMode: VoiceMemoCuratorMode?
                if let value = args["curatorMode"] {
                    guard case .string(let raw) = value else {
                        return .object([
                            "error": .string("curatorMode must be a string. Valid values: \(validModes.joined(separator: ", "))."),
                            "code": .string("invalid_input"),
                            "validValues": .array(validModes.map(Value.string)),
                        ])
                    }
                    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard let mode = VoiceMemoCuratorMode(rawValue: normalized) else {
                        return .object([
                            "error": .string("Unknown curatorMode '\(raw)'. Valid values: \(validModes.joined(separator: ", "))."),
                            "code": .string("invalid_input"),
                            "validValues": .array(validModes.map(Value.string)),
                        ])
                    }
                    requestedMode = mode
                }

                var requestedBooleans: [(key: String, defaultsKey: String, value: Bool)] = []
                for (key, defaultsKey) in [
                    ("appleTranscript", BridgeDefaults.voiceMemoAppleTranscript),
                    ("speechAnalyzerTranscription", BridgeDefaults.voiceMemoSpeechAnalyzerTranscription),
                    ("parakeetTranscription", BridgeDefaults.voiceMemoParakeetTranscription),
                ] {
                    guard let value = args[key] else { continue }
                    guard case .bool(let boolValue) = value else {
                        return .object([
                            "error": .string("\(key) must be a boolean."),
                            "code": .string("invalid_input"),
                        ])
                    }
                    requestedBooleans.append((key, defaultsKey, boolValue))
                }

                // Validate the complete request before writing any key.
                let context = settingsContext()
                if let requestedMode {
                    context.defaults.set(requestedMode.rawValue, forKey: BridgeDefaults.voiceMemoCuratorMode)
                }
                for request in requestedBooleans {
                    context.defaults.set(request.value, forKey: request.defaultsKey)
                }
                return settingsSnapshot(
                    defaults: context.defaults,
                    useProductionEffectiveAccessors: context.production)
            }
        )
    }

    private static func makeReviewList() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_review_list",
            module: moduleName,
            tier: .open,
            description: "List voice memos queued for operator review (low confidence, failures, or missing transcripts). Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "includeDismissed": .object([
                        "type": .string("boolean"),
                        "description": .string("Include dismissed entries (default false)."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Review List",
                whenToUse: ["inspect review.json after a curator batch", "remediation before re-running voice_memo_process"],
                whenNotToUse: ["routing writes — use voice_memo_process or voice_memo_review_dismiss"],
                relatedTools: ["voice_memo_process", "voice_memo_review_dismiss", "voice_memo_review_resolve"]
            ),
            handler: { args in
                var includeDismissed = false
                if case .object(let obj) = args, case .bool(let b)? = obj["includeDismissed"] { includeDismissed = b }
                let manifest = VoiceMemoReviewStore.load()
                let rows = manifest.entries.filter { includeDismissed || $0.status == .pending }
                return .object([
                    "pendingCount": .int(manifest.pendingCount),
                    "count": .int(rows.count),
                    "entries": .array(rows.map { VoiceMemoReviewStore.entryValue($0) }),
                    "manifestPath": .string(VoiceMemoReviewStore.manifestURL.path),
                ])
            }
        )
    }

    private static func makeReviewDismiss() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_review_dismiss",
            module: moduleName,
            tier: .notify,
            description: "Dismiss a pending voice memo review entry by id (does not re-run routing).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Review entry id from voice_memo_review_list."),
                    ]),
                ]),
                "required": .array([.string("id")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Review Dismiss",
                whenToUse: ["clear a review item after manual remediation"],
                whenNotToUse: ["auto-routing — use voice_memo_process"],
                relatedTools: ["voice_memo_review_list", "voice_memo_process", "voice_memo_review_resolve"]
            ),
            handler: { args in
                guard case .object(let obj) = args,
                      case .string(let id) = obj["id"] else {
                    throw ToolRouterError.invalidArguments(toolName: "voice_memo_review_dismiss", reason: "missing id")
                }
                let ok = try VoiceMemoReviewStore.dismiss(id: id)
                return .object([
                    "dismissed": .bool(ok),
                    "id": .string(id),
                    "pendingCount": .int(VoiceMemoReviewStore.pendingEntries().count),
                ])
            }
        )
    }

    private static func makeReviewResolve(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_review_resolve",
            module: moduleName,
            tier: .notify,
            description: """
            Resolve a pending voice memo review entry with a disposition: memory_keep (Notion Memory + transcript), \
            reminder, agent_remember, registry_update, retry_routing (re-run Ollama/heuristics without re-transcribe), \
            or mark_handled (processed.json only). Idempotent memory_keep blocks duplicate writes unless force:true.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Review entry id from voice_memo_review_list."),
                    ]),
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("memory_keep | reminder | agent_remember | registry_update | retry_routing | mark_handled"),
                    ]),
                    "force": .object([
                        "type": .string("boolean"),
                        "description": .string("Allow duplicate memory_keep for an already-processed memo (default false)."),
                    ]),
                    "entity": .object([
                        "type": .string("string"),
                        "description": .string("Registry entity key for registry_update / memory_keep override."),
                    ]),
                    "rowId": .object([
                        "type": .string("string"),
                        "description": .string("Registry row id for registry_update when hint matching is insufficient."),
                    ]),
                    "entityHint": .object([
                        "type": .string("string"),
                        "description": .string("Title hint for registry_update row matching."),
                    ]),
                    "fields": .object([
                        "type": .string("object"),
                        "description": .string("Registry field map for memory_keep / registry_update / agent_remember scope."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Reminder title override."),
                    ]),
                    "due": .object([
                        "type": .string("string"),
                        "description": .string("Reminder due ISO-8601 override."),
                    ]),
                    "minConfidence": .object([
                        "type": .string("number"),
                        "description": .string("Minimum confidence for retry_routing auto-execute (default 0.85)."),
                    ]),
                ]),
                "required": .array([.string("id"), .string("action")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Review Resolve",
                whenToUse: [
                    "File as Memory from the review inbox",
                    "retry Ollama routing without re-transcribing",
                    "mark a memo handled without creating external writes"
                ],
                whenNotToUse: ["clear review without action — use voice_memo_review_dismiss"],
                relatedTools: ["voice_memo_review_list", "voice_memo_review_dismiss", "voice_memo_transcript_refresh", "registry_create", "memory_remember"]
            ),
            handler: { args in try await VoiceMemoReviewResolver.resolve(args: args, router: router) }
        )
    }

    private static func makeTranscriptRefresh() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_transcript_refresh",
            module: moduleName,
            tier: .notify,
            description: "Force the transcription ladder for one memo (sidecar cache → Apple tsrp → SpeechAnalyzer → Parakeet). Use forceParakeet:true to overwrite with Parakeet. Returns the resolved transcript `source`.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id or absolute path."),
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the audio file."),
                    ]),
                    "forceParakeet": .object([
                        "type": .string("boolean"),
                        "description": .string("Skip cache/Apple and re-transcribe with Parakeet (default false)."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Transcript Refresh",
                whenToUse: ["re-run transcription for a memo stuck in review with no transcript sidecar"],
                whenNotToUse: ["routing-only retry — use voice_memo_review_resolve action retry_routing"],
                relatedTools: ["voice_memo_process", "voice_memo_review_resolve", "voice_memo_list"]
            ),
            handler: { args in try await VoiceMemoReviewResolver.refreshTranscript(args: args) }
        )
    }

    private static func makeGet(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_get",
            module: moduleName,
            tier: .open,
            description: """
            Load one voice memo: transcript, parsed plan, and intent preview (read-only; no writes). \
            The returned plan.intents array may contain more than one committable intent (e.g. a reminder \
            AND a memory_keep from the same memo) — this is normal, not an edge case. Use before \
            voice_memo_commit in agent-deferred mode.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id or absolute path."),
                    ]),
                    "understand": .object([
                        "type": .string("boolean"),
                        "description": .string("When true (default), run transcription + Understand + plan. When false, inspect cached transcript only."),
                    ]),
                    "provider": .object([
                        "type": .string("string"),
                        "description": .string("Optional curator override for Understand: local | cloud | auto | heuristics."),
                    ]),
                ]),
                "required": .array([.string("memoId")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Get",
                whenToUse: [
                    "preview routing plan before commit",
                    "agent-deferred curator Understand step",
                    "inspect a plan with multiple intents before committing each one via voice_memo_commit"
                ],
                whenNotToUse: ["batch auto-execute — use voice_memo_process"],
                relatedTools: ["voice_memo_commit", "voice_memo_process", "voice_memo_list"]
            ),
            handler: { args in try await VoiceMemoProcessor.get(args: args, router: router) }
        )
    }

    private static func makeCommit(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_commit",
            module: moduleName,
            tier: .notify,
            description: """
            Execute one approved intent for a voice memo (agent or operator commit after voice_memo_get). \
            Calling this multiple times for the same memoId with different intentKind values — one commit \
            call per intent — is normal, expected agent-mode behavior, not an edge case: it mirrors the \
            Memory Hub UI's batch-confirm cockpit, where an operator can confirm several lanes (reminder, \
            memory_keep, agent_memory, registry_update) from one memo. Marks processed when the write \
            succeeds and no review is queued. For intentKind=memory_keep, pass `summary` with a real, \
            substantive summary whenever the auto-generated one looks like a weak transcript fragment — \
            a summary that is too short or filler-dominated fails the minimum-information quality gate and \
            routes to the review queue instead of writing an incomplete Memory record.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id or path."),
                    ]),
                    "intentKind": .object([
                        "type": .string("string"),
                        "description": .string("reminder | memory_keep | agent_memory | registry_update | comment"),
                    ]),
                    "entityKey": .object([
                        "type": .string("string"),
                        "description": .string("Registry entity for registry_update / memory_keep / comment override."),
                    ]),
                    "entityHint": .object([
                        "type": .string("string"),
                        "description": .string("Row title hint for registry_update / comment target-page resolution."),
                    ]),
                    "rowId": .object([
                        "type": .string("string"),
                        "description": .string("Registry row id when hint matching is insufficient."),
                    ]),
                    "fields": .object([
                        "type": .string("object"),
                        "description": .string("Field map override for registry lanes."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Memory title for intentKind=memory_keep (wins over fields.title). Reminder title override; also the comment text fallback when body is unset."),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Comment text for intentKind=comment (preferred over title)."),
                    ]),
                    "summary": .object([
                        "type": .string("string"),
                        "description": .string("Substantive summary override for intentKind=memory_keep — replaces the heuristic summary in the Notion Memory page body. It is mirrored to a registry summary property only when that property is rich_text; select/status-backed fields such as Relevant never receive prose. Recommended whenever the auto-generated summary is a weak transcript fragment; must clear the minimum-information quality gate (non-filler, not too short) or the commit is routed to the review queue instead of being written."),
                    ]),
                    "purpose": .object([
                        "type": .string("string"),
                        "description": .string("Required for intentKind=comment: idea (ledger-tracked) | reflow (fire-and-forget, never logged)."),
                    ]),
                ]),
                "required": .array([.string("memoId"), .string("intentKind")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Commit",
                whenToUse: [
                    "connected MCP agent approves and executes one lane",
                    "operator confirms Process tab preview",
                    "call once per intentKind — repeated calls for the same memoId across multiple intents is expected, not exceptional"
                ],
                whenNotToUse: ["unreviewed batch — use voice_memo_process"],
                relatedTools: ["voice_memo_get", "voice_memo_process", "registry_update", "memory_remember"]
            ),
            handler: { args in try await VoiceMemoProcessor.commit(args: args, router: router) }
        )
    }

    // MARK: - PKT-MEM-122 triage session

    private static func makeTriageOpen() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_triage_open",
            module: moduleName,
            tier: .open,
            description: """
            Open an operator triage session for one voice memo: focuses Settings → Memory → Process, selects the memo, \
            and returns a sessionHandle for voice_memo_triage_await. Requires a connected HTTP/SSE MCP client (stdio-only \
            sessions cannot open triage). Bridge executes UI commits — do not call voice_memo_commit after a committed event.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id from voice_memo_list."),
                    ]),
                ]),
                "required": .array([.string("memoId")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Triage Open",
                whenToUse: ["agent defers commit to operator UI", "paired with voice_memo_triage_await"],
                whenNotToUse: ["direct commit — use voice_memo_commit", "stdio MCP transport"],
                relatedTools: ["voice_memo_triage_await", "voice_memo_get", "bridge_settings_navigate"]
            ),
            handler: { args in
                guard case .object(let obj) = args,
                      case .string(let memoId) = obj["memoId"],
                      !memoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .object([
                        "error": .string("memoId is required (string)"),
                        "code": .string("invalid_input"),
                    ])
                }
                do {
                    let opened = try await TriageSessionStore.shared.open(memoId: memoId)
                    let anchor = "process/\(memoId)"
                    await BridgeSettingsAutomation.navigate(to: .memory, anchor: anchor)
                    await BridgeSettingsAutomation.applyMemoryNavigationSideEffects(anchor: anchor)
                    _ = await BridgeSettingsAutomation.focusSettings(openIfNeeded: true)
                    return .object([
                        "sessionHandle": .string(opened.sessionId),
                        "memoId": .string(memoId),
                        "openerClientId": .string(opened.openerClientId),
                    ])
                } catch TriageSessionError.stdioOnlyOpener {
                    return .object([
                        "error": .string("Triage requires a connected HTTP/SSE MCP client (stdio-only opener rejected)."),
                        "code": .string("stdio_only"),
                    ])
                } catch TriageSessionError.sessionAlreadyOpen(let mid) {
                    return .object([
                        "error": .string("Triage session already open for memo \(mid)."),
                        "code": .string("session_already_open"),
                        "memoId": .string(mid),
                    ])
                } catch {
                    return .object([
                        "error": .string(error.localizedDescription),
                        "code": .string("triage_open_failed"),
                    ])
                }
            }
        )
    }

    private static func makeTriageAwait() -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_triage_await",
            module: moduleName,
            tier: .open,
            description: """
            Block until the operator completes triage in the UI (commit, end session, or timeout). Returns a structured event: \
            committed (Bridge already ran commit — do NOT call voice_memo_commit), sessionEnded, or timeout. Default timeout 1800s.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionHandle": .object([
                        "type": .string("string"),
                        "description": .string("Session id from voice_memo_triage_open."),
                    ]),
                    "timeoutSeconds": .object([
                        "type": .string("integer"),
                        "description": .string("Max wait in seconds (default 1800, max 1800)."),
                    ]),
                ]),
                "required": .array([.string("sessionHandle")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Triage Await",
                whenToUse: ["after voice_memo_triage_open while operator acts in Process UI"],
                whenNotToUse: ["without an open session", "re-commit after committed event"],
                relatedTools: ["voice_memo_triage_open", "voice_memo_get"]
            ),
            handler: { args in
                guard case .object(let obj) = args,
                      case .string(let handle) = obj["sessionHandle"],
                      !handle.isEmpty else {
                    return .object([
                        "error": .string("sessionHandle is required (string)"),
                        "code": .string("invalid_input"),
                    ])
                }
                var timeout = 1800
                if case .int(let t)? = obj["timeoutSeconds"] { timeout = t }
                if case .double(let t)? = obj["timeoutSeconds"] { timeout = Int(t) }
                let event = await TriageSessionStore.shared.awaitEvent(sessionId: handle, timeoutSeconds: timeout)
                return .object([
                    "event": TriageSessionMCP.eventValue(event),
                ])
            }
        )
    }
}
