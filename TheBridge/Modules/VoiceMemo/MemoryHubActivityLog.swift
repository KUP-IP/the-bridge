// MemoryHubActivityLog.swift — durable receipt log for the Memory Hub (PKT-MEM-106 0b)
// TheBridge · Modules · VoiceMemo
//
// Append-only JSONL at ~/Library/Application Support/The Bridge/memory-hub/activity.jsonl.
// Each line is one structured receipt envelope. PRIVACY (trust invariant): no full
// transcripts are ever written — transcript evidence is limited to a SHA-256 hash +
// short excerpt. The full SHA-256 receiptHash is stored; the UI / live-test tables
// reference only its first 12 chars. Retention prunes by 2000 events OR 90 days,
// whichever removes more. Survives relaunch (file-backed, not view state).

import Foundation
import CryptoKit

// MARK: — D12 Unified Operator Timeline Event Types

/// Typed event taxonomy for the ACTIVITY unified operator timeline (D12 / PKT-MEM-115).
/// Use `eventType` on `MemoryHubActivityEvent` to stamp a machine-readable category
/// alongside the freeform `action` string. `unknown` is the forward-compat fallback.
public enum MemoryHubActivityEventType: String, Codable, Sendable, CaseIterable {
    // Memo lifecycle
    case memoProcessed
    case memoTranscribed
    case memoSummarized
    case memoTitleGenerated

    // Disposition
    case dispositionDismissed
    case dispositionMarkHandled
    case dispositionSaveToKeep
    case dispositionSaveForAgents
    case dispositionCreateReminder
    case dispositionTrash

    // KEEP sync
    case keepSyncSuccess
    case keepSyncError
    case keepFieldAutoCreated

    // Agent memory
    case agentMemoryCreated
    case agentMemoryEdited
    case agentMemoryForgotten

    // Provider calls
    case providerCallStarted
    case providerCallCompleted
    case providerCallFailed
    case providerTestRun

    // Migration
    case migrationRun
    case migrationError

    /// Forward-compat fallback — decode unknown raw values to this.
    case unknown

