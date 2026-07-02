// CapabilityPreflight.swift — PKT-1065C
// TheBridge · Modules · StandingOrders
//
// Intent-sensitive capability preflight. Sub-packet C of PKT-1065 populates
// the capability axis of A's HandshakeReceipt (capabilityState +
// capabilityMatrix) WITHOUT bloating a universal, data-minimal handshake.
//
// CORE PRINCIPLE — data-minimal by default, probe only on demand:
//   • Universal initialization (no opening intent) runs ZERO domain probes.
//     A cold start reports only the base capability matrix A already derives
//     (mac_tools / cloud_channel / doctrine_loaded / routing_roster).
//   • A domain probe runs ONLY when the opening INTENT requires that domain.
//     `CapabilityPreflightRegistry` maps an intent → the probes it unlocks.
//     No intent ⇒ no probe ⇒ no side effects and no broad enumeration.
//
// FIRST ADAPTER — Reminders:
//   • Access status + writable/default-list availability are a CHEAP, bounded
//     discovery: enumerate LISTS (a handful of EKCalendars), never the
//     reminders inside them.
//   • A bounded READ of reminder CONTENT happens ONLY when the intent requires
//     reminder items (e.g. "what's on my reminders"), and even then it is
//     capped (`contentReadCap`) — never a full-store enumeration on a cold
//     start.
//
// The probes take the same injectable `RemindersStoring` seam the
// RemindersModule uses, so the whole preflight is hermetically testable with
// the existing `MockRemindersStore` — no live EventKit / TCC.

import Foundation

// MARK: - Intent classification

/// A coarse classification of the OPENING intent of a handshake. Universal
/// init carries `.none` — the data-minimal path. A domain intent unlocks the
/// probe(s) registered for that domain.
public enum PreflightIntent: String, Codable, Sendable, Equatable {
    /// No domain intent — universal, data-minimal init. Runs zero probes.
    case none = "none"
    /// The opening task concerns reminders but does NOT need their content
    /// (e.g. "add a reminder", "which list is default?"). Probes access +
    /// writable/default list availability. NEVER enumerates reminders.
    case remindersManage = "reminders.manage"
    /// The opening task needs to READ reminder content (e.g. "what's due
    /// today", "list my reminders"). Adds a BOUNDED content read on top of the
    /// access + list discovery.
    case remindersRead = "reminders.read"

    /// Classify a free-text opening intent into a preflight intent. Conservative
    /// by design: only an explicit reminders signal unlocks the reminders probe,
    /// and only an explicit read/list/query verb escalates to a content read.
    /// Anything unrecognized stays `.none` (data-minimal).
    public static func classify(_ raw: String?) -> PreflightIntent {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        // Already a canonical token?
        if let exact = PreflightIntent(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return exact
        }
        let t = raw.lowercased()
        let mentionsReminders =
            t.contains("reminder") || t.contains("to-do") || t.contains("todo") || t.contains("to do")
        guard mentionsReminders else { return .none }
        // Read/list/query verbs escalate to a bounded content read.
        let readVerbs = ["list", "show", "read", "what", "which reminders", "due", "overdue",
                         "what's on", "whats on", "review", "check my", "see my", "find"]
        if readVerbs.contains(where: { t.contains($0) }) {
            return .remindersRead
        }
        return .remindersManage
    }
}

// MARK: - Probe result

/// The outcome of one domain capability probe. Contributes `entries` to the
/// receipt's capabilityMatrix and may downgrade the overall capabilityState
/// (a required domain that is denied/unavailable makes the runtime LIMITED for
/// that intent). Every probe is DATA-MINIMAL: it reports availability, not the
/// domain's contents, unless the intent explicitly required a bounded read.
public struct CapabilityProbeResult: Sendable, Equatable {
    /// The domain this probe covers (e.g. "reminders").
    public let domain: String
    /// Whether the probed capability is usable for the requesting intent.
    public let available: Bool
    /// Capability matrix entries this probe contributes (merged into A's base
    /// matrix). Names are namespaced (e.g. "reminders.access").
    public let entries: [CapabilityEntry]
    /// Human-readable, operator-facing one-liners (surfaced in the summary).
    public let notes: [String]
    /// Whether a bounded content read was performed (intent required it). When
    /// false, NO reminder content was read — only access + list discovery.
    public let contentRead: Bool

    public init(
        domain: String,
        available: Bool,
        entries: [CapabilityEntry],
        notes: [String],
        contentRead: Bool
    ) {
        self.domain = domain
        self.available = available
        self.entries = entries
        self.notes = notes
        self.contentRead = contentRead
    }
}

