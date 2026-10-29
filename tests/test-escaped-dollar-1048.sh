#!/usr/bin/env bash
# Fail-open regressions for an ESCAPED `$` before a quote (#1048). `\$` is a literal dollar,
# so in `"\$"` the `"` closes the string. The first reading's `$"` -> `"` strip did not check
# for the escape and turned `"\$"` into `"\"`, an escaped quote, so the string ran on to the
# next `"` and two such strings hid the command between them:
#   echo "\$"; <payload>; echo "\$"
# _requote_ansi_c (#1043's second reading) already consumes a backslash with the character
# after it; the fix only widens when that reading runs. Both gates carry it: marker_check.py
# (the helper guard) and cmdword.py (the design gate).
#
# Every BLOCK / file-mod row is first EXECUTED under bash in a scratch tree and must really
# run the helper, really delete the directory or really write the marker -- a fixture that
# does not execute proves nothing about the guard.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/gate-scripts/lib"
CLASSIFIER="$LIB/marker_check.py"
PASS=0
FAIL=0
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
command -v timeout >/dev/null 2>&1 && TO=(timeout 60)
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() { # <command> -> the marker_check verdict line, or ERROR
    local payload out
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    if out=$(${TO[@]+"${TO[@]}"} python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf 'ERROR'
    fi
}

file_mod() { # <command> -> True / False from cmdword.is_file_mod, or ERROR
    ${TO[@]+"${TO[@]}"} python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1])
from cmdword import is_file_mod
print(is_file_mod(sys.argv[2]))' "$LIB" "$1" 2>/dev/null || printf 'ERROR'
}

LIBDIR="hooks/gate-scripts/lib"
NAME="lease""_slot.py"
H="$LIBDIR/$NAME"
MARKER=".claude/design-review-needed.local"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$LIBDIR"
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"
chmod +x "$SCRATCH/$H"

runs_helper() { # <command> -> 0 when bash, run in the scratch tree, executes the stub
    rm -f "$SCRATCH/$H.ran"
    (cd "$SCRATCH" && ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$H.ran" ]]
}

deletes_src() { # <command> -> 0 when bash, run in the scratch tree, removes src/; 2 on setup failure
    mkdir -p "$SCRATCH/src" && : > "$SCRATCH/src/impl.py" || return 2
    (cd "$SCRATCH" && ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ ! -e "$SCRATCH/src" ]]
}

assert_block() { # <command> <label>
    local got
    runs_helper "$1" || { no "$2" "fixture does not execute the helper under bash"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then no "$2" "got=$got — the classifier raised"
    elif [[ "$got" == BLOCK_UNSCANNABLE* ]]; then no "$2" "got=$got — the scan gave up, it found nothing"
    elif [[ "$got" == BLOCK_MARKER* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} — a real invocation was allowed"; fi
}

assert_ok() { # <command> <label>
    local got
    runs_helper "$1" && { no "$2" "fixture executes the helper -- it is not a read"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a read was refused"; fi
}

assert_marker_block() { # <command> <label> -- the command must really write the marker
    local got
    if ! { mkdir -p "$SCRATCH/.claude" && rm -f "$SCRATCH/$MARKER"; }; then
        no "$2" "could not prepare the .claude/ fixture"; return
    fi
    (cd "$SCRATCH" && ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$MARKER" ]] || { no "$2" "fixture does not write the marker under bash"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_MARKER* ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a marker write was allowed"; fi
}

assert_mod() { # <command> <label>
    local got
    local rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] || { no "$2" "fixture does not delete src/ under bash"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "True" ]]; then ok "$2"; else no "$2" "got=$got — a real deletion read as no file-mod"; fi
}

assert_no_mod() { # <command> <label>
    local got
    local rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] && { no "$2" "fixture deletes src/ -- it is not a read"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "False" ]]; then ok "$2"; else no "$2" "got=$got — a read was refused"; fi
}

