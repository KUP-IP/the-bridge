// FileModule.swift – V1-04 File & Clipboard Tools
// NotionBridge · Modules

import Foundation
import MCP

// MARK: - FileModule

/// Provides 12 file and clipboard tools.
/// Migrated from sk mac files R2.
/// Forbidden path enforcement handled by SecurityGate at ToolRouter dispatch level.
public enum FileModule {

    private static func valueToInt(_ value: Value?) -> Int? {
        if case .int(let i) = value { return i }
        if case .double(let d) = value { return Int(d) }
        return nil
    }

    private static func shouldSkipHidden(_ url: URL, root: URL) -> Bool {
        let rel = url.path.replacingOccurrences(of: root.path, with: "")
        return rel.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    // MARK: - HTML Entity Decoding (A1 fix)
    private static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&#x2F;", "/"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }



    public static let moduleName = "file"

    /// Register all file module tools on the given router.
    public static func register(on router: ToolRouter) async {

        // 1. file_list – open
        await router.register(ToolRegistration(
            name: "file_list",
            module: moduleName,
            tier: .open,
            description: "List a directory's contents. recursive and showHidden supported. Preferred over shell_exec ls.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to directory")]),
                    "recursive": .object(["type": .string("boolean"), "description": .string("List recursively (default: false)")]),
                    "showHidden": .object(["type": .string("boolean"), "description": .string("Show hidden files (default: false)")]),
                    "maxEntries": .object(["type": .string("integer"), "description": .string("Maximum entries to return (default: 5000 for recursive listings, unlimited otherwise)")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Maximum recursive depth below the root (default: unlimited)")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_list", reason: "missing 'path'")
                }
                let recursive: Bool = { if case .bool(let b) = args["recursive"] { return b }; return false }()
                let showHidden: Bool = { if case .bool(let b) = args["showHidden"] { return b }; return false }()
                let maxEntries = Self.valueToInt(args["maxEntries"]) ?? (recursive ? 5000 : Int.max)
                let maxDepth = Self.valueToInt(args["maxDepth"])

                let fm = FileManager.default
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var entries: [Value] = []
                var scanned = 0
                var truncated = false
                var truncationReason: String? = nil

                func appendEntry(_ item: URL) throws {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    entries.append(.object([
                        "name": .string(item.lastPathComponent),
                        "path": .string(item.path),
                        "type": .string(isDir ? "directory" : "file")
                    ]))
                }

                if recursive {
                    let rootDepth = url.pathComponents.count
                    if let enumerator = fm.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: showHidden ? [] : [.skipsHiddenFiles]
                    ) {
                        while let itemURL = enumerator.nextObject() as? URL {
                            scanned += 1
                            let depth = max(0, itemURL.pathComponents.count - rootDepth)
                            if let maxDepth, depth > maxDepth {
                                enumerator.skipDescendants()
                                continue
                            }
                            if entries.count >= maxEntries {
                                truncated = true
                                truncationReason = "maxEntries"
                                enumerator.skipDescendants()
                                break
                            }
                            try appendEntry(itemURL)
                        }
                    }
                } else {
                    let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                    for item in items {
                        scanned += 1
                        if !showHidden && item.lastPathComponent.hasPrefix(".") { continue }
                        if entries.count >= maxEntries {
                            truncated = true
                            truncationReason = "maxEntries"
                            break
                        }
                        try appendEntry(item)
                    }
                }

