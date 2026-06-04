// SpecialistRelationTests.swift — routing/specialist-relation (v3.7.4)
//
// Coverage for the specialist-relation plumbing fix: the routing surface
// now sources a parent skill's specialists from its curated `Specialist`
// RELATION property (verified live on the Keepr/Skills data source) instead
// of walking the parent's `child_page` blocks. The doc-page title heuristic
// (SpecialistFilter) survives only as a defensive secondary guard.
//
// What's covered here (all pure / hermetic — no network):
//   • NotionJSON.specialistRelationPropertyNames — the SSOT property name
//     is singular `Specialist`, plural accepted as a defensive alias.
//   • NotionJSON.extractSpecialistRelationIDs — reads relation ids in order,
//     case-insensitive on the property key, dedups, tolerates dashes,
//     ignores non-relation props, returns [] when absent/empty so callers
//     fall back to the child_page walk.
//   • Relation-preferred semantics: a parent page whose `Specialist`
//     relation lists curated ids resolves to THOSE ids (not its child_page
//     blocks); a parent with no relation yields [] (→ fallback).
//   • The 5 previously-unclassified specialist ids resolve to REAL
//     specialist pages (not doc-pages) and pass the SpecialistFilter guard.
//
// The full live hydration path (relation id → getPage → CachedSpecialist)
// runs through SkillsCacheWriter.ChildEnumerator.fetchChildren /
// SkillsModule.listNotionChildPages, both of which require a live
// NotionClient and so are exercised by integration, not unit tests. The
// pure extractor below is the unit seam that decides relation-vs-child.

import Foundation
import NotionBridgeLib

