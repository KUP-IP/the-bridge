# Skills Page — UI/UX Design Audit

> Scope: Settings → **Skills** section of The Bridge (macOS SwiftUI menu-bar app, MCP connector).
> Method: `design:design-critique` rubric applied against current source, read-only.
> Sources audited:
> - `NotionBridge/UI/Sections/SkillsSection.swift` (pane scaffold: hero + cache card + embedded master–detail)
> - `NotionBridge/UI/SkillsView.swift` (twin master–detail: list column + detail column)
> - `NotionBridge/UI/BridgeShell.swift` (chrome: stage, secnav, titlebar, footbar)
> - `NotionBridge/UI/BridgeThemeV2.swift` + `NotionBridge/UI/BridgeTheme.swift` (BridgeGlassCard, BridgeCardLabel, BridgeBadge, BridgeSpacing)
> - `NotionBridge/UI/BridgeTokens.swift` (color/radius SSOT mirror)
> - `NotionBridge/UI/Sections/BridgeSettingsSectionHeader.swift` (the shared 5-caller hero pattern Skills does NOT use)
> - `design/design-system/project/ui_kits/the-bridge/kit.css` (visual SSOT)
> Conformance target: LOCKED redesign — sidebar 10→7 (Orders · Skills · Jobs · Tools · Security · Connection · Advanced; Skills keeps its own section), GLOBAL DENSITY TENET (tighten vertical rhythm + padding; legibility floor ≥ 11–12px), chrome = section-name-only left-aligned titlebar with no divider, slim integrated footbar.

---

## Overall Impression

The Skills page is the most *materially* finished pane in the app — the twin master–detail is the right information architecture, the routing/palette mental model is well-explained, and the status-dot semantics are thoughtful. But it is also the single biggest **space waster** in Settings, and it fights the locked chrome decisions on three fronts: (1) a redundant in-pane hero that re-states the section name the titlebar already shows, (2) a hard-coded `560 px` detail viewport stacked *inside* an outer `ScrollView`, producing a nested-scroll trap, and (3) ~140–170 px of fixed vertical chrome (hero + cache card + outer padding) before the user reaches a single skill. Against the density tenet this page needs the most aggressive compaction in the redesign.

The biggest opportunity: **collapse the three stacked cards (hero → cache → master-detail) into one full-height master–detail surface**, move the section identity to the titlebar (already rendered), demote the cache action and stat counts into a slim toolbar above the list, and let the detail pane own the vertical space instead of a magic `560`.

---

## Usability

