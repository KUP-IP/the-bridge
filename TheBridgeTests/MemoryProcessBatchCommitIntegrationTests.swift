// MemoryProcessBatchCommitIntegrationTests.swift — PKT-MEM-123 batch commit loop
// TheBridge · Tests
//
// Stub-router integration: three checked intents, middle commit fails, first and third
// succeed — proves continue-on-failure and aggregate status messaging.

import Foundation
import MCP
import TheBridgeLib

private func threeIntentPlan() -> VoiceMemoPlan {
    VoiceMemoPlan(generatedTitle: "Batch", skipMemoryKeep: false, summary: "s", actions: [], intents: [
        VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "Call back"),
        VoiceMemoIntent(kind: .agentMemory, confidence: 0.88, title: "Note for agent"),
        VoiceMemoIntent(kind: .memoryKeep, confidence: 0.90, title: "Notion memory"),
    ])
}

func runMemoryProcessBatchCommitIntegrationTests() async {
    print("\n🔗 Memory Process batch commit integration (PKT-MEM-123)")

    await test("batch_execute_continueOnMiddleFailure") {
        let memoId = "memo-batch-int"
        let plan = threeIntentPlan()
        let rows = MemoryProcessCockpit.intentRows(memoId: memoId, plan: plan)
        let checked = Set(rows.filter { MemoryProcessBatchConfirm.isTagCheckable($0) }.map(\.intentId))
        let ordered = MemoryProcessBatchConfirm.commitOrder(checkedIds: checked, rows: rows)
        try expect(ordered.count == 3, "three executable intents")

        let failId = ordered[1].intentId
        let outcomes = await MemoryProcessBatchConfirm.executeBatch(
            memoId: memoId,
            checkedIds: checked,
            rows: rows,
            selectedRowIdByIntentId: [:]
        ) { row, _ in
            if row.intentId == failId {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "guardrail blocked"])
            }
            return ["ok": .bool(true), "detail": .string("ok \(row.kind.rawValue)")]
        }

        try expect(outcomes.count == 3, "three outcomes recorded")
        try expect(outcomes[0].ok, "first intent succeeded")
        try expect(!outcomes[1].ok, "second intent failed")
        try expect(outcomes[2].ok, "third intent succeeded after failure")
        try expect(outcomes[1].intentId == failId, "middle failure is lane-priority second")

        let result = MemoryProcessBatchConfirm.BatchCommitResult(outcomes: outcomes, processedGateCleared: false)
        let msg = MemoryProcessBatchConfirm.aggregateStatusMessage(result: result)
        try expect(msg.contains("2/3"), "aggregate reports partial success: \(msg)")
        try expect(MemoryProcessBatchConfirm.triageCommittedDetail(result: result).contains("2/3"), "triage detail N/M")
    }

    await test("batch_execute_needsManual_notCountedAsSuccess") {
        let memoId = "memo-manual"
        let plan = VoiceMemoPlan(generatedTitle: "M", skipMemoryKeep: false, summary: "s", actions: [], intents: [
            VoiceMemoIntent(kind: .reminder, confidence: 0.92, title: "R"),
        ])
        let rows = MemoryProcessCockpit.intentRows(memoId: memoId, plan: plan)
        let id = rows.first!.intentId
        let outcomes = await MemoryProcessBatchConfirm.executeBatch(
            memoId: memoId,
            checkedIds: [id],
            rows: rows,
            selectedRowIdByIntentId: [:]
        ) { _, _ in
            ["ok": .bool(false), "needsManual": .bool(true), "detail": .string("pick manually")]
        }
        try expect(outcomes.count == 1, "one outcome")
        try expect(!outcomes[0].ok, "needsManual is not success")
        try expect(outcomes[0].needsManual, "needsManual flag set")
    }
}
