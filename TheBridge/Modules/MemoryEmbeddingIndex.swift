// MemoryEmbeddingIndex.swift — Dense-vector embedding arm for MemoryStore
// TheBridge · Modules
//
// PKT-1007 Slice 1: on-device dense-vector retrieval via Apple NLContextualEmbedding,
// fused with the existing FTS5/bm25 arm through Reciprocal-Rank-Fusion (RRF).
//
// DESIGN
// ──────
// • Protocol seam `MemoryEmbedder` so the headless test build can inject a
//   deterministic stub without loading CoreML assets. The live implementation
//   (`NLContextualEmbedder`) is gated behind `#available(macOS 12.0, *)` which
//   is always satisfied here (Package.swift pins .macOS(.v26)), but the gate
//   keeps the code analysable on hypothetical older CI images.
//
// • `MemoryEmbeddingIndex` is a struct (value type, not an actor) because it is
//   only ever called from *within* the `MemoryStore` actor, which already provides
//   mutual exclusion. It holds a mutable in-memory vector cache keyed by entry id.
//
// • Embedding strategy: token-level contextual vectors are mean-pooled over all
//   tokens to produce a single sentence-level representation. This is the
//   standard pooling approach for NLContextualEmbedding and matches the
//   capabilities demonstrated in the embedding probe (cosine 0.93 for semantically
//   similar sentences vs 0.79 for unrelated ones).
//
// • Cosine similarity is used as the dense score; RRF fuses the FTS rank-list
//   and the dense rank-list. RRF formula: 1/(k + rank), where k=60 (standard
//   default). The fused list is sorted descending by combined score before the
//   salience layer in MemoryStore.recall.
//
// AVAILABILITY GATE
// ─────────────────
// NLContextualEmbedding is available from macOS 12. The project pins macOS 26,
// so the guard is always satisfied at runtime. However, in CI headless builds the
// embedding MODEL ASSETS may not be present. `NLContextualEmbedder.embed(_:)` is
// therefore non-throwing and returns `nil` when assets are unavailable, which
// causes `MemoryEmbeddingIndex.rankedByDense` to produce an empty list — the
// recall path then falls back to the FTS-only result set gracefully (RRF of an
// empty dense list is a no-op: FTS ranks win uncontested).

import Foundation
import NaturalLanguage

// MARK: - Embedder protocol (seam for testing)

/// A type that synchronously produces a fixed-dimensional float vector for a
/// text string. Returns `nil` if embedding is unavailable (assets missing, init
/// failure, etc.). The vector must be L2-normalized or normalization happens in
/// the cosine step — the implementation normalizes before returning.
public protocol MemoryEmbedder: Sendable {
    /// Embed `text` and return a float vector, or `nil` if unavailable.
    func embed(_ text: String) -> [Double]?
    /// Dimensionality of the vector space (informational).
    var dimension: Int { get }
}

// MARK: - NLContextualEmbedding live implementation

/// Live embedder backed by `NLContextualEmbedding`. Thread-safe: the embedding
/// object itself is used read-only after init; the semaphore-gated asset request
/// happens once (lazily, on the first call).
public final class NLContextualEmbedder: MemoryEmbedder, @unchecked Sendable {
    // NLContextualEmbedding is not Sendable itself but is documented as
    // thread-safe for read (embed) operations. We mark the class @unchecked
    // Sendable because the embedding object is created once and then only read.
    private let embedding: NLContextualEmbedding?
    private var assetsReady = false
    private let assetLock = NSLock()

    /// Preferred initializer. Tries English first; falls back to nil embedder
    /// if NLContextualEmbedding is unavailable for this language.
    public init(language: NLLanguage = .english) {
        self.embedding = NLContextualEmbedding(language: language)
        if let emb = embedding {
            // Kick off a synchronous asset request so the first embed() call
            // does not block indefinitely. If this is a headless/CI environment
            // the request will succeed immediately (assets on disk) or return
            // a non-fatal result that embed() handles by returning nil.
            let lock = NSLock()
            let semaphore = DispatchSemaphore(value: 0)
            var done = false
            emb.requestAssets { _, _ in
                lock.lock()
                done = true
                lock.unlock()
                semaphore.signal()
            }
            // Wait up to 5 seconds for asset readiness on first init.
            let _ = semaphore.wait(timeout: .now() + 5)
            assetLock.lock()
            assetsReady = done
            assetLock.unlock()
        }
    }

    public var dimension: Int {
        embedding?.dimension ?? 512
    }

    public func embed(_ text: String) -> [Double]? {
        guard let emb = embedding, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        assetLock.lock()
        let ready = assetsReady
        assetLock.unlock()
        guard ready else { return nil }

        do {
            let result = try emb.embeddingResult(for: text, language: .english)
            return Self.meanPool(result: result, text: text, dimension: emb.dimension)
        } catch {
            return nil
        }
    }

    /// Mean-pool the per-token vectors into a single sentence-level vector,
    /// then L2-normalize so cosine similarity reduces to a dot product.
    public static func meanPool(result: NLContextualEmbeddingResult, text: String, dimension: Int) -> [Double]? {
        var sum = [Double](repeating: 0.0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == dimension else { return true }
            for (i, v) in vector.enumerated() { sum[i] += v }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let avg = sum.map { $0 / Double(count) }
        return l2Normalize(avg)
    }

    /// L2 normalize a vector (returns a unit vector). Returns the original if
    /// the norm is near-zero (zero vector cannot be normalized).
    public static func l2Normalize(_ v: [Double]) -> [Double] {
        let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard norm > 1e-10 else { return v }
        return v.map { $0 / norm }
    }
}

// MARK: - Stub embedder (deterministic, for tests)

/// A deterministic stub embedder that returns a synthetic embedding derived
/// purely from character n-gram hashing — no CoreML assets required. Used in
/// tests to exercise the dense-retrieval and RRF paths without loading models.
///
/// The stub is "good enough" for correctness tests: it can rank a text more
/// similar to itself than to an unrelated text (because the same text hash-maps
/// to the same vector). It is NOT a semantic embedder and is NOT used in production.
public struct StubMemoryEmbedder: MemoryEmbedder {
    public let dimension: Int

