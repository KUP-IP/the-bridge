// ConfirmPanelController.swift — sticky Confirm window for the Confirm body
// TheBridge · App
//
// MenuBarExtra `.window` on an LSUIElement app is not a reliable Confirm
// host (PR #260 live-fail: popover window count 0, 0 AXButtons). #262
// fronts this window on escalate (activate + `.regular` **then a
// WindowServer yield**, then create). Same-turn create after
// `setActivationPolicy` is omitted from `NSApp.windows` (LIVE on
// b8045b61). Always Allow is never the AppKit default button (#264).

import AppKit
import SwiftUI

@MainActor
public final class ConfirmPanelController: ConfirmPanelPresenting {
    public static let shared = ConfirmPanelController()

    public static let windowTitle = "The Bridge — Confirm"
    /// Confirm never assigns an AppKit default button. Always Allow must
    /// not fire on Return / Focus delivery (#264).
    public nonisolated static let assignsDefaultButton = false
    /// Live `present` must drive `ConfirmSurfaceSync.run` (yield before
    /// create). Tests fail if this is false or if a parallel path creates.
    public nonisolated static let surfacesViaForceSurfacePlan = true

    private var panel: NSWindow?

    public init() {}

    /// Wire the host so a remote `awaiting_approval` publish fronts
    /// without waiting on AppDelegate's notification Task.
    public static func registerAsPresenter() {
        ConfirmPanelHost.shared.presenter = shared
        ConfirmPanelHost.shared.bindToSurface()
        ConfirmPanelSyncBridge.sync = { ConfirmPanelController.shared.sync() }
    }

    public func syncConfirmPanel() {
        sync()
    }

    /// True when a Confirm window is on-screen (tests inspect host state;
    /// this is the AppKit mirror for the live app).
    public var isPanelVisible: Bool {
        panel?.isVisible == true
    }

    public func sync() {
        let prompts = PendingApprovalSurface.shared.snapshot()
        if ConfirmDelivery.shouldPresentPanel(pendingPromptCount: prompts.count) {
            present(prompts: prompts)
        } else {
            dismiss()
        }
    }

    public func present(prompts: [PendingApprovalPrompt]) {
        let runtime = ConfirmSurfaceSession.makeRuntime(prompts)
        ConfirmSurfaceSync.run(
            pendingPromptCount: prompts.count,
            runtime: runtime
        )
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        NotificationCenter.default.post(name: .confirmPanelDidChange, object: nil)
    }

    /// Create / reuse the window. Only after `ConfirmSurfaceSync` has
    /// flipped policy and yielded. Re-reads the surface so a hop after
    /// UN misfire / resolve does not resurrect an empty Confirm.
    func materialize(prompts: [PendingApprovalPrompt]) {
        guard Self.canPresentPanel else { return }
        let live = PendingApprovalSurface.shared.snapshot()
        let cards = live.isEmpty ? prompts : live
        guard ConfirmDelivery.shouldPresentPanel(pendingPromptCount: live.count) else {
            dismiss()
            return
        }
        let host = NSHostingController(rootView: ConfirmPanelView(prompts: cards))
        let fitting = host.view.fittingSize
        let size = NSSize(width: max(fitting.width, 400), height: max(fitting.height, 220))
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.wantsLayer = true

        let window = self.panel ?? makeWindow(size: size)
        window.title = Self.windowTitle
        window.contentView = host.view
        window.setContentSize(size)
        position(window, size: size)
        window.defaultButtonCell = nil
        self.panel = window
        NotificationCenter.default.post(name: .confirmPanelDidChange, object: nil)
    }

    func frontExisting() {
        guard let window = panel else { return }
        window.defaultButtonCell = nil
        ConfirmFrontApplicator.apply(to: window)
        NotificationCenter.default.post(name: .confirmPanelDidChange, object: nil)
        if Self.canPresentPanel && !ConfirmFrontApplicator.confirmWindowIsListed() {
            ConfirmSurfaceSync.scheduleAfterWindowServerYield { [weak self] in
                guard let self, let window = self.panel else { return }
                ConfirmFrontApplicator.prepareApp()
                window.defaultButtonCell = nil
                ConfirmFrontApplicator.apply(to: window)
            }
        }
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        // Key-capable titled window (not NSPanel / `.nonactivatingPanel`).
        // LSUIElement NSPanels are still omitted from NSApp.windows / AX
        // after a same-turn `.regular` flip (#262 LIVE on b8045b61).
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.level = .statusBar
        window.hidesOnDeactivate = ConfirmDelivery.hidesOnDeactivate
        window.collectionBehavior = [.canJoinAllSpaces, .managed]
        window.isReleasedWhenClosed = false
        window.defaultButtonCell = nil
        return window
    }

    private func position(_ window: NSWindow, size: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(
            x: screen.maxX - size.width - 16,
            y: screen.maxY - size.height - 8
        )
        window.setFrameOrigin(origin)
    }

    /// Real Confirm window only in the bundled app — never in TheBridgeTests.
    /// `nonisolated` so SecurityGateUXTests can read it off the main actor
    /// under `-strict-concurrency=complete`.
    public nonisolated static var canPresentPanel: Bool {
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("thebridgetests") || processName.contains("notionbridgetests") {
            return false
        }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}

/// AppKit adapter driven by `ConfirmSurfaceSync.run`.
@MainActor
public final class ConfirmAppKitSurfaceRuntime: ConfirmSurfaceRuntime {
    let prompts: [PendingApprovalPrompt]

    public init(prompts: [PendingApprovalPrompt]) {
        self.prompts = prompts
    }

    public var currentPolicy: ConfirmActivationPolicy {
        if let app = NSApp, app.activationPolicy() == .regular {
            return .regular
        }
        return .accessory
    }

    public var hasVisibleConfirmWindow: Bool {
        ConfirmFrontApplicator.confirmWindowIsListed()
    }

    public func apply(_ command: ConfirmSurfaceCommand) {
        switch command {
        case .setRegularActivationPolicy, .unhideApp, .activateIgnoringOtherApps:
            ConfirmFrontApplicator.prepareApp()
        case .yieldForWindowServer:
            break
        case .createOrReusePanel:
            ConfirmPanelController.shared.materialize(prompts: prompts)
        case .applyFront:
            ConfirmPanelController.shared.frontExisting()
        }
    }
}
