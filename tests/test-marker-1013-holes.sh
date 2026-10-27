#!/usr/bin/env bash
# Fail-open regressions for the mutating-helper guard (#1013). Each BLOCK fixture is a
# command bash really runs the helper from, while main classified it OK:
#   - a helper GLOB after `--` (end of options) -- the `--` branch compared the next word
#     to the helper names literally and never resolved the glob;
#   - a helper glob with a bare parameter spliced onto it (`<glob>$A`, `<glob>"$A"`) --
#     the glob probe blanked `${A}` but not `$A`, so the pattern kept a literal `$A`;
#   - an interpreter-with-script payload inside a DOUBLE-QUOTED `$( )` or backtick.
#
# Every BLOCK row is first EXECUTED under bash against a stub helper in a scratch tree,
# and must really run it -- a fixture that does not execute proves nothing about the
# guard. Every OK row must classify OK and must NOT run the stub, so tightening cannot
# pass by refusing reads. The helper name is assembled from fragments because the live
# hook refuses a Bash call that spells it.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
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

LIBDIR="hooks/gate-scripts/lib"
NAME="lease""_slot.py"
H="$LIBDIR/$NAME"
G="$LIBDIR/lease""_slo?.py"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$LIBDIR"
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"
chmod +x "$SCRATCH/$H"

runs_helper() { # <command> -> 0 when bash, run in the scratch tree, executes the stub
    rm -f "$SCRATCH/$H.ran"
    (cd "$SCRATCH" && env -u A -u X ${TO[@]+"${TO[@]}"} bash -c "$1" >/dev/null 2>&1) || true
    [[ -f "$SCRATCH/$H.ran" ]]
}

assert_block() { # <command> <label>
    local got
    if ! runs_helper "$1"; then
        no "$2" "fixture does not execute the helper under bash -- it proves nothing"
        return
    fi
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then
        no "$2" "got=$got — the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a real invocation was allowed"
    fi
}

assert_ok() { # <command> <label>
    local got
    if runs_helper "$1"; then
        no "$2" "control executes the helper -- it is not a read"
        return
    fi
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a read was refused"; fi
}

echo "=== #1013: helper glob after end-of-options ==="
assert_block "python3 -- $G" "glob after -- runs the helper"
assert_block "python3 -B -- $G" "glob after a flag and -- runs the helper"
assert_block "python3 -- ./$G" "dot-relative glob after -- runs the helper"

echo "=== #1013: bare parameter spliced onto a helper glob ==="
assert_block "python3 $G\$A" "unset \$A after the glob"
assert_block "python3 $G\"\$A\"" "quoted unset \"\$A\" after the glob"
assert_block "python3 $LIBDIR/lease_*\$X" "star glob with a parameter suffix"
assert_block "python3 -- $G\$A" "-- and a parameter suffix together"
assert_block "[[ -n \$(python3 -- $G\$A) ]]" "the #947 litmus shape"

echo "=== #1013: the issue's original table (already BLOCK on main; pinned) ==="
assert_block "echo \"\$(sh -c '$H')\"" "echo \"\$(sh -c '<helper>')\""
assert_block "x=\"\$(sh -c '$H')\"" "x=\"\$(sh -c '<helper>')\""
assert_block "[[ \"\$(sh -c '$H')\" ]]" "[[ \"\$(sh -c '<helper>')\" ]]"
assert_block "[ \"\$(sh -c '$H')\" ]" "[ \"\$(sh -c '<helper>')\" ]"
assert_block "[[ -n x ]] && [[ \"\$(bash -c \"$H\")\" ]]" "conditional with bash -c in quotes"

