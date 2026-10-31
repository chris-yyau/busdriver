#!/usr/bin/env bash
# Fail-open regressions in cmdword (the design gate), #1063. Two substitution bodies read as
# no file mod while bash ran a write in them:
#   1. a `case` arm inside a quoted `$( … )` -- the arm's `)` closed the body early;
#   2. a backtick body read raw -- bash drops a layer of backslashes before parsing it, so a
#      program whose backslashes were doubled for the transport hid its write.
#
# Every file-mod row is first EXECUTED under bash in a scratch tree and must really delete
# src/ -- a fixture that does not execute proves nothing about the guard.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/gate-scripts/lib"
PASS=0
FAIL=0
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
command -v timeout >/dev/null 2>&1 && TO=(timeout 60)
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

file_mod() { # <command> -> True / False from cmdword.is_file_mod, or ERROR
    ${TO[@]+"${TO[@]}"} python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1])
from cmdword import is_file_mod
print(is_file_mod(sys.argv[2]))' "$LIB" "$1" 2>/dev/null || printf 'ERROR'
}

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

deletes_src() { # <command> -> 0 when bash, run in the scratch tree, removes src/; 2 on setup failure
    mkdir -p "$SCRATCH/src" && : > "$SCRATCH/src/impl.py" || return 2
    (cd "$SCRATCH" && ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ ! -e "$SCRATCH/src" ]]
}

assert_mod() { # <command> <label>
    local got rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] || { no "$2" "fixture does not delete src/ under bash"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "True" ]]; then ok "$2"; else no "$2" "got=$got — a real deletion read as no file-mod"; fi
}

assert_no_mod() { # <command> <label>
    local got rc=0
    deletes_src "$1" || rc=$?
    [[ $rc -eq 2 ]] && { no "$2" "could not create the src/ fixture"; return; }
    [[ $rc -eq 0 ]] && { no "$2" "fixture deletes src/ -- it is not a read"; return; }
    got="$(file_mod "$1")"
    if [[ "$got" == "False" ]]; then ok "$2"; else no "$2" "got=$got — a read was refused"; fi
}

sq() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
dbl() { printf '%s' "${1//\\/\\\\}"; }   # a backtick transport's doubled backslashes

echo "=== a case arm inside a quoted \$( ) ==="
assert_mod ": \"\$(case x in x) bash -c 'rm -rf src' ;; esac)\"" "the issue's shape"
assert_mod ": \"\$(case y in x) :;; y) rm -rf src;; esac)\"" "the second arm"
assert_mod ": \"\$(case x in x) :;; esac; rm -rf src)\"" "a command after its esac"
assert_mod ": \"\$(case x in x) rm -rf src
esac)\"" "an arm closed by esac alone"
assert_mod ": \"\$(case x in x) :;& y) rm -rf src;; esac)\"" "a ;& fall-through"
assert_mod "x=\"\$(case x in x|y) :;; *) :;; esac; rm -rf src)\"" "alternatives and *"
assert_no_mod "echo \"\$(case x in x) echo hi;; esac)\"" "a print"
assert_no_mod ": \"\$(case x in x) echo ')' esac;; esac)\"" "a quoted ) and esac as words"
assert_no_mod ": \"\$(case x in x) ls src;; esac)\"" "a read"

echo "=== a backtick body, its backslashes doubled for the transport ==="
P1="echo \$'\\\\'; rm -rf src; echo \\\$'x'"     # echo $'\\'; rm -rf src; echo \$'x'
P2="echo \\\$\"x\"; rm -rf src; echo '\\\$'"     # echo \$"x"; rm -rf src; echo '\$'
D2="\"$(printf '%s' "$P2" | sed 's/[\\$"]/\\&/g')\""   # P2 double-quoted
Q1=$(dbl "$(sq "$P1")")
assert_mod ": \`bash -c $Q1\`" "an sh-quoted program"
assert_mod ": \"\`bash -c $Q1\`\"" "the same in double quotes"
assert_mod ": \`sh -c $Q1\`" "the same under sh -c"
assert_mod ": \`bash -c $(dbl "$D2")\`" "a double-quoted program"
assert_no_mod ": \`bash -c $(dbl "$(sq "${P1/rm -rf/ls}")")\`" "a read"
assert_no_mod "echo \"\`echo \\\\\\\\n\`\"" "an escaped backslash"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
