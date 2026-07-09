# ADR 0013 — Opt-in one-shot Codex nudge when Codex never auto-triggers (`none`)

## Status

Accepted (2026-07-09)

## Context

ADR 0005 added `scripts/codex-retrigger.sh`: a one-shot-per-(PR,HEAD) `@codex
review` re-trigger that breaks the Codex-`stale`-on-unchanged-HEAD wait-round
dead-end. It fires **only** when Codex is `stale` — engaged on an older SHA and
didn't re-ack HEAD after a push — AND is the sole ack blocker on a wait-round. It
does **not** fire when Codex is `none`: Codex never engaged on the PR at all.

Observed on PR #297 (2026-07-08): the GitHub Codex bot (`chatgpt-codex-connector`)
and Cursor Bugbot — both of which normally auto-review every PR on this repo —
silently produced no review on either commit (no check, no review, no comment).
`cubic` on the same PR explicitly posted "monthly review limit reached." The likely
shared cause is **usage-quota exhaustion** for the billing cycle; a dropped
auto-review webhook is the other possibility. Either way, a `none` Codex is
non-gating today, so pr-grind proceeds without a Codex-bot review.

The existing **Codex first-engagement grace** (COMPLETION block, `skills/pr-grind/
SKILL.md`) already handles the `none` case with a *bounded re-poll* that *falls
through to non-gating `none`* — but it never **nudges**. So a repo that expects
Codex to review, where Codex silently no-ops on a fresh PR, converges and merges
without ever asking Codex to look.

## Why a blanket "nudge on `none`" is wrong

- `none` legitimately means "Codex does not operate on this PR" and is correctly
  non-gating today. Nudging **every** `none` would force `@codex review` onto every
  PR on every repo — including repos where Codex is not meant to review —
  converting a non-gating signal into a gating wait that can hang.
- `stale` is safe to retrigger because it PROVES Codex is installed and reviewing
  this PR. `none` proves nothing — not-installed, quota-exhausted, and
  dropped-webhook are indistinguishable from the GitHub API.
- **A nudge cannot cure quota exhaustion.** Posting `@codex review` to a
  quota-exhausted bot silently no-ops; if pr-grind then *waited* for the review it
  would burn its budget and bail. The nudge only helps the "webhook dropped, quota
  available" case — so it MUST degrade gracefully in every other case.

## Decision

Add an **opt-in, one-shot, bounded** `@codex review` nudge for the `none` case,
gated on a per-repo opt-in file and delegated to the existing ADR 0005 mechanism.

