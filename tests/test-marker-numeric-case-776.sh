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
  local payload out
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
    "$1" 2>/dev/null) || { printf 'ERROR'; return; }
  # Status captured SEPARATELY, not appended. `cmd || printf ERROR` leaves whatever the
  # classifier already wrote in place and adds to it, so a partial `BLOCK_…` followed by a
  # crash reads as `BLOCK_…ERROR` -- which every `== BLOCK_*` assertion here accepts. A
  # non-zero exit is not a verdict, and the blocking assertions are the ones that must not
  # be satisfiable by a crash.
  if ! out=$(python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
    printf 'ERROR'
    return
  fi
  printf '%s' "$out"
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
WORST=$(python3 -c 'print("[!0-9]|$A;" * 2000)')
# Bounded by python, not by the GNU `timeout` binary, which a stock macOS does not ship --
# and this branch explicitly targets macOS. Falling back to an unbounded run there would
# let the hang this assertion exists to catch hang the suite instead of failing it.
got=$(python3 - "$CLASSIFIER" "$WORST" <<'PYEOF' 2>/dev/null || echo TIMEOUT_OR_ERROR
import subprocess, sys, json

# Bounded by the PRODUCTION budget: the gate is registered with a 5s timeout and a
# timeout writes NO decision, which the harness reads as ALLOW, so anything looser would
# let a regression that takes 6-20s pass here while failing OPEN in production.
#
# The payload is deliberately sized BELOW the pre-existing pathological band rather than
# at it. 6000 repetitions sit at ~3.5s on the older glob-class expansion path that parent
# 51ba26e2 shares (tracked in issue #802), which is close enough to 5s to flake without
# saying anything about this branch. 2000 measures ~0.15s, so the 5s bound carries ~30x
# headroom and genuinely encodes the production constraint instead of a round number.
PROD_TIMEOUT_S = 5  # the repetition count lives with the payload, in `WORST=` below
try:
    p = subprocess.run([sys.executable, "-I", sys.argv[1]],
                       input=json.dumps({"tool_name": "Bash",
                                         "tool_input": {"command": sys.argv[2]}}),
                       capture_output=True, text=True, timeout=PROD_TIMEOUT_S)
except subprocess.TimeoutExpired:
    print("TIMEOUT_OR_ERROR")
else:
    # A non-zero exit is NOT a verdict, even when stdout already carries a BLOCK-prefixed
    # partial line: the previous shell pipeline turned every non-zero status into
    # TIMEOUT_OR_ERROR and that contract is preserved here.
    if p.returncode != 0:
        print("TIMEOUT_OR_ERROR")
    else:
        print((p.stdout or "").strip() or "TIMEOUT_OR_ERROR")
PYEOF
)
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
# containing `in`, and real executing stages were dropped from the producer text.
#
# What these VERDICT rows actually prove is narrower than it looks, so it is worth being
# exact: since the `in` must now LEAD its segment, `echo in` cannot complete a header at
# all, and these commands would still block even if the array-assignment guard regressed.
# They pin the outcome; the state-level assertion below is what pins the guard itself.
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
# shellcheck disable=SC2312  # a failed generator yields no rows, which the
# `*_PASS > 0` assertion below already reports as a failure
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
# shellcheck disable=SC2312  # a failed generator yields no rows, which the
# `*_PASS > 0` assertion below already reports as a failure
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
# pattern did redundant work; `_case_residue_flags` now settles each list once.
#
# Asserted as WORK, not as wall-clock. A timing ratio was tried and withdrawn: it needed a
# floor under the fast measurement, and that floor turns "the implementation got faster"
# into a failure on quick hardware -- the result then depends on the machine rather than on
# the algorithm. Counting the calls is deterministic, needs no floor, and measures the
# property directly: one settle per alternative list, however many candidates it holds.
WORK_OUT=$(python3 - "$CLASSIFIER" <<'PYEOF'
import importlib.util, io, json, sys

sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "true"}}))
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real

q, s = chr(39), chr(42)
calls = []
_orig = mc._case_pattern_closes_after
mc._case_pattern_closes_after = lambda pairs, i: (calls.append(i), _orig(pairs, i))[1]

