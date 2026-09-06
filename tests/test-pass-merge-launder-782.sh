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
    # NOT `( ... ) || { ... }`: a subshell used as the left operand of `||` runs
    # with errexit suppressed, so a failed commit/merge or a non-empty staged
    # diff would slip through and the gate's block for some UNRELATED reason
    # would score as a passing regression. Capture the status separately so
    # `set -e` stays live inside the fixture.
    local fixture_rc=0
    set +e
    (
        set -e
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
        mh_oid=$(cat "$mh_path")
        # Exactly 1 means "not an ancestor" — the state this fixture needs.
        # 0 is an ancestor and >1 is a git error; both are fixture failures, so
        # do not use `!`, which would accept the error as success.
        anc_rc=0
        git merge-base --is-ancestor "$mh_oid" HEAD || anc_rc=$?
        [[ "$anc_rc" -eq 1 ]]
    )
    fixture_rc=$?
    set -e
    if [[ "$fixture_rc" -ne 0 ]]; then
        printf "  FAIL  %s (fixture setup)\n" "$name"
        FAIL=$((FAIL + 1))
        rm -rf "$tmp_dir"
        return 0
    fi

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

# ── The isolating case (cubic P2, PR #841) ────────────────────────────
# The three cases above all block for reasons OTHER than the #782 empty-diff
# block: case 1 has no marker (Gate 2 rejects that), cases 2-3 carry a
# PASS-MERGE marker (the retirement arm rejects that). Stripping the #782
# block leaves all three green — verified by mutation — so none of them pins
# the behavior this issue is about.
#
# This case carries a marker that WOULD otherwise authorize the commit: the
# bare sha256 of the (empty) staged diff, computed exactly as the gate
# computes it. Without the #782 block the marker matches at the bare-hash arm
# and the gate allows. So a block here can only come from the empty-diff
# MERGE_HEAD logic — which is the property "NO marker can authorize an empty
# staged merge".
TOTAL=$((TOTAL + 1))
_iso_tmp=$(mktemp -d)
(
    set -e
    cd "$_iso_tmp"
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
)
mkdir -p "$_iso_tmp/.claude"
# Same pipeline as pre-commit-gate.sh's STAGED_HASH (empty diff => sha256 of
# empty input). Derived, not hardcoded, so it tracks any change to that shape.
if command -v sha256sum >/dev/null 2>&1; then _iso_hash_cmd=(sha256sum); else _iso_hash_cmd=(shasum -a 256); fi
_iso_hash=$(git -C "$_iso_tmp" --no-replace-objects -c color.ui=never -c core.quotePath=false \
    diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none 2>/dev/null \
    | "${_iso_hash_cmd[@]}" | cut -d' ' -f1)
printf '%s\n' "$_iso_hash" > "$_iso_tmp/.claude/litmus-passed.local"
_iso_in=$(make_hook_input_cwd "git commit -m merge" "$_iso_tmp")
_iso_out=$(printf '%s' "$_iso_in" | bash "$GATE_SCRIPT" 2>/dev/null || true)
if echo "$_iso_out" | grep -q '"block"' 2>/dev/null; then
    printf "  PASS  empty-diff merge blocks even with a VALID diff-bound hash marker\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL  a valid-hash marker authorized an empty-diff merge (got allow)\n    output: %s\n" "$_iso_out"
    FAIL=$((FAIL + 1))
fi
rm -rf "$_iso_tmp"

# ── Submodule-blind emptiness probe (Codex, PR #841) ──────────────────
# `diff.ignoreSubmodules=all` is repo-controlled and makes a staged gitlink
# change read as NO change (measured: rc 0). With the emptiness probe
# unpinned, a real submodule-only merge resolution was misread as an
# empty-diff merge — refused, and its valid marker deleted. Pin the same
# flags the marker-hash command uses so both agree what "empty" means.
#
# A fixture failure is a FAIL, never a skip: a skip here would silently
# retire the case, and the sanity assertions below are the only thing
# proving it still tests what it claims.
TOTAL=$((TOTAL + 1))
_sm_tmp=$(mktemp -d)
_sm_rc=0
set +e
(
    set -e
    cd "$_sm_tmp"
    mkdir -p sub main
    cd sub
    git init -q -b main 2>/dev/null || git init -q
    git config commit.gpgsign false; git config user.email "t@t"; git config user.name "T"
    echo v1 > f; git add f; git commit -qm v1 "$NV"
    cd ../main
    git init -q -b main 2>/dev/null || git init -q
    git config commit.gpgsign false; git config user.email "t@t"; git config user.name "T"
    echo base > base.txt; git add base.txt; git commit -qm base "$NV"
    git -c protocol.file.allow=always submodule add -q ../sub sub
    git commit -qm "add sub" "$NV"
    cd ../sub; echo v2 > f; git commit -qam v2 "$NV"
    sub_oid=$(git rev-parse HEAD)
    cd ../main/sub; git fetch -q origin 2>/dev/null || true
    git checkout -q "$sub_oid"
    cd ..
    # A staged gitlink change plus a MERGE_HEAD: a real, non-empty resolution.
    git add sub
    mh_path=$(git rev-parse --git-path MERGE_HEAD)
    head_oid=$(git rev-parse HEAD)
    printf '%s\n' "$head_oid" > "$mh_path"
    # Repo-controlled config that hides the gitlink from an unpinned probe.
    git config diff.ignoreSubmodules all
    # Sanity: the unpinned probe must read EMPTY (rc 0) and the pinned probe
    # must read NON-EMPTY (rc exactly 1). Check rc explicitly — `!` would
    # accept a git ERROR (rc > 1) as evidence of a non-empty diff and leave
    # the case asserting nothing.
    git diff --cached --quiet HEAD
    pinned_rc=0
    git diff --cached --quiet --no-ext-diff --no-textconv --ignore-submodules=none HEAD \
        || pinned_rc=$?
    [[ "$pinned_rc" -eq 1 ]]
)
_sm_rc=$?
set -e
if [[ "$_sm_rc" -ne 0 ]]; then
    printf "  FAIL  submodule-blind probe (fixture setup)\n"
    FAIL=$((FAIL + 1))
else
    _sm_in=$(make_hook_input_cwd "git commit -m merge" "$_sm_tmp/main")
    _sm_out=$(printf '%s' "$_sm_in" | bash "$GATE_SCRIPT" 2>/dev/null)
    _sm_gate_rc=$?
    # Assert POSITIVELY. "The refusal string is absent" would also be true of a
    # crashed hook that printed nothing, which is why the gate rc and the
    # expected block reason are both checked: a submodule-only resolution is
    # NOT empty, so the #782 arm must not fire and the commit must fall
    # through to the ordinary review gate (no marker here, so it blocks there).
    if [[ "$_sm_gate_rc" -ne 0 ]]; then
        printf "  FAIL  gate exited %s on a submodule-only resolution\n    output: %s\n" "$_sm_gate_rc" "$_sm_out"
        FAIL=$((FAIL + 1))
    elif echo "$_sm_out" | grep -q 'Empty-diff merge commit refused' 2>/dev/null; then
        printf "  FAIL  submodule-only resolution misread as an empty-diff merge\n    output: %s\n" "$_sm_out"
        FAIL=$((FAIL + 1))
    elif echo "$_sm_out" | grep -q 'Code review required before committing' 2>/dev/null; then
        printf "  PASS  submodule-only resolution reaches the normal review gate\n"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  unexpected gate decision on a submodule-only resolution\n    output: %s\n" "$_sm_out"
        FAIL=$((FAIL + 1))
    fi
fi
rm -rf "$_sm_tmp"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
