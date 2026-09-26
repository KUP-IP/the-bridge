# C0 Guarded Operation Inventory — Current Candidate

Packet: `3abcbb58-889e-814a-a55e-c1880bbe34d0`
Base: `850d58aca71ddf28ff6010bc334121b6936555ef`
Inventory date: 2026-07-30

## Shared enforcement seam

`ToolRouter` calls `WorktreeOwnershipGuard.authorizeToolMutation` after license, governance, module, and security-approval gates and immediately before handler invocation. Ownership failures use the normal audit/error path and occur before a handler, child process, background artifact, or target mutation.

## Registered surfaces

| Surface | Operation | Governed targets / disposition |
| --- | --- | --- |
| Git | `git_apply_patch` | `cwd`; pure check without index/commit bypasses |
| Git | `git_create_branch` | `cwd`; repository required |
| Code/file | `file_edit`, `file_write`, `file_append`, `dir_create` | mutated target path; edit preview bypasses |
| File | `file_move`, `file_rename` | source and destination |
| File | `file_copy` | destination; declared source is read-only |
| Archive | `file_zip` | archive output; source is read-only |
| Archive | `file_unzip` | destination; archive input is read-only |
| Command | `shell_exec` | working directory plus every statically resolved affected path/worktree |
| Background | `bg_run` | same analysis as shell; governed worktree execution is denied before startup |
| Script runner | `run_script` | always `worktree_target_unresolved`; opaque effects cannot satisfy C0 |

`url_open` is **not** on this list. It opens allowlisted http(s)/notion URLs via `NSWorkspace` and never enters C0 command analysis. `shell_exec open <http(s)>` remains unresolved (opaque `open`); the denial remedy names `url_open` / `applescript_exec open location`. Operator map: `docs/operator/remote-url-open.md`.

Every protected public schema exposes optional `ownerSession`; it becomes mandatory when a live Git worktree identity is resolved. `run_script` exposes the field for compatibility, but it cannot override fail-closed behavior. `run_script` always-unresolved is unchanged — see the operator doc for the cross-link only.

## Command-analysis coverage

- Quote-aware command chains and effective directory tracking through `cd`, `command`, `env -C`, supported sudo chdir forms, and nested bash/sh/zsh `-c`.
- Direct relative/absolute executable and script paths.
- Static interpreter stdin sources for `bash -`, `sh -s`, implicit zsh stdin, and wrappers. Opaque or unsupported stdin forms fail closed.
- Output redirection and ordinary mutation commands including `rm`, `cp`, `mv`, `mkdir`, `touch`, `ln`, and `tee`, including GNU target-directory forms.
- Git global options, `-C`, administrative/environment/config paths, worktree operations, existing operands, and conservative unknown-verb handling.
- SwiftPM package/output paths.
- GNU Make split/attached `-C` and `--directory`, all supported `-f`/`--file`/`--makefile` spellings, Makefile-before/after-directory ordering, repeated directory changes, and multiple Makefiles. Relative Makefiles resolve against the final effective directory.
- Promotion targets such as install, install-copy, install-agent-safe, release, dmg, notarize, sign, appcast, promote, and deploy.
- Dynamic targets, unsupported shell state/control syntax, command/process substitution, unsupported wrapper forms, invalid Git targets, and unavailable Just semantics fail as `worktree_target_unresolved`.

## Ownership identity and lifecycle

- Canonical path resolution standardizes dot/dot-dot and resolves symlinks through the deepest existing ancestor.
- Stable IDs distinguish primary and linked worktrees and survive ordinary commits and worktree moves.
- Process-local reservations plus secure POSIX record locks provide deterministic multi-worktree exclusion.
- Authorization revalidates live identity and durable owner state after permit acquisition.
- Expired claims remain durable stale metadata; explicit evidence-preserving release/recovery is required.

## Explicit read-only compatibility

Dedicated `git_status`, `git_diff`, `git_log`, `git_show`, and `git_blame`, pure patch checks, edit previews, and recognized read-only shell Git forms remain available without a claim.

## Exclusions

C0 does not install, merge, push, release, tag, delete worktrees, automatically reclaim stale work, provide multi-Mac distributed locking, or implement Packet Runner orchestration.
