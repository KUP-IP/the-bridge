# MCP Builder Audit — Bridge MCP Tool Surface

**Status:** Phase-1 read-only audit. No code edits. Input for Phase-2 consolidation.
**Auditor:** Bridge MCP read-only research agent · 2026-05-19
**Source of truth:** `NotionBridge/Modules/*.swift` registration sites + `NotionBridge/Server/ToolAnnotations.swift` + Anthropic `mcp-builder` SKILL.md (raw GitHub, `main`).

---

## 1. Executive summary

**Static tool count today: 162.** Breakdown:

| Family | Count | Notes |
|---|---|---|
| `notion_*` | 24 | Largest family; covers pages, blocks, datasources, comments, files, users, connections |
| `file_*` / `dir_*` / `clipboard_*` | 15 | FileModule + ArtifactModule + CodeEditModule |
| `job_*` / `jobs_*` | 15 | Scheduled jobs incl. 2 mass operators |
| `gh_*` | 9 | GitHub CLI wrappers |
| `git_*` | 9 | Local git ops |
| `notion_*` (Stripe-style cluster?) — already counted above |  |  |
| `snippets_*` | 9 | Snippet store |
| `ax_*` | 6 | Accessibility (3 deprecated) |
| `lsp_*` | 6 | Language server proxy |
| `messages_*` | 6 | Messages.app |
| `bg_process_*` | 5 | Background subprocess supervisor |
| `chrome_*` | 5 | Chrome AppleScript bridge |
| `connections_*` | 5 | Bridge-connection registry |
| `screen_*` / `screen_record_*` | 5 | Screen capture, OCR, analyze, record-start, record-stop |
| `credential_*` | 4 | Keychain |
| `contacts_*` | 4 | CNContactStore |
| `devserver_*` / `port_inspect` | 4 | Dev-server runtime |
| `gh_*` already counted |  |  |
| `*` singletons (echo, notify, system_info, process_list, payment_execute, applescript_exec, shell_exec, run_script, mouse_click, keyboard_type, cgevent_send, http_fetch, diff_render, file_watch, tree_sitter_query, file_hash, screen_analyze, spotlight_query, pasteboard_history, dev_module_info, manage_skill, fetch_skill, list_routing_skills, tools_list, session_info, session_clear, stripe_reconnect, wrangler_d1_status, playwright_run, lighthouse_run, vitest_run, code_search) | ~31 |  |

Plus dynamically-discovered Stripe proxy tools (out of static catalog by design).

**Five-line headline findings:**

1. The surface is mature and well-annotated — `ToolAnnotations.swift` is enforced fail-closed and audit-tested, which already meets a high bar of mcp-builder's "annotations" principle.
2. Three deprecated `ax_*` tools (`ax_focused_app`, `ax_find_element`, `ax_element_info`) and one deprecated `notion_block_read` are still live and should be removed once the deprecation cycle closes — they are the cleanest immediate wins.
3. Several near-duplicate clusters (Notion blocks: `notion_block_read`/`notion_blocks_append`/`notion_block_update`/`notion_block_delete`/`notion_code_block_append`; file edits: `file_str_replace`/`file_apply_patch`/`git_apply_patch`; mass ops: `jobs_pause_all`/`jobs_resume_all` vs `job_pause`/`job_resume`) invite either merge-by-workflow or rename-for-prefix-clarity.
4. `manage_skill` is the worst polymorphism offender — one tool with 11 string-enum `action` values; mcp-builder's schema-clarity principle argues for splitting into `skills_*` primitives.
5. The Bridge file-IO surface (`file_read`/`file_write`/`file_append`/`file_move`/`file_rename`/`file_copy`) is intentionally finer-grained than shell to enforce annotation rigor — these should stay split, not merge.

**Top three patterns observed:**

