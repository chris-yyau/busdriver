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
assert_mod ": \"\$(ca\\${NL}se x in x) bash -c 'rm -rf src';; esac)\"" "case split by a line continuation"
assert_mod ": \"\$(f() { case x in x) rm -rf src;; esac; }; f)\"" "a case in a function body"
assert_mod ": \"\$(case x in x) : \${y#)};; esac; rm -rf src)\"" "a # and ) inside \${ }"
assert_mod ": \"\$(echo \$(case x in x) :;; esac); rm -rf src)\"" "a case in a nested \$( )"
# A redirect is the one write the verb-only fallback cannot see, so a body that ran on to a `)`
# past the quote -- unparseable -- hid it. Checked by the write itself: nothing is deleted.
RW=": \"\$(case x in x) printf changed > src/impl.py;; esac)\" # )"
mkdir -p "$SCRATCH/src" && : > "$SCRATCH/src/impl.py"
(cd "$SCRATCH" && bash -c "$RW" >/dev/null 2>&1) || true
got="$(file_mod "$RW")"
if [[ ! -s "$SCRATCH/src/impl.py" ]]; then no "a redirect, a ) after the quote" "fixture does not write under bash"
elif [[ "$got" == "True" ]]; then ok "a redirect, a ) after the quote"
else no "a redirect, a ) after the quote" "got=$got — a real write read as no file-mod"; fi
assert_no_mod "echo \"\$(case x in x) echo hi;; esac)\"" "a print"
assert_no_mod ": \"\$(case x in x) echo ')' esac;; esac)\"" "a quoted ) and esac as words"
assert_no_mod ": \"\$(case x in x) ls src;; esac)\"" "a read"
assert_no_mod ": \"\$(case x in x) # it's${NL}echo hi;; esac)\"" "a comment in a print"
assert_no_mod ": \"\$(case x in y|case) :;; x) echo hi;; esac)\"" "case as a pattern word in a print"
assert_no_mod "echo \"\$(echo a case b)\"" "case as an argument"
assert_no_mod ": \"\$(case x in x) cat <<E${NL})${NL}E${NL};; esac)\"" "a heredoc holding a ) in a print"
# Accepted over-block: a `case` the body only quotes still triggers the over-read, which runs to
# a later `)` -- here an arithmetic one -- and reads the text between as code. Pinned so that
# narrowing the trigger is a visible change, not a silent one.
OB=": \"\$(grep -n 'case \"a\"' f.js)\"; sed -n \"\$((n+25))p\" f.js"
got="$(file_mod "$OB")"
if [[ "$got" == "True" ]]; then ok "over-block pinned: a quoted case word"
else no "over-block pinned: a quoted case word" "got=$got — trigger narrowed? make this an assert_no_mod row"; fi

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

