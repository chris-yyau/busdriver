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
#   8. Abort after failed merge commit leaves marker for ordinary commits.
#   9. Spoofed GIT_REFLOG_ACTION does not prevent marker consumption.
#  10. Hostile BASH_ENV cannot bypass merge validation.
#
# Usage: bash tests/test-merge-commit-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."
unset BUSDRIVER_STATE_DIR

REPO_ROOT="$PWD"
GATE_SCRIPT="hooks/gate-scripts/pre-merge-commit-gate.sh"
POST_MERGE="hooks/gate-scripts/post-merge-consume-marker.sh"
MERGE_PRE_COMMIT="hooks/gate-scripts/merge-pre-commit-gate.sh"
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

# Match validator hash (scrubbed diff flags).
staged_hash() {
    git -C "$1" -c diff.external= diff --cached --no-ext-diff --no-textconv \
        | bash -c "source '$REPO_ROOT/$HASH_HELPER'; hash_stdin"
}

install_hook() {
    local repo="$1"
    local hooks_dir="$2"
    mkdir -p "$hooks_dir"
    ln -sf "$REPO_ROOT/$GATE_SCRIPT" "$hooks_dir/pre-merge-commit"
    ln -sf "$REPO_ROOT/$POST_MERGE" "$hooks_dir/post-merge"
    ln -sf "$REPO_ROOT/$MERGE_PRE_COMMIT" "$hooks_dir/pre-commit"
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
HOOKS=$(mktemp -d)
SHIM=$(mktemp -d)
EXTDIFF=$(mktemp -d)
LOGDIR=$(mktemp -d)
trap 'rm -rf "$TMP_BLOCK" "$TMP_ALLOW" "$TMP_PATH" "$TMP_NOCOMMIT" "$TMP_FF" "$TMP_EXTDIFF" "$TMP_CLAIM" "$TMP_ABORT" "$TMP_SPOOF" "$TMP_BASHENV" "$HOOKS" "$SHIM" "$EXTDIFF" "$LOGDIR"' EXIT

setup_repo "$TMP_BLOCK"
install_hook "$TMP_BLOCK" "$HOOKS"
mkdir -p "$TMP_BLOCK/.claude"

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

echo "── abort after failed merge commit keeps marker ─"
setup_repo "$TMP_ABORT"
install_hook "$TMP_ABORT" "$HOOKS"
mkdir -p "$TMP_ABORT/.claude/hooks"
printf '#!/bin/bash\nexit 1\n' >"$TMP_ABORT/.claude/hooks/commit-msg"
chmod +x "$TMP_ABORT/.claude/hooks/commit-msg"
git -C "$TMP_ABORT" config core.hooksPath "$TMP_ABORT/.claude/hooks"
ln -sf "$REPO_ROOT/$GATE_SCRIPT" "$TMP_ABORT/.claude/hooks/pre-merge-commit"
ln -sf "$REPO_ROOT/$POST_MERGE" "$TMP_ABORT/.claude/hooks/post-merge"
ln -sf "$REPO_ROOT/$MERGE_PRE_COMMIT" "$TMP_ABORT/.claude/hooks/pre-commit"
ln -sf "$REPO_ROOT/$MERGE_POST_COMMIT" "$TMP_ABORT/.claude/hooks/post-commit"
git -C "$TMP_ABORT" merge --no-commit topic >/dev/null 2>&1
ABORT_HASH=$(staged_hash "$TMP_ABORT")
printf 'BUILTIN-%s\n' "$ABORT_HASH" >"$TMP_ABORT/.claude/litmus-passed.local"
set +e
git -C "$TMP_ABORT" commit -q -m "finish merge" 2>"$LOGDIR/abort-fail.err"
set -e
git -C "$TMP_ABORT" merge --abort >/dev/null 2>&1
echo plain >"$TMP_ABORT/plain.txt"
git -C "$TMP_ABORT" add plain.txt
set +e
git -C "$TMP_ABORT" commit -q -m "plain commit" 2>"$LOGDIR/abort-plain.err"
set -e
# post-commit runs during commit; invoke again so stale pending cleanup is deterministic
(cd "$TMP_ABORT" && bash "$REPO_ROOT/$MERGE_POST_COMMIT") >/dev/null 2>&1 || true
if [[ ! -f "$TMP_ABORT/.claude/litmus-passed.local" ]]; then
    assert "abort then plain commit clears stale marker" "cleared" "cleared"
else
    assert "abort then plain commit clears stale marker" "cleared" "present"
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

echo ""
printf "Results: %d/%d passed\n" "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
