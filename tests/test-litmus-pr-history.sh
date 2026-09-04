#!/usr/bin/env bash
# tests/test-litmus-pr-history.sh — cross-run PR review history (#811).
#
# Most fixtures below were checked by neutering the guard they name and
# confirming this suite turns red. Be honest about the ones that were not — an
# overstated coverage claim is worse than a missing test, because it stops anyone
# writing the real one. These assert a true property but do NOT discriminate the
# guard they sit next to, and each says so at its own site:
#   - fixture 8's LOAD side (the `-s` test short-circuits before the read guard);
#   - fixture 6b's partial-line drop (a truncated line fails json.loads anyway);
#   - fixture 5's strict-hex head_sha (a bad sha makes git exit 128, so the
#     ancestry check drops the entry with or without the hex test);
#   - the APPEND-side S_ISREG check (O_NONBLOCK raises ENXIO on a FIFO first).
#
# What the fixtures cover:
#
#   1. a verdict is filed against the caller's PRE-review SHA, never a HEAD that
#      moved during the review;
#   2. a commit no longer reachable from HEAD (rebase / force-push) is dropped;
#   3. a moved base drops verdicts recorded against the old one — which is also
#      the already-merged case;
#   4. a clean verdict still renders; an unvalidated SHA pair records nothing;
#      an oversized finding is clamped; an unresolvable base fails safe;
#   5. malformed records are skipped; the store lives OUTSIDE the repo and is
#      keyed by root commit, so the branch under review cannot supply one;
#   6. commit-mode helpers are untouched; the byte window reads the tail;
#   7/8. a symlink and a FIFO at the store path are refused at both ends.
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
cd "$SANDBOX"

git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
git config commit.gpgsign false

# The root commit is this fixture's store key, so it must differ between runs.
# An identical tree, author, message and second-resolution timestamp produce an
# identical root SHA, so two runs started in the same second would otherwise share
# one file in the operator's real home and each EXIT trap would delete the other's.
echo "base $$-${RANDOM}-$(date +%s%N 2>/dev/null || date +%s)" > base.txt
git add base.txt && git commit -qm base
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

# The store is keyed by this sandbox's root commit, which is unique per run, so
# runs never collide — but it lands in the operator's real home, so clean it up.
trap 'rm -rf "$SANDBOX"; [ -n "${PR_HISTORY_FILE:-}" ] && rm -f "$PR_HISTORY_FILE"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ── 0a. sourcing never aborts its host script ────────────────────────────────
# Both scripts that source this lib run under `set -euo pipefail`. A top-level
# pipeline whose first command fails is non-zero under pipefail even when the
# later stages succeed, so an unguarded `git rev-list` on an unborn HEAD would
# abort the SOURCING script at source time — silently, since git's stderr is
# discarded. That would kill a commit-mode review before the repo's first commit.
UNBORN=$(mktemp -d)
(
  cd "$UNBORN"
  git init -q -b main
  BUSDRIVER_STATE_DIR=.claude bash -c 'set -euo pipefail; source "$1"; echo READY' _ "$LIB"
) | grep -q READY || fail "sourcing the lib aborted its host script on an unborn HEAD"
rm -rf "$UNBORN"

NONREPO=$(mktemp -d)
(
  cd "$NONREPO"
  BUSDRIVER_STATE_DIR=.claude bash -c 'set -euo pipefail; source "$1"; echo READY' _ "$LIB"
) | grep -q READY || fail "sourcing the lib aborted its host script outside a repo"
rm -rf "$NONREPO"