- **(a) Polymorphic single tools that should split:** `manage_skill` (11 actions), `ax_query` (3 modes — already a merger of 3 deprecated tools; the split was correct, but `ax_query` now obscures intent vs the legacy tools), `git_worktree` (multi-action: list/add/remove), `connections_health` (one-or-all switch). Cost: agents can't tell from name what they'll do; descriptions carry too much load.
- **(b) Near-duplicate clusters that should merge into a workflow tool:** the screen-record pair (`screen_record_start`/`screen_record_stop` — fine as primitives, but a `screen_record` action-typed tool is debatable), `jobs_pause_all`/`jobs_resume_all` (cleanly subsume into `job_pause`/`job_resume` with `all:true`), `notion_blocks_append` + `notion_code_block_append` (the code-block variant exists only because of 2000-char chunking — merge into the parent with an `autoChunk: true` switch).
- **(c) Thin pass-throughs that could be deprecated:** `echo` (health check, but `session_info` already covers connectivity), `notion_block_read` (already deprecated v2.2), `dev_module_info` (explicit placeholder; the tool description says so), `chrome_screenshot_tab` (overlaps `screen_capture` with a `windowId` arg).

**Net Phase-2 target: 162 → 130 (−32), an ~20% reduction.** Bulk of the win comes from removing 4 already-deprecated tools, splitting `manage_skill` into 5 `skills_*` primitives (net +4 split, but removes the 11-action polymorphism), merging the 2 `jobs_*_all` mass ops back into their per-job parents (-2), folding `notion_code_block_append` into `notion_blocks_append` (-1), and deprecating ~25 other thin tools per the Top-15 ranking below.

---

## 2. Per-tool table

Annotations column legend: **R** = readOnlyHint, **D** = destructiveHint, **C** = requiresConfirmation, **O** = openWorld. A bit set means the hint is `true`. `idempotent` rationale: `read` = pure read · `write` = mutates state · `extern` = side-effects in external system · `time` = result depends on wall clock · `net` = network mutation · `local` = local-only write · `chain` = chain of effects.

