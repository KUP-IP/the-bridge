// CommandBoxSpikeTests.swift — cmd-sb (Commands palette: clipboard-only)
// NotionBridge · Tests
//
// The cmd-w1-spike paste-back subsystem was DELETED (prior-app capture,
// reactivate, synthetic Cmd-V, clipboard save/restore round-trip,
// focus-restore + timing policy). Its 13 paste-back `test()` blocks
// (ClipboardStasher save/restore/guard/unconditional, PriorAppCapture
// record/self/returnFocus/no-op/vanished/reset, CommandBoxParameters
// plain-text/invalid/restore-ordering, PasteKeystroke keycode/Cmd-V
// construction) are SUPERSEDED here by corrected-invariant tests for the
// surviving + new units of the clipboard-only design:
//   (a) HotkeyConfig model               — RETAINED verbatim (5 tests)
//   (b) ClipboardWriting seam            — NEW: write fully replaces,
//       no snapshot/no restore, read-back, write-count, idempotent
//       overwrite, empty/unicode payloads (the corrected invariant —
//       "replace, never restore" — that supersedes the deleted
//       save/restore/guard round-trip tests)
//   (c) SystemClipboard live adapter     — NSPasteboard.general round
//       trips a real write→read (replaces the deleted SystemPasteboard
//       save/restore coverage with the corrected replace-only contract)
//
// HONEST SCOPE: the global hot-key actually FIRING and a non-activating
// NSPanel receiving key events both require a live WindowServer session
// — those are NOT faked here. Only the injectable logic is asserted.

import Foundation
import AppKit
import Carbon.HIToolbox
import NotionBridgeLib

