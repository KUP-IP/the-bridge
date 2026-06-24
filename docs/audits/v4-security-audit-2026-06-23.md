# The Bridge — v4 Security & Test-Coverage Audit (2026-06-23)

**Scope:** the full MCP server surface on `feat/v4-redesign`, for the PRJCT-2754
"Ship The Bridge v4" *test+security audit-clean* DoD (packets T1/T2/T3).
**Method:** 6-lens multi-agent audit (off-loopback auth/R5 · tool tiers+annotations ·
secrets/credential handling · input-validation/path-traversal · fail-closed posture +
error leakage · test-coverage gaps), each finding adversarially verified by independent
skeptics before inclusion. 11 raw findings, 1 confirmed high, 0 refuted.

## Verdict: `minor-gaps` — shippable after the two auth-sensitive items are closed and reviewed against R5

**The off-loopback trust boundary is sound — zero confirmed critical/high *security*
findings, no exploitable open door.** The PKT-810 R5 contract was verified *correct* in
code: legacy `/sse` + `/messages` are dispatched **before** the `/mcp` gate and 403
tunnel-origin requests (`SSETransport.swift:1646-1679`); the tunnel predicate keys only on
Cloudflare `Cf-*` headers with no spoofable loopback path; only `/health` + a
correctly-configured PRM are intentionally tunnel-reachable unauthenticated. The single
confirmed *high* is a test-coverage hole, not a security defect.

## Findings & remediation status

| # | Sev | Packet | Finding | Status |
|---|-----|--------|---------|--------|
| 10 | low | T1 | `skill_delete` irreversible hard-delete at `.notify` (no confirmation) | ✅ **FIXED** `28c46ca` → `.request` + `neverAutoApprove` + annotation |
| 7 | low | T3 | `bg_run` double-escapes single quotes → corrupts `echo "it's"` | ✅ **FIXED** `28c46ca` (embed raw) + LIVE regression test |
| — | — | — | `job_delete` irreversible hard-delete at `.notify` (pre-audit) | ✅ **FIXED** `1e85bb6` → `.request` + `neverAutoApprove` |
| 1 | med | **E-wave3** | `isMisconfigured()` exists + unit-tested but **has zero callers** — a placeholder-issuer build silently advertises `auth.example.invalid` as its authorization server in PRM (`jsonBody` never consults it) instead of failing loud | 🔶 **OPEN — REVIEW-FIRST** (auth-serving path) |
| 2 | med | T2 | Legacy `/sse`+`/messages` loopback-only 403 gate is **predicate-tested only**, never driven end-to-end to a real outbound 403 (asymmetric with `/mcp`, which is E2E-tested) | 🔶 **OPEN — REVIEW-FIRST** (asserts R5 boundary; test-only, additive) |
| 3 | **high** | T2 | `BgProcessRuntime` actor (backs dev runners + launch-time orphan reconciliation: kill cascade, `reconcileOrphans`, `finalizeExit` race, atomic `writeMeta`) has **zero test references** | ⬜ OPEN (additive tests; hermetic `init(baseDir:)` seam exists) |
| 4 | med | T3 | `file_read` slurps the whole file into memory before applying `maxBytes` (unbounded-read / memory-exhaustion; `/dev/zero` streamable) `FileModule.swift:284` | ⬜ OPEN (bound the read: `FileHandle.read(upToCount:)` + reject non-regular files) |
| 5 | med | T3 | `bg_poll` reads the entire job log into memory on **every** poll `BgProcessModule.swift:316` | ⬜ OPEN (tail from EOF over a bounded window) |
| 6 | med | T2 | `bg_run`/`bg_kill` missing coverage: concurrent-launch jobId collision, SIGKILL escalation, dead-pid-no-sentinel, login-shell branch | ⬜ OPEN (additive tests) |
| 8 | low | T1 | Notion/Stripe secrets persisted in **world-readable** `config.json` (no `0o600`) `ConfigManager.swift:57-61` | ⬜ OPEN (write with `posixPermissions: 0o600`; finish Notion-token→keychain migration) |
| 9 | low | T3 | `bg_kill` trusts the pid sidecar verbatim — recycled-pid TOCTOU could signal an unrelated process `BgProcessModule.swift:415` | ⬜ OPEN (record+re-verify child start-time, or signal own process-group) |

