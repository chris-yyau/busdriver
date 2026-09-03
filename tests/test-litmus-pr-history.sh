#!/usr/bin/env bash
# tests/test-litmus-pr-history.sh — cross-run PR review history (#811).
#
# Asserts the two ancestry filters that make the store safe to inject:
#   1. a verdict recorded on a commit still reachable from HEAD is presented;
#   2. a verdict on a commit that is NOT an ancestor of HEAD (rebase/force-push/
#      wrong branch) is dropped — the reviewer starts cold, today's behaviour;
#   3. a verdict already merged into the PR base belongs to a previous PR and is
#      dropped;
#   4. commit mode never touches the store;
#   5. a symlink at the store path is refused at BOTH ends;
#   6. the verdict is stamped with the caller's pre-review SHA, never a HEAD that
#      moved while the review was running.
set -euo pipefail
# Scrub the ambient git environment before building the sandbox. An agent or CI
# runner that exports GIT_INDEX_FILE/GIT_DIR/GIT_WORK_TREE would otherwise have
# every `git` call below aim at ITS repo, and the fixture would fail while
# blaming the code under test. Repo convention — see test-gateguard-containment.sh.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/skills/litmus/scripts/lib/iteration-history.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"

git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false

echo base > base.txt && git add base.txt && git commit -qm base
BASE_SHA=$(git rev-parse HEAD)

git checkout -q -b feature
echo one > one.txt && git add one.txt && git commit -qm one
SHA1=$(git rev-parse HEAD)
echo two > two.txt && git add two.txt && git commit -qm two
SHA2=$(git rev-parse HEAD)

# An abandoned commit: created, then dropped from the branch (force-push shape).
git checkout -q -b abandoned
echo gone > gone.txt && git add gone.txt && git commit -qm gone
ORPHAN_SHA=$(git rev-parse HEAD)
git checkout -q feature

export BUSDRIVER_STATE_DIR=.claude
mkdir -p .claude
# shellcheck source=../skills/litmus/scripts/lib/iteration-history.sh
source "$LIB"

fail() { echo "FAIL: $1"; exit 1; }

# ── 1. a verdict stamped with the caller's pre-review SHA ────────────────────
# HEAD is SHA2 here while the recorded SHA is SHA1 — the shape that occurs when a
# commit lands during the (minutes-long) review. The verdict must be filed against
# the commit that was actually reviewed, so this call NEVER resolves HEAD itself.
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"one.txt","line":3,"description":"unchecked return"}]}' "$SHA1"
grep -q "\"head_sha\": \"$SHA1\"" .claude/litmus-pr-history.local.jsonl \
  || fail "verdict not stamped with the caller's reviewed SHA"

OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "ancestor verdict not presented:\n$OUT"
echo "$OUT" | grep -q "unchecked return" || fail "issue text not presented:\n$OUT"
echo "$OUT" | grep -q "re-verify against the diff" || fail "missing shifted-line caveat:\n$OUT"

# ── 2. a non-ancestor commit is dropped ──────────────────────────────────────
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"gone.txt","line":1,"description":"orphan finding"}]}' "$ORPHAN_SHA"

# Prove the entry really was recorded, so a green assertion below means the
# ancestry filter dropped it — not that the append silently no-op'd.
grep -q "orphan finding" .claude/litmus-pr-history.local.jsonl || fail "orphan entry was never recorded"

OUT=$(load_pr_history "$BASE_SHA")
if echo "$OUT" | grep -q "orphan finding"; then fail "non-ancestor verdict leaked:\n$OUT"; fi
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "ancestor verdict lost after orphan entry:\n$OUT"

# ── 3. a verdict already in the PR base is dropped ───────────────────────────
# Same store, but ask as if SHA1 had already merged: base moves to SHA2.
OUT=$(load_pr_history "$SHA2")
[ -z "$OUT" ] || fail "verdict already contained in base was presented:\n$OUT"

# ── 4. a PASS verdict with no issues still renders ───────────────────────────
append_pr_history '{"status":"PASS","issues":[]}' "$SHA2"
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "No issues found" || fail "clean verdict not presented:\n$OUT"

# ── 4b. a malformed or absent reviewed SHA records nothing ───────────────────
BEFORE=$(wc -l < .claude/litmus-pr-history.local.jsonl)
append_pr_history '{"status":"FAIL","issues":[]}'
append_pr_history '{"status":"FAIL","issues":[]}' "HEAD"
append_pr_history '{"status":"FAIL","issues":[]}' "${SHA2:0:8}"
AFTER=$(wc -l < .claude/litmus-pr-history.local.jsonl)
[ "$BEFORE" -eq "$AFTER" ] || fail "an unvalidated reviewed SHA was recorded ($BEFORE -> $AFTER)"

# ── 5. malformed / unresolvable entries are skipped, not fatal ───────────────
printf 'not json\n{"head_sha":"../../etc/passwd","status":"FAIL","issues":[]}\n{"head_sha":"%s","status":"FAIL","issues":[]}\n' \
  "0000000000000000000000000000000000000000" >> .claude/litmus-pr-history.local.jsonl
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "good entry lost among malformed ones:\n$OUT"

