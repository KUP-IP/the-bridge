// FetchSkillMarkdownTests.swift — cmd-w4 (fetch_skill /markdown switch)
// TheBridge · Tests
//
// Synthetic-fixture matrix for the cmd-w4 behavior change: fetch_skill's
// body retrieval moved from a depth-first block walk + extractPlainText
// join to the server `/markdown` render run through the shared cmd-w2
// MentionResolver. ZERO network / ZERO live Notion — every input is a
// recorded `/markdown` JSON (or raw markdown) string and every
// <mention-page> title lookup is an injected closure.
//
// Coverage:
//   (a) structure fidelity — headings / list / code-fence / table
//       survive the new path, whereas the OLD extractPlainText-style
//       join (reconstructed here as the documented prior behavior)
//       flattened them;
//   (b) before/after on a body with a <mention-page> → now [Title](url);
//   (c) unresolved mention → [link](url), never dropped;
//   (d) envelope-shape unchanged (same keys/value-types as the prior
//       fetch_skill result);
//   (e) empty / odd-body safety (no crash, stable envelope).

import Foundation
import MCP
import TheBridgeLib

func runFetchSkillMarkdownTests() async {
    print("\n\u{1F4DF} FetchSkillMarkdown Tests (cmd-w4 · /markdown + MentionResolver)")

    // ── synthetic /markdown JSON envelope helper ─────────────────────
    func mdJSON(_ markdown: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: ["markdown": markdown], options: []
        )
        return String(data: data, encoding: .utf8)!
    }

    // The OLD body shape: collectBlocksDepthFirst → per-block
    // extractPlainText → joined("\n"). For a structured doc this dropped
    // markdown syntax (heading #, list -, code fences, table pipes were
    // never present in plain_text). We model the pre-cmd-w4 plain-text
    // projection for the structure-fidelity contrast assertions.
    func legacyPlainTextProjection(headings: [String], listItems: [String],
                                   codeLines: [String], tableCells: [String]) -> String {
        var parts: [String] = []
        parts.append(contentsOf: headings)        // no leading '#'
        parts.append(contentsOf: listItems)       // no leading '- '
        parts.append(contentsOf: codeLines)       // no ``` fence
        parts.append(tableCells.joined(separator: " "))  // no | pipes
        return parts.joined(separator: "\n")
    }

    func contentString(_ v: Value) -> String? {
        guard case .object(let o) = v, case .string(let s)? = o["content"] else { return nil }
        return s
    }

    // ============================================================
    // MARK: (a) structure fidelity — markdown survives vs. legacy join
    // ============================================================

    let structuredMD = """
    # Skill Title

    Intro paragraph.

    ## Steps

    - first item
    - second item

    ```swift
    let x = 1
    print(x)
    ```

    | Col A | Col B |
    | ----- | ----- |
    | a1    | b1    |
    """

    await test("cmd-w4 (a): heading markers survive the /markdown path") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(structuredMD)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("# Skill Title"), "lost H1; got: \(c)")
        try expect(c.contains("## Steps"), "lost H2; got: \(c)")
    }

    await test("cmd-w4 (a): list bullets survive the /markdown path") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(structuredMD)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("- first item"), "lost list marker; got: \(c)")
        try expect(c.contains("- second item"), "lost list marker; got: \(c)")
    }

    await test("cmd-w4 (a): code fence survives the /markdown path") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(structuredMD)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("```swift"), "lost code fence; got: \(c)")
        try expect(c.contains("let x = 1"), "lost code body; got: \(c)")
    }

    await test("cmd-w4 (a): table pipes survive the /markdown path") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(structuredMD)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("| Col A | Col B |"), "lost table; got: \(c)")
        try expect(c.contains("| a1"), "lost table row; got: \(c)")
    }

    await test("cmd-w4 (a): structure GAIN vs. the legacy plain-text join") {
        // The legacy projection dropped every markdown marker; the new
        // path keeps them all. Assert the delta is real, not vacuous.
        let legacy = legacyPlainTextProjection(
            headings: ["Skill Title", "Steps"],
            listItems: ["first item", "second item"],
            codeLines: ["let x = 1", "print(x)"],
            tableCells: ["Col A", "Col B"]
        )
        try expect(!legacy.contains("#"), "legacy model wrong (had '#')")
        try expect(!legacy.contains("- first item"), "legacy model wrong (had bullet)")
        try expect(!legacy.contains("```"), "legacy model wrong (had fence)")
        try expect(!legacy.contains("|"), "legacy model wrong (had pipe)")

        let r = await SkillsModule.buildSkillResultForTesting(
            name: "demo", title: "Demo", url: "https://www.notion.so/p1",
            markdownJSONOrText: mdJSON(structuredMD)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("#") && c.contains("- first item")
                   && c.contains("```") && c.contains("|"),
                   "new path must preserve structure the legacy join lost; got: \(c)")
    }

    // ============================================================
    // MARK: (b) before/after on a <mention-page> body
    // ============================================================

    await test("cmd-w4 (b): page mention with resolved title → [Title](url)") {
        let body = #"See <mention-page url="https://www.notion.so/abc"/> for details."#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "https://www.notion.so/p",
            markdownJSONOrText: mdJSON(body)
        ) { _ in "Onboarding Guide" }
        let c = contentString(r) ?? ""
        try expect(c == "See [Onboarding Guide](https://www.notion.so/abc) for details.",
                   "got: \(c)")
    }

    await test("cmd-w4 (b): OLD behavior modeled — mention was bare title, no link") {
        // Pre-cmd-w4, a <mention-page> arrived as plain_text = the page
        // title with NO url. Contrast: the new path yields a real link.
        let oldRendered = "See Onboarding Guide for details."  // legacy: bare title
        try expect(!oldRendered.contains("]("), "legacy model wrong (had a link)")

        let body = #"See <mention-page url="https://www.notion.so/abc"/> for details."#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "https://www.notion.so/p",
            markdownJSONOrText: mdJSON(body)
        ) { _ in "Onboarding Guide" }
        let c = contentString(r) ?? ""
        try expect(c.contains("](https://www.notion.so/abc)"),
                   "new path must emit a clickable link; got: \(c)")
    }

    await test("cmd-w4 (b): multiple distinct page mentions all resolve") {
        let body = #"A <mention-page url="https://www.notion.so/a"/> B <mention-page url="https://www.notion.so/b"/>"#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "u",
            markdownJSONOrText: mdJSON(body)
        ) { u in u.hasSuffix("/a") ? "Alpha" : "Beta" }
        let c = contentString(r) ?? ""
        try expect(c == "A [Alpha](https://www.notion.so/a) B [Beta](https://www.notion.so/b)",
                   "got: \(c)")
    }

    // ============================================================
    // MARK: (c) unresolved / non-page mentions — never dropped
    // ============================================================

    await test("cmd-w4 (c): unresolved page mention → [link](url), not dropped") {
        let body = #"X <mention-page url="https://www.notion.so/zzz"/> Y"#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "u",
            markdownJSONOrText: mdJSON(body)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c == "X [link](https://www.notion.so/zzz) Y", "got: \(c)")
    }

    await test("cmd-w4 (c): user mention → [link](url) (modelled subtype)") {
        let body = #"ping <mention-user url="user://u-7"/> done"#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "u",
            markdownJSONOrText: mdJSON(body)
        ) { _ in "ShouldNotBeUsed" }
        let c = contentString(r) ?? ""
        try expect(c == "ping [link](user://u-7) done", "got: \(c)")
    }

    await test("cmd-w4 (c): unknown subtype WITHOUT url passes through verbatim") {
        let body = "keep <mention-mystery foo=\"bar\"/> me"
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "S", url: "u",
            markdownJSONOrText: mdJSON(body)
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c == body, "content must survive byte-for-byte; got: \(c)")
    }

    // ============================================================
    // MARK: (d) envelope shape unchanged
    // ============================================================

    await test("cmd-w4 (d): envelope keys + value types unchanged") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "skillName", title: "Page Title", url: "https://www.notion.so/p9",
            markdownJSONOrText: mdJSON("hello body"),
            summary: "sum", triggerPhrases: ["t1"], antiTriggerPhrases: ["a1"]
        ) { _ in nil }
        guard case .object(let o) = r else {
            throw TestError.assertion("result must be an object")
        }
        // Same keys the prior block-walk result emitted.
        for k in ["name", "title", "url", "blockCount", "truncated", "content",
                  "summary", "triggerPhrases", "antiTriggerPhrases"] {
            try expect(o[k] != nil, "missing envelope key: \(k)")
        }
        if case .string(let n)? = o["name"] { try expect(n == "skillName", "name") }
        else { throw TestError.assertion("name not a string") }
        if case .string(let t)? = o["title"] { try expect(t == "Page Title", "title") }
        else { throw TestError.assertion("title not a string") }
        if case .string(let u)? = o["url"] { try expect(u == "https://www.notion.so/p9", "url") }
        else { throw TestError.assertion("url not a string") }
        guard case .int? = o["blockCount"] else {
            throw TestError.assertion("blockCount must be an int (shape stability)")
        }
        guard case .bool(let tr)? = o["truncated"] else {
            throw TestError.assertion("truncated must be a bool")
        }
        try expect(tr == false, "truncated must be false on the /markdown path")
        guard case .string? = o["content"] else {
            throw TestError.assertion("content must be a string")
        }
        guard case .array? = o["triggerPhrases"] else {
            throw TestError.assertion("triggerPhrases must be an array")
        }
    }

    await test("cmd-w4 (d): truncationReason omitted (single /markdown call)") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: mdJSON("body")
        ) { _ in nil }
        guard case .object(let o) = r else {
            throw TestError.assertion("object expected")
        }
        try expect(o["truncationReason"] == nil,
                   "no pagination cap on /markdown → no truncationReason")
    }

    await test("cmd-w4 (d): raw markdown (non-JSON) input is accepted too") {
        // Defensive decode: a fetcher returning already-extracted markdown
        // (no JSON envelope) must still resolve, same as CommandsManager.
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: "## Raw Heading\n- bullet"
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("## Raw Heading") && c.contains("- bullet"),
                   "raw markdown must pass through; got: \(c)")
    }

    // ============================================================
    // MARK: (e) empty / odd body safety
    // ============================================================

    await test("cmd-w4 (e): empty markdown body → stable envelope, no crash") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: mdJSON("")
        ) { _ in nil }
        guard case .object(let o) = r,
              case .string(let c)? = o["content"],
              case .int(let bc)? = o["blockCount"] else {
            throw TestError.assertion("envelope must stay well-formed on empty body")
        }
        try expect(c == "(no content)", "empty body content placeholder; got: \(c)")
        try expect(bc == 0, "empty body blockCount must be 0; got: \(bc)")
    }

    await test("cmd-w4 (e): whitespace-only body → blockCount 0") {
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: mdJSON("   \n  \n\t\n")
        ) { _ in nil }
        guard case .object(let o) = r, case .int(let bc)? = o["blockCount"] else {
            throw TestError.assertion("object/int expected")
        }
        try expect(bc == 0, "whitespace lines are not content; got: \(bc)")
    }

    await test("cmd-w4 (e): malformed JSON envelope falls back to raw bytes") {
        // Not valid JSON and no 'markdown' key → treated as raw markdown,
        // never dropped (mirrors notion_page_markdown_read decode).
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: "{ this is not json # Heading"
        ) { _ in nil }
        let c = contentString(r) ?? ""
        try expect(c.contains("# Heading"), "raw fallback must keep content; got: \(c)")
    }

    await test("cmd-w4 (e): body that is ONLY a mention still resolves + counts") {
        let body = #"<mention-page url="https://www.notion.so/solo"/>"#
        let r = await SkillsModule.buildSkillResultForTesting(
            name: "s", title: "T", url: "u",
            markdownJSONOrText: mdJSON(body)
        ) { _ in "Solo Page" }
        guard case .object(let o) = r,
              case .string(let c)? = o["content"],
              case .int(let bc)? = o["blockCount"] else {
            throw TestError.assertion("object expected")
        }
        try expect(c == "[Solo Page](https://www.notion.so/solo)", "got: \(c)")
        try expect(bc == 1, "single resolved line; got: \(bc)")
    }

    await test("cmd-w4 (e): skillMarkdownString decode parity (JSON vs raw)") {
        let viaJSON = SkillsModule.skillMarkdownString(
            fromMarkdownJSON: mdJSON("# H\n- a")
        )
        try expect(viaJSON == "# H\n- a", "JSON decode; got: \(viaJSON)")
        let viaRaw = SkillsModule.skillMarkdownString(fromMarkdownJSON: "# H\n- a")
        try expect(viaRaw == "# H\n- a", "raw fallback; got: \(viaRaw)")
    }
}
