// CodeEditModule.swift — PKT-750 (v2.2 · 1.2): code_search · file_str_replace · file_apply_patch
// NotionBridge · Modules · dev/
//
// Three code-aware editing primitives, all registered on the dev/ module surface
// introduced in PKT-738 (v2.2 · 0.1):
//
//   code_search       — wraps `rg --json` with structured output (file, line,
//                       column, byte offset, lineText, submatches, optional
//                       before/after context). Tier .open. Returns
//                       capability_missing if ripgrep is not on PATH or in
//                       common Homebrew locations.
//
//   file_str_replace  — literal-string replace with uniqueness guarantee
//                       (single match by default; replaceAllMatches:true to
//                       override). preview:true returns a unified diff without
//                       writing. Atomic via String.write(atomically:true).
//                       Tier .notify.
//
//   file_apply_patch  — accepts a unified-diff patch (single-file), validates
//                       each hunk's context against current file content
//                       (rejects on drift), and applies atomically.
//                       preview:true validates without writing. Tier .notify.
//
// All three return the v2.2 dev/ error envelope:
//   ok=false; status ∈ {capability_missing, not_found, failed}; tool, error.

import Foundation
import MCP

// MARK: - CodeEditError

public enum CodeEditError: Error, LocalizedError {
    case capabilityMissing(String)
    case fileNotFound(String)
    case ambiguousMatch(count: Int, search: String)
    case noMatch(search: String)
    case contextDrift(hunkIndex: Int, reason: String)
    case invalidPatch(String)
    case ioError(String)
    case rgFailed(exit: Int32, stderr: String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .capabilityMissing(let r): return "capability_missing: \(r)"
        case .fileNotFound(let p):       return "file not found: \(p)"
        case .ambiguousMatch(let c, let s):
            return "ambiguous match: \(c) occurrences of \"\(s)\" — pass replaceAllMatches:true or narrow the pattern"
        case .noMatch(let s):            return "no occurrences of \"\(s)\" found"
        case .contextDrift(let i, let r): return "patch hunk #\(i) context drift: \(r)"
        case .invalidPatch(let r):       return "invalid unified-diff patch: \(r)"
        case .ioError(let r):            return "io error: \(r)"
        case .rgFailed(let e, let s):    return "rg exit \(e): \(s)"
        case .invalidArgument(let r):    return "invalid argument: \(r)"
        }
    }
}

// MARK: - CodeEditModule

public enum CodeEditModule {
    public static let moduleName = "dev"

    public static func register(on router: ToolRouter) async {
        await registerCodeSearch(on: router)
        await registerFileStrReplace(on: router)
        await registerFileApplyPatch(on: router)
    }

    // MARK: - rg discovery

