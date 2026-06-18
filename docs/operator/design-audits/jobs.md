# Design Audit — Jobs page

Scope: Settings → **Jobs** pane of The Bridge (macOS SwiftUI menu-bar app, MCP connector).
Method: `design:design-critique` rubric applied to the live source.
Sources read (read-only):

- `TheBridge/UI/Sections/JobsSection.swift` — page composition (hero, alert, scheduled card, recent runs).
- `TheBridge/UI/JobsView.swift` — `JobGlassRow`, `JobDetailView`, `NewJobSheet`, `ImportSheet`.
- `TheBridge/UI/BridgeShell.swift` — `BridgeTitleBar` / `BridgeFootBar` / section nav.
- `TheBridge/UI/BridgeThemeV2.swift` — `BridgeGlassCard`, `BridgeCardLabel`, `BridgeDepLink`, `PartialToggle`.
- `TheBridge/UI/BridgeTokens.swift` — token SSOT.
- `TheBridge/UI/Sections/BridgeSettingsSectionHeader.swift` — the shared 5-caller hero (Jobs preset at L130–136).
- `design/design-system/project/ui_kits/the-bridge/Jobs.jsx` + `kit.css` — locked mockup / visual SSOT.

Locked redesign constraints applied: sidebar 7 (Jobs stays its own section), **global density tenet** (compact; the app wastes space), **legibility floor** (text ≥ 11–12px, real hit areas, truncate-with-reveal over shrinking), chrome = section-name-only titlebar + slim footbar.

---

## Overall impression

The Jobs page is the most *complete* section in the app — hero + stat strip, failing-job alert, filter/search/sort, glass rows with inline editor, and a recent-runs log. It is also the **most space-hungry and the most internally inconsistent** of the settings panes. Three problems dominate:

