// ProductSurfaceGutTests.swift — #284
// SOURCE-ready: product Jobs scheduler + local-model connection are gone.

import Foundation
import MCP
import TheBridgeLib

func runProductSurfaceGutTests() async {
    print("\n🧹 Product surface gut (#284 Jobs + local-model connection)")

    await test("#284: Settings IA has no Jobs section") {
        let raw = SettingsSection.allCases.map(\.rawValue)
        let labels = SettingsSection.allCases.map(\.displayName)
        try expect(SettingsSection.allCases.count == 8, "expected 8 sections, got \(SettingsSection.allCases.count)")
        try expect(!raw.contains(where: { $0.localizedCaseInsensitiveContains("job") }),
                   "rawValues still mention Jobs: \(raw)")
        try expect(!labels.contains(where: { $0.localizedCaseInsensitiveContains("job") }),
                   "display names still mention Jobs: \(labels)")
        try expect(SettingsSection(rawValue: "Jobs") == nil, "Jobs rawValue must not decode")
    }

    await test("#284: VoiceMemoCuratorMode has no local case") {
        let raw = VoiceMemoCuratorMode.allCases.map(\.rawValue)
        try expect(raw == ["auto", "heuristics", "agent", "cloud"],
                   "curator modes drifted: \(raw)")
        try expect(VoiceMemoCuratorMode(rawValue: "local") == nil,
                   "local must not be a live curator mode")
    }

    await test("#284: persisted curatorMode local maps to heuristics") {
        let key = BridgeDefaults.voiceMemoCuratorMode
        let prior = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("local", forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try expect(VoiceMemoCuratorRouter.effectiveMode() == .heuristics,
                   "retired local persists as heuristics")
    }

    await test("#284: POST /jobs/*/run is notFound") {
        try expect(
            MCPHTTPRoute.classify(method: "POST", path: "/jobs/abc/run", endpoint: "/mcp") == .notFound,
            "legacy job callback must 404")
        try expect(
            MCPHTTPRoute.classify(method: "GET", path: "/jobs/abc/run", endpoint: "/mcp") == .notFound,
            "GET job callback must 404")
    }

    await test("#284: job_* and ollama_* annotations are gone") {
        let retired = [
            "job_create", "job_get", "job_list", "job_delete", "job_pause",
            "job_resume", "job_history", "job_templates", "job_run", "job_update",
            "job_duplicate", "job_export", "job_import",
            "ollama_health", "ollama_list_models",
        ]
        for name in retired {
            try expect(ToolAnnotationCatalog.annotations(for: name) == nil,
                       "\(name) must not remain in ToolAnnotationCatalog")
        }
    }

    await test("#284: ModuleGroup has no jobs group") {
        let ids = ModuleGroupID.allCases.map(\.rawValue)
        try expect(!ids.contains("jobs"), "ModuleGroupID.jobs must be gone: \(ids)")
        try expect(ModuleGroupDerivation.resolve(toolName: "job_create") == .system,
                   "retired job_* prefix folds to .system")
    }

    await test("#284: local-model auto-enhance and titles stay closed") {
        try expect(!MemoryHubMemoTitler.localTitleEnabled(), "local titles stay closed")
        try expect(!MemoryHubPreview.mayAutoEnhanceLocal(localEnabled: true),
                   "local auto-enhance stays closed even if a caller passes true")
    }

    await test("#284: static registry has no scheduler or ollama tools") {
        let securityGate = SecurityGate(approvalProvider: TestSecurityApprovalProvider())
        let auditLog = AuditLog()
        let router = ToolRouter(securityGate: securityGate, auditLog: auditLog)
        await BridgeModuleRegistry.registerStaticFeatureModules(
            on: router,
            registerSession: { sessionRouter in
                await SessionModule.register(on: sessionRouter, auditLog: auditLog)
            }
        )
        let all = await router.allRegistrations()
        let names = all.map(\.name)
        try expect(!names.contains(where: { $0.hasPrefix("job_") || $0.hasPrefix("jobs_") }),
                   "job_* tools still registered: \(names.filter { $0.hasPrefix("job_") || $0.hasPrefix("jobs_") })")
        try expect(!names.contains(where: { $0.hasPrefix("ollama_") }),
                   "ollama_* tools still registered: \(names.filter { $0.hasPrefix("ollama_") })")
        try expect((await router.registrations(forModule: "scheduler")).isEmpty,
                   "scheduler family must be empty")
        try expect((await router.registrations(forModule: "ollama")).isEmpty,
                   "ollama family must be empty")
        try expect(all.count == BridgeConstants.staticFeatureModuleToolCount,
                   "static count \(all.count) != \(BridgeConstants.staticFeatureModuleToolCount)")
    }
}
