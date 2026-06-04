// RemindersModule.swift – Reminders Tools (iCloud Reminders CRUD via EventKit)
// NotionBridge · Modules
//
// Six tools: reminders_lists (open), reminders_list (open),
// reminders_create (notify), reminders_update (notify),
// reminders_complete (notify), reminders_delete (request).
//
// Mirrors ContactsModule (CNContactStore + personal-information entitlement
// + module/registry pattern), but over EventKit's EKEventStore with
// `.reminder` entities. Unlike ContactsModule — which calls CNContactStore()
// inline — this module routes ALL store access through an injectable
// `RemindersStoring` seam (protocol) so the unit tests never touch live
// EventKit / TCC. Production uses `EventKitRemindersStore`; tests inject a
// deterministic mock.
//
// Created by PKT-957 (v3.7·D): first-class Reminders module closing the
// Apple-app gap so agents add/update/remove iCloud Reminders without ad-hoc
// AppleScript.
//
// ── ENTITLEMENT / OPERATOR GATE (PKT-933 lesson) ──────────────────────────
// Live use requires:
//   1. com.apple.security.personal-information.calendars in
//      NotionBridge.entitlements (declared by this packet), AND
//   2. a runtime Reminders TCC grant (operator, first-call prompt).
// PKT-933 (2026-05-30) removed keychain-access-groups because the
// Developer-ID provisioning profile / notarization refused it and the app
// would not launch. The calendars entitlement MUST be validated against
// notarize BEFORE shipping. If notarize refuses it, the documented fallback
// is AppleScript via the existing com.apple.security.automation.apple-events
// entitlement. This is an OPERATOR step — NOT validated by this packet.

import AppKit
import CoreLocation
@preconcurrency import EventKit
import Foundation
import MCP

// MARK: - Store Seam (injectable)

/// Authorization state for the Reminders store, decoupled from EventKit so
/// the mock seam can drive every branch (incl. the access-denied path).
public enum RemindersAuthStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// A plain reminder list (EKCalendar of type `.reminder`).
public struct ReminderList: Sendable, Equatable {
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

/// A draft alarm for `reminders_create` / `reminders_update`. Maps to an
/// `EKAlarm`. `type` selects the trigger shape:
///   - "relative"  → fires `triggerMinutesBefore` minutes before the due date
///                   (`EKAlarm(relativeOffset:)`, a negative offset).
///   - "absolute"  → fires at `triggerAbsoluteDate` (ISO-8601)
///                   (`EKAlarm(absoluteDate:)`).
///   - "geofence"  → fires on `proximity` ("arrive"/"leave") at the
///                   lat/long/radius location (`EKStructuredLocation` +
///                   `CLLocation`).
public struct AlarmDraft: Sendable, Equatable {
    public var type: String                 // "relative" | "absolute" | "geofence"
    public var triggerMinutesBefore: Int?    // relative: minutes before due
    public var triggerAbsoluteDate: String?  // absolute: ISO-8601
    public var latitude: Double?             // geofence
    public var longitude: Double?            // geofence
    public var radius: Double?               // geofence: meters
    public var proximity: String?            // geofence: "arrive" | "leave" | nil

    public init(
        type: String,
        triggerMinutesBefore: Int? = nil,
        triggerAbsoluteDate: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double? = nil,
        proximity: String? = nil
    ) {
        self.type = type
        self.triggerMinutesBefore = triggerMinutesBefore
        self.triggerAbsoluteDate = triggerAbsoluteDate
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.proximity = proximity
    }
}

/// A plain alarm record (the read-back shape of `AlarmDraft` + a stable id).
/// Decoupled from EKAlarm so the seam is testable without EventKit objects.
public struct AlarmItem: Sendable, Equatable {
    public let id: String
    public var type: String                 // "relative" | "absolute" | "geofence"
    public var triggerMinutesBefore: Int?
    public var triggerAbsoluteDate: String?
    public var latitude: Double?
    public var longitude: Double?
    public var radius: Double?
    public var proximity: String?

