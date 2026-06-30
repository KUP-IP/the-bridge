// TriageSessionTests.swift — PKT-MEM-122 triage session hermetic tests
// TheBridge · Tests

import Foundation
import TheBridgeLib

func runTriageSessionTests() async {
    print("\n🤝 Triage session (PKT-MEM-122)")

    await test("triage_open_and_await_committed") {
        await TriageSessionStore.shared.resetForTesting()
        TriageSessionStore.testAllowWithoutHTTPClient = true
        TriageSessionStore.testOpenerClientId = "cursor-http"
        defer {
            TriageSessionStore.testAllowWithoutHTTPClient = false
            TriageSessionStore.testOpenerClientId = nil
        }

        let opened = try await TriageSessionStore.shared.open(memoId: "memo-1")
        try expect(!opened.sessionId.isEmpty, "session id required")
        try expect(opened.openerClientId == "cursor-http", "opener id")

        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await TriageSessionStore.shared.emitCommitted(
                memoId: "memo-1", receiptHash: "abc123", detail: "committed reminder")
        }

        let event = await TriageSessionStore.shared.awaitEvent(sessionId: opened.sessionId, timeoutSeconds: 2)
        try expect(event.kind == .committed, "expected committed, got \(event.kind)")
        try expect(event.receiptHash == "abc123", "receipt hash")
        await TriageSessionStore.shared.resetForTesting()
    }

    await test("triage_invalidate_emits_sessionEnded") {
        await TriageSessionStore.shared.resetForTesting()
        TriageSessionStore.testAllowWithoutHTTPClient = true
        defer { TriageSessionStore.testAllowWithoutHTTPClient = false }

        let opened = try await TriageSessionStore.shared.open(memoId: "memo-2")
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await TriageSessionStore.shared.invalidateForMemo(memoId: "memo-2")
        }
        let event = await TriageSessionStore.shared.awaitEvent(sessionId: opened.sessionId, timeoutSeconds: 2)
        try expect(event.kind == .sessionEnded, "expected sessionEnded, got \(event.kind)")
        await TriageSessionStore.shared.resetForTesting()
    }

    await test("triage_sessionAlreadyOpen_rejected") {
        await TriageSessionStore.shared.resetForTesting()
        TriageSessionStore.testAllowWithoutHTTPClient = true
        TriageSessionStore.testOpenerClientId = "test-http"
        defer {
            TriageSessionStore.testAllowWithoutHTTPClient = false
            TriageSessionStore.testOpenerClientId = nil
        }

        let first = try await TriageSessionStore.shared.open(memoId: "memo-open-dupe")
        try expect(await TriageSessionStore.shared.activeSession(forMemoId: "memo-open-dupe") == first.sessionId)
        do {
            _ = try await TriageSessionStore.shared.open(memoId: "memo-open-dupe")
            try expect(false, "second open must throw")
        } catch TriageSessionError.sessionAlreadyOpen(let mid) {
            try expect(mid == "memo-open-dupe", "memo id in error")
        } catch {
            throw TestError.assertion("unexpected error: \(error)")
        }
        await TriageSessionStore.shared.resetForTesting()
    }

    await test("triage_bridge_invalidateForMemo_callable") {
        MemoryHubTriageSessionBridge.invalidateForMemo(memoId: "noop")
    }

    await test("triage_batchDetail_format") {
        let outcomes = [
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "a", kind: .reminder, ok: true, needsManual: false, detail: "ok", receiptHash: "hash1"),
            MemoryProcessBatchConfirm.BatchCommitOutcome(intentId: "b", kind: .agentMemory, ok: true, needsManual: false, detail: "ok", receiptHash: "hash2"),
        ]
        let result = MemoryProcessBatchConfirm.BatchCommitResult(outcomes: outcomes, processedGateCleared: false)
        let detail = MemoryProcessBatchConfirm.triageCommittedDetail(result: result)
        try expect(detail.contains("2/2"), "batch triage detail N/M")
        try expect(detail.contains("lastReceipt=hash2"), "last receipt in triage detail")
    }

    await test("MemoryNavigationAnchor_compound_process_memoId") {
        let res = MemoryNavigationAnchor.resolve("process/memo-abc")
        try expect(res.tab == .process, "process tab")
        try expect(res.memoId == "memo-abc", "memo id tail")
    }

    await test("MemoryNavigationAnchor_inbox_filter") {
        let res = MemoryNavigationAnchor.resolve("inbox/awaitingAgent")
        try expect(res.tab == .inbox, "inbox tab")
        try expect(res.inboxFilter == .awaitingAgent, "filter")
    }

    await test("MemoryNavigationAnchor_activity_maps_process") {
        let res = MemoryNavigationAnchor.resolve("activity")
        try expect(res.tab == .process, "activity → process")
    }
}
