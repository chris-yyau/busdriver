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
# Residual, tracked in #1051: the same strings inside a single-quoted `bash -c` program
# (`bash -c 'echo "\$"; <payload>; echo "\$"'`) still read as OK, on main as here.

echo "=== marker_check: reads stay OK ==="
assert_ok "echo $E; echo $H; echo $E" "a mention between two such strings"
assert_ok "grep \"x\\\$\" $H; grep \"y\\\$\" $H" "two anchored greps of the helper"

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

echo "=== cmdword: the design gate reads the same strings ==="
assert_mod "echo $E; rm -rf src; echo $E" "the issue's shape"
assert_mod "echo \"\\\$\\\$\"; rm -rf src; echo \"\\\$\\\$\"" "an escaped \$\$"
assert_mod "echo \"a\\\$\" && rm -rf src && echo \"b\\\$\"" "text before each escaped \$"
assert_no_mod "echo $E; ls src; echo $E" "a read between two such strings"
assert_no_mod "grep \"x\\\$\" src/impl.py; grep \"y\\\$\" src/impl.py" "two anchored greps"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