    public init(
        id: String,
        type: String,
        triggerMinutesBefore: Int? = nil,
        triggerAbsoluteDate: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double? = nil,
        proximity: String? = nil
    ) {
        self.id = id
        self.type = type
        self.triggerMinutesBefore = triggerMinutesBefore
        self.triggerAbsoluteDate = triggerAbsoluteDate
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.proximity = proximity
    }
}

/// A plain reminder record. `due` is ISO-8601 (or nil). Decoupled from
/// EKReminder so the seam is testable without EventKit objects.
public struct ReminderItem: Sendable, Equatable {
    public let id: String       // EKReminder.calendarItemIdentifier
    public var title: String
    public var due: String?     // ISO-8601 string, nil = no due date
    public var listId: String
    public var listTitle: String
    public var completed: Bool
    public var notes: String?
    public var priority: Int    // EKReminder.priority (0 = none, 1 = high … 9 = low)
    public var url: String?      // EKCalendarItem.url (absolute string)
    public var location: String? // EKCalendarItem.location (free text)
    /// Compact serialization of the first EKRecurrenceRule, e.g.
    /// "weekly;interval:1" (+ ";count:N" or ";until:ISO"). nil = not recurring.
    public var recurrenceRule: String?
    public var alarms: [AlarmItem]?

    public init(
        id: String,
        title: String,
        due: String?,
        listId: String,
        listTitle: String,
        completed: Bool,
        notes: String?,
        priority: Int,
        url: String? = nil,
        location: String? = nil,
        recurrenceRule: String? = nil,
        alarms: [AlarmItem]? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.listId = listId
        self.listTitle = listTitle
        self.completed = completed
        self.notes = notes
        self.priority = priority
        self.url = url
        self.location = location
        self.recurrenceRule = recurrenceRule
        self.alarms = alarms
    }
}

/// Filter for `reminders_list`.
public struct ReminderQuery: Sendable {
    public var listId: String?
    public var includeCompleted: Bool
    public var dueBefore: String?  // ISO-8601
    public var dueAfter: String?   // ISO-8601

    public init(listId: String? = nil, includeCompleted: Bool = false, dueBefore: String? = nil, dueAfter: String? = nil) {
        self.listId = listId
        self.includeCompleted = includeCompleted
        self.dueBefore = dueBefore
        self.dueAfter = dueAfter
    }
}

/// Draft for `reminders_create` / `reminders_update`. Optional fields mean
/// "leave unchanged" on update.
public struct ReminderDraft: Sendable {
    public var title: String?
    public var due: String?        // ISO-8601; explicit empty string clears
    public var clearDue: Bool
    public var listId: String?
    public var notes: String?
    public var priority: Int?
    /// EKCalendarItem.url. On update, empty string clears it.
    public var url: String?
    /// EKCalendarItem.location (free text). On update, empty string clears it.
    public var location: String?
    /// Recurrence frequency: "daily" | "weekly" | "monthly" | "yearly".
    /// On update, an explicit empty string clears the recurrence.
    public var recurrenceFreq: String?
    /// Recurrence interval (every N units). Defaults to 1 when freq is set.
    public var recurrenceInterval: Int?
    /// Recurrence end date (ISO-8601). Mutually informs EKRecurrenceEnd.
    public var recurrenceEndDate: String?
    /// Recurrence occurrence count. Mutually informs EKRecurrenceEnd.
    public var recurrenceCount: Int?
    /// Alarms to set. On update, an explicit empty array clears all alarms;
    /// nil leaves them unchanged.
    public var alarms: [AlarmDraft]?

