// SkillExposureRuntime.swift — generation persistence, publication, reconciliation
// TheBridge · Modules · Skills

import Foundation
import MCP

/// Persisted freshness lease for an active Runtime Exposure generation.
/// Written on successful publish and on unchanged shadow renew. Independent
/// of `latest-receipt.json`, which remains the audit of the last
/// reconciliation *attempt* (including failed/blocked/changed shadows).
public struct SkillFreshnessLease: Codable, Sendable, Equatable {
    public let generationID: String
    public let renewedAt: Date
    public let receiptID: String

    public init(generationID: String, renewedAt: Date, receiptID: String) {
        self.generationID = generationID
        self.renewedAt = renewedAt
        self.receiptID = receiptID
    }
}

public struct SkillExposureReconciliationReceipt: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case shadow, publish }
    public enum Outcome: String, Codable, Sendable { case blocked, shadowReady, published, failed }
    public let receiptID: String
    public let mode: Mode
    public let outcome: Outcome
    public let attemptedAt: Date
    public let snapshotID: String?
    public let candidateGenerationID: String?
    public let activeGenerationID: String?
    public let errors: [String]
    public let warnings: [String]
    public let changes: [String]

    public init(receiptID: String = UUID().uuidString.lowercased(), mode: Mode,
                outcome: Outcome, attemptedAt: Date, snapshotID: String?,
                candidateGenerationID: String?, activeGenerationID: String?,
                errors: [String], warnings: [String], changes: [String]) {
        self.receiptID = receiptID
        self.mode = mode
        self.outcome = outcome
        self.attemptedAt = attemptedAt
        self.snapshotID = snapshotID
        self.candidateGenerationID = candidateGenerationID
        self.activeGenerationID = activeGenerationID
        self.errors = errors
        self.warnings = warnings
        self.changes = changes
    }
}

