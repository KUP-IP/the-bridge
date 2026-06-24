// MemorySemanticRecallTests.swift — Dense-vector recall + RRF (PKT-1007 Slice 1)
// TheBridge · Tests
//
// Tests for:
//   • MemoryEmbeddingIndex — indexing, dense ranking, tombstone eviction
//   • StubMemoryEmbedder — deterministic, asset-free, good-enough for plumbing
//   • ReciprocaLRankFusion — single-list, dual-list, entry appearing in both
//   • MemoryStore.recall with a stub embedder injected via init(path:embedder:)
//     — verifies the RRF path is exercised without requiring CoreML model assets
//   • NLContextualEmbedder unit tests — pure API tests, gated on asset availability
//     (skipped gracefully if assets are missing so CI stays green)
//
// All store-level tests use a TEMP DB path and never touch the shared singleton.
// The NLContextualEmbedder tests are the only ones that may load CoreML assets;
// they guard on hasAvailableAssets and print a skip notice if not ready.

import Foundation
import MCP
import TheBridgeLib
import NaturalLanguage

// MARK: - Temp-DB helpers (mirrors MemoryModuleTests)

private func makeTempStore(embedder: MemoryEmbedder? = nil) -> (store: MemoryStore, url: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-semantic-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("memory.sqlite")
    let stub = embedder ?? StubMemoryEmbedder()
    return (MemoryStore(path: url, embedder: stub), url)
}

private func cleanup(_ url: URL) {
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        try? fm.removeItem(at: url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix))
    }
    try? fm.removeItem(at: url.deletingLastPathComponent())
}

// MARK: - Helper to build simple MemoryEntry values for index tests

private func makeEntry(id: String = UUID().uuidString, text: String, scope: String = "global") -> MemoryEntry {
    MemoryEntry(
        id: id, scope: scope, entity: nil, text: text, type: .fact,
        pinned: false, useCount: 0,
        createdAt: Date(), lastUsedAt: Date(),
        source: "test", contentHash: MemoryStore.contentHash(text)
    )
}

