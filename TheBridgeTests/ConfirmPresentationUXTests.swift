// ConfirmPresentationUXTests.swift
// TheBridge · Tests
//
// #262 — assertive Confirm presentation + Time Sensitive registration.
// Hermetic: no WindowServer panel, no Focus LIVE. Bridge Keepr owns LIVE UX.

import Foundation
import UserNotifications
import TheBridgeLib

#if canImport(AppKit)
import AppKit
#endif

func runConfirmPresentationUXTests() async {
    print("\n🔔  Confirm presentation UX Tests (#262)")

    await test("Confirm auto-presents on escalate without status-item click") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "ux-auto-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=ux-auto",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        try await waitUntilConfirmPresented()
        try expect(ConfirmDelivery.autoPresentsOnEscalate)
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                   "escalate must open the Confirm body, not ATTENTION-only")
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
        try expect(await MainActor.run { ConfirmPanelHost.shared.visibleActionTitles.contains("Always Allow") })
    }

    await test("#262 publish alone auto-presents without AppDelegate handleSurfaceChange") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        let recorder = await MainActor.run { RecordingConfirmPresenter() }
        await MainActor.run {
            ConfirmPanelHost.shared.resetForTesting()
            ConfirmPanelHost.shared.presenter = recorder
        }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "ux-bind-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=bind",
            toolName: "standing_orders_delete",
            module: "standing_orders",
            allowAlwaysAllow: true,
            origin: .remote
        ))
        try await waitUntilConfirmPresented()
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                   "host must observe surface publish — AppDelegate Task hop is not required")
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
        try expect(await MainActor.run { recorder.syncCount } >= 1,
                   "presenter.syncConfirmPanel must run on publish, got \(await MainActor.run { recorder.syncCount })")
        try expect(await MainActor.run { ConfirmPanelHost.shared.visibleActionTitles }
                    == ["Deny", "Allow", "Always Allow"])
    }

    await test("second escalate re-asserts presented (not badge-only)") {
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }
        PendingApprovalSurface.shared.publish(PendingApprovalPrompt(
            id: "ux-refront-1",
            title: "The Bridge wants to standing_orders_delete",
            body: "id=refront",
            toolName: "standing_orders_delete",
            allowAlwaysAllow: true,
            origin: .local
        ))
        try await waitUntilConfirmPresented()
        // Click + re-assert on one MainActor hop so a leftover surface
        // observer cannot overwrite statusItemClick before the expect.
        try await MainActor.run {
            ConfirmPanelHost.shared.handleStatusItemClick()
            try expect(ConfirmPanelHost.shared.lastPresentReason == .statusItemClick)
            ConfirmPanelHost.shared.handleSurfaceChange()
            try expect(ConfirmPanelHost.shared.isPresented)
            try expect(
                ConfirmPanelHost.shared.lastPresentReason == .pendingRequest,
                "surface publish must re-assert escalate, not stay ATTENTION-click-only"
            )
        }
    }

    await test("Always Allow is visual primary and never the keyboard default") {
        try expect(ConfirmDelivery.alwaysAllowIsVisualPrimary)
        try expect(ConfirmDelivery.keyboardDefaultIsAlwaysAllow == false,
                   "#264: Always Allow must not be the Return-key default")
        try expect(ConfirmPresentation.alwaysAllowIsDefaultCapableControl == false,
                   "#264: Always Allow must not be a SwiftUI Button / AppKit default")
        try expect(ConfirmPresentation.actionTitles(allowAlwaysAllow: true)
                    == ["Deny", "Allow", "Always Allow"])
        try expect(ConfirmDelivery.alwaysAllowHint.contains("Notify"),
                   "Always Allow hint must say it sticks Notify")
        try expect(ConfirmDelivery.dashboardSectionTitle == "Needs your confirmation")
        try expect(ConfirmDelivery.panelHeadline.contains("OK"))
    }

    await test("#264 compact first action and default tap do not persist Notify") {
        try expect(
            ConfirmPresentation.shouldPersistNotifySticky(forNotificationActionIdentifier: "ALLOW_ACTION")
                == false,
            "compact first action (Allow) must not persist Notify"
        )
        try expect(
            ConfirmPresentation.shouldPersistNotifySticky(
                forNotificationActionIdentifier: UNNotificationDefaultActionIdentifier
            ) == false
        )
        try expect(
            ConfirmPresentation.shouldPersistNotifySticky(
                forNotificationActionIdentifier: UNNotificationDismissActionIdentifier
            ) == false
        )
        try expect(
            ConfirmPresentation.shouldPersistNotifySticky(forNotificationActionIdentifier: "ALWAYS_ALLOW")
        )
        try expect(ConfirmDelivery.alwaysAllowRequiresForeground == false,
                   "ALWAYS_ALLOW must not be unique .foreground — that was the 2bd375aa sticky misfire")
        try expect(ConfirmDelivery.alwaysAllowRequiresAuthentication)
        try expect(
            ConfirmDelivery.alwaysAllowNotificationActionOptions.contains(.foreground) == false,
            "PR #269 unique-foreground ALWAYS_ALLOW is the #264 LIVE trigger"
        )
        try expect(
            ConfirmDelivery.alwaysAllowNotificationActionOptions.contains(.authenticationRequired)
        )
    }

    await test("Time Sensitive registration includes Focus-breaking options") {
        try expect(
            ConfirmDelivery.authorizationOptions.contains(.timeSensitive),
            "requestAuthorization must ask for Time Sensitive (first prompt wins)"
        )
        try expect(ConfirmDelivery.authorizationOptions.contains(.alert))
        try expect(ConfirmDelivery.authorizationOptions.contains(.sound))
        try expect(ConfirmDelivery.authorizationOptions.contains(.badge))
        try expect(ConfirmDelivery.confirmInterruptionLevel == .timeSensitive)
        try expect(ConfirmDelivery.willPresentOptions.contains(.banner))
        try expect(ConfirmDelivery.willPresentOptions.contains(.sound))
        try expect(ConfirmDelivery.confirmThreadIdentifier == "bridge.confirm")
        try expect(ConfirmDelivery.notificationSubtitle.contains("Always Allow"))
        let content = UNMutableNotificationContent()
        ConfirmDelivery.applyConfirmContent(content)
        try expect(content.interruptionLevel == .timeSensitive)
        try expect(content.threadIdentifier == "bridge.confirm")
        try expect(content.subtitle == ConfirmDelivery.notificationSubtitle)
        try expect(content.sound != nil)
    }

    await test("Confirm keeps regular activation policy so LSUIElement cannot hide it") {
        try expect(ConfirmDelivery.activatesApplication)
        try expect(ConfirmDelivery.usesRegularActivationPolicy)
        try expect(ConfirmDelivery.becomesKey)
        try expect(ConfirmDelivery.hidesOnDeactivate == false)
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: true
            ),
            "visible Confirm must keep .regular"
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: true,
                hasVisibleConfirm: false
            )
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: false
            ) == false
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: false,
                pendingConfirmCount: 1
            ),
            "in-flight Request must keep .regular before the panel is in NSApp.windows"
        )
        try expect(
            ConfirmDelivery.shouldUseRegularActivationPolicy(
                hasVisibleSettings: false,
                hasVisibleConfirm: false,
                pendingConfirmCount: 0
            ) == false
        )
        try expect(
            ConfirmDelivery.shouldPresentPanel(pendingPromptCount: 1),
            "sync must present from the pending surface even if host.isPresented is still false"
        )
        try expect(ConfirmDelivery.shouldPresentPanel(pendingPromptCount: 0) == false)
        try expect(ConfirmDelivery.isConfirmWindowTitle(ConfirmPanelController.windowTitle))
        try expect(ConfirmDelivery.isConfirmWindowTitle("Settings") == false)
        try expect(ConfirmDelivery.panelWindowLevelName == "statusBar")
        try expect(
            Notification.Name.confirmPanelDidChange.rawValue
                == "com.notionbridge.confirmPanelDidChange",
            "dismiss must notify WindowTracker — orderOut does not fire willClose"
        )
    }

    await test("dual-notify mitigation is grouping + operator OS/Grok docs") {
        try expect(
            ConfirmDelivery.dualNotifyMitigation
                == .groupBridgeBannersDocumentOSMirroring
        )
        let doc = try String(
            contentsOfFile: "docs/operator/confirm-focus-and-dual-notify.md",
            encoding: .utf8
        )
        try expect(doc.contains("Time Sensitive"), "Focus/TCC doc must name Time Sensitive")
        try expect(doc.contains("Focus"), "Focus/TCC doc must name Focus")
        try expect(doc.contains("Grok"), "dual-notify doc must name Grok mirroring")
        try expect(doc.contains("iPhone"), "dual-notify doc must name iPhone mirroring")
        try expect(doc.contains("Notification Mirroring") || doc.contains("iPhone Notifications"),
                   "dual-notify doc must name the OS setting")
        try expect(doc.contains("bridge.confirm"))
        try expect(doc.contains("#264") || doc.contains("PR #267"),
                   "stacking note for compact-banner / default-button lane")
    }

    await test("#262 remote Request enforce auto-presents and does not persist Notify") {
        let perTool = BridgeDefaults.tierOverrides
        let perModule = BridgeDefaults.moduleTierOverrides
        let priorTool = UserDefaults.standard.object(forKey: perTool)
        let priorModule = UserDefaults.standard.object(forKey: perModule)
        defer {
            if let priorTool { UserDefaults.standard.set(priorTool, forKey: perTool) }
            else { UserDefaults.standard.removeObject(forKey: perTool) }
            if let priorModule { UserDefaults.standard.set(priorModule, forKey: perModule) }
            else { UserDefaults.standard.removeObject(forKey: perModule) }
        }
        var tools = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        tools.removeValue(forKey: "standing_orders_delete")
        UserDefaults.standard.set(tools, forKey: perTool)
        var mods = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
        mods.removeValue(forKey: "standing_orders")
        UserDefaults.standard.set(mods, forKey: perModule)
        NotifyStickyPersistLog.resetForTesting()
        PendingApprovalSurface.shared.resetForTesting()
        defer { PendingApprovalSurface.shared.resetForTesting() }
        await MainActor.run { ConfirmPanelHost.shared.resetForTesting() }

        let provider = TestSecurityApprovalProvider(decision: .pending)
        let gate = SecurityGate(approvalProvider: provider)
        let decision = await gate.enforce(
            toolName: "standing_orders_delete",
            tier: .request,
            arguments: .object(["id": .string("262-enforce")]),
            module: "standing_orders",
            context: ToolDispatchContext(
                transportSessionId: ToolDispatchContext.remoteConnectorJSONSessionID,
                origin: .remote
            )
        )
        switch decision {
        case .awaitingApproval: break
        default: throw TestError.assertion("expected awaitingApproval, got \(decision)")
        }
        try await waitUntilConfirmPresented()
        try expect(await MainActor.run { ConfirmPanelHost.shared.isPresented },
                   "remote awaiting_approval must auto-present Confirm")
        try expect(await MainActor.run { ConfirmPanelHost.shared.lastPresentReason } == .pendingRequest)
        try expect(await MainActor.run { ConfirmPanelHost.shared.visibleActionTitles.contains("Always Allow") })
        let stored = UserDefaults.standard.dictionary(forKey: perTool) as? [String: String] ?? [:]
        try expect(stored["standing_orders_delete"] == nil,
                   "pending must not write tierOverrides, got \(stored["standing_orders_delete"] ?? "nil")")
        let modules = UserDefaults.standard.dictionary(forKey: perModule) as? [String: String] ?? [:]
        try expect(modules["standing_orders"] == nil,
                   "pending must not write moduleTierOverrides")
        try expect(NotifyStickyPersistLog.lastRecord() == nil)
    }

    await test("test process still never opens a live Confirm NSPanel") {
        try expect(ConfirmPanelController.canPresentPanel == false)
        try expect(ConfirmPanelController.windowTitle == "The Bridge — Confirm")
    }
}

@MainActor
private final class RecordingConfirmPresenter: ConfirmPanelPresenting {
    var syncCount = 0
    func syncConfirmPanel() {
        syncCount += 1
    }
}

private func waitUntilConfirmPresented() async throws {
    let deadline = ContinuousClock.now + .milliseconds(500)
    while await MainActor.run(body: { ConfirmPanelHost.shared.isPresented }) == false {
        if ContinuousClock.now >= deadline {
            throw TestError.assertion(
                "Confirm host did not auto-present after surface publish"
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
