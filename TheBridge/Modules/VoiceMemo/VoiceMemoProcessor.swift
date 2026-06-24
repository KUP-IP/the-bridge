// VoiceMemoProcessor.swift — orchestrates discover → parse → route → receipt
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP

public enum VoiceMemoProcessor {

    public struct Options: Sendable {
        public var mode: String
        public var memoId: String?
        public var dryRun: Bool
        public var forceReprocess: Bool
        public var minConfidence: Double
        public var recordingRoots: [URL]
        public var transcriptLoader: @Sendable (URL) -> String?

        public init(
            mode: String = "batch",
            memoId: String? = nil,
            dryRun: Bool = false,
            forceReprocess: Bool = false,
            minConfidence: Double = 0.85,
            recordingRoots: [URL] = VoiceMemoDiscovery.defaultRecordingRoots(),
            transcriptLoader: @escaping @Sendable (URL) -> String? = VoiceMemoDiscovery.loadTranscriptSidecar(for:)
        ) {
            self.mode = mode
            self.memoId = memoId
            self.dryRun = dryRun
            self.forceReprocess = forceReprocess
            self.minConfidence = minConfidence
            self.recordingRoots = recordingRoots
            self.transcriptLoader = transcriptLoader
        }
    }

    public static func options(from args: Value) -> Options {
        guard case .object(let obj) = args else { return Options() }
        let mode = stringArg(obj, "mode") ?? "batch"
        let memoId = stringArg(obj, "memoId")
        let dryRun: Bool = {
            if case .bool(let b)? = obj["dryRun"] { return b }
            return false
        }()
        let forceReprocess: Bool = {
            if case .bool(let b)? = obj["forceReprocess"] { return b }
            return false
        }()
        let minConfidence: Double = {
            if case .double(let d)? = obj["minConfidence"] { return d }
            if case .int(let i)? = obj["minConfidence"] { return Double(i) }
            return 0.85
        }()
        var roots = VoiceMemoDiscovery.defaultRecordingRoots()
        if let custom = stringArg(obj, "recordingsRoot") {
            roots = [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        return Options(mode: mode, memoId: memoId, dryRun: dryRun, forceReprocess: forceReprocess, minConfidence: minConfidence, recordingRoots: roots)
    }

    public static func listUnprocessed(options: Options = Options()) -> [VoiceMemoRecording] {
        VoiceMemoDiscovery.listRecordings(roots: options.recordingRoots, transcriptLoader: options.transcriptLoader)
            .filter { !VoiceMemoProcessedStore.isProcessed(id: $0.id) }
    }

    public static func process(args: Value, router: ToolRouter) async throws -> Value {
        let options = options(from: args)
        var recordings = VoiceMemoDiscovery.listRecordings(
            roots: options.recordingRoots,
            transcriptLoader: options.transcriptLoader
        )

        if let memoId = options.memoId {
            recordings = recordings.filter { $0.id == memoId || $0.path == memoId }
        } else if options.mode == "batch" {
            recordings = recordings.filter { !VoiceMemoProcessedStore.isProcessed(id: $0.id) }
        }

        var receipts: [VoiceMemoReceipt] = []
        var reviewQueued = 0
        for recording in recordings {
            let receipt = try await processOne(recording, options: options, router: router, reviewQueued: &reviewQueued)
            receipts.append(receipt)
        }

        if !options.dryRun {
            await VoiceMemoNotifier.notifyIfNeeded(receipts: receipts, reviewQueued: reviewQueued, router: router)
        }

        let summary = buildSummary(receipts: receipts, dryRun: options.dryRun)
        return .object([
            "dryRun": .bool(options.dryRun),
            "processedCount": .int(receipts.filter { $0.skippedReason == nil }.count),
            "skippedCount": .int(receipts.filter { $0.skippedReason != nil }.count),
            "reviewPending": .int(VoiceMemoReviewStore.pendingEntries().count),
            "summary": .string(summary),
            "receipts": .array(receipts.map(receiptValue)),
        ])
    }

    // MARK: - Single memo

    static func processOne(
        _ recording: VoiceMemoRecording,
        options: Options,
        router: ToolRouter,
        reviewQueued: inout Int
    ) async throws -> VoiceMemoReceipt {
        if !options.forceReprocess, VoiceMemoProcessedStore.isProcessed(id: recording.id) {
            return VoiceMemoReceipt(
                memoId: recording.id,
                title: recording.title,
                skippedReason: "already processed — pass forceReprocess:true to re-run"
            )
        }

        let audioURL = URL(fileURLWithPath: recording.path, isDirectory: false)
        let transcript: String
        do {
            let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audioURL)
            guard let text = resolved.text else {
                return skipNoTranscript(
                    recording: recording,
                    options: options,
                    reviewQueued: &reviewQueued,
                    reason: "no transcript"
                )
            }
            transcript = text
        } catch {
            if !options.dryRun {
                try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                    memoId: recording.id,
                    memoTitle: recording.title,
                    memoPath: recording.path,
                    intentKind: VoiceMemoIntentKind.review.rawValue,
                    confidence: 0,
                    reason: "transcription failed: \(error.localizedDescription)",
                    transcriptExcerpt: ""
                ))
                reviewQueued += 1
            }
            return VoiceMemoReceipt(
                memoId: recording.id,
                title: recording.title,
                skippedReason: "transcription failed: \(error.localizedDescription)"
            )
        }

