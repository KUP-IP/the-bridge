// CommandBridge.swift — PKT-878 v3.6.3
// NotionBridge · App
//
// The Command Bridge popup, rebuilt as a SwiftUI Liquid Glass surface
// inside a borderless non-activating NSPanel. Replaces the legacy
// `CommandBoxController` / `CommandBoxPanel` (NSTableView-backed) with
// the locked design at `design/command-bridge.html`:
//
//   • A 10-slot `BridgeGlassBubble` tray (slots 1…0). Slots with a
//     `CommandStore` favorite render their icon; unassigned slots are
//     `visibility:hidden` so the keycap positions stay stable.
//   • A central pill containing the leading bridge icon, an inline
//     query field, and a trailing ⌘ chip that deep-links to
//     Settings → Commands via `SettingsNavigation.shared.go(.commands)`.
//   • A panel below the pill that ONLY appears on ↓ (recents) or while
//     typing (search results). Recents is in-memory session-only (locked
//     decision Q1).
//
// Behaviour locked by PKT-878:
//   • Number key 1–0 → fires the assigned favorite → copies its
//     markdown body to the system pasteboard → closes.
//   • ↓ → opens the recents slide-in (140ms ease).
//   • Typing → substring search across all commands, ranked by recency.
//   • Enter or click on a row → fires the selected command (copy +
//     close). Esc / focus-loss → closes without writing.
//   • Open animation: 180ms ease-out, opacity 0→1, scale 0.94→1.0,
//     with a 10ms cascade stagger across the 10 bubbles.
//   • Reduce-motion → all animations collapse to instant.
//
// What was REUSED verbatim from the legacy `CommandBox.swift`:
//   • `HotkeyConfig`            — Carbon `RegisterEventHotKey` config
//                                  + persisted-load + Cocoa→Carbon recorder
//   • `ClipboardWriting`/`InMemoryClipboard`/`SystemClipboard`
//                                  — write-only pasteboard seam
//   • Carbon hot-key REGISTRATION shape (InstallEventHandler +
//     RegisterEventHotKey) — pulled into `registerHotkey()` below
//     unchanged in semantics so the operator-smoke contract is
//     bit-for-bit identical to the prior controller.
//   • Static placement math — multi-monitor screen pick is unchanged.
//     The bottom-edge factor flips from the legacy 28%-up-from-bottom
//     to the locked PKT-878 25%-up-from-bottom (Q2) and the panel
//     centre (not its origin) is anchored at that point.
//
// HONEST P2 GUI CEILING (NOT papered over): the Carbon hot-key actually
// firing on the live WindowServer, the borderless NSPanel becoming key
// without activating the app, the SwiftUI rendering, and the focus-loss
// dismiss all require a real login session. The DECISION layers below
// (the state machine, the placement math, the search ranking, the
// recents tracker, the commit→clipboard write, the animation config)
// are PURE and unit-tested headlessly.

import Foundation
import AppKit
import SwiftUI
import Carbon.HIToolbox
import CoreGraphics
import ApplicationServices

// ============================================================
// MARK: - 1. CommandBridgePanel (borderless non-activating)
// ============================================================

/// Borderless, non-activating floating panel. Shows over the active app
/// without making this app the foreground. `canBecomeKey` is true so
/// the hosted SwiftUI text field can receive typing while the previous
/// app stays visually active (the Spotlight/Alfred pattern).
public final class CommandBridgePanel: NSPanel {
    public init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // shadows are baked into BridgeGlass surfaces
        // v3.7.6: system-tethered appearance — leave `appearance` UNSET so the
        // palette follows the system (its hosted SwiftUI glass adapts live).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

// ============================================================
// MARK: - 2. RecentsTracker (in-memory session log)
//
//   Locked decision Q1: recents are session-only, no persistence. The
//   tracker keeps the most-recently-fired command slugs in MRU order
//   and is reset to empty on app launch. Pure (no AppKit, no defaults)
//   so the ordering + cap behaviour is unit-tested headlessly.
// ============================================================

public final class CommandBridgeRecents: @unchecked Sendable {
    public static let shared = CommandBridgeRecents()
    private let lock = NSLock()
    private var slugs: [String] = []
    private let cap: Int

    public init(cap: Int = 8) { self.cap = max(1, cap) }

    /// Most-recently-fired first.
    public var ordered: [String] {
        lock.lock(); defer { lock.unlock() }
        return slugs
    }

    /// Record that `slug` was just fired. Moves it to the front (MRU)
    /// and trims to `cap`. Returns the new ordered list.
    @discardableResult
    public func record(_ slug: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        slugs.removeAll(where: { $0 == slug })
        slugs.insert(slug, at: 0)
        if slugs.count > cap { slugs.removeLast(slugs.count - cap) }
        return slugs
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        slugs.removeAll()
    }
}

// ============================================================
// MARK: - 3. CommandBridgeAnimation (pure animation config)
// ============================================================

/// All animation tunables for the popup, gathered so they are
/// unit-asserted as a single value type (no GUI dependency). The
/// `reduceMotion` flag collapses everything to instant — that is what
/// `@Environment(\.accessibilityReduceMotion)` flips on inside the view.
public struct CommandBridgeAnimation: Sendable, Equatable {
    /// Open animation duration (seconds). Locked at 180ms.
    public let openDuration: TimeInterval
    /// Stagger between bubble appearances (seconds). Locked at 10ms.
    public let bubbleCascadeStagger: TimeInterval
    /// Recents panel slide-in duration (seconds). Locked at 140ms.
    public let recentsSlideDuration: TimeInterval
    /// Starting scale for the open animation. Locked at 0.94.
    public let openStartScale: CGFloat
    /// Starting opacity for the open animation. Locked at 0.
    public let openStartOpacity: Double