# ONE alternative list holding many digit-negation candidates.
n = 200
alts = [q + q] + [s + "[!0-9]" + s] * n + ["bash"]
cmd = "case x in " + "|".join(alts) + ") : ;; " + s + ") : ;; esac"
pairs, _ok = mc._split_with_ops(mc._norm_for_scan(cmd))
flags = mc._case_residue_flags(pairs)

candidates = sum(1 for _op, seg in pairs if mc._is_digit_negation_only_segment(seg))
marked = sum(1 for f in flags if f)
# One settle per LIST. Per-candidate would be ~`candidates` calls; a couple of lists in
# this command is the honest upper bound, so anything at candidate scale is the regression.
ok = len(calls) <= 4 and candidates >= n and marked >= n
print("%s calls=%d candidates=%d marked=%d" %
      ("OK" if ok else "BAD", len(calls), candidates, marked))
PYEOF
)
read -r _w_status _w_calls _w_cands _w_marked <<<"$WORK_OUT"
if [[ "$_w_status" == "OK" ]]; then
  ok "#776 each alternative list is settled once (${_w_calls}, ${_w_cands})"
else
  no "#776 each alternative list is settled once" "$WORK_OUT"
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
# the INERT spellings -- backslash-escaped and single-quoted. Inside DOUBLE quotes a
# backtick still substitutes, so that one is executable and is asserted as such.
# Executable rows must BLOCK and inert rows must be ALLOWED: accepting either verdict for
# the inert ones is what let a raw `"`" in seg` test over-block them unnoticed.
BT_PASS=0; BT_FAIL=0
# shellcheck disable=SC2016  # the generator is python source, not shell
# shellcheck disable=SC2312  # a failed generator yields no rows, which the
# `*_PASS > 0` assertion below already reports as a failure
while IFS=$'\t' read -r want cmd; do
  [[ -z "$cmd" ]] && continue
  bash -n <<<"$cmd" 2>/dev/null || continue
  got=$(verdict "$cmd")
  case "$want" in
    block) if [[ "$got" == BLOCK_* ]]; then BT_PASS=$((BT_PASS + 1)); else
             BT_FAIL=$((BT_FAIL + 1)); printf '  bt MISMATCH want=block got=%s :: %s\n' "$got" "$cmd"; fi ;;
    allow) if [[ "$got" == "OK|" ]]; then BT_PASS=$((BT_PASS + 1)); else
             BT_FAIL=$((BT_FAIL + 1)); printf '  bt MISMATCH want=allow got=%s :: %s\n' "$got" "$cmd"; fi ;;
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
# Inert spellings: the shell runs nothing, so the numeric shape stays ALLOWED.
rows.append(("allow", "case x in " + chr(92) + bt + "|" + q + q + "|" + neg + ") : ;; " + s + ") : ;; esac"))
rows.append(("allow", "case x in " + q + bt + q + "|" + q + q + "|" + neg + ") : ;; " + s + ") : ;; esac"))
for w, c in rows:
    print(w + chr(9) + c)
')
if [[ "$BT_FAIL" -eq 0 && "$BT_PASS" -gt 0 ]]; then
  ok "#776 backtick matrix (${BT_PASS} spellings: executable block, inert allowed)"
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

