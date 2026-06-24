// VoiceMemoReviewResolver.swift — review dispositions + transcript refresh (PKT-MEM-103)
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP

public enum VoiceMemoReviewAction: String, Sendable, CaseIterable {
    case memoryKeep = "memory_keep"
    case reminder
    case agentRemember = "agent_remember"
    case registryUpdate = "registry_update"
    case retryRouting = "retry_routing"
    case markHandled = "mark_handled"
}

public enum VoiceMemoReviewResolver {

    public struct ResolveResult: Sendable, Equatable {
        public var action: String
        public var detail: String
        public var markedProcessed: Bool
        public var resolved: Bool
        public var warning: String?

        public init(action: String, detail: String, markedProcessed: Bool, resolved: Bool, warning: String? = nil) {
            self.action = action
            self.detail = detail
            self.markedProcessed = markedProcessed
            self.resolved = resolved
            self.warning = warning
        }
    }

    public static func resolve(args: Value, router: ToolRouter) async throws -> Value {
        guard case .object(let obj) = args,
              case .string(let reviewId) = obj["id"],
              case .string(let actionRaw) = obj["action"],
              let action = VoiceMemoReviewAction(rawValue: actionRaw) else {
            throw ToolRouterError.invalidArguments(
                toolName: "voice_memo_review_resolve",
                reason: "expected id + action (memory_keep|reminder|agent_remember|registry_update|retry_routing|mark_handled)"
            )
        }

        let force: Bool = {
            if case .bool(let b)? = obj["force"] { return b }
            return false
        }()
        let minConfidence: Double = {
            if case .double(let d)? = obj["minConfidence"] { return d }
            if case .int(let i)? = obj["minConfidence"] { return Double(i) }
            return 0.85
        }()

        let result = try await resolve(
            reviewId: reviewId,
            action: action,
            router: router,
            force: force,
            minConfidence: minConfidence,
            fields: stringFields(from: obj["fields"]),
            entityKey: stringArg(obj, "entity"),
            rowId: stringArg(obj, "rowId"),
            entityHint: stringArg(obj, "entityHint"),
            reminderTitle: stringArg(obj, "title"),
            reminderDue: stringArg(obj, "due")
        )

        return .object([
            "action": .string(result.action),
            "detail": .string(result.detail),
            "markedProcessed": .bool(result.markedProcessed),
            "resolved": .bool(result.resolved),
            "warning": result.warning.map { .string($0) } ?? .null,
            "pendingCount": .int(VoiceMemoReviewStore.pendingEntries().count),
        ])
    }

