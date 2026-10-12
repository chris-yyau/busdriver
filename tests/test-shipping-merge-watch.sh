#!/usr/bin/env bash
# Tests for scripts/shipping-merge-watch.sh.
#
# A stub `gh` on PATH answers each `gh pr view` with the next line of $FIX/seq
# (`MERGED <oid>`, `OPEN`, `CLOSED`, or `FAIL` for a failed read) and logs its argv.
#
# Usage: bash tests/test-shipping-merge-watch.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
SCRIPT=$PWD/scripts/shipping-merge-watch.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIX=$TMP/fix
mkdir -p "$TMP/bin" "$FIX"
export FIX
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s|GH_HOST=%s|GH_REPO=%s\n' "$*" "${GH_HOST-}" "${GH_REPO-unset}" >> "$FIX/calls"
case "$*" in *headRefName*) cat "$FIX/refs"; exit 0 ;; esac
n=$(( $(cat "$FIX/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIX/n"
line=$(sed -n "${n}p" "$FIX/seq"); [ -n "$line" ] || line=$(tail -n 1 "$FIX/seq")
case $line in
  FAIL) echo "HTTP 502" >&2; exit 1 ;;
  KILLED) echo "MERGED partial"; kill -KILL $$ ;;
  HANG) trap '' ALRM; exec sleep 30 ;;   # ignores SIGALRM, as Go's gh does
  MERGED*) echo "MERGED ${line#MERGED }" ;;
  *) echo "$line " ;;
esac
GH
chmod +x "$TMP/bin/gh"

# run <expected-rc> <expected-stdout> <label> <args...>
run() {
  local rc_want=$1 out_want=$2 label=$3; shift 3
  local out rc
  out=$(PATH="$TMP/bin:$PATH" GH_REPO=evil/repo GH_HOST=evil.example bash "$SCRIPT" "$@"); rc=$?
  if [ "$rc" = "$rc_want" ] && [ "$out" = "$out_want" ]; then pass "$label"
  else fail "$label (rc=$rc out='$out', want rc=$rc_want out='$out_want')"; fi
}
reset() { rm -f "$FIX/n" "$FIX/calls"; printf '%s\n' "$@" > "$FIX/seq"; }

reset "MERGED abc123"
run 0 "merged 42 abc123" "merged on the first poll" o/r 42 0 10
grep -q '^pr view 42 -R o/r --json state,mergeCommit' "$FIX/calls" && pass "reads the named PR in the named repo" || fail "reads the named PR in the named repo"
grep -q '|GH_HOST=github.com|GH_REPO=unset$' "$FIX/calls" && pass "pins GH_HOST and clears GH_REPO" || fail "pins GH_HOST and clears GH_REPO"

reset OPEN OPEN "MERGED def456"
run 0 "merged 42 def456" "waits through open polls" o/r 42 0 10
[ "$(cat "$FIX/n")" = 3 ] && pass "stops polling at the merge" || fail "stops polling at the merge"

reset FAIL FAIL "MERGED 789"
run 0 "merged 42 789" "a failed read is retried, not an outcome" o/r 42 0 10

reset OPEN CLOSED
run 3 "closed 42" "closed without merging" o/r 42 0 10

reset OPEN
run 5 "timeout 42 0s OPEN" "still open at the cap" o/r 42 0 0

reset FAIL
run 5 "timeout 42 0s unread" "never readable reports unread at the cap" o/r 42 0 0

reset KILLED
run 5 "timeout 42 0s unread" "a read killed by a signal is a failed read, whatever it printed" o/r 42 0 0

reset OPEN
start=$(date +%s)
run 5 "timeout 42 2s OPEN" "the cap bounds the wait when the interval is longer" o/r 42 60 2
[ $(( $(date +%s) - start )) -lt 10 ] && pass "a long interval is clamped to the remaining time" || fail "a long interval is clamped to the remaining time"

