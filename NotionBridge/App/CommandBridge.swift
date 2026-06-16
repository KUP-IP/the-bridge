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
//     Settings → Orders/Commands via
//     `SettingsNavigation.shared.go(.orders, anchor: "commands")`.
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
        // (v4 round-3) Drag is handled by a SwiftUI gesture in the hosted view —
        // isMovableByWindowBackground does NOT engage an NSHostingView (verified
        // on-device: the bar wouldn't move). The controller's didMove observer
        // still records the dragged origin for the session + resets on boot.
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
    /// (v4 round-2) Observes the panel moving so a drag updates `rememberedOrigin`.
    private var didMoveObserver: Any?
    /// (v4 round-2) Where the operator last dragged the palette THIS app run. nil
    /// until the first drag; restored on every open within the session. It is an
    /// instance var (not UserDefaults), so it resets to the default placement on
    /// the next app boot — the "standard boot-up location" the operator asked for.
    private var rememberedOrigin: CGPoint?

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

    /// Adaptive palette width (operator round-2): the bar tracks the favorite
    /// count and centres in the transparent envelope, clamped to [half, full].
    /// ~5 favorites ≈ half width; 10 ≈ full. Pure so the clamp is unit-tested.
    public nonisolated static func paletteWidth(favoriteCount: Int, full: CGFloat) -> CGFloat {
        let pitch: CGFloat = 64                       // 54 bubble + 10 gap
        let content = CGFloat(max(favoriteCount, 1)) * pitch
        let floorW = (full / 2).rounded()             // never narrower than half
        return min(max(content, floorW), full)
    }

    /// Clamp a remembered drag origin so a display change can't strand the panel
    /// off-screen. Picks the screen under the panel's centre (else the first) and
    /// keeps the frame fully inside it. Pure + nonisolated for headless tests.
    public nonisolated static func clampOrigin(
        _ origin: CGPoint, toScreens screens: [CGRect], panelSize: CGSize
    ) -> CGPoint {
        let centre = CGPoint(x: origin.x + panelSize.width / 2,
                             y: origin.y + panelSize.height / 2)
        guard let screen = screens.first(where: { $0.contains(centre) }) ?? screens.first
        else { return origin }
        let maxX = max(screen.minX, screen.maxX - panelSize.width)
        let maxY = max(screen.minY, screen.maxY - panelSize.height)
        return CGPoint(x: min(max(origin.x, screen.minX), maxX),
                       y: min(max(origin.y, screen.minY), maxY))
    }

    // MARK: - Hot-key registration (Carbon — no Input Monitoring)
    //
    //   v4 enterprise-grade hardening. Two changes from the prior shape that
    //   were the surface of the persistent "⚠ Shortcut not active" defect:
    //
    //   1. INSTALL-ONCE event handler. The Carbon `InstallEventHandler` is
    //      idempotent here — it runs at most ONCE for the lifetime of the
    //      controller (tracked by `eventHandler`), decoupled from per-combo
    //      `RegisterEventHotKey`. Before, every register()/rebind() installed a
    //      FRESH application-level handler; a rebind (unregister→register) or a
    //      double-start could leave multiple live handlers, each trampolining
    //      `handleHotkey()` → the palette opened-then-immediately-closed on a
    //      single press and read as "the shortcut doesn't work". Unregistering
    //      now drops ONLY the hot-key (`UnregisterEventHotKey`); the single
    //      handler persists, so re-register is a clean one-call op.
    //
    //   2. PRECISE collision-vs-plumbing classification. Only the real
    //      "combo owned by another app" OSStatus (`eventHotKeyExistsErr`,
    //      -9878) maps to `.collision`; every other non-noErr maps to
    //      `.plumbingFailure`. A false "in use by another app" message is
    //      thus impossible for a non-collision failure.
    //
    //   The Carbon callback trampolines back to `handleHotkey()` on the main
    //   actor; the `HotkeyConfig.signature` ('NBcb') is unchanged.

    /// Carbon's "this hot-key is already registered (by us or another app)"
    /// result. Named locally so the classification doesn't depend on the
    /// constant being importable everywhere.
    nonisolated private static let eventHotKeyExists: Int32 = -9878  // eventHotKeyExistsErr

    /// Install the application-level Carbon event handler exactly once. Returns
    /// `noErr` when the handler is already installed (idempotent) or the install
    /// succeeds; a non-noErr OSStatus on a genuine install failure. Decoupling
    /// this from `RegisterEventHotKey` is the fix for the multi-handler churn
    /// that made a single key-press toggle the palette twice.
    @discardableResult
    private func installEventHandlerIfNeeded() -> OSStatus {
        if eventHandler != nil { return noErr }   // already installed — idempotent
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
        return installStatus
    }

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

        // (1) Install-once handler — NOT re-installed on every register/rebind.
        let installStatus = installEventHandlerIfNeeded()
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
            // (2) Precise classification: ONLY the real already-registered code
            // is a collision; anything else is a plumbing failure. The handler
            // is install-once, so we do NOT tear it down here (a later retry /
            // rebind reuses it).
            lastRegisterStatus = Self.classifyRegisterFailure(regStatus)
            print("[CommandBridge] RegisterEventHotKey failed: \(regStatus) → \(lastRegisterStatus)")
            hotKeyRef = nil
            return false
        }

        isRegistered = true
        lastRegisterStatus = .registered
        print("[CommandBridge] registered global hot-key \(hotkey.displayString) (Carbon — no Input Monitoring)")
        return true
    }

    /// Map a non-noErr `RegisterEventHotKey` OSStatus to the structured
    /// outcome. Pure + nonisolated so the collision-vs-plumbing rule is
    /// unit-tested headlessly (no Carbon call needed to assert the mapping).
    public nonisolated static func classifyRegisterFailure(_ osStatus: OSStatus) -> HotkeyRegisterStatus {
        osStatus == eventHotKeyExists
            ? .collision(osStatus: Int32(osStatus))
            : .plumbingFailure(osStatus: Int32(osStatus))
    }

    /// Drop the live hot-key registration. The install-once event handler is
    /// intentionally RETAINED (removing + re-adding it on every disable/enable
    /// or rebind was the source of handler churn); it is torn down only by
    /// `teardownEventHandler()` (called on app termination). Idempotent.
    public func unregisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        isRegistered = false
        lastRegisterStatus = .unattempted
    }

    /// Full teardown — unregister the hot-key AND remove the single Carbon
    /// event handler. Called on app termination so no application-level
    /// handler outlives the controller.
    public func teardownEventHandler() {
        unregisterHotkey()
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
    }

    @discardableResult
    public func rebind(to newHotkey: HotkeyConfig) -> Bool {
        // No-op fast path: re-binding to the SAME already-live combo is a
        // success without churning the registration.
        if isRegistered, newHotkey == hotkey {
            lastRegisterStatus = .registered
            return true
        }
        let previous = hotkey
        unregisterHotkey()
        hotkey = newHotkey
        if registerHotkey() { return true }
        // New combo failed — restore the prior working combo and surface the
        // NEW combo's failure reason (so the status row names why the rebind
        // was rejected, while the palette keeps working on the old combo).
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
        if let remembered = rememberedOrigin {
            // (v4 round-2) Session memory — reopen where the operator last dragged
            // it, clamped so a display change can't strand it off-screen.
            panel.setFrameOrigin(
                Self.clampOrigin(remembered, toScreens: screenFrames,
                                 panelSize: panel.frame.size)
            )
        } else if let target = Self.pickScreenFrame(
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
        installDidMoveObserver()
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
        removeDidMoveObserver()
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

    // MARK: - Drag-to-reposition with session memory (v4 round-2)

    /// While open, capture every panel move (the operator dragging it via
    /// `isMovableByWindowBackground`) into `rememberedOrigin`. The programmatic
    /// placement in `show()` runs BEFORE this is installed, so only USER drags are
    /// remembered — and only for this app run (reset to default on boot).
    private func installDidMoveObserver() {
        removeDidMoveObserver()
        didMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.panel else { return }
                self.rememberedOrigin = p.frame.origin
            }
        }
    }

    private func removeDidMoveObserver() {
        if let obs = didMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            didMoveObserver = nil
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
        // (v3.7.6) Dashboard popover presenter. The pill no longer carries a
        // leading bridge-mark (the design `.cb-pill` has none — see `pill`), so
        // this is invoked from the status-bar item path rather than the palette
        // bar; it stays wired so that entry point keeps working. We hide the
        // palette first so the two surfaces don't overlap, then hand off to the
        // App-layer presenter (which owns the StatusBar / PermissionManager).
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

    /// Menu-bar ⌘ chip → SettingsNavigation to Orders/Commands. Public so the
    /// SwiftUI button can invoke without touching the AppDelegate.
    /// PKT-A: Commands folded into Orders → open Orders on the `commands` tab.
    public func openCommandsSettings() {
        SettingsNavigation.shared.go(.orders, anchor: "commands")
        if let app = NSApp.delegate as? AppDelegate {
            app.openSettings(section: .orders)
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
    /// Keyboard-selected row in the active panel (recents/search), by slug.
    /// ↓/↑ move it; Enter fires it. nil → no selection (closed tray).
    @Published public var selectedSlug: String? = nil
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
    /// (v3.7.6) Open the Dashboard popover. No longer fired from a pill glyph
    /// (the design `.cb-pill` has no leading mark); retained for the status-bar
    /// entry point that presents the same Dashboard surface.
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
            if case .search = panelMode { panelMode = .none; selectedSlug = nil }
            searchRows = []
            return
        }
        let hits = (try? store.search(trimmed)) ?? []
        searchRows = hits.map(Self.row(from:))
        panelMode = .search(query: trimmed)
        selectedSlug = searchRows.first?.slug
    }

    /// ↓ → open recents (140ms slide-in handled by the view), selecting the
    /// first row so ↑/↓ can traverse and Enter fires it.
    public func openRecents() {
        if recentRows.isEmpty { return }
        panelMode = .recents
        selectedSlug = recentRows.first?.slug
    }

    /// Rows currently shown in the secondary panel (recents or search).
    private var activeRows: [Row] {
        switch panelMode {
        case .recents: return recentRows
        case .search:  return searchRows
        case .none:    return []
        }
    }

    /// ↓ (+1) / ↑ (−1) move the keyboard selection within the open panel,
    /// clamped to the ends. ↓ from the closed tray opens recents.
    public func moveSelection(_ delta: Int) {
        if case .none = panelMode {
            if delta > 0 { openRecents() }
            return
        }
        let rows = activeRows
        guard !rows.isEmpty else { return }
        let cur = selectedSlug.flatMap { s in rows.firstIndex(where: { $0.slug == s }) } ?? 0
        let next = min(max(cur + delta, 0), rows.count - 1)
        selectedSlug = rows[next].slug
    }

    /// Enter fires the keyboard-selected row (falling back to the first).
    public func commitSelected() {
        let rows = activeRows
        guard !rows.isEmpty else { return }
        let slug = selectedSlug.flatMap { s in rows.contains(where: { $0.slug == s }) ? s : nil }
            ?? rows.first?.slug
        if let slug { onFireSlug(slug) }
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
    @FocusState private var queryFocused: Bool
    // (v4 round-3) Window-drag plumbing — resolve the hosting window + track the
    // cursor-to-origin offset so the palette can drag itself.
    @State private var paletteWindow: NSWindow?
    @State private var dragMouseOffset: CGSize?

    private var anim: CommandBridgeAnimation {
        reduceMotion ? .reduced : .locked
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
            VStack(spacing: BridgeTokens.Space.s3) {
                tray
                pill
                if case .none = model.panelMode {
                    EmptyView()
                } else {
                    secondaryPanel
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                footer
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
        // (v4 round-3) Capture the hosting window + make the whole palette
        // draggable. simultaneousGesture so taps on the orbs / menu mark still
        // fire and the field still focuses; a >3pt drag on the glass repositions.
        .background(WindowAccessor { paletteWindow = $0 })
        .simultaneousGesture(windowDrag)
        .background(KeyHandler(
            onNumber: { n in model.onFireSlot(n) },
            onArrowDown: { model.moveSelection(1) },
            onArrowUp: { model.moveSelection(-1) },
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

    /// Drag the whole palette to reposition it (operator round-3: the bar wouldn't
    /// move). Moves the hosting window from the LIVE cursor (`NSEvent.mouseLocation`,
    /// screen coords) so there's no feedback jitter as the window follows.
    /// `minimumDistance` keeps taps (fire favorite / focus field) intact; a >3pt
    /// drag anywhere on the glass repositions. Session memory + reset-on-boot live
    /// in the controller (its didMove observer records each move).
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                guard let win = paletteWindow else { return }
                let mouse = NSEvent.mouseLocation
                if dragMouseOffset == nil {
                    dragMouseOffset = CGSize(width: mouse.x - win.frame.origin.x,
                                             height: mouse.y - win.frame.origin.y)
                }
                if let off = dragMouseOffset {
                    win.setFrameOrigin(CGPoint(x: mouse.x - off.width,
                                               y: mouse.y - off.height))
                }
            }
            .onEnded { _ in dragMouseOffset = nil }
    }

    // MARK: Tray

    /// Adaptive palette width — tracks the favorite count, centred in the
    /// transparent envelope, clamped to [half, full] (operator round-2).
    private var paletteWidth: CGFloat {
        let favCount = model.slotRows.filter { $0.command != nil }.count
        return CommandBridgeController.paletteWidth(
            favoriteCount: favCount, full: CommandBridgeController.pillWidth)
    }

    private var tray: some View {
        // Only REAL favorites, CENTERED (operator round-2: no empty slots, no
        // left-anchored gaps). The fixed-pitch HStack centres inside `paletteWidth`.
        let favorites = model.slotRows.filter { $0.command != nil }
        return HStack(spacing: 10) {
            ForEach(Array(favorites.enumerated()), id: \.element.id) { idx, row in
                slotView(row, cascadeIndex: idx)
            }
        }
        .frame(width: paletteWidth)
    }

    @ViewBuilder
    private func slotView(_ row: CommandBridgeViewModel.SlotRow, cascadeIndex: Int) -> some View {
        // The tray now renders ONLY assigned favorites (operator round-2), so this
        // is always a real command; `command == nil` cannot reach here.
        if let cmd = row.command {
            VStack(spacing: BridgeTokens.Space.s2) {
                Button { model.onFireSlot(row.storeSlot) } label: {
                    BridgeGlassBubble(size: Self.bubbleSize) {
                        iconView(for: cmd.icon, color: cmd.color, size: 25)
                    }
                }
                .buttonStyle(.plain)
                keycap(row.displayKey)
            }
            // Bubble cascade — 10ms stagger per slot from the locked spec.
            .opacity(model.didOpen ? 1.0 : 0.0)
            .animation(
                .easeOut(duration: anim.openDuration)
                .delay(Double(cascadeIndex) * anim.bubbleCascadeStagger),
                value: model.didOpen
            )
        }
    }

    /// Tray bubble edge length — the v4 source draws 54px liquid-glass domes.
    private static let bubbleSize: CGFloat = 54

    /// Mono numeric keycap beneath each favorite — a dark chip with near-white ink
    /// (operator round-2: the bare number was unreadable on light backdrops). The
    /// chip is self-contained (dark fill + white digit) so it stays legible on ANY
    /// backdrop — carbon or titanium, over wallpaper or white.
    private func keycap(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.96))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.34))
            )
    }

    // (emptyWell removed — the tray no longer renders unassigned slots; operator
    //  round-2: show only real favorites, centered.)

    // MARK: Pill
    //
    //   v4 source `.cb-pill`: 70px popover-glass bar (radius 22) whose ONLY
    //   children are the field area ([blinking accent caret][mono query]) and a
    //   trailing glass menu-bar mark. The source pill has NO leading glyph —
    //   the layout is [caret][placeholder] … [trailing mark] — so the prior
    //   leading bridge-mark button (a v3.7.6 add not present in the design) is
    //   removed; the caret/field now sit flush at the pill's leading edge exactly
    //   as `command-bridge.html` draws them. The trailing mark (→ Commands
    //   settings) renders the Bridge mark IMAGE (`.cb-menubar img`, 24×24), not a
    //   literal ⌘ glyph. Dashboard remains reachable from the status-bar item /
    //   menu-bar mark; `model.onBridgeMark` stays defined for that path.

    private var pill: some View {
        HStack(spacing: BridgeTokens.Space.s4) {
            // Field area — leading blinking caret (`.cb-caret`) sits in front of
            // the query field; its mono placeholder ("Bridge Command") is drawn by
            // QueryField itself, so the caret leads the pill exactly as the source
            // shows (no glyph precedes it).
            HStack(spacing: BridgeTokens.Space.s3) {
                QueryField(
                    text: Binding(
                        get: { model.query },
                        set: { model.queryDidChange($0) }
                    ),
                    placeholder: "Bridge Command",
                    isFocused: $queryFocused,
                    onReturn: { commitTopSelection() },
                    onArrowDown: { model.moveSelection(1) },
                    onArrowUp: { model.moveSelection(-1) },
                    onEscape: { model.onEscape() }
                )
                .frame(maxWidth: .infinity)
            }

            // Trailing menu-bar mark (`.cb-menubar`) → Commands settings. Glass
            // control tile (40×40, radius 12 = Radius.card, glassControl fill +
            // hair-strong border + bevel-control) wrapping the 24×24 Bridge mark
            // image (`.cb-menubar img`) — the brand mark, not a keyboard glyph.
            Button {
                model.onSettings()
            } label: {
                menuBarMark
                    .frame(width: 24, height: 24)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
                            .fill(BridgeTokens.glassControl)
                            .bridgeBevel(BridgeTokens.bevelControl, radius: BridgeTokens.Radius.card)
                    )
            }
            .buttonStyle(.plain)
            .help("Open Commands settings")
        }
        .padding(.leading, BridgeTokens.Space.s6)
        .padding(.trailing, BridgeTokens.Space.s4)
        .frame(width: paletteWidth, height: 70)
        .popoverGlass(radius: 22)
    }

    // (Fake blinking caret removed — the real QueryField shows the only caret,
    //  on focus. Operator: kill the double-cursor.)

    /// The trailing menu-bar mark image (`.cb-menubar img`). Loads `MenuBarIcon`
    /// — the bundled Bridge mark (`assets/bridge-mark-white.png` in the design) —
    /// template-rendered so it tints with the adaptive foreground at fg2 (mirrors
    /// the source's `opacity:.92` ink). Falls back to the `command.circle` SF
    /// Symbol mark only when the asset can't be resolved (e.g. headless).
    @ViewBuilder
    private var menuBarMark: some View {
        if let icon = Self.bridgeMarkImage {
            Image(nsImage: icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(BridgeTokens.fg2)
        } else {
            Image(systemName: "command.circle")
                .font(BridgeTokens.Typeface.hero)
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

    // MARK: Footer hint rail (`.cb-foot`)
    //
    //   A non-interactive shortcut legend mirroring the source's keycap rail.
    //   Pure decoration — no controller wiring; the keys it advertises are the
    //   ones already handled by `KeyHandler` / `QueryField`.

    private var footer: some View {
        HStack(spacing: BridgeTokens.Space.s4) {
            footHint("1–0", "fire favorite")
            footHint("↑↓", "browse")
            footHint("↵", "run")
            Spacer(minLength: 0)
            footHint("esc", "close")
        }
        .frame(width: paletteWidth)
        .padding(.horizontal, BridgeTokens.Space.s2 - 2)
        .padding(.top, BridgeTokens.Space.s1 / 2)
        .accessibilityHidden(true)
    }

    private func footHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: BridgeTokens.Space.s1 + 1) {
            kbdChip(key)
            Text(label)
                .font(BridgeTokens.Typeface.micro)
                .foregroundStyle(BridgeTokens.fg5)
        }
    }

    /// A `<kbd>` chip from the source footer — mono glyph in a chip-filled pill.
    private func kbdChip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
            .foregroundStyle(BridgeTokens.fg4)
            .padding(.horizontal, BridgeTokens.Space.s1 + 1)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(BridgeTokens.chipFill)
            )
    }

    // MARK: Secondary panel (recents / search)

    @ViewBuilder
    private var secondaryPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.panelMode {
            case .none:
                EmptyView()
            case .recents:
                panelHeader("Recents")
                ForEach(model.recentRows) { r in
                    rowView(r, selected: r.slug == model.selectedSlug)
                }
                if model.recentRows.isEmpty {
                    panelEmptyHint("No recents yet — fire a command to start the history.")
                }
            case .search(let q):
                panelHeader("Matches — sorted by recency")
                ForEach(model.searchRows) { r in
                    rowView(r, selected: r.slug == model.selectedSlug, highlight: q)
                }
                if model.searchRows.isEmpty {
                    panelEmptyHint("No match for \"\(q)\".")
                }
            }
        }
        .padding(BridgeTokens.Space.s2)
        .frame(width: paletteWidth)
        .popoverGlass(radius: 18)
    }

    /// Panel section header (`.cb-phead`) — an uppercase cap micro-caption.
    private func panelHeader(_ s: String) -> some View {
        Text(s)
            .bridgeCap()
            .foregroundStyle(BridgeTokens.fg5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BridgeTokens.Space.s3)
            .padding(.top, BridgeTokens.Space.s2)
            .padding(.bottom, BridgeTokens.Space.s1 + 2)
    }

    private func panelEmptyHint(_ s: String) -> some View {
        Text(s)
            .font(BridgeTokens.Typeface.meta)
            .foregroundStyle(BridgeTokens.fg4)
            .padding(.horizontal, BridgeTokens.Space.s3)
            .padding(.vertical, BridgeTokens.Space.s1 + 2)
    }

    @ViewBuilder
    private func rowView(_ r: CommandBridgeViewModel.Row,
                         selected: Bool,
                         highlight: String = "") -> some View {
        Button {
            model.onFireSlug(r.slug)
        } label: {
            HStack(spacing: BridgeTokens.Space.s4 - 2) {
                // Icon (`.cb-ic`) — the bare glyph, no chip box (operator round-2:
                // drop the per-row container). A soft drop-shadow lifts it off the
                // frosted panel.
                iconView(for: r.icon, color: r.color, size: 17)
                    .frame(width: 28, height: 28)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)

                highlightedName(r.name, query: highlight)
                    .font(BridgeTokens.Typeface.name)
                    .foregroundStyle(BridgeTokens.fg1)
                    .lineLimit(1)

                Spacer(minLength: BridgeTokens.Space.s1)

                Text(Self.relativeHint(for: r.lastUsedAt))
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg5)

                if let slot = r.keySlot {
                    // Slot keycap badge (`.cb-badge`) — mono, chip-filled.
                    Text("\(slot)")
                        .font(BridgeTokens.Typeface.micro.monospacedDigit())
                        .foregroundStyle(BridgeTokens.fg3)
                        .padding(.horizontal, BridgeTokens.Space.s1 + 1)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(BridgeTokens.chipFill)
                        )
                }
            }
            .padding(.horizontal, BridgeTokens.Space.s3)
            .frame(height: 46)
            .background(rowBackground(selected: selected))
        }
        .buttonStyle(.plain)
    }

    /// Selected-row treatment (`.cb-row.on`): faint accent tint + accent hairline
    /// ring + a 2.5pt accent-strong rail down the leading edge. Unselected is clear.
    @ViewBuilder
    private func rowBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: BridgeTokens.Radius.card, style: .continuous)
        if selected {
            shape
                .fill(BridgeTokens.accent.opacity(0.15))
                .overlay(shape.strokeBorder(BridgeTokens.accent.opacity(0.34), lineWidth: 0.5))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(BridgeTokens.accentStrong)
                        .frame(width: 2.5)
                        .padding(.vertical, 11)
                        .padding(.leading, 4)
                }
        } else {
            shape.fill(Color.clear)
        }
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
        // Fires the keyboard-selected row (↑/↓), falling back to the first.
        model.commitSelected()
    }
}