# ── 0. environments with no usable store degrade to a cold review ────────────
# Some sandboxes give the password-database home to root and hand the session a
# writable $HOME elsewhere; the store is then unreachable BY DESIGN, since there
# is no $HOME fallback (that path is repo-injectable).
#
# The two cases are kept apart deliberately. A store that is missing BECAUSE the
# home is unusable is an environment fact — assert the degradation is silent and
# empty, then SKIP. A store that is missing while the home is perfectly writable
# is a REGRESSION (a broken root-commit key, the containment check misfiring, a
# uid absent from the password database) and must fail, not skip. Collapsing the
# two would let any such regression exit here self-reporting success.
#
# The SKIP marker is the LAST line on that path on purpose: scripts/ci/run-shell-
# tests.sh classifies a suite by its last non-empty line, so printing a trailing
# PASS after it would record a run that asserted almost nothing as green.
# The environment is judged by the test's OWN password-database lookup, never by
# $_PR_HISTORY_HOME. That variable is produced by the code under test, so trusting
# it would let a regression in the lookup itself present as "no usable home" and
# take the allowed skip — precisely the masking this branch exists to prevent.
TEST_HOME=$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)
if [ -n "$PR_HISTORY_FILE" ] && mkdir -p "$PR_HISTORY_DIR" 2>/dev/null; then
  :
elif [ -n "$TEST_HOME" ] && [ -d "$TEST_HOME" ] && [ -w "$TEST_HOME" ]; then
  fail "no usable store although the password-database home ($TEST_HOME) is writable"
else
  append_pr_history '{"status":"FAIL","issues":[]}' "$SHA1" "$BASE_SHA"
  OUT=$(load_pr_history "$BASE_SHA") || fail "load errored with no store available"
  [ -z "$OUT" ] || fail "history was produced with no store available:\n$OUT"
  echo "SKIP: no writable password-database home — the store is disabled here"
  exit 0
fi

# ── 1. a verdict stamped with the caller's pre-review SHA ────────────────────
# HEAD is SHA2 here while the recorded SHA is SHA1 — the shape that occurs when a
# commit lands during the (minutes-long) review. The verdict must be filed against
# the commit that was actually reviewed, so this call NEVER resolves HEAD itself.
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"one.txt","line":3,"description":"unchecked return"}]}' "$SHA1" "$BASE_SHA"
grep -q "\"head_sha\": \"$SHA1\"" "$PR_HISTORY_FILE" \
  || fail "verdict not stamped with the caller's reviewed SHA"

OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "ancestor verdict not presented:\n$OUT"
echo "$OUT" | grep -q "unchecked return" || fail "issue text not presented:\n$OUT"
echo "$OUT" | grep -q "re-verify against the diff" || fail "missing shifted-line caveat:\n$OUT"

# ── 2. a non-ancestor commit is dropped ──────────────────────────────────────
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"gone.txt","line":1,"description":"orphan finding"}]}' "$ORPHAN_SHA" "$BASE_SHA"

# Prove the entry really was recorded, so a green assertion below means the
# ancestry filter dropped it — not that the append silently no-op'd.
grep -q "orphan finding" "$PR_HISTORY_FILE" || fail "orphan entry was never recorded"

OUT=$(load_pr_history "$BASE_SHA")
if echo "$OUT" | grep -q "orphan finding"; then fail "non-ancestor verdict leaked:\n$OUT"; fi
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "ancestor verdict lost after orphan entry:\n$OUT"

# ── 3. a moved base drops the verdicts recorded against the old one ──────────
# Ask as if the PR had been retargeted / the base force-pushed to SHA2: the diff
# `base...HEAD` now means something else, so a verdict reached on the old scope
# must not be presented as applicable. This also covers the already-merged case —
# a base that advanced to contain the commit is a base that moved.
OUT=$(load_pr_history "$SHA2")
[ -z "$OUT" ] || fail "verdict recorded against a different base was presented:\n$OUT"

# ── 4. a PASS verdict with no issues still renders ───────────────────────────
append_pr_history '{"status":"PASS","issues":[]}' "$SHA2" "$BASE_SHA"
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "No issues found" || fail "clean verdict not presented:\n$OUT"

