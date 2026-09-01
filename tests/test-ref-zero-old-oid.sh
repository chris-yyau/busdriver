#!/usr/bin/env bash
# Focused regression for issue #780 — ZERO-old-oid create vs force-update.
#
# At reference-transaction prepared, force-update and create both report
# old-oid=ZERO. The shared discriminator is prepared-time / pre-command
# `git rev-parse --verify` (githooks(5)): absent ⇒ genuine create (allow);
# present ⇒ force-update (abort). Deletes of protected refs abort so
# delete-then-recreate cannot re-mint the name.
#
# Covers: branch -f, checkout -B, update-ref without oldvalue, delete/recreate,
# and both files + reftable backends where supported.
#
# Usage: bash tests/test-ref-zero-old-oid.sh

# shellcheck disable=SC2310
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
GATE_SCRIPT="$REPO_ROOT/hooks/gate-scripts/ref-ff-gate.sh"

PASS=0
FAIL=0

ISO_STATE=".claude-test-780-$$"
export BUSDRIVER_STATE_DIR="$ISO_STATE"

TMPROOT=$(mktemp -d) || { printf 'could not create temp dir\n' >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

supports_reftable() {
    local d="$TMPROOT/reftable-probe"
    rm -rf "$d"
    git init -q -b main --ref-format=reftable "$d" 2>/dev/null || return 1
    rm -rf "$d"
    return 0
}

setup_repo() {  # <tag> <ref-format>
    local tag="$1" fmt="$2"
    REPO="$TMPROOT/repo-$tag"
    rm -rf "$REPO"
    (
        set -e
        if [ "$fmt" = reftable ]; then
            git init -q -b main --ref-format=reftable "$REPO"
        else
            # Default backend is files; avoid --ref-format=files (Git >= 2.45 only).
            git init -q -b main "$REPO"
        fi
        cd "$REPO"
        git config user.email t@t; git config user.name t
        git config commit.gpgsign false; git config tag.gpgsign false
        # Isolate from ambient core.hooksPath (e.g. ~/.codex/git-hooks).
        git config core.hooksPath "$(pwd)/.git/hooks"
        echo base > f; git add f; git commit -qm base
        echo next >> f; git add f; git commit -qm next
        UNREVIEWED=$(git rev-parse HEAD)
        git reset -q --hard HEAD~1
        git branch unreviewed "$UNREVIEWED"
        mkdir -p "$ISO_STATE"
    ) >/dev/null 2>&1 || return 1
    UNREVIEWED=$(git -C "$REPO" rev-parse unreviewed)
}

run_gate() {  # <name> <expected: allow|block> <command> [reason substring]
    local name="$1" expected="$2" cmd="$3" want_reason="${4:-}"
    local payload output exit_code got
    payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))' "$REPO" "$cmd")
    output=$(cd "$REPO_ROOT" && printf '%s' "$payload" | bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
    got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi
    if [[ "$got" != "$expected" ]]; then
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        printf "         output=%s\n" "$output"
        FAIL=$((FAIL + 1))
        return
    fi
    if [[ -n "$want_reason" ]] && ! grep -qF "$want_reason" <<<"$output"; then
        printf "  FAIL  %s (blocked, but reason missing %q)\n" "$name" "$want_reason"
        FAIL=$((FAIL + 1)); return
    fi
    printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
}

