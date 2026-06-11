# Tools page — UI/UX design audit

> Settings redesign · The Bridge (macOS SwiftUI menu-bar app, MCP connector)
> Scope: the **Tools** section only. This page carries the MOST operator
> direction in the redesign; the audit honors the locked TOOLS SPEC precisely.
> Method: `design:design-critique` rubric applied against the live source.
> Source is READ-ONLY; the only write is this file.

## Files audited (ground truth)

| Path | Role |
|------|------|
| `NotionBridge/UI/ModuleGroupCard.swift` | `ModuleGroupCard` (group card + header + tool list) and `ModuleGroupList` (the page) |
| `NotionBridge/UI/ToolRegistryView.swift` | legacy flat `Form`-based registry (still in tree; superseded by ModuleGroupList) |
| `NotionBridge/UI/Sections/ToolDepLinks.swift` | dep-link derivation + `BridgeDepLinkRow` |
| `NotionBridge/Core/ModuleGroup.swift` | `ModuleGroup` model, `masterState`, prefix derivation, dispatch gate |
| `NotionBridge/UI/BridgeShell.swift` | shell primitives (titlebar, footbar, nav, glass) |
| `NotionBridge/UI/BridgeThemeV2.swift` | `BridgeGlassCard`, `PartialToggle`/`TripleState`, `BridgeDepLink`, `BridgeCardLabel` |
| `NotionBridge/UI/BridgeTokens.swift` | color tokens, `Radius` |
| `NotionBridge/UI/BridgeTheme.swift` | `BridgeSpacing` scale (xxs 4 / xs 8 / sm 12 / md 16 / lg 24) |

---

## Overall Impression

The grouped-card model is sound and most of the locked row anatomy already
exists — the cycling tier chip, the tri-state master toggle, the dep chips,
the per-tool truncated description are all present in `ModuleGroupToolRow`
(`ModuleGroupCard.swift:36–132`) and the header (`:269–316`). The single
biggest miss against the locked spec is **layout, not components**:
`ModuleGroupList` stacks every card in one full-width column
(`ModuleGroupCard.swift:548` — a plain `VStack`, not a `LazyVGrid`), so on a
wide window each card spans the full content width and the page becomes a tall
single-file scroll. The locked decision is a **responsive 2-up `LazyVGrid`
that collapses to 1 column below ~640–680px container width**. That is the
headline change. Secondary: the header master toggle/region eats horizontal
space (the GLOBAL DENSITY TENET flags this), and the legacy `ToolRegistryView`
is dead weight that should not ship.

---

## The current wide-toggle / wide-card problem

Two distinct "too wide" problems, both flagged by the density tenet:

1. **Card is full-bleed.** `ModuleGroupList.body` lays cards in
   `VStack(alignment: .leading, spacing: BridgeSpacing.sm)`
   (`ModuleGroupCard.swift:548`) inside a `ScrollView` padded `BridgeSpacing.md`
   (`:575`). With ~26 derived groups (one per non-empty `ModuleGroupID`,
   `ModuleGroup.swift:481`) and a window that is typically 600–900px wide, a
   one-column stack wastes the right half of the page on wide windows and
   forces a long scroll. This is the primary target of the locked 2-col grid.

2. **The header master region is wide.** The header
   (`ModuleGroupCard.swift:269–299`) is `iconSquare · {name + countBadge +
   subtitle} · Spacer · chevron · PartialToggle`. `PartialToggle` is a fixed
   40×24 capsule (`BridgeThemeV2.swift:177`) — that part is fine. The waste is
   the `countBadge` rendering a full sentence ("`12 of 18 active`",
   `:366/376`) PLUS the subtitle on the same line, pushing the toggle far
   right and leaving a large dead gap via `Spacer(minLength: 8)` (`:285`). In
   a 2-up grid (~half width) this row will be cramped; the count must shrink
   to a compact glyph form (e.g. `12/18`) and the subtitle must yield first.

