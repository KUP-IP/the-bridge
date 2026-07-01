// ToolSurfaceCoverageAuditTests.swift — meta-audit: every static tool referenced in tests
// TheBridge · Tests
//
// Fails if a registered static tool name never appears quoted in TheBridgeTests/.

import Foundation
import TheBridgeLib

private let suiteAuditToolSets: [Set<String>] = [
    // DevSuiteAuditTests.swift expectedDevTools (representative superset check via module tests)
    // VoiceMemoSuiteAuditTests explicit set:
    [
        "voice_memo_list", "voice_memo_process", "voice_memo_review_list",
        "voice_memo_review_dismiss", "voice_memo_review_resolve", "voice_memo_transcript_refresh",
        "voice_memo_get", "voice_memo_commit", "voice_memo_triage_open", "voice_memo_triage_await",
    ],
    // Messages module (registration count lock in MessagesModuleTests + suite audit)
    [
        "messages_search", "messages_chat", "messages_send", "messages_content",
        "messages_participants", "messages_recent",
    ],
]

private func loadAllTestSource() -> String {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var combined = ""
    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for url in files where url.pathExtension == "swift" && url.lastPathComponent != "ToolSurfaceCoverageAuditTests.swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                combined += text
            }
        }
    }
    return combined
}

func runToolSurfaceCoverageAuditTests() async {
    print("\n\u{1F50E} Tool surface coverage meta-audit")

    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    let log = AuditLog()
    await BridgeModuleRegistry.registerStaticFeatureModules(on: router) { r in
        await SessionModule.register(on: r, auditLog: log)
    }
    let allTools = (await router.allRegistrations()).map(\.name).sorted()
    let suiteCovered = suiteAuditToolSets.reduce(into: Set<String>()) { $0.formUnion($1) }
    let testSource = loadAllTestSource()

    await test("Tool surface: static registry count matches BridgeConstants") {
        try expect(allTools.count == BridgeConstants.staticFeatureModuleToolCount,
                   "registry \(allTools.count) != constant \(BridgeConstants.staticFeatureModuleToolCount)")
    }

    await test("Tool surface: every static tool quoted in TheBridgeTests or suite audit") {
        var gaps: [String] = []
        for name in allTools {
            if suiteCovered.contains(name) { continue }
            if testSource.contains("\"\(name)\"") { continue }
            // JobsModuleTests (and similar) reference tools in test titles: `job_get: …`
            if testSource.contains("\(name):") { continue }
            gaps.append(name)
        }
        if !gaps.isEmpty {
            throw TestError.assertion("tools without test reference (\(gaps.count)): \(gaps.prefix(12).joined(separator: ", "))\(gaps.count > 12 ? "…" : "")")
        }
    }
}
