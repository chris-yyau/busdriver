#!/usr/bin/env bash
# Adversarial tests for gate scripts — validates enforcement under edge cases.
# Tests: freeze-guard (prefix escape, MultiEdit, infra bypass) and careful-guard
# (escaped quotes, multiline, safe exceptions, Python fallback).
#
# Usage: bash tests/test-gate-adversarial.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1" expected="$2" script="$3" input="$4"
    TOTAL=$((TOTAL + 1))
    local output exit_code
    output=$(printf '%s' "$input" | bash "$script" 2>/dev/null) && exit_code=0 || exit_code=$?

    # Detect script crashes: non-zero exit with no structured output = broken guard
    local got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    elif echo "$output" | grep -q '"ask"' 2>/dev/null; then
        got="ask"
    fi

    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# FREEZE-GUARD TESTS
# ═══════════════════════════════════════════════════════════════════════
FREEZE_SCRIPT="hooks/gate-scripts/freeze-guard.sh"
FREEZE_FILE=".claude/freeze-scope.local"

echo "── freeze-guard ──────────────────────────────────────────────"

# Setup: save any active freeze scope, create test scope
mkdir -p .claude
PREV_FREEZE=""
[ -f "$FREEZE_FILE" ] && PREV_FREEZE=$(cat "$FREEZE_FILE")
trap 'if [[ -n "$PREV_FREEZE" ]]; then echo "$PREV_FREEZE" > "$FREEZE_FILE"; else rm -f "$FREEZE_FILE"; fi' EXIT
echo "src/auth" > "$FREEZE_FILE"

# 1. File inside scope → allow
run_test "file inside scope (src/auth/login.js)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/auth/login.js"}}'

# 2. File exactly matching scope → allow
run_test "file exactly matching scope (src/auth)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/auth"}}'

# 3. PREFIX ESCAPE: src/authx should be blocked (not src/auth prefix)
run_test "prefix escape blocked (src/authx/exploit.js)" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/authx/exploit.js"}}'

# 4. File outside scope → block
run_test "file outside scope (src/payments/stripe.js)" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/payments/stripe.js"}}'

# 5. Edit tool → should also be gated
run_test "Edit tool gated" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/payments/stripe.js"}}'

# 6. MultiEdit tool → should now be gated (was a gap)
run_test "MultiEdit tool gated" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"src/payments/stripe.js"}}'

# 7. MultiEdit inside scope → allow
run_test "MultiEdit inside scope allowed" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"src/auth/middleware.js"}}'

# 8. Infrastructure paths always allowed
run_test "infra bypass (.claude/ path)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":".claude/notes/debug.md"}}'

run_test "infra bypass (CLAUDE.md)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"CLAUDE.md"}}'

run_test "infra bypass (docs/plans/)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"docs/plans/debug-plan.md"}}'

run_test "infra bypass (docs/specs/)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"docs/specs/2026-07-17-x-design.md"}}'

# `docs` must START a path segment — a bare *docs/plans/* glob also exempts
# notdocs/, which is not a docs dir. Nested (monorepo) docs dirs stay exempt.
run_test "infra bypass NOT granted to notdocs/plans/" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"notdocs/plans/impl.sh"}}'

run_test "infra bypass NOT granted to notdocs/specs/" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"notdocs/specs/runtime.sh"}}'

run_test "infra bypass (nested monorepo docs/specs/)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"packages/foo/docs/specs/x-design.md"}}'

# Traversal: matches the docs glob raw, resolves to src/impl.sh. The exemption is
# checked post-normalization so the real target decides, not the prefix.
run_test "infra bypass NOT granted via docs/specs/../.. traversal" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"docs/specs/../../src/payments/impl.sh"}}'

run_test "infra bypass NOT granted via docs/plans/../.. traversal" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"docs/plans/../../src/payments/impl.sh"}}'

# The mirror case must still work: traversal that genuinely lands in docs/specs/.
run_test "infra bypass (traversal resolving INTO docs/specs/)" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/../docs/specs/x-design.md"}}'

# NOTE — known residual, deliberately NOT asserted: a symlinked docs/specs -> src
# reads as a docs path here. It is shared with the pre-existing docs/plans and
# docs/reviews arms (not new to docs/specs), unreachable via the gated toolset (`ln`
# is FILE_MOD), and cannot be closed by resolving physically without diverging from
# the LEXICAL detector and tripping the `*.claude/*` fail-open. See the UPGRADE
# receipt on the docs/ arms in freeze-guard.sh — it closes with repo-relative
# anchoring, in its own change.

# 9. Non-Write/Edit tools pass through
run_test "Read tool not gated" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Read","tool_input":{"file_path":"src/payments/stripe.js"}}'

run_test "Bash tool not gated" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'

# 10. Path traversal via ../ should be blocked
run_test "path traversal blocked (src/auth/../payments)" "block" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/auth/../payments/stripe.js"}}'

# 11. No freeze file → all allowed
rm -f "$FREEZE_FILE"
run_test "no freeze file → allow all" "allow" "$FREEZE_SCRIPT" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/payments/stripe.js"}}'

# ═══════════════════════════════════════════════════════════════════════
# CAREFUL-GUARD TESTS
# ═══════════════════════════════════════════════════════════════════════
CAREFUL_SCRIPT="hooks/gate-scripts/careful-guard.sh"

echo ""
echo "── careful-guard ─────────────────────────────────────────────"

# 1. Safe command → allow
run_test "safe command (ls)" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

# 2. rm -rf detected → ask
run_test "rm -rf detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/important"}}'

# 3. rm -rf of build artifacts → allow (safe exception)
run_test "rm -rf node_modules (safe)" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"}}'

run_test "rm -rf dist (safe)" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -rf dist"}}'

run_test "rm -rf .next (safe)" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"rm -rf .next"}}'

# 4. git force push → ask
run_test "git push --force detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'

# 5. git push --force-with-lease → allow (safe alternative)
run_test "git push --force-with-lease (safe)" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin main"}}'

# 6. git reset --hard → ask
run_test "git reset --hard detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'

# 7. DROP TABLE → ask
run_test "DROP TABLE detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"psql -c \"DROP TABLE users\""}}'

# 8. TRUNCATE → ask
run_test "TRUNCATE detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"psql -c \"TRUNCATE sessions\""}}'

# 9. git checkout . → ask
run_test "git checkout . detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'

# 10. git clean -f → ask
run_test "git clean -fd detected" "ask" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}'

# 11. Empty command → allow
run_test "empty command" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash","tool_input":{"command":""}}'

# 12. No tool_input → allow
run_test "no tool_input" "allow" "$CAREFUL_SCRIPT" \
    '{"tool_name":"Bash"}'

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
