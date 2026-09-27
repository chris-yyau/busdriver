#!/bin/bash
# Shard partition + aggregate reconciliation for scripts/ci/run-shell-tests.sh
# (0827 roadmap item 5; docs/plans/2026-09-27-ci-shard-shell-tests.md).
# Drives --list-shard / --reconcile, plus ONE --shard run whose weights pin a single
# fast, hermetic suite onto shard 1 — never this file — so it cannot recurse into the
# suite that runs it. bash 3.2 compatible.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable only so the plan's mutation proof can point the suite at a mutant; CI never sets it.
R="${SHELL_TEST_RUNNER:-$ROOT/scripts/ci/run-shell-tests.sh}"
pass=0 fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
run() { /bin/bash -p "$R" "$@"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"

all="$(cd "$ROOT" && for t in tests/test-*.sh; do b=${t##*/}; echo "${b%.sh}"; done | LC_ALL=C sort)"

echo "── partition ──"
for n in 1 3 4 7; do
  : >"$TMP/union"
  for i in $(seq 1 "$n"); do run --list-shard "$i/$n" >>"$TMP/union" || bad "list-shard $i/$n rc!=0"; done
  if [ "$(LC_ALL=C sort "$TMP/union")" = "$all" ]; then ok "N=$n: shards disjoint, union == live glob"
  else bad "N=$n: partition != live glob"; fi
done
[ "$(run --list-shard 2/4)" = "$(run --list-shard 2/4)" ] && ok "partition is deterministic" || bad "partition not deterministic"

printf '# no weights\n' >"$TMP/empty.tsv"
: >"$TMP/union"
for i in 1 2 3 4; do SHELL_TEST_DURATIONS="$TMP/empty.tsv" run --list-shard "$i/4" >>"$TMP/union"; done
[ "$(LC_ALL=C sort "$TMP/union")" = "$all" ] && ok "tests absent from the weights file are still assigned" || bad "unweighted tests dropped"

heavy="$(printf '%s\n' "$all" | head -n1)"
printf '%s\t100000\n' "$heavy" >"$TMP/heavy.tsv"
[ "$(SHELL_TEST_DURATIONS="$TMP/heavy.tsv" run --list-shard 1/2)" = "$heavy" ] && ok "weights are honoured (heaviest test alone on shard 1)" || bad "weights ignored"

printf 'test-x\tnot-a-number\n' >"$TMP/bad.tsv"
SHELL_TEST_DURATIONS="$TMP/bad.tsv" run --list-shard 1/2 >/dev/null 2>&1 && bad "malformed weights accepted" || ok "malformed weights file fails closed"
SHELL_TEST_DURATIONS="$TMP/nope.tsv" run --list-shard 1/2 >/dev/null 2>&1 && bad "missing weights accepted" || ok "missing weights file fails closed"

echo "── argument validation ──"
for args in "--list-shard 5/4" "--list-shard 0/4" "--list-shard x/4" "--shard 1/4" "--shard 1/4 --record rel.tsv" "--reconcile 0 /tmp" "--reconcile 4 rel" "--bogus"; do
  # shellcheck disable=SC2086  # deliberate word-split of the case's argv
  run $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "rejects: $args" || bad "rc=$rc for: $args (want 2)"
done

echo "── record writer ──"
# One real --shard run: the weights pin test-upstream-manifest (hermetic, ~1s) alone onto
# shard 1 of 2, so the writer's actual output is checked, not a hand-built fixture.
# Recursion guard: the pinned shard must own exactly that fixture, and the fixture must
# exist — a renamed fixture would otherwise put every test (this suite included) on the
# shard and make this real run recurse.
fast=test-upstream-manifest
printf '%s\t100000\n' "$fast" >"$TMP/fast.tsv"
owned="$(SHELL_TEST_DURATIONS="$TMP/fast.tsv" run --list-shard 1/2)"
if [ "$owned" != "$fast" ] || [ ! -f "$ROOT/tests/$fast.sh" ]; then
  bad "record-writer fixture shard owns '$owned', not '$fast' — refusing the real run"
elif SHELL_TEST_DURATIONS="$TMP/fast.tsv" run --shard 1/2 --record "$TMP/written.tsv" >"$TMP/shard.out" 2>&1 \
  && awk -F'\t' -v t="$fast" '
       NR == 1 { ok = ($0 == "N\t2") }
       NR == 2 { ok = ok && ($0 == "SHARD\t1") }
       NR == 3 { ok = ok && ($0 == "ASSIGNED\t" t) }
       NR == 4 { ok = ok && NF == 5 && $1 == "DONE" && $2 == t && $3 == "PASS" && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ }
       NR == 5 { ok = ok && ($0 == "END\t1") }
       END { exit !(ok && NR == 5) }' "$TMP/written.tsv"; then
  ok "--shard writes N/SHARD/ASSIGNED/DONE/END for the tests it ran"
else
  bad "--shard record wrong"; sed 's/^/      /' "$TMP/written.tsv" "$TMP/shard.out" 2>/dev/null | tail -n 12
fi

echo "── reconcile ──"
mkrec() {   # <dir> <n> — a complete, passing record set for the real partition
  local d="$1" n="$2" i t
  mkdir -p "$d"
  for i in $(seq 1 "$n"); do
    run --list-shard "$i/$n" >"$TMP/m$i"
    { printf 'N\t%s\nSHARD\t%s\n' "$n" "$i"
      while IFS= read -r t; do printf 'ASSIGNED\t%s\n' "$t"; done <"$TMP/m$i"
      while IFS= read -r t; do printf 'DONE\t%s\tPASS\t1\t0\n' "$t"; done <"$TMP/m$i"
      printf 'END\t%s\n' "$(wc -l <"$TMP/m$i" | tr -d ' ')"
    } >"$d/shell-shard-$i.tsv"
  done
}
drop() { grep -v -F -x "$2" "$1" >"$1.new"; mv "$1.new" "$1"; }   # <file> <exact line>
# reend <file> — move END back to the last line with the file's current DONE count, so a
# fixture mutation trips only the rule it targets and not the END-count check.
reend() { grep -v '^END' "$1" >"$1.new"; printf 'END\t%s\n' "$(grep -c '^DONE' "$1.new")" >>"$1.new"; mv "$1.new" "$1"; }
addrec() { local f="$1"; shift; printf '%s\n' "$@" >>"$f"; reend "$f"; }   # <file> <line>... (lands before END)
expect_ok() {   # <label> <dir> <n>
  local out
  if out="$(run --reconcile "$3" "$2" 2>&1)" && printf '%s\n' "$out" | grep -q '^OK: reconciled'; then ok "$1"
  else bad "$1"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'; fi
}
expect_fail() {   # <label> <dir> <n> <needle>
  local out rc
  out="$(run --reconcile "$3" "$2" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "$4"; then ok "$1"
  else bad "$1 (rc=$rc, wanted '$4')"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'; fi
}

mkrec "$TMP/good" 4
victim="$(head -n1 "$TMP/m2")"
expect_ok "complete record set reconciles" "$TMP/good" 4
vdone="DONE${TAB}$victim${TAB}PASS${TAB}1${TAB}0"

c="$TMP/skipok"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}SKIP${TAB}1${TAB}0"
expect_ok "a SKIP verdict (runner-allowed) reconciles" "$c" 4