The legacy `ToolRegistryView` (`ToolRegistryView.swift`) is the *original*
wide-toggle problem in full: a `.formStyle(.grouped)` `Form` with a leading
40-ish switch, a wide name+chip row, and 3-line descriptions on disabled tools
(`:321–326`). It is verbose, low-density, and already superseded — it should
not be part of the redesigned page.

---

## The responsive 2-column grid (locked)

**Target:** a `LazyVGrid` of group cards, **2 columns side-by-side**, collapsing
to **1 column below ~640–680px container width**, capped at 2 columns (never 3+).

- Replace the `VStack` at `ModuleGroupCard.swift:548` with a `LazyVGrid`.
- Columns: `[GridItem(.flexible(), spacing: gutter), GridItem(.flexible())]`
  when width ≥ breakpoint; a single `[GridItem(.flexible())]` below it.
- Drive the column count off the **container** width, not the screen — wrap the
  grid in a `GeometryReader` (or read the `ScrollView` content width) and pick
  `columns = containerWidth >= breakpoint ? 2 : 1`.
- **Breakpoint: 660px** content width (midpoint of the locked 640–680 band).
  Rationale: the inner section content sits to the right of the 188px nav
  (`BridgeShell.swift:165`) inside a ~640–960 window; 660 puts the flip near
  the common-window boundary so a default-size window shows 2 columns and a
  pinched/half-width window shows 1.
- **Gutter / row spacing: `BridgeSpacing.sm` (12)** — matches the current card
  spacing (`:548`) and keeps Tools and Jobs on one tier (the comment at
  `:545–547` explicitly aligns these two pages).
- **Outer padding: `BridgeSpacing.md` (16)** — unchanged (`:575`).
- The `hero` card (`ModuleGroupCard.swift:610–643`) must remain **full-width**
  — place it ABOVE the grid (or span both columns), not as a grid cell.
- **Card height:** cards are variable height (collapsed vs. expanded, variable
  tool counts). `LazyVGrid` aligns rows to the tallest cell; to avoid a tall
  expanded card leaving a sibling with dead space, set each card
  `.frame(maxHeight: .infinity, alignment: .top)` is WRONG here (would stretch
  collapsed cards). Instead use `GridItem(.flexible(), alignment: .top)` so
  cards top-align and keep their natural height. Accept ragged column bottoms —
  this is correct masonry-ish behavior for collapsibles and far better than
  stretching.
- **Deep-link scroll preserved:** `ScrollViewReader` + `.id(group.id)`
  (`:543`, `:572`) and `scrollToAnchorIfNeeded` (`:595`) work unchanged inside
  a `LazyVGrid` — the `.id` is on the card, not the row container.

### Why 2-up (critique: visual hierarchy + usability)

26 groups in one column is a ~26-row scroll where the operator must page past
modules they don't care about to reach (say) `shell` or `stripe`. Two columns
roughly halves scroll length, brings more of the registry into the first
viewport, and uses the wasted right gutter the density tenet calls out. Capping
at 2 (not 3) keeps each card wide enough for the row anatomy (icon · title ·
description · toggle · tier chip) to stay legible above the 11–12px floor.

---

## Compact per-tool row anatomy

The row already matches the locked anatomy and the legibility floor — this is a
KEEP, with two tightening notes. Current `ModuleGroupToolRow`
(`ModuleGroupCard.swift:36–132`):

```
[7px status dot] [ name (12.5 mono) / description (11.5, lineLimit 1, tail) ]  ⟶Spacer⟶  [TIER CHIP] [off pill?] [mini switch]
```