# Install a reference-transaction hook that uses the SAME discriminator the
# gate does, so files/reftable backends are exercised at the documented layer.
install_rt_hook() {
    local hookdir
    # MUST NOT use `git rev-parse --git-path hooks`: ambient core.hooksPath
    # (this machine points it at the primary checkout) would install into the
    # SHARED hooks dir and poison every other suite. Pin the repo-local path.
    hookdir="$REPO/.git/hooks"
    if [ -f "$REPO/.git" ]; then
        # linked worktree — read gitdir file; tests use plain inits only
        hookdir=$(git -C "$REPO" rev-parse --absolute-git-dir)/hooks
    fi
    # Neutralize hooksPath for THIS fixture so git runs the local hook.
    git -C "$REPO" config --local core.hooksPath "$hookdir"
    mkdir -p "$hookdir"
    cat > "$hookdir/reference-transaction" <<'HOOK'
#!/bin/bash
phase=$1
[ "$phase" = prepared ] || exit 0
while read -r old new ref; do
    case "$ref" in
        refs/heads/*) ;;
        *) continue ;;
    esac
    zero=0000000000000000000000000000000000000000
    zero64=0000000000000000000000000000000000000000000000000000000000000000
    # Delete of any heads ref (new=ZERO): abort — same as the gate for protected
    # names; here we exercise the discriminator for all heads.
    if [ "$new" = "$zero" ] || [ "$new" = "$zero64" ]; then
        echo "ref-zero-old-oid: refuse delete of $ref" >&2
        exit 1
    fi
    if [ "$old" = "$zero" ] || [ "$old" = "$zero64" ]; then
        if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
            echo "ref-zero-old-oid: refuse force-update of $ref (pre-image exists)" >&2
            exit 1
        fi
        # absent ⇒ genuine create — allow
    fi
done
exit 0
HOOK
    chmod +x "$hookdir/reference-transaction"
}

assert_git_fails() {  # <name> <git args...>
    local name="$1"; shift
    if git -C "$REPO" "$@" >/dev/null 2>&1; then
        printf "  FAIL  %s (git succeeded, expected abort)\n" "$name"
        FAIL=$((FAIL + 1))
    else
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    fi
}

assert_git_ok() {  # <name> <git args...>
    local name="$1"; shift
    if git -C "$REPO" "$@" >/dev/null 2>&1; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (git failed, expected success)\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

run_format_suite() {  # <format>
    local fmt="$1"
    printf '\n=== #780 ZERO-old-oid (%s) ===\n' "$fmt"
    setup_repo "$fmt" "$fmt" || { printf "  FAIL  fixture setup (%s)\n" "$fmt"; FAIL=$((FAIL + 1)); return; }

    # PreToolUse gate — the shipped observation point (same machinery as #779).
    run_gate "branch -f main → block" \
        block "git branch -f main $UNREVIEWED" "FORCE-UPDATE the protected branch"
    run_gate "checkout -B main → block" \
        block "git checkout -B main $UNREVIEWED" "FORCE-UPDATE the protected branch"
    run_gate "update-ref without oldvalue → block" \
        block "git update-ref refs/heads/main $UNREVIEWED" "FORCE-UPDATE the protected branch"
    run_gate "branch -D main → block (closes delete-recreate)" \
        block "git branch -D main" "DELETE the protected branch"
    run_gate "delete then recreate in one call → block on delete" \
        block "git branch -D main && git branch main $UNREVIEWED" "issue #780"
    run_gate "genuine create of newbranch → allow" \
        allow "git branch newbranch $UNREVIEWED"
    git -C "$REPO" branch topic HEAD
    # Porcelain force has no old-oid CAS; pre-command probe is TOCTOU, so
    # fail closed for every current-ref state (direct / absent / symref),
    # including non-protected topic names (files + reftable).
    run_gate "branch -f of non-protected topic → block" \
        block "git branch -f topic $UNREVIEWED" "FORCE-UPDATE the protected branch"

    # Off protected HEAD still blocks force of main.
    git -C "$REPO" checkout -q -b feature
    run_gate "branch -f main from feature branch → block" \
        block "git branch -f main $UNREVIEWED" "FORCE-UPDATE the protected branch"

    # reference-transaction layer — stay off main so Git itself does not reject
    # branch -f/-D of the checked-out branch (that would mask a missing hook).
    install_rt_hook
    assert_git_fails "rt: branch -f main aborts" branch -f main "$UNREVIEWED"
    assert_git_fails "rt: checkout -B main aborts" checkout -B main "$UNREVIEWED"
    assert_git_fails "rt: update-ref without oldvalue aborts" update-ref refs/heads/main "$UNREVIEWED"
    assert_git_fails "rt: delete main aborts" branch -D main
    assert_git_ok "rt: genuine create newbranch2 allowed" branch newbranch2 "$UNREVIEWED"
    git -C "$REPO" update-ref -d refs/heads/scratch 2>/dev/null || true
    assert_git_ok "rt: create of absent non-protected name allowed" branch scratch "$UNREVIEWED"
}

run_format_suite files
if supports_reftable; then
    run_format_suite reftable
else
    printf '\n=== #780 reftable skipped (git lacks --ref-format=reftable) ===\n'
    printf "  PASS  reftable unsupported on this git — files coverage stands\n"
    PASS=$((PASS + 1))
fi

# Detector unit smoke (shared root).
printf '\n=== #780 detector smoke ===\n'
DET=$(PYTHONPATH="$REPO_ROOT/hooks/gate-scripts/lib" python3 -S - "$REPO" <<'PY'
import sys
from gitcmd_detect import git_zero_old_ref_op, zero_old_ref_exists
hook_cwd = sys.argv[1]
ops = git_zero_old_ref_op('git branch -f main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op('git checkout -B main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op('git branch -f topic abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main abc def', hook_cwd=hook_cwd)
assert ops == [], ops
ops = git_zero_old_ref_op('git branch -D main', hook_cwd=hook_cwd)
assert ops == [('delete', 'main')], ops
assert zero_old_ref_exists(hook_cwd, 'main') is True
print('ok')
PY
) || DET=fail
if [ "$DET" = ok ]; then
    printf "  PASS  detector shapes\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  detector shapes (%s)\n" "$DET"; FAIL=$((FAIL + 1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
