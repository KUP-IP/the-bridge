// MemoryHubCockpitTests.swift — PKT-MEM-106 Slice 0b: activity log + registry cache (+ cockpit AX)
// TheBridge · Tests
//
// Activity-log receipt envelope (privacy + retention) and the Process registry picker's
// per-entity cache. File-backed asserts run against a HERMETIC temp home so nothing
// touches the real ~/Library. Cockpit zone/AX/mirror asserts are appended once the
// split cockpit lands.

import Foundation
import MCP
import TheBridgeLib

private func withHubTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("MemoryHub0b-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    return try await body()
}

private func makeEvent(
    memoId: String = "m",
    intentId: String? = "intent_v1_0123456789abcdef0123",
    phase: MemoryHubActivityEvent.Phase = .execute,
    action: String = "registry_update",
    status: String = "executed",
    detail: String = "ok",
    timestamp: String = "2026-06-25T09:00:00Z"
) -> MemoryHubActivityEvent {
    MemoryHubActivityEvent(
        timestamp: timestamp, memoId: memoId, intentId: intentId, phase: phase,
        action: action, status: status, provenance: "election", actor: "curator", detail: detail
    )
}

func runMemoryHubCockpitTests() async {
    print("\n🗂️ Memory Hub 0b — activity log + registry cache (PKT-MEM-106)")

    // MARK: Activity receipt envelope

    await test("activity_envelope_requiredFields") {
        let event = makeEvent()
        try expect(!event.eventId.isEmpty, "eventId present")
        try expect(event.schemaVersion == MemoryHubActivityLog.schemaVersion, "schemaVersion stamped")
        try expect(event.memoId == "m" && event.intentId != nil, "memoId + intentId")
        try expect(event.phase == .execute && !event.action.isEmpty && !event.status.isEmpty, "phase/action/status")
        try expect(!event.provenance.isEmpty && !event.actor.isEmpty, "provenance + actor")
        try expect(event.receiptHash.count == 64, "full SHA-256 receiptHash, got \(event.receiptHash.count)")
    }

    await test("activity_phaseEnum_constrained") {
        try expect(MemoryHubActivityEvent.Phase.allCases.count == 6, "six phases")
        let valid = Set(MemoryHubActivityEvent.Phase.allCases.map(\.rawValue))
        try expect(valid == ["transcribe", "understand", "plan", "execute", "review", "test"], "exact phase domain")
        // an out-of-domain phase string fails to decode
        let bad = #"{"phase":"deploy"}"#.data(using: .utf8)!
        try expect((try? JSONDecoder().decode(MemoryHubActivityEvent.Phase.self, from: bad)) == nil, "invalid phase rejected")
    }

    await test("activity_noFullTranscript_hashPlusExcerptOnly") {
        let transcript = String(repeating: "The quick brown fox jumped over the lazy dog. ", count: 30)
        let detail = MemoryHubActivityLog.transcriptEvidence(transcript)
        try expect(detail.count < transcript.count, "detail is far shorter than the transcript")
        try expect(!detail.contains(transcript), "full transcript NEVER embedded")
        try expect(detail.contains("sha256="), "carries a transcript hash")
        try expect(detail.contains("excerpt="), "carries a short excerpt")
    }

    await test("activity_shortTranscript_excerptOmitted_neverVerbatim") {
        // A short memo would BE its own excerpt — so it's stored hash-only (0b/0c review privacy fix).
        let secret = "Account 4471 PIN 9920 — call mom about the settlement"
        let detail = MemoryHubActivityLog.transcriptEvidence(secret)
        try expect(!detail.contains(secret), "complete short transcript NEVER stored verbatim")
        try expect(detail.contains("excerpt omitted"), "short memo ⇒ excerpt omitted")
        try expect(detail.contains("sha256="), "still carries the transcript hash")
    }

    await test("activity_receiptHash_fullStored_first12Displayed") {
        let event = makeEvent()
        try expect(event.receiptHash.count == 64, "stored hash is full 64-char SHA-256")
        try expect(event.receiptHashShort.count == 12, "display projection is 12 chars")
        try expect(event.receiptHash.hasPrefix(event.receiptHashShort), "short is the prefix of full")
    }

    await test("activity_receiptHash_deterministicOverCanonicalFields") {
        let a = makeEvent(detail: "same")
        let b = makeEvent(detail: "same")
        try expect(a.receiptHash == b.receiptHash, "identical content fields ⇒ identical hash (eventId excluded)")
        let c = makeEvent(detail: "different")
        try expect(a.receiptHash != c.receiptHash, "one field change ⇒ different hash")
    }

    await test("activity_jsonl_appendOnly_oneLinePerEvent") {
        try await withHubTempHome {
            for i in 0..<3 {
                try MemoryHubActivityLog.append(makeEvent(action: "a\(i)"))
            }
            let raw = try String(contentsOf: MemoryHubActivityLog.fileURL, encoding: .utf8)
            let lines = raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            try expect(lines.count == 3, "3 events ⇒ 3 JSONL lines, got \(lines.count)")
            let loaded = MemoryHubActivityLog.load()
            try expect(loaded.map(\.action) == ["a0", "a1", "a2"], "appended in order, not rewritten")
        }
    }

    await test("activity_retention_eventCap") {
        // D24: cap at maxEvents (2000). Test with maxEvents+1 events.
        let now = ISO8601DateFormatter().date(from: "2026-06-25T12:00:00Z")!
        let events = (0..<(MemoryHubActivityLog.maxEvents + 1)).map { i in
            makeEvent(action: "a\(i)", timestamp: "2026-06-25T11:00:00Z")
        }
        let pruned = MemoryHubActivityLog.prune(events, now: now)
        try expect(pruned.count == MemoryHubActivityLog.maxEvents, "\(MemoryHubActivityLog.maxEvents + 1) recent ⇒ pruned to \(MemoryHubActivityLog.maxEvents), got \(pruned.count)")
        try expect(pruned.first?.action == "a1", "oldest dropped (kept the newest \(MemoryHubActivityLog.maxEvents))")
    }

    await test("activity_retention_90dayCap_whicheverSmaller") {
        // D24: 2000 events OR 90 days — whichever removes more.
        let now = ISO8601DateFormatter().date(from: "2026-06-25T12:00:00Z")!
        // 2026-03-01 is ~116 days before 2026-06-25 → older than 90 days → pruned
        let old = makeEvent(action: "old", timestamp: "2026-03-01T12:00:00Z")
        let fresh = makeEvent(action: "fresh", timestamp: "2026-06-25T11:00:00Z")
        let pruned = MemoryHubActivityLog.prune([old, fresh], now: now)
        try expect(pruned.map(\.action) == ["fresh"], "events older than 90 days dropped even under 2000-count")
    }

    await test("activity_file_path_underMemoryHub") {
        let path = MemoryHubActivityLog.fileURL.path
        try expect(path.contains("memory-hub/activity.jsonl"), "activity log lives under memory-hub/, got \(path)")
    }

    // MARK: Registry picker cache

    await test("picker_cacheFile_perEntityPathAndTTLMeta") {
        try await withHubTempHome {
            let entry = try MemoryHubRegistryCache.write(entity: "session", rows: [
                MemoryHubRegistryRow(id: "r1", title: "DST-8"),
                MemoryHubRegistryRow(id: "r2", title: "DST-9"),
            ])
            try expect(MemoryHubRegistryCache.cacheURL(entity: "session").path.contains("memory-hub/registry-cache/session.json"), "per-entity path")
            try expect(entry.ttlSeconds == MemoryHubRegistryCache.staleAfterSeconds, "ttl metadata persisted")
            let read = MemoryHubRegistryCache.read(entity: "session")
            try expect(read?.rows.count == 2 && read?.rows.first?.title == "DST-8", "rows round-trip")
            try expect(read?.fetchedAt.isEmpty == false, "fetchedAt persisted")
        }
    }

    await test("picker_cacheStaleAfter24h_setsStaleBadge") {
        try await withHubTempHome {
            let base = ISO8601DateFormatter().date(from: "2026-06-25T00:00:00Z")!
            _ = try MemoryHubRegistryCache.write(entity: "project", rows: [MemoryHubRegistryRow(id: "r1", title: "Bridge v4")], fetchedAt: base)
            // exactly 24h later ⇒ NOT stale (boundary); just past ⇒ stale
            try expect(MemoryHubRegistryCache.isStale(entity: "project", now: base.addingTimeInterval(24 * 3600)) == false, "exactly 24h ⇒ not stale")
            try expect(MemoryHubRegistryCache.isStale(entity: "project", now: base.addingTimeInterval(24 * 3600 + 1)) == true, "past 24h ⇒ stale")
            try expect(MemoryHubRegistryCache.isStale(entity: "project", now: base.addingTimeInterval(3600)) == false, "1h ⇒ not stale")
        }
    }

    await test("picker_liveFailure_fallsBackToCache") {
        try await withHubTempHome {
            // last-good rows persisted with a recorded source error → still selectable as fallback.
            _ = try MemoryHubRegistryCache.write(entity: "contact", rows: [MemoryHubRegistryRow(id: "c1", title: "Jacob")],
                                                 sourceError: "registry_list timeout")
            let state = MemoryHubRegistryCache.state(entity: "contact")
            try expect(state.cached, "cache present for offline fallback")
            try expect(state.sourceError == "registry_list timeout", "source error recorded")
            try expect(MemoryHubRegistryCache.read(entity: "contact")?.rows.first?.id == "c1", "last-good row selectable")
        }
    }

    // MARK: Three-zone cockpit + primary override + per-intent commit

    await test("cockpit_threeZones_present") {
        // The three cockpit zones + activity strip are addressable, well-formed AX surfaces.
        let p = "bridge.settings.memory.process."
        try expect(BridgeAXID.Memory.Process.memoList == p + "memoList", "memo list zone")
        try expect(BridgeAXID.Memory.Process.intentTable == p + "intentTable", "intent table zone")
        try expect(BridgeAXID.Memory.Process.detailInspector == p + "detailInspector", "detail inspector zone")
        try expect(BridgeAXID.Memory.Process.activityStrip == p + "activityStrip", "activity strip zone")
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: makeCockpitPlan())
        try expect(rows.count == 4, "intent table populated from the plan, got \(rows.count)")
    }

    await test("cockpit_intentTable_showsPrimaryMarkerAndColumns") {
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: makeCockpitPlan())
        try expect(rows.filter { $0.isPrimary }.count == 1, "exactly one primary-marked row")
        try expect(rows.first { $0.isPrimary }?.kind == .reminder, "reminder elected primary (lane-priority-first)")
        let session = rows.first { $0.entityHint == "DST-8" }
        try expect(session?.kind == .registryUpdate && session?.confidence == 0.88, "columns: kind + confidence")
        try expect(session?.destinationField == "session.summary", "destination field column")
        try expect(session?.status == "suppressed", "non-primary executable ⇒ suppressed")
    }

    await test("cockpit_primaryOverride_reElectsChosenLane") {
        let plan = makeCockpitPlan()
        let sessionId = VoiceMemoIntentIdentity.intentId(
            memoId: "m", kind: "registry_update", entityKey: "session", entityHint: "DST-8", title: nil, fields: ["summary": "ship"])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan, overrideIntentId: sessionId)
        try expect(rows.first { $0.intentId == sessionId }?.isPrimary == true, "overridden lane becomes primary")
        try expect(rows.first { $0.kind == .reminder }?.isPrimary == false, "previously-elected reminder demoted")
        try expect(rows.filter { $0.isPrimary }.count == 1, "still exactly one primary")
    }

    await test("cockpit_perIntentCommit_callsCommitWithIntentId") {
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: makeCockpitPlan())
        let session = rows.first { $0.entityHint == "DST-8" }!
        let args = MemoryProcessCockpit.commitArguments(memoId: "m", row: session)
        try expect(args["memoId"] == .string("m"), "scoped to memo")
        try expect(args["intentKind"] == .string("registry_update"), "scoped to this intent's kind")
        try expect(args["entityKey"] == .string("session") && args["entityHint"] == .string("DST-8"), "carries target")
    }

    await test("cockpit_duplicateLanes_collapseToOnePrimary") {
        // Two byte-identical executable lanes (same intentId — e.g. a duplicated parser lane)
        // must NEVER produce two rows or two primaries (sacred one-primary invariant). 0b review fix.
        let dup = VoiceMemoIntent(kind: .agentMemory, confidence: 0.9)
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [dup, dup])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        try expect(rows.count == 1, "byte-identical lanes collapse to one row, got \(rows.count)")
        try expect(rows.filter { $0.isPrimary }.count == 1, "exactly one primary even with duplicate intentIds")
    }

    await test("cockpit_commitArguments_threadsDue") {
        let row = MemoryProcessCockpit.intentRows(memoId: "m", plan: VoiceMemoPlan(
            generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [],
            intents: [VoiceMemoIntent(kind: .reminder, confidence: 0.9, title: "ping", dueISO8601: "2026-06-26T16:00:00Z")]
        )).first!
        let args = MemoryProcessCockpit.commitArguments(memoId: "m", row: row)
        try expect(args["due"] == .string("2026-06-26T16:00:00Z"), "row due threads into commit args")
    }

    // MARK: AX identifiers (exact)

    await test("axId_rowAndCommandHelpers_exactFormat") {
        let p = "bridge.settings.memory.process."
        try expect(BridgeAXID.Memory.Process.memoRow("memo-1") == p + "memoRow.memo-1", "memo row keyed by memoId")
        try expect(BridgeAXID.Memory.Process.intentRow("intent_v1_abc") == p + "intentRow.intent_v1_abc", "intent row keyed by intentId")
        try expect(BridgeAXID.Memory.Process.registryRow(entity: "session", rowId: "r1") == p + "registryRow.session.r1", "registry row")
        try expect(BridgeAXID.Memory.Process.commit("intent_v1_abc") == p + "commit.intent_v1_abc", "commit command")
        try expect(BridgeAXID.Memory.Process.primaryOverride("intent_v1_abc") == p + "primaryOverride.intent_v1_abc", "override command")
    }

    await test("axHarness_memoryProcess_registeredEntries") {
        let memory = SettingsUIValidationHarness.expectedIdentifiers[.memory] ?? []
        for zone in [BridgeAXID.Memory.Process.memoList, BridgeAXID.Memory.Process.intentTable,
                     BridgeAXID.Memory.Process.detailInspector, BridgeAXID.Memory.Process.activityStrip] {
            try expect(memory.contains(zone), "manifest must register cockpit zone \(zone)")
        }
    }

    // MARK: Registry picker (live + cached)

    await test("picker_liveRegistryList_populatesRows") {
        try await withHubTempHome {
            let live = [MemoryHubRegistryRow(id: "r1", title: "DST-8"), MemoryHubRegistryRow(id: "r2", title: "DST-9")]
            let state = MemoryProcessCockpit.picker(entity: "session", liveRows: live)
            try expect(state.rows.count == 2 && !state.stale, "live rows populate, not stale")
            // last-good persisted for offline fallback
            try expect(MemoryHubRegistryCache.read(entity: "session")?.rows.count == 2, "live rows cached as last-good")
        }
    }

    await test("picker_liveFailure_picker_fallsBackToStaleCache") {
        try await withHubTempHome {
            let base = ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z")!
            _ = try MemoryHubRegistryCache.write(entity: "project", rows: [MemoryHubRegistryRow(id: "r1", title: "Bridge v4")], fetchedAt: base)
            // live nil (failure) → cached fallback; 48h later ⇒ stale flagged
            let state = MemoryProcessCockpit.picker(entity: "project", liveRows: nil, now: base.addingTimeInterval(48 * 3600))
            try expect(state.rows.first?.id == "r1", "falls back to cached last-good")
            try expect(state.stale, "stale flagged past 24h")
            try expect(state.sourceError != nil, "source error recorded")
        }
    }

    await test("rowIdCommit_pickerSelectionFlowsIntoCommit") {
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: makeCockpitPlan())
        let project = rows.first { $0.entityHint == "Bridge v4" }!
        let args = MemoryProcessCockpit.commitArguments(memoId: "m", row: project, selectedRowId: "picked-row-123")
        try expect(args["rowId"] == .string("picked-row-123"), "picker-selected rowId threads into commit args")
    }

    // MARK: Process↔Inbox mirror (same underlying entries)

    await test("mirror_pendingLane_visibleInProcessAndInbox") {
        try await withHubTempHome {
            let iid = VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "session", entityHint: "DST-8", title: "T", fields: [:])
            try VoiceMemoReviewStore.enqueue(VoiceMemoReviewEntry(
                memoId: "m", memoTitle: "T", intentKind: "registry_update", confidence: 0.7,
                reason: "secondary intent suppressed", transcriptExcerpt: "", intentId: iid, entityKey: "session", entityHint: "DST-8"))
            let inbox = VoiceMemoReviewStore.pendingEntries()
            let process = MemoryProcessCockpit.processGroup(memoId: "m", pending: inbox)
            try expect(inbox.contains { $0.effectiveIntentId() == iid }, "lane visible in Inbox")
            try expect(process.contains { $0.effectiveIntentId() == iid }, "same lane grouped in Process")
        }
    }

    await test("mirror_resolvedLane_dropsFromBothViews") {
        try await withHubTempHome {
            let entry = VoiceMemoReviewEntry(
                memoId: "m", memoTitle: "T", intentKind: "registry_update", confidence: 0.7,
                reason: "secondary intent suppressed", transcriptExcerpt: "",
                intentId: VoiceMemoIntentIdentity.intentId(memoId: "m", kind: "registry_update", entityKey: "session", entityHint: "DST-8", title: "T", fields: [:]),
                entityKey: "session", entityHint: "DST-8")
            try VoiceMemoReviewStore.enqueue(entry)
            _ = try VoiceMemoReviewStore.resolve(id: entry.id)
            let inbox = VoiceMemoReviewStore.pendingEntries()
            try expect(inbox.isEmpty, "resolving clears it from Inbox")
            try expect(MemoryProcessCockpit.processGroup(memoId: "m", pending: inbox).isEmpty, "and from the Process mirror simultaneously")
        }
    }
}

// MARK: - Cockpit fixtures

private func makeCockpitPlan() -> VoiceMemoPlan {
    VoiceMemoPlan(generatedTitle: "Standup", skipMemoryKeep: false, summary: "morning standup", actions: [], intents: [
        VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "4pm test results"),
        VoiceMemoIntent(kind: .registryUpdate, confidence: 0.88, entityKey: "session", entityHint: "DST-8", fields: ["summary": "ship"]),
        VoiceMemoIntent(kind: .registryUpdate, confidence: 0.86, entityKey: "project", entityHint: "Bridge v4", fields: ["summary": "trust"]),
        VoiceMemoIntent(kind: .agentMemory, confidence: 0.80),
    ])
}
