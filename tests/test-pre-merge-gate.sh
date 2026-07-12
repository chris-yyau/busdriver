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
#   8. Gate is wired to scripts/relevant-check-status.sh (issue #154) and the
#      lock-aware allowlist + ADVISORY_PATTERN fallback behaves correctly when
#      driven through the gate-relative helper path (R1-R8 integration). Filter
#      edge-case units live in tests/test-relevant-check-status.sh.
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
WRAPPED_BASH_C='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"bash -c \"gh pr merge 42 --squash && gh pr merge 99 --squash\""}}'
WRAPPED_SUBSHELL='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"(gh pr merge 42 --squash; gh pr merge 99 --squash)"}}'

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

# 7d. Multi-merge guard MUST also catch wrapper bypasses (bash -c, sh -c,
#     eval, subshell). Substring-count over the whole cmd, not per-segment.
echo "42" > "$CLEAN_MARKER"
run_gate_test "blocks bash -c wrapped chained merges" "block" "$WRAPPED_BASH_C"
rm -f "$CLEAN_MARKER"

# 7e. Subshell-wrapped chained merges.
echo "42" > "$CLEAN_MARKER"
run_gate_test "blocks (...)-subshell chained merges" "block" "$WRAPPED_SUBSHELL"
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

# 7f. cwd-anchored resolution: the recognized $(git rev-parse --show-toplevel)
#     idiom resolves via cwd instead of a junk path, so a fresh marker
#     authorizes the merge (previously this spurious-blocked). Shares the
#     gh-availability precondition with case 2 above.
SUBST_MERGE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd \"$(git rev-parse --show-toplevel)\" && gh pr merge 31 --squash"}}'
echo "31" > "$CLEAN_MARKER"
run_gate_test "allows toplevel-idiom cd prefix with fresh marker" "allow" "$SUBST_MERGE"
rm -f "$CLEAN_MARKER"

# 7g. Unresolvable command substitution in the cd target → fail-CLOSED block,
#     even with a marker that would otherwise authorize the merge (the block
#     fires during resolution, before the marker check).
UNRESOLV_MERGE='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"cd \"$(echo /x)\" && gh pr merge 31 --squash"}}'
echo "31" > "$CLEAN_MARKER"
run_gate_test "blocks unresolvable cd substitution target" "block" "$UNRESOLV_MERGE"
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

# B15a. Log-injection defense via merge_pr (round-3 fix): if a forged
#       pending file contains a malformed merge_pr (non-numeric/non-unknown)
#       with embedded JSON-fragment text, the malformed branch must also
#       suppress merge_pr in the log (mirroring the claimed_at fix).
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null \
    || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
printf 'skip_mtime=%s\nmerge_pr=42","event":"INJECTED-VIA-PR\nclaimed_at=%s\n' \
    "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BYPASS_PENDING"
LOG_LINES_BEFORE_B15A=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
printf '%s' "$SUCCESS_INPUT" | bash "$POST_HOOK_SCRIPT" 2>/dev/null || true
TOTAL=$((TOTAL + 1))
if [ -f "$SKIP_FILE" ] && [ ! -f "$BYPASS_PENDING" ]; then
    printf "  PASS  log-injection in merge_pr → released-malformed, skip preserved\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  merge_pr injection: skip=%s pending=%s\n" \
        "$([ -f "$SKIP_FILE" ] && echo yes || echo no)" \
        "$([ -f "$BYPASS_PENDING" ] && echo yes || echo no)"
    FAIL=$((FAIL + 1))
