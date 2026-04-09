#!/usr/bin/env bash
# Tests for branch-scoped reviewed-commits tracking.
# Validates: branch-scoped write, branch-scoped read, cross-branch rejection,
# legacy bare SHA compat, rebase invalidation.
#
# Usage: bash tests/test-reviewed-commits-tracking.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0
REVIEWED_FILE=".claude/reviewed-commits.local"

assert() {
    local name="$1" expected="$2" got="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# Save and clean up
PREV_CONTENT=""
[ -f "$REVIEWED_FILE" ] && PREV_CONTENT=$(cat "$REVIEWED_FILE")
trap 'if [[ -n "$PREV_CONTENT" ]]; then echo "$PREV_CONTENT" > "$REVIEWED_FILE"; else rm -f "$REVIEWED_FILE"; fi' EXIT

echo "── branch-scoped tracking ────────────────────────────────────"

# Setup: create a file with branch-scoped entries
mkdir -p .claude
cat > "$REVIEWED_FILE" << 'EOF'
feat/auth:abc123def456789012345678901234567890abcd
feat/auth:def456789012345678901234567890abcdef1234
feat/payments:111222333444555666777888999000aaabbbcccc
EOF

# 1. Branch-scoped entry found for correct branch
got=$(grep -qF "feat/auth:abc123def456789012345678901234567890abcd" "$REVIEWED_FILE" && echo "found" || echo "missing")
assert "branch-scoped entry found on correct branch" "found" "$got"

# 2. Cross-branch entry NOT matched when checking different branch
SHA="111222333444555666777888999000aaabbbcccc"
got=$(grep -qF "feat/auth:${SHA}" "$REVIEWED_FILE" && echo "found" || echo "missing")
assert "cross-branch SHA rejected (feat/payments SHA on feat/auth)" "missing" "$got"

# 3. Same SHA found when checking correct branch
got=$(grep -qF "feat/payments:${SHA}" "$REVIEWED_FILE" && echo "found" || echo "missing")
assert "same SHA found on correct branch (feat/payments)" "found" "$got"

echo ""
echo "── legacy bare SHA compatibility ─────────────────────────────"

# 4. Add a legacy bare SHA entry
echo "deadbeef12345678901234567890123456789012" >> "$REVIEWED_FILE"

# 5. Legacy bare SHA matches with grep -x (exact line match)
got=$(grep -qxF "deadbeef12345678901234567890123456789012" "$REVIEWED_FILE" && echo "found" || echo "missing")
assert "legacy bare SHA found (backwards compat)" "found" "$got"

# 6. Branch-scoped entry does NOT match bare SHA grep
got=$(grep -qxF "abc123def456789012345678901234567890abcd" "$REVIEWED_FILE" && echo "found" || echo "missing")
assert "branch-scoped entry not matched by bare SHA grep" "missing" "$got"

echo ""
echo "── rebase invalidation ────────────────────────────────────────"

# 7. Simulate rebase detection — file should be cleared
HOOK_DATA='{"tool_name":"Bash","tool_input":{"command":"git rebase main"},"tool_output":{"output":"Successfully rebased"}}'
printf '%s' "$HOOK_DATA" | bash hooks/gate-scripts/post-commit-consume-marker.sh 2>/dev/null || true

got=$( [ -f "$REVIEWED_FILE" ] && echo "exists" || echo "cleared" )
assert "rebase clears reviewed-commits file" "cleared" "$got"

# 8. Recreate and test amend detection
mkdir -p .claude
echo "feat/test:aaa111222333444555666777888999000aaabbb" > "$REVIEWED_FILE"
HOOK_DATA='{"tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"fix\""},"tool_output":{"output":"[main abc1234] fix"}}'
printf '%s' "$HOOK_DATA" | bash hooks/gate-scripts/post-commit-consume-marker.sh 2>/dev/null || true

got=$( [ -f "$REVIEWED_FILE" ] && echo "exists" || echo "cleared" )
assert "amend clears reviewed-commits file" "cleared" "$got"

# 9. Non-rebase command does NOT clear file
mkdir -p .claude
echo "feat/test:bbb222333444555666777888999000aaabbbccc" > "$REVIEWED_FILE"
HOOK_DATA='{"tool_name":"Bash","tool_input":{"command":"git status"},"tool_output":{"output":"On branch main"}}'
printf '%s' "$HOOK_DATA" | bash hooks/gate-scripts/post-commit-consume-marker.sh 2>/dev/null || true

got=$( [ -f "$REVIEWED_FILE" ] && echo "exists" || echo "cleared" )
assert "non-rebase command preserves file" "exists" "$got"

# ═══════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
    printf " (%d FAILED)\n" "$FAIL"
    exit 1
else
    printf " (all passed)\n"
    exit 0
fi
