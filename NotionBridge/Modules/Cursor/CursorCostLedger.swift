// CursorCostLedger.swift — PKT-3.4.2 (Bridge v2.2)
// NotionBridge · Modules · Cursor
//
// Daily local cost ledger for Cursor agent runs. Provides soft / hard cap
// enforcement with notification fan-out so the UI surface (menu bar pill,
// Dashboard banner, notification dispatcher) can react without each consumer
// re-implementing threshold logic.
//
// Defaults: $25/day soft, $100/day hard (both configurable via UserDefaults
// keys below). Ledger rolls automatically at midnight in the user's local
// calendar. Persisted as JSON to:
//   ~/Library/Application Support/NotionBridge/cursor-cost-ledger.json
//
// Wave 1 (this packet) ships the ledger primitive + threshold notifications.
// Wave 2 wires CursorRuntime cost reports into `record(...)` and connects the
// banner UI / auto-pause action. Wave 3 wires hard-cap auto-terminate.
//
// Thread model: `actor` for mutation safety; all mutating APIs are async.
// Read-only snapshot APIs are nonisolated and safe from any thread.

import Foundation

// MARK: - Public types

public enum CursorCostCapTier: String, Codable, Sendable, CaseIterable {
    case under
    case soft
    case hard
}

/// Snapshot of the ledger for a given local date.
public struct CursorCostDay: Codable, Sendable, Equatable {
    /// Local calendar date in `yyyy-MM-dd` (the user's current TimeZone).
    public let dateLocal: String
    /// Sum of cents recorded for the day.
    public let totalCents: Int
    /// Per-run cents in insertion order (newest last).
    public let entries: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        public let runId: String
        public let cents: Int
        public let recordedAt: Date
        public let runtime: String?   // CursorRuntimeKind.rawValue, optional for back-compat
        public let model: String?

        public init(runId: String, cents: Int, recordedAt: Date, runtime: String? = nil, model: String? = nil) {
            self.runId = runId
            self.cents = cents
            self.recordedAt = recordedAt
            self.runtime = runtime
            self.model = model
        }
    }

    public init(dateLocal: String, totalCents: Int = 0, entries: [Entry] = []) {
        self.dateLocal = dateLocal
        self.totalCents = totalCents
        self.entries = entries
    }
}

/// Outcome of `record(...)` — lets the caller react (UI banner, auto-pause, terminate).
public struct CursorCostRecordResult: Sendable, Equatable {
    public let totalCents: Int
    public let tier: CursorCostCapTier
    /// `true` when this specific record crossed the soft or hard threshold
    /// (vs. having already crossed earlier in the day).
    public let crossedThreshold: Bool
}

// MARK: - UserDefaults keys

public enum CursorCostLedgerDefaults {
    public static let softCapCents = "com.notionbridge.cursor.softCapCents"
    public static let hardCapCents = "com.notionbridge.cursor.hardCapCents"
}

// MARK: - Actor

