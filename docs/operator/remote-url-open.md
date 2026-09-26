# Remote URL open vs worktree-gated tools

Issue: [#312](https://github.com/KUP-IP/the-bridge/issues/312)

Remote Notion AI / Bridge cloud clients cannot `shell_exec open <url>`. That
failure is **intentional C0** (`WorktreeOwnership.swift`): `open` is an opaque
executable, so the command cannot prove a complete worktree target set and
fails as `worktree_target_unresolved`. Do not weaken C0 for claimed worktrees.

## Open a Notion / http(s) URL on the Mac

Use the first-class tool:

```
url_open url:"https://www.notion.so/<page>"
```

Allowed schemes: `http`, `https`, `notion`. Rejected: `file:`, `javascript:`,
`data:`, relative paths, credentialed URLs. `url_open` is **not**
worktree-gated — it never opens local files, so it is not a C0 bypass.

Same effective behavior as AppleScript `open location "{url}"`. If `url_open`
is unavailable on an older host, `applescript_exec` with that script remains
the cover. Do **not** retry `shell_exec open`.

## Worktree-gated remote tools (C0)

These go through `WorktreeOwnershipGuard.authorizeToolMutation` after security
approval. A live Git worktree target requires `ownerSession` matching
`worktree_claim`. Dynamic / opaque targets fail closed.

| Surface | Tools | Notes |
| --- | --- | --- |
| Shell | `shell_exec` | Working dir + statically resolved paths. `open <http(s)>` is unresolved; error names `url_open`. |
| Background | `bg_run` | Same analysis as `shell_exec`; governed worktree execution is denied. |
| Script runner | `run_script` | Always `worktree_target_unresolved`. Opaque effects cannot satisfy C0. Use `shell_exec` with an explicit command and `workingDir` — see the C0 inventory. |
| Git writes | `git_apply_patch`, `git_create_branch` | `cwd`; repository required. |
| File writes | `file_edit`, `file_write`, `file_append`, `dir_create`, `file_move`, `file_rename`, `file_copy`, `file_zip`, `file_unzip` | Mutated paths; some preview/check bypasses. |
| Tests | `node_test` | `workingDir`. |
| Worktree | `worktree_command_run` | Explicit `worktreePath` required. |

Full analysis surface: `docs/evidence/c0-guarded-operation-inventory.md`.

## AppleScript-legal / not worktree-gated (this host)

These do **not** enter C0 command analysis. They still have their own security
tiers (Open / Notify / Request) and TCC / Automation grants.

| Family | Examples | Notes |
| --- | --- | --- |
| URL open | `url_open` | Preferred for http(s)/notion. Notify tier. |
| AppleScript | `applescript_exec` | Request tier. `open location "{url}"` is legal here. Preferred over `shell_exec osascript`. |
| System | `system_info`, `process_list`, `notify` | Host facts / banner. Not a URL opener. |
| Notion | `notion_*`, `registry_*` | Workspace API. After a write, open the returned URL with `url_open`. |
| Mac apps | `mail_*`, `messages_*`, `notes_*`, `calendar_*`, `reminders_*`, `contacts_*` | Apple Event / EventKit surfaces. |
| Skills / doctrine | `fetch_skill`, `bridge_initialize`, `standing_orders_*` | Read/handshake. |

`run_script` is listed above on purpose: it is registered next to `shell_exec`
but is **not** AppleScript-legal — it is always unresolved. Cross-link only;
do not change that contract.

## Error copy

When `shell_exec` / `bg_run` is `open <http(s)|notion://…>` and C0 denies it:

```
worktree_target_unresolved
remedy=Do not retry shell_exec open. Use url_open with the http(s) or notion URL, or applescript_exec with open location "{url}".
```

`open /path/to/file` keeps the generic C0 remedy (explicit, statically
resolvable worktree target). That is not a URL-open case.
