# ADR 0054 — pr-grind stops at Ready for Shipping in opted-in repos

## Status

**Accepted (2026-10-08).** Plan: `docs/plans/2026-10-07-pr-grind-shipping-handoff.md`
(blueprint-review PASS, FULL 3/3, round 3). It replaced a first draft that flipped
pr-grind's global default to "never merge".

## Context

Cursor Cloud **Shipping** (pstack `poteto-mode/playbooks/shipping.md`) lands a PR only
after an independent per-PR verdict. That verdict comes from an agent that did not write
the code and that exercises the real surface, parent against head. If pr-grind merges
first, or leaves a `pr-grind-clean.local` that lets a local `gh pr merge` through,
Shipping has nothing left to gate.

The value is in the website repos (chrisyau.me, jikdak, diveand.dev, and future apps),
where SEO and visual regressions survive green CI. busdriver itself has no stacked PRs
and no UI surface.

Measured 2026-10-07 over the last 50 merged PRs per repo, none of them stacked. These
are the PRs that would need Shipping under the skip list below:

| Repo | PRs needing Shipping |
|---|---|
| diveand.dev | 37/50 |
| chrisyau.me | 48/50 |
| jikdak | 47/50 |

A hand-tuned per-repo list skipped only 4 more of the 150 PRs, and it never skipped a PR
that the universal list sent to Shipping.

## Decision

- **Opt-in.** A repo opts in when the PR's *base commit* tree contains a directory
  `.cursor/skills/verify-<site>/`, the layout pstack `/create-verification-skill`
  generates. The tree is read through the git trees API at `baseRefOid`.
  - Absence is decided only from a successful listing that omits the entry. A 404 is an
    error, never "not opted in".
  - A PR cannot opt its own repo out: removing the skill touches `.cursor/skills/**`,
    which routes to Shipping.
  - Shipping without a verify skill is no better than green CI, so the prerequisite
    and the switch are one artifact.
- **Universal skip list, built into `scripts/needs-shipping.py`.** A PR skips
  Shipping only if every changed path matches the list, counting `previous_filename`
  for renames:
  - `docs/**`
  - root-level `*.md`
  - `.claude/**/*.md`
  - `__tests__/**` and `tests/**`
  - `*.test.ts` and `*.test.tsx`
  - `.github/lighthouse.baseline.json`

  The list is not configurable per repo, so no PR in a gated repo can edit it.
- **Routing runs on every clean completion, `--no-merge` included**, before the
  marker write. The classifier's result decides what happens next:
  - `merge` (exit 0): the existing marker and merge paths run unchanged.
  - `shipping mergeStateStatus=<S>` (exit 10): pr-grind removes `pr-grind-clean.local`
    and `pr-pending-grind.local` from the session root and from the original worktree
    root, reports Ready for Shipping, and stops.
  - Anything else: pr-grind removes the same markers and BAILs `env`. It never merges.
- **No new flags.** The operator escape for landing a Shipping-routed PR locally is the
  existing audited `.claude/skip-pr-grind.local`.
- **Merge readiness is reported, not enforced.** On the Shipping path, Branch-Currency
  and Approver-Gap detection do not run. Instead the Ready line carries the
  `mergeStateStatus` and warns on `BEHIND`, `BLOCKED`, `DIRTY`, `DRAFT` or `UNKNOWN`.
  Shipping rebases the bottom PR itself. As of 2026-10-07, none of the three target
  repos had required reviews or rulesets on `main`.
- **Interpreter: `/usr/bin/python3 -I`.**
  - The absolute path avoids PATH hijack.
  - `-I` drops `PYTHONPATH` and the user site.
  - A missing interpreter is a visible BAIL, not a silent gate loss.

  This is not the gate-launch first-hop role that ADR 0049 rejected `/usr/bin/python3`
  for. There, its absence would have failed open silently. The code stays
  3.9-compatible. `gh` runs with `GH_HOST=github.com` and with `GH_REPO` removed.

## Alternatives

- **Flip the global default to never-merge (the first draft).** Rejected. It would stop
  every PR in every repo, busdriver included, and hand each one to a verifier for which
  no repo yet has a control skill.
- **A per-repo `.shipping.json` declaration.** Rejected. It saved 4 of 150 PRs, cost one
  file of upkeep per repo, and needed base-branch reads to stop a PR from editing its
  own exemptions.
- **A separate opt-in marker, or a gitignored `.claude/*.local` opt-in.** Rejected. The
  first can drift from the verify skill. Cursor Cloud agents and other machines (um)
  never see the second.
- **Letting the authoring agent decide whether Shipping is needed.** Rejected: it would
  be the author exempting itself from independent verification.

## Consequences

- Non-opted-in repos, busdriver included, keep their merge behavior. They gain one new
  failure mode: a GitHub API or interpreter failure during the opt-in check BAILs
  `env`. A non-opted-in repo makes no `pulls/<n>/files` call, only one `gh pr view`,
  one to three trees calls, and a second `gh pr view`.
- **Opt-out procedure.** A PR that removes the last `verify-*` skill routes to Shipping,
  but Shipping has no skill left at that head. The operator lands that one PR through
  `.claude/skip-pr-grind.local`. After it merges, the repo is no longer opted in.
- The classifier binds to the reviewed head and re-checks both head and base before it
  answers. A base move between its last read and Shipping's own landing is still
  possible; Shipping re-checks the patch itself (its step 3).
- `pr-grind-clean.local` is one file per repo root, so removing it on the Shipping path
  can also drop another PR's marker in that root. That only makes the other merge
  block, and the existing writer already overwrites other PRs' markers.
- Per-PR Codex retrigger markers are not pruned on the Shipping path, because the PR is
  not merged there.
- `gh` is pinned to github.com, so a GitHub Enterprise host is not supported.
- `dependabot-auto-merge.yml` in chrisyau.me and jikdak merges without pr-grind and so
  bypasses Shipping. That is a per-repo follow-up.

## Revisit trigger

- An opted-in repo serves content from a skip-list path, such as a docs site under
  `docs/**`. Add a per-repo override then.
- The trial, about 10 Shipping-routed PRs, shows Shipping costing more than it catches.
- Stacked PRs appear in an opted-in repo.
- A routing BAIL in a non-opted-in repo is observed to cost real time. Add a bounded
  retry then.
- A required-review rule or a ruleset is added to an opted-in repo. Then `BLOCKED`
  needs its own handling.
