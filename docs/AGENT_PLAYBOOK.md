# Agent Playbook — task → tool map

A concise map from "what you are trying to do" to "the Bridge MCP tool that already
does it." Many recurring frictions in `AGENT_FEEDBACK.md` are **discoverability gaps**:
the tool exists, but the agent reaches for `shell_exec` (or guesses a `/Users/...`
path) instead. This page exists so you reach for the right tool on the first try.

**Accuracy rule for this doc:** every tool listed below was confirmed to be registered
in the Swift source (grep `name: "<tool>"` under `TheBridge/Modules/`). Tools that do
**not** exist yet are called out explicitly in the [Not yet available](#not-yet-available)
section — do not assume them.

> All tool names are the bare MCP tool names. Depending on your host they may be
> prefixed (`mcp__Bridge_MCP__…`, `mcp__The_Bridge__…`). If a tool is deferred, load
> its schema with `ToolSearch` (`select:<name>`) before the first call — guessing the
> argument shape hard-errors (see `AGENT_FEEDBACK.md`, 2026-05-19).

---

## Quick reference

| Task | Reach for | Not |
|---|---|---|
| Build / test / migration / dev server (anything > shell's ~60s request window) | `bg_process_start` → `bg_process_status` / `bg_process_logs` → `bg_process_kill` | a foreground `shell_exec` that will time out |
| Surgical in-place file edit | `file_edit` (`mode:"replace"` or `mode:"patch"`) | `shell_exec` + `sed`/`python3` heredoc |
| Search source code | `code_search` (ripgrep, structured matches) | `shell_exec rg` for programmatic consumption |
| Ground `$HOME` / user / cwd before touching the filesystem | `system_info` | guessing `/Users/<name>` from an email |
| Open a Notion / http(s) URL on the operator Mac | `url_open` | `shell_exec open` (C0 `worktree_target_unresolved`) |
| Read specific columns from a Notion data source | `notion_query` with `properties` + `pageSize` | N follow-up reads to bucket by Status |
| Read one Notion page's prose | `notion_page_markdown_read` | paginating raw blocks yourself |
| Long-running shell work generally | `bg_process_*` | `cmd &` (still capped to the request window) |
| On-device Settings verification | manual AX raise + `screen_capture` (see [Not yet available](#not-yet-available)) | a dedicated settings-navigation tool — it does not exist yet |

---

## Builds, tests, and anything long-running → `bg_process_*`

`shell_exec` has a short server-side request window (~60s observed; see
`AGENT_FEEDBACK.md` 2026-05-10 / 2026-05-11). A trailing `&` does **not** help — the
background command is still capped to that window. For `swift build`, `make test`,
migrations, dev servers, or any work where you want to keep iterating while it runs,
use the background-process module:

- **`bg_process_start`** (`.request`) — spawns the command as a detached child in its
  own POSIX process group; returns a job `id` immediately. Optional `workingDir`,
  `env`, `label`. Stdout/stderr stream to
  `~/Library/Application Support/TheBridge/jobs/<id>/`.
- **`bg_process_status`** (`.request`) — `status`, `pid`, `pgid`, `exitCode`,
  `killSignal`, timestamps for one job `id`.
- **`bg_process_logs`** (`.request`) — paginated stdout/stderr chunk. Pass `cursor:0`
  (or omit) for the start; pass the returned `nextCursor` to continue. `eof:true` once
  the job is terminal and the cursor reached `totalBytes`.
- **`bg_process_list`** (`.request`) — enumerate jobs (filter by `label`).
- **`bg_process_kill`** (`.request`) — terminate a job by `id`.

Typical loop: `bg_process_start` the build → poll `bg_process_status` until terminal →
`bg_process_logs` to read the tail on failure.

Source: `TheBridge/Modules/BgProcessModule.swift`.

## Surgical file edits → `file_edit`

Do not shell out to `sed`/`python3` for in-place edits. Use the first-class edit verb:

- **`file_edit`** (`.notify`) — the canonical surgical edit tool.
  - `mode:"replace"` — literal search → replacement (rejects ambiguous multi-match
    unless you opt in; supports `preview` for a unified diff without writing).
  - `mode:"patch"` — apply a unified-diff patch to a single file; validates each hunk's
    context against current content and rejects on drift. Multi-file diffs must be split
    per file by the caller. Writes are atomic.

The removed `file_str_replace` and `file_apply_patch` aliases are historical only.
Use `file_edit` for surgical replacements and unified patches.

Source: `TheBridge/Modules/CodeEditModule.swift`.

## Code search → `code_search`

- **`code_search`** — ripgrep-backed; returns structured matches (`path`, `lineNumber`,
  `absoluteOffset`, `lineText`, `submatches` with column offsets) plus optional
  before/after context. Preferred over `shell_exec rg` when you will consume the matches
  programmatically. Returns `capability_missing` if ripgrep is not installed
  (`brew install ripgrep`).

Source: `TheBridge/Modules/CodeEditModule.swift`.

## Filesystem grounding → `system_info`

Do not infer `/Users/<name>` from the operator's email — the canonical home on this
machine is `/Users/keepup`, not `/Users/isaiah` (this exact mistake cost round-trips in
`AGENT_FEEDBACK.md` 2026-05-11). Instead:

- **`system_info`** (`.open`, no args) — returns `homeDirectory`, `userName`,
  `currentDirectory` (plus model, OS version, RAM, CPU, uptime). Use these values to
  build absolute paths.

File tools also expand a leading `~` (VERIFIED-FIXED 2026-05-30), so `~/Developer/...`
resolves correctly.

Source: `TheBridge/Modules/SystemModule.swift`.

## Open a live Notion / http(s) URL → `url_open`

Remote clients cannot `shell_exec open https://…` — C0 treats `open` as an
opaque executable (`worktree_target_unresolved`). That is intentional and is
**not** a lease to weaken. After a Notion write, open the returned URL with:

- **`url_open`** (`.notify`) — `url` must be an absolute `http`, `https`, or
  `notion` URL. Same effective behavior as AppleScript `open location`.
  Not worktree-gated. Rejects `file:` and other schemes.
- Fallback on an older host: `applescript_exec` with
  `open location "{url}"` (still Request-tier Automation).

Do not retry `shell_exec open`. File opens stay on `shell_exec` and remain
C0-gated. Operator map of worktree-gated vs AppleScript-legal tools:
`docs/operator/remote-url-open.md`. `run_script` stays always-unresolved
(C0 inventory).

Source: `TheBridge/Modules/URLOpen.swift` + `SystemModule.swift`.

## Long Notion reads → `notion_query` projection + `notion_page_markdown_read`

Large Notion results spill to disk and force `jq`/slice workarounds. Keep reads tight:

- **`notion_query`** (`.open`) — query a data source with Notion-API
  `filter`/`sorts`/cursor pagination. Two arguments that prevent the "N follow-up reads"
  anti-pattern:
  - `properties: [...]` — project specific column names into each result row, so you can
    bucket by Status/relations in one call instead of N status-filtered queries.
  - `pageSize` — cap result size (default 100). Use a small page for preflight probes.
  - `sorts` — server-side ordering (plumbed end-to-end; VERIFIED-FIXED 2026-05-30).
  - Run `notion_datasource_get` first to learn exact column names.
- **`notion_page_markdown_read`** — full prose for one page without paginating raw blocks
  yourself. Prefer this over `notion_page_read` when block structure is not needed.

Source: `TheBridge/Modules/NotionModule.swift`.

## Git diffs over a range → `git_diff`

- **`git_diff`** — accepts a `range` (single ref, `A..B`, `A...B`, or omitted for
  worktree-vs-index) and a `cwd`. The earlier `A...B`-range failure is VERIFIED-FIXED
  (2026-05-30): use the `range:` + `cwd:` arguments rather than shelling out.

Source: `TheBridge/Modules/GitModule.swift`.

---

## Availability notes

- **`swift_build` / `swift_test`** — a first-class build/test wrapper has been *requested*
  (`AGENT_FEEDBACK.md` 2026-05-10) but is intentionally replaced by the current
  `bg_run` → `bg_poll` → optional `bg_kill` surface for long builds and tests.
- **`bridge_settings_navigate(section)` / `bridge_open_settings` /
  `bridge_focus_settings` are registered.** Use the open/focus helpers before
  Settings screenshots; they verify the target app/window rather than reporting
  coordinate-only success.
- After changing branches across tool-surface commits, run **`make test-clean`**.
  After any install/relaunch, reconnect MCP clients so they re-run initialize and
  `tools/list`; an already-open client's descriptor cache is not live proof.

---

## Session wrap-up / Close

Session wrap-up is the **Close** command → skill **`close-agent`** only.
There is **no** skill named `ScaleFocusKeeper` (and no roster alias). If a prompt
asks to "fetch ScaleFocusKeeper," route to `close-agent` instead.

---

## See also

- GitHub Issues — the only actionable development-feedback ledger. Search before
  creating. AI LOG is telemetry. See `docs/operator/calibrate.md` and
  `docs/commands-github-first-b1.md`.
- `AGENTS.md` — build/test/install ladder, architecture, security tiers, MCP dispatch
  shape (`runTool({toolName, toolArguments})`).
