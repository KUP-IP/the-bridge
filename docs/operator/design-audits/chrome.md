# Chrome / Shell — Design Audit

**Surface:** the cross-cutting window frame (stage, sidebar/section-nav, title bar, foot bar, per-page section header) that all 7 pages live inside.
**App:** The Bridge — macOS SwiftUI menu-bar app, MCP connector. v3.7.7.
**Scope:** UI/UX design audit for the Settings redesign. Source is READ-ONLY.
**Rubric:** `design:design-critique` (first-impression, usability, hierarchy, consistency, accessibility).

Files in scope:
- `NotionBridge/UI/BridgeShell.swift` — `BridgeStage`, `BridgeCarbonWeave`, `BridgeVectorIcon`/`BridgeIconShape`, `BridgeSectionNav`/`BridgeSectionNavItem`, `BridgeTitleBar` (L265), `BridgeFootBar` (L287).
- `NotionBridge/UI/SettingsWindow.swift` — `SettingsWindowController` (window styleMask/size L69–96), `SettingsSection` enum (L114–142), `SettingsView.body` layout (L213–228), `detailContent` switch (L230–244).
- `NotionBridge/UI/Sections/BridgeSettingsSectionHeader.swift` — shared per-page hero header + presets.
- `NotionBridge/UI/BridgeTokens.swift` — color/radius tokens (no spacing scale exists yet).
- `NotionBridge/UI/BridgeThemeV2.swift` — `BridgeSectionIcon.systemImage(for:)` (L290).
- `design/design-system/project/ui_kits/the-bridge/kit.css` — visual SSOT (`.titlebar` L62, `.secnav` L72, `.sec` L75, `.pane` L85, `.footbar` L178).

---

## Overall Impression

The shell is handsome and internally coherent — the carbon/titanium "Liquid Glass" identity is consistent, the custom vector glyphs are a nice touch, and the system-tethered appearance is well-built. But it is **spending vertical space it doesn't have**: a 44px centered breadcrumb title bar with a hairline, a 30px slab foot bar with its own fill + hairline, AND a third heavy in-pane "hero" header (44px icon tile + 18px title + subtitle) at the top of every page. That is **three stacked headers** competing for the top of the window, and the breadcrumb ("The Bridge › Connections") restates what the selected sidebar row and the in-pane hero already say twice. The biggest opportunity is to collapse this redundancy and reclaim ~40–60px of chrome height, then carry the same density discipline into the sidebar and pane.

The locked redesign decisions (section-name-only left-aligned title, no title hairline, de-slabbed foot bar, 10→7 sidebar) directly target the worst of this. This audit specs them and flags the second-order work they expose.

---

## 1. Sidebar / Section-Nav (`BridgeSectionNav`, L148–259)

### Current state
- Width **188px** (L165), matches `.secnav` SSOT. Vertical padding 10, horizontal 8 (L163–164). Item gap **1px** (L153). Good.
- Renders **all 10** `SettingsSection.allCases` (L154) — Standing Orders, Commands, Connections, Remote Access, Skills, Permissions, Credentials, Tools, Jobs, Advanced — in enum order (L114–124). The order is "most-visited-first," not conceptual-flow.
- Each item (`BridgeSectionNavItem`, L204): HStack icon(18×18) + 10px gap + 13px label; horizontal pad 9, **height 30** (L223); corner radius 7. Solid hit target — meets the floor.
- **Selected state is doubled up**: `accent.opacity(0.14)` fill (L252) AND a `hairlineStrong` 0.5px stroked border (L228–230). The CSS SSOT (`.sec.on`, L78–79) uses a white top→bottom gradient + inset bevel shadows, NOT an accent wash — so the Swift selected state has drifted off-spec toward a blue tint.
- Icons are **mixed sources**: 4 custom `BridgeVectorIcon` glyphs (skills/tools/advanced/credentials, L242–245) at 18pt; the other 6 are SF Symbols via `section.icon` at **14pt** (L246). Two icon systems, two optical sizes, two stroke weights side by side in the same column — visibly inconsistent.
- Icon color: selected `fg1`, idle `fg4` (L215). Label: selected `fg1`, idle `fg3` (L218). Reasonable two-tone.
- Keyboard nav (↑/↓, clamped) is wired (L183–200) with `focusEffectDisabled` to kill the system focus ring — good.
- Background: faint top-down hairline gradient (L168) + a trailing 0.5px `hairline` rule (L172). Clean.

