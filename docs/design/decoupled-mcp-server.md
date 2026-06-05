# Design: Decoupled MCP Server (persistent helper)

**Status:** Spike / design-only. No code, no build. This document informs a future
implementation packet; it does **not** authorize implementation.
**Branch:** `feat/fb-design-decouple`
**Date:** 2026-06-04
**Owner:** Bridge runtime

---

## TL;DR

The Bridge today is a **single process**: one `NotionBridge` executable, launched
as a menu-bar app (`LSUIElement`), hosts the MCP server, the `:9700` HTTP/SSE
listener, all in-process tool modules, the SecurityGate, Sparkle, and (when
enabled) the cloudflared tunnel. When that process dies — for **any** reason: an
operator `make install`, a Sparkle self-update, a force-quit, a crash, a logout —
**every MCP session dies with it**. Clients see `-32600 "Session not found or
expired"` and must re-handshake (and, on claude.ai, re-`ToolSearch` to reload the
40+ deferred Bridge tool schemas). The same death takes down any long-running
work the agent had in flight.

This is the root cause behind a recurring, evidence-cited class of friction in
`AGENT_FEEDBACK.md` (the "session-death" cluster — see §2). It also imposes a
**per-install reconnect tax**: every operator update of the app — which The Bridge
*ships to itself* hourly via Sparkle — severs live agent sessions.

The proposal: **split the process in two.**

- A **persistent background helper** (launchd-managed daemon / agent) that owns
  the `:9700` HTTP/MCP server, all tool modules, the session table, the
  SecurityGate, and the cloudflared tunnel. It survives app quit, app reinstall,
  and Sparkle self-update of the **UI**.
- A **thin `.app`** that is a *UI client* of the helper: menu-bar item, Settings
  window, onboarding, permission prompts, and the operator's update surface. It
  can be quit, restarted, or replaced without touching live sessions.

The big wins: live MCP sessions survive UI restarts/updates (collapses the
session-death cluster), and long-running work is no longer hostage to the app's
lifecycle. The big costs/risks: a separately codesigned+notarized helper, TCC
grant inheritance across two binaries, an auth boundary between UI and helper, and
a more complex Sparkle update flow (you must be able to update the helper without
killing the very sessions you're trying to protect). These are covered in §6–§7
with an incremental rollout in §8.

---

## 1. Current architecture (verified)

All claims below are grounded in the current `origin/main` tree (file/line
references confirmed by reading the source, not inferred).

### 1.1 One process owns everything

`NotionBridge` is a SwiftUI `MenuBarExtra` app with `LSUIElement = true`
(`Info.plist:40`) and no Dock presence by default. `AppDelegate`
(`NotionBridge/App/AppDelegate.swift`) is the lifecycle owner. On
`applicationDidFinishLaunching` it:

1. Enforces a **single-instance guard** (`ensureSingleInstance()`,
   `AppDelegate.swift:179`) — only one `NotionBridge` may run at a time.
2. Bootstraps licensing, path migration, credential migration.
3. Calls `startMCPServer()` (`AppDelegate.swift:525`), which constructs a
   `ServerManager` and launches it in a **detached `Task`** (`serverTask`,
   `AppDelegate.swift:562`).

`ServerManager.setup()` (`NotionBridge/Server/ServerManager.swift:117`) builds the
core components in-process:

- `SecurityGate`, `AuditLog`, `ToolRouter` (the dispatcher).
- An `SSEServer` bound to **`127.0.0.1:<ssePort>`** (default `9700`;
  `SSETransport.swift:230`, host literal `"127.0.0.1"`). This single NIO listener
  hosts `GET /sse` + `POST /messages` (legacy), `GET /health`, the job callback
  `POST /jobs/<id>/run`, and the Streamable HTTP `/mcp` endpoint backed by
  `StatefulHTTPServerTransport` (`SSETransport.swift:659`).
- All feature modules, registered via `BridgeModuleRegistry`
  (`ServerManager.swift:169`) — Notion, file, shell, AX, screen, messages,
  contacts, calendar, reminders, credentials, jobs, Stripe, etc.

The server then runs **both transports concurrently** in a `withTaskGroup`
(`AppDelegate.swift:576`): `manager.run()` (stdio) and `manager.runSSE()` (the
`:9700` listener). The whole group lives inside `serverTask`, which is owned by
the `AppDelegate`, which lives in the single app process.

### 1.2 Sessions are in-memory and process-scoped

The Streamable HTTP transport is **stateful**: each client gets an
`Mcp-Session-Id` and a `SessionContext` (`SSETransport.swift:206`) holding a
`StatefulHTTPServerTransport`. The session table is an in-actor dictionary
(`sessions[sessionID]`), with a configurable `sessionTimeout` (default 300 s;
`SSETransport.swift:236`) and a periodic cleanup pass. A request for an unknown or
expired id returns **`404 "Session not found or expired"`**
(`SSETransport.swift:503`).

Crucially, this table has **no persistence**. It exists only in the running
actor's memory. When the process exits, the table is gone.

### 1.3 The death sequence

On `applicationWillTerminate` (`AppDelegate.swift:358`) the app:

```
serverTask?.cancel()          // cancels the stdio+SSE task group
serverManager.stopSSE()       // SSEServer.stop() removes every session, closes the channel
```

`SSEServer.stop()` (`SSETransport.swift:362`) iterates `sessions.keys` and removes
each one, then closes the listening channel. On the **next** launch a brand-new
`ServerManager` is constructed with a fresh, empty `SSEServer` — there is no
mechanism to restore the prior session table. The client's cached
`Mcp-Session-Id` no longer resolves → `404`.

There is also an **explicit** invalidation path:
`invalidateAllSessions(reason:)` (`SSETransport.swift:374`), fired on remote-access
config changes (`AppDelegate.swift:299`). Same effect, intentionally.

### 1.4 cloudflared tunnel (Bridge Cloud Access)

The tunnel is **not** the local transport. `:9700` is `127.0.0.1`-only
(loopback). The cloudflared tunnel belongs to **Bridge Cloud Access** (the WS-C
program): a persistent *outbound* connection from the Mac that a control plane
delivers capabilities over. It is modeled behind the injectable `TunnelProcess`
protocol (`NotionBridge/Modules/Cloud/TunnelProcess.swift`) and owned by
`BridgeCloudManager`.

Two facts matter for this design:

- Cloud access is **default-OFF** (`BridgeDefaults.cloudAccessEnabledValue`,
  gated in `ServerManager.setup():192`). In a default install there is **no**
  cloudflared process and **no** `bridge_status` tool.
- The production cloudflared conformer is **not yet wired** — `makeCloudManager()`
  (`ServerManager.swift:355`) currently assembles `FakeTunnelProcess` /
  `FakePasskeyGate` pending the live Worker (PKT-810 / WS-A). So today the tunnel
  is a state machine over fakes, not a real network process.

Either way, the tunnel's lifecycle is **bound to the app process** (started in
`setup()` / `setCloudAccessEnabled()`), so it dies with the app exactly like the
SSE server does.