E='"\$"'          # the string `"\$"`, exactly as typed
echo "=== marker_check: a payload between two strings ending in \\\$ ==="
assert_block "echo $E; python3 $H; echo $E" "the issue's shape"
assert_block "echo \"a\\\$\" ; python3 $H ; echo \"b\\\$\"" "text before each escaped \$"
assert_block "echo \"\\\$\\\$\"; python3 $H; echo \"\\\$\\\$\"" "an escaped \$\$"
assert_block "case \"\\\$\\\$\" in ?*) python3 $H ;; esac; echo \"\\\$\\\$\"" "a case subject"
assert_block "echo $E; bash -c \"python3 $H\"; echo $E" "an interpreter payload"
assert_block "x=\$(echo $E; python3 $H; echo $E)" "inside \$( )"
assert_block "echo \\\$'x'; python3 $H; echo \\\$'x'" "an escaped \$ before a single quote"
assert_marker_block "echo $E; printf W > $MARKER; echo $E" "a marker write"
assert_block "eval 'echo $E; python3 $H; echo $E'" "the same under eval"

# Nested programs (#1051). Inside the outer quote the `$` is the program's own text, so it is
# kept and the program is read as it would be at top level. sq quotes as shlex.quote does.
sq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
HAVE_DASH=0; command -v dash >/dev/null 2>&1 && HAVE_DASH=1
P1="echo $E; python3 $H; echo $E"
P2="echo \$'it\\'s'; python3 $H; echo '\\\$'"   # #1043's shape: $'it\'s' ... '\$'
M1="echo $E; echo $H; echo $E"
M2="echo \$'it\\'s'; echo $H; echo '\\\$'"
R1="echo $E; rm -rf src; echo $E"
R2="echo \$'it\\'s'; rm -rf src; echo '\\\$'"
L1="echo $E; ls src; echo $E"
D="printf '%s\\n' \$'\\''echo $H'"     # bash -n rejects it; dash has no $'...' and prints it
DM="printf '%s\\n' \$'\\''echo rm src'"
IM="echo \$'it\\'s'; echo rm src; echo '\\\$'"   # cmdword's own top-level #1043 residual
# Quoted once, up front, so each assertion's command is a plain expansion.
QP1=$(sq "$P1"); QP2=$(sq "$P2"); QM1=$(sq "$M1"); QM2=$(sq "$M2"); QR1=$(sq "$R1")
QR2=$(sq "$R2"); QL1=$(sq "$L1"); QD=$(sq "$D"); QDM=$(sq "$DM"); QIM=$(sq "$IM")
QSH=$(sq "sh -c $QP1")
echo "=== marker_check: the same payloads inside a program for another shell ==="
assert_block "bash -c $QP1" "a bash -c program"
assert_block "sh -c $QP1" "an sh -c program"
[[ $HAVE_DASH -eq 1 ]] && assert_block "dash -c $QP1" "a dash -c program"
assert_block "bash <<< $QP1" "a here-string program"
assert_block "bash -c $QSH" "sh -c inside bash -c"
assert_block "bash -c $QP2" "#1043's shape as a bash -c program"
assert_block "bash <<< $QP2" "#1043's shape as a here-string program"
# A double quote keeps the `$` too: there `$'` is literal to the outer shell (#1051 litmus).
assert_block "bash -c \"echo \$'it\\\\'s'; python3 $H; # it's\"" "#1043's shape as a double-quoted program"
# ...and #1048's, which that quoting types as `\\$\"`: the second reading must still fire.
# shellcheck disable=SC2016  # the text is the command, typed exactly
DQ1='bash -c "echo \"\\$\"; @W@; echo \"\\$\""'
assert_block "${DQ1/@W@/python3 $H}" "#1048's shape as a double-quoted program"
# An ANSI-C quote BEFORE the program is one quote too: read as a plain `'`, its `\'` closed it
# early and inverted every quote after it (#1051 litmus).
P3="echo \$'it\\'s'; python3 $H; # it's"; QP3=$(sq "$P3")
assert_block "echo \$'it\\'s'; bash -c $QP3" "an ANSI-C quote before the program"
# A backtick body loses a layer of backslashes first, so its raw `\\'` opens no quote; read as
# one, it swallowed the closer and inverted what followed (#1051 design review).
BT=": \"\`echo \\\\'\`\"; "
assert_block "${BT}bash -c $QP2" "a backtick body holding \\\\' before the program"
# A line continuation inside "\$" is joined before bash reads it, so the trigger must see the
# joined text too (#1051 design review).
CS=$'echo "\\$\\\n"; @W@; echo "\\$\\\n"'
CS_H=${CS/@W@/python3 $H}; QCS_H=$(sq "$CS_H")
assert_block "$CS_H" "#1048's shape split by a line continuation"
assert_block "bash -c $QCS_H" "the same as a bash -c program"
# ...and so is a bare CR, which the normalizer turns into a newline first (#1051 review).
CR=$'echo "\\$\\\r"; @W@; echo "\\$\\\r"'
CR_H=${CR/@W@/python3 $H}; QCR_H=$(sq "$CR_H")
assert_block "$CR_H" "#1048's shape split by a backslash-CR"
assert_block "bash -c $QCR_H" "the same as a bash -c program"
# Inside "..." bash drops the backslash of `\$` and shlex keeps it: a double-quoted program's
# `\$'it\'s'` must reach its own scan as the ANSI-C quote bash runs (#1051 review).
DQ2=$'bash -c "echo \\$\'it\\\\\'s\'; @W@; # it\'s"'
assert_block "${DQ2/@W@/python3 $H}" "a double-quoted program typing \\\$'it\\\\'s'"
DQ3=${DQ2/bash -c/bash <<<}
assert_block "${DQ3/@W@/python3 $H}" "the same as a double-quoted here-string"

