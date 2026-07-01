// VoiceMemoReviewStore.swift — low-confidence / failed routing review queue
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Disposition types (D8 / D9 / D13)

/// Scope for a dismiss operation: this lane only, or all sibling lanes for the memo.
public enum DismissScope: String, Sendable, Equatable, CaseIterable {
    case thisLane
    case allLanes
}

/// Result of a dismiss operation.
public struct DismissResult: Sendable, Equatable {
    /// True if the targeted lane (and any sibling lanes per scope) was found and dismissed.
    public let dismissed: Bool
    /// True if the source memo was marked processed as a result (all pending lanes resolved).
    public let memoMarkedProcessed: Bool
    /// True if sibling pending lanes exist and scope was .thisLane (caller may offer scope choice).
    public let hasSiblingLanes: Bool

    public init(dismissed: Bool, memoMarkedProcessed: Bool, hasSiblingLanes: Bool) {
        self.dismissed = dismissed
        self.memoMarkedProcessed = memoMarkedProcessed
        self.hasSiblingLanes = hasSiblingLanes
    }
}

/// Result of a trash operation (D9).
public struct TrashResult: Sendable, Equatable {
    /// Number of items moved to macOS Trash (audio + sidecars).
    public let itemsTrashed: Int
    /// Evidence id emitted to MemoryHubActivityLog.
    public let evidenceId: UUID

    public init(itemsTrashed: Int, evidenceId: UUID) {
        self.itemsTrashed = itemsTrashed
        self.evidenceId = evidenceId
    }
}

public struct VoiceMemoReviewEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case resolved
        case dismissed
    }

    public let id: String
    public var memoId: String
    public var memoTitle: String
    public var memoPath: String?
    public var intentKind: String
    public var confidence: Double
    public var reason: String
    public var transcriptExcerpt: String
    public var queuedAt: String
    /// Set when status leaves `pending` (dismiss, resolve, TTL auto-dismiss).
    public var statusChangedAt: String?
    public var status: Status

    // PKT-MEM-106 0a — per-intent identity + target metadata. Optional + defaulted so
    // legacy review.json entries (pre-0a, without these keys) decode cleanly; `intentId`
    // is nil for legacy entries until they are touched (resolved / dismissed / committed).
    public var intentId: String?
    public var entityKey: String?
    public var entityHint: String?
    public var rowId: String?
    public var destinationFields: [String: String]?
    public var provenance: String?
    /// Structured filter tag (PKT-MEM-120). Legacy entries derive via `effectiveReviewTag`.
    public var reviewTag: String?

    public init(
        id: String = UUID().uuidString,
        memoId: String,
        memoTitle: String,
        memoPath: String? = nil,
        intentKind: String,
        confidence: Double,
        reason: String,
        transcriptExcerpt: String,
        queuedAt: String = ISO8601DateFormatter().string(from: Date()),
        statusChangedAt: String? = nil,
        status: Status = .pending,
        intentId: String? = nil,
        entityKey: String? = nil,
        entityHint: String? = nil,
        rowId: String? = nil,
        destinationFields: [String: String]? = nil,
        provenance: String? = nil,
        reviewTag: String? = nil
    ) {
        self.id = id
        self.memoId = memoId
        self.memoTitle = memoTitle
        self.memoPath = memoPath
        self.intentKind = intentKind
        self.confidence = confidence
        self.reason = reason
        self.transcriptExcerpt = transcriptExcerpt
        self.queuedAt = queuedAt
        self.statusChangedAt = statusChangedAt
        self.status = status
        self.intentId = intentId
        self.entityKey = entityKey
        self.entityHint = entityHint
        self.rowId = rowId
        self.destinationFields = destinationFields
        self.provenance = provenance
        self.reviewTag = reviewTag
    }

    /// Anchor for TTL age — `statusChangedAt` when present, else `queuedAt`.
    public func statusAnchorDate() -> Date? {
        let iso = statusChangedAt ?? queuedAt
        return ISO8601DateFormatter().date(from: iso)
    }

    /// Stable per-intent id: the stored `intentId` when present, else derived on read
    /// from available canonical fields (PKT-MEM-106 0a legacy derive-on-read). When the
    /// canonical target fields are incomplete (legacy entries), falls back to a hash that
    /// folds `queuedAt` + `reason` so the derived id is deterministic across repeated reads.
    public func effectiveIntentId() -> String {
        if let intentId, !intentId.isEmpty { return intentId }
        let fields = destinationFields ?? [:]
        let hasCanonicalTarget = (entityKey?.isEmpty == false)
            || (entityHint?.isEmpty == false)
            || !fields.isEmpty
        if hasCanonicalTarget {
            return VoiceMemoIntentIdentity.intentId(
                memoId: memoId, kind: intentKind, entityKey: entityKey,
                entityHint: entityHint, title: memoTitle, fields: fields
            )
        }
        return VoiceMemoIntentIdentity.intentId(
            memoId: memoId, kind: intentKind, entityKey: nil, entityHint: nil,
            title: memoTitle, fields: ["queuedAt": queuedAt, "reason": reason]
        )
    }

    /// True when this entry carries no stored `intentId` (the id is derived on read).
    public var isLegacyDerived: Bool { (intentId ?? "").isEmpty }
}

