// ConfirmPanelController.swift — sticky NSPanel for the Confirm body
// TheBridge · App
//
// MenuBarExtra `.window` on an LSUIElement app is not a reliable Confirm
// host (PR #260 live-fail: popover window count 0, 0 AXButtons). #262
// fronts this panel on escalate (activate + `.regular`, status-bar level,
// becomes key). It stays until Deny / Allow / Always Allow or the surface
// empties. Always Allow is never the AppKit default button (#264).

import AppKit
import SwiftUI

@MainActor
public final class ConfirmPanelController: ConfirmPanelPresenting {
    public static let shared = ConfirmPanelController()

    public nonisolated static let windowTitle = "The Bridge — Confirm"
    /// Confirm never assigns an AppKit default button. Always Allow must
    /// not fire on Return / Focus delivery (#264).
    public nonisolated static let assignsDefaultButton = false

    private var panel: NSPanel?

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

    /// True when a Confirm panel is on-screen (tests inspect host state;
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
        guard Self.canPresentPanel else { return }
        // LSUIElement: policy + unhide + activate BEFORE the window exists.
        // Creating an NSPanel while still `.accessory` never joins
        // `NSApp.windows` (#262 LIVE on 2bd375aa).
        ConfirmFrontApplicator.prepareApp()
        let host = NSHostingController(rootView: ConfirmPanelView(prompts: prompts))
        let fitting = host.view.fittingSize
        let size = NSSize(width: max(fitting.width, 400), height: max(fitting.height, 220))
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.wantsLayer = true

        let panel = self.panel ?? makePanel(size: size)
        panel.title = Self.windowTitle
        panel.contentView = host.view
        panel.setContentSize(size)
        position(panel, size: size)
        panel.defaultButtonCell = nil
        ConfirmFrontApplicator.apply(to: panel)
        self.panel = panel
        NotificationCenter.default.post(name: .confirmPanelDidChange, object: nil)
        // SwiftUI's first Button becomes AppKit's default after layout and
        // overwrites `defaultButtonCell = nil`. Always Allow is no longer a
        // Button (#264); still re-clear + re-front on the next turn so
        // LSUIElement cannot swallow the first orderFront (#262).
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.defaultButtonCell = nil
            ConfirmFrontApplicator.apply(to: panel)
        }
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        NotificationCenter.default.post(name: .confirmPanelDidChange, object: nil)
    }

    private func makePanel(size: NSSize) -> NSPanel {
        // Key-capable titled panel (not `.nonactivatingPanel`). Accessory
        // LSUIElement windows hide on deactivate — #262 fronts this as a
        // regular, key window at status-bar level. Always Allow is never
        // an AppKit default button (#264 / PR #267).
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = Self.windowTitle
        // Not a floating utility panel — those are omitted from NSApp.windows
        // / AX while the process is LSUIElement (#262 LIVE).
        panel.isFloatingPanel = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = ConfirmDelivery.hidesOnDeactivate
        panel.becomesKeyOnlyIfNeeded = !ConfirmDelivery.becomesKey
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .managed]
        panel.isReleasedWhenClosed = false
        panel.defaultButtonCell = nil
        return panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(
            x: screen.maxX - size.width - 16,
            y: screen.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    /// Real NSPanel only in the bundled app — never in TheBridgeTests.
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