echo "=== marker_check: reads stay OK ==="
assert_ok "echo $E; echo $H; echo $E" "a mention between two such strings"
assert_ok "grep \"x\\\$\" $H; grep \"y\\\$\" $H" "two anchored greps of the helper"
assert_ok "bash -c $QM1" "a mention inside a bash -c program"
assert_ok "sh -c $QM1" "a mention inside an sh -c program"
assert_ok "bash -c $QM2" "#1043's shape as a bash -c mention"
# A "$( ... )" body is unquoted to bash but quoted to the flat tokenizer, so a `$` there is
# dropped as before; keeping it misread these prints (#1051 litmus).
SUBQ="echo \"\$(echo \"\\\$(x)\"; echo @W@; echo \$'\\\\')\""
SUBP="echo \"\$(echo \"(\"; echo @W@; echo \"\$'\\\\'\")\""
SUBQ_H=${SUBQ/@W@/$H}; SUBQ_R=${SUBQ/@W@/rm src}; SUBP_H=${SUBP/@W@/$H}; SUBP_R=${SUBP/@W@/rm src}
assert_ok "$SUBQ_H" "a mention in a quoted \$( ) beside \$'\\\\'"
assert_ok "$SUBP_H" "a mention in a quoted \$( ) beside \"(\" and \"\$'\\\\'\""
# So is one where bash reads a different KIND of quote than the flat tokenizer: a single-quoted
# program inside "$( )" (#1051 design review).
SUBB=": \"\$(bash -c $(sq "echo \"(\"; echo @W@; echo \$'\\\\'"))\""
SUBB_H=${SUBB/@W@/$H}; SUBB_R=${SUBB/@W@/rm src}
assert_ok "$SUBB_H" "a mention in a quoted \$( ) around a bash -c program"
# Main refused this read only through the #1048 misreading; it now gets its plain twin's OK
# (review fuzz, seed 91).
LR=$'echo "\\$\\\r" | cat; sh -c \'echo \'"\'"\'\\$\'"\'"\' && cat @W@ && echo "\\$\\\r"\ncat @W@ || echo $\'"\'"\'\\\\\'"\'"\'\''
assert_ok "${LR//@W@/$H}" "a read behind \"\\\$\\<CR>\" in an sh -c program"

