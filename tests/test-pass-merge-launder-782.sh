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
# NOT a bare `( ... )`: with top-level `set -e` a failing fixture would abort the
# whole suite with no diagnostic and leak $_iso_tmp, losing the clean
# "FAIL (fixture setup)" attribution run_case already gives. Capture the status.
_iso_rc=0
set +e
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
_iso_rc=$?
set -e
if [[ "$_iso_rc" -ne 0 ]]; then
    printf "  FAIL  isolating valid-hash marker case (fixture setup)\n"
    FAIL=$((FAIL + 1))
    rm -rf "$_iso_tmp"
else
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
if echo "$_iso_out" | grep -q 'Empty-diff merge commit refused' 2>/dev/null; then
    # The SPECIFIC refusal, not merely `"block"` — the ERR trap emits a
    # precautionary block too, so a crashed hook would otherwise score a PASS.
    printf "  PASS  empty-diff merge blocks even with a VALID diff-bound hash marker\n"
    PASS=$((PASS + 1))
elif echo "$_iso_out" | grep -q '"block"' 2>/dev/null; then
    printf "  FAIL  blocked, but not by the empty-diff check (hook error?)\n    output: %s\n" "$_iso_out"
    FAIL=$((FAIL + 1))
else
    printf "  FAIL  a valid-hash marker authorized an empty-diff merge (got allow)\n    output: %s\n" "$_iso_out"
    FAIL=$((FAIL + 1))
fi
rm -rf "$_iso_tmp"
fi

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

# ── Replacement refs cannot launder (Codex, PR #841) ──────────────────
# refs/replace/* is repo-controlled. A replacement mapping HEAD to a commit
# with a DIFFERENT tree makes an actually-empty staged merge read as
# non-empty (measured: rc 1), which would skip the #782 arm and let the
# marker holding the TRUE empty-diff hash authorize the merge.
#
# The gate already exports GIT_NO_REPLACE_OBJECTS=1 process-wide (#576), so
# this holds today; the probes carry --no-replace-objects as well. Pin the
# END-TO-END property rather than either mechanism, so it stays pinned no
# matter which one a future change touches.
TOTAL=$((TOTAL + 1))
_rp_tmp=$(mktemp -d)
_rp_rc=0
set +e
(
    set -e
    cd "$_rp_tmp"
    git init -q -b main 2>/dev/null || git init -q
    git config commit.gpgsign false; git config user.email "t@t"; git config user.name "T"
    echo trunk > file.txt; git add file.txt; git commit -qm trunk "$NV"
    echo other > file.txt; git add file.txt; git commit -qm decoy "$NV"
    decoy=$(git rev-parse HEAD)
    git reset -q --hard 'HEAD~1'
    git checkout -q -b unreviewed
    echo secret > evil.txt; git add evil.txt; git commit -qm evil "$NV"
    git checkout -q main
    git merge -s ours --no-commit unreviewed >/dev/null 2>&1
    git diff --cached --quiet HEAD          # genuinely empty before the replace
    head_now=$(git rev-parse HEAD)
    git replace "$head_now" "$decoy" >/dev/null 2>&1
    # Sanity: an UNGUARDED probe must now read non-empty (rc exactly 1), or
    # this case is not exercising the laundering path it describes.
    unguarded_rc=0
    git diff --cached --quiet HEAD || unguarded_rc=$?
    [[ "$unguarded_rc" -eq 1 ]]
)
_rp_rc=$?
set -e
if [[ "$_rp_rc" -ne 0 ]]; then
    printf "  FAIL  replace-ref launder (fixture setup)\n"
    FAIL=$((FAIL + 1))
else
    mkdir -p "$_rp_tmp/.claude"
    if command -v sha256sum >/dev/null 2>&1; then _rp_hash_cmd=(sha256sum); else _rp_hash_cmd=(shasum -a 256); fi
    _rp_hash=$(git -C "$_rp_tmp" --no-replace-objects -c color.ui=never -c core.quotePath=false \
        diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none 2>/dev/null \
        | "${_rp_hash_cmd[@]}" | cut -d' ' -f1)
    printf '%s\n' "$_rp_hash" > "$_rp_tmp/.claude/litmus-passed.local"
    _rp_in=$(make_hook_input_cwd "git commit -m merge" "$_rp_tmp")
    # `_rp_out=$(...)` on its own aborts the whole suite under `set -e` when the
    # gate exits non-zero -- taking the _rp_gate_rc branch below with it. Capture
    # the status on the assignment itself so that branch stays reachable (a plain
    # `|| true` would instead discard the very rc it exists to report).
    _rp_gate_rc=0
    _rp_out=$(printf '%s' "$_rp_in" | bash "$GATE_SCRIPT" 2>/dev/null) || _rp_gate_rc=$?
    if [[ "$_rp_gate_rc" -ne 0 ]]; then
        printf "  FAIL  gate exited %s on the replace-ref fixture\n    output: %s\n" "$_rp_gate_rc" "$_rp_out"
        FAIL=$((FAIL + 1))
    elif echo "$_rp_out" | grep -q 'Empty-diff merge commit refused' 2>/dev/null; then
        # The SPECIFIC refusal, not merely `"block"`: the gate's ERR trap also
        # emits a precautionary block and exits 0, so a hook that crashed before
        # ever reaching the empty-diff check would otherwise score as a PASS.
        printf "  PASS  a planted refs/replace cannot launder an empty-diff merge\n"
        PASS=$((PASS + 1))
    elif echo "$_rp_out" | grep -q '"block"' 2>/dev/null; then
        printf "  FAIL  blocked, but not by the empty-diff check (hook error?)\n    output: %s\n" "$_rp_out"
        FAIL=$((FAIL + 1))
    else
        printf "  FAIL  refs/replace laundered an empty-diff merge (got allow)\n    output: %s\n" "$_rp_out"
        FAIL=$((FAIL + 1))
    fi
