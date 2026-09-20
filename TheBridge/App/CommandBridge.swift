// CommandBridge.swift — PKT-878 v3.6.3
// TheBridge · App
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
// Behaviour locked by PKT-878 + issue #129:
//   • Number key 1–0 → fires the assigned favorite → inserts its
//     markdown body at the focused cursor in the prior app → closes.
//     The clipboard is never read or written on this path.
//   • ↓ → opens the recents slide-in (140ms ease).
//   • Typing → substring search across all commands, ranked by recency.
//   • Enter or click on a row → fires the selected command (insert +
//     close). Esc / focus-loss → closes without writing.
//   • Open animation: 180ms ease-out, opacity 0→1, scale 0.94→1.0,
//     with a 10ms cascade stagger across the 10 bubbles.
//   • Reduce-motion → all animations collapse to instant.
//
// What was REUSED verbatim from the legacy `CommandBox.swift`:
//   • `HotkeyConfig`            — Carbon `RegisterEventHotKey` config
//                                  + persisted-load + Cocoa→Carbon recorder
//   • `ClipboardWriting`/`InMemoryClipboard`/`SystemClipboard`
//                                  — retained as a probe seam so tests
//                                  can prove the fire path never writes
//   • `CommandTextInserting`       — cursor-insert seam (#129)
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
// recents tracker, the commit→cursor insert, the animation config)
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
///
/// Visual-pass 2026-07-23 (Spotlight-rhyme): open **and** close share the
/// same duration family; tiles co-born with the bar (tiny stagger only);
/// no group-scale silhouette (opacity-led open).
public struct CommandBridgeAnimation: Sendable, Equatable {
    /// Open animation duration (seconds).
    public let openDuration: TimeInterval
    /// Close animation duration (seconds). Same family as open (±0); dismiss
    /// must finish **before** `orderOut` so close is never a hard cut.
    public let closeDuration: TimeInterval
    /// Stagger between favorite-tile appearances (seconds). Micro only —
    /// tiles still read as co-born with the bar.
    public let bubbleCascadeStagger: TimeInterval
    /// Recents / search panel slide-in duration (seconds).
    public let recentsSlideDuration: TimeInterval
    /// Starting scale for the **bar** open animation (tiles use opacity only).
    public let openStartScale: CGFloat
    /// Starting opacity for open.
    public let openStartOpacity: Double

    public init(reduceMotion: Bool = false) {
        if reduceMotion {
            self.openDuration = 0
            self.closeDuration = 0
            self.bubbleCascadeStagger = 0
            self.recentsSlideDuration = 0
            self.openStartScale = 1.0
            self.openStartOpacity = 1.0
        } else {
            self.openDuration = 0.180
            self.closeDuration = 0.180
            self.bubbleCascadeStagger = 0.012
            self.recentsSlideDuration = 0.140
            self.openStartScale = 0.97
            self.openStartOpacity = 0.0
        }
    }

    public static let locked = CommandBridgeAnimation()
    public static let reduced = CommandBridgeAnimation(reduceMotion: true)
}

// ============================================================
// MARK: - Glass recipe (bar + tiles share one system)
// ============================================================

/// Shared visual metrics for Command Bridge chrome (bar + favorite tiles).
/// Contract 2026-07-23: one recipe table — not dual bubble vs ultraThin air.
public enum CommandBridgeChrome: Sendable {
    /// Search bar width (≤580). Slightly under legacy 640.
    public static let pillWidth: CGFloat = 560
    /// Search bar height (≤58).
    public static let pillHeight: CGFloat = 52
    /// Bar continuous corner radius (squarer than Spotlight stadium).
    public static let barCornerRadius: CGFloat = 14
    /// Favorite tile edge length (≥36 hit target).
    public static let tileSize: CGFloat = 40
    /// Tile continuous corner radius (squircle, not full circle).
    public static let tileCornerRadius: CGFloat = 12
    /// Results panel corner radius.
    public static let panelCornerRadius: CGFloat = 14
    /// Soft float shadow (not e2 fog r33).
    public static let glassShadowRadius: CGFloat = 12
    public static let glassShadowY: CGFloat = 5
    /// Pitch between tile centers for adaptive width.
    public static let tilePitch: CGFloat = 48
    /// Host panel width: bar + horizontal breathing room.
    public static let hostWidth: CGFloat = pillWidth + 24
    /// Host panel height: content-hug for idle + search results (not 360 empty air).
    public static let hostHeight: CGFloat = 260
    /// Expanded host when the create sheet is open so Save/Cancel stay inside
    /// the panel. Idle `hostHeight` stays the content-hug floor (< 360).
    public static let hostHeightCreateSheet: CGFloat = 480

    public static func hostHeight(createSheetOpen: Bool) -> CGFloat {
        createSheetOpen ? hostHeightCreateSheet : hostHeight
    }

    /// Cocoa frame after a host-height change that keeps the **top** edge fixed
    /// (grow/shrink downward). `current` uses bottom-left origin.
    public static func frameKeepingTop(current: CGRect, newHeight: CGFloat) -> CGRect {
        let delta = newHeight - current.height
        return CGRect(x: current.origin.x,
                      y: current.origin.y - delta,
                      width: current.width,
                      height: newHeight)
    }
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
//     • On commit: inserts the resolved command body at the focused
//       editable control of the previously-frontmost app via
//       `CommandTextInserting`. The clipboard is not used.
//
//   PERMISSION MODEL (issue #129 — cursor insert): Carbon
//   `RegisterEventHotKey` is still a HOT-KEY REGISTRATION, not an event
//   tap — no Input Monitoring grant. Insertion requires Accessibility
//   (`AXIsProcessTrusted()`). When the grant is absent, or there is no
//   focused editable target, the fire path fails closed with an explicit
//   status and does NOT copy to the clipboard as a fallback.
// ============================================================

@MainActor
public final class CommandBridgeController: NSObject {

    // MARK: Constants

    /// Pill width — `CommandBridgeChrome.pillWidth` (≤580 Spotlight-rhyme).
    public nonisolated static var pillWidth: CGFloat { CommandBridgeChrome.pillWidth }
    /// Hosting panel size — content-hug (no empty 360pt air plate).
    public nonisolated static var panelSize: NSSize {
        NSSize(width: CommandBridgeChrome.hostWidth, height: CommandBridgeChrome.hostHeight)
    }

    // MARK: Stored state

    private var hotkey: HotkeyConfig
    private let clipboard: ClipboardWriting
    private let inserter: CommandTextInserting
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

    /// The app that was frontmost the instant before we showed, so
    /// cursor-insert can target its focused AX element. Captured in
    /// `show()` BEFORE `orderFrontRegardless()`.
    private var priorApp: NSRunningApplication?

    /// (v3.7.6) Presents the standalone Dashboard popover anchored off the
    /// bar's leading bridge-mark. Injected by the App layer (it owns the
    /// `StatusBarController` / `PermissionManager` the dashboard needs); `nil`
    /// in tests / shells that don't wire it. Returns whether it presented.
    public var presentDashboard: (() -> Void)?

    /// Last insert attempt from `applyCommit` / `fireSlot` / `fireSlug`.
    /// Tests assert this instead of reading the pasteboard.
    public private(set) var lastInsertOutcome: CommandInsertOutcome?
    /// Body delivered on the last successful insert (nil when skipped/failed).
    public private(set) var lastInsertedText: String?

    /// Cancels a pending close `orderOut` when re-opened mid-dismiss.
    private var dismissGeneration: UInt = 0

    public private(set) var isRegistered = false
    public private(set) var lastRegisterStatus: HotkeyRegisterStatus = .unattempted
    public private(set) var lifecycle: CommandBridgeLifecycle = .closed

    public var hotkeyConfig: HotkeyConfig { hotkey }
    public var isVisible: Bool { lifecycle == .open || lifecycle == .opening }

    // MARK: Init

