// MemoryHubGuardrailTests.swift — PKT-MEM-106 Slice 0c: preview + guardrails + tabs
// TheBridge · Tests
//
// Pure-logic + file-backed asserts for the 0c cores: lane-threshold guardrails,
// duplicate block + force-reason enum, non-protected per-field diff (validate-all +
// display + protected append-only), versioned plan snapshots (retention / no-silent-
// removal / launch sweep / diff badges), provider config (providers.json / defaults /
// syntax validation), progressive-preview policy (timeouts / cloud-failure semantics),
// notification suppression gate, and activity corruption handling. Hermetic temp home.

import Foundation
import MCP
import TheBridgeLib

private func withGuardrailTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("MemoryHub0c-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? fm.removeItem(at: tmp) }
    return try await body()
}

private func snapIntent(_ id: String, conf: Double = 0.9, fields: [String: String] = [:], demoted: Bool = false) -> PlanSnapshotIntent {
    PlanSnapshotIntent(intentId: id, kind: "registry_update", confidence: conf, entityKey: "project",
                       entityHint: "P", title: "T", fields: fields, demoted: demoted)
}

private func snapshot(_ memoId: String, _ prov: PlanSnapshot.Provenance, _ version: Int, _ intents: [PlanSnapshotIntent], at: String = "2026-06-25T09:00:00Z") -> PlanSnapshot {
    PlanSnapshot(memoId: memoId, provenance: prov, version: version, createdAt: at, intents: intents)
}

