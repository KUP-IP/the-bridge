// VoiceMemoModule.swift — MCP tools for the Registry-Centric Voice Router
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP

public enum VoiceMemoModule {
    public static let moduleName = "voice"

    public static func register(on router: ToolRouter) async {
        await router.register(makeList(on: router))
        await router.register(makeProcess(on: router))
        await router.register(makeReviewList())
        await router.register(makeReviewDismiss())
        await router.register(makeReviewResolve(on: router))
        await router.register(makeTranscriptRefresh())
        await router.register(makeGet(on: router))
        await router.register(makeCommit(on: router))
    }

    private static func makeList(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_list",
            module: moduleName,
            tier: .open,
            description: "List Voice Memos recordings discovered on disk. Marks which are already processed by the morning curator job. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "includeProcessed": .object([
                        "type": .string("boolean"),
                        "description": .string("Include memos already processed (default false)."),
                    ]),
                ]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo List",
                whenToUse: ["inspect unprocessed Voice Memos before running the curator", "debug discovery paths and transcript sidecars"],
                whenNotToUse: ["routing writes — use voice_memo_process"],
                relatedTools: ["voice_memo_process"]
            ),
            handler: { args in
                var includeProcessed = false
                if case .object(let obj) = args, case .bool(let b)? = obj["includeProcessed"] { includeProcessed = b }
                let all = VoiceMemoDiscovery.listRecordings(roots: VoiceMemoDiscovery.defaultRecordingRoots())
                let rows = all.filter { includeProcessed || !VoiceMemoProcessedStore.isProcessed(id: $0.id) }
                return .object([
                    "count": .int(rows.count),
                    "memos": .array(rows.map { memo in
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
                ])
            }
        )
    }

    private static func makeProcess(on router: ToolRouter) -> ToolRegistration {
        ToolRegistration(
            name: "voice_memo_process",
            module: moduleName,
            tier: .notify,
            description: """
            Registry-centric Voice Memos curator: discover recordings → resolve transcript (sidecar → Apple tsrp → Parakeet) → parse → route intents. \
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
                    "live speech-to-text without the transcription ladder (use voice_memo_process which resolves sidecar → Apple → Parakeet)",
                    "Notion Meeting Notes AI (not API-automatable)"
                ],
                relatedTools: ["voice_memo_list", "voice_memo_review_list", "reminders_create", "registry_create", "registry_update", "memory_remember"]
            ),
            handler: { args in try await VoiceMemoProcessor.process(args: args, router: router) }
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
            description: "Force the transcription ladder for one memo (sidecar cache → Apple tsrp → Parakeet). Use forceParakeet:true to overwrite with Parakeet.",
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
            description: "Load one voice memo: transcript, parsed plan, and intent preview (read-only; no writes). Use before voice_memo_commit in agent-deferred mode.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id or absolute path."),
                    ]),
                ]),
                "required": .array([.string("memoId")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Get",
                whenToUse: ["preview routing plan before commit", "agent-deferred curator Understand step"],
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
            description: "Execute one approved intent for a voice memo (agent or operator commit after voice_memo_get). Marks processed when the write succeeds and no review is queued.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "memoId": .object([
                        "type": .string("string"),
                        "description": .string("Stable memo id or path."),
                    ]),
                    "intentKind": .object([
                        "type": .string("string"),
                        "description": .string("reminder | memory_keep | agent_memory | registry_update"),
                    ]),
                    "entityKey": .object([
                        "type": .string("string"),
                        "description": .string("Registry entity for registry_update / memory_keep override."),
                    ]),
                    "entityHint": .object([
                        "type": .string("string"),
                        "description": .string("Row title hint for registry_update."),
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
                        "description": .string("Reminder title override."),
                    ]),
                ]),
                "required": .array([.string("memoId"), .string("intentKind")]),
            ]),
            metadata: ToolMetadata(
                title: "Voice Memo Commit",
                whenToUse: ["connected MCP agent approves and executes one lane", "operator confirms Process tab preview"],
                whenNotToUse: ["unreviewed batch — use voice_memo_process"],
                relatedTools: ["voice_memo_get", "voice_memo_process", "registry_update", "memory_remember"]
            ),
            handler: { args in try await VoiceMemoProcessor.commit(args: args, router: router) }
        )
    }
}
