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

# Shared fixtures for the Case 3 tests below. Defined once here so all six
# tests share a single source of truth — future shape changes (new fields,
# adjusted body text) only need updating in one place.
STALE_CUBIC_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"No issues found"}]'
ACTIONABLE_COMMENTED_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"Please fix the validation logic in line 47."}]'
CHANGES_REQUESTED_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"oldcommit","body":"Please fix the validation logic."}]'
SKIPPED_HEAD_CHECK_RUN='{"check_runs":[{"app":{"slug":"cubic-dev-ai"},"conclusion":"skipped","head_sha":"abc12345"}]}'
SKIPPED_STALE_CHECK_RUN='{"check_runs":[{"app":{"slug":"cubic-dev-ai"},"conclusion":"skipped","head_sha":"oldcommit"}]}'

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

# Helper for check-run-driven tests (Tier D / downgrade Case 3). Parametrizes
# ALL_CHECK_RUNS and optionally ALL_REVIEWS so tests can construct the
# canonical cubic shape: stale /reviews entry + skipped check-run on HEAD.
# The reviews parameter defaults to '[]' for back-compat with tests that only
# exercise the check-run path (e.g., Tier D priority where Tier D exits at
# line 93 before reaching line 98).
mk_check_runs_json() {
  # $1 = JSON array literal of check_runs entries
  # Example: '[{"app":{"slug":"cubic-dev-ai"},"conclusion":"skipped","head_sha":"abc12345"}]'
  printf '{"check_runs":%s}\n' "$1"
}