    public static func resolve(
        reviewId: String,
        action: VoiceMemoReviewAction,
        router: ToolRouter,
        force: Bool = false,
        minConfidence: Double = 0.85,
        fields: [String: String] = [:],
        entityKey: String? = nil,
        rowId: String? = nil,
        entityHint: String? = nil,
        reminderTitle: String? = nil,
        reminderDue: String? = nil
    ) async throws -> ResolveResult {
        guard let entry = VoiceMemoReviewStore.load().entries.first(where: { $0.id == reviewId }) else {
            throw VoiceMemoReviewError.entryNotFound(reviewId)
        }
        guard entry.status == .pending else {
            throw VoiceMemoReviewError.notPending(reviewId, entry.status.rawValue)
        }

        switch action {
        case .markHandled:
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            return ResolveResult(
                action: action.rawValue,
                detail: "marked processed without external write",
                markedProcessed: true,
                resolved: true
            )

        case .retryRouting:
            return try await retryRouting(
                entry: entry,
                reviewId: reviewId,
                router: router,
                minConfidence: minConfidence
            )

        case .memoryKeep:
            if VoiceMemoProcessedStore.isProcessed(id: entry.memoId), !force {
                throw VoiceMemoReviewError.duplicateMemoryKeep(entry.memoId)
            }
            let (transcript, plan) = try await loadTranscriptAndPlan(for: entry)
            var intent = plan.intents.first(where: { $0.kind == .memoryKeep })
                ?? VoiceMemoIntent(
                    kind: .memoryKeep,
                    confidence: 1.0,
                    entityKey: entityKey ?? "memory",
                    title: entry.memoTitle,
                    body: plan.summary,
                    fields: fields
                )
            if !fields.isEmpty { intent.fields = fields }
            if let entityKey { intent.entityKey = entityKey }
            let detail = try await VoiceMemoProcessor.executeMemoryKeep(intent, plan: plan, transcript: transcript, router: router)
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            return ResolveResult(
                action: action.rawValue,
                detail: detail,
                markedProcessed: true,
                resolved: true
            )

        case .reminder:
            let (transcript, plan) = try await loadTranscriptAndPlan(for: entry)
            var intent = plan.intents.first(where: { $0.kind == .reminder })
                ?? VoiceMemoIntent(
                    kind: .reminder,
                    confidence: 1.0,
                    title: reminderTitle ?? entry.memoTitle,
                    body: plan.summary,
                    dueISO8601: reminderDue
                )
            if let reminderTitle { intent.title = reminderTitle }
            if let reminderDue { intent.dueISO8601 = reminderDue }
            let detail = try await VoiceMemoProcessor.executeReminder(intent, router: router)
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            return ResolveResult(
                action: action.rawValue,
                detail: detail,
                markedProcessed: true,
                resolved: true
            )

        case .agentRemember:
            let (_, plan) = try await loadTranscriptAndPlan(for: entry)
            var intent = plan.intents.first(where: { $0.kind == .agentMemory })
                ?? VoiceMemoIntent(kind: .agentMemory, confidence: 1.0, title: entry.memoTitle, body: plan.summary)
            if !fields.isEmpty { intent.fields = fields }
            let detail = try await VoiceMemoProcessor.executeAgentMemory(intent, plan: plan, router: router)
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            return ResolveResult(
                action: action.rawValue,
                detail: detail,
                markedProcessed: true,
                resolved: true
            )

        case .registryUpdate:
            let (_, plan) = try await loadTranscriptAndPlan(for: entry)
            guard let entity = entityKey ?? planEntityHint(from: entry) else {
                throw VoiceMemoReviewError.missingRegistryTarget
            }
            var intent = plan.intents.first(where: { $0.kind == .registryUpdate && ($0.entityKey == entity || entityKey != nil) })
                ?? VoiceMemoIntent(
                    kind: .registryUpdate,
                    confidence: 1.0,
                    entityKey: entity,
                    entityHint: entityHint ?? entry.memoTitle,
                    title: entry.memoTitle,
                    body: plan.summary,
                    fields: fields.isEmpty ? VoiceMemoProcessor.resolvedRegistryFields(
                        intent: VoiceMemoIntent(kind: .registryUpdate, confidence: 1.0, title: entry.memoTitle),
                        plan: plan
                    ) : fields
                )
            if !fields.isEmpty { intent.fields = fields }
            if let entityHint { intent.entityHint = entityHint }
            if let rowId {
                let updateFields = intent.fields.mapValues { Value.string($0) }
                _ = try await router.dispatch(toolName: "registry_update", arguments: .object([
                    "entity": .string(entity),
                    "id": .string(rowId),
                    "fields": .object(updateFields),
                ]))
                let detail = "registry_update entity=\(entity) id=\(rowId)"
                try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
                try VoiceMemoReviewStore.resolve(id: reviewId)
                return ResolveResult(
                    action: action.rawValue,
                    detail: detail,
                    markedProcessed: true,
                    resolved: true
                )
            }
            let detail = try await VoiceMemoProcessor.executeRegistryUpdate(intent, router: router)
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            return ResolveResult(
                action: action.rawValue,
                detail: detail,
                markedProcessed: true,
                resolved: true
            )
        }
    }

