// VoiceMemoIntentIdentity.swift — deterministic per-intent identity (PKT-MEM-106 0a)
// TheBridge · Modules · VoiceMemo
//
// One canonical `intentId` generator shared by the processor, review store,
// Process UI, and activity receipts. The id is stable across reruns and folds
// the intent's destination identity (entity + hint + fields + title) so two
// same-kind lanes from one memo (e.g. session vs project `registry_update`)
// never collapse to the same id.
//
// Contract (SPEC §0.1 / PKT-MEM-106 Success Criteria 1):
//   intentId = "intent_v1_" + first 20 hex of SHA-256 over canonical JSON
//   (sorted keys, trimmed strings, normalized whitespace, lowercase enums) of
//   memoId + kind + entityKey + entityHint + destination fields + normalized title
//   (+ due, when present — folded in for reminder distinctness; only ever ADDS
//   distinctness, never collides two distinct targets).

import Foundation
import CryptoKit

public enum VoiceMemoIntentIdentity {
    public static let prefix = "intent_v1_"
    /// First N hex chars of the SHA-256 digest kept after the prefix.
    public static let hexLength = 20

    /// Canonical per-intent id from explicit fields.
    public static func intentId(
        memoId: String,
        kind: String,
        entityKey: String?,
        entityHint: String?,
        title: String?,
        due: String? = nil,
        fields: [String: String] = [:]
    ) -> String {
        let canonical = canonicalJSON(
            memoId: memoId,
            kind: kind,
            entityKey: entityKey,
            entityHint: entityHint,
            title: title,
            due: due,
            fields: fields
        )
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return prefix + String(hex.prefix(hexLength))
    }

    /// Canonical per-intent id from a `VoiceMemoIntent`.
    public static func intentId(memoId: String, intent: VoiceMemoIntent) -> String {
        intentId(
            memoId: memoId,
            kind: intent.kind.rawValue,
            entityKey: intent.entityKey,
            entityHint: intent.entityHint,
            title: intent.title,
            due: intent.dueISO8601,
            fields: intent.fields
        )
    }

    /// Build the canonical JSON string. Keys are sorted at every level
    /// (`JSONSerialization.sortedKeys`), strings are trimmed + whitespace-normalized,
    /// enum-ish fields (`kind`, `entityKey`) are lowercased. Empty optional fields
    /// are omitted so absent vs empty hash identically.
    static func canonicalJSON(
        memoId: String,
        kind: String,
        entityKey: String?,
        entityHint: String?,
        title: String?,
        due: String?,
        fields: [String: String]
    ) -> String {
        var object: [String: Any] = [
            "memoId": canon(memoId),
            "kind": canonLower(kind),
        ]
        if let entityKey, !canon(entityKey).isEmpty { object["entityKey"] = canonLower(entityKey) }
        if let entityHint, !canon(entityHint).isEmpty { object["entityHint"] = canon(entityHint) }
        if let title, !canon(title).isEmpty { object["title"] = canon(title) }
        if let due, !canon(due).isEmpty { object["due"] = canon(due) }
        if !fields.isEmpty {
            var canonFields: [String: String] = [:]
            // Iterate raw keys in sorted order so that if two raw keys ever
            // canonicalize to the same key, the surviving value is deterministic
            // (last-write-wins by sorted raw key) rather than Dictionary-order
            // dependent. No effect on normal, already-distinct keys.
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                let k = canon(key)
                guard !k.isEmpty else { continue }
                canonFields[k] = canon(value)
            }
            if !canonFields.isEmpty { object["fields"] = canonFields }
        }

        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        // Deterministic fallback if serialization ever fails (should not for String values).
        return object.keys.sorted().map { "\($0)=\(object[$0].map { "\($0)" } ?? "")" }.joined(separator: "\u{1}")
    }

    /// Trim + collapse internal whitespace runs to a single space.
    static func canon(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Canonicalize then lowercase (for enum-like fields).
    static func canonLower(_ string: String) -> String {
        canon(string).lowercased()
    }
}
