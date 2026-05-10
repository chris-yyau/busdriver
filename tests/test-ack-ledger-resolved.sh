#!/usr/bin/env bash
# tests/test-ack-ledger-resolved.sh
#
# Verifies scripts/ack-ledger.sh tier A treats resolved (non-outdated)
# threads as HEAD-acked, mirroring the existing outdated-thread escalation.
#
# Motivated by the pr-grind out-of-scope-acknowledged workflow: when the
# worker resolves a thread after dismissing a finding (spawn or audit-only),
# the bot's stale signal must clear or the merge gate blocks forever.
# Without this behavior, jikdak PR #129 stuck across 7+ rounds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [ ! -x "$ACK_SCRIPT" ] && [ ! -f "$ACK_SCRIPT" ]; then
  fail "ack-ledger.sh missing at $ACK_SCRIPT"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

# Common harness: one-page paginated graphql output containing a single
# thread node. The bot author appears as `greptile-apps[bot]` (the REST
# `[bot]` suffix); the script's jq filter accepts both bare login and
# `[bot]`-suffixed forms.
mk_threads_json() {
  # $1 = isResolved, $2 = isOutdated
  cat <<EOF
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRT_1","isResolved":$1,"isOutdated":$2,"comments":{"nodes":[{"author":{"login":"greptile-apps[bot]"}}]}}]}}}}}
EOF
}

# Empty fixtures for the other sources — we want tier A to be the only
# matching path, so tier B/C/D fall through.
EMPTY_REVIEWS='[]'
EMPTY_COMMENTS='{"comments":[]}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'

# Common HEAD_SHA. ack-ledger.sh emits this on tier A.2 escalation.
HEAD_SHA="abc12345"

run_ledger() {
  # $1 = ALL_THREADS json
  FETCH_OK=1 \
  ALL_THREADS="$1" \
  ALL_REVIEWS="$EMPTY_REVIEWS" \
  ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" greptile-apps 2>/dev/null
}

# --- Test 1: resolved + non-outdated thread → HEAD_SHA ---
# This is the new behavior. Before the tier A change, the script would
# fall through to the bottom and emit `stale` because the bot has no
# /reviews entry on HEAD.
got=$(run_ledger "$(mk_threads_json true false)")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved+non-outdated thread → HEAD_SHA (was $got)"
else
  fail "resolved+non-outdated thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 2: outdated thread → HEAD_SHA (regression check) ---
# Prior behavior; must not regress under the disposed=outdated|resolved filter.
got=$(run_ledger "$(mk_threads_json false true)")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "outdated thread → HEAD_SHA (regression check; got $got)"
else
  fail "outdated thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 3: resolved AND outdated thread → HEAD_SHA ---
# Either flag should escalate; both flags should also escalate (no double-counting bug).
got=$(run_ledger "$(mk_threads_json true true)")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved+outdated thread → HEAD_SHA (got $got)"
else
  fail "resolved+outdated thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 4: unresolved + non-outdated thread → stale (regression check) ---
# Pre-existing tier A.1 behavior: real actionable finding must keep the
# bot stale. The disposed-filter widening must NOT swallow these.
got=$(run_ledger "$(mk_threads_json false false)")
if [ "$got" = "stale" ]; then
  ok "unresolved+non-outdated thread → stale (regression check)"
else
  fail "unresolved+non-outdated thread expected 'stale', got '$got'"
fi

# --- Test 4b: mixed — unresolved + resolved threads on same bot → stale ---
# Locks in the tier-A ordering: `unresolved > 0 → stale` short-circuits
# BEFORE `disposed > 0 → HEAD`. Without this test, a future refactor that
# accidentally reorders the two checks (or merges them into a single
# count) would silently pass the resolved-only / unresolved-only tests
# above but break the merge gate by acking a bot that still has open
# findings.
MIXED_THREADS=$(cat <<EOF
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRT_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"greptile-apps[bot]"}}]}},{"id":"PRT_2","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"greptile-apps[bot]"}}]}}]}}}}}
EOF
)
got=$(run_ledger "$MIXED_THREADS")
if [ "$got" = "stale" ]; then
  ok "mixed unresolved+resolved threads → stale (unresolved-priority ordering check)"
else
  fail "mixed unresolved+resolved threads expected 'stale' (unresolved must take priority), got '$got'"
fi

# --- Test 5: no threads at all → none (regression check) ---
# Bot didn't post on this PR. Falls through to the bottom and emits `none`.
NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
got=$(run_ledger "$NO_THREADS")
if [ "$got" = "none" ]; then
  ok "no threads → none (regression check)"
else
  fail "no threads expected 'none', got '$got'"
fi

# --- Test 6: FETCH_OK=0 → stale (fail-CLOSED regression check) ---
# Source-fetch failure must short-circuit to stale before tier A even runs;
# the disposed-filter change must not break this guard.
got=$(FETCH_OK=0 \
  ALL_THREADS="$(mk_threads_json true false)" \
  ALL_REVIEWS="$EMPTY_REVIEWS" \
  ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" greptile-apps 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "FETCH_OK=0 → stale (fail-CLOSED regression check)"
else
  fail "FETCH_OK=0 expected 'stale', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
