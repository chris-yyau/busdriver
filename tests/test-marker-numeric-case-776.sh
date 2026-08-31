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

# --- Independent backstop review of #800: `case` reaching segment lead through `(`.
#
# `_split_with_ops` splits on `(`, so an ARRAY ASSIGNMENT `A=(case x)` leaves the bare word
# `case` at a segment lead while it is only an array element -- not command position. The
# header it wrongly opened was then closed into a pattern list by any later segment merely
# containing `in`, and real executing stages were dropped from the producer text. Two
# independent guards now close it: the array-assignment `(` is not command position, and an
# unterminated header no longer survives a segment that is not the `in`.
for _spoof_case in "case x" "case"; do
  ARR=$(python3 -c '
import sys
subj = sys.argv[1]; q = chr(39); s = chr(42)
print("A=(" + subj + "); echo in; (" + q + q + " | " + s + "[!0-9]" + s + " | bash)")
' "$_spoof_case")
  got=$(verdict "$ARR")
  if [[ "$got" == BLOCK_* ]]; then
    ok "#776 array-assignment [$_spoof_case] + later 'in' still blocks"
  else
    no "#776 array-assignment [$_spoof_case] + later 'in' still blocks" "got=${got:-<empty>}"
  fi
done

# Filler commands between the spoof and the payload must not extend the header either.
ARR_FILL=$(python3 -c 'q=chr(39);s=chr(42);print("A=(case x); : ; : ; echo in; ("+q+q+" | "+s+"[!0-9]"+s+" | bash)")')
got=$(verdict "$ARR_FILL")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 array-assignment spoof with filler commands still blocks"
else
  no "#776 array-assignment spoof with filler commands still blocks" "got=${got:-<empty>}"
fi

# The same shape with `in` INSIDE the array must not flag the following real pipeline.
ARR_IN=$(python3 -c 'q=chr(39);s=chr(42);print("A=(case x in); ("+q+q+" | "+s+"[!0-9]"+s+" | bash)")')
got=$(verdict "$ARR_IN")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 array-assignment carrying 'in' still blocks the next pipeline"
else
  no "#776 array-assignment carrying 'in' still blocks the next pipeline" "got=${got:-<empty>}"
fi

# Control: a case in a GENUINE subshell has no `NAME=` before its `(` and stays allowed.
# shellcheck disable=SC2016  # $x must stay literal inside the generated case
SUBSH=$(python3 -c 'q=chr(39);s=chr(42);print("(case $x in "+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac)")')
got=$(verdict "$SUBSH")
if [[ "$got" == "OK|" ]]; then
  ok "#776 numeric case inside a genuine subshell -> allowed"
else
  no "#776 numeric case inside a genuine subshell -> allowed" "got=${got:-<empty>}"
fi

# Control: a newline between the case subject and `in` is still a valid header.
# shellcheck disable=SC2016  # $x must stay literal inside the generated case
NL_IN=$(python3 -c 'q=chr(39);s=chr(42);print("case $x\nin\n"+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$NL_IN")
if [[ "$got" == "OK|" ]]; then
  ok "#776 newline between case subject and in -> allowed"
else
  no "#776 newline between case subject and in -> allowed" "got=${got:-<empty>}"
fi

# --- Litmus on the array-assignment guard: two valid shapes it must NOT over-block.

# Operator characters join into one run, so a subshell after an empty assignment arrives
# as `;(`. That is command position, not an array assignment.
SUBSH_AFTER_ASSIGN=$(python3 -c 'dq=chr(34);s=chr(42);print("A=;(case x in "+dq+dq+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac)")')
got=$(verdict "$SUBSH_AFTER_ASSIGN")
if [[ "$got" == "OK|" ]]; then
  ok "#776 subshell after an empty assignment (;() -> allowed"
else
  no "#776 subshell after an empty assignment (;() -> allowed" "got=${got:-<empty>}"
fi

# The digit-negation alternative need not be LAST in the pattern list; the closing `)`
# then sits beyond the final candidate stage.
NOT_LAST_ALT=$(python3 -c 'dq=chr(34);s=chr(42);print("case x in "+dq+dq+"|"+s+"[!0-9]"+s+"|bash) : ;; esac")')
got=$(verdict "$NOT_LAST_ALT")
if [[ "$got" == "OK|" ]]; then
  ok "#776 digit-negation as a non-final alternative -> allowed"
else
  no "#776 digit-negation as a non-final alternative -> allowed" "got=${got:-<empty>}"
fi

# Same shape, but a real pipeline into that trailing shell name must still block.
NOT_LAST_PIPE=$(python3 -c 'q=chr(39);s=chr(42);print("("+q+q+" | "+s+"[!0-9]"+s+" | bash) ")')
got=$(verdict "$NOT_LAST_PIPE")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 empty-alt group piping into bash still blocks"
else
  no "#776 empty-alt group piping into bash still blocks" "got=${got:-<empty>}"
fi

# --- Generated coverage over the axes the hand-picked cases kept missing.
#
# Both over-blocks found by review (a subshell reached through `;(`, and a digit-negation
# alternative that is not the LAST one) were combinations no fixed example covered, as was
# a paren-opened item whose FIRST alternative is the digit-negation glob. The matrix walks
# empty-alt spelling x alternative position x opener x arm terminator, keeps only shapes
# `bash -n` accepts, and pins each to its expected verdict. The `block` controls rebuild
# the SAME alternatives as a real pipeline into a shell, so a change that "passes" by
# allowing everything fails here.
#
# `overblock` is a PRE-EXISTING residual, pinned so it cannot silently get worse: when the
# digit-negation glob is the FIRST alternative and no `(` opens the case item, the glob is
# absorbed into the `case x in ...` header SEGMENT rather than standing alone, so there is
# no segment to omit and the producer text keeps the glob. Parent 51ba26e2 blocks all 12 of
# these too — this PR neither introduced nor widened them. Fixing that needs sub-segment
# analysis, which is out of scope here; a `(` opener or any non-first position works today.
GEN_PASS=0; GEN_FAIL=0; GEN_XFAIL=0
# shellcheck disable=SC2016  # the heredoc'd generator is python source, not shell
while IFS=$'\t' read -r want cmd; do
  [[ -z "$cmd" ]] && continue
  bash -n <<<"$cmd" 2>/dev/null || continue          # only assert on valid bash
  got=$(verdict "$cmd")
  case "$want" in
    allow)     [[ "$got" == "OK|"    ]] && { GEN_PASS=$((GEN_PASS+1)); continue; } ;;
    block)     [[ "$got" == BLOCK_*  ]] && { GEN_PASS=$((GEN_PASS+1)); continue; } ;;
    overblock) [[ "$got" == BLOCK_*  ]] && { GEN_XFAIL=$((GEN_XFAIL+1)); continue; } ;;
  esac
  GEN_FAIL=$((GEN_FAIL+1))
  printf '  gen MISMATCH want=%s got=%s :: %s\n' "$want" "${got:-<empty>}" "$cmd"
