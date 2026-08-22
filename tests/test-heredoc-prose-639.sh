#!/usr/bin/env bash
# Regression tests for #639 — the residual half of #573. A helper name written as PROSE
# inside a QUOTED heredoc blocked whenever the body also carried an apostrophe:
#
#     cat > /tmp/c.md <<'EOF'
#     The library's <helper> builds its records from fixed fields.
#     EOF
#     -> BLOCKED: Cannot call <helper> directly.
#
# The apostrophe made `_split_with_ops` fail — the segmenter models a heredoc body as shell
# source — so `_helper_invoked` abandoned the structured walk and handed the whole command
# to the structureless probe, which cannot tell a name in prose from a name in command
# position. The fix deletes a LONE wedged quote from a quoted heredoc body and retries the
# split once, on the failed-parse path only.
#
# ONE mechanism, so ONE bug-side case: A. Delimiter spellings, sinks and residuals are not
# separate mechanisms and are left to the existing suites. What is NOT left to them is how
# far the squeeze may reach: every answer that reached further was a MEASURED fail-open,
# found by review, reproduced against HEAD, and none of them is visible from case A.
#
#   B  the BACKSLASH is left alone   — `_norm_for_scan` rejoins a backslash-newline, so
#                                      deleting backslashes first splits the assembled name
#   C  only a LONE quote may go      — a wedged PAIR still quotes the whitespace between it,
#                                      so an executed `sh -c` payload comes apart
#   D  the opener must be live shell — a `<<'FAKE'` in a COMMENT selects a "body" of real
#                                      syntax to delete a quote out of
#   E  ...and one in a STRING too    — which the comment defuser does not reach
#   F  the lone quote must be WEDGED — an unwedged one opens a spaced path, and deleting it
#                                      splits the path out of the script operand
#   G  a benign CONTINUATION is fine — refusing every continuation was tried and re-blocked
#                                      ordinary prose, so G is a BUG-side case
#   H  ONE heredoc per command       — deleting a quote shifts the parity of the WHOLE
#                                      command, so other bodies' apostrophes pair across the
#                                      live shell between them. Counted as OPERATORS, not as
#                                      `_HEREDOC_QUOTED` matches: `<<'E'2` is assembled from
#                                      two quoting runs and that pattern refuses it, so
#                                      counting matches let two more heredocs hide
#   I  the body starts after the     — a continuation carrying BALANCED quotes would
#      LOGICAL line                    otherwise pull them into the body and lift H's count
#                                      above one, refusing an ordinary command
#   J  ...and only an ODD backslash  — with `\\` the first escapes the second and the
#      run continues                   newline still ends the line
#   K  H is counted OUTSIDE the body — inside it a `<<` is prose, and counting it there
#                                      refused every body that merely writes one: this
#                                      branch re-breaking its own bug
#   L  ...and so is the OPENER count — a body documenting an opener produced a second match
#
# B..F and H all BLOCK on the pre-fix classifier too. That is the point: they are controls,
# not coverage, and only A, G, I, J and K may change verdict. B and C also assert that the
# body is still read as shell source, so a change that stopped scanning heredocs fails them.
#
# Each is bitten by a mutation the others survive — verified, not assumed. The set was
# trimmed to exactly that: a plain-invocation case, a spaced-quoted-path case, a
# two-heredocs-on-one-line case, a continuation-joined case and a three-simple-heredocs case
# were all dropped once measured to be strict subsets of the survivors, as was a
# delete-vs-escape case the narrowed squeeze made unbiteable.
#
# C is also why the guard COUNTS quotes instead of judging them: `library's prose` plus that
# `sh -c` payload is the same shape as three ordinary prose apostrophes — all wedged, all
# with whitespace between them. Telling them apart needs to know what the consumer executes,
# which is exactly what the parked #639 design proved undecidable from text. The measured
# consequence is that only a body with ONE quote is recovered; N=3, 5, ... still over-block,
# which is fail-CLOSED and is not the reported shape.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
# Assembled, never spelled: this suite's own grep and editor traffic would otherwise trip
# the guard it tests — which is how #639 was hit again while it was being fixed.
HELPER="audit_""append.py"
Q=\'
BS=\\

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision — same reason
# test-marker-glob-specificity.sh reads it here: going through the gate would let an
# unrelated pending-review state decide the outcome instead of the evidence under test.
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a name in a quoted heredoc body is data, not a call"
    fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — the helper guard regressed to allow"
    fi
}

# A. THE BUG, verbatim from the issue. The apostrophe in "library's" is the whole defect:
# remove it and this command already read OK| before the fix.
assert_ok "cat > /tmp/c.md <<'EOF'
The library${Q}s ${HELPER} builds its records from fixed fields.
EOF" "A. prose naming a helper in an apostrophe body -> allowed"

# B. Never the backslash. Built with printf so the continuation is a real backslash-newline
# rather than an escape this file's own quoting could swallow.
printf -v CONT 'sh <<%sEOF%s\nit%ss time\npython3 audit_%s\nappend.py\nEOF' \
    "$Q" "$Q" "$Q" "$BS"
