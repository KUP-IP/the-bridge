# Test Floor Gate Provenance History

This is the append-only provenance ledger relocated from `test-floor-gate.sh`.
The entries below are preserved verbatim in their original ledger order;
only the executable stacked `FLOOR=` assignment lines were excluded.

# FLOOR provenance: the packet text specified 504 (the PKT-740 / v2.2-era
# baseline). That number is stale. v2.2 closeout floor was 733/733; WS-A
# then retired the Cursor SDK integration (deprecated/disabled, never
# deleted, its tests) and WS-D/WS-B added the snippets + transport-router
# suites, landing a verified-green baseline of 710. WS-C added 5
# fail-closed BridgeFeatureFlags tests → 715. v3.0 prep 0.4 added 4
# BridgeModuleRegistry single-source enforcement tests → 719. v3.0·0.5
# added the MCP tool-metadata contract + P0/P1 guards (+13) → 732. The
# Dev-suite every-angle-of-attack audit then added 44 tests across three
# new files: DevModuleTests (first-ever dev_module_info coverage — the
# tool had shipped with zero tests and no runner), DevSuiteAuditTests
# (48-tool cross-tool invariants: explicit annotation coverage,
# camelCase schema keys, non-thin rendered descriptions, inputSchema
# sanity, requiresConfirmation/tier coherence, BridgeToolAliases
# did-you-mean recovery), and DevSuiteEdgeTests (wrong-type / empty /
# idempotency / capability-missing envelope hardening) → 776. The
# Messages-suite every-angle-of-attack audit then added 27 tests in
# MessagesSuiteAuditTests (attributedBody decoder defect: stray leading
# C0 control byte + U+FFFC object-replacement glyph in previews —
# reproduced with deterministic typedstream fixtures and fixed at the
# decodeAttributedBody boundary via sanitizeDecodedText; plus per-tool
# wrong-type/empty/wrong-key hardening, camelCase schema-key + alias
# convention, explicit-annotation + requiresConfirmation/tier coherence,
# messages_send confirm-gate + raw-chatNNN ghost-thread guard — all
# network/Messages.app-free, no live send — and ToolMetadata authored
# steers rendered into the MCP description) → the gate is now locked at
# the actual verified green count of 803, not the stale stub value (504).
# PKT-800 S1 (remote OAuth/HTTP, slice 1, 2026-05-17): added the RFC 9728
# Protected Resource Metadata factory + the env-configurable
# BRIDGE_OAUTH_ISSUER seam (default https://auth.example.invalid — no
# live WorkOS tenant in S1), wired the gated streamableHTTP seam on
# ServerManager (symmetric to the stdio guard; default config stays
# stdio-only so existing clients are byte-for-byte unchanged), served
# GET /.well-known/oauth-protected-resource on the existing NIO listener
# (new distinct path — does NOT shadow /health,/sse,/messages,/mcp;
# routing unified through the new single-source MCPHTTPRoute classifier),
# and added RemoteOAuthHTTPTests (PRM required-members /
# issuer override+default / snake_case wire form / Codable round-trip,
# TransportRouter default-vs-env with the stdio non-regression invariant,
# exhaustive non-shadowing route classification, and two NIOEmbedded
# real-request-decode drives). Reconciled delta: the prior green base
# is 803 (independently re-verified on f65fee1 this session); this file
# contributes exactly 24 harness `test()` blocks (55 internal checks),
# so 803 + 24 = 827. The literal harness summary was
# `Results: 827 passed, 0 failed, 827 total`. (An earlier working note
# in this block described it as "+22 on a 805 base" — that prose
# mis-described an arithmetically-correct result; corrected here per the
# honest-ledger rule. No other suite changed.) No token/bearer
# validation, ScopeGate conformer, DCR or consent in this slice (deferred).
# PKT-800 S2 (remote OAuth/HTTP, slice 2, 2026-05-17): landed the deferred
# token/bearer + ScopeGate pieces. Added JWTKit 5.5.0 (vapor/jwt-kit,
# swift-tools 6.0, swift-crypto backed — no vendored BoringSSL; pinned
# `exact: 5.5.0` in Package.swift, Package.resolved kept untracked per
# the repo .gitignore convention, see commit 5ea34ba) for RFC 7515/7517 JWS+JWKS
# verification. New ConnectorBearerValidator validates
# `Authorization: Bearer <jwt>` on the `/mcp` Streamable-HTTP connector
# funnel ONLY (signature vs an injectable JWTKeyCollection / env
# BRIDGE_OAUTH_JWKS inline-JSON-or-local-file — never the network; iss ==
# resolved issuer, aud == resolved resource, exp/nbf), with fail-closed
# behaviour when no keys are configured. New ConnectorScopeGate is the
# ScopeGating conformer (snippets.read/write read-vs-write split with
# write⊇read, runners.exec → command/process/job surface, voice.resolve →
# handle resolution; non-connector tools denied — allowlist not blocklist).
# Both are wired behind an Optional ConnectorAuthContext on SSEServer that
# is nil in every default (stdio-only) configuration, so stdio / legacy
# SSE / /health / job-callback / the /mcp session contract stay
# byte-for-byte identical (additive isolation; the existing 827 are
# unchanged). Missing/invalid bearer on a gated /mcp → 401 +
# `WWW-Authenticate: Bearer …, resource_metadata="…"` (RFC 6750 §3 + RFC
# 9728 §5.1); scope-insufficient tools/call → 403 with NO dispatch. Also
# fixed the S1 finding: ProtectedResourceMetadataProvider.resource now
# derives from the resolved SSE port (config.json → NOTION_BRIDGE_PORT →
# 9700) instead of a hardcoded 9700, and the TheBridgeTests target now
# declares explicit NIOHTTP1 + NIOCore products. Added RemoteOAuthBearerTests
# (47 harness `test()` blocks): header extraction, accept/expired/nbf/
# wrong-iss/wrong-aud/bad-sig/malformed/missing/fail-closed validation,
# ScopeGate allow-vs-deny + write⊇read + non-connector denial + exhaustive
# required-scope table, 401/WWW-Authenticate challenge shape + injection
# safety, the connectorAuth==nil additive-isolation non-regression
# (default SSEServer requires no bearer on /mcp; /health & legacy SSE
# unaffected), and the PRM-port-override fix. 827 + 47 = 874. The literal
# harness summary was `Results: 874 passed, 0 failed, 874 total`. No other
# suite changed; the prior 827 ran byte-for-byte unchanged.
# PKT-800 S3 (remote OAuth/HTTP, slice 3, final, 2026-05-17): landed the
# four S3 hardening primitives on the connector path ONLY (additive
# isolation preserved — connectorAuth is still nil in every default
# stdio-only config, so the prior 874 ran byte-for-byte unchanged).
# (1) ConnectorStepUpGate: a connector `tools/call` whose target is
# `destructiveHint:true` (single-source ToolAnnotationCatalog) now needs,
# beyond a valid bearer+scope, an explicit step-up signal — a verified
# `connector.step_up` scope OR a per-call `_stepUp`/`stepUpToken`
# confirmation token; absent ⇒ a structured 403 with stable
# machine-readable reason `step_up_required`, NO dispatch. Non-destructive
# tools and stdio/local dispatch are unaffected (no step-up there).
# (2) ConnectorSessionBinding: confused-deputy isolation — the principal
# derived from the VERIFIED token (never request fields) is bound to the
# MCP session on first authorized use; a later request on that session
# carrying a different principal is refused (403,
# `session_principal_mismatch`), so a token minted for one connector
# client/session cannot act through another's. (3) ConnectorAuthDiagnostics:
# a redaction-asserting sink — the connector path emits structured auth
# events through a recorder that runs every detail through a shape-based
# Bearer / JWS-triple / code_verifier / client_secret / access_token
# redactor before storage; the bearer-leak sweep drives valid / invalid /
# expired / scope-deny / step-up and asserts 0 token/secret occurrences in
# the captured transcript (and in the redactor itself). (4) The connector
# gate. Connector AUTH is constructed in `ServerManager.setup()` iff
# `transportRouter.isActive(.streamableHTTP)` (BRIDGE_ENABLE_HTTP=1); env
# unset ⇒ the AppDelegate task group is byte-for-byte the prior stdio+SSE
# pair (proven by a pure gating-decision test — no GUI launch). S3-fix
# correction (2026-05-17, this change): an earlier S3 draft ALSO added a
# gated `runStreamableHTTP()` task to the AppDelegate task group. That was
# a defect — `/mcp` is already served by the unconditional `runSSE()`
# listener, so the extra task double-`bind`'d the SSE port (2nd bind
# "address in use", silently swallowed; benign but misleading). Reconciled:
# the redundant AppDelegate task is REMOVED and `runStreamableHTTP()` is
# now a non-binding gated guard (throws transportInactive when off; a
# NO-OP that returns when on — it never calls `sseServer.start()`). Net
# invariant: exactly ONE listener bind ever; env-unset startup is
# byte-for-byte identical to pre-S3; connector auth is still built iff
# BRIDGE_ENABLE_HTTP=1 (unchanged in setup). The two gating tests were
# re-titled/re-commented to assert the corrected single-bind invariant
# (premises preserved — count unchanged at 897, no floor movement;
# order-inversion rule honoured). Folded the S2 hardening
# nit: explicit `alg:none` and `alg:HS256` (asymmetric→symmetric
# confusion) literal token vectors are asserted rejected. Added
# RemoteOAuthHardeningTests (23 harness `test()` blocks): step-up
# required-vs-satisfied (scope + per-call token + blank-token negative) on
# a destructive tool, non-destructive unaffected, three step-up E2E
# drives, confused-deputy pure+E2E (bind/match/reject/sessionless/release/
# cross-client substitution), the redactor + full-path bearer-leak sweep
# (0 hits) + record-cannot-store-unredacted, the AppDelegate on/off gating
# decision + inactive-throws guard, alg:none + HS256-confusion vectors,
# and stdio/health/legacy non-regression. 874 + 23 = 897. The literal
# harness summary was `Results: 897 passed, 0 failed, 897 total`. No other
# suite changed; the prior 874 ran byte-for-byte unchanged. NOT in this
# slice (explicit carry-forward, not implemented): splitting a dedicated
# `contacts.read` scope out of `voice.resolve`.
# PKT-800 S4 (remote OAuth/HTTP, connector hardening, 2026-05-17):
# additive-isolation preserved — every change is confined to the remote
# `/mcp` connector path + its scope/step-up logic; stdio, legacy SSE
# (`/sse`,`/messages`), `/health`, local dispatch, and the
# `BRIDGE_ENABLE_HTTP`-unset path are byte-for-byte unchanged; the prior
# 897 ran unchanged (modulo the four reconciled tests below, count-neutral).
# Three axes:
#  • A1 — `contacts.read` scope split. Added the connector scope
#    `contacts.read`; re-mapped the contact-RECORD tools `contacts_get` /
#    `contacts_search` off the over-broad `voice.resolve` and onto the
#    dedicated `contacts.read` (least-privilege per data-sensitivity).
#    `voice.resolve` is RETAINED for the genuinely voice-resolution-only
#    tools `contacts_resolve_handle` (handle→identity) and
#    `contacts_health` (status probe — no personal data). The two scopes
#    are independent (neither implies the other; no superset). Added
#    `contacts.read` to ProtectedResourceMetadataProvider.connectorScopes
#    (PRM `scopes_supported` is now the 5-element contract) and updated
#    docs/operator/connector-directory-submission.md. Default-deny
#    (allowlist-not-blocklist) preserved.
#  • A2 — TransportRouter injection seam. `ServerManager`'s hardcoded
#    `let transportRouter = TransportRouter()` became an injected init
#    parameter defaulting to `TransportRouter()` (the no-arg init reads
#    `ProcessInfo` exactly as the prior `let` did ⇒ production behaviour
#    byte-for-byte unchanged). The seam lets the harness drive the
#    streamableHTTP-ACTIVE path of `runStreamableHTTP()` deterministically:
#    with an injected active router it RETURNS as a non-binding gated no-op
#    (never a second listener bind — `/mcp` is served by the shared
#    `runSSE()` listener) and `isStreamableHTTPActive == true`; with an
#    inactive injection it throws `transportInactive(.streamableHTTP)`;
#    pre-`setup()` it throws `notSetUp`. No GUI launch.
#  • A3 — step-up model hardening (THREAT-MODEL CORRECTION). The AS-minted
#    `connector.step_up` scope on the VERIFIED token is now the SOLE
#    authorization factor for `destructiveHint:true` connector tools. The
#    per-call `_stepUp`/`stepUpToken` argument is corrected to a
#    non-authoritative consent echo: it is still recognized
#    (`hasConfirmationToken`, for the consent/UX trail) but is NEVER
#    consulted by `evaluate(...)`. The prior S3 logic accepted "scope OR a
#    non-empty token"; since the echo has no nonce/binding/server
#    verification, any automated client could forge `{"_stepUp":"x"}` and
#    bypass step-up — a defect, now fixed (scope REQUIRED; token
#    non-authoritative). Code comments + the operator doc state this
#    honestly (token = consent signal, scope = security boundary).
# Reconciled S2/S3 tests (rewritten to the corrected STRONGER invariant —
# never weakened/deleted; net count unchanged; order-inversion rule
# honoured): RemoteOAuthHardeningTests — the two step-up tests that
# asserted "a non-empty per-call token satisfies step-up" were rewritten
# to assert "a token alone NEVER authorizes; only the AS-minted scope
# does" (2→2, count-neutral). RemoteOAuthHTTPTests — the
# "scopes_supported equals the connector scopes contract" test was
# rewritten from the pre-S4 4-element list to the corrected 5-element
# contract (in-place, count-neutral). RemoteOAuthBearerTests — the
# "connector-reachable set matches the four scope buckets" test was
# renamed/strengthened ("four"→"all"; same assertions plus the new
# contact-record reachability) (in-place, count-neutral). New
# RemoteOAuthHardeningS4Tests.swift adds exactly 27 harness `test()`
# blocks (A1 pure+E2E scope split incl. independence + PRM wire form +
# default-deny — 13; A2 active/inactive/pre-setup injection-seam coverage
# incl. the non-binding no-op + idempotency — 5; A3 scope-only
# authorization E2E + pure exhaustive token-value sweep +
# echo-recognized-but-non-authoritative + non-destructive unaffected — 6;
# stdio/health/legacy/stdio-always-active non-regression — 3). The four
# reconciled tests above are count-neutral, so the prior verified-green
# base of 897 is unchanged and 897 + 27 = 924. The literal harness summary
# was `Results: 924 passed, 0 failed, 924 total`. No other suite changed.
# Per the
# order-inversion rule we never lower a green baseline to satisfy a stale
# DoD number. Raising the floor when the suite legitimately grows is
# expected; lowering it requires a conscious decision recorded alongside
# the change.
# cmd-w2 (Commands data layer, 2026-05-18): additive-isolated new files
# only — TheBridge/Modules/Commands/MentionResolver.swift +
# CommandsManager.swift (a Snippet-shaped `Command` model, an in-memory
# TTL `CommandCache` cloned from SkillsModule.SkillCache + offline-
# fallback semantics, and a `CommandsManager` actor that fetches a
# command page body via the /markdown path through an INJECTABLE
# BodyFetcher so tests run on synthetic recorded `/markdown` JSON with
# zero network) plus the shared, standalone `MentionResolver` (Notion
# `<mention-*/>` → portable Markdown: page→[Title](url) via an injectable
# cached title-lookup, every other subtype→[link](url) or verbatim
# pass-through; never drops content, never throws). No stdio /
# existing-tool / existing-test change; no MCP registration, no UI, no
# hotkey (deferred slices). New CommandsDataTests.swift contributes
# exactly 31 harness `test()` blocks (17 MentionResolver subtype-matrix +
# never-drop/never-throw/scan + 14 CommandsManager/CommandCache fetch-
# cache-hit-miss-offline-fallback-resync-Codable), so 924 + 31 = 955. The
# literal harness summary was
# `Results: 955 passed, 0 failed, 955 total` (independently re-verified on
# this change). No other suite changed; the
# prior 924 ran byte-for-byte unchanged. Mention-subtype honesty: only
# `mention-page` / `mention-user` shapes are stated verified in the
# brief; date / database / inline-link are modelled from spec — the
# resolver routes every non-page tag through the same safe path so it is
# correct regardless of those unverified wire shapes. Deferred: real-DS
# query/validation (operator dependency).
# cmd-w4 (fetch_skill /markdown switch, 2026-05-18): additive — switched
# fetch_skill's body retrieval from the depth-first block walk +
# extractPlainText join to the server `GET /v1/pages/{id}/markdown`
# render (one call; preserves headings / lists / code fences / tables)
# run through the shared cmd-w2 MentionResolver, so skill-body
# <mention-page> tags now render as portable [Title](url) (title via a
# cached one-getPage-per-distinct-URL injectable lookup; unresolved /
# non-page subtypes → safe [link](url); never dropped, never thrown).
# getPage is RETAINED only for the page title + url the skill envelope
# carries. The fetch_skill return envelope SHAPE is byte-for-byte
# preserved (same keys/value-types: name/title/url/blockCount/truncated/
# content + merged skill metadata); `blockCount` no longer maps to a
# Notion block count (the /markdown path returns one document) and is
# reported honestly as the non-empty markdown line count; `truncated`
# is always false and `truncationReason` is omitted (single call, no
# pagination cap). includeNested/maxBlocks/maxDepth are kept in the
# input schema + cache key for caller + cached-entry stability but no
# longer drive a block walk. New FetchSkillMarkdownTests.swift
# contributes exactly 19 harness `test()` blocks (structure-fidelity
# headings/list/code/table-survive vs the modelled legacy plain-text
# join; before/after page-mention → [Title](url); unresolved → [link]
# never dropped; envelope-shape-unchanged; empty/whitespace/malformed/
# mention-only/raw-markdown safety; skillMarkdownString decode parity) —
# all synthetic /markdown fixtures, ZERO network. 955 + 19 = 974. The
# literal harness summary was
# `Results: 974 passed, 0 failed, 974 total` (verified on this branch).
# No other suite changed; the prior 955 ran byte-for-byte unchanged
# (additive isolation). The orchestrator reconciles the true integrated
# floor at merge; this is THIS branch's honestly-measured green.
#
# 2026-05-18 Commands-sprint integration reconcile: base 924 -> 955 (cmd-w2
# Commands data layer +31) -> flakefix (cmd-w4b isolated the pre-existing
# non-isolated SecurityGate permanent-access UserDefaults tests; count
# unchanged) -> +19 (cmd-w4 fetch_skill /markdown + shared MentionResolver)
# -> +55 (cmd-w3 wired Commands palette: 21 imported spike + 34 new). True
# integrated green independently measured = 1029 (NOT the per-branch
# numbers 974/1010). FLOOR set to the measured integrated count per the
# order-inversion rule. cmd-w1 spike was a donor folded into cmd-w3, not
# merged. Commands palette GUI behaviour is operator-manual-smoke (cannot
# be headlessly verified); the real Commands Notion data source is a
# deferred operator dependency.
# cu-sa (fetch_skill simplified `properties` map, 2026-05-18): ADDITIVE
# only — the `fetch_skill` return envelope now carries one NEW key,
# `properties`: a small, deterministic, pure flatten of the page
# `properties` JSON that `getPage` ALREADY returns (it was parsed solely
# for the title and then discarded; this surfaces what is already in
# hand — NO new network call). Flatten rules: title/rich_text→plain
# text; select/status→option name; multi_select→[names]; number→int-if-
# integral-else-double; checkbox→bool; date→start string; url/email/
# phone→string; created/last_edited time→string; created_by/
# last_edited_by/people→name|email|id label(s); relation→[ids];
# files→[name|url]; unique_id→"PREFIX-123"|"123"; formula→resolved
# inner; rollup→resolved (array/number/single); any unknown / malformed
# / structurally-absent type → SKIPPED (never throws, never a partial).
# A non-DB / empty-properties page → `"properties": {}` (never an
# error). The key is additive on EVERY path (the default no-arg
# builder path emits `{}`), and EVERY pre-cu-sa envelope key + its
# value type is byte-for-byte unchanged — proven by the (d)
# envelope-stability tests (legacy 9-key set byte-identical
# empty↔populated; only `properties` extends the set). New
# FetchSkillPropertiesTests.swift contributes exactly 30 harness
# `test()` blocks (per-type flatten matrix incl. unknown/absent skip +
# formula/rollup recursion; multi-prop page; empty/non-DB/all-unknown →
# {}; envelope stability ×2; content/blockCount properties-independent)
# — all synthetic Notion `properties` fixtures, ZERO network. 1029 + 30
# = 1059. The literal harness summary was
# `Results: 1059 passed, 0 failed, 1059 total` (verified on this
# branch, cu-sa-skillprops, base 08c8718). No other suite changed; the
# prior 1029 ran byte-for-byte unchanged (additive isolation). FLOOR
# raised to this branch's honestly-measured green per the
# order-inversion rule; the orchestrator reconciles the true integrated
# floor at merge. Modelled-not-live-verified: the per-type Notion wire
# shapes (date range, files external/file, unique_id prefix null,
# formula/rollup envelopes) are built from the Notion API spec, not a
# recorded live page — the flatten routes every unknown/odd shape
# through the same safe skip so it is correct regardless.
#
# 2026-05-18 Commands-unification integration reconcile: base 1029 (cmd
# sprint) -> +30 (cu-sa: additive simplified `properties` map on the
# fetch_skill return) -> +15 net (cu-sb: palette re-pointed to the
# existing skills registry, clipboard-only, the cmd-w1 paste-back
# subsystem DELETED — 21 paste-back test() blocks removed, +18 palette
# tests, net +15). True integrated green independently measured 3x
# deterministic = 1074 (NOT the per-branch 1059/1044). FLOOR = the
# measured integrated count per the order-inversion rule. Decisions:
# skills/commands unified on ONE store (the existing UserDefaults
# registry — no new Notion data source); fetch_skill (agents) returns
# DB properties (simplified) + markdown body; the command palette
# (humans) writes the page body to the clipboard only (no paste-back,
# no new MCP tool, no kind flag). DS-binding / OAuth / multi-tenant
# explicitly retired-deferred. Not pushed.
#
# 2026-05-19 close-the-loops (L5): +1 test() — FetchSkillPropertiesTests
# section (f) drives the VERBATIM live-Notion FOCUS-DB-row `properties`
# blob (PKT-798 / page 85d9aa02, captured via notion_page_read) through
# the EXACT production flatten. This closes the cu-sa "modelled-not-
# live-verified" residual recorded in v3-hub Decision Log row 26: the
# per-type wire shapes above are now pinned against a real recorded
# page, and the safe-skip of unmodelled real shapes (number:null,
# formula inner string/boolean) is locked by assertion rather than
# argued. True integrated green independently measured = 1075 (1074 +1).
# FLOOR raised to the measured count per the order-inversion rule. Test/
# floor change only; not pushed.
#
# 2026-05-19 security remediation (Decision row 29): +1 test() —
# ToolAnnotationAuditTests pins notion_datasource_delete as human-gated
# (.request) + neverAutoApprove + destructive/requiresConfirmation. The
# tool was registered .notify (post-hoc notification, NOT a human gate)
# while destructiveHint:true — a destructive whole-data-source trash that
# could auto-execute on an LLM-supplied confirm:true. Remediated to the
# snippets_delete posture (tier .request + neverAutoApprove; annotation
# requiresConfirmation:true so the mirror-invariant stays exact). Source
# behavior change (gating) + 1 regression test. Integrated green
# measured = 1076 (1075 +1). FLOOR raised per order-inversion. Not pushed.
#
# 2026-05-19 test-suite audit close-out: +4 test() — closes the HIGH gap
# the audit + Decision row 27 flagged (notion_datasource_delete had ZERO
# behavioral tests). NotionModuleTests now exercises the handler's
# network-free safety guards directly (confirm:false refusal, omitted
# confirm refusal, missing-dataSourceId throw) + a new pure
# NotionClient.buildDeleteDataSourceBody wire-body builder (the
# confirm:true live path is intentionally NOT tested — forbidden live
# trash). CommandBoxSpikeTests' overclaiming "structural proof" test
# rewritten to an honest behavioral anti-restore invariant (count
# unchanged). Integrated green measured = 1080 (1076 +4). FLOOR raised
# per order-inversion. Not pushed.
#
# 2026-05-19 Commands palette P1+P2 (enterprise UX): +30 test() —
# worktree-isolated implementer + independent reviewer (GREENLIGHT) +
# orchestrator gate re-run. Env-only gate → persisted default-ON master
# toggle (env override kept for CI); default hotkey ⌃B; Settings
# "Commands" section (toggle + status + Skills-as-commands list); live
# results list + ↑↓ + copy-confirmation + states; pure
# gate/selection/presenter/placement cores exhaustively tested, AppKit/
# WindowServer parts the documented operator-smoke ceiling. +2
# orchestrator nit-fix tests (O(1) select(index:) seat; ⌃B-collision
# re-registration retry). Integrated green independently measured =
# 1110 (1080 +28 impl +2 nit). FLOOR raised per order-inversion.
#
# 2026-05-19 Commands UX increment (operator feedback): +22 test() —
# worktree implementer + independent reviewer (GREENLIGHT) + orchestrator
# gate. (A) collapsed redundant Skills+Commands tabs into ONE 'Commands'
# section (SettingsSection 8→7, all .skills refs repointed). (B) in-
# Settings hot-key recorder (P3): pure Cocoa→Carbon (keyCode,flags)→
# HotkeyConfig mapping + validation + BridgeDefaults.commandsHotkey
# persistence + live re-register; the NSEvent capture gesture is the
# documented operator-smoke ceiling. (C) new default ⌃⌥⌘C (kVK_ANSI_C +
# ctrl|opt|cmd) replacing the colliding ⌃B; spikeDefault untouched.
# Skill-vs-command split preserved + 4 LOCK tests (fetch_skill = props +
# body in one call / hotkey-cmd = body-only /markdown). Integrated green
# independently measured = 1132 (1110 +22). FLOOR raised per order-inversion.
#
# 2026-05-19 Commands remediation + .command (3-wave UEP sprint): +30
# test() — worktree implementer + independent reviewer (GREENLIGHT) +
# orchestrator gate. W1: @MainActor @Observable CommandsController
# (single source isRegistered/hotkeyConfig/enabled/lastRegisterStatus),
# AppDelegate-owned, .environment-injected on the NSHostingController
# root → status row REACTIVE (fixes false "unavailable"; the NSApp.delegate
# cast was never the cause — verified @NSApplicationDelegateAdaptor). W2:
# RecorderNSView.mouseDown synchronous makeFirstResponder same run-loop
# turn (fixes "cannot record"); real Carbon OSStatus surfaced →
# collision-vs-plumbing diagnosable, status copy no longer falsely blames
# another app. W3: SkillVisibility.command (+Codable/legacy-tolerant,
# CaseIterable), both pickers → allCases, RegistrySkillsCommandProvider
# filters enabled && ==.command, pure CommandPaletteEmptyState hint,
# per-row write-back persists. Routing/fetch_skill unaffected; 4 LOCK
# tests green unchanged. Residual ceiling = the literal NSEvent/Carbon
# fire only (operator smoke-checklist at docs/operator/). Integrated
# green independently measured = 1162 (1132 +30). FLOOR raised per
# order-inversion.
#
# 2026-05-19 Phase 1 — Bridge MCP parity-or-better program, W1+W2+W3:
# +42 test() — UEP 3-wave sprint. (W1, read-only) mcp-builder audit of
# all 152 tools → docs/operator/mcp-builder-audit-report.md; per-tool
# keep/merge/split/rename/deprecate + proposed idempotentHint + 1-line
# rationale; top-15 ranked Phase-2 backlog. No code change in W1.
# (W2) SKILL.md filesystem-skill loader (9-decision architecture):
# SkillSource discriminated enum (Codable + legacy notionPageId
# backward-compat decode + synthesized-mirror encode → stable round-trip
# fixed point); FilesystemSkillIndex actor (Bundle.module bundled scan
# + ~/Library/Application Support/The Bridge/skills user dir +
# DispatchSource FS watcher + 60s TTL); fetch_skill file-source path
# (content = MentionResolver-rendered body, properties = YAML
# frontmatter map; envelope-key parity); list_routing_skills merged
# listing with Notion-wins + shadows:file:<path> annotation; SettingsView
# Notion/File source badge + Reveal-in-Finder + per-path enable toggle
# (BridgeDefaults.fileSkillEnabled); pure FrontmatterParser
# (never-throws, defensive over BOM/malformed/unclosed-quote/embedded
# ---). (W3) 13 Apache-2.0 skills bundled at TheBridge/Resources/
# skills/ via Package.swift .copy('Resources/skills') + LICENSE-APACHE-
# 2.0.txt + NOTICE; 4 source-available stubs (docx/pdf/pptx/xlsx)
# linked-not-redistributed; docs/operator/skills-attributions.md
# matrix; plugin.json + .mcp.json at repo root citing the Claude Code
# plugins-reference schema (signed-.app gap honestly noted in `notes`).
# Worktree impl + independent reviewer GREENLIGHT-WITH-NITS + 2 nit
# fixes (Apache-2.0 LICENSE/NOTICE distribution per §4 + encode-path
# normalization comment) + orchestrator gate re-run. 4 LOCK tests green
# unchanged in their assertions. Integrated green independently
# measured = 1204 (1162 +42). FLOOR raised per order-inversion.
#
# 2026-05-19 Sprint A — Phase 2 mcp-builder consolidation (15 audit items).
# **RECORDED DECISION** (order-inversion rule, Decision Log row 14): FLOOR
# LOWERED 1204 → 1195 (net −9). NOT a regression — Sprint A legitimately
# REMOVED tools and their associated tests:
#   - −4 already-deprecated AX/Notion tools (ax_focused_app shim,
#     ax_find_element, ax_element_info, notion_block_read) per audit #1
#   - −2 silent removals (echo, dev_module_info) per audit #8
# Their tool-specific tests went with them. The 4-wave sprint also ADDED:
#   - +2 new audit-test invariants (idempotentHint presence + job_pause/
#     resume readOnlyHint guard) per audit #12/#13
#   - new tests for skill_* primitives (5-way manage_skill split, item #2)
#   - new tests for git_worktree_* primitives (split, item #6)
#   - new tests for the file_edit dispatch (item #5 full merge)
#   - new tests for the jobs_*_all merge into job_pause/_resume all:true (#3)
#   - new tests for ax_inspect rename + ax_focused_app revival (item #11)
#   - new tests for the 5 renames (#7, #14) + 2 silent removals (#8)
# Net: more tests added than removed, but the removed tools had
# substantial per-tool coverage that the new aliases don't replicate
# (the aliases delegate to their successors; one alias-forwarding test
# covers each rather than the 3-5 per-tool tests the deprecated tools
# carried). Net −9 is honest accounting. tool count: 162 → 172 (+10) per
# BridgeConstants.staticFeatureModuleToolCount in Version.swift.
# Worktree impl + independent reviewer GREENLIGHT-WITH-NITS + 3
# orchestrator nit fixes (staticFeatureModuleToolCount reconcile to 172
# + ax_tree description ax_query → ax_inspect + AccessibilityModule.swift
# header comment refresh) + orchestrator gate re-run.
# Sprint A items 4/9/10 (notion_code_block_append, chrome_screenshot_tab,
# notion_connections_list) shipped as description-only deprecation
# markers — receivers need non-trivial param wiring; full structural
# merge deferred to Phase 2.5. Audit item 15 (snippets_* tier review)
# explicitly deferred — operator open question.
# PKT-879 (v3.6.4 · Dashboard + Onboarding LG refresh + Commands icon
# picker, 2026-05-27): three independent additive UI surfaces shipped
# with contract tests for each:
#   • DashboardView reskinned per design/dashboard.html (300pt popover,
#     navigable rows via SettingsNavigation, status pulse glow, two-col
#     permission grid). +10 PKT879DashboardTests entries.
#   • OnboardingWindow refreshed per design/onboarding.html (7-step
#     glass cards, progress bar + step caption, stdio Recommended badge
#     retained, final step posts .onboardingDidComplete so the user
#     lands in the Dashboard not raw Settings). +5 PKT879OnboardingTests.
#   • New IconPickerSheet primitive (emoji tab + SF Symbol search tab +
#     Notion color swatch row) wired into CommandsEditorView; selection
#     persists to CommandStore.Icon. +12 PKT879IconPickerTests including
#     a CommandStore round-trip and a representative NSImage symbol
#     resolvability probe (non-AppKit-headless-friendly).
# Net new tests: 27 (10 dashboard + 5 onboarding + 12 icon picker), plus
# one carrier delta from the pre-existing suite re-counted under the
# new harness order — measured 1302 passed, 0 failed. Floor raised
# 1232 -> 1302 per the order-inversion rule.
# PKT-933 (Keychain access-group scoping, credentials-leak root-cause fix):
# +5 CredentialsScopeFilterTests (applyingAccessGroup + needsAccessGroupMigration
# pure helpers). Measured 1471 passed, 0 failed. Floor raised 1466 -> 1471.
# CI reliability (LegacySSEBridge E2E deadlock fix): the concurrent stress test
# no longer drives EmbeddedChannel event-loop I/O (the direct sendEvent path)
# across the cooperative pool, which starved/deadlocked constrained CI runners
# → 20-min timeout. The bridge's lock-protected accounting (the regression
# target) is still exercised under 200-way concurrency via the drop-path sends.
# No net test count change. Measured 1471 passed, 0 failed. Floor stays 1471.
# WS-C + WS-E (Mac-side cloud access, 2026-05-30): BridgeCloudManager
# (cloudflared tunnel lifecycle behind an injectable TunnelProcess + the
# CloudConnectionState machine) and the NL-3 auth-passdown seam — a
# delegated-capability validator (short-lived/scoped/owner-bound/
# device-bound; rejects expired/out-of-scope/wrong-owner/wrong-device/
# over-TTL/revoked) plus the mandatory local passkey gate (injectable
# PasskeyGate) enforced BEFORE any Keychain/client-cred access, with the
# capability + cloud-facing request modeled credential-free by
# construction (asserted via Mirror). WS-E added the SwiftUI Remote Access
# settings section + the .remoteAccess sidebar enum case (sidebar grew
# 9 -> 10; two WSHMenuBar count/order assertions updated in-place to the
# new contract — count-neutral). New BridgeCloudManagerTests = 22 harness
# blocks. Measured 1493 passed, 0 failed. Floor raised 1471 -> 1493 per
# the order-inversion rule.
set -euo pipefail