func runCommandBoxSpikeTests() async {
    print("\n\u{2328}\u{FE0F}  CommandBox Tests (cmd-sb · clipboard-only)")

    // ---- (a) HotkeyConfig model (RETAINED) --------------------------

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

    // ---- cmd-ux Change C: SHIPPING default is ⌃⌥⌘C ------------------

    await test("HotkeyConfig.productionDefault is ⌃⌥⌘C (kVK_ANSI_C + ctrl|opt|cmd)") {
        let h = HotkeyConfig.productionDefault
        try expect(h.keyCode == UInt32(kVK_ANSI_C),
                   "keyCode must be C (\(kVK_ANSI_C)), got \(h.keyCode)")
        try expect(h.keyCode == 8, "kVK_ANSI_C is virtual key 8 (0x08), got \(h.keyCode)")
        try expect(h.carbonModifiers == UInt32(controlKey | optionKey | cmdKey),
                   "modifier must be controlKey|optionKey|cmdKey, got \(h.carbonModifiers)")
        // It must NOT carry the spike's cmd|option-Space shape.
        try expect(h != HotkeyConfig.spikeDefault,
                   "productionDefault must differ from the retained spikeDefault")
    }

    await test("HotkeyConfig.productionDefault.hasModifier is true (triple modifier)") {
        try expect(HotkeyConfig.productionDefault.hasModifier,
                   "⌃⌥⌘C must report hasModifier=true so the controller registers it")
    }

    await test("HotkeyConfig.productionDefault.displayString renders \"⌃⌥⌘C\"") {
        // Canonical Apple order: ⌃ ⌥ ⇧ ⌘ then the key glyph. ⌃⌥⌘C has
        // no shift, so the rendered string is exactly ⌃⌥⌘C.
        try expect(HotkeyConfig.productionDefault.displayString == "⌃⌥⌘C",
                   "got '\(HotkeyConfig.productionDefault.displayString)'")
    }

    await test("HotkeyConfig.keyGlyph maps Space, ANSI letters, and unknowns") {
        try expect(HotkeyConfig.keyGlyph(for: UInt32(kVK_Space)) == "Space")
        try expect(HotkeyConfig.keyGlyph(for: UInt32(kVK_ANSI_B)) == "B")
        try expect(HotkeyConfig.keyGlyph(for: UInt32(kVK_ANSI_A)) == "A")
        try expect(HotkeyConfig.keyGlyph(for: UInt32(kVK_ANSI_Z)) == "Z")
        try expect(HotkeyConfig.keyGlyph(for: 9999) == "key#9999",
                   "an unmapped code must degrade to key#N, never empty")
    }

    await test("HotkeyConfig.spikeDefault is RETAINED verbatim (⌥⌘Space) — not the shipping default") {
        // The shipping default moved to productionDefault (⌃B); spikeDefault
        // stays unchanged so historical Codable fixtures remain valid.
        let s = HotkeyConfig.spikeDefault
        try expect(s.keyCode == UInt32(kVK_Space) && s.carbonModifiers == UInt32(cmdKey | optionKey),
                   "spikeDefault must remain ⌥⌘Space")
        try expect(s != HotkeyConfig.productionDefault,
                   "the two defaults must be distinct configs")
    }

    // ---- (b) ClipboardWriting seam (NEW — supersedes save/restore) --
    //
    //   Corrected invariant vs the deleted ClipboardStasher: there is NO
    //   snapshot and NO restore. A write fully REPLACES the contents and
    //   the user's prior clipboard is intentionally NOT preserved (they
    //   WANT the resolved body left on the clipboard).

    await test("InMemoryClipboard.writeString fully replaces the contents") {
        let cb = InMemoryClipboard(initial: "user-original-clip")
        cb.writeString("the resolved command body")
        try expect(cb.readString() == "the resolved command body",
                   "clipboard must now hold ONLY the command body, got \(cb.readString() ?? "nil")")
    }

    await test("InMemoryClipboard does NOT preserve / restore the prior value") {
        // The corrected invariant that supersedes the deleted
        // save→set→restore round-trip: the original is GONE on purpose.
        let cb = InMemoryClipboard(initial: "user-original-clip")
        cb.writeString("body")
        try expect(cb.readString() == "body",
                   "there is no restore — the original must be overwritten, got \(cb.readString() ?? "nil")")
    }

    await test("InMemoryClipboard tracks an exact write count (wrote-once proof)") {
        let cb = InMemoryClipboard()
        try expect(cb.writeCount == 0, "no writes yet")
        cb.writeString("a")
        try expect(cb.writeCount == 1, "exactly one write, got \(cb.writeCount)")
    }

    await test("InMemoryClipboard repeated writes each fully replace + bump count") {
        let cb = InMemoryClipboard(initial: nil)
        cb.writeString("first")
        cb.writeString("second")
        try expect(cb.readString() == "second",
                   "the latest write wins (replace, not append), got \(cb.readString() ?? "nil")")
        try expect(cb.writeCount == 2, "two writes, got \(cb.writeCount)")
    }

    await test("InMemoryClipboard round-trips an empty-string body") {
        let cb = InMemoryClipboard(initial: "x")
        cb.writeString("")
        try expect(cb.readString() == "",
                   "an empty write must be readable back as empty, got \(cb.readString() ?? "nil")")
    }

    await test("InMemoryClipboard round-trips unicode / multiline markdown") {
        let cb = InMemoryClipboard()
        let body = "# Heading\n- bullet — em-dash\n[link](https://notion.so/p)\n✅ ünïçødé"
        cb.writeString(body)
        try expect(cb.readString() == body,
                   "the exact markdown bytes must survive the seam, got \(cb.readString() ?? "nil")")
    }

    await test("ClipboardWriting protocol is value-stable across the seam") {
        // Drive purely through the protocol type (proves the controller's
        // dependency is exactly this write-only surface).
        let cb: ClipboardWriting = InMemoryClipboard()
        cb.writeString("via-protocol")
        try expect(cb.readString() == "via-protocol",
                   "the protocol seam must carry the write, got \(cb.readString() ?? "nil")")
    }

    // ---- (c) SystemClipboard live adapter (replace-only) ------------
    //
    //   Replaces the deleted SystemPasteboard save/restore coverage with
    //   the corrected contract: clearContents()+setString, no restore.
    //   Uses a PRIVATE NSPasteboard (uniquely named) so the test never
    //   clobbers the developer's real `.general` clipboard.

    await test("SystemClipboard replaces a private NSPasteboard's contents") {
        let pb = NSPasteboard(name: NSPasteboard.Name(
            "kup.solutions.notion-bridge.cmd-sb.test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("pre-existing-user-clip", forType: .string)
        let cb = SystemClipboard(pb)
        cb.writeString("resolved-body")
        try expect(cb.readString() == "resolved-body",
                   "live adapter must REPLACE the pasteboard string, got \(cb.readString() ?? "nil")")
        try expect(pb.string(forType: .string) == "resolved-body",
                   "the underlying NSPasteboard must hold the body directly")
    }

    await test("SystemClipboard read-back is nil when nothing was written") {
        let pb = NSPasteboard(name: NSPasteboard.Name(
            "kup.solutions.notion-bridge.cmd-sb.test.\(UUID().uuidString)"))
        pb.clearContents()
        let cb = SystemClipboard(pb)
        try expect(cb.readString() == nil,
                   "an empty private pasteboard must read back nil, got \(cb.readString() ?? "nil")")
    }

    await test("SystemClipboard second write fully replaces the first (no append/restore)") {
        // Corrected invariant superseding the deleted guarded/unconditional
        // restore: there is NO change-count guard and NO restore — the
        // newest write simply wins, every time.
        let pb = NSPasteboard(name: NSPasteboard.Name(
            "kup.solutions.notion-bridge.cmd-sb.test.\(UUID().uuidString)"))
        let cb = SystemClipboard(pb)
        cb.writeString("first-body")
        cb.writeString("second-body")
        try expect(cb.readString() == "second-body",
                   "the latest write must fully replace the prior (no restore semantics), got \(cb.readString() ?? "nil")")
    }

    await test("SystemClipboard writing an empty string replaces (no nil round-trip footgun)") {
        let pb = NSPasteboard(name: NSPasteboard.Name(
            "kup.solutions.notion-bridge.cmd-sb.test.\(UUID().uuidString)"))
        let cb = SystemClipboard(pb)
        cb.writeString("non-empty")
        cb.writeString("")
        // NSPasteboard.setString("") records an empty string type; readback
        // is the empty string (NOT nil) — the controller's own empty-body
        // guard (applyCommit) is what prevents a blank write reaching here.
        try expect(cb.readString() == "",
                   "an explicit empty write reads back as empty, got \(cb.readString() ?? "nil")")
    }

    await test("ClipboardWriting is replace-only: no prior value is recoverable through the seam (anti-paste-back)") {
        // Honest rewrite (2026-05-19 test audit): the prior version
        // claimed a "structural proof" but only did a write/read
        // round-trip — a re-added restore() would NOT have failed it.
        // The TYPE is the structural guarantee (the protocol declares
        // exactly writeString/readString); this test pins the
        // *behavioral* consequence the deleted ClipboardStasher would
        // have violated: once a value is overwritten there is NO seam
        // operation that yields the prior value back.
        //
        // (1) Signature witness — these exact members must exist with
        //     these types; a signature drift breaks compilation here.
        let cb: ClipboardWriting = InMemoryClipboard(initial: "ORIG")
        let write: (String) -> Void = cb.writeString
        let read: () -> String? = cb.readString
        // (2) Replace-only + non-recoverable invariant.
        try expect(read() == "ORIG", "initial value visible, got \(read() ?? "nil")")
        write("FIRST")
        write("SECOND")
        try expect(read() == "SECOND", "a write fully replaces, got \(read() ?? "nil")")
        // The only way to see ORIG/FIRST again is to write them again —
        // there is no snapshot/restore/guard entry point, and re-read is
        // idempotent (never resurrects an earlier value).
        try expect(read() == "SECOND" && read() == "SECOND",
                   "re-read is stable and never restores an earlier value")
    }

    await test("InMemoryClipboard initial value is readable before any write") {
        let cb = InMemoryClipboard(initial: "seeded")
        try expect(cb.readString() == "seeded" && cb.writeCount == 0,
                   "an initial value is visible with zero writes, got \(cb.readString() ?? "nil")/\(cb.writeCount)")
    }

    // ---- (d) Change B: Cocoa→Carbon recorder mapping (PURE) ---------
    //
    //   The headlessly-testable heart of the in-Settings hot-key
    //   recorder. The raw NSEvent capture gesture is the documented
    //   operator-smoke ceiling; `HotkeyConfig.from(keyCode:cocoaModifiers:)`
    //   and `isPureModifierKeyCode` are NOT — exhaustively asserted here:
    //   every single modifier, all combinations, the Cocoa→Carbon bit
    //   translation, and every rejection case.

    await test("recorder map: ⌃ alone → controlKey (single-modifier bit)") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_C), cocoaModifiers: [.control])
        try expect(h != nil, "⌃C is a valid chord")
        try expect(h?.carbonModifiers == UInt32(controlKey),
                   "expected controlKey, got \(h?.carbonModifiers ?? 999)")
        try expect(h?.keyCode == UInt32(kVK_ANSI_C), "keyCode must pass through unchanged")
    }

    await test("recorder map: ⌥ alone → optionKey") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_K), cocoaModifiers: [.option])
        try expect(h?.carbonModifiers == UInt32(optionKey),
                   "expected optionKey, got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder map: ⇧ alone → shiftKey") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_K), cocoaModifiers: [.shift])
        try expect(h?.carbonModifiers == UInt32(shiftKey),
                   "expected shiftKey, got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder map: ⌘ alone → cmdKey") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_K), cocoaModifiers: [.command])
        try expect(h?.carbonModifiers == UInt32(cmdKey),
                   "expected cmdKey, got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder map: ⌃⌥⌘ → controlKey|optionKey|cmdKey (the new default shape)") {
        let h = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_C),
            cocoaModifiers: [.control, .option, .command]
        )
        try expect(h != nil, "the triple-modifier chord is valid")
        try expect(h?.carbonModifiers == UInt32(controlKey | optionKey | cmdKey),
                   "Cocoa ⌃⌥⌘ must OR to the exact Carbon mask, got \(h?.carbonModifiers ?? 999)")
        // Identical to the shipping productionDefault (round-trip proof
        // that the recorder can reproduce the default by hand).
        try expect(h == HotkeyConfig.productionDefault,
                   "recording ⌃⌥⌘C must equal productionDefault")
    }

    await test("recorder map: ⌃⇧⌘ all four-minus-option combine correctly") {
        let h = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_P),
            cocoaModifiers: [.control, .shift, .command]
        )
        try expect(h?.carbonModifiers == UInt32(controlKey | shiftKey | cmdKey),
                   "got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder map: all four modifiers → full Carbon mask") {
        let h = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_A),
            cocoaModifiers: [.control, .option, .shift, .command]
        )
        try expect(h?.carbonModifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey),
                   "all four Cocoa flags must map to the OR of all four Carbon bits, got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder map: device-dependent / Fn noise is stripped before mapping") {
        // .function + caps-lock noise must not leak into the Carbon mask;
        // only ⌘ should survive (deviceIndependentFlagsMask intersection).
        let h = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_C),
            cocoaModifiers: [.command, .function, .capsLock]
        )
        try expect(h?.carbonModifiers == UInt32(cmdKey),
                   "Fn/CapsLock must be stripped — only cmdKey survives, got \(h?.carbonModifiers ?? 999)")
    }

    await test("recorder REJECTS a modifier-less chord (nil — would hijack a bare key)") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_C), cocoaModifiers: [])
        try expect(h == nil, "a bare key with no modifier must be rejected, got \(String(describing: h))")
    }

    await test("recorder REJECTS Fn/CapsLock-only as modifier-less (they are not Carbon modifiers)") {
        let h = HotkeyConfig.from(
            keyCode: UInt32(kVK_ANSI_C),
            cocoaModifiers: [.function, .capsLock]
        )
        try expect(h == nil,
                   "Fn/CapsLock are not cmd/opt/ctrl/shift → no Carbon modifier → reject, got \(String(describing: h))")
    }

    await test("recorder REJECTS a pure-modifier key-down (⌘ held, no real key yet)") {
        // The recorder fires keyDown on the modifier key itself before a
        // real key arrives — keyCode is a modifier virtual key. Reject so
        // it never becomes a binding even though .command is "set".
        for code in [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                     kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
                     kVK_CapsLock, kVK_Function] {
            let h = HotkeyConfig.from(keyCode: UInt32(code), cocoaModifiers: [.command])
            try expect(h == nil,
                       "pure-modifier keyCode \(code) must be rejected, got \(String(describing: h))")
            try expect(HotkeyConfig.isPureModifierKeyCode(UInt32(code)),
                       "isPureModifierKeyCode must be true for modifier virtual key \(code)")
        }
    }

    await test("isPureModifierKeyCode is FALSE for ordinary keys (letters/Space)") {
        for code in [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_Z, kVK_Space, kVK_ANSI_0, kVK_ANSI_9] {
            try expect(!HotkeyConfig.isPureModifierKeyCode(UInt32(code)),
                       "ordinary key \(code) must NOT be a pure-modifier code")
        }
    }

    await test("recorder map: a valid chord round-trips through Codable (recorder→persist shape)") {
        let h = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_J), cocoaModifiers: [.control, .command])
        let data = try JSONEncoder().encode(h!)
        let back = try JSONDecoder().decode(HotkeyConfig.self, from: data)
        try expect(back == h, "the recorded config must survive the persistence Codable seam")
    }

    // ---- (e) Change B: hot-key persistence (PURE, injected defaults) -

    await test("loadPersisted falls back to productionDefault when the key is UNSET") {
        let d = UserDefaults(suiteName: "cmd-ux.persist.unset.\(UUID().uuidString)")!
        let loaded = HotkeyConfig.loadPersisted(from: d, key: BridgeDefaults.commandsHotkey)
        try expect(loaded == HotkeyConfig.productionDefault,
                   "an absent key must yield productionDefault (⌃⌥⌘C), got \(loaded.displayString)")
    }

    await test("loadPersisted falls back to productionDefault when the stored bytes are CORRUPT") {
        let suite = "cmd-ux.persist.corrupt.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.set(Data("not valid hotkey json".utf8), forKey: BridgeDefaults.commandsHotkey)
        let loaded = HotkeyConfig.loadPersisted(from: d, key: BridgeDefaults.commandsHotkey)
        try expect(loaded == HotkeyConfig.productionDefault,
                   "corrupt bytes must degrade to productionDefault, not crash, got \(loaded.displayString)")
    }

    await test("persist → loadPersisted round-trips an operator-recorded combo") {
        let suite = "cmd-ux.persist.roundtrip.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        // Record ⌥⌘J via the pure mapping, persist, reload.
        let recorded = HotkeyConfig.from(keyCode: UInt32(kVK_ANSI_J),
                                         cocoaModifiers: [.option, .command])!
        let ok = recorded.persist(to: d, key: BridgeDefaults.commandsHotkey)
        try expect(ok, "persist must succeed for a well-formed config")
        let loaded = HotkeyConfig.loadPersisted(from: d, key: BridgeDefaults.commandsHotkey)
        try expect(loaded == recorded,
                   "a persisted rebind must survive reload exactly, got \(loaded.displayString)")
        try expect(loaded != HotkeyConfig.productionDefault,
                   "the reloaded value must be the recorded combo, NOT the default")
    }

    await test("persist overwrites a prior persisted combo (latest rebind wins)") {
        let suite = "cmd-ux.persist.overwrite.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        HotkeyConfig(keyCode: UInt32(kVK_ANSI_A),
                     carbonModifiers: UInt32(controlKey)).persist(to: d, key: BridgeDefaults.commandsHotkey)
        let second = HotkeyConfig(keyCode: UInt32(kVK_ANSI_B),
                                  carbonModifiers: UInt32(cmdKey | shiftKey))
        second.persist(to: d, key: BridgeDefaults.commandsHotkey)
        try expect(HotkeyConfig.loadPersisted(from: d, key: BridgeDefaults.commandsHotkey) == second,
                   "the most recent persist must win")
    }

    await test("loadPersisted default key is the shared BridgeDefaults.commandsHotkey") {
        try expect(BridgeDefaults.commandsHotkey == "com.notionbridge.commandsHotkey",
                   "the persistence key constant must be stable, got \(BridgeDefaults.commandsHotkey)")
    }
}
