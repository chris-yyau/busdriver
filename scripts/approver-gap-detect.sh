#!/usr/bin/env bash
# scripts/approver-gap-detect.sh — detect required-approver gap before merge.
#
# Single source of truth for the approver-gap detection algorithm consumed
# by skills/pr-grind/SKILL.md's Completion path (post-clean, pre-merge). The
# Completion path composes the four input JSON blobs / status flags below
# and invokes this script; the script emits a structured JSON decision on
# stdout for the dispatcher to switch on.
#
# Why a script (vs inline in SKILL.md):
#   - Testable in isolation by mocking the inputs (no live gh calls).
#   - Single-source maintenance: SKILL.md / agents/pr-grinder.md / future
#     callers all read from one file.
#   - Mirrors the scripts/ack-ledger.sh shape (caller fetches blobs, script
#     classifies).
#
# Caller responsibilities (BEFORE invoking):
#   1. Set BRANCH_RULES_JSON — output of
#        gh api "repos/<owner>/<repo>/rules/branches/<branch>"
#      (empty string OK when the endpoint failed or returned nothing).
#   2. Set PR_REVIEWS_JSON — output of
#        gh api "repos/<owner>/<repo>/pulls/<pr>/reviews"
#      Used to count human APPROVED reviews. Empty OK; the script treats
#      missing data as zero approvals (gap exists if rules say so).
#   3. Set AUTHOR_PERM_JSON — output of
#        gh api "repos/<owner>/<repo>/collaborators/<author>/permission"
#      (empty OK; missing => "read"). Used to label whether [admin] is a
#      legal option for this author at all.
#   4. Set AUDIT_WORKFLOW_PRESENT — "1" when
#        gh api "repos/<owner>/<repo>/contents/.github/workflows/bypass-audit.yml"
#      returns 0, else "0". Used to decide whether --admin-on-approver-gap
#      is allowed to auto-escalate.
#   5. Set CI_AND_BOTS_CLEAN — "1" when the caller has already verified
#      CI green AND every registered bot has acked HEAD AND no actionable
#      threads remain. "0" means the gap is NOT the sole blocker; the
#      caller should NOT treat the script's decision as a policy bail.
#   6. Set ADMIN_FLAG_PASSED — "1" when --admin-on-approver-gap was passed
#      to pr-grind, else "0".
#   7. `export BRANCH_RULES_JSON PR_REVIEWS_JSON AUTHOR_PERM_JSON \
#       AUDIT_WORKFLOW_PRESENT CI_AND_BOTS_CLEAN ADMIN_FLAG_PASSED`
#      so this subprocess inherits them.
#
# Output (always one JSON line, always exit 0 on success):
#   {
#     "decision": "no-gap" | "surface-decision" | "auto-admin-merge",
#     "required_approving_review_count": <int>,
#     "human_approvals": <int>,
#     "author_perm": "admin" | "maintain" | "write" | "triage" | "read",
#     "audit_workflow_present": 0 | 1,
#     "admin_flag_passed": 0 | 1,
#     "audit_eligible": 0 | 1,
#     "reason": "<short human-readable reason>"
#   }
#
# Decision semantics:
#   - "no-gap"             → caller proceeds to the normal gh pr merge path.
#   - "surface-decision"   → caller BAILs with RESULT_BAIL_CATEGORY=policy and
#                            renders the operator-decision message (template in
#                            SKILL.md Completion → "Operator-decision message").
#                            The audit_workflow_present field controls whether
#                            [admin] appears as the first/default option.
#   - "auto-admin-merge"   → caller logs to .claude/bypass-log.jsonl and runs
#                            `gh pr merge <PR> --squash --delete-branch --admin`.
#                            ONLY emitted when ALL eligibility gates pass:
#                              admin_flag_passed=1
#                              CI_AND_BOTS_CLEAN=1
#                              required_approving_review_count >= 1
#                              human_approvals < required_approving_review_count
#                              author_perm ∈ {admin, maintain}
#                              audit_workflow_present=1
#
# Fail-CLOSED principle: any input missing or unparseable degrades the
# decision toward "surface-decision" (or "no-gap" when the rules are
# missing entirely — caller's existing gh pr merge will then surface the
# real error). The script NEVER emits "auto-admin-merge" without all six
# inputs being present and consistent.

set -u

# ── Helpers ──────────────────────────────────────────────────────────────

# Safe jq invocation: returns the fallback when jq fails or input is empty.
safe_jq() {
    local fallback="$1" input="$2" filter="$3"
    if [ -z "$input" ]; then printf '%s' "$fallback"; return; fi
    local out
    out=$(printf '%s' "$input" | jq -r "$filter" 2>/dev/null) || out=""
    if [ -z "$out" ] || [ "$out" = "null" ]; then printf '%s' "$fallback"; else printf '%s' "$out"; fi
}

