# keepr-bridge v1.8.0 — Sprint Plan

**Sprint:** v1.8.0 — MCP Tool Remediation & Notion API Expansion
**Contract:** `sk mac-dev v3.0.1` — Workflows B (BUILD), C (GIT + C-V), E (TEST), F (CURSOR)
**Base branch:** `main` @ `a3a275c`
**Target release:** v1.8.0 (build 15)
**Last updated:** 2026-04-04

---

## Objective

Close confirmed open bugs, expand Notion API coverage with 4 new tools, fix high-friction behavioral gaps, and update stale tool descriptions. Land all pending branches before sprint work begins.

---

## Pre-Sprint: Git Hygiene

Must complete before any sprint branch is opened.

| Step | Action | Notes |
|------|--------|-------|
| G1 | Commit unstaged `main` changes | Proxy client-name injection, AGENT_FEEDBACK additions, test/doc updates — single `chore:` commit |
| G2 | Merge `fix/session-lifecycle-stability` → main | 4 files, no conflict expected |
| G3 | Merge `feat/settings-connections-restructure` → main | 12 files, no conflict expected |
| G4 | Delete `claude/fervent-lichterman`, `claude/sad-kapitsa` | Ghost worktree branches, at main HEAD |

---

## Scope

### In Scope

Four tracks delivered as separate branches, merged to main individually upon completion and test pass.

#### Track A — Bug Fixes (`fix/mcp-tool-bugs`)

| ID | Tool | Issue | Definition of Done |
|----|------|-------|--------------------|
| A1 | `file_write` | HTML entities encoded in output — `<` → `&lt;`, `>` → `&gt;`. Passes dev server, fails esbuild production build. Root: MCP `Value.string()` decode path in `FileModule.swift`. | `file_write` writes `<div className="foo">` to a `.tsx` file; `file_read` returns it unchanged; `swift build` and esbuild both accept the output. Round-trip test added. |
| A2 | `credential_read` / `credential_list` | `parseKeychainItem()` throws for non-standard keychain labels; items stored under `com.notionbridge` service silently excluded from `credential_list`. | `credential_read("stripe_api_key")` returns the value for items stored under `com.notionbridge` service without error. `credential_list` returns unknown-label items with `type: "unknown"` instead of omitting them. |
| A3 | `messages_send` | Sending to a raw `chat[0-9]+` identifier creates a malformed ghost thread in Apple Messages UI (`any;-;chat...`). | `messages_send` with a raw `chat...` identifier returns an error before any dispatch. Error message directs caller to resolve the handle via `messages_participants` first. |

#### Track B — New Notion Tools (`feat/notion-api-tools`)

All tools follow Workflow B (7-step TheBridge Tool Development Protocol). Step 6 (Reload) hands off to `sk mac ops`.

| ID | Tool | Client Method | API Endpoint | Definition of Done |
|----|------|--------------|-------------|---------------------|
| B1 | `notion_database_get` | `getDatabase()` — exists at NotionClient A16 | `GET /databases/{id}` | Tool registered at `tier: .open`. Calling with a valid database ID returns the database container object (title, icon, cover, parent). |
| B2 | `notion_datasource_get` | New — `getDataSource()` | `GET /data_sources/{id}` | Client method implemented. Tool registered at `tier: .open`. Returns data source schema. |
| B3 | `notion_datasource_create` | New — `createDataSource()` | `POST /data_sources` | **Gate:** Only proceed if endpoint is confirmed in Notion API docs. Skip B3 if unconfirmed. Tool registered at `tier: .request`. |
| B4 | `notion_datasource_update` | New — `updateDataSource()` | `PATCH /data_sources/{id}` | **Gate:** Same as B3. Tool registered at `tier: .notify`. |

**CURSOR dispatch candidate (Workflow F):** B2–B4 client methods are mechanical implementations following the pattern of `queryDataSource()` (NotionClient line 495). Dispatch spec on request.

#### Track C — Behavioral Fixes (`fix/tool-behavioral`)

| ID | Tool | Issue | Definition of Done |
|----|------|-------|--------------------|
| C1 | `fetch_skill` | Exact-match only. `fetch_skill("sk web dev")` → "Skill not found: 'sk web dev'". No normalization, no suggestions. | Input is normalized before lookup: lowercased, spaces → hyphens, leading "sk " prefix stripped. `fetch_skill("sk web dev")` resolves to `web-dev`. On miss, error response includes a list of close matches. |
| C2 | `notion_query` | Transient 404 is indistinguishable from a genuine "not shared" error. Leads to false debug spirals averaging 20+ minutes. | Tool auto-retries once with a 2s delay on 404. Log entry distinguishes "retrying transient 404" from "permanent 404 — check sharing". Retry count visible in debug output. |
| C3 | `manage_skill` | SecurityGate 30s notification timeout causes failure in unattended/automated sessions. No batch bypass available. | `manage_skill` accepts a `bypassConfirmation: Bool` parameter. When `true`, the SecurityGate notify step is skipped and the operation proceeds without user prompt. Default remains `false` (unchanged behavior). |

