#!/usr/bin/env bash
# test-check-suite-anchor-271.sh
# Regression for #271: the HEAD_CHECKS_DATE fallback freshness anchor must NOT
# filter check-suites on head_branch. GitHub emits ONE check_suite per commit
# SHA globally, so the suite's head_branch is whatever branch the SHA was first
# pushed to (or null for forks). The old `select(.head_branch==$branch and
# head_sha==$sha)` filter dropped the only suite whenever that branch differed
# from the PR branch, fail-closing a genuinely-fresh Codex ack to stale forever.
#
# This test exercises the EXACT jq filter used in scripts/fetch-pr-state.sh and
# the pr-grind markdown mirrors.
set -uo pipefail

# The canonical filter (must stay byte-identical to the shipped call sites).
# shellcheck disable=SC2016  # $sha is a jq --arg variable, not a shell expansion
FILTER='[.[].check_suites[]? | select(.head_sha==$sha) | .created_at] | map(select(. != null and . != "")) | sort | .[0] // empty'

pass=0 fail=0
check() {
  local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then echo "PASS: $name"; pass=$((pass+1))
  else echo "FAIL: $name — expected [$expected] got [$got]"; fail=$((fail+1)); fi
}

# 1. Cross-branch suite (head_branch != PR branch) is INCLUDED — the #271 fix.
got=$(printf '{"check_suites":[{"head_branch":"feature-x","head_sha":"deadbeef","created_at":"2026-07-01T00:00:00Z"}]}\n' \
  | jq -rs --arg sha "deadbeef" "$FILTER")
check "cross-branch suite included" "2026-07-01T00:00:00Z" "$got"

# 2. null head_branch (fork / not-detected) is INCLUDED.
got=$(printf '{"check_suites":[{"head_branch":null,"head_sha":"deadbeef","created_at":"2026-07-02T00:00:00Z"}]}\n' \
  | jq -rs --arg sha "deadbeef" "$FILTER")
check "null head_branch included" "2026-07-02T00:00:00Z" "$got"

# 3. EARLIEST created_at wins (fail-closed toward stale) when multiple suites.
got=$(printf '{"check_suites":[{"head_sha":"deadbeef","created_at":"2026-07-05T00:00:00Z"},{"head_sha":"deadbeef","created_at":"2026-07-03T00:00:00Z"}]}\n' \
  | jq -rs --arg sha "deadbeef" "$FILTER")
check "earliest created_at chosen" "2026-07-03T00:00:00Z" "$got"

# 4. A suite for a DIFFERENT SHA is excluded (head_sha guard retained).
got=$(printf '{"check_suites":[{"head_sha":"cafef00d","created_at":"2026-07-01T00:00:00Z"}]}\n' \
  | jq -rs --arg sha "deadbeef" "$FILTER")
check "different SHA excluded" "" "$got"

# 5. No suites → empty (ack-ledger fails closed to stale).
got=$(printf '{"check_suites":[]}\n' | jq -rs --arg sha "deadbeef" "$FILTER")
check "no suites → empty" "" "$got"

echo "───────────────────────────────"
echo "Total: $((pass+fail))  Pass: $pass  Fail: $fail"
[ "$fail" -eq 0 ]
