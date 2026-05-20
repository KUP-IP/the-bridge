// RegistrySkillsCommandProvider.swift — cmd-sb (re-point palette → skills registry)
// NotionBridge · Modules · Commands
//
// The Commands palette's descriptor source is now the EXISTING skills
// registry — the JSON array in UserDefaults under
// `com.notionbridge.skills` (`BridgeDefaults.skills`), written by the MCP
// `manage_skill` tool and the Settings → Skills tab and owned by
// `SkillsManager`. There is no separate "Commands data source": every
// ENABLED registry entry is a selectable palette row.
//
// Why a direct UserDefaults decode (not `SkillsManager`): `SkillsManager`
// is `@MainActor @Observable`; `CommandDescriptorProviding.descriptors()`
// is a `Sendable`, non-isolated async call driven from the palette
// coordinator (an `actor`). `SkillsModule` already established the
// canonical pattern for an off-MainActor registry read — a lightweight
// `Codable` mirror of `SkillsManager.Skill` decoded straight from
// `UserDefaults` (see `SkillsModule.SkillConfig`). This provider mirrors
// that exactly so it is `Sendable`, headlessly testable (inject a
// `UserDefaults`), and consistent with the rest of the registry readers.
//
// Mapping (registry entry → CommandDescriptor): a registry entry carries
// `{ name, notionPageId, enabled, visibility, summary, … }`. The palette
// row needs `{ id (page id), name, abbreviation, group, tags }`. The page
// id is `notionPageId`; the searchable trigger/abbreviation is the skill
// `name` (registry entries have no separate short trigger — name is the
// only human key, so it is BOTH the display name and the abbreviation so
// the deterministic `CommandPaletteSearch` can exact/prefix/fuzzy match
// it). `group`/`tags` are left at the descriptor defaults — the registry
// has no equivalent fields and (per the slice decision) there is no
// skill/command kind distinction; every enabled entry is selectable.

import Foundation

/// A `CommandDescriptorProviding` backed by the live skills registry.
///
/// Reads `BridgeDefaults.skills` from the injected `UserDefaults`,
/// decodes the persisted skill array, keeps only ENABLED entries, and
/// maps each to a `CommandDescriptor`. A missing / empty / malformed
/// registry yields an empty list (fail-safe — the palette opens and
/// shows nothing, never crashes), exactly like the prior empty static
/// provider's contract.
public struct RegistrySkillsCommandProvider: CommandDescriptorProviding {

    /// Lightweight `Codable` mirror of `SkillsManager.Skill` — the exact
    /// shape persisted under `com.notionbridge.skills`. Decoded directly
    /// so the provider needs no `@MainActor`. Identical decode semantics
    /// to `SkillsModule.SkillConfig` (tolerant of legacy rows: missing
    /// `enabled` ⇒ true, missing `visibility` ⇒ `.standard`).
    struct RegistrySkillEntry: Decodable, Sendable {
        let name: String
        /// W2 D2: source discriminator. For palette use we only want
        /// `.notion(pageId:)` entries (a `.file` source has no page id to
        /// commit to the clipboard via Notion's /markdown endpoint — file
        /// skills surface elsewhere). Backward-compat: decoded from either
        /// the new `source` field or the legacy `notionPageId` field.
        let source: SkillSource
        let enabled: Bool
        /// cmd-ux W3: the visibility axis. Decoded tolerantly via
        /// `SkillVisibility`'s own Codable (missing ⇒ `.standard`;
        /// legacy `adminOnly` ⇒ `.standard`; unknown ⇒ `.standard`;
        /// `command` round-trips). The palette filters to `.command`.
        let visibility: SkillVisibility

        /// Convenience: the Notion page id (empty for `.file` sources).
        /// Preserves the pre-W2 call-site shape inside `descriptors()`.
        var notionPageId: String { source.notionPageIdOrEmpty }

