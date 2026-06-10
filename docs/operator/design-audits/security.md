# Security Page — Design Audit & Unification Spec

**Scope:** the NEW merged **Security** page (Settings sidebar slot 5/7, order: Orders · Skills · Jobs · Tools · **Security** · Connection · Advanced).
**Mandate:** fuse two distinct, already-shipped surfaces into one coherent page under the locked layout — a **posture header** over **two tabs: Vault (credentials) | Gates (per-tool tiers + module Always-Allow + revoke)**.
**Method:** `design:design-critique` rubric applied to the live source.
**Constraint:** source is READ-ONLY for this audit; the only file written is this one.

## Sources read (with line anchors)

| Surface | File | Role in the merge |
|---|---|---|
| Credentials vault | `NotionBridge/UI/Sections/CredentialsSection.swift` | Vault tab body (hero, keychain banner, rows, policy card) |
| Add/replace sheet | `NotionBridge/UI/Sections/CredentialAddSheet.swift` | Vault add/rotate/reconnect modal |
| System grants (TCC) | `NotionBridge/UI/Sections/PermissionsSection.swift` | Gates? — actually **System-grant** content, see §1 |
| Legacy TCC view | `NotionBridge/UI/PermissionView.swift` | Onboarding twin + upcoming-capability gating |
| Tool tier control | `NotionBridge/UI/ModuleGroupCard.swift` (`ModuleGroupToolRow` L36–132, `ModuleGroupList` L443–696) | **The real "Gates" mechanism** (Open/Notify/Request per tool) |
| Tier resolution | `NotionBridge/UI/ToolTierResolution.swift` | Precedence: own override > module grant > registered default |
| Tier enum | `NotionBridge/Security/SecurityGate.swift` L58–62 | `open` / `notify` / `request` |
| Section hero | `NotionBridge/UI/Sections/BridgeSettingsSectionHeader.swift` | Shared hero contract + presets |
| Primitives + tokens | `NotionBridge/UI/BridgeThemeV2.swift`, `NotionBridge/UI/BridgeTokens.swift`, `NotionBridge/UI/BridgeShell.swift` | `BridgeGlassCard`, `BridgeCardLabel`, `BridgeDepLink(Row)`, `PartialToggle`, all tokens |

---

## §0. The taxonomy problem (read this first — it changes the merge)

The redesign brief defines **Gates** as "per-tool permission tiers + module-scoped Always-Allow + revoke." That is **not** the content of `PermissionsSection.swift`. There are THREE distinct "permission" concepts in this codebase, and the merge has to pick the right two:

