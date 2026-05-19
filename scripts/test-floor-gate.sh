#!/usr/bin/env bash
# test-floor-gate.sh — WS-C (v2.3, PKT-798)
#
# Locks the green test baseline as a CI gate. The custom harness
# (.build/debug/NotionBridgeTests) already exits non-zero on any failing
# test, but that does NOT catch tests being silently deleted or disabled —
# a suite that shrinks from 710 → 600 with 0 failures would otherwise pass
# CI unnoticed. This gate fails the build if the passing count drops below
# the floor OR any test fails.
#
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
# 9700) instead of a hardcoded 9700, and the NotionBridgeTests target now
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
# only — NotionBridge/Modules/Commands/MentionResolver.swift +
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
set -euo pipefail

FLOOR="${BRIDGE_TEST_FLOOR:-1162}"
BIN=".build/debug/NotionBridgeTests"

echo "🧪 test-floor-gate: building debug + running suite (floor=${FLOOR})..."
swift build -c debug

LOG="$(mktemp -t bridge-test-floor.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

set +e
"$BIN" | tee "$LOG"
set -e

LINE="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "::error::test-floor-gate: could not find the 'Results:' summary line in test output"
  exit 2
fi

PASSED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
FAILED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: [0-9]+ passed, ([0-9]+) failed.*/\1/')"

if [ "$FAILED" -ne 0 ]; then
  echo "::error::test-floor-gate: ${FAILED} failing test(s) — green bar broken"
  exit 1
fi

if [ "$PASSED" -lt "$FLOOR" ]; then
  echo "::error::test-floor-gate: passed=${PASSED} is BELOW floor=${FLOOR} — tests were removed or disabled. If this drop is intentional, lower the floor in scripts/test-floor-gate.sh in the same change and record why."
  exit 1
fi

echo "✅ test-floor-gate OK: passed=${PASSED} >= floor=${FLOOR}, failed=0"