#### Track D — Stale Descriptions (`chore/tool-descriptions`)

Description-only edits in `NotionModule.swift`. No logic changes.

| ID | Tool | Change |
|----|------|--------|
| D1 | `notion_search` | Update `filter.value` documentation: `"page" \| "data_source"` (not `"page" \| "database"`). Notion API 2026-03-11 migration. |
| D2 | `notion_page_create` | Note that `parentType: "database_id"` is legacy; `"data_source_id"` is the preferred parent type for row inserts under API 2026-03-11. |
| D3 | `notion_page_markdown_write` | **Removed** — undocumented endpoint (`PATCH /pages/{id}/markdown`), no public Notion API contract. Tool registration and `updatePageMarkdown()` client method deleted. Tests updated. Use `notion_blocks_append` for content writes. |

> D3 is already done. `notion_page_markdown_write` has been removed from `NotionModule.swift`, `NotionClient.swift`, and `NotionModuleTests.swift` in this session.

### Out of Scope

The following are acknowledged but deferred to a future sprint:

| Item | Reason |
|------|--------|
| `shell_exec` PATH / escaping / nohup issues | Execution environment problem; document in AGENTS.md/CLAUDE.md |
| `screen_capture` window ID discovery | Requires CGWindowListCopyWindowInfo integration; separate feature work |
| `screen_analyze` color quantization | Image processing changes; separate sprint |
| `file_copy` overwrite flag | Low priority; `shell_exec cp -f` is a reliable workaround |
| `file_write` double-curly `{{ }}` stripping | Likely upstream in MCP SDK/Notion URL compression layer; needs investigation before scoping |
| `file_read` 20KB size cap | Enhancement; `shell_exec` workaround is documented |
| `make install` kills MCP transport | Makefile split (`install-copy` / `install-restart`); low urgency |
| `applescript_exec` Messages chat inspection errors | Brittle AppleScript; consider dedicated `messages_read_chat` tool in future |

---

## Branch Strategy

Each track is a separate branch off `main` after pre-sprint git hygiene completes.

```
main (clean, post pre-sprint)
├── fix/mcp-tool-bugs        (Track A)
├── feat/notion-api-tools    (Track B)
├── fix/tool-behavioral      (Track C)
└── chore/tool-descriptions  (Track D)
```

Merge order recommendation: D → A → C → B. Shortest to longest, lower risk first. Each track must pass `swift test` before merge.

---

## Version Release — Workflow C-V

Run this before committing the version bump. All three locations must agree.

```bash
V_SWIFT=$(grep 'marketing =' TheBridge/Config/Version.swift | sed 's/.*"\(.*\)".*/\1/')
B_SWIFT=$(grep 'build =' TheBridge/Config/Version.swift | sed 's/.*"\(.*\)".*/\1/')
V_PLIST=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
B_PLIST=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
CL_VER=$(grep -m1 '^## \[' CHANGELOG.md | sed 's/.*\[\(.*\)\].*/\1/')
echo "Version.swift: $V_SWIFT ($B_SWIFT) | Info.plist: $V_PLIST ($B_PLIST) | CHANGELOG: $CL_VER"
[[ "$V_SWIFT" == "$V_PLIST" && "$V_SWIFT" == "$CL_VER" && "$B_SWIFT" == "$B_PLIST" ]] && echo "✅ All in sync" || echo "❌ MISMATCH — fix before committing"
```

Version bump targets:
- `Version.swift` → `1.8.0`, build `15`
- `Info.plist` → match
- `CHANGELOG.md` → `## [1.8.0] — 2026-04-XX`

---

## CHANGELOG Outline — v1.8.0

```markdown
## [1.8.0] — 2026-04-XX

### Added
- `notion_database_get` — retrieve Notion database container metadata (title, icon, cover, parent)
- `notion_datasource_get` — retrieve data source schema and properties
- `notion_datasource_create` — create a new data source (if API endpoint confirmed)
- `notion_datasource_update` — update data source schema (if API endpoint confirmed)
- `manage_skill` `bypassConfirmation` flag for unattended/automated session use

### Fixed
- `file_write` HTML entity encoding in JSX/TSX content (`<` was written as `&lt;`)
- `credential_read` and `credential_list` now surface items with non-standard keychain labels
- `messages_send` rejects raw `chat...` identifiers before dispatch to prevent ghost threads
- `notion_query` auto-retries once on transient 404 before surfacing error to caller
- `fetch_skill` normalizes input (case-fold, spaces→hyphens, strip "sk " prefix) before lookup

### Changed
- `notion_search` description updated: filter value is `"data_source"` not `"database"`
- `notion_page_create` documents `"data_source_id"` as preferred parent type for row inserts

### Removed
- `notion_page_markdown_write` — used an undocumented Notion internal endpoint (`PATCH /pages/{id}/markdown`) with no public API contract. Use `notion_blocks_append` for content writes.
```

