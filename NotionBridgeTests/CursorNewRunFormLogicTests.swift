// CursorNewRunFormLogicTests.swift — PKT-3.4.2 Wave 5b (Bridge v2.2)
// Coverage scenario F4: new-run modal validation + submit gating.
// Pure-function tests against `CursorNewRunFormLogic`.

import Foundation
import NotionBridgeLib

func runCursorNewRunFormLogicTests() async {
    print("\n\u{1F500} CursorNewRunFormLogic Tests (PKT-3.4.2 Wave 5b · F4)")

    await test("F4: prompt validator rejects empty / whitespace-only") {
        try expect(CursorNewRunFormLogic.isPromptValid("") == false)
        try expect(CursorNewRunFormLogic.isPromptValid("   \n\t  ") == false)
        try expect(CursorNewRunFormLogic.isPromptValid("refactor X") == true)
        try expect(CursorNewRunFormLogic.isPromptValid("  ok  ") == true)
    }

    await test("F4: repo validator rejects empty / whitespace-only") {
        try expect(CursorNewRunFormLogic.isRepoValid("") == false)
        try expect(CursorNewRunFormLogic.isRepoValid("  ") == false)
        try expect(CursorNewRunFormLogic.isRepoValid("/Users/dev/repo") == true)
    }

    await test("F4: wall cap validator bounds 1...240") {
        try expect(CursorNewRunFormLogic.isWallCapValid(0) == false)
        try expect(CursorNewRunFormLogic.isWallCapValid(-5) == false)
        try expect(CursorNewRunFormLogic.isWallCapValid(1) == true)
        try expect(CursorNewRunFormLogic.isWallCapValid(30) == true)
        try expect(CursorNewRunFormLogic.isWallCapValid(240) == true)
        try expect(CursorNewRunFormLogic.isWallCapValid(241) == false)
        try expect(CursorNewRunFormLogic.isWallCapValid(1000) == false)
    }

    await test("F4: canSubmit requires all three predicates true") {
        // Happy path
        try expect(CursorNewRunFormLogic.canSubmit(
            prompt: "do the thing", repoPath: "/r", wallCapMinutes: 30) == true)
        // Empty prompt
        try expect(CursorNewRunFormLogic.canSubmit(
            prompt: "", repoPath: "/r", wallCapMinutes: 30) == false)
        // Empty repo
        try expect(CursorNewRunFormLogic.canSubmit(
            prompt: "x", repoPath: "  ", wallCapMinutes: 30) == false)
        // Out-of-range wall cap
        try expect(CursorNewRunFormLogic.canSubmit(
            prompt: "x", repoPath: "/r", wallCapMinutes: 0) == false)
        try expect(CursorNewRunFormLogic.canSubmit(
            prompt: "x", repoPath: "/r", wallCapMinutes: 999) == false)
    }

    await test("F4: cost estimate — cloud = wallCap * 12 cents, local = 0") {
        // Cloud
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .cloud, wallCapMinutes: 0) == 0)
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .cloud, wallCapMinutes: 1) == 12)
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .cloud, wallCapMinutes: 30) == 360)
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .cloud, wallCapMinutes: 240) == 2880)
        // Local: always 0
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .local, wallCapMinutes: 0) == 0)
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .local, wallCapMinutes: 60) == 0)
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .local, wallCapMinutes: 240) == 0)
        // Negative wall cap clamps to 0
        try expect(CursorNewRunFormLogic.estimatedCostCents(
            runtime: .cloud, wallCapMinutes: -10) == 0)
    }
}
