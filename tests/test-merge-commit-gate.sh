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
#  11. Fast-forward onto a published merge tip keeps HEAD (with RT).
#  12. commit-tree + update-ref of an unpublished merge tip is refused.
#  13. A tag tip alone cannot witness merge publication onto a branch.
#  14. A symbolic head aliasing a tag cannot witness merge publication.
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
TMP_ANNOTATED=$(mktemp -d)
HOOKS=$(mktemp -d)
SHIM=$(mktemp -d)
EXTDIFF=$(mktemp -d)
LOGDIR=$(mktemp -d)
trap 'rm -rf "$TMP_BLOCK" "$TMP_ALLOW" "$TMP_PATH" "$TMP_NOCOMMIT" "$TMP_FF" "$TMP_EXTDIFF" "$TMP_CLAIM" "$TMP_ABORT" "$TMP_SPOOF" "$TMP_BASHENV" "$TMP_SKIP_AGE" "$TMP_SKNONE_STALE" "$TMP_SKNONE_CONTENT" "$TMP_SKNONE_OVERFLOW" "$TMP_SKNONE_FUTURE" "$TMP_SKNONE_LONG" "$TMP_SKNONE_BOUND" "$TMP_REPO_MARKER" "$TMP_FF_MERGE" "$TMP_CTREE" "$TMP_TAG_WITNESS" "$TMP_SYM_WITNESS" "$TMP_ANNOTATED" "$HOOKS" "$SHIM" "$EXTDIFF" "$LOGDIR"' EXIT

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
FF_PARENT=$(git -C "$TMP_FF_MERGE" rev-parse 'HEAD^1')
# Keep main at the reviewed merge; FF a lagging branch onto that published tip.
git -C "$TMP_FF_MERGE" checkout -qb behind "$FF_PARENT"
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

echo ""
printf "Results: %d/%d passed\n" "$PASS" "$TOTAL"
[[ "$FAIL" -eq 0 ]]
