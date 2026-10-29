#!/usr/bin/env bash
# #1052: a command that is ONLY `[cd W &&] python3|node [- args] <<'D' <body> D` runs the body
# as the interpreter's program, so NAME()-shaped text there (a method call) must not withdraw
# the mention contract. Spec: docs/specs/2026-10-28-marker-heredoc-interp-design.md.
#
# Row types:
#   assert_ok          -- classifies OK, AND executing it runs the interpreter body (it writes
#                         a sentinel) without running the stub helper.
#   assert_block       -- executing it under each named shell runs the stub (a marker file,
#                         not an exit status), AND it classifies BLOCK.
#   assert_block_noexec -- a deliberate over-block that does not execute; must classify BLOCK.
# A row whose shell or interpreter is missing prints SKIP and is counted; REQUIRE_ZSH=1 (and
# REQUIRE_NODE=1) turn a SKIP into a FAIL. The helper name is assembled from fragments
# because the live hook refuses a Bash call that spells it.
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
skip() {
    if [[ "${REQUIRE_ZSH:-0}" == 1 && "$2" == zsh ]] || [[ "${REQUIRE_NODE:-0}" == 1 && "$2" == node ]]; then
        no "$1" "$2 is required but missing"
    else
        SKIP=$((SKIP + 1)); printf '  SKIP  %s (%s missing)\n' "$1" "$2"
    fi
}

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
G="$LIBDIR/lease""_slo?.py"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$LIBDIR" "$SCRATCH/dir"
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"
chmod +x "$SCRATCH/$H"

run_in() { # <shell> <command> -- run in the scratch tree, never fail the harness
    (cd "$SCRATCH" && env -u A -u X ${TO[@]+"${TO[@]}"} "$1" -c "$2" >/dev/null 2>&1) || true
}

assert_ok() { # <command> <label> <interpreter binary the row needs> -- executed under bash and zsh
    local got sh
    if ! command -v "$3" >/dev/null 2>&1; then skip "$2" "$3"; return; fi
    for sh in bash zsh; do
        if ! command -v "$sh" >/dev/null 2>&1; then skip "$2 [$sh]" "$sh"; continue; fi
        rm -f "$SCRATCH/$H.ran" "$SCRATCH/body.ran" "$SCRATCH/dir/body.ran"
        run_in "$sh" "$1"
        if [[ -f "$SCRATCH/$H.ran" ]]; then no "$2 [$sh]" "control executes the helper"; return; fi
        if [[ ! -f "$SCRATCH/body.ran" && ! -f "$SCRATCH/dir/body.ran" ]]; then
            no "$2 [$sh]" "the interpreter body did not run -- the row proves nothing"; return
        fi
    done
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} -- refused"; fi
}

assert_block() { # <command> <label> [shells: "bash zsh" | bash | zsh; default bash]
    local sh got ran=0
    for sh in ${3:-bash}; do
        if ! command -v "$sh" >/dev/null 2>&1; then skip "$2 [$sh]" "$sh"; continue; fi
        rm -f "$SCRATCH/$H.ran"
        run_in "$sh" "$1"
        if [[ -f "$SCRATCH/$H.ran" ]]; then ran=1; else
            no "$2 [$sh]" "fixture does not execute the helper under $sh -- it proves nothing"; return
        fi
    done
    [[ $ran == 1 ]] || return
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then no "$2" "got=$got -- the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- a real invocation was allowed"; fi
}

assert_block_noexec() { # <command> <label> -- deliberate over-block, not executed
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- expected the 3.0.12 over-block"; fi
}

# Bodies with an empty-paren method call (the NAME() shape), an ordinary glob, and a sentinel
# proving the body ran. With the predicate disabled, rows using them must come back BLOCK
# (checked in the mutation step below); that is what makes them guards.
# The helper GLOB in a string is what 3.0.12's probe matches once NAME() withdraws the
# contract; without it a row can be OK on 3.0.12 already and guard nothing.
PYB="import glob
p = 'body.ran'
open(p, 'w').write(open('/etc/hosts').read()[:1])
print(glob.glob('/*'), 'a.b'.split('.'), '$G')"
JSB="const fs = require('fs');
fs.writeFileSync('body.ran', 'x');
console.log(process.cwd(), process.argv.slice(2));
console.log('$G');"