// MARK: - Probe protocol

/// A single domain capability probe. Runs ONLY when the registry decides the
/// intent requires it. Must be data-minimal: enumerate availability, not
/// contents, unless the intent explicitly requested a bounded read.
public protocol CapabilityProbe: Sendable {
    var domain: String { get }
    /// Does this probe apply to the given intent? Governs whether it runs at
    /// all — the registry NEVER runs a probe whose `applies` is false.
    func applies(to intent: PreflightIntent) -> Bool
    /// Execute the probe for the given intent. `intent` tells the probe whether
    /// a bounded content read is in scope.
    func run(intent: PreflightIntent) async -> CapabilityProbeResult
}

// MARK: - Reminders adapter (first adapter)

/// The first capability adapter: Reminders. Reports access status and
/// writable/default-list availability, and performs a BOUNDED content read
/// ONLY when the intent is `.remindersRead`. Never enumerates all reminders.
public struct RemindersCapabilityProbe: CapabilityProbe {
    public let domain = "reminders"

    /// Hard cap on the bounded content read — even when the intent requires
    /// reading reminder content, we sample at most this many items. This is a
    /// preflight, not a query tool: the goal is to prove content is reachable,
    /// not to page the whole store.
    public static let contentReadCap = 5

    private let store: RemindersStoring

    public init(store: RemindersStoring) {
        self.store = store
    }

    public func applies(to intent: PreflightIntent) -> Bool {
        intent == .remindersManage || intent == .remindersRead
    }

    public func run(intent: PreflightIntent) async -> CapabilityProbeResult {
        // 1. Access status — cheap, no enumeration.
        let status = store.authorizationStatus()
        let authorized = status == .authorized
        let statusLabel: String = {
            switch status {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "notDetermined"
            }
        }()

        var entries: [CapabilityEntry] = [
            CapabilityEntry(capability: "reminders.access", available: authorized, detail: statusLabel)
        ]
        var notes: [String] = []

        guard authorized else {
            notes.append("Reminders access is \(statusLabel) — no list or content probe performed.")
            entries.append(CapabilityEntry(capability: "reminders.writable_list", available: false,
                                           detail: "unknown (access \(statusLabel))"))
            return CapabilityProbeResult(
                domain: domain, available: false, entries: entries,
                notes: notes, contentRead: false)
        }

        // 2. Writable / default list discovery — enumerate LISTS (a handful of
        //    calendars), NEVER the reminders inside them.
        var writableAvailable = false
        var defaultWritable = false
        do {
            let lists = try await store.lists()
            let writable = lists.filter { $0.allowsModify }
            writableAvailable = !writable.isEmpty
            let def = lists.first { $0.isDefault }
            defaultWritable = def?.allowsModify ?? false
            entries.append(CapabilityEntry(
                capability: "reminders.writable_list",
                available: writableAvailable,
                detail: "\(writable.count) writable of \(lists.count) list(s)"))
            entries.append(CapabilityEntry(
                capability: "reminders.default_list",
                available: def != nil,
                detail: def.map { $0.allowsModify ? "\($0.title) (writable)" : "\($0.title) (read-only)" }
                    ?? "no default list"))
            if !writableAvailable {
                notes.append("Reminders access granted but no writable list — creates will fail.")
            } else if !defaultWritable && def != nil {
                notes.append("Default reminders list is read-only; creates need an explicit writable listId.")
            }
        } catch {
            entries.append(CapabilityEntry(capability: "reminders.writable_list", available: false,
                                           detail: "list discovery failed"))
            notes.append("Reminders list discovery failed: \(error.localizedDescription)")
            return CapabilityProbeResult(
                domain: domain, available: false, entries: entries,
                notes: notes, contentRead: false)
        }

        // 3. Bounded content read — ONLY when the intent requires reminder
        //    content. NEVER on a cold start / manage-only intent.
        var didReadContent = false
        if intent == .remindersRead {
            do {
                // Not includeCompleted; the store fetch is bounded post-hoc to
                // contentReadCap so this is a SAMPLE, not an enumeration.
                let items = try await store.fetch(ReminderQuery(includeCompleted: false))
                let sample = items.prefix(Self.contentReadCap)
                didReadContent = true
                entries.append(CapabilityEntry(
                    capability: "reminders.content",
                    available: !items.isEmpty,
                    detail: "sampled \(sample.count) (cap \(Self.contentReadCap)) of \(items.count) open"))
                notes.append("Bounded reminder-content read performed (intent required content); "
                    + "sampled \(sample.count) item(s), cap \(Self.contentReadCap).")
            } catch {
                entries.append(CapabilityEntry(capability: "reminders.content", available: false,
                                               detail: "content read failed"))
                notes.append("Bounded reminder-content read failed: \(error.localizedDescription)")
            }
        }

        return CapabilityProbeResult(
            domain: domain,
            available: writableAvailable,
            entries: entries,
            notes: notes,
            contentRead: didReadContent)
    }
}

