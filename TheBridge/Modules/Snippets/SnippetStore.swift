// SnippetStore.swift — WS-D (v2.3, PKT-2135a9e9)
// TheBridge · Modules · Snippets
//
// Portable on-disk snippet store backing the snippets/ MCP module. Replaces
// the Wispr Flow snippets feature for personal use, no remote-MCP/OAuth dep.
//
// Persistence: single JSON document, schema-versioned, written with
// Data.write(options: .atomic) — temp-write + atomic rename under the hood,
// so a kill -9 mid-write cannot leave a torn file (packet DoD: crash-safe /
// atomic-rename). No SQLite/GRDB dependency added (Package.swift has none;
// the packet explicitly permits "SQLite OR JSON-lines, atomic-rename").
//
// Concurrency: `actor` — all mutation is serialized, so concurrent
// snippets_create calls cannot corrupt the store (packet QA).

import Foundation

// MARK: - Model

public struct Snippet: Codable, Sendable, Equatable {
    public let id: String          // uuid4
    public var name: String        // unique trigger
    public var text: String
    public var tags: [String]
    public let created: Date
    public var updated: Date
    public var source: String      // "manual" | "wispr" | "espanso" | "json"

    public init(
        id: String = UUID().uuidString,
        name: String,
        text: String,
        tags: [String] = [],
        created: Date = Date(),
        updated: Date = Date(),
        source: String = "manual"
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.tags = tags
        self.created = created
        self.updated = updated
        self.source = source
    }
}

public struct SnippetImportResult: Sendable, Equatable {
    public let imported: Int
    public let skipped: Int
    public let errors: [String]
}

public enum SnippetStoreError: Error, Equatable, Sendable {
    case duplicateName(String)
    case notFound(String)
    case invalidImport(String)
    case unsupportedFormat(String)
}

// MARK: - Store

