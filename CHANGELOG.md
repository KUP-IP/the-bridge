# Changelog

## [2.2.0-0.2] — 2026-05-10 — Remediation: notion_file_upload (PKT-739)

### Fixed
- `notion_file_upload` send-phase endpoint (carryover from v1.9.5 B1) — the second-phase POST now targets the documented Notion API route `/v1/file_uploads/{id}/send` instead of the non-existent `/send_content`, which had been returning `400 invalid_request_url` for every upload regardless of MIME. Trace labels (`phase=send`) updated to match.

### Added
- `notion_file_upload` MIME guard — uploads with unrecognized extensions (which previously fell through to `application/octet-stream`) now fail fast with a clear error listing all supported extensions, instead of being rejected by the Notion API with a confusing 400 `validation_error` from `phase=create_upload`.

### Deferred to follow-up packet
- `wrangler_d1_status` binding-ambiguity tool — out of scope here; tool does not yet exist in the Bridge MCP and creating it from scratch (TOML parser + subprocess + tests) exceeds the 0.2 complexity envelope.

## [2.2.0-0.1.2] — 2026-05-10 — AX consolidation: ax_query (PKT-755)

### Added
- **`ax_query`** unified Accessibility query tool — single `.open`-tier tool with a discriminated-union schema replacing the three overlapping per-shape AX query tools. Required `mode` enum (`focused_app` / `find_element` / `element_info`) selects the query shape; optional `pid`, `role`, `title`, `label`, `path`, `maxDepth` apply per-mode. Output matches the legacy tool payloads exactly. Deferred from PKT-738 (per Reflow #1, 2026-05-10).

### Changed
- **Tool-count baseline** bumped from 83 to **84** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`ax_query`). `AccessibilityModule` tool count goes 5 → 6 (3 legacy shims retained as deprecated, plus `ax_tree`, `ax_perform_action`, and the new `ax_query`).

### Deprecated
- **`ax_focused_app`**, **`ax_find_element`**, **`ax_element_info`** — descriptions prefixed with `[DEPRECATED v2.2 · PKT-755 — prefer ax_query with mode='X']`. Handlers continue to return the same payload as before, but now route through shared payload helpers and inject a `_deprecated` warning marker (`"Tool deprecated in v2.2 (PKT-755). Prefer ax_query with mode='…'. This tool will be removed in v2.3."`). Tools remain in registry through the v2.3 hard-removal ramp.

### Unchanged
- **`ax_tree`** and **`ax_perform_action`** untouched.
- macOS 26 Tahoe Accessibility permission flow unchanged in scope (PKT-754 territory).

## [2.2.0-0.1] — 2026-05-10 — Pruning + dev/ scaffold (PKT-738)

### Added
- **`modules/dev/` Swift module scaffold** — new `DevModule` registered as the 15th static feature module. Surfaces in `notion_modules_list` and exposes a placeholder `dev_module_info` tool. Foundation for v2.2 dev primitives (code-edit, cursor/, computer/ helpers); real tools land in follow-up packets (PKT-364, PKT-365, …).

### Changed
- **Tool-count baseline** bumped from 82 to **83** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`dev_module_info` scaffold). Jobs kill-switch drops do not affect this count because `JobsModule` is registered after `StripeMcpModule` in `ServerManager.setup()` and excluded from the static surface (matches test setup).
- **Family count** bumped from 15 to **16** with the `dev` family.

### Deprecated
- **`notion_block_read`** — description prefixed with `[DEPRECATED v2.2 · PKT-738]`. Prefer `notion_page_read` for whole-page reads or `notion_block_update` for surgical edits. Tool remains in registry through the v2.3 ramp.

### Removed
- **`jobs_pause_all`** and **`jobs_resume_all`** mass kill-switches deregistered. Per-job `job_pause` / `job_resume` (or iterate `job_list`) replace them. Factory functions retained in `JobsModule` for potential reinstatement; no longer wired to the router.

### Deferred to follow-up packets (out of scope here)
- 25 Stripe long-tail tool deprecations (warn + shim → `stripe_api_execute`) — needs its own focused packet; Stripe MCP module is a remote proxy and shimming requires a wrapping layer.
- AX collapse: `ax_focused_app` + `ax_find_element` + `ax_element_info` → unified `ax_query` — this is a feature implementation, not a warning shim, and warrants its own packet.

## [1.9.5] — 2026-05-04

