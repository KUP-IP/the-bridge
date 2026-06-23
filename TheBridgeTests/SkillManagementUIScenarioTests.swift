// SkillManagementUIScenarioTests.swift — Skills settings user scenarios
// TheBridge · Tests
//
// Headless scenario coverage for Settings -> Skills. These tests lock the UI
// contract to the actual backend storage/edit architecture:
//   • Notion-source rows persist in `BridgeDefaults.skills` through
//     `SkillsManager`.
//   • File-source toggles persist per path through `SkillsModule`; SKILL.md
//     files stay read-only.
//   • UI labels/counts/grouping/filtering come from `SkillManagementUIContract`,
//     the same pure contract `SkillsView` renders.

import Foundation
import TheBridgeLib

func runSkillManagementUIScenarioTests() async {
    print("\n\u{1F9ED} Skill Management UI Scenario Tests")

    @Sendable func restoreDefaultsKey(_ key: String, _ data: Data?) {
        if let data {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Sendable func restoreBoolMapKey(_ key: String, _ prior: [String: Bool]?) {
        if let prior {
            UserDefaults.standard.set(prior, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Sendable func parseNotion(_ url: String) throws -> SkillURLParser.ParseResult {
        switch SkillURLParser.parse(url: url) {
        case .success(let parsed):
            return parsed
        case .failure(let err):
            throw TestError.assertion("URL parse failed: \(err.message)")
        }
    }

    @Sendable func parseSkillURL(_ url: String) throws -> SkillURLParser.ParseResult {
        switch SkillURLParser.parse(url: url) {
        case .success(let parsed):
            return parsed
        case .failure(let err):
            throw TestError.assertion("URL parse failed: \(err.message)")
        }
    }

    // ── Scenario 1: add from the UI form, then re-read from storage ─────
    await test("Scenario: add Notion skill persists flags, URL, platform, labels, counts") {
        try await MainActor.run {
            let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
            defer { restoreDefaultsKey(BridgeDefaults.skills, prior) }
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

            let manager = SkillsManager()
            let parsed = try parseNotion("https://www.notion.so/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            try expect(manager.addSkill(name: "Focus Keepr", notionPageId: parsed.uuid, visibility: .standard))
            try expect(manager.setRoutingDiscoverable(named: "Focus Keepr", to: true))
            try expect(manager.setInCommandPalette(named: "Focus Keepr", to: true))
            try expect(manager.updateSkillExtras(named: "Focus Keepr", url: parsed.originalURL, platform: parsed.platform))

            let reloaded = SkillsManager()
            let skill = try requireSkill(reloaded, "Focus Keepr")
            try expect(skill.notionPageId == parsed.uuid)
            try expect(skill.routingDiscoverable == true)
            try expect(skill.inCommandPalette == true)
            try expect(skill.url == parsed.originalURL)
            try expect(skill.platform == .notion)

            try expect(SkillManagementUIContract.visibilityMetadataLabel(for: skill) == "Both")
            try expect(SkillManagementUIContract.visibilityBadgeLabel(for: skill) == "Routing-discoverable")
            try expect(SkillManagementUIContract.kindLabel(for: skill) == "Routing")
            try expect(SkillManagementUIContract.rowStatusDescription(for: skill) == "Enabled, routing-discoverable")

            let cache = SkillBodyCacheSnapshot(entries: [skill.notionPageId: .init(cached: true, stale: false)])
            let counts = SkillManagementUIContract.counts(
                skills: reloaded.skills,
                fileSkills: [],
                sourceFilter: .all,
                bodyCacheSnapshot: cache
            )
            try expect(counts == SkillManagementCounts(total: 1, routing: 1, specialist: 0, cached: 1),
                       "counts must mirror the persisted flags and real body-cache state; got \(counts)")
            try expect(reloaded.routingSkillsForDiscovery.map(\.name) == ["Focus Keepr"])
        }
    }

    // ── Scenario 2: rename + page edit guardrails ──────────────────────
    await test("Scenario: rename and URL edit preserve flags and reject duplicate/empty names") {
        try await MainActor.run {
            let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
            defer { restoreDefaultsKey(BridgeDefaults.skills, prior) }
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

            let manager = SkillsManager()
            try expect(manager.addSkill(name: "Alpha", notionPageId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", visibility: .standard))
            try expect(manager.addSkill(name: "Beta", notionPageId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", visibility: .standard))
            try expect(manager.setRoutingDiscoverable(named: "Alpha", to: true))
            try expect(manager.setInCommandPalette(named: "Alpha", to: true))

            try expect(manager.renameSkill(named: "Alpha", to: "Beta") == false,
                       "duplicate rename must not clobber another row")
            try expect(manager.renameSkill(named: "Alpha", to: "   ") == false,
                       "blank rename must be rejected")
            try expect(manager.renameSkill(named: "Alpha", to: "Gamma") == true)

            let normalized = try NotionPageRef.normalizedPageId(from: "https://www.notion.so/cccccccccccccccccccccccccccccccc").get()
            try expect(manager.updateSkillURL(named: "Gamma", newPageId: normalized) == true)

            let skill = try requireSkill(manager, "Gamma")
            try expect(skill.notionPageId == normalized)
            try expect(skill.routingDiscoverable == true && skill.inCommandPalette == true,
                       "rename + page edit must preserve independent visibility flags")
            try expect(manager.skill(named: "Alpha") == nil)
            try expect(manager.skill(named: "Beta") != nil)
        }
    }

    // ── Scenario 3: backend/MCP metadata edit then UI reload ───────────
    await test("Scenario: metadata edit survives reload and drives search/group UI contract") {
        try await MainActor.run {
            let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
            defer { restoreDefaultsKey(BridgeDefaults.skills, prior) }
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

            let manager = SkillsManager()
            try expect(manager.addSkill(name: "Draft Helper", notionPageId: "dddddddddddddddddddddddddddddddd", visibility: .standard))
            try expect(manager.setInCommandPalette(named: "Draft Helper", to: true))
            try expect(manager.setMetadata(
                named: "Draft Helper",
                summary: "Composes launch copy and polished packet receipts.",
                triggerPhrases: ["draft launch", "packet receipt"],
                antiTriggerPhrases: ["schedule meeting"]
            ))

            let reloaded = SkillsManager()
            let skill = try requireSkill(reloaded, "Draft Helper")
            try expect(skill.summary.contains("launch copy"))
            try expect(skill.triggerPhrases == ["draft launch", "packet receipt"])
            try expect(skill.antiTriggerPhrases == ["schedule meeting"])
            try expect(SkillManagementUIContract.visibilityMetadataLabel(for: skill) == "Palette")
            try expect(SkillManagementUIContract.kindLabel(for: skill) == "Specialist")

            let groups = SkillManagementUIContract.visibleGroups(
                skills: reloaded.skills,
                searchText: "receipts",
                sourceFilter: .all
            )
            try expect(groups.map(\.label) == ["Specialists"])
            try expect(groups.first?.skills.map(\.name) == ["Draft Helper"])
        }
    }

    // ── Scenario 4: delete removes only the registry row ───────────────
    await test("Scenario: confirmed delete removes registry row and updates UI inventory") {
        try await MainActor.run {
            let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
            defer { restoreDefaultsKey(BridgeDefaults.skills, prior) }
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

            let manager = SkillsManager()
            try expect(manager.addSkill(name: "Delete Me", notionPageId: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", visibility: .routing))
            try expect(manager.addSkill(name: "Keep Me", notionPageId: "ffffffffffffffffffffffffffffffff", visibility: .standard))
            manager.removeSkill(named: "Delete Me")

            let reloaded = SkillsManager()
            try expect(reloaded.skill(named: "Delete Me") == nil)
            try expect(reloaded.skill(named: "Keep Me") != nil)
            let counts = SkillManagementUIContract.counts(
                skills: reloaded.skills,
                fileSkills: [],
                sourceFilter: .all,
                bodyCacheSnapshot: SkillBodyCacheSnapshot()
            )
            try expect(counts == SkillManagementCounts(total: 1, routing: 0, specialist: 0, cached: 0))
        }
    }

    // ── Scenario 5: file-source controls persist per path, not in SKILL.md ─
    await test("Scenario: file-source toggles are per-path and SKILL.md stays read-only") {
        let enabledPrior = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillEnabled) as? [String: Bool]
        let routingPrior = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillRoutingDiscoverable) as? [String: Bool]
        let palettePrior = UserDefaults.standard.dictionary(forKey: BridgeDefaults.fileSkillInCommandPalette) as? [String: Bool]
        defer {
            restoreBoolMapKey(BridgeDefaults.fileSkillEnabled, enabledPrior)
            restoreBoolMapKey(BridgeDefaults.fileSkillRoutingDiscoverable, routingPrior)
            restoreBoolMapKey(BridgeDefaults.fileSkillInCommandPalette, palettePrior)
        }

        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skill-ui-scenario-\(UUID().uuidString)")
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "---\nname: file-helper\nvisibility: routing\n---\nBody\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        try expect(SkillsModule.isFileSkillEnabled(path: path) == true)
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: ["visibility": "routing"]) == true)
        SkillsModule.setFileSkillEnabled(path: path, enabled: false)
        SkillsModule.setFileSkillRoutingDiscoverable(path: path, value: false)
        SkillsModule.setFileSkillInCommandPalette(path: path, value: true)

        try expect(SkillsModule.isFileSkillEnabled(path: path) == false)
        try expect(SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: ["visibility": "routing"]) == false)
        try expect(SkillsModule.isFileSkillInCommandPalette(path: path) == true)
        try expect(try String(contentsOf: path, encoding: .utf8) == original,
                   "file-source UI toggles must not edit SKILL.md")

        let fileState = SkillManagementFileSkillState(
            name: "file-helper",
            path: path.path,
            enabled: SkillsModule.isFileSkillEnabled(path: path),
            routingDiscoverable: SkillsModule.isFileSkillRoutingDiscoverable(path: path, frontmatter: ["visibility": "routing"]),
            inCommandPalette: SkillsModule.isFileSkillInCommandPalette(path: path)
        )
        let counts = SkillManagementUIContract.counts(
            skills: [],
            fileSkills: [fileState],
            sourceFilter: .file,
            bodyCacheSnapshot: SkillBodyCacheSnapshot()
        )
        try expect(counts == SkillManagementCounts(total: 1, routing: 0, specialist: 0, cached: 1),
                   "file-source bodies ship on disk, but disabled routing must not count")
    }

    // ── Scenario 6: filtered display order drives chevrons ─────────────
    await test("Scenario: filtered grouped display order drives previous/next navigation") {
        let skills: [SkillsManager.Skill] = [
            .init(name: "Plain Z", notionPageId: "11111111111111111111111111111111", visibility: .standard, summary: "alpha"),
            .init(name: "Routing A", notionPageId: "22222222222222222222222222222222", visibility: .routing, summary: "alpha"),
            .init(name: "Palette B", notionPageId: "33333333333333333333333333333333", visibility: .command, summary: "alpha"),
            .init(name: "Docs C", notionPageId: "doc-id", visibility: .standard, summary: "alpha", url: "https://docs.google.com/document/d/doc-id/edit", platform: .googleDocs),
        ]

        let allOrder = SkillManagementUIContract.visibleSkillNamesInDisplayOrder(
            skills: skills,
            searchText: "alpha",
            sourceFilter: .all
        )
        try expect(allOrder == ["Routing A", "Palette B", "Plain Z", "Docs C"],
                   "visible order must group routing, specialist, then plain while preserving order inside each group; got \(allOrder)")
        try expect(SkillListNavigation.target(from: "Routing A", delta: 1, in: allOrder) == "Palette B")
        try expect(SkillListNavigation.target(from: "Plain Z", delta: -1, in: allOrder) == "Palette B")

        let docsOrder = SkillManagementUIContract.visibleSkillNamesInDisplayOrder(
            skills: skills,
            searchText: "",
            sourceFilter: .gdocs
        )
        try expect(docsOrder == ["Docs C"], "Docs filter must isolate Google Docs skills")
    }

    // ── Scenario 7: banner/footer/add states are truthful ──────────────
    await test("Scenario: banners, footer, cache badges, and add enabled state mirror backend state") {
        try expect(SkillManagementUIContract.isAddSkillEnabled(name: "", pageId: "abc") == false)
        try expect(SkillManagementUIContract.isAddSkillEnabled(name: "Name", pageId: "   ") == false)
        try expect(SkillManagementUIContract.isAddSkillEnabled(name: " Name ", pageId: " page ") == true)

        let validA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let validB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let skills: [SkillsManager.Skill] = [
            .init(name: "Invalid", notionPageId: "not-a-page-id", enabled: true, visibility: .standard),
            .init(name: "Enabled", notionPageId: validA, enabled: true, visibility: .standard),
            .init(name: "Disabled", notionPageId: validB, enabled: false, visibility: .command),
        ]
        let fileSkills = [
            SkillManagementFileSkillState(name: "File Plain", path: "/tmp/file-plain", enabled: true),
            SkillManagementFileSkillState(name: "File Palette", path: "/tmp/file-palette", enabled: true, inCommandPalette: true),
        ]
        let cache = SkillBodyCacheSnapshot(entries: [validA: .init(cached: true, stale: false)])

        try expect(SkillManagementUIContract.anyBodyCached(skills: skills, bodyCacheSnapshot: cache) == true)
        try expect(SkillManagementUIContract.listFooterText(skills: skills, bodyCacheSnapshot: cache) == "2/3 enabled · 1 cached")
        try expect(SkillManagementUIContract.palettePopulation(skills: skills, fileSkills: fileSkills) == 1,
                   "disabled palette skill must not count, enabled file palette must count")

        let state = SkillManagementUIContract.bannerState(
            skills: skills,
            fileSkills: fileSkills,
            fetchSkillDisabled: true,
            cacheBusy: false,
            cacheMessage: "Notion failed",
            cacheIsError: true
        )
        try expect(state.showsInvalidPageIDs == true)
        try expect(state.showsFetchSkillDisabled == true)
        try expect(state.showsPaletteEmpty == false, "enabled file palette membership should satisfy the palette banner")
        try expect(state.showsCacheFailure == true)

        let emptyPalette = SkillManagementUIContract.bannerState(
            skills: [skills[1]],
            fileSkills: [fileSkills[0]],
            fetchSkillDisabled: false,
            cacheBusy: true,
            cacheMessage: "Still running",
            cacheIsError: true
        )
        try expect(emptyPalette.showsInvalidPageIDs == false)
        try expect(emptyPalette.showsFetchSkillDisabled == false)
        try expect(emptyPalette.showsPaletteEmpty == true)
        try expect(emptyPalette.showsCacheFailure == false, "busy cache state must not render a failed-cache banner")
    }

    // ── Scenario 8: Google Docs source path stays distinct from Notion ──
    await test("Scenario: Google Docs skill preserves platform and filters/counts separately from Notion") {
        try await MainActor.run {
            let prior = UserDefaults.standard.data(forKey: BridgeDefaults.skills)
            defer { restoreDefaultsKey(BridgeDefaults.skills, prior) }
            UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills)

            let parsed = try parseSkillURL("https://docs.google.com/document/d/doc-12345/edit")
            try expect(parsed.platform == .googleDocs)

            let manager = SkillsManager()
            try expect(manager.addSkill(name: "Docs Skill", notionPageId: parsed.uuid, visibility: .standard))
            try expect(manager.setInCommandPalette(named: "Docs Skill", to: true))
            try expect(manager.updateSkillExtras(named: "Docs Skill", url: parsed.originalURL, platform: parsed.platform))

            let reloaded = SkillsManager()
            let skill = try requireSkill(reloaded, "Docs Skill")
            try expect(skill.platform == .googleDocs)
            try expect(skill.url == parsed.originalURL)
            try expect(skill.notionPageId == parsed.uuid)
            try expect(SkillManagementUIContract.kindLabel(for: skill) == "Specialist")
            try expect(SkillManagementUIContract.visibilityMetadataLabel(for: skill) == "Palette")

            let cache = SkillBodyCacheSnapshot(entries: [parsed.uuid: .init(cached: true, stale: false)])
            let docsCounts = SkillManagementUIContract.counts(
                skills: reloaded.skills,
                fileSkills: [],
                sourceFilter: .gdocs,
                bodyCacheSnapshot: cache
            )
            try expect(docsCounts == SkillManagementCounts(total: 1, routing: 0, specialist: 1, cached: 1))

            let notionCounts = SkillManagementUIContract.counts(
                skills: reloaded.skills,
                fileSkills: [],
                sourceFilter: .notion,
                bodyCacheSnapshot: cache
            )
            try expect(notionCounts == SkillManagementCounts(total: 0, routing: 0, specialist: 0, cached: 0))
        }
    }
}

@MainActor
private func requireSkill(_ manager: SkillsManager, _ name: String) throws -> SkillsManager.Skill {
    guard let skill = manager.skill(named: name) else {
        throw TestError.assertion("missing skill: \(name)")
    }
    return skill
}