    public init(hotkey: HotkeyConfig = .productionDefault,
                clipboard: ClipboardWriting = SystemClipboard(),
                inserter: CommandTextInserting = AccessibilityCommandInserter(),
                coordinator: CommandPaletteCoordinator,
                store: CommandStore = .shared,
                recents: CommandBridgeRecents = .shared) {
        self.hotkey = hotkey
        self.clipboard = clipboard
        self.inserter = inserter
        self.coordinator = coordinator
        self.store = store
        self.recents = recents
        super.init()
    }

    /// Convenience for tests / shells that don't pass a hotkey.
    /// Defaults the inserter to `RecordingTextInserter` so headless tests
    /// never type into the host process.
    public convenience init(clipboard: ClipboardWriting,
                            coordinator: CommandPaletteCoordinator) {
        self.init(hotkey: .productionDefault,
                  clipboard: clipboard,
                  inserter: RecordingTextInserter(),
                  coordinator: coordinator)
    }

    /// Test seam: inject both the clipboard probe (must stay untouched)
    /// and a recording / forced-outcome inserter.
    public convenience init(clipboard: ClipboardWriting,
                            inserter: CommandTextInserting,
                            coordinator: CommandPaletteCoordinator) {
        self.init(hotkey: .productionDefault,
                  clipboard: clipboard,
                  inserter: inserter,
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
        let pitch = CommandBridgeChrome.tilePitch     // tile + gap
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
        // Cancel any in-flight close so re-hotkey mid-fade doesn't orderOut.
        dismissGeneration &+= 1

        // Snapshot the destination caret BEFORE the palette becomes key.
        // `makeKeyAndOrderFront` below focuses the query field and clears
        // the prior app's AX focused element — insert must use this snapshot
        // (issue #129 live miss: clipboard gone, nothing landed at cursor).
        snapshotInsertDestination(frontmost: NSWorkspace.shared.frontmostApplication)

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

    /// Snapshot the app + focused AX element that should receive the
    /// command body. Called from `show()` before the palette becomes key.
    /// Tests call this with `NSRunningApplication.current` (self → no target).
    public func snapshotInsertDestination(frontmost: NSRunningApplication?) {
        let me = NSRunningApplication.current.processIdentifier
        priorApp = (frontmost?.processIdentifier == me) ? nil : frontmost
        inserter.captureFocusedElement(of: insertTargetPID(priorApp))
    }

    /// Public entrypoint mirroring the legacy `dismissOnEscape()` —
    /// closes the popup without writing anything.
    /// Visual-pass: animate close (didOpen→false) then `orderOut` only after
    /// `closeDuration` so dismiss is never a hard cut (Red Team DoD).
    /// Pass `immediate: true` on the fire path so CGEvent typing cannot
    /// land in the palette query field.
    public func hide(immediate: Bool = false) {
        guard lifecycle == .open || lifecycle == .opening else { return }
        lifecycle = .closing
        removeFocusLossObserver()
        removeBecomeKeyObserver()
        removeGlobalClickMonitor()
        removeDidMoveObserver()
        model?.didOpen = false
        dismissGeneration &+= 1
        if immediate {
            panel?.orderOut(nil)
            model?.resetToTray()
            lifecycle = .closed
            return
        }
        let gen = dismissGeneration
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let delay = reduce ? 0 : CommandBridgeAnimation.locked.closeDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.dismissGeneration == gen, self.lifecycle == .closing else { return }
            self.panel?.orderOut(nil)
            self.model?.resetToTray()
            self.lifecycle = .closed
        }
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
    //   Three commit shapes, all routing through `applyCommit(.paste(body))`
    //   so the cursor-insert contract is one-line-tested. The injected
    //   clipboard is a probe only — this path never writes it.

    /// Fire the favorite assigned to slot `slot` (0…9). If the slot is
    /// empty this is a no-op (no insert, clipboard untouched, panel stays).
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

    /// Shared fire path for `fireSlot` / `fireSlug`. Inserts the body at
    /// the prior app's focused editable control (issue #129). Never
    /// copies to the clipboard. Dismisses the palette *before* insert so
    /// synthetic typing cannot land in the query field; the focused
    /// element was snapshotted at `show()`.
    /// Compatibility-required commands fail closed: no insert, no fire.
    private func commitBody(_ body: String, slug: String) {
        let gate: CommandStore.ExecutionGate
        do {
            gate = try store.executionGate(slug: slug)
        } catch {
            _ = applyCommit(.unavailable(name: slug, reason: error.localizedDescription))
            hide()
            print("[CommandBridge] command execution gated: \(error.localizedDescription)")
            return
        }
        if case .compatibilityRequired(let evidence) = gate {
            _ = applyCommit(.unavailable(name: slug, reason: evidence))
            hide()
            print("[CommandBridge] command execution gated: \(evidence)")
            return
        }
        let target = priorApp
        let pid = insertTargetPID(target)
        // Resign key before AX / CGEvent insert. The destination caret was
        // captured in `snapshotInsertDestination` while the palette was
        // still not key.
        hide(immediate: true)
        // Activate the *resolved* pid (user Chrome), not Playwright MCP
        // Chrome that shares `com.google.Chrome`.
        if let pid,
           let dest = NSRunningApplication(processIdentifier: pid),
           dest.processIdentifier != NSRunningApplication.current.processIdentifier {
            dest.activate()
        }
        // Let the destination become key after the non-activating panel
        // resigns, before AX / CGEvent insert. Electron otherwise keeps
        // the composer unfocused and unicode typing lands nowhere.
        _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
        let outcome = applyCommit(.paste(body), intoProcess: pid)
        if outcome?.succeeded == true {
            try? store.recordUse(slug: slug)
            recents.record(slug)
        }
        if let outcome, !outcome.succeeded {
            print("[CommandBridge] \(outcome.userMessage)")
        }
    }

    /// Destination pid for insert: the captured prior app, unless it is us.
    /// Chrome/Edge helpers publish no AX tree — map to the browser process.
    private func insertTargetPID(_ target: NSRunningApplication?) -> pid_t? {
        guard let target else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        guard target.processIdentifier != me else { return nil }
        return CommandInsertPointerFocus.axApplicationPID(for: target.processIdentifier)
    }

    /// Cursor-insert commit (issue #129). `.paste(body)` delivers through
    /// `CommandTextInserting` and never writes the clipboard. `.notFound`
    /// / `.unavailable` / empty body skip insert. The injected clipboard
    /// is retained only so tests can assert `writeCount == 0`.
    @discardableResult
    public func applyCommit(
        _ result: CommandPaletteCommitResult,
        intoProcess pid: pid_t? = nil
    ) -> CommandInsertOutcome? {
        _ = clipboard  // probe only — never writeString / readString here
        lastInsertedText = nil
        switch result {
        case .paste(let body):
            guard !body.isEmpty else {
                lastInsertOutcome = .emptyBody
                return .emptyBody
            }
            let outcome = inserter.insert(body, intoProcess: pid)
            lastInsertOutcome = outcome
            if outcome.succeeded { lastInsertedText = body }
            return outcome
        case .notFound:
            lastInsertOutcome = nil
            return nil
        case .unavailable(_, let reason):
            lastInsertOutcome = nil
            print("[CommandBridge] command body unavailable: \(reason)")
            return nil
        }
    }

    // MARK: - Panel construction

    private func makePanel() -> CommandBridgePanel {
        let panel = CommandBridgePanel(size: Self.panelSize)

        let model = CommandBridgeViewModel(
            store: store,
            recents: recents,
            // (PKT-1006 R2) Live multi-entity provider. The view-model owns no
            // store coupling — the controller supplies the searchable entities
            // (Commands + Skills + Jobs + Tools) at query time.
            entityProvider: { [weak self] in self?.buildSearchEntities() ?? [] }
        )
        model.onFireSlot = { [weak self] slot in self?.fireSlot(slot) }
        model.onFireSlug = { [weak self] slug in self?.fireSlug(slug) }
        // (PKT-1006 R2) Route a typed result's destination to its open action.
        model.onFireDestination = { [weak self] dest in self?.fireDestination(dest) }
        model.onEscape   = { [weak self] in self?.hide() }
        model.onSettings = { [weak self] in self?.openCommandsSettings() }
        model.onEditCommandID = { [weak self] id in
            self?.navigateSettings(.orders, anchor: CommandSettingsDeepLink.anchor(commandID: id))
        }
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
        host.view.autoresizingMask = [.width, .height]
        // Transparent host — the BridgeGlass surfaces draw the backing.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host.view
        self.hostingController = host
        return panel
    }

    // MARK: - Settings deep-link

    /// Trailing bridge-mark → bring the Bridge app to the FOREGROUND.
    /// PKT-1006 R3 (operator-resolved Q1): the icon brings the app to the
    /// front only — NOT Dashboard, NOT Settings. The prior implementation
    /// deep-linked to Orders/Commands settings via the fragile
    /// `NSApp.delegate as? AppDelegate` cast (which silently no-ops under
    /// `@NSApplicationDelegateAdaptor`, so the icon read as dead). We now route
    /// through the identity-correct `AppDelegate.shared` handle — the proven
    /// PKT-1005 pattern from `BridgeAutomationModule.liveAppDelegate()` — and
    /// call the dedicated `bringToFront()` foreground primitive.
    public func openCommandsSettings() {
        let app = AppDelegate.shared ?? (NSApp.delegate as? AppDelegate)
        app?.bringToFront()
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

    // ============================================================
    // MARK: - Multi-entity search (PKT-1006 R2)
    // ============================================================

    /// Build the live searchable entities the view-model ranks: Commands +
    /// Skills + Jobs + Tools. Pure-adapter — it reads the live stores and maps
    /// each into a `BridgeSearchEntity` carrying a typed destination. All the
    /// ranking/fuzzy/grouping lives in the pure `BridgeSearch` (unit-tested);
    /// this is only the store-read seam, so a store failure degrades to fewer
    /// entities rather than crashing the bar.
    public func buildSearchEntities() -> [BridgeSearchEntity] {
        var entities: [BridgeSearchEntity] = []

        // ── Commands (the historical bar contents) ──────────────────────
        let commands = (try? store.list()) ?? []
        for c in commands {
            entities.append(BridgeSearchEntity(
                kind: .command,
                id: c.slug,
                title: c.name,
                subtitle: CommandSearchCreate.searchSubtitle(
                    slot: c.keySlot,
                    body: c.body,
                    sensitivePaths: ConfigManager.shared.sensitivePaths
                ),
                destination: .command(slug: c.slug),
                recency: c.lastUsedAt
            ))
        }

        // ── Skills (open their SOURCE: notion / gdocs / file) ────────────
        let skills = SkillsManager().listSkills()
        for s in skills {
            entities.append(BridgeSearchEntity(
                kind: .skill,
                id: s.name,
                title: s.name,
                subtitle: s.platform.displayName,
                destination: Self.skillDestination(for: s)
            ))
        }

        // ── Tools (deep-link into Settings → Tools, open the grouping) ───
        let tools = AppDelegate.shared?.statusBar.toolInfoList ?? []
        for t in tools {
            let group = ModuleGroupDerivation.resolve(toolName: t.name).rawValue
            entities.append(BridgeSearchEntity(
                kind: .tool,
                id: t.name,
                title: t.name,
                subtitle: t.module,
                destination: .tool(group: group, tool: t.name)
            ))
        }

        return entities
    }

    /// Resolve a Skill into its typed source destination. The Skill model
    /// carries `source` (.notion(pageId) / .file(path)) + `platform`
    /// (.notion / .googleDocs / .manual) + an optional original `url`:
    ///   • .file source        → open the file
    ///   • .notion + a Google-Docs platform/URL → open the Google Doc
    ///   • .notion source       → open the Notion page
    ///   • otherwise (manual / no resolvable target) → Settings → Skills row
    public static func skillDestination(for skill: SkillsManager.Skill) -> BridgeSearchDestination {
        switch skill.source {
        case .file(let path):
            return .skillFile(path: path.path)
        case .notion(let pageId):
            if skill.platform == .googleDocs, let url = skill.url, !url.isEmpty {
                return .skillGoogleDoc(url: url)
            }
            if !pageId.isEmpty {
                return .skillNotion(pageId: pageId, url: skill.url)
            }
            if let url = skill.url, !url.isEmpty {
                // No page id but a URL we can open (e.g. a non-canonical link).
                return .skillGoogleDoc(url: url)
            }
            return .skillSettings(anchor: skill.name)
        }
    }

    /// Fire a typed search result's destination (R2). The single routing seam
    /// (one switch, not 4 ad-hoc branches). Commands insert-and-close exactly as
    /// before; skills open their source; jobs/tools deep-link into Settings via
    /// the identity-correct `AppDelegate.shared` + SettingsNavigation (PKT-1005
    /// plumbing). The bar is hidden after navigating so the destination has focus.
    public func fireDestination(_ destination: BridgeSearchDestination) {
        switch destination {
        case .command(let slug):
            fireSlug(slug)                 // insert body + close (existing path)

        case .skillNotion(let pageId, let url):
            openURLString(url ?? SkillPlatform.notion.canonicalURL(uuid: pageId)
                          ?? "https://www.notion.so/\(pageId.replacingOccurrences(of: "-", with: ""))")
            hide()

        case .skillGoogleDoc(let url):
            openURLString(url)
            hide()

        case .skillFile(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            hide()

        case .skillSettings(let anchor):
            navigateSettings(.skills, anchor: anchor)

        case .tool(let group, let tool):
            // Open the tool's GROUPING and scroll to the tool so it can be
            // toggled / permission-gated. The Tools section consumes the
            // "group:tool" anchor (opens the group, then scrolls to the row).
            navigateSettings(.tools, anchor: "\(group):\(tool)")
        }
    }

    /// Foreground the app + deep-link Settings to `section`/`anchor` via the
    /// identity-correct `AppDelegate.shared` (PKT-1005). Hides the bar after.
    private func navigateSettings(_ section: SettingsSection, anchor: String?) {
        SettingsNavigation.shared.go(section, anchor: anchor)
        let app = AppDelegate.shared ?? (NSApp.delegate as? AppDelegate)
        app?.openSettings(section: section)
        app?.bringToFront()
        hide()
    }

    /// Open a URL string in the default handler (browser / Notion app).
    private func openURLString(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
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
    /// (PKT-1006 R2) Multi-entity, typed, ranked search results — Commands +
    /// Skills + Jobs + Tools. Replaces the command-only `searchRows` as the
    /// search-mode model; `searchRows` stays only for back-compat with the
    /// recency builder + existing tests. Each result carries its kind (type tag
    /// + color), title/subtitle, and typed destination action.
    @Published public var searchResults: [BridgeSearchResult] = []
    /// Keyboard-selected row in the active panel (recents/search), by slug.
    /// ↓/↑ move it; Enter fires it. nil → no selection (closed tray).
    @Published public var selectedSlug: String? = nil
    /// (PKT-1006 R2) Keyboard-selected typed search result id ("<kind>:<id>").
    /// ↑/↓ move it across groups; Enter fires its destination. nil → none.
    @Published public var selectedResultID: String? = nil
    /// C0 Search favorite picker / Replace-Swap-Cancel prompt.
    @Published public var favoriteSession = FavoriteLayoutSession()
    /// C1 explicit create sheet. Nil means Search is not creating.
    @Published public var createAssessment: CommandCreateAssessment? = nil
    @Published public var createDraft = CommandCreateDraft()
    @Published public var createError: String? = nil
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
    /// (PKT-1006 R2) Fire a typed search result's destination (skill source /
    /// jobs deep-link / tools deep-link / command body). The controller wires
    /// the live router; default is a no-op for tests/shells.
    public var onFireDestination: (BridgeSearchDestination) -> Void = { _ in }
    public var onEscape: () -> Void = {}
    public var onSettings: () -> Void = {}
    /// (v3.7.6) Open the Dashboard popover. No longer fired from a pill glyph
    /// (the design `.cb-pill` has no leading mark); retained for the status-bar
    /// entry point that presents the same Dashboard surface.
    public var onBridgeMark: () -> Void = {}
    /// C1 Edit/Reveal: Settings deep-link by immutable command ID.
    public var onEditCommandID: (String) -> Void = { _ in }

    private let store: CommandStore
    private let recents: CommandBridgeRecents
    /// (PKT-1006 R2) Supplies the live searchable entities (Skills + Jobs +
    /// Tools, plus Commands) at query time. Injected by the controller, which
    /// owns the store coupling; defaults to an empty provider so the view-model
    /// stays pure + headlessly testable (no store I/O in this layer).
    private let entityProvider: () -> [BridgeSearchEntity]

    public init(
        store: CommandStore,
        recents: CommandBridgeRecents,
        entityProvider: @escaping () -> [BridgeSearchEntity] = { [] }
    ) {
        self.store = store
        self.recents = recents
        self.entityProvider = entityProvider
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
        let layout = (try? store.favoriteLayout()) ?? FavoriteLayout()
        if favoriteSession.current != layout && favoriteSession.pending == nil {
            favoriteSession.current = layout
        }
    }

    public func beginFavoritePicker(slug: String) {
        var session = favoriteSession
        session.openPicker(slug: slug)
        favoriteSession = session
    }

    public func cancelFavoritePrompt() {
        var session = favoriteSession
        if session.pending != nil {
            session.cancelPrompt()
        } else {
            session.closePicker()
        }
        favoriteSession = session
    }

    @discardableResult
    public func handleFavoriteDigit(_ displayOrStoreSlot: Int) -> Bool {
        if favoriteSession.pending != nil { return true }
        guard let slug = favoriteSession.pickerSlug else { return false }
        return assignFavorite(slug: slug, slot: displayOrStoreSlot)
    }

    public func assignFavorite(slug: String, slot: Int) -> Bool {
        var session = favoriteSession
        if let next = session.chooseSlot(slot, for: slug) {
            favoriteSession = session
            persistFavoriteLayout(next)
            return true
        }
        favoriteSession = session
        return favoriteSession.pending != nil
    }

    public func resolveFavoriteReplace() {
        var session = favoriteSession
        if let next = session.resolveReplace() {
            favoriteSession = session
            persistFavoriteLayout(next)
        }
    }

    public func resolveFavoriteSwap() {
        var session = favoriteSession
        if let next = session.resolveSwap() {
            favoriteSession = session
            persistFavoriteLayout(next)
        }
    }

    public func removeFavorite(slug: String) {
        var session = favoriteSession
        let next = session.remove(slug: slug)
        favoriteSession = session
        persistFavoriteLayout(next)
    }

    public func undoFavoriteLayout() {
        var session = favoriteSession
        if let previous = session.undo() {
            favoriteSession = session
            persistFavoriteLayout(previous, recordUndo: false)
        }
    }

    public func selectedCommandSlug() -> String? {
        guard let id = selectedResultID,
              let result = searchResults.first(where: { $0.id == id }),
              result.kind == .command
        else { return nil }
        return result.entityId
    }

    public func beginCreateFromQuery() {
        createDraft = CommandSearchCreate.draft(fromSearchText: query)
        createError = nil
        refreshCreateAssessment()
    }

    public func cancelCreate() {
        createAssessment = nil
        createError = nil
    }

    public func refreshCreateAssessment() {
        let existing = (try? store.list()) ?? []
        createAssessment = CommandSearchCreate.assess(
            draft: createDraft,
            existing: existing,
            sensitivePaths: ConfigManager.shared.sensitivePaths
        )
        createError = nil
    }

    @discardableResult
    public func confirmCreate() -> CommandStore.Command? {
        refreshCreateAssessment()
        guard let assessment = createAssessment, assessment.canProposeSave else { return nil }
        do {
            let created = try store.create(
                name: assessment.draft.trimmedName,
                icon: .emoji("✨"),
                body: assessment.draft.trimmedBody,
                keySlot: assessment.draft.keySlot
            )
            createAssessment = nil
            createError = nil
            reload()
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queryDidChange(query)
            }
            return created
        } catch {
            createError = error.localizedDescription
            return nil
        }
    }

    public func editCommand(slug: String) {
        guard let command = try? store.get(slug: slug), !command.id.isEmpty else { return }
        onEditCommandID(command.id)
    }

    public func duplicateCommand(slug: String) {
        guard let command = try? store.get(slug: slug) else { return }
        let names = ((try? store.list()) ?? []).map(\.name)
        let copy = CommandSearchCreate.duplicateBody(of: command, existingNames: names)
        createDraft = CommandCreateDraft(name: copy.name, body: copy.body)
        createError = nil
        refreshCreateAssessment()
    }

    public func revealCommand(slug: String) {
        editCommand(slug: slug)
    }

    public func commandDisplayName(_ slug: String) -> String {
        if let name = slotRows.compactMap(\.command).first(where: { $0.slug == slug })?.name {
            return name
        }
        if let name = recentRows.first(where: { $0.slug == slug })?.name {
            return name
        }
        if let title = searchResults.first(where: { $0.kind == .command && $0.entityId == slug })?.title {
            return title
        }
        return (try? store.get(slug: slug))?.name ?? slug
    }

    private func persistFavoriteLayout(_ layout: FavoriteLayout, recordUndo: Bool = true) {
        do {
            try store.applyFavoriteLayout(layout)
            if !recordUndo {
                favoriteSession.current = layout
            }
            favoriteSession = favoriteSession
            reload()
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queryDidChange(query)
            }
        } catch {
            favoriteSession = FavoriteLayoutSession(
                current: (try? store.favoriteLayout()) ?? FavoriteLayout()
            )
        }
    }

    /// Search-as-you-type. Empty query → panelMode = .none and rows hidden.
    /// Non-empty → (PKT-1006 R2) multi-entity ranked search across Commands +
    /// Skills + Jobs + Tools via `BridgeSearch.rankedResults` over the live
    /// entities supplied by `entityProvider`. The selection moves to the first
    /// result so ↑/↓/Enter work across groups with no mouse.
    public func queryDidChange(_ q: String) {
        self.query = q
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // typing-stopped path collapses back to whichever secondary
            // panel was last open (recents stays open if it was open).
            if case .search = panelMode {
                panelMode = .none
                selectedSlug = nil
                selectedResultID = nil
            }
            searchRows = []
            searchResults = []
            return
        }
        let entities = entityProvider()
        let results = BridgeSearch.rankedResults(query: trimmed, entities: entities)
        searchResults = results
        // Keep `searchRows` populated from the command hits only, for the
        // back-compat recency path + the existing command-only tests.
        searchRows = results
            .filter { $0.kind == .command }
            .map { Row(slug: $0.entityId, name: $0.title, icon: .symbol("command"),
                       color: nil, lastUsedAt: nil, keySlot: nil) }
        panelMode = .search(query: trimmed)
        selectedResultID = results.first?.id
        selectedSlug = results.first(where: { $0.kind == .command })?.entityId
    }

    /// ↓ → open recents (140ms slide-in handled by the view), selecting the
    /// first row so ↑/↓ can traverse and Enter fires it.
    public func openRecents() {
        if recentRows.isEmpty { return }
        panelMode = .recents
        selectedSlug = recentRows.first?.slug
    }

    /// Rows currently shown in the RECENTS panel (search mode uses the typed
    /// `searchResults` instead — see `moveSelection`/`commitSelected`).
    private var activeRows: [Row] {
        switch panelMode {
        case .recents: return recentRows
        case .search:  return searchRows
        case .none:    return []
        }
    }

    /// ↓ (+1) / ↑ (−1) move the keyboard selection within the open panel,
    /// clamped to the ends. ↓ from the closed tray opens recents. In search
    /// mode the selection traverses the typed `searchResults` ACROSS GROUPS
    /// (R2: commands → skills → jobs → tools as one flat keyboard list).
    public func moveSelection(_ delta: Int) {
        switch panelMode {
        case .none:
            if delta > 0 { openRecents() }
        case .search:
            guard !searchResults.isEmpty else { return }
            let cur = selectedResultID
                .flatMap { id in searchResults.firstIndex(where: { $0.id == id }) } ?? 0
            let next = min(max(cur + delta, 0), searchResults.count - 1)
            selectedResultID = searchResults[next].id
            // Mirror the command slug for the back-compat path when a command
            // row is selected (nil otherwise — non-command rows have no slug).
            let sel = searchResults[next]
            selectedSlug = sel.kind == .command ? sel.entityId : nil
        case .recents:
            let rows = recentRows
            guard !rows.isEmpty else { return }
            let cur = selectedSlug.flatMap { s in rows.firstIndex(where: { $0.slug == s }) } ?? 0
            let next = min(max(cur + delta, 0), rows.count - 1)
            selectedSlug = rows[next].slug
        }
    }

    /// Enter fires the keyboard-selected row. In SEARCH mode it fires the
    /// selected typed result's DESTINATION (skill source / job / tool / command),
    /// falling back to the first result. In RECENTS mode it fires the selected
    /// command by slug (unchanged).
    public func commitSelected() {
        switch panelMode {
        case .search:
            guard !searchResults.isEmpty else { return }
            let result = selectedResultID
                .flatMap { id in searchResults.first(where: { $0.id == id }) }
                ?? searchResults.first
            if let result { onFireDestination(result.destination) }
        case .recents:
            let rows = recentRows
            guard !rows.isEmpty else { return }
            let slug = selectedSlug.flatMap { s in rows.contains(where: { $0.slug == s }) ? s : nil }
                ?? rows.first?.slug
            if let slug { onFireSlug(slug) }
        case .none:
            break
        }
    }

    /// Esc / focus-loss / fire → reset to closed-tray state.
    public func resetToTray() {
        query = ""
        searchRows = []
        searchResults = []
        selectedResultID = nil
        panelMode = .none
        cancelCreate()
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
    // (PKT-1006 R4c · operator-resolved Q3) True while the window is being
    // dragged. The self-legibility text shadows (placeholder NSShadow + field
    // layer.shadow + the SwiftUI .legibilityHalo()) re-render every
    // windowDrag.onChanged (setFrameOrigin from the live mouse) — that re-render
    // is the "Bridge Command" shimmer. We KEEP the shadows but FREEZE them while
    // dragging by rasterizing the haloed text into a stable layer (no per-frame
    // shadow recompute), then release it on drag end.
    @State private var isDraggingWindow = false
    @State private var hoveredSearchID: String?

    private var anim: CommandBridgeAnimation {
        reduceMotion ? .reduced : .locked
    }

    /// Idle 260; create sheet expands so Save/Cancel are not clipped (CB-1).
    private var activeHostHeight: CGFloat {
        CommandBridgeChrome.hostHeight(createSheetOpen: model.createAssessment != nil)
    }

    public init(model: CommandBridgeViewModel) {
        self.model = model
    }

    /// Grow/shrink the hosting panel downward, keeping the top edge where the
    /// operator last placed it.
    private func syncPaletteHostSize() {
        guard let win = paletteWindow else { return }
        let target = CommandBridgeChrome.frameKeepingTop(
            current: win.frame,
            newHeight: activeHostHeight
        )
        guard abs(target.height - win.frame.height) > 0.5 else { return }
        win.setFrame(target, display: true, animate: false)
    }

    public var body: some View {
        // Visual-pass 2026-07-23: discrete glass pieces only (tiles + bar +
        // optional results). No footer hints. No whole-stack scale (group plate
        // on white). Content-hug host; opacity-led open; bar alone micro-scales.
        ZStack(alignment: .top) {
            Color.clear
            VStack(spacing: BridgeTokens.Space.s2) {
                tray
                pill
                    .scaleEffect(model.didOpen ? 1.0 : anim.openStartScale)
                if case .none = model.panelMode {
                    EmptyView()
                } else {
                    secondaryPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 0)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .opacity(model.didOpen ? 1.0 : anim.openStartOpacity)
            .animation(.easeOut(duration: anim.openDuration), value: model.didOpen)
            .animation(.easeOut(duration: anim.recentsSlideDuration), value: panelModeKey)
        }
        .frame(width: CommandBridgeChrome.hostWidth,
               height: activeHostHeight,
               alignment: .top)
        .onChange(of: model.createAssessment != nil) { _, _ in
            syncPaletteHostSize()
        }
        .onChange(of: paletteWindow != nil) { _, _ in
            syncPaletteHostSize()
        }
        // (PKT-1006 R4c) Publish the drag state so the legibility halos freeze
        // (rasterize) while the window moves instead of shimmering.
        .environment(\.cbIsDragging, isDraggingWindow)
        // (v4 round-3) Capture the hosting window + make the whole palette
        // draggable. simultaneousGesture so taps on the orbs / menu mark still
        // fire and the field still focuses; a >3pt drag on the glass repositions.
        .background(WindowAccessor { paletteWindow = $0 })
        .simultaneousGesture(windowDrag)
        .background(KeyHandler(
            onNumber: { n in
                if model.createAssessment != nil { return }
                if model.handleFavoriteDigit(n) { return }
                model.onFireSlot(n)
            },
            onOptionNumber: { n in
                if model.createAssessment != nil { return }
                if let slug = model.selectedCommandSlug() {
                    _ = model.assignFavorite(slug: slug, slot: n)
                }
            },
            onArrowDown: { model.moveSelection(1) },
            onArrowUp: { model.moveSelection(-1) },
            onReturn: { commitTopSelection() },
            onEscape: { handleSearchEscape() },
            onCreateShortcut: { model.beginCreateFromQuery() }
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
                    // (R4c) Enter drag-stabilized mode on the first move — freeze
                    // the legibility halos so they don't shimmer as the window moves.
                    if !isDraggingWindow { isDraggingWindow = true }
                }
                if let off = dragMouseOffset {
                    win.setFrameOrigin(CGPoint(x: mouse.x - off.width,
                                               y: mouse.y - off.height))
                }
            }
            .onEnded { _ in
                dragMouseOffset = nil
                // (R4c) Release the frozen halos — back to live self-legible text.
                isDraggingWindow = false
            }
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
        // Only assigned favorites, centered; width tracks count (adaptive).
        let favorites = model.slotRows.filter { $0.command != nil }
        return HStack(spacing: 8) {
            ForEach(Array(favorites.enumerated()), id: \.element.id) { idx, row in
                slotView(row, cascadeIndex: idx)
            }
        }
        .frame(width: paletteWidth)
    }

    @ViewBuilder
    private func slotView(_ row: CommandBridgeViewModel.SlotRow, cascadeIndex: Int) -> some View {
        if let cmd = row.command {
            Button { model.onFireSlot(row.storeSlot) } label: {
                favoriteTile(cmd: cmd, displayKey: row.displayKey)
            }
            .buttonStyle(.plain)
            .frame(width: CommandBridgeChrome.tileSize, height: CommandBridgeChrome.tileSize)
            .contentShape(RoundedRectangle(cornerRadius: CommandBridgeChrome.tileCornerRadius, style: .continuous))
            .contextMenu {
                Button("Edit") { model.editCommand(slug: cmd.slug) }
                Button("Duplicate") { model.duplicateCommand(slug: cmd.slug) }
                Button("Reveal in Settings") { model.revealCommand(slug: cmd.slug) }
                Divider()
                Button("Move to slot…") { model.beginFavoritePicker(slug: cmd.slug) }
                Button("Remove favorite") { model.removeFavorite(slug: cmd.slug) }
                if model.favoriteSession.canUndo {
                    Button("Undo favorite change") { model.undoFavoriteLayout() }
                }
            }
            // Co-born with bar: opacity only (no under-keycap, no group scale).
            .opacity(model.didOpen ? 1.0 : 0.0)
            .animation(
                .easeOut(duration: anim.openDuration)
                .delay(Double(cascadeIndex) * anim.bubbleCascadeStagger),
                value: model.didOpen
            )
        }
    }

    /// Spotlight-rhyme favorite tile: shared glass recipe, squircle, digit inside.
    private func favoriteTile(cmd: CommandStore.Command, displayKey: Int) -> some View {
        let r = CommandBridgeChrome.tileCornerRadius
        let size = CommandBridgeChrome.tileSize
        return ZStack(alignment: .bottom) {
            iconView(for: cmd.icon, color: cmd.color, size: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 8)
            Text("\(displayKey)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.88))
                .legibilityHalo()
                .padding(.bottom, 4)
        }
        .frame(width: size, height: size)
        .commandBridgeGlass(radius: r)
        .accessibilityLabel("\(cmd.name), key \(displayKey)")
    }
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
                    focusToken: model.focusToken,
                    onReturn: { commitTopSelection() },
                    onArrowDown: { model.moveSelection(1) },
                    onArrowUp: { model.moveSelection(-1) },
                    onEscape: { handleSearchEscape() },
                    onCreateShortcut: { model.beginCreateFromQuery() }
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
                    .frame(width: 20, height: 20)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(BridgeTokens.glassControl)
                            .bridgeBevel(BridgeTokens.bevelControl, radius: 10)
                    )
            }
            .buttonStyle(.plain)
            .help("Bring The Bridge to the front")
        }
        .padding(.leading, BridgeTokens.Space.s5)
        .padding(.trailing, BridgeTokens.Space.s3)
        .frame(width: paletteWidth, height: CommandBridgeChrome.pillHeight)
        .commandBridgeGlass(radius: CommandBridgeChrome.barCornerRadius)
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
    /// from `TheBridgeLib`, where this view compiles). At runtime the
    /// packaged `.app` deposits it in the main bundle's Resources + Assets.car,
    /// so `Bundle.main` resolves it; `NSImage(named:)` is the final fallback.
    /// Loaded once and cached. `nil` headlessly → the SF Symbol fallback shows.
    private static let bridgeMarkImage: NSImage? = {
        let img = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(named: "MenuBarIcon")
        img?.isTemplate = true
        return img
    }()

    // Footer hint rail removed (visual-pass 2026-07-23): discover by use;
    // KeyHandler still owns 1–0 / ↑↓ / ↵ / Esc.

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
                // (PKT-1006 R2) Typed, grouped, multi-entity results. Each kind
                // gets its own section header; rows carry a type tag + color.
                let grouped = Dictionary(grouping: model.searchResults, by: { $0.kind })
                let kinds = grouped.keys.sorted { $0.groupOrder < $1.groupOrder }
                ForEach(kinds, id: \.self) { kind in
                    panelHeader(kind.groupHeader)
                    ForEach(grouped[kind] ?? []) { result in
                        resultRow(result,
                                  selected: result.id == model.selectedResultID,
                                  highlight: q)
                    }
                }
                if model.searchResults.isEmpty {
                    panelEmptyHint("No match for \"\(q)\".")
                }
                if !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   model.createAssessment == nil {
                    Button {
                        model.beginCreateFromQuery()
                    } label: {
                        HStack(spacing: BridgeTokens.Space.s3) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BridgeTokens.fg3)
                            Text("Create command from this text")
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg2)
                            Spacer(minLength: 0)
                            Text("⌥↩")
                                .font(BridgeTokens.Typeface.micro)
                                .foregroundStyle(BridgeTokens.fg5)
                        }
                        .padding(.horizontal, BridgeTokens.Space.s3)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open the create sheet. Ordinary Return never saves.")
                    .accessibilityLabel("Create command from this text")
                }
                if model.createAssessment != nil {
                    createCommandSheet
                }
                if let pickerSlug = model.favoriteSession.pickerSlug,
                   model.favoriteSession.pending == nil {
                    favoriteSlotPicker(slug: pickerSlug)
                }
                if let prompt = model.favoriteSession.pending {
                    favoriteConflictPrompt(prompt)
                }
            }
        }
        .padding(BridgeTokens.Space.s2)
        .frame(width: paletteWidth)
        .commandBridgeGlass(radius: CommandBridgeChrome.panelCornerRadius)
    }

    /// Panel section header (`.cb-phead`) — an uppercase cap micro-caption.
    private func panelHeader(_ s: String) -> some View {
        Text(s)
            .bridgeCap()
            .foregroundStyle(BridgeTokens.fg5)
            .legibilityHalo()
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
                    .legibilityHalo()

                Spacer(minLength: BridgeTokens.Space.s1)

                Text(Self.relativeHint(for: r.lastUsedAt))
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg5)
                    .legibilityHalo()

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

    /// (PKT-1006 R2) A typed multi-entity result row — a COLOR indicator dot +
    /// the title (match-highlighted) + an optional dim subtitle + a TYPE TAG
    /// chip (CMD/SKILL/JOB/TOOL) tinted to the kind's color. Selecting it fires
    /// the typed destination (skill source / jobs deep-link / tools deep-link /
    /// command body) with zero mouse.
    @ViewBuilder
    private func resultRow(_ result: BridgeSearchResult,
                           selected: Bool,
                           highlight: String) -> some View {
        let kindColor = NotionPalette.color(named: result.kind.colorTag) ?? BridgeTokens.fg2
        let isCommand = result.kind == .command
        let slot = isCommand ? model.favoriteSession.current.slot(of: result.entityId) : nil
        let showStar = isCommand && (
            selected
            || hoveredSearchID == result.id
            || slot != nil
            || model.favoriteSession.pickerSlug == result.entityId
        )
        HStack(spacing: 0) {
            Button {
                model.onFireDestination(result.destination)
            } label: {
                HStack(spacing: BridgeTokens.Space.s4 - 2) {
                    Circle()
                        .fill(kindColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: kindColor.opacity(0.6), radius: 2.5)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        highlightedName(result.title, query: highlight)
                            .font(BridgeTokens.Typeface.name)
                            .foregroundStyle(BridgeTokens.fg1)
                            .lineLimit(1)
                            .legibilityHalo()
                        if let subtitle = result.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(BridgeTokens.Typeface.meta)
                                .foregroundStyle(BridgeTokens.fg5)
                                .lineLimit(1)
                                .legibilityHalo()
                        }
                    }

                    Spacer(minLength: BridgeTokens.Space.s1)

                    Text(result.kind.tag)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(kindColor)
                        .padding(.horizontal, BridgeTokens.Space.s2)
                        .frame(minHeight: 18)
                        .background(
                            Capsule(style: .continuous)
                                .fill(kindColor.opacity(0.16))
                                .overlay(Capsule(style: .continuous)
                                    .strokeBorder(kindColor.opacity(0.34), lineWidth: 0.5))
                        )
                }
                .padding(.leading, BridgeTokens.Space.s3)
                .padding(.trailing, showStar ? BridgeTokens.Space.s1 : BridgeTokens.Space.s3)
                .frame(height: 46)
                .background(rowBackground(selected: selected))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isCommand {
                favoriteStar(slug: result.entityId, slot: slot, visible: showStar)
            }
        }
        .onHover { hovering in
            hoveredSearchID = hovering ? result.id : (hoveredSearchID == result.id ? nil : hoveredSearchID)
        }
        .contextMenu {
            if isCommand {
                Button("Edit") { model.editCommand(slug: result.entityId) }
                Button("Duplicate") { model.duplicateCommand(slug: result.entityId) }
                Button("Reveal in Settings") { model.revealCommand(slug: result.entityId) }
                Divider()
                Button("Move to slot…") { model.beginFavoritePicker(slug: result.entityId) }
                if slot != nil {
                    Button("Remove favorite") { model.removeFavorite(slug: result.entityId) }
                }
                if model.favoriteSession.canUndo {
                    Button("Undo favorite change") { model.undoFavoriteLayout() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(result.title)
        .accessibilityValue(slot.map { "Favorite slot \($0)" } ?? (isCommand ? "Not favorited" : result.kind.tag))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func favoriteStar(slug: String, slot: Int?, visible: Bool) -> some View {
        Button {
            model.beginFavoritePicker(slug: slug)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: slot == nil ? "star" : "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(slot == nil ? BridgeTokens.fg4 : BridgeTokens.gold)
                if let slot {
                    Text(String(slot))
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(BridgeTokens.fg2)
                }
            }
            .frame(width: 36, height: 46)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .accessibilityLabel(slot == nil ? "Add favorite" : "Favorite slot \(slot!)")
        }
        .buttonStyle(.plain)
        .disabled(!visible)
        .help(slot == nil ? "Assign a favorite slot" : "Change or remove favorite slot")
    }

    @ViewBuilder
    private func favoriteSlotPicker(slug: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favorite slot for \(model.commandDisplayName(slug))")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg3)
            HStack(spacing: 4) {
                ForEach(FavoriteLayout.displayOrder, id: \.self) { slot in
                    let taken = model.favoriteSession.current.slug(in: slot)
                    Button {
                        _ = model.assignFavorite(slug: slug, slot: slot)
                    } label: {
                        Text(String(slot))
                            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(taken == slug ? BridgeTokens.glassControl : BridgeTokens.wellFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(taken == nil || taken == slug
                          ? "Slot \(slot)"
                          : "Slot \(slot) occupied by \(model.commandDisplayName(taken!))")
                    .accessibilityLabel(taken == nil || taken == slug
                                        ? "Favorite slot \(slot)"
                                        : "Favorite slot \(slot), occupied by \(model.commandDisplayName(taken!))")
                }
            }
        }
        .padding(BridgeTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose favorite slot 1 through 0")
    }

    @ViewBuilder
    private func favoriteConflictPrompt(_ prompt: FavoriteConflictPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assigning \(model.commandDisplayName(prompt.slug)) to slot \(prompt.slot) would displace \(model.commandDisplayName(prompt.occupiedBy)).")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg2)
            HStack(spacing: 8) {
                Button("Replace") { model.resolveFavoriteReplace() }
                if prompt.swap != nil {
                    Button("Swap") { model.resolveFavoriteSwap() }
                }
                Button("Cancel") { model.cancelFavoritePrompt() }
            }
        }
        .padding(BridgeTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replace, swap, or cancel favorite assignment")
    }

    @ViewBuilder
    private var createCommandSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create command")
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg3)
            TextField("Name", text: Binding(
                get: { model.createDraft.name },
                set: { model.createDraft.name = $0; model.refreshCreateAssessment() }
            ))
            .textFieldStyle(.plain)
            .font(BridgeTokens.Typeface.name)
            .foregroundStyle(BridgeTokens.fg1)
            .padding(.horizontal, BridgeTokens.Space.s2)
            .frame(height: 28)
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            ZStack(alignment: .topLeading) {
                if model.createDraft.body.isEmpty {
                    Text("Body (optional)")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { model.createDraft.body },
                    set: { model.createDraft.body = $0; model.refreshCreateAssessment() }
                ))
                .font(BridgeTokens.Typeface.meta)
                .foregroundStyle(BridgeTokens.fg2)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 96)
                .padding(4)
            }
            .background(BridgeTokens.wellFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Toggle("Treat as sensitive", isOn: Binding(
                get: { model.createDraft.sensitive },
                set: { model.createDraft.sensitive = $0; model.refreshCreateAssessment() }
            ))
            .font(BridgeTokens.Typeface.meta)
            .foregroundStyle(BridgeTokens.fg3)
            .toggleStyle(.checkbox)
            HStack(spacing: 4) {
                Text("Slot")
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg5)
                ForEach(FavoriteLayout.displayOrder, id: \.self) { slot in
                    let selected = model.createDraft.keySlot == slot
                    Button {
                        model.createDraft.keySlot = selected ? nil : slot
                        model.refreshCreateAssessment()
                    } label: {
                        Text(String(slot))
                            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? BridgeTokens.glassControl : BridgeTokens.wellFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Optional favorite slot \(slot)")
                }
            }
            if let assessment = model.createAssessment {
                ForEach(Array(assessment.duplicates.enumerated()), id: \.offset) { _, dup in
                    HStack(alignment: .top, spacing: 8) {
                        Text(duplicateWarning(dup))
                            .font(BridgeTokens.Typeface.meta)
                            .foregroundStyle(BridgeTokens.fg2)
                        if case .exactSlug(let slug) = dup {
                            Button("Edit existing") { model.editCommand(slug: slug) }
                        } else if case .exactName(let slug) = dup {
                            Button("Edit existing") { model.editCommand(slug: slug) }
                        } else if case .nearName(let slug) = dup {
                            Button("Open similar") { model.editCommand(slug: slug) }
                        }
                    }
                }
                if !assessment.sensitiveHits.isEmpty {
                    Text("Sensitive path warning: \(assessment.sensitiveHits.joined(separator: ", ")). Body previews stay suppressed.")
                        .font(BridgeTokens.Typeface.meta)
                        .foregroundStyle(BridgeTokens.fg2)
                }
            }
            if let error = model.createError {
                Text(error)
                    .font(BridgeTokens.Typeface.meta)
                    .foregroundStyle(BridgeTokens.fg2)
            }
            HStack(spacing: 8) {
                Button("Save") { _ = model.confirmCreate() }
                    .disabled(!(model.createAssessment?.canProposeSave ?? false))
                Button("Cancel") { model.cancelCreate() }
            }
        }
        .padding(BridgeTokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create command sheet")
    }

    private func duplicateWarning(_ dup: CommandCreateDuplicate) -> String {
        switch dup {
        case .exactSlug(let slug):
            return "A command already uses this identity (\(model.commandDisplayName(slug)))."
        case .exactName(let slug):
            return "A command already has this name (\(model.commandDisplayName(slug)))."
        case .nearName(let slug):
            return "Similar to \(model.commandDisplayName(slug))."
        }
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

    /// Fires the keyboard-selected row (↑/↓), falling back to the first.
    /// Ordinary Return never opens or saves a create sheet.
    private func commitTopSelection() {
        if model.createAssessment != nil { return }
        model.commitSelected()
    }

    private func handleSearchEscape() {
        if model.createAssessment != nil {
            model.cancelCreate()
        } else if model.favoriteSession.pickerSlug != nil || model.favoriteSession.pending != nil {
            model.cancelFavoritePrompt()
        } else {
            model.onEscape()
        }
    }
}

// ============================================================
// MARK: - 7b. Shared Command Bridge glass (bar + tiles + results)
//
//   ONE recipe for every floating chrome piece (visual-pass 2026-07-23):
//     • `.regularMaterial` under `.ultraThinMaterial` — more look-through body
//       than pure air, without a continuous grey plate between pieces.
//     • Even top sheen + hairline + soft float shadow (budgeted — not e2 fog).
//     • Continuous rounded-rect; caller picks radius (bar 14 / tile 12).
// ============================================================

private struct CommandBridgeGlassModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isDark = colorScheme == .dark
        return content
            .background {
                ZStack {
                    // Body frost — Spotlight-rhyme depth without a solid fill plate.
                    shape.fill(.regularMaterial.opacity(isDark ? 0.55 : 0.72))
                    shape.fill(.ultraThinMaterial)
                    // Even top sheen (utilitarian glass, not a lens dome).
                    shape.fill(LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(isDark ? 0.16 : 0.34), location: 0.0),
                            .init(color: .clear, location: 0.32),
                        ]),
                        startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(shape.strokeBorder(
                Color.primary.opacity(isDark ? 0.22 : 0.12), lineWidth: 0.5)
                .allowsHitTesting(false))
            .clipShape(shape)
            .shadow(
                color: .black.opacity(isDark ? 0.32 : 0.14),
                radius: CommandBridgeChrome.glassShadowRadius,
                y: CommandBridgeChrome.glassShadowY
            )
    }
}

