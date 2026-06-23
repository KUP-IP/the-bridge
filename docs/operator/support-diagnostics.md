# Support Diagnostics — What to Ask a Customer For

Operator runbook for triaging "The Bridge isn't working." Goal: get the customer
to read three things off their own Mac so you can diagnose without screen-sharing.

Grounded against the live code as of v3.8.2. Everything here is **local-only** —
The Bridge processes data on the customer's Mac and phones home only for the
best-effort license check (see `license-ops-runbook.md`).

---

## 1. Read the license status (Settings → License)

Ask the customer to open **Settings → License** (the License card; in current
builds it sits under the **Security** page, historically under **Advanced**) and
read the **status pill** verbatim. The pill maps 1:1 to the gate state in
`LicenseManager` / `LicenseStatus`:

| Pill text | State | What it means |
|---|---|---|
| `Trial — N days left` | `.trial` | No license yet; 30-day trial running. Tools dispatch normally. |
| `Trial expired` | `.trialExpired` | Trial elapsed, no key. **Tools refuse to dispatch** until a key is activated. Local data untouched. |
| `Licensed` | `.licensed` | Valid paid key. Card shows "Licensed to" + "Expires" (Never for perpetual). |
| `License expired` | `.licenseExpired` | Paid key whose `exp` passed. Tools refuse to dispatch; offer a renewed key. |
| `Licensed (3.x)` | `.grandfathered` | Upgraded from a pre-gate version. No countdown ever; sticky across relaunches. |

Notes for triage:
- A trial-expired or license-expired Mac is **not broken** — the dispatch gate is
  doing its job. Every `tools/call` throws `BridgeToolError.trialExpired` with a
  `kind` of `trial-expired` or `license-expired`. The fix is activation, not reinstall.
- If the card shows **"Paste-activation is unavailable in this build (no bundled
  public key)"**, the customer has a build whose `LicensePublicKey.bundledBase64URL`
  is empty — paste activation can't verify any key. That's a **build/release
  problem on our side**, not a bad key. See `license-ops-runbook.md` and
  `DELIVERY-GAPS.md` (the `LICENSE_PUBLIC_KEY_BASE64URL` CI secret).

---

## 2. Where state + logs live

All under `~/Library/Application Support/The Bridge/` and `~/Library/Logs/The Bridge/`
(canonical home is `BridgePaths.appName = "The Bridge"`):

| Path | What |
|---|---|
| `~/Library/Application Support/The Bridge/license.json` | License state: `firstLaunchAt`, optional `token`, `grandfathered` flag, `trialExpiredAcknowledged`. Atomic-written, JSON, human-readable. |
| `~/Library/Logs/The Bridge/server/` | MCP/HTTP server logs (connection + access). |
| `~/Library/Logs/The Bridge/audit/` | Tool-call audit log. |
| `~/Library/Logs/The Bridge/jobs/` | Durable-job (JobStore) logs. |

Ask the customer to send `license.json` and the most recent file under
`logs/server/` first — those two cover the large majority of "won't connect" and
"says expired" reports.

To read `license.json` quickly (customer-side):

```sh
cat ~/Library/"Application Support"/"The Bridge"/license.json
```

The `token.payload` block (if present) carries the license `id` — that is the
key you map back to a Stripe order (see `license-ops-runbook.md`).

---

## 3. MCP tools that report state

If the customer has a working MCP client connected, these three read-only tools
are the fastest health probe (no confirmation prompts — all `.open` tier):

- **`system_info`** — host facts. Returns `osName`, `osVersion`, `osBuild`,
  `hostname`, `homeDirectory`, `userName`, `currentDirectory`, `cpu`, `cpuCores`,
  `memoryGB`, `uptime`, `hardwareModel`. Use this to confirm macOS version
  (requires macOS 26 / Apple Silicon per TERMS §4) and the real home path.
- **`session_info`** — this session's health. Returns `uptime` / `uptimeSeconds`,
  `connections`, `activeClients`, `toolCalls`, `auditLogSize`. Use this to confirm
  the server is actually serving the client and how busy it's been.
- **`bridge_status`** — **cloud** health only, and **only registered when Bridge
  Cloud Access is enabled**. Returns `{ tool, ok, state, up, macToolsAvailable,
  schemaVersion }` where `state` is `disabled|connecting|online|degraded|offline`.
  If a customer is purely local (the common case), this tool will not be present —
  that's expected, not a fault.

Note: none of these report license status directly — license state is read from
the **Settings → License pane** (§1) or `license.json` (§2).

---

## 4. Check the loopback server

The Bridge serves MCP on **`127.0.0.1:9700`**. `/health` requires no auth and is
the cleanest "is it alive" probe:

```sh
curl -s http://127.0.0.1:9700/health
```

- **JSON back** → the server is up and listening. Move on to the client config.
- **Connection refused** → the HTTP server isn't running. Most common causes:
  1. The app isn't running (it's a menu-bar app — check for the icon).
  2. HTTP isn't enabled. The GUI app gets `BRIDGE_ENABLE_HTTP` from the
     `solutions.kup.bridge-env` LaunchAgent; a launch that didn't inherit it runs
     stdio-only and won't bind `:9700`.
  3. Port `:9700` is taken by something else (bind fails gracefully — the app
     stays up but HTTP is down). `lsof -i :9700` on the customer's Mac confirms.

---

## 5. "Connector won't connect" triage

Post **PKT-810 R5**, a **direct-loopback** `/mcp` request is **token-free** — the
local Mac connects with no bearer/OAuth. So a local connection failure is almost
never an auth problem. Walk it in this order:

1. **Is the app running?** Menu-bar icon present? If not, launch "The Bridge".
2. **Is `:9700` answering?** Run the `curl /health` from §4.
3. **Is the client pointed at the right endpoint?** It must be
   `http://127.0.0.1:9700/mcp` (Streamable HTTP), **no token**. See
   `connector-setup-customer.md` for the exact client steps.
4. **Only if all the above pass** and it still fails, collect `logs/server/` and
   escalate.

Do **not** send the customer chasing tokens/OAuth for a local connection — the
tunnel/cloud path is the only auth-gated one, and that's a separate setup
(`cloud-deploy-runbook.md`).

---

## 6. Sparkle / update problems

For "Update failed" dialogs, crash-after-update, or "won't update," do **not**
debug ad hoc — follow the dedicated runbook:

→ **`docs/release/sparkle-troubleshooting.md`**

It covers the two distinct failure modes (missing/mismatched enclosure DMG, and
the staged-bundle corruption crash-loop) plus the customer-side manual recovery
(`make install-copy`, clearing Sparkle staging). With current builds a corrupt
post-update bundle degrades to an SF Symbol menu-bar icon instead of crash-looping,
so recovery is "reinstall at your convenience," not an emergency.