echo "=== #1013: interpreter payload inside a quoted substitution ==="
assert_block "echo \"\$(sh -c 'python3 $H')\"" "\"\$(sh -c 'python3 <helper>')\""
assert_block "echo \"a \$(sh -c 'python3 $H')\"" "prefixed text in the quotes"
assert_block "echo \"a \$(bash -c \"python3 $H\")\"" "bash -c with a nested double quote"
assert_block "echo \"a \`sh -c 'python3 $H'\`\"" "backtick form"
assert_block "x=\"a \$(sh -c 'python3 $H')\"" "assignment value"
# A `'` inside double quotes is literal and opens no inert region; read as one, it would
# skip straight past the substitution that follows it.
assert_block "echo \"it's \$(sh -c 'python3 $H') ok\"" "apostrophe in the quotes before the substitution"
assert_block "echo \"it's \$(sh -c 'python3 $H') ok\" \"'\"" "same, with the apostrophes balanced"
# A `)` paren counting misreads as the body's closer must not hide the rest of the body.
assert_block "echo \"\$(# )
sh -c 'python3 $H')\"" "a commented ) inside the body"
assert_block "echo \"\$(case x in x) sh -c 'python3 $H';; esac)\"" "a case pattern ) inside the body"
assert_block "echo \"\$(# it's
sh -c 'python3 $H')\"" "an apostrophe in a comment inside the body"
assert_block "echo \"\$(# (
sh -c 'python3 $H')\"" "an open paren in a comment inside the body"
# Paren counting finds NO closer here (the heredoc's apostrophe opens a quote that never
# closes in its reading); that must widen the scan, not drop every body.
assert_block "echo \"\$(cat <<'EOF'
it's
EOF
sh -c 'python3 $H')\"" "an apostrophe in a heredoc body inside the substitution"
assert_block "echo \"\$(cat <<'EOF'
)
EOF
sh -c 'python3 $H')\"" "a ) in a heredoc body inside the substitution"

echo "=== controls that must stay OK (reads, not runs) ==="
assert_ok "echo \"a \$(sh -c 'cat $H')\"" "quoted substitution that only reads the helper"
assert_ok "echo \"\$(case x in x) echo ok;; esac)\" \"[\"" "a case inside a quoted substitution, no helper (#877's control)"
assert_ok "x=\"\$(grep -c def $H)\"" "grep of the helper in a quoted substitution"
assert_ok "python3 -c 'print(1)' -- $G" "the glob is argv to a -c program"
assert_ok "ls -- $G\$A" "ls lists the helper"
assert_ok "python3 -m json.tool -- x.json" "-- with an unrelated operand"
# A substitution the shell never runs: after a word-start `#`, also when a line
# continuation sits between the word and the `#`.
assert_ok "echo ok # \"\$(sh -c 'python3 $H')\"" "a substitution inside a comment"
assert_ok "echo ok \\
# \"\$(sh -c 'python3 $H')\"" "a comment after a line continuation"

echo "=== heredocs inside a substitution body: read exactly as at top level ==="
# A body's heredoc is over-read as shell, as at top level and in the unquoted spelling. That
# reading is what refuses a payload WRITTEN by the heredoc and run afterwards; reading the
# body as data let these three run from inside "$( … )" while the unquoted twins refused.
assert_block "echo \"\$(cat <<'EOF' > x.sh
sh -c 'python3 $H'
EOF
sh x.sh)\"" "a heredoc written to a file, then run"
assert_block "echo \"\$(tee y.sh <<'EOF' >/dev/null
sh -c 'python3 $H'
EOF
bash y.sh)\"" "a heredoc tee'd to a file, then run"
assert_block "echo \"\$({ sh; } <<'EOF'
sh -c 'python3 $H'
EOF
)\"" "a heredoc fed to a compound command"
assert_block "echo \"\$(sh <<'EOF'
sh -c 'python3 $H'
EOF
)\"" "sh heredoc in a quoted substitution runs the body"
assert_block "echo \"\$(bash -s <<'EOF'
python3 $H
EOF
)\"" "bash -s heredoc in a quoted substitution runs the body"
assert_block "echo \"\$(sh <<'A' <<'B'
x
A
sh -c 'python3 $H'
B
)\"" "two heredocs on one line, sh runs the last"
assert_block "echo \"\$(cat <<EOF
\$(sh -c 'python3 $H')
EOF
)\"" "a substitution in an unquoted heredoc inside the body"
# The price: a heredoc that only PRINTS a helper-shaped line is refused in every spelling.
# Classification only -- nothing here executes the helper, so these are not assert_block.
HD="cat <<'EOF'
sh -c 'python3 $H'
EOF
"
for _c in "$HD" "echo \$($HD)" "echo \"\$($HD)\""; do
  _g="$(verdict "$_c")"
  if [[ "$_g" == BLOCK_MARKER_SCRIPT* ]]; then
    ok "same verdict wrapped or not :: ${_c:0:12}…"
  else
    no "same verdict wrapped or not" "got=$_g for ${_c:0:40}"
  fi
