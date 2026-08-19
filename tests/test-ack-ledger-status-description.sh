#!/usr/bin/env bash
# tests/test-ack-ledger-status-description.sh
#
# Verifies scripts/ack-ledger.sh tier E rejects a commit status whose
# DESCRIPTION reports that the review did not happen (rate limit, quota,
# capacity, could-not-start), instead of treating every `success` state as a
# HEAD-ack.
#
# Motivated by a live merge-gate fail-open on chris-yyau/busdriver PR #709,
# HEAD f11de70b: CodeRabbit posted context=CodeRabbit / state=success /
# description="Review rate limited" / target_url=null, published NO check-run,
# and its only issue comment was the walkthrough (matching no notice regex).
# #353 had already identified this exact fail-open and guarded it, but scoped
# detection to the bot's issue-COMMENT body — so both comment-scoped predicates
# returned false, tier E HEAD-acked, and pr-grind merged recording CodeRabbit as
# having reviewed a head it never reviewed.
#
# `success` on the status channel means "the run terminated", NOT "the code was
# reviewed". Only descriptions that AFFIRMATIVELY report non-performance are
# demoted; an empty or ordinary description must still ack (pinned below), so
# this cannot become a blanket over-block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [[ ! -f "$ACK_SCRIPT" ]]; then
  fail "ack-ledger.sh missing at $ACK_SCRIPT"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

HEAD_SHA="abc12345"
# Spelled out rather than "${HEAD_SHA}0000...": referencing HEAD_SHA from a sibling
# env-prefix assignment reads the OUTER value, not the prefix one (SC2097/SC2098).
HEAD_FULL_SHA="abc1234500000000000000000000000000000000"

# Tier E is reached only for a bot with a status context — coderabbitai is the
# only login mapped to one. Empty threads/check-runs so tiers A and D cannot
# fire and the status channel is the sole deciding signal.
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_REACTIONS='[]'

# The walkthrough comment CodeRabbit actually posts: substantial prose that
# matches NO rate-limit notice regex. This is what made the comment-scoped
# guards return false on #709.
WALKTHROUGH_COMMENT='{"comments":[{"author":{"login":"coderabbitai[bot]"},"createdAt":"2026-01-01T00:00:00Z","body":"## Walkthrough\nThe post-merge hook now uses GitHub PR state to confirm merges."}]}'

# A prior COMMENTED review on an OLDER commit — the #709 shape, and the
# higher-risk subset: the bot filed findings before, then stopped on HEAD.
PRIOR_REVIEW='[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"Please qualify this by the API result."}]'
# No history at all — the bot never posted a review on this PR.
NO_REVIEWS='[]'

mk_status() {
  # $1 = state, $2 = description
  printf '[{"context":"CodeRabbit","state":"%s","description":"%s","target_url":null,"created_at":"2026-01-01T00:01:00Z","id":2}]' "$1" "$2"
}

run_ledger() {
  # $1 = ALL_STATUSES json, $2 = ALL_REVIEWS json
  FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" \
  ALL_REVIEWS="$2" \
  ALL_COMMENTS="$WALKTHROUGH_COMMENT" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  ALL_STATUSES="$1" \
  ALL_REACTIONS="$EMPTY_REACTIONS" \
  HEAD_SHA="$HEAD_SHA" \
  HEAD_FULL_SHA="$HEAD_FULL_SHA" \
  HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo "ERR"
}

# ---------------------------------------------------------------------------
# NEGATIVE CASES — a success status that reports non-performance must NOT ack.
#
# Terminal choice mirrors the existing comment-notice arm and must not be
# inverted: with prior review history the bot's earlier findings must keep
# blocking (`stale`); with no history there is nothing to preserve and `stale`
# would dead-end the PR until quota resets (#294), so `none` is correct.
# ---------------------------------------------------------------------------

# The exact #709 string.
status=$(mk_status success 'Review rate limited')
result=$(run_ledger "$status" "$PRIOR_REVIEW")
if [[ "$result" == "stale" ]]; then
  ok "#709 regression: success + 'Review rate limited' + prior review => stale (was HEAD-ack)"
else
  fail "#709 regression: expected 'stale', got '$result' — tier E fail-open is back"
fi

# Same status, no prior review history => `none`, not a HEAD-ack.
status=$(mk_status success 'Review rate limited')
result=$(run_ledger "$status" "$NO_REVIEWS")
if [[ "$result" == "none" ]]; then
  ok "success + 'Review rate limited' + no history => none (non-gating, no dead-end)"
else
  fail "expected 'none', got '$result'"
fi

# Sibling phrasings the same defect class produces.
for desc in \
  'Rate limit exceeded' \
  'Review skipped due to quota' \
  'At capacity, review not started' \
  "Couldn't start this review" \
  'Could not start review' \
  'Review not started'
do
  status=$(mk_status success "$desc")
  result=$(run_ledger "$status" "$PRIOR_REVIEW")
  if [[ "$result" == "stale" ]]; then
    ok "non-review description rejected: '$desc'"
  else
    fail "non-review description '$desc' produced '$result', expected 'stale'"
  fi
done

# ---------------------------------------------------------------------------
# POSITIVE CASES — an ordinary success must still HEAD-ack. These pin that the
# guard did not become a blanket block on the status channel.
# ---------------------------------------------------------------------------

# The last three are the exact strings a review flagged as wrongly demoted by an
# earlier, looser regex (bare `quota`/`capacity`/`skipped` alternatives). They
# describe reviews that DID run and must keep acking.
for desc in 'Review completed' 'No issues found' '' \
  'Review completed within quota' \
  'Capacity analysis completed' \
  'Review completed; generated files skipped'
do
  label="${desc:-<empty>}"
  status=$(mk_status success "$desc")
  result=$(run_ledger "$status" "$PRIOR_REVIEW")
  if [[ "$result" == "$HEAD_SHA" ]]; then
    ok "genuine review still acks HEAD: '$label'"
  else
    fail "genuine review description '$label' produced '$result', expected '$HEAD_SHA'"
  fi
done

# Non-success states are unchanged by this patch — still stale.
status=$(mk_status pending 'Review in progress')
result=$(run_ledger "$status" "$PRIOR_REVIEW")
if [[ "$result" == "stale" ]]; then
  ok "pending status unchanged => stale"
else
  fail "pending status produced '$result', expected 'stale'"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
