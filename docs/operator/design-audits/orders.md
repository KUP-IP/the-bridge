# Orders Page — Design Audit

**Scope:** The merged **Orders** section = "Standing Orders" doctrine (renamed, display-only) + **Commands** folded in as a sub-area.
**Sources audited:**
- `NotionBridge/UI/Sections/StandingOrdersSection.swift` (712 lines)
- `NotionBridge/UI/Sections/CommandsSection.swift` (238 lines)
- `NotionBridge/UI/Sections/CommandsEditorView.swift` (637 lines)
- Shared chrome: `NotionBridge/UI/BridgeShell.swift`, `NotionBridge/UI/Sections/BridgeSettingsSectionHeader.swift`, `NotionBridge/UI/BridgeThemeV2.swift`, `NotionBridge/UI/BridgeTokens.swift`, `NotionBridge/UI/SettingsWindow.swift`

**Method:** `design:design-critique` rubric (first impression → usability → hierarchy → consistency → accessibility), then a merge-target proposal. Source is read-only; this is a spec, not a patch.

---

## Overall Impression

Two well-built, visually-polished panes that are each ~30% too tall for what they say. Both lead with an oversized hero (`size: 22` title + `50×50` icon tile + stat tiles) that duplicates the new titlebar's job, then stack full-width `BridgeGlassCard`s at `spacing: 14` / `padding(20)`. They are internally consistent with each other but **diverge from the shared `BridgeSettingsSectionHeader`** that the rest of the app standardized on (44px circle, `size: 18` title) — so merging them is also a chance to bring Orders back onto the shared header contract. The biggest opportunity: collapse the two heroes into one section header + a tab strip, and reclaim the vertical budget the density tenet demands.

---

## 1. First Impression (2 seconds)

**Standing Orders.** Eye lands on the blue `scroll` orb (`50×50`, `accent@0.22` fill, `accentLink` glyph) and the gold token count. Purpose reads instantly ("Your portable identity… edit once, applied everywhere"). Good. But the hero consumes ~78px before any editable content, and the `22pt` title restates the titlebar/sidebar label verbatim.

**Commands.** Eye lands on the gold `⌘` orb (`50×50`, `gold@0.22`) and the master switch on the right. The hero subtitle and the *separate* "Global shortcut" card both explain the palette — the page spends two full cards (hero + shortcutCard ≈ 160px) before the actual command list. Purpose is clear but slow.

**Merged risk:** if both heroes survive the merge the page opens with ~160px of redundant chrome before the user can act. The merge must delete one hero outright.

---

## 2. Usability

| # | Finding | Severity | Recommendation |
|---|---------|----------|----------------|
| U1 | **Two separate top-level sections** for doctrine + commands; no relationship surfaced. After the merge they must share one page with an explicit Orders \| Commands switch. | 🔴 Critical (blocks the locked merge) | Two-tab page; tab strip directly under one shared header. Persist last tab via `@AppStorage`. |
| U2 | **Two heroes, two stat-tile clusters, two icon orbs** doing the same job the titlebar already does. | 🟡 Moderate | One `BridgeSettingsSectionHeader` (Orders, `scroll`, `NotionPalette.purple` per the existing preset). Per-tab stats move into a slim meta row. |
| U3 | StandingOrders `editorCard` is a fixed `height: 286` (L138) AND offers an "Open" full-overlay (L178) — two ways to get more room, neither resizable. The inline editor is cramped; the overlay is modal. | 🟡 Moderate | Keep the expand overlay (it works), but let the inline panel grow with the window instead of a hard 286. Min ~240, flexible above. |
| U4 | Commands `CommandsEditorView` is a master-detail with `minHeight: 560` (CommandsSection L48) inside a `ScrollView` that already scrolls — nested scroll + a tall floor on an 600px-min window means the list scrolls inside a page that also scrolls. | 🟡 Moderate | When Commands becomes a tab, give the master-detail the full pane height (no outer ScrollView wrapping it); only the two columns scroll internally. |
| U5 | The palette **master switch** (CommandsSection L84) lives in the hero with no label — only a `.help` tooltip. A destructive global toggle deserves a visible label. | 🟡 Moderate | Move into the Commands tab's meta row as a labeled `PartialToggle`/switch: "Command Bridge — On/Off". |
| U6 | "Open" full-panel overlay dims with `bgCanvas.opacity(0.6)` (L277) — a *fill*, not a blur; on light/titanium this is a pale wash that barely separates the float from the page. | 🟢 Minor | Increase scrim or add material; ensure the float reads as modal in light mode. |
| U7 | No save affordance in Preview mode — Save only exists in `.edit` (L220). Switching to Preview hides the only Save button; unsaved edits are silently stranded. | 🟡 Moderate | Surface Save state at the card level (footer), visible in both modes; show a dirty indicator. |
| U8 | Commands tray-preview dims non-selected bubbles to `opacity 0.42` (CommandsEditorView L412) — implies the popup only shows the selected favorite, which is untrue. Misleading preview. | 🟢 Minor | Render all favorites at full opacity; mark the *selected* one with a ring, not by dimming the rest. |

