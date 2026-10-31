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
NL=$'\n'
assert_mod ": \"\$(case x in x) # '${NL}rm -rf src;; esac)\"" "a comment holding a quote"
assert_mod ": \"\$(case x in x) # )${NL}rm -rf src;; esac)\"" "a comment holding a )"
assert_mod ": \"\$(case x in x) :;; \\${NL}esac; rm -rf src)\"" "a line continuation before esac"
assert_mod ": \"\$(case x in y|case) :;; x) rm -rf src;; esac)\"" "case as a pattern word"
assert_mod ": \"\$(case x in x) cat <<E${NL})${NL}E${NL}rm -rf src;; esac)\"" "a heredoc holding a )"
assert_no_mod "echo \"\$(case x in x) echo hi;; esac)\"" "a print"
assert_no_mod ": \"\$(case x in x) echo ')' esac;; esac)\"" "a quoted ) and esac as words"
assert_no_mod ": \"\$(case x in x) ls src;; esac)\"" "a read"
assert_no_mod ": \"\$(case x in x) # it's${NL}echo hi;; esac)\"" "a comment in a print"
assert_no_mod ": \"\$(case x in y|case) :;; x) echo hi;; esac)\"" "case as a pattern word in a print"
assert_no_mod "echo \"\$(echo a case b)\"" "case as an argument"
# Accepted over-block: a heredoc inside the arm is not modelled, so its `)` closes the scan
# with the case still open, and that reads as unreadable -- BLOCK. Main allowed it.
got="$(file_mod ": \"\$(case x in x) cat <<E${NL})${NL}E${NL};; esac)\"")"
if [[ "$got" == "True" ]]; then ok "a heredoc holding a ) in a print is refused (fail-closed)"
else no "the heredoc over-block" "got=$got"; fi

echo "=== every generated case-in-\$( ) shape that deletes src/ reads as a file mod ==="
gen_fail=0 gen_runs=0
for pat in 'x)' '(x)' 'x|y)' '*)' "'x')"; do
    for arm in 'rm -rf src' "bash -c 'rm -rf src'" "echo ')'; rm -rf src"; do
        for end in ';; esac' "${NL}esac" ';& esac'; do
            # shellcheck disable=SC2016  # literal shell text, not expansions
            for wrap in ': "$(%s)"' ': $(%s)' 'x="$(%s)"' 'echo "a $(%s) b"'; do
                # shellcheck disable=SC2059  # the wrapper IS the format
                c="$(printf "$wrap" "case x in $pat $arm$end")"
                deletes_src "$c" || continue
                gen_runs=$((gen_runs + 1))
                got="$(file_mod "$c")"
                [[ "$got" == "True" ]] || { gen_fail=$((gen_fail + 1)); printf '    miss: %s\n' "$c"; }
            done
        done
    done
done
if [[ $gen_fail -eq 0 && $gen_runs -gt 100 ]]; then ok "$gen_runs generated deletions all read as file mods"
else no "generated shapes" "$gen_fail of $gen_runs missed"; fi

echo "=== a backtick body, its backslashes doubled for the transport ==="
P1="echo \$'\\\\'; rm -rf src; echo \\\$'x'"     # echo $'\\'; rm -rf src; echo \$'x'
P2="echo \\\$\"x\"; rm -rf src; echo '\\\$'"     # echo \$"x"; rm -rf src; echo '\$'
D2="\"$(printf '%s' "$P2" | sed 's/[\\$"]/\\&/g')\""   # P2 double-quoted
S1=$(sq "$P1"); Q1=$(dbl "$S1")
D2Q=$(dbl "$D2")
R1=$(sq "${P1/rm -rf/ls}"); R1Q=$(dbl "$R1")
assert_mod ": \`bash -c $Q1\`" "an sh-quoted program"
assert_mod ": \"\`bash -c $Q1\`\"" "the same in double quotes"
assert_mod ": \`sh -c $Q1\`" "the same under sh -c"
assert_mod ": \`bash -c $D2Q\`" "a double-quoted program"
assert_no_mod ": \`bash -c $R1Q\`" "a read"
assert_no_mod "echo \"\`echo \\\\\\\\n\`\"" "an escaped backslash"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
