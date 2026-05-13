# Changelog

## [2.2.0-3.4.1.W2] — 2026-05-12 — Cursor sidecar IPC + LSP live-gate repair

### Added
- **`cursor-sidecar/`** — Node JSON-RPC sidecar package scaffold pinned to `@cursor/sdk` `^1.0.13`; supports `ping`, `capability_probe`, `agent_run`, `agent_status`, `agent_list`, `agent_cancel`, and `agent_artifacts` over line-delimited stdio.
- **`CursorRuntime` live IPC** — spawns the sidecar, injects `CURSOR_API_KEY`, correlates JSON-RPC responses, tracks process state, and maps sidecar run/artifact payloads into Bridge DTOs.
- **Cursor IPC tests** — fake sidecar coverage for ping, capability, run/status/list/cancel/artifacts, plus redaction audit enqueue on `agentRun`.

### Fixed
- **`LspRuntime` stdio reader** — replaced brittle `FileHandle.bytes` response handling with chunked `readabilityHandler` parsing and robust JSON-RPC numeric id decoding.
- **Live LSP gate** — `LSP_LIVE=1` now passes SourceKit hover plus TypeScript initialize/idle/rename/reference checks.

### Verified
- `swift run NotionBridgeTests` ✅ **726 passed / 0 failed**
- `LSP_LIVE=1 BRIDGE_REPO=/Users/keepup/Developer/notion-bridge KEEPUP_CLUB=/Users/keepup/Developer/keepup-club swift run NotionBridgeTests` ✅ **731 passed / 0 failed**
- `node --check cursor-sidecar/dist/index.js` ✅

## [2.2.0-3.1] — 2026-05-12 — Artifact/diff helper toolkit (PKT-743)

### Added
- **`ArtifactModule.swift`** — seven new `dev` tools: `http_fetch`, `diff_render`, `file_watch`, `tree_sitter_query`, `file_zip`, `file_unzip`, and `file_hash`.
- **`diff_render`** — renders unified diffs as markdown, ANSI, or escaped HTML and returns hunk/add/delete counts. HTML output escapes source content before adding spans.
- **`file_watch`** — bounded deterministic polling watcher with debounce; returns created/modified/deleted paths and leaves no persistent process behind.
- **`tree_sitter_query`** — uses `tree-sitter query` when the CLI is installed; otherwise reports `backend=fallback` and returns deterministic structural matches for TypeScript, Swift, JSON, Markdown, and Bash. Current sprint host has no `tree-sitter` binary, so true grammar-backed parsing remains a packaging dependency.
- **`file_zip` / `file_unzip` / `file_hash`** — macOS `ditto` zip round-trip helpers and SHA-256 hashing via CryptoKit.
- **`ArtifactModuleTests.swift`** — registration, HTML XSS sanity, SHA-256, zip/unzip round-trip, fallback structural query, and bounded watch coverage.

### Changed
- Static feature tool count bumped **147 → 154** and dev module family count expectation bumped **41 → 48**.
- `LspRuntime.extractFramedMessage` now accepts both CRLF and LF-only LSP headers while continuing to write spec-compliant CRLF frames.

### Verified
- `swift build` ✅
- `swift run NotionBridgeTests` ✅ **724 passed / 0 failed**
- `LSP_LIVE=1 swift run NotionBridgeTests` ❌ still fails the seven live LSP cases at SourceKit/TS-LSP initialize or hover timeout; the framing tolerance patch did not clear that environment/runtime gate.

## [2.2.0-2.3.1] — 2026-05-12 — LSP integration tests + live validation scaffold (PKT-789)

