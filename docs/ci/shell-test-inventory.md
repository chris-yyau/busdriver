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
  SKIP prints don't count — those suites still end on a pass/fail summary.
- **FAIL** — any non-zero exit (incl. 124 = per-test timeout).

## Skip-masking guard (fail-closed allowlist)

Only the tests in `SKIP_ALLOWED` (`run-shell-tests.sh`) may report `SKIP`. Any
other test that skips — a gate/security suite, or a suite that started
self-skipping because a CI dependency went missing — fails the job as a coverage
regression. This is an **allowlist**, not a denylist of "protected" suites:
coverage can only be dropped by a conscious edit to `SKIP_ALLOWED`, which
extends "gate suites always PASS, never SKIP" to *every* non-allowlisted suite.
The allowlist currently holds exactly one entry (the live-claude test below).

## Headless-safety evidence (2026-07-13)

Full-glob run, then re-run with the AI CLIs (`codex`/`agy`/`droid`/`grok`)
stripped from `PATH` to simulate ubuntu-latest:

```
discovered=69  pass=68  skip=1  fail=0   (both runs identical)
skipped: test-gateway-arbiter-claude-json-residual
```

The suite is hermetic: identical result with the AI CLIs absent, so no suite
depends on live `codex`/`agy`/`droid`/`grok`. The only self-skip is
`test-gateway-arbiter-claude-json-residual`, gated behind
`BLUEPRINT_ARBITER_LIVE_TEST=1` (a real-claude round-trip test) — correct to skip
headless. It is **not** a gate suite, so the skip-masking guard permits it.
