// ArtifactModuleTests.swift — PKT-743 (Bridge v2.2 · 3.1)

import CryptoKit
import Foundation
import MCP
import TheBridgeLib

func runArtifactModuleTests() async {
    print("\n📦 ArtifactModule Tests (PKT-743 v2.2 · 3.1)")

    await test("ArtifactModule registers 5 dev tools") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let names = Set(await router.registrations(forModule: "dev").map(\.name))
        let expected: Set<String> = [
            "http_fetch",
            "diff_render",
            "file_zip",
            "file_unzip",
            "file_hash",
        ]
        try expect(expected.isSubset(of: names), "missing artifact tools: \(expected.subtracting(names).sorted())")
    }

    await test("diff_render escapes HTML and counts hunks") {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let diff = """
        --- a/file.ts
        +++ b/file.ts
        @@ -1 +1 @@
        -const x = "<script>"
        +const x = "safe"
        """
        let result = try await router.dispatch(toolName: "diff_render", arguments: .object([
            "diff": .string(diff),
            "format": .string("html")
        ]))
        guard case .object(let dict) = result,
              case .string(let rendered) = dict["rendered"],
              case .int(let hunks) = dict["hunks"],
              case .int(let additions) = dict["additions"],
              case .int(let deletions) = dict["deletions"] else {
            throw TestError.assertion("unexpected diff_render payload")
        }
        try expect(rendered.contains("&lt;script&gt;"), "HTML output must escape script content")
        try expect(!rendered.contains("<script>"), "HTML output must not contain raw script tag")
        try expect(hunks == 1)
        try expect(additions == 1)
        try expect(deletions == 1)
    }

    await test("file_hash returns SHA-256") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-artifact-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("a.txt")
        let data = Data("hello\n".utf8)
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let result = try await router.dispatch(toolName: "file_hash", arguments: .object(["path": .string(file.path)]))
        guard case .object(let dict) = result,
              case .string(let hash) = dict["hash"],
              case .int(let bytes) = dict["bytes"] else {
            throw TestError.assertion("unexpected file_hash payload")
        }
        try expect(hash == expected)
        try expect(bytes == data.count)
    }

    await test("file_zip/file_unzip round trip") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nb-artifact-zip-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("src")
        let out = tmp.appendingPathComponent("out")
        let archive = tmp.appendingPathComponent("archive.zip")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "roundtrip".write(to: src.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)

        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await ArtifactModule.register(on: router)
        let zipResult = try await router.dispatch(toolName: "file_zip", arguments: .object([
            "sourcePath": .string(src.path),
            "archivePath": .string(archive.path),
            "includeRoot": .bool(true)
        ]))
        guard case .object(let zipDict) = zipResult, case .bool(true) = zipDict["ok"] else {
            throw TestError.assertion("zip did not succeed")
        }
        let unzipResult = try await router.dispatch(toolName: "file_unzip", arguments: .object([
            "archivePath": .string(archive.path),
            "destinationPath": .string(out.path)
        ]))
        guard case .object(let unzipDict) = unzipResult, case .bool(true) = unzipDict["ok"] else {
            throw TestError.assertion("unzip did not succeed")
        }
        let payload = out.appendingPathComponent("src/payload.txt")
        try expect(FileManager.default.fileExists(atPath: payload.path), "expected extracted payload")
        try expect(try String(contentsOf: payload, encoding: .utf8) == "roundtrip")
    }

}