### 1.5 Sparkle (self-update)

The app embeds Sparkle (`AppDelegate.swift:19`). An `SPUStandardUpdaterController`
is created at `init` (`AppDelegate.swift:160`), armed in production
(`startingUpdater: !runningInTestProcess`). The feed is
`https://raw.githubusercontent.com/KUP-IP/the-bridge/main/appcast.xml`
(`Info.plist:54`), EdDSA-signed (`SUPublicEDKey`, `Info.plist:56`), checked on a
`SUScheduledCheckInterval` of **3600 s** (hourly, `Info.plist:58`).

Sparkle replaces the **entire `.app` bundle** in `/Applications/The Bridge.app`
and relaunches. Because the MCP server is *inside* that bundle's process, **every
hourly self-update is a potential session-death event** for any agent connected at
the time. The `make install` recipe even documents an install/Sparkle race that
can corrupt the bundle, and adds a pre-install "quit app + clear Sparkle staging"
guard (`Makefile`, `PREINSTALL_SAFETY`) — concrete evidence that the
app-owns-everything coupling is already operationally painful.

### 1.6 Distribution & signing context (verified)

- **Team ID** `VP24Z9CS22`, **bundle id** `kup.solutions.notion-bridge`
  (`Info.plist:13`, `AppIdentifierPrefix VP24Z9CS22.`).
- **Developer ID** distribution (outside the App Store): signing identity
  `Developer ID Application: Isaiah Peters (VP24Z9CS22)` (`Makefile:38`),
  hardened runtime (`--options runtime`), `notarytool submit … --wait` + `stapler`
  (`Makefile:371`).
- `LSMinimumSystemVersion 26.0` (`Info.plist:38`).
- Entitlements (`NotionBridge.entitlements`): `allow-jit`,
  `allow-unsigned-executable-memory`, `disable-library-validation`,
  `automation.apple-events`, `personal-information.addressbook`,
  `personal-information.calendars`.

### 1.7 Prior art: a signed helper already ships in the bundle

The Bridge **already embeds a signed Developer-ID helper binary**:
`NBJobRunner` at `Contents/MacOS/NBJobRunner` (`Makefile:24`,
`NBJobRunner/main.swift`). It exists so that macOS Background Task Management
(BTM) attributes scheduled-job launchd items to The Bridge's code signature
instead of `/usr/bin/curl`. Its job is to POST `http://127.0.0.1:$NB_SSE_PORT/jobs/<id>/run`.

This is directly relevant: **The Bridge already ships a second signed executable,
already drives the `:9700` server from outside the app process via launchd, and
already proves the "thin client → loopback HTTP → server" call shape.** The Jobs
infra hosts launchd LaunchAgents whose action chains are MCP tool invocations
executed over SSE (`AppDelegate.swift:223–229`). The decoupled-server design is an
extension of a pattern The Bridge already uses, not a greenfield architecture.

### 1.8 Current topology (diagram)

