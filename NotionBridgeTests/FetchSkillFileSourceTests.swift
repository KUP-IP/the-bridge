// FetchSkillFileSourceTests.swift — W2 D5 + D9
// NotionBridge · Tests
//
// `SkillsModule.buildFileSkillResult` envelope shape for file-source
// SKILL.md skills. Covers:
//   • content = markdown body
//   • properties = frontmatter map
//   • title / url / blockCount / truncated / summary populate per D5
//   • empty frontmatter degrades cleanly
//   • triggers / anti_triggers surface from frontmatter

import Foundation
import MCP
import NotionBridgeLib

func runFetchSkillFileSourceTests() async {
    print("\n\u{1F4D6} fetch_skill (file source) Tests (W2 D5)")

    func makeParsedSkill(name: String, frontmatter: [String: FrontmatterValue], body: String) -> ParsedSkill {
        ParsedSkill(
            name: name,
            path: URL(fileURLWithPath: "/tmp/nb-test-skills/\(name)/SKILL.md"),
            isUserSource: false,
            frontmatter: frontmatter,
            body: body,
            displayPath: "bundled/\(name)/SKILL.md"
        )
    }

    await test("buildFileSkillResult: envelope shape contains all D5 keys") {
        let parsed = makeParsedSkill(
            name: "alpha",
            frontmatter: [
                "name": .string("alpha"),
                "description": .string("A test skill"),
                "triggers": .array(["foo", "bar"]),
                "anti_triggers": .array(["never"])
            ],
            body: "# Hello\n\nThis is the body."
        )
        let env = await SkillsModule.buildFileSkillResult(parsed)
        guard case .object(let o) = env else {
            throw TestError.assertion("expected object envelope")
        }
        // Required keys
        for key in ["name", "title", "url", "blockCount", "truncated",
                    "content", "summary", "triggerPhrases", "antiTriggerPhrases",
                    "properties", "source"] {
            try expect(o[key] != nil, "envelope missing key '\(key)': \(o.keys.sorted())")
        }
        // Source discriminator
        if case .string(let s) = o["source"] {
            try expect(s == "file", "source should be 'file', got '\(s)'")
        } else {
            throw TestError.assertion("source not a string")
        }
    }

    await test("buildFileSkillResult: content equals markdown body") {
        let body = "# Hello\n\nworld"
        let parsed = makeParsedSkill(name: "x", frontmatter: ["name": .string("x")], body: body)
        let env = await SkillsModule.buildFileSkillResult(parsed)
        guard case .object(let o) = env, case .string(let c)? = o["content"] else {
            throw TestError.assertion("expected content")
        }
        try expect(c == body, "content must be verbatim body, got '\(c)'")
    }

    await test("buildFileSkillResult: properties is the frontmatter map") {
        let parsed = makeParsedSkill(
            name: "props",
            frontmatter: [
                "active": .bool(true),
                "triggers": .array(["a", "b"]),
                "description": .string("hi")
            ],
            body: "body"
        )
        let env = await SkillsModule.buildFileSkillResult(parsed)
        guard case .object(let o) = env, case .object(let props)? = o["properties"] else {
            throw TestError.assertion("expected properties object")
        }
        try expect(props["active"] != nil, "props should carry 'active'")
        try expect(props["triggers"] != nil, "props should carry 'triggers'")
        if case .bool(let b)? = props["active"] { try expect(b == true) }
        if case .array(let arr)? = props["triggers"] {
            // Strings inside; just verify count
            try expect(arr.count == 2)
        } else {
            throw TestError.assertion("triggers should be array")
        }
    }

    await test("buildFileSkillResult: title prefers frontmatter 'title' > 'name' > directory name") {
        let p1 = makeParsedSkill(name: "alpha",
                                 frontmatter: ["title": .string("Alpha Skill")],
                                 body: "")
        let env1 = await SkillsModule.buildFileSkillResult(p1)
        guard case .object(let o1) = env1, case .string(let t1)? = o1["title"] else {
            throw TestError.assertion("expected title")
        }
        try expect(t1 == "Alpha Skill", "got '\(t1)'")

        let p2 = makeParsedSkill(name: "beta",
                                 frontmatter: ["name": .string("Beta Skill")],
                                 body: "")
        let env2 = await SkillsModule.buildFileSkillResult(p2)
        guard case .object(let o2) = env2, case .string(let t2)? = o2["title"] else {
            throw TestError.assertion("expected title")
        }
        try expect(t2 == "Beta Skill", "got '\(t2)'")

        let p3 = makeParsedSkill(name: "gamma", frontmatter: [:], body: "")
        let env3 = await SkillsModule.buildFileSkillResult(p3)
        guard case .object(let o3) = env3, case .string(let t3)? = o3["title"] else {
            throw TestError.assertion("expected title")
        }
        try expect(t3 == "gamma", "got '\(t3)'")
    }

    await test("buildFileSkillResult: summary = description, else first 200 chars of body") {
        let bodyLong = String(repeating: "abc ", count: 100) // ~400 chars
        let p1 = makeParsedSkill(name: "x", frontmatter: ["description": .string("explicit")], body: bodyLong)
        let env1 = await SkillsModule.buildFileSkillResult(p1)
        if case .object(let o) = env1, case .string(let s)? = o["summary"] {
            try expect(s == "explicit", "got '\(s)'")
        } else {
            throw TestError.assertion("expected summary")
        }
        let p2 = makeParsedSkill(name: "y", frontmatter: [:], body: bodyLong)
        let env2 = await SkillsModule.buildFileSkillResult(p2)
        if case .object(let o) = env2, case .string(let s)? = o["summary"] {
            try expect(s.count <= 200, "summary must cap at 200 chars, got \(s.count)")
        } else {
            throw TestError.assertion("expected summary")
        }
    }

    await test("buildFileSkillResult: empty frontmatter degrades cleanly") {
        let p = makeParsedSkill(name: "bare", frontmatter: [:], body: "hi")
        let env = await SkillsModule.buildFileSkillResult(p)
        guard case .object(let o) = env, case .object(let props)? = o["properties"] else {
            throw TestError.assertion("expected envelope")
        }
        try expect(props.isEmpty, "empty frontmatter → empty properties")
        if case .array(let trig)? = o["triggerPhrases"] {
            try expect(trig.isEmpty)
        }
    }

    await test("buildFileSkillResult: url is a file:// URL") {
        let p = makeParsedSkill(name: "u", frontmatter: [:], body: "")
        let env = await SkillsModule.buildFileSkillResult(p)
        guard case .object(let o) = env, case .string(let u)? = o["url"] else {
            throw TestError.assertion("expected url")
        }
        try expect(u.hasPrefix("file://"), "expected file:// url, got '\(u)'")
    }
}
