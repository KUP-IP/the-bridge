// BridgeSearchTests.swift — PKT-1006 R2 (Command Bridge v4 · multi-entity search)
// NotionBridge · Tests
//
// Headless coverage for the PURE multi-entity search model (BridgeSearch.swift)
// + the skill-source destination resolver. The on-device GUI smoke (typing into
// the bar, the rows rendering, keyboard nav firing) is the documented W3 ceiling;
// what this file pins is the DECISION layer underneath:
//
//   (A) Fuzzy scoring: exact > prefix > substring > subsequence > no-match,
//       with position + boundary + gap shaping.
//   (B) rankedResults: group ordering (Commands→Skills→Jobs→Tools), score order
//       within a group, recency tie-break, per-group cap, empty-query guard.
//   (C) Typed result identity (kind-namespaced ids, destination carried through).
//   (D) skillDestination routing: file→file, notion→notion, gdocs→gdocs,
//       manual/empty→settings fallback.

import Foundation
import NotionBridgeLib

func runBridgeSearchTests() async {
    print("\n\u{1F50D}  BridgeSearch Tests (PKT-1006 R2 · multi-entity search)")

    // Helpers ────────────────────────────────────────────────────────────
    func entity(_ kind: BridgeSearchKind, _ id: String, _ title: String,
                recency: Date? = nil) -> BridgeSearchEntity {
        BridgeSearchEntity(kind: kind, id: id, title: title,
                           destination: .command(slug: id), recency: recency)
    }

    // ── (A) Fuzzy scoring ────────────────────────────────────────────────

    await test("Score: exact equality outranks prefix outranks substring") {
        let exact = BridgeSearch.score(query: "deploy", candidate: "deploy")
        let prefix = BridgeSearch.score(query: "dep", candidate: "deploy")
        let substr = BridgeSearch.score(query: "loy", candidate: "deploy")
        try expect(exact != nil && prefix != nil && substr != nil, "all three should match")
        try expect(exact! > prefix!, "exact (\(exact!)) must beat prefix (\(prefix!))")
        try expect(prefix! > substr!, "prefix (\(prefix!)) must beat substring (\(substr!))")
    }

    await test("Score: case-insensitive on both sides") {
        try expect(BridgeSearch.score(query: "DEPLOY", candidate: "deploy") == 1000,
                   "uppercase query vs lowercase candidate must be an exact match")
        try expect(BridgeSearch.score(query: "Re", candidate: "Reflow") != nil,
                   "mixed case prefix must match")
    }

    await test("Score: subsequence (fuzzy) matches scattered chars, scores below substring") {
        let sub = BridgeSearch.score(query: "fr", candidate: "file_read")     // f...r subsequence
        let substr = BridgeSearch.score(query: "ile", candidate: "file_read") // contiguous
        try expect(sub != nil, "f..r must match file_read as a subsequence")
        try expect(substr != nil, "ile must match as substring")
        try expect(substr! > sub!, "contiguous substring (\(substr!)) must outrank fuzzy (\(sub!))")
    }

    await test("Score: word-boundary subsequence (acronym) beats a same-length non-boundary one") {
        // "cb" → "command_bridge": both c and b land on word boundaries.
        let acronym = BridgeSearch.score(query: "cb", candidate: "command_bridge")
        // "cb" → "scuba": c and b are mid-word (no boundary), so fewer boundary bonuses.
        let scattered = BridgeSearch.score(query: "cb", candidate: "scuba")
        try expect(acronym != nil && scattered != nil, "both should be subsequence matches")
        try expect(acronym! > scattered!, "boundary acronym (\(acronym!)) must beat mid-word (\(scattered!))")
    }

    await test("Score: no match returns nil (filtered out)") {
        try expect(BridgeSearch.score(query: "xyz", candidate: "deploy") == nil,
                   "non-subsequence query must not match")
        try expect(BridgeSearch.score(query: "depz", candidate: "deploy") == nil,
                   "a query whose chars are not all an in-order subsequence must not match")
    }

    await test("Score: empty query is a neutral match; empty candidate never matches") {
        try expect(BridgeSearch.score(query: "", candidate: "anything") == 0,
                   "empty query matches with neutral score 0")
        try expect(BridgeSearch.score(query: "a", candidate: "") == nil,
                   "empty candidate cannot match a non-empty query")
    }

    await test("Score: earlier substring position outranks a later one") {
        let early = BridgeSearch.score(query: "ab", candidate: "abxxxx")
        let late  = BridgeSearch.score(query: "ab", candidate: "xxxxab")
        try expect(early != nil && late != nil, "both substring matches")
        try expect(early! > late!, "earlier position (\(early!)) must outrank later (\(late!))")
    }

    // ── (B) rankedResults: grouping + ordering + cap ─────────────────────

    await test("Ranked: empty query yields no results") {
        let results = BridgeSearch.rankedResults(query: "  ", entities: [entity(.command, "x", "deploy")])
        try expect(results.isEmpty, "blank query must return nothing (the bar shows the tray, not all)")
    }

    await test("Ranked: results are grouped Commands → Skills → Jobs → Tools") {
        let entities = [
            entity(.tool, "t", "deploy_tool"),
            entity(.job, "j", "deploy job"),
            entity(.skill, "s", "deploy skill"),
            entity(.command, "c", "deploy"),
        ]
        let results = BridgeSearch.rankedResults(query: "deploy", entities: entities)
        try expect(results.count == 4, "all four should match 'deploy', got \(results.count)")
        let kinds = results.map { $0.kind }
        try expect(kinds == [.command, .skill, .job, .tool],
                   "group order must be command, skill, job, tool — got \(kinds)")
    }

    await test("Ranked: within a group, higher score sorts first") {
        let entities = [
            entity(.command, "a", "deployment"),  // prefix-ish / substring
            entity(.command, "b", "deploy"),      // exact
        ]
        let results = BridgeSearch.rankedResults(query: "deploy", entities: entities)
        try expect(results.first?.entityId == "b", "the exact match must rank first, got \(results.first?.entityId ?? "nil")")
    }

    await test("Ranked: recency breaks score ties within a group") {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let entities = [
            entity(.command, "old", "deploy now", recency: older),
            entity(.command, "new", "deploy now", recency: newer),
        ]
        let results = BridgeSearch.rankedResults(query: "deploy now", entities: entities)
        try expect(results.count == 2, "both identical-title commands should match")
        try expect(results.first?.entityId == "new",
                   "the more-recent command must win the tie, got \(results.first?.entityId ?? "nil")")
    }

    await test("Ranked: per-group cap limits a noisy kind") {
        var entities: [BridgeSearchEntity] = []
        for i in 0..<20 { entities.append(entity(.tool, "t\(i)", "deploy\(i)")) }
        entities.append(entity(.command, "c", "deploy"))
        let results = BridgeSearch.rankedResults(query: "deploy", entities: entities, limitPerGroup: 8)
        let toolCount = results.filter { $0.kind == .tool }.count
        let cmdCount = results.filter { $0.kind == .command }.count
        try expect(toolCount == 8, "tools must be capped at 8, got \(toolCount)")
        try expect(cmdCount == 1, "the single command must survive the cap, got \(cmdCount)")
    }

    // ── (C) Typed result identity + destination carry-through ────────────

    await test("Result: id is kind-namespaced so the same id across kinds stays unique") {
        let entities = [
            BridgeSearchEntity(kind: .skill, id: "deploy", title: "deploy", destination: .skillSettings(anchor: "deploy")),
            BridgeSearchEntity(kind: .job, id: "deploy", title: "deploy", destination: .job(id: "deploy")),
        ]
        let results = BridgeSearch.rankedResults(query: "deploy", entities: entities)
        let ids = Set(results.map { $0.id })
        try expect(ids.count == 2, "same entity id in two kinds must yield two distinct result ids, got \(ids)")
        try expect(ids.contains("skill:deploy") && ids.contains("job:deploy"),
                   "ids must be namespaced by kind, got \(ids)")
    }

    await test("Result: destination is carried through unchanged") {
        let e = BridgeSearchEntity(kind: .tool, id: "screen_ocr", title: "screen_ocr",
                                   destination: .tool(group: "screen", tool: "screen_ocr"))
        let results = BridgeSearch.rankedResults(query: "screen", entities: [e])
        try expect(results.count == 1, "one match expected")
        try expect(results.first?.destination == .tool(group: "screen", tool: "screen_ocr"),
                   "the typed destination must round-trip through the result")
    }

    await test("Kind: tag + colorTag + group header are stable per kind") {
        try expect(BridgeSearchKind.command.tag == "CMD", "command tag")
        try expect(BridgeSearchKind.skill.tag == "SKILL", "skill tag")
        try expect(BridgeSearchKind.job.tag == "JOB", "job tag")
        try expect(BridgeSearchKind.tool.tag == "TOOL", "tool tag")
        try expect(BridgeSearchKind.command.colorTag == "blue", "command color")
        try expect(BridgeSearchKind.skill.colorTag == "purple", "skill color")
        try expect(BridgeSearchKind.job.colorTag == "green", "job color")
        try expect(BridgeSearchKind.tool.colorTag == "orange", "tool color")
        try expect(BridgeSearchKind.skill.groupHeader == "Skills", "skill header")
    }

    // ── (D) Skill-source destination resolution ──────────────────────────

    await MainActor.run {
        // file source → open the file
        let fileSkill = SkillsManager.Skill(
            name: "Local Skill", source: .file(path: URL(fileURLWithPath: "/tmp/skill.md")),
            platform: .manual)
        if case .skillFile(let path) = CommandBridgeController.skillDestination(for: fileSkill) {
            assert(path == "/tmp/skill.md", "file destination must carry the path")
            passed += 1; print("  \u{2705} skillDestination: .file → .skillFile(path)")
        } else {
            failed += 1; print("  \u{274C} skillDestination: .file did not resolve to .skillFile")
        }

        // notion source → open the Notion page
        let pid = "11112222333344445555666677778888"
        let notionSkill = SkillsManager.Skill(
            name: "Notion Skill", source: .notion(pageId: pid), platform: .notion)
        if case .skillNotion(let gotPid, _) = CommandBridgeController.skillDestination(for: notionSkill) {
            assert(gotPid == pid, "notion destination must carry the page id")
            passed += 1; print("  \u{2705} skillDestination: .notion → .skillNotion(pageId)")
        } else {
            failed += 1; print("  \u{274C} skillDestination: .notion did not resolve to .skillNotion")
        }

        // notion source but googleDocs platform + url → open the Google Doc
        let gdocURL = "https://docs.google.com/document/d/abc123/edit"
        let gdocSkill = SkillsManager.Skill(
            name: "Doc Skill", source: .notion(pageId: pid), url: gdocURL, platform: .googleDocs)
        if case .skillGoogleDoc(let url) = CommandBridgeController.skillDestination(for: gdocSkill) {
            assert(url == gdocURL, "gdocs destination must carry the doc url")
            passed += 1; print("  \u{2705} skillDestination: googleDocs platform → .skillGoogleDoc(url)")
        } else {
            failed += 1; print("  \u{274C} skillDestination: googleDocs platform did not resolve to .skillGoogleDoc")
        }

        // notion source with EMPTY page id and no url → settings fallback
        let manualSkill = SkillsManager.Skill(
            name: "Manual Skill", source: .notion(pageId: ""), platform: .manual)
        if case .skillSettings(let anchor) = CommandBridgeController.skillDestination(for: manualSkill) {
            assert(anchor == "Manual Skill", "settings fallback must anchor on the skill name")
            passed += 1; print("  \u{2705} skillDestination: empty/manual → .skillSettings(anchor)")
        } else {
            failed += 1; print("  \u{274C} skillDestination: empty/manual did not resolve to .skillSettings")
        }
    }
}