fi
LOG_LINES_AFTER_B15A=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
LAST_LOG=$(tail -1 .claude/bypass-log.jsonl 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if [ "$LOG_LINES_AFTER_B15A" -gt "$LOG_LINES_BEFORE_B15A" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'released-malformed' \
    && ! printf '%s' "$LAST_LOG" | grep -q '"event":"INJECTED-VIA-PR"'; then
    printf "  PASS  log line preserves framing on merge_pr injection\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  merge_pr injection escaped into log (lines before=%s after=%s): %s\n" \
        "$LOG_LINES_BEFORE_B15A" "$LOG_LINES_AFTER_B15A" "$LAST_LOG"
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
LOG_LINES_BEFORE_B15=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
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
# the injected fragment in a JSON-key position. Assert a new line was
# appended first, then validate the last line content.
LOG_LINES_AFTER_B15=$(wc -l < .claude/bypass-log.jsonl 2>/dev/null || echo 0)
LAST_LOG=$(tail -1 .claude/bypass-log.jsonl 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if [ "$LOG_LINES_AFTER_B15" -gt "$LOG_LINES_BEFORE_B15" ] \
    && printf '%s' "$LAST_LOG" | grep -q 'released-malformed' \
    && ! printf '%s' "$LAST_LOG" | grep -q '"event":"INJECTED"'; then
    printf "  PASS  log line preserves JSONL framing (no injected event key)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  log injection detected (lines before=%s after=%s): %s\n" \
        "$LOG_LINES_BEFORE_B15" "$LOG_LINES_AFTER_B15" "$LAST_LOG"
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
# REQUIRED-CHECKS ALLOWLIST TESTS
# ═══════════════════════════════════════════════════════════════════════
# Exercises _relevant_check_counts directly with synthetic gh pr checks
# text + synthetic .github/required-checks.lock files in tmpdirs. The
# helper drives both fail-counting sites in the gate, so unit-testing it
# covers the marker-path and bootstrap paths equivalently.
echo ""
echo "── required-checks allowlist ───────────────────────────────"

# The filter logic now lives in scripts/relevant-check-status.sh (issue #154);
# its full edge-case unit coverage is in tests/test-relevant-check-status.sh.
# Here we drive it through the SAME gate-relative path the gate's wrapper uses,
# so R1-R8 double as gate↔helper integration tests (path resolution + argument
# passing + line-1 parse). No more sed/eval of the gate's function body — that
# body is now a thin wrapper, and eval'ing it here would mis-resolve
# ${BASH_SOURCE[0]} to this test file instead of the gate.
export BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE=1  # test the working copy deterministically
HELPER="$(cd "$(dirname "$GATE_SCRIPT")" && pwd -P)/../../scripts/relevant-check-status.sh"
TOTAL=$((TOTAL + 1))
if [ -f "$HELPER" ] && grep -vE '^\s*#' "$GATE_SCRIPT" | grep -q 'relevant-check-status\.sh' && ! grep -q 'import sys, os, json, re' "$GATE_SCRIPT"; then
    printf "  PASS  gate wired to relevant-check-status.sh (inline python removed)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  gate not wired to helper, or inline python still present\n"
    FAIL=$((FAIL + 1))
fi
# Local wrapper mirrors the gate's _relevant_check_counts() invocation: it calls
# $HELPER (the same script the gate delegates to) with the same args the gate
# passes. `head -n1` keeps only the count line (the helper appends failing rows
# on lines 2..N, which the gate's `read <<<` ignores).
# Note: sourcing the full gate script to call its wrapper is not feasible here
# because the gate's main body runs at source time. Since _relevant_check_counts
# in the gate is a thin wrapper that just calls $HELPER, calling $HELPER directly
# is equivalent and avoids side-effects.
_relevant_check_counts() { bash "$HELPER" "$1" "CodeScene" 2>/dev/null | head -n1; }

# Synthetic CI output mirrors gh pr checks text: tab-separated columns,
# first column = check name. Same shape regardless of pass/fail mix.
SYNTH_CHECKS=$(printf 'shellcheck\tpass\t5s\thttps://x\ncommitlint\tfail\t3s\thttps://x\nCodeScene\tfail\t10s\thttps://x\nbuild\tpending\t1m\thttps://x\n')

# R1. Lock present + required[] includes only "shellcheck" → commitlint fail
#     is NOT counted (not in required), build pending NOT counted, CodeScene
#     fail NOT counted. Expected: 0 fail, 0 pending, mode=required.
REPO_R1=$(mktemp -d)
mkdir -p "$REPO_R1/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R1/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R1")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 0 required 1" ]]; then
    printf "  PASS  allowlist filters out non-required failures\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist non-required filter (got '%s', want '0 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R1"

# R2. Lock present + required[] includes "commitlint" → commitlint fail
#     IS counted. Expected: 1 fail, 0 pending, mode=required.
REPO_R2=$(mktemp -d)
mkdir -p "$REPO_R2/.github"
printf '%s' '{"required":[{"name":"commitlint"}]}' > "$REPO_R2/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R2")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  allowlist counts required failures\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist counts required failures (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R2"

# R3. Lock present + required[] includes "build" (pending) → 0 fail, 1 pending.
REPO_R3=$(mktemp -d)
mkdir -p "$REPO_R3/.github"
printf '%s' '{"required":[{"name":"build"}]}' > "$REPO_R3/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R3")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 1 required 1" ]]; then
    printf "  PASS  allowlist counts required pending checks\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  allowlist required pending (got '%s', want '0 1 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R3"

# R4. Lock missing → fallback to ADVISORY_PATTERN filter. CodeScene fail
#     is dropped, commitlint fail counted, build pending counted.
#     Expected: 1 fail, 1 pending, mode=all.
REPO_R4=$(mktemp -d)
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R4")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  no lock file → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  no-lock fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R4"

# R5. Malformed lock (invalid JSON) → fallback to ADVISORY_PATTERN.
REPO_R5=$(mktemp -d)
mkdir -p "$REPO_R5/.github"
printf '%s' 'not valid json{' > "$REPO_R5/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R5")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  malformed lock → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  malformed-lock fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R5"

