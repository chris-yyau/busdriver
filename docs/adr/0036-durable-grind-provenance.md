# ADR 0036 — Durable grind provenance: make #620's proportionality gate fire across invocations

**Status:** Accepted
**Date:** 2026-08-11

## Context

#620 shipped a proportionality gate into `agents/pr-grinder.md`: when every
finding in a round sits on code a prior grind round wrote, the loop is reviewing
its own output and BAILs `judgment` rather than fixing itself in circles.

The gate sources provenance **solely** from `PRIOR_ATTEMPTS`, which
`skills/pr-grind/SKILL.md` re-initializes empty on every invocation, and four
absolute statements short-circuit before any comparison ever runs — the loudest
being "On round 1 `PRIOR_ATTEMPTS` is empty, so no loop output exists yet and
this gate can never fire."

So on a **fresh invocation of an already-ground PR** the gate is inert. That is
not a corner case; it is the dominant mode in this repo. PR #617 took 17 fix
commits over 17 hours across repeated invocations, with 181/155/217-minute gaps
between them. Every one of those re-invocations started with an empty
`PRIOR_ATTEMPTS` and a gate that could not fire.

Provenance therefore has to live somewhere that survives the invocation
boundary. The branch itself is the only such place that needs no new state
store: `pr-grind` creates and destroys its own ephemeral worktree, so file state
in `.claude/` dies with it, and the gate doctrine already distrusts mutable
per-key files.

## Decision

Stamp a `Grind-PR: <N>` trailer at the sole commit path, derive the branch's
grind-commit SHA set in the dispatcher, hand it to the worker, and widen the
gate to that set.

**1. The trailer is written and verified at `scripts/dispatcher-commit-block.sh`.**
That script is the only place a grind commit is created
(`agents/pr-grinder.md` forbids the worker from calling `git commit`/`git push`
or composing a message). It is emitted with a leading newline so exactly one
blank line precedes it in both message shapes — an unconditional bare append
would, on the no-litmus path, glue the trailer onto the body's last paragraph
where git's trailer-ratio rule makes recognition shape-dependent on
`RESULT_FIXES`.

The commit runs through the repository's normal hooks, deliberately, so the
trailer is **verified after the fact** against two different predicates:

- the exact byte sequence the scanner matches (`grep -qx "Grind-PR: N"`), and
- that it parses as a real trailer (`%(trailers:key=Grind-PR,valueonly=true)`).

Neither alone is sufficient. Git's trailer parser is case-insensitive and
tolerates a missing space after the colon, so a `commit-msg` hook that
*normalizes* `Grind-PR: 618` to `grind-pr:618` passes a parser-only check,
returns `618` from it, and is matched **zero** times by the scanner (measured,
git 2.55.0) — a silent fail-open on the exact durability property this ADR
exists to guarantee. Either check failing BAILs `env` with the commit local and
unpushed.

**2. Two prose seams become executable scripts.**

- `scripts/grind-pr-commits.sh` — the producer. Emits the SHA **set** (not a
  count: a count cannot serve a membership test and would force a second,
  divergent predicate). `--context` renders the two worker context fields
  directly.
- `scripts/grind-set-member.sh` — the consumer. Owns the strict-vs-fail-open
  validation asymmetry and the membership decision.

This is the load-bearing part of the decision, not an implementation detail.
Both documents this touches are agent-executed prose, and a documented-but-
unenforced contract is precisely #620's failure mode. Prose cannot be tested;
these scripts are covered by `tests/test-grind-pr-commits.sh` (20 cases) and
`tests/test-grind-set-member.sh` (24 cases), with golden greps demoted to
declared drift guards in `tests/test-grind-provenance-gate.sh`.

**3. The dispatcher derives; the worker is handed the result.** The worker's
context block carries neither a base nor a head ref, so a worker-side derivation
is unrunnable. This matches the existing ownership split: the worker owns triage
and staging, the dispatcher owns commits, push, and git state. The worker gains
one input and no new capability.

