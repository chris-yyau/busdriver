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

# --- Tests for Case 2 (one-and-done COMMENTED downgrade) ---
# These tests exercise the downgrade block (no threads, stale commit_id),
# which requires a non-empty ALL_REVIEWS fixture. The run_ledger helper
# uses EMPTY_REVIEWS, so we use a separate helper here.
STALE_COMMIT="oldcommit"
run_ledger_reviews() {
  # $1 = ALL_REVIEWS json
  FETCH_OK=1 \
  ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
  ALL_REVIEWS="$1" \
  ALL_COMMENTS='{"comments":[]}' \
  ALL_CHECK_RUNS='{"check_runs":[]}' \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" greptile-apps 2>/dev/null
}

# --- Test 7: COMMENTED on stale commit, ever_approved==0 → none (new Case 2 behavior) ---
COMMENTED_REVIEWS=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"PR overview summary."}]' "$STALE_COMMIT")
got=$(run_ledger_reviews "$COMMENTED_REVIEWS")
if [ "$got" = "none" ]; then
  ok "COMMENTED stale commit ever_approved=0 → none (Case 2 new behavior)"
else
  fail "COMMENTED stale commit ever_approved=0 expected 'none', got '$got'"
fi

# --- Test 7b: COMMENTED with multi-line body (Copilot PR-overview format) → none ---
# Validates that read ordering (ever_approved, last_state, last_body) is correct so a
# multi-line body does not corrupt last_state. A single-line body (Test 7) would pass
# even with the old wrong ordering; this test catches a regression to body-before-state.
COMMENTED_MULTILINE=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"## PR Overview\\n\\nThis PR adds a new downgrade case.\\n\\nDetails follow."}]' "$STALE_COMMIT")
got=$(run_ledger_reviews "$COMMENTED_MULTILINE")
if [ "$got" = "none" ]; then
  ok "COMMENTED stale commit multi-line body → none (read ordering robust)"
else
  fail "COMMENTED stale commit multi-line body expected 'none', got '$got'"
fi

# --- Test 8: COMMENTED on stale commit with prior APPROVED → stale (guard holds) ---
COMMENTED_WITH_APPROVAL=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"APPROVED","commit_id":"%s","body":"LGTM"},{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"PR overview summary."}]' "$STALE_COMMIT" "$STALE_COMMIT")
got=$(run_ledger_reviews "$COMMENTED_WITH_APPROVAL")
if [ "$got" = "stale" ]; then
  ok "COMMENTED after prior APPROVED → stale (ever_approved guard)"
else
  fail "COMMENTED after prior APPROVED expected 'stale', got '$got'"
fi

# --- Test 9: CHANGES_REQUESTED on stale commit → stale (must not be downgraded) ---
CR_REVIEWS=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"CHANGES_REQUESTED","commit_id":"%s","body":"Please fix this issue."}]' "$STALE_COMMIT")
got=$(run_ledger_reviews "$CR_REVIEWS")
if [ "$got" = "stale" ]; then
  ok "CHANGES_REQUESTED stale commit → stale (must not downgrade)"
else
  fail "CHANGES_REQUESTED stale commit expected 'stale', got '$got'"
fi

# --- Test 10: [CHANGES_REQUESTED(A), COMMENTED(B)] history → stale (the closed gap) ---
# This is the precise scenario Greptile/Copilot/Cubic flagged: a history where
# a real CHANGES_REQUESTED finding was filed on commit A, then a non-actionable
# COMMENTED review landed on commit B. Without CHANGES_REQUESTED in the
# ever_approved filter, Case 2 would downgrade to `none`. With the fix, it stays `stale`.
CR_THEN_COMMENTED=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"CHANGES_REQUESTED","commit_id":"%s","body":"Finding body only — no inline threads."},{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"PR overview summary."}]' "$STALE_COMMIT" "$STALE_COMMIT")
got=$(run_ledger_reviews "$CR_THEN_COMMENTED")
if [ "$got" = "stale" ]; then
  ok "[CHANGES_REQUESTED(A), COMMENTED(B)] history → stale (closed gap)"
else
  fail "[CHANGES_REQUESTED(A), COMMENTED(B)] history expected 'stale', got '$got'"
fi

# --- Test 11: COMMENTED on stale commit with prior DISMISSED → stale (guard holds) ---
COMMENTED_WITH_DISMISSED=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"DISMISSED","commit_id":"%s","body":"Previously approved"},{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"PR overview."}]' "$STALE_COMMIT" "$STALE_COMMIT")
got=$(run_ledger_reviews "$COMMENTED_WITH_DISMISSED")
if [ "$got" = "stale" ]; then
  ok "COMMENTED after prior DISMISSED → stale (ever_approved guard)"
else
  fail "COMMENTED after prior DISMISSED expected 'stale', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