assert_block "$CONT" "B. a CONTINUATION-split invocation in an apostrophe body -> BLOCK"

# C. A wedged PAIR quotes the whitespace between it, so this `sh -c` operand is ONE word to
# bash and an executed payload. Squeezing it apart demotes the helper to an argument.
assert_block "sh <<'EOF'
library${Q}s prose
sh -c X${Q}x=1 python3 ${HELPER} Z${Q}Y
EOF" "C. a wedged PAIR quoting an executed payload -> BLOCK"

# D. The opener must be live shell. A `<<'FAKE'` written in a COMMENT selects a "body" made
# of real syntax, and the squeeze would delete a quote out of it.
assert_block "echo start # <<'FAKE'
python3 ${HELPER}${Q}x
FAKE" "D. a FALSE opener inside a comment -> BLOCK"

# E. ...and the same written inside a STRING, which the comment defuser does not touch.
assert_block "echo ${Q}start <<\"FAKE\"
python3 ${HELPER}${Q}x
FAKE
end${Q}" "E. a FALSE opener inside a quoted string -> BLOCK"

# F. The lone quote must also be WEDGED. This one is not — a space precedes it — so deleting
# it would split the spaced path and demote the helper out of the script operand.
assert_block "sh <<'EOF'
python3 \"/tmp/path with space/${HELPER} --seize
EOF" "F. a lone UNWEDGED quote opening a spaced path -> BLOCK"

# G. ...but only when a SECOND heredoc actually hides on that line. One heredoc whose
# opener line merely continues is the ordinary case-A shape and must still be allowed —
# refusing every continuation outright was tried and re-introduced the false positive.
printf -v BENIGN 'cat > /tmp/c.md <<%sEOF%s %s\n  2>/dev/null\nThe library%ss %s builds records.\nEOF' \
    "$Q" "$Q" "$BS" "$Q" "$HELPER"
assert_ok "$BENIGN" "G. ONE heredoc whose opener line continues -> allowed"

# H. F's parity bypass, hidden from a count that only sees delimiters this file can read:
# `<<'E'2` is assembled from two quoting runs, which the opener pattern deliberately refuses
# to match. Counting heredoc OPERATORS instead is what closes it.
assert_block "cat > /tmp/n1.md <<'E1'
it${Q}s 1
E1
cat > /tmp/n2.md <<${Q}E${Q}2
it${Q}s 2
E2
python3 ${HELPER}
cat > /tmp/n3.md <<${Q}E${Q}3
it${Q}s 3
E3" "H. ASSEMBLED quoted delimiters beside a simple one -> BLOCK"

# I. The body starts after the opener's LOGICAL line, not its first newline. A continuation
# carrying BALANCED quotes would otherwise pull them into the body, lifting the quote count
# above one and refusing to recover an ordinary command. This is the case that proved the
# logical-line walk is load-bearing after it had been deleted as unfireable.
printf -v QCONT 'cat <<%sEOF%s %s\n  > %snotes file.md%s\nThe library%ss %s builds records.\nEOF' \
    "$Q" "$Q" "$BS" '"' '"' "$Q" "$HELPER"
assert_ok "$QCONT" "I. a continuation carrying BALANCED quotes -> allowed"

# J. ...and only an ODD backslash run continues. With `\\` the first escapes the second and
# the newline still ends the opener line, so treating it as a continuation skips the body's
# first line and falsely blocks.
printf -v DBS 'cat > /tmp/c.md <<%sEOF%s %s%s\nThe library%ss %s builds records.\nEOF' \
    "$Q" "$Q" "$BS" "$BS" "$Q" "$HELPER"
assert_ok "$DBS" "J. a DOUBLE backslash ending the opener line -> allowed"

# K. Inside the body a `<<` is PROSE, not an operator. Counting operators over the whole
# command refused every body that merely writes one — this branch re-breaking its own bug.
assert_ok "cat > /tmp/c.md <<'EOF'
The library${Q}s ${HELPER} documents x << 1.
EOF" "K. a body whose prose contains << -> allowed"

# L. ...and the OPENER count is outside the body for the same reason K's operator count is:
# a body documenting a heredoc opener produced a second `_HEREDOC_QUOTED` match and refused
# the recovery. `ms[0]` is still the real opener — a match inside the body can only follow it.
printf -v DOCHD 'cat > /tmp/c.md <<%sEOF%s\nThe library%ss %s documents <<%sEND here.\nEOF' \
    "$Q" "$Q" "$Q" "$HELPER" "$BS"
assert_ok "$DOCHD" "L. a body documenting a heredoc opener -> allowed"

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'test-heredoc-prose-639.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
else
    printf 'test-heredoc-prose-639.sh: %d passed, %d FAILED\n' "$PASS" "$FAIL"
fi
[[ $FAIL -eq 0 ]]
