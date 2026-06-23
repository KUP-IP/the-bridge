# The Bridge

**A native macOS menu-bar app that turns your Mac into an MCP server for Notion AI agents and local coding clients.**

The Bridge exposes your local Mac and connected services as Model Context Protocol (MCP) tools over **Streamable HTTP**, **legacy SSE**, and **stdio** — locally on `127.0.0.1` for clients like Claude Code, Cursor, and Notion agents, and **securely from the cloud** (claude.ai and ChatGPT custom connectors) through a customer-owned Cloudflare Tunnel with OAuth. Built in Swift 6.2 for macOS 26+ on Apple Silicon, it is designed to be always-on, auto-launched, and safe enough for daily operator use.

**~163 tools** across 26 module groups · **3 transports + cloud connector** (Claude web · ChatGPT) · **3-tier security model** with on-device approvals · **Liquid Glass UI**

**Latest release:** [v3.7.11](https://github.com/KUP-IP/the-bridge/releases/tag/v3.7.11) (June 2026) — a tool-surface resurface that prunes the catalog to a lean, positioning-aligned ~163 tools (Chrome, the dynamic Stripe proxy, and the heavy dev-loop layer removed); `tools_list` is compact by default. Existing installs auto-update via Sparkle.

**Product page:** https://kup.solutions/notion-bridge

> **Naming history:** "TheBridge" was the product's original name; the user-facing brand is **The Bridge**. The Swift target and bundle identifier (`kup.solutions.notion-bridge`) are intentionally preserved for data continuity. The Keychain service was renamed `com.notionbridge` → `kup.solutions.the-bridge` (v3.7.8), and all prior services are still read so existing secrets migrate with zero loss.

---

## What this repo is

This is the product repository for **The Bridge** (Swift target name `TheBridge`).

It is not a generic Swift experiment and it is not an open-source demo server. It is the source-available codebase for a commercial macOS product that bridges Notion agents, local coding tools, and the user's Mac.

Current commercial posture:
- Direct purchase is the primary distribution path.
- No free tier is planned.
- Setapp distribution may follow later.

---

## Current product surface

The Bridge currently ships **~163 tools organized into 26 module groups**, surfaced collapsibly in **Settings → Tools**. Highlights below; the full registry is in-app.

| Module | Tools | Notes |
|---|---:|---|
| ShellModule | 2 | shell execution and approved scripts |
| FileModule | 12 | files, directories, metadata, clipboard |
| MessagesModule | 6 | iMessage and SMS read/send tooling |
| SystemModule | 3 | system info, processes, notifications |
| ContactsModule | 4 | CNContactStore search, get, resolve — no Contacts.app required |
| NotionModule | 21 | Notion pages, blocks, databases, data sources, comments, files, queries |
| SessionModule | 3 | session status and tool registry introspection |
| AppleScriptModule | 1 | in-process AppleScript execution |
| AccessibilityModule | 5 | AX tree, inspection, and actions |
| ScreenModule | 5 | capture, OCR, recording, screen analysis |
| ChromeModule | 5 | tabs, navigation, page reads, JS, screenshots |
| CredentialModule | 4 | Keychain-backed credential storage |
| PaymentModule | 1 | Stripe payment execution |
| SkillsModule | 3 | `fetch_skill`, `list_routing_skills`, `manage_skill` |
| ConnectionsModule | 5 | connection inventory, health, validation |
| BuiltinModule | 1 | `echo` (registered in `ServerManager`, not a Swift `*Module` type) |
| **Total** | **~163** | Across 26 module groups after the v3.7.11 resurface: the Apple suite (**Calendar**, **Reminders**, **Notes**, **Mail**, **Shortcuts**), **Memory**, on-device **Automation**, **CommandStore**, **StandingOrders**, **JobsManager**, **Notion**, **Git/Gh** quick-fix, **Snippets**, **Permissions**, and screen/clipboard/accessibility/AppleScript Mac steering. Removed: Chrome, the dynamic Stripe proxy + payment, and the dev-loop/IDE layer (LSP, bg_process, dev servers, test runners, Swift build tools). |

Core product traits:
- Native macOS menu-bar app with onboarding, settings, and a status popover
- **Liquid Glass UI** (v3.6+) — BridgeGlassCard, BridgeGlassBubble, dep-link chips, ModuleGroup cards, Standing Orders composer with per-client overlays
- **Command Bridge popup** — global hotkey (**⌃⌘B** default, "B for Bridge") opens a bottom-anchored SwiftUI tray with 10 favorite-slot bubbles + substring search + recents
- Auto-launch via `SMAppService`
- Streamable HTTP and legacy SSE on the same local server surface
- stdio support for local clients such as Claude Code and Cursor
- Local-first security gate with audit logging + **dispatch fail-closed** (disabled tool groups return typed `BridgeToolError.moduleGroupDisabled`, never silent failure)
- **Cloud connector** — reachable as a custom connector from **claude.ai** and **ChatGPT** over a customer-owned Cloudflare Tunnel, authorized with WorkOS OAuth and gated per-tool by the on-device security model (see **[Cloud connector](#cloud-connector)** below)
- Optional remote access through a customer-owned Cloudflare Tunnel (static-bearer path, for non-OAuth clients)

---

## Installation

### Option 1: Download a release

1. Download the latest DMG from [GitHub Releases](https://github.com/KUP-IP/the-bridge/releases).
2. Open the DMG.
3. Drag **The Bridge** (`TheBridge.app` in the DMG; renamed on install) into `/Applications`.
4. Launch the app and complete onboarding.

### Option 2: Build from source

```bash
git clone https://github.com/KUP-IP/the-bridge.git
cd Notion-bridge
make app
```

The app bundle is written to `.build/TheBridge.app`.

> **Install naming:** The Swift target is `TheBridge` (no space), so build output and DMG contents use `TheBridge.app`. The Finder display name is **The Bridge** (with space), set by `CFBundleName` / `CFBundleDisplayName` in `Info.plist`. `make install` places the app at `/Applications/The Bridge.app` to match the display name. Both names refer to the same product.

---

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| macOS | 26.0+ | Tahoe or later |
| Hardware | Apple Silicon | ARM64 only |
| Xcode | 26.0+ | Needed for building from source |
| Swift | 6.2+ | Defined by `Package.swift` |
| Git | 2.39+ | For cloning and release workflows |

---

## Configuration

Primary configuration path:

```text
~/.config/notion-bridge/config.json
```

The Bridge supports:
- Notion workspace connections
- connection health checks
- customer-owned remote-access configuration
- local security preferences

If you are using Notion tools, add a valid Notion integration token through the app's connection flow or config file.

### Factory reset (Settings → Maintenance)

**Factory Reset** clears local config, Keychain entries for The Bridge, resets macOS permissions for the app, and reloads in-memory workspace connection state. **Skills** are cleared to an **empty** list.

**Credentials** (Settings → Security) are **opt-in**: enable “Keychain credentials & MCP tools” to use `credential_*` and `payment_execute` with stored payment methods. When disabled, those MCP tools are omitted from listings and fail closed if called.

If you launch the app with **`NOTION_API_TOKEN`** or **`NOTION_API_KEY`** set in the environment, Notion can still resolve a token after reset (that path is intentional for developers). Unset those variables when testing a truly empty workspace. Restart the app after reset so permission and connection UIs stay consistent.

---

## Transport surface

### Streamable HTTP

```text
POST http://127.0.0.1:9700/mcp
```

This is the primary HTTP MCP endpoint. The listener is bound to **loopback** only. For remote agents (e.g. cloud IDEs) that reach your Mac through an **HTTPS tunnel** to that port, set **Settings → Connections → Remote access → Tunnel URL** to your tunnel’s base URL (for example `https://xyz.trycloudflare.com`). That extends Streamable HTTP **Origin** / **Host** validation to include the tunnel hostname while keeping the default localhost-only behavior when the field is empty.

### Remote MCP security

When a tunnel URL is set, **`POST /mcp` requires** a configured **MCP remote token** in the same settings section (generate/copy there) and matching **`Authorization: Bearer …`** in your MCP client. Without a token, new MCP sessions are rejected (fail closed). With an **empty** tunnel URL, local use is unchanged and a bearer is optional (you can still set a token to harden localhost-only clients). Tokens are stored in the **Keychain** (service `kup.solutions.the-bridge`, account `mcp_bearer_token`); the legacy UserDefaults key `com.notionbridge.mcpBearerToken` remains a fallback read path. This static bearer is for the loopback/tunnel path; cloud clients use OAuth instead (see [Cloud connector](#cloud-connector)). For defense in depth at the edge, operators can put **Cloudflare Access** in front of the tunnel hostname — see [docs/operator/cloudflare-access-notion-bridge.md](docs/operator/cloudflare-access-notion-bridge.md). Browser-based clients such as Claude chat generally cannot supply Cloudflare service-token headers, and Cloudflare browser challenges or Browser Integrity Check on `/mcp` can block valid MCP traffic before it reaches the app. In that case, use a narrow path-scoped bypass for `POST /mcp` and rely on the TheBridge bearer token at the app layer.

### Legacy SSE

```text
GET  http://127.0.0.1:9700/sse
POST http://127.0.0.1:9700/messages
```

This is retained for clients that still use split SSE transport behavior.

### stdio

Use stdio when connecting local clients such as Claude Code or Cursor directly to the app process.

#### Using Bridge with Antigravity

Google Antigravity enforces a strict 100-tool limit per MCP server, whereas The Bridge exposes ~163 tools. To use Bridge with Antigravity, we have curated a subset of ~84 tools to stay under the limit.

You can launch the Bridge process with a `--multi-instance` flag (bypasses single-instance GUI guard) and `--allow-tools` flag pointing to the Antigravity allowlist:

```json
{
  "mcpServers": {
    "Bridge MCP": {
      "command": "/path/to/TheBridge",
      "args": [
        "--multi-instance",
        "--allow-tools",
        "/path/to/the-bridge/configs/antigravity-allowlist.json"
      ]
    }
  }
}
```

---

## Cloud connector

The Bridge can be added as a **custom connector in claude.ai (web + mobile) and ChatGPT**, letting those hosted assistants operate your Mac's tools securely. Verified end-to-end in v3.7.10 — Claude web and ChatGPT each list and act on local files over the connector.

**How it works:**

- The loopback server (`127.0.0.1:9700`) is published at a stable HTTPS URL (e.g. `https://mcp.kup.solutions/mcp`) through a **customer-owned Cloudflare Tunnel** — the Mac is never exposed directly.
- Cloud clients authenticate via **OAuth 2.1** against a **WorkOS AuthKit** authorization server: RFC 9728 Protected Resource Metadata, RFC 8707 resource indicators, Dynamic Client Registration, and PKCE. The connector advertises the standard OpenID scopes the authorization server actually mints, so the authorize step never fails with `invalid_scope`.
- After a valid token, **every `tools/call` is gated by the on-device security model** (tiers + macOS approval prompts). The authenticated principal is the operator; the local approval is the real guardrail.
- **Local ↔ cloud coexistence:** a direct-loopback request (no Cloudflare tunnel header) can fall back to the local static bearer, so desktop clients keep working while cloud OAuth is on. A tunnelled request always carries the tunnel header, so it can never reach that fallback — the static bearer can never bypass OAuth.
- Connector clients receive **compact JSON-RPC** responses (ChatGPT's importer cannot parse the SDK's SSE framing); the SSE path is retained for local desktop clients.

**Requirements:** the Mac must be awake with The Bridge running and the Cloudflare Tunnel up. WorkOS access tokens are short-lived, so cloud clients re-authorize periodically (the connector shows a "Connect"/reconnect prompt). See [docs/operator/cloud-deploy-runbook.md](docs/operator/cloud-deploy-runbook.md) and [docs/operator/connector-directory-submission.md](docs/operator/connector-directory-submission.md).

---

## Security model

The Bridge currently uses a **3-tier execution model**:

- **Open**
	- Executes immediately
	- Intended for read-only or low-risk operations
- **Notify**
	- Executes immediately
	- Sends a post-execution macOS notification
- **Request**
	- Requires explicit approval before execution
	- Used for sensitive or high-impact actions

The security gate also enforces command-aware escalation rules, sensitive-path handling, and handoff behavior for commands that should not run automatically.

---

## Permissions

Depending on the tools you use, The Bridge may require:
- Auto-prompted on first launch: Contacts, Notifications, and Automation target registration
- Manual in System Settings: Accessibility, Screen Recording, and Full Disk Access
- Separate grants for Contacts privacy access and Automation access to Contacts.app

The onboarding flow and Settings window surface current grant state, trigger native prompts when macOS allows it, and deep-link to recovery panes when manual re-authorization is required.

---

## Build and test

```bash
make build
make test
make app
make dmg
```

Other useful targets:

```bash
make clean
make install
make install-copy    # or: make install-agent-safe — copy .app to /Applications without full notarize (agent-safe)
make release
```

Sparkle cache-busting is handled at the app level via httpHeaders (PKT-431). Pre-release manual QA: [docs/pre-ship-qa-checklist.md](docs/pre-ship-qa-checklist.md). Local MCP smoke (app running): `python3 scripts/qa_local_mcp_smoke.py`.

---

## Repo structure

```text
the-bridge/
├── TheBridge/
│   ├── App/
│   ├── Config/
│   ├── Modules/
│   ├── Notion/
│   ├── Security/
│   ├── Server/
│   └── UI/
├── TheBridgeTests/
├── .github/
├── Package.swift
├── Makefile
├── README.md
├── SECURITY.md
└── AGENTS.md
```

---

## Security disclosures

Report security issues per [SECURITY.md](SECURITY.md) (scope, out-of-scope, and contact).

## Public updates (Sparkle)

The app’s `SUFeedURL` (see `Info.plist`) points at the **Sparkle appcast** (`appcast.xml`). For automatic updates to work for end users, that URL must return valid XML **without** logging into GitHub:

- **Option A — Public GitHub repo:** Keep the default `https://raw.githubusercontent.com/KUP-IP/the-bridge/main/appcast.xml` and set the repository to **public** (anonymous `curl` / incognito browser must show XML).
- **Option B — Private repo:** Host `appcast.xml` at any **public HTTPS** URL you control (e.g. CDN or static site), then set `SUFeedURL` to that URL and ship a new build. The file must match the repo’s generated appcast (`make dmg` / `make appcast`); **`length`** and **`sparkle:edSignature`** must match the exact DMG you publish.

Verify locally: `make check-appcast` (committed `appcast.xml` vs `Info.plist`), then `make verify-sparkle-feed` (reads `SUFeedURL` from `Info.plist` and curls the live feed).

### Purchase download (kup.solutions)

Stripe fulfillment uses the Cloudflare Worker in the **`kup.solutions`** repo (`workers/nb-fulfillment`). After each release:

1. Run **`make dmg`** in this repo — artifact is **`.build/the-bridge-v$(VERSION).dmg`**, where **`VERSION`** is **`CFBundleShortVersionString`** in **`Info.plist`** (same as **`DMG_NAME`** in the Makefile).
2. Upload that file to R2 bucket **`nb-downloads`** with object key **`DMG_OBJECT_KEY`** from **`kup.solutions/workers/nb-fulfillment/wrangler.toml`** (must match the filename exactly).
3. Deploy the worker if **`DMG_OBJECT_KEY`** changed: **`cd workers/nb-fulfillment && npx wrangler deploy --env production`**.

Until the new object exists in R2, paid downloads return **500** (“Download artifact not found”).

## License and distribution

The Bridge is **source-available commercial software**.

This repository is licensed under the **KUP Solutions Source-Available License** (Version 1.0, April 2026). You may view and reference the source code. Copying, modification, redistribution, derivative works, and commercial use are prohibited without written permission from KUP Solutions.

See [`LICENSE`](LICENSE) for the full license text. See also [`PRIVACY.md`](PRIVACY.md) and [`TERMS.md`](TERMS.md).

### Commercial use

For commercial use of The Bridge, a separate **Commercial Use License** is required. See [`COMMERCIAL_LICENSE.md`](COMMERCIAL_LICENSE.md) for the full terms and purchase at [thebridge.kup.solutions/pricing](https://thebridge.kup.solutions/pricing).

---

## LSP server prerequisites (optional, for `lsp_*` tools)

The `lsp_*` tools (PKT-745, v2.2 · 2.3) wrap external Language Server Protocol implementations. The tools register and report `capability_missing` if the underlying servers are absent, so they are safe to leave uninstalled — they only become functional once the matching server is on disk. (The Bridge's `Tools` group `lsp` cleanly fails-closed via `BridgeToolError.moduleGroupDisabled` when the operator toggles the entire group off in Settings.)

| Language    | LSP server                  | Install                                                                                                                       |
|-------------|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| TypeScript / JavaScript | `typescript-language-server` | `npm install -g typescript-language-server typescript`                                                                        |
| Swift       | `sourcekit-lsp`             | Ships with the Xcode toolchain (`/Applications/Xcode.app/...`). Falls back to Command Line Tools (`xcode-select --install`).  |

Probe-supported install locations (checked in order):

- **typescript-language-server:** `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.local/bin`
- **sourcekit-lsp:** Xcode default toolchain, then CommandLineTools

If you install via a non-standard npm prefix, symlink the binary into one of the supported directories.

### LSP session supervision (`lsp_session_list`)

LSP servers are long-running processes; The Bridge supervises them out-of-band from the short-lived shell processes managed by `bg_process_*`. Each `(language, workspaceRoot)` pair gets a single `LspSession` lazy-spawned on first request, idle-disposed after 15 minutes of inactivity, and observable via `lsp_session_list` (PID, server name/version, spawn / last-used timestamps, idle seconds, request count, open-file count).

- **`lsp_session_list`** — LSP server processes only (typescript-language-server, sourcekit-lsp). Use this for LSP-specific lifecycle questions: “is the TS server up?”, “how many open files does the Swift session have?”, “when will it idle out?”.
- **`bg_process_list`** — Foreground-detached shell processes spawned via `bg_process_*` (long-running builds, watchers, dev servers). Use this for user-launched commands; LSP servers are **not** listed here.

The two surfaces are deliberately separated so observability for LSP supervision (which has its own RPC lifecycle, didOpen tracking, and capability probe) does not collide with generic shell lifecycle (which has none of those). When debugging cross-cutting state, query both.
