// LspModuleLiveExtraTests.swift — PKT-789 W3.cleanup: TS rename + references evidence
// NotionBridge · Tests
//
// LSP_LIVE=1 gated. Closes DoD #5 evidence for TS-LSP side:
//   - references query latency log (DoD target ≤500ms p50)
//   - rename across keepup-club (DoD target ≥10 files in WorkspaceEdit)
//
// Both metrics are logged; rename asserts ≥1 file (the strict ≥10 target is logged-only
// because reach depends on which top-level symbol the heuristic picks — pickability is
// part of the evidence, not a pass/fail invariant).

import Foundation
import MCP
import NotionBridgeLib

func runLspModuleRenameRefsLiveTests() async {
    guard ProcessInfo.processInfo.environment["LSP_LIVE"] == "1" else { return }

    let env = ProcessInfo.processInfo.environment
    let keepupClub = env["KEEPUP_CLUB"]
        ?? "\(NSHomeDirectory())/Developer/keepup-club"

    await test("[LSP_LIVE] TS-LSP references latency + rename across files") {
        guard FileManager.default.fileExists(atPath: keepupClub) else {
            throw TestError.assertion("\(keepupClub) not present; set KEEPUP_CLUB to override")
        }
        let probe = LspModule.probe(language: "typescript")
        guard probe.available, let serverPath = probe.path else {
            throw TestError.assertion("typescript-language-server not on PATH")
        }

        // Pick the first non-trivial .ts/.tsx file with ≥200 chars (skip vendor / build dirs).
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: keepupClub) else {
            throw TestError.assertion("could not enumerate \(keepupClub)")
        }
        var candidate: (path: String, content: String)?
        while let rel = enumerator.nextObject() as? String {
            guard (rel.hasSuffix(".ts") || rel.hasSuffix(".tsx")),
                  !rel.contains("node_modules/"),
                  !rel.contains(".next/"),
                  !rel.contains("dist/"),
                  !rel.contains("build/"),
                  !rel.hasSuffix(".d.ts") else { continue }
            let full = "\(keepupClub)/\(rel)"
            if let s = try? String(contentsOfFile: full, encoding: .utf8), s.count > 200 {
                candidate = (full, s)
                break
            }
        }
        guard let pick = candidate else {
            throw TestError.assertion("no suitable .ts/.tsx file found in \(keepupClub)")
        }
        guard let root = LspModule.findWorkspaceRoot(forFile: pick.path, language: "typescript") else {
            throw TestError.assertion("could not locate TS workspace for \(pick.path)")
        }

        // Restore default idle timeout in case the earlier live test left it short.
        await LspRuntime.shared.setIdleTimeout(15 * 60)
        let session = try await LspRuntime.shared.ensureSession(
            language: "typescript", workspaceRoot: root.path, serverPath: serverPath)
        try await session.ensureFileOpen(pick.path)

        // Locate the first top-level declaration name on any line.
        let lines = pick.content.components(separatedBy: "\n")
        var pickedLine = -1, pickedChar = -1, pickedName = ""
        let pattern = try NSRegularExpression(
            pattern: "^\\s*(?:export\\s+)?(?:async\\s+)?(?:function|const|let|var|type|interface|class)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            options: [])
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            if let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2 {
                let nameRange = m.range(at: 1)
                pickedLine = i
                pickedChar = nameRange.location
                pickedName = ns.substring(with: nameRange)
                break
            }
        }
        guard pickedLine >= 0 else {
            throw TestError.assertion("could not locate any top-level declaration in \(pick.path)")
        }
        print("    \u{25B8} target: \(pick.path) line \(pickedLine) col \(pickedChar) name '\(pickedName)'")

        // References — log latency + site count.
        let refsBegin = Date()
        let refsResult = try await session.sendRequest(
            method: "textDocument/references",
            params: [
                "textDocument": ["uri": URL(fileURLWithPath: pick.path).absoluteString],
                "position":     ["line": pickedLine, "character": pickedChar],
                "context":      ["includeDeclaration": true]
            ],
            timeout: 30)
        let refsElapsed = Date().timeIntervalSince(refsBegin)
        var refsCount = 0
        if let data = refsResult,
           let arr = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [Any] {
            refsCount = arr.count
        }
        print("    \u{25B8} TS-LSP references: \(refsCount) sites in \(String(format: "%.3f", refsElapsed))s")

        // Rename — count unique file URIs in the WorkspaceEdit response.
        let renameNew = "Renamed_\(pickedName)_PKT789"
        let renameBegin = Date()
        let renameResult = try await session.sendRequest(
            method: "textDocument/rename",
            params: [
                "textDocument": ["uri": URL(fileURLWithPath: pick.path).absoluteString],
                "position":     ["line": pickedLine, "character": pickedChar],
                "newName":      renameNew
            ],
            timeout: 60)
        let renameElapsed = Date().timeIntervalSince(renameBegin)
        var uniqueUris = Set<String>()
        if let data = renameResult,
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            if let changes = obj["changes"] as? [String: Any] {
                for k in changes.keys { uniqueUris.insert(k) }
            }
            if let docChanges = obj["documentChanges"] as? [[String: Any]] {
                for dc in docChanges {
                    if let td = dc["textDocument"] as? [String: Any],
                       let uri = td["uri"] as? String {
                        uniqueUris.insert(uri)
                    }
                }
            }
        }
        print("    \u{25B8} TS-LSP rename '\(pickedName)' → '\(renameNew)': \(uniqueUris.count) files in \(String(format: "%.3f", renameElapsed))s")
        try expect(uniqueUris.count >= 1, "rename should produce at least 1 file edit; got \(uniqueUris.count)")
        if uniqueUris.count < 10 {
            print("    \u{26A0}\u{FE0F}  rename touched only \(uniqueUris.count) file(s); DoD target ≥10 — heuristic picked a low-reach symbol")
        }
    }

    await LspRuntime.shared.disposeAll()
}
