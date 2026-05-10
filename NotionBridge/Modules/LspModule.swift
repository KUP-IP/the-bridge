// LspModule.swift – PKT-745 W1: lsp_* tool scaffolding (TypeScript first, Swift second)
// NotionBridge · Modules · dev/
//
// Five Language Server Protocol tools that act as the stable MCP surface for
// AST-aware operations: diagnostics, hover, references, definition, rename.
//
//   - lsp_diagnostics  : textDocument/publishDiagnostics (errors / warnings / hints)
//   - lsp_hover        : textDocument/hover               (type info + doc strings)
//   - lsp_references   : textDocument/references          (every reference site)
//   - lsp_definition   : textDocument/definition          (defining location(s))
//   - lsp_rename       : textDocument/rename              (atomic workspace patch)
//
// Tier: .request for all five (LSP operations cross the file / AST boundary
// and can spawn long-running servers).
//
// PKT-745 W1 scope (this packet):
//   ✅ Registration scaffold (5 tools wired into router under module "dev").
//   ✅ Capability probe — direct binary lookup at standard install paths
//      (avoids relying on the app's runtime PATH; pins the location, not
//      the minor version — per Decision Log #21 guardrail #1).
//   ✅ Language inference from file extension (.ts/.tsx/.js/.jsx/.mjs/.cjs
//      → typescript; .swift → swift).
//   ✅ Workspace detection (walks parents looking for tsconfig.json /
//      Package.swift markers).
//   ✅ Clean `capability_missing` response when the LSP server binary is
//      absent, including a copy-paste remediation command.
//
// PKT-745 W2 (next dispatch) — out of scope here:
//   - JSON-RPC client (stdio framing, Initialize / Initialized handshake,
//     textDocument/* request mapping).
//   - Lazy-spawn lifecycle supervised by BgProcessRuntime.shared
//     (per-workspace, 15-min idle timeout, dispose on workspace close).
//   - Swift Sourcekit-LSP adapter (Package.swift workspace).
//   - Integration tests (TS rename across KEEP·OS web; Swift hover against
//     Bridge core itself).
//
// Until W2 lands, all five handlers return `status: "not_implemented"`
// (mirrors the JobsModule PKT-340 W1 pattern). Capability probe and
// workspace detection ARE live and testable from W1.

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
    }

    // MARK: - Probe result

    public struct ProbeResult: Sendable {
        public let language: String
        public let available: Bool
        public let path: String?
        public let detail: String?
    }

    /// Locate an LSP server binary by checking standard install paths
    /// directly (no Process spawn). This is robust to the app's runtime
    /// PATH being narrower than a user shell's PATH — the common cause of
    /// `which` failing inside the Bridge MCP process even when the binary
    /// is installed.
    public static func probe(language: String) -> ProbeResult {
        switch language {
        case "typescript", "javascript", "ts", "js", "tsx", "jsx":
            let candidates = [
                "/opt/homebrew/bin/typescript-language-server",   // Apple Silicon Homebrew (npm -g prefix)
                "/usr/local/bin/typescript-language-server",      // Intel Homebrew / system
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

    /// Infer the LSP language ID from a file extension. Returns nil for
    /// unsupported extensions (caller should require an explicit `language`
    /// argument in that case).
    public static func inferLanguage(fromPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "typescript"
        case "swift":                                  return "swift"
        default:                                       return nil
        }
    }

    // MARK: - Workspace detection

    /// Walk up parents from `filePath` looking for a workspace marker.
    ///   - typescript : tsconfig.json → jsconfig.json → package.json
    ///   - swift      : Package.swift
    /// Returns nil if no marker is found within 32 ancestor directories.
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
            "type": .string("string"),
            "description": .string("Absolute path to the source file the LSP request targets.")
        ]),
        "language": .object([
            "type": .string("string"),
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
        "type": .string("integer"),
        "description": .string("Zero-indexed line number.")
    ])

    private static let positionCharProp: Value = .object([
        "type": .string("integer"),
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

    // MARK: - Response shapes

    private static func capabilityMissingValue(tool: String, probe: ProbeResult) -> Value {
        let remediation: String
        switch probe.language {
        case "typescript":
            remediation = "npm install -g typescript-language-server typescript"
        case "swift":
            remediation = "Install Xcode from the App Store (Sourcekit-LSP ships with the Xcode toolchain), or run `xcode-select --install`."
        default:
            remediation = "(no remediation — unsupported language)"
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

    private static func notImplementedValue(
        tool: String, language: String, probe: ProbeResult,
        filePath: String, workspaceRoot: URL?
    ) -> Value {
        .object([
            "ok":            .bool(false),
            "status":        .string("not_implemented"),
            "tool":          .string(tool),
            "language":      .string(language),
            "serverPath":    .string(probe.path ?? ""),
            "filePath":      .string(filePath),
            "workspaceRoot": .string(workspaceRoot?.path ?? "(not detected)"),
            "note":          .string("PKT-745 W1 scaffold: registration + capability probe + workspace detection are live. JSON-RPC client + bg_process lifecycle land in W2 follow-up packet.")
        ])
    }

    // MARK: - Tool factories

    private static func makeDiagnostics() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_diagnostics",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/publishDiagnostics on a file. Returns diagnostics (errors, warnings, hints) from typescript-language-server (.ts/.tsx/.js/.jsx/.mjs/.cjs) or sourcekit-lsp (.swift). Auto-detects language from extension; pass 'language' to override. PKT-745 W1 scaffold — returns `not_implemented` until W2 LSP JSON-RPC client lands.",
            inputSchema: schema(),
            handler: { arguments in
                let (filePath, language) = try extractFileAndLanguage(arguments, tool: "lsp_diagnostics")
                let p = probe(language: language)
                if !p.available { return capabilityMissingValue(tool: "lsp_diagnostics", probe: p) }
                let root = findWorkspaceRoot(forFile: filePath, language: language)
                return notImplementedValue(tool: "lsp_diagnostics", language: language, probe: p, filePath: filePath, workspaceRoot: root)
            }
        )
    }

    private static func makeHover() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_hover",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/hover at (line, character). Returns markdown-formatted type info, doc strings, and signatures. PKT-745 W1 scaffold — returns `not_implemented` until W2 LSP JSON-RPC client lands.",
            inputSchema: schema(extras: [
                "line":      positionLineProp,
                "character": positionCharProp
            ]),
            handler: { arguments in
                let (filePath, language) = try extractFileAndLanguage(arguments, tool: "lsp_hover")
                let p = probe(language: language)
                if !p.available { return capabilityMissingValue(tool: "lsp_hover", probe: p) }
                let root = findWorkspaceRoot(forFile: filePath, language: language)
                return notImplementedValue(tool: "lsp_hover", language: language, probe: p, filePath: filePath, workspaceRoot: root)
            }
        )
    }

    private static func makeReferences() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_references",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/references at (line, character). Returns every reference site across the workspace. PKT-745 W1 scaffold — returns `not_implemented` until W2 LSP JSON-RPC client lands.",
            inputSchema: schema(extras: [
                "line":               positionLineProp,
                "character":          positionCharProp,
                "includeDeclaration": .object([
                    "type":        .string("boolean"),
                    "description": .string("Include the symbol declaration site (default true).")
                ])
            ]),
            handler: { arguments in
                let (filePath, language) = try extractFileAndLanguage(arguments, tool: "lsp_references")
                let p = probe(language: language)
                if !p.available { return capabilityMissingValue(tool: "lsp_references", probe: p) }
                let root = findWorkspaceRoot(forFile: filePath, language: language)
                return notImplementedValue(tool: "lsp_references", language: language, probe: p, filePath: filePath, workspaceRoot: root)
            }
        )
    }

    private static func makeDefinition() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_definition",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/definition at (line, character). Returns the symbol's defining location(s). PKT-745 W1 scaffold — returns `not_implemented` until W2 LSP JSON-RPC client lands.",
            inputSchema: schema(extras: [
                "line":      positionLineProp,
                "character": positionCharProp
            ]),
            handler: { arguments in
                let (filePath, language) = try extractFileAndLanguage(arguments, tool: "lsp_definition")
                let p = probe(language: language)
                if !p.available { return capabilityMissingValue(tool: "lsp_definition", probe: p) }
                let root = findWorkspaceRoot(forFile: filePath, language: language)
                return notImplementedValue(tool: "lsp_definition", language: language, probe: p, filePath: filePath, workspaceRoot: root)
            }
        )
    }

    private static func makeRename() -> ToolRegistration {
        ToolRegistration(
            name: "lsp_rename",
            module: moduleName,
            tier: .request,
            description: "LSP textDocument/rename at (line, character) with a new identifier name. Returns an atomic workspace patch compatible with file_apply_patch (PKT-750). PKT-745 W1 scaffold — returns `not_implemented` until W2 LSP JSON-RPC client lands.",
            inputSchema: schema(extras: [
                "line":      positionLineProp,
                "character": positionCharProp,
                "newName":   .object([
                    "type":        .string("string"),
                    "description": .string("New identifier name for the symbol.")
                ])
            ]),
            handler: { arguments in
                let (filePath, language) = try extractFileAndLanguage(arguments, tool: "lsp_rename")
                let p = probe(language: language)
                if !p.available { return capabilityMissingValue(tool: "lsp_rename", probe: p) }
                let root = findWorkspaceRoot(forFile: filePath, language: language)
                return notImplementedValue(tool: "lsp_rename", language: language, probe: p, filePath: filePath, workspaceRoot: root)
            }
        )
    }
}
