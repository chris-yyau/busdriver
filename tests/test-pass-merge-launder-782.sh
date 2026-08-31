#!/usr/bin/env bash
# Focused regression for #782: empty-diff merge auto-pass / PASS-MERGE must not
# launder an unreviewed parent via `git merge -s ours`, and must not authorize
# any empty-diff MERGE_HEAD commit at PreToolUse.
#
# Usage: bash tests/test-pass-merge-launder-782.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

unset BUSDRIVER_STATE_DIR

PASS=0
FAIL=0
TOTAL=0
GATE_SCRIPT="hooks/gate-scripts/pre-commit-gate.sh"

make_hook_input_cwd() {
    local cmd="$1" cwd="$2"
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'cwd':sys.argv[2]}))
" "$cmd" "$cwd"
}

NV='--''no-verify'

run_case() {
    local name="$1" expected="$2" with_marker="$3"
    TOTAL=$((TOTAL + 1))
    local tmp_dir; tmp_dir=$(mktemp -d)
    (
        cd "$tmp_dir"
        git init -q -b main 2>/dev/null || git init -q
        git config commit.gpgsign false
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "trunk" > file.txt
        git add file.txt
        git commit -qm "trunk" "$NV"
        git checkout -q -b unreviewed
        echo "secret" > evil.txt
        git add evil.txt
        git commit -qm "unreviewed evil" "$NV"
        git checkout -q main
        git merge -s ours --no-commit unreviewed >/dev/null 2>&1
        git diff --cached --quiet HEAD
        mh_path=$(git rev-parse --git-path MERGE_HEAD)
        ! git merge-base --is-ancestor "$(cat "$mh_path")" HEAD
    ) || {
        printf "  FAIL  %s (fixture setup)\n" "$name"
        FAIL=$((FAIL + 1))
        rm -rf "$tmp_dir"
        return 0
    }

    if [[ "$with_marker" = "1" ]]; then
        mkdir -p "$tmp_dir/.claude"
        printf 'PASS-MERGE-1754400000\n' > "$tmp_dir/.claude/litmus-passed.local"
    fi

    local input output got
    input=$(make_hook_input_cwd "git commit -m merge" "$tmp_dir")
    output=$(printf '%s' "$input" | bash "$GATE_SCRIPT" 2>/dev/null || true)
    got="allow"
    echo "$output" | grep -q '"block"' 2>/dev/null && got="block"

    if [[ "$got" = "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n    output: %s\n" \
            "$name" "$expected" "$got" "$output"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$tmp_dir"
}

echo "── PASS-MERGE launder (#782) ──"
run_case "empty-diff -s ours merge without marker blocks" block 0
run_case "empty-diff -s ours merge with PASS-MERGE marker still blocks" block 1

# Even already-reachable MERGE_HEAD + empty staged is refused at PreToolUse
# (PASS-MERGE retired; nested bash -c can still swap parents).
TOTAL=$((TOTAL + 1))
_reach_tmp=$(mktemp -d)
(
    cd "$_reach_tmp"
    git init -q -b main 2>/dev/null || git init -q
    git config commit.gpgsign false
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "a" > file.txt
    git add file.txt
    git commit -qm "a" "$NV"
    echo "b" > file.txt
    git add file.txt
    git commit -qm "b" "$NV"
    git rev-parse 'HEAD~1' > "$(git rev-parse --git-path MERGE_HEAD)"
)
mkdir -p "$_reach_tmp/.claude"
printf 'PASS-MERGE-1754400000\n' > "$_reach_tmp/.claude/litmus-passed.local"
_reach_in=$(make_hook_input_cwd "git commit -m x" "$_reach_tmp")
_reach_out=$(printf '%s' "$_reach_in" | bash "$GATE_SCRIPT" 2>/dev/null || true)
if echo "$_reach_out" | grep -q '"block"' 2>/dev/null; then
    printf "  PASS  empty-diff merge with reachable MERGE_HEAD still blocks\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  reachable empty-diff merge should block (got allow)\n    output: %s\n" "$_reach_out"
    FAIL=$((FAIL + 1))
fi
rm -rf "$_reach_tmp"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
