// HotkeyRecorderFocusTests.swift — 3.4.2 W4 H5 regression test
// NotionBridge · Tests
//
// HEADLESSLY TESTED:
//   • RecorderFocusModel transitions (the pure state machine that backs
//     the AppKit RecorderNSView). These tests already exist in
//     CommandsControllerTests; this file adds explicit coverage of the
//     3.4.2 H5 regression scenario at the model level: when an external
//     caller flips `isRecording` via `setRecording(true)` (mimicking the
//     SwiftUI button-binding path), the model immediately becomes
//     focusable (`acceptsFirstResponder == true`). The W4-3.4.1
//     regression was at the NSView-mount layer (a fresh mount in a
//     conditional render meant the SwiftUI-side async makeFirstResponder
//     fired before the view landed in a window — silent no-op). The fix
//     overrode `viewDidMoveToWindow` to grab focus on mount AND added a
//     synchronous focus-grab in `applyRecording` when transitioning
//     FALSE→TRUE in an already-windowed view. The NSView side is the
//     documented operator-smoke ceiling; this file locks the contract
//     beneath it.
//
// LOCK invariant: a button-binding path (setRecording(true) without a
// click) MUST leave the model in a state where the NSView will be made
// first responder on its next windowing event. Specifically:
//   • acceptsFirstResponder == true after setRecording(true)
//   • setRecording(true) is idempotent
//   • setRecording(false) clears recording without focus implications

import Foundation
import NotionBridgeLib

func runHotkeyRecorderFocusTests() async {
    print("\n\u{2328}\u{FE0F}  Hotkey Recorder Focus Tests (3.4.2 W4 H5 regression)")

    await test("3.4.2 H5: setRecording(true) makes the model focusable (button-binding path)") {
        var m = RecorderFocusModel()
        try expect(m.isRecording == false)
        try expect(m.acceptsFirstResponder == false,
                   "initial state must not steal focus")
        m.setRecording(true)
        try expect(m.isRecording == true)
        try expect(m.acceptsFirstResponder == true,
                   "after the SwiftUI button-binding flips setRecording(true), the NSView must be eligible to take first responder — the W4-3.4.1 regression was a freshly-mounted view's `window` being nil at the moment the SwiftUI-side async makeFirstResponder fired; the model side has always been correct")
    }

    await test("3.4.2 H5: setRecording is idempotent (true→true stays focusable)") {
        var m = RecorderFocusModel(isRecording: true)
        m.setRecording(true)
        try expect(m.isRecording == true)
        try expect(m.acceptsFirstResponder == true)
    }

    await test("3.4.2 H5: setRecording(false) clears recording (and focus eligibility)") {
        var m = RecorderFocusModel(isRecording: true)
        m.setRecording(false)
        try expect(m.isRecording == false)
        try expect(m.acceptsFirstResponder == false,
                   "ending recording also surrenders focus eligibility so the field doesn't keep stealing focus when idle")
    }

    await test("3.4.2 H5: clickToRecord path (standalone) still works (Bug-1 baseline preserved)") {
        var m = RecorderFocusModel()
        m.clickToRecord()
        try expect(m.isRecording == true)
        try expect(m.acceptsFirstResponder == true,
                   "the 3.2.0 Bug-1 fix — click directly grabs focus — must remain intact")
    }

    await test("3.4.2 H5: escape during recording cancels without changing the bind") {
        var m = RecorderFocusModel(isRecording: true)
        m.escape()
        try expect(m.isRecording == false,
                   "escape exits capture state")
        try expect(m.acceptsFirstResponder == false)
    }

    await test("3.4.2 H5: captured(accepted: true) ends recording; captured(accepted: false) keeps recording") {
        var accepted = RecorderFocusModel(isRecording: true)
        accepted.captured(accepted: true)
        try expect(accepted.isRecording == false,
                   "an accepted chord ends capture")

        var rejected = RecorderFocusModel(isRecording: true)
        rejected.captured(accepted: false)
        try expect(rejected.isRecording == true,
                   "a rejected chord keeps the field recording so the user can immediately retry")
        try expect(rejected.acceptsFirstResponder == true)
    }
}
