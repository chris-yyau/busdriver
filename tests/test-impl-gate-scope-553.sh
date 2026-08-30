#!/usr/bin/env bash
# Tests for issue #553 — parameter expansion evaded the file-mod classifier AND the
# helper guard, for every runner the gate knows.
#
# One root cause, two layers. `${P}` is not `rm` and not `python3`, so:
#   * cmdword.is_file_mod resolved a command word that matched no verb and no runner,
#     and allowed `sh -c 'P=rm;${P}${IFS}-rf${IFS}src'`;
#   * marker_check._helper_invoked found no interpreter in command position, so the walk
#     never reached the operand naming a guarded helper.
# Both now fail CLOSED on an unresolved command word — a word the shell rewrites before
# it resolves what runs, covering substitution (`$`, backticks), pathname expansion,
# brace expansion and extglob. The classifier blocks outright; the helper guard — which
# is UNCONDITIONAL — blocks only when the same segment also NAMES a helper, so
# `$EDITOR notes.txt` stays runnable when no review is pending. See the comment above
# cmdword._JUDGED_NAMES for the measurement that settled the trade, and _unresolved_word
# there for why substitution and the pattern expansions are asked different questions.
#
# Each `check` drives the REAL gate against a REAL throwaway repo. The generated
# property section at the end is the one exception: it imports cmdword directly, because
# it runs several hundred compositions and a gate invocation apiece would not finish.
#
# Usage: bash tests/test-impl-gate-scope-553.sh — exit 0 if all pass.

# SC2312: decisions are read from captured stdout, not pipeline status.
# SC2016: the single-quoted cases pass LITERAL command text to the gate -- the `${P}`
# and `$EDITOR` in them are the input under test and must NOT be expanded by this script.
# SC2088: the same for `~` -- an unexpanded tilde is exactly what the gate is asked about.
# shellcheck disable=SC2312,SC2016,SC2088
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$PWD"
GATE="$REPO_ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
HELPER="hooks/gate-scripts/lib/lease_slot.py"

PASS=0; FAIL=0
ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s (%s)\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

# ONE classifier for every assertion in this file, loops included. `check` used to hold
# it inline while the property loops repeated a bare `case ... *'"block"'*`, so a
# command-specific gate crash still read as "allow" inside a loop even after `check`
# learned not to (codex, #553).
verdict() {   # <gate output> -> block | allow | gate-failed
    case "$1" in
        *'"block"'*)                       printf 'block\n' ;;
        GATE-EXIT-*|PAYLOAD-BUILD-FAILED*) printf 'gate-failed\n' ;;
        *)                                 printf 'allow\n' ;;
    esac
}

CHECK_N=0
check() {   # <name> <expected: allow|block> <actual-output>
    local name="$1" expected="$2" out="$3" got
    got="$(verdict "$out")"
    CHECK_N=$((CHECK_N + 1))
    if [[ "$got" == "$expected" ]]; then ok "$name"
    else no "$name [check #$CHECK_N]" "expected=$expected got=$got"; fi
}

# ── Two throwaway repos ──────────────────────────────────────────────────────
# ARMED holds a pending design review, so the CLASSIFIER is live there. CLEAN holds none,
# so a block there is the UNCONDITIONAL helper guard and nothing else — the only way to
# tell the two layers apart in a gate decision, and the distinction this issue turns on.
# The trap is armed BEFORE the second mktemp, not after both: installing it only once
# both succeeded leaks the first directory when the second fails (codex, #553 review).
# Both names are defined empty first so the trap can reference them either way.
ARMED=""; CLEAN=""
trap 'rm -rf ${ARMED:+"$ARMED"} ${CLEAN:+"$CLEAN"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
CLEAN="$(mktemp -d)" || CLEAN=""
if [[ -z "$ARMED" || ! -d "$ARMED" || -z "$CLEAN" || ! -d "$CLEAN" ]]; then
    echo "  FAIL  could not create the temp fixture dirs — refusing to run" >&2
    exit 1
fi

for d in "$ARMED" "$CLEAN"; do
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    mkdir -p "$d/docs/plans" "$d/.claude" "$d/src"
done
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm \
     "$ARMED/docs/plans/thing.md" >/dev/null 2>&1

decide() {   # <repo-dir> <command>  -> gate stdout, or a marker if the gate died
    local payload out rc
    payload="$(python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":sys.argv[2]}}))' "$1" "$2")" || {
        printf 'PAYLOAD-BUILD-FAILED\n'; return; }
    out="$(printf '%s\n' "$payload" | (cd "$1" && bash "$GATE") 2>/dev/null)"
    rc=$?
    # The gate's own status is kept rather than discarded: a nonzero exit with no
    # decision on stdout is a crash, and `check` must see that it is not an allow.
    if [[ "$rc" -ne 0 ]] && [[ "$out" != *'"decision"'* ]]; then
        printf 'GATE-EXIT-%s\n' "$rc"; return
    fi
    printf '%s\n' "$out"
}
armed()  { decide "$ARMED" "$1"; }
clean()  { decide "$CLEAN" "$1"; }

# Both fixtures must be in the state the rest of the suite assumes, or every assertion
# below passes vacuously and the suite certifies nothing.
case "$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/impl.py"}}' "$ARMED" "$ARMED" \
        | (cd "$ARMED" && bash "$GATE") 2>/dev/null)" in
    *'"block"'*) ok "fixture: the ARMED repo has a pending review" ;;
    *) no "fixture: the ARMED repo has a pending review" "gate allowed — fixture broken"
       printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"; exit 1 ;;
esac
check "fixture: the CLEAN repo has NO pending review" allow "$(clean "rm -rf src")"

echo "── the ticket: parameter expansion hid the VERB, for every runner ──"

# The six reproductions from the issue, all ALLOWED before this change.
for runner in "sh -c" "bash -c" "watch"; do
    check "verb behind \${P}: $runner" block \
        "$(armed "$runner 'P=rm;\${P}\${IFS}-rf\${IFS}src'")"
done

echo "── ...and hid the HELPER, in the unconditional guard ──"

# CLEAN: no review pending, so a block here is the helper guard alone.
for runner in "sh -c" "env -S" "watch"; do
    check "helper behind \${P}: $runner" block \
        "$(clean "$runner 'P=python3;\${P}\${IFS}-I\${IFS}$HELPER\${IFS}.claude\${IFS}fake\${IFS}1'")"
done

echo "── the WRAPPED regime, where the command word cannot be peeled ──"

# `sudo -u root ${P} -rf src` peels to `root`, not `${P}`, so asking the command word
# alone leaves this open. Hence the wrapped branch tests every token that could be one.
check "wrapper flag operand in front of an unresolved verb" block \
    "$(armed 'sudo -u root ${P} -rf src')"
check "bare wrapper in front of an unresolved verb" block \
    "$(armed 'env ${P} -rf src')"
# The execution-versus-mention contract, pinned on the shapes that broke it while a
# python-named wrapper OPERAND was being chased: `-c` takes code rather than a script,
# and an interpreter named as another script's argument runs nothing.
check "python -c takes CODE, not a script" allow \
    "$(clean "env python3 -c $HELPER")"
check "...and an interpreter named as another script's argument runs nothing" allow \
    "$(clean "env python3 safe.py python3 $HELPER")"
check "unresolved interpreter behind a wrapper flag operand" block \
    "$(clean "sudo -u root \${P} -I $HELPER .claude fake 1")"

echo "── property: EVERY expansion that hides the verb, across every runner ──"

# A fixed example matrix proves the reported spellings; it does not prove the RULE. The
# rule is "a command word the shell rewrites before it resolves what runs is unreadable,
# whatever rewrites it", so the spellings are crossed against the runners rather than
# listed one by one. Parameter expansion is the ticket; pathname expansion (`/b?n/r?`
# reaches /bin/rm) and brace expansion (a two-item list reaches `rm -rf src`) carry no
# `$` at all and were the two bypasses left standing when this rule was first scoped to
# `$` and a backtick -- codex raised the pathname one in review. Substitution is included
# because it is the spelling that needs no assignment anywhere in the command.
PROP_BAD=0; PROP_CASES=""
prop() {   # <expected: allow|block> <command>
    local out; out="$(armed "$2")"
    case "$out" in
        *'"block"'*) [[ "$1" == "block" ]] || { PROP_BAD=$((PROP_BAD + 1))
                       PROP_CASES="${PROP_CASES} [blocked: $2]"; } ;;
        *)           [[ "$1" == "allow" ]] || { PROP_BAD=$((PROP_BAD + 1))
                       PROP_CASES="${PROP_CASES} [allowed: $2]"; } ;;
    esac
}
# Each spelling reaches `rm` at run time and equals no verb at read time.
HIDDEN_RM='${P} -rf src|$P -rf src|`echo rm` -rf src|/b?n/r? -rf src|{rm,-rf} src'
while IFS= read -r -d "|" verb || [[ -n "$verb" ]]; do
    [[ -n "$verb" ]] || continue
    prop block "$verb"
    prop block "P=rm;$verb"
    for runner in "sh -c" "bash -c" "watch"; do
        prop block "$runner 'P=rm;$verb'"
    done
    # ...and behind a wrapper preamble whose flag operand cannot be peeled.
    prop block "sudo -u root $verb"
