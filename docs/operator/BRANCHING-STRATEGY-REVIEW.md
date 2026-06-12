# Branching Strategy Review — 2026-06-12

Standing audit of the repo's branch/worktree state, the root cause of the
v3.7.10 connector divergence, and the cleanup + go-forward strategy. The
go-forward rules live in [`AGENTS.md` → Git & Release Hygiene → Branching
strategy](../../AGENTS.md); this file is the audit + the cleanup checklist.

## TL;DR

A feature branch (`feat/backend-remediation`) sat **25+ commits behind `main`**
with long-lived **uncommitted** work, and the **primary checkout was parked on
it** rather than on `main`. A second agent then re-implemented the cloud
connector *that was already shipped on `main`* (PKT-810) off that stale base —
duplicating effort and nearly regressing the v3.7.8 keychain fix. The fix was to
graft only the essential connector change onto `main` (shipped as v3.7.10). The
strategy below prevents a repeat.

## Current state (as of `main` @ v3.7.10 / `f38eafe`)

### Branches

| Branch | Behind main | Ahead of main | Status |
|---|---|---|---|
| `main` (local) | 29 | 0 | **stale** — never updated locally (primary checkout was on a feature branch) |
| `release/v3.7.10` | 0 | 0 | == main; delete after the release run succeeds |
| `feat/backend-remediation` | 26 | 0 | committed work already merged (v3.7.8); uncommitted connector work **superseded by v3.7.10** |
| `antigravity-config-rename` | 185 | **2** | only branch with unmerged unique commits — review before deleting |
| `feat/memory-wave2-pkt-977` | 44 | 0 | merged → delete |
| `fix/v3.7.8-credentials-securitygate` | 43 | 0 | merged → delete |
| `fix/wsf-server-side-token-exchange` | 23 | 0 | merged → delete |
| `feat/settings-redesign` | 29 | 0 | merged → delete (+ prune its worktree) |
| `worktree-agent-a73a27…` / `a9889…` / `adfdd…` | 26–28 | 0 | merged (v3.7.8) → delete (+ prune worktrees) |
| `integration/v3.7.8` | 6 | 0 | merged → delete |
| `fix/connector-static-bearer` | 2 | 0 | merged (v3.7.9) → delete |
| `backup/sprint-lead-20260609` | 45 | 0 | recovery snapshot, fully merged → delete |

**11 of 13 local branches are fully merged (0-ahead) — pure clutter.**

### Worktrees

| Path | Branch | Disposition |
|---|---|---|
| `/Users/keepup/Developer/the-bridge` (**primary**) | `feat/backend-remediation` | **Should be on `main`.** Holds another agent's uncommitted connector work — coordinate before switching. |
| `/Users/keepup/Developer/the-bridge-merge` | `docs/branching-strategy-workflow` | active (this review); prune when merged |
| `/private/tmp/bridge-redesign` | `feat/settings-redesign` | merged → prune |
| `.claude/worktrees/agent-a73a27…` / `a9889…` / `adfdd…` | merged agent branches | merged (v3.7.8) → prune (the other chat's; coordinate) |

## Root cause

1. **Stale base.** Work continued on a branch 25+ commits behind main without a
   rebase, so it diverged from — and re-derived — already-shipped code.
2. **Primary checkout off `main`.** Local `main` never advanced; "the main dir"
   wasn't main, which strands updates and invites edits to the wrong branch.
3. **Long-lived uncommitted work.** The connector rework lived uncommitted in a
   shared checkout — invisible to other sessions, so it was re-implemented
   instead of reused.
4. **No subsystem ownership.** Two agents independently rewrote the same
   connector/transport files instead of coordinating via PR.

## Cleanup checklist

> Safe = no uncommitted work, not another agent's active branch. Coordinate =
> touches another agent's uncommitted work or worktree; confirm with the owner /
> operator first.

**Safe now**

```bash
# Local main is stale (0-ahead, just behind). Re-point it at the trunk.
git branch -f main origin/main

# Delete fully-merged branches (0-ahead → nothing lost; the commits are in main).
for b in feat/memory-wave2-pkt-977 fix/v3.7.8-credentials-securitygate \
         fix/wsf-server-side-token-exchange integration/v3.7.8 \
         fix/connector-static-bearer backup/sprint-lead-20260609; do
  git branch -D "$b"        # also: git push origin --delete "$b" if pushed
done
```

**After the v3.7.10 release run succeeds**

```bash
git worktree remove /Users/keepup/Developer/the-bridge-merge   # this review's worktree
git branch -d release/v3.7.10 docs/branching-strategy-workflow
git worktree remove /private/tmp/bridge-redesign && git branch -D feat/settings-redesign
git worktree prune
```

**Coordinate first (another agent's work / the primary checkout)**

```bash
# feat/backend-remediation: its committed work is in main; its uncommitted
# connector work is superseded by v3.7.10. Once the owning agent confirms it has
# nothing unique left, reset the primary checkout to main:
#   (in /Users/keepup/Developer/the-bridge, after preserving any wanted WIP)
#   git stash -u || true   # or commit to a throwaway branch first
#   git switch main && git pull --ff-only
#   git branch -D feat/backend-remediation   # if truly done

# agent-* worktrees (a73a27 / a9889 / adfdd) are the other chat's, merged at
# v3.7.8 — that session should prune them:
#   git worktree remove .claude/worktrees/agent-<id> && git branch -D worktree-agent-<id>

# antigravity-config-rename is 2 commits AHEAD of main (unmerged) — review those
# 2 commits before deciding to merge or drop:
#   git log --oneline origin/main..antigravity-config-rename
```

## Go-forward strategy

See [`AGENTS.md`](../../AGENTS.md) for the canonical rules. In short: trunk-based
on `origin/main`; short-lived branches off **current** main; **rebase before
resume** (mandatory before connector/auth/transport/security edits); keep the
primary checkout on `main`; commit + push WIP daily; one owner per shared
subsystem per cycle; delete merged branches + prune worktrees after each release.