# R6. Empty required[] → fallback (no allowlist means "no opinion", not
#     "allow everything"). Same as R4 expectation.
REPO_R6=$(mktemp -d)
mkdir -p "$REPO_R6/.github"
printf '%s' '{"required":[]}' > "$REPO_R6/.github/required-checks.lock"
OUT=$(printf '%s' "$SYNTH_CHECKS" | _relevant_check_counts "$REPO_R6")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 1 all 3" ]]; then
    printf "  PASS  empty required[] → ADVISORY_PATTERN fallback\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  empty-required fallback (got '%s', want '1 1 all 3')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R6"

# R7a. Whitespace-padded names in required[] still match. Lock files
#      written by hand or pasted from CI logs can carry stray spaces;
#      without normalization the allowlist silently misses the real
#      failure → fail-open. (Regression test for the .strip() inside
#      the python helper.)
REPO_R7A=$(mktemp -d)
mkdir -p "$REPO_R7A/.github"
printf '%s' '{"required":[{"name":"  shellcheck  "}]}' > "$REPO_R7A/.github/required-checks.lock"
OUT=$(printf 'shellcheck\tfail\t5s\thttps://x\n' | _relevant_check_counts "$REPO_R7A")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  required[] names with padding strip-match\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  whitespace-padded name match (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7A"

# R7b. Status column parsing — a passing check whose URL contains "fail"
#      (e.g. /actions/runs/.../fail-handler) must NOT be miscounted as
#      failed. Pre-fix the helper substring-scanned the whole line.
REPO_R7B=$(mktemp -d)
mkdir -p "$REPO_R7B/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R7B/.github/required-checks.lock"
URL_TRAP=$(printf 'shellcheck\tpass\t5s\thttps://github.com/owner/repo/actions/runs/12345/job/fail-handler\n')
OUT=$(printf '%s' "$URL_TRAP" | _relevant_check_counts "$REPO_R7B")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 0 required 1" ]]; then
    printf "  PASS  status column parsing ignores 'fail' in URL column\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  URL substring false-positive (got '%s', want '0 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7B"

# R7c. Lock has multi-word check name ("Actions security") → exact-match
#      against first tab-separated column handles spaces correctly.
REPO_R7C=$(mktemp -d)
mkdir -p "$REPO_R7C/.github"
printf '%s' '{"required":[{"name":"Actions security"}]}' > "$REPO_R7C/.github/required-checks.lock"
MULTI_CHECKS=$(printf 'Actions security\tfail\t8s\thttps://x\nshellcheck\tpass\t5s\thttps://x\n')
OUT=$(printf '%s' "$MULTI_CHECKS" | _relevant_check_counts "$REPO_R7C")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "1 0 required 1" ]]; then
    printf "  PASS  allowlist matches multi-word check names\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  multi-word match (got '%s', want '1 0 required 1')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R7C"

