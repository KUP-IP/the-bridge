// BridgeModuleRegistry.swift — v3.0 prep 0.4 (PKT — module-registrar remediation)
// NotionBridge · Server
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
    ///   - includeStripe: production passes `true` (StripeMcpModule talks to
    ///     the network); the test harnesses pass `false` and intentionally
    ///     omit it. This is the only module that differs between contexts.
    ///   - registerSession: invoked at SessionModule's canonical position.
    ///     Production passes a closure that registers SessionModule with its
    ///     diagnosticsProvider; tests pass a closure that registers it with
    ///     only an auditLog.
    public static func registerStaticFeatureModules(
        on router: ToolRouter,
        includeStripe: Bool,
        registerSession: (ToolRouter) async -> Void
    ) async {
        await ShellModule.register(on: router)
        await FileModule.register(on: router)
        await registerSession(router)
        await MessagesModule.register(on: router)
        await SystemModule.register(on: router)
        await ContactsModule.register(on: router)
        await NotionModule.register(on: router)
        await ScreenModule.register(on: router)
        await ScreenModule.registerRecording(on: router)
        await ScreenModule.registerAnalyze(on: router)
        await AccessibilityModule.register(on: router)
        await AppleScriptModule.register(on: router)
        await ChromeModule.register(on: router)
        await SkillsModule.register(on: router)
        await CredentialModule.register(on: router)
        await PaymentModule.register(on: router)
        if includeStripe {
            await StripeMcpModule.register(on: router)
        }
        await ConnectionsModule.register(on: router)
        await JobsModule.register(on: router)
        await DevModule.register(on: router)
        await BgProcessModule.register(on: router)
        await DevServerModule.register(on: router)
        await GhModule.register(on: router)
        await GitModule.register(on: router)
        await LspModule.register(on: router)
        await CodeEditModule.register(on: router)
        await WranglerModule.register(on: router)
        await SpotlightModule.register(on: router)
        await SyntheticInputModule.register(on: router)
        await MouseClickModule.register(on: router)
        await CGEventModule.register(on: router)
        await PasteboardHistoryModule.register(on: router)
        await PlaywrightModule.register(on: router)
        await VitestModule.register(on: router)
        await LighthouseModule.register(on: router)
        await ArtifactModule.register(on: router)
        await SnippetsModule.register(on: router)
    }
}
