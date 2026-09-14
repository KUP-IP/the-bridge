// FetchSkillNotionFilesTests.swift — #254 Notion Files & media catalog + materialize
// TheBridge · Tests
//
// SEPARATE from FetchSkillFileSourceTests / buildFileSkillResult (those cover
// bundled/user SKILL.md file-source skills, `source: "file"`). This file covers
// KEEP OS SKILLS data-source Files & media on a Notion-backed fetch_skill row.

import Foundation
import MCP
import TheBridgeLib

func runFetchSkillNotionFilesTests() async {
    print("\n\u{1F4CE} fetch_skill Notion Files & media Tests (#254)")

    func mdJSON(_ markdown: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["markdown": markdown], options: [])
        return String(data: data, encoding: .utf8)!
    }

    func build(
        props: [String: Any],
        body: String = "hello body",
        pageId: String = "1111111111111111111111111111aaaa"
    ) async -> Value {
        await SkillsModule.buildSkillResultForTesting(
            name: "brand-manager",
            title: "Brand Manager",
            url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(body),
            pageId: pageId,
            pageProperties: props
        ) { _ in nil }
    }

    func envelope(_ v: Value) throws -> [String: Value] {
        guard case .object(let o) = v else {
            throw TestError.assertion("expected object envelope")
        }
        return o
    }

    func filesArray(_ v: Value) throws -> [Value] {
        let o = try envelope(v)
        guard case .array(let arr)? = o["files"] else {
            throw TestError.assertion("expected files array, got \(o.keys.sorted())")
        }
        return arr
    }

    func filesProp(_ entries: [[String: Any]]) -> [String: Any] {
        ["type": "files", "files": entries]
    }

    let pageId = "1111111111111111111111111111aaaa"

    await test("#254: empty Files & media emits files: [] (omit is not honest)") {
        let env = try envelope(await build(props: [
            "Files & media": filesProp([])
        ]))
        guard case .array(let files)? = env["files"] else {
            throw TestError.assertion("files must be present when the property exists")
        }
        try expect(files.isEmpty, "empty Files & media → files: []")
    }

    await test("#254: no Files & media property omits the files key") {
        let env = try envelope(await build(props: [
            "Status": ["type": "status", "status": ["name": "Active", "id": "s1"]]
        ]))
        try expect(env["files"] == nil, "omit is OK when the property does not exist")
    }

    await test("#254: populated Files & media returns name, kind, notionFileId") {
        let result = await build(props: [
            "Files & media": filesProp([
                [
                    "name": "logo.png",
                    "type": "file",
                    "id": "file-abc",
                    "file": ["url": "https://s3.example/logo.png", "expiry_time": "2099-01-01T00:00:00Z"]
                ]
            ])
        ])
        let files = try filesArray(result)
        try expect(files.count == 1, "one attachment")
        guard case .object(let f) = files[0] else {
            throw TestError.assertion("file entry must be an object")
        }
        try expect(f["name"] == .string("logo.png"))
        try expect(f["kind"] == .string("notion_hosted"))
        try expect(f["notionFileId"] == .string("file-abc"))
        try expect(f["downloadURL"] == nil, "ephemeral Notion URLs must not leak into the envelope")
        try expect(f["localPath"] == nil, "not yet materialized")
    }

    await test("#254: Google Drive File column catalogs as google_drive") {
        let result = await build(props: [
            "Google Drive File": filesProp([
                [
                    "name": "brand-kit",
                    "type": "external",
                    "external": ["url": "https://drive.google.com/file/d/xyz"]
                ]
            ])
        ])
        let files = try filesArray(result)
        guard case .object(let f) = files[0] else {
            throw TestError.assertion("expected object")
        }
        try expect(f["name"] == .string("brand-kit"))
        try expect(f["kind"] == .string("google_drive"))
    }

    await test("#254: Files & media + Google Drive File concatenate into one catalog") {
        let result = await build(props: [
            "Files & media": filesProp([
                ["name": "headshot.jpg", "type": "file", "id": "f1",
                 "file": ["url": "https://s3.example/h.jpg"]]
            ]),
            "Google Drive File": filesProp([
                ["name": "drive-doc", "type": "external",
                 "external": ["url": "https://docs.google.com/document/d/1"]]
            ])
        ])
        let files = try filesArray(result)
        try expect(files.count == 2, "both columns contribute")
        let names = files.compactMap { v -> String? in
            guard case .object(let o) = v, case .string(let n)? = o["name"] else { return nil }
            return n
        }
        try expect(names == ["headshot.jpg", "drive-doc"], "got \(names)")
    }

    await test("#254: assetRoot captures ~/Desktop/Brand Master from prose") {
        let body = "Binary SSOT is local ~/Desktop/Brand Master until this ships."
        let env = try envelope(await build(props: [:], body: body))
        try expect(env["assetRoot"] == .string("~/Desktop/Brand Master"),
                   "got \(String(describing: env["assetRoot"]))")
    }

    await test("#254: assetRoot omitted when the body names no Mac folder") {
        let env = try envelope(await build(props: [:], body: "# Brand Manager\n\nNo local path here."))
        try expect(env["assetRoot"] == nil, "no folder → omit assetRoot")
    }

    await test("#254: assetRoot accepts /Users/... Desktop folders") {
        let root = SkillFileCatalog.assetRoot(
            fromMarkdown: "Library lives at /Users/keepup/Desktop/Brand Master."
        )
        try expect(root == "/Users/keepup/Desktop/Brand Master", "got \(String(describing: root))")
    }

    await test("#254: materializeBytes writes under skill-files/<uuid>/") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-skillfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        let bytes = Data("icon-bytes".utf8)
        let entry = try SkillFileCatalog.materializeBytes(
            skillUUID: pageId,
            fileName: "logo.png",
            data: bytes,
            kind: "notion_hosted",
            notionFileId: "file-abc"
        )
        let uuid = CachedSkillBody.canonicalUUID(pageId)
        try expect(entry.localPath?.contains("/skill-files/\(uuid)/logo.png") == true,
                   "localPath should be skill-files/<uuid>/logo.png, got \(String(describing: entry.localPath))")
        let path = entry.localPath!
        try expect(FileManager.default.fileExists(atPath: path), "file_read can open the cache file")
        try expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes, "bytes round-trip")
        try expect(entry.sha256 == SkillFileCatalog.sha256Hex(bytes))
        try expect(entry.kind == "notion_hosted")
        try expect(entry.notionFileId == "file-abc")
    }

    await test("#254: fetch_skill envelope surfaces localPath after materialize") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-skillfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        _ = try SkillFileCatalog.materializeBytes(
            skillUUID: pageId,
            fileName: "logo.png",
            data: Data("png".utf8)
        )
        let result = await build(props: [
            "Files & media": filesProp([
                ["name": "logo.png", "type": "file", "id": "file-abc",
                 "file": ["url": "https://s3.example/logo.png"]]
            ])
        ], pageId: pageId)
        let files = try filesArray(result)
        guard case .object(let f) = files[0] else {
            throw TestError.assertion("expected object")
        }
        guard case .string(let local)? = f["localPath"] else {
            throw TestError.assertion("localPath should populate from the cache")
        }
        try expect(local.hasSuffix("/logo.png"), "got \(local)")
        try expect(f["sha256"] != nil, "sha256 present once materialized")
    }

    await test("#254: materializeBytes stays inside the skill-files cache on ugly names") {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-skillfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        let entry = try SkillFileCatalog.materializeBytes(
            skillUUID: pageId,
            fileName: "../../etc/passwd",
            data: Data("x".utf8)
        )
        let cacheRoot = try BridgePaths.ensureApplicationSupport(.skillFiles)
            .resolvingSymlinksInPath().path
        let dest = URL(fileURLWithPath: entry.localPath!).resolvingSymlinksInPath().path
        try expect(dest.hasPrefix(cacheRoot), "must not escape \(cacheRoot); got \(dest)")
        try expect(entry.name == "passwd", "lastPathComponent is the stored name")
        try expect(!FileManager.default.fileExists(atPath: "/etc/passwd") || entry.localPath != "/etc/passwd",
                   "must not write the host passwd path")
    }

    await test("#254: materializeBytes rejects '.' / '..' names") {
        for name in [".", ".."] {
            do {
                _ = try SkillFileCatalog.materializeBytes(skillUUID: pageId, fileName: name, data: Data("x".utf8))
                throw TestError.assertion("expected invalidFileName for \(name)")
            } catch let error as SkillFileMaterializeError {
                guard case .invalidFileName = error else {
                    throw TestError.assertion("expected invalidFileName, got \(error)")
                }
            }
        }
    }

    await test("#254: materialize requires https Notion-hosted URL") {
        let http = SkillFileEntry(
            name: "x.bin", kind: "notion_hosted", downloadURL: "http://example.com/x.bin"
        )
        do {
            _ = try await SkillFileCatalog.materialize(skillUUID: pageId, entry: http) { _ in Data("x".utf8) }
            throw TestError.assertion("http must fail closed")
        } catch let error as SkillFileMaterializeError {
            guard case .notHTTPS = error else {
                throw TestError.assertion("expected notHTTPS, got \(error)")
            }
        }
        let drive = SkillFileEntry(
            name: "kit", kind: "google_drive", downloadURL: nil
        )
        do {
            _ = try await SkillFileCatalog.materialize(skillUUID: pageId, entry: drive) { _ in Data("x".utf8) }
            throw TestError.assertion("Drive/external without a URL must not pretend to materialize")
        } catch let error as SkillFileMaterializeError {
            guard case .missingDownloadURL = error else {
                throw TestError.assertion("expected missingDownloadURL, got \(error)")
            }
        }
        let hosted = SkillFileEntry(
            name: "logo.png", kind: "notion_hosted",
            notionFileId: "file-abc",
            downloadURL: "https://s3.example/logo.png"
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-skillfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        BridgePaths.overrideHomeForTesting(tmp)
        defer {
            BridgePaths.overrideHomeForTesting(nil)
            try? FileManager.default.removeItem(at: tmp)
        }
        nonisolated(unsafe) var downloadedHTTPS = false
        let got = try await SkillFileCatalog.materialize(skillUUID: pageId, entry: hosted) { url in
            downloadedHTTPS = url.scheme == "https"
            return Data("png-bytes".utf8)
        }
        try expect(downloadedHTTPS, "download URL must be https")
        try expect(got.localPath != nil)
        try expect(got.sha256 == SkillFileCatalog.sha256Hex(Data("png-bytes".utf8)))
    }

    await test("#254: findEntry matches notionFileId then fileName") {
        let catalog = SkillFileCatalogResult(files: [
            SkillFileEntry(name: "logo.png", kind: "notion_hosted", notionFileId: "file-abc"),
            SkillFileEntry(name: "headshot.jpg", kind: "notion_hosted", notionFileId: "file-def")
        ], propertyPresent: true)
        try expect(SkillFileCatalog.findEntry(in: catalog, fileName: nil, notionFileId: "file-def")?.name == "headshot.jpg")
        try expect(SkillFileCatalog.findEntry(in: catalog, fileName: "logo.png", notionFileId: nil)?.name == "logo.png")
        try expect(SkillFileCatalog.findEntry(in: catalog, fileName: "nope", notionFileId: nil) == nil)
    }

    let gate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await SkillsModule.register(on: router)

    await test("#254: skill_materialize_file rejects missing identity before Notion") {
        do {
            _ = try await router.dispatch(
                toolName: "skill_materialize_file",
                arguments: .object(["fileName": .string("logo.png")])
            )
            throw TestError.assertion("expected invalidArguments")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("#254: skill_materialize_file rejects missing file selector before Notion") {
        do {
            _ = try await router.dispatch(
                toolName: "skill_materialize_file",
                arguments: .object(["name": .string("brand-manager")])
            )
            throw TestError.assertion("expected invalidArguments")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("#254: skill_materialize_file unknown skill is a structured miss (not Notion)") {
        let result = try await router.dispatch(
            toolName: "skill_materialize_file",
            arguments: .object([
                "name": .string("definitely-not-a-configured-skill-\(UUID().uuidString)"),
                "fileName": .string("logo.png")
            ])
        )
        guard case .object(let o) = result, case .string(let err)? = o["error"] else {
            throw TestError.assertion("expected structured not-found, got \(result)")
        }
        try expect(err.contains("not found") || err.contains("Skill"), "got \(err)")
    }
}