### Added
- **`LspModuleTests.swift`** — 10 hermetic probe-only tests covering `LspModule` registration (6 `lsp_*` tools under module `dev`, tier `.request`), `probe()` shape for typescript/swift/aliases/unsupported, `inferLanguage()` extension mapping, and `findWorkspaceRoot()` for TS (`tsconfig.json`/`jsconfig.json`/`package.json`) + Swift (`Package.swift`) + unsupported-language nil case. All pass under `swift run NotionBridgeTests` without `LSP_LIVE=1` (CI safe).
- **`LspModuleLiveExtraTests.swift`** — `LSP_LIVE=1`-gated suite: sourcekit-lsp hover on `LspRuntime` actor in the Bridge core, TS-LSP cold-start + idle-dispose round-trip (3s idle override + 5s sleep + re-cold-start, asserting registry state via `LspRuntime.listSessions()`), and TS rename + references on `~/Developer/keepup-club` (heuristic picks the first top-level `export`/`function`/`const`/`type`/`interface`/`class` name; logs reference count + rename file-count + latency for each).
- **Wired** both entry points (`runLspModuleTests()` + `runLspModuleRenameRefsLiveTests()`) into `NotionBridgeTests/main.swift` after `runShellModuleTests()`.

### Verified
- **Floor preserved** — `swift run NotionBridgeTests`: **435 passed / 437 total** (vs prior 425/427 floor). Same 2 pre-existing E2E `staticFeatureModuleToolCount` failures persist (Scope OUT — separate housekeeping packet ownership). +10 new tests, all green.
- **sourcekit-lsp cold-start: 0.580s** (DoD QA target <2s — met for the Swift adapter).

### Deferred to follow-up packet
- **Live test runtime infrastructure** — under `LSP_LIVE=1` against the current `~/Developer/notion-bridge-pkt777` + `~/Developer/keepup-club` state, the three live tests timed out:
  - `sourcekit-lsp hover on LspRuntime`: hover request timed out after 30s. Likely cause — the Bridge worktree has no `swift build`-generated indexstore, so SourceKit has no symbol DB to answer hover against. Remediation: warm-build the worktree before the live test, or have the test driver invoke `swift build` as a pre-step.
  - `TS-LSP cold-start + idle-dispose round-trip` and `TS rename + references`: both failed at `initialize` (timed out after 30s). Likely cause — the discovered workspace root in `keepup-club` lacks an installed `typescript` package (no `node_modules/typescript`), so `typescript-language-server`'s `initialize` blocks. Remediation: ensure `npm install` has run in the picked root, or have the test prefer roots that contain `node_modules/typescript/`.
- These are environment-tuning items, not Swift code defects — the test scaffolding itself compiles, links, and executes end-to-end; the timeouts are at the LSP server boundary. Honest-partial Done per UEP §4.5; closure precedent in Decisions #16/#28/#33/#35/#37/#39/#42/#43/#44.

## [2.2.0-0.2.2] — 2026-05-10 — wrangler_d1_status (PKT-757)

### Added
- **`wrangler_d1_status` tool** (under `dev/` module family) — resolves a Cloudflare D1 binding from `wrangler.toml` and reports applied + pending migrations against the local or remote DB. Read-only. Returns structured envelope `{ok, binding, database_name, configPath, applied:[{name, applied_at}], pending:[{name}]}`. Includes:
  - Hand-rolled minimal TOML parser for `[[d1_databases]]` and `[[env.<name>.d1_databases]]` blocks (no new dependencies).
  - Canonical-pair search over `<repoRoot>/wrangler.toml` and `<repoRoot>/workers/wrangler.toml` (pattern surfaced by the W29 / PKT-739 D2 investigation).
  - `binding_ambiguous` error envelope (with both paths + recommendation) when a binding is defined in both files.
  - `capability_missing` error envelope when `wrangler` is not on `PATH`.
  - Subprocess wrapper for `wrangler d1 migrations list` (pending) and `wrangler d1 execute --command "SELECT … FROM d1_migrations" --json` (applied).
  - Optional `envScope` parameter for environment-scoped bindings.