    public init(
        title: String? = nil,
        due: String? = nil,
        clearDue: Bool = false,
        listId: String? = nil,
        notes: String? = nil,
        priority: Int? = nil,
        url: String? = nil,
        location: String? = nil,
        recurrenceFreq: String? = nil,
        recurrenceInterval: Int? = nil,
        recurrenceEndDate: String? = nil,
        recurrenceCount: Int? = nil,
        alarms: [AlarmDraft]? = nil
    ) {
        self.title = title
        self.due = due
        self.clearDue = clearDue
        self.listId = listId
        self.notes = notes
        self.priority = priority
        self.url = url
        self.location = location
        self.recurrenceFreq = recurrenceFreq
        self.recurrenceInterval = recurrenceInterval
        self.recurrenceEndDate = recurrenceEndDate
        self.recurrenceCount = recurrenceCount
        self.alarms = alarms
    }
}

/// The injectable store seam. Production = `EventKitRemindersStore`;
/// tests = a deterministic in-memory mock. All methods are async + throwing
/// so the mock can drive the access-denied path uniformly.
public protocol RemindersStoring: Sendable {
    func authorizationStatus() -> RemindersAuthStatus
    /// Ensures access is authorized, triggering the TCC prompt if
    /// `.notDetermined`. Throws `RemindersModuleError.accessDenied` otherwise.
    func ensureAccess() async throws
    func lists() async throws -> [ReminderList]
    func fetch(_ query: ReminderQuery) async throws -> [ReminderItem]
    func create(_ draft: ReminderDraft) async throws -> ReminderItem
    func update(id: String, _ draft: ReminderDraft) async throws -> ReminderItem
    func setCompleted(id: String, completed: Bool) async throws -> ReminderItem
    func delete(id: String) async throws
}

// MARK: - Errors

public enum RemindersModuleError: LocalizedError, Equatable {
    case accessDenied
    case notFound(String)
    case listNotFound(String)
    case immutableList(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access not granted. Enable in System Settings > Privacy & Security > Reminders for NotionBridge."
        case .notFound(let id):
            return "Reminder not found: \(id)"
        case .listNotFound(let id):
            return "Reminder list not found: \(id)"
        case .immutableList(let id):
            return "Reminder list does not allow modification: \(id)"
        }
    }
}

// MARK: - EventKit-backed store (production)

