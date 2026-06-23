// SkillSourceTests.swift — W2 D2 + D9
// TheBridge · Tests
//
// SkillSource Codable round-trip + legacy `notionPageId` backward
// compat. A legacy UserDefaults blob (the wire format from every prior
// release) MUST decode cleanly to `.notion(pageId:)`. Re-encoding then
// re-decoding the modern blob is a stable fixed point.

import Foundation
import TheBridgeLib

func runSkillSourceTests() async {
    print("\n\u{1F4E6} SkillSource Tests (W2 D2)")

    await test("SkillSource: Codable round-trip — notion case") {
        let s = SkillSource.notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SkillSource.self, from: data)
        try expect(back == s, "round-trip mismatch: \(back) vs \(s)")
    }

    await test("SkillSource: Codable round-trip — file case") {
        let url = URL(fileURLWithPath: "/tmp/test-skill/SKILL.md")
        let s = SkillSource.file(path: url)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SkillSource.self, from: data)
        try expect(back == s, "round-trip mismatch: \(back) vs \(s)")
    }

    await test("SkillSource: unknown discriminator → safe fallback (.notion empty)") {
        let json = #"{"kind":"unknownXYZ","junk":"data"}"#.data(using: .utf8)!
        let back = try JSONDecoder().decode(SkillSource.self, from: json)
        if case .notion(let pid) = back {
            try expect(pid.isEmpty, "expected empty pageId, got '\(pid)'")
        } else {
            throw TestError.assertion("expected .notion fallback, got \(back)")
        }
    }

    await test("Skill: legacy notionPageId blob decodes as .notion source") {
        // The wire format from every release prior to W2 — top-level
        // `notionPageId` field, no `source` discriminator.
        let json = """
        {
          "name": "LegacySkill",
          "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444",
          "enabled": true,
          "visibility": "standard",
          "summary": "",
          "triggerPhrases": [],
          "antiTriggerPhrases": [],
          "platform": "notion"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(SkillsManager.Skill.self, from: json)
        try expect(s.name == "LegacySkill")
        if case .notion(let pid) = s.source {
            try expect(pid == "aaaa1111bbbb2222cccc3333dddd4444", "got '\(pid)'")
        } else {
            throw TestError.assertion("expected .notion source, got \(s.source)")
        }
        try expect(s.notionPageId == "aaaa1111bbbb2222cccc3333dddd4444",
                   "legacy accessor must surface the page id")
    }

    await test("Skill: re-encoding a legacy blob writes the new source shape") {
        let json = """
        {
          "name": "x",
          "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444",
          "enabled": true,
          "visibility": "standard",
          "summary": "",
          "triggerPhrases": [],
          "antiTriggerPhrases": [],
          "platform": "notion"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(SkillsManager.Skill.self, from: json)
        let reEncoded = try JSONEncoder().encode(s)
        let raw = String(data: reEncoded, encoding: .utf8) ?? ""
        try expect(raw.contains("\"source\""), "modern shape must include 'source' field; got \(raw)")
        // Forward-compat mirror — the legacy field is also written.
        try expect(raw.contains("\"notionPageId\""), "must also mirror legacy 'notionPageId' field for forward compat")
    }

    await test("Skill: round-trip of modern blob is a stable fixed point") {
        let s = SkillsManager.Skill(
            name: "stable",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            visibility: .command
        )
        let data1 = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(SkillsManager.Skill.self, from: data1)
        let data2 = try JSONEncoder().encode(decoded)
        // Either byte-identical OR semantically equal.
        let back = try JSONDecoder().decode(SkillsManager.Skill.self, from: data2)
        try expect(decoded == back, "fixed point lost: \(decoded) vs \(back)")
    }

    await test("Skill: file-source round-trip") {
        let path = URL(fileURLWithPath: "/var/tmp/nb-test-skill/SKILL.md")
        let s = SkillsManager.Skill(name: "fs", source: .file(path: path), visibility: .routing)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SkillsManager.Skill.self, from: data)
        try expect(back.name == "fs")
        if case .file(let p) = back.source {
            try expect(p == path, "got \(p) vs \(path)")
        } else {
            throw TestError.assertion("expected .file source, got \(back.source)")
        }
        try expect(back.notionPageId.isEmpty, "file-source should have empty notionPageId")
    }

    await test("Skill: source.notionPageIdOrEmpty and isFile helpers") {
        let n = SkillSource.notion(pageId: "abc")
        try expect(n.notionPageIdOrEmpty == "abc")
        try expect(n.isFile == false)
        let f = SkillSource.file(path: URL(fileURLWithPath: "/x"))
        try expect(f.notionPageIdOrEmpty.isEmpty)
        try expect(f.isFile == true)
    }
}