### Added
- **Shell execution hardening** — `shell_exec` now reports structured success/status/timeout/termination fields, output line counts/truncation metadata, environment overrides, login-shell opt-in, tilde-expanded working directories, and recovery hints for long-running/background commands.
- **Filesystem caps** — `file_list` supports `maxEntries`/`maxDepth` with truncation metadata; `file_search` supports `maxResults`/`timeoutSeconds` with scanned counts and narrowing hints.
- **Notion diagnostics** — file uploads can return safe phase trace entries for create-upload vs send-content; long comment/discussion text is preflighted against Notion's 2000-character rich-text limit before API calls.
- **Chrome recovery** — `chrome_tabs` preserves partial tab listings when individual windows/tabs fail and returns structured per-item errors; `chrome_navigate` returns activation/tab-refresh recovery hints for off-Space or churned-tab failures.

### Changed
- MCP formatted responses now flag structured `success: false`/error-status payloads as tool errors at the transport layer while preserving the JSON body for agent recovery.
- Operator/agent guidance now documents portable search fallbacks, Python-first patch scripts, Cloudflare Pages temp-cwd deploys, inline-only Notion comments, and shell timeout/output semantics.

### Fixed
- Removed a duplicate execution-notification argument in the tool router path while adding structured failure propagation.

## [1.9.4] — 2026-04-18

### Added
- **Jobs pane redesigned** — vertical stacked layout modeled on macOS System Settings. `HSplitView` master/detail replaced with `ScrollView` + `LazyVStack` of grouped cards. Tap a row to expand the editor inline (schedule, action-chain JSON, skip-on-battery, Run Now, Duplicate, Pause/Resume, Copy ID, Reveal Log, Delete).
- **Segmented status filter** (All · Active · Paused) at the top of the Jobs pane.
- **Footer toolbar** — Pause All / Resume All / Export / Import moved to a persistent bottom bar. Includes a live count chip (`N jobs · M active`) with correct pluralization.
- **+ New Job sheet** — primary creation flow from the Jobs header and the empty state. Cron validation + action-chain JSON validation inline.
- **97 tool descriptions rewritten** across 18 modules per the §16 audit to improve routing specificity and reduce cross-tool overlap.

### Changed
- **Settings window consolidation** — removed the duplicate SwiftUI `Settings { }` scene. A single `SettingsWindowController`-owned NSWindow is now the canonical Settings surface, with unified transparent titlebar, `setFrameAutosaveName("NotionBridgeSettings.v2")`, min 640×720, max 900×1100, default 720×900 — closer to Apple System Settings proportions.
- **Empty-state copy** — replaced `job_create tool` jargon with "Tap **New** to create a job, or import a job export file."

### Fixed
- **Two Settings windows opening simultaneously** — root cause was the coexistence of SwiftUI `Settings {}` and the custom `SettingsWindowController`, each creating its own NSWindow with the same title. Consolidated to a single window controller.
- **Pluralization bug in Jobs toolbar** — count chip now derives from the live list and uses correct singular/plural.
- **Toolbar overflow at <900 px** — header reduced to Title + Search + Sort + **+ New**; bulk actions moved to footer.

## [1.9.3] — 2026-04-15

### Changed
- Packaging bump alongside Sparkle / Notion module polish shipped in commit `9acabdb`. No behavior changes beyond what is captured in 1.9.2 + prior entries.

## [1.9.2] — 2026-04-13

### Added
- **NBJobRunner** — dedicated launchd-invoked binary for executing scheduled jobs (commit `0058a2a`), decoupling job execution from the main app lifecycle.

## [1.9.1] — 2026-04-18

### Added
- **Jobs Surface** (Settings → Jobs) — restored dedicated sidebar section for scheduled jobs after v1.8.5 audit removed it. Includes status dots, human-readable cron preview, inline schedule editor with live validation, action-chain JSON editor, skip-on-battery toggle, Run Now, Duplicate, Pause/Resume, Delete, Copy ID, Reveal Log, search + sort toolbar, and kill-switches for Pause All / Resume All.
- **7 new scheduler tools** — `job_run`, `job_update`, `job_duplicate`, `job_export`, `job_import`, `jobs_pause_all`, `jobs_resume_all`. Scheduler module now exposes 15 tools total (up from 8).
- **JobStore.update(id:mutate:)** — atomic partial-update primitive on the JobStore actor with mutation closure; preserves id / createdAt, persists in one SQL round-trip.
- **JobsManager+V2.swift** — high-level handler module containing runNow/updateJob/duplicateJob/exportJobs/importJobs/pauseAll/resumeAll. Schedule changes trigger atomic LaunchAgent re-registration with automatic DB rollback + plist restore on failure.
- **CronHumanizer** — pure-Swift cron expression describer in JobsView (every minute, every N minutes, hourly at :MM, daily, weekly on DAY, monthly on day N).
- **JobExportEnvelope** — versioned Codable wire format for job export/import.