public actor SkillRuntimeGenerationStore {
    public static let shared = SkillRuntimeGenerationStore()
    private struct ActivePointer: Codable { let generationID: String }
    private let fixedDirectory: URL?

    public init(baseDirectory: URL? = nil) { fixedDirectory = baseDirectory }
    private var root: URL { fixedDirectory ?? BridgePaths.applicationSupport(.skillsExposure) }
    private var generationsDir: URL { root.appendingPathComponent("generations", isDirectory: true) }
    private var receiptsDir: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    private var pointerURL: URL { root.appendingPathComponent("active.json") }
    private var leaseURL: URL { root.appendingPathComponent("freshness-lease.json") }
    /// One-shot upgrade seed per store instance when the lease file is absent.
    private var didAttemptLeaseSeed = false

    public func activeGenerationID() -> String? {
        guard let data = try? Data(contentsOf: pointerURL),
              let pointer = try? decoder().decode(ActivePointer.self, from: data),
              !pointer.generationID.isEmpty else { return nil }
        return pointer.generationID
    }

    public func activeGeneration() -> SkillRuntimeGeneration? {
        guard let id = activeGenerationID() else { return nil }
        return generation(id: id)
    }

    public func generation(id: String) -> SkillRuntimeGeneration? {
        let url = generationsDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(SkillRuntimeGeneration.self, from: data)
    }

    public enum RoutingAuthority: Sendable {
        case legacy
        case active(SkillRuntimeExposureGate)
        case corrupt(pointerID: String)
    }

    public func gate() -> SkillRuntimeExposureGate? {
        guard let generation = activeGeneration() else { return nil }
        return .init(
            generation: generation,
            emergencyDenylist: emergencyDenylist(),
            freshnessRenewedAt: freshnessRenewedAt(for: generation)
        )
    }

    public func routingAuthority() -> RoutingAuthority {
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return .legacy }
        guard let data = try? Data(contentsOf: pointerURL),
              let pointer = try? decoder().decode(ActivePointer.self, from: data),
              !pointer.generationID.isEmpty else {
            return .corrupt(pointerID: "unreadable-active-pointer")
        }
        let pointerID = pointer.generationID
        guard let generation = generation(id: pointerID) else { return .corrupt(pointerID: pointerID) }
        return .active(.init(
            generation: generation,
            emergencyDenylist: emergencyDenylist(),
            freshnessRenewedAt: freshnessRenewedAt(for: generation)
        ))
    }

    @discardableResult
    public func stage(_ generation: SkillRuntimeGeneration) throws -> URL {
        try FileManager.default.createDirectory(at: generationsDir, withIntermediateDirectories: true)
        let url = generationsDir.appendingPathComponent("\(generation.generationID).json")
        try atomicWrite(generation, to: url)
        guard self.generation(id: generation.generationID) == generation else {
            throw StoreError.stagedVerificationFailed(generation.generationID)
        }
        return url
    }

    @discardableResult
    public func promote(generationID: String) throws -> String? {
        guard generation(id: generationID) != nil else { throw StoreError.generationMissing(generationID) }
        let previous = activeGenerationID()
        try atomicWrite(ActivePointer(generationID: generationID), to: pointerURL)
        guard activeGenerationID() == generationID else { throw StoreError.pointerVerificationFailed }
        return previous
    }

    public func restoreActiveGeneration(id: String?) throws {
        if let id { _ = try promote(generationID: id) }
        else { try? FileManager.default.removeItem(at: pointerURL) }
    }

    public func writeReceipt(_ receipt: SkillExposureReconciliationReceipt) throws {
        let url = receiptsDir.appendingPathComponent("\(receipt.receiptID).json")
        try atomicWrite(receipt, to: url)
        try atomicWrite(receipt, to: root.appendingPathComponent("latest-receipt.json"))
        if Self.receiptQualifiesForLease(receipt),
           let generationID = receipt.activeGenerationID, !generationID.isEmpty {
            try atomicWrite(
                SkillFreshnessLease(
                    generationID: generationID,
                    renewedAt: receipt.attemptedAt,
                    receiptID: receipt.receiptID
                ),
                to: leaseURL
            )
        }
    }

    public func latestReceipt() -> SkillExposureReconciliationReceipt? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("latest-receipt.json")) else { return nil }
        return try? decoder().decode(SkillExposureReconciliationReceipt.self, from: data)
    }

    public func freshnessLease() -> SkillFreshnessLease? {
        readLease()
    }

    /// A successful publish, or an unchanged shadow, renews the active
    /// generation's freshness window.
    ///
    /// The lease is a separate pointer from `latest-receipt.json`. Failed,
    /// blocked, and changed shadows still overwrite the latest-attempt audit
    /// but must not erase a prior good lease. Publish must not wait for a
    /// follow-up shadow to realign `freshnessLease.generationId` with the
    /// newly activated generation (#279).
    ///
    /// Shadow renew keys off empty exposure `changes` + the receipt's
    /// `activeGenerationID`, not `snapshotID` equality. The registry snapshot
    /// hash includes `notionLastEditedTime`, so ordinary page edits change
    /// the snapshot while leaving published Runtime Exposure policy unchanged
    /// (`changes == []`). Requiring snapshot equality left cold starts stuck
    /// on `runtime_exposure_freshness_expired` after a successful shadowReady
    /// (build 89 local pilot, 2026-08-03). Publish receipts qualify even when
    /// `changes` is non-empty: the new generation is already verified-active.
    private func freshnessRenewedAt(for generation: SkillRuntimeGeneration) -> Date? {
        if let lease = readLease(), lease.generationID == generation.generationID {
            return lease.renewedAt
        }
        guard !didAttemptLeaseSeed else { return nil }
        didAttemptLeaseSeed = true
        guard let seeded = newestQualifyingLease(for: generation.generationID) else { return nil }
        try? atomicWrite(seeded, to: leaseURL)
        return seeded.renewedAt
    }

    private func readLease() -> SkillFreshnessLease? {
        guard let data = try? Data(contentsOf: leaseURL) else { return nil }
        return try? decoder().decode(SkillFreshnessLease.self, from: data)
    }

    private static func receiptQualifiesForLease(
        _ receipt: SkillExposureReconciliationReceipt
    ) -> Bool {
        guard receipt.errors.isEmpty,
              !(receipt.activeGenerationID ?? "").isEmpty else { return false }
        switch (receipt.mode, receipt.outcome) {
        case (.shadow, .shadowReady):
            return receipt.changes.isEmpty
        case (.publish, .published):
            return true
        default:
            return false
        }
    }

    private func newestQualifyingLease(for generationID: String) -> SkillFreshnessLease? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: receiptsDir.path)
        } catch {
            return nil
        }
        var best: SkillExposureReconciliationReceipt?
        for name in names where name.hasSuffix(".json") {
            let url = receiptsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? decoder().decode(SkillExposureReconciliationReceipt.self, from: data),
                  Self.receiptQualifiesForLease(receipt),
                  receipt.activeGenerationID == generationID
            else { continue }
            if let current = best {
                if receipt.attemptedAt > current.attemptedAt { best = receipt }
            } else {
                best = receipt
            }
        }
        guard let receipt = best, let gid = receipt.activeGenerationID else { return nil }
        return SkillFreshnessLease(
            generationID: gid,
            renewedAt: receipt.attemptedAt,
            receiptID: receipt.receiptID
        )
    }

    public func emergencyDenylist() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: BridgeDefaults.skillExposureEmergencyDenylist) ?? [])
            .map(SkillExposureIdentity.normalize))
    }

    public func setEmergencyDenylist(_ pageIDs: Set<String>) {
        let normalized = pageIDs.map(SkillExposureIdentity.normalize)
            .filter(SkillExposureIdentity.isValid).sorted()
        UserDefaults.standard.set(normalized, forKey: BridgeDefaults.skillExposureEmergencyDenylist)
    }

    /// Drop named entries from the active published generation in place.
    /// Does not create a new generation ID and does not run publish reconcile.
    /// Returns the normalized UUIDs that were actually removed.
    @discardableResult
    public func dropPublishedEntries(pageIDs: Set<String>) throws -> [String] {
        let normalized = Set(pageIDs.map(SkillExposureIdentity.normalize).filter(SkillExposureIdentity.isValid))
        guard !normalized.isEmpty, let generation = activeGeneration() else { return [] }
        let removed = generation.entries
            .filter { normalized.contains($0.notionPageUUID) }
            .map(\.notionPageUUID)
        guard !removed.isEmpty else { return [] }
        let remaining = generation.entries.filter { !normalized.contains($0.notionPageUUID) }
        let updated = SkillRuntimeGeneration(
            schemaVersion: generation.schemaVersion,
            generationID: generation.generationID,
            snapshotID: generation.snapshotID,
            compilerVersion: generation.compilerVersion,
            compiledAt: generation.compiledAt,
            entries: remaining
        )
        try stage(updated)
        guard self.generation(id: generation.generationID) == updated else {
            throw StoreError.stagedVerificationFailed(generation.generationID)
        }
        return removed.sorted()
    }

    public enum StoreError: Error, LocalizedError {
        case generationMissing(String), stagedVerificationFailed(String), pointerVerificationFailed
        public var errorDescription: String? {
            switch self {
            case .generationMissing(let id): return "skill exposure generation missing: \(id)"
            case .stagedVerificationFailed(let id): return "staged generation failed read-back: \(id)"
            case .pointerVerificationFailed: return "active generation pointer failed read-back"
            }
        }
    }

    private func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // Date stores a binary Double. Persist that value directly so
            // staged read-back verification remains exact even when the
            // reconciliation timestamp carries sub-millisecond precision.
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        return value
    }

    private func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let raw = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }

            // Backward compatibility for generations and receipts written by
            // v1.0.0, whose `.iso8601` strategy emitted whole-second values.
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: raw) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(raw)"
            )
        }
        return value
    }

    private func atomicWrite<T: Encodable>(_ value: T, to destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder().encode(value)
        let temp = dir.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: destination) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

