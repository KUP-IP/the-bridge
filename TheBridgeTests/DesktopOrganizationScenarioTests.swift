// DesktopOrganizationScenarioTests.swift — scenario: “organize desktop” using FileModule only (/tmp, not real Desktop)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

/// Exercises the same tool sequence a cloud agent would use: list → dir_create → file_move → verify.
func runDesktopOrganizationScenarioTests() async {
    print("\n🗂️ Desktop organization scenario (sandbox /tmp, not ~/Desktop)")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await FileModule.register(on: router)

    let base = "/tmp/nb_desktop_scenario_\(ProcessInfo.processInfo.processIdentifier)"
    let organized = "\(base)/Organized/inbox-test"
    defer { try? FileManager.default.removeItem(atPath: base) }

    await test("Scenario: dir_create nested Organized/inbox") {
        let result = try await router.dispatch(
            toolName: "dir_create",
            arguments: .object(["path": .string(organized)])
        )
        if case .object(let dict) = result, case .bool(let ok) = dict["success"] {
            try expect(ok)
        } else {
            throw TestError.assertion("dir_create unexpected result")
        }
        try expect(FileManager.default.fileExists(atPath: organized))
    }

    await test("Scenario: seed loose files on synthetic desktop") {
        let looseA = "\(base)/loose_a.txt"
        let looseB = "\(base)/loose_b.txt"
        for p in [looseA, looseB] {
            let r = try await router.dispatch(
                toolName: "file_write",
                arguments: .object([
                    "path": .string(p),
                    "content": .string("scenario seed\n"),
                ])
            )
            if case .object(let d) = r, case .bool(let ok) = d["success"] {
                try expect(ok)
            } else {
                throw TestError.assertion("file_write failed for \(p)")
            }
        }
    }

    await test("Scenario: file_move loose files into Organized") {
        for name in ["loose_a.txt", "loose_b.txt"] {
            let src = "\(base)/\(name)"
            let dst = "\(organized)/\(name)"
            let r = try await router.dispatch(
                toolName: "file_move",
                arguments: .object([
                    "sourcePath": .string(src),
                    "destinationPath": .string(dst),
                ])
            )
            if case .object(let d) = r, case .bool(let ok) = d["success"] {
                try expect(ok)
            } else {
                throw TestError.assertion("file_move failed \(name)")
            }
            try expect(FileManager.default.fileExists(atPath: dst))
            try expect(!FileManager.default.fileExists(atPath: src))
        }
    }

    await test("Scenario: file_list confirms inbox contents") {
        let r = try await router.dispatch(
            toolName: "file_list",
            arguments: .object(["path": .string(organized)])
        )
        guard case .object(let top) = r,
              case .array(let items) = top["entries"] ?? .array([])
        else {
            throw TestError.assertion("file_list shape")
        }
        let names = items.compactMap { item -> String? in
            guard case .object(let o) = item, case .string(let n) = o["name"] else { return nil }
            return n
        }
        try expect(names.contains("loose_a.txt"))
        try expect(names.contains("loose_b.txt"))
    }
}