echo "=== marker_check: what main refuses without the strings, it now refuses with them ==="
# Deliberate, not a regression: main refuses this pipe into a group whose shell reads only
# echo's output (the piped-producer reading is wide on purpose). The misreading had
# exempted it whenever two "\$\$" strings sat around it; it now gets its plain twin's answer.
assert_refused() { # <command> <label> -- bash does not run the helper; the guard still refuses
    local got
    runs_helper "$1" && { no "$2" "fixture executes the helper"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_MARKER_SCRIPT* ]]; then ok "$2"; else no "$2" "got=${got:-<empty>}"; fi
}
assert_refused "printf 'python3 $H\\n' | { case x in *) echo \"\$\$\" ;; esac | bash; }" "the plain twin"
assert_refused "echo \"\\\$\\\$\"; printf 'python3 $H\\n' | { case x in *) echo \"\$\$\" ;; esac | bash; }; echo \"\\\$\\\$\"" \
    "the same between two escaped strings"

echo "=== inherited from top level: a nested program gets its own top-level answer (#1051) ==="
# Deliberate, not a regression. Each program below only prints (or is a bash syntax error),
# and main ALREADY refuses it at top level. Nested, main allowed it only because the `$` loss
# that hid #1051's payloads also mangled these into text that parsed clean. Both readings are
# a union, so nothing in the second one can clear a top-level refusal.
assert_refused_mod() { # <command> <label> -- bash does not delete src/; the design gate still refuses
    local got
    local rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] && { no "$2" "fixture deletes src/"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "True" ]]; then ok "$2"; else no "$2" "got=$got"; fi
}
assert_refused "$D" "a \$'\\'' program at top level"
assert_refused "bash -c $QD" "the same as a bash -c program"
[[ $HAVE_DASH -eq 1 ]] && assert_refused "dash -c $QD" "the same as a dash -c program"
[[ $HAVE_DASH -eq 1 ]] && assert_refused "dash -c $QP2" "#1043's shape, which dash rejects"
assert_refused_mod "$DM" "cmdword: a \$'\\'' program at top level"
[[ $HAVE_DASH -eq 1 ]] && assert_refused_mod "dash -c $QDM" "cmdword: the same as a dash -c program"
assert_refused_mod "$IM" "cmdword: #1043's print-only shape at top level"
assert_refused_mod "bash -c $QIM" "cmdword: the same as a bash -c program"
# The double-quoted spelling of the same program: its `\$'` is respelled to the `$'` bash
# passes, so it gets TOP's answer too.
DD=$'bash -c "printf \'%s\\\\n\' \\$\'\\\\\'\'echo @W@\'"'
assert_refused "${DD/@W@/$H}" "the \$'\\'' program double-quoted"
# A `"\$\<CR>"` before an `||` branch bash does not take: main exempted it only through the
# #1048 misreading, and refuses its plain twin (review fuzz, seeds 81/83).
RH=$'echo "$$" && echo "\\$\\\r" || bash -c "python3 @W@"; echo \\$; echo "\\$\\\n"'
assert_refused "${RH/@W@/$H}" "a \"\\\$\\<CR>\" before an untaken || branch"
assert_refused "echo \"\$\$\" && echo x || bash -c \"python3 $H\"; echo \\\$; echo y" "its plain twin"
if [[ $HAVE_DASH -eq 1 ]]; then
    RM=$'dash -c \'echo "\\$\\\r" || rm -rf src; echo \\$ | cat; echo "\\$\\\n"\''
    assert_refused_mod "$RM" "cmdword: the same before an untaken || under dash"
    assert_refused_mod "dash -c 'echo x || rm -rf src; echo \\\$ | cat; echo y'" "cmdword: its plain twin"
