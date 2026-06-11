// SkillIconAndKindTests.swift — WS-3 + WS-4
// NotionBridge · Tests
//
// WS-3: Skill emoji icon — Codable default/round-trip, blank normalization,
//       forwards-tolerant decode of pre-WS-3 blobs, and the
//       `NotionModule.extractIconEmoji` page-JSON extractor (emoji ONLY;
//       external/file image icons return nil).
// WS-4: Surfaced TYPE (skillKind) + SOURCE (sourceKind) derived accessors
//       for a future grouped UI — data only.

import Foundation
import NotionBridgeLib

func runSkillIconAndKindTests() async {
    print("\n\u{2728} Skill Icon + Kind Tests (WS-3 / WS-4)")

    // MARK: - WS-3: icon default + decode tolerance

    await test("WS-3: Skill defaults icon to nil") {
        let s = SkillsManager.Skill(name: "NoIcon", source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"))
        try expect(s.icon == nil, "expected nil icon, got \(String(describing: s.icon))")
    }

    await test("WS-3: pre-WS-3 blob (no icon key) decodes with nil icon") {
        // The persisted wire format from every release before WS-3 — and the
        // shape SkillsModule.SkillConfig writes (it never emits `icon`).
        let json = """
        {
          "name": "LegacyNoIcon",
          "source": {"kind": "notion", "pageId": "aaaa1111bbbb2222cccc3333dddd4444"},
          "enabled": true,
          "routingDiscoverable": false,
          "inCommandPalette": false,
          "summary": "",
          "triggerPhrases": [],
          "antiTriggerPhrases": [],
          "platform": "notion"
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(SkillsManager.Skill.self, from: json)
        try expect(s.name == "LegacyNoIcon")
        try expect(s.icon == nil, "missing icon key must decode as nil")
    }

    await test("WS-3: icon round-trips through Codable") {
        let s = SkillsManager.Skill(
            name: "WithIcon",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            icon: "\u{2728}" // ✨
        )
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SkillsManager.Skill.self, from: data)
        try expect(back.icon == "\u{2728}", "icon lost in round-trip: \(String(describing: back.icon))")
    }

    await test("WS-3: blank / whitespace icon normalizes to nil") {
        let s1 = SkillsManager.Skill(name: "Blank", source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"), icon: "   ")
        try expect(s1.icon == nil, "whitespace icon must normalize to nil")

        let s2 = SkillsManager.Skill(name: "Empty", source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"), icon: "")
        try expect(s2.icon == nil, "empty icon must normalize to nil")

        // Decode path normalizes too.
        let json = """
        {"name":"X","source":{"kind":"notion","pageId":"aaaa1111bbbb2222cccc3333dddd4444"},"enabled":true,"routingDiscoverable":false,"inCommandPalette":false,"summary":"","triggerPhrases":[],"antiTriggerPhrases":[],"platform":"notion","icon":"  "}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SkillsManager.Skill.self, from: json)
        try expect(decoded.icon == nil, "decoded blank icon must normalize to nil")
    }

    await test("WS-3: encoder omits icon key when nil (lean wire format)") {
        let s = SkillsManager.Skill(name: "NoIcon", source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"))
        let data = try JSONEncoder().encode(s)
        let str = String(data: data, encoding: .utf8) ?? ""
        try expect(!str.contains("\"icon\""), "nil icon must NOT be emitted: \(str)")
    }

    // MARK: - WS-3: NotionModule.extractIconEmoji

    await test("WS-3: extractIconEmoji returns the glyph for an emoji icon") {
        let json: [String: Any] = ["icon": ["type": "emoji", "emoji": "\u{1F680}"]] // 🚀
        try expect(NotionModule.extractIconEmoji(from: json) == "\u{1F680}")
    }

    await test("WS-3: extractIconEmoji returns nil for an external (image) icon") {
        let json: [String: Any] = ["icon": ["type": "external", "external": ["url": "https://example.com/i.png"]]]
        try expect(NotionModule.extractIconEmoji(from: json) == nil, "image icons are out of scope this pass")
    }

    await test("WS-3: extractIconEmoji returns nil for a file (uploaded) icon") {
        let json: [String: Any] = ["icon": ["type": "file", "file": ["url": "https://files.notion.so/x.png"]]]
        try expect(NotionModule.extractIconEmoji(from: json) == nil)
    }

    await test("WS-3: extractIconEmoji returns nil when no icon present") {
        try expect(NotionModule.extractIconEmoji(from: ["id": "abc"]) == nil)
        try expect(NotionModule.extractIconEmoji(from: ["icon": NSNull()]) == nil)
        try expect(NotionModule.extractIconEmoji(from: ["icon": ["type": "emoji", "emoji": "  "]]) == nil,
                   "blank emoji must normalize to nil")
    }

    // MARK: - WS-4: sourceKind

    await test("WS-4: sourceKind reflects the SkillSource origin") {
        let notion = SkillsManager.Skill(name: "N", source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"))
        try expect(notion.sourceKind == .notion)

        let file = SkillsManager.Skill(name: "F", source: .file(path: URL(fileURLWithPath: "/tmp/x/SKILL.md")))
        try expect(file.sourceKind == .file)
    }

    // MARK: - WS-4: skillKind derivation heuristic

    await test("WS-4: skillKind == .routing when routingDiscoverable") {
        let s = SkillsManager.Skill(
            name: "R",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            routingDiscoverable: true,
            inCommandPalette: false
        )
        try expect(s.skillKind == .routing)
    }

    await test("WS-4: skillKind == .specialist when palette-only (not routing)") {
        let s = SkillsManager.Skill(
            name: "S",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            routingDiscoverable: false,
            inCommandPalette: true
        )
        try expect(s.skillKind == .specialist)
    }

    await test("WS-4: skillKind == .plain when neither flag set") {
        let s = SkillsManager.Skill(
            name: "P",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            routingDiscoverable: false,
            inCommandPalette: false
        )
        try expect(s.skillKind == .plain)
    }

    await test("WS-4: routing flag dominates palette flag (combined state)") {
        // The new W4 state the legacy enum could not express: both flags set.
        // Routing wins — it's the more discoverable, orchestrator-level tier.
        let s = SkillsManager.Skill(
            name: "Both",
            source: .notion(pageId: "aaaa1111bbbb2222cccc3333dddd4444"),
            routingDiscoverable: true,
            inCommandPalette: true
        )
        try expect(s.skillKind == .routing)
    }

    // MARK: - WS-3/WS-4: SkillsManager mutator + filters

    await test("WS-3/WS-4: setIcon + skills(ofKind:) + skills(ofSource:) on a live manager") {
        try await MainActor.run {
            // Isolate this test's UserDefaults key write — restore after.
            let key = BridgeDefaults.skills
            let saved = UserDefaults.standard.data(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)

            let mgr = SkillsManager()
            _ = mgr.addSkill(name: "RoutingOne", notionPageId: "aaaa1111bbbb2222cccc3333dddd4444", visibility: .routing)
            _ = mgr.addSkill(name: "PaletteOne", notionPageId: "bbbb1111cccc2222dddd3333eeee4444", visibility: .command)
            _ = mgr.addSkill(name: "PlainOne", notionPageId: "cccc1111dddd2222eeee3333ffff4444", visibility: .standard)

            // setIcon writes + clears.
            try expect(mgr.setIcon(named: "PlainOne", to: "\u{2B50}"), "setIcon should find the skill") // ⭐
            try expect(mgr.skill(named: "PlainOne")?.icon == "\u{2B50}", "icon not stored")
            try expect(mgr.setIcon(named: "PlainOne", to: "  "), "setIcon clear should succeed")
            try expect(mgr.skill(named: "PlainOne")?.icon == nil, "blank should clear icon")
            try expect(mgr.setIcon(named: "DoesNotExist", to: "x") == false, "missing skill returns false")

            // skillKind filters.
            try expect(mgr.skills(ofKind: .routing).map(\.name) == ["RoutingOne"], "routing filter")
            try expect(mgr.skills(ofKind: .specialist).map(\.name) == ["PaletteOne"], "specialist filter")
            try expect(mgr.skills(ofKind: .plain).map(\.name) == ["PlainOne"], "plain filter")

            // sourceKind filter — all three are notion.
            try expect(mgr.skills(ofSource: .notion).count == 3, "notion source filter")
            try expect(mgr.skills(ofSource: .file).isEmpty, "no file-source skills")
        }
    }

    await test("WS-3: icon survives a SkillsManager save + reload (persistence)") {
        try await MainActor.run {
            let key = BridgeDefaults.skills
            let saved = UserDefaults.standard.data(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)

            let mgr = SkillsManager()
            _ = mgr.addSkill(name: "Persisted", notionPageId: "aaaa1111bbbb2222cccc3333dddd4444")
            _ = mgr.setIcon(named: "Persisted", to: "\u{1F525}") // 🔥

            // Fresh manager reads from the same UserDefaults key.
            let reloaded = SkillsManager()
            try expect(reloaded.skill(named: "Persisted")?.icon == "\u{1F525}", "icon must persist across reload")
        }
    }
}
