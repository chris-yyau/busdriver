#!/usr/bin/env bash
# #1055: zsh's writable command tables (`functions`, `dis_functions`, `commands`) re-point a
# command name within the same command, as BASH_CMDS[ does in bash. The marker gate's
# indirection trigger must withdraw the mention contract for them.
#
# Row types:
#   assert_block        -- executing it under zsh runs the stub helper (a marker file, not an
#                          exit status), AND it classifies BLOCK.
#   assert_ok           -- executing it under zsh does NOT run the stub, AND it classifies OK.
#   assert_block_noexec -- a deliberate over-block that does not execute; must classify BLOCK.
# A row whose shell is missing prints SKIP; REQUIRE_ZSH=1 turns that into a FAIL. The helper
# name is assembled from fragments because the live hook refuses a Bash call that spells it.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0 FAIL=0 SKIP=0
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
mkdir -p "$SCRATCH/$(dirname "$H")" "$SCRATCH/commands"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"

if ! command -v zsh >/dev/null 2>&1; then
    if [[ "${REQUIRE_ZSH:-0}" == 1 ]]; then echo "FAIL: zsh is required but missing"; exit 1; fi
    echo "SKIP: zsh missing"; exit 0
fi

ran_under_zsh() { # <command> -> 0 when the stub helper ran
    rm -f "$SCRATCH/$H.ran"
    (cd "$SCRATCH" && env ${TO[@]+"${TO[@]}"} zsh -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$H.ran" ]]
}

assert_block() { # <command> <label>
    local got
    ran_under_zsh "$1" || { no "$2" "fixture does not execute the helper under zsh -- it proves nothing"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then no "$2" "got=$got -- the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- a real invocation was allowed"; fi
}

assert_ok() { # <command> <label>
    local got
    if ran_under_zsh "$1"; then no "$2" "control executes the helper"; return; fi
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} -- refused"; fi
}

assert_block_noexec() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- expected the deliberate over-block"; fi
}

# Every row re-points `cat`, whose operand is otherwise a MENTION of the helper (read, not run).
RUN="'$PY \"\$@\"'"
echo "=== #1055: zsh table assignments that re-point a name are indirection ==="
assert_block "functions[cat]=$RUN; cat $H" "functions[NAME]="
assert_block "functions+=([cat]=$RUN); cat $H" "functions+=( )"
assert_block "functions=(cat $RUN); cat $H" "functions=( ) whole-table assignment"
assert_block "dis_functions[cat]=$RUN; enable -f cat; cat $H" "dis_functions[NAME]= then enable -f"
assert_block "commands[cat]=$PY; cat $H" "commands[NAME]="
assert_block "commands+=([cat]=$PY); cat $H" "commands+=( )"
assert_block "commands=(cat $PY); cat $H" "commands=( ) whole-table assignment"
assert_block "set -A commands cat $PY; cat $H" "set -A commands"
assert_block "set -Acommands cat $PY; cat $H" "set -Acommands (option letter attached)"
assert_block "set -Afunctions cat $RUN; cat $H" "set -Afunctions (option letter attached)"
assert_block ": \${commands[cat]::=$PY}; cat $H" "\${commands[NAME]::=...} expansion-time assignment"
assert_block ": \${(AA)=commands::=cat $PY}; cat $H" "\${(AA)=commands::=...} whole-table expansion"
assert_block "typeset commands[cat]=$PY; cat $H" "typeset commands[NAME]="

echo "=== mentions that are not the parameter stay OK ==="
assert_ok "cat $H" "plain read (control)"
assert_ok "ls commands/ && cat $H" "commands/ as a path segment"
assert_ok "cat docs/functions.md $H" "functions.md as a file name"
assert_ok "aliases[cat]=$PY; cat $H" "aliases[NAME]= does not take effect in the same command"

echo "=== deliberate over-block: a read-only expansion of the table ==="
assert_block_noexec "echo \${functions[cat]}; cat $H" "read-only \${functions[NAME]}"

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
