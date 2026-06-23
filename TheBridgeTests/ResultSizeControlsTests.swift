// ResultSizeControlsTests.swift — fb-resultsize (result-size / token-cap controls)
// TheBridge · Tests
//
// Evidence (05-20/22, 05-29, 06-02): large tool results blow token caps and
// spill to disk. This suite locks the three fb-resultsize mitigations:
//
//   (1) fetch_skill `section` selector — a pure markdown heading slicer for
//       granular / partial fetch, plus the file-source envelope post-process
//       (`applySectionToEnvelope`-equivalent behaviour exercised via the
//       public `extractMarkdownSection`).
//   (2) notion_query PROJECT-relation server-side filter (`NotionRelationFilter`)
//       so a PACKETS-by-PROJECT query returns inline instead of dumping the
//       whole data source — incl. AND-merge with an existing filter.
//   (3) calendar_events compact mode + `limit` cap with an honest
//       has_more/truncated signal, driven off the injectable mock store.
//
// ZERO network / ZERO live EventKit — every helper is pure, and the calendar
// handler runs against the in-memory MockCalendarStore (CalendarModuleTests).

import Foundation
import MCP
import TheBridgeLib

func runResultSizeControlsTests() async {
    print("\n\u{1F4CF} ResultSizeControls Tests (fb-resultsize · token-cap controls)")

    // ============================================================
    // MARK: (1) fetch_skill section selector — extractMarkdownSection
    // ============================================================

    let doc = """
    # Overview

    Top intro.

    ## Setup

    Setup line one.
    Setup line two.

    ### Prereqs

    A nested prereq.

    ## Usage

    Use it like so.

    ## Teardown

    Clean up.
    """

    await test("fb-resultsize (1): section returns only the named heading slice") {
        let slice = SkillsModule.extractMarkdownSection(doc, section: "Setup")
        guard let slice else { throw TestError.assertion("expected a Setup slice, got nil") }
        try expect(slice.hasPrefix("## Setup"), "slice should start at the heading; got: \(slice)")
        try expect(slice.contains("Setup line one."), "missing section body")
        try expect(!slice.contains("Use it like so."), "leaked the sibling Usage section")
        try expect(!slice.contains("Top intro."), "leaked the preceding Overview section")
    }

    await test("fb-resultsize (1): nested subsection is included in the parent slice") {
        let slice = SkillsModule.extractMarkdownSection(doc, section: "Setup") ?? ""
        try expect(slice.contains("### Prereqs"), "deeper subsection should stay with parent")
        try expect(slice.contains("A nested prereq."), "missing nested body")
        // The next SAME-level heading (## Usage) must terminate the slice.
        try expect(!slice.contains("## Usage"), "slice ran past the sibling heading")
    }

    await test("fb-resultsize (1): matching is case-insensitive and '#'-agnostic") {
        let a = SkillsModule.extractMarkdownSection(doc, section: "usage")
        let b = SkillsModule.extractMarkdownSection(doc, section: "  USAGE  ")
        try expect(a != nil && b != nil, "case/whitespace-insensitive match failed")
        try expect((a ?? "").contains("Use it like so."), "wrong section matched")
        try expect(a == b, "case/whitespace variants should resolve identically")
    }

    await test("fb-resultsize (1): no match → nil (caller falls back to full body)") {
        try expect(SkillsModule.extractMarkdownSection(doc, section: "Nonexistent") == nil,
                   "unknown heading must return nil, not an empty/wrong slice")
    }

    await test("fb-resultsize (1): empty section name → nil (no-op)") {
        try expect(SkillsModule.extractMarkdownSection(doc, section: "   ") == nil,
                   "blank section name must be a no-op")
    }

    await test("fb-resultsize (1): a deeper heading does NOT terminate a shallower slice early") {
        // 'Overview' (H1) should swallow everything up to the next H1 — here
        // there is none, so the H2/H3 below are all part of it. But 'Setup'
        // (H2) must stop at the next H2 ('Usage'). This guards the level math.
        let overview = SkillsModule.extractMarkdownSection(doc, section: "Overview") ?? ""
        try expect(overview.contains("## Setup"), "H1 slice should contain its H2 children")
        try expect(overview.contains("## Teardown"), "H1 slice should run to end (no later H1)")
    }

    await test("fb-resultsize (1): code-fence '#' comments are not treated as headings") {
        let withFence = """
        ## Real

        ```sh
        # not a heading, just a shell comment
        echo hi
        ```

        After.
        """
        // The slice for 'Real' should include the whole fenced block + After.
        let slice = SkillsModule.extractMarkdownSection(withFence, section: "Real") ?? ""
        try expect(slice.contains("echo hi"), "fence body dropped")
        try expect(slice.contains("After."), "slice ended early on a fenced comment")
        // And the comment line is NOT itself addressable as a section.
        let fencedAsSection = SkillsModule.extractMarkdownSection(withFence, section: "not a heading, just a shell comment")
        try expect(fencedAsSection == nil, "a fenced '#' line must not register as a heading")
    }

    // ============================================================
    // MARK: (2) notion_query PROJECT-relation server-side filter
    // ============================================================

    func parseJSONObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    await test("fb-resultsize (2): relationContains builds the Notion predicate shape") {
        let p = NotionRelationFilter.relationContains(property: "Project", pageId: "pid-1")
        try expect(p["property"] as? String == "Project", "wrong property")
        let rel = p["relation"] as? [String: Any]
        try expect(rel?["contains"] as? String == "pid-1", "wrong relation.contains value")
    }

    await test("fb-resultsize (2): merge with NO existing filter → bare relation predicate") {
        let merged = NotionRelationFilter.merge(existingJSON: nil, property: "Project", pageId: "pid-1")
        try expect(merged["property"] as? String == "Project", "should be the bare predicate")
        try expect(merged["and"] == nil, "should not wrap in `and` when nothing to merge")
    }

    await test("fb-resultsize (2): merge with an `and` filter APPENDS the relation predicate") {
        let existing = #"{"and":[{"property":"Status","status":{"equals":"Active"}}]}"#
        let merged = NotionRelationFilter.merge(existingJSON: existing, property: "Project", pageId: "pid-1")
        guard let andArr = merged["and"] as? [[String: Any]] else {
            throw TestError.assertion("expected an `and` array, got: \(merged)")
        }
        try expect(andArr.count == 2, "expected 2 predicates after append, got \(andArr.count)")
        let hasStatus = andArr.contains { ($0["property"] as? String) == "Status" }
        let hasProject = andArr.contains { ($0["property"] as? String) == "Project" }
        try expect(hasStatus && hasProject, "both original + relation predicates must survive")
    }

    await test("fb-resultsize (2): merge with a single (non-`and`) filter WRAPS both in `and`") {
        let existing = #"{"property":"Status","status":{"equals":"Active"}}"#
        let merged = NotionRelationFilter.merge(existingJSON: existing, property: "Project", pageId: "pid-1")
        guard let andArr = merged["and"] as? [[String: Any]] else {
            throw TestError.assertion("expected a wrapping `and`, got: \(merged)")
        }
        try expect(andArr.count == 2, "expected the existing + relation predicate")
    }

    await test("fb-resultsize (2): mergeData serializes to valid filter JSON") {
        let data = NotionRelationFilter.mergeData(existingJSON: nil, property: "Project", pageId: "pid-1")
        let obj = parseJSONObject(data)
        try expect(obj?["property"] as? String == "Project", "mergeData round-trip failed: \(String(describing: obj))")
    }

    await test("fb-resultsize (2): empty existing filter string is treated as none") {
        let merged = NotionRelationFilter.merge(existingJSON: "   ", property: "Project", pageId: "pid-1")
        try expect(merged["and"] == nil && merged["property"] as? String == "Project",
                   "whitespace filter should degrade to the bare predicate")
    }

    // ============================================================
    // MARK: (3) calendar_events compact mode + limit cap
    // ============================================================

    func makeRouter(_ store: CalendarStoring) async -> ToolRouter {
        let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
        await CalendarModule.register(on: router, store: store)
        return router
    }
    func callEvents(_ router: ToolRouter, _ args: Value) async throws -> Value {
        let regs = await router.registrations(forModule: "calendar")
        guard let reg = regs.first(where: { $0.name == "calendar_events" }) else {
            throw TestError.assertion("calendar_events not registered")
        }
        return try await reg.handler(args)
    }
    func field(_ v: Value, _ k: String) -> Value? {
        if case .object(let d) = v { return d[k] }
        return nil
    }

    await test("fb-resultsize (3): compact mode trims each event to id/title/start/end") {
        let store = MockCalendarStore()
        let router = await makeRouter(store)
        let createReg = await router.registrations(forModule: "calendar").first { $0.name == "calendar_create" }!
        _ = try await createReg.handler(.object([
            "title": .string("Standup"),
            "start": .string("2026-06-01T09:00:00Z"),
            "end": .string("2026-06-01T09:15:00Z"),
            "location": .string("Zoom"),
            "notes": .string("daily")
        ]))
        let result = try await callEvents(router, .object([
            "start": .string("2026-06-01T00:00:00Z"),
            "end": .string("2026-06-02T00:00:00Z"),
            "compact": .bool(true)
        ]))
        guard case .array(let events)? = field(result, "events"), let first = events.first,
              case .object(let ev) = first else {
            throw TestError.assertion("missing events array")
        }
        try expect(ev["id"] != nil && ev["title"] != nil && ev["start"] != nil && ev["end"] != nil,
                   "compact event missing core keys")
        try expect(ev["location"] == nil && ev["notes"] == nil && ev["calendar"] == nil && ev["allDay"] == nil,
                   "compact event leaked verbose keys: \(ev.keys.sorted())")
    }

    await test("fb-resultsize (3): non-compact still returns the full event shape") {
        let store = MockCalendarStore()
        let router = await makeRouter(store)
        let createReg = await router.registrations(forModule: "calendar").first { $0.name == "calendar_create" }!
        _ = try await createReg.handler(.object([
            "title": .string("Review"),
            "start": .string("2026-06-01T10:00:00Z"),
            "end": .string("2026-06-01T11:00:00Z"),
            "location": .string("Room 1")
        ]))
        let result = try await callEvents(router, .object([
            "start": .string("2026-06-01T00:00:00Z"),
            "end": .string("2026-06-02T00:00:00Z")
        ]))
        guard case .array(let events)? = field(result, "events"), let first = events.first,
              case .object(let ev) = first else {
            throw TestError.assertion("missing events array")
        }
        try expect(ev["calendar"] != nil && ev["allDay"] != nil && ev["location"] != nil,
                   "full shape should retain verbose keys")
    }

    await test("fb-resultsize (3): limit caps the result set and flags has_more/truncated") {
        let store = MockCalendarStore()
        let router = await makeRouter(store)
        let createReg = await router.registrations(forModule: "calendar").first { $0.name == "calendar_create" }!
        for i in 0..<5 {
            let hour = String(format: "%02d", 9 + i)
            _ = try await createReg.handler(.object([
                "title": .string("Evt \(i)"),
                "start": .string("2026-06-01T\(hour):00:00Z"),
                "end": .string("2026-06-01T\(hour):30:00Z")
            ]))
        }
        let result = try await callEvents(router, .object([
            "start": .string("2026-06-01T00:00:00Z"),
            "end": .string("2026-06-02T00:00:00Z"),
            "limit": .int(2)
        ]))
        guard case .int(let count)? = field(result, "count") else {
            throw TestError.assertion("missing count")
        }
        try expect(count == 2, "limit not applied; got \(count)")
        if case .bool(let more)? = field(result, "has_more") {
            try expect(more, "has_more should be true when truncated")
        } else {
            throw TestError.assertion("has_more flag missing on a truncated result")
        }
        if case .int(let total)? = field(result, "totalInRange") {
            try expect(total == 5, "totalInRange should report the full count, got \(total)")
        } else {
            throw TestError.assertion("totalInRange missing on a truncated result")
        }
    }

    await test("fb-resultsize (3): no truncation → no has_more/truncated noise") {
        let store = MockCalendarStore()
        let router = await makeRouter(store)
        let createReg = await router.registrations(forModule: "calendar").first { $0.name == "calendar_create" }!
        _ = try await createReg.handler(.object([
            "title": .string("Solo"),
            "start": .string("2026-06-01T09:00:00Z"),
            "end": .string("2026-06-01T09:30:00Z")
        ]))
        let result = try await callEvents(router, .object([
            "start": .string("2026-06-01T00:00:00Z"),
            "end": .string("2026-06-02T00:00:00Z"),
            "limit": .int(50)
        ]))
        try expect(field(result, "has_more") == nil, "has_more should be omitted when nothing was dropped")
        try expect(field(result, "truncated") == nil, "truncated should be omitted when nothing was dropped")
    }
}