### Fixed
- **SettingsSection enum** — reintroduced `.jobs` case between Skills and Advanced with `clock.badge.checkmark` icon; v1.8.5 removal left no UI surface for scheduled jobs.
- **Version drift** — `AppVersion.marketing` bumped 1.8.5 → 1.9.0 to match Info.plist.

### Changed
- `BridgeConstants.staticFeatureModuleToolCount`: 73 → 80 (7 new scheduler tools). Family count unchanged at 15.
- `AppVersion`: 1.8.5 (20) → 1.9.1 (22).

## [1.8.5] — 2026-04-12

### Added
- **notion_datasource_update** MCP tool (notify tier) — Update a data source's schema (add/modify properties) via `PATCH /v1/data_sources/{id}`. Enables programmatic schema changes on multi-data-source databases.
- **notion_datasource_create** MCP tool (notify tier) — Create a new data source under an existing database via `POST /v1/data_sources`.
- **NotionClient: updateDataSource(), createDataSource()** — Two new API methods for data source write operations.
- **12 new tests** — Test suite hardening: invalid JSON rejection for new tools, missing-param validation for `notion_database_get`, `notion_datasource_get`, `connections_get/validate/capabilities`, `manage_skill`, `payment_execute`, `process_list` filter/limit params. Total: 389 tests.

### Fixed
- **EndToEndTests** — NotionModule expected tool count updated from 19 to 21.

### Changed
- `BridgeConstants.staticFeatureModuleToolCount`: 78 → 80.
- NotionModule: 19 → 21 registered tools.
- Release build: v1.8.5 (20).

## [1.8.4] — 2026-04-12

### Added
- **Contacts module** — four new MCP tools: `contacts_health`, `contacts_search`, `contacts_get`, `contacts_resolve_handle`. Backed by CNContactStore — works without Contacts.app running. Closes #16.

### Fixed
- **Tests & docs vs tool inventory** — E2E harness registers `ContactsModule`; expectations and README/AGENTS use `BridgeConstants.staticFeatureModuleToolCount` (78) + `echo` + Stripe **N**. `SystemModuleTests` expect three system tools after Contacts split.
- **Stripe startup resilience** — transient startup failures retry automatically (3-attempt exponential backoff, 2s→4s→8s); `stripe_reconnect` sentinel tool registered as manual recovery when all retries fail. Auth failures (missing key) skip retries immediately.
- Remote access URL field no longer clears on click.
- Remote access status indicator no longer shows green when bearer token is absent.
- Remote access status loads correctly on Settings open (not only after expanding section).

### Changed
- **Remote access UX** — save button with dirty-state tracking; three-state status indicator (no URL / URL without token / fully configured); session invalidation on token rotation.
- **Session persistence** — Bridge MCP sessions no longer expire (configurable via `sessionTimeout: 0` in config).
- Release build: v1.8.4 (19).

## [1.8.3] — 2026-04-11

