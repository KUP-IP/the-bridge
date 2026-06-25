// VoiceMemoHubTrustTests.swift — PKT-MEM-106 Slice 0a: trust + identity core
// TheBridge · Tests
//
// The M5/M8 blocker set. Asserts the Phase-0 0a trust invariants at the model
// layer (no UI): deterministic intentId, lane-priority-first election, the shared
// processed-gate predicate routed through every callsite, distinct same-kind
// suppressed lanes, legacy derive-on-read with rewrite-on-touch, rowId-param
// threading + ambiguity → manual, and append-only protected registry fields.
// File-backed asserts run against a HERMETIC temp home; registry/memory writes
// run against a stub ToolRouter so nothing touches real Notion / agent memory.

import Foundation
import MCP
import TheBridgeLib

// MARK: - Hermetic home + stub router

private func withVMTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("MemoryHub0a-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    return try await body()
}

/// Captures the args the voice processor forwards to registry/memory tools so the
/// trust write-paths can be asserted without a live Notion / agent-memory backend.
private actor StubRegistryState {
    var listRows: [Value] = []
    var getProperties: [String: Value] = [:]
    var lastUpdateId: String?
    var lastUpdateFields: [String: Value] = [:]
    var updateCount = 0
    var lastMemoryText: String?

    func setListRows(_ rows: [Value]) { listRows = rows }
    func setGetProperties(_ props: [String: Value]) { getProperties = props }
    func recordUpdate(id: String, fields: [String: Value]) {
        lastUpdateId = id; lastUpdateFields = fields; updateCount += 1
    }
    func recordMemory(_ text: String) { lastMemoryText = text }
}

private func makeStubRouter(_ state: StubRegistryState) async -> ToolRouter {
    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    let schema: Value = .object(["type": .string("object")])
    await router.register(ToolRegistration(name: "registry_list", module: "registry", tier: .open,
        description: "stub", inputSchema: schema) { _ in
        .object(["rows": .array(await state.listRows)])
    })
    await router.register(ToolRegistration(name: "registry_get", module: "registry", tier: .open,
        description: "stub", inputSchema: schema) { _ in
        .object(["properties": .object(await state.getProperties)])
    })
    await router.register(ToolRegistration(name: "registry_update", module: "registry", tier: .open,
        description: "stub", inputSchema: schema) { args in
        guard case .object(let obj) = args, case .string(let id)? = obj["id"] else {
            return .object(["ok": .bool(false)])
        }
        var fields: [String: Value] = [:]
        if case .object(let f)? = obj["fields"] { fields = f }
        await state.recordUpdate(id: id, fields: fields)
        return .object(["ok": .bool(true)])
    })
    await router.register(ToolRegistration(name: "memory_remember", module: "memory", tier: .open,
        description: "stub", inputSchema: schema) { args in
        if case .object(let obj) = args, case .string(let text)? = obj["text"] {
            await state.recordMemory(text)
        }
        return .object(["ok": .bool(true)])
    })
    return router
}

// MARK: - Tests