    public init(reduceMotion: Bool = false) {
        if reduceMotion {
            self.openDuration = 0
            self.bubbleCascadeStagger = 0
            self.recentsSlideDuration = 0
            self.openStartScale = 1.0
            self.openStartOpacity = 1.0
        } else {
            self.openDuration = 0.180
            self.bubbleCascadeStagger = 0.010
            self.recentsSlideDuration = 0.140
            self.openStartScale = 0.94
            self.openStartOpacity = 0.0
        }
    }

    public static let locked = CommandBridgeAnimation()
    public static let reduced = CommandBridgeAnimation(reduceMotion: true)
}

// ============================================================
// MARK: - 4. CommandBridgePresentationState
//
//   Pure state machine for the popup. The view observes this; the
//   controller is the sole writer. The four cases mirror the open/closed
//   lifecycle the brief specifies (closed → opening → open → closing).
//   The "secondary panel" (recents / search results) is orthogonal to
//   the lifecycle and tracked by `panelMode`.
// ============================================================

public enum CommandBridgeLifecycle: Sendable, Equatable {
    case closed, opening, open, closing
}

public enum CommandBridgePanelMode: Sendable, Equatable {
    /// Tray + pill only; no secondary panel visible.
    case none
    /// Recents slide-in (opened by ↓).
    case recents
    /// Search-results slide-in (typing).
    case search(query: String)
}

// ============================================================
// MARK: - 5. CommandBridgeController
//
//   AppKit/SwiftUI glue:
//     • Owns the Carbon hot-key registration (reused verbatim from the
//       legacy controller — see PERMISSION MODEL note below).
//     • Owns the borderless NSPanel and the SwiftUI host inside it.
//     • Owns the lifecycle state machine (closed → opening → open →
//       closing) and the secondary panel mode (none / recents / search).
//     • On commit: writes the resolved command body to the system
//       pasteboard via the `ClipboardWriting` seam and closes.
//
//   PERMISSION MODEL (v3.7.6 — paste-back ADDED): Carbon
//   `RegisterEventHotKey` is still a HOT-KEY REGISTRATION, not an event
//   tap — no Input Monitoring grant. NSPasteboard write still needs no
//   TCC grant and stays UNCONDITIONAL on every commit. What is NEW: after
//   the clipboard write, the fire path optionally synthesizes ⌘V into the
//   previously-frontmost app via CGEvent (mirroring `CGEventModule.postKey`).
//   That single synthesis is GATED on `AXIsProcessTrusted()`; when the
//   Accessibility grant is absent we skip the keystroke entirely (the
//   clipboard already holds the body — a graceful manual-paste fallback)
//   and surface the system grant prompt once. The pure `applyCommit`
//   primitive is unchanged (clipboard-only) so its headless contract
//   stays byte-for-byte; paste-back lives on `fireSlot` / `fireSlug`.
// ============================================================

@MainActor
public final class CommandBridgeController: NSObject {

    // MARK: Constants

    /// Pill width (matches the design mock's --pill-w: 640px).
    public static let pillWidth: CGFloat = 640
    /// Hosting panel size — wide enough for the 10-slot tray + pill +
    /// the secondary slide-in panel. v3.7.6: the height was dropped from the
    /// legacy 460 to 360 so the transparent envelope HUGS the bar + favorites
    /// instead of leaving a tall empty box around them. The SwiftUI content is
    /// TOP-anchored inside this envelope (see `CommandBridgeRootView.body`) so
    /// any slack sits below the bar as fully-transparent space that never
    /// paints — only the tray + pill (+ optional results panel) draw.
    public static let panelSize = NSSize(width: 640, height: 360)

    // MARK: Stored state

    private var hotkey: HotkeyConfig
    private let clipboard: ClipboardWriting
    private let coordinator: CommandPaletteCoordinator
    private let store: CommandStore
    private let recents: CommandBridgeRecents

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var panel: CommandBridgePanel?
    private var hostingController: NSHostingController<CommandBridgeRootView>?
    private var model: CommandBridgeViewModel?
    private var focusLossObserver: Any?
    /// (v3.7.6) Becomes-key observer — focuses the query field every time the
    /// reused panel becomes the key window (so typing lands immediately).
    private var becomeKeyObserver: Any?
    /// (v3.7.6) Global mouse-down monitor installed while the palette is open.
    /// Fires on a click OUTSIDE the panel and dismisses (Spotlight behaviour).
    private var globalClickMonitor: Any?

    /// (v3.7.6) The app that was frontmost the instant before we showed, so
    /// paste-into-app can re-activate it and synthesize ⌘V. Captured in
    /// `show()` BEFORE `orderFrontRegardless()`.
    private var priorApp: NSRunningApplication?

    /// (v3.7.6) Presents the standalone Dashboard popover anchored off the
    /// bar's leading bridge-mark. Injected by the App layer (it owns the
    /// `StatusBarController` / `PermissionManager` the dashboard needs); `nil`
    /// in tests / shells that don't wire it. Returns whether it presented.
    public var presentDashboard: (() -> Void)?

    /// (v3.7.6) Whether paste-into-app is enabled. Default ON per the brief.
    /// The clipboard write is ALWAYS performed regardless of this flag; this
    /// only governs the post-write ⌘V synthesis.
    public var pasteIntoAppEnabled: Bool = true

    public private(set) var isRegistered = false
    public private(set) var lastRegisterStatus: HotkeyRegisterStatus = .unattempted
    public private(set) var lifecycle: CommandBridgeLifecycle = .closed

    public var hotkeyConfig: HotkeyConfig { hotkey }
    public var isVisible: Bool { lifecycle == .open || lifecycle == .opening }

    // MARK: Init

    public init(hotkey: HotkeyConfig = .productionDefault,
                clipboard: ClipboardWriting = SystemClipboard(),
                coordinator: CommandPaletteCoordinator,
                store: CommandStore = .shared,
                recents: CommandBridgeRecents = .shared) {
        self.hotkey = hotkey
        self.clipboard = clipboard
        self.coordinator = coordinator
        self.store = store
        self.recents = recents
        super.init()
    }

