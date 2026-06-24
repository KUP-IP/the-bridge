# Maintenance Command — Telemetry Drain + PACKETS Status Reconcile

**PKT-987**
**Status:** Implemented
**Execution Class:** MANUAL (no auto-run; operator-invoked only)

---

## Purpose

A reusable maintenance command that:

1. **Drains pending sub-agent telemetry** from Bridge sessions into the AI LOGS Notion data source
2. **Reconciles PACKETS statuses** against live state (git, PRs, conversation evidence)

Run after any multi-agent sprint to keep the KEEP OS operation layer current.

---

## Command home

This file (`docs/operator/maintenance-command.md`) is the **canonical, committed source** for the maintenance command. It lives in the repo and is version-controlled.

The Bridge project has two command surfaces:

| Surface | Location | Committed? | Served by |
|---|---|---|---|
| **Claude Code slash commands** | `<repo>/.claude/commands/*.md` | No — `.claude/` is in `.gitignore` | Claude Code CLI (`/maintenance`) |
| **Bridge Commands palette** | `~/Library/Application Support/The Bridge/commands/` | No — runtime app-support | The Bridge app (hot-key palette, `⌃⌥⌘C`) |

Because `.claude/` is gitignored in this repo, the Claude Code slash command cannot be committed. The full protocol lives here in `docs/operator/maintenance-command.md` and is installed by the operator into the runtime locations.

### Operator installation (one-time setup)

**For Claude Code slash command use:**

```sh
mkdir -p "$(git rev-parse --show-toplevel)/.claude/commands"
cp "$(git rev-parse --show-toplevel)/docs/operator/maintenance-command.md" \
   "$(git rev-parse --show-toplevel)/.claude/commands/maintenance.md"
```

Then invoke with `/maintenance` in any Claude Code session inside this repo.

**For the Bridge Commands palette:**

```sh
COMMANDS_DIR="$HOME/Library/Application Support/The Bridge/commands"
cp "$(git rev-parse --show-toplevel)/docs/operator/maintenance-command.md" \
   "$COMMANDS_DIR/maintenance.md"
```

Then add an entry to `$COMMANDS_DIR/index.json`:

```json
{
  "icon": { "emoji": { "_0": "🔧" } },
  "name": "maintenance",
  "slug": "maintenance"
}
```

---

## Invocation

### Option A: Claude Code slash command (after operator install above)

```
/maintenance
```

### Option B: Direct paste

Paste the **Command Protocol** section below into any Claude session with Bridge MCP tools available.

### Option C: Read from docs (no install required)

In a Claude Code session inside this repo:

```
Read docs/operator/maintenance-command.md and execute the Command Protocol section.
```

---

## Data sources touched

| DS | Notion ID | Operation |
|---|---|---|
| AI LOGS | `992fd5ac-d938-4be4-95fb-8ef18bd86bba` | Read (idempotency check) + Create (new drain entries) |
| PACKETS | `078e7c9e-e53e-4c83-a893-af64f82b5123` | Read (status query) + Update (status transitions only) |

No records are deleted or permanently altered. All writes are additive (AI LOGS) or status-updating only (PACKETS).

---

## Guardrails

- **No auto-decline or auto-delete** — only transitions packets to less-stale statuses; never removes them
- **No auto-run scheduling** — must be operator-invoked; no cron or scheduled task
- **Idempotent** — safe to run multiple times; AI LOGS entries are checked for existence before creation
- **Bridge MCP required** — if the app is not running or the loopback is unavailable, abort and output a plain-text summary for manual entry
- **Rate limits** — Bridge Notion client runs at 2–3 req/s; expect 1–3 minutes for a full PACKETS sweep on a large backlog

---

## Command Protocol

> This section is the executable body of the command. It is self-contained. Copy it when invoking via Option B or C above.

### Step 0 — Load tools

Load Bridge MCP tools via ToolSearch:

```
select:mcp__Bridge_MCP__notion_query,mcp__Bridge_MCP__notion_page_create,mcp__Bridge_MCP__notion_page_update,mcp__Bridge_MCP__notion_blocks_append,mcp__Bridge_MCP__notion_datasource_get
```

If Bridge MCP is unavailable (app not running / tunnel down), abort and report — do not partially write.

---

### Step 1 — Drain pending sub-agent telemetry into AI LOGS

**Target DS:** AI LOGS — `992fd5ac-d938-4be4-95fb-8ef18bd86bba`

#### 1a. Collect pending entries

Gather telemetry that is not yet written to AI LOGS. Sources:

