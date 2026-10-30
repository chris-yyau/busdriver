#!/usr/bin/env bash
# #1068: bash's writable tables (`BASH_CMDS`, `BASH_ALIASES`) re-point a command name within the
# same command in more spellings than `BASH_CMDS[`. The marker gate's indirection trigger must
# withdraw the mention contract for all of them, as #1055 did for zsh's tables.
#
# Row types:
#   assert_block        -- executing it under bash runs the stub helper (a marker file, not an
#                          exit status), AND it classifies BLOCK.
#   assert_ok           -- executing it under bash does NOT run the stub, AND it classifies OK.
#   assert_block_noexec -- a deliberate over-block that does not execute; must classify BLOCK.
#   assert_residual     -- #1066's documented residual: it DOES run the stub, and classifies OK.
#                          A failure here means the residual was closed; update this pin.
# Without bash >= 4 (associative arrays) the file prints SKIP; REQUIRE_BASH=1 turns that into a
# FAIL. The helper name is assembled from fragments because the live hook refuses a Bash call
# that spells it.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0 FAIL=0
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
command -v timeout >/dev/null 2>&1 && TO=(timeout 60)
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

H="hooks/gate-scripts/lib/lease""_slot.py"
PY="$(command -v python3)"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$(dirname "$H")"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"

SH="$(command -v bash)"
if ! "$SH" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
    if [[ "${REQUIRE_BASH:-0}" == 1 ]]; then echo "FAIL: bash >= 4 is required"; exit 1; fi
    echo "SKIP: bash >= 4 missing"; exit 0
fi
# BASH_ALIASES is bash 4.3+ and `printf -v` into an array element 4.1+; below 4.3 only those
# rows are skipped, loudly, so the BASH_CMDS rows (bash 4.0) still run.
NEW_BASH=0
"$SH" -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))' \
    2>/dev/null && NEW_BASH=1
too_old() { # <command> <label> -> 0 (and prints skip) when this bash cannot run the row
    [[ "$NEW_BASH" != 1 && ( "$1" == *BASH_ALIASES* || "$1" == *"printf -v"* ) ]] || return 1
    printf '  skip  %s :: needs bash >= 4.3\n' "$2"
}

ran_under_bash() { # <command> -> 0 when the stub helper ran
    rm -f "$SCRATCH/$H.ran"
    (cd "$SCRATCH" && env ${TO[@]+"${TO[@]}"} "$SH" -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$H.ran" ]]
}

assert_block() { # <command> <label>
    local got
    too_old "$1" "$2" && return
    ran_under_bash "$1" || { no "$2" "fixture does not execute the helper under bash -- it proves nothing"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then no "$2" "got=$got -- the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- a real invocation was allowed"; fi
}

assert_ok() { # <command> <label>
    local got
    if ran_under_bash "$1"; then no "$2" "control executes the helper"; return; fi
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} -- refused"; fi
}

assert_block_noexec() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- expected the deliberate over-block"; fi
}

assert_residual() { # <command> <label>
    local got
    too_old "$1" "$2" && return
    ran_under_bash "$1" || { no "$2" "fixture does not execute the helper under bash -- it proves nothing"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- the #1066 residual is now caught; update this pin and the marker_check comment"; fi
}

# Every row re-points `cat`, whose operand is otherwise a MENTION of the helper (read, not run).
# Aliases expand only on a LATER line, so those rows carry a real newline.
NL=$'\n'
AL="shopt -s expand_aliases; "
echo "=== #1068: bash table assignments that re-point a name are indirection ==="
assert_block "BASH_CMDS[cat]=$PY; cat $H" "BASH_CMDS[NAME]= (the branch that already existed)"
assert_block "BASH_CMDS=([cat]=$PY); cat $H" "BASH_CMDS=( ) whole-table assignment"
assert_block "BASH_CMDS+=([cat]=$PY); cat $H" "BASH_CMDS+=( )"
assert_block "declare -A BASH_CMDS=([cat]=$PY); cat $H" "declare -A BASH_CMDS=( )"
assert_block "${AL}BASH_ALIASES[cat]=$PY${NL}cat $H" "BASH_ALIASES[NAME]= then a new line"
assert_block "${AL}BASH_ALIASES=([cat]=$PY)${NL}cat $H" "BASH_ALIASES=( ) then a new line"
assert_block "${AL}BASH_ALIASES+=([cat]=$PY)${NL}cat $H" "BASH_ALIASES+=( ) then a new line"

echo "=== mentions that are not the parameter stay OK ==="
assert_ok "cat $H" "plain read (control)"
assert_ok "ls BASH_CMDS/; cat $H" "BASH_CMDS/ as a path segment"
assert_ok "cat docs/BASH_ALIASES.md $H" "BASH_ALIASES.md as a file name"

echo "=== deliberate over-block: the trigger is the WORD ==="
assert_block_noexec "grep -n BASH_CMDS $H" "bare-word mention of the table name"

echo "=== #1066 residual: names assembled from variables (documented, not chased) ==="
assert_residual "X=BASH_; printf -v \"\${X}CMDS[cat]\" %s $PY; cat $H" "assembled table name"
assert_residual "E=ev; \${E}al \"cat() { $PY \\\"\\\$@\\\"; }\"; cat $H" "assembled command word"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