### Findings
| Finding | Severity | Recommendation |
|---|---|---|
| 10 items, in "most-visited" order, no grouping | 🟡 Moderate | Collapse to **7** in conceptual-flow order (see §1a). Merges are display+routing only. |
| Selected = accent wash **+** border (two signals) | 🟡 Moderate | Pick one. Match SSOT: white-gradient fill + inset bevel; or keep a single `selectionFill` (L198) flat fill. Drop the redundant stroke or the accent tint — not both. |
| Two icon systems at two sizes (18pt vector vs 14pt SF) | 🟡 Moderate | Normalize to one optical size in the 18×18 frame. Either promote all 7 to custom vector glyphs, or render SF Symbols at the same ~15px the vectors occupy so the column reads as one set. |
| 30px rows are comfortable but the 10-row list nearly fills the column | 🟢 Minor | At 7 rows the column breathes; no need to shrink row height. Keep 30px (legibility floor friendly). |
| Item label 13px | 🟢 Good | Above the 11–12px floor. Keep. |

### 1a. Locked 7-item sidebar — conceptual-flow order
**Orders · Skills · Jobs · Tools · Security · Connection · Advanced**

| # | Display label | Composed from (current sections) | Icon |
|---|---|---|---|
| 1 | **Orders** | Standing Orders (rename, display-only) **+ Commands folded in** | `scroll` / bow-style vector |
| 2 | **Skills** | Skills | custom vector (bow & arrow) |
| 3 | **Jobs** | Jobs | `clock.badge.checkmark` |
| 4 | **Tools** | Tools | custom vector (crossed tools) |
| 5 | **Security** | **Credentials + Permissions merged** | `lock.shield` (or key vector) |
| 6 | **Connection** | **Connections + Remote Access merged** | `network` |
| 7 | **Advanced** | Advanced | custom vector (two gears) |

Notes for the implementer:
- "Orders," "Security," "Connection" are **display labels**; the underlying section identities/routing can stay distinct internally (sub-tabs or stacked cards inside the merged pane). The breadcrumb removal (§2) means the sidebar label is the only place these names render in chrome, so the label rename is low-risk.
- Standing Orders → **Orders** is a pure `rawValue` display change. Commands folds into the Orders pane as a sub-section, not its own row.

---

## 2. Title Bar (`BridgeTitleBar`, L265–284)

### Current state
- **44px** tall (L279), full-width, **centered** breadcrumb: `The Bridge › {section}` (L271–274) at 13px semibold, colored fg4 / fg5 / fg2.
- A **0.5px bottom hairline** divider (L280–282).
- Window is `fullSizeContentView` (L71) with `titlebarAppearsTransparent = true` (L82) and `titleVisibility = .hidden` (L83), `toolbarStyle = .unified` (L81). So the SwiftUI title bar is drawn UNDER the native traffic lights, and the 44px exists to clear them.

### Findings
| Finding | Severity | Recommendation |
|---|---|---|
| Centered breadcrumb collides conceptually with native traffic lights (top-left) and wastes the left gutter | 🟡 Moderate | **Left-align** the title; reserve the left ~78px for traffic lights, start text after. |
| Breadcrumb triples the section name (sidebar row + this + in-pane hero) | 🟡 Moderate | **Section-name-only.** Drop "The Bridge ›". One word, e.g. "Connection". |
| Bottom hairline boxes the title off from the canvas | 🟢 Minor (locked) | **Remove** the hairline (L280–282). Title floats on the stage. |
| 44px height for a single 13px line is loose | 🟢 Minor (locked) | Trim toward **~38px**. Must still clear traffic lights (see geometry below). |

### Locked geometry
- **Height: 38px.** Native traffic lights on a standard window are ~12px dots vertically centered in a ~28px band; with `fullSizeContentView` they sit at the very top-left. 38px gives ~13px above/below a 12px dot — ample clearance. Do **not** go below ~36px or the lights crowd the title baseline.
- **Alignment: leading.** Left inset = **76px** (clears the three 12px lights + their 8px gaps + edge padding ≈ 70–78px). Confirm against the live traffic-light frame; `78` is the safe value the `.titlebar` SSOT pads from edge with `0 14px` plus the traffic cluster.
- **Content:** `Text(section.displayName)` only. 13px **semibold**, color `fg2` (titlebar-title rank, BridgeTokens L162). No "The Bridge ›" prefix, no `›` glyph, no fg4/fg5 crumb spans.
- **No bottom divider.** Delete the `.overlay(alignment: .bottom)` hairline.
- **Background:** transparent (inherits `BridgeStage`). Keep it part of the draggable region.