reset "MERGED x"
new_msg="error: interval and cap must be integers of at most 6 digits"
run 2 "error: repo must be <owner>/<repo>" "rejects a repo without an owner" r 42
run 2 "error: bad repo 'o/r;id'" "rejects shell metacharacters in the repo" "o/r;id" 42
run 2 "error: bad repo 'a/b/c'" "rejects a three-part repo" a/b/c 42
run 2 "error: bad PR number '4x'" "rejects a non-numeric PR" o/r 4x
run 2 "error: bad PR number ''" "rejects an empty PR" o/r ""
run 2 "error: bad PR number '042'" "rejects a zero-led PR" o/r 042
run 2 "$new_msg" "rejects a non-numeric cap" o/r 42 60 1h
run 2 "$new_msg" "rejects a cap that would overflow" o/r 42 60 9223372036854775808
run 2 "$new_msg" "rejects an interval that would overflow" o/r 42 18446744073709551616 60
[ ! -e "$FIX/n" ] && pass "bad arguments make no gh call" || fail "bad arguments make no gh call"

reset HANG
start=$(date +%s)
run 5 "timeout 42 2s unread" "a hung read is cut off at the cap" o/r 42 60 2
[ $(( $(date +%s) - start )) -lt 10 ] && pass "a hung read does not outlive the cap" || fail "a hung read does not outlive the cap"

# --cleanup: a scratch repo with a linked worktree on a branch whose name holds shell
# syntax. The branch names come from the stub's `gh pr view` ($FIX/refs), as from GitHub.
R=$TMP/repo W=$TMP/wt
B="feat/x';printf\${IFS}INJECTED;'"
git init -q -b main "$R" && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R" remote add origin https://github.com/O/R.git
git -C "$R" worktree add -q -b "$B" "$W"
R=$(cd "$R" && pwd -P) W=$(cd "$W" && pwd -P)
# GIT_ALLOW_PROTOCOL=file: the script's fetch of an unknown head fails at once, offline.
cleanup() { (cd "$1" && PATH="$TMP/bin:$PATH" GIT_ALLOW_PROTOCOL=file bash "$SCRIPT" --cleanup o/r 42); }
HEAD_OID=$(git -C "$R" rev-parse "$B")
printf '%s main %s\n' "$B" "$HEAD_OID" > "$FIX/refs"
want=$(printf '! git -C %q worktree remove %q\n! git -C %q branch -D %q' "$R" "$W" "$R" "$B")
out=$(cleanup "$R")
[ "$out" = "$want" ] && pass "cleanup offers worktree remove and branch -D, quoted" || fail "cleanup offers worktree remove and branch -D, quoted (got '$out')"
out=$(cleanup "$W")
[ "$out" = "$want" ] && pass "cleanup run inside the worktree it removes runs from the main worktree" || fail "cleanup run inside the worktree it removes (got '$out')"
inj=$(printf '%s\n' "$out" | sed 's/^! //' | while IFS= read -r c; do bash -c "git() { :; }; $c"; done)
[ -z "$inj" ] && pass "a quote-breaking branch name stays inert when the commands run" || fail "a quote-breaking branch name stays inert (printed '$inj')"
git -C "$R" worktree remove "$W" || fail "test setup: worktree remove"
git -C "$R" switch -q "$B"
want=$(printf '! git -C %q switch main\n! git -C %q branch -D %q' "$R" "$R" "$B")
out=$(cleanup "$R")
[ "$out" = "$want" ] && pass "cleanup in the main root offers switch, not worktree remove" || fail "cleanup in the main root (got '$out')"
git -C "$R" worktree add -q "$TMP/basewt" main
want=$(printf '! git -C %q switch --detach\n! git -C %q branch -D %q' "$R" "$R" "$B")
out=$(cleanup "$R")
[ "$out" = "$want" ] && pass "with the base checked out elsewhere, cleanup detaches instead" || fail "base checked out elsewhere (got '$out')"
git -C "$R" worktree remove "$TMP/basewt" || fail "test setup: remove basewt"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "local work after the push"
out=$(cleanup "$R")
case $out in "note: local "*"no cleanup offered") pass "a branch with commits beyond the PR head gets no cleanup offer" ;;
  *) fail "a branch with commits beyond the PR head (got '$out')" ;; esac