---

## Deployment — Workflow B+

After version bump commit, use the Self-Update Protocol (detached nohup pipeline):

```bash
nohup bash -c '
  cd ~/Developer/keepr-bridge
  LOG=~/.notion-bridge-update.log
  echo "=== UPDATE STARTED $(date) ===" > "$LOG"
  make patch-deps >> "$LOG" 2>&1
  make app >> "$LOG" 2>&1
  make sign >> "$LOG" 2>&1
  make notarize >> "$LOG" 2>&1
  pkill -x TheBridge >> "$LOG" 2>&1
  sleep 3
  rm -rf "/Applications/The Bridge.app" "/Applications/TheBridge.app"
  ditto .build/TheBridge.app "/Applications/The Bridge.app" >> "$LOG" 2>&1
  open "/Applications/The Bridge.app"
  echo "=== UPDATE COMPLETE $(date) ===" >> "$LOG"
' > /dev/null 2>&1 &
```

Reconnect check: wait 60s, read `~/.notion-bridge-update.log` via MCP. Retry at 120s if still down. Alert user if down at 120s.

---

## Effort Estimates

| Track | Branch | Items | Estimate | Cursor-dispatchable |
|-------|--------|-------|----------|---------------------|
| Pre-sprint | — | 4 git ops | 20m | No |
| D: Descriptions | `chore/tool-descriptions` | 2 remaining | 10m | No |
| A: Bug fixes | `fix/mcp-tool-bugs` | 3 | 2.5h | No |
| C: Behavioral | `fix/tool-behavioral` | 3 | 2.25h | Partially |
| B: New tools | `feat/notion-api-tools` | 4 | 3.5h | B2–B4 yes |
| Version + deploy | — | 1 | 30m | No |
| **Total** | | **17** | **~9h** | |

---

## Risks & Dependencies

| Risk | Severity | Mitigation |
|------|----------|------------|
| `POST /data_sources` and `PATCH /data_sources/{id}` not in public Notion API | High | Verify before implementing B3/B4. Skip if unconfirmed. |
| `file_write` entity encoding is upstream in MCP SDK, not in `FileModule.swift` | Medium | If the fix cannot be applied at the FileModule layer, scope is blocked pending SDK investigation. Fall back to documenting `shell_exec` heredoc pattern. |
| Merging `feat/settings-connections-restructure` may conflict with sprint changes to `NotionModule.swift` | Low | Merge pre-sprint before any sprint branch touches NotionModule. |
| `manage_skill bypassConfirmation` weakens SecurityGate for automated sessions | Low | Flag is opt-in and explicit. Only applies to `notify` tier — `request` tier remains unaffected. |

---

## Acceptance Criteria Summary

Sprint is complete when all of the following pass:

- [ ] `swift test` passes on `main` after all track merges
- [ ] `file_write` round-trip test: write `<div className="foo">` to `.tsx`, read back without entity encoding, esbuild accepts output
- [ ] `credential_read("stripe_api_key")` returns value for `com.notionbridge` keychain items without error
- [ ] `credential_list` returns unknown-label items with `type: "unknown"`
- [ ] `messages_send` with raw `chat...` identifier returns error before dispatch
- [ ] `notion_query` logs "retrying transient 404" and retries once before surfacing error
- [ ] `fetch_skill("sk web dev")` resolves to `web-dev` skill without error
- [ ] `notion_database_get` returns database container object from Notion API
- [ ] `notion_datasource_get` returns data source schema from Notion API
- [ ] B3/B4 implemented if API confirmed; skipped with documented reason if not
- [ ] `manage_skill` with `bypassConfirmation: true` completes without SecurityGate notify prompt
- [ ] `notion_search`, `notion_page_create` descriptions updated in `NotionModule.swift`
- [ ] `notion_page_markdown_write` absent from tool registry, client, and tests (already done)
- [ ] `Version.swift`, `Info.plist`, `CHANGELOG.md` all agree on `1.8.0` / build `15`
- [ ] TheBridge v1.8.0 built, signed, notarized, installed, and reconnects successfully
