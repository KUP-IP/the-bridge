// SkillsManager.swift — Skills Configuration Manager
// NotionBridge · Modules
// PKT-366 F9: Manages named Notion page skills stored in UserDefaults.
// PKT-485: resetToDefaults() clears skills for factory reset (empty registry).
// PKT-487: Added moveSkill(from:to:) and sortAlphabetically() for ordering.

import Foundation
import Observation

/// Posted after `com.notionbridge.skills` is written by MCP (`manage_skill`) so the Settings UI can reload.
extension Notification.Name {
    public static let notionBridgeSkillsStorageDidChange = Notification.Name("com.notionbridge.skillsStorageDidChange")
}

/// Limits for MCP skill metadata stored in UserDefaults (`summary`, trigger / anti phrase lists).
public struct SkillMetadataLimits: Sendable {
    public static let maxSummaryCharacters = 4000
    public static let maxPhraseListCount = 64
    public static let maxPhraseCharacterCount = 500

    public static func clampedSummary(_ raw: String) -> String {
        String(raw.prefix(maxSummaryCharacters))
    }

    public static func clampedPhraseList(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in raw {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let clipped = String(t.prefix(maxPhraseCharacterCount))
            let key = clipped.lowercased()
            if seen.insert(key).inserted, out.count < maxPhraseListCount {
                out.append(clipped)
            }
        }
        return out
    }
}

/// Visibility for MCP discovery vs fetch-only registry entries.
///
/// cmd-ux W3: `.command` is a NEW, ORTHOGONAL axis — it controls only
/// whether an enabled skill appears in the global Commands PALETTE
/// (`RegistrySkillsCommandProvider`). It is deliberately single-enum
/// (Q3=a): a `.command` skill is palette-only-for-DISCOVERY. It is NOT
/// in the `list_routing_skills` discovery list (that stays
/// `enabled && .routing`), and — critically — `fetch_skill` is
/// name-based and visibility-AGNOSTIC, so a `.command` skill is STILL
/// fetchable by name exactly like before. The retrieval split locked by
/// SkillVsCommandSplitTests is a different axis and is unaffected.
public enum SkillVisibility: String, Sendable, CaseIterable, Equatable {
    /// Listed by `list_routing_skills` when enabled (lightweight discovery).
    case routing
    /// Fetchable via `fetch_skill` only; omitted from routing list.
    case standard
    /// cmd-ux W3: appears in the global Commands palette (the hot-key
    /// command box copies the page body to the clipboard). Still
    /// fetchable by name via `fetch_skill`; NOT in the routing list.
    case command
}

extension SkillVisibility: Codable {
    /// Round-trips all cases incl. `.command`. Decodes the legacy
    /// persisted value `adminOnly` as `.standard`; any
    /// unknown/missing/corrupt raw value degrades safely to `.standard`
    /// (the conservative default — never silently promotes a skill into
    /// the palette or the routing list).
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "routing": self = .routing
        case "command": self = .command
        case "adminOnly": self = .standard
        case "standard": self = .standard
        default: self = .standard
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension SkillVisibility {
    /// cmd-ux W3: the single source of the human-readable picker label
    /// for each case. Both visibility pickers (add-form + per-row) and
    /// the Settings help block render from this — no more hardcoded,
    /// drift-prone tag/label lists. Iterating `SkillVisibility.allCases`
    /// + this label is the ONE place a future case shows up.
    public var pickerLabel: String {
        switch self {
        case .routing:  return "Routing (discovery list)"
        case .standard: return "Standard (fetch only)"
        case .command:  return "Command (palette)"
        }
    }

    /// cmd-ux W4 (3.4.1): legacy enum → flag-pair mapping. The flag model
    /// is the new SSOT; this enum is preserved only as a synthesized read
    /// view + back-compat write target for one release.
    public var asFlags: (routingDiscoverable: Bool, inCommandPalette: Bool) {
        switch self {
        case .routing:  return (true,  false)
        case .standard: return (false, false)
        case .command:  return (false, true)
        }
    }

    /// cmd-ux W4 (3.4.1): flag-pair → legacy enum. Both flags true (a NEW
    /// combination the old enum cannot express) collapses to `.command` so
    /// existing `visibility == .command` checks remain correct. New
    /// callsites should read the flags directly via the Skill accessors.
    public static func fromFlags(routingDiscoverable r: Bool, inCommandPalette c: Bool) -> SkillVisibility {
        if c { return .command }
        if r { return .routing }
        return .standard
    }
}

// MARK: - SkillSource (W2 D2)

/// Discriminated origin for a skill. `cmd-w2` introduces SKILL.md
/// filesystem-loaded skills alongside Notion-page skills.
///
/// Persisted wire format (in the same JSON-encoded array under
/// `BridgeDefaults.skills`):
///   `.notion(pageId)` → `{"source": {"kind": "notion", "pageId": "<32hex>"}}`
///   `.file(path)`     → `{"source": {"kind": "file",   "path":   "<abs URL>"}}`
///
/// Backward-compat: a legacy row that carries the old top-level field
/// `"notionPageId": "<32hex>"` (without a `source` discriminator) decodes
/// as `.notion(pageId)`. Decoding is union-of-both; encoding always
/// writes the new `source` shape. Re-decoding a re-encoded legacy blob
/// is stable (a fixed point — see SkillSourceTests).
public enum SkillSource: Sendable, Equatable, Codable {
    case notion(pageId: String)
    case file(path: URL)

