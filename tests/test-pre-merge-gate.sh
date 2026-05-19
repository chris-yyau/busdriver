#!/usr/bin/env bash
# Tests for pre-merge gate and post-PR-created hook.
#
# Validates:
#   1. Pre-merge gate blocks gh pr merge without pr-grind-clean marker
#   2. Pre-merge gate allows with fresh marker
#   3. Pre-merge gate allows with skip file
#   4. Pre-merge gate ignores non-merge commands
#   5. Pre-merge gate rejects stale markers (>2h)
#   6. Post-PR-created hook appends pr-grind instruction
#   7. Post-PR-created hook passes through non-PR commands
#
# Usage: bash tests/test-pre-merge-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

GATE_SCRIPT="hooks/gate-scripts/pre-merge-gate.sh"
POST_HOOK_SCRIPT="hooks/gate-scripts/post-merge-confirm-bypass.sh"
HOOK_SCRIPT="scripts/hooks/post-bash-pr-created.js"
MARKER_DIR=".claude"
CLEAN_MARKER="$MARKER_DIR/pr-grind-clean.local"
SKIP_FILE="$MARKER_DIR/skip-pr-grind.local"
PENDING_MARKER="$MARKER_DIR/pr-pending-grind.local"
BYPASS_PENDING="$MARKER_DIR/.merge-bypass-pending.local"

# ── Helpers ───────────────────────────────────────────────────────────

run_gate_test() {
    local name="$1" expected="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local output exit_code
    output=$(printf '%s' "$input" | bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?

    local got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi

    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

run_hook_test() {
    local name="$1" expected_pattern="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local output
    output=$(CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
        const m = require('./$HOOK_SCRIPT');
        const r = m.run(process.argv[1]);
        if (typeof r === 'string') process.stdout.write(r);
        else if (r && r.stdout) process.stdout.write(r.stdout);
    " "$input" 2>/dev/null) || true

    if echo "$output" | grep -q "$expected_pattern" 2>/dev/null; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (pattern '%s' not found)\n" "$name" "$expected_pattern"
        FAIL=$((FAIL + 1))
    fi
}

# ── Setup ─────────────────────────────────────────────────────────────
mkdir -p "$MARKER_DIR"

# Save and restore any existing markers (track existence, not just content)
HAD_CLEAN=false ; HAD_SKIP=false ; HAD_PENDING=false ; HAD_BYPASS=false
PREV_CLEAN="" ; PREV_SKIP="" ; PREV_PENDING="" ; PREV_BYPASS=""
[ -f "$CLEAN_MARKER" ]    && HAD_CLEAN=true    && PREV_CLEAN=$(cat "$CLEAN_MARKER")
[ -f "$SKIP_FILE" ]       && HAD_SKIP=true     && PREV_SKIP=$(cat "$SKIP_FILE")
[ -f "$PENDING_MARKER" ]  && HAD_PENDING=true  && PREV_PENDING=$(cat "$PENDING_MARKER")
[ -f "$BYPASS_PENDING" ]  && HAD_BYPASS=true   && PREV_BYPASS=$(cat "$BYPASS_PENDING")

cleanup() {
    rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"
    [ "$HAD_CLEAN" = true ]   && printf '%s' "$PREV_CLEAN"   > "$CLEAN_MARKER"   || true
    [ "$HAD_SKIP" = true ]    && printf '%s' "$PREV_SKIP"    > "$SKIP_FILE"      || true
    [ "$HAD_PENDING" = true ] && printf '%s' "$PREV_PENDING" > "$PENDING_MARKER" || true
    [ "$HAD_BYPASS" = true ]  && printf '%s' "$PREV_BYPASS"  > "$BYPASS_PENDING" || true
}
trap cleanup EXIT

# Start clean
rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"

# ═══════════════════════════════════════════════════════════════════════
# PRE-MERGE GATE TESTS
# ═══════════════════════════════════════════════════════════════════════
MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 31 --squash"}}'
NON_MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"npm install"}}'
MERGE_WITH_CD='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd /tmp/repo && gh pr merge 42 --squash --delete-branch"}}'
MULTI_MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 42 --squash && gh pr merge 99 --squash"}}'

echo "── pre-merge-gate ──────────────────────────────────────────"

# 1. Block without marker
run_gate_test "blocks gh pr merge without marker" "block" "$MERGE_INPUT"

# 2. Allow with fresh marker
echo "31" > "$CLEAN_MARKER"
run_gate_test "allows gh pr merge with fresh marker" "allow" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 3. Allow with skip file (must be > 30s old to pass anti-self-bypass).
#    Bug B deferred-consumption: gate should ALSO leave skip file in place
#    and write .merge-bypass-pending.local so PostToolUse can consume only on
#    confirmed merge-success.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null \
    || true
rm -f "$BYPASS_PENDING"
run_gate_test "allows gh pr merge with skip file" "allow" "$MERGE_INPUT"

# 3a. Deferred-consumption: skip file MUST still exist after gate-pass
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ]; then
    printf "  PASS  defers skip-pr-grind.local consumption (still exists post-gate)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  defers skip-pr-grind.local consumption (skip file was deleted)\n"
    FAIL=$((FAIL + 1))