# ── 4b. a malformed or absent SHA in either position records nothing ─────────
BEFORE=$(wc -l < "$PR_HISTORY_FILE")
append_pr_history '{"status":"FAIL","issues":[]}'
append_pr_history '{"status":"FAIL","issues":[]}' "HEAD" "$BASE_SHA"
append_pr_history '{"status":"FAIL","issues":[]}' "${SHA2:0:8}" "$BASE_SHA"
append_pr_history '{"status":"FAIL","issues":[]}' "$SHA2"
append_pr_history '{"status":"FAIL","issues":[]}' "$SHA2" "not-a-sha"
AFTER=$(wc -l < "$PR_HISTORY_FILE")
[ "$BEFORE" -eq "$AFTER" ] || fail "an unvalidated SHA was recorded ($BEFORE -> $AFTER)"

# ── 4c. a long/multiline finding is clamped to one bounded line ──────────────
LONG=$(python3 -c 'print("A" * 4000 + "TAIL")')
append_pr_history "{\"status\":\"FAIL\",\"issues\":[{\"severity\":\"high\",\"file\":\"a\",\"line\":1,\"description\":\"$LONG\"}]}" "$SHA2" "$BASE_SHA"
OUT=$(load_pr_history "$BASE_SHA")
if echo "$OUT" | grep -q "TAIL"; then fail "an oversized finding was injected verbatim"; fi
LONGEST=$(echo "$OUT" | awk '{ print length }' | sort -rn | head -1)
[ "$LONGEST" -lt 800 ] || fail "clamped line is still $LONGEST chars"

# ── 4d. an unresolvable base ref drops entries instead of injecting them ─────
# `merge-base` exits 128 here, not 1. Treating that as "no merge base" and
# carrying on would present verdicts whose scope cannot be checked at all.
#
# The null-base record is what makes this fixture DISCRIMINATING. Without it the
# assertion passes either way: with the `BASE is None` early exit deleted, BASE
# stays None, every stored base_sha is a 40-hex string, and `base_sha != BASE`
# drops them all regardless. A record whose own base is null compares EQUAL to
# None, so it renders the moment that early exit goes — which is also the real
# residual, not just a testing trick.
printf '{"head_sha":"%s","base_sha":null,"status":"FAIL","issues":[{"severity":"high","file":"x","line":1,"description":"null-base-entry"}]}\n' \
  "$SHA1" >> "$PR_HISTORY_FILE"
OUT=$(load_pr_history "refs/heads/no-such-branch")
[ -z "$OUT" ] || fail "unresolvable base ref did not fail safe:\n$OUT"
# ...and it must not leak into an ordinary load either.
OUT=$(load_pr_history "$BASE_SHA")
if echo "$OUT" | grep -q "null-base-entry"; then fail "a null-base record was rendered:\n$OUT"; fi

# ── 5. malformed / unresolvable entries are skipped, not fatal ───────────────
printf 'not json\n{"head_sha":"../../etc/passwd","base_sha":"%s","status":"FAIL","issues":[]}\n{"head_sha":"%s","base_sha":"%s","status":"FAIL","issues":[]}\n' \
  "$BASE_SHA" "0000000000000000000000000000000000000000" "$BASE_SHA" \
  >> "$PR_HISTORY_FILE"
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "good entry lost among malformed ones:\n$OUT"

# ── 5b. the store lives outside the repo, and the repo cannot supply one ─────
# This is the guard that replaced four earlier ones. In-tree, every spelling of
# "check the committed store" leaked — `git add -f` past gitignore, a differently
# cased entry on a case-insensitive filesystem, a symlinked state dir, a gitlink
# whose contents git never lists. Asserting the LOCATION is what makes all of
# those irrelevant, so assert that rather than re-testing each spelling.
# Compared with the lib's own containment helper, not a textual glob on
# $SANDBOX: on macOS `mktemp -d` hands back /var/folders/... while the same
# directory realpaths to /private/var/folders/..., so a glob would miss an
# in-repo store built from `git rev-parse --show-toplevel`, and would miss a
# relative path entirely.
if _pr_history_within "$PR_HISTORY_FILE" "$(git rev-parse --show-toplevel)"; then
  fail "the store is inside the repo: $PR_HISTORY_FILE"
fi
[ ! -e .claude/litmus-pr-history.local.jsonl ] || fail "an in-repo store was created"

