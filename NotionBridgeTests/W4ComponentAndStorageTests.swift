// W4ComponentAndStorageTests.swift — cmd-ux W4 (3.4.1) UI components + file-source flag storage
// NotionBridge · Tests
//
// HEADLESSLY TESTED:
//   • BridgeKbdChips.init(displayString:) splits modifier symbols into
//     individual chips; trailing non-modifier characters become the
//     final chip. Empty / lone-key / lone-modifier strings handled.
//   • SkillsModule per-path flag storage for file-source skills round-
//     trips through UserDefaults (`fileSkillRoutingDiscoverable` +
//     `fileSkillInCommandPalette`).
//   • Effective routing-discoverable for a file-source skill prefers
//     explicit toggle over frontmatter `visibility: routing` default;
//     when no explicit toggle is set, the frontmatter wins; when neither
//     is set, defaults to false.
//   • Effective palette-membership for a file-source skill requires an
//     explicit opt-in toggle (no frontmatter default — conservative).
//
// OPERATOR-SMOKE CEILING (NOT faked): the SwiftUI rendering of
// BridgeKbdChips / BridgeEmptyState / BridgeBadge — the DECISIONS
// beneath (chip splitting, color tone, predicate) are pure and asserted
// here. The same components are reused across tabs in W3, so a
// regression here would visibly land across every settings surface.

import Foundation
import NotionBridgeLib

func runW4ComponentAndStorageTests() async {
    print("\n\u{1F3DB}\u{FE0F}  W4 Components + File-source Flag Storage Tests")

    // ── BridgeKbdChips chip splitter ───────────────────────────────────
    await test("W4 kbd chips: ⌃⌥⌘C splits into 4 chips") {
        let chips = BridgeKbdChips.splitChips(displayString: "\u{2303}\u{2325}\u{2318}C")
        try expect(chips == ["\u{2303}", "\u{2325}", "\u{2318}", "C"],
                   "modifier+key string must split per modifier glyph; got \(chips)")
    }

    await test("W4 kbd chips: shift-space splits into 2 chips") {
        let chips = BridgeKbdChips.splitChips(displayString: "\u{21E7}Space")
        try expect(chips == ["\u{21E7}", "Space"],
                   "single modifier + multi-char key holds together; got \(chips)")
    }

    await test("W4 kbd chips: lone key (no modifiers) is a single chip") {
        let chips = BridgeKbdChips.splitChips(displayString: "F12")
        try expect(chips == ["F12"], "got \(chips)")
    }

    await test("W4 kbd chips: empty string yields zero chips") {
        let chips = BridgeKbdChips.splitChips(displayString: "")
        try expect(chips.isEmpty, "got \(chips)")
    }

    await test("W4 kbd chips: multi-modifier no-key splits cleanly (degenerate but valid)") {
        let chips = BridgeKbdChips.splitChips(displayString: "\u{2303}\u{2318}")
        try expect(chips == ["\u{2303}", "\u{2318}"], "got \(chips)")
    }

    // ── File-source flag storage round-trip ────────────────────────────
    @Sendable func tmpURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("w4-\(UUID().uuidString).md")
    }

    await test("W4 storage: setFileSkillRoutingDiscoverable round-trips per-path") {
        let path = tmpURL()
        // Baseline: no entry → explicit returns nil.
        try expect(SkillsModule.explicitFileSkillRoutingDiscoverable(path: path) == nil,
                   "missing entry must return nil so callers can apply their own default")

        SkillsModule.setFileSkillRoutingDiscoverable(path: path, value: true)
        try expect(SkillsModule.explicitFileSkillRoutingDiscoverable(path: path) == true,
                   "write must persist; got \(String(describing: SkillsModule.explicitFileSkillRoutingDiscoverable(path: path)))")

        SkillsModule.setFileSkillRoutingDiscoverable(path: path, value: false)
        try expect(SkillsModule.explicitFileSkillRoutingDiscoverable(path: path) == false,
                   "toggle off must persist as false (not removed)")

        // Cleanup (best-effort).
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]) ?? [:]
        dict.removeValue(forKey: path.path)
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillRoutingDiscoverable)
    }

    await test("W4 storage: setFileSkillInCommandPalette round-trips per-path") {
        let path = tmpURL()
        try expect(SkillsModule.explicitFileSkillInCommandPalette(path: path) == nil)
        SkillsModule.setFileSkillInCommandPalette(path: path, value: true)
        try expect(SkillsModule.isFileSkillInCommandPalette(path: path) == true)
        SkillsModule.setFileSkillInCommandPalette(path: path, value: false)
        try expect(SkillsModule.isFileSkillInCommandPalette(path: path) == false)

        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]) ?? [:]
        dict.removeValue(forKey: path.path)
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillInCommandPalette)
    }

    // ── Effective routing/palette resolution ───────────────────────────
    await test("W4 effective routing: explicit toggle wins over frontmatter") {
        let path = tmpURL()
        let frontmatterRouting: [String: Any] = ["visibility": "routing"]
        let frontmatterStandard: [String: Any] = ["visibility": "standard"]

        // Frontmatter says routing, no explicit → effective true.
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: frontmatterRouting) == true,
                   "frontmatter visibility:routing must promote when no explicit toggle exists")

        // Frontmatter says standard, no explicit → effective false.
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: frontmatterStandard) == false)

        // Explicit override flips both ways regardless of frontmatter.
        SkillsModule.setFileSkillRoutingDiscoverable(path: path, value: false)
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: frontmatterRouting) == false,
                   "explicit false must override frontmatter routing")

        SkillsModule.setFileSkillRoutingDiscoverable(path: path, value: true)
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: frontmatterStandard) == true,
                   "explicit true must override frontmatter standard")

        // Cleanup.
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]) ?? [:]
        dict.removeValue(forKey: path.path)
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillRoutingDiscoverable)
    }

    await test("W4 effective palette: requires explicit opt-in (no frontmatter default)") {
        let path = tmpURL()
        // No explicit toggle, no frontmatter (palette doesn't consult it) → false.
        try expect(SkillsModule.isFileSkillInCommandPalette(path: path) == false,
                   "file-source palette membership must require explicit opt-in")

        SkillsModule.setFileSkillInCommandPalette(path: path, value: true)
        try expect(SkillsModule.isFileSkillInCommandPalette(path: path) == true)

        // Cleanup.
        var dict = (UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]) ?? [:]
        dict.removeValue(forKey: path.path)
        UserDefaults.standard.set(dict, forKey: BridgeDefaults.fileSkillInCommandPalette)
    }
}