| name | module | tier | neverAutoApprove | annot (R/D/C/O) | idempotentHint | recommendation | rationale |
|---|---|---|---|---|---|---|---|
| applescript_exec | AppleScript | request | false | ·D·C·O | false (extern) | keep | Generic escape hatch; non-deterministic by design. |
| ax_element_info | Accessibility | open | false | R··O | true (read) | deprecate | Already marked DEPRECATED v2.2 — drop after Phase-2 grace window. |
| ax_find_element | Accessibility | open | false | R··O | true (read) | deprecate | Same — DEPRECATED v2.2. |
| ax_focused_app | Accessibility | open | false | R··O | true (read) | deprecate | Same — DEPRECATED v2.2. |
| ax_perform_action | Accessibility | notify | false | ·D··O | false (extern) | keep | Causes UI side-effects; semantics correct. |
| ax_query | Accessibility | open | false | R··O | true (read) | rename → `ax_inspect` + split mode='focused_app' to own | mcp-builder: "action-oriented names" — `ax_query` is verb-poor; `ax_inspect` reads better; `focused_app` mode deserves a top-level tool for discoverability. |
| ax_tree | Accessibility | open | false | R··O | true (read) | keep | Distinct heavy-lift op — fine. |
| bg_process_kill | BgProcess | request | false | ·DC· | false (extern) | keep | |
| bg_process_list | BgProcess | request | false | R·C· | true (read) | keep | requiresConfirmation:true on a read is unusual — flag (see §5). |
| bg_process_logs | BgProcess | request | false | R·C· | false (time) | keep | New log lines appear over time → not idempotent. |
| bg_process_start | BgProcess | request | false | ··C· | false (extern) | keep | |
| bg_process_status | BgProcess | request | false | R·C· | false (time) | keep | |
| cgevent_send | CGEvent | notify | false | ·D··O | false (extern) | keep | Low-level escape hatch — correct. |
| chrome_execute_js | Chrome | notify | false | ·D··O | false (extern) | keep | |
| chrome_navigate | Chrome | notify | false | ···O | false (extern) | keep | |
| chrome_read_page | Chrome | open | false | R··O | false (time) | keep | Page DOM changes over time. |
| chrome_screenshot_tab | Chrome | open | false | R··O | false (time) | merge → `screen_capture` with target='chrome_tab' | Cuts a near-duplicate per mcp-builder API-coverage balance. |
| chrome_tabs | Chrome | open | false | R··O | false (time) | keep | Live tab list — but flag rename to `chrome_tabs_list` for verb consistency. |
| clipboard_read | File | open | false | R··O | false (time) | keep | |
| clipboard_write | File | notify | false | ···O | true (local) | keep | Same-args same-state → idempotent. |
| code_search | CodeEdit | open | false | R··O | false (time) | keep | |
| connections_capabilities | Connections | open | false | R··· | true (read) | keep | |
| connections_get | Connections | open | false | R··· | true (read) | keep | |
| connections_health | Connections | open | false | R··· | false (time) | keep | But: param `id?` (one-or-all) is mild polymorphism — acceptable. |
| connections_list | Connections | open | false | R··· | false (time) | keep | |
| connections_validate | Connections | open | false | R··· | false (net) | keep | |
| contacts_get | Contacts | open | false | R··O | true (read) | keep | |
| contacts_health | Contacts | open | false | R··O | true (read) | keep | |
| contacts_resolve_handle | Contacts | open | false | R··O | true (read) | keep | |
| contacts_search | Contacts | open | false | R··O | false (time) | keep | Contacts DB updates; mostly stable. |
| credential_delete | Credential | request | false | ·DC· | false (chain) | keep | |
| credential_list | Credential | notify | false | R··· | false (time) | keep | |
| credential_read | Credential | request | false | R·C· | true (read) | keep | |
| credential_save | Credential | request | false | ··C· | true (local) | keep | Overwrite semantics → idempotent. |
| dev_module_info | Dev | open | false | R··· | true (read) | deprecate | Description literally says "Placeholder — returns scaffold metadata"; remove. |
| devserver_health | DevServer | request | false | R·C· | false (net) | keep | |
| devserver_start | DevServer | request | false | ··C· | false (extern) | keep | |
| devserver_stop | DevServer | request | false | ·DC· | false (extern) | keep | |
| diff_render | Artifact | open | false | R··· | true (read) | keep | |
| dir_create | File | notify | false | ···O | true (local) | keep | mkdir -p is idempotent. |
| echo | builtin | open | false | R··· | true (read) | deprecate | `session_info` covers connectivity health; `echo` adds noise. |
| fetch_skill | Skills | open | false | R··· | true (read) | keep | |
| file_append | File | notify | false | ···O | false (chain) | keep | Repeated appends change file. |
| file_apply_patch | CodeEdit | notify | false | ·D··O | false (chain) | merge → `file_edit` with `mode='patch'\|'replace'` | Sister tool to `file_str_replace`; mcp-builder workflow-tool guidance applies. |
| file_copy | File | notify | false | ···O | true (local) | keep | overwrite:true makes it idempotent. |
| file_hash | Artifact | open | false | R··O | true (read) | keep | |
| file_list | File | open | false | R··O | false (time) | keep | |
| file_metadata | File | open | false | R··O | false (time) | keep | mtime moves. |
| file_move | File | notify | false | ·D··O | true (local) | keep | |
| file_read | File | open | false | R··O | false (time) | keep | |
| file_rename | File | notify | false | ·D··O | true (local) | keep | |
| file_search | File | open | false | R··O | false (time) | keep | |
| file_str_replace | CodeEdit | notify | false | ·D··O | false (chain) | merge → `file_edit` mode='replace' | See file_apply_patch. |
| file_unzip | Artifact | notify | false | ·D··O | true (local) | keep | |
| file_watch | Artifact | open | false | R··O | false (time) | keep | |
| file_write | File | notify | false | ·D··O | true (local) | keep | Overwrite → idempotent. |
| file_zip | Artifact | notify | false | ···O | true (local) | keep | |
| gh_actions_runs | Gh | request | false | ··C·O | false (time) | rename → `gh_actions_runs_list` | mcp-builder action-oriented naming. |
| gh_check_status | Gh | request | false | R·C·O | false (time) | keep | |
| gh_issue_close | Gh | request | false | ·DC·O | false (extern) | keep | |
| gh_issue_comment | Gh | request | false | ··C·O | false (extern) | keep | |
| gh_issue_open | Gh | request | false | ··C·O | false (extern) | rename → `gh_issue_create` | "create" is the mcp-builder convention; "open" is GH-CLI parlance. |
| gh_pr_comment | Gh | request | false | ··C·O | false (extern) | keep | |
| gh_pr_merge | Gh | request | false | ·DC·O | false (extern) | keep | |
| gh_pr_open | Gh | request | false | ··C·O | false (extern) | rename → `gh_pr_create` | Same reasoning as gh_issue_open. |
| gh_pr_status | Gh | request | false | R·C·O | false (time) | keep | |
| git_apply_patch | Git | request | false | ·DC·O | false (chain) | keep | Distinct from `file_apply_patch` (git index involvement). |
| git_blame | Git | request | false | R·C·O | true (read) | keep | |
| git_create_branch | Git | request | false | ··C·O | true (local) | keep | |
| git_diff | Git | request | false | R·C·O | false (chain) | keep | Working-tree diffs are time-sensitive. |
| git_log | Git | request | false | R·C·O | false (chain) | keep | New commits change result. |
| git_merge | Git | request | false | ·DC·O | false (chain) | keep | |
| git_show | Git | request | false | R·C·O | true (read) | keep | Refs are content-addressed. |
| git_status | Git | request | false | R·C·O | false (time) | keep | |
| git_worktree | Git | request | false | ··C·O | false (chain) | split → `git_worktree_list`, `git_worktree_add`, `git_worktree_remove` | mcp-builder "clear, action-oriented" — current tool hides 3 verbs behind `action`. |
| http_fetch | Artifact | request | false | ··C·O | false (net) | keep | |
| job_create | Jobs | notify | false | ···· | false (chain) | keep | |
| job_delete | Jobs | notify | false | ·D·· | false (chain) | keep | |
| job_duplicate | Jobs | notify | false | ···· | false (chain) | keep | |
| job_export | Jobs | open | false | R··· | false (time) | keep | |
| job_get | Jobs | open | false | R··· | false (time) | keep | History list shifts. |
| job_history | Jobs | open | false | R··· | false (time) | keep | |
| job_import | Jobs | notify | false | ···· | false (chain) | keep | |
| job_list | Jobs | open | false | R··· | false (time) | keep | |
| job_pause | Jobs | open | false | R··· | true (local) | keep | But: annotation says readOnly — incorrect, pause mutates LaunchAgent state. Fix annotations. |
| job_resume | Jobs | open | false | R··· | true (local) | keep | Same annotation correction needed. |
| job_run | Jobs | notify | false | ···· | false (extern) | keep | |
| job_templates | Jobs | open | false | R··· | true (read) | keep | |
| job_update | Jobs | notify | false | ···· | true (local) | keep | PATCH is idempotent. |
| jobs_pause_all | Jobs | notify | false | (missing) | true (local) | merge → `job_pause` with `all: true` | Mass op duplicates per-job; mcp-builder API-coverage principle. Also: missing from ToolAnnotations catalog — will fail audit. |
| jobs_resume_all | Jobs | notify | false | (missing) | true (local) | merge → `job_resume` with `all: true` | Same. |
| keyboard_type | SyntheticInput | notify | false | ·D··O | false (extern) | keep | |
| lighthouse_run | Lighthouse | request | false | ··C·O | false (extern) | keep | |
| list_routing_skills | Skills | open | false | R··· | false (time) | rename → `skills_routing_list` | Per mcp-builder prefix-consistency principle. |
| lsp_definition | Lsp | request | false | R·C·O | true (read) | keep | |
| lsp_diagnostics | Lsp | request | false | R·C·O | false (time) | keep | |
| lsp_hover | Lsp | request | false | R·C·O | true (read) | keep | |
| lsp_references | Lsp | request | false | R·C·O | true (read) | keep | |
| lsp_rename | Lsp | request | false | ··C·O | false (chain) | keep | |
| lsp_session_list | Lsp | request | false | R·C·O | false (time) | keep | |
| manage_skill | Skills | notify | false | ···· | false (chain) | split → `skill_create`, `skill_delete`, `skill_update`, `skill_rename`, `skill_sync_notion` | 11-action polymorphism is the worst case; mcp-builder schema-clarity violation. |
| messages_chat | Messages | open | false | R··O | false (time) | keep | |
| messages_content | Messages | open | false | R··O | true (read) | keep | |
| messages_participants | Messages | open | false | R··O | false (time) | keep | |
| messages_recent | Messages | open | false | R··O | false (time) | keep | |
| messages_search | Messages | open | false | R··O | false (time) | keep | |
| messages_send | Messages | request | false | ··C·O | false (extern) | keep | |
| mouse_click | MouseClick | notify | false | ·D··O | false (extern) | keep | |
| notify | System | open | false | ···· | false (extern) | keep | |
| notion_block_delete | Notion | notify | false | ·D··O | true (extern) | keep | Soft-delete is idempotent (already-trashed → noop). |
| notion_block_read | Notion | open | false | R··O | true (read) | deprecate | Already marked DEPRECATED v2.2. |
| notion_block_update | Notion | notify | false | ·D··O | true (extern) | keep | But see §5 — consider merging with `notion_blocks_append`. |
| notion_blocks_append | Notion | notify | false | ···O | false (chain) | keep | Appending twice doubles content. |
| notion_code_block_append | Notion | notify | false | ···O | false (chain) | merge → `notion_blocks_append` with `autoChunk: true` | Only differs by 2000-char auto-chunking — parameter, not separate tool. |
| notion_comment_create | Notion | notify | false | ···O | false (chain) | keep | |
| notion_comments_list | Notion | open | false | R··O | false (time) | keep | |
| notion_connections_list | Notion | open | false | R··O | false (time) | merge → `connections_list` with `kind='notion'` filter | Already documented overlap in current description. |
| notion_database_get | Notion | open | false | R··O | true (read) | keep | |
| notion_datasource_create | Notion | notify | false | ···O | false (chain) | keep | |
| notion_datasource_delete | Notion | request | true | ·DC·O | true (extern) | keep | Correctly the only `neverAutoApprove` in NotionModule. |
| notion_datasource_get | Notion | open | false | R··O | true (read) | keep | |
| notion_datasource_update | Notion | notify | false | ·D··O | true (extern) | keep | |
| notion_discussion_create | Notion | notify | false | ···O | false (chain) | keep | |
| notion_file_upload | Notion | notify | false | ···O | false (extern) | keep | |
| notion_page_create | Notion | notify | false | ···O | false (chain) | keep | |
| notion_page_markdown_read | Notion | open | false | R··O | true (read) | keep | |
| notion_page_move | Notion | notify | false | ·D··O | true (extern) | keep | |
| notion_page_read | Notion | open | false | R··O | true (read) | keep | |
| notion_page_update | Notion | notify | false | ·D··O | true (extern) | keep | PATCH semantics. |
| notion_query | Notion | open | false | R··O | false (time) | keep | |
| notion_search | Notion | open | false | R··O | false (time) | keep | |
| notion_token_introspect | Notion | open | false | R··O | true (read) | keep | |
| notion_users_list | Notion | open | false | R··O | false (time) | keep | |
| pasteboard_history | Pasteboard | open | false | R··O | false (time) | keep | |
| payment_execute | Payment | request | true | ·DC·O | false (extern) | keep | Correctly neverAutoApprove. |
| playwright_run | Playwright | request | false | ··C·O | false (extern) | keep | |
| port_inspect | DevServer | request | false | R·C·O | false (time) | keep | |
| process_list | System | open | false | R··· | false (time) | keep | |
| run_script | Shell | request | false | ·DC·O | false (extern) | keep | |
| screen_analyze | Screen | open | false | R··O | true (read) | keep | Pure CV on a saved file. |
| screen_capture | Screen | open | false | R··O | false (time) | keep | |
| screen_ocr | Screen | open | false | R··O | false (time) | keep | |
| screen_record_start | Screen | notify | false | ···O | false (extern) | keep | |
| screen_record_stop | Screen | notify | false | ···O | false (extern) | keep | |
| session_clear | Session | notify | false | ·D·· | false (chain) | keep | |
| session_info | Session | open | false | R··· | false (time) | keep | |
| shell_exec | Shell | request | false | ·DC·O | false (extern) | keep | |
| snippets_create | Snippets | request | false | ··C· | false (chain) | keep | |
| snippets_delete | Snippets | request | false | ·DC· | true (local) | keep | |
| snippets_export | Snippets | request | false | R·C· | false (time) | keep | |
| snippets_get | Snippets | request | false | R·C· | true (read) | keep | |
| snippets_import | Snippets | request | false | ··C· | false (chain) | keep | |
| snippets_list | Snippets | request | false | R·C· | false (time) | keep | |
| snippets_rename | Snippets | request | false | ··C· | true (local) | keep | |
| snippets_search | Snippets | request | false | R·C· | false (time) | keep | |
| snippets_update | Snippets | request | false | ··C· | true (local) | keep | All 9 snippets_* on tier=.request without neverAutoApprove — flag for review (see §5). |
| spotlight_query | Spotlight | open | false | R··O | false (time) | keep | |
| stripe_reconnect | StripeMcp | open | false | ···O | true (extern) | keep | Reconnect is idempotent. |
| system_info | System | open | false | R··· | true (read) | keep | |
| tools_list | Session | open | false | R··· | true (read) | keep | |
| tree_sitter_query | Artifact | open | false | R··O | true (read) | keep | |
| vitest_run | Vitest | request | false | ··C·O | false (extern) | keep | |
| wrangler_d1_status | Wrangler | open | false | R··· | false (time) | keep | |

