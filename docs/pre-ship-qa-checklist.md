# Pre-ship QA checklist

Use before merging to `main` or tagging a release. Automated: `make test`, `make build` or `make app`. This list covers **manual** verification.

## Last recorded ladder (CI / agent)

| Date | Result |
|------|--------|
| 2026-04-04 | `make test` pass; `make app` pass (actool warnings non-fatal); `make install-copy` pass; `python3 scripts/qa_local_mcp_smoke.py` pass with app running (`protocolVersion` **2025-06-18** in initialize result). |

## Build ladder (record result)

| Step | Command | Pass |
|------|---------|------|
| Tests | `make test` | |
| Release binary | `make build` | |
| App bundle | `make app` | |
| Install | `make install` (signed + notary) **or** `make install-copy` / `make install-agent-safe` | |

**Notes:** `actool` warnings during `make app` are often environmental (see `AGENTS.md`). Production install: `make test` → `make app` → `make install` when credentials exist.

## Advanced → Version

- [ ] App version matches release intent (`Info.plist` / `AppVersion`).
- [ ] **MCP protocol** shows `2025-06-18` (spec handshake).
- [ ] **Notion API** shows `2026-03-11` (REST `Notion-Version`).
- [ ] **Minimum macOS** shows deployment string (e.g. 26+).

## Advanced → Network (local MCP port)

- [ ] Change port → **Save** → **Restart** path applies new listener after relaunch.
- [ ] **Cancel** on restart prompt reverts saved port in config to previous value.
- [ ] **Default** fills 9700 without saving until **Save**.

## Connections

- [ ] **Server → Local port** matches Advanced saved port after restart.
- [ ] Streamable HTTP / Legacy SSE / Health URLs show `localhost:<port>`.
- [ ] **Remote access** expanded: `cloudflared` / Tailscale hints use the same port as config.

## Onboarding (optional reset)

- [ ] Connection JSON snippets use **configured** port (not hardcoded 9700 if changed).
- [ ] **Test Connection** health URL uses configured port.

## Credentials

- [ ] With feature **off**: credential MCP tools absent or fail closed; UI shows opt-in.
- [ ] With feature **on**: biometric on enable; add flow works as before.

## Permissions

- [ ] **Reset All Permissions** and **Factory Reset**: no extra permissions sheet; inline caption after reset explains re-grant in **System Settings** and **restart** (status may be stale until quit/reopen).
- [ ] Main Permissions tab: refresh behavior acceptable (throttled timer + Re-check).

## MCP smoke (requires running app)

1. Start **The Bridge** (menu bar).
2. Run: `python3 scripts/qa_local_mcp_smoke.py`  
   Or connect **Cursor** (or another client) to `http://127.0.0.1:<port>/mcp` with Streamable HTTP.
3. [ ] `initialize` succeeds; [ ] tool list non-empty (typical config).

## Git / release

- [ ] `AppVersion` in [`Version.swift`](../TheBridge/Config/Version.swift) matches `Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`).
- [ ] `CHANGELOG.md` entry for the release is complete.
- [ ] No force-push to `main` ([`AGENTS.md`](../AGENTS.md)); push `main` / tag when review is done (workspace may show `ahead` of `origin` until push).