c="$TMP/unassigned"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "ASSIGNED${TAB}$victim"; drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"
expect_fail "a test no shard owned fails as unassigned" "$c" 4 "unassigned: $victim"

c="$TMP/twice"; cp -R "$TMP/good" "$c"
addrec "$c/shell-shard-3.tsv" "ASSIGNED${TAB}$victim" "$vdone"
expect_fail "a test owned by two shards fails as assigned twice" "$c" 4 "assigned twice: $victim"

c="$TMP/nodone"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"
expect_fail "an assigned test with no DONE fails as missing completion record" "$c" 4 "missing completion record: $victim"

c="$TMP/noshard"; cp -R "$TMP/good" "$c"; rm "$c/shell-shard-4.tsv"
expect_fail "a missing shard record fails" "$c" 4 "shard 4/4: no record"

c="$TMP/noend"; cp -R "$TMP/good" "$c"; grep -v '^END' "$c/shell-shard-1.tsv" >"$c/x"; mv "$c/x" "$c/shell-shard-1.tsv"
expect_fail "a record without END (shard did not finish) fails" "$c" 4 "shard 1/4: record has no END line"

c="$TMP/failed"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}FAIL${TAB}1${TAB}0"
expect_fail "a FAIL verdict fails the aggregate" "$c" 4 "not passing: $victim"

expect_fail "an N mismatch (matrix vs --reconcile) fails" "$TMP/good" 3 "header is not N"

c="$TMP/ghost"; cp -R "$TMP/good" "$c"
addrec "$c/shell-shard-1.tsv" "ASSIGNED${TAB}test-does-not-exist" "DONE${TAB}test-does-not-exist${TAB}PASS${TAB}1${TAB}0"
expect_fail "a record naming an undiscovered test fails" "$c" 4 "assigned but not discovered: test-does-not-exist"

echo "── record protocol ──"
c="$TMP/afterend"; cp -R "$TMP/good" "$c"
printf 'DONE\t%s\tPASS\t1\t0\n' "$victim" >>"$c/shell-shard-2.tsv"
expect_fail "a line after END fails" "$c" 4 "line after END"

c="$TMP/endcount"; cp -R "$TMP/good" "$c"
grep -v '^END' "$c/shell-shard-2.tsv" >"$c/x"; printf 'END\t999\n' >>"$c/x"; mv "$c/x" "$c/shell-shard-2.tsv"
expect_fail "an END count that disagrees with the DONE lines fails" "$c" 4 "END count 999"

c="$TMP/nonnum"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}PASS${TAB}x${TAB}0"
expect_fail "a non-numeric DONE duration fails" "$c" 4 "non-numeric DONE field"

c="$TMP/crossfile"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"; addrec "$c/shell-shard-3.tsv" "$vdone"
expect_fail "a DONE in a shard that did not ASSIGN the test fails" "$c" 4 "did not ASSIGN: $victim"

c="$TMP/headeronly"; cp -R "$TMP/good" "$c"; printf 'N\t4\n' >"$c/shell-shard-9.tsv"
expect_fail "a header-only extra record file fails" "$c" 4 "without a valid SHARD line"

c="$TMP/extrafield"; cp -R "$TMP/good" "$c"
{ printf 'N\t4\textra\n'; tail -n +2 "$TMP/good/shell-shard-1.tsv"; } >"$c/shell-shard-1.tsv"
expect_fail "a header with extra fields fails" "$c" 4 "header is not N"

c="$TMP/emptyfile"; cp -R "$TMP/good" "$c"; : >"$c/shell-shard-9.tsv"
expect_fail "a zero-byte extra record file fails" "$c" 4 "empty record file"

mkdir -p "$TMP/emptydir"
expect_fail "no records at all (every shard skipped) fails" "$TMP/emptydir" 4 "shard 1/4: no record"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
