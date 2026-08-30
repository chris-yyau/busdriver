# ADR 0050 — Ref fast-forward gate for protected branches

- **Status:** Accepted
- **Date:** 2026-08-30
- **Issue:** #779
- **Supersedes / amends:** nothing. Sits alongside ADR 0049 (contained hook launch).

## Context

Every review gate in this repository hangs off a **commit**. `pre-commit-gate.sh`
matches `git commit`; litmus mints `PASS-MERGE` inside `if git rev-parse
MERGE_HEAD`; `pre-pr-gate.sh` and `pre-merge-gate.sh` key on `gh` subcommands.

A **fast-forward creates no commit object**. `git pull --ff-only`, and any `git
merge` whose target is a descendant of HEAD, move the branch ref and nothing
else. So a fast-forward of `main` to commits litmus never reviewed passes the
entire pipeline unseen:

- `pre-commit-gate.sh` never fires — there is no `git commit`.
- The only merge-shaped token litmus can mint, `PASS-MERGE`, requires
  `MERGE_HEAD`, which a fast-forward does not create.
- That token is `^PASS-MERGE-[0-9]+$`. It binds no repository, ref or oid, so
  even if it could be minted it could not authorize a *specific* ref move.

#779 states this as "no hook and no mintable marker". Both halves are real: there
is no observation point, and no marker form that could express the permission.

## Decision

Add a PreToolUse Bash gate, `hooks/gate-scripts/ref-ff-gate.sh`, and a
`git_ref_op()` detector in the shared `lib/gitcmd_detect.py`. On a protected
branch there is **exactly one way past**, and it is deliberately narrow:

> An operator-written `.claude/ref-ff-authorized.local` containing exactly
> `PASS-FF refs/heads/<branch> <oid>`, spent by a `git merge --ff-only <oid>`
> that names that same full object id.

Single-use, consumed at authorization, every use appended to `bypass-log.jsonl`
through `lib/audit_append.py` (a failed append blocks). Both `.local` files this
gate introduces are in `marker_check.py`'s forge guard, so no tool call can write
or delete them.

Everything else on a protected branch is **refused**, including shapes that would
otherwise look benign:

| Refused | Why |
|---|---|
| `git pull`, in every form | The commit it lands does not exist locally when the gate runs, so nothing can bind an authorization to it. |
| A merge without `--ff-only` | Only the literal flag makes git enforce fast-forward-or-fail at run time. |
| A merge naming a symbolic ref | Git re-resolves it when the command runs; the authorization would bind the gate's observation, not the ref move. |
| Any companion command | The gate resolves its target before the command runs, so anything else in the same call can replace what it checked — including which branch is checked out. |
| An annotated tag, an octopus, a diverged branch | Not the fast-forward shape this gate evaluates. |
| A git word that resolves to no command or alias | An alias defined through the environment is invisible here and could be `merge`. |
| A repo where no protected branch can be identified | See "empty set" below. |

### Why there is only one route

Two automatic routes were built, tested, and **deleted**. Recording why is the
main purpose of this ADR — both look reasonable, and both will be proposed again.

**1. Remote provenance** — "the target is already reachable from
`refs/remotes/<remote>/<protected>`, so it came through the PR pipeline."
Deleted: that voucher is a *local* ref. `git fetch <remote>
<unreviewed>:refs/remotes/<remote>/<protected>` installs any commit as the
voucher without moving a branch, and nothing local distinguishes a planted one.
Re-asking the remote (`git ls-remote`) would put a network round-trip inside a
10s PreToolUse budget and block every offline merge.

**2. A pull restricted to a fast-forward** — "git re-fetches and `--ff-only`
makes a moved remote fail, so the *shape* is guaranteed." The shape was; the
**source** never was. Each candidate for authenticating it reads an input the
gated party controls:

- `branch.<p>.remote` is a name this repository picks.
- `git remote get-url` is a URL this repository picks.
- A remote's published HEAD does not separate a fork from anything. *Measured on
  git 2.55:* `git remote add fork <url> && git fetch fork` creates
  `fork/HEAD -> fork/main` by itself, and a real GitHub fork's default branch is
  `main` too. This check was written, run, and removed rather than shipped as
  assurance it cannot give.
- An operator-declared canonical URL in a non-repo-controlled file came closest
  and still fails: `url.<x>.insteadOf`, set through the `GIT_CONFIG_COUNT`
  family, rewrites the transport underneath a URL that compares equal — and that
  family is stripped from the gate's environment and not from the command's.

