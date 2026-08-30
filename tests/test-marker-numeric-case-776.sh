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

HELPER_CMD=$(python3 -c 'print("python3 -I hooks/gate-scripts/lib/"+"lease"+"_"+"slot"+".py .claude 20 0 3600")')
got=$(verdict "$HELPER_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 real helper invocation still blocks"
else
  no "#776 real helper invocation still blocks" "got=${got:-<empty>}"
fi

STRUCT_CMD=$(python3 -c 's=chr(42);print("cd hooks/gate-scripts/lib && python3 "+s+"[!0-9]"+s)')
got=$(verdict "$STRUCT_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 digit-negation glob as python operand still blocks"
else
  no "#776 digit-negation glob as python operand still blocks" "got=${got:-<empty>}"
fi


# Producer text that names a helper still blocks when the receiver is digit-negation-only.
PIPE_CMD=$(python3 -c 's=chr(42);h="lease"+"_"+"slot"+".py";print("printf \"python3 hooks/gate-scripts/lib/"+h+" x\" | "+s+"[!0-9]"+s)')
got=$(verdict "$PIPE_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 printf helper | digit-negation receiver still blocks"
else
  no "#776 printf helper | digit-negation receiver still blocks" "got=${got:-<empty>}"
fi

# Sole digit-negation producer feeding a shell must stay fail-closed (Codex on #800).
SOLE_CMD=$(python3 -c 's=chr(42);print(s+"[!0-9]"+s+" | bash")')
got=$(verdict "$SOLE_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 sole digit-negation producer | bash still blocks"
else
  no "#776 sole digit-negation producer | bash still blocks" "got=${got:-<empty>}"
fi

# Digit-negation as a real middle producer must stay fail-closed (Litmus HIGH on #800).
MID_CMD=$(python3 -c 's=chr(42);print("printf x | "+s+"[!0-9]"+s+" | bash")')
got=$(verdict "$MID_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 printf | digit-negation | bash still blocks"
else
  no "#776 printf | digit-negation | bash still blocks" "got=${got:-<empty>}"
fi

# Empty case arm — `) ;;` must still allow the numeric-validation shape.
# shellcheck disable=SC2016
EMPTY_ARM=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("X=abc; case "+dq+"$X"+dq+" in "+q+q+"|"+s+"[!0-9]"+s+");; "+s+") : ;; esac")')
got=$(verdict "$EMPTY_ARM")
if [[ "$got" == "OK|" ]]; then
  ok "#776 empty case arm numeric pattern -> allowed"
else
  no "#776 empty case arm numeric pattern -> allowed" "got=${got:-<empty>}"
fi

# Parenthesized digit-negation producer must stay fail-closed.
PAREN_CMD=$(python3 -c 's=chr(42);print("("+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$PAREN_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 parenthesized digit-negation | bash still blocks"
else
  no "#776 parenthesized digit-negation | bash still blocks" "got=${got:-<empty>}"
fi

# Multi-alternative case list must stay allowed (Litmus HIGH on #800).
# shellcheck disable=SC2016
MULTI=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("X=abc; case "+dq+"$X"+dq+" in "+q+q+"|"+s+"[!0-9]"+s+"|foo) : ;; "+s+") : ;; esac")')
got=$(verdict "$MULTI")
if [[ "$got" == "OK|" ]]; then
  ok "#776 multi-alternative numeric case -> allowed"
else
  no "#776 multi-alternative numeric case -> allowed" "got=${got:-<empty>}"
fi

# Grouped real pipeline with digit-negation must stay fail-closed.
GROUP_CMD=$(python3 -c 's=chr(42);print("(printf x | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$GROUP_CMD")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 grouped printf | digit-negation | bash still blocks"
else
  no "#776 grouped printf | digit-negation | bash still blocks" "got=${got:-<empty>}"
fi

# Spoofed case/in words in a real pipeline must stay fail-closed.
SPOOF=$(python3 -c 's=chr(42);print("(printf case in | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$SPOOF")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 spoofed case in words | bash still blocks"
else
  no "#776 spoofed case in words | bash still blocks" "got=${got:-<empty>}"
fi

# Comment line between in and empty-alt must still allow the shape.
# shellcheck disable=SC2016
COMM=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("X=abc; case "+dq+"$X"+dq+" in\n# c\n"+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$COMM")
if [[ "$got" == "OK|" ]]; then
  ok "#776 comment before empty-alt numeric case -> allowed"
else
  no "#776 comment before empty-alt numeric case -> allowed" "got=${got:-<empty>}"
fi

# Empty-quoted subshell pipeline must stay fail-closed (Litmus HIGH on #800).
EMPTY_SUB=$(python3 -c 's=chr(42);q=chr(39);print("("+q+q+" | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$EMPTY_SUB")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 empty-quoted subshell | bash still blocks"
else
  no "#776 empty-quoted subshell | bash still blocks" "got=${got:-<empty>}"
fi

# Optional case-item opener must still allow the shape (Litmus HIGH).
# shellcheck disable=SC2016
OPT_PAREN=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("case "+dq+"$X"+dq+" in ("+q+q+"|"+s+"[!0-9]"+s+") : ;; (*) : ;; esac")')
got=$(verdict "$OPT_PAREN")
if [[ "$got" == "OK|" ]]; then
  ok "#776 optional case-item opener numeric pattern -> allowed"
else
  no "#776 optional case-item opener numeric pattern -> allowed" "got=${got:-<empty>}"
fi

# Combined-op group opener must stay fail-closed (Litmus HIGH).
COMBINED=$(python3 -c 's=chr(42);q=chr(39);print("false ||(printf case in "+q+q+" | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$COMBINED")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 combined-op group opener | bash still blocks"
else
  no "#776 combined-op group opener | bash still blocks" "got=${got:-<empty>}"
fi

# Comment lines before empty-alt must still allow (Litmus MEDIUM).
# shellcheck disable=SC2016
COMM3=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("X=1; case "+dq+"$X"+dq+" in\n# a\n# b\n# c\n"+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$COMM3")
if [[ "$got" == "OK|" ]]; then
  ok "#776 three comment lines before empty-alt -> allowed"
else
  no "#776 three comment lines before empty-alt -> allowed" "got=${got:-<empty>}"
fi

# Concatenated empty quotes are still an empty alternative.
# shellcheck disable=SC2016
CONCAT=$(python3 -c 'q=chr(39);dq=chr(34);s=chr(42);print("case "+dq+"x"+dq+" in "+q+q+dq+dq+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$CONCAT")
if [[ "$got" == "OK|" ]]; then
  ok "#776 concatenated empty-alt quotes -> allowed"
else
  no "#776 concatenated empty-alt quotes -> allowed" "got=${got:-<empty>}"
fi

# --- Litmus iteration-3 findings on #800: case context must be parser state, not nearby text.

# HIGH: `case`/`in` as printf OPERANDS before a real subshell pipeline must not read as a
# case pattern. Distinct from the group-internal spoof above: the words sit BEFORE the
# group and the group carries the empty alternative.
STATE_SPOOF=$(python3 -c 'q=chr(39);s=chr(42);print("printf case in; ("+q+q+" | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$STATE_SPOOF")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 case/in operands before a real group | bash still blocks"
else
  no "#776 case/in operands before a real group | bash still blocks" "got=${got:-<empty>}"
fi

# A genuine, CLOSED case earlier in the command must not lend its state to a later group.
CLOSED_CASE=$(python3 -c 'q=chr(39);s=chr(42);print("case y in z) : ;; esac; ("+q+q+" | "+s+"[!0-9]"+s+") | bash")')
got=$(verdict "$CLOSED_CASE")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 closed case then real group | bash still blocks"
else
  no "#776 closed case then real group | bash still blocks" "got=${got:-<empty>}"
fi

# A digit-negation pipeline in a case BODY is a real pipeline, not a pattern.
BODY_PIPE=$(python3 -c 's=chr(42);print("case x in a) "+s+"[!0-9]"+s+" | bash ;; esac")')
got=$(verdict "$BODY_PIPE")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 digit-negation pipeline in case body still blocks"
else
  no "#776 digit-negation pipeline in case body still blocks" "got=${got:-<empty>}"
fi

# The pattern list of a SECOND arm (reached via `;;`) is still a pattern list.
SECOND_ARM=$(python3 -c 'q=chr(39);s=chr(42);print("case x in a) : ;; "+q+q+"|"+s+"[!0-9]"+s+") : ;; esac")')
got=$(verdict "$SECOND_ARM")
if [[ "$got" == "OK|" ]]; then
  ok "#776 second case arm numeric pattern -> allowed"
else
  no "#776 second case arm numeric pattern -> allowed" "got=${got:-<empty>}"
fi

# MEDIUM: no fixed lookback. Comment runs at and beyond the old 32-pair bound must allow.
# shellcheck disable=SC2016
for _n in 31 32 33 64 200; do
  PAD=$(python3 -c '
import sys
n = int(sys.argv[1]); q = chr(39); s = chr(42)
pads = "".join("# pad %d\n" % k for k in range(n))
print("X=abc; case \"$X\" in\n" + pads + q + q + "|" + s + "[!0-9]" + s + ") : ;; " + s + ") : ;; esac")
' "$_n")
  got=$(verdict "$PAD")
  if [[ "$got" == "OK|" ]]; then
    ok "#776 ${_n} comment lines before empty-alt -> allowed"
  else
    no "#776 ${_n} comment lines before empty-alt -> allowed" "got=${got:-<empty>}"
  fi
done

# --- Litmus iteration-4 findings on #800.

# `case` is a keyword only where a command may START. `case case in case) ...` is valid
# bash; honouring the PATTERN-list `case` reopened the header, and a body operand `in`
# then re-entered pattern state and dropped a real pipeline stage (fail-OPEN).
KEYWORD_SPOOF=$(python3 -c 'q=chr(39);s=chr(42);print("case case in\ncase) printf in; ("+q+q+" | "+s+"[!0-9]"+s+") | bash ;; "+s+") : ;; esac")')
got=$(verdict "$KEYWORD_SPOOF")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 case as a pattern word does not reopen the header"
else
  no "#776 case as a pattern word does not reopen the header" "got=${got:-<empty>}"
fi

# `;&` and `;;&` are valid clause terminators, so the arm after them is a pattern list.
for _term in ";&" ";;&"; do
  FALL=$(python3 -c '
import sys
term = sys.argv[1]; q = chr(39); s = chr(42)
print("case x in a) : " + term + " " + q + q + "|" + s + "[!0-9]" + s + ") : ;; " + s + ") : ;; esac")
' "$_term")
  got=$(verdict "$FALL")
  if [[ "$got" == "OK|" ]]; then
    ok "#776 ${_term} fallthrough then numeric pattern -> allowed"
  else
    no "#776 ${_term} fallthrough then numeric pattern -> allowed" "got=${got:-<empty>}"
  fi
done

# Bounded work: the gate is registered with a 5s timeout and a timeout emits NO decision,
# which the harness reads as ALLOW -- so a payload that never returns is a fail-open. The
# case flags are built ONCE per command for this reason; rebuilding them per emitted
# producer measured ~6.2s on this shape against ~3.7s once cached. The bound below is
# deliberately loose (a slow CI runner must not flake it); it catches a hang or a
# re-introduced quadratic, not a small regression. NOTE: the ~3.5s band itself is
# PRE-EXISTING glob-class expansion -- HEAD reaches the same band on `[!0-9]x|$A;`
# repetitions, which its filter also retains. Tracked separately, not introduced here.
# shellcheck disable=SC2016  # $A must stay literal inside the generated payload
WORST=$(python3 -c 'print("[!0-9]|$A;" * 6000)')
worst_payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$WORST" 2>/dev/null)
got=$(printf '%s' "$worst_payload" | timeout 30 python3 -I "$CLASSIFIER" 2>/dev/null) || got="TIMEOUT_OR_ERROR"
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 worst-case digit-negation pipeline returns a verdict in bounded time"
else
  no "#776 worst-case digit-negation pipeline returns a verdict in bounded time" "got=${got:-<empty>}"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