    /// Lazy ripgrep discovery: PATH lookup via /usr/bin/which, then common static locations.
    public static func discoverRipgrep() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["rg"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch { /* fall through */ }
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/opt/local/bin/rg"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    // MARK: - Error envelope

    static func errorValue(_ tool: String, _ error: Error) -> Value {
        if let e = error as? CodeEditError {
            switch e {
            case .capabilityMissing(let reason):
                return .object([
                    "ok": .bool(false),
                    "status": .string("capability_missing"),
                    "tool": .string(tool),
                    "error": .string(reason)
                ])
            case .fileNotFound(let path):
                return .object([
                    "ok": .bool(false),
                    "status": .string("not_found"),
                    "tool": .string(tool),
                    "path": .string(path),
                    "error": .string(e.errorDescription ?? "")
                ])
            default:
                return .object([
                    "ok": .bool(false),
                    "status": .string("failed"),
                    "tool": .string(tool),
                    "error": .string(e.errorDescription ?? "")
                ])
            }
        }
        return .object([
            "ok": .bool(false),
            "status": .string("failed"),
            "tool": .string(tool),
            "error": .string(error.localizedDescription)
        ])
    }

    static func atomicWrite(path: String, content: String) throws {
        do {
            try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            throw CodeEditError.ioError("atomic write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - code_search

    private static func registerCodeSearch(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "code_search",
            module: moduleName,
            tier: .open,
            description: "Search source code with ripgrep, returning structured matches (path, lineNumber, absoluteOffset, lineText, submatches with start/end column offsets). Optional before/after line context. Preferred over `shell_exec rg` for programmatic match consumption. Returns capability_missing if ripgrep is not installed (install via `brew install ripgrep`).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object(["type": .string("string"), "description": .string("rg-flavoured regex (or literal if fixedString=true)")]),
                    "path": .object(["type": .string("string"), "description": .string("Root directory or single file (default: current working directory)")]),
                    "fixedString": .object(["type": .string("boolean"), "description": .string("Treat pattern as literal (rg -F). Default: false")]),
                    "ignoreCase": .object(["type": .string("boolean"), "description": .string("Case-insensitive (rg -i). Default: false")]),
                    "contextBefore": .object(["type": .string("integer"), "description": .string("Lines of context before each match (rg -B). Default: 0")]),
                    "contextAfter": .object(["type": .string("integer"), "description": .string("Lines of context after each match (rg -A). Default: 0")]),
                    "maxMatches": .object(["type": .string("integer"), "description": .string("Cap on returned match records. Default: 500")]),
                    "globs": .object(["type": .string("array"), "description": .string("Optional rg --glob filters (e.g. [\"*.swift\", \"!*.lock\"])")]),
                    "hidden": .object(["type": .string("boolean"), "description": .string("Search hidden files (rg --hidden). Default: false")])
                ]),
                "required": .array([.string("pattern")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let pattern) = args["pattern"] else {
                    throw ToolRouterError.invalidArguments(toolName: "code_search", reason: "missing required 'pattern' parameter")
                }
                let path: String = {
                    if case .string(let s) = args["path"] { return (s as NSString).expandingTildeInPath }
                    return FileManager.default.currentDirectoryPath
                }()
                let fixedString: Bool = { if case .bool(let b) = args["fixedString"] { return b }; return false }()
                let ignoreCase: Bool = { if case .bool(let b) = args["ignoreCase"] { return b }; return false }()
                let cBefore: Int = { if case .int(let i) = args["contextBefore"] { return max(0, i) }; return 0 }()
                let cAfter: Int = { if case .int(let i) = args["contextAfter"] { return max(0, i) }; return 0 }()
                let maxMatches: Int = { if case .int(let i) = args["maxMatches"] { return max(1, i) }; return 500 }()
                let hidden: Bool = { if case .bool(let b) = args["hidden"] { return b }; return false }()
                var globs: [String] = []
                if case .array(let arr) = args["globs"] {
                    for v in arr { if case .string(let s) = v { globs.append(s) } }
                }

                guard let rg = discoverRipgrep() else {
                    return errorValue("code_search", CodeEditError.capabilityMissing(
                        "ripgrep (rg) not found on PATH or in /opt/homebrew/bin, /usr/local/bin, /opt/local/bin. Install via `brew install ripgrep`."
                    ))
                }

                do {
                    return try runRipgrep(
                        rg: rg, pattern: pattern, path: path,
                        fixedString: fixedString, ignoreCase: ignoreCase,
                        contextBefore: cBefore, contextAfter: cAfter,
                        maxMatches: maxMatches, globs: globs, hidden: hidden
                    )
                } catch {
                    return errorValue("code_search", error)
                }
            }
        ))
    }

