// CommandBridgeControllerTests.swift — PKT-878 v3.6.3
// TheBridge · Tests
//
// Headless coverage for the SwiftUI Command Bridge popup. The Carbon
// hot-key firing on a live WindowServer, the non-activating NSPanel
// becoming key without activating the app, and the SwiftUI rendering
// are all an explicit operator-smoke ceiling (documented in
// `docs/operator/command-bridge-smoke-checklist.md`). What this file
// asserts headlessly is the DECISION layer underneath:
//
//   (A) Placement math: bottom-center-25% anchor (locked Q2).
//   (B) CommandBridgeRecents in-memory MRU log (locked Q1 — no persist).
//   (C) CommandBridgeAnimation values + reduce-motion collapse.
//   (D) CommandBridgeViewModel.buildSlotRows / buildRecentRows /
//       queryDidChange — the pure builders driving the SwiftUI tray and
//       secondary panel.
//   (E) CommandBridgeController.applyCommit clipboard contract preserved
//       byte-for-byte from the retired CommandBoxController.
//   (F) Lifecycle reset shape (open → closed) without touching AppKit.
//   (G) Hot-key plumbing-failure shape: modifier-less ⇒ .plumbingFailure.

import Foundation
import AppKit
import Carbon.HIToolbox
import TheBridgeLib