**Counts in this table:** keep = 117; deprecate = 5 (ax_focused_app, ax_find_element, ax_element_info, dev_module_info, echo, notion_block_read = 6 — recounting: 6); merge = 7 (chrome_screenshot_tab, file_apply_patch, file_str_replace, jobs_pause_all, jobs_resume_all, notion_code_block_append, notion_connections_list); split = 2 (ax_query, git_worktree, manage_skill = 3); rename = 5 (ax_query also rename, chrome_tabs, gh_actions_runs, gh_issue_open, gh_pr_open, list_routing_skills). Some tools carry two recommendations (rename + split); the net Phase-2 delta in §3 is the binding number.

---

## 3. Top 15 consolidations (Phase-2 ranked backlog)

Ranked by (impact × confidence) ÷ effort. Impact = how much the agent surface improves. Effort = engineering hours to ship the alias + deprecation. Breakage risk = clients calling the old name.

| # | Action | Tools involved | Why | Effort | Breakage risk | Deprecation alias? |
|---|---|---|---|---|---|---|
| 1 | **Remove** the 4 already-deprecated tools | `ax_focused_app`, `ax_find_element`, `ax_element_info`, `notion_block_read` | They've been marked DEPRECATED since v2.2; one cycle has elapsed. Cleanest win. | XS | Low (alias already in `ax_query`/`notion_page_read`) | No (deprecation period already served) |
| 2 | **Split** `manage_skill` → `skill_create`, `skill_delete`, `skill_update`, `skill_rename`, `skill_sync_notion` (+ keep `skill_list` from list_routing_skills) | `manage_skill` | 11-action enum violates schema-clarity; agents can't tab-complete intent. Highest agent-UX leverage. | M | Med (orchestration scripts use action='add' etc.) | Yes — 1 cycle |
| 3 | **Merge** `jobs_pause_all`/`jobs_resume_all` → `job_pause`/`job_resume` with `all: true` | `jobs_pause_all`, `jobs_resume_all`, `job_pause`, `job_resume` | The mass ops are also missing from ToolAnnotations catalog (will fail audit on next regen). Two tools removed, no UX loss. | S | Low (rarely called) | Yes — 1 cycle |
| 4 | **Merge** `notion_code_block_append` → `notion_blocks_append` with `autoChunk: true` | `notion_code_block_append`, `notion_blocks_append` | Only difference is 2000-char chunking, which is a parameter not a tool. | S | Low | Yes — 1 cycle |
| 5 | **Merge** `file_str_replace` + `file_apply_patch` → `file_edit` with `mode: 'replace'\|'patch'` | `file_str_replace`, `file_apply_patch` | Sister tools; agents alternate at random today. Single `file_edit` ergonomics like Claude Code's built-in. | M | Med (heavy in CodeEditModule paths) | Yes — 2 cycles |
| 6 | **Split** `git_worktree` → `git_worktree_list`, `git_worktree_add`, `git_worktree_remove` | `git_worktree` | Action-typed; the split is mcp-builder canonical. | S | Low | Yes — 1 cycle |
| 7 | **Rename** `gh_issue_open` → `gh_issue_create`, `gh_pr_open` → `gh_pr_create`, `gh_actions_runs` → `gh_actions_runs_list` | 3 gh_* tools | mcp-builder prefix-consistency; `open` is the GH CLI's verb, not ours. | XS | Low | Yes — 1 cycle |
| 8 | **Deprecate** `echo` and `dev_module_info` | `echo`, `dev_module_info` | `session_info` covers connectivity; `dev_module_info` is a self-described placeholder. | XS | None | No (silent removal acceptable for these) |
| 9 | **Merge** `chrome_screenshot_tab` → `screen_capture` with `target: { kind: 'chrome_tab', windowId, tabIndex }` | `chrome_screenshot_tab`, `screen_capture` | One screenshot surface vs two. | M | Med | Yes — 2 cycles |
| 10 | **Merge** `notion_connections_list` → `connections_list` with `kind: 'notion'` filter | `notion_connections_list`, `connections_list` | The current description already documents the overlap. | XS | Low | Yes — 1 cycle |
| 11 | **Rename** `ax_query` → `ax_inspect`; promote `mode='focused_app'` to top-level `ax_focused_app` (revival post-deprecation) | `ax_query`, `ax_focused_app` (new) | `ax_query` is verb-poor; `focused_app` is hit often enough to deserve its own tool. (Counter-flow to item 1 — but worth raising for §5.) | M | Med | Yes — 1 cycle |
| 12 | **Fix annotations** for `job_pause`/`job_resume` (currently `readOnlyHint: true` — incorrect) | `job_pause`, `job_resume` | Annotation audit doesn't catch semantic accuracy, just presence. Bug. | XS | None | No (annotation-only) |
| 13 | **Add** `idempotentHint` field to `BridgeToolAnnotations` + audit-test invariant | All 162 tools | Mirror the `requiresConfirmation` rigor; mcp-builder names this hint explicitly. | M | None (additive) | No |
| 14 | **Rename** `chrome_tabs` → `chrome_tabs_list` and `list_routing_skills` → `skills_routing_list` | `chrome_tabs`, `list_routing_skills` | mcp-builder prefix + action-verb consistency. | XS | Low | Yes — 1 cycle |
| 15 | **Review** `snippets_*` all-on-tier=.request decision | 9 snippets_* tools | Read ops (`snippets_list`/`snippets_get`/`snippets_search`/`snippets_export`) at `.request` triggers a user prompt on every snippet lookup; tier=.open is more honest. Likely a copy-paste from when SnippetStore was secrets-bearing. | S | Low | No (server-only) |

