// CommandVisibilityTests.swift — cmd-ux W3 (.command visibility axis)
// TheBridge · Tests
//
// HEADLESSLY TESTED (no UI, no WindowServer):
//   • SkillVisibility Codable round-trip for ALL cases incl. `.command`
//     + legacy `adminOnly`→`.standard` + unknown→`.standard` + missing.
//   • RegistrySkillsCommandProvider filters descriptors() to enabled
//     `.command` ONLY (mixed registry via the init(suiteName:) seam).
//   • The per-row visibility picker write-back persists `visibility`
//     through SkillsManager.setVisibility (round-trips on reload).
//   • CommandPaletteEmptyState — the pure empty-vs-hint decision + copy.
//   • The 4 SkillVsCommandSplitTests LOCK tests stay green (re-run from
//     main.swift) — this feature is a DIFFERENT axis and must not
//     regress the retrieval split or routing/fetch_skill.
//
// OPERATOR-SMOKE CEILING (NOT faked): the SwiftUI Picker rendering and
// the live palette NSPanel showing the hint line — the DECISIONS beneath
// (filter, persistence, empty-state) are pure and asserted here.

import Foundation
import TheBridgeLib

func runCommandVisibilityTests() async {
    print("\n\u{1F516} Command Visibility Tests (cmd-ux W3 · .command axis)")

    // ── SkillVisibility Codable round-trip ─────────────────────────────
    @Sendable func roundTrip(_ v: SkillVisibility) throws -> SkillVisibility {
        let data = try JSONEncoder().encode(v)
        return try JSONDecoder().decode(SkillVisibility.self, from: data)
    }
    @Sendable func decodeRaw(_ raw: String) throws -> SkillVisibility {
        // Encode a bare JSON string (single-value container shape).
        let data = try JSONEncoder().encode(raw)
        return try JSONDecoder().decode(SkillVisibility.self, from: data)
    }

    await test("W3 SkillVisibility: every case round-trips (incl. .command)") {
        for v in SkillVisibility.allCases {
            try expect(try roundTrip(v) == v, "\(v) must survive encode→decode")
        }
        try expect(SkillVisibility.allCases.count == 3,
                   "exactly routing/standard/command, got \(SkillVisibility.allCases.count)")
        try expect(SkillVisibility.command.rawValue == "command",
                   "the wire value is 'command'")
    }

    await test("W3 SkillVisibility: legacy adminOnly ⇒ .standard; unknown ⇒ .standard") {
        try expect(try decodeRaw("adminOnly") == .standard,
                   "legacy adminOnly must decode as .standard")
        try expect(try decodeRaw("totally-unknown") == .standard,
                   "an unknown raw must degrade to .standard (never auto-promote)")
        try expect(try decodeRaw("  command  ") == .command,
                   "whitespace-padded 'command' still decodes (trimmed)")
        try expect(try decodeRaw("routing") == .routing)
        try expect(try decodeRaw("standard") == .standard)
    }

    await test("W3 SkillVisibility: a Skill with .command round-trips through the registry shape") {
        // The exact persisted Skill shape (what manage_skill / SkillsManager
        // write) must carry `.command` losslessly.
        let s = SkillsManager.Skill(name: "Sig", notionPageId: "p", visibility: .command)
        let data = try JSONEncoder().encode([s])
        let back = try JSONDecoder().decode([SkillsManager.Skill].self, from: data)
        try expect(back.first?.visibility == .command,
                   "a .command skill must persist + reload as .command, got \(String(describing: back.first?.visibility))")
    }

    // ── RegistrySkillsCommandProvider: enabled `.command` ONLY ─────────
    @Sendable func seed(_ suite: String,
                        _ rows: [(String, String, Bool, String)]) {
        let arr: [[String: Any]] = rows.map {
            ["name": $0.0, "notionPageId": $0.1, "enabled": $0.2, "visibility": $0.3]
        }
        let data = try! JSONSerialization.data(withJSONObject: arr)
        UserDefaults(suiteName: suite)!.set(data, forKey: BridgeDefaults.skills)
    }

    await test("W3 provider: mixed registry ⇒ ONLY enabled `.command` descriptors") {
        let suite = "kup.solutions.notion-bridge.cmd-ux.w3.\(UUID().uuidString)"
        let p1 = "aaaa1111bbbb2222cccc3333dddd4444"
        let p2 = "bbbb1111cccc2222dddd3333eeee4444"
        seed(suite, [
            ("Routing X",  "cccc1111dddd2222eeee3333ffff4444", true,  "routing"),
            ("Standard X", "dddd1111eeee2222ffff33334444aaaa", true,  "standard"),
            ("Command A",  p1,                                  true,  "command"),
            ("Command B",  p2,                                  true,  "command"),
            ("Disabled C", "eeee1111ffff222233334444aaaabbbb", false, "command"),
            ("Admin X",    "ffff1111aaaa2222bbbb3333cccc4444", true,  "adminOnly"),
        ])
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        let names = Set(got.map { $0.name })
        try expect(names == ["Command A", "Command B"],
                   "only enabled `.command` rows; got \(names.sorted())")
        try expect(got.count == 2, "exactly 2, got \(got.count)")
    }

    await test("W3 provider: a row with NO visibility key ⇒ .standard ⇒ excluded from palette") {
        let suite = "kup.solutions.notion-bridge.cmd-ux.w3b.\(UUID().uuidString)"
        let legacy: [[String: Any]] = [
            ["name": "NoVis", "notionPageId": "aaaa1111bbbb2222cccc3333dddd4444", "enabled": true]
        ]
        UserDefaults(suiteName: suite)!.set(
            try JSONSerialization.data(withJSONObject: legacy),
            forKey: BridgeDefaults.skills)
        let got = await RegistrySkillsCommandProvider(
            suiteName: suite, storageKey: BridgeDefaults.skills).descriptors()
        try expect(got.isEmpty,
                   "a visibility-less legacy row defaults to .standard ⇒ NOT a palette command, got \(got.map { $0.name })")
    }

    // ── Per-row picker write-back persists `visibility` ───────────────
    await test("W3 SkillsManager.setVisibility persists `.command` (picker write-back round-trips)") {
        // The per-row picker's set: closure is exactly
        // `skillsManager.setVisibility(named:to:)`. Drive that and prove
        // the new value is persisted + reloaded (the picker is the only
        // GUI; the persistence it triggers is the headless contract).
        let mgrName = "kup.solutions.notion-bridge.cmd-ux.w3pick.\(UUID().uuidString)"
        // SkillsManager persists to UserDefaults.standard; isolate by
        // snapshot+restore of the shared key so this is hermetic.
        let key = BridgeDefaults.skills
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        _ = mgrName
        let (added, persistedVis, reloadedVis): (Bool, SkillVisibility?, SkillVisibility?) =
            await MainActor.run {
                let m = SkillsManager()
                // start from a clean registry
                m.resetToDefaults()
                let ok = m.addSkill(name: "Picker Skill",
                                    notionPageId: "aaaa1111bbbb2222cccc3333dddd4444",
                                    visibility: .standard)
                // The exact per-row picker write-back call:
                _ = m.setVisibility(named: "Picker Skill", to: .command)
                let inMemory = m.skill(named: "Picker Skill")?.visibility
                // Prove it PERSISTED: a fresh manager reloads from disk.
                let m2 = SkillsManager()
                let reloaded = m2.skill(named: "Picker Skill")?.visibility
                return (ok, inMemory, reloaded)
            }
        try expect(added, "skill added")
        try expect(persistedVis == .command, "in-memory visibility updated to .command")
        try expect(reloadedVis == .command,
                   "the picker write-back must PERSIST .command (a fresh SkillsManager reloads it), got \(String(describing: reloadedVis))")
    }

    // ── CommandPaletteEmptyState — pure empty-vs-hint decision ─────────
    await test("W3 empty-state: zero commands ⇒ .hint with the mark-a-skill copy") {
        let s = CommandPaletteEmptyState.decide(commandCount: 0)
        try expect(s == .hint(message: CommandPalettePresenter.emptyRegistryMessage),
                   "zero commands ⇒ the inline hint, got \(s)")
        try expect(s.hintMessage == "No commands yet — mark a skill as Command in Settings → Commands",
                   "exact Q1=b copy, got \(String(describing: s.hintMessage))")
    }

    await test("W3 empty-state: ≥1 command ⇒ .hasCommands (render the list, no hint)") {
        for n in [1, 2, 50] {
            let s = CommandPaletteEmptyState.decide(commandCount: n)
            try expect(s == .hasCommands, "count \(n) ⇒ render the list")
            try expect(s.hintMessage == nil, "no hint when commands exist")
        }
    }

    await test("W3 empty-state: a negative/garbage count is treated as empty (defensive)") {
        let s = CommandPaletteEmptyState.decide(commandCount: -3)
        try expect(s.hintMessage != nil, "a non-positive count shows the hint, not a blank list")
    }
}
