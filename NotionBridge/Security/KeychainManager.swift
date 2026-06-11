// KeychainManager.swift — Keychain CRUD Wrapper
// NotionBridge · Security
// V3-QUALITY B1: Secure token storage via macOS Keychain (SecItem API).
// Thread-safe — all operations are synchronous via Security framework.
// UEP-003 K2: In-process token cache to reduce Keychain prompts on unsigned rebuilds.
//
// WS-5c / the-bridge rename: the canonical Keychain service is
// `kup.solutions.the-bridge` (the product name). The prior services
// `kup.solutions.notion-bridge` and `com.notionbridge` are still READ
// (fallback) and MIRROR-WRITTEN so the rename is fully migration-safe and
// NON-DESTRUCTIVE: an item written under any old service is never lost, and the
// vault's infra-key surfacing in CredentialManager (which filters on the
// `com.notionbridge` service string and must not be touched) keeps working.

import Foundation
import Security

/// Provides CRUD operations for storing sensitive values in the macOS Keychain.
/// Uses kSecClassGenericPassword with the canonical service
/// "kup.solutions.the-bridge", mirror-writing the legacy "kup.solutions.notion-bridge"
/// and "com.notionbridge" services for migration safety.
public final class KeychainManager: @unchecked Sendable {

    public static let shared = KeychainManager()

    /// Canonical Keychain service identifier — the product name, "the-bridge".
    /// Rename chain: `com.notionbridge` → `kup.solutions.notion-bridge` → this.
    public static let service = "kup.solutions.the-bridge"

    /// Legacy Keychain service identifiers, newest-first. Pre-rename builds
    /// stored items under these; every one is READ as a fallback and
    /// MIRROR-WRITTEN so a credential is never lost across a rename — a harmless
    /// duplicate is far better than an orphaned credential. `com.notionbridge`
    /// additionally backs `CredentialManager`'s vault surfacing (it filters on
    /// that exact string and must NOT be modified), so it must stay populated.
    public static let legacyServices = ["kup.solutions.notion-bridge", "com.notionbridge"]

    /// The original infra service — retained as a named constant because
    /// `CredentialManager` and several call sites reference it directly. Always
    /// the last entry in `legacyServices`.
    public static let legacyService = "com.notionbridge"

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

    /// Test-only escape hatch to exercise real Keychain CRUD (including the
    /// WS-5c old→new migration round-trip) in the standalone test executable,
    /// which is NOT an .app bundle. Mirrors CredentialManager's pattern. OFF by
    /// default so the normal suite never touches the real Keychain.
    private var keychainOpsEnabledInNonAppTests: Bool {
        UserDefaults.standard.bool(forKey: Self.enableKeychainOpsOutsideAppKey)
    }

    /// UserDefaults flag the migration test sets to enable real Keychain CRUD
    /// in the non-.app test executable.
    public static let enableKeychainOpsOutsideAppKey =
        "com.notionbridge.tests.enableKeychainOpsOutsideApp"