git -C "$R" reset -q --hard "$HEAD_OID"
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "cloud update"
printf '%s main %s\n' "$B" "$(git -C "$R" rev-parse HEAD)" > "$FIX/refs"
git -C "$R" reset -q --hard "$HEAD_OID"
want=$(printf '! git -C %q switch main\n! git -C %q branch -D %q' "$R" "$R" "$B")
out=$(cleanup "$R")
[ "$out" = "$want" ] && pass "a local branch behind the PR head is still offered cleanup" || fail "a local branch behind the PR head (got '$out')"
printf '%s main %s\n' "$B" "0123456789abcdef0123456789abcdef01234567" > "$FIX/refs"
out=$(cleanup "$R")
case $out in "note: local "*"no cleanup offered") pass "a same-named branch from another repository gets no cleanup offer" ;;
  *) fail "a same-named branch from another repository (got '$out')" ;; esac
printf '%s main %s\n' "$B" "$HEAD_OID" > "$FIX/refs"
git -C "$R" switch -q main
git -C "$R" branch -q -D "$B"
out=$(cleanup "$R")
[ -z "$out" ] && pass "cleanup offers nothing once the branch and worktree are gone" || fail "cleanup offers nothing (got '$out')"
printf 'bad..name main %s\n' "$HEAD_OID" > "$FIX/refs"
out=$(cleanup "$R"); rc=$?
[ "$rc" = 1 ] && [ "$out" = "error: bad branch name from GitHub" ] && pass "cleanup rejects an invalid branch name from GitHub" || fail "cleanup rejects an invalid branch name (rc=$rc out='$out')"
out=$(cd "$R" && bash "$SCRIPT" --cleanup "o/r;id" 42); rc=$?
[ "$rc" = 2 ] && pass "cleanup validates the repo" || fail "cleanup validates the repo"
printf '%s main %s\n' "$B" "$HEAD_OID" > "$FIX/refs"
out=$(cd "$R" && PATH="$TMP/bin:$PATH" bash "$SCRIPT" --cleanup fork/r 42)
[ "$out" = "note: no remote of this checkout is github.com/fork/r; no cleanup offered" ] \
  && pass "a checkout of another repository gets no cleanup offer" || fail "a checkout of another repository (got '$out')"
# A worktree path holding a newline is read whole (porcelain -z).
NL=$TMP/'wt
x'
git -C "$R" worktree add -q -b nl-branch "$NL"
printf 'nl-branch main %s\n' "$(git -C "$R" rev-parse nl-branch)" > "$FIX/refs"
want=$(printf '! git -C %q worktree remove %q\n! git -C %q branch -D %q' "$R" "$(cd "$NL" && pwd -P)" "$R" nl-branch)
out=$(cleanup "$R")
[ "$out" = "$want" ] && pass "a worktree path with a newline is quoted whole" || fail "a worktree path with a newline (got '$out')"
# --separate-git-dir: the main worktree is not the git dir's parent.
S=$TMP/sep G=$TMP/sep-store.git
git init -q -b main --separate-git-dir "$G" "$S" && git -C "$S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$S" remote add origin git@github.com:o/r.git
git -C "$S" branch sep-branch
S=$(cd "$S" && pwd -P)
printf 'sep-branch main %s\n' "$(git -C "$S" rev-parse sep-branch)" > "$FIX/refs"
want=$(printf '! git -C %q branch -D sep-branch' "$S")
out=$(cleanup "$S")
[ "$out" = "$want" ] && pass "a separate git dir still resolves the checkout" || fail "a separate git dir (got '$out')"

grep -q '^#!/usr/bin/env bash' "$SCRIPT" && pass "has a bash shebang" || fail "has a bash shebang"

COMP=skills/pr-grind/references/completion.md
grep -qF 'scripts/shipping-merge-watch.sh' "$COMP" && pass "completion.md runs the watcher" || fail "completion.md runs the watcher"
grep -qF 'run_in_background' "$COMP" && pass "completion.md runs it in the background" || fail "completion.md runs it in the background"
grep -qF 'shipping-merge-watch.sh" --cleanup "<owner>/<repo>" <PR_NUMBER>' "$COMP" && pass "completion.md builds cleanup through the script" || fail "completion.md builds cleanup through the script"

echo
echo "shipping-merge-watch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
