// SkillListNavigationTests.swift — PKT-1003 Skills Truth-Up · Wave D
// TheBridge · Tests
//
// Locks the pure navigation math behind the Skills detail-header up/down arrows
// (which now NAVIGATE the visible list rather than reorder the store). Boundary
// behavior (no wrap), absent-name, and multi-step are asserted here; the actual
// selection mutation + the confirm-gated delete are SwiftUI-bound and verified
// on-device.

import Foundation
import TheBridgeLib

func runSkillListNavigationTests() async {
    print("\n\u{2195}\u{FE0F} PKT-1003 SkillListNavigation (detail-header prev/next)")

    let order = ["focus-keepr", "executor", "orchestrator", "pdf"]

    await test("nav: next moves forward, prev moves back") {
        try expect(SkillListNavigation.target(from: "executor", delta: +1, in: order) == "orchestrator",
                   "next from executor should be orchestrator")
        try expect(SkillListNavigation.target(from: "executor", delta: -1, in: order) == "focus-keepr",
                   "prev from executor should be focus-keepr")
    }

    await test("nav: boundaries do not wrap (nil at the ends)") {
        try expect(SkillListNavigation.target(from: "focus-keepr", delta: -1, in: order) == nil,
                   "prev from the first item should be nil")
        try expect(SkillListNavigation.target(from: "pdf", delta: +1, in: order) == nil,
                   "next from the last item should be nil")
    }

    await test("nav: absent name yields nil") {
        try expect(SkillListNavigation.target(from: "not-in-list", delta: +1, in: order) == nil,
                   "absent name should yield nil")
    }

    await test("nav: empty list yields nil") {
        try expect(SkillListNavigation.target(from: "anything", delta: +1, in: []) == nil,
                   "empty order should yield nil")
    }

    await test("nav: multi-step delta lands on the right item, clamped to nil past the end") {
        try expect(SkillListNavigation.target(from: "focus-keepr", delta: +2, in: order) == "orchestrator",
                   "two steps from focus-keepr should be orchestrator")
        try expect(SkillListNavigation.target(from: "focus-keepr", delta: +9, in: order) == nil,
                   "overshoot should be nil (no wrap)")
    }

    // NOTE: the destructive delete is confirm-gated in the view (an .alert with
    // a "Delete <name>" destructive button + Cancel, calling
    // SkillsManager.removeSkill). It is NOT exercised here because removeSkill
    // persists to the SHARED `com.notionbridge.skills` UserDefaults (no test
    // isolation seam), so driving it in-suite would mutate the operator's real
    // skills. The delete + confirm-gate are verified on-device.
}