private extension View {
    /// Shared bar/tile/panel glass at `radius` (CommandBridgeChrome recipe).
    func commandBridgeGlass(radius: CGFloat) -> some View {
        modifier(CommandBridgeGlassModifier(radius: radius))
    }

    /// Back-compat alias — same recipe.
    func popoverGlass(radius: CGFloat) -> some View {
        commandBridgeGlass(radius: radius)
    }
}

// ── Text legibility halo (v4 round-3) ──────────────────────────────────────
//
//   The pill/panel container is near-invisible now (operator round-3 chose
//   "self-legible text"), so the text carries its OWN legibility — a subtle
//   theme-aware halo lets it read on ANY backdrop (white, busy, dark): a dark
//   halo in dark mode (white ink → reads on light backdrops), a light halo in
//   light mode (dark ink → reads on dark backdrops). On a matching backdrop the
//   halo is imperceptible. No container is reintroduced.
/// (PKT-1006 R4c) Environment flag — true while the palette window is being
/// dragged. The legibility halos read it and FREEZE (rasterize) so they don't
/// shimmer/re-render as the window moves (operator-resolved Q3: keep the
/// shadows, stabilize during drag).
private struct CBIsDraggingKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var cbIsDragging: Bool {
        get { self[CBIsDraggingKey.self] }
        set { self[CBIsDraggingKey.self] = newValue }
    }
}

