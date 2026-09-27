#!/bin/bash -p
# #803: /bin/bash, not `env -S bash -p`. `env` resolves the interpreter through the
# AMBIENT PATH, so a hostile PATH selects an attacker-supplied bash BEFORE privileged
# mode or the environment rebuild below can start -- the entry boundary would be
# decided by the very thing it exists to distrust. This script is written for bash 3.2
# (see the `case` lookup below, chosen over `declare -A` for exactly that reason), so
# pinning the absolute system interpreter costs nothing.
# #803: re-exec privileged before sourcing resolve-cli.sh below. Privileged bash
# ignores BASH_ENV, which is the only environment-reachable way to install a DEBUG
# trap (it steers every parent-shell variable, defeating in-library checks) or to
# declare the review-lib state readonly (neither assignment nor `builtin unset`
# clears a readonly). It also refuses BASH_FUNC_* imports. Same guard as
# skills/litmus/scripts/run-review-loop.sh; "$BASH" keeps the same interpreter.
# The per-test children are unaffected — the suites that deliberately export
# BASH_FUNC_* shadows spawn their own shells.
if [[ "$-" != *p* ]]; then
    exec "${BASH:-/bin/bash}" -p "$0" "$@"
fi
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves those entries sitting in the
# ENVIRONMENT, so any unprivileged bash CHILD re-processes them. Measured: with
# BASH_ENV pointing at a file containing `exit 0`, a child launched from a
# privileged parent exited 0 without running its body at all. Scrub them here,
# where -p guarantees `unset` is the real builtin and no shadow was imported.
# BASH_FUNC_* entries cannot be removed this way -- their names are not valid
# identifiers, and `unset "BASH_FUNC_x%%"` leaves the environ entry in place
# (measured; an unprivileged grandchild still imported it) -- so every child this
# script launches is started with -p rather than relying on the scrub alone.
# BD803-CLEAN-ENV-BEGIN
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves every one of those entries sitting in
# the ENVIRONMENT, so any unprivileged descendant re-imports them -- including a
# plain `#!/bin/bash` helper reached through a sourced library, which no amount of
# care in THIS file would cover. Measured: BASH_ENV pointing at a file containing
# `exit 0` made a child exit 0 without running its body, and a forged
# BASH_FUNC_python3%% was imported by an unprivileged grandchild.
# BASH_FUNC_* entries cannot be removed with `unset` -- their names are not valid
# identifiers and the environ entry survives (measured) -- so strip them by rebuilding
# the environment once, here. SHELLOPTS/BASHOPTS are readonly and cannot be unset;
# -p already ignores them.
unset BASH_ENV ENV
# Blank the dynamic-loader variables BEFORE anything below runs a binary. The
# `-u` list built further down only cleans the FINAL re-exec's child, but the
# enumerator (`env -0` / `perl`) and `printf` are themselves dynamically linked:
# on Linux a hostile LD_PRELOAD/LD_AUDIT executes inside THOSE processes first,
# and a preloaded enumerator can simply lie about the environment it reports.
# Assignment, not `unset`: `unset` is a shadowable builtin (see the note above),
# while assignment is grammar no exported function can intercept — and an EMPTY
# LD_PRELOAD/LD_AUDIT is inert to the loader, so blanking is as good as removing.
# Scope, stated honestly: this protects the binaries this block runs and every
# descendant. It CANNOT protect the interpreter already executing these lines --
# the loader acted before bash ran its first instruction, which no in-script step
# can undo. DYLD_* is not blanked here (it is a family, not a fixed name); it is
# still carried into the `-u` list below, and macOS ignores DYLD_* for the
# SIP-protected /usr/bin binaries this block invokes.
# Not locals: these arrive EXPORTED from the caller's environment, so assigning
# empty keeps them exported and inert for every child -- hence SC2034 per line.
# shellcheck disable=SC2034
LD_PRELOAD=
# shellcheck disable=SC2034
LD_AUDIT=
# shellcheck disable=SC2034
LD_LIBRARY_PATH=
# Same treatment for the Python loader variables, and for the same reason the LD_*
# trio needs the ASSIGNMENT form rather than the `-u` list below: the re-exec is
# conditional on that list being non-empty, so an environment carrying only
# PYTHONPATH would skip it entirely and hand every `python3 -c` here an attacker
# import path. That is not a theoretical descendant -- the backstop VERDICT
# VALIDATOR is one of those calls, so a forged `sitecustomize.py` runs before the
# code that decides whether a review passed. Measured: a hostile PYTHONPATH
# executed sitecustomize.py ahead of the `-c` body, and a hostile PYTHONUSERBASE
# got its usercustomize.py found, read and executed. Blanking is inert to Python
# for all three (measured), exactly as an empty LD_PRELOAD is inert to the loader.
# PYTHONSTARTUP is deliberately NOT here: measured, it applies only to interactive
# sessions and never to `-c`, so adding it would be hardening with no vector.
# Blanking PYTHONUSERBASE is NOT sufficient on its own: with it empty, site.py
# falls back to deriving the user site directory from $HOME, which this block does
# not strip -- so a hostile HOME still reaches usercustomize.py by a second route
# (measured: it executed). PYTHONNOUSERSITE closes that, because it disables user
# site-packages outright rather than relocating them, so no $HOME value can point
# at anything. It is the one entry here that must be EXPORTED and NON-EMPTY: the
# other three arrive exported already and are being emptied, while this one is
# usually absent and is a flag Python tests for presence, not value. It is
# deliberately absent from the `-u` strip list below -- this is the one Python
# variable that must SURVIVE into every descendant. Measured: ENABLE_USER_SITE
# becomes False, and ordinary stdlib use (json, sys -- all these call sites import)
# is unaffected.
# shellcheck disable=SC2034
PYTHONPATH=
# shellcheck disable=SC2034
PYTHONHOME=
# shellcheck disable=SC2034
PYTHONUSERBASE=
export PYTHONNOUSERSITE=1
# Enumerate NUL-delimited (`env -0`), never newline-delimited. `env` output is NOT one
# line per variable: a value holding an embedded newline followed by text shaped like
# `BASH_FUNC_x%%=...` renders as its own line, and the name parsed out of that PHANTOM
# names no real variable -- so `env -u` strips nothing, the carrier survives the exec,
# the child re-detects the same phantom, and the block re-execs forever. Measured: an
# unbounded exec loop, armed by one ordinary variable, by the very poisoned environment
# this block exists to strip. A NUL can appear in neither an environment name nor a
# value, so NUL-delimited entries are exact and that phantom cannot be constructed.
# The trailing sentinel is the exit-status channel `env -0` otherwise loses through the
# process substitution: `&&` emits it only when env succeeded, and it can only arrive
# LAST. A final entry that is not the sentinel therefore covers BOTH a failed
# enumeration AND a substitution that never opened (no /dev/fd, unwritable TMPDIR).
# Neither may be read as "nothing to strip" -- that skips the clean re-exec and hands
# every descendant the inherited entries -- so both refuse. The count bound stays as a
# backstop against a pathological environment; NUL parsing is already O(n).
_bd803_envclean=()
_bd803_last=
_bd803_count=0
# shellcheck disable=SC2312  # `env -0`'s status is deliberately not read here: the
# sentinel below IS the status channel, and splitting the substitution would
# reintroduce a capture that cannot carry NUL bytes.
while IFS= read -r -d '' _bd803_e; do
  _bd803_last=$_bd803_e
  _bd803_count=$((_bd803_count + 1))
  if [[ ${_bd803_count} -gt 4096 ]]; then
    printf '%s\n' "$0: environment listing too large — refusing to run unprivileged descendants (#803)" >&2
    exit 1
  fi
  # Dynamic-loader variables are stripped alongside the forged functions. Be exact
  # about what this does and does not buy: on Linux the loader honours LD_PRELOAD /
  # LD_AUDIT before bash executes a single instruction, so `-p` cannot protect THIS
  # process — that residual is unreachable from here, and a parent able to set them
  # is the parent, which could as easily have exec'd a different binary outright
  # (the same boundary the shadowable-`exec` note draws). What the strip does buy is
  # that the re-exec'd shell and EVERY descendant start loader-clean, which is the
  # same treatment resolve-cli.sh already gives each of its `env -i` children.
  case "$_bd803_e" in
    BASH_FUNC_*|LD_PRELOAD=*|LD_AUDIT=*|LD_LIBRARY_PATH=*|DYLD_*|PYTHONPATH=*|PYTHONHOME=*|PYTHONUSERBASE=*)
      _bd803_envclean+=(-u "${_bd803_e%%=*}") ;;
  esac