# --- PINNED over-block: a case SUBJECT carrying a substitution.
#
# `case "$(printf x)" in ''|*[!0-9]*) …` is valid bash and IS blocked. The abandoned scan
# also runs over a copy where `$( … )` has been flattened to separators, and that copy has
# lost the pattern-closing `)`, so the residue rule declines and the glob keeps its text.
# Two fixes were built and measured, and both re-opened a verified fail-open: removing the
# closing-`)` requirement let `(case $(printf x)); in; ('' | *[!0-9]* | bash)` through, and
# accepting a later `esac` instead let a double-quoted backtick pipeline through, because
# the same flattening erases the backticks the substitution guard looks for. In that copy
# the valid case and the spoof are identical text, so both are blocked.
#
# Pinned, not asserted-correct: if a later change makes these ALLOW while every spoof in
# this file still blocks, that is an improvement -- update this block deliberately.
# shellcheck disable=SC2016  # the subjects must stay literal, unexpanded
for _subj in '"$(printf x)"' '`printf x`' '"$(printf "$(echo x)")"'; do
  SUBJ_CMD=$(python3 -c '
import sys
subj = sys.argv[1]; q = chr(39); s = chr(42)
print("case " + subj + " in " + q + q + "|" + s + "[!0-9]" + s + ") : ;; " + s + ") : ;; esac")
' "$_subj")
  got=$(verdict "$SUBJ_CMD")
  if [[ "$got" == BLOCK_* ]]; then
    ok "#776 substitution in the case subject is pinned as a known over-block"
  else
    no "#776 substitution-subject over-block changed (review the residual note)" "got=${got:-<empty>}"
  fi
done

# The spoof the over-block pays for must stay blocked.
SUBJ_SPOOF=$(python3 -c 'q=chr(39);s=chr(42);d=chr(36);print("(case "+d+"(printf x)); in; ("+q+q+" | "+s+"[!0-9]"+s+" | bash)")')
got=$(verdict "$SUBJ_SPOOF")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 flattened-substitution spoof still blocks"
else
  no "#776 flattened-substitution spoof still blocks" "got=${got:-<empty>}"
fi

# --- bash 5.3 alternate command substitution inside a case pattern.
# `$<brace> cmd; }` and `$<brace>| cmd; }` RUN their body while wearing parameter-expansion syntax, so
# a pattern list carrying one is not inert text. The separator after `${` is what tells
# them from `${VAR}` / `${VAR:-x}`, which expand without running anything and must stay
# allowed -- both controls are asserted here so the rule cannot be widened into them.
# The introducers are BUILT, never written literally: bash 3.2 -- still /bin/bash on a
# stock macOS -- fails to parse a file containing `${ `, even inside a quoted heredoc,
# with "unexpected EOF while looking for matching '}'". A test that cannot be parsed
# cannot run, so the whole suite would have been dead on the platform it targets.
_D=$(python3 -c 'print(chr(36))'); _B=$(python3 -c 'print(chr(123))')
for _alt in "${_D}${_B} " "${_D}${_B}| "; do
  ALTCMD=$(python3 -c '
import sys
intro = sys.argv[1]; q = chr(39); s = chr(42)
print("case x in " + intro + "printf x | " + q + q + " | " + s + "[!0-9]" + s + " | bash; }) : ;; " + s + ") : ;; esac")
' "$_alt")
  got=$(verdict "$ALTCMD")
  if [[ "$got" == BLOCK_* ]]; then
    ok "#776 bash 5.3 '${_alt}...}' substitution in a case pattern still blocks"
  else
    no "#776 bash 5.3 '${_alt}...}' substitution in a case pattern still blocks" "got=${got:-<empty>}"
  fi
done

# Controls: ordinary parameter expansion runs nothing and must remain allowed.
# shellcheck disable=SC2016  # the expansions must stay literal
for _var in '"${V}"' '"${V:-x}"'; do
  VARCMD=$(python3 -c '
import sys
subj = sys.argv[1]; q = chr(39); s = chr(42)
print("V=x; case " + subj + " in " + q + q + "|" + s + "[!0-9]" + s + ") : ;; " + s + ") : ;; esac")
' "$_var")
  got=$(verdict "$VARCMD")
  if [[ "$got" == "OK|" ]]; then
    ok "#776 plain parameter expansion ${_var} in the subject -> allowed"
  else
    no "#776 plain parameter expansion ${_var} in the subject -> allowed" "got=${got:-<empty>}"
  fi
done

# --- Generated quote-context coverage for bash 5.3 alternate command substitution.
#
# Whether the body RUNS is decided by QUOTE STATE, not by the characters alone, and the
# combination that first broke it was a literal apostrophe inside double quotes: an
# earlier version stripped single-quoted runs before looking, so a double-quoted run
# holding a literal apostrophe around the introducer had its
# live substitution removed and read as inert. The contexts are therefore generated
# rather than sampled.
#
# The rows are SEGMENT TEXT, not whole commands, so they are deliberately not run through
# `bash -n`: such a fragment is half a pattern and would fail a
# syntax check while still being exactly what the walk receives after `_split_with_ops`.
# The end-to-end spellings are covered separately below and in the backtick matrix. The
# assertion is on `_alt_cmd_subst_active` -- the walk's own decision -- because the
# surrounding verdict can be supplied by other machinery and would hide a wrong answer.
QUOTE_OUT=$(python3 - "$CLASSIFIER" <<'PYEOF'
import importlib.util, io, json, subprocess, sys

sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "true"}}))
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real

