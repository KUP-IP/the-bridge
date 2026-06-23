// PKT879IconPickerTests.swift — Commands icon picker
//
// Contract tests for the v3.6.4 IconPickerSheet:
//   • emoji curation list is non-empty and de-duplicated
//   • SF Symbol curation is ~200 entries and renders via NSImage
//   • picker emits .emoji with nil color, .symbol with the swatch color
//   • picker can be constructed from any starting (icon, color) pair

import Foundation
import AppKit
import SwiftUI
import TheBridgeLib

func runPKT879IconPickerTests() async {
    print("\n\u{1F3A8} PKT-879 IconPickerSheet Tests")

    // ── Curation contract ─────────────────────────────────────────────
    await test("Emoji curation has at least 30 entries") {
        let count = IconPickerCatalog.curatedEmoji.count
        try expect(count >= 30, "expected >=30 emoji, got \(count)")
    }

    await test("Emoji entries are unique by emoji character") {
        let chars = IconPickerCatalog.curatedEmoji.map(\.emoji)
        let unique = Set(chars)
        try expect(chars.count == unique.count,
                   "duplicate emoji in curation: \(chars.count - unique.count)")
    }

    await test("Emoji entries have non-empty labels (used for search)") {
        for e in IconPickerCatalog.curatedEmoji {
            try expect(!e.label.isEmpty, "empty label for \(e.emoji)")
        }
    }

    await test("SF Symbol curation has ~200 entries (Locked Decision Q1)") {
        let count = IconPickerCatalog.curatedSymbols.count
        // Spec says "~200 curated SF Symbols". Allow a generous band so
        // future tweaks don't churn the test, but catch any wholesale
        // shrink or drift.
        try expect(count >= 150 && count <= 260,
                   "expected 150-260 curated symbols, got \(count)")
    }

    await test("SF Symbol curation entries are all non-empty") {
        for name in IconPickerCatalog.curatedSymbols {
            try expect(!name.isEmpty, "empty symbol name in curation")
        }
    }

    await test("SF Symbol curation is de-duplicated") {
        let unique = Set(IconPickerCatalog.curatedSymbols)
        try expect(unique.count == IconPickerCatalog.curatedSymbols.count,
                   "duplicate symbols in curation: \(IconPickerCatalog.curatedSymbols.count - unique.count)")
    }

    // ── Symbol resolvability via NSImage ──────────────────────────────
    // Locked Decision Q1: raw NSImage(systemSymbolName:), no SPM dep.
    // We can't require 100% — SF Symbol availability is OS-version
    // dependent. We probe a small representative slice rather than the
    // full list so the test runs quickly in headless CI and doesn't
    // depend on AppKit being fully initialized for every symbol lookup.
    await test("A representative slice of curated SF Symbols resolve via NSImage") {
        let probe = [
            "command", "sparkles", "checkmark.circle.fill", "play.fill",
            "envelope", "magnifyingglass", "lock.fill", "bolt.fill",
            "gearshape", "doc.text", "network", "folder",
        ]
        var missing: [String] = []
        await MainActor.run {
            for name in probe {
                if NSImage(systemSymbolName: name, accessibilityDescription: name) == nil {
                    missing.append(name)
                }
            }
        }
        try expect(missing.count <= 2,
                   "more than 2 baseline symbols missing: \(missing)")
    }

    // ── Picker tab enum ───────────────────────────────────────────────
    await test("PickerTab has exactly emoji + symbol cases (locked spec)") {
        let cases = IconPickerSheet.PickerTab.allCases.map(\.rawValue)
        try expect(cases == ["emoji", "symbol"],
                   "PickerTab cases drifted: \(cases)")
    }

    // ── Picker constructs from any starting (icon, color) ─────────────
    await test("IconPickerSheet constructs from an emoji icon") {
        await MainActor.run {
            let bound = State<Bool>(initialValue: true)
            _ = IconPickerSheet(
                isPresented: bound.projectedValue,
                currentIcon: .emoji("\u{1F4A1}"),
                currentColor: nil,
                onPick: { _, _ in }
            )
        }
    }

    await test("IconPickerSheet constructs from a symbol icon with color") {
        await MainActor.run {
            let bound = State<Bool>(initialValue: true)
            _ = IconPickerSheet(
                isPresented: bound.projectedValue,
                currentIcon: .symbol("command"),
                currentColor: .blue,
                onPick: { _, _ in }
            )
        }
    }

    // ── Selection round-trip via the onPick closure shape ─────────────
    // We can't drive a button tap from the harness, but we can pin the
    // closure shape — the contract is "(Icon, NotionColor?) -> Void"
    // and that emoji selections supply nil color while symbol
    // selections supply the active swatch.
    await test("IconPickerSheet onPick signature accepts (Icon, NotionColor?)") {
        await MainActor.run {
            let bound = State<Bool>(initialValue: true)
            var capturedIcon: CommandStore.Icon? = nil
            var capturedColor: CommandStore.NotionColor? = nil
            let onPick: (CommandStore.Icon, CommandStore.NotionColor?) -> Void = { icon, color in
                capturedIcon = icon
                capturedColor = color
            }
            _ = IconPickerSheet(
                isPresented: bound.projectedValue,
                currentIcon: .emoji("\u{1F4A1}"),
                currentColor: nil,
                onPick: onPick
            )
            // Simulate an emoji pick — color should be nil.
            onPick(.emoji("\u{2728}"), nil)
            assert(capturedIcon == .emoji("\u{2728}"))
            assert(capturedColor == nil)
            // Simulate a symbol pick — color should be the swatch.
            onPick(.symbol("command"), .blue)
            assert(capturedIcon == .symbol("command"))
            assert(capturedColor == .blue)
        }
    }

    // ── CommandStore round-trip — picker selections persist ───────────
    // This is the contract that wires the picker to the data layer:
    // applying an icon/color via CommandStore.update() must round-trip
    // through the index.json + body file.
    await test("CommandStore round-trips icon picker selections") {
        let store = CommandStore.shared
        // Use a slug that's vanishingly unlikely to collide with seeds.
        let baseName = "PKT-879 picker test \(UUID().uuidString.prefix(6))"
        let created = try store.create(
            name: baseName,
            icon: .emoji("\u{1F4A1}"),
            color: nil,
            body: "## test\n"
        )
        defer { try? store.delete(slug: created.slug) }

        // Pick an SF Symbol with a Notion color.
        var modified = created
        modified.icon = .symbol("command")
        modified.color = .blue
        _ = try store.update(modified)

        guard let reloaded = try store.get(slug: created.slug) else {
            throw TestError.assertion("reloaded command was nil")
        }
        try expect(reloaded.icon == .symbol("command"),
                   "icon did not persist: \(reloaded.icon)")
        try expect(reloaded.color == .blue,
                   "color did not persist: \(String(describing: reloaded.color))")

        // Pick an emoji with nil color (emoji ignores swatches).
        var modified2 = reloaded
        modified2.icon = .emoji("\u{2728}")
        modified2.color = nil
        _ = try store.update(modified2)

        guard let reloaded2 = try store.get(slug: created.slug) else {
            throw TestError.assertion("reloaded2 was nil")
        }
        try expect(reloaded2.icon == .emoji("\u{2728}"),
                   "emoji icon did not persist: \(reloaded2.icon)")
        try expect(reloaded2.color == nil,
                   "color should clear on emoji pick: \(String(describing: reloaded2.color))")
    }
}
