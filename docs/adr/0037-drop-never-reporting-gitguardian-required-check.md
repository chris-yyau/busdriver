# ADR 0037 — Drop the never-reporting `GitGuardian Security Checks` required context

**Status:** Accepted
**Date:** 2026-08-11

## Context

`main`'s branch protection required 12 status contexts. One of them,
`GitGuardian Security Checks` (`source_app: gitguardian`, the only
`.github/required-checks.lock` entry with no `workflow` field), has **never been
reported by any app**.

Evidence gathered while running pr-grind on PR #630:

- `gh pr checks 630` rendered it `pending`, 0s elapsed, generic
  `dashboard.gitguardian.com` URL — GitHub's rendering of an *expected* required
  context that never posted. Every other check passed.
- The PR head's `commits/<sha>/statuses` payload contained only CodeRabbit
  entries. No GitGuardian.
- The six most recent commits on `main` (`9cd52ddd`, `8209074c`, `e086aa55`,
  `4787cd31`, `4617e388`, `ed02a73f`) had no GitGuardian status either.

`scripts/relevant-check-status.sh` therefore returned `pending=1` — correct
behaviour under #515, where a lock-required check with no run counts as pending
rather than absent — and `mergeStateStatus` was `BLOCKED`. So the context was not
gating anything; it was blocking *everything*, permanently, while providing zero
coverage. pr-grind converged clean on #630 and then correctly refused to merge.

The repo's own drift detector did not catch this. `scripts/check-required-checks.sh`
exits 0: surface (b) compares lock↔server sets and both contained the dead name,
and surface (c) samples the latest commit on `main` — routinely a
`chore(release): … [skip ci]` commit with no checks — so it emitted
`warn: no check-run named '<name>' on HEAD` for all 12 required checks and still
printed `ok`. Tracked as #631.

## Decision

Remove `GitGuardian Security Checks` from **both** halves, which must move
together because surface (b) enforces set equality between them:

1. Branch protection — `PATCH .../branches/main/protection/required_status_checks`
   with the surviving 11 checks, preserving `strict: true` and each check's
   `app_id` pin.
2. `.github/required-checks.lock` — delete the entry from `required[]`.

Secret scanning remains gated: `Secret scanning` (gitleaks, `security.yml`) is
still required and still reporting.

## Alternatives

- **Move the entry to `advisory[]` instead of deleting it.** Rejected on review.
  That list is documented as an assertion that "its failure is safe to merge
  past" — a claim worth avoiding for a security scanner, and one that would
  become false the moment the app reconnected. Deleting the entry asserts
  nothing.
- **Reconnect the GitGuardian App.** Not exclusive with this decision, and
  strictly better if the operator wants the coverage — but it is out-of-band
  configuration that cannot unblock the PR in front of us. If it happens, see
  the revisit trigger.
- **One-off `--admin` merge of #630.** Leaves the dead gate in place, so the
  next PR hits the identical wall. Repairs nothing.
- **Add `workflow_dispatch:` to `tests.yml` / `security.yml`** as a manual
  re-run lever. Rejected — see Consequences.

## Consequences

- Every PR can reach a mergeable state again. 11 required contexts, all with a
  live reporter.
- Secret-scanning coverage is unchanged in practice: it was already entirely
  carried by gitleaks, since GitGuardian never ran.
- The one way this becomes a downgrade rather than a repair is a silent
  reconnection of the GitGuardian App — the check would then post, but
  non-blockingly. The `_doc` note in `required-checks.lock` records the
  obligation to re-add it to both surfaces in that case.
- **A related trap, found while attempting the alternative above and worth
  recording so the next attempt does not repeat it:** adding `workflow_dispatch`
  to `tests.yml`/`security.yml` would create a path that *satisfies* required
  contexts without executing them. `commitlint` and `version-drift` are guarded
  by `if: github.event_name == 'pull_request'`, so on a manual run they post as
  **skipped** — and GitHub counts a skipped required check as satisfied. Any
  future manual-rerun lever must first make those jobs either run or fail on a
  non-PR event.

## Revisit trigger

- The GitGuardian App is connected to this repo and starts posting statuses →
  re-add `GitGuardian Security Checks` to branch protection **and** to
  `required[]` here, in that order.
- #631 lands a surface that fails when a required context has no successful
  report in a recent window → this ADR's evidence-gathering becomes automated,
  and the manual commit-status archaeology above is no longer the detection
  mechanism.
