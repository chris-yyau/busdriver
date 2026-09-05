#!/bin/bash
# Regression for #622 slice 1 — conflict-free git merge requires litmus marker.
#
#   1. pre-merge-commit blocks a clean merge without a marker.
#   2. pre-merge-commit allows the same merge when BUILTIN-<staged-hash> is present.
#   3. Attacker-controlled PATH with shim sha256sum cannot authorize a merge.
#   4. merge --no-commit + git commit requires marker via merge-pre-commit-gate.
#   5. Fast-forward merge does not consume a stale marker (no pending claim).
#   6. GIT_EXTERNAL_DIFF constant output cannot authorize a merge.
#   7. Pre-created pending tmp blocks merge (claim write failure).
#   8. Abort then an ordinary successor is not locked by the stale arm.
#   9. Spoofed GIT_REFLOG_ACTION does not prevent marker consumption.
#  10. Hostile BASH_ENV cannot bypass merge validation.
#  11. Fast-forward onto a published merge tip keeps HEAD (with RT).
#  12. commit-tree + update-ref of an unpublished merge tip is refused.
#  13. A tag tip alone cannot witness merge publication onto a branch.
#  14. A symbolic head aliasing a tag cannot witness merge publication.
#  15. A one-parent tip cannot smuggle an unpublished merge into history.
#  16. New-branch (zero old-oid) cannot publish smuggled merge ancestry.
#  17. Stale MERGE_HEAD cannot authorize a one-parent smuggle tip.
#  18. First root commit (zero OLD, zero parents) is allowed.
#  19. Root amend (zero-parent replace of a root tip) is allowed.
#  20. Fast-forward from a deeper ancestor onto a witnessed merge tip is allowed.
#  21. Multi-commit linear fast-forward (no merges) is allowed.
#  22. Orphan spent marker naming the live tip is retired, not a permanent block.
#  23. Orphan spent marker naming a NON-tip commit still blocks, and does not
#      consume an unrelated marker (the decision must not key on marker presence).
#  24. A CR inside a commit header is unparseable framing and is refused BY THE GATE.
#  25. A merge touching a non-ASCII path authorizes (validator/writer hash parity).
#  26. Backward ref moves (reset --hard, incl. onto the root commit) are allowed.
#  27. A divergent sideways move is still refused.
#  28. PASS-MERGE authorizes an empty-resolution merge and is consumed once; the
#      same token against a real resolution is refused and left in place.
#  29. Retiring an armed claim keeps a marker belonging to a LATER review.
#
# Usage: bash tests/test-merge-commit-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."
unset BUSDRIVER_STATE_DIR
# Every fixture below runs plain `git` against a temp repo, and `-C <dir>` does NOT
# override the repository-selecting environment. An inherited GIT_INDEX_FILE makes
# `git -C "$fixture" add` write ANOTHER repository's index; GIT_DIR and GIT_WORK_TREE
# redirect the operation outright; the object-directory pair sends new objects
# somewhere else and can leave the fixture referencing objects its own cleanup then
# deletes. That is not hypothetical here -- an unisolated fixture in this branch's
# history installed hooks machine-wide and took the pristine suite from 66/66 to
# 26/66. A FUNCTION, not a bare `unset`, so the guard itself is testable below.
_neutralize_git_env() {
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
          GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    # ...and the COMMAND-LEVEL config injectors, which the six above do not cover.
    # `GIT_CONFIG_COUNT` + `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` (and the older
    # `GIT_CONFIG_PARAMETERS`) inject settings into EVERY git invocation at a
    # precedence above the repository file, so an inherited core.hooksPath sends a
    # fixture install into an external hooks directory that the fixture never names
    # -- measured, not assumed. Unsetting COUNT is what disables the indexed pairs:
    # git reads KEY_n/VALUE_n only up to COUNT, so the pairs need no enumeration.
    unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
}
_neutralize_git_env

REPO_ROOT="$PWD"
GATE_SCRIPT="hooks/gate-scripts/pre-merge-commit-gate.sh"
POST_MERGE="hooks/gate-scripts/post-merge-consume-marker.sh"
MERGE_PRE_COMMIT="hooks/gate-scripts/merge-pre-commit-gate.sh"
MERGE_PREPARE_COMMIT_MSG="hooks/gate-scripts/merge-prepare-commit-msg-gate.sh"
MERGE_REFERENCE_TRANSACTION="hooks/gate-scripts/merge-reference-transaction-gate.sh"
MERGE_POST_COMMIT="hooks/gate-scripts/merge-post-commit-consume.sh"
HASH_HELPER="scripts/lib/staged-diff-hash.sh"

PASS=0
FAIL=0
TOTAL=0

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

# Mint the way litmus MINTS, not the way the validator reads: spelled with the
# canonical expression (#576) so a validator that drifts away from the writers
# fails these fixtures instead of silently agreeing with itself.
staged_hash() {
    git -C "$1" --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none \
        | bash -c "source '$REPO_ROOT/$HASH_HELPER'; hash_stdin"
}

