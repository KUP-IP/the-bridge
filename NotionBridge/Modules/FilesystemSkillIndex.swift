// FilesystemSkillIndex.swift — W2 D3: file-source skills index
// NotionBridge · Modules
//
// Discovers SKILL.md files in two roots:
//   • Bundled defaults: Bundle.module, subdir `skills/<name>/SKILL.md`
//     (or `STUB.md` for source-available linked-only skills).
//   • User-installable: ~/Library/Application Support/The Bridge/skills/
//     (or `kup.solutions.notion-bridge`'s appSupport dir derived from the
//     main bundle id).
//
// Parses each file's YAML frontmatter via `FrontmatterParser` (zero deps)
// and exposes the result as a `ParsedSkill` snapshot. All mutating state
// lives behind an `actor` for Swift 6 strict concurrency.
//
// Refresh model:
//   • An init-time scan populates the cache.
//   • A `DispatchSource` file-system watcher on the USER dir invalidates
//     on `.write / .delete / .rename`. (Bundled dir is immutable.)
//   • Defensive TTL floor: any read >60s after the last index without a
//     watcher event triggers a forced re-scan.
//
// Identity rule: when both roots define a skill with the same name, the
// USER dir wins (the operator's override). Notion-source vs. file-source
// collision handling lives in `SkillsModule.list_routing_skills` (D4) —
// here we only resolve file-vs-file collisions.

import Foundation

/// A parsed file-source skill snapshot. Value type — safe to hand out
/// across actor boundaries.
public struct ParsedSkill: Sendable, Equatable {
    /// The skill name (filename of the parent directory, or the `name`
    /// frontmatter value if present).
    public let name: String
    /// Absolute file URL of the SKILL.md (or STUB.md) file.
    public let path: URL
    /// `true` when this skill came from the user's Application Support
    /// dir (operator override). `false` for bundled defaults.
    public let isUserSource: Bool
    /// Decoded frontmatter (string / bool / array). Empty if the file
    /// had no `---` block (whole file is body).
    public let frontmatter: [String: FrontmatterValue]
    /// Markdown body — everything after the closing `---`.
    public let body: String
    /// Human-readable display path (relative to either bundled or user
    /// dir), suitable for the `shadows` annotation in D4.
    public let displayPath: String

    public init(
        name: String,
        path: URL,
        isUserSource: Bool,
        frontmatter: [String: FrontmatterValue],
        body: String,
        displayPath: String
    ) {
        self.name = name
        self.path = path
        self.isUserSource = isUserSource
        self.frontmatter = frontmatter
        self.body = body
        self.displayPath = displayPath
    }
}