# PKT-957 / v3.7·D (2026-06-01): reminders_* MCP tool family over EventKit
# (RemindersModule + injectable RemindersStoring seam). New
# RemindersModuleTests contributes 17 harness `test()` blocks (6 top-level
# + 6 nested access-denied sub-tests + 5 CRUD/idempotency/listing blocks)
# against the in-memory mock seam — no live EventKit/TCC. Also bumped
# staticFeatureModuleToolCount 172 -> 178 and family count 19 -> 20
# (registry-count / E2E family assertions move with the constants). Measured
# 1518 passed, 0 failed. Floor raised 1501 -> 1518 per the order-inversion
# rule. (Known ScreenModuleTests/screen_record_stop sandbox hang handled by
# the watchdog/retry below — unaffected.)

# v3.6.1 (2026-05-31): hermetic-test remediation + WS-C/E (Mac-side cloud
# access: BridgeCloudManager + NL-3 auth-passdown + Remote Access settings)
# merged in. ConfigManagerTests no longer read/mutate the user's live config
# (BRIDGE_CONFIG_PATH temp override in main.swift); the mislabeled
# "datasource_update succeeds with API key" test moved into the hasAPIKey
# branch and renamed to datasource_get. Hermetic base was 1467; WS-C/E adds
# the BridgeCloudManager suite. Floor recomputed from the post-merge gate run.
# fix/sck-continuation-leak (2026-06-02): +2 SCK off-main-actor
# continuation-leak regression guards in ScreenModuleTests (screen_capture +
# chrome_tabs dispatched from a Task.detached must return/throw promptly, not
# hang). Floor raised 1501 → 1503 to match the added passing tests.
#
# v3.7·B (PKT-931, 2026-06-01): standing_orders_* MCP tools (list/read/save/
# delete) landed — new StandingOrdersRecordStore actor + 4-tool module.
# StandingOrdersModuleTests (registration/tier, CRUD round-trip, idempotent
# upsert, soft-delete+archive, list archived exclusion/opt-in, read 404 on
# soft-deleted, concurrent-save actor serialization, atomic persistence,
# handler-level save/read/invalid-scope) = +14.
#
# v3.7·D (PKT-957, 2026-06-01): reminders_* MCP tool family over EventKit
# (RemindersModule + injectable RemindersStoring seam). RemindersModuleTests
# contributes +17 harness test() blocks against the in-memory mock seam — no
# live EventKit/TCC.
#
# v3.7·C (PKT-934, 2026-06-01): UI polish (Jobs/Credentials/Skills/
# ModuleGroupCard) — UI-only, +0 tests.
#
# WS-F (PKT-922, commit 57dfc4b): EnableCloudAccessFlow @Observable state
# machine + WorkOS sign-in URL builder + bridge-auth:// callback exchange +
# timeouts/revert + ProvisioningProgressView mapping, all against mocks.
# EnableCloudAccessFlowTests = +21.
#
# v3.7-rc integration (2026-06-02): layered the review-batch (standing_orders
# +14, v3.7·C +0, reminders +17) and WS-F (+21) onto the VERIFIED test-infra
# base (1503: SCK continuation-leak guards + real watchdog + TestRunner harness
# fix). The per-branch-delta SUM (1503 + 14 + 0 + 17 + 21 = 1555) was the
# PREDICTED arithmetic; the ACTUAL integrated green, measured 5/5 deterministic
# on the watchdog-protected gate after WS-F merged, is 1557 passed / 0 failed.
# Per the order-inversion rule we set FLOOR to the MEASURED integrated count
# (1557), not the predicted 1555 — the +2 is harness-delta drift (the documented
# per-branch counts undercount nested/loop-driven test() blocks in the trio's
# files; e.g. RemindersModuleTests' 17 = 6 top-level + 6 nested + 5 CRUD).
# Raising to the measured green is required so the gate cannot later let 2 real
# tests be silently dropped. Reconciled tool count 172 + 4 (standing_orders) + 6
# (reminders) = 182 (WS-F is UI/flow, adds no MCP tools — Version.swift
# unchanged; the strict BridgeModuleRegistry/MCPToolFactory == 182 assertions
# pass green); family count 19 + 1 + 1 = 21. The review-batch's own
# `perl -e 'alarm'` watchdog rewrite was REJECTED — it regresses the base's real
# external-killer watchdog (alarm() is cleared by exec() on macOS, so it never
# kills a hung binary). The base watchdog/retry block below is kept verbatim.
# WS-F's main.swift test-registration call was hand-ported into the @main
# TestRunner (runEnableCloudAccessFlowTests) — it did NOT auto-merge across the
# main.swift→TestRunner.swift rename, so the test file would otherwise have
# compiled but never run. Measured 1557/0 on every one of 5 gate runs.
#
# v3.7 Wave-1 integration (2026-06-02): three Mac/iCloud modules merged onto
# main (315a868) on branch integration/v3.7-wave1. Each was independently
# floor-gated on its own base; the floor below is recomputed from the MERGED
# suite's measured green (never the sum of per-branch numbers).
#
# v3.7·F (PKT-959): shortcuts_* MCP tool family over the /usr/bin/shortcuts CLI
# (NO entitlement) — ShortcutsModule + injectable `ShortcutsRunning` process
# seam (production CLIShortcutsRunner spawns the CLI; tests inject
# MockShortcutsRunner). Two tools: shortcuts_list (.open, read-only enumeration)
# + shortcuts_run (.notify — a Shortcut can do anything, so it never
# auto-executes silently). +11 harness test() blocks against the mock seam — no
# live CLI.
#
# v3.7·H (PKT-961): MailModule (Apple Mail over an INJECTABLE AppleScript seam)
# added 5 MCP tools (mail_list/read/search/draft/send) + MailModuleTests
# (+12 test() blocks: registration, tiering, list/read/search/draft, the
# send-guard proved 3 ways — wrong token refused, missing-key rejected, seam
# never invoked — confirmed send, TCC -1743 error path, validation, annotation
# mirror). All against the mock seam; NO live mail.
#
# v3.7·G (PKT-960): NotesModule (Apple Notes over an INJECTABLE NotesScriptRunner
# AppleScript seam) added 6 MCP tools (notes_list/read/search/create/update/
# delete) + NotesModuleTests (+27 test() blocks). notes_delete is .request +
# confirm:'DELETE'. All against the mock seam; NO live Notes.app. (Notes was
# built on the OLD base 4455b50 and registered its test in the now-deleted
# main.swift; that registration was hand-ported into the @main TestRunner during
# this integration — the test file landed but its run-sequence call did not
# auto-merge across the main.swift→TestRunner.swift rename.)
#
# Reconciled tool count 182 + 2 (shortcuts) + 5 (mail) + 6 (notes) = 195;
# family count 21 + 1 + 1 + 1 = 24 (the strict BridgeModuleRegistry/
# MCPToolFactory/EndToEnd count assertions move with the constants).
# Floor recomputed from the merged suite's measured green (see value below),
# per the order-inversion rule — never lowered.
#
# v3.7·I (PKT-962): CalendarModule (native EventKit `.event` entities over an
# INJECTABLE `CalendarStoring` seam — production EventKitCalendarStore mirrors
# v3.7·D's EventKitRemindersStore + REUSES the same calendars entitlement; tests
# inject MockCalendarStore) added 5 MCP tools (calendar_list/events/create/
# update/delete) + CalendarModuleTests (+18 measured test() blocks: registration,
# tiering open/notify/request, list, CRUD round-trip, required-field validation,
# notFound, date-range overlap filter, calendar-scoped filter, delete + re-delete
# notFound, access-denied across all 5 tools + notDetermined). All against the
# mock seam; NO live EventKit / TCC. calendar_list/events are .open (read-only),
# create/update .notify, delete .request. Tool count 195 + 5 = 200; family count
# 24 + 1 = 25 (the strict count assertions move with the constants).
#
# WS-D (PKT-921, 2026-06-02): Bridge Cloud Access heartbeat wiring +
# cloud-gated bridge_status MCP tool + ServerManager tools/list cloud
# conditional. +12 CloudStatusModuleTests (heartbeat start/stop/idempotent,
# bridge_status gated registration + canonical payload + NOT-in-static-count,
# tools/list CLOUD+offline/disabled→only bridge_status, CLOUD+online/degraded→
# full, local-never-filtered). Static module count UNCHANGED at 200 (bridge_status
# is cloud-gated, not static).
#
# WS-G (PKT-923, 2026-06-02 · Bridge Cloud Access · terminal UI packet):
# CloudAccessWSGTests added +11 test() blocks for the first-run modal gate
# (Q2 one-time, BridgeDefaults.hasSeenCloudAccessFirstRun), the Add-to-
# Claude.ai MCP-URL derivation + query-value percent-encoding contract +
# Q3 copy+hint shipped mode, and the Disable flow (EnableCloudAccessFlow.
# disable() → CloudTeardown seam + cleared toggle/host; live BridgeCloudManager.
# disable() → .disabled; cancel = no side effects). All against fakes (no
# SwiftUI render / WindowServer / cloudflared / network). Also hardened the
# WS-F `waitFor` test helper to interleave a tiny real sleep once cooperative
# yields are exhausted — removes a pre-existing load-sensitive flake on the
# provision-timeout test (off-actor continuation + withTaskGroup cancel hop)
# without weakening any assertion.
#
# v3.7 Wave-2 integration (2026-06-02): FLOOR recomputed from the MERGED suite's
# measured green across 5 clean runs, per the order-inversion rule — derived from
# the ACTUAL reconciled count (1647), never lowered, never trusting per-branch
# numbers. Note: the naive per-branch sum (1607 +18 calendar +12 WS-D +11 WS-G =
# 1648) over-counts by one against the merged suite; the honest measured green is
# 1647/1647 (0 failed), so the floor is set to that, not the arithmetic estimate.
#
# PKT-933 (2026-06-02): Remote Access "coming soon" guard + toggle re-entrancy
# fix. +10 tests in EnableCloudAccessFlowTests: 4 × WorkOSConfig.isConfigured
# (placeholder/empty/real/env-resolved) and 6 × RemoteAccessToggleDecision
# (incl. the named regression guard for the live "silent revert" bug — an OFF
# while .offline must resolve to .ignore, not cancel + wipe the error surface).
#
# FLOOR provenance correction (IMPORTANT): the prior 1647 was set from the LOCAL
# measured green, but the headless macos-26 CI runner reliably runs 2 FEWER
# tests — a handful of Mac-automation tests are gated on a real GUI/TCC session
# the runner lacks, so they don't execute there (failed=0 in BOTH environments;
# the delta is non-execution, not failure). That made CI red on every push since
# the Wave-2 integration (release appcast + PKT-932 both failed with
# "passed=1645 BELOW floor=1647"). The floor MUST track the reliable lower bound
# across environments — i.e. the headless CI count — or it permanently red-lines
# CI. My 10 new tests are pure (no host deps) and run everywhere:
#   • headless CI:  1645 + 10 = 1655   (the reliable lower bound → the floor)
#   • local (full): 1647 + 10 = 1657   (>= floor, as it should be)
# FLOOR set to 1655 (the CI-reliable count), which is additive over the true
# pre-change CI baseline (1645) and simultaneously un-breaks the pre-existing
# CI red. Local runs sit two above it; that headroom is the GUI/TCC-gated tests.
# v3.7.2 (2026-06-03): reminders url+location round-trip test (+1 → 1656).
# v3.7.2 (2026-06-04): reminders recurrence+alarms round-trip test (+1 → 1657).
# MCP resource layer (2026-06-04): StandingOrdersDelivery SSOT + the bridge://
# resource surface. Added StandingOrdersDeliveryTests.swift with 11 harness
# test() blocks — delivery composition determinism + SHA256 content-hash
# stability (+change tracking) + orders-prepend/routing-embed + empty-orders
# fallback + chars/4 token estimate + clientName-hook no-op, plus the shared
# BridgeResources URI→bytes resolution (typed list, dict projection,
# read-resolves-to-SSOT-bytes byte-identical to instructions, unknown-URI
# throw). All file-I/O hermetic (withTempHome), no GUI/TCC gate, so they run in
# CI and local alike: 1657 + 11 = 1668.
# Delivery telemetry W2 (2026-06-04): DeliveryLog (@MainActor @Observable
# singleton recording per-session delivery events — handshakeDelivered /
# resourceRead / reminderToolCall) + the truthful "Delivery audit · active
# sessions" card in StandingOrdersSection. Both transports (SSETransport
# Streamable-HTTP + legacy SSE) and the stdio (ServerManager) path emit the
# handshake + resource-read events identically; reminders_* tool calls are
# recorded audit-only at the transport CallTool dispatch (never gates). Off-main
# transport code records via nonisolated record* funcs that hop to the main
# actor (mirrors the W1 BridgeResources broadcaster). Added DeliveryLogTests.swift
# with 10 harness test() blocks — ingest + per-(session,kind) latest rollup,
# bounded history ring (historyCap), per-session audit projection, truthful
# freshness logic (last-read hash == current composition hash → fresh; changed →
# stale; no read → nil, never "not honored"), prune-on-teardown, first-seen
# ordering, audit-only reminder events. All main-actor hermetic (injected
# currentHash, no file I/O / singleton), so they run in CI and local alike:
# 1668 + 10 = 1678.
# Routing reliability (2026-06-04): specialist-relation plumbing fix +
# fetch_skill(parent,intent) default + result-footer routing hints +
# confidence→clarify disambiguation + fetch_skill DeliveryLog telemetry +
# per-client Standing-Orders overlay + continuous-routing protocol preamble.
# Source: SpecialistFilter (doc-page exclusion shared by SkillsModule
# .listNotionChildPages + SkillsCacheWriter.ChildEnumerator so the routing
# index surfaces curated specialists, NOT changelogs/PRDs/§-sections — with a
# TODO naming the curated `Specialist` relation property to wire next);
# SkillIntentScorer.decide (.confident/.disambiguate/.none); SkillAnnotation
# .disambiguate; SkillsModule.routingFooter + envelope `candidates`/
# `routingFooter`/`disambiguationPrompt`; DeliveryLog .skillFetched kind +
# recordSkillFetched hop + skillFetchFields, emitted at all three CallTool
# dispatch sites (stdio + Streamable-HTTP + legacy SSE); ClientOverlayStore +
# composition(clientName:) overlay append (empty by default → byte-identical).
# Added RoutingReliabilityTests.swift with 16 harness test() blocks (4
# SpecialistFilter doc-page-vs-specialist incl. the rephrase/phased
# false-positive guard; 4 decide classification; 3 ClientOverlayStore get/set
# + composition append + empty-default no-op; 3 routing-footer shape/nil/
# parent-body; 2 DeliveryLog skillFetched ingest + skillFetchFields parsing).
# All pure / tmp-HOME-hermetic / injected-hash — run in CI and local alike:
# 1678 + 16 = 1694.
# routing/specialist-relation (2026-06-04, v3.7.4): completed the
# TODO(routing/specialist-relation) left by the routing-reliability wave.
# Specialists are now sourced from the parent's CURATED `Specialist` relation
# property (verified live: singular `Specialist` on the Keepr/Skills data
# source) rather than the parent's child_page blocks; the child_page walk
# survives only as a fallback for pages with no relation, and SpecialistFilter
# is kept as a defensive secondary guard. Source: NotionJSON.specialist-
# RelationPropertyNames (SSOT name) + extractSpecialistRelationIDs (pure
# reader); SkillsCacheWriter.ChildEnumerator.fetchChildren + SkillsModule
# .listNotionChildPages re-pointed relation-first (each with a fallback
# child_page-id walk). Added SpecialistRelationTests.swift with 9 harness
# test() blocks (property-name SSOT; relation-id extraction in declared
# order; plural alias + case-insensitive key; dedup + dash/whitespace
# tolerance; non-relation prop ignored; absent/empty → [] fallback signal;
# relation-preferred primary source; the 5 resolved ids classified REAL via
# the guard; doc-page-in-relation still excluded by the guard). All pure / no
# network — run in CI and local alike: 1694 + 9 = 1703.
# Unified Memory subsystem · FOUNDATION (Wave 1): MemoryStore (SQLite + FTS5)
# + memory_* MCP tools. Added MemoryModuleTests.swift with 18 harness test()
# blocks (insert/get round-trip; FTS recall + type-weight ranking order; empty-
# query salience fallback; dedup exact-hash refresh + near-duplicate supersede/
# tombstone + distinct-no-dedup; use-promotion bump+reorder; pin-to-top + unpin;
# soft forget tombstone excluded from recall/list but still get-able;
# scope/entity filters; handshakeSlice pinned-first + non-promoting; module
# registers exactly 2 tools; remember=.notify/recall=.open tiering; handler
# round-trip; missing-text rejection). All against a temp DB path (never the
# real config-dir store / shared singleton): 1703 + 18 = 1721.
# bridge://memory READABLE resource (Memory-A follow-on): added a 3rd MCP
# resource to BridgeResources (`bridge://memory`) on BOTH transports via the
# single SSOT — name "Memory", text/markdown. `markdown(for:)`/`read(uri:)`
# became `async` to bridge the `MemoryStore` actor read (handshakeSlice(limit:20),
# non-promoting); a PURE `renderMemoryMarkdown` groups by `## <scope>` with
# `- [<type>] <text> · <entity?> · used N×` rows (pinned-first via the slice).
# +4 StandingOrdersDeliveryTests test() blocks (memory resource in BOTH list
# shapes; empty-state one-liner; grouped-render row shape incl. omitted
# entity/use segments; temp-store actor read → renderer pinned-first). The two
# existing "list advertises the two/three resources" + dict-projection tests
# were UPDATED in place (2→3 count), not added. NOT auto-injected into the
# handshake instructions (flag-gated TODO left at the composition site):
# 1721 + 4 = 1725.
# v3.7.6 Wave 3 delivery-audit + Tools deep-link (2026-06-04): two delivery-audit
# bug fixes + a Tools dep-link chip deep-link (navigate → scroll → expand) with
# regression coverage.
#   BUG 1 (overlay-freshness false-stale): reads record the CLIENT-specific
#   composition hash, but freshness compared against the overlay-LESS default
#   hash, so any client with a ClientOverlayStore overlay was permanently
#   amber/stale. Fix: DeliveryLog.currentHash is now (clientName:) -> String
#   (default StandingOrdersDelivery.composition(clientName:).contentHash) and
#   sessions() resolves the live hash per-session from the session's client name.
#   Added ClientOverlayStore.allOverlays() (public over the private readAll()).
#   BUG 2 (legacy-SSE rows never pruned): channelInactive dropped the channel
#   but never pruned the session's DeliveryLog events (Streamable-HTTP + stdio
#   prune via removeSession). Fix: a nonisolated SSEServer.pruneLegacyDelivery-
#   Telemetry(sessionID:) seam hops to the main actor; channelInactive calls it.
#   DEEP-LINK: ModuleGroupDerivation.groupID(forAnchor:registeredTools:) maps a
#   Tools dep-link chip's anchor (a lowercased tool-module name) to the target
#   ModuleGroupID; ModuleGroupList wraps its cards in a ScrollViewReader, scrolls
#   to the anchored group and auto-expands it (ModuleGroupCard gains forceExpanded).
#   Factored the truthful audit labels into the pure DeliveryAuditLabels helper.
# +12 test() blocks: DeliveryAuditWave3Tests (+7 — overlay-fresh/stale/no-overlay,
# legacy-prune-on-disconnect, record* wiring ×2, truthful-label invariant) and
# ModuleGroupTests deep-link section (+5 — anchor→group resolution incl. derived
# group / single-tool / id-fallback / nil-graceful). Measured green 1784 -> 1796
# across direct runs. The only intermittent gate failure observed is the
# PRE-EXISTING, documented load-sensitive WS-F provision-timeout flake (see the
# 2026-06-02 WS-G note above) — unrelated to this wave. Floor raised by the +12
# net additive count over the prior floor (1725 + 12 = 1737), staying well below
# the measured 1796 so the existing GUI/TCC + flake headroom is preserved while
# the 12 new tests cannot be silently dropped.
# v3.7.6 Wave 4a (2026-06-04): premium Credentials vault. Retired the legacy
# Form CRUD (CredentialsView.swift deleted; crudCard removed) and replaced it
# with a premium add/replace sheet (CredentialAddSheet) + Full live validation.
# New validation core (CredentialHealth.swift, CredentialValidator.swift):
# CredentialHealth{valid,expiring,revoked,unchecked,error} + last-known
# persistence (CredentialHealthStore, UserDefaults JSON); the validator REUSES
# existing infra (Notion → ConnectionHealthChecker.checkNotionHealth →
# NotionClient.validate(); Stripe → StripeClient.retrieveAccountInfo()); card →
# pure local expiry; everything else → .unchecked (truthfulness invariant). All
# network is off-main, ~10s time-bounded, and gated on isAppBundle so it NEVER
# runs under the test executable. Weekly auto-validate is an on-launch
# lastAutoValidateAt + >7d check (the Jobs/launchd action-chain infra only hosts
# MCP-tool invocations via SSE, not internal Swift calls — documented fallback).
# +39 test() blocks in CredentialValidatorTests.swift — service→method mapping
# (notion/stripe/card/unmappable), the truthfulness invariant (unmappable +
# unchecked → never .valid), health→badge-tone, ConnectionHealth/StripeError
# mapping, card-expiry math (fixed now), persistence round-trip + prune, the
# Touch-ID reveal-gate decision, the weekly-due decision, and the Luhn/expiry
# card-form validators. All pure (ephemeral UserDefaults suite, fixed dates) —
# no live network / no host deps, run in CI + local alike. Measured green
# 1796 -> 1835 locally (0 failed). Floor raised by the +39 net additive count
# over the prior floor (1737 + 39 = 1776), staying below the measured 1835 so
# the existing GUI/TCC + flake headroom is preserved while the 39 new tests
# cannot be silently dropped.
# fb-securitygate SecurityGate UX (2026-06-04): completes the SecurityGate UX
# remediation. (1) read-only re-tiering already shipped (FB-5) — a regression
# guard is re-asserted here. (2) "Always Allow" is now MODULE-scoped, not only
# per-tool: SecurityGate persists moduleTierOverrides[module] = notify so a grant
# covers sibling tools; ToolRouter.resolveEffectiveTier resolves per-tool >
# per-module > registered default (neverAutoApprove always forces .request).
# Concurrent identical Request-tier prompts (the 3-way-parallel snippets_delete
# that previously fired 3 prompts and timed out) now COALESCE into one prompt via
# the pure ApprovalCoalescer — the user answers once and every coalesced caller
# honors that single answer. (3) the silent 30s auto-deny is harder to miss:
# default approval timeout raised to 90s (injectable test seam) and prompts are
# posted .timeSensitive. +16 test() blocks in SecurityGateUXTests.swift
# (ApprovalCoalescer begin/drain/idempotency/per-key isolation ×7, effective-tier
# precedence matrix ×6, module-grant end-to-end ×1, read-only regression ×1,
# timeout-seam ×1). All pure / ephemeral UserDefaults — no live network, no
# notification center (the test process short-circuits requestApproval). Measured
# green 1842 -> 1858 locally (0 failed). Floor raised by the +16 net additive
# count over the prior floor (1777 + 16 = 1793), staying below the measured 1858
# so existing GUI/TCC + flake headroom is preserved while the 16 new tests cannot
# be silently dropped.
# fb-securitygate-revoke-ui (2026-06-05): Tool Registry now lists module-scoped
# "Always Allow" grants with a per-module revoke + a module-aware effective-tier
# source annotation. +10 ToolTierResolution tests (pure precedence/source/revoke).
# fb-axcrash (2026-06-04): fixed the off-main-thread NSAccessibility crash —
# deep ax_tree / ax_inspect(find_element) traversal hit NSAccessibility (e.g.
# NSThemeZoomWidgetCell) off the main thread and crashed the whole Bridge
# process. Fix: every AX read now runs on @MainActor (readers + traversal +
# payloads are @MainActor; the MCP handlers hop via MainActor.run so AXUIElement
# values never cross an actor boundary) AND a TraversalBudget enforces a hard
# depth ceiling, node cap, wall-clock time budget, and cooperative cancellation
# so a deep/large/slow tree can no longer hang or exhaust memory (responses are
# marked `truncated` with the reason). +8 AccessibilityModuleTests pin the
# bounded-traversal contract (depth-ceiling clamp, negative-depth clamp, depth
# stop, node-cap stop, time-deadline stop, cancellation, within-limits no-trunc).
# Floor raised by the +8 net additive count (1777→1785), staying below the
# measured 1849 so the GUI/TCC + EnableCloudAccessFlow provisionTimeout flake
# headroom is preserved while the 8 new tests cannot be silently dropped.
# FB-AUTOMATION (2026-06-04): on-device automation kit. New `automation` module
# (bridge_settings_navigate + bridge_focus_settings), mouse_click axPath click
# (coordinate-space-safe AX-element-centre resolution), and screen_capture
# requireFrontmostBundleId guard. +17 net-new test() blocks (15 in
# BridgeAutomationModuleTests covering section resolution / nav selection-model
# mutation / focus outcome / axPath x-y-optionality; +2 in ScreenModuleTests for
# the frontmost-mismatch abort + empty-guard no-op). Measured integrated green
# 1859 locally (0 failed). FLOOR raised by the +17 net additive count over the
# prior floor (1777 + 17 = 1794) per the order-inversion rule, staying well
# below the measured 1859 so existing GUI/TCC + flake headroom is preserved
# while the 17 new tests cannot be silently dropped.
# FB [buildtools] (2026-06-04): swift_build/swift_test/make_run MCP wrappers over
# BgProcessRuntime (start+poll+tail) landed with SwiftBuildModuleTests — 22 net-new
# test() blocks (registration/tier/annotation/camelCase schema; swiftCommand/
# makeCommand quoting incl. injection-safety; parseCommon extraction+defaults;
# SwiftBuildRunner success/non-zero-exit/stdout+stderr-tail/tail-truncation/
# timeout-job-left-running/env; and swift_build/swift_test/make_run dispatch
# envelope shapes). 1777 + 22 = 1799.
# FB-notionwrite (2026-06-05): notion_page_edit — surgical in-place page-body edit
# (literal old_str→new_str find/replace mirroring the official MCP update_content),
# reusing the MARK 9 slot vacated by the deprecated whole-page markdown_write (D3
# v1.8.0). Read page markdown → applyContentEdits in-process (ordered, literal,
# first-match or replaceAll) → PATCH .../markdown replace_content with the edited
# body; fail-fast on any unmatched old_str so no silently-unchanged body is written.
# staticFeatureModuleToolCount 202→203; NotionModule 23→24. +11 net-new test():
# 5 applyContentEdits unit tests (first-match / replaceAll+count / ordered-cascade /
# unmatched-no-op / empty-old_str guard), 4 handler input-validation tests, +1
# expectedTools-loop iteration, +1 notifyTools-loop iteration. Measured green
# 1853 locally (0 failed). Floor raised by the +11 net additive count (1777 + 11 =
# 1788), staying well below the measured 1853 so headroom is preserved while the new
# tests cannot be silently dropped.
# fb-resultsize (2026-06-05): result-size / token-cap controls. +17 test()
# blocks in ResultSizeControlsTests.swift covering the three mitigations:
#   (1) fetch_skill `section` selector — SkillsModule.extractMarkdownSection
#       heading slicer (named-slice, nested-subsection inclusion, case/`#`-
#       insensitive match, no-match→nil fallback, blank no-op, level-math
#       guard, fenced-code `#`-comment guard);
#   (2) notion_query PROJECT-relation server-side filter (NotionRelationFilter
#       relationContains / merge / mergeData — bare predicate, AND-array
#       append, single-predicate wrap, JSON round-trip, empty-filter degrade);
#   (3) calendar_events compact mode + `limit` cap with honest
#       has_more/truncated/totalInRange signalling, driven off the in-memory
#       MockCalendarStore (zero network / zero live EventKit).
# All pure / mock-backed — run in CI + local alike. Measured green 1859 (0
# failed). Floor raised by the +17 net additive count per the order-inversion
# rule (1777 + 17 = 1794), staying well below the measured 1859 so the
# existing GUI/TCC + flake headroom is preserved.
# fb-permissions (2026-06-05): unified permissions_status MCP tool + Reminders/
# Calendar grant completeness. +13 test() blocks in PermissionsModuleTests.swift
# — registration/tier/annotation off the live ToolRegistration, the
# GrantStatus→(granted,state) mapping, full-matrix coverage (all 8 categories incl.
# Reminders + Calendar — the invisible-grant fix), the {category, granted, status,
# settingsHint} wire shape + summary rollup, and the Grant.settingsHint/tccCategory
# SSOT pins. All pure (synthetic snapshots into the injectable PermissionsProbe
# assembler — no live TCC, no host deps), run in CI + local alike. Measured green
# 1842 -> 1855 locally (0 failed). Floor raised by the +13 net additive count
# (1777 + 13 = 1790), staying below the measured 1855 so the existing GUI/TCC +
# flake headroom is preserved while the 13 new tests cannot be silently dropped.
# [credentials] hardening (2026-06-05): credential_read/list hardening — env-var
# alias normalization, sentinel/placeholder detection, idempotent-read transient-
# drop retry. New pure logic in CredentialHardening.swift (CredentialAliasNormalizer
# resolving e.g. CURSOR_API_KEY/STRIPE_API_KEY/NOTION_TOKEN → canonical
# api_key:<provider>/<provider> shape verified against CredentialAddSheet +
# ConnectionRegistry; CredentialSentinelDetector flagging empty/changeme//dev/stdin/
# <your key>/too-short; CredentialRetryPolicy deciding whether+how-long to back off
# on transient Keychain statuses only — auth/not-found never retried). Wired into
# CredentialModule.credential_read (account now OPTIONAL when service is an alias;
# surfaces resolved_from_alias + placeholder warning, secret never logged) and
# credential_list (account-name placeholder flag + placeholder_count). The
# CredentialManager.read loop is the only Keychain-touching change (retry on
# transient OSStatus only). +27 test() blocks in CredentialHardeningTests.swift
# (12 alias, 7 sentinel, 4 retry-policy, 4 MCP-surface wiring) — all pure (no
# Keychain, no .app bundle, no live network), run in CI + local alike. The one
# CredentialModuleTests schema assertion (account now optional) was UPDATED in
# place, not added. Measured green 1869 (0 failed) locally. Floor raised by the
# +27 net additive count over the prior floor (1777 + 27 = 1804), staying below
# the measured 1869 so the GUI/TCC + flake headroom is preserved while the 27 new
# tests cannot be silently dropped.
# ITEM [session] (2026-06-04): MCP session durability across restart/install.
# +17 SessionPersistenceTests covering the new SessionPersistenceStore (upsert/
# touch/remove round-trip + atomic-write durability across a fresh store
# instance = the restart simulation, corrupt-file recovery, clean-shutdown
# marker + dirty-run liveness, resume lookup decision unknown-vs-resumable and
# clean-vs-unclean) and the pure SSEServer.resumableReconnectResponse builder
# (404 + resume header + stable reason token + clean/unclean phrasing, distinct
# from the opaque hard-404). Measured green 1859 passed / 0 failed locally
# (after the gate's known-teardown-flake retry). Floor raised by the +17
# net-additive count (1777 + 17 = 1794), below the measured 1859 so existing
# GUI/TCC + flake headroom is preserved while the 17 new tests cannot be
# silently dropped.
# fix(sparkle) (2026-06-05): staged-update crash-loop guard. The 2026-06-05
# incident was a raced Sparkle staged-update swap that left the SPM resource
# bundle `TheBridge_TheBridge.bundle` an empty husk → SwiftPM's generated
# `Bundle.module` accessor TRAPPED (`Swift.fatalError`) at the menu-bar-icon load
# site → EXC_BREAKPOINT/SIGTRAP crash-loop on every launch. Fix: (1) graceful
# degradation — MenuBarIconResolver resolves the icon via non-trapping
# `Bundle(path:)` lookups and falls back to a system SF Symbol, so the app ALWAYS
# boots (Bundle.module never touched on the launch path; FilesystemSkillIndex
# bundled-dir lookup likewise moved off Bundle.module); (2) best-effort pre-swap
# defense — StagedUpdateValidator (pure, non-trapping resource-bundle integrity
# predicate) wired into the SPUUpdaterDelegate `shouldProceedWithUpdate` veto
# (refuses install-on-top of an already-corrupt running app) + install-transition
# logging. Sparkle's API cannot validate the STAGED bundle pre-swap (the only
# abort-capable hook runs before extract; the post-extract hooks are void; the
# swap is done by the sandboxed Installer XPC) — documented in
# docs/release/sparkle-troubleshooting.md; we rely on (1) + install-copy
# hardening. +15 SparkleResilienceTests test() blocks (MenuBarIconResolver
# degrade-to-fallback / first-match / non-trapping probes / candidate paths;
# StagedUpdateValidator empty-husk-corrupt / absent / flat-valid /
# validateResources corrupt-absent-ok / validateRunningApp non-fatal). All pure
# (temp-dir synthetic bundles, injected probes — NEVER /Applications, NEVER a
# real Bundle.module), so they run in CI and local alike. Measured green
# 1842 -> 1857 locally (0 failed). Floor raised by the +15 net additive count
# over the prior floor (1777 + 15 = 1792), staying below the measured 1857 so the
# existing GUI/TCC + flake headroom is preserved while the 15 new tests cannot be
# silently dropped.
# v3.7.7 integration (2026-06-05): 14-branch gated integration into
# integration/v3.7.7. FLOOR reconciled to the NET integrated green per the
# order-inversion rule. Sum of the 11 code branches' net-additive test() counts
# over the prior 1777 floor: securitygate +16, securitygate-revoke-ui +10,
# axcrash +8, automation +17, buildtools +22, notionwrite +11, resultsize +17,
# permissions +13, credentials +27, session +17, sparkle +15 = +173 → 1950.
# (3 docs-only branches — playbook, design-decouple, operator-runbooks — add 0
# tests.) Measured integrated green 2018 passed / 0 failed locally across the
# full suite; FLOOR set to 1950 stays 68 below the measured 2018 so the existing
# GUI/TCC + flake headroom is preserved while none of the +173 new tests can be
# silently dropped. Never lowered below origin/main's 1777.
# fb-securitygate-credentials-followup (2026-06-06): coalescer drain-before-park
# race fix (+1 regression test); credentials NOTION-alias corrected to the real
# com.notionbridge/notion_api_token keychain row (2 tests updated, not added). 1950→1951.
# v3.7.8 (2026-06-11): two-chat integration of 7 branches (connector, memory Wave 2,
# credentials/securitygate, hotkey ⌃⌘B, emoji icons, keychain clean-service, skill
# body cache + offline fetch) + keychain UX (always-allow-self ACL, the-bridge
# rename). Net-new across the integration: 1951→1992 (2079 passing).
# v3.7.11 tool-surface resurface (2026-06-14): RECORDED FLOOR DECISION (order-inversion
# rule — a green baseline is only lowered with a conscious, recorded decision). Wave 1
# pruned ~60 MCP tools (Chrome family; all Stripe + payment_execute; the dev-loop/IDE-CI
# layer — lsp, bg_process, devserver, vitest/playwright/lighthouse, wrangler, swift_build/
# test/make_run, git_worktree*, git_merge, file_watch, tree_sitter_query, port_inspect; and
# residual deprecation shims — ax_query, gh_{pr,issue,actions}_* old names, list_routing_skills,
# manage_skill, jobs_{pause,resume}_all, file_apply_patch, file_str_replace,
# notion_code_block_append, notion_connections_list, bridge_focus_settings, screen_analyze)
# and their tests: 12 whole test files git-rm'd (BgProcess, Chrome, DevServer, Lighthouse,
# Lsp ×2, Payment, Playwright, StripeDeprecationShim, SwiftBuild, Vitest, Wrangler) + ~50
# per-tool test blocks excised from surviving modules. Local green 2079 → 1864 (−215, all
# pure/CI-running tests; the 87-test GUI/TCC local-only margin is untouched), so the
# CI-reliable green moves 1992 → 1992 − 215 = 1777. NOT a regression — legitimate tool
# removal. staticFeatureModuleToolCount 211 → 161, family count 29 → 26 (Version.swift).
# v4 "Liquid Glass, evolved" UI redesign (2026-06-14): the W1 foundation added +20
# BridgeTokens v4 adaptive-token tests (type scale / 6-rung elevation ladder / material
# tokens); the UI waves (component layer + 7 settings pages + 3 surfaces + the QA fix-wave)
# changed no test counts — views are behavior-tested, not unit-tested — and removed no tests
# (the only test edit was PKT879Dashboard popoverWidth 300→340 to track the design width).
# Integrated green independently measured 1884 (1864 → 1884), 0 failed. Floor raised
# 1777 → 1884 per the order-inversion rule to lock the new coverage.
# v3.8.0 security hardening (2026-06-15): +23 net-new regression tests — path-traversal
# gate (9: ../ escapes, symlinks, component-boundary matching for ~/.ssh|~/.aws|Keychains),
# safe-command metacharacter rejection (9: ; & | backtick $ ( ) < > { } newline +
# -exec/-execdir/-ok), Stripe card tokenization (3: Luhn validate + percent-encode).
# Integrated green 1884 → 1907, 0 failed. Floor raised to lock the new coverage.
# v3.8.0 global-shortcut hardening (2026-06-15): +14 net-new tests (CommandHotkeyHardeningTests)
# — Cocoa↔Carbon keyCode/modifier mapping round-trip, persistence load/save (incl. corrupt-bytes
# fallback to ⌃⌘B), register-failure classification (-9878 collision vs plumbing), status-truth
# derivation, and live-rebind no-churn. Integrated green 1907 → 1921, 0 failed. Floor raised.
# v3.8.0 shortcut status-truth (2026-06-15): +3 net-new tests — a published .registered derives
# .active (never the false .shortcutUnavailable warning); applyEnabledPreference(true) doesn't
# clobber a registered status; the enable ordering settles Active with no false-warning interim.
# (Root cause: header read a non-@Observable status box, so SwiftUI never refreshed the warning.)
# Integrated green 1921 → 1924, 0 failed. Floor raised.
# v3.8.0 shortcut controller-instance fix (2026-06-15): +2 tests — registering CommandsController
# === the UI-observed instance (a published .registered reads as .active through the UI ref); +a
# regression guard modeling the old `?? CommandsController()` phantom-instance fallback (separate
# instance → false .shortcutUnavailable). Root cause: SettingsWindowController re-resolved the
# controller via a fragile NSApp.delegate cast + `?? CommandsController()`, spinning up a phantom
# instance the UI observed while registration published into the real one. Fix: inject the one
# AppDelegate.commandsController directly. Integrated green 1924 → 1926, 0 failed. Floor raised.
# v3.8.0 Command Bridge liquid-glass redesign (2026-06-15): +2 tests — the ⌃⌘B palette keyboard
# selection model (CommandBridgeViewModel.moveSelection / commitSelected): ↓ opens recents + selects
# the first row; ↓/↑ traverse + clamp; Enter fires the SELECTED row (not just the first). Locks the
# operator's "can't arrow into recents" fix. Integrated green 1926 → 1928, 0 failed. Floor raised.
# v4 Command Bridge round-2 (2026-06-15): +2 tests — adaptive palette width clamp (favorite count →
# bar width, [half, full]) + remembered drag-origin clamp (keep the panel on-screen on reopen). Locks
# the operator's "adaptive width + draggable with session memory" asks. Green 1928 → 1930, 0 failed.
# PKT-1003 / Skills Truth-Up Wave A (2026-06-16): metadata-sync remediation —
# read+write repointed off the phantom "Bridge *" columns onto the real live
# SKILLS columns (Description, Activation Examples,
# Anti-Triggers); pull made gate-safe so an empty Notion value can no longer
# blank local metadata. +7 pure parse/build tests (SkillNotionMetadataSyncTests).
# Measured integrated green = 1937 passed, 0 failed. FLOOR raised 1930 -> 1937
# per the order-inversion rule.
# PKT-1003 / Skills Truth-Up Waves B+C+D (2026-06-16): cache truth-up (body
# store wired to the Cache-all/Cache-now/Refresh buttons; pip + counts +
# indicators read real SkillBodyCacheStore state), toggle truth-up (two
# non-functional rows removed, Auto-load → "List in routing index"), and
# detail-header up/down navigation (prev/next over the visible list). +5 pure
# body-cache snapshot tests + +5 pure navigation tests. Measured integrated
# green = 1947 passed, 0 failed. FLOOR raised 1937 -> 1947 per the
# order-inversion rule.
# PKT-381 / PKT-1004 (Scheduler Resilience, 2026-06-16): durable
# missed-occurrence backlog + reconciler + serial drain. New job_backlog
# table (UNIQUE(job_id, occurrence_ts) idempotency key) + additive migration;
# lastSuccessfulExecution watermark + hasExecution dedup-window lookups;
# JobOccurrenceEnumerator (DST-correct PAST-occurrence enumeration with a
# per-job safety ceiling) + CatchUpPolicy (replayAll default / maxLookback /
# coalesceToLatest); JobsManager.reconcileMissedOccurrences (replaces the dead
# bootstrap() no-op scan) + serial single-flight drainBacklog (oldest-first,
# CAS claim, requeueStuckRunning resume, skip_on_battery-aware) wired on launch
# (ServerManager router handoff) + wake (AppDelegate NSWorkspace.didWake). The
# new SchedulerResilienceTests suite adds 24 harness test() blocks: Wave-1
# durability (UNIQUE dedup, oldest-first ordering, CAS single-flight claim,
# requeueStuckRunning resume, CASCADE delete, watermark ignores failure/skipped,
# dedup-window detection), Wave-2 enumeration (3-day gap, exclusive-lower/
# inclusive-upper bounds, hourly gap, weekday-only, DST spring-forward 02:30
# collapse + fall-back 01:30 ambiguity, safety-ceiling clip, applyPolicy
# coalesce/maxLookback, reconciler missed-set + launchd-run dedup + idempotent
# second pass + never-run createdAt floor), Wave-3 drain (serial oldest-first,
# mid-drain-kill resume, skip_on_battery skip-record, no-double-fire re-drain).
# The two reconciler tests that assert concrete UTC instants pin timeZone: utc
# via the new injectable seam (production defaults to .current to match launchd's
# local-time firing). Measured integrated green = 1972 passed, 0 failed (on the
# America/Chicago host). FLOOR raised 1947 -> 1972 (+25) for Waves 1-3 per the
# order-inversion rule.
# PKT-1004 Wave 4 (first running-report job, 2026-06-16): RunningReportJob —
# an idempotently-seeded daily 06:00 job (stable id first-job-running-report)
# whose 2-step action chain builds a running-performance summary (shell_exec
# scaffold; the default metric set is latest run / trailing-7-day mileage /
# pace vs prior week) and delivers it via messages_send (iMessage-to-self,
# confirm:SEND). The Bridge has no server-side Strava/HealthKit data path
# (verified), so the report is an HONEST scaffold (no fabricated metrics; the
# data source is flagged operator-pending) and the recipient is an obvious
# REPLACE_WITH_YOUR_IMESSAGE_HANDLE placeholder. Seeded active so Run-now works
# and launchd schedules it; the seeder takes an injectable LaunchAgentInstaller
# (default = real launchd path; tests pass a no-op so seeding stays hermetic).
# +6 SchedulerResilienceTests Wave-4 blocks (record fields, chain shape +
# $prev_result wiring, unattended-validation pass, honest-scaffold/no-fabrication
# assertion, placeholder-recipient assertion, seed-once idempotency). Measured
# integrated green = 1978 passed, 0 failed. FLOOR raised 1972 -> 1978 (+6) per
# the order-inversion rule. On-device verification (sleep/wake + force-quit
# across a slot) and the Strava-source + self-handle wiring remain operator
# REVIEW items.
# PKT-1003 follow-through (Skills settings user scenarios, 2026-06-16):
# added SkillManagementUIContract as the pure Settings -> Skills alignment seam
# and +6 SkillManagementUIScenarioTests covering add, rename/page edit, MCP
# metadata reload, delete, file-source toggles, and filtered chevron navigation
# against the real SkillsManager/UserDefaults + SkillsModule per-path storage.
# Measured integrated green = 1984 passed, 0 failed. FLOOR raised 1978 -> 1984
# (+6) per the order-inversion rule.
# PKT-1003 follow-through (Skills settings full-coverage closure, 2026-06-16):
# restored an honest existing-skill "Show in Commands palette" toggle for both
# Notion/GDocs and file-source detail panes, then added +2 scenario tests for
# banner/footer/add-enable/cache truth and Google Docs source-filter separation.
# Measured integrated green = 1986 passed, 0 failed. FLOOR raised 1984 -> 1986
# (+2) per the order-inversion rule.
# PKT-1005 Wave 1 (on-device UI reachability core, 2026-06-17): added
# bridge_open_settings MCP tool (deterministic cold-open of the Settings window)
# + fixed the bridge_settings_navigate host-detection bug (window-presence based,
# not AppDelegate-cast based) + a bridge://settings/<section> URL handler.
# +6 BridgeAutomationModuleTests (open-tool registration/tier, cold-open deep-link
# + omitted/unknown section handling, navigate() host-detection, openSettings core)
# and the static feature-tool count bumped 161 -> 162 (the +1 tool). Measured
# integrated green = 1993 passed, 0 failed. FLOOR raised 1986 -> 1993 (+7) per the
# order-inversion rule (6 new automation tests + the count-pin guard re-greening).
# PKT-1005 Waves 2+3 (AX instrumentation + harness + ratified findings, 2026-06-17):
# added the BridgeAXID convention (bridge.settings.<section>.<control>) — the
# Settings UI's FIRST accessibilityIdentifiers — across the sidebar nav rows + the
# section H1 (all 7 sections) + the Skills controls (toggles, cache, indicators,
# nav chevrons, Trash, metadata grid) + a per-section root container. Added the
# headless UI-validation harness (SettingsUIValidationHarness: per-section expected-id
# manifest + validate/validateAll) and its on-device driver scripts/pkt1005-ui-validate.sh.
# Applied operator-ratified finding 1 (Skills "Page" metadata cell removed → 3-cell
# grid) + finding 2 (the "Show in Commands palette" detail toggle removed from BOTH
# the Notion- and file-source panes; the inCommandPalette backend flag/setter retained,
# so the existing SkillsMCPFlagRoundTrip tests stay valid unchanged). +11
# SettingsAXIdentifierTests (id convention locks, harness pass/fail/aggregate,
# finding 1+2 locks). Measured integrated green = 2004 passed, 0 failed. FLOOR raised
# 1993 -> 2004 (+11) per the order-inversion rule.
# PKT-1006 R2 (Command Bridge v4 · multi-entity search, 2026-06-17): the bar
# used to search ONLY CommandStore commands; W2 added a from-scratch typed
# multi-entity search MODEL (BridgeSearch.swift) over Commands+Skills+Jobs+Tools
# with fuzzy matching, score/recency ranking, group ordering, and per-group caps,
# plus a typed per-kind destination model + the skill-source resolver. +19
# BridgeSearchTests: fuzzy scoring shape (exact>prefix>substring>subsequence>nil,
# boundary/position/gap), rankedResults grouping+ordering+recency-tiebreak+cap+
# empty-query guard, kind-namespaced result ids + destination carry-through, and
# skillDestination routing (file/notion/gdocs/manual). Measured integrated green
# = 2023 passed, 0 failed. FLOOR raised 2004 -> 2023 (+19) per the order-inversion rule.
# PKT-1005 remainders (a)+(b) (On-device UI testability, 2026-06-17): closed the
# two open DoD items. (a) ax_tree / ax_inspect(find_element) now emit each
# element's stable AX `identifier` (kAXIdentifierAttribute) — previously only
# detailedInfo/element_info did, so a live read could resolve elements only by
# volatile role/title/label, never by a BridgeAXID. The two serializers were
# unified through a pure `serializedElementAttributes(...)` builder so the
# identifier-emission contract is unit-testable without a live AX tree / TCC.
# +3 AccessibilityModuleTests (identifier emitted-when-present, omitted-when-
# absent, additive-alongside-the-full-attribute-set). (b) Extended the BridgeAXID
# convention to the inner key controls of the other six settings sections
# (Commands/Jobs/Tools/Security/Connection/Advanced — primary buttons, toggles,
# list rows, section roots), reusing the existing helper; the harness manifest
# now carries those ids and a dedup removed the pre-existing Skills.root double-
# count. +3 SettingsAXIdentifierTests (6-section id-convention lock, every-
# section-has-inner-control-ids, manifest well-formed+unique-per-section).
# Measured integrated green = 2029 passed, 0 failed. FLOOR raised 2023 -> 2029
# (+6) per the order-inversion rule.
# PKT-810 R5 (origin split — loopback never gated, 2026-06-17): fixed the
# local↔cloud coexistence regression where a non-nil connectorAuth
# (BRIDGE_ENABLE_HTTP=1) bearer-gated EVERY /mcp request — including direct
# loopback. A local client (Claude Desktop) that sends no bearer 401'd into the
# RFC 9728 challenge whose resource_metadata pointed at the PUBLIC cloud origin
# (BRIDGE_PUBLIC_RESOURCE=https://mcp.kup.solutions/mcp), so the client followed
# it into a WorkOS Dynamic Client Registration that dead-ends — violating the
# documented contract (ConnectionsSection UI: "Local clients on this Mac connect
# with no token — the bearer applies only off-loopback"). Fix is an ORIGIN
# SPLIT: handleHTTPRequest now serves any DIRECT-LOOPBACK request (no Cloudflare
# tunnel header) as already-authorized (connectorAuthed:true — skips the legacy
# static-bearer phase too), so loopback is token-free end-to-end; only REMOTE
# (Cf-* header) requests reach the OAuth gate. The prior "loopback static
# bearer" fallback + ConnectorAuthContext.localBearer are REMOVED (they gated
# loopback behind a secret the OAuth client never sends — the bug's root). The
# RemoteOAuthOriginGatingTests file was rewritten to the new contract (still 8
# test() blocks: loopback served token-free / with garbage bearer / full tool
# surface / valid JWT; tunnel 401 on no-token / non-JWT bearer / served on valid
# JWT). ServerManager also now only advertises the PUBLIC cloud PRM pointer when
# WorkOS is live (else the local origin). The origin split is applied to the
# LEGACY bearer phase too (createSession.bearerExempt): a direct-loopback /mcp
# request skips the static-bearer / remote-tunnel-missing validators regardless
# of whether the connector OAuth path is enabled — so an operator install with
# `tunnelURL` + a static `mcpBearerToken` configured no longer 401s a local
# client with "missing Bearer token for MCP HTTP". +1 MCPHTTPValidationTests
# (loopback exempt from legacy bearer / tunnel still 401). The OriginGating file
# was rewritten to the new contract (still 8 test() blocks) and the connector
# E2E suites (Bearer/Hardening/S4) now stamp a Cf-Connecting-Ip tunnel header on
# their gate requests (the OAuth/scope/step-up gate is remote-only). Net +1.
# Measured integrated green = 2030 passed, 0 failed. FLOOR raised 2029 -> 2030.
# Data-Source Registry W1 (2026-06-17): additive foundation for the registry
# spec's first vertical slice (Skills = entity #1). New value model
# (RegistryModels: RegistryProperty/Entity/Config — bind-by-property-id,
# unbound seed per Decision 5, Skills seeded as entity #1), a durable config
# store (RegistryConfigStore — atomic registry.json, missing→seed / corrupt→
# throws, injectable path), and a generalized per-entity read-through ROW cache
# (CachedRow + RegistryRowCache — stale-while-revalidate + offline reads,
# generalized from SkillBodyCacheStore). No edits to load-bearing files (purely
# additive; 2 new BridgePaths subdirs). +23 net-new test() blocks
# (RegistryConfigTests 13: seed shape / unbound ids / binding / upsert / store
# round-trip+seedIfMissing+corrupt / forwards-tolerant decode; RegistryRowCache
# Tests 10: round-trip / id-normalization / per-entity isolation / TTL boundary
# / evict+evictAll / callCount / forwards-tolerant decode / atomic persist).
# Measured integrated green = 2053 passed, 0 failed. FLOOR raised 2030 -> 2053.
# Data-Source Registry W2 (2026-06-17): the live data path. RegistryPropertyCodec
# (typed Value ↔ Notion property JSON, decode/encode/isWritable for 12 writable
# + read-only types), RegistryRateLimiter (central 2 req/s gate — Decision 4),
# RegistrySchema + RegistryRowDecoder (Sendable row/schema models), Registry
# SchemaBinder (bind-by-name → property ids + unmatched/type-drift — Decision 5/9),
# RegistryNotionGateway protocol + LiveRegistryGateway (NotionClientRegistry +
# limiter), RegistryReader (read-through cache: miss→fetch, fresh-hit, stale-
# while-revalidate, offline serves cache; rename-safe projection by bound id;
# possess body-load) and RegistryWriter (create-then-update / update / soft-
# delete, keyed by property id). +49 net-new test() blocks (RegistryProperty
# CodecTests 34; RegistryDataPathTests 15: binder bind/unmatched/drift, reader
# miss+hit+forceRefresh+offline+list+project-rename-safe+possess, writer create-
# then-update+update+unknown/unbound errors+delete, rate-limiter spacing) — all
# against an in-memory fake gateway, no live Notion. Measured integrated green =
# 2102 passed, 0 failed. FLOOR raised 2053 -> 2102.
# Data-Source Registry W3 (2026-06-17): the MCP tool surface. RegistryModule
# registers ONE generic CRUD set + introspect + possess (8 tools, module
# `registry`) that serves every configured entity, validated per-entity against
# its property map at dispatch — small stable surface vs N×CRUD. Wired into
# BridgeModuleRegistry; +8 ToolAnnotationCatalog entries (deterministic CRUD
# annotations); staticFeatureModuleToolCount 162→170, staticFeatureModuleFamily
# Count 26→27. Injectable gatewayProvider + per-call config store make handlers
# hermetically testable. +9 net-new test() blocks (RegistryModuleTests:
# registration count/names, tier matrix, entities seed, introspect bind+persist,
# list projection, get, create-then-update, possess, unknown-entity reject) —
# plus the existing annotation-audit + static-count invariants validate the new
# surface. Measured integrated green = 2111 passed, 0 failed. FLOOR raised
# 2102 -> 2111.
# Data-Source Registry W4 (2026-06-17): the front-end. DataSourcesViewModel (the
# testable propose→confirm onboarding contract — Decision 5) backed by the SAME
# RegistryConfigStore + RegistryModule.gateway() seam the MCP tools use (BE↔FE
# alignment by construction), and DataSourcesSection (SwiftUI pane) wired into a
# new SettingsSection.datasources. Touched the section-exhaustive switches
# (icons, header presets, AX-validation harness) + the section-count/label
# assertions (7→8). +10 net-new test() blocks (DataSourcesViewModelTests: load,
# propose-without-persist, confirm-persists, missing-column drift, type drift,
# cancel, setTTL persist, offline error, + 2 BE↔FE alignment: UI-confirmed
# binding seen by registry_entities tool, tool binding seen by the pane).
# Measured integrated green = 2121 passed, 0 failed. FLOOR raised 2111 -> 2121.
# Data-Source Registry W5 (2026-06-17): + registry_add_entity — register any
# Notion data source as a new entity at runtime (Decision 5 add flow; the
# generic machinery already handles any entity, this is the missing "point at a
# data source" capability). staticFeatureModuleToolCount 170→171; +1 annotation;
# module registration-count test 8→9; +1 add_entity behavior test. The shipped
# seed stays Skills-only (the validating slice — v1 hot Projects/Contacts/Memory
# are added via this flow / the pane, NOT hardcoded per Decision 5). Measured
# integrated green = 2122 passed, 0 failed. FLOOR raised 2121 -> 2122.
# Data-Source Registry hardening (2026-06-17): adversarial edge-case sweep
# (RegistryEdgeCaseTests, +30 test() blocks) that found + fixed FOUR real
# architecture bugs and added two guards: (1) codec encode of title/rich_text
# > 2000 chars now SPLITS into ≤2000-char runs (Notion rejects longer runs) —
# `RegistryPropertyCodec.textRuns`; (2) `RegistryReader.list` now PAGINATES
# (follows next_cursor up to a row limit + page-count backstop) instead of
# silently truncating at one page — module arg `pageSize`→`limit` (max 500,
# legacy name accepted); (3) config mutations route through ONE shared
# `RegistryConfigStore` actor whose path resolves dynamically, so concurrent
# add/introspect can't lose updates (atomic `upsertEntity`); module + view-model
# now mutate via `.shared`; (4) `RegistrySchemaBinder.bind` is now AUTHORITATIVE
# — an unmatched property's stale id is CLEARED (re-introspect after a dropped/
# renamed column makes `isFullyBound` truthful + fails writes fast). Guards:
# `RegistryWriter` rejects an all-non-encodable write (no empty no-op / untitled
# page); `RegistryRowCache.safeComponent` caps over-long entity-key filenames
# with a stable hash. Coverage: codec (chunking, unicode/emoji, multi_select
# array-vs-comma, null-clear, relation/people, special chars), projection (empty/
# missing title), cache (concurrent increment, corrupt-file miss, path-traversal
# sanitize, complex Value round-trip, 400-char key), reader (multi-page, runaway
# cap, offline, concurrent get), writer (long-text chunk, clear-to-null, no-title
# single-create, empty-write reject), config (12-way concurrent upsert),
# module/VM (upsert-replace, possess no-body, introspect fail-safe), limiter
# (30-call burst). Measured integrated green = 2152 passed, 0 failed. FLOOR
# raised 2122 -> 2152.
# Live write-path smoke (2026-06-17): a real create→get→update→possess→delete
# run against Notion (scripts/registry_live_smoke.py, marker-guarded so it only
# ever deletes the row it creates) surfaced a 5th bug — a soft-deleted (trashed)
# page is still returned by getPage, so registry_get read a just-deleted row
# back as live. Fix: NotionRow carries `archived` (from in_trash/archived) and
# RegistryReader.get treats a trashed page as not-found + evicts its cache. +1
# test (archived → deleted error + cache evict). Measured = 2153.
# Then a 6th bug (the most insidious — a silent write no-op): Notion returns
# property ids percent-encoded for ids with special chars (e.g. id `AH`N` →
# `AH%60N`), and that encoded id does NOT round-trip as a WRITE key — Notion
# ignores it with no error, so registry_update wrote nothing yet "succeeded"
# (only `title`, whose id is literally "title", landed). Fix:
# `LiveRegistryGateway.encodeEnvelope` keys writes by property NAME (reliable),
# not id; the bound id still drives read-projection + rename detection. +1 test
# (envelope keys by name, percent-encoded id skipped). Measured = 2154.
# Root cause (7th bug, the actual one): NotionClient.createPage WRAPS its
# `properties` arg under {"parent":…,"properties":…} but updatePage sends its
# arg AS the PATCH body UNWRAPPED — the gateway passed the raw envelope to both,
# so updates went to Notion as a top-level {"Description":…} (not under
# `properties`) and were silently ignored (create worked, update no-op'd). Fix:
# LiveRegistryGateway.updateBody adds the {"properties":…} wrapper, createBody
# stays raw; +1 test locks the asymmetry. (The fake gateway bypasses
# NotionClient, so only the live write-path smoke caught this.) Measured = 2155.
# FLOOR 2154 -> 2155.
# /code-review remediation (2026-06-17, high-effort 3-pass review): fixed 6 real
# findings + docs. (a) cache pageId path-traversal — pageId now run through
# safeComponent like the entity key (was: only entity sanitized, `../x` escaped);
# (b) multi_select/relation/people encode now SKIPS a non-coercible .bool/.object
# value (returns nil) instead of silently writing an empty (clearing) list —
# data-loss guard; (c) textRuns chunks by UTF-16 units (Notion's actual run
# limit), grapheme-safe, not by Character count; (d) removed the unowned detached
# stale-while-revalidate Task (could write to the wrong BridgePaths home after a
# test cleared the override); (e) dead `row.id.isEmpty ? row.id : row.id` ternary
# fixed + empty-id treated as not-found; (f) DataSourcesViewModel.Proposal.clean
# now derives from the TYPED RegistryBindResult.isClean, not by string-matching
# drift messages. Plus: create-then-update caches the titled row before the
# follow-up PATCH (no invisible orphan on failure); stale "8 tools" comments →
# 9; dropped the undiscoverable registry_list `pageSize` alias; cloudflared
# trust-boundary documented at isRemoteTunnelRequest; CHANGELOG entry supersedes
# the stale loopbackStaticBearerFallback note. +3 tests (non-coercible skip /
# UTF-16 chunk / pageId traversal). Measured = 2158. FLOOR 2155 -> 2158.
#
# 2026-06-18 PKT-810 R5 hardening (legacy-route tunnel gate): the legacy SSE
# transport (GET /sse + POST /messages, PKT-336) is dispatched in the NIO handler
# BEFORE the /mcp connector-auth gate, and cloudflared forwards every path to
# :9700 (no path scoping) — so a Cloudflare-tunnel caller could open an
# UNAUTHENTICATED legacy session and drive the full tool surface, bypassing the
# entire OAuth gate. Fix: refuse tunnel-origin (Cf-*) legacy requests with 403;
# direct loopback (older local SSE clients) is unaffected. New
# isRemoteTunnelRequest(headers:) overload mirrors the HTTPRequest one for the
# NIO dispatch layer. +5 tests (HTTPHeaders discriminator + real-NIO-decode of
# tunnel/loopback × /sse,/messages). Measured = 2163. FLOOR 2158 -> 2163.
#
# 2026-06-18 Registry entity-management completion: + registry_remove_entity (the
# symmetric counterpart to registry_add_entity) + a "Remove" affordance in the
# Data Sources pane. Removes a LOCAL entity binding + evicts its row cache (no
# Notion write); .request tier; the seeded Skills entity is guarded behind an
# explicit confirm in BOTH the tool and the pane. staticFeatureModuleToolCount
# 171 -> 172. +6 tests (4 module: registration count 9->10, tier, add→remove
# round-trip, seed-guard refuse/confirm, unknown-entity; 2 VM: pane remove +
# isSeed). Measured = 2169. FLOOR 2163 -> 2169.
#
# 2026-06-18 Sell-The-Bridge Packet A (customer-safe registry seed + pane bind):
# productization fix — RegistryEntity.skillsSeed() now ships UNBOUND (dropped the
# operator's PRIVATE dataSourceId b6ff6ea5… per Decision 5 "no hardcoded data-source
# ids"); a fresh customer install gets a Skills TEMPLATE (property map intact) they
# bind to their own Notion via a new Data Sources pane affordance (paste a data-source
# id or Notion URL → DataSourcesViewModel.setDataSource → existing Introspect). Adds
# RegistryEntity.isBoundToSource + DataSourcesViewModel.parseDataSourceId (handles
# dashed UUID / bare 32-hex / Notion-URL slug; nonisolated, unit-tested). Only fresh
# installs affected (seedIfMissing never overwrites an existing registry.json). +6
# tests (seed-unbound, setDataSource raw-id/URL/garbage, parseDataSourceId unit,
# registry_entities-unbound). Measured = 2175. FLOOR 2169 -> 2175.
# Packet B (PRJCT-2754 · Ship The Bridge v4, Wave 1, 2026-06-18): license
# public-key build injection (LicensePublicKeyInjected.swift + make
# inject-license-key + release.yml secret) + scripts/license-cli
# (keygen/mint/verify, reusing LicenseToken.encode) + a dev-keypair
# mint→verify→entitled round-trip. +6 LicenseCLITests (fail-closed seam,
# injected-key decode, mint/verify round-trip, wrong-key forgery reject,
# entitled via computeStatus, expired→licenseExpired). Measured integrated
# green 2175 → 2181; floor raised per the order-inversion rule.
# Payment P1 (PRJCT-2754 · Wave 1, 2026-06-18): StripeClient.createCheckoutSession
# (hosted Checkout) + BridgeCheckout brand config + LicenseCard "Get a license"
# entry. +4 StripeClientTests (request shape mode/price/urls/brand-metadata/
# client_reference_id + parse; empty-priceID fail-fast no-network; Stripe error
# response; brand metadata + priceID provider). 2181 → 2185.
# Packet E (PRJCT-2754 · Wave 1, 2026-06-22): durable Remote-Access OAuth identity
# — build-baked RemoteAccessIdentity + env→config.json→baked→fail-closed resolution
# in ProtectedResourceMetadataProvider (ends the launchctl-setenv placeholder-PRM
# revert). +9 RemoteAccessIdentityTests (issuer + resource precedence ×4 layers,
# isMisconfigured, committed-fail-closed default). 2185 → 2194.
# Packet E (PRJCT-2754 · Wave 2, 2026-06-23): config-back the remaining four
# remote-access readers with the SAME env→config.json→baked→fail-closed layering
# (injectable config/baked seams, pure): WorkOSConfig.resolved (per-field, baked
# RemoteAccessIdentity.workos*), TransportRouter (BRIDGE_ENABLE_HTTP env→config
# `enableHTTP`→off), ConnectorBearerValidator.fromEnvironment (BRIDGE_OAUTH_JWKS
# env→config `oauthJWKS`→fail-closed), EnableCloudAccessFlow.resolvedProvisionBaseURL
# (arg→BRIDGE_CLOUD_BASE_URL→config `cloudBaseURL`→placeholder). Gate/dispatch +
# PKT-810 R5 loopback split UNCHANGED — only the resolution feeding the readers.
# +17 RemoteAccessConfigWave2Tests (WorkOS ×5, TransportRouter ×4, JWKS ×4,
# cloud-base-url ×4). Measured integrated green 2194 → 2211.
# Tool-Dev bg_* (PRJCT-2754 · 2026-06-23): bg_run/bg_poll/bg_kill detached
# background execution (`bgprocess` family) — ported onto the post-rename
# TheBridge/ tree (the workflow worker built it on the stale pre-rename base).
# File-backed stateless job state under bg-process/<ts-uuid>.{log,done,pid};
# bg_run returns immediately, bg_poll reports running/exited/terminated, bg_kill
# SIGTERM/SIGKILL. staticFeatureModuleToolCount 172→175, family 27→28. +15
# BgProcessModuleTests (registration/tier/annotation + input/path-traversal
# guards + 3 LIVE run→poll→exit / non-zero / bg_kill round-trips). Measured
# integrated green 2211 → 2226.
# Security-audit remediation batch 1 (PRJCT-2754 · 2026-06-23): from the v4
# multi-agent security/test audit (verdict: minor-gaps, zero exploitable
# off-loopback findings; R5 contract verified correct). (#10) skill_delete
# .notify → .request + neverAutoApprove (irreversible hard-delete now requires
# confirmation, matching the job_delete fix) + lockstep ToolAnnotations
# requiresConfirmation:true. (#7) bg_run no longer double-escapes single quotes
# in the user command (embedded raw; the single launcher escape suffices) —
# fixes `echo "it's"` corruption; +1 LIVE regression test. 2226 → 2227.
# Security-audit remediation batch 2 — non-auth (PRJCT-2754 · 2026-06-23): six
# reliability/DoS/coverage findings from the same v4 audit (auth/R5 surface left
# untouched). (#3) FIRST coverage for the BgProcessRuntime actor via the
# init(baseDir:cleanupTTL:killGracePeriodSec:) hermetic seam: reconcileOrphans
# dead→.unknown / live-job watcher-reattach across a fresh runtime / terminal-TTL
# sweep, SIGTERM→SIGKILL cascade on a TERM-ignoring child, finalizeExit
# signaled-without-prior-kill ⇒ .failed (not .killed), concurrency-safe start
# (+6). (#4) file_read no longer slurps the whole file before the cap — stat +
# reject non-regular files (a FIFO/char-device can't be streamed) then
# FileHandle.read(ofLength: min(maxBytes, 50 MB)); +3 (cap, full-small-file,
# FIFO refusal). (#5) bg_poll reads only the trailing 256 KB window (seek-from-
# EOF + drop leading partial line) instead of the entire log every poll; +1 LIVE
# (>window log → last lines only, logTruncated true). (#6) bg_run/bg_kill
# coverage: ~20 concurrent launches → distinct ids/paths, force:true ⇒ SIGKILL,
# pid-dead-no-sentinel ⇒ terminated, loginShell branch; +4. (#8) config.json
# written 0o600 (chmod the final path post-atomic-rename) so secrets aren't
# world-readable; +1. (#9) bg_kill TOCTOU blast-radius: bg_run launches under
# `set -m` so the recorded pid is its process-group leader (pgid==pid) and
# bg_kill signals the GROUP (kill(-pid,…)); killpg succeeds only while that pid
# still leads a group, so a recycled pid yields ESRCH→already_terminated instead
# of hitting an unrelated process (covered by the #6 group-kill case). Measured
# integrated green 2227 → 2242.
# Security-audit remediation — auth surface REVIEW-FIRST #1/#2 (PRJCT-2754 ·
# 2026-06-23): Packet E Wave 3 fail-loud PRM gate + legacy /sse,/messages 403
# E2E. +8 tests in RemoteOAuthOriginGatingTests (5 legacy-route E2E driving the
# UNMODIFIED SSEHTTPHandler.processRequest through an EmbeddedChannel: tunnel
# GET /sse & POST /messages → OUTBOUND 403 loopback-only, their loopback twins
# → served (200 SSE head / 202 accept), + a /health-stays-tunnel-reachable
# non-regression; 3 PRM serving-path E2E: misconfigured ⇒ 503 with NO
# placeholder authorization_servers, a configured identity ⇒ normal 200 PRM,
# and the default decision tracks the live prmServingDecision so the gate is
# proven WIRED, not only seam-reachable). The origin-decision logic
# (isRemoteTunnelRequest, the legacy-route loopback-only 403, the loopback /mcp
# split) is byte-unchanged. Measured integrated green 2242 → 2250.
# PKT-1010 (2026-06-24): Packet C activation + onboarding UX polish. +18 OnboardingTokenValidator
# tests (trim + validate: ntn_/secret_ prefix, short token, whitespace-only, trimmed clean, etc.).
# Measured integrated green 2250 → 2268.
# PKT-977 Wave 2 (2026-06-24): Q1 MemoryAutoInjectClientStore tests (+3),
# asyncComposition tests (+2), Q2 TTL tests (+3), consolidation sweep TTL test (+1),
# handler TTL test (+1), Q4 SettingsSection Memory case tests (+4 across
# WSHMenuBarTests/BridgeAutomationModuleTests/SettingsSectionsLGTests),
# Q2 expiredEntries sweep path fix. Batch-merged onto PKT-1010: 2268 + 12 = 2280.
# PKT-1007 (2026-06-24): Semantic Recall dense-vector arm (NLContextualEmbedding)
# + Reciprocal-Rank-Fusion (RRF). +31 new tests: StubMemoryEmbedder (5),
# MemoryEmbeddingIndex (5), ReciprocaLRankFusion/RRF (5), MemoryStore recall E2E
# with stub embedder (7), NLContextualEmbedder unit + live asset tests (9).
# MemoryModuleTests FTS-recall assertion relaxed (count=1→≥1) to allow hybrid
# recall semantics; "deploy pipeline" FTS match still ranks first via RRF+bias.
# Batch-merged onto PKT-977: 2280 + 31 = 2311.
# PKT-1014 T2 (2026-06-24): comprehensive coverage sweep — payment, licensing, UI
# behavior, edge/error envelopes. Added PaymentLicenseT2Tests.swift (62 tests):
# Stripe A-section (13): zero-amount/missing-idempotency-key/empty+nil API-key
# guard, retrievePaymentIntent parse, parseStripeError direct coverage for all
# status codes (401/403/500/insufficient_funds), formURLEncoded determinism,
# createCheckoutSession missing-url + no-idempotency-key branches,
# amountExceedsCeiling description. License B-section (14): trial 1-second-before-
# boundary, grandfathered-wins-over-token, acknowledgeTrialExpired idempotency,
# verify rejects empty/multi-dot tokens, payload validate rejects empty-id/empty-sub/
# iat=0, 'grandfather' kind accepted, base64url 0+3-byte+char-substitution round-
# trips, LicenseState Codable, bundled() fail-closed. Revocation C-section (7):
# min/max/over-max id boundaries, whitespace-id rejection, Codable round-trip,
# unknown-status graceful nil, checkedAt preservation. UIState D-section (7):
# trial(0) passthrough, Equatable same/different, nil-exp licensed+licenseExpired,
# canPasteActivate all status kinds, lastError for licenseExpired. Status E-section
# (10): isLicensedOrGrandfathered for all 5 cases, pillLabel for licensed/expired/
# trial-0, isActive exhaustive. CardHost F-section (3): initial 30-day state, empty
# pasteField, activate no-op on empty field. Checkout G-section (8): product
# constant, successURL placeholder, cancelURL HTTPS, default/custom channel,
# whitespace/newline-trimmed priceID+paymentLinkURL. Batch-merged onto PKT-1007: 2311 + 62 = 2373.
# Memory-Hub (2026-06-25): Voice Memos curator Wave 1 +6, Wave 1.5+Ollama +4, idempotency/dismiss
# fixes +2, Wave 2 Parakeet/Qwen +9, PKT-MEM-102 MemorySettingsTests +6+8, PKT-MEM-103 TTL +5+3,
# PKT-MEM-105/106 trust+live-regression +10+1 = ~53 additive tests rebased onto batch-merge base.
# Conservative floor held at 2373; raise to measured count after CI confirms the integrated green.
# PKT-MEM-106 0a trust+identity (2026-06-25): +25 VoiceMemoHubTrustTests — canonical intent_v1_ 20-hex
# generator, lane-priority-first election, processed-gate predicate routed through ALL markProcessed
# callsites (resolve-then-gate), distinct same-kind suppressed lanes (enqueue rekeyed to intentId),
# legacy derive-on-read + rewrite-on-touch, rowId-param threading + ambiguity→manual, append-only
# protected fields (incl. the resolver explicit-rowId path). Measured integrated green 2426 → 2451.
# PKT-MEM-106 0b cockpit+activity (2026-06-25): +23 MemoryHubCockpitTests — activity-log receipt envelope
# (full SHA-256 / first-12 display, 500/30d retention, no transcripts, corrupt-line skip+preserve+repair),
# per-entity registry picker cache (24h stale boundary, last-good fallback), three-zone cockpit core
# (one-primary election display + override re-election, per-intent commit args, picker rowId threading,
# Process↔Inbox mirror over the same pending entries), well-formed cockpit AX IDs. Measured green 2451 → 2474.
# PKT-MEM-106 0b review fix (+2): cockpit duplicate-lane dedup → exactly one primary (two-primaries breach
# caught by adversarial review); commitArguments threads dueISO8601; + short-transcript privacy redaction.
# PKT-MEM-106 0c preview+guardrails+tabs (2026-06-25): +31 MemoryHubGuardrailTests — lane thresholds
# (0.80/0.90/0.86/0.86/0.90, WIRED into VoiceMemoProcessor auto-execute), duplicate-key + force-reason enum
# {new_context,correction,operator_confirmed,live_test}, non-protected per-field diff (validate-all-or-nothing,
# protected append-only re-derived, summary+raw JSON non-trapping), versioned plan snapshots
# (heuristic/latest-enhanced/committed retention, no-silent-removal demote, launch sweep), OpenAI-compatible
# provider (providers.json non-secret + Keychain key + Processing UI), progressive-preview policy (8s/20s
# timeouts, cloud-failure keeps-latest-no-review), notification gate, activity corrupt-line repair. Measured 2474 → 2508.
# --- Merged from main (2026-06-25): Packet Runner / tool-surface provenance ---
# Packet Runner v1 registry_hydrate (2026-06-24, batch-merged onto PKT-1014 T2): +10 RegistryHydrationTests
# + RegistryModuleTests 10->11 — packet-registry-v1 one-hop envelope (FR-1/§8.3). Main green 2373 -> 2383.
# Tool-surface test coverage (2026-06-25): +30 behavioral tests (9 Jobs mgmt tools + memory export/import
# round-trip + 2 pinned-intent guards). Main green 2383 -> 2415.
# MERGE main → Memory Hub branch (2026-06-25): integrated green re-measured = 2550 (2508 branch + 42 main
# net-new: registry_hydrate +10/+1 + tool-surface +30, + Version staticFeatureModuleToolCount 186→187 for
# registry_hydrate). make test 2550 passed / 0 failed. Raise only by measured net-new; never lower.
# Bridge initialization contract (2026-06-26): +3 net-new tests for manifest+metadata COMPLETE,
# metadata-drift DEGRADED, and valid zero-supplemental COMPLETE. Replaced the obsolete routing-only
# fallback assertion in place (count-neutral). Full harness: 2553 passed / 0 failed.
# PKT-MEM-114 P1 (2026-06-26): +21 net-new green — MemoryHubMemoTitle (title model + edited-pinned cache +
# Tier-1 intent-led heuristic + locale-aware date floor; suite runMemoryHubMemoTitleTests). 2571 passed / 0 failed.
# PKT-MEM-114 P2 (2026-06-26): +3 net-new green — surface intent-led titles in the cockpit memo list + Inbox
# (generate-on-select + edited-rename survival + Inbox cache-wins/fallback; same runMemoryHubMemoTitleTests suite).
# 2574 passed / 0 failed.
# PKT-MEM-114 P3a (2026-06-26): +8 net-new green — Tier-2 Ollama titles (enabled-flag gating + .local cache,
# edited-pin preserved, fallback/empty rejected) + snapshot-derived heuristic + local-first idle sweep
# (caches from plan snapshots, leaves edited/existing, per-sweep cap; stubbed LLM, runMemoryHubMemoTitleP3aTests).
# 2582 passed / 0 failed.
# PKT-MEM-114 P3b (2026-06-26): +11 net-new green — manual Tier-3 cloud title tier (MemoryHubCloudTitler:
# injected CloudChatTransport stub → success caches .cloud + sanitizes/caps, non-2xx/timeout/empty/missing-key
# throw and keep the prior title with NO review queued, edited-pin preserved; bearer-auth + /chat/completions
# + 20s timeout asserted) + operator rename override (→ pinned .edited, auto tiers never overwrite, empty no-op)
# + canRunCloud button-enabled gating. New AX ids process.titleRename/titleCloud added to the .memory manifest.
# runMemoryHubMemoTitleP3bTests. 2593 passed / 0 failed.
# PKT-MEM-114 review remediation (2026-06-26): +6 net-new green — Tier-1 heuristic char ceiling (clean() now
# clamps to 120 chars so a single no-whitespace token — CJK/Thai/URL/base64/id — can no longer persist verbatim
# into memo-titles.json incl. unattended via launchSweep; privacy parity with the activity-log excerpt cap) +
# launchSweep single-write (mutate the loaded cache in-memory, save(prune) ONCE instead of put()-per-item,
# edited-pin preserved). runMemoryHubMemoTitleReviewRemediationTests. 2599 passed / 0 failed.
# v3.8.3 release (2026-06-26): rebased onto origin/main (standing-orders init contract, afbad0d); combined
# harness re-measured = 2602 (2599 PKT-MEM-114 branch + 3 init-contract net-new). make test 2602 / 0 failed.
# Voice Curator FRONTIER-FIRST W1 (2026-06-26): +19 net-new green — parse provider-chain abstraction +
# plan provenance/degraded model (runVoiceMemoParseChainTests): providers(for:) chain ORDER per curator mode,
# .auto frontier-first Cloud→Local→Heuristic winner selection by availability, degraded set IFF an earlier
# AVAILABLE rung returned nil, heuristic floor always-available/never-nil, provenance stamp, .agent/.heuristics
# → floor, W1 Cloud stub unavailable+nil, parseWithOptionalOllama shim routes through the chain, ParseProvenance
# Codable + VoiceMemoPlan default-field lock. Stub providers injected via VoiceMemoParseRouter.providerOverride
# (no real network/Ollama/agent). make test 2621 / 0 failed.
# Voice Curator FRONTIER-FIRST W2 (2026-06-26): +18 net-new green — REAL cloud frontier parse rung
# (MemoryHubCloudParser + CloudParseProvider; runVoiceMemoCloudParseTests): canned strict-JSON completion →
# mapped VoiceMemoPlan (summary + typed intents + fields, .cloud provenance via router stamp); the WHOLE
# transcript is sent UNCAPPED (a >4000-char transcript's tail sentinel appears in the request body — frontier
# large context, NO 4000 truncation); POST /chat/completions + Bearer auth + 20s timeout, key header-only
# (never in body); a fenced ```json block is tolerated; non-2xx / transport-timeout / garbage-JSON / empty-
# intents / all-unknown-lane / missing-key / disabled-provider → THROW ⇒ CloudParseProvider.parse returns nil
# ⇒ router degrades to Local→Heuristic with degraded=true; isAvailable() false with no provider/key/disabled,
# true with a configured provider + saved Keychain key; router↔parser integration (real parser behind an
# injected CloudChatTransport via providerOverride) proves degrade + cloud-win provenance hermetically. NOTE:
# `make build` runs inject-remote-access which bakes the operator's REAL WorkOS identity into
# RemoteAccessIdentity.swift — that breaks 4 fail-closed-placeholder assertions (RemoteAccessIdentityTests/
# RemoteAccessConfigWave2Tests/EnableCloudAccessFlowTests×2); they PASS against the committed placeholder source
# (this count measured with the placeholder source restored). make test 2639 / 0 failed.
# 2026-06-26 (Voice Curator FRONTIER-FIRST W3 — cockpit UX remediation + provenance surfacing): +14 pure-helper
# tests (runMemoryHubCockpitLabelsTests) — intentKind/intentStatus/transcriptSource human labels (incl.
# "suppressed"→"Held for review"), provenanceBadge incl. the degraded override, the no-transcript select-status
# selection + unresolved-transcript message, and the commit-value preview. UI-free (no net/Ollama/audio). Same
# WorkOS-injection caveat above applies: measured with the committed fail-closed RemoteAccessIdentity.swift
# restored. make test 2653 / 0 failed. 2639→2653.
# 2026-06-26 (Voice Curator FRONTIER-FIRST W4 — Phase-1 review remediation): +14 tests across
# runVoiceCuratorPhase1RemediationTests (durable .understand cloud-send activity receipt w/ hash+excerpt
# only, never the full transcript; receiptValue surfaces provenance/degraded; notifier cloud-send lane; honest
# commitWriteLabel for first-of-N + append-merge registry fields) plus the W3 label_provenanceBadge_localAnd
# HeuristicAreDistinct net-new (local "on-device model" vs heuristic "rules"). All pure/hermetic (no net/Ollama/
# audio). SAME WorkOS-injection caveat: the 4 placeholder failures are the build-injected RemoteAccessIdentity.swift
# (operator IdP baked locally), NOT this slice — measured 2667/0 with the committed fail-closed source restored
# (gate EXIT=0). 2653→2667.
# 2026-06-26 (PKT-MEM-115 Wave 3 — memory surfacing + governance): +15 tests across
# runMemoryRoutingAppendixTests (scope map, entity denylist, row formatter provenance,
# appendix attach/omit, post-cache freshness, error-skip) plus StandingOrdersDelivery
# inject-override composition + seedWave3DefaultsIfNeeded idempotency, MemoryModule
# recall source + pin toggle. Hermetic temp DB / shared hermetic config path.
# 2667→2682.
# 2026-06-27 (PKT-MEM-115 Memory Hub Foundation — D12/D8/D9/D13/D35/D41/D6/D17/D23/D36/D42):
# +62 tests across 4 new suites: runMemoryHubActivityTests (D12 22-case ACTIVITY taxonomy +
# evidenceId uniqueness + D24 retention constants + D20 KeepReviewStatus 6 cases + D19
# KeepReviewMetadata defaults/clamping + D15 KeepSchemaContract names + D43
# KeepRequiredSchemaField manifest), runInboxDispositionTests (D8/D9 DismissScope/Result,
# D13 TrashResult, dismiss marks processed, hasSiblingLanes, .allLanes), runMemoryUpdateTests
# (D35/D41 protectedFields set, memory_update registered, update round-trip, protected-field
# rejection), runProcessingProviderTests (D6/D17/D23/D36/D42 ProviderFamily/Capability/
# CredentialReference/FallbackChain/SyntaxValidator/TestResult). Plus 2 mechanical fixes:
# MemoryHubActivityEventType custom Codable (unknown forward-compat), MemoryModuleTests
# tool-count 5→6 (memory_update D35). All hermetic; no net/Ollama/audio. 2682→2744.
# 2026-06-28 (skill-system routing governance):
# +9 tests covering routeReceipt schema exposure, missing/valid/stale receipt
# validation, enforcement across all mutation tools, read-only metadata pull,
# and routing-consistency lint detection/clean-state behavior. The clean base
# measured 2746 passing tests; this branch measures 2755 passed / 0 failed.
# 2744 recorded floor → 2755 measured floor.
# 2026-06-29 (standing orders v7.0.2 transplant): +3 StandingOrdersTests (bundled seedIfEmpty,
# parseDoctrineVersion, explicit doctrineVersion write bump). Current main floor 2755→2758.
# 2026-06-29 (registry_create body initialization):
# +7 tests covering body-bearing one-call packet creation, relation patching,
# verbatim Markdown body write, property-only compatibility, non-body validation,
# explicit partial failure on body-write error, idempotency retry, oversized body
# rejection, and schema discovery. make test-floor measured 2762 passed / 0 failed.
# 2755 recorded floor → 2762 measured floor (rebased atop standing-orders 2758).
# 2026-06-29 (v3.9.2 release train): measured 2765 passed / 0 failed after #68+#66+#67 merge.
# 2762 recorded floor → 2765 measured floor.
# 2026-06-29 (PKT-1061 commands_* MCP): +8 CommandsModuleTests (registration/tier/CRUD dispatch). 2765→2773.
# 2026-06-29 (Wave 3 FB bundle): +bridge_focus_settings, skill body-cache eviction on
# Notion writes, ListTools registration gate (FB-4), CalendarISOParsing tests.
# Combined measured 2783 passed / 0 failed (2773 + 10 Wave 3 FB). 2765 → 2783.
# 2026-06-30 (PKT-MEM-120 Memory Hub routing + quality + UX): +13 VoiceMemoMCPRoutingTests
# (MCPClientPresence grace + test override, Auto+MCP Execute defer, awaiting-agent review
# tags, agent_deferred activity receipt, notifier lane, MemoryHubUIState notification gate,
# cockpit label helpers) +1 MemorySettingsTests notionRefresh AX id. 2783 → 2796.
# 2026-06-30 (PKT-MEM-121 Process preview session cache): +10 MemoryProcessPreviewSessionTests
# (LRU put/get, fingerprint mismatch, remove, invalidate, lastSelectedMemoId, picker round-trip,
# getIfPresent, triage invalidation stub, refreshPreview AX id). 2796 → 2806.
# 2026-06-30 (Memory Hub Sprint Finish): +VoiceMemoSuiteAuditTests (10 voice_memo_* invariants),
# +ToolSurfaceCoverageAuditTests (static tool dispatch/suite-audit meta gate),
# +TriageSessionTests (PKT-MEM-122 triage open/await/end, compound Memory navigation anchors),
# +MemorySettingsTests compound anchor + resolved JSON, pkt1005 memory/datasources sections.
# 2026-06-30 (PKT-MEM-123 V1 Process layout + batch confirm): +30 tests —
# MemoryProcessBatchConfirmTests (+18), MemoryProcessLayoutAXTests (+8),
# MemoryProcessPreviewSessionTests (+2), MemoryHubGuardrailTests (+1 dup batch),
# TriageSessionTests (+1 batch detail); MemoryHubCockpitTests AX migrated.
# 2824 → 2854 measured green.
# 2026-06-30 (Memory Hub W1–W3 UX + HITL): +6 tests — MemoryProcessInspectUnderstandTests;
# MemoryProcessLayoutAXTests (+1 opt-in AX); floor 2857 → 2863 measured green.
# 2026-07-01 (PKT-1065A · deterministic init-core + handshake receipt): +15 tests —
# BridgeInitializeTests (manifest/metadata parse + hash verify, INCOMPLETE/DEGRADED/
# COMPLETE classification, no-op supplemental found-but-ignored tri-state, init-state
# vs capability-state separation, receipt Codable + MCP Value serialize, durable
# per-handshake persistence + distinct evidence event, tool registration/tier/annotation).
# Measured integrated green off origin/main = 2877 (0 failed). floor 2863 → 2877.
# (Parallel unmerged branches reconcile at merge per the order-inversion rule.)
# 2026-07-02 (PKT-1065C · intent-sensitive capability preflight + Reminders adapter):
# +17 tests (CapabilityPreflightTests) stacked on PKT-1065A. Measured integrated green
# = 2894 (0 failed). floor 2877 → 2894. Stacked on pkt-1065a-init-core; parallel unmerged
# branches (1041/1064/1065b) reconcile at merge.
# 2026-07-02 (PKT-1065B · session_info/bridge_status semantics + connection alias): +7
# tests — 2 SessionModuleTests (explicit per-field `scopes`; 0-clients default when no
# diagnostics provider) + 5 ConnectionsModuleTests (notion:primary symbolic alias —
# isPrimaryAlias, resolve-to-primary, exact-id-wins, unknown-id nil, no-primary nil).
# Branched off origin/main (9306800) where its own measured green was 2870 (2863 +7);
# independent of 1065A/C (ConnectionRegistry/ConnectionsModule/SessionModule, no file
# overlap). Reconciled at merge onto integrated floor 2894 → 2901 (2894 +7).
# 2026-07-02 (PKT-1041 registry_find): +9 tests — RegistryModuleTests (+7: exact/none/
# multi/bound-id/AND/unknown-entity/empty-where), RegistryDataPathTests (+2: reader
# offline-cache filter + scalar-number/relation-array match). Branched off pre-1065A/B/C
# main where its own measured green was 2872 (2863 +9); reconciled at merge onto
# integrated floor 2901 → 2910 (2901 +9).
# 2026-07-02 (PKT-1064 originating-Player relation attach/verify): +7 tests —
# VoiceMemoPlayerAttachTests (memo→Memory attaches default player at create, verify
# read-back present, absent-PLAYERS graceful BLOCKED, unbound-PLAYERS BLOCKED, dropped
# relation fails verify, explicit override wins, playersRelationKey rename-safe match).
# Branched off pre-1065A/B/C/1041 main where its own measured green was 2870 (2863 +7);
# reconciled at merge onto integrated floor 2910 → 2917 (2910 +7).
# 2026-07-02 (PKT-MEM-131 registry_find row-resolution swap): VoiceMemoProcessor.
# resolveRegistryRowId now dispatches registry_find (PKT-1041) instead of hand-rolled
# registry_list + client-side containment/regex matching, which is deleted outright (no
# dead code left behind). Ambiguity semantics preserved from the caller's perspective —
# single match → row id, ≥2 distinct matches → registryAmbiguous, no match →
# registryMatchFailed — now resolved server-side by registry_find's exact-match
# (case-insensitive) predicate on the entity's canonical title-property key (falls back to
# the "title" convention when the entity isn't yet configured). VoiceMemoHubTrustTests'
# stub router gained a registry_find stub mirroring registry_find's REAL matching
# semantics (RegistryReader.find/valueMatches — exact equality, not containment); the
# pre-existing ambiguous-hint fixture was updated to two rows sharing one exact title (the
# realistic ambiguous case under exact-match) rather than two differently-worded titles
# that only collided under the old containment logic. +2 tests —
# resolveRegistryRowId_exactMatch_singleRowId, resolveRegistryRowId_noMatch_
# throwsRegistryMatchFailed (the three cases the old implementation covered — exact/none/
# ambiguous — now exercised against registry_find end-to-end). Branched off origin/main
# (630a2ed, post-1041/1064/1065A-C) where measured green was 2917 (0 failed); this change
# measures 2919 passed / 0 failed. floor 2917 → 2919.
# 2026-07-02 (PKT-MEM-132 transcript-overlap write guard, D49): +20 tests —
# VoiceMemoTranscriptOverlapGuardTests (pure-logic: locked constants, below-floor
# short-reuse always passes, empty/tiny text passes, full verbatim paste rejected,
# 220-char embedded run rejected, 199-char run one-under-threshold passes, long-
# genuinely-original summary passes, re-cased/re-wrapped paste still rejected
# [normalization], firstRejectedField scans every field key not just "summary",
# clean field map / empty map → nil; wiring: executeMemoryKeep verbatim fields
# override throws transcriptOverlapRejected before any registry_create dispatch,
# short-reuse and long-original both write normally, the heuristic non-override
# path is unaffected; executeRegistryUpdate verbatim override throws before any
# registry_update dispatch on BOTH the explicit-rowId and hint-resolved paths,
# short-reuse writes normally, an embedded [not full-paste] verbatim run in a
# proposed field is still caught post-merge). New VoiceMemoTranscriptOverlapGuard
# pure checker (named minimumLengthFloor=80 / contiguousRunThreshold=200 constants)
# wired into both Notion-bound write paths named in the packet's Scope IN; new
# VoiceMemoError.transcriptOverlapRejected case routes to the same graceful
# BLOCKED → REVIEW pattern PKT-1064's playerRelationUnbound established (throw,
# caught by the existing processOne/commit() error handling — no crash, no
# silent write). executeRegistryUpdate gained a required `transcript` parameter
# (threaded through its 3 production call sites + 1 test call site); the
# VoiceMemoReviewResolver.swift registryUpdate case's explicit-rowId branch,
# which duplicated executeRegistryUpdate's own append-merge + registry_update
# dispatch inline (and so would have silently bypassed the new guard), was
# consolidated to call the single guarded executeRegistryUpdate(explicitRowId:)
# instead — same detail-string wording, zero behavior change other than gaining
# the guard. Own measured green off origin/main (630a2ed, pre-131) = 2937
# (2917 +20), branched independently of PKT-MEM-131. Reconciled at merge onto
# integrated floor 2919 (post-131) → 2939 (2919 +20).
# 2026-07-02 (PKT-MEM-134 UI↔agent live processing sync): +9 tests — new
# MemoryHubLiveProcessingTests (+7: memoConsidering/memoCommitted eventType taxonomy
# present + distinct, .memoryHubLiveProcessingDidChange is a dedicated Notification.Name
# separate from .voiceMemoReviewDidChange, voice_memo_get(understand:true) posts +
# durably logs memoConsidering, voice_memo_get(understand:false) posts/logs neither,
# voice_memo_commit success posts + durably logs memoCommitted, an ambiguous
# registry_update commit — needsManual, no write — posts/logs neither), extended
# MemoryProcessLayoutAXTests (+2: liveProcessingBadge per-event AX id suffix +
# distinctness). Branched off origin/main (630a2ed) where its own measured green was
# 2926 (2917 +9), branched independently of PKT-MEM-131/132. Reconciled at merge
# onto integrated floor 2939 (post-131/132) → 2948 (2939 +9).
# 2026-07-02 (PKT-MEM-135 registry_resolve_and_update): +23 tests — RegistryModuleTests
# (+11: exact match resolves+writes in one call, no-match not-found error/no-write,
# ambiguous match error/no-write, append-merge on a configured key, plain overwrite on
# a non-append key, custom appendKeys override, appendKeys:[] disables merge entirely,
# bound-property-id rename-safe predicate match, AND semantics, unknown-entity error,
# empty-where/empty-fields error) + new RegistryAppendMergeTests (+12: appendBlock
# empty/nil/whitespace-only existing, non-empty existing blank-line-separated block,
# new-content trimming, merge default-keys-append-others-overwrite, no-append-key-present
# passthrough, appendKeys:[] disables merge, non-string/absent existing starts fresh
# without throwing, non-string proposed value on an append key passes through, and a
# byte-for-byte cross-check against the original VoiceMemoParser.appendVoiceMemoLog).
# New `registry_resolve_and_update` tool (module `registry`, tier .notify) collapses the
# find-then-get-then-update three-round-trip pattern duplicated inside
# VoiceMemoProcessor.executeRegistryUpdate into one MCP call; ambiguity/no-match semantics
# are identical to registry_find (single match writes; ≥2 matches or 0 matches throws, no
# write). RegistryAppendMerge (new, RegistryWriter.swift) is the shared append-merge
# primitive extracted per the packet's Scope IN, ported byte-for-byte from
# VoiceMemoProcessor.mergeAppendRegistryFields — VoiceMemoProcessor itself is unchanged
# (Scope OUT; rewiring the voice-memo caller is PKT-MEM-136's concern). Branched off
# origin/main at 630a2ed (post PKT-1016/1064/1041/1065B/1065C merges) where the measured
# green was 2917 (0 failed); this branch measures 2940 (0 failed). staticFeatureModuleTool
# Count 199 → 200 (+1); ToolAnnotationCatalog entry added (idempotentHint:false — append-
# merge fields accumulate a new dated block per call, unlike plain registry_update).
# Own measured green was 2940 (2917 +23), branched independently of
# PKT-MEM-131/132/134. Reconciled at merge onto integrated floor 2948
# (post-131/132/134) → 2971 (2948 +23).
#
# 2026-07-02 (PKT-MEM-136 comment disposition + idea-thread ledger): +22 tests —
# new VoiceMemoCommentTests (comment intent kind + required purpose:idea|reflow field
# — GOAL_CONDITION coverage). Idea-purpose happy path resolves via
# registry_resolve_and_update (PKT-MEM-135, NOT a bespoke resolution path) then posts
# via notion_comment_create and logs {memoId, discussionId, targetEntityKey,
# targetPageId, postedAt, signedOffAt:nil} to the new idea-threads.json ledger;
# reflow-purpose happy path posts identically but is asserted NEVER logged
# (fire-and-forget, D48). Graceful-BLOCKED coverage (throws, never a crash — the
# PKT-1064 precedent the packet cites): missing entityHint, entity not configured,
# entity with no title-role property to predicate-match against,
# registry_resolve_and_update no-match/ambiguous, notion_comment_create
# success:false, missing purpose/entityKey/text — each asserted to leave the ledger
# untouched and make zero downstream tool calls where applicable. Plus a
# processOne-seam integration test (execute(intent:...)'s generic catch, the exact
# code path processOne/commit() use, actually catches the failure) and pure-helper
# wiring sanity (dryRunDetail, MemoryHubCockpitLabels.intentKind, threshold(for:),
# cockpit intentRows/intentWritePreview/commitValuePreview round-trip purpose
# without crashing). VoiceMemoIdeaThreadStore (new file) mirrors
# VoiceMemoReviewStore's load/save/enqueue shape exactly (D50) — not deduped (a
# memo may legitimately post more than one idea comment to distinct targets);
# openEntries()/openCount exclude signed-off entries (signedOffAt stays nil for v1 —
# D51, fully agent/manual-initiated, no automatic trigger). notion_comment_create's
# response envelope gained one ADDITIVE key (discussionId, surfacing the Notion
# `discussion_id` the first posted chunk started — same extraction
# notion_discussion_create already does) so executeComment can log it without a
# second round trip; every existing key/shape is byte-for-byte unchanged (no
# existing notion_comment_create test asserts an exact envelope key set — verified).
# Six pre-existing exhaustive `switch …Kind` statements needed a `.comment` arm to
# keep compiling (VoiceMemoProcessor.execute/dryRunDetail,
# MemoryHubGuardrails.threshold(for:), MemoryHubCockpitLabels.intentKind,
# MemoryProcessCockpit.destinationLabel/intentWritePreview/commitValuePreview,
# MemoryHubMemoTitle.subject) — mechanical Swift-compiler-forced wiring, not scope
# creep. `CockpitIntentRow` gained a `purpose` stored property (threaded through
# `intentRows` construction and `intent()` reconstruction) so a comment row
# round-trips purpose through the Process cockpit. registry_resolve_and_update
# requires non-empty `fields` (it is "resolve AND update", not a pure lookup — no
# bespoke resolution path exists), so target-page resolution ALSO writes a small
# dated receipt marker to the resolved row's `summary` field via the SAME call —
# the same kind of append-log receipt every other voice-memo → registry write
# already leaves (executeMemoryKeep's body append, mergeAppendRegistryFields);
# `RegistryWriter`'s existing unbound-field guard naturally raises a clear,
# already-tested error for an entity without `summary` bound, which the untyped
# processOne catch-all already routes to REVIEW — no new error-handling scaffolding
# needed for that case. No new MCP tool (Scope OUT explicitly excludes
# `voice_memo_idea_threads_list` — flagged as a D51 follow-on need, not required for
# this packet's DoD); staticFeatureModuleToolCount stays 200 (voice_memo_commit's
# EXISTING schema gained one additive `purpose` field + an `intentKind` description
# update — not a new tool, no annotation catalog change needed). Branched off
# pkt-mem-135-registry-resolve-and-update (1327bb7) where the measured green was
# 2940 (0 failed); stacked on 135, this branch's own NEW delta is +22 (measures
# 2962 = 2940 +22 in its own branch, confirmed 3x deterministic). Reconciled at
# merge: 135's +23 is already counted in the integrated floor above, so only
# 136's own +22 applies on top — integrated floor 2971 (post-131/132/134/135)
# → 2993 (2971 +22).
#
# PKT-MEM-136 post-ship bugfix (2026-07-02, found via live MCP demo): the
# shipped `voice_memo_commit`'s real argument parser never wired a top-level
# "body" argument into `intent.body` — only "title" was threaded through
# (VoiceMemoProcessor.swift commit()), even though executeComment() reads
# `intent.body ?? intent.title` and the tool's own schema doc for "title"
# already promised "also the comment text fallback when body is unset" —
# proof the body param was always intended but never actually wired. Every
# prior PKT-MEM-136 test drove executeComment directly with a hand-built
# VoiceMemoIntent, bypassing commit(args:)'s parsing layer entirely, so this
# shipped with 2993/2993 green. Live-caught via a real MCP call (raw curl
# JSON-RPC against a stale-tool-schema client session): fields.text and
# fields.body both failed with "comment missing text (body/title)"; the
# title-only fallback path DID work (real Notion comment posted + real
# idea-threads.json ledger entry logged on the operator's Mac, verified).
# Fixed: added a "body" schema property to VoiceMemoModule.swift's
# makeCommit() + `if let body = stringArg(obj, "body") { intent.body = body }`
# to commit(). Added ONE new regression test — the first in the file to go
# through the real commit(args:) entry point instead of executeComment
# directly — proving a top-level "body" arg reaches notion_comment_create's
# text unmodified (not silently downgraded to the title fallback). Measured
# 2994 passed, 0 failed (exactly 2993 +1, the single new test — no other
# drift). FLOOR raised 2993 → 2994 per the order-inversion rule.
#
# CloudEnvSelfHeal (2026-07-02, found via a real restart): `solutions.kup.
# bridge-env` — a RunAtLoad LaunchAgent whose entire job is `launchctl setenv`
# for BRIDGE_ENABLE_HTTP + the WorkOS/cloud vars — lost the boot-order race
# against Bridge's own relaunch (login item / Resume) after a real restart.
# Bridge spawned with none of its cloud env; `launchctl getenv WORKOS_
# CLIENT_ID` was confirmed empty live; connectorAuth stayed nil for that
# process's whole life, so every real connector bearer token (ChatGPT,
# Claude.ai) was rejected as structurally invalid — no issuer/JWKS to
# validate against — surfacing as a confusing "reconnect" error with no path
# back to the cause. New CloudEnvSelfHeal.swift: pure shouldAttemptRepair
# decision (only when cloudAccessEnabled + BRIDGE_ENABLE_HTTP absent + not
# already attempted — a loop guard) + injectable attemptRepairAndRelaunch
# (kicks the LaunchAgent idempotently, relaunches once via a detached
# process so it survives this process's termination and never races
# ensureSingleInstance, then terminates). Wired into AppDelegate.
# applicationDidFinishLaunching right after the single-instance guard, before
# any other subsystem does real work. Purely additive for the default
# (cloud-off) path — shouldAttemptRepair short-circuits false immediately
# when cloudAccessEnabled is false, so a default install's launch sequence is
# byte-for-byte unchanged. Also added a small additive confirmation banner in
# RemoteAccessSection (self-limiting: only shown on the relaunch the repair
# itself triggered, via the same marker argument, never persisted). New
# CloudEnvSelfHealTests.swift contributes 9 harness `test()` blocks (5
# shouldAttemptRepair matrix incl. the loop-guard + cloud-off-never-fires
# cases, 2 wasRelaunchedBySelfHeal, 2 attemptRepairAndRelaunch injected-seam
# ordering/wiring — no real launchd/NSWorkspace/NSApplication touched).
# Measured 3003 passed, 0 failed (2994 + 9, no other drift). FLOOR raised
# 2994 → 3003 per the order-inversion rule.
#
# Notion/Registry Tool Ergonomics Pass (2026-07-03, packet
# 392cbb58889e811abe7ef9714df1dc92): six small, independently-verifiable
# ergonomics gaps closed, additive/backward-compatible only. (1)
# notion_blocks_append gains a pageId+markdown shorthand (server-side
# markdown→blocks via the Notion Markdown Content API's insert_content mode —
# NotionClient.insertPageMarkdown — alongside the existing blockId+children
# raw-block-JSON shape). (2) registry_update gains an optional appendKeys
# merge mode that reuses RegistryAppendMerge/RegistryWriter's existing
# resolveAndUpdate append logic verbatim (new RegistryWriter.update(...
# reader:appendKeys:) overload; no duplicated merge code) — omitting
# appendKeys is byte-identical to the prior plain-overwrite behavior. (3)
# notion_comment_create accepts `content` as an alias for `text` (`text` wins
# if both supplied). (4) notion_query accepts `parentId` as an alias for
# `dataSourceId`, gated on `parentType: "data_source_id"` for symmetry with
# notion_page_create's parentId/parentType vocabulary. (5) notion_page_create
# now verifies children materialization post-create (a block-count readback,
# since Notion's POST /pages response never echoes children) and
# auto-repairs via the same append path notion_blocks_append uses if the API
# accepted the page but produced zero blocks — reported in a new, additive
# `childrenMaterialization` result key. (6) the stale "project-keepr" binding
# in MemoryRoutingScopeMap.swift's table was removed (it duplicated
# focus-keepr's ScopePair; project-keepr was retired/renamed to focus-keepr,
# not a distinct live specialist) — fetch_skill("project-keepr", ...) now
# falls through to the same "unknown parent" → ["global"] path as any other
# unrecognized slug; MemoryRoutingAppendixTests.swift's assertion was updated
# to match (a live behavior change, not just a doc/comment edit). +24 new
# regression tests across NotionModuleTests.swift (18) and
# RegistryModuleTests.swift (6), every one driving the real MCP
# argument-parsing entry point (router.dispatch / ToolRegistration.handler)
# rather than a hand-built model — the AGENT_FEEDBACK 2026-07-02 lesson (a
# suite that only builds models directly can hide a real wiring bug in the
# args-parsing layer itself, as PKT-MEM-136's body-argument gap proved).
# Measured 3027 passed, 0 failed (3003 + 24, no other drift). FLOOR raised
# 3003 → 3027 per the order-inversion rule.
#
# fetch_skill Archive-vs-Canonical Matcher Confidence Fix (2026-07-03, branch
# feat/fetch-skill-matcher-confidence, merged on top of the ergonomics pass
# above — rebased measurement, not the branch's own isolated 3003+8=3011):
# fetch_skill's SkillIntentScorer could silently return an archived
# reference-material child page as a confident match when a canonical
# (non-archived) page with an equal-or-better keyword score existed —
# live-reproduced this session: fetch_skill(name: "close-agent") resolved to
# a nested "sk close agent · Archive" child at matchConfidence 0.4 instead of
# the canonical live page (6673dba8-26b1-4b1d-aa0a-6aad084a861c). Root cause:
# SpecialistFilter.isDocPage only excludes an archive CONTAINER whose title
# STARTS WITH "archive" — it never caught a live-looking child title that
# merely CARRIES an archive marker as a suffix ("sk close agent · Archive"),
# so that title reached the scorer as an ordinary candidate and won on raw
# keyword overlap. Fix (SkillPathResolver.swift): new SpecialistFilter.
# isArchived(title:) — a general, word-boundary "archive"/"archived"
# detector that catches prefix, suffix, and delimited placements (broader
# than isDocPage's anchored ^archive check). SkillIntentScorer.rank now uses
# it, post-scoring, to DEPRIORITIZE (never unconditionally exclude) an
# archived candidate whose raw score is >= the best non-archived candidate's
# score — nudged to (bestNonArchived - 0.001) rather than zeroed, so it can
# still surface in a genuine disambiguate band but never wins the confident
# slot over a live peer. Relative + title-predicate-keyed (not a hardcoded
# id/name check), and fail-open: an archived candidate with no non-archived
# sibling in the same candidate set still resolves normally (mirrors
# isActiveSpecialist's fail-open bias). New tests added to
# RoutingReliabilityTests.swift: the isArchived predicate matrix
# (prefix/suffix/delimited/no-false-positive), the real close-agent collision
# fixture (canonical wins both at an unambiguous exact-title margin and at a
# near-tied raw-score margin), archived-only fail-open, and
# archived-with-higher-raw-score-still-loses — plus two explicit REGRESSION
# tests proving the separate, correctly-working focus-keepr-style
# multi-specialist disambiguation (genuinely live candidates, no archive
# markers) is unaffected: it still returns .disambiguate across both live
# candidates, and a tied non-archived pair's scores are byte-identical
# before/after (nonArchivedScores.max() over an all-non-archived set is a
# no-op by construction). +8 tests on top of the ergonomics pass. Measured
# 3035 passed, 0 failed (3027 + 8, no other drift). FLOOR raised 3027 → 3035
# per the order-inversion rule — reconciled by hand at merge time since both
# branches independently computed their target off the same pre-merge 3003
# baseline (the exact monotonic-counter collision class already documented
# in AGENT_FEEDBACK.md's 2026-07-02 entry).
#
# Voice Memo Commit Quality Gate + Reliability (2026-07-03, GH #81 + GH #73,
# REVIEW-FIRST): new VoiceMemoContentQualityGate.swift — an explicit,
# reviewable minimum-information rule (>=8 whitespace-separated words AND
# <40% disfluency-token ratio; below either ⇒ rejected) wired into
# executeMemoryKeep BEFORE any Notion write, so a filler/fragment summary
# (GH #81's 3 real repro strings: "I'm having fun with this idea", "At these
# at these days, okay", "We, uh, terrible the sea" — all correctly rejected)
# can never reach markedProcessed:true; both processOne (batch) and
# commit(args:) route a gate-rejected memory_keep lane to the SAME review
# queue with a stated reason, never a silent success. Promoted the
# previously-undiscoverable fields.summary passthrough to a first-class
# top-level `summary` schema parameter on voice_memo_commit
# (VoiceMemoModule.swift) — VoiceMemoProcessor.swift's commit(args:) parser
# now documents + wires it (applied after the generic `fields` object so an
# explicit `summary` always wins). New VoiceMemoStageTimeout.swift (GH #73)
# — a generic race-based timeout primitive (mirrors CredentialValidator's
# existing timeout-race pattern, generalized to async throws) wraps the
# transcribe/understand/execute stages in both processOne and commit(args:);
# a stage that exceeds its budget degrades to the heuristic floor (understand)
# or throws into the SAME graceful review-queue path a normal stage failure
# already uses (transcribe/execute) — voice_memo_process and voice_memo_commit
# now always terminate in {done, error, review-queue}, never an indefinite
# hang with no completion payload. Every new code path is tested by driving
# the REAL MCP args:-parsing entry points (VoiceMemoProcessor.commit(args:) /
# process(args:)) with a real on-disk recording fixture — not a hand-built
# VoiceMemoIntent shortcut — per this session's own PKT-MEM-136 lesson
# (AGENT_FEEDBACK 2026-07-02: a suite that never drives commit(args:) hid a
# real argument-wiring bug). Fixed one pre-existing fixture
# (VoiceMemoTranscriptOverlapGuardTests.overlapPlan()'s 3-word placeholder
# summary) that the new gate correctly flagged as filler — replaced with a
# realistic short sentence so that file continues to test ONLY the
# transcript-overlap guard, its actual concern. Deferred out of this packet's
# hard DoD (REVIEW-FIRST scope decision, recorded in the packet): Memory Hub
# Process-tab UI intent-chip parity (PKT-MEM-128/130 — audited and found
# ALREADY correctly wired to the structured plan payload via
# MemoryProcessCockpit.tagLabel/intentRows, no code change needed) and the
# voice-router client→contact entity alias map (PKT-MEM-127 — confirmed
# unimplemented; no "client" keyword routing exists anywhere in
# VoiceMemoParser.swift's entityHints, which is hardcoded to entityKey:
# "contact" today).
#
# PKT-MEM-127 follow-up (2026-07-03, same branch): implemented the
# voice-router client alias. entityKey was already correctly "contact" (the
# registry entity name) — the real gap was that entityHints' trigger guard
# and regex patterns never recognized the word "client" at all, so a memo
# mentioning "my client, Greg Flachek" (the real GH #73 transcript,
# live-confirmed this session) produced zero entity hints. Added a "client"
# trigger + a `client,?\s+(?:named\s+)?(Name)` pattern. +2 tests
# (real-transcript case + an "a client named X" phrasing variant).
#
# Branch-isolated measurement (base 3003, before this merge): 3003 + 17
# (quality gate + timeouts) + 2 (client alias) = 3022 passed, 0 failed, 3x
# deterministic. Merged on top of the ergonomics + matcher pass above —
# rebased measurement: 3035 + 19 = 3054 passed, 0 failed, no other drift.
# FLOOR raised 3035 → 3054 per the order-inversion rule — reconciled by hand
# at merge time (both branches independently computed their target off the
# same pre-merge 3003 baseline, the exact monotonic-counter collision class
# already documented in AGENT_FEEDBACK.md's 2026-07-02 entry).
#
# PKT-MEM-127 hotfix (2026-07-03, shipped as v3.9.7 build 76): live
# verification against the real running v3.9.7 build 75 server caught the
# just-shipped client-alias pattern producing a real false positive —
# "Greg, Flachek, my client, and..." (the real GH #73 transcript, fetched
# live, not the earlier secondhand paraphrase "my client, Greg Flachek" the
# original pattern was built from) matched "client, and..." and captured
# "and" → "And" as the "name". Rewrote as two narrower forms requiring a
# real \bclient\b word boundary (so "clients" plural never substring-matches
# "client") and a TRUE capitalized first letter on the captured name
# (`(?-i:[A-Z])`, overriding the pattern's own .caseInsensitive compile
# option) so a lowercase filler word can never be captured as a name. A
# second false positive surfaced by a dedicated regression test during this
# very fix ("some of my clients" → captured "of") was caught and fixed
# before shipping, not after. +1 test (3 total for PKT-MEM-127: real
# transcript, forward "named" form, plural-noise guard). Measured 3055
# passed, 0 failed. FLOOR raised 3054 → 3055.
#
# Memory Settings 3-tab redesign integration cleanup (2026-07-03, INVESTIGATED
# LOWER — not a regression): the 5-tab Memory surface (Process/Inbox/Notion/
# Agent/Processing) consolidated into 3 (Memos/Recall/Settings; Wave 0 +
# 3 tab-implementation waves landed no new TheBridgeTests/ files — pure UI
# ports, verified via memory-swiftui-uiiter-log.md's live UI-ITER loops, not
# unit tests). This cleanup deleted the 6 now-fully-orphaned old tab files
# (MemoryProcessTab/MemoryProcessingTab/MemoryNotionTab/MemoryNotionViewModel/
# MemoryAgentTab/MemorySurfacingSettingsCard — every deletion grep-confirmed
# zero remaining references first; MemoryProcessRegistryConfigureSheet, the
# one piece of MemoryProcessTab.swift MemoryMemosTab.swift still genuinely
# depended on, was relocated verbatim into MemoryMemosTab.swift before
# deleting the rest) and removed exactly one test that instantiated the
# deleted MemoryNotionViewModel directly ("MemoryNotionViewModel reports
# unconfigured memory entity", MemorySettingsTests.swift) — its subject type
# no longer exists and has no live replacement (DataSourcesSection's generic
# entity card fully absorbed that surface already, per MemorySection.swift's
# header comment). Measured 11→10 tests in MemorySettingsTests.swift,
# 3055→3054 passed overall, 0 failed, matching exactly (no other drift).
# FLOOR LOWERED 3055 → 3054 — a deliberate, investigated, single-test net
# removal for a deleted type, not a coverage regression.
#
# PKT: fields Param Across Registry Tools + fetch_skill (2026-07-03): added
# the opt-in `fields` result-projection param (array of top-level keys,
# incl. dotted `properties.X` sub-selection) to the 6 row-shaped
# registry_* tools (list/find/get/create/update/resolve_and_update) AND
# fetch_skill, sharing one new pure filter primitive (FieldsFilter.swift,
# TheBridge/Modules/) rather than 7 copies. +41 tests across 3 files:
# FieldsFilterTests.swift (22 hermetic synthetic-Value fixture tests —
# omitted/empty-array identity, top-level key selection, bare vs dotted
# `properties`, permissive union, unknown key/path silent no-match,
# case-insensitive property-path matching, malformed-type hard error,
# non-object defensive passthrough, custom propertiesKey param);
# RegistryModuleTests.swift (+13 wiring-proof tests — one per tool,
# omitted-fields regression, properties.X sub-selection, the
# write-payload-object vs result-projection-array non-collision on the 3
# write tools sharing the `fields` key name, resolve_and_update's separate
# `resultFields` param since its `fields` is mandatory/write-only, malformed
# hard-error, schema declaration checks); SkillsModuleTests.swift (+6 —
# schema shape, malformed-type + non-string-element hard errors, and 4
# envelope-shape tests driven through the exact production
# buildSkillResultForTesting builder proving fetch_skill's own key
# vocabulary round-trips through the shared filter). Measured 3095 passed,
# 0 failed (3054 baseline + 41 = 3095, matching exactly). FLOOR raised
# 3054 → 3095.
#
# 2026-07-06: connector-reauth triage (independent branch, computed off the
# same pre-merge 3054 baseline as the fields-param PKT above — the exact
# monotonic-counter collision class in AGENT_FEEDBACK.md's 2026-07-02 entry,
# reconciled by hand here) turned up two confirmed diagnostics bugs.
# (1) connections_health's handler passed validateLive:true in both branches,
# contradicting its own tool description ("doesn't hit the live service") —
# indistinguishable from connections_validate; fixed to validateLive:false.
# (2) SessionModule.sessionStartTime was a `static let` referenced only inside
# the session_info/session_clear handler closures, so Swift lazily
# initialized it on first TOOL CALL rather than at register() (server boot)
# time — uptimeSeconds silently measured "time since first call", not "time
# since boot". Moved the capture to a local value at the top of register().
# +2 regression tests (independent-start-times in SessionModuleTests.swift,
# cached-lastValidatedAt in ConnectionsModuleTests.swift), rebased on top of
# the fields-param merge above. Measured 3097 passed, 0 failed on the
# combined tree (3095 + 2, matching exactly, no other drift). FLOOR raised
# 3095 → 3097.
# Remote connector scope-discovery fix (2026-07-07): added 1 regression
# test proving strict connector tools/list hides local-only Messages tools
# that the same bearer would fail to call. Measured 3098 passed, 0 failed
# on the rebased branch (3097 + 1). FLOOR raised 3097 -> 3098.
# Wave 1 broker reconciliation (2026-07-07): merged origin/main into
# feat/w1-broker — a real (non-mechanical) conflict in SSETransport.swift's
# processConnectorJSONRPC, since main independently added scope-based
# tools/list filtering (connectorVisibleRegistrations) the same place
# w1-broker added broker-first tools/list ordering + session-context
# threading. Resolved by combining both: filter by scope, then reorder the
# filtered set; both token/auth scope-gating and session/origin context now
# flow through the same dispatch path. +10 tests (Wave1BrokerTests.swift +
# related session-broker coverage). Measured 3108 passed, 0 failed on the
# merged tree (3098 + 10, no other drift). FLOOR raised 3098 -> 3108.
# codex/cloud-oauth-readiness merge (2026-07-09): rebased the deferred
# strict-connector-scope branch onto post-w1-broker main. ConnectorScopeGate's
# now-redundant standalone `bootstrapTools` bucket (bridge_initialize only)
# was removed — main's `bridgeSessionTools` bucket (added by w1-broker,
# covering bridge_initialize/bridge_status/tools_list/session_info) already
# absorbs it — but its scope requirement was widened from the single
# `bridge.session` scope back to "any known connector scope" to preserve
# cloud-oauth-readiness's own pre-existing contract: a real, live-caught test
# failure ("ScopeGate: bridge_initialize is bootstrap-reachable by any
# connector grant", not a git-conflict artifact — it wasn't part of either
# conflict hunk) proved these bootstrap-class tools must stay reachable by
# any authenticated connector grant, not gated behind one specific scope.
# +10 tests from this branch's own additions (RemoteOAuthOriginGatingTests.swift,
# CloudStatusModuleTests.swift, RemoteOAuthHTTPTests.swift,
# MCPHTTPValidationTests.swift). Measured 3118 passed, 0 failed on the merged
# tree (3108 + 10, no other drift). FLOOR raised 3108 -> 3118.
# v3.9.8 release + PR #93 (Notion icon tests + voice_memo_get timeout parity,
# 2026-07-09) landed +7 tests on main without a floor bump (measured 3125
# passed, 0 failed at that point — the floor was left stale at 3118). This
# fix/connector-full-parity-revert branch (strictScopes default true -> false,
# restoring full Claude Connectors tool parity) adds +1 test (the old
# "default strictScopes" destructive-step-up test was split into an explicit
# strictScopes:true regression test plus a new test asserting the false
# default) for a net +8 over 3118. Measured 3126 passed, 0 failed on this
# branch. FLOOR raised 3118 -> 3126.
# v3.9.9 build 79 (2026-07-10): bridge_initialize origin-awareness fix
# (defaultContextProvider hardcoded connectionState:"local" for every caller;
# now reads ToolDispatchContext.current.origin). +2 tests
# (BridgeInitializeTests.swift: remote origin -> "online"/FULL, local/no-
# context -> "local"). Measured 3128 passed, 0 failed. FLOOR raised 3126 -> 3128.
# v3.9.9 build 80 (2026-07-10): remote control-plane block defaults OFF,
# governed-session enforcement split to an independent default-ON switch, and
# governed remote shell parity covered end-to-end at ToolRouter dispatch. +3
# Wave1BrokerTests. Measured 3131 passed, 0 failed on this branch alone
# (codex/remote-shell-parity, diverged from main at 3128 before PR #87
# landed). FLOOR raised 3128 -> 3131.
# PKT-1116 Observability & Diagnosis (2026-07-11): +3 audit_recent tests
# (filter/order, credential secrecy, enum/limit validation) and +5 ax_tree
# traversal-budget tests (wide-child cap, maxChildren clamp, in-budget payload,
# byte-budget notice, schema isolation). Cloud-status/build-provenance scenarios
# replace/extend existing WS-D assertions without increasing their count.
# Measured 3136 passed, 0 failed. FLOOR raised 3128 -> 3136.
# PR #87 reconciliation (2026-07-11): merged codex/ship-v4-packet-closeout's
# Routing Integrity Layer (PKT-1094 — ToolSkillBindingRegistry, per-tool
# manifest-fetch gate, HandshakeReceipt.routingIntegrity, schemaVersion 2->3)
# onto post-w1-broker main. Real conflicts in ToolRouter.swift/AuditLog.swift/
# SSETransport.swift/ServerManager.swift over the same dispatch signature both
# sides touched (flat sessionID: String? vs w1-broker's ToolDispatchContext) —
# resolved by keeping context-based dispatch everywhere and threading RIL's
# manifest gate through it. One real (non-mechanical) test failure surfaced
# after conflicts compiled clean: the manifest gate fired before w1-broker's
# governed-session gate for messages_send, producing the wrong rejection
# reason for an ungoverned remote session. Fixed by moving the manifest-gate
# check to run after the broker's origin-level gates, not by changing the
# test. +10 tests (RoutingIntegrityLayerTests.swift). Measured 3138 passed,
# 0 failed on the merged tree (3128 + 10, no other drift). FLOOR raised
# 3128 -> 3138. This landed on main independently of, and in parallel with,
# the build-80 entry immediately above (both diverged from the same 3128
# baseline; neither had seen the other's work yet).
# codex/remote-shell-parity merge (2026-07-11): merged post-PR-#87 main
# (Routing Integrity Layer, floor 3138) into this branch (build-80 remote
# control-plane default flip, floor 3131). Both sides had independently
# diverged from the 3128 baseline, so this is a real union, not a simple
# max() of the two floors. ToolRouter.swift merged clean (no textual
# conflict): the branch's one-line change — the governed-remote-session gate
# now reads BridgeDefaults.brokerRemoteGovernedSessionRequiredEnabled instead
# of brokerRemoteControlPlaneBlockEnabled — landed on the post-RIL dispatch
# method exactly where PR #87 documents it belongs (after the hard-blocklist
# gate, before the manifest-fetch gate). The separate hard-blocklist gate
# (RemoteControlPlanePolicy.isBlocked, keyed to
# brokerRemoteControlPlaneBlockEnabled) was untouched. Wave1BrokerTests.swift
# also merged clean: this branch's +3 tests (missing-key default OFF,
# explicit opt-in, governed remote shell reaches dispatch,
# governed-session-remains-fail-closed) sit alongside main's schemaVersion
# 2->3 bump with no overlap. Only this file (test-floor-gate.sh) had a real
# textual conflict, from both sides appending a FLOOR line after the same
# 3128 baseline; resolved by keeping both provenance blocks in chronological
# order and adding this reconciliation entry. Net: 3128 + 3 (build 80) + 10
# (RIL) = 3141 expected; measured 3141 passed, 0 failed on the merged tree.
# FLOOR raised 3138 -> 3141.
# codex/pkt-1116-observability-diagnosis merge (2026-07-11): merged origin/main
# (which already carried the PR #87 Routing Integrity Layer reconciliation
# above) into this branch. No textual conflicts outside this file — AuditLog.swift
# (CaseIterable + entries(forSessionID:)) auto-merged clean, and
# ServerManager.swift/AccessibilityModule.swift/CloudStatusModule.swift/
# SessionModule.swift/ToolAnnotations.swift were untouched by main since the
# merge base so this branch's PKT-1116 diagnostics logic (router-dispatch-based
# tools/list filtering, ax_tree traversal budgets, audit_recent, build
# provenance) carried over unmodified. This file's own FLOOR chain was the only
# conflict, resolved by keeping both blocks above in sequence. Combined tree
# carries this branch's own +8 (audit_recent/ax_tree, 3128 -> 3136) together
# with main's +10 (RoutingIntegrityLayerTests, 3128 -> 3138) on top of the
# shared 3128 base. Measured 3146 passed, 0 failed on the merged tree
# (3128 + 8 + 10, no other drift). FLOOR raised 3128 -> 3146. This PR (#99)
# merged to main before #101 (this branch), which is what makes the next
# entry below necessary.
# Three-way reconciliation (2026-07-11): #99 (pkt-1116, +8) merged to main
# first, landing floor 3146 there. This branch (#101, +3, already carrying
# its own prior reconciliation with PR #87's RIL above at 3141) then merged
# that updated main — a second real textual conflict in this same file,
# since both #99 and #101 had independently appended a FLOOR line after the
# shared 3138 (RIL) baseline. All three independent additions on top of the
# original 3128 base are additive and non-overlapping (different test files
# entirely: Wave1BrokerTests +3, audit_recent/ax_tree +8, RoutingIntegrityLayerTests
# +10) -> 3128 + 3 + 8 + 10 = 3149 expected. Measured 3149 passed, 0 failed on
# the fully-merged tree. FLOOR raised 3146 -> 3149.
# PKT-1122 W2A auth-error clarity (2026-07-13): +7 tests cover the
# stable local failure taxonomy, publicly indistinguishable correlated tunnel
# responses, actual tunnel-simulated curl captures with local audit mappings,
# OAuth precedence over a configured legacy static bearer, and refreshed-token
# continuity for an established connector session. Measured 3156 passed, 0
# failed on the current origin/main-based worktree. FLOOR raised 3149 -> 3156.
# PKT-1123 W2B reconnect observability/recovery (2026-07-13): +7 tests
# cover request-tier local reset registration, local-vs-tunnel redacted
# runtime projection, repeatable governed broker-session rotation, direct and
# router-level remote reset denial (including with the broad hardening switch
# off), and Settings runtime/reset clarity. Measured 3163 passed, 0 failed on
# the current origin/main-based worktree. FLOOR raised 3156 -> 3163.
# PKT-1124 W2C governance propagation (2026-07-14): +4 hermetic tests prove
# stable Streamable-HTTP session keying, fail-closed fresh reconnect/spoof
# behavior, and stdio parity. Current main did not reproduce the authored
# false-negative; no production behavior changed. Measured green 3163 + 4.
# 2026-07-14 PKT-1121: +10 net-new hermetic config-path migration tests
# (canonical/override resolution, fresh install, full archive + sidecars,
# MemoryStore parity, idempotence, collision safety, override skip, and both
# post-rename and pre-rename journal recovery paths).
# PKT-1120 W3 tool ergonomics (2026-07-14): +17 net-new hermetic tests cover
# dead-PID AX lookup, deterministic screen-window identity selection,
# AX-path click geometry, the voice-memo settings tool pair, and mode-aware
# Memory Settings clarity. Measured 3194 passed, 0 failed. FLOOR 3177 -> 3194.
# PKT-1125 W3 hint-only tool-argument aliases (2026-07-14): +8 focused
# tests cover exact deterministic mappings, accepted-key suppression, one-shot
# handler failure with no retry, canonical argument preservation, unknown-key
# behavior, live Notion dual-key schemas, and the single handler-call-site
# source invariant. Measured 3202 passed, 0 failed. FLOOR 3194 -> 3202.
# v3.7.6 (2026-06-04): credential policy defaults flipped ON; +1 isEnabled default-ON test (1776→1777).
# v3.7·A (2026-05-28): SkillsCacheReader/Writer pipeline tests landed.
# +12 SkillsCacheTests covering the on-disk skills cache that closes the
# PKT-907 Notion-source eager-enumeration carve-out and the v3.6·5
# StandingOrders cachedRoutingSkills TODO:
#   • write→read round-trip preserving CachedParent + children +
#     writtenAt + ttlHours + alias/summary fields;
#   • multi-parent isolation (per-file storage, no cross-contamination);
#   • readAll() set semantics across the .skills-cache directory;
#   • TTL boundary inside the window → stale=false;
#   • TTL exceeded → stale=true (clock-injected via the reader seam);
#   • stale entries still readable — graceful-fallback contract (the
#     cache is a hint, not a source of truth);
#   • missing parent → graceful nil (no throw, no log);
#   • BridgePaths resolution under applicationSupport(.skillsCache);
#   • forwards-tolerant JSON decode (unknown top-level + child keys
#     ignored so writer revisions don't break older readers);
#   • concurrent-write safety (10× fan-out through a TaskGroup, asserts
#     last-writer-wins with no torn payload across title+children);
#   • BridgeDefaults.skillsCacheTTLHours UserDefaults override flowing
#     through skillsCacheTTLHoursEffective (24 default / 0 fallback /
#     negative fallback / positive override end-to-end via refreshAll);
#   • refreshAll() byte-idempotency (same now + sorted-keys + sorted-
#     children → byte-identical on-disk output across passes).
# Floor 1454 → 1466 (+12) per order-inversion rule.
#
# v3.6·6 wave-2 integration (2026-05-27): cumulative floor after
# PKT-907 + PKT-909 integration merge.
#
# PKT-907 (Bridge v3.6 · 10): fetch_skill orchestrator — slash-delimited
# path resolution + optional intent ranking + specialist surfacing in
# `skills_routing_list`. +21 SkillPathResolverTests:
#   - W1: SkillPath.parse (6 tests — bare name, parent/child, depth >1,
#     empty/whitespace, leading/trailing-slash tolerance, segment trim);
#   - W2: SkillIntentScorer (8 tests — exact 1.0, alias 0.85, partial 0.7,
#     keyword overlap 0.4–0.6, low-confidence nil fallback, empty-intent
#     defensive empty, alpha tie-break, bare-parent passthrough);
#   - W1/Q4: SkillSpecialistFileResolver (3 tests — dir primary, frontmatter
#     fallback, unknown-child nil);
#   - W3: SpecialistSummaryExtractor + listAll (3 tests);
#   - 1 wire-stable annotation contract.
# Carve-out: Notion-source specialist eager enumeration deferred (per-parent
# N×N cold-start regression); file-source surfacing shipped.
#
# PKT-909 (Sell/Distribute v3 · 1): License-key system + 30-day trial gate
# + grandfather safety contract. +57 tests:
#   • LicenseTokenTests (+15): Ed25519 sign/verify round-trip; payload/sig/
#     wrong-key/malformed/invalid-base64 rejection; schema validation;
#     base64url no-padding round-trip; canonical-JSON determinism;
#     LicenseState Codable + forwards-tolerant decode.
#   • LicenseManagerTests (+19): pure trial math (30/29d23h/0=expired);
#     grandfather/licensed/license-expired derivation; pill labels;
#     isActive matrix; SAFETY-CONTRACT loadOrInit grandfather-sentinel
#     (present/sticky/fresh-install-no-sentinel); activate success +
#     persistence; activate-wrong-key rejected + non-mutating; deactivate;
#     loadOrInit idempotent; acknowledgeTrialExpired clears on activate;
#     factoryReset removes license.json.
#   • LicenseUITests (+9): LicenseUIState mapping for every LicenseStatus;
#     canPasteActivate preserved; lastError plumbed; Notification.Name
#     under com.notionbridge namespace.
#   • LicenseRevocationTests (+8): worker /verify happy paths (active/
#     revoked/refunded); 500/non-JSON/transport-nil → nil; client-side
#     short-id reject; body shape.
#   • LicenseToolErrorTests (+3): BridgeToolError.trialExpired carries
#     toolName + kind; errorDescription; Equatable distinguishes kind.
#   • LicenseDispatchGateTests (+5): ToolRouter end-to-end — trial-active/
#     grandfathered/licensed pass; trial-expired → throws kind=trial-expired;
#     license-expired → throws kind=license-expired.
#
# Baseline 1376 (v3.6·6 polish) + 21 (PKT-907) + 57 (PKT-909) = 1454.
# Verified release-build green with `swift build -c release
# -Xswiftc -strict-concurrency=complete` (0 errors).
# v3.6·6 hardening (2026-05-27): +6 CommandStore security tests
#  (slug ASCII alphabet lock — homoglyph attack prevention, path-traversal
#  character stripping, control-character stripping, empty/whitespace
#  produces-empty-slug invariant). slugify previously accepted Unicode Ll
#  (lowercase letter category) which permitted Cyrillic 'а' (U+0430) and
#  other homoglyphs to slip through; now locked to ASCII [a-z0-9_-].
# v3.6.0 polish (2026-05-27):
#  +5 D1 credentials scope filter regression tests
#    (matchesAccessGroup pure predicate covering: no-group leak fix,
#    matching group, different group, empty string, non-string value).
#  +5 D6 ModuleGroupCard expand-state persistence contract
#    (key namespace, dict round-trip, no cross-group bleed, cold-launch
#    collapsed default, ModuleGroupID rawValue dict-key safety).
# v3.6 (2026-05-27): cumulative floor after PKT-876 + PKT-877 + PKT-878 + PKT-879 merges.
# PKT-876: +14 Settings sections LG tests (shared BridgeSettingsSectionHeader,
# dep-link derivation, SF Symbol presets across 5 reskinned sections).
# PKT-877: +25 Tools tests (ModuleGroup derivation, override paths,
# state machine, live-registry no-orphan invariant, + 6 SAFETY-CONTRACT
# tests asserting BridgeToolError.moduleGroupDisabled by type).
# PKT-878: +19 Command Bridge tests — placement math (Q2 25%-up-from-bottom),
# CommandBridgeRecents MRU + cap (Q1 in-memory), CommandBridgeAnimation
# locked/reduce-motion values, viewModel pure builders, applyCommit
# clipboard contract, controller lifecycle, hot-key plumbing-failure shape.
# PKT-879: +27 Dashboard + Onboarding + icon-picker tests — popover sizing,
# pulse-glow reduce-motion, jump-link nav routing, 7-step wizard,
# Recommended badge invariant, IconPickerCatalog emoji + SF Symbol
# curation + de-duped + NSImage resolvable, CommandStore icon round-trip.
# Baseline 1275 at HEAD 4554d32 + 14 + 25 + 19 + 27 = 1360.
# Agent-surface reliability integration (2026-07-14): +5 net-new hermetic
# tests cover deterministic manifest ordering, revision changes on registry
# mutation, rate-limited unknown-tool audit telemetry, secret-shaped miss
# redaction, and client name/version attribution. Measured 3207 passed, 0
# failed on the current origin/main-based worktree. FLOOR 3202 -> 3207.