    /// Convenience for tests / shells that don't pass a hotkey.
    public convenience init(clipboard: ClipboardWriting,
                            coordinator: CommandPaletteCoordinator) {
        self.init(hotkey: .productionDefault,
                  clipboard: clipboard,
                  coordinator: coordinator)
    }

    // MARK: - Pure placement (multi-monitor) — unit-tested headlessly

    /// Panel origin for a given target screen visible-frame + panel size.
    /// PKT-878 Q2: the panel CENTRE sits 25% up from the bottom of the
    /// visible frame, horizontally centred. Pure so the math is asserted
    /// without a WindowServer.
    public nonisolated static func placementOrigin(
        screenVisibleFrame f: CGRect,
        panelSize size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: f.midX - size.width / 2,
            y: f.minY + f.height * 0.25 - size.height / 2
        )
    }

    /// Pick the screen the panel should open on: the one containing the
    /// key window, else the one under the mouse, else `NSScreen.main`,
    /// else the first screen. Pure given the inputs.
    public nonisolated static func pickScreenFrame(
        screens: [CGRect],
        keyWindowFrame: CGRect?,
        mouseLocation: CGPoint,
        mainScreenFrame: CGRect?
    ) -> CGRect? {
        if let kw = keyWindowFrame {
            let centre = CGPoint(x: kw.midX, y: kw.midY)
            if let hit = screens.first(where: { $0.contains(centre) }) { return hit }
        }
        if let hit = screens.first(where: { $0.contains(mouseLocation) }) { return hit }
        if let main = mainScreenFrame { return main }
        return screens.first
    }

    // MARK: - Hot-key registration (Carbon — no Input Monitoring)
    //
    //   Reused verbatim in semantics from `CommandBoxController.registerHotkey`.
    //   The Carbon callback trampolines back to `handleHotkey()` on the
    //   main actor; the `HotkeyConfig.signature` ('NBcb') is unchanged.