## Recommended next waves

1. **DoS + hygiene batch (T3/T1, non-auth, parallelizable):** #4, #5 (bounded reads, same fix shape), #8 (`0o600` perms), #9 (pid re-verify). All build+gate-verifiable, low regression risk.
2. **Coverage batch (T2, additive, raises the floor):** #3 (`BgProcessRuntimeTests`, 6 hermetic cases via the `init(baseDir:cleanupTTL:killGracePeriodSec:)` seam), #6 (bg_* edge cases).
3. **Auth-sensitive (REVIEW-FIRST — must not change loopback behavior; keep `/health` + a correctly-configured PRM tunnel-reachable):**
   - #1 = **Packet E Wave 3**: wire `isMisconfigured()` into the PRM-serving path (`SSETransport.swift:1634-1644`) so a misconfigured build refuses to advertise the placeholder AS (503/omit `authorization_servers`) + surfaces the misconfig to the operator at launch when HTTP is active; add a *serving-path* test.
   - #2: add end-to-end NIO tests in `RemoteOAuthOriginGatingTests.swift` driving real dispatch (tunnel-origin `GET /sse` / `POST /messages` → assert outbound 403 `loopback-only`; loopback twins assert served).

## Remediation status (updated 2026-06-23)

- **Batch 1** (`1e85bb6`, `28c46ca`, + pre-audit `1e85bb6`): #10 `skill_delete` confirm-gate + #7 `bg_run` double-escape + `job_delete` confirm-gate. ✅
- **Batch 2** (`20b24f9`): all six non-auth findings — **#3** `BgProcessRuntime` coverage (6 tests via the `init(baseDir:)` seam), **#4** `file_read` bounded read + non-regular-file rejection, **#5** `bg_poll` 256 KB tail window, **#6** bg_* coverage (concurrency/SIGKILL/terminated/login-shell), **#8** `config.json` `0o600`, **#9** `bg_kill` process-group signalling — implemented + gate-green. Floor 2227 → **2242** (+15 tests). ✅
  - **#9 caveat:** `set -m` + `kill(-pid,…)` closes the common recycled-pid vector; the `ESRCH`→single-pid fallback retains a *narrow* residual TOCTOU (recycled pid that is a live non-group-leader). Acceptable for a low finding — tighten later by dropping the fallback for `set -m`-era jobs if desired.
  - **#4 note:** `file_read` now imposes a **50 MB default ceiling** where reads were previously unbounded — intended hardening; revisit if a legitimate >50 MB read without `maxBytes` is needed.
- **#1 + #2 — REVIEW-FIRST (auth): ✅ DONE** — implemented (`ddf9154`), triple adversarially-reviewed R5-safe (origin gate byte-unchanged), merged via **PR #44** (`729c40e`). **#1** Packet E Wave 3 fail-loud PRM gate (`prmServingDecision()` → 503 with no `authorization_servers` when `isMisconfigured()`; the configured 200 PRM is byte-identical). **#2** legacy `/sse`+`/messages` 403 end-to-end tests. Floor 2242 → **2250**.
- **Test hermeticity follow-up: ✅ (`RemoteOAuth{HTTP,Bearer}Tests`)** `metadata()` / `jsonBody()` gained injectable `config`/`baked` seams; the 8 PRM/identity-default tests in those two files now pin `baked: ""`, so they pass whether or not `make build` baked an identity into the binary (verified: all 8 green under a real baked identity; empty-state gate stays 2250/0).
  - **Deliberately left coupled** (commit-guards — they alert if a non-empty identity is ever committed): the `RemoteAccessIdentityTests` + `RemoteAccessConfigWave2Tests` *"committed build is fail-closed"* cases.
  - **Recommended further follow-up** (analogous, WorkOS subsystem, out of the named scope): 2 `EnableCloudAccessFlowTests` cases (`WorkOSConfig.resolved` empty-env → placeholder) need the same `baked` injection to be bake-robust.

> The findings table above is the original discovery snapshot; this ledger is the authoritative remediation record. **All 11 audit findings are now remediated.**