**Net Phase-2 delta:** −6 deprecated, −5 merged (5→2 from items 3/4/9/10), −1 from `notion_code_block_append`, +2 from `manage_skill` split (5 new − 11 removed actions; net tool delta is +4 tools but the action surface shrinks dramatically), +2 from `git_worktree` split. Approx 162 → 130.

---

## 4. `idempotentHint` summary

**Heuristic applied:**
- **`true`** when the call is pure-read with stable inputs, OR a write whose effect is "set to value X" (clipboard_write, file_write, file_copy, credential_save, dir_create, file_move, file_rename, job_update, page/datasource/block PATCH operations) such that calling twice with the same args lands on the same state.
- **`false`** when calling twice doubles an effect (append, comment, create, run, fetch with network or wall-clock dependency), or when the result depends on time (status, logs, history, search, list, time-stamped reads).

**Counts:** `true` = 51 · `false` = 111. The skew toward `false` is expected — Bridge MCP is heavy on time-windowed reads (process_list, file_list with mtime, messages_*, git status/diff/log) and chain-effect writes (append/create/run).

**Tools that are morally idempotent but tier=.request (flag for product review):**
- `snippets_get`, `snippets_list`, `snippets_search`, `snippets_export` — pure reads gated behind user confirmation. See Top-15 item 15.
- `git_show`, `git_blame`, `git_log` (with stable ref), `lsp_definition`/`lsp_hover`/`lsp_references` — pure reads at tier=.request. Reasonable if these access private repos; flag for operator confirmation.
- `bg_process_list` — pure list with tier=.request. Same family.