public struct SkillRuntimeProjectionBackup: Sendable { let data: Data? }

public enum SkillRuntimeProjectionPublisher {
    public static func backup() -> SkillRuntimeProjectionBackup {
        .init(data: UserDefaults.standard.data(forKey: BridgeDefaults.skills))
    }

    public static func apply(_ generation: SkillRuntimeGeneration) {
        let existing = SkillsModule.readAllSkills()
        let files = existing.filter { $0.source.isFile }
        let pairs = existing.compactMap { config -> (String, SkillsModule.SkillConfig)? in
            guard !config.source.isFile else { return nil }
            let id = SkillExposureIdentity.normalize(config.notionPageId)
            return SkillExposureIdentity.isValid(id) ? (id, config) : nil
        }
        let byID = Dictionary(uniqueKeysWithValues: pairs)
        let projected = generation.entries.map { entry -> SkillsModule.SkillConfig in
            let old = byID[entry.notionPageUUID]
            return .init(name: entry.displayName, source: .notion(pageId: entry.notionPageUUID), enabled: true,
                         routingDiscoverable: entry.publishedExposure.routingDiscoverable,
                         inCommandPalette: entry.publishedExposure.inCommandPalette,
                         summary: old?.summary ?? "", triggerPhrases: old?.triggerPhrases ?? [],
                         antiTriggerPhrases: old?.antiTriggerPhrases ?? [],
                         url: entry.url.isEmpty ? old?.url : entry.url, platform: old?.platform ?? .notion)
        }
        SkillsModule.writeSkills(files + projected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    public static func rollback(_ backup: SkillRuntimeProjectionBackup) {
        if let data = backup.data { UserDefaults.standard.set(data, forKey: BridgeDefaults.skills) }
        else { UserDefaults.standard.removeObject(forKey: BridgeDefaults.skills) }
        NotificationCenter.default.post(name: .notionBridgeSkillsStorageDidChange, object: nil)
    }

    public static func verify(_ generation: SkillRuntimeGeneration) -> Bool {
        let notion = SkillsModule.readAllSkills().filter { !$0.source.isFile }
        let got = Dictionary(uniqueKeysWithValues: notion.map {
            (SkillExposureIdentity.normalize($0.notionPageId), ($0.enabled, $0.routingDiscoverable, $0.inCommandPalette))
        })
        guard got.count == generation.entries.count else { return false }
        return generation.entries.allSatisfy { entry in
            got[entry.notionPageUUID].map {
                $0.0 && $0.1 == entry.publishedExposure.routingDiscoverable
                    && $0.2 == entry.publishedExposure.inCommandPalette
            } ?? false
        }
    }
}

public struct SkillExposureReconciler: Sendable {
    public let gateway: RegistryNotionGateway
    public let configStore: RegistryConfigStore
    public let generationStore: SkillRuntimeGenerationStore
    public let now: @Sendable () -> Date

    public init(gateway: RegistryNotionGateway = LiveRegistryGateway(),
                configStore: RegistryConfigStore = .shared,
                generationStore: SkillRuntimeGenerationStore = .shared,
                now: @Sendable @escaping () -> Date = { Date() }) {
        self.gateway = gateway
        self.configStore = configStore
        self.generationStore = generationStore
        self.now = now
    }

    public func fetchSnapshot() async throws -> SkillRegistryExposureSnapshot {
        let config = try await configStore.load()
        guard let entity = config.entity(RegistryEntity.seedEntityKey), entity.isBoundToSource else {
            throw ReconcileError.skillsSourceUnbound
        }
        let schema = try await gateway.schema(dataSourceId: entity.dataSourceId, workspace: entity.workspace)
        var rows: [NotionRow] = []
        var cursor: String?
        var pages = 0
        repeat {
            let result = try await gateway.query(dataSourceId: entity.dataSourceId, workspace: entity.workspace,
                                                 pageSize: 100, startCursor: cursor)
            rows.append(contentsOf: result.rows.filter { !$0.archived })
            cursor = result.nextCursor
            pages += 1
            if pages >= 200 && cursor != nil { throw ReconcileError.paginationLimitExceeded }
        } while cursor != nil
        let decoded = rows.map(Self.exposureRow)
        let columns = schema.columnsByName.mapValues(\.type)
        return .init(snapshotID: Self.snapshotID(schema: columns, rows: decoded), capturedAt: now(),
                     schemaColumns: columns, paginationComplete: true, rows: decoded)
    }

    public func reconcile(mode: SkillExposureReconciliationReceipt.Mode,
                          baseline: [SkillExposureBaselineEntry],
                          approvals: [SkillExposureApproval]) async -> SkillExposureReconciliationReceipt {
        let attemptedAt = now()
        do {
            let snapshot = try await fetchSnapshot()
            let previous = await generationStore.activeGeneration()
            let denylist = await generationStore.emergencyDenylist()
            let compiled = SkillExposureCompiler.compile(snapshot: snapshot, previousGeneration: previous,
                                                         baseline: baseline, approvals: approvals,
                                                         emergencyDenylist: denylist,
                                                         requireReviewedPublishedRows: mode == .publish,
                                                         now: attemptedAt)
            guard let candidate = compiled.candidate else {
                let receipt = SkillExposureReconciliationReceipt(mode: mode, outcome: .blocked,
                    attemptedAt: attemptedAt, snapshotID: snapshot.snapshotID,
                    candidateGenerationID: nil, activeGenerationID: previous?.generationID,
                    errors: compiled.errors, warnings: compiled.warnings, changes: compiled.changes)
                try? await generationStore.writeReceipt(receipt)
                return receipt
            }
            if mode == .shadow {
                let receipt = SkillExposureReconciliationReceipt(mode: mode, outcome: .shadowReady,
                    attemptedAt: attemptedAt, snapshotID: snapshot.snapshotID,
                    candidateGenerationID: candidate.generationID, activeGenerationID: previous?.generationID,
                    errors: [], warnings: compiled.warnings, changes: compiled.changes)
                try? await generationStore.writeReceipt(receipt)
                return receipt
            }

            _ = try await generationStore.stage(candidate)
            let previousID = await generationStore.activeGenerationID()
            let backup = SkillRuntimeProjectionPublisher.backup()
            do {
                SkillRuntimeProjectionPublisher.apply(candidate)
                _ = try await generationStore.promote(generationID: candidate.generationID)
                guard SkillRuntimeProjectionPublisher.verify(candidate),
                      await generationStore.activeGeneration() == candidate else {
                    throw ReconcileError.publicationVerificationFailed
                }
                await SkillRuntimeCachePruner.prune(using: .init(generation: candidate, emergencyDenylist: denylist))
                // Prune only filters existing cache children. Enrollment
                // expansions (new Standard specialists) need a live re-enumeration.
                await SkillRuntimeCachePruner.refreshRouting()
            } catch {
                SkillRuntimeProjectionPublisher.rollback(backup)
                try? await generationStore.restoreActiveGeneration(id: previousID)
                throw error
            }
            let receipt = SkillExposureReconciliationReceipt(mode: mode, outcome: .published,
                attemptedAt: attemptedAt, snapshotID: snapshot.snapshotID,
                candidateGenerationID: candidate.generationID, activeGenerationID: candidate.generationID,
                errors: [], warnings: compiled.warnings, changes: compiled.changes)
            try? await generationStore.writeReceipt(receipt)
            return receipt
        } catch {
            let receipt = SkillExposureReconciliationReceipt(mode: mode, outcome: .failed,
                attemptedAt: attemptedAt, snapshotID: nil, candidateGenerationID: nil,
                activeGenerationID: await generationStore.activeGenerationID(),
                errors: ["reconciliation_failed:\(error)"], warnings: [], changes: [])
            try? await generationStore.writeReceipt(receipt)
            return receipt
        }
    }

    public enum ReconcileError: Error, LocalizedError {
        case skillsSourceUnbound, paginationLimitExceeded, publicationVerificationFailed
        public var errorDescription: String? {
            switch self {
            case .skillsSourceUnbound: return "Skills registry entity is not bound to a Notion data source"
            case .paginationLimitExceeded: return "Skills registry pagination exceeded the 200-page safety cap"
            case .publicationVerificationFailed: return "published skill generation failed read-back verification"
            }
        }
    }

    private static func exposureRow(_ row: NotionRow) -> SkillRegistryExposureRow {
        .init(notionPageUUID: row.id, displayName: string(row.cells["Skill Name"]?.value) ?? "",
              slug: string(row.cells["Slug"]?.value) ?? "", status: string(row.cells["Status"]?.value),
              maturity: string(row.cells["Maturity"]?.value),
              deprecationDate: date(row.cells["Deprecation Date"]?.value),
              desiredExposure: string(row.cells["Runtime Exposure"]?.value).flatMap(SkillRuntimeExposure.init(rawValue:)),
              url: row.url, notionLastEditedTime: row.lastEditedTime)
    }

    private static func string(_ value: Value?) -> String? {
        guard case .string(let value)? = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Value?) -> Date? {
        let raw: String?
        switch value {
        case .string(let string): raw = string
        case .object(let object): if case .string(let start)? = object["start"] { raw = start } else { raw = nil }
        default: raw = nil
        }
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter(); standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: raw) { return date }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }

    private static func snapshotID(schema: [String: String], rows: [SkillRegistryExposureRow]) -> String {
        var raw = schema.keys.sorted().map { "\($0)=\(schema[$0] ?? "")" }.joined(separator: "|")
        for row in rows.sorted(by: { $0.notionPageUUID < $1.notionPageUUID }) {
            raw += "|\(row.notionPageUUID)|\(row.displayName)|\(row.slug)|\(row.status ?? "")|\(row.maturity ?? "")|\(row.deprecationDate?.timeIntervalSince1970 ?? -1)|\(row.desiredExposure?.rawValue ?? "")|\(row.notionLastEditedTime)"
        }
        var hash: UInt64 = 14695981039346656037
        for byte in raw.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return String(hash, radix: 16)
    }
}

/// Explicit local+published orphan drop. Default reconcile never calls this.
public enum SkillExposureOrphanPurger {
    public static func apply(
        pageIDs: [String],
        generationStore: SkillRuntimeGenerationStore,
        pruneCaches: Bool = false
    ) async throws -> SkillExposureOrphanPurge.Outcome {
        let classified = SkillExposureOrphanPurge.classify(pageIDs)
        let admitted = Set(classified.admitted)
        guard !admitted.isEmpty else {
            return .init(
                purgedLocal: [],
                purgedPublished: [],
                held: classified.held,
                notFound: [],
                invalid: classified.invalid
            )
        }

        let purgedLocal = dropLocalSkills(pageIDs: admitted)
        let purgedPublished = try await generationStore.dropPublishedEntries(pageIDs: admitted)
        let found = Set(purgedLocal).union(purgedPublished)
        let notFound = classified.admitted.filter { !found.contains($0) }

        // Tests use a temp generation store. Pruning against that gate would
        // evict the process-global body/routing caches for every page not in
        // the fixture. Only the MCP tool (shared store) opts in.
        if pruneCaches, let gate = await generationStore.gate() {
            await SkillRuntimeCachePruner.prune(using: gate)
        }

        return .init(
            purgedLocal: purgedLocal,
            purgedPublished: purgedPublished,
            held: classified.held,
            notFound: notFound,
            invalid: classified.invalid
        )
    }

