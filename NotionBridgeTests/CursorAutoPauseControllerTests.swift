// CursorAutoPauseControllerTests.swift — PKT-3.4.2 Wave 5b (Bridge v2.2)
// Coverage scenario D3: cost-cap soft trigger drives auto-pause; hard tier
// drives full lock + cancel fan-out. Tests inject `cancelFn` +
// `runningStatesProvider` so we don't touch the live runtime or registry.

import Foundation
import NotionBridgeLib

// Sendable reference holder for cross-suspension state in async tests.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func runCursorAutoPauseControllerTests() async {
    print("\n\u{1F500} CursorAutoPauseController Tests (PKT-3.4.2 Wave 5b · D3)")

    // Helper: build a CursorAgentRegistryState fixture on the main actor.
    @MainActor
    func makeRunningState(
        id: String,
        runtime: CursorRuntimeKind
    ) -> CursorAgentRegistryState {
        let run = CursorRun(
            id: id,
            runtime: runtime,
            model: "composer-2",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            costCents: 0,
            repoPath: "/Users/dev/repo-\(id)",
            prURL: nil,
            lastEventId: nil
        )
        return CursorAgentRegistryState(
            run: run,
            lastHeartbeat: Date(),
            healthLevel: .healthy,
            lastErrorMessage: nil
        )
    }

    // ------------------------------------------------------------------
    // 1) Initial state
    // ------------------------------------------------------------------
    await test("CursorAutoPauseController initial state is clear") {
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            try expect(ctl.pausedAt == nil)
            try expect(ctl.lockedAt == nil)
            try expect(ctl.isLocked == false)
            try expect(ctl.isPaused == false)
            try expect(ctl.isObserving == false)
        }
    }

    // ------------------------------------------------------------------
    // 2) Soft tier → pausedAt set, only CLOUD agents cancelled.
    // ------------------------------------------------------------------
    await test("D3: soft cap trip pauses + cancels cloud runs only") {
        let cancelled = Box<[String]>([])
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.runningStatesProvider = {
                [
                    makeRunningState(id: "cloud-1", runtime: .cloud),
                    makeRunningState(id: "cloud-2", runtime: .cloud),
                    makeRunningState(id: "local-1", runtime: .local),
                ]
            }
            ctl.cancelFn = { id in
                cancelled.value.append(id)
            }
            ctl.handleCapTripped(tier: "soft")
            try expect(ctl.pausedAt != nil)
            try expect(ctl.lockedAt == nil)
            try expect(ctl.isLocked == false)
            try expect(ctl.isPaused == true)
        }
        // Tasks dispatched inside cancelRunning are detached; give them a moment.
        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { cancelled.value.sorted() }
        try expect(recorded == ["cloud-1", "cloud-2"])
    }

    // ------------------------------------------------------------------
    // 3) Hard tier → lockedAt set AND pausedAt set; cancels EVERY runtime.
    // ------------------------------------------------------------------
    await test("D3: hard cap trip locks + cancels every runtime") {
        let cancelled = Box<[String]>([])
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.runningStatesProvider = {
                [
                    makeRunningState(id: "cloud-A", runtime: .cloud),
                    makeRunningState(id: "local-A", runtime: .local),
                ]
            }
            ctl.cancelFn = { id in
                cancelled.value.append(id)
            }
            ctl.handleCapTripped(tier: "hard")
            try expect(ctl.lockedAt != nil)
            try expect(ctl.pausedAt != nil) // hard implies pause
            try expect(ctl.isLocked == true)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { cancelled.value.sorted() }
        try expect(recorded == ["cloud-A", "local-A"])
    }

    // ------------------------------------------------------------------
    // 4) Unknown tier → no-op.
    // ------------------------------------------------------------------
    await test("unknown / under tier leaves state untouched") {
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.runningStatesProvider = { [] }
            ctl.handleCapTripped(tier: "under")
            ctl.handleCapTripped(tier: "")
            ctl.handleCapTripped(tier: "garbage")
            try expect(ctl.pausedAt == nil)
            try expect(ctl.lockedAt == nil)
        }
    }

    // ------------------------------------------------------------------
    // 5) unlock() clears both fields
    // ------------------------------------------------------------------
    await test("unlock() clears pausedAt + lockedAt") {
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.runningStatesProvider = { [] }
            ctl.handleCapTripped(tier: "hard")
            try expect(ctl.lockedAt != nil)
            ctl.unlock()
            try expect(ctl.pausedAt == nil)
            try expect(ctl.lockedAt == nil)
        }
    }

    // ------------------------------------------------------------------
    // 6) start()/stop() idempotent
    // ------------------------------------------------------------------
    await test("start()/stop() idempotent observer wiring") {
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.start()
            try expect(ctl.isObserving == true)
            ctl.start() // double-start safe
            try expect(ctl.isObserving == true)
            ctl.stop()
            try expect(ctl.isObserving == false)
            ctl.stop() // double-stop safe
            try expect(ctl.isObserving == false)
        }
    }

    // ------------------------------------------------------------------
    // 7) End-to-end: posting cursorAgentCostCapTripped drives the handler.
    // ------------------------------------------------------------------
    await test("D3 e2e: NotificationCenter post drives handleCapTripped") {
        let cancelled = Box<[String]>([])
        let ctlBox = Box<CursorAutoPauseController?>(nil)
        try await MainActor.run {
            let ctl = CursorAutoPauseController()
            ctl.runningStatesProvider = {
                [makeRunningState(id: "cloud-e2e", runtime: .cloud)]
            }
            ctl.cancelFn = { id in cancelled.value.append(id) }
            ctl.start()
            ctlBox.value = ctl
            NotificationCenter.default.post(
                name: .cursorAgentCostCapTripped,
                object: nil,
                userInfo: [
                    "tier": "soft",
                    "totalCents": 3000,
                    "thresholdCents": 2500,
                    "dateLocal": "2026-05-12"
                ]
            )
        }
        // Allow observer-dispatched task + cancel task to drain.
        try await Task.sleep(nanoseconds: 150_000_000)
        try await MainActor.run {
            try expect(ctlBox.value?.pausedAt != nil)
            try expect(ctlBox.value?.isLocked == false)
            ctlBox.value?.stop()
        }
        let recorded = await MainActor.run { cancelled.value }
        try expect(recorded == ["cloud-e2e"])
    }
}
