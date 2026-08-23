# ADR 0005 — Auto-re-trigger Codex when it is the sole stale blocker on an unchanged HEAD

## Status

Accepted (2026-06-20)

Amended (2026-07-18): pr-grind's inline `--opus` execution mode was removed
(subagent-only dispatch). The wait-round is now detected at two sites, not three
— the dispatcher loop and the worker's Step 6.5. References below to the "Inline
`--opus`" detection site and the three-way ledger mirror are historical.

**Amended (2026-08-15, issue #673): one-shot → bounded N, paced.** The re-trigger
is now at most `PR_GRIND_CODEX_RETRIGGER_MAX` attempts (default 3) per (PR, HEAD),
spaced by `PR_GRIND_CODEX_RETRIGGER_COOLDOWN` (default 180s — see the
**2026-08-15 (#676) cooldown correction** amendment below for why 180 replaced the
originally-shipped 900, and why the intermediate 240 was itself insufficient). Every "one-shot" reference below should be read as
"bounded budget"; `MAX=1` restores the original behavior exactly.

**Amended (2026-08-15, PR #676): cooldown corrected from 900s to 180s — the
shipped default was unreachable within the dispatcher's own documented wait
budget.** `COOLDOWN * (MAX - 1)` must fit inside the dispatcher's
`--max-wait` wall-clock, because an attempt whose cooldown has not yet elapsed
when the dispatcher exhausts its wait budget is never reached. This Context
section already documented `--max-wait 8` exhausting in "~8 min", but the
originally-shipped `COOLDOWN=900` needs `900 * 2 = 1800s` (30 min) to spend all 3
attempts — over 3x the ~8-minute default wait budget. Under default settings the
bounded-N fix from the amendment above never actually reached attempt 2: the
dispatcher bailed on `--max-wait` before the first cooldown elapsed, silently
reproducing the exact one-shot dead end #673 shipped this ADR to close (Codex
review, PR #676).

The FIRST correction set `COOLDOWN=240` and tested it with a bare `<=` against the
full 480s. That is exactly-equal, not inside: `240 * 2 = 480` places the last
attempt at the precise instant the dispatcher bails, reachable only with zero
trigger latency, zero marker-write time and perfectly aligned polling. Litmus
caught that as MEDIUM on the same PR. The budget must be fit INSIDE, not filled, so
the requirement carries an explicit 20% margin:

    COOLDOWN * (MAX - 1) <= 0.8 * wait-budget wall-clock

Shipped defaults are `MAX=3, COOLDOWN=180` → `180 * 2 = 360s <= 384s`, leaving 120s
of headroom. 180s still meets or exceeds the observed Codex turnaround (~3 minutes
on PR #676); when it does not, this ADR's own Consequences section already settled
the cost — Codex de-dupes, so the downside is one extra comment, never a
correctness problem. See the coupling comment in `scripts/codex-retrigger.sh` and
the pinned assertion in `tests/test-codex-retrigger.sh`, which is written against
the 0.8 margin rather than a bare `<=` precisely so that restoring 240 fails.

**Known residual — the inequality is a sanity bound, not a guarantee.** `--max-wait`
counts wait-ROUNDS and the dispatcher enforces no minimum duration per round, so the
480s figure is a documented typical rather than a contract. Eight fast rounds can
exhaust the budget in well under 360s, leaving the later attempts unreachable even at
`COOLDOWN=180`, with the pinned assertion still green. What the bound genuinely buys
is rejection of order-of-magnitude and zero-margin defaults — the two live defects on
PR #676. Closing the gap properly requires a caller-side change: pace in ROUNDS rather
than wall-clock, or have the dispatcher enforce a minimum wait-round duration. Neither
is derivable from the mtimes `codex-retrigger.sh` reads, so neither belongs in the
helper; tracked as a follow-up.

*Why the original reasoning does not survive.* This ADR justified one-shot purely
as ANTI-SPAM (see the first Guards bullet) — never as a safety boundary. What it
did not know is how much load the nudge carries. #673 measured it: after the FIRST
fix round, the Codex ack tiers can no longer clear on their own. `ack-ledger.sh`'s
outdated short-circuit (`:500-508`) fires forever once any Codex thread goes
outdated, and its ALL-OR-STALE freshness proof (`:558-594`) is re-broken by every
push, because a thread disposed in round N never gains a newer resolver comment
afterwards. Both were reproduced against PR #670's live thread data, and each is
independently sufficient to hold Codex `stale` for the life of the PR.

So from round 2 onward a fresh Tier-F 👍 is the *only* exit, and this nudge is the
only thing that asks for one. A single-use mechanism was holding up a gate it is
structurally required to clear: one dropped or ignored nudge (PR #670 — delivered
at 10:32:19Z, no Codex activity for the following 66 minutes) made
`.claude/skip-pr-grind.local` the sole remaining exit, turning a deliberate risk
acceptance into routine plumbing. The budget stays bounded, so this ADR's anti-spam
intent is preserved; only its assumption that one attempt always suffices is
retracted.

**This does not close #673.** A bounded retry raises the probability of a Tier-F
ack; it cannot manufacture one if Codex is genuinely unresponsive. The
terminal-but-unacked classification that would close the dead end is merge-gate
semantics and is tracked separately.

## Context

pr-grind gates a merge on a *fresh per-HEAD* ack from each AI reviewer. Codex
(`chatgpt-codex-connector`) is gated via `scripts/ack-ledger.sh` Tier F (a 👍
reaction whose `created_at` postdates `HEAD_PUSH_DATE`) and Tier A.2 (a review
thread resolved by Codex *after* the last push). Both anchor on the server-stamped
push date and fail CLOSED when it is absent — the #186/#189 anti-backdating
hardening.

That gating has a structural dead-end, discovered while grinding PR #217:

- **Codex only re-reviews on a *push*.** When it has no suggestions it reacts 👍;
  when it does, it posts a `COMMENTED` review (it never posts an `APPROVED`
  `/reviews` entry, a check-run, or a commit-status).
- On a pr-grind **wait-round** the HEAD is *unchanged* (there is no fix to push).
  If Codex already reviewed that HEAD and its findings were triaged + resolved, the
  ledger still reads Codex **`stale`**: it emitted a `COMMENTED` review (0
  reactions → no Tier F), and its thread resolutions predate the last push (Tier
  A.2 fails CLOSED). No event will ever make Codex re-evaluate the unchanged HEAD
  and emit a fresh clean signal.
- So Codex stays `stale` forever, every wait-round burns `--max-wait`, and the
  dispatcher BAILs (~8 min) even though the PR is otherwise clean (CI green, every
  registered bot acked HEAD, all threads resolved).

Posting a manual `@codex review` comment re-triggered Codex on #217: it re-reviewed
the unchanged HEAD and posted its 👍 within minutes → Tier F ack → clean. **pr-grind
should do this automatically.**

This is the *same class* of dead-end ADR 0004 fixes (ack-freshness gating with no
recovery path), applied to Codex's reaction tier rather than the SHA-keyed tiers.

The existing **Codex first-engagement grace** (COMPLETION block) does NOT cover it:
it only fires when Codex is `none` (never engaged) and only **re-polls** — it never
**re-triggers**, and never handles `stale`. And COMPLETION is unreachable while
Codex is `stale` (Invariant 2 blocks `clean`), so the recovery must live in the
**loop**, not COMPLETION.

## Decision

Add a guarded, one-shot `@codex review` re-trigger to pr-grind's **wait-round**
handling, factored into a single harness-neutral helper `scripts/codex-retrigger.sh`
(the source of truth) that the call sites invoke.

**Trigger condition (all must hold), evaluated by the CALLER from its ack context:**

- The round is a **wait-round** (`RESULT_COMMIT_SHA == "none"` — no fix pushed this
  round, so HEAD is unchanged).
- `RESULT_CODEX_ACK == "stale"`.
- Every registered bot in `RESULT_REVIEWER_ACKS` is a HEAD-sha or `none` (no
  registered `stale`) — Codex is the **sole** ack blocker. (Post-push fix-rounds
  self-exclude here: a fresh push leaves the registered bots `stale`.)

**Mechanism (`scripts/codex-retrigger.sh`, pure and idempotent):** given `<pr>
<head-sha>`, it posts the trigger phrase via `gh pr comment` **at most once per
(PR, HEAD)**, guarded by a gitignored marker
`${BUSDRIVER_STATE_DIR:-.claude}/.pr-grind-codex-retriggered-pr<PR>-<HEAD8>.local`.
The helper owns only the spam guard + opt-out; the *policy* (the trigger condition
above) is the caller's, because those signals live in the caller's context.

**Guards / safety:**

- **One-shot per (PR, HEAD)** *(amended 2026-08-15 → bounded N + cooldown, #673 —
  this bullet's anti-spam rationale is exactly why the change is safe: it names no
  safety boundary, so raising the budget from 1 to a small N loosens nothing)* —
  the marker prevents re-trigger spam across
  consecutive wait-rounds on one HEAD; a new push (new HEAD) is eligible again.
  Per-(PR,HEAD) scoping means concurrent grinds on different PRs never race on a
  shared marker (same rationale as pr-grind's per-PR solo-opt-in snapshot).
- **Atomic claim (no double-post under same-PR concurrency)** — the marker is
  created with an `O_CREAT|O_EXCL` pre-claim (`set -o noclobber` redirect) *before*
  the post, so two concurrent grinds on the same (PR, HEAD) cannot both pass the
  existence check and both post — the kernel grants the create to exactly one
  racer; the loser skips. The claim is **released** (removed) by a `trap … EXIT INT
  TERM` on any exit before a confirmed post — a failed post, a normal early exit, or
  an INT/TERM signal — so the fail-SAFE retry-next-round semantics are preserved.
  The trap is disarmed the instant the post is confirmed (SIGKILL is the sole
  uncoverable case — see Known limitations).
  *(Amended 2026-08-23, #677 — the release is no longer unconditional. "Any exit
  before a confirmed post" was too wide by exactly one window: from the moment
  `gh pr comment` is invoked until its rc is read, the outcome is INDETERMINATE, and
  a signal there released the claim for a nudge GitHub had already accepted — the
  next round then re-posted it, so a landed nudge cost nothing against the budget and
  the PR could collect MAX+1 comments. A `POST_OUTCOME_UNKNOWN` flag now gates the
  release. Its two transitions are not symmetric, so state them separately: it is
  **raised** immediately before each `gh` invocation and stays raised through a
  SUCCESSFUL post — the success path then disarms the traps outright, which is what
  makes a landed nudge durable — and it is **cleared** only on a KNOWN non-zero rc.
  A signal while a call is in flight therefore keeps the claim; every other exit
  releases as before — pre-attempt (a claim with no post behind it must not spend an
  attempt), between the two bounded transport retries, and after a known failure (the
  fail-SAFE retry semantics above are untouched). Two one-command-wide boundaries
  remain and cannot be closed in shell (a trap fires only *between* commands): the
  gap between raising the flag and invoking `gh`, and the gap between reading `$?`
  and clearing it. Both cost at most one attempt out of `MAX_ATTEMPTS`, recoverable
  on a later round; the alternative on either side is re-posting a nudge GitHub may
  already have accepted. The argv is built once before the retry loop specifically so
  the first of those gaps is one command rather than three. This trades a
  possibly-wasted attempt for a possibly-duplicated comment, which is the right
  direction now that the budget is 3 rather than 1 (#673) and Codex de-dupes anyway
  — see Consequences. Pinned by case 19 of `tests/test-codex-retrigger.sh`, which
  drives the window deterministically from the `gh` stub rather than by timing.)*
- **Fail-SAFE** — the helper returns 0 on every operational path (opt-out, bad
  input, marker present, `gh` missing, post failure); a failed re-trigger must
  never stale the gate, and call sites also append `|| true`. The marker is written
  **only after a confirmed successful post**, so a transient `gh` failure is
  retried next wait-round.
- **Still bounded by `--max-wait`** — if Codex never acks even after the
  re-trigger, the existing budget bail surfaces to the operator. No new unbounded
  wait is introduced.
- **Opt-out** `PR_GRIND_CODEX_RETRIGGER=0` (default on); **phrase override**
  `PR_GRIND_CODEX_RETRIGGER_PHRASE` (default `@codex review`) for forks whose Codex
  connector uses a different trigger.
- **Input sanitization** — PR must be digits, HEAD hex 7–64 (argument-injection
  guard, consistent with `ack-ledger.sh` / `augment-equiv-acks.sh`).

Wired at every wait-round site (the helper's idempotency makes overlap harmless).
Each site detects the wait-round with a different in-scope signal, all equivalent
expressions of trigger condition #1:

- **Dispatcher loop** (`skills/pr-grind/SKILL.md`) — `RESULT_COMMIT_SHA == "none"`
  (the canonical classifier; this site is authoritative since the dispatcher
  overwrites the worker's advisory acks and owns the loop).
- **Worker Step 6.5** (`agents/pr-grinder.md`) — an empty staged index
  (`git diff --cached --quiet`). The worker stages fixes but never commits (the
  dispatcher commit-block does), so an empty index means this round produces no
  push (HEAD unchanged).

**Amendment (2026-08-15, issue #678) — the worker site was NOT an equivalent
expression, and now is.** As originally shipped, Worker Step 6.5 tested a *clean
working tree*: `git diff --quiet` AND `git diff --cached --quiet` AND
`git ls-files --others --exclude-standard` empty. That is a strict superset of the
canonical classifier, so the sentence above ("all equivalent expressions of trigger
condition #1") was false for this site — it could only ever under-fire relative to
`RESULT_COMMIT_SHA == "none"`, never over-fire.

The extra clauses test states that cannot produce a push: `scripts/dispatcher-commit-block.sh`
contains **zero `git add` calls** and commits the index alone, and its `needs_more`
branch routes on `git diff --cached --quiet` alone (empty index →
`emit_success_no_commit` → `result_commit_sha:"none"`). Unstaged tracked edits and
untracked files are therefore invisible to the commit decision.

The untracked clause was the live defect. `git ls-files --others --exclude-standard`
returns **any** untracked non-ignored path, not only paths this round created, so
one long-lived untracked file disables the nudge permanently and silently. In this
repo `.claude/parked/` had done exactly that for weeks: the worker-side call site
had never fired, and #676's grind needed the dispatcher-side site invoked by hand.
That matters beyond cosmetics — #673 established the nudge as the only exit once
the Codex ack tiers go sticky after round 1, so halving the delivery paths on
unrelated repo debris raises the odds of the dead end.

The guard is now the byte-identical predicate the dispatcher routes on, which makes
the equivalence claim true by construction rather than by assertion. Pinned by
`__tests__/codex-nudge-waitround-guard.test.ts`. Rejected alternative: comparing
untracked paths against a pre-dispatch snapshot — `PRE_DISPATCH_BASELINE` is a
*staged-paths* baseline (dispatcher-commit-block.sh:115-131), not an untracked one,
so that route needed new plumbing to reproduce a signal the index already carries.

## Alternatives

- **Operator prompt instead of auto-re-trigger.** Rejected as the default: the
  whole point of pr-grind is unattended convergence; a prompt re-introduces the
  manual step #217 exposed. The env kill switch covers operators who want manual
  control.
- **Carry Codex's prior 👍/resolution forward (à la ADR 0004 content identity).**
  Rejected: Codex's signals are reaction/timestamp-anchored with no SHA to
  re-prove, and carrying them forward would relax the #186/#189 push-date anchor.
  Re-triggering produces a *genuinely fresh* signal instead of trusting an old one.
- **Widen Tier F to accept a `COMMENTED` review as a clean ack.** Rejected: a
  `COMMENTED` review can carry unresolved findings; treating it as clean would
  merge past untriaged Codex comments. Re-trigger keeps the clean signal honest (a
  fresh 👍 or new findings).
- **Extend the first-engagement grace to the `stale` case.** Rejected: that grace
  lives in COMPLETION, which is unreachable while Codex is `stale` (Invariant 2).
  The recovery has to be in the loop.
- **Centralize the call in one site only.** The mechanism *is* centralized (one
  helper); the call is mirrored at each wait-round site because the existing ledger
  algorithm is already mirrored there (worker / dispatcher), and the
  one-shot marker makes mirrored calls idempotent.

## Consequences

- A Codex-only-stale, unchanged-HEAD PR now converges automatically: pr-grind posts
  up to `PR_GRIND_CODEX_RETRIGGER_MAX` `@codex review` attempts, Codex re-reviews, and the next wait-round acks via
  Tier F (or surfaces new findings the worker triages) — instead of dead-ending at
  `--max-wait`.
- The gate is **not** loosened: the merge authority (required status checks) is
  untouched; Codex must still emit a *fresh* clean signal. The re-trigger only
  creates the *opportunity* for that signal; it never fabricates one.
- No new unbounded wait: `--max-wait` still bounds the loop.
- **Same-PR concurrency is safe:** the atomic marker pre-claim guarantees at most
  one `@codex review` per (PR, HEAD) even if two grinds race on the same PR — the
  loser skips. (Cross-PR grinds never shared a marker to begin with — per-PR scoping.)
- **Human-posted `@codex review` before the wait-round:** if a human posts the
  trigger via the GitHub UI before pr-grind reaches its wait-round, the local marker
  doesn't yet exist, so pr-grind posts a redundant duplicate. Codex de-dupes; cost
  is one extra comment. Acceptable (same spirit as the bootstrapping caveat below).
- New operator knobs: `PR_GRIND_CODEX_RETRIGGER` (default on),
  `PR_GRIND_CODEX_RETRIGGER_PHRASE` (default `@codex review`).
- Covered by `tests/test-codex-retrigger.sh` (19 cases total: 10 original + 9 added
  by #673, `gh` stubbed). The #673 cases pin the budget in BOTH directions — it
  spends across rounds AND stops at MAX — plus `MAX=1` restoring one-shot, a
  pre-#673 marker counting as attempt 1 spent (so an upgrade cannot hand in-flight
  PRs a fresh budget), the cooldown blocking while hot and releasing once elapsed,
  a malformed `MAX` falling back to the default rather than unlimited, a `MAX`
  ceiling, a failed post spending no attempt, hole refill, and the #676
  wait-budget-coupling assertion.
  The original 10: happy path, one-shot
  (marker present → no second post), opt-out, fail-safe (post failure → released
  claim, exit 0, no marker), transient recovery, custom phrase, bad-input skip,
  usage error, `gh` missing, and sequential idempotency (two real runs → exactly
  one post).
- **Bootstrapping caveat:** when this fix grinds its *own* PR, the running pr-grind
  is the *installed* plugin (which predates the fix), so it can still hit the very
  dead-end the PR fixes — resolve with a manual `@codex review`, exactly as for #217.

## Known limitations

- **SIGKILL between claim and post.** The helper atomically pre-claims the marker,
  then posts, then either confirms (writes content) or releases (removes) it. A
  `trap ... EXIT INT TERM` releases the claim on a normal early exit, Ctrl-C, or
  SIGTERM, so those never orphan the marker. A `kill -9` (SIGKILL) in the narrow
  window between claim and confirmation is the one uncoverable case — it leaves an
  empty marker that suppresses re-trigger for that one HEAD. Recover by removing the
  marker or pushing a new commit (new HEAD → new marker). Bounded and rare.
  *(Amended 2026-08-23, #677 — an INT/TERM arriving once the post attempt has begun
  now deliberately leaves the SAME empty marker, rather than releasing the claim.
  The residue shape is therefore no longer SIGKILL-only, and the recovery is
  identical. It is not a defect: the alternative was re-posting a nudge that had
  already landed. Note the marker is empty because the forensic-content write never
  ran — nothing reads that content; the slot scan reads existence and mtime, and
  `codex-retrigger-gc.sh` globs by name.)*
- **Marker accumulation.** Each (PR, HEAD) writes a gitignored
  `.pr-grind-codex-retriggered-pr<PR>-<HEAD8>.local` marker with no automatic
  cleanup; on a busy repo with many force-pushes these accumulate. Impact is
  cosmetic (small gitignored files under the state dir). Prune if desired:
  `find "${BUSDRIVER_STATE_DIR:-.claude}" -name '.pr-grind-codex-retriggered-*' -mtime +30 -delete`.
  **Partly addressed (2026-07-11, #327):** `scripts/codex-retrigger-gc.sh <pr>` now prunes a
  PR's markers at pr-grind merge (both merge blocks), so the common merge-through-pr-grind
  path self-cleans (ADR 0013 revision). The age-sweep above is still the belt-and-suspenders
  for PRs merged outside pr-grind or closed without merging (deferred).

## Out of scope (follow-up)

> **2026-06-27 update:** Closed, not deferred. OpenCode host-harness support was
> removed in #251, so there is no `opencode/` mirror to wire and the port must not
> be restored. `opencode` remains only an optional review CLI (auditor / Mechanism
> Witness).

## Revisit trigger

- Codex's GitHub integration changes its signal (e.g. starts emitting an `APPROVED`
  `/reviews` entry or a check-run on re-review) → the re-trigger may become
  unnecessary; reassess whether the ledger can ack Codex without it.
- A repo reports re-trigger comment noise → lower `PR_GRIND_CODEX_RETRIGGER_MAX`
  (1 restores one-shot) or raise `PR_GRIND_CODEX_RETRIGGER_COOLDOWN` before
  changing code; only if neither knob helps, consider tightening the trigger (e.g.
  require N consecutive Codex-only-stale wait-rounds before posting). **Raising the
  cooldown re-opens the coupling below — check it.**
- **Either default changes, or the dispatcher's default `--max-wait` changes** →
  re-check `COOLDOWN * (MAX - 1) <= 0.8 * wait-budget wall-clock`. Violating it does
  not fail loudly at runtime; it silently makes the later attempts unreachable and
  degrades the budget back toward one-shot — the #676 defect. `--max-wait` is owned
  by `skills/pr-grind/SKILL.md`, so a change there can break this from the other
  side, and the pinned assertion in `tests/test-codex-retrigger.sh` reads the two
  script defaults but NOT the dispatcher's `--max-wait` (it hardcodes the ~8-minute
  figure from this ADR's Context). Changing `--max-wait`'s default therefore requires
  updating that constant by hand — the test cannot catch that one for you.
- Codex answers the *first* nudge essentially always, across many PRs → the budget
  is dead weight; drop `MAX` back to 1 and keep the cooldown.
- Codex ignores all N attempts often enough that operators still reach for the skip
  file → the budget is not the binding constraint, and the terminal-but-unacked
  classification (#673) is what needs shipping, not a larger N.
- The trigger phrase or connector login changes upstream → update the
  `PR_GRIND_CODEX_RETRIGGER_PHRASE` default / the `chatgpt-codex-connector` login.
- **Raising `MAX` or `COOLDOWN`, or lowering the dispatcher's default `--max-wait`,
  without re-checking `COOLDOWN * (MAX - 1) <= 0.8 * wait-budget wall-clock`** →
  re-creates the #676 dead end (a scheduled attempt whose cooldown has not yet
  elapsed when `--max-wait` exhausts is never reached). Re-derive the inequality
  against the current `--max-wait` default before changing either knob.

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3  -->
