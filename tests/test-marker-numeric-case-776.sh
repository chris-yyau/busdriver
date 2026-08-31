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

# --- Generated arm-layout coverage: terminator x whitespace x optional item opener.
#
# `case x in a);;''|*[!0-9]*) …` emits `);;` as ONE operator run, and with the optional
# case-item opener it becomes `);;(`. Both were over-blocked, one spelling at a time, so
# the layout axes are generated rather than enumerated: three terminators, whitespace
# present or absent on each side, and the item `(` present or absent. Each `allow` row is
# a valid empty first arm followed by the numeric-validation pattern.
GEN2_PASS=0; GEN2_FAIL=0
# shellcheck disable=SC2016  # the generator is python source, not shell
while IFS=$'\t' read -r want cmd; do
  [[ -z "$cmd" ]] && continue
  bash -n <<<"$cmd" 2>/dev/null || continue
  got=$(verdict "$cmd")
  if [[ ( "$want" == "allow" && "$got" == "OK|" ) || ( "$want" == "block" && "$got" == BLOCK_* ) ]]; then
    GEN2_PASS=$((GEN2_PASS + 1))
  else
    GEN2_FAIL=$((GEN2_FAIL + 1))
    printf '  arm MISMATCH want=%s got=%s :: %s\n' "$want" "${got:-<empty>}" "$cmd"
  fi