# `env -0` is GNU; BSD/older macOS `env` rejects it and exits non-zero having
# written nothing, which would refuse to start every hardened entry point on a
# platform this repo explicitly supports (bash 3.2 is the macOS default). perl is
# the fallback because it is already the portable stand-in `_portable_timeout`
# relies on, and %ENV is read straight from environ, so a BASH_FUNC_x%% key —
# not a valid shell identifier — is still visible to it. If BOTH are unavailable
# the sentinel never arrives and the entry point refuses, which is the correct
# direction: unknowable environment, no unprivileged descendants.
#
# The perl arm is itself environment-steerable, and it is reached with the hostile
# environment still in place: PERL5OPT/PERL5LIB load attacker code BEFORE the
# script runs, and a module that merely exits 0 produces an EMPTY enumeration that
# the outer `&&` still stamps with the sentinel — "nothing to strip", every
# BASH_FUNC_* inherited (measured: 0 bytes, rc 0). Closed twice over: `-T` makes
# perl ignore PERL5LIB/PERLLIB/PERL5OPT outright, the assignment prefixes blank
# them for belt and braces, and the count check after the loop refuses an
# enumeration that returned nothing at all — no real environment is empty, so a
# silent zero is a failure however it was produced.
done < <( { /usr/bin/env -0 2>/dev/null \
            || PERL5OPT='' PERL5LIB='' PERLLIB='' /usr/bin/perl -T -e 'print map { "$_=$ENV{$_}\0" } keys %ENV'; } \
          && /usr/bin/printf 'BD803-ENV-OK\0' )
