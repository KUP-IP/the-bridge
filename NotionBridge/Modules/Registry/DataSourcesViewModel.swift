// DataSourcesViewModel.swift — Data-Source Registry (Wave 4)
// NotionBridge · Modules · Registry
//
// The testable contract behind the Settings → "Data Sources" pane (Decision 5
// onboarding UX: auto-introspect → propose → confirm). The pane is a thin
// SwiftUI binding over this view-model; ALL behavior + state lives here so the
// "user scenarios" are unit-tested without a UI runner (the codebase's pattern,
// cf. SkillManagementUIScenarioTests).
//
// BE↔FE ALIGNMENT (by construction): this view-model reads/writes the SAME
// `RegistryConfigStore` and uses the SAME `RegistryModule.gateway()` seam the
// MCP tools use — so a binding confirmed in the UI is the binding the
// `registry_*` tools see, and vice-versa. No parallel state.

import Foundation
import Combine

@MainActor
public final class DataSourcesViewModel: ObservableObject {
    /// Configured entities (mirrors `registry_entities`).
    @Published public private(set) var entities: [RegistryEntity] = []
    /// A pending, NOT-yet-persisted introspection proposal (propose→confirm).
    @Published public private(set) var proposal: Proposal?
    /// Cached row counts per entity key (freshness indicator).
    @Published public private(set) var cacheCounts: [String: Int] = [:]
    /// Busy flag for spinners.
    @Published public private(set) var busy = false
    /// Last user-facing status line (success or error).
    @Published public private(set) var status: String = ""

    public init() {}

    /// A proposed binding for an entity — drift + the resolved entity, held
    /// until the user confirms (Decision 5: "user confirms").
    public struct Proposal: Equatable, Sendable {
        public let entityKey: String
        public let resolved: RegistryEntity
        public let drift: [String]
        public let schemaColumns: [String]
        /// Derived from the TYPED `RegistryBindResult.isClean` (no unmatched
        /// columns), not by string-matching the human-readable drift messages —
        /// so a wording change to a drift message can't silently break this.
        public let clean: Bool
        public var fullyBound: Bool { resolved.isFullyBound }
    }

    // The SHARED store: mutations serialize with the registry tools' writes
    // (BE↔FE alignment + no lost updates).
    private func store() -> RegistryConfigStore { .shared }

    // MARK: - Load

    public func load() async {
        let s = store()
        let cfg: RegistryConfig
        if let seeded = try? await s.seedIfMissing() {
            cfg = seeded
        } else {
            cfg = await s.loadOrSeed()
        }
        entities = cfg.entities
        await refreshCacheCounts()
    }

    public func refreshCacheCounts() async {
        var counts: [String: Int] = [:]
        for e in entities {
            counts[e.key] = await RegistryRowCache.shared.readAll(entity: e.key).count
        }
        cacheCounts = counts
    }

    public func entity(_ key: String) -> RegistryEntity? { entities.first { $0.key == key } }

    /// Bound / total property counts for a progress label.
    public func bindingProgress(_ key: String) -> (bound: Int, total: Int) {
        guard let e = entity(key) else { return (0, 0) }
        return (e.properties.filter { $0.isBound }.count, e.properties.count)
    }

    // MARK: - Propose → Confirm (Decision 5)

    /// Read the live schema and PROPOSE a binding (match by name → ids + drift)
    /// WITHOUT persisting. The user reviews `proposal` then confirms.
    public func proposeIntrospection(_ key: String) async {
        guard let e = entity(key) else { status = "Unknown entity ‘\(key)’"; return }
        busy = true; status = "Reading schema for \(e.displayName)…"
        defer { busy = false }
        do {
            let schema = try await RegistryModule.gateway().schema(dataSourceId: e.dataSourceId, workspace: e.workspace)
            let result = RegistrySchemaBinder.bind(e, to: schema)
            proposal = Proposal(
                entityKey: key,
                resolved: result.entity,
                drift: result.drift.map { $0.message },
                schemaColumns: schema.names,
                clean: result.isClean)
            let bound = result.entity.properties.filter { $0.isBound }.count
            status = "Proposed \(bound)/\(e.properties.count) bound" + (result.hasDrift ? " · \(result.drift.count) issue(s)" : " · clean")
        } catch {
            proposal = nil
            status = "Introspection failed: \(error.localizedDescription)"
        }
    }

    /// Persist the pending proposal (Decision 5: "user confirms"). Returns true
    /// on success.
    @discardableResult
    public func confirmProposal() async -> Bool {
        guard let p = proposal else { status = "Nothing to confirm"; return false }
        busy = true; defer { busy = false }
        do {
            _ = try await store().upsertEntity(p.resolved)   // atomic, serialized
            proposal = nil
            await load()
            status = "Saved bindings for \(p.entityKey)"
            return true
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    public func cancelProposal() {
        proposal = nil
        status = "Cancelled"
    }

    // MARK: - Per-entity settings

    /// Set an entity's cache TTL (Decision 4) and persist.
    public func setTTL(_ key: String, seconds: Int) async {
        guard var e = entity(key) else { return }
        e.cacheTTLSeconds = max(0, seconds)
        busy = true; defer { busy = false }
        do {
            _ = try await store().upsertEntity(e)   // atomic, serialized
            await load()
            status = "TTL for \(e.displayName) set to \(e.cacheTTLSeconds)s"
        } catch {
            status = "Could not save TTL: \(error.localizedDescription)"
        }
    }

    /// Wipe an entity's cache (Decision 8 disconnect-wipe; also a manual
    /// "clear cache" affordance).
    public func clearCache(_ key: String) async {
        await RegistryRowCache.shared.evictAll(entity: key)
        await refreshCacheCounts()
        status = "Cleared cache for \(key)"
    }

    // MARK: - Remove data source

    /// Whether `key` is the seeded Skills entity — the pane requires an extra,
    /// explicit confirm before removing it (it's the validating fold-in + the
    /// default a fresh install relies on). Mirrors the `registry_remove_entity`
    /// tool guard so the UI and the MCP surface agree.
    public func isSeed(_ key: String) -> Bool { key == RegistryEntity.seedEntityKey }

    /// Remove an entity from the registry (forget its binding + evict its cache)
    /// and persist. Goes through the SHARED store, so it serializes with the
    /// registry tools' writes (BE↔FE alignment). Does NOT touch Notion.
    public func removeEntity(_ key: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await store().removeEntity(key: key)   // atomic, serialized, evicts cache
            await load()
            status = "Removed data source ‘\(key)’"
        } catch {
            status = "Could not remove ‘\(key)’: \(error.localizedDescription)"
        }
    }
}