q, dq, bs = chr(39), chr(34), chr(92)
bad = []
# Every separator bash accepts after `${`: space, TAB, NEWLINE and `|`. Newline is the
# one most easily left out of a hand-written class, and `${\nprintf x; }` really runs.
_d, _b = chr(36), chr(123)                # built, never literal -- see the note above
for intro in (_d + _b + " ", _d + _b + "\t", _d + _b + "\n", _d + _b + "|"):
    rows = [
        (True,  intro + " printf x; }"),                      # unquoted: runs
        # bash removes an unquoted or double-quoted backslash-newline BEFORE parsing, so
        # the separator can arrive on the next line and the substitution still runs.
        (True,  _d + _b + bs + "\n printf x; }"),
        (True,  dq + _d + _b + bs + "\n printf x; }" + dq),
        (False, q + _d + _b + bs + "\n printf x; }" + q),      # single-quoted: literal
        (True,  dq + intro + " printf x; }" + dq),            # double-quoted: still runs
        (True,  dq + q + intro + " printf x; }" + q + dq),    # literal apostrophe inside "
        (True,  "a" + dq + intro + " printf x; }" + dq),      # after ordinary text
        (False, q + intro + " printf x; }" + q),              # single-quoted: inert
        (False, bs + intro + " printf x; }"),                 # escaped `$`: inert
        # A closed single-quoted run, then the SAME spelling inside double quotes: the
        # second one runs, so the whole text is active. Quoting is positional, not a
        # property of the characters -- this row is why the matrix exists.
        (True,  q + intro + q + dq + intro + q),
        (False, q + intro + q + q + intro + q),               # both runs single-quoted
    ]
    for want, text in rows:
        got = mc._alt_cmd_subst_active(text)
        if got != want:
            bad.append((text, want, got))
# Comment boundaries, judged AS THE SHELL SEES THEM. A `#` opens a comment only at a
# word boundary, and an ESCAPED character before it is an ordinary word character, so
# `\)#` is not a boundary and the substitution behind it runs.
for want, text in (
    (False, "# " + _d + _b + " note"),        # comment at the start
    (False, "; # " + _d + _b + " note"),      # comment after a separator
    (True,  bs + ")#" + _d + _b + " printf x; }"),   # escaped `)`: NOT a boundary
    (True,  "a#" + _d + _b + " printf x; }"),        # mid-word `#`: not a comment
    (True,  ") " + _d + _b + "| printf x; }"),       # real boundary, then a substitution
    # A backslash does NOT continue a comment: the newline still ends it, so the
    # substitution on the FOLLOWING line runs. Joining the lines hid it -- a fail-OPEN.
    (True,  "# note " + bs + "\n" + _d + _b + "| printf x; }"),
    (False, "# note " + bs + " still comment " + _d + _b + " x"),
    # A continuation REMOVED before the `#` must leave the preceding character in place:
    # bash deletes the pair, so the space before it still opens the comment boundary.
    # Rewriting it to a word character hid the boundary, folded the next line in, and the
    # live substitution scanned as comment text -- a fail-OPEN.
    (True,  "case x in " + bs + "\n# note " + bs + "\n" + _d + _b + "| printf x; }"),
    (True,  "in " + bs + "\n" + _d + _b + "| printf x; }"),
    # ANSI-C `$'…'`: a backslash escapes INSIDE it, including the closing quote, so
    # `$'a\'b'` is one word. Treating every quote alike let the escaped one close the run
    # and the real one open a false single-quoted region, hiding a live substitution.
    (True,  _d + q + "a" + bs + q + "b" + q + _d + _b + " printf x; }"),
    (True,  _d + q + "ab" + q + " " + _d + _b + " printf x; }"),
    (False, _d + q + "a b" + q + " " + q + _d + _b + " " + q),
):
    if mc._alt_cmd_subst_active(text) != want:
        bad.append((text, want, not want))