    /// Whether real Keychain operations are permitted in this process.
    private var keychainEnabled: Bool {
        isAppBundle || keychainOpsEnabledInNonAppTests
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

    // MARK: - Low-level service-scoped primitives (WS-5c)

    /// Raw read of one account under an explicit service. No cache, no gate.
    private func rawRead(key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
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
        return value
    }

    /// Build a Keychain ACL granting THIS app silent access (no password
    /// prompt) to the item it creates. This explicit "always allow this app"
    /// trusted-application ACL is the fix for recurring "enter your password to
    /// allow access" prompts: without it, items get a default ACL that macOS
    /// may re-confirm on each read. File-keychain only — the data-protection /
    /// access-group path that would obviate this is refused by launchd for
    /// Developer-ID apps distributed outside the App Store (NotionBridge.entitlements,
    /// PKT-933). The SecTrustedApplication/SecAccess APIs are deprecated but are
    /// the only file-keychain ACL mechanism; `nil` path == the current app.
    /// Shared by `KeychainManager.rawWrite` AND `CredentialManager.save` so that
    /// EVERY credential-creation path produces prompt-free items (new users
    /// included). Static + public for reuse; builds a fresh SecAccess per call.
    public static func makeSelfTrustAccess() -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApp) == errSecSuccess,
              let app = trustedApp else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("The Bridge" as CFString, [app] as CFArray, &access) == errSecSuccess else {
            return nil
        }
        return access
    }

    /// Raw write (add-or-replace) of one account under an explicit service.
    /// Returns true on success. No cache, no gate.
    @discardableResult
    private func rawWrite(key: String, value: String, service: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete existing first (SecItemAdd fails on duplicate). This also drops
        // any stale ACL the prior item carried — the re-add below installs the
        // clean always-allow-self ACL.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrLabel as String: "The Bridge"
        ]
        if let access = Self.makeSelfTrustAccess() {
            // Explicit ACL → no recurring prompts. kSecAttrAccess (file-keychain
            // ACL) and kSecAttrAccessible are mutually exclusive; we never set
            // kSecAttrSynchronizable, so the login keychain still never syncs to
            // iCloud without the ThisDeviceOnly accessibility.
            addQuery[kSecAttrAccess as String] = access
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess, addQuery[kSecAttrAccess as String] != nil {
            // The explicit-ACL add failed (e.g. a SecAccess the runtime rejects
            // in this context). NEVER leave the item deleted: retry with the
            // default accessibility so the value is always persisted — a missing
            // prompt-free ACL is strictly better than a lost credential.
            addQuery.removeValue(forKey: kSecAttrAccess as String)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecSuccess {
                print("[KeychainManager] ℹ️ Saved '\(key)' (service=\(service)) WITHOUT explicit ACL (SecAccess rejected); value preserved.")
            }
        }
        if status != errSecSuccess {
            print("[KeychainManager] ⚠️ Save failed for '\(key)' (service=\(service)): OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    /// Raw delete of one account under an explicit service. Returns true if
    /// deleted or not found.
    @discardableResult
    private func rawDelete(key: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Legacy Fallback Read

    /// Read a value from the Keychain using the key itself as the service name.
    /// This supports pre-KeychainManager entries where the service was the key name
    /// rather than the app's bundle service.
    /// If found, migrates the entry to the current service and deletes the legacy entry.
    public func readLegacy(service legacyServiceName: String) -> String? {
        guard keychainEnabled else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyServiceName,
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

        // Migrate: save under current service, delete legacy entry.
        if save(key: legacyServiceName, value: value) {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyServiceName
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            print("[KeychainManager] Migrated legacy entry '\(legacyServiceName)' to \(Self.service) service")
        }

        return value
    }

    // MARK: - CRUD Operations

    /// Save a value to the Keychain. Overwrites if key already exists.
    ///
    /// WS-5c: writes the canonical service AND mirror-writes the legacy service
    /// so (a) the old-service copy always exists (zero loss / non-destructive)
    /// and (b) CredentialManager's vault surfacing — which filters on the legacy
    /// service and must not be modified — keeps working. Success is reported
    /// when the CANONICAL write succeeds; the mirror is best-effort.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard keychainEnabled else { return true }
        guard value.data(using: .utf8) != nil else { return false }

        let ok = rawWrite(key: key, value: value, service: Self.service)
        // Best-effort mirror to every legacy service (non-destructive duplicate)
        // so a credential written before a rename is never orphaned.
        for legacy in Self.legacyServices {
            _ = rawWrite(key: key, value: value, service: legacy)
        }

        if ok {
            setCacheValue(value, for: key)
        }
        return ok
    }

    /// Read a value from the Keychain. Returns nil if not found.
    /// UEP-003 K2: Checks in-process cache first to avoid repeated Keychain prompts.
    ///
    /// WS-5c: reads the canonical service first; on a miss, falls back to the
    /// legacy service and transparently migrates (copy old→new) WITHOUT deleting
    /// the old copy — so a credential written before the rename is never lost.
    public func read(key: String) -> String? {
        guard keychainEnabled else { return nil }

        // Check in-process cache first
        if let cached = cachedValue(for: key) {
            return cached
        }

        // Canonical service first.
        if let value = rawRead(key: key, service: Self.service) {
            setCacheValue(value, for: key)
            return value
        }

        // Migration fallback: walk the legacy services newest-first. On a hit,
        // copy forward to the canonical service (non-destructive — leave every
        // legacy copy in place).
        for legacy in Self.legacyServices {
            if let legacyValue = rawRead(key: key, service: legacy) {
                _ = rawWrite(key: key, value: legacyValue, service: Self.service)
                setCacheValue(legacyValue, for: key)
                print("[KeychainManager] Migrated '\(key)' from legacy service '\(legacy)' to \(Self.service) (legacy copy retained)")
                return legacyValue
            }
        }

        setCacheValue(nil, for: key)  // Cache the miss
        return nil
    }

    // MARK: - One-time ACL re-authorization (prompt heal)

    /// UserDefaults flag marking that the one-time ACL heal has run.
    private static let aclHealedKey = "kup.solutions.the-bridge.keychainACLHealedV1"

    /// One-time heal for the recurring access-prompt issue. Items created by
    /// older builds carry a default ACL that macOS re-confirms on each read;
    /// re-saving them installs the explicit always-allow-self ACL (see
    /// `makeSelfTrustAccess`). Reading each stale item surfaces ONE prompt
    /// (unavoidable — the value must be read to be re-written), after which all
    /// future reads are silent. Idempotent, UserDefaults-guarded → runs once.
    public func reauthorizeIfNeeded() {
        guard keychainEnabled else { return }
        guard !UserDefaults.standard.bool(forKey: Self.aclHealedKey) else { return }
        reauthorizeAllItems()
        UserDefaults.standard.set(true, forKey: Self.aclHealedKey)
    }

    /// Re-save every stored item under the clean always-allow-self ACL. Public +
    /// unguarded so a "Re-authorize credentials" affordance can invoke it on
    /// demand. Enumerates accounts (metadata only, no prompt), then reads +
    /// re-saves each (one prompt per stale item, silent thereafter).
    @discardableResult
    public func reauthorizeAllItems() -> Int {
        guard keychainEnabled else { return 0 }
        invalidateAllCache()
        let keys = allKeys()
        for key in keys {
            if let value = read(key: key) {
                _ = save(key: key, value: value)
            }
        }
        print("[KeychainManager] Re-authorized \(keys.count) keychain item(s) under the always-allow-self ACL")
        return keys.count
    }

    /// Delete a value from the Keychain. Returns true if deleted or not found.
    ///
    /// WS-5c: deletes from BOTH services so clearing a token fully clears it
    /// (no stale legacy copy left readable).
    @discardableResult
    public func delete(key: String) -> Bool {
        guard keychainEnabled else { return true }

        let newOK = rawDelete(key: key, service: Self.service)
        var legacyOK = true
        for legacy in Self.legacyServices {
            legacyOK = rawDelete(key: key, service: legacy) && legacyOK
        }
        if newOK && legacyOK {
            invalidateCache(for: key)
        }
        return newOK && legacyOK
    }

    /// Check if a key exists in the Keychain.
    /// UEP-003 K2: Uses cache to avoid Keychain prompt for already-read keys.
    public func exists(key: String) -> Bool {
        guard keychainEnabled else { return false }

        // Check cache first — if we have a positive cache hit, key exists
        if let cached = cachedValue(for: key) {
            return cached != nil
        }

        for service in [Self.service] + Self.legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: false
            ]
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
                return true
            }
        }
        return false
    }

    /// Update an existing value in the Keychain. Falls back to save if not found.
    ///
    /// WS-5c: routed through `save` so both services stay in sync.
    @discardableResult
    public func update(key: String, value: String) -> Bool {
        guard keychainEnabled else { return true }
        guard value.data(using: .utf8) != nil else { return false }
        return save(key: key, value: value)
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

    /// List all keys stored under either service (canonical ∪ legacy).
    public func allKeys() -> [String] {
        guard keychainEnabled else { return [] }
        var keys = Set<String>()
        for service in [Self.service] + Self.legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let items = result as? [[String: Any]] else {
                continue
            }
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String {
                    keys.insert(account)
                }
            }
        }
        return Array(keys)
    }

    /// Delete all items stored under either service.
    @discardableResult
    public func deleteAll() -> Bool {
        guard keychainEnabled else { return true }
        var allOK = true
        for service in [Self.service] + Self.legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            let status = SecItemDelete(query as CFDictionary)
            allOK = allOK && (status == errSecSuccess || status == errSecItemNotFound)
        }
        if allOK {
            invalidateAllCache()
        }
        return allOK
    }
}
