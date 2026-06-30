# PKT-CURSOR-001 — Cloud Agent Bridge MCP OAuth shows Connected but tools stay `needsAuth`

**Date opened:** 2026-06-30  
**Status:** Open — reproduction confirmed  
**Severity:** High (blocks cloud-agent workflows that depend on Bridge MCP)  
**Owner:** Triage — likely **Cursor platform** (MCP OAuth → cloud-agent VM propagation); Bridge connector endpoint verified healthy  
**Reporter:** Isaiah Peters (operator session via Cursor Cloud Agent on mobile web)

---

## Summary

Operator completed WorkOS OAuth for **Bridge MCP** (`https://mcp.kup.solutions/mcp`) in the **Cursor web app on mobile**. UI reports **Connected**. A running **Cursor Cloud Agent** in the same account still sees Bridge MCP as **`needsAuth`** with **0 tools** — direct `mcp_call_tool` invocations are blocked.

This breaks the expected “authenticate once, use Bridge from any Cursor environment” story.

---

## Environment

| Field | Value |
|---|---|
| Bridge MCP URL | `https://mcp.kup.solutions/mcp` |
| OAuth AS | `https://agile-expression-49.authkit.app` (WorkOS AuthKit) |
| Auth surface | Cursor **web app on mobile** (not desktop) |
| Agent type | Cursor **Cloud Agent** (isolated VM) |
| Bridge app version | Unknown at report time (connector infra live) |
| Desktop Cursor auth | **Not attempted** |

---

## Steps to reproduce

1. Ensure The Bridge is running on the operator Mac and the Cloudflare tunnel fronts `mcp.kup.solutions` → loopback `:9700`.
2. Open **cursor.com/agents** on **mobile**.
3. Configure **Bridge MCP** with URL `https://mcp.kup.solutions/mcp`.
4. Complete **WorkOS OAuth** login; UI shows **Connected**.
5. Start or continue a **Cloud Agent** session that should have Bridge MCP tools.
6. Agent calls `mcp_get_tools` for server `Bridge MCP`.

---

## Expected

- Bridge MCP `serverStatus: ready`
- `tools/list` returns the static Bridge surface (~195+ tools)
- Agent can invoke low-risk probes (`echo`, `system_info`, `session_info`)

---

## Actual

- Bridge MCP `serverStatus: needsAuth`
- Tool catalog empty for Bridge MCP
- `mcp_call_tool` → blocked (“requires authentication” / “MCP server does not exist”)
- Unauthenticated probe from cloud VM (control): `POST https://mcp.kup.solutions/mcp` → **401** `missing bearer token` (expected without token; confirms endpoint is up, not that OAuth reached the agent)

---

## Evidence (2026-06-30 cloud-agent session)

### OAuth protected-resource metadata (healthy)

```json
GET https://mcp.kup.solutions/.well-known/oauth-protected-resource
{
  "resource": "https://mcp.kup.solutions/mcp",
  "authorization_servers": ["https://agile-expression-49.authkit.app"],
  "scopes_supported": ["openid", "email", "profile", "offline_access"]
}
```

### Unauthenticated initialize (expected 401)

```
POST https://mcp.kup.solutions/mcp
→ 401 Unauthorized: missing bearer token
WWW-Authenticate: Bearer ... resource_metadata="https://mcp.kup.solutions/.well-known/oauth-protected-resource"
```

### Agent-side MCP catalog (after operator reported Connected)

```
Bridge MCP: serverStatus=needsAuth, tools=[]
```

Other team MCP servers (Cloudflare-bindings, Cloudflare-docs) show `ready` in the same session — isolation points to Bridge OAuth binding, not a global MCP outage.

---

## Hypotheses (ranked)

1. **Cursor web/mobile OAuth tokens are not propagated to Cloud Agent VMs** — UI “Connected” reflects browser/session storage that the agent runtime never receives. *Most likely.*
2. **Cloud-agent MCP config is a separate surface** from mobile-web MCP config — operator authenticated the wrong scope (web UI vs cloud-agent secrets/MCP dropdown).
3. **Agent session started before OAuth completed** and requires hard restart — operator may have restarted conversation but not the agent worker; worth re-testing after explicit agent restart from cursor.com/agents.
4. **Bridge-side** — less likely: connector rejects Cursor-issued tokens. Would expect UI to show error, not Connected. Still verify Mac tunnel + `logs/server/` for denied JWTs if hypothesis 1–3 ruled out.

---

## Impact

- Cloud agents cannot use Bridge tools (Notion via Mac token path, `registry_*`, `notify`, local file ops, etc.) despite operator completing OAuth.
- Undermines PKT-810 connector value prop: “add Bridge in claude.ai / remote Cursor and operate the Mac.”
- Forces operators back to **local-only** Cursor on the Mac for Bridge work — defeats mobile + cloud-agent workflows.

---

## Triage checklist

### Operator (Isaiah)

- [ ] Confirm Bridge MCP shows **Connected** on **cursor.com/agents → MCP** (not only mobile PWA shell).
- [ ] **Stop and restart** the cloud agent (new worker) after auth.
- [ ] Retry auth on **desktop Cursor** → Cloud agent — does token propagate there?
- [ ] On Mac: `curl -s http://127.0.0.1:9700/health` + check `~/Library/Logs/The Bridge/server/` for OAuth/JWT errors during agent attempts.

### Cursor (platform)

- [ ] Confirm mobile-web MCP OAuth tokens are injected into cloud-agent VM MCP client.
- [ ] Document whether cloud agents require MCP auth via dashboard secrets vs in-session OAuth.
- [ ] Expose actionable error when UI “Connected” ≠ agent `needsAuth`.

### Bridge (if Cursor rules out platform gap)

- [ ] Verify `ConnectorBearerValidator` accepts tokens minted for resource `https://mcp.kup.solutions/mcp`.
- [ ] Confirm tunnel + WorkOS env (`BRIDGE_OAUTH_ISSUER`, `BRIDGE_PUBLIC_RESOURCE`) on operator Mac.

---

## Related docs

- `README.md` — Cloud connector section
- `docs/operator/cloudflare-access-notion-bridge.md`
- `docs/operator/connector-provisioning-runbook.md`
- `packet-runner/config/PROVIDER_CAPABILITY_MATRIX.md` — capability 4 “Bridge reachability in cloud” was **plausible-needs-integration-test**; this packet is that test failing.

---

## Tracking

- GitHub issue: *(file in repo; open issue from PR or manually)*
- AGENT_FEEDBACK.md: 2026-06-30 entry
