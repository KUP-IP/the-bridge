# Bridge Cloud Access — Deploy Runbook

Deploys the kup-worker control plane (/Users/keepup/Developer/kup-worker) and wires the Bridge (Mac) host to it. Code-complete, 28 passing tests. READ-ONLY prep: nothing below was executed except a validation dry-run.

Unblocks: WS-A 917, WS-B 920, live E2E for WS-F / WS-D / WS-G + 810.

Account: wrangler is authenticated as isaiah@kup.solutions, account 99ca43ae6713b1fc6be0c77047bc06d7 (verified via `wrangler whoami`).

## Exact names (single source of truth)

### Worker (kup-worker) — from src/index.ts Env interface
- CAPABILITY_SIGNING_SECRET — SECRET, set via `wrangler secret put`. HMAC key for NL-3 capability signing. The ONLY real secret. Falls back to `dev-insecure-secret` if unset — MUST be set in prod.
- MCP_BASE_URL — var, wrangler.toml [vars]. Already set to https://mcp.kup.solutions. Base for tenant remote-MCP URLs.
- WORKOS_JWKS_URL — var or secret, per-env. WorkOS JWKS endpoint, consumed by WorkOsIdentityProvider.
- WORKOS_AUDIENCE — var or secret, per-env. Expected aud for owner session JWTs.
- OFFLINE_THRESHOLD_MS — optional var. Defaults to 30000 in code (liveness.ts) when unset.
- KV binding TENANTS — KV namespace, wrangler.toml [[kv_namespaces]]. Tenant/last-seen Store for prod. Commented sketch already in wrangler.toml and src/store.ts (KVNamespaceLike).

### Bridge (Mac) host — exact env-var names from the-bridge Swift
- BRIDGE_ENABLE_HTTP (TransportRouter.swift / BridgeFeatureFlags.swift / ServerManager.swift) = `1`. Flag flips ON only on exact string "1"; true/0/unset = off, fail-closed.
- BRIDGE_OAUTH_ISSUER (AuthorizationServer.swift, ProtectedResourceMetadataProvider.issuerEnvKey) = WorkOS issuer URL. Unset => placeholder https://auth.example.invalid.
- BRIDGE_OAUTH_JWKS (ConnectorBearerValidator.swift, jwksEnvKey) = inline JWKS JSON OR a local file path. Never fetched over network. Absent => key-less validator that rejects every bearer (fail-closed).
- NOTION_BRIDGE_PORT (ConfigManager.swift / ServerManager.swift / AppDelegate.swift / AuthorizationServer.swift) = SSE/`/mcp` listen port. Default 9700. This is the connector port env var (NOT BRIDGE_PORT; the SSE transport uses NOTION_BRIDGE_PORT). Advertised PRM resource = http://127.0.0.1:<port>/mcp, which is also the bearer-validator expected audience.
- BRIDGE_CLOUD_BASE_URL (EnableCloudAccessFlow+Live.swift) = WS-A Worker provision endpoint. Default placeholder https://cloud.kup.solutions. Set to https://bridge.kup.solutions.
- WORKOS_CLIENT_ID (CloudAuth.swift, WorkOSConfig.resolved) = public OAuth client id. Placeholder client_PLACEHOLDER_pkt810 blocks the Enable flow until set. NO secret.
- WORKOS_BASE_URL (CloudAuth.swift) = WorkOS auth base. Default https://api.workos.com.
- WORKOS_REDIRECT_URI (CloudAuth.swift) = default bridge-auth://callback. Keep this; it is the registered custom scheme.

## (a) Create Cloudflare KV namespace + bind in wrangler.toml

Prod Store needs a KV namespace (in-memory store is dev/test only). Binding name MUST be TENANTS.

```bash
cd /Users/keepup/Developer/kup-worker
wrangler kv namespace create TENANTS            # prints a production id
wrangler kv namespace create TENANTS --preview  # prints a preview_id
```

Paste printed ids into wrangler.toml (uncomment the sketch at the bottom):

```toml
[[kv_namespaces]]
binding = "TENANTS"
id = "<production id>"
preview_id = "<preview id>"
```

Note: a KV-backed Store implementing the src/store.ts interface must exist for the binding to be used (repo ships InMemoryStore + a KVNamespaceLike sketch). Deploy succeeds either way; KV is the durability layer.

## (b) Put the secret(s)

Exactly one real secret, named exactly:

```bash
cd /Users/keepup/Developer/kup-worker
wrangler secret put CAPABILITY_SIGNING_SECRET   # paste a long random value
```

Generate a value: `openssl rand -base64 48`. Optionally store WorkOS values as secrets instead of plaintext vars:

```bash
wrangler secret put WORKOS_JWKS_URL
wrangler secret put WORKOS_AUDIENCE
```

## (c) Deploy

```bash
cd /Users/keepup/Developer/kup-worker
npm test            # 28 tests — confirm green before shipping
wrangler deploy
```

Validate first without shipping: `wrangler deploy --dry-run` (already verified — 36.93 KiB upload, clean).

## (d) bridge.kup.solutions domain / route

After deploy, bind the hostname via dashboard (Workers & Pages -> kup-worker -> Settings -> Domains & Routes) or via toml:

```toml
routes = [
  { pattern = "bridge.kup.solutions", custom_domain = true }
]
```

The zone kup.solutions must be on this Cloudflare account. bridge.kup.solutions is referenced by the Mac in BridgeCloudManager.swift / KeychainManager.swift as the tunnel host. Set the Mac BRIDGE_CLOUD_BASE_URL to match.

Distinct hosts: mcp.kup.solutions (MCP_BASE_URL, per-tenant remote-MCP URL template) vs bridge.kup.solutions (control-plane route / tunnel host) vs cloud.kup.solutions (default BRIDGE_CLOUD_BASE_URL placeholder). Point BRIDGE_CLOUD_BASE_URL at wherever you bind the Worker (bridge.kup.solutions).

## (e) WorkOS tenant

In the WorkOS dashboard (operator-only — account creation out of scope):
1. Create/select the application; copy the client_id (public) -> Mac env WORKOS_CLIENT_ID.
2. Add redirect URI exactly bridge-auth://callback (custom scheme the app registers; matches WorkOSConfig.placeholder.redirectURI and CloudAuth.swift). Keep Mac WORKOS_REDIRECT_URI=bridge-auth://callback.
3. Copy the issuer and JWKS URL -> Worker WORKOS_JWKS_URL + Mac BRIDGE_OAUTH_ISSUER; mirror the JWKS into Mac BRIDGE_OAUTH_JWKS (inline JSON or local file path).
4. Set Worker WORKOS_AUDIENCE to the expected session aud. The Mac connector expected audience is the resolved PRM resource http://127.0.0.1:<NOTION_BRIDGE_PORT>/mcp (default port 9700).

The placeholder client id client_PLACEHOLDER_pkt810 deliberately disables the Enable flow until a real id is set.

## (f) Bridge host env vars (Mac)

Set where the Bridge app reads its environment (launchd plist EnvironmentVariables, or the launch context). EXACT names:

```sh
BRIDGE_ENABLE_HTTP=1                              # exact "1" — anything else stays off
BRIDGE_OAUTH_ISSUER=https://<your-workos-issuer>
BRIDGE_OAUTH_JWKS=<inline JWKS JSON OR /abs/path/to/jwks.json>
NOTION_BRIDGE_PORT=9700                           # default; the SSE/mcp port
BRIDGE_CLOUD_BASE_URL=https://bridge.kup.solutions
WORKOS_CLIENT_ID=client_<real from WorkOS>
WORKOS_BASE_URL=https://api.workos.com
WORKOS_REDIRECT_URI=bridge-auth://callback
```

With BRIDGE_ENABLE_HTTP=1 and BRIDGE_OAUTH_JWKS configured, the connector /mcp endpoint validates bearers (fail-closed if JWKS absent). Without them, the app runs stdio+SSE exactly as today.

## Order of operations
1. wrangler kv namespace create TENANTS (+ --preview) -> paste ids into wrangler.toml (step a)
2. wrangler secret put CAPABILITY_SIGNING_SECRET (step b)
3. Set WORKOS_JWKS_URL + WORKOS_AUDIENCE (toml vars or secrets) (step e prerequisite)
4. npm test then wrangler deploy (step c)
5. Bind bridge.kup.solutions route -> re-deploy (step d)
6. WorkOS tenant: client_id + redirect_uri + issuer/JWKS (step e)
7. Set the 8 Bridge (Mac) env vars; restart the Bridge app to re-handshake (step f)
8. Live E2E: Enable Cloud Access flow -> /provision -> /heartbeat -> /t/:id/tools online/offline.

Steps 1-4 are automated by deploy.sh (KV create, secret put, deploy). Steps 5-7 are operator dashboard / launchd actions.

## Known blocker for live E2E
WorkOsIdentityProvider.verify (src/identity.ts) is an intentional stub that THROWS ("requires a live WorkOS binding"). After deploy, all authenticated endpoints (/provision, /heartbeat, /t/:id/*) return 401 until a live WorkOS verify impl is wired; only /healthz works. This is the last code gap between "deployed" and "live E2E".