| Element | Current value (source) | Verdict |
|---------|------------------------|---------|
| Row HStack spacing | `11` (`:58`) | OK |
| Row padding | `.horizontal 10`, `.vertical 8` (`:111–112`) | OK — dense, ~33px row |
| Status dot | 7×7 `Circle`, emerald glow on / `fg5` off (`:61–66`) | KEEP |
| Tool name | `12.5` monospaced, `fg1` (`:69–71`) | KEEP (≥12 floor) |
| Description | `11.5`, `fg4`, `lineLimit(1)`, `.tail` (`:72–78`) | KEEP — **add `.help()` tooltip for the full text (hover/tooltip reveal per spec)** |
| Tier chip | tappable capsule, `10` semibold (`:85–97`) | KEEP — see chip section |
| "off" pill | red capsule shown when disabled (`:98–103`) | **REDUNDANT** — see below |
| Toggle | `.switch` `.mini`, tint `ok` (`:105–109`) | KEEP |
| Disabled row | `.opacity(0.52)` (`:113`) | OK |
| Row a11y | `.combine`, label "name — enabled/disabled" (`:118–119`) | KEEP |

Two tightening notes:

1. **Description tooltip is missing.** The spec wants "1-line-truncated
   description (hover/tooltip reveal)". The row truncates (`:76`) but has no
   `.help(description)`. Add `.help()` on the description `Text` (or the row) so
   the full description surfaces on hover — this is the "reveal" half of
   truncate-with-reveal and costs nothing.
2. **The "off" pill is redundant in the dense grid.** When a tool is disabled
   the row already shows: dimmed `0.52` opacity, a grey status dot, and an
   off-position switch. Adding a red "OFF" capsule (`:98–103`) is a third
   redundant signal that competes with the tier chip for the narrow trailing
   space — especially costly at half-width in a 2-up grid. **Drop the "off"
   pill**; the opacity + switch already encode the state. (Persistence
   unaffected — purely visual.)

Trailing-cluster width budget at half-width is the real constraint: tier chip
(~52px) + switch (~30px) + spacing must fit beside a truncating
name/description. Removing the off pill reclaims ~36px and prevents the chip
from being squeezed.

---

## The cycling tier chip (states / colors / accessibility)

Already implemented exactly as locked — a tap-to-cycle, color-coded capsule
replacing the old wide tier button. `ModuleGroupToolRow.tierTriple`
(`ModuleGroupCard.swift:49–55`) + the `Button` (`:85–97`); cycle logic in
`ModuleGroupList.cycleTier` (`:501–515`).

**Cycle order:** Open → Notify → Request → Open
(`nextTier`, `ModuleGroupCard.swift:488–494`; spec says "Open→Notify→Confirm" —
the in-code third tier is **`request`/REQUEST**, the canonical security-tier
name; treat "Confirm" and "Request" as the same state, keep the code's
`REQUEST` label to match `SecurityTier` and the router).

**States, colors, copy** (all from BridgeTokens — no raw colors):

| Tier | Label | Fill | Stroke | Text | Token source |
|------|-------|------|--------|------|--------------|
| `open` (default) | `OPEN` | `ok @0.14` | `ok @0.28` | `okText` | `:53` |
| `notify` | `NOTIFY` | `warn @0.16` | `warn @0.30` | `warnText` | `:52` |
| `request` | `REQUEST` | `bad @0.16` | `bad @0.30` | `badText` | `:51` |

Chip typography: `10pt` semibold, `tracking 0.4`, padding `.h 7 / .v 2`,
`Capsule()` with `0.5` stroke (`:86–93`). The 10pt is BELOW the 11–12px text
floor, but this is an established **all-caps badge/pill idiom** used consistently
across the app (`countBadge` 10.5 `:382`, hero stat labels 10 `:659`,
`BridgeCardLabel` 11). For a tracked, all-caps, single-word status token this is
acceptable and on-system; do not enlarge it (that would re-bloat the trailing
cluster). It clears the spirit of the floor (legibility) via weight + tracking +
caps.

**Persistence contract (DO NOT CHANGE):**
- effective tier resolved by `ToolTierResolution.effectiveTier(...)`
  (`ModuleGroupList.tiers`, `:472–481`) — per-tool override > module grant >
  registered default.
