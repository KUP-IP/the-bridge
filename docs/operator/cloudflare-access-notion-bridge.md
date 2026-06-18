# Cloudflare Zero Trust Access in front of TheBridge (tunnel)

This runbook is for **operators** who expose TheBridge’s Streamable HTTP endpoint through an HTTPS tunnel (for example Cloudflare Tunnel to `127.0.0.1`). It contains **no secrets** — generate tokens and policies only in the Cloudflare dashboard or your identity provider.

## Why use Access

TheBridge listens on **loopback** only; a tunnel publishes a public hostname. **Cloudflare Access** adds an identity layer at the edge so arbitrary internet clients cannot reach your tunnel origin without meeting your policy.

Use Access **together with** the app’s **mandatory MCP bearer** when a tunnel URL is configured (see [SECURITY.md](../../SECURITY.md) and the in-app **Remote access** settings).

## Important: browser-based MCP clients

Some MCP hosts run inside a browser context or use browser-like traffic fingerprints. Those clients can be blocked by **Cloudflare Browser Integrity Check**, WAF challenges, or other browser-signature heuristics before the request ever reaches TheBridge. If you see **Cloudflare 1010** or similar edge denials on `POST /mcp`, the fix is at the edge, not in the local app.

For browser-based clients such as Claude chat:

- Do **not** put browser challenges in front of `POST /mcp`.
- If Cloudflare Access service tokens are unavailable in that client, use a **narrow bypass rule scoped to the MCP path and method** instead of disabling protection for the entire hostname.
- Keep protection on the rest of the host, and rely on the app’s **Authorization: Bearer** requirement for the MCP endpoint.

## Prerequisites

- A Cloudflare account and a **hostname** routed through Cloudflare (tunnel or proxied DNS).
- TheBridge **tunnel URL** set to that HTTPS base URL, and an **MCP remote token** generated in the app.

## 1. Create an Access application

1. In the Cloudflare dashboard, open **Zero Trust** → **Access** → **Applications**.
2. **Add an application** → **Self-hosted** (or the template that matches your hostname).
3. Set the **application domain** to the same host you use in TheBridge’s tunnel URL (for example `bridge.example.com` or a `*.trycloudflare.com` hostname if applicable to your setup).
4. Configure a **default deny** posture: only identities or **non-identity** rules you add should grant access.

Official reference: [Cloudflare Access documentation](https://developers.cloudflare.com/cloudflare-one/policies/access/).

## 2. Choose how Cursor (or the MCP client) authenticates

Access supports several patterns. Pick one that matches your client:

- **Service token (recommended for automation)** — Cloudflare issues a **client ID** and **client secret** used as HTTP headers on each request. Suitable when the MCP client lets you set **custom headers** for the remote URL.
- **Identity / SSO** — Users sign in through your IdP; the browser or client must complete the Access login flow. Viability depends on whether your MCP runtime supports interactive auth or stored cookies.

Document your choice in your internal wiki; rotate service tokens on the same schedule as other machine credentials.

## 3. Headers for service tokens

When using a **service token**, Cloudflare expects (names may vary slightly by dashboard version):

- `CF-Access-Client-Id: <client id>`
- `CF-Access-Client-Secret: <client secret>`

Create the service token under **Zero Trust** → **Access** → **Service auth** (or **Service tokens**). See [Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/).

## 4. Cursor MCP headers

In Cursor, configure the **remote MCP** URL to your tunnel’s **`POST /mcp`** endpoint (as documented in the product README). Add headers:

1. **Cloudflare Access** — `CF-Access-Client-Id` and `CF-Access-Client-Secret` if you use a service token (see above).
2. **TheBridge** — `Authorization: Bearer <token>` using the **MCP remote token** from TheBridge **Settings → Connections → Remote access**.

If a client cannot send custom headers, you cannot combine that client with both Access service-token auth and TheBridge bearer in the intended way; use a client that supports headers or adjust edge policy with your security team. For browser-based clients, the usual adjustment is a **path-scoped bypass for `POST /mcp`** while keeping the app bearer token enabled.

## 5. Verification

- With tunnel URL set and **no** MCP token in the app, **`initialize`** over Streamable HTTP should **fail** (HTTP **401** from TheBridge).
- After setting the token in the app and matching **`Authorization`** in the client (plus Access headers if used), **`initialize`** should **succeed**.
- If `GET /health` succeeds but `POST /mcp` fails with **Cloudflare 1010**, **browser_signature_banned**, or another edge denial, inspect Cloudflare Security Events and remove browser challenges from the MCP path.

## 6. Health endpoint

`GET /health` is informational and is **not** gated by this app release. If you need it private, protect it with Access path rules or a separate hostname.

## Related links

- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [Access policies](https://developers.cloudflare.com/cloudflare-one/policies/access/)
- TheBridge [SECURITY.md](../../SECURITY.md)
