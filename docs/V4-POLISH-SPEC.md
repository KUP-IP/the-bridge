# The Bridge v4 — Master UI/UX Polish Spec

> Branch `feat/v4-redesign`. v3.7.12 (the redesign) shipped; this sheet drove the post-ship polish toward ~95% visual compliance. Audit method: on-device window capture (display 0) of each surface via the live Settings window, compared against the Liquid-Glass design system (`design/the-bridge-design-system/` tokens.css/materials.css + sprint design language). **Status 2026-06-15:** G1 + security committed; per-page audit complete (8/10 surfaces captured); only Skills needed page-specific fixes.

## Root-cause reframe (CONFIRMED)
The bulk of "many inconsistencies" was **one global cause — G1**: the titanium (light) theme rendered flat (cards lost bevels/edges/shadows) while carbon (dark) rendered full depth. Fixed (commit `c37e468`) and **verified on-device** — light-theme cards now read as frosted glass. The per-page audit on the fixed base confirms the reframe: with G1 resolved, 6 of 7 settings pages + the Command Bridge are faithful; only **Skills** had concrete page-specific defects.

---

## A. GLOBAL (foundation)
| ID | Requirement | Status |
|----|-------------|--------|
| **G1** | Restore titanium/light glass depth (hairline edges, bevel rim + occlusion, cool drop shadows); carbon untouched. | ✅ **DONE** — commit `c37e468`; verified on-device (Orders/Tools/Security/etc. render frosted-glass depth in light mode). |

## B. SECURITY / BACKEND (v4 T1 audit findings)
| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **S1** | HIGH | Sensitive-path gate bypass via `..`/symlink traversal (`~/.ssh`,`~/.aws`,Keychains). | ✅ **DONE** — `c60c7e4` (canonicalize + component-boundary match; gate before auto-allow). |
| **S2** | HIGH | Safe-command auto-allow bypass via shell metacharacters. | ✅ **DONE** — `c60c7e4` (reject metachars + `-exec/-execdir/-ok`). |
| **S3** | MED | Stripe form-param injection on `credential_save` card path. | ✅ **DONE** — `c60c7e4` (Luhn-validate + percent-encode). |
| — | — | +23 regression tests; floor 1884→1907, 0 failed. | ✅ verified |
| S4… | MED/LOW | connector-oauth ×2, credential_read always-allow scope, constant-time loopback compare. | 📋 T2/T3 backlog (roadmap → 3.8.8) |

## C. PER-PAGE AUDIT (display 0, light/titanium, on the G1-fixed base — 2026-06-15)
| # | Surface | Verdict | Notes |
|---|---------|---------|-------|
| 1 | Orders + Commands | ✅ clean | G1 depth verified; consistent components (segmented / favorite-slot chips / emoji picker / Command-Bridge toggle); truthful "shortcut not active" banner showing ⌃⌘B. |
| 2 | Skills | ✅ **FIXED** | **S-1** stat-tile labels wrapped mid-word ("ROUTI NG", "SPECI ALIST"); **S-2** filter-tab labels wrapped ("Notio n", "Googl e Docs"). Fix: `BridgeStatTile` + `BridgeSegmented` labels → `lineLimit(1)` + `minimumScaleFactor` (shared-component fix; wide tiles/tabs already fit, unaffected). |
| 3 | Jobs | ✅ clean | Scheduler "Healthy" badge, status-pill row, well-designed empty states (No scheduled jobs / Recent Runs). |
| 4 | Tools | ✅ clean | Header stat tiles fit; family/tool table with ON-counts + tier badges (Notify/Open/Confirm) + per-row toggles. |
| 5 | Security | ✅ clean | Posture mirror (Balanced + Locked-down/Balanced/Open), License card (grandfathered "early user" / Licensed 3.x), Keychain banner, Vault/Gates tabs, credential rows with Valid/Unchecked badges. *Sub-95 = deliberate truthful-UI divergence (awaits operator ratification), not a defect.* |
| 6 | Connection | ✅ clean | Endpoint "Online", Agent-Handshake doctrine card, real connected client (claude-code · Live), Local Endpoint (loopback/no-token), Remote Access truthfully "Coming soon". |
| 7 | Advanced | ✅ clean | Startup/Updates toggles, About (version/protocol/bundle), Network port, Local Endpoints, System Paths. |
| 8 | Dashboard (menu-bar popover) | ⏭️ deferred | Resists programmatic capture (NSPopover focus-dismiss + ambiguous menu-bar icon coords + neighbor app icon). ~96% in sprint QA. Manual re-audit if wanted. |
| 9 | Command Bridge (⌃⌘B) | ✅ clean | Glass command palette: toolbar (tools/navigate/edit + app icons) + "Bridge Command" input + keyboard hints (↵ fire favorite · ⇥ browse). |
| 10 | Onboarding wizard | ⏭️ deferred | Needs first-run / onboarding-state reset to trigger. ~96% in sprint QA. |

**Outcome:** post-G1, the app is at ~95%+ visual compliance. Only Skills needed page-specific fixes (applied). Verify the Skills fix on-device (build → install → re-capture), then commit. Optional follow-ups: Dashboard/Onboarding manual re-audit; ratify the Security truthful-UI divergences.
