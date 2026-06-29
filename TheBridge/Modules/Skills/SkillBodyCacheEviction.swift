// SkillBodyCacheEviction.swift — Bridge (Wave 3 FB)
// Evict the persistent skill body cache when Notion writes touch a configured skill page.

import Foundation

public enum SkillBodyCacheEviction {
    /// When `pageId` matches a skill configured in `SkillsManager`, evict its
    /// body cache entry so the next `fetch_skill` re-reads from Notion.
    public static func evictIfConfiguredSkillPage(_ rawPageId: String) async {
        let normalized = NotionClient.normalizePageId(rawPageId)
        guard normalized.count >= 32 else { return }

        let isConfigured = await MainActor.run {
            SkillsManager().skills.contains { skill in
                let pid = skill.notionPageId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pid.isEmpty else { return false }
                return NotionClient.normalizePageId(pid) == normalized
            }
        }
        guard isConfigured else { return }
        await SkillBodyCacheStore.shared.evict(pageId: normalized)
    }
}
