// SkillManagementUIContract.swift — pure Skills settings UI contract
// NotionBridge · Modules · Skills
//
// Keeps the Skills settings surface aligned with the backend storage model:
// labels, counts, grouping, filtering, and row status are all derived from the
// same `SkillsManager.Skill` flags and file-source toggle state the MCP/backend
// paths persist. The SwiftUI view renders these values; tests exercise this file
// as the headless user-scenario seam.

import Foundation

/// Source segment shown in Settings -> Skills.
public enum SkillManagementSourceFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case file
    case notion
    case gdocs

    public var label: String {
        switch self {
        case .all: return "All"
        case .file: return "File"
        case .notion: return "Notion"
        case .gdocs: return "Docs"
        }
    }
}

/// Render-safe state for a file-source skill row. The path-keyed values come
/// from `SkillsModule` UserDefaults helpers; the SKILL.md itself remains
/// read-only.
public struct SkillManagementFileSkillState: Sendable, Equatable {
    public var name: String
    public var path: String
    public var enabled: Bool
    public var routingDiscoverable: Bool
    public var inCommandPalette: Bool

    public init(
        name: String,
        path: String,
        enabled: Bool = true,
        routingDiscoverable: Bool = false,
        inCommandPalette: Bool = false
    ) {
        self.name = name
        self.path = path
        self.enabled = enabled
        self.routingDiscoverable = routingDiscoverable
        self.inCommandPalette = inCommandPalette
    }
}

public struct SkillManagementSkillGroup: Sendable, Equatable {
    public var id: String
    public var label: String
    public var skills: [SkillsManager.Skill]

    public init(id: String, label: String, skills: [SkillsManager.Skill]) {
        self.id = id
        self.label = label
        self.skills = skills
    }
}

public struct SkillManagementCounts: Sendable, Equatable {
    public var total: Int
    public var routing: Int
    public var specialist: Int
    public var cached: Int

    public init(total: Int, routing: Int, specialist: Int, cached: Int) {
        self.total = total
        self.routing = routing
        self.specialist = specialist
        self.cached = cached
    }
}

public struct SkillManagementBannerState: Sendable, Equatable {
    public var showsInvalidPageIDs: Bool
    public var showsFetchSkillDisabled: Bool
    public var showsPaletteEmpty: Bool
    public var showsCacheFailure: Bool

    public init(
        showsInvalidPageIDs: Bool,
        showsFetchSkillDisabled: Bool,
        showsPaletteEmpty: Bool,
        showsCacheFailure: Bool
    ) {
        self.showsInvalidPageIDs = showsInvalidPageIDs
        self.showsFetchSkillDisabled = showsFetchSkillDisabled
        self.showsPaletteEmpty = showsPaletteEmpty
        self.showsCacheFailure = showsCacheFailure
    }
}