    @discardableResult
    public func registerHotkey() -> Bool {
        guard hotkey.hasModifier else {
            print("[CommandBridge] refusing modifier-less hot-key")
            lastRegisterStatus = .plumbingFailure(osStatus: Int32(paramErr))
            return false
        }
        guard !isRegistered else {
            lastRegisterStatus = .registered
            return true
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                if err == noErr, hkID.signature == HotkeyConfig.signature {
                    let ctrl = Unmanaged<CommandBridgeController>
                        .fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in ctrl.handleHotkey() }
                }
                return noErr
            },
            1, &spec, selfPtr, &eventHandler
        )
        guard installStatus == noErr else {
            print("[CommandBridge] InstallEventHandler failed: \(installStatus)")
            lastRegisterStatus = .plumbingFailure(osStatus: Int32(installStatus))
            return false
        }

        let hkID = EventHotKeyID(signature: HotkeyConfig.signature, id: 1)
        let regStatus = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, hkID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard regStatus == noErr else {
            print("[CommandBridge] RegisterEventHotKey failed: \(regStatus) (combo likely taken)")
            if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
            lastRegisterStatus = .collision(osStatus: Int32(regStatus))
            return false
        }

        isRegistered = true
        lastRegisterStatus = .registered
        print("[CommandBridge] registered global hot-key \(hotkey.displayString) (Carbon — no Input Monitoring)")
        return true
    }

    public func unregisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        isRegistered = false
        lastRegisterStatus = .unattempted
    }

    @discardableResult
    public func rebind(to newHotkey: HotkeyConfig) -> Bool {
        let previous = hotkey
        unregisterHotkey()
        hotkey = newHotkey
        if registerHotkey() { return true }
        let failureOfNewCombo = lastRegisterStatus
        hotkey = previous
        _ = registerHotkey()
        lastRegisterStatus = failureOfNewCombo
        return false
    }

    // MARK: - Lifecycle transitions

    private func handleHotkey() {
        switch lifecycle {
        case .closed, .closing: show()
        case .open, .opening:   hide()
        }
    }

    private func show() {
        // (v3.7.6) Capture the frontmost app BEFORE we order the panel front,
        // so paste-into-app can re-activate it on commit. The panel is a
        // `.nonactivatingPanel`, so the prior app normally stays frontmost —
        // but we record it explicitly to be robust across Spaces / ⌘-Tab.
        let me = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        priorApp = (front?.processIdentifier == me.processIdentifier) ? nil : front

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Multi-monitor (P2.8): the screen-pick + origin math is the
        // PURE, unit-tested `pickScreenFrame` / `placementOrigin`; this
        // is only the glue.
        let screenFrames = NSScreen.screens.map { $0.visibleFrame }
        if let target = Self.pickScreenFrame(
            screens: screenFrames,
            keyWindowFrame: NSApp.keyWindow?.frame,
            mouseLocation: NSEvent.mouseLocation,
            mainScreenFrame: NSScreen.main?.visibleFrame
        ) {
            panel.setFrameOrigin(
                Self.placementOrigin(screenVisibleFrame: target,
                                     panelSize: panel.frame.size)
            )
        }

        lifecycle = .opening
        // Re-seed the model from the live store so a freshly-edited
        // command shows immediately. Failures fall back to empty.
        model?.reload()
        model?.queryDidChange("")

        // (v3.7.6) Make the panel KEY (not just ordered front) so the hosted
        // query field can take first responder and the user types immediately.
        // We intentionally DO NOT grab `panel.contentView` as first responder
        // any more — that competed with the SwiftUI `@FocusState` field and
        // left the bar unfocused. `makeKeyAndOrderFront` lets the field win.
        panel.makeKeyAndOrderFront(nil)
        installFocusLossObserver()
        installBecomeKeyObserver()
        installGlobalClickMonitor()
        // Re-assert field focus on EVERY show() — the panel is reused, so the
        // SwiftUI `.onAppear` only fires the first time. Nudging the model's
        // focus token + asking the view-model to reset to the tray makes the
        // field claim first responder again on subsequent opens.
        focusQueryField()

        // The 180ms ease-out is driven inside the SwiftUI view (its
        // root applies the scale+opacity transition); the controller
        // simply moves the lifecycle to .open after a coalesced tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self else { return }
            if self.lifecycle == .opening {
                self.lifecycle = .open
                self.model?.didOpen = true
            }
        }
    }

    /// Public entrypoint mirroring the legacy `dismissOnEscape()` —
    /// closes the popup without writing anything.
    public func hide() {
        guard lifecycle == .open || lifecycle == .opening else { return }
        lifecycle = .closing
        removeFocusLossObserver()
        removeBecomeKeyObserver()
        removeGlobalClickMonitor()
        model?.didOpen = false
        panel?.orderOut(nil)
        lifecycle = .closed
    }

    // MARK: - Focus loss

    private func installFocusLossObserver() {
        removeFocusLossObserver()
        // Esc/focus-loss closes — we observe the panel losing key
        // status, which fires when the user clicks outside or switches
        // app via ⌘-Tab. The SwiftUI view also handles Esc directly.
        focusLossObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeFocusLossObserver() {
        if let obs = focusLossObserver {
            NotificationCenter.default.removeObserver(obs)
            focusLossObserver = nil
        }
    }

    // MARK: - Auto-focus (v3.7.6)

    /// Focus the query field whenever the (reused) panel becomes key. The
    /// SwiftUI `.onAppear` only fires the first time the view is mounted; the
    /// panel is reused across opens, so this re-asserts focus on every show().
    private func installBecomeKeyObserver() {
        removeBecomeKeyObserver()
        becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.focusQueryField() }
        }
    }

    private func removeBecomeKeyObserver() {
        if let obs = becomeKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            becomeKeyObserver = nil
        }
    }

    /// Ask the SwiftUI view to claim first responder on the query field. The
    /// view binds its `@FocusState` to `model.focusToken`; bumping the token
    /// drives `QueryField.updateNSView` → `makeFirstResponder`.
    private func focusQueryField() {
        model?.requestFieldFocus()
    }

    // MARK: - Click-outside-to-dismiss (v3.7.6)

    /// While the palette is open, a click ANYWHERE outside the panel dismisses
    /// it (the Spotlight/Alfred pattern). A GLOBAL monitor sees clicks in OTHER
    /// apps; clicks inside our own panel are LOCAL events the global monitor
    /// never receives, so no extra hit-test is required. `didResignKey` already
    /// covers ⌘-Tab / clicking another app's window that takes key; this adds
    /// the "clicked the desktop / a non-activating spot" case.
    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeGlobalClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    // MARK: - Commit (number key / Enter / row click)
    //
    //   Three commit shapes, all routing through the single
    //   `applyCommit(.paste(body))` write so the clipboard contract is
    //   one-line-tested.

    /// Fire the favorite assigned to slot `slot` (0…9). If the slot is
    /// empty this is a no-op (no clipboard clobber, panel stays open).
    public func fireSlot(_ slot: Int) {
        guard let cmd = (try? store.command(forKeySlot: slot)) ?? nil else { return }
        commitBody(cmd.body, slug: cmd.slug)
    }

    /// Fire the command whose slug matches `slug` (used by Enter on a
    /// selected row + by the row click handler).
    public func fireSlug(_ slug: String) {
        guard let cmd = (try? store.get(slug: slug)) ?? nil else { return }
        commitBody(cmd.body, slug: cmd.slug)
    }

    /// (v3.7.6) Shared fire path for `fireSlot` / `fireSlug`. Writes the body
    /// to the clipboard (UNCONDITIONAL — same `applyCommit` primitive the
    /// headless test pins), records the use, closes the panel, then optionally
    /// pastes into the previously-frontmost app. The clipboard half is
    /// unchanged from the prior two call sites; only the paste-back tail is new.
    private func commitBody(_ body: String, slug: String) {
        applyCommit(.paste(body))              // unconditional clipboard write
        try? store.recordUse(slug: slug)
        recents.record(slug)
        let target = priorApp                  // snapshot the target before we close
        hide()
        if pasteIntoAppEnabled, !body.isEmpty {
            pasteIntoPriorApp(target)
        }
    }

    // MARK: - Paste-into-app (v3.7.6 — CGEvent ⌘V, AX-gated)

    /// Re-activate the previously-frontmost app and synthesize ⌘V so the just-
    /// copied body lands in its focused field. GATED on `AXIsProcessTrusted()`:
    ///   • No prior app, or the prior app IS us → skip (nothing to paste into).
    ///   • Not AX-trusted → skip the keystroke (clipboard already holds the
    ///     body, so manual ⌘V is the graceful fallback) and surface the system
    ///     grant prompt ONCE via `AXIsProcessTrustedWithOptions(prompt:true)`.
    ///   • Trusted → activate the target, then after ~100ms post a ⌘V key
    ///     press through `.cghidEventTap` (mirrors `CGEventModule.postKey`).
    /// Secure text fields silently swallow synthetic paste — that degrades to
    /// the clipboard fallback, which is acceptable.
    private func pasteIntoPriorApp(_ target: NSRunningApplication?) {
        guard let target else { return }
        let me = NSRunningApplication.current
        guard target.processIdentifier != me.processIdentifier else { return }

        guard AXIsProcessTrusted() else {
            // Not trusted — clipboard fallback stands; nudge the one-time grant
            // prompt so the user can enable real paste-back next time. The
            // option key is the string literal "AXTrustedCheckOptionPrompt" (not
            // the `kAXTrustedCheckOptionPrompt` global, which Swift 6 strict
            // concurrency flags as shared-mutable — same workaround as
            // PermissionManager.requestAccessibilityAccess()).
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
            return
        }

        // Re-activate the target so the keystroke is routed to its key window.
        target.activate(options: [])

        // Let the activation settle, then post ⌘V. ~100ms mirrors the brief.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            Self.postCommandV()
        }
    }

    /// Synthesize a ⌘V key press via CGEvent. Mirrors `CGEventModule.postKey`:
    /// `.hidSystemState` source, `kVK_ANSI_V` virtual key, `.maskCommand`
    /// flag, posted to `.cghidEventTap`. Static + side-effect-only.
    private nonisolated static func postCommandV() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
            let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Clipboard-only commit: on `.paste(body)` write the resolved body
    /// to the clipboard (replace contents — no save/restore). On
    /// `.notFound` / `.unavailable` write nothing. Same shape as the
    /// legacy `CommandBoxController.applyCommit` so the headless
    /// `applyCommit(.paste / .notFound / .unavailable)` test contract is
    /// preserved byte-for-byte.
    public func applyCommit(_ result: CommandPaletteCommitResult) {
        switch result {
        case .paste(let body):
            guard !body.isEmpty else { return }
            clipboard.writeString(body)
        case .notFound:
            break
        case .unavailable(_, let reason):
            print("[CommandBridge] command body unavailable: \(reason)")
        }
    }

    // MARK: - Panel construction

    private func makePanel() -> CommandBridgePanel {
        let panel = CommandBridgePanel(size: Self.panelSize)

        let model = CommandBridgeViewModel(store: store, recents: recents)
        model.onFireSlot = { [weak self] slot in self?.fireSlot(slot) }
        model.onFireSlug = { [weak self] slug in self?.fireSlug(slug) }
        model.onEscape   = { [weak self] in self?.hide() }
        model.onSettings = { [weak self] in self?.openCommandsSettings() }
        // (v3.7.6) Leading bridge-mark → present the Dashboard popover. We hide
        // the palette first so the two surfaces don't overlap, then hand off to
        // the App-layer presenter (which owns the StatusBar / PermissionManager).
        model.onBridgeMark = { [weak self] in self?.openDashboard() }
        self.model = model

        let root = CommandBridgeRootView(model: model)
        let host = NSHostingController(rootView: root)
        host.view.frame = NSRect(origin: .zero, size: Self.panelSize)
        // Transparent host — the BridgeGlass surfaces draw the backing.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host.view
        self.hostingController = host
        return panel
    }

    // MARK: - Settings deep-link

    /// Menu-bar ⌘ chip → SettingsNavigation to Commands. Public so the
    /// SwiftUI button can invoke without touching the AppDelegate.
    public func openCommandsSettings() {
        SettingsNavigation.shared.go(.commands)
        if let app = NSApp.delegate as? AppDelegate {
            app.openSettings(section: .commands)
        }
        hide()
    }

    /// (v3.7.6) Leading bridge-mark → standalone Dashboard popover. Closes the
    /// palette, then defers to the App-layer presenter (set via
    /// `presentDashboard`). No-op when no presenter is wired (tests / shells).
    public func openDashboard() {
        hide()
        guard let present = presentDashboard else { return }
        // Defer one tick so the palette's orderOut completes before the popover
        // is anchored (avoids a flash of both surfaces).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
            present()
        }
    }
}

