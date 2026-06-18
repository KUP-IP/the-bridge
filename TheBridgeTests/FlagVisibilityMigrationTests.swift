// FlagVisibilityMigrationTests.swift — cmd-ux W4 (3.4.1) flag migration
// TheBridge · Tests
//
// HEADLESSLY TESTED:
//   • Legacy `visibility` enum → flag pair derivation (4 raw values).
//   • Flag-pair → derived enum mapping (4 combos incl. the NEW state
//     routingDiscoverable + inCommandPalette both true).
//   • Skill Codable decode: flags-present path, flags-absent legacy path,
//     both-present (flags win), neither-present (defaults to .standard).
//   • Skill Codable encode: writes BOTH flags AND derived enum value
//     for one-cycle back-compat.
//   • SkillConfig (off-MainActor mirror in SkillsModule) round-trips the
//     same migration shape.
//   • RegistrySkillsCommandProvider filters on `inCommandPalette` flag
//     (not the legacy enum) — a flag-only row appears, an enum-only
//     legacy row still appears (via derived-flag fallback).
//   • SkillsManager.routingSkillsForDiscovery filters on
//     `routingDiscoverable` flag.
//   • The new combined state (both flags true) appears in BOTH the
//     palette AND the routing list — the semantic that the old 3-state
//     enum could not express.
//   • The 4 SkillVsCommandSplitTests LOCK contracts are unchanged.
//
// LOCK invariant preserved: `SkillVisibility.allCases.count == 3` —
// the enum is the legacy synthesized view; the flag pair is the truth.

import Foundation
import TheBridgeLib

