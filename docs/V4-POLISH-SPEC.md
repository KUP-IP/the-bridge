# The Bridge v4 — Master UI/UX Polish Spec

> Branch `feat/v4-redesign`. v3.7.12 (the redesign) shipped, but an on-device review found visual inconsistencies the code-level QA couldn't see. This sheet drives the polish pass: per-page **VISUAL** (fidelity to the Claude Design handoff in `design/the-bridge-design-system/`) **+ UX/BACKEND** (functionality), remediated by dispatched sub-agents. Audit method: on-device window capture (light **and** carbon) vs the design files.

## Root-cause reframe
The bulk of "many inconsistencies" is **one global cause**: the carbon (dark) theme renders the full Liquid-Glass depth, but the **titanium (light) theme renders flat** (cards lose bevels, hairline edges, shadows). Shared material layer → degrades *every* page in light mode. Fix globally first (cascades), then per-page specifics on the corrected base.

---

## A. GLOBAL (foundation — fix once, cascades to all pages)
| ID | Requirement | Status |
|----|-------------|--------|
| **G1** | **Titanium/light theme renders flat** — restore the design's titanium glass depth: hairline edges (`rgba(15,18,28,.10)`), bevel (bright-white top rim `rgba(255,255,255,.34)` + cool bottom occlusion), cool drop shadows — so light-mode cards read as frosted glass, not flat white. Carbon UNCHANGED. (BridgeTokens + BridgeThemeV2 + BridgeUIKit light branch.) | 🔄 dispatched (agent a599) |

## B. SECURITY / BACKEND (separate workstream — v4 T1 audit findings)
| ID | Sev | Finding | Status |
|----|-----|---------|--------|
| **S1** | HIGH | Sensitive-path gate bypassable via `..`/symlink path traversal (`~/.ssh`,`~/.aws`,Keychains) — `file_read` is tier `.open` → zero-interaction, cloud-reachable. Fix: canonicalize + component-boundary match. | 🔄 dispatched (agent a9b9) |
| **S2** | HIGH | Safe-command auto-allow bypasses tier prompt + sensitive-path gate via shell metacharacters. Fix: reject metachars, reorder sensitive-path before auto-allow. | 🔄 dispatched (a9b9) |
| **S3** | MED | Stripe form-param injection on the `credential_save` card tool path (unvalidated → unescaped). Fix: Luhn-validate + `formURLEncoded`. | 🔄 dispatched (a9b9) |
| S4… | MED/LOW | connector-oauth (×2 med), credential_read "Always-Allow" silences all reads, non-constant-time loopback compare, etc. | 📋 T2/T3 backlog |

## C. PER-PAGE (VISUAL + UX/BACKEND) — audited on the depth-fixed base, one at a time
| # | Page | Status | Notes |
|---|------|--------|-------|
| 1 | Orders + Commands | 🔍 audited (light+dark) | dominated by G1; page-specific items pending re-audit post-depth-fix |
| 2 | Skills | ⏳ pending | |
| 3 | Jobs | ⏳ pending | |
| 4 | Tools | ⏳ pending | |
| 5 | Security | ⏳ pending | |
| 6 | Connection | ⏳ pending | |
| 7 | Advanced | ⏳ pending | |
| 8 | Dashboard (menu-bar popover) | ⏳ pending | |
| 9 | Command Bridge (⌃⌘B) | ⏳ pending | |
| 10 | Onboarding wizard | ⏳ pending | |

*(Each page row expands into a VISUAL list + a UX/BACKEND list before its remediation sub-agent is dispatched.)*
