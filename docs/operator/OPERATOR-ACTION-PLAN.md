# Operator Action Plan — Close "Ship The Bridge v3"

**Date:** 2026-06-05 · **Branch this lives on:** `feat/fb-operator-runbooks` · **Sprint:** v3.7.6 cloud sprint

This is the dependency-ordered list of **operator-only** actions to close the remaining packets for "Ship The Bridge v3". Each step states the concrete action, the runbook that backs it, and the packet it closes. The executor has done everything that can be done autonomously (code, audits, drafts, deploy automation, dry-runs); the steps below require **your** accounts (WorkOS, Cloudflare, the kup.solutions domain), on-device TCC grants, or a live update test — none of which can be performed for you.

**Do NOT mark any packet Done until its verification step here passes.** The packets stay in their current Status until you act.

---

## Tracks at a glance

| Track | Packets closed | Gating dependency |
|---|---|---|
| A. Cloud (deploy → provision → live E2E → submit) | 917, 920, 810, 922, 921, 923, 801 | strictly sequential within the track |
| B. Live OS gates (TCC) | 968 | independent of A; needs the installed app |
| C. Sparkle atomic install | 932 | independent; needs two app versions |
| D. Unified Memory design | 965 | needs your answers; unblocks scoping only |
| E. Harness-side feedback (decline + upstream) | 943, 946 | not in this repo |

Tracks A–E are mutually independent and can run in parallel. **Within Track A the order is mandatory** — each step's output is the next step's input.

---

## TRACK A — Cloud (the critical path)

Backed by: `docs/operator/cloud-deploy-runbook.md`, `docs/operator/deploy.sh`, `docs/operator/connector-provisioning-runbook.md`, `docs/operator/connectors/submission-checklist.md`, `scripts/validate-connector.sh`.

### A1. Deploy the Worker control plane — closes **WS-A (917)**
Runbook: `cloud-deploy-runbook.md` steps (a)–(c); automated by `deploy.sh` steps 1–4.

1. From `/Users/keepup/Developer/kup-worker`, create the KV namespace:
   `wrangler kv namespace create TENANTS` and `wrangler kv namespace create TENANTS --preview`.
2. Paste both ids into `wrangler.toml` under `[[kv_namespaces]]` (binding MUST be `TENANTS`).
3. Put the one real secret: `wrangler secret put CAPABILITY_SIGNING_SECRET` (generate with `openssl rand -base64 48`).
4. `npm test` (confirm 28 green) then `wrangler deploy`.
   - Or run all four with `./deploy.sh` (it prompts you to paste the KV ids, then continue with `SKIP_KV=1 ./deploy.sh`).
   - Validate first without shipping: `DRY_RUN=1 ./deploy.sh` (already verified clean: 36.93 KiB, exit 0).
