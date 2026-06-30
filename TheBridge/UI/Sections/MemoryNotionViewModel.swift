// MemoryNotionViewModel.swift — Settings → Memory → Notion tab (PKT-MEM-104)
// TheBridge · UI · Sections

import Foundation
import Combine

@MainActor
public final class MemoryNotionViewModel: ObservableObject {
    @Published public private(set) var rows: [CachedRow] = []
    @Published public private(set) var status: String = ""
    @Published public private(set) var busy = false
    @Published public private(set) var entityConfigured = false

    public static let defaultLimit = 20

    public init() {}

    /// Force a network read (Settings → Memory → Notion Refresh).
    public func refresh(limit: Int = defaultLimit) async {
        await load(limit: limit)
    }

    public func load(limit: Int = defaultLimit) async {
        busy = true
        defer { busy = false }

        let config = await Self.loadConfig()
        guard let entity = config.entity("memory") else {
            entityConfigured = false
            rows = []
            status = "Memory entity is not configured — bind it in Data Sources."
            return
        }
        entityConfigured = entity.isBoundToSource
        guard entity.isBoundToSource else {
            rows = []
            status = "Connect the Memory data source in Data Sources to preview rows here."
            return
        }

        let reader = RegistryReader(gateway: RegistryModule.gateway())
        do {
            var fetched = try await reader.list(entity: entity, limit: max(1, limit))
            fetched.sort { $0.lastEditedTime > $1.lastEditedTime }
            rows = fetched
            status = rows.isEmpty
                ? "No Memory rows cached yet — run the voice curator or create a row via registry."
                : "\(rows.count) recent row(s)"
        } catch {
            let cached = await RegistryRowCache.shared.readAll(entity: "memory")
            rows = cached.sorted { $0.lastEditedTime > $1.lastEditedTime }.prefix(limit).map { $0 }
            status = cached.isEmpty
                ? "Could not load Memory rows: \(error.localizedDescription)"
                : "Offline — showing \(rows.count) cached row(s)"
        }
    }

    private static func loadConfig() async -> RegistryConfig {
        let store = RegistryConfigStore.shared
        if let seeded = try? await store.seedIfMissing() { return seeded }
        return await store.loadOrSeed()
    }
}