    private enum CodingKeys: String, CodingKey {
        case kind, pageId, path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "notion":
            let pid = try c.decode(String.self, forKey: .pageId)
            self = .notion(pageId: pid)
        case "file":
            let raw = try c.decode(String.self, forKey: .path)
            // Decode both file:// URL strings and bare absolute paths
            // (defensive — a hand-edited preferences plist could carry
            // either). `URL(fileURLWithPath:)` always succeeds.
            if let url = URL(string: raw), url.isFileURL {
                self = .file(path: url)
            } else {
                self = .file(path: URL(fileURLWithPath: raw))
            }
        default:
            // Unknown discriminator: degrade safely to an empty-notion source
            // (the conservative default — the row will fail validation and
            // surface the corruption to the operator rather than crash).
            self = .notion(pageId: "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notion(let pageId):
            try c.encode("notion", forKey: .kind)
            try c.encode(pageId, forKey: .pageId)
        case .file(let path):
            try c.encode("file", forKey: .kind)
            // Normalized encode: emits the full `file://...` URL. The decode
            // path is forgiving (accepts both `file://...` and a bare absolute
            // path); a bare-path input therefore decodes once and re-encodes
            // with the `file://` prefix — semantically a quiet normalization.
            try c.encode(path.absoluteString, forKey: .path)
        }
    }

    /// The Notion page id, if this is a `.notion` source. Empty string for
    /// `.file` sources. Used by call sites that ONLY make sense for Notion
    /// (e.g. `sync_metadata_to_notion`, the Notion-API fetch path).
    public var notionPageIdOrEmpty: String {
        switch self {
        case .notion(let pid): return pid
        case .file:            return ""
        }
    }

    /// True for `.file` sources.
    public var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}

/// Manages the Skills configuration — named Notion pages that can be
/// fetched at runtime via the `fetch_skill` MCP tool.
///
/// Persistence: JSON-encoded array in UserDefaults under `com.notionbridge.skills`.
/// Each skill has a unique name, a Notion page ID (URL), enabled flag, and visibility.
@MainActor
@Observable
public final class SkillsManager {

    /// A single skill definition: name + source (Notion page or file path)
    /// + enabled + visibility.
    ///
    /// W2 D2: `source` replaces the prior `notionPageId: String` field. The
    /// persistence layer reads BOTH the new `source` discriminator AND the
    /// legacy top-level `notionPageId` — so an existing UserDefaults blob
    /// from a prior release decodes as `.notion(pageId)` without
    /// migration. Encoding always emits the new `source` shape; re-decode
    /// is stable.
    public struct Skill: Codable, Identifiable, Sendable, Equatable {
        public var id: String { name }
        public var name: String
        public var source: SkillSource
        public var enabled: Bool
        /// cmd-ux W4 (3.4.1): primary stored visibility axis. SSOT for the
        /// `list_routing_skills` discovery list (`routingDiscoverable`)
        /// and the Commands palette membership (`inCommandPalette`). The
        /// legacy `SkillVisibility` enum is preserved as a derived read +
        /// back-compat encode mirror only — every call site that branches
        /// on a single enum value now maps to one of these two flags.
        public var routingDiscoverable: Bool
        public var inCommandPalette: Bool
        /// MCP-facing summary (authoritative in UserDefaults; sync to Notion via `manage_skill`).
        public var summary: String
        public var triggerPhrases: [String]
        public var antiTriggerPhrases: [String]
        /// V2-SKILLS: Original URL for click-to-open in browser. Optional.
        public var url: String?
        /// V2-SKILLS: Auto-detected platform from URL. Defaults to .notion for backward compat.
        public var platform: SkillPlatform