public actor SnippetStore {

    public static let shared = SnippetStore()

    private struct Document: Codable {
        var schemaVersion: Int
        var snippets: [Snippet]
    }

    private static let currentSchemaVersion = 1
    private let storeURL: URL
    private var doc: Document

    public init(storeURL: URL = SnippetStore.defaultStoreURL()) {
        self.storeURL = storeURL
        self.doc = SnippetStore.loadOrRecover(url: storeURL)
    }

    public nonisolated static func defaultStoreURL() -> URL {
        // PKT-1 v3.5: route through BridgePaths so the rename migration is
        // consistent and the store lands at ~/Library/Application Support/
        // The Bridge/snippets/store.json.
        BridgePaths.applicationSupport(.snippets).appendingPathComponent("store.json", isDirectory: false)
    }

    public nonisolated static func defaultEspansoURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/espanso/match/bridge-snippets.yml", isDirectory: false)
    }

    // MARK: Load / persist

    private nonisolated static func loadOrRecover(url: URL) -> Document {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return Document(schemaVersion: currentSchemaVersion, snippets: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let d = try? decoder.decode(Document.self, from: data) {
            return d
        }
        // Corrupt file — preserve it for forensics, start fresh rather than throw.
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return Document(schemaVersion: currentSchemaVersion, snippets: [])
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

    public func all() -> [Snippet] { doc.snippets }

    public func get(idOrName: String) -> Snippet? {
        doc.snippets.first { $0.id == idOrName || $0.name == idOrName }
    }

    /// Ranked search: exact-name (3) > name-prefix (2) > name-subsequence/contains (1)
    /// > text-contains (0.5). `tags` (if non-empty) AND-filters before scoring.
    public func search(query: String, tags: [String] = []) -> [Snippet] {
        let q = query.lowercased()
        let pool = tags.isEmpty
            ? doc.snippets
            : doc.snippets.filter { s in tags.allSatisfy { t in s.tags.contains(t) } }
        func score(_ s: Snippet) -> Double {
            let n = s.name.lowercased()
            if q.isEmpty { return 0.25 }
            if n == q { return 3 }
            if n.hasPrefix(q) { return 2 }
            if n.contains(q) || Self.isSubsequence(q, of: n) { return 1 }
            // Separator-style abbreviation: name's alphanumerics as a
            // subsequence of the query (e.g. "d-e-p" matches "deploy").
            let nAlnum = String(n.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if !nAlnum.isEmpty, Self.isSubsequence(nAlnum, of: q) { return 1 }
            if s.text.lowercased().contains(q) { return 0.5 }
            return 0
        }
        struct Scored { let snippet: Snippet; let score: Double }
        var scored: [Scored] = []
        for s in pool {
            let v = score(s)
            if v > 0 { scored.append(Scored(snippet: s, score: v)) }
        }
        scored.sort { (a: Scored, b: Scored) -> Bool in
            if a.score != b.score { return a.score > b.score }
            return a.snippet.name.localizedCaseInsensitiveCompare(b.snippet.name) == .orderedAscending
        }
        return scored.map { $0.snippet }
    }

    private nonisolated static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() { if h == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    // MARK: Write

    @discardableResult
    public func create(name: String, text: String, tags: [String] = [], source: String = "manual") throws -> Snippet {
        if doc.snippets.contains(where: { $0.name == name }) {
            throw SnippetStoreError.duplicateName(name)
        }
        let s = Snippet(name: name, text: text, tags: tags, source: source)
        doc.snippets.append(s)
        try persist()
        return s
    }

    @discardableResult
    public func update(id: String, name: String? = nil, text: String? = nil, tags: [String]? = nil) throws -> Snippet {
        guard let idx = doc.snippets.firstIndex(where: { $0.id == id }) else {
            throw SnippetStoreError.notFound(id)
        }
        if let name, name != doc.snippets[idx].name,
           doc.snippets.contains(where: { $0.name == name && $0.id != id }) {
            throw SnippetStoreError.duplicateName(name)
        }
        if let name { doc.snippets[idx].name = name }
        if let text { doc.snippets[idx].text = text }
        if let tags { doc.snippets[idx].tags = tags }
        doc.snippets[idx].updated = Date()
        try persist()
        return doc.snippets[idx]
    }

    @discardableResult
    public func rename(id: String, name: String) throws -> Snippet {
        try update(id: id, name: name)
    }

    public func delete(id: String) throws {
        guard let idx = doc.snippets.firstIndex(where: { $0.id == id }) else {
            throw SnippetStoreError.notFound(id)
        }
        doc.snippets.remove(at: idx)
        try persist()
    }

    // MARK: Import

    /// `wispr` / `json`: array of `{name,text,tags?}`. `espanso`: matches: list.
    /// Idempotent on `name` — existing names are skipped + counted, never overwritten.
    @discardableResult
    public func importSnippets(format: String, data: String) throws -> SnippetImportResult {
        let incoming: [(name: String, text: String, tags: [String])]
        switch format.lowercased() {
        case "wispr", "json":
            incoming = try Self.parseJSONImport(data)
        case "espanso":
            incoming = try Self.parseEspansoImport(data)
        default:
            throw SnippetStoreError.unsupportedFormat(format)
        }
        var imported = 0, skipped = 0
        var errors: [String] = []
        for item in incoming {
            if item.name.isEmpty { errors.append("empty name skipped"); continue }
            if doc.snippets.contains(where: { $0.name == item.name }) { skipped += 1; continue }
            doc.snippets.append(Snippet(name: item.name, text: item.text, tags: item.tags, source: format.lowercased()))
            imported += 1
        }
        if imported > 0 { try persist() }
        return SnippetImportResult(imported: imported, skipped: skipped, errors: errors)
    }

    private nonisolated static func parseJSONImport(_ data: String) throws -> [(name: String, text: String, tags: [String])] {
        guard let raw = data.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
            throw SnippetStoreError.invalidImport("expected JSON array of {name,text,tags?}")
        }
        return arr.compactMap { obj in
            guard let name = obj["name"] as? String else { return nil }
            let text = obj["text"] as? String ?? ""
            let tags = obj["tags"] as? [String] ?? []
            return (name, text, tags)
        }
    }

    private nonisolated static func parseEspansoImport(_ yaml: String) throws -> [(name: String, text: String, tags: [String])] {
        // Minimal espanso `matches:` reader — trigger/replace pairs only.
        var out: [(String, String, [String])] = []
        var trigger: String?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = Self.yamlValue(t, key: "trigger") { trigger = r }
            if let r = Self.yamlValue(t, key: "replace"), let trg = trigger {
                out.append((trg, r, [])); trigger = nil
            }
        }
        if out.isEmpty { throw SnippetStoreError.invalidImport("no espanso trigger/replace pairs found") }
        return out.map { ($0.0, $0.1, $0.2) }
    }

    private nonisolated static func yamlValue(_ line: String, key: String) -> String? {
        let prefixes = ["- \(key):", "\(key):"]
        for p in prefixes where line.hasPrefix(p) {
            var v = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
                v = v.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            }
            return v
        }
        return nil
    }

    // MARK: Export

    public func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(doc)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Emits espanso-schema YAML (double-quoted scalars; espanso accepts the
    /// JSON-subset quoting). Writes to the espanso match dir and returns the path.
    @discardableResult
    public func exportEspanso(to url: URL? = nil) throws -> String {
        let target = url ?? Self.defaultEspansoURL()
        var lines = ["matches:"]
        for s in doc.snippets.sorted(by: { $0.name < $1.name }) {
            lines.append("  - trigger: \(Self.yamlQuote(s.name))")
            lines.append("    replace: \(Self.yamlQuote(s.text))")
        }
        let yaml = lines.joined(separator: "\n") + "\n"
        let dir = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(yaml.utf8).write(to: target, options: [.atomic])
        return target.path
    }

    nonisolated static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: Test support

    public func reloadFromDisk() {
        doc = Self.loadOrRecover(url: storeURL)
    }
}
