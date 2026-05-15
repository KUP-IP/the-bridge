# NotionBridge

**A native macOS menu-bar app that turns your Mac into an MCP server for Notion AI agents and local coding clients.**

NotionBridge exposes local Mac capabilities and connected services as MCP tools over **Streamable HTTP**, **legacy SSE**, and **stdio**. It is built in Swift 6.2 for macOS 26+ on Apple Silicon and is designed to be always-on, auto-launched, and safe enough for daily operator use.

**81+N tools** (80 feature module tools + `echo` + **N** dynamic Stripe MCP tools) · **3 transports** · **3-tier security model** · **Customer-owned Cloudflare Tunnel support**

**Product page:** https://kup.solutions/notion-bridge

---

## What this repo is

This is the product repository for **NotionBridge**.

It is not a generic Swift experiment and it is not an open-source demo server. It is the source-available codebase for a commercial macOS product that bridges Notion agents, local coding tools, and the user's Mac.

Current commercial posture:
- Direct purchase is the primary distribution path.
- No free tier is planned.
- Setapp distribution may follow later.

---

## Current product surface

NotionBridge currently ships the following module surface:

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
| **Total** | **81+N** | 80 feature module tools + `echo` + **N** dynamic Stripe MCP tools (currently 26 when configured) |

Core product traits:
- Native macOS menu-bar app with onboarding, settings, and a status popover
- Auto-launch via `SMAppService`
- Streamable HTTP and legacy SSE on the same local server surface
- stdio support for local clients such as Claude Code and Cursor
- Local-first security gate with audit logging
- Optional remote access through a customer-owned Cloudflare Tunnel

---

## Installation

### Option 1: Download a release

