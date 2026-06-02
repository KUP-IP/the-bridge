// CalendarModule.swift – Calendar Tools (native EventKit Calendar CRUD)
// NotionBridge · Modules
//
// Five tools: calendar_list (open), calendar_events (open),
// calendar_create (notify), calendar_update (notify),
// calendar_delete (request).
//
// Created by PKT-962 (v3.7·I): first-class native Calendar module over
// EventKit `.event` entities, replacing connector/cloud-only calendar access
// so agents enumerate calendars, query events by date range, and CRUD events
// without a cloud round-trip.
//
// ── REUSES v3.7·D (PKT-957)'s EventKit infrastructure ─────────────────────
// This module DOES NOT recreate the EventKit store or re-declare any
// entitlement. It mirrors RemindersModule's injectable-seam pattern — all
// store access routes through a `CalendarStoring` protocol so the unit tests
// never touch live EventKit / TCC. Production uses `EventKitCalendarStore`,
// which constructs an `EKEventStore` exactly as `EventKitRemindersStore` does
// (the same EventKit type backs both `.reminder` and `.event` entities); a
// single process may share one `EKEventStore` between the two production
// stores. Tests inject a deterministic in-memory mock.
//
// ── ENTITLEMENT / OPERATOR GATE (shared with PKT-957) ─────────────────────
// Live use requires:
//   1. com.apple.security.personal-information.calendars in
//      NotionBridge.entitlements — ALREADY DECLARED by PKT-957 (v3.7·D).
//      This packet REUSES it; it does NOT add a second entitlement key.
//   2. a runtime Calendar TCC grant (operator, first-call prompt).
// As with reminders, the calendars entitlement MUST be validated against
// notarize BEFORE shipping; if notarize refuses it, the documented fallback
// is AppleScript via the existing apple-events entitlement. This is an
// OPERATOR step — the same notarize-validate residual as PKT-957, NOT
// validated by this packet.

import AppKit
@preconcurrency import EventKit
import Foundation
import MCP

// MARK: - Store Seam (injectable)

/// Authorization state for the Calendar store, decoupled from EventKit so the
/// mock seam can drive every branch (incl. the access-denied path). Mirrors
/// `RemindersAuthStatus` but kept distinct so a future write-only calendar
/// access state could be modelled independently of reminders.
public enum CalendarAuthStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// A plain calendar (EKCalendar of type `.event`). Decoupled from EKCalendar
/// so the seam is testable without EventKit objects.
public struct CalendarInfo: Sendable, Equatable {
    public let id: String       // EKCalendar.calendarIdentifier
    public let title: String
    public let isDefault: Bool
    public let allowsModify: Bool

    public init(id: String, title: String, isDefault: Bool, allowsModify: Bool) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.allowsModify = allowsModify
    }
}

/// A plain calendar-event record. `start` / `end` are ISO-8601. Decoupled
/// from EKEvent so the seam is testable without EventKit objects.
public struct CalendarEvent: Sendable, Equatable {
    public let id: String       // EKEvent.eventIdentifier
    public var title: String
    public var start: String    // ISO-8601
    public var end: String      // ISO-8601
    public var allDay: Bool
    public var calendarId: String
    public var calendarTitle: String
    public var location: String?
    public var notes: String?

    public init(
        id: String,
        title: String,
        start: String,
        end: String,
        allDay: Bool,
        calendarId: String,
        calendarTitle: String,
        location: String?,
        notes: String?
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
    }
}

/// Date-range filter for `calendar_events`. `start` / `end` are ISO-8601 and
/// both required (an unbounded EventKit event query is not meaningful).
public struct CalendarEventQuery: Sendable {
    public var start: String       // ISO-8601 (range lower bound)
    public var end: String         // ISO-8601 (range upper bound)
    public var calendarId: String? // nil = all event calendars

    public init(start: String, end: String, calendarId: String? = nil) {
        self.start = start
        self.end = end
        self.calendarId = calendarId
    }
}

/// Draft for `calendar_create` / `calendar_update`. Optional fields mean
/// "leave unchanged" on update. Recurrence editing is intentionally out of
/// scope (see packet Scope OUT) — these drafts model single events only.
public struct CalendarEventDraft: Sendable {
    public var title: String?
    public var start: String?      // ISO-8601
    public var end: String?        // ISO-8601
    public var allDay: Bool?
    public var calendarId: String?
    public var location: String?
    public var notes: String?