done
# `case` pattern parens, nested cases and arithmetic inside the body do not end it.
assert_block "echo \"\$(case x in (x) sh -c 'python3 $H';; esac)\"" "an opening-paren case pattern"
assert_block "echo \"\$(case x in x) case y in y) true;; esac; sh -c 'python3 $H';; esac)\"" "a nested case"
assert_block "echo \"\$( (( 1 < 2 )) && sh -c 'python3 $H')\"" "arithmetic before the payload"
assert_block "echo \"\$(if true; then case x in x) sh -c 'python3 $H';; esac; fi)\"" "a case after a reserved word"
# `$((` whose parens do not close as one `))` is not arithmetic: bash falls back to `$(` +
# a subshell and runs it.
assert_block "echo \"\$((( 1 < 2 )) && sh -c 'python3 $H')\"" "an arithmetic-looking substitution"
assert_ok "echo \"\$(( 1 + 2 ))\" \"$H\"" "real arithmetic stays arithmetic"
assert_ok "echo \"a \$(( : && printf %s '$H' && echo \\) )) b\"" "an escaped ) does not end arithmetic"
# In a pattern list only `esac` is reserved: an alternative spelled `case` opens nothing,
# and the patterns after `;;` and `;&` are patterns again.
assert_ok "echo \"$H \$(case x in x|case) true;; esac)\"" "a case alternative spelled case"
assert_block "echo \"\$(case x in y|z) :;; x) sh -c 'python3 $H';; esac)\"" "the payload after a second pattern"
assert_block "echo \"\$(case x in x) :;& (y) sh -c 'python3 $H';; esac)\"" "the payload after a fall-through"
assert_ok "echo \"$H \$(case x in z) :;; x|case) true;; esac)\"" "an alternative spelled case after ;;"
assert_block "echo \"\$(case x in (x) case y in y) :;; esac;; z) :;; esac; sh -c 'python3 $H')\"" "a nested case in a parenthesised pattern's action"
# `esac` ends a case only as a pattern list's first word: the subject and an alternative
# after `|` are words (`case esac in`, `x|esac)`).
assert_block "echo \"\$(case esac in *) sh -c 'python3 $H';; esac)\"" "a subject spelled esac"
assert_block "echo \"\$(case x in x|esac) sh -c 'python3 $H';; esac)\"" "an alternative spelled esac"
assert_block "echo \"\$(case x in y) :;; x|esac) sh -c 'python3 $H';; esac)\"" "an alternative spelled esac after ;;"
assert_block "echo \"\$(case in in in) sh -c 'python3 $H';; esac)\"" "a subject spelled in"
assert_block "echo \"\$(case \"\$(echo x)\" in x) sh -c 'python3 $H';; esac)\"" "a substitution as the subject"
assert_ok "echo \"\$(case x in x|esac) echo hi;; esac)\" \"sh -c 'python3 $H'\"" "an alternative spelled esac, payload only quoted text"
# Parens inside `\${…}` are data: `\${X:-(}` prints `(`, and `\${X:-)}` does not end the body.
assert_ok "echo \"\$(echo \${X:-(})\" \"sh -c 'python3 $H'\"" "an open paren in a parameter default"
assert_ok "echo \"\$(echo \${X:-)})\" \"sh -c 'python3 $H'\"" "a close paren in a parameter default"
assert_block "echo \"\$(echo \${X:-)}; sh -c 'python3 $H')\"" "a payload after a close paren in a parameter default"
assert_block "echo \"\$(echo \"\${X:-\")\"}\"; sh -c 'python3 $H')\"" "a quoted close paren in a quoted parameter default"
assert_block "echo \"\$(echo \${X:-\$(echo \")\")}; sh -c 'python3 $H')\"" "a substitution in a parameter default"
# `case` is reserved only at command position; as an argument it opens nothing.
assert_ok "echo \"\$(echo case)\" \"$H\"" "an argument spelled case"
assert_ok "echo \"\$(echo case.txt)\" \"$H\"" "an argument starting with case"
# In `$'it\'s'` the escaped apostrophe closes nothing.
assert_ok "echo \"\$(printf '%s' \$'it\\'s')\" \"$H\"" "an ANSI-C quote with an escaped apostrophe"
assert_block "echo \"\$(printf '%s' \$'it\\'s'; sh -c 'python3 $H')\"" "a payload after an ANSI-C quote"
# A body whose end this scan cannot find is unread, not empty: the whole command goes to
# the abandoned-scan probe.
assert_block "echo \"\$(echo \`)\`; sh -c 'python3 $H')\"" "a ) inside backticks inside the body"
# Classification only (bash rejects this one): a case whose `in` is not where this scan
# expects it leaves the body unread, and the probe still sees the helper.
_g="$(verdict "echo \"\$(case x y in z) :;; esac; sh -c 'python3 $H')\"")"
if [[ "$_g" == BLOCK* ]]; then ok "an unreadable body goes to the probe"
else no "an unreadable body goes to the probe" "got=$_g"; fi
# A line continuation is joined before the body is read: `ca\<nl>se` is `case`.
assert_block "echo \"\$(ca\\
se x in x) sh -c 'python3 $H';; esac)\"" "a case keyword split by a line continuation"
assert_ok "echo \"\$(case x i\\
n x) :;; esac)\" \"sh -c 'python3 $H'\"" "an in keyword split by a line continuation"
# In a `\${…}` PATTERN, `'` quotes even inside double quotes: `"\${X//'\"'/}"` strips a `"`.
assert_ok "echo \"\$(printf %s \"\${X//'\"'/}\")\" \"$H\"" "a quoted double quote in a quoted parameter pattern"
assert_block "echo \"\$(printf %s \"\${X//'\"'/}\"; sh -c 'python3 $H')\"" "a payload after a quoted parameter pattern"
# A local \"…\" in an unquoted pattern makes ' literal: \${X//\"'\"/} strips a '.
assert_ok "echo \${X//\"'\"/} \"\$(true)\" $H" "a double-quoted apostrophe in an unquoted parameter pattern"
assert_block "echo \${X//\"'\"/} \"\$(sh -c 'python3 $H')\"" "a payload after a double-quoted apostrophe in a pattern"
# A word after a closed substitution is an argument, not a command.
assert_ok "echo \"\$(echo \$(true) case)\" \"sh -c 'python3 $H'\"" "case as an argument after a nested substitution"
assert_block "echo \"\$(echo \$(true) case; sh -c 'python3 $H')\"" "a payload after case as an argument"
# A backtick inside a double-quoted word keeps its own quotes.
assert_ok "echo \"\$(echo \"\`printf '\"'\`\")\" \"sh -c 'python3 $H'\"" "a quote inside a backtick inside double quotes"
assert_block "echo \"\$(echo \"\`printf '\"'\`\"; sh -c 'python3 $H')\"" "a payload after a backtick inside double quotes"
# Inside `[[ … ]]` no word is a command, so `case` there is data; after `]]` it is a command again.
assert_ok "echo \"\$([[ x == x || case == case ]] && echo ok)\" \"sh -c 'python3 $H'\"" "case as a [[ ]] operand"
assert_block "echo \"\$([[ x == x || case == case ]] && sh -c 'python3 $H')\"" "a payload after a [[ ]] with a case operand"
assert_block "echo \"\$([[ x == \"]]\" ]] || case x in x) sh -c 'python3 $H';; esac)\"" "a case after a [[ ]] with a quoted ]]"
# An escaped backtick inside backticks is nesting, not the end of the outer one.
assert_block "echo \"\$(echo \`echo \\\`echo hi\\\`\`; sh -c 'python3 $H')\"" "an escaped backtick nested in backticks"
assert_ok "echo \"\$(echo \`echo \\\`echo hi\\\`\`)\" \"sh -c 'python3 $H'\"" "an escaped backtick nested in backticks, payload only quoted text"
assert_block "echo \"\$(echo \`echo \\\`sh -c 'python3 $H'\\\`\`)\"" "a payload in a nested backtick"
assert_ok "echo \"\`echo \\\`echo hi\\\`\`\" \"sh -c 'python3 $H'\"" "a top-level backtick with an escaped backtick"
# A backtick inside the body is its own substitution: its parens do not end the body.
assert_ok "echo \"$H \$(echo \`case x in x) :;; esac\`)\"" "a case inside backticks inside the body"
# Deeply nested arithmetic must stay inside the hook budget: a killed hook reads as ALLOW.
# shellcheck disable=SC2016  # the $(( are literal text for the classifier
_opens=$(printf '$(( %.0s' {1..5000}); _closes=$(printf ' ))%.0s' {1..5000})
_deep="echo \"${_opens}1${_closes}\""
_now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }   # BSD date has no %N
_t0=$(_now_ms); _g="$(verdict "$_deep")"; _t1=$(_now_ms); _ms=$(( _t1 - _t0 ))
if [[ "$_g" == "OK|" && "$_ms" -lt 3000 ]]; then ok "5000 nested arithmetic openers (${_ms}ms)"
else no "5000 nested arithmetic openers" "got=$_g in ${_ms}ms"; fi
# A substitution nested in a double-quoted word inside the body opens fresh quoting.
assert_ok "echo \"\$(echo \"\$(echo '\"')\")\" \"sh -c 'python3 $H'\"" "a lone double quote in a nested substitution"
assert_block "echo \"\$(echo \"\$(echo '\"')\"; sh -c 'python3 $H')\"" "a payload after a nested substitution"
# Only text a quote really covers is skipped: a comment closing a body leaves the next
# quoted argument an argument.
assert_ok "echo \"\$(# harmless
true)\" \"sh -c 'python3 $H'\"" "a quoted argument after a commented body is data"
# Parameters that are never empty are not blanked: `\$?` is 0 here, so the glob gets a
# trailing 0 and matches nothing.
assert_ok "python3 $G\$? 2>/dev/null; true" "a never-empty \$? after the glob"
assert_ok "python3 $G\$\$ 2>/dev/null; true" "a never-empty \$\$ after the glob"
assert_ok "python3 $G\$UID 2>/dev/null; true" "a readonly \$UID after the glob"
assert_ok "python3 $G\$PPID 2>/dev/null; true" "a readonly \$PPID after the glob"
assert_ok "python3 $G\$BASH_VERSINFO 2>/dev/null; true" "the readonly \$BASH_VERSINFO after the glob"
# After `--` a dash-led word is the SCRIPT, not an option; skipping it as a flag would
# promote the next word (here the helper, which is only argv) to the script.
assert_ok "python3 -- -x.py $G" "a dash-led script after -- takes the helper as argv"

