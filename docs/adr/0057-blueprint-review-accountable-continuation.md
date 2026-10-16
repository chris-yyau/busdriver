# ADR 0057 — blueprint-review continues a stopped review instead of resetting it

## Status

**Proposed (2026-10-14).** Design: `docs/plans/2026-10-11-blueprint-review-continuation-history-design.md`
(issue #948, prerequisite to #947). The design was parked by its own native review at
iteration 3 and could only be assessed read-only: three B4.1 runs, the last
`DESIGN_ASSESSMENT_READY` with FULL 3/3 coverage on SHA `e01318ec`. That is a readiness
label, not a `design-reviewed: PASS`. The implementation was written under an
operator-created skip lease, because the review that would pass the design needs the
`--continue` this ADR adds.

## Context

When the loop parks a review (`parked_no_progress`) or stops it at its ceiling
(`max_iterations_exceeded`), SKILL.md said "fix the findings and re-run". Both re-run
paths erase what the stop recorded:

- re-running the loop on the parked state never counts the parked attempt, resets
  `medium_issues_history` at the :1889 stint boundary, and deletes the stopped round's
  artifacts in the iteration cleanup;
- a fresh init rewrites the state to iteration 1 with empty histories.

So the trajectory check that parked the review could be undone by following the
documented advice, and #947's parked review had no honest way forward.

## Decision

1. **One entry point:** `init-design-review.sh --continue <design_file> [--max-iterations N]`.
   Init owns the pointer and the state, so continuing is the explicit alternative to
   initialising. The loop gains no mode.
2. **Close both resetting paths.** A fresh init refuses a slug that carries the park
   signal, the ceiling signal, or a continuation that has not passed. The loop refuses a
   park or ceiling state, and any leftover of a killed `--continue`, before it snapshots,
   cleans up or writes.
3. **Continuing counts and carries.** A park is counted once (`iteration + 1`); a ceiling
   raise is explicit and recorded; every history is carried; a write-site uncountable park
   drops its placeholder `0`. The blocker to carry is persisted by the loop at park time
   (`pre_park_progress_status`, with a `pre_park_recorded` marker); legacy states derive
   it, and the one ambiguous legacy shape is refused rather than guessed.
4. **Evidence before enforcement.** The stopped round is staged, hashed into
   `MANIFEST.sha256`, verified, built into a temporary state, published as
   `attempts/<NNN>-<run_id>/`, and only then committed by one `mv`. A single trap-installed
   rollback undoes everything this run created before the commit. One ledger line follows.
5. **The next verdict needs a full round.** `fresh_round_required` refuses `--claude-only`
   until a full round clears it once all its reviewers have finished, and `--claude-only` also refuses the stop
   `run_id`.
6. **The shared pointer.** The loop re-reads the pointer on every state write, and
   `active` cannot tell a finished review from a running loop. So `--continue` refuses
   whenever the pointer names another review the loop could still run (anything but a
   park or ceiling signal), refuses one changed in the last 10 seconds (a parking loop's
   last writes come after its signal), and re-checks under its lock.
7. **Beyond the frozen design (litmus review).** Every `--continue` and every fresh
   init also holds `docs/reviews/.continue.lock` from its pointer check through its
   pointer write, so neither can move the pointer under a continuation that has just
   committed. `--continue` defers INT, TERM and HUP to checkpoints at which every path
   it created is recorded, so a signal never orphans an archive or undoes a commit; a
   commit `mv` killed after its rename counts as committed, since its temp state is gone.
   Each lock and the archive destination are claimed by a `mkdir` that ignores those
   signals, so a process-group signal cannot leave a claim the run never recorded.
   `mark_review_complete` writes `status` and `active` in one write, the loop's last
   state write at a park or ceiling; `--continue` treats a park as finished only once
   its loop has exited (decision 9). Fresh init repeats its
   refusal under the lock, right after `check_existing_review` and before any cleanup,
   so a loop that parks in between is not reset. An empty slug, and a symlinked review
   directory, `docs/reviews` or `docs`, or a symlinked pointer file, are refused.
8. **The loop pins its review directory (approved after litmus round 7).** The loop
   resolves the pointer once at start, under `docs/reviews/.continue.lock`, and every
   later read and write uses that directory, so a pointer moved by init or `--continue`
   never redirects a running loop. This removes the premise of decision 6; its refusals
   stay as defence in depth. Stale cleanup leaves a terminal status in place, so a
   cleaned-up review is still classified by how it stopped.
9. **The loop announces that it is alive (approved after litmus round 9).** Under the
   same lock, the loop writes its PID to `<review dir>/.loop.pid` (noclobber), appends each
   reviewer job's PID as it starts it (they outlive a SIGKILLed loop; a job writes nothing
   until it is recorded, and a reader re-reads the file once the loop is dead), and removes the file
   on exit, once those jobs have exited. `--continue` continues a parked, ceiling-stopped
   or unfinished continued review, init stale-cleans one and fresh init resets one only when no live process
   listed in that file is alive (`kill -0`, then `ps -p`; a zombie counts as dead). This
   replaces the timestamp and terminal-status tests for a finished loop, which a paused
   loop could pass. A killed loop leaves a dead PID, which counts as finished; a reused
   PID, a symlink or an unreadable file counts as alive and refuses until the operator
   removes it. The optional ultra-oracle advisory is not listed: it writes only under
   `$STATE_DIR/ultra-oracle/<run_id>-*`, never the review directory.

## Alternatives

- **A loop flag** (`--continue` on the loop). Rejected: two lifecycles in one script, and
  Path A one forgotten flag away.
- **Keeping the count and history by hand in the design document.** Rejected by the
  dispatcher: a count in a document is not enforcement state.
- **Holding `docs/reviews/.continue.lock` for the loop's whole run.** Rejected: every
  init and `--continue` would wait behind a loop that runs for many minutes. The pin
  (decision 8) holds the lock for one read.

## Consequences

- A stopped review can be continued without losing what stopped it, and #947 can move.
- After an ordinary review finishes, the pointer stays on it, so continuing a different
  review first needs the pointer removed, the same step as init's existing "To force"
  advice.
- `docs/reviews/` is gitignored here, so the archive and ledger are local, best-effort
  evidence. Marker tokens remain the only thing the pre-implementation gate keys on.
- A SIGKILLed `--continue` cannot roll back. It leaves visible leftovers that both the
  loop and `--continue` refuse until the operator inspects them.
- Residuals: a reused PID in `.loop.pid` refuses until the operator removes the file.
  A SIGKILLed run, or a loop killed between its lock and release, can leave
  `docs/reviews/.continue.lock`, which refuses every `--continue` and fresh init until
  the operator removes it.
  `.loop.pid` lists the loop and its reviewer subshells, not the CLI each subshell runs.
  If the loop and a subshell are SIGKILLed by PID while that CLI survives, the review
  reads as finished and the orphan can still append to that attempt's raw output file.
  It cannot write the reviewer's verdict, which only the dead subshell writes, and a
  process-group signal reaches the CLI too. Process-group tracking would not close it,
  since `timeout` moves its child into a group of its own; accepted as residual.

## Revisit trigger

- A legacy write-site park refused as `ambiguous_legacy_history`.
- Any observed write from a running loop landing in another review after a pointer move.
- A request to protect reviews that were never continued from an abandon reset.