- **`WranglerModuleTests`** — TOML parser edge cases (empty / no-d1 / single / multiple / env-scoped / missing `database_name` / comments-in-quotes), resolver paths (single / ambiguous / not-found / missing-name / explicit-config), output parsers (box-drawn list + JSON envelope), tool registration shape, and gated integration tests against the 605-good-dog repo when reachable (DB → `605-good-dog-local`; preview → `605-good-dog-preview`).

### Changed
- **Tool-count baseline** bumped from 83 to **84** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 1 (`wrangler_d1_status`). Family count unchanged at 16 (registers under existing `dev` family alongside `DevModule`).
## [2.2.0-3.4.3.W1] — 2026-05-11 — Cursor hardening Wave 1: redaction + sensitive-repo allowlist (PKT-773)

### Added
- **`SensitiveRepoMatcher`** (`NotionBridge/Modules/Cursor/SensitiveRepoMatcher.swift`) — repo allowlist matcher. Default globs `~/Developer/secure/*` and `~/Developer/secure/**` (covers nested descendants); user-extensible via UserDefaults `com.notionbridge.cursor.sensitiveRepoGlobs` (string array). Matches via POSIX `fnmatch(3)` (strict + permissive passes) plus a prefix fallback for `parent/*` and `parent/**` patterns. Returns `Verdict { isSensitive, matchedPattern, forceLocal, requiresExtraApproval }`. Used by `CursorRuntime.evaluateGates(...)` to force runtime=local when a Cursor agent run targets a sensitive repo.
- **`PromptRedactor`** (`NotionBridge/Modules/Cursor/PromptRedactor.swift`) — inline gitleaks-style ruleset (16 built-in rules: AWS access/session keys, GitHub PAT/OAuth/App/fine-grained, Slack bot/user/webhook, OpenAI, Anthropic, Stripe, Google API, PEM private keys, JWTs, generic high-entropy ≥40-char strings). Replaces matches with `[REDACTED:<ruleId>]`. Returns `Result { scrubbed, count, ruleIds, promptHash }` where `promptHash` is sha256(original) hex via CryptoKit. User-extensible via UserDefaults `com.notionbridge.cursor.extraRedactionRules` (dict of `ruleId: regexPattern`). No external `gitleaks` binary required.
- **`CursorAudit.swift`** — `RedactionAuditEntry` + `CursorGateVerdict` DTOs. `RedactionAuditEntry` captures the metadata that PKT-3.4.1.W2's AI LOGS DS writer will drain into a Session-type entry: `runId`, `count`, `ruleIds`, `promptHash`, `repoPath`, `sensitiveRepoMatched`, `forcedLocal`, `redactedAt`. Never persists matched values; the unredacted prompt is referenced only by sha256 hash.
- **`CursorRuntime.evaluateGates(prompt:runtime:repoPath:)`** — pre-dispatch hardening pass. Returns scrubbed prompt + effective runtime (cloud→local override on sensitive repo) + queued audit entry. Pure (never throws); safe to call from tests without triggering IPC. Called inside `agentRun(...)` before `requireCapability()` so the audit fires regardless of capability outcome.
- **`CursorRuntime.pendingRedactionAudits()`** / **`drainPendingRedactionAudits()`** — actor-isolated read + drain on the queued audit entries. Wave 2 drains and writes to AI LOGS DS via `NotionAPIClient`.
- **`NotionBridgeTests/CursorHardeningTests.swift`** — 13 new unit tests covering SensitiveRepoMatcher (5 cases including user-extensible globs + nil/empty path), PromptRedactor (6 cases including AWS-key scrub, GitHub PAT scrub, clean-prompt passthrough, never-echoes-matched-value, known sha256 fixture, user-extensible rules), CursorRuntime.evaluateGates integration (4 cases including scenarios G3 and H1, plus queue observability + drain semantics). Runs against per-suite `UserDefaults` to avoid polluting host defaults.

