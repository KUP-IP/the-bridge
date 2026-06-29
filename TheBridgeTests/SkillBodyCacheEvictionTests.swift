// SkillBodyCacheEvictionTests.swift — Wave 3 FB (fetch_skill stale cache)
// TheBridge · Tests

import Foundation
import MCP
import TheBridgeLib

private let skillsDefaultsKey = "com.notionbridge.skills"

private func evictionSampleBody(pageId: String, markdown: String) -> CachedSkillBody {
    CachedSkillBody(
        pageId: pageId, markdown: markdown, title: "Demo", url: "https://www.notion.so/demo",
        properties: .object([:]), lastEditedTime: "2026-06-11T10:00:00.000Z",
        writtenAt: Date(timeIntervalSince1970: 1_700_000_000), ttlHours: 24, callCount: 1
    )
}

private func withTempHomeEviction(_ body: () async throws -> Void) async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-skill-evict-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let priorSkills = UserDefaults.standard.data(forKey: skillsDefaultsKey)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        if let priorSkills {
            UserDefaults.standard.set(priorSkills, forKey: skillsDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: skillsDefaultsKey)
        }
        try? FileManager.default.removeItem(at: tmp)
    }
    try await body()
}

func runSkillBodyCacheEvictionTests() async {
    print("\n\u{1F9F9} SkillBodyCacheEviction (Notion write → body cache evict)")

    await test("evictIfConfiguredSkillPage removes cached body for configured skill") {
        try await withTempHomeEviction {
            let pageId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            await MainActor.run {
                _ = SkillsManager().addSkill(name: "demo-skill-evict", notionPageId: pageId)
            }
            let entry = evictionSampleBody(pageId: pageId, markdown: "# stale")
            try await SkillBodyCacheStore.shared.write(entry)

            await SkillBodyCacheEviction.evictIfConfiguredSkillPage(pageId)
            try expect(await SkillBodyCacheStore.shared.read(pageId: pageId) == nil, "expected cache evicted")
        }
    }

    await test("evictIfConfiguredSkillPage is no-op for non-skill pages") {
        try await withTempHomeEviction {
            UserDefaults.standard.removeObject(forKey: skillsDefaultsKey)
            let pageId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            let entry = evictionSampleBody(pageId: pageId, markdown: "# keep")
            try await SkillBodyCacheStore.shared.write(entry)

            await SkillBodyCacheEviction.evictIfConfiguredSkillPage(pageId)
            try expect(await SkillBodyCacheStore.shared.read(pageId: pageId) != nil, "non-skill page cache should remain")
        }
    }
}