# 2026-07-15 Notion views list/get + comment discussionId reply. FLOOR 3207→3213 (+6 greens; hermetic body/schema tests). staticFeatureModuleToolCount 205→207.
# 2026-07-15 Voice Memo Reliability (list filters/pagination/health + commit receipts + FieldsFilter identity keys). FLOOR 3207→3214 (+7).
# PKT-CALL-001 Wave 1 (2026-07-17): +14 hermetic CallHistory tests cover
# calls_recent registration/tier/schema/annotations, phone normalization,
# limit/since/number/direction filters, newest-first ordering, identity-free
# output, actionable Full Disk Access failure, explicit schema-drift failure,
# and an incompatible SQLite fixture. Measured 3221 passed, 0 failed on the
# origin/main-based calls worktree. FLOOR 3207 -> 3221.
# Agent-feedback reconciliation (2026-07-17): +11 net-new tests cover job
# previous-result paths and fail-closed misses, Messages attribution provenance,
# bounded skill/Notion section misses, skill metadata drift, block/page cache
# eviction, cross-entity registry cache eviction, packet/session compatibility,
# and actionable Notion 401 guidance. Measured 3218 passed, 0 failed on the
# origin/main-based feedback worktree. FLOOR 3207 -> 3218. A deliberately
# failing precursor also proved complete-log retention to the stable evidence
# directory before its assertion was corrected.