| Finding | Severity | Recommendation |
|---|---|---|
| **Nested scroll trap.** `SkillsSection.body` wraps everything in a `ScrollView` (L24), then `SkillsView.body` pins the master–detail to `.frame(height: 560)` (L85), and *both* the list (L203) and detail (L408) columns are their own `ScrollView`s. Three scroll contexts compete; the outer one scrolls the hero/cache off-screen while the inner 560-px window scrolls skills. Trackpad momentum will hijack the wrong scroller depending on cursor position. | 🔴 Critical | Kill the outer `ScrollView`. Make the master–detail the page body at `maxHeight: .infinity`. Only the list and detail columns scroll. |
| **Fixed `560` detail height** (`SkillsView.swift:85`) ignores window height. On a tall window the page leaves dead space below; on a short one the master–detail clips. The min window is `760×600` (`SettingsWindow.swift:226`) but the page does not adapt above that. | 🔴 Critical | Drive height from the container (`maxHeight: .infinity`), not a literal. |
| **Two titles for one section.** Chrome already renders "The Bridge › Skills" (`BridgeTitleBar`, `BridgeShell.swift:265–284`) and the in-pane hero renders a 22 px "Skills" again (`SkillsSection.swift:57`). Per the locked chrome decision (titlebar = section-name-only, left-aligned), the in-pane hero title is pure duplication. | 🟡 Moderate | Drop the hero. Keep its two stat tiles + the section blurb, relocated into a slim list-column toolbar / footer (counts already live in `listFooterText`, L281). |
| **Add affordance is a bare `+` glyph** (`SkillsView.swift:183–196`), 14 px SF Symbol, no text label. First-run users on an empty list must infer "add" from an icon; the empty state's "Add a skill" button (L451) is the clearer path but is in the *other* column. | 🟡 Moderate | Keep the `+` but give it a tooltip-confirmed primary tint when the list is empty, or pair it with the empty-state CTA so there is one obvious add path. |
| **Reorder is detail-pane-only.** Move-up / move-down live in `detailActions` (L655–663) — you must *select* a skill, then reorder from the right pane while watching the left list jump. There is no drag-to-reorder on the list rows themselves. | 🟡 Moderate | Add list-row drag reorder (`.onMove`-style), or at minimum surface up/down on hover in the row. The detail-pane chevrons are an indirect, high-friction path. |
| **Sort is a tiny unlabeled icon** in the list footer (`arrow.up.arrow.down`, L249), 11 px, easy to miss; it silently mutates persisted order. | 🟢 Minor | Fine to keep small, but pair with a tooltip (present) and consider a confirm-free undo, since it overwrites manual order. |
| **Cache card is a full-width glass slab** for a single occasional action (`SkillsSection.swift:98–131`). It consumes a whole card row above the actual content for a maintenance button most users press rarely. | 🟡 Moderate | Demote to a small "Refresh cache" button in the list toolbar (with the spinner + inline result as a transient toast/caption), freeing a full card height. |
| **Inline edit commit is implicit.** `commitPendingEdit()` fires on row-switch / add / reorder (L293, L580, L657…), so a half-typed URL/rename auto-commits when you click away. Good for flow, but there is no visible "unsaved" affordance and `onExitCommand` cancels — the two escape paths (click-away = commit, Esc = cancel) are inconsistent. | 🟢 Minor | Make commit-on-blur explicit (checkmark) or align Esc and click-away semantics. |
| **`triggerPhrases` / `antiTriggerPhrases` are read-only in the UI.** The empty-trigger hint tells the user to go use the `manage_skill` MCP tool (L485, L508). A settings pane that can add/rename/delete/toggle skills but cannot edit the field that drives *routing* is a capability gap. | 🟡 Moderate | Out of scope for a pure visual redesign, but flag: triggers are the highest-value routing lever and are uneditable here. At least make the chips look non-interactive (they currently read as tappable, see Consistency). |

---

## Visual Hierarchy

- **What draws the eye first:** the hero's 50×50 accent-tinted icon tile + 22 px "Skills" (`SkillsSection.swift:46–59`). This is wrong — it is the lowest-information element on the page (the titlebar already names the section), yet it has the largest type and a saturated accent fill. The user's first fixation lands on a label they already read in the chrome.
- **Intended primary object:** the skill list + detail. These start ~150 px down the page, below hero and cache card.
- **Reading flow:** top-to-bottom the eye crosses hero → stat tiles → cache card → *then* the master–detail, i.e. two decorative/utility rows before the actual subject. Inside the master–detail the flow is correct (list left → detail right).
- **Emphasis problems:**
  - Stat tiles (`statTile`, L77–90) use 18 px **monospaced** numerals in gold/emerald — visually loud for two counts that duplicate `listFooterText` ("x/y enabled · z routing", L281–287). Two sources of the same truth, the louder one less useful.
  - In the detail pane the **metadata grid** (`metadataGrid`, L670–689) is an 8-cell 4-column LazyVGrid where 4 of 8 cells restate booleans already shown elsewhere: "Status" duplicates the Enabled toggle, "In palette"/"In routing" duplicate the two permission toggles below, "Triggers"/"Anti-triggers" counts duplicate the chip section. Half the grid is redundant, diluting the cells that matter (Platform, Visibility, Page ID).
  - Detail name is 21 px (L575) while the hero name is 22 px (L58) — two near-identical "page titles" 150 px apart.

