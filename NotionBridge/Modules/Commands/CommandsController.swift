// CommandsController.swift — cmd-ux W1 (single observable source of truth)
// NotionBridge · Modules · Commands
//
// THE single @Observable source of truth for the Commands palette's
// Settings-facing state. Before this, the Settings view read the
// AppDelegate via two plain computed vars (`commandsPaletteRegistered`,
// `commandsHotkeyConfig`) that were snapshotted ONCE at body-eval and
// never re-read — so the status row could say "⚠ Shortcut unavailable"
// while the hot-key worked fine (Bug 2: non-reactivity). This class
// fixes that structurally: it is `@Observable`, the AppDelegate owns
// exactly one instance and pushes every registration / hotkey / enabled
// transition INTO it, and `SettingsView` reads it via `@Environment` so
// SwiftUI re-renders the status row the instant the observed state moves.
//
// The AppDelegate's existing public method signatures
// (`setCommandsPaletteEnabled`, `setCommandsHotkey`,
// `isCommandsPaletteHotkeyRegistered`, `commandsHotkeyConfig`) are
// PRESERVED — their bodies now delegate into this controller so existing
// call sites and tests keep working unchanged.
//
// PURE / HEADLESSLY-TESTED: the observable state machine here
// (enable/disable, setHotkey success/failure → isRegistered +
// lastRegisterStatus, persistence interaction) is exercised through an
// injected `Registrar` seam in the test harness with NO Carbon, NO
// NSApp, NO WindowServer. The real Carbon `RegisterEventHotKey` firing
// remains the documented operator-smoke ceiling (see CommandBox.swift),
// but the controller's reaction to a register RESULT is fully unit-tested.

import Foundation

// ============================================================
// MARK: - HotkeyRegisterStatus (pure register-outcome model)
// ============================================================

/// The outcome of the last attempt to register the Commands global
/// hot-key. W2 fills the collision/plumbing distinction; W1 establishes
/// the carrier so the observable state machine and the pure
/// `CommandsSettingsStatus` mapping can be unit-tested over it now.
///
/// Pure value type — no Carbon, no AppKit — so every state is
/// deterministically asserted headlessly.
public enum HotkeyRegisterStatus: Sendable, Equatable {
    /// No registration has been attempted yet (palette never started, or
    /// disabled before any attempt).
    case unattempted
    /// The combo registered successfully and is live.
    case registered
    /// The combo is owned by another app (Carbon `eventHotKeyExistsErr`
    /// / a non-noErr `RegisterEventHotKey`) — a TRUE collision. Carries
    /// the raw OSStatus (W2) so a genuine collision is distinguishable
    /// from a plumbing failure.
    case collision(osStatus: Int32)
    /// A plumbing failure (the Carbon `InstallEventHandler` step failed,
    /// or a modifier-less combo was refused) — NOT a real combo
    /// collision. W2 surfaces the real status.
    case plumbingFailure(osStatus: Int32)

    /// Convenience: did the most recent attempt actually register?
    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

// ============================================================
// MARK: - RecorderFocusModel (pure recorder focus state, cmd-ux W2)
//
//   The hot-key recorder field's focus/recording state machine, factored
//   OUT of the AppKit NSView so the click-to-record / Escape-exits /
//   accepted-vs-rejected transitions are unit-tested with NO NSEvent and
//   NO WindowServer. The NSView consumes this; the raw `NSEvent` capture
//   gesture itself remains the documented operator-smoke ceiling.
// ============================================================

/// Pure state for the recorder control: is it capturing, and may it
/// become first responder. `acceptsFirstResponder` is true ⟺ recording —
/// so a click that enters recording also makes the field focusable
/// STANDALONE (the Bug-1 structural fix: focus no longer depends on a
/// best-effort async makeFirstResponder from a separate SwiftUI Button).
public struct RecorderFocusModel: Sendable, Equatable {
    /// Whether the field is currently capturing the next chord.
    public private(set) var isRecording: Bool

