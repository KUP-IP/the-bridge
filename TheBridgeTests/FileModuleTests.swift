// FileModuleTests.swift – V1-04 FileModule Tests
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

// MARK: - FileModule Tests

func runFileModuleTests() async {
    print("\n📁 FileModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await FileModule.register(on: router)

    // Registration
    await test("FileModule registers 12 tools") {
        let tools = await router.registrations(forModule: "file")
        try expect(tools.count == 12, "Expected 12 file tools, got \(tools.count)")
    }

    await test("FileModule tool names match spec") {
        let tools = await router.registrations(forModule: "file")
        let names = Set(tools.map(\.name))
        let expected: Set<String> = [
            "file_list", "file_search", "file_metadata", "file_read",
            "file_write", "file_append", "file_move", "file_rename",
            "file_copy", "dir_create", "clipboard_read", "clipboard_write"
        ]
        for name in expected {
            try expect(names.contains(name), "Missing tool: \(name)")
        }
    }

    // Tier verification
    await test("FileModule tiers match spec") {
        let tools = await router.registrations(forModule: "file")
        let tierMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.tier) })
        // Green: file_list, file_search, file_metadata, file_read, clipboard_read
        try expect(tierMap["file_list"] == .open, "file_list should be green")
        try expect(tierMap["file_search"] == .open, "file_search should be green")
        try expect(tierMap["file_metadata"] == .open, "file_metadata should be green")
        try expect(tierMap["file_read"] == .open, "file_read should be green")
        try expect(tierMap["clipboard_read"] == .open, "clipboard_read should be green")
        // Notify: clipboard_write (SEC-03: upgraded from .open)
        try expect(tierMap["clipboard_write"] == .notify, "clipboard_write should be notify (SEC-03)")
        // Notify: file_copy (elevated PKT-373 P1-1)
        try expect(tierMap["file_copy"] == .notify, "file_copy should be notify (elevated PKT-373 P1-1)")
        // Orange: file_write, file_append, file_move, file_rename, dir_create
        try expect(tierMap["file_write"] == .notify, "file_write should be orange")
        try expect(tierMap["file_append"] == .notify, "file_append should be orange")
        try expect(tierMap["file_move"] == .notify, "file_move should be orange")
        try expect(tierMap["file_rename"] == .notify, "file_rename should be orange")
        try expect(tierMap["dir_create"] == .notify, "dir_create should be orange")
    }

    // Create temp directory for file operation tests
    let testDir = "/tmp/notionbridge_file_tests_\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: testDir) }

    // dir_create
    await test("dir_create creates a new directory") {
        let newDir = "\(testDir)/subdir_a/subdir_b"
        let result = try await router.dispatch(
            toolName: "dir_create",
            arguments: .object(["path": .string(newDir)])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"] {
            try expect(success, "Expected success: true")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
        try expect(FileManager.default.fileExists(atPath: newDir), "Directory should exist on disk")
    }

    // file_write
    await test("file_write creates a file with content") {
        let filePath = "\(testDir)/test_write.txt"
        let result = try await router.dispatch(
            toolName: "file_write",
            arguments: .object([
                "path": .string(filePath),
                "content": .string("Hello from FileModule tests!")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"] {
            try expect(success, "Expected success: true")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
        try expect(FileManager.default.fileExists(atPath: filePath), "File should exist on disk")
    }

    // file_write with createDirs
    await test("file_write with createDirs creates parent directories") {
        let filePath = "\(testDir)/auto_parent/nested/file.txt"
        let result = try await router.dispatch(
            toolName: "file_write",
            arguments: .object([
                "path": .string(filePath),
                "content": .string("nested content"),
                "createDirs": .bool(true)
            ])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"] {
            try expect(success, "Expected success: true")
        }
        try expect(FileManager.default.fileExists(atPath: filePath), "Nested file should exist")
    }

    // file_read
    await test("file_read returns file content") {
        let filePath = "\(testDir)/test_write.txt"
        let result = try await router.dispatch(
            toolName: "file_read",
            arguments: .object(["path": .string(filePath)])
        )
        if case .object(let dict) = result,
           case .string(let content) = dict["content"] {
            try expect(content == "Hello from FileModule tests!", "Content mismatch: \(content)")
        } else {
            throw TestError.assertion("Expected content field in result")
        }
    }

    // file_append
    await test("file_append adds to existing file") {
        let filePath = "\(testDir)/test_write.txt"
        let _ = try await router.dispatch(
            toolName: "file_append",
            arguments: .object([
                "path": .string(filePath),
                "content": .string(" Appended text.")
            ])
        )
        let readResult = try await router.dispatch(
            toolName: "file_read",
            arguments: .object(["path": .string(filePath)])
        )
        if case .object(let dict) = readResult,
           case .string(let content) = dict["content"] {
            try expect(content.contains("Appended text."), "Appended text should be present")
        }
    }

    // file_list
    await test("file_list lists directory contents") {
        let result = try await router.dispatch(
            toolName: "file_list",
            arguments: .object(["path": .string(testDir)])
        )
        if case .object(let dict) = result,
           case .int(let count) = dict["count"] {
            try expect(count > 0, "Directory should not be empty, got \(count)")
        } else {
            throw TestError.assertion("Expected count field")
        }
    }

    // file_list recursive
    await test("file_list recursive finds nested files") {
        let result = try await router.dispatch(
            toolName: "file_list",
            arguments: .object([
                "path": .string(testDir),
                "recursive": .bool(true)
            ])
        )
        if case .object(let dict) = result,
           case .int(let count) = dict["count"] {
            try expect(count > 1, "Recursive listing should find nested items, got \(count)")
        }
    }

    await test("file_list supports maxEntries truncation metadata") {
        let result = try await router.dispatch(
            toolName: "file_list",
            arguments: .object([
                "path": .string(testDir),
                "recursive": .bool(true),
                "maxEntries": .int(1)
            ])
        )
        if case .object(let dict) = result,
           case .int(let count) = dict["count"],
           case .bool(let truncated) = dict["truncated"],
           case .string(let reason) = dict["truncationReason"] {
            try expect(count == 1, "Expected capped count of 1, got \(count)")
            try expect(truncated, "Expected truncated true")
            try expect(reason == "maxEntries", "Expected maxEntries truncation reason")
        } else {
            throw TestError.assertion("Expected truncation metadata")
        }
    }

    // file_search
    await test("file_search finds files by name") {
        let result = try await router.dispatch(
            toolName: "file_search",
            arguments: .object([
                "directory": .string(testDir),
                "query": .string("test_write")
            ])
        )
        if case .object(let dict) = result,
           case .int(let count) = dict["count"] {
            try expect(count >= 1, "Should find test_write.txt, got \(count) matches")
        }
    }

    await test("file_search supports maxResults cap and hint") {
        FileManager.default.createFile(atPath: "\(testDir)/test_cap_one.txt", contents: Data("one".utf8))
        FileManager.default.createFile(atPath: "\(testDir)/test_cap_two.txt", contents: Data("two".utf8))
        let result = try await router.dispatch(
            toolName: "file_search",
            arguments: .object([
                "directory": .string(testDir),
                "query": .string("test"),
                "maxResults": .int(1)
            ])
        )
        if case .object(let dict) = result,
           case .int(let count) = dict["count"],
           case .bool(let truncated) = dict["truncated"] {
            try expect(count <= 1, "Expected search cap to limit matches")
            try expect(truncated || count == 0, "Expected truncated when cap is reached")
        } else {
            throw TestError.assertion("Expected search cap metadata")
        }
    }

    // file_metadata
    await test("file_metadata returns size and timestamps") {
        let filePath = "\(testDir)/test_write.txt"
        let result = try await router.dispatch(
            toolName: "file_metadata",
            arguments: .object(["path": .string(filePath)])
        )
        if case .object(let dict) = result {
            try expect(dict["size"] != nil, "Missing size field")
            try expect(dict["created"] != nil, "Missing created field")
            try expect(dict["modified"] != nil, "Missing modified field")
            try expect(dict["type"] != nil, "Missing type field")
            if case .string(let type) = dict["type"] {
                try expect(type == "file", "Expected type 'file', got '\(type)'")
            }
        }
    }

    // file_metadata for directory
    await test("file_metadata identifies directories") {
        let result = try await router.dispatch(
            toolName: "file_metadata",
            arguments: .object(["path": .string(testDir)])
        )
        if case .object(let dict) = result,
           case .string(let type) = dict["type"] {
            try expect(type == "directory", "Expected type 'directory', got '\(type)'")
        }
    }

    // file_copy
    await test("file_copy duplicates a file") {
        let src = "\(testDir)/test_write.txt"
        let dst = "\(testDir)/test_copy.txt"
        let result = try await router.dispatch(
            toolName: "file_copy",
            arguments: .object([
                "sourcePath": .string(src),
                "destinationPath": .string(dst)
            ])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"] {
            try expect(success, "Expected success: true")
        }
        try expect(FileManager.default.fileExists(atPath: dst), "Copy should exist on disk")
        try expect(FileManager.default.fileExists(atPath: src), "Original should still exist")
    }

    // file_rename
    await test("file_rename changes file name") {
        let src = "\(testDir)/test_copy.txt"
        let result = try await router.dispatch(
            toolName: "file_rename",
            arguments: .object([
                "path": .string(src),
                "newName": .string("renamed_copy.txt")
            ])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"] {
            try expect(success, "Expected success: true")
        }
        try expect(FileManager.default.fileExists(atPath: "\(testDir)/renamed_copy.txt"), "Renamed file should exist")
        try expect(!FileManager.default.fileExists(atPath: src), "Original name should not exist")
    }

    // file_move
    await test("file_move relocates a file") {
        let src = "\(testDir)/renamed_copy.txt"
        let dstDir = "\(testDir)/subdir_a"
        let dst = "\(dstDir)/moved_file.txt"
        let result = try await router.dispatch(
            toolName: "file_move",
            arguments: .object([
                "sourcePath": .string(src),
                "destinationPath": .string(dst)
            ])
        )
        if case .object(let dict) = result,
           case .bool(let success) = dict["success"],
           case .bool(let destinationExists) = dict["destinationExistsAfterMove"],
           case .bool(let sourceExists) = dict["sourceExistsAfterMove"],
           case .string(let status) = dict["status"] {
            try expect(success, "Expected success: true")
            try expect(destinationExists, "Expected destinationExistsAfterMove true")
            try expect(!sourceExists, "Expected sourceExistsAfterMove false")
            try expect(status == "verified", "Expected verified move status")
        }
        try expect(FileManager.default.fileExists(atPath: dst), "Moved file should exist at destination")
        try expect(!FileManager.default.fileExists(atPath: src), "Source should no longer exist")
    }

    // clipboard_read (basic invocation — just verify it returns without error)
    await test("clipboard_read returns content and size fields") {
        let result = try await router.dispatch(
            toolName: "clipboard_read",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            try expect(dict["content"] != nil, "Missing content field")
            try expect(dict["size"] != nil, "Missing size field")
        } else {
            throw TestError.assertion("Expected object result from clipboard_read")
        }
    }

    // clipboard_write + read roundtrip
    await test("clipboard_write + clipboard_read roundtrip") {
        let testContent = "notionbridge_clipboard_test_\(Int.random(in: 1000...9999))"
        let writeResult = try await router.dispatch(
            toolName: "clipboard_write",
            arguments: .object(["content": .string(testContent)])
        )
        if case .object(let dict) = writeResult,
           case .bool(let success) = dict["success"] {
            try expect(success, "clipboard_write should succeed")
        }

        let readResult = try await router.dispatch(
            toolName: "clipboard_read",
            arguments: .object([:])
        )
        if case .object(let dict) = readResult,
           case .string(let content) = dict["content"] {
            try expect(content == testContent, "Clipboard roundtrip failed: expected '\(testContent)', got '\(content)'")
        }
    }

    // file_read: missing path param
    await test("file_read rejects missing path") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing path")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // file_write: missing params
    await test("file_write rejects missing content") {
        do {
            _ = try await router.dispatch(
                toolName: "file_write",
                arguments: .object(["path": .string("/tmp/test.txt")])
            )
            throw TestError.assertion("Expected error for missing content")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // P2-3: file_copy security tier verification (PKT-373)
    await test("file_copy is registered at notify tier") {
        let tools = await router.allRegistrations()
        let fileCopy = tools.first(where: { $0.name == "file_copy" })!
        try expect(fileCopy.tier == .notify, "file_copy must be notify tier (was .open before PKT-373)")
    }

}
