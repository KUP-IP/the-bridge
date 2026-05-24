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

public final class StandingOrdersStore: @unchecked Sendable {
    public static let shared = StandingOrdersStore()

    // MARK: - Public model

    public struct Snapshot: Equatable, Sendable {
        public let markdown: String
        public let hash: String           // sha256 (truncated to 16 hex) for optimistic concurrency
        public let updatedAt: Date
        public let estimatedTokens: Int   // rough approximation (chars / 4)
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

    private var dir: URL { BridgePaths.applicationSupport(.standingOrders) }
    private var ordersURL: URL { dir.appendingPathComponent(storeName) }
    private var metaURL: URL { dir.appendingPathComponent(metaName) }

    // MARK: - Lifecycle

    /// First-run: if no orders file exists, seed it with the given template
    /// (or `cautious` by default). Idempotent — does nothing if the file
    /// is already present.
    public func seedIfEmpty(with template: Template = .cautious) throws {
        try ensureDir()
        if FileManager.default.fileExists(atPath: ordersURL.path) { return }
        try template.body.write(to: ordersURL, atomically: true, encoding: .utf8)
        try writeMetadata(updatedAt: Date(), hash: Self.shortHash(template.body))
    }

    /// Read current state. If the file does not exist, returns a Snapshot
    /// of empty markdown.
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
            try markdown.write(to: ordersURL, atomically: true, encoding: .utf8)
            let now = Date()
            let hash = Self.shortHash(markdown)
            try writeMetadata(updatedAt: now, hash: hash)
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

    private func writeMetadata(updatedAt: Date, hash: String) throws {
        let iso = ISO8601DateFormatter().string(from: updatedAt)
        let payload = """
        {"updatedAt":"\(iso)","hash":"\(hash)","version":"v3.5"}
        """
        try payload.write(to: metaURL, atomically: true, encoding: .utf8)
    }

    /// Truncated SHA-256 hex (16 chars). Stable per process / platform.
    public static func shortHash(_ s: String) -> String {
        // Avoid importing CryptoKit so this file stays portable across targets.
        // FNV-1a 64-bit is good enough for optimistic-concurrency stomping detection.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Rough token approximation: ~4 chars/token. Acceptable for a UI
    /// warning meter; not used for billing.
    public static func estimateTokens(_ s: String) -> Int {
        max(0, s.count / 4)
    }
}
