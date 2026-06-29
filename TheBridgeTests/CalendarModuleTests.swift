// CalendarModuleTests.swift
// TheBridge · Tests
//
// PKT-962 (v3.7·I): unit tests for the calendar_* tool family against the
// injectable `CalendarStoring` seam — no live EventKit / TCC. Covers tool
// registration + tiering, CRUD round-trips, date-range filtering, and the
// access-denied path. Handlers are invoked directly off their
// `ToolRegistration` so dispatch (security gate / license / UserDefaults)
// stays out of the unit boundary — the seam is what's under test. Mirrors
// RemindersModuleTests (PKT-957), the v3.7·D template this packet reuses.

import Foundation
import MCP
import TheBridgeLib

// MARK: - In-memory mock seam

/// Deterministic in-memory `CalendarStoring` for tests. `authStatus` drives
/// the access-denied branch; the dictionaries model calendars + events. The
/// range filter is implemented exactly as the production EventKit predicate
/// behaves: an event overlaps [start, end] when its start < query.end AND its
/// end > query.start.
final class MockCalendarStore: CalendarStoring, @unchecked Sendable {
    var authStatus: CalendarAuthStatus
    private(set) var cals: [CalendarInfo]
    private(set) var items: [String: CalendarEvent] = [:]
    private var seq = 0

    init(authStatus: CalendarAuthStatus = .authorized, calendars: [CalendarInfo]? = nil) {
        self.authStatus = authStatus
        self.cals = calendars ?? [
            CalendarInfo(id: "cal-home", title: "Home", isDefault: true, allowsModify: true),
            CalendarInfo(id: "cal-work", title: "Work", isDefault: false, allowsModify: true)
        ]
    }

    func authorizationStatus() -> CalendarAuthStatus { authStatus }

    func ensureAccess() async throws {
        switch authStatus {
        case .authorized: return
        case .notDetermined, .denied, .restricted:
            throw CalendarModuleError.accessDenied
        }
    }

    func calendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        return cals
    }

    private func calTitle(_ id: String) -> String {
        cals.first(where: { $0.id == id })?.title ?? ""
    }

    func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent] {
        try await ensureAccess()
        var out = Array(items.values)
        if let calId = query.calendarId {
            guard cals.contains(where: { $0.id == calId }) else {
                throw CalendarModuleError.calendarNotFound(calId)
            }
            out = out.filter { $0.calendarId == calId }
        }
        // Overlap test (string ISO-8601 compares lexicographically when
        // zero-padded + same offset — the harness uses Z-suffixed times).
        out = out.filter { $0.start < query.end && $0.end > query.start }
        return out.sorted { $0.start < $1.start }
    }

    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        let calId = draft.calendarId ?? "cal-home"
        guard cals.contains(where: { $0.id == calId }) else {
            throw CalendarModuleError.calendarNotFound(calId)
        }
        guard let start = draft.start else { throw CalendarModuleError.missingRequired("start") }
        guard let end = draft.end else { throw CalendarModuleError.missingRequired("end") }
        seq += 1
        let id = "evt-\(seq)"
        let event = CalendarEvent(
            id: id,
            title: draft.title ?? "",
            start: start,
            end: end,
            allDay: draft.allDay ?? false,
            calendarId: calId,
            calendarTitle: calTitle(calId),
            location: draft.location,
            notes: draft.notes
        )
        items[id] = event
        return event
    }

    func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        guard var event = items[id] else { throw CalendarModuleError.notFound(id) }
        if let t = draft.title { event.title = t }
        if let s = draft.start { event.start = s }
        if let e = draft.end { event.end = e }
        if let a = draft.allDay { event.allDay = a }
        if let loc = draft.location { event.location = loc }
        if let n = draft.notes { event.notes = n }
        if let c = draft.calendarId {
            guard cals.contains(where: { $0.id == c }) else {
                throw CalendarModuleError.calendarNotFound(c)
            }
            event.calendarId = c
            event.calendarTitle = calTitle(c)
        }
        items[id] = event
        return event
    }

    func delete(id: String) async throws {
        try await ensureAccess()
        guard items[id] != nil else { throw CalendarModuleError.notFound(id) }
        items[id] = nil
    }
}

// MARK: - Test helpers

private func makeCalendarRouter(_ store: CalendarStoring) async -> ToolRouter {
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await CalendarModule.register(on: router, store: store)
    return router
}

/// Invoke a tool's handler directly (bypasses dispatch gating — the seam is
/// the unit under test).
private func callCalendarHandler(_ router: ToolRouter, _ name: String, _ args: Value) async throws -> Value {
    let regs = await router.registrations(forModule: "calendar")
    guard let reg = regs.first(where: { $0.name == name }) else {
        throw TestError.assertion("tool \(name) not registered")
    }
    return try await reg.handler(args)
}

private func calField(_ v: Value, _ key: String) -> Value? {
    if case .object(let d) = v { return d[key] }
    return nil
}