done < <(python3 -c '
q = chr(39); dq = chr(34); s = chr(42)
neg = s + "[!0-9]" + s
rows = []
for empty in (q + q, dq + dq, q + q + dq + dq):
    for pos in (0, 1, 2):                      # where the digit-negation alt sits
        alts = [empty, "foo", "bash"]
        alts.insert(pos, neg)
        alt = "|".join(alts)
        for opener in ("", "(", ";("):
            for term in (") : ;;", ");;"):
                if opener == "":
                    cmd = "case x in " + alt + term + " " + s + ") : ;; esac"
                elif opener == "(":
                    cmd = "case x in (" + alt + term + " " + s + ") : ;; esac"
                else:
                    cmd = "A=;(case x in " + alt + term + " " + s + ") : ;; esac)"
                # A leading glob with no case-item `(` is absorbed into the header segment.
                want = "overblock" if (pos == 0 and opener != "(") else "allow"
                rows.append((want, cmd))
        rows.append(("block", "(" + alt.replace("|", " | ") + " | bash)"))
for w, c in rows:
    print(w + "\t" + c)
')
if [[ "$GEN_FAIL" -eq 0 && "$GEN_PASS" -gt 0 ]]; then
  ok "#776 generated matrix (${GEN_PASS} asserted, ${GEN_XFAIL} pinned pre-existing over-blocks)"
else
  no "#776 generated matrix" "pass=${GEN_PASS} fail=${GEN_FAIL} xfail=${GEN_XFAIL}"
fi

# --- A pattern list is inert text EXCEPT for substitutions, which RUN their contents.
# `case x in <(...))` really executes the pipeline, so membership in a pattern list is not
# on its own enough to call a stage non-executing. Parent 51ba26e2 returned OK| for all
# three spellings; they block here.
for _sub in "<" "\$" ">"; do
  SUBST=$(python3 -c '
import sys
intro = sys.argv[1]; q = chr(39); s = chr(42)
print("case x in " + intro + "(" + s + "[!0-9]" + s + " | " + q + q + " | bash)) : ;; " + s + ") : ;; esac")
' "$_sub")
  got=$(verdict "$SUBST")
  if [[ "$got" == BLOCK_* ]]; then
    ok "#776 ${_sub}( substitution inside a case pattern still blocks"
  else
    no "#776 ${_sub}( substitution inside a case pattern still blocks" "got=${got:-<empty>}"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