### Fixed
- `credential_save`: accept `type: "api_key"` for save-path validation (GitHub #15).

### Changed
- Release build: v1.8.3 (18).

## [1.8.2] — 2026-04-07

### Fixed
- **Connection identity collision** — addConnection() now upserts when a connection with the same name already exists, preventing duplicate entries with dual-primary state. setPrimary() atomically unsets all other connections. preflightRemove() handles same-name edge case to allow self-healing deletion. loadConnections() auto-deduplicates on startup (last-write-wins) and ensures exactly one primary. (NotionClientRegistry.swift, NotionModels.swift)
- **Apple Passwords modal deadlock** — Added .textContentType(.none) to all SecureField inputs (token, password, API key, bearer token fields) to prevent macOS AuthenticationServices from hijacking the input with an undismissable Passwords picker. (ConnectionsManagementView.swift, OnboardingWindow.swift, CredentialsView.swift, ConnectionSetupView.swift)

### Changed
- **Shell-as-last-resort tool descriptions** — Updated 17 MCP tool descriptions to steer agents toward dedicated tools over shell_exec. shell_exec description now lists alternatives and includes fallback clause for when dedicated tools are disabled. 12 file/clipboard tools, process_list, applescript_exec, and screen_capture now include "Preferred over shell_exec X" guidance. (ShellModule.swift, FileModule.swift, SystemModule.swift, AppleScriptModule.swift, ScreenModule.swift)

## [1.8.1] — 2026-04-06

### Added
- **Skills Manager V2** — Platform-agnostic skill engine. Skills keyed on UUID with auto-detected platform routing (Notion, Google Docs). New `SkillURLParser.swift` utility. `manage_skill add` routes through URL parser. `manage_skill list` returns uuid, url, platform per skill. UI: URL field with live auto-detect, platform badge, inline skill rename (double-click). (`e0e09d9`)
- **Credentials tab restructure** — "API Keys" renamed to "Notion Integrations". New dedicated "Stripe" section with connection state management, validation, and removal. `StripeConnectionSection.swift` + `StripeConnectionSheet.swift`. Add Connection wizard simplified to Notion-only. (`1bbf091`)
- **MCP auto-routing on connection** — Routing skill index embedded in MCP `initialize` response via `instructions` field. Agents receive skill routing context at handshake time without needing to call `list_routing_skills` first. (`0fe85c8`)

### Fixed
- **Stripe stale key cleanup** — `ConnectionRegistry.removeConnection(.stripe)` now deletes legacy keychain entry (`SecItemDelete`) and resets `StripeMcpProxy`. No more false-positive green checkmark after key removal.
- **Skill rename in UI** — Double-click skill name in SkillsView for inline `TextField` rename. Validates non-empty, unique name. Escape cancels.
- **Skill page open crash** — `openSkillURL` now strips dashes from UUID before constructing `notion.so` URL. No more "Oops" error page.
- **UI text simplification** — Removed platform-specific language (Notion, Google Docs) from URL field placeholders. Just says "URL". (`339457e`)

### Changed
- **Skill data model** — `Skill` struct gains `url: String?` and `platform: SkillPlatform`. Backward-compatible decoder defaults existing skills to `.notion` / `nil`. All mutation methods preserve new fields.
- **README** — Updated tool count (76 static + N dynamic Stripe). Module table refreshed.
- **AGENT_FEEDBACK.md** — Pruned all resolved entries from v1.8.0 development cycle.

## [1.8.0] — 2026-04-04

### Added
- **Pre-ship release** — `docs/pre-ship-qa-checklist.md` (manual QA matrix), `scripts/qa_local_mcp_smoke.py` (local `GET /health` + `POST /mcp` initialize), **`make install-agent-safe`** alias for `install-copy` (see `AGENTS.md`).
- **notion_database_get** MCP tool (open tier) — Retrieve a Notion database container by ID. Returns title, icon, cover, parent metadata. (B1)
- **notion_datasource_get** MCP tool (open tier) — Retrieve a Notion data source schema by ID. Returns full property definitions, types, and options. (B2)
- **NotionClient: getDataSource()** — GET /v1/data_sources/id. New client method for data source schema retrieval.
- **CredentialType.unknown** — Fallback credential type for non-standard keychain labels. (A2)
- **fetch_skill close matches** — On miss, error response now includes Levenshtein-based close match suggestions instead of just listing all skills. (C1)
- **manage_skill bypassConfirmation** — New boolean parameter to skip SecurityGate confirmation prompt for automated/unattended sessions. (C3)

### Fixed
- **file_write HTML entity encoding** — Content with HTML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`) is now decoded before writing to disk. Round-trip integrity preserved. (A1)
- **credential_read/credential_list** — `parseKeychainItem()` no longer throws for non-standard keychain labels; items with unknown labels surface as `type: "unknown"` instead of being silently excluded. (A2)
- **messages_send chat identifier guard** — Raw `chat[0-9]+` identifiers are now rejected before AppleScript dispatch, preventing malformed ghost threads in Messages.app. Error directs caller to resolve via `messages_participants`. (A3)
- **notion_query retry logging** — Auto-retry on transient 404 now logs "retrying transient 404" vs "permanent 404 — check sharing". Retry count visible in debug output. (C2)

### Changed
- **Security: Request-tier Always Allow** — Choosing **Always Allow** on a Request-tier tool (notification actions) now sets that tool to **Notify** in the Tool Registry (`tierOverrides`), matching the tier toggle. It no longer appends legacy “learned command prefixes.” Sensitive-path prompts: **Allow** keeps a session grant; **Always Allow** stores a **permanent path allow** (unchanged intent, without tier side effects). Alert-only fallback (no notification permission) remains Allow/Deny only — use the Tool Registry to lower tier. Tools marked never-auto-approve do not offer Always Allow.
- **Skills: Notion-only page refs** — Settings and `manage_skill` (`add`, `update_url`, `bulk_add`) accept only Notion page IDs (32 hex, dashes optional) or `notion.so` / `notion.site` URLs. Invalid rows in `bulk_add` are skipped with per-row reasons (`invalidPageRows`). Legacy bad IDs surface clear errors from `fetch_skill` / sync and an optional Settings banner.
- **MCP protocol version** — Handshake and diagnostics now use MCP spec **2025-06-18** (was 2024-11-05). Advanced → Version clarifies Model Context Protocol vs Notion’s hosted MCP.
- **Notion API version** — Advanced → Version and diagnostics list **`Notion-Version`** (**2026-03-11**), centralized as `BridgeConstants.notionAPIVersion` (used by `NotionClient`).
- **Advanced → Network** — Port save opens a **Restart / Cancel** dialog; Cancel reverts `config.json` to the previous port. **Default** button fills 9700 without saving. Copy tightened for tunnel ↔ localhost port coupling. Connections → Server labels **Local port**.
- **Onboarding connection snippets** — Sample MCP URLs use the configured local port (not hardcoded 9700). Health check uses the same port.
- **Minimum macOS** — Advanced shows minimum deployment **macOS 26+** (matches SwiftPM), not the machine’s runtime major version alone.
- **Skills registry** — Fresh installs and factory reset yield an **empty** skills list (no bundled placeholder skills). (UX Wave 2)
- **Credentials (Settings + MCP)** — Keychain credential storage is **opt-in** with a migration for existing users (`hasCompletedOnboarding` → default on until changed). When off, `credential_*` tools are hidden from MCP listings and calls fail closed; `payment_execute` requires credentials enabled. Biometric gate when turning on. (UX Wave 4)
- **Permissions UI** — Removed **PostResetSheet** (no guided sheet after TCC reset or factory reset); success copy points to **System Settings** and restart. Permissions tab auto-refresh throttled to **20s**; onboarding auto-permissions defer probes until **Re-check** or **Grant All**. (UX Wave 3)
- **payment_execute** — Description clarifies Stripe PaymentIntent + stored `pm_` (not web checkout), separate from the Stripe MCP proxy. (UX Wave 5)
- **notion_search** description — Updated to reference "data sources" instead of "databases". `filter.value` documentation now specifies `"page"` or `"data_source"` (not `"database"`). (D1)
- **notion_page_create** description — Notes that `parentType: "data_source_id"` is preferred for row inserts under Notion API 2026-03-11; `"database_id"` is legacy. (D2)
- **Settings polish (Connections, Credentials, Remote Access, Advanced)** — Minimal Stripe **API connections** row (pre-installed / status); removed Workspace and API section footers; **Credentials** delete uses attribute-matched Keychain queries with clearer messaging when removal fails; **Remote Access** header row toggles expand; **Advanced** Version/Network helper copy trimmed (Minimum macOS **26+**, port row + validation errors only).

### Removed
- **notion_page_markdown_write** tool — Removed from NotionModule, NotionClient, and tests. Superseded by notion_page_update + content blocks approach. (D3)

### Notes
- B3 (`notion_datasource_create`) and B4 (`notion_datasource_update`) are gated on Notion API endpoint confirmation. Deferred to v1.9.0.
- Git hygiene: merged `fix/session-lifecycle-stability` and `feat/settings-connections-restructure` into main. Deleted ghost branches (`claude/fervent-lichterman`, `claude/sad-kapitsa`).
- Tool count: 75 NotionBridge tools (74 base − 1 removed + 2 new) + N Stripe MCP tools.
- Version: marketing **1.8.0**, build **15** (Version.swift, Info.plist).

## [1.7.0] — 2026-04-02

### Added
- **NotionClient: getBlock()** — GET /v1/blocks/{id}. Retrieves a single block by ID with full type-specific data.
- **NotionClient: updateBlock()** — PATCH /v1/blocks/{id}. Updates a block's content by ID.
- **NotionClient: getDatabase()** — GET /v1/databases/{id}. Retrieves a database schema by ID.
- **notion_block_read** MCP tool (open tier) — Deep-inspect a single Notion block. Returns id, type, has_children, text, and raw type-specific payload.
- **notion_block_update** MCP tool (notify tier) — Update a Notion block's content by ID. Accepts JSON payload.
- **meeting_notes** support in extractPlainTextFromBlock — Surfaces title, status, and child block IDs (summary, notes, transcript).
- **SkillsManager.findSkillFuzzy()** — Public fuzzy lookup: exact > normalized (strip 'sk ' prefix, space/hyphen swap) > substring. Returns (match, suggestions).
- **Makefile install-copy target** — Copy-only install without notarize dependency or killall. For iterative development.

### Changed
- **notion_query** — Auto-retry on transient HTTP 404 with 2s delay before re-throwing (KI-08, F4).
- **shell_exec** — Background commands (trailing &) now cap timeout at 5s instead of 30s for fast early-return (F2).
- **lookupSkill** in SkillsModule — Now uses fuzzy matching: exact > normalized > substring. Resolves "web dev" to "Web Design", "sk messages" to "Messages", etc. (F5).

### Notes
- Remote MCP operator guidance now documents that browser-based clients (for example Claude chat) can be blocked by Cloudflare Browser Integrity Check or WAF challenges on `POST /mcp`; recommended mitigation is a path-scoped edge bypass plus the app bearer token.
- Tool count: 74 NotionBridge tools (72 base + 2 new block tools) + N Stripe MCP tools.
- Version: marketing **1.7.0**, build **14** (Version.swift, Info.plist).
- Feedback items resolved: F2, F3, F4, F5 (F1, F7 already fixed in v1.5.5/v1.6.0).

## [1.6.0] — 2026-03-31

### Fixed
- **`NotionClient.updatePageMarkdown`** — PATCH body now sends `replace_content.new_str` (full markdown string) per [Update page markdown](https://developers.notion.com/reference/update-page-markdown). The previous nested `markdown.content` shape caused HTTP 400 validation errors from the Notion API.

### Changed
- **Stripe MCP Proxy architecture** — Replaced hardcoded `StripeModule` (4 tools) with `StripeMcpProxy` + `StripeMcpModule`. Tools are now discovered dynamically from Stripe's remote MCP server (`mcp.stripe.com`) at registration time via HTTP `initialize` + `tools/list`. All discovered tools are registered with SecurityGate tiering (read → 🟢, write → 🟡, delete → 🔴).
- **StripeClient cleaned** — Removed `StripeProduct`, `StripePrice` structs and 6 catalog methods (`retrieveProduct`, `updateProduct`, `retrievePrice`, `listPrices`, `parseProduct`, `parsePrice`). Retained payment intent and account info methods only.
- **ConnectionRegistry** — Stripe capabilities updated from hardcoded catalog tool names to `["payment_execute", "card_tokenization", "stripe_mcp_proxy"]`.
- **ServerManager** — Registration call updated from `StripeModule.register` to `StripeMcpModule.register`.

### Removed
- **StripeModule.swift** — Replaced by `StripeMcpModule.swift` (dynamic proxy registration).

### Added
- **StripeMcpProxy.swift** — HTTP transport client for Stripe MCP server. Handles `initialize`, `tools/list`, and `tools/call` JSON-RPC methods. Bearer auth via Stripe API key from Keychain. Includes retry logic, timeout handling, and structured error responses.
- **StripeMcpModule.swift** — Registers proxy-discovered tools with the MCP tool router. Maps Stripe tool input schemas to SecurityGate tiers. Passes tool calls through to `StripeMcpProxy.callTool()` at runtime.

### Notes
- Tool count is now dynamic — base 72 NotionBridge tools + N Stripe MCP tools discovered at startup.
- Version: marketing **1.6.0**, build **13** (`Version.swift`, `Info.plist`).

## [1.5.5] — 2026-03-31

### Added
- **StripeModule** — 4 new Stripe catalog MCP tools (`stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`). Separate module from PaymentModule.
- **StripeClient** — 4 new methods: `retrieveProduct`, `updateProduct`, `retrievePrice`, `listPrices`. Reuses existing `authorizedRequest` helper.
- **StripeProduct** and **StripePrice** response structs for type-safe Stripe catalog data.
- Stripe connection capabilities expanded: `stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`.

### Fixed
- **Credential namespace bridge** — `CredentialManager.read()` now returns infrastructure keys (service `com.notionbridge`) instead of throwing `invalidType`. Enables agents to access Stripe API key and other infrastructure credentials via `credential_read` MCP tool.
- **Credential list visibility** — `CredentialManager.list()` now surfaces `com.notionbridge` infrastructure keys as metadata-only entries. No secrets exposed in list results.

All notable changes to NotionBridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.4] — 2026-03-31

### Fixed
- **KI-07: notion_page_markdown_write HTTP 400** — Changed API request body format from `page_content` to `replace_content` to match Notion API 2026-03-11 spec. Full page markdown replacement now works correctly.

### Added
- **Parent field in notion_page_read** — Response now includes `parent` object from the Notion API, enabling data source ID resolution from any page without additional API calls.

## [1.5.3] — 2026-03-30

### Added
- **Streamable HTTP tunnel compatibility** — When **Settings → Connections → Remote access** has a non-empty **tunnel URL** (`tunnelURL` in app storage), `POST /mcp` validation extends the default localhost-only **Origin** / **Host** allowlist to include that tunnel’s hostname (e.g. Cloudflare quick tunnels). The server still binds to **127.0.0.1** only; traffic must reach the app via a tunnel or reverse proxy to loopback. No `0.0.0.0` bind.
- **Mandatory MCP bearer when tunnel is active** — If the tunnel URL **parses** (same condition as the extended allowlist) and **no** MCP bearer is configured, Streamable HTTP **`POST /mcp`** is rejected (**401**). When a bearer is set (**Keychain** `mcp_bearer_token`, with **`com.notionbridge.mcpBearerToken`** as legacy/migration read), clients must send **`Authorization: Bearer …`**. With an **empty** tunnel URL, bearer is optional (setting a token still enforces it for localhost clients).
- **Remote access UI** — **MCP remote token** field (SecureField) with Generate / Copy / Clear when a tunnel URL is present; persists to Keychain + UserDefaults mirror.
- **`MCPHTTPValidation`** — Shared builder for the Streamable HTTP `StandardValidationPipeline` used by session creation in `SSETransport`; exposes **`streamableHTTPBearerPhase()`** for tests and diagnostics.
- **Tests** — `MCPHTTPValidationTests` for tunnel URL → host/origin allowlist parsing and bearer phase (remote missing token / bearer required / local optional).
- **Operator doc** — `docs/operator/cloudflare-access-notion-bridge.md` (Cloudflare Access in front of the tunnel; no secrets).

### Changed
- **`SSETransport` `createSession`** — Uses `MCPHTTPValidation.streamableHTTPPipeline(ssePort:)` instead of only `OriginValidator.localhost()`.

### Notes (distribution)
- After **`make dmg`**, confirm **`make verify-sparkle-feed`** and that **`length`** / **`sparkle:edSignature`** in `appcast.xml` match the uploaded GitHub release asset (regenerate with **`make appcast`** if the DMG changed).
- **Version / Sparkle** — Marketing **1.5.3**, build **10** (`Version.swift`, `Info.plist`). **`appcast.xml`** includes **1.5.3** (newest) plus prior **1.5.2** / **1.5.1** items. Upload **`notion-bridge-v1.5.3.dmg`** to the **v1.5.3** GitHub release so the enclosure URL resolves.
- **Purchase download (kup.solutions)** — When publishing this build to paid fulfillment, set `workers/nb-fulfillment/wrangler.toml` **`DMG_OBJECT_KEY`** to **`notion-bridge-v1.5.3.dmg`** (or keep the prior filename if you intentionally reuse it), re-upload the object, then deploy the worker if needed.

## [1.5.2] — 2026-03-30

### Removed
- **Skill visibility `adminOnly`** — Same behavior as Standard for MCP discovery; removed from UI and tool schema. Persisted registry entries and MCP calls using `adminOnly` are read as **standard**.

### Added
- **[SECURITY.md](SECURITY.md)** — Vulnerability reporting scope, out-of-scope items, Sparkle channel guidance.
- **GitHub issue templates** — Bug and feature forms under `.github/ISSUE_TEMPLATE/`.
- **`make verify-sparkle-feed`** and **`scripts/verify_sparkle_feed.sh`** — Confirms `SUFeedURL` from `Info.plist` returns HTTP 200 and XML-shaped content (run before/after publishing `appcast.xml`).
- **Skills MCP metadata** — `summary`, `triggerPhrases`, and `antiTriggerPhrases` stored with each skill (UserDefaults); Notion `rich_text` mirror properties **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`**. New `manage_skill` actions: `set_metadata`, `sync_metadata_to_notion`, `sync_metadata_from_notion`. `list_routing_skills`, `manage_skill list`, and `fetch_skill` expose metadata; `fetch_skill` cache key includes a metadata fingerprint.
- **SkillNotionMetadata** — Shared encode/decode for Notion page property patches (2000-char rich_text chunks).

### Changed
- **[README.md](README.md)** — Canonical tool counts (**73** = 72 module + `echo`); SkillsModule **3** tools; **Public updates (Sparkle)** and **Security disclosures** sections.
- **[AGENTS.md](AGENTS.md)** — Aligned MCP tool count with runtime (`echo` as builtin).
- **[PRIVACY.md](PRIVACY.md)**, **[TERMS.md](TERMS.md)** — Stripe as primary processor; Lemon Squeezy described only where applicable as merchant of record.
- **[Version.swift](NotionBridge/Config/Version.swift)** — Build constant kept in sync with `Info.plist`.
- **Settings → Connections** — Sections clarified: Notion workspaces vs API connections (Stripe); footers explain tunnel vs tokens. **API connections** list uses `ConnectionRegistry` `kind: .api` with provider badges.
- **Settings → Skills** — Footer explains Standard / Routing visibility; optional summary line in skill rows.
- **Settings → Advanced → Network** — Copy explains local SSE port vs remote tunnel; tunnel must forward to the same port after changes.
- **Permissions → Notifications** — `PermissionManager` maps `UNAuthorizationStatus` consistently; one-shot `requestAuthorization` when still `notDetermined` to sync System Settings–only grants; remediation text when status is unknown.

### Notes (distribution)
- Sparkle requires the appcast URL to be **publicly readable** (e.g. public GitHub repo for `raw.githubusercontent.com/.../appcast.xml`, or host `appcast.xml` on your own HTTPS origin and set `SUFeedURL`). See README.
- **GitHub repository** `KUP-IP/Notion-bridge` is **public**, so the default `SUFeedURL` is anonymously reachable; run **`make verify-sparkle-feed`** to confirm after changes to `appcast.xml`.

### Notes (UEP closeout)
- Documentation and tooling delivered in-repo; sync **Status** / **Summary** on any linked Notion packet or project if this work was tracked in KUP·OS DOCS.

### Changed (release)
- Version: marketing **1.5.2**; build **7 → 8 → 9** (`Version.swift`, `Info.plist`). Build **9** is the current shipping binary for 1.5.2 (includes `adminOnly` removal and doc/tooling updates above).
- **Sparkle (`appcast.xml`)** — Item for 1.5.2 (build **9**). If the release DMG from `make dmg` differs in size from the committed appcast, run `sign_update` / `generate_appcast` on the exact uploaded `.dmg` and update `length` / `sparkle:edSignature` before publishing the GitHub release.
- **Purchase download (kup.solutions)** — In the `kup.solutions` repo, `workers/nb-fulfillment/wrangler.toml` `DMG_OBJECT_KEY` is set to `notion-bridge-v1.5.2.dmg`. Re-upload that object after each new DMG build (same filename), then deploy the `nb-fulfillment` worker if needed.

## [1.5.1] — 2026-03-26

### Added
- **`screen_analyze` tool** — Dominant color extraction from screenshot files using CoreGraphics pixel sampling. Returns hex colors with percentages, average luminance (0-1), dark/light theme detection, and image dimensions. Open tier (read-only). Input: file path from `screen_capture`. Algorithm: 5-bit RGB quantization → frequency sort → top-N.

### Changed
- Version bump: 1.5.0 → 1.5.1, build 6 → 7.
- ServerManager: Added `ScreenModule.registerAnalyze(on:)` registration.

## [1.5.0] — 2026-03-25

### Added
- **TCC csreq mismatch detection** — `PermissionManager` now detects stale TCC entries where `auth_value=2` but runtime probe returns false. New "Reset & Re-authorize" UI banner in PermissionView.
- **reminders-bridge.swift** — Full EventKit CLI for Apple Reminders (8 commands: list-lists, create-list, create, read, update, complete, delete, search). Supports recurrence rules, location alarms, URL, priority, due dates.
- `Version.swift` as single source of truth for app versioning (replaces hardcoded fallback strings).

### Fixed
- **reminders-bridge v1.1.0** — `listId` UUID resolution fix + `notes` param alias (`notes` takes priority over `body`).
- **TCC csreq stale grants** — Automation targets with approved-but-stale code signing requirements now detected and resettable from UI.

### Changed
- **66 MCP tool descriptions rewritten** (PKT-488) — Every tool description now leads with action, names return shape, embeds behavioral gotchas, includes workflow hints. Removed all security tier badges (SecurityGate enforces at runtime).
- Version bump: 1.4.0 → 1.5.0, build 5 → 6.
- Info.plist synced with Version.swift (was stale at 1.4.0).

## [1.4.0] — 2026-03-24

### Added
- **ChromeModule Space-awareness** — Tab listing now reports which macOS Space each Chrome window occupies via ScreenCaptureKit `onScreen` field. `chrome_navigate` falls back to `open` when the target window isn't on the active Space.
- `.cursor/rules` for Cursor agent project context.
- `RELEASE_HANDOFF.md` with build/sign/notarize instructions.

### Fixed
- **Makefile rpath** — Corrected `@executable_path` → `@loader_path` for proper framework resolution.
- **Stripe payment tests** — Refactored `StripeTokenizationTests` to use shared `readRequestBody()` helper instead of inline body parsing.

### Changed
- **Swift 6.3 compatibility** — Compiler fixes, SkillsModule fix, added `patch-deps` Makefile target.
- **Module/tool count reconciliation** — Audited and corrected counts: 63 → 65 tools, 14 → 13 modules. Updated AGENTS.md and all E2E test assertions.
- Version bump: 1.2.0 → 1.4.0, build 4 → 5.
- DMG size reduced from ~12.9 MB to ~10.2 MB.

## [1.3.0] — 2026-03-20

### Added
- `contacts_search` tool via CNContactStore (#51).
- Reminders (`com.apple.reminders`) as 5th automation target.

## [1.2.0] — 2026-03-22

### Added
- Settings tweaks, `manage_skill` tool, Connection Manager guards.

## [1.1.5] — 2026-03-15

_Initial tracked release._

[1.8.4]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.8.0
[1.7.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.7.0-pkt381
[1.6.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.5...v1.6.0
[1.5.5]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.1.5...v1.2.0
[1.1.5]: https://github.com/KUP-IP/Notion-bridge/releases/tag/v1.1.5

[1.9.1]: https://github.com/KUP-IP/Notion-bridge/compare/v1.9.0...v1.9.1