### macOS titlebar constraints (carry into spec)
- `titlebarAppearsTransparent = true` + `titleVisibility = .hidden` + `.fullSizeContentView` are **already set** (L71, 82–83) — keep all three. They are what let custom content sit beside the lights.
- The traffic-light cluster position is **owned by AppKit**, not SwiftUI. Don't try to move it; just leave its 76–78px gutter clear.
- Because content is full-size, the title bar must remain inside a draggable area. With `titleVisibility=.hidden` the whole transparent titlebar stays draggable by default — keep the title `Text` non-interactive so the drag passes through.

---

## 3. Foot Bar (`BridgeFootBar`, L287–307)

### Current state
- **30px** tall (L300), horizontal pad 14 (L300).
- "The Bridge" (fg4) on the left, version string (fg4) + a glowing `ok` status dot (7px + shadow) on the right (L292–298), 11px font.
- Has its **own `chipFill` background** (L302) AND a **0.5px top hairline** (L303–305) — so it reads as a separate slab docked to the bottom, not part of the canvas.

### Findings
| Finding | Severity | Recommendation |
|---|---|---|
| `chipFill` background makes it a visible slab | 🟢 Minor (locked) | **Remove** `.background(BridgeTokens.chipFill)` — blend with `BridgeStage`. |
| Top hairline boxes it off | 🟢 Minor (locked) | **Remove** the top hairline overlay (L303–305). |
| "The Bridge" label is redundant footer chrome | 🟢 Minor | Optional: drop it; the window already identifies the app. If kept, keep it fg4/quiet. Locked decision only requires keep version + dot. |
| Status dot is always `ok` (green) | 🟢 Minor | Confirm it's wired to real server status, not a static green. If static, either wire it or demote to neutral. (Out of strict chrome scope; flag.) |
| 11px font | 🟢 Borderline | At the 11px floor — acceptable for passive meta, but don't go smaller. |

### Locked spec
- Height **30px** (keep). Horizontal pad **14**.
- **No background fill, no hairline.** Transparent; sits directly on the stage.
- Keep **version string** + **status dot** on the right. Left "The Bridge" optional.
- Font 11px, color `fg4`. Dot: 7px, `ok`/`warn`/`bad` per real status, soft glow OK.

---

## 4. Per-Page Section Header (the third header)

There are **two** header mechanisms, and the redundancy is the core density problem.

### 4a. `BridgeSettingsSectionHeader` (BridgeSettingsSectionHeader.swift)
- A `BridgeGlassCard` containing: **44×44** tinted circle + 18pt SF icon, an 18px-semibold title, a 12px subtitle (fg3), optional trailing accessory (L36–57).
- Presets per section (L107–181) give each a tint (NotionPalette green/orange/blue/purple/gray/etc.) + copy. The header itself doesn't branch — clean component design.
- **But** the doc comment claims "5 callers" (Connections, Credentials, Permissions, Jobs, Advanced) while the sections actually roll their **own** in-pane "hero" (e.g. `ConnectionsSection.hero`, ConnectionsSection.swift L60–70: a `BridgeGlassCard` with a 50×50 orb + status). So in practice each page builds a bespoke hero card AND the breadcrumb titlebar AND the sidebar label all name the same thing.

### Findings
| Finding | Severity | Recommendation |
|---|---|---|
| **Three** titles per page (titlebar breadcrumb + in-pane hero title + sidebar row) | 🔴 Critical (density) | After §2 trims the breadcrumb to section-name-only, **demote the in-pane hero**. The hero should carry *status/affordances* (orb, health, primary action), not re-print the section name at 18px. Let the 38px titlebar be the page title. |
| Hero card is tall (44–50px tile + two text lines + card padding ≈ 76–90px) before any real content | 🟡 Moderate | Slim the hero: drop the big tinted icon tile OR the title line. Keep the orb/status + actions; move the subtitle into a one-line caption. Target ≤ ~56px. |
| 18px hero title vs 13px titlebar — the in-pane title is the loudest text, but the titlebar is the canonical page name | 🟡 Moderate | If the hero keeps a title, demote to ≤15px or remove; the 38px titlebar (fg2 semibold) is now the page H1. |
| Header tints (per-section colors) add chroma the carbon system otherwise reserves for signals | 🟢 Minor | Optional: mute the per-section tint tiles; the design tenet is "color enters only via accents + signals" (BridgeTokens L9, L120). |