```
                       ┌──────────────────────────────────────────────┐
                       │  NotionBridge.app  (single process, LSUIElement)│
   MCP clients         │                                                │
 (Claude Code,         │  AppDelegate                                   │
  Cursor, claude.ai,   │   ├─ Sparkle (SPUStandardUpdaterController)    │
  Notion AI)           │   ├─ Menu bar + Settings + Onboarding (UI)     │
        │  stdio       │   ├─ SMAppService login item                   │
        ├──────────────┼──▶ ServerManager (serverTask, detached)        │
        │              │   │   ├─ ToolRouter + SecurityGate + AuditLog  │
        │  HTTP /mcp   │   │   ├─ all tool modules (in-process)         │
        ├──────────────┼──▶ │   └─ SSEServer  :9700 (127.0.0.1)          │
        │  (Mcp-Session-Id) │        sessions{} in-memory, process-scoped│
                       │   └─ BridgeCloudManager → cloudflared (opt-in)  │
                       └──────────────────────────────────────────────┘
              app quits / Sparkle updates / crashes  ⇒  process dies
                       ⇒  sessions{} gone  ⇒  clients get 404
```

---

## 2. The problem: session-death evidence

`AGENT_FEEDBACK.md` is the evidence-only feedback log (one block per session).
The session-death class appears repeatedly and is explicitly root-caused to the
app-hosts-server coupling:

- **2026-05-16 (v3.0 prep):** *"Bridge MCP session is lost whenever The Bridge app
  restarts (the app hosts the MCP server) — every `notion_*`/`git_*` call returns
  `-32600 'Session not found or expired'` until the client re-handshakes; a server
  restart alone does not fix it. Induced by in-session `make install`. Evidence:
  post-`make install` … failures; root-caused via direct `:9700` probe (/health
  200, /mcp 401). Lesson saved to project memory."*
- **2026-05-20 (3.4.1 ship):** *"Bridge MCP session lost across app reinstall.
  Twice this session: (1) at the start of the reflow turn, (2) after `make install`
  of 3.4.1. Expected behavior per `App Restore Kills MCP Session` memory note, but
  every operator restart costs one tool-rediscovery cycle."*
- **2026-05-20 (3.4.1, reconnect tax):** *"every operator restart costs one
  tool-rediscovery cycle. Suggest … The Bridge MCP could surface a `session_resume`
  capability summarizing what tools are now available again — instead of letting
  the next caller hit a deferred-tool wall and load via `ToolSearch` again."*
- **2026-05-22:** *"Bridge MCP session-expiry not recovered by the harness HTTP
  client. `mcp__Bridge_MCP__*` calls returned `-32600 'Session not found or
  expired'` ~5× this session after The Bridge app was restarted. … App +
  cloudflared tunnel were healthy throughout."* (Confirms the death is the **app
  process**, not the tunnel.)
- **2026-05-20 (605-good-dog):** *"After a long … coding session, the system
  surfaced '36 deferred tools are no longer available (their MCP server
  disconnected)'. Two reconnect cycles fired before fetch_skill returned its first
  successful response."*
- **2026-05-30 (triage):** **FB-4 — session reinit** logged as still-open,
  marked *"DEFERRED — harness side."* This design addresses the **server side** of
  FB-4: a session that *can* survive is a precondition for any client-side resume.

The two costs, in the workflow's framing:

- **Cluster A (session death):** an MCP session vanishing mid-conversation when the
  app process ends.
- **Cluster C (long-running work death):** in-flight `bg_process_*` jobs, dev
  servers, and tunnel state dying with the app, even though the work itself is
  process-independent in principle.
- **Per-install reconnect tax:** because The Bridge self-updates hourly via Sparkle
  *and* the operator runs `make install` during development, the
  app-owns-everything coupling makes routine updates a session-severing event.

A persistent helper that **outlives the UI** collapses A and C and removes the
reconnect tax for the common case (UI restart / UI self-update), because the thing
the client is connected to (`:9700`) never goes away.

---

## 3. Goals & non-goals

### Goals

- **G1 — Survive UI restarts.** A `.app` quit/relaunch leaves `:9700` and every
  live MCP session untouched.
- **G2 — Survive UI self-update.** A Sparkle update of the **UI** does not sever
  sessions. (Updating the **helper** itself is handled deliberately — §6.5.)
- **G3 — Survive crashes.** The helper is launchd-`KeepAlive`; a helper crash
  auto-respawns. (Session continuity across a *helper* crash is a stretch goal —
  see §3 non-goals and §7-R7.)
- **G4 — Preserve security posture.** The SecurityGate, tier model, loopback-only
  bind, and the cloud-access default-OFF gate stay exactly as strong, or stronger.
- **G5 — Preserve byte-stability invariants.** Dark-mode bytes, the
  StandingOrders/handshake composition (`StandingOrdersDelivery` SSOT), tool
  surface, and the test floor are unchanged by the *transport relocation*; the only
  intended behavior change is *who owns the process*.
- **G6 — One TCC identity.** Tool capabilities that require TCC grants
  (Automation, Contacts, Calendar, Reminders, Screen Recording, Accessibility)
  keep working without re-prompting the user for a second binary.

### Non-goals (this spike)

- Not implementing anything. No code, no build.
- Not changing the **tool surface** or **tool semantics**.
- Not solving in-flight-request resumption across a **helper** crash/upgrade
  (a request that was mid-dispatch when the helper dies is lost; only the *session*
  is restorable). Full request-level durability is a later, separate effort.
- Not redesigning Bridge Cloud Access; only relocating *which process* owns the
  tunnel.
- Not switching off stdio. stdio remains a valid transport for clients that spawn
  the binary directly (see §5.4).

---

## 4. Proposed architecture

### 4.1 Two processes

