#!/usr/bin/env bash
# Fail-open regressions for the mutating-helper guard (GHSA-mpjr-v52g-cj7x). Each BLOCK
# fixture is a command bash really runs the helper from, while 3.0.9 classified it OK:
#   - the `time` keyword, or the `time` program, in front of the helper -- the command
#     word resolved to `time` and nothing behind it was read;
#   - a `trap` handler -- the shell runs the handler string later, and the guard read it
#     as an operand;
#   - a shell -c payload built at run time (`"$(echo ...)"`, `"$X"`) -- the payload text
#     was read as a top-level command, which only PRINTS the helper command.
#
# Every BLOCK row is first EXECUTED under bash against a stub helper in a scratch tree,
# and must really run it -- a fixture that does not execute proves nothing about the
# guard. Every OK row must classify OK and must NOT run the stub, so tightening cannot
# pass by refusing reads. The helper name is assembled from fragments because the live
# hook refuses a Bash call that spells it.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
TO4=(perl -e 'alarm shift; exec @ARGV or exit 127' 4)
command -v timeout >/dev/null 2>&1 && { TO=(timeout 60); TO4=(timeout 4); }
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() { # <command> -> the verdict line, or ERROR
    local payload out
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    if out=$(${TO[@]+"${TO[@]}"} python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf 'ERROR'
    fi
}

LIBDIR="hooks/gate-scripts/lib"
NAME="lease""_slot.py"
H="$LIBDIR/$NAME"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$LIBDIR"
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"
chmod +x "$SCRATCH/$H"

runs_helper() { # <command> -> 0 when bash, run in the scratch tree, executes the stub
    rm -f "$SCRATCH/$H.ran"
    (cd "$SCRATCH" && env -u X ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$H.ran" ]]
}

assert_block() { # <command> <label>
    local got
    if ! runs_helper "$1"; then
        no "$2" "fixture does not execute the helper under bash -- it proves nothing"
        return
    fi
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then
        no "$2" "got=$got — the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a real invocation was allowed"
    fi
}

assert_ok() { # <command> <label>
    local got
    if runs_helper "$1"; then
        no "$2" "control executes the helper -- it is not a read"
        return
    fi
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a read was refused"; fi
}

assert_overblock() { # <command> <label> -- a pinned, accepted over-block
    local got
    if runs_helper "$1"; then
        no "$2" "pinned over-block executes the helper -- it is a real invocation"
        return
    fi
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_MARKER_SCRIPT* ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — the pinned over-block changed"; fi
}

echo "=== the time keyword and the time program ==="
assert_block "time python3 $H" "time keyword"
assert_block "time -p python3 $H" "time -p"
assert_block "time time python3 $H" "time twice"
assert_block "{ time python3 $H; }" "time inside a group"
assert_block "x=1; time python3 $H" "time after another command"
assert_block "time nice python3 $H" "time in front of a wrapper"
assert_block "time ./$H" "time in front of the executable helper"
if [[ -x /usr/bin/time ]]; then
    assert_block "/usr/bin/time python3 $H" "the time program"
    assert_block "/usr/bin/time -p python3 $H" "the time program with -p"
    assert_block "/usr/bin/time -o /dev/null python3 $H" "the time program with -o FILE"
    assert_ok "/usr/bin/time -p true" "the time program running something else"
fi
if /usr/bin/time --version >/dev/null 2>&1; then  # GNU time: long options
    assert_block "/usr/bin/time --output /dev/null python3 $H" "GNU time with --output FILE"
    assert_block "/usr/bin/time --output=/dev/null python3 $H" "GNU time with --output=FILE"
    assert_block "/usr/bin/time --verbose python3 $H" "GNU time with a long flag"
fi
assert_ok "time true" "time running something else"
assert_ok "time python3 -c 'print(1)'" "time running a read-only interpreter"
assert_ok "time cat $H" "time in front of a read of the helper"
G="$LIBDIR/${NAME%t.py}[t].py"
# Pinned: the timed command now reads exactly as the untimed one, and 3.0.9 already
# blocks `python3 "<stem>[t].py"` (its bracket reading). 3.0.9 allowed only the timed form,
# because `time` hid the whole command -- the hole this file closes.
assert_overblock "time python3 \"$G\"" "time before a quoted literal that looks like a glob"
assert_block "time python3 $G" "time before an unquoted glob onto the helper"
assert_block "time nice time python3 $H" "time behind a wrapper behind time"
if /usr/bin/time --version >/dev/null 2>&1; then  # GNU time: getopt clusters and prefixes
    assert_block "/usr/bin/time -vo /dev/null python3 $H" "GNU time with -vo FILE"
    assert_block "/usr/bin/time -o/dev/null python3 $H" "GNU time with -oFILE"
    assert_block "/usr/bin/time --out /dev/null python3 $H" "GNU time with an abbreviated --output FILE"
fi
# The finding's shape: a re-read per `time` cost ~10s, and a hook killed at its 5s timeout
# is an ALLOW. Held to 4s.
LONG="$(printf 'time %.0s' {1..60})true $(printf 'x%.0s' {1..60000}); python3 $H"
got="$(TO=("${TO4[@]}"); verdict "$LONG")"
if [[ "$got" == BLOCK_MARKER_SCRIPT* ]]; then ok "60 time prefixes before a 60KB argument, within 4s"
else no "60 time prefixes before a 60KB argument, within 4s" "got=${got:-<empty or timed out>}"; fi

echo "=== trap handlers ==="
assert_block "trap 'python3 $H' EXIT" "a literal helper handler"
assert_block "trap -- 'python3 $H' EXIT" "a literal helper handler after --"
assert_block "cd $LIBDIR; trap 'true; python3 [l]????_[s]???.??' EXIT" "a bracket glob handler"
assert_block "trap 'true; python3 */?*/???/?????_????.??' EXIT" "a ?-and-* glob handler"
assert_block "cd $LIBDIR; trap 'python3 *' EXIT" "a bare * handler"
assert_ok "trap - EXIT" "resetting a trap"
assert_ok "trap INT" "a lone operand resets that signal"
assert_ok "trap '' PIPE" "ignoring a signal"
assert_ok "trap 'rm -f /tmp/r9-none' EXIT" "an unrelated handler"
assert_ok "trap 'cat $H >/dev/null' EXIT" "a handler that reads the helper"
assert_ok "echo trap" "the word trap as an argument"
assert_ok "grep trap $H /dev/null" "grep for the word trap in the helper"
assert_ok "echo trap $H x" "the word trap before a helper path and another word"
assert_ok "command -v trap $H python3" "command -v looks trap up"
assert_ok "command </dev/null -v trap $H python3" "command -v behind a redirect"
assert_ok "command 2>/dev/null -v trap $H python3" "command -v behind a numbered redirect"
assert_ok "sig=INT; trap -p \"\$sig\" EXIT; cat $H" "trap -p only prints handlers"
assert_ok "trap 'rm -f \"\$F\"' EXIT; cat $H" "a handler with a variable beside a read of the helper"
assert_block "command trap 'python3 $H' EXIT" "trap behind command"
assert_block "command trap >/dev/null 'python3 $H' EXIT" "trap behind command with a redirect before the handler"
assert_block "builtin trap 2>/dev/null 'python3 $H' EXIT" "trap behind builtin with a numbered redirect"
assert_block "command trap > /dev/null 'python3 $H' EXIT" "trap behind command with a split redirect"
assert_block "trap -- >/dev/null 'python3 $H' EXIT" "a redirect after --"
assert_block "command trap '>/dev/null python3 $H' EXIT" "a quoted handler that starts with a redirect"
assert_ok "command trap >/dev/null 'rm -f /tmp/r9-none' EXIT; cat $H" "a redirect before an unrelated handler, beside a read"
assert_ok "command trap > /dev/null - EXIT; cat $H" "a split redirect before a reset, beside a read"
assert_block "if true; then trap 'python3 $H' EXIT; fi" "trap inside an if"
assert_block "f() { trap 'python3 $H' EXIT; }; f" "trap inside a function body"

echo "=== a shell -c payload built at run time ==="
assert_block "bash -c \"\$(echo 'python3 $H')\"" "bash -c of a substitution that prints the helper command"
assert_block "sh -c \"\$(echo 'python3 $H')\"" "sh -c of the same"
assert_block "bash -c \"\`echo 'python3 $H'\`\"" "bash -c of a backtick substitution"
assert_block "X='python3 $H'; bash -c \"\$X\"" "bash -c of a variable holding the helper command"
assert_ok "bash -c \"\$(echo true)\"" "bash -c of an unrelated substitution"
assert_ok "X=true; bash -c \"\$X\"" "bash -c of an unrelated variable"
assert_ok "bash -c 'cat $H'" "bash -c of a read of the helper"
assert_ok "echo \"\$(echo 'python3 $H')\"" "printing the helper command"
assert_ok "bash -c 'cat $H; echo \$HOME'" "a fixed payload with a variable that reads the helper"
assert_ok "bash -c \"grep -E 'slot.py\$|audit' $H\"" "a regex anchor is not an expansion"
assert_ok "bash -c \"grep -E 'slot.py\$' $H\"" "a dollar before a quote inside double quotes is literal"
if script -q -c true /dev/null >/dev/null 2>&1; then  # util-linux script
    assert_ok "script -q --command='echo \$HOME' /dev/null; cat $H" "a fixed attached --command= payload beside a read"
fi
assert_ok "bash -c \"grep -E x\$é $H\"" "a non-ASCII letter after a dollar is not a name"
assert_block "X='python3 $H'; bash -c \"\$X\" '\$X'" "the same text quoted inert and live"
if env -S true >/dev/null 2>&1; then  # GNU env -S
    assert_block "X='python3 $H'; env -S\"\$X\" '\$X'" "an env -S payload cut from a live word, beside the same text inert"
fi
# Accepted over-block, the same one eval already has: once a shell runs a payload the
# text does not fix, any helper the command names is read as possibly run.
assert_overblock "X=true; bash -c \"\$X\"; cat $H" "a run-time payload beside a read of the helper"
# ...and a later -c operand is a candidate too, since which -c bash takes needs option arity.
assert_overblock "bash -c true -c \"\$HOME\"; echo $H" "a positional after the payload, beside a mention"
# Same for a watch operand: without watch's option table an interval or argv word may be
# the command. TERM is cleared so watch exits before running anything.
assert_overblock "TERM= watch -n \"\$I\" true; cat $H" "a watch interval that expands, beside a read"
assert_overblock "TERM= watch -x true \"\$HOME\"; cat $H" "a watch -x argument that expands, beside a read"
assert_block "X='python3 $H'; bash --rcfile /dev/null -c \"\$X\"" "a run-time payload behind an option operand"
assert_block "X='python3 $LIBDIR/${NAME%t.py}?.py'; bash -c \"\$X\"" "a run-time payload naming the helper through a ? glob"
assert_block "X='python3 $LIBDIR/${NAME%t.py}?.py'; trap \"\$X\" EXIT" "a run-time trap handler naming the helper through a ? glob"
# Accepted over-block, eval's: a vague glob beside a run-time payload is read as possibly
# naming a helper (`*n*` matches audit_append.py).
assert_overblock "X=true; bash -c \"\$X\"; ls -d *n* >/dev/null 2>&1" "a run-time payload beside a vague glob"

echo "=== a named coproc ==="
assert_block "coproc W { python3 $H; }; wait" "a named coproc running the helper"
assert_block "coproc W { trap 'python3 $H' EXIT; }; wait" "a named coproc setting a helper trap"
assert_block "coproc W { time python3 $H; }; wait" "a named coproc timing the helper"
assert_block "coproc W if python3 $H; then :; fi; wait" "a named coproc whose if runs the helper"
assert_block "coproc W until python3 $H; do :; done; wait" "a named coproc whose until runs the helper"
assert_block "bash -c 'coproc W { python3 $H; }; wait'" "a named coproc inside a bash -c payload"
assert_ok "coproc W { cat $H; }; wait" "a named coproc reading the helper"
assert_ok "coproc cat '{' $H; wait" "a quoted brace is an argument, not a coproc body"
assert_ok "coproc cat \"if\" $H; wait" "a quoted if is an argument, not a coproc body"
assert_ok "coproc cat '{' $H; wait # coproc cat { " "an unquoted pair elsewhere does not lend the quoted brace a body"
assert_ok "\"coproc\" cat { $H; wait" "a quoted coproc is a command name, not the keyword"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
