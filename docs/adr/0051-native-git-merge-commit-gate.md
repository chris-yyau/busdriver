# ADR 0051 — Litmus enforcement for native Git merge commits

- **Status:** Accepted
- **Date:** 2026-09-04
- **Issue:** #622
- **Supersedes / amends:** nothing. Sits alongside ADR 0050 (ref fast-forward gate),
  which covers the *no-commit-object* half of the same class.

## Context

`pre-commit-gate.sh` is a PreToolUse hook that pre-filters on the command string
for `*git*commit*`. A conflict-free `git merge` auto-commits internally and its
command string carries no `commit` token, so the gate never evaluates and the
merge commit lands unreviewed. #622 records the observed pair from the #620
grind: `04aaa327` conflicted, needed an explicit `git commit`, and was reviewed;
`86dc8717` was conflict-free and was not. Whether content got reviewed came down
to whether git happened to need a manual commit step.

Two layers are broken, not one. Widening the shell pre-filter alone changes
nothing: `gitcmd_detect.py`'s `_scan_commit` exact-matches the subcommand against
the literal `commit`, so the hook would invoke Python and allow the merge exactly
as before — a fix that looks like a fix and enforces nothing.

Verb enumeration does not terminate. The same verb both does and does not create
a commit depending on flags (`merge` vs `merge --no-commit` vs `--abort` vs
`--continue`; `cherry-pick -n`; `revert -n`), so a verb list is really a per-verb
option classifier that grows with git and is wrong in both directions.

## Decision

Enforce on the **effect** — a ref moving to a commit the repository cannot show
was reviewed — using Git's own `reference-transaction` hook as the observation
point, and leave the PreToolUse `git commit` block untouched.

`hooks/gate-scripts/merge-reference-transaction-gate.sh` decides at the `prepared`
phase — the only phase whose non-zero exit aborts the transaction. It drains the
whole transaction, decides once, and refuses a branch-tip update to a merge
commit unless a pending claim — written by the commit-chain gates from a
validated `litmus-passed.local` marker — binds that exact `HEAD`, staged tree and
`MERGE_HEAD` set. It also runs at `aborted`, where it does no gating at all: it
only releases the spent-marker bookkeeping for a transaction git rolled back. It
takes no action at `committed`, the only
other phase git defines.

Marker and claim **consumption** stays where it already was, in the commit-chain
hooks (`merge-post-commit-consume.sh` on `post-commit`,
`post-merge-consume-marker.sh` on `post-merge`). Those run after the commit
object exists and cannot veto it, which is why they consume rather than decide.

This is prevention, not detection: `prepared` runs before the ref moves, so an
unauthorized merge tip is never published.

## Alternatives

- **Widen the pre-filter / enumerate committing verbs.** Rejected: needs the
  per-option classifier above, is a treadmill, and over-blocks `--no-commit` and
  `--abort` while still missing variants.
- **PostToolUse "HEAD moved without a marker" check** (the issue's own
  suggestion, and the recommendation in its second comment). Rejected as the
  primary mechanism because it is detection after the fact; `reference-transaction`
  gives the same verb-agnostic coverage *before* the ref moves, for the same
  absence of enumeration. The second net that comment identifies —
  `pre-pr-gate.sh` reviewing the merge-base-anchored `base...HEAD` diff — still
  stands behind this gate; it is why the residuals below are acceptable.
- **Read-enumeration** (list the subcommands that *cannot* commit, unknown fails
  closed). Rejected: it gates a long tail of innocuous git commands for the whole
  duration of a pending review, and it cannot reuse `cmdword.py`'s `reads` set,
  which classifies `add`/`commit`/`push` as reads — the opposite of what a
  commit-creation classifier needs.

## Consequences

- `git rebase` and `git am` are **out of scope (#783)**: they fire no
  commit-chain hook and have no `--no-commit` two-step form, so no marker can
  bind to content git has not produced yet. What that means at runtime differs
  between the two, and the difference is worth stating exactly because it is a
  claim about a boundary — both were run against the installed hook:
  - `git rebase` onto a diverged upstream **aborts fail-closed** (`rc=128`,
    "refusing unauthorized merge commit"). The rewritten tip is not a successor
    of the old one, so it reaches no allow rule.
  - `git am` **is allowed**, and is not refused at all. It appends an ORDINARY
    single-parent commit whose first parent is the old tip, which is exactly
    the shape the successor rule permits by design — this gate authorizes merge
    tips, and an ordinary successor publishes no merge. The commit it lands is
    unreviewed, but it is unreviewed the way any `git am` is: no `git commit`
    runs, so the PreToolUse commit gate does not evaluate either. Closing that
    is #783's subject, not this gate's, and it is a gap in the ordinary-commit
    path rather than in this one.
- `cherry-pick` and `revert` are in scope via their `-n` two-step form, which
  stages without committing and so yields a bindable staged diff.
- The adjacent ref-layer classes stay split and are **not** started here:
  #779 (fast-forward, shipped as ADR 0050), #780 (ZERO old-oid force-update),
  #781 (ref creation at unreachable content), #782 (`PASS-MERGE` parent
  laundering), #783 (rebase / `am`).
- The gate is only reached where the repository has `reference-transaction`
  support and the hook installed; `scripts/install-git-hooks.sh` owns that, and
  installs the RT gate alongside the five commit-chain hooks rather than in
  place of them.