                var result: [String: Value] = [
                    "path": .string(url.path),
                    "count": .int(entries.count),
                    "scannedCount": .int(scanned),
                    "truncated": .bool(truncated),
                    "entries": .array(entries)
                ]
                if let truncationReason { result["truncationReason"] = .string(truncationReason) }
                if truncated {
                    result["warning"] = .string("Listing truncated before exhausting the directory. Re-run with a narrower path, maxDepth, or larger maxEntries if you need more results.")
                }
                return .object(result)
            }
        ))

        // 2. file_search – open
        await router.register(ToolRegistration(
            name: "file_search",
            module: moduleName,
            tier: .open,
            description: "Find local files by name under a directory. For Spotlight-style system search use shell_exec mdfind. Preferred over shell_exec find.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "directory": .object(["type": .string("string"), "description": .string("Directory to search in")]),
                    "query": .object(["type": .string("string"), "description": .string("Query string to match file names against")]),
                    "maxResults": .object(["type": .string("integer"), "description": .string("Maximum matches to return (default 1000)")]),
                    "timeoutSeconds": .object(["type": .string("integer"), "description": .string("Soft search time limit in seconds (default 10)")])
                ]),
                "required": .array([.string("directory"), .string("query")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let directory) = args["directory"],
                      case .string(let query) = args["query"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_search", reason: "missing 'directory' or 'query'")
                }

                let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                let maxResults = Self.valueToInt(args["maxResults"]) ?? 1000
                let timeoutSeconds = Self.valueToInt(args["timeoutSeconds"]) ?? 10
                let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
                var matches: [Value] = []
                var scanned = 0
                var truncated = false
                var truncationReason: String? = nil

                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    while let itemURL = enumerator.nextObject() as? URL {
                        scanned += 1
                        if Date() >= deadline {
                            truncated = true
                            truncationReason = "timeoutSeconds"
                            break
                        }
                        if itemURL.lastPathComponent.localizedCaseInsensitiveContains(query) {
                            if matches.count >= maxResults {
                                truncated = true
                                truncationReason = "maxResults"
                                break
                            }
                            matches.append(.object([
                                "name": .string(itemURL.lastPathComponent),
                                "path": .string(itemURL.path)
                            ]))
                        }
                    }
                }

                var result: [String: Value] = [
                    "query": .string(query),
                    "directory": .string(url.path),
                    "count": .int(matches.count),
                    "scannedCount": .int(scanned),
                    "truncated": .bool(truncated),
                    "matches": .array(matches)
                ]
                if let truncationReason { result["truncationReason"] = .string(truncationReason) }
                if truncated {
                    result["hint"] = .string("Search was capped before exhaustive traversal. Narrow directory/query, raise maxResults/timeoutSeconds, or use Spotlight via shell_exec mdfind for broad user-home searches.")
                }
                return .object(result)
            }
        ))

        // 3. file_metadata – open
        await router.register(ToolRegistration(
            name: "file_metadata",
            module: moduleName,
            tier: .open,
            description: "Return size, created/modified dates, and type for one local path. Preferred over shell_exec stat.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file or directory")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let rawPath) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_metadata", reason: "missing 'path'")
                }
                // v1.9.0 F3: expand ~ in paths so agents dont hardcode home dirs
                let path = (rawPath as NSString).expandingTildeInPath

                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let size = (attrs[.size] as? Int) ?? 0
                let created = (attrs[.creationDate] as? Date)?.ISO8601Format() ?? "unknown"
                let modified = (attrs[.modificationDate] as? Date)?.ISO8601Format() ?? "unknown"
                let fileType = (attrs[.type] as? FileAttributeType) == .typeDirectory ? "directory" : "file"

                return .object([
                    "path": .string(path),
                    "type": .string(fileType),
                    "size": .int(size),
                    "created": .string(created),
                    "modified": .string(modified)
                ])
            }
        ))

        // 4. file_read – open
        await router.register(ToolRegistration(
            name: "file_read",
            module: moduleName,
            tier: .open,
            description: "Read a local text file (utf8/ascii/latin1). Preferred over shell_exec cat — no approval required.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "encoding": .object(["type": .string("string"), "description": .string("Text encoding: utf8, ascii, latin1 (default: utf8)")]),
                    "maxBytes": .object(["type": .string("integer"), "description": .string("Maximum bytes to read (default: unlimited)")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_read", reason: "missing 'path'")
                }

                let encoding: String.Encoding = {
                    if case .string(let enc) = args["encoding"] {
                        switch enc.lowercased() {
                        case "ascii": return .ascii
                        case "latin1": return .isoLatin1
                        default: return .utf8
                        }
                    }
                    return .utf8
                }()

                var data = try Data(contentsOf: URL(fileURLWithPath: path))
                if case .int(let max) = args["maxBytes"], max > 0, data.count > max {
                    data = data.prefix(max)
                }

                let content: String
                if let decoded = String(data: data, encoding: encoding) {
                    content = decoded
                } else if encoding == .utf8 {
                    // v1.9.0 B5: UTF-8 best-effort fallback replaces invalid bytes with U+FFFD
                    content = String(decoding: data, as: UTF8.self)
                } else {
                    return .object(["error": .string("Failed to decode file with specified encoding")])
                }

                return .object([
                    "path": .string(path),
                    "content": .string(content),
                    "size": .int(data.count)
                ])
            }
        ))

        // 5. file_write – notify
        await router.register(ToolRegistration(
            name: "file_write",
            module: moduleName,
            tier: .notify,
            description: "Create or overwrite a local text file. Destructive to existing content. Preferred over shell_exec echo >.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to write")]),
                    "createDirs": .object(["type": .string("boolean"), "description": .string("Create parent directories if needed (default: false)")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_write", reason: "missing 'path' or 'content'")
                }

                let createDirs: Bool = { if case .bool(let b) = args["createDirs"] { return b }; return false }()

                let url = URL(fileURLWithPath: path)
                if createDirs {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                }

                let decodedContent = Self.decodeHTMLEntities(content)
                try decodedContent.write(to: url, atomically: true, encoding: .utf8)

                return .object([
                    "path": .string(path),
                    "bytesWritten": .int(decodedContent.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))

        // 6. file_append – notify
        await router.register(ToolRegistration(
            name: "file_append",
            module: moduleName,
            tier: .notify,
            description: "Append text to an existing local file. Non-destructive. Preferred over shell_exec echo >>.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to append")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_append", reason: "missing 'path' or 'content'")
                }

                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                handle.seekToEndOfFile()
                handle.write(content.data(using: .utf8) ?? Data())
                handle.closeFile()

                return .object([
                    "path": .string(path),
                    "bytesAppended": .int(content.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))

        // 7. file_move – notify
        await router.register(ToolRegistration(
            name: "file_move",
            module: moduleName,
            tier: .notify,
            description: "Move a local file or directory to a new path. Preferred over shell_exec mv. For in-place renames use file_rename.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourcePath": .object(["type": .string("string"), "description": .string("Source file or directory path")]),
                    "destinationPath": .object(["type": .string("string"), "description": .string("Destination path")])
                ]),
                "required": .array([.string("sourcePath"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let src) = args["sourcePath"],
                      case .string(let dst) = args["destinationPath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_move", reason: "missing 'sourcePath' or 'destinationPath'")
                }

                let sourceURL = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
                let destinationURL = URL(fileURLWithPath: (dst as NSString).expandingTildeInPath)
                try FileManager.default.moveItem(
                    at: sourceURL,
                    to: destinationURL
                )

                let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
                let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
                let success = destinationExists && !sourceExists
                return .object([
                    "source": .string(sourceURL.path),
                    "destination": .string(destinationURL.path),
                    "success": .bool(success),
                    "sourceExistsAfterMove": .bool(sourceExists),
                    "destinationExistsAfterMove": .bool(destinationExists),
                    "status": .string(success ? "verified" : "partial_or_unverified")
                ])
            }
        ))

        // 8. file_rename – notify
        await router.register(ToolRegistration(
            name: "file_rename",
            module: moduleName,
            tier: .notify,
            description: "Rename a local file or directory in place (parent unchanged). For relocating use file_move.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path to file or directory")]),
                    "newName": .object(["type": .string("string"), "description": .string("New file or directory name")])
                ]),
                "required": .array([.string("path"), .string("newName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let newName) = args["newName"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_rename", reason: "missing 'path' or 'newName'")
                }

                let url = URL(fileURLWithPath: path)
                let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
                try FileManager.default.moveItem(at: url, to: newURL)

                return .object([
                    "oldPath": .string(path),
                    "newPath": .string(newURL.path),
                    "success": .bool(true)
                ])
            }
        ))

        // 9. file_copy – notify (PKT-373 P1-1: elevated from .open; v1.9.0 F2: overwrite param)
        await router.register(ToolRegistration(
            name: "file_copy",
            module: moduleName,
            tier: .notify,
            description: "Copy a local file or directory. overwrite: true replaces the destination. Preferred over shell_exec cp.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourcePath": .object(["type": .string("string"), "description": .string("Source file or directory path")]),
                    "destinationPath": .object(["type": .string("string"), "description": .string("Destination path")]),
                    "overwrite": .object(["type": .string("boolean"), "description": .string("If true, remove destination before copying (default: false)")])
                ]),
                "required": .array([.string("sourcePath"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let src) = args["sourcePath"],
                      case .string(let dst) = args["destinationPath"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_copy", reason: "missing 'sourcePath' or 'destinationPath'")
                }
                let overwrite: Bool = { if case .bool(let b) = args["overwrite"] { return b }; return false }()

                let dstURL = URL(fileURLWithPath: dst)
                if overwrite && FileManager.default.fileExists(atPath: dst) {
                    try FileManager.default.removeItem(at: dstURL)
                }
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: src),
                    to: dstURL
                )

                return .object([
                    "source": .string(src),
                    "destination": .string(dst),
                    "success": .bool(true)
                ])
            }
        ))

        // 10. dir_create – notify
        await router.register(ToolRegistration(
            name: "dir_create",
            module: moduleName,
            tier: .notify,
            description: "Create a local directory, including any missing parents. Preferred over shell_exec mkdir -p.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute path for new directory")])
                ]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"] else {
                    throw ToolRouterError.invalidArguments(toolName: "dir_create", reason: "missing 'path'")
                }

                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: path),
                    withIntermediateDirectories: true
                )

                return .object([
                    "path": .string(path),
                    "success": .bool(true)
                ])
            }
        ))

        // 11. clipboard_read – open
        await router.register(ToolRegistration(
            name: "clipboard_read",
            module: moduleName,
            tier: .open,
            description: "Read plain text from the macOS clipboard. Preferred over shell_exec pbpaste.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                // Read pipe data BEFORE waitUntilExit to prevent buffer deadlock
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let content = String(data: data, encoding: .utf8) ?? ""

                return .object([
                    "content": .string(content),
                    "size": .int(content.utf8.count)
                ])
            }
        ))

        // 12. clipboard_write – notify (SEC-03: upgraded from .open)
        await router.register(ToolRegistration(
            name: "clipboard_write",
            module: moduleName,
            tier: .notify,
            description: "Write plain text to the macOS clipboard (replaces prior contents). Preferred over shell_exec pbcopy.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "content": .object(["type": .string("string"), "description": .string("Text content to write to clipboard")])
                ]),
                "required": .array([.string("content")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let content) = args["content"] else {
                    throw ToolRouterError.invalidArguments(toolName: "clipboard_write", reason: "missing 'content'")
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
                let pipe = Pipe()
                process.standardInput = pipe
                try process.run()
                pipe.fileHandleForWriting.write(content.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                process.waitUntilExit()

                return .object([
                    "bytesWritten": .int(content.utf8.count),
                    "success": .bool(true)
                ])
            }
        ))
    }
}
