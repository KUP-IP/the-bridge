// CommandsControllerTests.swift — cmd-ux W1/W2 (headless state machine)
// NotionBridge · Tests
//
// HEADLESSLY TESTED (no Carbon, no NSApp, no WindowServer):
//   • W1: CommandsController observable state machine — enable/disable,
//         setHotkey success/failure → isRegistered + lastRegisterStatus,
//         persistence interaction; CommandsSettingsStatus derived over
//         the controller's observable states.
//   • W2: the HotkeyRegisterStatus → status-message mapping (success /
//         collision / plumbing failure / unattempted), and the recorder
//         focus-state model (recording on/off, click-enters-recording,
//         Escape-exits, accepted-vs-rejected) — modelled as state, not
//         raw NSEvent.
//
// DOCUMENTED OPERATOR-SMOKE CEILING (NOT faked here): the real Carbon
// `RegisterEventHotKey` firing, the non-activating NSPanel receiving
// keystrokes, and the raw `NSEvent` keystroke capture in the recorder
// NSView all require a live login session — see CommandBox.swift and
// SettingsWindow+Sections.swift headers. The DECISION logic beneath each
// (this file) is pure and fully asserted.

import Foundation
import AppKit
import Carbon.HIToolbox
import NotionBridgeLib

// ── In-memory CommandsRegistrar fake (no Carbon) ───────────────────────
//
// Models the CommandBoxController contract the controller drives: a
// register/rebind returns a scripted HotkeyRegisterStatus and the fake
// updates isRegistered + currentHotkey exactly like the real adapter
// would, so the controller's reaction is asserted with zero WindowServer.
@MainActor
final class FakeCommandsRegistrar: CommandsRegistrar {
    var isRegistered: Bool = false
    var currentHotkey: HotkeyConfig
    /// Scripted outcome the next register()/rebind() returns.
    var nextStatus: HotkeyRegisterStatus
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var rebindCalls = 0

    init(hotkey: HotkeyConfig = .productionDefault,
         nextStatus: HotkeyRegisterStatus = .registered) {
        self.currentHotkey = hotkey
        self.nextStatus = nextStatus
    }

    func register() -> HotkeyRegisterStatus {
        registerCalls += 1
        isRegistered = nextStatus.isRegistered
        return nextStatus
    }

    func unregister() {
        unregisterCalls += 1
        isRegistered = false
    }

    func rebind(to config: HotkeyConfig) -> HotkeyRegisterStatus {
        rebindCalls += 1
        let outcome = nextStatus
        if outcome.isRegistered {
            currentHotkey = config   // new combo took
            isRegistered = true
        } else {
            // Real controller falls back to the prior working combo:
            // stays on the OLD combo, still functionally registered.
            isRegistered = true
        }
        return outcome
    }
}

