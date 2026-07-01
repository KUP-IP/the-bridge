// CommandsModuleTests.swift — PKT-1061
// CommandStore-backed commands_* MCP tools: registration/tier, list/get/search, CRUD.

import Foundation
import MCP
import TheBridgeLib

func runCommandsModuleTests() async {
    print("\n📋 CommandsModule Tests (PKT-1061)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CommandsModule.register(on: router)

    await test("CommandsModule registers 6 tools under module=\"commands\"") {
        let regs = await router.registrations(forModule: "commands")
        let names = Set(regs.map(\.name))
        let expected: Set<String> = [
            "commands_list", "commands_get", "commands_search",
            "commands_create", "commands_update", "commands_delete"
        ]
        try expect(expected.isSubset(of: names), "missing — got \(names.sorted())")
        try expect(regs.count == 6, "expected 6, got \(regs.count)")
    }

    await test("commands tier split: read-only .open, mutating .request") {
        let regs = await router.registrations(forModule: "commands")
        let readOnly: Set<String> = ["commands_list", "commands_get", "commands_search"]
        for r in regs {
            if readOnly.contains(r.name) {
                try expect(r.tier == .open, "\(r.name) must be .open")
            } else {
                try expect(r.tier == .request, "\(r.name) must be .request")
            }
        }
    }

    await test("commands_delete carries neverAutoApprove") {
        let regs = await router.registrations(forModule: "commands")
        let del = regs.first { $0.name == "commands_delete" }
        try expect(del?.neverAutoApprove == true)
    }

    await test("commands_list + get round-trip via dispatch") {
        try await withCommandsTestHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Smoke", icon: .emoji("🔥"), body: "## Smoke\n\nBody text")
            let (listText, _) = try await router.dispatchFormatted(toolName: "commands_list", arguments: .object([:]))
            try expect(listText.contains("\"ok\":true") || listText.contains("\"ok\" : true"))
            try expect(listText.contains("smoke"))
            let (getText, _) = try await router.dispatchFormatted(
                toolName: "commands_get",
                arguments: .object(["slugOrName": .string("Smoke")])
            )
            try expect(getText.contains("Body text"))
        }
    }

    await test("commands_get resolves slug by display name") {
        try await withCommandsTestHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Close-loop", icon: .emoji("✅"), body: "loop body")
            let (text, _) = try await router.dispatchFormatted(
                toolName: "commands_get",
                arguments: .object(["slugOrName": .string("Close-loop")])
            )
            try expect(text.contains("loop body"))
        }
    }

    await test("commands_search finds substring") {
        try await withCommandsTestHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Execute", icon: .emoji("⚡"), body: "x")
            _ = try CommandStore.shared.create(name: "Reflow", icon: .emoji("🔁"), body: "y")
            let (text, _) = try await router.dispatchFormatted(
                toolName: "commands_search",
                arguments: .object(["query": .string("exec")])
            )
            try expect(text.contains("execute"))
            try expect(!text.contains("reflow"))
        }
    }

    await test("commands_create rejects duplicate slug") {
        try await withCommandsTestHome { _ in
            try CommandStore.shared.resetForTesting()
            _ = try CommandStore.shared.create(name: "Dup", icon: .emoji("d"), body: "1")
            let (text, _) = try await router.dispatchFormatted(
                toolName: "commands_create",
                arguments: .object(["name": .string("dup"), "body": .string("2")])
            )
            try expect(text.contains("duplicate_slug"))
        }
    }

    await test("commands_delete removes command") {
        try await withCommandsTestHome { _ in
            try CommandStore.shared.resetForTesting()
            let c = try CommandStore.shared.create(name: "Gone", icon: .emoji("x"), body: "z")
            _ = try await router.dispatchFormatted(
                toolName: "commands_delete",
                arguments: .object(["slug": .string(c.slug)])
            )
            try expect(try CommandStore.shared.get(slug: c.slug) == nil)
        }
    }
}

// MARK: - tmp-home helper

private func withCommandsTestHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandsModule-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