        enum CodingKeys: String, CodingKey {
            case name, source, notionPageId, enabled, visibility
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            // W2 D2: union-of-both decode — prefer the new `source`
            // field, fall back to legacy `notionPageId`.
            if let decoded = try c.decodeIfPresent(SkillSource.self, forKey: .source) {
                source = decoded
            } else if let legacy = try c.decodeIfPresent(String.self, forKey: .notionPageId) {
                source = .notion(pageId: legacy)
            } else {
                source = .notion(pageId: "")
            }
            // Legacy rows may omit `enabled`; SkillsManager treats a
            // missing flag as enabled — mirror that exactly.
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            // Missing/legacy/unknown visibility ⇒ `.standard` (the
            // conservative default — a row is never silently promoted
            // into the palette). `SkillVisibility`'s custom decoder
            // already maps adminOnly→standard and unknown→standard.
            visibility = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibility) ?? .standard
        }
    }

    /// Reads the raw persisted registry blob. A `@Sendable` closure (not a
    /// stored `UserDefaults`) because `CommandDescriptorProviding` is
    /// `Sendable` and `UserDefaults` is NOT `Sendable` under Swift 6
    /// strict concurrency. The default closure reads
    /// `UserDefaults.standard[storageKey]` lazily, at call time, so a
    /// registry write by `manage_skill` / the Settings UI after the
    /// palette is constructed is still observed (the provider holds no
    /// snapshot). Tests inject a closure over a private suite — zero
    /// process-global / network coupling.
    private let readBlob: @Sendable () -> Data?

    /// Default: read the shared `BridgeDefaults.skills` from
    /// `UserDefaults.standard` at every `descriptors()` call.
    public init(storageKey: String = BridgeDefaults.skills) {
        self.readBlob = { UserDefaults.standard.data(forKey: storageKey) }
    }

    /// Test/diagnostic seam: read from a NAMED `UserDefaults` suite. Only
    /// the suite name (a `String`) and key are captured — both `Sendable`;
    /// the suite is resolved lazily inside the closure (the suite-name
    /// instance is process-shared, so a test that seeds
    /// `UserDefaults(suiteName: name)` is observed here). This keeps the
    /// struct `Sendable` without capturing a `UserDefaults`.
    public init(suiteName: String, storageKey: String = BridgeDefaults.skills) {
        self.readBlob = {
            UserDefaults(suiteName: suiteName)?.data(forKey: storageKey)
        }
    }

    /// Lowest-level seam: inject the blob reader directly.
    public init(readBlob: @escaping @Sendable () -> Data?) {
        self.readBlob = readBlob
    }

    /// Decode the persisted registry and project the ENABLED entries onto
    /// palette descriptors. Pure read; never mutates the registry.
    ///
    /// An entry whose `notionPageId` is blank is dropped (a page-id-less
    /// row can never resolve a body on Enter — keeping it would only
    /// produce a guaranteed `.unavailable`, so it is not a selectable
    /// command). The `name` is used as BOTH the descriptor name and its
    /// abbreviation/trigger because the registry has no separate short
    /// form and `CommandPaletteSearch` ranks the abbreviation strongest.
    public func descriptors() async -> [CommandDescriptor] {
        guard
            let data = readBlob(),
            let entries = try? JSONDecoder().decode([RegistrySkillEntry].self, from: data)
        else {
            return []
        }
        return entries.compactMap { entry in
            // cmd-ux W3: the palette now shows ONLY skills explicitly
            // marked `.command` (and enabled). Routing/standard skills
            // are no longer palette rows — visibility is the selector.
            // `fetch_skill` is unaffected (name-based, visibility-
            // agnostic): a `.command` skill is still fetchable by name,
            // and a routing/standard skill is still NOT in the palette.
            guard entry.enabled, entry.visibility == .command else { return nil }
            // W2 D2: palette commit goes via Notion /markdown — only
            // `.notion(pageId:)` sources are selectable. File-source
            // skills surface in `list_routing_skills` / `fetch_skill`,
            // not the hot-key palette (no page id to fetch).
            guard case .notion(let rawPageId) = entry.source else { return nil }
            let pageId = rawPageId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageId.isEmpty else { return nil }
            let name = entry.name
            return CommandDescriptor(
                id: pageId,
                name: name,
                abbreviation: name
            )
        }
    }
}