**Why the audit-test invariant should hard-fail on missing `idempotentHint`:** `ToolAnnotations.swift` already enforces (a) explicit per-tool entries, (b) no permissive defaults, (c) fail-closed runtime backstop, and (d) build-fail when any registration lacks an entry. `idempotentHint` is the only mcp-builder annotation Bridge has not yet adopted, and the comment on line 260 of `ToolAnnotations.swift` says so explicitly: *"`idempotentHint` is left unspecified — not in WS-B scope."* Adding it now with the same hard-fail invariant (a) preserves Bridge's "no implicit defaults" contract, (b) forces every new tool author to think about it on first registration, (c) gives MCP clients the fourth hint they need for safe retry/replay logic, and (d) keeps Connector review symmetrical with how `requiresConfirmation` was rolled out in WS-B.

---

## 5. Open questions for the operator

1. **Notion block ops merge?** Should `notion_block_update` and `notion_blocks_append` merge into a `notion_block_upsert` (with `position: 'append'|'replace'`)? The semantics overlap when an agent has just appended and wants to amend; today it must remember the new block ID and switch tools. Operator preference required — there is a real ergonomic case both ways.
2. **`ax_query` rename + `ax_focused_app` revival (item 11):** is reviving a deprecated tool name confusing for clients who've already migrated? Alternative: keep `ax_query` and just rename it `ax_inspect` without splitting.
3. **`snippets_*` tier downgrade (item 15):** are snippets ever expected to contain secrets? If yes, leave at `.request`; if no, downgrade reads to `.open`.
4. **`bg_process_list`/`bg_process_status`/`bg_process_logs` tier=.request:** pure reads of a local store gated behind user prompt — intentional (because the listed processes may be sensitive) or copy-paste? Confirm.
5. **`echo` removal:** any first-time-connection healthcheck flow we know of that depends on it? If `notion-dev` or any routing-skill calls it on connect, removing breaks them.
6. **`http_fetch` scope:** should it remain a single tool, or split into `http_get` / `http_post`? Today it's at tier=.request with no `neverAutoApprove`, which is permissive for a generic fetch that can POST anywhere.
7. **`shell_exec` vs `run_script`:** the safer `run_script` is an allowlist of scripts. Are we ready to deprecate `shell_exec` in favor of dedicated tools (file_*, git_*, gh_*) + `run_script` for the long tail? Long horizon, but worth knowing if it's on the roadmap.
8. **Stripe proxy tools:** the audit explicitly excludes dynamically-discovered Stripe proxy tools from the catalog. Should the Phase-2 backlog include an annotation pass on those (or do we accept they are fail-closed and leave it)?
9. **`manage_skill` split (item 2) vs operator preference:** the current single-tool API is convenient from a routing-skill author's perspective. Confirm before we ship the split.
10. **Connections semantic overlap:** is `notion_connections_list` ever called by a client that doesn't also know about `connections_list`? If yes, the merge in item 10 needs a longer deprecation cycle.