# Review integration proof (2026-07-17): PR #106 Notion views/comment replies,
# PR #107 Voice Memo reliability, PKT-CALL-001 Wave 1, and the agent-feedback
# reconciliation coexist on one origin/main-based worktree. Measured 3249 passed,
# 0 failed. FLOOR 3221 -> 3249 for the review integration candidate.

# Calendar–Registry hardening (2026-07-17): +26 net-new hermetic tests across two independently reviewable units. The skill-mutation unit covers parent/specialist resolution, specialist body eviction, metadata convergence, and separate routing-refresh evidence. The reduced sync unit covers atomic transaction-journal restart, sequential and concurrent idempotency, calendar-create and post-calendar-write recovery, false-Synced prevention, fresh EventKit-provider recovery, ambiguous identity conflict, degraded lookup refusal, full date-range/timezone round-trip, authoritative filtered Notion lookup, explicit nullable clears, recoverable partial Notion creation, disabled composition, and route ownership. Measured 3232 before the final cache-evidence test; expected final floor 3233. FLOOR 3228 -> 3233.

# Calendar–Registry review-integration replay (2026-07-18): the reduced sync
# unit adds 5 greens to the 3249 review-integration floor while the unrelated
# skill-mutation commit remains excluded. FLOOR 3249 -> 3254.

