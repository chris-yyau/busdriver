#!/usr/bin/env bash
# Test: a skip file whose mtime cannot be read is NOT honored (issue #946).
#
# The four skip-file gates used to default FILE_AGE=999 before probing `stat`, so a
# file whose age could not be proven passed the 30s self-bypass floor (and, in
# pre-merge, landed inside the 3600s validity window). gate_file_mtime now fails
# instead, and every gate blocks on that failure. A PATH stub makes `stat` fail.
#
# Usage: bash tests/test-skip-file-mtime-946.sh
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd -P)
# shellcheck source=../hooks/gate-scripts/lib/resolve-repo-dir.sh disable=SC1091
source "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/nostat" "$TMP/qstat" "$TMP/gnustat" "$TMP/badrc"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nostat/stat"
printf '#!/bin/sh\necho "?"\n' > "$TMP/qstat/stat"
printf '#!/bin/sh\necho 1700000000; exit 1\n' > "$TMP/badrc/stat"   # digits, but stat failed
# GNU shape: -f is "filesystem" and prints non-digits; -c %Y gives the mtime.
printf '#!/bin/sh\ncase "$1" in -c) echo 1700000000 ;; *) echo "File: x"; exit 1 ;; esac\n' > "$TMP/gnustat/stat"
chmod +x "$TMP"/*/stat

# ── gate_file_mtime ─────────────────────────────────────────────────────
F="$TMP/f"; : > "$F"
m=$(gate_file_mtime "$F") && case $m in *[!0-9]*|'') false ;; esac && pass "reads a real file's mtime as digits" || fail "reads a real file's mtime (got '$m')"
gate_file_mtime "$TMP/missing" >/dev/null && fail "a missing file has no mtime" || pass "a missing file has no mtime"
(PATH="$TMP/nostat:$PATH" gate_file_mtime "$F" >/dev/null) && fail "fails when stat fails" || pass "fails when stat fails"
(PATH="$TMP/qstat:$PATH" gate_file_mtime "$F" >/dev/null) && fail "fails when stat prints non-digits" || pass "fails when stat prints non-digits"
(PATH="$TMP/badrc:$PATH" gate_file_mtime "$F" >/dev/null) && fail "fails when stat prints digits but exits non-zero" || pass "fails when stat prints digits but exits non-zero"
m=$(PATH="$TMP/gnustat:$PATH" gate_file_mtime "$F") && [ "$m" = 1700000000 ] && pass "falls back to stat -c when -f prints non-digits" || fail "falls back to stat -c (got '$m')"

# ── Each gate blocks a skip file it cannot date ─────────────────────────
STATE=.claude-test-946
export BUSDRIVER_STATE_DIR="$STATE"
R="$TMP/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
printf '%s/\n' "$STATE" > "$R/.gitignore"
git -C "$R" add .gitignore && git -C "$R" commit -qm init
git -C "$R" branch feature && git -C "$R" switch -q feature
git -C "$R" commit -q --allow-empty -m ahead && git -C "$R" switch -q main
mkdir -p "$R/$STATE"

arm() {   # <skip file name>: an operator-made file, two minutes old
  touch "$R/$STATE/$1"
  touch -t "$(date -v-2M '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 minutes ago' '+%Y%m%d%H%M.%S')" "$R/$STATE/$1"
}
gate() {   # <stat dir or ""> <gate> <command>
  local input
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$3" "$R")
  (cd "$R" && PATH="${1:+$1:}$PATH" bash "$ROOT/hooks/gate-scripts/$2" <<<"$input" 2>/dev/null)
}
check() {   # <gate> <skip file> <command>
  local out
  arm "$2"
  out=$(gate "$TMP/nostat" "$1" "$3")
  case $out in *'"block"'*'#946'*) pass "$1 blocks a $2 whose mtime cannot be read" ;;
    *) fail "$1 blocks an undatable $2 (got '$out')" ;; esac
  [ -f "$R/$STATE/$2" ] && pass "$1 leaves the undatable $2 in place" || fail "$1 leaves the undatable $2 in place"
  arm "$2"
  out=$(gate "" "$1" "$3")
  # Positive control: the same file with a readable mtime is honored, so the
  # fixture really reaches each gate's skip path.
  case $out in *'"block"'*) fail "$1 honors a datable $2 (got '$out')" ;;
    *) pass "$1 honors a datable $2" ;; esac
  rm -f "$R/$STATE/$2" "$R/$STATE/.merge-bypass-pending.local"
}
check pre-commit-gate.sh skip-litmus.local "git commit -m x"
check pre-pr-gate.sh skip-litmus.local "gh pr create --title x --body y"
check pre-merge-gate.sh skip-pr-grind.local "gh pr merge 31 --squash"
check ref-ff-gate.sh skip-litmus.local "git merge feature"

echo
echo "skip-file-mtime-946: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
