// LspModule.swift – PKT-745 W1+W2: lsp_* tools (TypeScript first, Swift second)
// NotionBridge · Modules · dev/
//
// Six LSP tools that act as the stable MCP surface for AST-aware operations:
//   - lsp_diagnostics  : textDocument/publishDiagnostics (errors / warnings / hints)
//   - lsp_hover        : textDocument/hover               (type info + doc strings)
//   - lsp_references   : textDocument/references          (every reference site)
//   - lsp_definition   : textDocument/definition          (defining location(s))
//   - lsp_rename       : textDocument/rename              (atomic workspace patch)
//   - lsp_session_list : every live LspSession            (substitute for bg_process_list,
//                                                          PM Decision Log #29 / Option C)
//
// Tier: .request for all six.
//
// W1 (commit e1ecb8a, 2026-05-10):
//   ✅ Registration scaffold; capability probe; language inference; workspace detection;
//      capability_missing fallback.
//
// W2 (this commit):
//   ✅ JSON-RPC stdio client wired into LspRuntime / LspSession actors.
//   ✅ Lazy per-workspace server spawn + 15-min idle dispose.
//   ✅ textDocument/didOpen lifecycle on first touch per file.
//   ✅ Handlers map MCP args → LSP requests → MCP-shaped Value responses.
//   ✅ lsp_session_list tool exposes live sessions for observability.
//
// W3 (next dispatch): Sourcekit-LSP validation against Bridge core, integration
// tests (TS rename across KEEP·OS web, Swift hover), QA checklist.

import Foundation
import MCP

public enum LspModule {

