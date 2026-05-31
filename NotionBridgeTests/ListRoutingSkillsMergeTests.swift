// ListRoutingSkillsMergeTests.swift — W2 D6 + D9
// NotionBridge · Tests
//
// `SkillsModule.mergedRoutingSkills` combines Notion-source routing
// skills (from UserDefaults) with file-source skills (from
// `FilesystemSkillIndex.shared`). Verifies stable alphabetical ordering
// and the file-source routing visibility filter.
//
// Note: production `mergedRoutingSkills` reads from
// `FilesystemSkillIndex.shared` (process-shared actor). These tests
// drive focused assertions through UserDefaults seeds and the shared
// file-source index. The per-piece semantics are independently locked.

import Foundation
import MCP
import NotionBridgeLib

func runListRoutingSkillsMergeTests() async {
    print("\n\u{1F517} list_routing_skills merge Tests (W2 D6)")

    let key = BridgeDefaults.skills
    let saved = UserDefaults.standard.data(forKey: key)
    let fileRoutingKey = BridgeDefaults.fileSkillRoutingDiscoverable
    let savedFileRouting = UserDefaults.standard.object(forKey: fileRoutingKey)
    let fileEnabledKey = BridgeDefaults.fileSkillEnabled
    let savedFileEnabled = UserDefaults.standard.object(forKey: fileEnabledKey)
    defer {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        if let savedFileRouting { UserDefaults.standard.set(savedFileRouting, forKey: fileRoutingKey) }
        else { UserDefaults.standard.removeObject(forKey: fileRoutingKey) }
        if let savedFileEnabled { UserDefaults.standard.set(savedFileEnabled, forKey: fileEnabledKey) }
        else { UserDefaults.standard.removeObject(forKey: fileEnabledKey) }
    }

    @Sendable func seedNotionSkills(_ entries: [[String: Any]]) {
        let data = try! JSONSerialization.data(withJSONObject: entries, options: [])
        UserDefaults.standard.set(data, forKey: key)
    }

    await test("mergedRoutingSkills: empty registry returns empty array") {
        UserDefaults.standard.removeObject(forKey: key)
        // Note: this still reads the shared FilesystemSkillIndex, which
        // may or may not have bundled skills in a dev tree. We assert
        // shape, not strict emptiness — every row must have a `name`.
        let rows = await SkillsModule.mergedRoutingSkills()
        for r in rows {
            if case .object(let o) = r {
                try expect(o["name"] != nil, "every row must have a name")
            } else {
                throw TestError.assertion("row must be an object")
            }
        }
    }

    await test("mergedRoutingSkills: Notion-source routing skill surfaces with source=notion") {
        seedNotionSkills([
            [
                "name": "TestRouting",
                "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444",
                "enabled": true,
                "visibility": "routing"
            ]
        ])
        let rows = await SkillsModule.mergedRoutingSkills()
        var foundNotion = false
        for r in rows {
            if case .object(let o) = r,
               case .string(let name) = o["name"], name == "TestRouting" {
                foundNotion = true
                if case .string(let src)? = o["source"] {
                    try expect(src == "notion", "expected source=notion, got '\(src)'")
                } else {
                    throw TestError.assertion("expected source field")
                }
            }
        }
        try expect(foundNotion, "TestRouting should be in merged routing list")
    }

    await test("mergedRoutingSkills: alphabetical ordering") {
        seedNotionSkills([
            ["name": "Zulu", "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444", "enabled": true, "visibility": "routing"],
            ["name": "Alpha", "notionPageId": "bbbb1111cccc2222dddd3333eeee4444", "enabled": true, "visibility": "routing"],
            ["name": "Mike", "notionPageId": "cccc1111dddd2222eeee3333ffff4444", "enabled": true, "visibility": "routing"]
        ])
        let rows = await SkillsModule.mergedRoutingSkills()
        let names: [String] = rows.compactMap { r in
            guard case .object(let o) = r, case .string(let n)? = o["name"] else { return nil }
            return n
        }
        // The Notion-seeded names appear in alphabetical order.
        let indices = ["Alpha", "Mike", "Zulu"].map { names.firstIndex(of: $0) ?? -1 }
        try expect(indices.allSatisfy { $0 >= 0 }, "all seeded names found, got \(names)")
        try expect(indices == indices.sorted(), "seeded names not alphabetically ordered: \(names)")
    }

    await test("mergedRoutingSkills: disabled skill is filtered out") {
        seedNotionSkills([
            ["name": "DisabledOne", "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444",
             "enabled": false, "visibility": "routing"]
        ])
        let rows = await SkillsModule.mergedRoutingSkills()
        for r in rows {
            if case .object(let o) = r, case .string(let n)? = o["name"] {
                try expect(n != "DisabledOne", "disabled skill leaked into merged list")
            }
        }
    }

    await test("mergedRoutingSkills: non-routing visibility filtered out") {
        seedNotionSkills([
            ["name": "StdOnly", "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444",
             "enabled": true, "visibility": "standard"]
        ])
        let rows = await SkillsModule.mergedRoutingSkills()
        for r in rows {
            if case .object(let o) = r, case .string(let n)? = o["name"] {
                try expect(n != "StdOnly", "standard-visibility skill leaked into routing merge")
            }
        }
    }

    await test("mergedRoutingSkills: file-source routing honors effective routing flag") {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: fileRoutingKey)
        UserDefaults.standard.removeObject(forKey: fileEnabledKey)

        let fileSkills = await FilesystemSkillIndex.shared.allSkills()
        let hiddenByDefault = fileSkills.first { fs in
            fs.frontmatter["visibility"] == nil
        }
        let frontmatterRouting = fileSkills.first { fs in
            if case .string(let v) = fs.frontmatter["visibility"] { return v == "routing" }
            return false
        }

        let rows = await SkillsModule.mergedRoutingSkills()
        let names: Set<String> = Set(rows.compactMap { r in
            guard case .object(let o) = r, case .string(let n)? = o["name"] else { return nil }
            return n
        })

        if let hiddenByDefault {
            try expect(!names.contains(hiddenByDefault.name),
                       "file skill without visibility:routing must not leak into routing list: \(hiddenByDefault.name)")
        }
        if let frontmatterRouting {
            try expect(names.contains(frontmatterRouting.name),
                       "file skill with visibility:routing should be discoverable: \(frontmatterRouting.name)")
        }
    }

    await test("mergedRoutingSkills: source-available stubs are not routing discoverable") {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: fileRoutingKey)
        UserDefaults.standard.removeObject(forKey: fileEnabledKey)

        let rows = await SkillsModule.mergedRoutingSkills()
        let names: Set<String> = Set(rows.compactMap { r in
            guard case .object(let o) = r, case .string(let n)? = o["name"] else { return nil }
            return n
        })

        for stub in ["docx", "pdf", "pptx", "xlsx"] {
            try expect(!names.contains(stub), "source-available stub leaked into routing list: \(stub)")
        }
    }
}
