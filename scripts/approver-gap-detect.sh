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
#   7. Set SOLO_ADMIN_OPT_IN — "1" only when ALL of the following hold;
#      the caller (skills/pr-grind/SKILL.md) is responsible for performing
#      these checks before setting the flag. Set "0" if any condition fails.
#        (a) The opt-in file exists at
#            <MAIN_REPO_ROOT>/.claude/pr-grind-auto-admin-solo.local
#            (MAIN repo, NOT the worktree — resolve via
#             `dirname "$(git -C <WORKTREE_DIR> rev-parse --path-format=absolute --git-common-dir)"`
#             so worktree-mode pr-grind sees the operator's actual opt-in).
#        (b) A snapshot file exists at
#            <MAIN_REPO_ROOT>/.claude/.pr-grind-solo-opt-in-snapshot-<PR>.local
#            written by pr-grind Step 0 ONLY when the opt-in file was already
#            ≥30s old at INVOCATION_START_EPOCH (Step 0's captured-once
#            timestamp from the very first line of the block, NOT a fresh
#            `date +%s` at snapshot time — slow earlier ops in Step 0 could
#            otherwise push elapsed time past 30s and let a mid-invocation
#            touch satisfy the gate it's meant to defeat).
#        (c) The snapshot's recorded mtime (content) equals the opt-in
#            file's current mtime — a mid-run replacement invalidates.
#        (d) The snapshot file's own filesystem mtime is ≥30s AFTER the
#            opt-in file's mtime (`snapshot.fs_mtime - opt-in.mtime >= 30`).
#            Defeats the same-NOW forge where an attacker creates both
#            files in one action with identical mtimes (which would
#            otherwise pass condition (c) trivially). Step 0's legitimate
#            write produces diff >= 30 by definition (it only snapshots
#            opt-in files already >= 30s old). `touch -t` backdating by a
#            sophisticated attacker can still bypass this — documented as
#            defense-in-depth, not a security boundary; threat model
#            already assumes attacker has same-user write access, in
#            which case `gh pr merge --admin` is directly accessible.
#      This is the per-repo operator-consent mechanism (gitignored, same
#      .local pattern as skip-litmus.local) that lets pr-grind treat
#      --admin-on-approver-gap as implicit when the operator is
#      structurally the sole human with PR-approval capability. Off by
#      default.
#   8. Set HUMAN_ADMIN_COUNT — count of NON-BOT collaborators with
#      PR-APPROVAL capability (anyone with write/maintain/admin perm —
#      `permissions.push == true`). The caller MUST use the fail-CLOSED
#      tmpfile pattern below; piping `gh api --paginate` directly into
#      `jq -s 'add // []'` without pipefail can succeed over PARTIAL
#      pages when gh fails on a later page (rate limit, transient
#      network), yielding an incomplete collaborator list that misses a
#      write-capable human on an unfetched page:
#        COLLAB_TMP=$(mktemp -t pr-grind-collab.XXXXXXXX)
#        if gh api "repos/<owner>/<repo>/collaborators?affiliation=all" --paginate >"$COLLAB_TMP" 2>/dev/null; then
#          COLLABORATORS_JSON=$(jq -s 'add // []' "$COLLAB_TMP" 2>/dev/null || echo "[]")
#        else
#          COLLABORATORS_JSON="[]"
#        fi
#        rm -f "$COLLAB_TMP"
#        HUMAN_ADMIN_COUNT=$(printf '%s' "$COLLABORATORS_JSON" \
#          | jq '[.[] | select((.type // "User") == "User"
#                              and ((.login // "") | endswith("[bot]") | not)
#                              and ((.permissions.push // false) == true))] | length')
#      The variable name is kept for backward compatibility with the
#      script's input contract, but the SEMANTIC is "count of humans who
#      can submit an APPROVED PR review under default branch protection"
#      — not just admins. Filtering only `permission=admin` would let the
#      solo-admin trigger fire even when another human with maintain/write
#      could approve, contradicting the "no other human can approve"
#      property. Used together with AUTHOR_IS_SOLE_ADMIN as the structural
#      check; if the count ever drifts > 1 (contractor added), the opt-in
#      self-revokes. Default "0" (unknown).
#   9. Set AUTHOR_IS_SOLE_ADMIN — "1" when the caller verified the PR
#      author is the only human with PR-approval capability
#      (HUMAN_ADMIN_COUNT==1 AND that one human is the author). Default "0".
#  10. `export BRANCH_RULES_JSON PR_REVIEWS_JSON AUTHOR_PERM_JSON \
#       AUDIT_WORKFLOW_PRESENT CI_AND_BOTS_CLEAN ADMIN_FLAG_PASSED \
#       SOLO_ADMIN_OPT_IN HUMAN_ADMIN_COUNT AUTHOR_IS_SOLE_ADMIN`
#      so this subprocess inherits them.
#
# Output (always one JSON line, always exit 0 on success):
#   {
#     "decision": "no-gap" | "surface-decision" | "auto-admin-merge",
#     "trigger": "flag" | "solo-admin-auto" | "none",
#     "required_approving_review_count": <int>,
#     "human_approvals": <int>,
#     "author_perm": "admin" | "maintain" | "write" | "triage" | "read",
#     "audit_workflow_present": 0 | 1,
#     "admin_flag_passed": 0 | 1,
#     "solo_admin_opt_in": 0 | 1,
#     "human_admin_count": <int>,
#     "author_is_sole_admin": 0 | 1,
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
#                            ONLY emitted when ALL eligibility gates pass.
#                            Two triggers can reach this decision:
#                            (a) trigger=flag:
#                                  admin_flag_passed=1
#                                  CI_AND_BOTS_CLEAN=1
#                                  required_approving_review_count >= 1
#                                  human_approvals < required_approving_review_count
#                                  author_perm ∈ {admin, maintain}
#                                  audit_workflow_present=1
#                            (b) trigger=solo-admin-auto:
#                                  solo_admin_opt_in=1
#                                  author_is_sole_admin=1
#                                  human_admin_count=1
#                                  CI_AND_BOTS_CLEAN=1
#                                  required_approving_review_count >= 1
#                                  human_approvals < required_approving_review_count
#                                  author_perm ∈ {admin, maintain}
#                                  audit_workflow_present=1
#                            Caller switches the bypass-log "event" field on
#                            the trigger value:
#                              flag             → pr-grind-admin-on-approver-gap
#                              solo-admin-auto  → pr-grind-admin-on-approver-gap-solo-admin-auto
#
# Fail-CLOSED principle: any input missing or unparseable degrades the
# decision toward "surface-decision" (or "no-gap" when the rules are
# missing entirely — caller's existing gh pr merge will then surface the
# real error). The script NEVER emits "auto-admin-merge" without all
# eligibility inputs for the chosen trigger being present and consistent.

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
    local decision="$1" reason="$2" audit_eligible="$3" trigger="${4:-none}"
    jq -c -n \
        --arg decision "$decision" \
        --arg trigger "$trigger" \
        --arg reason "$reason" \
        --arg author_perm "$AUTHOR_PERM" \
        --argjson required "$REQUIRED_APPROVALS" \
        --argjson human_approvals "$HUMAN_APPROVALS" \
        --argjson audit_workflow_present "$AUDIT_PRESENT_INT" \
        --argjson admin_flag_passed "$ADMIN_FLAG_INT" \
        --argjson solo_admin_opt_in "$SOLO_OPT_IN_INT" \
        --argjson human_admin_count "$HUMAN_ADMIN_COUNT_INT" \
        --argjson author_is_sole_admin "$AUTHOR_IS_SOLE_INT" \
        --argjson audit_eligible "$audit_eligible" \
        '{
            decision: $decision,
            trigger: $trigger,
            required_approving_review_count: $required,
            human_approvals: $human_approvals,
            author_perm: $author_perm,
            audit_workflow_present: $audit_workflow_present,
            admin_flag_passed: $admin_flag_passed,
            solo_admin_opt_in: $solo_admin_opt_in,
            human_admin_count: $human_admin_count,
            author_is_sole_admin: $author_is_sole_admin,
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