# Emit the JSON decision and exit 0.
emit_decision() {
    local decision="$1" reason="$2" audit_eligible="$3"
    jq -c -n \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --arg author_perm "$AUTHOR_PERM" \
        --argjson required "$REQUIRED_APPROVALS" \
        --argjson human_approvals "$HUMAN_APPROVALS" \
        --argjson audit_workflow_present "$AUDIT_PRESENT_INT" \
        --argjson admin_flag_passed "$ADMIN_FLAG_INT" \
        --argjson audit_eligible "$audit_eligible" \
        '{
            decision: $decision,
            required_approving_review_count: $required,
            human_approvals: $human_approvals,
            author_perm: $author_perm,
            audit_workflow_present: $audit_workflow_present,
            admin_flag_passed: $admin_flag_passed,
            audit_eligible: $audit_eligible,
            reason: $reason
        }'
    exit 0
}

# ── Parse inputs ─────────────────────────────────────────────────────────

REQUIRED_APPROVALS=$(safe_jq 0 "${BRANCH_RULES_JSON:-}" \
    '[.[] | select(.type=="pull_request") | .parameters.required_approving_review_count] | max // 0')
case "$REQUIRED_APPROVALS" in ''|*[!0-9]*) REQUIRED_APPROVALS=0 ;; esac

HUMAN_APPROVALS=$(safe_jq 0 "${PR_REVIEWS_JSON:-}" \
    '[.[]
      | select((.user.type // "User") == "User")
      | select((.user.login // "") | endswith("[bot]") | not)
      | {login: (.user.login // ""), submitted_at: (.submitted_at // ""), state: (.state // "")}]
     | sort_by(.login, .submitted_at)
     | group_by(.login)
     | map(last)
     | map(select(.state == "APPROVED"))
     | length')
case "$HUMAN_APPROVALS" in ''|*[!0-9]*) HUMAN_APPROVALS=0 ;; esac

AUTHOR_PERM=$(safe_jq "read" "${AUTHOR_PERM_JSON:-}" '.permission // "read"')

AUDIT_PRESENT_INT=0
if [ "${AUDIT_WORKFLOW_PRESENT:-0}" = "1" ]; then AUDIT_PRESENT_INT=1; fi

ADMIN_FLAG_INT=0
if [ "${ADMIN_FLAG_PASSED:-0}" = "1" ]; then ADMIN_FLAG_INT=1; fi

CI_AND_BOTS_CLEAN_INT=0
if [ "${CI_AND_BOTS_CLEAN:-0}" = "1" ]; then CI_AND_BOTS_CLEAN_INT=1; fi

# ── Decision logic ───────────────────────────────────────────────────────

# No protection rule, or PR already has enough approvals → no gap, normal merge.
if [ "$REQUIRED_APPROVALS" -lt 1 ] || [ "$HUMAN_APPROVALS" -ge "$REQUIRED_APPROVALS" ]; then
    emit_decision "no-gap" "approver count satisfied or no rule" 0
fi

# Approver gap exists. Now decide whether the caller can auto-escalate.
# Required for auto-admin-merge:
#   - --admin-on-approver-gap was passed (operator opted in)
#   - CI/bots are already verified clean (gap is sole blocker — caller asserts)
#   - Author has admin or maintain permission (others can't run --admin)
#   - Audit workflow exists (we never bypass without an audit trail)

AUDIT_ELIGIBLE=0
case "$AUTHOR_PERM" in
    admin|maintain) PERM_OK=1 ;;
    *) PERM_OK=0 ;;
esac

if [ "$ADMIN_FLAG_INT" -eq 1 ] \
   && [ "$CI_AND_BOTS_CLEAN_INT" -eq 1 ] \
   && [ "$PERM_OK" -eq 1 ] \
   && [ "$AUDIT_PRESENT_INT" -eq 1 ]; then
    AUDIT_ELIGIBLE=1
    emit_decision "auto-admin-merge" "all eligibility gates passed" "$AUDIT_ELIGIBLE"
fi

# Gap exists but auto-escalation is not eligible. Surface the decision
# message; --admin shows up as the first option ONLY when an audit
# workflow exists (caller renders the right template based on
# audit_workflow_present).
if [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$AUDIT_PRESENT_INT" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but no audit workflow — fail-CLOSED" 0
elif [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$PERM_OK" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but author lacks admin/maintain" 0
elif [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$CI_AND_BOTS_CLEAN_INT" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but caller did not assert CI/bots clean" 0
fi

emit_decision "surface-decision" "approver gap; awaiting operator decision" 0
