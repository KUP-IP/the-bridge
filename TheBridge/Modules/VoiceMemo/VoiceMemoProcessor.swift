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
                    transcriptExcerpt: "",
                    intentId: VoiceMemoIntentIdentity.intentId(
                        memoId: recording.id, kind: VoiceMemoIntentKind.review.rawValue,
                        entityKey: nil, entityHint: nil, title: recording.title, fields: [:]
                    ),
                    provenance: "transcription-error"
                ))
                reviewQueued += 1
            }
            return VoiceMemoReceipt(
                memoId: recording.id,
                title: recording.title,
                skippedReason: "transcription failed: \(error.localizedDescription)"
            )
        }

        let llmSummary: String
        var plan = await VoiceMemoParser.parseWithOptionalOllama(
            transcript: transcript,
            fallbackTitle: recording.title,
            recordingPath: recording.path
        )
        // PRIVACY (FRONTIER-FIRST W4): the autonomous path (batch + scheduled curator
        // job, .auto/.cloud mode) can send the WHOLE transcript to a cloud provider as
        // the Understand step. Write a DURABLE Understand receipt the instant the cloud
        // rung wins so the operator can later see content left the device — hash +
        // excerpt only, NEVER the full transcript. Fires even on dryRun (the send was
        // real). Best-effort: a failed append never blocks processing.
        recordUnderstandCloudSend(recording: recording, plan: plan, transcript: transcript)
        let needsLLMSummary = plan.intents.contains { $0.kind == .memoryKeep }
            && VoiceMemoCuratorRouter.shouldSummarizeForMemoryKeep()
        if needsLLMSummary {
            llmSummary = await VoiceMemoSummarizer.summarize(transcript: transcript, fallbackTitle: recording.title)
        } else {
            llmSummary = VoiceMemoParser.firstSentencePublic(in: transcript, maxLen: 280)
        }
        plan = applySummary(to: plan, summary: llmSummary, transcript: transcript, recordingPath: recording.path)

        if await VoiceMemoCuratorRouter.deferExecuteToAgent() {
            if !options.dryRun {
                let mode = VoiceMemoCuratorRouter.effectiveMode()
                let reason = mode == .agent
                    ? "curator mode agent — transcribed; awaiting connected agent commit"
                    : "auto — MCP connected; awaiting agent commit"
                queueReview(
                    recording: recording,
                    intent: VoiceMemoIntent(kind: .review, confidence: 0.5, title: plan.generatedTitle, body: plan.summary),
                    plan: plan,
                    reason: reason,
                    reviewQueued: &reviewQueued,
                    reviewTag: .awaitingAgent,
                    provenance: plan.provenance.rawValue
                )
                recordAgentDeferred(recording: recording, plan: plan, reason: reason)
            }
            return VoiceMemoReceipt(
                memoId: recording.id,
                title: plan.generatedTitle,
                skippedReason: "deferred to connected MCP agent",
                provenance: plan.provenance,
                degraded: plan.degraded
            )
        }

        let election = VoiceMemoIntentElection.split(plan.intents)
        var outcomes: [VoiceMemoIntentOutcome] = []
        var executedAny = false
        var reviewQueuedForMemo = false

        for suppressed in election.suppressed {
            outcomes.append(VoiceMemoIntentOutcome(
                kind: suppressed.kind,
                status: .review,
                detail: "secondary intent suppressed — primary lane elected"
            ))
            if !options.dryRun {
                queueReview(
                    recording: recording,
                    intent: suppressed,
                    plan: plan,
                    reason: "secondary intent suppressed — primary lane elected",
                    reviewQueued: &reviewQueued,
                    reviewTag: .suppressed
                )
                reviewQueuedForMemo = true
            }
        }

        for intent in election.execute {
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
                    reviewQueuedForMemo = true
                }
                continue
            }

            // Auto-execute only when the lane-specific threshold + global floor pass
            // (PKT-MEM-106 0c locked thresholds: reminder 0.90 / registry 0.86 / agent 0.86 /
            // memory_keep 0.90 / global 0.80) AND the operator's minConfidence. Otherwise queue review.
            let laneAuto = MemoryHubCommitGuardrails.autoDecision(kind: intent.kind, confidence: intent.confidence)
            if !laneAuto.isAuto || intent.confidence < options.minConfidence {
                let reviewReason: String
                if case .manual(let why) = laneAuto { reviewReason = why }
                else { reviewReason = "confidence \(intent.confidence) below min \(options.minConfidence)" }
                outcomes.append(VoiceMemoIntentOutcome(
                    kind: intent.kind,
                    status: .review,
                    detail: reviewReason
                ))
                if !options.dryRun {
                    queueReview(
                        recording: recording,
                        intent: intent,
                        plan: plan,
                        reason: reviewReason,
                        reviewQueued: &reviewQueued
                    )
                    reviewQueuedForMemo = true
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
                    reviewQueuedForMemo = true
                }
            }
        }

        let hasExecuted = outcomes.contains { $0.status == .executed }
        if !options.dryRun, hasExecuted, !reviewQueuedForMemo {
            // Processed-gate (PKT-MEM-106 0a): even past the in-run flag, mark only when
            // NO pending review remains for this memo in the store (sibling lanes / prior runs).
            try VoiceMemoProcessedGate.markProcessedIfClear(memoId: recording.id)
        }

        return VoiceMemoReceipt(
            memoId: recording.id,
            title: plan.generatedTitle,
            outcomes: outcomes,
            provenance: plan.provenance,
            degraded: plan.degraded
        )
    }

    // MARK: - Execution lanes

    static func execute(intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, router: ToolRouter) async throws -> String {
        switch intent.kind {
        case .reminder:
            return try await executeReminder(intent, router: router)
        case .memoryKeep:
            return try await executeMemoryKeep(intent, plan: plan, transcript: transcript, router: router)
        case .agentMemory:
            return try await executeAgentMemory(intent, plan: plan, transcript: transcript, router: router)
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

    public static func executeAgentMemory(_ intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, router: ToolRouter) async throws -> String {
        let scope = intent.fields["scope"] ?? "global"
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = [plan.summary, plan.actions.joined(separator: "; ")].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        _ = try await router.dispatch(toolName: "memory_remember", arguments: .object([
            "text": .string(text),
            "scope": .string(scope),
            "source": .string("voice-memo"),
            "type": .string("reference"),
        ]))
        return "memory_remember scope=\(scope) (\(text.count) chars)"
    }

    static func executeMemoryKeep(_ intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, router: ToolRouter) async throws -> String {
        let entityKey = intent.entityKey ?? "memory"
        return try await executeMemoryKeep(
            entityKey: entityKey,
            intent: intent,
            plan: plan,
            transcript: transcript,
            router: router,
            entity: await Self.loadRegistryEntity(key: entityKey)
        )
    }

    /// Testable core: `entity` is the resolved registry binding for `entityKey`
    /// (the property map that decides whether a PLAYERS relation can be
    /// attached). Production resolves it from the shared config store; tests
    /// inject a fixture entity so the attach/verify/graceful-BLOCKED branches
    /// are exercised hermetically without live Notion.
    @discardableResult
    public static func executeMemoryKeep(
        entityKey: String,
        intent: VoiceMemoIntent,
        plan: VoiceMemoPlan,
        transcript: String,
        router: ToolRouter,
        entity: RegistryEntity?
    ) async throws -> String {
        var fields = resolvedMemoryKeepFields(intent: intent, plan: plan)

        // PKT-1064 — attach the ORIGINATING Player relation to the new Memory
        // row at create time. The Player is bound by property id through the
        // registry contract, so the entity MUST expose a bound PLAYERS relation
        // property. If it does not (absent/unbound binding), that is the
        // "graceful BLOCKED" case: throw a descriptive error so the memo routes
        // to REVIEW (queueReview in processOne) rather than being silently
        // marked processed with no attribution. No crash.
        guard let playersKey = Self.playersRelationKey(in: entity) else {
            throw VoiceMemoError.playerRelationUnbound(entityKey)
        }
        let originatingPlayerId = Self.originatingPlayerId(for: intent)
        fields[playersKey] = originatingPlayerId

        let createResult = try await router.dispatch(toolName: "registry_create", arguments: .object([
            "entity": .string(entityKey),
            "fields": .object(fields.mapValues { .string($0) }),
        ]))
        guard let pageId = parseRegistryPageId(from: createResult) else {
            return "registry_create entity=\(entityKey) (memory_keep) — created but page id not parsed"
        }

        // Verify the relation actually attached via a read-back. A create that
        // reports success but drops the relation (schema mismatch, silent Notion
        // no-op) must NOT be accepted as processed — throw so the memo routes to
        // REVIEW with a visible assertion failure (packet Success Criteria).
        try await Self.verifyPlayerAttached(
            entityKey: entityKey,
            pageId: pageId,
            playersKey: playersKey,
            expectedPlayerId: originatingPlayerId,
            router: router
        )

        // W3: summary + action items in Notion body — transcript remains UI-only (FR-005).
        try await appendSummaryBodyToNotionPage(pageId: pageId, plan: plan, fields: fields, router: router)
        return "registry_create entity=\(entityKey) id=\(pageId) + player \(originatingPlayerId) + summary body"
    }

    /// Load the registry entity binding for `key` from the shared config store.
    /// Returns nil when the store has no such entity (first run / unconfigured).
    static func loadRegistryEntity(key: String) async -> RegistryEntity? {
        await RegistryConfigStore.shared.loadOrSeed().entity(key)
    }

    /// The canonical field key of a BOUND `.relation` property whose Notion
    /// column is "PLAYERS" on this entity, or nil when no such bound relation
    /// exists (property absent from the map, or present but not yet bound to a
    /// Notion property id). Matching is by the Notion display name (case- and
    /// whitespace-insensitive) so a rename of the canonical key doesn't break it,
    /// while an UNBOUND property still yields nil (can't write a relation with no
    /// property id → graceful BLOCKED).
    public static func playersRelationKey(in entity: RegistryEntity?) -> String? {
        guard let entity else { return nil }
        let match = entity.properties.first { prop in
            prop.role == .relation
                && prop.isBound
                && prop.notionName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PLAYERS"
        }
        return match?.key
    }

    /// Default originating player = the primary user player (Isaiah, PLYR-5).
    /// A future source-metadata owner override would slot in here; for Isaiah's
    /// local Voice Memos library the default is authoritative (packet scope).
    static let defaultOriginatingPlayerId = "dc8e8f3f-e607-4b5d-809e-ae289574f40c"

    static func originatingPlayerId(for intent: VoiceMemoIntent) -> String {
        // An explicit non-empty per-intent override wins; otherwise the primary
        // user player. Kept deterministic — no ambiguous resolution (packet stop
        // condition: originating Player must resolve deterministically).
        if let explicit = intent.fields["originatingPlayer"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        return defaultOriginatingPlayerId
    }

    /// Read the just-created row back and assert the PLAYERS relation contains
    /// the expected player id. Throws `playerRelationVerifyFailed` when the
    /// relation is absent/empty/wrong on read-back.
    static func verifyPlayerAttached(
        entityKey: String,
        pageId: String,
        playersKey: String,
        expectedPlayerId: String,
        router: ToolRouter
    ) async throws {
        let getResult = try await router.dispatch(toolName: "registry_get", arguments: .object([
            "entity": .string(entityKey),
            "id": .string(pageId),
            "forceRefresh": .bool(true),
        ]))
        guard case .object(let envelope) = getResult,
              case .object(let props)? = envelope["properties"],
              case .array(let ids)? = props[playersKey] else {
            throw VoiceMemoError.playerRelationVerifyFailed(entityKey, pageId, expectedPlayerId)
        }
        let attached = ids.contains { if case .string(let s) = $0 { return s == expectedPlayerId } else { return false } }
        if !attached {
            throw VoiceMemoError.playerRelationVerifyFailed(entityKey, pageId, expectedPlayerId)
        }
    }

    public static func executeRegistryUpdate(_ intent: VoiceMemoIntent, explicitRowId: String? = nil, router: ToolRouter) async throws -> String {
        guard let entityKey = intent.entityKey else {
            throw VoiceMemoError.invalidIntent("registry update missing entity key")
        }
        // An explicit rowId (operator / agent / picker selection) wins over the free-text
        // entityHint match (PKT-MEM-106 0a rowId threading); otherwise resolve by hint.
        let rowId: String
        if let explicitRowId, !explicitRowId.isEmpty {
            rowId = explicitRowId
        } else {
            rowId = try await resolveRegistryRowId(entityKey: entityKey, hint: intent.entityHint, router: router)
        }
        let merged = try await mergeAppendRegistryFields(
            entityKey: entityKey,
            rowId: rowId,
            proposed: intent.fields,
            router: router
        )
        let fields = merged.mapValues { Value.string($0) }
        _ = try await router.dispatch(toolName: "registry_update", arguments: .object([
            "entity": .string(entityKey),
            "id": .string(rowId),
            "fields": .object(fields),
        ]))
        return "registry_update entity=\(entityKey) id=\(rowId) (append)"
    }

    public static func mergeAppendRegistryFields(
        entityKey: String,
        rowId: String,
        proposed: [String: String],
        router: ToolRouter
    ) async throws -> [String: String] {
        let appendKeys: Set<String> = ["brief", "objective", "summary", "description"]
        guard proposed.keys.contains(where: appendKeys.contains) else { return proposed }

        let getResult = try await router.dispatch(toolName: "registry_get", arguments: .object([
            "entity": .string(entityKey),
            "id": .string(rowId),
        ]))
        guard case .object(let envelope) = getResult,
              case .object(let props) = envelope["properties"] else {
            return proposed
        }

        var merged = proposed
        for (key, newValue) in proposed where appendKeys.contains(key) {
            var existing = ""
            if case .string(let s)? = props[key] { existing = s }
            merged[key] = VoiceMemoParser.appendVoiceMemoLog(existing: existing, newContent: newValue)
        }
        return merged
    }

    public static func resolveRegistryRowId(entityKey: String, hint: String?, router: ToolRouter) async throws -> String {
        let list = try await router.dispatch(toolName: "registry_list", arguments: .object([
            "entity": .string(entityKey),
            "limit": .int(100),
        ]))
        guard case .object(let envelope) = list,
              case .array(let rows)? = envelope["rows"] else {
            throw VoiceMemoError.registryMatchFailed(entityKey, hint)
        }
        let normalizedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pairs: [(id: String, title: String)] = rows.compactMap { row in
            guard case .object(let rowObj) = row,
                  case .string(let id)? = rowObj["id"],
                  case .string(let title)? = rowObj["title"] else { return nil }
            return (id, title)
        }

        // Containment match — collect ALL candidates; ≥2 distinct rows ⇒ ambiguous.
        // PKT-MEM-106 0a: do not silently auto-pick the first of several matches; an
        // ambiguous hint must route to a manual / picker decision, never a wrong-row write.
        if let hint = normalizedHint, !hint.isEmpty {
            var matches: [String] = []
            for (id, title) in pairs {
                let t = title.lowercased()
                if t.contains(hint) || hint.contains(t) { matches.append(id) }
            }
            let distinct = Set(matches)
            if distinct.count == 1, let only = matches.first { return only }
            if distinct.count >= 2 { throw VoiceMemoError.registryAmbiguous(entityKey, hint, distinct.count) }
        }

        // Regex fallback — same ambiguity rule.
        if let hint = normalizedHint,
           let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: hint), options: .caseInsensitive) {
            var matches: [String] = []
            for (id, title) in pairs where regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil {
                matches.append(id)
            }
            let distinct = Set(matches)
            if distinct.count == 1, let only = matches.first { return only }
            if distinct.count >= 2 { throw VoiceMemoError.registryAmbiguous(entityKey, hint, distinct.count) }
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
                transcriptExcerpt: "",
                intentId: VoiceMemoIntentIdentity.intentId(
                    memoId: recording.id, kind: VoiceMemoIntentKind.review.rawValue,
                    entityKey: nil, entityHint: nil, title: recording.title, fields: [:]
                ),
                provenance: "no-transcript"
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

    static func appendSummaryBodyToNotionPage(
        pageId: String,
        plan: VoiceMemoPlan,
        fields: [String: String],
        router: ToolRouter
    ) async throws {
        let summaryText = fields["summary"] ?? plan.summary
        let trimmed = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var children: [[String: Any]] = [
            [
                "object": "block",
                "type": "heading_2",
                "heading_2": [
                    "rich_text": [["type": "text", "text": ["content": "Summary"]]],
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
        if !plan.actions.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["type": "text", "text": ["content": "Action items"]]],
                ],
            ])
            for action in plan.actions.prefix(12) {
                children.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": [
                        "rich_text": [["type": "text", "text": ["content": String(action.prefix(1900))]]],
                    ],
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: children)
        guard let json = String(data: data, encoding: .utf8) else { return }
        _ = try await router.dispatch(toolName: "notion_blocks_append", arguments: .object([
            "blockId": .string(pageId),
            "children": .string(json),
        ]))
    }

    /// Legacy transcript append — retained for explicit opt-in callers only.
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
        reviewQueued: inout Int,
        reviewTag: VoiceMemoReviewTag? = nil,
        provenance: String = "election"
    ) {
        let tag = reviewTag ?? inferredReviewTag(reason: reason, confidence: intent.confidence)
        try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
            memoId: recording.id,
            memoTitle: plan.generatedTitle,
            memoPath: recording.path,
            intentKind: intent.kind.rawValue,
            confidence: intent.confidence,
            reason: reason,
            transcriptExcerpt: String((recording.transcript ?? plan.summary).prefix(500)),
            intentId: VoiceMemoIntentIdentity.intentId(memoId: recording.id, intent: intent),
            entityKey: intent.entityKey,
            entityHint: intent.entityHint,
            destinationFields: intent.fields.isEmpty ? nil : intent.fields,
            provenance: provenance,
            reviewTag: tag.rawValue
        ))
        reviewQueued += 1
    }

    static func inferredReviewTag(reason: String, confidence: Double) -> VoiceMemoReviewTag {
        VoiceMemoReviewTag.derive(from: VoiceMemoReviewEntry(
            memoId: "",
            memoTitle: "",
            intentKind: "",
            confidence: confidence,
            reason: reason,
            transcriptExcerpt: ""
        ))
    }

    public static func recordAgentDeferred(
        recording: VoiceMemoRecording,
        plan: VoiceMemoPlan,
        reason: String,
        now: Date = Date()
    ) {
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: now),
            memoId: recording.id,
            phase: .execute,
            action: "agent_deferred",
            status: plan.degraded ? "degraded" : "ok",
            provenance: plan.provenance.rawValue,
            actor: "curator",
            detail: String(reason.prefix(240))
        )
        try? MemoryHubActivityLog.append(event, now: now)
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

    public static func receiptValue(_ receipt: VoiceMemoReceipt) -> Value {
        var obj: [String: Value] = [
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
        ]
        // FRONTIER-FIRST W4: surface the Understand-chain arm so the autonomous-path
        // envelope is auditable (esp. that a CLOUD send occurred). Additive — older
        // consumers ignore unknown keys.
        if let provenance = receipt.provenance {
            obj["provenance"] = .string(provenance.rawValue)
            obj["degraded"] = .bool(receipt.degraded)
        }
        return .object(obj)
    }

    /// PRIVACY audit (FRONTIER-FIRST W4): when the winning Understand provenance is
    /// `.cloud`, the WHOLE transcript was sent off-device — write ONE durable
    /// `.understand` receipt to the activity log so the operator can later see it
    /// happened (critical for the silent scheduled-curator path). The detail carries a
    /// SHA-256 hash + short excerpt via `transcriptEvidence`, NEVER the full transcript.
    /// Non-cloud arms write nothing (local/heuristic stay on-device). Best-effort — a
    /// failed append never blocks processing. `now` is injectable for hermetic tests.
    public static func recordUnderstandCloudSend(
        recording: VoiceMemoRecording,
        plan: VoiceMemoPlan,
        transcript: String,
        now: Date = Date()
    ) {
        guard plan.provenance == .cloud else { return }
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: now),
            memoId: recording.id,
            phase: .understand,
            action: "cloud_parse",
            status: plan.degraded ? "degraded" : "ok",
            provenance: "cloud",
            actor: "curator",
            detail: MemoryHubActivityLog.transcriptEvidence(transcript)
        )
        try? MemoryHubActivityLog.append(event, now: now)
    }

    private static func stringArg(_ obj: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s }
        return nil
    }

    // MARK: - Get / Commit (PKT-MEM-110)

    public static func get(args: Value, router: ToolRouter) async throws -> Value {
        let options = options(from: args)
        guard let memoId = options.memoId ?? stringArg(fromValue: args, "memoId") else {
            throw VoiceMemoError.invalidIntent("missing memoId")
        }
        let recordings = VoiceMemoDiscovery.listRecordings(roots: options.recordingRoots, transcriptLoader: options.transcriptLoader)
        guard let recording = recordings.first(where: { $0.id == memoId || $0.path == memoId }) else {
            throw VoiceMemoError.invalidIntent("memo not found: \(memoId)")
        }
        let understand: Bool = {
            guard case .object(let obj) = args, case .bool(let b)? = obj["understand"] else { return true }
            return b
        }()
        let providerMode = stringArg(fromValue: args, "provider").flatMap { VoiceMemoCuratorMode(rawValue: $0.lowercased()) }

        if understand {
            let (transcript, plan) = try await buildPlan(for: recording, options: options, curatorMode: providerMode)
            return .object([
                "memo": memoValue(recording, transcript: transcript),
                "plan": planValue(plan),
                "understood": .bool(true),
                "curatorMode": .string(VoiceMemoCuratorRouter.effectiveMode().rawValue),
                "processed": .bool(VoiceMemoProcessedStore.isProcessed(id: recording.id)),
            ])
        }

        let inspected = inspectTranscript(for: recording)
        let transcript = inspected.text ?? ""
        return .object([
            "memo": memoValue(recording, transcript: transcript),
            "understood": .bool(false),
            "needsTranscript": .bool(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            "curatorMode": .string(VoiceMemoCuratorRouter.effectiveMode().rawValue),
            "processed": .bool(VoiceMemoProcessedStore.isProcessed(id: recording.id)),
        ])
    }

    /// Cheap inspect: cached sidecar / list preview only — no transcription ladder or Understand.
    public static func inspectTranscript(for recording: VoiceMemoRecording) -> VoiceMemoTranscriptResolution {
        if let cached = recording.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return VoiceMemoTranscriptResolution(text: cached, source: recording.transcriptSource)
        }
        let audioURL = URL(fileURLWithPath: recording.path, isDirectory: false)
        if let sidecar = VoiceMemoDiscovery.loadTranscriptSidecar(for: audioURL) {
            let source = VoiceMemoDiscovery.loadTranscriptMeta(for: audioURL)?.source ?? .sidecar
            return VoiceMemoTranscriptResolution(text: sidecar, source: source)
        }
        if BridgeDefaults.voiceMemoAppleTranscriptEffective,
           let apple = AppleVoiceMemoTranscriptExtractor.extract(from: audioURL) {
            return VoiceMemoTranscriptResolution(text: apple, source: .apple)
        }
        return VoiceMemoTranscriptResolution(text: nil, source: .none)
    }

    static func logUnderstandActivity(
        memoId: String,
        phase: MemoryHubActivityEvent.Phase,
        action: String,
        status: String,
        provenance: String,
        detail: String,
        eventType: MemoryHubActivityEventType = .unknown
    ) {
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            memoId: memoId,
            phase: phase,
            eventType: eventType,
            action: action,
            status: status,
            provenance: provenance,
            actor: "operator",
            detail: String(detail.prefix(240))
        )
        try? MemoryHubActivityLog.append(event)
    }

    static func buildPlan(
        for recording: VoiceMemoRecording,
        options: Options,
        curatorMode: VoiceMemoCuratorMode? = nil
    ) async throws -> (transcript: String, plan: VoiceMemoPlan) {
        let memoId = recording.id
        logUnderstandActivity(
            memoId: memoId, phase: .transcribe, action: "understand_transcribe",
            status: "running", provenance: curatorMode?.rawValue ?? VoiceMemoCuratorRouter.effectiveMode().rawValue,
            detail: "Starting transcription ladder", eventType: .memoTranscribed
        )
        let audioURL = URL(fileURLWithPath: recording.path, isDirectory: false)
        let resolved = try await VoiceMemoDiscovery.resolveTranscript(for: audioURL)
        guard let transcript = resolved.text else {
            throw VoiceMemoError.invalidIntent("no transcript for memo")
        }
        logUnderstandActivity(
            memoId: memoId, phase: .transcribe, action: "understand_transcribe",
            status: "ok", provenance: resolved.source.rawValue,
            detail: MemoryHubActivityLog.transcriptEvidence(transcript), eventType: .memoTranscribed
        )

        logUnderstandActivity(
            memoId: memoId, phase: .understand, action: "understand_parse",
            status: "running", provenance: curatorMode?.rawValue ?? "auto",
            detail: "Parsing intents", eventType: .providerCallStarted
        )
        var plan = await VoiceMemoParseRouter.parse(
            transcript: transcript,
            fallbackTitle: recording.title,
            recordingPath: recording.path,
            curatorMode: curatorMode
        )
        logUnderstandActivity(
            memoId: memoId, phase: .understand, action: "understand_parse",
            status: plan.degraded ? "degraded" : "ok", provenance: plan.provenance.rawValue,
            detail: "\(plan.intents.count) intent(s)", eventType: .providerCallCompleted
        )

        let needsLLM = plan.intents.contains { $0.kind == .memoryKeep }
            && VoiceMemoCuratorRouter.shouldSummarizeForMemoryKeep()
        let summary: String
        let actions: [String]
        if needsLLM {
            logUnderstandActivity(
                memoId: memoId, phase: .plan, action: "understand_summarize",
                status: "running", provenance: plan.provenance.rawValue,
                detail: "Structured summary for memory_keep", eventType: .memoSummarized
            )
            let structured = await VoiceMemoSummarizer.structuredSummary(
                transcript: transcript, fallbackTitle: recording.title
            )
            summary = structured.paragraph
            actions = structured.actions
            logUnderstandActivity(
                memoId: memoId, phase: .plan, action: "understand_summarize",
                status: "ok", provenance: plan.provenance.rawValue,
                detail: "\(structured.actions.count) action(s)", eventType: .memoSummarized
            )
        } else {
            summary = VoiceMemoParser.firstSentencePublic(in: transcript, maxLen: 280)
            actions = VoiceMemoParser.extractActionBulletsPublic(from: transcript)
        }
        var updated = applySummary(to: plan, summary: summary, transcript: transcript, recordingPath: recording.path)
        if !actions.isEmpty { updated.actions = actions }
        plan = updated
        logUnderstandActivity(
            memoId: memoId, phase: .plan, action: "understand_ready",
            status: "ok", provenance: plan.provenance.rawValue,
            detail: "Plan ready for Confirm", eventType: .unknown
        )
        return (transcript, plan)
    }

    /// Backward-compatible overload used by process/commit paths.
    static func buildPlan(for recording: VoiceMemoRecording, options: Options) async throws -> (transcript: String, plan: VoiceMemoPlan) {
        try await buildPlan(for: recording, options: options, curatorMode: nil)
    }

    public static func commit(args: Value, router: ToolRouter) async throws -> Value {
        guard case .object(let obj) = args,
              case .string(let memoId)? = obj["memoId"],
              case .string(let kindRaw)? = obj["intentKind"],
              let kind = VoiceMemoIntentKind(rawValue: kindRaw) else {
            throw VoiceMemoError.invalidIntent("missing memoId or intentKind")
        }
        var options = options(from: args)
        options.memoId = memoId
        let recordings = VoiceMemoDiscovery.listRecordings(roots: options.recordingRoots, transcriptLoader: options.transcriptLoader)
        guard let recording = recordings.first(where: { $0.id == memoId || $0.path == memoId }) else {
            throw VoiceMemoError.invalidIntent("memo not found: \(memoId)")
        }
        let (transcript, plan) = try await buildPlan(for: recording, options: options)
        var intent = plan.intents.first { $0.kind == kind } ?? VoiceMemoIntent(kind: kind, confidence: 1.0)
        if let entityKey = stringArg(obj, "entityKey") { intent.entityKey = entityKey }
        if let hint = stringArg(obj, "entityHint") { intent.entityHint = hint }
        if let title = stringArg(obj, "title") { intent.title = title }
        if let due = stringArg(obj, "due") { intent.dueISO8601 = due }
        if case .object(let fieldObj)? = obj["fields"] {
            intent.fields = fieldObj.compactMapValues { if case .string(let s) = $0 { return s }; return nil }
        }
        let explicitRowId = stringArg(obj, "rowId")

        // Execute the lane. registry_update threads an explicit rowId straight to the
        // writer (rowId wins over entityHint — PKT-MEM-106 0a). An ambiguous/unresolved
        // registry target surfaces as a manual outcome WITHOUT writing or marking processed.
        let detail: String
        do {
            if kind == .registryUpdate {
                detail = try await executeRegistryUpdate(intent, explicitRowId: explicitRowId, router: router)
            } else {
                detail = try await execute(intent: intent, plan: plan, transcript: transcript, router: router)
            }
        } catch let error as VoiceMemoError {
            if case .registryAmbiguous = error {
                return .object([
                    "ok": .bool(false),
                    "needsManual": .bool(true),
                    "memoId": .string(recording.id),
                    "intentKind": .string(kind.rawValue),
                    "detail": .string(error.localizedDescription),
                    "markedProcessed": .bool(false),
                ])
            }
            throw error
        }

        // Processed-gate (PKT-MEM-106 0a): resolve the pending review entry this commit
        // satisfies — the one whose intentId matches this intent, plus any generic
        // "needs review" / agent-defer placeholder for the memo — THEN mark processed only
        // when no pending sibling review remains. A multi-lane memo is processed only after
        // its last lane commits (the M5/M8 contract).
        let committedIntentId = VoiceMemoIntentIdentity.intentId(memoId: recording.id, intent: intent)
        for entry in VoiceMemoReviewStore.load().entries
        where entry.memoId == recording.id && entry.status == .pending {
            let matchesIntent = entry.effectiveIntentId() == committedIntentId
            let isPlaceholder = entry.intentKind == VoiceMemoIntentKind.review.rawValue
            if matchesIntent || isPlaceholder {
                try? VoiceMemoReviewStore.resolve(id: entry.id)
            }
        }
        let markedProcessed = try VoiceMemoProcessedGate.markProcessedIfClear(memoId: recording.id)
        return .object([
            "ok": .bool(true),
            "memoId": .string(recording.id),
            "intentKind": .string(kind.rawValue),
            "detail": .string(detail),
            "markedProcessed": .bool(markedProcessed),
        ])
    }

    static func memoValue(_ recording: VoiceMemoRecording, transcript: String) -> Value {
        .object([
            "id": .string(recording.id),
            "title": .string(recording.title),
            "path": .string(recording.path),
            "recordedAt": .string(ISO8601DateFormatter().string(from: recording.recordedAt)),
            "transcriptSource": .string(recording.transcriptSource.rawValue),
            "transcript": .string(transcript),
            "processed": .bool(VoiceMemoProcessedStore.isProcessed(id: recording.id)),
        ])
    }

    static func planValue(_ plan: VoiceMemoPlan) -> Value {
        // `provenance` + `degraded` (FRONTIER-FIRST W1) are carried into the envelope so the
        // Process cockpit can surface a provenance badge (W3). Additive — existing consumers
        // ignore unknown keys; the only reader (`MemoryProcessTab.parsePlan`) defaults them.
        .object([
            "generatedTitle": .string(plan.generatedTitle),
            "skipMemoryKeep": .bool(plan.skipMemoryKeep),
            "summary": .string(plan.summary),
            "actions": .array(plan.actions.map { .string($0) }),
            "intents": .array(plan.intents.map(intentValue)),
            "provenance": .string(plan.provenance.rawValue),
            "degraded": .bool(plan.degraded),
        ])
    }

    static func intentValue(_ intent: VoiceMemoIntent) -> Value {
        var obj: [String: Value] = [
            "kind": .string(intent.kind.rawValue),
            "confidence": .double(intent.confidence),
        ]
        if let entityKey = intent.entityKey { obj["entityKey"] = .string(entityKey) }
        if let hint = intent.entityHint { obj["entityHint"] = .string(hint) }
        if let title = intent.title { obj["title"] = .string(title) }
        if let body = intent.body { obj["body"] = .string(body) }
        if !intent.fields.isEmpty {
            obj["fields"] = .object(intent.fields.mapValues { .string($0) })
        }
        return .object(obj)
    }

    private static func stringArg(fromValue args: Value, _ key: String) -> String? {
        guard case .object(let obj) = args else { return nil }
        return stringArg(obj, key)
    }
}

