// StandingOrdersStore.swift — Single-document store for the v3.5
// "Standing Orders": the user-authored operating preamble that every
// MCP client receives in the initialize handshake.
//
// PKT-9: backs the Settings → Standing Orders editor and the
// standing_orders_read / standing_orders_write MCP tools.
//
// Storage: one markdown file at
//   ~/Library/Application Support/The Bridge/standing-orders/orders.md
// plus a sibling metadata.json holding per-client overlays.
//
// Why a small directory not just a single .md?
//   • Future per-client overlays land as siblings (orders.claude.md, etc.)
//   • The metadata.json carries hash/timestamp for optimistic-concurrency
//     writes — a tool can pass `expectedHash` to prevent stomping.

import Foundation
import CryptoKit

public final class StandingOrdersStore: @unchecked Sendable {
    public static let shared = StandingOrdersStore()

    // MARK: - Public model

    public struct Snapshot: Equatable, Sendable {
        public let markdown: String
        public let hash: String           // SHA-256 (truncated to 16 hex) for optimistic concurrency
        public let updatedAt: Date
        public let estimatedTokens: Int   // rough approximation (chars / 4)
    }

    public enum InitializationState: String, Codable, Sendable {
        case complete = "COMPLETE"
        case degraded = "DEGRADED"
        case incomplete = "INCOMPLETE"
    }

    public struct InitializationReport: Equatable, Sendable {
        public let state: InitializationState
        public let doctrineVersion: String
        public let doctrineLoaded: Bool
        public let manifestLoaded: Bool
        public let metadataVerified: Bool
        public let issues: [String]
    }

    private struct Metadata: Codable {
        var updatedAt: String
        var hash: String
        var version: String
    }

    private struct SourceManifest: Codable {
        struct SSOT: Codable {
            var type: String
            var id: String
            var role: String
        }

        struct FileSource: Codable {
            var path: String
            var role: String
            var required: Bool
            var sha256: String?
        }

        struct ToolSource: Codable {
            var tool: String
            var role: String
            var required: Bool
            var zeroResultMeaning: String?
        }

        struct Sources: Codable {
            var handshakeDoctrine: FileSource
            var metadata: FileSource
            var routingRoster: ToolSource
            var supplementalOrders: ToolSource
        }

        struct FailurePolicy: Codable {
            var requiredSourceFailure: String
            var integrityMismatch: String
            var allowCompleteOnEmptySupplementalRegistry: Bool
        }

        var schemaVersion: Int
        var updatedAt: String
        var doctrineVersion: String
        var ssot: SSOT
        var sources: Sources
        var initializationSequence: [String]
        var completionReceiptFields: [String]
        var failurePolicy: FailurePolicy
    }

