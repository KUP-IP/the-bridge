// CommandBoxSpikeTests.swift — Feasibility spike (cmd-w1-spike)
// NotionBridge · Tests
//
// Covers the PURE, GUI-free units of the command-box architecture:
//   (a) prior-app capture / return model       — PriorAppCapture
//   (b) clipboard save→set→restore round-trip   — ClipboardStasher (stub pb)
//   (c) plain-text paste-format selection       — CommandBoxParameters
//   (d) hotkey-config model                     — HotkeyConfig
//   (+) Cmd-V CGEvent construction (no posting) — PasteKeystroke
//
// HONEST SCOPE: the global hot-key actually FIRING and a non-activating
// NSPanel receiving key events both require a live WindowServer session
// and a real frontmost app — those are NOT faked here. Only the
// injectable logic is asserted.

import Foundation
import AppKit
import Carbon.HIToolbox
import NotionBridgeLib

// Test double for FrontmostAppProviding.
private final class StubFrontmost: FrontmostAppProviding {
    var frontmost: PriorApp?
    var activatedPIDs: [pid_t] = []
    var activateResult = true
    init(_ f: PriorApp?) { frontmost = f }
    func currentFrontmost() -> PriorApp? { frontmost }
    func activate(_ app: PriorApp) -> Bool {
        activatedPIDs.append(app.processIdentifier)
        return activateResult
    }
}

