// PathMigrationTests.swift — verifies the v4.0 rename migration
// PKT-1: idempotency, atomicity, conflict handling, no-data-loss.

import Foundation
import NotionBridgeLib

/// Entry point called from main.swift.
func runPathMigrationTests() async {
    print("\n[PathMigration]")

    await test("BridgePaths.applicationSupport uses 'The Bridge' canonical name") {
        try expect(BridgePaths.applicationSupport.lastPathComponent == "The Bridge",
                   "expected 'The Bridge', got \(BridgePaths.applicationSupport.lastPathComponent)")
    }

    await test("BridgePaths.logs uses 'The Bridge' canonical name") {
        try expect(BridgePaths.logs.lastPathComponent == "The Bridge")
    }

    await test("BridgePaths.legacyNames includes both 3.x variants") {
        try expect(BridgePaths.legacyNames.contains("Notion Bridge"))
        try expect(BridgePaths.legacyNames.contains("NotionBridge"))
    }

    await test("BridgePaths subdir helper composes paths correctly") {
        let commands = BridgePaths.applicationSupport(.commands)
        try expect(commands.lastPathComponent == "commands")
        try expect(commands.deletingLastPathComponent().lastPathComponent == "The Bridge")
    }

    await test("PathMigration.runOnce no-ops when sentinel exists") {
        try await withTempHome { _ in
            // Run once to create the sentinel.
            let first = try PathMigration.runOnce(log: { _ in })
            try expect(!first.alreadyComplete, "first run should not be noop")

            // Second run should be a noop.
            let second = try PathMigration.runOnce(log: { _ in })
            try expect(second.alreadyComplete, "second run should be noop")
            try expect(second.supportItemsMoved == 0)
            try expect(second.logsItemsMoved == 0)
        }
    }

    await test("PathMigration moves entries from 'Notion Bridge' legacy dir") {
        try await withTempHome { home in
            let fm = FileManager.default
            let legacy = home
                .appendingPathComponent("Library/Application Support/Notion Bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let legacyFile = legacy.appendingPathComponent("snippets.json")
            try "ok".write(to: legacyFile, atomically: true, encoding: .utf8)

            let report = try PathMigration.runOnce(log: { _ in })
            try expect(report.supportItemsMoved == 1, "expected 1 moved, got \(report.supportItemsMoved)")

            let canonical = BridgePaths.applicationSupport.appendingPathComponent("snippets.json")
            try expect(fm.fileExists(atPath: canonical.path), "expected file at canonical path")

            // Legacy dir should have been archived, not deleted.
            try expect(!fm.fileExists(atPath: legacy.path), "legacy dir should no longer exist at original location")
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let children = try fm.contentsOfDirectory(atPath: support.path)
            let archived = children.contains(where: { $0.hasPrefix("Notion Bridge.legacy-") })
            try expect(archived, "expected archived legacy dir present, got \(children)")
        }
    }

    await test("PathMigration moves entries from 'NotionBridge' (no-space) legacy dir") {
        try await withTempHome { home in
            let fm = FileManager.default
            let legacy = home
                .appendingPathComponent("Library/Application Support/NotionBridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try "config".write(to: legacy.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            let report = try PathMigration.runOnce(log: { _ in })
            try expect(report.supportItemsMoved == 1)
            try expect(fm.fileExists(atPath:
                BridgePaths.applicationSupport.appendingPathComponent("config.json").path))
        }
    }

    await test("PathMigration merges BOTH legacy variants into one canonical dir") {
        try await withTempHome { home in
            let fm = FileManager.default
            let supportRoot = home.appendingPathComponent("Library/Application Support", isDirectory: true)

            let legacyA = supportRoot.appendingPathComponent("Notion Bridge", isDirectory: true)
            let legacyB = supportRoot.appendingPathComponent("NotionBridge", isDirectory: true)
            try fm.createDirectory(at: legacyA, withIntermediateDirectories: true)
            try fm.createDirectory(at: legacyB, withIntermediateDirectories: true)
            try "A".write(to: legacyA.appendingPathComponent("from-A.txt"), atomically: true, encoding: .utf8)
            try "B".write(to: legacyB.appendingPathComponent("from-B.txt"), atomically: true, encoding: .utf8)

            let report = try PathMigration.runOnce(log: { _ in })
            try expect(report.supportItemsMoved == 2, "expected 2 items, got \(report.supportItemsMoved)")

            let canonical = BridgePaths.applicationSupport
            try expect(fm.fileExists(atPath: canonical.appendingPathComponent("from-A.txt").path))
            try expect(fm.fileExists(atPath: canonical.appendingPathComponent("from-B.txt").path))
        }
    }

    await test("PathMigration renames collisions instead of overwriting") {
        try await withTempHome { home in
            let fm = FileManager.default
            // Pre-populate canonical with a file.
            try fm.createDirectory(at: BridgePaths.applicationSupport, withIntermediateDirectories: true)
            try "canonical-content".write(
                to: BridgePaths.applicationSupport.appendingPathComponent("commands.json"),
                atomically: true, encoding: .utf8)

            // Legacy has a same-named file with different content.
            let legacy = home.appendingPathComponent("Library/Application Support/Notion Bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try "legacy-content".write(
                to: legacy.appendingPathComponent("commands.json"),
                atomically: true, encoding: .utf8)

            let report = try PathMigration.runOnce(log: { _ in })
            try expect(report.collisionsRenamed == 1, "expected 1 collision, got \(report.collisionsRenamed)")

            // Canonical content survives unchanged.
            let canonical = BridgePaths.applicationSupport.appendingPathComponent("commands.json")
            let canonicalContent = try String(contentsOf: canonical, encoding: .utf8)
            try expect(canonicalContent == "canonical-content", "canonical content must not be overwritten")

            // Legacy content lands at a pre-migrate suffix.
            let entries = try fm.contentsOfDirectory(atPath: BridgePaths.applicationSupport.path)
            let preMigrate = entries.first(where: { $0.hasPrefix("commands.json.pre-migrate-") })
            try expect(preMigrate != nil, "expected pre-migrate sibling, got \(entries)")
        }
    }

    await test("PathMigration handles logs dir alongside application support") {
        try await withTempHome { home in
            let fm = FileManager.default
            let legacyLogs = home.appendingPathComponent("Library/Logs/NotionBridge", isDirectory: true)
            try fm.createDirectory(at: legacyLogs, withIntermediateDirectories: true)
            try "log-line".write(
                to: legacyLogs.appendingPathComponent("bridge.log"),
                atomically: true, encoding: .utf8)

            let report = try PathMigration.runOnce(log: { _ in })
            try expect(report.logsItemsMoved == 1, "expected 1 log moved, got \(report.logsItemsMoved)")
            try expect(fm.fileExists(atPath:
                BridgePaths.logs.appendingPathComponent("bridge.log").path))
        }
    }

    await test("PathMigration.resetSentinel allows re-running migration") {
        try await withTempHome { _ in
            _ = try PathMigration.runOnce(log: { _ in })
            try PathMigration.resetSentinel()
            let report = try PathMigration.runOnce(log: { _ in })
            try expect(!report.alreadyComplete, "after reset, runOnce should run again")
        }
    }
}

// MARK: - Test helpers

/// Sets up a tmpdir-rooted "home" and routes BridgePaths through it for
/// the duration of `body`. Restores the override before returning.
private func withTempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("BridgePaths-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
