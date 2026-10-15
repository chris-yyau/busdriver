#!/usr/bin/env bash
# tests/test-pr-grind-stall-redispatch-558.sh — pins the #558 rule in
# skills/pr-grind/SKILL.md: a worker killed as "[Request interrupted by user]"
# after a stall is re-dispatched once, never treated as an operator stop.
#
# shellcheck disable=SC2016  # backticks are literal markdown being matched
set -uo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/pr-grind/SKILL.md"
FAIL=0
need() { if grep -qF -- "$1" "$SKILL"; then echo "PASS: $1"; else echo "FAIL: missing: $1"; FAIL=1; fi; }

need 'a stalled worker is not an operator stop (#558)'
need '[Request interrupted by user]'
need 'never ends the run `TERMINAL`'
need 're-dispatch the SAME round once'
# Evidence bars: the 600s gap must be shown, and a moved HEAD is not retried.
need 'at least 600s between its last event and the kill'
need 'If you cannot establish the gap'
need 'equals the `GRIND_HEAD_SHA` you dispatched with'
need 'pr-grinder stalled twice on round <N> (#558)'
# The killed attempt's out-of-scope side effects still feed Invariant 4.
need 'add them to `total_scope_skipped` and `total_issues_spawned`, and run Invariant 4'

# The rule must sit after the generic unparseable bail it overrides.
bail=$(grep -nF 'then bail "subagent output unparseable" — do not guess' "$SKILL" | head -1 | cut -d: -f1)
rule=$(grep -nF 'a stalled worker is not an operator stop (#558)' "$SKILL" | head -1 | cut -d: -f1)
if [[ -n "$bail" && -n "$rule" && "$rule" -gt "$bail" ]]; then
  echo "PASS: #558 exception follows the unparseable bail"
else
  echo "FAIL: #558 exception not placed after the unparseable bail (bail=$bail rule=$rule)"; FAIL=1
fi

exit "$FAIL"