done <<< "$HIDDEN_RM"
if [[ "$PROP_BAD" -eq 0 ]]; then
    ok "property: 5 hidden-verb spellings x 6 runner/wrapper shapes all block"
else
    no "property: hidden-verb spellings" "$PROP_BAD disagreement(s):${PROP_CASES}"
fi

# The same property for the helper guard's half: an interpreter the shell rewrites is an
# interpreter this file cannot name, so a segment that also NAMES a helper must block.
HELPER_BAD=0; HELPER_CASES=""
for interp in '${P}' '$P' '`echo python3`' '/usr/bin/pytho?3'; do
    [[ "$(verdict "$(clean "$interp -I $HELPER .claude fake 1")")" == "block" ]] || {
        HELPER_BAD=$((HELPER_BAD + 1))
        HELPER_CASES="${HELPER_CASES} [not blocked: $interp]"; }
    # ...and the same unresolved interpreter naming NO helper must stay allowed, or the
    # unconditional guard would block an ordinary command in every repo forever.
    [[ "$(verdict "$(clean "$interp notes.txt")")" == "allow" ]] || {
        HELPER_BAD=$((HELPER_BAD + 1))
        HELPER_CASES="${HELPER_CASES} [not allowed bare: $interp]"; }
done
if [[ "$HELPER_BAD" -eq 0 ]]; then
    ok "property: 4 unresolved-interpreter spellings block ONLY when a helper is named"
else
    no "property: unresolved interpreter" "$HELPER_BAD disagreement(s):${HELPER_CASES}"
fi

echo "── the names a PATTERN is judged against, and the one it is not ──"

# A pathname expansion is asked whether it can REACH a name the classifier acts on, so
# the target list matters: find/sed are matched by command word, and reaching a WRAPPER
# selects the all-token regime. All ALLOWED at HEAD; pinned so the list cannot shrink.
JUDGED_BAD=0; JUDGED_CASES=""
while IFS= read -r -d "|" jcmd || [[ -n "$jcmd" ]]; do
    [[ -n "$jcmd" ]] || continue
    [[ "$(verdict "$(armed "$jcmd")")" == "block" ]] || {
        JUDGED_BAD=$((JUDGED_BAD + 1)); JUDGED_CASES="${JUDGED_CASES} [$jcmd]"; }
done <<< "su?o rm -rf src|s?do rm -rf src|watc? 'rm -rf src'|fin? . -delete|se? -i s/a/b/ f|tim? rm -rf src|functio? f { rm x; }; f"
if [[ "$JUDGED_BAD" -eq 0 ]]; then
    ok "7 globbed wrapper/find/sed/reserved/introducer spellings block (allowed at HEAD)"
else
    no "judged-name coverage" "$JUDGED_BAD allowed:${JUDGED_CASES}"
fi

# SHELL names are judged here too. They were excluded at first, because 519's matrix
# asserted a globbed shell receiver behaves like the literal one -- but a pattern yields
# as many words as it matches, so `ba*` is `bash baz` where both exist, and excluding
# them let that through (codex, #553). The matrix now asserts the globbed spelling the
# same way as `$SHELL`.
# A GLOBBED shell name is an unresolved command word like any other: a pattern yields as
# many words as it matches, so `ba*` is `bash baz` where both exist (codex, #553). Only
# the LITERAL spelling is a resolved receiver; 519's matrix was corrected to match.
check "a bracketed shell spelling is judged, not read as a shell" block \
    "$(armed "printf 'hello' | /bin/[b]ash")"
check "...while the literal shell spelling stays allowed" allow \
    "$(armed "printf 'hello' | /bin/bash")"
check "...while a real write through it still blocks" block \
    "$(armed "printf 'rm -rf src' | /bin/[b]ash")"

echo "── a pipeline RECEIVER is judged like any other command word ──"

# An earlier round of this change EXEMPTED a receiver whose command word was unresolved,
# because 519's stdin-shell matrix asserted `printf 'hello' | $SHELL` behaves like
# `| bash`. That exemption could not be made safe: `P='rm -rf src'; printf hello | ${P}`,
# `| ${P} -rf src`, `| ${P} ${O} ${T}`, `| {rm,-rf,src}`, `| r*` and `| ba*` all delete
# behind an inert producer, and each was found only after the previous was patched
# (codex, six rounds). The invariant that "receiver spelling must not change the verdict"
# is sound for spellings that RESOLVE and unsound for the ones that do not, so 519's
# matrix now asserts the unresolved three the other way and no exemption exists here.
RECV_BAD=0; RECV_CASES=""
# One command per LINE, not a `|`-delimited string: every case here contains a pipe.
while IFS= read -r rcmd; do
    [[ -n "$rcmd" ]] || continue
    [[ "$(verdict "$(armed "$rcmd")")" == "block" ]] || {
        RECV_BAD=$((RECV_BAD + 1)); RECV_CASES="${RECV_CASES} [$rcmd]"; }
done <<'RECV_EOF'
printf hello | ${P}
printf hello | ${P} -rf src
P='rm -rf src'; printf hello | ${P}
P='rm -rf src'; P=bash /usr/bin/true; printf hello | ${P}
P='rm:-rf:src'; IFS=:; printf hello | ${P}
printf hello | {rm,-rf,src}
printf hello | rm*
printf hello | *
P='rm -rf src' sh -c 'printf hello | ${P}'
RECV_EOF
if [[ "$RECV_BAD" -eq 0 ]]; then
    ok "9 unresolved receiver spellings block behind an inert producer"
else
    no "receiver spellings" "$RECV_BAD allowed:${RECV_CASES}"
fi
# ...and a RESOLVED receiver is untouched, which is what keeps the read/mention contract.
check "a named shell receiver with an inert payload stays allowed" allow \
    "$(armed "printf 'hello' | bash")"
check "...while a globbed one is judged" block \
    "$(armed "printf 'hello' | /bin/[b]ash")"
check "...while a real write through it still blocks" block \
    "$(armed "printf 'rm -rf src' | bash")"

echo "── DIFFERENTIAL: bash decides which patterns reach a verb, not this suite ──"

# The bracket scanner reimplements a slice of bash's glob grammar, and a fixed example
# matrix only ever covers the shapes someone thought of -- which is how POSIX classes,
# classes beside other members, a leading `]`, an escaped `]` and collating symbols each
# arrived one review round at a time (codex, #553). So the ORACLE here is bash itself:
# for each spelling, bash is asked whether it matches `rm`, and whenever bash says yes the
# classifier must block. No expected-value table to get wrong, and a locale or grammar
# detail the scanner mishandles shows up as a disagreement rather than as a gap.
DIFF_BAD=0; DIFF_CASES=""
while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    # Does BASH think this pattern matches the verb? `==` inside [[ ]] is a glob match.
    # Compared against the pattern's BASENAME: the classifier resolves `/bin/r[m]` to its
    # last component before judging it, so asking bash about the whole path would answer
    # "no match" and quietly drop the path-shaped cases from the assertion (codex, #553).
    # SC2053 disabled deliberately: the UNQUOTED right-hand side is the whole point --
    # `[[ x == $pat ]]` glob-matches, and quoting it would compare literal text and
    # turn the oracle into a string equality check.
    base="${pat##*/}"
    # shellcheck disable=SC2053
    if [[ "rm" == $base ]]; then want=block; else want=allow; fi
    # An allow is only asserted when the pattern reaches nothing else judged either --
    # `r*` matches no `rm` here but does reach `runuser`, and over-blocking on a wider
    # reach is correct, so only the BLOCK direction is a hard assertion.
    got="$(verdict "$(armed "$pat -rf src")")"
    if [[ "$want" == "block" && "$got" != "block" ]]; then
        DIFF_BAD=$((DIFF_BAD + 1)); DIFF_CASES="${DIFF_CASES} [$pat -> $got]"
    fi
