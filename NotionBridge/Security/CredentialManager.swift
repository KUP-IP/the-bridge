// CredentialManager.swift — Polymorphic Credential Vault
// NotionBridge · Security
// PKT-372: kSecClassGenericPassword CRUD with type discriminator,
// LAContext biometric gate, and Stripe card tokenization.
//
// Two-class Keychain strategy:
// - KeychainManager: API tokens, service "com.notionbridge". Untouched.
// - CredentialManager: User credentials, user-defined service names.
//   No collision — different kSecAttrService values.

import Foundation
import Security
import LocalAuthentication

// MARK: - CredentialType

/// Discriminator for polymorphic credential storage.
/// Persisted as `kSecAttrLabel` on each Keychain item.
public enum CredentialType: String, Sendable, Codable, CaseIterable {
    case apiKey = "api_key"   // PKT-441: API keys (Stripe, generic)
    case password = "password"
    case card = "card"
    case unknown = "unknown"
}

// MARK: - CredentialMetadata

/// Type-erased metadata stored as JSON in `kSecAttrComment`.
/// For `.password`: empty `{}`. For `.card`: brand, last4, expiry, stripe_pm.
public struct CredentialMetadata: Codable, Sendable, Equatable {
    public var brand: String?
    public var last4: String?
    public var expMonth: Int?
    public var expYear: Int?
    public var stripePm: String?
    /// Cardholder name, captured at card-save time. PKT-573.
    public var cardholderName: String?
    /// Billing ZIP / postal code, captured at card-save time. PKT-573.
    public var zipCode: String?
    /// Set when saved by `CredentialManager` (JSON key `nb`). Used with keychain access group to hide third-party items.
    public var notionBridgeManaged: Bool?

    public init(
        brand: String? = nil,
        last4: String? = nil,
        expMonth: Int? = nil,
        expYear: Int? = nil,
        stripePm: String? = nil,
        cardholderName: String? = nil,
        zipCode: String? = nil,
        notionBridgeManaged: Bool? = nil
    ) {
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
        self.stripePm = stripePm
        self.cardholderName = cardholderName
        self.zipCode = zipCode
        self.notionBridgeManaged = notionBridgeManaged
    }

    enum CodingKeys: String, CodingKey {
        case brand, last4
        case expMonth = "exp_month"
        case expYear = "exp_year"
        case stripePm = "stripe_pm"
        case cardholderName = "cardholder_name"
        case zipCode = "zip_code"
        case notionBridgeManaged = "nb"
    }

    /// Empty metadata for password-type credentials.
    public static let empty = CredentialMetadata()
}

// MARK: - CredentialEntry

/// A credential retrieved from the Keychain (read/list results).
public struct CredentialEntry: Sendable {
    public let service: String
    public let account: String
    public let type: CredentialType
    public let metadata: CredentialMetadata
    public let password: String?      // nil for list results (metadata-only)
    public let createdAt: Date?
    public let modifiedAt: Date?
}

// MARK: - CredentialError

public enum CredentialError: Error, LocalizedError {
    case biometricFailed(String)
    case biometricUnavailable
    case keychainError(OSStatus)
    case encodingError(String)
    case stripeTokenizationFailed(String)
    case stripeKeyMissing
    case notFound
    case invalidType(String)

    public var errorDescription: String? {
        switch self {
        case .biometricFailed(let msg): return "Biometric authentication failed: \(msg)"
        case .biometricUnavailable: return "Biometric authentication unavailable on this device"
        case .keychainError(let status):
            // errSecInvalidOwnerEdit (-25244): ACL / code signature mismatch with stored item.
            if status == -25244 {
                return "Could not remove this credential from the keychain. It may have been created by another install of the app. Remove it in Keychain Access, or try again after reinstalling."
            }
            // errSecMissingEntitlement (-34018): item owned by another app or not deletable from this process.
            if status == -34018 {
                return "This keychain item can’t be deleted from Notion Bridge. It was likely saved by another app. Remove it in Keychain Access (search the service name), or use that app’s settings."
            }
            return "Keychain error: OSStatus \(status)"
        case .encodingError(let msg): return "Encoding error: \(msg)"
        case .stripeTokenizationFailed(let msg): return "Stripe tokenization failed: \(msg)"
        case .stripeKeyMissing: return "STRIPE_API_KEY not found in KeychainManager"
        case .notFound: return "Credential not found"
        case .invalidType(let t): return "Invalid credential type: \(t)"
        }
    }
}

