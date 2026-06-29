#!/usr/bin/env bash
# Tests for ADR 0003 Decision 7: arbiter-verdict freshness re-keying.
#
# The pre-v3.3 loop preserved and accepted claude.json keyed only on design
# spec_hash while reviewer artifacts re-rolled every run — so a stale arbiter
# verdict (rendered against reviews that no longer exist) could converge a
# re-run. Decision 7 requires a current-run run_id AND a matching spec_hash,
# fail-closed (missing metadata is stale, not a pass).
#
# Behavioral tests exercise validate_claude_verdict_freshness() from
# lib/validation.sh; static tests verify the loop script no longer contains
# the spec_hash-only preserve/accept paths.
#
# Usage: bash tests/test-claude-verdict-freshness.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

REVIEW_SCRIPT="skills/blueprint-review/scripts/run-design-review-loop.sh"
VALIDATION_LIB="skills/blueprint-review/scripts/lib/validation.sh"

# shellcheck source=/dev/null
source "$VALIDATION_LIB"

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

make_verdict() {
  # $1 = path, $2 = run_id ("" to omit), $3 = spec_hash ("" to omit)
  local path="$1" run_id="$2" spec_hash="$3"
  jq -n --arg rid "$run_id" --arg sh "$spec_hash" '{
    status: "PASS",
    reviewer_id: "claude",
    issues: [],
    metadata: (
      {}
      + (if $rid != "" then {run_id: $rid} else {} end)
      + (if $sh != "" then {spec_hash: $sh} else {} end)
    )
  }' > "$path"
}

check() {
  # $1 = description, $2 = expected (fresh|stale), $3 = verdict path,
  # $4 = expected run_id, $5 = expected spec_hash
  local desc="$1" expected="$2" path="$3" rid="$4" sh="$5"
  TOTAL=$((TOTAL + 1))
  local got
  if validate_claude_verdict_freshness "$path" "$rid" "$sh" 2>/dev/null; then
    got="fresh"
  else
    got="stale"
  fi
  if [[ "$got" == "$expected" ]]; then
    printf "  PASS  %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s (expected %s, got %s)\n" "$desc" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
}

echo "── validate_claude_verdict_freshness (behavioral) ───────────"

V="$TMPDIR_T/claude.json"

make_verdict "$V" "run-A" "hash-1"
check "current run_id + matching spec_hash is fresh" fresh "$V" "run-A" "hash-1"

make_verdict "$V" "run-OLD" "hash-1"
check "different run_id is stale even when spec_hash matches (the pre-v3.3 hole)" stale "$V" "run-A" "hash-1"

make_verdict "$V" "" "hash-1"
check "missing run_id is stale (old -n guard let it pass)" stale "$V" "run-A" "hash-1"

make_verdict "$V" "run-A" "hash-OLD"
check "matching run_id but mismatched spec_hash is stale (design changed mid-run)" stale "$V" "run-A" "hash-1"

make_verdict "$V" "run-A" ""
check "missing spec_hash is stale (freshness contract requires it)" stale "$V" "run-A" "hash-1"

VBAD="$TMPDIR_T/claude-bad.json"
echo '{ not json' > "$VBAD"
check "unparseable verdict is stale (fail-closed)" stale "$VBAD" "run-A" "hash-1"

echo ""
echo "── loop script structure (static) ───────────────────────────"

# Static 1: spec_hash-only preservation removed from iteration cleanup
TOTAL=$((TOTAL + 1))
if ! grep -q "PRESERVE_CLAUDE" "$REVIEW_SCRIPT"; then
  printf "  PASS  PRESERVE_CLAUDE spec_hash-only preservation removed\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  PRESERVE_CLAUDE still present in loop script\n"
  FAIL=$((FAIL + 1))
fi

# Static 2: cross-run spec_hash-only acceptance branch removed
TOTAL=$((TOTAL + 1))
if ! grep -q "different run but spec_hash matches" "$REVIEW_SCRIPT"; then
  printf "  PASS  cross-run spec_hash-only acceptance branch removed\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  cross-run spec_hash acceptance still present\n"
  FAIL=$((FAIL + 1))
fi

# Static 3: loop calls the shared freshness validator
TOTAL=$((TOTAL + 1))
if grep -q "validate_claude_verdict_freshness" "$REVIEW_SCRIPT"; then
  printf "  PASS  loop uses validate_claude_verdict_freshness\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  loop does not call validate_claude_verdict_freshness\n"
  FAIL=$((FAIL + 1))
fi

# Static 4: claude.json is cleaned unconditionally with the other artifacts
TOTAL=$((TOTAL + 1))
CLEANUP_BLOCK=$(sed -n '/Cleaning stale artifacts/,/Stale artifacts cleared/p' "$REVIEW_SCRIPT")
# here-string, not `echo | grep -q`: under `set -o pipefail`, grep -q closes the
# pipe on first match and the upstream echo takes SIGPIPE (141), flipping the
# pipeline non-zero even on a match — an intermittent false FAIL. No pipe, no race.
if grep -q 'get_review_file "claude.json"' <<<"$CLEANUP_BLOCK"; then
  printf "  PASS  claude.json cleaned unconditionally in iteration cleanup\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  claude.json not in unconditional cleanup list\n"
  FAIL=$((FAIL + 1))
fi

# Static 5: stale verdict still routes to the fail-closed state
TOTAL=$((TOTAL + 1))
if grep -q 'mark_review_complete "stale_claude_output"' "$REVIEW_SCRIPT"; then
  printf "  PASS  stale verdict marks stale_claude_output (fail-closed)\n"
  PASS=$((PASS + 1))
else
  printf "  FAIL  stale_claude_output state marker missing\n"
  FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
  echo "   $FAIL FAILED"
  exit 1
fi
echo "   All passed."
exit 0
