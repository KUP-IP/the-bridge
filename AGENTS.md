# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

NotionBridge is a native macOS menu bar app (Swift 6.2, macOS 26+, Apple Silicon) that runs an MCP (Model Context Protocol) server. It exposes **81+N** MCP tools in a typical configuration — **80** from registered feature modules (`BridgeConstants.staticFeatureModuleToolCount`), **1** builtin (`echo`), plus **N** tools from the optional remote Stripe MCP proxy when API discovery succeeds (**N=0** if Stripe is not configured or discovery fails) — over Streamable HTTP, legacy SSE, and stdio, routing every call through a security gate with an append-only audit log. Feature code is organized in **15** Swift modules (`*Module`); `echo` is registered separately as `builtin`, and Stripe tools are registered dynamically from `StripeMcpModule`.

Bundle ID: `kup.solutions.notion-bridge` (legacy: `solutions.kup.keepr`)

> **Agents:** see [`docs/AGENT_PLAYBOOK.md`](docs/AGENT_PLAYBOOK.md) for a task → tool
> map (builds/tests → `bg_process_*`, surgical edits → `file_edit`, filesystem grounding
> → `system_info`, long Notion reads → `notion_query` projection, etc.) before falling
> back to `shell_exec`.

## Commands

### Build

```bash
# Debug build (fast iteration)
make debug
# or: swift build -c debug

# Release build (strict concurrency enforced)
make build
# or: swift build -c release -Xswiftc -strict-concurrency=complete
```

### Test

The test suite is a **standalone executable**, not XCTest. It must be compiled and run as a binary:

```bash
make test
# Equivalent to: swift build -c debug && .build/debug/NotionBridgeTests
```

There is no way to run a single test file in isolation — all tests run from `NotionBridgeTests/main.swift`, which calls module-level `run*Tests()` functions.

### App Bundle & Distribution

```bash
make app           # Release build + package .build/NotionBridge.app
make install       # sign → notarize → staple → ditto → /Applications/Notion Bridge.app (needs Developer ID + notary keychain profile)
make install-copy  # Same .app to /Applications without sign/notarize — local dev only
make dmg           # Create distributable DMG
make sign          # Code-sign with Developer ID
make notarize      # Submit to Apple notarization (requires keychain profile)
make release       # Full pipeline: clean → test → app → sign → notarize → dmg → verify
make check-appcast # Fail if appcast.xml does not match Info.plist version/build numbers
```

**Production install ladder (canonical):** `make test` → `make app` → `make install` when signing credentials exist; otherwise `make install-copy` and accept ad-hoc / Gatekeeper differences. **`swift build` alone does not refresh `/Applications`** — always use the Makefile app target.

**Agents / Cursor / MCP-driven sessions:** After `make app`, use **`make install-copy`** or **`make install-agent-safe`** (same target) to copy `.build/NotionBridge.app` → `/Applications/Notion Bridge.app` without running the full notarize pipeline. Avoid long `make install` / `make release` from the same session that hosts your MCP connection if the workflow would time out or abort. The `install` target only sends `killall Dock` (icon refresh), not the Notion Bridge process—historical friction is documented in `AGENT_FEEDBACK.md` and resolved by preferring `install-copy` for copy-only installs.

If `make app` warns that `actool` failed, icons may fall back to PNGs; see Makefile `app` target (asset compile is best-effort). A common cause is a broken **ibtoold** plugin load (`xcodebuild -runFirstLaunch` or opening **Xcode** once to refresh system content), not Swift source errors.

### Maintenance

```bash
make clean      # Remove build artifacts
make clean-tcc  # Reset TCC permissions for both legacy (solutions.kup.keepr) and current bundle IDs
```

### Agent workflow hardening notes