func runCommandBridgeControllerTests() async {
    print("\n\u{1F9F1}  CommandBridge Tests (PKT-878 v3.6.3 · popup rebuild)")

    // ── (A) Placement math ──────────────────────────────────────────

    await test("Placement: panel centre anchored 25% up from bottom (Q2 locked)") {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 640, height: 460)
        let o = CommandBridgeController.placementOrigin(
            screenVisibleFrame: frame, panelSize: size)
        try expect(o.x == frame.midX - size.width / 2,
                   "x must centre horizontally, got \(o.x)")
        let expectedY = frame.minY + 900 * 0.25 - size.height / 2
        try expect(o.y == expectedY,
                   "y must place the panel CENTRE at 25% up; expected \(expectedY), got \(o.y)")
    }

    await test("Placement: math is independent of screen origin (multi-monitor)") {
        // A second display offset to (1440, 0) must use its own coords.
        let frame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 640, height: 460)
        let o = CommandBridgeController.placementOrigin(
            screenVisibleFrame: frame, panelSize: size)
        try expect(o.x == 1440 + (1920 - 640) / 2,
                   "x must centre relative to the screen's own origin, got \(o.x)")
        try expect(o.y == 0 + 1080 * 0.25 - 230,
                   "y must compute against the screen's own minY, got \(o.y)")
    }

    await test("Placement: pickScreenFrame prefers the screen containing the key window") {
        let s0 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let s1 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let keyOnS1 = CGRect(x: 1400, y: 300, width: 200, height: 200)
        let hit = CommandBridgeController.pickScreenFrame(
            screens: [s0, s1], keyWindowFrame: keyOnS1,
            mouseLocation: CGPoint(x: 10, y: 10), mainScreenFrame: s0)
        try expect(hit == s1, "the panel must open on the key window's screen, got \(String(describing: hit))")
    }

    // ── (B) Recents tracker (in-memory MRU, session-only — Q1) ──────

    await test("Recents: starts empty, no persistence (Q1 locked)") {
        let r = CommandBridgeRecents(cap: 5)
        try expect(r.ordered.isEmpty, "fresh recents tracker must be empty")
    }

    await test("Recents: record moves the slug to the front (MRU)") {
        let r = CommandBridgeRecents(cap: 5)
        _ = r.record("alpha")
        _ = r.record("bravo")
        _ = r.record("alpha")  // bumps alpha back to front
        try expect(r.ordered == ["alpha", "bravo"],
                   "MRU order must be [alpha, bravo], got \(r.ordered)")
    }

    await test("Recents: cap trims the tail (oldest dropped)") {
        let r = CommandBridgeRecents(cap: 3)
        for s in ["a", "b", "c", "d", "e"] { _ = r.record(s) }
        try expect(r.ordered == ["e", "d", "c"],
                   "cap=3 must keep the 3 most recent, got \(r.ordered)")
    }

    await test("Recents: reset empties the log") {
        let r = CommandBridgeRecents(cap: 5)
        _ = r.record("x"); _ = r.record("y")
        r.reset()
        try expect(r.ordered.isEmpty, "reset must clear; got \(r.ordered)")
    }

    // ── (C) Animation config (180ms open + 10ms cascade + reduce) ──

    await test("Animation: locked values match PKT-878 spec exactly") {
        let a = CommandBridgeAnimation.locked
        try expect(a.openDuration == 0.180,
                   "open duration must be 180ms, got \(a.openDuration)")
        try expect(a.bubbleCascadeStagger == 0.010,
                   "cascade stagger must be 10ms, got \(a.bubbleCascadeStagger)")
        try expect(a.recentsSlideDuration == 0.140,
                   "recents slide must be 140ms, got \(a.recentsSlideDuration)")
        try expect(a.openStartScale == 0.94, "start scale 0.94")
        try expect(a.openStartOpacity == 0.0, "start opacity 0")
    }

    await test("Animation: reduceMotion collapses every duration to 0 (instant)") {
        let a = CommandBridgeAnimation.reduced
        try expect(a.openDuration == 0, "open must collapse to instant")
        try expect(a.bubbleCascadeStagger == 0, "stagger must collapse to instant")
        try expect(a.recentsSlideDuration == 0, "recents must collapse to instant")
        try expect(a.openStartScale == 1.0, "start scale must be 1.0 when reducing")
        try expect(a.openStartOpacity == 1.0, "start opacity must be 1.0 when reducing")
    }

    // ── (D) ViewModel pure builders ─────────────────────────────────

    func cmd(_ name: String, slot: Int?, lastUsed: Date? = nil) -> CommandStore.Command {
        CommandStore.Command(
            slug: CommandStore.slugify(name),
            name: name,
            icon: .emoji("⭐"),
            color: nil,
            keySlot: slot,
            lastUsedAt: lastUsed,
            body: "BODY-\(name)")
    }

    await test("ViewModel: buildSlotRows returns 10 slots in display order 1…9,0") {
        let rows = CommandBridgeViewModel.buildSlotRows(from: [])
        try expect(rows.count == 10, "must always be 10 slots, got \(rows.count)")
        try expect(rows.map(\.displayKey) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
                   "display order must be 1…9 then 0 (locked design), got \(rows.map(\.displayKey))")
        try expect(rows.allSatisfy { $0.command == nil },
                   "empty store ⇒ every slot's command is nil")
    }

    await test("ViewModel: buildSlotRows binds favorites by keySlot") {
        let a = cmd("Execute",  slot: 1)
        let b = cmd("Discuss",  slot: 4)
        let c = cmd("Loops",    slot: 7)
        let z = cmd("Close",    slot: 9)
        let rows = CommandBridgeViewModel.buildSlotRows(from: [a, b, c, z])
        try expect(rows[0].command?.slug == "execute", "slot 1 must hold Execute")
        try expect(rows[3].command?.slug == "discuss", "slot 4 must hold Discuss")
        try expect(rows[6].command?.slug == "loops",   "slot 7 must hold Loops")
        try expect(rows[8].command?.slug == "close",   "slot 9 must hold Close")
        try expect(rows[1].command == nil,             "slot 2 stays empty")
        try expect(rows[9].command == nil,             "slot 0 stays empty (display index 10)")
    }

    await test("ViewModel: buildRecentRows respects the MRU order and drops missing slugs") {
        let a = cmd("Execute",  slot: 1)
        let b = cmd("Discuss",  slot: 4)
        let c = cmd("Loops",    slot: 7)
        let rows = CommandBridgeViewModel.buildRecentRows(
            from: [a, b, c],
            order: ["loops", "execute", "ghost-slug-not-in-store"])
        try expect(rows.map(\.slug) == ["loops", "execute"],
                   "MRU order wins; ghost slugs are dropped — got \(rows.map(\.slug))")
    }

    await test("ViewModel: empty MRU order ⇒ no recents rows") {
        let a = cmd("Execute", slot: 1)
        let rows = CommandBridgeViewModel.buildRecentRows(from: [a], order: [])
        try expect(rows.isEmpty, "no MRU ⇒ no recents")
    }

    // ── (E) Clipboard contract — applyCommit preserved byte-for-byte ─

    await test("applyCommit(.paste) writes the resolved body once (clipboard contract)") {
        let cb = InMemoryClipboard(initial: "prior")
        let mgr = CommandsManager(fetcher: { _ in "{}" })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(), manager: mgr)
        let ctrl = await CommandBridgeController(clipboard: cb, coordinator: coord)
        await ctrl.applyCommit(.paste("hello-bridge"))
        try expect(cb.readString() == "hello-bridge",
                   "exact body must reach the clipboard, got \(cb.readString() ?? "nil")")
        try expect(cb.writeCount == 1, "exactly one write, got \(cb.writeCount)")
    }

    await test("applyCommit(.notFound) writes nothing (no clobber)") {
        let cb = InMemoryClipboard(initial: "prior")
        let mgr = CommandsManager(fetcher: { _ in "{}" })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(), manager: mgr)
        let ctrl = await CommandBridgeController(clipboard: cb, coordinator: coord)
        await ctrl.applyCommit(.notFound(query: "zzzz"))
        try expect(cb.writeCount == 0, "no write on .notFound")
        try expect(cb.readString() == "prior", "clipboard untouched on no-match")
    }

    await test("applyCommit(.paste) with empty body no-ops (no blank clobber)") {
        let cb = InMemoryClipboard(initial: "prior")
        let mgr = CommandsManager(fetcher: { _ in "{}" })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(), manager: mgr)
        let ctrl = await CommandBridgeController(clipboard: cb, coordinator: coord)
        await ctrl.applyCommit(.paste(""))
        try expect(cb.writeCount == 0, "empty body must NOT blank-clobber")
        try expect(cb.readString() == "prior", "clipboard untouched on empty body")
    }

    // ── (F) Lifecycle defaults (closed at init, no panel constructed) ─

    await test("Controller: lifecycle starts at .closed and isVisible is false") {
        let cb = InMemoryClipboard()
        let mgr = CommandsManager(fetcher: { _ in "{}" })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(), manager: mgr)
        let ctrl = await CommandBridgeController(clipboard: cb, coordinator: coord)
        let isClosed = await (ctrl.lifecycle == .closed)
        let isVisible = await ctrl.isVisible
        try expect(isClosed, "fresh controller must be .closed")
        try expect(!isVisible, "fresh controller must NOT be visible")
    }

    // ── (G) Hot-key plumbing failure shape ──────────────────────────

    await test("registerHotkey: modifier-less ⇒ .plumbingFailure (NEVER .collision)") {
        let bad = HotkeyConfig(keyCode: UInt32(kVK_Space), carbonModifiers: 0)
        let cb = InMemoryClipboard()
        let mgr = CommandsManager(fetcher: { _ in "{}" })
        let coord = CommandPaletteCoordinator(
            provider: StaticCommandDescriptorProvider(), manager: mgr)
        let ctrl = await CommandBridgeController(hotkey: bad, clipboard: cb, coordinator: coord)
        let ok = await ctrl.registerHotkey()
        let status = await ctrl.lastRegisterStatus
        try expect(!ok, "modifier-less combo must be refused")
        if case .plumbingFailure = status { } else {
            throw TestError.assertion(
                "modifier-less ⇒ .plumbingFailure (NEVER .collision); got \(status)")
        }
    }

    // ── (H) Search query routing — empty resets panelMode to .none ──

    await test("ViewModel.queryDidChange: empty input clears search panel") {
        let queryNotNone = await MainActor.run { () -> Bool in
            let vm = CommandBridgeViewModel(
                store: CommandStore.shared, recents: CommandBridgeRecents(cap: 1))
            vm.queryDidChange("close")
            if case .none = vm.panelMode { return false }
            return true
        }
        try expect(queryNotNone, "non-empty query must set panelMode to .search")
        let nowNone = await MainActor.run { () -> Bool in
            let vm = CommandBridgeViewModel(
                store: CommandStore.shared, recents: CommandBridgeRecents(cap: 1))
            vm.queryDidChange("anything")
            vm.queryDidChange("")
            if case .none = vm.panelMode { return true }
            return false
        }
        try expect(nowNone, "empty query must clear panelMode back to .none")
    }

    // ── (I) W4 keyboard traversal — the selection model behind ↓/↑/Enter ──

    await test("ViewModel.moveSelection: ↓ from the closed tray opens recents + selects first") {
        let r = await MainActor.run { () -> (Bool, String) in
            let vm = CommandBridgeViewModel(
                store: CommandStore.shared, recents: CommandBridgeRecents(cap: 5))
            let a = cmd("Alpha", slot: 1); let b = cmd("Bravo", slot: 2)
            vm.recentRows = CommandBridgeViewModel.buildRecentRows(
                from: [a, b], order: ["alpha", "bravo"])
            vm.panelMode = .none
            vm.moveSelection(1)
            let opened: Bool = { if case .recents = vm.panelMode { return true }; return false }()
            return (opened, vm.selectedSlug ?? "")
        }
        try expect(r.0, "↓ from the closed tray opens recents")
        try expect(r.1 == "alpha", "↓ from closed selects the first recent, got \(r.1)")
    }

    await test("ViewModel.moveSelection/commitSelected: ↓/↑ traverse + clamp; Enter fires the SELECTED row") {
        let result = await MainActor.run { () -> [String] in
            let vm = CommandBridgeViewModel(
                store: CommandStore.shared, recents: CommandBridgeRecents(cap: 5))
            let a = cmd("Alpha", slot: 1); let b = cmd("Bravo", slot: 2); let c = cmd("Charlie", slot: 3)
            vm.recentRows = CommandBridgeViewModel.buildRecentRows(
                from: [a, b, c], order: ["alpha", "bravo", "charlie"])
            vm.panelMode = .recents
            vm.selectedSlug = vm.recentRows.first?.slug
            var fired = ""
            vm.onFireSlug = { fired = $0 }
            vm.moveSelection(1);  let s1 = vm.selectedSlug ?? ""
            vm.moveSelection(1);  let s2 = vm.selectedSlug ?? ""
            vm.moveSelection(1);  let s3 = vm.selectedSlug ?? ""   // clamp at the end
            vm.moveSelection(-1); let s4 = vm.selectedSlug ?? ""
            vm.commitSelected()                                    // fires s4 (bravo)
            return [s1, s2, s3, s4, fired]
        }
        try expect(result[0] == "bravo",   "↓ alpha→bravo, got \(result[0])")
        try expect(result[1] == "charlie", "↓ bravo→charlie, got \(result[1])")
        try expect(result[2] == "charlie", "↓ at end clamps at charlie, got \(result[2])")
        try expect(result[3] == "bravo",   "↑ charlie→bravo, got \(result[3])")
        try expect(result[4] == "bravo",   "Enter fires the SELECTED row (bravo), not the first, got \(result[4])")
    }
}