# Controls: ordinary parameter expansion must never look like a substitution.
for text in (_d + _b + "V}", dq + _d + _b + "V:-x}" + dq, _d + _b + "VAR}", _d + _b + "#V}"):
    if mc._alt_cmd_subst_active(text):
        bad.append((text, False, True))
# Generated cross-product of the lexical states that decide this, rather than more fixed
# rows: quote context x comment-before x line-continuation. Every fail-open found in this
# area was a COMBINATION (an apostrophe inside double quotes; a continuation removed
# before a `#`), so the combinations are enumerated instead of sampled. The expectation is
# derived from the rules, not from the implementation: a substitution runs unless it is
# single-quoted, escaped, or inside a comment, and a comment ends at a real newline.
for wrap in ("bare", "dq", "sq"):
    for lead in ("", "; ", "# note\n", "# note " + bs + "\n", "x " + bs + "\n"):
        for intro in (_d + _b + " ", _d + _b + "|"):
            core = intro + "printf x; }"
            if wrap == "dq":
                core = dq + core + dq
            elif wrap == "sq":
                core = q + core + q
            text = lead + core
            # Inert only when single-quoted, or when a comment is still open at the core.
            commented = lead.startswith("#") and not lead.endswith("\n")
            want = (wrap != "sq") and not commented
            got = mc._alt_cmd_subst_active(text)
            if got != want:
                bad.append((text, want, got))
print("CLEAN" if not bad else "BAD %d %r" % (len(bad), bad[:2]))
PYEOF
)
if [[ "$QUOTE_OUT" == "CLEAN" ]]; then
  ok "#776 quote-context matrix: executable vs inert substitution spellings"
else
  no "#776 quote-context matrix" "$QUOTE_OUT"
fi

# End-to-end control for the spellings that are decided entirely by this walk.
SQ_INERT=$(python3 -c 'q=chr(39);s=chr(42);d=chr(36);b=chr(123);print("case x in "+q+d+b+" "+q+"|"+q+q+"|"+s+"[!0-9]"+s+"|bash) : ;; "+s+") : ;; esac")')
got=$(verdict "$SQ_INERT")
if [[ "$got" == "OK|" ]]; then
  ok "#776 single-quoted inert substitution spelling -> allowed"
else
  no "#776 single-quoted inert substitution spelling -> allowed" "got=${got:-<empty>}"
fi