// MARK: - Registry

/// The intent-sensitive capability-preflight registry. Owns the set of domain
/// probes and decides — from the opening intent — which (if any) to run. The
/// universal, data-minimal path (`.none`) runs NOTHING.
public struct CapabilityPreflightRegistry: Sendable {
    private let probes: [CapabilityProbe]

    public init(probes: [CapabilityProbe]) {
        self.probes = probes
    }

    /// The probes that WOULD run for the given intent (without running them).
    /// Exposed so a data-minimal guarantee is directly assertable in tests.
    public func applicableProbes(for intent: PreflightIntent) -> [CapabilityProbe] {
        guard intent != .none else { return [] }
        return probes.filter { $0.applies(to: intent) }
    }

    /// Run exactly the probes the intent requires, in registration order.
    /// Returns an empty array for `.none` — no probe, no side effect.
    public func run(intent: PreflightIntent) async -> [CapabilityProbeResult] {
        var results: [CapabilityProbeResult] = []
        for probe in applicableProbes(for: intent) {
            results.append(await probe.run(intent: intent))
        }
        return results
    }
}

// MARK: - Routing roster quality

/// The routing-roster quality axis — richer than A's loaded/missing. Surfaced
/// in the receipt + operator summary so a thin or empty roster is visible at
/// handshake, not discovered mid-task.
public enum RoutingRosterQuality: String, Codable, Sendable, Equatable {
    /// Roster is present and has enough entries to route confidently.
    case healthy = "HEALTHY"
    /// Roster loaded but sparse (few entries) — routing may be unreliable.
    case sparse = "SPARSE"
    /// Roster is empty / missing — a required-source gap.
    case empty = "EMPTY"

    /// Derive quality from the rendered routing index. `sparseThreshold` is the
    /// entry count below which a loaded roster is considered SPARSE.
    public static func assess(rendered: String, sparseThreshold: Int = 3) -> RoutingRosterQuality {
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains("_None registered yet._") {
            return .empty
        }
        // Each routing skill renders as a top-level "- **" bullet.
        let entryCount = rendered
            .split(whereSeparator: { $0.isNewline })
            .filter { $0.hasPrefix("- **") }
            .count
        if entryCount == 0 {
            // Non-empty text but no recognizable entries → treat as empty roster.
            return .empty
        }
        return entryCount < sparseThreshold ? .sparse : .healthy
    }
}

// MARK: - Operator summary

/// Renders the operator-facing summary of a handshake receipt. This is the
/// human-readable companion to the structured receipt: it surfaces the
/// supplemental-order tri-state (found / operative / ignored), routing-roster
/// quality + warnings, the capability axis (SEPARATE from init state), and any
/// probe notes — in both the receipt (`operatorSummary`) and any operator UI.
public enum OperatorSummary {
    /// Build the multi-line operator summary for a receipt.
    public static func render(_ r: HandshakeReceipt) -> String {
        var lines: [String] = []
        lines.append("Bridge handshake \(r.handshakeId.prefix(8)) — init: \(r.finalState.rawValue), "
            + "capability: \(r.capabilityState.rawValue)")
        lines.append("Doctrine \(r.doctrineVersion) · integrity \(r.integrityResult)")

        // Supplemental orders — tri-state, NOT one undifferentiated count.
        let s = r.supplementalOrderCounts
        lines.append("Supplemental orders: \(s.found) found · \(s.operative) operative · \(s.ignored) ignored")

        // Routing roster — state + quality + warnings.
        var routingLine = "Routing roster: \(r.routingRosterState) (\(r.routingRosterQuality.rawValue))"
        if !r.routingWarnings.isEmpty {
            routingLine += " — " + r.routingWarnings.joined(separator: "; ")
        }
        lines.append(routingLine)

        // Capability probes (only present when an intent required them).
        if r.preflightIntent != .none {
            lines.append("Preflight intent: \(r.preflightIntent.rawValue)")
        }
        if !r.capabilityNotes.isEmpty {
            for note in r.capabilityNotes {
                lines.append("  • \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