### 4b. Pane padding inconsistency
Across sections the content wrapper drifts:
- `.padding(20)` — Connections, Permissions, Commands, Advanced, Standing Orders (e.g. ConnectionsSection.swift L51).
- `.padding(18)` — Credentials (L61), Jobs (L74), Skills (L35), Remote Access (L175).
- SSOT `.pane` (kit.css L85) is `padding:18px 22px` (asymmetric: 18 vertical, 22 horizontal) — **neither** Swift value matches.
- All use `VStack(spacing: 14)` consistently (matches `.pane gap:14px`). Good.

| Finding | Severity | Recommendation |
|---|---|---|
| Pane padding is 18 in some sections, 20 in others, 18×22 in SSOT | 🟡 Moderate | Pick **one** pane padding token and apply everywhere. Recommend `pane: 18 vertical / 20 horizontal` (or honor SSOT 18/22). Add it to a spacing scale (see §6). |
| Inter-card spacing 14 is consistent | 🟢 Good | Keep; promote to a `gap` token. |

---

## 5. Overall Window Density & the Wasted-Space Problem

- Window opens at **1080×880** content (L80), min 760×600, no frame autosave (resets each launch, L84–88). Square-ish, deliberate.
- **Vertical chrome budget today:** 44 (titlebar) + 30 (footbar) + ~80 (in-pane hero) = **~154px** consumed before a single real control, on a window whose content area is ~880px. That's ~17% of height spent restating the page name and bracketing it with two rules and two slabs.
- **The redesign reclaims roughly 40–60px** with no content loss:
  - Titlebar 44→38 (−6) and the breadcrumb→section-name (visual de-clutter).
  - Foot bar de-slab (−0 height but removes 2 rules + 1 fill → reads ~10px lighter).
  - Hero demotion (−~24px once it stops re-printing the title).
- **First impression today:** the eye lands on the loud 18px in-pane hero title, NOT the canonical titlebar — the hierarchy is inverted. The locked changes fix this: titlebar becomes the page H1, hero becomes status/actions.
- **Hairline inventory** — the shell currently draws hairlines at: titlebar bottom (L281), sidebar trailing (L172), footbar top (L304), plus every card edge. The locked changes remove two of the three full-width horizontal rules (titlebar + footbar), leaving the vertical sidebar rule as the one structural divider. This is the right call — fewer boxes, more canvas.

---

## 6. Missing: a spacing scale

`BridgeTokens` has colors (L64–206) and **`Radius`** (L210–216) but **no spacing scale**. Every pad/gap is a magic number (`.padding(20)`, `spacing: 14`, `padding(.horizontal, 9)`, `height: 30`), which is exactly why pane padding drifted 18↔20. The redesign should introduce a `BridgeTokens.Space` enum so chrome geometry is named and consistent.

Proposed (additive, names only — no code here):
- `Space.paneV = 18`, `Space.paneH = 20`, `Space.cardGap = 14`, `Space.navItemH = 30`, `Space.titleBar = 38`, `Space.footBar = 30`, `Space.trafficGutter = 78`.

---

## What Works Well
- **Single selection source of truth** (`nav.section`) drives sidebar + titlebar + detail switch — deep-link safe, clean (SettingsWindow.swift L213–244).
- **System-tethered appearance** is genuinely well-engineered: dynamic NSColor resolvers give free live light/dark adaptation in both SwiftUI and AppKit (BridgeTokens L38–51, L137–152).
- **Custom vector glyphs** (BridgeIconShape, L80–141) are crisp, on-grid (24-unit), and inherit nav state color.
- **Keyboard nav with suppressed focus ring** (BridgeShell L178–200) restores what the native sidebar gave for free without the ugly blue outline.
- **Ink ranks** (fg1–fg5, L161–165) are a disciplined, well-documented typographic gray scale — reuse them, don't invent new opacities.
- **Card gap 14** is already consistent across all sections.

---

## Priority Recommendations
1. **Kill the triple-header (density).** Trim titlebar to 38px section-name-only left-aligned (no hairline), and demote each in-pane hero from "title card" to "status/actions card." This is the single biggest legibility + density win and fixes the inverted hierarchy. (§2, §4)
2. **Collapse the sidebar 10→7 in conceptual-flow order** and unify its icon set + selected state (one fill, one icon size). (§1)
3. **De-slab the foot bar** (remove fill + top hairline) and **standardize pane padding** via a new `BridgeTokens.Space` scale so 18/20/22 drift can't recur. (§3, §4b, §6)
