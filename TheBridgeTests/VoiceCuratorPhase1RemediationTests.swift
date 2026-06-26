// VoiceCuratorPhase1RemediationTests.swift — Voice Curator FRONTIER-FIRST Phase-1 review remediation (W4)
// TheBridge · Tests
//
// Regression coverage for the adversarial-review remediation:
//  • [privacy/#1] A cloud Understand send writes ONE durable `.understand` activity
//    receipt (action `cloud_parse`, provenance `cloud`) carrying hash+excerpt ONLY —
//    never the full transcript. Local/heuristic arms write NOTHING. The process
//    `receiptValue` surfaces provenance/degraded so the autonomous path is auditable.
//  • [privacy/#1] The notifier classifies a `.cloud` receipt into a cloud-send lane so
//    the silent scheduled-curator path tells the operator content left the device.
//  • [design/#4] `commitWriteLabel` is honest about partial previews: first-of-N fields
//    and append-only (merge) registry fields — the value preview is unchanged.
//
// All pure / hermetic — no network, no Ollama, no audio. The activity log + provider
// config live in a hermetic temp home (`BridgePaths.overrideHomeForTesting`).

import Foundation
import MCP
import TheBridgeLib

// MARK: - Hermetic home

private func withRemediationTempHome<T>(_ body: () async throws -> T) async rethrows -> T {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("VoiceCuratorRemediation-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer { BridgePaths.overrideHomeForTesting(nil); try? fm.removeItem(at: tmp) }
    return try await body()
}

private func planWith(provenance: ParseProvenance, degraded: Bool = false) -> VoiceMemoPlan {
    VoiceMemoPlan(
        generatedTitle: "Title",
        skipMemoryKeep: false,
        summary: "summary",
        actions: [],
        intents: [VoiceMemoIntent(kind: .agentMemory, confidence: 0.9, title: "Title")],
        provenance: provenance,
        degraded: degraded
    )
}

private func recording(id: String = "memo-1") -> VoiceMemoRecording {
    VoiceMemoRecording(id: id, path: "/tmp/\(id).m4a", title: "Title", recordedAt: Date(), transcript: nil)
}

private func remediationRow(kind: VoiceMemoIntentKind, fields: [String: String], title: String? = nil) -> CockpitIntentRow {
    // Build the row the real way (the public election path) so it is shaped exactly as the view renders it.
    let intent = VoiceMemoIntent(kind: kind, confidence: 0.9, entityKey: kind == .registryUpdate ? "project" : nil,
                                 entityHint: kind == .registryUpdate ? "Bridge" : nil, title: title, fields: fields)
    let plan = VoiceMemoPlan(generatedTitle: "t", skipMemoryKeep: false, summary: "", actions: [], intents: [intent])
    return MemoryProcessCockpit.intentRows(memoId: "m1", plan: plan).first!
}

func runVoiceCuratorPhase1RemediationTests() async {
    print("\n🔒 Voice Curator FRONTIER-FIRST W4 — Phase-1 review remediation")

    // MARK: #1 — durable cloud-send Understand receipt (privacy provenance)

    await test("cloudSend_writesUnderstandReceipt_withHashNotFullTranscript") {
        try await withRemediationTempHome {
            let transcript = String(repeating: "secret words ", count: 50) // > 120 chars ⇒ excerpt path
            VoiceMemoProcessor.recordUnderstandCloudSend(
                recording: recording(),
                plan: planWith(provenance: .cloud),
                transcript: transcript
            )
            let events = MemoryHubActivityLog.recent(limit: 10)
            guard let event = events.first(where: { $0.phase == .understand }) else {
                try expect(false, "expected a .understand receipt"); return
            }
            try expect(event.action == "cloud_parse", "action must be cloud_parse, got \(event.action)")
            try expect(event.provenance == "cloud", "provenance must be cloud")
            try expect(event.actor == "curator", "actor must be curator (autonomous path)")
            try expect(event.status == "ok", "non-degraded cloud send ⇒ status ok")
            // PRIVACY INVARIANT: the full transcript must NEVER appear in the receipt detail.
            try expect(!event.detail.contains(transcript), "detail must NOT contain the full transcript")
            try expect(event.detail.contains("sha256="), "detail must carry the transcript hash evidence")
        }
    }

    await test("cloudSend_degraded_marksStatusDegraded") {
        try await withRemediationTempHome {
            VoiceMemoProcessor.recordUnderstandCloudSend(
                recording: recording(),
                plan: planWith(provenance: .cloud, degraded: true),
                transcript: "a short cloud-parsed memo"
            )
            let event = MemoryHubActivityLog.recent(limit: 5).first { $0.phase == .understand }
            try expect(event?.status == "degraded", "degraded cloud win ⇒ status degraded")
        }
    }

    await test("cloudSend_noReceiptForLocalOrHeuristic") {
        try await withRemediationTempHome {
            for arm in [ParseProvenance.local, .heuristic, .agent] {
                VoiceMemoProcessor.recordUnderstandCloudSend(
                    recording: recording(),
                    plan: planWith(provenance: arm),
                    transcript: "on-device only, never leaves the machine"
                )
            }
            let understand = MemoryHubActivityLog.recent(limit: 20).filter { $0.phase == .understand }
            try expect(understand.isEmpty, "local/heuristic/agent arms must write NO cloud receipt, got \(understand.count)")
        }
    }

    await test("cloudSend_isIdempotentByContentHash_perMemo") {
        try await withRemediationTempHome {
            // Calling twice for the same memo+transcript must not double-count as two
            // distinct sends in the receipt CONTENT hash (the receiptHash excludes the
            // random eventId + timestamp, so identical content ⇒ identical receiptHash).
            let r = recording()
            let plan = planWith(provenance: .cloud)
            VoiceMemoProcessor.recordUnderstandCloudSend(recording: r, plan: plan, transcript: "same memo twice")
            VoiceMemoProcessor.recordUnderstandCloudSend(recording: r, plan: plan, transcript: "same memo twice")
            let hashes = Set(MemoryHubActivityLog.recent(limit: 10).filter { $0.phase == .understand }.map(\.receiptHash))
            try expect(hashes.count == 1, "identical cloud sends share one content hash, got \(hashes.count)")
        }
    }

    // MARK: #1 — receiptValue surfaces provenance/degraded

    await test("receiptValue_surfacesProvenanceAndDegraded_whenSet") {
        let receipt = VoiceMemoReceipt(memoId: "m", title: "t", outcomes: [], provenance: .cloud, degraded: true)
        guard case .object(let obj) = VoiceMemoProcessor.receiptValue(receipt) else {
            try expect(false, "receiptValue must be an object"); return
        }
        try expect(obj["provenance"] == .string("cloud"), "envelope must carry provenance=cloud")
        try expect(obj["degraded"] == .bool(true), "envelope must carry degraded=true")
    }

    await test("receiptValue_omitsProvenance_forPreParseSkips") {
        // A no-transcript / already-processed skip is produced BEFORE the parse ⇒ nil
        // provenance ⇒ no provenance key (older consumers + skip receipts stay clean).
        let receipt = VoiceMemoReceipt(memoId: "m", title: "t", skippedReason: "no transcript")
        guard case .object(let obj) = VoiceMemoProcessor.receiptValue(receipt) else {
            try expect(false, "receiptValue must be an object"); return
        }
        try expect(obj["provenance"] == nil, "pre-parse skip must NOT carry a provenance key")
    }

    // MARK: #1 — notifier cloud-send lane (autonomous path is surfaced)

    await test("notifier_classifiesCloudSendLane") {
        let receipts = [
            VoiceMemoReceipt(memoId: "a", title: "t", provenance: .cloud),
            VoiceMemoReceipt(memoId: "b", title: "t", provenance: .local),
            VoiceMemoReceipt(memoId: "c", title: "t", provenance: .cloud),
            VoiceMemoReceipt(memoId: "d", title: "t", provenance: nil),
        ]
        let counts = VoiceMemoNotifier.classify(receipts: receipts)
        try expect(counts.cloudSends == 2, "two .cloud receipts ⇒ cloudSends == 2, got \(counts.cloudSends)")
        try expect(counts.needsNotification, "a cloud send alone must trigger a notification")
    }

    await test("notifier_noCloudLane_whenAllLocal") {
        let counts = VoiceMemoNotifier.classify(receipts: [
            VoiceMemoReceipt(memoId: "a", title: "t", provenance: .local),
            VoiceMemoReceipt(memoId: "b", title: "t", provenance: .heuristic),
        ])
        try expect(counts.cloudSends == 0, "no cloud send ⇒ cloudSends == 0")
    }

    // MARK: #4 — honest commit-write label (first-of-N + append-merge)

    await test("commitWriteLabel_singleField_plainWrite") {
        let row = remediationRow(kind: .registryUpdate, fields: ["status": "Shipped"])
        try expect(MemoryProcessCockpit.commitWriteLabel(for: row) == "Will write",
                   "single non-append field ⇒ plain 'Will write'")
    }

    await test("commitWriteLabel_multiField_saysFirstOfN") {
        let row = remediationRow(kind: .registryUpdate, fields: ["status": "Shipped", "owner": "Isaiah"])
        let label = MemoryProcessCockpit.commitWriteLabel(for: row)
        try expect(label?.contains("first of 2 fields") == true,
                   "multi-field update must state it previews 1 of N, got \(String(describing: label))")
    }

    await test("commitWriteLabel_appendField_saysAppend") {
        // The first sorted key here is an append-only field (brief) ⇒ the writer MERGES
        // existing + this delta, so the label must say so, not 'Will write'.
        let row = remediationRow(kind: .registryUpdate, fields: ["brief": "new note"])
        let label = MemoryProcessCockpit.commitWriteLabel(for: row)
        try expect(label?.contains("append") == true, "append-only field ⇒ label says append, got \(String(describing: label))")
        try expect(label?.lowercased().contains("existing") == true, "append label must say it adds to existing")
    }

    await test("commitWriteLabel_reminderIsPlainWrite") {
        let row = remediationRow(kind: .reminder, fields: [:], title: "Call the bank")
        try expect(MemoryProcessCockpit.commitWriteLabel(for: row) == "Will write",
                   "non-registry lane ⇒ plain 'Will write'")
    }

    await test("commitWriteLabel_nilWhenNoPreviewValue") {
        // No fields + no title ⇒ no preview value ⇒ no label (the view shows neither).
        let row = remediationRow(kind: .registryUpdate, fields: [:])
        try expect(MemoryProcessCockpit.commitWriteLabel(for: row) == nil,
                   "no concrete value ⇒ nil label")
    }
}