        /// Convenience: the Notion page id for a `.notion` source, or
        /// empty for `.file`. Many existing call sites only make sense for
        /// Notion-source skills (the Notion API client, page-id
        /// validators, etc.) — those keep reading this field unchanged.
        public var notionPageId: String { source.notionPageIdOrEmpty }

        /// Derived legacy view — call sites that branch on a single enum
        /// value continue to work without source changes. Setting maps to
        /// the underlying flags. New code should prefer the flag pair.
        public var visibility: SkillVisibility {
            get { SkillVisibility.fromFlags(routingDiscoverable: routingDiscoverable, inCommandPalette: inCommandPalette) }
            set {
                let pair = newValue.asFlags
                self.routingDiscoverable = pair.routingDiscoverable
                self.inCommandPalette = pair.inCommandPalette
            }
        }

        enum CodingKeys: String, CodingKey {
            case name, source, notionPageId, enabled, visibility,
                 routingDiscoverable, inCommandPalette,
                 summary, triggerPhrases, antiTriggerPhrases, url, platform
        }

        /// Flag-based designated initializer — the new W4 SSOT shape.
        public init(
            name: String,
            source: SkillSource,
            enabled: Bool = true,
            routingDiscoverable: Bool = false,
            inCommandPalette: Bool = false,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.name = name
            self.source = source
            self.enabled = enabled
            self.routingDiscoverable = routingDiscoverable
            self.inCommandPalette = inCommandPalette
            self.summary = SkillMetadataLimits.clampedSummary(summary)
            self.triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
            self.antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
            self.url = url
            self.platform = platform
        }

        /// Back-compat convenience initializer — every pre-W4 caller that
        /// passes `visibility:` keeps working; the enum is translated to
        /// the flag pair at construction time.
        public init(
            name: String,
            source: SkillSource,
            enabled: Bool = true,
            visibility: SkillVisibility,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            let pair = visibility.asFlags
            self.init(
                name: name,
                source: source,
                enabled: enabled,
                routingDiscoverable: pair.routingDiscoverable,
                inCommandPalette: pair.inCommandPalette,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        /// Legacy convenience initializer accepting `notionPageId` directly
        /// — keeps every pre-W2 caller (and 30+ persisted-format test
        /// fixtures) compiling unchanged. Constructs `.notion(pageId:)`.
        public init(
            name: String,
            notionPageId: String,
            enabled: Bool = true,
            visibility: SkillVisibility = .standard,
            summary: String = "",
            triggerPhrases: [String] = [],
            antiTriggerPhrases: [String] = [],
            url: String? = nil,
            platform: SkillPlatform = .notion
        ) {
            self.init(
                name: name,
                source: .notion(pageId: notionPageId),
                enabled: enabled,
                visibility: visibility,
                summary: summary,
                triggerPhrases: triggerPhrases,
                antiTriggerPhrases: antiTriggerPhrases,
                url: url,
                platform: platform
            )
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            // W2 D2: union-of-both decode. Prefer the new `source`
            // discriminator; fall back to the legacy top-level
            // `notionPageId` field for backward compat with persisted
            // blobs written by every prior release.
            if let decoded = try c.decodeIfPresent(SkillSource.self, forKey: .source) {
                source = decoded
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .notionPageId) {
                source = .notion(pageId: legacy)
            } else {
                source = .notion(pageId: "")
            }
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            // W4 visibility-flag migration. Prefer the new
            // `routingDiscoverable` + `inCommandPalette` fields. If they
            // are absent (every pre-3.4.1 persisted row), fall back to
            // deriving the flag pair from the legacy `visibility` enum.
            // If even the enum is missing/malformed, both flags default
            // false (= `.standard`, the conservative posture).
            if let rd = try c.decodeIfPresent(Bool.self, forKey: .routingDiscoverable),
               let ip = try c.decodeIfPresent(Bool.self, forKey: .inCommandPalette) {
                routingDiscoverable = rd
                inCommandPalette = ip
            } else {
                let legacy = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
                let pair = legacy.asFlags
                routingDiscoverable = pair.routingDiscoverable
                inCommandPalette = pair.inCommandPalette
            }
            let rawSummary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            let rawTriggers = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
            let rawAnti = try c.decodeIfPresent([String].self, forKey: .antiTriggerPhrases) ?? []
            summary = SkillMetadataLimits.clampedSummary(rawSummary)
            triggerPhrases = SkillMetadataLimits.clampedPhraseList(rawTriggers)
            antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(rawAnti)
            // V2-SKILLS: Backward-compat — existing skills default to .notion, no URL
            url = try c.decodeIfPresent(String.self, forKey: .url)
            platform = try c.decodeIfPresent(SkillPlatform.self, forKey: .platform) ?? .notion
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            // W2 D2: encode the NEW `source` shape. Also mirror the
            // notion page id into the legacy `notionPageId` field when
            // it is a `.notion` source so a hypothetical older build
            // that doesn't know about `source` still works (forward-
            // compat with the prior wire format).
            try c.encode(source, forKey: .source)
            if case .notion(let pid) = source {
                try c.encode(pid, forKey: .notionPageId)
            }
            try c.encode(enabled, forKey: .enabled)
            // W4: write BOTH the new flag pair (primary SSOT going
            // forward) AND the derived legacy enum value (one-cycle
            // back-compat so a hypothetical older build that still
            // reads `visibility` keeps working). The flag pair is the
            // source of truth on the next decode.
            try c.encode(routingDiscoverable, forKey: .routingDiscoverable)
            try c.encode(inCommandPalette, forKey: .inCommandPalette)
            try c.encode(visibility, forKey: .visibility)
            try c.encode(summary, forKey: .summary)
            try c.encode(triggerPhrases, forKey: .triggerPhrases)
            try c.encode(antiTriggerPhrases, forKey: .antiTriggerPhrases)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(platform, forKey: .platform)
        }
    }

    private static let defaultsKey = BridgeDefaults.skills

    /// Empty template for factory reset / "restore defaults" — no bundled placeholder skills.
    public static let defaultSkills: [Skill] = []

    public private(set) var skills: [Skill] = []

    public init() {
        load()
    }

    /// Reloads from `UserDefaults` (same key as MCP `manage_skill`). Use after external writes while the app stays open.
    public func reloadFromUserDefaults() {
        load()
    }

    // MARK: - CRUD

    /// Add a new skill. Returns false if name is empty or not unique.
    @discardableResult
    public func addSkill(name: String, notionPageId: String) -> Bool {
        addSkill(name: name, source: .notion(pageId: notionPageId), visibility: .standard)
    }

    /// Add with explicit visibility (e.g. routing tier).
    @discardableResult
    public func addSkill(name: String, notionPageId: String, visibility: SkillVisibility) -> Bool {
        addSkill(name: name, source: .notion(pageId: notionPageId), visibility: visibility)
    }

    /// W2 D2: full-fidelity add accepting any `SkillSource`.
    @discardableResult
    public func addSkill(name: String, source: SkillSource, visibility: SkillVisibility = .standard) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            return false
        }
        skills.append(Skill(name: trimmed, source: source, visibility: visibility))
        save()
        return true
    }