- cycle writes `BridgeDefaults.tierOverrides` and clears the override when the
  next tier lands back on the tool's *base* (module grant or registered
  default) so it follows the grant/default (`cycleTier`, `:506–513`).
- posts `.notionBridgeTierOverridesDidChange` (`:514`) so the router + other
  surfaces update live. Reuse all three verbatim.

**Accessibility gaps to close (critique):**
- The chip is inside a row whose `accessibilityElement(children: .combine)`
  collapses it (`:118`); the combined label ("name — enabled/disabled",
  `:119`) **omits the tier entirely**. A VoiceOver user cannot hear or change
  the security tier. Fix: either include the tier in the combined label
  ("`<name>, <enabled/disabled>, security <tier>`") or expose the chip as its
  own accessibility element with `.accessibilityValue(tier)` and an
  `.accessibilityAction` to cycle. Prefer the latter so the gate is operable.
- The `.help()` tooltip ("Security gate — tap to cycle…", `:97`) is good for
  mouse but not a substitute for the a11y label.
- **Contrast:** the light-mode `*Text` tokens are the deep variants
  (`okText #0A6442`, `warnText #825910`, `badText #941F1F`,
  `BridgeTokens.swift:98–109`) over a ~14–16% tint on a near-white card — these
  pass AA for the small-but-bold caps. Dark-mode variants are the pale
  on-glass set; also fine. No change needed.

---

## The master-group toggle (PartialToggle tri-state)

Correct as built. Header `PartialToggle` (`ModuleGroupCard.swift:289–298`)
bound to `group.masterState.ui`. `masterState` is **derived** from per-tool
disabled state (`ModuleGroup.swift:231–236`): `on` (none disabled) / `off`
(all disabled) / `partial` (mixed). Writes route through `onMasterChange` →
`setGroupEnabled` (`:675–682`) which adds/removes the whole group from
`disabledTools` — the partial state is never a write target (the comment at
`:291–295` is correct: partial is derived, never the target).

`PartialToggle` visuals (`BridgeThemeV2.swift:168–223`): 40×24 capsule, 18px
white knob, knob alignment leading/center/trailing for off/partial/on, track
fill `chipFill` (off) / `warn 0.55→0.40` (partial) / `ok 0.65→0.55` (on). Cycle
semantics (`:214–222`): off→on, partial→on (complete the group), on→off. This
matches the locked decision and the `setGroupEnabled` write.

**Critique notes:**
- The whole header is *also* a tap target that toggles expand/collapse
  (`.onTapGesture` `:303–309`), and the `PartialToggle` is a `Button` nested
  inside it. Verify the toggle's tap is not swallowed by the header's gesture
  (SwiftUI usually lets the inner Button win, but a nested-gesture conflict here
  is a classic bug). Keep the toggle hit area distinct from the
  expand-on-header-tap region. **This is the one interaction to verify on
  device after the grid change.**
- The header carries TWO state readouts of the same fact: `countBadge`
  ("N of M active", color-coded by masterState, `:359–389`) AND the
  `PartialToggle` color (amber=partial / green=on). That redundancy is fine and
  even helpful — but in the half-width 2-up card, **shorten the count to
  `N/M`** (monospaced, `:388` already sets `monospacedDigit`) and let the
  subtitle truncate first (it already does, `:281–282`). The word "active" and
  the "of" can go; the color already says "active vs partial vs off".

---

## Dep-link chips

Two dep-link surfaces, both correct and both KEEP:

1. **In-card `depChipRow`** (`ModuleGroupCard.swift:398–414`): "depends on" +
   one `BridgeDepLink` per `group.dependencies`, rendered when expanded
   (`:220–222`). Variant `.bad` when severity is bad (missing
   permission/credential), else `.info` (`:406`). Dependencies are authored in
   `ModuleGroupDerivation.defaultDependencies` (`ModuleGroup.swift:385–431`).