# R8. Empty stdin → kept count is 0. Bootstrap path uses this to refuse a
#     bootstrap-merge when no relevant checks ran at all (defends against
#     a gate-modifying PR that also disables CI).
REPO_R8=$(mktemp -d)
mkdir -p "$REPO_R8/.github"
printf '%s' '{"required":[{"name":"shellcheck"}]}' > "$REPO_R8/.github/required-checks.lock"
OUT=$(printf '' | _relevant_check_counts "$REPO_R8")
TOTAL=$((TOTAL + 1))
if [[ "$OUT" = "0 0 required 0" ]]; then
    printf "  PASS  empty stdin → kept=0 (bootstrap fail-safe signal)\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  empty-stdin kept count (got '%s', want '0 0 required 0')\n" "$OUT"
    FAIL=$((FAIL + 1))
fi
rm -rf "$REPO_R8"

# ═══════════════════════════════════════════════════════════════════════
# MATCHER HARDENING: whitespace/prefix bypass regression (Task 1)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── pre-merge-gate whitespace/prefix bypass ─────────────────"
rm -f "$CLEAN_MARKER" "$SKIP_FILE" "$PENDING_MARKER" "$BYPASS_PENDING"

# Double space defeated the literal-single-space pre-filter (*gh\ pr\ merge*),
# skipping the parser entirely → early exit 0 (allow). Now *gh*pr*merge*.
run_gate_test "blocks 'gh  pr  merge' (double-space pre-filter bypass)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"gh  pr  merge 31 --squash"}}'
# Wrapper prefix: the parser already used whole-command re.findall, so this was
# blocked pre-fix too — asserted here to lock in cross-gate detection parity.
run_gate_test "blocks 'command gh pr merge' (wrapper prefix)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"command gh pr merge 31 --squash"}}'

# ═══════════════════════════════════════════════════════════════════════
# POST-MERGE-CONFIRM detection: prose must NOT be treated as a merge (Task 1)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── post-merge-confirm-bypass prose vs command ──────────────"
PMCB="hooks/gate-scripts/post-merge-confirm-bypass.sh"
# Setup a scratch repo with a STALE pending file, run the post-merge hook on it,
# and report whether stale-cleanup fired. Stale-cleanup only runs when detection
# says NOT-a-merge, so it is a clean proxy for the is_merge decision against the
# real script: prose → cleanup fires; real command-word merge → cleanup skipped.
pmcb_stale_cleanup_fired() {
    local cmd="$1" tmp input
    tmp=$(mktemp -d)
    git -C "$tmp" init -q
    mkdir -p "$tmp/.claude"
    echo "merge_pr=5" > "$tmp/.claude/.merge-bypass-pending.local"
    touch -t "$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M.%S')" \
        "$tmp/.claude/.merge-bypass-pending.local" 2>/dev/null || true
    input=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))" "$cmd" "$tmp")
    printf '%s' "$input" | bash "$PMCB" >/dev/null 2>&1 || true
    if grep -q 'merge-bypass-stale-cleanup' "$tmp/.claude/bypass-log.jsonl" 2>/dev/null; then echo yes; else echo no; fi
    rm -rf "$tmp"
}
_pmcb_prose=$(pmcb_stale_cleanup_fired 'echo gh pr merge 5')
TOTAL=$((TOTAL + 1))
if [[ "$_pmcb_prose" == "yes" ]]; then
    printf "  PASS  prose 'echo gh pr merge 5' not treated as merge\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  prose treated as merge (stale-cleanup did not fire, got=%s)\n" "$_pmcb_prose"; FAIL=$((FAIL + 1))
fi
_pmcb_real=$(pmcb_stale_cleanup_fired 'command gh pr merge 5')
TOTAL=$((TOTAL + 1))
if [[ "$_pmcb_real" == "no" ]]; then
    printf "  PASS  'command gh pr merge 5' recognized as merge\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  command-prefixed merge not recognized (got=%s)\n" "$_pmcb_real"; FAIL=$((FAIL + 1))
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
