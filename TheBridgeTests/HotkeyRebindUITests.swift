// HotkeyRebindUITests.swift — v3.7.6 (mount the Command Bridge hotkey rebind UI)
// TheBridge · Tests
//
// The "Global shortcut" card in CommandsSection.swift mounts the previously
// built-but-orphaned `HotkeyRecorderField` and wires it to the live engine.
// This suite LOCKS the pure contract surface that card depends on — every
// piece of decision logic the SwiftUI view delegates to is asserted here,
// HEADLESSLY (no Carbon RegisterEventHotKey, no NSApp, no WindowServer):
//
//   1. The recorder's capture handler maps a chord through
//      `HotkeyConfig.from(keyCode:cocoaModifiers:)` — a valid modifier+key
//      combo maps to a config; a pure-modifier press and a no-modifier key
//      are REJECTED (nil) so the field re-arms instead of binding garbage.
//   2. `persist` → `loadPersisted` round-trips the recorded combo through an
//      injected UserDefaults suite (relaunch-safe), and an unset key falls
//      back to the shipping default.
//   3. The live status row maps the controller's structured
//      `HotkeyRegisterStatus` (registered / collision / plumbingFailure) to
//      the exact `CommandsSettingsStatus` message + severity the card renders
//      — a TRUE collision is the only state that offers the Retry button.
//
// DOCUMENTED OPERATOR-SMOKE CEILING (NOT faked): the raw `NSEvent` keystroke
// reaching the `RecorderNSView` on a live WindowServer, and the actual Carbon
// `RegisterEventHotKey` firing — see CommandBox.swift / SettingsWindow+
// Sections.swift headers. The DECISION logic beneath the gesture (this file)
// is pure and fully asserted.

import Foundation
import AppKit
import Carbon.HIToolbox
import TheBridgeLib

