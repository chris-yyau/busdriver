#!/usr/bin/env bash
# Regression tests for #776 — a `|` between `case` PATTERNS is not a pipe.
#
# History: the POSIX numeric-validation idiom
#   X=abc; case "$X" in ''|*[!0-9]*) echo a ;; *) echo b ;; esac
# was refused with "Cannot call lease_slot.py directly" although it names no helper.
# _split_with_ops cuts on every unquoted `|`, so _piped_shell_producers read the pattern
# alternation as a pipeline feeding the stage `*[!0-9]*`, whose unresolved command word
# looked like a shell receiver, and the probe then read `*[!0-9]*` as targeting the helper.
# _case_pattern_pairs now recognises the pattern `|` and pattern words, but only on text
# the normalizer did not rewrite beyond newlines (design:
# docs/plans/2026-10-21-marker-case-heredoc.md).
#
# Two sides are pinned, and BOTH are needed:
#   A. the idiom (and its ordinary spellings) is allowed
#   B. every shape that RUNS a piped program keeps blocking — including the fictitious
#      `case` frames each review round built out of heredoc text and normalizer rewrites
# Every B row was measured BLOCK on 367d33cd before the change. Fixture text is inert
# classifier input: nothing here executes a helper.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
LIB="hooks/gate-scripts/lib"
P="'python3 $LIB/lease_slot.py'"
CR=$'\r'
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision, so pending-review state cannot
# decide the outcome. Same payload shape as test-marker-glob-specificity.sh's verdict().
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a case pattern is not a pipeline stage"
    fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    # The producer probe's own reason, not any BLOCK_*: an unrelated rule refusing the same
    # command would otherwise keep a regressed guard green (every row measured this reason).
    if [[ "$got" == "BLOCK_MARKER_SCRIPT|"* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — expected the helper guard's BLOCK_MARKER_SCRIPT"
    fi
}

IDIOM="case \"\$X\" in ''|*[!0-9]*) n=0;; *) n=1;; esac"

echo "== A: the idiom and its ordinary spellings are allowed"
assert_ok "X=abc; case \"\$X\" in ''|*[!0-9]*) echo \"a\" ;; *) echo \"b\" ;; esac" "#776 minimal repro"
assert_ok "cat > /tmp/c.md <<'EOF'
case \"\$X\" in ''|*[!0-9]*) n=0;; *) ;; esac
EOF" "the idiom as text in a heredoc body"
assert_ok "case \"\$X\" in ''|*[!0-9]*) n=0;& *) n=1;;& a|b) n=2;; esac" ";& and ;;& arms"
assert_ok "case \"\$X\" in (''|*[!0-9]*) n=0;; *) n=1;; esac" "leading ( before the pattern list"
assert_ok "case \"\$X\" in '' | *[!0-9]* ) n=0 ;; * ) n=1 ;; esac" "spaced pattern style"
assert_ok "case y in y) $IDIOM;; esac" "nested inside an outer arm"
assert_ok "if true; then $IDIOM; fi" "after if ... then"
assert_ok "if false; then :; elif true; then $IDIOM; fi" "after elif"
assert_ok "N=3
case \"\$N\" in ''|*[!0-9]*) N=0;; *) :;; esac
echo \"\$N\"" "a multi-line script whose case sits on one line"
assert_ok "case \$1 in ''|*[!0-9]*) a;; *) b;; esac; case \"\${N}\" in ''|*[!0-9]*) a;; *) b;; esac" \
    "plain parameter subjects \$1 and \${N}"
assert_ok "HUMAN_ADMIN_COUNT=\"\${R%% *}\"; SOLE=\"\${R#* }\"; case \"\$HUMAN_ADMIN_COUNT\" in ''|*[!0-9]*) HUMAN_ADMIN_COUNT=0;; *) :;; esac" \
    "pr-grind completion.md approver-gap composer line"
assert_ok "printf $P | case x in a) :;; *) :;; esac" "a fed * pattern under a literal subject is not a receiver"

echo "== A': residuals that still block (the model abandons; today's reading)"
assert_block "case \"\$X\" in
  ''|*[!0-9]*)
    n=0
    ;;
  *)
    n=1
    ;;
esac" "patterns on their own lines"
assert_block "X=abc; echo \\
  hi; case \"\$X\" in ''|*[!0-9]*) echo a ;; *) echo b ;; esac" "a line continuation anywhere in the command"