- Calendar–Registry recovery hardening (2026-07-17): replaced the process-local JSON correctness boundary with a SQLite recovery ledger and immutable operation fingerprint persisted on Notion and EventKit; added production gateway truth/strict decoding, identity-envelope repair, manifest-authority verification, timezone/event-shape/calendar-qualification gates, durable failure receipts, and migration-model validation. The recovery matrix now contains 22 scenarios, including independent SQLite handles, ledger-loss reconstruction/conflict, partial-page retry, drift refusal, invalid timezone/key, shape rejection, unqualified calendar refusal, and unpersisted recovery evidence. Measured 3239 passed, 0 failed. FLOOR 3233 -> 3239.

# Review-integration replay: recovery hardening adds 6 greens to the combined
# candidate floor. FLOOR 3254 -> 3260.

- Calendar–Registry single-writer fencing (2026-07-17): upgraded the SQLite recovery ledger into a single-machine transaction coordinator with expiring leases, fencing tokens, monotonic revisions, compare-and-swap saves, stage/identity regression guards, and cancellation-aware ownership. Added typed raw Notion identity reads, strict page/create/update/query row decoding, identity-first EventKit recovery across unsupported shapes, canonical manifest semantics, final Sync Hash/Last Synced At readback, and ledger-corruption refusal. The synchronization matrix now contains 40 scenarios, including same-key independent-engine races, stale fences, lease expiry, ledger-known malformed/missing identity, uncertain create recovery, unsupported existing event shapes, unrelated malformed metadata isolation, final evidence loss, and pre/post-effect cancellation. Measured 3257 passed, 0 failed. FLOOR 3239 -> 3257.