    public init(isRecording: Bool = false) {
        self.isRecording = isRecording
    }

    /// AppKit `acceptsFirstResponder` must be true while recording so the
    /// WindowServer routes key-downs to the field. (Before: only true
    /// while `isRecording`, and the ONLY focus path was a fragile async
    /// makeFirstResponder — Bug 1.)
    public var acceptsFirstResponder: Bool { isRecording }

    /// A mouse click on the field enters recording — the standalone
    /// focus path (no dependence on the secondary button).
    public mutating func clickToRecord() { isRecording = true }

    /// The secondary "Record shortcut" button path (kept as a belt).
    public mutating func setRecording(_ on: Bool) { isRecording = on }

    /// Escape while recording cancels capture without changing the bind.
    public mutating func escape() { isRecording = false }

    /// A chord was captured. An accepted (valid modifier+key) chord ends
    /// capture; a rejected one (modifier-less / pure-modifier) keeps the
    /// field recording so the user can immediately try again.
    public mutating func captured(accepted: Bool) {
        if accepted { isRecording = false }
    }
}

// ============================================================
// MARK: - CommandsRegistrar (seam over the Carbon-backed controller)
// ============================================================

/// The behaviour `CommandsController` needs from the live
/// `CommandBridgeController` (Carbon hot-key), abstracted so the controller
/// state machine is unit-testable with an in-memory fake (no Carbon, no
/// WindowServer). The production conformance is a thin adapter the
/// AppDelegate builds around its `CommandBridgeController`.
@MainActor
public protocol CommandsRegistrar: AnyObject {
    /// Whether the global hot-key is currently registered.
    var isRegistered: Bool { get }
    /// The combo the registrar currently owns (or last tried).
    var currentHotkey: HotkeyConfig { get }
    /// Register the current combo. Returns the structured outcome.
    @discardableResult
    func register() -> HotkeyRegisterStatus
    /// Unregister the global hot-key (idempotent).
    func unregister()
    /// Live-rebind to a new combo without a relaunch. Returns the
    /// structured outcome of registering the NEW combo (on failure the
    /// registrar restores the prior working combo internally).
    @discardableResult
    func rebind(to config: HotkeyConfig) -> HotkeyRegisterStatus
}

// ============================================================
// MARK: - CommandsController (@Observable single source of truth)
// ============================================================

/// The single observable model the Settings → Commands section reads.
/// The AppDelegate owns ONE instance and pushes every state transition
/// into it; SwiftUI observes it so the status row is always live.
@MainActor
@Observable
public final class CommandsController {

    /// Whether the global hot-key is currently registered (drives the
    /// Active vs "⚠ unavailable" status row). `false` when the palette
    /// is off or registration failed.
    public private(set) var isRegistered: Bool = false

    /// The combo the Settings recorder should display. Tracks the live
    /// registrar's config when running, else the persisted value.
    public private(set) var hotkeyConfig: HotkeyConfig

    /// The persisted master-toggle value (mirrors
    /// `BridgeDefaults.commandsPaletteEnabled`).
    public private(set) var enabled: Bool

    /// The structured outcome of the last registration attempt — lets a
    /// genuine combo collision be distinguished from a plumbing failure
    /// (W2 drives the message off this).
    public private(set) var lastRegisterStatus: HotkeyRegisterStatus = .unattempted

    /// Injected persistence (defaults to `.standard`). Captured as a
    /// closure-free reference only on the MainActor so the `@Observable`
    /// stays `@MainActor`-isolated.
    private let defaults: UserDefaults
    private let enabledKey: String
    private let hotkeyKey: String

    public init(
        defaults: UserDefaults = .standard,
        enabledKey: String = BridgeDefaults.commandsPaletteEnabled,
        hotkeyKey: String = BridgeDefaults.commandsHotkey
    ) {
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.hotkeyKey = hotkeyKey
        // Default true: the palette ships ON (matches CommandsPaletteGate's
        // default-enabled contract when the key has never been written).
        self.enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true
        self.hotkeyConfig = HotkeyConfig.loadPersisted(from: defaults, key: hotkeyKey)
    }