**Net:** hierarchy inverts importance — chrome/identity is loudest, the working surface is quietest and pushed down.

---

## Consistency

| Element | Issue | Recommendation |
|---|---|---|
| **Hero pattern divergence** | Skills hand-rolls its own hero (`SkillsSection.swift:43–71`) with a 50×50 **rounded-rect** accent tile, while the shared `BridgeSettingsSectionHeader` (used by Connections/Credentials/Permissions/Jobs/Advanced) uses a 44×44 **circle** tile at 18 px icon (`BridgeSettingsSectionHeader.swift:37–45`). A `.skills` preset already exists in `BridgeSettingsHeaderPreset` (L160–166, tint `NotionPalette.yellow`) but Skills ignores it. | If any hero survives the redesign, adopt the shared component or its tokens. Right now Skills is the odd one out. |
| **Section title size** | Hero "Skills" is 22 px (L58); the shared header title is 18 px (`BridgeSettingsSectionHeader.swift:49`) and kit.css `.hero-title` is **18px** (kit.css L100). Skills is 4 px over the SSOT. | Conform to 18 px if a title remains — but the locked chrome decision removes the in-pane title entirely. |
| **Hero subtitle size** | 12.5 px (L61) matches kit.css `.hero-sub` (12.5px, L101) ✔, but `BridgeSettingsSectionHeader` subtitle is 12 px (L52). Minor drift between the two hero idioms. | Pick one (12 or 12.5) system-wide. |
| **Stat-tile radius** | 10 (L88) vs the meta-cell radius 9 (L705) vs card 12 (`BridgeTokens.Radius.card`) vs chip 13/999. Four radii for small wells on one page. | Standardize small wells to a single radius (kit.css meta-cell = 9; stat-tiles should match). |
| **Trigger chips look interactive but aren't** | `chipFlow` chips (L940–955) use `BridgeTokens.chipFill` + hairline, visually identical to kit.css `.chip` which has `cursor:pointer` + `:hover` (kit.css L131–135). In SwiftUI they have no action → they look clickable but do nothing. | Give read-only chips a flatter, non-pill treatment, or wire them to edit. Don't borrow the interactive `.chip` look for static data. |
| **Raw `Color.black.opacity(0.10)` for list column bg** | `listColumn.background(Color.black.opacity(0.10))` (L259) bypasses BridgeTokens. On the **light/titanium** appearance this paints a dark wash on a light ground — exactly the regression the adaptive `wellFill`/`hairline` tokens were created to prevent (`BridgeTokens.swift:182–206`). | Use `BridgeTokens.wellFill` (adaptive: `black@.22` dark / `black@.05` light) or `bgRaised`. Never hardcode black-at-alpha. |
| **Raw `Color.white` on the add button glyph** | `+` glyph uses `Color.white` when active (L189). In light mode white-on-accent is fine (accent is royal blue in both schemes) but the token for that is `BridgeTokens.onAccent` (`BridgeTokens.swift:76`), which exists precisely so call-sites stop using bare white. | Use `BridgeTokens.onAccent`. |
| **`.font(.caption)` / `.caption2` escapes the px scale** | Cache message uses `.font(.caption)` (L116); `BridgeBadge` uses `.caption2` (`BridgeTheme.swift:140,143`). Everything else on this page is explicit `.system(size:)`. Dynamic Type can push caption above/below the surrounding fixed sizes, breaking rhythm. | Use explicit sizes consistent with neighbors (cache msg ~11.5, badge ~11 per kit.css `.badge`). |
| **Two divider idioms** | `Divider().overlay(BridgeTokens.hairline)` (L200, 236) vs hand-rolled `tokenDivider` = `Rectangle().fill(hairline).frame(height:0.5).padding(.vertical,10)` (L965–970). Same visual, two implementations, different surrounding padding. | One divider primitive. |
| **Stat tile numerals monospaced; meta values not** | Stat tiles use `.monospaced` (L80); meta-grid values use default (L698). Both are numeric/status fields. | Tabular-nums consistently for counts (kit.css uses `font-variant-numeric:tabular-nums` on count pills). |