fi
rm -rf "$_rp_tmp"

# ── Amend auto-pass must not outrank the merge refusal (cubic P0, PR #841) ──
# `git commit --amend --no-edit || git commit -m merge` during an empty-diff
# merge used to launder the unreviewed parent: the amend auto-pass ran FIRST
# and returned allow, then the amend failed at execution time (git refuses an
# amend while MERGE_HEAD exists) and the `||` fallback committed the merge with
# no gate in front of it. The auto-pass now excludes merge state, so this
# command falls through to the empty-diff refusal.
#
# Asserted on the SPECIFIC refusal string: a bare `"block"` would also be
# satisfied by the ERR trap, scoring a crashed hook as a PASS.
TOTAL=$((TOTAL + 1))
_am_tmp=$(mktemp -d)
_am_rc=0
set +e
(
    set -e
    cd "$_am_tmp"
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
    # The two preconditions the case depends on: a merge really is in progress
    # and the staged diff really is empty. Without both, the case proves nothing.
    git rev-parse --verify MERGE_HEAD >/dev/null 2>&1
    git diff --cached --quiet HEAD
)
_am_rc=$?
set -e
if [[ "$_am_rc" -ne 0 ]]; then
    printf "  FAIL  amend-during-merge case (fixture setup)\n"
    FAIL=$((FAIL + 1))
    rm -rf "$_am_tmp"
else
    _am_in=$(make_hook_input_cwd "git commit --amend --no-edit || git commit -m merge" "$_am_tmp")
    _am_out=$(printf '%s' "$_am_in" | bash "$GATE_SCRIPT" 2>/dev/null || true)
    if echo "$_am_out" | grep -q 'Empty-diff merge commit refused' 2>/dev/null; then
        printf "  PASS  amend auto-pass does not outrank the empty-diff merge refusal\n"
        PASS=$((PASS + 1))
    elif echo "$_am_out" | grep -q '"block"' 2>/dev/null; then
        printf "  FAIL  blocked, but not by the empty-diff check (hook error?)\n    output: %s\n" "$_am_out"
        FAIL=$((FAIL + 1))
    else
        printf "  FAIL  amend auto-pass laundered an empty-diff merge (got allow)\n    output: %s\n" "$_am_out"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$_am_tmp"
fi

# ── A ref NAMED MERGE_HEAD is not a merge (cubic P2 / Codex P2, PR #841) ──
# `git rev-parse MERGE_HEAD` is revision-name resolution: with an ordinary
# branch named `MERGE_HEAD` and NO merge running it exits 0. Both merge-state
# checks then misfire in the SAFE-LOOKING direction, which is why this needs a
# test rather than a comment: an ordinary empty commit gets refused as a merge
# (Codex reproduced exactly this with a valid marker), and the message-only
# amend auto-pass is disabled outright — the #96 deadlock it exists to prevent.
#
# Asserted NEGATIVELY on the refusal string, so the case fails if the gate ever
# starts treating a same-named ref as merge state again. The gate legitimately
# blocks here for the ORDINARY reason (no valid review marker for this repo);
# what must not appear is the #782 merge refusal.
TOTAL=$((TOTAL + 1))
_nm_tmp=$(mktemp -d)
_nm_rc=0
set +e
(
    set -e
    cd "$_nm_tmp"
    git init -q -b main 2>/dev/null || git init -q
    git config commit.gpgsign false
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "trunk" > file.txt
    git add file.txt
    git commit -qm "trunk" "$NV"
    # An ordinary branch that merely SHARES the pseudoref's name.
    git branch MERGE_HEAD
    # The preconditions: the NAME resolves, the pseudoref file does NOT exist.
    git rev-parse MERGE_HEAD >/dev/null 2>&1
    [ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ]
)
_nm_rc=$?
set -e
if [[ "$_nm_rc" -ne 0 ]]; then
    printf "  FAIL  MERGE_HEAD-named-ref case (fixture setup)\n"
    FAIL=$((FAIL + 1))
    rm -rf "$_nm_tmp"
else
    _nm_in=$(make_hook_input_cwd "git commit --allow-empty -m ordinary" "$_nm_tmp")
    _nm_out=$(printf '%s' "$_nm_in" | bash "$GATE_SCRIPT" 2>/dev/null || true)
    if echo "$_nm_out" | grep -q 'Empty-diff merge commit refused' 2>/dev/null; then
        printf "  FAIL  a ref merely NAMED MERGE_HEAD was misread as an active merge\n    output: %s\n" "$_nm_out"
        FAIL=$((FAIL + 1))
    elif ! echo "$_nm_out" | grep -q 'Code review required before committing' 2>/dev/null; then
        # Absence of the #782 string is not on its own evidence of anything: a
        # hook that crashed, or was never reached, prints nothing and would sail
        # through a purely negative assertion. Pin the ORDINARY refusal too, so
        # the case only passes when the gate actually ran and took the normal
        # unreviewed-changes path.
        printf "  FAIL  gate did not reach the ordinary review path (crashed or silent)\n    output: %s\n" "$_nm_out"
        FAIL=$((FAIL + 1))
    else
        printf "  PASS  a ref named MERGE_HEAD is not mistaken for merge state\n"
        PASS=$((PASS + 1))
    fi
    rm -rf "$_nm_tmp"
fi

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
if [[ "$FAIL" -gt 0 ]]; then
    echo "   $FAIL FAILED"
    exit 1
fi
echo "   All passed."
exit 0
