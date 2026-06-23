// RegistryConfigStore.swift — Data-Source Registry (vertical slice v0)
// TheBridge · Modules · Registry
//
// Durable home for the exportable registry config (Decision 8). One typed
// `registry.json` under `BridgePaths.applicationSupport(.registry)`, written
// atomically (temp → replace) so a concurrent reader never sees a torn doc.
// Path is injectable so tests drive a temp file — mirrors
// SessionPersistenceStore / JobStore.
//
// Posture: config is TRUTH, not a hint. So the two failure modes are handled
// distinctly:
//   • file MISSING  → first run; `load()` returns the default seed.
//   • file CORRUPT  → `load()` THROWS (never silently overwrites a real file).
//     `loadOrSeed()` is the never-throwing convenience that logs + returns the
//     seed, for call sites that must always make progress (e.g. registration).

import Foundation

public actor RegistryConfigStore {
    /// The process-wide config store. Because it is ONE actor, every config
    /// mutation routed through it (load→modify→save inside a single actor
    /// method, e.g. `upsertEntity`) is serialized — concurrent introspect/add
    /// calls can't lose each other's writes. Production (RegistryModule, the
    /// pane view-model) MUST use `.shared` for mutations. Its path resolves
    /// DYNAMICALLY (see `effectiveURL`) so it still honors
    /// `BridgePaths.overrideHomeForTesting`.
    public static let shared = RegistryConfigStore()

    /// nil ⇒ resolve the default path dynamically per call (honors the test
    /// home-override and keeps `.shared` correct across tests). A fixed URL is
    /// used by isolated unit tests.
    private let fixedURL: URL?

    /// - Parameter storeURL: explicit path (isolated tests). Omit/nil for the
    ///   dynamic default `…/The Bridge/registry/registry.json`.
    public init(storeURL: URL? = nil) {
        self.fixedURL = storeURL
    }

    private var storeURL: URL { fixedURL ?? Self.defaultURL() }

    public static func defaultURL() -> URL {
        BridgePaths.applicationSupport(.registry)
            .appendingPathComponent("registry.json", isDirectory: false)
    }

    public enum RegistryConfigError: Error, LocalizedError {
        case corrupt(String)
        public var errorDescription: String? {
            switch self {
            case .corrupt(let why): return "registry.json is corrupt: \(why)"
            }
        }
    }

    // MARK: - Load

    /// Load the persisted config. Missing file ⇒ the default seed (first run,
    /// not persisted until the first `save`). A present-but-undecodable file
    /// THROWS `RegistryConfigError.corrupt` so a real config is never silently
    /// clobbered.
    public func load() throws -> RegistryConfig {
        guard let data = try? Data(contentsOf: storeURL) else {
            return .defaultSeed()
        }
        do {
            return try JSONDecoder().decode(RegistryConfig.self, from: data)
        } catch {
            throw RegistryConfigError.corrupt("\(error)")
        }
    }

    /// Never-throwing load: seeds on a missing file AND on a corrupt one
    /// (logging the corruption). For call sites that must always proceed.
    public func loadOrSeed() -> RegistryConfig {
        do {
            return try load()
        } catch {
            NSLog("[RegistryConfigStore] config unreadable, using seed: %@", "\(error)")
            return .defaultSeed()
        }
    }

    /// Whether a config file exists on disk (vs. a seed-only first run).
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    // MARK: - Save

    /// Atomically persist `config` (temp file → replace).
    public func save(_ config: RegistryConfig) throws {
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let tmp = dir.appendingPathComponent(
            ".registry.json.tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: tmp, options: [.atomic])
            let fm = FileManager.default
            if fm.fileExists(atPath: storeURL.path) {
                _ = try fm.replaceItemAt(storeURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: storeURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Seed the file on disk if it does not yet exist; returns the config now
    /// on disk (seed if it was just written, else the existing one). Used at
    /// startup so a fresh install lands entity #1 (Skills) without a manual
    /// setup step.
    @discardableResult
    public func seedIfMissing() throws -> RegistryConfig {
        if exists() { return try load() }
        let seed = RegistryConfig.defaultSeed()
        try save(seed)
        return seed
    }

    // MARK: - Mutations (load → mutate → save)

    /// Upsert one entity and persist. Returns the saved config.
    @discardableResult
    public func upsertEntity(_ entity: RegistryEntity) throws -> RegistryConfig {
        var config = try load()
        config.upsert(entity)
        try save(config)
        return config
    }

    /// Remove one entity by key, persist, AND evict its row cache — the
    /// "forget this data source entirely" operation (symmetric to `upsertEntity`).
    /// A no-op (returns the current config, no save) if the key isn't present.
    /// Does NOT touch Notion — only the Bridge's local binding + cache.
    /// The Skills SEED is removable here like any other entity; the "explicit
    /// confirm" guard for it lives in the CALLER (the tool / the pane), not the
    /// store, so a deliberate programmatic removal stays simple.
    @discardableResult
    public func removeEntity(key: String) async throws -> RegistryConfig {
        var config = try load()
        guard config.removeEntity(key: key) else { return config }   // not present — no-op
        try save(config)
        await RegistryRowCache.shared.evictAll(entity: key)
        return config
    }
}