public enum SkillManagementUIContract {
    public static func isAddSkillEnabled(name: String, pageId: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func anyBodyCached(
        skills: [SkillsManager.Skill],
        bodyCacheSnapshot: SkillBodyCacheSnapshot
    ) -> Bool {
        skills.contains { bodyCacheSnapshot.isCached($0.notionPageId) }
    }

    public static func listFooterText(
        skills: [SkillsManager.Skill],
        bodyCacheSnapshot: SkillBodyCacheSnapshot
    ) -> String {
        let total = skills.count
        guard total > 0 else { return "No skills" }
        let enabled = skills.filter(\.enabled).count
        let cached = bodyCacheSnapshot.cachedCount(amongPageIds: skills.map(\.notionPageId))
        return "\(enabled)/\(total) enabled · \(cached) cached"
    }

    public static func palettePopulation(
        skills: [SkillsManager.Skill],
        fileSkills: [SkillManagementFileSkillState]
    ) -> Int {
        skills.filter { $0.enabled && $0.inCommandPalette }.count
            + fileSkills.filter { $0.enabled && $0.inCommandPalette }.count
    }

    public static func bannerState(
        skills: [SkillsManager.Skill],
        fileSkills: [SkillManagementFileSkillState],
        fetchSkillDisabled: Bool,
        cacheBusy: Bool,
        cacheMessage: String?,
        cacheIsError: Bool
    ) -> SkillManagementBannerState {
        SkillManagementBannerState(
            showsInvalidPageIDs: skills.contains { !NotionPageRef.isValidStoredPageId($0.notionPageId) },
            showsFetchSkillDisabled: fetchSkillDisabled && !skills.isEmpty,
            showsPaletteEmpty: !skills.isEmpty && palettePopulation(skills: skills, fileSkills: fileSkills) == 0,
            showsCacheFailure: cacheIsError && cacheMessage != nil && !cacheBusy
        )
    }

    public static func rowStatusDescription(for skill: SkillsManager.Skill) -> String {
        if !skill.enabled { return "Disabled" }
        if skill.routingDiscoverable { return "Enabled, routing-discoverable" }
        if skill.inCommandPalette { return "Enabled, palette only" }
        return "Enabled"
    }

    public static func visibilityBadgeLabel(for skill: SkillsManager.Skill) -> String {
        if !skill.enabled { return "Disabled" }
        if skill.routingDiscoverable { return "Routing-discoverable" }
        if skill.inCommandPalette { return "Palette-only" }
        return "Enabled"
    }

    public static func visibilityMetadataLabel(for skill: SkillsManager.Skill) -> String {
        switch (skill.routingDiscoverable, skill.inCommandPalette) {
        case (true, true): return "Both"
        case (true, false): return "Routing"
        case (false, true): return "Palette"
        case (false, false): return "Fetch-only"
        }
    }

    public static func kindLabel(for skill: SkillsManager.Skill) -> String {
        switch skill.skillKind {
        case .routing: return "Routing"
        case .specialist: return "Specialist"
        case .plain: return "Plain"
        }
    }

    public static func countableSkills(
        _ skills: [SkillsManager.Skill],
        sourceFilter: SkillManagementSourceFilter
    ) -> [SkillsManager.Skill] {
        switch sourceFilter {
        case .all:
            return skills
        case .notion:
            return skills.filter { $0.platform == .notion }
        case .gdocs:
            return skills.filter { $0.platform == .googleDocs }
        case .file:
            return []
        }
    }

    public static func counts(
        skills: [SkillsManager.Skill],
        fileSkills: [SkillManagementFileSkillState],
        sourceFilter: SkillManagementSourceFilter,
        bodyCacheSnapshot: SkillBodyCacheSnapshot
    ) -> SkillManagementCounts {
        let countable = countableSkills(skills, sourceFilter: sourceFilter)
        let includeFiles = sourceFilter == .all || sourceFilter == .file
        return SkillManagementCounts(
            total: countable.count + (includeFiles ? fileSkills.count : 0),
            routing: countable.filter { $0.enabled && $0.routingDiscoverable }.count
                + (includeFiles ? fileSkills.filter { $0.enabled && $0.routingDiscoverable }.count : 0),
            specialist: countable.filter { $0.enabled && $0.skillKind == .specialist }.count,
            cached: bodyCacheSnapshot.cachedCount(amongPageIds: countable.map(\.notionPageId))
                + (includeFiles ? fileSkills.count : 0)
        )
    }

    public static func filteredSkills(
        _ skills: [SkillsManager.Skill],
        searchText: String,
        sourceFilter: SkillManagementSourceFilter
    ) -> [SkillsManager.Skill] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skills.filter { skill in
            let matchesQuery = q.isEmpty
                || skill.name.lowercased().contains(q)
                || skill.summary.lowercased().contains(q)
            let matchesSource: Bool = {
                switch sourceFilter {
                case .all: return true
                case .notion: return skill.platform == .notion
                case .gdocs: return skill.platform == .googleDocs
                case .file: return false
                }
            }()
            return matchesQuery && matchesSource
        }
    }

    public static func visibleFileSkills(
        _ fileSkills: [SkillManagementFileSkillState],
        searchText: String,
        sourceFilter: SkillManagementSourceFilter
    ) -> [SkillManagementFileSkillState] {
        guard sourceFilter == .all || sourceFilter == .file else { return [] }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return fileSkills }
        return fileSkills.filter { $0.name.lowercased().contains(q) }
    }

    public static func visibleGroups(
        skills: [SkillsManager.Skill],
        searchText: String,
        sourceFilter: SkillManagementSourceFilter
    ) -> [SkillManagementSkillGroup] {
        let all = filteredSkills(skills, searchText: searchText, sourceFilter: sourceFilter)
        let routing = all.filter { $0.skillKind == .routing }
        let specialist = all.filter { $0.skillKind == .specialist }
        let plain = all.filter { $0.skillKind == .plain }
        return [
            SkillManagementSkillGroup(id: "routing", label: "Routing & orchestrators", skills: routing),
            SkillManagementSkillGroup(id: "specialist", label: "Specialists", skills: specialist),
            SkillManagementSkillGroup(id: "plain", label: "Plain skills", skills: plain),
        ].filter { !$0.skills.isEmpty }
    }

    public static func visibleSkillNamesInDisplayOrder(
        skills: [SkillsManager.Skill],
        searchText: String,
        sourceFilter: SkillManagementSourceFilter
    ) -> [String] {
        visibleGroups(skills: skills, searchText: searchText, sourceFilter: sourceFilter)
            .flatMap { $0.skills.map(\.name) }
    }
}