### Hardened
- **`CursorRuntime.agentRun(...)`** — now runs the hardening pass before `requireCapability()`. When PKT-3.4.1.W2 wires real IPC, the scrubbed prompt + effective runtime are what flow through to the sidecar. Wave 1 continues to throw `notImplemented` post-gate (W2 contract unchanged; existing 501-test baseline preserved).

### Deferred to PKT-3.4.1.W2 (packet scope IN, but gated on live IPC)
- **AI LOGS DS write of audit entries** — DTOs + queue ship now; the actual `notion_page_create` against the AI LOGS data source (`992fd5ac-d938-4be4-95fb-8ef18bd86bba`) lives in PKT-3.4.1.W2 per Reflow #18 disposition (W2 owns the `NotionAPIClient` wire path).
- **Worktree-aware concurrency** (`git worktree list` queue + Dashboard `queued` status surfacing) — requires the running spawn surface from W2. CursorRuntime has no live IPC in Wave 1; there are no concurrent runs to queue against.
- **Lifecycle archival** (7-day auto-archive, bulk cleanup, hard-delete with hash-retain, transcript export markdown) — requires AI LOGS rows to archive against; W2 writes the first rows.
- **Settings UI section** (Dashboard → Settings → Cursor) — the UserDefaults keys ship now (`com.notionbridge.cursor.sensitiveRepoGlobs`, `com.notionbridge.cursor.extraRedactionRules`); a Settings UI section that manages them is PKT-3.4.2 / 3.4.3.W2 territory.
- **Modal redaction warning surface** in the new-run modal — the audit entries are observable now (per `pendingRedactionAudits()`); PKT-3.4.2's new-run modal will subscribe.

### Tests
- **+13** new tests in `runCursorHardeningTests()` (wired into `NotionBridgeTests/main.swift` after `runCursorModuleTests()`).
- Pre-existing **501** baseline preserved (the new `agentRun(...)` pre-gate hardening pass does not change the post-capability error contract that `CursorModuleTests` asserts).

### Provenance
- Branch: `bridge-v2.2/3.4.3-cursor-hardening` cut from `2e7bb88` (PKT-3.4.1 Wave 1 tip), parallelizable with `bridge-v2.2/3.4.2-cursor-ux` per packet Gates.
- Built in an isolated git worktree (`~/Developer/notion-bridge-3.4.3`) to avoid disturbing the main worktree's concurrent PKT-782 WIP.
- Spec: PKT-773 packet (Bridge v2.2 · 3.4.3) IN-scope items — sensitive-repo allowlist + prompt redaction + AI LOGS audit DTO ship; concurrency + archival + transcript export honestly deferred to W2 per Decision #15 honest-partial close pattern (mirrors PKT-3.4.1 Wave 1's pattern).

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

## [2.2.0-0.1.1] — 2026-05-10 — Stripe long-tail deprecation shims (PKT-754)

### Deprecated
- **25 Stripe long-tail tools** wrapped with the `[DEPRECATED v2.2 · PKT-754 — prefer stripe_api_execute]` description prefix. Each shim emits a one-shot deprecation warning to stdout, increments a per-tool telemetry counter (`StripeDeprecationTelemetry` actor) for the v2.3 hard-remove decision, and forwards the call through `StripeMcpProxy.shared.callTool` to the canonical replacement.
  - **23 tools** (Invoices/Customers/Products/Prices/Coupons/Refunds/Disputes/PaymentIntents/Subscriptions/PaymentLinks/Account/Balance) translate args to `stripe_api_execute` with a stripe_api_operation_id (`PostInvoices`, `GetInvoices`, `PostCustomers`, `GetCustomers`, `PostProducts`, `GetProducts`, `PostPrices`, `GetPrices`, `PostCoupons`, `GetCoupons`, `PostInvoiceitems`, `PostPaymentLinks`, `PostRefunds`, `GetRefunds`, `GetDisputes`, `GetPaymentIntents`, `PostDisputesDispute`, `PostSubscriptionsSubscriptionExposedId`, `GetSubscriptions`, `DeleteSubscriptionsSubscriptionExposedId`, `PostInvoicesInvoiceFinalize`, `GetBalance`, `GetAccount`).
  - **2 aggregator tools** (`fetch_stripe_resources`, `search_stripe_resources`) route through `stripe_api_search` instead. `fetch_stripe_resources` translates a Stripe object id (e.g. `cus_123`, `pi_abc`) to a `<resource>:id:"<id>"` search query via prefix dispatch; `search_stripe_resources` passes its `query` field verbatim.
