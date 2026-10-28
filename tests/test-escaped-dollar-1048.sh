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
assert_no_mod "echo $E; ls src; echo $E" "a read between two such strings"
assert_no_mod "bash -c $QL1" "the same read as a bash -c program"
assert_no_mod "$SUBQ_R" "a print in a quoted \$( ) beside \$'\\\\'"
assert_no_mod "$SUBP_R" "a print in a quoted \$( ) beside \"(\" and \"\$'\\\\'\""
assert_no_mod "grep \"x\\\$\" src/impl.py; grep \"y\\\$\" src/impl.py" "two anchored greps"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