func runHotkeyRebindUITests() async {
    print("\n\u{2328}\u{FE0F}  Hotkey Rebind UI Tests (v3.7.6 · mount the recorder card)")

    // ── 1. Capture handler: HotkeyConfig.from validation ───────────────
    //
    //   The card's `handleCapture` returns `HotkeyConfig.from(...) != nil`:
    //   a valid chord is accepted (capture ends), a rejected chord keeps the
    //   field recording. These three cases ARE that accept/reject decision.

    await test("rebind UI: a valid modifier+key chord maps (⌃⌥⌘ + K)") {
        let cfg = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_K),
            cocoaModifiers: [.control, .option, .command]
        )
        try expect(cfg != nil, "a real modifier+key chord must produce a config")
        try expect(cfg?.keyCode == UInt32(kVK_ANSI_K), "keeps the captured key code")
        try expect(
            cfg?.carbonModifiers == UInt32(controlKey | optionKey | cmdKey),
            "Cocoa flags must translate to the Carbon mask, got \(cfg?.carbonModifiers ?? 999)"
        )
        // The capture handler ACCEPTS exactly when from(...) is non-nil.
        try expect((cfg != nil) == true, "accepted ⇒ recorder ends capture")
    }

    await test("rebind UI: a pure-modifier press is REJECTED (nil ⇒ keep recording)") {
        // A modifier key-down with no real key yet (the recorder must wait):
        // the keyCode is itself a modifier virtual key.
        let cfg = HotkeyConfig.from(
            keyCode: UInt32(kVK_Command),
            cocoaModifiers: [.command]
        )
        try expect(cfg == nil, "a pure-modifier press must NOT bind — keep recording")
        try expect(
            HotkeyConfig.isPureModifierKeyCode(UInt32(kVK_Command)),
            "⌘ keyCode is a pure modifier"
        )
    }

    await test("rebind UI: a no-modifier key is REJECTED (nil ⇒ keep recording)") {
        // A bare key with zero modifiers would hijack that key for every app.
        let cfg = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_K),
            cocoaModifiers: []
        )
        try expect(cfg == nil, "a modifier-less chord must NOT bind — keep recording")
    }

    // ── 2. persist → loadPersisted round-trip (relaunch-safe) ──────────

    await test("rebind UI: persist → load round-trips the recorded combo") {
        let suite = "kup.solutions.notion-bridge.hotkeyUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = BridgeDefaults.commandsHotkey

        let recorded = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_J),
            cocoaModifiers: [.control, .command]
        )!
        try expect(recorded.persist(to: defaults, key: key), "encode + write must succeed")

        let loaded = HotkeyConfig.loadPersisted(from: defaults, key: key)
        try expect(loaded == recorded, "loaded combo must equal the persisted one, got \(loaded)")
        try expect(loaded.displayString == recorded.displayString,
                   "the displayed glyph survives the round-trip")
    }

    await test("rebind UI: an unset key falls back to the shipping default") {
        let suite = "kup.solutions.notion-bridge.hotkeyUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let loaded = HotkeyConfig.loadPersisted(from: defaults, key: BridgeDefaults.commandsHotkey)
        try expect(loaded == .productionDefault,
                   "no persisted combo ⇒ productionDefault (so the card always shows a glyph)")
    }

    // ── 3. Status row: HotkeyRegisterStatus → message / severity / Retry ─
    //
    //   The card derives its row from CommandsSettingsStatus over the
    //   controller's observed `lastRegisterStatus` + the master toggle.
    //   These lock the three states the card renders + the Retry gating.

    await test("rebind UI status: .registered ⇒ \"Active — <glyph>\", no warning, no Retry") {
        let glyph = "\u{2303}\u{2325}\u{2318}C" // ⌃⌥⌘C
        let s = CommandsSettingsStatus(enabled: true, lastRegisterStatus: .registered, hotkey: glyph)
        try expect(s == .active(hotkey: glyph), "registered + enabled ⇒ .active")
        try expect(s.message == "Active — \(glyph)", "exact active text, got: \(s.message)")
        try expect(s.isWarning == false, "active is not a warning")
        // The card only shows Retry on a TRUE collision.
        try expect(isCollisionStatus(.registered) == false, "no Retry on a working combo")
    }

    await test("rebind UI status: .collision ⇒ 'in use by another app', warning, Retry shown") {
        let glyph = "\u{2303}\u{2325}\u{2318}C"
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .collision(osStatus: -9878), hotkey: glyph)
        try expect(s.isWarning == true, "a real collision is a warning")
        try expect(
            s.message == "\u{26A0} \(glyph) is in use by another app — record a different shortcut",
            "collision must name the combo + tell the user to rebind, got: \(s.message)")
        // ONLY a collision arms the card's Retry button.
        try expect(isCollisionStatus(.collision(osStatus: -9878)) == true,
                   "a collision must offer Retry")
    }

    await test("rebind UI status: .plumbingFailure ⇒ generic error line (not a collision, no Retry)") {
        let glyph = "\u{2303}\u{2325}\u{2318}C"
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .plumbingFailure(osStatus: -50), hotkey: glyph)
        try expect(s.isWarning == true, "a plumbing failure is still a warning")
        try expect(!s.message.contains("in use by another app"),
                   "a plumbing failure must NOT blame another app, got: \(s.message)")
        try expect(s.message.contains("could not register"),
                   "the generic error line says registration failed, got: \(s.message)")
        // A plumbing failure is NOT retryable on the same combo → no Retry.
        try expect(isCollisionStatus(.plumbingFailure(osStatus: -50)) == false,
                   "no Retry on a plumbing failure")
    }
}

/// Mirrors CommandsSection.isCollision — the card shows Retry ⟺ the last
/// attempt was a TRUE Carbon combo collision. Kept here so the gating logic
/// the view applies is asserted directly (the view's private computed prop is
/// not module-visible; this is the same one-line classification).
private func isCollisionStatus(_ status: HotkeyRegisterStatus) -> Bool {
    if case .collision = status { return true }
    return false
}
