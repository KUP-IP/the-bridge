// SkillFileCatalog.swift — #254 Notion Files & media catalog + local materialize
// TheBridge · Modules · Skills
//
// KEEP OS skills attach binaries on the SKILLS `Files & media` property.
// Notion is a catalog + mirror, NEVER the binary SSOT. This type:
//   • parses the Notion files wire-shape into a fetch_skill `files` catalog
//   • extracts an optional `assetRoot` Mac folder from skill prose
//   • copies a Notion-hosted file into `skill-files/<uuid>/` for file_read
//
// File-source SKILL.md skills (`buildFileSkillResult`) are a different path
// and are intentionally not handled here.

import CryptoKit
import Foundation
import MCP

/// One skill attachment the agent can materialize and `file_read`.
public struct SkillFileEntry: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var notionFileId: String?
    public var localPath: String?
    public var sha256: String?
    public var role: String?
    /// Ephemeral Notion/S3 URL used only by the materialize download. Never
    /// serialized into the fetch_skill envelope (URLs expire).
    public var downloadURL: String?

    public init(
        name: String,
        kind: String,
        notionFileId: String? = nil,
        localPath: String? = nil,
        sha256: String? = nil,
        role: String? = nil,
        downloadURL: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.notionFileId = notionFileId
        self.localPath = localPath
        self.sha256 = sha256
        self.role = role
        self.downloadURL = downloadURL
    }

    /// Envelope object: required `name` + `kind`; optionals omitted when nil.
    public var envelopeValue: Value {
        var obj: [String: Value] = [
            "name": .string(name),
            "kind": .string(kind)
        ]
        if let notionFileId, !notionFileId.isEmpty {
            obj["notionFileId"] = .string(notionFileId)
        }
        if let localPath, !localPath.isEmpty {
            obj["localPath"] = .string(localPath)
        }
        if let sha256, !sha256.isEmpty {
            obj["sha256"] = .string(sha256)
        }
        if let role, !role.isEmpty {
            obj["role"] = .string(role)
        }
        return .object(obj)
    }
}

public struct SkillFileCatalogResult: Equatable, Sendable {
    public var files: [SkillFileEntry]
    /// True when a Files & media / Google Drive File property exists on the
    /// page (even if the array is empty). Empty catalog + present property
    /// must still emit `files: []`; omit is not honest.
    public var propertyPresent: Bool

    public init(files: [SkillFileEntry] = [], propertyPresent: Bool = false) {
        self.files = files
        self.propertyPresent = propertyPresent
    }
}

public enum SkillFileMaterializeError: Error, LocalizedError, Equatable {
    case invalidFileName(String)
    case missingDownloadURL
    case notHTTPS(String)
    case tooLarge(Int)
    case emptyDownload
    case fileNotOnSkill(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName(let name):
            return "Refusing to materialize an unsafe file name: \(name)"
        case .missingDownloadURL:
            return "That skill file has no downloadable Notion-hosted URL (external / Drive links are not binary SSOT)."
        case .notHTTPS(let url):
            return "Skill file download URL is not https: \(url)"
        case .tooLarge(let bytes):
            return "Skill file exceeds the \(SkillFileCatalog.maxBytes) byte materialize cap (\(bytes) bytes)."
        case .emptyDownload:
            return "Skill file download was empty."
        case .fileNotOnSkill(let needle):
            return "No Files & media entry named '\(needle)' on this skill."
        }
    }
}

/// Pure catalog + local-cache helper for Notion-backed skill files.
public enum SkillFileCatalog {
    public static let maxBytes = 50 * 1024 * 1024

    public static let filesPropertyNames: [String] = ["Files & media", "Files", "files"]
    public static let googleDrivePropertyNames: [String] = ["Google Drive File", "Google Drive"]

    public static var allFilePropertyNames: [String] {
        filesPropertyNames + googleDrivePropertyNames
    }