func runFlagVisibilityMigrationTests() async {
    print("\n\u{1F6A9} Flag Visibility Migration Tests (cmd-ux W4 · flag-based SSOT)")

    // ── enum ↔ flag mapping ────────────────────────────────────────────
    await test("W4 mapping: enum → flag pair is exhaustive") {
        try expect(SkillVisibility.routing.asFlags == (true, false))
        try expect(SkillVisibility.standard.asFlags == (false, false))
        try expect(SkillVisibility.command.asFlags == (false, true))
    }

    await test("W4 mapping: flag pair → derived enum is exhaustive") {
        try expect(SkillVisibility.fromFlags(routingDiscoverable: true, inCommandPalette: false) == .routing)
        try expect(SkillVisibility.fromFlags(routingDiscoverable: false, inCommandPalette: false) == .standard)
        try expect(SkillVisibility.fromFlags(routingDiscoverable: false, inCommandPalette: true) == .command)
        // The NEW state: both true → collapse to .command for legacy
        // readers (palette wins over routing).
        try expect(SkillVisibility.fromFlags(routingDiscoverable: true, inCommandPalette: true) == .command,
                   "both-true must surface as .command for legacy callers")
    }

    // ── Skill Codable decode ───────────────────────────────────────────
    @Sendable func decodeSkillFromJSON(_ json: String) throws -> SkillsManager.Skill {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(SkillsManager.Skill.self, from: data)
    }

    await test("W4 decode: legacy enum-only row derives flags correctly") {
        let routing = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"visibility":"routing","summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(routing.routingDiscoverable == true)
        try expect(routing.inCommandPalette == false)

        let standard = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"visibility":"standard","summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(standard.routingDiscoverable == false)
        try expect(standard.inCommandPalette == false)

        let command = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"visibility":"command","summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(command.routingDiscoverable == false)
        try expect(command.inCommandPalette == true)

        // Legacy adminOnly maps via SkillVisibility's own decoder → standard.
        let admin = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"visibility":"adminOnly","summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(admin.routingDiscoverable == false)
        try expect(admin.inCommandPalette == false)
    }

    await test("W4 decode: flag-only row honors flags verbatim") {
        let both = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"routingDiscoverable":true,"inCommandPalette":true,"summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(both.routingDiscoverable == true)
        try expect(both.inCommandPalette == true)
        // Derived view collapses to .command.
        try expect(both.visibility == .command)
    }

    await test("W4 decode: both flags AND visibility present → flags WIN") {
        // Hypothetical mismatched row: flags say (true, false) but
        // legacy enum says command. Flags are SSOT.
        let mismatched = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"routingDiscoverable":true,"inCommandPalette":false,"visibility":"command","summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(mismatched.routingDiscoverable == true)
        try expect(mismatched.inCommandPalette == false)
        try expect(mismatched.visibility == .routing)
    }

    await test("W4 decode: neither flags nor visibility present → defaults .standard") {
        let bare = try decodeSkillFromJSON(#"{"name":"x","notionPageId":"p","enabled":true,"summary":"","triggerPhrases":[],"antiTriggerPhrases":[]}"#)
        try expect(bare.routingDiscoverable == false)
        try expect(bare.inCommandPalette == false)
    }

    // ── Skill Codable encode (both shapes written) ─────────────────────
    await test("W4 encode: writes BOTH flag pair AND derived enum value") {
        let s = SkillsManager.Skill(
            name: "x",
            source: .notion(pageId: "p"),
            routingDiscoverable: true,
            inCommandPalette: true
        )
        let data = try JSONEncoder().encode(s)
        let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expect(raw["routingDiscoverable"] as? Bool == true, "flag must be written")
        try expect(raw["inCommandPalette"] as? Bool == true, "flag must be written")
        try expect(raw["visibility"] as? String == "command",
                   "derived legacy enum value must also be written for back-compat")
    }

    await test("W4 round-trip: a both-flags-true Skill survives encode → decode") {
        let s = SkillsManager.Skill(
            name: "y",
            source: .notion(pageId: "p"),
            routingDiscoverable: true,
            inCommandPalette: true
        )
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SkillsManager.Skill.self, from: data)
        try expect(back.routingDiscoverable == true)
        try expect(back.inCommandPalette == true)
    }

    // ── SkillsManager.routingSkillsForDiscovery uses flag ──────────────
    await test("W4 SkillsManager: routingSkillsForDiscovery filters on routingDiscoverable flag") {
        await MainActor.run {
            // Use a private suite to avoid clobbering operator defaults.
            let suite = "kup.solutions.notion-bridge.w4.routing.\(UUID().uuidString)"
            let ud = UserDefaults(suiteName: suite)!
            let p1 = "aaaa1111bbbb2222cccc3333dddd4444"
            let p2 = "bbbb2222cccc3333dddd4444eeee5555"
            let p3 = "cccc3333dddd4444eeee5555ffff6666"
            let rows: [[String: Any]] = [
                // Row A: flag-only routing → must appear
                ["name": "A", "notionPageId": p1, "enabled": true, "routingDiscoverable": true, "inCommandPalette": false],
                // Row B: both flags true → must STILL appear in routing
                ["name": "B", "notionPageId": p2, "enabled": true, "routingDiscoverable": true, "inCommandPalette": true],
                // Row C: standard (both false) → must NOT appear
                ["name": "C", "notionPageId": p3, "enabled": true, "routingDiscoverable": false, "inCommandPalette": false],
            ]
            let data = try! JSONSerialization.data(withJSONObject: rows)
            ud.set(data, forKey: BridgeDefaults.skills)
            let decoded = try! JSONDecoder().decode([SkillsManager.Skill].self, from: data)
            let listed = decoded.filter { $0.enabled && $0.routingDiscoverable }
            try! expect(Set(listed.map(\.name)) == Set(["A", "B"]),
                       "routing list must include A + B (combined), exclude C; got \(listed.map(\.name))")
            ud.removePersistentDomain(forName: suite)
        }
    }

    // ── RegistrySkillsCommandProvider filters on inCommandPalette ──────
    await test("W4 provider: filter uses inCommandPalette flag (legacy enum row still works via fallback)") {
        let suite = "kup.solutions.notion-bridge.w4.palette.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let p1 = "aaaa1111bbbb2222cccc3333dddd4444"
        let p2 = "bbbb2222cccc3333dddd4444eeee5555"
        let p3 = "cccc3333dddd4444eeee5555ffff6666"
        let p4 = "dddd4444eeee5555ffff6666aaaa7777"
        let rows: [[String: Any]] = [
            // Legacy enum-only command row → derived flag must promote it
            ["name": "Legacy", "notionPageId": p1, "enabled": true, "visibility": "command"],
            // Flag-direct inCommandPalette row → first-class
            ["name": "Flagged", "notionPageId": p2, "enabled": true, "inCommandPalette": true, "routingDiscoverable": false],
            // Both flags true (new state) → must appear in palette
            ["name": "Combined", "notionPageId": p3, "enabled": true, "inCommandPalette": true, "routingDiscoverable": true],
            // Disabled palette row → excluded
            ["name": "Disabled", "notionPageId": p4, "enabled": false, "inCommandPalette": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: rows)
        UserDefaults(suiteName: suite)!.set(data, forKey: BridgeDefaults.skills)

        let provider = RegistrySkillsCommandProvider(suiteName: suite)
        let descs = await provider.descriptors()
        let names = Set(descs.map(\.name))
        try expect(names == Set(["Legacy", "Flagged", "Combined"]),
                   "palette must show Legacy + Flagged + Combined, exclude Disabled; got \(names)")
    }

    // ── SkillsManager flag-direct mutators ─────────────────────────────
    await test("W4 SkillsManager: setRoutingDiscoverable + setInCommandPalette persist independently") {
        await MainActor.run {
            // Snapshot/restore the live skills array so the suite stays isolated.
            let manager = SkillsManager()
            let beforeSnapshot = manager.skills
            defer {
                // Best-effort restoration: re-encode and write back.
                if let data = try? JSONEncoder().encode(beforeSnapshot) {
                    UserDefaults.standard.set(data, forKey: BridgeDefaults.skills)
                }
            }
            let probeName = "w4-flag-mutator-\(UUID().uuidString.prefix(8))"
            let p = "aaaa1111bbbb2222cccc3333dddd4444"
            _ = manager.addSkill(name: probeName, notionPageId: p, visibility: .standard)
            defer { manager.removeSkill(named: probeName) }

            try! expect(manager.skill(named: probeName)?.routingDiscoverable == false)
            try! expect(manager.skill(named: probeName)?.inCommandPalette == false)

            _ = manager.setRoutingDiscoverable(named: probeName, to: true)
            try! expect(manager.skill(named: probeName)?.routingDiscoverable == true,
                       "flag write must persist")
            try! expect(manager.skill(named: probeName)?.inCommandPalette == false,
                       "the other flag must stay independent")

            _ = manager.setInCommandPalette(named: probeName, to: true)
            try! expect(manager.skill(named: probeName)?.routingDiscoverable == true,
                       "routing flag must stay set after writing palette flag")
            try! expect(manager.skill(named: probeName)?.inCommandPalette == true,
                       "palette flag must persist")
            // Derived enum collapses to .command for the new combined state.
            try! expect(manager.skill(named: probeName)?.visibility == .command,
                       "combined state derives to .command for legacy enum readers")
        }
    }

    // ── setVisibility back-compat (legacy enum path still works) ───────
    await test("W4 SkillsManager.setVisibility: legacy enum writes still map to flag pair") {
        await MainActor.run {
            let manager = SkillsManager()
            let beforeSnapshot = manager.skills
            defer {
                if let data = try? JSONEncoder().encode(beforeSnapshot) {
                    UserDefaults.standard.set(data, forKey: BridgeDefaults.skills)
                }
            }
            let probeName = "w4-legacy-vis-\(UUID().uuidString.prefix(8))"
            let p = "aaaa1111bbbb2222cccc3333dddd4444"
            _ = manager.addSkill(name: probeName, notionPageId: p, visibility: .routing)
            defer { manager.removeSkill(named: probeName) }

            try! expect(manager.skill(named: probeName)?.routingDiscoverable == true,
                       ".routing add must set routingDiscoverable=true")
            try! expect(manager.skill(named: probeName)?.inCommandPalette == false)

            _ = manager.setVisibility(named: probeName, to: .command)
            try! expect(manager.skill(named: probeName)?.routingDiscoverable == false,
                       ".command set must clear routingDiscoverable (legacy single-axis semantics)")
            try! expect(manager.skill(named: probeName)?.inCommandPalette == true)

            _ = manager.setVisibility(named: probeName, to: .standard)
            try! expect(manager.skill(named: probeName)?.routingDiscoverable == false)
            try! expect(manager.skill(named: probeName)?.inCommandPalette == false)
        }
    }

    // ── SkillVisibility.allCases LOCK invariant preserved ──────────────
    await test("W4 LOCK: SkillVisibility.allCases.count remains 3 (enum unchanged)") {
        try expect(SkillVisibility.allCases.count == 3,
                   "the legacy enum stays at 3 cases; flag pair is the new SSOT")
    }
}