---

## 3. Visual Hierarchy

- **What draws the eye first:** the colored orb + stat tiles in each hero. Correct intent (status at a glance) but over-weighted — `22pt` semibold title competes with the editable body for top billing, and the title is redundant with the titlebar.
- **Reading flow (StandingOrders):** hero → editor (Preview/Edit) → Delivery audit → Templates. Logical, but Delivery audit and Templates push the *editor* (the actual job) into a small 286px window above the fold-line while telemetry/templates get full-height cards below. Priority is inverted: the editor should own the most vertical space.
- **Reading flow (Commands):** hero → Global shortcut → master-detail. The shortcut card is a single setting given a full glass card; the editor (the real work) is third.
- **Emphasis problems:**
  - `BridgeCardLabel` is `size: 11` + `tracking 1.2` uppercase (BridgeThemeV2 L114-122) — good, consistent label rank.
  - Stat-tile values are `size: 18` mono (StandingOrders L99) — heavier than the `BridgeCardLabel` headings on the same screen, so a metric outranks a section title.
  - Templates card uses `BridgeCardLabel("Templates")` + a long `size: 11` instruction string crammed beside it (L516-518) — the instruction wraps awkwardly next to the label in narrow widths.

**Recommendation:** demote heroes to the shared 44px header. Let the **editor** (doctrine on the Orders tab, master-detail on the Commands tab) be the tallest element. Telemetry (Delivery audit) and Templates become a secondary, collapsible zone, not equal-weight cards.

---

## 4. Consistency with the Design System

| Element | Issue | Recommendation |
|---------|-------|----------------|
| **Section header** | Both panes hand-roll a hero (`50×50` tile, `cornerRadius 14`, `22pt` title) instead of the shared `BridgeSettingsSectionHeader` (44px circle, `18pt` title, `size:12` subtitle). The header even already defines a `.standingOrders` and `.commands` preset (BridgeSettingsSectionHeader L146-159) that go unused. | Adopt `BridgeSettingsSectionHeader` with the `.standingOrders` preset; retire both bespoke heroes. Eliminates two icon-tile sizes and one title size from the page. |
| **Icon tile geometry** | Heroes use `RoundedRectangle(cornerRadius: 14)` `50×50`; shared header uses `Circle()` `44×44`. Two conventions for the same element. | Standardize on the shared circle. |
| **Title size** | `22pt` here vs `18pt` everywhere else via the shared header. | Drop to `18pt` (shared) — also frees vertical space. |
| **`Color.white` literals** | CommandsEditorView slot keys and tray use raw `Color.white.opacity(...)` (L293, L318, L326, L404) and `Color.black.opacity(...)` (L304). BridgeTokens explicitly says prefer tokens; these will not adapt cleanly in light mode (the comment-tokens like `selectionFill`, `chipFill`, `onAccent` exist for exactly this). | Replace selected-slot text `Color.white` → `BridgeTokens.onAccent`; sheens → token-based adaptive gradients. (Note: BridgeGlassBubble/PartialToggle already do the adaptive swap; the slot keys are the holdout.) |
| **Spacing scale** | Card spacing is inconsistent: StandingOrders `VStack(spacing: 14)` (L40), inner cards `spacing: 11/12/10`; Commands `spacing: 14`, editor `spacing: 13`. No shared spacing token (BridgeTokens has Radius but **no spacing scale**). | Define a spacing tenet for the redesign (see Density below) and apply uniformly. |
| **Stat tiles** | StandingOrders and Commands each redeclare an identical private `statTile(...)` (StandingOrders L96, Commands L95) — copy-paste, will drift. | One shared meta-stat component for the merged page. |
| **Save feedback** | StandingOrders uses inline colored text `saveMessage` (L223); Commands uses `saveMessage` too (CommandsEditorView L352) but also a status row with icon. Inconsistent save UX between the two areas that will now sit on one page. | Unify on one save/dirty pattern across both tabs. |