    // Custom Codable: fall back to .unknown instead of throwing on unrecognised raw values,
    // so future event types added to the log don't break older Bridge versions reading the JSONL.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryHubActivityEventType(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One Memory Hub activity receipt (the structured envelope, SPEC §2 / PKT-MEM-106 0b).
public struct MemoryHubActivityEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case transcribe, understand, plan, execute, review, test
    }

    public var id: String { eventId }
    public let eventId: String
    /// Stable evidence identifier — UUID assigned at log time. Survives relaunch;
    /// may be referenced in ACTIVITY evidence fields (D9).
    public let evidenceId: UUID
    public let timestamp: String        // ISO-8601
    public let schemaVersion: Int
    public let memoId: String
    public let intentId: String?
    public let phase: Phase
    /// Machine-readable event category (D12). Defaults to `.unknown` for legacy events.
    public let eventType: MemoryHubActivityEventType
    public let action: String
    public let status: String
    public let provenance: String
    public let actor: String
    /// Receipt detail. NEVER a full transcript — for transcript-bearing events use
    /// `MemoryHubActivityLog.transcriptEvidence(_:)` (hash + short excerpt only).
    public let detail: String
    /// Full SHA-256 (64 hex) over the canonical content fields. Display via `receiptHashShort`.
    public let receiptHash: String

    /// First 12 chars of the full receipt hash — the value referenced in UI + grade tables.
    public var receiptHashShort: String { String(receiptHash.prefix(12)) }

    // MARK: Coding Keys (explicit — evidenceId added; eventType added; both have defaults for legacy rows)
    enum CodingKeys: String, CodingKey {
        case eventId, evidenceId, timestamp, schemaVersion, memoId, intentId
        case phase, eventType, action, status, provenance, actor, detail, receiptHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId       = try c.decode(String.self, forKey: .eventId)
        evidenceId    = try c.decodeIfPresent(UUID.self, forKey: .evidenceId) ?? UUID()
        timestamp     = try c.decode(String.self, forKey: .timestamp)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        memoId        = try c.decode(String.self, forKey: .memoId)
        intentId      = try c.decodeIfPresent(String.self, forKey: .intentId)
        phase         = try c.decode(Phase.self, forKey: .phase)
        // Forward-compat: unknown raw values fall back to .unknown
        eventType     = (try? c.decodeIfPresent(MemoryHubActivityEventType.self, forKey: .eventType)) ?? .unknown
        action        = try c.decode(String.self, forKey: .action)
        status        = try c.decode(String.self, forKey: .status)
        provenance    = try c.decode(String.self, forKey: .provenance)
        actor         = try c.decode(String.self, forKey: .actor)
        detail        = try c.decode(String.self, forKey: .detail)
        receiptHash   = try c.decode(String.self, forKey: .receiptHash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventId,       forKey: .eventId)
        try c.encode(evidenceId,    forKey: .evidenceId)
        try c.encode(timestamp,     forKey: .timestamp)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(memoId,        forKey: .memoId)
        try c.encodeIfPresent(intentId, forKey: .intentId)
        try c.encode(phase,         forKey: .phase)
        try c.encode(eventType,     forKey: .eventType)
        try c.encode(action,        forKey: .action)
        try c.encode(status,        forKey: .status)
        try c.encode(provenance,    forKey: .provenance)
        try c.encode(actor,         forKey: .actor)
        try c.encode(detail,        forKey: .detail)
        try c.encode(receiptHash,   forKey: .receiptHash)
    }

    public init(
        eventId: String = UUID().uuidString,
        evidenceId: UUID = UUID(),
        timestamp: String,
        schemaVersion: Int = MemoryHubActivityLog.schemaVersion,
        memoId: String,
        intentId: String? = nil,
        phase: Phase,
        eventType: MemoryHubActivityEventType = .unknown,
        action: String,
        status: String,
        provenance: String,
        actor: String,
        detail: String,
        receiptHash: String? = nil
    ) {
        self.eventId = eventId
        self.evidenceId = evidenceId
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
        self.memoId = memoId
        self.intentId = intentId
        self.phase = phase
        self.eventType = eventType
        self.action = action
        self.status = status
        self.provenance = provenance
        self.actor = actor
        self.detail = detail
        self.receiptHash = receiptHash ?? MemoryHubActivityLog.computeReceiptHash(
            memoId: memoId, intentId: intentId, phase: phase, action: action,
            status: status, provenance: provenance, actor: actor, detail: detail
        )
    }
}

public enum MemoryHubActivityLog {
    public static let schemaVersion = 1
    /// Retention bounds (D24): evict entries older than 90 days AND cap at 2000 total —
    /// whichever removes more events wins.
    public static let maxEvents = 2000
    public static let maxAgeDays = 90

    public static var fileURL: URL {
        BridgePaths.applicationSupport(.memoryHub).appendingPathComponent("activity.jsonl")
    }

    // MARK: Hashing

    public static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Full SHA-256 over the canonical CONTENT fields (excludes the random eventId +
    /// the timestamp), so identical content ⇒ identical hash; one field change ⇒ different.
    public static func computeReceiptHash(
        memoId: String, intentId: String?, phase: MemoryHubActivityEvent.Phase,
        action: String, status: String, provenance: String, actor: String, detail: String
    ) -> String {
        let canonical = [
            "memoId=\(memoId)", "intentId=\(intentId ?? "")", "phase=\(phase.rawValue)",
            "action=\(action)", "status=\(status)", "provenance=\(provenance)",
            "actor=\(actor)", "detail=\(detail)",
        ].joined(separator: "\u{1}")
        return sha256Hex(canonical)
    }

    /// Transcript evidence string for a `detail` field: a hash + short excerpt only.
    /// Guarantees the full transcript is NEVER written to the activity log.
    public static func transcriptEvidence(_ transcript: String, excerptLen: Int = 120) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = String(sha256Hex(trimmed).prefix(12))
        // Privacy invariant: never store a COMPLETE transcript. A short memo (≤ excerptLen)
        // would be its own excerpt, so omit the excerpt entirely and keep only the hash.
        guard trimmed.count > excerptLen else {
            return "transcript sha256=\(hash)… chars=\(trimmed.count) (excerpt omitted — short memo)"
        }
        let excerpt = String(trimmed.prefix(excerptLen)).replacingOccurrences(of: "\n", with: " ")
        return "transcript sha256=\(hash)… chars=\(trimmed.count) excerpt=\"\(excerpt)…\""
    }

