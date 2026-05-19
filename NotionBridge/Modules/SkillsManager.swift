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
}

/// Manages the Skills configuration — named Notion pages that can be
/// fetched at runtime via the `fetch_skill` MCP tool.
///
/// Persistence: JSON-encoded array in UserDefaults under `com.notionbridge.skills`.
/// Each skill has a unique name, a Notion page ID (URL), enabled flag, and visibility.
@MainActor
@Observable
public final class SkillsManager {

    /// A single skill definition: name + Notion page ID + enabled + visibility.
    public struct Skill: Codable, Identifiable, Sendable, Equatable {
        public var id: String { name }
        public var name: String
        public var notionPageId: String
        public var enabled: Bool
        public var visibility: SkillVisibility
        /// MCP-facing summary (authoritative in UserDefaults; sync to Notion via `manage_skill`).
        public var summary: String
        public var triggerPhrases: [String]
        public var antiTriggerPhrases: [String]
        /// V2-SKILLS: Original URL for click-to-open in browser. Optional.
        public var url: String?
        /// V2-SKILLS: Auto-detected platform from URL. Defaults to .notion for backward compat.
        public var platform: SkillPlatform

        enum CodingKeys: String, CodingKey {
            case name, notionPageId, enabled, visibility, summary, triggerPhrases, antiTriggerPhrases, url, platform
        }

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
            self.name = name
            self.notionPageId = notionPageId
            self.enabled = enabled
            self.visibility = visibility
            self.summary = SkillMetadataLimits.clampedSummary(summary)
            self.triggerPhrases = SkillMetadataLimits.clampedPhraseList(triggerPhrases)
            self.antiTriggerPhrases = SkillMetadataLimits.clampedPhraseList(antiTriggerPhrases)
            self.url = url
            self.platform = platform
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            notionPageId = try c.decode(String.self, forKey: .notionPageId)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            visibility = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
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
            try c.encode(notionPageId, forKey: .notionPageId)
            try c.encode(enabled, forKey: .enabled)
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            return false
        }
        skills.append(Skill(name: trimmed, notionPageId: notionPageId, visibility: .standard))
        save()
        return true
    }

    /// Add with explicit visibility (e.g. routing tier).
    @discardableResult
    public func addSkill(name: String, notionPageId: String, visibility: SkillVisibility) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !skills.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            return false
        }
        skills.append(Skill(name: trimmed, notionPageId: notionPageId, visibility: visibility))
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

    /// Enabled skills marked `routing` with a valid Notion page id (for `list_routing_skills`).
    public var routingSkillsForDiscovery: [Skill] {
        skills.filter {
            $0.enabled && $0.visibility == .routing
                && NotionPageRef.isValidStoredPageId($0.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines))
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
    @discardableResult
    public func updateSkillURL(named name: String, newPageId: String) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].notionPageId = newPageId
            save()
            return true
        }
        return false
    }

    /// Set visibility tier. Returns false if not found.
    @discardableResult
    public func setVisibility(named name: String, to visibility: SkillVisibility) -> Bool {
        if let idx = skills.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            skills[idx].visibility = visibility
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