// ============================================================
// MARK: - 6. CommandBridgeViewModel
//
//   The view's observable state. The controller is the only writer of
//   `onFire*` / `onEscape` / `onSettings`; the view binds to
//   `panelMode`, `slotRows`, `recentRows`, `searchRows`, `didOpen`.
//   `reload()` re-reads the store; `queryDidChange(_:)` updates the
//   panelMode + filtered rows.
// ============================================================

@MainActor
public final class CommandBridgeViewModel: ObservableObject {
    @Published public var didOpen: Bool = false
    @Published public var panelMode: CommandBridgePanelMode = .none
    @Published public var query: String = ""
    @Published public var slotRows: [SlotRow] = []
    @Published public var recentRows: [Row] = []
    @Published public var searchRows: [Row] = []
    /// (v3.7.6) Monotonic focus token. The controller bumps this on EVERY
    /// show() (the panel is reused, so `.onAppear` only fires once); the view
    /// observes it and re-claims first responder on the query field.
    @Published public var focusToken: Int = 0

    /// `keySlot` is 1…0 (display order). `command` is nil when the slot
    /// is unassigned (the bubble renders as a transparent placeholder).
    public struct SlotRow: Identifiable, Equatable {
        public let displayKey: Int   // 1…9 then 0 (the keycap label)
        public let storeSlot: Int    // 0…9 (the CommandStore key)
        public let command: CommandStore.Command?
        public var id: Int { displayKey }
    }

    public struct Row: Identifiable, Equatable {
        public let slug: String
        public let name: String
        public let icon: CommandStore.Icon
        public let color: CommandStore.NotionColor?
        public let lastUsedAt: Date?
        public let keySlot: Int?
        public var id: String { slug }
    }

    public var onFireSlot: (Int) -> Void = { _ in }
    public var onFireSlug: (String) -> Void = { _ in }
    public var onEscape: () -> Void = {}
    public var onSettings: () -> Void = {}
    /// (v3.7.6) Leading bridge-mark tap → open the Dashboard popover.
    public var onBridgeMark: () -> Void = {}

    private let store: CommandStore
    private let recents: CommandBridgeRecents

    public init(store: CommandStore, recents: CommandBridgeRecents) {
        self.store = store
        self.recents = recents
        reload()
    }

    /// (v3.7.6) Controller-driven re-focus. Bumps `focusToken` so the SwiftUI
    /// view re-asserts first responder on the query field on every show().
    public func requestFieldFocus() {
        focusToken &+= 1
    }