private struct LegibilityHalo: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cbIsDragging) private var isDragging
    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let haloed = content.shadow(
            color: (isDark ? Color.black : Color.white).opacity(isDark ? 0.55 : 0.6),
            radius: 2.5, x: 0, y: 0.5)
        // (R4c) While dragging, flatten the haloed text into a single GPU layer
        // (`.drawingGroup()`) so the window move translates a STABLE bitmap
        // rather than re-compositing the text shadow every frame — the shadow is
        // intact, just frozen, so the shimmer stops. Released (live) when idle.
        return Group {
            if isDragging {
                haloed.drawingGroup()
            } else {
                haloed
            }
        }
    }
}

private extension View {
    func legibilityHalo() -> some View { modifier(LegibilityHalo()) }
}

// ============================================================
// MARK: - 8. QueryField — plain NSTextField bridge with key hooks
// ============================================================

private struct QueryField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    /// (PKT-1006 R1) Monotonic focus token. The controller bumps it on EVERY
    /// `show()`; this representable claims first responder whenever the value it
    /// last applied differs from the current one. Driving focus off a token that
    /// ALWAYS changes (rather than the `isFocused` boolean, which is already
    /// `true` on a reused panel so its `.onChange` never re-fires) is what makes
    /// re-open focus deterministic.
    var focusToken: Int
    var onReturn: () -> Void
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onEscape: () -> Void
    var onCreateShortcut: () -> Void

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
        // (v4 round-3) Self-legibility: the container is near-invisible now, so the
        // placeholder carries its own contrast — ink raised to 42% + a soft dark
        // shadow so "Bridge Command" reads even over a light backdrop.
        let placeholderShadow = NSShadow()
        placeholderShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        placeholderShadow.shadowBlurRadius = 3
        placeholderShadow.shadowOffset = NSSize(width: 0, height: -1)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: monoFont,
                .foregroundColor: BridgeTokens.adaptiveNSColor(
                    dark:  { BridgeTokens.whiteAlpha(0.42) },
                    light: { BridgeTokens.blackAlpha(0.42) }
                ),
                .shadow: placeholderShadow,
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
        // (v4 round-3) Self-legibility for the typed text — a soft dark layer shadow
        // halos the glyphs (the field bg is clear, so only the text casts it).
        // Reads on white, subtle on dark; no container substrate needed.
        field.wantsLayer = true
        field.layer?.shadowColor = NSColor.black.cgColor
        field.layer?.shadowOpacity = 0.45
        field.layer?.shadowRadius = 2.5
        field.layer?.shadowOffset = .zero
        field.layer?.masksToBounds = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        // (PKT-1006 R4c) Freeze the field's self-legibility layer shadow while the
        // window is dragging — rasterize the layer so its shadow is cached and
        // translates as a stable bitmap rather than re-rendering every frame (the
        // shimmer). The shadow stays intact; it's just frozen. Released when idle.
        if let layer = nsView.layer {
            let dragging = context.environment.cbIsDragging
            if layer.shouldRasterize != dragging {
                layer.rasterizationScale = nsView.window?.backingScaleFactor ?? 2.0
                layer.shouldRasterize = dragging
            }
        }
        // (PKT-1006 R1) Re-claim first responder whenever the controller bumps
        // the focus token. The token strictly increases on every show(), so a
        // reused-panel re-open ALWAYS lands here (the old `isFocused` boolean
        // was already `true`, so its `.onChange` never re-fired and the field
        // stayed unfocused). `claimFocus` retries on the next runloop until the
        // panel is actually the key window, fixing the async-vs-panel-key race.
        if context.coordinator.lastAppliedFocusToken != focusToken {
            context.coordinator.lastAppliedFocusToken = focusToken
            claimFocus(nsView, attemptsRemaining: 12)
        }
    }

    /// Make `field` first responder once its window is key. The makeFirstResponder
    /// from `show()` used to fire a single `DispatchQueue.main.async` that could
    /// land BEFORE `makeKeyAndOrderFront` made the panel key — the WindowServer
    /// then rejects the focus and the field stays dead. This retries on the main
    /// runloop (cheap, bounded) until the window is key, then focuses exactly once.
    private func claimFocus(_ field: NSTextField, attemptsRemaining: Int) {
        guard let window = field.window else {
            // Not yet in a window — try again shortly (the panel is being shown).
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { claimFocus(field, attemptsRemaining: attemptsRemaining - 1) }
            return
        }
        guard window.isKeyWindow else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { claimFocus(field, attemptsRemaining: attemptsRemaining - 1) }
            return
        }
        // Already first responder (the field editor descends from the field) → done.
        if let fr = window.firstResponder as? NSView, fr === field || fr.isDescendant(of: field) {
            return
        }
        window.makeFirstResponder(field)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QueryField
        /// (PKT-1006 R1) The focus token most recently applied, so `updateNSView`
        /// only re-claims focus on an actual token change (not on every SwiftUI
        /// invalidation, which would steal focus mid-typing / mid-drag).
        var lastAppliedFocusToken: Int = 0
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
                let mods = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if mods.contains(.option) || mods.contains(.command) {
                    parent.onCreateShortcut(); return true
                }
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
    let onOptionNumber: (Int) -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void
    let onCreateShortcut: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onNumber = onNumber
        v.onOptionNumber = onOptionNumber
        v.onArrowDown = onArrowDown
        v.onArrowUp = onArrowUp
        v.onReturn = onReturn
        v.onEscape = onEscape
        v.onCreateShortcut = onCreateShortcut
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? MonitorView else { return }
        v.onNumber = onNumber
        v.onOptionNumber = onOptionNumber
        v.onArrowDown = onArrowDown
        v.onArrowUp = onArrowUp
        v.onReturn = onReturn
        v.onEscape = onEscape
        v.onCreateShortcut = onCreateShortcut
    }

    final class MonitorView: NSView {
        var onNumber: ((Int) -> Void)?
        var onOptionNumber: ((Int) -> Void)?
        var onArrowDown: (() -> Void)?
        var onArrowUp: (() -> Void)?
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        var onCreateShortcut: (() -> Void)?
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
                guard self.window?.isKeyWindow == true else { return event }
                if Self.consumeCreateShortcut(event, fire: self) { return nil }
                if Self.consumeOptionNumber(event, fire: self) { return nil }
                let isFieldEditor = (self.window?.firstResponder is NSText)
                if !isFieldEditor || (event.charactersIgnoringModifiers?.isEmpty ?? true) {
                    if Self.consume(event, fire: self) { return nil }
                } else if let text = self.window?.firstResponder as? NSText,
                          text.string.isEmpty {
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

        static func consumeCreateShortcut(_ event: NSEvent, fire v: MonitorView) -> Bool {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isReturn = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
            if isReturn,
               mods.contains(.option),
               !mods.contains(.command),
               !mods.contains(.control) {
                v.onCreateShortcut?()
                return true
            }
            if mods.contains(.command),
               !mods.contains(.option),
               !mods.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "n" {
                v.onCreateShortcut?()
                return true
            }
            return false
        }

        static func consumeOptionNumber(_ event: NSEvent, fire v: MonitorView) -> Bool {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.option),
                  !mods.contains(.command),
                  !mods.contains(.control),
                  let chars = event.charactersIgnoringModifiers,
                  chars.count == 1,
                  let digit = chars.first?.wholeNumberValue,
                  (0...9).contains(digit)
            else { return false }
            v.onOptionNumber?(digit)
            return true
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