```
   MCP clients                ┌────────────────────────────────────────┐
 (Claude Code, Cursor,        │  com.kup.solutions.bridge-helper        │
  claude.ai, Notion AI)       │  (launchd-managed, KeepAlive)            │
        │                     │                                          │
        │  HTTP /mcp :9700    │   ServerManager  (was in the .app)       │
        ├─────────────────────┼──▶ ToolRouter + SecurityGate + AuditLog │
        │  (Mcp-Session-Id)   │   ├─ all tool modules (in-process)       │
        │                     │   ├─ SSEServer :9700 (127.0.0.1)          │
        │                     │   │    sessions{}  (in-memory; §4.4)      │
        │                     │   └─ BridgeCloudManager → cloudflared     │
        │  stdio (optional,   │                                          │
        │  spawns thin shim   │   IPC control endpoint (loopback / XPC)  │
        │  → helper, §5.4)    │            ▲                              │
                              └────────────┼──────────────────────────────┘
                                           │ control + UI-state channel
                       ┌───────────────────┼──────────────────────────────┐
                       │  The Bridge.app   │  (LSUIElement, UI client)     │
                       │   ├─ Sparkle (updates the .app, and brokers       │
                       │   │   helper updates — §6.5)                       │
                       │   ├─ Menu bar + Settings + Onboarding (UI only)   │
                       │   ├─ SMAppService: registers the helper + login   │
                       │   └─ Permission prompts (TCC consent UI) — §6.2   │
                       └────────────────────────────────────────────────┘
            quit / update / crash the .app  ⇒  helper + :9700 + sessions LIVE
```

### 4.2 Helper ownership

The helper (`com.kup.solutions.bridge-helper`, a working name) owns everything
the agent talks to:

- The `:9700` NIO listener and all its endpoints (`/mcp`, `/sse`, `/messages`,
  `/health`, `/jobs/<id>/run`).
- `ToolRouter`, `SecurityGate`, `AuditLog`, and **all tool modules**.
- The session table.
- `BridgeCloudManager` + the cloudflared tunnel (when cloud access is enabled).
- The `bg_process_*` runtime and its orphan-reconciliation (already designed to
  survive force-quit via on-disk `meta.json` — see `docs/mcp-transport-and-bg-process.md`).

This is, almost exactly, **`ServerManager` as it exists today**, lifted out of the
app process. The module registry, transport router, and SSE server are already
structured as standalone components with no hard dependency on `NSApplication`
beyond a handful of MainActor callbacks (tool-call counters, client
connect/disconnect for the menu-bar UI). Those callbacks become IPC notifications
to the UI (§4.5) rather than direct `MainActor.run` calls.

### 4.3 The `.app` becomes a UI client

The `.app` keeps only what *needs a GUI*:

- Menu-bar item + popover (`StatusBarController`, `DashboardView`).
- Settings window, Onboarding, Permissions page, Credentials page.
- Sparkle update surface (and helper-update brokering, §6.5).
- TCC permission **prompts** — but see §6.2: the grant must attach to the helper,
  not (only) the app.

It talks to the helper over a **control channel** (XPC or loopback HTTP — §4.5).
The menu-bar "running / N clients / M tool calls / uptime" data is **pulled from
the helper** rather than maintained in-process. `/health` already returns
`{status, tools, uptime, version, clients, httpClients}` — the UI can poll it (or
subscribe over XPC) without any new server surface.

### 4.4 Session continuity across UI restart (the core win)

Because the helper process **does not exit** when the `.app` quits or updates, the
session table simply stays in memory. The client's `Mcp-Session-Id` keeps
resolving. No `404`, no re-handshake, no `ToolSearch` reload. **This is the
primary deliverable** and it requires **zero** session persistence — it falls out
of the process split for free.

Session continuity across a **helper** restart (crash/upgrade) is a separate,
optional layer (§7-R7). The minimum viable design does *not* persist sessions; it
relies on the helper being long-lived and launchd `KeepAlive` for crash recovery.
If we later want sessions to survive a helper upgrade, we add a serialize-on-
`SIGTERM` / rehydrate-on-launch step (the session table is small: id + client name
+ timestamps + subscriber set; the `StatefulHTTPServerTransport` per-session state
is the harder part and may force "graceful drain" instead — see §6.5).

### 4.5 UI ↔ helper control channel

Two viable mechanisms; the design recommends **XPC** for control with a
**loopback-HTTP fallback** for status, because the MCP data plane is *already*
loopback HTTP.

| Concern | XPC (`NSXPCConnection` + `SMAppService` daemon) | Loopback HTTP (extend `:9700`) |
| --- | --- | --- |
| Auth | Kernel-enforced peer codesign check (`setCodeSigningRequirement`) — only our signed `.app` can call control verbs | Must add a bearer/secret; loopback is local but any local process can hit `127.0.0.1:9700` |
| Surface | New, typed, control-only protocol (start/stop tunnel, get status, push config, broker update) | Reuses NIO listener; add `/control/*` routes behind auth |
| Fit | Idiomatic macOS daemon↔app pattern; pairs with `SMAppService.daemon` | Zero new transport; but blurs data plane and control plane |
| Risk | More moving parts (mach service name, launchd plist, code-sign requirement string) | Control verbs on the same port the agent uses — bigger blast radius if auth is weak |

