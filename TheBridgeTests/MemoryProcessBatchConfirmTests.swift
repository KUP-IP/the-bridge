// MemoryProcessBatchConfirmTests.swift — PKT-MEM-123 batch commit orchestrator
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

private func batchPlan() -> VoiceMemoPlan {
    VoiceMemoPlan(generatedTitle: "Standup", skipMemoryKeep: false, summary: "morning", actions: [], intents: [
        VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "4pm results"),
        VoiceMemoIntent(kind: .agentMemory, confidence: 0.88, title: "full transcript"),
        VoiceMemoIntent(kind: .registryUpdate, confidence: 0.86, entityKey: "session", entityHint: "DST-8", fields: ["summary": "ship"]),
        VoiceMemoIntent(kind: .memoryKeep, confidence: 0.90, title: "Notion memory"),
        VoiceMemoIntent(kind: .review, confidence: 0.50, title: "unclear"),
    ])
}

private func batchRows(memoId: String = "m", override: String? = nil) -> [CockpitIntentRow] {
    MemoryProcessCockpit.intentRows(memoId: memoId, plan: batchPlan(), overrideIntentId: override)
}

func runMemoryProcessBatchConfirmTests() async {
    print("\n✅ Memory Process batch confirm (PKT-MEM-123)")

    await test("batch_defaultChecked_primaryOnly") {
        let rows = batchRows()
        let checked = MemoryProcessBatchConfirm.defaultCheckedIntentIds(rows: rows)
        let primary = rows.first { $0.isPrimary }!
        try expect(checked == [primary.intentId], "defaults to primary only")
    }

    await test("batch_isTagCheckable_reviewDisabled") {
        let review = batchRows().first { $0.kind == .review }!
        try expect(!MemoryProcessBatchConfirm.isTagCheckable(review), "review not checkable")
        let reminder = batchRows().first { $0.kind == .reminder }!
        try expect(MemoryProcessBatchConfirm.isTagCheckable(reminder), "reminder checkable")
    }

    await test("batch_commitOrder_lanePriority") {
        let rows = batchRows()
        let allIds = Set(rows.filter { MemoryProcessBatchConfirm.isTagCheckable($0) }.map(\.intentId))
        let ordered = MemoryProcessBatchConfirm.commitOrder(checkedIds: allIds, rows: rows)
        try expect(ordered.first?.kind == .reminder, "reminder first")
        try expect(ordered.last?.kind == .memoryKeep, "memory_keep last among executable")
        try expect(!ordered.contains { $0.kind == .review }, "review excluded from order")
    }

    await test("batch_commitOrder_stableTieBreakByIntentId") {
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.90, entityKey: "a", entityHint: "A", fields: ["x": "1"]),
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.90, entityKey: "b", entityHint: "B", fields: ["x": "2"]),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        let ids = Set(rows.map(\.intentId))
        let o1 = MemoryProcessBatchConfirm.commitOrder(checkedIds: ids, rows: rows)
        let o2 = MemoryProcessBatchConfirm.commitOrder(checkedIds: ids, rows: rows)
        try expect(o1.map(\.intentId) == o2.map(\.intentId), "stable order")
    }

    await test("batch_missingRegistry_emptyHintNeedsRow") {
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.90, entityKey: "session", entityHint: "", fields: ["summary": "x"]),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        let id = rows.first!.intentId
        let missing = MemoryProcessBatchConfirm.missingRegistryConfiguration(
            checkedIds: [id], rows: rows, selectedRowIdByIntentId: [:])
        try expect(missing.count == 1, "empty hint needs row pick")
    }

    await test("batch_missingRegistry_satisfiedWhenRowPicked") {
        let rows = batchRows()
        let reg = rows.first { $0.kind == .registryUpdate }!
        let missing = MemoryProcessBatchConfirm.missingRegistryConfiguration(
            checkedIds: [reg.intentId], rows: rows, selectedRowIdByIntentId: [reg.intentId: "row-1"])
        try expect(missing.isEmpty, "picked row clears missing")
    }

    await test("batch_needsPicker_forPerIntent") {
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.90, entityKey: "session", entityHint: "DST-8", fields: ["summary": "a"]),
            VoiceMemoIntent(kind: .registryUpdate, confidence: 0.88, entityKey: "project", entityHint: "Bridge", fields: ["summary": "b"]),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        let reg = rows.first { $0.kind == .registryUpdate }!
        try expect(MemoryProcessCockpit.needsPicker(for: reg, allRows: rows), "multi registry ⇒ per-intent picker")
    }

    await test("batch_needsPicker_reminderNeverNeedsPicker") {
        let rows = batchRows()
        let reminder = rows.first { $0.kind == .reminder }!
        try expect(!MemoryProcessCockpit.needsPicker(for: reminder, allRows: rows), "reminder never needs picker")
    }

    await test("batch_canConfirm_requiresNonEmptySelection") {
        try expect(!MemoryProcessBatchConfirm.canConfirm(checkedIds: [], rows: batchRows()), "empty selection rejected")
    }

    await test("batch_canConfirm_requiresPreviewValue") {
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "", fields: [:]),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        let id = rows.first!.intentId
        try expect(!MemoryProcessBatchConfirm.canConfirm(checkedIds: [id], rows: rows), "empty title ⇒ no preview ⇒ disabled")
    }

    await test("batch_confirmSummaryLines_truncatesLongPreview") {
        let long = String(repeating: "word ", count: 40)
        let plan = VoiceMemoPlan(generatedTitle: "T", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: long),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: "m", plan: plan)
        let lines = MemoryProcessBatchConfirm.confirmSummaryLines(checkedIds: [rows.first!.intentId], rows: rows)
        try expect(lines.count == 1, "one summary line")
        try expect(lines[0].preview.hasSuffix("…"), "truncated preview")
        try expect(lines[0].preview.count <= 120, "preview capped")
    }

    await test("batch_parseCommitResponse_needsManualNotSuccess") {
        let env: [String: Value] = ["ok": .bool(true), "needsManual": .bool(true), "detail": .string("pick row")]
        let parsed = MemoryProcessBatchConfirm.parseCommitResponse(env)
        try expect(!parsed.ok, "needsManual ⇒ not ok")
        try expect(parsed.needsManual, "needsManual flagged")
    }

    await test("batch_parseCommitResponse_okWhenClean") {
        let env: [String: Value] = ["ok": .bool(true), "detail": .string("done")]
        let parsed = MemoryProcessBatchConfirm.parseCommitResponse(env)
        try expect(parsed.ok, "clean ok")
        try expect(!parsed.needsManual, "no manual flag")
    }

    await test("batch_aggregateStatusMessage_partialFailure") {
        let outcomes = [
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "a", kind: .reminder, ok: true, needsManual: false, detail: "ok", receiptHash: "h1"),
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "b", kind: .agentMemory, ok: false, needsManual: false, detail: "fail", receiptHash: nil),
        ]
        let result = MemoryProcessBatchConfirm.BatchCommitResult(outcomes: outcomes, processedGateCleared: false)
        let msg = MemoryProcessBatchConfirm.aggregateStatusMessage(result: result)
        try expect(msg.contains("1/2"), "partial count in message")
        try expect(result.anySuccess && !result.allSucceeded, "partial success flags")
    }

    await test("batch_triageCommittedDetail_includesCountAndKinds") {
        let outcomes = [
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "a", kind: .reminder, ok: true, needsManual: false, detail: "ok", receiptHash: "abc"),
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "b", kind: .registryUpdate, ok: false, needsManual: false, detail: "fail", receiptHash: nil),
        ]
        let result = MemoryProcessBatchConfirm.BatchCommitResult(outcomes: outcomes, processedGateCleared: false)
        let detail = MemoryProcessBatchConfirm.triageCommittedDetail(result: result)
        try expect(detail.contains("1/2"), "N/M in triage detail")
        try expect(detail.contains("reminder"), "successful kind listed")
        try expect(detail.contains("lastReceipt=abc"), "last receipt hash")
    }

    await test("batch_tagLabel_includesKindAndConfidence") {
        let row = batchRows().first { $0.kind == .reminder }!
        let label = MemoryProcessCockpit.tagLabel(for: row)
        try expect(label.contains("Reminder") || label.contains("reminder"), "kind in label")
        try expect(label.contains("92"), "confidence percent")
    }

    await test("batch_emptySelection_commitOrderEmpty") {
        try expect(MemoryProcessBatchConfirm.commitOrder(checkedIds: [], rows: batchRows()).isEmpty, "no checked ⇒ empty order")
    }

    await test("batch_confirmDisabledReason_emptySelection") {
        let reason = MemoryProcessBatchConfirm.confirmDisabledReason(checkedIds: [], rows: batchRows())
        try expect(reason?.contains("Select") == true, "empty selection reason")
    }
}