    public init(
        title: String? = nil,
        start: String? = nil,
        end: String? = nil,
        allDay: Bool? = nil,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
    }
}

/// The injectable store seam. Production = `EventKitCalendarStore`;
/// tests = a deterministic in-memory mock. All methods are async + throwing
/// so the mock can drive the access-denied path uniformly.
public protocol CalendarStoring: Sendable {
    func authorizationStatus() -> CalendarAuthStatus
    /// Ensures access is authorized, triggering the TCC prompt if
    /// `.notDetermined`. Throws `CalendarModuleError.accessDenied` otherwise.
    func ensureAccess() async throws
    func calendars() async throws -> [CalendarInfo]
    func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent]
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent
    func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent
    func delete(id: String) async throws
}

// MARK: - Errors

public enum CalendarModuleError: LocalizedError, Equatable {
    case accessDenied
    case notFound(String)
    case calendarNotFound(String)
    case immutableCalendar(String)
    case invalidDate(String)
    case missingRequired(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access not granted. Enable in System Settings > Privacy & Security > Calendars for NotionBridge."
        case .notFound(let id):
            return "Event not found: \(id)"
        case .calendarNotFound(let id):
            return "Calendar not found: \(id)"
        case .immutableCalendar(let id):
            return "Calendar does not allow modification: \(id)"
        case .invalidDate(let s):
            return "Invalid ISO-8601 date: \(s)"
        case .missingRequired(let field):
            return "Missing required field: \(field)"
        }
    }
}

// MARK: - EventKit-backed store (production)

/// Live EventKit implementation over `.event` entities. Requires the
/// calendars entitlement (declared by PKT-957) + a Calendar TCC grant
/// (operator). Not exercised by the unit tests — those use the mock.
///
/// Shares the same `EKEventStore` *type* as `EventKitRemindersStore`; a
/// process that wants one store for both entity kinds can construct this with
/// the reminders store's `EKEventStore`. The default initializer makes its own.
public final class EventKitCalendarStore: CalendarStoring, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func authorizationStatus() -> CalendarAuthStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            // Write-only grants can create events but not read them back;
            // fail-closed for the read paths (treat as restricted).
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    public func ensureAccess() async throws {
        switch authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            } else {
                granted = await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
                }
            }
            if !granted { throw CalendarModuleError.accessDenied }
        case .denied, .restricted:
            throw CalendarModuleError.accessDenied
        }
    }

    /// A fresh formatter per call — `ISO8601DateFormatter` is not `Sendable`,
    /// so it cannot be a shared static across the actor-hopping handlers.
    /// (Same rationale as `EventKitRemindersStore.makeISO`.)
    private static func makeISO() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private func dateToISO(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.makeISO().string(from: date)
    }

    private func isoToDate(_ iso: String) throws -> Date {
        guard let date = Self.makeISO().date(from: iso) else {
            throw CalendarModuleError.invalidDate(iso)
        }
        return date
    }

    private func toEvent(_ e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: e.eventIdentifier ?? "",
            title: e.title ?? "",
            start: dateToISO(e.startDate),
            end: dateToISO(e.endDate),
            allDay: e.isAllDay,
            calendarId: e.calendar?.calendarIdentifier ?? "",
            calendarTitle: e.calendar?.title ?? "",
            location: e.location,
            notes: e.notes
        )
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        return store.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                title: cal.title,
                isDefault: cal.calendarIdentifier
                    == store.defaultCalendarForNewEvents?.calendarIdentifier,
                allowsModify: cal.allowsContentModifications
            )
        }
    }

    public func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let startDate = try isoToDate(query.start)
        let endDate = try isoToDate(query.end)
        let calendars: [EKCalendar]?
        if let calendarId = query.calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarModuleError.calendarNotFound(calendarId)
            }
            calendars = [cal]
        } else {
            calendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: startDate, end: endDate, calendars: calendars)
        // Map EKEvent → Sendable CalendarEvent before returning so no
        // non-Sendable EventKit object escapes this call.
        let ek = store.events(matching: predicate)
        return ek.map(toEvent).sorted { $0.start < $1.start }
    }

    private func resolveCalendar(_ calendarId: String?) throws -> EKCalendar {
        if let calendarId {
            guard let cal = store.calendar(withIdentifier: calendarId) else {
                throw CalendarModuleError.calendarNotFound(calendarId)
            }
            return cal
        }
        guard let def = store.defaultCalendarForNewEvents else {
            throw CalendarModuleError.calendarNotFound("default")
        }
        return def
    }

    public func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        guard let start = draft.start else { throw CalendarModuleError.missingRequired("start") }
        guard let end = draft.end else { throw CalendarModuleError.missingRequired("end") }
        let event = EKEvent(eventStore: store)
        event.calendar = try resolveCalendar(draft.calendarId)
        event.title = draft.title ?? ""
        event.startDate = try isoToDate(start)
        event.endDate = try isoToDate(end)
        if let allDay = draft.allDay { event.isAllDay = allDay }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        return toEvent(event)
    }

    private func fetchEvent(id: String) throws -> EKEvent {
        if let event = store.event(withIdentifier: id) {
            return event
        }
        throw CalendarModuleError.notFound(id)
    }

    public func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent {
        try await ensureAccess()
        let event = try fetchEvent(id: id)
        if let title = draft.title { event.title = title }
        if let start = draft.start { event.startDate = try isoToDate(start) }
        if let end = draft.end { event.endDate = try isoToDate(end) }
        if let allDay = draft.allDay { event.isAllDay = allDay }
        if let location = draft.location { event.location = location }
        if let notes = draft.notes { event.notes = notes }
        if let calendarId = draft.calendarId {
            event.calendar = try resolveCalendar(calendarId)
        }
        try store.save(event, span: .thisEvent, commit: true)
        return toEvent(event)
    }

    public func delete(id: String) async throws {
        try await ensureAccess()
        let event = try fetchEvent(id: id)
        try store.remove(event, span: .thisEvent, commit: true)
    }
}