fi
# A "\$" split by a line continuation now reads as the joined "\$" bash runs, and main refuses
# that joined spelling here (review fuzz, seed 93).
# shellcheck disable=SC2016  # the text is the command, typed exactly
JT='x="$(sh -c '\''echo "("; echo "\$"'\'')"'
assert_refused_mod "${JT/\\\$/\\\$\\$'\n'}" "cmdword: a split \"\\\$\" in a quoted \$( ) program"
assert_refused_mod "$JT" "cmdword: its joined spelling"

echo "=== a program split across adjacent outer fragments (#1051 design review) ==="
# Each `\$"` split across fragments leaves none in the raw text, while bash still runs
# #1048's program; the trigger must not depend on the outer quoting.
SPL="bash -c 'echo \"''\\''\$\"; @W@; echo \"''\\''\$\"'"
assert_block "${SPL/@W@/python3 $H}" "#1048's shape split across adjacent fragments"
assert_mod "${SPL/@W@/rm -rf src}" "cmdword: the same with rm"
assert_ok "${SPL/@W@/echo $H}" "its print stays OK"
assert_no_mod "${SPL/@W@/ls src}" "cmdword: its read stays no file-mod"
# ...and #1043's, its `$` and `'` in adjacent fragments.
S43="bash -c 'echo \$'\"'\"'it\\'\\''s'\"'\"'; @W@; echo '\\''\\\$'\\'''"
assert_block "${S43/@W@/python3 $H}" "#1043's shape split across adjacent fragments"
assert_mod "${S43/@W@/rm -rf src}" "cmdword: the same with rm"
assert_ok "${S43/@W@/echo $H}" "its print stays OK"
QSHR=$(sq "sh -c $QR1")
assert_mod "bash -c $QSHR" "cmdword: sh -c inside bash -c"

# Accepted, not inherited: the pre-pass cannot pair a `case` arm's `)` inside "$( … )", so it
# keeps a `$` there and refuses this print, which main allowed (operator, 2026-10-29). The
# same program without the `case` stays allowed above.
CASEB=": \"\$(case x in x) bash -c $(sq "echo \"(\"; echo @W@; echo \$'\\\\'") ;; esac)\""
assert_refused "${CASEB/@W@/$H}" "a print in a case arm in a quoted \$( )"
assert_refused_mod "${CASEB/@W@/rm src}" "cmdword: the same"
# Accepted the same way: the pre-pass does not model a `${…}` word, so in a double-quoted
# one it keeps the `$` of `$""` that bash consumes (operator, 2026-10-29; PR-mode litmus).
# shellcheck disable=SC2016  # the text is the command, typed exactly
PEX='printf "%s\n" "${x:-echo "\$(x)"; @W@; echo $""}"'
assert_refused "${PEX/@W@/echo $H}" "a print in a double-quoted \${…} word"
assert_refused_mod "${PEX/@W@/rm src}" "cmdword: the same"
# shellcheck disable=SC2016  # the text is the command, typed exactly
PEX2='printf "%s\n" "${x:-echo @W@; echo $""}"'
assert_ok "${PEX2/@W@/echo $H}" "the same word without the escaped \$( stays OK"