- **Bridge DeliveryLog:** any in-memory session audit rows (handshake-delivered, resource-reads, skill-fetches, memory-tool-calls, reminder-tool-calls) from sub-agent sessions in the current sprint that have no corresponding AI LOGS row. Retrieve via `bridge_status` or note them from conversation context.
- **Cursor/agent run entries:** any `RedactionAuditEntry` DTOs queued in `CursorRuntime` (visible via `pendingRedactionAudits()` if the cursor sidecar is active).
- **Sprint sub-agent outputs:** summary of what each sub-agent did, keyed by session/run ID if available. Derive from conversation context when no programmatic queue is available.

#### 1b. Write each entry to AI LOGS

For each pending entry, create one page in DS `992fd5ac-d938-4be4-95fb-8ef18bd86bba`:

| Property | Value |
|---|---|
| `Name` (title) | `[MAINT] <session-id-or-description> — <YYYY-MM-DD>` |
| `Log Type` | `Session` (for agent runs) or `Incident` (for errors/failures) or `Learning` (for insights) |
| `Platform` | `Claude Code` (or `Cursor` / `Other` as appropriate) |
| `Session Context` | sha256 hash of the prompt/task description — NEVER the raw prompt |
| `Status` | `Done` |

Write body content (page blocks) summarizing:
- What the sub-agent did
- Tool calls made / outcomes
- Any errors or partial results

**Idempotency:** before creating, query the DS filtered by `Name` contains the session ID. If a row already exists, skip creation and log "already drained".

#### 1c. Report

Summarize: N entries drained, M already existed (skipped).

---

### Step 2 — Reconcile PACKETS statuses

**Target DS:** PACKETS — `078e7c9e-e53e-4c83-a893-af64f82b5123`

#### 2a. Load incomplete packets

Query the PACKETS DS for all rows where Status is not in `{Done, Decline}` (i.e., Backlog, QUEUE, FOCUS, BLOCKED, REVIEW).

#### 2b. Cross-reference against live state

For each packet, evaluate whether its status is stale relative to verifiable live evidence:

| Check | How to verify |
|---|---|
| Branch merged to main | `git log --oneline origin/main` or `gh pr list --state merged` |
| PR closed/merged | `gh pr view <number> --json state,mergedAt` |
| Task marked Done in conversation | Conversation context |
| Blocked dependency now resolved | Query PACKETS or PROJECTS DS for the blocker |

**Status transitions allowed by this command (non-destructive):**

- `REVIEW` → `Done` — when verified merged to main or live-confirmed
- `FOCUS` → `REVIEW` — when work is complete but unverified
- `BLOCKED` → `QUEUE` — when the blocking dependency is resolved
- `QUEUE` → `FOCUS` — only if the operator explicitly requests promotion; never auto-promote

**Never auto-decline or auto-delete a packet.** Surface candidates only.

#### 2c. Write status updates

For each packet whose status should change, call `notion_page_update` with the new `Status` select value.

For packets where verification was ambiguous, write a short note in the `Packet Output` property (keep it short/ASCII to avoid the known "Invalid JSON" rejection for long rich_text values; use `notion_blocks_append` for longer receipts).

#### 2d. Report

Summarize:
- Total packets scanned
- Status updates applied (list each: packet name, old → new status, reason)
- Packets flagged for operator review (cannot auto-verify)
- No-ops (already correct status)

---

### Step 3 — Wrap-up log

Append a one-line dated entry to the AI LOGS DS or the current conversation:

```
<UTC timestamp> — maintenance command: N AI LOGS entries drained, M PACKETS statuses reconciled (K updated, L flagged for review).
```

---

## Notes

- **BLOCKED status:** `BLOCKED` is a UI-only status option added by the operator. The `fromStatus` parser may not handle it in all code paths — treat it as equivalent to `QUEUE` for reconcile purposes.
- **rich_text gotcha:** `notion_page_update` rejects long/punctuated strings in rich_text properties. Keep `Packet Output` values short and ASCII; use `notion_blocks_append` for longer receipts.
- **DS IDs are stable** (bound by property ID, rename-safe): `992fd5ac-d938-4be4-95fb-8ef18bd86bba` (AI LOGS) and `078e7c9e-e53e-4c83-a893-af64f82b5123` (PACKETS).

---

## Related

- `docs/operator/commands-smoke-checklist.md` — smoke-test checklist for the Bridge Commands palette
- `docs/operator/commands-datasource.md` — historical Notion-backed Commands data source design (deferred; not the active palette)
- `docs/operator/skill-command-routing-schema.md` — routing vs. command visibility flags
- `TheBridge/Server/DeliveryLog.swift` — the Bridge telemetry log that this command drains
- Memory: `packet-pipeline-topology.md` — PACKETS DS ID and production spine context
- Memory: `packet-runner-v1.md` — Packet Runner v1 spec and AI LOGS DS schema