echo "=== review round 1: readings the body scan lost ==="
# `$((1))` is a word, so a `#` glued to it comments nothing.
assert_block "echo \$((1))#\"\$(sh -c 'python3 $H')\"" "a # glued to an arithmetic word"
# A `<<` or ` #` inside `\${…}` is data: neither may hide the substitutions after it.
assert_block "echo \${X:-<<E}
echo \"\$(sh -c 'python3 $H')\"" "a << inside a parameter default"
assert_block "echo \${X:- #\$(sh -c 'python3 $H')}" "a # inside a parameter default"
assert_block "echo \"\${X:-\$(sh -c 'python3 $H')}\"" "a payload inside a quoted parameter default"
# The issue's BLOCK controls, so body re-entry cannot flip one to OK.
assert_block "[[ -n x ]] && [[ \"\$($H)\" ]]" "control: the helper run directly in a quoted substitution"
assert_block "[[ -n x ]] && [[ \$(sh -c '$H') ]]" "control: the unquoted twin"
assert_block "[[ -n x ]] && [[ \"\$(eval '$H')\" ]]" "control: eval in a quoted substitution"
assert_block "echo \"\$(sh -s x <<<'python3 $H')\"" "an explicit sh -s payload in a quoted substitution"
# Deep nesting is answered by the probe, never by RecursionError.
# shellcheck disable=SC2016  # the $( are literal text for the classifier
_dq_open=$(printf '"$(echo %.0s' {1..1000}); _dq_close=$(printf ')"%.0s' {1..1000})
_g="$(verdict "echo ${_dq_open}a${_dq_close}")"
if [[ "$_g" == "OK|" ]]; then ok "1000 nested quoted substitutions"
else no "1000 nested quoted substitutions" "got=$_g"; fi
_g="$(verdict "echo ${_dq_open}\"\$(sh -c 'python3 $H')\"${_dq_close}")"
if [[ "$_g" == BLOCK_MARKER_SCRIPT* ]]; then ok "a payload under 1000 nested quoted substitutions"
else no "a payload under 1000 nested quoted substitutions" "got=$_g"; fi
_g="$(verdict "echo ${_dq_open}\"\$(sh -c 'python3 $G')\"${_dq_close}")"
if [[ "$_g" == BLOCK_* && "$_g" != BLOCK_CLASSIFIER_ERROR* ]]; then ok "a globbed payload under 1000 nested quoted substitutions"
else no "a globbed payload under 1000 nested quoted substitutions" "got=$_g"; fi
# Many bodies must stay inside the hook budget: a killed hook reads as ALLOW.
# shellcheck disable=SC2016  # the $( are literal text for the classifier
_many="cat <(x); python3 -V; echo \"$(printf '$(true)%.0s' {1..1500})\""
_t0=$(_now_ms); _g="$(verdict "$_many")"; _t1=$(_now_ms); _ms=$(( _t1 - _t0 ))
if [[ "$_g" == "OK|" && "$_ms" -lt 2000 ]]; then ok "1500 substitution bodies (${_ms}ms)"
else no "1500 substitution bodies" "got=$_g in ${_ms}ms"; fi