2. **`warnBanner`** (`:244–265`): when an expanded, non-off group has a
   `.bad`-severity unmet dependency (`unmetDependency`, `:211–213`), an amber
   banner explains tools won't function until the grant is made, with a
   trailing `BridgeDepLink` to the fix. Good progressive disclosure.

`BridgeDepLink` (`BridgeThemeV2.swift:127–157`): 11pt medium, `infoText`
(adaptive royal-blue link) or `badText`, with a `↗` affordance. Taps route via
`onDepLinkTapped` → `handleDepLink` → `nav.go(.permissions/.credentials/
.connections)` (`:688–695`). The reciprocal chips on the Permissions/Credentials
pages (`ToolDepLinks.swift` `usedByChips`/`requiredByChips`) deep-link BACK into
Tools with an `anchor`, which `ModuleGroupList.anchoredGroupID` (`:535–540`)
resolves to a group, auto-expands (`forceExpanded`, `:155/556`), and scrolls to
(`:595–608`). This cross-page graph is a genuine strength — preserve it intact
through the grid migration (it keys off `.id(group.id)`, unaffected by columns).

**Critique note:** dep chips render in a `HStack` with `Spacer` (`:399–410`).
At half-width, a group with 2 chips (e.g. `chrome` → Accessibility +
Screen Recording, `ModuleGroup.swift:411–415`) plus the "depends on" prefix may
overflow. Allow the chip row to wrap (a flow layout) or drop the "depends on"
prefix at narrow widths; do NOT shrink chip text below 11.

---

## Density values (consolidated reference)

| Token / measure | Value | Where |
|-----------------|-------|-------|
| Grid gutter & row spacing | `BridgeSpacing.sm` = 12 | locked param |
| Page outer padding | `BridgeSpacing.md` = 16 | `:575` |
| Grid breakpoint (1↔2 col) | **660px** container width | locked (640–680 band) |
| Card corner radius | 12 (`Radius.card`) | `:216` |
| Card glass | `BridgeGlassCard(cornerRadius:12, padding:0)` | `:216` |
| Header padding | `.h 14 / .v 11` | `:300–301` |
| Header icon tile | 30×30, radius 8 | `:356` / `:335` |
| Group name | 14.5 semibold, `fg1` | `:274` |
| Subtitle | 11.5, `fg4`, 1-line tail | `:279–282` |
| Count badge | 10.5 semibold, monospaced digits | `:382/388` |
| Tool list padding | `.h 6 / .top 4 / .bottom 6`, spacing 1 | `:418/432–434` |
| Tool row | `.h 10 / .v 8`, HStack spacing 11 | `:111–112/58` |
| Tool name | 12.5 mono | `:70` |
| Tool description | 11.5, 1-line tail | `:74–77` |
| Tier chip | 10 semibold, tracking 0.4, pad `.h7/.v2` | `:87–90` |
| Master toggle | 40×24 capsule, 18px knob | `BridgeThemeV2.swift:177/181` |
| Per-tool switch | `.switch` `.controlSize(.mini)` | `:106–108` |
| Status dot | 7×7 | `:64` |

**Legibility floor compliance:** all *body* text is ≥11.5 (names 12.5, desc/
subtitle 11.5). The 10–10.5 values are confined to tracked all-caps badge/pill
labels (tier chip, count badge, hero stat captions) — an intentional,
system-consistent exception. Honor truncate-with-reveal (descriptions +
subtitle truncate; add `.help()` reveal) over shrinking text below the floor.

---

## Breakpoints

| Container width | Layout |
|-----------------|--------|
| ≥ 660px | 2-column `LazyVGrid`, gutter 12 |
| < 660px | 1-column `LazyVGrid` (or VStack), full width |
| (never) | 3+ columns — capped at 2 by spec |

Hero card spans full width at all breakpoints. Cards top-align within a grid
row (`GridItem(alignment: .top)`); ragged column bottoms are expected and
correct for collapsible cards.

---

## Usability

