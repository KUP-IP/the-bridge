# MCP Transport & Background Jobs

**Status:** Current public background-job contract.

---

## TL;DR

- Use `shell_exec` only for short, synchronous commands that can return
  within the MCP client's response window.
- For a build, test suite, migration, watcher, or any command of uncertain
  duration, start it with `bg_run`, then observe the same `jobId` with
  `bg_poll`.
- Some eligible Bridge tools also return a background `jobId`; observe or
  cancel that exact ID with the same `bg_poll` / `bg_kill` pair.
- Use `bg_kill` only to stop an active job. It is safe to call on an
  already-terminal job.

The durable shape is a short start call followed by short polling calls; do
not rely on a trailing `&` in `shell_exec` to outlive the caller.

## Why this exists

An MCP host may end an awaited tool call before a long-running child process
has completed, regardless of the server-side shell timeout. Background work
therefore needs a handle that can be checked by later, independent calls.

`bg_run` starts a detached shell child, captures combined stdout/stderr in
Bridge application support, and returns immediately. `bg_poll` reads the
bounded trailing output and derives current state from the job's file-backed
records and process liveness.

Eligible module tools may instead use Bridge's managed background runtime and
return its `jobId`. The public poll and cancellation tools support that handoff
too. Such replies explicitly include `provider:"runtime"`; the runtime keeps
stdout and stderr as separate durable files, so its convenience `tail` is
labeled as per-stream snapshots rather than a fabricated chronological merge.

## Decision rule

| Workload shape | Use | Notes |
| --- | --- | --- |
| Small, predictable command that returns within the client response window | `shell_exec` | Use a bounded timeout and concise output. |
| Build, test suite, migration, watcher, or unknown duration | `bg_run` → `bg_poll` | Default whenever duration is uncertain. |
| Need recent combined output | `bg_poll` | Set `tailLines`; legacy `bg_run` output is combined, while runtime-backed replies identify separate stream tails. |
| Need to stop live work | `bg_kill` | Use the exact `jobId` returned by `bg_run` or an eligible module tool. |

## Public surface

| Tool | Tier | Contract |
| --- | --- | --- |
| `bg_run` | request | Starts a detached shell command. Returns `jobId`, `pid`, `logPath`, `donePath`, and `status:"started"`. Accepts `command`, optional `workingDir`, `env`, `loginShell`, `label`, and `ownerSession`. |
| `bg_poll` | open | Reads one job by `jobId`. Returns `running`, `exited`, `terminated`, or `not_found`, plus a bounded output `tail`; a completed job includes `exitCode` and `success`. Runtime-backed replies add `provider:"runtime"`, `stdoutPath`, and `stderrPath`. |
| `bg_kill` | notify | Sends SIGTERM by default (or SIGKILL with `force:true`) to one job. A completed job returns `already_exited`; runtime-backed replies identify `provider:"runtime"`. |

Job IDs are validated before filesystem access. The public contract is
intentionally per-job: there is no public background-job list or separately
paginated log endpoint.

## Typical loop

1. Call `bg_run`, or retain a background `jobId` returned by an eligible
   Bridge tool.
2. Call `bg_poll` with that `jobId` until the `status` is not
   `running`.
3. Treat `status:"exited"` and `success:true` as completion. Inspect
   `tail` and `exitCode` for any other terminal outcome.
4. If cancellation is needed before terminal state, call `bg_kill` with the
   same `jobId`, then poll again for the final observed result.

## Anti-patterns

- Do not start a long command with `shell_exec` plus a trailing `&`; the
  caller still owns a short-lived request and loses durable observability.
- Do not invent a file-path poller. Pass the returned `jobId` to
  `bg_poll`, which validates the ID and bounds returned output.
- Do not claim a background job succeeded merely because its launch call
  returned a `jobId` or `status:"started"`; only a terminal `bg_poll`
  response proves the observed outcome.

## References

- `TheBridge/Modules/BgProcessModule.swift` — public tool handlers and
  file-backed job contract.
- `TheBridgeTests/BgProcessModuleTests.swift` — hermetic round-trip coverage.