fi

# 3b. Deferred-consumption: pending claim MUST be written
TOTAL=$((TOTAL + 1))
if [ -f "$BYPASS_PENDING" ]; then
    printf "  PASS  writes .merge-bypass-pending.local on gate-pass\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  writes .merge-bypass-pending.local on gate-pass\n"
    FAIL=$((FAIL + 1))
fi

# 3c. Pending claim records the merge PR number for audit
TOTAL=$((TOTAL + 1))
if [ -f "$BYPASS_PENDING" ] && grep -q '^merge_pr=31$' "$BYPASS_PENDING" 2>/dev/null; then
    printf "  PASS  pending claim records merge_pr=31\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  pending claim records merge_pr=31 (content: %s)\n" \
        "$(cat "$BYPASS_PENDING" 2>/dev/null || echo MISSING)"
    FAIL=$((FAIL + 1))
fi

rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# 4. Ignore non-merge commands
run_gate_test "ignores non-merge commands" "allow" "$NON_MERGE_INPUT"

# 5. Block with merge + cd prefix (no marker)
run_gate_test "blocks cd + gh pr merge without marker" "block" "$MERGE_WITH_CD"

# 6. Non-Bash tool name → allow (not our concern)
run_gate_test "ignores non-Bash tool" "allow" \
    '{"tool_name":"Write","tool_input":{"file_path":"test.js"}}'

# 7. Stale marker (simulate by touching with old timestamp)
echo "31" > "$CLEAN_MARKER"
# Touch with timestamp 3 hours ago (macOS or GNU)
TOUCH_OK=false
touch -t "$(date -v-3H '+%Y%m%d%H%M.%S')" "$CLEAN_MARKER" 2>/dev/null && TOUCH_OK=true
[ "$TOUCH_OK" = false ] && touch -d "3 hours ago" "$CLEAN_MARKER" 2>/dev/null && TOUCH_OK=true
if [ "$TOUCH_OK" = true ]; then
    run_gate_test "blocks with stale marker (>2h old)" "block" "$MERGE_INPUT"
else
    TOTAL=$((TOTAL + 1))
    printf "  SKIP  blocks with stale marker (>2h old) — touch timestamp not supported\n"
    PASS=$((PASS + 1))  # Don't fail the suite on platform limitation
fi
rm -f "$CLEAN_MARKER"

# 7c. Multi-merge guard: refuse Bash commands chaining more than one
#     gh pr merge invocation, regardless of marker/skip state.
echo "42" > "$CLEAN_MARKER"  # marker WOULD authorize PR 42, but multi-merge blocks anyway
run_gate_test "blocks chained gh pr merge (multi-merge guard)" "block" "$MULTI_MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 7a. Bug A: marker for PR X must NOT authorize merging PR Y. Marker holds
#     a different PR number than the one being merged → gate blocks.
echo "99" > "$CLEAN_MARKER"
run_gate_test "blocks when marker PR != merge PR (cross-PR mismatch)" "block" "$MERGE_INPUT"
rm -f "$CLEAN_MARKER"

# 7b. Bug A: when the mismatch fires, the stale marker is removed so the
#     next attempt does not silently re-authorize.
echo "99" > "$CLEAN_MARKER"
printf '%s' "$MERGE_INPUT" | bash "$GATE_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$CLEAN_MARKER" ]; then
    printf "  PASS  removes mismatched pr-grind-clean marker (no silent re-auth)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  removes mismatched pr-grind-clean marker\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$CLEAN_MARKER"

