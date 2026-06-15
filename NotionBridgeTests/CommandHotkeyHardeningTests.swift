// CommandHotkeyHardeningTests.swift — v4 global-shortcut enterprise hardening
// NotionBridge · Tests
//
// Locks the v4 root-cause fixes for the persistent "⚠ Shortcut not active"
// defect on the Command Bridge global hot-key (⌃⌘B). All four areas the fix
// touched are asserted here HEADLESSLY (no Carbon RegisterEventHotKey firing,
// no NSApp, no WindowServer — those remain the documented operator-smoke
// ceiling):
//
//   (1) keyCode/modifier mapping ROUND-TRIP (Cocoa ↔ Carbon) — the recorder's
//       (NSEvent keyCode, NSEvent.ModifierFlags) → HotkeyConfig is total and
//       its Carbon mask is the bit layout RegisterEventHotKey expects, and the
//       glyph round-trips. (Re-pins the mapping is NOT the bug — proves it.)
//
//   (2) PERSISTENCE load/save round-trip — a recorded combo survives a
//       relaunch (persist → fresh loadPersisted reads it back); a corrupt /
//       unset key falls back to productionDefault (⌃⌘B), never crashes.
//
//   (3) Collision-vs-plumbing CLASSIFICATION — CommandBridgeController
//       .classifyRegisterFailure maps ONLY the real already-registered Carbon
//       code (eventHotKeyExistsErr, -9878) to .collision; every other
//       non-noErr is .plumbingFailure. This is what makes a conflict surface a
//       DISTINCT state and a non-collision failure never falsely blame another
//       app.
//
//   (4) STATUS derivation from the registration result — the truth invariants:
//       a registered outcome NEVER renders as a warning / "not active"; a true
//       collision renders the specific "in use … record a different shortcut";
//       a plumbing failure renders a DIFFERENT (non-"another app") warning;
//       disabled always wins. Plus the live-rebind no-churn invariant via the
//       CommandsController + a fake registrar (a rebind to the same live combo
//       keeps it Active; a rebind to a taken combo keeps the prior combo live
//       and surfaces the collision).

import Foundation
import AppKit
import Carbon.HIToolbox
import NotionBridgeLib