    /// Remove a skill by name.
    public func removeSkill(named name: String) {
        skills.removeAll { $0.name == name }
        save()
    }

    /// Toggle a skill's enabled state.
    public func toggleSkill(named name: String) {
        if let idx = skills.firstIndex(where: { $0.name == name }) {
            skills[idx].enabled.toggle()
            save()
        }
    }

    /// Look up a skill by name (case-insensitive).
    public func skill(named name: String) -> Skill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Fuzzy skill lookup with suggestions (v1.7.0, F5).
    /// Returns (match, suggestions) for Settings UI and external callers.
    public func findSkillFuzzy(named name: String) -> (match: Skill?, suggestions: [String]) {
        let input = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 1. Exact
        if let exact = skill(named: input) { return (exact, []) }
        // 2. Normalized: strip "sk " prefix, swap spaces and hyphens
        let stripped = input.hasPrefix("sk ") ? String(input.dropFirst(3)) : input
        let variants = [stripped, stripped.replacingOccurrences(of: " ", with: "-"), stripped.replacingOccurrences(of: "-", with: " ")]
        for v in variants {
            if let match = skills.first(where: { $0.name.lowercased() == v }) {
                return (match, [])
            }
        }
        // 3. Substring (unique match only)
        let subs = skills.filter {
            $0.name.lowercased().contains(stripped) || stripped.contains($0.name.lowercased())
        }
        if subs.count == 1 { return (subs[0], []) }
        // 4. No match - return all names as suggestions
        return (nil, skills.map(\.name))
    }

    /// All enabled skills.
    public var enabledSkills: [Skill] {
        skills.filter(\.enabled)
    }