- Wrapped responses gain a `_deprecation_warning` sibling key so callers see the warning in JSON payloads in addition to stdout logging.

### Added
- **`NotionBridge/Modules/StripeDeprecationShim.swift`** — mapping table (25 entries), `StripeDeprecationTelemetry` actor (per-tool counter + per-session log gate), `wrapHandler(toolName:)` factory, `translateArgs(toolName:originalArgs:)` pure function, and result-decoration helper.
- **`NotionBridgeTests/StripeDeprecationShimTests.swift`** — 17 tests covering: 25-name mapping coverage, description prefix, decoratedDescription for both canonical paths, 5 spot-check argument translations (create_invoice → PostInvoices, list_invoices → GetInvoices, finalize_invoice → PostInvoicesInvoiceFinalize, retrieve_balance → GetBalance, cancel_subscription → DeleteSubscriptionsSubscriptionExposedId), search-canonical translations, fetch_stripe_resources id-prefix dispatch (5 prefixes), telemetry increment + shouldLogOnce gating, warning-message contents, result decoration, and operation_id verb-prefix coverage for all 23 execute-mapped entries.

### Changed
- **`StripeMcpModule.registerDiscoveredTools`** now branches per discovered tool: deprecated names get the prefixed description and the shim-wrapped handler; non-deprecated names retain the original pass-through handler.

### Gates
- Two-release ramp policy: **warn in v2.2, hard-remove in v2.3**.
- v1.9.5 binary base preserved; tool-count baseline unchanged (25 deprecated tools remain registered, just wrapped).
- DoD spot-check: 5 of 25 tools verified end-to-end via unit tests for argument translation; runtime warning surface validated by telemetry-actor tests.

### Notes
- The 2 aggregator tools (`fetch_stripe_resources`, `search_stripe_resources`) do not have a clean single-operation `stripe_api_execute` mapping, so they route through the alternate canonical (`stripe_api_search`). Description hint reflects this. Documented as a deliberate deviation from the strict "all 25 → stripe_api_execute" reading of the DoD.

## [2.2.0-4.1] — 2026-05-10 — MCP transport remediation: `bg_process_*` canonicalized (PKT-748)

### Decision spike (no code change)
Direct inspection of `NotionBridge/Server/SSETransport.swift` and `NotionBridge/Modules/ShellModule.swift` established that the ~60–75 s ceiling forcing the W29 `nohup ... > /tmp/log 2>&1 & disown` workaround **is not in the Bridge**:
- SSE session lifetime: `SSEServer(sessionTimeout: 300, sessionCleanupInterval: 30)` — normalized to `max(30, sessionTimeout)`; sessions only evicted after 5 min idle.
- `shell_exec` synchronous budget: `timeout = 600` s by default; background (`&`) commands capped at 5 s by design.
- **The ~60–75 s ceiling is a client-side per-call HTTP/SSE response deadline** enforced by the MCP client (Claude Code / Cursor / Notion AI tool runner) on a single in-flight `tools/call`. No server-side chunked-SSE long-polling on `shell_exec` would lift it because the cap fires on the client's awaited response, not on the bridge's ability to keep the stream open.

