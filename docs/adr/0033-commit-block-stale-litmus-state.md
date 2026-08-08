# ADR 0033 — The pr-grind commit block discards stale litmus state, gated on `terminal_status`

**Status:** Accepted
**Date:** 2026-08-06
**Issue:** #569

## Context

`run-review-loop.sh` deletes `litmus-state.md` **only on PASS**. Every other terminal
status — `review_findings`, `stall`, `infra_failure`, `setup_error` — leaves the file
behind with `active: true`.

`init-review-loop.sh` refuses to initialize while any state file is active, and that
refusal is deliberate: its own comment block records that `active: true` cannot
distinguish a KILLED run from a LIVE one, so auto-re-initializing would risk two
writers on one state file. It offers `--force` as the operator's remedy and prints a
three-way (a)/(b)/(c) menu asking the operator to pick based on what is actually true.

`scripts/dispatcher-commit-block.sh` called `init-review-loop.sh` with no arguments and
no recovery path. There is no operator in that loop to read the menu. So one non-PASS
review wedged the script for every later invocation, and the resulting envelope —
`{"bail_category":"judgment","bail_reason":"litmus init-review-loop.sh failed"}` —
read as an infra failure when the real cause was the previous round's state never
being cleared. Observed on the #567, #577, and #579 grinds; each time the only recovery
was hand-editing `active: false`.

The same file also leaks across the `gh pr create` → pr-grind boundary. The pre-PR gate
leaves a **pr-mode** state file, and `run-review-loop.sh` lets a state-file `review_mode`
OVERRIDE `$LITMUS_MODE` — so a commit-round that inherited it would silently review
`base...HEAD` instead of the staged diff.

## Decision

Supply the discriminator the guard lacks — **`terminal_status`** — and force on it.

That required making the field mean what the block needs it to mean. Two changes in
`run-review-loop.sh` complete the contract:

- **It is cleared when a run starts** — before the setup steps, not after. Previously a
  resumed loop (status `FAIL`, operator fixed the findings, ran the script again) carried
  the previous iteration's `terminal_status` for the whole of the next review, so a live
  review read as finished. Clearing makes presence mean "*this* run ended", not "some run
  once ended". The call sits ahead of CLI resolution and the git/diff checks because
  those are quick but not instant, and the field is stale for every microsecond it
  survives; `clear_terminal_status` self-guards on `active: true` so it can sit that
  early without mutating a file this run will not review.
- **The `TOO_LARGE` (exit 2) path now records one**, and records it *before* the advisory
  `suggest-split.sh` call. It was the single non-PASS exit that left the state file behind
  with no `terminal_status` — every other path either records one or deletes the file.
  Without this, a size failure wedged every later invocation exactly the way #569
  describes. The ordering matters because the script runs under `set -e`: with the write
  after the helper, a `suggest-split.sh` failure exits first and the status is lost again.

With that, the block's rule is simple, and it reaches for `--force` as late as possible:

1. Run the **ordinary** `init-review-loop.sh`. With no state file, or a completed one, it
   succeeds — and that round never involves `--force` at all. Since `--force` exists only
   to override the active-state guard, asking for it before that guard has fired would
   put its overwrite risk on every ordinary round for no benefit.
2. Only on refusal, consult `terminal_status`. A **recognized** value — matched against
   `run-review-loop.sh`'s own allowlist, not merely the presence of a `terminal_status:`
   line — proves the most recent run reached its end, and the block retries with
   `--force`. Empty, `null`, unknown, or malformed values are not evidence of anything;
   treating any such line as proof would let corrupted state authorize a force, a
   fail-open on the one check standing between this script and a live review.

Absent on an `active: true` file → a review running right now, one initialized and not
yet started, or one killed before it could record its outcome. Indistinguishable without
a clock, so the block bails and names the remedy. The `FAIL` →
`terminal_status: review_findings` case, which is every occurrence observed in #569,
stays fully automatic.

Forcing is sound *for this caller specifically*: the block owns one self-contained review
per invocation against a fresh staged diff, and a litmus FAIL ends the grind, so no
iteration history is ever worth carrying forward.

Separately, the FAIL/stall bail envelopes now carry the findings, parsed from litmus's
captured stdout (`  [severity] file:line - description`), bounded to 10 findings and
1500 characters.

## The lock: why classification alone was not enough

Reading `terminal_status` more carefully does not make the answer survive to the next
line. Classify-then-force is check-then-act, and between the two a review can start,
resume, or clear the very status just read. No amount of care in the classification
closes that; only holding something across both does.

So `skills/litmus/scripts/lib/review-lock.sh` is taken by **every writer of
`litmus-state.md`**, without exception — a mutual-exclusion contract that some writers
opt out of is not a contract:

- `run-review-loop.sh` holds it for the lifetime of a run.
- `init-review-loop.sh` holds it while it rewrites the state file. It is the most
  destructive writer of the three (with `--force`, unconditionally), so leaving it
  outside the contract would have let an operator reset the state file out from under a
  running review.
- The commit block holds it across classify-and-init, releasing just before invoking the
  reviewer, which takes it itself.

Because interactive `/litmus` goes through these same scripts, it participates too,
which is what makes the guarantee real rather than dispatcher-only.