done < <(python3 -c '
q = chr(39); s = chr(42)
neg = s + "[!0-9]" + s
rows = []
for term in (";;", ";&", ";;&"):
    for lead in ("", " "):                 # whitespace before the terminator
        for gap in ("", " "):              # whitespace after it
            for opener in ("", "("):       # optional case-item opener
                arm = "a)" + lead + term + gap + opener
                rows.append(("allow",
                    "case x in " + arm + q + q + "|" + neg + ") : ;; " + s + ") : ;; esac"))
# Controls: the same terminator runs must not license a REAL pipeline into a shell.
for term in (";;", ";&", ";;&"):
    rows.append(("block", "case x in a)" + term + q + q + "|" + neg + ") : ;; esac; " + neg + " | bash"))
    rows.append(("block", "case x in a) " + neg + " | bash " + term + " esac"))
for w, c in rows:
    print(w + "\t" + c)
')
if [[ "$GEN2_FAIL" -eq 0 && "$GEN2_PASS" -gt 0 ]]; then
  ok "#776 arm-layout matrix (${GEN2_PASS} valid shapes: terminator x whitespace x item opener)"
else
  no "#776 arm-layout matrix" "pass=${GEN2_PASS} fail=${GEN2_FAIL}"
fi

# --- Bounded work INSIDE a real case pattern list (litmus PR-mode finding on #800).
#
# Every alternative in a `|`-list shares one span, one empty-alt answer and one closing
# `)`. Deciding that per candidate re-walked the whole list each time, so a long valid
# pattern did redundant work; `_case_residue_flags` now settles each list once. The
# earlier bounded-work probe missed it because its repeated alternatives sit OUTSIDE a
# real case-pattern state, so none of them was ever a candidate.
#
# This is an EMPIRICAL regression detector, not a complexity proof, and the distinction
# matters: at the sizes the classifier's own budget allows, the prior implementation
# peaked below 1s, so no wall-clock ceiling short of the gate's 5s timeout could separate
# the two. What does separate them is the SHAPE. Measured N=500 -> N=4000 (8x input),
# best-of-3, same machine: 13.16 on the implementation this replaced, 2.66 after. The
# limit is set at 6.0, between the two, and was RUN against that prior commit to confirm
# it fails there -- a bound the regression slips under is worse than no bound.
# Both measurements ride the same interpreter start-up and the same budget truncation, so
# a slower runner moves them together and the ratio holds.
RATIO_OUT=$(python3 - "$CLASSIFIER" <<'PYEOF'
import json, subprocess, sys, time

classifier = sys.argv[1]
q, s = chr(39), chr(42)
FLOOR = 0.05
LIMIT = 6.0


def build(n):
    alts = [q + q] + [s + "[!0-9]" + s] * n + ["bash"]
    return "case x in " + "|".join(alts) + ") : ;; " + s + ") : ;; esac"


def run(cmd):
    """Best-of-3 wall time plus the verdict; None if the classifier fails to answer."""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    best = None
    for _ in range(3):
        t0 = time.monotonic()
        try:
            # A hang is the failure mode this test exists to catch, so it must become a
            # failed assertion here rather than a stalled job an outer CI timeout kills.
            p = subprocess.run([sys.executable, "-I", classifier], input=payload,
                               capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return (None, "TIMEOUT")
        dt = time.monotonic() - t0
        if best is None or dt < best[0]:
            best = (dt, p.stdout.strip())
    return best


small_t, small_v = run(build(500))
large_t, large_v = run(build(4000))
if small_t is None or large_t is None:
    print("BAD 0 0 0 %s %s" % (small_v, large_v))
    raise SystemExit(0)
# The floor only guards division. If the small case ever lands at or under it the ratio
# stops meaning anything -- report inconclusive rather than let a shrunken denominator
# hide real growth.
if small_t <= FLOOR:
    print("BAD 0 %.3f %.3f TOO_FAST_TO_COMPARE %s" % (small_t, large_t, large_v))
    raise SystemExit(0)
ratio = large_t / small_t
ok = ratio <= LIMIT and small_v and large_v
print("%s %.2f %.3f %.3f %s %s" % ("OK" if ok else "BAD", ratio, small_t, large_t,
                                   small_v or "<none>", large_v or "<none>"))
PYEOF
)
read -r _r_status _r_ratio _r_small _r_large _r_sv _r_lv <<<"$RATIO_OUT"
if [[ "$_r_status" == "OK" ]]; then
  ok "#776 long in-pattern list: 8x input -> ${_r_ratio}x time (limit 6x; was 13.16x)"
else
  no "#776 long in-pattern list scaling" "ratio=${_r_ratio} small=${_r_small}s large=${_r_large}s verdicts=${_r_sv}/${_r_lv}"
fi

# The same list length as a REAL pipeline must still block (not merely be fast).
LONG_PIPE=$(python3 -c '
q = chr(39); s = chr(42)
print("(" + q + q + " | " + " | ".join([s + "[!0-9]" + s] * 200) + " | bash)")
')
got=$(verdict "$LONG_PIPE")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 long real pipeline of digit-negation stages still blocks"
else
  no "#776 long real pipeline of digit-negation stages still blocks" "got=${got:-<empty>}"
fi

# --- Generated backtick coverage: executable vs inert spellings.
#
# Backticks are the POSIX command substitution and RUN their contents, but the tokenizer
# does not split on them, so there is no `(` for the substitution check to see. Two fixed
# examples do not separate the executable spellings from the ones the shell treats as
# ordinary characters, so the forms are generated: bare, nested, operator-adjacent, and
# the three INERT spellings -- backslash-escaped, single-quoted, and inside double quotes
# (where a backtick still substitutes, so that one is executable too and is asserted as
# such). Executable rows must BLOCK. The inert rows are asserted only to be VALID bash and
# to return some verdict, because whether the numeric shape is still allowed there depends
# on the surrounding pattern, not on the backtick.
BT_PASS=0; BT_FAIL=0
# shellcheck disable=SC2016  # the generator is python source, not shell
while IFS=$'\t' read -r want cmd; do
  [[ -z "$cmd" ]] && continue
  bash -n <<<"$cmd" 2>/dev/null || continue
  got=$(verdict "$cmd")
  case "$want" in
    block) if [[ "$got" == BLOCK_* ]]; then BT_PASS=$((BT_PASS + 1)); else
             BT_FAIL=$((BT_FAIL + 1)); printf '  bt MISMATCH want=block got=%s :: %s\n' "$got" "$cmd"; fi ;;
    any)   if [[ "$got" == "OK|" || "$got" == BLOCK_* ]]; then BT_PASS=$((BT_PASS + 1)); else
             BT_FAIL=$((BT_FAIL + 1)); printf '  bt NO-VERDICT :: %s\n' "$cmd"; fi ;;
  esac
done < <(python3 -c '
q = chr(39); dq = chr(34); s = chr(42); bt = chr(96)
neg = s + "[!0-9]" + s
inner = q + q + " | " + neg + " | bash"
rows = []
# Executable: the substitution really runs the pipeline.
rows.append(("block", "case x in " + bt + inner + bt + ") : ;; " + s + ") : ;; esac"))
rows.append(("block", "case x in " + bt + ":; " + inner + bt + ") : ;; " + s + ") : ;; esac"))
rows.append(("block", "case x in " + q + q + "|" + bt + neg + bt + ") : ;; " + s + ") : ;; esac"))
rows.append(("block", "case x in a) : ;; " + bt + inner + bt + ") : ;; " + s + ") : ;; esac"))
# Inside DOUBLE quotes a backtick still substitutes -- executable, not inert.
rows.append(("block", "case x in " + dq + bt + inner + bt + dq + ") : ;; " + s + ") : ;; esac"))
# Inert spellings: the shell passes the backtick through as an ordinary character.
rows.append(("any", "case x in " + chr(92) + bt + q + q + "|" + neg + ") : ;; " + s + ") : ;; esac"))
rows.append(("any", "case x in " + q + bt + q + "|" + neg + ") : ;; " + s + ") : ;; esac"))
for w, c in rows:
    print(w + chr(9) + c)
')
if [[ "$BT_FAIL" -eq 0 && "$BT_PASS" -gt 0 ]]; then
  ok "#776 backtick matrix (${BT_PASS} spellings: executable block, inert still decide)"
else
  no "#776 backtick matrix" "pass=${BT_PASS} fail=${BT_FAIL}"
fi

# --- State-level assertion for the substitution guard.
#
# A verdict-level test cannot see this: every backtick spelling already BLOCKS via the
# whole-command backtick scan, on the parent commit too, so the matrix above passes even
# when the walk still marks an executing glob as case residue. That standing dependency on
# a different check is the thing being removed, so the assertion reads the walk directly:
# no digit-negation segment inside a backtick substitution may come back as residue.
# Verified to FAIL on the parent blob, where segment 2 is marked.
STATE_OUT=$(python3 - "$CLASSIFIER" <<'PYEOF'
import importlib.util, io, json, sys

sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "true"}}))
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
# The classifier prints its verdict for the stub command at import time; swallow it so
# this probe's stdout carries only the assertion result.
_real_stdout, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real_stdout

q, s, bt = chr(39), chr(42), chr(96)
neg = s + "[!0-9]" + s
cases = [
    "case x in " + bt + ":; " + q + q + " | " + neg + " | bash" + bt + ") : ;; " + s + ") : ;; esac",
    "case x in " + bt + q + q + " | " + neg + bt + ") : ;; " + s + ") : ;; esac",
    "case x in " + q + q + "|" + bt + neg + bt + ") : ;; " + s + ") : ;; esac",
]
bad = []
for c in cases:
    pairs, _ok = mc._split_with_ops(mc._norm_for_scan(c))
    residue = mc._case_residue_flags(pairs)
    for i, (_op, seg) in enumerate(pairs):
        if mc._is_digit_negation_only_segment(seg) and residue[i]:
            bad.append((c, i))
print("CLEAN" if not bad else "MARKED %d" % len(bad))
PYEOF
)
if [[ "$STATE_OUT" == "CLEAN" ]]; then
  ok "#776 no executing backtick glob is marked as case residue (walk state, not verdict)"
else
  no "#776 no executing backtick glob is marked as case residue" "$STATE_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