# A committed file under the store's in-repo name must not be read.
printf '{"head_sha":"%s","base_sha":"%s","status":"FAIL","issues":[{"severity":"high","file":"x","line":1,"description":"planted in repo"}]}\n' \
  "$SHA1" "$BASE_SHA" > .claude/litmus-pr-history.local.jsonl
git add -f .claude/litmus-pr-history.local.jsonl
OUT=$(load_pr_history "$BASE_SHA")
if echo "$OUT" | grep -q "planted in repo"; then fail "a committed in-repo file was read:\n$OUT"; fi
git rm -q --cached .claude/litmus-pr-history.local.jsonl
rm -f .claude/litmus-pr-history.local.jsonl

# ── 5bb. a store that WOULD land inside the reviewed worktree is refused ─────
# The operator's home can be inside the repo under review — `~/.claude` is itself
# a git repository on the maintainer's machine — which would hand the whole
# in-tree problem back. Exercised on synthetic paths because the live wiring
# offers no way to reach the case without moving the operator's real home.
mkdir -p "$SANDBOX/outer/inner" "$SANDBOX/unrelated"
ln -s "$SANDBOX/outer" "$SANDBOX/link-to-outer"
_pr_history_within "$SANDBOX/outer/inner" "$SANDBOX/outer" \
  || fail "containment missed a plain descendant"
_pr_history_within "$SANDBOX/outer" "$SANDBOX/outer" \
  || fail "containment missed the identical path"
_pr_history_within "$SANDBOX/link-to-outer/inner" "$SANDBOX/outer" \
  || fail "containment was fooled by a symlinked path"
if _pr_history_within "$SANDBOX/unrelated" "$SANDBOX/outer"; then
  fail "containment claimed an unrelated sibling was inside"
fi
if _pr_history_within "$SANDBOX/outer-suffix" "$SANDBOX/outer"; then
  fail "containment matched on a shared name prefix, not a path boundary"
fi

# ── 5c. an unrelated repo keys to a different store ──────────────────────────
OTHER=$(mktemp -d)
OTHER_FILE=$(
  cd "$OTHER"
  git init -q -b main >/dev/null
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  echo other > o.txt && git add o.txt && git commit -qm other >/dev/null
  # shellcheck source=../skills/litmus/scripts/lib/iteration-history.sh
  source "$LIB"
  printf '%s' "$PR_HISTORY_FILE"
)
rm -rf "$OTHER"
[ -n "$OTHER_FILE" ] || fail "an ordinary repo resolved to no store at all"
[ "$OTHER_FILE" != "$PR_HISTORY_FILE" ] || fail "an unrelated repo shares this repo's store"

# ── 5d. the store is found from a subdirectory ───────────────────────────────
# PR_HISTORY_FILE is resolved at source time, so re-source there: this is the
# shape that matters, the loop launched with a subdirectory as its CWD.
mkdir -p sub/dir
# shellcheck source=../skills/litmus/scripts/lib/iteration-history.sh
SUB_OUT=$(cd sub/dir && source "$LIB" && load_pr_history "$BASE_SHA")
echo "$SUB_OUT" | grep -q "commit ${SHA1:0:8}" || fail "store not found from a subdirectory:\n$SUB_OUT"

# ── 6. commit-mode helpers are untouched by the new store ────────────────────
append_iteration_history 1 '{"status":"FAIL","issues":[{"severity":"high","file":"a","line":1,"description":"d"}]}'
load_iteration_history | grep -q "PREVIOUS ITERATION HISTORY" || fail "per-run history broken"
clear_iteration_history
[ -f "$PR_HISTORY_FILE" ] || fail "clear_iteration_history removed the cross-run store"

# ── 6b. the byte window reads the tail, and drops the partial line it starts on ─
# Pad past TAIL_BYTES (512 KiB) so the read starts mid-record. The recent entries
# must still come back, and the truncated record must not blow up the parse.
cp "$PR_HISTORY_FILE" "$SANDBOX/small-store.jsonl"
{ head -c 600000 /dev/zero | tr '\0' 'x'; echo; cat "$SANDBOX/small-store.jsonl"; } \
  > "$PR_HISTORY_FILE"
