// BridgeModuleRegistry.swift — v3.0 prep 0.4 (PKT — module-registrar remediation)
// TheBridge · Server
//
// Single source of truth for the static feature-module registration surface.
// This list was previously hand-maintained in triplicate:
//   - ServerManager.setup()            (production: includes StripeMcpModule)
//   - EndToEndTests.swift              (test: omits StripeMcpModule — network-dependent)
//   - ToolAnnotationAuditTests.swift   (test: omits StripeMcpModule)
// The three copies drifted (WS-B's annotation audit caught one slip; the
// registration counts diverged 34 vs 36). All three now call this one
// function so a module added in one place is added everywhere, in one
// canonical order.
//
// Behavior-preserving by construction: the order below is the exact order
// ServerManager.setup() used, and StripeMcpModule keeps its original
// position behind `includeStripe`. SessionModule is the only registration
// whose call signature varies by context (production supplies a
// diagnosticsProvider closure that captures the live SSE server; the test
// harnesses pass only an auditLog) — the caller owns that one call via the
// `registerSession` hook; the registry owns ordering.

import Foundation

public enum BridgeModuleRegistry {

    /// Registers the canonical static feature-module surface, in stable order.
    ///
    /// - Parameters:
    ///   - router: the tool router to register into.
    ///   - registerSession: invoked at SessionModule's canonical position.
    ///     Production passes a closure that registers SessionModule with its
    ///     diagnosticsProvider; tests pass a closure that registers it with
    ///     only an auditLog.
    public static func registerStaticFeatureModules(
        on router: ToolRouter,
        registerSession: (ToolRouter) async -> Void
    ) async {
        await ShellModule.register(on: router)
        await BgProcessModule.register(on: router)         // Tool-Dev (PRJCT-2754): bg_run/bg_poll/bg_kill detached background execution (3 tools)
        await FileModule.register(on: router)
        await registerSession(router)
        await MessagesModule.register(on: router)
        await MailModule.register(on: router)
        await NotesModule.register(on: router)
        await SystemModule.register(on: router)
        await ContactsModule.register(on: router)
        await RemindersModule.register(on: router)
        await CalendarModule.register(on: router)
        await NotionModule.register(on: router)
        await ScreenModule.register(on: router)
        await ScreenModule.registerRecording(on: router)
        await AccessibilityModule.register(on: router)
        await AppleScriptModule.register(on: router)
        await SkillsModule.register(on: router)
        await CredentialModule.register(on: router)
        await ConnectionsModule.register(on: router)
        await JobsModule.register(on: router)
        await DevModule.register(on: router)
        await GhModule.register(on: router)
        await GitModule.register(on: router)
        await CodeEditModule.register(on: router)
        await SpotlightModule.register(on: router)
        await SyntheticInputModule.register(on: router)
        await MouseClickModule.register(on: router)
        await CGEventModule.register(on: router)
        await PasteboardHistoryModule.register(on: router)
        await ArtifactModule.register(on: router)
        await SnippetsModule.register(on: router)
        await StandingOrdersModule.register(on: router)
        await ShortcutsModule.register(on: router)
        await MemoryModule.register(on: router)
        await RegistryModule.register(on: router)          // Data-Source Registry: generic CRUD + add/remove_entity + introspect + possess (10 tools)
        await VoiceMemoModule.register(on: router)       // Voice Memos curator: voice_memo_list + voice_memo_process (2 tools)
        await OllamaModule.register(on: router)          // Local Ollama: ollama_health + ollama_list_models (2 tools)
        await BridgeAutomationModule.register(on: router) // FB-AUTOMATION: bridge_settings_navigate
        await PermissionsModule.register(on: router)       // fb-permissions: permissions_status
    }

    /// WS-D (PKT-921): register the cloud-gated `bridge_status` tool.
    ///
    /// Kept OUT of `registerStaticFeatureModules` on purpose: `bridge_status`
    /// is conditional on `BridgeDefaults.cloudAccessEnabled`, so it must not
    /// inflate `BridgeConstants.staticFeatureModuleToolCount` (which counts the
    /// always-present surface) nor trip the registry's
    /// every-tool-has-an-annotation / no-duplicate guards. The caller (e.g.
    /// `ServerManager.setup()`) invokes this ONLY when cloud access is enabled,
    /// passing the live `BridgeCloudManager` whose `state` the handler reads.
    public static func registerCloudStatusTool(
        on router: ToolRouter,
        manager: BridgeCloudManager
    ) async {
        await CloudStatusModule.register(on: router, manager: manager)
    }
}