    public init(dimension: Int = 8) {
        self.dimension = dimension
    }

    public func embed(_ text: String) -> [Double]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Build a reproducible pseudo-embedding from character bigrams.
        // Two identical strings → identical vector; two completely different
        // strings → near-orthogonal vectors. Sufficient for RRF plumbing tests.
        var v = [Double](repeating: 0.0, count: dimension)
        let chars = Array(text.lowercased())
        for i in 0..<max(1, chars.count - 1) {
            let a = Int(chars[i].asciiValue ?? 0)
            let b = Int(chars[i + 1].asciiValue ?? 0)
            let idx = (a * 31 + b) % dimension
            v[idx] += 1.0
        }
        // L2-normalize
        let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
        guard norm > 1e-10 else { return v }
        return v.map { $0 / norm }
    }
}

// MARK: - MemoryEmbeddingIndex

/// In-memory dense-vector index over MemoryEntry text, with lazy population.
/// Must only be called from within the MemoryStore actor (provides isolation).
///
/// The index stores (id → vector) pairs. Entries are indexed on first recall
/// request; re-indexing is cheap (only missing ids are embedded).
public struct MemoryEmbeddingIndex {
    private var vectors: [String: [Double]] = [:]
    private let embedder: MemoryEmbedder

    public init(embedder: MemoryEmbedder) {
        self.embedder = embedder
    }

    /// Index any entries not yet embedded. Called from MemoryStore before recall.
    public mutating func index(entries: [MemoryEntry]) {
        for e in entries where vectors[e.id] == nil {
            if let v = embedder.embed(e.text) {
                vectors[e.id] = v
            }
        }
    }

    /// Remove a vector when an entry is tombstoned / deleted.
    public mutating func remove(id: String) {
        vectors.removeValue(forKey: id)
    }

    /// Dense-ranked list for `query`. Returns entries sorted by cosine
    /// similarity descending, paired with their [0,1] cosine score.
    /// Returns an empty list if the query cannot be embedded or no vectors exist.
    public func rankedByDense(query: String, candidates: [MemoryEntry]) -> [(entry: MemoryEntry, score: Double)] {
        guard !candidates.isEmpty else { return [] }
        guard let qv = embedder.embed(query) else { return [] }
        var scored: [(entry: MemoryEntry, score: Double)] = []
        for e in candidates {
            guard let ev = vectors[e.id] else { continue }
            let sim = cosineSimilarity(qv, ev)
            scored.append((e, sim))
        }
        return scored.sorted { $0.score > $1.score }
    }

    // MARK: Cosine similarity (dot product on L2-normalized vectors)

    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        return zip(a, b).map { $0 * $1 }.reduce(0, +)
    }

    // Non-static internal accessor for tests
    func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        Self.cosineSimilarity(a, b)
    }
}

// MARK: - Reciprocal Rank Fusion

/// Fuses two rank-ordered lists (FTS + dense) into a single combined score list
/// using Reciprocal Rank Fusion.
///
/// Formula: RRF_score(d) = Σ_i 1/(k + rank_i(d))
/// where rank_i is 1-based. Standard k=60.
///
/// Both input lists are `[(entry, score)]` already sorted descending by their
/// respective scores. The fused output is sorted descending by combined RRF score.
///
/// Entries appearing in ONLY ONE list still get a contribution from that list;
/// entries appearing in BOTH lists get contributions from both (hybrid boost).
public enum ReciprocaLRankFusion {
    /// k parameter (default 60, per the original RRF paper).
    public static let kDefault: Double = 60.0

    public static func fuse(
        ftsList: [(entry: MemoryEntry, rank: Double)],  // already sorted descending by score
        denseList: [(entry: MemoryEntry, score: Double)], // already sorted descending by cosine
        k: Double = kDefault
    ) -> [(entry: MemoryEntry, rrfScore: Double)] {
        var scores: [String: Double] = [:]   // id → combined RRF score
        var byId: [String: MemoryEntry] = [:]

        // FTS contributions (rank = 1, 2, 3, … in sorted order)
        for (rank0, item) in ftsList.enumerated() {
            let r = Double(rank0 + 1)
            scores[item.entry.id, default: 0.0] += 1.0 / (k + r)
            byId[item.entry.id] = item.entry
        }

        // Dense contributions
        for (rank0, item) in denseList.enumerated() {
            let r = Double(rank0 + 1)
            scores[item.entry.id, default: 0.0] += 1.0 / (k + r)
            byId[item.entry.id] = item.entry
        }

        return scores
            .sorted { $0.value > $1.value }
            .compactMap { kv in
                guard let entry = byId[kv.key] else { return nil }
                return (entry, kv.value)
            }
    }

    /// Overload accepting both lists with the same `rank: Double` label.
    /// Convenience for callers that have already converted dense scores to the same tuple shape.
    public static func fuse(
        ftsList: [(entry: MemoryEntry, rank: Double)],
        denseListRanked: [(entry: MemoryEntry, rank: Double)],
        k: Double = kDefault
    ) -> [(entry: MemoryEntry, rrfScore: Double)] {
        let denseConverted = denseListRanked.map { (entry: $0.entry, score: $0.rank) }
        return fuse(ftsList: ftsList, denseList: denseConverted, k: k)
    }
}