done <<'DIFF_EOF'
r[m]
r[]m]
r[[:alpha:]]
r[[:alpha:]_]
r[[=m=]]
r[!x]
r[l-n]
[r]m
[r][m]
r?
r*
?m
/bin/r[m]
/bin/r[[:alpha:]]
DIFF_EOF
if [[ "$DIFF_BAD" -eq 0 ]]; then
    ok "differential: every spelling bash matches to the verb blocks (14 patterns)"
else
    no "differential vs bash" "$DIFF_BAD disagreement(s):${DIFF_CASES}"
fi

echo "── shapes that only LOOK skippable, and a word that can vanish ──"

# An assignment or flag is skipped as a command-word candidate because neither can be one
# -- unless it carries a substitution, which field-splits and leaves only its FIRST field
# wearing the prefix: with P='x rm -rf src', `env X=${P}` becomes `X=x rm -rf src` and env
# runs rm. And under `nullglob` a pattern matching nothing DISAPPEARS, promoting the next
# token into command position -- and the promoted suffix is CLASSIFIED, not scanned for
# verb names, because the verb can sit a layer deeper (`no-match-* sh -c "rm -rf src"`).
# Both allowed at HEAD (codex, #553).
SKIP_BAD=0; SKIP_CASES=""
while IFS= read -r scmd; do
    [[ -n "$scmd" ]] || continue
    [[ "$(verdict "$(armed "$scmd")")" == "block" ]] || {
        SKIP_BAD=$((SKIP_BAD + 1)); SKIP_CASES="${SKIP_CASES} [$scmd]"; }
done <<'SKIP_EOF'
P='x rm -rf src'; env X=${P}
P='x rm -rf src'; sudo -u${P}
SKIP_EOF
if [[ "$SKIP_BAD" -eq 0 ]]; then
    ok "2 skippable-shape spellings block"
else
    no "skippable shapes" "$SKIP_BAD allowed:${SKIP_CASES}"
fi
# ...and the ordinary shapes they must not cost.
check "a wrapper flag operand with no expansion stays a read" allow \
    "$(armed 'sudo -u root ls')"
check "a literal assignment in front of a read stays a read" allow \
    "$(armed 'env FOO=1 ls')"

echo "── TILDE expansion, the fourth way a command word names nothing ──"

# `~` becomes $HOME, so `HOME=/bin/rm; ~ -rf src` runs rm while the word names nothing
# (codex, #553). Only the directoryless spelling counts: with a `/` in it the last
# component still names the program, which is what keeps `~/bin/tool` a resolved word.
check "a bare tilde command word" block "$(armed 'A=r; HOME=/bin/${A}m; ~ -rf src')"
check "...and the ~user spelling" block "$(armed '~user -rf src')"
check "...while a tilde PATH still names its program" allow \
    "$(armed '~/bin/tool --flag')"
check "...and the same in the helper guard" block \
    "$(clean "~ -I $HELPER .claude fake 1")"
check "...which likewise keeps a tilde path a read" allow \
    "$(clean '~/bin/tool notes.txt')"

echo "── NULLGLOB promotion: closed for globs, named where it cannot be read ──"

# A pattern matching nothing DISAPPEARS under `shopt -s nullglob` and the next word
# becomes the command. Closed for `*` and `?`: the promoted remainder is CLASSIFIED, so a
# verb one layer deeper is caught and `no-match-* grep rm file` stays the read it is.
NG_BAD=0; NG_CASES=""
while IFS= read -r ngcmd; do
    [[ -n "$ngcmd" ]] || continue
    [[ "$(verdict "$(armed "$ngcmd")")" == "block" ]] || {
        NG_BAD=$((NG_BAD + 1)); NG_CASES="${NG_CASES} [$ngcmd]"; }
done <<'NG_EOF'
no-match-* rm -rf src
no-match-* sh -c "rm -rf src"
no-a-* no-b-* rm -rf src
no-match-[0-9] rm -rf src
X=1 no-match-* rm -rf src
env no-match-* rm -rf src
bash -O nullglob -c 'no-match-* rm -rf src'
NG_EOF
if [[ "$NG_BAD" -eq 0 ]]; then
    ok "7 nullglob promotions block, repeated and bracketed included"
else
    no "nullglob promotion" "$NG_BAD allowed:${NG_CASES}"
fi
check "...while a promoted READ stays a read" allow \
    "$(armed 'no-match-* grep rm file')"
# QUOTING decides whether a pattern expands at all, and tokenization has thrown it away
# by the time the rule runs -- so the rule asks the segment text. A quoted or escaped
# pattern is a literal program name whose `rm` is an ARGUMENT (codex, #553).
check "a quoted pattern is a program name, not a glob" allow \
    "$(armed "'no-match-*' rm -rf src")"
check "...as is an escaped one" allow \
    "$(armed 'no-match-\* rm -rf src')"
# ...and the WORD's own spelling decides, not the segment's: an unrelated glob later in
# the line is no evidence that the command word expands (codex, #553).
check "a quoted command word with a glob elsewhere stays a read" allow \
    "$(armed "'no-match-*' *.txt rm -rf src")"
# GENERATED, because raw-spelling versus tokenized-word alignment is where every defect
# in this rule came from: the pattern's QUOTING decides whether it expands, and its
# POSITION decides whether it is the command word. Both are crossed rather than sampled
# (codex, #553).
NGA_BAD=0; NGA_CASES=""
for _pat in 'no-match-*' 'no-match-?' 'no-match-[0-9]'; do
    # command position, plain and with an ATTACHED redirect or a REPEATED spelling --
    # the two shapes that hid the command word from the raw scan.
    for _cmd in "$_pat rm -rf src" "$_pat>/dev/null rm -rf src" \
                "$_pat rm $_pat -rf src" "X=1 $_pat rm -rf src" \
                "2>&1 $_pat rm -rf src" ">123 $_pat rm -rf src" \
                "> /dev/null $_pat rm -rf src" \
                "$_pat<<<'$_pat' rm -rf src" "$_pat >$_pat rm -rf src" \
                "$_pat \\
 rm -rf src"; do
        [[ "$(verdict "$(armed "$_cmd")")" == "block" ]] || {
            NGA_BAD=$((NGA_BAD + 1)); NGA_CASES="${NGA_CASES} [not blocked: $_cmd]"; }
    done
    # ...and the same pattern QUOTED or ESCAPED is a literal program name, whatever else
    # the line contains.
    for _cmd in "'$_pat' rm -rf src" "\"$_pat\" rm -rf src" "'$_pat' *.txt rm -rf src"; do
        [[ "$(verdict "$(armed "$_cmd")")" == "allow" ]] || {
            NGA_BAD=$((NGA_BAD + 1)); NGA_CASES="${NGA_CASES} [blocked: $_cmd]"; }
    done
    # ...and a promoted READ is still a read.
    # ...a second, QUOTED spelling of the same pattern becomes a literal command word on
    # the next turn, so the walk must track occurrences rather than reuse the first.
    _cmd="$_pat '$_pat' rm -rf src"
    [[ "$(verdict "$(armed "$_cmd")")" == "allow" ]] || {
        NGA_BAD=$((NGA_BAD + 1)); NGA_CASES="${NGA_CASES} [blocked: $_cmd]"; }
    _cmd="$_pat grep rm file"
    [[ "$(verdict "$(armed "$_cmd")")" == "allow" ]] || {
        NGA_BAD=$((NGA_BAD + 1)); NGA_CASES="${NGA_CASES} [blocked: $_cmd]"; }
done
if [[ "$NGA_BAD" -eq 0 ]]; then
    ok "generated: 3 pattern spellings x 15 quoting/position shapes agree"
else
    no "generated nullglob alignment sweep" "$NGA_BAD disagreement(s):${NGA_CASES}"
fi

