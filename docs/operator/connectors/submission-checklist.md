# Connectors Directory — Submission Checklist (PKT-801)

Reconciled with `docs/operator/connector-directory-submission.md` (PKT-800) and `docs/operator/connector-provisioning-runbook.md`. Those docs own the infra/provisioning detail; this checklist is the directory-submission control surface for **Anthropic Connectors Directory** and **ChatGPT Developer Mode**, plus the items the directory forms require that those docs do not enumerate (legal URLs, listing metadata).

## 0. Pre-flight gates (must be green before submitting)
- [ ] Build is green with the tool-annotation audit passing (`runToolAnnotationAuditTests`) — guarantees 100% explicit MCP hint coverage. (Verified 2026-06-05: 0 tools missing annotations.)
- [ ] Privacy Policy published at a stable public URL: `_______________________`
- [ ] Terms of Service published at a stable public URL: `_______________________`
- [ ] Support/contact email reachable: isaiah@kup.solutions

## 1. Remote endpoint (operator-provisioned — see provisioning runbook §B1)
- [ ] Transport: Streamable HTTP MCP at `POST /mcp` (activate with `BRIDGE_ENABLE_HTTP=1`).
- [ ] Public remote MCP URL: `https://bridge.kup.solutions/mcp`
- [ ] Cloudflare Tunnel up; TLS terminating; routing host → `127.0.0.1:NOTION_BRIDGE_PORT` (outbound-only; no inbound ports).
- [ ] `/health` responds (non-regression).

## 2. Protected Resource Metadata (PRM, RFC 9728)
- [ ] `GET /.well-known/oauth-protected-resource` returns `200 application/json`.
- [ ] PRM URL: `https://bridge.kup.solutions/.well-known/oauth-protected-resource`
- [ ] Body carries: `resource` = the `/mcp` URL; `authorization_servers` = [your WorkOS issuer]; `scopes_supported` = the 5 scopes below; `bearer_methods_supported` = ["header"].
- [ ] Verify: `curl https://bridge.kup.solutions/.well-known/oauth-protected-resource` shows your REAL issuer (not the `https://auth.example.invalid` placeholder).

## 3. OAuth flow
- [ ] Flow: OAuth 2.1 Authorization Code + PKCE.
- [ ] Authorization Server: WorkOS AuthKit (Path B). Bridge = Resource Server only.
- [ ] Client registration: CIMD enabled (preferred) AND DCR enabled (fallback) in the WorkOS dashboard — Claude/ChatGPT self-register against the AS.
- [ ] Bearer validation: JWS verified against the AS JWKS; `iss`/`aud`/`exp`/`nbf` enforced; fail-closed.
- [ ] Failure semantics confirmed: missing/invalid bearer → `401` + `WWW-Authenticate: Bearer`; scope-deny / step-up-required / confused-deputy → `403`.

## 4. Scopes (advertise exactly these)
- [ ] `snippets.read` — read-only snippet tools
- [ ] `snippets.write` — mutating snippet tools (⊇ read)
- [ ] `runners.exec` — command/process/job/dev-runner tools
- [ ] `contacts.read` — contact-RECORD tools (`contacts_get`, `contacts_search`)
- [ ] `voice.resolve` — voice-resolution tools only (`contacts_resolve_handle`, `contacts_health`)
- [ ] `connector.step_up` — AS-minted; the **sole** authorization factor for `destructiveHint` tools. Configure the WorkOS policy so it is issued ONLY after explicit per-elevation human consent.
- [ ] Confirm non-listed tools are denied (allowlist posture).

## 5. Validation (one-shot, gate the submission on a clean exit)
- [ ] `BASE_URL=https://bridge.kup.solutions EXPECT_ISSUER=https://<workos-issuer> scripts/validate-connector.sh`
- [ ] With `BEARER=<token> STEPUP_TOOL=<a destructive tool>` to also exercise scope + forged-`_stepUp` → `403`.

## 6. Anthropic Connectors Directory submission
- [ ] Connector name: `The Bridge`
- [ ] Remote MCP URL: `https://bridge.kup.solutions/mcp`
- [ ] PRM URL (§2)
- [ ] Auth: Authorization Code + PKCE via WorkOS AS
- [ ] Scope list (§4)
- [ ] Short description (Notion content + Mac app-control + Keychain credentials, local-first with optional cloud relay)
- [ ] Privacy Policy URL (§0) + Terms of Service URL (§0)
- [ ] Icon/logo asset (if required by the form): `_______________________`
- [ ] Note for reviewers: the human-confirmation gate for destructive tools is enforced via the `connector.step_up` OAuth scope, NOT via an MCP tool annotation (`requiresConfirmation` is Bridge-internal and not projected to the wire). Reviewers exercising discovery via PRM + OAuth will see `readOnlyHint`/`destructiveHint`/`idempotentHint`/`openWorldHint` on every tool.

## 7. ChatGPT Developer Mode submission
- [ ] Register the same remote MCP endpoint `https://bridge.kup.solutions/mcp`.
- [ ] Confirm ChatGPT self-registers as a client via DCR/CIMD against the WorkOS AS.
- [ ] Re-confirm PRM discovery + OAuth flow complete from the ChatGPT side.
- [ ] Provide Privacy Policy + Terms URLs if the developer-mode flow requests them.

## 8. Post-submission
- [ ] Record the submission date and reviewer feedback.
- [ ] Keep `BRIDGE_OAUTH_ISSUER` / `BRIDGE_OAUTH_JWKS` provisioned and the tunnel healthy for the duration of review.
- [ ] On approval, capture the directory listing URL: `_______________________`