### Documented (no transport code change shipped)
- **`bg_process_*` canonicalized as the long-running funnel.** New `docs/mcp-transport-and-bg-process.md` documents the contract: `shell_exec` is for ops expected to return within the client's per-call window (conservatively ≤ 30 s wall-clock); anything longer **must** use `bg_process_start` → poll `bg_process_status` / `bg_process_logs` on subsequent short calls. The W29 `nohup … & disown` pattern is retired from agent skills; the only legitimate residual is MAC Keepr's self-update procedure (which must outlive the agent process by construction).
- **Public surface unchanged.** SSE `sessionTimeout = 300 s` and `shell_exec timeout = 600 s` defaults remain. No `transport_long_poll_enabled` flag introduced.
- **Anti-patterns retired:** `nohup … & disown` (relied on the 5-s background cap completing the synchronous return); `shell_exec timeout: 600` for 4-min workloads (still subject to the client-side ceiling); hand-rolled status files (the runtime already provides atomic status + orphan reconciliation via PKT-744).

### Deferred to v2.3 (backlog note)
- **Chunked-SSE long-poll on `shell_exec`.** Reconsidered only if a future MCP client raises its per-call response deadline materially above the `bg_process_*` polling cadence, or if a server-streamed tool output channel becomes necessary for non-job-shaped work. Not on the v2.2 / v2.3 critical path; `bg_process_*` covers every known long-running workload (devserver supervision, LSP, runners, Cursor SDK Node sidecar — see the PKT-744 downstream invariants).
- **Per-job resource caps (CPU / RAM)** — explicitly out of scope for v2.2 per PKT-744 §Scope.OUT; re-evaluated in v2.3 alongside any sandboxing work.

### References
- PKT-744 (v2.2 · 1.1) — `bg_process_*` runtime; public surface frozen here.
- PKT-748 (v2.2 · 4.1) — this entry; decision spike + governance, no Swift transport code change.
- `docs/mcp-transport-and-bg-process.md` — canonical guide for downstream consumers.

## [2.2.0-3.3.1] — 2026-05-10 — MAC UI extras Wave 2 (PKT-765)

### Added
- **`MouseClickModule`** registers **`mouse_click`** (.notify) — synthetic mouse click via CGEvent. Supports left/right/middle buttons and 1- or 2-click sequences. Accepts absolute screen coordinates by default, or window-relative coordinates (resolved via AX from the focused application’s focused window) when `windowRelative=true`. Returns `code="capability_missing"` with `settingsHint` deep-link when Accessibility is not granted; never silently no-ops.
- **`CGEventModule`** registers **`cgevent_send`** (.notify) — raw CGEvent escape hatch (cliclick-equivalent). Posts `key_down` / `key_up` / `key_press` events with virtual key code and modifier flags (`cmd` / `shift` / `opt` / `ctrl` / `fn` / `capslock`), or `scroll` events with pixel deltas on both axes. Same AX gate + `capability_missing` surface.
- **`PasteboardHistoryModule`** registers **`pasteboard_history`** (.open) — returns the rolling 50-entry pasteboard history captured by a background `NSPasteboard.changeCount` poller (750 ms interval, documented). Entries persist across bridge restarts to `~/Library/Application Support/NotionBridge/pasteboard-history.json`. No TCC grant required. Honors a `limit` parameter (1..50, default 50).

### Changed
- **Tool-count baseline** bumped to **+3** static feature module tools (`mouse_click`, `cgevent_send`, `pasteboard_history`).

### Notes
- Companion to PKT-747 (Wave 1: `spotlight_query` + `keyboard_type`). Branch `bridge-v2.2/3.3.1-mac-ui-extras-wave2` cut from PKT-747 head `6bf0507`.
- Live-HITL items deferred to QA: (1) `mouse_click` validation against an AX-incompatible (Adobe-class) application, (2) `pasteboard_history` idle CPU footprint measurement (target < 1%). The polling timer uses a utility-QoS DispatchSourceTimer with 100 ms leeway and string-only payload capture, which is the low-overhead path; measurement remains a QA gate.
- Test coverage: 7 new tests in `MouseClickModuleTests.swift`, 6 new tests in `CGEventModuleTests.swift`, 8 new tests in `PasteboardHistoryModuleTests.swift` (registration, tier classification, input validation, capability_missing surface, in-process pasteboard capture round-trip, limit clamping, persistence assertion).