**4. The producer call sits pre-dispatch, every round.**
`dispatcher-commit-block.sh` is a subprocess invoked *after* the worker returns
and only on fix-rounds, so a call placed there could never populate a wait-round
or the round-1 re-invocation this ADR exists to fix — #620's defect repeating
one layer down.

**5. The base floor is the MERGE BASE, resolved in Step 0 from a
per-invocation, force-updated scratch ref that is deleted in the same block.**

The floor is deliberately not the fetched tip. The live tip stops being an
ancestor of the PR head the moment the base branch advances after the branch
diverged — the routine `mergeStateStatus=BEHIND` case in this repo — and the
helper refuses a non-ancestor range, so using the tip directly would have BAILed
before every dispatch on ordinary, behind-but-valid PRs. The merge base is an
ancestor of HEAD by construction, and `merge-base..HEAD` is exactly this
branch's own commits, so it still excludes the trunk squash commits whose
concatenated bodies carry `Grind-PR:` lines.

`gh pr view --json baseRefOid` was rejected: it does not materialize the object
locally, so `git rev-list <missing-sha>..HEAD` fails rc 128 and hard-BAILs every
grind, and it is frozen at PR creation rather than the live tip. A stale local
`origin/<base>` was rejected because semantic-release pushes a release commit to
`main` after every merge here.

Resolving in one block makes `BASE_SHA` a cross-block literal (the convention
`WORKTREE_DIR` already uses) and removes a COMPLETION/BAIL cleanup row that
would have been skipped under `NO_WORKTREE=1`, the most common in-place mode.
The ref is named per-**invocation**, not merely per-PR: PR-scoping alone still
lets two grinds on the same PR interleave, one deleting the ref between the
other's fetch and its `merge-base`. Deletion is cleanup; uniqueness is what
removes the race.

**5a. The trailer match runs against the parsed trailer BLOCK, not the whole
message.** `rev-list --grep` matches any line, so an author commit quoting an
exact `Grind-PR: N` line in prose — an example, a changelog entry, a review
quote — would be attributed to the grind and false-BAIL on the author's own
code. `%(trailers)` emits only the trailer paragraph, verbatim, so one
exact-line match against *that* is the right predicate. Checking the parsed
VALUE instead is not equivalent: git's parser is case-insensitive and
space-tolerant, so a commit whose body quotes the line and whose real trailer is
`grind-pr:617` returns `617` and would still be counted. The parse is pinned
with `-c trailer.separators=':'` so the predicate means the same thing in every
repository it runs in.

**6. Membership is set-over-a-bounded-range, never per-SHA message matching.**
GitHub squash bodies concatenate every branch commit's full message (verified on
`924cbdea`, the #617 merge), so `main` accumulates `Grind-PR:` lines — including
this PR's own number after an earlier related merge. Since `git blame -w -M -C`
follows moves and copies into merged history, a per-SHA `grep` on the blamed
commit's message would false-BAIL on author code. The helper additionally
rejects a wrong-shaped range (`merge-base --is-ancestor` false) and a shallow
repository, because `git rev-list A..B` returns rc 0 for any pair and would
otherwise scan trunk history or a truncated ancestry silently.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Persist a counter in `.claude/` | The ephemeral worktree dies with the run; the gate doctrine distrusts mutable per-key files. |
| Count all commits since PR creation | Cannot distinguish author from grind commits, which is the whole question. |
| Worker-side derivation | The worker's context block carries no base or head ref and owns no git topology by design. |
| A count-returning helper | Cannot serve a membership test; forces a second, divergent predicate. |
| `origin/<base>` as the range floor | Only the PR head is fetched; the ref may be absent or stale. |
| A single repo-wide `refs/bd-grind/base` | Shared across linked worktrees; races concurrent grinds and, without `+`, poisons permanently on a divergent base. |
| `--no-verify` to protect the trailer | Bypasses the repository gates the dispatcher is required to commit through. Verify after the fact instead. |
| Verifying with git's trailer parser alone | A normalizing `commit-msg` hook passes it while the scanner misses the commit — silent fail-open. |
| Leaving the contract in prose | The reason #620 shipped inert. Two scripts + 44 behavioral cases replace it. |

