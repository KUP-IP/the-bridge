# The Bridge — Settings Redesign Spec (IMPLEMENTED 2026-06-10)

> Status: **IMPLEMENTED** on branch `feat/settings-redesign`. Foundation (PKT-A, nav 10→7)
> + 7 per-page redesigns (PKT-B…H) + Wave-3 relocations (License→Security, launch-at-login/
> check-for-updates→Advanced) + dead-code cleanups all landed and verified: full suite
> **2024 passed / 0 failed**, release strict-concurrency build clean, bundle packaged.
> Commit range `9b28975` (spec + audits) … `1adf5b1` (orphan sweep). Started + shipped 2026-06-10.
> Retained as the execution SSOT of record. Items marked "deferred" below were validated as
> already-satisfied in Wave 2 (version single-source, port→Connection) or out of scope
> (full Stripe removal = separate tool-surface-pruning effort).

## Current sidebar (SettingsWindow.swift L115–124) — 10 sections
Standing Orders · Commands · Connections · Remote Access · Skills · Permissions · Credentials · Tools · Jobs · Advanced

## Target sidebar — 7 sections (Batch 1 — LOCKED 2026-06-10)
| # | Section | Change |
|---|---------|--------|
| 1 | **Orders** | rename from "Standing Orders" (display only) + **absorb Commands** as a sub-area |
| 2 | **Skills** | unchanged (reordered up) |
| 3 | **Jobs** | unchanged (reordered up) |
| 4 | **Tools** | unchanged |
| 5 | **Security** | **merge** Credentials + Permissions → posture header + tabs (Vault \| Gates) |
| 6 | **Connection** | **merge** Connections + Remote Access → status strip + stacked (Local / Remote); singular name |
| 7 | **Advanced** | unchanged |

Net: 10 sections → 7. Commands folds into Orders; Credentials+Permissions→Security; Connections+Remote Access→Connection.

## Spec items + refinements