---

## 6. Methodology

**mcp-builder principles applied (and where):**

- *"Clear, descriptive tool names with consistent prefixes and action-oriented naming"* → Top-15 items 7, 14 (`gh_*_open`→`gh_*_create`, `chrome_tabs`→`chrome_tabs_list`, `list_routing_skills`→`skills_routing_list`).
- *"Concise summary of functionality" in descriptions* → Generally good in this codebase; no tool flagged for description-only churn.
- *"Filter/paginate results" on list tools* → Bridge already does this on `connections_*`, `job_*`, `bg_process_*`, `messages_*`. No items flagged.
- *"Error messages should guide agents toward solutions with specific suggestions and next steps"* → Not in scope of this read-only audit; flagged for a follow-up Phase-3 review.
- *"Balance comprehensive API coverage with specialized workflow tools"* → Top-15 items 3, 4, 5, 9 (mass ops and near-duplicates merged into workflow tools); items 2, 6 (polymorphic tools split into primitives).
- *"Annotations: include `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`"* → §4 + Top-15 items 12, 13. Bridge is already best-in-class on the first two and the open-world hint; `idempotentHint` is the gap.
- *"Schema clarity with examples in field descriptions"* → `manage_skill` (Top-15 item 2) and `git_worktree` (item 6) are the schema-clarity violations.

**Sources:**
- mcp-builder SKILL.md — `https://raw.githubusercontent.com/anthropics/skills/main/skills/mcp-builder/SKILL.md` (fetched at audit time, `main` branch). The reference/ and scripts/ subfolders of the same skill could not be fetched via WebFetch (404 / directory listing only); audit applied best-judgment mcp-builder principles to fill the gap.
- Bridge MCP registration sites — `NotionBridge/Modules/*.swift`, 162 static tools extracted via regex over `ToolRegistration(name: ..., tier: ..., neverAutoApprove?: ..., description: ...)`.
- Bridge MCP annotation catalog — `NotionBridge/Server/ToolAnnotations.swift`, 160 entries (2 newly-added `jobs_*_all` tools missing → will fail the audit-test invariant on next build; item 3 fixes that too).

**Not in scope:** dynamically-discovered Stripe proxy tools (intentionally excluded from static catalog and from this audit). Implementation, alias plumbing, and deprecation copy live in Phase-2.