func runSpecialistRelationTests() async {
    print("\n\u{1F517} routing/specialist-relation (v3.7.4)")

    // -----------------------------------------------------------------
    // 1. Property name SSOT: singular `Specialist` is canonical, plural
    //    `Specialists` accepted defensively.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: canonical property name is singular 'Specialist'") {
        try expect(NotionJSON.specialistRelationPropertyNames.first == "Specialist",
                   "canonical name must be singular 'Specialist'")
        try expect(NotionJSON.specialistRelationPropertyNames.contains("Specialists"),
                   "plural 'Specialists' must be accepted as a defensive alias")
    }

    // -----------------------------------------------------------------
    // 2. Extract relation ids — happy path, declared order preserved.
    //    Mirrors the live people-keepr shape: `Specialist` relation with
    //    multiple related ids.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: extracts related ids in declared order") {
        let props: [String: Any] = [
            "Specialist": [
                "type": "relation",
                "relation": [
                    ["id": "0560e75f-6da7-4259-82fe-e1fb49158fcf"],
                    ["id": "f1728f25-391a-4ef9-9dd5-2fddee9aa266"],
                    ["id": "367cbb58-889e-81f9-9d83-fe122e3ec10b"]
                ]
            ]
        ]
        let ids = NotionJSON.extractSpecialistRelationIDs(from: props)
        try expect(ids == [
            "0560e75f-6da7-4259-82fe-e1fb49158fcf",
            "f1728f25-391a-4ef9-9dd5-2fddee9aa266",
            "367cbb58-889e-81f9-9d83-fe122e3ec10b"
        ], "ids must come back in declared relation order: \(ids)")
    }

    // -----------------------------------------------------------------
    // 3. Plural alias + case-insensitive property key match.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: plural alias + case-insensitive key resolve") {
        let plural: [String: Any] = [
            "Specialists": ["type": "relation", "relation": [["id": "aaaaaaaa-0000-0000-0000-000000000001"]]]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: plural) == ["aaaaaaaa-0000-0000-0000-000000000001"],
                   "plural 'Specialists' relation must resolve")

        let lowercased: [String: Any] = [
            "specialist": ["type": "relation", "relation": [["id": "bbbbbbbb-0000-0000-0000-000000000002"]]]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: lowercased) == ["bbbbbbbb-0000-0000-0000-000000000002"],
                   "a stray-casing 'specialist' key must still resolve (case-insensitive)")
    }

    // -----------------------------------------------------------------
    // 4. Dedup + dash/whitespace tolerance.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: dedups + tolerates dash/whitespace variants") {
        let props: [String: Any] = [
            "Specialist": [
                "type": "relation",
                "relation": [
                    ["id": "367cbb58-889e-81f9-9d83-fe122e3ec10b"],
                    ["id": " 367cbb58889e81f99d83fe122e3ec10b "],  // same id, undashed + padded
                    ["id": "f1728f25-391a-4ef9-9dd5-2fddee9aa266"]
                ]
            ]
        ]
        let ids = NotionJSON.extractSpecialistRelationIDs(from: props)
        try expect(ids.count == 2, "duplicate (dashed vs undashed) must collapse: \(ids)")
        try expect(ids.first == "367cbb58-889e-81f9-9d83-fe122e3ec10b",
                   "first occurrence wins (original form preserved)")
        try expect(ids.last == "f1728f25-391a-4ef9-9dd5-2fddee9aa266")
    }

    // -----------------------------------------------------------------
    // 5. Non-relation property of the same name is ignored (defensive:
    //    only a relation-typed `Specialist` counts).
    // -----------------------------------------------------------------
    await test("SpecialistRelation: non-relation 'Specialist' property is ignored") {
        let asRichText: [String: Any] = [
            "Specialist": ["type": "rich_text", "rich_text": [["plain_text": "not a relation"]]]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: asRichText).isEmpty,
                   "a rich_text 'Specialist' must not be read as a relation source")
    }

    // -----------------------------------------------------------------
    // 6. Absent / empty relation → [] so the caller falls back to the
    //    child_page walk rather than rendering zero specialists.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: absent or empty relation → [] (fallback signal)") {
        // Absent property entirely.
        let noProp: [String: Any] = [
            "Skill Name": ["type": "title", "title": [["plain_text": "FOCUS Keepr"]]]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: noProp).isEmpty,
                   "absent 'Specialist' property → []")

        // Present but empty relation array (a leaf specialist like close-event).
        let emptyRel: [String: Any] = [
            "Specialist": ["type": "relation", "relation": [[String: Any]]()]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: emptyRel).isEmpty,
                   "empty 'Specialist' relation → []")
    }

    // -----------------------------------------------------------------
    // 7. Relation-PREFERRED semantics: when a parent carries BOTH a
    //    populated `Specialist` relation AND (notionally) child pages, the
    //    extractor returns the curated relation ids — the relation is the
    //    primary source. (The child_page walk lives in the live enumerators
    //    and only runs when this returns [].)
    // -----------------------------------------------------------------
    await test("SpecialistRelation: populated relation is the primary source") {
        // Mirrors the live FOCUS Keepr `Specialist` relation (4 curated ids).
        let focusParent: [String: Any] = [
            "Skill Name": ["type": "title", "title": [["plain_text": "FOCUS Keepr"]]],
            "Specialist": [
                "type": "relation",
                "relation": [
                    ["id": "c57598ef-b059-4a17-bbe8-55a27b14e943"], // close-event
                    ["id": "aa3363b9-36a2-40d1-8d28-60e50c4306b4"], // retro
                    ["id": "d0925acd-d04c-4a15-b60f-c1c98245ff82"],
                    ["id": "23337454-5b9d-46ac-8ec6-e59ce084d094"]  // discourse
                ]
            ]
        ]
        let ids = NotionJSON.extractSpecialistRelationIDs(from: focusParent)
        try expect(ids.count == 4, "all four curated FOCUS specialists are sourced from the relation")
        try expect(ids.contains("c57598ef-b059-4a17-bbe8-55a27b14e943"))
        try expect(ids.contains("23337454-5b9d-46ac-8ec6-e59ce084d094"))
    }

    // -----------------------------------------------------------------
    // 8. The 5 previously-unclassified ids resolve to REAL specialist
    //    titles that PASS the defensive SpecialistFilter guard (i.e. they
    //    are not doc-pages). Titles confirmed live (2026-06-04):
    //      focus-keepr: close-event, retro, discourse
    //      notion-keepr: block-aura-create, bug-report
    //    All five are sibling database rows reachable only via the curated
    //    `Specialist` relation — the old child_page walk never saw them,
    //    which is exactly why they were "unresolved".
    // -----------------------------------------------------------------
    await test("SpecialistRelation: the 5 resolved ids are REAL specialists, not doc-pages") {
        let resolvedTitles = [
            "close-event",        // c57598ef — FOCUS, Orchestrator, v2.4.0
            "retro",              // aa3363b9 — System, Specialist, v2.0.1 (deprecated row, but a real skill)
            "discourse",          // 23337454 — FOCUS, Orchestrator, v0.6.0
            "block-aura-create",  // 9a4105d0 — FOCUS, Specialist, v3.0.1
            "bug-report"          // c629dc07 — System, Specialist, v2.1.0
        ]
        for title in resolvedTitles {
            try expect(SpecialistFilter.isSpecialist(title: title),
                       "resolved specialist '\(title)' must pass the defensive guard (REAL, not DOC)")
            try expect(!SpecialistFilter.isDocPage(title: title),
                       "resolved specialist '\(title)' must not be classified as a doc-page")
        }
    }

    // -----------------------------------------------------------------
    // 9. Defensive guard still bites: a doc-page that slips INTO the
    //    relation is excluded by SpecialistFilter even though the relation
    //    is the primary source (belt + suspenders). Confirms the relation
    //    + guard compose — the extractor surfaces the id, the guard drops
    //    the doc title at hydration time in the live enumerators.
    // -----------------------------------------------------------------
    await test("SpecialistRelation: doc-page title still excluded by the defensive guard") {
        // The relation extractor itself is title-agnostic (it only reads
        // ids), so it WILL return a doc-page's id if one is wired in…
        let pollutedParent: [String: Any] = [
            "Specialist": [
                "type": "relation",
                "relation": [
                    ["id": "11111111-1111-1111-1111-111111111111"],  // → would hydrate to a real specialist
                    ["id": "22222222-2222-2222-2222-222222222222"]   // → would hydrate to "NOTION Keepr Changelog"
                ]
            ]
        ]
        try expect(NotionJSON.extractSpecialistRelationIDs(from: pollutedParent).count == 2,
                   "extractor is title-agnostic: it returns every wired id")
        // …and the guard is what drops the doc title once hydrated.
        try expect(!SpecialistFilter.isSpecialist(title: "NOTION Keepr Changelog"),
                   "the defensive guard drops a doc-page that slipped into the relation")
        try expect(SpecialistFilter.isSpecialist(title: "bug-report"),
                   "while a real specialist in the same relation is kept")
    }
}