- **Portable repository search:** Prefer `rg` when available, but do not assume it exists in every agent shell. Use POSIX fallbacks such as `find . -type f ...`, `grep -R`, and `sed -n` before treating a search failure as missing source.
- **Patch scripts:** Before generating Node-based patch scripts, check the package module type (`package.json` `type`, file extension, or existing scripts). For cross-repo agent edits, Python `pathlib` patch scripts are the safest default because they avoid CommonJS/ESM `require` drift.
- **Cloudflare Pages in mixed repos:** For repositories that contain both Worker and Pages configs, run Pages deploys from a temporary clean cwd or explicitly point Wrangler at the Pages project directory/config so Worker-only bindings do not contaminate the Pages deploy context.
- **Notion comments/discussions:** Comment and discussion tools are inline-rich-text surfaces, not page-body block markdown. Keep each rich_text run ≤ 2000 characters; split long notes into multiple comments or write long structured/code content to a page/code block.
- **Shell execution:** `shell_exec` reports `success`, `status`, `timedOut`, `terminationReason`, output line counts, and truncation metadata. Use `env` for explicit environment overrides, `loginShell: true` only when profile-loaded tooling is required, and `stdoutHeadLines`/`stdoutTailLines`/`stderrHeadLines`/`stderrTailLines` when large output should be summarized. Background commands ending in `&` remain capped to a short request window; redirect to logs and poll when detaching work.

### Configuration

Set the HTTP/SSE port (default 9700):
```bash
NOTION_BRIDGE_PORT=9701 .build/release/NotionBridge
```

Set the Notion API token (resolution priority order):
1. `NOTION_API_TOKEN` environment variable
2. `NOTION_API_KEY` environment variable (legacy)
3. `~/.config/notion-bridge/config.json` — key: `notion_api_token`

**Cursor MCP (avoid duplicates):** use a **single** global MCP entry in `~/.cursor/mcp.json` named **`Bridge MCP`** (JSON key), pointing at your Streamable HTTP URL (and `Authorization: Bearer` when required). Do **not** add a workspace-scoped duplicate — remove it under Cursor **Settings → MCP** if present, then restart Cursor.

## Git & Release Hygiene

- **`main`** on `origin` is the integration branch for shipped behavior; integrate via normal merge or PR — **no force-push**, **no history rewrite**.
- Before a production install or risky verification pass, if the working tree is mixed or uncommitted, create a backup branch, commit the current state, and push it before additional surgery.
- Do not push mixed emergency or verification state directly to `main` without review.
- Use `backup/*` branches as recovery snapshots; fold them into `main` when ready, then avoid long-lived duplicate integration lines.
- Split stability fixes, settings/UI restructures, and unrelated documentation or test drift into separate reviewable commits when feasible.
- When installing a production candidate, verify the running binary path is `/Applications/Notion Bridge.app/Contents/MacOS/NotionBridge`, not a `.build` artifact.

### Branching strategy (trunk-based, short-lived branches)

Trunk = `origin/main`. Branches are short-lived and **rebased onto current main before work resumes**. The v3.7.10 connector incident is the cautionary tale: a feature branch (`feat/backend-remediation`) sat 25+ commits behind main and re-implemented the connector that was *already shipped on main* (PKT-810) — duplicating ~1.5h of effort and nearly regressing the keychain fix. The rules that prevent it:

- **Branch off CURRENT main, never a stale base.** `git fetch origin && git switch -c <branch> origin/main`.
- **Rebase before you resume.** If `main` moved while a branch was idle, `git rebase origin/main` (or merge) **before** continuing — *mandatory* before touching shared surfaces (`SSETransport`, `MCPHTTPValidation`, connector/OAuth/auth, security, keychain). Stale-base edits to these are how divergent reimplementations happen.
- **Keep the primary checkout (`/Users/keepup/Developer/the-bridge`) on `main`.** Do feature work in a `git worktree` or a fresh branch — never leave the primary checkout parked on a feature branch (it strands local `main` and invites edits to the wrong branch; this review was itself almost committed to the wrong branch that way).
- **Commit and push WIP the same day.** No long-lived *uncommitted* work in a shared checkout — it is invisible to other sessions/agents and fragile. Push WIP branches so collaborators can rebase on them rather than re-deriving the work.
- **One owner per shared subsystem per release cycle.** The connector/OAuth/transport surface gets a single owner at a time; parallel agents coordinate via PR against main, not parallel rewrites of the same files.
- **After each release: delete merged branches and prune merged worktrees.** A branch with `git rev-list --count origin/main..<branch>` == 0 is fully merged — delete it. Target ≤ 2 active worktrees. See `docs/operator/BRANCHING-STRATEGY-REVIEW.md` for the standing audit + cleanup commands.

