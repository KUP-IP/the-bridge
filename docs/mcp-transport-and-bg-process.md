# MCP Transport & `bg_process_*` Funnel

**Status:** v2.2 — Canonical. PKT-748 (decision spike + this doc) supersedes the W29 `nohup ... > /tmp/log 2>&1 & disown` workaround.

---

## TL;DR

- `shell_exec` is for **short, synchronous** commands that return within the MCP client's per-call response window. Treat the budget as **~30 s wall-clock**, conservatively.
- For anything longer (builds, test suites, dev servers, LSP indexing, Playwright, batch migrations, the Cursor SDK Node sidecar, etc.) use **`bg_process_*`**:
  - `bg_process_start` returns a job id immediately (< 1 s).
  - Poll `bg_process_status` / `bg_process_logs` on subsequent short calls.
- The W29 `nohup … > /tmp/log 2>&1 & disown` pattern is **retired**. The only legitimate residual is MAC Keepr's self-update procedure (which must outlive the agent process by construction).

## Why this exists

The ~60–75 s ceiling that forced the W29 nohup workaround **is not a Bridge constraint**. PKT-748's decision spike inspected the transport source directly:

| Layer | Setting | Source |
| --- | --- | --- |
| SSE session lifetime | `SSEServer(sessionTimeout: 300, sessionCleanupInterval: 30)` (normalized to `max(30, sessionTimeout)`; cleanup only evicts on `now - lastAccessedAt > sessionTimeout`) | `NotionBridge/Server/SSETransport.swift` |
| `shell_exec` synchronous timeout | `timeout = 600` s default (10 min) | `NotionBridge/Modules/ShellModule.swift` |
| `shell_exec` background (`&`) cap | 5 s by design | `ShellModule.swift` |

The ceiling fires on the **MCP client's** awaited response to a single in-flight `tools/call` (Claude Code / Cursor / Notion AI tool runner all enforce some flavor of this). Therefore:

- **No amount of server-side chunked-SSE long-polling on `shell_exec`** lifts the ceiling — the cap is upstream of any stream the Bridge emits.
- The fix is **shape**, not transport. Convert the workload into a short call that returns a job handle, then poll on subsequent short calls.

## Decision rule

| Workload shape | Use | Notes |
| --- | --- | --- |
| Returns < ~30 s, single output blob | `shell_exec` | The 600 s server-side budget is mostly moot — the client cap governs in practice. |
| Returns > ~30 s, or unknown duration | `bg_process_start` + poll | Default here when you can't predict wall-clock. |
| Process must outlive a single tool call | `bg_process_start` | e.g. dev servers, LSP daemons, the Cursor SDK Node sidecar. |
| Need streamed logs as they accumulate | `bg_process_logs` | Byte-cursor pagination; safe under high write rate. |
| Need to terminate | `bg_process_kill` | SIGTERM → 5 s grace → SIGKILL. |
| Audit / orphan reconciliation | `bg_process_list` | Filter by status (`running` / `done` / `failed` / `killed` / `unknown`) or label. |

If you can't predict the wall-clock, **default to `bg_process_*`**. The funnel costs one extra short call to start and removes the timeout class entirely.

## Public surface (frozen since PKT-744)

- **Tools** (module `dev`, tier `.request`): `bg_process_start` · `bg_process_status` · `bg_process_logs` · `bg_process_kill` · `bg_process_list`.
- **Job dir:** `~/Library/Application Support/NotionBridge/jobs/<id>/{stdout,stderr,meta.json}`.
- **Job id format:** `yyyyMMdd-HHmmss-<8hex>`.
- **State machine:** `running → {done | failed | killed | unknown}` (`unknown` is the orphan-reconcile terminal state).
- **`meta.json` schema:** `id, pid, pgid, command, workingDir?, label?, startedAt, endedAt?, exitCode?, status, killSignal?, lastReconcileAt?, note?`.
- **Atomicity:** `meta.json` writes use `FileManager.replaceItemAt` (POSIX rename) with `Data.write(.atomic)` fallback.
- **Log writers** use `O_APPEND` on the spawned child's stdout/stderr fds passed to `posix_spawn` — no app-side coordination needed at any write rate.
- **POSIX process group:** `pgid == pid` via `POSIX_SPAWN_SETPGROUP` with `pgrp = 0`. `kill(-pgid, sig)` delivers `killpg` semantics, so the kill cascade reliably reaps the full subtree.
- **Crash recovery:** `BgProcessRuntime.shared.reconcileOrphans()` runs on every Bridge launch (registered in `ServerManager.start()`). `bg_process_list` reflects truth after a force-quit.
- **Cleanup:** terminal jobs purged after 7 days (configurable on the `BgProcessRuntime` actor: `cleanupTTL`).
- **Capability surface:** `capability_missing` if `posix_spawn` / Application Support dir unavailable.

See `NotionBridge/Modules/BgProcessRuntime.swift` and `BgProcessModule.swift` for the implementation, and `NotionBridgeTests/BgProcessModuleTests.swift` for the 16 hermetic tests covering each state-machine path.

## Anti-patterns (retired in v2.2)

- ❌ `shell_exec` with `command: "nohup long_running_thing > /tmp/log 2>&1 & disown"` — relied on the 5-s background cap completing the synchronous return before the work finishes. Unstable: depends on FS flush ordering, the client's grace handling, and produces orphaned processes the Bridge can't track. **Replace with `bg_process_start`.**
- ❌ `shell_exec` with `timeout: 600` for a 4-minute test suite — still subject to the **client-side** per-call ceiling; the server-side 600 s is moot. **Replace with `bg_process_start`.**
- ❌ Polling a custom file path you wrote yourself instead of `bg_process_status`. The runtime already provides atomic status + orphan reconciliation; rolling your own re-introduces the race conditions PKT-744 closed.

## Future considerations (v2.3 backlog)

- **Chunked-SSE long-poll on `shell_exec`.** Reconsidered only if a future MCP client raises its per-call response deadline materially above the `bg_process_*` polling cadence, or if a server-streamed tool output channel becomes necessary for non-job-shaped work. Not on the v2.2 / v2.3 critical path; `bg_process_*` covers every known long-running workload (devserver supervision, LSP, runners, Cursor SDK Node sidecar — see the PKT-744 downstream invariants).
- **Per-job resource caps (CPU / RAM).** Explicitly out of scope for v2.2 per PKT-744 §Scope.OUT. Re-evaluated in v2.3 alongside any sandboxing work.

## References

- **PKT-744** (v2.2 · 1.1) — `bg_process_*` runtime + tests. Public surface frozen here.
- **PKT-748** (v2.2 · 4.1) — this decision spike + governance (no transport code change).
- **W29 packet retro** — original surface of the ceiling this work resolves.