    public static let moduleName = "dev"

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(makeDiagnostics())
        await router.register(makeHover())
        await router.register(makeReferences())
        await router.register(makeDefinition())
        await router.register(makeRename())
        await router.register(makeSessionList())
    }

    // MARK: - Probe result

    public struct ProbeResult: Sendable {
        public let language: String
        public let available: Bool
        public let path: String?
        public let detail: String?
    }

    public static func probe(language: String) -> ProbeResult {
        switch language {
        case "typescript", "javascript", "ts", "js", "tsx", "jsx":
            let candidates = [
                "/opt/homebrew/bin/typescript-language-server",
                "/usr/local/bin/typescript-language-server",
                "\(NSHomeDirectory())/.npm-global/bin/typescript-language-server",
                "\(NSHomeDirectory())/.local/bin/typescript-language-server"
            ]
            if let path = firstExecutable(in: candidates) {
                return ProbeResult(language: "typescript", available: true, path: path, detail: nil)
            }
            return ProbeResult(
                language: "typescript", available: false, path: nil,
                detail: "typescript-language-server not found at any standard install path"
            )

        case "swift":
            let candidates = [
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
                "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp"
            ]
            if let path = firstExecutable(in: candidates) {
                return ProbeResult(language: "swift", available: true, path: path, detail: nil)
            }
            return ProbeResult(
                language: "swift", available: false, path: nil,
                detail: "sourcekit-lsp not found; install Xcode from the App Store or run `xcode-select --install`"
            )

        default:
            return ProbeResult(
                language: language, available: false, path: nil,
                detail: "unsupported language hint: \(language) (expected 'typescript' or 'swift')"
            )
        }
    }

    private static func firstExecutable(in candidates: [String]) -> String? {
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Language inference

    public static func inferLanguage(fromPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "typescript"
        case "swift":                                  return "swift"
        default:                                       return nil
        }
    }

    // MARK: - Workspace detection

    public static func findWorkspaceRoot(forFile filePath: String, language: String) -> URL? {
        let markers: [String]
        switch language {
        case "typescript": markers = ["tsconfig.json", "jsconfig.json", "package.json"]
        case "swift":      markers = ["Package.swift"]
        default:           return nil
        }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<32 {
            for marker in markers {
                if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                    return dir
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - Schema helpers

    private static let baseProperties: [String: Value] = [
        "filePath": .object([
            "type":        .string("string"),
            "description": .string("Absolute path to the source file the LSP request targets.")
        ]),
        "language": .object([
            "type":        .string("string"),
            "description": .string("Optional language hint ('typescript' | 'swift'). Auto-detected from file extension if omitted.")
        ])
    ]

    private static func schema(extras: [String: Value] = [:]) -> Value {
        var props = baseProperties
        for (k, v) in extras { props[k] = v }
        return .object([
            "type":       .string("object"),
            "properties": .object(props),
            "required":   .array([.string("filePath")])
        ])
    }

    private static let positionLineProp: Value = .object([
        "type":        .string("integer"),
        "description": .string("Zero-indexed line number.")
    ])

    private static let positionCharProp: Value = .object([
        "type":        .string("integer"),
        "description": .string("Zero-indexed UTF-16 character offset within the line.")
    ])

    // MARK: - Argument extraction

    private static func extractFileAndLanguage(_ arguments: Value, tool: String) throws -> (filePath: String, language: String) {
        guard case .object(let args) = arguments,
              case .string(let filePath) = args["filePath"] else {
            throw ToolRouterError.invalidArguments(
                toolName: tool,
                reason: "missing required 'filePath' parameter"
            )
        }
        let language: String
        if case .string(let hint) = args["language"] {
            language = hint
        } else if let inferred = inferLanguage(fromPath: filePath) {
            language = inferred
        } else {
            throw ToolRouterError.invalidArguments(
                toolName: tool,
                reason: "could not infer language from extension of '\(filePath)'; pass 'language' explicitly ('typescript' or 'swift')"
            )
        }
        return (filePath, language)
    }

    private static func extractPosition(_ arguments: Value, tool: String) throws -> (line: Int, character: Int) {
        guard case .object(let args) = arguments else {
            throw ToolRouterError.invalidArguments(toolName: tool, reason: "arguments must be an object")
        }
        let line: Int
        let character: Int
        if case .int(let v) = args["line"] {
            line = v
        } else {
            throw ToolRouterError.invalidArguments(toolName: tool, reason: "missing required integer 'line' parameter")
        }
        if case .int(let v) = args["character"] {
            character = v
        } else {
            throw ToolRouterError.invalidArguments(toolName: tool, reason: "missing required integer 'character' parameter")
        }
        return (line, character)
    }

    private static func extractNewName(_ arguments: Value, tool: String) throws -> String {
        guard case .object(let args) = arguments,
              case .string(let newName) = args["newName"] else {
            throw ToolRouterError.invalidArguments(toolName: tool, reason: "missing required string 'newName' parameter")
        }
        return newName
    }

    private static func includeDeclaration(_ arguments: Value) -> Bool {
        if case .object(let args) = arguments, case .bool(let b) = args["includeDeclaration"] { return b }
        return true
    }

    // MARK: - Response shapes

    private static func capabilityMissingValue(tool: String, probe: ProbeResult) -> Value {
        let remediation: String
        switch probe.language {
        case "typescript": remediation = "npm install -g typescript-language-server typescript"
        case "swift":      remediation = "Install Xcode from the App Store (Sourcekit-LSP ships with the Xcode toolchain), or run `xcode-select --install`."
        default:           remediation = "(no remediation — unsupported language)"
        }
        return .object([
            "ok":          .bool(false),
            "status":      .string("capability_missing"),
            "tool":        .string(tool),
            "language":    .string(probe.language),
            "error":       .string(probe.detail ?? "LSP server binary not found"),
            "remediation": .string(remediation)
        ])
    }

    private static func errorValue(tool: String, language: String, filePath: String?, error: Error) -> Value {
        var fields: [String: Value] = [
            "ok":       .bool(false),
            "status":   .string("error"),
            "tool":     .string(tool),
            "language": .string(language),
            "error":    .string("\(error)")
        ]
        if let fp = filePath { fields["filePath"] = .string(fp) }
        return .object(fields)
    }

    private static func workspaceNotFoundValue(tool: String, language: String, filePath: String) -> Value {
        return .object([
            "ok":          .bool(false),
            "status":      .string("workspace_not_found"),
            "tool":        .string(tool),
            "language":    .string(language),
            "filePath":    .string(filePath),
            "error":       .string("no workspace marker found within 32 ancestor directories of '\(filePath)'"),
            "remediation": .string(language == "typescript"
                ? "create a tsconfig.json, jsconfig.json, or package.json at the workspace root"
                : "create a Package.swift at the Swift package root")
        ])
    }

    // MARK: - JSON ↔ Value bridge

    /// Decode a `Data?` JSON-RPC response payload into an MCP `Value` (or `.null`).
    private static func valueFromData(_ data: Data?) -> Value {
        guard let data = data,
              !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return valueFromJSON(parsed)
    }

    /// Recursive `JSONSerialization`-result → `Value` converter. NSNumber Bool detection
    /// must precede int/double (CFBoolean uses NSNumber's type system).
    private static func valueFromJSON(_ json: Any) -> Value {
        if let dict = json as? [String: Any] {
            var out: [String: Value] = [:]
            for (k, v) in dict { out[k] = valueFromJSON(v) }
            return .object(out)
        }
        if let arr = json as? [Any] { return .array(arr.map(valueFromJSON)) }
        if let s = json as? String { return .string(s) }
        if let n = json as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let oct = String(cString: n.objCType)
            if oct == "d" || oct == "f" { return .double(n.doubleValue) }
            return .int(n.intValue)
        }
        if let b = json as? Bool { return .bool(b) }
        if let i = json as? Int { return .int(i) }
        if let d = json as? Double { return .double(d) }
        return .null
    }

    // MARK: - Common request flow

    private enum PrepResult {
        case capabilityMissing(Value)
        case noWorkspace(Value)
        case ready(session: LspSession?, filePath: String, language: String, workspaceRoot: String, error: Error?)
    }

    /// Shared front-half: probe → workspace → ensureSession → ensureFileOpen.
    private static func prepareSession(
        tool: String,
        arguments: Value
    ) async throws -> PrepResult {
        let (filePath, language) = try extractFileAndLanguage(arguments, tool: tool)
        let p = probe(language: language)
        if !p.available {
            return .capabilityMissing(capabilityMissingValue(tool: tool, probe: p))
        }
        guard let root = findWorkspaceRoot(forFile: filePath, language: language) else {
            return .noWorkspace(workspaceNotFoundValue(tool: tool, language: language, filePath: filePath))
        }
        do {
            let session = try await LspRuntime.shared.ensureSession(
                language: language,
                workspaceRoot: root.path,
                serverPath: p.path!
            )
            try await session.ensureFileOpen(filePath)
            return .ready(session: session, filePath: filePath, language: language, workspaceRoot: root.path, error: nil)
        } catch {
            return .ready(session: nil, filePath: filePath, language: language, workspaceRoot: root.path, error: error)
        }
    }

    private static func positionParams(filePath: String, line: Int, character: Int) -> [String: Any] {
        [
            "textDocument": ["uri": URL(fileURLWithPath: filePath).absoluteString],
            "position":     ["line": line, "character": character]
        ]
    }

    private static func successValue(tool: String, language: String, filePath: String, workspaceRoot: String, serverPath: String, result: Data?) -> Value {
        .object([
            "ok":            .bool(true),
            "tool":          .string(tool),
            "language":      .string(language),
            "filePath":      .string(filePath),
            "workspaceRoot": .string(workspaceRoot),
            "serverPath":    .string(serverPath),
            "result":        valueFromData(result)
        ])
    }

    // MARK: - Tool factories

    private static func makeDiagnostics() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_diagnostics",
            module: moduleName,
            tier: .request,
            description: "LSP diagnostics on a file. Returns the server's current diagnostics (errors, warnings, hints) from a push-based cache populated by `textDocument/publishDiagnostics` notifications. The first call after `textDocument/didOpen` waits up to 1.5s for the initial publish; subsequent calls return cached results immediately. An empty `result` array means the server reported no issues, not an error. Auto-detects language from extension; pass 'language' to override.",
            inputSchema: schema(),
            handler: { arguments in
                switch try await prepareSession(tool: "lsp_diagnostics", arguments: arguments) {
                case .capabilityMissing(let v): return v
                case .noWorkspace(let v):       return v
                case .ready(let session, let filePath, let language, let workspaceRoot, let prepErr):
                    guard let session = session, prepErr == nil else {
                        return errorValue(tool: "lsp_diagnostics", language: language, filePath: filePath, error: prepErr!)
                    }
                    // PKT-777 W2: serve from push-diagnostics cache. The cache is populated
                    // asynchronously by the server via `textDocument/publishDiagnostics`;
                    // the await-with-timeout below handles the cold-start case where the
                    // first call arrives before the server has emitted its initial publish.
                    let uri = URL(fileURLWithPath: filePath).absoluteString
                    let resultData = await session.diagnosticsJSON(forUri: uri, timeout: 1.5)
                    return successValue(tool: "lsp_diagnostics", language: language, filePath: filePath,
                                        workspaceRoot: workspaceRoot, serverPath: session.serverPath, result: resultData)
                }
            }
        )
    }

    private static func makeHover() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_hover",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/hover at (line, character). Returns markdown-formatted type info, doc strings, and signatures.",
            inputSchema: schema(extras: ["line": positionLineProp, "character": positionCharProp]),
            handler: { arguments in
                let (line, character) = try extractPosition(arguments, tool: "lsp_hover")
                switch try await prepareSession(tool: "lsp_hover", arguments: arguments) {
                case .capabilityMissing(let v): return v
                case .noWorkspace(let v):       return v
                case .ready(let session, let filePath, let language, let workspaceRoot, let prepErr):
                    guard let session = session, prepErr == nil else {
                        return errorValue(tool: "lsp_hover", language: language, filePath: filePath, error: prepErr!)
                    }
                    do {
                        let result = try await session.sendRequest(
                            method: "textDocument/hover",
                            params: positionParams(filePath: filePath, line: line, character: character),
                            timeout: 10
                        )
                        return successValue(tool: "lsp_hover", language: language, filePath: filePath,
                                            workspaceRoot: workspaceRoot, serverPath: session.serverPath, result: result)
                    } catch {
                        return errorValue(tool: "lsp_hover", language: language, filePath: filePath, error: error)
                    }
                }
            }
        )
    }

    private static func makeReferences() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_references",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/references at (line, character). Returns every reference site across the workspace.",
            inputSchema: schema(extras: [
                "line":               positionLineProp,
                "character":          positionCharProp,
                "includeDeclaration": .object([
                    "type":        .string("boolean"),
                    "description": .string("Include the symbol declaration site (default true).")
                ])
            ]),
            handler: { arguments in
                let (line, character) = try extractPosition(arguments, tool: "lsp_references")
                let includeDecl = includeDeclaration(arguments)
                switch try await prepareSession(tool: "lsp_references", arguments: arguments) {
                case .capabilityMissing(let v): return v
                case .noWorkspace(let v):       return v
                case .ready(let session, let filePath, let language, let workspaceRoot, let prepErr):
                    guard let session = session, prepErr == nil else {
                        return errorValue(tool: "lsp_references", language: language, filePath: filePath, error: prepErr!)
                    }
                    var params = positionParams(filePath: filePath, line: line, character: character)
                    params["context"] = ["includeDeclaration": includeDecl]
                    do {
                        let result = try await session.sendRequest(method: "textDocument/references", params: params, timeout: 15)
                        return successValue(tool: "lsp_references", language: language, filePath: filePath,
                                            workspaceRoot: workspaceRoot, serverPath: session.serverPath, result: result)
                    } catch {
                        return errorValue(tool: "lsp_references", language: language, filePath: filePath, error: error)
                    }
                }
            }
        )
    }

    private static func makeDefinition() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_definition",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/definition at (line, character). Returns the symbol's defining location(s).",
            inputSchema: schema(extras: ["line": positionLineProp, "character": positionCharProp]),
            handler: { arguments in
                let (line, character) = try extractPosition(arguments, tool: "lsp_definition")
                switch try await prepareSession(tool: "lsp_definition", arguments: arguments) {
                case .capabilityMissing(let v): return v
                case .noWorkspace(let v):       return v
                case .ready(let session, let filePath, let language, let workspaceRoot, let prepErr):
                    guard let session = session, prepErr == nil else {
                        return errorValue(tool: "lsp_definition", language: language, filePath: filePath, error: prepErr!)
                    }
                    do {
                        let result = try await session.sendRequest(
                            method: "textDocument/definition",
                            params: positionParams(filePath: filePath, line: line, character: character),
                            timeout: 10
                        )
                        return successValue(tool: "lsp_definition", language: language, filePath: filePath,
                                            workspaceRoot: workspaceRoot, serverPath: session.serverPath, result: result)
                    } catch {
                        return errorValue(tool: "lsp_definition", language: language, filePath: filePath, error: error)
                    }
                }
            }
        )
    }

    private static func makeRename() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_rename",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/rename at (line, character) with a new identifier name. Returns the server's WorkspaceEdit (compatible with file_apply_patch via PKT-750).",
            inputSchema: schema(extras: [
                "line":      positionLineProp,
                "character": positionCharProp,
                "newName":   .object([
                    "type":        .string("string"),
                    "description": .string("New identifier name for the symbol.")
                ])
            ]),
            handler: { arguments in
                let (line, character) = try extractPosition(arguments, tool: "lsp_rename")
                let newName = try extractNewName(arguments, tool: "lsp_rename")
                switch try await prepareSession(tool: "lsp_rename", arguments: arguments) {
                case .capabilityMissing(let v): return v
                case .noWorkspace(let v):       return v
                case .ready(let session, let filePath, let language, let workspaceRoot, let prepErr):
                    guard let session = session, prepErr == nil else {
                        return errorValue(tool: "lsp_rename", language: language, filePath: filePath, error: prepErr!)
                    }
                    var params = positionParams(filePath: filePath, line: line, character: character)
                    params["newName"] = newName
                    do {
                        let result = try await session.sendRequest(method: "textDocument/rename", params: params, timeout: 30)
                        return successValue(tool: "lsp_rename", language: language, filePath: filePath,
                                            workspaceRoot: workspaceRoot, serverPath: session.serverPath, result: result)
                    } catch {
                        return errorValue(tool: "lsp_rename", language: language, filePath: filePath, error: error)
                    }
                }
            }
        )
    }

    // MARK: - lsp_session_list (Option C observability tool)

    private static func makeSessionList() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_session_list",
            module: moduleName,
            tier: .request,
            description: "List every live LSP session under LspRuntime supervision: per-workspace process info, server name/version, spawn + last-used timestamps, idle seconds, request count, open-file count. The substitute for bg_process_list in the LSP supervision domain (PM Decision Log #29, PKT-745).",
            inputSchema: .object([
                "type":       .string("object"),
                "properties": .object([:])
            ]),
            handler: { _ in
                let infos = await LspRuntime.shared.listSessions()
                let timeout = await LspRuntime.shared.currentIdleTimeout()
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var rows: [Value] = []
                for info in infos {
                    rows.append(.object([
                        "language":      .string(info.language),
                        "workspaceRoot": .string(info.workspaceRoot),
                        "pid":           .int(Int(info.pid)),
                        "serverPath":    .string(info.serverPath),
                        "serverName":    info.serverName.map { Value.string($0) } ?? .null,
                        "serverVersion": info.serverVersion.map { Value.string($0) } ?? .null,
                        "spawnedAt":     .string(iso.string(from: info.spawnedAt)),
                        "lastUsedAt":    .string(iso.string(from: info.lastUsedAt)),
                        "idleSeconds":   .double(info.idleSeconds),
                        "requestCount":  .int(info.requestCount),
                        "openFileCount": .int(info.openFileCount)
                    ]))
                }
                return .object([
                    "ok":             .bool(true),
                    "sessions":       .array(rows),
                    "count":          .int(rows.count),
                    "idleTimeoutSec": .double(timeout)
                ])
            }
        )
    }
}
