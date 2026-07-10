# ADR 0012: Bounded Advisory-Bot Stale-Ack Timeout Downgrade in pr-grind

## Status

Accepted (2026-07-07). Settled by an ultra-council review this session (5 voices
+ forced UltraOracle expert witness). Extends the `ever_approved=0` infra-error
downgrade in `scripts/ack-ledger.sh` and complements
[ADR 0004](./0004-content-identity-ack-carryforward.md) (content-identity
carry-forward) and [ADR 0005](./0005-codex-auto-retrigger.md) (Codex one-shot
re-trigger). Resolves issue #295.

## Date

2026-07-07

## Context

pr-grind's clean-marker (Invariant 2, `skills/pr-grind/SKILL.md`) refuses to
write the `clean` (merge-ready) marker while ANY registered advisory reviewer bot
(`cursor`, `cubic-dev-ai`, `coderabbitai`, `devin-ai-integration`,
`codescene-delta-analysis`, plus Codex tracked separately) is `stale` in the ack
ledger. `stale` means the bot's last review targets a non-HEAD SHA.

The real merge authority is server-side and untouched by this decision: required
GitHub status checks (`.github/required-checks.lock`) + branch protection + the
separate `litmus` deep review (Codex lead + Opus backstop). Advisory acks are a
bounded-wait quality nicety, capped by `--max-wait`; on exhaustion pr-grind bails
to the operator.

**The friction:** Codex and Devin do not reliably re-ack a force-pushed / rebased
HEAD. They leave their last review on the old SHA (often with 0 findings) or post
a `COMMENTED` review without the clean 👍 the ledger keys on. The bot then stays
`stale` indefinitely, blocking the clean marker even though it found nothing and
every real gate is green. The only recourse today is a manual
`touch .claude/skip-pr-grind.local` each time — ~7–15 min wasted per PR for zero
safety benefit. Observed twice on 2026-07-07: PR #291 (Codex `COMMENTED`, never a
clean 👍) and PR #293 (Devin reviewed the pre-rebase SHA with 0 findings, did not
re-review HEAD). Both had 8/8 CI green, litmus PASS, 0 unresolved threads,
`mergeState=CLEAN`.

The council (4/5) and the UltraOracle independently converged on the preferred
direction below. The Skeptic dissented (delete the advisory stale-gate entirely);
its risk — laundering a *genuine* silent bot failure into a false all-clear —
reshaped the trigger precondition (see Consequences).

## Decision

Add a **bounded, logged, precondition-gated auto-downgrade** of an advisory bot's
ack from `stale` → `none` (non-gating), **solo-repo opt-in** (mirrors the existing
`.claude/pr-grind-auto-admin-solo.local` affordance; a repo-controlled config
cannot enable it).

**Trigger — ALL of the following must hold** (fail closed if any is unprovable):