    /// Re-read the store + recompute tray rows. Called when the panel
    /// shows so a Settings-side edit is reflected immediately.
    public func reload() {
        let all = (try? store.list()) ?? []
        self.slotRows = Self.buildSlotRows(from: all)
        self.recentRows = Self.buildRecentRows(from: all, order: recents.ordered)
    }

    /// Search-as-you-type. Empty query → panelMode = .none and rows
    /// hidden. Non-empty → substring match on name, ranked by recency.
    public func queryDidChange(_ q: String) {
        self.query = q
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // typing-stopped path collapses back to whichever secondary
            // panel was last open (recents stays open if it was open).
            if case .search = panelMode { panelMode = .none }
            searchRows = []
            return
        }
        let hits = (try? store.search(trimmed)) ?? []
        searchRows = hits.map(Self.row(from:))
        panelMode = .search(query: trimmed)
    }

    /// ↓ → open recents (140ms slide-in handled by the view).
    public func openRecents() {
        if recentRows.isEmpty { return }
        panelMode = .recents
    }

    /// Esc / focus-loss / fire → reset to closed-tray state.
    public func resetToTray() {
        query = ""
        searchRows = []
        panelMode = .none
    }

    // MARK: Pure builders (unit-tested)

    /// Build the 10-slot tray. Display order is 1,2,3,4,5,6,7,8,9,0
    /// — matching the locked design — but the CommandStore key slot is
    /// the integer key (1→1, 9→9, 0→0). Unassigned slots render as a
    /// transparent placeholder so the keycap row stays evenly spaced.
    public nonisolated static func buildSlotRows(
        from all: [CommandStore.Command]
    ) -> [SlotRow] {
        let displayOrder: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
        return displayOrder.map { d in
            let cmd = all.first(where: { $0.keySlot == d })
            return SlotRow(displayKey: d, storeSlot: d, command: cmd)
        }
    }

    /// Build the recents list from the session log. Slug order wins
    /// (most-recently-fired first); a slug that no longer exists in the
    /// store is dropped silently.
    public nonisolated static func buildRecentRows(
        from all: [CommandStore.Command],
        order: [String]
    ) -> [Row] {
        var byslug: [String: CommandStore.Command] = [:]
        for c in all { byslug[c.slug] = c }
        return order.compactMap { slug in
            guard let c = byslug[slug] else { return nil }
            return row(from: c)
        }
    }

    public nonisolated static func row(from c: CommandStore.Command) -> Row {
        Row(slug: c.slug, name: c.name, icon: c.icon, color: c.color,
            lastUsedAt: c.lastUsedAt, keySlot: c.keySlot)
    }
}

// ============================================================
// MARK: - 7. CommandBridgeRootView (SwiftUI)
//
//   The locked Liquid Glass surface. Three stacked layers:
//     • tray (10 BridgeGlassBubble slots)
//     • pill (lead icon + query field + ⌘ chip)
//     • optional panel (recents OR search results)
// ============================================================

public struct CommandBridgeRootView: View {
    @ObservedObject var model: CommandBridgeViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    // v3.7.6 system-tethered: the pill/panel sheen must adapt — a raw white
    // sheen over the heavier tint would wash out on the titanium (light)
    // canvas. DARK keeps the locked white sheen; LIGHT mirrors it dark.
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @FocusState private var queryFocused: Bool

    private var anim: CommandBridgeAnimation {
        reduceMotion ? .reduced : .locked
    }

    /// Adaptive sheen stops for the glass pill / results panel. DARK keeps the
    /// brief's white values; LIGHT uses a faint dark gradient so the surface
    /// still reads as raised glass on #ECEDEF without blowing out to white.
    private func sheenTop(_ darkAlpha: Double) -> Color {
        colorScheme == .dark ? Color.white.opacity(darkAlpha)
                             : Color.black.opacity(darkAlpha * 0.45)
    }
    private func sheenBottom(_ darkAlpha: Double) -> Color {
        colorScheme == .dark ? Color.white.opacity(darkAlpha)
                             : Color.black.opacity(darkAlpha * 0.20)
    }

    public init(model: CommandBridgeViewModel) {
        self.model = model
    }