install_hook() {
    local repo="$1"
    local hooks_dir="$2"
    mkdir -p "$hooks_dir"
    ln -sf "$REPO_ROOT/$GATE_SCRIPT" "$hooks_dir/pre-merge-commit"
    ln -sf "$REPO_ROOT/$POST_MERGE" "$hooks_dir/post-merge"
    ln -sf "$REPO_ROOT/$MERGE_PRE_COMMIT" "$hooks_dir/pre-commit"
    ln -sf "$REPO_ROOT/$MERGE_PREPARE_COMMIT_MSG" "$hooks_dir/prepare-commit-msg"
    ln -sf "$REPO_ROOT/$MERGE_REFERENCE_TRANSACTION" "$hooks_dir/reference-transaction"
    ln -sf "$REPO_ROOT/$MERGE_POST_COMMIT" "$hooks_dir/post-commit"
    chmod +x "$hooks_dir"/*
    git -C "$repo" config core.hooksPath "$hooks_dir"
}

setup_repo() {
    local repo="$1"
    git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
    git -C "$repo" config user.email t@t.dev
    git -C "$repo" config user.name tester
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config tag.gpgsign false
    echo base >"$repo/base.txt"
    git -C "$repo" add base.txt
    git -C "$repo" commit -q -m base --no-verify
    git -C "$repo" checkout -q -b topic
    echo topic >"$repo/topic.txt"
    git -C "$repo" add topic.txt
    git -C "$repo" commit -q -m topic --no-verify
    git -C "$repo" checkout -q main
    echo mainline >"$repo/mainline.txt"
    git -C "$repo" add mainline.txt
    git -C "$repo" commit -q -m mainline --no-verify
}

TMP_BLOCK=$(mktemp -d)
TMP_ALLOW=$(mktemp -d)
TMP_PATH=$(mktemp -d)
TMP_NOCOMMIT=$(mktemp -d)
TMP_FF=$(mktemp -d)
TMP_EXTDIFF=$(mktemp -d)
TMP_CLAIM=$(mktemp -d)
TMP_ABORT=$(mktemp -d)
TMP_SPOOF=$(mktemp -d)
TMP_BASHENV=$(mktemp -d)
TMP_SKIP_AGE=$(mktemp -d)
TMP_SKNONE_STALE=$(mktemp -d)
TMP_SKNONE_CONTENT=$(mktemp -d)
TMP_SKNONE_OVERFLOW=$(mktemp -d)
TMP_SKNONE_FUTURE=$(mktemp -d)
TMP_SKNONE_LONG=$(mktemp -d)
TMP_SKNONE_BOUND=$(mktemp -d)
TMP_REPO_MARKER=$(mktemp -d)
TMP_FF_MERGE=$(mktemp -d)
TMP_CTREE=$(mktemp -d)
TMP_TAG_WITNESS=$(mktemp -d)
TMP_SYM_WITNESS=$(mktemp -d)
TMP_HIDDEN_MERGE=$(mktemp -d)
TMP_NEW_BRANCH=$(mktemp -d)
TMP_STALE_MH=$(mktemp -d)
TMP_ROOT_CREATE=$(mktemp -d)
TMP_ROOT_AMEND=$(mktemp -d)
TMP_FF_DEEP=$(mktemp -d)
TMP_LINEAR_FF=$(mktemp -d)
TMP_ANNOTATED=$(mktemp -d)
TMP_SPENT_ORPHAN=$(mktemp -d)
TMP_SPENT_STALE=$(mktemp -d)
TMP_CR_HEADER=$(mktemp -d)
TMP_UTF8_PATH=$(mktemp -d)
TMP_BACKWARD=$(mktemp -d)
TMP_DIVERGENT=$(mktemp -d)
TMP_PASSMERGE=$(mktemp -d)
TMP_FOREIGN_MARKER=$(mktemp -d)
TMP_PM_NONEMPTY=$(mktemp -d)
HOOKS=$(mktemp -d)
SHIM=$(mktemp -d)
EXTDIFF=$(mktemp -d)
LOGDIR=$(mktemp -d)
trap 'rm -rf "$TMP_BLOCK" "$TMP_ALLOW" "$TMP_PATH" "$TMP_NOCOMMIT" "$TMP_FF" "$TMP_EXTDIFF" "$TMP_CLAIM" "$TMP_ABORT" "$TMP_SPOOF" "$TMP_BASHENV" "$TMP_SKIP_AGE" "$TMP_SKNONE_STALE" "$TMP_SKNONE_CONTENT" "$TMP_SKNONE_OVERFLOW" "$TMP_SKNONE_FUTURE" "$TMP_SKNONE_LONG" "$TMP_SKNONE_BOUND" "$TMP_REPO_MARKER" "$TMP_FF_MERGE" "$TMP_CTREE" "$TMP_TAG_WITNESS" "$TMP_SYM_WITNESS" "$TMP_HIDDEN_MERGE" "$TMP_NEW_BRANCH" "$TMP_STALE_MH" "$TMP_ROOT_CREATE" "$TMP_ROOT_AMEND" "$TMP_FF_DEEP" "$TMP_LINEAR_FF" "$TMP_ANNOTATED" "$TMP_SPENT_ORPHAN" "$TMP_SPENT_STALE" "$TMP_CR_HEADER" "$TMP_UTF8_PATH" "$TMP_BACKWARD" "$TMP_DIVERGENT" "$TMP_PASSMERGE" "$TMP_FOREIGN_MARKER" "$TMP_PM_NONEMPTY" "$HOOKS" "$SHIM" "$EXTDIFF" "$LOGDIR"' EXIT

setup_repo "$TMP_BLOCK"
install_hook "$TMP_BLOCK" "$HOOKS"
mkdir -p "$TMP_BLOCK/.claude"

echo "── fixture containment: repo-selecting git env cannot escape ─"
# Forcing, not decorative: the hostile values are planted INSIDE this case and the
# guard is re-applied on top of them, so deleting the unsets makes `git rev-parse`
# answer with the planted directory (or fail) instead of the fixture. Asserting only
# that the variables are empty would pass vacuously whenever the caller's env is clean
# -- which is exactly the run where the bug is invisible.
TMP_CONTAIN=$(mktemp -d)
( cd "$TMP_CONTAIN" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && echo x > x && git add x && git commit -q -m contained ) >/dev/null 2>&1
CONTAIN_GD=$(
    export GIT_DIR="$TMP_CONTAIN/hostile-gitdir" \
           GIT_INDEX_FILE="$TMP_CONTAIN/hostile-index" \
           GIT_WORK_TREE="$TMP_CONTAIN/hostile-worktree" \
           GIT_OBJECT_DIRECTORY="$TMP_CONTAIN/hostile-objects" \
           GIT_ALTERNATE_OBJECT_DIRECTORIES="$TMP_CONTAIN/hostile-alt" \
           GIT_COMMON_DIR="$TMP_CONTAIN/hostile-common"
    _neutralize_git_env
    # `|| true` so a broken guard reports a readable FAIL instead of aborting the
    # whole suite under `set -e` with no indication of which assertion broke.
    cd "$TMP_CONTAIN/r" && { git rev-parse --absolute-git-dir 2>/dev/null || true; }
)
# Resolve the fixture path the same way git reports it: on macOS /var is a symlink
# to /private/var, so the literal mktemp path never prefix-matches what git prints.
CONTAIN_REAL=$(cd "$TMP_CONTAIN" && pwd -P)
case "$CONTAIN_GD" in
    "$CONTAIN_REAL"/r/.git) assert "a fixture resolves its own git dir despite a hostile inherited env" "contained" "contained" ;;
    *) assert "a fixture resolves its own git dir despite a hostile inherited env" "contained" "${CONTAIN_GD:-<unresolvable>}" ;;
esac
# ...and the staged write really landed in the fixture index, not somewhere else.
CONTAIN_STAGED=$(
    export GIT_INDEX_FILE="$TMP_CONTAIN/hostile-index"
    _neutralize_git_env
    git -C "$TMP_CONTAIN/r" diff --cached --name-only 2>/dev/null | tr '\n' ' '
)
assert "a staged write goes to the fixture index, not an inherited one" "" "$CONTAIN_STAGED"

# ...and a command-level injector cannot override the fixture's OWN config. The
# fixture sets a local core.hooksPath first: reading an unset key would fall
# through to the machine's global config and prove nothing about the injector.
git -C "$TMP_CONTAIN/r" config core.hooksPath "$TMP_CONTAIN/fixture-hooks"
CONTAIN_HOOKS=$(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
           GIT_CONFIG_VALUE_0="$TMP_CONTAIN/EXTERNAL-hooks"
    _neutralize_git_env
    git -C "$TMP_CONTAIN/r" config --get core.hooksPath 2>/dev/null || echo "<unreadable>"
)
assert "an inherited GIT_CONFIG_COUNT cannot redirect core.hooksPath" \
    "$TMP_CONTAIN/fixture-hooks" "$CONTAIN_HOOKS"
assert "the fixture commit is visible to a plain fixture read" "contained" \
    "$(git -C "$TMP_CONTAIN/r" log -1 --format=%s 2>/dev/null)"
rm -rf "$TMP_CONTAIN"

echo "── pre-merge-commit: conflict-free merge without marker ───"
set +e
git -C "$TMP_BLOCK" merge topic --no-edit 2>"$LOGDIR/merge-block.err"
MERGE_RC=$?
set -e
HEAD_MSG=$(git -C "$TMP_BLOCK" log -1 --format=%s 2>/dev/null || true)
BLOCK_ERR=$(tr '\n' ' ' <"$LOGDIR/merge-block.err")
if [[ "$MERGE_RC" -ne 0 && "$HEAD_MSG" == "mainline" ]]; then
    assert "merge blocked without marker" "block" "block"
else
    assert "merge blocked without marker" "block" "allow(rc=$MERGE_RC head=$HEAD_MSG err=$BLOCK_ERR)"
fi

echo "── pre-merge-commit: conflict-free merge with matching marker ─"
setup_repo "$TMP_ALLOW"
install_hook "$TMP_ALLOW" "$HOOKS"
mkdir -p "$TMP_ALLOW/.claude"
git -C "$TMP_ALLOW" merge --no-commit topic >/dev/null 2>&1
EXPECTED_HASH=$(staged_hash "$TMP_ALLOW")
git -C "$TMP_ALLOW" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$EXPECTED_HASH" >"$TMP_ALLOW/.claude/litmus-passed.local"
set +e
git -C "$TMP_ALLOW" merge topic --no-edit >"$LOGDIR/merge-allow.out" 2>"$LOGDIR/merge-allow.err"
MERGE_OK_RC=$?
set -e
HEAD_AFTER=$(git -C "$TMP_ALLOW" log -1 --format=%s 2>/dev/null || true)
ALLOW_ERR=$(tr '\n' ' ' <"$LOGDIR/merge-allow.err")
if [[ "$MERGE_OK_RC" -eq 0 && "$HEAD_AFTER" != "mainline" && "$HEAD_AFTER" != "base" ]]; then
    assert "merge allowed with marker" "allow" "allow"
else
    assert "merge allowed with marker" "allow" "block(rc=$MERGE_OK_RC head=$HEAD_AFTER err=$ALLOW_ERR)"
fi
if [[ ! -f "$TMP_ALLOW/.claude/litmus-passed.local" ]]; then
    assert "post-merge consumed marker" "gone" "gone"
else
    assert "post-merge consumed marker" "gone" "present"
fi

echo "── pre-merge-commit: hostile PATH cannot authorize merge ─"
setup_repo "$TMP_PATH"
install_hook "$TMP_PATH" "$HOOKS"
mkdir -p "$TMP_PATH/.claude"
printf '#!/bin/bash\necho "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  -"\n' >"$SHIM/sha256sum"
printf '#!/bin/bash\necho "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  -"\n' >"$SHIM/shasum"
chmod +x "$SHIM/sha256sum" "$SHIM/shasum"
printf 'BUILTIN-%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    >"$TMP_PATH/.claude/litmus-passed.local"
set +e
env PATH="$SHIM:/usr/bin:/bin" git -C "$TMP_PATH" merge topic --no-edit 2>"$LOGDIR/merge-path.err"
PATH_RC=$?
set -e
PATH_HEAD=$(git -C "$TMP_PATH" log -1 --format=%s 2>/dev/null || true)
PATH_ERR=$(tr '\n' ' ' <"$LOGDIR/merge-path.err")
if [[ "$PATH_RC" -ne 0 && "$PATH_HEAD" == "mainline" ]]; then
    assert "hostile PATH blocked" "block" "block"
else
    assert "hostile PATH blocked" "block" "allow(rc=$PATH_RC head=$PATH_HEAD err=$PATH_ERR)"
fi

echo "── merge --no-commit + git commit: blocked without marker ─"
setup_repo "$TMP_NOCOMMIT"
install_hook "$TMP_NOCOMMIT" "$HOOKS"
mkdir -p "$TMP_NOCOMMIT/.claude"
set +e
git -C "$TMP_NOCOMMIT" merge --no-commit topic >/dev/null 2>&1
git -C "$TMP_NOCOMMIT" commit -q -m "finish merge" 2>"$LOGDIR/nocommit-block.err"
NOCOMMIT_RC=$?
set -e
NOCOMMIT_HEAD=$(git -C "$TMP_NOCOMMIT" log -1 --format=%s 2>/dev/null || true)
NOCOMMIT_ERR=$(tr '\n' ' ' <"$LOGDIR/nocommit-block.err")
if [[ "$NOCOMMIT_RC" -ne 0 && "$NOCOMMIT_HEAD" == "mainline" ]]; then
    assert "merge commit blocked without marker" "block" "block"
else
    assert "merge commit blocked without marker" "block" "allow(rc=$NOCOMMIT_RC head=$NOCOMMIT_HEAD err=$NOCOMMIT_ERR)"
fi

echo "── merge --no-commit + git commit: allowed with marker ─"
git -C "$TMP_NOCOMMIT" merge --abort >/dev/null 2>&1 || true
git -C "$TMP_NOCOMMIT" merge --no-commit topic >/dev/null 2>&1
NOCOMMIT_HASH=$(staged_hash "$TMP_NOCOMMIT")
printf 'BUILTIN-%s\n' "$NOCOMMIT_HASH" >"$TMP_NOCOMMIT/.claude/litmus-passed.local"
set +e
git -C "$TMP_NOCOMMIT" commit -q -m "finish merge" 2>"$LOGDIR/nocommit-allow.err"
NOCOMMIT_OK_RC=$?
set -e
NOCOMMIT_OK_HEAD=$(git -C "$TMP_NOCOMMIT" log -1 --format=%s 2>/dev/null || true)
NOCOMMIT_ALLOW_ERR=$(tr '\n' ' ' <"$LOGDIR/nocommit-allow.err")
if [[ "$NOCOMMIT_OK_RC" -eq 0 && "$NOCOMMIT_OK_HEAD" == "finish merge" ]]; then
    assert "merge commit allowed with marker" "allow" "allow"
else
    assert "merge commit allowed with marker" "allow" "block(rc=$NOCOMMIT_OK_RC head=$NOCOMMIT_OK_HEAD err=$NOCOMMIT_ALLOW_ERR)"
fi

echo "── fast-forward: stale marker not consumed ─"
git -C "$TMP_FF" init -q -b main 2>/dev/null || git -C "$TMP_FF" init -q
git -C "$TMP_FF" config user.email t@t.dev
git -C "$TMP_FF" config user.name tester
git -C "$TMP_FF" config commit.gpgsign false
echo base >"$TMP_FF/base.txt"
git -C "$TMP_FF" add base.txt
git -C "$TMP_FF" commit -q -m base --no-verify
git -C "$TMP_FF" checkout -q -b topic
echo topic >"$TMP_FF/topic.txt"
git -C "$TMP_FF" add topic.txt
git -C "$TMP_FF" commit -q -m topic --no-verify
git -C "$TMP_FF" checkout -q main
install_hook "$TMP_FF" "$HOOKS"
mkdir -p "$TMP_FF/.claude"
printf 'BUILTIN-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' \
    >"$TMP_FF/.claude/litmus-passed.local"
set +e
git -C "$TMP_FF" merge topic --no-edit 2>"$LOGDIR/ff.err"
set -e
if [[ -f "$TMP_FF/.claude/litmus-passed.local" ]]; then
    assert "fast-forward keeps stale marker" "kept" "kept"
else
    assert "fast-forward keeps stale marker" "kept" "consumed"
fi

echo "── GIT_EXTERNAL_DIFF constant cannot authorize merge ─"
setup_repo "$TMP_EXTDIFF"
install_hook "$TMP_EXTDIFF" "$HOOKS"
mkdir -p "$TMP_EXTDIFF/.claude"
printf '#!/bin/bash\necho "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  -"\n' >"$EXTDIFF/fake-diff"
chmod +x "$EXTDIFF/fake-diff"
printf 'BUILTIN-%s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    >"$TMP_EXTDIFF/.claude/litmus-passed.local"
set +e
env GIT_EXTERNAL_DIFF="$EXTDIFF/fake-diff" git -C "$TMP_EXTDIFF" merge topic --no-edit 2>"$LOGDIR/extdiff.err"
EXT_RC=$?
set -e
EXT_HEAD=$(git -C "$TMP_EXTDIFF" log -1 --format=%s 2>/dev/null || true)
EXT_ERR=$(tr '\n' ' ' <"$LOGDIR/extdiff.err")
if [[ "$EXT_RC" -ne 0 && "$EXT_HEAD" == "mainline" ]]; then
    assert "external diff blocked" "block" "block"
else
    assert "external diff blocked" "block" "allow(rc=$EXT_RC head=$EXT_HEAD err=$EXT_ERR)"
fi

echo "── pending claim write failure blocks merge ─"
setup_repo "$TMP_CLAIM"
install_hook "$TMP_CLAIM" "$HOOKS"
mkdir -p "$TMP_CLAIM/.claude"
git -C "$TMP_CLAIM" merge --no-commit topic >/dev/null 2>&1
CLAIM_HASH=$(staged_hash "$TMP_CLAIM")
git -C "$TMP_CLAIM" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$CLAIM_HASH" >"$TMP_CLAIM/.claude/litmus-passed.local"
ln -sf /dev/null "$TMP_CLAIM/.claude/merge-litmus-pending.local.tmp"
set +e
git -C "$TMP_CLAIM" merge topic --no-edit 2>"$LOGDIR/claim-block.err"
CLAIM_RC=$?
set -e
CLAIM_HEAD=$(git -C "$TMP_CLAIM" log -1 --format=%s 2>/dev/null || true)
CLAIM_ERR=$(tr '\n' ' ' <"$LOGDIR/claim-block.err")
if [[ "$CLAIM_RC" -ne 0 && "$CLAIM_HEAD" == "mainline" && -f "$TMP_CLAIM/.claude/litmus-passed.local" ]]; then
    assert "claim write failure blocks merge" "block" "block"
else
    assert "claim write failure blocks merge" "block" "allow(rc=$CLAIM_RC head=$CLAIM_HEAD err=$CLAIM_ERR)"
fi

echo "── abort then an ordinary successor is not locked by the stale arm ─"
setup_repo "$TMP_ABORT"
install_hook "$TMP_ABORT" "$HOOKS"
mkdir -p "$TMP_ABORT/.claude/hooks"
printf '#!/bin/bash\nexit 1\n' >"$TMP_ABORT/.claude/hooks/commit-msg"
chmod +x "$TMP_ABORT/.claude/hooks/commit-msg"
git -C "$TMP_ABORT" config core.hooksPath "$TMP_ABORT/.claude/hooks"
ln -sf "$REPO_ROOT/$GATE_SCRIPT" "$TMP_ABORT/.claude/hooks/pre-merge-commit"
ln -sf "$REPO_ROOT/$POST_MERGE" "$TMP_ABORT/.claude/hooks/post-merge"
ln -sf "$REPO_ROOT/$MERGE_PRE_COMMIT" "$TMP_ABORT/.claude/hooks/pre-commit"
ln -sf "$REPO_ROOT/$MERGE_PREPARE_COMMIT_MSG" "$TMP_ABORT/.claude/hooks/prepare-commit-msg"
ln -sf "$REPO_ROOT/$MERGE_REFERENCE_TRANSACTION" "$TMP_ABORT/.claude/hooks/reference-transaction"
ln -sf "$REPO_ROOT/$MERGE_POST_COMMIT" "$TMP_ABORT/.claude/hooks/post-commit"
git -C "$TMP_ABORT" merge --no-commit topic >/dev/null 2>&1
ABORT_HASH=$(staged_hash "$TMP_ABORT")
printf 'BUILTIN-%s\n' "$ABORT_HASH" >"$TMP_ABORT/.claude/litmus-passed.local"
set +e
git -C "$TMP_ABORT" commit -q -m "finish merge" 2>"$LOGDIR/abort-fail.err"
set -e
git -C "$TMP_ABORT" merge --abort >/dev/null 2>&1
ABORT_GD=$(git -C "$TMP_ABORT" rev-parse --absolute-git-dir)
# Assert the PRECONDITION, not just the outcome. The whole case is "a stale arm
# left by an aborted merge does not lock the branch" — but `git merge --abort`
# does not clear the arm or the claim today, and if hook ordering or the
# commit-msg stub ever changed so that it did, the allow-assertion below would
# still pass while testing nothing at all. That is the shape of vacuity this
# suite has already shipped four times.
if [[ -f "$ABORT_GD/busdriver-merge-litmus-armed" \
      && -f "$TMP_ABORT/.claude/merge-litmus-pending.local" ]]; then
    assert "aborted merge really does leave a stale arm" "armed" "armed"
else
    assert "aborted merge really does leave a stale arm" "armed" \
        "arm=$([[ -f "$ABORT_GD/busdriver-merge-litmus-armed" ]] && echo yes || echo no) claim=$([[ -f "$TMP_ABORT/.claude/merge-litmus-pending.local" ]] && echo yes || echo no)"
fi
ABORT_BEFORE=$(git -C "$TMP_ABORT" rev-parse HEAD)
ABORT_TREE=$(git -C "$TMP_ABORT" rev-parse 'HEAD^{tree}')
ABORT_NEXT=$(git -C "$TMP_ABORT" commit-tree "$ABORT_TREE" -p "$ABORT_BEFORE" -m "post-abort successor")
set +e
git -C "$TMP_ABORT" update-ref refs/heads/main "$ABORT_NEXT" "$ABORT_BEFORE" >/dev/null 2>"$LOGDIR/abort-rt.err"
ABORT_RT_RC=$?
set -e
ABORT_AFTER=$(git -C "$TMP_ABORT" rev-parse HEAD)
if [[ "$ABORT_RT_RC" -eq 0 && "$ABORT_AFTER" == "$ABORT_NEXT" ]]; then
    assert "abort then ordinary successor not locked by stale arm" "allow" "allow"
else
    ABORT_RT_ERR=$(tr '\n' ' ' <"$LOGDIR/abort-rt.err" || true)
    assert "abort then ordinary successor not locked by stale arm" "allow" \
        "block(rc=$ABORT_RT_RC after=$ABORT_AFTER err=$ABORT_RT_ERR)"
fi

echo "── spoofed GIT_REFLOG_ACTION still consumes marker ─"
setup_repo "$TMP_SPOOF"
install_hook "$TMP_SPOOF" "$HOOKS"
mkdir -p "$TMP_SPOOF/.claude"
git -C "$TMP_SPOOF" merge --no-commit topic >/dev/null 2>&1
SPOOF_HASH=$(staged_hash "$TMP_SPOOF")
git -C "$TMP_SPOOF" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$SPOOF_HASH" >"$TMP_SPOOF/.claude/litmus-passed.local"
set +e
env GIT_REFLOG_ACTION='merge HEAD' git -C "$TMP_SPOOF" merge topic --no-edit >"$LOGDIR/spoof.err" 2>&1
SPOOF_RC=$?
set -e
if [[ "$SPOOF_RC" -eq 0 && ! -f "$TMP_SPOOF/.claude/litmus-passed.local" ]]; then
    assert "spoofed reflog action consumed marker" "consumed" "consumed"
else
    assert "spoofed reflog action consumed marker" "consumed" "left(rc=$SPOOF_RC)"
fi

echo "── hostile BASH_ENV cannot bypass merge gate ─"
setup_repo "$TMP_BASHENV"
install_hook "$TMP_BASHENV" "$HOOKS"
mkdir -p "$TMP_BASHENV/.claude"
printf '#!/bin/bash\nexit 0\n' >"$TMP_BASHENV/bypass.sh"
chmod +x "$TMP_BASHENV/bypass.sh"
set +e
env BASH_ENV="$TMP_BASHENV/bypass.sh" git -C "$TMP_BASHENV" merge topic --no-edit 2>"$LOGDIR/bashenv.err"
BASHENV_RC=$?
set -e
BASHENV_HEAD=$(git -C "$TMP_BASHENV" log -1 --format=%s 2>/dev/null || true)
BASHENV_ERR=$(tr '\n' ' ' <"$LOGDIR/bashenv.err")
if [[ "$BASHENV_RC" -ne 0 && "$BASHENV_HEAD" == "mainline" ]]; then
    assert "hostile BASH_ENV blocked" "block" "block"
else
    assert "hostile BASH_ENV blocked" "block" "allow(rc=$BASHENV_RC head=$BASHENV_HEAD err=$BASHENV_ERR)"
fi

echo "── fresh skip-litmus.local blocked (< 30s) ─"
setup_repo "$TMP_SKIP_AGE"
install_hook "$TMP_SKIP_AGE" "$HOOKS"
mkdir -p "$TMP_SKIP_AGE/.claude"
printf 'skip\n' >"$TMP_SKIP_AGE/.claude/skip-litmus.local"
set +e
git -C "$TMP_SKIP_AGE" merge topic --no-edit 2>"$LOGDIR/skip-age.err"
SKIP_AGE_RC=$?
set -e
SKIP_AGE_HEAD=$(git -C "$TMP_SKIP_AGE" log -1 --format=%s 2>/dev/null || true)
if [[ "$SKIP_AGE_RC" -ne 0 && "$SKIP_AGE_HEAD" == "mainline" ]]; then
    assert "fresh skip file blocked" "block" "block"
else
    assert "fresh skip file blocked" "block" "allow(rc=$SKIP_AGE_RC head=$SKIP_AGE_HEAD)"
fi

echo "── stale SKIPPED-NONE marker blocked ─"
setup_repo "$TMP_SKNONE_STALE"
install_hook "$TMP_SKNONE_STALE" "$HOOKS"
mkdir -p "$TMP_SKNONE_STALE/.claude"
git -C "$TMP_SKNONE_STALE" merge --no-commit topic >/dev/null 2>&1
printf 'SKIPPED-NONE-1\n' >"$TMP_SKNONE_STALE/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_STALE" commit -q -m "finish merge" 2>"$LOGDIR/sknone-stale.err"
SKNONE_STALE_RC=$?
set -e
SKNONE_STALE_MARKER=absent
[[ -f "$TMP_SKNONE_STALE/.claude/litmus-passed.local" ]] && SKNONE_STALE_MARKER=present
if [[ "$SKNONE_STALE_RC" -ne 0 && "$SKNONE_STALE_MARKER" == "absent" ]]; then
    assert "stale SKIPPED-NONE blocked" "block" "block"
else
    assert "stale SKIPPED-NONE blocked" "block" "allow(rc=$SKNONE_STALE_RC marker=$SKNONE_STALE_MARKER)"
fi

echo "── fresh SKIPPED-NONE allows merge with staged content (NONE opt-out) ─"
setup_repo "$TMP_SKNONE_CONTENT"
install_hook "$TMP_SKNONE_CONTENT" "$HOOKS"
mkdir -p "$TMP_SKNONE_CONTENT/.claude"
git -C "$TMP_SKNONE_CONTENT" merge --no-commit topic >/dev/null 2>&1
SKNONE_EPOCH=$(date +%s)
printf 'SKIPPED-NONE-%s\n' "$SKNONE_EPOCH" >"$TMP_SKNONE_CONTENT/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_CONTENT" commit -q -m "finish merge" 2>"$LOGDIR/sknone-content.err"
SKNONE_CONTENT_RC=$?
set -e
if [[ "$SKNONE_CONTENT_RC" -eq 0 ]]; then
    assert "fresh SKIPPED-NONE allows merge with content" "allow" "allow"
else
    assert "fresh SKIPPED-NONE allows merge with content" "allow" "block(rc=$SKNONE_CONTENT_RC)"
fi

echo "── overflow SKIPPED-NONE epoch blocked ─"
setup_repo "$TMP_SKNONE_OVERFLOW"
install_hook "$TMP_SKNONE_OVERFLOW" "$HOOKS"
mkdir -p "$TMP_SKNONE_OVERFLOW/.claude"
git -C "$TMP_SKNONE_OVERFLOW" merge --no-commit topic >/dev/null 2>&1
printf 'SKIPPED-NONE-9999999999\n' >"$TMP_SKNONE_OVERFLOW/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_OVERFLOW" commit -q -m "finish merge" 2>"$LOGDIR/sknone-overflow.err"
SKNONE_OVERFLOW_RC=$?
set -e
SKNONE_OVERFLOW_MARKER=absent
[[ -f "$TMP_SKNONE_OVERFLOW/.claude/litmus-passed.local" ]] && SKNONE_OVERFLOW_MARKER=present
if [[ "$SKNONE_OVERFLOW_RC" -ne 0 && "$SKNONE_OVERFLOW_MARKER" == "absent" ]]; then
    assert "overflow SKIPPED-NONE epoch blocked" "block" "block"
else
    assert "overflow SKIPPED-NONE epoch blocked" "block" "allow(rc=$SKNONE_OVERFLOW_RC marker=$SKNONE_OVERFLOW_MARKER)"
fi

echo "── future SKIPPED-NONE epoch blocked ─"
setup_repo "$TMP_SKNONE_FUTURE"
install_hook "$TMP_SKNONE_FUTURE" "$HOOKS"
mkdir -p "$TMP_SKNONE_FUTURE/.claude"
git -C "$TMP_SKNONE_FUTURE" merge --no-commit topic >/dev/null 2>&1
SKNONE_FUTURE_EPOCH=$(( $(date +%s) + 3600 ))
printf 'SKIPPED-NONE-%s\n' "$SKNONE_FUTURE_EPOCH" >"$TMP_SKNONE_FUTURE/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_FUTURE" commit -q -m "finish merge" 2>"$LOGDIR/sknone-future.err"
SKNONE_FUTURE_RC=$?
set -e
if [[ "$SKNONE_FUTURE_RC" -ne 0 ]]; then
    assert "future SKIPPED-NONE epoch blocked" "block" "block"
else
    assert "future SKIPPED-NONE epoch blocked" "block" "allow(rc=$SKNONE_FUTURE_RC)"
fi

echo "── overlong SKIPPED-NONE epoch blocked ─"
setup_repo "$TMP_SKNONE_LONG"
install_hook "$TMP_SKNONE_LONG" "$HOOKS"
mkdir -p "$TMP_SKNONE_LONG/.claude"
git -C "$TMP_SKNONE_LONG" merge --no-commit topic >/dev/null 2>&1
printf 'SKIPPED-NONE-12345678901\n' >"$TMP_SKNONE_LONG/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_LONG" commit -q -m "finish merge" 2>"$LOGDIR/sknone-long.err"
SKNONE_LONG_RC=$?
set -e
if [[ "$SKNONE_LONG_RC" -ne 0 ]]; then
    assert "overlong SKIPPED-NONE epoch blocked" "block" "block"
else
    assert "overlong SKIPPED-NONE epoch blocked" "block" "allow(rc=$SKNONE_LONG_RC)"
fi

echo "── SKIPPED-NONE at 3600s freshness boundary blocked ─"
setup_repo "$TMP_SKNONE_BOUND"
install_hook "$TMP_SKNONE_BOUND" "$HOOKS"
mkdir -p "$TMP_SKNONE_BOUND/.claude"
git -C "$TMP_SKNONE_BOUND" merge --no-commit topic >/dev/null 2>&1
SKNONE_BOUND_EPOCH=$(( $(date +%s) - 3601 ))
printf 'SKIPPED-NONE-%s\n' "$SKNONE_BOUND_EPOCH" >"$TMP_SKNONE_BOUND/.claude/litmus-passed.local"
set +e
git -C "$TMP_SKNONE_BOUND" commit -q -m "finish merge" 2>"$LOGDIR/sknone-bound.err"
SKNONE_BOUND_RC=$?
set -e
if [[ "$SKNONE_BOUND_RC" -ne 0 ]]; then
    assert "SKIPPED-NONE older than 3600s blocked" "block" "block"
else
    assert "SKIPPED-NONE older than 3600s blocked" "block" "allow(rc=$SKNONE_BOUND_RC)"
fi

echo "── committed litmus-passed.local marker blocked ─"
setup_repo "$TMP_REPO_MARKER"
install_hook "$TMP_REPO_MARKER" "$HOOKS"
mkdir -p "$TMP_REPO_MARKER/.claude"
printf '.claude/*.local\n' >"$TMP_REPO_MARKER/.gitignore"
git -C "$TMP_REPO_MARKER" add .gitignore
git -C "$TMP_REPO_MARKER" commit -q -m "gitignore" --no-verify
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' \
    >"$TMP_REPO_MARKER/.claude/litmus-passed.local"
git -C "$TMP_REPO_MARKER" add -f .claude/litmus-passed.local
git -C "$TMP_REPO_MARKER" commit -q -m "sneak marker" --no-verify
set +e
git -C "$TMP_REPO_MARKER" merge topic --no-edit 2>"$LOGDIR/repo-marker.err"
REPO_MARKER_RC=$?
set -e
REPO_MARKER_HEAD=$(git -C "$TMP_REPO_MARKER" log -1 --format=%s 2>/dev/null || true)
if [[ "$REPO_MARKER_RC" -ne 0 && "$REPO_MARKER_HEAD" == "sneak marker" ]]; then
    assert "committed marker blocked" "block" "block"
else
    assert "committed marker blocked" "block" "allow(rc=$REPO_MARKER_RC head=$REPO_MARKER_HEAD)"
fi

echo "── fast-forward onto existing merge commit does not rewind HEAD ─"
setup_repo "$TMP_FF_MERGE"
install_hook "$TMP_FF_MERGE" "$HOOKS"
mkdir -p "$TMP_FF_MERGE/.claude"
# Create lagging branch while main tip is still a direct tip (zero-OLD exact).
git -C "$TMP_FF_MERGE" branch behind main
git -C "$TMP_FF_MERGE" merge --no-commit --no-ff topic >/dev/null 2>&1
FF_MERGE_HASH=$(staged_hash "$TMP_FF_MERGE")
git -C "$TMP_FF_MERGE" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$FF_MERGE_HASH" >"$TMP_FF_MERGE/.claude/litmus-passed.local"
set +e
git -C "$TMP_FF_MERGE" merge --no-ff topic --no-edit >/dev/null 2>"$LOGDIR/ff-merge-create.err"
FF_CREATE_RC=$?
set -e
FF_MERGE_SHA=$(git -C "$TMP_FF_MERGE" rev-parse HEAD)
FF_PARENT_COUNT=$(git -C "$TMP_FF_MERGE" rev-list --parents -n 1 HEAD | awk '{print NF-1}')
if [[ "$FF_CREATE_RC" -ne 0 || "$FF_PARENT_COUNT" -lt 2 ]]; then
    FF_CREATE_ERR=$(tr '\n' ' ' <"$LOGDIR/ff-merge-create.err" || true)
    assert "fast-forward onto merge commit keeps merge HEAD" "kept" \
        "create-failed(rc=$FF_CREATE_RC parents=$FF_PARENT_COUNT err=$FF_CREATE_ERR)"
else
git -C "$TMP_FF_MERGE" checkout -q behind
set +e
git -C "$TMP_FF_MERGE" merge --ff-only "$FF_MERGE_SHA" >/dev/null 2>"$LOGDIR/ff-onto-merge.err"
FF_ONTO_RC=$?
set -e
FF_ONTO_HEAD=$(git -C "$TMP_FF_MERGE" rev-parse HEAD)
if [[ "$FF_ONTO_RC" -eq 0 && "$FF_ONTO_HEAD" == "$FF_MERGE_SHA" ]]; then
    assert "fast-forward onto merge commit keeps merge HEAD" "kept" "kept"
else
    FF_ONTO_ERR=$(tr '\n' ' ' <"$LOGDIR/ff-onto-merge.err" || true)
    assert "fast-forward onto merge commit keeps merge HEAD" "kept" \
        "moved(rc=$FF_ONTO_RC head=$FF_ONTO_HEAD want=$FF_MERGE_SHA err=$FF_ONTO_ERR)"
fi
fi

echo "── commit-tree merge tip without other ref is refused ─"
setup_repo "$TMP_CTREE"
install_hook "$TMP_CTREE" "$HOOKS"
CTREE_MAIN=$(git -C "$TMP_CTREE" rev-parse main)
CTREE_TOPIC=$(git -C "$TMP_CTREE" rev-parse topic)
CTREE_TREE=$(git -C "$TMP_CTREE" rev-parse "$CTREE_TOPIC^{tree}")
CTREE_MERGE=$(git -C "$TMP_CTREE" commit-tree "$CTREE_TREE" -p "$CTREE_MAIN" -p "$CTREE_TOPIC" -m "crafted merge")
set +e
git -C "$TMP_CTREE" update-ref refs/heads/main "$CTREE_MERGE" "$CTREE_MAIN" >/dev/null 2>"$LOGDIR/ctree-update.err"
CTREE_RC=$?
set -e
CTREE_HEAD=$(git -C "$TMP_CTREE" rev-parse main)
if [[ "$CTREE_RC" -ne 0 && "$CTREE_HEAD" == "$CTREE_MAIN" ]]; then
    assert "commit-tree merge tip without other ref blocked" "block" "block"
else
    CTREE_ERR=$(tr '\n' ' ' <"$LOGDIR/ctree-update.err" || true)
    assert "commit-tree merge tip without other ref blocked" "block" \
        "allow(rc=$CTREE_RC head=$CTREE_HEAD err=$CTREE_ERR)"
fi

echo "── tag tip cannot witness an unreviewed merge publication ─"
setup_repo "$TMP_TAG_WITNESS"
install_hook "$TMP_TAG_WITNESS" "$HOOKS"
TW_MAIN=$(git -C "$TMP_TAG_WITNESS" rev-parse main)
TW_TOPIC=$(git -C "$TMP_TAG_WITNESS" rev-parse topic)
TW_TREE=$(git -C "$TMP_TAG_WITNESS" rev-parse "$TW_TOPIC^{tree}")
TW_MERGE=$(git -C "$TMP_TAG_WITNESS" commit-tree "$TW_TREE" -p "$TW_MAIN" -p "$TW_TOPIC" -m "tag-witnessed merge")
git -C "$TMP_TAG_WITNESS" update-ref refs/tags/bypass "$TW_MERGE"
set +e
git -C "$TMP_TAG_WITNESS" update-ref refs/heads/main "$TW_MERGE" "$TW_MAIN" >/dev/null 2>"$LOGDIR/tag-witness.err"
TW_RC=$?
set -e
TW_HEAD=$(git -C "$TMP_TAG_WITNESS" rev-parse main)
if [[ "$TW_RC" -ne 0 && "$TW_HEAD" == "$TW_MAIN" ]]; then
    assert "tag tip cannot witness merge publication" "block" "block"
else
    TW_ERR=$(tr '\n' ' ' <"$LOGDIR/tag-witness.err" || true)
    assert "tag tip cannot witness merge publication" "block" \
        "allow(rc=$TW_RC head=$TW_HEAD err=$TW_ERR)"
fi

echo "── symbolic head aliasing a tag cannot witness merge publication ─"
setup_repo "$TMP_SYM_WITNESS"
install_hook "$TMP_SYM_WITNESS" "$HOOKS"
SW_MAIN=$(git -C "$TMP_SYM_WITNESS" rev-parse main)
SW_TOPIC=$(git -C "$TMP_SYM_WITNESS" rev-parse topic)
SW_TREE=$(git -C "$TMP_SYM_WITNESS" rev-parse "$SW_TOPIC^{tree}")
SW_MERGE=$(git -C "$TMP_SYM_WITNESS" commit-tree "$SW_TREE" -p "$SW_MAIN" -p "$SW_TOPIC" -m "symref-witnessed merge")
git -C "$TMP_SYM_WITNESS" update-ref refs/tags/bypass "$SW_MERGE"
git -C "$TMP_SYM_WITNESS" symbolic-ref refs/heads/witness refs/tags/bypass
set +e
git -C "$TMP_SYM_WITNESS" update-ref refs/heads/main "$SW_MERGE" "$SW_MAIN" >/dev/null 2>"$LOGDIR/sym-witness.err"
SW_RC=$?
set -e
SW_HEAD=$(git -C "$TMP_SYM_WITNESS" rev-parse main)
if [[ "$SW_RC" -ne 0 && "$SW_HEAD" == "$SW_MAIN" ]]; then
    assert "symbolic head cannot witness merge publication" "block" "block"
else
    SW_ERR=$(tr '\n' ' ' <"$LOGDIR/sym-witness.err" || true)
    assert "symbolic head cannot witness merge publication" "block" \
        "allow(rc=$SW_RC head=$SW_HEAD err=$SW_ERR)"
fi

echo "── one-parent tip cannot smuggle unpublished merge into history ─"
setup_repo "$TMP_HIDDEN_MERGE"
install_hook "$TMP_HIDDEN_MERGE" "$HOOKS"
HM_MAIN=$(git -C "$TMP_HIDDEN_MERGE" rev-parse main)
HM_TOPIC=$(git -C "$TMP_HIDDEN_MERGE" rev-parse topic)
HM_TREE=$(git -C "$TMP_HIDDEN_MERGE" rev-parse "$HM_TOPIC^{tree}")
HM_MERGE=$(git -C "$TMP_HIDDEN_MERGE" commit-tree "$HM_TREE" -p "$HM_MAIN" -p "$HM_TOPIC" -m "hidden merge")
HM_CHILD=$(git -C "$TMP_HIDDEN_MERGE" commit-tree "$HM_TREE" -p "$HM_MERGE" -m "smuggle")
set +e
git -C "$TMP_HIDDEN_MERGE" update-ref refs/heads/main "$HM_CHILD" "$HM_MAIN" >/dev/null 2>"$LOGDIR/hidden-merge.err"
HM_RC=$?
set -e
HM_HEAD=$(git -C "$TMP_HIDDEN_MERGE" rev-parse main)
if [[ "$HM_RC" -ne 0 && "$HM_HEAD" == "$HM_MAIN" ]]; then
    assert "one-parent tip cannot smuggle unpublished merge" "block" "block"
else
    HM_ERR=$(tr '\n' ' ' <"$LOGDIR/hidden-merge.err" || true)
    assert "one-parent tip cannot smuggle unpublished merge" "block" \
        "allow(rc=$HM_RC head=$HM_HEAD err=$HM_ERR)"
fi

echo "── new branch zero-oid cannot publish smuggled merge ancestry ─"
setup_repo "$TMP_NEW_BRANCH"
install_hook "$TMP_NEW_BRANCH" "$HOOKS"
NB_MAIN=$(git -C "$TMP_NEW_BRANCH" rev-parse main)
NB_TOPIC=$(git -C "$TMP_NEW_BRANCH" rev-parse topic)
NB_TREE=$(git -C "$TMP_NEW_BRANCH" rev-parse "$NB_TOPIC^{tree}")
NB_MERGE=$(git -C "$TMP_NEW_BRANCH" commit-tree "$NB_TREE" -p "$NB_MAIN" -p "$NB_TOPIC" -m "new-branch merge")
NB_CHILD=$(git -C "$TMP_NEW_BRANCH" commit-tree "$NB_TREE" -p "$NB_MERGE" -m "new-branch child")
set +e
git -C "$TMP_NEW_BRANCH" update-ref refs/heads/smuggled "$NB_CHILD" >/dev/null 2>"$LOGDIR/new-branch.err"
NB_RC=$?
set -e
if [[ "$NB_RC" -ne 0 ]] && ! git -C "$TMP_NEW_BRANCH" show-ref --verify --quiet refs/heads/smuggled; then
    assert "new branch cannot publish smuggled merge ancestry" "block" "block"
else
    NB_ERR=$(tr '\n' ' ' <"$LOGDIR/new-branch.err" || true)
    assert "new branch cannot publish smuggled merge ancestry" "block" \
        "allow(rc=$NB_RC err=$NB_ERR)"
fi

echo "── stale MERGE_HEAD cannot authorize one-parent smuggle tip ─"
setup_repo "$TMP_STALE_MH"
install_hook "$TMP_STALE_MH" "$HOOKS"
SM_MAIN=$(git -C "$TMP_STALE_MH" rev-parse main)
SM_TOPIC=$(git -C "$TMP_STALE_MH" rev-parse topic)
SM_TREE=$(git -C "$TMP_STALE_MH" rev-parse "$SM_TOPIC^{tree}")
SM_MERGE=$(git -C "$TMP_STALE_MH" commit-tree "$SM_TREE" -p "$SM_MAIN" -p "$SM_TOPIC" -m "stale-mh merge")
SM_CHILD=$(git -C "$TMP_STALE_MH" commit-tree "$SM_TREE" -p "$SM_MERGE" -m "stale-mh child")
: >"$(git -C "$TMP_STALE_MH" rev-parse --absolute-git-dir)/MERGE_HEAD"
set +e
git -C "$TMP_STALE_MH" update-ref refs/heads/main "$SM_CHILD" "$SM_MAIN" >/dev/null 2>"$LOGDIR/stale-mh.err"
SM_RC=$?
set -e
SM_HEAD=$(git -C "$TMP_STALE_MH" rev-parse main)
if [[ "$SM_RC" -ne 0 && "$SM_HEAD" == "$SM_MAIN" ]]; then
    assert "stale MERGE_HEAD cannot authorize one-parent smuggle" "block" "block"
else
    SM_ERR=$(tr '\n' ' ' <"$LOGDIR/stale-mh.err" || true)
    assert "stale MERGE_HEAD cannot authorize one-parent smuggle" "block" \
        "allow(rc=$SM_RC head=$SM_HEAD err=$SM_ERR)"
fi

echo "── first root commit (zero OLD, zero parents) is allowed ─"
git -C "$TMP_ROOT_CREATE" init -q -b main
git -C "$TMP_ROOT_CREATE" config user.email t@t.dev
git -C "$TMP_ROOT_CREATE" config user.name tester
git -C "$TMP_ROOT_CREATE" config commit.gpgsign false
install_hook "$TMP_ROOT_CREATE" "$HOOKS"
RC_EMPTY=$(git -C "$TMP_ROOT_CREATE" hash-object -t tree -w --stdin </dev/null)
RC_ROOT=$(git -C "$TMP_ROOT_CREATE" commit-tree "$RC_EMPTY" -m "first root")
set +e
git -C "$TMP_ROOT_CREATE" update-ref refs/heads/main "$RC_ROOT" >/dev/null 2>"$LOGDIR/root-create.err"
RC_RC=$?
set -e
RC_HEAD=$(git -C "$TMP_ROOT_CREATE" rev-parse main 2>/dev/null || true)
if [[ "$RC_RC" -eq 0 && "$RC_HEAD" == "$RC_ROOT" ]]; then
    assert "first root commit allowed" "allow" "allow"
else
    RC_ERR=$(tr '\n' ' ' <"$LOGDIR/root-create.err" || true)
    assert "first root commit allowed" "allow" \
        "block(rc=$RC_RC head=$RC_HEAD err=$RC_ERR)"
fi

echo "── root amend (zero-parent replace of a root tip) is allowed ─"
git -C "$TMP_ROOT_AMEND" init -q -b main
git -C "$TMP_ROOT_AMEND" config user.email t@t.dev
git -C "$TMP_ROOT_AMEND" config user.name tester
git -C "$TMP_ROOT_AMEND" config commit.gpgsign false
RA_EMPTY=$(git -C "$TMP_ROOT_AMEND" hash-object -t tree -w --stdin </dev/null)
RA_ROOT1=$(git -C "$TMP_ROOT_AMEND" commit-tree "$RA_EMPTY" -m "root1")
git -C "$TMP_ROOT_AMEND" update-ref refs/heads/main "$RA_ROOT1"
install_hook "$TMP_ROOT_AMEND" "$HOOKS"
RA_ROOT2=$(git -C "$TMP_ROOT_AMEND" commit-tree "$RA_EMPTY" -m "root2")
set +e
git -C "$TMP_ROOT_AMEND" update-ref refs/heads/main "$RA_ROOT2" "$RA_ROOT1" >/dev/null 2>"$LOGDIR/root-amend.err"
RA_RC=$?
set -e
RA_HEAD=$(git -C "$TMP_ROOT_AMEND" rev-parse main)
if [[ "$RA_RC" -eq 0 && "$RA_HEAD" == "$RA_ROOT2" ]]; then
    assert "root amend allowed" "allow" "allow"
else
    RA_ERR=$(tr '\n' ' ' <"$LOGDIR/root-amend.err" || true)
    assert "root amend allowed" "allow" \
        "block(rc=$RA_RC head=$RA_HEAD err=$RA_ERR)"
fi

echo "── fast-forward from deeper ancestor onto witnessed merge tip ─"
setup_repo "$TMP_FF_DEEP"
install_hook "$TMP_FF_DEEP" "$HOOKS"
mkdir -p "$TMP_FF_DEEP/.claude"
git -C "$TMP_FF_DEEP" merge --no-commit --no-ff topic >/dev/null 2>&1
FF_DEEP_HASH=$(staged_hash "$TMP_FF_DEEP")
git -C "$TMP_FF_DEEP" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$FF_DEEP_HASH" >"$TMP_FF_DEEP/.claude/litmus-passed.local"
set +e
git -C "$TMP_FF_DEEP" merge --no-ff topic --no-edit >/dev/null 2>"$LOGDIR/ff-deep-create.err"
FF_DEEP_CREATE_RC=$?
set -e
FF_DEEP_SHA=$(git -C "$TMP_FF_DEEP" rev-parse HEAD)
FF_DEEP_GP=$(git -C "$TMP_FF_DEEP" rev-parse 'HEAD^1^')
if [[ "$FF_DEEP_CREATE_RC" -ne 0 ]]; then
    FF_DEEP_CREATE_ERR=$(tr '\n' ' ' <"$LOGDIR/ff-deep-create.err" || true)
    assert "deeper ancestor FF onto witnessed merge" "kept" \
        "create-failed(rc=$FF_DEEP_CREATE_RC err=$FF_DEEP_CREATE_ERR)"
else
git -C "$TMP_FF_DEEP" checkout -qb deeper "$FF_DEEP_GP"
set +e
git -C "$TMP_FF_DEEP" merge --ff-only "$FF_DEEP_SHA" >/dev/null 2>"$LOGDIR/ff-deep.err"
FF_DEEP_RC=$?
set -e
FF_DEEP_HEAD=$(git -C "$TMP_FF_DEEP" rev-parse HEAD)
if [[ "$FF_DEEP_RC" -eq 0 && "$FF_DEEP_HEAD" == "$FF_DEEP_SHA" ]]; then
    assert "deeper ancestor FF onto witnessed merge" "kept" "kept"
else
    FF_DEEP_ERR=$(tr '\n' ' ' <"$LOGDIR/ff-deep.err" || true)
    assert "deeper ancestor FF onto witnessed merge" "kept" \
        "moved(rc=$FF_DEEP_RC head=$FF_DEEP_HEAD want=$FF_DEEP_SHA err=$FF_DEEP_ERR)"
fi
fi

echo "── multi-commit linear fast-forward without merges is allowed ─"
setup_repo "$TMP_LINEAR_FF"
install_hook "$TMP_LINEAR_FF" "$HOOKS"
LF_A=$(git -C "$TMP_LINEAR_FF" rev-parse main)
LF_TREE=$(git -C "$TMP_LINEAR_FF" rev-parse 'main^{tree}')
LF_B=$(git -C "$TMP_LINEAR_FF" commit-tree "$LF_TREE" -p "$LF_A" -m "linear-b")
LF_C=$(git -C "$TMP_LINEAR_FF" commit-tree "$LF_TREE" -p "$LF_B" -m "linear-c")
set +e
git -C "$TMP_LINEAR_FF" update-ref refs/heads/main "$LF_C" "$LF_A" >/dev/null 2>"$LOGDIR/linear-ff.err"
LF_RC=$?
set -e
LF_HEAD=$(git -C "$TMP_LINEAR_FF" rev-parse main)
if [[ "$LF_RC" -eq 0 && "$LF_HEAD" == "$LF_C" ]]; then
    assert "multi-commit linear FF allowed" "allow" "allow"
else
    LF_ERR=$(tr '\n' ' ' <"$LOGDIR/linear-ff.err" || true)
    assert "multi-commit linear FF allowed" "allow" \
        "block(rc=$LF_RC head=$LF_HEAD err=$LF_ERR)"
fi

echo "── annotated-tag merge peels MERGE_HEAD and allows matching marker ─"
setup_repo "$TMP_ANNOTATED"
install_hook "$TMP_ANNOTATED" "$HOOKS"
mkdir -p "$TMP_ANNOTATED/.claude"
git -C "$TMP_ANNOTATED" checkout -q topic
git -C "$TMP_ANNOTATED" -c tag.gpgsign=false tag -a v-ann -m "annotated topic"
git -C "$TMP_ANNOTATED" checkout -q main
git -C "$TMP_ANNOTATED" merge --no-commit --no-ff v-ann >/dev/null 2>&1
ANN_HASH=$(staged_hash "$TMP_ANNOTATED")
git -C "$TMP_ANNOTATED" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$ANN_HASH" >"$TMP_ANNOTATED/.claude/litmus-passed.local"
set +e
git -C "$TMP_ANNOTATED" merge --no-ff v-ann --no-edit >"$LOGDIR/ann-merge.out" 2>"$LOGDIR/ann-merge.err"
ANN_RC=$?
set -e
ANN_HEAD=$(git -C "$TMP_ANNOTATED" log -1 --format=%s 2>/dev/null || true)
ANN_PARENTS=$(git -C "$TMP_ANNOTATED" log -1 --format=%P)
ANN_TAG_OID=$(git -C "$TMP_ANNOTATED" rev-parse v-ann)
ANN_COMMIT_OID=$(git -C "$TMP_ANNOTATED" rev-parse 'v-ann^{commit}')
if [[ "$ANN_RC" -eq 0 && "$ANN_HEAD" != "mainline" && "$ANN_TAG_OID" != "$ANN_COMMIT_OID" \
    && "$ANN_PARENTS" == *" $ANN_COMMIT_OID" ]]; then
    assert "annotated-tag merge allowed with peeled claim" "allow" "allow"
else
    ANN_ERR=$(tr '\n' ' ' <"$LOGDIR/ann-merge.err" || true)
    assert "annotated-tag merge allowed with peeled claim" "allow" \
        "block(rc=$ANN_RC head=$ANN_HEAD tag=$ANN_TAG_OID commit=$ANN_COMMIT_OID parents=$ANN_PARENTS err=$ANN_ERR)"
fi

# An interrupted post-publication cleanup retires ARM and the claim before the
# spent marker, so spent can survive alone. Refusing that state blocked every
# later reference transaction in the repository, permanently.
echo "── orphan spent marker naming the live tip is retired ─"
setup_repo "$TMP_SPENT_ORPHAN"
install_hook "$TMP_SPENT_ORPHAN" "$HOOKS"
SO_GD=$(git -C "$TMP_SPENT_ORPHAN" rev-parse --absolute-git-dir)
SO_OLD=$(git -C "$TMP_SPENT_ORPHAN" rev-parse main)
SO_TREE=$(git -C "$TMP_SPENT_ORPHAN" rev-parse 'main^{tree}')
SO_NEW=$(git -C "$TMP_SPENT_ORPHAN" commit-tree "$SO_TREE" -p "$SO_OLD" -m "after publish")
printf '%s\n' "$SO_OLD" >"$SO_GD/busdriver-merge-litmus-spent"
set +e
git -C "$TMP_SPENT_ORPHAN" update-ref refs/heads/main "$SO_NEW" "$SO_OLD" >/dev/null 2>"$LOGDIR/spent-orphan.err"
SO_RC=$?
set -e
SO_HEAD=$(git -C "$TMP_SPENT_ORPHAN" rev-parse main)
if [[ "$SO_RC" -eq 0 && "$SO_HEAD" == "$SO_NEW" && ! -f "$SO_GD/busdriver-merge-litmus-spent" ]]; then
    assert "orphan spent at live tip retired" "allow" "allow"
else
    SO_ERR=$(tr '\n' ' ' <"$LOGDIR/spent-orphan.err" || true)
    assert "orphan spent at live tip retired" "allow" \
        "block(rc=$SO_RC head=$SO_HEAD err=$SO_ERR)"
fi

# Adversarial on purpose: an UNRELATED valid marker is present. A cleanup that
# consumes the marker whenever one exists would both destroy that token and let
# the marker's presence decide the outcome — the gated party can create that file,
# so the decision must come from the protected spent record alone.
echo "── orphan spent marker naming a non-tip commit still blocks ─"
setup_repo "$TMP_SPENT_STALE"
install_hook "$TMP_SPENT_STALE" "$HOOKS"
mkdir -p "$TMP_SPENT_STALE/.claude"
SS_GD=$(git -C "$TMP_SPENT_STALE" rev-parse --absolute-git-dir)
SS_OLD=$(git -C "$TMP_SPENT_STALE" rev-parse main)
SS_TREE=$(git -C "$TMP_SPENT_STALE" rev-parse 'main^{tree}')
SS_NEW=$(git -C "$TMP_SPENT_STALE" commit-tree "$SS_TREE" -p "$SS_OLD" -m "after publish")
SS_TOPIC=$(git -C "$TMP_SPENT_STALE" rev-parse topic)
SS_FAKE_HASH=$(printf 'a%.0s' {1..64})
printf '%s\n' "$SS_TOPIC" >"$SS_GD/busdriver-merge-litmus-spent"
printf 'BUILTIN-%s\n' "$SS_FAKE_HASH" >"$TMP_SPENT_STALE/.claude/litmus-passed.local"
set +e
git -C "$TMP_SPENT_STALE" update-ref refs/heads/main "$SS_NEW" "$SS_OLD" >/dev/null 2>"$LOGDIR/spent-stale.err"
SS_RC=$?
set -e
SS_HEAD=$(git -C "$TMP_SPENT_STALE" rev-parse main)
SS_ERR=$(tr '\n' ' ' <"$LOGDIR/spent-stale.err" || true)
# A non-zero exit alone is not evidence the GATE refused: a broken fixture or an
# unrelated git failure produces one too. Require the gate's own message — and
# specifically THIS branch's message, not the generic refusal, so the case cannot
# pass on some other rule of the gate happening to refuse first.
if [[ "$SS_RC" -ne 0 && "$SS_HEAD" == "$SS_OLD" \
      && "$SS_ERR" == *"could not clear stale merge authorization state"* ]]; then
    assert "orphan spent at non-tip blocks" "block" "block"
else
    assert "orphan spent at non-tip blocks" "block" \
        "allow(rc=$SS_RC head=$SS_HEAD err=$SS_ERR)"
fi
if [[ -f "$TMP_SPENT_STALE/.claude/litmus-passed.local" ]]; then
    assert "stale spent cleanup leaves an unbound marker alone" "kept" "kept"
else
    assert "stale spent cleanup leaves an unbound marker alone" "kept" "consumed"
fi

# An armed claim whose token has been REPLACED on disk — a later /litmus minted a
# different marker — must still retire, and must leave that marker alone. It is
# not this claim's to destroy: retiring the claim already tightens the gate, and
# consuming the newer token would silently revoke a review the operator just ran.
echo "── armed-claim retirement keeps a foreign marker ─"
setup_repo "$TMP_FOREIGN_MARKER"
mkdir -p "$TMP_FOREIGN_MARKER/.claude"
FM_HASH=$(printf 'b%.0s' {1..64})
FM_OTHER=$(printf 'c%.0s' {1..64})
printf 'BUILTIN-%s\n' "$FM_HASH" >"$TMP_FOREIGN_MARKER/.claude/litmus-passed.local"
FM_HEAD=$(git -C "$TMP_FOREIGN_MARKER" rev-parse HEAD)
set +e
FM_OUT=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
from merge_pending import write_claim
print("armed" if write_claim(sys.argv[2], ".claude", sys.argv[4], sys.argv[3]) else "arm-failed")
' "$REPO_ROOT/hooks/gate-scripts/lib" "$TMP_FOREIGN_MARKER" "BUILTIN-$FM_HASH" "$FM_HEAD" 2>&1)
set -e
if [[ "$FM_OUT" == "armed" ]]; then
    printf 'BUILTIN-%s\n' "$FM_OTHER" >"$TMP_FOREIGN_MARKER/.claude/litmus-passed.local"
    set +e
    FM_CLEAR=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
from merge_pending import clear_stale_abort_state
print("cleared" if clear_stale_abort_state(sys.argv[2], ".claude") else "refused")
' "$REPO_ROOT/hooks/gate-scripts/lib" "$TMP_FOREIGN_MARKER" 2>&1)
    set -e
    FM_LEFT=$(cat "$TMP_FOREIGN_MARKER/.claude/litmus-passed.local" 2>/dev/null || echo MISSING)
    if [[ "$FM_CLEAR" == "cleared" && "$FM_LEFT" == "BUILTIN-$FM_OTHER" ]]; then
        assert "armed-claim retirement keeps a foreign marker" "kept" "kept"
    else
        assert "armed-claim retirement keeps a foreign marker" "kept" \
            "clear=$FM_CLEAR marker=$FM_LEFT"
    fi
else
    assert "armed-claim retirement keeps a foreign marker" "kept" "setup-failed($FM_OUT)"
fi

# The gate parses commit headers itself; git frames them with LF only, so a CR is
# junk that `splitlines` would read as a header boundary — `junk\rparent <oid>`
# would invent a parent. The CR must sit in a header git ITSELF accepts: a CR in a
# `parent` line is rejected by git ("bad parents in commit") before the
# reference-transaction hook is invoked at all, so that spelling asserts git's
# behaviour and passes against an empty gate. Asserting the gate's own message is
# what keeps this test bound to the guard rather than to git.
echo "── CR inside a commit header is refused as unparseable framing ─"
setup_repo "$TMP_CR_HEADER"
install_hook "$TMP_CR_HEADER" "$HOOKS"
CR_OLD=$(git -C "$TMP_CR_HEADER" rev-parse main)
CR_TREE=$(git -C "$TMP_CR_HEADER" rev-parse 'main^{tree}')
CR_FAKE=$(printf 'b%.0s' {1..40})
CR_RAW=$(printf 'tree %s\nparent %s\nauthor t <t@t.dev> 0 +0000\ncommitter t <t@t.dev> 0 +0000\njunkhdr x\rparent %s\n\ncr header\n' \
    "$CR_TREE" "$CR_OLD" "$CR_FAKE")
CR_NEW=$(printf '%s' "$CR_RAW" | git -C "$TMP_CR_HEADER" hash-object -t commit -w --literally --stdin)
set +e
git -C "$TMP_CR_HEADER" update-ref refs/heads/main "$CR_NEW" "$CR_OLD" >/dev/null 2>"$LOGDIR/cr-header.err"
CR_RC=$?
set -e
CR_HEAD=$(git -C "$TMP_CR_HEADER" rev-parse main)
CR_ERR=$(tr '\n' ' ' <"$LOGDIR/cr-header.err" || true)
if [[ "$CR_RC" -ne 0 && "$CR_HEAD" == "$CR_OLD" && "$CR_ERR" == *"merge reference-transaction gate:"* ]]; then
    assert "CR in commit header refused by the gate" "block" "block"
else
    assert "CR in commit header refused by the gate" "block" \
        "allow(rc=$CR_RC head=$CR_HEAD err=$CR_ERR)"
fi

# The validator hashes with the canonical minting expression; core.quotePath alone
# re-spells a non-ASCII path, so a divergent validator can never match a real marker.
echo "── merge touching a non-ASCII path authorizes with a matching marker ─"
setup_repo "$TMP_UTF8_PATH"
install_hook "$TMP_UTF8_PATH" "$HOOKS"
mkdir -p "$TMP_UTF8_PATH/.claude"
git -C "$TMP_UTF8_PATH" checkout -q topic
printf 'accented\n' >"$TMP_UTF8_PATH/café.txt"
git -C "$TMP_UTF8_PATH" add "café.txt"
git -C "$TMP_UTF8_PATH" commit -q -m "utf8 path" --no-verify
git -C "$TMP_UTF8_PATH" checkout -q main
git -C "$TMP_UTF8_PATH" merge --no-commit --no-ff topic >/dev/null 2>&1
U8_HASH=$(staged_hash "$TMP_UTF8_PATH")
git -C "$TMP_UTF8_PATH" merge --abort >/dev/null 2>&1
printf 'BUILTIN-%s\n' "$U8_HASH" >"$TMP_UTF8_PATH/.claude/litmus-passed.local"
set +e
git -C "$TMP_UTF8_PATH" merge --no-ff topic --no-edit >/dev/null 2>"$LOGDIR/utf8-merge.err"
U8_RC=$?
set -e
U8_PARENTS=$(git -C "$TMP_UTF8_PATH" log -1 --format=%P)
if [[ "$U8_RC" -eq 0 && "$U8_PARENTS" == *" "* ]]; then
    assert "non-ASCII path merge authorized" "allow" "allow"
else
    U8_ERR=$(tr '\n' ' ' <"$LOGDIR/utf8-merge.err" || true)
    assert "non-ASCII path merge authorized" "allow" \
        "block(rc=$U8_RC parents=$U8_PARENTS err=$U8_ERR)"
fi


# A backward move rewinds the ref into its OWN published history, so there is
# nothing to authorize. Refusing it broke `git reset --hard HEAD~1` and also
# _rollback_merge's undo update-ref. The root-commit case is separate: NEW then
# has zero parents, which the zero-parent rule refuses unless the backward rule
# is reached first.
echo "── backward ref moves are allowed (incl. onto the root commit) ─"
setup_repo "$TMP_BACKWARD"
# setup_repo leaves main two commits deep, so `main^` IS the root and both moves
# below would land there — the second on identical old and new OIDs, a no-op that
# asserts nothing. A third commit (before the hook is installed, so making it is
# not itself gated) gives root -> mid -> tip, and the guard under it keeps the
# case from degenerating back to that silently.
echo third >"$TMP_BACKWARD/third.txt"
git -C "$TMP_BACKWARD" add third.txt
git -C "$TMP_BACKWARD" commit -q -m third --no-verify
install_hook "$TMP_BACKWARD" "$HOOKS"
BW_ROOT=$(git -C "$TMP_BACKWARD" rev-list --max-parents=0 main | head -1)
BW_TIP=$(git -C "$TMP_BACKWARD" rev-parse main)
BW_MID=$(git -C "$TMP_BACKWARD" rev-parse 'main^')
if [[ "$BW_MID" != "$BW_ROOT" && "$BW_MID" != "$BW_TIP" ]]; then
    assert "backward fixture has a non-root midpoint" "distinct" "distinct"
else
    assert "backward fixture has a non-root midpoint" "distinct" \
        "root=$BW_ROOT mid=$BW_MID tip=$BW_TIP"
fi
set +e
git -C "$TMP_BACKWARD" update-ref refs/heads/main "$BW_MID" "$BW_TIP" >/dev/null 2>"$LOGDIR/bw1.err"
BW_RC1=$?
set -e
BW_AT1=$(git -C "$TMP_BACKWARD" rev-parse main)
set +e
git -C "$TMP_BACKWARD" update-ref refs/heads/main "$BW_ROOT" "$BW_AT1" >/dev/null 2>"$LOGDIR/bw2.err"
BW_RC2=$?
set -e
BW_AT2=$(git -C "$TMP_BACKWARD" rev-parse main)
if [[ "$BW_RC1" -eq 0 && "$BW_AT1" == "$BW_MID" ]]; then
    assert "backward move onto a non-root commit allowed" "allow" "allow"
else
    assert "backward move onto a non-root commit allowed" "allow" "block(rc=$BW_RC1 at=$BW_AT1)"
fi
if [[ "$BW_RC2" -eq 0 && "$BW_AT2" == "$BW_ROOT" ]]; then
    assert "backward move onto root commit allowed" "allow" "allow"
else
    BW_ERR2=$(tr '\n' ' ' <"$LOGDIR/bw2.err" || true)
    assert "backward move onto root commit allowed" "allow" \
        "block(rc=$BW_RC2 at=$BW_AT2 err=$BW_ERR2)"
fi

# The backward rule must not become a general "any move to a commit that exists"
# allow: a sideways move to unrelated ancestry is still unreviewed publication.
echo "── divergent sideways move is still refused ─"
setup_repo "$TMP_DIVERGENT"
install_hook "$TMP_DIVERGENT" "$HOOKS"
DV_BASE=$(git -C "$TMP_DIVERGENT" rev-list --max-parents=0 main | head -1)
DV_OLD=$(git -C "$TMP_DIVERGENT" rev-parse main)
DV_TREE=$(git -C "$TMP_DIVERGENT" rev-parse "$DV_BASE^{tree}")
DV_D1=$(git -C "$TMP_DIVERGENT" commit-tree "$DV_TREE" -p "$DV_BASE" -m div1)
DV_D2=$(git -C "$TMP_DIVERGENT" commit-tree "$DV_TREE" -p "$DV_D1" -m div2)
set +e
git -C "$TMP_DIVERGENT" update-ref refs/heads/main "$DV_D2" "$DV_OLD" >/dev/null 2>"$LOGDIR/div.err"
DV_RC=$?
set -e
DV_AT=$(git -C "$TMP_DIVERGENT" rev-parse main)
if [[ "$DV_RC" -ne 0 && "$DV_AT" == "$DV_OLD" ]]; then
    assert "divergent sideways move refused" "block" "block"
else
    assert "divergent sideways move refused" "block" "allow(rc=$DV_RC at=$DV_AT)"
fi

# PASS-MERGE is the empty-resolution token: litmus mints it for a merge whose
# resolution changed nothing, so authorize_pass_merge must bind staged tree ==
# HEAD^{tree} and spend the marker exactly once.
echo "── PASS-MERGE authorizes an empty-resolution merge and is consumed ─"
setup_repo "$TMP_PASSMERGE"
install_hook "$TMP_PASSMERGE" "$HOOKS"
mkdir -p "$TMP_PASSMERGE/.claude"
PM_NOW=$(date +%s)
printf 'PASS-MERGE-%s\n' "$PM_NOW" >"$TMP_PASSMERGE/.claude/litmus-passed.local"
# `-s ours` is the canonical empty resolution: two real parents, tree identical to
# HEAD's, so `git diff --cached` is empty and PASS-MERGE is the only marker that
# can authorize it.
set +e
git -C "$TMP_PASSMERGE" merge --no-ff -s ours topic --no-edit >/dev/null 2>"$LOGDIR/passmerge.err"
PM_RC=$?
set -e
PM_PARENTS=$(git -C "$TMP_PASSMERGE" log -1 --format=%P | wc -w | tr -d ' ')
PM_HEAD_TREE=$(git -C "$TMP_PASSMERGE" rev-parse 'HEAD^{tree}')
PM_PARENT_TREE=$(git -C "$TMP_PASSMERGE" rev-parse 'HEAD^1^{tree}')
if [[ "$PM_RC" -eq 0 && "$PM_PARENTS" -eq 2 && "$PM_HEAD_TREE" == "$PM_PARENT_TREE" ]]; then
    assert "PASS-MERGE authorizes empty-resolution merge" "allow" "allow"
else
    PM_ERR=$(tr '\n' ' ' <"$LOGDIR/passmerge.err" || true)
    assert "PASS-MERGE authorizes empty-resolution merge" "allow" \
        "block(rc=$PM_RC parents=$PM_PARENTS err=$PM_ERR)"
fi
if [[ ! -f "$TMP_PASSMERGE/.claude/litmus-passed.local" ]]; then
    assert "PASS-MERGE marker consumed exactly once" "consumed" "consumed"
else
    assert "PASS-MERGE marker consumed exactly once" "consumed" "still-present"
fi

# The same token against a merge with a REAL resolution must be refused — and the
# token must survive. It authorizes only a write-tree == HEAD^{tree} merge, which
# Python enforces, so keeping it grants nothing; destroying it would revoke a
# review on every unrelated reason authorize_pass_merge can return false (a lost
# index race, a failed claim write), which the shell cannot tell apart from this.
echo "── PASS-MERGE against a non-empty resolution is refused, marker kept ─"
setup_repo "$TMP_PM_NONEMPTY"
install_hook "$TMP_PM_NONEMPTY" "$HOOKS"
mkdir -p "$TMP_PM_NONEMPTY/.claude"
printf 'PASS-MERGE-%s\n' "$(date +%s)" >"$TMP_PM_NONEMPTY/.claude/litmus-passed.local"
set +e
git -C "$TMP_PM_NONEMPTY" merge --no-ff topic --no-edit >/dev/null 2>"$LOGDIR/pm-nonempty.err"
PMN_RC=$?
set -e
PMN_PARENTS=$(git -C "$TMP_PM_NONEMPTY" log -1 --format=%P | wc -w | tr -d ' ')
PMN_ERR=$(tr '\n' ' ' <"$LOGDIR/pm-nonempty.err" || true)
# Same reason as the non-tip case above, and it matters more here: `git merge`
# fails for plenty of reasons that have nothing to do with this gate. The message
# is the validator's, not the RT gate's — this refusal happens in the commit
# chain, before any ref moves.
if [[ "$PMN_RC" -ne 0 && "$PMN_PARENTS" -ne 2 \
      && "$PMN_ERR" == *"PASS-MERGE review marker present but it did not authorize this merge"* ]]; then
    assert "PASS-MERGE against a real resolution refused" "block" "block"
else
    assert "PASS-MERGE against a real resolution refused" "block" \
        "allow(rc=$PMN_RC parents=$PMN_PARENTS err=$PMN_ERR)"
fi
if [[ -f "$TMP_PM_NONEMPTY/.claude/litmus-passed.local" ]]; then
    assert "refused PASS-MERGE leaves the marker in place" "kept" "kept"
else
    assert "refused PASS-MERGE leaves the marker in place" "kept" "destroyed"
fi

# ── write_claim refuses a moved index instead of arming it ──────────────
# The hash-authorized paths used to publish the arm and only then confirm its
# tree, so between those two steps a valid claim named a tree nobody reviewed.
# Passing the reviewed tree in makes it one decision.
echo "── write_claim binds the reviewed tree ─"
TMP_AUTHTREE=$(mktemp -d)
setup_repo "$TMP_AUTHTREE"
mkdir -p "$TMP_AUTHTREE/.claude"
AT_HEAD=$(git -C "$TMP_AUTHTREE" rev-parse HEAD)
AT_HASH=$(printf 'd%.0s' {1..64})
AT_REVIEWED=$(git -C "$TMP_AUTHTREE" rev-parse "HEAD^{tree}")   # the tree we "reviewed"
echo "drift" > "$TMP_AUTHTREE/drift.txt"                       # index moves on
git -C "$TMP_AUTHTREE" add drift.txt
set +e
AT_OUT=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
from merge_pending import write_claim
print("armed" if write_claim(sys.argv[2], ".claude", sys.argv[4], sys.argv[3], sys.argv[5]) else "refused")
' "$REPO_ROOT/hooks/gate-scripts/lib" "$TMP_AUTHTREE" "BUILTIN-$AT_HASH" "$AT_HEAD" "$AT_REVIEWED" 2>&1)
set -e
assert "a live index that moved off the reviewed tree is refused" "refused" "$AT_OUT"
if [[ -f "$TMP_AUTHTREE/.claude/merge-litmus-pending.local" ]]; then
    assert "no claim is left armed after the refusal" "none" "armed"
else
    assert "no claim is left armed after the refusal" "none" "none"
fi
rm -rf "$TMP_AUTHTREE"

# ── operator skip consumes before it arms ───────────────────────────────
# authorize_pass_merge already spends first and arms second. The skip path did
# the reverse, leaving a window where a valid arm existed while the skip inode
# was still on disk: a concurrent transaction spends the arm, the consume then
# fails, and the skip survives to be reused after aging. Forced here by making
# the claim write fail: with consume-first the skip is gone and no claim exists.
echo "── operator skip spends the inode before arming ─"
TMP_SKIPORD=$(mktemp -d)
setup_repo "$TMP_SKIPORD"
mkdir -p "$TMP_SKIPORD/.claude"
SO_HEAD=$(git -C "$TMP_SKIPORD" rev-parse HEAD)
SO_HASH=$(printf 'e%.0s' {1..64})
: > "$TMP_SKIPORD/.claude/skip-litmus.local"
mkdir -p "$TMP_SKIPORD/.claude/merge-litmus-pending.local.tmp"   # makes the claim write fail
# The age gate reads ctime and birthtime as well as mtime, and the parent dir's
# ctime too, so no fixture can mint a consumable skip without really waiting it
# out. Only the OPEN is stubbed; finish_skip_consume runs for real, which is the
# half this case is about. Age policy has its own coverage in skip_age tests.
set +e
python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import merge_pending as mp
mp.open_skip_for_authorization = lambda dfd, name=mp.SKIP: os.open(
    name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
mp.authorize_operator_skip(sys.argv[2], ".claude", "pre-commit", sys.argv[4], sys.argv[3])
' "$REPO_ROOT/hooks/gate-scripts/lib" "$TMP_SKIPORD" "BUILTIN-$SO_HASH" "$SO_HEAD" >/dev/null 2>&1
set -e
if [[ -f "$TMP_SKIPORD/.claude/skip-litmus.local" ]]; then
    assert "a failed arm still spent the skip inode" "spent" "survived"
else
    assert "a failed arm still spent the skip inode" "spent" "spent"
fi
if [[ -f "$TMP_SKIPORD/.claude/merge-litmus-pending.local" ]]; then
    assert "a failed arm leaves no claim behind" "none" "armed"
else
    assert "a failed arm leaves no claim behind" "none" "none"
fi
rm -rf "$TMP_SKIPORD"

# ── write_claim binds the reviewed HEAD, not a later one ────────────────
# The digest is taken against an implicit base, so it pins the diff but not the
# commit it came from. Re-reading HEAD at claim time let an ordinary ref update
# swap H1 for H2 and arm a head nobody reviewed.
echo "── write_claim binds the reviewed HEAD ─"
TMP_AUTHHEAD=$(mktemp -d)
setup_repo "$TMP_AUTHHEAD"
mkdir -p "$TMP_AUTHHEAD/.claude"
AH_REVIEWED_HEAD=$(git -C "$TMP_AUTHHEAD" rev-parse HEAD)
AH_TREE=$(git -C "$TMP_AUTHHEAD" rev-parse "HEAD^{tree}")
AH_HASH=$(printf 'f%.0s' {1..64})
# HEAD moves after the hash, exactly as a concurrent ordinary commit would.
git -C "$TMP_AUTHHEAD" commit -q --allow-empty -m "concurrent ordinary commit"
AH_MOVED=$(git -C "$TMP_AUTHHEAD" rev-parse HEAD)
set +e
AH_OUT=$(python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
from merge_pending import write_claim
print("armed" if write_claim(sys.argv[2], ".claude", sys.argv[4], sys.argv[3], sys.argv[5], sys.argv[4]) else "refused")
' "$REPO_ROOT/hooks/gate-scripts/lib" "$TMP_AUTHHEAD" "BUILTIN-$AH_HASH" "$AH_REVIEWED_HEAD" "$AH_TREE" 2>&1)
set -e
assert "a HEAD that moved after the review hash is refused" "refused" "$AH_OUT"
if [[ "$AH_REVIEWED_HEAD" == "$AH_MOVED" ]]; then
    assert "the fixture really moved HEAD" "moved" "unchanged"
else
    assert "the fixture really moved HEAD" "moved" "moved"
fi
rm -rf "$TMP_AUTHHEAD"

# ── fast-forward past an already-published merge ────────────────────────
# linear mode refuses at the first merge it meets, and the witnessed-FF rule
# used to be reachable only when NEW itself had two parents. So the identical
# history was allowed when the tip WAS the merge and refused once one ordinary
# commit sat on top -- a verdict that depended on the shape of the tip rather
# than on whether the move was a real fast-forward.
echo "── FF past a published merge ─"
TMP_FFMERGE=$(mktemp -d)
(
  cd "$TMP_FFMERGE" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && MAIN=$(git symbolic-ref --short HEAD) \
    && echo a>a && git add . && git commit -q -m A && git rev-parse HEAD > ../A \
    && git checkout -q -b side && echo s>s && git add . && git commit -q -m S \
    && git checkout -q -b topic "$MAIN" && echo t>t && git add . && git commit -q -m T \
    && git merge -q --no-ff side -m "published merge" \
    && echo o>o && git add . && git commit -q -m ord && git rev-parse HEAD > ../C \
    && echo "$MAIN" > ../MAIN
) >/dev/null 2>&1
FF_A=$(cat "$TMP_FFMERGE/A"); FF_C=$(cat "$TMP_FFMERGE/C"); FF_MAIN=$(cat "$TMP_FFMERGE/MAIN")
FF_GATE="$REPO_ROOT/hooks/gate-scripts/merge-reference-transaction-gate.sh"
set +e
( cd "$TMP_FFMERGE/r" && printf '%s %s refs/heads/%s\n' "$FF_A" "$FF_C" "$FF_MAIN" \
    | bash "$FF_GATE" prepared ) >/dev/null 2>&1
FF_RC=$?
set -e
assert "FF onto an ordinary commit above a published merge is allowed" "0" "$FF_RC"

# Negatives: the unified rule must not become a hole.
set +e
( cd "$TMP_FFMERGE/r" && git checkout -q --detach >/dev/null 2>&1
  git branch -D topic >/dev/null 2>&1; git branch -D side >/dev/null 2>&1
  printf '%s %s refs/heads/%s\n' "$FF_A" "$FF_C" "$FF_MAIN" | bash "$FF_GATE" prepared ) >/dev/null 2>&1
FF_UNWIT=$?
set -e
assert "the same NEW is refused when no branch witnesses it" "1" "$FF_UNWIT"
rm -rf "$TMP_FFMERGE"

# ── message-only amend of a merge commit ────────────────────────────────
# MERGE_HEAD is gone, the amended commit is not in OLD's ancestry, OLD is not
# its ancestor, and no branch witnesses an OID this very update would create --
# so every other rule misses it and there was no path to success at all.
echo "── amend of a merge commit ─"
TMP_AMEND=$(mktemp -d)
AM_GATE="$REPO_ROOT/hooks/gate-scripts/merge-reference-transaction-gate.sh"
(
  cd "$TMP_AMEND" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && MAIN=$(git symbolic-ref --short HEAD) && echo "$MAIN" > ../MAIN \
    && echo a>a && git add . && git commit -q -m A && git rev-parse HEAD > ../A \
    && git checkout -q -b side && echo s>s && git add . && git commit -q -m S \
    && git rev-parse HEAD > ../S \
    && git checkout -q "$MAIN" && echo m>m && git add . && git commit -q -m M \
    && git merge -q --no-ff side -m original && git rev-parse HEAD > ../OLD \
    && git commit -q --amend -m reworded && git rev-parse HEAD > ../NEW
) >/dev/null 2>&1
AM_MAIN=$(cat "$TMP_AMEND/MAIN"); AM_OLD=$(cat "$TMP_AMEND/OLD"); AM_NEW=$(cat "$TMP_AMEND/NEW")
set +e
( cd "$TMP_AMEND/r" && printf '%s %s refs/heads/%s\n' "$AM_OLD" "$AM_NEW" "$AM_MAIN" \
    | bash "$AM_GATE" prepared ) >/dev/null 2>&1
AM_RC=$?
set -e
assert "a message-only amend of a merge commit is allowed" "0" "$AM_RC"

# Negative: a replacement with a DIFFERENT parent set introduces a merge and must refuse.
AM_A=$(cat "$TMP_AMEND/A"); AM_S=$(cat "$TMP_AMEND/S")
set +e
AM_BAD_RC=$( cd "$TMP_AMEND/r" \
  && AM_TREE=$(git rev-parse "$AM_OLD^{tree}") \
  && AM_FORGED=$(git commit-tree "$AM_TREE" -p "$AM_A" -p "$AM_S" -m forged) \
  && printf '%s %s refs/heads/%s\n' "$AM_OLD" "$AM_FORGED" "$AM_MAIN" \
     | bash "$AM_GATE" prepared >/dev/null 2>&1; echo $? )
set -e
assert "a replacement with a different parent set is refused" "1" "$AM_BAD_RC"

# Negative: SAME parents, DIFFERENT tree. The exemption exists for a commit that
# differs only in message or authorship; comparing parents alone made it an
# authorization for arbitrary content, since `commit-tree <anything> -p P1 -p S`
# reproduces a reviewed merge's parent set exactly and update-ref fires no
# commit-chain hook. This is the assertion that distinguishes the two.
set +e
AM_TREE_RC=$( cd "$TMP_AMEND/r" \
  && AM_EVIL=$(git rev-parse "$AM_S^{tree}") \
  && AM_OLD_P1=$(git rev-parse "$AM_OLD^1") && AM_OLD_P2=$(git rev-parse "$AM_OLD^2") \
  && AM_RETREE=$(git commit-tree "$AM_EVIL" -p "$AM_OLD_P1" -p "$AM_OLD_P2" -m "same parents, new tree") \
  && printf '%s %s refs/heads/%s\n' "$AM_OLD" "$AM_RETREE" "$AM_MAIN" \
     | bash "$AM_GATE" prepared >/dev/null 2>&1; echo $? )
set -e
assert "a replacement keeping the parents but changing the tree is refused" "1" "$AM_TREE_RC"

# ...but ONLY for merge replacements. An ordinary single-parent `git commit --amend`
# with changed content must still pass: the gate authorizes MERGE tips, and a
# non-merge tip is refused at the `parents -ge 2` floor BEFORE any claim or marker is
# consulted -- so blocking it here leaves no path to success at all, which re-creates
# the dead end this gate already had to remove once.
TMP_ORD=$(mktemp -d)
(
  cd "$TMP_ORD" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && MAIN=$(git symbolic-ref --short HEAD) && echo "$MAIN" > ../MAIN \
    && echo a>a && git add . && git commit -q -m A \
    && echo b>b && git add . && git commit -q -m B && git rev-parse HEAD > ../OLD \
    && echo more >> b && git add b && git commit -q --amend -m "B fixed" \
    && git rev-parse HEAD > ../NEW
) >/dev/null 2>&1
ORD_MAIN=$(cat "$TMP_ORD/MAIN"); ORD_OLD=$(cat "$TMP_ORD/OLD"); ORD_NEW=$(cat "$TMP_ORD/NEW")
# Guard against a vacuous pass: the amend must really have changed the tree.
assert "the ordinary amend actually changed the tree (else the case proves nothing)" "differ" \
    "$( cd "$TMP_ORD/r" && [ "$(git rev-parse "$ORD_OLD^{tree}")" != "$(git rev-parse "$ORD_NEW^{tree}")" ] && echo differ || echo same )"
set +e
ORD_RC=$( cd "$TMP_ORD/r" \
  && printf '%s %s refs/heads/%s\n' "$ORD_OLD" "$ORD_NEW" "$ORD_MAIN" \
     | bash "$AM_GATE" prepared >/dev/null 2>&1; echo $? )
set -e
assert "an ordinary single-parent amend with changed content is allowed" "0" "$ORD_RC"
rm -rf "$TMP_ORD"
rm -rf "$TMP_AMEND"

# ── forged commit headers ───────────────────────────────────────────────
# Git reads parents only in the LEADING header block and stops at the first other
# header, so a "parent" line placed after the committer is message text to git and
# a parent to a naive scan. Two consequences, both exercised here.
echo "── forged commit headers ─"
TMP_FORGE=$(mktemp -d)
FG_GATE="$REPO_ROOT/hooks/gate-scripts/merge-reference-transaction-gate.sh"
(
  cd "$TMP_FORGE" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && MAIN=$(git symbolic-ref --short HEAD) && echo "$MAIN" > ../MAIN \
    && echo a>a && git add . && git commit -q -m A && git rev-parse HEAD > ../A \
    && git checkout -q -b side && echo s>s && git add . && git commit -q -m S \
    && git rev-parse HEAD > ../S \
    && git checkout -q "$MAIN" && echo m>m && git add . && git commit -q -m M \
    && git merge -q --no-ff side -m merged && git rev-parse HEAD > ../OLD \
    && git rev-parse HEAD^1 > ../P1 && git rev-parse "HEAD^{tree}" > ../TREE
) >/dev/null 2>&1
FG_MAIN=$(cat "$TMP_FORGE/MAIN"); FG_OLD=$(cat "$TMP_FORGE/OLD")
FG_P1=$(cat "$TMP_FORGE/P1"); FG_S=$(cat "$TMP_FORGE/S"); FG_TREE=$(cat "$TMP_FORGE/TREE")

# 1. Command injection. The parser joins its fields with "|" and the gate re-splits
# on it, so a parent value carrying a "|" shifts every field and lands attacker text
# in $parents -- which four tests then evaluate as ARITHMETIC, and bash arithmetic
# runs a command substitution inside an array subscript. The commit below is a valid
# ROOT commit to git (no parent in the leading block), which is what makes it
# storable and referenceable in the first place.
# The subscript names G, an array the gate really has in scope: `set -u` aborts on an
# UNSET name before the subscript is expanded, so an unset one would make this pass
# without ever exercising the defect.
FG_SENTINEL="$TMP_FORGE/EXECUTED"
rm -f "$FG_SENTINEL"
# Heredoc, not printf: the payload itself contains a command substitution, and a
# format string carrying both that and %s is one quoting slip away from writing an
# empty file -- which git rejects as an unterminated header, passing the case for
# the wrong reason. "\$(" stays literal here; only the two named variables expand.
cat > "$TMP_FORGE/inj" <<EOF
tree $FG_TREE
author A <a@b> 1 +0000
committer A <a@b> 1 +0000
parent x|G[\$(touch $FG_SENTINEL)0]

x
EOF
set +e
FG_INJ=$( cd "$TMP_FORGE/r" && git hash-object -t commit -w --stdin < ../inj 2>/dev/null )
set -e
# Guard against a vacuous pass: if the object was never stored, nothing was tested.
assert "the forged commit object is storable (else the case proves nothing)" "40" "${#FG_INJ}"
set +e
FG_ERR=$( cd "$TMP_FORGE/r" \
  && printf '%s %s refs/heads/%s\n' "$FG_OLD" "$FG_INJ" "$FG_MAIN" \
     | bash "$FG_GATE" prepared 2>&1 >/dev/null )
FG_INJ_RC=$?
set -e
assert "a forged parent header carrying a shell metacharacter is refused" "1" "$FG_INJ_RC"
# THE forcing assertion. Pre-fix the gate also exits 1 -- by CRASHING on the poisoned
# arithmetic ("unbound variable") after the payload has already run -- so the status
# alone cannot tell a refusal from a bypass. These two can.
if [[ -e "$FG_SENTINEL" ]]; then
    assert "the forged header did not execute a command inside the gate" "absent" "EXECUTED"
else
    assert "the forged header did not execute a command inside the gate" "absent" "absent"
fi
case "$FG_ERR" in
    *"unbound variable"*|*"syntax error"*)
        assert "the refusal is a decision, not a crash on the poisoned value" "clean" "$FG_ERR" ;;
    *) assert "the refusal is a decision, not a crash on the poisoned value" "clean" "clean" ;;
esac

# 2. Parent-set forgery. Even an exact-hex fake parent must not count: a trailing
# "parent <S>" makes NEW's parsed parent set equal OLD's, and the amend rule exits 0
# on set equality -- so a single-parent commit with an arbitrary tree would be
# published as an "amend" of a reviewed merge.
FG_OTHER=$( cd "$TMP_FORGE/r" && git rev-parse "$FG_S^{tree}" )
cat > "$TMP_FORGE/setforge" <<EOF
tree $FG_OTHER
parent $FG_P1
author A <a@b> 1 +0000
committer A <a@b> 1 +0000
parent $FG_S

x
EOF
set +e
FG_FORGED=$( cd "$TMP_FORGE/r" && git hash-object -t commit -w --stdin < ../setforge 2>/dev/null )
set -e
assert "the parent-set forgery is storable (else the case proves nothing)" "40" "${#FG_FORGED}"
set +e
FG_SET_RC=$( cd "$TMP_FORGE/r" \
  && printf '%s %s refs/heads/%s\n' "$FG_OLD" "$FG_FORGED" "$FG_MAIN" \
     | bash "$FG_GATE" prepared >/dev/null 2>&1; echo $? )
set -e
assert "a fake trailing parent cannot forge parent-set equality" "1" "$FG_SET_RC"
rm -rf "$TMP_FORGE"

echo ""
printf "Results: %d/%d passed\n" "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
