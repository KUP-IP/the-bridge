# Design Audit — Advanced page

> Source: `TheBridge/UI/Sections/AdvancedSection.swift` (548 lines, READ-ONLY)
> Method: `design:design-critique` rubric applied against the LOCKED redesign decisions (7-section sidebar, global density tenet + legibility floor, section-name-only titlebar, slim integrated footbar).
> Date: 2026-06-10 · Auditor session: Advanced page

---

## Overall impression

Advanced is the **best-structured page in the app** — it already speaks the redesign's language (custom glass hero, `BridgeCardLabel` kv-grids, mono chips, reveal-in-Finder rows, a 2-col maintenance grid with color-coded danger tiles). It is also the **most space-wasteful**: seven full-bleed `BridgeGlassCard`s stacked with 14pt gaps and 20pt page padding mean a power-user reference page (mostly read-only metadata + rare destructive actions) consumes ~5–6 scroll-heights of vertical space for what is, functionally, ~15 facts and 4 buttons.

The single biggest opportunity: **version appears three times** (hero `versionTile`, About card `App version` row, and — post-redesign — the slim footbar's version readout). Pick one home. Per the brief, this page is the natural landing spot for relocated About/version if the footbar slims.

Biggest consistency defect: the page rolls its **own** hero (`hero`, L174–203) instead of the shared `BridgeSettingsSectionHeader`, whose `.advanced` preset (L137–143) exists and is asserted by snapshot tests as a "one header, 5 callers" contract — yet **no section actually calls it**. Advanced's hero also diverges from that contract (50pt rounded-rect tile vs 44pt circle; 22pt title vs 18pt; trailing version tile + icon button vs a single accessory).

---

## Current anatomy (what's on the page)

`body` → `ScrollView` → `VStack(spacing: 14).padding(20)` (L88–100) of seven cards:

| # | Card | Lines | Content | Verdict |
|---|------|-------|---------|---------|
| 1 | **hero** | 174–230 | 50pt gear tile · "Advanced" 22pt · subtitle · `versionTile` · export icon button | Redundant w/ titlebar; version dup #1 |
| 2 | **aboutCard** | 234–263 | kv-grid: App version, MCP protocol, Notion API, macOS, Bundle | Keep; version dup #2 |
| 3 | **licenseCard** | 267–278 | `LicenseCard` state machine (trial/licensed/expired/grandfathered) | Belongs in Security, not Advanced |
| 4 | **networkCard** | 282–325 | Local MCP port field + Save + Restore default + apply-after-restart note | Keep, but arguably Connection |
| 5 | **localEndpointsCard** | 329–354 | 3 copyable mono rows (Streamable HTTP / Legacy SSE / Health) | Keep; could be Connection |
| 6 | **systemPathsCard** | 358–396 | 3 reveal-in-Finder rows (Config / Logs / Screen output) | Keep — canonical Advanced |
| 7 | **maintenanceCard** | 437–486 | 2×2 tile grid: Export diag · Reset onboarding · Reset bg items · Factory reset | Keep — canonical Advanced |

---

## 1. Usability

| Finding | Severity | Recommendation |
|---|---|---|
| **Version shown 3×** — hero `versionTile` (L205–218, gold mono 15pt), About `App version` row (L239), and the slim footbar (`BridgeFootBar.version`, BridgeShell L295). | 🟡 Moderate | Make Advanced the single source of build/version truth. Drop the hero `versionTile`. Keep About's `App version` row as the canonical readout. Footbar may keep a tiny version per B2.3 (it's chrome, not duplication of *this page's* job) — but the page itself should not show version twice. |
| **Export diagnostics has two triggers** — hero icon button (L200) and the Export tile (L445–451). Same action, two affordances, far apart. | 🟡 Moderate | Keep one. The Maintenance tile is the discoverable, labeled home (has subtitle explaining the redacted bundle). Remove the hero icon button. |
| **Network "Save" gives no inline confirmation of the restart requirement until after save** — the restart prompt is a `confirmationDialog` (L107–125); the "Changes apply after Restart Bridge" hint (L320) sits below and is `fg4` (46% alpha), easy to miss. | 🟢 Minor | Promote the restart hint to `fg3` and place it adjacent to the Save button, or fold it into the field's helper line. |
| **Three maintenance actions are destructive/disruptive, one is benign** (Export) yet all four share identical tile chrome and grid weight. Factory reset (irreversible) sits bottom-right with the same visual prominence as Export. | 🟡 Moderate | Separate concerns: Export is a *diagnostic*, not maintenance. Move Export out of the destructive grid (e.g. up next to the network/paths reference area or into the hero-adjacent utility row). Keep the 3 reset/wipe actions grouped as "Danger zone" / "Reset". |
| **Restore-default port and Save are equal-weight** (both `controlSize(.small)`, Save is `.borderedProminent` accent, Restore is `.bordered`). Acceptable, but Restore is rarely needed and adds width. | 🟢 Minor | Demote Restore to a text-only link or move into an overflow; reclaim row width for the field + helper. |
| **No empty/error state for paths** — `pathRow` assumes the path resolves; if `screenOutputDir` is empty the chip renders a blank well with a Finder button that opens nothing. | 🟢 Minor | Guard: if path is empty, show "Not set" muted text and disable the reveal/copy buttons. |

## 2. Visual hierarchy

- **What draws the eye first**: the gold `v3.7.x` version tile in the hero (gold is the only warm accent on a cool page) — but version is the *least* actionable thing here. The eye is pulled to chrome, not to the destructive actions or the editable port. Hierarchy is inverted.
- **Reading flow**: hero → About → License → Network → Endpoints → Paths → Maintenance. License interrupts the build-info → network → paths → maintenance flow with a billing concern that doesn't belong, breaking the "system internals" mental model.
- **Emphasis**: the page has no internal priority. All seven cards are the same `BridgeGlassCard` weight (same 14pt padding, same sheen, same radius 12). A reference page should let *editable* (port) and *dangerous* (factory reset) regions read louder than *read-only* (About, endpoints, paths) regions. Right now they're flat.
- **Hero subtitle is 12.5pt `fg3`** (L194–195) and wraps to two lines — combined with the 22pt title and 50pt tile, the hero alone is ~80–90pt tall before any content. That's a lot of masthead for "everything else."

## 3. Consistency

| Element | Issue | Recommendation |
|---|---|---|
| **Hero component** | Rolls its own `hero` (L174–203) instead of shared `BridgeSettingsSectionHeader`; the `.advanced` preset (L137–143) is dead. Tile is a 50pt rounded-rect (L178–180) vs the shared 44pt circle (header L39–41); title 22pt vs 18pt; icon is SF `gearshape.2` (L183) while the *sidebar* uses the custom `BridgeVectorIcon(.advanced)` two-gears glyph (BridgeShell L244). Two different "advanced" icons. | Adopt one hero contract app-wide. Given the LOCKED titlebar = section-name-only, the per-section hero is largely redundant — collapse the hero to a thin section intro (or remove it) and let the titlebar carry the name. If a hero stays, use the shared component + `.advanced` preset and the two-gears glyph for icon parity with the sidebar. |
| **Card label casing** | `BridgeCardLabel` upper-cases + tracks 1.2 (ThemeV2 L114–123) at 11pt `fg3` — consistent and good. The hero title bypasses it (22pt semibold). Fine for a hero, but note About/Network/etc. all use the label; the hero is the odd one out. | Keep `BridgeCardLabel` as the section-within-page label standard. |
| **Mono chip radius vs button radius** | `monoChip` uses radius 7 (L410), copy/reveal buttons radius 7 (L387, L427) — consistent. Good. But `versionTile` uses radius 10 (L216) and the hero tile radius 14 (L178). Three radii in one hero. | Standardize on `BridgeTokens.Radius` (control 8 / card 12) — the page currently hardcodes 7, 10, 14 instead of the tokens. |
| **Hardcoded radii everywhere** | Every `RoundedRectangle(cornerRadius:)` in this file is a literal (7, 10, 14) — none reference `BridgeTokens.Radius.control/card/input` (Tokens L210–216). | Replace literals with tokens; the well/chip radius should be one value (suggest `Radius.control` = 8 or a new `Radius.chip` = 6–7). |
| **Maintenance `.neutral` tint = `Color.white`** (L502) | Bypasses tokens; `Color.white` is not appearance-adaptive and will read wrong on the titanium (light) ground for the tile stroke/fill math (`tint.opacity(...)`). | Use `BridgeTokens.fg1`/`titanium` or a neutral token so light mode is correct. |
| **Two key/value grids, two row builders** | `kvRow` (About, L250) and `copyRow`/`pathRow` (L343, L372) are near-identical label+value grids with different value treatments. | Unify into one `metaRow(label:value:trailing:)` that optionally renders mono chip + action buttons — cuts ~40 lines and guarantees aligned columns across About/Endpoints/Paths. |

## 4. Density / space-waste (the headline problem)

Measured against B2.0 (density tenet) + legibility floor:

- **7 separate cards** each pay the `BridgeGlassCard` tax: 14pt internal padding ×2 (28pt) + sheen + hairline + 14pt inter-card gap. That's ~42pt of pure chrome per card boundary × 7 = ~290pt of vertical space spent on card framing alone, plus 40pt page padding (20 top/bottom).
- **About, Local endpoints, System paths are all read-only metadata** — they don't each need to be a hero-weight glass card. They're three small tables.
- **Hero ~85pt + footbar overlap of version** — the hero is the single largest waste given the titlebar already names the section.
- **Maintenance tiles have `Spacer(minLength: 6)` (L524)** pushing buttons to tile bottom — fine, but the 2×2 grid with 12pt tile padding + 10pt gaps is generous for four short actions.

**Density recommendations (conform to legibility floor — nothing below 11pt, hit areas ≥ 27pt which the copy/reveal buttons already meet at 27×27):**
1. **Merge the three read-only metadata cards** (About + Local endpoints + System paths) into **one "System" card with three labeled sub-groups** (or a single grid with section dividers). One card boundary instead of three saves ~84pt and unifies column alignment.
2. **Drop the hero** to a single titlebar-aligned line (section name lives in the titlebar; a one-line subtitle can sit as the first content line). Saves ~85pt.
3. **Tighten the page VStack** from `spacing: 14` → `10` and page padding `20` → `16` (still above cramped; copy/reveal targets stay 27pt). 
4. **Keep Maintenance as the only "loud" card** — it earns its weight because it holds the dangerous actions.

Net: roughly halve the page height while keeping every fact and action and never dropping below the 11–12pt floor.

## 5. Accessibility

- **Legibility floor**: PASS overall. Smallest text is the `VERSION` label at 10pt (L211) and the kv keys/labels at 12.5pt. The **10pt `VERSION` caption violates the 11–12px floor** — if `versionTile` survives, bump to 11pt; better, delete the tile. `fg4`/`fg5` (46%/34% alpha) on captions is low-contrast — the "apply after restart" hint at `fg4` (L322) and `VERSION` at `fg4` (L213) are borderline on the titanium ground.
- **Hit areas**: copy button 27×27 (L426), reveal 27×27 (L386), hero icon button 30×30 (L225) — all meet a reasonable min. Network field buttons are `controlSize(.small)` (system-minimum, acceptable on macOS).
- **Color-only signaling**: the maintenance danger tile relies on red (`bad`/`badText`) to mark "destructive" (L502, L509). It *also* uses `role: .destructive` (L535) and the word "Factory reset" — so it's not color-alone. Good. Export's blue-vs-neutral distinction is color-only but low-stakes.
- **VoiceOver**: hero icon `accessibilityHidden(true)` (L187) ✓; copy/reveal buttons have labels (L392, L432) ✓; the kv values are `textSelection(.enabled)` ✓. The `versionTile` has **no accessibility label** — VoiceOver reads "v3.7.7 VERSION" as two fragments. The shared header's combined-heading pattern (`accessibilityElement(children: .contain)`, header L62) is not applied to this page's custom hero — VoiceOver gets a more fragmented hero here.
- **Copy feedback**: the "copied" checkmark (L423) is a 1.4s visual-only flash with no VoiceOver announcement. Minor — consider an `accessibilityValue`/announcement on copy.

## What works well

- **The mono-chip + copy-button row** (`monoChip` L400 + `copyButton` L414) is an excellent, reusable, dense pattern — keyed "copied" flash by value (L86, L418–421) so the checkmark lands on the clicked row. This is the model the rest of the app should copy.
- **Reveal-in-Finder rows** with middle-truncation on long paths (L379, L405) respect "truncate-with-reveal over shrinking" — exactly the locked tenet.
- **Maintenance tile color-coding** (export=accent, neutral, danger=red) with `role: .destructive` is correct and accessible.
- **Confirmation dialogs** for all three destructive resets (L126–169) with clear, scoped messages ("settings and data will not be affected", "credentials preserved", factory-reset message injected) — good safety hygiene.
- **View-layer-only discipline** (header comment L8–11): every binding preserved verbatim, which makes the redesign a pure presentation refactor — low risk.

---

## What belongs here vs elsewhere (post-merge)

**Move OUT of Advanced:**
- **License card (L267–278)** → **Security**. It's a billing/entitlement posture concern, not a system internal. Security is becoming the posture page (S3); license fits its header strip or a Vault-adjacent area. Removing it also fixes the hierarchy break (billing interrupting build-info → network → paths flow).
- **Network port (L282–325)** and **Local endpoints (L329–354)** → strong candidates for **Connection** (S4), which is explicitly "the single way agents reach the Bridge" with a "Local clients: the loopback MCP endpoint(s)" area. The port *defines* those endpoints; keeping them in Advanced splits one concept across two pages. **Recommendation: move both to Connection's "Local clients" area.** If the operator wants Advanced to remain the low-level escape hatch, leave a read-only mirror — but the editable port should live with the endpoints it controls.

**Stays in Advanced (canonical):**
- **About / build info** (version, MCP protocol, Notion API, macOS, bundle) — and absorb relocated **version/About** if the footbar slims (per brief). This is the natural home.
- **System paths** (config / logs / screen output) — pure power-user disk introspection.
- **Maintenance / reset / factory reset** — destructive escape hatches belong nowhere else.
- **Export diagnostics** — a support/diagnostic utility; fits Advanced.

**Good candidates to LAND here from merges (per brief):**
- **Version/About** from a slimmed footbar → About card is ready to be the SSOT.
- Any **orphaned low-level toggles** from the Security/Connection/Orders merges that don't fit those posture pages (e.g. a stray "reset background items"-class launchd control, or a developer/debug flag) → Advanced is the correct catch-all, grouped under a "System" or "Developer" sub-area rather than scattered.

---

## Priority recommendations

1. **Kill the version triplication + collapse the hero.** Drop the hero `versionTile` and the hero export icon; let About own version and let the titlebar own the section name. Saves ~85–100pt and fixes the inverted hierarchy (gold version chip no longer steals first-glance). *Highest impact, lowest risk.*
2. **Merge the three read-only metadata cards** (About + Endpoints + Paths) into one "System" card with labeled sub-groups via a single unified `metaRow` builder. Halves card-chrome waste and guarantees column alignment. Apply `spacing 14→10`, `padding 20→16`.
3. **Relocate License → Security and Network+Endpoints → Connection.** Leaves Advanced as a clean, coherent "build info · system paths · maintenance" page — the true "everything else" bucket. Then tokenize the hardcoded radii (7/10/14 → `BridgeTokens.Radius`) and replace `Color.white` neutral tint (L502) with an adaptive token.