OUT=$(load_pr_history "$BASE_SHA")
echo "$OUT" | grep -q "commit ${SHA1:0:8}" || fail "tail window lost a recent entry in a large store:\n$OUT"
cp "$SANDBOX/small-store.jsonl" "$PR_HISTORY_FILE"

# ── 7. a symlink at the store path is refused at both ends ───────────────────
# The store now sits in an operator directory rather than the repo, so this is
# stray-symlink hygiene rather than a defence against the reviewed branch.
# The symlink target must be a record the loader WOULD render. Pointing at
# arbitrary text makes the read-side assertion pass for the wrong reason: with
# O_NOFOLLOW removed the load would follow the link, fail to parse the line, and
# still emit nothing — green with the guard deleted. A distinct marker keeps the
# append-side grep below unambiguous.
mv "$PR_HISTORY_FILE" "$SANDBOX/real-store.jsonl"
printf '{"head_sha":"%s","base_sha":"%s","status":"FAIL","issues":[{"severity":"high","file":"x","line":1,"description":"read-through-symlink"}]}\n' \
  "$SHA1" "$BASE_SHA" > "$SANDBOX/elsewhere.txt"
ln -s "$SANDBOX/elsewhere.txt" "$PR_HISTORY_FILE"
append_pr_history '{"status":"FAIL","issues":[{"severity":"high","file":"x","line":1,"description":"planted"}]}' "$SHA1" "$BASE_SHA"
if grep -q "planted" "$SANDBOX/elsewhere.txt"; then fail "append followed a symlink out of the store"; fi
OUT=$(load_pr_history "$BASE_SHA")
[ -z "$OUT" ] || fail "load read through a symlinked store:\n$OUT"
rm -f "$PR_HISTORY_FILE"

# ── 8. a FIFO at the store path is refused, and never blocks ─────────────────
# O_NOFOLLOW does not cover this shape: without O_NONBLOCK the APPEND would block
# on the open until someone opened the other end. Be precise about which end this
# proves: only the append. `load_pr_history` returns at its `[ -s ]` test, and a
# FIFO reports size 0, so the read never reaches its own O_NONBLOCK/S_ISREG guard
# — the load assertions below say "a FIFO does not hang or error the loader",
# which is true and worth pinning, but they are NOT evidence for the read-side
# guard. (Forcing `-s` true with a background writer is not portable: a FIFO's
# st_size differs between Linux and macOS.) Asserting "never blocks" needs a
# wall-clock budget, and stock macOS ships no `timeout` — so find one or skip the
# case rather than fail and blame the code under test.
if command -v timeout >/dev/null 2>&1; then TO=(timeout 10)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 10)
else TO=(); echo "SKIP (fixture 8): no timeout/gtimeout — cannot bound the FIFO open"; fi

if [ "${#TO[@]}" -gt 0 ]; then
  mkfifo "$PR_HISTORY_FILE"
  # Values are passed as POSITIONAL ARGUMENTS, never interpolated into the shell
  # source: a sandbox or repo path containing an apostrophe would otherwise close
  # the quoting and inject shell syntax into the fixture.
  "${TO[@]}" bash -c \
    'cd "$1"; . "$2"; append_pr_history "{\"status\":\"FAIL\",\"issues\":[]}" "$3" "$4"' \
    _ "$SANDBOX" "$LIB" "$SHA1" "$BASE_SHA" \
    || fail "append blocked or errored on a FIFO store"
  OUT=$("${TO[@]}" bash -c 'cd "$1"; . "$2"; load_pr_history "$3"' \
    _ "$SANDBOX" "$LIB" "$BASE_SHA") \
    || fail "load blocked or errored on a FIFO store"
  [ -z "$OUT" ] || fail "load read through a FIFO store:\n$OUT"
  rm -f "$PR_HISTORY_FILE"
fi

mv "$SANDBOX/real-store.jsonl" "$PR_HISTORY_FILE"

echo "PASS: test-litmus-pr-history.sh"