Holders that shell out to another lock-taking script export their pid
(`review_lock_export_owner`), and an inherited owner counts as ours — otherwise the
dispatcher calling `init-review-loop.sh`, or `--auto-pr-review` doing the same, would
deadlock against itself. A child never releases a lock it merely inherited. This is
cooperative, like the lock itself: a correctness mechanism between our own scripts, not
a boundary against a hostile caller, who could simply unlink the lock.

The acquire is **`symlink(2)`**: it creates the lock *and* publishes its owner in one
atomic operation — the pid rides in the link target. An earlier `mkdir`-based draft
needed a second write to record ownership, and in that window the lock existed with no
owner, so a concurrent process read it as an orphan and reclaimed a **live** lock.

It is taken **before** the `--auto-pr-review` branch, not after. That branch runs
`init-review-loop.sh --force` and then re-execs; acquiring afterwards would let an
auto-PR invocation reset `litmus-state.md` out from under a review that already owns the
lock, and fail only once the damage was done. `exec(2)` preserves the pid, so the
re-executed image finds the lock already its own and proceeds.

**There is no automatic reclaim of an orphaned lock**, and that is the most important
decision here. Every shell-level reclaim is a race:

- `rm` + create loses arbitration outright — of two processes that both judge the lock
  orphaned, the loser deletes the *winner's* fresh live lock and takes it.
- `mv` + create looks atomic but is not: `rename(2)` moves whatever occupies the *path*,
  not the specific symlink that was inspected. The winner replaces the orphan with its
  own live lock; the loser's `mv` then carries that away and installs its own. Both
  return success.
- Verify-after-move needs an undo, and the undo races the next acquirer.

There is no compare-and-swap on a path in POSIX shell. So an orphan is *reported* — with
its owner's liveness and the exact path — and a human unlinks it. `kill -0` informs that
message but never a decision, because pid reuse would otherwise let an unrelated
long-lived process make an orphan look live forever, wedging reviews permanently.

Release only ever unlinks a lock we still own, so a bail can never drop a successor's.

Acquisition distinguishes **contention** from an **unusable state directory**. If the
symlink cannot be created and nothing occupies its path, that is a missing or unwritable
directory, not a concurrent review — reporting it as contention would send the operator
hunting for a lock that does not exist.

The honest tally: this lock went through a `mkdir` draft, a `pgrep`-probe draft, and a
`rename`-reclaim draft, each corrected and each revealing the next defect. What survives
is the smallest thing that cannot be wrong — atomic acquire, no reclaim.

## Alternatives considered

**Resume the paused loop via `run-review-loop.sh` instead of re-initializing.** Keeps
the iteration counter and the reviewer's history of already-fixed issues. Rejected: a
litmus FAIL bails the whole grind, so the *next* invocation is a different grind against
a different staged diff. Resuming would feed the reviewer history from unrelated code.
It also inherits the leaked `review_mode` — the wrong-diff failure above.

**Keep `active: true` as the signal and bail on it.** That is the status quo, and it is
precisely the bug: the signal cannot distinguish stale from live, so it is wrong in the
overwhelmingly common case (stale) to protect the rare one.

**Make `run-review-loop.sh` clear `active` on every terminal status.** Fixes the leak at
the source, but breaks the interactive `/litmus` contract, where a FAIL state file *is*
the paused loop the operator resumes with their fixes. Wrong layer.

**Have the block honor an existing fresh, diff-bound PASS marker instead of re-reviewing**
(issue #569's third suggestion). Removes a nondeterminism re-roll, but it is a
review-skipping change on a gate path and deserves its own decision. Not taken here.

## Consequences

- The block recovers unattended from the stale states that wedged it in practice.
- **A hard-killed review that never recorded a `terminal_status` bails instead of
  recovering automatically.** That is the price of not clobbering a not-yet-started
  interactive review, and the bail message names `init-review-loop.sh --force` as the
  remedy.
- The findings text is best-effort: it is parsed from litmus's rendered stdout, so a
  change to that render format degrades the envelope to
  `(none parsed from litmus stdout)` rather than failing. The gate decision never
  depends on it.
- `BUSDRIVER_STATE_DIR` is normalized in the commit block with the **same** rule
  `run-review-loop.sh` applies. This is agreement, not defence in depth: if the two
  normalized differently, an absolute or traversal value would have the block classify
  and initialize one state file while the reviewer consumed another.
- The lock is cooperative. It binds the scripts that take it, which is sufficient only
  because every script that writes `litmus-state.md` now does. A future writer that
  skips it reopens the race silently — hence the revisit trigger below.
- **A SIGKILLed review leaves a lock that a human must remove**, and the block bails
  `env` naming the path until they do. This is a real cost, accepted deliberately: the
  alternative is a reclaim race that silently permits two concurrent reviews on one
  state file. A visible stall beats silent corruption.

## Revisit trigger

- A new writer of `litmus-state.md` appears that does not take the review lock. The
  lock's guarantee is only as broad as its adoption, and a non-participating writer
  reopens the race with no visible symptom.
- `litmus-state.md` gains a field that distinguishes "killed mid-review" from
  "initialized, not yet started", which would let the remaining bail case recover
  automatically too.
