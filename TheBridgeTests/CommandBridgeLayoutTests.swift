// CommandBridgeLayoutTests.swift — v4 round-2
// TheBridge · Tests
//
// Pure layout / placement math for the Command Bridge palette, asserted
// headlessly via the custom harness (NOT XCTest — see TestRunner.swift):
//   • adaptive width clamp — favorite count → bar width, clamped to [half, full]
//   • remembered drag-origin clamp — keep the panel fully on-screen on reopen
//
// Both helpers are `nonisolated static` on CommandBridgeController, so they run
// with no WindowServer / MainActor hop. These pin the two NEW behaviours the
// operator asked for (round-2): the bar adapts to the favorite count + centres,
// and a dragged position is restored within the session but can never strand
// the palette off the visible frame.

import Foundation
import CoreGraphics
import TheBridgeLib

func runCommandBridgeLayoutTests() async {
    print("\n\u{1F9F1}  CommandBridge Layout Tests (v4 round-2 · adaptive width + drag memory)")

    await test("Adaptive width: tracks favorite count, clamped to [half, full]") {
        let full: CGFloat = 640
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 0,  full: full) == 320,
                   "0 favorites floors at half width (320)")
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 1,  full: full) == 320,
                   "1 favorite floors at half width (320)")
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 5,  full: full) == 320,
                   "5 favorites ≈ half width (320)")
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 7,  full: full) == 448,
                   "7 favorites grows past the floor (7×64=448)")
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 10, full: full) == 640,
                   "10 favorites = full width (640)")
        try expect(CommandBridgeController.paletteWidth(favoriteCount: 20, full: full) == 640,
                   "beyond 10 never exceeds full width (640)")
    }

    await test("Drag memory: clampOrigin keeps the panel fully on-screen") {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 640, height: 360)

        let inside = CommandBridgeController.clampOrigin(
            CGPoint(x: 100, y: 100), toScreens: [screen], panelSize: size)
        try expect(inside == CGPoint(x: 100, y: 100),
                   "in-bounds origin is unchanged, got \(inside)")

        let tr = CommandBridgeController.clampOrigin(
            CGPoint(x: 5000, y: 5000), toScreens: [screen], panelSize: size)
        try expect(tr.x == 1440 - 640 && tr.y == 900 - 360,
                   "off top-right clamps to the max in-bounds origin, got \(tr)")

        let bl = CommandBridgeController.clampOrigin(
            CGPoint(x: -500, y: -500), toScreens: [screen], panelSize: size)
        try expect(bl == CGPoint(x: 0, y: 0),
                   "off bottom-left clamps to the screen origin, got \(bl)")

        let none = CommandBridgeController.clampOrigin(
            CGPoint(x: 7, y: 7), toScreens: [], panelSize: size)
        try expect(none == CGPoint(x: 7, y: 7),
                   "no screens → returned as-is, got \(none)")
    }
}
