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
  'Review was skipped due to quota' \
  'At capacity, review not started' \
  "Couldn't start this review" \
  'Could not start review' \
  'Review not started' \
  "Review can't be started" \
  "Review couldn't be started" \
  "Review won't be started" \
  'Review could not be started' \
  'Could not start this review' \
  'Unable to start the review' \
  'Review was not completed' \
  'Review did not complete' \
  "Review couldn't complete" \
  'Could not complete this review' \
  'Unable to proceed, review was not started' \
  'Failed - review was skipped' \
  'Review unavailable, rate limit exceeded' \
  "Couldn't start" \
  'Unable to start' \
  'Review started; failed to complete' \
  'Review has yet to start' \
  'Review has yet to be completed' \
  'Review: not started' \
  'Review - not started' \
  'Review started. Failed to complete' \
  'Review started! Failed to complete' \
  'Review was unable to start' \
  'Review was unable to be started' \
  'Review is unable to complete' \
  'Review never started' \
  'Review never completed' \
  'Review failed to be completed' \
  'Review started. Failed to be completed' \
  'Could not start due to quota' \
  'Review started; failed to complete due to timeout' \
  'Review failed' \
  'Review failed due to timeout' \
  'Review -- not started' \
  'Review  was  not  started' \
  'Review timed out' \
  'Review did not finish' \
  'Review started: failed to complete' \
  'Review started - failed to complete' \
  'Review started,could not complete' \
  'Review started:was not completed' \
  'Review rate:limited' \
  'Review rate—limited' \
  'Review failed:see log' \
  'Review failed,retry later' \
  'Review failed—see log' \
  'No review was completed' \
  'No review was started' \
  'No review was completed due to quota' \
  'No review was completed, due to quota' \
  'No review was completed. Logs attached' \
  'No review was completed: service unavailable' \
  'No review was completed, service unavailable' \
  'No review was completed—due to quota' \
  'No review was completed–due to quota' \
  'No review was started; service unavailable' \
  'The review started, failed to complete' \
  'Code review started, failed to complete' \
  'Review started successfully, failed to complete' \
  'Review had successfully started, failed to complete' \
  'Review started,failed to complete' \
  'Review did not get completed' \
  "Review didn't get started" \
  ' Review started: failed to complete' \
  'Review was not able to start' \
  "Review wasn't able to start" \
  'Could not start a review' \
  'Unable to complete a review' \
  'Failed to start this review' \
  'Review completed; not rate limited' \
  'Review completed; no longer at capacity' \
  'Review failed: see log' \
  'Review failed, retry later' \
  'Review failed - contact support' \
  'Could not start this review: see log' \
  'Could not start this review, retry later' \
  'Unable to start this review: contact support' \
  'Failed to start this review: see log' \
  'Yet to start this review: see log'
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
# PROPERTY COVERAGE — the classifier must not hinge on one exact phrasing.
# Varies auxiliary verb x trailing context x capitalization over the two verb
# phrases bots actually use. A fixed example list is what let the passive form
# ("Review was skipped due to quota") slip past review once already.
# ---------------------------------------------------------------------------

prop_fail=0
# Natural phrase templates, NOT an aux x verb cross-product: the two families take
# different auxiliaries, and a blind product generates ungrammatical strings like
# "Review has been not started" while missing the real "Review has not started".
for phrase in \
  'Review skipped' \
  'Review was skipped' \
  'Review is skipped' \
  'Review has been skipped' \
  'Review not started' \
  'Review was not started' \
  'Review is not started' \
  'Review has not started' \
  'Review has not been started' \
  'Review not yet started' \
  'Review has not yet been started' \
  "Review hasn't started" \
  "Review wasn't started" \
  "Review didn't start" \
  'Review did not start' \
  'Review was aborted' \
  'Review cancelled' \
  'Review failed to start' \
  "Review can't start" \
  "Review won't start" \
  'Review cannot start' \
  'Review will not start'
do
  for suffix in '' ' due to quota' ' - see logs'; do
    lower="${phrase}${suffix}"
    upper=$(printf '%s' "$lower" | tr '[:lower:]' '[:upper:]')
    for desc in "$lower" "$upper"; do
      status=$(mk_status success "$desc")
      result=$(run_ledger "$status" "$PRIOR_REVIEW")
      if [[ "$result" != "stale" ]]; then
        fail "property: '$desc' produced '$result', expected 'stale'"
        prop_fail=$((prop_fail + 1))
      fi
    done
  done
done
if [[ "$prop_fail" -eq 0 ]]; then
  ok "property: 132 natural/contracted non-review phrasings (x suffix x case) all rejected"
fi

# A bare progress report is NOT a non-review — `not` is mandatory in the classifier.
status=$(mk_status success 'Review started')
result=$(run_ledger "$status" "$PRIOR_REVIEW")
if [[ "$result" == "$HEAD_SHA" ]]; then
  ok "'Review started' (no negation) still acks HEAD"
else
  fail "'Review started' produced '$result', expected HEAD-ack"
fi