// MARK: - CredentialManager

/// Polymorphic credential vault using `kSecClassGenericPassword`.
/// Supports multiple credential types via `kSecAttrLabel` (type) and
/// `kSecAttrComment` (metadata JSON). Coexists with KeychainManager
/// (different service names, no collision).
public final class CredentialManager: Sendable {

    public static let shared = CredentialManager()

    private init() {}

    /// When running outside an .app bundle (e.g. test binary), keychain ops
    /// return safe no-ops to avoid password prompt storms from mismatched code signatures.
    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Test-only escape hatch to exercise Stripe tokenization in the standalone
    /// test executable (non-.app bundle) without touching Keychain writes.
    private var shouldTokenizeCardsInNonAppTests: Bool {
        UserDefaults.standard.bool(forKey: "com.notionbridge.tests.enableStripeTokenizationOutsideApp")
    }

    /// Default access group for items this app creates (`AppIdentifierPrefix` + bundle ID). Other apps use different groups.
    private static func defaultKeychainAccessGroupForThisApp() -> String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              let bundleID = Bundle.main.bundleIdentifier else {
            return nil
        }
        return "\(prefix)\(bundleID)"
    }

    /// `true` when the keychain item belongs to this app's default access group.
    /// v3.6 fix: missing-access-group no longer counts as "ours" — that defaulted-true
    /// path surfaced every system keychain item (Apple system services, Chrome, Spark,
    /// etc.) under "Stored credentials". Bridge-saved items still surface via the
    /// fallback paths in `shouldSurfaceCredentialFromKeychainItem` (metadata flag or
    /// `com.notionbridge` infrastructure service).
    public static func isKeychainItemManagedByThisApp(_ item: [String: Any]) -> Bool {
        guard let expected = defaultKeychainAccessGroupForThisApp() else {
            // v3.7 hotfix: if we cannot resolve OUR keychain access group
            // (e.g. AppIdentifierPrefix missing from Info.plist or the
            // keychain-access-groups entitlement isn't declared), default
            // DENY in every context. The previous behavior — `return true`
            // — was meant to keep unit tests permissive, but it ALSO
            // matched production installs of v3.6.x (which ship without
            // AppIdentifierPrefix in Info.plist and without
            // keychain-access-groups in NotionBridge.entitlements). The
            // user observed every system keychain item leaking into
            // Settings → Credentials because of this default-allow path.
            //
            // Tests that need to exercise the membership predicate use
            // `matchesAccessGroup(item:expected:)` directly (a pure
            // helper) — they don't hit this fallback.
            //
            // Bridge-saved credentials still surface via the fallback
            // paths in `shouldSurfaceCredentialFromKeychainItem`
            // (notionBridgeManaged metadata flag) and `list()` (explicit
            // service == "com.notionbridge" path).
            return false
        }
        return matchesAccessGroup(item: item, expected: expected)
    }

    /// Pure helper for `isKeychainItemManagedByThisApp` — testable without an
    /// app-bundle access group. Returns `true` iff the item's
    /// `kSecAttrAccessGroup` equals `expected`. Absent attribute → `false`
    /// (the v3.6 audit fix; previously this leaked system keychain items).
    public static func matchesAccessGroup(item: [String: Any], expected: String) -> Bool {
        guard let ag = item[kSecAttrAccessGroup as String] as? String else {
            return false
        }
        return ag == expected
    }

    /// Hide generic-password rows created by other apps (e.g. licensing tools) unless explicitly saved by us (`nb` in metadata).
    private static func shouldSurfaceCredentialFromKeychainItem(
        _ item: [String: Any],
        parsedEntry: CredentialEntry
    ) -> Bool {
        if isKeychainItemManagedByThisApp(item) { return true }
        return parsedEntry.metadata.notionBridgeManaged == true
    }

    // MARK: - Biometric Gate

    /// Evaluate LAContext biometric on the write path (save/delete).
    /// Bounded MainActor hop — explicitly scoped, not open-ended blocking.
    /// Falls back to device passcode if biometric is unavailable.
    public func requireBiometric(reason: String) async throws {
        // Skip biometric in non-app context (tests)
        guard isAppBundle else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch let laError as LAError {
            switch laError.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                // Fall back to device passcode
                let fallbackContext = LAContext()
                do {
                    try await fallbackContext.evaluatePolicy(
                        .deviceOwnerAuthentication,
                        localizedReason: reason
                    )
                } catch {
                    throw CredentialError.biometricFailed(error.localizedDescription)
                }
            case .userCancel, .appCancel:
                throw CredentialError.biometricFailed("Authentication cancelled")
            default:
                throw CredentialError.biometricFailed(laError.localizedDescription)
            }
        }
    }

    // MARK: - CRUD Operations

    /// Save or update a credential. Invokes biometric gate before writing.
    /// For card type, tokenizes via Stripe before storing — raw card number
    /// never touches Keychain.
    public func save(
        service: String,
        account: String,
        password: String,
        type: CredentialType = .password,
        metadata: CredentialMetadata = .empty,
        syncToiCloud: Bool = false
    ) async throws -> CredentialEntry {
        let runTokenizationOnly = !isAppBundle && type == .card && shouldTokenizeCardsInNonAppTests
        guard isAppBundle || runTokenizationOnly else {
            return CredentialEntry(
                service: service, account: account, type: type,
                metadata: metadata, password: nil,
                createdAt: Date(), modifiedAt: Date()
            )
        }

        // Biometric gate (write path)
        if isAppBundle {
            try await requireBiometric(reason: "Save credential for \(service)")
        }

        var finalPassword = password
        var finalMetadata = metadata

        finalMetadata.notionBridgeManaged = true

        // Stripe tokenization for card type
        if type == .card {
            let tokenResult = try await tokenizeCard(
                number: password,
                expMonth: metadata.expMonth ?? 1,
                expYear: metadata.expYear ?? 2030,
                brand: metadata.brand,
                cardholderName: metadata.cardholderName,
                zipCode: metadata.zipCode
            )
            finalPassword = tokenResult.pmToken
            finalMetadata.stripePm = tokenResult.pmToken
            finalMetadata.last4 = tokenResult.last4
            finalMetadata.brand = tokenResult.brand
            // cardholderName + zipCode are user-supplied and preserved on finalMetadata (no overwrite)
        }

        // In standalone tests, stop after tokenization to avoid keychain writes.
        guard isAppBundle else {
            return CredentialEntry(
                service: service, account: account, type: type,
                metadata: finalMetadata, password: nil,
                createdAt: Date(), modifiedAt: Date()
            )
        }

        // Encode metadata to JSON
        let metadataJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(finalMetadata)
            metadataJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw CredentialError.encodingError(error.localizedDescription)
        }

        // Delete existing item first (SecItemAdd fails on duplicate)
        deleteInternal(service: service, account: account)

        guard let passwordData = finalPassword.data(using: .utf8) else {
            throw CredentialError.encodingError("Failed to encode password as UTF-8")
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: type.rawValue,
            kSecAttrComment as String: metadataJSON,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[CredentialManager] ⚠️ Save failed for '\(service)/\(account)': OSStatus \(status)")
            throw CredentialError.keychainError(status)
        }

        return CredentialEntry(
            service: service, account: account, type: type,
            metadata: finalMetadata, password: nil,
            createdAt: Date(), modifiedAt: Date()
        )
    }

    /// Read a credential by service+account.
    /// No biometric — SecurityGate `.request` tier is sufficient.
    public func read(service: String, account: String) throws -> CredentialEntry {
        guard isAppBundle else { throw CredentialError.notFound }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let item = result as? [String: Any] else {
            if status == errSecItemNotFound { throw CredentialError.notFound }
            throw CredentialError.keychainError(status)
        }

        do {
            let entry = try parseKeychainItem(item, includePassword: true)
            guard Self.shouldSurfaceCredentialFromKeychainItem(item, parsedEntry: entry) else {
                throw CredentialError.notFound
            }
            return entry
        } catch CredentialError.invalidType {
            // Bridge: Allow reading KeychainManager infrastructure keys (com.notionbridge service)
            guard Self.isKeychainItemManagedByThisApp(item) else { throw CredentialError.notFound }
            let itemService = item[kSecAttrService as String] as? String ?? ""
            guard itemService == "com.notionbridge" else { throw CredentialError.invalidType(itemService) }
            let account = item[kSecAttrAccount as String] as? String ?? ""
            var password: String? = nil
            if let data = item[kSecValueData as String] as? Data {
                password = String(data: data, encoding: .utf8)
            }
            let createdAt = item[kSecAttrCreationDate as String] as? Date
            let modifiedAt = item[kSecAttrModificationDate as String] as? Date
            return CredentialEntry(
                service: itemService, account: account, type: .password,
                metadata: .empty, password: password,
                createdAt: createdAt, modifiedAt: modifiedAt
            )
        }
    }

    /// List credentials, optionally filtered by type.
    /// Uses `SecItemCopyMatching` on `kSecClassGenericPassword` with optional label filter.
    /// Items from other apps (different keychain access group) are omitted unless saved by us (`nb` in metadata).
    /// Returns metadata only — no passwords or tokens exposed.
    public func list(type: CredentialType? = nil) throws -> [CredentialEntry] {
        guard isAppBundle else { return [] }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        // Filter by type via kSecAttrLabel if specified
        if let type = type {
            query[kSecAttrLabel as String] = type.rawValue
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return [] }
            throw CredentialError.keychainError(status)
        }

        // Filter to items with a valid CredentialType label.
        // Bridge: Also includes KeychainManager infrastructure items (com.notionbridge service)
        // as password-type entries with metadata-only visibility (no secrets exposed).
        //
        // v3.7 hotfix: `parseKeychainItem` falls back to `credType = .unknown`
        // when `kSecAttrLabel` doesn't match a Bridge CredentialType. That
        // matches every system keychain item (which has service + account
        // but no Bridge-authored label). Combined with the predicate
        // hotfix above, .unknown-type items now require the
        // `notionBridgeManaged` metadata flag to surface — system items
        // never have that flag, so they cannot leak through this path.
        return items.compactMap { item in
            if let entry = try? parseKeychainItem(item, includePassword: false) {
                // Belt-and-suspenders: items parsed with .unknown type
                // (label missing or not a Bridge type) must clear the
                // explicit metadata-flag bar. The predicate also filters
                // them via access-group matching when entitlements are
                // declared; this is the second line of defense.
                if entry.type == .unknown && entry.metadata.notionBridgeManaged != true {
                    return nil
                }
                guard Self.shouldSurfaceCredentialFromKeychainItem(item, parsedEntry: entry) else {
                    return nil
                }
                return entry
            }
            // Fallback: surface com.notionbridge infrastructure keys as password-type entries
            guard Self.isKeychainItemManagedByThisApp(item),
                  let service = item[kSecAttrService as String] as? String,
                  service == "com.notionbridge",
                  let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            let createdAt = item[kSecAttrCreationDate as String] as? Date
            let modifiedAt = item[kSecAttrModificationDate as String] as? Date
            return CredentialEntry(
                service: service, account: account, type: .password,
                metadata: .empty, password: nil,
                createdAt: createdAt, modifiedAt: modifiedAt
            )
        }
    }

    /// Delete a credential. Invokes biometric gate before deleting.
    /// Uses attribute-matched delete (sync / access group) with fallbacks for Keychain mismatches.
    public func deleteCredential(
        service: String,
        account: String
    ) async throws -> Bool {
        guard isAppBundle else { return true }

        // Biometric gate (write path)
        try await requireBiometric(reason: "Delete credential for \(service)")

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let copyStatus = SecItemCopyMatching(lookup as CFDictionary, &result)
        if copyStatus == errSecItemNotFound {
            throw CredentialError.notFound
        }
        guard copyStatus == errSecSuccess,
              let item = result as? [String: Any] else {
            throw CredentialError.keychainError(copyStatus)
        }

        let variants = Self.keychainDeleteQueryVariants(service: service, account: account, item: item)
        var lastStatus: OSStatus = errSecInternalError
        for deleteQuery in variants {
            lastStatus = SecItemDelete(deleteQuery as CFDictionary)
            if lastStatus == errSecSuccess {
                return true
            }
            if lastStatus == errSecItemNotFound {
                throw CredentialError.notFound
            }
        }
        throw CredentialError.keychainError(lastStatus)
    }

    /// Builds delete query variants: mirrored attrs, minimal, minimal + sync flags.
    private static func keychainDeleteQueryVariants(
        service: String,
        account: String,
        item: [String: Any]
    ) -> [[String: Any]] {
        var list: [[String: Any]] = []
        list.append(keychainDeleteQuery(fromStoredAttributes: item))

        let minimal: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        list.append(minimal)

        var falseSync = minimal
        falseSync[kSecAttrSynchronizable as String] = kCFBooleanFalse
        list.append(falseSync)

        var trueSync = minimal
        trueSync[kSecAttrSynchronizable as String] = kCFBooleanTrue
        list.append(trueSync)

        return list
    }

    private static func keychainDeleteQuery(fromStoredAttributes item: [String: Any]) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword
        ]
        if let s = item[kSecAttrService as String] as? String {
            q[kSecAttrService as String] = s
        }
        if let a = item[kSecAttrAccount as String] as? String {
            q[kSecAttrAccount as String] = a
        }
        if item[kSecAttrSynchronizable as String] != nil {
            q[kSecAttrSynchronizable as String] = item[kSecAttrSynchronizable as String] as Any
        }
        if let ag = item[kSecAttrAccessGroup as String] as? String {
            q[kSecAttrAccessGroup as String] = ag
        }
        return q
    }

    // MARK: - Private: Internal Delete (no biometric, for save overwrites)

    @discardableResult
    private func deleteInternal(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private: Parse Keychain Item

    private func parseKeychainItem(
        _ item: [String: Any],
        includePassword: Bool
    ) throws -> CredentialEntry {
        guard let service = item[kSecAttrService as String] as? String,
              let account = item[kSecAttrAccount as String] as? String else {
            throw CredentialError.encodingError("Missing service or account in keychain item")
        }

        // Parse type from kSecAttrLabel
        let typeRaw = item[kSecAttrLabel as String] as? String ?? ""
        let credType = CredentialType(rawValue: typeRaw) ?? .unknown

        // Parse metadata from kSecAttrComment
        let commentJSON = item[kSecAttrComment as String] as? String ?? "{}"
        let metadata: CredentialMetadata
        if let data = commentJSON.data(using: .utf8) {
            metadata = (try? JSONDecoder().decode(CredentialMetadata.self, from: data)) ?? .empty
        } else {
            metadata = .empty
        }

        // Password (only for read, not list)
        var password: String? = nil
        if includePassword, let data = item[kSecValueData as String] as? Data {
            password = String(data: data, encoding: .utf8)
        }

        let createdAt = item[kSecAttrCreationDate as String] as? Date
        let modifiedAt = item[kSecAttrModificationDate as String] as? Date

        return CredentialEntry(
            service: service, account: account, type: credType,
            metadata: metadata, password: password,
            createdAt: createdAt, modifiedAt: modifiedAt
        )
    }

    // MARK: - Stripe Tokenization

    private struct StripeTokenResult {
        let pmToken: String
        let last4: String
        let brand: String
    }

    /// Tokenize card via Stripe POST /v1/payment_methods.
    /// Raw card number never persists — only the pm_ token is stored.
    private func tokenizeCard(
        number: String,
        expMonth: Int,
        expYear: Int,
        brand: String?,
        cardholderName: String? = nil,
        zipCode: String? = nil
    ) async throws -> StripeTokenResult {
        let keychainKey = KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
        let testFallbackKey: String? = {
            guard !isAppBundle else { return nil }
            return UserDefaults.standard.string(forKey: "com.notionbridge.tests.stripeApiKey")
        }()
        guard let apiKey = keychainKey ?? testFallbackKey, !apiKey.isEmpty else {
            throw StripeError.authenticationFailed
        }

        let url = URL(string: "https://api.stripe.com/v1/payment_methods")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let cleanNumber = number
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        var bodyParts = [
            "type=card",
            "card[number]=\(cleanNumber)",
            "card[exp_month]=\(expMonth)",
            "card[exp_year]=\(expYear)"
        ]
        if let name = cardholderName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            bodyParts.append("card[name]=\(encoded)")
        }
        if let zip = zipCode?.trimmingCharacters(in: .whitespaces), !zip.isEmpty {
            let encoded = zip.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? zip
            bodyParts.append("card[address_zip]=\(encoded)")
        }
        let body = bodyParts.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw StripeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StripeError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw StripeClient.parseStripeError(statusCode: httpResponse.statusCode, data: data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pmId = json["id"] as? String else {
            throw StripeError.invalidResponse
        }

        // Extract card details from Stripe response
        let cardInfo = json["card"] as? [String: Any]
        let last4 = cardInfo?["last4"] as? String ?? String(cleanNumber.suffix(4))
        let detectedBrand = cardInfo?["brand"] as? String ?? brand ?? "unknown"

        return StripeTokenResult(
            pmToken: pmId,
            last4: last4,
            brand: detectedBrand
        )
    }
}