1. **Credentials** — secrets in the macOS Keychain (`CredentialsSection`). → **Vault tab.** ✅ unambiguous.
2. **Tool security tiers** — `open`/`notify`/`request`, with a per-tool override that can clear back to a **module-scoped grant** (`moduleTierOverrides`, the literal "Always Allow") or the registered default. This lives **inside the Tools page today** (`ModuleGroupToolRow`'s tappable tier pill, `ModuleGroupList.cycleTier`). → This is what the brief calls **Gates**, and `ToolTierSource` (`ownOverride`/`moduleGrant`/`registeredDefault` in `ToolTierResolution.swift`) is exactly the "revoke a module grant" model. ✅
3. **macOS TCC system grants** — Accessibility, Screen Recording, Full Disk, Contacts, Notifications, Automation, Reminders, Calendar (`PermissionsSection`). These are OS-level, granted in System Settings, not per-tool tiers.

**Finding (Critical, taxonomy):** The locked spec's "Gates = per-tool tiers + module Always-Allow + revoke" maps to **#2**, which currently lives on the **Tools** page, while the file pair the audit names (`CredentialsSection` + `PermissionsSection`) is **#1 + #3**. These are not the same merge. Two coherent readings exist:

- **Reading A (literal-spec):** Security = **Vault (#1) + Gates (#2 — tool tiers)**, and TCC system grants (#3) move to **Connection** or a "System Access" card. This honors the brief's exact Gates definition and gives the posture header its "tool counts by gate tier open/notify/confirm" metric (which only #2 produces — TCC has no open/notify/confirm).
- **Reading B (file-literal):** Security = **Vault (#1) + Permissions (#3 — TCC)**, and the tool-tier control stays on Tools.

The posture-header requirement — **"tool counts by gate tier open/notify/confirm"** — is decisive. Only the tool security tiers (#2) have open/notify/confirm tiers; TCC grants are granted/not-granted. **Therefore the brief intends Reading A: Gates = tool security tiers.** This report specs Reading A as primary, and notes where TCC content must relocate. (If the operator actually wants #3 on this page, the Gates tab becomes a two-section tab — "Tool gates" + "System grants" — but that fights the density tenet; flag for decision.)

> **DECISION NEEDED (blocking):** Confirm Gates = **tool security tiers** (Reading A). Everything below assumes A. The TCC system-grant content (`PermissionsSection` grants card + sensitive-paths + reset) needs a new home — recommended: a **"System access"** card at the *bottom of the Gates tab* (collapsed/secondary), OR moved to Connection. Speccing it as a secondary Gates section so nothing is lost.

---

## §1. Design Critique (rubric)

### Overall impression
Two genuinely premium, well-tokenized surfaces that were designed in isolation and now collide. Both open with a 50×50 orb + 22pt title + stat tiles + ScrollView of `BridgeGlassCard`s — near-identical skeletons with **subtly divergent constants** (padding 18 vs 20; hero radius 14 RoundedRect vs the shared header's 44pt Circle; "added"/"checked" sub-lines vs "Last checked" header text). The biggest opportunity is not visual polish — both already pass — it's **eliminating the redundant second hero**: a merged page must not stack two 22pt orb-heroes. One posture header, two tabs.

### Usability
| Finding | Severity | Recommendation |
|---|---|---|
| Two full heroes if naively stacked (each ~82px tall + its own stat tiles) | 🔴 Critical | Collapse to ONE posture header; per-tab metrics live in the header, not a second orb |
| The "Gates" content the brief wants is on a *different page* (Tools) | 🔴 Critical | Relocate `ModuleGroupToolRow` tier control into the Gates tab (or surface a focused per-tool tier list); see §0 |
| Touch-ID reveal is invisible until you tap Copy/Rotate (`requestReveal` L608) | 🟡 Moderate | Surface reveal state in the posture header ("Touch ID to reveal: On") so the gate is legible before action |
| `CredentialsSection` ForEach keyed by `\.offset` (L216) → row identity breaks on reorder/delete animations | 🟡 Moderate | Key by a stable `service+account` id |
| Two different "add" affordances on one card (orb `+` L154 AND pill L252) — redundant | 🟢 Minor | Keep ONE primary add in the tab toolbar; drop the orb plus |
| Tier pill cycles silently with no confirm; `request`→data-loss-capable tools flip to `open` in one tap | 🟡 Moderate | Keep tap-to-cycle but add a `help`/toast on landing at `open`; mark `neverAutoApprove` tools as non-cycling (router already blocks them) |
| TCC grants auto-refresh on a 20s timer (`PermissionsSection` L27) — fine, but if merged blindly the timer runs even when the Vault tab is showing | 🟢 Minor | Gate the timer on tab visibility |

### Visual hierarchy
- **What draws the eye first (today):** the orb + 22pt title. Correct for a standalone page; **wrong for a tab host** — on a merged page the eye should land on the posture summary + the active tab, not a decorative orb that repeats per surface.
- **Reading flow:** Credentials = orb → keychain banner → rows → policy. Permissions = orb → grants → paths → reset. Merged flow must be: **posture header (status + counts) → tab bar → active-tab list**. The keychain banner and policy toggles drop *below the fold* of the Vault tab (they're reference/config, not the primary task).
- **Emphasis:** stat tiles are good (18pt monospaced value, 10pt tracked label) and **already consistent across both files** — reuse verbatim for the posture header. The "attention" tile going amber (`attentionCount > 0`) is the single most valuable signal; promote it.

### Consistency
| Element | Issue | Recommendation |
|---|---|---|
| Page padding | Credentials `.padding(18)` (L61) vs Permissions `.padding(20)` (L53) | Pick one — **20** (matches `BridgeSpacing.md` usage in `ModuleGroupList` L575) |
| Card stack spacing | both `VStack(spacing: 14)` but `ModuleGroupList` uses `BridgeSpacing.sm` | Use `BridgeSpacing.sm`/`.md` tokens, not literal 14 |
| Hero construction | Credentials/Permissions hand-roll the orb (`RoundedRectangle` 50×50 radius 14); `BridgeSettingsSectionHeader` uses a 44pt Circle | The posture header is bespoke (needs tabs+metrics), but standardize on **one** orb spec; don't ship a third variant |
| Status badge | Credentials uses filled-capsule badges (`statusBadge` L481); Permissions uses bare-text labels (`statusBadge` L274) + an LED dot on the icon | Pick one badge grammar per page. Vault = filled capsule (tone = ok/warn/bad/neutral); Gates tier = filled capsule (open=ok, notify=warn, request=bad) — already aligned in `ModuleGroupToolRow.tierTriple` L49 |
| Icon tile size | Credential icon 36×36 (L437), grant icon 34×34 (L254), module icon 30×30 (`ModuleGroupCard` L356) | Standardize row leading tile at **34×34**, radius 9 |
| Hairline divider | Credentials `hairlineFaint` 0.5 (L220); Permissions `hairline` 0.5 (L191) | Use `hairlineFaint` for in-card row separators uniformly |
| Sub-label caps | Credentials inline 10pt tracking-0.8; the shared `BridgeCardLabel` is 11pt tracking-1.2 | Use `BridgeCardLabel` everywhere; kill the inline variant |

### Accessibility
- **Contrast:** all text via adaptive `fg1–fg5`/`*Text` tokens — `okText`/`warnText`/`badText` have dedicated light-mode darkenings (`BridgeTokens.swift` L98–115), so badges pass AA on titanium. ✅
- **Legibility floor (≥11–12px):** mostly held, but **violations to fix**: `checkedLine` 10.5pt (L336/339/345/349/356), stat-tile label 10pt (L145), tier pill 10pt (`ModuleGroupCard` L87), card-label 11pt (borderline). The brief's floor is 11–12px. Bump the 10–10.5pt meta to **11pt minimum**; keep the all-caps tracked labels at 11pt (they read larger than their cap-height suggests, acceptable).
- **Hit areas:** icon buttons are 28×28 (`iconButton` L418) / 30×30 (`pmIconButton` L149) / mini toggles — **below the 44pt comfortable target but acceptable for a dense desktop utility**; keep `contentShape(Rectangle())` so the whole tile is hittable. The **tier pill** (`ModuleGroupToolRow` L85) is only ~`text+14px` wide and is the primary Gates control — give it a `minWidth`/larger vertical padding so it's a confident tap target.
- **VoiceOver:** Credentials hero adds `.isHeader` (L119); Permissions hero does NOT (L105). Add `.isHeader` to the posture header title. `credentialIcon`/`grantIcon` correctly `accessibilityHidden`. The tier pill needs an `accessibilityValue` ("gate: notify") — today it's a bare button.
- **Keyboard:** sidebar nav has arrow-key support (`BridgeShell` L183). The new tab bar must be keyboard-traversable (Tab/arrow) and the active tab `.isSelected`.

### What works well
- Token discipline is excellent — zero hardcoded palette values; every surface is appearance-adaptive.
- The **stat-tile component is identical** in both files (Credentials L139, Permissions L129) — a free, ready-made posture-metric primitive.
- "Truthful UI" rigor: `.unchecked` never reads "Valid"; `checked <relative>` is a last-known timestamp, not a fake live call (L327–364). Preserve this verbatim.
- `BridgeDepLinkRow` ("USED BY" / "REQUIRED BY") already cross-links credentials↔tools↔permissions — the connective tissue a merged Security page needs.
- `ToolTierResolution` cleanly separates *effective tier* from *its source*, which is exactly the data the Gates tab's "revoke module grant" affordance needs.

### Priority recommendations
1. **One posture header, two tabs (kill the second hero).** Biggest spatial + coherence win; resolves the density tenet directly.
2. **Resolve the Gates taxonomy (§0).** Gates = tool security tiers; relocate that control off Tools; re-home TCC as a secondary "System access" section.
3. **Normalize the dozen drift constants** (padding 18/20, tile 36/34/30, badge grammar, 10pt meta → 11pt floor) into shared values so the merged page reads as one surface.

---

## §2. Posture header (locked content)

A single bespoke header replacing both orb-heroes. Built on `BridgeGlassCard(cornerRadius:12, padding:14)`.

**Anatomy (left → right):**
- **Orb** — 44×44, the standardized tile. Glyph `lock.shield` (security), tint `BridgeTokens.gold` (Permissions' tint) OR `accent`; pick `gold` so Security reads as the "premium/protective" page distinct from blue Connection. `accessibilityHidden(true)`.
- **Title block** — `Text("Security")` 18pt semibold `fg1` `.isHeader`; subtitle 12pt `fg3`: *"Stored secrets and the gates that govern what tools can do."*
- **Posture metrics** (stat-tile component, verbatim from `statTile`): a row of tiles.
  - **`<n>` STORED** — `okText`, count from `CredentialManager.list()`.
  - **`<n>` ATTENTION** — `warnText` when `>0` else `fg4`; `attentionCount` (revoked+expiring+error, L97).
  - **`<n>` OPEN / `<n>` NOTIFY / `<n>` REQUEST** — gate-tier tool counts, `okText`/`warnText`/`badText`, computed from `tiers` map in `ModuleGroupList` (L472). Collapse to a single compact tri-segment tile if width is tight: `12 · 4 · 2` with tier-colored digits.
- **Touch-ID reveal status** — small inline chip/text: "Touch ID to reveal: On/Off" driven by `requireTouchID` (L39). Makes the gate legible before the user hits Copy.

**States:**
- All credentials valid + 0 attention → all stat tiles neutral/ok, no warning tint.
- Attention > 0 → ATTENTION tile amber; consider a 1-line affordance "Validate all" inline.
- Touch ID unavailable on device → chip reads "Touch ID unavailable" (fall through to immediate reveal, matching `CredentialRevealGate.shouldGate`).

---

## §3. Tab structure

A two-tab segmented control directly under the posture header (12pt gap, `BridgeSpacing.sm`).

- **Vault** (default/leftmost) — credentials.
- **Gates** — tool security tiers + module Always-Allow + revoke (+ secondary System-access section, §0).

Tab bar: reuse `.segmented` Picker grammar already used in `CredentialAddSheet.typePicker` (L171) for consistency, OR a custom pill bar matching `BridgeSectionNavItem` selection (accent@0.14 fill + `hairlineStrong` outline). Keyboard-traversable; active tab `.isSelected`. The 20s TCC refresh timer should only run while Gates' System-access section is visible.

---

## §4. Vault tab — row & sheet anatomy

### 4.1 Keychain banner
Keep the single keychain-safety banner (`keychainBanner` L170) — the one place "Keychain" + bundle id is named. Place it as the **first card in the Vault tab** (not the page), `BridgeGlassCard(cornerRadius:11, padding:12)`, `lock.fill` + adaptive copy. Demote visually (it's reference, not action).

### 4.2 Credential row (`credentialRow` L287)
Keep the existing anatomy; normalize sizes/floors:
- **Leading:** branded service mark in a **34×34** radius-9 tile (`credentialIcon`, currently 36 — drop to 34 to match Gates rows). NotionMark/StripeMark/SF-symbol fallback (L455).
- **Identity:** name 14pt medium `fg1`; masked subtitle 11.5pt mono `fg4` (`••••••••••<last4> · added <date>`), truncate-middle (already correct, L298–301).
- **Dep chips:** `BridgeDepLinkRow(label:"USED BY", …)` — live "used by" tool links (L302).
- **Checked line:** `checked <relative>` / "not yet validated" / "no automatic check" + inline **Revalidate** link. **Bump 10.5pt → 11pt** (L336–356).
- **Trailing:** status badge (filled capsule, tone ok/warn/bad/neutral, `statusBadge` L481) + action cluster.
- **Actions** (`actions` L367): default `Rotate · Copy · Delete` (28×28 icon buttons); **revoked/invalid → primary `Reconnect` capsule** replaces Rotate. Copy/Rotate/Reconnect fire the Touch-ID gate (`requestReveal` L608). Delete → confirmation dialog.
- **Focused state:** anchor highlight (accent@0.10 fill + accent@0.28 outline, L317) for deep-link landing — keep.
- **Row identity:** switch ForEach key from `\.offset` to stable `service+account`.
- **Separator:** `hairlineFaint` 0.5 between rows.

### 4.3 Empty state (`emptyState` L273)
Keep verbatim — "Only credentials saved through Bridge appear here…". Good copy, legible (13/12pt).

### 4.4 Policy card (`policyCard` L502)
Two real toggles, persisted: **Require Touch ID to reveal** (`requireTouchID`) and **Auto-validate weekly** (`autoValidateWeekly`, runs immediate check when toggled on if due, L515). Keep at the **bottom of the Vault tab**. Use `.switch` toggles; title 13.5pt `fg2`, sub 11.5pt `fg4`. (Touch-ID toggle is also mirrored read-only in the posture header chip.)

### 4.5 Add / Rotate / Reconnect sheet (`CredentialAddSheet`)
Keep as-is — it's already premium and correct:
- 460pt fixed width, min 360 height, `bgRaised` background (L109–111).
- Header orb (40×40 radius 11) + title/subtitle that adapt to add/rotate/reconnect (L143–154).
- Type segmented picker (add only; locked in replace, L168).
- Per-type fields: API key (name+secret), Password (service+account+secret), Card (name+number+expiry+CVC+ZIP with Luhn/expiry validation L351). Card tokenization note (L201).
- Footer: Cancel (`.bordered`) + Save/Rotate/Reconnect (`.borderedProminent`, `defaultAction`), disabled until `isValid` (L289).
- Biometric gate fires inside `CredentialManager.save` — the sheet is the only write path. Preserve.
- **Single add entry point:** drop the orb `+` (L154); keep ONE add button in the Vault tab toolbar (the pill, L252) so there aren't two adds on one surface.

---

## §5. Gates tab — tier, Always-Allow, revoke

The brief's core new surface. Content = the tool security-gate model currently embedded in `ModuleGroupToolRow` + `ModuleGroupList`.

### 5.1 Layout
A scrollable list of **module groups** (reuse `ModuleGroupDerivation.deriveGroups`), each a `BridgeGlassCard`. But the Gates tab is **gate-first, not enable-first** — unlike the Tools page (which leads with on/off toggles), Gates leads with the **tier** of each tool. Two viable densities:

- **Grouped (recommended):** collapsible module card → per-tool rows showing **name (mono 12.5) · one-line desc · tier pill**. Drop the on/off toggle here (that's Tools' job); Gates is purely about *how* an enabled tool is gated.
- **Flat-by-tier:** sort all tools under Open / Notify / Request headers. Denser but loses module context and the Always-Allow grant model. Prefer grouped.

### 5.2 Module header — the Always-Allow grant
Each module card header shows the **module-scoped grant** (`moduleTierOverrides[module]`, the literal "Always Allow"):
- If a module grant exists → a chip "Always-Allow: NOTIFY" (tier-colored) + a **Revoke** affordance (clears `moduleTierOverrides[module]`, tools fall back to registered defaults). This is the `ToolTierSource.moduleGrant` case made visible/revocable.
- If no grant → "Per-tool / default".
- Count badge: "N of M elevated" (tools whose effective tier ≠ registered default).

### 5.3 Per-tool tier row (`ModuleGroupToolRow` L36)
- **Leading dot:** 7px (keep), but in Gates color it by **tier risk**, not enabled-state, OR keep enabled-dot and let the pill carry tier. Recommend tier-colored.
- **Name:** mono 12.5pt `fg1`; **desc:** 11.5pt `fg4` truncate-tail.
- **Tier pill (primary control):** tap-to-cycle Open→Notify→Request→Open (`onTierTap`/`cycleTier` L501). Labels OPEN/NOTIFY/REQUEST; colors `okText`/`warnText`/`badText` on tinted capsule (`tierTriple` L49). **Enlarge** the pill (min width + ≥3px vertical pad) — it's the main action, currently a 10pt/2px-pad chip. **Bump label 10pt → 11pt.** Add `accessibilityValue("gate: <tier>")`.
- **Source annotation:** small 11pt `fg5` suffix when the tier comes from a module grant — "via <module> Always-Allow" (`ToolTierSource.moduleGrant`) — so the operator knows why a tool is elevated and where to revoke. When `ownOverride`, no annotation (it's explicit). This is the file's documented purpose (`ToolTierResolution.swift` header).
- **Per-tool revoke:** cycling a tool back to its base (module grant or registered default) clears its own override automatically (`cycleTier` L508) — already correct; surface a subtle "reset" affordance on rows with `ownOverride`.
- **`neverAutoApprove` tools:** the pill should be non-cycling / locked at `request` with a lock glyph (router blocks Always-Allow for these per `SecurityGate.swift` L9). Today the UI lets it cycle visually; lock it.

### 5.4 Secondary: System access (TCC) — re-homed from `PermissionsSection`
If Reading A holds, the TCC grant content gets a **secondary section at the bottom of Gates** (or a third tab if the operator insists — flag). Reuse `grantsCard` (L168) verbatim: LED-badged 34×34 icon tile + grant name + status badge + remediation + "REQUIRED BY" dep chips + Allow/Open-Settings. Plus `sensitivePathsCard` (L411) and the destructive **Reset all permissions** (`managementCard` L428). Keep the 20s/activation refresh (L57–63) but gate on visibility.

---

## §6. Density, states, edge cases

**Density (apply the tenet):**
- Page padding **20** (one value).
- Card spacing **`BridgeSpacing.sm`**.
- Row vertical padding: Vault 5–8px, Gates tool rows 8px (current) — keep tight.
- Truncate-with-reveal over shrinking: masked subtitle truncates middle; descriptions truncate tail; never shrink below 11pt.
- One add entry point; one badge grammar; one icon-tile size (34×34).

**States:**
- **Loading** — Vault `ProgressView` in card header (L200); Gates inherits live tools.
- **Empty Vault** — keep `emptyState`.
- **Validating all** — spinner in posture header + per-row "Checking…" (`checkedLine` busy, L333).
- **Revoked credential** — bad badge + Reconnect primary.
- **Expiring card** — local expiry verdict (`CredentialCardExpiry`, L554), warn badge, no network revalidate (cards aren't `isValidatable`, L565).
- **Module grant active** — header chip + Revoke; tools show "via … Always-Allow".
- **`neverAutoApprove` tool** — locked Request pill.
- **TCC denied** — LED red + Allow/Open-Settings; restart/csreq banners (`PermissionView` L231/L270) if surfaced.

**Edge cases:**
- Touch ID unavailable → reveal passes through; header chip says so.
- Credential deleted while validating → `store.prune` (L646) drops stale health; ensure new stable row id so the deleted row animates out cleanly.
- Deep-link anchor into Vault (focused row) and into Gates (module auto-expand, `forceExpanded` L155) — preserve both; the tab host must switch to the correct tab when a `BridgeDepLink` targets it.
- Orphaned credential whose "used by" maps to no live tool → empty USED BY row (handled by `BridgeDepLinkRow`).
- Tier change posts `.notionBridgeTierOverridesDidChange` (L514) so the posture-header counts live-update — wire the header to that notification.

---

## §7. Migration notes (for the implementer)

1. **Build the tab host + posture header first**; embed the existing `CredentialsSection` body (minus its hero/second-add) as Vault, and a new Gates view (extracted tier control from `ModuleGroupList`).
2. **Do not duplicate the tier-cycle logic** — lift `cycleTier`/`nextTier`/`tiers`/`toolMeta` (L472–515) into a shared model so Tools and Gates read the same `BridgeDefaults.tierOverrides` / `moduleTierOverrides`. (Today Tools owns it; Gates must share, not fork.)
3. **Decide TCC's home (§0)** before wiring — it's the one open question that changes the tab count.
4. Normalize the drift constants (§1 Consistency) in one pass.
5. Keep all "truthful UI" guarantees and the biometric gate path untouched.