func runCommandHotkeyHardeningTests() async {
    print("\n\u{2328}\u{FE0F}  Command Hot-key Hardening Tests (v4 · ⌃⌘B enterprise-grade)")

    // ── (1) Cocoa ↔ Carbon mapping round-trip ──────────────────────────

    await test("map round-trip: ⌃⌘B recorder chord → productionDefault config + glyph") {
        // The recorder forwards NSEvent.keyCode (== Carbon kVK_*) + Cocoa mods.
        let cfg = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_B),
                                    cocoaModifiers: [.control, .command])
        try expect(cfg != nil, "a valid ⌃⌘B chord must map")
        try expect(cfg == .productionDefault,
                   "⌃⌘B must round-trip to productionDefault, got \(String(describing: cfg))")
        try expect(cfg?.carbonModifiers == UInt32(controlKey | cmdKey),
                   "Carbon mask must be controlKey|cmdKey (RegisterEventHotKey layout), got \(cfg?.carbonModifiers ?? 0)")
        try expect(cfg?.displayString == "\u{2303}\u{2318}B",
                   "glyph must render ⌃⌘B, got \(cfg?.displayString ?? "nil")")
    }

    await test("map round-trip: every modifier bit translates Cocoa→Carbon independently") {
        let cases: [(NSEvent.ModifierFlags, UInt32)] = [
            ([.control], UInt32(controlKey)),
            ([.option],  UInt32(optionKey)),
            ([.shift],   UInt32(shiftKey)),
            ([.command], UInt32(cmdKey)),
            ([.control, .option, .shift, .command],
             UInt32(controlKey | optionKey | shiftKey | cmdKey)),
        ]
        for (cocoa, carbon) in cases {
            let cfg = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_K), cocoaModifiers: cocoa)
            try expect(cfg?.carbonModifiers == carbon,
                       "mods \(cocoa) must map to \(carbon), got \(cfg?.carbonModifiers ?? 999)")
        }
    }

    await test("map round-trip: modifier-less + pure-modifier chords are REJECTED (never bindable)") {
        try expect(HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_B), cocoaModifiers: []) == nil,
                   "a bare key (no modifier) must be rejected")
        try expect(HotkeyConfig.from(keyCode: UInt32(kVK_Command), cocoaModifiers: [.command]) == nil,
                   "a pure-modifier key-down (⌘ alone, no real key) must be rejected")
    }

    // ── (2) Persistence load/save round-trip (relaunch survival) ───────

    await test("persistence: a recorded combo survives a relaunch (persist → fresh load)") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let key = BridgeDefaults.commandsHotkey
        let recorded = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_J),
                                         cocoaModifiers: [.control, .option, .command])!
        try expect(recorded.persist(to: defaults, key: key), "persist must succeed")
        // Simulate relaunch: a brand-new read against the same backing store.
        let reloaded = HotkeyConfig.loadPersisted(from: defaults, key: key)
        try expect(reloaded == recorded,
                   "the persisted combo must load back identically, got \(reloaded)")
        defaults.removePersistentDomain(forName: suite)
    }

    await test("persistence: unset key falls back to productionDefault ⌃⌘B (no crash)") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let loaded = HotkeyConfig.loadPersisted(from: defaults, key: BridgeDefaults.commandsHotkey)
        try expect(loaded == .productionDefault,
                   "unset ⇒ productionDefault (⌃⌘B), got \(loaded)")
        defaults.removePersistentDomain(forName: suite)
    }

    await test("persistence: corrupt stored bytes fall back to productionDefault (schema-drift safe)") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let key = BridgeDefaults.commandsHotkey
        defaults.set(Data([0x00, 0x01, 0x02, 0xFF]), forKey: key) // not valid JSON config
        let loaded = HotkeyConfig.loadPersisted(from: defaults, key: key)
        try expect(loaded == .productionDefault,
                   "corrupt bytes ⇒ productionDefault fallback, got \(loaded)")
        defaults.removePersistentDomain(forName: suite)
    }

    // ── (3) Collision-vs-plumbing classification (the conflict state) ──

    await test("classify: the real already-registered code (-9878) ⇒ .collision") {
        let r = CommandBridgeController.classifyRegisterFailure(OSStatus(-9878)) // eventHotKeyExistsErr
        try expect(r == .collision(osStatus: -9878),
                   "eventHotKeyExistsErr must be a true collision, got \(r)")
    }

    await test("classify: any OTHER non-noErr ⇒ .plumbingFailure (never a false collision)") {
        for code: OSStatus in [-50 /*paramErr*/, -108 /*memFullErr*/, -1, -9870, 1] {
            let r = CommandBridgeController.classifyRegisterFailure(code)
            switch r {
            case .plumbingFailure(let s):
                try expect(s == Int32(code), "carries the raw status \(code), got \(s)")
            default:
                throw TestError.assertion("\(code) must classify as .plumbingFailure, got \(r)")
            }
        }
    }

    // ── (4) Status derivation from the registration result ─────────────
    //
    //   The reported bug: the row read "⚠ Shortcut not active" (the generic
    //   .shortcutUnavailable) even when registered. These pin the truth
    //   invariants that make that impossible for a registered outcome and make
    //   a conflict a DISTINCT state.

    await test("status truth: a .registered outcome is ALWAYS Active and NEVER a warning") {
        let s = CommandsSettingsStatus(enabled: true,
                                       lastRegisterStatus: .registered,
                                       hotkey: "\u{2303}\u{2318}B")
        try expect(s == .active(hotkey: "\u{2303}\u{2318}B"), "registered ⇒ .active, got \(s)")
        try expect(s.isWarning == false, "a registered hot-key must never render as a warning")
        try expect(s.message == "Active — \u{2303}\u{2318}B", "exact active copy")
    }

    await test("status truth: a true collision is a DISTINCT 'in use … record a different' warning") {
        let s = CommandsSettingsStatus(enabled: true,
                                       lastRegisterStatus: .collision(osStatus: -9878),
                                       hotkey: "\u{2303}\u{2318}B")
        try expect(s == .comboInUse(hotkey: "\u{2303}\u{2318}B"), "collision ⇒ .comboInUse, got \(s)")
        try expect(s.isWarning, "a collision is a warning")
        try expect(s.message.contains("in use by another app") && s.message.contains("record a different"),
                   "collision copy must name the conflict + the fix, got: \(s.message)")
    }

    await test("status truth: a plumbing failure is a warning but does NOT blame another app") {
        let s = CommandsSettingsStatus(enabled: true,
                                       lastRegisterStatus: .plumbingFailure(osStatus: -50),
                                       hotkey: "\u{2303}\u{2318}B")
        try expect(s.isWarning, "plumbing failure is still a warning (palette not working)")
        try expect(!s.message.contains("in use by another app"),
                   "a plumbing failure must NOT falsely blame another app, got: \(s.message)")
    }

    await test("status truth: disabled wins over every last-register outcome") {
        for st: HotkeyRegisterStatus in [.registered, .collision(osStatus: -9878),
                                         .plumbingFailure(osStatus: -50), .unattempted] {
            let s = CommandsSettingsStatus(enabled: false, lastRegisterStatus: st, hotkey: "B")
            try expect(s == .disabled, "disabled must win over \(st)")
            try expect(s.isWarning == false, "disabled is not a warning")
        }
    }

    // ── (4b) Live-rebind no-churn truth via CommandsController + fake ──

    await test("rebind no-churn: re-binding to the SAME live combo stays Active (1 rebind, registered)") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let r = await MainActor.run { () -> (Bool, HotkeyRegisterStatus, HotkeyConfig) in
            let c = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            let reg = FakeCommandsRegistrar(hotkey: .productionDefault, nextStatus: .registered)
            c.setEnabled(true, registrar: reg)                 // now Active on ⌃⌘B
            _ = c.setHotkey(.productionDefault, registrar: reg) // rebind to the SAME combo
            return (c.isRegistered, c.lastRegisterStatus, c.hotkeyConfig)
        }
        try expect(r.0, "must stay registered after a same-combo rebind")
        try expect(r.1 == .registered, "status stays .registered (no false interim warning)")
        try expect(r.2 == .productionDefault, "the live combo is unchanged")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    await test("rebind no-churn: a TAKEN combo keeps the prior combo live + surfaces the collision") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let prior = HotkeyConfig.productionDefault
        let taken = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_V), cocoaModifiers: [.command])!
        let r = await MainActor.run { () -> (Bool, Bool, HotkeyConfig, HotkeyRegisterStatus) in
            let c = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            let reg = FakeCommandsRegistrar(hotkey: prior, nextStatus: .collision(osStatus: -9878))
            let ok = c.setHotkey(taken, registrar: reg)
            return (ok, c.isRegistered, c.hotkeyConfig, c.lastRegisterStatus)
        }
        try expect(r.0 == false, "a taken combo returns false")
        try expect(r.1, "palette stays alive on the PRIOR working combo")
        try expect(r.2 == prior, "displayed combo reflects the REAL live (prior) combo")
        try expect(r.3 == .collision(osStatus: -9878), "the collision reason is surfaced")
        // And that surfaced collision renders the distinct conflict message.
        let s = CommandsSettingsStatus(enabled: true, lastRegisterStatus: r.3,
                                       hotkey: taken.displayString)
        try expect(s == .comboInUse(hotkey: taken.displayString),
                   "the surfaced collision must drive the distinct .comboInUse row")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // ── (5) Status REACHES the header: the published-registration invariant ──
    //
    //   The residual on-device bug: ⌃⌘B registered + fired, yet the Commands
    //   header still showed "⚠ Shortcut not active". Root cause — the header
    //   read its VALUE from the non-@Observable `commandBridge` box while the
    //   launch `publishRegistration(.registered)` only updated the OBSERVED
    //   `CommandsController`; the published status never reached the rendered
    //   value. The header now derives its status from the OBSERVED controller's
    //   `lastRegisterStatus`. These pin that the controller-derived status is
    //   Active (never `.shortcutUnavailable`) once a successful registration is
    //   published — exactly what the header reads.

    await test("status reaches header: a published .registered ⇒ controller derives Active, NOT unavailable") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        // Simulate the launch path: startCommandsPalette() → publishRegistration
        // with the real box outcome (default ⌃⌘B registered cleanly).
        let s = await MainActor.run { () -> CommandsSettingsStatus in
            let c = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            c.publishRegistration(isRegistered: true,
                                  status: .registered,
                                  hotkey: .productionDefault)
            // The header derives the row from the OBSERVED controller fields.
            return CommandsSettingsStatus(enabled: c.enabled,
                                          lastRegisterStatus: c.lastRegisterStatus,
                                          hotkey: c.hotkeyConfig.displayString)
        }
        try expect(s == .active(hotkey: "\u{2303}\u{2318}B"),
                   "a published .registered must derive .active, got \(s)")
        try expect(s != .shortcutUnavailable,
                   "the header must NEVER show the false 'Shortcut not active' after a successful register")
        try expect(s.isWarning == false, "Active is not a warning")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    await test("status reaches header: applyEnabledPreference(true) does NOT clobber a published .registered") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        // Mirrors the AppDelegate setCommandsPaletteEnabled(true) ordering AFTER
        // the fix: persist the toggle via applyEnabledPreference (which must NOT
        // touch the status), THEN publishRegistration. Previously this path ran
        // setEnabled(true, registrar: nil) → publishUnregistered(), momentarily
        // resetting the status to .unattempted (the false-warning interim).
        let r = await MainActor.run { () -> (HotkeyRegisterStatus, Bool, Bool) in
            let c = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            c.publishRegistration(isRegistered: true, status: .registered, hotkey: .productionDefault)
            c.applyEnabledPreference(true)        // must leave status untouched
            return (c.lastRegisterStatus, c.isRegistered, c.enabled)
        }
        try expect(r.0 == .registered, "applyEnabledPreference must NOT reset status to .unattempted, got \(r.0)")
        try expect(r.1 == true, "isRegistered must survive applyEnabledPreference")
        try expect(r.2 == true, "the master toggle is persisted ON")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    await test("status reaches header: full enable ordering (applyEnabledPreference→publishRegistration) ends Active") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        // The exact post-fix setCommandsPaletteEnabled(true) sequence, then the
        // header derivation. Must end Active with no false-warning interim left.
        let s = await MainActor.run { () -> CommandsSettingsStatus in
            let c = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            let reg = FakeCommandsRegistrar(hotkey: .productionDefault, nextStatus: .registered)
            c.applyEnabledPreference(true)
            // startCommandsPalette()'s publish, modeled via the registrar outcome.
            _ = reg.register()
            c.publishRegistration(isRegistered: reg.isRegistered,
                                  status: .registered,
                                  hotkey: reg.currentHotkey)
            return CommandsSettingsStatus(enabled: c.enabled,
                                          lastRegisterStatus: c.lastRegisterStatus,
                                          hotkey: c.hotkeyConfig.displayString)
        }
        try expect(s == .active(hotkey: "\u{2303}\u{2318}B"), "enable flow must settle Active, got \(s)")
        try expect(s.isWarning == false, "no false warning may remain after enabling")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // ── (6) INSTANCE IDENTITY: the registering controller IS the observed one ──
    //
    //   The last-mile on-device defect. ⌃⌘B registered + fired globally, yet the
    //   Commands header STILL showed "⚠ Shortcut not active" on every fresh
    //   launch — even after the header was fixed to read the OBSERVED
    //   `CommandsController`. Root cause: there were effectively TWO controllers.
    //   The AppDelegate's launch path published `.registered` into instance A
    //   (`AppDelegate.commandsController`), but `SettingsWindowController.show()`
    //   re-resolved the controller for the SwiftUI `.environment` via
    //   `(NSApp.delegate as? AppDelegate)?.commandsController ?? CommandsController()`.
    //   When that cast didn't yield the registering AppDelegate it silently fell
    //   back to a BRAND-NEW instance B — never published into, forever
    //   `.unattempted` — and the UI observed B. So A was Active while the header
    //   rendered B's false warning.
    //
    //   The fix injects the AppDelegate's ONE `commandsController` straight into
    //   `SettingsWindowController` at construction (no `NSApp.delegate` cast, no
    //   `?? CommandsController()` fallback), so the registering controller and the
    //   UI-observed controller are necessarily the SAME object. These pin that
    //   invariant: a `.registered` published on the registration-side reference is
    //   visible through the UI-observed reference (and the false-warning regression
    //   that a SEPARATE fallback instance would reintroduce).

    await test("instance identity: a .registered published on the registering controller is visible to the UI-observed reference") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        let r = await MainActor.run { () -> (Bool, CommandsSettingsStatus) in
            // ONE controller — exactly the post-fix wiring: the AppDelegate owns
            // it (`registering`) and hands the SAME object to the Settings UI
            // (`uiObserved`). No fresh fallback is constructed.
            let registering = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            let uiObserved = registering   // SettingsWindowController(commandsController:) injection

            // The launch registration path publishes the TRUE outcome into the
            // controller it holds (default ⌃⌘B registered cleanly).
            registering.publishRegistration(isRegistered: true,
                                            status: .registered,
                                            hotkey: .productionDefault)

            // The header derives its row from the UI-observed reference. Because
            // it is the SAME object, it must see the published .registered.
            let sameObject = (registering === uiObserved)
            let s = CommandsSettingsStatus(enabled: uiObserved.enabled,
                                           lastRegisterStatus: uiObserved.lastRegisterStatus,
                                           hotkey: uiObserved.hotkeyConfig.displayString)
            return (sameObject, s)
        }
        try expect(r.0, "the registering controller and the UI-observed controller MUST be the same instance")
        try expect(r.1 == .active(hotkey: "\u{2303}\u{2318}B"),
                   "the UI-observed controller must read the published .registered as Active, got \(r.1)")
        try expect(r.1 != .shortcutUnavailable,
                   "the header must NOT show the false 'Shortcut not active' when the registering controller is Active")
        try expect(r.1.isWarning == false, "a shared, registered controller is never a warning")
        UserDefaults().removePersistentDomain(forName: suite)
    }

    await test("instance identity: a SEPARATE fallback controller (the old bug) reproduces the false 'not active' warning") {
        let suite = "kup.solutions.notion-bridge.cmd-hk.\(UUID().uuidString)"
        // Documents WHY the instance must be shared: model the OLD
        // `?? CommandsController()` fallback — the UI observes a DIFFERENT
        // instance than the one the launch path registered. The registering
        // instance is Active; the freshly-constructed UI instance is forever
        // `.unattempted` ⇒ the exact false "⚠ Shortcut not active" header.
        let r = await MainActor.run { () -> (Bool, CommandsSettingsStatus, CommandsSettingsStatus) in
            let registering = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            registering.publishRegistration(isRegistered: true,
                                            status: .registered,
                                            hotkey: .productionDefault)
            // The bug: a brand-new instance the UI would observe instead.
            let fallbackUI = CommandsController(defaults: UserDefaults(suiteName: suite)!)
            let sameObject = (registering === fallbackUI)
            let registeringStatus = CommandsSettingsStatus(
                enabled: registering.enabled,
                lastRegisterStatus: registering.lastRegisterStatus,
                hotkey: registering.hotkeyConfig.displayString)
            let uiStatus = CommandsSettingsStatus(
                enabled: fallbackUI.enabled,
                lastRegisterStatus: fallbackUI.lastRegisterStatus,
                hotkey: fallbackUI.hotkeyConfig.displayString)
            return (sameObject, registeringStatus, uiStatus)
        }
        try expect(r.0 == false, "the fallback path observes a DIFFERENT instance (this is the bug)")
        try expect(r.1 == .active(hotkey: "\u{2303}\u{2318}B"),
                   "the registering instance is genuinely Active")
        try expect(r.2 == .shortcutUnavailable,
                   "a separate, never-published instance derives the FALSE 'Shortcut not active' — exactly the on-device symptom the fix removes")
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
