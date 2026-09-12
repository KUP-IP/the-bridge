// ConfirmLiveFailContractTests.swift
// TheBridge · Tests
//
// Integration-style contracts that would have failed on installed main
// 2bd375aa (PR #269). Hermetic: no WindowServer, no live UN delivery.
// Models LSUIElement surface sync + sticky gate + #263 pending.

import Foundation
import UserNotifications
import TheBridgeLib

func runConfirmLiveFailContractTests() async {
    print("\n🧱  Confirm LIVE-fail contracts (#262/#264 on 2bd375aa)")

    await test("LSUIElement accessory plan flips policy before any window command") {
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
        try expect(policyIdx != nil && windowIdx != nil && policyIdx! < windowIdx!,
                   "create/front must follow policy flip, plan=\(plan)")
        try expect(plan.contains(.unhideApp))
        try expect(plan.contains(.activateIgnoringOtherApps))
        try expect(plan.contains(.createOrReusePanel))
        try expect(plan.last == .applyFront)
    }

    await test("LSUIElement regular + pending still unhides and fronts") {
        let plan = ConfirmSurfaceSync.forceSurfacePlan(
            currentPolicy: .regular,
            pendingPromptCount: 1,
            hasVisibleConfirmWindow: false
        )
        try expect(plan.contains(.setRegularActivationPolicy) == false)
        try expect(plan.contains(.unhideApp))
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

    await test("current banner actions must not make ALWAYS_ALLOW unique foreground") {
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
        try expect(source == .notificationAlwaysAllow,
                   "without unique foreground, ALWAYS_ALLOW stays explicit")
        try expect(NotifyStickyGate.allowsPersist(source: .notificationAlwaysAllow))
    }

    await test("persistNotifySticky refuses implicit / escalate / default-button") {
        try await withLiveFailCleanStickies {
            for source: NotifyStickyDecisionSource in [
                .implicitForeground, .pendingEscalate, .defaultButton
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

    await test("explicit Always Allow sources still persist per-tool + module") {
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

    await test("2bd375aa probe: pending escalate presents and does not rewrite stickies") {
        try await withLiveFailCleanStickies {
            PendingApprovalSurface.shared.resetForTesting()
            defer { PendingApprovalSurface.shared.resetForTesting() }
            ConfirmPanelSyncBridge.resetForTesting()
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
    }
    tools.removeValue(forKey: "standing_orders_delete")
    mods.removeValue(forKey: "standing_orders")
    UserDefaults.standard.set(tools, forKey: perTool)
    UserDefaults.standard.set(mods, forKey: perModule)
    NotifyStickyPersistLog.resetForTesting()
    try await body()
}
