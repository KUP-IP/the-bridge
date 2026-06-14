// ArtifactModule.swift — PKT-743 (Bridge v2.2 · 3.1)
// NotionBridge · Modules · dev/

import CryptoKit
import Foundation
import MCP

public enum ArtifactModule {
    public static let moduleName = "dev"

    public static func register(on router: ToolRouter) async {
        await registerHTTPFetch(on: router)
        await registerDiffRender(on: router)
        await registerFileZip(on: router)
        await registerFileUnzip(on: router)
        await registerFileHash(on: router)
    }

    private static func string(_ args: [String: Value], _ key: String, default fallback: String? = nil) -> String? {
        if case .string(let s) = args[key] { return s }
        return fallback
    }

    private static func bool(_ args: [String: Value], _ key: String, default fallback: Bool = false) -> Bool {
        if case .bool(let b) = args[key] { return b }
        return fallback
    }

    private static func int(_ args: [String: Value], _ key: String, default fallback: Int) -> Int {
        if case .int(let i) = args[key] { return i }
        if case .double(let d) = args[key] { return Int(d) }
        return fallback
    }

    private static func stringArray(_ value: Value?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { if case .string(let s) = $0 { return s }; return nil }
    }

    private static func stringMap(_ value: Value?) -> [String: String] {
        guard case .object(let obj) = value else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if case .string(let s) = v { out[k] = s }
        }
        return out
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> (exit: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private static func error(_ tool: String, _ status: String, _ message: String) -> Value {
        .object([
            "ok": .bool(false),
            "status": .string(status),
            "tool": .string(tool),
            "error": .string(message)
        ])
    }

    private static func registerHTTPFetch(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "http_fetch",
            module: moduleName,
            tier: .request,
            description: "Fetch an HTTP(S) URL with URLSession and return status, headers, and a bounded UTF-8 body preview. Supports method, headers, body, timeoutSeconds, and maxBytes. Use for dev smoke probes without shelling out to curl.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string")]),
                    "method": .object(["type": .string("string"), "description": .string("HTTP method, default GET")]),
                    "headers": .object(["type": .string("object"), "description": .string("String header map")]),
                    "body": .object(["type": .string("string")]),
                    "timeoutSeconds": .object(["type": .string("integer"), "description": .string("Default 30")]),
                    "maxBytes": .object(["type": .string("integer"), "description": .string("Default 65536")])
                ]),
                "required": .array([.string("url")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let rawURL = string(args, "url"), let url = URL(string: rawURL) else {
                    throw ToolRouterError.invalidArguments(toolName: "http_fetch", reason: "missing valid 'url'")
                }
                guard ["http", "https"].contains((url.scheme ?? "").lowercased()) else {
                    return error("http_fetch", "invalid_argument", "url scheme must be http or https")
                }
                var req = URLRequest(url: url)
                req.httpMethod = string(args, "method", default: "GET")?.uppercased()
                req.timeoutInterval = TimeInterval(max(1, int(args, "timeoutSeconds", default: 30)))
                for (k, v) in stringMap(args["headers"]) { req.setValue(v, forHTTPHeaderField: k) }
                if let body = string(args, "body") { req.httpBody = Data(body.utf8) }
                let maxBytes = max(1, int(args, "maxBytes", default: 65_536))
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    let http = response as? HTTPURLResponse
                    let clipped = data.prefix(maxBytes)
                    let body = String(decoding: clipped, as: UTF8.self)
                    var headers: [String: Value] = [:]
                    http?.allHeaderFields.forEach { key, value in headers[String(describing: key)] = .string(String(describing: value)) }
                    return .object([
                        "ok": .bool(true),
                        "url": .string(rawURL),
                        "statusCode": .int(http?.statusCode ?? 0),
                        "headers": .object(headers),
                        "body": .string(body),
                        "bytes": .int(data.count),
                        "truncated": .bool(data.count > maxBytes)
                    ])
                } catch {
                    return ArtifactModule.error("http_fetch", "failed", error.localizedDescription)
                }
            }
        ))
    }

    private static func registerDiffRender(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "diff_render",
            module: moduleName,
            tier: .open,
            description: "Render a unified diff as markdown, HTML, or ANSI text with escaped content. Useful after git_diff or file_apply_patch preview. Returns hunk/add/delete counts and never executes diff content.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "diff": .object(["type": .string("string")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("markdown"), .string("html"), .string("ansi")])])
                ]),
                "required": .array([.string("diff")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let diff = string(args, "diff") else {
                    throw ToolRouterError.invalidArguments(toolName: "diff_render", reason: "missing 'diff'")
                }
                let format = string(args, "format", default: "markdown") ?? "markdown"
                let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let adds = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let dels = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                let hunks = lines.filter { $0.hasPrefix("@@") }.count
                let rendered: String
                switch format {
                case "html":
                    rendered = "<pre class=\"notionbridge-diff\">\n" + lines.map(htmlLine).joined(separator: "\n") + "\n</pre>"
                case "ansi":
                    rendered = lines.map(ansiLine).joined(separator: "\n")
                default:
                    rendered = "```diff\n" + diff + (diff.hasSuffix("\n") ? "" : "\n") + "```"
                }
                return .object([
                    "ok": .bool(true),
                    "format": .string(format),
                    "rendered": .string(rendered),
                    "hunks": .int(hunks),
                    "additions": .int(adds),
                    "deletions": .int(dels)
                ])
            }
        ))
    }

    private static func htmlLine(_ line: String) -> String {
        let escaped = line
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return "<span class=\"add\">\(escaped)</span>" }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return "<span class=\"del\">\(escaped)</span>" }
        if line.hasPrefix("@@") { return "<span class=\"hunk\">\(escaped)</span>" }
        return escaped
    }

    private static func ansiLine(_ line: String) -> String {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return "\u{001B}[32m\(line)\u{001B}[0m" }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return "\u{001B}[31m\(line)\u{001B}[0m" }
        if line.hasPrefix("@@") { return "\u{001B}[36m\(line)\u{001B}[0m" }
        return line
    }

    private static func snapshot(path: String, recursive: Bool) -> [String: String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [:] }
        let urls: [URL]
        if isDir.boolValue {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            if recursive, let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
                urls = e.compactMap { $0 as? URL }
            } else {
                urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            }
        } else {
            urls = [URL(fileURLWithPath: path)]
        }
        var out: [String: String] = [:]
        for url in urls {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            out[url.path] = "\(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(vals?.fileSize ?? -1)"
        }
        return out
    }

    private static func registerFileZip(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "file_zip",
            module: moduleName,
            tier: .notify,
            description: "Create a zip archive with macOS ditto. Returns archive path and byte size. includeRoot defaults true for deterministic round-trips.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourcePath": .object(["type": .string("string")]),
                    "archivePath": .object(["type": .string("string")]),
                    "includeRoot": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("sourcePath"), .string("archivePath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let source = string(args, "sourcePath"), let archive = string(args, "archivePath") else {
                    throw ToolRouterError.invalidArguments(toolName: "file_zip", reason: "missing sourcePath or archivePath")
                }
                let src = expand(source)
                let dst = expand(archive)
                let includeRoot = bool(args, "includeRoot", default: true)
                let fm = FileManager.default
                try? fm.createDirectory(at: URL(fileURLWithPath: dst).deletingLastPathComponent(), withIntermediateDirectories: true)
                let dittoArgs = includeRoot ? ["-c", "-k", "--keepParent", src, dst] : ["-c", "-k", src, dst]
                let res = try runProcess("/usr/bin/ditto", dittoArgs)
                if res.exit != 0 { return error("file_zip", "failed", res.stderr) }
                let bytes = (try? fm.attributesOfItem(atPath: dst)[.size] as? NSNumber)?.intValue ?? 0
                return .object(["ok": .bool(true), "archivePath": .string(dst), "bytes": .int(bytes)])
            }
        ))
    }

    private static func registerFileUnzip(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "file_unzip",
            module: moduleName,
            tier: .notify,
            description: "Extract a zip archive with macOS ditto into destinationPath. Returns extracted file list.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "archivePath": .object(["type": .string("string")]),
                    "destinationPath": .object(["type": .string("string")])
                ]),
                "required": .array([.string("archivePath"), .string("destinationPath")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let archive = string(args, "archivePath"), let dest = string(args, "destinationPath") else {
                    throw ToolRouterError.invalidArguments(toolName: "file_unzip", reason: "missing archivePath or destinationPath")
                }
                let src = expand(archive)
                let dst = expand(dest)
                try? FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
                let res = try runProcess("/usr/bin/ditto", ["-x", "-k", src, dst])
                if res.exit != 0 { return error("file_unzip", "failed", res.stderr) }
                let files = snapshot(path: dst, recursive: true).keys.sorted().map { Value.string($0) }
                return .object(["ok": .bool(true), "destinationPath": .string(dst), "files": .array(files)])
            }
        ))
    }

    private static func registerFileHash(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "file_hash",
            module: moduleName,
            tier: .open,
            description: "Compute SHA-256 for a file and return hex digest plus byte count.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments, let rawPath = string(args, "path") else {
                    throw ToolRouterError.invalidArguments(toolName: "file_hash", reason: "missing 'path'")
                }
                let path = expand(rawPath)
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return .object(["ok": .bool(true), "path": .string(path), "algorithm": .string("sha256"), "hash": .string(digest), "bytes": .int(data.count)])
                } catch {
                    return ArtifactModule.error("file_hash", "not_found", error.localizedDescription)
                }
            }
        ))
    }

}
