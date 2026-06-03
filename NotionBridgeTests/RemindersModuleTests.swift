// RemindersModuleTests.swift
// NotionBridge · Tests
//
// PKT-957 (v3.7·D): unit tests for the reminders_* tool family against the
// injectable `RemindersStoring` seam — no live EventKit / TCC. Covers tool
// registration + tiering, CRUD round-trips, completion idempotency, and the
// access-denied path. Handlers are invoked directly off their
// `ToolRegistration` so dispatch (security gate / license / UserDefaults)
// stays out of the unit boundary — the seam is what's under test.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - In-memory mock seam

/// Deterministic in-memory `RemindersStoring` for tests. `authStatus` drives
/// the access-denied branch; the dictionaries model lists + reminders.
final class MockRemindersStore: RemindersStoring, @unchecked Sendable {
    var authStatus: RemindersAuthStatus
    private(set) var lists_: [ReminderList]
    private(set) var items: [String: ReminderItem] = [:]
    private var seq = 0

    init(authStatus: RemindersAuthStatus = .authorized, lists: [ReminderList]? = nil) {
        self.authStatus = authStatus
        self.lists_ = lists ?? [
            ReminderList(id: "list-default", title: "Reminders", isDefault: true, allowsModify: true),
            ReminderList(id: "list-work", title: "Work", isDefault: false, allowsModify: true)
        ]
    }

    func authorizationStatus() -> RemindersAuthStatus { authStatus }

    func ensureAccess() async throws {
        switch authStatus {
        case .authorized: return
        case .notDetermined, .denied, .restricted:
            throw RemindersModuleError.accessDenied
        }
    }

    func lists() async throws -> [ReminderList] {
        try await ensureAccess()
        return lists_
    }

    private func listTitle(_ id: String) -> String {
        lists_.first(where: { $0.id == id })?.title ?? ""
    }

    func fetch(_ query: ReminderQuery) async throws -> [ReminderItem] {
        try await ensureAccess()
        var out = Array(items.values)
        if let listId = query.listId {
            guard lists_.contains(where: { $0.id == listId }) else {
                throw RemindersModuleError.listNotFound(listId)
            }
            out = out.filter { $0.listId == listId }
        }
        if !query.includeCompleted { out = out.filter { !$0.completed } }
        if let before = query.dueBefore {
            out = out.filter { ($0.due.map { $0 < before }) ?? false }
        }
        if let after = query.dueAfter {
            out = out.filter { ($0.due.map { $0 > after }) ?? false }
        }
        return out.sorted { $0.id < $1.id }
    }

    func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        try await ensureAccess()
        let listId = draft.listId ?? "list-default"
        guard lists_.contains(where: { $0.id == listId }) else {
            throw RemindersModuleError.listNotFound(listId)
        }
        seq += 1
        let id = "rem-\(seq)"
        let item = ReminderItem(
            id: id,
            title: draft.title ?? "",
            due: (draft.due?.isEmpty == false) ? draft.due : nil,
            listId: listId,
            listTitle: listTitle(listId),
            completed: false,
            notes: draft.notes,
            priority: draft.priority ?? 0,
            url: (draft.url?.isEmpty == false) ? draft.url : nil,
            location: (draft.location?.isEmpty == false) ? draft.location : nil
        )
        items[id] = item
        return item
    }

    func update(id: String, _ draft: ReminderDraft) async throws -> ReminderItem {
        try await ensureAccess()
        guard var item = items[id] else { throw RemindersModuleError.notFound(id) }
        if let t = draft.title { item.title = t }
        if draft.clearDue { item.due = nil }
        else if let d = draft.due, !d.isEmpty { item.due = d }
        if let n = draft.notes { item.notes = n }
        if let p = draft.priority { item.priority = p }
        if let u = draft.url { item.url = u.isEmpty ? nil : u }
        if let loc = draft.location { item.location = loc.isEmpty ? nil : loc }
        if let l = draft.listId {
            guard lists_.contains(where: { $0.id == l }) else {
                throw RemindersModuleError.listNotFound(l)
            }
            item.listId = l
            item.listTitle = listTitle(l)
        }
        items[id] = item
        return item
    }

    func setCompleted(id: String, completed: Bool) async throws -> ReminderItem {
        try await ensureAccess()
        guard var item = items[id] else { throw RemindersModuleError.notFound(id) }
        item.completed = completed
        items[id] = item
        return item
    }

    func delete(id: String) async throws {
        try await ensureAccess()
        guard items[id] != nil else { throw RemindersModuleError.notFound(id) }
        items[id] = nil
    }
}

