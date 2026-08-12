# ADR 0037 — Drop the never-reporting `GitGuardian Security Checks` required context

**Status:** REVERSED 2026-08-12 — see [Reversal](#reversal-2026-08-12). The
decision below was acted on (PR #630) and then undone. The Context section is
retained verbatim as the historical record: its three probes are each a
plausible-looking way to conclude a live app is dead, and knowing them is the
durable value of this ADR.
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

---

## Reversal (2026-08-12)

**The app was live for the measured PR-head sample.** The first revisit trigger
above fired immediately — not because anything was reconnected, but because the
premise was wrong. Every line of evidence in Context was a measurement
artifact, each from a different cause. Re-measurement below covers 14 PR heads
observed on 2026-08-12; it does not claim the app never failed outside that
sample:

| Probe used | Why it saw nothing |
|---|---|
| `commits/<sha>/statuses` on the PR head | GitGuardian posts a **check-run**, not a legacy commit status. The same commit `e30f7567` reports `completed/neutral`, `app=gitguardian`, via `commits/<sha>/check-runs`. |
| Six most recent commits on `main` | GitGuardian is **PR-scoped** and does not run on pushes to `main` at all. Confirmed absent on `7f5313d2`, `ca5caf4b`, `82990ad4` while each of the PR heads that produced them reported. Absence on `main` is this app's normal state. |
| `gh pr checks 630` → `pending`, 0s | A **sampling window**, not a permanent state. GitGuardian took **27m57s** on #630; this ADR was written inside that window. It later completed, and `gh pr checks 630` now shows `skipping 27m57s`. |

Re-measured across recent PRs: **14/14 final heads reported**
(`#607 #609 #610 #613 #614 #617 #619 #620 #621 #628 #630 #633 #636 #634`).
Conclusions are a mix of `success` and `neutral`. Intermediate commits of a
multi-commit push have no run — expected, since checks run per push.

### `neutral` was the second wrong assumption

`neutral` never blocked anything, so it was not evidence of a broken gate:

- GitHub's own docs: *"Required status checks must have a `successful`,
  `skipped`, or `neutral` status before collaborators can make changes to a
  protected branch."*
- This repo's tooling agrees. `gh pr checks` renders `neutral` as `skipping`;
  `scripts/relevant-check-status.sh` counts a row failed only for
  `fail|failure|cancel|cancelled` and pending only for
  `pending|queued|in_progress|expected`. `skipping` is neither, and the name is
  present in `reported`, so it does not trip the #515 no-row rule either.

The `pending=1` / `mergeStateStatus=BLOCKED` reading was therefore correct **for
that moment** — the check genuinely had not finished yet.

### What the removal actually did

It created the exact downgrade the original Consequences section named as the
one way this could go wrong: a real GitGuardian `failure` conclusion could not
block a merge. Gitleaks (`Secret scanning`) remained required throughout, so
secrets were never wholly ungated, but the two tools' coverage is not identical.

### Decision (reversed)

Restore `GitGuardian Security Checks` to **both** halves — branch protection and
`required[]` — in that order, since surface (b) enforces set equality. Back to
12 required contexts.

Accepted cost: **wait time, not blockage.** A check that can take ~28 minutes
now sits on the merge path, so pr-grind must outwait it; verify that against
`--max-wait` rather than assuming the default 8 rounds covers it.

### What still stands from #631

The two tooling gaps are real and worth fixing regardless — arguably more so,
since a surface that reports `ok` after skipping every input is what let a wrong
diagnosis look confirmed:

- Surface (c) must not print `ok` when it skipped **all** of its inputs.
  No-evidence should fail closed.
- A liveness surface for `required[]` entries is still worth having — but it
  must sample **PR heads via the Checks API**, not `main` via `/statuses`, or it
  will reproduce this exact error.

Both are now closed (#648). Surface (c) selects a sample commit that actually
carries a required check-run — the old "has any check-run" rule stopped at
`[skip ci]` release commits, which are not bare because CodeQL still posts
there — and its `ok` line now names how many of the required checks it
verified, because a partial sample is the normal state on `main`. Surface (f)
is the liveness check, built to the constraint above: merged PR heads, Checks
API, presence rather than conclusion — and matched on the reporting app, not
the name alone, which incidentally gives the PR-scoped entries the `source_app`
check (c) can never run on them. Run against this repo it reports GitGuardian
live and reported by `gitguardian`, which is the answer #631 needed and could
not get. It also refuses to answer when the sample cannot support one. Each
required check is dated by its own most recent sighting, not by the sample's
newest merge: a check whose last sighting has aged out is reported stale even
when other checks are current. That matters because a required app going dark
blocks every PR, which freezes the sample on pre-outage merges that all still
carry the name — under one summary date those frozen sightings read as fresh.

### Lesson

Before removing a security control on the evidence that it "never reports",
check that you queried the API it actually posts to, on the population it
actually runs against, outside its latency window. All three were wrong here,
and each independently produced a confident null.
