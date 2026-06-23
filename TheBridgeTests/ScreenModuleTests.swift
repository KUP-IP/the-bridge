// ScreenModuleTests.swift – V1-TESTCOVERAGE
// TheBridge · Tests
//
// Tests for ScreenModule (4 tools: screen_capture, screen_ocr,
// screen_record_start, screen_record_stop).
// Note: Screen tools require Screen Recording TCC grant. Tests focus on
// registration, tier classification, and graceful error handling.

import Foundation
import MCP
import TheBridgeLib

// MARK: - ScreenModule Tests

func runScreenModuleTests() async {
    print("\n📸 ScreenModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ScreenModule.register(on: router)
    await ScreenModule.registerRecording(on: router)

    // --- Registration ---

    await test("ScreenModule registers 4 tools") {
        let tools = await router.registrations(forModule: "screen")
        try expect(tools.count == 4, "Expected 4 screen tools, got \(tools.count)")
    }

    await test("ScreenModule tool names are correct") {
        let tools = await router.registrations(forModule: "screen")
        let names = Set(tools.map(\.name))
        try expect(names.contains("screen_capture"), "Missing screen_capture")
        try expect(names.contains("screen_ocr"), "Missing screen_ocr")
        try expect(names.contains("screen_record_start"), "Missing screen_record_start")
        try expect(names.contains("screen_record_stop"), "Missing screen_record_stop")
    }

    // --- Tier classification ---

    await test("screen_capture is open tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_capture" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("screen_ocr is open tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_ocr" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }
    await test("screen_record_start is notify tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_record_start" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    await test("screen_record_stop is notify tier") {
        let tools = await router.registrations(forModule: "screen")
        let tool = tools.first(where: { $0.name == "screen_record_stop" })!
        try expect(tool.tier == .notify, "Expected notify, got \(tool.tier.rawValue)")
    }

    // --- Graceful error handling ---

    await test("screen_capture returns error when Screen Recording denied") {
        let result = try await router.dispatch(
            toolName: "screen_capture",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    await test("screen_ocr returns error when Screen Recording denied") {
        let result = try await router.dispatch(
            toolName: "screen_ocr",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }
    await test("screen_record_stop handles no active recording") {
        let result = try await router.dispatch(
            toolName: "screen_record_stop",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .string(let err) = dict["error"] {
                try expect(!err.isEmpty, "Error message should not be empty")
            }
        }
    }

    // --- Module name ---

    await test("ScreenModule.moduleName is 'screen'") {
        try expect(ScreenModule.moduleName == "screen",
                   "Expected 'screen', got '\(ScreenModule.moduleName)'")
    }

    // --- SCK off-main-actor continuation-leak regression guard ---
    // Before the SCKBoundary fix, dispatching an SCK-backed tool from a
    // nonisolated / off-main-actor context (`Task.detached`) leaked the
    // ScreenCaptureKit checked continuation and HUNG FOREVER ("SWIFT TASK
    // CONTINUATION MISUSE"). The fix routes the SCK call onto the main actor
    // and guards it with a libdispatch watchdog, so the call must now RETURN
    // or THROW promptly. We only assert "did not hang" — content depends on
    // live TCC/display/Chrome state, which we do not gate on here.
    await test("screen_capture from a detached (off-main) task returns promptly, never hangs") {
        let result = await Task.detached {
            try? await router.dispatch(toolName: "screen_capture", arguments: .object([:]))
        }.value
        try expect(result != nil, "screen_capture dispatch should produce a value off-main, not hang")
    }

    // --- FB-AUTOMATION: requireFrontmostBundleId guard ---
    // An impossible bundle id can never be frontmost, so the guard MUST short-
    // circuit with error='frontmost_mismatch' and perform NO capture (no
    // filePath in the response). This holds regardless of TCC/display state.
    await test("screen_capture aborts with frontmost_mismatch when required app is not frontmost") {
        let result = try await router.dispatch(
            toolName: "screen_capture",
            arguments: .object(["requireFrontmostBundleId": .string("com.example.never.frontmost.\(UUID().uuidString)")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        guard case .string(let err) = dict["error"] else {
            throw TestError.assertion("expected error key on mismatch, got keys: \(dict.keys)")
        }
        try expect(err == "frontmost_mismatch", "expected frontmost_mismatch, got \(err)")
        try expect(dict["filePath"] == nil, "guard must abort BEFORE capture — no filePath expected")
        try expect(dict["requiredBundleId"] != nil, "mismatch response should echo requiredBundleId")
    }

    // Empty / absent requireFrontmostBundleId must NOT engage the guard — the
    // call proceeds exactly as before (returns promptly, content state-dependent).
    await test("screen_capture with empty requireFrontmostBundleId does not engage the guard") {
        let result = try await router.dispatch(
            toolName: "screen_capture",
            arguments: .object(["requireFrontmostBundleId": .string("")])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("expected object response")
        }
        // Must not be a frontmost_mismatch (guard skipped on empty string).
        if case .string(let err) = dict["error"] {
            try expect(err != "frontmost_mismatch", "empty guard string must not trigger frontmost_mismatch")
        }
    }
}