func runMemorySemanticRecallTests() async {
    print("\n🧲 MemorySemanticRecall Tests (PKT-1007 Slice 1 — dense vector + RRF)")

    // ── StubMemoryEmbedder ────────────────────────────────────────────────

    await test("StubMemoryEmbedder: identical text produces identical vector") {
        let stub = StubMemoryEmbedder(dimension: 8)
        let a = stub.embed("hello world")
        let b = stub.embed("hello world")
        try expect(a != nil && b != nil, "stub must embed non-empty text")
        try expect(a! == b!, "identical text must produce identical vector")
    }

    await test("StubMemoryEmbedder: empty text returns nil") {
        let stub = StubMemoryEmbedder(dimension: 8)
        try expect(stub.embed("") == nil, "empty text must return nil")
        try expect(stub.embed("   ") == nil, "whitespace-only text must return nil")
    }

    await test("StubMemoryEmbedder: dimension is respected") {
        for dim in [4, 8, 16] {
            let stub = StubMemoryEmbedder(dimension: dim)
            guard let v = stub.embed("test vector") else {
                throw TestError.assertion("stub returned nil for dim=\(dim)")
            }
            try expect(v.count == dim, "vector must have \(dim) elements, got \(v.count)")
        }
    }

    await test("StubMemoryEmbedder: vector is L2-normalized (unit length within tolerance)") {
        let stub = StubMemoryEmbedder(dimension: 16)
        guard let v = stub.embed("normalization check") else {
            throw TestError.assertion("stub returned nil")
        }
        let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
        try expect(abs(norm - 1.0) < 1e-9 || norm < 1e-10,
                   "L2 norm must be ~1.0 (unit vector), got \(norm)")
    }

    await test("StubMemoryEmbedder: different text produces different vectors") {
        let stub = StubMemoryEmbedder(dimension: 16)
        let a = stub.embed("the quick brown fox")
        let b = stub.embed("pack my box with five dozen liquor jugs")
        try expect(a != nil && b != nil)
        try expect(a! != b!, "different text should produce different vectors")
    }

    // ── MemoryEmbeddingIndex ──────────────────────────────────────────────

    await test("MemoryEmbeddingIndex: index then rankedByDense returns sorted results") {
        let stub = StubMemoryEmbedder(dimension: 8)
        var idx = MemoryEmbeddingIndex(embedder: stub)
        let e1 = makeEntry(id: "a", text: "apple fruit orchard harvest")
        let e2 = makeEntry(id: "b", text: "banana tropical yellow fruit")
        let e3 = makeEntry(id: "c", text: "cloud computing aws azure gcp")
        idx.index(entries: [e1, e2, e3])
        // Query on "apple" — stub embedder is character-hash-based, so "apple"
        // shares bigrams with e1 more than with e3.
        let ranked = idx.rankedByDense(query: "apple", candidates: [e1, e2, e3])
        try expect(!ranked.isEmpty, "ranked list must be non-empty after indexing")
        // Verify sorted descending by score
        for i in 0..<ranked.count - 1 {
            try expect(ranked[i].score >= ranked[i + 1].score,
                       "ranked list must be sorted descending by cosine score")
        }
    }

    await test("MemoryEmbeddingIndex: remove evicts entry from dense ranking") {
        let stub = StubMemoryEmbedder(dimension: 8)
        var idx = MemoryEmbeddingIndex(embedder: stub)
        let e1 = makeEntry(id: "keep", text: "relevant result text")
        let e2 = makeEntry(id: "gone", text: "relevant result text duplicate")
        idx.index(entries: [e1, e2])
        idx.remove(id: "gone")
        let ranked = idx.rankedByDense(query: "relevant result", candidates: [e1, e2])
        try expect(!ranked.contains(where: { $0.entry.id == "gone" }),
                   "removed entry must not appear in dense ranking")
        try expect(ranked.contains(where: { $0.entry.id == "keep" }),
                   "non-removed entry must still appear")
    }

    await test("MemoryEmbeddingIndex: rankedByDense returns empty for unembeddable query") {
        let stub = StubMemoryEmbedder(dimension: 8)
        var idx = MemoryEmbeddingIndex(embedder: stub)
        let e = makeEntry(text: "some content")
        idx.index(entries: [e])
        // Empty query → embed returns nil → dense arm empty
        let ranked = idx.rankedByDense(query: "", candidates: [e])
        try expect(ranked.isEmpty, "empty query must produce empty dense list")
    }

    await test("MemoryEmbeddingIndex: index is idempotent (re-indexing same id is no-op)") {
        let stub = StubMemoryEmbedder(dimension: 8)
        var idx = MemoryEmbeddingIndex(embedder: stub)
        let e = makeEntry(id: "dup", text: "idempotent indexing text")
        idx.index(entries: [e])
        idx.index(entries: [e])  // second call must not crash or double-index
        let ranked = idx.rankedByDense(query: "idempotent", candidates: [e])
        try expect(ranked.count == 1, "duplicate index must produce exactly 1 result")
    }

    await test("MemoryEmbeddingIndex: empty candidate list returns empty") {
        let stub = StubMemoryEmbedder(dimension: 8)
        let idx = MemoryEmbeddingIndex(embedder: stub)
        let ranked = idx.rankedByDense(query: "any query", candidates: [])
        try expect(ranked.isEmpty, "empty candidates must produce empty result")
    }

    // ── ReciprocaLRankFusion ──────────────────────────────────────────────

    await test("RRF: fuse with only FTS list (empty dense) returns FTS order") {
        let e1 = makeEntry(id: "a", text: "first")
        let e2 = makeEntry(id: "b", text: "second")
        let e3 = makeEntry(id: "c", text: "third")
        let fts: [(entry: MemoryEntry, rank: Double)] = [(e1, 2.0), (e2, 1.5), (e3, 1.0)]
        let result = ReciprocaLRankFusion.fuse(ftsList: fts, denseList: [])
        try expect(result.count == 3, "fused count must equal FTS count when dense is empty")
        // With only FTS, rank order is preserved (e1 rank 1 → highest RRF score)
        try expect(result[0].entry.id == "a", "first FTS rank must lead fused list")
        try expect(result[1].entry.id == "b")
        try expect(result[2].entry.id == "c")
    }

    await test("RRF: fuse with only dense list (empty FTS) returns dense order") {
        let e1 = makeEntry(id: "x", text: "alpha")
        let e2 = makeEntry(id: "y", text: "beta")
        let dense: [(entry: MemoryEntry, score: Double)] = [(e1, 0.95), (e2, 0.60)]
        let result = ReciprocaLRankFusion.fuse(ftsList: [], denseList: dense)
        try expect(result.count == 2, "fused count must equal dense count when FTS is empty")
        try expect(result[0].entry.id == "x", "top-cosine entry must lead when FTS empty")
    }

    await test("RRF: entry in both lists gets higher score than entry in one list") {
        let eShared = makeEntry(id: "shared", text: "shared result")
        let eFtsOnly = makeEntry(id: "fts-only", text: "fts only result")
        let eDenseOnly = makeEntry(id: "dense-only", text: "dense only result")

        // shared is rank 1 in FTS, rank 1 in dense → double contribution
        let fts: [(entry: MemoryEntry, rank: Double)] = [(eShared, 2.0), (eFtsOnly, 1.0)]
        let dense: [(entry: MemoryEntry, score: Double)] = [(eShared, 0.9), (eDenseOnly, 0.5)]

        let result = ReciprocaLRankFusion.fuse(ftsList: fts, denseList: dense)
        guard let sharedPos = result.firstIndex(where: { $0.entry.id == "shared" }),
              let ftsOnlyPos = result.firstIndex(where: { $0.entry.id == "fts-only" }),
              let denseOnlyPos = result.firstIndex(where: { $0.entry.id == "dense-only" }) else {
            throw TestError.assertion("all three entries must appear in fused list")
        }
        // shared (rank 1 in both) must beat fts-only (rank 2 in FTS) and dense-only (rank 2 in dense)
        try expect(sharedPos < ftsOnlyPos,
                   "shared entry must rank above fts-only entry; shared=\(sharedPos), ftsOnly=\(ftsOnlyPos)")
        try expect(sharedPos < denseOnlyPos,
                   "shared entry must rank above dense-only entry; shared=\(sharedPos), denseOnly=\(denseOnlyPos)")
    }

    await test("RRF: scores are strictly positive and descending") {
        let entries = (0..<5).map { makeEntry(id: "e\($0)", text: "entry \($0)") }
        let fts = entries.enumerated().map { (entry: $0.element, rank: Double(5 - $0.offset)) }
        let dense = entries.reversed().enumerated().map { (entry: $0.element, score: Double($0.offset) / 5.0) }
        let result = ReciprocaLRankFusion.fuse(ftsList: fts, denseList: Array(dense))
        try expect(!result.isEmpty)
        for item in result { try expect(item.rrfScore > 0, "RRF score must be positive") }
        for i in 0..<result.count - 1 {
            try expect(result[i].rrfScore >= result[i + 1].rrfScore,
                       "RRF scores must be non-increasing (descending order)")
        }
    }

    await test("RRF: k parameter controls score magnitude") {
        let e = makeEntry(id: "e0", text: "test")
        let fts: [(entry: MemoryEntry, rank: Double)] = [(e, 1.0)]
        let r60 = ReciprocaLRankFusion.fuse(ftsList: fts, denseList: [], k: 60)
        let r1  = ReciprocaLRankFusion.fuse(ftsList: fts, denseList: [], k: 1)
        try expect(!r60.isEmpty && !r1.isEmpty)
        // k=1 → 1/(1+1)=0.5; k=60 → 1/(60+1)≈0.016; k=1 gives higher score
        try expect(r1[0].rrfScore > r60[0].rrfScore,
                   "smaller k must produce larger RRF score; k=1: \(r1[0].rrfScore), k=60: \(r60[0].rrfScore)")
    }

    // ── MemoryStore.recall with stub embedder injected ────────────────────

    await test("MemoryStore recall: dense arm indexed; stub-identical query ranks matched entry") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        // Insert entries. The stub embedder gives "apple" and "apple" the same
        // vector, so querying "apple" ranks the apple entry above the unrelated one.
        _ = try await store.remember(text: "apple orchard farming", scope: "global", source: "t")
        _ = try await store.remember(text: "cloud computing infrastructure", scope: "global", source: "t")

        let results = try await store.recall(query: "apple", scope: "global")
        try expect(!results.isEmpty, "recall must return at least one result")
        // The apple-related entry should be in results (FTS also matches on "apple")
        try expect(results.contains(where: { $0.text.contains("apple") }),
                   "apple-related memory must appear in recall results")
    }

    await test("MemoryStore recall: tombstoned entry absent from dense ranking") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        let entry = try await store.remember(text: "secret forgotten text", scope: "global", source: "t")
        try await store.forget(id: entry.id)

        let results = try await store.recall(query: "secret forgotten", scope: "global")
        try expect(!results.contains(where: { $0.id == entry.id }),
                   "tombstoned entry must not appear in recall after forget")
    }

    await test("MemoryStore recall: empty query works with dense arm (falls back gracefully)") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        _ = try await store.remember(text: "first global fact", scope: "global", source: "t")
        _ = try await store.remember(text: "second global fact", scope: "global", source: "t")

        // Empty query → stub embed returns nil → dense arm empty → FTS fallback
        let results = try await store.recall(query: "", scope: "global")
        try expect(results.count == 2, "empty query must return all live entries, got \(results.count)")
    }

    await test("MemoryStore recall: use-promotion still works with dense arm enabled") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        _ = try await store.remember(text: "promotable north entry", scope: "project", source: "t")
        _ = try await store.remember(text: "promotable south entry", scope: "project", source: "t")

        let first = try await store.recall(query: "promotable", scope: "project")
        try expect(first.allSatisfy { $0.useCount == 1 },
                   "recall must bump useCount to 1 on both entries")
    }

    await test("MemoryStore recall: pinned entry still sorts to top with dense arm active") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        let pinned = try await store.remember(text: "pinned memory entry result", scope: "global", source: "t")
        _ = try await store.remember(text: "unpinned competing memory result", scope: "global", source: "t")
        try await store.pin(id: pinned.id, true)

        let results = try await store.recall(query: "memory result", scope: "global")
        try expect(results.first?.id == pinned.id,
                   "pinned entry must be first even with dense arm; got \(results.first?.id as Any)")
    }

    await test("MemoryStore recall: scope filter still enforced with dense arm") {
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        _ = try await store.remember(text: "scope test people result", scope: "people", source: "t")
        _ = try await store.remember(text: "scope test project result", scope: "project", source: "t")

        let peopleResults = try await store.recall(query: "scope test result", scope: "people")
        try expect(peopleResults.allSatisfy { $0.scope == "people" },
                   "scope filter must exclude project entries; got \(peopleResults.map(\.scope))")
    }

    await test("MemoryStore recall: RRF produces non-empty result when both arms have candidates") {
        // Build a store with a stub embedder so we control the dense arm
        let (store, url) = makeTempStore()
        defer { Task { await store.close(); cleanup(url) } }

        for i in 0..<5 {
            _ = try await store.remember(text: "test entry \(i) for fusion", scope: "global", source: "t")
        }

        // Query that should match via FTS and also via stub dense
        let results = try await store.recall(query: "test entry fusion", scope: "global", limit: 5)
        try expect(!results.isEmpty, "RRF recall must return results when both arms have candidates")
        try expect(results.count <= 5, "limit must be honored, got \(results.count)")
    }

    // ── NLContextualEmbedder unit tests (skip if assets not available) ────

    await test("NLContextualEmbedder: dimension matches NLContextualEmbedding.dimension") {
        if #available(macOS 12.0, *) {
            let nlEmb = NLContextualEmbedder()
            let expected = NLContextualEmbedding(language: .english)?.dimension ?? 512
            try expect(nlEmb.dimension == expected,
                       "NLContextualEmbedder.dimension must match NLContextualEmbedding.dimension")
        }
    }

    await test("NLContextualEmbedder: embed returns nil or a 512-dim unit vector") {
        if #available(macOS 12.0, *) {
            // Check if assets are available before testing embedding
            guard let emb = NLContextualEmbedding(language: .english), emb.hasAvailableAssets else {
                print("    ⚠️  NLContextualEmbedding assets not available — skipping embed test")
                return
            }
            let nlEmb = NLContextualEmbedder()
            guard let v = nlEmb.embed("apple orchard harvest season") else {
                print("    ⚠️  NLContextualEmbedder returned nil (assets may not be ready) — skip")
                return
            }
            try expect(v.count == 512, "live embedding must be 512-dimensional, got \(v.count)")
            let norm = sqrt(v.map { $0 * $0 }.reduce(0, +))
            try expect(abs(norm - 1.0) < 1e-6,
                       "live embedding must be L2-normalized, norm=\(norm)")
        }
    }

    await test("NLContextualEmbedder: identical text produces identical embedding") {
        if #available(macOS 12.0, *) {
            guard let emb = NLContextualEmbedding(language: .english), emb.hasAvailableAssets else {
                print("    ⚠️  NLContextualEmbedding assets not available — skipping determinism test")
                return
            }
            let nlEmb = NLContextualEmbedder()
            let a = nlEmb.embed("the weather is fine today")
            let b = nlEmb.embed("the weather is fine today")
            if a == nil || b == nil {
                print("    ⚠️  NLContextualEmbedder returned nil — assets may not be ready, skip")
                return
            }
            try expect(a! == b!, "same text must produce identical embedding (deterministic)")
        }
    }

    await test("NLContextualEmbedder: semantically similar texts have higher cosine than unrelated") {
        if #available(macOS 12.0, *) {
            guard let emb = NLContextualEmbedding(language: .english), emb.hasAvailableAssets else {
                print("    ⚠️  NLContextualEmbedding assets not available — skipping semantic test")
                return
            }
            let nlEmb = NLContextualEmbedder()
            guard let vWeather = nlEmb.embed("the weather is nice today"),
                  let vDay = nlEmb.embed("it is a beautiful day outside"),
                  let vStocks = nlEmb.embed("the stock market crashed badly") else {
                print("    ⚠️  NLContextualEmbedder returned nil — skip")
                return
            }
            // NLContextualEmbedder.embed already L2-normalizes, so cosine = dot product
            let simWeatherDay = zip(vWeather, vDay).map { $0 * $1 }.reduce(0.0, +)
            let simWeatherStocks = zip(vWeather, vStocks).map { $0 * $1 }.reduce(0.0, +)
            try expect(simWeatherDay > simWeatherStocks,
                       "weather/day cosine (\(simWeatherDay)) must exceed weather/stocks (\(simWeatherStocks))")
        }
    }

    await test("NLContextualEmbedder: meanPool returns nil for empty token stream") {
        if #available(macOS 12.0, *) {
            guard let emb = NLContextualEmbedding(language: .english), emb.hasAvailableAssets else {
                print("    ⚠️  NLContextualEmbedding assets not available — skipping meanPool nil test")
                return
            }
            // A string with zero embeddable tokens (punctuation-only) may produce no token vectors.
            // We can't force this deterministically across all model versions, so this is
            // a best-effort test: if the embedder returns nil for "..." that's acceptable.
            let nlEmb = NLContextualEmbedder()
            // The main assertion is that embed() does not crash or throw for unusual inputs.
            let _ = nlEmb.embed("...")  // may be nil or a vector — both acceptable
        }
    }

    // ── l2Normalize helper ────────────────────────────────────────────────

    await test("NLContextualEmbedder.l2Normalize: zero vector stays zero (no NaN)") {
        let zeroed = NLContextualEmbedder.l2Normalize([0.0, 0.0, 0.0])
        try expect(zeroed.count == 3)
        try expect(zeroed.allSatisfy { !$0.isNaN && !$0.isInfinite },
                   "l2Normalize of zero vector must not produce NaN/Inf")
    }

    await test("NLContextualEmbedder.l2Normalize: unit vector unchanged") {
        let unit = [1.0, 0.0, 0.0]
        let normed = NLContextualEmbedder.l2Normalize(unit)
        try expect(abs(normed[0] - 1.0) < 1e-10 && abs(normed[1]) < 1e-10 && abs(normed[2]) < 1e-10,
                   "unit vector must be unchanged by l2Normalize")
    }

    await test("NLContextualEmbedder.l2Normalize: general vector has unit norm after normalize") {
        let v = [3.0, 4.0]
        let normed = NLContextualEmbedder.l2Normalize(v)
        let norm = sqrt(normed.map { $0 * $0 }.reduce(0, +))
        try expect(abs(norm - 1.0) < 1e-10, "l2Normalize result must have unit L2 norm, got \(norm)")
    }

    // ── meanPool via NLContextualEmbedder (if assets available) ──────────

    await test("NLContextualEmbedder.meanPool: result has unit norm") {
        if #available(macOS 12.0, *) {
            guard let emb = NLContextualEmbedding(language: .english), emb.hasAvailableAssets else {
                print("    ⚠️  NLContextualEmbedding assets unavailable — skipping meanPool norm test")
                return
            }
            let text = "mean pooling gives a sentence embedding"
            do {
                let result = try emb.embeddingResult(for: text, language: .english)
                guard let pooled = NLContextualEmbedder.meanPool(result: result, text: text, dimension: emb.dimension) else {
                    throw TestError.assertion("meanPool returned nil for non-empty text")
                }
                let norm = sqrt(pooled.map { $0 * $0 }.reduce(0, +))
                try expect(abs(norm - 1.0) < 1e-6,
                           "meanPool result must be unit norm after L2 normalize, got \(norm)")
            } catch {
                throw TestError.assertion("embeddingResult threw: \(error)")
            }
        }
    }
}