---

## Density / Space-Waste (the headline issue)

Vertical budget *before any skill is visible*, current:

| Band | Source | Approx height |
|---|---|---|
| Outer pane padding (top) | `.padding(18)` (`SkillsSection.swift:35`) | 18 |
| Hero card | icon 50 + card padding 14×2 (`BridgeGlassCard` default, `BridgeThemeV2.swift:56`) | ~78 |
| Inter-card gap | `VStack(spacing: 14)` (L25) | 14 |
| Cache card | ~16 icon + 14×2 padding + 2-line text | ~62 |
| Inter-card gap | 14 | 14 |
| Master–detail toolbar (search row) | `.frame(height:32)` + `.padding(.vertical,11)` (L179, 198) | ~54 |
| **Total chrome before first skill row** | | **~240 px** |

On the 600-px min window that is **40% of the viewport** spent before the first skill. The master–detail itself is then boxed to a *fixed* 560 inside a scroller, so the page is simultaneously cramped (list) and wasteful (outer dead space).

Specific space-waste offenders:
1. **Hero card** — ~92 px (card + gap) for a duplicate title + a blurb + two counts. The counts already exist in `listFooterText`. → reclaim ~92 px.
2. **Cache card** — ~76 px (card + gap) for one occasional button. → demote to a toolbar button, reclaim ~76 px.
3. **Outer padding 18 on all sides** (L35) — heavier than the density tenet wants; the master–detail already has internal column padding. → drop outer padding to ~0 (page should be edge-to-edge under the titlebar) and let columns own their insets.
4. **List rows are 8 px vertical padding + ~28 avatar = ~44 px tall** (`skillListRow`, L314). Acceptable but the 28-px avatar (a generic SF Symbol in a radial-gradient circle, `avatar`, L384–402) is decorative weight; a 7 px platform-tinted dot or a 16 px monochrome glyph would shave each row and de-noise the list.
5. **Detail header avatar is 48 px** (`avatar(big:true)`, L385) beside a 21 px name + badges — a large decorative circle for an SF Symbol that conveys only "platform," already stated by the badge two lines down.
6. **Metadata grid 8 cells × ~52 px in 4 cols = two rows ~120 px**, half redundant (see Hierarchy). → 4 meaningful cells, one row, ~60 px.

Density target after redesign: chrome-before-first-skill from ~240 px → **~56 px** (just the slim list toolbar), master–detail filling the rest of the window.

Compaction must respect the **legibility floor**: smallest body text on the page today is 9 px uppercased meta-captions (`metaCell` L693–696, `formField` L920, list platform tag L307) and the file-source section label (L215). **9 px is below the 11–12 px floor** for the redesign — these tracked-uppercase micro-labels read as texture, not text. Raise meta-caps to ≥ 10.5 px (kit.css `.meta-cap` is 10.5px, L313) and reconsider the 9 px platform tags entirely (the status dot + badge already carry that info).

---

## Accessibility