public struct VoiceMemoReviewManifest: Codable, Sendable, Equatable {
    public var entries: [VoiceMemoReviewEntry]

    public init(entries: [VoiceMemoReviewEntry] = []) {
        self.entries = entries
    }

    public var pendingCount: Int {
        entries.filter { $0.status == .pending }.count
    }
}

public struct VoiceMemoReviewTTLSweepReport: Sendable, Equatable {
    public var autoDismissed: Int
    public var purged: Int

    public init(autoDismissed: Int = 0, purged: Int = 0) {
        self.autoDismissed = autoDismissed
        self.purged = purged
    }
}

public enum VoiceMemoReviewStore {
    public static let pendingTTLDays = 30
    public static let dismissedTTLDays = 7

    public static var manifestURL: URL {
        BridgePaths.applicationSupport(.voiceMemos).appendingPathComponent("review.json")
    }

    public static func load() -> VoiceMemoReviewManifest {
        let url = manifestURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VoiceMemoReviewManifest.self, from: data) else {
            return VoiceMemoReviewManifest()
        }
        return decoded
    }

    public static func save(_ manifest: VoiceMemoReviewManifest) throws {
        let dir = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    @discardableResult
    public static func enqueue(_ entry: VoiceMemoReviewEntry) throws -> VoiceMemoReviewEntry {
        var manifest = load()
        // Dedupe by per-intent identity (PKT-MEM-106 0a), NOT memoId+intentKind: two
        // same-kind lanes from one memo (distinct targets) have distinct intentIds and
        // must both persist (M5/M8). Re-enqueueing the same intentId replaces (idempotent).
        let newIntentId = entry.effectiveIntentId()
        manifest.entries.removeAll { $0.effectiveIntentId() == newIntentId && $0.status == .pending }
        manifest.entries.insert(entry, at: 0)
        try save(manifest)
        return entry
    }

    /// Persist the derived `intentId` onto an entry the first time it is touched
    /// (rewrite-on-touch — PKT-MEM-106 0a legacy migration; reads never rewrite).
    private static func materializeIntentId(_ entry: inout VoiceMemoReviewEntry) {
        if (entry.intentId ?? "").isEmpty {
            entry.intentId = entry.effectiveIntentId()
        }
    }

    public static func pendingEntries() -> [VoiceMemoReviewEntry] {
        load().entries.filter { $0.status == .pending }
    }

    /// Legacy single-Bool dismiss — kept for existing callers.
    @discardableResult
    public static func dismiss(id: String, at date: Date = Date()) throws -> Bool {
        let result = try dismissWithResult(id: id, scope: .thisLane, at: date)
        return result.dismissed
    }

    /// Structured dismiss with D8/D13 semantics.
    ///
    /// - When `scope == .thisLane`: dismiss just this lane. If sibling pending entries
    ///   exist for the same memo, `hasSiblingLanes` is true and the memo is NOT marked
    ///   processed yet (caller presents scope choice per D13).
    /// - When `scope == .allLanes`: dismiss this lane AND all sibling pending entries
    ///   for the same memo. Marks memo processed once all lanes are resolved.
    @discardableResult
    public static func dismissWithResult(
        id: String,
        scope: DismissScope = .thisLane,
        at date: Date = Date()
    ) throws -> DismissResult {
        var manifest = load()
        guard let idx = manifest.entries.firstIndex(where: { $0.id == id }) else {
            return DismissResult(dismissed: false, memoMarkedProcessed: false, hasSiblingLanes: false)
        }
        let memoId = manifest.entries[idx].memoId

        // Dismiss the targeted lane.
        manifest.entries[idx].status = .dismissed
        manifest.entries[idx].statusChangedAt = ISO8601DateFormatter().string(from: date)
        materializeIntentId(&manifest.entries[idx])

        if scope == .allLanes {
            // Dismiss all other pending lanes for the same memo.
            for i in manifest.entries.indices where manifest.entries[i].memoId == memoId
                && manifest.entries[i].id != id
                && manifest.entries[i].status == .pending {
                manifest.entries[i].status = .dismissed
                manifest.entries[i].statusChangedAt = ISO8601DateFormatter().string(from: date)
                materializeIntentId(&manifest.entries[i])
            }
        }

        try save(manifest)

        // Determine sibling state AFTER dismissal.
        let remainingPending = manifest.entries.filter {
            $0.memoId == memoId && $0.status == .pending
        }
        let hasSiblings = !remainingPending.isEmpty

        // Mark memo processed if gate is clear (no pending lanes remain).
        var markedProcessed = false
        if !hasSiblings {
            markedProcessed = (try? VoiceMemoProcessedGate.markProcessedIfClear(memoId: memoId, at: date)) ?? false
        }

        return DismissResult(
            dismissed: true,
            memoMarkedProcessed: markedProcessed,
            hasSiblingLanes: hasSiblings
        )
    }

    /// Trash: move the source audio file and sidecars to macOS Trash (D9).
    /// Dismisses ALL pending review entries for the memo and emits ACTIVITY evidence.
    public static func trash(memoId: String, at date: Date = Date()) async throws -> TrashResult {
        let evidenceId = UUID()

        // Collect URLs to trash.
        var urlsToTrash: [URL] = []

        // Find the audio file URL from the review entries or discovered recordings.
        var memoPath: String? = {
            let manifest = load()
            return manifest.entries.first(where: { $0.memoId == memoId })?.memoPath
        }()

        // Also check discovery roots if no path in review entries.
        if memoPath == nil {
            let roots = VoiceMemoDiscovery.defaultRecordingRoots()
            let recordings = VoiceMemoDiscovery.listRecordings(roots: roots)
            memoPath = recordings.first(where: { VoiceMemoDiscovery.stableId(for: URL(fileURLWithPath: $0.path)) == memoId })?.path
        }

        if let path = memoPath {
            let audioURL = URL(fileURLWithPath: path)
            let fm = FileManager.default
            if fm.fileExists(atPath: audioURL.path) {
                urlsToTrash.append(audioURL)
            }
            // Sidecars: transcript.json and summary.json alongside the audio.
            let base = audioURL.deletingPathExtension()
            let sidecarSuffixes = [".transcript.json", ".summary.json", ".json"]
            for suffix in sidecarSuffixes {
                let sidecar = base.deletingLastPathComponent()
                    .appendingPathComponent(base.lastPathComponent + suffix)
                if fm.fileExists(atPath: sidecar.path) {
                    urlsToTrash.append(sidecar)
                }
            }
        }

        // Move to macOS Trash via NSWorkspace (must call on main actor).
        var itemsTrashed = 0
        if !urlsToTrash.isEmpty {
#if canImport(AppKit)
            itemsTrashed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                let urlsCopy = urlsToTrash
                DispatchQueue.main.async {
                    NSWorkspace.shared.recycle(urlsCopy) { trashedURLs, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: trashedURLs.count)
                        }
                    }
                }
            }
