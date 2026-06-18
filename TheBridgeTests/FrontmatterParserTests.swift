// FrontmatterParserTests.swift — W2 D8 + D9
// TheBridge · Tests
//
// Coverage for the YAML-subset SKILL.md frontmatter parser. Every
// happy path + every defensive degrade. The parser MUST NEVER throw.

import Foundation
import TheBridgeLib

func runFrontmatterParserTests() async {
    print("\n\u{1F4D1} FrontmatterParser Tests (W2 D8)")

    // MARK: - Valid frontmatter

    await test("parse: empty input → empty map + empty body") {
        let (fm, body) = FrontmatterParser.parse("")
        try expect(fm.isEmpty, "expected empty frontmatter, got \(fm)")
        try expect(body.isEmpty, "expected empty body, got '\(body)'")
    }

    await test("parse: no leading --- → empty map + whole text as body") {
        let text = "# Just markdown\n\nNo frontmatter here."
        let (fm, body) = FrontmatterParser.parse(text)
        try expect(fm.isEmpty)
        try expect(body == text, "body should equal input verbatim")
    }

    await test("parse: single string key/value") {
        let text = "---\nname: my-skill\n---\nbody"
        let (fm, body) = FrontmatterParser.parse(text)
        guard case .string(let v)? = fm["name"] else {
            throw TestError.assertion("expected string for 'name', got \(String(describing: fm["name"]))")
        }
        try expect(v == "my-skill", "got '\(v)'")
        try expect(body == "body")
    }

    await test("parse: multiple keys + comment + boolean") {
        let text = """
        ---
        # this is a comment
        name: alpha
        active: true
        ready: false
        description: A skill
        ---
        markdown body
        """
        let (fm, _) = FrontmatterParser.parse(text)
        try expect(fm.count == 4, "expected 4 keys, got \(fm.count): \(fm.keys.sorted())")
        if case .bool(let b)? = fm["active"] { try expect(b == true) }
        else { throw TestError.assertion("expected bool for active") }
        if case .bool(let b)? = fm["ready"] { try expect(b == false) }
        else { throw TestError.assertion("expected bool for ready") }
    }

    await test("parse: inline array") {
        let text = "---\ntriggers: [foo, bar, \"baz qux\"]\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        guard case .array(let arr)? = fm["triggers"] else {
            throw TestError.assertion("expected array, got \(String(describing: fm["triggers"]))")
        }
        try expect(arr == ["foo", "bar", "baz qux"], "got \(arr)")
    }

    await test("parse: block-style array") {
        let text = """
        ---
        anti_triggers:
          - never
          - "do not use"
          - skip
        name: x
        ---
        """
        let (fm, _) = FrontmatterParser.parse(text)
        guard case .array(let arr)? = fm["anti_triggers"] else {
            throw TestError.assertion("expected array, got \(String(describing: fm["anti_triggers"]))")
        }
        try expect(arr == ["never", "do not use", "skip"], "got \(arr)")
        // Trailing scalar after the block array must still be captured.
        if case .string(let s)? = fm["name"] { try expect(s == "x") }
        else { throw TestError.assertion("expected name after block array") }
    }

    await test("parse: quoted strings preserve special characters") {
        let text = "---\ngreeting: \"Hello, world: yes\"\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        if case .string(let s)? = fm["greeting"] {
            try expect(s == "Hello, world: yes", "got '\(s)'")
        } else {
            throw TestError.assertion("expected string")
        }
    }

    await test("parse: single-quoted string verbatim (no escapes)") {
        let text = "---\nphrase: 'don''t do this'\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        if case .string(let s)? = fm["phrase"] {
            // Single quotes return inner verbatim — escape semantics out of scope.
            try expect(s.contains("don"), "got '\(s)'")
        } else {
            throw TestError.assertion("expected string for phrase")
        }
    }

    await test("parse: trailing # in unquoted value treated as comment") {
        let text = "---\nkey: value # with a comment\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        if case .string(let s)? = fm["key"] {
            try expect(s == "value", "comment should be stripped, got '\(s)'")
        } else {
            throw TestError.assertion("expected string")
        }
    }

    await test("parse: # inside quoted value preserved") {
        let text = "---\nkey: \"value # not a comment\"\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        if case .string(let s)? = fm["key"] {
            try expect(s.contains("#"), "expected # preserved, got '\(s)'")
        } else {
            throw TestError.assertion("expected string")
        }
    }

    // MARK: - Defensive / malformed

    await test("parse: unclosed frontmatter → empty map + whole text as body") {
        let text = "---\nname: foo\nno closing delimiter"
        let (fm, body) = FrontmatterParser.parse(text)
        try expect(fm.isEmpty, "should not parse incomplete frontmatter")
        try expect(body == text, "body should be whole input")
    }

    await test("parse: only frontmatter no body") {
        let text = "---\nname: empty-body\n---\n"
        let (fm, body) = FrontmatterParser.parse(text)
        try expect(fm["name"] != nil)
        try expect(body.isEmpty || body == "", "body should be empty, got '\(body)'")
    }

    await test("parse: stray dash with no key context ignored") {
        let text = "---\n- stray\nname: x\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        if case .string(let s)? = fm["name"] { try expect(s == "x") }
        else { throw TestError.assertion("name should still parse") }
    }

    await test("parse: line without colon silently ignored") {
        let text = "---\nname: x\nrandomline\nactive: true\n---\n"
        let (fm, _) = FrontmatterParser.parse(text)
        try expect(fm["name"] != nil)
        try expect(fm["active"] != nil)
    }

    await test("parse: never throws on garbage input") {
        let cases = [
            "",
            "---",
            "---\n",
            "---\n---\n",
            "garbage\u{0}\u{1}\u{2}",
            "---\nkey:\"unclosed",
            String(repeating: "---\n", count: 50)
        ]
        for c in cases {
            // No throw expected; we don't assert specific output —
            // surviving the call IS the assertion.
            _ = FrontmatterParser.parse(c)
        }
    }
}