# The inverse property: descriptions that CONTAIN a classifier keyword but report
# a review that ran must still ack. This is the over-block guard.
#
# NOTE the last two negative cases above are a DELIBERATE over-block, not a bug: a
# NEGATED budget claim in a trailing clause still demotes. Every normalization that
# removed the over-block introduced a fail-OPEN instead (it swallowed the verdict in
# "Review was not completed because rate limited", and left "Not rate limited" as an
# empty string indistinguishable from a broken pipeline). They are pinned here so a
# later round cannot quietly trade a visible stall for a silent ack.
#
# The trailing-clause cases pin the two-channel scope rule: an UNANCHORED denial
# (bare `can't start`, `failed to complete`) is read from the leading clause only,
# so a clause about a DIFFERENT component cannot demote a completed review — while
# an ANCHORED phrase (naming the review, or the reviewer's own budget) is read from
# the whole description, which is why 'Unable to proceed, review was not started'
# and 'Review unavailable, rate limit exceeded' above are still rejected.
# `Review was not skipped` pins that `not` is not an auxiliary — it is mandatory
# only where negation is meant.
prop_ok_fail=0
for desc in \
  'Review completed within quota' \
  'Capacity analysis completed' \
  'Review completed; generated files skipped' \
  'Review completed, no rate limit issues' \
  'Review completed - 0 findings, quota healthy' \
  'Review started and completed' \
  'Review completed; preview was skipped' \
  'Preview skipped' \
  'Preview limit reached' \
  "Review completed; preview can't start" \
  'Review completed; generated files failed to complete' \
  'Review completed - quota healthy' \
  'Review was not skipped' \
  'Review completed: generated files failed to complete' \
  'Review completed — preview failed to complete' \
  "Review completed – preview can't start" \
  'Review completed; docs yet to be written' \
  'Review completed: preview failed to start' \
  'Review was not completely clean' \
  'Review completed; preview rendering: failed to complete' \
  'Review completed. Preview rendering failed to complete' \
  'Review completed; unable to complete the reviewer profile update' \
  'Review completed; preview rendering - failed to complete' \
  'Review completed; reviewer profile update: failed to complete' \
  'Review completed; preview, however, failed to complete' \
  'Review completed; artifacts for review: failed to complete' \
  'Review failed to find any issues' \
  'Review completed; failed to complete the review summary' \
  'Review completed; skipping reviewer profile update' \
  'The reviewer started, failed to complete' \
  'The review summary started, failed to complete' \
  "The review's author started, failed to complete" \
  'No review was completed without findings' \
  'Review reply: failed to complete' \
  'Could not start this review-summary generator' \
  'Review failed-safe check passed' \
  'Review completed; corporate: limited scope' \
  'Review completed; corporate - limited scope' \
  'Review completed: preview rendering - failed to complete'
do
  status=$(mk_status success "$desc")
  result=$(run_ledger "$status" "$PRIOR_REVIEW")
  if [[ "$result" != "$HEAD_SHA" ]]; then
    fail "property(inverse): '$desc' produced '$result', expected HEAD-ack"
    prop_ok_fail=$((prop_ok_fail + 1))
  fi
done
if [[ "$prop_ok_fail" -eq 0 ]]; then
  ok "property(inverse): 39 keyword-bearing/trailing-clause verdicts still ack HEAD"
fi

# ---------------------------------------------------------------------------
# POSITIVE CASES — an ordinary success must still HEAD-ack. These pin that the
# guard did not become a blanket block on the status channel.
# ---------------------------------------------------------------------------

# The last three are the exact strings a review flagged as wrongly demoted by an
# earlier, looser regex (bare `quota`/`capacity`/`skipped` alternatives). They
# describe reviews that DID run and must keep acking.
for desc in 'Review completed' 'No issues found' '' '   ' \
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

# ---------------------------------------------------------------------------
# CONTRACT RESIDUALS — the classifier's declared limits, pinned in BOTH
# directions so a later round cannot quietly move one without the other.
#
# Each of these was implemented during review and then removed, because the fix
# opened a defect in the mirror direction: widening the qualifier run before
# `review` swallowed foreign subjects, narrowing it missed real ones, and treating
# a colon/dash/comma as a clause break stripped the subject that decides whose
# failure it is. A status description is free English and this regex has no fixed
# point; the contract in scripts/ack-ledger.sh states what it does cover.
# ---------------------------------------------------------------------------

# Under-block residual: outside the contract, so it ACKS. Not a silent gap — a
# newly OBSERVED payload in this shape is a new case with a new fixture.
for desc in \
  'The scheduled nightly review started, failed to complete' \
  'No review of this commit was completed' \
  'Could not complete the full automated code review'
do
  status=$(mk_status success "$desc")
  result=$(run_ledger "$status" "$PRIOR_REVIEW")
  if [[ "$result" == "$HEAD_SHA" ]]; then
    ok "contract residual (acks, documented): '$desc'"
  else
    fail "residual '$desc' produced '$result' — the contract says it acks; if this \
was widened deliberately, update the contract block AND the mirror case below"
  fi
done

# Over-block residual: inside the matcher but wrong-way, kept because every
# removal introduced a fail-OPEN. A visible stall beats a silent ack.
for desc in \
  'Review completed; not rate limited' \
  'Review completed; no review was skipped' \
  'Review passed; failed to complete after retry but later completed'
do
  status=$(mk_status success "$desc")
  result=$(run_ledger "$status" "$PRIOR_REVIEW")
  if [[ "$result" == "stale" ]]; then
    ok "contract residual (over-blocks, deliberate): '$desc'"
  else
    fail "residual '$desc' produced '$result' — expected the deliberate over-block"
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