- **Verify:** `curl https://<worker-url>/healthz` returns OK. (Authed endpoints will still 401 — that is expected here; see A2's blocker.)
- **Closes WS-A 917** once the Worker is deployed and `/healthz` is live.

### A2. Bind the control-plane route + wire WorkOS verify — closes **WS-B (920)**
Runbook: `cloud-deploy-runbook.md` steps (d)–(e); provisioning runbook §B1.

1. Bind `bridge.kup.solutions` to the Worker (dashboard: Workers & Pages → kup-worker → Settings → Domains & Routes, or `routes = [{ pattern = "bridge.kup.solutions", custom_domain = true }]` in `wrangler.toml`, then re-deploy). The zone `kup.solutions` must be on this Cloudflare account.
2. Set `WORKOS_JWKS_URL` and `WORKOS_AUDIENCE` (toml vars or `wrangler secret put`), then re-deploy.
3. **Code gap to close before live E2E:** `WorkOsIdentityProvider.verify` in `kup-worker/src/identity.ts` is an intentional stub that throws. Until a live WorkOS verify impl is wired, every authenticated endpoint (`/provision`, `/heartbeat`, `/t/:id/*`) returns 401 — only `/healthz` works. This is the last code gap between "deployed" and "live E2E"; wire it (or have an executor wire it) as part of WS-B.
- **Verify:** the route resolves over TLS and `verify` no longer throws for a valid WorkOS token.
- **Closes WS-B 920** once the route is bound and the verify path is live.

### A3. Provision WorkOS + Cloudflare + domain (Mac host env) — closes **810**
Runbook: `cloud-deploy-runbook.md` steps (e)–(f); provisioning runbook §B1.

1. WorkOS dashboard: create/select the AuthKit application; enable **CIMD** (preferred) **and** **DCR** (fallback); configure the `connector.step_up` scope to be minted **only after explicit per-elevation human consent**. Record issuer + JWKS URL; copy the public `client_id`.
2. Add redirect URI **exactly** `bridge-auth://callback`.
3. Cloudflare Tunnel: terminate TLS and route `https://bridge.kup.solutions` → `127.0.0.1:<NOTION_BRIDGE_PORT>` (outbound-only; no inbound ports).
4. Set the **8 Bridge (Mac) host env vars** (launchd plist EnvironmentVariables or launch context), then restart the app to re-handshake:
   - `BRIDGE_ENABLE_HTTP=1` (exact "1")
   - `BRIDGE_OAUTH_ISSUER=https://<your-workos-issuer>`
   - `BRIDGE_OAUTH_JWKS=<inline JWKS JSON OR /abs/path/to/jwks.json>`
   - `NOTION_BRIDGE_PORT=9700` (the SSE/`/mcp` port — NOT `BRIDGE_PORT`)
   - `BRIDGE_CLOUD_BASE_URL=https://bridge.kup.solutions`
   - `WORKOS_CLIENT_ID=client_<real>` (placeholder `client_PLACEHOLDER_pkt810` blocks the Enable flow)
   - `WORKOS_BASE_URL=https://api.workos.com`
   - `WORKOS_REDIRECT_URI=bridge-auth://callback`
- **Verify:** `curl https://bridge.kup.solutions/.well-known/oauth-protected-resource` returns `200 application/json` with your **real** issuer (not `https://auth.example.invalid`).
- **Closes 810** once WorkOS + Cloudflare + domain are provisioned and the Mac env is set + app restarted.

### A4. Live end-to-end validation — closes **WS-F (922) / WS-D (921) / WS-G (923)**
Runbook: provisioning runbook §B2; `scripts/validate-connector.sh`; `cloud-deploy-runbook.md` step 8.

1. Run the Enable Cloud Access flow on the Mac → exercise `/provision` → `/heartbeat` → `/t/:id/tools` and confirm online/offline transitions (the `OFFLINE_THRESHOLD_MS` default is 30000).
2. One-shot connector validation — gate on a clean exit:
   `BASE_URL=https://bridge.kup.solutions EXPECT_ISSUER=https://<your-workos-issuer> scripts/validate-connector.sh`
   Add `BEARER=<test token> STEPUP_TOOL=<a destructiveHint tool>` to also exercise scope + forged-`_stepUp` → 403.
   The script checks: PRM RFC-9728 shape + your real issuer + the 5 scopes; unauthenticated `/mcp` → 401 + `WWW-Authenticate: Bearer`; `/health` non-regression; forged `_stepUp` on a destructive tool → 403.
- **Verify:** `validate-connector.sh` exits 0 and the provision/heartbeat/liveness round-trip is observed.
- **Closes WS-F 922, WS-D 921, WS-G 923** once the live E2E (provision, heartbeat/liveness, tool surface) is green.

### A5. Submit to the connector directories — closes **801**
Runbook: `docs/operator/connectors/submission-checklist.md`; `connector-directory-submission.md` §4.

1. **Publish the two legal docs** at stable public URLs first (the directory forms require live Privacy + Terms URLs). Suggested: `https://kup.solutions/the-bridge/privacy` and `.../terms`. Fill the bracketed placeholders in `docs/operator/connectors/privacy-policy.md` and `terms-of-service.md`: legal/operating entity name, contact (isaiah@kup.solutions on file), governing-law jurisdiction, effective date (2026-06-05).
2. Work the checklist top-to-bottom; gate on the §5 validation run (A4) being clean.
3. **Anthropic Connectors Directory:** name `The Bridge`, remote MCP URL `https://bridge.kup.solutions/mcp`, the PRM URL, Auth = Authorization Code + PKCE via WorkOS AS, the scope list, short description, the two legal URLs. Reviewer note: the destructive-tool human gate lives in the `connector.step_up` OAuth scope, NOT in an MCP tool annotation (`requiresConfirmation` is Bridge-internal, not on the wire).
4. **ChatGPT Developer Mode:** register the same endpoint; it self-registers via DCR/CIMD against the WorkOS AS.
- **Verify:** both submissions accepted into review; record submission date.
- **Closes 801** on submission. (The tool-annotation audit is already 100% and build-enforced — no operator action there.)

---

## TRACK B — Live OS gates (TCC) — closes **968**
Runbook: `docs/operator/live-os-gates-tcc.md`. Independent of Track A; needs the installed Bridge app.

1. **Grant TCC:** with The Bridge running, call one WRITE tool per domain — `reminders_create` then `calendar_create`. On a fresh (`.notDetermined`) Mac the native consent dialogs appear (the app self-activates); click **Allow Full Access** on both. (If you already denied, the dialog will NOT reappear — enable manually: System Settings → Privacy & Security → Reminders = ON; Calendars = **Full Access**, not Add-Only.)
2. **Verify (read + write round-trip):** `reminders_lists` and `calendar_list` return the documented shapes (`{ count, lists:[{id,title,isDefault,allowsModify}] }` / `{ count, calendars:[...] }`); then `reminders_create`+`reminders_delete` and `calendar_create`+`calendar_delete` round-trip cleanly. Clean up probe records.
- **Closes 968** once both read+write round-trips succeed. (All four code-side gates — Info.plist full-access keys, registry wiring, `requestFullAccess*` consent path — are already present and verified; this is verification-only, no code change.)

---

## TRACK C — Sparkle atomic install — closes **932**
Branch: `feat/fb-sparkle-atomic-install`. Reference: `docs/release/sparkle-troubleshooting.md`. Independent; needs two app versions.

1. **Install the branch:** check out `feat/fb-sparkle-atomic-install`, build, and install the resulting app (the branch carries the atomic-install fix + the v3.7.6 Sparkle appcast).
2. **Run a live cross-version update E2E:** install an **older** signed build first, then trigger a Sparkle update to the new build and confirm the update **applies atomically** — the app relaunches on the new version with no half-written bundle, no "damaged app" Gatekeeper error, and settings/state intact across the version bump.
3. **Verify:** post-update `CFBundleShortVersionString` reflects the new version; relaunch succeeds; no rollback/corruption.
- **Closes 932** once the live cross-version atomic update is observed end-to-end.

---

## TRACK D — Unified Memory design — closes (scopes) **965**
Brief: `docs/operator/v3.7.7-memory-design-questions.md`. Needs your answers; unblocks scoping only.

1. **Answer the design-questions brief** — work the decision matrix (Q1–Q6). The fastest path: accept or override the bolded "Suggested default" on each.
2. **Answer Q6 first** — it is load-bearing: does v3.7.7 unify the Bridge SQLite store with the Claude Code `MEMORY.md` system, or keep them separate? This gates the scope of everything else.
3. Versioning stays PATCH-increment (3.7.6 → 3.7.7); public push operator-gated.
- **Once answered:** an implementing agent can spec Wave 2. **965 is design-gated, not Done** — answering the brief moves it from "blocked" to "scopable," not to "shipped."

---

## TRACK E — Harness-side feedback (recommend Decline + file upstream) — **FB-1 (943) / FB-4 (946)**
Not in this repo — these are harness-side, not Bridge code.

- **FB-1 (943)** and **FB-4 (946):** recommended disposition is **Decline in-repo** and **file upstream** as harness/tooling feedback. Neither maps to a change in `the-bridge`; closing them as in-repo work would be a false Done. File the upstream report against the harness/tooling owner and mark these Declined (out-of-repo) with a pointer to the upstream item.
- **No code action in this repo.** Listed here so the v3 close-out accounts for every open packet.

---

## Final close-out gate

"Ship The Bridge v3" is closed when:
- Track A: 917 → 920 → 810 → 922/921/923 → 801 all verified green (in order).
- Track B: 968 verified (TCC read+write round-trip).
- Track C: 932 verified (live atomic cross-version update).
- Track D: 965 answered + scoped (not necessarily shipped).
- Track E: 943/946 declined in-repo + filed upstream.

Each step's "Verify" line is the gate for moving its packet to Done. Until then, the packets stay where they are.