# -lt 2, not -lt 1: the SENTINEL is itself one of the entries the loop counted, so
# an enumeration that returned nothing at all still arrives here with a count of 1.
# Any real environment carries at least PATH alongside it.
if [[ "$_bd803_last" != "BD803-ENV-OK" || "$_bd803_count" -lt 2 ]]; then
  printf '%s\n' "$0: cannot enumerate the environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
if [[ ${#_bd803_envclean[@]} -gt 0 ]]; then
  # A FAILED exec must not fall through. Non-interactive bash normally exits when
  # exec cannot run the command, but that behaviour is switchable (`execfail`), and
  # relying on an implicit exit for a security boundary means relying on a shell
  # option to stay off. The realistic failure is E2BIG: every stripped name adds a
  # `-u NAME` argument to an environment that is already large, and past ARG_MAX
  # the exec fails — at which point falling through would run the whole script with
  # exactly the BASH_FUNC_* entries this block exists to remove.
  exec /usr/bin/env "${_bd803_envclean[@]}" "${BASH:-/bin/bash}" -p "$0" "$@"
  printf '%s\n' "$0: cannot re-exec with a rebuilt environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
unset _bd803_envclean _bd803_e _bd803_last _bd803_count
# BD803-CLEAN-ENV-END
# run-shell-tests.sh — full-glob runner for the tests/test-*.sh gate suite.
#
# Replaces the hand-picked list that previously ran in CI (only ~15 of the
# suites), so a gate regression can no longer slip past because its test was
# never wired in. Local and CI run this SAME script, so "green here" means
# "green there".
#
# Classification per test:
#   PASS  — exit 0 and the last non-empty output line is NOT a `SKIP:` marker.
#   SKIP  — exit 0 and the last non-empty output line matches `^SKIP:`
#           (the repo's established self-skip convention: `echo "SKIP: …"; exit 0`).
#           A mid-test sub-case SKIP print does NOT count — the test still ends
#           on its pass/fail summary line, so only whole-test skips are caught.
#   FAIL  — any non-zero exit (including 124 = timeout).
#
# Skip-masking guard (fail-closed ALLOWLIST): only the tests in SKIP_ALLOWED
# below may report SKIP. ANY other test that skips — a gate/security suite, or a
# test that started self-skipping because a CI dependency went missing — fails
# the job as a coverage regression. An allowlist (not a denylist of "protected"
# suites) is the fail-closed choice: coverage can only be dropped by a conscious
# edit here, which is exactly the "gate suites always PASS, never SKIP" invariant
# the plan requires, extended to every non-allowlisted suite.
#
# Exit 0 iff every discovered test PASSed or (permissibly) SKIPped; exit 1 on
# any FAIL or skip-masking violation.
#
# Modes (0827 roadmap item 5 — sharded CI; docs/plans/2026-09-27-ci-shard-shell-tests.md):
#   (no args)                      run every discovered test (local use; unchanged)
#   --shard I/N --record FILE      run only shard I of N; write a completion record to FILE
#   --list-shard I/N               print shard I of N's test basenames, run nothing
#   --reconcile N DIR              aggregate check: DIR/shell-shard-*.tsv vs the live glob
#
# Env:
#   SHELL_TEST_TIMEOUT   per-test timeout in seconds (default 180)
#   SHELL_TEST_DURATIONS partition weights file (default scripts/ci/shell-test-durations.tsv)
set -uo pipefail   # NOT -e: each test's exit is handled explicitly below.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Portable per-test timeout (timeout → gtimeout → perl alarm). Reuse the repo
# helper so macOS/BSD (no GNU `timeout`) and Linux CI behave identically.
# resolve-cli.sh only runs top-level code under a `--json` direct-exec guard, so
# sourcing it is side-effect-free.
# shellcheck source=scripts/lib/resolve-cli.sh
# shellcheck disable=SC1091  # sourced at runtime; path is not statically followable without -x
source "$REPO_ROOT/scripts/lib/resolve-cli.sh"

# Default 180s (was 120): test-ultra-oracle.sh legitimately runs ~130s — several
# #458/#481 salvage tests sleep ~30s each to simulate hung/streamed-then-hung
# consults, and the tab-status probe needs two stability probes ≥15s apart. The
# suite outgrew the old 120s budget; 180 restores headroom without masking a hang.
PER_TEST_TIMEOUT="${SHELL_TEST_TIMEOUT:-180}"

# Per-test timeout OVERRIDES (basename → seconds), for a specific suite that
# legitimately needs more than the shared default without loosening the
# 180s budget for the other ~100 tests (which would mask a genuine hang in
# any of THEM for an extra minute-plus). Keep this list minimal and justify
# each entry, same discipline as SKIP_ALLOWED above. A `case` lookup (not
# `declare -A`) — this script's own #519 sibling proved `env bash` resolves
# to macOS's system /bin/bash 3.2 whenever PATH is stripped, which has no
# associative arrays; a case statement is portable to 3.2 and 5.x alike.
#
# test-impl-gate-scope-519: #519's classifier-parity matrices (wrapper x
# payload x boundary, -m module x cluster x escape-width, …) are driven
# rather than sampled by design (see the file's own header — a hand-picked
# case is how launchers like flock/script went missing before), and that
# breadth is >300 `bash_decision` calls, each forking python3 twice (JSON
# construction + the gate's own embedded parser) plus the gate's bash
# process itself. Measured 190-230s wall on a dev machine — already past
# 180s before accounting for CI's slower/shared CPUs. Splitting the file
# would just move the same subprocess count across file boundaries; the
# cost is inherent to per-case subprocess isolation, which is what makes
# each case an honest end-to-end run of the real gate rather than a stub.
# Takes the MAX of the override and PER_TEST_TIMEOUT, not the override
# alone — an operator-set SHELL_TEST_TIMEOUT larger than the override must
# still win, otherwise this floor would silently shrink an explicit ask.
#
# 420 -> 900 (#562): the suite was sitting right on the old ceiling and #562's
# regression fixtures tipped it over. The three PR heads bracket it -- shell-tests
# took 11m55s at f97817c and 12m48s at 76d6b4f, both green, then the very next head
# was hard-killed at 420s. Nothing got slower: the classifier itself measures 1.93s
# per 1600 in-process calls against 1.97s before that round, so the cost is purely
# the added `bash_decision` cases, each of which is three processes. Raised with
# headroom above the observed runtime rather than tuned to it -- same reasoning as
# the job-level ceiling in tests.yml, and for the same reason: a cap set at the
# measurement reproduces this false failure on the next PR that adds a case.
#
# test-impl-gate-scope-553: the same shape as its #519 sibling, one ticket later. The
# suite drives the REAL gate against two throwaway repos -- one holding a pending review
# so a block is attributable to the classifier, one clean so a block is attributable to
# the unconditional helper guard -- and that doubling is what makes each verdict
# attributable at all. Its several-hundred-case sweeps already run IN PROCESS for exactly
# this reason (see the file's own header); what remains is ~150 end-to-end gate
# invocations, each three processes. Measured 193s at the #553 branch head and 185s with
# the interpreter-decoy cases added -- already past the 180s default before CI's slower,
# shared CPUs are accounted for, and the growth is the fail-closed rules this ticket adds
# rather than anything getting slower. Same headroom reasoning as the entry above: set
# above the observation, not at it, so the next PR that adds a case does not reproduce
# this failure.
#
# test-litmus-mode-transition: #847's suite, 411 assertions driving the real runner
# through FAIL->other-mode recovery, retirement journals and the orphan watchdog. Measured
# 1074s locally on a PASSING run (2026-09-23); the 180s default killed it on CI. 1500 is
# headroom above that observation, same reasoning as above. Splitting the file is the
# upgrade path if the job ceiling in tests.yml becomes the constraint.
test_timeout() {   # <basename> -> prints the effective per-test timeout
  local override=0
  case "$1" in
    test-impl-gate-scope-519) override=900 ;;
    test-impl-gate-scope-553) override=600 ;;
    test-litmus-mode-transition) override=1500 ;;
  esac
  if [ "$override" -gt "$PER_TEST_TIMEOUT" ]; then
    printf '%s\n' "$override"
  else
    printf '%s\n' "$PER_TEST_TIMEOUT"
  fi
}

