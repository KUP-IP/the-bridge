// SkillPathResolverTests.swift — PKT-907 (Bridge v3.6 · 10) W1/W2/W3
// TheBridge · Tests
//
// Pure-logic coverage for the fetch_skill orchestrator's path parser,
// intent scorer, file-source specialist resolver, and routing-index
// surfacing helper. Zero network — every input is a synthetic string,
// every disk hit is a tmpdir created and torn down per test.

import Foundation
import TheBridgeLib

func runSkillPathResolverTests() async {
    print("\n\u{1F9ED} SkillPathResolver Tests (PKT-907 W1/W2/W3)")

    // MARK: - W1: SkillPath.parse

    await test("W1: parse('project-keepr') → parent only, no child, no depth-guard") {
        let p = SkillPath.parse("project-keepr")
        try expect(p != nil, "parser should accept bare name")
        try expect(p?.parent == "project-keepr")
        try expect(p?.child == nil)
        try expect(p?.depthExceeded == false)
    }

    await test("W1: parse('project-keepr/update') → parent + child, no depth-guard") {
        let p = SkillPath.parse("project-keepr/update")
        try expect(p?.parent == "project-keepr")
        try expect(p?.child == "update")
        try expect(p?.depthExceeded == false)
    }

    await test("W1: parse('project-keepr/update/deep') → depth-guard fires, child nil") {
        let p = SkillPath.parse("project-keepr/update/deep")
        try expect(p?.parent == "project-keepr", "parent must still be exposed for fallback")
        try expect(p?.child == nil, "child must be nil under depth-guard")
        try expect(p?.depthExceeded == true)
    }

    await test("W1: parse('   ') → nil (empty trimmed input)") {
        try expect(SkillPath.parse("   ") == nil)
        try expect(SkillPath.parse("") == nil)
    }

    await test("W1: parse('/foo') / 'foo/' tolerated") {
        // Empty parent before slash → nil.
        try expect(SkillPath.parse("/foo") == nil)
        // Trailing slash → bare parent.
        let p = SkillPath.parse("foo/")
        try expect(p?.parent == "foo")
        try expect(p?.child == nil)
        try expect(p?.depthExceeded == false)
    }

    await test("W1: parse('  parent  /  child  ') trims whitespace on segments") {
        let p = SkillPath.parse("  parent  /  child  ")
        try expect(p?.parent == "parent")
        try expect(p?.child == "child")
    }

    // MARK: - W2: SkillIntentScorer

    await test("W2.a: intent exact match returns score 1.0 + 'exact title'") {
        let candidates = [
            SkillIntentCandidate(name: "update"),
            SkillIntentCandidate(name: "triage")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "update", candidates: candidates)
        try expect(best != nil, "expected a winning match")
        try expect(best?.candidate.name == "update")
        try expect(best?.score == 1.0)
        try expect(best?.reason == "exact title")
    }

    await test("W2.b: intent alias match returns 0.85") {
        let candidates = [
            SkillIntentCandidate(name: "update", aliases: ["bump", "advance"]),
            SkillIntentCandidate(name: "triage")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "advance", candidates: candidates)
        try expect(best?.candidate.name == "update")
        try expect(best?.score == 0.85)
        try expect(best?.reason == "alias")
    }

    await test("W2: partial title match returns 0.7") {
        let candidates = [
            SkillIntentCandidate(name: "project-update")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "update", candidates: candidates)
        try expect(best != nil)
        try expect(best?.score == 0.7)
        try expect(best?.reason == "partial title")
    }

    await test("W2: keyword overlap on summary returns 0.4–0.6") {
        let candidates = [
            SkillIntentCandidate(name: "alpha", aliases: [], summary: "Triage stale projects weekly.")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "triage stale", candidates: candidates)
        try expect(best != nil, "expected a keyword-overlap match")
        let s = best?.score ?? 0
        try expect(s >= 0.4 && s <= 0.6, "score in [0.4, 0.6], got \(s)")
        try expect(best?.reason == "keyword overlap")
    }

    await test("W2.c: low confidence → nil (caller surfaces low-confidence annotation)") {
        let candidates = [
            SkillIntentCandidate(name: "alpha", aliases: [], summary: "Totally unrelated subject."),
            SkillIntentCandidate(name: "beta",  aliases: [], summary: "Another unrelated topic.")
        ]
        let best = SkillIntentScorer.bestMatch(intent: "xyzzy frobnicate", candidates: candidates)
        try expect(best == nil, "no candidate should clear 0.4 threshold")
    }

    await test("W2: empty intent → empty ranked list (defensive)") {
        let candidates = [SkillIntentCandidate(name: "update")]
        try expect(SkillIntentScorer.rank(intent: "", candidates: candidates).isEmpty)
        try expect(SkillIntentScorer.rank(intent: "   ", candidates: candidates).isEmpty)
    }

    await test("W2: stable tie-break by candidate name (alpha ascending)") {
        // Two candidates each get a partial match — tie at 0.7. The
        // alpha-first winner must be deterministic.
        let candidates = [
            SkillIntentCandidate(name: "zebra-update"),
            SkillIntentCandidate(name: "alpha-update")
        ]
        let ranked = SkillIntentScorer.rank(intent: "update", candidates: candidates)
        try expect(ranked.count == 2)
        try expect(ranked[0].candidate.name == "alpha-update", "alpha tie-break failed: \(ranked.map(\.candidate.name))")
    }

    await test("W2.d: parser without intent / path → bare parent (pre-PKT-907 shape)") {
        // The parser produces no child + no annotation. The bestMatch
        // function isn't called at all by the orchestrator in this case.
        let p = SkillPath.parse("focus-keepr")
        try expect(p?.child == nil)
        try expect(p?.depthExceeded == false)
    }

    // MARK: - W1.d / Q4: file-source path resolution

    await test("W1.d: file-source path resolves specialists/<child>.md (primary)") {
        let tmp = makeTmpSkillsDir(name: "pkt907-primary")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Layout:
        //   <tmp>/parent-skill/SKILL.md
        //   <tmp>/parent-skill/specialists/update.md
        let parentDir = tmp.appendingPathComponent("parent-skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: parentDir.appendingPathComponent("specialists"), withIntermediateDirectories: true)
        try? "---\nname: parent-skill\n---\nParent body.".write(to: parentDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "---\nname: update\n---\nUpdate sub-skill body.".write(to: parentDir.appendingPathComponent("specialists").appendingPathComponent("update.md"), atomically: true, encoding: .utf8)

        let parentText = try String(contentsOf: parentDir.appendingPathComponent("SKILL.md"))
        let parsed = FrontmatterParser.parse(parentText)
        let parent = ParsedSkill(
            name: "parent-skill",
            path: parentDir.appendingPathComponent("SKILL.md"),
            isUserSource: false,
            frontmatter: parsed.frontmatter,
            body: parsed.body,
            displayPath: "test/parent-skill/SKILL.md"
        )

        let r = SkillSpecialistFileResolver.resolve(parent: parent, child: "update")
        try expect(r != nil, "primary specialists/update.md should resolve")
        try expect(r?.name == "update")
        try expect(r?.body == "Update sub-skill body.")
    }

    await test("Q4: file-source frontmatter `specialists:` fallback resolves child") {
        let tmp = makeTmpSkillsDir(name: "pkt907-fallback")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parentDir = tmp.appendingPathComponent("parent-skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: parentDir.appendingPathComponent("specialists"), withIntermediateDirectories: true)
        // Parent declares specialists in frontmatter; file is named oddly.
        try? "---\nname: parent-skill\nspecialists: [triage]\n---\nParent body.".write(to: parentDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "---\nname: triage\n---\nTriage body.".write(to: parentDir.appendingPathComponent("specialists").appendingPathComponent("triage.md"), atomically: true, encoding: .utf8)

        let parentText = try String(contentsOf: parentDir.appendingPathComponent("SKILL.md"))
        let parsed = FrontmatterParser.parse(parentText)
        let parent = ParsedSkill(
            name: "parent-skill",
            path: parentDir.appendingPathComponent("SKILL.md"),
            isUserSource: false,
            frontmatter: parsed.frontmatter,
            body: parsed.body,
            displayPath: "test/parent-skill/SKILL.md"
        )

        let r = SkillSpecialistFileResolver.resolve(parent: parent, child: "triage")
        try expect(r != nil, "frontmatter-declared specialist should resolve")
        try expect(r?.name == "triage")
    }

    await test("W1.b: unknown file-source child returns nil (caller emits annotation)") {
        let tmp = makeTmpSkillsDir(name: "pkt907-nochild")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parentDir = tmp.appendingPathComponent("parent-skill", isDirectory: true)
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try? "---\nname: parent-skill\n---\nParent body.".write(to: parentDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let parsed = FrontmatterParser.parse(try String(contentsOf: parentDir.appendingPathComponent("SKILL.md")))
        let parent = ParsedSkill(
            name: "parent-skill",
            path: parentDir.appendingPathComponent("SKILL.md"),
            isUserSource: false,
            frontmatter: parsed.frontmatter,
            body: parsed.body,
            displayPath: "test/parent-skill/SKILL.md"
        )
        try expect(SkillSpecialistFileResolver.resolve(parent: parent, child: "nonexistent") == nil)
    }

    // MARK: - W3: SpecialistSummaryExtractor

    await test("W3.b: SpecialistSummaryExtractor returns first sentence of body, skipping headings") {
        let body = "# Title\n\n## Section\n\nThis is the first sentence. This is a second sentence."
        let s = SpecialistSummaryExtractor.firstSentence(from: body)
        try expect(s == "This is the first sentence.", "got '\(s)'")
    }

    await test("W3: SpecialistSummaryExtractor falls back to first 160 chars when no terminator") {
        let body = String(repeating: "abc ", count: 200)
        let s = SpecialistSummaryExtractor.firstSentence(from: body)
        try expect(s.count <= 160, "extractor must cap at 160 chars, got \(s.count)")
    }

    await test("W3.d: listAll enumerates dir + frontmatter specialists, deduped + alpha-sorted") {
        let tmp = makeTmpSkillsDir(name: "pkt907-listall")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parentDir = tmp.appendingPathComponent("parent-skill", isDirectory: true)
        let spDir = parentDir.appendingPathComponent("specialists")
        try? FileManager.default.createDirectory(at: spDir, withIntermediateDirectories: true)
        try? "---\nname: parent-skill\nspecialists: [close, update]\n---\nParent body.".write(to: parentDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try? "---\nname: update\n---\nUpdate body. First sentence.".write(to: spDir.appendingPathComponent("update.md"), atomically: true, encoding: .utf8)
        try? "---\nname: close\n---\nClose body. First sentence.".write(to: spDir.appendingPathComponent("close.md"), atomically: true, encoding: .utf8)
        try? "---\nname: triage\n---\nTriage body. First sentence.".write(to: spDir.appendingPathComponent("triage.md"), atomically: true, encoding: .utf8)

        let parsed = FrontmatterParser.parse(try String(contentsOf: parentDir.appendingPathComponent("SKILL.md")))
        let parent = ParsedSkill(
            name: "parent-skill",
            path: parentDir.appendingPathComponent("SKILL.md"),
            isUserSource: false,
            frontmatter: parsed.frontmatter,
            body: parsed.body,
            displayPath: "test/parent-skill/SKILL.md"
        )

        let all = SkillSpecialistFileResolver.listAll(parent: parent)
        // Expect alpha ordering: close, triage, update — and no dupes
        // even though `close` and `update` are also in the frontmatter array.
        let names = all.map(\.name)
        try expect(names == ["close", "triage", "update"], "expected close/triage/update, got \(names)")
    }

    // MARK: - SkillAnnotation raw values are wire-stable

    await test("SkillAnnotation raw values match the dispatch packet contract strings") {
        try expect(SkillAnnotation.specialistNotFound.rawValue == "specialist-not-found")
        try expect(SkillAnnotation.depthGuard.rawValue == "depth-guard")
        try expect(SkillAnnotation.lowConfidence.rawValue == "low-confidence")
    }
}

// MARK: - tmpdir helper

private func makeTmpSkillsDir(name: String) -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pkt907-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}