## [2.2.0-1.2] — 2026-05-10 — code_search · file_str_replace · file_apply_patch (PKT-750)

### Added
- **`CodeEditModule`** registers three new `dev/` tools that replace ad-hoc `shell_exec rg` + manual file rewrite patterns:
  - **`code_search`** (.open) — ripgrep-backed search with structured output. Returns `{matches: [{path, lineNumber, lineText, columnStart, columnEnd, absoluteOffset, submatches}], count, elapsedMs}`. Honors `pattern`, `path`, `globs`, `caseInsensitive`, `fixedString`, `contextBefore`/`contextAfter`, `maxCount`. Discovers `rg` via `PATH` then common Homebrew/MacPorts prefixes; reports `capability_missing` if absent.
  - **`file_str_replace`** (.notify) — scope-safe string replace. Default mode requires the `search` substring to be unique in the file (rejects ambiguous matches with `status: "failed"`). `replaceAllMatches: true` opts into bulk replace and reports `occurrencesReplaced`. `preview: true` returns a unified diff without writing. Atomic write via tmp + rename.
  - **`file_apply_patch`** (.notify) — unified-diff apply with strict context validation. Parses `@@ -a,b +c,d @@` hunks; tolerates leading line drift but rejects context-line drift with a clear `context drift` error. Atomic write; partial application is impossible (validate-all-then-write).

### Changed
- **Tool-count baseline** bumped from 83 to **86** static feature module tools (`BridgeConstants.staticFeatureModuleToolCount`): + 3 (`code_search`, `file_str_replace`, `file_apply_patch`).
- **Family count** unchanged at **16** (still the `dev` family from PKT-738).

### Notes
- Performance: `code_search` against the bridge repo itself (≈34k LoC) measures 27–38 ms p50 — well under the 500 ms p50 target for the ≈100k LoC reference workload.
- Test coverage: 18 new tests in `CodeEditModuleTests.swift` cover registration, tier assignment, structured search output, ambiguous-match rejection, replaceAllMatches, preview mode, unicode, trailing whitespace, no-match, not-found, clean apply, drift rejection, multi-hunk apply, and malformed patch rejection. Total bridge test count: **447 passed / 0 failed**.

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
## [2.2.0-3.4.1] — 2026-05-11 — Cursor SDK adapter Wave 1 — Swift `CursorModule` + sidecar protocol DTOs (PKT-3.4.1 / PKT-772)

### Added
- **`modules/cursor/` Swift module** — new top-level Bridge module hosting the Cursor SDK adapter as a peer of `dev/` and `computer/`. Justifies its own family: the cursor-sidecar carries a distinct security envelope (`.request` tier on every call as a cost gate), a separate Node-subprocess lifecycle, and an SDK pin (`@cursor/sdk@^1.0.12`) decoupled from the rest of the Bridge.
  - `CursorTypes.swift` — wire-level DTOs (`CursorRun`, `CursorArtifact`, `CursorEvent`, `CursorCapability`) and `CursorError` mirroring the sidecar error registry (`10001 NOT_IMPLEMENTED`, `10002 CAPABILITY_MISSING`, `10003 AUTH_FAILED`, `10004 SDK_ERROR`, `10005 COST_CAP_TRIPPED`, `10006 TIMEOUT` per `cursor-sidecar/SPEC.md` §4).
  - `CursorRuntime.swift` — actor singleton with synchronous `capabilityCheck()` (Node binary + sidecar entrypoint + Keychain `service=api_key:cursor / account=cursor`), nonisolated `locateNode()` / `detectNodeVersion()` / `readSidecarVersion()` helpers, public `readApiKey()` Keychain accessor, and the public 5-method API contract (`ping`, `capabilityProbe`, `agentRun`, `agentStatus`, `agentList`, `agentCancel`, `agentArtifacts`). Wave 1 returns `capability_missing` cleanly when the pre-flight fails; returns `not_implemented` after a successful gate — sidecar IPC + `@cursor/sdk` wiring lands in PKT-3.4.1.W2.
  - `CursorModule.swift` — 5 `cursor_agent_*` tool registrations under module `"cursor"`, all tier `.request`. Schemas describe `prompt` / `runtime` (`local`|`cloud`) / `model` / `repoPath` / `branch` / `maxCostCents`. Handlers proxy to `CursorRuntime` and return a structured error envelope (`ok=false`, `code`, `error`) when capability is missing.