**Recommendation:** control verbs over **XPC** with a hard code-signing
requirement (only the matching Team ID + bundle id may invoke), and keep the MCP
data plane on `:9700` exactly as today. Status/telemetry the UI needs can come
from the existing `/health` JSON (read-only, already loopback) to avoid widening
the control surface.

### 4.6 Helper packaging & registration

Use **`SMAppService`** (already a dependency — `AppDelegate.swift:18`,
`registerAutoLaunch()`). Today it registers the *main app* as a login item
(`SMAppService.mainApp`). The decoupled design adds a **daemon/agent**
registration:

- `SMAppService.daemon(plistName:)` for a system-wide LaunchDaemon, **or**
- `SMAppService.agent(plistName:)` for a per-user LaunchAgent.

**Recommendation: a per-user LaunchAgent**, not a system daemon. Rationale:

- The Bridge's tools act **as the user** (their Notion token, their Messages,
  their Contacts, their Keychain). A per-user agent runs in the user's GUI session
  with the user's TCC context — which is exactly what the tools need (§6.2).
- A LaunchDaemon runs as root pre-login and **cannot** hold per-user TCC grants
  for Automation/Contacts/etc., so it would break the very tools we're protecting.
- The Jobs infra **already** uses per-user LaunchAgents (`AppDelegate.swift:223`),
  so this is consistent with the existing model.

The agent's plist embeds `ProgramArguments = [<helper-binary>]` (the helper lives
inside the `.app` bundle, e.g. `Contents/MacOS/bridge-helper`, mirroring how
`NBJobRunner` is embedded at `Contents/MacOS/NBJobRunner`), `KeepAlive = true`,
and `RunAtLoad = true`. `SMAppService.agent` reads a bundled plist from
`Contents/Library/LaunchAgents/`.

---

## 5. Process lifecycle & ownership

### 5.1 Startup ordering

1. **Login / app launch.** The `.app` (or its login item) launches.
2. **App ensures helper is registered + running.** On `applicationDidFinishLaunching`,
   the app calls `SMAppService.agent(...).register()` (idempotent; replaces the
   current `registerAutoLaunch()` main-app registration, which the helper now
   subsumes for "is The Bridge running"). launchd starts the helper if not already
   up (`RunAtLoad`).
3. **Helper binds `:9700` and registers all tools** — i.e. runs today's
   `ServerManager.setup()` + `runSSE()`, minus the GUI callbacks.
4. **App connects to the helper** over XPC for control/status, and shows the menu
   bar reflecting helper state pulled from `/health`.

The single-instance guard (`ensureSingleInstance()`) moves to the **helper** (only
one helper may bind `:9700`). The app may have its own lighter guard, but it is no
longer the thing that owns the port.

### 5.2 Steady state

- Helper: long-lived, launchd-supervised, owns `:9700` + sessions + tunnel.
- App: present when the user is logged in and wants the menu bar; may be quit by
  the user at will. Quitting the app does **not** stop the helper.

### 5.3 Shutdown / restart matrix

| Event | Today | Decoupled |
| --- | --- | --- |
| User quits the menu-bar app | sessions die (`stopSSE`) | **sessions live** (helper untouched) |
| `make install` (dev) | sessions die | UI swapped; **helper kept** if helper unchanged (§6.5) |
| Sparkle updates the **UI** | sessions die | **sessions live** |
| Sparkle updates the **helper** | n/a | controlled drain/handoff (§6.5) |
| App crash | sessions die | **sessions live** (helper independent) |
| Helper crash | n/a | launchd respawns; sessions lost unless persisted (§7-R7) |
| Logout / shutdown | sessions die | sessions die (expected) |
| Toggle remote-access config | `invalidateAllSessions` (intentional) | unchanged (still intentional) |

### 5.4 stdio transport in a two-process world

stdio matters for clients that spawn the binary directly (`.mcp.json`
`type: stdio`). Two options:

- **(a) Thin stdio shim.** The binary the client spawns is a tiny shim that proxies
  stdio JSON-RPC to the helper's `:9700` `/mcp` (or to the XPC control channel).
  This preserves stdio for those clients *and* gives them session survival, because
  the real server is the helper. (`scripts/claude_mcp_http_proxy.py` is prior art
  for an stdio↔HTTP proxy.)
- **(b) Keep an in-helper stdio listener** for a single attached stdio client, as
  today (`ServerManager.run()`), accepting that a directly-spawned stdio client's
  lifetime is its own pipe's lifetime.

**Recommendation:** (a) the thin shim, so *every* client benefits from the helper's
longevity, and stdio is no longer a second, separately-lived server path.

### 5.5 Job callback path (NBJobRunner) — unchanged

`NBJobRunner` POSTs to `http://127.0.0.1:$NB_SSE_PORT/jobs/<id>/run`. In the
decoupled world that endpoint is served by the **helper** instead of the app —
which is *strictly better*, because scheduled jobs no longer require the menu-bar
app to be running. This removes a latent failure mode (a job firing while the app
is quit) for free.

---

## 6. Migration path

The migration is a **lift**, not a rewrite. `ServerManager` and its modules are
already a self-contained server; the work is (1) giving the helper a `main`, (2)
replacing the app-owned `serverTask` with helper-owned ownership, (3) converting
the MainActor UI callbacks into IPC, and (4) wiring registration + updates.