- **Color contrast — caption ranks on glass:** `fg4` is `white@0.46` (dark) / `black@0.48` (light) (`BridgeTokens.swift:164`). At 9 px tracked uppercase (meta-caps, platform tags) this is well under WCAG AA for the effective contrast against the glass card tint. `fg5` (`white@0.34`, L165) is used for the list platform tag (L309) and disabled names (L303) — borderline-to-failing even at larger sizes. → raise size and/or rank for these micro-labels.
- **Status communicated by color + dot only.** `statusDot` (L358–369) encodes routing/palette/enabled/disabled purely as emerald/amber/blue-grey/faint hues on a 7 px circle. No shape, label, or text alternative → fails for color-blind users and is invisible to VoiceOver. The list rows are `Button`s with no `accessibilityLabel`/`accessibilityValue` describing status. → add an accessibility value ("Routing-discoverable, enabled") and consider a glyph-differentiated dot.
- **Touch / hit-area targets:** search field 32 px ✔, add button 32×32 ✔, detail icon buttons 30×30 (`iconButton`, L996) ✔ — all meet a ~28–30 px min. But the **list footer sort button** is an 11 px glyph with no explicit frame (L249–252) → hit area ≈ the glyph itself, under the min. The **detail rename pencil** (L585) and **idRow link button** (L622) likewise have no padded frame. → give all icon-only controls a ≥ 28 px hit frame.
- **VoiceOver structure:** unlike the shared `BridgeSettingsSectionHeader` (which sets `.isHeader` + a combined element, `BridgeSettingsSectionHeader.swift:48–62`), the Skills hero and detail headers set no header traits, so a VoiceOver rotor has no section landmarks. Permission toggles use `Toggle("", …).labelsHidden()` (L984–987) with the title in a *separate* `Text` — the toggle announces as an unlabeled switch. → bind the title as the toggle's accessibility label, or use a labeled toggle.
- **Keyboard:** the secnav restores arrow-key nav (`BridgeShell.swift:178–185`), but inside Skills the list is `LazyVStack` of `Button`s (L204) with no arrow-key traversal or focus ring — keyboard users can Tab through but not arrow through the list, and selection has no visible focus state distinct from the gradient selection fill.
- **`.help()` tooltips** are good and present on most icon buttons (L196, L254, L590, L642, L1004) — keep these.

---

## List / Row Design (skills: routing, triggers, status)

**Master row anatomy** (`skillListRow`, L290–320): `[28 avatar] [name 13px / PLATFORM-TAG 9px] —spacer— [7px status dot]`, 10 px h-padding, 8 px v-padding, 2 px row spacing (`LazyVStack(spacing:2)`, L204).

Strengths:
- Name truncates tail (L304–305) ✔, dimming for disabled skills via `dimmed` (L299, L335) ✔, selection gradient + rim (`rowBackground`/`rowRim`, L371–382) ✔.
- The four-state status dot (`statusDot`, L356–369) is a genuinely good compression of routing/palette/enabled into one glyph.

Weaknesses:
- **The 28 px avatar is decorative weight per row.** It is a generic SF Symbol in a radial-gradient circle conveying only platform — which is *also* the 9 px tag right beside it and (in detail) a badge. Two encodings of platform, one of them a heavyweight circle. → replace with a compact monochrome platform glyph or fold platform into a single leading dot whose color = platform, status = a trailing pip.
- **9 px uppercased platform tag** (L306–309) is below the legibility floor and in `fg5` (the faintest ink). It reads as noise. → either lift to ≥ 11 px or drop it (badge in detail already covers platform).
- **Status is dot-only** (no text, no a11y value) — see Accessibility.
- **File-source rows** (`fileListRow`, L322–353) duplicate the entire row builder with a different secondary line ("USER FILE"/"BUNDLED") and a plain status dot (no shadow, no 4-state logic, L344–346). Two near-identical row implementations → unify into one row that takes a source/status descriptor.
- **Section header "FILE-SOURCE"** is 9 px tracked (L214–215) — micro-label, same floor problem.

**Triggers / anti-triggers** (`chipFlow` + `FlowLayout`, L940–955, L1201–1240): the flow-wrap is correct and the anti-trigger red treatment (L945, 949, 952) reads clearly. But (a) chips imitate the interactive kit.css `.chip` while being static (see Consistency), and (b) the empty state points users to an MCP tool rather than offering inline edit (see Usability). The 26 px chip height matches kit.css `.chip` (L131) ✔.