# ═══════════════════════════════════════════════════════════════════════
# POST-MERGE BYPASS CONFIRMATION HOOK TESTS (Bug B)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-merge-confirm-bypass ──────────────────────────────"

# B1. Success path: merge succeeded → consume skip file + clear pending.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
SUCCESS_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"✓ Squashed and merged pull request #42","exit_code":0}}'
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  success → skip + pending consumed\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  success path: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B2. Failure path: merge failed → leave skip file, clear pending.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
FAIL_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --delete-branch"},"tool_output":{"output":"X Pull request is not mergeable: the head branch is not up to date with the base branch.","exit_code":1}}'
printf '%s' "$FAIL_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  failure → skip preserved, pending released\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  failure path: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B3. No pending claim → hook is a no-op (does not touch skip file).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ]; then
    printf "  PASS  no pending claim → skip file untouched\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  no pending claim → skip file was incorrectly deleted\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B4. Non-merge bash call does not touch pending claim.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=0\nmerge_pr=42\nclaimed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
NON_MERGE_BASH='{"tool_name":"Bash","tool_input":{"command":"gh pr view 42"},"tool_output":{"output":"PR title\n","exit_code":0}}'
printf '%s' "$NON_MERGE_BASH" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ -f "$BYPASS_PENDING" ]; then
    printf "  PASS  non-merge bash leaves pending claim intact\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  non-merge bash touched pending claim or skip file\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B5. Ambiguous output (no clear success/failure signal) → fail-safe: leave skip.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
AMBIG_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash"},"tool_output":{"output":"some unfamiliar output that matches neither pattern"}}'
printf '%s' "$AMBIG_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  ambiguous → fail-safe (skip preserved, pending released)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  ambiguous: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B6. Tamper detection: skip file mtime changed between claim and confirm.
#     Pending file records the OLD mtime; current file has a NEWER mtime.
#     Should refuse to consume + preserve skip (release-tampered).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
ORIGINAL_MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$ORIGINAL_MTIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# Simulate tamper: re-touch skip file to update its mtime (claim's mtime now stale)
touch "$SKIP_FILE"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  tamper detected (skip mtime changed) → released, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  tamper detection: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B7. Tamper detection: skip file deleted between claim and confirm.
#     Pending file claims an mtime but the skip file is gone. Should release
#     pending (nothing left to consume).
printf 'skip_mtime=12345\nmerge_pr=42\nclaimed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# No skip file — pre-existing or post-gate deletion
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  skip file missing → released-tampered (nothing to consume)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  missing-skip case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B8. Tamper detection: skip file is too young (<30s) at confirm time.
#     Re-applies the anti-self-bypass check at consumption — defense
#     against a Claude self-touch between claim and confirm.
touch "$SKIP_FILE"  # fresh mtime → age = 0s
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  skip <30s at confirm → released-tampered, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  young-skip case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B9. Cross-PR mismatch: claim is for PR 42 but bash cmd is gh pr merge 99.
#     Should release pending without consuming skip (released-mismatch).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
MISMATCH_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 99 --squash"},"tool_output":{"output":"✓ Squashed and merged pull request #99","exit_code":0}}'
printf '%s' "$MISMATCH_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  claim/cmd PR mismatch → released-mismatch, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  PR mismatch: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B10. Auto-merge enabled (gh pr merge --auto) → PR not actually merged yet.
#      Should release pending and preserve skip so retry doesn't need a
#      re-touch when the real merge eventually fires (or fails).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
AUTO_INPUT='{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42 --squash --auto"},"tool_output":{"output":"✓ Pull request #42 will be automatically merged via squash when all requirements are met","exit_code":0}}'
printf '%s' "$AUTO_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  --auto enable → released-auto-queued, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  --auto case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B11. Malformed pending file (non-numeric mtime / corrupt content) →
#      released-malformed without consuming the skip file.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=not-a-number\nmerge_pr=DROP TABLE users;\nclaimed_at=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  malformed pending → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  malformed case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B12. Stale-cleanup ordering: a >5min-old pending claim must NOT be
#      cleaned up when the current Bash call IS gh pr merge — the merge
#      processing must take priority. (Cleanup is for crash-recovery on
#      unrelated bash calls only.)
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
# Make pending file >5min old (10 min)
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$BYPASS_PENDING" 2>/dev/null \
    || touch -d "10 minutes ago" "$BYPASS_PENDING" 2>/dev/null || true
