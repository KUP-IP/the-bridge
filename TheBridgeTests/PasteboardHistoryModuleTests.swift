// PasteboardHistoryModuleTests.swift — PKT-765 (v2.2 · 3.3.1)
// TheBridge · Tests
//
// NSPasteboard read requires no TCC grant. We can manipulate the pasteboard
// in-process, manually poll once, and assert the new entry surfaces.

import Foundation
import AppKit
import MCP
import TheBridgeLib

func runPasteboardHistoryModuleTests() async {
    print("\n\u{1F4CB} PasteboardHistoryModule Tests")

    let gate = SecurityGate()
    let log  = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)

    // Reset before registering so test runs are deterministic.
    PasteboardHistoryStore.shared.reset()
    await PasteboardHistoryModule.register(on: router)

    await test("PasteboardHistoryModule registers pasteboard_history") {
        let tools = await router.registrations(forModule: "computer")
        try expect(tools.contains(where: { $0.name == "pasteboard_history" }),
                   "Missing pasteboard_history")
    }

    await test("PasteboardHistoryModule.moduleName is 'computer'") {
        try expect(PasteboardHistoryModule.moduleName == "computer",
                   "Expected 'computer', got '\(PasteboardHistoryModule.moduleName)'")
    }

    await test("pasteboard_history is open tier (no TCC gate)") {
        let tools = await router.registrations(forModule: "computer")
        let tool = tools.first(where: { $0.name == "pasteboard_history" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    await test("pasteboard_history responds with structured fields") {
        let result = try await router.dispatch(
            toolName: "pasteboard_history",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .array(_) = dict["entries"] else {
            throw TestError.assertion("Expected entries array")
        }
        try expect(dict["count"] != nil,          "count missing")
        try expect(dict["maxEntries"] != nil,     "maxEntries missing")
        try expect(dict["pollIntervalMs"] != nil, "pollIntervalMs missing")
    }

    await test("pasteboard_history reports maxEntries = 50") {
        let result = try await router.dispatch(
            toolName: "pasteboard_history",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .int(let m) = dict["maxEntries"] else {
            throw TestError.assertion("Expected maxEntries int")
        }
        try expect(m == 50, "Expected 50, got \(m)")
    }

    await test("pasteboard_history captures a fresh clip via in-process polling") {
        // Stamp the pasteboard with a unique token, then dispatch the tool
        // (which triggers a manual pollOnce) and assert the token appears.
        let token = "nb-pkt-765-test-\(UUID().uuidString)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)

        let result = try await router.dispatch(
            toolName: "pasteboard_history",
            arguments: .object(["limit": .int(5)])
        )
        guard case .object(let dict) = result,
              case .array(let rows) = dict["entries"] else {
            throw TestError.assertion("Expected entries array")
        }
        let found = rows.contains { row in
            if case .object(let r) = row, case .string(let t) = r["text"] { return t == token }
            return false
        }
        try expect(found, "Expected token '\(token)' to appear in pasteboard_history entries")
    }

    await test("pasteboard_history limit clamps to 1..50") {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString("nb-pkt-765-A-\(UUID().uuidString)", forType: .string)
        PasteboardHistoryStore.shared.pollOnce()
        pb.clearContents(); pb.setString("nb-pkt-765-B-\(UUID().uuidString)", forType: .string)
        PasteboardHistoryStore.shared.pollOnce()

        let resultSmall = try await router.dispatch(
            toolName: "pasteboard_history",
            arguments: .object(["limit": .int(1)])
        )
        guard case .object(let d1) = resultSmall, case .int(let n1) = d1["count"] else {
            throw TestError.assertion("Expected count int on limit=1")
        }
        try expect(n1 == 1, "limit=1 should yield 1 row, got \(n1)")

        let resultBig = try await router.dispatch(
            toolName: "pasteboard_history",
            arguments: .object(["limit": .int(9999)])
        )
        guard case .object(let d2) = resultBig, case .int(let n2) = d2["count"] else {
            throw TestError.assertion("Expected count int on limit=9999")
        }
        try expect(n2 <= 50, "limit=9999 should clamp to ≤50, got \(n2)")
    }

    await test("pasteboard_history persists to ~/Library/Application Support/TheBridge/") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("nb-pkt-765-persist-\(UUID().uuidString)", forType: .string)
        PasteboardHistoryStore.shared.pollOnce()

        // Allow the async write to drain.
        try await Task.sleep(nanoseconds: 250_000_000)

        let url = PasteboardHistoryStore.shared.storeFileURL
        try expect(FileManager.default.fileExists(atPath: url.path),
                   "Expected pasteboard-history.json at \(url.path)")
    }
}
