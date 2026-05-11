#!/usr/bin/env bash
# Tests for scripts/copilot-auto-resolve-eligibility.sh — Phase 2 of pr-grind work.
#
# Validates the three canonical scenarios from the implementation spec:
#   5. Copilot stale on force-push; all 3 Copilot threads anchored to changed
#      lines with substantive fixes → "resolve" (worker posts addressed-in-SHA
#      reply + resolveReviewThread mutation; ack ledger flips to HEAD via
#      scripts/ack-ledger.sh tier A).
#   6. Copilot stale on force-push; threads anchored to lines NOT touched by
#      HEAD → "skip" (worker leaves threads alone; ack ledger stays stale).
#   7. Copilot stale but no force-push detected (regular push) → "skip"
#      (worker does NOT auto-resolve threads; Copilot will catch up on its
#      own via the linear-push trigger).
#
# Plus defensive cases that bound the carve-out.
#
# Usage: bash tests/test-copilot-resolve.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT="scripts/copilot-auto-resolve-eligibility.sh"
PASS=0
FAIL=0
TOTAL=0

# ── Fixtures ─────────────────────────────────────────────────────────────

# 3 Copilot threads, all anchored to lines in src/foo.ts and src/bar.ts.
THREE_THREADS_FOO_BAR='[
    {"threadId":"T1","path":"src/foo.ts","line":42},
    {"threadId":"T2","path":"src/foo.ts","line":58},
    {"threadId":"T3","path":"src/bar.ts","line":10}
]'

# 1 thread on a line NOT touched by HEAD.
ONE_THREAD_UNTOUCHED='[
    {"threadId":"T9","path":"src/untouched.ts","line":100}
]'

# Mixed: 2 anchored to touched, 1 to untouched (fail-CLOSED scenario).
MIXED_THREADS='[
    {"threadId":"T1","path":"src/foo.ts","line":42},
    {"threadId":"T9","path":"src/untouched.ts","line":100}
]'

# HEAD touched lines covering the threads in THREE_THREADS_FOO_BAR.
TOUCHED_FOO_BAR='[
    {"path":"src/foo.ts","start":40,"end":60},
    {"path":"src/bar.ts","start":1,"end":15}
]'

# HEAD touched a completely different file.
TOUCHED_OTHER='[
    {"path":"src/other.ts","start":1,"end":50}
]'

# ── Helper ───────────────────────────────────────────────────────────────

run_case() {
    local name="$1"
    local expected_decision="$2"
    local expected_anchored="$3"
    local expected_fixes="$4"
    TOTAL=$((TOTAL + 1))

    local out decision anchored fixes
    out=$(bash "$SCRIPT" 2>/dev/null) || {
        printf "  FAIL  %s (script exited non-zero)\n" "$name"
        FAIL=$((FAIL + 1))
        return
    }
    decision=$(printf '%s' "$out" | jq -r '.decision' 2>/dev/null || echo "")
    anchored=$(printf '%s' "$out" | jq -r '.all_anchored' 2>/dev/null || echo "")
    fixes=$(printf '%s' "$out" | jq -r '.fixes_this_round' 2>/dev/null || echo "")

    if [ "$decision" = "$expected_decision" ] \
       && [ "$anchored" = "$expected_anchored" ] \
       && [ "$fixes" = "$expected_fixes" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        printf "        expected: decision=%s all_anchored=%s fixes_this_round=%s\n" \
            "$expected_decision" "$expected_anchored" "$expected_fixes"
        printf "        got:      decision=%s all_anchored=%s fixes_this_round=%s\n" \
            "$decision" "$anchored" "$fixes"
        printf "        full out: %s\n" "$out"
        FAIL=$((FAIL + 1))
    fi
}

# ── Scenarios ────────────────────────────────────────────────────────────

echo "── copilot-auto-resolve-eligibility ────────────────────────"

# 5. Copilot stale on force-push; all 3 threads anchored to changed lines
#    with substantive fixes → resolve
export RESULT_FIXES="rewrite onclick handler in src/foo.ts; tighten state guard in src/bar.ts"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON="$THREE_THREADS_FOO_BAR"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "5. force-push + all 3 threads anchored + substantive fix → resolve" \
    "resolve" "1" "1"

# 6. Copilot stale on force-push; threads anchored to lines NOT touched by HEAD
#    → skip
export RESULT_FIXES="rewrite onclick handler"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON="$ONE_THREAD_UNTOUCHED"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_OTHER"
run_case "6. force-push + thread on untouched line → skip" \
    "skip" "0" "1"

# 7. Copilot stale but no force-push detected (regular push) → skip
export RESULT_FIXES="rewrite onclick handler"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="0"
export COPILOT_THREADS_JSON="$THREE_THREADS_FOO_BAR"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "7. NO force-push (linear push) → skip (Copilot will catch up)" \
    "skip" "0" "1"

# ── Defensive cases ──────────────────────────────────────────────────────

echo ""
echo "── copilot-auto-resolve-eligibility (defensive) ────────────"

# 8. No fix pushed this round → skip (precondition 3 fails)
export RESULT_FIXES="none"
export RESULT_COMMIT_SHA="none"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON="$THREE_THREADS_FOO_BAR"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "8. no fix this round → skip (no SHA to claim 'addressed in')" \
    "skip" "0" "0"

# 9. Empty thread list → skip (nothing to resolve)
export RESULT_FIXES="rewrite onclick handler"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON='[]'
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "9. no Copilot threads → skip (nothing to resolve)" \
    "skip" "0" "1"

# 10. Mixed: some threads anchored, some not → fail-CLOSED to skip
export RESULT_FIXES="rewrite onclick handler"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON="$MIXED_THREADS"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "10. mixed anchored+unanchored threads → skip (fail-CLOSED on partial coverage)" \
    "skip" "0" "1"

# 11. RESULT_FIXES present but RESULT_COMMIT_SHA is "none" → skip
export RESULT_FIXES="rewrote handler"
export RESULT_COMMIT_SHA="none"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON="$THREE_THREADS_FOO_BAR"
export HEAD_TOUCHED_LINES_JSON="$TOUCHED_FOO_BAR"
run_case "11. RESULT_FIXES present but RESULT_COMMIT_SHA=none → skip" \
    "skip" "0" "0"

# 12. Thread.line = 0 (edge) → must NOT match a touched range starting at >=1
export RESULT_FIXES="rewrote handler"
export RESULT_COMMIT_SHA="abc1234"
export FORCE_PUSH_DETECTED="1"
export COPILOT_THREADS_JSON='[{"threadId":"T1","path":"src/foo.ts","line":0}]'
export HEAD_TOUCHED_LINES_JSON='[{"path":"src/foo.ts","start":1,"end":10}]'
run_case "12. thread.line=0 falls outside any touched range → skip" \
    "skip" "0" "1"

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