## Consequences

- **#620's gate fires across invocations.** This is the change that fixes #620.
- **A gate that has never fired becomes armed**, on the case most common in this
  repo — a long-running, repeatedly-ground PR. The first firings are the risk
  surface: a false BAIL blocks a legitimate grind. The `bail_reason` names the
  SHAs it attributed to, so first occurrences are diagnosable from the round
  output without extra instrumentation.
- **A false proportionality BAIL is resolved by the operator, manually.** There
  is no override flag: the gate BAILs `judgment` before applying any fix, and
  `--max-fix` is a round budget, so raising it cannot override a gate that
  re-fires deterministically on the same findings and the same provenance. If an
  autonomous continuation is ever wanted it needs its own explicit, named
  one-shot override.
- **Every dispatcher-pushed commit carries a machine-readable `Grind-PR:`
  trailer**, and a hook that strips *or normalizes* it stops the grind rather
  than degrading provenance silently. The recovery is: fix the hook, then
  `git reset --soft HEAD~1` on the local unpushed commit, then re-grind. An
  "explicit re-run" without the reset does not work — `resolve-pr-worktree.sh`
  asserts the resolved dir's HEAD equals the PR's `headRefOid` and bails
  otherwise.
- **Both markers are client-stamped** — the trailer *and* the transitional
  subject arm, which is a plain conventional-commit line any author could write
  by hand. The gate doctrine forbids such values in an automated merge proof;
  this design does not put one there. Every consumer feeds a **BAIL**: a missing
  marker under-counts (today's behavior), a forged or coincidental one
  over-counts into an operator review. Neither authorizes an unreviewed merge.
- **Provenance is over reachable, un-rewritten history.** A rebase or squash
  between invocations erases trailers. History rewriting on a pushed branch is
  already a worker BAIL trigger, so the guarantee is scoped accordingly.
- **A shallow clone now hard-fails the grind** rather than silently
  under-counting. Fail-closed is the intended direction: under-counting degrades
  straight back to the inert gate.
- One extra fetch per grind and one extra `rev-list` pair per round; both
  `--no-tags`/single-range and neither replaces an existing call.
- **Environment exposure on this path is the ADR 0026 accepted residual,
  inherited rather than reopened.** pr-grind's dispatcher prose runs in the
  operator session's ambient environment; ADR 0016's `env -i` wrapper protects
  auto-firing gates and explicitly does not transfer here, and issue #475 was
  closed as documented residual rather than fixed with a dispatcher-wide
  wrapper. The helpers therefore do what they can from inside — cleared git
  variables, `GIT_NO_REPLACE_OBJECTS`, dropped inherited functions, `command` to
  bypass function lookup, `set -f`, a canary verifying that `git` is really git,
  and a pure-bash membership test with no external command to shadow — and say
  in-script that none of it is the boundary. A PATH shim or a full `git`
  emulation still wins, and no in-script check can change that: at that point
  the attacker is running arbitrary code in the process and could have replaced
  the script.

## Transitional arm and its removal trigger

A commit whose **subject** is exactly `fix: address PR #N feedback` also counts,
covering branches already open at rollout. It matches the subject only, never
via `--grep`, which would also match body lines (verified: an author commit
whose body quoted the phrase). Drop this arm once no pre-rollout grind branch
remains open.

## Revisit trigger

If `GRIND_SHAS` proves insufficient because branches are routinely rebased
between invocations, revisit whether the record must live outside branch history
— a PR label or comment ledger is the only count that survives history
rewriting.

## Not solved by this

Durable provenance makes the gate fire; it does not measure diff size against
defect size. When a fix is new code, each round's additions become the next
round's review surface, and every finding on them is legitimately "your changed
code" (#617 grew to 1333 lines this way). A true proportionality metric is the
deferred UltraOracle closure-SHA finding-ledger, which stays deferred on its
existing trigger.

**Rail B — a cumulative `--max-fix` ceiling** — is deliberately out of scope. It
becomes implementable on top of this without further plumbing, consuming the
same helper, and follows as its own PR and its own design.
