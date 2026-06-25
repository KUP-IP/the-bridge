// MemoryProcessCockpit.swift — testable core for the Process three-zone cockpit (PKT-MEM-106 0b)
// TheBridge · Modules · VoiceMemo
//
// Pure, UI-free logic the SwiftUI Process tab renders: intent-table rows with a
// single primary marker (elected lane-priority-first, operator-overridable), the
// per-intent `voice_memo_commit` argument builder (threading a picker-selected
// rowId), the registry picker (live → cached fallback + 24h stale), and the
// Process↔Inbox mirror projection (the SAME pending review entries shown in both).

import Foundation
import MCP

/// One row in the Process intent table.
public struct CockpitIntentRow: Identifiable, Sendable, Equatable {
    public let intentId: String
    public let kind: VoiceMemoIntentKind
    public let confidence: Double
    public let entityKey: String?
    public let entityHint: String?
    public let title: String?
    public let destinationField: String
    public let fields: [String: String]
    public let dueISO8601: String?
    /// True for the single lane that will execute (elected primary or operator override).
    public var isPrimary: Bool
    /// True for the lane the election picked (before any override).
    public let isElectedPrimary: Bool
    public let status: String        // primary | suppressed | review
    public let warning: String?

    public var id: String { intentId }

    /// Rebuild a `VoiceMemoIntent` for commit/arg building.
    public func intent() -> VoiceMemoIntent {
        VoiceMemoIntent(kind: kind, confidence: confidence, entityKey: entityKey,
                        entityHint: entityHint, title: title, dueISO8601: dueISO8601, fields: fields)
    }
}

/// Picker state for the registry entity/row chooser.
public struct CockpitPickerState: Sendable, Equatable {
    public let entity: String
    public let rows: [MemoryHubRegistryRow]
    public let stale: Bool
    public let sourceError: String?
    public init(entity: String, rows: [MemoryHubRegistryRow], stale: Bool, sourceError: String?) {
        self.entity = entity
        self.rows = rows
        self.stale = stale
        self.sourceError = sourceError
    }
}

public enum MemoryProcessCockpit {

    /// Build the intent-table rows for a memo. Exactly one row is marked primary:
    /// the operator override when set + present, else the lane-priority-first election.
    public static func intentRows(memoId: String, plan: VoiceMemoPlan, overrideIntentId: String? = nil) -> [CockpitIntentRow] {
        // Collapse byte-identical lanes (same intentId — e.g. a duplicated Ollama parser lane)
        // so a duplicate can never produce two rows / two primaries. Distinct targets keep
        // distinct ids and are preserved. Matches the 0a review-store dedup (one-primary invariant).
        var seenIds = Set<String>()
        let intents = plan.intents.filter { intent in
            seenIds.insert(VoiceMemoIntentIdentity.intentId(memoId: memoId, intent: intent)).inserted
        }

        let split = VoiceMemoIntentElection.split(intents)
        let electedPrimary = split.execute.first { $0.kind != .review }
        let electedId = electedPrimary.map { VoiceMemoIntentIdentity.intentId(memoId: memoId, intent: $0) }

        // The override only takes effect if it names a real executable intent in this plan.
        let overridableIds = Set(intents.filter { $0.kind != .review }
            .map { VoiceMemoIntentIdentity.intentId(memoId: memoId, intent: $0) })
        let effectiveOverride = overrideIntentId.flatMap { overridableIds.contains($0) ? $0 : nil }
        let targetPrimaryId = effectiveOverride ?? electedId

        var primaryAssigned = false
        return intents.map { intent in
            let iid = VoiceMemoIntentIdentity.intentId(memoId: memoId, intent: intent)
            let isReview = intent.kind == .review
            let isElected = iid == electedId
            // Exactly one primary: the FIRST non-review row matching the target id. Dedup already
            // guarantees uniqueness; this guard hard-enforces the one-primary invariant regardless.
            var isPrimary = false
            if !isReview, !primaryAssigned, let targetPrimaryId, iid == targetPrimaryId {
                isPrimary = true
                primaryAssigned = true
            }
            let status = isReview ? "review" : (isPrimary ? "primary" : "suppressed")
            return CockpitIntentRow(
                intentId: iid,
                kind: intent.kind,
                confidence: intent.confidence,
                entityKey: intent.entityKey,
                entityHint: intent.entityHint,
                title: intent.title,
                destinationField: destinationLabel(for: intent),
                fields: intent.fields,
                dueISO8601: intent.dueISO8601,
                isPrimary: isPrimary,
                isElectedPrimary: isElected,
                status: status,
                warning: warning(for: intent)
            )
        }
    }