SOLO_OPT_IN_INT=0
if [ "${SOLO_ADMIN_OPT_IN:-0}" = "1" ]; then SOLO_OPT_IN_INT=1; fi

# HUMAN_ADMIN_COUNT defaults to 0 (unknown). When the caller didn't compute
# it, the solo-admin branch can't fire — falls through to existing logic.
HUMAN_ADMIN_COUNT_INT="${HUMAN_ADMIN_COUNT:-0}"
case "$HUMAN_ADMIN_COUNT_INT" in ''|*[!0-9]*) HUMAN_ADMIN_COUNT_INT=0 ;; esac

AUTHOR_IS_SOLE_INT=0
if [ "${AUTHOR_IS_SOLE_ADMIN:-0}" = "1" ]; then AUTHOR_IS_SOLE_INT=1; fi

# ── Decision logic ───────────────────────────────────────────────────────

# No protection rule, or PR already has enough approvals → no gap, normal merge.
if [ "$REQUIRED_APPROVALS" -lt 1 ] || [ "$HUMAN_APPROVALS" -ge "$REQUIRED_APPROVALS" ]; then
    emit_decision "no-gap" "approver count satisfied or no rule" 0 "none"
fi

# Approver gap exists. Now decide whether the caller can auto-escalate.
# Two triggers can produce auto-admin-merge:
#   (a) explicit --admin-on-approver-gap flag (operator consent per-invocation)
#   (b) solo-admin opt-in file + structural sole-admin check (per-repo consent)
# Both require the same baseline gates:
#   - CI/bots are already verified clean (gap is sole blocker — caller asserts)
#   - Author has admin or maintain permission (others can't run --admin)
#   - Audit workflow exists (we never bypass without an audit trail)

