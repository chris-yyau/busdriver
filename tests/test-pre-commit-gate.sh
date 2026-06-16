#!/usr/bin/env bash
# Tests for the pre-commit gate's --amend bypass (item 4 fix from PR #96 grind).
#
# Empirical motivation: PR #96 hit a commitlint footer-max-line-length
# failure on a pushed commit body. Required force-push amend. Litmus
# refused to run on the empty staged diff ("No uncommitted changes
# detected"), but the pre-commit gate still required a litmus pass —
# deadlock until the user manually created .claude/skip-litmus.local.
#
# The fix in pre-commit-gate.sh adds an auto-pass for `git commit --amend`
# when the staged diff is empty (commit-message-only rewrite). The amended
# commit has the same tree as HEAD, which already passed review.
#
# Validates:
#   1. git commit --amend with empty staged → allow (item 4 fix)
#   2. git commit --amend with staged changes → falls through (no marker → block)
#   3. plain git commit (no amend) without marker → block (normal flow)
#   4. git commit --amend with -m before --amend → allow (flag order robustness)
#
# Usage: bash tests/test-pre-commit-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
TOTAL=0

GATE_SCRIPT="hooks/gate-scripts/pre-commit-gate.sh"

# ── Helpers ───────────────────────────────────────────────────────────

# Compose a hook JSON input using python3 to handle escaping safely.
make_hook_input() {
    local cmd="$1"
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash', 'tool_input':{'command':sys.argv[1]}}))
" "$cmd"
}

run_amend_test() {
    # $1 = name, $2 = expected (allow|block), $3 = command, $4 = staged-setup (0=clean, 1=stage-modification)
    local name="$1" expected="$2" cmd="$3" staged_setup="$4"
    TOTAL=$((TOTAL + 1))

    # Setup ephemeral git repo with one initial commit
    local tmp_dir
    tmp_dir=$(mktemp -d)
    (
        cd "$tmp_dir"
        git init -q -b main 2>/dev/null || git init -q
        # Disable any global commit signing / hooks for the test
        git config commit.gpgsign false
        git config user.email "test@test.com"
        git config user.name "Test"
        # Initial commit so HEAD exists
        echo "initial" > file.txt
        git add file.txt
        git commit -qm "initial" --no-verify
        # Optionally stage a modification (simulates non-empty staged diff)
        if [ "$staged_setup" = "1" ]; then
            echo "modified" >> file.txt
            git add file.txt
        fi
    )

    # Compose hook JSON: `cd <tmp_dir> && <cmd>` so the gate resolves
    # REPO_DIR to the temp repo (via the python3 parser's `cd` detection).
    local input
    input=$(make_hook_input "cd $tmp_dir && $cmd")

    local output
    output=$(printf '%s' "$input" | bash "$GATE_SCRIPT" 2>/dev/null)

    local got="allow"
    if echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi

    if [ "$got" = "$expected" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n    output: %s\n" \
            "$name" "$expected" "$got" "$output"
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$tmp_dir"
}

# Compose a hook JSON input that includes the PreToolUse `cwd` field.
make_hook_input_cwd() {
    local cmd="$1" cwd="$2"
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))
" "$cmd" "$cwd"
}

# Like run_amend_test but anchors resolution on the cwd field (no cd-prefix
# parse required) and takes an arbitrary command.
run_cwd_test() {
    # $1=name $2=expected(allow|block) $3=command $4=staged-setup (0=clean,1=stage)
    local name="$1" expected="$2" cmd="$3" staged_setup="$4"
    TOTAL=$((TOTAL + 1))

    local tmp_dir
    tmp_dir=$(mktemp -d)
    (
        cd "$tmp_dir"
        git init -q -b main 2>/dev/null || git init -q
        git config commit.gpgsign false
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
        git add file.txt
        git commit -qm "initial" --no-verify
        if [ "$staged_setup" = "1" ]; then
            echo "modified" >> file.txt
            git add file.txt
        fi
    )

    local input output got="allow"
    input=$(make_hook_input_cwd "$cmd" "$tmp_dir")
    output=$(printf '%s' "$input" | bash "$GATE_SCRIPT" 2>/dev/null)
    if echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi

    if [ "$got" = "$expected" ]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n    output: %s\n" \
            "$name" "$expected" "$got" "$output"
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$tmp_dir"
}