**Routing metadata grid** (`metadataGrid`, L670–707): 4-col × 8-cell. ~Half the cells are redundant with the toggles/chips. Visibility cell logic (`visibilityLabel`, L709–716: Both/Routing/Palette/Fetch-only) is the one genuinely synthesizing cell and should be elevated, not buried as 1 of 8 equal tiles.

**Status semantics summary (keep — they're good):**
| State | Dot color | Token |
|---|---|---|
| Disabled | faint grey | `fg5` |
| Routing-discoverable | emerald | `ok` |
| Palette-only | amber | `warn` |
| Enabled, neither | blue-grey | `accentLink` |

---

## What Works Well

- **Information architecture.** Master list + detail is the right model for a growable, per-item-configurable collection; far better than the old flat list.
- **Routing vs Palette mental model** is explicitly taught (permission toggle subs L529–549, the "How visibility works" card L904–914, `visibilityLabel`). This is genuinely good UX writing for a subtle concept.
- **Cross-tab guard banners** (`banners`, L118–161) surface real failure modes (invalid page ID, fetch_skill disabled in Tools, empty palette) with correct warn/info tones — proactive, contextual.
- **Four-state status dot** compresses a 2×2 capability matrix into one glyph elegantly.
- **Destructive delete behind a confirm alert** (L97–113) with copy clarifying the Notion page is untouched — correct safety posture.
- **Empty/placeholder states exist and are differentiated** (`emptyListState` L262, `detailPlaceholder` L436, "No skills yet" vs "Select a skill") — most panes skip these.
- **Tooltips on icon controls** and **dimming for disabled items** are consistent.

---

## Priority Recommendations

1. **Collapse to one full-height master–detail surface; remove the outer ScrollView, hero, and cache card.** Move section identity to the (locked) titlebar, relocate the two stat counts + the Refresh-cache action into a slim list-column toolbar, and drive the master–detail height from the container (`maxHeight:.infinity`) instead of the literal `560`. This fixes the nested-scroll trap, reclaims ~240 px of pre-content chrome, and satisfies the density tenet in one move. *(Files: `SkillsSection.swift:24–36, 43–131`; `SkillsView.swift:73–86`.)*

2. **De-duplicate the detail pane.** Cut the metadata grid from 8 cells to the ~4 non-redundant ones (Platform, Visibility, Page ID, Source), and let the permission toggles + trigger chips be the single source for the booleans they already show. Elevate the synthesized **Visibility** value. Shrink the 48-px detail avatar. *(Files: `SkillsView.swift:670–707, 554–603`.)*

3. **Fix the token + floor violations.** Replace `Color.black.opacity(0.10)` (L259) with `wellFill`, the add-button `Color.white` (L189) with `onAccent`, and raise every 9 px tracked micro-label (platform tags L307, meta-caps L693, form labels L920, "FILE-SOURCE" L215) to ≥ 10.5–11 px or remove them. Add accessibility values to status dots and labels to permission toggles. *(Files: `SkillsView.swift` throughout; `BridgeTokens.swift` for the tokens.)*

---

## Appendix — Conformance to Locked Decisions

- **Sidebar 10→7 / Skills keeps its own section:** ✔ no merge required; this audit assumes Skills stays standalone at slot 2.
- **Density tenet:** current page is the worst offender (~240 px pre-content chrome, fixed 560 inner box). Recommendations above target ~56 px chrome + full-height content.
- **Legibility floor (≥ 11–12 px):** currently violated by 9 px tracked micro-labels in 6 places. Must lift.
- **Titlebar = section-name-only, no divider:** the in-pane hero title is now redundant with the (left-aligned, section-only) titlebar and should be removed; the titlebar bottom hairline removal is chrome-level (`BridgeShell.swift:280–282`), out of this page's scope but noted.
- **Footbar slim/integrated:** chrome-level (`BridgeShell.swift:287–307`), out of scope; the cache-refresh status could optionally live as a transient footbar message instead of an in-card caption.
