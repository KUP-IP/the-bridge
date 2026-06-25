// MemoryHubGuardrails.swift — commit guardrails + registry diff model (PKT-MEM-106 0c)
// TheBridge · Modules · VoiceMemo
//
// Pure, UI-free guardrail logic: lane-specific auto-execute thresholds, the
// duplicate-write key + force-reason enum, and the non-protected per-field diff
// model (protected fields stay append-only and are never offered as overwrites;
// all selected fields validate before any write). Locked values are SPEC §0.1.

import Foundation

/// Force-commit reason enum (Decision 1). A blocked duplicate may only proceed with
/// one of these; an optional free-text note may accompany it. Recorded in activity.
public enum DuplicateForceReason: String, Codable, Sendable, CaseIterable {
    case newContext = "new_context"
    case correction
    case operatorConfirmed = "operator_confirmed"
    case liveTest = "live_test"
}

public enum MemoryHubCommitGuardrails {

    /// Global auto-execute floor (all lanes must also clear this).
    public static let globalFloor = 0.80

    /// Lane-specific auto-execute thresholds (SPEC §0.1).
    public static func threshold(for kind: VoiceMemoIntentKind) -> Double {
        switch kind {
        case .reminder: return 0.90
        case .registryUpdate: return 0.86
        case .agentMemory: return 0.86
        case .memoryKeep: return 0.90
        case .review: return 1.01   // review lanes never auto-execute
        }
    }

    public enum AutoDecision: Equatable, Sendable {
        case auto
        case manual(reason: String)

        public var isAuto: Bool { self == .auto }
    }

    /// Whether the elected primary lane may auto-execute: confidence must clear BOTH the
    /// global floor AND the lane threshold, the registry target must be unambiguous, and
    /// the target must not be a stale-cache fallback. Everything else requires operator commit.
    public static func autoDecision(
        kind: VoiceMemoIntentKind,
        confidence: Double,
        targetAmbiguous: Bool = false,
        staleFallback: Bool = false
    ) -> AutoDecision {
        if targetAmbiguous { return .manual(reason: "ambiguous registry target") }
        if staleFallback { return .manual(reason: "stale cache target (>24h)") }
        if confidence < globalFloor { return .manual(reason: "below global floor \(globalFloor)") }
        if confidence < threshold(for: kind) { return .manual(reason: "below \(kind.rawValue) threshold \(threshold(for: kind))") }
        return .auto
    }

    /// Duplicate-write key = `memoId + intentId + destination key`, where the destination
    /// key is the minimum stable target/field/value identity (target system + row/field/value).
    public static func duplicateKey(memoId: String, intentId: String, destinationKey: String) -> String {
        "\(memoId)\u{1}\(intentId)\u{1}\(destinationKey)"
    }

    public enum ForceValidation: Equatable, Sendable {
        case ok(DuplicateForceReason)
        case rejected(String)
    }

    /// A force commit requires a reason from the fixed enum; an optional note is allowed.
    /// Commit cannot proceed until a valid reason is selected.
    public static func validateForce(reasonRaw: String?) -> ForceValidation {
        guard let reasonRaw, !reasonRaw.isEmpty else {
            return .rejected("force requires a reason from {new_context, correction, operator_confirmed, live_test}")
        }
        guard let reason = DuplicateForceReason(rawValue: reasonRaw) else {
            return .rejected("invalid force reason '\(reasonRaw)'; allowed: \(DuplicateForceReason.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return .ok(reason)
    }
}

/// One non-protected registry property change in the before/after diff.
public struct RegistryFieldDiff: Sendable, Equatable, Identifiable {
    public let field: String
    public let oldValue: String
    public let newValue: String
    public let isProtected: Bool
    public var id: String { field }
    public init(field: String, oldValue: String, newValue: String, isProtected: Bool) {
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.isProtected = isProtected
    }
}

public enum MemoryHubRegistryDiff {
    /// Append-only protected text fields (never offered as overwritable diffs).
    public static let protectedFields: Set<String> = ["brief", "objective", "summary", "description"]

    /// Per-field before/after diff over the proposed update (changed fields only).
    public static func diff(current: [String: String], proposed: [String: String]) -> [RegistryFieldDiff] {
        proposed.keys.sorted().compactMap { key in
            let old = current[key] ?? ""
            let new = proposed[key] ?? ""
            guard old != new else { return nil }
            return RegistryFieldDiff(field: key, oldValue: old, newValue: new, isProtected: protectedFields.contains(key))
        }
    }

    /// The selectable, overwritable subset (non-protected only). Protected fields stay
    /// append-only and are excluded from the overwrite set.
    public static func selectableNonProtected(_ diffs: [RegistryFieldDiff]) -> [RegistryFieldDiff] {
        diffs.filter { !$0.isProtected }
    }

    /// Human-readable old/new summary lines (the default diff display).
    public static func summary(_ diffs: [RegistryFieldDiff]) -> [String] {
        diffs.map { "\($0.field): \"\($0.oldValue)\" → \"\($0.newValue)\"\($0.isProtected ? " (append-only)" : "")" }
    }

    /// Expandable raw before/after JSON for debugging (sorted keys).
    public static func rawJSON(_ diffs: [RegistryFieldDiff]) -> String {
        // Non-trapping on duplicate field names (first wins).
        let before = Dictionary(diffs.map { ($0.field, $0.oldValue) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(diffs.map { ($0.field, $0.newValue) }, uniquingKeysWith: { first, _ in first })
        let payload: [String: [String: String]] = ["before": before, "after": after]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    public enum ApplyResult: Equatable, Sendable {
        case write([String: String])
        case rejected(String)
    }

    /// Apply only the selected fields, and only after ALL of them validate. If any selected
    /// field fails validation, write NOTHING (the intent stays uncommitted + review-visible).
    public static func apply(
        selected: [RegistryFieldDiff],
        validator: (RegistryFieldDiff) -> Bool = { !$0.newValue.isEmpty }
    ) -> ApplyResult {
        // Protected fields must never reach the overwrite path. Re-derive protection from
        // the canonical set (do NOT trust a caller-supplied isProtected flag).
        if let bad = selected.first(where: { protectedFields.contains($0.field) || $0.isProtected }) {
            return .rejected("protected field '\(bad.field)' cannot be overwritten (append-only)")
        }
        guard selected.allSatisfy(validator) else {
            return .rejected("validation failed for one or more selected fields — nothing written")
        }
        var write: [String: String] = [:]
        for diff in selected { write[diff.field] = diff.newValue }
        return .write(write)
    }
}