1. Download the latest DMG from [GitHub Releases](https://github.com/KUP-IP/Notion-bridge/releases).
2. Open the DMG.
3. Drag `NotionBridge.app` into `/Applications`.
4. Launch the app and complete onboarding.

### Option 2: Build from source

```bash
git clone https://github.com/KUP-IP/Notion-bridge.git
cd Notion-bridge
make app
```

The app bundle is written to `.build/NotionBridge.app`.

> **Install naming:** The Swift target is `NotionBridge` (no space), so build output and DMG contents use `NotionBridge.app`. The Finder display name is **Notion Bridge** (with space), set by `CFBundleName` / `CFBundleDisplayName` in `Info.plist`. `make install` places the app at `/Applications/Notion Bridge.app` to match the display name. Both names refer to the same product.

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

NotionBridge supports:
- Notion workspace connections
- connection health checks
- customer-owned remote-access configuration
- local security preferences

If you are using Notion tools, add a valid Notion integration token through the app's connection flow or config file.

### Factory reset (Settings → Maintenance)

**Factory Reset** clears local config, Keychain entries for Notion Bridge, resets macOS permissions for the app, and reloads in-memory workspace connection state. **Skills** are cleared to an **empty** list.

**Credentials** (Settings → Credentials) are **opt-in**: enable “Keychain credentials & MCP tools” to use `credential_*` and `payment_execute` with stored payment methods. When disabled, those MCP tools are omitted from listings and fail closed if called.

If you launch the app with **`NOTION_API_TOKEN`** or **`NOTION_API_KEY`** set in the environment, Notion can still resolve a token after reset (that path is intentional for developers). Unset those variables when testing a truly empty workspace. Restart the app after reset so permission and connection UIs stay consistent.

---

## Transport surface

### Streamable HTTP

```text
POST http://127.0.0.1:9700/mcp
```

This is the primary HTTP MCP endpoint. The listener is bound to **loopback** only. For remote agents (e.g. cloud IDEs) that reach your Mac through an **HTTPS tunnel** to that port, set **Settings → Connections → Remote access → Tunnel URL** to your tunnel’s base URL (for example `https://xyz.trycloudflare.com`). That extends Streamable HTTP **Origin** / **Host** validation to include the tunnel hostname while keeping the default localhost-only behavior when the field is empty.

### Remote MCP security

When a tunnel URL is set, **`POST /mcp` requires** a configured **MCP remote token** in the same settings section (generate/copy there) and matching **`Authorization: Bearer …`** in your MCP client. Without a token, new MCP sessions are rejected (fail closed). With an **empty** tunnel URL, local use is unchanged and a bearer is optional (you can still set a token to harden localhost-only clients). Tokens are stored in the **Keychain** in the app; **`com.notionbridge.mcpBearerToken`** remains a legacy read path. For defense in depth at the edge, operators can put **Cloudflare Access** in front of the tunnel hostname — see [docs/operator/cloudflare-access-notion-bridge.md](docs/operator/cloudflare-access-notion-bridge.md). Browser-based clients such as Claude chat generally cannot supply Cloudflare service-token headers, and Cloudflare browser challenges or Browser Integrity Check on `/mcp` can block valid MCP traffic before it reaches the app. In that case, use a narrow path-scoped bypass for `POST /mcp` and rely on the NotionBridge bearer token at the app layer.

### Legacy SSE

```text
GET  http://127.0.0.1:9700/sse
POST http://127.0.0.1:9700/messages
```

This is retained for clients that still use split SSE transport behavior.

### stdio

Use stdio when connecting local clients such as Claude Code or Cursor directly to the app process.

#### Using Bridge with Antigravity

Google Antigravity enforces a strict 100-tool limit per MCP server, whereas Notion Bridge exposes ~180 tools. To use Bridge with Antigravity, we have curated a subset of ~84 tools to stay under the limit.

You can launch the Bridge process with a `--multi-instance` flag (bypasses single-instance GUI guard) and `--allow-tools` flag pointing to the Antigravity allowlist:

```json
{
  "mcpServers": {
    "Bridge MCP": {
      "command": "/path/to/NotionBridge",
      "args": [
        "--multi-instance",
        "--allow-tools",
        "/path/to/notion-bridge/configs/antigravity-allowlist.json"
      ]
    }
  }
}
```

---

## Security model

NotionBridge currently uses a **3-tier execution model**:

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

Depending on the tools you use, NotionBridge may require:
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
Notion-bridge/
├── NotionBridge/
│   ├── App/
│   ├── Config/
│   ├── Modules/
│   ├── Notion/
│   ├── Security/
│   ├── Server/
│   └── UI/
├── NotionBridgeTests/
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

- **Option A — Public GitHub repo:** Keep the default `https://raw.githubusercontent.com/KUP-IP/Notion-bridge/main/appcast.xml` and set the repository to **public** (anonymous `curl` / incognito browser must show XML).
- **Option B — Private repo:** Host `appcast.xml` at any **public HTTPS** URL you control (e.g. CDN or static site), then set `SUFeedURL` to that URL and ship a new build. The file must match the repo’s generated appcast (`make dmg` / `make appcast`); **`length`** and **`sparkle:edSignature`** must match the exact DMG you publish.

Verify locally: `make check-appcast` (committed `appcast.xml` vs `Info.plist`), then `make verify-sparkle-feed` (reads `SUFeedURL` from `Info.plist` and curls the live feed).

### Purchase download (kup.solutions)

Stripe fulfillment uses the Cloudflare Worker in the **`kup.solutions`** repo (`workers/nb-fulfillment`). After each release:

1. Run **`make dmg`** in this repo — artifact is **`.build/notion-bridge-v$(VERSION).dmg`**, where **`VERSION`** is **`CFBundleShortVersionString`** in **`Info.plist`** (same as **`DMG_NAME`** in the Makefile).
2. Upload that file to R2 bucket **`nb-downloads`** with object key **`DMG_OBJECT_KEY`** from **`kup.solutions/workers/nb-fulfillment/wrangler.toml`** (must match the filename exactly).
3. Deploy the worker if **`DMG_OBJECT_KEY`** changed: **`cd workers/nb-fulfillment && npx wrangler deploy --env production`**.

Until the new object exists in R2, paid downloads return **500** (“Download artifact not found”).

## License and distribution

NotionBridge is **source-available commercial software**.

This repository is licensed under the **KUP Solutions Source-Available License** (Version 1.0, April 2026). You may view and reference the source code. Copying, modification, redistribution, derivative works, and commercial use are prohibited without written permission from KUP Solutions.

See [`LICENSE`](LICENSE) for the full license text. See also [`PRIVACY.md`](PRIVACY.md) and [`TERMS.md`](TERMS.md).

---

## LSP server prerequisites (optional, for `lsp_*` tools)

The `lsp_*` tools (PKT-745, v2.2 · 2.3) wrap external Language Server Protocol implementations. The tools register and report `capability_missing` if the underlying servers are absent, so they are safe to leave uninstalled — they only become functional once the matching server is on disk.

| Language    | LSP server                  | Install                                                                                                                       |
|-------------|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| TypeScript / JavaScript | `typescript-language-server` | `npm install -g typescript-language-server typescript`                                                                        |
| Swift       | `sourcekit-lsp`             | Ships with the Xcode toolchain (`/Applications/Xcode.app/...`). Falls back to Command Line Tools (`xcode-select --install`).  |

Probe-supported install locations (checked in order):

- **typescript-language-server:** `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.local/bin`
- **sourcekit-lsp:** Xcode default toolchain, then CommandLineTools

If you install via a non-standard npm prefix, symlink the binary into one of the supported directories.

### LSP session supervision (`lsp_session_list`)

LSP servers are long-running processes; NotionBridge supervises them out-of-band from the short-lived shell processes managed by `bg_process_*`. Each `(language, workspaceRoot)` pair gets a single `LspSession` lazy-spawned on first request, idle-disposed after 15 minutes of inactivity, and observable via `lsp_session_list` (PID, server name/version, spawn / last-used timestamps, idle seconds, request count, open-file count).

- **`lsp_session_list`** — LSP server processes only (typescript-language-server, sourcekit-lsp). Use this for LSP-specific lifecycle questions: “is the TS server up?”, “how many open files does the Swift session have?”, “when will it idle out?”.
- **`bg_process_list`** — Foreground-detached shell processes spawned via `bg_process_*` (long-running builds, watchers, dev servers). Use this for user-launched commands; LSP servers are **not** listed here.

The two surfaces are deliberately separated so observability for LSP supervision (which has its own RPC lifecycle, didOpen tracking, and capability probe) does not collide with generic shell lifecycle (which has none of those). When debugging cross-cutting state, query both.