1. **The page does not use the shared section header.** Every other target section (Connections, Credentials, Permissions, Advanced) renders `BridgeSettingsSectionHeader`, which already has a Jobs preset defined (`BridgeSettingsSectionHeader.swift:130`, purple tint, `clock.badge.checkmark`). Jobs hand-rolls its own hero in `JobsSection.hero` (`JobsSection.swift:112–142`) with a *different* icon tile (50×50 rounded-rect vs the shared 44×44 circle), a *different* tint (`BridgeTokens.ok` emerald vs the preset's `NotionPalette.purple`), and a *different* title size (22 vs 18). This is a direct consistency violation and the single highest-leverage fix.

2. **The hero is a tall, low-density band.** ~82pt of vertical chrome (50pt orb + 18pt card padding ×2 + spacing) to show one icon, a title that duplicates the titlebar, a subtitle, and three stat tiles. Under the density tenet this is the worst offender on the page.

3. **The row right-edge is a cramped control gutter** — next-run text + status badge + pause + run-now + ellipsis menu all compete in a narrow trailing zone, while the whole row is *also* a tap target that toggles the editor. Tap-vs-button ambiguity plus sub-minimum hit areas.

What is genuinely good and should be preserved: the failing-state model (row tone + inline banner + page-level alert with one-click "Retry now"), the inline-expand editor (no modal context switch to edit), live cron validation with humanized echo, and the monospace cron + run-log treatment.

---

## 1. First impression (2 seconds)

- **What draws the eye first:** the emerald orb in the hero. That is **wrong** — emerald is the app's "ok/running" signal color (`BridgeTokens.ok`, `#13B87A`), so a large emerald block top-left reads as a *status*, not a section icon. The shared header's Jobs preset is purple precisely to avoid colliding with signals.
- **Emotional read:** "dashboard-y, slightly heavy." The 22pt "Jobs" title plus a full-width subtitle plus a stat strip is a lot of preamble before the actual job list.
- **Purpose clarity:** good. The subtitle ("Scheduled tool calls Bridge runs on cron — even when no client is connected") is the best one-liner in the app and explains the feature precisely. Keep this copy.

---

## 2. Usability

| Finding | Severity | Recommendation |
|---|---|---|
| **Whole row is a toggle AND contains 3+ buttons.** `rowHeader` sets `.contentShape(Rectangle()).onTapGesture { onToggle() }` (`JobsView.swift:122–124`) while pause/run/ellipsis live inside it. Buttons use `.buttonStyle(.plain)` so they swallow their own taps, but there is no visual affordance that the *rest* of the row expands — and the chevron (10pt, fg5) is nearly invisible. | 🔴 Critical | Keep row-tap-to-expand but make the affordance explicit: a hover background (`BridgeTokens.hoverFill`) on the row body, and bump the chevron to 11pt fg4. Reserve the trailing button cluster as a clearly separate zone. |
| **Run-now is irreversible and unconfirmed.** `arrow.clockwise` (`JobsView.swift:187`) fires `runNowTool` immediately. For jobs that send messages / hit Stripe / mutate Notion this is a live side effect from a 26pt icon with no confirm. | 🔴 Critical | Add a brief in-row running state (spinner replacing the glyph while `busy`) and, for jobs whose action chain touches send/payment/delete tools, a lightweight confirm. At minimum, surface a transient "Run triggered" toast (the detail editor already does this at `JobsView.swift:582`; the row does not). |
| **Row gives no post-action feedback.** `JobGlassRow` actions (`pause`/`resume`/`runNow`, `JobsView.swift:240–251`) just call `onChanged()` → full reload. No optimistic state, no toast. The user clicks pause and waits for a reload flicker. | 🟡 Moderate | Optimistically flip the status badge/dot on click; show a 1-line inline confirmation or reuse the card's `bulkMessage` slot. |
| **"Pause all" / "New job" / overflow are stacked into the card-label row** (`JobsSection.swift:221–248`) alongside the section title "Scheduled jobs". Three different button styles (`.controlSize(.small)` plain, `.borderedProminent`, borderless ellipsis) crowd one line. | 🟡 Moderate | Standardize to the kit's `.btn.sm` (26pt) + `.btn.primary.sm` pattern; move Export/Import/Resume-all into the overflow only (already there) and keep the visible row to **Pause all** + **+ New job**. |
| **Sort menu is 170pt wide and always visible** (`JobsSection.swift:279`) even with 2 jobs. Filter segmented + search + sort eat a full control row above the list. | 🟡 Moderate | Collapse sort into the overflow menu or a small icon-menu; keep the segmented filter + search inline. Saves a full row and a lot of width. |
| **No bulk selection / multi-row actions.** "Pause all" / "Resume all" are the only bulk verbs; you cannot select 3 of 10 jobs. | 🟢 Minor | Out of scope for v1, but note for later. |
| **Recent-runs log truncates each line to 1 with no reveal** (`JobsSection.swift:402`). A failed run's error message (the most important line) gets clipped with no tooltip or expand. | 🟡 Moderate | Add `.help(line.text)` on each log line, and let a failed line wrap to 2 lines (errors are why you open this card). |
| **Error/empty/loading are inside the scheduled card only.** A hard load failure shows a small inline retry (`JobsSection.swift:303–310`) but the hero still renders stat tiles reading "0 / 0 / 0", implying "all healthy" during an outage. | 🟡 Moderate | When `loadError != nil`, suppress or dim the stat strip so it doesn't assert false health. |

---

## 3. Visual hierarchy

- **Reading order today:** giant emerald orb → "Jobs" (22pt) → subtitle → 3 stat tiles → (alert) → "Scheduled jobs" + buttons → filter/search/sort → rows → recent runs. The first ~120pt is all preamble; the actual scannable content (rows) starts well below the fold on the compact settings window.
- **Title duplication:** the titlebar already shows the section name ("The Bridge › Jobs", `BridgeTitleBar`, `BridgeShell.swift:265–284`; redesign moves this to section-name-only left-aligned). The hero then repeats "Jobs" at 22pt. Two titles for one page. Under the redesign's "titlebar = section-name-only" rule, the in-page hero title is **redundant** and should shrink or go.
- **Stat strip is under-powered vs the mockup.** The locked `Jobs.jsx` strip carries **four** stats — `142 done · 24h`, `4 running`, `2 paused`, `1 failed` (`Jobs.jsx:46–51`) — i.e. throughput is the lead metric. The Swift port (`JobsSection.swift:135–139`) renders only **three** (active / paused / failing) and **drops the 24h-throughput stat entirely**. The most reassuring number ("142 ran successfully today") is missing. The footbar in the mockup also reads "Scheduler healthy · 4 active · 1 failing" (`Jobs.jsx:37`); the shipped `BridgeFootBar` is generic version text.
- **Emphasis is on the wrong thing.** The orb (decorative) is the largest, most colorful element. The stat tiles (the actual at-a-glance value) are small wells with 18pt mono numbers. Invert: shrink the orb, let the numbers lead.
- **Whitespace:** outer padding 18 (`JobsSection.swift:74`), inter-card spacing 14 (L68), card padding 14 (default `BridgeGlassCard`), hero icon 50pt. Generous everywhere. The density tenet wants this tightened to ~14 outer / 10 inter-card / 12 card.

---

## 4. Consistency

| Element | Issue | Recommendation |
|---|---|---|
| **Section header** | Jobs hand-rolls `hero` instead of using `BridgeSettingsSectionHeader`; a Jobs preset already exists and is unused (`BridgeSettingsSectionHeader.swift:130–136`). | Adopt the shared header. Put the stat strip in its `accessory` slot. |
| **Hero icon shape** | Jobs uses a 50×50 **rounded-rect** tile (`JobsSection.swift:116–124`); shared header uses a 44×44 **circle** (`BridgeSettingsSectionHeader.swift:38–45`). | Conform to the circle (or change the shared header system-wide, not just here). |
| **Hero tint** | Jobs = emerald `BridgeTokens.ok` (a signal color); preset = `NotionPalette.purple`. | Use purple; free up emerald for status only. |
| **Title size** | Hero "Jobs" = 22pt (`JobsSection.swift:127`); shared header titles = 18pt (`BridgeSettingsSectionHeader.swift:49`). | 18pt to match. |
| **Icon-button hit area drift** | Row pause/run = 26×26 (`JobsView.swift:229`); row ellipsis = 26×26 (`:211`); hero/card ellipsis = 24×22 (`JobsSection.swift:242`). Three sizes for the same affordance. | One token: 28×28 minimum (see accessibility). |
| **Button styles** | Mixed `.controlSize(.small)`, `.borderedProminent`, `.borderless`, `.plain` across the card header and detail footer. | Standardize on kit `.btn` family (30pt / `.sm` 26pt) per `kit.css:109–119`. |
| **Detail editor reverts to native controls** | `JobDetailView` uses `.roundedBorder` text fields and default `Toggle`/`Button` (`JobsView.swift:434, 459, 495, 502–518`), breaking the glass language the row established. The action JSON editor *is* glassed (`:484`) but the name/schedule fields are not. | Wrap the editor in the same well/glass treatment; use the kit toggle and `.btn` family. |
| **Two failing-state surfaces, two layouts** | Page alert (`failingAlert`, `JobsSection.swift:161–206`) and row banner (`failingBanner`, `JobsView.swift:154–169`) render the same condition with different paddings/corner radii. | Share one `FailingBanner` view at two scales. |
| **Stat tile vs mockup** | 3 tiles vs 4; labels uppercased+tracked here (`JobsSection.swift:149–151`) but lowercase in mockup. | Restore the 4th (throughput) and align label casing to the kit. |

---

## 5. Density & space waste (against the global tenet)

Measured from source:

- **Hero band ≈ 82pt tall** for a decorative orb + duplicated title + subtitle + tiles. Biggest single waste on the page.
- **Outer padding 18 / inter-card 14 / card 14** — every gap is 2–4pt over what the density tenet wants.
- **Full control row** (filter + search + 170pt sort) is always present even at 0–2 jobs.
- **Row vertical padding 4 + 3pt internal spacing** is actually reasonable; the *width* is the problem (trailing cluster).
- **Recent-runs collapsed shows 5 lines + "+N more"** (`JobsSection.swift:388, 407`) — good restraint; keep.

Net: the page could reclaim ~50–70pt of vertical space above the first row by (a) collapsing the hero into the shared header with the stat strip as accessory, (b) tightening padding, (c) folding sort into overflow. That is roughly one extra job row visible without scrolling on the compact settings window.

---

## 6. Accessibility

- **Hit areas below the 44pt HIG target — and below this app's own practical floor.** Row icon-buttons are 26×26 (`JobsView.swift:229`), card ellipsis 24×22 (`JobsSection.swift:242`). The legibility floor mandates real hit areas; 26pt for a *destructive-adjacent* run-now button is too small. Raise interactive glyph buttons to **28×28 minimum** (visual) with a ≥32pt tap region via `contentShape`.
- **Text legibility — mostly compliant.** Smallest text is 10pt (stat-tile label, `JobsSection.swift:150`) and 11pt (badge `JobsView.swift:173`, "+N more" `:409`, dep-link). The **10pt stat label is below the 11–12px floor** — bump to 11pt. Everything else is ≥11.5pt. Good.
- **Color-only status encoding.** Status is carried by badge text ("Active/Paused/Failing") AND tint, so it is not color-only — good. But the row icon-tile tint (`tone.iconTint`, `JobsView.swift:78–82`) is the *only* place the glyph color changes; fine since the badge carries the word.
- **Contrast risk in light mode.** `BridgeTokens.fg4`/`fg5` (black @ 0.48 / 0.38 on `#ECEDEF`) carry next-run text, captions, and the chevron. fg5 at 0.38 alpha on titanium is borderline for the 10–11pt meta text. Verify the chevron (`fg5`, 10pt) and stat labels against WCAG AA in light mode; likely needs fg4 or larger.
- **VoiceOver on the row is unstructured.** The whole row is a tap target with embedded buttons but no `accessibilityElement`/label grouping (contrast with the shared header, which sets `.accessibilityElement(children: .contain)` and header traits). A VO user gets a pile of sub-elements with no "row = job X, active, next run …" summary, and the expand gesture is an untyped tap.
- **`.help(...)` tooltips** exist on row icon-buttons (`JobsView.swift:234`) — good — but not on the run-log lines or the stat tiles.
- **Keyboard:** the sidebar has arrow-key nav (`BridgeShell.swift:183`), but there is no keyboard path to focus/expand/run a job row. Row is mouse-only.

---

## 7. The job row — anatomy critique (the core of the page)

`JobGlassRow.rowHeader` (`JobsView.swift:96–125`) lays out, left→right:

`[icon 30×30] [name + cron·detail subline + (failing banner)] [Spacer] [next-run (mono) over status badge] [pause/run + ellipsis] [chevron 16]`

Findings:

- **The trailing zone is a traffic jam.** Next-run text, badge, two icon-buttons, an ellipsis menu, and a chevron all live to the right of `Spacer(minLength: 8)`. On a narrow settings window with a long job name, the name truncates to make room for five trailing elements. The chevron (16pt frame) is pure overhead next to a row that's already tap-to-expand.
- **Redundant expand affordances.** Row-tap expands *and* a chevron sits at the end. Pick one signal: drop the standalone chevron, rotate the icon-tile or show a hover chevron.
- **next-run is doing two jobs.** It shows cadence for active jobs (`CronHumanizer.describe`), "paused" for paused, "retrying…" for failing (`JobsView.swift:265–269`). Overloading one slot with status *and* schedule means active rows show a relative time while paused/failing rows show a status word — inconsistent column semantics. The badge already says Paused/Failing, so next-run repeating "paused"/"retrying…" is redundant; for active jobs the *actual* next fire time ("next in 12m" / "tomorrow 06:00" per the mockup `Jobs.jsx:10,13`) is more useful than the cadence echo.
- **detail subline is good but fragile.** `schedule (mono) · firstTool +N` (`JobsView.swift:141–151`) is the right info. But `detailText` falls back to the *humanized cron* when there are no actions (`:255–261`), so a no-action job shows the cadence twice (subline + next-run). Edge case.
- **Per-job glyph is cosmetic guesswork.** `jobGlyph` keys off substring matches in the first tool name (`JobsView.swift:273–282`). Harmless, but it can mislead (a job that happens to contain "fetch" gets the sync glyph). Acceptable as decoration; don't let users infer meaning from it.
- **Failing banner placement.** Rendered *inside* the name column (`JobsView.swift:105`), so it indents under the name and competes with the trailing cluster width. It reads fine but pushes row height up unpredictably. Consider full-row-width below the header line.

**Controls (run / pause / history / run-now):**

- **Pause/Resume + Run-now** are the two always-visible icon-buttons (`JobsView.swift:182–187`) — correct primary verbs.
- **History/log** is *buried*: there is no per-row history affordance in the collapsed row. To see a job's log you must expand → "Reveal Log" (`JobsView.swift:450`), which opens **Finder at a `.out.log` file** (`:625–629`) rather than showing the run history in-app. The page-level "Recent runs" card is global, not per-job. So "see this job's recent runs" has no direct path. This is the biggest *information* gap.
- **Duplicate / Copy ID / Delete** live in the row overflow (`JobsView.swift:188–217`) — appropriate.
- **Run-now confirmation:** none (see Usability, critical).

---

## 8. States — empty / error / loading / failing

- **Loading:** centered small spinner, 22pt vertical (`JobsSection.swift:300–302`). Fine.
- **Empty (no jobs):** good — icon, headline, explainer, New Job + Import buttons (`JobsSection.swift:337–358`). The two-state copy ("No scheduled jobs yet" vs "No jobs match this filter", `:342`) is a nice touch.
- **Error:** inline retry inside the card (`JobsSection.swift:303–310`); but hero stat strip still shows 0/0/0 implying health (see Usability). Also the error string is the raw `"\(error)"` (`:472`) — developer text, not user copy.
- **Failing:** strong — row tone + inline row banner + page-level alert with "Retry now" + footer hint. Best-handled state on the page. Keep the model; just unify the two banner layouts.
- **Bulk-action result:** single-line `bulkMessage` under the list (`JobsSection.swift:252–258`), red if it contains "failed". Works, but it's the only feedback channel and it's easy to miss at the bottom of a long card.

---

## 9. Edge cases observed in source

- **Long job names** truncate to 1 line (`JobsView.swift:103`) — correct (truncate-with-reveal), but no tooltip reveal. Add `.help(job.name)`.
- **Long cron / many actions:** subline `detailText` shows `+N` overflow (`JobsView.swift:257`) — good.
- **No-action job:** subline falls back to humanized cron, duplicating next-run (above).
- **Expanded row + reload:** `expandedJobId` is cleared if the job vanishes after reload (`JobsSection.swift:466–468`) — correct, prevents a dangling editor.
- **Raw error leakage:** load error and several save/run failures interpolate `\(error)` directly into the UI (`JobsSection.swift:472, 511`; `JobsView.swift:387, 574`). Developer-facing, not localized.
- **Save button enablement** correctly gates on validity + `hasChanges` (`JobsView.swift:517, 521–526`) — good.

---

## Priority recommendations

1. **Adopt `BridgeSettingsSectionHeader` (purple, 44pt circle, 18pt title) and move the stat strip into its accessory slot — restoring the 4th "done · 24h" throughput stat.** Kills the consistency violation, the duplicated title, and ~50pt of wasted height in one move. (`JobsSection.swift:112–157` → shared header; preset already at `BridgeSettingsSectionHeader.swift:130`.)
2. **Re-architect the row trailing zone into a fixed 3-slot grid** (next-run · status badge · action cluster), drop the standalone chevron, give the row a hover background, and make next-run show the *actual next fire time* for active jobs. Raise all icon-buttons to 28×28 / ≥32pt tap. (`JobsView.swift:96–125, 180–236`.)
3. **Add a per-row run-history path in-app** (expand → a compact run-log filtered to this job, reusing the `RunLine` treatment) so "Reveal Log → Finder" is the fallback, not the only route; and add a run-now running state + confirm for side-effecting tools. (`JobsView.swift:187, 450, 625`.)
4. **Tighten density** to 14 outer / 10 inter-card / 12 card; fold Sort into overflow; bump 10pt stat label to 11pt; suppress the stat strip during load errors so it never asserts false health.
5. **Re-glass the inline editor** so name/schedule/toggle match the row's material instead of dropping to native `.roundedBorder` / default controls. (`JobsView.swift:432–519`.)