### Release flow (the v3.7.x → 3.8.x pattern)

**Versioning (operator rule, 2026-06-15):** each merged branch bumps the marketing version **+1 patch**, but segments are **single-digit and roll at 9** — never double digits. Patch 9 → `X.(Y+1).0`; minor 9 → `(X+1).0.0` (so `3.8.9 → 3.9.0`, `3.9.9 → 4.0.0`). **The next version is `3.8.0`** — the `3.7.10`–`3.7.12` double-digit patches were pre-rule legacy, so restart clean at 3.8.0. **`4.0.0` is the sale-ready "V4" destination, reached incrementally** (each patch advances the product toward ready-for-sale). `CFBundleVersion` (build) is monotonic +1, independent of the marketing roll. Override only when Isaiah specifies.

1. `git switch -c release/vX.Y.Z origin/main` (off current main).
2. One atomic version commit: `Version.swift` (marketing + build) **and** root `Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`) in the SAME commit (see `### Version surfaces`), plus the `CHANGELOG.md` entry.
3. `make test-floor` green (suite ≥ floor; raise the floor only by net-new tests, never lower it).
4. `make install-copy` for an on-device smoke test; relaunch via `open -a "The Bridge"` so it inherits the launchd OAuth env (`solutions.kup.bridge-env`) — a bare relaunch serves the placeholder issuer and breaks Claude web.
5. Fast-forward main: verify `git merge-base --is-ancestor origin/main HEAD`, then `git push origin release/vX.Y.Z:main`.
6. Tag: `git tag -a vX.Y.Z -m "…" && git push origin vX.Y.Z` → `release.yml` runs test→sign→notarize→DMG+appcast (~28 min).
7. After the run succeeds, delete the release branch and prune its worktree.

## Architecture

### Package Structure

`Package.swift` defines three targets:
- **`NotionBridgeLib`** — shared library containing all core logic. Covers everything in `NotionBridge/` except `App/NotionBridgeApp.swift` and `Server/main.swift`. Both the app and the test executable depend on this.
- **`NotionBridge`** — app executable. Entry point is `App/NotionBridgeApp.swift`.
- **`NotionBridgeTests`** — test executable. Entry point is `NotionBridgeTests/main.swift`.

Dependencies: `MCP` (MCP Swift SDK 0.11.0), `NIOCore/NIOPosix/NIOHTTP1` (swift-nio 2.65+).

### Request Data Flow

Every tool call follows this pipeline regardless of transport:

```
Client → Transport (stdio or SSE) → ServerManager → ToolRouter.dispatch()
       → SecurityGate.enforce() → Module handler → AuditLog.append() → Response
```

`ToolRouter` is the central dispatch hub and is transport-agnostic. Modules never know which transport delivered the request.

### Core Components

**`ServerManager`** (`NotionBridge/Server/ServerManager.swift`) — actor that orchestrates startup: creates `SecurityGate`, `AuditLog`, and `ToolRouter`; registers all modules; wires MCP `ListTools`/`CallTool` handlers; starts both transports concurrently via `TaskGroup`. The `NOTION_BRIDGE_PORT` env var is read here.

**`ToolRouter`** (`NotionBridge/Server/ToolRouter.swift`) — actor. Central registry and dispatch hub. Each `ToolRegistration` carries a name, module, `SecurityTier`, description, JSON input schema, and a `@Sendable` async handler closure. `dispatchFormatted()` is the shared helper used by all transports (returns `(text: String, isError: Bool)` for MCP `CallTool` responses).

**`SecurityGate`** (`NotionBridge/Security/SecurityGate.swift`) — actor. Enforces a 3-tier model:
- `.open` — execute immediately, no user interaction
- `.notify` — execute immediately, then send a fire-and-forget notification via `UNUserNotificationCenter`
- `.request` — request explicit user approval before execution; 30-second timeout defaults to deny

Three decision outcomes: `.allow`, `.reject(reason:)`, `.handoff(command:explanation:warning:)`. Handoff is **not an error** — it returns a JSON response to the caller with instructions to run the command manually. Nuclear patterns (e.g., `diskutil erasedisk`, `csrutil disable`, `dd if=`, fork bomb, recursive delete of `/`) always produce handoff regardless of tier or trusted mode. `sudo` is always a handoff. **Trusted mode** (UserDefaults key `com.notionbridge.security.trustedMode`) auto-allows all `.notify` tier calls; nuclear and dangerous command patterns are still enforced.

