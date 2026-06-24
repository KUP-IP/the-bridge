// Version.swift – Single source of truth for app versioning
// TheBridge · Config
//
// All runtime version references should use AppVersion constants.
// Info.plist CFBundleShortVersionString must be kept in sync (stamped at build time or manually).
// Hardcoded fallback strings (e.g. ?? "1.1.0") are eliminated — use AppVersion.marketing instead.
//
// VERSIONING (operator rule, 2026-06-15): +1 patch per PUBLISHED INSTALL
// (release), NOT per branch — several task branches can merge to main and ship
// together as one install increment. Single-digit segments roll at 9 (3.8.9→
// 3.9.0, 3.9.9→4.0.0), never double digits. THIS install is 3.8.0; next is 3.8.1 (3.7.10–3.7.12
// were pre-rule legacy). 4.0.0 = sale-ready "V4", reached incrementally. Build
// (CFBundleVersion) monotonic +1. See AGENTS.md "Release flow" + versioning memory.

import Foundation

/// Central version constants for The Bridge.
public enum AppVersion {
    /// Marketing version (CFBundleShortVersionString equivalent).
    /// Format: MAJOR.MINOR.PATCH (Semantic Versioning).
    public static let marketing = "3.8.2"

    /// Build number (CFBundleVersion equivalent).
    /// Monotonically increasing integer per release.
    /// v3.7 WS-D (PKT-921): 43 → 44 — heartbeat wiring + cloud-gated
    /// `bridge_status` MCP tool + tools/list cloud conditional.
    /// v3.7.0 release: 44 → 45 — marketing 3.6.1 → 3.7.0; Info.plist CFBundleVersion reconciled to 45.
    /// v3.7.1 release (PKT-933): 45 → 46 — Remote Access "coming soon" guard +
    ///   toggle re-entrancy fix (so the published build carries the guard that
    ///   the 3.7.0 DMG predates).
    /// v3.7.6: 50 → 51 — system-tethered Light/Dark theme (adaptive BridgeTokens;
    ///   removed all 9 force-dark mechanisms; Dark unchanged, Light = titanium).
    /// v3.7.7: 51 → 52 — integration of 14 post-3.7.6 branches (module-scoped tool
    ///   grants + revoke UI, on-device automation tools, Notion/credentials
    ///   ergonomics, Sparkle + AX crash resilience).
    /// v3.7.8: 52 → 53 — two-chat integration: PKT-810 cloud connector (public PRM
    ///   + server-side token exchange + local↔cloud coexistence), credential +
    ///   securitygate fixes, memory Wave 2, migration-safe keychain service,
    ///   ⌃⌘B default hotkey + true reg-state, skill body cache + offline fetch,
    ///   emoji skill icons (Settings 10→7 redesign already on main).
    /// v3.7.9: 53 → 54 — cloud connector fixes: a valid OAuth JWT was 403'd by
    ///   the legacy loopback static-bearer re-check in the session pipeline
    ///   (now skipped for connector-authed sessions); and the ConnectorScopeGate
    ///   denied every cloud tools/call (scope-less WorkOS tokens) — now default
    ///   full tool parity for authenticated connector tokens, with the per-tool
    ///   SecurityGate as the guardrail (strictScopes opt-in retained).
    /// v3.7.10: 54 → 56 — reconcile two divergent connector reworks on the
    ///   v3.7.9 base (keeps the keychain UX fix + PKT-810 loopback coexistence).
    ///   Three fixes so Claude web + local Claude + ChatGPT all work on one build:
    ///   (1) PRM advertises the AuthKit OpenID scopes so ChatGPT can authorize
    ///       (empty/Bridge-only scopes_supported blocked it with invalid_scope);
    ///   (2) OAuth connector clients get COMPACT JSON-RPC responses instead of
    ///       the SDK's SSE framing — ChatGPT's importer cannot parse SSE and 503'd
    ///       every tools/call with -32603 "data couldn't be read" (claude.ai
    ///       tolerates SSE, which is why only ChatGPT broke); local desktop keeps
    ///       the SDK path via the loopback fallback;
    ///   (3) v3.7.9's loopback-static-bearer fallback retained for local↔cloud.
    /// v3.7.11: 56 → 57 — tool-surface resurface (223→163 tools across 26
    ///   families: pruned Chrome/Stripe/dev-loop-IDE-CI layer + deprecation
    ///   shims) + compact-default tools_list. NB: the bump commit (bb24000)
    ///   set Info.plist CFBundleVersion to 57 + marketing 3.7.10→3.7.11 but
    ///   left this `build` constant at 56 — re-synced here so the SSOT, the
    ///   in-app display, and the bundle agree (Sparkle compares CFBundleVersion).
    /// v3.7.12: 57 → 58 — v4 "Liquid Glass, evolved" UI redesign (foundation
    ///   tokens + component layer + 7 settings pages + 3 surfaces); ~95% design
    ///   compliance vs the Claude Design handoff, zero functional regression (1884/0).
    /// v3.8.0: 58 → 59 — first install under the +1-per-published-install rule;
    ///   post-v3.7.12 refinements shipped together: Command Bridge liquid-glass
    ///   redesign (Golden-Gate round orbs + Spotlight-mimic even-frost bar, draggable
    ///   with session memory + keyboard traversal into recents), security hardening
    ///   (path-traversal / metachar / Stripe tokenization), IA restructure (Commands
    ///   its own page + Standing Orders → Connection handshake), wave page conformance,
    ///   titanium glass-depth fix. test-floor 1884 → 1930, zero regression.
    /// v3.8.1: 59 → 60 — PKT-810 R5 hardening (security): close the legacy-route
    ///   tunnel bypass. The legacy SSE transport (GET /sse + POST /messages,
    ///   PKT-336) is dispatched in the NIO handler BEFORE the /mcp connector-auth
    ///   gate, and cloudflared forwards every path to :9700 (no path scoping) —
    ///   so a Cloudflare-tunnel caller could open an UNAUTHENTICATED legacy MCP
    ///   session and drive the full tool surface, bypassing the entire OAuth gate.
    ///   Now tunnel-origin (Cf-*) legacy requests are refused (403); direct
    ///   loopback (older local SSE clients) is unaffected. Also bundles the
    ///   config-driven Data-Source Registry (9 `registry_*` tools) that landed on
    ///   main post-v3.8.0. test-floor 2158 → 2163, zero regression.
    /// v3.8.2: 60 → 61 — Data-Source Registry entity-management completion:
    ///   + registry_remove_entity (symmetric to registry_add_entity — forgets a
    ///   local entity binding + evicts its row cache, no Notion write; .request
    ///   tier; seeded Skills entity guarded behind explicit confirm) + a "Remove"
    ///   affordance in the Data Sources pane. staticFeatureModuleToolCount 171 →
    ///   172. test-floor 2163 → 2169, zero regression.
    public static let build = "61"

