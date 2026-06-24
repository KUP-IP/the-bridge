// VoiceMemoReviewStore.swift — low-confidence / failed routing review queue
// TheBridge · Modules · VoiceMemo

import Foundation
import MCP

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
        status: Status = .pending
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
    }

    /// Anchor for TTL age — `statusChangedAt` when present, else `queuedAt`.
    public func statusAnchorDate() -> Date? {
        let iso = statusChangedAt ?? queuedAt
        return ISO8601DateFormatter().date(from: iso)
    }
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
        manifest.entries.removeAll { $0.memoId == entry.memoId && $0.intentKind == entry.intentKind && $0.status == .pending }
        manifest.entries.insert(entry, at: 0)
        try save(manifest)
        return entry
    }

    public static func pendingEntries() -> [VoiceMemoReviewEntry] {
        load().entries.filter { $0.status == .pending }
    }

    @discardableResult
    public static func dismiss(id: String, at date: Date = Date()) throws -> Bool {
        var manifest = load()
        guard let idx = manifest.entries.firstIndex(where: { $0.id == id }) else { return false }
        manifest.entries[idx].status = .dismissed
        manifest.entries[idx].statusChangedAt = ISO8601DateFormatter().string(from: date)
        try save(manifest)
        return true
    }

    @discardableResult
    public static func resolve(id: String, at date: Date = Date()) throws -> Bool {
        var manifest = load()
        guard let idx = manifest.entries.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return false }
        manifest.entries[idx].status = .resolved
        manifest.entries[idx].statusChangedAt = ISO8601DateFormatter().string(from: date)
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
        ])
    }
}
