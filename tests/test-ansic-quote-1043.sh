#!/usr/bin/env bash
# Fail-open regressions for ANSI-C quoting (#1043). Inside `$'…'` a backslash escapes the
# next character, so the `'` in `$'it\'s'` is data. Two readers took it as the closer:
#   - the `$'` -> `'` strip before shlex, so the next stray apostrophe anywhere later in the
#     command (`echo \'`, a `# it's` comment) closed a phantom quote around the payload;
#   - _defuse_comments, so a comment after such a quote sat in a phantom quote and its
#     separators and apostrophes were never blanked.
# Both live twice: marker_check.py (the helper guard) and cmdword.py (the design gate).
#
# Every BLOCK / file-mod row is first EXECUTED under bash in a scratch tree and must really
# run the helper or really delete the directory -- a fixture that does not execute proves
# nothing about the guard.
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
NL=$'\n'

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
    elif [[ "$got" == BLOCK_* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} — a real invocation was allowed"; fi
}

assert_ok() { # <command> <label>
    local got
    runs_helper "$1" && { no "$2" "fixture executes the helper -- it is not a read"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a read was refused"; fi
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

echo "=== marker_check: an escaped apostrophe in \$'…' closes nothing ==="
assert_block "printf %s \$'it\\'s' && python3 $H && echo \\'" "a later escaped apostrophe"
assert_block "printf %s \$'it\\'s' && python3 $H # it's" "a later comment apostrophe"
assert_block "printf %s \$'it\\'s' && python3 $H${NL}# it's" "a comment apostrophe on the next line"
assert_block "printf %s \$'it\\'s' && bash -c \"python3 $H\" # it's" "an interpreter payload"
assert_block "printf %s \$'it\\'s' && bash -c \"python3 $H\" && cat <<'E' # it's${NL}true${NL}E${NL}" \
    "the issue's heredoc shape"
assert_block "x=\$(printf %s \$'it\\'s' && bash -c \"python3 $H\" && cat <<'E' # it's${NL}true${NL}E${NL})" \
    "the same inside \$( )"
assert_block "printf %s \$'it\\\\' && python3 $H && echo \\'" "an escaped backslash before the closer"
assert_block "printf %s \$\$'x' && python3 $H && echo \\'" "\$\$ is the PID, not an ANSI-C opener"
# Inside double quotes `$'` is literal text, not an ANSI-C opener.
assert_block "echo \"\$'\" && python3 $H && echo \"'\"" "a \$' inside double quotes"
# A comment after an ANSI-C quote is a comment: its separators must not split a pipeline.
assert_block "printf '%s\\n' 'python3 $H' \$'#it\\'s' | # ; x${NL}bash" "a comment separator after an ANSI-C quote"

MARKER=".claude/design-review-needed.local"
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

echo "=== marker_check: a heredoc body is data, so the first reading must survive (litmus) ==="
# Bash reads no quotes in a heredoc body. Read as an ANSI-C quote, the body's `$'it\'s`
# ran on past the body into the write; the first reading blocks it, so it must still run.
assert_marker_block "cat <<'EOF'${NL}\$'it\\'s${NL}EOF${NL}printf W > $MARKER # it's" \
    "an unterminated \$' in a heredoc body"
assert_marker_block "cat <<'EOF'${NL}\$'it\\'s' y '${NL}EOF${NL}printf W > $MARKER # it's" \
    "a closed \$'…' and a stray quote in a heredoc body"
assert_block "cat <<'EOF'${NL}\$'it\\'s${NL}EOF${NL}python3 $H # it's" "the helper after such a body"
assert_block "cat <<'EOF'${NL}\$'it\\'s' y '${NL}EOF${NL}python3 $H # it's" "the helper after a stray quote"

echo "=== a heredoc body is over-read as shell, as main reads every other body ==="
# Deliberate, not a regression: main refuses `cat <<'EOF'` + `python3 <helper>` + `EOF`
# (and calls `rm -rf src` in a body a write), because a body fed to `sh`/`bash -s`
# runs. The `$'it\'s'` spelling escaped that only through the misreading this issue
# closes, so it now gets the same answer as its plain twin.
assert_refused() { # <command> <label> -- bash only prints; the guard still refuses
    local got
    runs_helper "$1" && { no "$2" "fixture executes the helper"; return; }
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_MARKER_SCRIPT* ]]; then ok "$2"; else no "$2" "got=${got:-<empty>}"; fi
}
assert_refused "cat <<'EOF'${NL}python3 $H${NL}EOF" "main's over-read of a printed helper call"
assert_refused "cat <<'EOF'${NL}printf %s \$'it\\'s' && python3 $H # it's${NL}EOF" \
    "the same body behind an ANSI-C quote"

echo "=== marker_check: reads stay OK ==="
assert_ok "printf %s \$'it\\'s' && echo $H # it's" "a mention after an ANSI-C quote"
assert_ok "printf %s \$'it\\'s' && cat <<'E' # it's${NL}true${NL}E${NL}" "a harmless heredoc"

echo "=== cmdword: the design gate reads the same quotes ==="
assert_mod "printf %s \$'it\\'s' && rm -rf src && echo \\'" "a later escaped apostrophe"
assert_mod "printf %s \$'it\\'s' && rm -rf src # it's" "a later comment apostrophe"
assert_mod "printf %s \$'it\\'s' && rm -rf src${NL}# it's" "a comment apostrophe on the next line"
assert_mod "printf %s \$'it\\'s' && rm -rf src && cat <<'E' # it's${NL}true${NL}E${NL}" "the heredoc shape"
assert_mod "echo \"\$'\" && rm -rf src && echo \"'\"" "a \$' inside double quotes"
assert_mod "cat <<'EOF'${NL}\$'it\\'s${NL}EOF${NL}rm -rf src # it's" "a write after a heredoc body's \$'"
assert_mod "cat <<'EOF'${NL}\$'it\\'s' y '${NL}EOF${NL}rm -rf src # it's" "a write after a body's stray quote"
assert_no_mod() { # <command> <label>
    local got
    local rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] && { no "$2" "fixture deletes src/ -- it is not a read"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "False" ]]; then ok "$2"; else no "$2" "got=$got — a read was refused"; fi
}
assert_no_mod "printf %s \$'it\\'s' && ls src # it's" "a read after an ANSI-C quote"
# Pins the _defuse_comments half: in a phantom quote the comment's `;` stayed a separator.
assert_no_mod "printf %s \$'it\\'s' # ; rm -rf src '" "a write that only sits in a comment"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