echo "=== review round 2: a body's )# ambiguity stays with the whole command ==="
# A body's `)#` sends the WHOLE command to the probe: a helper bound outside the body
# runs from inside it. So `echo "$(echo $(true)#hi)" <helper>` stays blocked (#1039).
assert_block "read A <<<'python3 $H'; echo \"\$(echo \$(true)#x; \$A)\"" "a helper bound outside a body with )#"
assert_block "echo \"\$(echo \$(true)#x; sh -c 'python3 $H')\"" "its payload twin"
assert_block "echo \"\$(echo \$(true)#\$(sh -c 'python3 $H'))\"" "a payload glued after the #"

echo "=== review round 3: a local quote inside a quoted parameter expansion ==="
# Inside `"${X:-…}"` a local `"` flips the quote state; the `#` after it is still inside
# the expansion, so it comments nothing and the body after it runs.
assert_block "echo \"\${X:-\" #\$(sh -c 'python3 $H')\"}\"" "a # after a local quote in a quoted parameter default"
assert_ok "echo \"\${X:-\" #\$(echo hi)\"}\"" "its harmless twin"

# The `#` after a `((1))` command is a comment, but `_subst_bodies` reads every `))#` as
# one word: `((` also groups inside `$[ ]` and `a[ ]`, where the `#` after it is not a
# comment. Treating `((1))#` as a comment let those bodies run unread (litmus).
assert_block "echo \$[ ((1))#\`sh -c 'python3 $H'\`]" "a backtick after ((1))# inside \$[ ]"
assert_block "((1))#x <<EOF
echo \"\$(sh -c 'python3 $H')\"" "its payload, end to end"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