1. `--max-wait` is exhausted (this is a last-resort release, never a fast path).
2. The bot is advisory-only (not a required GitHub check).
3. The bot is `stale` solely because its last review targets a non-HEAD SHA.
4. The bot's own last review on that SHA had **0 unresolved findings** — the
   decisive precondition. This distinguishes "the bot signaled clean and simply
   didn't re-ack" from "the bot went silent / crashed / is rate-limited mid-review"
   (the Skeptic's laundering risk). A bot that never produced a clean signal is
   NOT downgraded.
5. Zero unresolved review threads attributable to the bot on HEAD (reuses the
   existing Source-2 unresolved-thread query, `ack-ledger.sh`).
6. Required status checks are green (per `required-checks.lock`).
7. `litmus` is green on the current HEAD (Codex lead + Opus backstop).
8. No bot-authored live blocking / changes-requested / security / must-fix signal
   on still-relevant diff content.

Downgrade emits `stale → none` (**never** `stale → approved`): the ledger records
"this advisory signal expired cleanly," not "the bot approved HEAD." Anti-laundering
lives in the **audit trail**, not the marker: the `pr-grind-clean.local` marker must
stay a bare PR number (`pre-merge-gate.sh` parses it with `tr -d '[:space:]'` and
treats any non-digit as corrupt), so the released-bot list is recorded in
`bypass-log.jsonl` (one event per bot) and surfaced to the operator in the
completion message — `clean` is never silently equated with "all advisors approved
HEAD."

**Forensic logging:** one JSONL event per downgrade to `.claude/bypass-log.jsonl`,
distinct event `advisory_stale_timeout_downgrade`, carrying at least: `event`,
`repo`, `pr`, `bot`, `head_sha`, `stale_review_sha`, `last_state`,
`unresolved_bot_findings_on_head`, `unresolved_bot_threads`,
`required_checks_state`, `litmus_state`, `wait_rounds`, `policy_version`,
`operator`, `timestamp`.

## Alternatives

- **(2) Content-identity / message-only carry-forward extended to `/reviews`-based
  bots (Devin).** Rejected as the primary fix: review states and comments are
  messy and human-visible, so misclassification after a rebase is riskier than for
  check-runs (Codex Critic + Grok). May be added later for bots with stable review
  fingerprints.
- **(3) Per-repo drop of specific advisory bots from the clean-gating set.**
  Rejected as "too blunt" (UltraOracle): it discards the bot's signal wholesale
  rather than releasing only after the bounded, green-gated conditions.
- **(4) Devin re-trigger parity (mirror ADR 0005's Codex re-trigger).** Kept as an
  optional *pre-timeout* optimization, not the main fix — it is vendor-specific
  whack-a-mole and unproven (Devin may expose no re-review API), and Codex already
  has a re-trigger yet still stalled on #291. The bounded downgrade is the backstop
  that always terminates.
- **(Skeptic) Delete the advisory stale-gate entirely.** Rejected: the gate still
  protects the common case — a bot mid-review on HEAD, or one with live findings,
  or the slow-bot race where a fast bot acks seconds before a slower bot posts
  findings. The bounded downgrade preserves the gate for that case and releases
  only after `--max-wait` + green gates + a proven-clean bot signal.

## Consequences

- Eliminates the manual-skip tax on green PRs where an advisory bot merely failed
  to re-ack, without touching required-check or litmus merge authority.
- The precondition "bot's last review had 0 unresolved findings" (not merely "bot
  is stale") is load-bearing: it is what prevents laundering a silent/crashed bot
  into a false all-clear. A rate-limited or crashed bot that produced no clean
  signal stays `stale` and still bails to the operator.
- `clean` remains forensically honest — the downgraded-bot list travels with the
  marker and every downgrade is logged, so a future reader cannot mistake a
  timeout-released `clean` for "all advisors approved HEAD."
- Solo-repo opt-in keeps blast radius minimal; a multi-maintainer repo (where an
  advisory bot may encode team policy) must opt in explicitly.
- New surface to maintain in the pr-grind Completion block + a new ledger/marker
  interaction; covered by gate tests.

## Addendum (2026-07-09): server-time anchor for the revalidation ref (issue #302)

The COMPLETION-time revalidation (`scripts/advisory-downgrade-revalidate.sh`, added
in PR #300) decides "did this bot re-engage after its downgrade?" by comparing the
downgrade event's `timestamp` **lexically** against GitHub activity timestamps
(`created_at`/`submitted_at`/`createdAt`). The event `timestamp` was originally
stamped with the operator's **local** clock — a fail-**open** under clock skew: a
machine clock ahead of GitHub makes a genuine re-engagement carry a GitHub
`created_at` that sorts *before* the ref, so the revalidator reads the bot as
silent and suppresses a live review.

Fix (fix direction 1, "server-time anchor"): the downgrade event is now stamped
with GitHub's own clock via `scripts/github-server-now.sh` (the `Date` response
header of the quota-exempt `/rate_limit` endpoint, converted to ISO-8601 with a
portable awk month-map). `advisory-stale-downgrade.sh` takes this as a required
`SERVER_NOW` input, validated against the same ISO regex the revalidator enforces
on the ref, and **fails CLOSED** (no downgrade) when it is absent or malformed —
it never falls back to the local clock. The revalidator is unchanged: once the
logged ref is on GitHub's clock, its existing comparison is skew-correct.

Scope note: this closes the clock-skew gap in the issue body. The broader
timestamp-diff gap *class* raised in the issue comment (edited comments/reviews,
reaction churn — bots that mutate existing activity without a fresh `created_at`)
is deliberately deferred; the recommended holistic direction is to reuse the
ack-ledger staleness verdict directly rather than patch each timestamp source.

## Addendum (2026-07-10): global opt-in — one switch for all repos

The opt-in was per-repo only (`<repo>/.claude/pr-grind-advisory-downgrade.local`),
so a solo operator who wants the affordance on every checkout had to drop the file
into each one. Added a **global** opt-in alternative:
`${BUSDRIVER_GLOBAL_STATE_DIR:-$HOME/.claude}/pr-grind-advisory-downgrade.local`.
Either file present ⇒ opted in; the per-repo file still works unchanged and wins on
its own.

Resolution moved into a single fail-CLOSED resolver, `scripts/advisory-downgrade-optin.sh`
(prints `1`/`0`), replacing the inline prompt-level presence check in the pr-grind
COMPLETION block (step 1). It checks the global file first (repo-independent
standing consent, valid even when the repo root can't be resolved), then the
per-repo file via the same `--git-common-dir`-parent main-root resolver the rest of
the opt-in ecosystem uses. Any ambiguity — unresolvable root with no global file —
prints `0` (stay strict / BAIL), because this opt-in *relaxes* a gate. Covered by
`tests/test-advisory-downgrade-optin.sh` (7 cases; env-seam roots, no real git).

**Why global is safe here.** The switch does **not** open the merge gate — it only
changes *where the opt-in is read from*. Every downgrade precondition above is
unchanged and re-checked by `advisory-stale-downgrade.sh`: CI green, litmus green,
the bot found 0 findings, 0 unresolved threads, no live/blocking signal, server-time
anchored. It never touches required checks or litmus, and for the genuine-new-commit
case litmus has already reviewed the new diff. So the marginal effect of "on
everywhere" is only that a *stale-but-clean* advisory ack stops blocking when the
real gates are already green.

**Blast radius (chosen: plain global).** The operator's repos are single-operator,
so a plain global switch was chosen over auto-scoping it to sole-admin repos. The
tradeoff: on a *shared* repo the operator later contributes to (a second
approval-capable human, advisory bots encoding team policy), the global file would
apply there too. The stricter **solo-admin-gated global** — active only where the
existing sole-admin detector says the operator is the only approval-capable human,
self-revoking otherwise — is documented as the upgrade path (revisit trigger below)
and is a small delta on this resolver if a shared repo ever enters the mix.

## Revisit trigger

- The operator starts running pr-grind in a **shared / multi-maintainer** repo while
  the global opt-in is set — upgrade the resolver to the **solo-admin-gated global**
  variant (reuse the `pr-grind-auto-admin-solo` sole-admin detector; active only where
  the operator is the sole approver, self-revoking when a second appears).
- A second approval-capable human joins the repo (the solo assumption breaks) —
  re-evaluate whether the opt-in should self-revoke like `pr-grind-auto-admin-solo`.
- Evidence that a downgraded bot later surfaced a real finding that the trigger's
  0-findings precondition missed — tighten the precondition or add a bot to a
  never-downgrade set.
- A registered bot gains a reliable force-push re-ack (making the downgrade
  unnecessary for it) — drop it from the downgrade-eligible set.