echo "== B: shapes that run a piped program keep blocking"
# #1078: a subshell's case arms must not let a later `)` read as an unmodelled case-arm
# closer. A rejected fix for #1078 kept an unopened `)` as `)`; here the arm `a)` pops the
# subshell's `(`, `b)` then finds the stack empty, and this fed shell classified OK.
assert_block ": \$(true); printf $P | ( case x in a) :;; b) :;; esac; sh )" \
    "a fed subshell whose case arms precede the shell, beside a \$(...)"
assert_block "case x in a|b) printf $P | sh;; esac" "a body pipe beside an alternation"
assert_block "printf $P | case x in a|b) sh;; esac" "a real pipe INTO a case whose arm is a shell"
assert_block "case x in a|b) echo;; esac; printf $P | sh" "a pipeline after a closed case"
assert_block "case x in a|b) echo;;& *) echo;; esac; printf $P | sh" "a pipeline after a ;;& arm"
assert_block "case x in a|b) case y in c|d) echo;; esac;; esac; printf $P | sh" "a pipeline after a nested esac"
assert_block "printf $P | case x in a|\$(sh)) ;; esac" "a \$(sh) pattern fed by a pipe"
assert_block "P='\$(sh)'; printf $P | case x in a) :;; \${P@P}) :;; esac" "a \${P@P} pattern after ;;"
assert_block "printf $P | case \"\$(sh)\" in a|b) ;; esac" "a quoted \$() case subject"
assert_block "printf $P | case \$(sh) in a|b) ;; esac" "an unquoted \$() case subject"
assert_block "case x in \"a b\"|c) echo;; esac; printf $P | sh" "a quoted multi-word pattern beside a real pipe"
assert_block "case x in a|b) printf $P | /bin/[b]ash;; *) true;; esac" "a glob receiver in an arm"
assert_block "X=1; case \"\$X\" in ''|*[!0-9]*) python3 $LIB/lease_slot.py ;; *) echo b ;; esac" "the helper run directly in an arm"
assert_block "printf $P | case \"\$X\" in a) :;; *) :;; esac" "a fed * pattern under a parameter subject (nameref-capable)"
assert_block "printf $P | case \"\$X\" in ''|*[!0-9]*) :;; esac" "the idiom fed by a pipe under a parameter subject"
assert_block "case x in x) printf $P | case \${P@P} in a) :;; *) :;; esac;; esac" "an ineligible nested header abandons the model"
# A pattern spelled like a compound keyword still moves the caller's keyword depth, so
# releasing it let the arm's `;` drop the fed state before `bash` (litmus round 1).
assert_block "printf $P | case x in a|esac|*) :; bash;; esac" "an esac-spelled pattern before a fed shell"
assert_block "printf $P | case \"\$x\" in a|esac|*) :; bash;; esac" "the same under a parameter subject"
assert_block "printf $P | case x in a|done|*) :; bash;; esac" "a done-spelled pattern"
assert_block "printf $P | case x in a|}|*) :; bash;; esac" "a }-spelled pattern"

echo "== B: fictitious frames built from heredoc text"
assert_block "printf $P | (cat <<';'
case x in
;
bash)" "a ; delimiter keeps a body-text frame open"
assert_block "printf $P | (cat <<''
case x in

bash)" "an empty delimiter"
assert_block "printf $P | (cat <<'('
case x in
(
bash)" "a ( delimiter"
assert_block "printf $P | (cat <<';'
case x in
;
cat <<'E'
esac
E
bash)" "a frame closed by a second heredoc body"
assert_block "printf $P | (cat <<'E'
case x in a|
E
bash)" "an alternation left open in a body"
assert_block "cat <<'E'
case x in a)
E
printf $P | case \${P@P} in a) :;; *) :;; esac" "a body-text frame then an ineligible header"
assert_block "printf $P | (cat <<'\\'
case x in a) :;; \\
\\
bash)" "a backslash delimiter"
assert_block "printf $P | (cat <<-'\\'
case x in a) :;; \\
	\\
bash)" "the same under <<- tab stripping"

