// FilesystemSkillIndexTests.swift — W2 D3 + D9
// NotionBridge · Tests
//
// Drive the actor against a fixture tmpdir. Verifies:
//   • init-time scan + lookup
//   • frontmatter + body parsing pass-through
//   • user-dir overrides bundled (collision precedence)
//   • TTL re-scan after >cacheTTL (we don't wait 60s; we test the
//     reindex() entry point that the watcher uses anyway — the TTL
//     floor is just a defensive backstop with the SAME re-scan path)
//   • missing user dir does NOT crash
//   • watcher-driven re-scan on filesystem change is covered by direct
//     reindex() (the watcher path is just a Dispatch wrapper around it)

import Foundation
import NotionBridgeLib

func runFilesystemSkillIndexTests() async {
    print("\n\u{1F4C2} FilesystemSkillIndex Tests (W2 D3)")

    func makeTmpDir(_ tag: String) -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("nb-fsidx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeSkill(_ root: URL, name: String, frontmatter: String, body: String) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = "---\n\(frontmatter)\n---\n\(body)"
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    await test("FilesystemSkillIndex: empty roots → no skills, no crash") {
        let bundled = makeTmpDir("empty-b")
        let user = makeTmpDir("empty-u")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let all = await idx.allSkills()
        try expect(all.isEmpty, "expected no skills, got \(all.count)")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }

    await test("FilesystemSkillIndex: missing user dir does not crash") {
        let bundled = makeTmpDir("nu-b")
        // user dir intentionally points at a path that does NOT exist.
        let user = URL.temporaryDirectory.appendingPathComponent("nb-fsidx-missing-\(UUID().uuidString)")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let all = await idx.allSkills()
        try expect(all.isEmpty)
        defer { try? FileManager.default.removeItem(at: bundled) }
    }

    await test("FilesystemSkillIndex: indexes a single SKILL.md") {
        let bundled = makeTmpDir("one-b")
        let user = makeTmpDir("one-u")
        try writeSkill(bundled, name: "alpha",
                       frontmatter: "name: alpha\ndescription: First skill",
                       body: "# Hello\n\nworld")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let one = await idx.skill(named: "alpha")
        guard let one else { throw TestError.assertion("expected 'alpha'") }
        try expect(one.name == "alpha")
        try expect(one.body.contains("Hello"), "body should pass through")
        try expect(one.isUserSource == false, "bundled source")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }

    await test("FilesystemSkillIndex: user dir overrides bundled (same name → user wins)") {
        let bundled = makeTmpDir("col-b")
        let user = makeTmpDir("col-u")
        try writeSkill(bundled, name: "same",
                       frontmatter: "name: same\ndescription: bundled version",
                       body: "BUNDLED BODY")
        try writeSkill(user, name: "same",
                       frontmatter: "name: same\ndescription: user override",
                       body: "USER BODY")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let resolved = await idx.skill(named: "same")
        guard let resolved else { throw TestError.assertion("expected 'same'") }
        try expect(resolved.isUserSource == true, "user dir must win on collision")
        try expect(resolved.body.contains("USER BODY"), "user body must be returned")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }

    await test("FilesystemSkillIndex: reindex() picks up newly-written files") {
        let bundled = makeTmpDir("re-b")
        let user = makeTmpDir("re-u")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)

        // Before: nothing.
        let empty = await idx.allSkills()
        try expect(empty.isEmpty)

        // Write a skill into the user dir AFTER first scan.
        try writeSkill(user, name: "fresh",
                       frontmatter: "name: fresh",
                       body: "body")
        await idx.reindex()
        let after = await idx.skill(named: "fresh")
        try expect(after != nil, "reindex() should surface the new skill")
        try expect(after?.isUserSource == true)
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }

    await test("FilesystemSkillIndex: stable alphabetical ordering in allSkills()") {
        let bundled = makeTmpDir("ord-b")
        let user = makeTmpDir("ord-u")
        try writeSkill(bundled, name: "beta", frontmatter: "name: beta", body: "")
        try writeSkill(bundled, name: "alpha", frontmatter: "name: alpha", body: "")
        try writeSkill(bundled, name: "gamma", frontmatter: "name: gamma", body: "")
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let all = await idx.allSkills()
        let names = all.map(\.name)
        try expect(names == ["alpha", "beta", "gamma"], "expected alphabetical, got \(names)")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }

    await test("FilesystemSkillIndex: STUB.md is indexed when SKILL.md absent") {
        let bundled = makeTmpDir("stub-b")
        let user = makeTmpDir("stub-u")
        let stubDir = bundled.appendingPathComponent("docx", isDirectory: true)
        try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let text = "---\nname: docx\ndescription: linked-only\n---\nSee upstream."
        try text.write(to: stubDir.appendingPathComponent("STUB.md"), atomically: true, encoding: .utf8)
        let idx = FilesystemSkillIndex(bundledDir: bundled, userDir: user)
        let one = await idx.skill(named: "docx")
        try expect(one != nil, "STUB.md should be indexed when SKILL.md is absent")
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: user)
        }
    }
}