    // MARK: Append / read

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Append one receipt as a single JSONL line (true append — prior lines are NOT
    /// rewritten in the common case). Prunes only when over the retention bound.
    public static func append(_ event: MemoryHubActivityEvent, now: Date = Date()) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = try encoder.encode(event)
        var payload = line
        payload.append(0x0A) // newline

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: fileURL, options: .atomic)
        }

        pruneIfNeeded(now: now)
    }

    /// All events in file (append) order — oldest first.
    public static func load() -> [MemoryHubActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(MemoryHubActivityEvent.self, from: d)
        }
    }

    /// The most recent `limit` events, newest first (for the activity strip).
    public static func recent(limit: Int = 50) -> [MemoryHubActivityEvent] {
        Array(load().suffix(limit).reversed())
    }

    // MARK: Corruption handling (non-destructive — PKT-MEM-106 0c)

    public struct LoadResult: Sendable, Equatable {
        public let events: [MemoryHubActivityEvent]
        public let skipped: Int
        /// Line index (0-based) of the first malformed line, if any.
        public let firstErrorOffset: Int?
    }

    /// Load tolerantly: skip malformed JSONL lines, counting how many were skipped and the
    /// first error offset. NEVER rewrites the file — the original (incl. corrupt lines) is preserved.
    public static func loadWithRepair() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else {
            return LoadResult(events: [], skipped: 0, firstErrorOffset: nil)
        }
        let decoder = JSONDecoder()
        var events: [MemoryHubActivityEvent] = []
        var skipped = 0
        var firstError: Int?
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let d = trimmed.data(using: .utf8), let event = try? decoder.decode(MemoryHubActivityEvent.self, from: d) {
                events.append(event)
            } else {
                skipped += 1
                if firstError == nil { firstError = index }
            }
        }
        return LoadResult(events: events, skipped: skipped, firstErrorOffset: firstError)
    }

    /// If corrupt lines are present, APPEND a repair activity (skipped count + first error
    /// offset) without removing/rewriting the corrupt line — the original file is preserved.
    /// Returns the number of corrupt lines found.
    @discardableResult
    public static func repairScan(now: Date = Date(), memoId: String = "system") -> Int {
        let result = loadWithRepair()
        guard result.skipped > 0 else { return 0 }
        let detail = "skipped \(result.skipped) corrupt line(s); first at line \(result.firstErrorOffset.map(String.init) ?? "?")"
        // Idempotent: don't append a duplicate repair receipt for the same corruption state
        // (safe to call on every launch / activity reload).
        guard !result.events.contains(where: { $0.action == "activity_repair" && $0.detail == detail }) else {
            return result.skipped
        }
        let repair = MemoryHubActivityEvent(
            timestamp: ISO8601DateFormatter().string(from: now), memoId: memoId, phase: .test,
            action: "activity_repair", status: "skipped", provenance: "loader", actor: "system",
            detail: detail
        )
        try? append(repair, now: now)
        return result.skipped
    }

    // MARK: Retention

    /// Keep the newest `maxEvents` events AND drop anything older than `maxAgeDays`
    /// — whichever bound bites first.
    public static func prune(_ events: [MemoryHubActivityEvent], now: Date) -> [MemoryHubActivityEvent] {
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let iso = ISO8601DateFormatter()
        let byAge = events.filter { event in
            guard let t = iso.date(from: event.timestamp) else { return true } // keep unparseable
            return t >= cutoff
        }
        if byAge.count > maxEvents {
            return Array(byAge.suffix(maxEvents))
        }
        return byAge
    }

    private static func pruneIfNeeded(now: Date) {
        // Never auto-rewrite a file that has corrupt lines — preserve the original
        // (PKT-MEM-106 0c: corruption handling is non-destructive). Repair is explicit.
        let scan = loadWithRepair()
        guard scan.skipped == 0 else { return }
        let events = scan.events
        let oldestAged: Bool = {
            guard let first = events.first,
                  let t = ISO8601DateFormatter().date(from: first.timestamp) else { return false }
            return t < now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        }()
        guard events.count > maxEvents || oldestAged else { return }
        let kept = prune(events, now: now)
        rewrite(kept)
    }

    private static func rewrite(_ events: [MemoryHubActivityEvent]) {
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