### S1 — Rename "Standing Orders" → "Orders" + absorb Commands [LOCKED]
Snappier. Refinement: keep a one-line subtitle so the meaning stays unambiguous (e.g. "Standing orders & operating doctrine"), since "Orders" alone can read as commerce. The on-disk path (`standing-orders/`), MCP `standing_orders_*` tools, and the constitution term stay as-is — this is a **display rename only** (don't churn the data layer / SSOT term).
**Commands fold-in (Q1=merge):** Orders hosts two areas — the standing-orders doctrine editor AND the Commands surface (favorite-slot palette / Command Bridge config). Likely a two-tab page (Orders | Commands) or a doctrine page with a Commands section. The CommandStore data layer + the Command Bridge popup stay; only the Settings entry point moves under Orders.

### S2 — Reorder: Orders → Skills → Jobs → Tools → Security → Connection → Advanced
Reads as a conceptual flow: *who the agent is* (Orders) → *what it knows* (Skills) → *what runs on a schedule* (Jobs) → *what it can do* (Tools) → *what's gated/stored* (Security) → *how agents reach it* (Connection) → *everything else* (Advanced). Note: this replaces the prior "most-visited-first" ordering principle with "conceptual flow." → confirm in Q4.

### S3 — "Security" = Credentials + Permissions (merge)
Both are security-posture surfaces, so the merge is sound. Refinement: make Security a real posture page, not two stacked lists —
- a header strip: Touch-ID-to-reveal status · # stored credentials · tool counts by gate tier (open/notify/confirm).
- two areas: **Vault** (credentials) and **Gates** (per-tool permission tiers + module-scoped Always-Allow + revoke).
- Layout [LOCKED Q2=tabs]: posture header on top + **two tabs (Vault | Gates)**.

### S4 — "Connection" = Connections + Remote Access (merge)
Remote Access is just a connection *mode*, so folding it in is right and dovetails with the "single way agents reach the Bridge" thesis. Refinement: one page with —
- **Local clients**: the loopback MCP endpoint(s) + per-client config (desktop, Claude Code) — incl. the loopback-bearer model from PKT-810.
- **Remote access**: the cloud connector (the `mcp.kup.solutions/mcp` URL, OAuth, enable state — currently `comingSoon` for Model A).
- a live **status strip**: who's connected, online/offline, last-seen.
- Layout [LOCKED Q3=stacked]: **status strip on top, then Local clients, then Remote access** (one scroll). Name: **singular "Connection"** per operator.

### S5 — Ordering principle [LOCKED Q4=conceptual flow]
Use the exact order Orders → Skills → Jobs → Tools → Security → Connection → Advanced. Conceptual flow, not most-visited-first.

## Decisions log
- 2026-06-10 Batch 1 LOCKED: Q1 Commands→merge into Orders · Q2 Security→posture header + tabs (Vault|Gates) · Q3 Connection→status strip + stacked (Local/Remote), singular name · Q4 order→conceptual flow (exact). Rename Orders = display-only (data layer/SSOT untouched).

---

## Batch 2 — Density & chrome (gathering)

### B2.0 — Global density principle
Operator: the app wastes space; merging pages demands a more compact layout. Codify a **density tenet**: tighten vertical rhythm + row padding across all pages, with a **legibility floor** so "compact" never becomes "cramped" — text ≥ 11–12px, interactive targets keep a minimum hit area, truncate-with-reveal instead of shrinking. Applies everywhere, hardest on the merged Security/Connection/Orders pages where two surfaces now share one.

### B2.1 — Tools page: responsive 2-column groups
Operator: the group toggle is too wide; want two tool categories side by side in a compact toggle, responsive back to 1 column below a width threshold. Compact each row's Icon · Title · Description · Control toggle · Security-tier button.
Refinements:
- `LazyVGrid`, **group-level** 2 columns (two ModuleGroup cards side by side), collapse to 1 below ~640–680px container width. (Cap at 2 vs allow 3 on ultra-wide → Q1.)
- Compact group card: header = icon + title + master toggle + tool-count; dense tool list inside.
- Per-tool row: small leading icon · title · **1-line truncated description w/ hover/tooltip reveal** (description is the width hog — see Q2) · trailing compact toggle · **tier control as a cycling chip** (Open→Notify→Confirm, color-coded, tap-to-cycle) replacing the wide button. Reuses `ToolTierResolution` + `tierOverrides` (don't change the persistence/notification contract from PKT-976/the restored gate control).

### B2.2 — Title bar: minimalist, no divider
Current `BridgeTitleBar`: 44px, centered "The Bridge › {section}", **0.5px hairline overlay at bottom** (the divider to remove).
Refinements:
- Remove the bottom hairline → seamless into content.
- 44px height is partly load-bearing (clears the native traffic lights). Reclaim feel by **left-aligning** the title beside the traffic lights and trimming height toward ~38px rather than centered-44.
- Breadcrumb value is low with a flat 7-section nav → drop the "The Bridge ›" prefix, show just the section name? → Q3.

### B2.3 — Foot bar: integrated
Current `BridgeFootBar`: 30px, distinct `chipFill` background, **0.5px hairline overlay at top**, "The Bridge … {version} ●".
Refinements:
- Drop the top hairline AND the separate `chipFill` so it blends with the canvas (no slab).
- Keep slim version + status dot, OR remove the bar entirely and relocate version/status into a title-bar corner to free the bottom for content → Q4.

## Decisions log (Batch 2 — LOCKED 2026-06-10)
- B2.1 Tools grid: **cap at 2 columns, collapse to 1** below ~640–680px. Description **1-line truncate + hover/tooltip reveal**. Tier control → **cycling chip** (Open→Notify→Confirm). Reuse ToolTierResolution/tierOverrides contract.
- B2.2 Title bar: **section name only, left-aligned** beside traffic lights; **remove bottom hairline**; trim toward ~38px.
- B2.3 Foot bar: **keep slim + integrated** — remove top hairline + separate chipFill so it blends; keep version + status dot.
- B2.0 Global: density tenet with a **legibility floor** (text ≥ 11–12px, min hit areas, truncate-with-reveal over shrink).

---

# Per-page implementation specs (design-critique sub-agents — 2026-06-10)
Full reports: `docs/operator/design-audits/{chrome,orders,skills,jobs,tools,security,connection,advanced}.md`

## CROSS-CUTTING (systemic — every page)
- **The shared `BridgeSettingsSectionHeader` is dead** — its "one header, 5 callers" presets exist but NO section uses them; every page hand-rolls an oversized hero (50×50 orb, 18–22pt re-printed title). With the titlebar now carrying the section name (B2.2), in-pane heroes are an inverted hierarchy. → Adopt the shared header OR demote heroes to a status/action strip (≤56px); the title must never out-shout the titlebar.
- **No spacing scale in BridgeTokens** → padding drift (`.padding(20)` in 5 sections, `.padding(18)` in 4; kit.css `.pane` is 18×22). → Add `BridgeTokens.Space` (paneV 18, paneH 20, cardGap 14, navItemH 30, titleBar 38, footBar 30, trafficGutter 78) and apply one token everywhere.
- **Legibility floor**: many 9–10pt tracked labels across Skills/Jobs/Security/Connection/Advanced → bump all to ≥11pt.
- **Token hygiene**: kill raw `Color.white`/`Color.black.opacity()` (break light/titanium); signal TEXT must use `okText/warnText/badText` not base `ok/warn/bad` (light-mode contrast); replace hardcoded radii with `BridgeTokens.Radius`.
- **Truncate-with-reveal** (`lineLimit(1)` + `.help`) over shrinking, everywhere.
- **Sidebar selected-state**: currently double-signals (accent fill + hairlineStrong border) and mixes icon sizes (4 vector glyphs @18pt vs 6 SF Symbols @14pt) → pick ONE selection signal; normalize icon optical size (~15px in an 18×18 frame).

## Chrome / Shell  → `design-audits/chrome.md`
- **Sidebar** 188px; 7 items, conceptual-flow order; rows icon18 + 13pt label, height 30, gap 1. Selected = one signal only. Icons: Orders `scroll`/bow · Skills bow&arrow · Jobs `clock.badge.checkmark` · Tools crossed-tools · Security `lock.shield`/key · Connection `network` · Advanced two-gears.
- **Title bar** 38px (from 44), **leading-aligned**, left inset 76–78px (clear traffic lights), section name only (drop "The Bridge ›"), 13pt semibold `fg2`, **remove bottom hairline**, transparent + draggable. Keep `.fullSizeContentView` + `titlebarAppearsTransparent` + `titleVisibility=.hidden`.
- **Foot bar** 30px, **remove `chipFill` bg + top hairline** (blend into stage), keep version + status dot (verify dot reflects real status, not static green).
- Net: ~40–60px vertical chrome reclaimed; sidebar vertical rule becomes the only structural divider.

## Orders (doctrine + Commands)  → `design-audits/orders.md`
- Label "Orders" (data layer/tools/wording unchanged). Adopt shared header (`scroll`, purple), delete both bespoke heroes.
- **Segmented `Orders | Commands`** (persist via `@AppStorage`) + per-tab meta row (stat pair; Commands shows labeled "Command Bridge — On/Off").
- Orders tab: keep Preview/Edit + token meter; **editor flexible `minHeight 240`** (drop fixed 286); **Save visible in both modes** with dirty dot; fold Delivery-audit + Templates into ONE collapsed disclosure (~200px reclaimed).
- Commands tab: no hero; **remove outer ScrollView + `minHeight:560`** (CommandsSection L48) so only the two columns scroll; master 236 (collapsible ~200); token cleanup (`Color.white→onAccent`; selected = ring not dim-others).
- Density: pad 20→16h/14v, card gap 14→10, command rows 42→36, slot keys 46→40. Floor: body ≥12.5, command name ≥13, icon buttons 30×30.
- Edge: never-blank doctrine (seed default); **don't lose unsaved draft on tab switch**; re-verify slot-key legibility in light mode.

## Skills  → `design-audits/skills.md`
- Biggest space-waster (~240px chrome before first row). Collapse to ONE full-height master–detail; **no hero, no outer ScrollView, no standalone cache card**; edge-to-edge under titlebar.
- Page = `HStack`: list ~268px | 0.5px hairline | detail (maxWidth ∞), maxHeight ∞. Cross-tab guard banners pinned on top.
- List: toolbar (search 32px + add 32 + overflow w/ Sort & **Refresh-cache demoted here**); counts → list footer; rows ~36px `[glyph/dot] name(13, tail) — [7px status dot]` (drop 28px avatar + 9px platform tag); **keep 4-state status dot** + add a11y value/glyph; list bg `wellFill` (not `Color.black.opacity`).
- Detail: header avatar 48→32, name 18pt + rename (≥28px hit); metadata grid 8 cells→4 (Platform · **Visibility** · Page ID · Source); flatter read-only trigger chips; 3 labeled toggle rows (bind title as a11y label).
- Density: outer pad 18→0 (columns own insets), card gap 14→10, pre-content ~240→~56px. Floor: 9pt→≥10.5–11; 28px min hit on all icon buttons.

## Jobs  → `design-audits/jobs.md`
- Adopt shared header (purple, `clock.badge.checkmark`); **stat strip → header accessory, restore 4 stats** (done24h/running/paused/failing; dim on load error). No in-page 22pt title.
- Page-level **failing banner** when failingCount>0 (shared with row banner). **Scheduled jobs** card (label row: Pause all · +New · overflow; filter+search inline; Sort→overflow). **Recent runs** card (5 lines + expand, `.help` per line).
- Row (collapsed): `[icon30] name(1-line .help)+subline · Spacer · 3-slot grid {next-run · status badge · actions}`; subline `cron(mono) · firstTool +N`; **drop standalone chevron** (hover bg signals expand); **next-run = actual next fire time** for active jobs (not cadence echo).
- Controls: Pause/Resume + Run-now always visible (28×28 / ≥32pt tap); **Run-now → in-row spinner + toast + CONFIRM for send/payment/delete chains**; per-row history on expand (reuse RunLine; Reveal-Log fallback).
- Re-glass the inline editor (fields drop to native today); keep cron validation + Save gating. Density: pad 18→14, card gap →10. States: loading/empty/filter-empty/error(dim stats, user copy)/failing/bulk-toast. A11y: row as combined element; verify light-mode `fg5` meta contrast. **Footbar note** (chrome): mockup wants "Scheduler healthy · N active · N failing" — flag for footbar spec.

## Tools  → `design-audits/tools.md`  (most operator direction)
- **`LazyVGrid`** of group cards, **2 cols ≥660px container / 1 col <660 (cap 2)**, `[.flexible top, .flexible top]`, gutter+rowspacing `sm=12`, page pad `md=16`. **Hero card stays full-width** above grid; cards top-aligned (ragged bottoms OK). Preserve deep-link infra (`ScrollViewReader`/`.id`/`forceExpanded`).
- Group card header (half-width): `icon30 · {name 14.5 / countBadge+subtitle 11.5 tail} · Spacer · chevron · PartialToggle`; count badge **`N/M`** colored by masterState; **verify toggle tap isn't swallowed by the row's onTapGesture**.
- Tool row: `[7px dot] {name 12.5 mono / desc 11.5 lineLimit1 .tail+.help} ⟶ [TIER CHIP] [mini switch]`; **drop the red OFF pill** (reclaims ~36px); switch `.mini` tint ok.
- **Cycling tier chip** (already built): Open→Notify→Request→Open; OPEN `ok@.14`/okText, NOTIFY `warn@.16`/warnText, REQUEST `bad@.16`/badText. ("Confirm" in the brief = REQUEST tier — keep REQUEST label to match SecurityTier/router.) **Persistence unchanged** (ToolTierResolution.effectiveTier → tierOverrides → `.notionBridgeTierOverridesDidChange`). A11y: expose tier via `.accessibilityValue` + cycle action.
- Dep-link chips keep (wrap at half-width). Floor: name 12.5/desc 11.5; 10–10.5 reserved for all-caps badges only. **Flag:** legacy `ToolRegistryView.swift` is dead once ModuleGroupList is the page — confirm/remove separately.

## Security (Credentials + Permissions)  → `design-audits/security.md`
- **D1 RESOLVED:** Tools owns per-tool tiers (the cycling chip). Security's **"Gates" tab = macOS system access (TCC grants) + module Always-Allow/revoke** (what `PermissionsSection` actually is) — NOT per-tool tiers. The posture header shows tier COUNTS read-only (OPEN/NOTIFY/REQUEST) with a "Manage in Tools ↗" link. No duplication.
- **Posture header** (one bespoke, replaces both orb-heroes): orb 44 `lock.shield` gold · "Security" 18pt · stat tiles STORED/ATTENTION + tier counts OPEN/NOTIFY/REQUEST · Touch-ID chip; subscribe to tierOverrides + creds-changed for live counts.
- Tabs: **Vault** (default) | **Gates**.
- Vault: keychain banner (one place naming Keychain) · ONE add pill (drop the 2nd add) · credential rows (34 service-mark · name 14 · masked mono subtitle · USED-BY dep chips · checked-line ≥11 + Revalidate · status badge · Rotate/Copy/Delete 28, Touch-ID-gated; key by service+account not offset) · policy card (Require Touch ID, Auto-validate weekly) · keep CredentialAddSheet verbatim.
- Gates: grouped, gate-first (no on/off — that's Tools); module header shows Always-Allow chip + Revoke; tool rows = tier pill (cycle, ≥11pt labels) + source annotation; `neverAutoApprove` locked at Request; **re-home TCC** as a secondary "System access" sub-section (reuse grantsCard/sensitivePathsCard/Reset-all). **Share the tier model with Tools** (don't fork cycleTier/tiers).
- Density: pad 20, card gap sm, tile 34 r9, one badge grammar, floor 11pt.

## Connection (Connections + Remote Access)  → `design-audits/connection.md`
- Layout: **Status strip → Local clients → Remote access**. Pad 16, card gap 12.
- **Delete dead code** (zero call-sites): `ConnectionsManagementView.swift`, `ConnectionSetupView.swift`, `StripeConnectionSection.swift`.
- Status strip (~52px, replaces both heroes): dot+label (Online/Stopped from `statusBar.isServerRunning`) · clients count · last-seen · optional calls-today · actions Restart + Copy-loopback.
- Local clients: loopback `127.0.0.1:{ssePort}/mcp` copyable card ("local clients connect with no token" — PKT-810 model); transports folded into a collapsed disclosure; per-client rows (Claude Desktop, Claude Code) with Configure reveal.
- Remote access: surface **`https://mcp.kup.solutions/mcp` as STATIC copyable reference** (fixes the dead-URL problem — today it's only built dynamically when `cloudConfigured`, which is false); Model A → **"Cloud access — Coming soon" pill, not a dead switch**; keep security-posture (condensed) + Add-to-Claude.ai (gated on real hostname). Preserve `RemoteAccessToggleDecision` for re-enable.
- **Remove Stripe** tile (integrationsCard) → Notion-only single line. **Relocate**: Launch-at-login + Check-for-Updates → Advanced; Manage-credentials links → Security; configure-ports → Advanced.
- One dot vocabulary (ok/warn/bad/fg4); one link primitive (BridgeDepLink); signal text → *Text variants; micro-labels ≥11.

## Advanced  → `design-audits/advanced.md`
- Strongest structure, most wasteful (version appears 3×). Collapse 7 cards → **System** (merge About + endpoints-if-kept + paths, 3 labeled sub-groups) + **Maintenance**.
- **Drop the hero** (titlebar carries name) → one subtitle line (~85–100px saved). **Version single-source = Advanced's About row** (delete hero versionTile; footbar keeps tiny chrome version).
- Unify into one `metaRow` (read-only / copyable monoChip / path-with-reveal; keep keyed copied-flash + add a11y announce). **Pull Export OUT of the destructive grid**; remaining 3 = Reset/Danger zone (keep role:.destructive + confirms).
- **Receives relocations**: License (billing, full state machine) → here? NO — License → **Security** per connection/advanced split; but **About/version + merge-orphaned low-level toggles land here**. Tokens: hardcoded radii→`Radius`; `.neutral` `Color.white`→adaptive; pad 20→16, gap 14→10.

## Decisions raised by the audits — ALL RESOLVED 2026-06-10
- **D1 ✓** Tools owns per-tool tiers; Security "Gates" = system access (TCC) + module Always-Allow/revoke; posture header shows tier counts read-only + "Manage in Tools ↗".
- **D2 ✓** Adopt the shared `BridgeSettingsSectionHeader` and demote in-page heroes everywhere — titlebar is the canonical page H1.
- **D3 ✓** Add `BridgeTokens.Space` spacing scale; apply one padding token across all pages.
- **D4 ✓** Relocations approved: License → Security · Network port + local endpoints → Connection (Local-clients) · Launch-at-login + Check-for-Updates → Advanced (version single-sourced to Advanced's About row) · **remove Stripe** tile from Connection (Stripe tools being cut).

---

# VALIDATION PASS (2026-06-10) — execution-readiness hardening
> Verified against source. The page audits were view-scoped and missed the load-bearing enum/nav/MCP/test/Dashboard layer below. **Executors: read this section first — it governs build-correctness and market safety.**

## V1 — `SettingsSection` enum migration is the critical path (everything depends on it)
`SettingsSection` (SettingsWindow.swift L114) is `String, CaseIterable` with **rawValue = the display string** (`standingOrders = "Standing Orders"`, etc.). It is consumed by: the sidebar, `BridgeTitleBar(title: nav.section.rawValue)`, deep-link routing, the **MCP tool** `bridge_settings_navigate` (`BridgeAutomationModule.resolveSection`/`sectionRawValues`/`navigate`), and 5 test files. Merging 10→7 is NOT a view change — it is an enum + contract migration.
**Directives:**
- **Decouple label from id.** Do NOT repurpose rawValue for display. Keep stable rawValue IDs; add a `displayName` computed property for the UI ("Orders", "Connection", "Security"). `BridgeTitleBar` + sidebar render `displayName`; rawValue stays the stable deep-link/MCP id.
- New cases: `orders` (was standingOrders), `security`, `connection`. Removed as top-level: `commands`, `connections`, `remoteAccess`, `permissions`, `credentials`.
- **Sub-area anchors:** Commands/Vault/Gates/Local/Remote are reached via the existing `go(section, anchor:)` anchor param (e.g. `.orders` anchor `commands`, `.security` anchor `gates`, `.connection` anchor `remote`). Wire anchors, don't add enum cases.

## V2 — MCP contract back-compat (market safety — don't break external callers)
`bridge_settings_navigate` exposes section strings to ANY connected agent/script. Removing "Credentials"/"Permissions"/"Remote Access"/"Connections"/"Commands" silently breaks existing automations.
**Directive:** `resolveSection` MUST keep **back-compat aliases** mapping the 5 retired strings → their new home + anchor (Credentials→security/vault, Permissions→security/gates, Remote Access→connection/remote, Connections→connection, Commands→orders/commands). The tool's *advertised* enum becomes the 7 names; the *resolver* still accepts the legacy 5. Add a test asserting each legacy alias resolves.

## V3 — Test contracts that WILL break (update as part of the foundation, not after)
- `WSHMenuBarTests`: `count == 10` → 7; drop assertions for removed cases; **icons** — it asserts SF Symbols (`scroll`/`sparkles`/`hammer`/`network`/`command`). **Keep SF Symbols this pass** (defer custom vector glyphs to a later polish packet) so the icon contract only changes for merged/removed cases; update the "most-visited (Standing Orders)" order assertion to the conceptual-flow order.
- `SettingsSectionsLGTests`: "every section has a header preset" — add presets for `orders`/`security`/`connection`, remove retired; keep the "single shared `BridgeSettingsSectionHeader` type" invariant (we're now ADOPTING it — strengthen, don't weaken).
- `BridgeCloudManagerTests`: asserts `.remoteAccess` case + rawValue — re-point to `.connection` (remote anchor) or assert the alias.
- `BridgeAutomationModuleTests`: "sectionRawValues covers all cases" — will pass if kept in sync; add the back-compat alias test (V2).
- `PKT879DashboardTests`: "every dashboard row deep-links to a real section" — update DashboardView deep-link targets to the 7 cases first (see V4).

## V4 — Surfaces the page audits missed
- **DashboardView** deep-links into sections (PKT879). Audit + repoint its rows to the 7-section set. Treat as part of the foundation packet.
- **CommandBridge.swift** opens Settings→Commands; repoint to `.orders` anchor `commands`.
- **No persisted "last section"** found (selection is in-memory `SettingsNavigation.shared.section`) — no migration needed, but confirm the default section (`.orders`) is valid post-merge.

## V5 — Market-success quality bar (how executors should decide when the spec is silent)
The Settings UI is the product's face for the Anthropic/ChatGPT directory listing and enterprise buyers; the positioning is **"universal context Mac bridge."** When a spec detail is ambiguous, optimize for:
1. **First-5-minutes clarity** — empty states teach (every list/tab has a real empty state with a next action), the connect path is obvious.
2. **Enterprise trust** — Security/Connection must *read* as trustworthy (truthful status, no dead switches, no fake-green dots; the loopback-vs-cloud model legible).
3. **Light + dark parity** — every change verified in BOTH titanium-light and carbon-dark (the token-hygiene fixes exist for exactly this; no raw Color.white/black).
4. **Accessibility = table stakes** — VoiceOver labels on every control (bind row title as the toggle/switch label), keyboard nav preserved, contrast ≥ WCAG AA at the new densities (the legibility floor enforces this).
5. **No capability/security regressions** — Touch-ID gates, tier persistence, confused-deputy/session binding, and the `neverAutoApprove` lock all survive the reskin untouched.
6. **Performance** — density must not add layout cost (LazyVGrid for Tools; no eager rendering of collapsed content).

## V6 — Execution plan (dependency-ordered packets — DO NOT parallelize across the foundation)
**PKT-A · Foundation (sequential, blocks all):** `BridgeTokens.Space` scale · adopt `BridgeSettingsSectionHeader` (presets for new cases) · `SettingsSection` 10→7 with `displayName` + stable rawValue ids + anchors · MCP back-compat aliases (V2) · title bar + foot bar chrome (B2.2/B2.3) · repoint ALL deep-links + DashboardView (V4) · update the 5 test files (V3). **DoD:** builds, full suite green, floor held, app launches to the 7-section nav, every legacy + new deep-link + MCP alias resolves. Isolated worktree/branch only.
**PKT-B…H · per page (after A lands, each in the A branch, sequenced to avoid routing-switch conflicts):** Orders · Skills · Jobs · Tools · Security · Connection · Advanced — each per its section above. **Per-page DoD:** builds, suite green, light+dark verified in preview, a11y labels present, no security/persistence regression, density targets met, empty/loading/error states.
**Global non-negotiables:** never change tierOverrides/credential/session-binding persistence contracts; keep the shared tier model single-sourced (Tools owns it; Security reads counts); verify in BOTH themes; one selection signal + SF-Symbol icons this pass.

## Open questions
- (none — spec is execution-ready; foundation packet dispatching via orchestrator)