public enum VoiceMemoError: Error, LocalizedError {
    case invalidIntent(String)
    case registryMatchFailed(String, String?)
    case registryAmbiguous(String, String?, Int)
    /// The Memory entity has no BOUND PLAYERS relation property, so the
    /// originating Player cannot be attached — a graceful BLOCKED → REVIEW,
    /// never a silent successful processed receipt (PKT-1064).
    case playerRelationUnbound(String)
    /// The row was created but the read-back did not show the expected Player
    /// relation attached (PKT-1064 post-write verification).
    case playerRelationVerifyFailed(String, String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidIntent(let msg): return msg
        case .registryMatchFailed(let entity, let hint):
            return "no registry row matched entity=\(entity) hint=\(hint ?? "nil")"
        case .registryAmbiguous(let entity, let hint, let count):
            return "ambiguous registry target entity=\(entity) hint=\(hint ?? "nil") matched \(count) rows — select a rowId"
        case .playerRelationUnbound(let entity):
            return "entity ‘\(entity)’ has no bound PLAYERS relation property — cannot attach the originating Player; bind PLAYERS via registry_introspect, then reprocess (BLOCKED, queued for review)"
        case .playerRelationVerifyFailed(let entity, let pageId, let player):
            return "originating Player \(player) not present on created \(entity) row \(pageId) after read-back — attach verification failed (queued for review)"
        }
    }
}