    private static func dropLocalSkills(pageIDs: Set<String>) -> [String] {
        let all = SkillsModule.readAllSkills()
        var removed: [String] = []
        let kept = all.filter { skill in
            guard !skill.source.isFile else { return true }
            let id = SkillExposureIdentity.normalize(skill.notionPageId)
            guard SkillExposureIdentity.isValid(id), pageIDs.contains(id) else { return true }
            removed.append(id)
            return false
        }
        if !removed.isEmpty {
            SkillsModule.writeSkills(kept)
        }
        return Array(Set(removed)).sorted()
    }
}

public enum SkillRuntimeCachePruner {
    public static func prune(using gate: SkillRuntimeExposureGate, now: Date = Date()) async {
        // Memory keys are name+params+meta, not page id — selective evict is
        // not possible. Full clear matches SkillBodyCacheEviction.
        await SkillCache.shared.clear()
        for body in await SkillBodyCacheStore.shared.readAll()
            where !gate.allows(pageID: body.pageId, surface: .bodyCache, now: now) {
            await SkillBodyCacheStore.shared.evict(pageId: body.pageId)
        }
        for parent in await SkillsCacheReader.shared.readAll() {
            if !gate.allows(pageID: parent.parentId, surface: .routing, now: now) {
                try? FileManager.default.removeItem(at: SkillsCacheReader.fileURL(for: parent.parentId))
                continue
            }
            let children = parent.children.filter { gate.allows(pageID: $0.id, surface: .specialist, now: now) }
            if children != parent.children {
                try? await SkillsCacheWriter.shared.write(parent: .init(writtenAt: parent.writtenAt,
                    ttlHours: parent.ttlHours, parentId: parent.parentId,
                    parentTitle: parent.parentTitle, children: children))
            }
        }
    }

