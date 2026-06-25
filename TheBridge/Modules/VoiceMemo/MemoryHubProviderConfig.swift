// MemoryHubProviderConfig.swift — non-secret cloud provider config (PKT-MEM-106 0c)
// TheBridge · Modules · VoiceMemo
//
// Non-secret OpenAI-compatible provider config at memory-hub/providers.json:
// provider id, base URL, model, enabled. The API KEY is NEVER stored here — it lives
// in the Keychain only (handled by the credential layer). Base URL defaults to the
// OpenAI endpoint; model has no default and must be operator-entered before cloud
// enhancement can run. Save validates LOCAL SYNTAX only (URL shape + required local
// fields); network/model validation happens only when manual cloud enhancement runs.

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