/// Indexes SKILL.md files on disk and exposes them by name.
/// Single shared instance: `FilesystemSkillIndex.shared`.
public actor FilesystemSkillIndex {

    /// Time-to-live for the in-memory cache before a defensive re-scan.
    /// Watcher-driven invalidation should normally beat this floor.
    public static let cacheTTL: TimeInterval = 60.0

    /// Default app-support bundle id (matches `kup.solutions.notion-bridge`
    /// from `Info.plist` — kept as a fallback so the index works in
    /// headless test harnesses where `Bundle.main.bundleIdentifier` is
    /// the test executable id, not the production app).
    public static let defaultBundleId = "kup.solutions.notion-bridge"

    /// Shared default-configured instance — production code path.
    public static let shared = FilesystemSkillIndex()

    // MARK: - State

    private var bundledDir: URL?
    private var userDir: URL
    private var indexed: [String: ParsedSkill] = [:]
    private var lastScan: Date = .distantPast
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private var didInitialScan: Bool = false

    // MARK: - Init

    /// Default init — resolves bundled dir from `Bundle.module`
    /// (`Resources/skills` subdir) and the user dir from
    /// `~/Library/Application Support/<bundleId>/skills/`.
    public init() {
        self.bundledDir = Self.defaultBundledDirectory()
        self.userDir = Self.defaultUserDirectory()
    }

    /// Test-only init — point at arbitrary roots. Either may be nil.
    public init(bundledDir: URL?, userDir: URL) {
        self.bundledDir = bundledDir
        self.userDir = userDir
    }

    // MARK: - Public API

    /// Force re-scan + return all known skills sorted by name.
    public func allSkills() async -> [ParsedSkill] {
        await ensureFresh()
        return indexed.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look up by exact (case-insensitive) name.
    public func skill(named name: String) async -> ParsedSkill? {
        await ensureFresh()
        let lower = name.lowercased()
        return indexed.first { $0.key.lowercased() == lower }?.value
    }

    /// Force an immediate re-scan (used by tests + the file watcher).
    public func reindex() async {
        scan()
    }

    /// Resolve the on-disk user directory (creates it lazily if missing
    /// — operators expect a stable, walk-up-able path).
    public func userDirectoryURL() -> URL { userDir }

    // MARK: - Internals

    /// One-shot init + TTL check.
    private func ensureFresh() async {
        if !didInitialScan {
            didInitialScan = true
            scan()
            installWatcher()
            return
        }
        // TTL floor — watcher should normally beat this.
        if Date().timeIntervalSince(lastScan) > Self.cacheTTL {
            scan()
        }
    }

    /// Synchronous scan over both roots.
    private func scan() {
        var found: [String: ParsedSkill] = [:]

        // Bundled (lowest precedence) — load first, may be overridden.
        if let bundled = bundledDir {
            for skill in Self.parseRoot(bundled, isUserSource: false) {
                found[skill.name] = skill
            }
        }
        // User dir (highest precedence) — overrides bundled.
        for skill in Self.parseRoot(userDir, isUserSource: true) {
            found[skill.name] = skill
        }

        indexed = found
        lastScan = Date()
    }

    /// Walk one root directory, returning every parsed SKILL.md / STUB.md.
    /// Tolerates missing root (returns empty). Skips unreadable files.
    private static func parseRoot(_ root: URL, isUserSource: Bool) -> [ParsedSkill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var results: [ParsedSkill] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Look for SKILL.md first, then STUB.md (W3 source-available stubs).
            let skillMd = entry.appendingPathComponent("SKILL.md")
            let stubMd  = entry.appendingPathComponent("STUB.md")
            let target: URL
            if fm.fileExists(atPath: skillMd.path) { target = skillMd }
            else if fm.fileExists(atPath: stubMd.path) { target = stubMd }
            else { continue }

            guard let text = try? String(contentsOf: target, encoding: .utf8) else { continue }
            let parsed = FrontmatterParser.parse(text)

            // Prefer the frontmatter `name` (or `title`), else the dir name.
            let dirName = entry.lastPathComponent
            let resolvedName: String = {
                if case .string(let s) = parsed.frontmatter["name"], !s.isEmpty { return s }
                if case .string(let s) = parsed.frontmatter["title"], !s.isEmpty { return s }
                return dirName
            }()

            let displayPath: String = {
                let rel = entry.lastPathComponent + "/" + target.lastPathComponent
                return isUserSource ? "~/Library/Application Support/.../\(rel)" : "bundled/\(rel)"
            }()

            results.append(ParsedSkill(
                name: resolvedName,
                path: target,
                isUserSource: isUserSource,
                frontmatter: parsed.frontmatter,
                body: parsed.body,
                displayPath: displayPath
            ))
        }
        return results
    }

    // MARK: - Watcher (user dir only — bundled is immutable)

    private func installWatcher() {
        // Tear down any prior watcher first.
        if let w = watcher { w.cancel() }
        if watcherFD >= 0 { close(watcherFD); watcherFD = -1 }

        let fm = FileManager.default
        // Ensure user dir exists so we can attach the watcher. Failure
        // is non-fatal — the TTL floor still triggers re-scans.
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)

        let fd = open(userDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.reindex()
            }
        }
        src.setCancelHandler { [weak self] in
            Task { [weak self] in await self?.releaseFD() }
        }
        src.resume()
        watcher = src
    }

    private func releaseFD() {
        if watcherFD >= 0 {
            close(watcherFD)
            watcherFD = -1
        }
    }

    deinit {
        if let w = watcher { w.cancel() }
        if watcherFD >= 0 { close(watcherFD) }
    }

    // MARK: - Default roots

    private static func defaultBundledDirectory() -> URL? {
        // SPM resources live in the `NotionBridge_NotionBridgeLib.bundle`
        // resource bundle (the `.copy("Resources/skills")` declaration in
        // Package.swift), exposed at `<bundle>/skills/<name>/SKILL.md`.
        //
        // fix(sparkle), 2026-06-05: this used to read `Bundle.module.resourceURL`
        // directly. `Bundle.module` is the SPM-synthesized accessor that TRAPS
        // (`Swift.fatalError`) when the resource bundle is missing or corrupt —
        // the same crash class that the staged-update bundle corruption caused at
        // the menu-bar-icon load site. Bundled skills are an OPTIONAL convenience
        // (the user-dir + Notion sources still work), so a broken resource bundle
        // must NOT abort the process here. Resolve the bundle through a
        // non-trapping `Bundle(path:)` lookup instead and degrade to `nil`
        // (no bundled skills) if it cannot load.
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/NotionBridge_NotionBridgeLib.bundle")
            .path
        let base: URL?
        if let bundle = Bundle(path: candidate) {
            base = bundle.resourceURL
        } else {
            // Fall back to the main bundle's own resource dir (e.g. when the SPM
            // bundle is absent in non-.app contexts). Still non-trapping.
            base = Bundle.main.resourceURL
        }
        guard let base else { return nil }
        return base.appendingPathComponent("skills", isDirectory: true)
    }

    private static func defaultUserDirectory() -> URL {
        // PKT-1 v3.5: ~/Library/Application Support/The Bridge/skills/
        // (was previously bundle-id-scoped — now everything lives under
        // the shared "The Bridge" home and BridgePaths owns the layout).
        BridgePaths.applicationSupport(.skills)
    }

    /// Seam for tests to override index contents directly in memory.
    /// 3.4.2 W4 fix: was `#if DEBUG`-gated which broke `make build`'s
    /// release-mode compile of NotionBridgeTests (5 sites in
    /// CommandPaletteTests reference this method). Removing the guard
    /// is harmless — the production code never calls this method, and
    /// shipping a public test-seam in release adds zero runtime cost
    /// (no allocation, no behavior change unless deliberately invoked).
    public func testOverrideIndexed(_ override: [String: ParsedSkill]) {
        self.indexed = override
        self.didInitialScan = true
        self.lastScan = Date()
    }
}
