// PathMigration.swift — One-time migration of legacy on-disk locations
// to the new canonical "The Bridge" folders.
//
// PKT-1 (v3.5): Existing pre-rebrand installs store data under one (or
// both!) of these legacy locations:
//   ~/Library/Application Support/Notion Bridge/   (display-name variant)
//   ~/Library/Application Support/NotionBridge/    (executable-name variant)
//
// On first launch we merge any legacy content into the new canonical home:
//   ~/Library/Application Support/The Bridge/
//
// NOTE: the 2026-06 internal NotionBridge*→TheBridge* identifier rename
// KEPT the on-disk dir "The Bridge" (and the bundle id), so "The Bridge"
// is the canonical destination — never a legacy SOURCE. Legacy names are
// the genuinely-old pre-rebrand dirs only (see BridgePaths.legacyNames).
//
// Properties guaranteed by `runOnce(fileManager:logger:)`:
//   • Idempotent — running twice leaves the filesystem identical to
//     running once. A sentinel file inside the canonical dir records
//     completion so subsequent launches no-op cheaply.
//   • Atomic per top-level entry — each file/folder is moved with
//     FileManager.moveItem, which on APFS is an atomic rename for items
//     on the same volume.
//   • Non-destructive — when a legacy directory is fully drained, it is
//     renamed in place to "<name>.legacy" rather than deleted. The user
//     can manually recover from there for one release cycle (or use
//     `purgeLegacy()` from Advanced → Maintenance later).
//   • Conflict-safe — if the canonical dir already contains a name that
//     collides with a legacy entry, the legacy entry is renamed with a
//     ".pre-migrate-<timestamp>" suffix so nothing is silently overwritten.
//
// The same protocol applies to ~/Library/Logs/ at the same time.

import Foundation

public enum PathMigration {

    /// Status return for telemetry / UI feedback.
    public struct Report: Equatable, Sendable {
        public let supportItemsMoved: Int
        public let logsItemsMoved: Int
        public let collisionsRenamed: Int
        public let alreadyComplete: Bool
        public let legacyArchivedAt: [URL]

        public static let noop = Report(
            supportItemsMoved: 0,
            logsItemsMoved: 0,
            collisionsRenamed: 0,
            alreadyComplete: true,
            legacyArchivedAt: []
        )
    }

    /// Sentinel filename inside the canonical Application Support dir that
    /// records a successful migration. Existence ⇒ skip migration.
    public static let sentinelName = ".bridge-migration-v3.5-complete"

    /// Run migration once. Safe to call on every launch — no-ops after the
    /// first successful run.
    @discardableResult
    public static func runOnce(
        fileManager fm: FileManager = .default,
        log: (String) -> Void = { print("[PathMigration] \($0)") }
    ) throws -> Report {

        // Ensure canonical destinations exist before we begin so moveItem
        // has somewhere to land. createDirectory with
        // withIntermediateDirectories:true is a no-op if it already exists.
        try fm.createDirectory(at: BridgePaths.applicationSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: BridgePaths.logs, withIntermediateDirectories: true)

        let sentinel = BridgePaths.applicationSupport.appendingPathComponent(sentinelName)
        if fm.fileExists(atPath: sentinel.path) {
            return .noop
        }

        var supportMoved = 0
        var logsMoved = 0
        var collisions = 0
        var archived: [URL] = []

        for legacy in BridgePaths.legacyApplicationSupportCandidates {
            let (moved, collisionCount, archivedTo) = try drain(
                legacy: legacy,
                into: BridgePaths.applicationSupport,
                fileManager: fm,
                log: log
            )
            supportMoved += moved
            collisions += collisionCount
            if let archivedTo { archived.append(archivedTo) }
        }

        for legacy in BridgePaths.legacyLogsCandidates {
            let (moved, collisionCount, archivedTo) = try drain(
                legacy: legacy,
                into: BridgePaths.logs,
                fileManager: fm,
                log: log
            )
            logsMoved += moved
            collisions += collisionCount
            if let archivedTo { archived.append(archivedTo) }
        }

        // Record completion. We write a small JSON-y manifest so future
        // versions can read provenance if useful.
        let manifest = """
        {"completedAt":"\(ISO8601DateFormatter().string(from: Date()))",\
        "supportItemsMoved":\(supportMoved),\
        "logsItemsMoved":\(logsMoved),\
        "collisionsRenamed":\(collisions)}
        """
        try manifest.write(to: sentinel, atomically: true, encoding: .utf8)

        log("migration complete — support:\(supportMoved) logs:\(logsMoved) collisions:\(collisions) archived:\(archived.count)")

        return Report(
            supportItemsMoved: supportMoved,
            logsItemsMoved: logsMoved,
            collisionsRenamed: collisions,
            alreadyComplete: false,
            legacyArchivedAt: archived
        )
    }

    // MARK: - Drain helper

    /// Moves every top-level entry from `legacy` into `destination` and
    /// then renames the (now-empty) `legacy` directory to "<name>.legacy".
    /// Returns the number of items moved, collisions renamed, and the URL
    /// of the archived legacy dir (nil if the legacy dir didn't exist).
    private static func drain(
        legacy: URL,
        into destination: URL,
        fileManager fm: FileManager,
        log: (String) -> Void
    ) throws -> (moved: Int, collisions: Int, archivedTo: URL?) {

        guard fm.fileExists(atPath: legacy.path) else {
            return (0, 0, nil)
        }
        // Refuse to migrate INTO ourselves (no-op if the user somehow has
        // the legacy and canonical names pointing at the same directory).
        if legacy.standardizedFileURL == destination.standardizedFileURL {
            return (0, 0, nil)
        }

        var moved = 0
        var collisions = 0

        let entries = try fm.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for src in entries {
            let target = destination.appendingPathComponent(src.lastPathComponent)
            var finalTarget = target

            if fm.fileExists(atPath: target.path) {
                let ts = Int(Date().timeIntervalSince1970)
                finalTarget = destination.appendingPathComponent(
                    "\(src.lastPathComponent).pre-migrate-\(ts)"
                )
                collisions += 1
                log("collision at \(target.lastPathComponent) — moving legacy to \(finalTarget.lastPathComponent)")
            }

            try fm.moveItem(at: src, to: finalTarget)
            moved += 1
        }

        // Archive the drained legacy dir if it's now empty. If anything
        // remains (e.g. hidden files like .DS_Store), we still archive
        // because the user can recover from there.
        let ts = Int(Date().timeIntervalSince1970)
        let archived = legacy.deletingLastPathComponent()
            .appendingPathComponent("\(legacy.lastPathComponent).legacy-\(ts)")
        try fm.moveItem(at: legacy, to: archived)
        log("archived legacy \(legacy.lastPathComponent) → \(archived.lastPathComponent)")

        return (moved, collisions, archived)
    }

    /// Reset the sentinel so the next launch re-runs migration. Intended
    /// for tests and the "Reset background items" maintenance flow.
    public static func resetSentinel(fileManager fm: FileManager = .default) throws {
        let sentinel = BridgePaths.applicationSupport.appendingPathComponent(sentinelName)
        if fm.fileExists(atPath: sentinel.path) {
            try fm.removeItem(at: sentinel)
        }
    }
}
