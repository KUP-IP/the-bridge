// Version.swift – Single source of truth for app versioning
// NotionBridge · Config
//
// All runtime version references should use AppVersion constants.
// Info.plist CFBundleShortVersionString must be kept in sync (stamped at build time or manually).
// Hardcoded fallback strings (e.g. ?? "1.1.0") are eliminated — use AppVersion.marketing instead.

import Foundation

/// Central version constants for NotionBridge.
public enum AppVersion {
    /// Marketing version (CFBundleShortVersionString equivalent).
    /// Format: MAJOR.MINOR.PATCH (Semantic Versioning).
    public static let marketing = "3.2.0"

    /// Build number (CFBundleVersion equivalent).
    /// Monotonically increasing integer per release.
    public static let build = "33"

    /// Combined display string for UI and logs.
    public static var display: String { "\(marketing) (\(build))" }

    /// Fallback for Bundle.main lookups — use this instead of hardcoded strings.
    public static var resolved: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
    }
}

/// Protocol and networking constants for NotionBridge.
public enum BridgeConstants {
    /// MCP (Model Context Protocol) version announced in the `initialize` handshake.
    public static let mcpProtocolVersion = "2025-06-18"
    /// Minimum macOS major version matching `Package.swift` deployment target.
    public static let minimumMacOSMarketing = "26+"
    /// `Notion-Version` header for all Notion REST API requests (`NotionClient`).
    public static let notionAPIVersion = "2026-03-11"
    /// Default SSE server port.
    public static let defaultSSEPort = 9700

    /// Tools registered by Swift `*Module` types only: excludes `builtin` (`echo`) and excludes Stripe MCP (dynamic).
    /// Keep in sync with `ServerManager.setup()` static module registrations and the E2E fixture.
    /// v1.9.5: 82 total (80 prior static tools + discussion/code-block Notion helpers).
    /// v2.2 · 0.1 (PKT-738): 82 + 1 (dev_module_info scaffold) = 83.
    /// v2.2 · 0.1.2 (PKT-755): 83 + 1 (ax_query, AccessibilityModule consolidation) = 84.
    /// v2.2 · 1.2 (PKT-750): 84 + 3 (code_search, file_str_replace, file_apply_patch) = 87.
    /// v2.2 · 0.2.2 (PKT-757): 87 + 1 (wrangler_d1_status) = 88.
    /// v2.2 · 3.3/3.3.1 (PKT-747/765): 88 + 5 (spotlight/input/pasteboard tools) = 93.
    /// v2.2 · 2.1/2.1.1 (PKT-740/784/786/788): 93 + 9 (git_* tools) = 102.
    /// v2.2 · 2.3/2.3.1 (PKT-745/777/789): 102 + 6 (lsp_* tools) = 108.
    /// v2.2 · integration closeout: 113 + 34 previously uncounted static dev/jobs/runner tools = 147.
    /// v2.2 · 3.1 (PKT-743): 147 + 7 artifact/diff helper tools = 154.
    /// v2.3 · 0.1 (PKT-804): − cursor (5 cursor_agent_* tools) = 149.
    /// v2.3 · WS-D (PKT-2135a9e9): + snippets (9 snippets_* tools) = 158.
    /// Note: jobs_pause_all / jobs_resume_all dropped; current JobsModule contributes 13 job_* tools.
    /// run-app re-platform: + notion_datasource_delete (NotionModule 23→24) = 159.
    public static let staticFeatureModuleToolCount = 159

    /// Distinct `module` string families included in `staticFeatureModuleToolCount` (Stripe and `builtin` excluded).
    /// v2.2 · 0.1 (PKT-738): 15 + 1 (dev) = 16.
    /// v2.2 · 2.3 W2 (PKT-745): unchanged at 16 — lsp_session_list joins existing `dev` family.
    /// v2.2 · integration closeout: + jobs + cursor + computer = 19.
    /// v2.3 · 0.1 (PKT-804): − cursor family = 18.
    /// v2.3 · WS-D (PKT-2135a9e9): + snippets family = 19.
    public static let staticFeatureModuleFamilyCount = 19
}
