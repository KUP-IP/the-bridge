import Foundation
import Security

public enum ConnectionRegistryError: Error, LocalizedError {
    case invalidConnectionId(String)
    case connectionNotFound(String)
    case unsupportedAction(String)
    case invalidAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidConnectionId(let id):
            return "Invalid connection id: \(id)"
        case .connectionNotFound(let id):
            return "Connection not found: \(id)"
        case .unsupportedAction(let action):
            return action
        case .invalidAPIKey:
            return "API key cannot be empty"
        }
    }
}

public actor ConnectionRegistry {
    public static let shared = ConnectionRegistry()

    private let formatter = ISO8601DateFormatter()

    public init() {}

    /// PKT-441: One-time migration — if a Stripe API key exists in KeychainManager
    /// but not yet in CredentialManager, copy it over as a typed .apiKey entry.
    public func migrateStripeKeyIfNeeded() async {
        let migrationKey = "com.notionbridge.stripeKeyMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationKey)

        let secret = KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
            ?? KeychainManager.shared.readLegacy(service: KeychainManager.Key.stripeAPIKey)
            ?? ConfigManager.shared.stripeAPIKey
        guard let secret, !secret.isEmpty else { return }

        let last4 = String(secret.suffix(4))
        let metadata = CredentialMetadata(last4: last4)
        _ = try? await CredentialManager.shared.save(
            service: "api_key:stripe",
            account: "stripe",
            password: secret,
            type: .apiKey,
            metadata: metadata
        )
    }

    public func listConnections(
        provider: BridgeConnectionProvider? = nil,
        kind: BridgeConnectionKind? = nil,
        validateLive: Bool = true
    ) async throws -> [BridgeConnection] {
        var connections = try await buildConnections(validateLive: validateLive)
        if let provider {
            connections.removeAll { $0.provider != provider }
        }
        if let kind {
            connections.removeAll { $0.kind != kind }
        }
        return connections.sorted { lhs, rhs in
            self.sortConnections(lhs: lhs, rhs: rhs)
        }
    }

    /// The reserved symbolic alias segment that resolves to a provider's LIVE
    /// primary connection at call time (e.g. `notion:primary`). Rename-safe: it
    /// always tracks whichever connection is currently primary rather than a
    /// fixed name. An exact-id match always wins first, so a connection literally
    /// named "primary" is never shadowed.
    public static let primaryAliasSegment = "primary"

    /// Whether the name segment of `id` is the reserved `primary` alias
    /// (case-insensitive), e.g. `notion:primary`. Pure and testable.
    public static func isPrimaryAlias(id: String) -> Bool {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return parts[1].lowercased() == primaryAliasSegment
    }

    /// Resolve `id` against a candidate set following alias rules:
    /// an exact-id match always wins first (so a connection literally named
    /// "primary" is never shadowed); otherwise, if `id`'s name segment is the
    /// `primary` alias, return the candidate flagged primary. Pure and testable
    /// (no live state), independent of provider.
    public static func resolve<C>(
        id: String,
        in candidates: [C],
        idOf: (C) -> String,
        isPrimary: (C) -> Bool
    ) -> C? {
        if let exact = candidates.first(where: { idOf($0) == id }) {
            return exact
        }
        if isPrimaryAlias(id: id) {
            return candidates.first(where: isPrimary)
        }
        return nil
    }

    public func getConnection(id: String, validateLive: Bool = true) async throws -> BridgeConnection {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let notionConnections = try await buildNotionConnections(validateLive: validateLive)
            // Exact-id-wins, then notion:primary → the live primary connection.
            if let match = Self.resolve(
                id: id,
                in: notionConnections,
                idOf: { $0.id },
                isPrimary: { $0.isPrimary }
            ) {
                return match
            }
        case .stripe:
            let stripeConnection = try await buildStripeConnection(validateLive: validateLive)
            if stripeConnection.id == id {
                return stripeConnection
            }
        case .tunnel:
            let tunnelConnection = buildTunnelConnection()
            if tunnelConnection.id == id {
                return tunnelConnection
            }
        case .generic:
            break
        }
        throw ConnectionRegistryError.connectionNotFound(id)
    }

    public func validateConnection(id: String) async throws -> BridgeConnection {
        try await getConnection(id: id, validateLive: true)
    }

    public func capabilities(forConnectionId id: String) async throws -> [String] {
        try await getConnection(id: id, validateLive: false).capabilities
    }

    public func configureNotionConnection(
        name: String,
        token: String,
        primary: Bool = false
    ) async throws -> BridgeConnection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ConnectionRegistryError.unsupportedAction("Connection name cannot be empty")
        }

        try await NotionClientRegistry.shared.addConnection(
            name: trimmedName,
            token: token,
            primary: primary
        )
        await ConnectionHealthChecker.shared.invalidateAll()
        return try await getConnection(id: "notion:\(trimmedName)", validateLive: true)
    }

    public func configureStripeAPIKey(_ apiKey: String) async throws -> BridgeConnection {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionRegistryError.invalidAPIKey
        }

        // PKT-441: Write to both KeychainManager (for backward compat) and CredentialManager (unified vault)
        let updated = KeychainManager.shared.update(key: KeychainManager.Key.stripeAPIKey, value: trimmed)
        guard updated else {
            throw ConnectionRegistryError.unsupportedAction("Failed to store Stripe API key in Keychain")
        }

        // Also store as a typed API key credential for the unified vault UI
        let last4 = String(trimmed.suffix(4))
        let metadata = CredentialMetadata(last4: last4)
        _ = try? await CredentialManager.shared.save(
            service: "api_key:stripe",
            account: "stripe",
            password: trimmed,
            type: .apiKey,
            metadata: metadata
        )

        ConfigManager.shared.stripeAPIKey = nil
        return try await buildStripeConnection(validateLive: true)
    }

    /// UEP-004 W2: Store a generic API key in Keychain and return a BridgeConnection.
    public func configureGenericConnection(name: String, apiKey: String) async throws -> BridgeConnection {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ConnectionRegistryError.unsupportedAction("Connection name cannot be empty")
        }
        guard !trimmedKey.isEmpty else {
            throw ConnectionRegistryError.invalidAPIKey
        }

        let keychainKey = "generic:\(trimmedName)"
        let saved = KeychainManager.shared.save(key: keychainKey, value: trimmedKey)
        guard saved else {
            throw ConnectionRegistryError.unsupportedAction("Failed to store API key in Keychain")
        }

        return BridgeConnection(
            id: "\(BridgeConnectionProvider.generic.rawValue):\(trimmedName)",
            provider: .generic,
            kind: .api,
            name: trimmedName,
            status: .connected,
            authType: "api_key",
            maskedCredential: BridgeConnection.maskSecret(trimmedKey),
            capabilities: [],
            lastValidatedAt: formatter.string(from: Date()),
            summary: "Generic API key stored securely"
        )
    }

    public func removeConnection(id: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let name = try parseName(from: id)
            try await NotionClientRegistry.shared.removeConnection(name: name)
            await ConnectionHealthChecker.shared.invalidate(connectionName: name)
        case .stripe:
            _ = KeychainManager.shared.delete(key: KeychainManager.Key.stripeAPIKey)
            // BUG-1 fix: Also delete legacy keychain entry (pre-KeychainManager migration)
            // and clear ConfigManager fallback to prevent stale-key false-positive in health check.
            let legacyDeleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainManager.Key.stripeAPIKey
            ]
            SecItemDelete(legacyDeleteQuery as CFDictionary)
            ConfigManager.shared.stripeAPIKey = nil
        case .tunnel:
            throw ConnectionRegistryError.unsupportedAction("Remote access is managed through the Remote Access settings section")
        case .generic:
            let name = try parseName(from: id)
            let keychainKey = "generic:\(name)"
            _ = KeychainManager.shared.delete(key: keychainKey)
        }
    }

    public func renameConnection(id: String, to newName: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let oldName = try parseName(from: id)
            try await NotionClientRegistry.shared.renameConnection(from: oldName, to: newName)
            await ConnectionHealthChecker.shared.invalidateAll()
        case .stripe, .tunnel, .generic:
            throw ConnectionRegistryError.unsupportedAction("Renaming is not supported for this connection type")
        }
    }

    public func setPrimary(id: String) async throws {
        let provider = try parseProvider(from: id)
        switch provider {
        case .notion:
            let name = try parseName(from: id)
            try await NotionClientRegistry.shared.setPrimary(name: name)
            await ConnectionHealthChecker.shared.invalidateAll()
        case .stripe, .tunnel, .generic:
            throw ConnectionRegistryError.unsupportedAction("Only workspace connections can be set as primary")
        }
    }

    private func buildConnections(validateLive: Bool) async throws -> [BridgeConnection] {
        var connections = try await buildNotionConnections(validateLive: validateLive)
        connections.append(try await buildStripeConnection(validateLive: validateLive))
        connections.append(buildTunnelConnection())
        return connections
    }

    private func buildNotionConnections(validateLive: Bool) async throws -> [BridgeConnection] {
        let notionConnections = try await NotionClientRegistry.shared.listConnections()
        var connections: [BridgeConnection] = []
        connections.reserveCapacity(notionConnections.count)

        for info in notionConnections {
            let health: ConnectionHealth
            let validatedAt: String?
            if validateLive {
                health = await ConnectionHealthChecker.shared.checkNotionHealth(connectionName: info.name)
                validatedAt = formatter.string(from: Date())
            } else {
                // PKT-440: Show last-known-good status instead of .checking
                health = await ConnectionHealthChecker.shared.lastKnownHealth(connectionName: info.name) ?? .checking
                validatedAt = nil
            }
            connections.append(
                BridgeConnection(
                    id: "\(BridgeConnectionProvider.notion.rawValue):\(info.name)",
                    provider: .notion,
                    kind: .workspace,
                    name: info.name,
                    isPrimary: info.isPrimary,
                    status: mapHealth(health),
                    authType: "token",
                    maskedCredential: info.maskedToken,
                    capabilities: [
                        "search",
                        "page_read",
                        "page_update",
                        "query",
                        "comments",
                        "file_upload"
                    ],
                    lastValidatedAt: validatedAt,
                    summary: "Notion workspace connection",
                    metadata: ["workspace": info.name]
                )
            )
        }

        return connections
    }

    private func buildStripeConnection(validateLive: Bool) async throws -> BridgeConnection {
        // UEP-005: Read from KeychainManager (com.notionbridge service) first,
        // then fall back to legacy service-name entry (pre-KeychainManager migration),
        // then ConfigManager (config.json bridgeConnections.stripe.apiKey).
        let secret = KeychainManager.shared.read(key: KeychainManager.Key.stripeAPIKey)
            ?? KeychainManager.shared.readLegacy(service: KeychainManager.Key.stripeAPIKey)
            ?? ConfigManager.shared.stripeAPIKey
        let maskedCredential = secret.map { BridgeConnection.maskSecret($0) }

        guard let secret, !secret.isEmpty else {
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: .notConfigured,
                authType: "api_key",
                maskedCredential: nil,
                capabilities: [],
                summary: nil
            )
        }

        guard validateLive else {
            // PKT-440: Show last-known status instead of .checking
            let lastKnown = await ConnectionHealthChecker.shared.lastKnownHealthForKey("stripe:default")
            let optimisticStatus: BridgeConnectionStatus = {
                switch lastKnown {
                case .healthy: return .connected
                case .warning: return .warning
                case .error: return .disconnected
                case .unconfigured: return .notConfigured
                case .checking, .none: return .checking
                }
            }()
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: optimisticStatus,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: [],
                summary: nil
            )
        }

        do {
            let account = try await StripeClient.shared.retrieveAccountInfo()
            let status: BridgeConnectionStatus = account.chargesEnabled ? .connected : .warning
            // PKT-440: Store last-known result for optimistic display
            let stripeHealth: ConnectionHealth = account.chargesEnabled ? .healthy : .warning
            await ConnectionHealthChecker.shared.setLastKnown(stripeHealth, forKey: "stripe:default")
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: account.displayName ?? "Stripe",
                status: status,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: [],
                lastValidatedAt: nil,
                summary: nil,
                metadata: [
                    "account_id": account.id,
                    "country": account.country ?? "",
                    "charges_enabled": account.chargesEnabled ? "true" : "false"
                ]
            )
        } catch {
            // PKT-440: Store last-known error for optimistic display
            await ConnectionHealthChecker.shared.setLastKnown(.error, forKey: "stripe:default")
            return BridgeConnection(
                id: "\(BridgeConnectionProvider.stripe.rawValue):default",
                provider: .stripe,
                kind: .api,
                name: "Stripe",
                status: .disconnected,
                authType: "api_key",
                maskedCredential: maskedCredential,
                capabilities: [],
                lastValidatedAt: formatter.string(from: Date()),
                summary: nil,
                metadata: ["last_error": error.localizedDescription]
            )
        }
    }

    private func buildTunnelConnection() -> BridgeConnection {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "tunnelProvider") ?? "Cloudflare"
        let tunnelURL = defaults.string(forKey: "tunnelURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bearerToken = MCPHTTPValidation.resolveMCPBearerToken()

        // Three-state status mirroring MCPHTTPValidation.streamableHTTPBearerPhase():
        // - .notConfigured: no tunnel URL
        // - .warning: tunnel URL set but no bearer token (server will 401 all requests)
        // - .connected: tunnel URL + bearer token both configured
        let status: BridgeConnectionStatus
        if tunnelURL.isEmpty {
            status = .notConfigured
        } else if bearerToken.isEmpty {
            status = .warning
        } else {
            status = .connected
        }

        return BridgeConnection(
            id: "\(BridgeConnectionProvider.tunnel.rawValue):remote-access",
            provider: .tunnel,
            kind: .remoteAccess,
            name: provider,
            status: status,
            authType: "url",
            maskedCredential: tunnelURL.isEmpty ? nil : tunnelURL,
            capabilities: ["remote_access"],
            summary: tunnelURL.isEmpty ? "Configure a public or private tunnel URL for remote agent access" : tunnelURL,
            metadata: [
                "provider": provider,
                "url": tunnelURL
            ]
        )
    }

    private func parseProvider(from id: String) throws -> BridgeConnectionProvider {
        guard let raw = id.split(separator: ":", maxSplits: 1).first,
              let provider = BridgeConnectionProvider(rawValue: String(raw).lowercased()) else {
            throw ConnectionRegistryError.invalidConnectionId(id)
        }
        return provider
    }

    private func parseName(from id: String) throws -> String {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            throw ConnectionRegistryError.invalidConnectionId(id)
        }
        return parts[1]
    }

    private func mapHealth(_ health: ConnectionHealth) -> BridgeConnectionStatus {
        switch health {
        case .healthy:
            return .connected
        case .warning:
            return .warning
        case .error:
            return .disconnected
        case .unconfigured:
            return .notConfigured
        case .checking:
            return .checking
        }
    }

    private func sortConnections(lhs: BridgeConnection, rhs: BridgeConnection) -> Bool {
        let kindOrder: [BridgeConnectionKind: Int] = [.workspace: 0, .api: 1, .remoteAccess: 2]
        let leftKind = kindOrder[lhs.kind] ?? 9
        let rightKind = kindOrder[rhs.kind] ?? 9
        if leftKind != rightKind {
            return leftKind < rightKind
        }
        if lhs.isPrimary != rhs.isPrimary {
            return lhs.isPrimary && !rhs.isPrimary
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
