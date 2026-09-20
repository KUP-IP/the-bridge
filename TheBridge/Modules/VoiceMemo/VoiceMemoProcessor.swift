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
            // GH #73 — bound transcription so a wedged Parakeet/Apple-extractor call
            // cannot hang the whole voice_memo_process call indefinitely. A timeout
            // throws VoiceMemoStageTimeoutError, which this catch handles identically
            // to any other transcription failure — enqueue review, never hang.
            let resolved = try await VoiceMemoStageTimeout.run(
                stage: "transcribe",
                seconds: VoiceMemoStageTimeout.transcribeSeconds
            ) {
                try await VoiceMemoDiscovery.resolveTranscript(for: audioURL)
            }
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
        // GH #73 — bound the Understand stage. parseWithOptionalOllama/summarize are
        // non-throwing (they already `try?` their own provider call, which has its own
        // per-request timeoutInterval), but that per-request bound is not a bound on
        // the WHOLE async chain — a genuinely wedged local call (the exact GH #73
        // symptom: "Local Ollama reachable" yet the call never returned) must still
        // degrade to the heuristic floor rather than hang voice_memo_process forever.
        var plan = await understandStage(
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
        let structuredActions: [String]
        if needsLLMSummary {
            let structured = await structuredSummarizeStage(transcript: transcript, fallbackTitle: recording.title)
            llmSummary = structured.paragraph
            structuredActions = structured.actions
        } else {
            llmSummary = VoiceMemoParser.firstSentencePublic(in: transcript, maxLen: 280)
            structuredActions = []
        }
        plan = applySummary(to: plan, summary: llmSummary, transcript: transcript, recordingPath: recording.path)
        if !structuredActions.isEmpty { plan.actions = structuredActions }

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
                // GH #73 — bound the write/dispatch stage (Reminder/Memory/Notion writes
                // via router.dispatch have no built-in timeout). A stuck write now times
                // out into this SAME catch block that already handles any other execute()
                // failure — queues review, never hangs voice_memo_process indefinitely.
                // `plan` is snapshotted into a `let` before crossing into the @Sendable
                // timeout-race closure (strict concurrency forbids capturing a `var`).
                let planSnapshot = plan
                let detail = try await VoiceMemoStageTimeout.run(
                    stage: "execute",
                    seconds: VoiceMemoStageTimeout.executeSeconds
                ) {
                    try await execute(
                        intent: intent,
                        plan: planSnapshot,
                        transcript: transcript,
                        memoId: recording.id,
                        router: router
                    )
                }
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

    public static func execute(intent: VoiceMemoIntent, plan: VoiceMemoPlan, transcript: String, memoId: String = "", router: ToolRouter) async throws -> String {
        switch intent.kind {
        case .reminder:
            return try await executeReminder(intent, router: router, transcript: transcript)
        case .memoryKeep:
            return try await executeMemoryKeepWithFallbackPolicy(
                intent, plan: plan, transcript: transcript, router: router
            )
        case .agentMemory:
            return try await executeAgentMemory(intent, plan: plan, transcript: transcript, router: router)
        case .registryUpdate:
            return try await executeRegistryUpdate(intent, transcript: transcript, router: router)
        case .comment:
            return try await executeComment(intent, memoId: memoId, router: router)
        case .review:
            return "queued for review — no auto-write"
        }
    }

    /// SC8 — Notion Memory failure routes through an explicit policy (default: review).
    static func executeMemoryKeepWithFallbackPolicy(
        _ intent: VoiceMemoIntent,
        plan: VoiceMemoPlan,
        transcript: String,
        router: ToolRouter
    ) async throws -> String {
        do {
            return try await executeMemoryKeep(intent, plan: plan, transcript: transcript, router: router)
        } catch {
            switch BridgeDefaults.voiceMemoMemoryFallbackPolicyEffective {
            case .off:
                throw error
            case .review:
                throw VoiceMemoError.memoryFallbackReview(
                    intent.entityKey ?? "memory",
                    BridgeDefaults.VoiceMemoMemoryFallbackPolicy.review.rawValue,
                    error.localizedDescription
                )
            case .agentMemory:
                let detail = try await executeAgentMemory(intent, plan: plan, transcript: transcript, router: router)
                return "\(detail) [fallback=agent_memory policy=agentMemory reason=\(error.localizedDescription)]"
            }
        }
    }

    static func executeReminder(_ intent: VoiceMemoIntent, router: ToolRouter, transcript: String = "") async throws -> String {
        let rawTitle = intent.title ?? ""
        let resolvedTitle: String
        switch VoiceMemoReminderTitleGate.evaluate(rawTitle, transcript: transcript) {
        case .ok(let title):
            resolvedTitle = title
        case .rejected(_, let fallback):
            resolvedTitle = fallback
        }
        guard !resolvedTitle.isEmpty else {
            throw VoiceMemoError.invalidIntent("reminder missing title")
        }
        var args: [String: Value] = ["title": .string(resolvedTitle)]
        if let notes = intent.body { args["notes"] = .string(notes) }
        if let due = intent.dueISO8601 { args["due"] = .string(due) }
        _ = try await router.dispatch(toolName: "reminders_create", arguments: .object(args))
        return "reminders_create: \(resolvedTitle)"
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
            entity: await Self.loadRegistryEntity(key: entityKey),
            catalog: await VoiceMemoRelationCatalog.loadFromSharedCache()
        )
    }

    /// Testable core: `entity` is the resolved registry binding for `entityKey`
    /// (the property map that decides whether a PLAYERS relation can be
    /// attached). Production resolves it from the shared config store; tests
    /// inject a fixture entity so the attach/verify/graceful-BLOCKED branches
    /// are exercised hermetically without live Notion. `catalog` defaults empty
    /// so hermetic tests never scan the live registry cache.
    @discardableResult
    public static func executeMemoryKeep(
        entityKey: String,
        intent: VoiceMemoIntent,
        plan: VoiceMemoPlan,
        transcript: String,
        router: ToolRouter,
        entity: RegistryEntity?,
        catalog: VoiceMemoRelationCatalog = VoiceMemoRelationCatalog()
    ) async throws -> String {
        let proposedFields = resolvedMemoryKeepFields(intent: intent, plan: plan)

        // The durable Memory summary is authored page content first. A live
        // registry may bind the canonical `summary` key to a non-text property
        // (the operator's Memory DB currently maps it to the `Relevant` select),
        // so the semantic summary cannot be assumed to be a writable property.
        let semanticSummary: String = {
            if let field = proposedFields["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
                return field
            }
            let body = intent.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !body.isEmpty { return body }
            return plan.summary
        }()

        // GH #81 — minimum-information quality gate BEFORE any Notion write.
        if case .rejected(let reason) = VoiceMemoContentQualityGate.evaluate(semanticSummary) {
            throw VoiceMemoError.contentQualityRejected(entityKey, reason)
        }

        // Adapt legacy plan fields to the LIVE Memory registry before any write:
        // unknown retired keys are dropped; prose goes into a rich_text summary
        // property only when the registry actually exposes one. A select/status
        // property must never receive the prose summary.
        var createFields = memoryKeepCreateFields(
            proposed: proposedFields,
            semanticSummary: semanticSummary,
            entity: entity
        )

        // PKT-MEM-132 D49 — protect the semantic summary (page body, and a
        // rich_text property when one exists) plus every other property that
        // will actually be sent to Notion. Report the canonical `summary` key
        // when the prose overlaps the transcript, even if the live registry
        // maps that key to a non-text column such as `Relevant`.
        if let rejected = VoiceMemoTranscriptOverlapGuard.firstRejectedField(
            in: ["summary": semanticSummary], transcript: transcript
        ) {
            throw VoiceMemoError.transcriptOverlapRejected(entityKey, rejected.key, rejected.runLength)
        }
        if let rejected = VoiceMemoTranscriptOverlapGuard.firstRejectedField(in: createFields, transcript: transcript) {
            throw VoiceMemoError.transcriptOverlapRejected(entityKey, rejected.key, rejected.runLength)
        }

        // SC2 — fail closed when required write fields (esp. summary/title) are
        // unbound BEFORE any Notion create. Surfaces candidate Notion names for
        // rebind via registry_introspect.
        if let entity {
            try Self.preflightMemoryKeepBindings(entity: entity, fields: createFields)
        }

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
        createFields[playersKey] = originatingPlayerId

        let haystack = [
            intent.title ?? plan.generatedTitle,
            semanticSummary,
            plan.actions.joined(separator: " "),
            transcript,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        let relationMatch = VoiceMemoMemoryRelationMatcher.match(haystack: haystack, catalog: catalog)
        applyBoundRelationMatches(relationMatch, to: &createFields, entity: entity)

        let createResult = try await router.dispatch(toolName: "registry_create", arguments: .object([
            "entity": .string(entityKey),
            "fields": .object(createFields.mapValues { .string($0) }),
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
        try await appendSummaryBodyToNotionPage(
            pageId: pageId,
            plan: plan,
            summaryText: semanticSummary,
            transcript: transcript,
            matchNotes: relationMatch.notes,
            router: router
        )
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

    /// Bound relation key whose Notion column matches `notionName`
    /// case-insensitively, or nil when absent/unbound. Unbound keys are skipped
    /// (not a BLOCK) so Memory create still lands with PLAYERS.
    public static func boundRelationKey(named notionName: String, in entity: RegistryEntity?) -> String? {
        guard let entity else { return nil }
        let want = notionName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let match = entity.properties.first { prop in
            prop.role == .relation
                && prop.isBound
                && prop.notionName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == want
        }
        return match?.key
    }

    static func applyBoundRelationMatches(
        _ match: VoiceMemoRelationMatch,
        to fields: inout [String: String],
        entity: RegistryEntity?
    ) {
        func put(_ notionName: String, ids: [String]) {
            guard !ids.isEmpty, let key = boundRelationKey(named: notionName, in: entity) else { return }
            fields[key] = ids.joined(separator: ",")
        }
        put("CONTACTS", ids: match.contactIds)
        put("PROJECTS", ids: match.projectIds)
        put("DOCS", ids: match.docIds)
        put("BLOCKS", ids: match.blockIds)
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

    public static func executeRegistryUpdate(
        _ intent: VoiceMemoIntent,
        explicitRowId: String? = nil,
        transcript: String,
        router: ToolRouter
    ) async throws -> String {
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
        // PKT-MEM-132 D49 — same pre-write guard as executeMemoryKeep, on the
        // MERGED field set (append-only fields wrap the raw proposed value
        // with a timestamp stamp but do not strip an embedded verbatim
        // transcript run, so checking post-merge still catches it; checking
        // every key also covers non-append fields the merge leaves untouched).
        if let rejected = VoiceMemoTranscriptOverlapGuard.firstRejectedField(in: merged, transcript: transcript) {
            throw VoiceMemoError.transcriptOverlapRejected(entityKey, rejected.key, rejected.runLength)
        }
        let fields = merged.mapValues { Value.string($0) }
        _ = try await router.dispatch(toolName: "registry_update", arguments: .object([
            "entity": .string(entityKey),
            "id": .string(rowId),
            "fields": .object(fields),
        ]))
        return "registry_update entity=\(entityKey) id=\(rowId) (append)"
    }

    // MARK: - executeComment (PKT-MEM-136 / D48)

    /// The canonical field a comment-post's receipt marker is appended to, as
    /// PART of the SAME `registry_resolve_and_update` call that resolves the
    /// target page (that tool requires non-empty `fields` — it is "resolve AND
    /// update", not a pure lookup — so the comment-post leaves the SAME kind of
    /// dated append-log receipt every other voice-memo → registry write already
    /// leaves, e.g. `executeMemoryKeep`'s body append and
    /// `mergeAppendRegistryFields`'s existing behavior). `summary` is the most
    /// broadly-bound canonical key across configured entities; an entity
    /// without it bound throws `RegistryWriteError`/`ToolRouterError` from the
    /// underlying tool, which — like every other failure in this function —
    /// propagates up to `processOne`'s catch-all (queues REVIEW, never a crash).
    public static let commentReceiptField = "summary"

    /// Executes a `.comment` intent: resolve the target page via
    /// `registry_resolve_and_update` (PKT-MEM-135) — NOT a bespoke resolution
    /// path (GOAL_CONDITION) — then post the comment via `notion_comment_create`.
    /// `idea`-purpose comments are logged to `VoiceMemoIdeaThreadStore`;
    /// `reflow`-purpose comments are posted the same way but never logged
    /// (fire-and-forget, D48). Any resolution or post failure throws (never a
    /// crash) so the caller's existing catch routes the memo to REVIEW.
    public static func executeComment(_ intent: VoiceMemoIntent, memoId: String, router: ToolRouter) async throws -> String {
        guard let entityKey = intent.entityKey else {
            throw VoiceMemoError.invalidIntent("comment missing entity key")
        }
        guard let purpose = intent.purpose else {
            throw VoiceMemoError.invalidIntent("comment missing required purpose (idea | reflow)")
        }
        let text = (intent.body ?? intent.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceMemoError.invalidIntent("comment missing text (body/title)")
        }
        guard let hint = intent.entityHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else {
            throw VoiceMemoError.commentTargetUnresolved(entityKey, "missing entityHint — nothing to resolve the target page against")
        }
        guard let entity = await Self.loadRegistryEntity(key: entityKey) else {
            throw VoiceMemoError.commentTargetUnresolved(entityKey, "entity not configured in the registry")
        }
        guard let titleKey = entity.titleProperty?.key else {
            throw VoiceMemoError.commentTargetUnresolved(entityKey, "entity has no title-role property — cannot predicate-match by entityHint")
        }

        let pageId: String
        do {
            let resolved = try await router.dispatch(toolName: "registry_resolve_and_update", arguments: .object([
                "entity": .string(entityKey),
                "where": .object([titleKey: .string(hint)]),
                "fields": .object([commentReceiptField: .string("Voice memo comment posted (\(purpose.rawValue)).")]),
            ]))
            guard case .object(let envelope) = resolved,
                  case .string(let matchedId)? = envelope["matchedId"], !matchedId.isEmpty else {
                throw VoiceMemoError.commentTargetUnresolved(entityKey, "registry_resolve_and_update returned no matchedId")
            }
            pageId = matchedId
        } catch let error as VoiceMemoError {
            throw error
        } catch {
            // registry_resolve_and_update throws ToolRouterError.invalidArguments for
            // both no-match and ambiguous-match (RegistryResolveError, re-wrapped inside
            // the tool handler) — surface it as a graceful BLOCKED, not a crash.
            throw VoiceMemoError.commentTargetUnresolved(entityKey, error.localizedDescription)
        }

        let commentResult = try await router.dispatch(toolName: "notion_comment_create", arguments: .object([
            "pageId": .string(pageId),
            "text": .string(text),
        ]))
        guard case .object(let commentEnvelope) = commentResult,
              case .bool(true)? = commentEnvelope["success"] else {
            throw VoiceMemoError.commentPostFailed(entityKey, pageId)
        }
        let discussionId: String = {
            if case .string(let d)? = commentEnvelope["discussionId"] { return d }
            return ""
        }()

        if purpose == .idea {
            try? VoiceMemoIdeaThreadStore.enqueue(VoiceMemoIdeaThreadEntry(
                memoId: memoId,
                discussionId: discussionId,
                targetEntityKey: entityKey,
                targetPageId: pageId
            ))
        }

        return "notion_comment_create entity=\(entityKey) id=\(pageId) purpose=\(purpose.rawValue) discussionId=\(discussionId)"
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

    /// Resolve `hint` to an existing row id via `registry_find` (PKT-1041) — the
    /// convergent, server-side, bound-property-id lookup that replaced this
    /// function's original hand-rolled `registry_list` + containment/regex
    /// matching (PKT-MEM-131). The predicate key is the entity's own canonical
    /// title-property key when the entity is resolvable from the shared config
    /// store, else the `"title"` convention (`RegistryHydration`'s default for
    /// non-Skills entities) — so a not-yet-configured entity (first run) still
    /// dispatches a well-formed call instead of guessing a wrong key.
    ///
    /// SC4: when exact match fails, a unique first-name / first-token title match
    /// resolves deterministically; ≥2 first-name matches throw `registryAmbiguous`
    /// with candidate `{id,title}` pairs (never an auto-picked write).
    public static func resolveRegistryRowId(entityKey: String, hint: String?, router: ToolRouter) async throws -> String {
        let normalizedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHint, !normalizedHint.isEmpty else {
            throw VoiceMemoError.registryMatchFailed(entityKey, hint)
        }
        let titleKey = await loadRegistryEntity(key: entityKey)?.titleProperty?.key ?? "title"

        let found = try await router.dispatch(toolName: "registry_find", arguments: .object([
            "entity": .string(entityKey),
            "where": .object([titleKey: .string(normalizedHint)]),
        ]))
        if case .object(let envelope) = found, case .array(let rows)? = envelope["rows"] {
            let ids: [String] = rows.compactMap { row in
                guard case .object(let rowObj) = row, case .string(let id)? = rowObj["id"] else { return nil }
                return id
            }
            let distinct = Set(ids)
            if distinct.count == 1, let only = ids.first { return only }
            if distinct.count >= 2 {
                let candidates = Self.candidatePairs(from: rows)
                throw VoiceMemoError.registryAmbiguous(entityKey, hint, distinct.count, candidates)
            }
        }

        // SC4 — exact miss: first-name / first-token uniqueness scan via list.
        let listed = try await router.dispatch(toolName: "registry_list", arguments: .object([
            "entity": .string(entityKey),
            "limit": .int(200),
            "fields": .array([.string("title"), .string("id")]),
        ]))
        let firstName = normalizedHint
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased() ?? ""
        guard !firstName.isEmpty else {
            throw VoiceMemoError.registryMatchFailed(entityKey, hint)
        }
        var firstNameHits: [(id: String, title: String)] = []
        if case .object(let listEnv) = listed, case .array(let listRows)? = listEnv["rows"] {
            for row in listRows {
                guard case .object(let rowObj) = row,
                      case .string(let id)? = rowObj["id"] else { continue }
                let title = Self.rowTitle(from: rowObj) ?? ""
                let titleFirst = title
                    .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased() ?? ""
                if titleFirst == firstName || title.lowercased().hasPrefix(firstName + " ") {
                    firstNameHits.append((id, title.isEmpty ? id : title))
                }
            }
        }
        let distinctFirst = Dictionary(grouping: firstNameHits, by: \.id)
        if distinctFirst.count == 1, let only = firstNameHits.first {
            return only.id
        }
        if distinctFirst.count >= 2 {
            let candidates = firstNameHits.map { "\($0.id)|\($0.title)" }
            throw VoiceMemoError.registryAmbiguous(entityKey, hint, distinctFirst.count, candidates)
        }
        throw VoiceMemoError.registryMatchFailed(entityKey, hint)
    }

    /// Convert the parser's legacy Memory envelope into the properties the
    /// CURRENT registry entity can safely accept. Voice-memo summaries are page
    /// content; they are mirrored into a property only when `summary` is
    /// `rich_text`. This prevents prose from being coerced into a live select
    /// such as `Relevant`, while preserving older text-backed Memory schemas.
    public static func memoryKeepCreateFields(
        proposed: [String: String],
        semanticSummary: String,
        entity: RegistryEntity?
    ) -> [String: String] {
        guard let entity else { return proposed }

        // Parser plans can outlive registry schema changes. Only send canonical
        // keys the live entity declares; retired metadata fields are not writes.
        var adapted = proposed.filter { entity.property($0.key) != nil }

        if let summaryProperty = entity.property("summary"),
           summaryProperty.type.lowercased() == "rich_text" {
            adapted["summary"] = semanticSummary
        } else {
            adapted.removeValue(forKey: "summary")
        }
        return adapted
    }

    /// SC2 — required Notion-bound fields must be bound before any write.
    public static func preflightMemoryKeepBindings(entity: RegistryEntity, fields: [String: String]) throws {
        let input = fields.mapValues { Value.string($0) }
        let resolved = RegistryWriter.resolve(input, entity: entity)
        var unbound = resolved.unbound
        // Title is always required. Summary is required only when it is part of
        // the adapted property payload; non-text summary columns are deliberately
        // excluded because the semantic summary lives in the page body.
        if let titleProp = entity.titleProperty, !titleProp.isBound,
           !unbound.contains(titleProp.key) {
            unbound.append(titleProp.key)
        }
        guard !unbound.isEmpty else { return }
        let candidates = unbound.compactMap { key -> String? in
            guard let prop = entity.property(key) else { return key }
            let alts = entity.properties
                .filter { $0.key != key && !$0.isBound }
                .prefix(3)
                .map(\.notionName)
            if alts.isEmpty { return "\(key) (Notion: \(prop.notionName))" }
            return "\(key) (Notion: \(prop.notionName); nearby unbound: \(alts.joined(separator: ", ")))"
        }
        throw VoiceMemoError.requiredFieldsUnbound(entity.key, unbound.sorted(), candidates)
    }

    private static func candidatePairs(from rows: [Value]) -> [String] {
        rows.compactMap { row -> String? in
            guard case .object(let rowObj) = row,
                  case .string(let id)? = rowObj["id"] else { return nil }
            let title = rowTitle(from: rowObj) ?? id
            return "\(id)|\(title)"
        }
    }

    private static func rowTitle(from rowObj: [String: Value]) -> String? {
        if case .string(let t)? = rowObj["title"], !t.isEmpty { return t }
        if case .object(let props)? = rowObj["properties"] {
            for key in ["title", "name"] {
                if case .string(let t)? = props[key], !t.isEmpty { return t }
            }
        }
        return nil
    }

    static func resolvedMemoryKeepFields(intent: VoiceMemoIntent, plan: VoiceMemoPlan) -> [String: String] {
        let overrideTitle = intent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if intent.fields.isEmpty {
            return VoiceMemoParser.memoryKeepFields(
                title: overrideTitle.isEmpty ? plan.generatedTitle : overrideTitle,
                summary: plan.summary,
                actions: plan.actions
            )
        }

        var fields = intent.fields
        if !overrideTitle.isEmpty {
            fields["title"] = overrideTitle
            return fields
        }

        let existingTitle = fields["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existingTitle.isEmpty {
            return fields
        }

        let semantic = [
            fields["summary"],
            intent.body,
            plan.summary,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let fromSummary = VoiceMemoParser.sanitizeTitle(
            nil,
            fallback: VoiceMemoParser.firstSentencePublic(in: semantic, maxLen: 72)
        )
        if !fromSummary.isEmpty {
            fields["title"] = fromSummary
        }
        return fields
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
        summaryText: String,
        transcript: String = "",
        matchNotes: [String] = [],
        router: ToolRouter
    ) async throws {
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
        let actions = memoryKeepActionItems(plan: plan, summaryText: trimmed, transcript: transcript)
        if !actions.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["type": "text", "text": ["content": "Action items"]]],
                ],
            ])
            for action in actions.prefix(12) {
                children.append([
                    "object": "block",
                    "type": "to_do",
                    "to_do": [
                        "checked": false,
                        "rich_text": [["type": "text", "text": ["content": String(action.prefix(1900))]]],
                    ],
                ])
            }
        }
        if !matchNotes.isEmpty {
            children.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["type": "text", "text": ["content": "Unresolved names"]]],
                ],
            ])
            for note in matchNotes.prefix(12) {
                children.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": [
                        "rich_text": [["type": "text", "text": ["content": String(note.prefix(1900))]]],
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

    /// Plan actions first; otherwise lift "Next:" / "Next action:" / "I need to"
    /// prose from the summary, then the transcript. Never invent "Follow up."
    static func memoryKeepActionItems(plan: VoiceMemoPlan, summaryText: String, transcript: String = "") -> [String] {
        let fromPlan = plan.actions
            .map { stripLeadingNextLabel($0) }
            .filter { !$0.isEmpty && !isFollowUpFiller($0) }
        if !fromPlan.isEmpty { return Array(fromPlan.prefix(12)) }

        for source in [summaryText, transcript] {
            var fromProse = proseActionSentences(from: source)
            if fromProse.isEmpty {
                fromProse = VoiceMemoDegradedPreviewBuilder.build(from: source).actions
                    .map { stripLeadingNextLabel($0) }
                    .filter { !isFollowUpFiller($0) }
            }
            if !fromProse.isEmpty { return Array(fromProse.prefix(12)) }
        }
        return []
    }

    private static func isFollowUpFiller(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "follow up" || lower == "follow up." || lower == "follow-up" || lower == "follow-up."
    }

    /// Lifted checkboxes should not keep a "Next:" / "Next action:" label.
    static func stripLeadingNextLabel(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let prefixes = [
            "next action:", "next action —", "next action –", "next action -",
            "next:", "next —", "next –", "next -",
        ]
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private static func proseActionSentences(from text: String) -> [String] {
        let parts = text
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
        var out: [String] = []
        for raw in parts {
            let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= 12, !isFollowUpFiller(sentence) else { continue }
            let lower = sentence.lowercased()
            let isAction = lower.hasPrefix("next")
                || lower.hasPrefix("i need to")
                || lower.hasPrefix("i'll ")
                || lower.hasPrefix("i will ")
            guard isAction else { continue }
            let cleaned = stripLeadingNextLabel(sentence)
            guard cleaned.count >= 12, !isFollowUpFiller(cleaned) else { continue }
            out.append(cleaned)
        }
        return out
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

    // MARK: - Live UI sync (PKT-MEM-134)
    //
    // `voice_memo_get`/`voice_memo_commit` are the agent-deferred hand-off pair: a
    // connected MCP agent calls get to propose a plan, then commit to execute one
    // lane. Neither previously posted anything an already-open Process tab could
    // observe — the tab only reads MemoryHubActivityLog once, on .onAppear. These
    // two helpers durably log a receipt (so the read-through stays the single
    // source of truth) AND post `.memoryHubLiveProcessingDidChange` so a live tab
    // can re-read without a manual reload. The post is dispatched on the main
    // actor (SwiftUI `.onReceive` observers expect main-thread delivery; `get`/
    // `commit` are not themselves MainActor-isolated).

    /// Agent called `voice_memo_get` with `understand:true` and received a
    /// proposed plan — the "considering" event.
    static func recordConsidering(recording: VoiceMemoRecording, plan: VoiceMemoPlan, now: Date = Date()) {
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: now),
            memoId: recording.id,
            phase: .plan,
            eventType: .memoConsidering,
            action: "voice_memo_get",
            status: plan.degraded ? "degraded" : "ok",
            provenance: plan.provenance.rawValue,
            actor: "agent",
            detail: "\(plan.intents.count) intent(s) proposed"
        )
        try? MemoryHubActivityLog.append(event, now: now)
        Task { @MainActor in
            NotificationCenter.default.post(name: .memoryHubLiveProcessingDidChange, object: nil)
        }
    }

    /// Agent called `voice_memo_commit` and the write succeeded — the "committed" event.
    static func recordCommitted(
        recording: VoiceMemoRecording,
        intentId: String,
        kind: VoiceMemoIntentKind,
        detail: String,
        now: Date = Date()
    ) {
        let event = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: now),
            memoId: recording.id,
            intentId: intentId,
            phase: .execute,
            eventType: .memoCommitted,
            action: "voice_memo_commit:\(kind.rawValue)",
            status: "executed",
            provenance: "agent",
            actor: "agent",
            detail: String(detail.prefix(240))
        )
        try? MemoryHubActivityLog.append(event, now: now)
        Task { @MainActor in
            NotificationCenter.default.post(name: .memoryHubLiveProcessingDidChange, object: nil)
        }
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
        var reminders = 0, memoryKeep = 0, agent = 0, registry = 0, comments = 0, review = 0, skipped = 0
        for receipt in receipts {
            if receipt.skippedReason != nil { skipped += 1; continue }
            for outcome in receipt.outcomes {
                switch outcome.kind {
                case .reminder where outcome.status == .executed || outcome.status == .dryRun: reminders += 1
                case .memoryKeep where outcome.status == .executed || outcome.status == .dryRun: memoryKeep += 1
                case .agentMemory where outcome.status == .executed || outcome.status == .dryRun: agent += 1
                case .registryUpdate where outcome.status == .executed || outcome.status == .dryRun: registry += 1
                case .comment where outcome.status == .executed || outcome.status == .dryRun: comments += 1
                case .review: review += 1
                default: break
                }
            }
        }
        return "\(prefix) \(receipts.count) memo(s): \(reminders) reminder(s), \(memoryKeep) memory_keep, \(agent) agent_memory, \(registry) registry update(s), \(comments) comment(s), \(review) review, \(skipped) skipped."
    }

    public static func dryRunDetail(_ intent: VoiceMemoIntent) -> String {
        switch intent.kind {
        case .memoryKeep: return "would memory_keep → registry/\(intent.entityKey ?? "memory")"
        case .reminder: return "would reminders_create: \(intent.title ?? "?")"
        case .agentMemory: return "would memory_remember"
        case .registryUpdate: return "would registry_update \(intent.entityKey ?? "?") hint=\(intent.entityHint ?? "?")"
        case .comment: return "would notion_comment_create \(intent.entityKey ?? "?") hint=\(intent.entityHint ?? "?") purpose=\(intent.purpose?.rawValue ?? "?")"
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
            let transcript: String
            let plan: VoiceMemoPlan
            do {
                (transcript, plan) = try await buildPlan(for: recording, options: options, curatorMode: providerMode)
            } catch let timeoutError as VoiceMemoStageTimeoutError {
                // GH #73 parity fix (2026-07-09): voice_memo_process (processOne) and
                // voice_memo_commit both catch a transcribe/understand-stage timeout
                // inside buildPlan and degrade gracefully; this understand:true path
                // let it propagate as a raw thrown error instead — a real completion
                // payload asymmetry, though not a hang (bounded by the same stage
                // budgets). No review-queue enqueue here (unlike commit): get is a
                // read-only inspect call, not a write the caller is trying to persist.
                return .object([
                    "memo": memoValue(recording, transcript: inspectTranscript(for: recording).text ?? ""),
                    "understood": .bool(false),
                    "needsManual": .bool(true),
                    "timedOut": .bool(true),
                    "detail": .string(timeoutError.localizedDescription),
                    "curatorMode": .string(VoiceMemoCuratorRouter.effectiveMode().rawValue),
                    "processed": .bool(VoiceMemoProcessedStore.isProcessed(id: recording.id)),
                ])
            }
            recordConsidering(recording: recording, plan: plan)
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

    // MARK: - Understand-stage timeout wrappers (GH #73)
    //
    // `VoiceMemoParseRouter.parse` / `VoiceMemoSummarizer.{summarize,structuredSummary}`
    // are non-throwing — their internal Ollama call is already `try?`-guarded and
    // falls back to the heuristic floor on failure. But that fallback only fires if
    // the call RETURNS (even with an error); it does not bound how long the call can
    // take before returning. These wrappers race the same work against
    // `VoiceMemoStageTimeout` and, on timeout, substitute the identical heuristic
    // fallback the callee would have produced on an ordinary failure — so a wedged
    // local call degrades exactly like an unavailable one, never hangs the caller.

    static func understandStage(
        transcript: String,
        fallbackTitle: String,
        recordingPath: String?,
        curatorMode: VoiceMemoCuratorMode? = nil
    ) async -> VoiceMemoPlan {
        do {
            return try await VoiceMemoStageTimeout.run(
                stage: "understand",
                seconds: VoiceMemoStageTimeout.understandSeconds
            ) {
                if let curatorMode {
                    return await VoiceMemoParseRouter.parse(
                        transcript: transcript, fallbackTitle: fallbackTitle,
                        recordingPath: recordingPath, curatorMode: curatorMode
                    )
                }
                return await VoiceMemoParser.parseWithOptionalOllama(
                    transcript: transcript, fallbackTitle: fallbackTitle, recordingPath: recordingPath
                )
            }
        } catch {
            // Timed out — degrade to the same heuristic-only chain the router uses as
            // its guaranteed-non-nil floor, marked degraded so the operator can see the
            // Understand stage fell through (mirrors the router's own degraded rule).
            var plan = await VoiceMemoParseRouter.walk(
                [HeuristicParseProvider()], transcript: transcript,
                fallbackTitle: fallbackTitle, recordingPath: recordingPath
            )
            plan.degraded = true
            let preview = VoiceMemoDegradedPreviewBuilder.build(from: transcript)
            if !preview.summary.isEmpty { plan.summary = preview.summary }
            if !preview.actions.isEmpty { plan.actions = preview.actions }
            return plan
        }
    }

    static func summarizeStage(transcript: String, fallbackTitle: String) async -> String {
        let structured = await structuredSummarizeStage(transcript: transcript, fallbackTitle: fallbackTitle)
        return structured.relevantFieldText
    }

    static func structuredSummarizeStage(transcript: String, fallbackTitle: String) async -> VoiceMemoStructuredSummary {
        do {
            return try await VoiceMemoStageTimeout.run(
                stage: "summarize",
                seconds: VoiceMemoStageTimeout.understandSeconds
            ) {
                await VoiceMemoSummarizer.structuredSummary(transcript: transcript, fallbackTitle: fallbackTitle)
            }
        } catch {
            // SC5 — timed out / LLM degraded: sectioned preview, not opening fragment only.
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return VoiceMemoStructuredSummary(paragraph: fallbackTitle, actions: [])
            }
            let preview = VoiceMemoDegradedPreviewBuilder.build(from: trimmed)
            return VoiceMemoStructuredSummary(
                paragraph: preview.summary.isEmpty ? fallbackTitle : preview.summary,
                actions: preview.actions.isEmpty
                    ? VoiceMemoParser.extractActionBulletsPublic(from: trimmed)
                    : preview.actions
            )
        }
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
        // GH #73 — same transcription bound as the batch path (processOne). A timeout
        // throws VoiceMemoStageTimeoutError, which propagates like any other
        // buildPlan failure to the get()/commit() callers (never a hang).
        let resolved = try await VoiceMemoStageTimeout.run(
            stage: "transcribe",
            seconds: VoiceMemoStageTimeout.transcribeSeconds
        ) {
            try await VoiceMemoDiscovery.resolveTranscript(for: audioURL)
        }
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
        // GH #73 — bound the Understand/parse stage the same way as processOne's
        // understandStage helper. VoiceMemoParseRouter.parse is non-throwing (its
        // own chain already falls back to the heuristic floor on a nil rung), so a
        // timeout here also degrades to the heuristic parse rather than throwing —
        // consistent behavior whether the memo is routed via voice_memo_process or
        // voice_memo_get/commit.
        var plan = await understandStage(
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
            let structured = await structuredSummarizeStage(transcript: transcript, fallbackTitle: recording.title)
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
        let transcript: String
        let plan: VoiceMemoPlan
        do {
            (transcript, plan) = try await buildPlan(for: recording, options: options)
        } catch let timeoutError as VoiceMemoStageTimeoutError {
            // GH #73 — a transcription-stage timeout inside buildPlan must still land in
            // the review queue, not just fail the tool call with no durable trace (no
            // plan/intent exists yet at this point, so the entry is a generic review
            // placeholder — mirrors skipNoTranscript's shape for the batch path).
            try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                memoId: recording.id,
                memoTitle: recording.title,
                memoPath: recording.path,
                intentKind: VoiceMemoIntentKind.review.rawValue,
                confidence: 0,
                reason: timeoutError.localizedDescription,
                transcriptExcerpt: "",
                intentId: VoiceMemoIntentIdentity.intentId(
                    memoId: recording.id, kind: VoiceMemoIntentKind.review.rawValue,
                    entityKey: nil, entityHint: nil, title: recording.title, fields: [:]
                ),
                provenance: "stage-timeout"
            ))
            var receipt = commitReceipt(
                ok: false,
                memoId: recording.id,
                intentKind: kind.rawValue,
                intentState: "review_required",
                detail: timeoutError.localizedDescription,
                markedProcessed: false
            )
            if case .object(var obj) = receipt {
                obj["needsManual"] = .bool(true)
                receipt = .object(obj)
            }
            return receipt
        }
        var intent = plan.intents.first { $0.kind == kind } ?? VoiceMemoIntent(kind: kind, confidence: 1.0)
        if let entityKey = stringArg(obj, "entityKey") { intent.entityKey = entityKey }
        if let hint = stringArg(obj, "entityHint") { intent.entityHint = hint }
        if let title = stringArg(obj, "title") { intent.title = title }
        if let body = stringArg(obj, "body") { intent.body = body }
        if let due = stringArg(obj, "due") { intent.dueISO8601 = due }
        if case .object(let fieldObj)? = obj["fields"] {
            intent.fields = fieldObj.compactMapValues { if case .string(let s) = $0 { return s }; return nil }
        }
        // First-class summary override stays in the semantic summary envelope.
        // executeMemoryKeep mirrors it to a property only when that live property
        // is rich_text; select/status-backed columns such as `Relevant` are
        // filtered at the property-write boundary.
        if let summary = stringArg(obj, "summary") { intent.fields["summary"] = summary }
        if kind == .comment, let purposeRaw = stringArg(obj, "purpose") {
            intent.purpose = VoiceMemoCommentPurpose(rawValue: purposeRaw)
        }
        let explicitRowId = stringArg(obj, "rowId")

        // Execute the lane. registry_update threads an explicit rowId straight to the
        // writer (rowId wins over entityHint — PKT-MEM-106 0a). An ambiguous/unresolved
        // registry target surfaces as a manual outcome WITHOUT writing or marking processed.
        // `intent` is fully built by this point — snapshotted into a `let` before crossing
        // into the @Sendable timeout-race closure (strict concurrency forbids capturing a
        // `var`, and `intent` is referenced again below for the review-store enqueue).
        let intentSnapshot = intent
        let detail: String
        do {
            // GH #73 — bound the commit-time write/dispatch stage the same way as
            // processOne's execute() wrap. A stuck registry/Notion write during an
            // agent-driven commit() must still terminate (error or review-queue),
            // never hang the MCP call indefinitely.
            detail = try await VoiceMemoStageTimeout.run(
                stage: "commit-execute",
                seconds: VoiceMemoStageTimeout.executeSeconds
            ) {
                if kind == .registryUpdate {
                    return try await executeRegistryUpdate(intentSnapshot, explicitRowId: explicitRowId, transcript: transcript, router: router)
                } else {
                    return try await execute(intent: intentSnapshot, plan: plan, transcript: transcript, memoId: recording.id, router: router)
                }
            }
        } catch let timeoutError as VoiceMemoStageTimeoutError {
            // Same durable-trace treatment as contentQualityRejected below: never a bare
            // thrown timeout with no review-queue entry (the exact GH #73 gap).
            let intentId = VoiceMemoIntentIdentity.intentId(memoId: recording.id, intent: intent)
            try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                memoId: recording.id,
                memoTitle: plan.generatedTitle,
                memoPath: recording.path,
                intentKind: kind.rawValue,
                confidence: intent.confidence,
                reason: timeoutError.localizedDescription,
                transcriptExcerpt: String(transcript.prefix(500)),
                intentId: intentId,
                entityKey: intent.entityKey,
                entityHint: intent.entityHint,
                provenance: "stage-timeout"
            ))
            var receipt = commitReceipt(
                ok: false,
                memoId: recording.id,
                intentKind: kind.rawValue,
                intentState: "review_required",
                detail: timeoutError.localizedDescription,
                markedProcessed: false
            )
            if case .object(var obj) = receipt {
                obj["needsManual"] = .bool(true)
                receipt = .object(obj)
            }
            return receipt
        } catch let error as VoiceMemoError {
            if case .registryAmbiguous(_, _, _, let candidates) = error {
                var receipt = commitReceipt(
                    ok: false,
                    memoId: recording.id,
                    intentKind: kind.rawValue,
                    intentState: "review_required",
                    detail: error.localizedDescription,
                    markedProcessed: false
                )
                if case .object(var obj) = receipt {
                    obj["needsManual"] = .bool(true)
                    if !candidates.isEmpty {
                        obj["candidates"] = .array(candidates.map { .string($0) })
                    }
                    receipt = .object(obj)
                }
                return receipt
            }
            let reviewProvenance: String?
            switch error {
            case .contentQualityRejected: reviewProvenance = "content-quality-gate"
            case .requiredFieldsUnbound: reviewProvenance = "required-fields-unbound"
            case .memoryFallbackReview: reviewProvenance = "memory-fallback-review"
            default: reviewProvenance = nil
            }
            if let reviewProvenance {
                let intentId = VoiceMemoIntentIdentity.intentId(memoId: recording.id, intent: intent)
                try? VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                    memoId: recording.id,
                    memoTitle: plan.generatedTitle,
                    memoPath: recording.path,
                    intentKind: kind.rawValue,
                    confidence: intent.confidence,
                    reason: error.localizedDescription,
                    transcriptExcerpt: String(transcript.prefix(500)),
                    intentId: intentId,
                    entityKey: intent.entityKey,
                    entityHint: intent.entityHint,
                    provenance: reviewProvenance
                ))
                var receipt = commitReceipt(
                    ok: false,
                    memoId: recording.id,
                    intentKind: kind.rawValue,
                    intentState: "review_required",
                    detail: error.localizedDescription,
                    markedProcessed: false
                )
                if case .object(var obj) = receipt {
                    obj["needsManual"] = .bool(true)
                    receipt = .object(obj)
                }
                return receipt
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
        recordCommitted(recording: recording, intentId: committedIntentId, kind: kind, detail: detail)
        return commitReceipt(
            ok: true,
            memoId: recording.id,
            intentKind: kind.rawValue,
            intentState: "committed",
            detail: detail,
            markedProcessed: markedProcessed,
            write: parseWriteDestination(detail: detail, kind: kind, intent: intent)
        )
    }

    /// Structured commit receipt (Voice Memo Reliability packet SC #7 / proposed receipt).
    /// Additive fields — existing clients still read ok/memoId/intentKind/detail/markedProcessed.
    public static func commitReceipt(
        ok: Bool,
        memoId: String,
        intentKind: String,
        intentState: String,
        detail: String,
        markedProcessed: Bool,
        write: [String: Value]? = nil
    ) -> Value {
        let remaining = VoiceMemoReviewStore.pendingEntries()
            .filter { $0.memoId == memoId }
            .map { $0.intentKind }
        let completed = VoiceMemoReviewStore.load().entries
            .filter { $0.memoId == memoId && ($0.status == .resolved || $0.status == .dismissed) }
            .map { $0.intentKind }
        // Include the intent we just committed even if the review entry was just resolved.
        var completedSet = Set(completed)
        if ok { completedSet.insert(intentKind) }

        let memoState: String
        if markedProcessed {
            memoState = "committed"
        } else if !remaining.isEmpty {
            memoState = "partially_committed"
        } else if !ok {
            memoState = intentState == "review_required" ? "review_required" : "failed"
        } else {
            memoState = "partially_committed"
        }

        var obj: [String: Value] = [
            "ok": .bool(ok),
            "memoId": .string(memoId),
            "intentKind": .string(intentKind),
            "intentState": .string(intentState),
            "memoState": .string(memoState),
            "detail": .string(detail),
            "markedProcessed": .bool(markedProcessed),
            "completedIntents": .array(completedSet.sorted().map { .string($0) }),
            "remainingIntents": .array(remaining.sorted().map { .string($0) }),
        ]
        if let write { obj["write"] = .object(write) }
        return .object(obj)
    }

    /// Best-effort parse of lane execute() detail strings into a write receipt block.
    static func parseWriteDestination(
        detail: String,
        kind: VoiceMemoIntentKind,
        intent: VoiceMemoIntent
    ) -> [String: Value]? {
        // Common detail shapes: "memory_keep pageId=…", "registry_update contact rowId=…",
        // "reminder id=…", "memory_remember scope=… (N chars)".
        var write: [String: Value] = [
            "tool": .string(kind.rawValue),
        ]
        if let entity = intent.entityKey { write["entity"] = .string(entity) }
        if let title = intent.entityHint ?? intent.title { write["title"] = .string(title) }
        // Capture first UUID-looking token as recordId when present.
        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32}"#
        if let regex = try? NSRegularExpression(pattern: uuidPattern),
           let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
           let range = Range(match.range, in: detail) {
            write["recordId"] = .string(String(detail[range]))
        }
        if detail.contains("append") { write["mode"] = .string("append") }
        write["detail"] = .string(detail)
        return write
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
        if let purpose = intent.purpose { obj["purpose"] = .string(purpose.rawValue) }
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
    /// Ambiguous registry target. `candidates` are `"id|title"` strings (SC4).
    case registryAmbiguous(String, String?, Int, [String])
    /// SC2 — required write fields unbound before any Notion call.
    case requiredFieldsUnbound(String, [String], [String])
    /// SC8 — memory_keep failed; policy=review (explicit, not silent fallback).
    case memoryFallbackReview(String, String, String)
    /// The Memory entity has no BOUND PLAYERS relation property, so the
    /// originating Player cannot be attached — a graceful BLOCKED → REVIEW,
    /// never a silent successful processed receipt (PKT-1064).
    case playerRelationUnbound(String)
    /// The row was created but the read-back did not show the expected Player
    /// relation attached (PKT-1064 post-write verification).
    case playerRelationVerifyFailed(String, String, String)
    /// A proposed Notion-bound field value (memory_keep body/summary,
    /// registry_update text field) contains a contiguous verbatim run from
    /// the memo's raw transcript at/above
    /// `VoiceMemoTranscriptOverlapGuard.contiguousRunThreshold` — a graceful
    /// BLOCKED → REVIEW (PKT-MEM-132 D49), never a silent raw-transcript
    /// write, never a crash. Associated values: entity key, offending field
    /// key, matched run length.
    case transcriptOverlapRejected(String, String, Int)
    /// The `.comment` intent's target page could not be resolved via
    /// `registry_resolve_and_update` (missing entityHint, entity not
    /// configured, no title-role property to predicate-match against, or the
    /// underlying tool threw no-match/ambiguous) — a graceful BLOCKED → REVIEW,
    /// never a crash (PKT-MEM-136 / D48 GOAL_CONDITION).
    case commentTargetUnresolved(String, String)
    /// `notion_comment_create` did not report success after a resolved target
    /// page (PKT-MEM-136 post-write verification, mirrors PKT-1064's pattern).
    case commentPostFailed(String, String)
    /// The proposed memory_keep summary/body failed the minimum-information
    /// quality gate (GH #81) — too short or disfluency-dominated to be a
    /// substantive record. A graceful BLOCKED → REVIEW, never a silent
    /// markedProcessed:true on an effectively-empty Memory row. Associated
    /// values: entity key, the gate's stated rejection reason.
    case contentQualityRejected(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidIntent(let msg): return msg
        case .registryMatchFailed(let entity, let hint):
            return "no registry row matched entity=\(entity) hint=\(hint ?? "nil")"
        case .registryAmbiguous(let entity, let hint, let count, let candidates):
            let list = candidates.prefix(8).joined(separator: "; ")
            let suffix = list.isEmpty ? "select a rowId" : "candidates: \(list)"
            return "ambiguous registry target entity=\(entity) hint=\(hint ?? "nil") matched \(count) rows — \(suffix)"
        case .requiredFieldsUnbound(let entity, let unbound, let candidates):
            let detail = candidates.isEmpty ? unbound.joined(separator: ", ") : candidates.joined(separator: "; ")
            return "entity ‘\(entity)’ required fields unbound before write: \(detail) — rebind via registry_introspect (BLOCKED, queued for review)"
        case .memoryFallbackReview(let entity, let policy, let reason):
            return "entity=\(entity) memory_keep failed; fallback policy=\(policy) → REVIEW (\(reason))"
        case .playerRelationUnbound(let entity):
            return "entity ‘\(entity)’ has no bound PLAYERS relation property — cannot attach the originating Player; bind PLAYERS via registry_introspect, then reprocess (BLOCKED, queued for review)"
        case .playerRelationVerifyFailed(let entity, let pageId, let player):
            return "originating Player \(player) not present on created \(entity) row \(pageId) after read-back — attach verification failed (queued for review)"
        case .transcriptOverlapRejected(let entity, let field, let runLength):
            return "entity=\(entity) field ‘\(field)’ contains a \(runLength)-char verbatim run from the raw transcript — refusing to write the transcript into Notion; provide an original summary (BLOCKED, queued for review)"
        case .commentTargetUnresolved(let entity, let reason):
            return "comment target unresolved for entity ‘\(entity)’: \(reason) (BLOCKED, queued for review)"
        case .commentPostFailed(let entity, let pageId):
            return "notion_comment_create did not report success for entity ‘\(entity)’ page \(pageId) (queued for review)"
        case .contentQualityRejected(let entity, let reason):
            return "entity=\(entity) memory_keep summary failed the minimum-information quality gate: \(reason) (BLOCKED, queued for review — never marked processed)"
        }
    }
}