    // MARK: - Launch / registration publish

    /// The launch (or live-enable) registration path calls this with the
    /// real registrar so the controller publishes the TRUE
    /// `isRegistered` + `lastRegisterStatus` + the live combo.
    public func publishRegistration(
        isRegistered: Bool,
        status: HotkeyRegisterStatus,
        hotkey: HotkeyConfig
    ) {
        self.isRegistered = isRegistered
        self.lastRegisterStatus = status
        self.hotkeyConfig = hotkey
    }

    /// Reflect a clean teardown (palette disabled): nothing registered,
    /// no failure to report. The persisted hotkey is retained for display.
    public func publishUnregistered() {
        self.isRegistered = false
        self.lastRegisterStatus = .unattempted
    }

    // MARK: - Live entrypoints (mirror the AppDelegate's, update state)

    /// Live enable/disable. Persists the preference, then asks the
    /// injected registrar (when present) to register/unregister WITHOUT
    /// a relaunch, publishing the resulting observable state. Idempotent
    /// and safe when no registrar is wired (disable → clean no-op).
    public func setEnabled(_ enabled: Bool, registrar: CommandsRegistrar?) {
        self.enabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            guard let registrar else {
                // No registrar to act on (gate off / palette not built).
                // The persisted pref is written; nothing is registered.
                publishUnregistered()
                return
            }
            let status = registrar.register()
            publishRegistration(
                isRegistered: registrar.isRegistered,
                status: status,
                hotkey: registrar.currentHotkey
            )
        } else {
            registrar?.unregister()
            publishUnregistered()
        }
    }

    /// Persist + reflect ONLY the master-toggle `enabled` value, WITHOUT
    /// touching `isRegistered` / `lastRegisterStatus`. Used by the AppDelegate's
    /// `setCommandsPaletteEnabled(true)` path, which performs the Carbon
    /// construction + registration itself and then publishes the REAL outcome
    /// via `publishRegistration`. Routing that path through `setEnabled(_:
    /// registrar: nil)` used to call `publishUnregistered()` as an interim,
    /// momentarily clobbering a just-published `.registered` back to
    /// `.unattempted` — a fragile ordering that risked the header latching the
    /// false "⚠ Shortcut not active". This keeps the status fields untouched so
    /// the only writer of registration truth on that path is the subsequent
    /// `publishRegistration`.
    public func applyEnabledPreference(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Live-rebind the global hot-key from the Settings recorder.
    /// Persists the new `HotkeyConfig` FIRST (so a relaunch keeps it even
    /// if the live re-register loses a race), then re-registers via the
    /// registrar. Updates `isRegistered` + `lastRegisterStatus` +
    /// `hotkeyConfig` from the real outcome. Returns whether the NEW
    /// combo registered.
    ///
    /// If no registrar is wired (palette OFF) we still persist — the
    /// recorded combo takes effect when next enabled — update the
    /// displayed combo, and report `false` (nothing registered).
    @discardableResult
    public func setHotkey(_ config: HotkeyConfig, registrar: CommandsRegistrar?) -> Bool {
        config.persist(to: defaults, key: hotkeyKey)
        guard let registrar else {
            // Palette OFF: persisted + displayed, but not registered.
            self.hotkeyConfig = config
            self.isRegistered = false
            self.lastRegisterStatus = .unattempted
            return false
        }
        let status = registrar.rebind(to: config)
        // On success the registrar owns `config`; on failure it restored
        // the prior working combo — mirror the registrar's REAL config so
        // the displayed glyph never lies about what is actually live.
        publishRegistration(
            isRegistered: registrar.isRegistered,
            status: status,
            hotkey: registrar.currentHotkey
        )
        return status.isRegistered
    }
}