# The ONLY tests permitted to SKIP. Everything else — every gate/security suite
# included — must run to completion; an unexpected SKIP fails the job (see the
# skip-masking guard above). Keep this list minimal and justify each entry.
# Exactly ONE entry, justified immediately below. (The previous occupant,
# test-gateway-arbiter-claude-json-residual — a real-claude round-trip gated
# behind BLUEPRINT_ARBITER_LIVE_TEST=1 — went out with the gateway rung, ADR
# 0019.) Every other discovered test must run to completion; an unexpected SKIP
# fails the job.
# test-litmus-pr-history: the cross-run PR store lives under the PASSWORD-DATABASE
# home (#811 — $HOME is repo-injectable, so there is no $HOME fallback). Some
# sandboxes hand the session a writable $HOME while the passwd home is root-owned;
# there the store cannot exist and the suite has nothing to assert. It skips ONLY
# in that case — a store missing while the passwd home IS writable is treated as a
# regression and fails — so this entry cannot mask a code defect, only an
# environment. GitHub's ubuntu runner has a writable passwd home, so CI never
# takes the skip path and coverage there is unaffected.
SKIP_ALLOWED=(test-litmus-pr-history)

is_skip_allowed() {
  local base="$1" n
  # `${arr[@]}` on an EMPTY array is "unbound" under `set -u` on bash 3.2 (macOS),
  # so check the count first — the allowlist is empty by design right now.
  [ "${#SKIP_ALLOWED[@]}" -eq 0 ] && return 1
  for n in "${SKIP_ALLOWED[@]}"; do
    [[ "$n" == "$base" ]] && return 0
  done
  return 1
}

