#!/usr/bin/env bash
# Regression guard for issue #325 / ADR 0016.
#
# A committed .claude/settings.json `env` block is merged into the Claude Code
# session environment, so a PR under review can set any env var the gate scripts
# read. The four gate-skip env vars (SKIP_LITMUS / SKIP_PR_GRIND /
# SKIP_DESIGN_REVIEW) were therefore removed — the git-resolved, operator-placed
# skip *file* is the only bypass. This test fails if any gate script re-introduces
# a shell READ of those vars (a bare word in a comment is fine; a `$SKIP_...` /
# `${SKIP_...}` expansion is not).
#
# Usage: bash tests/test-gate-env-skip-removed.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

GATES=(
  hooks/gate-scripts/pre-commit-gate.sh
  hooks/gate-scripts/pre-pr-gate.sh
  hooks/gate-scripts/pre-merge-gate.sh
  hooks/gate-scripts/pre-implementation-gate.sh
)

# Matches an actual shell expansion of a removed skip var ($SKIP_X or ${SKIP_X}),
# which only appears in a live read — not in the explanatory comments we kept.
READ_RE='\$\{?SKIP_(LITMUS|PR_GRIND|DESIGN_REVIEW)'

PASS=0
FAIL=0
for gate in "${GATES[@]}"; do
  if [[ ! -f "$gate" ]]; then
    echo "FAIL: $gate not found"; FAIL=$((FAIL + 1)); continue
  fi
  # Capture grep's status explicitly so a grep ERROR (rc>=2: unreadable file, bad
  # regex) fails CLOSED, instead of falling through the no-match (rc=1) PASS path.
  hits=$(grep -nE "$READ_RE" "$gate") && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: $gate reads a removed gate-skip env var (settings.json-injectable — #325 / ADR 0016):"
    echo "$hits"
    FAIL=$((FAIL + 1))
  elif [[ $rc -eq 1 ]]; then
    echo "PASS: $gate has no SKIP_* env-var read"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $gate — grep errored (rc=$rc); failing closed"
    FAIL=$((FAIL + 1))
  fi
done

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