# ── Tests ─────────────────────────────────────────────────────────────

echo "── pre-commit-gate --amend bypass ──────────────────────────"

# 1. The fix: --amend with empty staged diff → allow.
#    This is the case that deadlocked PR #96. After the gate fix, the
#    commit-message-only amend passes without needing a litmus marker.
run_amend_test "allows git commit --amend with empty staged" \
    "allow" "git commit --amend --no-edit" "0"

# 2. --amend WITH staged changes is NOT bypassed — staged content IS
#    new and must be reviewed. With no marker present, the gate blocks.
run_amend_test "blocks git commit --amend with staged changes (no marker)" \
    "block" "git commit --amend" "1"

# 3. Plain git commit (no amend) without marker → block (normal flow,
#    unchanged by the item 4 fix).
run_amend_test "blocks plain git commit without marker" \
    "block" "git commit -m 'msg'" "1"

# 4. Flag-order robustness: --amend after -m still hits the bypass.
#    The python3 parser scans the option portion (tokens before any --
#    pathspec separator) for the --amend flag, so positions like
#    `-m 'msg' --amend` (--amend after -m) all hit.
run_amend_test "allows --amend regardless of flag order (-m before --amend)" \
    "allow" "git commit -m 'rewritten msg' --amend" "0"

# 5. Pathspec scoping: --amend after `--` is a FILENAME, not a flag.
#    The parser must scope detection to option_words (before --) only.
#    Without this scoping, `git commit --allow-empty -- --amend` would
#    falsely set IS_AMEND=1 and could trigger the bypass on a commit
#    that doesn't have --amend semantics. With staged_setup=0 (empty
#    staged) the bypass would auto-pass; we expect block because the
#    correctly-scoped parser sets IS_AMEND=0, falling through to the
#    marker check which blocks (no marker). This locks in the Copilot
#    finding on PR #98 (commit e2ac6f4).
run_amend_test "blocks git commit ... -- --amend (pathspec, not flag)" \
    "block" "git commit --allow-empty -- --amend" "0"

# ── cwd-anchored resolution / substitution handling ──────────────────
echo ""
echo "── pre-commit-gate cwd-anchored resolution ─────────────────"

# THE regression: cd "$(...)" used to yield a junk REPO_DIR that tripped
# `... || exit 0`, silently ALLOWING the commit with no review. cwd anchoring
# now resolves the repo and the missing litmus marker blocks (fail-CLOSED).
run_cwd_test 'blocks cd "$(git rev-parse --show-toplevel)" commit, no marker (was fail-open)' \
    "block" 'cd "$(git rev-parse --show-toplevel)" && git commit -m msg' "1"

# Unresolvable command substitution in the cd target → fail-CLOSED block.
run_cwd_test 'blocks unresolvable cd substitution target' \
    "block" 'cd "$(echo /tmp)" && git commit -m msg' "1"

# cwd is consulted even with no cd prefix: staged change, no marker → block.
run_cwd_test 'blocks plain commit anchored on cwd, no marker' \
    "block" "git commit -m msg" "1"

# Guard against over-blocking: the recognized toplevel idiom resolves, so the
# --amend empty-staged bypass (no marker needed) is reached → allow.
run_cwd_test 'allows --amend empty-staged via toplevel idiom (no over-block)' \
    "allow" 'cd "$(git rev-parse --show-toplevel)" && git commit --amend --no-edit' "0"

# ── Results ───────────────────────────────────────────────────────────

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