echo "=== #1119: a case pattern's ) does not close an enclosing subshell ==="
# A piped program read as no file mod: the arm's ) cancelled the subshell's (, the ; before
# sh then reset the pipeline, and sh was never seen as fed. Measured False on 18637b37.
assert_mod "printf 'rm -rf src' | ( case x in a) :;; esac; sh )" "a 1-arm case before sh"
assert_mod "printf 'rm -rf src' | ( case x in a) :;; b) :;; esac; bash -s )" "a 2-arm case before bash -s"
assert_mod "printf 'rm -rf src' | ( case x in a) case y in b) :;; esac;; esac; sh )" "a nested case"
assert_mod "printf 'rm -rf src' | ( case x in a) :; esac; sh )" "a last arm with no ;;"
assert_mod "echo case; printf 'rm -rf src' | ( case x in a) :;; esac; sh )" "a stray case word before it"
assert_no_mod "printf 'rm -rf src' | ( case x in a) :;; esac; cat )" "the same subshell feeding cat"
assert_no_mod "case x in a) ( cd . && ls );; esac; git status | head -1" "a subshell in an arm, then a read"
assert_no_mod "echo case; (printf 'rm -rf src' | cat); printf hi | bash" "a stray case word does not join two pipelines"
assert_no_mod "(echo case a in b; printf 'rm -rf src' | cat); printf hi | bash" "an argument case/in keeps its group's )"
assert_no_mod "(echo case x in a); printf 'rm -rf src' | cat; printf '' | bash" "nor joins the pipelines after it (codex)"
assert_mod "printf 'rm -rf src' | ( { case x in a) :;; esac; }; sh )" "case after { still opens a frame"
assert_mod "printf 'rm -rf src' | ( ! case x in a) :;; esac; sh )" "case after ! still opens a frame"
assert_no_mod "echo case case; (printf 'rm -rf src' | cat); printf hi | bash" "nor do two of them"
assert_mod "printf 'rm -rf src' | ( case \$(echo x) in x) :;; esac; sh )" "a subject the splitter cuts, then in"
assert_mod "printf 'rm -rf src' | ( time -p case x in a) :;; esac; sh )" "a header behind time -p"
assert_mod "printf 'rm -rf src' | ( coproc NM case x in a) :;; esac; wait; sh )" "a header behind coproc NAME"
assert_mod "printf 'rm -rf src' | ( case x
in x) :;; esac; sh )" "a newline before in"
# A pattern's own parens nest, and a pattern spelled esac ends nothing (Kody, PR #1130).
assert_mod "printf 'rm -rf src' | ( case x in \$((1+1))) :;; esac; sh )" "an arithmetic pattern"
assert_mod "printf 'rm -rf src' | ( case x in a|esac|b) :;; esac; sh )" "a pattern spelled esac"
assert_no_mod "(case x in a|esac|b) :;; esac); printf 'rm -rf src' | cat; printf '' | bash" "nor joins the pipelines after it"
assert_mod "printf 'rm -rf src' | ( function f { case x in a) :;; esac; }; sh )" "a header opening a function body"
# `coproc case case in` stays read as `coproc NAME case` (#1133), so this fail-open stays as
# it was before; reading it unnamed over-blocked arguments and array literals. Pinned.
KO="printf 'rm -rf src' | ( coproc case case in a) :;; esac; wait; sh )"
got="$(file_mod "$KO")"
if [[ "$got" == "False" ]]; then ok "known open: an unnamed coproc whose subject is case"
else no "known open: an unnamed coproc whose subject is case" "got=$got — closed? make this an assert_mod row"; fi
assert_no_mod "(echo \$(echo hi) coproc case case in a); printf 'rm -rf src' | cat; printf '' | bash" "coproc case case as arguments opens no frame"
assert_no_mod "( case x in
a) : ;;
# note
esac ); printf 'rm -rf src' | cat; printf '' | bash" "a comment line before esac still lets it end the case"
assert_no_mod "( case x in # note
esac ); printf 'rm -rf src' | cat; printf '' | bash" "a comment after in reads no pattern either"
assert_mod "printf 'rm -rf src' | ( case x in # note
esac; sh )" "a comment after in keeps the subshell open"
assert_no_mod "(case x # in prose
in
esac); printf 'rm -rf src' | cat; printf hi | bash" "an in inside a header comment opens no pattern list"
assert_mod "printf 'rm -rf src' | ( case x # in note
in a) :;; esac; sh )" "a header comment keeps the subshell open"
assert_mod "printf 'rm -rf src' | ( case \"a #b\" in a) :;; esac; sh )" "a # inside a quoted subject is no comment"
assert_mod "printf 'rm -rf src' | ( case \"a\\\" #b\" in x) :;; esac; sh )" "nor after an escaped quote inside it"
assert_mod "printf 'rm -rf src' | ( case \$'a\\' #b' in x) :;; esac; sh )" "nor inside an ANSI-C string holding an escaped quote"

# Generated: every subject x header comment x pattern spelling bash accepts keeps the
# subshell open (litmus, PR #1130 -- hand-picked rows kept missing a combination). A shape
# bash rejects is skipped; `bash -n` only parses it.
# Each pattern spelling carries its own lead, so `in(a` -- an opener glued to `in` -- is one.
# shellcheck disable=SC2016  # the $ in these words is shell text under test, not expanded
_SUBJS=(x '"x in y"' '"a #b"' 'a\ #b' '"$(echo a) #c"')
_HCOMS=('' ' # in note
')
# shellcheck disable=SC2016
_PATS=(' a' ' (a' '(a' ' a|esac|b' ' $((1))')
_ENDS=(';;' ';&')
_n=0
for _s in "${_SUBJS[@]}"; do for _h in "${_HCOMS[@]}"; do for _p in "${_PATS[@]}"; do
for _e in "${_ENDS[@]}"; do
    _c="case $_s$_h in$_p) :$_e(b) :;; esac"
    bash -n <<<"$_c" 2>/dev/null || continue
    _n=$((_n + 1))
    assert_mod "printf 'rm -rf src' | ( $_c; sh )" "generated: ${_c//$'\n'/ NL }"
done; done; done; done
# A typo in the template would make bash reject every shape and skip them all silently.
# Bash 3.2 rejects `;&` and so parses fewer (45 on macOS): ask the bash that parsed them.
_bv="$(bash -c 'echo "${BASH_VERSINFO[0]}"')"
if (( _n == 100 || (${_bv:-0} < 4 && _n > 0) )); then ok "generated: every shape this bash accepts parsed ($_n)"
else no "generated: every shape this bash accepts parsed" "only $_n parsed"; fi
assert_no_mod "echo case; x=(function); echo hi" "a bare function word does not crash the walk"

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