**What's already consistent (keep):** both use `BridgeGlassCard`, `BridgeCardLabel`, `wellFill`/`wellFillDeep` for sunken editors, `hairline`/`hairlineFaint` rules, signal tokens for status, `Radius.card/control`. The glass material language is solid and shared.

---

## 5. Density / Space-Waste (the global tenet)

The page is the prime offender the density tenet targets — after the merge, two surfaces share one pane, so reclaimed pixels are mandatory, not cosmetic.

**Current vertical budget (StandingOrders, top → editor content):**
- `ScrollView` `padding(20)` top = 20
- Hero `BridgeGlassCard` (`padding 14` + 50px tile) ≈ 78
- `VStack spacing 14`
- Editor card header (modeToggle row) ≈ 34 + `spacing 11`
- → **~157px before the doctrine text is reachable.** On a 600px-min window that's ~26% of height gone to chrome.

**Concrete density moves:**

| Token / value | Current | Proposed | Saving |
|---|---|---|---|
| Outer page padding | `padding(20)` (both, L48/L50) | `padding(16)` h, `14` top/bottom | ~12px/edge |
| Inter-card spacing | `VStack(spacing: 14)` | `spacing: 10` | ~4px × N cards |
| Hero | bespoke 78px hero ×2 | one shared 44px header (≈ 64px card) | ~14px + removes the 2nd hero entirely (~78px on the Commands side) |
| Editor inline height | fixed `height: 286` (L138) | flexible, `minHeight 240`, grows with window | reclaims dead space on tall windows |
| StandingOrders Delivery audit + Templates | two always-expanded full cards | collapse into a single "Audit & Templates" disclosure zone (default collapsed) | ~200px when collapsed |
| Command rows | `height: 42` (CommandsEditorView L140) | `36` | 6px × rows |
| Sidebar nav rows (context) | already `height: 30` (BridgeShell L223) — good reference density | match list rows toward this rhythm | — |

**Legibility floor (do NOT cross):**
- Body/preview text stays ≥ `12.5` (current SOMarkdownView paragraph L681) — keep.
- Labels/captions stay ≥ `11` (`BridgeCardLabel`, stat captions) — keep; do not shrink to 10 to save space.
- Command row name `13.5` (L125) → may drop to `13` but no lower.
- Hit areas: command rows ≥ 36px tall; icon buttons keep their `30×30` frame (StandingOrders L116, CommandsEditorView L223) — these are at the comfortable floor, do not shrink.
- Slot keys `46×46` (CommandsEditorView L296) are generously sized "keycaps" by design intent — may trim to ~40 but keep square + legible `17pt` digit.

**Truncate-with-reveal over shrink:** the Templates instruction string (L517) and command names already use `lineLimit` in places; apply consistently — 1-line truncate + `.help` tooltip rather than wrapping or shrinking type.

---

## 6. Accessibility

- **Contrast (dark/carbon):** primary inks `fg1 white@0.95` on `#0B0C0E` pass comfortably. `fg4 white@0.46` (stat captions, meta) on carbon ≈ borderline for small text — acceptable at `11pt` semibold but it's the floor; do not use `fg4`/`fg5` for anything the user must read.
- **Contrast (light/titanium):** the adaptive inks (`fg1 black@0.92` … `fg4 black@0.48` on `#ECEDEF`) are tuned and pass. The **risk is the `Color.white` literals** in CommandsEditorView slot keys/tray (L293/L318/L326/L404): selected-slot white text on `accent@0.9` royal blue is fine, but the white sheens over `bgRaised` in light mode can wash out — verify the unselected keycap digit `fg2` stays ≥ 4.5:1.
- **Touch/hit targets:** icon buttons `30×30`, slot keys `46×46`, command rows `42` — all adequate. The unlabeled palette master switch (U5) is reachable but has no visible label for VoiceOver beyond `.help`.
- **VoiceOver:** the shared header sets `.accessibilityElement(children: .contain)` + `.isHeader` (BridgeSettingsSectionHeader L48/L62) — adopting it improves the rotor vs. the current hand-rolled heroes, which add no header trait. StandingOrders freshness dots have `.help` but the *meaning* (emerald/amber/neutral) is color-only in the dot itself — pair with the existing text label (it does: "Fetched ✓") so it's not color-only. Good.
- **Keyboard:** the tab strip must be focusable + arrow-navigable to match the sidebar's `onMoveCommand` pattern (BridgeShell L183). The Commands master-detail should support arrow-key list navigation.
- **Focus ring:** follow the sidebar's `focusEffectDisabled()` + custom selection convention (BridgeShell L182) for the tab strip so the system blue ring doesn't fight the glass.

