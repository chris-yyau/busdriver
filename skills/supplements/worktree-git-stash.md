---
name: worktree-git-stash
description: Why `git stash` is unsafe inside git worktrees — refs/stash is shared across all linked worktrees, so a sibling pop can corrupt your tree
targets: busdriver:using-git-worktrees, busdriver:parallel-execution-optimizer, busdriver:claude-devfleet, busdriver:dispatching-parallel-agents
type: supplement
source: get-shit-done #3542 (adapted)
added: 2026-05-29
---

# Red Flags: `git stash` Inside a Worktree

> Load alongside any skill that runs work inside a `git worktree` — especially when multiple agents operate in sibling worktrees concurrently.

## The Hazard

Git stores stashes at `refs/stash` in the **shared** parent `.git/` directory (the `--git-common-dir`), **not** per-worktree. The stash list is therefore global across the main checkout and every linked worktree.

Consequence: a `git stash pop` (or `apply`) run inside one worktree silently applies WIP that was pushed from a **different** worktree's session. This produces:

- phantom `UU`/`UD` merge-conflict states in a tree you never touched,
- untracked files that "appear from nowhere",
- a broken worktree-isolation invariant that is very hard to debug.

This bites precisely the topology busdriver uses: `parallel-execution-optimizer` runs "multi-worktree implementation passes" and `claude-devfleet` dispatches "each agent in an isolated git worktree."

## Rule

**Never `git stash` inside a worktree.** Treat the whole `git stash` family (`push` / `pop` / `apply` / `drop`) as prohibited in any multi-worktree or parallel-agent context.

## Sanctioned Alternatives

- **Need to set work aside:** commit to a throwaway branch you own — `git checkout -b wip/<task>` then `git add -A && git commit -m wip`. Use `git add -A`, **not** `git commit -am` — `-a` stages only already-*tracked* files, so new untracked files would be silently dropped and lost on a later reset / cherry-pick (the same data-loss class this supplement warns against). Reset / cherry-pick later. Per-branch refs are namespaced safely across worktrees in a way the single shared `refs/stash` is not.
- **Need another ref's version of a file (read-only):** `git show <ref>:<path>` or `git diff <ref> -- <path>`. No working-tree mutation, no shared state.

Single-checkout flows that use stash deliberately (e.g. `/checkpoint`) are unaffected — this prohibition is scoped to worktree / parallel-agent contexts.
