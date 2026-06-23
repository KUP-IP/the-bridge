// SpotlightModule.swift — Spotlight metadata search via mdfind
// TheBridge · Modules
//
// PKT-747 (v2.2 · 3.3) — MAC UI extras: spotlight_query.
// Wraps the system `mdfind` CLI with predicate + scope + structured rows.
// No new TCC permissions required (mdfind is a public Apple CLI shipped with
// macOS at /usr/bin/mdfind).
//
// Sibling tools shipped in the same packet (SyntheticInputModule):
//   keyboard_type — synthetic typing via CGEvent.
// Deferred to follow-up packet PKT-3.3.1: mouse_click, cgevent_send, pasteboard_history.

import Foundation
import MCP

public enum SpotlightModule {
    public static let moduleName = "computer"

    // MARK: - Errors

    private enum SpotlightError: Error {
        case mdfindMissing
        case mdfindFailed(stderr: String, code: Int32)
        case invalidInput(String)

        func toResponse() -> Value {
            switch self {
            case .mdfindMissing:
                return .object([
                    "error": .string("capability_missing: /usr/bin/mdfind not present. Spotlight indexing must be enabled on this machine."),
                    "code": .string("capability_missing")
                ])
            case .mdfindFailed(let stderr, let code):
                return .object([
                    "error": .string("mdfind exited with code \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"),
                    "code": .string("mdfind_failed")
                ])
            case .invalidInput(let detail):
                return .object([
                    "error": .string("Invalid input: \(detail)"),
                    "code": .string("invalid_input")
                ])
            }
        }
    }

    // MARK: - Helpers

    private static func unwrap(_ arguments: Value) -> [String: Value] {
        if case .object(let a) = arguments { return a }
        return [:]
    }

    private static func stringParam(_ params: [String: Value], _ key: String) -> String? {
        if case .string(let s) = params[key] { return s }
        return nil
    }

    private static func intParam(_ params: [String: Value], _ key: String, default fallback: Int) -> Int {
        guard let v = params[key] else { return fallback }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        default:             return fallback
        }
    }

    private static func boolParam(_ params: [String: Value], _ key: String, default fallback: Bool) -> Bool {
        guard let v = params[key] else { return fallback }
        if case .bool(let b) = v { return b }
        return fallback
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Run mdfind and return parsed file paths + light metadata.
    private static func runMdfind(query: String, scope: String?, name: Bool, count: Bool, limit: Int) throws -> Value {
        let mdfindURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        guard FileManager.default.fileExists(atPath: mdfindURL.path) else {
            throw SpotlightError.mdfindMissing
        }

        let proc = Process()
        proc.executableURL = mdfindURL
        var args: [String] = []
        if let scope = scope, !scope.isEmpty {
            args.append("-onlyin")
            args.append(expandTilde(scope))
        }
        if name  { args.append("-name") }
        if count { args.append("-count") }
        args.append(query)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        do { try proc.run() }
        catch { throw SpotlightError.mdfindMissing }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            throw SpotlightError.mdfindFailed(stderr: stderr, code: proc.terminationStatus)
        }

        if count {
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // mdfind -count emits e.g. "23 matches"
            let firstToken = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            let n = Int(firstToken) ?? 0
            return .object([
                "count": .int(n),
                "query": .string(query),
                "scope": .string(scope ?? ""),
                "raw":   .string(trimmed)
            ])
        }

        let lines = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let truncated = lines.count > limit
        let kept = Array(lines.prefix(limit))

        let rows: [Value] = kept.map { path in
            let url = URL(fileURLWithPath: path)
            return .object([
                "path": .string(path),
                "name": .string(url.lastPathComponent),
                "dir":  .string(url.deletingLastPathComponent().path)
            ])
        }

        return .object([
            "matches":   .array(rows),
            "count":     .int(kept.count),
            "total":     .int(lines.count),
            "truncated": .bool(truncated),
            "query":     .string(query),
            "scope":     .string(scope ?? "")
        ])
    }

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "spotlight_query",
            module: moduleName,
            tier: .open,
            description: "Wrap macOS Spotlight (mdfind) with predicate + scope + structured rows. Use for metadata-aware system search (e.g. 'kMDItemContentType == \"public.swift-source\"'). For plain filename match under a known directory, prefer file_search.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query":  .object(["type": .string("string"),  "description": .string("Spotlight predicate or plain query (e.g. 'budget' or 'kMDItemContentType == \"public.swift-source\"').")]),
                    "scope":  .object(["type": .string("string"),  "description": .string("Optional directory to scope the search (tilde-expanded, e.g. '~/Library' or '~/Developer').")]),
                    "name":   .object(["type": .string("boolean"), "description": .string("Match query against file name (mdfind -name). Default false (full Spotlight predicate).")]),
                    "count":  .object(["type": .string("boolean"), "description": .string("Return only the count of matches (mdfind -count). Default false.")]),
                    "limit":  .object(["type": .string("integer"), "description": .string("Max rows to return (default: 200). Ignored when count=true.")])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { arguments in
                let params = unwrap(arguments)
                guard let query = stringParam(params, "query"), !query.isEmpty else {
                    return SpotlightError.invalidInput("query is required").toResponse()
                }
                let scope = stringParam(params, "scope")
                let name  = boolParam(params, "name",  default: false)
                let count = boolParam(params, "count", default: false)
                let limit = max(1, intParam(params, "limit", default: 200))

                do {
                    return try runMdfind(query: query, scope: scope, name: name, count: count, limit: limit)
                } catch let e as SpotlightError {
                    return e.toResponse()
                } catch {
                    return .object(["error": .string("Unexpected: \(error)")])
                }
            }
        ))
    }
}