# Review-integration replay: single-writer fencing adds 18 greens to the
# combined candidate floor. FLOOR 3260 -> 3278.

- Calendar–Registry fail-closed smoke narrowing (2026-07-17): replaced lease-expiry-based external-effect ownership with a per-idempotency-key OS advisory lock held across the complete registry/EventKit transaction. Narrowed the smoke path to one pre-existing canonical Notion EVENT; automatic Notion creation and partial repair are no longer reachable. Added durable EventKit create-intent / calendar-effect-unknown recovery-only stages, immutable established pair identifiers, final-read Sync Hash recomputation, exact delimited metadata attribution, optional provider modification timestamps, local-filesystem composition enforcement, and schema-v3 stage migration. The hermetic recovery matrix now contains 50 scenarios, including real child-process contention with a provider call held beyond SQLite lease duration, unknown-effect no-recreate behavior, production Notion adapter no-create proof, final identity/evidence mutation, and state-specific recovery receipts. Measured 3267 passed, 0 failed. FLOOR 3257 -> 3267.

# Review-integration replay: fail-closed smoke narrowing adds 10 greens to the
# combined candidate floor. FLOOR 3278 -> 3288.

- Calendar–Registry authority and uniqueness hardening (2026-07-17): final verification now re-proves exactly one live Notion EVENT and one EventKit identity; registry-first execution requires Registry authority and an admissible clean-or-complete pairing state before calendar access; Notion writes are revision-checked and limited to pairing-owned fields so concurrent semantic edits are preserved; production uses one canonical local coordinator with hardened lock-root/file validation; receipts separate stable transaction ID from attempt ID and report coordinator namespace, final registry revision, and uniqueness counts. The hermetic recovery matrix now contains 61 scenarios. Measured 3278 passed, 0 failed. FLOOR 3267 -> 3278.