func runCalendarModuleTests() async {
    print("\n\u{1F4C5} CalendarModule Tests (PKT-962 · v3.7·I)")

    // MARK: registration + tiering

    await test("CalendarModule registers exactly 5 tools") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let tools = await router.registrations(forModule: "calendar")
        try expect(tools.count == 5, "expected 5 calendar tools, got \(tools.count)")
    }

    await test("calendar tiering: list/events open, create/update notify, delete request") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let tools = await router.registrations(forModule: "calendar")
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expect(byName["calendar_list"]?.tier == .open, "list must be .open")
        try expect(byName["calendar_events"]?.tier == .open, "events must be .open")
        try expect(byName["calendar_create"]?.tier == .notify, "create must be .notify")
        try expect(byName["calendar_update"]?.tier == .notify, "update must be .notify")
        try expect(byName["calendar_delete"]?.tier == .request, "delete must be .request")
    }

    // MARK: calendar_list

    await test("calendar_list returns the seeded calendars with default flag") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let result = try await callCalendarHandler(router, "calendar_list", .object([:]))
        guard case .int(let count)? = calField(result, "count") else {
            throw TestError.assertion("missing count")
        }
        try expect(count == 2, "expected 2 calendars, got \(count)")
        guard case .array(let arr)? = calField(result, "calendars") else {
            throw TestError.assertion("missing calendars array")
        }
        let defaults = arr.filter { calField($0, "isDefault") == .bool(true) }
        try expect(defaults.count == 1, "exactly one default calendar expected")
    }

    // MARK: CRUD round-trip

    await test("calendar_create returns a new id + record") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let result = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Standup"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T09:30:00Z"),
            "location": .string("Zoom")
        ]))
        guard case .string(let id)? = calField(result, "id") else {
            throw TestError.assertion("create returned no id")
        }
        try expect(!id.isEmpty, "empty id")
        let rec = calField(result, "event")!
        try expect(calField(rec, "title") == .string("Standup"), "title mismatch")
        try expect(calField(rec, "start") == .string("2026-06-05T09:00:00Z"), "start mismatch")
        try expect(calField(rec, "end") == .string("2026-06-05T09:30:00Z"), "end mismatch")
        try expect(calField(rec, "location") == .string("Zoom"), "location mismatch")
        try expect(calField(rec, "calendar") == .string("Home"), "should default to Home calendar")
    }

    await test("calendar_create requires title, start, and end") {
        let router = await makeCalendarRouter(MockCalendarStore())
        // missing title
        do {
            _ = try await callCalendarHandler(router, "calendar_create", .object([
                "start": .string("2026-06-05T09:00:00Z"), "end": .string("2026-06-05T10:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing title")
        } catch is ToolRouterError { /* expected */ }
        // missing end
        do {
            _ = try await callCalendarHandler(router, "calendar_create", .object([
                "title": .string("x"), "start": .string("2026-06-05T09:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing end")
        } catch is ToolRouterError { /* expected */ }
    }

    await test("calendar_update mutates fields and can move calendars") {
        let store = MockCalendarStore()
        let router = await makeCalendarRouter(store)
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Draft"),
            "start": .string("2026-06-10T12:00:00Z"),
            "end": .string("2026-06-10T13:00:00Z")
        ]))
        guard case .string(let id)? = calField(created, "id") else { throw TestError.assertion("no id") }

        let updated = try await callCalendarHandler(router, "calendar_update", .object([
            "id": .string(id),
            "title": .string("Final review"),
            "start": .string("2026-06-10T14:00:00Z"),
            "end": .string("2026-06-10T15:00:00Z"),
            "calendarId": .string("cal-work")
        ]))
        let rec = calField(updated, "event")!
        try expect(calField(rec, "title") == .string("Final review"), "title not updated")
        try expect(calField(rec, "start") == .string("2026-06-10T14:00:00Z"), "start not updated")
        try expect(calField(rec, "calendar") == .string("Work"), "calendar not moved")
    }

    await test("calendar_update on a missing event surfaces notFound") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_update", .object([
                "id": .string("evt-nope"), "title": .string("ghost")
            ]))
            throw TestError.assertion("expected notFound")
        } catch let e as CalendarModuleError {
            try expect(e == .notFound("evt-nope"), "expected notFound, got \(e)")
        }
    }

    // MARK: date-range filter

    await test("calendar_events filters by date range (overlap semantics)") {
        let router = await makeCalendarRouter(MockCalendarStore())
        // June 5 morning event
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Inside"),
            "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        // June 20 event — outside the queried window
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Outside"),
            "start": .string("2026-06-20T09:00:00Z"),
            "end": .string("2026-06-20T10:00:00Z")
        ]))

        let result = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"),
            "end": .string("2026-06-06T00:00:00Z")
        ]))
        guard case .int(let n)? = calField(result, "count") else { throw TestError.assertion("no count") }
        try expect(n == 1, "expected 1 event in the June 5 window, got \(n)")
        guard case .array(let arr)? = calField(result, "events") else { throw TestError.assertion("no events array") }
        try expect(calField(arr[0], "title") == .string("Inside"), "wrong event returned")
    }

    await test("calendar_events scoped to a calendarId only returns that calendar's events") {
        let router = await makeCalendarRouter(MockCalendarStore())
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Home thing"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z"), "calendarId": .string("cal-home")
        ]))
        _ = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Work thing"), "start": .string("2026-06-05T11:00:00Z"),
            "end": .string("2026-06-05T12:00:00Z"), "calendarId": .string("cal-work")
        ]))
        let result = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"),
            "end": .string("2026-06-06T00:00:00Z"),
            "calendarId": .string("cal-work")
        ]))
        try expect(calField(result, "count") == .int(1), "expected 1 work event")
        guard case .array(let arr)? = calField(result, "events") else { throw TestError.assertion("no events array") }
        try expect(calField(arr[0], "title") == .string("Work thing"), "wrong scoped event")
    }

    await test("calendar_events requires start and end") {
        let router = await makeCalendarRouter(MockCalendarStore())
        do {
            _ = try await callCalendarHandler(router, "calendar_events", .object([
                "start": .string("2026-06-05T00:00:00Z")
            ]))
            throw TestError.assertion("expected invalidArguments for missing end")
        } catch is ToolRouterError { /* expected */ }
    }

    // MARK: naive ISO parsing (CalendarISOParsing)

    await test("CalendarISOParsing accepts timezone-qualified ISO-8601") {
        let date = try CalendarISOParsing.parse("2026-06-05T09:00:00Z")
        let iso = ISO8601DateFormatter().string(from: date)
        try expect(iso.hasPrefix("2026-06-05"), "parsed Z timestamp: \(iso)")
    }

    await test("CalendarISOParsing accepts naive local wall-clock timestamps") {
        let date = try CalendarISOParsing.parse("2026-06-03T14:30:00")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try expect(comps.year == 2026 && comps.month == 6 && comps.day == 3, "year/month/day")
        try expect(comps.hour == 14 && comps.minute == 30, "hour/minute in local TZ")
    }

    await test("CalendarISOParsing accepts date-only strings at local midnight") {
        let date = try CalendarISOParsing.parse("2026-06-03")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        try expect(comps.year == 2026 && comps.month == 6 && comps.day == 3, "date-only parse")
        try expect(comps.hour == 0 && comps.minute == 0, "date-only anchors local midnight")
    }

    await test("CalendarISOParsing rejects garbage input") {
        do {
            _ = try CalendarISOParsing.parse("not-a-date")
            throw TestError.assertion("expected invalidDate")
        } catch let e as CalendarModuleError {
            if case .invalidDate = e { return }
            throw TestError.assertion("expected invalidDate, got \(e)")
        }
    }

    // MARK: delete

    await test("calendar_delete removes the event (re-delete throws notFound)") {
        let router = await makeCalendarRouter(MockCalendarStore())
        let created = try await callCalendarHandler(router, "calendar_create", .object([
            "title": .string("Temp"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        guard case .string(let id)? = calField(created, "id") else { throw TestError.assertion("no id") }

        let del = try await callCalendarHandler(router, "calendar_delete", .object(["id": .string(id)]))
        try expect(calField(del, "deleted") == .bool(true), "delete should report true")

        // gone from the range query
        let listed = try await callCalendarHandler(router, "calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"), "end": .string("2026-06-06T00:00:00Z")
        ]))
        try expect(calField(listed, "count") == .int(0), "deleted event still listed")

        // re-delete surfaces a notFound (no silent success on a missing id)
        do {
            _ = try await callCalendarHandler(router, "calendar_delete", .object(["id": .string(id)]))
            throw TestError.assertion("expected notFound on re-delete")
        } catch let e as CalendarModuleError {
            try expect(e == .notFound(id), "expected notFound, got \(e)")
        }
    }

    // MARK: access-denied path

    await test("access-denied: every calendar tool surfaces accessDenied") {
        let store = MockCalendarStore(authStatus: .denied)
        let router = await makeCalendarRouter(store)

        func expectDenied(_ name: String, _ args: Value) async {
            await test("  \(name) → accessDenied when TCC denied") {
                do {
                    _ = try await callCalendarHandler(router, name, args)
                    throw TestError.assertion("expected accessDenied")
                } catch let e as CalendarModuleError {
                    try expect(e == .accessDenied, "expected accessDenied, got \(e)")
                }
            }
        }

        await expectDenied("calendar_list", .object([:]))
        await expectDenied("calendar_events", .object([
            "start": .string("2026-06-05T00:00:00Z"), "end": .string("2026-06-06T00:00:00Z")
        ]))
        await expectDenied("calendar_create", .object([
            "title": .string("x"), "start": .string("2026-06-05T09:00:00Z"),
            "end": .string("2026-06-05T10:00:00Z")
        ]))
        await expectDenied("calendar_update", .object(["id": .string("evt-1"), "title": .string("y")]))
        await expectDenied("calendar_delete", .object(["id": .string("evt-1")]))
    }

    await test("notDetermined status also throws accessDenied (no live TCC prompt in tests)") {
        let router = await makeCalendarRouter(MockCalendarStore(authStatus: .notDetermined))
        do {
            _ = try await callCalendarHandler(router, "calendar_list", .object([:]))
            throw TestError.assertion("expected accessDenied for notDetermined")
        } catch let e as CalendarModuleError {
            try expect(e == .accessDenied)
        }
    }
}