func runCommandsControllerTests() async {
    print("\n\u{2328}\u{FE0F}  CommandsController Tests (cmd-ux W1/W2 · observable state machine)")

    let hKey = BridgeDefaults.commandsHotkey
    let eKey = BridgeDefaults.commandsPaletteEnabled

    // Vend a fresh, uniquely-named suite. We pass the NAME (a Sendable
    // String) across the @MainActor boundary and resolve `UserDefaults`
    // on both sides — a named suite is process-shared, so a write inside
    // the MainActor closure is observed by a read-back resolved outside.
    // This is the same isolation discipline CommandPaletteTests uses for
    // the registry-provider suite, and it sidesteps the Swift-6
    // non-Sendable-UserDefaults-across-actors hazard cleanly.
    @Sendable func suiteName() -> String {
        "kup.solutions.notion-bridge.cmd-ux.ctrl.\(UUID().uuidString)"
    }

    // ── W1: construction reads persisted prefs ─────────────────────────
    await test("W1 controller: defaults to enabled=true + productionDefault when prefs unset") {
        let sn = suiteName()
        let snap = await MainActor.run { () -> (Bool, HotkeyConfig, Bool, HotkeyRegisterStatus) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            return (c.enabled, c.hotkeyConfig, c.isRegistered, c.lastRegisterStatus)
        }
        try expect(snap.0 == true, "palette ships ON when key unset")
        try expect(snap.1 == .productionDefault, "unset hotkey ⇒ productionDefault")
        try expect(snap.2 == false, "nothing registered before any attempt")
        try expect(snap.3 == .unattempted, "no attempt yet")
    }

    await test("W1 controller: reads a persisted disabled pref + persisted combo") {
        let sn = suiteName()
        UserDefaults(suiteName: sn)!.set(false, forKey: eKey)
        let recorded = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_J),
                                         cocoaModifiers: [.control, .command])!
        _ = recorded.persist(to: UserDefaults(suiteName: sn)!, key: hKey)
        let snap = await MainActor.run { () -> (Bool, HotkeyConfig) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            return (c.enabled, c.hotkeyConfig)
        }
        try expect(snap.0 == false, "must observe persisted-off pref")
        try expect(snap.1 == recorded, "must load the persisted combo")
    }

    // ── W1: setEnabled transitions ─────────────────────────────────────
    await test("W1 setEnabled(true) with a registrar publishes the REAL registration") {
        let sn = suiteName()
        let r = await MainActor.run { () -> (Bool, Bool, HotkeyRegisterStatus, Int) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .registered)
            c.setEnabled(true, registrar: reg)
            return (c.enabled, c.isRegistered, c.lastRegisterStatus, reg.registerCalls)
        }
        try expect(r.0 == true, "enabled flag set")
        try expect(UserDefaults(suiteName: sn)!.bool(forKey: eKey) == true, "pref persisted true")
        try expect(r.1 == true, "publishes registrar.isRegistered")
        try expect(r.2 == .registered, "publishes the real status")
        try expect(r.3 == 1, "registrar.register() called once")
    }

    await test("W1 setEnabled(true) with a colliding registrar publishes the collision") {
        let sn = suiteName()
        let r = await MainActor.run { () -> (Bool, HotkeyRegisterStatus) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .collision(osStatus: -9878))
            c.setEnabled(true, registrar: reg)
            return (c.isRegistered, c.lastRegisterStatus)
        }
        try expect(r.0 == false, "collision ⇒ not registered")
        try expect(r.1 == .collision(osStatus: -9878), "the true collision OSStatus is published")
    }

    await test("W1 setEnabled(false) unregisters + publishes a clean state") {
        let sn = suiteName()
        let r = await MainActor.run { () -> (Bool, Bool, HotkeyRegisterStatus, Int) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .registered)
            c.setEnabled(true, registrar: reg)
            c.setEnabled(false, registrar: reg)
            return (c.enabled, c.isRegistered, c.lastRegisterStatus, reg.unregisterCalls)
        }
        try expect(r.0 == false, "disabled flag")
        try expect(UserDefaults(suiteName: sn)!.bool(forKey: eKey) == false, "pref persisted false")
        try expect(r.1 == false, "nothing registered after disable")
        try expect(r.2 == .unattempted, "a deliberate disable is not a failure")
        try expect(r.3 == 1, "registrar.unregister() called")
    }

    await test("W1 setEnabled(true) with NO registrar persists pref but registers nothing") {
        let sn = suiteName()
        let r = await MainActor.run { () -> (Bool, HotkeyRegisterStatus) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            c.setEnabled(true, registrar: nil)
            return (c.isRegistered, c.lastRegisterStatus)
        }
        try expect(UserDefaults(suiteName: sn)!.bool(forKey: eKey) == true, "pref still persisted")
        try expect(r.0 == false, "no registrar ⇒ nothing registered")
        try expect(r.1 == .unattempted, "clean interim state")
    }

    // ── W1: setHotkey success / failure ────────────────────────────────
    await test("W1 setHotkey success: persists + publishes isRegistered + status + combo") {
        let sn = suiteName()
        let newCombo = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_K),
                                         cocoaModifiers: [.control, .option, .command])!
        let r = await MainActor.run { () -> (Bool, Bool, HotkeyRegisterStatus, HotkeyConfig, Int) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .registered)
            let ok = c.setHotkey(newCombo, registrar: reg)
            return (ok, c.isRegistered, c.lastRegisterStatus, c.hotkeyConfig, reg.rebindCalls)
        }
        try expect(r.0 == true, "success returns true")
        try expect(r.1 == true, "publishes registered")
        try expect(r.2 == .registered, "publishes .registered")
        try expect(r.3 == newCombo, "publishes the new live combo")
        try expect(HotkeyConfig.loadPersisted(from: UserDefaults(suiteName: sn)!, key: hKey) == newCombo,
                   "the new combo is persisted (relaunch-safe)")
        try expect(r.4 == 1, "registrar.rebind() called once")
    }

    await test("W1 setHotkey collision: persists intent, keeps prior live combo, surfaces collision") {
        let sn = suiteName()
        let prior = HotkeyConfig.productionDefault
        let taken = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_V),
                                      cocoaModifiers: [.command])!
        let r = await MainActor.run { () -> (Bool, Bool, HotkeyConfig, HotkeyRegisterStatus) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(hotkey: prior,
                                            nextStatus: .collision(osStatus: -9878))
            let ok = c.setHotkey(taken, registrar: reg)
            return (ok, c.isRegistered, c.hotkeyConfig, c.lastRegisterStatus)
        }
        try expect(r.0 == false, "a taken combo returns false")
        try expect(r.1 == true, "palette stays alive on the PRIOR working combo (best-effort)")
        try expect(r.2 == prior, "displayed combo reflects the registrar's REAL live combo (prior)")
        try expect(r.3 == .collision(osStatus: -9878), "the collision reason is surfaced")
        try expect(HotkeyConfig.loadPersisted(from: UserDefaults(suiteName: sn)!, key: hKey) == taken,
                   "the recorded combo is persisted even on collision (user intent)")
    }

    await test("W1 setHotkey with NO registrar (palette OFF): persists + displays, not registered") {
        let sn = suiteName()
        let combo = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_M),
                                      cocoaModifiers: [.control, .shift])!
        let r = await MainActor.run { () -> (Bool, HotkeyConfig, Bool) in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let ok = c.setHotkey(combo, registrar: nil)
            return (ok, c.hotkeyConfig, c.isRegistered)
        }
        try expect(r.0 == false, "nothing is registered while disabled")
        try expect(r.1 == combo, "the recorded combo is shown immediately")
        try expect(r.2 == false, "not registered while OFF")
        try expect(HotkeyConfig.loadPersisted(from: UserDefaults(suiteName: sn)!, key: hKey) == combo,
                   "persisted so it applies when re-enabled")
    }

    // ── W1: CommandsSettingsStatus over the controller's observable states
    await test("W1 status derivation: enabled+registered ⇒ Active — <glyph>") {
        let sn = suiteName()
        let s = await MainActor.run { () -> CommandsSettingsStatus in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .registered)
            c.setEnabled(true, registrar: reg)
            return CommandsSettingsStatus(enabled: c.enabled,
                                          isRegistered: c.isRegistered,
                                          hotkey: c.hotkeyConfig.displayString)
        }
        try expect(s == .active(hotkey: "\u{2303}\u{2325}\u{2318}C"),
                   "registered ⇒ .active with the live glyph, got \(s)")
        try expect(s.message == "Active — \u{2303}\u{2325}\u{2318}C", "exact copy")
        try expect(s.isWarning == false, "active is not a warning")
    }

    await test("W1 status derivation: enabled+collision ⇒ a red warning") {
        let sn = suiteName()
        let s = await MainActor.run { () -> CommandsSettingsStatus in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .collision(osStatus: -9878))
            c.setEnabled(true, registrar: reg)
            return CommandsSettingsStatus(enabled: c.enabled,
                                          isRegistered: c.isRegistered,
                                          hotkey: c.hotkeyConfig.displayString)
        }
        try expect(s == .shortcutUnavailable, "collision ⇒ .shortcutUnavailable (legacy init)")
        try expect(s.isWarning == true, "must render as a red warning")
    }

    await test("W1 status derivation: disabled ⇒ Disabled (no warning) regardless of registration") {
        let sn = suiteName()
        let s = await MainActor.run { () -> CommandsSettingsStatus in
            let c = CommandsController(defaults: UserDefaults(suiteName: sn)!)
            let reg = FakeCommandsRegistrar(nextStatus: .registered)
            c.setEnabled(false, registrar: reg)
            return CommandsSettingsStatus(enabled: c.enabled,
                                          isRegistered: c.isRegistered,
                                          hotkey: c.hotkeyConfig.displayString)
        }
        try expect(s == .disabled, "off ⇒ .disabled")
        try expect(s.message == "Disabled", "exact copy")
        try expect(s.isWarning == false, "disabled is not a warning")
    }

    // ── W2: HotkeyRegisterStatus → precise status message mapping ──────
    await test("W2 message mapping: .registered ⇒ Active — <glyph>, no warning") {
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .registered, hotkey: "\u{2303}\u{2325}\u{2318}C")
        try expect(s == .active(hotkey: "\u{2303}\u{2325}\u{2318}C"))
        try expect(s.isWarning == false)
    }

    await test("W2 message mapping: .collision ⇒ specific 'in use … record a different shortcut'") {
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .collision(osStatus: -9878),
            hotkey: "\u{2303}\u{2325}\u{2318}C")
        try expect(s.isWarning == true, "a real collision is a warning")
        try expect(
            s.message == "\u{26A0} \u{2303}\u{2325}\u{2318}C is in use by another app — record a different shortcut",
            "collision message must name the combo + tell the user to rebind, got: \(s.message)")
    }

    await test("W2 message mapping: .plumbingFailure ⇒ DIFFERENT message (not 'in use by another app')") {
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .plumbingFailure(osStatus: -50),
            hotkey: "\u{2303}\u{2325}\u{2318}C")
        try expect(s.isWarning == true, "still a warning (palette not working)")
        try expect(!s.message.contains("in use by another app"),
                   "a plumbing failure must NOT blame another app, got: \(s.message)")
        try expect(s.message.contains("could not register"),
                   "plumbing failure should say registration failed, got: \(s.message)")
    }

    await test("W2 message mapping: enabled but .unattempted ⇒ generic unavailable (no false collision)") {
        let s = CommandsSettingsStatus(
            enabled: true, lastRegisterStatus: .unattempted, hotkey: "\u{2303}\u{2325}\u{2318}C")
        try expect(s.isWarning == true)
        try expect(!s.message.contains("in use by another app"),
                   "an unattempted state must not falsely claim a collision, got: \(s.message)")
    }

    await test("W2 message mapping: disabled ⇒ Disabled regardless of last status") {
        for st: HotkeyRegisterStatus in [.registered, .collision(osStatus: -9878),
                                         .plumbingFailure(osStatus: -50), .unattempted] {
            let s = CommandsSettingsStatus(enabled: false, lastRegisterStatus: st, hotkey: "X")
            try expect(s == .disabled, "disabled wins over \(st)")
        }
    }

    // ── W2: recorder focus-state model (state, not NSEvent) ────────────
    await test("W2 recorder focus model: rest → click records → Escape exits") {
        var m = RecorderFocusModel()
        try expect(m.isRecording == false, "starts at rest")
        try expect(m.acceptsFirstResponder == false, "not first responder at rest")
        m.clickToRecord()
        try expect(m.isRecording == true, "a click enters recording standalone")
        try expect(m.acceptsFirstResponder == true,
                   "must accept first responder while recording (so keys arrive)")
        m.escape()
        try expect(m.isRecording == false, "Escape exits recording")
        try expect(m.acceptsFirstResponder == false, "no longer first responder")
    }

    await test("W2 recorder focus model: accepted capture exits; rejected stays") {
        var m = RecorderFocusModel()
        m.clickToRecord()
        m.captured(accepted: false)
        try expect(m.isRecording == true,
                   "a rejected chord (modifier-less / pure-modifier) keeps capture open")
        m.captured(accepted: true)
        try expect(m.isRecording == false, "an accepted chord ends capture")
    }

    await test("W2 recorder focus model: external setRecording(true) is also focusable") {
        var m = RecorderFocusModel()
        m.setRecording(true) // the secondary 'Record shortcut' button path
        try expect(m.isRecording == true)
        try expect(m.acceptsFirstResponder == true,
                   "the button path must also be focusable (belt + click both work)")
    }

    // ── W2: CommandBoxController.lastRegisterStatus — the HEADLESS slice
    //
    //   The modifier-less refusal path returns BEFORE any Carbon call
    //   (no WindowServer needed) — so the controller's structured-status
    //   classification of THAT path is genuinely unit-testable. It MUST
    //   be a plumbing failure, NOT a collision: a user who somehow has a
    //   modifier-less combo must never be told another app owns it.
    //   (The Carbon RegisterEventHotKey firing for a VALID combo remains
    //   the documented operator-smoke ceiling — see CommandBox.swift.)
    await test("W2 CommandBoxController: a modifier-less combo ⇒ .plumbingFailure (never .collision)") {
        let r = await MainActor.run { () -> HotkeyRegisterStatus in
            // keyCode with ZERO modifiers → hasModifier == false →
            // registerHotkey() refuses before touching Carbon.
            let bad = HotkeyConfig(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: 0)
            let coord = CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider([]),
                manager: CommandsManager(fetcher: { _ in "" })) // never invoked here
            let box = CommandBoxController(hotkey: bad,
                                          clipboard: InMemoryClipboard(),
                                          coordinator: coord)
            _ = box.registerHotkey()
            return box.lastRegisterStatus
        }
        switch r {
        case .plumbingFailure:
            break // correct — refused input, not another app's fault
        default:
            throw TestError.assertion(
                "modifier-less refusal must be .plumbingFailure, got \(r)")
        }
        // And it must map to the honest message, not a false collision.
        let s = CommandsSettingsStatus(enabled: true, lastRegisterStatus: r,
                                       hotkey: "C")
        try expect(!s.message.contains("in use by another app"),
                   "a refused modifier-less combo must NOT blame another app, got: \(s.message)")
    }
}