        let llmSummary = await VoiceMemoSummarizer.summarize(transcript: transcript, fallbackTitle: recording.title)
        var plan = await VoiceMemoParser.parseWithOptionalOllama(
            transcript: transcript,
            fallbackTitle: recording.title,
            recordingPath: recording.path
        )
        plan = applySummary(to: plan, summary: llmSummary, transcript: transcript, recordingPath: recording.path)
        var outcomes: [VoiceMemoIntentOutcome] = []
        var executedAny = false

        for intent in plan.intents {
            if intent.kind == .review {
                outcomes.append(VoiceMemoIntentOutcome(
                    kind: intent.kind,
                    status: .review,
                    detail: "parser could not classify — manual review"
                ))
                if !options.dryRun {
                    queueReview(
                        recording: recording,
                        intent: intent,
                        plan: plan,
                        reason: "parser could not classify — manual review",
                        reviewQueued: &reviewQueued
                    )
                }
                continue
            }

            if intent.confidence < options.minConfidence {
                outcomes.append(VoiceMemoIntentOutcome(
                    kind: intent.kind,
                    status: .review,
                    detail: "confidence \(intent.confidence) below min \(options.minConfidence)"
                ))
                if !options.dryRun {
                    queueReview(
                        recording: recording,
                        intent: intent,
                        plan: plan,
                        reason: "confidence \(intent.confidence) below min \(options.minConfidence)",
                        reviewQueued: &reviewQueued
                    )
                }
                continue
            }

            if options.dryRun {
                outcomes.append(VoiceMemoIntentOutcome(
                    kind: intent.kind,
                    status: .dryRun,
                    detail: dryRunDetail(intent)
                ))
                executedAny = true
                continue
            }

            do {
                let detail = try await execute(
                    intent: intent,
                    plan: plan,
                    transcript: transcript,
                    router: router
                )
                outcomes.append(VoiceMemoIntentOutcome(kind: intent.kind, status: .executed, detail: detail))
                executedAny = true
            } catch {
                outcomes.append(VoiceMemoIntentOutcome(kind: intent.kind, status: .failed, detail: error.localizedDescription))
                if !options.dryRun {
                    queueReview(
                        recording: recording,
                        intent: intent,
                        plan: plan,
                        reason: error.localizedDescription,
                        reviewQueued: &reviewQueued
                    )
                }
            }
        }

        if !options.dryRun, executedAny, outcomes.contains(where: { $0.status == .executed }) {
            try VoiceMemoProcessedStore.markProcessed(id: recording.id)
        }