echo "=== cmdword: the design gate reads the same strings ==="
assert_mod "echo $E; rm -rf src; echo $E" "the issue's shape"
assert_mod "echo \"\\\$\\\$\"; rm -rf src; echo \"\\\$\\\$\"" "an escaped \$\$"
assert_mod "echo \"a\\\$\" && rm -rf src && echo \"b\\\$\"" "text before each escaped \$"
assert_mod "bash -c $QR1" "a bash -c program"
assert_mod "sh -c $QR1" "an sh -c program"
[[ $HAVE_DASH -eq 1 ]] && assert_mod "dash -c $QR1" "a dash -c program"
assert_mod "bash <<< $QR1" "a here-string program"
assert_mod "bash -c $QR2" "#1043's shape as a bash -c program"
assert_mod "bash <<< $QR2" "#1043's shape as a here-string program"
assert_mod "bash -c \"echo \$'it\\\\'s'; rm -rf src; # it's\"" "#1043's shape as a double-quoted program"
assert_mod "${DQ1/@W@/rm -rf src}" "#1048's shape as a double-quoted program"
R3="echo \$'it\\'s'; rm -rf src; # it's"; QR3=$(sq "$R3")
assert_mod "echo \$'it\\'s'; bash -c $QR3" "an ANSI-C quote before the program"
assert_mod "${BT}bash -c $QR2" "a backtick body holding \\\\' before the program"
CS_R=${CS/@W@/rm -rf src}; QCS_R=$(sq "$CS_R")
assert_mod "$CS_R" "#1048's shape split by a line continuation"
assert_mod "bash -c $QCS_R" "the same as a bash -c program"
CR_R=${CR/@W@/rm -rf src}; QCR_R=$(sq "$CR_R")
assert_mod "$CR_R" "#1048's shape split by a backslash-CR"
assert_mod "bash -c $QCR_R" "the same as a bash -c program"
assert_mod "${DQ2/@W@/rm -rf src}" "a double-quoted program typing \\\$'it\\\\'s'"
assert_mod "${DQ3/@W@/rm -rf src}" "the same as a double-quoted here-string"

echo "=== the two gates carry the same readings ==="
# KEEP IN STEP, enforced: the three functions this issue changed must parse to the same code
# in both modules, docstrings and comments aside, and the trigger patterns must match.
# shellcheck disable=SC2016  # a Python program
if out=$(python3 -I -c '
import ast, sys
# Parsed, not imported: importing marker_check runs its hook main(), which reads stdin.
trees = [ast.parse(open(sys.argv[1] + "/" + m).read()) for m in ("cmdword.py", "marker_check.py")]
def node(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            if isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant):
                n.body = n.body[1:]
            return ast.dump(n)
        if isinstance(n, ast.Assign) and any(getattr(t, "id", "") == name for t in n.targets):
            return ast.dump(n)
    return "missing " + name
names = ("_requote_ansi_c", "_bash_quoted", "_ansi_c_differs", "_ansi_c_span", "_dollar_run_is_even",
         "_DOLLAR_QUOTE_RE", "_opens_ansi_c", "_is_unquoted_paren", "_drops_dollar",
         "_respells_escaped_dollar")
print(" ".join(n for n in names if node(trees[0], n) != node(trees[1], n)
               or node(trees[0], n).startswith("missing")))' "$LIB" 2>&1) && [[ -z "$out" ]]; then
    ok "the second reading, its pre-pass, its trigger and their helpers match"
else
    no "the copies match" "differs: ${out:-<python failed>}"
fi
assert_no_mod "echo $E; ls src; echo $E" "a read between two such strings"
assert_no_mod "bash -c $QL1" "the same read as a bash -c program"
# ...and #1043's nested read, the cmdword twin of the marker_check mention above (Kody).
assert_no_mod "bash -c $(sq "echo \$'it\\'s'; ls src; echo '\\\$'")" "#1043's shape as a bash -c read"
assert_no_mod "${DQ2/@W@/ls src}" "the same as a double-quoted program"
assert_no_mod "$SUBQ_R" "a print in a quoted \$( ) beside \$'\\\\'"
assert_no_mod "$SUBP_R" "a print in a quoted \$( ) beside \"(\" and \"\$'\\\\'\""
assert_no_mod "$SUBB_R" "a print in a quoted \$( ) around a bash -c program"
assert_no_mod "grep \"x\\\$\" src/impl.py; grep \"y\\\$\" src/impl.py" "two anchored greps"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