    public enum WriteError: Error, LocalizedError {
        case staleHash(expected: String, current: String)
        case ioFailure(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .staleHash(let expected, let current):
                return "Standing Orders changed since you last read it (expected \(expected), now \(current)). Re-read before writing."
            case .ioFailure(let e):
                return "Standing Orders write failed: \(e.localizedDescription)"
            }
        }
    }

    public enum Template: String, CaseIterable, Sendable {
        case cautious
        case soloDevTerse = "solo_dev_terse"
        case confirmDestructive = "confirm_destructive"

        public var label: String {
            switch self {
            case .cautious: return "Cautious researcher"
            case .soloDevTerse: return "Solo dev — terse"
            case .confirmDestructive: return "Confirm before destructive ops"
            }
        }

        public var body: String {
            switch self {
            case .cautious:
                return """
                # Standing Orders

                Treat every claim as a hypothesis until verified against primary sources.
                Cite your sources inline. When you are uncertain, say so explicitly.
                Prefer narrow questions over broad assertions.
                """
            case .soloDevTerse:
                return """
                # Standing Orders

                The operator is a solo developer working in their own time. Match that mode:
                - Skip filler. No "great question". No "let me think about that".
                - One idea per message. Make space for the next reply.
                - When an answer is a single sentence, ship a single sentence.
                - Use a code block only when code is the answer.
                """
            case .confirmDestructive:
                return """
                # Standing Orders

                Before any tool call that deletes, renames, sends, or pays:
                1. State exactly what will happen.
                2. List what cannot be undone.
                3. Wait for an explicit "yes" before proceeding.

                Read-only operations and idempotent writes proceed without confirmation.
                """
            }
        }
    }

    // MARK: - File layout

    private let storeName = "orders.md"
    private let metaName  = "metadata.json"
    private let manifestName = "manifest.json"

    private var dir: URL { BridgePaths.applicationSupport(.standingOrders) }
    private var ordersURL: URL { dir.appendingPathComponent(storeName) }
    private var metaURL: URL { dir.appendingPathComponent(metaName) }
    private var manifestURL: URL { dir.appendingPathComponent(manifestName) }

    // MARK: - Lifecycle

    /// First-run: if no orders file exists, seed it with the given template
    /// (or `cautious` by default). Idempotent — does nothing if the file
    /// is already present.
    public func seedIfEmpty(with template: Template = .cautious) throws {
        try ensureDir()
        if FileManager.default.fileExists(atPath: ordersURL.path) {
            try ensureInitializationContract()
            return
        }
        let now = Date()
        let version = currentDoctrineVersion()
        try template.body.write(to: ordersURL, atomically: true, encoding: .utf8)
        try writeMetadata(updatedAt: now, hash: Self.shortHash(template.body), version: version)
        try writeManifest(updatedAt: now, markdown: template.body, doctrineVersion: version)
    }

    /// Read current state. If the file does not exist, returns a Snapshot
    /// of empty markdown. Strict initialization callers must additionally use
    /// `initializationReport()`; an empty snapshot is not proof that no doctrine
    /// source exists.
    public func read() throws -> Snapshot {
        try ensureDir()
        let md: String
        if FileManager.default.fileExists(atPath: ordersURL.path) {
            md = try String(contentsOf: ordersURL, encoding: .utf8)
        } else {
            md = ""
        }
        let hash = Self.shortHash(md)
        let updatedAt = (try? FileManager.default.attributesOfItem(atPath: ordersURL.path))
            .flatMap { $0[.modificationDate] as? Date } ?? Date(timeIntervalSince1970: 0)
        return Snapshot(
            markdown: md,
            hash: hash,
            updatedAt: updatedAt,
            estimatedTokens: Self.estimateTokens(md)
        )
    }

    /// One-time migration/self-repair for pre-manifest installations. This only
    /// creates missing integrity files; it never overwrites an existing mismatch.
    public func ensureInitializationContract() throws {
        try ensureDir()
        guard FileManager.default.fileExists(atPath: ordersURL.path) else { return }
        let markdown = try String(contentsOf: ordersURL, encoding: .utf8)
        let updatedAt = (try? FileManager.default.attributesOfItem(atPath: ordersURL.path))
            .flatMap { $0[.modificationDate] as? Date } ?? Date()
        let version = currentDoctrineVersion()
        let manifestExists = FileManager.default.fileExists(atPath: manifestURL.path)
        // Creating the first manifest is the explicit legacy migration boundary:
        // normalize the old FNV metadata hash to the documented SHA-256 prefix.
        if !manifestExists || !FileManager.default.fileExists(atPath: metaURL.path) {
            try writeMetadata(updatedAt: updatedAt, hash: Self.shortHash(markdown), version: version)
        }
        if !manifestExists {
            try writeManifest(updatedAt: updatedAt, markdown: markdown, doctrineVersion: version)
        }
    }

    /// Validate the required handshake doctrine, integrity metadata, and source
    /// manifest. Required-source failures are INCOMPLETE; hash/version drift is
    /// DEGRADED. Supplemental orders are intentionally validated separately.
    public func initializationReport() -> InitializationReport {
        var requiredIssues: [String] = []
        var integrityIssues: [String] = []
        var doctrineLoaded = false
        var manifestLoaded = false
        var metadataVerified = false
        var doctrineVersion = "unknown"

        let markdown: String
        do {
            guard FileManager.default.fileExists(atPath: ordersURL.path) else {
                return InitializationReport(
                    state: .incomplete,
                    doctrineVersion: doctrineVersion,
                    doctrineLoaded: false,
                    manifestLoaded: false,
                    metadataVerified: false,
                    issues: ["Required handshake doctrine orders.md is missing."]
                )
            }
            markdown = try String(contentsOf: ordersURL, encoding: .utf8)
            doctrineLoaded = !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !doctrineLoaded {
                requiredIssues.append("Required handshake doctrine orders.md is empty.")
            }
        } catch {
            return InitializationReport(
                state: .incomplete,
                doctrineVersion: doctrineVersion,
                doctrineLoaded: false,
                manifestLoaded: false,
                metadataVerified: false,
                issues: ["Required handshake doctrine orders.md is unreadable: \(error.localizedDescription)"]
            )
        }

        let manifest: SourceManifest?
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
            manifestLoaded = true
            doctrineVersion = manifest?.doctrineVersion ?? doctrineVersion
        } catch {
            manifest = nil
            requiredIssues.append("Required standing-orders manifest.json is missing or unreadable.")
        }

        let metadata: Metadata?
        do {
            let data = try Data(contentsOf: metaURL)
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
            if doctrineVersion == "unknown" { doctrineVersion = metadata?.version ?? doctrineVersion }
        } catch {
            metadata = nil
            requiredIssues.append("Required standing-orders metadata.json is missing or unreadable.")
        }

        if let manifest {
            if manifest.schemaVersion != 1 {
                integrityIssues.append("Unsupported standing-orders manifest schemaVersion \(manifest.schemaVersion).")
            }
            if manifest.sources.handshakeDoctrine.path != storeName || !manifest.sources.handshakeDoctrine.required {
                integrityIssues.append("Manifest does not mark orders.md as the required handshake doctrine.")
            }
            if manifest.sources.metadata.path != metaName || !manifest.sources.metadata.required {
                integrityIssues.append("Manifest does not mark metadata.json as required integrity metadata.")
            }
            if manifest.sources.routingRoster.tool != "skills_routing_list" || !manifest.sources.routingRoster.required {
                integrityIssues.append("Manifest does not mark skills_routing_list as the required routing roster.")
            }
            if manifest.sources.supplementalOrders.tool != "standing_orders_list"
                || manifest.sources.supplementalOrders.required
                || manifest.sources.supplementalOrders.zeroResultMeaning != "no_supplemental_orders" {
                integrityIssues.append("Manifest does not classify standing_orders_list as a supplemental source.")
            }
            if manifest.sources.handshakeDoctrine.sha256 != Self.sha256Hex(markdown) {
                integrityIssues.append("Manifest doctrine hash does not match orders.md.")
            }
        }

        if let metadata {
            let hashMatches = metadata.hash == Self.shortHash(markdown)
            let versionMatches = manifest.map { $0.doctrineVersion == metadata.version } ?? false
            metadataVerified = hashMatches && versionMatches
            if !hashMatches {
                integrityIssues.append("metadata.json hash does not match orders.md.")
            }
            if manifest != nil && !versionMatches {
                integrityIssues.append("metadata.json version does not match manifest doctrineVersion.")
            }
        }

        let issues = requiredIssues + integrityIssues
        let state: InitializationState
        if !requiredIssues.isEmpty {
            state = .incomplete
        } else if !integrityIssues.isEmpty {
            state = .degraded
        } else {
            state = .complete
        }
        return InitializationReport(
            state: state,
            doctrineVersion: doctrineVersion,
            doctrineLoaded: doctrineLoaded,
            manifestLoaded: manifestLoaded,
            metadataVerified: metadataVerified,
            issues: issues
        )
    }

    /// Write new markdown. If `expectedHash` is supplied and does not match
    /// the current file's hash, throws `.staleHash` without writing.
    @discardableResult
    public func write(_ markdown: String, expectedHash: String? = nil) throws -> Snapshot {
        try ensureDir()
        if let expected = expectedHash {
            let current = try read().hash
            if current != expected {
                throw WriteError.staleHash(expected: expected, current: current)
            }
        }
        do {
            let doctrineVersion = currentDoctrineVersion()
            try markdown.write(to: ordersURL, atomically: true, encoding: .utf8)
            let now = Date()
            let hash = Self.shortHash(markdown)
            try writeMetadata(updatedAt: now, hash: hash, version: doctrineVersion)
            try writeManifest(updatedAt: now, markdown: markdown, doctrineVersion: doctrineVersion)
            // Standing Orders changed → fan out a resources/updated notification
            // to subscribed MCP sessions. Decoupled, best-effort no-op when no
            // SSE transport is running (stdio-only / tests). The composed
            // `bridge://standing-orders` body is what changed.
            BridgeResources.notifyResourceChanged(uri: BridgeResources.standingOrdersURI)
            return Snapshot(
                markdown: markdown,
                hash: hash,
                updatedAt: now,
                estimatedTokens: Self.estimateTokens(markdown)
            )
        } catch let e as WriteError {
            throw e
        } catch {
            throw WriteError.ioFailure(underlying: error)
        }
    }

    /// Wipe the store. Used by Reset Onboarding / Factory Reset / tests.
    public func resetForTesting() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func currentDoctrineVersion() -> String {
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(SourceManifest.self, from: data) {
            return manifest.doctrineVersion
        }
        if let data = try? Data(contentsOf: metaURL),
           let metadata = try? JSONDecoder().decode(Metadata.self, from: data) {
            return metadata.version
        }
        return "unversioned"
    }

    private func writeMetadata(updatedAt: Date, hash: String, version: String) throws {
        let metadata = Metadata(
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            hash: hash,
            version: version
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metaURL, options: [.atomic])
    }

    private func writeManifest(updatedAt: Date, markdown: String, doctrineVersion: String) throws {
        let manifest = SourceManifest(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            doctrineVersion: doctrineVersion,
            ssot: .init(
                type: "notion_page",
                id: "28acbb58889e80d5b111ed23b996c304",
                role: "authoritative_constitution"
            ),
            sources: .init(
                handshakeDoctrine: .init(
                    path: storeName,
                    role: "required_handshake_mirror",
                    required: true,
                    sha256: Self.sha256Hex(markdown)
                ),
                metadata: .init(
                    path: metaName,
                    role: "required_integrity_metadata",
                    required: true,
                    sha256: nil
                ),
                routingRoster: .init(
                    tool: "skills_routing_list",
                    role: "required_active_routing_roster",
                    required: true,
                    zeroResultMeaning: nil
                ),
                supplementalOrders: .init(
                    tool: "standing_orders_list",
                    role: "supplemental_orders",
                    required: false,
                    zeroResultMeaning: "no_supplemental_orders"
                )
            ),
            initializationSequence: [
                "bridge_status",
                "load_manifest",
                "load_handshake_doctrine",
                "verify_metadata_and_hash",
                "skills_routing_list",
                "standing_orders_list",
                "emit_completion_receipt",
            ],
            completionReceiptFields: [
                "bridgeState",
                "doctrineVersion",
                "routingRosterState",
                "supplementalOrderCount",
                "initializationState",
            ],
            failurePolicy: .init(
                requiredSourceFailure: "INCOMPLETE",
                integrityMismatch: "DEGRADED",
                allowCompleteOnEmptySupplementalRegistry: true
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    /// SHA-256 hex of the UTF-8 bytes.
    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Truncated SHA-256 hex (16 chars). Stable per process / platform.
    public static func shortHash(_ s: String) -> String {
        String(Self.sha256Hex(s).prefix(16))
    }

    /// Rough token approximation: ~4 chars/token. Acceptable for a UI
    /// warning meter; not used for billing.
    public static func estimateTokens(_ s: String) -> Int {
        max(0, s.count / 4)
    }
}

// MARK: - Multi-record standing orders (PKT-931, v3.7·B)
//
// The single-document store above (PKT-9 / v3.5) backs the one operating
// preamble injected at handshake time. PKT-931 layers a *multi-record* model
// on top so individual, id-addressable standing orders (per-skill, per-tool,
// per-context overlays) can be authored, listed, updated, and soft-deleted
// via the standing_orders_* MCP tools — mirroring the credential_* / skill_*
// tool families.
//
// Storage: a sibling JSON document at
//   ~/Library/Application Support/The Bridge/standing-orders/orders.json
// (the .md / metadata.json single-doc files are untouched). Schema-versioned,
// written with Data.write(options: .atomic) so a kill -9 mid-write cannot tear
// the file. All mutation is serialized through the `actor`, so concurrent
// standing_orders_save calls cannot race (packet QA: no last-write-wins).

/// Scope axis for a standing order — which surface the directive applies to.
public enum StandingOrderScope: String, Codable, Sendable, CaseIterable {
    case global
    case perSkill   = "per-skill"
    case perTool    = "per-tool"
    case perContext = "per-context"
}

/// One id-addressable standing order record.
public struct StandingOrder: Codable, Sendable, Equatable {
    public let id: String          // uuid4 (stable across updates)
    public var title: String
    public var body: String
    public var scope: StandingOrderScope
    public let createdAt: Date
    public var updatedAt: Date
    public var archived: Bool       // soft-delete flag
    public var archivedAt: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        scope: StandingOrderScope = .global,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archived: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.archivedAt = archivedAt
    }
}

/// Lightweight metadata projection returned by `list` (body omitted).
public struct StandingOrderSummary: Sendable, Equatable {
    public let id: String
    public let title: String
    public let scope: StandingOrderScope
    public let updatedAt: Date
    public let archived: Bool
}

public enum StandingOrdersRecordError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidScope(String)
}

