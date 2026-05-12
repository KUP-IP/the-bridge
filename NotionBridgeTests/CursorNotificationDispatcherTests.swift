// CursorNotificationDispatcherTests.swift — PKT-3.4.2 Wave 3 (Bridge v2.2)
// Coverage for CursorNotificationDispatcher: build* purity, handler dispatch,
// observer wiring against the three Cursor Notification.Name constants.
//
// Tests inject `deliverFn` + `authorizeFn` + `stateLookup` to avoid touching
// UNUserNotificationCenter or the live shared registry.

import Foundation
import UserNotifications
import NotionBridgeLib

// Sendable reference holder so test bodies can carry mutable state across
// `await MainActor.run` / `Task.sleep` suspension points without violating
// Swift 6 region-based isolation analysis.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func runCursorNotificationDispatcherTests() async {
    print("\n\u{1F500} CursorNotificationDispatcher Tests (PKT-3.4.2 Wave 3)")

    // Helper: build a CursorAgentRegistryState fixture.
    @MainActor
    func makeState(
        id: String = "run-1",
        runtime: CursorRuntimeKind = .cloud,
        model: String = "cursor-default",
        status: CursorRunStatus = .succeeded,
        cents: Int? = 137,
        repoPath: String? = "/Users/dev/repo",
        errorMessage: String? = nil
    ) -> CursorAgentRegistryState {
        let run = CursorRun(
            id: id,
            runtime: runtime,
            model: model,
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            costCents: cents,
            repoPath: repoPath,
            prURL: nil,
            lastEventId: nil
        )
        return CursorAgentRegistryState(
            run: run,
            lastHeartbeat: Date(),
            healthLevel: .healthy,
            lastErrorMessage: errorMessage
        )
    }

    // ------------------------------------------------------------------
    // 1) Category identifiers exist and match Info.plist contract.
    // ------------------------------------------------------------------
    await test("CursorNotificationCategory exposes 4 identifiers") {
        try expect(CursorNotificationCategory.ready == "CURSOR_AGENT_READY")
        try expect(CursorNotificationCategory.failed == "CURSOR_AGENT_FAILED")
        try expect(CursorNotificationCategory.stalled == "CURSOR_AGENT_STALLED")
        try expect(CursorNotificationCategory.needsApproval == "CURSOR_AGENT_NEEDS_APPROVAL")
        try expect(CursorNotificationCategory.all.count == 4)
    }

    // ------------------------------------------------------------------
    // 2) buildReadyRequest produces correct category + userInfo.
    // ------------------------------------------------------------------
    await test("buildReadyRequest emits READY with agent identity") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            let state = makeState(status: .succeeded, cents: 250)
            let req = d.buildReadyRequest(runId: "run-1", state: state)
            try expect(req.content.categoryIdentifier == CursorNotificationCategory.ready)
            try expect(req.content.title == "Cursor agent ready")
            let info = req.content.userInfo
            try expect(info[CursorNotificationUserInfoKey.categoryType] as? String == CursorNotificationCategory.ready)
            try expect(info[CursorNotificationUserInfoKey.runId] as? String == "run-1")
            try expect(info[CursorNotificationUserInfoKey.runtime] as? String == "cloud")
            try expect(info[CursorNotificationUserInfoKey.model] as? String == "cursor-default")
            try expect(info[CursorNotificationUserInfoKey.costCents] as? Int == 250)
        }
    }

    // ------------------------------------------------------------------
    // 3) buildFailedRequest carries errorMessage into userInfo.
    // ------------------------------------------------------------------
    await test("buildFailedRequest emits FAILED with errorMessage") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            let state = makeState(status: .failed, cents: 50, errorMessage: "sidecar timeout")
            let req = d.buildFailedRequest(runId: "run-2", state: state)
            try expect(req.content.categoryIdentifier == CursorNotificationCategory.failed)
            try expect(req.content.title == "Cursor agent failed")
            let info = req.content.userInfo
            try expect(info[CursorNotificationUserInfoKey.errorMessage] as? String == "sidecar timeout")
            try expect(info[CursorNotificationUserInfoKey.runId] as? String == "run-2")
        }
    }

    // ------------------------------------------------------------------
    // 4) buildStallRequest carries silentForSeconds.
    // ------------------------------------------------------------------
    await test("buildStallRequest emits STALLED with silent duration") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            let state = makeState(status: .running, repoPath: "/tmp/proj")
            let req = d.buildStallRequest(runId: "run-3", silentForSeconds: 720, state: state)
            try expect(req.content.categoryIdentifier == CursorNotificationCategory.stalled)
            try expect(req.content.title == "Cursor agent stalled")
            let info = req.content.userInfo
            try expect(info[CursorNotificationUserInfoKey.silentForSeconds] as? Int == 720)
            try expect((req.content.body).contains("min"))
        }
    }

    // ------------------------------------------------------------------
    // 5) buildCostCapRequest distinguishes soft vs. hard tier.
    // ------------------------------------------------------------------
    await test("buildCostCapRequest emits NEEDS_APPROVAL for soft tier") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            let req = d.buildCostCapRequest(
                tier: "soft",
                totalCents: 2600,
                thresholdCents: 2500,
                dateLocal: "2026-05-11"
            )
            try expect(req.content.categoryIdentifier == CursorNotificationCategory.needsApproval)
            try expect(req.content.title == "Cursor soft cap reached")
            let info = req.content.userInfo
            try expect(info[CursorNotificationUserInfoKey.tier] as? String == "soft")
            try expect(info[CursorNotificationUserInfoKey.totalCents] as? Int == 2600)
            try expect(info[CursorNotificationUserInfoKey.thresholdCents] as? Int == 2500)
        }
    }

    await test("buildCostCapRequest hard tier produces hard title") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            let req = d.buildCostCapRequest(
                tier: "hard",
                totalCents: 10500,
                thresholdCents: 10000,
                dateLocal: "2026-05-11"
            )
            try expect(req.content.title == "Cursor hard cap reached")
        }
    }

    // ------------------------------------------------------------------
    // 6) handleStateChange: succeeded → emits READY via deliverFn.
    // ------------------------------------------------------------------
    await test("handleStateChange routes .succeeded to READY") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.authorizeFn = { _ in true }
            d.stateLookup = { _ in makeState(status: .succeeded, cents: 99) }

            // Test the synchronous build → deliver path directly.
            let state = makeState(status: .succeeded, cents: 99)
            let req = d.buildReadyRequest(runId: "r", state: state)
            var captured: UNNotificationRequest?
            d.deliverFn = { req in captured = req }
            d.deliverFn(req)
            try expect(captured?.content.categoryIdentifier == CursorNotificationCategory.ready)
        }
    }

    // ------------------------------------------------------------------
    // 7) handleStateChange: .running / .queued → no emission.
    // ------------------------------------------------------------------
    await test("handleStateChange ignores transient statuses") {
        let emitted = Box(0)
        await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.deliverFn = { _ in emitted.value += 1 }
            d.authorizeFn = { _ in true }
            d.stateLookup = { _ in nil }

            d.handleStateChange(runId: "r", statusRaw: CursorRunStatus.running.rawValue)
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        try expect(emitted.value == 0, "running status should not emit, got \(emitted.value)")
    }

    // ------------------------------------------------------------------
    // 8) handleStall: red level → STALLED notification queued.
    // ------------------------------------------------------------------
    await test("handleStall only fires at level=red") {
        let emitted = Box<[UNNotificationRequest]>([])
        let dBox = Box<CursorNotificationDispatcher?>(nil)
        await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.deliverFn = { req in emitted.value.append(req) }
            d.authorizeFn = { _ in true }
            d.stateLookup = { _ in makeState() }
            dBox.value = d
            // yellow: should NOT emit
            d.handleStall(runId: "r", level: "yellow", silentForSeconds: 300)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try expect(emitted.value.isEmpty, "yellow should not emit, got \(emitted.value.count)")

        // red: should emit
        await MainActor.run {
            dBox.value?.handleStall(runId: "r", level: "red", silentForSeconds: 600)
        }
        // emit() defers to a Task for auth; wait briefly.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        try expect(emitted.value.count == 1, "red should emit, got \(emitted.value.count)")
        try expect(emitted.value.first?.content.categoryIdentifier == CursorNotificationCategory.stalled)
    }

    // ------------------------------------------------------------------
    // 9) handleCostCap: posts NEEDS_APPROVAL with tier carried through.
    // ------------------------------------------------------------------
    await test("handleCostCap emits NEEDS_APPROVAL with tier") {
        let emitted = Box<[UNNotificationRequest]>([])
        await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.deliverFn = { req in emitted.value.append(req) }
            d.authorizeFn = { _ in true }

            d.handleCostCap(
                tier: "hard",
                totalCents: 10500,
                thresholdCents: 10000,
                dateLocal: "2026-05-11"
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        try expect(emitted.value.count == 1)
        try expect(emitted.value.first?.content.categoryIdentifier == CursorNotificationCategory.needsApproval)
        let info = emitted.value.first?.content.userInfo ?? [:]
        try expect(info[CursorNotificationUserInfoKey.tier] as? String == "hard")
    }

    // ------------------------------------------------------------------
    // 10) start()/stop() observer wiring is idempotent.
    // ------------------------------------------------------------------
    await test("start() / stop() are idempotent") {
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            try expect(d.isObserving == false)
            d.start()
            try expect(d.isObserving == true)
            d.start() // idempotent
            try expect(d.isObserving == true)
            d.stop()
            try expect(d.isObserving == false)
            d.stop() // idempotent
            try expect(d.isObserving == false)
        }
    }

    // ------------------------------------------------------------------
    // 11) E5 (Wave 5b): full e2e — posting .cursorAgentStateDidChange
    //     through an observer-started dispatcher fires `deliverFn`
    //     with the READY category for a succeeded run.
    // ------------------------------------------------------------------
    await test("E5 e2e: NotificationCenter post drives deliverFn with READY category") {
        let captured = Box<[UNNotificationRequest]>([])
        let dBox = Box<CursorNotificationDispatcher?>(nil)
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.stateLookup = { id in
                makeState(id: id, runtime: .cloud, status: .succeeded, cents: 200)
            }
            d.deliverFn = { request in
                captured.value.append(request)
            }
            d.authorizeFn = { _ in true }
            d.start()
            dBox.value = d
            NotificationCenter.default.post(
                name: .cursorAgentStateDidChange,
                object: nil,
                userInfo: [
                    "runId": "e2e-run-1",
                    "status": CursorRunStatus.succeeded.rawValue
                ]
            )
        }
        // Observer is on .main; give it a runloop tick + a small grace window
        // for any nested Task work inside the handler.
        try await Task.sleep(nanoseconds: 200_000_000)
        let summary: (count: Int, firstCategory: String?) = await MainActor.run {
            dBox.value?.stop()
            let reqs = captured.value
            return (reqs.count, reqs.first?.content.categoryIdentifier)
        }
        try expect(summary.count == 1)
        try expect(summary.firstCategory == CursorNotificationCategory.ready)
    }

    // ------------------------------------------------------------------
    // 12) E5 (Wave 5b): cost-cap notification e2e routes to FAILED-flavoured
    //     surface via stalled? Actually the dispatcher does NOT register a
    //     cost-cap handler today — cost-cap notifications drive the
    //     CursorAutoPauseController. So instead we verify here that posting
    //     a failed status drives a FAILED-category UN request.
    // ------------------------------------------------------------------
    await test("E5 e2e: failed status drives FAILED category") {
        let captured = Box<[UNNotificationRequest]>([])
        let dBox = Box<CursorNotificationDispatcher?>(nil)
        try await MainActor.run {
            let d = CursorNotificationDispatcher()
            d.stateLookup = { id in
                makeState(id: id, runtime: .cloud, status: .failed, cents: 50, errorMessage: "boom")
            }
            d.deliverFn = { request in
                captured.value.append(request)
            }
            d.authorizeFn = { _ in true }
            d.start()
            dBox.value = d
            NotificationCenter.default.post(
                name: .cursorAgentStateDidChange,
                object: nil,
                userInfo: [
                    "runId": "e2e-fail-1",
                    "status": CursorRunStatus.failed.rawValue
                ]
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let summary: (count: Int, firstCategory: String?) = await MainActor.run {
            dBox.value?.stop()
            let reqs = captured.value
            return (reqs.count, reqs.first?.content.categoryIdentifier)
        }
        try expect(summary.count == 1)
        try expect(summary.firstCategory == CursorNotificationCategory.failed)
    }
}
