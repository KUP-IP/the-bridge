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
    public static let marketing = "4.0.2"

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
    /// v3.8.3: 61 → 62 — Memory Hub Phase 0 (trust + Process cockpit + guardrails) +
    ///   PKT-MEM-114 progressive AI memo titles (intent-led heuristic / Ollama / cloud
    ///   tiers, edited-pinned cache, idle sweep) + standing-orders initialization
    ///   contract. staticFeatureModuleToolCount unchanged (187 — titles add no tools).
    /// v3.8.3: 62 → 63 — on-device smoke fix: isDefaultName now humanizes the real
    ///   "YYYYMMDD HHMMSS <hexid>" memo filename (the hex suffix was leaking raw ids
    ///   into the cockpit/Inbox). Marketing unchanged; build-only re-install.
    /// v3.8.4: 63 → 64 — Voice Curator FRONTIER-FIRST parse provider chain (agent→cloud→
    ///   local→heuristic, availability-gated graceful degradation + plan provenance) +
    ///   cloud whole-transcript structured parse (4000-char cap now local-only) + cockpit
    ///   UX remediation (full scrollable transcript/title, on-select transcribing state,
    ///   human labels, commit-value preview, provenance badge) + a durable cloud-send
    ///   activity receipt. staticFeatureModuleToolCount unchanged (187). test-floor 2602 → 2667.
    /// v3.8.5: 64 → 65 — PKT-932 Sparkle staged-update triage: fix fragile delegate cast in
    ///   AdvancedSection + operator triage doc (docs/bridge/sparkle-triage.md). Merged post-v3.8.4
    ///   tag during release integration; no new MCP tools. test-floor unchanged (2667).
    /// v3.9.0: 65 → 66 — Unified Memory Wave 3 (PKT-MEM-115): handshake inject settings,
    ///   fetch_skill scopedMemory appendix (post-cache), Memory → Agent pin/forget + provenance.
    ///   test-floor 2667 → 2682 (+15). staticFeatureModuleToolCount unchanged (187).
    /// v3.9.1: 66 → 67 — Memory Hub Foundation (PKT-MEM-115): D12 ACTIVITY taxonomy (22
    ///   event types + evidenceId), D8/D9/D13 INBOX disposition (DismissScope/Result/
    ///   TrashResult + NSWorkspace.recycle), D35/D41 memory_update MCP tool (notify tier,
    ///   protectedFields guard), D6/D17/D23/D36/D42 PROCESSING provider profiles (9 types:
    ///   ProviderFamily/Capability/CredentialReference/CapabilityProfile/FallbackChain/
    ///   ProfileConfig/ValidationError/SyntaxValidator/TestResult), D15/D19/D20/D43
    ///   KeepReviewModel (KeepReviewStatus + KeepReviewMetadata + KeepSchemaContract +
    ///   KeepRequiredSchemaField). staticFeatureModuleToolCount 187 → 188. test-floor
    ///   2682 → 2744 (+62).
    /// v3.9.2: 67 → 68 — Ollama defaults + registry create-body + standing orders seed:
    ///   Ollama routing-vs-summarization defaults split (Qwen generate think:false + tuned
    ///   context, PR #67); registry_create initializes page bodies from markdown in one
    ///   call (PR #66, +7 tests); bundled v7.0.2 standing-orders doctrine seeds fresh
    ///   installs via seedIfEmpty (PR #68, PKT-1057, +3 tests); close-agent AGENT_FEEDBACK
    ///   path hygiene fix. test-floor 2755 → 2783 (2765 measured immediately after the
    ///   v3.9.2 merge; +18 net from PR #69/#70 commands + wave3 FB landed same window).
    ///   Backfilled 2026-07-02 per focus-keepr reflow — see CHANGELOG.md for the
    ///   original entry (this ladder had skipped straight 3.9.1 → 3.9.4).
    /// v3.9.3: 68 → 69 — Memory Hub opt-in Understand + summary-first keeps: memo select
    ///   is inspect-only (voice_memo_get understand:false); Process locally / Process with
    ///   cloud buttons run explicit Understand with activity-phase receipts (W1); intent
    ///   inspector expands intent tags to full write preview (W2); structured summary +
    ///   action items for Notion keeps, transcript stays UI-only (W3); HITL scenario
    ///   catalog + voice scripts + friction log under docs/operator/live-evidence/.
    ///   test-floor 2857 → 2863 (+6 MemoryProcessInspectUnderstandTests + opt-in AX).
    ///   Backfilled 2026-07-02 per focus-keepr reflow — see CHANGELOG.md for the
    ///   original entry.
    /// v3.9.4: 69 → 70 — six-packet Memory Hub / registry batch (PKT-MEM-131–136):
    ///   registry_find row-resolution swap (131), pre-write transcript-overlap guard
    ///   closing an agent-commit gap (132, D49), multi-intent-per-memo agent-mode docs
    ///   (133), UI↔agent live processing sync via a dedicated notification channel
    ///   (134), new general-purpose registry_resolve_and_update MCP tool (135),
    ///   comment disposition (idea|reflow) + idea-thread ledger built on it (136).
    ///   staticFeatureModuleToolCount 199 → 200. test-floor 2917 → 2993 (+76).
    /// v3.9.4: 70 → 71 — on-device smoke fix (found via live MCP demo of PKT-MEM-136):
    ///   voice_memo_commit's real argument parser never wired a top-level "body" arg
    ///   into intent.body — every real MCP caller of intentKind=comment silently fell
    ///   back to the title path. Schema + handler fix, no new tool. Marketing unchanged;
    ///   build-only re-install. test-floor 2993 → 2994.
    /// v3.9.5: 71 → 72 — Notion Page Icon Write Support: notion_page_create /
    ///   notion_page_update both accept an optional single-emoji `icon` parameter
    ///   (NotionClient.createPage/updatePage gain a trailing icon: String? = nil that
    ///   merges Notion's {"type":"emoji","emoji":"…"} shape into the request body;
    ///   omitted ⇒ byte-identical to prior behavior). Pass-through only, no new
    ///   Bridge-side validation (Notion's API is the validator), matching the existing
    ///   extractIconEmoji read-side precedent. REVIEW-FIRST packet, live-verified
    ///   against real Notion (4/4: create+icon, update+icon, create-no-icon and
    ///   update-no-icon regression, all confirmed via live read-back). No new tool —
    ///   staticFeatureModuleToolCount unchanged (200). test-floor unchanged (2994).
    /// v3.9.6: 72 → 73 — self-heal the bridge-env LaunchAgent boot-order race
    ///   (found live via a real restart): the RunAtLoad LaunchAgent that injects
    ///   BRIDGE_ENABLE_HTTP + WorkOS/cloud env via `launchctl setenv` sometimes loses
    ///   the boot-order race against Bridge's own relaunch (login item / Resume),
    ///   leaving connectorAuth nil for that process's whole life — every real
    ///   connector bearer token (ChatGPT, Claude.ai) rejected as structurally invalid,
    ///   surfacing as a confusing "reconnect" error. New CloudEnvSelfHeal.swift
    ///   detects the signature at launch (cloud access enabled + BRIDGE_ENABLE_HTTP
    ///   absent + not already attempted) and self-heals: kick the LaunchAgent, wait
    ///   for this process's own pid to actually exit, relaunch once (loop-guarded),
    ///   done. No-op for the default cloud-off path. +9 tests. staticFeatureModuleToolCount
    ///   unchanged (200). test-floor 2994 → 3003.
    /// v3.9.6: 73 → 74 — build-only, two bundled backlog packets (internal DX +
    ///   a routing bug fix, no new user-facing marketing capability, matching the
    ///   `fields`-param packet's precedent). (1) Notion/Registry Tool Ergonomics
    ///   Pass (packet 392cbb58889e811abe7ef9714df1dc92): notion_blocks_append gains
    ///   a pageId+markdown shorthand alongside blockId+children; registry_update
    ///   gains an optional appendKeys merge mode reusing registry_resolve_and_update's
    ///   existing append logic; notion_comment_create accepts `content` as an alias
    ///   for `text`; notion_query accepts `parentId` as an alias for `dataSourceId`;
    ///   notion_page_create verifies children materialization post-create and
    ///   auto-repairs via notion_blocks_append if the API accepted the page but
    ///   produced zero blocks; the stale "project-keepr" binding in
    ///   MemoryRoutingScopeMap.swift removed (project-keepr was retired/renamed to
    ///   focus-keepr, not a distinct live specialist). +24 tests. (2) fetch_skill
    ///   Archive-vs-Canonical Matcher Confidence Fix (packet
    ///   392cbb58889e81189569ff4481764375): fetch_skill's SkillIntentScorer could
    ///   let an archived reference-material child page (e.g. "sk close agent ·
    ///   Archive") outrank its live canonical parent on raw keyword score alone —
    ///   live-reproduced this session. New SpecialistFilter.isArchived(title:)
    ///   general word-boundary detector + a relative post-scoring deprioritization
    ///   pass (never a hard exclude — an archived page with no non-archived sibling
    ///   still resolves normally; an archived page never wins the confident slot
    ///   over a live peer). Disambiguation behavior for genuinely-live multi-specialist
    ///   candidates (e.g. focus-keepr's own children) explicitly regression-tested
    ///   unaffected. +8 tests. staticFeatureModuleToolCount unchanged (200) — both
    ///   packets extend existing tools' parameters, add no new tool names.
    ///   test-floor 3003 → 3035 (24 + 8, reconciled by hand at merge time since
    ///   both branches independently computed their target off the same pre-merge
    ///   3003 baseline).
    /// v3.9.7: 74 → 75 — marketing bump (real user-facing GitHub-issue fixes +
    ///   reliability, not build-only DX like build 74). Voice Memo Commit Quality
    ///   Gate + Reliability (packet 392cbb58889e81198c01f719a4a58675, REVIEW-FIRST,
    ///   operator-approved): new VoiceMemoContentQualityGate.swift — an explicit,
    ///   reviewable rule (>=8 words AND <40% disfluency-token ratio, below either
    ///   ⇒ rejected) wired into executeMemoryKeep before any Notion write, so a
    ///   filler/fragment summary can never reach markedProcessed:true (closes
    ///   GitHub #81 — verified against all 3 real repro memos). Promoted the
    ///   previously-undiscoverable fields.summary passthrough to a first-class
    ///   top-level `summary` schema parameter on voice_memo_commit. New
    ///   VoiceMemoStageTimeout.swift wraps transcribe/understand/execute stages in
    ///   both the batch and commit(args:) paths so voice_memo_process always
    ///   terminates in {done, error, review-queue}, never an indefinite hang
    ///   (closes GitHub #73). Voice-router client alias (PKT-MEM-127): entityKey
    ///   was already correctly "contact" — the real gap was that entityHints never
    ///   recognized the word "client" at all; added trigger + extraction pattern,
    ///   live-confirmed against the real "my client, Greg Flachek" transcript.
    ///   Every new code path tested by driving the real MCP args:-parsing entry
    ///   points, not hand-built models, per this session's own PKT-MEM-136 lesson.
    ///   +19 tests. staticFeatureModuleToolCount unchanged (200). test-floor
    ///   3035 → 3054.
    /// v3.9.7: 75 → 76 — build-only hotfix. Live verification against the real
    ///   running build-75 server (not just the harness) caught the just-shipped
    ///   client-alias pattern producing a real false positive: build 75's pattern
    ///   was built from a secondhand PARAPHRASE of the GH #73 transcript ("my
    ///   client, Greg Flachek") rather than the verbatim text — the real memo
    ///   says "Greg, Flachek, my client, and..." (name FIRST), so the
    ///   forward-only pattern matched "client, and..." and captured "And" as the
    ///   name. Rewrote with two narrower forms requiring a real `\bclient\b` word
    ///   boundary (so "clients" plural never substring-matches) and a TRUE
    ///   capitalized first letter on the captured name (overriding the pattern's
    ///   own case-insensitive compile option), so a lowercase filler word can
    ///   never be captured as a name — a second false positive ("of" from "some
    ///   of my clients") was caught by a dedicated regression test written during
    ///   this very fix and corrected before shipping, not after. +1 test.
    ///   staticFeatureModuleToolCount unchanged (200). test-floor 3054 → 3055.
    /// v3.9.8: 76 → 77 — marketing bump. Ships v3.9.4-v3.9.7 (developed/installed
    ///   locally but never tagged) bundled with this session's work: Wave 1 broker
    ///   (session governance + remote control-plane blocklist) + strict
    ///   connector-scope allowlist (ConnectorAuthContext.strictScopes default
    ///   false → true — remote/cloud callers now allowlisted to 36 of 202 tools,
    ///   full local parity unaffected), two notion_* schema required-field
    ///   accuracy fixes, the install clean-tree/branch guard, the bg_process_*
    ///   hint-text fix, plus the previously-unshipped Memory Settings 3-tab
    ///   redesign + registry/fetch_skill fields projection + an AX-crash fix. Full
    ///   detail in CHANGELOG.md. staticFeatureModuleToolCount 200 → 201
    ///   (doctrine_sync). test-floor 3108 → 3118.
    /// v3.9.9: 77 -> 78 -- full Claude Connectors parity restored. Reverts
    ///   v3.9.8's one-day-old ConnectorAuthContext.strictScopes default
    ///   (false -> true) back to false: an authenticated connector token once
    ///   again reaches every tool, gated only by the per-tool SecurityGate at
    ///   dispatch, since WorkOS/AuthKit issues scope-less tokens and the
    ///   ConnectorScopeGate allowlist would otherwise deny most of the
    ///   catalog. The v3.9.8-era 36-tool allowlist remains available --
    ///   ConnectorAuthContext(strictScopes: true) -- as an opt-in ceiling.
    ///   Independent of this flag and unaffected: ToolRouter's Wave 1 broker
    ///   (remote control-plane blocklist for shell/applescript/computer/
    ///   credential + config-write tools, governed-session requirement) is
    ///   origin-based, not scope-based, and stays fully active. +1 test
    ///   (RemoteOAuthBearerTests.swift: split the old "default strictScopes"
    ///   assertion into an explicit strictScopes:true regression test plus a
    ///   new test asserting the false default). staticFeatureModuleToolCount
    ///   unchanged (201). test-floor 3118 -> 3126.
    /// v3.9.9: 78 -> 79 -- build-only fix (marketing unchanged; operator decision
    ///   2026-07-10 to reserve 4.0.0 for a deliberate sale-ready release rather
    ///   than consume it on a routine internal bugfix, even though it's the
    ///   mechanical next version under the roll-at-9 rule). bridge_initialize's
    ///   defaultContextProvider hardcoded connectionState:"local" for every
    ///   caller regardless of actual origin -- live-caught: a remote/cloud
    ///   session called bridge_initialize, was told "local"/capabilityState
    ///   FULL, then had shell_exec refused moments later with origin:"remote"
    ///   by RemoteControlPlanePolicy. Fixed to read the same
    ///   ToolDispatchContext.current.origin the Wave 1 broker already uses:
    ///   .remote -> "online" (existing bridge_status vocabulary; already
    ///   classifies FULL via capabilityState's default case, no downstream
    ///   logic change), .local/no-ambient-context -> "local", unchanged. +2
    ///   tests. staticFeatureModuleToolCount unchanged (201). test-floor
    ///   3126 -> 3128.
    /// v3.9.9: 79 -> 80 -- build-only remote connector parity fix. The Wave 1
    ///   origin-based control-plane block now defaults OFF so authenticated,
    ///   governed ChatGPT and Claude sessions can reach shell/applescript/
    ///   computer/credential and config-write tools through their normal
    ///   SecurityGate tiers. The hard block remains an explicit operator opt-in.
    ///   Remote governed-session enforcement is split onto its own default-ON
    ///   preference so full tool parity does not weaken initialization policy.
    ///   +3 regression tests. staticFeatureModuleToolCount unchanged (201).
    ///   test-floor 3128 -> 3131.
    /// v3.9.9: 80 -> 81 -- build-only merge batch, no marketing bump (same
    ///   reserve-4.0.0-for-sale-ready operator decision as 78->79 applies).
    ///   Landed: PR #87 (Routing Integrity Layer / PKT-1094 -- per-tool
    ///   skill-governance bindings + manifest-fetch dispatch gate, reconciled
    ///   with the Wave 1 broker's origin gates); PR #99 (PKT-1116 --
    ///   build-provenance stamping + Accessibility/CloudStatus/Session
    ///   diagnostics); PR #101 (this branch's own build-80 remote
    ///   control-plane default flip, re-reconciled onto post-PR-#87
    ///   ToolRouter after #99 landed first -- a real three-way test-floor
    ///   union, not a simple rebase); plus 4 doc-only corrections (#97 cloud-
    ///   oauth-readiness record, #98 counter-collision CI guard, #100 /health
    ///   tunnel-scoping, #102 NL-2 row 18 job/snippets locality).
    ///   staticFeatureModuleToolCount 201 -> 202 (PR #99's audit_recent).
    ///   test-floor 3131 -> 3149 (final reconciled count across all three
    ///   independent test additions on the shared 3128 base: +3 Wave1Broker,
    ///   +8 PKT-1116, +10 RoutingIntegrityLayer).
    /// v4.0.0: 81 -> 82 -- first major under the roll-at-9 rule (3.9.9→4.0.0).
    /// v4.0.1 candidate: 82 -> 83 -- post-v4 reliability and UX batch; no
    ///   tag or GitHub release was published before v4.0.2 superseded it.
    /// v4.0.2 C1 containment: 82 -> 84 -- build 83 was used by the superseded
    /// v4.0.1 release candidate. Contains THREAD Messages before side effects,
    /// removes runtime approval inference, requires one explicit ordinary-send
    /// service, removes fallback, and reports correlation-only local evidence.
    ///   Sale-ready V4 cut: W5B bundle-id cutover + continuity, Notion Views
    ///   write tools, Wave A Settings UI-ITER polish, license public-key +
    ///   WorkOS OAuth bake secrets present for release.yml inject. Floor 3391.
    public static let build = "84"

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
    /// Memory Hub trust (2026-06-24): +1 memory_forget; +2 voice_memo_get + voice_memo_commit.
    /// 183 + 3 = 186.
    /// Packet Runner v1 (FR-1/§8.3, merged from main 2026-06-25): + registry_hydrate
    ///   (packet-registry-v1 one-hop envelope). 186 + 1 = 187.
    ///   (PKT-MEM-106 Phase 0 added internal types only — no new MCP tools.)
    /// Memory Hub UX Reconstruction (D35/D41, 2026-06-27): + memory_update
    ///   (in-place AGENTS field update tool). 187 + 1 = 188.
    /// PKT-1061 Commands MCP (2026-06-29): +6 commands_* tools (list/get/search/create/update/delete). 188 + 6 = 194.
    /// Wave 3 FB (2026-06-29): + bridge_focus_settings (automation family). 194 + 1 = 195.
    /// PKT-1065A (2026-07-01): + bridge_initialize (canonical init-core handshake +
    ///   persisted receipt; joins the existing standing_orders family, no new family). 197 + 1 = 198.
    /// PKT-1041 registry_find (2026-07-01): + registry_find (convergent resolve-before-write
    ///   lookup — read-only predicate match over the registry_list read-through/offline path).
    ///   Branched independently off pre-1065A main (197 + 1 = 198 in isolation); reconciled at
    ///   merge onto the already-integrated 198 (which already carries 1065A's bridge_initialize).
    ///   198 + 1 = 199.
    /// PKT-MEM-135 registry_resolve_and_update (2026-07-02): + registry_resolve_and_update
    ///   (find+get+update in one call — resolve a row by registry_find-identical predicate
    ///   matching, append-merge configured fields, then write; joins the existing `registry`
    ///   family, no new family). 199 + 1 = 200.
    /// Bridge Evolution W1 broker: + doctrine_sync (request-tier single writer
    ///   for doctrine-core.md, joins existing standing_orders family). 200 + 1 = 201.
    /// PKT-1116 Observability: + audit_recent (read-only session-family audit
    ///   projection; no new family). 201 + 1 = 202.
    /// PKT-1123 Reconnect Observability: + connections_reset (request-tier,
    ///   local-only governed broker-session rebind; joins connections family).
    ///   connections_list also gains redacted runtime/session telemetry. 202 + 1 = 203.
    /// PKT-1120 Tool Ergonomics (2026-07-14): +2
    ///   (voice_memo_settings_get + voice_memo_settings_set; voice family).
    ///   203 + 2 = 205.
    /// Notion Views read + comment reply (2026-07-15): +2
    ///   (notion_views_list + notion_view_get; notion family). Comment path
    ///   gains discussionId reply (no new tool). 205 + 2 = 207.
    /// Bridge v4 stabilization Wave 1 (2026-07-17): +1 calls_recent.
    ///   207 + 1 = 208.
    /// Closeout-A Views write (2026-07-20): +2
    ///   (notion_view_create + notion_view_update; notion family). 209 + 2 = 211.
    public static let staticFeatureModuleToolCount = 212

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
    /// PKT-1061 (2026-06-29): + commands family = 31.
    /// Bridge v4 stabilization Wave 1 (2026-07-17): + calls family = 32.
    public static let staticFeatureModuleFamilyCount = 32
}