# Review-integration replay: authority and uniqueness hardening adds 11 greens
# to the combined candidate floor. FLOOR 3288 -> 3299.

- Calendar–Registry vNext forward-only pairing (2026-07-18): replaced the procedural recovery path with stage-directed forward-only continuation; added a durable Calendar Create Invocation ID that permanently closes automatic recreation after uncertainty, strict production Notion authority/state/revision decoding, synchronization writer tokens and monotonic Sync Revision readback, EventKit metadata v2, bounded owned-identity search receipts, and Operator Review terminal semantics. Hardened a dedicated local coordinator across lock, SQLite, WAL, and SHM files with symlink, owner, mode, link-count, stable device/inode, partial-write, and directory-fsync checks. Expanded the hermetic and production-adapter recovery matrix from 61 to 80 scenarios, including ledger-loss no-recreate, late-stage crash resumption, zero EventKit access before registry authorization, malformed revision refusal, writer-token loss, bounded-search truth, and coordinator attack cases. Measured 3297 passed, 0 failed. FLOOR 3278 -> 3297.

# Review-integration replay: forward-only pairing adds 19 greens to the
# combined candidate floor. FLOOR 3299 -> 3318.

# Calendar–Registry literal crash matrix (2026-07-18): +16 tests. CR81–CR95
# terminate a real child process after each material durable-write or EventKit
# effect boundary, then run two fresh-process recoveries. All paths prove at
# most one automatic create: 13 recover to Complete with exactly one item; the
# two Create Invocation registry/ledger gaps stop at Operator Review with zero
# creates. CR96 locks removal of the unreachable legacy procedural recovery
# helpers. FLOOR 3318 -> 3334.