/// Live EventKit implementation. Requires the calendars entitlement + TCC
/// grant (operator). Not exercised by the unit tests — those use the mock.
public final class EventKitRemindersStore: RemindersStoring, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public func authorizationStatus() -> RemindersAuthStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .writeOnly:
            // Reminders has no write-only state in practice; treat as denied
            // for read paths (fail-closed).
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
                granted = (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                granted = await withCheckedContinuation { cont in
                    store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
                }
            }
            if !granted { throw RemindersModuleError.accessDenied }
        case .denied, .restricted:
            throw RemindersModuleError.accessDenied
        }
    }

    /// A fresh formatter per call — `ISO8601DateFormatter` is not `Sendable`,
    /// so it cannot be a shared static across the actor-hopping handlers.
    /// Construction cost is negligible relative to the EventKit round-trips.
    private static func makeISO() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private func dateComponentsToISO(_ comps: DateComponents?) -> String? {
        guard let comps, let date = Calendar.current.date(from: comps) else { return nil }
        return Self.makeISO().string(from: date)
    }

    private func isoToDateComponents(_ iso: String) -> DateComponents? {
        guard let date = Self.makeISO().date(from: iso) else { return nil }
        return Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private func toItem(_ r: EKReminder) -> ReminderItem {
        ReminderItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "",
            due: dateComponentsToISO(r.dueDateComponents),
            listId: r.calendar?.calendarIdentifier ?? "",
            listTitle: r.calendar?.title ?? "",
            completed: r.isCompleted,
            notes: r.notes,
            priority: r.priority,
            url: r.url?.absoluteString,
            location: r.location,
            recurrenceRule: serializeRule(r.recurrenceRules?.first),
            alarms: serializeAlarms(r.alarms)
        )
    }

    /// Compact, lossy serialization of the first recurrence rule, e.g.
    /// "weekly;interval:1", "daily;interval:2;count:5",
    /// "monthly;interval:1;until:2026-12-31T00:00:00Z".
    private func serializeRule(_ rule: EKRecurrenceRule?) -> String? {
        guard let rule else { return nil }
        let freq: String
        switch rule.frequency {
        case .daily: freq = "daily"
        case .weekly: freq = "weekly"
        case .monthly: freq = "monthly"
        case .yearly: freq = "yearly"
        @unknown default: freq = "daily"
        }
        var parts = ["\(freq);interval:\(rule.interval)"]
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                parts.append("count:\(end.occurrenceCount)")
            } else if let until = end.endDate {
                parts.append("until:\(Self.makeISO().string(from: until))")
            }
        }
        return parts.joined(separator: ";")
    }

    /// Map EKAlarms back into the Sendable AlarmItem shape.
    private func serializeAlarms(_ alarms: [EKAlarm]?) -> [AlarmItem]? {
        guard let alarms, !alarms.isEmpty else { return nil }
        return alarms.enumerated().map { idx, alarm in
            if let loc = alarm.structuredLocation, let geo = loc.geoLocation {
                let proximity: String?
                switch alarm.proximity {
                case .enter: proximity = "arrive"
                case .leave: proximity = "leave"
                default: proximity = nil
                }
                return AlarmItem(
                    id: "alarm-\(idx)",
                    type: "geofence",
                    latitude: geo.coordinate.latitude,
                    longitude: geo.coordinate.longitude,
                    radius: loc.radius,
                    proximity: proximity
                )
            } else if let absolute = alarm.absoluteDate {
                return AlarmItem(
                    id: "alarm-\(idx)",
                    type: "absolute",
                    triggerAbsoluteDate: Self.makeISO().string(from: absolute)
                )
            } else {
                return AlarmItem(
                    id: "alarm-\(idx)",
                    type: "relative",
                    triggerMinutesBefore: Int((-alarm.relativeOffset) / 60.0)
                )
            }
        }
    }

    /// Build an EKRecurrenceRule from the draft's recurrence fields. Returns
    /// nil when no frequency is set (or it's the empty clear sentinel).
    private func buildRecurrenceRule(_ draft: ReminderDraft) -> EKRecurrenceRule? {
        guard let freqRaw = draft.recurrenceFreq, !freqRaw.isEmpty else { return nil }
        let frequency: EKRecurrenceFrequency
        switch freqRaw.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: return nil
        }
        let interval = max(1, draft.recurrenceInterval ?? 1)
        var end: EKRecurrenceEnd?
        if let count = draft.recurrenceCount, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        } else if let endRaw = draft.recurrenceEndDate, !endRaw.isEmpty,
                  let endDate = Self.makeISO().date(from: endRaw) {
            end = EKRecurrenceEnd(end: endDate)
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    /// Build EKAlarms from the draft alarm shapes.
    private func buildAlarms(_ drafts: [AlarmDraft]) -> [EKAlarm] {
        drafts.compactMap { d in
            switch d.type.lowercased() {
            case "relative":
                let minutes = d.triggerMinutesBefore ?? 0
                return EKAlarm(relativeOffset: TimeInterval(-60 * minutes))
            case "absolute":
                guard let iso = d.triggerAbsoluteDate, let date = Self.makeISO().date(from: iso) else {
                    return nil
                }
                return EKAlarm(absoluteDate: date)
            case "geofence":
                guard let lat = d.latitude, let lon = d.longitude else { return nil }
                let alarm = EKAlarm()
                let structured = EKStructuredLocation(title: "Reminder location")
                structured.geoLocation = CLLocation(latitude: lat, longitude: lon)
                if let radius = d.radius { structured.radius = radius }
                alarm.structuredLocation = structured
                switch d.proximity?.lowercased() {
                case "arrive": alarm.proximity = .enter
                case "leave": alarm.proximity = .leave
                default: alarm.proximity = .none
                }
                return alarm
            default:
                return nil
            }
        }
    }

    public func lists() async throws -> [ReminderList] {
        try await ensureAccess()
        return store.calendars(for: .reminder).map { cal in
            ReminderList(
                id: cal.calendarIdentifier,
                title: cal.title,
                isDefault: cal.calendarIdentifier
                    == store.defaultCalendarForNewReminders()?.calendarIdentifier,
                allowsModify: cal.allowsContentModifications
            )
        }
    }

    public func fetch(_ query: ReminderQuery) async throws -> [ReminderItem] {
        try await ensureAccess()
        let calendars: [EKCalendar]?
        if let listId = query.listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersModuleError.listNotFound(listId)
            }
            calendars = [cal]
        } else {
            calendars = nil
        }
        let predicate = store.predicateForReminders(in: calendars)
        // Map EKReminder → Sendable ReminderItem INSIDE the completion handler
        // so no non-Sendable EventKit object crosses the continuation boundary.
        var items: [ReminderItem] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).map(self.toItem))
            }
        }
        if !query.includeCompleted {
            items = items.filter { !$0.completed }
        }
        if let before = query.dueBefore {
            items = items.filter { item in
                guard let d = item.due else { return false }
                return d < before
            }
        }
        if let after = query.dueAfter {
            items = items.filter { item in
                guard let d = item.due else { return false }
                return d > after
            }
        }
        return items
    }

    private func resolveCalendar(_ listId: String?) throws -> EKCalendar {
        if let listId {
            guard let cal = store.calendar(withIdentifier: listId) else {
                throw RemindersModuleError.listNotFound(listId)
            }
            return cal
        }
        guard let def = store.defaultCalendarForNewReminders() else {
            throw RemindersModuleError.listNotFound("default")
        }
        return def
    }

    public func create(_ draft: ReminderDraft) async throws -> ReminderItem {
        try await ensureAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try resolveCalendar(draft.listId)
        reminder.title = draft.title ?? ""
        if let due = draft.due, !due.isEmpty {
            reminder.dueDateComponents = isoToDateComponents(due)
        }
        if let notes = draft.notes { reminder.notes = notes }
        if let priority = draft.priority { reminder.priority = priority }
        if let url = draft.url, !url.isEmpty { reminder.url = URL(string: url) }
        if let location = draft.location, !location.isEmpty { reminder.location = location }
        if let rule = buildRecurrenceRule(draft) { reminder.recurrenceRules = [rule] }
        if let alarms = draft.alarms, !alarms.isEmpty { reminder.alarms = buildAlarms(alarms) }
        try store.save(reminder, commit: true)
        return toItem(reminder)
    }

    private func fetchReminder(id: String) async throws -> EKReminder {
        if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
            return item
        }
        throw RemindersModuleError.notFound(id)
    }

    public func update(id: String, _ draft: ReminderDraft) async throws -> ReminderItem {
        try await ensureAccess()
        let reminder = try await fetchReminder(id: id)
        if let title = draft.title { reminder.title = title }
        if draft.clearDue {
            reminder.dueDateComponents = nil
        } else if let due = draft.due, !due.isEmpty {
            reminder.dueDateComponents = isoToDateComponents(due)
        }
        if let notes = draft.notes { reminder.notes = notes }
        if let priority = draft.priority { reminder.priority = priority }
        if let url = draft.url { reminder.url = url.isEmpty ? nil : URL(string: url) }
        if let location = draft.location { reminder.location = location.isEmpty ? nil : location }
        if let freq = draft.recurrenceFreq {
            // Empty string clears recurrence; otherwise (re)build the rule.
            reminder.recurrenceRules = freq.isEmpty ? nil : buildRecurrenceRule(draft).map { [$0] }
        }
        if let alarms = draft.alarms {
            // Empty array clears all alarms; otherwise replace them wholesale.
            reminder.alarms = alarms.isEmpty ? nil : buildAlarms(alarms)
        }
        if let listId = draft.listId {
            reminder.calendar = try resolveCalendar(listId)
        }
        try store.save(reminder, commit: true)
        return toItem(reminder)
    }

    public func setCompleted(id: String, completed: Bool) async throws -> ReminderItem {
        try await ensureAccess()
        let reminder = try await fetchReminder(id: id)
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        return toItem(reminder)
    }

    public func delete(id: String) async throws {
        try await ensureAccess()
        let reminder = try await fetchReminder(id: id)
        try store.remove(reminder, commit: true)
    }
}