### 6.1 Carve out a helper executable

Add a new SPM product `bridge-helper` (mirrors how `NBJobRunner` and
`NotificationContentExtension` are separate `--product` builds in the Makefile).
Its `main`:

- Constructs `ServerManager` (no `onToolCall`/`onClientConnected` MainActor
  closures — those become XPC notifications, or no-ops if the UI isn't attached).
- Runs `setup()` + `runSSE()` (+ optional stdio).
- Hosts the XPC control listener.
- Installs the existing SIGTERM/SIGABRT crash-flush handlers
  (`AppDelegate.swift:446`) so log flushing on termination is preserved.

Most of `ServerManager` moves verbatim. The MainActor coupling is small and
already isolated behind closures.

### 6.2 TCC grant inheritance (the make-or-break detail)

This is the single highest-risk migration item and deserves a dedicated spike.

- macOS attributes TCC grants (Automation/Apple Events, Contacts, Calendar,
  Reminders, Screen Recording, Accessibility) to a **code identity** (designated
  requirement / bundle id), *and* to the process that actually performs the
  protected operation.
- Today the **app** process performs those operations in-process (e.g.
  `AppleScriptModule` runs Apple Events in-process specifically to avoid a TCC
  prompt storm — `ServerManager.swift:11`). After decoupling, the **helper**
  performs them. **The helper is a different executable**, so its grants are *not*
  automatically the app's grants.
- A per-user **LaunchAgent** (§4.6) is the right substrate: it runs in the user's
  GUI login session, so it *can* hold per-user TCC grants and *can* surface consent
  prompts (a LaunchDaemon running as root cannot). But the helper will likely need
  its **own** first-grant flow.
- The bundle id strategy matters. Options:
  - **Same bundle id, sub-identity:** keep `kup.solutions.notion-bridge` and ship
    the helper with a designated requirement that ties it to the same Team ID; TCC
    may still treat distinct executables distinctly.
  - **Dedicated helper bundle id** (e.g. `kup.solutions.notion-bridge.helper`):
    cleaner code identity, but means a *second* set of TCC grants the user must
    approve. The Permissions page (`PermissionManager`) must then drive consent for
    the **helper's** identity, and the entitlement `Usage Description` strings
    (`Info.plist` `NS*UsageDescription`) must be present in the **helper's**
    Info.plist too, or `requestFullAccess*` denies instantly (exactly the
    2026-06-03 `NSRemindersFullAccessUsageDescription` / `NSCalendarsFullAccessUsageDescription`
    bug in `AGENT_FEEDBACK.md`).

**Required spike (pre-implementation):** build a signed helper, register it as a
LaunchAgent, and empirically confirm which TCC categories prompt, which inherit,
and whether a user who already granted the app must re-grant the helper. The
existing live-QA discipline ("declare the entitlement but verify notarize+launch+
prompt on device" — see the calendars-entitlement note in
`NotionBridge.entitlements`) is mandatory here. Do **not** assume inheritance.

### 6.3 Auth between UI and helper

- XPC control channel: enforce a code-signing requirement so only our signed
  `.app` (Team ID `VP24Z9CS22`, matching bundle id) may invoke control verbs.
- `:9700` data plane: unchanged — loopback-only bind (`127.0.0.1`), CORS already
  removed (`SSETransport.swift:1404`), SecurityGate unchanged, connector bearer
  auth unchanged (still gated by `BRIDGE_ENABLE_HTTP`, default off).
- New consideration: because the helper now runs **without** a foreground app, any
  SecurityGate flow that depends on a **user-visible notification/prompt** must
  still be deliverable. The SecurityGate already requests notification permission
  (`ServerManager.requestSecurityNotificationPermission`); confirm that a
  LaunchAgent-hosted helper can post `UNUserNotification` approvals (it runs in the
  user session, so it should — but verify, given the 2026-06-02 Reminders
  "headless NotionBridge can't surface a consent prompt" finding).

### 6.4 Config & state migration

- `ConfigManager` / `BridgeDefaults` (UserDefaults) and Application Support paths
  must resolve to the **same** locations from the helper as from the app. With a
  per-user LaunchAgent both run as the same user, so `~/Library/...` resolves
  identically. Confirm the suite name / `UserDefaults` domain is shared (the app
  and helper read/write the same defaults domain) so a Settings toggle in the app
  reaches the helper. If they don't share a domain, the toggle goes over the XPC
  control channel instead.
- `PathMigration.runOnce` (`AppDelegate.swift:189`) must run **once**, owned by
  whichever process is authoritative (recommend: the helper, since it starts first
  and lives longest).

### 6.5 Sparkle / update flow (the second-hardest detail)

Goal: update the UI **without** killing sessions (easy once decoupled), and update
the **helper** with the least possible session disruption.

- **UI-only update:** Sparkle replaces `The Bridge.app`. Because the helper is a
  separate launchd-managed binary, an app update does **not** restart the helper.
  Sessions survive. The pre-install Sparkle-staging guard in the Makefile still
  applies to the app bundle only.
- **Helper update:** the helper binary ships *inside* the `.app` bundle
  (`Contents/MacOS/bridge-helper`), so a Sparkle app update *also* delivers a new
  helper binary on disk — but launchd is still running the **old** helper. Options:
  1. **Lazy upgrade:** new helper binary lands on disk; the running (old) helper
     keeps serving existing sessions until it next restarts (crash, logout, or an
     explicit operator "apply update"). Simple; sessions survive the app update;
     the helper upgrade happens on the next natural restart.
  2. **Graceful drain handoff:** the app (post-update) asks the old helper over XPC
     to *stop accepting new sessions*, lets existing sessions idle out (or persist
     them — §7-R7), then `SMAppService` re-registers and launchd respawns the new
     helper. More complex; only needed if we want the *helper* to upgrade promptly
     without waiting for a natural restart.
  - **Versioning:** the helper and UI ship from the same build, so they share a
    version. The XPC protocol must be **version-negotiated** so a newer UI can talk
    to an older still-running helper during the window between app-update and
    helper-restart (lazy upgrade). Keep the control protocol additive and
    backward-compatible.

**Recommendation:** ship **(1) lazy upgrade** in v1 of the decoupled design — it
delivers the core win (UI updates never kill sessions) with minimal complexity.
Add (2) graceful drain only if operators report stale-helper friction. Either way,
this directly removes the per-install reconnect tax for the dominant case (the
hourly Sparkle UI update).

### 6.6 Backward compatibility / rollback

- The `.mcp.json` registration shape (the URL/command clients use to reach The
  Bridge) must remain stable. If clients point at `http://127.0.0.1:9700/mcp`, that
  endpoint is now served by the helper at the same address — **no client change
  needed**. If clients spawn a stdio binary, the thin shim (§5.4) preserves that.
- Rollback: because the helper *is* today's `ServerManager`, a feature flag
  (`BRIDGE_DECOUPLED=1`) can select between "app hosts server" (today) and "helper
  hosts server" (new) during rollout. If decoupling misbehaves, flip the flag and
  the app re-hosts the server in-process. (See §8.)

---

## 7. Risks

| # | Risk | Severity | Mitigation |
| --- | --- | --- | --- |
| R1 | **TCC grants don't inherit** to the helper; tools that need Automation/Contacts/Calendar/Reminders/Screen/AX break or re-prompt | **High** | Dedicated empirical spike (§6.2); per-user LaunchAgent (not daemon) so the helper runs in the user TCC context; ensure all `NS*UsageDescription` strings exist in the helper Info.plist; drive consent from the Permissions page for the helper's identity |
| R2 | **Codesigning/notarization of a second binary** — a Developer-ID app outside the App Store has *no embedded provisioning profile*; an entitlement the notarization refuses makes launchd **reject the binary at spawn** (POSIX 163 "Launchd job spawn failed") even when codesign+notarize+Gatekeeper pass | **High** | This already bit The Bridge **twice** (`NotionBridge.entitlements`: keychain-access-groups removed 2026-05-30; calendars entitlement live-QA gate). Sign the helper with the same Developer-ID identity + hardened runtime; give it the **minimum** entitlements it needs; **build+sign+notarize+launch the helper on device before shipping**; have a documented fallback (drop the offending entitlement) |
| R3 | **Security/auth on the control channel** — a malicious local process could drive control verbs (start tunnel, change config) if auth is weak | High | XPC with a hard code-signing requirement (Team ID + bundle id); keep control verbs *off* the `:9700` data plane; data plane stays loopback-only + CORS-off + SecurityGate intact |
| R4 | **SecurityGate prompts undeliverable from a headless helper** — approval notifications might not surface without a foreground app | Medium | Per-user LaunchAgent runs in the GUI session and can post `UNUserNotification`; verify on device (the 2026-06-02 Reminders finding shows headless consent is *not* guaranteed); the UI app can also broker prompts over XPC when present |
| R5 | **Two-process state divergence** — Settings toggle in the app doesn't reach the helper (separate UserDefaults domains / stale config) | Medium | Share the UserDefaults suite, or push every config change over the XPC control channel; single owner for `PathMigration` |
| R6 | **Sparkle helper-update window** — new UI talks to old helper (or vice versa) | Medium | Version-negotiated, additive XPC protocol; lazy-upgrade default (§6.5); helper+UI ship from the same build |
| R7 | **Session loss on helper crash/upgrade** — a helper restart still drops sessions (the core win only covers *UI* restarts) | Medium | launchd `KeepAlive` for fast respawn; the *primary* deliverable (UI-restart survival) needs no persistence; if helper-restart survival is wanted later, serialize the session table on SIGTERM and rehydrate on launch — note `StatefulHTTPServerTransport` per-session internals are the hard part and may force graceful-drain instead |
| R8 | **Single-instance / port-bind races** — both old and new helper, or app + helper, try to bind `:9700` | Medium | Move the single-instance guard + port ownership to the helper; the app never binds `:9700`; `SSEServer.start()` already fails bind gracefully (`AppDelegate.swift:589`) |
| R9 | **Orphaned helper** — user uninstalls the app but the LaunchAgent keeps running | Low/Med | App uninstall / "disable" path must `SMAppService.agent(...).unregister()`; document an uninstall recipe (mirror the `make install` cleanup discipline) |
| R10 | **`bg_process_*` + tunnel double-ownership** during the flag-gated rollout (both app and helper try to own them) | Medium | The `BRIDGE_DECOUPLED` flag must be mutually exclusive — exactly one process owns `ServerManager` at a time; orphan reconciliation (`reconcileOrphans`) already handles dead-pid jobs |
| R11 | **App Store path foreclosed / Gatekeeper friction** — a bundled LaunchAgent + helper changes the notarization payload | Low | Already Developer-ID-only (not MAS); notarize the whole `.app` (helper embedded) as one submission, as today; re-verify `spctl --assess` post-install |

---

## 8. Incremental rollout plan

Each phase is independently shippable, flag-gated, and reversible. No phase removes
the in-app server path until the helper path is proven on device.

**Phase 0 — Spikes (no shipped behavior change).**
- 0a. **TCC inheritance spike (R1, R2):** build a throwaway signed helper, register
  it as a per-user LaunchAgent, and empirically map which TCC categories prompt /
  inherit / require re-grant. Confirm notarize+launch with the candidate
  entitlement set (avoid the POSIX-163 trap). *Gate: results documented before any
  production code.*
- 0b. **XPC control-channel spike (R3):** prove app↔helper XPC with a code-signing
  requirement; confirm only the signed app can invoke control verbs.

**Phase 1 — Extract the helper, behind a default-OFF flag.**
- New `bridge-helper` SPM product = today's `ServerManager` with a `main`.
- `BRIDGE_DECOUPLED=0` (default): app hosts the server exactly as today —
  **byte-for-byte unchanged**, test floor unchanged. `=1`: app registers + starts
  the helper, the helper owns `:9700`, the app becomes a UI client.
- Validate: with the flag on, an app quit/relaunch leaves a live session
  connected (the core win) on the developer's machine.

**Phase 2 — UI callbacks → IPC; status from `/health`.**
- Replace `onToolCall` / `onClientConnected` MainActor closures with XPC
  notifications (or drop them when no UI is attached).
- Menu-bar UI reads helper state from `/health` (and/or XPC), not in-process
  counters.

**Phase 3 — Update flow.**
- Sparkle UI-only update verified to **not** kill sessions (G2).
- Lazy helper-upgrade (§6.5 option 1) implemented + version-negotiated XPC.
- Update `make install` / uninstall recipes for the helper (register/unregister,
  pre-install drain).

**Phase 4 — stdio shim + job-callback move.**
- Ship the thin stdio shim (§5.4a) so directly-spawned stdio clients also get
  session survival.
- Confirm `NBJobRunner`'s `/jobs/<id>/run` is served by the helper and jobs fire
  even when the app is quit (§5.5).

**Phase 5 — Default-ON + cleanup.**
- Flip `BRIDGE_DECOUPLED=1` as the default after on-device soak (operator-gated,
  per the release policy — this spike does **not** authorize the flip).
- Optionally remove the in-app server path once the helper path has shipped
  cleanly for one or more releases (keep the flag as a kill-switch through the
  transition).

**Stretch (post-rollout):** session persistence across helper restart (R7);
graceful-drain helper handoff (§6.5 option 2); per-job resource caps already
backlogged in `docs/mcp-transport-and-bg-process.md`.

---

## 9. Open questions (for the implementing packet)

1. **Bundle id for the helper** — same id with a designated-requirement sub-identity,
   or a dedicated `…notion-bridge.helper` id? Decides the TCC re-grant story (§6.2).
2. **Session persistence in v1?** The core win needs none; do we want helper-restart
   survival in the first cut or defer to the stretch phase (R7)?
3. **Control channel: XPC vs loopback-HTTP** — recommendation is XPC; confirm
   `SMAppService.agent` + mach-service registration is acceptable operationally.
4. **stdio strategy** — thin shim (recommended) vs in-helper stdio listener (§5.4).
5. **Helper-update promptness** — lazy upgrade (recommended) vs graceful drain
   (§6.5); does operator workflow tolerate a stale helper until next natural restart?
6. **Does a LaunchAgent-hosted helper reliably surface SecurityGate `UNUserNotification`
   approvals?** (R4 — empirical, on device.)

---

## 10. Summary

The session-death cluster in `AGENT_FEEDBACK.md` (2026-05-16, -05-20, -05-22,
-05-30/FB-4) all trace to a single architectural fact: **the app process owns the
MCP server, so the server's lifetime is the app's lifetime.** Splitting the
process — a launchd-managed per-user **helper** that owns `:9700` + sessions +
modules + tunnel, and a thin **`.app`** UI client — makes live sessions survive UI
restarts and self-updates (collapsing clusters A + C and removing the per-install
reconnect tax) with **no session persistence required** for the primary win.

The architecture is not speculative for The Bridge: it already ships a signed
Developer-ID helper (`NBJobRunner`), already drives `:9700` from launchd, and
already runs the Jobs infra as per-user LaunchAgents. The real risks are
**operational, not architectural** — TCC grant inheritance across two binaries
(R1) and the Developer-ID notarize/launch entitlement trap (R2, which has already
bitten this codebase twice). Both are addressable with the on-device live-QA
discipline the project already practices, and the rollout is fully flag-gated and
reversible.

**This is a spike to inform a future packet. Do not implement from this document
alone — Phase 0 spikes (TCC + XPC) gate everything that follows.**