    // MARK: - Parse

    /// Parse the verbatim getPage `properties` blob. Captures Notion file ids
    /// and ephemeral download URLs for a subsequent materialize.
    public static func fromRawPageProperties(
        _ properties: [String: Any],
        skillUUID: String
    ) -> SkillFileCatalogResult {
        var files: [SkillFileEntry] = []
        var present = false
        for name in allFilePropertyNames {
            guard let prop = property(named: name, in: properties) else { continue }
            let type = (prop["type"] as? String) ?? ""
            let fromDriveColumn = googleDrivePropertyNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            if fromDriveColumn && (type == "url" || type == "rich_text") {
                present = true
                let label: String
                if type == "url" {
                    label = (prop["url"] as? String) ?? ""
                } else if let arr = prop["rich_text"] as? [[String: Any]] {
                    label = arr.compactMap { $0["plain_text"] as? String }.joined()
                } else {
                    label = ""
                }
                if !label.isEmpty {
                    files.append(SkillFileEntry(
                        name: label,
                        kind: "google_drive",
                        downloadURL: label.hasPrefix("http") ? label : nil
                    ))
                }
                continue
            }
            guard type == "files" || prop["files"] is [[String: Any]] else { continue }
            present = true
            let arr = (prop["files"] as? [[String: Any]]) ?? []
            for raw in arr {
                if let entry = entry(fromRawFile: raw, fromDriveColumn: fromDriveColumn, skillUUID: skillUUID) {
                    files.append(entry)
                }
            }
        }
        return SkillFileCatalogResult(files: files, propertyPresent: present)
    }

    /// Rebuild a catalog from the already-flattened envelope `properties`
    /// map (cache-hit path). Names only — Notion file ids are recovered on
    /// materialize via a fresh getPage.
    public static func fromFlattenedProperties(
        _ properties: Value,
        skillUUID: String
    ) -> SkillFileCatalogResult {
        guard case .object(let dict) = properties else {
            return SkillFileCatalogResult()
        }
        var files: [SkillFileEntry] = []
        var present = false
        for name in allFilePropertyNames {
            guard let value = dict.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else {
                continue
            }
            present = true
            let fromDriveColumn = googleDrivePropertyNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            let names: [String]
            switch value {
            case .array(let arr):
                names = arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            case .string(let s) where !s.isEmpty:
                names = [s]
            default:
                names = []
            }
            for fileName in names {
                var entry = SkillFileEntry(
                    name: fileName,
                    kind: fromDriveColumn ? "google_drive" : kindGuess(name: fileName, url: fileName)
                )
                if let cached = existingCache(skillUUID: skillUUID, fileName: fileName) {
                    entry.localPath = cached.path
                    entry.sha256 = cached.sha256
                }
                files.append(entry)
            }
        }
        return SkillFileCatalogResult(files: files, propertyPresent: present)
    }

    // MARK: - assetRoot

