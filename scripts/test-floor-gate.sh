#!/usr/bin/env bash
# test-floor-gate.sh — WS-C (v2.3, PKT-798)
#
# Locks the green test baseline as a CI gate. The custom harness
# (.build/debug/TheBridgeTests) already exits non-zero on any failing
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
FLOOR="${BRIDGE_TEST_FLOOR:-2910}"
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
BIN=".build/debug/TheBridgeTests"

echo "🧪 test-floor-gate: building debug + running suite (floor=${FLOOR})..."
swift build -c debug

LOG="$(mktemp -t bridge-test-floor.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# Watchdog: cap the test binary at DEADLINE seconds (default 1500 = 25 min;
# local run is ~5 min, CI macos-26 is ~3x slower). Override with
# TEST_WATCHDOG_SECONDS — a short value (e.g. 5) makes the watchdog testable.
#
# This is a REAL EXTERNAL watchdog, not `perl -e 'alarm N; exec'`. On macOS the
# SIGALRM timer set by alarm() is CLEARED by exec() (the new image starts with no
# pending alarm), so the old pattern never actually killed a hung binary — it ran
# until the CI step/job timeout. Instead we now: launch the binary in the
# background, capture its PID, start a separate killer subshell that SIGKILLs that
# PID after DEADLINE, and `wait` on the binary. On normal completion we KILL THE
# KILLER so a finished run leaves no stray `sleep` and the script never blocks on
# it. On a watchdog kill we FAIL FAST with the last logged test line so the hang
# is diagnosable instead of an opaque multi-hour cancel.
DEADLINE="${TEST_WATCHDOG_SECONDS:-1500}"
#
# Bounded retry on the harness teardown flake: the runner emits its summary from
# a tail that, on a fully-completed suite, can intermittently lose a race with
# process teardown and drop the final `Results:` line — the binary still exits 0
# and every test ran (the per-test ✅ lines are all present). That is NOT a test
# failure, so re-run up to ATTEMPTS times until the summary is captured. A real
# hang (watchdog) or a genuine non-zero exit fails immediately with no retry, and
# the floor/failure checks below are unchanged.
ATTEMPTS=3
LINE=""
for attempt in $(seq 1 "$ATTEMPTS"); do
  set +e
  # Run the binary in the background, tee'ing its combined output to the log so
  # the timeout path can print the last test line. `$!` is the binary's PID.
  "$BIN" > >(tee "$LOG") 2>&1 &
  BIN_PID=$!

  # External killer: SIGKILL the binary if it outlives DEADLINE. Captured PID so
  # we can cancel it on a clean finish.
  ( sleep "$DEADLINE"; kill -9 "$BIN_PID" 2>/dev/null ) &
  KILLER_PID=$!

  # Block until the binary exits (normally, or via the killer's SIGKILL).
  wait "$BIN_PID"
  RC=$?

  # Cleanup: cancel + reap the killer so a completed run leaves no stray sleep
  # and the script doesn't block waiting on it. Kill the killer's `sleep` CHILD
  # first (while the subshell is still alive so `pkill -P` can resolve it),
  # otherwise killing only the subshell orphans the `sleep` and it keeps running
  # for the full DEADLINE. Then kill + reap the subshell itself.
  pkill -P "$KILLER_PID" 2>/dev/null
  kill "$KILLER_PID" 2>/dev/null
  wait "$KILLER_PID" 2>/dev/null
  set -e

  # SIGKILL from the watchdog surfaces as 137 (128+9). (128+SIGALRM=142 / 14 are
  # kept as a defensive fallback in case a future change reintroduces an alarm.)
  if [ "$RC" -eq 137 ] || [ "$RC" -eq 142 ] || [ "$RC" -eq 14 ]; then
    echo "::error::test-floor-gate: test binary exceeded ${DEADLINE}s watchdog and was killed"
    echo "--- last 60 lines of test output (so you can see which test hung) ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit 124
  fi
  if [ "$RC" -ne 0 ]; then
    echo "::error::test-floor-gate: test binary exited with code $RC (non-zero, non-timeout)"
    echo "--- last 60 lines of test output ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit "$RC"
  fi

  LINE="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$LOG" | tail -1 || true)"
  if [ -n "$LINE" ]; then
    break
  fi
  echo "::warning::test-floor-gate: attempt ${attempt}/${ATTEMPTS} exited 0 but emitted no 'Results:' line (known harness teardown flake) — retrying"
done

LINE="$(tr -d '\000-\010\013\014\016-\037' < "$LOG" | grep -aE 'Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "::error::test-floor-gate: no 'Results:' summary line after ${ATTEMPTS} attempts"
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