echo "== B: one row per _norm_for_scan rewrite that could manufacture case syntax"
assert_block "printf $P | (cat - ${CR}case x in a|bash)" "a bare CR"
assert_block "printf $P | (cat - ${CR}
case x in a|bash)" "a CRLF line end"
assert_block "printf $P | case\$IFS""x\$IFS""in a|bash" "\$IFS between the words"
assert_block "printf $P | case\${IFS}x\${IFS}in a|bash" "\${IFS} between the words"
assert_block "printf $P | case \$'x' in a|bash" "ANSI-C quoting"
assert_block "printf $P | (cat # ; x
case x in a|bash)" "a comment holding a separator"
assert_block "printf $P | (for f
in a; do :; done; case x in a|bash)" "a for header split across lines"
assert_block "printf $P | case \${P@P} in a) :;; *) :;; esac" "a \${P@P} subject"
assert_block "printf $P | case \${a[i]} in a) :;; *) :;; esac" "an arithmetic-subscript subject"

echo "== only bash blanks separate words"
for sep in $'\v' $'\f' $'\r'; do
    assert_block "printf $P | case${sep}x${sep}in a|bash" "$(printf %q "$sep") is not a word separator"
done
assert_ok "X=abc; case"$'\t'"\"\$X\""$'\t'"in ''|*[!0-9]*) echo a;; *) echo b;; esac" "a tab still separates the header"

echo "== #1078: a case arm's ) survives the \$(...) flatten"
# The flatten pass rewrites each substitution and pairs every ) with its opener. A case
# arm's ) has no opener, and it used to become \` ; \`, which hid the end of the pattern list
# from the release above, so the idiom beside any \$(...) read \`*[!0-9]*\` as a piped stage.
# It is now kept as ), which still separates. Measured BLOCK before the fix:
assert_ok "R=\$(printf '%s' 3)
N=\"\${R%% *}\"; case \"\$N\" in ''|*[!0-9]*) N=0;; *) :;; esac" "the idiom beside a \$(...) substitution"
assert_ok "if [ \"\$S\" = 1 ]; then
  case \"\$H\" in ''|*[!0-9]*) H=0 ;; esac