# ── 6. commit-mode helpers are untouched by the new store ────────────────────
append_iteration_history 1 '{"status":"FAIL","issues":[{"severity":"high","file":"a","line":1,"description":"d"}]}'
load_iteration_history | grep -q "PREVIOUS ITERATION HISTORY" || fail "per-run history broken"
clear_iteration_history
[ -f .claude/litmus-pr-history.local.jsonl ] || fail "clear_iteration_history removed the cross-run store"

# ── 4bb. a long/multiline finding is clamped to one bounded line ─────────────
LONG=$(python3 -c 'print("A" * 4000 + "TAIL")')
append_pr_history "{\"status\":\"FAIL\",\"issues\":[{\"severity\":\"high\",\"file\":\"a\",\"line\":1,\"description\":\"$LONG\"}]}" "$SHA2"
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "TAIL" && fail "an oversized finding was injected verbatim"
LONGEST=$(echo "$OUT" | awk '{ print length }' | sort -rn | head -1)
[ "$LONGEST" -lt 800 ] || fail "clamped line is still $LONGEST chars"

# ── 4c. an unresolvable base ref drops entries instead of injecting them ─────
# `merge-base --is-ancestor` exits 128 here, not 1. Treating that as "not merged"
# would present verdicts that may belong to an already-merged PR.
OUT=$(load_pr_history "refs/heads/no-such-branch")
[ -z "$OUT" ] || fail "unresolvable base ref did not fail safe:\n$OUT"

# ── 5b. the store is found from a subdirectory, not re-created there ─────────
# Re-source from the subdirectory: PR_HISTORY_FILE is resolved at source time, so
# this is the shape that matters — the loop launched with a subdirectory as CWD.
mkdir -p sub/dir
# shellcheck source=../skills/litmus/scripts/lib/iteration-history.sh
SUB_OUT=$(cd sub/dir && source "$LIB" && load_pr_history "$BASE_SHA")
echo "$SUB_OUT" | grep -q "commit ${SHA1:0:8}" || fail "store not found from a subdirectory:\n$SUB_OUT"
[ ! -e sub/dir/.claude ] || fail "a second store was created in the subdirectory"

# ── 6b. the byte window reads the tail, and drops the partial line it starts on ─
# Pad past TAIL_BYTES (512 KiB) so the read starts mid-record. The recent entries
# must still come back, and the truncated record must not blow up the parse.
cp .claude/litmus-pr-history.local.jsonl .claude/small-store.jsonl
{ head -c 600000 /dev/zero | tr '\0' 'x'; echo; cat .claude/small-store.jsonl; } \
  > .claude/litmus-pr-history.local.jsonl
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "tail window lost a recent entry in a large store:\n$OUT"
cp .claude/small-store.jsonl .claude/litmus-pr-history.local.jsonl

# ── 7. a symlink at the store path is refused at both ends ───────────────────
mv .claude/litmus-pr-history.local.jsonl .claude/real-store.jsonl
echo "elsewhere" > elsewhere.txt
ln -s "$SANDBOX/elsewhere.txt" .claude/litmus-pr-history.local.jsonl
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"x","line":1,"description":"planted"}]}' "$SHA1"
grep -q "planted" elsewhere.txt && fail "append followed a symlink out of the store"
OUT=$(load_pr_history "$BASE_SHA")
[ -z "$OUT" ] || fail "load read through a symlinked store:\n$OUT"
rm -f .claude/litmus-pr-history.local.jsonl

# ── 8. a FIFO at the store path is refused, and never blocks ─────────────────
# O_NOFOLLOW does not cover this shape: without O_NONBLOCK + S_ISREG both calls
# would block on the open until someone opened the other end. Asserting "never
# blocks" needs a wall-clock budget, and stock macOS ships no `timeout` — so
# find one or skip the case rather than fail and blame the code under test.
if command -v timeout >/dev/null 2>&1; then TO=(timeout 10)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 10)
else TO=(); echo "SKIP (fixture 8): no timeout/gtimeout — cannot bound the FIFO open"; fi

if [ "${#TO[@]}" -gt 0 ]; then
  mkfifo .claude/litmus-pr-history.local.jsonl
  "${TO[@]}" bash -c \
    "source '$LIB'; append_pr_history '{\"status\":\"FAIL\",\"issues\":[]}' '$SHA1'" \
    || fail "append blocked or errored on a FIFO store"
  OUT=$("${TO[@]}" bash -c "source '$LIB'; load_pr_history '$BASE_SHA'") \
    || fail "load blocked or errored on a FIFO store"
  [ -z "$OUT" ] || fail "load read through a FIFO store:\n$OUT"
  rm -f .claude/litmus-pr-history.local.jsonl
fi

mv .claude/real-store.jsonl .claude/litmus-pr-history.local.jsonl

echo "PASS: test-litmus-pr-history.sh"
