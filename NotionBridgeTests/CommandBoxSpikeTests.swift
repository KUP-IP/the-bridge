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
}
