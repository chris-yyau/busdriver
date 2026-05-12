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

# ── Precondition 3 (checked first — cheapest guard): fixes happened this round ──

FIXES_OK=0
if [ -n "${RESULT_FIXES:-}" ] \
   && [ "${RESULT_FIXES:-none}" != "none" ] \
   && [ "${RESULT_COMMIT_SHA:-none}" != "none" ]; then
    FIXES_OK=1
fi
if [ "$FIXES_OK" -eq 0 ]; then
    emit "skip" "no fix pushed this round; nothing to claim 'addressed in <SHA>'" 0 0 0
fi

# ── Precondition 1 (checked second): force-push detected since Copilot's last review ─

if [ "${FORCE_PUSH_DETECTED:-0}" != "1" ]; then
    emit "skip" "no force-push detected; Copilot will auto-re-review on linear push" 0 0 1
fi

# ── Precondition 2 (checked third): every Copilot thread anchored to HEAD-touched lines ─

THREAD_COUNT=$(printf '%s' "${COPILOT_THREADS_JSON:-[]}" | jq -r 'length' 2>/dev/null || echo 0)
case "$THREAD_COUNT" in ''|*[!0-9]*) THREAD_COUNT=0 ;; esac

if [ "$THREAD_COUNT" -eq 0 ]; then
    emit "skip" "no unresolved Copilot threads to resolve" 0 0 1
fi

# Walk every thread; verify <path>:<line> falls inside one of HEAD's hunks.
# fail-CLOSED: if ANY thread fails the anchor check, skip the entire batch.
# Single jq call — avoids O(N) subprocess forks of the per-iteration loop.
# -n: use null as the input (the data is passed via --argjson, not stdin).
# Without -n, jq blocks on stdin, receives EOF, emits nothing, and the
# downstream integer comparison silently fails-OPEN to "resolve". Defense
# in depth: validate the output is exactly "0" or "1" before the integer
# test so any future jq breakage produces a deterministic skip instead of
# a fail-OPEN to resolve.
ALL_ANCHORED=$(jq -nr \
    --argjson threads "${COPILOT_THREADS_JSON}" \
    --argjson hunks "${HEAD_TOUCHED_LINES_JSON:-[]}" \
    '($threads | length > 0) and
     ($threads | all(
         . as $t |
         ($hunks | any(.path == $t.path and .start <= ($t.line // 0) and ($t.line // 0) <= .end))
     )) | if . then "1" else "0" end' \
    2>/dev/null || echo "0")
case "$ALL_ANCHORED" in 0|1) ;; *) ALL_ANCHORED=0 ;; esac

if [ "$ALL_ANCHORED" -eq 0 ]; then
    emit "skip" "at least one Copilot thread anchored to a line HEAD did not touch" \
        "$THREAD_COUNT" 0 1
fi

emit "resolve" "all three preconditions hold" "$THREAD_COUNT" 1 1