---

## 7. The Merged Orders Page — How It Should Look

**Structure (top → bottom):**
1. **One shared section header** — `BridgeSettingsSectionHeader(title: "Orders", subtitle: "Doctrine your clients load at session start, and the commands you fire from the Command Bridge.", systemImage: "scroll", tint: NotionPalette.purple)`. ~64px. No second hero.
2. **Tab strip** — `Orders | Commands`, reusing the StandingOrders `modeToggle` visual (segmented, `wellFill` track, `accent@0.18` selected pill, `12pt`) at full-section scope. Persist via `@AppStorage`. Right-aligned on the same row: the **per-tab meta** (Orders → token + skills stats; Commands → command/favorite counts + the labeled Command Bridge switch).
3. **Tab body** fills remaining height.

**Orders tab (doctrine):**
- Preview/Edit segmented control + "Open" overlay — **keep** the existing `editorCard` interaction (it's good), but make the inline panel height **flexible** (min 240, grows), not fixed 286.
- Token meter pinned to the editor card footer — **keep** (StandingOrders L233, the gradient meter is a highlight).
- Save: surface a card-footer Save + dirty dot visible in BOTH Preview and Edit (fix U7).
- **Audit & Templates** collapse into one disclosure zone below the editor, **default collapsed** (reclaims ~200px). The Delivery-audit telemetry and the Templates picker each become a sub-section inside it.
- Terminology: keep "Standing Orders / constitution" language *inside* the doctrine copy and tooltips; only the section/tab label is "Orders".

**Commands tab (palette config):**
- Drop the Commands hero entirely. The master switch → labeled control in the meta row (fix U5).
- Fold the one-setting "Global shortcut" card into a slim row ABOVE the master-detail (or into the meta row), not a full glass card — it's a single rebind field + status line.
- The `CommandsEditorView` master-detail gets the full tab height; remove the outer `ScrollView`/`minHeight: 560` wrapper so only the two columns scroll (fix U4).
- Command rows `42 → 36`; selected-slot `Color.white` → `BridgeTokens.onAccent`; tray shows all favorites at full opacity (fix U8).

**States & edge cases to spec:**
- **Empty doctrine:** Orders tab shows the seeded default (store seeds on load, StandingOrders L582) — never a blank editor.
- **No connected clients:** Delivery audit already has a clean empty line ("No clients connected.") — keep inside the collapsed zone.
- **No commands / none selected:** CommandsEditorView `emptyState` exists (L417) — keep; ensure it centers in the detail column at full tab height.
- **No favorites:** tray-preview empty line exists (L373) — keep.
- **Unsaved edits when switching tabs:** must not lose the doctrine draft; either auto-persist draft state or warn. (Today the draft lives in `@State`, lost if the view is torn down.)
- **Light/titanium:** verify slot-key and tray sheens after the `Color.white` → token migration.
- **Narrow window (760 min width, 600 min height):** tab body must stay usable; master-detail master column `236` (CommandsEditorView L38) + detail must fit; consider collapsing the master column toward 200 under pressure.

**Net effect:** one header instead of two heroes, one tabbed body instead of two stacked sections, ~150–250px of reclaimed vertical space, full design-system header/token compliance, and the editor (the actual work) promoted to the tallest element on each tab.

---

## Priority Recommendations

1. **Collapse two heroes → one shared `BridgeSettingsSectionHeader` + a tab strip.** Biggest hierarchy + density + consistency win in a single move; unblocks the locked merge. Uses the already-defined `.standingOrders` preset.
2. **Make the editors own the height.** Flexible doctrine panel (drop fixed 286), full-height Commands master-detail (drop the nested ScrollView + `minHeight 560`), and push Delivery-audit + Templates into a default-collapsed zone.
3. **Token-clean + save-state fixes.** Replace `Color.white`/`Color.black` literals in slot keys/tray with `onAccent`/adaptive tokens; surface a persistent Save+dirty indicator visible in both Preview and Edit; label the Command Bridge master switch.
