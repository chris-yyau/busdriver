#!/usr/bin/env bash
# #776 — POSIX numeric-validation case must not be misread as a guarded helper call.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() {
  local payload
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
    "$1" 2>/dev/null) || { printf 'ERROR'; return; }
  python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

# Exact POSIX shape from issue #776 (empty-alt + digit-negation glob + catch-all).
# shellcheck disable=SC2016  # $X must remain literal inside the generated case subject
CASE_CMD=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("X=abc; case "+dq+"$X"+dq+" in "+q+q+"|"+s+"[!0-9]"+s+") echo "+dq+"a"+dq+" ;; "+s+") echo "+dq+"b"+dq+" ;; esac")')
got=$(verdict "$CASE_CMD")
if [[ "$got" == "OK|" ]]; then
  ok "#776 POSIX numeric-validation case -> allowed"
else
  no "#776 POSIX numeric-validation case -> allowed" "got=${got:-<empty>}"
fi

# Fail-closed: a real helper invocation still blocks.
HELPER_CMD=$(python3 -c 'print("python3 -I hooks/gate-scripts/lib/"+"lease"+"_"+"slot"+".py .claude 20 0 3600")')
got=$(verdict "$HELPER_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 real helper invocation still blocks"
else
  no "#776 real helper invocation still blocks" "got=${got:-<empty>}"
fi


# Structured operand still blocks (producer filter must not weaken command-position).
STRUCT_CMD=$(python3 -c 's=chr(42);print("cd hooks/gate-scripts/lib && python3 "+s+"[!0-9]"+s)')
got=$(verdict "$STRUCT_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 digit-negation glob as python operand still blocks"
else
  no "#776 digit-negation glob as python operand still blocks" "got=${got:-<empty>}"
fi

# Abandoned/eval path still fail-closed (interpreter-adjacent globs are kept).
EVAL_CMD=$(python3 -c 's=chr(42);print("eval \"cd hooks/gate-scripts/lib && python3 "+s+"[!0-9]"+s+"\"")')
got=$(verdict "$EVAL_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 eval digit-negation glob still blocks"
else
  no "#776 eval digit-negation glob still blocks" "got=${got:-<empty>}"
fi

# Unparseable heredoc containing the same case shape must allow (abandoned fallback).
# shellcheck disable=SC2016  # $X must remain literal in generated case subject
HEREDOC_CMD=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("cat <<EOF\nit isn"+q+"t\nX=1; case "+dq+"$X"+dq+" in "+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac\nEOF")')
got=$(verdict "$HEREDOC_CMD")
if [[ "$got" == "OK|" ]]; then
  ok "#776 heredoc numeric-validation case -> allowed"
else
  no "#776 heredoc numeric-validation case -> allowed" "got=${got:-<empty>}"
fi


# Inert interpreter-looking text in a heredoc is data, not an invocation.
HEREDOC_PY_CMD=$(python3 -c 'q=chr(39);s=chr(42);print("cat <<EOF\nit isn"+q+"t\npython3 "+s+"[!0-9]"+s+"\nEOF")')
got=$(verdict "$HEREDOC_PY_CMD")
if [[ "$got" == "OK|" ]]; then
  ok "#776 heredoc inert python3 digit-negation -> allowed"
else
  no "#776 heredoc inert python3 digit-negation -> allowed" "got=${got:-<empty>}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