G=\$(bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-detect.sh\" 2>/dev/null || echo '{\"d\":\"s\"}')
fi" "the issue's approver-gap repro"
assert_ok "x=\$(true); printf $P | case x in a|bash) :;; esac" \
    "a pipe into a case whose bash is a pattern, as without the \$(...)"
# ...and every shape that runs something keeps blocking with a \$(...) beside it.
assert_block "x=\$(true); case y in a) printf $P | sh ;; esac" "a body pipe into sh"
assert_block "x=\$(true); case \"\$X\" in ''|*[!0-9]*) printf $P | sh ;; esac" "a body pipe in the idiom's arm"
assert_block "x=\$(true); case \"\$X\" in ''|*[!0-9]*) python3 $LIB/lease_slot.py ;; esac" "the helper run in the arm"
assert_block "x=\$(true); case \"\$X\" in ''|*[!0-9]*) python3 $LIB/lease_slo?.py ;; esac" "a helper glob run in the arm"
assert_block "x=\$(true); case \"\$X\" in ''|*[!0-9]*) X=0 ;; esac; printf $P | sh" "a pipeline after the case"
assert_block "x=\$(true); printf $P | case x in a|b) sh;; esac" "a pipe into a case whose arm is a shell"
assert_block "x=\$(true); printf $P | case \"\$X\" in ''|*[!0-9]*) :;; esac" "the idiom fed by a pipe"
assert_block "x=\$(true); printf $P | \"case\" x in a|bash \")\"" "a header that exists only after quote removal"
assert_block "x=\$(case y in a) echo 1 ;; esac); printf $P | sh" "a case inside the \$(...), then a pipeline"
assert_block "x=\$(printf $P | case y in a|bash) bash;; esac)" "a fed case inside the \$(...)"
assert_block "x=\$(true); ( case y in a) :;; esac; printf $P ) | sh" "a subshell holding the case, piped to sh"
assert_block "x=\$(true); { case y in a) :;; esac; printf $P; } | sh" "a group holding the case, piped to sh"
assert_block "x=\$(grep -o 'p(c [^)]*)' f | head -1); printf $P | sh" "a quoted ) in the \$(...), then a pipeline"
# A subshell's ( is popped by the first arm's ), so every later ) arrives unpaired. Kept
# as ), they closed the subshell early in the producers' depth count and `sh` was no
# longer fed (litmus backstop on the first draft of this fix).
assert_block ": \$(true); printf $P | ( case x in a) :;; b) :;; esac; sh )" "a pipe into a subshell holding a 2-arm case, then sh"
assert_block ": \$(true); printf $P | ( case x in a) :;; b) :;; c) :;; esac; sh )" "the same with 3 arms"
assert_block ": \$(true); printf $P | ( case x in a) :;; b) :;; esac; bash -s )" "the same feeding bash -s"

echo "== #1119: a case pattern's ) does not close an enclosing subshell"
# The same shapes with no \$(...) at all. The arm's ) has no (, and counted as a closer it
# cancelled the subshell's (, so the ; before sh read as a top-level separator and sh was
# never fed. Every row below was measured OK on 18637b37. The { } twin always blocked.
G="'python3 $LIB/lease_slo?.py'"
assert_block "printf $P | ( case x in a) :;; esac; sh )" "the issue's 1-arm shape"
assert_block "printf $P | ( case x in a) :;; b) :;; esac; sh )" "the issue's 2-arm shape"
assert_block "printf $P | ( case x in a) :;; b) :;; esac; bash -s )" "the issue's bash -s shape"
assert_block "printf $G | ( case x in a) :;; esac; sh )" "a glob payload"
assert_block "printf $P | ( case \$x in a) :;; esac; sh )" "an expanded subject"
assert_block "printf $P | ( case x in
a) :;;
esac; sh )" "a multi-line case"
assert_block "printf $P | ( case x in a) :;& b) :;;& esac; sh )" "fall-through terminators"
assert_block "printf $P | ( case x in a) case y in b) :;; esac;; esac; sh )" "a nested case"
assert_block "printf $P | ( case x in a) :; esac; sh )" "a last arm with no ;;"
assert_block "printf $P | ( case x in a);; esac; sh ) # c" "a trailing comment (the #776 release is off)"
assert_block "echo case; printf $P | ( case x in a) :;; esac; sh )" "a stray case word before it"
assert_block "printf $P | ( case x in a) (true) ;; esac; sh )" "a subshell inside the arm"
assert_block "printf $P | ( ( case x in a) :;; esac ); sh )" "the case in its own inner subshell"
assert_block "printf $P | ( case x in (a) :;; esac; sh )" "a (pattern) arm, which always blocked"
# A real arm may open a subshell right after its ), so `)(` is not proof of the flatten
# pass's unpaired closer; that one is spelled `)()(`, which bash rejects everywhere.
assert_block "printf $P | ( case x in a)(:);; esac; sh )" "an arm that opens a subshell at once"
assert_block ": \$(true); printf $P | ( case x in a)(:);; esac; sh )" "the same beside a \$(...)"
assert_block ": \$(true); printf $P | ( case x in a) :;; esac; sh )" "the 1-arm shape beside a \$(...)"
assert_block "printf $P | ( case \"\$(dirname \"\$D\")\" in /*) :;; esac; sh )" "a quoted subject that blank-splits"
assert_block "printf $P | ( case \$(echo x) in x) :;; esac; sh )" "a subject the splitter cuts, then in"
# `case` stays reserved behind these prefixes, so each still opens a frame.
for _pre in "time -p " "time -p -- " "coproc NM " "! time -p " "! coproc NM "; do
    assert_block "printf $P | ( ${_pre}case x in a) :;; esac; sh )" "a header behind '${_pre% }'"
done
assert_ok "printf 'hi' | ( case x in a) :;; esac; cat )" "the same subshell feeding cat"
assert_ok "( case x in a) echo hi;; esac ) | cat" "a case subshell piped to cat"
# `case` is reserved only at command position, so an argument `case ... in` opens no frame
# and cannot discount its own group's ) (Kody, PR #1130).
assert_ok "(echo case a in b; printf $G | cat); printf hi | sh" "an argument case/in keeps its group's )"
# ...while every word that keeps command position still opens one.
for _w in "{" "if true; then" "for i in 1; do" "!" "time" "coproc"; do
    _end=""; case "$_w" in "{") _end="; }" ;; "if true; then") _end="; fi" ;; "for i in 1; do") _end="; done" ;; esac
    assert_block "printf $G | ( $_w case x in a) :;; esac$_end; sh )" "case after \`$_w\` still opens a frame"
done

echo "== pinned residual: any non-header word \`case\` abandons the model (today's reading)"
assert_block "echo case; X=abc; case \"\$X\" in ''|*[!0-9]*) echo a;; *) echo b;; esac" "a stray case word keeps the over-block"

echo "== #639 is out of scope and unchanged"
assert_block "cat > /tmp/c.md <<'EOF'
The library's audit_append.py builds its records from fixed fields.
EOF" "quoted heredoc prose with an odd apostrophe still blocks"

echo
echo "════ marker-case-776: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