| Finding | Severity | Recommendation |
|---------|----------|----------------|
| Single-column stack wastes wide-window space, long scroll over ~26 groups | 🔴 Critical | Responsive 2-up `LazyVGrid`, breakpoint 660px (the locked decision) |
| Tier change is invisible/inoperable to VoiceOver (combined label omits tier) | 🟡 Moderate | Add tier to combined a11y label or expose chip as element with value + cycle action |
| Description truncates with no reveal | 🟡 Moderate | Add `.help(description)` tooltip on the description/row |
| Redundant "OFF" pill competes for narrow trailing space | 🟢 Minor | Drop it; opacity + grey dot + off-switch already encode disabled |
| Header master toggle nested in header tap-gesture | 🟡 Moderate | Verify toggle tap isn't swallowed by expand-on-tap after grid change (on-device) |
| Count badge verbose ("N of M active") for half-width card | 🟢 Minor | Shorten to `N/M`; let subtitle yield first |
| Legacy `ToolRegistryView` still in tree | 🟢 Minor | Confirm it is not routed; exclude from the redesigned page (out of audit write-scope) |

## Visual Hierarchy

- **What draws the eye first:** the per-group icon tile + name (good — the
  module is the unit of decision). Accent-tinted tiles (`accent`, `:322–332`)
  color-code the registry by source — a real strength.
- **Reading flow:** today vertical-only; the 2-up grid gives a Z-scan and
  surfaces more modules per viewport.
- **Emphasis:** the master toggle (right) and the count badge both read the
  group's on/partial/off state — correct emphasis; just compress at half-width.

## Consistency

| Element | Status |
|---------|--------|
| Colors | All via BridgeTokens (signals + accent + ink); no raw palette. PASS |
| Glass | `BridgeGlassCard` for cards + hero; `PartialToggle`, `BridgeDepLink`, `BridgeCardLabel` reused. PASS |
| Spacing | Card stack on `BridgeSpacing.sm`; page on `.md`. Inner row paddings are bespoke literals but dense and consistent. MOSTLY PASS |
| Badge idiom | 10–11pt tracked all-caps capsules used uniformly (tier chip, count, hero captions). PASS |

## Accessibility

- **Color contrast:** adaptive `*Text` tokens are deep on light / pale on dark
  over tinted capsules — AA-safe for bold caps. PASS.
- **Touch/hit areas:** mini switch + 10pt chip are small but mouse-targeted on
  macOS; chip has `contentShape(Capsule())` (`:96`). Acceptable for pointer.
- **VoiceOver:** header is a labeled button with expanded/collapsed state
  (`:310–315`) — good. Tool row combines children but **drops the tier** — the
  one real a11y defect (see Usability).
- **Text readability:** body ≥11.5; floor honored. PASS.

## What Works Well

- Cycling tier chip, tri-state master toggle, dep chips, and truncated dense
  rows are already built to the locked anatomy — the redesign is mostly a
  *layout* change, not a component rewrite.
- The cross-page dep-link graph (Tools ↔ Permissions/Credentials/Connections)
  with auto-expand + scroll-to-anchor is a standout, and survives the grid.
- Color-coded per-source icon tiles give the registry instant scanability.
- Persistence is cleanly factored (`disabledTools`, `tierOverrides`,
  `moduleTierOverrides`, `moduleGroupExpanded`) with a live
  `notionBridgeTierOverridesDidChange` contract — no churn needed.

## Priority Recommendations

1. **Ship the responsive 2-up `LazyVGrid`** (breakpoint 660px, gutter 12, hero
   full-width, cards top-aligned). This is the locked decision and the single
   highest-impact change. Replace the `VStack` at `ModuleGroupCard.swift:548`.
2. **Compress the half-width card chrome:** count badge → `N/M`, subtitle
   yields first, drop the redundant "OFF" pill, add `.help()` description
   reveal. Keeps the dense row legible at ~half width.
3. **Close the tier a11y gap:** expose the tier chip with an accessibility
   value + cycle action (or fold the tier into the row's combined label) so the
   security gate is operable by VoiceOver.