**Policy wrapper (`scripts/codex-nudge-if-expected.sh`, new):** checks for the
per-repo opt-in file `<main-repo-root>/.claude/pr-grind-codex-expected.local`
(gitignored, same pattern as `pr-grind-auto-admin-solo.local`; resolved at the MAIN
repo root because worktree `.local` files are not copied into worktrees). ABSENT →
no-op, exit 0 (today's behavior: a `none` Codex is never nudged). PRESENT →
delegate to `codex-retrigger.sh`, which owns the one-shot marker, fail-safe post,
global opt-out (`PR_GRIND_CODEX_RETRIGGER=0`), and phrase override. This preserves
ADR 0005's split: the helper is pure MECHANISM; the opt-in is caller POLICY.

**Call site (`skills/pr-grind/SKILL.md`, COMPLETION first-engagement grace):**
invoke the wrapper ONCE, inside the existing `CODEX_DONE == none && CODEX_GRACE > 0`
branch, **before** the bounded re-poll (`sleep` + refresh). COMPLETION is reached
only post-convergence (CI green, all registered bots acked, all threads resolved),
so the nudge fires **after CI has settled** — it never races normal auto-trigger
latency. The existing bounded re-poll then observes the result; if Codex still does
not engage within the grace, the block falls through to non-gating `none` exactly as
before. `|| true` at the call site keeps a failed nudge from ever staling the gate.
The call runs in a subshell that `cd`s into `$WORKTREE_DIR` first — identical to the
LOOP's stale-retrigger call site — so (a) the wrapper's CWD-derived opt-in root is
the PR's own repo, not a drifted checkout's (per-repo consent), and (b) the delegated
codex-retrigger marker lands in the same worktree `.claude/` the stale path uses,
preserving the single shared one-shot marker.

**Shared one-shot marker.** The wrapper delegates to `codex-retrigger.sh` with no
new marker, so the `none` and `stale` paths share the same per-(PR,HEAD) marker:
**at most one `@codex review` is posted per HEAD across both paths combined.**

## Guards / safety

- **Opt-in required.** Absent the file, behavior is byte-for-byte today's — a
  `none` Codex is never nudged. No repo is forced into Codex review.
- **Bounded, never hangs.** The nudge reuses the *existing* bounded grace re-poll;
  it adds no new wait. Quota-exhausted / uninstalled / still-silent Codex all
  degrade to non-gating `none` — the merge is never blocked waiting for a review
  that will not arrive. (An opt-in operator who wants the nudge to have more time to
  land raises `PR_GRIND_CODEX_GRACE_SECS`, default 20.)
- **One nudge per (PR, HEAD), logged.** Enforced by the shared codex-retrigger
  marker; codex-retrigger logs the post to stderr (`✅ codex-retrigger: posted …`).
- **Merge authority unchanged.** Required status checks + litmus still gate. The
  nudge only creates the *opportunity* for a fresh Codex signal; if Codex engages
  and finds real issues, FRESH_ACKS reads `stale` and the merge correctly blocks —
  that is the desired outcome, not a regression.
- **Fail-safe.** The wrapper exits 0 on every operational path (not opted in, bad
  args → except missing-args exit 2, a wiring bug; delegate skip/fail). A failed
  nudge never stales the gate.
- **Global kill switch still wins.** `PR_GRIND_CODEX_RETRIGGER=0` disables both the
  `stale` retrigger and the `none` nudge (the wrapper delegates through it).

## Alternatives

- **Extend `codex-retrigger.sh` itself to accept the `none`+opt-in path.** Rejected:
  it would push repo-level POLICY (the opt-in) into the pure-MECHANISM helper,
  breaking ADR 0005's split and coupling the `stale` path to the opt-in file. A thin
  wrapper keeps the helper unchanged and independently tested.
- **Nudge on `none` during the LOOP (like the `stale` retrigger).** Rejected: on a
  repo with registered bots the loop waits on those bots, not on Codex; `none` Codex
  is non-gating there. The only place a `none`-only Codex (e.g. a Codex-only repo)
  needs handling is COMPLETION, where the first-engagement grace already lives. The
  issue also requires firing "after CI settles" — COMPLETION is exactly that point.
- **Longer / looping re-poll after the nudge.** Rejected as default: an unbounded or
  multi-round wait for a possibly-quota-dead bot is the hang the design forbids. The
  single bounded grace + `PR_GRIND_CODEX_GRACE_SECS` knob covers operators who want
  a longer window.
- **Generalize to other auto-advisory bots (Cursor Bugbot `bugbot run`) now.**
  Deferred: Codex already has the retrigger machinery and the observed failure. The
  opt-in + bounded-fallback contract generalizes cleanly if a second bot warrants it
  (revisit trigger below).

## Consequences

- A repo that opts in and whose Codex silently didn't auto-trigger now gets exactly
  one `@codex review` at COMPLETION; if quota/webhook allows, Codex reviews and the
  bounded grace picks up its ack (or findings). Otherwise the PR still converges to
  non-gating `none` — no behavior change from today for the degraded cases.
- No repo without the opt-in file sees any change.
- New per-repo opt-in file `.claude/pr-grind-codex-expected.local` (gitignored).
- Covered by `tests/test-codex-nudge-if-expected.sh` (7 cases, `gh` stubbed):
  not-opted-in no-op, opted-in one post + marker, one-shot through the shared marker,
  global opt-out pass-through, fail-safe (post failure → exit 0, no marker),
  unresolvable-main-root fail-safe (no CWD-relative fallback → no nudge), and usage
  error. `codex-retrigger.sh` itself remains covered by `tests/test-codex-retrigger.sh`.

## Revisit trigger

- A repo reports nudge-comment noise → tighten (e.g. require the opt-in AND a prior
  successful Codex review on the repo before nudging) or lengthen the one-shot scope.
- A second auto-advisory bot (Cursor Bugbot, etc.) exhibits the same silent-`none`
  failure → generalize the wrapper to a bot+phrase table under the same opt-in +
  bounded-fallback contract.
- Codex gains a reliable first-engagement signal that the grace can wait on
  deterministically → reassess whether the nudge is still needed.