    static func runRipgrep(
        rg: String, pattern: String, path: String,
        fixedString: Bool, ignoreCase: Bool,
        contextBefore: Int, contextAfter: Int,
        maxMatches: Int, globs: [String], hidden: Bool
    ) throws -> Value {
        var rgArgs: [String] = ["--json", "--max-count", String(maxMatches)]
        if fixedString { rgArgs.append("-F") }
        if ignoreCase { rgArgs.append("-i") }
        if contextBefore > 0 { rgArgs.append("-B"); rgArgs.append(String(contextBefore)) }
        if contextAfter > 0  { rgArgs.append("-A"); rgArgs.append(String(contextAfter)) }
        if hidden { rgArgs.append("--hidden") }
        for g in globs { rgArgs.append("--glob"); rgArgs.append(g) }
        rgArgs.append("--")
        rgArgs.append(pattern)
        rgArgs.append(path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rg)
        proc.arguments = rgArgs
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let start = Date()
        do { try proc.run() } catch {
            throw CodeEditError.rgFailed(exit: -1, stderr: "failed to launch rg: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        let exitCode = proc.terminationStatus
        if exitCode == 2 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw CodeEditError.rgFailed(exit: exitCode, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var matches: [Value] = []
        var truncated = false

        if let stdout = String(data: outData, encoding: .utf8) {
            for raw in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                if matches.count >= maxMatches { truncated = true; break }
                guard let data = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type != "match" { continue }
                guard let dataObj = obj["data"] as? [String: Any] else { continue }
                let pathText = (dataObj["path"] as? [String: Any])?["text"] as? String ?? ""
                let lineText = (dataObj["lines"] as? [String: Any])?["text"] as? String ?? ""
                let lineNumber = dataObj["line_number"] as? Int ?? 0
                let absoluteOffset = dataObj["absolute_offset"] as? Int ?? 0
                var subs: [Value] = []
                if let submatches = dataObj["submatches"] as? [[String: Any]] {
                    for sm in submatches {
                        let mtxt = (sm["match"] as? [String: Any])?["text"] as? String ?? ""
                        let s = sm["start"] as? Int ?? 0
                        let e = sm["end"] as? Int ?? 0
                        subs.append(.object([
                            "match": .string(mtxt),
                            "start": .int(s),
                            "end": .int(e)
                        ]))
                    }
                }
                matches.append(.object([
                    "path": .string(pathText),
                    "lineNumber": .int(lineNumber),
                    "absoluteOffset": .int(absoluteOffset),
                    "lineText": .string(lineText),
                    "submatches": .array(subs)
                ]))
            }
        }

        return .object([
            "ok": .bool(true),
            "count": .int(matches.count),
            "truncated": .bool(truncated),
            "elapsedMs": .int(elapsedMs),
            "rgPath": .string(rg),
            "exitCode": .int(Int(exitCode)),
            "matches": .array(matches)
        ])
    }

    // MARK: - file_str_replace

    private static func registerFileStrReplace(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "file_str_replace",
            module: moduleName,
            tier: .notify,
            description: "Replace one or more occurrences of a literal string in a file. By default rejects ambiguous matches (>1 occurrence) — pass replaceAllMatches:true to override. Pass preview:true to receive a unified diff without writing. Atomic via String.write(atomically:true). Preferred over `shell_exec sed` for code edits because it guarantees scope (no accidental multi-match) and previewable diffs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute file path (tilde-expanded)")]),
                    "search": .object(["type": .string("string"), "description": .string("Literal string to find (not a regex)")]),
                    "replacement": .object(["type": .string("string"), "description": .string("Replacement string")]),
                    "replaceAllMatches": .object(["type": .string("boolean"), "description": .string("Replace all occurrences. Default: false (single-match enforced)")]),
                    "preview": .object(["type": .string("boolean"), "description": .string("Return unified diff without writing. Default: false")])
                ]),
                "required": .array([.string("path"), .string("search"), .string("replacement")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let search) = args["search"],
                      case .string(let replacement) = args["replacement"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_str_replace", reason: "missing required 'path', 'search', or 'replacement'")
                }
                let replaceAll: Bool = { if case .bool(let b) = args["replaceAllMatches"] { return b }; return false }()
                let preview: Bool = { if case .bool(let b) = args["preview"] { return b }; return false }()
                let expanded = (path as NSString).expandingTildeInPath

                do {
                    return try strReplace(path: expanded, search: search, replacement: replacement, replaceAll: replaceAll, preview: preview)
                } catch {
                    return errorValue("file_str_replace", error)
                }
            }
        ))
    }

    static func strReplace(path: String, search: String, replacement: String, replaceAll: Bool, preview: Bool) throws -> Value {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CodeEditError.fileNotFound(path)
        }
        if search.isEmpty {
            throw CodeEditError.invalidArgument("'search' must not be empty")
        }
        let originalData: Data
        do { originalData = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw CodeEditError.ioError("read failed: \(error.localizedDescription)") }
        guard let originalContent = String(data: originalData, encoding: .utf8) else {
            throw CodeEditError.ioError("file is not valid UTF-8: \(path)")
        }

        var occurrenceCount = 0
        var idx = originalContent.startIndex
        while let r = originalContent.range(of: search, range: idx..<originalContent.endIndex) {
            occurrenceCount += 1
            idx = r.upperBound
        }
        if occurrenceCount == 0 {
            throw CodeEditError.noMatch(search: search)
        }
        if occurrenceCount > 1 && !replaceAll {
            throw CodeEditError.ambiguousMatch(count: occurrenceCount, search: search)
        }

        let newContent: String
        if replaceAll {
            newContent = originalContent.replacingOccurrences(of: search, with: replacement)
        } else if let r = originalContent.range(of: search) {
            newContent = originalContent.replacingCharacters(in: r, with: replacement)
        } else {
            newContent = originalContent
        }

        let diff = makeUnifiedDiff(path: path, original: originalContent, modified: newContent, contextLines: 3)

        if !preview {
            try atomicWrite(path: path, content: newContent)
        }

        return .object([
            "ok": .bool(true),
            "preview": .bool(preview),
            "path": .string(path),
            "occurrencesFound": .int(occurrenceCount),
            "occurrencesReplaced": .int(replaceAll ? occurrenceCount : 1),
            "bytesBefore": .int(originalData.count),
            "bytesAfter": .int(newContent.utf8.count),
            "diff": .string(diff)
        ])
    }

    // MARK: - Unified diff generator (LCS-based, line-oriented)

    static func makeUnifiedDiff(path: String, original: String, modified: String, contextLines: Int) -> String {
        let aLines = original.components(separatedBy: "\n")
        let bLines = modified.components(separatedBy: "\n")
        if aLines == bLines { return "" }
        let lcs = longestCommonSubsequence(aLines, bLines)
        var ops: [(Character, String)] = []
        var i = 0, j = 0, k = 0
        while i < aLines.count || j < bLines.count {
            if k < lcs.count && i < aLines.count && j < bLines.count
                && aLines[i] == lcs[k] && bLines[j] == lcs[k] {
                ops.append(("=", aLines[i])); i += 1; j += 1; k += 1
            } else if i < aLines.count && (k >= lcs.count || aLines[i] != lcs[k]) {
                ops.append(("-", aLines[i])); i += 1
            } else if j < bLines.count {
                ops.append(("+", bLines[j])); j += 1
            }
        }
        var out = "--- a/\(path)\n+++ b/\(path)\n"
        var pos = 0
        while pos < ops.count {
            guard let changeStart = (pos..<ops.count).first(where: { ops[$0].0 != "=" }) else { break }
            let hunkStart = max(pos, changeStart - contextLines)
            var lastChange = changeStart
            var scan = changeStart + 1
            while scan < ops.count {
                if ops[scan].0 != "=" { lastChange = scan; scan += 1 }
                else if scan - lastChange > contextLines * 2 { break }
                else { scan += 1 }
            }
            let hunkEnd = min(ops.count, lastChange + contextLines + 1)
            var aStart = 0, aLen = 0, bStart = 0, bLen = 0
            for x in 0..<hunkStart {
                switch ops[x].0 {
                case "=": aStart += 1; bStart += 1
                case "-": aStart += 1
                case "+": bStart += 1
                default: break
                }
            }
            for x in hunkStart..<hunkEnd {
                switch ops[x].0 {
                case "=": aLen += 1; bLen += 1
                case "-": aLen += 1
                case "+": bLen += 1
                default: break
                }
            }
            out += "@@ -\(aStart + 1),\(aLen) +\(bStart + 1),\(bLen) @@\n"
            for x in hunkStart..<hunkEnd {
                let prefix: String
                switch ops[x].0 {
                case "=": prefix = " "
                case "-": prefix = "-"
                case "+": prefix = "+"
                default: prefix = " "
                }
                out += "\(prefix)\(ops[x].1)\n"
            }
            pos = hunkEnd
        }
        return out
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if a[i] == b[j] { dp[i + 1][j + 1] = dp[i][j] + 1 }
                else { dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j]) }
            }
        }
        var i = n, j = m
        var lcs: [String] = []
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] { lcs.append(a[i - 1]); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 }
            else { j -= 1 }
        }
        return lcs.reversed()
    }

    // MARK: - file_apply_patch

    private static func registerFileApplyPatch(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "file_apply_patch",
            module: moduleName,
            tier: .notify,
            description: "Apply a unified-diff patch to a single file. Validates each hunk's context against current file content (rejects on drift). Atomic via String.write(atomically:true). Multi-file diffs must be split per file by the caller. Pass preview:true to validate without writing.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Absolute file path the patch applies to (tilde-expanded)")]),
                    "patch": .object(["type": .string("string"), "description": .string("Unified-diff patch text. The --- / +++ headers are optional and ignored if present.")]),
                    "preview": .object(["type": .string("boolean"), "description": .string("Validate without writing. Default: false")])
                ]),
                "required": .array([.string("path"), .string("patch")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let path) = args["path"],
                      case .string(let patch) = args["patch"] else {
                    throw ToolRouterError.invalidArguments(toolName: "file_apply_patch", reason: "missing required 'path' or 'patch'")
                }
                let preview: Bool = { if case .bool(let b) = args["preview"] { return b }; return false }()
                let expanded = (path as NSString).expandingTildeInPath
                do {
                    return try applyPatch(path: expanded, patch: patch, preview: preview)
                } catch {
                    return errorValue("file_apply_patch", error)
                }
            }
        ))
    }

    struct PatchHunk {
        let aStart: Int
        let aLen: Int
        let bStart: Int
        let bLen: Int
        let ops: [(Character, String)]
    }

    static func applyPatch(path: String, patch: String, preview: Bool) throws -> Value {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CodeEditError.fileNotFound(path)
        }
        let originalData = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let originalContent = String(data: originalData, encoding: .utf8) else {
            throw CodeEditError.ioError("file is not valid UTF-8: \(path)")
        }
        let originalLines = originalContent.components(separatedBy: "\n")

        let hunks = try parseUnifiedDiffHunks(patch)
        if hunks.isEmpty {
            throw CodeEditError.invalidPatch("no hunks (@@ headers) found in patch")
        }

        var newLines = originalLines
        var hunksApplied = 0
        var lineOffset = 0

        for (idx, hunk) in hunks.enumerated() {
            let aStartIdx = hunk.aStart - 1 + lineOffset
            if aStartIdx < 0 || aStartIdx + hunk.aLen > newLines.count {
                throw CodeEditError.contextDrift(hunkIndex: idx, reason: "hunk references lines \(hunk.aStart)..\(hunk.aStart + hunk.aLen - 1) which are out of range (file has \(newLines.count) lines after prior hunks)")
            }
            var expectedOld: [String] = []
            var newSlice: [String] = []
            for op in hunk.ops {
                switch op.0 {
                case " ":
                    expectedOld.append(op.1)
                    newSlice.append(op.1)
                case "-":
                    expectedOld.append(op.1)
                case "+":
                    newSlice.append(op.1)
                default:
                    throw CodeEditError.invalidPatch("unknown op '\(op.0)' in hunk #\(idx)")
                }
            }
            if expectedOld.count != hunk.aLen {
                throw CodeEditError.invalidPatch("hunk #\(idx) header says aLen=\(hunk.aLen) but op-count produced \(expectedOld.count)")
            }
            let actualOld = Array(newLines[aStartIdx..<aStartIdx + hunk.aLen])
            if actualOld != expectedOld {
                var divergeAt = -1
                for k in 0..<min(actualOld.count, expectedOld.count) {
                    if actualOld[k] != expectedOld[k] { divergeAt = k; break }
                }
                let lineLabel = divergeAt >= 0 ? "line \(hunk.aStart + divergeAt)" : "size mismatch"
                let expectedSample = divergeAt >= 0 ? expectedOld[divergeAt] : ""
                let actualSample = divergeAt >= 0 ? actualOld[divergeAt] : ""
                throw CodeEditError.contextDrift(hunkIndex: idx, reason: "context mismatch at \(lineLabel) — expected \"\(expectedSample)\" but file has \"\(actualSample)\"")
            }
            newLines.replaceSubrange(aStartIdx..<aStartIdx + hunk.aLen, with: newSlice)
            lineOffset += newSlice.count - hunk.aLen
            hunksApplied += 1
        }

        let newContent = newLines.joined(separator: "\n")

        if !preview {
            try atomicWrite(path: path, content: newContent)
        }

        return .object([
            "ok": .bool(true),
            "preview": .bool(preview),
            "path": .string(path),
            "hunksApplied": .int(hunksApplied),
            "bytesBefore": .int(originalData.count),
            "bytesAfter": .int(newContent.utf8.count)
        ])
    }

    static func parseUnifiedDiffHunks(_ patch: String) throws -> [PatchHunk] {
        let lines = patch.components(separatedBy: "\n")
        var hunks: [PatchHunk] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@") {
                guard let parsed = parseHunkHeader(line) else {
                    throw CodeEditError.invalidPatch("malformed hunk header: \(line)")
                }
                i += 1
                var ops: [(Character, String)] = []
                while i < lines.count {
                    let opLine = lines[i]
                    if opLine.hasPrefix("@@") { break }
                    if opLine.isEmpty {
                        i += 1
                        if i >= lines.count { break }
                        continue
                    }
                    let prefix = opLine.first!
                    if prefix == "-" || prefix == "+" || prefix == " " {
                        // Skip --- and +++ file header lines specifically
                        if (prefix == "-" && opLine.hasPrefix("---")) || (prefix == "+" && opLine.hasPrefix("+++")) {
                            i += 1
                            continue
                        }
                        let content = String(opLine.dropFirst())
                        ops.append((prefix, content))
                        i += 1
                    } else if opLine.hasPrefix("diff ") || opLine.hasPrefix("index ") {
                        i += 1
                    } else if opLine.hasPrefix("\\") {
                        // "\ No newline at end of file" — consume
                        i += 1
                    } else {
                        break
                    }
                }
                hunks.append(PatchHunk(aStart: parsed.aStart, aLen: parsed.aLen, bStart: parsed.bStart, bLen: parsed.bLen, ops: ops))
            } else {
                i += 1
            }
        }
        return hunks
    }

    private static func parseHunkHeader(_ line: String) -> (aStart: Int, aLen: Int, bStart: Int, bLen: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
        func parseRange(_ s: String) -> (Int, Int)? {
            let trimmed = String(s.dropFirst())
            if trimmed.contains(",") {
                let comps = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
                guard comps.count == 2, let a = Int(comps[0]), let b = Int(comps[1]) else { return nil }
                return (a, b)
            }
            guard let a = Int(trimmed) else { return nil }
            return (a, 1)
        }
        guard let aRange = parseRange(parts[0]), let bRange = parseRange(parts[1]) else { return nil }
        return (aRange.0, aRange.1, bRange.0, bRange.1)
    }
}