MODE=run SHARD_I=0 SHARD_N=0 RECORD_FILE='' RECONCILE_DIR=''
usage() {
  echo "usage: run-shell-tests.sh [--shard I/N --record /abs/file | --list-shard I/N | --reconcile N /abs/dir]" >&2
  exit 2
}
parse_shard() {   # <I/N> -> SHARD_I, SHARD_N (1 <= I <= N <= 99), else usage
  [[ "$1" =~ ^([1-9][0-9]?)/([1-9][0-9]?)$ ]] || usage
  SHARD_I=${BASH_REMATCH[1]} SHARD_N=${BASH_REMATCH[2]}
  [ "$SHARD_I" -le "$SHARD_N" ] || usage
}
case "${1:-}" in
  "") [ $# -eq 0 ] || usage ;;
  --shard)
    [ $# -eq 4 ] && [ "$3" = --record ] && [[ "$4" == /* ]] || usage
    parse_shard "$2"; MODE=shard RECORD_FILE=$4 ;;
  --list-shard)
    [ $# -eq 2 ] || usage
    parse_shard "$2"; MODE=list ;;
  --reconcile)
    [ $# -eq 3 ] && [[ "$2" =~ ^[1-9][0-9]?$ ]] && [[ "$3" == /* ]] || usage
    SHARD_N=$2 RECONCILE_DIR=$3 MODE=reconcile ;;
  *) usage ;;
esac