    /// Enabled skills with `routingDiscoverable` set (for `list_routing_skills`).
    /// W4: reads the flag directly; the legacy `.routing` enum value
    /// maps to `routingDiscoverable == true && inCommandPalette == false`.
    public var routingSkillsForDiscovery: [Skill] {
        skills.filter { skill in
            guard skill.enabled, skill.routingDiscoverable else { return false }
            switch skill.source {
            case .notion(let pid):
                return NotionPageRef.isValidStoredPageId(pid.trimmingCharacters(in: .whitespacesAndNewlines))
            case .file:
                // W2 D6: file-source skills don't surface through the Notion-
                // page-id-bound routing list from SkillsManager. The merged
                // listing comes from `SkillsModule.list_routing_skills`,
                // which combines this Notion-source slice with file-source
                // entries from `FilesystemSkillIndex`. Keep this property
                // bound to Notion skills for backward-compat callers.
                return false
            }
        }
    }

    // MARK: - Extended CRUD (PKT-477 Feature 3)

    /// Rename a skill. Returns false if name is empty, not unique, or not found.
    @discardableResult
    public func renameSkill(named oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else { return false }
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            skills[idx].name = trimmed
            save()
            return true
        }
        return false
    }

    /// V2-SKILLS: Update url and platform fields on an existing skill.
    @discardableResult
    public func updateSkillExtras(named name: String, url: String?, platform: SkillPlatform) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].url = url
            skills[idx].platform = platform
            save()
            return true
        }
        return false
    }

        /// Update a skill's Notion page ID. Returns false if not found.
    /// File-source skills are not updatable here (the SKILL.md path is the
    /// source of truth — use the user dir to change it).
    @discardableResult
    public func updateSkillURL(named name: String, newPageId: String) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            switch skills[idx].source {
            case .notion:
                skills[idx].source = .notion(pageId: newPageId)
                save()
                return true
            case .file:
                // No-op for file-source skills (preserves contract that
                // returning `false` means "no change applied").
                return false
            }
        }
        return false
    }

    /// Set visibility tier via the legacy enum. Maps to the flag pair
    /// at the call site so existing call paths keep working unchanged.
    /// Returns false if not found.
    @discardableResult
    public func setVisibility(named name: String, to visibility: SkillVisibility) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].visibility = visibility
            save()
            return true
        }
        return false
    }

    /// cmd-ux W4: flag-direct mutator — the new W4 UI writes these
    /// independently rather than via the 3-state enum. Returns false if
    /// not found. The two flags are independent: a skill may be both
    /// routing-discoverable AND palette-pinned (the new state the old
    /// enum could not express).
    @discardableResult
    public func setRoutingDiscoverable(named name: String, to value: Bool) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].routingDiscoverable = value
            save()
            return true
        }
        return false
    }

    /// cmd-ux W4: flag-direct mutator — the new W4 UI writes these
    /// independently rather than via the 3-state enum. Returns false if
    /// not found.
    @discardableResult
    public func setInCommandPalette(named name: String, to value: Bool) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].inCommandPalette = value
            save()
            return true
        }
        return false
    }

    /// Set MCP metadata for a skill (clamped). Returns false if not found.
    @discardableResult
    public func setMetadata(
        named name: String,
        summary: String,
        triggerPhrases: [String],
        antiTriggerPhrases: [String]
    ) -> Bool {
        guard let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            return false
        }
        skills[idx].summary = SkillMetadataLimits.clampedSummary(summary)
        skills[idx].triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
        skills[idx].antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
        save()
        return true
    }

    /// Bulk add multiple skills at once. Skips duplicates.
    public func bulkAdd(skills newSkills: [(name: String, pageId: String)]) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for s in newSkills {
            if addSkill(name: s.name, notionPageId: s.pageId) {
                added += 1
            } else {
                skipped += 1
            }
        }
        return (added, skipped)
    }

    /// Return all skills (for manage tool).
    public func listSkills() -> [Skill] {
        return skills
    }

    // MARK: - Ordering (PKT-487)

    /// Move a skill from one position to another. Persists immediately.
    /// Returns false if either index is out of bounds or indices are equal.
    @discardableResult
    public func moveSkill(from source: Int, to destination: Int) -> Bool {
        guard source >= 0, source < skills.count,
              destination >= 0, destination < skills.count,
              source != destination else { return false }
        let skill = skills.remove(at: source)
        skills.insert(skill, at: destination)
        save()
        return true
    }

    /// Sort all skills alphabetically by name (case-insensitive). Persists immediately.
    public func sortAlphabetically() {
        skills.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    // MARK: - Factory Reset (PKT-485)

    /// Clear all skills and persist (factory reset / restore empty registry).
    public func resetToDefaults() {
        skills = Self.defaultSkills
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Skill].self, from: data) else {
            skills = []
            return
        }
        skills = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