public actor CursorCostLedger {

    // MARK: Singleton

    public static let shared = CursorCostLedger()

    // MARK: Caps (defaults; UserDefaults overrides resolved on read)

    /// Default soft cap = $25.00 = 2500 cents.
    public static let defaultSoftCapCents = 2_500
    /// Default hard cap = $100.00 = 10_000 cents.
    public static let defaultHardCapCents = 10_000

    // MARK: State

    private var today: CursorCostDay
    private let storeURL: URL
    private let calendar: Calendar
    private let dateFormatter: DateFormatter

    // MARK: Init

    public init(
        storeURL: URL = CursorCostLedger.defaultStoreURL(),
        calendar: Calendar = Calendar.current
    ) {
        self.storeURL = storeURL
        self.calendar = calendar
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = f

        let todayStr = f.string(from: Date())
        if let loaded = CursorCostLedger.loadFromDisk(url: storeURL),
           loaded.dateLocal == todayStr {
            self.today = loaded
        } else {
            // Either no ledger yet, or yesterday's ledger — start fresh.
            // (Caller can inspect the on-disk file directly for history if needed;
            //  Wave 2 will introduce a rolling archive.)
            self.today = CursorCostDay(dateLocal: todayStr)
        }
    }

    // MARK: Default store location

    /// SPEC §7 canonical location — the sidecar dir owns the ledger.
    /// The Swift actor still owns the writer; placing the file inside the
    /// sidecar dir keeps the cost data co-located with the rest of the
    /// Cursor adapter state (sessions/, dist/, etc).
    public nonisolated static func defaultStoreURL() -> URL {
        let url = canonicalStoreURL()
        migrateLegacyIfNeeded(to: url)
        return url
    }

    private nonisolated static func canonicalStoreURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Application Support/NotionBridge/cursor-sidecar/cost-ledger.json",
            isDirectory: false
        )
    }

    /// Pre-PKT-3.4.1-RESCUE location. Retained for one-time migration only.
    private nonisolated static func legacyStoreURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Application Support/NotionBridge/cursor-cost-ledger.json",
            isDirectory: false
        )
    }

    /// One-shot migration: if a ledger exists at the legacy path but not at
    /// the new canonical path, copy it (best-effort) and rename the legacy
    /// file with a `.bak` suffix so future loads skip the migration.
    private nonisolated static func migrateLegacyIfNeeded(to newURL: URL) {
        let fm = FileManager.default
        let legacy = legacyStoreURL()
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: newURL.path) else {
            return
        }
        do {
            let dir = newURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try fm.copyItem(at: legacy, to: newURL)
            let bak = legacy.appendingPathExtension("bak")
            if fm.fileExists(atPath: bak.path) {
                try? fm.removeItem(at: bak)
            }
            try fm.moveItem(at: legacy, to: bak)
        } catch {
            FileHandle.standardError.write(Data(
                "[CursorCostLedger] migration failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    // MARK: Configurable caps (UserDefaults override)

    /// Effective soft cap in cents (UserDefaults override or default).
    public nonisolated static func softCapCents(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: CursorCostLedgerDefaults.softCapCents)
        return v > 0 ? v : defaultSoftCapCents
    }

    /// Effective hard cap in cents (UserDefaults override or default).
    public nonisolated static func hardCapCents(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: CursorCostLedgerDefaults.hardCapCents)
        return v > 0 ? v : defaultHardCapCents
    }

    // MARK: Read API

    /// Current day snapshot. Rolls the day silently if midnight has passed.
    public func snapshot() -> CursorCostDay {
        rollIfNeeded()
        return today
    }

    public func currentTotalCents() -> Int {
        rollIfNeeded()
        return today.totalCents
    }

    public func currentCapTier() -> CursorCostCapTier {
        rollIfNeeded()
        return Self.tier(
            forCents: today.totalCents,
            soft: Self.softCapCents(),
            hard: Self.hardCapCents()
        )
    }

    // MARK: Write API

    /// Record cost for a completed (or in-progress) agent run, persist, and emit
    /// `cursorAgentCostCapTripped` if this record crosses the soft or hard threshold.
    ///
    /// - Parameters:
    ///   - runId: The Cursor run identifier (CursorRun.id).
    ///   - cents: Cost delta in cents (must be ≥ 0; negatives are clamped to 0).
    ///   - runtime: Optional CursorRuntimeKind.rawValue for richer history.
    ///   - model: Optional model id for richer history.
    /// - Returns: Snapshot result with new total + tier + threshold-cross flag.
    @discardableResult
    public func record(
        runId: String,
        cents: Int,
        runtime: String? = nil,
        model: String? = nil,
        now: Date = Date()
    ) -> CursorCostRecordResult {
        rollIfNeeded(now: now)

        let delta = max(0, cents)
        let soft = Self.softCapCents()
        let hard = Self.hardCapCents()

        let priorTier = Self.tier(forCents: today.totalCents, soft: soft, hard: hard)
        let newTotal = today.totalCents + delta
        let entry = CursorCostDay.Entry(
            runId: runId,
            cents: delta,
            recordedAt: now,
            runtime: runtime,
            model: model
        )
        today = CursorCostDay(
            dateLocal: today.dateLocal,
            totalCents: newTotal,
            entries: today.entries + [entry]
        )
        persist()

        let newTier = Self.tier(forCents: newTotal, soft: soft, hard: hard)
        let crossed = newTier != priorTier && newTier != .under

        if crossed {
            let thresholdCents: Int = newTier == .hard ? hard : soft
            let userInfo: [String: Any] = [
                "tier": newTier.rawValue,
                "totalCents": newTotal,
                "thresholdCents": thresholdCents,
                "dateLocal": today.dateLocal
            ]
            NotificationCenter.default.post(
                name: .cursorAgentCostCapTripped,
                object: nil,
                userInfo: userInfo
            )
        }

        return CursorCostRecordResult(
            totalCents: newTotal,
            tier: newTier,
            crossedThreshold: crossed
        )
    }

    /// Reset the ledger for today (test / admin only). Does not delete history file.
    public func resetToday() {
        let todayStr = dateFormatter.string(from: Date())
        today = CursorCostDay(dateLocal: todayStr)
        persist()
    }

    // MARK: Roll

    private func rollIfNeeded(now: Date = Date()) {
        let todayStr = dateFormatter.string(from: now)
        if today.dateLocal != todayStr {
            today = CursorCostDay(dateLocal: todayStr)
            persist()
        }
    }

    // MARK: Tier helper

    public nonisolated static func tier(forCents cents: Int, soft: Int, hard: Int) -> CursorCostCapTier {
        if cents >= hard { return .hard }
        if cents >= soft { return .soft }
        return .under
    }

    // MARK: Persistence

    private func persist() {
        do {
            let dir = storeURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(today)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            // Persistence is best-effort. Swallow + log to stderr; an unwritable
            // ledger should not crash the app or block run recording.
            FileHandle.standardError.write(Data(
                "[CursorCostLedger] persist failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    nonisolated private static func loadFromDisk(url: URL) -> CursorCostDay? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CursorCostDay.self, from: data)
    }
}