- **The installed wrapper pins the gate closure by digest.** Unlike a PreToolUse
  hook, which evaluates before the command mutates anything, `pre-merge-commit`
  and `reference-transaction prepared` run AFTER git has updated the worktree.
  Where the gated repo IS the busdriver checkout — `PLUGIN_ROOT == REPO_ROOT`,
  the documented default invocation — the merge being gated would otherwise
  supply the gate's own code, and hostile branch content could turn both gates
  into no-ops before either evaluated. That is the "gate scoped by input the
  gated party controls" anti-pattern, so the installer digests every file under
  `hooks/gate-scripts/**` (the whole closure: the six gates source only
  `$_SCRIPT_DIR/lib/`) and embeds both the digest and the checking code in the
  generated wrapper, which lives in the hooks directory and not in the worktree.
  A mismatch refuses to `exec` and names the reinstall. It is a LISTING digest,
  so an added or deleted file is caught, not only an edited one. The wrapper
  then execs a **snapshot** of the verified tree, kept beside it under
  `<hooks dir>/.busdriver-gates/<digest>/` and refreshed whenever the digest
  changes. Hashing by pathname and then re-opening by pathname are two separate
  reads, and only the first is verified; a writer racing that window executes
  bytes the digest never saw. Exec-from-snapshot closes it — verified bytes and
  executed bytes become the same bytes — and it is why source-adjacent bytecode
  needs no special handling. An UNCHECKED hash-based `.pyc` executes in place of
  its `.py` without Python reading the source at all (measured — the source says
  `SOURCE`, the interpreter prints `HOSTILE-BYTECODE`), which while the wrapper
  still exec-ed the live tree was a real bypass and forced the digest to PURGE
  `__pycache__` rather than exempt it. From the snapshot, `$_SCRIPT_DIR` resolves
  inside the snapshot, so libs are sourced and bytecode written there; the live
  tree is only ever hashed, never imported, and planted bytecode is inert where
  it lies. The purge is therefore gone, and with it the race it created with
  concurrent gate runs sharing one plugin root. `-X pycache_prefix=<dir outside
  the tree>` also survives `-I` and was measured to block the planted bytecode,
  but it was rejected before the snapshot existed and remains rejected: it has to
  be added to every python invocation in every gate, and missing one silently
  reopens the hole. (`.gate-integrity.lock` keeps its `__pycache__` exemption —
  it is visibility, not prevention, and rescoping it is not this ticket's.)
  Snapshotting is NOT the "copy the scripts aside" option this ADR previously
  rejected: that one replaced the digest, so a stale install kept running the old
  gate silently, and on a repo whose gate scripts churn daily the gate you are
  developing is never the one running. Here the live-tree digest still runs
  first and still fails LOUD on stale — the snapshot only decides which bytes
  execute once staleness has been ruled out. The installer also refuses a
  `core.hooksPath` inside the work tree but outside the git dir: the wrapper
  carries the digest check, so a merge able to replace the WRAPPER skips the
  check entirely and pinning the gates behind it would be theatre — and it is
  what makes the snapshot's location trustworthy, since the snapshot sits in
  that same directory. Three further details the review rounds forced, each with
  a test: the snapshot is re-hashed AFTER the copy and rebuilt when it does not
  match the digest it is named by — hashing the live tree and copying it are two
  reads of two different moments, and a directory's name is not evidence about
  its contents; the snapshot is built after preflight, because pruning
  superseded snapshots is destructive and a preflight that then refuses would
  leave the already-installed wrappers pointing at a snapshot the refused run
  had deleted; and containment compares `(st_dev, st_ino)` rather than string
  prefixes, because macOS volumes are case-insensitive by default while
  `realpath()` preserves whatever spelling it was handed, so `<WT>/hooks` and
  `<wt>/hooks` are one directory that no prefix test relates.
  `tests/test-install-git-hooks.sh` proves it refuses an
  edit, an addition and a deletion, clears on restore, execs the snapshot rather
  than the live tree (a break planted in the snapshot alone is carried through),
  does not copy planted bytecode into the snapshot on re-pin, rebuilds a
  tampered snapshot, leaves working hooks intact when an install is refused, and
  refuses a case-variant path into tracked content.
- The gate validates the staged-diff hash with the canonical minting expression
  (#576), pinned against the other three hash-bearing files by
  `tests/test-litmus-marker-binding.sh`. A validator that spells the hash
  differently from the writer cannot authorize anything the writer reviewed —
  a non-ASCII path alone was enough to make every such merge unauthorizable.
- **Residual — the review token is only as one-use as the directory holding it.**
  Two paths consume the marker by INODE (`authorize_pass_merge` and the
  published-cleanup recovery in `clear_stale_abort_state`), so for those a
  rename-aside cannot survive the consume and be restored. The ordinary
  post-commit consumption in `consume_if_pending` still removes it by PATHNAME.
  A HARD LINK is caught on the inode paths — `_open_marker_for_consume` refuses
  `st_nlink > 1` outright, and `_finish_marker_consume` requires the held inode's
  link count to reach zero — so it survives only the pathname path. A plain COPY
  is bounded by nothing anywhere: fresh inode, one link, matching content. A
  writer who can create files in `.claude/` can therefore keep a token across a
  consume. What is guaranteed is narrower and worth stating exactly: no path that
  DECLINES to consume the token destroys it. `authorize_pass_merge` is the one
  place where a refusal can still cost a real review, and deliberately so — it
  consumes before it writes the claim, so a claim-write or tree-binding failure
  leaves the token spent and no authorization behind. That ordering is what makes
  the window unexploitable, and its failure mode is the fail-CLOSED one: rerun
  `/litmus`, never a merge that slipped through. The
  bound that would actually close reuse is the `SPENT` record under `.git/`,
  outside the writer's directory; extending it to cover minted-but-unspent tokens
  is deliberately not done here.
- Recovery from a refusal is terminal-side: run `/litmus`, or remove the hook.
  The block message names the ref, the `old→new` pair and why the claim did not
  bind.

## Revisit trigger

#780, #781, #782 or #783 landing; or litmus gaining a way to review a *proposed*
commit, which is what would let rebase/`am` be brought in scope.