# Run hook with gh pr merge → cleanup must NOT fire here; the success path
# must process the merge normally (skip + pending consumed).
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  stale pending on gh-pr-merge call → merge processed (not cleaned)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  stale ordering: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B14. Stricter PR equality: claim with merge_pr=unknown must NOT
#      authorize consumption even on a success-pattern merge. The
#      auto-detect path is rejected to prevent cross-PR token reuse via
#      branch-switching between claim and confirm.
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=unknown\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  unknown-PR claim + success → released-mismatch, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  unknown-PR case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B15. Log-injection defense: claimed_at containing JSON-fragment text
#      must be rejected as malformed (preserves bypass-log.jsonl integrity).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=2026-05-20T02:00:00Z","event":"INJECTED\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    > "$BYPASS_PENDING"
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  log-injection in claimed_at → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  log-injection case: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
# Verify the bypass-log line for this injection attempt does NOT contain
# the injected fragment in a JSON-key position. Look at the last log line
# written by this hook for the malformed event.
LAST_LOG=$(tail -1 .claude/bypass-log.jsonl 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if printf '%s' "$LAST_LOG" | grep -q 'released-malformed' \
    && ! printf '%s' "$LAST_LOG" | grep -q '"event":"INJECTED"'; then
    printf "  PASS  log line preserves JSONL framing (no injected event key)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  log injection detected: %s\n" "$LAST_LOG"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# B13. Stale-cleanup correctness: a >5min-old pending claim IS cleaned up
#      when the current Bash call is unrelated (not gh pr merge). Skip
#      file is preserved (cleanup only releases the claim, not the skip).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$BYPASS_PENDING"
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$BYPASS_PENDING" 2>/dev/null \
    || touch -d "10 minutes ago" "$BYPASS_PENDING" 2>/dev/null || true
UNRELATED_BASH='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_output":{"output":"total 8\n","exit_code":0}}'
printf '%s' "$UNRELATED_BASH" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  stale pending on unrelated bash → force-cleaned, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  stale cleanup: skip exists=%s pending exists=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
rm -f "$SKIP_FILE" "$BYPASS_PENDING"

# ═══════════════════════════════════════════════════════════════════════
# POST-PR-CREATED HOOK TESTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-bash-pr-created ────────────────────────────────────"

# 8. Appends instruction on PR creation
run_hook_test "appends pr-grind instruction on PR creation" "PR Grind Required" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title test"},"tool_output":{"output":"https://github.com/owner/repo/pull/42\n"}}'

# 9. Passes through non-PR commands
run_hook_test "passes through non-PR commands" "npm install" \
    '{"tool_name":"Bash","tool_input":{"command":"npm install"},"tool_output":{"output":"added 5 packages\n"}}'

# 10. Passes through failed PR creation (no URL in output)
run_hook_test "passes through failed PR creation" "error creating" \
    '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title test"},"tool_output":{"output":"error creating pull request\n"}}'

# 11. Writes pending marker
rm -f "$PENDING_MARKER"
CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
    const m = require('./$HOOK_SCRIPT');
    m.run(JSON.stringify({tool_name:'Bash',tool_input:{command:'gh pr create --title test'},tool_output:{output:'https://github.com/owner/repo/pull/99\n'}}));
" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$PENDING_MARKER" ]; then
    printf "  PASS  writes pr-pending-grind.local on PR creation\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  writes pr-pending-grind.local on PR creation\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$PENDING_MARKER"

# 12. Invalidates stale clean marker on new PR creation
echo "old-pr" > "$CLEAN_MARKER"
CLAUDE_PLUGIN_ROOT="$(pwd)" node -e "
    const m = require('./$HOOK_SCRIPT');
    m.run(JSON.stringify({tool_name:'Bash',tool_input:{command:'gh pr create --title test'},tool_output:{output:'https://github.com/owner/repo/pull/99\n'}}));
" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ ! -f "$CLEAN_MARKER" ]; then
    printf "  PASS  invalidates stale pr-grind-clean.local on new PR\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  invalidates stale pr-grind-clean.local on new PR\n"
    FAIL=$((FAIL + 1))
fi
rm -f "$CLEAN_MARKER" "$PENDING_MARKER"

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