# An EXTGLOB command word is unreadable: enabled it may match anything, and under
# nullglob it may vanish and promote the next word. The alternation bar tokenizes as a
# pipe, so `@(a|b)` never reaches the word-level rule -- it is judged on segment text.
# Crossed rather than listed: the construct is invisible to the token stream, so every
# way of REACHING command position (a literal prefix, a wrapper, an assignment, a
# redirect) is a separate way to miss it -- codex found three at once.
EG_BAD=0; EG_CASES=""
for _eg in '?(no-match)' '@(no-match|x)' '+(a|b)' '!(keep)' 'x@(no-match)'; do
    for _pre in "" "env " "command " "time " "X=1 " ">out " "2>&1 " ">&- " "</dev/null " \
                 "X='a b' " "> 'a b' " "env>/dev/null " "env -i " "sudo -u root " \
                 "{fd}<notes.txt " "{fd}>out " \
                 "env> /dev/null " "env >/dev/null " \
                 "</dev/null< /dev/null " "no-a-* " \
                 '&>/dev/null ' '&>>log ' 'X=${Y:-a b} '; do
        [[ "$(verdict "$(armed "${_pre}${_eg} rm -rf src")")" == "block" ]] || {
            EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [not blocked: ${_pre}${_eg}]"; }
        # ...with NO literal verb anywhere, so only the extglob rule can catch it. The
        # `rm -rf src` cases above are independently blocked by the wrapped all-token
        # scan, which masked a defect in the command-position walk (codex, #553).
        [[ "$(verdict "$(armed "${_pre}@(r)m -rf src")")" == "block" ]] || {
            EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [not blocked: ${_pre}@(r)m]"; }
    done
    # ...and the same construct as an OPERAND is not in command position.
    [[ "$(verdict "$(armed "echo ${_eg} notes.txt")")" == "allow" ]] || {
        EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [blocked as operand: $_eg]"; }
    # ...and QUOTING it does not buy an allow. The segment rule correctly reads a quoted
    # extglob as a literal name, but the token-level rule behind it sees the word with the
    # quoting already stripped and pays the over-block -- the same uniform conservatism
    # `REACHING` pins below. Fail-CLOSED, so it is asserted rather than waived.
    [[ "$(verdict "$(armed "'${_eg}' --version")")" == "block" ]] || {
        EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [allowed quoted: $_eg]"; }
done
# ESCAPING the operator makes it a literal program name that cannot vanish, and the
# raw-spelling scan is precise enough to see that -- unlike the token-level rule behind
# it, whose input has already lost the escape. Only `@(` and `+(` are asserted: escaping
# `?(` or `!(` leaves a word the token-level rule judges on other grounds, and `x@(...)`
# escapes the `x`, not the operator, so it is still an extglob.
# Bash removes a line continuation BEFORE it parses, so it can neither split a word nor
# defuse the operator it sits inside.
check "a line continuation inside an extglob operator does not defuse it" block \
    "$(armed "$(printf '@\\\n(no-match|x) rm -rf src')")"
# The helper guard is UNCONDITIONAL, so the same construct has to reach it there too --
# and tokenization takes an extglob apart, so no token and no command word carries it.
check "an extglob INTERPRETER naming a helper, no review pending" block \
    "$(clean "bash -O extglob -c '/usr/bin/@(python3|no-such) -I $HELPER .claude fake 1'")"
# ACCEPTED OVER-BLOCK, asserted rather than waived: the extglob test reads the whole
# segment, so an extglob used as DATA beside a helper reads as an invocation. Scoping it
# to command position was tried and withdrawn -- finding command position on raw text
# means stepping over every launcher shape (`time`, `busybox env`, a named `coproc`), and
# each one missed was a fail-OPEN in an UNCONDITIONAL guard.
check "an extglob used as DATA beside a helper pays the over-block" block \
    "$(clean "echo @(a|b) $HELPER")"
# Command position is found on the RAW text, so quoted whitespace, a quoted redirect
# target and a reserved word all have to be stepped over rather than split on.
# CROSSED rather than listed. The extglob test is deliberately whole-segment (see the
# over-block above), so what these prefixes pin is that NOTHING in front of the construct
# changes the verdict -- an assignment whose value holds whitespace or brackets, a
# redirect with an attached or a separated target, a reserved word, a wrapper. Each is a
# shape that has, in some earlier revision of this rule, hidden the construct or split
# the segment before it was reached (codex, #553).
HG_BAD=0; HG_CASES=""
for _pre in "" "X=1" "X='a b'" 'X=${Y:-a b}' 'X=${Y:-foo) bar}' \
            ">out" "> out" "> 'a b'" "2>&1" "0<&1" "2>&-" "{fd}<in" "&>/dev/null" \
            "if" "{" "env" "sudo -u root" "command"; do
    for _eg in "/usr/bin/@(python3|no-such)" "@(python3|x)" "x@(python3)"; do
        [[ "$(verdict "$(clean "$_pre $_eg -I $HELPER .claude fake 1")")" == "block" ]] || {
            HG_BAD=$((HG_BAD + 1)); HG_CASES="${HG_CASES} [not blocked: $_pre $_eg]"; }
    done
    # ...and a plain read with NO expansion anywhere is still only a mention, whatever
    # prefix precedes it -- the over-block above is paid for the construct, not for the
    # helper's name appearing in the line.
    # (`{fd}<` excepted: its brace is unresolved to the blanket WORD test on its own.)
    case "$_pre" in
        "{fd}"*) ;;
        *) [[ "$(verdict "$(clean "$_pre cat $HELPER")")" == "allow" ]] || {
               HG_BAD=$((HG_BAD + 1)); HG_CASES="${HG_CASES} [blocked read: $_pre]"; } ;;
    esac
done
if [[ "$HG_BAD" -eq 0 ]]; then
    ok "generated: 18 prefixes x 3 extglob interpreters, + the read control"
else
    no "generated helper-guard command-position sweep" "$HG_BAD disagreement(s):${HG_CASES}"
fi
check "...while the same extglob naming NO helper stays runnable" allow \
    "$(clean "/usr/bin/@(python3|no-such) notes.txt")"
check "...and a continuation inside that operator does not defuse it" block \
    "$(clean "$(printf '/usr/bin/@\\\n(python3|no-such) -I %s .claude fake 1' "$HELPER")")"
# A plain glob that VANISHES promotes the extglob behind it into command position, and
# a single word can carry more than one redirect -- both hide the construct from a
# word-at-a-time scan.
# The promoted remainder gets the FULL verdict, not just the direct-verb half: `find`
# writes through `-delete` and through an -exec payload, neither of which is a verb in
# command position.
check "a promoted find -delete is still a write" block \
    "$(armed 'no-match-* find . -delete')"
check "...as is a promoted find -exec payload that writes" block \
    "$(armed 'no-match-* find . -exec rm {} +')"
check "...while a promoted find that only READS stays a read" allow \
    "$(armed 'no-match-* find . -name rm')"
check "...as does one whose -exec payload only reads" allow \
    "$(armed 'no-match-* find . -exec echo rm {} +')"
# The promoted remainder gets the SAME find rule the gate already applies directly --
# reused, not rewritten. It reads `-delete` anywhere in the command, which over-blocks
# `find . -name -delete`; refining that was tried and withdrawn, because find's grammar
# also puts a live `-delete` behind a predicate's operand and every refinement that
# removed the over-block opened a MISS. The over-block is asserted, at HEAD's behaviour.
check "...and the over-block on a -delete OPERAND is HEAD's, unchanged" block \
    "$(armed 'no-match-* find . -name -delete')"
check "an extglob promoted by a vanished glob is still judged" block \
    "$(armed 'no-a-* @(no-b) rm -rf src')"
check "an extglob behind a chain of redirects is still judged" block \
    "$(armed '</dev/null< /dev/null @(no-hit) rm -rf src')"
# A parameter expansion is one WORD to the RAW word scan, which is what this ticket
# needed: `${Y:-a b}` in front of a command word must not split into two and slide that
# word out of position.
check "a parameter expansion is one word to the raw scan" block \
    "$(armed 'X=${Y:-a b} @(no-hit) rm -rf src')"
# The SEGMENT split is deliberately left as HEAD has it -- it knows nothing of `${...}`
# and splits on every operator inside one. That over-blocks literal text (`${x:-$(true);
# rm -rf src}` runs no rm, and blocks), and it misses a command word behind an expansion
# that contains an operator. Teaching it the expansion grammar was tried across five
# review rounds and withdrawn: each correction needed the next (a `)` that closes
# nothing, a nested substitution, a quoted or bare brace, a `case` pattern terminator, a
# here-doc body, a line continuation, an `esac` used as an argument), and every one of
# them traded a false block for a MISS or the reverse. #553 is a command-word ticket;
# the expansion grammar is not its to settle. Both directions are asserted so the
# boundary is visible rather than assumed.
check "...while the segment split still blocks literal text inside one" block \
    "$(armed 'echo ${x:-$(true); rm -rf src}')"
# ...and the command word behind an expansion that CONTAINS an operator is reached by a
# second, expansion-aware split whose segments are ADDED to the first set. Additive is
# the whole point: HEAD's blanket stays, and a defect in the new scanner can only fail
# to add a block, never remove one.
check "...and a command word behind an operator inside one is still reached" block \
    "$(armed 'X=${Y:-a;b} /bin/@(rm) -rf src')"
check "...as is one behind a bracket that closes nothing" block \
    "$(armed 'X=${Y:-foo) bar} /bin/@(rm) -rf src')"
check "...and one behind a nested substitution that contains a brace" block \
    "$(armed 'X=${Y:-$(echo });true} /bin/@(rm) -rf src')"
# ...and a second, GREEDY reading closes the frame at the LAST brace, which covers the
# stray-brace shapes that balancing parens does not (a `case` pattern terminator).
check "...and one behind a case pattern inside that substitution" block \
    "$(armed 'X=${Y:-$(case x in x) echo };; esac);true} /bin/@(rm) -rf src')"
# ...while a BARE paren inside an expansion nests nothing, so the frame still closes.
check "...and one behind a bare paren inside the expansion" block \
    "$(armed 'X=${Y:-foo(;bar} /bin/@(rm) -rf src')"
check "...and one where a later brace makes both simple readings wrong" block \
    "$(armed 'X=${Y:-$(case x in x) echo };; esac);true} /bin/@(rm) -rf src; echo }')"
# ...with the candidate closer applied to the OUTER frame only, and taken from the
# unquoted braces after the first `${` -- quoted ones ahead of it exhausted the cap.
check "...and one behind a NESTED expansion" block \
    "$(armed 'X=${A:-${B:-x}$(case x in x) echo };; esac);true} /bin/@(rm) -rf src')"
# ...and past the candidate cap the reading is UNRESOLVABLE, which blocks. Any finite
# cap can be stepped over by writing one more brace than it allows, so the cap is a
# fail-closed boundary rather than a best-effort one.
check "...and one past the candidate cap, which is unresolvable" block \
    "$(armed "$(python3 -c 'D=chr(36); print("X=" + D + "{Y:-" + D + "(case x in x) echo " + "} " * 70 + ";; esac);true} ls")')")"
# ...while ordinary brace GROUPS after an expansion stay well inside the cap.
check "...and fifteen brace groups after one are not a bomb" allow \
    "$(armed "$(python3 -c 'print("echo \${x}; " + "{ :; }; " * 15 + "ls")')")"
# `$${` is a PID and a literal brace to this reading too, not an expansion.
check "...and \$\${ opens no frame for the expansion readings either" allow \
    "$(armed 'X=$${Y:-a;b} /bin/@(rm) -rf src')"
check "...nor does it start the candidate scan" allow \
    "$(armed "$(python3 -c 'print("echo \$\${x}; " + "{ :; }; " * 63 + "ls")')")"
# ...while a continuation between the `$` and the `{` does not hide a real one.
# PROCESS substitution is a WORD to the raw scan, not a redirect: reading its `<` as an
# operator skipped into the body and lost the command word behind it.
check "a process substitution in an assignment is one word" block \
    "$(armed 'X=<(echo x) /bin/@(r)m -rf src')"
check "...while the same shape running a read stays a read" allow \
    "$(armed 'X=<(echo x) ls')"
check "a continuation inside the opener does not hide the expansion" block \
    "$(armed "$(printf 'X=$\\\n{Y:-a;b} /bin/@(rm) -rf src')")"
check "...and one behind eight quoted braces" block \
    "$(armed "A='}' B='}' C='}' D='}' E='}' F='}' G='}' H='}' X=\${Y:-a;b} /bin/@(rm) -rf src")"
check "...and the helper guard reads it the same way" block \
    "$(clean "printf '%s ' \${X:-python3\${IFS}-I\${IFS}$HELPER\${IFS}.claude\${IFS}fake\${IFS}1;true} | bash")"
check "...while an ordinary expansion in front of a read stays a read" allow \
    "$(armed 'X=${Y:-a b} make check')"
# What DOES reach the classifier from inside an expansion is anything the extractor sees
# as a command: a substitution runs wherever it appears.
for _inner in '$(rm -rf src)' '<(rm -rf src)' '`rm -rf src; true`'; do
    check "a substitution inside a parameter expansion blocks: $_inner" block \
        "$(armed "echo \${x:-$_inner}")"
done
check "...and a process substitution outside one is judged the same way" block \
    "$(armed 'diff <(rm -rf src) b')"
check "...while a reading one stays a read" allow \
    "$(armed 'diff <(cat a) b')"
# The raw word scan applies the same dollar-run parity as the segment split, or `$${`
# stays opaque and glues the command word to the assignment in front of it.
check "an unopened expansion does not swallow the command word" block \
    "$(armed 'X=$${x /bin/@(r|x)m -rf src')"
# `&>` takes no fd prefix, so the word in front of it is the command, not a descriptor.
check "a word in front of &> is the command, not an fd" allow \
    "$(armed '2&>/dev/null @(no-hit) rm -rf src')"
# Under a WRAPPER the unresolved test reads every non-skippable token, arguments and
# all, because a wrapper flag can take an operand and no per-flag arity table settles
# which word is the command. That is an ACCEPTED OVER-BLOCK, asserted rather than waived:
# narrowing it to command position was tried and withdrawn, since every approximation of
# the arity table left a fail-OPEN hole in an unconditional guard.
for _shape in "grep '[abc]'" "-u root grep '[abc]'" "--user=root grep '[abc]'" \
              "-- grep '[abc]'" "-n grep '[abc]'"; do
    check "wrapped scan reads arguments too: sudo $_shape" block \
        "$(clean "sudo $_shape $HELPER")"
done
check "...while an UNWRAPPED read of the same shape stays allowed" allow \
    "$(clean "grep '[abc]' $HELPER")"
# ...and the shapes the scan exists for: an unresolved word behind a wrapper flag
# operand, a wrapper's positional operand, or a redirection target.
for _pre in "sudo -u root" "flock /tmp/l" "chroot /jail" "su root" "timeout 5" \
            "flock -E 1 /tmp/l" "env -P /usr/bin" "arch -arch arm64" \
            "stdbuf --out L" "script -t /tmp/timing /tmp/ts" "> /tmp/x"; do
    check "unresolved interpreter behind '$_pre'" block \
        "$(clean "$_pre \${P} -I $HELPER .claude fake 1")"
done
# An unterminated `${` is a half-parse: it swallows every later operator into one
# segment, so it must fail closed rather than hide the verb behind it.
check "an unterminated parameter expansion fails closed" block \
    "$(armed 'X=${Y:-a rm -rf src')"
check "...and \$\${ is a PID followed by a literal brace, not an expansion" allow \
    "$(armed 'echo $${x}')"
check "...and the run's PARITY decides which it is, to the raw word scan" block \
    "$(armed 'echo $$${X:-; rm -rf src}')"
check "a flag-shaped extglob command word is not a flag" block \
    "$(armed '-@(no-match|x) rm -rf src')"
for _eg in '@(no-match)' '+(a|b)'; do
    [[ "$(verdict "$(armed "\\${_eg} --version")")" == "allow" ]] || {
        EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [blocked escaped: $_eg]"; }
    [[ "$(verdict "$(armed "\\${_eg} rm -rf src")")" == "allow" ]] || {
        EG_BAD=$((EG_BAD + 1)); EG_CASES="${EG_CASES} [blocked escaped+rm: $_eg]"; }
done
if [[ "$EG_BAD" -eq 0 ]]; then
    ok "generated: 5 extglob spellings x 23 command-position shapes, + operand/quoted"
else
    no "generated extglob command-position sweep" "$EG_BAD disagreement(s):${EG_CASES}"
fi

# PROPERTY-BASED, because the parser's failure surface is a COMPOSITION of quoting,
# escaping, redirection, and repeated words rather than any single shape -- the fixed
# matrix above cannot enumerate it. Two invariants are asserted over randomly generated
# compositions: a command word that CANNOT vanish (quoted, escaped, or literal) never
# turns the line into a write, and one that CAN vanish in front of `rm` always does.
if PROP_OUT="$(GATE_LIB="${REPO_ROOT}/hooks/gate-scripts/lib" python3 - <<'PY'
import itertools, os, random, sys
sys.path.insert(0, os.environ["GATE_LIB"])
import cmdword

SQ, DQ, BS = chr(39), chr(34), chr(92)
random.seed(553)

VANISH = ["no-match-*", "no-match-?", "no-match-[0-9]"]
LITERAL = [SQ + "no-match-*" + SQ, DQ + "no-match-*" + DQ,
           BS + "n" + "o-match-*", "ls", "./run.sh"]
# Quoting does NOT loosen the judged-name rule: `*` can expand to `rm` however it is
# spelled, because shlex has removed the quoting by the time the word is judged. This is
# the conservative direction, and it is asserted so the uniformity cannot regress.
REACHING = ["*", SQ + "*" + SQ, DQ + "*" + DQ, BS + "*", SQ + "${P}" + SQ]
PREFIX = ["", "X=1 ", ">out ", "2>&1 ", "</dev/null ", ">123 "]
SUFFIX = ["", " >/dev/null", " 2>&1", " <<<" + SQ + "no-match-*" + SQ]

bad = []
for cw, pre, suf in itertools.product(VANISH, PREFIX, SUFFIX):
    line = pre + cw + " rm -rf src" + suf
    if not cmdword.is_file_mod(line):
        bad.append("MISS " + repr(line))
for cw, pre, suf in itertools.product(LITERAL, PREFIX, SUFFIX):
    line = pre + cw + " --version" + suf
    if cmdword.is_file_mod(line):
        bad.append("FALSE " + repr(line))
for cw, pre in itertools.product(REACHING, PREFIX):
    line = pre + cw + " --version"
    if not cmdword.is_file_mod(line):
        bad.append("REACHING-MISS " + repr(line))
# COMPOSITIONS of everything that can precede command position. Each prefix is one of
# the four things the parser steps over -- an assignment, a redirect, a wrapper with its
# flags, a glob that vanishes -- and they are stacked in random order, because every
# defect in this walk was one layer losing the state another had established.
PREFIXES = ["X=1", "X=" + SQ + "a b" + SQ, ">out", "> out", "2>&1",
            "&>/dev/null", "&>>log", "X=${Y:-a b}",
            "env", "env -i", "sudo -u root", "command", "time",
            "no-a-*", "no-b-?", "env>/dev/null"]
EXTGLOBS = ["@(no-b)", "?(no-b)", "+(a|b)", "!(keep)", "x@(no-b)"]
for _ in range(300):
    pre = " ".join(random.sample(PREFIXES, random.randint(0, 4)))
    eg = random.choice(EXTGLOBS)
    line = (pre + " " + eg + " rm -rf src").strip()
    if not cmdword.is_file_mod(line):
        bad.append("COMPOSE-MISS " + repr(line))
    # ...and the same prefixes in front of a plain READ stay a read. `echo` is the
    # command word there, so nothing after it is ever promoted into command position.
    line = (pre + " echo " + eg + " notes.txt").strip()
    _wrapped = any(w.startswith(("env", "sudo", "command", "time"))
                   for w in pre.split())
    if pre and not _wrapped and cmdword.is_file_mod(line):
        bad.append("COMPOSE-FALSE " + repr(line))
# PROMOTION MUST NOT CHANGE THE VERDICT. The remainder a vanished glob promotes is
# classified by the same rules as a command written directly, so every find spelling has
# to agree with itself across the two forms -- that equivalence is the whole contract of
# the walk, and it is what a fixed example pair cannot pin.
FIND_TAILS = ["-delete", "-name rm", "-fprint out", "-fls out", "-print",
              "-maxdepth 0 -exec echo -fprint {} +",
              "-exec rm {} +", "-exec echo rm {} +", "-exec sudo rm {} ;",
              "-name -delete", "-exec echo -delete {} ;", "-maxdepth 2 -delete"]
for tail in FIND_TAILS:
    direct = "find . " + tail
    for pat in VANISH:
        promoted = pat + " " + direct
        if cmdword.is_file_mod(direct) != cmdword.is_file_mod(promoted):
            bad.append("PROMOTION-DIFFERS " + repr(promoted))
# ...and randomly composed lines must still yield a decision rather than an exception.
frag = VANISH + LITERAL + ["rm", "-rf", "src", "grep", "|", "&&", ";", "(", ")", "{", "}"]
for _ in range(400):
    line = " ".join(random.choice(frag) for _ in range(random.randint(2, 7)))
    try:
        cmdword.is_file_mod(line)
    except Exception as exc:                                   # noqa: BLE001
        bad.append("CRASH " + repr(line) + " " + type(exc).__name__)

print(len(bad))
for b in bad[:5]:
    print(b)
PY
)"; then
    PROP_BAD="$(printf '%s' "$PROP_OUT" | head -1)"
    if [[ "$PROP_BAD" == "0" ]]; then
        ok "property: command-position compositions agree over 700+ generated lines"
    else
        no "property-based composition sweep" "$(printf '%s' "$PROP_OUT" | tail -n +2)"
    fi
else
    no "property-based composition sweep" "generator failed to run"
fi


# ...and NOT closed for a word carrying a PARENTHESIS. Deciding what an extglob word
# promotes needs adjacency and quoting that tokenization has discarded, and every
# formulation that tried FALSE-BLOCKED one of the reads below (codex, #553, across twenty
# rounds). BRACKETS are closed -- `no-match-[0-9]` is an ordinary pattern, and the shape
# that made them look dangerous (`[ -f x ] rm`, where `[` is a literal test command) never
# reaches the rule, since the command-word walk returns nothing for a test opener. A
# pattern behind a wrapper FLAG stays a residual: it needs the per-flag arity table.
#
# Each command below was blocked by one of the withdrawn formulations, and each must stay
# a read; that is what a future attempt has to keep. (The three over-blocks the surviving
# rule does pay are pinned separately, just below.)
check "a test command with a verb operand stays a read" allow \
    "$(armed '[ -f x ] rm -rf src')"
# ...and the cost this rule DOES pay, pinned so it is visible rather than discovered:
# `_effective_command_word` steps over flags and reserved words, so a program named like
# one -- `-n`, a quoted `'if'`, a `/bin/if` path -- lets the walk resolve past it to the
# pattern behind, and the verb after that blocks. Over-block on a contrived program name,
# against a real promotion; the same direction this module takes everywhere.
check "a flag-named program pays an over-block" block \
    "$(armed '-n no-match-* rm -rf src')"
check "...as does a quoted keyword" block \
    "$(armed "'if' no-match-* rm -rf src")"
check "...and a keyword-named path" block \
    "$(armed '/bin/if no-match-* rm -rf src')"
# An extglob command word is judged UNREADABLE outright, so the promoted payload is
# never consulted -- the same fail-closed answer `_unresolved_word` gives a brace.
check "an extglob command word blocks whatever it promotes" block \
    "$(armed '@(no-match) echo rm -rf src')"
check "an extglob operand of a read stays a read" allow \
    "$(armed 'echo x@(a|r)m notes.txt')"
check "a case pattern with an extglob alternative stays a read" allow \
    "$(armed 'case $x in @(a|b)) ls;; esac')"
check "a command with quoted parenthesis arguments stays a read" allow \
    "$(armed "x@ '(' a ')' rm -rf src")"
check "a process substitution operand stays a read" allow \
    "$(armed 'diff <(cat notes.md) <(cat notes.md)')"
check "...while a verb INSIDE one is still a verb" block \
    "$(armed 'diff <(rm -rf src) notes.md')"

echo "── control: the UNDIRECTED spellings must still block ──"

check "literal rm behind sh -c" block "$(armed "sh -c 'rm -rf src'")"
check "literal helper behind watch" block \
    "$(clean "watch 'python3 -I $HELPER .claude fake 1'")"

echo "── already closed at HEAD — pinned so a refactor cannot reopen them ──"

# The issue's comment reports both as open residuals. They are not: `${IFS}` is restored
# to whitespace before the walk, and the padded `watch` shape is caught by the top-level
# scan. Measured, then pinned so a refactor cannot reopen them.
check "helper name glued to its args by \${IFS}" block \
    "$(clean "python3 -I $HELPER\${IFS}.claude\${IFS}fake\${IFS}1")"
check "watch payload behind a value-taking option" block \
    "$(clean "watch --shotsdir logs ' python3' -I $HELPER .claude 20 30 3600")"

echo "── the ACCEPTED over-block, and the reads it must not cost ──"

# Failing closed on an unresolved command word has a price, and the price is pinned here
# rather than described in prose. Measured differentially against HEAD over 8,514
# real shell-history commands (2026-08-29): 209 flips, 191 of them not commands at all
# (continued argument strings, bullet lists and prose a history file recorded as
# separate lines), 18 genuine -- 0.21%. Recoverable through the skip lease; the
# alternative -- a verb the gate cannot read -- is not.
check "an editor named by a variable, while a review is pending" block \
    "$(armed '$EDITOR notes.txt')"
check "...and the braced spelling" block "$(armed '${EDITOR} notes.txt')"

# A SUBSTITUTION anywhere in the command word costs the whole word, including the part
# after a slash that looks like a program name. Basenaming first was unsound three ways:
# the slash can sit inside the construct, or the expansion can field-split before the
# suffix attaches. Pinned so the precision is not quietly reintroduced.
check "a variable directory costs the program name after it" block \
    "$(armed '"$HOME/bin/tool" --flag')"
check "...and so does a braced one" block \
    "$(armed './${dir}/script.sh')"
check "a field-splitting expansion with a path suffix" block \
    "$(armed "P='rm -rf src'; \${P}/victim")"
# A glob in a DIRECTORY component costs the word too, for the same reason: `/tmp/*/bash`
# can be `/tmp/a/bash /tmp/b/bash`, where the first runs the second (codex, #553). Only
# when the directory part is clean does the last component name the program -- which is
# what keeps `/b?n/r?` resolving to `r?` and judged against the verbs.
check "a glob directory in front of a named script is judged" block \
    "$(armed './*/script.sh')"
check "...while a clean directory leaves the globbed name readable" block \
    "$(armed '/b?n/r? -rf src')"
check "a variable as plain DATA in a read-only command" allow "$(armed 'echo ${P}')"

# The helper guard is UNCONDITIONAL, so an unresolved command word alone must never be
# enough there: it blocks only when the segment also NAMES a helper. Without this the
# guard would block `$EDITOR notes.txt` in every repo, in every session, forever.
check "unresolved command word naming NO helper, no review pending" allow \
    "$(clean '$EDITOR notes.txt')"
# The helper NAME may itself be a variable, and that stays out of scope -- the ADR 0006
# computed-name residual the guard already documents, allowed at HEAD and here. Two wider
# readings were tried and withdrawn: searching the WHOLE command couples unrelated
# segments (the pair below), and resolving the command's own assignments needs shell
# semantics this file does not model -- which value is live, per-target `+=`, the
# parameter-expansion grammar, and telling `H=v` from `printf '%s' H=v` (codex, #553,
# five rounds). What this rule closes is the COMMAND WORD.
check "a plain read beside an unresolved command word stays allowed" allow \
    "$(clean "cat $HELPER; \$EDITOR notes.txt")"
check "unresolved command word NAMING a helper, no review pending" block \
    "$(clean "\${EDITOR} $HELPER")"

# The read/mention contract survives on the resolved side: naming a helper is still a
# read when the command word says what runs.
check "reading a helper with a named program" allow "$(clean "cat $HELPER")"

# A WRAPPER NAME sitting inside expansion TEXT costs the segment. This block is NEW on
# this branch — HEAD allows it — so it is recorded as an accepted cost, not as parity.
#
# The mechanism is the tokenizer, not the rule: shlex splits `X=${Y:-a env b}` into
# `X=${Y:-a`, `env`, `b}`, the first is an assignment, so `env` becomes the apparent
# command word and engages the WRAPPED regime. That regime scans every token, and the
# expansion's own fragments carry `${` and `}` — unresolved. The extglob spelling below
# is incidental; the plain one blocks for the same reason.
#
# Narrowing it means deriving `wrapped` from the raw pieces inside _runs_mod_verb, which
# is shared with the find `-exec` payload path where no segment text corresponds. That is
# the same precision trade this file has already refused eight times, and every previous
# attempt bought a false block back with a MISS. Widening a conservative scan on text the
# shell may yet turn into a real wrapper is the safe direction; narrowing it is not.
#
# The cost is narrow: it needs the expansion in an ASSIGNMENT PREFIX *and* a wrapper name
# as a whitespace-separated word inside it. Both companions below stay allowed.
check "a wrapper name inside expansion text costs the segment" block \
    "$(armed 'X=${Y:-a env b} ls src')"
check "...the extglob spelling is the same block, not a second one" block \
    "$(armed 'X=${Y:-a env b} ls /bin/@(r)m -rf src')"
check "...an expansion with no wrapper name in it stays allowed" allow \
    "$(armed 'X=${Y:-a b} ls src')"
check "...and so does the same expansion away from command position" allow \
    "$(armed 'ls ${Y:-a env b} src')"

# ORDER INDEPENDENCE of the expansion-aware readings. A `;` inside `${...}` is literal,
# so `X=${Y:-a;b} bash` is one assignment and a shell reading stdin — which the ordinary
# split cannot see, because it splits at that semicolon. The extra reading restores it,
# and _piped_shell_producers then pairs the receiver with the producer BESIDE it.
#
# Deduplicating individual segments broke that adjacency: two pipelines whose receivers
# spell the same collapsed to one entry sitting beside the FIRST producer, so the verdict
# depended on whether the dangerous half came first. Readings are now deduplicated whole.
check "a shell receiver hidden by a semicolon inside an expansion" block \
    "$(armed "printf 'rm -rf src' | X=\${Y:-a;b} bash")"
check "...still blocks when an INERT pipeline is written first" block \
    "$(armed "printf hello | X=\${Y:-a;b} bash; printf 'rm -rf src' | X=\${Y:-a;b} bash")"
check "...and when the dangerous one is" block \
    "$(armed "printf 'rm -rf src' | X=\${Y:-a;b} bash; printf hello | X=\${Y:-a;b} bash")"

# A bare grouping paren inside a command substitution does not close its frame early.
# _raw_pieces stacks the closer, so the extglob after it is still judged in command
# position rather than being hidden behind a stray `)` (codex, #553, round 32 — reported
# as a bypass, verified as a block).
check "a grouped substitution does not hide the extglob behind it" block \
    "$(armed "X=\$( ( : ) ) /bin/@(r)m -rf src")"

# The helper guard carries the same reading machinery, so it carries the same order
# dependence until the twin is fixed too. An inert pipeline written FIRST, with a
# receiver spelled exactly like the dangerous one, used to collapse the two entries and
# leave the guard's receiver beside the harmless producer (codex, #553).
check "the helper guard is order-independent across identical receivers" block \
    "$(clean "printf hello | X=\${Y:-a;b} bash; printf '%s ' python3\${IFS}-I\${IFS}$HELPER\${IFS}.claude\${IFS}fake\${IFS}1 | X=\${Y:-a;b} bash")"

# ...and adjacency must not be bought by MULTIPLYING the segments. Emitting every
# reading's segments into one list made a 520-character read produce 2,144 pairs, which
# exhausted the fail-closed scan budget in the classifier and the token budget in the
# guard — so a harmless command blocked in a CLEAN repo, which is where the guard is
# unconditional and an over-block is permanent. Readings are kept whole for the
# adjacency-sensitive transport scan and unioned for the per-segment scan (codex, #553).
_many="X=\${Y:-;} ;"
for _i in $(seq 1 63); do _many="$_many echo };"; done
_many="$_many echo"
check "a candidate closer per brace does not exhaust the budget" allow "$(armed "$_many")"
check "...and does not exhaust the helper guard's either" allow "$(clean "$_many")"

# ...and the same with a PIPELINE in it, which is the shape that pays twice: every reading
# re-walks that pipeline's stages, so the stage decision — and the budget charge for it —
# is made once per distinct stage rather than once per reading. Both layers block a real
# piped payload (asserted above); neither may block this one.
_pipe="printf hello | echo"
for _i in $(seq 1 60); do _pipe="$_pipe w$_i"; done
check "a pipeline beside many candidate closers stays a read" allow \
    "$(armed "$_many $_pipe")"
check "...and stays unscanned-free in the helper guard" allow \
    "$(clean "$_many $_pipe")"
unset _many _pipe _i

# A `${` inside a COMMENT opens nothing, and taking it as the frame opener nested the real
# expansion under a phantom one — so prefixing a comment turned a blocked command into an
# allowed one, in both layers. Comments are blanked (length preserved, since the candidate
# closers are indices) before the readings are built (codex, #553).
check "a braced opener inside a comment does not hide the one after it" block \
    "$(armed "$(printf ': # ${\nX=${Y:-a;b} /bin/@(rm) -rf src')")"
check "...and the helper guard reads it the same way" block \
    "$(clean "$(printf ': # ${\nprintf %%s\\40 ${X:-python3${IFS}-I${IFS}'"$HELPER"'${IFS}.claude${IFS}fake${IFS}1;true} | bash')")"

# An ARITHMETIC expansion's inner parens do not close the opaque region early — reported as
# a bypass, verified as a block (codex, #553, round 35).
check "arithmetic parens do not expose the extglob behind them" block \
    "$(armed "X=\$(( (1) + 2 )) /bin/@(r)m -rf src")"
# The RESIDUAL of that blanking, pinned as HEAD PARITY rather than left in prose — these
# are what origin/main misses too. A comment can still carry a phantom opener when it is
# written after the first real `${`, or opened after a `)`. Each was closed in a review
# round and each closure opened the next spelling: counting `)` as word position made
# `$(true)#` blank the REAL expansion and drop the reading, which REMOVES a block, and
# that this pass may never do. So it answers only the part it can answer safely.
check "PARITY: a comment opened after a paren still hides one" allow \
    "$(armed "$(printf '(true)# ${\nX=${Y:-a;b} /bin/@(rm) -rf src')")"
check "PARITY: a comment after the first opener still hides one" allow \
    "$(armed "$(printf 'X=${A:-ok} : # ${\nY=${B:-a;b} /bin/rm -rf src')")"
check "...while a substitution's ) leaves an ordinary read a read" allow \
    "$(armed 'echo $(true)#x')"
# A `#` INSIDE an expansion is literal text to bash, so the blanking stops at the first
# real opener. Blanking past it deleted the command word behind the expansion outright.
check "a hash inside the expansion does not blank the command behind it" block \
    "$(armed 'X=${Y:-a;b #x} /bin/rm -rf src')"

# A LEADING pattern that can vanish under nullglob is refused on the command word itself,
# before any promotion walk has to decide what it promotes — reported as a routing gap in
# the promoted verdict, verified as a block for every verb class (codex, #553, round 36).
# origin/main allows the first three.
for _v in 'sed -i s/a/b/ src/file' 'rm -rf src' 'find . -delete'; do
    check "a vanishing pattern in front of: $_v" block "$(armed "no-match-* $_v")"
done
check "...and inside a find -exec payload" block \
    "$(armed 'find . -exec no-match-* sed -i s/a/b/ f ;')"
unset _v

# ── THE INTERPRETER DECOY ──
# A python-shaped word can PRECEDE the real interpreter, and choosing between them is not
# decidable from the text: `env python3 python3 <helper>` is either a decoy in front of an
# interpreter or an interpreter running a script NAMED `python3`, and the two spell the
# same. The SHAPE is what decides — a word `env` would read as an assignment is not the
# interpreter — and the rules that tried to decide it another way each traded a false block
# for a miss: skipping by env-name adjacency (an option breaks it, and the region walk is
# quadratic), advancing to the first non-flag operand (promotes a `-c` PROGRAM), a `.py`
# test (calls `python3.py` a script), an interpreter-shaped name test (loses
# `python-local`), and an additive re-ask of the skipped word (blocks every script behind a
# decoy). Ten rounds; the four spellings below are closed here and open at origin/main.
check "an assignment-shaped decoy in front of the interpreter blocks" block \
    "$(clean "env python3=decoy python3 -I $HELPER .claude fake 1")"
check "...with an option breaking the adjacency" block \
    "$(clean "env -i python3=decoy python3 -I $HELPER .claude fake 1")"
check "...with a second assignment between them" block \
    "$(clean "env python3=decoy X=1 python3 -I $HELPER .claude fake 1")"
check "...and for a dash-suffixed interpreter name" block \
    "$(clean "env python3=decoy python-local -I $HELPER .claude fake 1")"

# The MENTION half of the same undecidable pair, which every candidate-choosing rule broke.
check "an interpreter running a script named python3 stays a mention" allow \
    "$(clean "env python3 python3 $HELPER")"
check "...as does a python-prefixed SCRIPT with an argument" allow \
    "$(clean "env python3 python_tool.py $HELPER")"
check "...extensionless too" allow "$(clean "env python3 python_tool $HELPER")"
check "...and a -c program is not read as an interpreter" allow \
    "$(clean "env python3 -c python_code=1 $HELPER")"
check "...and a script behind a decoy keeps its argument an argument" allow \
    "$(clean "env python3=decoy python3 safe.py $HELPER")"

# What the shape rule COSTS, pinned rather than described: a wrapper that does NOT read
# assignments can run a PATH entry literally named `python3=shim`. origin/main blocks this
# and this branch does not — the one trade in the family. Closing it means knowing which
# wrappers interpret `NAME=value`, which is the per-flag arity table this suite's subject
# refuses to carry, and every attempt above reopened one of the mention cases.
check "RESIDUAL: a literal assignment-shaped program name behind timeout" allow \
    "$(clean "timeout 5 python3=shim -I $HELPER .claude fake 1")"

# ...and the grid generated rather than enumerated, because the spellings that got through
# during review were combinations nobody had written out — a path-qualified
# assignment-shaped name (`./python3=real`), a free-threaded `t` suffix, an option between
# the decoy and the interpreter. Run IN PROCESS like the sweeps above: 110 gate subprocesses
# would add about a minute to a suite CI caps at 180 seconds.
#
# The block arm is SPLIT by what the wrapper does with `NAME=value`. `env` reads it as an
# assignment, so the decoy really is one and the interpreter behind it really runs — those
# are correct blocks, and open at origin/main. `timeout`, `sudo` and `nice` do NOT, so they
# execute a program literally named `python3=decoy` and the helper is only an argument:
# those block too, and that is the ACCEPTED OVER-BLOCK the shape rule costs, the same trade
# as the RESIDUAL above but pointing the safe way. Asserting them together would have
# claimed the second group was correct.
if DECOY_OUT="$(GATE_LIB="${REPO_ROOT}/hooks/gate-scripts/lib" HELPER="$HELPER" python3 - <<'PY'
import itertools, os, sys
sys.path.insert(0, os.environ["GATE_LIB"])
import marker_check

H = os.environ["HELPER"]
blocked = lambda c: marker_check._helper_invoked(c) not in (None, "OK")

ENV_WRAP = ["", "env ", "env -i "]
OTHER_WRAP = ["timeout 5 ", "sudo ", "nice -n 5 "]
DECOY = ["python3=decoy ", "python3=decoy X=1 "]
INTERP = ["python3", "python3.12", "python3.13t", "pythonw", "/usr/bin/python3",
          "./python3=real", "python-local"]
SCRIPT = ["python_tool.py", "python_tool", "python3.py", "safe.py"]

bad = []
# 1. behind an env-like wrapper the decoy is an assignment: the interpreter behind it runs.
for w, d, i in itertools.product(ENV_WRAP, DECOY, INTERP):
    c = w + d + i + " -I " + H + " .claude fake 1"
    if not blocked(c):
        bad.append("DECOY-MISS " + repr(c))
# 2. behind a wrapper that does NOT read assignments the decoy is the program, so the
#    helper is an argument. These block anyway -- the accepted over-block, pinned so a
#    later change cannot quietly turn it into a MISS instead.
for w, d, i in itertools.product(OTHER_WRAP, DECOY, INTERP):
    c = w + d + i + " -I " + H + " .claude fake 1"
    if not blocked(c):
        bad.append("OVERBLOCK-LOST " + repr(c))
# 3. the mention control: a SCRIPT in interpreter position keeps its argument an argument.
for w, d, s in itertools.product(ENV_WRAP + OTHER_WRAP, DECOY, SCRIPT):
    c = w + d + "python3 " + s + " " + H
    if blocked(c):
        bad.append("MENTION-BLOCKED " + repr(c))
# SENTINEL-DELIMITED: the module under test writes its own diagnostics to stdout, so
# a bare capture reads one of those as a finding. Only the text after the marker
# is ours.
print("DECOY-RESULT:" + ("|".join(bad[:8]) if bad else "clean"))
PY
)"; then
    DECOY_OUT="${DECOY_OUT##*DECOY-RESULT:}"
    if [[ "$DECOY_OUT" == clean ]]; then
        ok "generated: 84 decoy spellings block, 96 script spellings stay mentions"
    else
        no "generated decoy grid" "$DECOY_OUT"
    fi
else
    no "generated decoy grid" "harness failed to run"
fi
unset DECOY_OUT

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
