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
    struct RegistrySkillEntry: Codable, Sendable {
        let name: String
        let notionPageId: String
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case name, notionPageId, enabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            notionPageId = try c.decode(String.self, forKey: .notionPageId)
            // Legacy rows may omit `enabled`; SkillsManager treats a
            // missing flag as enabled — mirror that exactly.
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
            guard entry.enabled else { return nil }
            let pageId = entry.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
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
