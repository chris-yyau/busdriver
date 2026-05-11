#!/usr/bin/env bash
# scripts/copilot-auto-resolve-eligibility.sh — three-precondition gate for
# Copilot stale-thread auto-resolve on force-push (Phase 2 of pr-grind work).
#
# Single source of truth for the eligibility logic consumed by the
# pr-grinder worker's Step 6.5a. The worker composes the inputs from
# Source 2 of Step 2's GraphQL projection + git state + RESULT_* tags and
# invokes this script; the script emits a JSON decision the worker switches
# on to decide whether to post addressed-in-<SHA> replies and resolve threads.
#
# Why a script (vs inline in agents/pr-grinder.md):
#   - Testable in isolation by mocking the inputs (no live gh/git calls).
#   - Single-source maintenance: worker / future tooling / tests all read
#     from one file.
#
# Caller responsibilities (BEFORE invoking):
#   1. Set RESULT_FIXES — the worker's RESULT_FIXES tag value (string;
#      empty/"none" means no fix this round).
#   2. Set RESULT_COMMIT_SHA — the worker's RESULT_COMMIT_SHA tag value
#      ("none" or a real SHA).
#   3. Set FORCE_PUSH_DETECTED — "1" when the caller has confirmed via
#      `git merge-base --is-ancestor <copilot_commit_id> HEAD` returning
#      non-zero (force-push rewrote the SHA Copilot reviewed). "0" means
#      Copilot's last-reviewed SHA is still an ancestor of HEAD (linear
#      push; do NOT auto-resolve, Copilot will catch up).
#   4. Set COPILOT_THREADS_JSON — a JSON array of objects, each shaped
#      {threadId, path, line}, drawn from Step 2's Source 2 stream
#      filtered to unresolved+non-outdated Copilot threads. Empty array
#      means there's nothing to resolve.
#   5. Set HEAD_TOUCHED_LINES_JSON — a JSON array of objects, each shaped
#      {path, start, end}, representing line ranges HEAD touched (parsed
#      from `git diff <merge-base>..HEAD -U0`). The caller composes this
#      from the worker's own diff inspection.
#   6. `export RESULT_FIXES RESULT_COMMIT_SHA FORCE_PUSH_DETECTED \
#       COPILOT_THREADS_JSON HEAD_TOUCHED_LINES_JSON` so this subprocess
#      inherits them.
#
# Output (always one JSON line, always exit 0 on success):
#   {
#     "decision": "resolve" | "skip",
#     "reason": "<short human-readable reason>",
#     "thread_count": <int>,
#     "force_push_detected": 0 | 1,
#     "all_anchored": 0 | 1,
#     "fixes_this_round": 0 | 1
#   }
#
# Decision semantics:
#   - "resolve" → caller iterates COPILOT_THREADS_JSON and posts an
#                 addressed-in-<HEAD> reply + resolveReviewThread mutation
#                 per thread. ack-ledger tier A picks up the resolved
#                 threads on the next Step 6.5 run.
#   - "skip"    → preconditions failed; caller leaves threads alone and
#                 lets the normal `stale` flow continue.
#
# The script ONLY emits "resolve" when ALL THREE preconditions hold:
#   1. RESULT_FIXES is non-empty/non-"none" AND RESULT_COMMIT_SHA is not
#      "none" (the worker actually fixed something this round).
#   2. FORCE_PUSH_DETECTED=1 (Copilot won't auto-re-review on force-push).
#   3. Every thread in COPILOT_THREADS_JSON is anchored to a line in
#      HEAD_TOUCHED_LINES_JSON (no stale-on-unrelated-code resolves).
#
# Fail-CLOSED on any precondition failure. Empty thread list also produces
# "skip" — there's nothing to resolve.

set -u

# ── Helpers ──────────────────────────────────────────────────────────────

emit() {
    local decision="$1" reason="$2"
    local thread_count="${3:-0}" all_anchored="${4:-0}" fixes_this_round="${5:-0}"
    local force_push="${FORCE_PUSH_DETECTED:-0}"
    case "$force_push" in 0|1) ;; *) force_push=0 ;; esac
    jq -c -n \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --argjson thread_count "$thread_count" \
        --argjson force_push_detected "$force_push" \
        --argjson all_anchored "$all_anchored" \
        --argjson fixes_this_round "$fixes_this_round" \
        '{
            decision: $decision,
            reason: $reason,
            thread_count: $thread_count,
            force_push_detected: $force_push_detected,
            all_anchored: $all_anchored,
            fixes_this_round: $fixes_this_round
        }'
    exit 0
}

# ── Precondition 3 (cheap, check first): fixes happened this round ──────

FIXES_OK=0
if [ -n "${RESULT_FIXES:-}" ] \
   && [ "${RESULT_FIXES:-none}" != "none" ] \
   && [ "${RESULT_COMMIT_SHA:-none}" != "none" ]; then
    FIXES_OK=1
fi
if [ "$FIXES_OK" -eq 0 ]; then
    emit "skip" "no fix pushed this round; nothing to claim 'addressed in <SHA>'" 0 0 0
fi

# ── Precondition 1: force-push detected since Copilot's last review ─────

if [ "${FORCE_PUSH_DETECTED:-0}" != "1" ]; then
    emit "skip" "no force-push detected; Copilot will auto-re-review on linear push" 0 0 1
fi

# ── Precondition 2: every Copilot thread anchored to HEAD-touched lines ─

THREAD_COUNT=$(printf '%s' "${COPILOT_THREADS_JSON:-[]}" | jq -r 'length' 2>/dev/null || echo 0)
case "$THREAD_COUNT" in ''|*[!0-9]*) THREAD_COUNT=0 ;; esac

if [ "$THREAD_COUNT" -eq 0 ]; then
    emit "skip" "no unresolved Copilot threads to resolve" 0 0 1
fi

# Walk every thread; verify <path>:<line> falls inside one of HEAD's hunks.
# fail-CLOSED: if ANY thread fails the anchor check, skip the entire batch.
ALL_ANCHORED=1
for i in $(seq 0 $((THREAD_COUNT - 1))); do
    t_path=$(printf '%s' "$COPILOT_THREADS_JSON" | jq -r ".[$i].path" 2>/dev/null)
    t_line=$(printf '%s' "$COPILOT_THREADS_JSON" | jq -r ".[$i].line // 0" 2>/dev/null)
    case "$t_line" in ''|*[!0-9]*) t_line=0 ;; esac

    # Does any HEAD_TOUCHED_LINES_JSON entry match path + line ∈ [start,end]?
    match=$(printf '%s' "${HEAD_TOUCHED_LINES_JSON:-[]}" | jq -r \
        --arg p "$t_path" \
        --argjson l "$t_line" \
        '[.[] | select(.path == $p) | select(.start <= $l and $l <= .end)] | length' \
        2>/dev/null || echo 0)
    case "$match" in ''|*[!0-9]*) match=0 ;; esac
    if [ "$match" -lt 1 ]; then
        ALL_ANCHORED=0
        break
    fi
done

if [ "$ALL_ANCHORED" -eq 0 ]; then
    emit "skip" "at least one Copilot thread anchored to a line HEAD did not touch" \
        "$THREAD_COUNT" 0 1
fi

emit "resolve" "all three preconditions hold" "$THREAD_COUNT" 1 1
