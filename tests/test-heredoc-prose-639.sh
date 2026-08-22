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
# far the squeeze may reach, because each answer that reaches too far is a MEASURED
# fail-open, and none of them is visible from case A:
#
#   B  the BACKSLASH is left alone   — `_norm_for_scan` rejoins a backslash-newline, so
#                                      deleting backslashes first splits the assembled name
#   C  only a LONE quote may go      — deleting every quote splits a spaced quoted path;
#                                      deleting every WEDGED quote is no better, because a
#                                      wedged PAIR still quotes the whitespace between it
#   D  the opener must be live shell — a `<<'FAKE'` in a COMMENT selects a "body" of real
#                                      syntax to delete a quote out of
#   E  ...and one in a STRING too    — which the comment defuser does not reach
#   F  ONE heredoc per command       — deleting a quote shifts the parity of the WHOLE
#                                      command, so a second body's apostrophe pairs with a
#                                      third across the live shell between them
#   G  the opener must OWN the body  — bash gives the first body to the FIRST operator, so
#                                      `3<<U 4<<'N'` hands it to the unquoted `U`
#   H  the lone quote must be WEDGED — an unwedged one opens a spaced path, and deleting it
#                                      splits the path out of the script operand
#   I  "line" means the LOGICAL line — bash removes backslash-newline before reading
#                                      redirections, so a continuation hides G's second
#                                      heredoc from a physical-line count
#   J  ...extended, not REFUSED       — a blanket refusal on any continuation re-introduced
#                                      the very false positive this change removes, so J is
#                                      a second BUG-side case: one heredoc, opener line
#                                      continues, still allowed
#
# B..I all BLOCK on the pre-fix classifier too. That is the point: they are controls, not
# coverage, and only A and J may change verdict. B and C also assert that the body is
# still read as shell source, so a change that stopped scanning heredocs fails them.
#
# Each of the ten is bitten by a mutation the other nine survive — verified, not assumed.
# The set was trimmed to exactly that: a plain-invocation case and a spaced-quoted-path case
# were dropped once measured to be strict subsets of the survivors, as was a
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

# F. Deleting a quote shifts the parity of the WHOLE command, so a second heredoc's prose
# apostrophe stops being odd-one-out and pairs with a third ACROSS the invocation between
# them, hiding it as quoted data. `bash -n` calls this valid and bash runs the invocation.
# Three is the smallest count that bites (even counts already parse and never get here).
assert_block "cat > /tmp/n1.md <<'E1'
it${Q}s 1
E1
cat > /tmp/n2.md <<'E2'
it${Q}s 2
E2
python3 ${HELPER}
cat > /tmp/n3.md <<'E3'
it${Q}s 3
E3" "F. THREE prose heredocs straddling an invocation -> BLOCK"

# G. Bash gives the first body to the FIRST operator, so the UNQUOTED `<<U` owns this text,
# not the quoted `<<'N'` that the opener pattern matched. Reading it as N's body squeezes a
# quote out of a document that is not N's.
assert_block "bash -c ${Q}sh -c \"\$(cat /dev/fd/3)\"${Q} 3<<U 4<<'N'
python3 ${HELPER}${Q}x
U
plain
N" "G. two heredocs on one line, the quoted one not owning the body -> BLOCK"

# H. The lone quote must also be WEDGED. This one is not — a space precedes it — so deleting
# it would split the spaced path and demote the helper out of the script operand.
assert_block "sh <<'EOF'
python3 \"/tmp/path with space/${HELPER} --seize
EOF" "H. a lone UNWEDGED quote opening a spaced path -> BLOCK"

# I. ...and "line" must mean the LOGICAL line. Bash removes the backslash-newline before it
# reads redirections, so this is G's two-heredocs-one-line wearing a continuation.
# shellcheck disable=SC2016  # the $(...) is literal payload text handed to the classifier
printf -v CONTHD 'bash -c %ssh -c "$(cat /dev/fd/3)"%s 3<<U %s\n 4<<%sN%s\npython3 %s%sx\nU\nplain\nN' \
    "$Q" "$Q" "$BS" "$Q" "$Q" "$HELPER" "$Q"
assert_block "$CONTHD" "I. two heredocs joined by a CONTINUATION -> BLOCK"

# J. ...but only because a SECOND heredoc hides on that logical line. One heredoc whose
# opener line merely continues is the ordinary case A shape and must still be allowed —
# refusing every continuation outright was tried and re-introduced the false positive.
printf -v BENIGN 'cat > /tmp/c.md <<%sEOF%s %s\n  2>/dev/null\nThe library%ss %s builds records.\nEOF' \
    "$Q" "$Q" "$BS" "$Q" "$HELPER"
assert_ok "$BENIGN" "J. ONE heredoc whose opener line continues -> allowed"

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'test-heredoc-prose-639.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
else
    printf 'test-heredoc-prose-639.sh: %d passed, %d FAILED\n' "$PASS" "$FAIL"
fi
[[ $FAIL -eq 0 ]]
