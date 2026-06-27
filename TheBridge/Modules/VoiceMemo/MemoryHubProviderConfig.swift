// MemoryHubProviderConfig.swift — non-secret cloud provider config (PKT-MEM-106 0c)
// TheBridge · Modules · VoiceMemo
//
// Non-secret OpenAI-compatible provider config at memory-hub/providers.json:
// provider id, base URL, model, enabled. The API KEY is NEVER stored here — it lives
// in the Keychain only (handled by the credential layer). Base URL defaults to the
// OpenAI endpoint; model has no default and must be operator-entered before cloud
// enhancement can run. Save validates LOCAL SYNTAX only (URL shape + required local
// fields); network/model validation happens only when manual cloud enhancement runs.
//
// PROCESSING provider capability profile contracts (D6/D17/D23/D36/D42):
// ProviderFamily, ProviderCapability, CredentialReference, ProviderCapabilityProfile,
// ProviderFallbackChain, ProviderProfileConfig, ProviderValidationError,
// ProviderSyntaxValidator, ProviderTestResult.

import Foundation

/// One non-secret provider slot. No `apiKey` field by construction — keys are Keychain-only.
public struct MemoryHubProvider: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var baseURL: String
    public var model: String
    public var enabled: Bool

    public init(id: String, baseURL: String, model: String, enabled: Bool) {
        self.id = id
        self.baseURL = baseURL
        self.model = model
        self.enabled = enabled
    }
}

public enum MemoryHubProviderConfigStore {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let openAICompatibleId = "openai-compatible"

    public static var fileURL: URL {
        BridgePaths.applicationSupport(.memoryHub).appendingPathComponent("providers.json")
    }

    /// A fresh provider slot: default base URL, blank (operator-required) model, disabled.
    public static func defaultProvider(id: String = openAICompatibleId) -> MemoryHubProvider {
        MemoryHubProvider(id: id, baseURL: defaultBaseURL, model: "", enabled: false)
    }

    public static func load() -> [MemoryHubProvider] {
        guard let data = try? Data(contentsOf: fileURL),
              let providers = try? JSONDecoder().decode([MemoryHubProvider].self, from: data) else { return [] }
        return providers
    }

    public static func save(_ providers: [MemoryHubProvider]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(providers).write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public static func upsert(_ provider: MemoryHubProvider) throws -> [MemoryHubProvider] {
        var providers = load()
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        try save(providers)
        return providers
    }

    @discardableResult
    public static func remove(id: String) throws -> [MemoryHubProvider] {
        var providers = load()
        providers.removeAll { $0.id == id }
        try save(providers)
        return providers
    }

    public enum SaveValidation: Equatable, Sendable {
        case ok
        case rejected(String)
        public var isOK: Bool { self == .ok }
    }

    /// Syntax-only validation on save: base URL must be a well-formed http(s) URL with a
    /// host. Model may be blank at save time (only required at cloud-enhance time). No
    /// network call is made here.
    public static func validateSyntax(_ provider: MemoryHubProvider) -> SaveValidation {
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("base URL is required") }
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return .rejected("base URL must be a valid http(s) URL with a host")
        }
        return .ok
    }

    /// Whether manual cloud enhancement may run: enabled AND a model is set AND the base
    /// URL is syntactically valid. (Actual network/model validation occurs at enhance time.)
    public static func canRunCloud(_ provider: MemoryHubProvider) -> Bool {
        provider.enabled
            && !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validateSyntax(provider).isOK
    }

    // MARK: API key (Keychain only — never in providers.json)

    public static func keychainKey(for providerId: String) -> String { "memory-hub.provider.\(providerId).apiKey" }

    /// Whether an API key is present in the Keychain for this provider (status only — the
    /// value is never surfaced).
    public static func keyConfigured(providerId: String) -> Bool {
        (KeychainManager.shared.read(key: keychainKey(for: providerId))?.isEmpty == false)
    }

    @discardableResult
    public static func saveKey(providerId: String, apiKey: String) -> Bool {
        KeychainManager.shared.save(key: keychainKey(for: providerId), value: apiKey)
    }

    @discardableResult
    public static func deleteKey(providerId: String) -> Bool {
        KeychainManager.shared.delete(key: keychainKey(for: providerId))
    }
}

// MARK: - PROCESSING Provider Capability Profile Contracts (D6/D17/D23/D36/D42)

/// Which AI provider family a profile targets.
public enum ProviderFamily: Codable, Sendable, Equatable, Hashable {
    case anthropic
    case openai
    case cursor
    case google
    case elevenLabs
    case custom(id: String)
}