    public static func refreshTranscript(args: Value) async throws -> Value {
        guard case .object(let obj) = args else {
            throw ToolRouterError.invalidArguments(toolName: "voice_memo_transcript_refresh", reason: "expected object")
        }
        let forceParakeet: Bool = {
            if case .bool(let b)? = obj["forceParakeet"] { return b }
            return false
        }()
        let audioURL: URL
        if let memoId = stringArg(obj, "memoId") {
            let roots = VoiceMemoDiscovery.defaultRecordingRoots()
            let recordings = VoiceMemoDiscovery.listRecordings(roots: roots)
            guard let match = recordings.first(where: { $0.id == memoId || $0.path == memoId }) else {
                throw VoiceMemoReviewError.memoNotFound(memoId)
            }
            audioURL = URL(fileURLWithPath: match.path)
        } else if let path = stringArg(obj, "path") {
            audioURL = URL(fileURLWithPath: path)
        } else {
            throw ToolRouterError.invalidArguments(toolName: "voice_memo_transcript_refresh", reason: "missing memoId or path")
        }

        let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audioURL, forceParakeet: forceParakeet)
        return .object([
            "memoId": .string(VoiceMemoDiscovery.stableId(for: audioURL)),
            "path": .string(audioURL.path),
            "source": .string(resolved.source.rawValue),
            "charCount": .int(resolved.text?.count ?? 0),
            "textPreview": .string(String(resolved.text?.prefix(500) ?? "")),
            "hasTranscript": .bool(resolved.text != nil),
        ])
    }

    // MARK: - Retry routing (no re-transcribe)

    private static func retryRouting(
        entry: VoiceMemoReviewEntry,
        reviewId: String,
        router: ToolRouter,
        minConfidence: Double
    ) async throws -> ResolveResult {
        let transcript = try loadCachedTranscript(for: entry)
        let llmSummary = await VoiceMemoSummarizer.summarize(transcript: transcript, fallbackTitle: entry.memoTitle)
        var plan = await VoiceMemoParser.parseWithOptionalOllama(
            transcript: transcript,
            fallbackTitle: entry.memoTitle,
            recordingPath: entry.memoPath
        )
        plan = VoiceMemoProcessor.applySummary(
            to: plan,
            summary: llmSummary,
            transcript: transcript,
            recordingPath: entry.memoPath
        )

        var executedDetails: [String] = []
        var executedAny = false

        for intent in plan.intents {
            guard intent.kind != .review else { continue }
            guard intent.confidence >= minConfidence else { continue }
            let detail = try await VoiceMemoProcessor.execute(
                intent: intent,
                plan: plan,
                transcript: transcript,
                router: router
            )
            executedDetails.append(detail)
            executedAny = true
        }

        var markedProcessed = false
        var resolved = false
        if executedAny {
            try VoiceMemoProcessedStore.markProcessed(id: entry.memoId)
            try VoiceMemoReviewStore.resolve(id: reviewId)
            markedProcessed = true
            resolved = true
        }

        let detail = executedAny
            ? executedDetails.joined(separator: "; ")
            : "retry_routing: no intents met confidence \(minConfidence)"

        return ResolveResult(
            action: VoiceMemoReviewAction.retryRouting.rawValue,
            detail: detail,
            markedProcessed: markedProcessed,
            resolved: resolved,
            warning: executedAny ? nil : "still needs manual disposition"
        )
    }

    // MARK: - Transcript loading

    private static func loadCachedTranscript(for entry: VoiceMemoReviewEntry) throws -> String {
        if let path = entry.memoPath {
            let audio = URL(fileURLWithPath: path)
            if let sidecar = VoiceMemoDiscovery.loadTranscriptSidecar(for: audio) {
                return sidecar
            }
            if let apple = AppleVoiceMemoTranscriptExtractor.extract(from: audio) {
                return apple
            }
        }
        let excerpt = entry.transcriptExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else {
            throw VoiceMemoReviewError.noTranscript(entry.memoId)
        }
        return excerpt
    }

    private static func loadTranscriptAndPlan(for entry: VoiceMemoReviewEntry) async throws -> (String, VoiceMemoPlan) {
        let transcript = try loadCachedTranscript(for: entry)
        let summary = await VoiceMemoSummarizer.summarize(transcript: transcript, fallbackTitle: entry.memoTitle)
        var plan = await VoiceMemoParser.parseWithOptionalOllama(
            transcript: transcript,
            fallbackTitle: entry.memoTitle,
            recordingPath: entry.memoPath
        )
        plan = VoiceMemoProcessor.applySummary(
            to: plan,
            summary: summary,
            transcript: transcript,
            recordingPath: entry.memoPath
        )
        return (transcript, plan)
    }

    private static func planEntityHint(from entry: VoiceMemoReviewEntry) -> String? {
        if let kind = VoiceMemoIntentKind(rawValue: entry.intentKind), kind == .registryUpdate {
            return entry.memoTitle
        }
        return nil
    }

    private static func stringArg(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = obj[key], !s.isEmpty { return s }
        return nil
    }

    private static func stringFields(from value: Value?) -> [String: String] {
        guard case .object(let obj)? = value else { return [:] }
        var out: [String: String] = [:]
        for (key, val) in obj {
            if case .string(let s) = val { out[key] = s }
        }
        return out
    }
}

public enum VoiceMemoReviewError: Error, LocalizedError {
    case entryNotFound(String)
    case notPending(String, String)
    case duplicateMemoryKeep(String)
    case noTranscript(String)
    case memoNotFound(String)
    case missingRegistryTarget

    public var errorDescription: String? {
        switch self {
        case .entryNotFound(let id): return "review entry not found: \(id)"
        case .notPending(let id, let status): return "review entry \(id) is \(status), not pending"
        case .duplicateMemoryKeep(let memoId):
            return "memo \(memoId) already processed — pass force:true to file another Memory row"
        case .noTranscript(let memoId): return "no cached transcript for memo \(memoId) — run voice_memo_transcript_refresh first"
        case .memoNotFound(let id): return "voice memo not found: \(id)"
        case .missingRegistryTarget: return "registry_update requires entity (and rowId or entityHint)"
        }
    }
}

/// Launch + wake TTL sweep (PKT-MEM-103).
public enum VoiceMemoReviewLifecycle {
    public static func sweepIfNeeded(router: ToolRouter? = nil) async {
        do {
            let report = try VoiceMemoReviewStore.sweepTTL()
            guard report.autoDismissed > 0 || report.purged > 0 else { return }
            if report.autoDismissed > 0, let router {
                await VoiceMemoNotifier.notify(
                    title: "Voice memos auto-dismissed",
                    body: "\(report.autoDismissed) review item(s) older than \(VoiceMemoReviewStore.pendingTTLDays) days were dismissed.",
                    settingsSection: "Memory",
                    settingsAnchor: "inbox",
                    router: router
                )
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .voiceMemoReviewDidChange, object: nil)
            }
        } catch {
            print("[VoiceMemoReview] TTL sweep failed: \(error)")
        }
    }
}