AUDIT_ELIGIBLE=0
case "$AUTHOR_PERM" in
    admin|maintain) PERM_OK=1 ;;
    *) PERM_OK=0 ;;
esac

BASELINE_OK=0
if [ "$CI_AND_BOTS_CLEAN_INT" -eq 1 ] \
   && [ "$PERM_OK" -eq 1 ] \
   && [ "$AUDIT_PRESENT_INT" -eq 1 ]; then
    BASELINE_OK=1
fi

# Trigger (b): solo-admin auto-detect. Checked first so an operator who has
# BOTH the opt-in file AND passes --admin-on-approver-gap still gets the
# solo-admin attribution (more specific reason in the audit log).
if [ "$BASELINE_OK" -eq 1 ] \
   && [ "$SOLO_OPT_IN_INT" -eq 1 ] \
   && [ "$AUTHOR_IS_SOLE_INT" -eq 1 ] \
   && [ "$HUMAN_ADMIN_COUNT_INT" -eq 1 ]; then
    AUDIT_ELIGIBLE=1
    emit_decision "auto-admin-merge" "solo-admin opt-in + sole human admin confirmed" "$AUDIT_ELIGIBLE" "solo-admin-auto"
fi

# Trigger (a): explicit flag.
if [ "$BASELINE_OK" -eq 1 ] && [ "$ADMIN_FLAG_INT" -eq 1 ]; then
    AUDIT_ELIGIBLE=1
    emit_decision "auto-admin-merge" "all eligibility gates passed" "$AUDIT_ELIGIBLE" "flag"
fi

# Gap exists but auto-escalation is not eligible. Surface the decision
# message; --admin shows up as the first option ONLY when an audit
# workflow exists (caller renders the right template based on
# audit_workflow_present).
if [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$AUDIT_PRESENT_INT" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but no audit workflow — fail-CLOSED" 0 "none"
elif [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$PERM_OK" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but author lacks admin/maintain" 0 "none"
elif [ "$ADMIN_FLAG_INT" -eq 1 ] && [ "$CI_AND_BOTS_CLEAN_INT" -eq 0 ]; then
    emit_decision "surface-decision" "admin flag passed but caller did not assert CI/bots clean" 0 "none"
fi

# Solo-admin opt-in present but the structural check or baseline gates
# couldn't satisfy auto-escalation. Distinct reasons help the operator
# diagnose why auto-detect didn't fire — without these, the operator sees
# only the generic "approver gap; awaiting operator decision" message and
# has no signal that the opt-in file was seen at all.
if [ "$SOLO_OPT_IN_INT" -eq 1 ]; then
    if [ "$HUMAN_ADMIN_COUNT_INT" -eq 0 ]; then
        emit_decision "surface-decision" "solo-admin opt-in present but human admin count is 0 (gh API failed or returned empty) — refusing to auto-escalate" 0 "none"
    elif [ "$AUTHOR_IS_SOLE_INT" -eq 0 ] || [ "$HUMAN_ADMIN_COUNT_INT" -ne 1 ]; then
        emit_decision "surface-decision" "solo-admin opt-in present but structural check failed (count=$HUMAN_ADMIN_COUNT_INT, author_is_sole=$AUTHOR_IS_SOLE_INT) — opt-in self-revokes" 0 "none"
    elif [ "$BASELINE_OK" -eq 0 ]; then
        emit_decision "surface-decision" "solo-admin opt-in present and sole-admin confirmed, but baseline gates not satisfied (CI/bots clean, admin/maintain perm, bypass-audit.yml all required)" 0 "none"
    fi
fi

emit_decision "surface-decision" "approver gap; awaiting operator decision" 0 "none"