    public var body: some View {
        // v3.7.6 transparency: TOP-anchor the content so only the tray + pill
        // (+ optional results panel) paint near the top of the envelope and the
        // unused height falls below as fully-transparent space. Combined with
        // the shrunken `panelSize` height + the cut pill shadow, the palette no
        // longer reads as a dark square halo — transparency HUGS the bar.
        ZStack(alignment: .top) {
            // Clear backing — BridgeGlass surfaces draw their own
            // background. Lets the panel's NSWindow shape through.
            Color.clear
            VStack(spacing: 8) {
                tray
                pill
                if case .none = model.panelMode {
                    EmptyView()
                } else {
                    secondaryPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 0)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .scaleEffect(model.didOpen ? 1.0 : anim.openStartScale)
            .opacity(model.didOpen ? 1.0 : anim.openStartOpacity)
            .animation(.easeOut(duration: anim.openDuration), value: model.didOpen)
            .animation(.easeOut(duration: anim.recentsSlideDuration), value: panelModeKey)
        }
        .frame(width: CommandBridgeController.pillWidth + 24,
               height: CommandBridgeController.panelSize.height,
               alignment: .top)
        .background(KeyHandler(
            onNumber: { n in model.onFireSlot(n) },
            onArrowDown: { model.openRecents() },
            onReturn: { commitTopSelection() },
            onEscape: { model.onEscape() }
        ))
        .onAppear { queryFocused = true }
        // Re-assert field focus whenever the controller bumps the token (the
        // panel is reused, so `.onAppear` fires only once across opens).
        .onChange(of: model.focusToken) { _, _ in queryFocused = true }
    }

    private var panelModeKey: String {
        switch model.panelMode {
        case .none:                return "none"
        case .recents:             return "recents"
        case .search(let q):       return "search:\(q)"
        }
    }

    // MARK: Tray

    private var tray: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.slotRows.enumerated()), id: \.element.id) { idx, row in
                slotView(row, cascadeIndex: idx)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: CommandBridgeController.pillWidth)
    }

    @ViewBuilder
    private func slotView(_ row: CommandBridgeViewModel.SlotRow, cascadeIndex: Int) -> some View {
        VStack(spacing: 6) {
            if let cmd = row.command {
                Button { model.onFireSlot(row.storeSlot) } label: {
                    BridgeGlassBubble(size: 52) {
                        iconView(for: cmd.icon, color: cmd.color, size: 22)
                    }
                }
                .buttonStyle(.plain)
                Text("\(row.displayKey)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BridgeTokens.fg4)
                    .monospacedDigit()
            } else {
                // Position-stable transparent placeholder (per locked design).
                BridgeGlassBubble(size: 52) { EmptyView() }
                    .opacity(0)
                Text("\(row.displayKey)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.clear)
                    .monospacedDigit()
            }
        }
        // Bubble cascade — 10ms stagger per slot from the locked spec.
        .opacity(model.didOpen ? 1.0 : 0.0)
        .animation(
            .easeOut(duration: anim.openDuration)
            .delay(Double(cascadeIndex) * anim.bubbleCascadeStagger),
            value: model.didOpen
        )
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: 14) {
            // v3.7.6: the LEADING glyph is now the clickable bridge-mark →
            // opens the standalone Dashboard popover. Falls back to an SF
            // Symbol when the asset can't be loaded (e.g. headless / Lib bundle).
            Button {
                model.onBridgeMark()
            } label: {
                bridgeMark
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Open Bridge dashboard")
            QueryField(
                text: Binding(
                    get: { model.query },
                    set: { model.queryDidChange($0) }
                ),
                placeholder: "Bridge Command",
                isFocused: $queryFocused,
                onReturn: { commitTopSelection() },
                onArrowDown: { model.openRecents() },
                onEscape: { model.onEscape() }
            )
            .frame(maxWidth: .infinity)
            Button {
                model.onSettings()
            } label: {
                Text("⌘")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(BridgeTokens.fg5)
            }
            .buttonStyle(.plain)
            .help("Open Commands settings")
        }
        .padding(.horizontal, 20)
        .frame(width: CommandBridgeController.pillWidth, height: 66)
        .background(
            ZStack {
                // v3.7.6 legibility: tint 0.34→0.62 + top sheen 0.14→0.22 so
                // ONLY the bar paints — and reads as solid glass on a now-
                // transparent envelope (no square halo to lean on).
                BridgeTokens.glassWindowTint.opacity(0.62)
                LinearGradient(
                    colors: [sheenTop(0.22), sheenBottom(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)
        )
        // v3.7.6: shadow cut from .black@0.55 / r30 / y18 (which read as a dark
        // square halo around the transparent panel) to a soft contact shadow.
        .shadow(color: .black.opacity(0.30), radius: 16, y: 10)
    }

    /// The leading bridge-mark glyph. Loads `MenuBarIcon` from the app bundle
    /// (template-rendered so it tints with the adaptive foreground), and falls
    /// back to the prior `command.circle` SF Symbol when the asset is absent.
    @ViewBuilder
    private var bridgeMark: some View {
        if let icon = Self.bridgeMarkImage {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(BridgeTokens.fg2)
        } else {
            Image(systemName: "command.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(BridgeTokens.fg3)
        }
    }

    /// `MenuBarIcon` lives in the executable's resource bundle (it is excluded
    /// from `NotionBridgeLib`, where this view compiles). At runtime the
    /// packaged `.app` deposits it in the main bundle's Resources + Assets.car,
    /// so `Bundle.main` resolves it; `NSImage(named:)` is the final fallback.
    /// Loaded once and cached. `nil` headlessly → the SF Symbol fallback shows.
    private static let bridgeMarkImage: NSImage? = {
        let img = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(named: "MenuBarIcon")
        img?.isTemplate = true
        return img
    }()

    // MARK: Secondary panel (recents / search)

    @ViewBuilder
    private var secondaryPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.panelMode {
            case .none:
                EmptyView()
            case .recents:
                panelHeader("Recently used")
                ForEach(model.recentRows) { r in
                    rowView(r, selected: r.id == model.recentRows.first?.id)
                }
                if model.recentRows.isEmpty {
                    panelEmptyHint("No recents yet — fire a command to start the history.")
                }
            case .search(let q):
                panelHeader("Matches — sorted by recency")
                ForEach(model.searchRows) { r in
                    rowView(r, selected: r.id == model.searchRows.first?.id, highlight: q)
                }
                if model.searchRows.isEmpty {
                    panelEmptyHint("No match for \"\(q)\".")
                }
            }
        }
        .padding(7)
        .frame(width: CommandBridgeController.pillWidth)
        .background(
            ZStack {
                // v3.7.6 legibility: results-panel tint 0.32→0.58 to match the
                // more-opaque pill now that the envelope is transparent.
                BridgeTokens.glassWindowTint.opacity(0.58)
                LinearGradient(
                    colors: [sheenTop(0.12), sheenBottom(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(BridgeTokens.hairlineStrong, lineWidth: 0.5)
        )
    }

    private func panelHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(BridgeTokens.fg5)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    private func panelEmptyHint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(BridgeTokens.fg4)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowView(_ r: CommandBridgeViewModel.Row,
                         selected: Bool,
                         highlight: String = "") -> some View {
        Button {
            model.onFireSlug(r.slug)
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(BridgeTokens.chipFill)
                    iconView(for: r.icon, color: r.color, size: 15)
                }
                .frame(width: 26, height: 26)
                highlightedName(r.name, query: highlight)
                    .font(.system(size: 15))
                    .foregroundStyle(BridgeTokens.fg1)
                Spacer(minLength: 4)
                Text(Self.relativeHint(for: r.lastUsedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(BridgeTokens.fg5)
                if let slot = r.keySlot {
                    Text("\(slot)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(BridgeTokens.chipFill)
                        )
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected
                          ? BridgeTokens.accent.opacity(0.18)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func highlightedName(_ name: String, query: String) -> some View {
        let q = query.lowercased()
        if !q.isEmpty,
           let range = name.lowercased().range(of: q) {
            let lower = String(name[..<range.lowerBound])
            let mid = String(name[range])
            let upper = String(name[range.upperBound...])
            (
                Text(lower)
                + Text(mid).bold().foregroundColor(BridgeTokens.fg1)
                + Text(upper)
            )
        } else {
            Text(name)
        }
    }

    @ViewBuilder
    private func iconView(for icon: CommandStore.Icon,
                          color: CommandStore.NotionColor?,
                          size: CGFloat) -> some View {
        switch icon {
        case .emoji(let s):
            Text(s).font(.system(size: size))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(
                    color.flatMap { NotionPalette.color(named: $0.rawValue) }
                    ?? BridgeTokens.fg2
                )
        }
    }

    /// "2m ago" / "yesterday" / "" hint shown in result rows.
    static func relativeHint(for date: Date?) -> String {
        guard let date else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        if interval < 2 * 86_400 { return "yesterday" }
        return "\(Int(interval / 86_400))d ago"
    }

    private func commitTopSelection() {
        switch model.panelMode {
        case .search:
            if let top = model.searchRows.first { model.onFireSlug(top.slug) }
        case .recents:
            if let top = model.recentRows.first { model.onFireSlug(top.slug) }
        case .none:
            // No selection → Enter is a no-op (matches Spotlight / cmd-sb).
            return
        }
    }
}

// ============================================================
// MARK: - 8. QueryField — plain NSTextField bridge with key hooks
// ============================================================

private struct QueryField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    var onReturn: () -> Void
    var onArrowDown: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = BridgeQueryTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 25, weight: .light)
        // v3.7.6: adaptive ink — the query text follows the system appearance
        // (white on carbon, dark on titanium) instead of a hardcoded white that
        // would vanish on the light canvas. Mirrors BridgeTokens.fg1.
        field.textColor = BridgeTokens.adaptiveNSColor(
            dark:  { BridgeTokens.whiteAlpha(0.95) },
            light: { BridgeTokens.blackAlpha(0.92) }
        )
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.bezelStyle = .squareBezel
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.onArrowDown = { onArrowDown() }
        field.onEscape    = { onEscape() }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if isFocused.wrappedValue {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QueryField
        init(_ parent: QueryField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape(); return true
            default:
                return false
            }
        }
    }
}

/// A text field that hooks ↓/Esc directly so the model can react even
/// when the field editor would normally swallow them.
private final class BridgeQueryTextField: NSTextField {
    var onArrowDown: (() -> Void)?
    var onEscape: (() -> Void)?
}

// ============================================================
// MARK: - 9. KeyHandler — captures 1–0 + ↓ + Esc at the root level
// ============================================================

/// A transparent NSView that monitors key-down events to fire number
/// keys 1–0 and propagate ↓/Esc when the text field is empty. Mounted
/// behind the SwiftUI hierarchy so it sees keystrokes the field doesn't
/// consume (the field handles arrow/return/escape itself via its
/// delegate — see `QueryField.Coordinator`).
private struct KeyHandler: NSViewRepresentable {
    let onNumber: (Int) -> Void
    let onArrowDown: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onNumber = onNumber
        v.onArrowDown = onArrowDown
        v.onReturn = onReturn
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MonitorView: NSView {
        var onNumber: ((Int) -> Void)?
        var onArrowDown: (() -> Void)?
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Only act when our window is key.
                guard self.window?.isKeyWindow == true else { return event }
                // If the focused first responder is the query text view
                // (i.e. the user is typing), let it have the keystroke
                // EXCEPT for the bare-number/bare-arrow shortcuts when
                // the field is empty.
                let isFieldEditor = (self.window?.firstResponder is NSText)
                if !isFieldEditor || (event.charactersIgnoringModifiers?.isEmpty ?? true) {
                    if Self.consume(event, fire: self) { return nil }
                } else if let text = self.window?.firstResponder as? NSText,
                          text.string.isEmpty {
                    // Empty field → bare number keys still fire the slot.
                    if Self.consume(event, fire: self) { return nil }
                }
                return event
            }
        }

        private func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            // The local monitor is removed in `viewDidMoveToWindow` when
            // the view leaves the window, which happens before deinit
            // for a panel-hosted view. We intentionally do NOT touch
            // `monitor` here — under Swift 6 strict concurrency a
            // `nonisolated deinit` cannot read a non-Sendable property,
            // and the cleanup path above is sufficient (the monitor is
            // bound to a window-scoped block that no longer reaches a
            // dead view).
        }

        /// Returns true if the event was handled (swallowed).
        static func consume(_ event: NSEvent, fire v: MonitorView) -> Bool {
            // Modifier-bearing keys are never our number shortcuts —
            // let the field handle ⌘A, ⌘V, etc.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
                return false
            }
            if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
                let c = chars.first!
                if let digit = c.wholeNumberValue, (0...9).contains(digit) {
                    v.onNumber?(digit)
                    return true
                }
            }
            switch event.keyCode {
            case UInt16(kVK_DownArrow):
                v.onArrowDown?(); return true
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                v.onReturn?(); return true
            case UInt16(kVK_Escape):
                v.onEscape?(); return true
            default:
                return false
            }
        }
    }
}
