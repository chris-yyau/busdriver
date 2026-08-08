# shellcheck shell=bash
# careful-guard-harness.sh — shared verdict/check harness for the careful-guard
# test files. Source it; do not execute it.
#
# It exists because the four careful-guard suites each carried a verbatim copy
# of this harness, INCLUDING the exit-status check. That check is a correctness
# property, not boilerplate: without it a guard that dies before printing
# anything yields empty output, which matches no "ask" and reports a clean
# "allow" — a false PASS in exactly the files meant to prevent one. Four copies
# meant four chances for that property to drift out of one of them.
#
# Callers must define GUARD (path to careful-guard.sh) and the counters
# `pass` and `fail` before sourcing.

# <command> -> ask|allow|ERROR(rc=N).
#
# bypassPermissions is deliberate: every check is live in that mode, so nothing
# under test is masked by the auto-mode stand-down.
verdict() {
  local payload out rc
  payload=$(python3 -c '
import json, sys
print(json.dumps({"permission_mode": "bypassPermissions",
                  "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$1")
  if [[ -z "$payload" ]]; then echo "ERROR(payload)"; return; fi
  # Read the exit status too — see the false-PASS note above.
  out=$("$GUARD" <<<"$payload"); rc=$?
  if [[ $rc -ne 0 ]]; then echo "ERROR(rc=$rc)"; return; fi
  if [[ "$out" == *'"permissionDecision":"ask"'* ]]; then
    echo "ask"
  elif [[ "$out" == "{}" ]]; then
    # The guard's allow path always emits exactly `{}` — never partial JSON,
    # never a trailing newline inside the value. Anything else with rc=0
    # (empty output, or unexpected JSON) is NOT a proven "allow"; treating it
    # as one is the false-PASS this harness exists to prevent (a guard that
    # printed nothing would otherwise match no "ask" and read as a clean
    # "allow").
    echo "allow"
  else
    echo "ERROR(out=$out)"
  fi
}

_harness_check() { # name expected command
  local got; got=$(verdict "$3")
  if [[ "$got" == "$2" ]]; then
    echo "PASS: $1"; pass=$((pass+1))
  else
    echo "FAIL: $1 — expected $2 got $got"; fail=$((fail+1))
  fi
}

# Suites may override `check` to add their own fixture oracle (see
# test-careful-guard-differential.sh's `bash -n` wrapper); the comparison
# logic itself stays in `_harness_check` so an override can delegate to it by
# name instead of reading the harness source back out with `declare -f`.
#
# NOT applying that `bash -n` oracle here by default, despite the tempting
# symmetry: several OTHER suites' fixtures are deliberately not standalone-
# parseable (extglob patterns without `shopt -s extglob`, a segment-level
# unbalanced `"${T"` proving the brace-must-balance regex, a bare unmatched
# paren) — they are exact TEXT the guard's regex layer must classify
# correctly, not scripts anyone would ever hand to `bash -c`. Measured:
# forcing `bash -n` on every suite here broke 4 previously-passing checks in
# test-careful-guard-mktemp.sh and test-careful-guard-truncate-context.sh.
# The oracle is real value where the SEEDS are meant to always be valid bash
# (differential.sh's whole point), not a safe default everywhere.
check() { _harness_check "$@"; }