// MARK: - CalendarModule

/// Provides EventKit-backed calendar tools through an injectable store seam.
public enum CalendarModule {

    public static let moduleName = "calendar"

    /// Register all CalendarModule tools on the given router. `store`
    /// defaults to the live EventKit store; tests inject a mock seam.
    public static func register(
        on router: ToolRouter,
        store: CalendarStoring = EventKitCalendarStore()
    ) async {

        // MARK: 1. calendar_list – open (read-only)
        await router.register(ToolRegistration(
            name: "calendar_list",
            module: moduleName,
            tier: .open,
            description: "Enumerate Calendar calendars (EKCalendar of type .event). Returns id, title, isDefault, allowsModify. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let cals = try await store.calendars()
                return .object([
                    "count": .int(cals.count),
                    "calendars": .array(cals.map(formatCalendar))
                ])
            }
        ))

        // MARK: 2. calendar_events – open (read-only)
        await router.register(ToolRegistration(
            name: "calendar_events",
            module: moduleName,
            tier: .open,
            description: "List calendar events within a date range. Requires start + end (ISO-8601); optional calendarId scopes to one calendar (default: all). Returns id, title, start, end, allDay, calendar, location, notes. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "start": .object(["type": .string("string"), "description": .string("ISO-8601 range lower bound (required)")]),
                    "end": .object(["type": .string("string"), "description": .string("ISO-8601 range upper bound (required)")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("EKCalendar.calendarIdentifier to scope to a single calendar (default: all event calendars)")])
                ]),
                "required": .array([.string("start"), .string("end")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let start = stringArg(args, "start") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_events", reason: "missing 'start'")
                }
                guard let end = stringArg(args, "end") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_events", reason: "missing 'end'")
                }
                let query = CalendarEventQuery(
                    start: start,
                    end: end,
                    calendarId: stringArg(args, "calendarId")
                )
                let events = try await store.events(query)
                return .object([
                    "count": .int(events.count),
                    "events": .array(events.map(formatEvent))
                ])
            }
        ))

        // MARK: 3. calendar_create – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "calendar_create",
            module: moduleName,
            tier: .notify,
            description: "Create a calendar event. Requires title, start, end (ISO-8601); optional allDay, calendarId, location, notes. Returns the new event id + record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Event title (required)")]),
                    "start": .object(["type": .string("string"), "description": .string("Start ISO-8601 (required)")]),
                    "end": .object(["type": .string("string"), "description": .string("End ISO-8601 (required)")]),
                    "allDay": .object(["type": .string("boolean"), "description": .string("All-day event (default: false)")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("Target calendar identifier (default: the default Calendar for new events)")]),
                    "location": .object(["type": .string("string"), "description": .string("Location (optional)")]),
                    "notes": .object(["type": .string("string"), "description": .string("Freeform notes (optional)")])
                ]),
                "required": .array([.string("title"), .string("start"), .string("end")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let title = stringArg(args, "title") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'title'")
                }
                guard let start = stringArg(args, "start") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'start'")
                }
                guard let end = stringArg(args, "end") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_create", reason: "missing 'end'")
                }
                let draft = CalendarEventDraft(
                    title: title,
                    start: start,
                    end: end,
                    allDay: boolArg(args, "allDay"),
                    calendarId: stringArg(args, "calendarId"),
                    location: stringArg(args, "location"),
                    notes: stringArg(args, "notes")
                )
                let event = try await store.create(draft)
                return .object([
                    "id": .string(event.id),
                    "event": formatEvent(event)
                ])
            }
        ))

        // MARK: 4. calendar_update – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "calendar_update",
            module: moduleName,
            tier: .notify,
            description: "Update a calendar event by id. Any of title, start, end, allDay, location, notes, calendarId. Returns the updated record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKEvent.eventIdentifier (required)")]),
                    "title": .object(["type": .string("string"), "description": .string("New title")]),
                    "start": .object(["type": .string("string"), "description": .string("New start ISO-8601")]),
                    "end": .object(["type": .string("string"), "description": .string("New end ISO-8601")]),
                    "allDay": .object(["type": .string("boolean"), "description": .string("Set all-day flag")]),
                    "calendarId": .object(["type": .string("string"), "description": .string("Move to a different calendar")]),
                    "location": .object(["type": .string("string"), "description": .string("New location")]),
                    "notes": .object(["type": .string("string"), "description": .string("New notes")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_update", reason: "missing 'id'")
                }
                let draft = CalendarEventDraft(
                    title: stringArg(args, "title"),
                    start: stringArg(args, "start"),
                    end: stringArg(args, "end"),
                    allDay: boolArg(args, "allDay"),
                    calendarId: stringArg(args, "calendarId"),
                    location: stringArg(args, "location"),
                    notes: stringArg(args, "notes")
                )
                let event = try await store.update(id: id, draft)
                return .object([
                    "id": .string(event.id),
                    "event": formatEvent(event)
                ])
            }
        ))

        // MARK: 5. calendar_delete – request (DESTRUCTIVE)
        await router.register(ToolRegistration(
            name: "calendar_delete",
            module: moduleName,
            tier: .request,
            description: "Delete a calendar event by id. DESTRUCTIVE / irreversible — gated at tier .request (confirmation required). Returns the deleted id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKEvent.eventIdentifier (required)")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "calendar_delete", reason: "missing 'id'")
                }
                try await store.delete(id: id)
                return .object([
                    "id": .string(id),
                    "deleted": .bool(true)
                ])
            }
        ))
    }

    // MARK: - Formatting

    static func formatCalendar(_ cal: CalendarInfo) -> Value {
        .object([
            "id": .string(cal.id),
            "title": .string(cal.title),
            "isDefault": .bool(cal.isDefault),
            "allowsModify": .bool(cal.allowsModify)
        ])
    }

    static func formatEvent(_ event: CalendarEvent) -> Value {
        var entry: [String: Value] = [
            "id": .string(event.id),
            "title": .string(event.title),
            "start": .string(event.start),
            "end": .string(event.end),
            "allDay": .bool(event.allDay),
            "calendarId": .string(event.calendarId),
            "calendar": .string(event.calendarTitle)
        ]
        if let location = event.location { entry["location"] = .string(location) }
        if let notes = event.notes { entry["notes"] = .string(notes) }
        return .object(entry)
    }

    // MARK: - Argument helpers

    private static func objectArgs(_ value: Value) -> [String: Value] {
        if case .object(let args) = value { return args }
        return [:]
    }

    private static func stringArg(_ args: [String: Value], _ key: String) -> String? {
        if case .string(let s)? = args[key] { return s }
        return nil
    }

    private static func boolArg(_ args: [String: Value], _ key: String) -> Bool? {
        if case .bool(let b)? = args[key] { return b }
        return nil
    }
}
