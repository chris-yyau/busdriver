#!/usr/bin/env bash
# tests/test-ack-ledger-devin.sh
#
# Verifies scripts/ack-ledger.sh handles `devin-ai-integration` (Devin Review)
# correctly as a registered gating bot in the pr-grind ack panel.
#
# Devin is a PLAIN Tier A / Tier B bot (like CodeRabbit) — it needs no
# Devin-specific code in ack-ledger.sh; these tests pin that the generic tiers
# gate it correctly:
#   - actionable findings post as inline review THREADS -> Tier A -> `stale`,
#     with precedence OVER the Tier B clean-ack;
#   - a clean COMMENTED-on-HEAD review -> Tier B HEAD-ack (NOT a deadlock);
#   - a resolved/outdated thread -> Tier A disposed HEAD-ack.
#
# Devin is deliberately OFF Tier E: its `Devin Review` commit-status goes
# pending -> SUCCESS even when the review HAS findings (verified on PRs
# #238/#240/#241), so a status-based ack would be unsafe (Codex P1 on #241).
# HEAD coverage instead comes from the `Devin Review` GitHub check, which
# pr-grind Step 1 waits on. These tests confirm a `success` status never
# rescues an otherwise-stale Devin into a HEAD-ack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [ ! -f "$ACK_SCRIPT" ]; then
  fail "ack-ledger.sh missing at $ACK_SCRIPT"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

HEAD_SHA="abc12345"
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_REVIEWS='[]'
EMPTY_COMMENTS='{"comments":[]}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_STATUSES='[]'
DEVIN_STATUS_SUCCESS='[{"context":"Devin Review","state":"success","created_at":"2026-06-23T06:40:00Z","id":2}]'

run() {
  # $1=login $2=threads $3=reviews $4=statuses
  FETCH_OK=1 \
  ALL_THREADS="$2" \
  ALL_REVIEWS="$3" \
  ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  ALL_STATUSES="$4" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$1" 2>/dev/null
}

mk_devin_thread() {
  # $1=isResolved $2=isOutdated
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRT_1","isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":{"login":"devin-ai-integration[bot]"}}]}}]}}}}}' "$1" "$2"
}

# Clean COMMENTED /reviews whose commit_id direct-matches HEAD (acks_head 8-char
# prefix, no git). A clean Devin review acks here via Tier B exactly like CodeRabbit.
DEVIN_COMMENTED_HEAD='[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","commit_id":"abc12345","body":"Devin Review: no issues found."}]'

# --- Test 1: unresolved Devin thread -> stale (Tier A findings gate) ---
got=$(run devin-ai-integration "$(mk_devin_thread false false)" "$EMPTY_REVIEWS" "$EMPTY_STATUSES")
if [ "$got" = "stale" ]; then
  ok "unresolved Devin thread -> stale (Tier A findings gate)"
else
  fail "unresolved Devin thread expected 'stale', got '$got'"
fi

# --- Test 2: Tier A precedence — unresolved thread + clean COMMENTED + success status -> stale ---
# The decisive P1-adjacent case: even with a clean-looking COMMENTED /reviews on
# HEAD AND a `success` status, an unresolved finding thread keeps Devin `stale`.
# Tier A runs before Tier B, and Devin is off Tier E, so neither rescues it.
got=$(run devin-ai-integration "$(mk_devin_thread false false)" "$DEVIN_COMMENTED_HEAD" "$DEVIN_STATUS_SUCCESS")
if [ "$got" = "stale" ]; then
  ok "unresolved thread beats clean COMMENTED + success status -> stale (Tier A precedence; off Tier E)"
else
  fail "unresolved thread + clean COMMENTED + success status expected 'stale', got '$got'"
fi

# --- Test 3: clean COMMENTED-on-HEAD -> HEAD_SHA via Tier B (NO deadlock) ---
# Devin is NOT excluded from Tier B (excluding it would deadlock clean reviews on
# `stale` forever). A clean COMMENTED on HEAD acks like CodeRabbit.
got=$(run devin-ai-integration "$EMPTY_THREADS" "$DEVIN_COMMENTED_HEAD" "$EMPTY_STATUSES")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean Devin COMMENTED-on-HEAD -> HEAD_SHA (Tier B clean-ack; no deadlock)"
else
  fail "clean Devin COMMENTED-on-HEAD expected '$HEAD_SHA', got '$got'"
fi

# --- Test 4: resolved Devin thread -> HEAD_SHA (Tier A disposed ack) ---
got=$(run devin-ai-integration "$(mk_devin_thread true false)" "$EMPTY_REVIEWS" "$EMPTY_STATUSES")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved Devin thread -> HEAD_SHA (Tier A disposed ack)"
else
  fail "resolved Devin thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 5: success status ALONE (no /reviews, no thread) -> none (off Tier E) ---
# Confirms the `Devin Review` success status is NOT itself an ack — Devin is off
# Tier E, so a bare status with no review/thread is non-gating `none`.
got=$(run devin-ai-integration "$EMPTY_THREADS" "$EMPTY_REVIEWS" "$DEVIN_STATUS_SUCCESS")
if [ "$got" = "none" ]; then
  ok "Devin success status alone -> none (off Tier E; status is not an ack)"
else
  fail "Devin success status alone expected 'none', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
