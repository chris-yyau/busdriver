# Shell gate-test inventory (CI coverage)

**Source of truth for the live per-test table:** `scripts/ci/run-shell-tests.sh`
prints `PASS`/`SKIP`/`FAIL` for every discovered `tests/test-*.sh` on each run
(local and CI are identical). This note records the audit *methodology* and the
one deliberate skip — it intentionally does **not** hardcode a per-test row table,
which would drift the moment a suite is added or renamed. Read the runner output
(CI logs, or `bash scripts/ci/run-shell-tests.sh`) for the current table.

## Why this exists

Before PR-B, the CI `shell-tests` job hand-listed ~15 of the suites; every other
gate/security suite was never executed in CI. `run-shell-tests.sh` replaces that
list with a full glob, so a gate regression can no longer slip past because its
test was never wired in.

## Classification

- **PASS** — exit 0, last non-empty output line is not a `SKIP:` marker.
- **SKIP** — exit 0 and the last non-empty line matches `^SKIP:` (the repo's
  established `echo "SKIP: …"; exit 0` self-skip convention). Mid-test sub-case
  SKIP prints don't count — those suites still end on a pass/fail summary, so a
  mid-file `SKIP:` is invisible to the guard below (#821: the zsh-portability rows
  skipped silently for as long as the runner had no zsh). A suite whose dependency
  CI installs (zsh via `tests.yml`) must FAIL under `GITHUB_ACTIONS` when it is
  missing, not skip.
- **FAIL** — any non-zero exit (incl. 124 = per-test timeout).

## Skip-masking guard (fail-closed allowlist)

Only the tests in `SKIP_ALLOWED` (`run-shell-tests.sh`) may report `SKIP`. Any
other test that skips — a gate/security suite, or a suite that started
self-skipping because a CI dependency went missing — fails the job as a coverage
regression. This is an **allowlist**, not a denylist of "protected" suites:
coverage can only be dropped by a conscious edit to `SKIP_ALLOWED`, which
extends "gate suites always PASS, never SKIP" to *every* non-allowlisted suite.
The allowlist currently holds exactly one entry (the live-claude test below).

## Runner-safety evidence (2026-07-13)

The first CI run of the full glob failed 4 suites that had never run in CI before
(the old job hand-picked ~15 known-safe tests). A local proxy that only stripped
the AI CLIs from `PATH` was **not** faithful enough — it kept the system's bash
(3.2) and an *authenticated* `gh`. The real ubuntu runner (bash 5.x, unauthenticated
`gh`) exposed pre-existing, non-hermetic assumptions in those 4 tests, since fixed:

| Test | CI-only failure | Fix |
|------|-----------------|-----|
| `test-dispatcher-commit-block` | `${var?}` guard misfires — `local x` (no value) is *unset* on bash ≥5, *set-empty* on 3.2 | declare fixture vars with `=""` |
| `test-pre-merge-gate` | gate's real `gh pr checks` fails-closed without auth | hermetic `gh` stub (required checks pass, names from the lock) |
| `test-pr-excluded-only-autopass` | stub-codex empty output → litmus retry backoff (30/60/120s) → 120s timeout | pin `LITMUS_CODEX_RETRIES=1`, low delay |
| `test-review-loop-noninteractive` | BSD `script` syntax; util-linux needs `-c` | detect the `script` variant |

Re-verified under a faithful proxy — full glob under **bash 5.3 + unauthenticated
`gh` + `CI=true`**:

```
discovered=67  pass=67  skip=0  fail=0
```

There are now **no** permitted self-skips: the sole entry
(`test-gateway-arbiter-claude-json-residual`, gated behind
`BLUEPRINT_ARBITER_LIVE_TEST=1`) was deleted along with the gateway rung it
exercised (ADR 0019), so `SKIP_ALLOWED` is empty and every discovered test must run
to completion.

## Sharding (2026-09-27)

CI runs the suite as `shell-tests-shard (1..4)`: advisory legs, each executing the
slice `run-shell-tests.sh --shard I/4` computes from the live glob and
`scripts/ci/shell-test-durations.tsv` (longest-first greedy; unknown tests weigh
10s). The REQUIRED `shell-tests` check is an aggregate that runs `if: always()` and
`--reconcile`s the legs' completion records against the glob at the same commit. It
fails if any test is unassigned, assigned twice, missing its completion record or not
passing. It also fails on a missing or unfinished leg and on a malformed or spliced
record. The weights only balance the legs; correctness never depends on them being
current. Design: `docs/plans/2026-09-27-ci-shard-shell-tests.md`.

Refresh the weights when a leg drifts well past the others. The aggregate prints one
`duration<TAB><test><TAB><seconds>` line per test. `gh run view --log` prefixes each
line with `<job><TAB><step><TAB><timestamp> `, with a space after the timestamp, so
extract with awk (portable to macOS, unlike `grep -P`). Keep the file's 3-line header
comment by hand; the command prints only the data lines, sorted by seconds descending:

```bash
gh run view <run-id> --job <aggregate-job-id> --log \
  | awk -F'\t' '{ sub(/^[^ ]* /, "", $3) } $3 == "duration" { print $4 "\t" ($5 < 1 ? 1 : $5) }' \
  | sort -t "$(printf '\t')" -k2,2nr -k1,1
```

Local runs (`bash scripts/ci/run-shell-tests.sh`, no args) still execute every test.
They now also print each test's duration and any mid-file sub-case `SKIP` lines.
