// NotionClientRegistry.swift – V2-NOTION-CORE Multi-Workspace Token Registry
// TheBridge · Notion
//
// PKT-367: Multi-workspace connection manager.
// Manages N named NotionClient connections with optional workspace selection.
// Handles config.json schema migration: flat "notion_api_token" → "connections" array.
// Zero data loss backward-compat: old flat key preserved as read fallback.
//
// Uses actor isolation for thread-safety (no NSLock needed).
// PKT-FIX-DUAL-PRIMARY: addConnection upserts on duplicate name; preflightRemove
//   handles same-name edge case; setPrimary unsets all others atomically.

import Foundation

// MARK: - NotionClientRegistry

/// Result of a preflight remove check.
public enum RemoveResult: Sendable {
    case removed
    case lastConnectionWarning
    case primaryBlocked(message: String)
}

/// Thread-safe manager for multiple Notion workspace connections.
/// Each connection has its own `NotionClient` instance with independent rate limiting.
public actor NotionClientRegistry {

    /// Shared singleton for app-wide access.
    public static let shared = NotionClientRegistry()

    private var clients: [String: NotionClient] = [:]
    private var connectionConfigs: [NotionConnection] = []
    private var primaryName: String?
    private var initialized = false

    public init() {}

    // MARK: - Client Access

    /// Get a NotionClient for the specified workspace, or the primary connection.
    /// Lazy-initializes connections on first access.
    public func getClient(workspace: String? = nil) throws -> NotionClient {
        if !initialized {
            try loadConnections()
            initialized = true
        }

        if let name = workspace {
            guard let client = clients[name] else {
                throw NotionClientError.connectionNotFound(name)
            }
            return client
        }

        // Return primary connection
        if let primary = primaryName, let client = clients[primary] {
            return client
        }

        // Fallback: try env var / single config token
        if clients.isEmpty {
            let client = try NotionClient()
            clients["default"] = client
            primaryName = "default"
            connectionConfigs.append(NotionConnection(name: "default", token: "", primary: true))
            return client
        }

        throw NotionClientError.missingAPIKey
    }

    // MARK: - Connection Management

    /// List all configured connections with status info.
    public func listConnections() throws -> [NotionConnectionInfo] {
        if !initialized {
            try loadConnections()
            initialized = true
        }

        return connectionConfigs.map { config in
            let masked = config.token.isEmpty
                ? "env/fallback"
                : NotionJSON.maskToken(config.token)
            let status = clients[config.name] != nil ? "connected" : "error"
            return NotionConnectionInfo(
                name: config.name,
                isPrimary: config.primary,
                status: status,
                maskedToken: masked
            )
        }
    }

    /// Add or update a named connection. If a connection with the same name already
    /// exists, its token is replaced in-place (upsert) instead of creating a duplicate.
    /// When `primary` is true, all other connections are atomically set to non-primary.
    /// Persists to config.json.
    /// PKT-FIX-DUAL-PRIMARY: Upsert prevents duplicate entries with the same name.
    public func addConnection(name: String, token: String, primary: Bool = false) throws {
        let client = try NotionClient(apiKey: token)
        clients[name] = client

        if let existingIdx = connectionConfigs.firstIndex(where: { $0.name == name }) {
            // Upsert: replace token on the existing entry
            connectionConfigs[existingIdx].token = token
            if primary {
                // Atomically unset all others before setting this one
                for i in connectionConfigs.indices {
                    connectionConfigs[i].primary = (i == existingIdx)
                }
                primaryName = name
            }
            print("[NotionClientRegistry] Updated existing connection '\(name)'\(primary ? " (set primary)" : "")")
        } else {
            // New entry
            if primary {
                // Atomically unset all others
                for i in connectionConfigs.indices {
                    connectionConfigs[i].primary = false
                }
            }
            connectionConfigs.append(NotionConnection(name: name, token: token, primary: primary))
            if primary || primaryName == nil {
                primaryName = name
            }
            print("[NotionClientRegistry] Added new connection '\(name)'\(primary ? " (primary)" : "")")
        }

        try persistConfig()
    }

    /// Preflight check before removing a connection. Returns the guard result.
    /// PKT-FIX-DUAL-PRIMARY: Checks for other connections with *different* names
    /// so same-name duplicates don't create an unresolvable block.
    public func preflightRemove(name: String) -> RemoveResult {
        if connectionConfigs.count == 1 { return .lastConnectionWarning }
        // Check if this is the primary and whether a different-named connection exists
        if primaryName == name && connectionConfigs.count > 1 {
            let hasOtherName = connectionConfigs.contains { $0.name != name }
            if hasOtherName {
                return .primaryBlocked(message: "Set a new primary before deleting this one.")
            }
            // All entries share the same name (duplicate bug state) — allow removal
            // of excess entries to self-heal. Keep at least one.
            let sameNameCount = connectionConfigs.filter { $0.name == name }.count
            if sameNameCount > 1 {
                return .removed
            }
            return .lastConnectionWarning
        }
        return .removed
    }

    /// Remove a named connection. Persists to config.json.
    /// Use preflightRemove() first to check for guard conditions.
    public func removeConnection(name: String) throws {
        clients.removeValue(forKey: name)
        connectionConfigs.removeAll { $0.name == name }
        if primaryName == name {
            primaryName = connectionConfigs.first?.name
        }
        try persistConfig()
        // Post notification so UI refreshes
        NotificationCenter.default.post(name: .notionTokenDidChange, object: nil)
    }

    /// Set a connection as primary. Persists to config.json.
    public func setPrimary(name: String) throws {
        guard clients[name] != nil else {
            throw NotionClientError.connectionNotFound(name)
        }
        for i in connectionConfigs.indices {
            connectionConfigs[i].primary = (connectionConfigs[i].name == name)
        }
        primaryName = name
        try persistConfig()
        print("[NotionClientRegistry] Primary set to '\(name)'")
    }

    /// Rename a connection in-place. Handles primary rename case. Persists to config.json.
    public func renameConnection(from oldName: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NotionClientError.connectionNotFound(oldName)
        }
        guard clients[oldName] != nil else {
            throw NotionClientError.connectionNotFound(oldName)
        }
        guard clients[trimmed] == nil else {
            throw NotionClientError.connectionNotFound(oldName) // name collision
        }
        // Move client to new key
        clients[trimmed] = clients.removeValue(forKey: oldName)
        // Update config entry
        if let idx = connectionConfigs.firstIndex(where: { $0.name == oldName }) {
            connectionConfigs[idx].name = trimmed
        }
        // Update primary if renamed connection was primary
        if primaryName == oldName { primaryName = trimmed }
        try persistConfig()
        print("[NotionClientRegistry] Renamed '\(oldName)' → '\(trimmed)'")
    }

    // MARK: - Config Loading & Migration

    /// Load connections from config.json, handling both old and new formats.
    /// PKT-FIX-DUAL-PRIMARY: Deduplicates entries with the same name on load,
    /// keeping the last (newest) entry and ensuring exactly one primary.
    private func loadConnections() throws {
        let path = NotionTokenResolver.configFilePath

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No config file — try environment variable fallback
            if let resolved = NotionTokenResolver.resolve() {
                let client = try NotionClient(apiKey: resolved.token)
                clients["default"] = client
                connectionConfigs = [NotionConnection(name: "default", token: resolved.token, primary: true)]
                primaryName = "default"
                print("[NotionClientRegistry] Initialized from token resolver: \(resolved.source)")
                return
            }
            print("[NotionClientRegistry] No config file found — will use env vars on first access")
            return
        }

        // New format: { "connections": [{ "name": "...", "token": "...", "primary": true }] }
        if let connections = json["connections"] as? [[String: Any]] {
            // PKT-FIX-DUAL-PRIMARY: Deduplicate on load — last entry per name wins.
            var seen: [String: Int] = [:]
            var deduped: [(name: String, token: String, isPrimary: Bool)] = []
            for conn in connections {
                guard let name = conn["name"] as? String,
                      let token = conn["token"] as? String,
                      !token.isEmpty else { continue }
                let isPrimary = conn["primary"] as? Bool ?? false
                if let existingIdx = seen[name] {
                    // Replace with newer entry (last-write-wins)
                    deduped[existingIdx] = (name, token, isPrimary)
                    print("[NotionClientRegistry] Dedup: replaced earlier '\(name)' with newer entry")
                } else {
                    seen[name] = deduped.count
                    deduped.append((name, token, isPrimary))
                }
            }

            // Ensure exactly one primary
            let primaryCount = deduped.filter { $0.isPrimary }.count
            if primaryCount != 1 && !deduped.isEmpty {
                // Reset: make the last primary (or first entry) the sole primary
                let lastPrimaryIdx = deduped.lastIndex(where: { $0.isPrimary }) ?? 0
                for i in deduped.indices {
                    deduped[i].isPrimary = (i == lastPrimaryIdx)
                }
                print("[NotionClientRegistry] Fixed primary count (was \(primaryCount), now 1)")
            }

            let needsPersist = deduped.count != connections.count || primaryCount != 1

            print("[NotionClientRegistry] Loading \(deduped.count) connection(s) from new format")
            for entry in deduped {
                do {
                    let client = try NotionClient(apiKey: entry.token)
                    clients[entry.name] = client
                    connectionConfigs.append(NotionConnection(name: entry.name, token: entry.token, primary: entry.isPrimary))
                    if entry.isPrimary || primaryName == nil {
                        primaryName = entry.name
                    }
                    print("[NotionClientRegistry] Loaded connection '\(entry.name)'\(entry.isPrimary ? " (primary)" : "")")
                } catch {
                    print("[NotionClientRegistry] Failed to create client for '\(entry.name)': \(error)")
                    connectionConfigs.append(NotionConnection(name: entry.name, token: entry.token, primary: entry.isPrimary))
                }
            }

            // Auto-heal: persist deduplicated config if duplicates or primary issues were found
            if needsPersist {
                try? persistConfig()
                print("[NotionClientRegistry] Auto-healed config.json (removed duplicates / fixed primary)")
            }
            return
        }

        // Old format: { "notion_api_token": "ntn_..." }
        let oldToken = (json["notion_api_token"] as? String) ?? (json["notion_api_key"] as? String)
        if let token = oldToken, !token.isEmpty {
            print("[NotionClientRegistry] Detected old config format — migrating to connections array")
            do {
                let client = try NotionClient(apiKey: token)
                clients["primary"] = client
                connectionConfigs.append(NotionConnection(name: "primary", token: token, primary: true))
                primaryName = "primary"
                migrateConfig(token: token, path: path, existingJSON: json)
            } catch {
                print("[NotionClientRegistry] Failed to create client from legacy token: \(error)")
            }
        }
    }

    /// Migrate old flat config to new connections array format.
    /// Preserves the old key for backward compatibility.
    private func migrateConfig(token: String, path: String, existingJSON: [String: Any]) {
        var config = existingJSON
        config["connections"] = [
            ["name": "primary", "token": token, "primary": true] as [String: Any]
        ]
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? jsonData.write(to: URL(fileURLWithPath: path))
            print("[NotionClientRegistry] Config migrated — connections array added, old key preserved")
        }
    }

    /// Persist current connections to config.json.
    private func persistConfig() throws {
        let path = NotionTokenResolver.configFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        config["connections"] = connectionConfigs.map { conn -> [String: Any] in
            ["name": conn.name, "token": conn.token, "primary": conn.primary]
        }

        if let primaryToken = connectionConfigs.first(where: { $0.primary })?.token {
            config["notion_api_token"] = primaryToken
        }

        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: URL(fileURLWithPath: path))
        print("[NotionClientRegistry] Config persisted — \(connectionConfigs.count) connection(s)")
    }

    /// Number of configured connections.
    public var connectionCount: Int {
        return clients.count
    }

    // MARK: - Factory reset

    /// Clears in-memory workspace clients and connection list, then reloads from disk and
    /// `NotionTokenResolver` on next access. Call after `config.json` and Keychain have been
    /// cleared so Settings and MCP see an empty state without restarting the app.
    public func resetAfterFactoryReset() {
        clients.removeAll()
        connectionConfigs.removeAll()
        primaryName = nil
        initialized = false
        print("[NotionClientRegistry] resetAfterFactoryReset — in-memory state cleared; will reload on next access")
    }
}