#else
            // Fallback for non-AppKit builds: attempt FileManager removal.
            for url in urlsToTrash {
                if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                    itemsTrashed += 1
                }
            }
#endif
        }

        // Dismiss ALL pending review entries for this memo.
        var manifest = load()
        for i in manifest.entries.indices where manifest.entries[i].memoId == memoId
            && manifest.entries[i].status == .pending {
            manifest.entries[i].status = .dismissed
            manifest.entries[i].statusChangedAt = ISO8601DateFormatter().string(from: date)
            materializeIntentId(&manifest.entries[i])
        }
        try save(manifest)

        // Mark memo processed (gate should now be clear).
        try? VoiceMemoProcessedGate.markProcessedIfClear(memoId: memoId, at: date)

        // Emit ACTIVITY evidence (D9 / D12).
        let trashEvent = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: date),
            memoId: memoId,
            phase: .execute,
            action: "dispositionTrash",
            status: "completed",
            provenance: "VoiceMemoReviewStore.trash",
            actor: "system",
            detail: "Moved \(itemsTrashed) item(s) to Trash; evidenceId=\(evidenceId.uuidString)"
        )
        try? MemoryHubActivityLog.append(trashEvent, now: date)

        return TrashResult(itemsTrashed: itemsTrashed, evidenceId: evidenceId)
    }

    @discardableResult
    public static func resolve(id: String, at date: Date = Date()) throws -> Bool {
        var manifest = load()
        guard let idx = manifest.entries.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return false }
        manifest.entries[idx].status = .resolved
        manifest.entries[idx].statusChangedAt = ISO8601DateFormatter().string(from: date)
        materializeIntentId(&manifest.entries[idx])
        try save(manifest)
        return true
    }

    /// Pending entries older than `pendingDays` → auto-dismiss; dismissed entries
    /// older than `dismissedDays` → purge from manifest.
    public static func sweepTTL(
        now: Date = Date(),
        pendingDays: Int = pendingTTLDays,
        dismissedDays: Int = dismissedTTLDays
    ) throws -> VoiceMemoReviewTTLSweepReport {
        var manifest = load()
        var autoDismissed = 0
        let pendingCutoff = now.addingTimeInterval(-Double(pendingDays) * 86_400)
        let dismissedCutoff = now.addingTimeInterval(-Double(dismissedDays) * 86_400)
        let iso = ISO8601DateFormatter()

        for idx in manifest.entries.indices {
            guard manifest.entries[idx].status == .pending else { continue }
            guard let anchor = manifest.entries[idx].statusAnchorDate(), anchor < pendingCutoff else { continue }
            manifest.entries[idx].status = .dismissed
            manifest.entries[idx].statusChangedAt = iso.string(from: now)
            autoDismissed += 1
        }

        let before = manifest.entries.count
        manifest.entries.removeAll { entry in
            guard entry.status == .dismissed else { return false }
            let dismissedAt = entry.statusChangedAt.flatMap { iso.date(from: $0) }
                ?? iso.date(from: entry.queuedAt)
            guard let dismissedAt else { return false }
            return dismissedAt < dismissedCutoff
        }
        let purged = before - manifest.entries.count

        if autoDismissed > 0 || purged > 0 {
            try save(manifest)
        }
        return VoiceMemoReviewTTLSweepReport(autoDismissed: autoDismissed, purged: purged)
    }

    public static func entryValue(_ entry: VoiceMemoReviewEntry) -> Value {
        .object([
            "id": .string(entry.id),
            "memoId": .string(entry.memoId),
            "memoTitle": .string(entry.memoTitle),
            "memoPath": entry.memoPath.map { .string($0) } ?? .null,
            "intentKind": .string(entry.intentKind),
            "confidence": .double(entry.confidence),
            "reason": .string(entry.reason),
            "transcriptExcerpt": .string(entry.transcriptExcerpt),
            "queuedAt": .string(entry.queuedAt),
            "statusChangedAt": entry.statusChangedAt.map { .string($0) } ?? .null,
            "status": .string(entry.status.rawValue),
            "intentId": .string(entry.effectiveIntentId()),
            "legacyDerived": .bool(entry.isLegacyDerived),
            "entityKey": entry.entityKey.map { .string($0) } ?? .null,
            "entityHint": entry.entityHint.map { .string($0) } ?? .null,
            "rowId": entry.rowId.map { .string($0) } ?? .null,
        ])
    }
}