For `shell_exec`/`cli_exec` tools, commands matching `safeCommandPatterns` (read-only: `ls`, `cat`, `git status`, etc.) auto-allow. Commands matching `dangerousCommandPatterns` (pipe to shell, `chmod 777`, etc.) produce handoff.

**`AuditLog`** (`NotionBridge/Security/AuditLog.swift`) — actor. Append-only in-memory log with disk persistence via `LogManager`. Writes to `~/Library/Logs/NotionBridge/notion-bridge.log` (JSON lines, 10MB rotation with one backup). Every tool call gets an `AuditEntry` regardless of outcome (approved / rejected / escalated / error).

**`SSEServer`** (`NotionBridge/Server/SSETransport.swift`) — actor. NIO-based HTTP server with two transport modes:
- **Streamable HTTP**: `POST /mcp` with `Mcp-Session-Id` header — each session gets its own `StatefulHTTPServerTransport` and `Server` instance, all sharing one `ToolRouter`. Request validation is built by **`MCPHTTPValidation.streamableHTTPPipeline`**: localhost-only origins/hosts by default; if **`tunnelURL`** (Remote access in UI) is set **and** parses to a host allowlist, the tunnel host is merged into the allowlist and **`POST /mcp` requires** a configured MCP bearer (**Keychain** `mcp_bearer_token`, else **`com.notionbridge.mcpBearerToken`** for migration) plus `Authorization: Bearer` — fail closed if the tunnel is active but no token is set. If **`tunnelURL`** is empty, bearer remains optional (same token keys when set). The HTTP server still listens on **127.0.0.1** only (`ServerManager`); there is no LAN-wide bind. Operators often add **Cloudflare Access** on the tunnel hostname; see `docs/operator/cloudflare-access-notion-bridge.md`.
- **Legacy SSE**: `GET /sse` + `POST /messages` — for clients like Notion that use the standard split SSE spec
- **Health endpoint**: `GET /health` returns JSON `{status, tools, uptime, version, clients}`

`LegacySSEBridge` is `@unchecked Sendable` (uses `NSLock`) to safely write SSE events to NIO channels from async contexts.

**`AppDelegate`** (`NotionBridge/App/AppDelegate.swift`) — single-instance guard (PID check), `SMAppService` login item registration, signal handlers (SIGTERM/SIGABRT → `fsync` for crash breadcrumbs), launches both transports in a `Task.detached` group.

### Module Registration Pattern

Every module exposes a `static func register(on router: ToolRouter) async` method (some take additional parameters, e.g., `SessionModule.register(on:auditLog:)`). `ServerManager.setup()` calls all of them in sequence. Adding a new tool means adding a `ToolRegistration` inside the module's `register` method.

### Skills MCP tools (`SkillsModule`)

MCP metadata (`summary`, `triggerPhrases`, `antiTriggerPhrases`) is **authoritative** in app storage (`com.notionbridge.skills`). Optional Notion page `rich_text` properties mirror it for humans: **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`** (one phrase per line in the latter two). Use `manage_skill` **`sync_metadata_to_notion`** / **`sync_metadata_from_notion`** to copy in either direction; create those properties on the skill page if missing.

- **`list_routing_skills`** (`.open`) — Returns enabled skills with `visibility == routing` and a non-empty Notion page id, including MCP metadata fields. Does not fetch page bodies.
- **`fetch_skill`** (`.open`) — Loads a configured skill page: paginates blocks, returns `summary` / `triggerPhrases` / `antiTriggerPhrases` next to `content`. Cache key includes a metadata fingerprint so metadata edits do not reuse stale fetches.
- **`manage_skill`** (`.request`) — Registry CRUD, `set_visibility`, **`set_metadata`** (partial updates), and Notion sync actions above. Not a secrecy boundary: approved calls still see all skills.

`notion_page_read` uses the same block collection as skills: paginated siblings; optional nesting via `includeNested` (default false). Prefer `notion_page_markdown_read` for full prose when block structure is unnecessary.

### Credentials (`CredentialModule` + `payment_execute`)

Enable **Keychain credentials** in Settings to expose `credential_*` MCP tools and allow `payment_execute` (Stripe PaymentIntent using a stored `pm_` from `credential_save`). When disabled, credential tools are filtered from `ListTools` and dispatch fails closed; `payment_execute` also checks the flag.

### Version surfaces

- **MCP protocol** — `BridgeConstants.mcpProtocolVersion` (Model Context Protocol spec date), used in MCP `initialize` / legacy JSON-RPC.
- **Notion REST API** — `BridgeConstants.notionAPIVersion` → `Notion-Version` header on `https://api.notion.com` (Notion workspace tools). Distinct from MCP and from Notion’s hosted MCP (`mcp.notion.com`).

