#!/usr/bin/env bash
# tests/test-skip-file-guard.sh
#
# Verifies hooks/gate-scripts/lib/skip-file-guard.sh — the shared guard that lets
# the four review gates honor a skip file ONLY when it is OPERATOR-OWNED, never
# when it is REPO-CONTROLLED (committed / injected by the PR under review). This
# closes the residual vector Codex flagged on PR #328 (issue #325 / ADR 0016):
# any PR-delivered skip file is necessarily git-tracked, so rejecting tracked /
# HEAD-present / symlinked / multi-component-state-dir files closes it by
# construction. Mirrors tests/test-advisory-downgrade-optin.sh (ADR 0012).
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=hooks/gate-scripts/lib/skip-file-guard.sh disable=SC1091
source hooks/gate-scripts/lib/skip-file-guard.sh

PASS=0
FAIL=0

# Call the guard without tripping `set -e`, capturing its return code.
assert_rc() {
    local want="$1" desc="$2"; shift 2
    local got=0
    skip_file_operator_owned "$@" || got=$?
    if [[ "$got" -eq "$want" ]]; then
        echo "OK:   $desc (rc=$got)"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected rc=$want, got rc=$got)"; FAIL=$((FAIL + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email t@t
git -C "$TMP" config user.name t
mkdir "$TMP/.claude"
git -C "$TMP" commit -q --allow-empty -m init   # a HEAD exists for cases 1-6

# 1. No file → reject.
assert_rc 1 "no file → reject" "$TMP" ".claude" "skip-litmus.local"

# 2. Untracked regular file in a repo WITH a HEAD → honor (the operator case).
#    Guards the cat-file-vs-ls-tree regression: `git cat-file -e HEAD:<absent>`
#    exits 128 (not 1), so an earlier draft rejected every untracked skip file
#    once any commit existed. `ls-tree` (exit 0 + empty output = absent) fixes it.
: > "$TMP/.claude/skip-litmus.local"
assert_rc 0 "untracked file with a HEAD → honor" "$TMP" ".claude" "skip-litmus.local"

# 3. Tracked in the index (`git add -f` past gitignore) → reject (repo-controlled).
git -C "$TMP" add -f ".claude/skip-litmus.local"
assert_rc 1 "tracked in index → reject" "$TMP" ".claude" "skip-litmus.local"

# 4. Committed then `git rm --cached` — in HEAD's tree, not in the index; the
#    worktree file remains → reject (still repo-controlled via HEAD).
git -C "$TMP" commit -q -m track-skip
git -C "$TMP" rm --cached -q ".claude/skip-litmus.local"
assert_rc 1 "in HEAD tree, not index → reject" "$TMP" ".claude" "skip-litmus.local"

# 5. Symlink skip file → reject (not a regular file).
rm -f "$TMP/.claude/skip-litmus.local"
ln -s /dev/null "$TMP/.claude/skip-litmus.local"
assert_rc 1 "symlink skip file → reject" "$TMP" ".claude" "skip-litmus.local"

# 6. Multi-component state dir (repo-injectable BUSDRIVER_STATE_DIR) → reject,
#    even with an untracked file present at the lexical path.
mkdir -p "$TMP/a/b"
: > "$TMP/a/b/skip-litmus.local"
assert_rc 1 "multi-component state dir → reject" "$TMP" "a/b" "skip-litmus.local"

# 7. Corrupt repo (refs removed after a commit) → fail CLOSED (reject). A git
#    error must never be read as "file absent from HEAD". The untracked file
#    would be honored in a healthy repo, so this proves the error path rejects.
TMP2=$(mktemp -d)
git -C "$TMP2" init -q
git -C "$TMP2" config user.email t@t
git -C "$TMP2" config user.name t
git -C "$TMP2" commit -q --allow-empty -m init
mkdir "$TMP2/.claude"
: > "$TMP2/.claude/skip-litmus.local"
rm -rf "$TMP2/.git/refs"
assert_rc 1 "corrupt repo (git error) → fail closed" "$TMP2" ".claude" "skip-litmus.local"
rm -rf "$TMP2"

# 8. Unborn repo (no HEAD commit): `git ls-tree HEAD` errors, which cannot PROVE
#    the file is absent from a committed tree, so the guard FAILS CLOSED. This is
#    intentional — these gates review commit history, so a zero-commit repo is a
#    non-scenario, and fail-closed beats guessing a git exit code. Case 2 (with a
#    HEAD) is the real-world honor path.
TMP3=$(mktemp -d)
git -C "$TMP3" init -q
git -C "$TMP3" config user.email t@t
git -C "$TMP3" config user.name t
mkdir "$TMP3/.claude"
: > "$TMP3/.claude/skip-litmus.local"   # untracked, but no HEAD to prove absence
assert_rc 1 "untracked file in unborn repo → fail closed" "$TMP3" ".claude" "skip-litmus.local"
rm -rf "$TMP3"

# 9. State dir is a gitlink (submodule) in HEAD but dropped from the index. The
#    index-only gitlink check would miss it, and `ls-tree` of the FILE path
#    returns empty (git does not traverse a gitlink), so an aged file in the
#    submodule checkout must still be rejected — via the HEAD gitlink check.
SUB=$(mktemp -d); TMP4=$(mktemp -d)
git -C "$SUB" init -q; git -C "$SUB" config user.email t@t; git -C "$SUB" config user.name t
git -C "$SUB" commit -q --allow-empty -m sub
git -C "$TMP4" init -q; git -C "$TMP4" config user.email t@t; git -C "$TMP4" config user.name t
git -C "$TMP4" commit -q --allow-empty -m init
if git -C "$TMP4" -c protocol.file.allow=always submodule add -q "$SUB" .claude 2>/dev/null \
   && git -C "$TMP4" commit -q -m "add .claude submodule" \
   && git -C "$TMP4" rm --cached -q .claude; then
    : > "$TMP4/.claude/skip-litmus.local"   # file inside the submodule checkout
    assert_rc 1 "gitlink state dir in HEAD (not index) → reject" "$TMP4" ".claude" "skip-litmus.local"
else
    echo "SKIP: submodule fixture unavailable (git submodule add failed)"
fi
rm -rf "$SUB" "$TMP4"

echo "---"
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