run_ledger_check_runs() {
  # $1 = login to query
  # $2 = ALL_CHECK_RUNS json (the wrapped {"check_runs":[...]} form)
  # $3 = ALL_REVIEWS json (optional; defaults to '[]')
  local reviews="${3:-[]}"
  FETCH_OK=1 \
  ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
  ALL_REVIEWS="$reviews" \
  ALL_COMMENTS='{"comments":[]}' \
  ALL_CHECK_RUNS="$2" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$1" 2>/dev/null
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
# Two distinct commit IDs model the cross-commit sequence the test name describes.
STALE_COMMIT_B="oldc0mm2"
CR_THEN_COMMENTED=$(printf '[{"user":{"login":"greptile-apps[bot]"},"state":"CHANGES_REQUESTED","commit_id":"%s","body":"Finding body only — no inline threads."},{"user":{"login":"greptile-apps[bot]"},"state":"COMMENTED","commit_id":"%s","body":"PR overview summary."}]' "$STALE_COMMIT" "$STALE_COMMIT_B")
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

# --- Test 12: skipped check-run on HEAD + stale COMMENTED review with non-actionable body → none (Case 3 positive case) ---
# Canonical cubic-dev-ai merge-commit scenario from PR #129: bot reviewed
# pre-merge commit with a "No issues found" COMMENTED body AND posted a
# check-run with conclusion=skipped on the merge commit. Without Case 3,
# the downgrade block falls through to `echo stale`. With Case 3 (and its
# non-actionable-body positive-signal guard), the skipped-on-HEAD check-run
# downgrades to `none` so invariant 2 doesn't deadlock.
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$STALE_CUBIC_REVIEW")
if [ "$got" = "none" ]; then
  ok "skipped on HEAD + stale 'No issues found' COMMENTED → none (Case 3 positive case)"
else
  fail "skipped on HEAD + stale 'No issues found' COMMENTED expected 'none', got '$got'"
fi

# --- Test 13: skipped check-run on STALE commit + stale 'No issues found' review → stale (head-sha guard) ---
# Pins the `${check_run_skipped:0:8} = $HEAD_SHA` guard inside Case 3.
# Without the guard, ANY skipped check-run from the bot would fire Case 3 and
# silently downgrade to `none`. With the guard, only HEAD-anchored skipped
# check-runs downgrade.
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_STALE_CHECK_RUN" "$STALE_CUBIC_REVIEW")
if [ "$got" = "stale" ]; then
  ok "skipped on stale commit + stale review → stale (head-sha guard pins Case 3 to HEAD)"
else
  fail "skipped on stale commit + stale review expected 'stale', got '$got'"
fi

# --- Test 14: success + skipped both on HEAD → HEAD_SHA (Tier D priority over Case 3) ---
# Tier D's success-check-run-on-HEAD short-circuits at line 93 before the
# downgrade block runs. Without this test, swapping the order of Tier D and
# the downgrade block (or moving Case 3 before Tier D) would silently downgrade
# a successful bot to `none`. No reviews fixture is needed because Tier D
# exits at line 93 before reaching line 98.
SUCCESS_AND_SKIPPED_HEAD=$(mk_check_runs_json "[{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"success\",\"head_sha\":\"${HEAD_SHA}\"},{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"skipped\",\"head_sha\":\"${HEAD_SHA}\"}]")
got=$(run_ledger_check_runs cubic-dev-ai "$SUCCESS_AND_SKIPPED_HEAD")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "success + skipped both on HEAD → HEAD_SHA (Tier D priority over Case 3)"
else
  fail "success + skipped both on HEAD expected '$HEAD_SHA', got '$got'"
fi

# --- Test 15: success-stale + skipped-HEAD + stale 'No issues found' review → none (robustness fixture) ---
# Robustness fixture inspired by busdriver PR #129 (2026-05-21). The live
# /commits/$HEAD_SHA/check-runs fetch may not return stale-anchored entries,
# so this is a "what if both arrive in the same payload" test rather than
# an exact production reproduction. Test 12 already covers the canonical
# minimal-fixture case; Test 15 adds pagination-resilience coverage.
SUCCESS_STALE_SKIPPED_HEAD=$(mk_check_runs_json "[{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"success\",\"head_sha\":\"oldcommit\"},{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"skipped\",\"head_sha\":\"${HEAD_SHA}\"}]")
got=$(run_ledger_check_runs cubic-dev-ai "$SUCCESS_STALE_SKIPPED_HEAD" "$STALE_CUBIC_REVIEW")
if [ "$got" = "none" ]; then
  ok "success-stale + skipped-HEAD + stale review → none (robustness fixture inspired by PR #129)"
else
  fail "success-stale + skipped-HEAD + stale review expected 'none', got '$got'"
fi

# --- Test 16: [CHANGES_REQUESTED on prior + skipped on HEAD] → stale (ever_approved guard preserved) ---
# Codex's blueprint-review iteration 1 finding: Case 3 must NOT downgrade a
# bot with a prior CHANGES_REQUESTED review even if it later posts a skipped
# check-run on HEAD. The ever_approved==0 outer guard at scripts/ack-ledger.sh:124
# enforces this — CHANGES_REQUESTED counts toward ever_approved (see lines
# 105-112). Without the guard (e.g., if Case 3 was placed at line 94 instead
# of inside the downgrade block), this test would fail with `got 'none'`,
# silently discarding the bot's prior actionable finding.
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$CHANGES_REQUESTED_REVIEW")
if [ "$got" = "stale" ]; then
  ok "[CHANGES_REQUESTED + skipped-HEAD] → stale (ever_approved==0 guard preserved)"
else
  fail "[CHANGES_REQUESTED + skipped-HEAD] expected 'stale', got '$got'"
fi

# --- Test 17: actionable COMMENTED body + skipped-HEAD → stale (positive-signal guard) ---
# Codex's blueprint-review iteration 2 finding: Case 3 must NOT downgrade a
# bot whose last review body contains actionable content even if ever_approved
# is 0. Mirrors Case 2's PR-overview positive-signal guard. The fixture body
# "Please fix the validation logic in line 47." does NOT match the
# non-actionable regex (no issues found / no concerns / all good / looks good
# / lgtm / nothing to add|report), so Case 3 does NOT fire and the script
# falls through to `echo stale`.
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$ACTIONABLE_COMMENTED_REVIEW")
if [ "$got" = "stale" ]; then
  ok "actionable COMMENTED body + skipped-HEAD → stale (positive-signal guard prevents bypass)"
else
  fail "actionable COMMENTED body + skipped-HEAD expected 'stale', got '$got'"
fi

# --- Test 18: body_sha-only bot (no /reviews) + skipped-HEAD → stale (last_state==COMMENTED guard) ---
# Codex's blueprint-review iteration 4 finding: a hypothetical bot with NO
# /reviews entry but a stale body_sha (issue-comment body referencing an
# older commit SHA) + a skipped check-run on HEAD would reach the downgrade
# block with empty last_body. Without the `last_state == "COMMENTED"` guard,
# Case 3 would fire on the empty body and silently downgrade actionable
# issue-comment findings to `none`. With the guard, last_state is empty
# (no /reviews) → Case 3 doesn't fire → falls through to `echo stale`.
# Fixture note: body_sha must be a valid hex SHA (parser regex is commit/[a-f0-9]{7,40})
# and != HEAD_SHA 'abc12345' so it reaches the downgrade block (not the line-98 short-circuit).
BODY_SHA_ONLY_COMMENTS='{"comments":[{"author":{"login":"hypothetical-bot[bot]"},"body":"Reviewed at commit/deadbeef — found actionable issues."}]}'
SKIPPED_HEAD_OTHER_BOT='{"check_runs":[{"app":{"slug":"hypothetical-bot"},"conclusion":"skipped","head_sha":"abc12345"}]}'
got=$(FETCH_OK=1 \
  ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
  ALL_REVIEWS='[]' \
  ALL_COMMENTS="$BODY_SHA_ONLY_COMMENTS" \
  ALL_CHECK_RUNS="$SKIPPED_HEAD_OTHER_BOT" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" hypothetical-bot 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "body_sha-only bot (no /reviews) + skipped-HEAD → stale (last_state==COMMENTED guard prevents bypass)"
else
  fail "body_sha-only bot + skipped-HEAD expected 'stale', got '$got'"
fi

# --- Test 19: skipped-HEAD followed by skipped-stale in same payload → none (jq HEAD-filter resilience) ---
# Codex's blueprint-review iteration 4 finding: a `last | .head_sha` jq
# pattern would pick the LAST entry from the filtered array; if pagination
# orders the skipped-stale entry after the skipped-HEAD entry, `last` picks
# the stale one and the head_sha != HEAD check fails (Case 3 falls through
# to stale, wrong outcome). The fix filters HEAD inside the jq predicate,
# making the query pagination-order resilient. This test exercises that
# fix by putting skipped-HEAD first and skipped-stale second.
ORDERED_SKIPPED_HEAD_THEN_STALE=$(mk_check_runs_json "[{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"skipped\",\"head_sha\":\"${HEAD_SHA}\"},{\"app\":{\"slug\":\"cubic-dev-ai\"},\"conclusion\":\"skipped\",\"head_sha\":\"oldcommit\"}]")
got=$(run_ledger_check_runs cubic-dev-ai "$ORDERED_SKIPPED_HEAD_THEN_STALE" "$STALE_CUBIC_REVIEW")
if [ "$got" = "none" ]; then
  ok "skipped-HEAD before skipped-stale → none (jq HEAD-filter is pagination-order resilient)"
else
  fail "skipped-HEAD before skipped-stale expected 'none', got '$got'"
fi

# --- Test 20: stale COMMENTED no-findings /reviews + actionable body_sha comment + skipped-HEAD → stale (body_sha empty guard) ---
# Codex's blueprint-review iteration 6 finding: a bot with BOTH a stale
# non-actionable COMMENTED /reviews entry AND a stale issue-comment whose
# body contains a hex SHA (body_sha non-empty) and actionable text plus a
# skipped check-run on HEAD reaches the downgrade block with all three
# pre-body_sha predicates passing (skipped-HEAD ✓, last_state=COMMENTED ✓,
# last_body non-actionable ✓). Without the `[ -z "$body_sha" ]` guard,
# Case 3 fires and silently discards actionable issue-comment content.
# With the guard, body_sha is non-empty → Case 3 doesn't fire → falls
# through to `echo stale`.
ACTIONABLE_BODY_SHA_COMMENTS='{"comments":[{"author":{"login":"cubic-dev-ai[bot]"},"body":"Reviewed at commit/deadbeef — found a bug at line 47."}]}'
got=$(FETCH_OK=1 \
  ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' \
  ALL_REVIEWS="$STALE_CUBIC_REVIEW" \
  ALL_COMMENTS="$ACTIONABLE_BODY_SHA_COMMENTS" \
  ALL_CHECK_RUNS="$SKIPPED_HEAD_CHECK_RUN" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "stale COMMENTED no-findings + body_sha comment + skipped-HEAD → stale (body_sha empty guard prevents bypass)"
else
  fail "stale COMMENTED no-findings + body_sha comment + skipped-HEAD expected 'stale', got '$got'"
fi

# --- Test 21: cubic's actual default markdown body (issue #138) → none (substring match) ---
# Reproducer captured from PR #137 (2026-05-22). Cubic's real "No issues found"
# review body is markdown-wrapped with a re-trigger link footer and HTML
# attribution comments — not the bare "No issues found" string that Test 12
# uses. The Case 3 body regex was originally anchored (^...$) and missed this
# shape, leaving cubic stale on every [update-merge] PR.
# Newlines in `body` are normalized to spaces by the jq `gsub("\n"; " ")` on
# ack-ledger.sh:123 before the regex runs, so the fixture inlines the
# multi-block body the same way.
CUBIC_MARKDOWN_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"**No issues found** across 1 file\n\n<sub>[Re-trigger cubic](https://www.cubic.dev/action/re-review/pr/x/y/137)</sub>\n\n<!-- cubic:review-post:abc123 -->\n\n<!-- cubic:attribution IMPORTANT: -->"}]'
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$CUBIC_MARKDOWN_REVIEW")
if [ "$got" = "none" ]; then
  ok "cubic markdown body (**No issues found** + footer + comments) → none (issue #138)"
else
  fail "cubic markdown body expected 'none', got '$got'"
fi

# --- Test 22: actionable body containing 'lgtm' substring → none (accepted false-negative pin) ---
# Pins the documented false-negative trade-off from scripts/ack-ledger.sh:200-207.
# Substring match means a body like "lgtm but ... critical race at line 50" matches
# the non-actionable phrase set even though the body is actionable. We accept this
# because guards (a)/(b)/(c) (ever_approved==0, COMMENTED, body_sha empty) AND the
# skipped-HEAD check-run requirement make accidental matches rare in practice, and
# Tier A's unresolved-thread check catches the inline-comment variant. Pinning this
# behavior in a test forces any future regex-tightening or guard-weakening change
# to engage with the trade-off explicitly rather than silently shifting it.
LGTM_BUT_ACTIONABLE_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"lgtm but there is a critical race condition at line 50 that needs a fix before merge"}]'
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$LGTM_BUT_ACTIONABLE_REVIEW")
if [ "$got" = "none" ]; then
  ok "actionable body containing 'lgtm' substring → none (accepted false-negative, contract pin)"
else
  fail "actionable body containing 'lgtm' substring expected 'none' (accepted false-negative), got '$got'"
fi

# --- Test 23: mid-word partial match prevented by \b boundary on (add|report) ---
# Copilot flagged on PR #139 that the unanchored regex `nothing to (add|report)`
# can match inside `nothing to address` because `add` is a prefix of `address`.
# The fix appends `\b` after the capture group so `add` and `report` must be
# followed by a non-word character (whitespace, punctuation, end of string).
# This test pins the new behavior: a body containing "nothing to address but..."
# does NOT trigger Case 3 downgrade — the actionable finding stays `stale`.
NOTHING_TO_ADDRESS_REVIEW='[{"user":{"login":"cubic-dev-ai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"this PR has nothing to address yet for that file but please fix line 47 first"}]'
got=$(run_ledger_check_runs cubic-dev-ai "$SKIPPED_HEAD_CHECK_RUN" "$NOTHING_TO_ADDRESS_REVIEW")
if [ "$got" = "stale" ]; then
  ok "body containing 'nothing to address' (mid-word 'add') → stale (\\b boundary prevents partial match)"
else
  fail "body containing 'nothing to address' expected 'stale' (\\b boundary), got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