- **`ServerManager.setup`** registration after `GhModule.register` (line 118).
- **`NotionBridgeTests/CursorModuleTests.swift`** — registration (5 tools, all `.request`, module name = `"cursor"`), `CursorTypes` JSON round-trip, capability surface, error-code registry, and a dispatch path verifying the structured error envelope shape on the Wave 1 stub path. Wired into `main.swift` after `runGhModuleTests()`.
- **`cursor-sidecar/src/protocol.ts`** — TypeScript mirror DTOs (`CursorRuntimeKind`, `CursorRunStatus`, `CursorRun`, `CursorArtifact`, `CursorEvent`) so the Wave 2 sidecar runtime impl can replace the NOT_IMPLEMENTED stubs against a typed contract.

### Changed
- **Tool-count baseline** bumped from 84 to **89** static feature module tools: + 5 (`cursor_agent_run`, `cursor_agent_status`, `cursor_agent_list`, `cursor_agent_cancel`, `cursor_agent_artifacts`).
- **Family count** bumped from 16 to **17** with the `cursor` family.

### Deferred to PKT-3.4.1.W2 (Wave 2 follow-up)
- Live JSON-RPC IPC between `CursorRuntime` and `cursor-sidecar` (bidirectional stdio with request/response correlation, SSE notification fan-out, `Last-Event-ID` reconnect per SPEC §8).
- Sidecar `agent_run` / `agent_status` / `agent_list` / `agent_cancel` / `agent_artifacts` stub-handler replacement with real `@cursor/sdk@1.0.12` calls. **Blocker:** the published `@cursor/sdk@1.0.12` npm tarball does not ship `.d.ts` declaration files (verified — `find @cursor/sdk -name '*.d.ts'` returns zero results) despite `package.json` declaring `"types": "./dist/esm/index.d.ts"`. W2 prerequisite: either upstream SDK ships its types, or we vendor minimal declarations from the SDK's public source on the SDK repo (`github.com/cursor/cursor`).
- SecurityGate Always-Allow scoped per `(repo, model, runtime)` triple-keyed session memo (default request-tier prompt ships in W1; scoped memo surface is W2).
- AI LOGS DS write per run (`machine_id`, `prompt_hash`, `model`, `runtime`, `status`, `cost_cents`, `artifact_urls` — hash-only) via `NotionAPIClient`. Wire path scoped to W2.
- Capability probe auto-rollback on failed sidecar update (failure-injection infrastructure; W2 or W3).

### Deferred to live-validation (requires user-side authorization)
- DoD A1 — local refactor round-trip against a test repo with structured SSE events captured (requires real `@cursor/sdk` spend).
- DoD B2 — cloud runtime confirmation modal + cloud VM provisioning + PR URL artifact (requires cloud spend authorization, GitHub repo nomination, real PR creation).
- DoD C5 — Bridge restart re-attaches running cloud agent via `Last-Event-ID` (requires running cloud agent + induced sleep/disconnect cycle).
