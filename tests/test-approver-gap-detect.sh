#!/usr/bin/env bash
# Tests for scripts/approver-gap-detect.sh — Phase 3 of pr-grind work.
#
# Validates the four canonical scenarios from the implementation spec:
#   1. Solo-author, required=1, audit workflow present, CI green, bots ack
#      → "surface-decision" with [admin] available
#   2. Same as #1 but no audit workflow
#      → "surface-decision" without [admin] as default (audit_workflow_present=0)
#   3. Same as #1 with --admin-on-approver-gap flag
#      → "auto-admin-merge"
#   4. PR has the required human APPROVED review
#      → "no-gap" (normal merge path)
#
# Each test composes JSON fixtures inline (no live gh calls) and exports the
# script's input env vars, then checks the decision field on stdout.
#
# Usage: bash tests/test-approver-gap-detect.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT="scripts/approver-gap-detect.sh"
PASS=0
FAIL=0
TOTAL=0

# ── Fixtures ─────────────────────────────────────────────────────────────

# Branch rules JSON when protection requires 1 approving review.
RULES_REQUIRE_1='[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]'

# Branch rules JSON when no protection rule exists.
RULES_NONE='[]'

# Pull request reviews — empty (no human approval yet).
REVIEWS_EMPTY='[]'

# Pull request reviews — one human APPROVED review.
REVIEWS_HUMAN_APPROVED='[{"state":"APPROVED","submitted_at":"2026-01-01T10:00:00Z","user":{"login":"alice","type":"User"}}]'

# Pull request reviews — reviewer APPROVED then later requested changes (dismissed approval).
# The latest state is CHANGES_REQUESTED → should NOT count as an active approval.
REVIEWS_DISMISSED_APPROVAL='[{"state":"APPROVED","submitted_at":"2026-01-01T10:00:00Z","user":{"login":"alice","type":"User"}},{"state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T11:00:00Z","user":{"login":"alice","type":"User"}}]'

# Pull request reviews — bot APPROVED (should NOT count).
REVIEWS_BOT_APPROVED='[{"state":"APPROVED","user":{"login":"copilot-pull-request-reviewer[bot]","type":"Bot"}}]'

# Author permission — admin (eligible for --admin).
AUTHOR_ADMIN='{"permission":"admin"}'

# Author permission — maintain (also eligible).
AUTHOR_MAINTAIN='{"permission":"maintain"}'

# Author permission — write (NOT eligible for --admin escalation).
AUTHOR_WRITE='{"permission":"write"}'

# ── Helpers ──────────────────────────────────────────────────────────────

run_case() {
    local name="$1"
    local expected_decision="$2"
    local expected_audit_present="$3"
    local expected_audit_eligible="$4"
    # Inputs come from env exported by the caller before invoking us.
    TOTAL=$((TOTAL + 1))

    local out decision audit_present audit_eligible
    out=$(bash "$SCRIPT" 2>/dev/null) || {
        printf "  FAIL  %s (script exited non-zero)\n" "$name"
        FAIL=$((FAIL + 1))
        return
    }
    decision=$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null || echo "")
    audit_present=$(printf '%s' "$out" | jq -r '.audit_workflow_present' 2>/dev/null || echo "")
    audit_eligible=$(printf '%s' "$out" | jq -r '.audit_eligible' 2>/dev/null || echo "")

    if [ "$decision" = "$expected_decision" ] \
       && [ "$audit_present" = "$expected_audit_present" ] \
       && [ "$audit_eligible" = "$expected_audit_eligible" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        printf "        expected: decision=%s audit_present=%s audit_eligible=%s\n" \
            "$expected_decision" "$expected_audit_present" "$expected_audit_eligible"
        printf "        got:      decision=%s audit_present=%s audit_eligible=%s\n" \
            "$decision" "$audit_present" "$audit_eligible"
        printf "        full out: %s\n" "$out"
        FAIL=$((FAIL + 1))
    fi
}

# ── Scenarios ────────────────────────────────────────────────────────────

echo "── approver-gap-detect ─────────────────────────────────────"

# 1. Solo-author, required=1, audit workflow present, CI green, no flag
#    → surface-decision with [admin] available (audit_workflow_present=1)
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "1. solo-author + audit workflow + no flag → surface-decision ([admin] available)" \
    "surface-decision" "1" "0"

# 2. Same as #1 but no audit workflow → surface-decision, [admin] omitted
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="0"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "2. solo-author + NO audit workflow + no flag → surface-decision ([admin] NOT default)" \
    "surface-decision" "0" "0"

# 3. Same as #1 with --admin-on-approver-gap flag → auto-admin-merge
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="1"
run_case "3. solo-author + audit workflow + --admin-on-approver-gap → auto-admin-merge" \
    "auto-admin-merge" "1" "1"

# 4. PR has 1 human APPROVED review → no-gap
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_HUMAN_APPROVED"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "4. PR has human APPROVED review → no-gap" \
    "no-gap" "1" "0"

# ── Defensive cases ──────────────────────────────────────────────────────

echo ""
echo "── approver-gap-detect (defensive) ─────────────────────────"

# 5. No protection rule at all → no-gap regardless of approvals
export BRANCH_RULES_JSON="$RULES_NONE"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "5. no protection rule → no-gap" \
    "no-gap" "1" "0"

# 6. Bot APPROVED review does NOT count → still surface-decision
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_BOT_APPROVED"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "6. only bot APPROVED → does NOT satisfy → surface-decision" \
    "surface-decision" "1" "0"

# 7. --admin-on-approver-gap WITH no audit workflow → fail-CLOSED to surface
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="0"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="1"
run_case "7. --admin flag + NO audit workflow → fail-CLOSED to surface-decision" \
    "surface-decision" "0" "0"

# 8. --admin-on-approver-gap WITH author.permission=write → fail-CLOSED to surface
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_WRITE"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="1"
run_case "8. --admin flag + author=write (not admin/maintain) → fail-CLOSED to surface" \
    "surface-decision" "1" "0"

# 9. --admin-on-approver-gap WITH author.permission=maintain → auto-admin-merge
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_MAINTAIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="1"
run_case "9. --admin flag + author=maintain → auto-admin-merge (maintain is eligible)" \
    "auto-admin-merge" "1" "1"

# 10. --admin-on-approver-gap WITHOUT caller asserting CI/bots clean → surface
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_EMPTY"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="0"
export ADMIN_FLAG_PASSED="1"
run_case "10. --admin flag + CI/bots NOT asserted clean → surface-decision (gap is not sole blocker)" \
    "surface-decision" "1" "0"

# 11. Reviewer APPROVED then CHANGES_REQUESTED — dismissed approval must NOT count
export BRANCH_RULES_JSON="$RULES_REQUIRE_1"
export PR_REVIEWS_JSON="$REVIEWS_DISMISSED_APPROVAL"
export AUTHOR_PERM_JSON="$AUTHOR_ADMIN"
export AUDIT_WORKFLOW_PRESENT="1"
export CI_AND_BOTS_CLEAN="1"
export ADMIN_FLAG_PASSED="0"
run_case "11. reviewer APPROVED then CHANGES_REQUESTED → dismissed approval does NOT satisfy" \
    "surface-decision" "1" "0"

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