    /// First Mac folder named in skill prose (`~/Desktop/Brand Master`,
    /// `/Users/…/Desktop/…`). Agents should not scrape `/Users/…` themselves.
    public static func assetRoot(fromMarkdown markdown: String) -> String? {
        guard let start = firstPathStart(in: markdown) else { return nil }
        var tokens: [String] = []
        var current = ""
        for ch in markdown[start...] {
            if ch.isNewline || "`,;()[]{}<>\"'|".contains(ch) { break }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        guard let first = tokens.first else { return nil }
        var parts = [first]
        for token in tokens.dropFirst() {
            var cleaned = token
            while let last = cleaned.last, ".,:;!?".contains(last) {
                cleaned.removeLast()
            }
            guard !cleaned.isEmpty else { break }
            if isStopword(cleaned) { break }
            if let f = cleaned.first, f.isLowercase { break }
            parts.append(cleaned)
        }
        var path = parts.joined(separator: " ")
        while let last = path.last, ".,:;!?".contains(last) {
            path.removeLast()
        }
        guard isPlausibleFolderPath(path) else { return nil }
        return path
    }

    // MARK: - Materialize (local cache)

    public static func cacheDirectory(skillUUID: String) throws -> URL {
        let root = try BridgePaths.ensureApplicationSupport(.skillFiles)
        let uuid = CachedSkillBody.canonicalUUID(skillUUID)
        let dir = root.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func sanitizedFileName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !base.isEmpty, base != ".", base != ".." else { return nil }
        if base.contains("\0") { return nil }
        return base
    }

    public static func existingCache(skillUUID: String, fileName: String) -> (path: String, sha256: String)? {
        guard let safe = sanitizedFileName(fileName) else { return nil }
        let uuid = CachedSkillBody.canonicalUUID(skillUUID)
        let url = BridgePaths.applicationSupport(.skillFiles)
            .appendingPathComponent(uuid, isDirectory: true)
            .appendingPathComponent(safe, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        return (url.path, sha256Hex(data))
    }

    /// Write bytes into the per-skill cache. Public so tests materialize
    /// without Notion or the network.
    public static func materializeBytes(
        skillUUID: String,
        fileName: String,
        data: Data,
        kind: String = "notion_hosted",
        notionFileId: String? = nil,
        role: String? = nil
    ) throws -> SkillFileEntry {
        guard let safe = sanitizedFileName(fileName) else {
            throw SkillFileMaterializeError.invalidFileName(fileName)
        }
        guard !data.isEmpty else { throw SkillFileMaterializeError.emptyDownload }
        guard data.count <= maxBytes else { throw SkillFileMaterializeError.tooLarge(data.count) }
        let dir = try cacheDirectory(skillUUID: skillUUID)
        let dest = dir.appendingPathComponent(safe, isDirectory: false)
        try data.write(to: dest, options: [.atomic])
        return SkillFileEntry(
            name: safe,
            kind: kind,
            notionFileId: notionFileId,
            localPath: dest.path,
            sha256: sha256Hex(data),
            role: role
        )
    }

    public static func materialize(
        skillUUID: String,
        entry: SkillFileEntry,
        download: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> SkillFileEntry {
        guard let urlString = entry.downloadURL, !urlString.isEmpty else {
            throw SkillFileMaterializeError.missingDownloadURL
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw SkillFileMaterializeError.notHTTPS(urlString)
        }
        let data = try await download(url)
        return try materializeBytes(
            skillUUID: skillUUID,
            fileName: entry.name,
            data: data,
            kind: entry.kind,
            notionFileId: entry.notionFileId,
            role: entry.role
        )
    }

    public static func defaultDownload(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SkillFileMaterializeError.emptyDownload
        }
        return data
    }

    public static func findEntry(
        in catalog: SkillFileCatalogResult,
        fileName: String?,
        notionFileId: String?
    ) -> SkillFileEntry? {
        if let id = notionFileId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            if let hit = catalog.files.first(where: { $0.notionFileId == id }) { return hit }
        }
        if let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let lowered = name.lowercased()
            if let exact = catalog.files.first(where: { $0.name.lowercased() == lowered }) {
                return exact
            }
            let suffix = catalog.files.filter { $0.name.lowercased().contains(lowered) }
            if suffix.count == 1 { return suffix[0] }
        }
        return nil
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    private static func property(named name: String, in properties: [String: Any]) -> [String: Any]? {
        if let exact = properties[name] as? [String: Any] { return exact }
        for (key, raw) in properties where key.caseInsensitiveCompare(name) == .orderedSame {
            return raw as? [String: Any]
        }
        return nil
    }

    private static func entry(
        fromRawFile raw: [String: Any],
        fromDriveColumn: Bool,
        skillUUID: String
    ) -> SkillFileEntry? {
        let type = (raw["type"] as? String) ?? ""
        var url: String?
        if type == "external" || raw["external"] != nil,
           let ext = raw["external"] as? [String: Any] {
            url = ext["url"] as? String
        }
        if url == nil, let file = raw["file"] as? [String: Any] {
            url = file["url"] as? String
        }
        var name = (raw["name"] as? String) ?? ""
        if name.isEmpty, let url {
            name = URL(string: url)?.lastPathComponent ?? url
        }
        guard !name.isEmpty else { return nil }
        let fileId = (raw["id"] as? String)
            ?? (raw["file_id"] as? String)
            ?? ((raw["file"] as? [String: Any])?["id"] as? String)
        let kind: String
        if fromDriveColumn {
            kind = "google_drive"
        } else if type == "external" || raw["external"] != nil {
            kind = kindGuess(name: name, url: url ?? "")
        } else {
            kind = "notion_hosted"
        }
        var entry = SkillFileEntry(
            name: name,
            kind: kind,
            notionFileId: fileId,
            downloadURL: url
        )
        if let cached = existingCache(skillUUID: skillUUID, fileName: name) {
            entry.localPath = cached.path
            entry.sha256 = cached.sha256
        }
        return entry
    }

    private static func kindGuess(name: String, url: String) -> String {
        let hay = (name + " " + url).lowercased()
        if hay.contains("drive.google.com") || hay.contains("docs.google.com") {
            return "google_drive"
        }
        if hay.hasPrefix("http://") || hay.hasPrefix("https://") {
            return "external"
        }
        return "notion_hosted"
    }

    private static func firstPathStart(in body: String) -> String.Index? {
        if let r = body.range(of: "~/") { return r.lowerBound }
        if let r = body.range(of: "/Users/") { return r.lowerBound }
        return nil
    }

    private static func isStopword(_ word: String) -> Bool {
        let w = word.lowercased()
        let stop: Set<String> = [
            "until", "is", "are", "was", "were", "the", "a", "an", "which",
            "that", "this", "these", "those", "for", "with", "from", "and",
            "or", "to", "as", "on", "in", "of", "before", "after", "when",
            "where", "so", "but", "if", "then", "not", "never"
        ]
        return stop.contains(w)
    }

    private static func isPlausibleFolderPath(_ path: String) -> Bool {
        guard path.hasPrefix("~/") || path.hasPrefix("/Users/") else { return false }
        let last = URL(fileURLWithPath: path).lastPathComponent
        if last.contains("."), let ext = last.split(separator: ".").last, (2...4).contains(ext.count) {
            // Looks like a file (icon.png) rather than a folder.
            return false
        }
        return path.contains("/")
    }
}

extension SkillsModule {
    /// Copy a Notion-hosted skill attachment into the local skill-files
    /// cache. Notion remains a catalog, not binary SSOT.
    static func handleMaterializeSkillFile(_ arguments: Value) async throws -> Value {
        let args = unpackArgsObject(arguments)
        let rawIDArg: String? = {
            guard case .string(let raw) = args["id"] else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let idArg: String? = {
            guard let raw = rawIDArg, !raw.isEmpty else { return nil }
            let normalized = CachedSkillBody.normalize(raw)
            return CachedSkillBody.isNotionUUID(normalized) ? normalized : nil
        }()
        let nameArg: String? = {
            guard case .string(let raw) = args["name"] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        guard idArg != nil || nameArg != nil else {
            throw ToolRouterError.invalidArguments(
                toolName: "skill_materialize_file",
                reason: "one of 'id' (preferred UUID) or 'name' is required"
            )
        }
        if let rawIDArg, !rawIDArg.isEmpty, idArg == nil {
            throw ToolRouterError.invalidArguments(
                toolName: "skill_materialize_file",
                reason: "'id' must be a 32-hex Notion UUID (dashed or compact)"
            )
        }
        let fileName: String? = {
            guard case .string(let raw) = args["fileName"] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let notionFileId: String? = {
            guard case .string(let raw) = args["notionFileId"] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        guard fileName != nil || notionFileId != nil else {
            throw ToolRouterError.invalidArguments(
                toolName: "skill_materialize_file",
                reason: "one of 'fileName' or 'notionFileId' is required"
            )
        }

        let skill: SkillConfig? = if let idArg {
            if let configured = lookupSkill(pageId: idArg) {
                configured
            } else {
                await lookupCachedSpecialist(pageId: idArg)
            }
        } else if let nameArg {
            await lookupSkill(named: nameArg)
        } else {
            nil
        }
        guard let skill else {
            if let idArg {
                return .object([
                    "error": .string("Skill UUID is not configured in Bridge."),
                    "id": .string(CachedSkillBody.canonicalUUID(idArg)),
                    "hint": .string("Refresh or register the Notion skill in Settings → Skills. This tool does not download arbitrary Notion pages.")
                ])
            }
            return .object([
                "error": .string("Skill not found"),
                "name": .string(nameArg ?? ""),
                "hint": .string("Skill files materialize from a configured Notion SKILLS row, not a file-source SKILL.md.")
            ])
        }

        let pageId = CachedSkillBody.normalize(skill.notionPageId)
        guard CachedSkillBody.isNotionUUID(pageId) else {
            return .object([
                "error": .string("Skill has no Notion page id"),
                "name": .string(skill.name),
                "hint": .string("file-source SKILL.md skills have no Notion Files & media; use file_read on the local skill folder.")
            ])
        }

        do {
            let client = try NotionClient()
            let data = try await client.getPage(pageId: pageId)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["properties"] as? [String: Any] else {
                return .object([
                    "error": .string("Skill page had no properties"),
                    "name": .string(skill.name),
                    "uuid": .string(CachedSkillBody.canonicalUUID(pageId))
                ])
            }
            let catalog = SkillFileCatalog.fromRawPageProperties(props, skillUUID: pageId)
            guard catalog.propertyPresent else {
                return .object([
                    "error": .string("Skill has no Files & media property"),
                    "name": .string(skill.name),
                    "uuid": .string(CachedSkillBody.canonicalUUID(pageId)),
                    "files": .array([]),
                    "hint": .string("Notion is not binary SSOT. If the library lives on disk, use assetRoot from fetch_skill / file_read.")
                ])
            }
            let needle = fileName ?? notionFileId ?? ""
            guard let entry = SkillFileCatalog.findEntry(
                in: catalog,
                fileName: fileName,
                notionFileId: notionFileId
            ) else {
                return .object([
                    "error": .string(SkillFileMaterializeError.fileNotOnSkill(needle).localizedDescription),
                    "name": .string(skill.name),
                    "uuid": .string(CachedSkillBody.canonicalUUID(pageId)),
                    "files": .array(catalog.files.map(\.envelopeValue))
                ])
            }
            let materialized = try await SkillFileCatalog.materialize(
                skillUUID: pageId,
                entry: entry,
                download: SkillFileCatalog.defaultDownload
            )
            return .object([
                "success": .bool(true),
                "name": .string(skill.name),
                "uuid": .string(CachedSkillBody.canonicalUUID(pageId)),
                "file": materialized.envelopeValue,
                "localPath": .string(materialized.localPath ?? ""),
                "hint": .string("Open with file_read. Notion remains a mirror — local disk is binary SSOT when assetRoot is set.")
            ])
        } catch let error as SkillFileMaterializeError {
            return .object([
                "error": .string(error.localizedDescription),
                "name": .string(skill.name),
                "uuid": .string(CachedSkillBody.canonicalUUID(pageId))
            ])
        } catch {
            return .object([
                "error": .string("Failed to materialize skill file"),
                "detail": .string(error.localizedDescription),
                "name": .string(skill.name),
                "uuid": .string(CachedSkillBody.canonicalUUID(pageId))
            ])
        }
    }
}