// ============================================================
// MARK: - 7b. Popover-glass surface (`.cb-pill` / `.cb-panel`)
//
//   The pill + recents/search panel container. Operator round-2 ("I still see
//   the container color + outlines — make it near-invisible liquid glass")
//   reduced this from the opaque e3 popover material to FROSTED AIR:
//     • `.ultraThinMaterial` — the most transparent system blur, the ONLY
//       backing, so the desktop reads through as liquid glass (no tint box).
//     • a faint centre LENS frost (thick middle → clear rim).
//     • a faint diagonal `--sheen` lip — the only specular.
//     • a single soft FLOAT shadow — NO directional bevel, NO edge hairline.
//   The favorites (`BridgeGlassBubble`) stay FIRM (fill + rim); only the
//   container goes near-invisible — the operator's firm-orbs / no-box split.
// ============================================================

private struct PopoverGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isDark = colorScheme == .dark
        // Operator round-3: "on a white backdrop I can still see the container."
        // A blur material (.ultraThinMaterial) keeps a gray tint in DARK mode that
        // reads as a filled box over white. Replace it with a WHISPER-faint adaptive
        // frost that is invisible over white in BOTH themes (6%-white in dark,
        // 45%-white ≈ white-on-white in light) and only a barely-there film over
        // busy content. The favorites (BridgeGlassBubble) carry the liquid-glass
        // signature; the container all but disappears — no fill box, no bevel, no
        // edge hairline. The only definition is a soft, faint float halo.
        let frost = isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.45)
        return content
            .background {
                ZStack {
                    shape.fill(frost)
                    // Faint centre lens (thick-middle read) — also invisible over white.
                    GeometryReader { geo in
                        shape.fill(RadialGradient(
                            colors: [Color.white.opacity(isDark ? 0.06 : 0.10), Color.clear],
                            center: UnitPoint(x: 0.5, y: 0.26),
                            startRadius: 0,
                            endRadius: max(geo.size.width, geo.size.height) * 0.6))
                    }
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(isDark ? 0.20 : 0.10), radius: 11, y: 6)
    }
}