    /// Re-enumerate Specialist-relation children after a generation change.
    /// `prune` cannot add newly allowed children; handshake lists stay stale
    /// until this refresh (or Settings → Refresh routing cache).
    @discardableResult
    public static func refreshRouting(
        source: SkillsCacheWriter.ParentSource,
        enumerator: SkillsCacheWriter.ChildEnumerator,
        ttlHours: Int = BridgeDefaults.skillsCacheTTLHoursEffective,
        now: Date = Date()
    ) async -> Int {
        await SkillsCacheWriter.shared.refreshAll(
            source: source, enumerator: enumerator, ttlHours: ttlHours, now: now
        )
    }

    @discardableResult
    public static func refreshRouting() async -> Int {
        guard let client = try? NotionClient() else {
            NSLog("[SkillRuntimeCachePruner] routing refresh skipped — no Notion token")
            return 0
        }
        let source = await MainActor.run {
            SkillsCacheWriter.ParentSource.fromSkillsManager(SkillsManager())
        }
        return await refreshRouting(source: source, enumerator: .live(client: client))
    }
}

// MARK: - Periodic shadow reconciliation

/// Serializes registry reconciliation. Startup remains shadow-only until the
/// zero-orphan migration gate is satisfied and an approved publish is invoked.
public actor SkillExposureReconciliationCoordinator {
    public static let shared = SkillExposureReconciliationCoordinator()
    public static let intervalNanoseconds: UInt64 = 6 * 60 * 60 * 1_000_000_000

    private var loopTask: Task<Void, Never>?
    private struct ActiveRun {
        let id: UUID
        let mode: SkillExposureReconciliationReceipt.Mode
        let task: Task<SkillExposureReconciliationReceipt?, Never>
    }
    private var activeRun: ActiveRun?

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.runShadow()
                do { try await Task.sleep(nanoseconds: Self.intervalNanoseconds) }
                catch { return }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    @discardableResult
    public func runShadow() async -> SkillExposureReconciliationReceipt? {
        await run(mode: .shadow, approvals: [])
    }

    /// Run one serialized reconciliation immediately. Publication remains
    /// compiler-gated and route-governed by the caller; this coordinator only
    /// ensures startup, periodic, UI, and MCP triggers cannot overlap.
    @discardableResult
    public func run(
        mode: SkillExposureReconciliationReceipt.Mode,
        approvals: [SkillExposureApproval]
    ) async -> SkillExposureReconciliationReceipt? {
        if let active = activeRun {
            let result = await active.task.value
            if activeRun?.id == active.id { activeRun = nil }
            if active.mode == mode, approvals.isEmpty {
                return result
            }
            return await run(mode: mode, approvals: approvals)
        }
        let id = UUID()
        let task = Task { () -> SkillExposureReconciliationReceipt? in
            let baseline = await MainActor.run {
                SkillExposureBaselineEntry.fromSkillsManager(SkillsManager())
            }
            return await SkillExposureReconciler().reconcile(
                mode: mode,
                baseline: baseline,
                approvals: approvals
            )
        }
        activeRun = ActiveRun(id: id, mode: mode, task: task)
        let result = await task.value
        if activeRun?.id == id { activeRun = nil }
        return result
    }
}
