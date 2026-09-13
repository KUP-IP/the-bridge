// ConfirmLiveFailContractTests.swift
// TheBridge · Tests
//
// Integration-style contracts for the LIVE miss on installed main
// b8045b61 (PR #271) after 2bd375aa (PR #269) and f1c71cc7 (PR #268).
// Hermetic WindowServer probe + NAM.handleConfirmNotificationAction —
// not a parallel plan the live presenter can skip.

import Foundation
import UserNotifications
import TheBridgeLib

func runConfirmLiveFailContractTests() async {
    print("\n🧱  Confirm LIVE-fail contracts (#262/#264 on b8045b61)")

    await test("LSUIElement accessory plan flips policy then yields before create") {
        let plan = ConfirmSurfaceSync.forceSurfacePlan(
            currentPolicy: .accessory,
            pendingPromptCount: 1,
            hasVisibleConfirmWindow: false
        )
        try expect(ConfirmSurfaceSync.mustPreparePolicyBeforeCreatingWindow(currentPolicy: .accessory))
        try expect(plan.first == .setRegularActivationPolicy,
                   "accessory Confirm must set .regular before create, got \(plan)")
        let windowIdx = ConfirmSurfaceSync.firstWindowCommandIndex(in: plan)
        let policyIdx = plan.firstIndex(of: .setRegularActivationPolicy)
        let yieldIdx = ConfirmSurfaceSync.yieldIndex(in: plan)
        try expect(policyIdx != nil && windowIdx != nil && policyIdx! < windowIdx!,
                   "create must follow policy flip, plan=\(plan)")
        try expect(yieldIdx != nil && windowIdx != nil && yieldIdx! < windowIdx!,
                   "WindowServer yield must precede create, plan=\(plan)")
        try expect(plan.contains(.unhideApp))
        try expect(plan.contains(.activateIgnoringOtherApps))
        try expect(plan.contains(.createOrReusePanel))
        try expect(plan.last == .applyFront)
        try expect(ConfirmPanelController.surfacesViaForceSurfacePlan,
                   "live presenter must drive ConfirmSurfaceSync.run, not a parallel prepareApp+create")
    }

    await test("LSUIElement regular + pending still yields before create") {
        let plan = ConfirmSurfaceSync.forceSurfacePlan(
            currentPolicy: .regular,
            pendingPromptCount: 1,
            hasVisibleConfirmWindow: false
        )
        try expect(plan.contains(.setRegularActivationPolicy) == false)
        try expect(plan.contains(.yieldForWindowServer),
                   "already-regular still yields so WindowServer sees activate")
        try expect(plan.contains(.createOrReusePanel))
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: false,
                pendingConfirmCount: 1
            ),
            "pending Request must keep .regular even when windows=0"
        )
    }

    await test("empty pending plan does not create a Confirm window") {
        let plan = ConfirmSurfaceSync.forceSurfacePlan(
            currentPolicy: .accessory,
            pendingPromptCount: 0,
            hasVisibleConfirmWindow: false
        )
        try expect(plan.isEmpty, "no in-flight Request → no force-front, got \(plan)")
    }

    await test("WindowServer probe: same-turn create after policy flip leaves windows empty") {
        try await MainActor.run {
            let probe = ConfirmWindowServerProbe(policy: .accessory)
            probe.applySkippedYieldCreate()
            try expect(
                ConfirmSurfaceSync.windowJoinsAppWindows(policy: .regular, yieldedAfterRegular: false)
                    == false,
                "same-turn create is the b8045b61 / PR #271 live miss"
            )
            try expect(probe.windows.isEmpty,
                       "skipped yield must model TheBridge windows=0, got \(probe.windows)")
            try expect(probe.yieldCount == 0)
        }
    }

    await test("WindowServer probe: ConfirmSurfaceSync.run lists the Confirm window") {
        try await MainActor.run {
            let probe = ConfirmWindowServerProbe(policy: .accessory)
            ConfirmSurfaceSync.run(
                pendingPromptCount: 1,
                runtime: probe,
                hop: { work in work() }
            )
            try expect(probe.executed.contains(.yieldForWindowServer),
                       "run must apply yield, got \(probe.executed)")
            try expect(probe.yieldCount == 1)
            try expect(probe.windows == [ConfirmPanelController.windowTitle],
                       "yielded regular create must join windows, got \(probe.windows)")
            try expect(
                ConfirmSurfaceSync.windowJoinsAppWindows(policy: .regular, yieldedAfterRegular: true)
            )
        }
    }

    await test("ConfirmPanelController.present drives run — skip-yield presenter would fail") {
        try await MainActor.run {
            let probe = ConfirmWindowServerProbe(policy: .accessory)
            ConfirmSurfaceSession.makeRuntime = { _ in probe }
            defer { ConfirmSurfaceSession.resetForTesting() }
            ConfirmPanelController.shared.present(
                prompts: [
                    PendingApprovalPrompt(
                        id: "ws-present-1",
                        title: "The Bridge wants to standing_orders_delete",
                        body: "id=ws-present",
                        toolName: "standing_orders_delete",
                        module: "standing_orders",
                        allowAlwaysAllow: true,
                        origin: .remote
                    )
                ],
                // Sync hop so this turn sees create after yield (default hop is async).
                hop: { work in work() }
            )
            try expect(probe.executed.contains(.setRegularActivationPolicy))
            try expect(probe.executed.contains(.yieldForWindowServer),
                       "present() must not skip the WindowServer yield (PR #271 live miss)")
            try expect(probe.windows == [ConfirmPanelController.windowTitle],
                       "injected probe must see a listed window after present, got \(probe.windows)")
        }
    }

    await test("PR 269 unique-foreground ALWAYS_ALLOW is implicit and must not persist") {
        let v269 = NotifyStickyGate.pr269UniqueForegroundLayout
        try expect(
            NotifyStickyGate.uniqueForegroundActionIdentifier(actions: v269)
                == NotifyStickyGate.alwaysAllowActionIdentifier,
            "2bd375aa / PR #269 layout must classify as unique-foreground ALWAYS_ALLOW"
        )
        let source = NotifyStickyGate.sourceForNotificationAction(
            identifier: NotifyStickyGate.alwaysAllowActionIdentifier,
            categoryActions: v269
        )
        try expect(source == .implicitForeground)
        try expect(NotifyStickyGate.allowsPersist(source: .implicitForeground) == false)
    }

    await test("live banner ALWAYS_ALLOW is implicit even without unique foreground") {
        let live = ConfirmDelivery.confirmBannerActions
        try expect(live.first?.identifier == NotifyStickyGate.allowActionIdentifier)
        try expect(
            NotifyStickyGate.uniqueForegroundActionIdentifier(actions: live)
                != NotifyStickyGate.alwaysAllowActionIdentifier,
            "live ALWAYS_ALLOW must not be the unique .foreground action"
        )
        let source = NotifyStickyGate.sourceForNotificationAction(
            identifier: NotifyStickyGate.alwaysAllowActionIdentifier,
            categoryActions: live
        )
        try expect(source == .implicitForeground,
                   "UN ALWAYS_ALLOW cannot prove a tap (b8045b61 classified this as explicit)")
        try expect(NotifyStickyGate.allowsPersist(source: .notificationAlwaysAllow) == false,
                   "PR #271 treated notificationAlwaysAllow as explicit — that wrote prefs")
        try expect(ConfirmDelivery.notificationActionsPersistNotifySticky == false)
        try expect(
            ConfirmPresentation.outcome(forNotificationActionIdentifier: "ALWAYS_ALLOW")
                == .presentBody,
            "banner Always Allow must open Confirm, not resolve+persist"
        )
        try expect(
            ConfirmPresentation.shouldPersistNotifySticky(forNotificationActionIdentifier: "ALWAYS_ALLOW")
                == false
        )
    }

    await test("persistNotifySticky refuses implicit / escalate / default-button / UN") {
        try await withLiveFailCleanStickies {
            for source: NotifyStickyDecisionSource in [
                .implicitForeground, .pendingEscalate, .defaultButton, .notificationAlwaysAllow
            ] {
                NotifyStickyPersistLog.resetForTesting()
                NotificationApprovalManager.persistNotifySticky(
                    toolName: "standing_orders_delete",
                    module: "standing_orders",
                    source: source
                )
                let tools = UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides)
                    as? [String: String] ?? [:]
                try expect(
                    tools["standing_orders_delete"] != SecurityTier.notify.rawValue,
                    "\(source.rawValue) must not write tierOverrides"
                )
                let mods = UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides)
                    as? [String: String] ?? [:]
                try expect(
                    mods["standing_orders"] != SecurityTier.notify.rawValue,
                    "\(source.rawValue) must not write moduleTierOverrides"
                )
                try expect(NotifyStickyPersistLog.lastRecord() == nil,
                           "\(source.rawValue) must not log a persist")
            }
        }
    }

    await test("explicit Confirm-surface Always Allow still persists per-tool + module") {
        try await withLiveFailCleanStickies {
            NotificationApprovalManager.persistNotifySticky(
                toolName: "standing_orders_delete",
                module: "standing_orders",
                source: .confirmSurface
            )
            let tools = UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides)
                as? [String: String] ?? [:]
            let mods = UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides)
                as? [String: String] ?? [:]
            try expect(tools["standing_orders_delete"] == SecurityTier.notify.rawValue)
            try expect(mods["standing_orders"] == SecurityTier.notify.rawValue)
            try expect(NotifyStickyPersistLog.lastRecord()?.source == .confirmSurface)
        }
    }

    await test("UN ALWAYS_ALLOW didReceive path does not rewrite prefs or clear surface") {
        try await withLiveFailCleanStickies {
            PendingApprovalSurface.shared.resetForTesting()
            defer { PendingApprovalSurface.shared.resetForTesting() }
            ConfirmPanelSyncBridge.resetForTesting()
            ConfirmSurfaceSession.resetForTesting()
            await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }

            let title = "The Bridge wants to standing_orders_delete"
            let body = "id=live-fail-un-aa-\(UUID().uuidString)"
            let prompt = PendingApprovalPrompt(
                id: "un-aa-b8045b61",
                title: title,
                body: body,
                toolName: "standing_orders_delete",
                module: "standing_orders",
                allowAlwaysAllow: true,
                origin: .remote
            )
            PendingApprovalSurface.shared.publish(prompt)
            let mgr = NotificationApprovalManager(approvalTimeout: 8)
            let pending = await mgr.requestApproval(
                title: title,
                body: body,
                allowAlwaysAllowAction: true,
                forceModalReview: false
            )
            guard case .pending = pending else {
                throw TestError.assertion("#263 must stay pending, got \(pending)")
            }

            mgr.handleConfirmNotificationAction(
                actionIdentifier: NotifyStickyGate.alwaysAllowActionIdentifier,
                notificationIdentifier: "un-b8045b61",
                categoryIdentifier: "SECURITY_APPROVAL",
                title: title,
                body: body,
                userInfo: [
                    "toolName": "standing_orders_delete",
                    "module": "standing_orders"
                ]
            )

            try expect(PendingApprovalSurface.shared.pendingCount == 1,
                       "UN ALWAYS_ALLOW must not clear Confirm (PR #271 cleared it)")
            try expect(PendingApprovalSurface.shared.prompt(id: prompt.id) != nil)
            let tools = UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides)
                as? [String: String] ?? [:]
            let mods = UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides)
                as? [String: String] ?? [:]
            try expect(tools["standing_orders_delete"] == nil,
                       "UN ALWAYS_ALLOW must not write per-tool notify")
            try expect(mods["standing_orders"] == nil,
                       "UN ALWAYS_ALLOW must not write module notify")
            try expect(NotifyStickyPersistLog.lastRecord() == nil)
            try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                       "presentBody must keep / re-front Confirm")
        }
    }

    await test("2bd375aa probe: pending escalate presents and does not rewrite stickies") {
        try await withLiveFailCleanStickies {
            PendingApprovalSurface.shared.resetForTesting()
            defer { PendingApprovalSurface.shared.resetForTesting() }
            ConfirmPanelSyncBridge.resetForTesting()
            ConfirmSurfaceSession.resetForTesting()
            await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }

            let provider = TestSecurityApprovalProvider(decision: .pending)
            let gate = SecurityGate(approvalProvider: provider)
            let decision = await gate.enforce(
                toolName: "standing_orders_delete",
                tier: .request,
                arguments: .object(["id": .string("1C4ACE06")]),
                module: "standing_orders",
                context: ToolDispatchContext(
                    transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                    origin: .remote
                )
            )
            switch decision {
            case .awaitingApproval: break
            default:
                throw TestError.assertion("#263 must stay awaiting_approval, got \(decision)")
            }

            let deadline = ContinuousClock.now + .milliseconds(500)
            while await MainActor.run(body: { ConfirmPanelHost.shared.isPresented }) == false {
                if ContinuousClock.now >= deadline {
                    throw TestError.assertion("pending escalate must auto-present Confirm host")
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented })
            try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
            try expect(PendingApprovalSurface.shared.pendingCount == 1)

            NotificationApprovalManager.persistNotifySticky(
                toolName: "standing_orders_delete",
                module: "standing_orders",
                source: .pendingEscalate
            )
            NotificationApprovalManager.persistNotifySticky(
                toolName: "standing_orders_delete",
                module: "standing_orders",
                source: .implicitForeground
            )
            NotificationApprovalManager.persistNotifySticky(
                toolName: "standing_orders_delete",
                module: "standing_orders",
                source: .notificationAlwaysAllow
            )

            let tools = UserDefaults.standard.dictionary(forKey: BridgeDefaults.tierOverrides)
                as? [String: String] ?? [:]
            let mods = UserDefaults.standard.dictionary(forKey: BridgeDefaults.moduleTierOverrides)
                as? [String: String] ?? [:]
            try expect(tools["standing_orders_delete"] == nil,
                       "probe without Always Allow tap must not write per-tool notify")
            try expect(mods["standing_orders"] == nil,
                       "probe without Always Allow tap must not write module notify")
            try expect(NotifyStickyPersistLog.lastRecord() == nil)
            try expect(ConfirmPanelController.canPresentPanel == false)
        }
    }

    await test("#263 NAM still returns pending immediately (not weakened)") {
        let mgr = NotificationApprovalManager(approvalTimeout: 8)
        let start = ContinuousClock.now
        let decision = await mgr.requestApproval(
            title: "The Bridge wants to standing_orders_delete",
            body: "id=live-fail-263-\(UUID().uuidString)",
            allowAlwaysAllowAction: true,
            forceModalReview: false
        )
        let elapsed = start.duration(to: ContinuousClock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        guard case .pending = decision else {
            throw TestError.assertion("#263 pending return must hold, got \(decision)")
        }
        try expect(ms < 1500, "must not wait approvalTimeout, took \(Int(ms))ms")
    }
}

private func withLiveFailCleanStickies(_ body: () async throws -> Void) async throws {
    let perTool = BridgeDefaults.tierOverrides
    let perModule = BridgeDefaults.moduleTierOverrides
    var tools = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
    var mods = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
    let priorTool = tools["standing_orders_delete"]
    let priorMod = mods["standing_orders"]
    defer {
        var t = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        var m = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
        if let priorTool { t["standing_orders_delete"] = priorTool }
        else { t.removeValue(forKey: "standing_orders_delete") }
        if let priorMod { m["standing_orders"] = priorMod }
        else { m.removeValue(forKey: "standing_orders") }
        UserDefaults.standard.set(t, forKey: perTool)
        UserDefaults.standard.set(m, forKey: perModule)
        NotifyStickyPersistLog.resetForTesting()
        ConfirmSurfaceSession.resetForTesting()
    }
    tools.removeValue(forKey: "standing_orders_delete")
    mods.removeValue(forKey: "standing_orders")
    UserDefaults.standard.set(tools, forKey: perTool)
    UserDefaults.standard.set(mods, forKey: perModule)
    NotifyStickyPersistLog.resetForTesting()
    try await body()
}
