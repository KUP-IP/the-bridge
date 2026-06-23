// ConfigManager.swift — Centralized config read/write
// TheBridge · Configuration
// PKT-363 D1: Manages ~/.config/notion-bridge/config.json
// Thread-safe via concurrent DispatchQueue with barrier writes.
// Atomic file writes via Data.write(options: .atomic).

import Foundation

/// Centralized configuration manager for ~/.config/notion-bridge/config.json.
/// Shared by SecurityGate (runtime path reads) and SettingsWindow (UI edits).
public final class ConfigManager: @unchecked Sendable {

    public static let shared = ConfigManager()

    /// The 5 original sensitive paths shipped as defaults.
    public static let defaultSensitivePaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config",
        "~/Library/Keychains"
    ]

    /// Default screen output directory (PKT-375).
    public static let defaultScreenOutputDir = "~/Desktop"
    public static let defaultLearnedAllowPrefixes: [String] = []
    public static let defaultSSEPort = BridgeConstants.defaultSSEPort

    private let configURL: URL
    private let queue = DispatchQueue(label: "com.notionbridge.config", attributes: .concurrent)

    private init() {
        // BRIDGE_CONFIG_PATH override: an explicit config-file path wins over the
        // default location. Lets operators relocate config (e.g. sandboxed/CI
        // environments) and lets the test suite point at a temp file so tests
        // never read or mutate the user's real ~/.config/.../config.json.
        if let override = ProcessInfo.processInfo.environment["BRIDGE_CONFIG_PATH"],
           !override.isEmpty {
            configURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            configURL = home.appendingPathComponent(".config/notion-bridge/config.json")
        }
    }

    // MARK: - Raw Config I/O

    private func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[ConfigManager] ⚠️ Failed to read config.json — returning empty config")
            return [:]
        }
        return json
    }

    /// Atomic write via Data.write(options: .atomic) — writes to temp file, then renames.
    ///
    /// Security (v4 audit #8): config.json can hold secrets (Notion token, Stripe
    /// key, OAuth JWKS), so it must not be world-readable. After the atomic write
    /// we chmod it to 0o600 (owner read/write only). The chmod runs on the FINAL
    /// path post-rename, so the mode sticks regardless of the temp file's umask.
    private func writeConfig(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    // MARK: - Sensitive Paths (PKT-363 D1 + D2)

    /// Read sensitive paths from config.
    /// Falls back to hardcoded defaults if key is missing, wrong type, or JSON is malformed.
    /// Logs a warning on fallback.
    public var sensitivePaths: [String] {
        get {
            queue.sync {
                let config = readConfig()
                guard let paths = config["sensitivePaths"] as? [String] else {
                    print("[ConfigManager] ⚠️ sensitivePaths missing or malformed — falling back to defaults")
                    return Self.defaultSensitivePaths
                }
                return paths
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                config["sensitivePaths"] = newValue
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write sensitivePaths: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Seed sensitivePaths into config if key is absent.
    /// Called on first launch with new schema to populate defaults.
    public func seedDefaultsIfNeeded() {
        queue.sync(flags: .barrier) {
            var config = readConfig()
            var didUpdate = false
            if config["sensitivePaths"] == nil {
                config["sensitivePaths"] = Self.defaultSensitivePaths
                didUpdate = true
            }
            if config["learnedAllowPrefixes"] == nil {
                config["learnedAllowPrefixes"] = Self.defaultLearnedAllowPrefixes
                didUpdate = true
            }
            if config["bridgeConnections"] == nil {
                config["bridgeConnections"] = ["stripe": ["apiKey": ""]]
                didUpdate = true
            }
            guard didUpdate else { return }
            do {
                try writeConfig(config)
                print("[ConfigManager] Seeded missing config defaults")
            } catch {
                print("[ConfigManager] ⚠️ Failed to seed defaults: \(error.localizedDescription)")
            }
        }
    }

    /// Merge default paths back into the current list without removing custom paths.
    /// PKT-363 D4: "Restore Defaults" merges originals back without wiping additions.
    /// Returns the merged list.
    @discardableResult
    public func restoreDefaults() -> [String] {
        var current = sensitivePaths
        for defaultPath in Self.defaultSensitivePaths {
            if !current.contains(defaultPath) {
                current.append(defaultPath)
            }
        }
        sensitivePaths = current
        return current
    }

    // MARK: - Notion API Token (V3-QUALITY A4)

    /// Read/write the Notion API token from config.json.
    public var notionAPIToken: String? {
        get {
            queue.sync {
                let config = readConfig()
                // Check connections array first (new format)
                if let connections = config["connections"] as? [[String: Any]],
                   let primary = connections.first(where: { $0["primary"] as? Bool == true }),
                   let token = primary["token"] as? String, !token.isEmpty {
                    return token
                }
                // Fall back to flat key (legacy format)
                return config["notion_api_token"] as? String
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                if let value = newValue {
                    config["notion_api_token"] = value
                } else {
                    config.removeValue(forKey: "notion_api_token")
                }
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write notionAPIToken: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - SSE Port

    /// Read/write the SSE port from config.json.
    /// Resolution order on read: config.json -> NOTION_BRIDGE_PORT env -> 9700.
    public var ssePort: Int {
        get {
            queue.sync {
                let config = readConfig()
                if let port = config["ssePort"] as? Int, (1...65535).contains(port) {
                    return port
                }
                if let portString = config["ssePort"] as? String,
                   let port = Int(portString),
                   (1...65535).contains(port) {
                    return port
                }
                if let envValue = ProcessInfo.processInfo.environment["NOTION_BRIDGE_PORT"],
                   let envPort = Int(envValue),
                   (1...65535).contains(envPort) {
                    return envPort
                }
                return Self.defaultSSEPort
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                if (1...65535).contains(newValue) {
                    config["ssePort"] = newValue
                } else {
                    config.removeValue(forKey: "ssePort")
                }
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write ssePort: \(error.localizedDescription)")
                }
            }
        }
    }


    // MARK: - Session Timeout

    /// Read/write the SSE session timeout from config.json.
    /// `0` in config means no timeout (sessions never expire). Maps to `TimeInterval.infinity` at runtime.
    /// Any positive value is clamped to a minimum of 30 seconds.
    /// Falls back to 300 seconds (5 minutes) if not configured.
    public var sessionTimeout: TimeInterval {
        get {
            queue.sync {
                let config = readConfig()
                guard let raw = config["sessionTimeout"] else { return 300 }
                let value: Double
                if let d = raw as? Double { value = d }
                else if let i = raw as? Int { value = Double(i) }
                else { return 300 }
                return value == 0 ? .infinity : max(30, value)
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                // Store 0 to represent "no timeout"; otherwise store the raw value.
                if newValue.isInfinite || newValue == 0 {
                    config["sessionTimeout"] = 0
                } else {
                    config["sessionTimeout"] = newValue
                }
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write sessionTimeout: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Notion Connections (V3-QUALITY A4)

    /// Read/write the connections array from config.json.
    public var notionConnections: [[String: Any]] {
        get {
            queue.sync {
                let config = readConfig()
                return config["connections"] as? [[String: Any]] ?? []
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                config["connections"] = newValue
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write notionConnections: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Bridge Connections (V2-BRIDGE-CONNECTIONS)

    /// Read/write the Stripe API key from bridgeConnections in config.json.
    public var stripeAPIKey: String? {
        get {
            queue.sync {
                let config = readConfig()
                guard let bc = config["bridgeConnections"] as? [String: Any],
                      let stripe = bc["stripe"] as? [String: Any],
                      let key = stripe["apiKey"] as? String, !key.isEmpty else {
                    return nil
                }
                return key
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                var bc = config["bridgeConnections"] as? [String: Any] ?? [:]
                var stripe = bc["stripe"] as? [String: Any] ?? [:]
                if let value = newValue {
                    stripe["apiKey"] = value
                } else {
                    stripe.removeValue(forKey: "apiKey")
                }
                bc["stripe"] = stripe
                config["bridgeConnections"] = bc
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write stripeAPIKey: \(error.localizedDescription)")
                }
            }
        }
    }

        // MARK: - Generic Config Access (V3-QUALITY A4)

    /// The config.json file URL (exposed for callers that need the path).
    public var configFileURL: URL { configURL }

    /// Read the full parsed config dictionary.
    public var configJSON: [String: Any] {
        queue.sync { readConfig() }
    }

    /// Write a value for a specific key.
    public func setValue(_ value: Any?, forKey key: String) {
        queue.sync(flags: .barrier) {
            var config = readConfig()
            if let value = value {
                config[key] = value
            } else {
                config.removeValue(forKey: key)
            }
            do {
                try writeConfig(config)
            } catch {
                print("[ConfigManager] ⚠️ Failed to write key ''\(key)''': \(error.localizedDescription)")
            }
        }
    }

    /// Read a value for a specific key.
    public func value(forKey key: String) -> Any? {
        queue.sync {
            readConfig()[key]
        }
    }

    // MARK: - Learned Command Prefixes (PKT-376)

    public var learnedAllowPrefixes: [String] {
        get {
            queue.sync {
                let config = readConfig()
                return config["learnedAllowPrefixes"] as? [String] ?? Self.defaultLearnedAllowPrefixes
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                config["learnedAllowPrefixes"] = newValue
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write learnedAllowPrefixes: \(error.localizedDescription)")
                }
            }
        }
    }

    public func addLearnedAllowPrefix(_ prefix: String) {
        queue.sync(flags: .barrier) {
            let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }

            var config = readConfig()
            var prefixes = config["learnedAllowPrefixes"] as? [String] ?? []
            if !prefixes.contains(normalized) {
                prefixes.append(normalized)
                config["learnedAllowPrefixes"] = prefixes
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to append learnedAllowPrefix: \(error.localizedDescription)")
                }
            }
        }
    }

    public func removeLearnedAllowPrefix(_ prefix: String) {
        queue.sync(flags: .barrier) {
            var config = readConfig()
            var prefixes = config["learnedAllowPrefixes"] as? [String] ?? []
            prefixes.removeAll { $0 == prefix }
            config["learnedAllowPrefixes"] = prefixes
            do {
                try writeConfig(config)
            } catch {
                print("[ConfigManager] ⚠️ Failed to remove learnedAllowPrefix: \(error.localizedDescription)")
            }
        }
    }

    public func clearLearnedAllowPrefixes() {
        learnedAllowPrefixes = []
    }


    // MARK: - Screen Output Directory (PKT-375)

    /// Read/write the screen output directory from config.json.
    /// Falls back to ~/Desktop if key is missing.
    /// Path with ~ is expanded to absolute path at read time.
    public var screenOutputDir: String {
        get {
            queue.sync {
                let config = readConfig()
                let raw = config["screenOutputDir"] as? String ?? Self.defaultScreenOutputDir
                return NSString(string: raw).expandingTildeInPath
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                config["screenOutputDir"] = newValue
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write screenOutputDir: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Validate that the screen output directory exists and is writable.
    /// Returns the configured path if valid, otherwise falls back to /tmp.
    public func resolvedScreenOutputDir() -> (path: String, isFallback: Bool) {
        let dir = screenOutputDir
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir) {
            return (path: dir, isFallback: false)
        }
        print("[ConfigManager] ⚠️ screenOutputDir '\(dir)' is invalid or not writable — falling back to /tmp")
        return (path: "/tmp", isFallback: true)
    }

    // MARK: - Keychain Migration (V3-QUALITY B4)

    /// Migrate tokens from config.json to Keychain on first launch.
    /// Reads existing tokens from config, saves to Keychain if not already there.
    /// Safe to call multiple times — skips if Keychain already has the token.
    private static let keychainMigrationKey = "keychain_migration_v1_done"

    public func migrateTokensToKeychain() {
        // Skip if migration already completed (avoids unnecessary Keychain access on every launch)
        guard !UserDefaults.standard.bool(forKey: Self.keychainMigrationKey) else { return }

        var migrated = false

        // Migrate Notion API token
        if let token = notionAPIToken, !token.isEmpty,
           !KeychainManager.shared.exists(key: KeychainManager.Key.notionAPIToken) {
            KeychainManager.shared.save(key: KeychainManager.Key.notionAPIToken, value: token)
            print("[ConfigManager] Migrated notion_api_token to Keychain")
            migrated = true
        }

        // Migrate Stripe API key
        if let stripeKey = stripeAPIKey, !stripeKey.isEmpty,
           !KeychainManager.shared.exists(key: KeychainManager.Key.stripeAPIKey) {
            KeychainManager.shared.save(key: KeychainManager.Key.stripeAPIKey, value: stripeKey)
            stripeAPIKey = nil
            print("[ConfigManager] Migrated stripe_api_key to Keychain")
            migrated = true
        }

        // Mark migration complete - even if nothing needed migrating, skip future checks
        UserDefaults.standard.set(true, forKey: Self.keychainMigrationKey)
        if migrated {
            print("[ConfigManager] Keychain migration complete - flagged as done")
        }
    }
}