// (OptionalBridgeShadow removed — the frosted-air PopoverGlass uses a single
//  soft float shadow, not the e3 dual-shadow rung.)

private extension View {
    /// Wrap `self` in the v4 floating popover-glass surface at `radius`.
    func popoverGlass(radius: CGFloat) -> some View {
        modifier(PopoverGlass(radius: radius))
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
    var onArrowUp: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = BridgeQueryTextField()
        field.delegate = context.coordinator
        // v4 source `.cb-ph`: the command field is mono (Space Mono → SF Mono)
        // at 27pt. Use the monospaced system face so the typed query + the
        // placeholder both read as the locked lowercase-mono command field.
        let monoFont = NSFont.monospacedSystemFont(ofSize: 27, weight: .regular)
        field.font = monoFont
        // Placeholder ink matches `.cb-ph` (fg-1 @ 34%) — a faint mono prompt.
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: monoFont,
                .foregroundColor: BridgeTokens.adaptiveNSColor(
                    dark:  { BridgeTokens.whiteAlpha(0.34) },
                    light: { BridgeTokens.blackAlpha(0.34) }
                ),
            ]
        )
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
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp(); return true
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
// MARK: - 8b. WindowAccessor — resolve the hosting NSWindow
//
//   The borderless non-activating panel ignores isMovableByWindowBackground when
//   its content view is an NSHostingView, so the palette drags itself via a
//   SwiftUI gesture (see `windowDrag`). That needs a reference to the hosting
//   window; this representable resolves it on appear.
// ============================================================

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
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
    let onArrowUp: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onNumber = onNumber
        v.onArrowDown = onArrowDown
        v.onArrowUp = onArrowUp
        v.onReturn = onReturn
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MonitorView: NSView {
        var onNumber: ((Int) -> Void)?
        var onArrowDown: (() -> Void)?
        var onArrowUp: (() -> Void)?
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
            case UInt16(kVK_UpArrow):
                v.onArrowUp?(); return true
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
