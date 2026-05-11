# PR-8 — Copilot auto-re-request — won't-ship

**Disposition:** Closed, will not implement.
**Date:** 2026-05-11
**Original spec source:** Session backlog item carried from `2026-05-09-pr-queue-final-session.tmp` → `2026-05-11-pr84-shipped-session.tmp`.

## Original spec

When the worker (or dispatcher's defense-in-depth re-query) computes the
ack ledger and `copilot-pull-request-reviewer` returns `none`, check whether
Copilot's most recent review/comment body matches an infra-error pattern
(rate limit, quota, internal error). If yes, auto-`POST` to
`repos/{owner}/{repo}/pulls/<N>/requested_reviewers` with body
`{"reviewers": ["copilot-pull-request-reviewer"]}` to nudge Copilot to retry.
Constrain to once per PR per dispatcher session.

## Why this is closed

### 1. The proposed mechanism does not work

`scripts/ack-ledger.sh:100-115` documents the technical blocker discovered
during PR #77 (v1.30.1) implementation:

> *"there's no gh-CLI surface to clear it (DELETE only works on pending
> reviews; **requested_reviewers POST 422s for Copilot**)."*

GitHub's `requested_reviewers` endpoint rejects `copilot-pull-request-reviewer`
with HTTP 422. The active re-request mechanism PR-8 was specced around is
unavailable.

### 2. The trigger conditions are already covered by passive downgrade

PR #77 shipped a passive downgrade in `scripts/ack-ledger.sh:100-129` for the
same trigger surface PR-8 wanted to act on. When a bot's latest review body
matches the regex `'encountered an error|rate.?limit|unable to review|try again
by re-requesting'` AND the bot has never approved/dismissed (`ever_approved=0`
admin-bypass guard), the ledger downgrades `stale → none`. The grind loop then
treats Copilot as "doesn't operate here" rather than "still waiting", surfaces
the situation to the operator, and proceeds to merge gate when other authority
signals (required checks) are green.

### 3. Empirical catch rate: 100% on observed cases

Audit of Copilot reviews on busdriver PRs #82–#91 (2026-05-08 → 2026-05-11):

| PR | Copilot review state | Body matches existing regex? |
|----|---------------------|------------------------------|
| #82 | COMMENTED (errored) | ✅ 3 alternation hits |
| #83 | COMMENTED (errored) | ✅ 3 alternation hits |
| #84 | COMMENTED (errored) | ✅ 3 alternation hits |
| #85 | (no Copilot review) | n/a |
| #86 | COMMENTED (errored) | ✅ 3 alternation hits |
| #87 | (no Copilot review) | n/a |
| #89 | COMMENTED (errored) | ✅ 3 alternation hits |
| #90 | COMMENTED (success) | n/a — no error path |
| #91 | COMMENTED (success) | n/a — no error path |

All 5/5 observed Copilot infra errors emit the verbatim string:

> *"Copilot encountered an error and was unable to review this pull request.
> You can try again by re-requesting a review."*

This single string matches three of the four regex alternation arms
(`encountered an error`, `unable to review`, `try again by re-requesting`).
There is no measured gap.

### 4. The session file's proposed extension patterns are speculative

The session file enumerated six additional patterns to add to the regex:
`quota exceeded`, `usage limit`, `internal error`, `temporarily unavailable`,
`service degraded`, `503`. None of these appear in any observed Copilot output
across the audited PRs. They are plausible-sounding generic infra-error
templates, not what Copilot actually emits in 2026-05.

Per `validate-before-building.md`: *"Do not build, port, or integrate a feature
until you have empirical evidence the problem it solves actually exists."*
No evidence, no build.

## Future revisit trigger

Reopen this disposition only if **all** of the following are true:

1. A Copilot error message is observed in the wild whose body does NOT match
   the existing regex `'encountered an error|rate.?limit|unable to review|try
   again by re-requesting'`.
2. The unmatched message represents a recurring pattern (≥2 occurrences across
   different PRs), not a one-off.
3. The pattern actually causes a stuck grind (Copilot stays `stale` past
   `--max-wait` exhaustion, forcing operator intervention).

At that point the correct response is to widen the regex *for the observed
pattern only*, not to revive the active re-request mechanism (which remains
blocked by GitHub's 422).

## Related

- **PR #77** (v1.30.1) — original infra-error downgrade + `ever_approved=0`
  admin-bypass guard. The implementer of this PR discovered the
  `requested_reviewers` 422 wall.
- **PR #79** (v1.31.0) — extracted the ledger algorithm to
  `scripts/ack-ledger.sh` for single-source maintenance.
- **PR #84** (v1.33.0) — split `--max` into `--max-fix`/`--max-wait`, giving
  the loop a bounded wait budget. Combined with the downgrade, this is the
  full safety net for slow/erroring bots.
- **PR-9 closure** (commit `3a0f263`, on the deleted `spike/cubic-additive-stale`
  branch) — analogous research-closure note for the Cubic toggle hypothesis.