func runCommandBoxSpikeTests() async {
    print("\n\u{2328}\u{FE0F}  CommandBox Spike Tests")

    // ---- (d) HotkeyConfig model -------------------------------------

    await test("HotkeyConfig spikeDefault is ⌥⌘Space (Carbon mask)") {
        let h = HotkeyConfig.spikeDefault
        try expect(h.keyCode == UInt32(kVK_Space), "keyCode should be Space (49), got \(h.keyCode)")
        try expect(h.carbonModifiers == UInt32(cmdKey | optionKey),
                   "modifiers should be cmd|option, got \(h.carbonModifiers)")
    }

    await test("HotkeyConfig.hasModifier true for default, false for bare key") {
        try expect(HotkeyConfig.spikeDefault.hasModifier, "default must have a modifier")
        let bare = HotkeyConfig(keyCode: UInt32(kVK_Space), carbonModifiers: 0)
        try expect(!bare.hasModifier, "modifier-less combo must report hasModifier=false")
    }

    await test("HotkeyConfig signature is the stable 4-char 'NBcb' OSType") {
        // 'N'=0x4E 'B'=0x42 'c'=0x63 'b'=0x62
        let expected: OSType = (0x4E << 24) | (0x42 << 16) | (0x63 << 8) | 0x62
        try expect(HotkeyConfig.signature == expected,
                   "signature mismatch: \(HotkeyConfig.signature) vs \(expected)")
    }

    await test("HotkeyConfig displayString renders the combo glyphs") {
        try expect(HotkeyConfig.spikeDefault.displayString == "⌥⌘Space",
                   "got '\(HotkeyConfig.spikeDefault.displayString)'")
    }

    await test("HotkeyConfig is Codable round-trip stable") {
        let h = HotkeyConfig(keyCode: 11, carbonModifiers: UInt32(controlKey | shiftKey))
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(HotkeyConfig.self, from: data)
        try expect(back == h, "Codable round-trip changed the config")
    }

    // ---- (c) plain-text paste-format / timing policy ----------------

    await test("CommandBoxParameters default is plain-text-only and valid") {
        let p = CommandBoxParameters.spikeDefault
        try expect(p.pasteFormatIsPlainTextOnly, "spike must paste PLAIN TEXT only")
        try expect(p.isValid, "default policy must be self-consistent")
    }

    await test("CommandBoxParameters invalid if rich-text selected") {
        let p = CommandBoxParameters(reactivateToPasteDelayMs: 60,
                                     pasteToRestoreDelayMs: 250,
                                     pasteFormatIsPlainTextOnly: false)
        try expect(!p.isValid, "non-plain-text policy must be rejected as invalid")
    }

    await test("CommandBoxParameters invalid if restore delay <= reactivate delay") {
        let p = CommandBoxParameters(reactivateToPasteDelayMs: 300,
                                     pasteToRestoreDelayMs: 100)
        try expect(!p.isValid, "restore must come strictly after reactivate+paste")
    }

    // ---- (b) clipboard save → set → restore round-trip --------------

    await test("ClipboardStasher saves original, writes command text") {
        let pb = InMemoryPasteboard(initial: "user-original-clip")
        let token = ClipboardStasher(pb).stash("the typed command")
        try expect(pb.readString() == "the typed command",
                   "pasteboard should now hold the command text")
        try expect(token.postWriteChangeCount == pb.changeCount,
                   "token must capture the post-write changeCount")
    }

    await test("ClipboardStasher restores the user's original clipboard") {
        let pb = InMemoryPasteboard(initial: "user-original-clip")
        let token = ClipboardStasher(pb).stash("cmd")
        token.restore()
        try expect(pb.readString() == "user-original-clip",
                   "original clipboard must be restored, got \(pb.readString() ?? "nil")")
    }

    await test("ClipboardStasher round-trips a nil (empty) original") {
        let pb = InMemoryPasteboard(initial: nil)
        let token = ClipboardStasher(pb).stash("cmd")
        try expect(pb.readString() == "cmd", "command text should be set")
        token.restore()
        try expect(pb.readString() == nil,
                   "an originally-empty clipboard must restore to empty")
    }

    await test("ClipboardStasher guarded restore does NOT clobber a newer write") {
        let pb = InMemoryPasteboard(initial: "original")
        let token = ClipboardStasher(pb).stash("cmd")
        // Simulate the user/another app copying something AFTER our paste.
        pb.writeString("user-copied-something-new")
        token.restore()   // guarded: changeCount advanced past our write
        try expect(pb.readString() == "user-copied-something-new",
                   "guarded restore must not overwrite a newer clipboard write")
    }

    await test("ClipboardStasher unconditional restore overrides the guard") {
        let pb = InMemoryPasteboard(initial: "original")
        let token = ClipboardStasher(pb).stash("cmd")
        pb.writeString("newer")
        token.restoreUnconditionally()
        try expect(pb.readString() == "original",
                   "unconditional restore must force the original back")
    }

    // ---- (a) prior-app capture / return model -----------------------

    await test("PriorAppCapture records the frontmost app") {
        let app = PriorApp(bundleIdentifier: "com.apple.Notes", processIdentifier: 4242)
        let cap = PriorAppCapture(provider: StubFrontmost(app),
                                  selfBundleID: "kup.solutions.notion-bridge")
        let got = cap.capture()
        try expect(got == app, "capture() should return the frontmost app")
        try expect(cap.capturedApp == app, "capturedApp should be stored")
    }

    await test("PriorAppCapture ignores self (never returns focus to us)") {
        let me = PriorApp(bundleIdentifier: "kup.solutions.notion-bridge",
                          processIdentifier: 999)
        let cap = PriorAppCapture(provider: StubFrontmost(me),
                                  selfBundleID: "kup.solutions.notion-bridge")
        try expect(cap.capture() == nil,
                   "frontmost==self must capture nil (nothing to return to)")
    }

    await test("PriorAppCapture returnFocus reactivates the captured app") {
        let app = PriorApp(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 7777)
        let stub = StubFrontmost(app)
        let cap = PriorAppCapture(provider: stub, selfBundleID: "x.y.z")
        cap.capture()
        try expect(cap.returnFocus(), "returnFocus should succeed when app present")
        try expect(stub.activatedPIDs == [7777],
                   "activate must be called with the captured pid, got \(stub.activatedPIDs)")
    }

    await test("PriorAppCapture returnFocus is a no-op when nothing captured") {
        let cap = PriorAppCapture(provider: StubFrontmost(nil), selfBundleID: "x")
        try expect(!cap.returnFocus(),
                   "returnFocus with no capture must return false")
    }

    await test("PriorAppCapture returnFocus false if app vanished") {
        let app = PriorApp(bundleIdentifier: "com.gone", processIdentifier: 1)
        let stub = StubFrontmost(app)
        stub.activateResult = false   // app disappeared between show and commit
        let cap = PriorAppCapture(provider: stub, selfBundleID: "x")
        cap.capture()
        try expect(!cap.returnFocus(),
                   "returnFocus must report false when the app can't be reactivated")
    }

    await test("PriorAppCapture reset clears the captured app") {
        let app = PriorApp(bundleIdentifier: "a", processIdentifier: 2)
        let cap = PriorAppCapture(provider: StubFrontmost(app), selfBundleID: "x")
        cap.capture()
        cap.reset()
        try expect(cap.capturedApp == nil, "reset must clear capturedApp")
    }

    // ---- (+) Cmd-V keystroke construction (no posting) --------------

    await test("PasteKeystroke uses the 'V' virtual keycode") {
        try expect(PasteKeystroke.vKeyCode == CGKeyCode(kVK_ANSI_V),
                   "paste key must be ANSI V, got \(PasteKeystroke.vKeyCode)")
    }

    await test("PasteKeystroke builds a Cmd-V down/up pair with .maskCommand") {
        // CGEventSource may be nil in a headless CI sandbox; only assert
        // the flags/keycode when the WindowServer hands us real events.
        if let pair = PasteKeystroke.makeCommandVEvents() {
            try expect(pair.down.flags.contains(.maskCommand),
                       "key-down must carry the Command modifier flag")
            try expect(pair.up.flags.contains(.maskCommand),
                       "key-up must carry the Command modifier flag")
            try expect(pair.down.getIntegerValueField(.keyboardEventKeycode)
                        == Int64(kVK_ANSI_V),
                       "key-down keycode must be V")
        } else {
            // Honest: no WindowServer event source available here. The
            // construction path is structurally exercised; posting is
            // GUI-time only. Not a failure.
            print("    (CGEventSource unavailable in this environment — " +
                  "Cmd-V posting is manual-smoke only, as documented)")
        }
    }
}