func runMemoryHubGuardrailTests() async {
    print("\n🛡️ Memory Hub 0c — preview + guardrails + tabs (PKT-MEM-106)")

    // MARK: Lane thresholds

    await test("gate_globalFloor_080_blocksBelow") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .registryUpdate, confidence: 0.79).isAuto, "below 0.80 ⇒ manual")
    }
    await test("gate_reminder_090_threshold") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .reminder, confidence: 0.89).isAuto, "reminder@0.89 ⇒ manual")
        try expect(MemoryHubCommitGuardrails.autoDecision(kind: .reminder, confidence: 0.90).isAuto, "reminder@0.90 ⇒ auto")
    }
    await test("gate_registry_086_threshold") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .registryUpdate, confidence: 0.85).isAuto, "registry@0.85 ⇒ manual")
        try expect(MemoryHubCommitGuardrails.autoDecision(kind: .registryUpdate, confidence: 0.86).isAuto, "registry@0.86 ⇒ auto")
    }
    await test("gate_agent_086_threshold") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .agentMemory, confidence: 0.85).isAuto, "agent@0.85 ⇒ manual")
        try expect(MemoryHubCommitGuardrails.autoDecision(kind: .agentMemory, confidence: 0.86).isAuto, "agent@0.86 ⇒ auto")
    }
    await test("gate_memoryKeep_090_threshold") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .memoryKeep, confidence: 0.89).isAuto, "memory_keep@0.89 ⇒ manual")
        try expect(MemoryHubCommitGuardrails.autoDecision(kind: .memoryKeep, confidence: 0.90).isAuto, "memory_keep@0.90 ⇒ auto")
    }
    await test("gate_ambiguousRegistryTarget_forcesManual") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .registryUpdate, confidence: 0.99, targetAmbiguous: true).isAuto, "ambiguous ⇒ manual even at high confidence")
    }
    await test("gate_staleCacheFallbackTarget_forcesManual") {
        try expect(!MemoryHubCommitGuardrails.autoDecision(kind: .registryUpdate, confidence: 0.99, staleFallback: true).isAuto, "stale fallback ⇒ manual")
    }

    // MARK: Duplicate block + force reason

    await test("dup_blockByDefault_sameDestinationKey") {
        let a = MemoryHubCommitGuardrails.duplicateKey(memoId: "m", intentId: "i1", destinationKey: "reminder|9am")
        let b = MemoryHubCommitGuardrails.duplicateKey(memoId: "m", intentId: "i1", destinationKey: "reminder|9am")
        try expect(a == b, "identical memo+intent+destination ⇒ same dup key (blocked by default)")
    }
    await test("dup_distinctDestinationKey_notBlocked") {
        let a = MemoryHubCommitGuardrails.duplicateKey(memoId: "m", intentId: "i1", destinationKey: "session.summary")
        let b = MemoryHubCommitGuardrails.duplicateKey(memoId: "m", intentId: "i2", destinationKey: "project.summary")
        try expect(a != b, "distinct lanes ⇒ distinct dup keys (both allowed)")
    }
    await test("dup_forceReasonEnum_required") {
        if case .rejected = MemoryHubCommitGuardrails.validateForce(reasonRaw: nil) {} else { try expect(false, "no reason ⇒ rejected") }
        if case .rejected = MemoryHubCommitGuardrails.validateForce(reasonRaw: "") {} else { try expect(false, "empty reason ⇒ rejected") }
        try expect(Set(DuplicateForceReason.allCases.map(\.rawValue)) == ["new_context", "correction", "operator_confirmed", "live_test"], "exact force-reason enum")
    }
    await test("dup_forceReason_invalidValueRejected") {
        if case .rejected = MemoryHubCommitGuardrails.validateForce(reasonRaw: "because") {} else { try expect(false, "out-of-enum reason ⇒ rejected") }
    }
    await test("dup_batchDistinctIntents_distinctKeys") {
        // V1 batch: two checked intents in same batch keep distinct dup keys (guardrail per commit).
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: VoiceMemoPlan(
            generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
                VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "A"),
                VoiceMemoIntent(kind: .agentMemory, confidence: 0.88, title: "B"),
            ]))
        let ordered = MemoryProcessBatchConfirm.commitOrder(checkedIds: Set(rows.map(\.intentId)), rows: rows)
        try expect(ordered.count == 2, "batch orders both lanes")
        let keys = ordered.map {
            MemoryHubCommitGuardrails.duplicateKey(
                memoId: "m", intentId: $0.intentId,
                destinationKey: $0.destinationField)
        }
        try expect(keys[0] != keys[1], "distinct lanes ⇒ distinct dup keys in batch")
    }

    // MARK: Non-protected per-field diff

    await test("nonProtected_perFieldDiff_computesBeforeAfter") {
        let diffs = MemoryHubRegistryDiff.diff(current: ["status": "old", "owner": "A"], proposed: ["status": "new", "owner": "A"])
        try expect(diffs.count == 1 && diffs.first?.field == "status", "only changed fields, before/after captured")
        try expect(diffs.first?.oldValue == "old" && diffs.first?.newValue == "new", "old/new")
    }
    await test("nonProtected_diffSelectsOnlyChosenFields") {
        let diffs = MemoryHubRegistryDiff.diff(current: [:], proposed: ["a": "1", "b": "2", "c": "3"])
        let chosen = Array(diffs.prefix(2))
        if case .write(let w) = MemoryHubRegistryDiff.apply(selected: chosen) {
            try expect(w.count == 2 && w["c"] == nil, "only chosen fields written")
        } else { try expect(false, "valid selection ⇒ write") }
    }
    await test("nonProtected_diffDisplay_summaryAndRawJson") {
        let diffs = MemoryHubRegistryDiff.diff(current: ["status": "old"], proposed: ["status": "new"])
        try expect(MemoryHubRegistryDiff.summary(diffs).first?.contains("status: \"old\" → \"new\"") == true, "human-readable summary")
        let raw = MemoryHubRegistryDiff.rawJSON(diffs)
        try expect(raw.contains("before") && raw.contains("after") && raw.contains("old") && raw.contains("new"), "expandable raw before/after JSON")
    }
    await test("nonProtected_diffValidationFailure_writesNothingKeepsReview") {
        // "b" goes from a real value to empty → a genuine (invalid) diff that reaches the validator.
        let diffs = MemoryHubRegistryDiff.diff(current: ["a": "0", "b": "x"], proposed: ["a": "1", "b": ""])
        try expect(diffs.count == 2, "both fields are real changes")
        // default validator rejects empty values → ALL-or-nothing: nothing written.
        if case .rejected = MemoryHubRegistryDiff.apply(selected: diffs) {
            try expect(true, "any field fails ⇒ nothing written, intent stays uncommitted")
        } else { try expect(false, "validation failure must reject the whole write") }
    }
    await test("appendOnly_protectedNeverOverwritable_inDiff") {
        let diffs = MemoryHubRegistryDiff.diff(current: ["brief": "old"], proposed: ["brief": "new"])
        try expect(diffs.first?.isProtected == true, "protected field flagged")
        try expect(MemoryHubRegistryDiff.selectableNonProtected(diffs).isEmpty, "protected excluded from selectable overwrite set")
        if case .rejected = MemoryHubRegistryDiff.apply(selected: diffs) {} else { try expect(false, "protected in overwrite set ⇒ rejected") }
    }

    // MARK: Plan snapshots

    await test("snapshot_storage_perMemoJsonPath") {
        try expect(MemoryHubPlanSnapshotStore.fileURL(memoId: "memo-1").path.contains("memory-hub/plan-snapshots/memo-1.json"), "per-memo JSON path")
    }
    await test("snapshot_retention_keepsHeuristicLatestEnhancedCommitted") {
        let snaps = [
            snapshot("m", .heuristic, 1, [snapIntent("i1")]),
            snapshot("m", .local, 2, [snapIntent("i1")]),
            snapshot("m", .local, 3, [snapIntent("i1")]),   // intermediate enhanced — pruned
            snapshot("m", .cloud, 4, [snapIntent("i1")]),   // latest enhanced
            snapshot("m", .committed, 5, [snapIntent("i1")]),
        ]
        let kept = MemoryHubPlanSnapshotStore.prune(snaps)
        try expect(kept.contains { $0.provenance == .heuristic }, "heuristic kept")
        try expect(kept.contains { $0.provenance == .committed }, "committed kept")
        try expect(kept.contains { $0.provenance == .cloud && $0.version == 4 }, "latest-enhanced kept")
        try expect(!kept.contains { $0.provenance == .local && $0.version == 3 }, "intermediate enhanced pruned")
        try expect(kept.count == 3, "exactly heuristic + latest-enhanced + committed")
    }
    await test("snapshot_prunesOnWriteAndLaunchSweep") {
        try await withGuardrailTempHome {
            _ = try MemoryHubPlanSnapshotStore.append(snapshot("m", .heuristic, 1, [snapIntent("i1")]))
            _ = try MemoryHubPlanSnapshotStore.append(snapshot("m", .local, 2, [snapIntent("i1")]))
            _ = try MemoryHubPlanSnapshotStore.append(snapshot("m", .local, 3, [snapIntent("i1")]))
            // prune-on-write already keeps {heuristic, latest-enhanced}
            try expect(MemoryHubPlanSnapshotStore.load(memoId: "m").count == 2, "pruned on write")
            MemoryHubPlanSnapshotStore.launchSweep()
            try expect(MemoryHubPlanSnapshotStore.load(memoId: "m").allSatisfy { $0.provenance != .local || $0.version == 3 }, "launch sweep keeps latest-enhanced only")
        }
    }
    await test("snapshot_noSilentRemoval_demoteOrSupersedeOnly") {
        let heuristic = [snapIntent("i1"), snapIntent("i2")]
        let enhanced = [snapIntent("i1", conf: 0.95)]   // i2 "dropped" by enhancement
        let merged = MemoryHubPlanSnapshotStore.mergePreservingDemoted(heuristic: heuristic, enhanced: enhanced)
        try expect(merged.contains { $0.intentId == "i2" && $0.demoted }, "dropped heuristic intent survives as demoted, never silently removed")
        try expect(merged.contains { $0.intentId == "i1" && !$0.demoted }, "enhanced intent present")
    }
    await test("snapshot_versioned_addedChangedDemotedBadges") {
        let from = snapshot("m", .heuristic, 1, [snapIntent("i1", conf: 0.8), snapIntent("i2")])
        let to = snapshot("m", .local, 2, [snapIntent("i1", conf: 0.95), snapIntent("i3"), snapIntent("i2", demoted: true)])
        let badges = MemoryHubPlanSnapshotStore.diffBadges(from: from, to: to)
        try expect(badges["i1"] == "changed", "confidence change ⇒ changed")
        try expect(badges["i3"] == "added", "new intent ⇒ added")
        try expect(badges["i2"] == "demoted", "demoted intent ⇒ demoted")
    }
    await test("preview_enhancementChangesLane_returnsToUncommitted") {
        try expect(MemoryHubPreview.enhancementReturnsLaneToUncommitted(approvedIntentIds: ["i1"], changedIntentId: "i1"), "changed approved lane ⇒ uncommitted")
        try expect(!MemoryHubPreview.enhancementReturnsLaneToUncommitted(approvedIntentIds: ["i1"], changedIntentId: "i2"), "unrelated change ⇒ no effect")
    }

    // MARK: Progressive preview policy

    await test("preview_heuristicFirst_localAuto_cloudManual") {
        try expect(PreviewProvenance.allCases.first == .heuristic, "heuristic is first")
        try expect(MemoryHubPreview.mayAutoEnhanceLocal(localEnabled: true), "local may auto when enabled")
        try expect(!MemoryHubPreview.mayAutoEnhanceLocal(localEnabled: false), "no local auto when disabled")
        try expect(!MemoryHubPreview.mayCloudEnhance(operatorTriggered: false), "cloud NEVER auto")
        try expect(MemoryHubPreview.mayCloudEnhance(operatorTriggered: true), "cloud only on explicit trigger")
    }
    await test("preview_timeouts_local8s_cloud20s") {
        try expect(MemoryHubPreview.localTimeoutSeconds == 8, "local 8s soft timeout")
        try expect(MemoryHubPreview.cloudTimeoutSeconds == 20, "cloud 20s timeout")
    }
    await test("preview_cloudFailure_keepsLatestValid_noReviewQueued") {
        let r = MemoryHubPreview.onTimeoutOrFailure(latestValid: .local, isCloudFailure: true)
        try expect(r.kept == .local, "keeps latest valid heuristic/local plan")
        try expect(r.queuesReview == false, "cloud failure does NOT queue a review item")
        try expect(r.activityStatus == "cloud_failure", "failure status recorded in activity")
    }

    // MARK: Provider config

    await test("processing_providerDefaults_baseUrlOnly_modelRequired") {
        let p = MemoryHubProviderConfigStore.defaultProvider()
        try expect(p.baseURL == "https://api.openai.com/v1", "base URL default")
        try expect(p.model.isEmpty, "model blank until operator-entered")
        try expect(!MemoryHubProviderConfigStore.canRunCloud(p), "cannot run cloud without a model")
        var withModel = p; withModel.model = "gpt-4o"; withModel.enabled = true
        try expect(MemoryHubProviderConfigStore.canRunCloud(withModel), "model + enabled ⇒ can run cloud")
    }
    await test("processing_providerValidation_syntaxOnSave") {
        try expect(MemoryHubProviderConfigStore.validateSyntax(MemoryHubProvider(id: "x", baseURL: "https://api.openai.com/v1", model: "", enabled: false)).isOK, "valid https URL ⇒ ok (model blank ok on save)")
        if case .rejected = MemoryHubProviderConfigStore.validateSyntax(MemoryHubProvider(id: "x", baseURL: "not a url", model: "m", enabled: true)) {} else { try expect(false, "malformed URL ⇒ rejected") }
        if case .rejected = MemoryHubProviderConfigStore.validateSyntax(MemoryHubProvider(id: "x", baseURL: "", model: "m", enabled: true)) {} else { try expect(false, "empty URL ⇒ rejected") }
    }
    await test("processing_providerConfig_nonSecretProvidersJson_noKeyInJson") {
        try await withGuardrailTempHome {
            _ = try MemoryHubProviderConfigStore.upsert(MemoryHubProvider(id: "openai-compatible", baseURL: "https://api.openai.com/v1", model: "gpt-4o", enabled: true))
            try expect(MemoryHubProviderConfigStore.fileURL.path.contains("memory-hub/providers.json"), "providers.json path")
            let raw = try String(contentsOf: MemoryHubProviderConfigStore.fileURL, encoding: .utf8)
            try expect(raw.contains("baseURL") && raw.contains("gpt-4o") && raw.contains("enabled"), "non-secret config persisted")
            try expect(!raw.lowercased().contains("apikey") && !raw.lowercased().contains("api_key") && !raw.lowercased().contains("secret"), "API key NEVER in providers.json")
            let loaded = MemoryHubProviderConfigStore.load()
            try expect(loaded.first?.model == "gpt-4o", "round-trips")
        }
    }

    // MARK: Notification suppression gate

    await test("notify_gate_truthTable_activeAndProcessOnly") {
        try expect(MemoryHubNotificationGate.shouldSuppress(appActive: true, processSelected: true), "active + Process ⇒ suppress")
        try expect(!MemoryHubNotificationGate.shouldSuppress(appActive: true, processSelected: false), "active + other surface ⇒ deliver")
        try expect(!MemoryHubNotificationGate.shouldSuppress(appActive: false, processSelected: true), "inactive ⇒ deliver")
        try expect(!MemoryHubNotificationGate.shouldSuppress(appActive: false, processSelected: false), "inactive + other ⇒ deliver")
    }

    // MARK: Activity corruption handling

    await test("activity_corruptJsonl_skipsPreservesRepairs") {
        try await withGuardrailTempHome {
            // one good event, then a corrupt line, then another good event
            let good1 = MemoryHubActivityEvent(timestamp: "2026-06-25T09:00:00Z", memoId: "m", phase: .execute, action: "a1", status: "executed", provenance: "election", actor: "curator", detail: "ok")
            try MemoryHubActivityLog.append(good1)
            // inject a corrupt line directly
            let handle = try FileHandle(forWritingTo: MemoryHubActivityLog.fileURL)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{not valid json\n".utf8)); try handle.close()
            let good2 = MemoryHubActivityEvent(timestamp: "2026-06-25T09:01:00Z", memoId: "m", phase: .execute, action: "a2", status: "executed", provenance: "election", actor: "curator", detail: "ok")
            let before = try Data(contentsOf: MemoryHubActivityLog.fileURL)
            try MemoryHubActivityLog.append(good2)
            let result = MemoryHubActivityLog.loadWithRepair()
            try expect(result.events.count == 2, "good events loaded, corrupt skipped, got \(result.events.count)")
            try expect(result.skipped == 1 && result.firstErrorOffset != nil, "skipped count + first error offset")
            // corrupt line preserved (append didn't auto-rewrite it away)
            let after = try Data(contentsOf: MemoryHubActivityLog.fileURL)
            try expect(after.count > before.count, "original corrupt line preserved (file only grew)")
            // repair scan appends a repair activity without removing the corrupt line
            let skipped = MemoryHubActivityLog.repairScan()
            try expect(skipped == 1, "repair scan reports the corrupt line")
            try expect(MemoryHubActivityLog.load().contains { $0.action == "activity_repair" }, "repair activity recorded")
        }
    }
}