/// Actor-isolated multi-record store backing the standing_orders_* MCP tools.
public actor StandingOrdersRecordStore {

    public static let shared = StandingOrdersRecordStore()

    private struct Document: Codable {
        var schemaVersion: Int
        var orders: [StandingOrder]
    }

    private static let currentSchemaVersion = 1
    private let storeURL: URL
    private var doc: Document

    public init(storeURL: URL = StandingOrdersRecordStore.defaultStoreURL()) {
        self.storeURL = storeURL
        self.doc = StandingOrdersRecordStore.loadOrRecover(url: storeURL)
    }

    public struct DiskInspection: Equatable, Sendable {
        public let loaded: Bool
        public let activeCount: Int
        public let issue: String?
    }

    public nonisolated static func defaultStoreURL() -> URL {
        BridgePaths.applicationSupport(.standingOrders)
            .appendingPathComponent("orders.json", isDirectory: false)
    }

    /// Synchronous, side-effect-free inspection for handshake receipts. A
    /// missing registry is a valid empty supplemental source; malformed JSON is
    /// degraded and must not be misreported as an empty registry.
    public nonisolated static func inspectOnDisk(url: URL = defaultStoreURL()) -> DiskInspection {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DiskInspection(loaded: true, activeCount: 0, issue: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(Document.self, from: data)
            return DiskInspection(
                loaded: true,
                activeCount: document.orders.filter { !$0.archived }.count,
                issue: nil
            )
        } catch {
            return DiskInspection(
                loaded: false,
                activeCount: 0,
                issue: "Supplemental standing-orders registry is unreadable: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Load / persist

    private nonisolated static func loadOrRecover(url: URL) -> Document {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return Document(schemaVersion: currentSchemaVersion, orders: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let d = try? decoder.decode(Document.self, from: data) {
            return d
        }
        // Corrupt file — preserve it for forensics, start fresh rather than throw.
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return Document(schemaVersion: currentSchemaVersion, orders: [])
    }

    private func persist() throws {
        let dir = storeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try data.write(to: storeURL, options: [.atomic])  // temp + atomic rename
    }

    // MARK: Read

    /// Metadata-only projection. Archived rows are excluded unless
    /// `includeArchived` is true. Sorted by updatedAt descending.
    public func list(includeArchived: Bool = false) -> [StandingOrderSummary] {
        doc.orders
            .filter { includeArchived || !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { StandingOrderSummary(id: $0.id, title: $0.title, scope: $0.scope, updatedAt: $0.updatedAt, archived: $0.archived) }
    }

    /// Full record by id. Soft-deleted (archived) records are treated as
    /// absent (read returns nil → caller maps to 404) unless `includeArchived`.
    public func read(id: String, includeArchived: Bool = false) -> StandingOrder? {
        guard let o = doc.orders.first(where: { $0.id == id }) else { return nil }
        if o.archived && !includeArchived { return nil }
        return o
    }

    // MARK: Write

    /// Idempotent upsert. If `id` is supplied and matches an existing record,
    /// that record is updated in place (no duplicate). Otherwise a new record
    /// is created. Saving an archived id un-archives it (operator re-authoring).
    @discardableResult
    public func save(
        id: String? = nil,
        title: String,
        body: String,
        scope: StandingOrderScope = .global
    ) throws -> StandingOrder {
        if let id, let idx = doc.orders.firstIndex(where: { $0.id == id }) {
            doc.orders[idx].title = title
            doc.orders[idx].body = body
            doc.orders[idx].scope = scope
            doc.orders[idx].updatedAt = Date()
            if doc.orders[idx].archived {
                doc.orders[idx].archived = false
                doc.orders[idx].archivedAt = nil
            }
            try persist()
            return doc.orders[idx]
        }
        let order = StandingOrder(id: id ?? UUID().uuidString, title: title, body: body, scope: scope)
        doc.orders.append(order)
        try persist()
        return order
    }

    // MARK: Delete

    /// Soft-delete: flag the record archived (and stamp archivedAt) rather
    /// than purging the row. Idempotent — archiving an already-archived row
    /// is a no-op success. Throws notFound for an unknown id.
    @discardableResult
    public func delete(id: String) throws -> StandingOrder {
        guard let idx = doc.orders.firstIndex(where: { $0.id == id }) else {
            throw StandingOrdersRecordError.notFound(id)
        }
        if !doc.orders[idx].archived {
            doc.orders[idx].archived = true
            doc.orders[idx].archivedAt = Date()
            doc.orders[idx].updatedAt = Date()
            try persist()
        }
        return doc.orders[idx]
    }

    // MARK: Test support

    public func reloadFromDisk() {
        doc = Self.loadOrRecover(url: storeURL)
    }
}