        return VoiceMemoReceipt(memoId: recording.id, title: plan.generatedTitle, outcomes: outcomes)
    }

    // MARK: - Execution lanes

    static func execute(intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, router: ToolRouter) async throws -> String {
        switch intent.kind {
        case .reminder:
            return try await executeReminder(intent, router: router)
        case .memoryKeep:
            return try await executeMemoryKeep(intent, plan: plan, transcript: transcript, router: router)
        case .agentMemory:
            return try await executeAgentMemory(intent, plan: plan, router: router)
        case .registryUpdate:
            return try await executeRegistryUpdate(intent, router: router)
        case .review:
            return "queued for review — no auto-write"
        }
    }

    static func executeReminder(_ intent: VoiceMemoIntent, router: ToolRouter) async throws -> String {
        guard let title = intent.title, !title.isEmpty else {
            throw VoiceMemoError.invalidIntent("reminder missing title")
        }
        var args: [String: Value] = ["title": .string(title)]
        if let notes = intent.body { args["notes"] = .string(notes) }
        if let due = intent.dueISO8601 { args["due"] = .string(due) }
        _ = try await router.dispatch(toolName: "reminders_create", arguments: .object(args))
        return "reminders_create: \(title)"
    }

    static func executeAgentMemory(_ intent: VoiceMemoIntent, plan: VoiceMemoPlan, router: ToolRouter) async throws -> String {
        let scope = intent.fields["scope"] ?? "global"
        let text = [plan.summary, plan.actions.joined(separator: "; ")].filter { !$0.isEmpty }.joined(separator: "\n")
        _ = try await router.dispatch(toolName: "memory_remember", arguments: .object([
            "text": .string(text),
            "scope": .string(scope),
            "source": .string("voice-memo"),
            "type": .string("reference"),
        ]))
        return "memory_remember scope=\(scope)"
    }

    static func executeMemoryKeep(_ intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, router: ToolRouter) async throws -> String {
        let entityKey = intent.entityKey ?? "memory"
        let fields = resolvedMemoryKeepFields(intent: intent, plan: plan)
        let createResult = try await router.dispatch(toolName: "registry_create", arguments: .object([
            "entity": .string(entityKey),
            "fields": .object(fields.mapValues { .string($0) }),
        ]))
        guard let pageId = parseRegistryPageId(from: createResult) else {
            return "registry_create entity=\(entityKey) (memory_keep) — created but page id not parsed"
        }
        try await appendTranscriptToNotionPage(pageId: pageId, transcript: transcript, router: router)
        return "registry_create entity=\(entityKey) id=\(pageId) + transcript appended"
    }

    static func executeRegistryUpdate(_ intent: VoiceMemoIntent, router: ToolRouter) async throws -> String {
        guard let entityKey = intent.entityKey else {
            throw VoiceMemoError.invalidIntent("registry update missing entity key")
        }
        let rowId = try await resolveRegistryRowId(entityKey: entityKey, hint: intent.entityHint, router: router)
        let fields = intent.fields.mapValues { Value.string($0) }
        _ = try await router.dispatch(toolName: "registry_update", arguments: .object([
            "entity": .string(entityKey),
            "id": .string(rowId),
            "fields": .object(fields),
        ]))
        return "registry_update entity=\(entityKey) id=\(rowId)"
    }

    static func resolveRegistryRowId(entityKey: String, hint: String?, router: ToolRouter) async throws -> String {
        let list = try await router.dispatch(toolName: "registry_list", arguments: .object([
            "entity": .string(entityKey),
            "limit": .int(100),
        ]))
        guard case .object(let envelope) = list,
              case .array(let rows)? = envelope["rows"] else {
            throw VoiceMemoError.registryMatchFailed(entityKey, hint)
        }
        let normalizedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for row in rows {
            guard case .object(let rowObj) = row,
                  case .string(let id)? = rowObj["id"],
                  case .string(let title)? = rowObj["title"] else { continue }
            if let hint = normalizedHint, !hint.isEmpty {
                let t = title.lowercased()
                if t.contains(hint) || hint.contains(t) { return id }
            }
        }
        if let hint = normalizedHint,
           let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: hint), options: .caseInsensitive) {
            for row in rows {
                guard case .object(let rowObj) = row,
                      case .string(let id)? = rowObj["id"],
                      case .string(let title)? = rowObj["title"],
                      regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil else { continue }
                return id
            }
        }
        throw VoiceMemoError.registryMatchFailed(entityKey, hint)
    }

    static func resolvedMemoryKeepFields(intent: VoiceMemoIntent, plan: VoiceMemoPlan) -> [String: String] {
        if !intent.fields.isEmpty { return intent.fields }
        return VoiceMemoParser.memoryKeepFields(
            title: intent.title ?? plan.generatedTitle,
            summary: plan.summary,
            actions: plan.actions
        )
    }

    static func skipNoTranscript(
        recording: VoiceMemoRecording,
        options: Options,
        reviewQueued: inout Int,
        reason: String
    ) -> VoiceMemoReceipt {
        if !options.dryRun {
            try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                memoId: recording.id,
                memoTitle: recording.title,
                memoPath: recording.path,
                intentKind: VoiceMemoIntentKind.review.rawValue,
                confidence: 0,
                reason: reason,
                transcriptExcerpt: ""
            ))
            reviewQueued += 1
        }
        return VoiceMemoReceipt(memoId: recording.id, title: recording.title, skippedReason: reason)
    }

    public static func applySummary(to plan: VoiceMemoPlan, summary: String, transcript: String, recordingPath: String?) -> VoiceMemoPlan {
        var updated = plan
        updated.summary = summary
        updated.intents = plan.intents.map { intent in
            guard intent.kind == .memoryKeep else { return intent }
            var copy = intent
            let title = VoiceMemoParser.sanitizeTitle(intent.title, fallback: plan.generatedTitle)
            copy.title = title
            copy.fields = VoiceMemoParser.memoryKeepFields(
                title: title,
                summary: summary,
                actions: plan.actions,
                recordingPath: recordingPath
            )
            copy.body = summary
            return copy
        }
        if !updated.skipMemoryKeep {
            updated.generatedTitle = VoiceMemoParser.sanitizeTitle(updated.generatedTitle, fallback: VoiceMemoParser.firstSentencePublic(in: transcript, maxLen: 72))
        }
        return updated
    }

    public static func parseRegistryPageId(from value: Value) -> String? {
        guard case .object(let envelope) = value,
              case .object(let row)? = envelope["row"],
              case .string(let id)? = row["id"],
              !id.isEmpty else { return nil }
        return id
    }

    static func appendTranscriptToNotionPage(pageId: String, transcript: String, router: ToolRouter) async throws {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var children: [[String: Any]] = [
            [
                "object": "block",
                "type": "heading_2",
                "heading_2": [
                    "rich_text": [["type": "text", "text": ["content": "Voice Memo Transcript"]]],
                ],
            ],
        ]
        for chunk in chunkText(trimmed, maxLen: 1900) {
            children.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [["type": "text", "text": ["content": chunk]]],
                ],
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: children)
        guard let json = String(data: data, encoding: .utf8) else { return }
        _ = try await router.dispatch(toolName: "notion_blocks_append", arguments: .object([
            "blockId": .string(pageId),
            "children": .string(json),
        ]))
    }

    public static func chunkText(_ text: String, maxLen: Int) -> [String] {
        guard text.count > maxLen else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLen, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    static func queueReview(
        recording: VoiceMemoRecording,
        intent: VoiceMemoIntent,
        plan: VoiceMemoPlan,
        reason: String,
        reviewQueued: inout Int
    ) {
        try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
            memoId: recording.id,
            memoTitle: plan.generatedTitle,
            memoPath: recording.path,
            intentKind: intent.kind.rawValue,
            confidence: intent.confidence,
            reason: reason,
            transcriptExcerpt: String((recording.transcript ?? plan.summary).prefix(500))
        ))
        reviewQueued += 1
    }

    static func resolvedRegistryFields(intent: VoiceMemoIntent, plan: VoiceMemoPlan) -> [String: String] {
        if !intent.fields.isEmpty { return intent.fields }
        var fields: [String: String] = [
            "title": intent.title ?? plan.generatedTitle,
            "summary": plan.summary,
            "source": "voice-memo",
        ]
        if !plan.actions.isEmpty {
            fields["actions"] = plan.actions.joined(separator: "\n")
        }
        return fields
    }

    // MARK: - Helpers

    static func buildSummary(receipts: [VoiceMemoReceipt], dryRun: Bool) -> String {
        let prefix = dryRun ? "Dry-run:" : "Processed"
        var reminders = 0, memoryKeep = 0, agent = 0, registry = 0, review = 0, skipped = 0
        for receipt in receipts {
            if receipt.skippedReason != nil { skipped += 1; continue }
            for outcome in receipt.outcomes {
                switch outcome.kind {
                case .reminder where outcome.status == .executed || outcome.status == .dryRun: reminders += 1
                case .memoryKeep where outcome.status == .executed || outcome.status == .dryRun: memoryKeep += 1
                case .agentMemory where outcome.status == .executed || outcome.status == .dryRun: agent += 1
                case .registryUpdate where outcome.status == .executed || outcome.status == .dryRun: registry += 1
                case .review: review += 1
                default: break
                }
            }
        }
        return "\(prefix) \(receipts.count) memo(s): \(reminders) reminder(s), \(memoryKeep) memory_keep, \(agent) agent_memory, \(registry) registry update(s), \(review) review, \(skipped) skipped."
    }

    static func dryRunDetail(_ intent: VoiceMemoIntent) -> String {
        switch intent.kind {
        case .memoryKeep: return "would memory_keep → registry/\(intent.entityKey ?? "memory")"
        case .reminder: return "would reminders_create: \(intent.title ?? "?")"
        case .agentMemory: return "would memory_remember"
        case .registryUpdate: return "would registry_update \(intent.entityKey ?? "?") hint=\(intent.entityHint ?? "?")"
        case .review: return "would queue for review"
        }
    }

    static func receiptValue(_ receipt: VoiceMemoReceipt) -> Value {
        .object([
            "memoId": .string(receipt.memoId),
            "title": .string(receipt.title),
            "skippedReason": receipt.skippedReason.map { .string($0) } ?? .null,
            "outcomes": .array(receipt.outcomes.map {
                .object([
                    "kind": .string($0.kind.rawValue),
                    "status": .string($0.status.rawValue),
                    "detail": .string($0.detail),
                ])
            }),
        ])
    }

    private static func stringArg(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s }
        return nil
    }
}

public enum VoiceMemoError: Error, LocalizedError {
    case invalidIntent(String)
    case registryMatchFailed(String, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidIntent(let msg): return msg
        case .registryMatchFailed(let entity, let hint):
            return "no registry row matched entity=\(entity) hint=\(hint ?? "nil")"
        }
    }
}