### Notion Token Configuration

`NotionTokenResolver` (`NotionBridge/Notion/NotionClient.swift`) handles token resolution at runtime. To update the token from the UI, call `NotionTokenResolver.writeToken(_:)` (writes to `~/.config/notion-bridge/config.json`) and post `Notification.Name.notionTokenDidChange` to trigger re-validation. Token format must start with `ntn_` or `secret_` and be ≥20 characters.

### Swift 6 Concurrency Notes

The project enforces Swift 6 strict concurrency (`-strict-concurrency=complete`). Key patterns to follow:
- All shared mutable state lives in `actor` types (`ToolRouter`, `SecurityGate`, `AuditLog`, `ServerManager`, `SSEServer`, `LogManager`).
- `StatusBarController` is `@MainActor @Observable`.
- Closures passed across actor boundaries must be `@Sendable`.
- `LegacySSEBridge` uses `@unchecked Sendable` with `NSLock` — this is intentional to avoid passing actor references into NIO pipeline handlers (see PKT-338 comment in `SSETransport.swift`).
- NIO `ChannelHandlerContext` references stored in closures must be marked `nonisolated(unsafe)`.

### TCC Permissions

The app requires Full Disk Access, Automation, and optionally Screen Recording and Accessibility. During development, after frequent rebuilds that change the code signature, run `make clean-tcc` to clear stale TCC grants for both the current (`kup.solutions.notion-bridge`) and legacy (`solutions.kup.keepr`) bundle IDs.

## Jobs (scheduler module) — v1.9.1

The scheduler module exposes 15 MCP tools for background job management. Jobs are backed by SQLite (`~/Library/Application Support/NotionBridge/jobs.sqlite`) and launchd LaunchAgents in `~/Library/LaunchAgents/solutions.kup.notionbridge.job.<id>.plist`. Each job runs a chain of up to 10 tool invocations via the bridge's own ToolRouter, with `$prev_result` templating between steps.

### Tool inventory (15)

| Tool | Tier | Purpose |
|---|---|---|
| `job_create` | notify | Create a scheduled job (5-field cron + action chain). |
| `job_get` | open | Get a job by id with last 10 executions. |
| `job_list` | open | List all jobs. |
| `job_delete` | notify | Delete a job (unregister LaunchAgent, remove plist + DB row, cascade executions). |
| `job_pause` | open | Pause (unregister LaunchAgent, keep row + plist). |
| `job_resume` | open | Resume a paused job. |
| `job_history` | open | Last N executions for a job. |
| `job_templates` | open | List common job presets. |
| **`job_run`** | notify | **v1.9.1** — Trigger immediate run, bypassing schedule. |
| **`job_update`** | notify | **v1.9.1** — Patch name/schedule/actions/skipOnBattery. Schedule changes trigger atomic LaunchAgent re-registration with rollback. |
| **`job_duplicate`** | notify | **v1.9.1** — Clone a job with a fresh id and LaunchAgent. |
| **`job_export`** | open | **v1.9.1** — Export all or selected jobs as a versioned JSON envelope. |
| **`job_import`** | notify | **v1.9.1** — Import jobs from an envelope (IDs regenerated). |
| **`jobs_pause_all`** | notify | **v1.9.1** — Kill-switch: pause all active jobs in parallel. |
| **`jobs_resume_all`** | notify | **v1.9.1** — Resume all paused jobs in parallel. |

UI: **Settings → Jobs** (`JobsView` + `JobDetailView`). All UI mutations call `JobsManager.shared` actor methods directly; no MCP round-trip from the app shell.