DURATIONS_FILE="${SHELL_TEST_DURATIONS:-$REPO_ROOT/scripts/ci/shell-test-durations.tsv}"
# Weight for a test absent from the durations file — every newly added test until the
# file is refreshed. It affects balance only: reconciliation, not the weights, is what
# guarantees every discovered test ran exactly once.
DEFAULT_WEIGHT=10

# shard_members <I> <N> <base>... -> the bases shard I of N owns, one per line.
# Longest-processing-time greedy: heaviest first (ties by name), each onto the lightest
# shard so far (ties to the lowest index). Pure function of (test list, weights file),
# so every shard computes the same partition independently. The weights are read with
# getline in BEGIN, not the NR==FNR idiom, which misreads stdin as weights when the
# weights file is empty. A malformed or unreadable weights file fails closed.
shard_members() {
  local i="$1" n="$2"; shift 2
  printf '%s\n' "$@" | awk -v want="$i" -v n="$n" -v dflt="$DEFAULT_WEIGHT" -v dfile="$DURATIONS_FILE" '
    BEGIN {
      while ((r = (getline line < dfile)) > 0) {
        ln++
        if (line ~ /^#/ || line == "") continue
        nf = split(line, f, "\t")
        if (nf != 2 || f[2] !~ /^[0-9]+$/) {
          print "ERROR: bad durations line " ln ": " line > "/dev/stderr"; bad = 1; exit 1
        }
        w[f[1]] = f[2] + 0
      }
      if (r < 0) { print "ERROR: cannot read durations file: " dfile > "/dev/stderr"; bad = 1; exit 1 }
    }
    { k++; name[k] = $0; wt[k] = ($0 in w) ? w[$0] : dflt }
    END {
      if (bad) exit 1
      for (a = 2; a <= k; a++) {
        nm = name[a]; x = wt[a]
        for (b = a - 1; b >= 1 && (wt[b] < x || (wt[b] == x && name[b] > nm)); b--) {
          name[b + 1] = name[b]; wt[b + 1] = wt[b]
        }
        name[b + 1] = nm; wt[b + 1] = x
      }
      for (s = 1; s <= n; s++) load[s] = 0
      for (a = 1; a <= k; a++) {
        best = 1
        for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
        load[best] += wt[a]
        if (best == want) print name[a]
      }
    }'
}

# reconcile_shards <N> <dir> <discovered-list-file> — the aggregate `shell-tests` verdict.
# Every test the LIVE glob discovers must be ASSIGNED by exactly one shard and carry
# exactly one DONE line with a PASS/SKIP verdict; shards 1..N must each have produced
# exactly one record with a matching N header and an END line. Anything else fails,
# naming the test or shard. A shard that never ran (skipped, cancelled, crashed before
# writing) has no record file at all, which reads as "no record".
# Per-file protocol, mirroring exactly what the runner writes: two-field N and SHARD
# headers, one END as the last line whose count equals the file's DONE lines, numeric
# DONE fields, every DONE naming a test the same file ASSIGNED, and no record file
# without a valid SHARD line. A truncated or spliced record therefore fails.
reconcile_shards() {
  local n="$1" dir="$2" listf="$3"
  awk -F'\t' -v n="$n" -v listf="$listf" '
    function err(m) { print "RECONCILE FAIL: " m; bad = 1 }
    FILENAME == listf { disc[$0] = 1; nd++; next }
    FILENAME != cur { cur = FILENAME; nrec++; sh = ""; fended = 0; fdone = 0 }
    fended { err(FILENAME ":" FNR ": line after END"); next }
    FNR == 1 { if ($1 != "N" || $2 != n || NF != 2) err(FILENAME ": header is not N\t" n); next }
    FNR == 2 {
      if ($1 != "SHARD" || NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > n) { err(FILENAME ": bad SHARD line"); next }
      sh = $2; seen[sh]++; nseen++; next
    }
    $1 == "ASSIGNED" && NF == 2 { assigned[$2]++; inshard[FILENAME, $2] = 1; next }
    $1 == "DONE" && NF == 5 {
      if ($4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/) { err(FILENAME ":" FNR ": non-numeric DONE field"); next }
      if (!((FILENAME, $2) in inshard)) err(FILENAME ": DONE for a test this shard did not ASSIGN: " $2)
      done[$2]++; fdone++; verdict[$2] = $3; dur[$2] = $4; next
    }
    $1 == "END" && NF == 2 {
      if ($2 !~ /^[0-9]+$/ || $2 + 0 != fdone) err(FILENAME ": END count " $2 " != " fdone " DONE lines")
      fended = 1; if (sh != "") ended[sh] = 1; next
    }
    { err(FILENAME ":" FNR ": unrecognised record line") }
    END {
      if (nrec != nseen) err((nrec - nseen) " record file(s) without a valid SHARD line")
      for (s = 1; s <= n; s++) {
        if (!(s in seen)) err("shard " s "/" n ": no record (shard missing, skipped or cancelled)")
        else if (seen[s] > 1) err("shard " s "/" n ": more than one record")
        else if (!(s in ended)) err("shard " s "/" n ": record has no END line (shard did not finish)")
      }
      for (t in disc) {
        if (!(t in assigned)) err("unassigned: " t)
        else if (assigned[t] > 1) err("assigned twice: " t)
        else if (!(t in done)) err("missing completion record: " t)
        else if (done[t] > 1) err("completion recorded twice: " t)
        else if (verdict[t] != "PASS" && verdict[t] != "SKIP") err("not passing: " t " (" verdict[t] ")")
      }
      for (t in assigned) if (!(t in disc)) err("assigned but not discovered: " t)
      for (t in done) if (!(t in assigned)) err("completed but never assigned: " t)
      if (bad) exit 1
      for (t in done) print "duration\t" t "\t" dur[t]
      print "OK: reconciled " nd " discovered tests across " n " shards"
    }' "$listf" "$dir"/shell-shard-*.tsv
}

pass=0 skip=0 fail=0
failed_names=()
skipped_names=()
subskipped_names=()

# Capture each test's output to a regular file, NOT a `$(…)` pipe. A timed-out
# test may leave a descendant that survives the TERM (the portable-timeout
# helpers signal only the direct child); a surviving descendant holding a
# command-substitution pipe's write end would block us past the timeout. A file
# redirect has no such back-pressure — we read the file after the helper returns.
out_file="$(mktemp)"
# #803: compose the staged-lib cleanup — this script sources resolve-cli.sh BEFORE
# installing this trap, so the library's own EXIT handler is registered and then
# overwritten here. Without composing, the ~250KB staged copy is left in TMPDIR on
# every invocation. See run-review-loop.sh for the same composition.
trap 'rm -f "$out_file"; declare -F _bd803_cleanup_review_lib_exec >/dev/null && _bd803_cleanup_review_lib_exec || true' EXIT

shopt -s nullglob
tests=(tests/test-*.sh)
if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "ERROR: no tests matched tests/test-*.sh" >&2
  exit 1
fi
# Basenames become tab-separated fields in shard records; refuse any name that could
# split or forge a field rather than let the reconcile misread it.
all_bases=()
for t in "${tests[@]}"; do
  b=${t##*/}; b=${b%.sh}
  [[ "$b" =~ ^test-[A-Za-z0-9._-]+$ ]] || { echo "ERROR: unsupported test file name: $t" >&2; exit 1; }
  all_bases+=("$b")
done

if [[ "$MODE" == reconcile ]]; then
  printf '%s\n' "${all_bases[@]}" >"$out_file"
  reconcile_shards "$SHARD_N" "$RECONCILE_DIR" "$out_file"
  exit $?
fi

if [[ "$MODE" == shard || "$MODE" == list ]]; then
  members="$(shard_members "$SHARD_I" "$SHARD_N" "${all_bases[@]}")" || exit 1
  if [[ "$MODE" == list ]]; then
    [ -n "$members" ] && printf '%s\n' "$members"
    exit 0
  fi
  tests=()
  while IFS= read -r b; do [ -n "$b" ] && tests+=("tests/$b.sh"); done <<<"$members"
  { printf 'N\t%s\nSHARD\t%s\n' "$SHARD_N" "$SHARD_I"
    for t in ${tests[@]+"${tests[@]}"}; do b=${t##*/}; printf 'ASSIGNED\t%s\n' "${b%.sh}"; done
  } >"$RECORD_FILE" || { echo "ERROR: cannot write $RECORD_FILE" >&2; exit 1; }
  echo "Shard ${SHARD_I}/${SHARD_N}: ${#tests[@]} of ${#all_bases[@]} discovered shell tests (per-test timeout ${PER_TEST_TIMEOUT}s, per-test overrides may extend individual suites)"
else
  echo "Discovered ${#tests[@]} shell tests (per-test timeout ${PER_TEST_TIMEOUT}s, per-test overrides may extend individual suites)"
fi
echo

# record <field>... — append one tab-joined line to the shard record (shard mode only).
# A failed append exits: a record that silently stops growing would reconcile as
# "missing completion record", but naming the real cause is cheaper to debug.
record() {
  [[ "$MODE" != shard ]] && return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$RECORD_FILE" || { echo "ERROR: cannot append to $RECORD_FILE" >&2; exit 1; }
}

# Sub-case skips (#821 residual): a suite that ends on its pass/fail summary can still
# have skipped rows mid-file, which the verdict below cannot see. Shown, not failed —
# see the plan's decision table. Matches SKIP after an optional non-alphanumeric prefix
# ("  SKIP:", "⏭️  SKIP:", "↳ SKIP:", "[SKIP]") or after an optional "label:" prefix
# ("test_af: SKIP —"), the formats the suites use today. A format outside these shapes
# is not counted; the count is informational, so a miss only hides a line from the log.
SUBSKIP_RE='^[^[:alnum:]]*([[:alnum:]_.-]+:[[:space:]]*)?\[?SKIP\]?([:[:space:]]|$)'

# ${tests[@]+…}: a shard can own zero tests, and bash 3.2 treats an empty "${tests[@]}"
# as unbound under set -u.
for t in ${tests[@]+"${tests[@]}"}; do
  base="$(basename "$t" .sh)"
  this_timeout="$(test_timeout "$base")"
  started=$SECONDS
  _portable_timeout "$this_timeout" /bin/bash -p "$t" >"$out_file" 2>&1
  rc=$?
  dur=$((SECONDS - started))
  last="$(grep -vE '^[[:space:]]*$' "$out_file" | tail -n1)"
  subskips="$(grep -cE "$SUBSKIP_RE" "$out_file" || true)"

  if [[ "$rc" -eq 0 ]] && printf '%s' "$last" | grep -q '^SKIP:'; then
    if is_skip_allowed "$base"; then
      echo "SKIP: $base (${dur}s) — ${last#SKIP:}"
      skip=$((skip + 1))
      skipped_names+=("$base")
      record DONE "$base" SKIP "$dur" 0
    else
      echo "FAIL (unexpected skip — coverage regression): $base → $last"
      echo "    (if this skip is intentional, add $base to SKIP_ALLOWED with a reason)"
      fail=$((fail + 1))
      failed_names+=("$base")
      record DONE "$base" FAIL "$dur" 0
    fi
  elif [[ "$rc" -eq 0 ]]; then
    if [[ "$subskips" -gt 0 ]]; then
      echo "PASS: $base (${dur}s, ${subskips} sub-case SKIP)"
      grep -E "$SUBSKIP_RE" "$out_file" | head -n 3 | sed 's/^/    ~ /'
      subskipped_names+=("$base")
    else
      echo "PASS: $base (${dur}s)"
    fi
    pass=$((pass + 1))
    record DONE "$base" PASS "$dur" "$subskips"
  else
    if [[ "$rc" -eq 124 ]]; then
      echo "FAIL (timeout ${this_timeout}s): $base (${dur}s)"
    else
      echo "FAIL (rc=$rc): $base (${dur}s)"
    fi
    record DONE "$base" FAIL "$dur" 0
    # Surface explicit failure/error lines first — for a suite with many
    # assertions the failing ones are often earlier than the tail, so a bare
    # `tail` hides them (esp. for CI-only failures). Then show the tail for context.
    grep -nE 'FAIL|Error|error:|not found|expected=' "$out_file" | head -n 30 | sed 's/^/    ! /'
    tail -n 20 "$out_file" | sed 's/^/    | /'
    fail=$((fail + 1))
    failed_names+=("$base")
  fi
done
record END "$((pass + skip + fail))"

echo
echo "──────────────────────────────────────────"
echo "discovered=${#tests[@]}  pass=$pass  skip=$skip  fail=$fail"
[[ "$skip" -gt 0 ]] && printf 'skipped: %s\n' "${skipped_names[*]}"
[[ "${#subskipped_names[@]}" -gt 0 ]] && printf 'sub-case skips in: %s\n' "${subskipped_names[*]}"
if [[ "$fail" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${failed_names[*]}"
  exit 1
fi
echo "OK: all discovered shell tests passed (or permissibly skipped)."
exit 0