// MARK: - Test helpers

private func makeRouter(_ store: RemindersStoring) async -> ToolRouter {
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await RemindersModule.register(on: router, store: store)
    return router
}

/// Invoke a tool's handler directly (bypasses dispatch gating — the seam is
/// the unit under test).
private func callHandler(_ router: ToolRouter, _ name: String, _ args: Value) async throws -> Value {
    let regs = await router.registrations(forModule: "reminders")
    guard let reg = regs.first(where: { $0.name == name }) else {
        throw TestError.assertion("tool \(name) not registered")
    }
    return try await reg.handler(args)
}

private func objField(_ v: Value, _ key: String) -> Value? {
    if case .object(let d) = v { return d[key] }
    return nil
}

func runRemindersModuleTests() async {
    print("\n\u{23F0} RemindersModule Tests (PKT-957 · v3.7·D)")

    // MARK: registration + tiering

    await test("RemindersModule registers exactly 6 tools") {
        let router = await makeRouter(MockRemindersStore())
        let tools = await router.registrations(forModule: "reminders")
        try expect(tools.count == 6, "expected 6 reminders tools, got \(tools.count)")
    }

    await test("reminders tiering matches ReadOnlyTierAudit policy") {
        let router = await makeRouter(MockRemindersStore())
        let tools = await router.registrations(forModule: "reminders")
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expect(byName["reminders_lists"]?.tier == .open, "lists must be .open")
        try expect(byName["reminders_list"]?.tier == .open, "list must be .open")
        try expect(byName["reminders_create"]?.tier == .notify, "create must be .notify")
        try expect(byName["reminders_update"]?.tier == .notify, "update must be .notify")
        try expect(byName["reminders_complete"]?.tier == .notify, "complete must be .notify")
        try expect(byName["reminders_delete"]?.tier == .request, "delete must be .request")
    }

    // MARK: reminders_lists

    await test("reminders_lists returns the seeded lists with default flag") {
        let router = await makeRouter(MockRemindersStore())
        let result = try await callHandler(router, "reminders_lists", .object([:]))
        guard case .int(let count)? = objField(result, "count") else {
            throw TestError.assertion("missing count")
        }
        try expect(count == 2, "expected 2 lists, got \(count)")
        guard case .array(let arr)? = objField(result, "lists") else {
            throw TestError.assertion("missing lists array")
        }
        let defaults = arr.filter { objField($0, "isDefault") == .bool(true) }
        try expect(defaults.count == 1, "exactly one default list expected")
    }

    // MARK: CRUD round-trip

    await test("reminders_create returns a new id + record") {
        let router = await makeRouter(MockRemindersStore())
        let result = try await callHandler(router, "reminders_create", .object([
            "title": .string("Buy milk"),
            "due": .string("2026-06-05T17:00:00Z"),
            "priority": .int(1)
        ]))
        guard case .string(let id)? = objField(result, "id") else {
            throw TestError.assertion("create returned no id")
        }
        try expect(!id.isEmpty, "empty id")
        let rec = objField(result, "reminder")
        try expect(objField(rec!, "title") == .string("Buy milk"), "title mismatch")
        try expect(objField(rec!, "priority") == .int(1), "priority mismatch")
        try expect(objField(rec!, "due") == .string("2026-06-05T17:00:00Z"), "due mismatch")
    }

    await test("reminders_create requires title") {
        let router = await makeRouter(MockRemindersStore())
        do {
            _ = try await callHandler(router, "reminders_create", .object(["notes": .string("x")]))
            throw TestError.assertion("expected invalidArguments for missing title")
        } catch is ToolRouterError {
            // expected
        }
    }

    await test("reminders_list reflects a created reminder; reminders_update mutates it") {
        let store = MockRemindersStore()
        let router = await makeRouter(store)
        let created = try await callHandler(router, "reminders_create", .object(["title": .string("Draft report")]))
        guard case .string(let id)? = objField(created, "id") else {
            throw TestError.assertion("no id")
        }

        // list shows it (incomplete, default filter)
        let listed = try await callHandler(router, "reminders_list", .object([:]))
        guard case .int(let n)? = objField(listed, "count") else { throw TestError.assertion("no count") }
        try expect(n == 1, "expected 1 active reminder, got \(n)")

        // update title + due + priority
        let updated = try await callHandler(router, "reminders_update", .object([
            "id": .string(id),
            "title": .string("Draft Q2 report"),
            "due": .string("2026-07-01T09:00:00Z"),
            "priority": .int(5)
        ]))
        let rec = objField(updated, "reminder")!
        try expect(objField(rec, "title") == .string("Draft Q2 report"), "title not updated")
        try expect(objField(rec, "due") == .string("2026-07-01T09:00:00Z"), "due not updated")
        try expect(objField(rec, "priority") == .int(5), "priority not updated")
    }

    await test("reminders_update with empty due clears the due date") {
        let router = await makeRouter(MockRemindersStore())
        let created = try await callHandler(router, "reminders_create", .object([
            "title": .string("Dated"), "due": .string("2026-06-09T12:00:00Z")
        ]))
        guard case .string(let id)? = objField(created, "id") else { throw TestError.assertion("no id") }
        let updated = try await callHandler(router, "reminders_update", .object([
            "id": .string(id), "due": .string("")
        ]))
        try expect(objField(objField(updated, "reminder")!, "due") == .null, "due not cleared")
    }

    await test("reminders_create/update set + clear url and location (v3.7.2 fields)") {
        let router = await makeRouter(MockRemindersStore())
        let created = try await callHandler(router, "reminders_create", .object([
            "title": .string("Pick up package"),
            "url": .string("https://example.com/track/123"),
            "location": .string("Front desk")
        ]))
        guard case .string(let id)? = objField(created, "id") else { throw TestError.assertion("no id") }
        let rec = objField(created, "reminder")!
        try expect(objField(rec, "url") == .string("https://example.com/track/123"), "url not set on create")
        try expect(objField(rec, "location") == .string("Front desk"), "location not set on create")
        // update both to new values
        let updated = try await callHandler(router, "reminders_update", .object([
            "id": .string(id),
            "url": .string("https://example.com/track/456"),
            "location": .string("Mailroom")
        ]))
        let urec = objField(updated, "reminder")!
        try expect(objField(urec, "url") == .string("https://example.com/track/456"), "url not updated")
        try expect(objField(urec, "location") == .string("Mailroom"), "location not updated")
        // clear both via empty string
        let cleared = try await callHandler(router, "reminders_update", .object([
            "id": .string(id), "url": .string(""), "location": .string("")
        ]))
        let crec = objField(cleared, "reminder")!
        try expect(objField(crec, "url") == nil, "url not cleared")
        try expect(objField(crec, "location") == nil, "location not cleared")
    }

    // MARK: completion idempotency

    await test("reminders_complete is idempotent (repeat → same completed state)") {
        let router = await makeRouter(MockRemindersStore())
        let created = try await callHandler(router, "reminders_create", .object(["title": .string("Submit")]))
        guard case .string(let id)? = objField(created, "id") else { throw TestError.assertion("no id") }

        let first = try await callHandler(router, "reminders_complete", .object(["id": .string(id)]))
        try expect(objField(first, "completed") == .bool(true), "first complete should be true")

        let second = try await callHandler(router, "reminders_complete", .object([
            "id": .string(id), "completed": .bool(true)
        ]))
        try expect(objField(second, "completed") == .bool(true), "idempotent complete must stay true")

        // re-open
        let reopened = try await callHandler(router, "reminders_complete", .object([
            "id": .string(id), "completed": .bool(false)
        ]))
        try expect(objField(reopened, "completed") == .bool(false), "should be re-opened")
    }

    await test("completed reminders are hidden by default, shown with includeCompleted") {
        let router = await makeRouter(MockRemindersStore())
        let created = try await callHandler(router, "reminders_create", .object(["title": .string("Done soon")]))
        guard case .string(let id)? = objField(created, "id") else { throw TestError.assertion("no id") }
        _ = try await callHandler(router, "reminders_complete", .object(["id": .string(id)]))

        let hidden = try await callHandler(router, "reminders_list", .object([:]))
        try expect(objField(hidden, "count") == .int(0), "completed reminder must be hidden by default")

        let shown = try await callHandler(router, "reminders_list", .object(["includeCompleted": .bool(true)]))
        try expect(objField(shown, "count") == .int(1), "completed reminder must show with includeCompleted")
    }

    // MARK: delete

    await test("reminders_delete removes the reminder (idempotency: re-delete throws notFound)") {
        let router = await makeRouter(MockRemindersStore())
        let created = try await callHandler(router, "reminders_create", .object(["title": .string("Temp")]))
        guard case .string(let id)? = objField(created, "id") else { throw TestError.assertion("no id") }

        let del = try await callHandler(router, "reminders_delete", .object(["id": .string(id)]))
        try expect(objField(del, "deleted") == .bool(true), "delete should report true")

        // gone from listing
        let listed = try await callHandler(router, "reminders_list", .object([:]))
        try expect(objField(listed, "count") == .int(0), "deleted reminder still listed")

        // re-delete surfaces a notFound (no silent success on a missing id)
        do {
            _ = try await callHandler(router, "reminders_delete", .object(["id": .string(id)]))
            throw TestError.assertion("expected notFound on re-delete")
        } catch let e as RemindersModuleError {
            try expect(e == .notFound(id), "expected notFound, got \(e)")
        }
    }

    // MARK: access-denied path

    await test("access-denied: every mutating + reading tool surfaces accessDenied") {
        let store = MockRemindersStore(authStatus: .denied)
        let router = await makeRouter(store)

        func expectDenied(_ name: String, _ args: Value) async {
            await test("  \(name) → accessDenied when TCC denied") {
                do {
                    _ = try await callHandler(router, name, args)
                    throw TestError.assertion("expected accessDenied")
                } catch let e as RemindersModuleError {
                    try expect(e == .accessDenied, "expected accessDenied, got \(e)")
                }
            }
        }

        await expectDenied("reminders_lists", .object([:]))
        await expectDenied("reminders_list", .object([:]))
        await expectDenied("reminders_create", .object(["title": .string("x")]))
        await expectDenied("reminders_update", .object(["id": .string("rem-1"), "title": .string("y")]))
        await expectDenied("reminders_complete", .object(["id": .string("rem-1")]))
        await expectDenied("reminders_delete", .object(["id": .string("rem-1")]))
    }

    await test("notDetermined status also throws accessDenied (no live TCC prompt in tests)") {
        let router = await makeRouter(MockRemindersStore(authStatus: .notDetermined))
        do {
            _ = try await callHandler(router, "reminders_lists", .object([:]))
            throw TestError.assertion("expected accessDenied for notDetermined")
        } catch let e as RemindersModuleError {
            try expect(e == .accessDenied)
        }
    }
}
