# Sprint Plan — Close "Ship The Bridge v3"

**Date:** 2026-06-06 · **Driver:** FOCUS Keepr (Reflow Mode) · **Operator:** Isaiah
**Hub:** Ship The Bridge v3 (Notion `268b2a2a`) · **Repo:** `~/Developer/the-bridge` `integration/v3.7.7`

This sprint sequences the remaining non-terminal packets into the fastest path to Done. It builds on `OPERATOR-ACTION-PLAN.md` (the gate-by-gate reference) and adds: post-968 state, a parallelized wave order, an explicit agent-vs-operator split, the exact verification hooks the agent runs, and a plan for PKT-966 (which the action plan omits).

## Sprint goal
Every remaining hub packet at Done or correctly dispositioned; v3.7.7 merged to `origin/main`, tagged, and live across cloud + OS surfaces; hub closed via close-project.

## Current state
- Build: `integration/v3.7.7` @ `d312e68`, **30 commits ahead** of `origin/main`, working tree clean.
- Gate (verified): `make build` 0 errors · `make test-floor` **2014 passed / 0 failed** (floor 1950) · 209 tools / 29 families.
- Reminders + Calendar **TCC already granted** on the running build (verified live).
- **Closed this session:** PKT-968 Live OS gates → Done (live read + write + delete round-trip; recurrence, relative alarm, and geofence all persisted; calendar event round-tripped).
- Remaining non-terminal: **10** — Track A ×7 (917, 920, 810, 922, 921, 923, 801), 932, 965, 966.

## Owner split
- **Agent-finishable now:** 966 (Notion skill edits). Plus all Track A/B/C *verifications* once a gate clears.
- **Operator-only gates:** the merge/push, cloud accounts (WorkOS + Cloudflare + domain), the Sparkle two-version live test, the memory design answers.

## Waves (recommended order — fastest Done first)

**Wave 0 — DONE:** 968. ✅

**Wave 1 — no cloud, run in parallel:**
- **966 skill-content restructure** — *agent executes* (skill-keepr; apply `design/SKILL-AUDIT.md` across the 7 routing parents; PROTECT: notion §Write-Mechanics, project §3, people §LD; Status/Maturity written LAST). Gate: operator GO (edits constitution-level skills). Closes on re-audit grade A.
- **932 Sparkle** — *operator*: install an older signed build, trigger update to the new build, confirm atomic relaunch. Agent pre-checks appcast/signature. Blast radius already confirmed dev-only; residual is the live E2E.

**Wave 2 — the push (operator):** review `integration/v3.7.7` → merge `main` → tag `v3.7.7` → `release.yml` builds/notarizes/publishes. This clears the "pushed" half of every REVIEW packet.

**Wave 3 — cloud cluster (strictly sequential):**
A1 deploy Worker → **917** · A2 bind route + WorkOS verify → **920** · A3 provision WorkOS/Cloudflare/domain + 8 Mac env vars → **810** · A4 live E2E → **922 / 921 / 923** · A5 submit directories → **801**.
Operator owns accounts/deploy; agent runs the verification hook for each and flips the packet on green.

**Wave 4 — 965 memory (operator):** answer `v3.7.7-memory-design-questions.md` (Q6 first — store-unification, load-bearing). Moves blocked → scopable; agent then specs the build wave.

**Track E — 943 / 946:** decline in-repo + file upstream (harness-side, out-of-repo).

## Agent verification hooks (run per gate, then flip Status→Done + sign-off comment)
- **917:** `curl https://<worker>/healthz` OK; `DRY_RUN=1 ./deploy.sh` clean.
- **920:** route resolves over TLS; `verify` no longer throws for a valid WorkOS token.
- **810:** `curl https://bridge.kup.solutions/.well-known/oauth-protected-resource` → 200 with the **real** issuer.
- **922/921/923:** `BASE_URL=… EXPECT_ISSUER=… scripts/validate-connector.sh` exits 0 + provision/heartbeat/liveness round-trip observed.
- **801:** legal URLs live; both submissions accepted; record dates.
- **932:** post-update `CFBundleShortVersionString` reflects the new version; clean relaunch.

## Exit
Track A green in order · 932 verified · 968 done · 965 scoped · 966 done · 943/946 declined+filed → close-project on the hub with the cumulative retro.
