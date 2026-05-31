// SystemModuleTests.swift – V1-05 SystemModule Tests
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

// MARK: - SystemModule Tests

func runSystemModuleTests() async {
    print("\n🖥️ SystemModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SystemModule.register(on: router)

    // Registration tests
    await test("SystemModule registers 3 tools") {
        let tools = await router.registrations(forModule: "system")
        try expect(tools.count == 3, "Expected 3 system tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("system_info"), "Missing system_info")
        try expect(names.contains("process_list"), "Missing process_list")
        try expect(names.contains("notify"), "Missing notify")
    }

    // Tier tests
    await test("system_info tier is green") {
        let tools = await router.registrations(forModule: "system")
        let tool = tools.first(where: { $0.name == "system_info" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("process_list tier is green") {
        let tools = await router.registrations(forModule: "system")
        let tool = tools.first(where: { $0.name == "process_list" })!
        try expect(tool.tier == .open, "Expected green, got \(tool.tier.rawValue)")
    }

    await test("notify tier is open") {
        let tools = await router.registrations(forModule: "system")
        let tool = tools.first(where: { $0.name == "notify" })!
        try expect(tool.tier == .open, "Expected open, got \(tool.tier.rawValue)")
    }

    // Functional tests — system_info
    await test("system_info returns OS and hardware info") {
        let result = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            try expect(dict["osName"] != nil, "Expected osName")
            try expect(dict["osVersion"] != nil, "Expected osVersion")
            try expect(dict["hostname"] != nil, "Expected hostname")
            try expect(dict["cpu"] != nil, "Expected cpu")
            try expect(dict["cpuCores"] != nil, "Expected cpuCores")
            try expect(dict["memoryGB"] != nil, "Expected memoryGB")
            try expect(dict["uptime"] != nil, "Expected uptime")

            // Validate types
            if case .string(let os) = dict["osName"] {
                try expect(os.contains("mac") || os.contains("Mac"), "osName should contain 'mac': \(os)")
            }
            if case .int(let cores) = dict["cpuCores"] {
                try expect(cores > 0, "cpuCores should be > 0, got \(cores)")
            }
            if case .double(let mem) = dict["memoryGB"] {
                try expect(mem > 0, "memoryGB should be > 0, got \(mem)")
            }
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // FB-2: system_info exposes home/user/cwd so agents stop guessing /Users paths.
    await test("system_info returns homeDirectory, userName, currentDirectory") {
        let result = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        guard case .object(let dict) = result else {
            throw TestError.assertion("Expected object result")
        }
        try expect(dict["homeDirectory"] != nil, "Expected homeDirectory field")
        try expect(dict["userName"] != nil, "Expected userName field")
        try expect(dict["currentDirectory"] != nil, "Expected currentDirectory field")

        guard case .string(let home)? = dict["homeDirectory"] else {
            throw TestError.assertion("homeDirectory should be a string")
        }
        try expect(!home.isEmpty, "homeDirectory must be non-empty")
        try expect(home.hasPrefix("/Users/"), "homeDirectory should begin with /Users/, got \(home)")

        guard case .string(let user)? = dict["userName"] else {
            throw TestError.assertion("userName should be a string")
        }
        try expect(!user.isEmpty, "userName must be non-empty")

        guard case .string(let cwd)? = dict["currentDirectory"] else {
            throw TestError.assertion("currentDirectory should be a string")
        }
        try expect(cwd.hasPrefix("/"), "currentDirectory should be an absolute path, got \(cwd)")
    }

    // Functional tests — process_list
    await test("process_list returns processes") {
        let result = try await router.dispatch(
            toolName: "process_list",
            arguments: .object(["limit": .int(10)])
        )
        if case .object(let dict) = result {
            try expect(dict["processes"] != nil, "Expected processes key")
            if case .array(let procs) = dict["processes"] {
                try expect(procs.count > 0, "Expected at least 1 process")
                // Check first process has expected fields
                if case .object(let proc) = procs[0] {
                    try expect(proc["pid"] != nil, "Expected pid")
                    try expect(proc["command"] != nil, "Expected command")
                    try expect(proc["cpu"] != nil, "Expected cpu")
                    try expect(proc["mem"] != nil, "Expected mem")
                }
            }
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // process_list with filter
    await test("process_list filter returns matching processes") {
        let result = try await router.dispatch(
            toolName: "process_list",
            arguments: .object(["filter": .string("kernel"), "limit": .int(5)])
        )
        if case .object(let dict) = result {
            if case .array(let procs) = dict["processes"] {
                // All returned processes should match the filter
                for proc in procs {
                    if case .object(let p) = proc,
                       case .string(let cmd) = p["command"] {
                        // kernel_task or similar should match
                        try expect(
                            cmd.lowercased().contains("kernel") ||
                            (p["user"].flatMap { if case .string(let u) = $0 { return u } else { return nil } })?.lowercased().contains("kernel") == true,
                            "Process '\(cmd)' should match filter 'kernel'"
                        )
                    }
                }
            }
        } else {
            throw TestError.assertion("Expected object result")
        }
    }

    // notify — test with a real notification
    await test("notify sends macOS notification") {
        let result = try await router.dispatch(
            toolName: "notify",
            arguments: .object([
                "title": .string("NotionBridgeTests"),
                "body": .string("V1-05 SystemModule test notification")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let sent) = dict["sent"] {
            try expect(sent == true, "Expected notification sent=true")
        } else {
            throw TestError.assertion("Expected object with sent=true")
        }
    }

    // notify rejects missing title
    await test("notify rejects missing title") {
        do {
            _ = try await router.dispatch(
                toolName: "notify",
                arguments: .object(["body": .string("test")])
            )
            throw TestError.assertion("Expected error for missing title")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // notify rejects missing body
    await test("notify rejects missing body") {
        do {
            _ = try await router.dispatch(
                toolName: "notify",
                arguments: .object(["title": .string("test")])
            )
            throw TestError.assertion("Expected error for missing body")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("process_list respects filter param") {
        let result = try await router.dispatch(
            toolName: "process_list",
            arguments: .object(["filter": .string("NotionBridge")])
        )
        if case .object(let dict) = result,
           case .array(let procs) = dict["processes"] {
            for proc in procs {
                if case .object(let p) = proc, case .string(let name) = p["name"] {
                    try expect(name.lowercased().contains("notionbridge"), "Filter should match: \(name)")
                }
            }
        }
    }

    await test("process_list respects limit param") {
        let result = try await router.dispatch(
            toolName: "process_list",
            arguments: .object(["limit": .int(3)])
        )
        if case .object(let dict) = result,
           case .array(let procs) = dict["processes"] {
            try expect(procs.count <= 3, "Expected at most 3 processes, got \(procs.count)")
        }
    }
}