    /// `voice_memo_commit` arguments for one approved intent. A picker-selected
    /// `rowId` (0b) threads through to the writer (rowId wins over entityHint — 0a).
    public static func commitArguments(memoId: String, row: CockpitIntentRow, selectedRowId: String? = nil) -> [String: Value] {
        var args: [String: Value] = [
            "memoId": .string(memoId),
            "intentKind": .string(row.kind.rawValue),
        ]
        if let entityKey = row.entityKey, !entityKey.isEmpty { args["entityKey"] = .string(entityKey) }
        if let entityHint = row.entityHint, !entityHint.isEmpty { args["entityHint"] = .string(entityHint) }
        if let title = row.title, !title.isEmpty { args["title"] = .string(title) }
        if let due = row.dueISO8601, !due.isEmpty { args["due"] = .string(due) }
        if let rowId = selectedRowId, !rowId.isEmpty { args["rowId"] = .string(rowId) }
        if !row.fields.isEmpty { args["fields"] = .object(row.fields.mapValues { .string($0) }) }
        return args
    }

    /// Build the registry picker: live rows when available (also persisted as last-good),
    /// else the cached fallback with a stale flag (>24h) and recorded source error.
    public static func picker(entity: String, liveRows: [MemoryHubRegistryRow]?, sourceError: String? = nil, now: Date = Date()) -> CockpitPickerState {
        if let liveRows {
            try? MemoryHubRegistryCache.write(entity: entity, rows: liveRows, fetchedAt: now)
            return CockpitPickerState(entity: entity, rows: liveRows, stale: false, sourceError: nil)
        }
        let state = MemoryHubRegistryCache.state(entity: entity, now: now)
        let rows = MemoryHubRegistryCache.read(entity: entity)?.rows ?? []
        return CockpitPickerState(entity: entity, rows: rows, stale: state.stale, sourceError: sourceError ?? state.sourceError ?? "registry_list unavailable")
    }

    /// Whether this intent needs the registry picker (multiple registry lanes or an
    /// ambiguous/empty row hint).
    public static func needsPicker(rows: [CockpitIntentRow]) -> Bool {
        let registry = rows.filter { $0.kind == .registryUpdate }
        if registry.count > 1 { return true }
        return registry.contains { ($0.entityHint ?? "").isEmpty }
    }

    /// Process↔Inbox mirror: the unresolved lanes for a memo, grouped for Process.
    /// These are the SAME pending review entries the Inbox renders (one source of truth),
    /// so resolving/dismissing in either view clears the mirror.
    public static func processGroup(memoId: String, pending: [VoiceMemoReviewEntry]) -> [VoiceMemoReviewEntry] {
        pending.filter { $0.memoId == memoId && $0.status == .pending }
    }

    // MARK: - Labels

    static func destinationLabel(for intent: VoiceMemoIntent) -> String {
        switch intent.kind {
        case .reminder: return "Apple Reminders"
        case .agentMemory: return "Agent memory (full transcript)"
        case .memoryKeep: return "Notion Memory"
        case .registryUpdate:
            let entity = intent.entityKey ?? "?"
            let field = intent.fields.keys.sorted().first
            return field.map { "\(entity).\($0)" } ?? entity
        case .review: return "Needs review"
        }
    }

    static func warning(for intent: VoiceMemoIntent) -> String? {
        if intent.kind == .registryUpdate, (intent.entityHint ?? "").isEmpty, intent.entityKey != nil {
            return "no row hint — pick a row"
        }
        if intent.kind == .reminder, (intent.title ?? "").isEmpty {
            return "missing reminder title"
        }
        return nil
    }
}