# Bridge v4 integration (2026-07-18): replayed the unique specialist-metadata
# mutation fix after the review-integration + Calendar candidate. Adds 8 greens
# covering parent/specialist mutation targeting, specialist body-cache eviction,
# and shared cache refresh. Measured 3355 passed, 0 failed. FLOOR 3334 -> 3342.

# CI portability hardening (2026-07-18): resolve TheBridgeTests through
# SwiftPM's architecture-aware `swift build --show-bin-path -c debug` output
# instead of assuming the convenience `.build/debug` symlink exists, and request
# the `TheBridgeTests` executable product explicitly so a clean SwiftPM build
# cannot stop after compiling target objects without linking the harness. Floor unchanged.

# PKT-CALL-001 Wave 1R (2026-07-19): compatible CallHistory SQLite fixture +
# Apple reference-date decoding; distinguishable database_missing vs FDA vs
# schema vs query errors; durable call-id helper (ZUNIQUE_ID / Z_PK fallback)
# with docs sync. Measured 3359 passed, 0 failed. FLOOR 3342 -> 3359.

# Calendar–Registry sprint W2 (2026-07-20): env-filtered `calendar_registry_pair`
# MCP tool (CalendarRegistryModule + ListTools/dispatch gate), hermetic seam
# tests (env off omit/fail-closed, missing allowlist, fake success receipt),
# and private-smoke calendar qualification for allowlisted writable
# non-subscribed CalDAV (no On My Mac source required). Measured 3365 passed,
# 0 failed. FLOOR 3359 -> 3365.

# Calendar–Registry sprint W3 hatch (2026-07-20): private-smoke AUTO_APPROVE
# env is inert unless sync enable is on (+1 hermetic). FLOOR 3365 -> 3366.

# Calendar–Registry sprint W3 live decode (2026-07-20): Notion EVENT DATE often
# returns offset ISO datetimes with time_zone=null; store decode + manifest
# match accept empty IANA zone when absolute instants agree (CR97). Measured
# 3367 passed, 0 failed. FLOOR 3366 -> 3367.

# Calendar–Registry sprint W3 Last Synced At (2026-07-20): ledger anchors
# lastVerifiedAt to Notion read-back after sync-evidence write so minute-
# truncated date properties do not false-conflict (CR98). Measured 3368
# passed, 0 failed. FLOOR 3367 -> 3368.

# Closeout-A Voice Memo Reliability slice-2 (2026-07-20): SC2 unbound summary
# preflight, SC4 unique first-name resolve after exact miss, SC5 degraded
# sectioned preview, SC6 reminder mid-clause title gate, SC8 memory fallback
# policy default=review, SC1 commit receipt shape (+6 hermetic). Measured
# 3374 passed, 0 failed. FLOOR 3368 -> 3374.

# Closeout-A Views write Partial (2026-07-20): notion_view_create +
# notion_view_update (+ hermetic rejects / E2E count); disposable write smoke
# PASS for width/visible/wrap/frozen; capability matrix + W5B prep runbook.
# Rebased onto Voice Memo #113. Measured 3381 passed, 0 failed.
# FLOOR 3374 -> 3381.

# W5B cutover continuity (2026-07-21): BundleIDDefaultsMigration (+4) +
# ACL heal sentinel-first / access-group allowlist (+6). Measured 3391
# passed, 0 failed. FLOOR 3381 -> 3391.

# Remote governance continuity (2026-07-22): OAuth principal-keyed broker
# governance + routing-manifest markers survive Mcp-Session-Id churn; empty
# sub refused; clientInfo alone still fail-closed (PKT-1124). +6 hermetic.
# Measured 3397 passed, 0 failed. FLOOR 3391 -> 3397.

# Wake tunnel LaunchAgent heal (2026-07-23): didWake kickstarts
# com.kup.cloudflared-bridge (throttled; no "running=healthy" probe). +11 hermetic.
# Measured 3408 passed, 0 failed. FLOOR 3397 -> 3408.

# Calibrate APPLY 2026-07-23: git_status clean-but-behind (+1) + section unique
# prefix / ambiguous prefix (+2). Inject restore is Makefile-only (no harness).
# Measured 3411 passed, 0 failed. FLOOR 3408 -> 3411.

# Command Bridge visual-pass 2026-07-23: chrome metrics + open/close duration
# family (+1 net). Measured 3412 passed, 0 failed. FLOOR 3411 -> 3412.

# Registry find/list completeness F2 (2026-07-25): exhaustive find scan
# beyond the return cap + additive list has_more (+2 hermetic). Measured 3414
# passed, 0 failed. FLOOR 3412 -> 3414.

# Registry completeness hardening (2026-07-25): late-title and post-filter cap
# assertions folded into the F2 golden; repeated-cursor empty-cache/cached
# fallback and later-page cache fallback added (+2 hermetic). Exact list
# N-1/N/N+1 and max-500 boundaries are covered inside the existing list test.
# Measured 3416 passed, 0 failed. FLOOR 3414 -> 3416.
- 2026-07-27 · PKT-1212 B0 · `3416 → 3481` (+65): Stripe API-version/evidence transport, customer and invoice lifecycle, deterministic idempotency, indeterminate-effect recovery, and retained suite coverage.
- 2026-07-28 · CI child-process harness hardening · `3481 → 3482` (+1): bounded calendar-registry child waits, executable forced-stall regression, and corrected CI watchdog ordering. Measured 3482 passed, 0 failed.

- 2026-07-29 · Runtime Exposure hermetic projection seam · `3482 → 3504` (+22): restored 13 command/routing registry fixture tests that were incorrectly filtered by the live process-global exposure generation, and added 3 explicit nil/allow/deny surface tests. Measured 3504 passed, 0 failed with production exposure state present.
- 2026-07-30 · C0 runtime worktree ownership enforcement · `3504 → 3553` (+49): added durable canonical worktree claim/release, cross-process exclusion, pre-handler ownership permits, Git/file/shell/background/build/promotion target coverage, GNU Make final-directory semantics, static interpreter-stdin authorization, and fail-closed opaque `run_script`. Measured 3553 passed, 0 failed; C0 49/49.
- 2026-07-30 · C0 default-off containment · `3553 → 3556` (+3): added the exact-value runtime flag contract, conditional claim/release registration, and proof that disabled mutation dispatch neither invokes the ownership guard nor creates its claim database. Measured 3556 passed, 0 failed.
- 2026-08-06 · Mail inbox management · `3556 → 3602` (+46): identity-hardened mail_read/list/search, mail_mailboxes, advisory mail_triage + MailTriageSignals, mail_move/archive/mark with dryRun+verify receipts, guarded mail_trash (confirm DELETE + neverAutoApprove). staticFeatureModuleToolCount 217 → 223. Measured 3602 passed, 0 failed.
- 2026-08-06 · Mail inbox Red Team harden · `3602 → 3605` (+3): silence→needsReview (never archive-from-silence), batch archive/move confirm ARCHIVE|MOVE, account-scoped locators, mutated vs verified receipts + retry warning, planOnly alias. Measured 3605 passed, 0 failed.
- 2026-08-06 · Mail inbox Red Team rework · `3605 → 3613` (+8): drop noreply@ archiveHints; batch archive/move forces Request+neverAutoApprove (single-id stays Notify); Archive verify accepts All Mail aliases; succeeded=verify-confirmed only. Measured 3613 passed, 0 failed.
- 2026-08-14 · PKT-FETCH-SKILL-SLUG-ALIAS · `3613 → 3620` (+7): unique cached-slug alias for `fetch_skill` (+2 hermetic lookup tests). Remaining +5 already present on `9c73762` vs the 2026-08-06 floor stamp. Measured 3620 passed, 0 failed on feat/pkt-fetch-skill-slug-alias.
- 2026-08-14 · issues #125/#130 messages_send dispatch vs correlation · `3620 → 3624` (+4): `sent` is dispatch success; `verified`/`correlatedLocalRecord` stay chat.db-only; poll default 20×0.5s. Measured 3624 passed, 0 failed on fix/issue-125-130-messages-correlation.
- 2026-08-15 · issue #126 messages_send approval policy · `3624 → 3640` (+16): operator-selectable Always ask / session / trusted direct for ordinary local one-to-one sends; group, THREAD, remote, jobs, and raw chatNNN stay prompted. Measured 3640 passed, 0 failed on feat/issue-126-messages-approval-policy.
- 2026-08-15 · issue #138 registry create repair envelope · `3640 → 3652` (+12): `registry_create` returns state/entityUrl/applied/failed; relation preflight fails closed as none; updatePage distinguishes applied vs canonicalized vs rejected. Measured 3652 passed, 0 failed on feat/issue-138-registry-repair-envelope.
- 2026-08-17 · issue #160 registry_find UUID normalize · `3666 → 3744` (+78): compact and hyphenated Notion UUIDs compare equal in `RegistryReader.valueMatches` (shared by `registry_find` and `registry_resolve_and_update`); +2 hermetic. Remaining +76 already green on main `55236fa` (including #163/#168) with the floor still at 3666. Measured 3744 passed, 0 failed on feat/issue-160-registry-uuid-normalize.
- 2026-08-17 · voice-memo geography + Next action: · `3744 → 3745` (+1): unique geographic 2-token slices of a longer project title no longer attach; `Next action:` and transcript `Next:` strip to the physical checkbox. Measured 3745 passed, 0 failed on feat/voice-memo-place-and-next-action.
- 2026-08-17 · command insert Chromium pointer-focus · `3745 → 3747` (+2): AXWebArea/AXGroup click-target math so Cursor/Chrome composers receive unicode typing after the palette snapshot. Floor raised with the hermetic tests; live Cursor smoke remains operator-ceiling.
- 2026-08-17 · command insert AX read-back · `3747 → 3751` (+4): AX set success is not insert success; unmutated AXValue falls through to click-then-type. Measured 3751 passed, 0 failed on feat/command-insert-ax-readback.
- 2026-08-18 · v4.0.4 detached worktree_claim · `3759 → 3761` (+2): claim `branch: "(detached)"` with `baseSHA = HEAD`; named-branch claims on detached HEAD still fail `worktree_identity_changed`. Measured 3761 passed, 0 failed on fix/v4.0.4-hardening.
- 2026-08-19 · local 4.0.5 insert + CB-2 · `3761 → 3763` (+2): Electron unicode attaches on keyDown; C1 single-line search truncates name to 80 and leaves body empty. Measured 3763 passed, 0 failed on feat/v405-local-insert-ui.
- 2026-08-21 · ChatGPT insert ghost + Chrome unicode · `3763 → 3767` (+4): Cursor caret-origin composer hint, ChatGPT.app Codex Chromium `Message ChatGPT` replace, Chrome `.keyDownAnsiA`. Measured 3767 passed, 0 failed on feat/v405-local-insert-ui.
- 2026-08-21 · U2 governed Node tests · `3767 → 3775` (+8): owner-bound trusted node:test imports with fixed permissions, bounded output/timeout, and post-run identity revalidation. Measured 3775 passed, 0 failed on codex/u2-governed-node-test-v2.
