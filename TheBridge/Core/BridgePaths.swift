// BridgePaths.swift — Single source of truth for on-disk locations.
// PKT-1 (v3.5): The app rebranded "Notion Bridge → The Bridge"; this
// consolidates the previously-inconsistent path naming (the codebase
// historically used both "NotionBridge" and "Notion Bridge" as folder
// names) into one canonical home: "The Bridge".
//
// Legacy directory variants are migrated on first launch by
// `PathMigration.runOnce()` so existing 3.x installs survive the rename.
//
// USAGE:
//   BridgePaths.applicationSupport            // ~/Library/Application Support/The Bridge/
//   BridgePaths.logs                          // ~/Library/Logs/The Bridge/
//   BridgePaths.applicationSupport(.commands) // …/The Bridge/commands/
//   BridgePaths.logs(.jobs)                   // …/Logs/The Bridge/jobs/

import Foundation

public enum BridgePaths {

    // MARK: - Canonical names

    /// Display name used to derive on-disk folders. Matches CFBundleName.
    public static let appName = "The Bridge"

    /// Legacy folder names previously in use across the codebase. Order is
    /// significant: PathMigration walks these in order and merges any that
    /// exist into the canonical destination.
    public static let legacyNames: [String] = [
        "Notion Bridge",   // pre-rebrand display-name-with-space variant (migrate FROM)
        "NotionBridge",    // pre-rebrand executable-name (no-space) variant (migrate FROM)
    ]

    // MARK: - Application Support

    /// `~/Library/Application Support/The Bridge/`
    public static var applicationSupport: URL {
        homeLibrary
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// Convenience for a named subdirectory inside Application Support.
    public static func applicationSupport(_ sub: SupportSubdir) -> URL {
        applicationSupport.appendingPathComponent(sub.rawValue, isDirectory: true)
    }

    public enum SupportSubdir: String {
        case commands       = "commands"
        case snippets       = "snippets"
        case skills         = "skills"          // user-installed SKILL.md files
        case skillsCache    = "skills-cache"    // Notion-synced routing-skill cache
        case skillsBodyCache = "skills-body-cache" // persistent per-skill BODY cache
        case standingOrders = "standing-orders"
        case jobs           = "jobs"
        case bgProcess      = "bg-process"
        case pasteboard     = "pasteboard"
        case screen         = "screen"
        case config         = "config"
        case sessions       = "sessions"        // MCP session durability snapshots
        case registry       = "registry"        // data-source registry config (registry.json)
        case registryCache  = "registry-cache"  // per-entity read-through row cache
        case voiceMemos     = "voice-memos"     // Voice Memos curator manifest + state
        case memoryHub      = "memory-hub"      // Memory Hub: activity.jsonl, registry-cache/, plan-snapshots/
    }

    // MARK: - Logs

    /// `~/Library/Logs/The Bridge/`
    public static var logs: URL {
        homeLibrary
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func logs(_ sub: LogsSubdir) -> URL {
        logs.appendingPathComponent(sub.rawValue, isDirectory: true)
    }

    public enum LogsSubdir: String {
        case jobs   = "jobs"
        case audit  = "audit"
        case server = "server"
    }

    // MARK: - Legacy lookup (for PathMigration)

    /// Returns every potential legacy Application Support directory that
    /// PathMigration should consider migrating. Used at app launch.
    public static var legacyApplicationSupportCandidates: [URL] {
        let support = homeLibrary.appendingPathComponent("Application Support", isDirectory: true)
        return legacyNames.map { support.appendingPathComponent($0, isDirectory: true) }
    }

    public static var legacyLogsCandidates: [URL] {
        let logs = homeLibrary.appendingPathComponent("Logs", isDirectory: true)
        return legacyNames.map { logs.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: - Helpers

    /// `~/Library` by default. Tests may override via
    /// `BridgePaths.overrideHomeForTesting(_:)`.
    public static var homeLibrary: URL {
        homeRoot.appendingPathComponent("Library", isDirectory: true)
    }

    /// Root used to derive every URL above. Defaults to the real home dir;
    /// PathMigration tests substitute a tmpdir via the override below.
    nonisolated(unsafe) private static var _overrideHome: URL?

    public static var homeRoot: URL {
        _overrideHome ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Override the home dir for unit tests. Pass nil to restore default.
    /// NOT thread-safe; tests must serialize their use.
    public static func overrideHomeForTesting(_ url: URL?) {
        _overrideHome = url
    }

    /// Ensure the canonical Application Support dir + a named subdir exist.
    /// Returns the subdir URL. Used by stores that lazy-create on first write.
    @discardableResult
    public static func ensureApplicationSupport(_ sub: SupportSubdir? = nil) throws -> URL {
        let url = sub.map { applicationSupport($0) } ?? applicationSupport
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public static func ensureLogs(_ sub: LogsSubdir? = nil) throws -> URL {
        let url = sub.map { logs($0) } ?? logs
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