    /// Combined display string for UI and logs.
    public static var display: String { "\(marketing) (\(build))" }

    /// Fallback for Bundle.main lookups — use this instead of hardcoded strings.
    public static var resolved: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
    }
}

/// Protocol and networking constants for The Bridge.
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
    /// Sprint A (mcp-builder Phase 2): 159 + 13 net = 172. Delta:
    ///   − 4 deprecated removals (ax_focused_app deprecated-shim, ax_find_element, ax_element_info, notion_block_read)
    ///   − 1 dev_module_info (silent removal; echo was builtin so excluded already)
    ///   + 5 skill_* primitives from manage_skill 11-action split (manage_skill kept as 1-cycle alias)
    ///   + 3 git_worktree_{list,add,remove} from git_worktree split (git_worktree kept as 1-cycle alias)
    ///   + 1 ax_inspect (rename of ax_query; ax_query kept as 1-cycle alias)
    ///   + 1 ax_focused_app REVIVED as new dedicated tool (item 11; not a deprecation shim)
    ///   + 3 gh_*_create / gh_actions_runs_list renames (3 old names kept as aliases)
    ///   + 1 chrome_tabs_list rename (chrome_tabs kept as alias)
    ///   + 1 skills_routing_list rename (list_routing_skills kept as alias)
    ///   + 1 file_edit new (file_str_replace + file_apply_patch kept as aliases)
    ///   + 2 jobs_pause_all / jobs_resume_all reinstated as catalog-present aliases routing to job_pause/_resume all:true
    /// Aliases all carry one-cycle deprecation prefix; full removal in 3.5.0 (Sprint B's release in the patch ladder).
    ///   + 4 standing_orders_{list,read,save,delete} (PKT-931, v3.7·B): new standing_orders family.
    ///   + 6 reminders_* tools (PKT-957, v3.7·D): reminders_lists/list/create/update/complete/delete.
    /// v3.7 review-batch integration: 172 + 4 (standing_orders) + 6 (reminders) = 182.
    ///   + 2 shortcuts_* tools (PKT-959, v3.7·F): shortcuts_list/run over the /usr/bin/shortcuts CLI.
    ///   + 5 mail_* tools (PKT-961, v3.7·H): mail_list/read/search/draft/send (Apple Mail).
    ///   + 6 notes_* tools (PKT-960, v3.7·G): notes_list/read/search/create/update/delete (Apple Notes).
    /// v3.7 Wave-1 integration: 182 + 2 (shortcuts) + 5 (mail) + 6 (notes) = 195.
    ///   + 5 calendar_* tools (PKT-962, v3.7·I): calendar_list/events/create/update/delete
    ///     (native EventKit .event entities; reuses v3.7·D's store + calendars entitlement).
    /// v3.7·I (PKT-962): 195 + 5 (calendar) = 200.
    /// v3.7 WS-D (PKT-921): static count UNCHANGED by WS-D. `bridge_status` is
    ///   registered ONLY when `BridgeDefaults.cloudAccessEnabled` (via
    ///   `BridgeModuleRegistry.registerCloudStatusTool`, NOT
    ///   `registerStaticFeatureModules`), so it deliberately does NOT count
    ///   toward this always-present static surface. A default (cloud-off)
    ///   install exposes exactly these 200 module tools (195 Wave-1 + 5 calendar).
    /// Unified Memory foundation (Wave 1): 200 + 2 (memory_remember +
    ///   memory_recall) = 202.
    /// FB-AUTOMATION (on-device automation kit): + 2 (bridge_settings_navigate +
    ///   bridge_focus_settings, new `automation` family) = 204.
    /// FB [buildtools]: + 3 swift_* / make_run build-tool wrappers
    ///   (swift_build + swift_test + make_run, module "swift") that wrap
    ///   BgProcessRuntime so long builds/tests don't hit the ~60s transport
    ///   cap: 204 + 3 = 207.
    /// FB-notionwrite: + 1 (notion_page_edit — surgical in-place body edit,
    ///   joins the existing `notion` family) = 208.
    /// fb-permissions: + 1 (permissions_status — unified TCC grant probe, new
    ///   `permissions` family) = 209.
    /// Unified Memory Wave 2 (PKT-977): + 2 (memory_export + memory_import) = 211.
    /// Tool-surface resurface (v3.7.11, 2026-06-14): −50 static tools. Pruned the
    ///   Chrome family (6); the dev-loop/IDE-CI layer (lsp 6, vitest/playwright/
    ///   lighthouse 3, devserver+port_inspect 4, bg_process 5, wrangler 1,
    ///   swift_build/test/make_run 3, file_watch+tree_sitter_query 2,
    ///   git_worktree×4+git_merge 5); payment_execute (1); screen_analyze (1); and
    ///   residual deprecation shims (ax_query, gh_{pr,issue,actions}_* old names ×3,
    ///   list_routing_skills, manage_skill, jobs_pause_all/resume_all ×2,
    ///   file_apply_patch, file_str_replace, notion_code_block_append,
    ///   notion_connections_list, bridge_focus_settings = 12). 211 − 50 = 161.
    ///   The Stripe family was removed entirely but was already excluded from this
    ///   static count (it registered via the network-gated `includeStripe` path).
    /// PKT-1005 (Pillar A, 2026-06-17): + 1 (bridge_open_settings — deterministic
    ///   cold-open of the Settings window, joins the existing `automation` family).
    ///   161 + 1 = 162.
    /// Data-Source Registry (2026-06-17): + 9 (registry_entities/add_entity/
    ///   introspect/list/get/create/update/delete/possess — the new `registry`
    ///   family: one generic CRUD set + entity registration + introspect + possess
    ///   serving every configured entity). 162 + 9 = 171.
    /// Registry entity-management completion (2026-06-18): + 1 (registry_remove_entity
    ///   — the symmetric counterpart to registry_add_entity; drops a local
    ///   entity binding + evicts its cache, no Notion write). 171 + 1 = 172.
    /// Tool-Dev (PRJCT-2754): + 3 (bg_run/bg_poll/bg_kill — detached background
    ///   shell execution, the new `bgprocess` family: file-backed stateless job
    ///   state under bg-process/<ts-uuid>.{log,done,pid}; bg_run returns
    ///   immediately, bg_poll reports running/exited/terminated, bg_kill
    ///   SIGTERMs/SIGKILLs a running job). 172 + 3 = 175.
    /// Voice Memos curator (2026-06-24): +2 (voice_memo_list + voice_memo_process).
    /// 175 + 2 = 177.
    /// Local Ollama (2026-06-24): +2 (ollama_health + ollama_list_models).
    /// 177 + 2 = 179.
    /// Voice Memos review (2026-06-24): +2 (voice_memo_review_list + voice_memo_review_dismiss).
    /// 179 + 2 = 181.
    /// Voice Memos review resolve (2026-06-24): +2 (voice_memo_review_resolve + voice_memo_transcript_refresh).
    /// 181 + 2 = 183.
    public static let staticFeatureModuleToolCount = 183

    /// Distinct `module` string families included in `staticFeatureModuleToolCount` (Stripe and `builtin` excluded).
    /// v2.2 · 0.1 (PKT-738): 15 + 1 (dev) = 16.
    /// v2.2 · 2.3 W2 (PKT-745): unchanged at 16 — lsp_session_list joins existing `dev` family.
    /// v2.2 · integration closeout: + jobs + cursor + computer = 19.
    /// v2.3 · 0.1 (PKT-804): − cursor family = 18.
    /// v2.3 · WS-D (PKT-2135a9e9): + snippets family = 19.
    /// v3.7·B (PKT-931): + standing_orders family.
    /// v3.7·D (PKT-957): + reminders family.
    /// v3.7 review-batch integration: 19 + 1 (standing_orders) + 1 (reminders) = 21.
    /// v3.7·F (PKT-959): + shortcuts family.
    /// v3.7·H (PKT-961): + mail family.
    /// v3.7·G (PKT-960): + notes family.
    /// v3.7 Wave-1 integration: 21 + 1 (shortcuts) + 1 (mail) + 1 (notes) = 24.
    /// v3.7·I (PKT-962): + calendar family = 25.
    /// Unified Memory foundation (Wave 1): + memory family = 26.
    /// FB-AUTOMATION: + automation family (bridge_settings_navigate +
    ///   bridge_focus_settings) = 27.
    /// FB [buildtools]: + swift family (swift_build/swift_test/make_run) = 28.
    /// fb-permissions: + permissions family (permissions_status) = 29.
    /// Tool-surface resurface (v3.7.11, 2026-06-14): − chrome, − payment, − swift
    ///   families (their tools were fully pruned); dev family survives via
    ///   git/gh/file_edit/code_search/http_fetch. 29 − 3 = 26.
    /// Data-Source Registry (2026-06-17): + registry family = 27.
    /// Tool-Dev (PRJCT-2754): + bgprocess family (bg_run/bg_poll/bg_kill) = 28.
    /// Voice Memos curator (2026-06-24): + voice family = 29.
    /// Local Ollama (2026-06-24): + ollama family = 30.
    public static let staticFeatureModuleFamilyCount = 30
}
