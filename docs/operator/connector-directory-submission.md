# Connector Directory Submission — Handoff (PKT-800, v3.0.0)

**Status:** artifacts prepared by the executor; **operator performs the external submission** (requires your WorkOS/Cloudflare/domain accounts and a live public endpoint). Built + green against synthetic JWKS; not yet validated against live Claude/ChatGPT.

## 1. What Bridge exposes

| Item | Value |
|---|---|
| Transport | Streamable HTTP MCP, served at `POST /mcp` on the SSE NIO listener |
| Activation | env `BRIDGE_ENABLE_HTTP=1` (unset ⇒ stdio-only, byte-for-byte unchanged) |
| Protected Resource Metadata | `GET /.well-known/oauth-protected-resource` (RFC 9728) |
| Auth | OAuth 2.1 Authorization Code + PKCE; **WorkOS AuthKit = Authorization Server** (Path B, Decision Log row 21); Bridge = Resource Server only |
| Client identity | CIMD preferred (Nov-2025 MCP spec) + DCR fallback — enable both in the WorkOS dashboard |
| Bearer | JWS validated via JWTKit against the AS JWKS; `iss`/`aud`/`exp`/`nbf` enforced; fail-closed |
| Scopes | `snippets.read`, `snippets.write`, `voice.resolve`, `runners.exec`, `contacts.read`, plus `connector.step_up` (AS-minted; **the sole authorization factor** for `destructiveHint` tools — see §5) |
| Scope→tool map | `snippets.read`→read-only snippet tools; `snippets.write`→mutating snippet tools (⊇ read); `runners.exec`→command/process/job/dev-runner tools; `contacts.read`→contact-RECORD tools (`contacts_get`, `contacts_search`); `voice.resolve`→voice-resolution tools ONLY (`contacts_resolve_handle`, `contacts_health`). `contacts.read` and `voice.resolve` are independent (neither implies the other). Non-listed tools are denied (allowlist, not blocklist). |
| Failure semantics | `401` + `WWW-Authenticate: Bearer` (missing/invalid bearer); `403` (scope-deny / step-up-required / confused-deputy) |

## 2. Operator prerequisites (must be provisioned before submission)

1. **WorkOS tenant** — create an AuthKit project; enable CIMD + DCR; note the issuer URL and JWKS URL.
2. **Public domain** — `bridge.kup.solutions` (or chosen host) with TLS.
3. **Cloudflare Tunnel** — terminate TLS, route the host to the local Bridge SSE port.
4. **Bridge env on the host:**
   - `BRIDGE_ENABLE_HTTP=1`
   - `BRIDGE_OAUTH_ISSUER=<WorkOS AuthKit issuer URL>` (default placeholder is `https://auth.example.invalid` — MUST be overridden in production)
   - `BRIDGE_OAUTH_JWKS=<WorkOS JWKS: inline JSON or local file path>` (no network fetch is performed; provision the JWKS material)
   - `NOTION_BRIDGE_PORT=<port behind the tunnel>` (the PRM `resource` is derived from this)

## 3. Sample PRM (shape served; values reflect env at runtime)

```json
{
  "resource": "https://bridge.kup.solutions/mcp",
  "authorization_servers": ["https://<your-workos-issuer>"],
  "scopes_supported": ["snippets.read","snippets.write","voice.resolve","runners.exec","contacts.read"],
  "bearer_methods_supported": ["header"]
}
```

Verify after provisioning: `curl https://bridge.kup.solutions/.well-known/oauth-protected-resource` returns the above with your real issuer and a `200 application/json`.

## 4. Submission steps (operator-performed)

**Anthropic connector directory** — submit: connector name, the remote MCP URL (`https://bridge.kup.solutions/mcp`), the PRM URL, OAuth flow = Authorization Code + PKCE with the WorkOS AS, the scope list above, and a short description. Anthropic's review will exercise discovery via the PRM + the OAuth flow.

**ChatGPT Developer Mode** — register the same remote MCP endpoint; ChatGPT self-registers as a client via DCR/CIMD against the WorkOS AS.

## 5. Step-up threat model (honest) + remaining limitations

**Step-up authorization (S4-corrected — PKT-800).** A `destructiveHint:true`
connector `tools/call` is authorized **only** by the AS-minted
`connector.step_up` scope present on the **verified** access token. That
scope is the **sole security boundary**: the authorization server is
responsible for eliciting the human elevation before minting it. The
per-call `_stepUp`/`stepUpToken` argument is a **non-authoritative consent
echo** — it is recorded for the consent trail/UX only and **cannot, by
itself, authorize a destructive call**. (This corrects the prior S3
behaviour, which accepted "scope **OR** a non-empty token": because the
echo has no nonce, no binding, and no server-side verification, any
automated client could trivially forge `{"_stepUp":"x"}` and bypass
step-up. That was a defect; it is fixed — the token is now decoupled from
authorization entirely.) Absent the scope ⇒ `403` with stable reason
`step_up_required`, **no dispatch**.

Remaining limitations to disclose:

- **Principal isolation is subject-only** — `clientID` derives from the token `sub`; two OAuth clients sharing one `sub` are not distinguished (no `azp`/`client_id` claim decoded).
- **Step-up elevation is delegated to the AS** — Bridge enforces the presence of the `connector.step_up` scope but does not itself verify *how* the AS elicited the elevation (interactive vs. policy-granted). Operators MUST configure the WorkOS AuthKit policy so `connector.step_up` is only issued after an explicit per-elevation human consent.
- Live validation against real Claude/ChatGPT clients is **pending operator infra** — everything above is green against synthetic JWKS only.

*Resolved in S4 (PKT-800): the `voice.resolve` over-scoping of contact-record tools (split into a dedicated `contacts.read`); the `runStreamableHTTP()` active-path gated no-op now has in-harness coverage via a `TransportRouter` injection seam on `ServerManager`.*