# A `#` at a word boundary opens a COMMENT, which expands nothing, so the substitution
# spelling is inert there. `${#V}` and `a#b` are NOT comments and must stay allowed.
COMMENT_CMD=$(python3 -c 'q=chr(39);s=chr(42);d=chr(36);b=chr(123);print("case x in # "+d+b+" inert comment\n"+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$COMMENT_CMD")
if [[ "$got" == "OK|" ]]; then
  ok "#776 substitution spelling inside a comment is inert -> allowed"
else
  no "#776 substitution spelling inside a comment is inert -> allowed" "got=${got:-<empty>}"
fi

# shellcheck disable=SC2016  # the expansions must stay literal
for _hash in '"${#V}"' 'a#b'; do
  HASHCMD=$(python3 -c '
import sys
subj = sys.argv[1]; q = chr(39); s = chr(42)
print("V=abc; case " + subj + " in " + q + q + "|" + s + "[!0-9]" + s + ") : ;; " + s + ") : ;; esac")
' "$_hash")
  got=$(verdict "$HASHCMD")
  if [[ "$got" == "OK|" ]]; then
    ok "#776 ${_hash} is not a comment -> allowed"
  else
    no "#776 ${_hash} is not a comment -> allowed" "got=${got:-<empty>}"
  fi
done

# --- Word splitting follows the SHELL, not python.
# `str.split()` splits on unicode whitespace; bash splits on space, tab and newline only.
# A non-breaking space is an ordinary word character to the shell, so `case<NBSP>x` is ONE
# command name -- and splitting it produced a `case` lead that opened a pattern list over
# a REAL pipeline and dropped its executing stage.
NBSP_SPOOF=$(python3 -c 'q=chr(39);s=chr(42);nb=chr(160);print("(case"+nb+"x in "+q+q+" | "+s+"[!0-9]"+s+" | bash)")')
got=$(verdict "$NBSP_SPOOF")
if [[ "$got" == BLOCK_* ]]; then
  ok "#776 non-breaking space does not split a command word"
else
  no "#776 non-breaking space does not split a command word" "got=${got:-<empty>}"
fi

# The ordinary spelling, with a real space, is still a case and stays allowed.
SP_CASE=$(python3 -c 'q=chr(39);s=chr(42);print("case x in "+q+q+"|"+s+"[!0-9]"+s+") : ;; "+s+") : ;; esac")')
got=$(verdict "$SP_CASE")
if [[ "$got" == "OK|" ]]; then
  ok "#776 an ordinary space still separates the case keyword"
else
  no "#776 an ordinary space still separates the case keyword" "got=${got:-<empty>}"
fi

# --- Substitution introducers separated from their `(` by a line continuation.
# bash deletes an unquoted `\<newline>` before parsing, so `$`, `<` and `>` still open a
# substitution across one. Asserted at the WALK as well as the verdict: the introducer is
# normalized inside `_opens_substitution` rather than relying on upstream normalization
# having run, and only the walk shows that.
SUBST_OUT=$(python3 - "$CLASSIFIER" <<'PYEOF'
import importlib.util, io, json, sys

sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "true"}}))
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real

q, s, bs = chr(39), chr(42), chr(92)
neg = s + "[!0-9]" + s
bad = []
for intro in ("$", "<", ">"):
    # the helper itself, with the continuation still present
    pairs = [("", "case x in " + intro + bs + "\n"), ("(", q + q + " ")]
    if not mc._opens_substitution(pairs, 1):
        bad.append(("helper", intro))
    # and end to end: no digit-negation segment may be marked as case residue
    cmd = "case x in " + intro + bs + "\n(" + q + q + " | " + neg + " | bash)) : ;; " + s + ") : ;; esac"
    pr, _ok = mc._split_with_ops(mc._norm_for_scan(cmd))
    res = mc._case_residue_flags(pr)
    if any(res[i] for i, (_o, sg) in enumerate(pr) if mc._is_digit_negation_only_segment(sg)):
        bad.append(("marked", intro))
print("CLEAN" if not bad else "BAD %r" % (bad,))
PYEOF
)
if [[ "$SUBST_OUT" == "CLEAN" ]]; then
  ok "#776 substitution introducer survives a line continuation before its ("
else
  no "#776 substitution introducer survives a line continuation before its (" "$SUBST_OUT"
fi

# --- The array-assignment guard, asserted directly.
# The verdict rows above cannot isolate it (see the note there), so it is checked at the
# walk: an ATTACHED `(` after `NAME=` is an array assignment and not command position,
# while a `(` reached through a separator is a genuine subshell and is.
ARRGUARD=$(python3 - "$CLASSIFIER" <<'PYEOF'
import importlib.util, io, json, sys

sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "tool_input": {"command": "true"}}))
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real

bad = []
# `A=(case x)` -- array element, NOT command position.
if mc._case_lead_is_command_position([("", "A="), ("(", "case x")], 1):
    bad.append("array assignment treated as command position")
# `A=;(case x …)` -- the `(` is a real subshell, so it IS command position.
if not mc._case_lead_is_command_position([("", "A="), (";(", "case x")], 1):
    bad.append("subshell after an empty assignment rejected")
# A bare subshell with nothing before it is command position too.
if not mc._case_lead_is_command_position([("", ""), ("(", "case x")], 1):
    bad.append("plain subshell rejected")
print("CLEAN" if not bad else "BAD %r" % (bad,))
PYEOF
)
if [[ "$ARRGUARD" == "CLEAN" ]]; then
  ok "#776 array-assignment ( is not command position (guard asserted directly)"
else
  no "#776 array-assignment ( is not command position" "$ARRGUARD"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
