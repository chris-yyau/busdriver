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

check() { # name expected command
  local got; got=$(verdict "$3")
  if [[ "$got" == "$2" ]]; then
    echo "PASS: $1"; pass=$((pass+1))
  else
    echo "FAIL: $1 — expected $2 got $got"; fail=$((fail+1))
  fi
}
