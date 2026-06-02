// KeychainManager.swift — Keychain CRUD Wrapper
// NotionBridge · Security
// V3-QUALITY B1: Secure token storage via macOS Keychain (SecItem API).
// Thread-safe — all operations are synchronous via Security framework.
// UEP-003 K2: In-process token cache to reduce Keychain prompts on unsigned rebuilds.

import Foundation
import Security

/// Provides CRUD operations for storing sensitive values in the macOS Keychain.
/// Uses kSecClassGenericPassword with service "com.notionbridge".
public final class KeychainManager: @unchecked Sendable {

    public static let shared = KeychainManager()

    /// Keychain service identifier.
    private static let service = "com.notionbridge"

    /// In-process cache to avoid repeated Keychain prompts on unsigned rebuilds.
    /// Lifetime: one app launch. Invalidated on save/update/delete.
    private let cacheLock = NSLock()
    private var cache: [String: String] = [:]
    /// Keys that were read from Keychain and returned nil — cache the miss too.
    private var negativeCacheKeys: Set<String> = []

    private init() {}

    /// When running outside an .app bundle (e.g. test binary), keychain ops
    /// return safe no-ops to avoid password prompt storms from mismatched code signatures.
    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Cache Helpers

    private func cachedValue(for key: String) -> String?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let value = cache[key] { return .some(value) }
        if negativeCacheKeys.contains(key) { return .some(nil) }
        return nil // cache miss
    }

    private func setCacheValue(_ value: String?, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let value = value {
            cache[key] = value
            negativeCacheKeys.remove(key)
        } else {
            cache.removeValue(forKey: key)
            negativeCacheKeys.insert(key)
        }
    }

    private func invalidateCache(for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeValue(forKey: key)
        negativeCacheKeys.remove(key)
    }

    private func invalidateAllCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache.removeAll()
        negativeCacheKeys.removeAll()
    }


    // MARK: - Legacy Fallback Read

    /// Read a value from the Keychain using the key itself as the service name.
    /// This supports pre-KeychainManager entries where the service was the key name
    /// rather than the app's bundle service (com.notionbridge).
    /// If found, migrates the entry to the current service and deletes the legacy entry.
    public func readLegacy(service legacyService: String) -> String? {
        guard isAppBundle else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Migrate: save under current service, delete legacy entry
        if save(key: legacyService, value: value) {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            print("[KeychainManager] Migrated legacy entry '\(legacyService)' to com.notionbridge service")
        }

        return value
    }

    // MARK: - CRUD Operations

    /// Save a value to the Keychain. Overwrites if key already exists.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard isAppBundle else { return true }
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first (SecItemAdd fails if duplicate)
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Notion Bridge"
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainManager] ⚠️ Save failed for '\(key)': OSStatus \(status)")
        } else {
            setCacheValue(value, for: key)
        }
        return status == errSecSuccess
    }

    /// Read a value from the Keychain. Returns nil if not found.
    /// UEP-003 K2: Checks in-process cache first to avoid repeated Keychain prompts.
    public func read(key: String) -> String? {
        guard isAppBundle else { return nil }

        // Check in-process cache first
        if let cached = cachedValue(for: key) {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            setCacheValue(nil, for: key)  // Cache the miss
            return nil
        }

        setCacheValue(value, for: key)
        return value
    }

    /// Delete a value from the Keychain. Returns true if deleted or not found.
    @discardableResult
    public func delete(key: String) -> Bool {
        guard isAppBundle else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            invalidateCache(for: key)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists in the Keychain.
    /// UEP-003 K2: Uses cache to avoid Keychain prompt for already-read keys.
    public func exists(key: String) -> Bool {
        guard isAppBundle else { return false }

        // Check cache first — if we have a positive cache hit, key exists
        if let cached = cachedValue(for: key) {
            return cached != nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Update an existing value in the Keychain. Falls back to save if not found.
    @discardableResult
    public func update(key: String, value: String) -> Bool {
        guard isAppBundle else { return true }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Notion Bridge"
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return save(key: key, value: value)
        }
        if status == errSecSuccess {
            setCacheValue(value, for: key)
        }
        return status == errSecSuccess
    }

    // MARK: - Convenience

    /// Well-known key constants for token storage.
    public enum Key {
        public static let notionAPIToken = "notion_api_token"
        public static let stripeAPIKey = "stripe_api_key"
        /// Bearer secret for `POST /mcp` when remote tunnel URL is configured (Streamable HTTP).
        public static let mcpBearerToken = "mcp_bearer_token"
        /// WS-F: WorkOS session token from the `bridge-auth://callback` code
        /// exchange. Persisted so a returning user skips the browser sign-in.
        public static let cloudToken = "bridge.kup.solutions.workos_token"
    }

    // MARK: - Cloud token convenience (WS-F)

    /// The stored WorkOS cloud session token, or `nil` if the user has not
    /// signed in (or is running outside an .app bundle, where Keychain ops
    /// are no-ops). Read by `EnableCloudAccessFlow.start()` to decide whether
    /// to skip the browser sign-in step.
    public var cloudToken: String? {
        read(key: Key.cloudToken)
    }

    /// Persist the WorkOS cloud session token (overwrites any prior value).
    @discardableResult
    public func saveCloudToken(_ value: String) -> Bool {
        save(key: Key.cloudToken, value: value)
    }

    /// Remove the stored WorkOS cloud session token.
    @discardableResult
    public func clearCloudToken() -> Bool {
        delete(key: Key.cloudToken)
    }

    /// List all keys stored under this service.
    public func allKeys() -> [String] {
        guard isAppBundle else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Delete all items stored under this service.
    @discardableResult
    public func deleteAll() -> Bool {
        guard isAppBundle else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            invalidateAllCache()
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
