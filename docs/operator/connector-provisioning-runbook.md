# Connector Provisioning Runbook — Group B turnkey (PKT-800, v3.0.0)

This is the **operator-only** sequence to take the green, shipped v3.0.0 connector from "code-complete on synthetic keys" to "live and directory-listed." The executor cannot perform these (your accounts, DNS, external review). Each step is one-shot; the final validation is scripted.

> Code state assumed: `main` at the v3.0.0 GA (PKT-800 S1–S4), notarized + installed. Nothing below requires code changes.

## B1 — Provision infra

**1. WorkOS AuthKit (Authorization Server, Path B — Decision Log row 21)**
- Create a WorkOS project; enable **AuthKit**.
- Enable **CIMD** (preferred, Nov-2025 MCP spec) **and** **DCR** (fallback) in the WorkOS dashboard.
- Configure the `connector.step_up` scope so it is **only minted after an explicit per-elevation human consent** (this is the sole step-up security boundary — Bridge enforces presence, the AS owns elicitation; see the submission doc §5).
- Record the **issuer URL** and **JWKS URL**.

**2. Public domain + TLS**
- Point `bridge.kup.solutions` (or your chosen host) at the machine.

**3. Cloudflare Tunnel**
- Create a tunnel terminating TLS and routing `https://bridge.kup.solutions` → `127.0.0.1:<NOTION_BRIDGE_PORT>`.

**4. Bridge host env** (the running app process / launch environment)
- `BRIDGE_ENABLE_HTTP=1`
- `BRIDGE_OAUTH_ISSUER=<WorkOS issuer URL>`  (must override the `https://auth.example.invalid` placeholder)
- `BRIDGE_OAUTH_JWKS=<WorkOS JWKS: inline JSON or local file path>`  (no network fetch is performed — provision the material)
- `NOTION_BRIDGE_PORT=<port behind the tunnel>`  (the PRM `resource` is derived from this)
- Restart the app so the env takes effect.

## B2 — Validate (one-shot, scripted)

```sh
BASE_URL=https://bridge.kup.solutions \
EXPECT_ISSUER=https://<your-workos-issuer> \
scripts/validate-connector.sh
```

Add `BEARER=<a test access token>` and `STEPUP_TOOL=<a destructiveHint tool>` to also exercise scope/step-up enforcement. The script checks: PRM RFC 9728 shape + your real issuer + the 5 scopes + snake_case; unauthenticated `/mcp` → `401` + `WWW-Authenticate: Bearer`; `/health` non-regression; forged `_stepUp` on a destructive tool → `403`. Exits non-zero on the first failure — gate the submission on a clean run.

## B3 — Submit to the directories

Once B2 is clean, follow `docs/operator/connector-directory-submission.md` (§4) to submit to the **Anthropic connector directory** and **ChatGPT Developer Mode**. Both self-register clients via DCR/CIMD against the WorkOS AS.

## Status / honest scope

- Code: **done, green (924/0/924), reviewed, notarized, installed, pushed.**
- B1–B3: **operator-gated** — cannot be completed autonomously (accounts, DNS, external review). This runbook + `validate-connector.sh` make them one-shot.
- Out of scope by prior operator decision: STT `ca31fb27` and the snippet-expander (off the GA critical path; not reactivated).
