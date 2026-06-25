// MemoryHubPlanSnapshot.swift — versioned preview/enhancement snapshots (PKT-MEM-106 0c)
// TheBridge · Modules · VoiceMemo
//
// Per-memo plan snapshots at memory-hub/plan-snapshots/<memoId>.json. Preview is
// progressive (heuristic → local-auto → cloud-manual); each result is a versioned
// snapshot. Retention keeps the heuristic, latest-enhanced, and committed snapshot
// per memo (intermediates pruned), on write AND a launch/wake sweep. Enhancement may
// add / change / demote intents but may NEVER silently remove a heuristic intent —
// a removal candidate is carried forward as `demoted` and stays visible until committed.

import Foundation

public struct PlanSnapshotIntent: Codable, Sendable, Equatable, Identifiable {
    public let intentId: String
    public let kind: String
    public let confidence: Double
    public let entityKey: String?
    public let entityHint: String?
    public let title: String?
    public let fields: [String: String]
    /// Demoted / superseded by a later enhancement — still visible, never silently dropped.
    public var demoted: Bool
    public var id: String { intentId }

    public init(intentId: String, kind: String, confidence: Double, entityKey: String?,
                entityHint: String?, title: String?, fields: [String: String], demoted: Bool = false) {
        self.intentId = intentId; self.kind = kind; self.confidence = confidence
        self.entityKey = entityKey; self.entityHint = entityHint; self.title = title
        self.fields = fields; self.demoted = demoted
    }
}

public struct PlanSnapshot: Codable, Sendable, Equatable {
    public enum Provenance: String, Codable, Sendable { case heuristic, local, cloud, committed }
    public let memoId: String
    public let provenance: Provenance
    public let version: Int
    public let createdAt: String
    public var intents: [PlanSnapshotIntent]

    public init(memoId: String, provenance: Provenance, version: Int, createdAt: String, intents: [PlanSnapshotIntent]) {
        self.memoId = memoId; self.provenance = provenance; self.version = version
        self.createdAt = createdAt; self.intents = intents
    }

    public var isEnhanced: Bool { provenance == .local || provenance == .cloud }
}

public enum MemoryHubPlanSnapshotStore {

    public static var dir: URL {
        BridgePaths.applicationSupport(.memoryHub).appendingPathComponent("plan-snapshots", isDirectory: true)
    }
    public static func fileURL(memoId: String) -> URL {
        dir.appendingPathComponent("\(MemoryHubRegistryCache.safeName(memoId)).json")
    }

    public static func load(memoId: String) -> [PlanSnapshot] {
        guard let data = try? Data(contentsOf: fileURL(memoId: memoId)),
              let snaps = try? JSONDecoder().decode([PlanSnapshot].self, from: data) else { return [] }
        return snaps
    }

    /// Append a snapshot, prune to {heuristic, latest-enhanced, committed}, and persist.
    @discardableResult
    public static func append(_ snapshot: PlanSnapshot) throws -> [PlanSnapshot] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var snaps = load(memoId: snapshot.memoId)
        snaps.append(snapshot)
        snaps = prune(snaps)
        let data = try JSONEncoder().encode(snaps)
        try data.write(to: fileURL(memoId: snapshot.memoId), options: .atomic)
        return snaps
    }

    /// Retain the heuristic, the latest-enhanced (highest-version local/cloud), and the
    /// committed snapshot per memo; intermediate enhanced drafts are pruned.
    public static func prune(_ snapshots: [PlanSnapshot]) -> [PlanSnapshot] {
        guard !snapshots.isEmpty else { return [] }
        let heuristic = snapshots.last { $0.provenance == .heuristic }
        let committed = snapshots.last { $0.provenance == .committed }
        let latestEnhanced = snapshots.filter { $0.isEnhanced }.max { $0.version < $1.version }
        // Preserve original order, de-duplicated by identity (provenance+version).
        var kept: [PlanSnapshot] = []
        for snap in snapshots {
            let keep = snap == heuristic || snap == committed || snap == latestEnhanced
            if keep, !kept.contains(snap) { kept.append(snap) }
        }
        return kept
    }

    /// Launch/wake sweep: prune every memo's snapshot file.
    public static func launchSweep() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snaps = try? JSONDecoder().decode([PlanSnapshot].self, from: data) else { continue }
            let pruned = prune(snaps)
            if pruned != snaps, let out = try? JSONEncoder().encode(pruned) {
                try? out.write(to: file, options: .atomic)
            }
        }
    }

    // MARK: Enhancement authority (no silent removal) + diff badges

    /// Build an enhanced intent set from a heuristic baseline WITHOUT silently removing
    /// any heuristic intent: an intent present in `heuristic` but absent from `enhanced`
    /// is carried forward marked `demoted` (still visible). Added/changed intents come
    /// from `enhanced`.
    public static func mergePreservingDemoted(heuristic: [PlanSnapshotIntent], enhanced: [PlanSnapshotIntent]) -> [PlanSnapshotIntent] {
        let enhancedIds = Set(enhanced.map(\.intentId))
        var result = enhanced
        for intent in heuristic where !enhancedIds.contains(intent.intentId) {
            var demotedIntent = intent
            demotedIntent.demoted = true
            result.append(demotedIntent)
        }
        return result
    }

    /// Per-intent diff badge between two snapshots: added / changed / demoted.
    public static func diffBadges(from: PlanSnapshot, to: PlanSnapshot) -> [String: String] {
        let fromById = Dictionary(uniqueKeysWithValues: from.intents.map { ($0.intentId, $0) })
        var badges: [String: String] = [:]
        for intent in to.intents {
            if intent.demoted {
                badges[intent.intentId] = "demoted"
            } else if let prior = fromById[intent.intentId] {
                if prior.confidence != intent.confidence || prior.fields != intent.fields || prior.title != intent.title {
                    badges[intent.intentId] = "changed"
                }
            } else {
                badges[intent.intentId] = "added"
            }
        }
        return badges
    }
}