echo "=== #1052: the stdin-program shape is OK ==="
assert_ok "python3 - <<'E'
$PYB
E" "python3 - <<'E'" python3
assert_ok "python3 <<'E'
$PYB
E" "python3 <<'E' (no -)" python3
assert_ok "python3 - a b <<'E'
$PYB
E" "python3 - with argv" python3
assert_ok "python3  -  <<'E'
$PYB
E" "multiple spaces between tokens" python3
assert_ok "cd dir && python3 - <<'E'
$PYB
E" "cd WORD && python3 -" python3
assert_ok "python3 - 2>&1 <<\"E\"
$PYB
E" "2>&1 and a double-quoted delimiter" python3
assert_ok "python3 - <<\\E >/dev/null
$PYB
E" "backslash delimiter and >/dev/null" python3
assert_ok "python3 - <<'E'
#!/bin/sh
$PYB
E" "a #! first body line is a Python comment" python3
assert_ok "python3 - '<<\"F\"' <<'E'
$PYB
F
E" "decoy <<\"F\" in a quoted argv word does not end the body" python3
assert_ok "python - <<'E'
$PYB
E" "python receiver" python
assert_ok "python2 - <<'E'
$PYB
E" "python2 receiver" python2
PY3N="python3.$(python3 -c 'import sys;print(sys.version_info[1])')"
assert_ok "$PY3N - <<'E'
$PYB
E" "python3.N receiver" "$PY3N"
assert_ok "python3 - <<'E'
s = '\`date\` and \$(date) and \${x}'
$PYB
E" "backtick, \$( and \${ inside a quoted body" python3
assert_ok "node - a <<'E'
$JSB
E" "node - <<'E'" node
assert_ok "node <<'E'
#!/bin/sh
$JSB
E" "node, #! first body line is a JS comment" node

echo "=== #1052: grammar near-misses keep their 3.0.12 BLOCK ==="
# Each row below is BLOCK on 3.0.12 because the body holds NAME() text and a helper glob.
# A near-miss keeps whatever 3.0.12 says; if that is OK, the row does not belong here.
NM_BODY="x = open(p).read()
print('$G')"
NL=$'\n' CR=$'\r'
assert_block_noexec "python3	- <<'E'
$NM_BODY
E" "tab separator"
assert_block_noexec "python3 - << 'E'
$NM_BODY
E" "space between << and the delimiter (review note 4)"
assert_block_noexec " python3 - <<'E'
$NM_BODY
E" "leading space on the introducer line"
assert_block_noexec "python3 -u - <<'E'
$NM_BODY
E" "an interpreter option"
assert_block_noexec "/usr/bin/python3 - <<'E'
$NM_BODY
E" "path-qualified receiver"
assert_block_noexec "python3-config - <<'E'
$NM_BODY
E" "suffixed receiver name"
assert_block_noexec "python3 - <<E
$NM_BODY
E" "unquoted delimiter"
assert_block_noexec "python3 - <<-'E'
$NM_BODY
E" "<<- operator"
assert_block_noexec "python3 - 0<<'E'
$NM_BODY
E" "descriptor prefix"
assert_block_noexec "python3 - <<'E' > out.txt
$NM_BODY
E" "file redirection"
assert_block_noexec "python3 - >/dev/null 2>&1 <<'E'
$NM_BODY
E" "two ERR tokens on one side (review note 3)"
assert_block_noexec "python3 - <<'E'${NL}${NM_BODY}${NL}E${NL}${NL}" "a second trailing newline (review note 2)"
assert_block_noexec "python3 - <<'E'${CR}${NL}${NM_BODY}${CR}${NL}E${CR}" "CRLF line endings"
assert_block_noexec "python3 - 'x;foo()' '$G' <<'E'
print(1)
E" "NAME() text in a quoted argv word still triggers (review note 1)"
assert_block_noexec "python3 - 'if\${IFS}foo()' '$G' <<'E'
print(1)
E" "NAME() behind \${IFS} in a quoted argv word still triggers (normalized reading)"

echo "=== #1052: the OTHER indirection branches still read the whole body ==="
# These commands MATCH §2, so only the non-NAME() branches can block them. They pin that
# _INDIRECTION_OTHER_RE keeps reading the full command (spec §1), via the second mutation
# step below. (`eval(` is not here: the eval branch's lookahead excludes `(`, so it never
# fired on `eval(` -- on 3.0.12 either.)
assert_block_noexec "python3 - <<'E'
x = hash(p)
print('$G')
E" "hash in a qualifying body still triggers"
assert_block_noexec "node - <<'E'
function foo() { return 1; }
console.log('$G');
E" "function NAME in a qualifying node body still triggers"
assert_block_noexec "python3 - <<'E'
alias = 1
print('$G')
E" "alias in a qualifying body still triggers"
assert_block_noexec "python3 - <<'E'
s = 'BASH_CMDS[x]'
print('$G')
E" "BASH_CMDS[ in a qualifying body still triggers"
assert_block_noexec "python3 - <<'E'
$NM_BODY
E
echo done" "a line after the terminator"
assert_block_noexec "python3 - <<'E'
$NM_BODY
E
E" "the FIRST line equal to D ends the body; a second D line is trailing text"

echo "=== #1052: classes found in review keep their 3.0.12 BLOCK ==="
# Each row executes the stub under the listed shells, holds NAME() text, is BLOCK on 3.0.12,
# and does NOT match §2 -- so the whole command is still read. The forms come from the
# design-review verdicts (docs/reviews/marker-heredoc-interp-design/). Each row's comment
# names the class.
# shellcheck disable=SC2016 # $@ is for the shell under test, not this one
SHF='run() { "$@"; }'
# A Python body that runs the helper through the shell, with a method call (NAME()) in it.
RUNB="import os
x = open('/etc/hosts').read()
os.system('python3 $G')"
# A Python body that only PRINTS a shell line, for the rows that hand stdout to a shell.
PRTB="x = open('/etc/hosts').read()
print('python3 $G')"
printf 'python3() { sh; }\n' > "$SCRATCH/setup.sh"
mkdir -p "$SCRATCH/fp" && printf '/bin/sh\n' > "$SCRATCH/fp/python3"

# class: allowlisted interpreter that does not read the program from stdin (inline flag)
assert_block "python3 -c 'import sys;exec(sys.stdin.read())' <<'E'
$RUNB
E" "inline-program flag reading stdin" "bash zsh"
# class: allowlisted interpreter given the program as a script argument
assert_block "python3 /dev/stdin <<'E'
$RUNB
E" "script argument /dev/stdin" "bash zsh"
# class: allowlisted interpreter in module mode, the module reading the heredoc
assert_block "python3 -m code <<'E'
$RUNB
E" "module flag reading stdin" "bash zsh"
# class: perl hands a body to another program by its #! first line. Measured: perl does this
# only for a script FILE, not for a program read from stdin, so the pin is the file form.
assert_block "cat > p.pl <<'E'
#!/bin/sh
$SHF
run python3 $G
E
perl p.pl" "perl with a #! first line hands the body to sh" "bash zsh"
# class: heredoc attached to a { ...; } group
assert_block "{ python3 -; } <<'E'
$RUNB
E" "heredoc attached to a group" "bash zsh"
# class: function definition outside the body, after a qualifying heredoc
assert_block "python3 - <<'E'
print(1)
E
$SHF; run python3 $G" "function definition after a qualifying heredoc" "bash zsh"
# class: two heredocs queued on one line, the first non-qualifying
assert_block "sh <<'A' && python3 - <<'E'
$SHF
run python3 $G
A
print(1)
E" "two heredocs on one line, the first to sh" "bash zsh"
# class: heredoc on a non-zero descriptor, read back by the stdin program (bash only)
assert_block "printf 'import os;exec(os.fdopen(10).read())' | python3 - 10<<'E'
$RUNB
E" "heredoc on descriptor 10" bash
# class: receiver output piped into a shell
assert_block "python3 - <<'E' | sh
$PRTB
E" "receiver output piped into sh" "bash zsh"
# class: same-command source of a file that redefines the receiver
assert_block ". ./setup.sh; python3 - <<'E'
$SHF
run python3 $G
E" "sourced file redefines the receiver" "bash zsh"
# class: zsh writable command table re-pointing the receiver (#1055 tracks the table itself)
assert_block "commands[python3]=/bin/sh; python3 - <<'E'
$SHF
run python3 $G
E" "zsh commands[] re-points the receiver" zsh
# class: zsh autoload of the receiver
assert_block "FPATH=./fp; autoload python3; python3 - <<'E'
$SHF
run python3 $G
E" "zsh autoload of the receiver" zsh
# class: output channel to a shell set up by exec / process substitution / a coprocess
assert_block "exec 3> >(sh); python3 - <<'E' >&3
$PRTB
E
exec 3>&-; sleep 1" "exec'd process-substitution channel" "bash zsh"
assert_block "python3 - <<'E' > >(sh)
$PRTB
E
sleep 1" "process substitution as the output target" "bash zsh"
assert_block "coproc sh; python3 - <<'E' >&p
$PRTB
E
sleep 1" "zsh coprocess channel" zsh
# class: heredoc inside backticks with an escaped delimiter
assert_block "x=\`python3 - <<\\\\E
print(1)
E
$SHF
run python3 $G
\\\\E\`" "heredoc in backticks with an escaped delimiter" "bash zsh"
# The helper named literally inside a qualifying body that runs it.
assert_block "python3 - <<'E'
import subprocess
subprocess.run(['python3', '$H'])
E" "literal helper name in a qualifying body" "bash zsh"
assert_block "python3 - <<'E'
import os
os.system('python3 $H')
E" "literal helper name in an os.system call in a qualifying body" "bash zsh"
# Copied verbatim from tests/test-marker-1013-holes.sh.
assert_block "echo \"\$(cat <<'EOF' > x.sh
sh -c 'python3 $H'
EOF
sh x.sh)\"" "a heredoc written to a file, then run"

echo "=== #1052: residual, stated (spec §3 / ADR 0006) ==="
# NOT a fix target and NOT asserted BLOCK. A stdin program with no NAME() text can write a
# script and run it; that was OK on 3.0.12 and stays OK. The program, not the shell, does
# the work, and no text-level gate can see what it builds.
got="$(verdict "node - <<'E'
const fs = require('fs');
fs.writeFileSync('r.sh', 'python3 ' + 'hooks/gate-scripts/lib/lease' + '_slo' + '?.py');
require('child_process').execSync('sh r.sh');
E")"
if [[ "$got" == "OK|" ]]; then ok "residual: a node program that writes and runs a script"
else no "residual: a node program that writes and runs a script" "got=${got:-<empty>} -- expected OK (stated residual)"; fi

echo "=== #1052: bounded time on large inputs ==="
timed() { # <command> <label> -- classifies within 1s, to a real verdict
    local s e got
    s=$(python3 -c 'import time;print(time.monotonic())')
    got="$(verdict "$1")"
    e=$(python3 -c 'import time;print(time.monotonic())')
    if [[ "$got" != "OK|" && ( "$got" != BLOCK_* || "$got" == BLOCK_CLASSIFIER_ERROR* ) ]]; then
        no "$2" "no verdict: got=${got:-<empty>}"
    elif python3 -c "import sys;sys.exit(0 if $e - $s < 1.0 else 1)"; then ok "$2"
    else no "$2" "took $(python3 -c "print(round($e - $s, 2))")s"; fi
}
MID="$(python3 -c 'print("x = open(p).read()\n" * 640, end="")')"$'\n'"print('$G')"  # ~12 KiB, BLOCK on 3.0.12
BIG="$(python3 -c 'print("x = open(p).read()\n" * 3100, end="")')"    # ~58 KiB
WORDS="$(python3 -c 'print("a " * 29000, end="")')"                   # ~58 KiB
ONE="$(python3 -c 'print("a" * 58000, end="")')"
got="$(verdict "python3 - <<'E'${NL}${MID}${NL}E")"
if [[ "$got" == "OK|" ]]; then ok "12 KiB accepted body classifies OK"
else no "12 KiB accepted body classifies OK" "got=${got:-<empty>}"; fi
timed "python3 - <<'E'${NL}${MID}${NL}E" "12 KiB accepted body"
timed "python3 - <<'E'${NL}${BIG}${NL}E" "58 KiB accepted body"
timed "python3 -u - <<'E'${NL}${BIG}${NL}E" "58 KiB near-miss body"
timed "python3 - ${WORDS}<<'E'${NL}x${NL}E" "58 KiB introducer of short words"
timed "python3 - '${ONE}' <<'E'${NL}x${NL}E" "58 KiB introducer of one quoted word"
timed "python3 - ${WORDS}<<x${NL}x" "58 KiB introducer, failing at the delimiter"

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[[ $FAIL -eq 0 ]]
