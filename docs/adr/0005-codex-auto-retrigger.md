# ADR 0005 — Auto-re-trigger Codex when it is the sole stale blocker on an unchanged HEAD

## Status

Accepted (2026-06-20)

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

- **One-shot per (PR, HEAD)** — the marker prevents re-trigger spam across
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
- **Worker Step 6.5** (`agents/pr-grinder.md`) — a clean working tree: no unstaged
  tracked changes (`git diff --quiet`), no staged changes (`git diff --cached
  --quiet`), AND no new untracked files (`git ls-files --others --exclude-standard`
  empty). The worker stages fixes but never commits (the dispatcher commit-block
  does), so a fully clean tree means no fix was made this round (HEAD unchanged).
  `--exclude-standard` honors `.gitignore`, so the re-trigger `.local` marker and
  other ignored files never trip the guard.
- **Inline `--opus`** ("Acting on the result" in `skills/pr-grind/SKILL.md`) —
  Claude-evaluated (did this round run the commit-block?). A shell guard can't tell
  here because the commit-block runs *before* the inline ledger, leaving a clean
  tree even on a fix-round; the surrounding step is already Claude-interpreted, so
  the wait-round test is too.

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
  algorithm is already mirrored there (worker / inline / dispatcher), and the
  one-shot marker makes mirrored calls idempotent.

## Consequences

- A Codex-only-stale, unchanged-HEAD PR now converges automatically: pr-grind posts
  exactly one `@codex review`, Codex re-reviews, and the next wait-round acks via
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
- Covered by `tests/test-codex-retrigger.sh` (9 cases, `gh` stubbed): one-shot post,
  marker idempotency, opt-out, fail-safe (post failure → released claim, exit 0, no
  marker), custom phrase, bad-input skip, usage error, `gh` missing, and sequential
  idempotency (two real runs → exactly one post).
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

> **2026-06-27 update:** opencode support has been removed; this section is historical/moot.

- **opencode mirror wiring.** pr-grind is one of the four features mirrored to the
  `opencode/` subtree, and that mirror carries the identical
  Codex-stale-on-unchanged-HEAD wait-round dead-end. Wiring the opencode pr-grind
  SKILL/agent to invoke `$BUSDRIVER_PLUGIN_ROOT/scripts/codex-retrigger.sh` under
  the same guard is **deferred to a follow-up PR**, consistent with the project
  convention that `opencode/` is a downstream mirror edited only when the task is
  explicitly the opencode port (the four features were themselves ported in a
  dedicated PR #207), and that `opencode/` is stripped from the `claude-release`
  distribution so Claude Code users never see it. The root helper is harness-neutral
  and already reachable via `$BUSDRIVER_PLUGIN_ROOT` (the bridge model — opencode
  skills call root `scripts/*.sh`, not duplicates), so the follow-up is wiring-only:
  add the guarded call to the two opencode mirror files.

## Revisit trigger

- Codex's GitHub integration changes its signal (e.g. starts emitting an `APPROVED`
  `/reviews` entry or a check-run on re-review) → the re-trigger may become
  unnecessary; reassess whether the ledger can ack Codex without it.
- A repo reports re-trigger comment noise → consider tightening the trigger (e.g.
  require N consecutive Codex-only-stale wait-rounds before posting) or lengthening
  the one-shot scope.
- The trigger phrase or connector login changes upstream → update the
  `PR_GRIND_CODEX_RETRIGGER_PHRASE` default / the `chatgpt-codex-connector` login.

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3  -->