// MARK: - RemindersModule

/// Provides EventKit-backed reminder tools through an injectable store seam.
public enum RemindersModule {

    public static let moduleName = "reminders"

    /// Register all RemindersModule tools on the given router. `store`
    /// defaults to the live EventKit store; tests inject a mock seam.
    public static func register(
        on router: ToolRouter,
        store: RemindersStoring = EventKitRemindersStore()
    ) async {

        // MARK: 1. reminders_lists – open (read-only)
        await router.register(ToolRegistration(
            name: "reminders_lists",
            module: moduleName,
            tier: .open,
            description: "Enumerate iCloud Reminders lists (EKCalendar of type .reminder). Returns id, title, isDefault, allowsModify. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let lists = try await store.lists()
                return .object([
                    "count": .int(lists.count),
                    "lists": .array(lists.map(formatList))
                ])
            }
        ))

        // MARK: 2. reminders_list – open (read-only)
        await router.register(ToolRegistration(
            name: "reminders_list",
            module: moduleName,
            tier: .open,
            description: "List reminders, optionally filtered by list, completion, and a due-date window. Returns id, title, due (ISO-8601), list, completed, notes, priority. Read-only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "listId": .object(["type": .string("string"), "description": .string("EKCalendar.calendarIdentifier to scope to a single list (default: all lists)")]),
                    "includeCompleted": .object(["type": .string("boolean"), "description": .string("Include completed reminders (default: false)")]),
                    "dueBefore": .object(["type": .string("string"), "description": .string("ISO-8601 — only reminders with a due date strictly before this")]),
                    "dueAfter": .object(["type": .string("string"), "description": .string("ISO-8601 — only reminders with a due date strictly after this")])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                let query = ReminderQuery(
                    listId: stringArg(args, "listId"),
                    includeCompleted: boolArg(args, "includeCompleted") ?? false,
                    dueBefore: stringArg(args, "dueBefore"),
                    dueAfter: stringArg(args, "dueAfter")
                )
                let items = try await store.fetch(query)
                return .object([
                    "count": .int(items.count),
                    "reminders": .array(items.map(formatItem))
                ])
            }
        ))

        // MARK: 3. reminders_create – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "reminders_create",
            module: moduleName,
            tier: .notify,
            description: "Create a reminder. Requires title; optional due (ISO-8601), listId, notes, priority (0 none, 1 high … 9 low), url (rich link), location (free text), recurrence (recurrenceFreq daily/weekly/monthly/yearly + recurrenceInterval/EndDate/Count), and alarms (relative/absolute/geofence). Returns the new reminder id + record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Reminder title (required)")]),
                    "due": .object(["type": .string("string"), "description": .string("Due date ISO-8601 (optional)")]),
                    "listId": .object(["type": .string("string"), "description": .string("Target list identifier (default: the default Reminders list)")]),
                    "notes": .object(["type": .string("string"), "description": .string("Freeform notes (optional)")]),
                    "priority": .object(["type": .string("integer"), "description": .string("EKReminder priority 0–9 (0 none, 1 high, 5 medium, 9 low)")]),
                    "url": .object(["type": .string("string"), "description": .string("Attached URL / rich link (optional)")]),
                    "location": .object(["type": .string("string"), "description": .string("Location text shown on the reminder (optional)")]),
                    "recurrenceFreq": .object(["type": .string("string"), "description": .string("Repeat frequency: daily | weekly | monthly | yearly (optional)")]),
                    "recurrenceInterval": .object(["type": .string("integer"), "description": .string("Repeat every N units (default 1)")]),
                    "recurrenceEndDate": .object(["type": .string("string"), "description": .string("Recurrence end date ISO-8601 (optional; mutually exclusive with recurrenceCount)")]),
                    "recurrenceCount": .object(["type": .string("integer"), "description": .string("Number of occurrences before recurrence ends (optional)")]),
                    "alarms": .object([
                        "type": .string("array"),
                        "description": .string("Alarms to attach. Each: type (relative|absolute|geofence), triggerMinutesBefore (relative), triggerAbsoluteDate ISO-8601 (absolute), latitude/longitude/radius + proximity arrive|leave (geofence)"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "type": .object(["type": .string("string"), "description": .string("relative | absolute | geofence")]),
                                "triggerMinutesBefore": .object(["type": .string("integer"), "description": .string("Relative: minutes before the due date")]),
                                "triggerAbsoluteDate": .object(["type": .string("string"), "description": .string("Absolute: fire-at date ISO-8601")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Geofence: latitude")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Geofence: longitude")]),
                                "radius": .object(["type": .string("number"), "description": .string("Geofence: radius in meters")]),
                                "proximity": .object(["type": .string("string"), "description": .string("Geofence: arrive | leave")])
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("title")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let title = stringArg(args, "title") else {
                    throw ToolRouterError.invalidArguments(toolName: "reminders_create", reason: "missing 'title'")
                }
                let draft = ReminderDraft(
                    title: title,
                    due: stringArg(args, "due"),
                    listId: stringArg(args, "listId"),
                    notes: stringArg(args, "notes"),
                    priority: intArg(args, "priority"),
                    url: stringArg(args, "url"),
                    location: stringArg(args, "location"),
                    recurrenceFreq: stringArg(args, "recurrenceFreq"),
                    recurrenceInterval: intArg(args, "recurrenceInterval"),
                    recurrenceEndDate: stringArg(args, "recurrenceEndDate"),
                    recurrenceCount: intArg(args, "recurrenceCount"),
                    alarms: parseAlarmArray(args, "alarms")
                )
                let item = try await store.create(draft)
                return .object([
                    "id": .string(item.id),
                    "reminder": formatItem(item)
                ])
            }
        ))

        // MARK: 4. reminders_update – notify (write, non-destructive)
        await router.register(ToolRegistration(
            name: "reminders_update",
            module: moduleName,
            tier: .notify,
            description: "Update a reminder by id. Any of title, due, notes, priority, listId, url, location, recurrence, alarms. Pass due/url/location as empty string to clear them; recurrenceFreq \"\" clears recurrence; alarms [] clears all alarms. Returns the updated record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKReminder.calendarItemIdentifier (required)")]),
                    "title": .object(["type": .string("string"), "description": .string("New title")]),
                    "due": .object(["type": .string("string"), "description": .string("New due date ISO-8601; empty string clears the due date")]),
                    "listId": .object(["type": .string("string"), "description": .string("Move to a different list")]),
                    "notes": .object(["type": .string("string"), "description": .string("New notes")]),
                    "priority": .object(["type": .string("integer"), "description": .string("New priority 0–9")]),
                    "url": .object(["type": .string("string"), "description": .string("New URL; empty string clears it")]),
                    "location": .object(["type": .string("string"), "description": .string("New location text; empty string clears it")]),
                    "recurrenceFreq": .object(["type": .string("string"), "description": .string("Repeat frequency daily | weekly | monthly | yearly; empty string clears recurrence")]),
                    "recurrenceInterval": .object(["type": .string("integer"), "description": .string("Repeat every N units (default 1)")]),
                    "recurrenceEndDate": .object(["type": .string("string"), "description": .string("Recurrence end date ISO-8601 (optional)")]),
                    "recurrenceCount": .object(["type": .string("integer"), "description": .string("Number of occurrences before recurrence ends (optional)")]),
                    "alarms": .object([
                        "type": .string("array"),
                        "description": .string("Replace all alarms. Empty array clears alarms. Each: type (relative|absolute|geofence), triggerMinutesBefore, triggerAbsoluteDate, latitude/longitude/radius + proximity arrive|leave"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "type": .object(["type": .string("string"), "description": .string("relative | absolute | geofence")]),
                                "triggerMinutesBefore": .object(["type": .string("integer"), "description": .string("Relative: minutes before the due date")]),
                                "triggerAbsoluteDate": .object(["type": .string("string"), "description": .string("Absolute: fire-at date ISO-8601")]),
                                "latitude": .object(["type": .string("number"), "description": .string("Geofence: latitude")]),
                                "longitude": .object(["type": .string("number"), "description": .string("Geofence: longitude")]),
                                "radius": .object(["type": .string("number"), "description": .string("Geofence: radius in meters")]),
                                "proximity": .object(["type": .string("string"), "description": .string("Geofence: arrive | leave")])
                            ])
                        ])
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "reminders_update", reason: "missing 'id'")
                }
                let dueRaw = stringArg(args, "due")
                let draft = ReminderDraft(
                    title: stringArg(args, "title"),
                    due: dueRaw,
                    clearDue: dueRaw == "",
                    listId: stringArg(args, "listId"),
                    notes: stringArg(args, "notes"),
                    priority: intArg(args, "priority"),
                    url: stringArg(args, "url"),
                    location: stringArg(args, "location"),
                    recurrenceFreq: stringArg(args, "recurrenceFreq"),
                    recurrenceInterval: intArg(args, "recurrenceInterval"),
                    recurrenceEndDate: stringArg(args, "recurrenceEndDate"),
                    recurrenceCount: intArg(args, "recurrenceCount"),
                    alarms: parseAlarmArray(args, "alarms")
                )
                let item = try await store.update(id: id, draft)
                return .object([
                    "id": .string(item.id),
                    "reminder": formatItem(item)
                ])
            }
        ))

        // MARK: 5. reminders_complete – notify (write, non-destructive, idempotent)
        await router.register(ToolRegistration(
            name: "reminders_complete",
            module: moduleName,
            tier: .notify,
            description: "Mark a reminder complete or incomplete by id. Idempotent. Returns the updated record.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKReminder.calendarItemIdentifier (required)")]),
                    "completed": .object(["type": .string("boolean"), "description": .string("true = complete (default), false = mark incomplete")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "reminders_complete", reason: "missing 'id'")
                }
                let completed = boolArg(args, "completed") ?? true
                let item = try await store.setCompleted(id: id, completed: completed)
                return .object([
                    "id": .string(item.id),
                    "completed": .bool(item.completed),
                    "reminder": formatItem(item)
                ])
            }
        ))

        // MARK: 6. reminders_delete – request (DESTRUCTIVE)
        await router.register(ToolRegistration(
            name: "reminders_delete",
            module: moduleName,
            tier: .request,
            description: "Delete a reminder by id. DESTRUCTIVE / irreversible — gated at tier .request (confirmation required). Returns the deleted id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string"), "description": .string("EKReminder.calendarItemIdentifier (required)")])
                ]),
                "required": .array([.string("id")])
            ]),
            handler: { arguments in
                let args = objectArgs(arguments)
                guard let id = stringArg(args, "id") else {
                    throw ToolRouterError.invalidArguments(toolName: "reminders_delete", reason: "missing 'id'")
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

    static func formatList(_ list: ReminderList) -> Value {
        .object([
            "id": .string(list.id),
            "title": .string(list.title),
            "isDefault": .bool(list.isDefault),
            "allowsModify": .bool(list.allowsModify)
        ])
    }

    static func formatItem(_ item: ReminderItem) -> Value {
        var entry: [String: Value] = [
            "id": .string(item.id),
            "title": .string(item.title),
            "listId": .string(item.listId),
            "list": .string(item.listTitle),
            "completed": .bool(item.completed),
            "priority": .int(item.priority)
        ]
        if let due = item.due { entry["due"] = .string(due) } else { entry["due"] = .null }
        if let notes = item.notes { entry["notes"] = .string(notes) }
        if let url = item.url { entry["url"] = .string(url) }
        if let location = item.location { entry["location"] = .string(location) }
        if let rule = item.recurrenceRule { entry["recurrenceRule"] = .string(rule) }
        if let alarms = item.alarms { entry["alarms"] = .array(alarms.map(formatAlarm)) }
        return .object(entry)
    }

    static func formatAlarm(_ alarm: AlarmItem) -> Value {
        var entry: [String: Value] = [
            "id": .string(alarm.id),
            "type": .string(alarm.type)
        ]
        if let m = alarm.triggerMinutesBefore { entry["triggerMinutesBefore"] = .int(m) }
        if let d = alarm.triggerAbsoluteDate { entry["triggerAbsoluteDate"] = .string(d) }
        if let lat = alarm.latitude { entry["latitude"] = .double(lat) }
        if let lon = alarm.longitude { entry["longitude"] = .double(lon) }
        if let r = alarm.radius { entry["radius"] = .double(r) }
        if let p = alarm.proximity { entry["proximity"] = .string(p) }
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

    private static func intArg(_ args: [String: Value], _ key: String) -> Int? {
        switch args[key] {
        case .int(let i)?: return i
        case .double(let d)?: return Int(d)
        default: return nil
        }
    }

    private static func doubleArg(_ args: [String: Value], _ key: String) -> Double? {
        switch args[key] {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return nil
        }
    }

    /// Parse the `alarms` argument (an array of objects) into `[AlarmDraft]`.
    /// Returns nil when the key is absent (leave unchanged); an empty array
    /// when an empty array was passed (clear-all sentinel on update).
    private static func parseAlarmArray(_ args: [String: Value], _ key: String) -> [AlarmDraft]? {
        guard case .array(let arr)? = args[key] else { return nil }
        return arr.compactMap { element in
            guard case .object(let obj) = element, let type = stringArg(obj, "type") else { return nil }
            return AlarmDraft(
                type: type,
                triggerMinutesBefore: intArg(obj, "triggerMinutesBefore"),
                triggerAbsoluteDate: stringArg(obj, "triggerAbsoluteDate"),
                latitude: doubleArg(obj, "latitude"),
                longitude: doubleArg(obj, "longitude"),
                radius: doubleArg(obj, "radius"),
                proximity: stringArg(obj, "proximity")
            )
        }
    }
}