A committed `.claude/settings.json` `env` block reaches session environment
(#325), so this is not merely the earlier-command class: the input is
repo-reachable. The marker route is the only one whose guarantee survives an
environment the gate cannot read — a full object id resolves to itself, a
command-line `--ff-only` outranks every configuration source git has, and no
fetch means no URL to rewrite. **The gate authorizes nothing it has to predict.**

### The empty set

Protected branches are discovered from every remote's HEAD, then
`init.defaultBranch`, then the conventional names (`main`, `master`, `trunk`,
`develop`, `development`, `default`) that exist locally, then
`.claude/ref-ff-protected.local`.

If that set comes out **empty**, the gate **blocks**. It used to allow, and that
was its one non-fail-closed point — and the lever every mutable-discovery
objection pulled, since deleting the remote HEAD a non-conventional default was
found through empties the set. The escape is the declaration file, and its
*existence* is the operator's statement: a file listing branches names them; an
empty file says "this repository has no protected branch" deliberately. Absence
of the file is not that statement.

Two precisions, both load-bearing. An empty file is a statement only about a repo
where nothing was discovered — it does **not** un-protect a branch that WAS
found, or it would be a general bypass. And a file naming only branches that do
not exist is a **typo**, not a statement: unvalidated it left the set empty just
as an empty file does, so one mistyped character disabled the gate silently.
Declared names are existence-checked exactly as discovered ones are, and a name
that does not resolve blocks on the spot rather than quietly guarding less than
was asked. The file has **no comment syntax**: `#release` is a valid branch name,
so treating `#` as a comment dropped a declared branch silently.

The file is held to the same standard as the authorization marker — an untracked,
non-symlink regular file, checked with `gate_skip_file_repo_controlled`. It has
to be: a declaration naming no branch turns the gate off, so a repository able to
commit one could disable its own enforcement. Consent by **location**, never by
content (ADR 0012's rule, and #325's lesson).

## Deviation from the issue text

**#779 names git's `reference-transaction` hook as the observation point, and it
is right.** That is where a ref update is genuinely visible, with the actual
`(ref, old_oid, new_oid)` tuple, after git has interpreted its own environment
and configuration.

This ADR does not build it, for one reason: that layer needs a **git-hook
installer**, which does not exist on `main`. `scripts/install-git-hooks.sh`,
`validate-staged-litmus-marker.sh` and `tests/test-merge-commit-gate.sh` — all
cited by the issue — belong to **#622's branch**, which this work must not touch.
A second installer here would duplicate that work and guarantee a conflict.

So the bypass is closed at the layer that *does* exist — the PreToolUse Bash hook
every other busdriver gate uses — against the vector that matters today: the
agent's own Bash calls. **The marker form defined here is exactly what a
`reference-transaction` hook would consume unchanged**, so migrating later is a
move, not a redesign.

## Consequences

### New friction, protected branch only

1. **Advancing a protected branch locally always requires an operator marker.**
   `git pull` on `main` is refused outright. The flow is `git fetch`, then
   `git rev-parse FETCH_HEAD`, then the operator writes `PASS-FF
   refs/heads/main <oid>`, then `git merge --ff-only <oid>`.
2. **A merge or pull must be the only command in its Bash call** (a leading `cd`
   aside).
3. **A repo with no identifiable protected branch blocks** until the operator
   declares one, or declares none with an empty file.

This is the sharp end of the decision and the part to revisit first if it proves
unworkable in daily use. It is deliberate: a protected branch that can be moved
without saying so is the thing #779 is about.

### Accepted residuals

Each is bounded the same way — **every operation it permits was permitted before
this gate existed, and none of them weakens a case the gate does block.**

| Residual | Owner |
|---|---|
| A pre-exec gate reads HEAD at dispatch; a *concurrent* process could retarget HEAD before the authorized merge runs, spending a marker minted for one branch on another. Nothing in the command can do it — a companion is refused — so it takes an outside writer. This is the standing limit of every PreToolUse gate here, and precisely what the `reference-transaction` hook would close. | #779 follow-up, after #622 lands an installer |
| Ambient `GIT_DIR`, `GIT_WORK_TREE`, `GIT_NAMESPACE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES` and the `GIT_CONFIG_COUNT` family are stripped from the gate by the contained launch and retained by the command, so the command can act on a different repository or object graph. The gate cannot see that it happened. Closing it means the **launcher** forwarding a trusted "ambient git scope was set" flag — `contained-launch.sh`, shared by every gate in this directory, so the repo resolution **every** gate here performs has the same exposure. | #777 / ADR 0049 (R3) |
| A colon refspec that writes a ref with no checkout — `git fetch . HEAD:main` (moves the branch outright), `git fetch <r> <x>:refs/remotes/<r>/<p>` (forges a remote-tracking ref) | #780 / #781 |
| Discovery through remote HEAD and `init.defaultBranch` is mutable by a separate command. The conventional-name list is not, and the declaration file is forge-guarded, so the durable answer for a non-conventional branch is to declare it. An actor who can delete a remote HEAD can equally run `git update-ref refs/heads/<b> <oid>`, which moves the branch in one command — so this hands them nothing new. | #780 / #781 |
| Downstream execution generally: the gate authorizes one ref move and cannot see what git runs afterwards. The case needing **no shell access at all** — `git merge` running `post-merge`, where the landed content can BE the hook — is **closed for the marker route**. The question is asked as "which file will git execute" and answered with git's own `rev-parse --git-path hooks` — it honours `core.hooksPath`, and it is right in a **linked worktree**, where the hooks git runs live in the common dir and a hand-composed `<absolute-git-dir>/hooks` names a directory that does not exist. Each path COMPONENT is then judged where it lives before it is followed, so a symlink at any level, `..`, an ancestor link, and a link whose target this merge creates all count. Containment is *inside the worktree but not inside the git dir*, decided by name **and by dev+inode**: `realpath` does not collapse a macOS firmlink, so a second spelling of one directory would otherwise read as safely outside. An ordinary `.git/hooks/post-merge` file is fine; the same name as a symlink into the tree refuses. Spelling-only versions were tried and each leaked | closed for the marker route |
| The gate's own 10s deadline. Expiry is not a block — the runner kills the hook before it can emit anything, so a gate that runs long is a gate that is not there. Every bound in the script (payload bytes, remote-listing bytes and count, declaration length) exists to keep the work under that deadline, and each was added because an unbounded read was reachable from repo-controlled state; none of them makes the deadline itself safe, because git parses config before this script decides anything. Closing it means the RUNNER treating a hook timeout as a block, which a hook cannot do for itself | stated, not closeable from here |
| A SECOND MOUNT of an in-tree subdirectory — a bind mount of `<repo>/.githooks` at `/mnt/hooks`, with `core.hooksPath` naming the outside spelling. Containment climbs to the worktree root by dev+inode, and such a mount shares the *subdirectory's* inode, never the root's, so it reads as outside. Closing it would mean scanning the tree for a matching inode on every check. Like the ambient-`GIT_DIR` row above it is machine state the gate cannot see — not something the incoming content can arrange | stated, not closed |
| The command's own resolution of `git` — ambient `PATH`, `BASH_ENV`, exported shell functions. The contained launch (`#!/bin/bash -p`) hardens the GATE, never the gated command | #777 / ADR 0049 (R3) |
| Parser evasion by an actor with shell access — an interpreter payload, a script file, a dispatcher. The same residual `gitcmd_detect`'s docstring already carries for `git_commit` and `gh_pr`. | accepted, stated in the detector's THREAT MODEL |
| The marker is **detection, not prevention**, on the same terms as `design-clear.sh --yes` | ADR 0017 / ADR 0031 |

### Out of scope by decision

Non-FF merges and `merge -s ours` laundering (#622, #782); force-updates,
`update-ref`, `branch -f`, `checkout -B` (#780); ref creation (#781);
`rebase` / `am` (#783). `--squash` is allowed — it moves no ref, and
`pre-commit-gate.sh` owns the `git commit` that follows.

## Alternatives considered

- **`reference-transaction` hook now** — correct layer, needs #622's installer.
  See the deviation above.
- **`git ls-remote` to verify provenance** — a network round-trip inside a 10s
  PreToolUse budget, and it blocks every offline merge. Worse than the residual
  it closes.
- **Gate the ref-writing commands too** — that is #780/#781, explicitly out of
  scope for this change.
- **Persist discovered protected branches in a gate-owned file** — a fifth state
  file and a new write path, to close a hypothetical in repositories that do not
  exist yet. The empty-set block closes the same lever with no new state.

## Revisit trigger

Any of:

1. **#622 lands a git-hook installer.** Move the marker check into
   `reference-transaction`; the marker format does not change.
2. **The friction proves unworkable** — if the marker flow is being reached for
   several times a day, the answer is a better-evidenced automatic route, not a
   skip file. Nothing in this ADR's analysis found one, so a new route needs new
   evidence, not a new argument.
3. **ADR 0049 R3 / #777 closes**, making the command's git environment visible to
   the gate. Two residuals above collapse if it does.
