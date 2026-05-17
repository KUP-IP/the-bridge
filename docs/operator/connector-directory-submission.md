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
| Scopes | `snippets.read`, `snippets.write`, `voice.resolve`, `runners.exec`, plus `connector.step_up` (AS-minted; required for `destructiveHint` tools) |
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
  "scopes_supported": ["snippets.read","snippets.write","voice.resolve","runners.exec"],
  "bearer_methods_supported": ["header"]
}
```

Verify after provisioning: `curl https://bridge.kup.solutions/.well-known/oauth-protected-resource` returns the above with your real issuer and a `200 application/json`.

## 4. Submission steps (operator-performed)

**Anthropic connector directory** — submit: connector name, the remote MCP URL (`https://bridge.kup.solutions/mcp`), the PRM URL, OAuth flow = Authorization Code + PKCE with the WorkOS AS, the scope list above, and a short description. Anthropic's review will exercise discovery via the PRM + the OAuth flow.

**ChatGPT Developer Mode** — register the same remote MCP endpoint; ChatGPT self-registers as a client via DCR/CIMD against the WorkOS AS.

## 5. Known limitations to disclose / fix before public load

- **Step-up per-call token is a consent signal, not anti-automation** — the strong factor is the AS-minted `connector.step_up` scope; the per-call `_stepUp` arg is satisfied by any non-empty value (documented in code).
- **Principal isolation is subject-only** — `clientID` derives from the token `sub`; two OAuth clients sharing one `sub` are not distinguished (no `azp`/`client_id` claim decoded).
- **`voice.resolve` over-scopes `contacts_get`/`contacts_search`** — consider a dedicated `contacts.read` scope before public listing (carry-forward).
- **`runStreamableHTTP()` is a gated non-binding guard** — `/mcp` is served by the shared SSE listener; the active-path no-op is enforced structurally (no in-harness coverage; carry-forward to add a `TransportRouter` injection seam).
- Live validation against real Claude/ChatGPT clients is **pending operator infra** — everything above is green against synthetic JWKS only.
