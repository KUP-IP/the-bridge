# MCP Session Durability Across Restart / Install

**Item:** `session` — MCP session durability across restart/install
**Status:** partial (contained safe slice shipped; transparent transport
resume + harness-side re-initialize deferred — see "Deferred / External asks")
**Date:** 2026-06-04

## Problem

The Bridge **hosts** the MCP server in-process (the menu-bar app *is* the
server — `ServerManager` + `SSEServer` run inside the `TheBridge` target).
So any app restart or `make install` tears down the in-memory session map
(`SSEServer.sessions`). A client that had a live Streamable-HTTP session and
keeps sending its prior `Mcp-Session-Id` then hit a hard:

```
HTTP 404  { "error": { "message": "Session not found or expired" } }
```

with no signal that this was a *recoverable* restart vs. a genuinely-bad id.
Clients (and the harness) had to manually reconnect.

Evidence dates: 05-16, 05-20, 05-22, 06-02, 06-04.

## What shipped (server-side slice)

### 1. Persist active session state to disk

New `SessionPersistenceStore` (actor, `TheBridge/Server/SessionPersistenceStore.swift`),
modelled on `SnippetStore`'s crash-safe posture:

- Single JSON document at
  `~/Library/Application Support/The Bridge/sessions/active-sessions.json`
  (via `BridgePaths.applicationSupport(.sessions)`, new subdir case).
- Each row (`PersistedSession`) carries **minimal context only**: session id,
  client name/version, transport, negotiated protocol version, created/
  last-accessed timestamps. **Never** tool arguments, bearer material, or
  transport buffers.
- Writes are `Data.write(options: .atomic)` (temp-write + atomic rename), so a
  `kill -9` mid-write (force-quit / installer binary-swap) cannot leave a torn
  file. A corrupt file is moved aside (`.corrupt-<ts>`) and the store recovers
  to empty rather than blocking startup.

Wired into `SSEServer` (Streamable-HTTP path):
- `createSession` → `upsert`
- live request → `touch` (refresh last-accessed)
- per-session teardown (DELETE / expiry / eviction) → `remove`

### 2. Clean-shutdown marker + flush

On a **graceful** stop (`SSEServer.stop()` ← `applicationWillTerminate`):
- live transports are torn down with `preservePersistence: true` so the durable
  rows are **kept** (the sessions are being *suspended* by a host restart, not
  *closed* by the client),
- a `ShutdownMarker { date, reason, cleanlyEnded: true, activeSessionsAtShutdown }`
  is written + flushed,
- a `dirtyRun` flag (set on the first session write of a run, cleared by the
  clean marker) lets the next launch distinguish a planned restart from a crash.

Because `applicationWillTerminate` is synchronous and cannot reliably `await`
the async `stop()` Task before the process exits (same constraint as the
existing `LogManager.flush()`), the AppDelegate also calls the **synchronous**
`SessionPersistenceStore.recordCleanShutdownSync(reason:)` fallback. Both paths
are idempotent.

### 3. Resumable reconnect (no more opaque hard-404)

`processStreamableHTTP` now, before the opaque 404, consults
`sessionStore.resumeLookup(sessionID:)`:

- **`.unknown`** (id never persisted — forged / truly gone) → the existing
  hard-404 `"Session not found or expired"` (unchanged).
- **`.resumable`** (id persisted from a prior run; host restarted) →
  `SSEServer.resumableReconnectResponse(...)`: still a `404` per
  Streamable-HTTP resumability (the id is no longer *live*), but carrying a
  distinct, recoverable signal:
  - header `Mcp-Session-Resumable: true`,
  - header `Mcp-Prior-Session-Id: <id>` (echoed back for correlation),
  - a stable `[session_expired_resumable]` reason token in the JSON-RPC error
    message, with clean-vs-unclean phrasing ("host restarted" vs "host
    recovered from an unexpected stop") instructing the client to
    **re-initialize**.

`/health` gained `sessionsPersisted`, `sessionsResumeSignaled`, and
`priorRunEndedCleanly` so the durability path is observable.

## Tests

`TheBridgeTests/SessionPersistenceTests.swift` (+17, floor 1777 → 1794):
store round-trip + restart durability, idempotent upsert, remove/touch
durability, corrupt-file recovery, resume-lookup decision (unknown vs
resumable, clean vs unclean), clean-shutdown marker + dirty-run liveness, the
synchronous fallback preserving rows, and the pure `resumableReconnectResponse`
builder (status / headers / reason token / clean-vs-unclean phrasing / distinct
from the opaque hard-404).

## Deferred / External asks

1. **Transparent transport resume (server-side remainder).** Full resumability
   per the Streamable-HTTP spec — replaying the SDK's per-stream event log so an
   *in-flight* request survives a restart with no client round-trip — requires
   event-store support that the vendored `StatefulHTTPServerTransport`
   (swift-sdk) does not expose. The shipped slice instead returns a
   re-initialize signal (one cheap client round-trip). Closing this needs an SDK
   change (a persistable `EventStore` seam) or a fork; tracked as the remainder
   of this item.

2. **Harness-side automatic re-initialize (out of scope, external).** The
   client/harness must observe the `Mcp-Session-Resumable: true` header (or the
   `[session_expired_resumable]` reason token) on a 404 and transparently
   re-`initialize` instead of surfacing a hard failure. This is **client-side**
   and explicitly out of scope for the server item; documented here as the
   external ask so the two halves meet.

3. **Legacy split-SSE path.** The legacy `GET /sse` + `POST /messages` transport
   mints a fresh server-side session id on each new SSE stream connection (the
   client does not carry `Mcp-Session-Id` across reconnects), so the resume
   signal is correctly scoped to the Streamable-HTTP `/mcp` funnel. Legacy
   reconnect already re-establishes a fresh stream; no durability change was
   needed there, and the legacy hot path was deliberately left free of disk
   writes.