/// What capability a provider profile is configured to serve.
public enum ProviderCapability: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case transcription
    case summarization
    case titleGeneration
    case quizGeneration
    case routing
    case general
}

/// A reference to a Keychain-stored credential. The field holds the Keychain key name only —
/// never a raw secret value (D23).
public struct CredentialReference: Codable, Sendable, Equatable {
    /// Keychain key name (not the secret itself — the key under which the secret is stored).
    public let credentialKey: String
    /// Human-readable label for UI display.
    public let label: String?

    public init(credentialKey: String, label: String? = nil) {
        self.credentialKey = credentialKey
        self.label = label
    }
}

/// A single profile in a capability fallback chain (D42).
public struct ProviderCapabilityProfile: Codable, Sendable, Equatable {
    public let capability: ProviderCapability
    public let family: ProviderFamily
    /// Keychain credential reference — never a raw secret (D23).
    public let credentialRef: CredentialReference?
    public let modelId: String?
    public let endpointOverride: URL?
    public let isEnabled: Bool

    public init(
        capability: ProviderCapability,
        family: ProviderFamily,
        credentialRef: CredentialReference? = nil,
        modelId: String? = nil,
        endpointOverride: URL? = nil,
        isEnabled: Bool = true
    ) {
        self.capability = capability
        self.family = family
        self.credentialRef = credentialRef
        self.modelId = modelId
        self.endpointOverride = endpointOverride
        self.isEnabled = isEnabled
    }
}

/// Ordered fallback chain for a single capability: first enabled profile wins (D42).
public typealias ProviderFallbackChain = [ProviderCapabilityProfile]

public extension ProviderFallbackChain {
    /// Returns the first enabled profile in the chain, or nil if none are enabled.
    func activeProfile() -> ProviderCapabilityProfile? {
        first(where: { $0.isEnabled })
    }
}

/// Top-level config: one fallback chain per capability (D42).
public struct ProviderProfileConfig: Codable, Sendable {
    public let chains: [ProviderCapability: ProviderFallbackChain]

    public init(chains: [ProviderCapability: ProviderFallbackChain] = [:]) {
        self.chains = chains
    }

    /// Returns the fallback chain for a capability, or [] if not configured.
    public func chain(for capability: ProviderCapability) -> ProviderFallbackChain {
        chains[capability] ?? []
    }

    /// Returns the active (first enabled) profile for a capability, or nil.
    public func activeProfile(for capability: ProviderCapability) -> ProviderCapabilityProfile? {
        chain(for: capability).activeProfile()
    }
}

/// A validation error for a specific field of a provider profile (D36).
public struct ProviderValidationError: Sendable, Equatable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// Local-only syntax validator for a provider capability profile (D36: no network calls here).
public struct ProviderSyntaxValidator: Sendable {
    public init() {}

    /// Validates syntax of a profile. Returns [] if valid. No network calls are made (D36).
    public func validateSyntax(_ profile: ProviderCapabilityProfile) -> [ProviderValidationError] {
        var errors: [ProviderValidationError] = []

        // modelId present but empty string is an error
        if let modelId = profile.modelId, modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ProviderValidationError(field: "modelId", message: "modelId must not be an empty string when set"))
        }

        // endpointOverride: if non-nil URL was constructed it's valid by construction; however
        // we guard against a nil URL from a bad string that might slip through at init via a
        // property wrapper — the URL type itself guarantees structural validity for non-nil.
        // No additional check needed for URL type field; callers constructing from a string
        // should use URL(string:) which will produce nil for malformed strings.

        // credentialRef present but credentialKey is empty
        if let ref = profile.credentialRef, ref.credentialKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(ProviderValidationError(field: "credentialRef.credentialKey", message: "credentialKey must not be empty when credentialRef is set"))
        }

        return errors
    }
}

/// Result of an explicit "Test profile" action (D36/D42). The evidenceId links to the
/// ACTIVITY log entry emitted for this test run.
public struct ProviderTestResult: Codable, Sendable {
    public let capability: ProviderCapability
    public let success: Bool
    public let message: String
    public let evidenceId: UUID
    public let testedAt: Date

    public init(
        capability: ProviderCapability,
        success: Bool,
        message: String,
        evidenceId: UUID = UUID(),
        testedAt: Date = Date()
    ) {
        self.capability = capability
        self.success = success
        self.message = message
        self.evidenceId = evidenceId
        self.testedAt = testedAt
    }
}
