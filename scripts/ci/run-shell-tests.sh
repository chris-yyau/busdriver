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
# Residual, stated honestly: with PYTHONUSERBASE blank, site.py derives the user
# site directory from $HOME, which this block does not strip -- a hostile HOME
# still reaches usercustomize.py. That is the passwd-home boundary (#811/#813),
# not something this block can close.
# shellcheck disable=SC2034
PYTHONPATH=
# shellcheck disable=SC2034
PYTHONHOME=
# shellcheck disable=SC2034
PYTHONUSERBASE=
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
# Env:
#   SHELL_TEST_TIMEOUT   per-test timeout in seconds (default 180)
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
test_timeout() {   # <basename> -> prints the effective per-test timeout
  local override=0
  case "$1" in
    test-impl-gate-scope-519) override=900 ;;
    test-impl-gate-scope-553) override=600 ;;
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
# Currently EMPTY: the only entry (test-gateway-arbiter-claude-json-residual, a
# real-claude round-trip gated behind BLUEPRINT_ARBITER_LIVE_TEST=1) was deleted
# with the gateway rung (ADR 0019). Every discovered test must now run to
# completion; an unexpected SKIP fails the job.
SKIP_ALLOWED=()

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

pass=0 skip=0 fail=0
failed_names=()
skipped_names=()

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

echo "Discovered ${#tests[@]} shell tests (per-test timeout ${PER_TEST_TIMEOUT}s, per-test overrides may extend individual suites)"
echo

for t in "${tests[@]}"; do
  base="$(basename "$t" .sh)"
  this_timeout="$(test_timeout "$base")"
  _portable_timeout "$this_timeout" /bin/bash -p "$t" >"$out_file" 2>&1
  rc=$?
  last="$(grep -vE '^[[:space:]]*$' "$out_file" | tail -n1)"

  if [[ "$rc" -eq 0 ]] && printf '%s' "$last" | grep -q '^SKIP:'; then
    if is_skip_allowed "$base"; then
      echo "SKIP: $base — ${last#SKIP:}"
      skip=$((skip + 1))
      skipped_names+=("$base")
    else
      echo "FAIL (unexpected skip — coverage regression): $base → $last"
      echo "    (if this skip is intentional, add $base to SKIP_ALLOWED with a reason)"
      fail=$((fail + 1))
      failed_names+=("$base")
    fi
  elif [[ "$rc" -eq 0 ]]; then
    echo "PASS: $base"
    pass=$((pass + 1))
  else
    if [[ "$rc" -eq 124 ]]; then
      echo "FAIL (timeout ${this_timeout}s): $base"
    else
      echo "FAIL (rc=$rc): $base"
    fi
    # Surface explicit failure/error lines first — for a suite with many
    # assertions the failing ones are often earlier than the tail, so a bare
    # `tail` hides them (esp. for CI-only failures). Then show the tail for context.
    grep -nE 'FAIL|Error|error:|not found|expected=' "$out_file" | head -n 30 | sed 's/^/    ! /'
    tail -n 20 "$out_file" | sed 's/^/    | /'
    fail=$((fail + 1))
    failed_names+=("$base")
  fi
done

echo
echo "──────────────────────────────────────────"
echo "discovered=${#tests[@]}  pass=$pass  skip=$skip  fail=$fail"
[[ "$skip" -gt 0 ]] && printf 'skipped: %s\n' "${skipped_names[*]}"
if [[ "$fail" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${failed_names[*]}"
  exit 1
fi
echo "OK: all discovered shell tests passed (or permissibly skipped)."
exit 0
