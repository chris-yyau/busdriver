#!/usr/bin/env bash
# tests/test-pr-grind-stall-redispatch-558.sh — pins the #558 rule in
# skills/pr-grind/SKILL.md: a worker killed as "[Request interrupted by user]"
# after a stall is re-dispatched once, never treated as an operator stop.
#
# shellcheck disable=SC2016  # backticks are literal markdown being matched
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/pr-grind/SKILL.md"
FAIL=0
need() { if grep -qF -- "$1" "$SKILL"; then echo "PASS: $1"; else echo "FAIL: missing: $1"; FAIL=1; fi; }

need 'a stalled worker is not an operator stop (#558)'
need '[Request interrupted by user]'
need 'never ends the run `TERMINAL`'
need 're-dispatch the SAME round once'
# Evidence bars: all three stall conditions must hold, the gap comes from the
# dispatched worker's own transcript, and a moved HEAD is not retried.
need 'your own turn is still running'
need 'no operator message has arrived since the dispatch'
need 'at least 600s between its last event and the kill'
need 'agent-<agentId>.jsonl'
need 'Never pick one by globbing'
need 'If you cannot establish the gap'
need 'equals the `GRIND_HEAD_SHA` you dispatched with'
need 'BAIL `env` if the refreshed `GRIND_HEAD_SHA` differs from the one you dispatched with'
need 'pr-grinder stalled twice on round <N> (#558)'
# Invariant 4 counters carry forward; no timestamp reconstruction (#976 review).
need 'Carry `total_scope_skipped` and `total_issues_spawned` forward unchanged'
need 'Do not reconstruct them from GitHub timestamps'
need 'Invariant 4 can overshoot either cap by at most 3 after a stall'
need 'as handled instead of spawning another issue'
need 'That context line must also spell out the deduplication below'
need 'and the #558 stalled-worker exception below does not apply'
need 'posting the reply citing the issue, resolving the thread'
need 'the worktree and the index may both hold its partial edits'
need '`git add` every fix it keeps, because the dispatcher commits only the index'
need 'records each disposition it finishes as its own round'"'"'s dismissal'
if grep -qF 'date -u +%Y-%m-%dT%H:%M:%SZ' "$SKILL"; then echo 'FAIL: timestamp window is back'; FAIL=1; else echo 'PASS: no timestamp window'; fi

# The rule must sit after the generic unparseable bail it overrides.
bail=$(grep -nF 'then bail "subagent output unparseable" — do not guess' "$SKILL" | head -1 | cut -d: -f1)
rule=$(grep -nF 'a stalled worker is not an operator stop (#558)' "$SKILL" | head -1 | cut -d: -f1)
if [[ -n "$bail" && -n "$rule" && "$rule" -gt "$bail" ]]; then
  echo "PASS: #558 exception follows the unparseable bail"
else
  echo "FAIL: #558 exception not placed after the unparseable bail (bail=$bail rule=$rule)"; FAIL=1
fi

exit "$FAIL"