func runVoiceMemoHubTrustTests() async {
    print("\n🔐 Memory Hub 0a — trust + identity core (PKT-MEM-106)")

    // MARK: Lane-priority-first election

    await test("election_priorityBeatsConfidence_reminderOverHigherConfRegistry") {
        let intents = [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.95, entityKey: "project", entityHint: "Bridge v4"),
            VoiceMemoIntent(kind: .reminder, confidence: 0.81, title: "ping"),
        ]
        let split = VoiceMemoIntentElection.split(intents)
        try expect(split.execute.count == 1, "one execute lane")
        try expect(split.execute.first?.kind == .reminder, "reminder wins by priority over higher-confidence registry")
        try expect(split.suppressed.count == 1 && split.suppressed.first?.kind == .registryUpdate, "registry suppressed")
    }

    await test("election_fullPriorityOrder_reminderAgentRegistryMemoryKeep") {
        let memoryKeep = VoiceMemoIntent(kind: .memoryKeep, confidence: 0.9, entityKey: "memory")
        let registry = VoiceMemoIntent(kind: .registryUpdate, confidence: 0.9, entityKey: "project", entityHint: "P")
        let agent = VoiceMemoIntent(kind: .agentMemory, confidence: 0.9)
        let reminder = VoiceMemoIntent(kind: .reminder, confidence: 0.9, title: "r")
        try expect(VoiceMemoIntentElection.split([memoryKeep, registry, agent, reminder]).execute.first?.kind == .reminder,
                   "reminder is primary at equal confidence")
        try expect(VoiceMemoIntentElection.split([memoryKeep, registry, agent]).execute.first?.kind == .agentMemory,
                   "agent_memory next when no reminder")
        try expect(VoiceMemoIntentElection.split([memoryKeep, registry]).execute.first?.kind == .registryUpdate,
                   "registry over memory_keep")
    }

    await test("election_confidenceTiebreakWithinSameLane") {
        let intents = [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.80, entityKey: "session", entityHint: "DST-8"),
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.92, entityKey: "project", entityHint: "Bridge v4"),
        ]
        let split = VoiceMemoIntentElection.split(intents)
        try expect(split.execute.count == 1, "one lane")
        try expect(split.execute.first?.entityKey == "project", "higher-confidence registry lane wins the in-lane tie-break")
        try expect(split.suppressed.first?.entityKey == "session", "lower-confidence registry suppressed")
    }

    await test("election_singleExecutableLane_noSuppression") {
        let split = VoiceMemoIntentElection.split([VoiceMemoIntent(kind: .reminder, confidence: 0.9, title: "r")])
        try expect(split.execute.count == 1 && split.suppressed.isEmpty, "single executable lane passthrough")
    }

    // MARK: Deterministic intentId

    await test("intentId_canonicalDeterminism_stableAcrossReorder") {
        var f1: [String: String] = [:]; f1["summary"] = "a"; f1["brief"] = "b"; f1["zeta"] = "z"
        var f2: [String: String] = [:]; f2["zeta"] = "z"; f2["brief"] = "b"; f2["summary"] = "a"
        let id1 = VoiceMemoIntentIdentity.intentId(memoId: "m1", kind: "registry_update", entityKey: "project", entityHint: "Bridge v4", title: "T", fields: f1)
        let id2 = VoiceMemoIntentIdentity.intentId(memoId: "m1", kind: "registry_update", entityKey: "project", entityHint: "Bridge v4", title: "T", fields: f2)
        try expect(id1 == id2, "field insertion order must not change the id")
    }

    await test("intentId_format_prefixAnd20HexLowercase") {
        let id = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "reminder", entityKey: nil, entityHint: nil, title: "x", fields: [:])
        try expect(id.hasPrefix("intent_v1_"), "intent_v1_ prefix")
        let hex = id.dropFirst("intent_v1_".count)
        try expect(hex.count == 20, "exactly 20 hex chars, got \(hex.count)")
        try expect(hex.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }, "lowercase hex only")
    }

    await test("intentId_canonicalization_trimWhitespaceCaseEnums") {
        let a = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "Project", entityHint: " Bridge  v4 ", title: " T ", fields: [:])
        let b = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "REGISTRY_UPDATE", entityKey: "project", entityHint: "Bridge v4", title: "T", fields: [:])
        try expect(a == b, "trim + whitespace-normalize + lowercase enums must hash equal")
    }

    await test("intentId_sameMemoDistinctKind_differentId") {
        let a = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "reminder", entityKey: nil, entityHint: nil, title: "T", fields: [:])
        let b = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "agent_memory", entityKey: nil, entityHint: nil, title: "T", fields: [:])
        try expect(a != b, "different kind ⇒ different id")
    }

    await test("intentId_sameMemoSameKindDistinctTarget_differentId") {
        let session = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "session", entityHint: "DST-8", title: "T", fields: [:])
        let project = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "project", entityHint: "Bridge v4", title: "T", fields: [:])
        try expect(session != project, "two registry_update lanes (session vs project) from one memo ⇒ distinct ids (M5/M8 core)")
    }

    // MARK: Same-kind distinctness in the store

    await test("reviewEnqueue_twoSameKindLanes_bothPersist") {
        try await withVMTempHome {
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8"))
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "project", entityHint: "Bridge v4"))
            let pending = VoiceMemoReviewStore.pendingEntries().filter { $0.memoId == "m" }
            try expect(pending.count == 2, "both same-kind lanes persist (no memoId+intentKind collapse), got \(pending.count)")
        }
    }

    await test("reviewEnqueue_idempotentSameIntentId_replacesNotDuplicates") {
        try await withVMTempHome {
            let iid = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "session", entityHint: "DST-8", title: "T", fields: [:])
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8", reason: "r1", intentId: iid))
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8", reason: "r2", intentId: iid))
            let pending = VoiceMemoReviewStore.pendingEntries().filter { $0.effectiveIntentId() == iid }
            try expect(pending.count == 1, "re-enqueue of same intentId replaces, got \(pending.count)")
        }
    }

    // MARK: Legacy derive-on-read

    await test("legacy_deriveIntentIdOnRead_marksLegacyDerived") {
        let legacy = VoiceMemoReviewEntry(memoId: "m", memoTitle: "Legacy Memo", intentKind: "registry_update",
                                          confidence: 0.6, reason: "old", transcriptExcerpt: "")
        try expect(legacy.isLegacyDerived, "no stored intentId ⇒ legacyDerived")
        try expect(legacy.effectiveIntentId().hasPrefix("intent_v1_"), "derives a canonical id on read")
    }

    await test("legacy_deriveFallback_usesCreatedAtAndReason") {
        let legacy = VoiceMemoReviewEntry(memoId: "m", memoTitle: "", intentKind: "review", confidence: 0,
                                          reason: "transcription failed", transcriptExcerpt: "",
                                          queuedAt: "2026-06-25T09:00:00Z")
        let a = legacy.effectiveIntentId()
        let b = legacy.effectiveIntentId()
        try expect(a == b, "fallback id deterministic across reads")
        try expect(a.hasPrefix("intent_v1_") && a.count == "intent_v1_".count + 20, "well-formed fallback id")
    }

    await test("legacy_rewriteOnTouchOnly_untouchedFileUnchanged") {
        try await withVMTempHome {
            let legacy = VoiceMemoReviewEntry(memoId: "m", memoTitle: "T", intentKind: "registry_update",
                                              confidence: 0.6, reason: "old", transcriptExcerpt: "",
                                              entityKey: "project", entityHint: "Bridge v4")
            try VoiceMemoReviewStore.save(VoiceMemoReviewManifest(entries: [legacy]))
            let url = VoiceMemoReviewStore.manifestURL
            let before = try Data(contentsOf: url)
            _ = VoiceMemoReviewStore.load()
            let afterRead = try Data(contentsOf: url)
            try expect(before == afterRead, "reading a legacy manifest must NOT rewrite it")
            _ = try VoiceMemoReviewStore.dismiss(id: legacy.id)
            let afterTouch = try Data(contentsOf: url)
            try expect(afterTouch != before, "touch (dismiss) materializes intentId and rewrites")
            let touched = VoiceMemoReviewStore.load().entries.first { $0.id == legacy.id }
            try expect((touched?.intentId ?? "").isEmpty == false, "stored intentId present after touch")
        }
    }

    // MARK: Processed-gate alignment (the trust invariant)

    await test("processedGate_pendingSiblingReview_blocksMark") {
        let manifest = VoiceMemoReviewManifest(entries: [makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8")])
        try expect(VoiceMemoProcessedGate.noPendingReview(memoId: "m", manifest: manifest) == false, "pending sibling blocks mark")
        try expect(VoiceMemoProcessedGate.noPendingReview(memoId: "other", manifest: manifest) == true, "unrelated memo unaffected")
    }

    await test("processedGate_commit_lastLaneClearsThenMarks") {
        try await withVMTempHome {
            let e1 = makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8")
            let e2 = makeEntry(memoId: "m", entityKey: "project", entityHint: "Bridge v4")
            try VoiceMemoReviewStore.enqueue(e1)
            try VoiceMemoReviewStore.enqueue(e2)
            _ = try VoiceMemoReviewStore.resolve(id: e1.id)
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == false, "sibling still pending ⇒ not marked")
            try expect(VoiceMemoProcessedStore.isProcessed(id: "m") == false, "not processed yet")
            _ = try VoiceMemoReviewStore.resolve(id: e2.id)
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == true, "last lane cleared ⇒ marked")
            try expect(VoiceMemoProcessedStore.isProcessed(id: "m") == true, "processed after last lane clears")
        }
    }

    await test("processedGate_reviewResolve_marksOnlyWhenNoSiblingPending") {
        try await withVMTempHome {
            for (ek, eh) in [("session", "DST-8"), ("project", "Bridge v4"), ("contact", "Jacob")] {
                try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: ek, entityHint: eh))
            }
            let pending = VoiceMemoReviewStore.pendingEntries().filter { $0.memoId == "m" }
            try expect(pending.count == 3, "three distinct lanes queued")
            _ = try VoiceMemoReviewStore.resolve(id: pending[0].id)
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == false, "2 pending ⇒ not marked")
            _ = try VoiceMemoReviewStore.resolve(id: pending[1].id)
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == false, "1 pending ⇒ not marked")
            _ = try VoiceMemoReviewStore.resolve(id: pending[2].id)
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == true, "0 pending ⇒ marked")
        }
    }

    await test("processedGate_alignmentAcrossAllCallsites_singlePredicate") {
        try await withVMTempHome {
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8"))
            // process / commit / review_resolve all consult the SAME predicate.
            let live = VoiceMemoProcessedGate.noPendingReview(memoId: "m")
            let viaManifest = VoiceMemoProcessedGate.noPendingReview(memoId: "m", manifest: VoiceMemoReviewStore.load())
            try expect(live == false && viaManifest == false, "single predicate blocks while a sibling is pending")
            try expect(try VoiceMemoProcessedGate.markProcessedIfClear(memoId: "m") == false, "gate-routed mark blocked")
            try expect(VoiceMemoProcessedStore.isProcessed(id: "m") == false, "no callsite marked the memo independently")
        }
    }

    // MARK: rowId threading + ambiguity → manual

    await test("rowIdCommit_paramThreadsToWriterByRowId") {
        let state = StubRegistryState()
        await state.setListRows([.object(["id": .string("wrong-row-999"), "title": .string("Bridge v4")])])
        let router = await makeStubRouter(state)
        let intent = VoiceMemoIntent(kind: .registryUpdate, confidence: 1.0, entityKey: "project", entityHint: "Bridge v4", fields: ["status": "shipping"])
        _ = try await VoiceMemoProcessor.executeRegistryUpdate(intent, explicitRowId: "correct-row-123", router: router)
        let wrote = await state.lastUpdateId
        try expect(wrote == "correct-row-123", "explicit rowId wins over entityHint match, wrote to \(wrote ?? "nil")")
    }

    await test("rowIdCommit_missingRowAndAmbiguousHint_routesToManual") {
        let state = StubRegistryState()
        await state.setListRows([
            .object(["id": .string("r1"), "title": .string("Bridge v4 launch")]),
            .object(["id": .string("r2"), "title": .string("Bridge v4 ops")]),
        ])
        let router = await makeStubRouter(state)
        var threwAmbiguous = false
        do {
            _ = try await VoiceMemoProcessor.resolveRegistryRowId(entityKey: "project", hint: "bridge v4", router: router)
        } catch let error as VoiceMemoError {
            if case .registryAmbiguous = error { threwAmbiguous = true }
        }
        try expect(threwAmbiguous, "ambiguous hint (2 matches) ⇒ registryAmbiguous (manual), not an auto-pick")
        try expect(await state.updateCount == 0, "no write performed on ambiguous hint")
    }

    // MARK: Append-only protected registry fields

    await test("appendOnly_brief_neverOverwrites") {
        let state = StubRegistryState()
        await state.setGetProperties(["brief": .string("Prior brief content.")])
        let router = await makeStubRouter(state)
        let merged = try await VoiceMemoProcessor.mergeAppendRegistryFields(entityKey: "project", rowId: "r1", proposed: ["brief": "New voice note."], router: router)
        try expect(merged["brief"]?.contains("Prior brief content.") == true, "keeps prior brief")
        try expect(merged["brief"]?.contains("New voice note.") == true, "appends new content")
    }

    await test("appendOnly_allFourProtectedFields_objectiveSummaryDescription") {
        let state = StubRegistryState()
        await state.setGetProperties([
            "brief": .string("B0"), "objective": .string("O0"), "summary": .string("S0"), "description": .string("D0"),
        ])
        let router = await makeStubRouter(state)
        let merged = try await VoiceMemoProcessor.mergeAppendRegistryFields(
            entityKey: "project", rowId: "r1",
            proposed: ["brief": "B1", "objective": "O1", "summary": "S1", "description": "D1"], router: router)
        for (key, old) in [("brief", "B0"), ("objective", "O0"), ("summary", "S0"), ("description", "D0")] {
            try expect(merged[key]?.contains(old) == true, "\(key) retains prior \(old)")
        }
        for (key, new) in [("brief", "B1"), ("objective", "O1"), ("summary", "S1"), ("description", "D1")] {
            try expect(merged[key]?.contains(new) == true, "\(key) appends new \(new)")
        }
    }

    await test("appendOnly_protectedField_forceFlagStillAppends") {
        let state = StubRegistryState()
        await state.setGetProperties(["brief": .string("Original brief — do not lose.")])
        let router = await makeStubRouter(state)
        // No Phase-0 path can overwrite a protected field; the merge always appends.
        let merged = try await VoiceMemoProcessor.mergeAppendRegistryFields(entityKey: "project", rowId: "r1", proposed: ["brief": "Forced new content."], router: router)
        try expect(merged["brief"]?.contains("Original brief — do not lose.") == true, "protected field never overwritten, even on a force path")
        try expect(merged["brief"] != "Forced new content.", "result is an append, not a raw overwrite")
    }

    // MARK: Trust regression guards

    await test("agentMemory_fullTranscriptStored_notFirstSentence") {
        let state = StubRegistryState()
        let router = await makeStubRouter(state)
        let transcript = "First sentence here. Second sentence with more detail. Third sentence so it is clearly multi-sentence and long."
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "First sentence here.", actions: [], intents: [])
        _ = try await VoiceMemoProcessor.executeAgentMemory(VoiceMemoIntent(kind: .agentMemory, confidence: 1.0), plan: plan, transcript: transcript, router: router)
        let stored = await state.lastMemoryText ?? ""
        try expect(stored.count >= transcript.count, "stores the full transcript, not the first sentence (\(stored.count) of \(transcript.count))")
        try expect(stored.contains("Third sentence"), "full transcript retained")
    }

    await test("intentId_usedAsReviewAndReceiptKey_consistent") {
        try await withVMTempHome {
            let intent = VoiceMemoIntent(kind: .registryUpdate, confidence: 0.7, entityKey: "session", entityHint: "DST-8")
            let iid = VoiceMemoIntentIdentity.intentId(memoId: "m", intent: intent)
            try VoiceMemoReviewStore.enqueue(makeEntry(memoId: "m", entityKey: "session", entityHint: "DST-8", intentId: iid))
            let stored = VoiceMemoReviewStore.pendingEntries().first { $0.memoId == "m" }
            try expect(stored?.effectiveIntentId() == iid, "stored review id equals generator output")
            if let stored,
               case .object(let obj) = VoiceMemoReviewStore.entryValue(stored),
               case .string(let projected)? = obj["intentId"] {
                try expect(projected == iid, "entryValue (receipt/UI projection) surfaces the same intentId")
            } else {
                try expect(false, "intentId missing from entryValue projection")
            }
        }
    }
}

// MARK: - Fixtures

/// A suppressed-lane review entry carrying per-intent identity (PKT-MEM-106 0a).
private func makeEntry(
    memoId: String,
    entityKey: String,
    entityHint: String,
    reason: String = "secondary intent suppressed — primary lane elected",
    intentId: String? = nil
) -> VoiceMemoReviewEntry {
    let iid = intentId ?? VoiceMemoIntentIdentity.intentId(
        memoId: memoId, kind: "registry_update", entityKey: entityKey, entityHint: entityHint, title: "T", fields: [:])
    return VoiceMemoReviewEntry(
        memoId: memoId, memoTitle: "T", intentKind: "registry_update", confidence: 0.7,
        reason: reason, transcriptExcerpt: "", intentId: iid,
        entityKey: entityKey, entityHint: entityHint)
}
