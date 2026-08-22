#!/usr/bin/env bash
# Regression tests for #573 — the mutating-helper guard must not name a helper that the
# command never spells, on the evidence of a wildcard that matches every filename.
#
# History: `gh pr create` with the PR body inline was refused with "Cannot call
# lease_slot.py directly". The command contained neither `lease_slot` nor `audit_append`.
# The quote-flattening that lets this file see inside `$(...)` turns a markdown bold
# marker into a bare `**` token, `_abandoned_scan_probe` asks each glob-looking word
# whether the shell could expand it onto a helper, and `fnmatch("**")` matches
# `lease_slot.py` — as it matches everything else. Reported twice by the operator; the
# first block cost a skip-litmus token on the retry.
#
# Two sides are pinned, and BOTH are needed. Only the first would let a future change
# drop glob detection wholesale (a real bypass); only the second is the bug.
#   A. a GENERIC pattern in structureless text is not evidence — no block
#   B. a TARGETED pattern still blocks, and so does every generic glob the structured
#      walk can still reach as a command operand
# Sections C–E extend the same pair: crafted patterns must not buy a release (C), a quoted
# glob in a piped payload still blocks (D, #640), and a class whose member is a quoted
# SPACE blocks while ordinary bracketed markdown does not (E, #708).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
LIB="hooks/gate-scripts/lib"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision: this is a guard on the
# classifier's evidence, and going through the gate would let an unrelated pending-review
# state decide the outcome instead.
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

# Deliberately if/then/else rather than `cond && ok || no` (shellcheck SC2015).
assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a wildcard is not evidence that a helper was named"
    fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — the helper guard regressed to allow"
    fi
}

# The delta-debugged minimum from #573, VERBATIM. Quoted heredoc, so these are the exact
# bytes the operator typed. All five lines are load-bearing — the issue reports that
# removing any one of them stops the block, and shortened paraphrases of this prose do
# NOT reproduce (measured). Do not "tidy" it: a trimmed body turns the assertion below
# vacuous, passing against the very classifier it exists to catch.
BODY573=$(cat <<'PROSE'
A `{` or `[` inside codex's own command log poisoned the whole extraction sweep. `raw_decode` anchored on the bracket, could not resolve the region, and `_resolve` then refused every verdict decoded after it.
The issue fingers `[codex] Running command:` at byte 1622, echoing `rg -n "import \{ en \}"`. **Measured against the artifact, that line is harmless** -- the `\}` closes the `{`, the region resolves, and the sweep steps over it. A fix aimed only at `Running command:` did not rescue the reported transcript.
Delta-debugging the 129-line artifact down to one line found the real culprit: its **`Command completed:` twin**, echoing the regex character class `[;}]`. The `[` pushes `]`, the `}` mismatches, `broken_pos` is set, and every later verdict is refused. The reported error message reproduces from that line alone.
| Per-region backward `rfind` was quadratic on one long line | `_seek_line` -- a monotonic forward cursor, equivalence to `rfind` asserted at every region of every fixture |
Also unchanged: the ~1.15s baseline on 64,000 same-line regions is pre-existing (the two sibling recognizers each do their own per-region backward scan). This PR only ensures it is not made worse.
PROSE
)

echo "── A. a generic wildcard in prose is not evidence ──"
assert_ok "gh pr create --body \"\$(cat <<'EOF'
$BODY573
EOF
)\"" "#573 verbatim: PR body inline -> allowed"

# The same word reached through the OTHER abandonment path: an apostrophe makes the
# heredoc unparseable, so the whole command is probed as text.
assert_ok "cat > /tmp/x.md <<'EOF'
It isn't ** a helper ** at all.
EOF" "bare ** in an unparseable heredoc -> allowed"

assert_ok "gh pr create --body \"\$(cat <<'EOF'
Emphasis ** around ** a phrase, and a bare * on its own.
EOF
)\"" "bare * and ** in a PR body -> allowed"

echo "── B. targeted patterns, and every glob the walk can still reach ──"
# The case the glob probe was BUILT for: `?` stands FOR the character, so no substring
# test finds the name, yet the shell expands it onto the helper.
assert_block "python3 $LIB/lease_slo?.py" "targeted glob (parseable) -> BLOCK"
assert_block "cat <<'EOF'
it isn't
EOF
python3 lease_slo?.py" "targeted glob in unparseable text -> BLOCK"
assert_block "eval \"python3 lease_slo?.py\"" "targeted glob behind eval -> BLOCK"
assert_block "python3 lease_slo[t].py" "bracket-globbed helper -> BLOCK"

# Generic globs the STRUCTURED walk still reaches, because the interpreter is in command
# position and the wildcard is its operand. These are why the change is scoped to
# _abandoned_scan_probe and _glob_helper itself stays strict — if these ever flip to
# allow, the fix was applied at the wrong layer.
assert_block "cd $LIB && python3 *" "python3 * (operand) -> BLOCK"
assert_block "cd $LIB && python3 *.py" "python3 *.py (operand) -> BLOCK"
assert_block "cd $LIB && python3 **" "python3 ** (operand) -> BLOCK"
assert_block "python3 -m cProfile $LIB/*" "runner module + glob operand -> BLOCK"

# A pattern of pure `?` matches the helper by LENGTH and matches no ordinary short
# filename, so it stays blocked. Pinned deliberately: it is the safe direction, and it is
# the case a future "just drop all-wildcard patterns" simplification would open.
assert_block "cd $LIB && python3 ?????????????" "13 wildcards == len(lease_slot.py) -> BLOCK"

# The plain spellings, so a regression in the fix cannot pass this file by disabling the
# guard outright.
assert_block "python3 -I $LIB/lease_slot.py .claude 20 0 3600" "direct invocation -> BLOCK"
assert_block "python3 -m lease_slot" "module invocation -> BLOCK"
assert_block "echo \"see $LIB/audit_append.py\" > /dev/null && python3 $LIB/audit_append.py" \
    "audit_append invocation -> BLOCK"

echo "── C. crafted patterns must not buy a release ──"
# The release rule is "a run of `*` and nothing else". Anything that AIMS at the helper
# needs some character other than `*` to aim with, and any such character disqualifies it.
# These are the evasions that broke the first draft, which asked whether the pattern also
# matched an ordinary decoy filename: unioning alternatives satisfied both the decoy and
# the helper.
for evasion in \
    '[lm][ea][ai]*.py' \
    '[la]*.py' \
    'l*t.py' \
    '*slot.py' \
    'lease*' \
    '[a-z]*_*.py' \
    '?ease_slot.py'
do
    assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $evasion" "crafted: $evasion -> BLOCK"
done

# GENERATED, not hand-picked. A hand-written evasion list is exactly how the second draft
# of this fix shipped a hole: every case someone thinks of tends to contain a letter, and
# the evasion that broke it (`?????_????.??*`) contained none — it aimed with `_` and `.`
# at the offsets of the helper's own name. So derive the family mechanically from the
# helper names instead: replace every alphanumeric RUN with that many `?`, then decorate
# with `*`. Each result matches its helper and carries no letter, and every one must block.
for helper in lease_slot.py audit_append.py; do
    # python3, not sed: a `\n` in a sed REPLACEMENT is a GNU extension, so the same script
    # emits a literal `n` under BSD sed and silently generates a weaker pattern set. This
    # suite runs on both macOS (developer) and ubuntu (CI), and a test that quietly covers
    # less on one of them is worse than no test. python3 is already a hard dependency here.
    skeleton=$(python3 -c \
        'import re,sys;print(re.sub(r"[A-Za-z0-9]+", lambda m: "?"*len(m.group()), sys.argv[1]))' \
        "$helper")
    # Every decoration must still MATCH the helper, or the assertion is vacuous: a
    # trailing `*?` demands one more character than the name has, so it matches nothing
    # and `OK|` would be the correct answer rather than a bypass.
    for shaped in "$skeleton" "$skeleton*" "*$skeleton" "${skeleton%??}*"; do
        assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $shaped" "generated skeleton: $shaped -> BLOCK"
    done
done

# The ONLY pattern class that is released: a run of `*` and nothing else, which matches
# every string that exists and so distinguishes the helper from nothing. Asserted so the
# residual is visible rather than folklore. Each `?` above imposes a minimum length and is
# therefore a narrowing, which is why the `*?`-family sits in the BLOCK list rather than
# here — four successive drafts of a wider rule each shipped a bypass. If this last case
# ever needs to block, the fix is command-position gating, not a wider release rule.
for lenfloor in '?????????????*' '*?????????????' '?*' '*?*' '??*'; do
    assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $lenfloor" "length-floor wildcard: $lenfloor -> BLOCK"
done

# That last sentence came true, from the other direction. #639 recovers the segmentation
# the apostrophe used to cost, so `python3 *` now arrives as a real invocation with a glob
# OPERAND and the untargeted `_glob_helper` answers it — command-position gating, reached
# without widening the release rule. Measured on the pre-#639 classifier: the identical
# command WITHOUT the apostrophe already blocked, so this is parity, not a new refusal. The
# release rule itself is still pinned by section A, where the text really is structureless.
#
# The SPECIFIC block verdict, not any BLOCK_*. A bare prefix test also accepts
# BLOCK_CLASSIFIER_ERROR, so a crash on the #639 recovery path would satisfy every case
# below while the guard under test never ran -- test-heredoc-prose-639.sh already applies
# this stricter predicate for the same reason. Scoped to this loop only: `assert_block`
# elsewhere in this file covers verdicts this set does not enumerate. CodeRabbit in review.
assert_block_script() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_MARKER_SCRIPT\|* || "$got" == BLOCK_MARKER\|* \
          || "$got" == BLOCK_MARKER_UNPARSED\|* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — expected a marker/helper block, not this"
    fi
}

for closed in '*' '**' '***'; do
    assert_block_script "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $closed" "#639 closed: $closed behind a quoted heredoc -> BLOCK"
done

# ...and the boundary of that residual, which a third draft got wrong: taking the
# BASENAME before the purity test released `<libdir>/*`, whose discarded directory is a
# literal naming the folder both helpers live in. That is the "pruned directory" the
# residual note assumes must come from outside the token — supplied inside it. A `/` is a
# literal like any other, so a qualified glob is never released.
for qualified in "$LIB/*" "$LIB/**" "./$LIB/*" "/usr/../$LIB/*"; do
    assert_block "cat <<'EOF'
it isn't
EOF
python3 $qualified" "path-qualified wildcard: $qualified -> BLOCK"
done

echo "── D. a QUOTED targeted glob, in a payload piped to a shell (#640) ──"
# The probe asked its glob question of the RAW words, so the quote the payload is wrapped
# in stayed glued to the word: `lease_slo?.py'` is a pattern that matches the helper
# nowhere, and the piped payload measured OK| while the same payload spelled literally
# blocked. Section B's rows are all UNQUOTED, which is why they never caught it. The
# literal twins are asserted alongside each glob so a regression that disables the whole
# producer scan cannot pass this section by flipping both to allow.
for recv in 'sh' 'bash -s' 'zsh'; do
    assert_block "echo python3 lease_slot.py | $recv" "literal, unquoted -> $recv -> BLOCK"
    assert_block "echo 'python3 lease_slot.py' | $recv" "literal, quoted -> $recv -> BLOCK"
    assert_block "echo 'python3 lease_slo?.py' | $recv" "#640: quoted ? glob -> $recv -> BLOCK"
    assert_block "echo 'python3 lease_slo[t].py' | $recv" "#640: quoted [] glob -> $recv -> BLOCK"
    assert_block "printf '%s' 'python3 lease_slo?.py' | $recv" "#640: printf-quoted glob -> $recv -> BLOCK"
done
# Double quotes and a SPLIT quoted run: the shell concatenates adjacent runs, so the word
# is a pattern about the helper even though no contiguous glob is spelled anywhere.
assert_block 'echo "python3 lease_slo?.py" | sh' '#640: double-quoted glob -> BLOCK'
assert_block "echo 'python3 lease_'slo?'.py' | sh" '#640: split quoted runs -> BLOCK'

# GENERATED, not hand-picked — the same discipline section C's skeletons use, and for the
# same reason: the first draft of this fix fixed the QUOTE and left every adjacent shell
# OPERATOR as a live bypass (`lease_slo?.py;` is a pattern the helper does not match), and
# a hand-written row per spelling is how that hole survived review once already. Codex
# raised it on #640. The cross-product decorates each glob with what the shell separates
# on before it globs, in both quote styles, and every cell must block.
for quoting in single double; do
    for pat in 'lease_slo?.py' 'lease_slo[t].py' 'lease_?lot.py'; do
        for deco in '%s' '%s;' '%s ;' '%s&&true' 'true&&%s' '%s|cat' '(%s)' '%s>/dev/null' \
                    '%s<in' '{ %s; }' 'true; %s & '; do
            # The format string IS the fixture parameter here, by design.
            # shellcheck disable=SC2059
            payload="python3 $(printf "$deco" "$pat")"
            case "$quoting" in
                single) cmd="echo '$payload' | sh" ;;
                double) cmd="echo \"$payload\" | sh" ;;
            esac
            assert_block "$cmd" "#640 generated: $quoting quotes, $deco with $pat -> BLOCK"
        done
    done
done
# An operator character INSIDE a bracket expression, which is why the probe asks the
# whitespace split alongside the operator split rather than replacing it. These blocked
# before #640 and must keep blocking: cutting the word at the `;` halves the pattern and
# trades one bypass for another. Raised by codex on #640.
for cls in 'lease_slo[;t].py' 'lease_slo[&t].py' 'lease_slo[|t].py' 'lease_slo[(t].py' 'lease_slo[<t].py'
do
    assert_block "eval \"python3 $LIB/$cls\"" "#640: operator inside a bracket class: $cls -> BLOCK"
done

# The accepted over-block, PINNED so it reads as a decision rather than an accident: a
# payload that only quotes the name as data blocks too, because nothing static can tell
# print from run inside an opaque payload. The literal twin is asserted first and blocked
# BEFORE #640 as well -- that is the evidence this aligns the two spellings rather than
# opening a class. Raised by codex on #640.
assert_block "echo \"printf '%s' 'lease_slot.py'\" | sh" \
    "#640 trade: quoted literal as data (blocked pre-#640 too) -> BLOCK"
assert_block "echo \"printf '%s' 'lease_slo?.py'\" | sh" \
    "#640 trade: quoted glob as data, now matching the literal -> BLOCK"

# FD-PREFIXED REDIRECTS. Raised as Medium by Cursor Bugbot on #707: the claim was that a
# globbed helper immediately before `2>` stays one token, so fnmatch never sees the
# pattern the shell globs. Measured, the opposite is true and the probe is already right:
# the FD digit binds to the WORD, not to the redirect, so the shell globs `lease_slo?.py2`
# and matches nothing -- verified by EXECUTION (a stub helper in a temp dir never ran)
# across bash, sh, zsh, dash and ksh, all five agreeing. The probe cutting on `>` and
# leaving the digit attached is therefore the SAME tokenization the shell performs, not a
# divergence from it.
#
# What is pinned here is the form that DOES execute -- the space-separated redirect, where
# the digit is its own token and the glob really does reach the helper. That is the
# security-relevant half and it was untested; the glued form needs no assertion because
# the shell does not run it either.
for redir in '2>&1' '2>/dev/null' '1>&2' '&>/dev/null' '3>/dev/null'; do
    assert_block "eval \"python3 $LIB/lease_slo?.py $redir\"" \
        "#707: executing FD redirect: $redir -> BLOCK"
done

# The release rule still holds through a quote: widening to the shell variants must not
# hand `**` a new way to block, which is #573 reaching the same code path.
assert_ok "echo 'it isn'\\''t ** anything **' | sh" "#573 holds: quoted ** in a piped payload -> allowed"

echo "── E. WHITESPACE inside a bracket class (#708) ──"
# The other half of section D's last shape, and the one #640 left open: a space is a legal
# class MEMBER too, and the whitespace split -- the probe's only split when it was written --
# cuts the pattern in half at exactly the character that makes it match. Pre-existing,
# verified allowing at origin/main (94f13b07), so it predates #640 and #573 both.
#
# What is asserted is what EXECUTES -- but read that precisely, because this file cannot
# check the second half of it. Every row below asserts ONE thing: the classifier's verdict
# on a command string. Nothing here creates a stub helper and nothing here runs a shell, so
# a spelling that stopped executing, or one that started, would not show up as a failure.
#
# Where "measured" comes from is section F at the end of this file, which does execute: it
# builds a STUB helper in a temp directory, runs each generated spelling there, and requires
# every command that actually RAN the stub to be one the classifier blocks. The rows in this
# section are the hand-picked shapes that discipline turned up, each one a draft it falsified.
#
# Section F is why the two halves cannot drift apart: a spelling that stops executing, or one
# that starts, changes what F asserts. It runs against a stub in a throwaway directory and
# never against this repo's own helper -- but nothing in this file should be pasted into a
# shell regardless.
#
# The fix deletes the whitespace from inside the class instead of trying to work out whether
# it was quoted. The quoting is what makes the shell keep the word together, but asking that
# question is what every broken draft had in common -- see the _class_members docstring.
# The rows below are grouped by the draft each one broke, so a future rewrite has to face
# them all.

# 1. THE ORIGINAL SHAPES. One per way of quoting the space; all five shells ran every one.
for cls in 'lease_slo[\ t].py' "lease_slo[' 't].py" "lease_slo[\$' 't].py" "lease_slo['x t'].py"
do
    assert_block "eval \"python3 $LIB/$cls\"" "#708: quoted space inside a bracket class: $cls -> BLOCK"
done
# The inner-DOUBLE-quoted twins, on outer SINGLE quotes because that is the spelling that
# was measured running -- nesting a double quote inside `eval "..."` ends the string rather
# than the class.
for cls in 'lease_slo[" "t].py' 'lease_slo["x t"].py'
do
    assert_block "eval 'python3 $LIB/$cls'" "#708: quoted space, inner double quotes: $cls -> BLOCK"
done
# No directory in front of the name, so the basename cannot be what rescues the match, and
# the same word reached through a piped payload rather than the indirection path.
assert_block "eval \"python3 lease_slo[\\ t].py\"" "#708: no directory, behind eval -> BLOCK"
assert_block "echo 'python3 $LIB/lease_slo[\\ t].py' | sh" "#708: piped payload -> BLOCK"

# 2. WHAT BROKE THE ADJACENCY DRAFT: the space is inside a quoted run but next to NEITHER
# quote, so a rule reading only the characters beside it divides the pattern in half. Raised
# as high by codex in review, then confirmed by execution. `['x t']` is in the loop above.

# 3. WHAT BROKE THE INNERMOST-RUN REGEX: the OPPOSITE quote inside the run. An apostrophe is
# an ordinary character inside double quotes, so `["x'y t"]` is a legal quoted class -- but a
# run holding the other quote does not look innermost to a regex, and the delivery is what
# makes it unreachable: the inner delimiters ESCAPED inside an outer quoted payload, where no
# regex can tell which run a character belongs to. Measured running in all five shells while
# the classifier answered OK. Raised by codex in review.
__DQ='"'
for pay in "lease_slo[${__DQ}x'y t${__DQ}].py" "lease_slo['x${__DQ}y t'].py" "lease_slo[${__DQ}' t${__DQ}].py"; do
    esc="${pay//$__DQ/\\$__DQ}"
    assert_block "eval \"python3 $LIB/$esc\"" \
        "#708: opposite quote inside the run, escaped in an outer payload: $pay -> BLOCK"
    assert_block "printf '%s' \"python3 $LIB/$esc\" | sh" \
        "#708: same, delivered through a pipe: $pay -> BLOCK"
done

# 4. WHAT BROKE THE STATEFUL SCANNER: an unpaired quote the shell never opened, standing in
# front of the class. A heredoc body and a comment are both regions the shell does not
# quote-track, so an apostrophe in either is ordinary text -- but a scanner reading straight
# through sees a quote and carries that state forward, and the class further down then reads
# as unquoted exactly where it matters. Both measured RUNNING while the classifier answered
# OK. The heredoc was raised by codex in review; the comment twin was found the same way and
# is pinned beside it because one fix covers both.
__POISON_HEREDOC="cat <<'EOF'
it isn't data
EOF"
__POISON_COMMENT="# it isn't data"
__POISON_PAY="lease_slo[${__DQ}x'y t${__DQ}].py"
__POISON_ESC="${__POISON_PAY//$__DQ/\\$__DQ}"
assert_block "$__POISON_HEREDOC
eval \"python3 $LIB/$__POISON_ESC\"" \
    "#708: apostrophe in a heredoc body must not poison the read -> BLOCK"
assert_block "$__POISON_COMMENT
eval \"python3 $LIB/$__POISON_ESC\"" \
    "#708: apostrophe in a comment must not poison the read -> BLOCK"

# 5. WHAT BROKE THE PER-LINE SCANNER: a quoted run that legitimately SPANS a newline, which
# resynchronising at each line cannot see. Both spellings were measured running. Raised by
# codex in review.
for nlpay in "lease_slo[${__DQ}x'
 t${__DQ}].py" "lease_slo[${__DQ}x
 t${__DQ}].py"; do
    nlesc="${nlpay//$__DQ/\\$__DQ}"
    assert_block "eval \"python3 $nlesc\"" \
        "#708: quoted class spanning a newline -> BLOCK"
done

# 6. WHAT BROKE THE LAZY `[^]]*` SPAN: two spellings where the first `]` does not terminate
# the class. A `]` is a literal MEMBER when it comes first, and the `]` closing a POSIX
# sub-expression belongs to that sub-expression. Both were measured RUNNING the helper while
# the classifier answered OK; raised by codex in review. The POSIX one needs the
# sub-expression deleted as well as the whitespace, because fnmatch cannot represent it --
# it reads `[[:space:]t]` as literal characters followed by a literal `]`, so the pattern
# stops matching anything the shell would expand.
for gcls in "lease_slo[]' 't].py" "lease_slo[[:space:]' 't].py" "lease_slo[[:alpha:]' 't].py"
do
    assert_block "eval \"python3 $LIB/$gcls\"" \
        "#708: a close-bracket or POSIX class that does not end the expression: $gcls -> BLOCK"
done
# The same sub-expression in ordinary use must still be allowed -- deleting a member from a
# class in prose leaves a shorter class, never a helper name.
assert_ok 'grep "[[:alpha:] ]" file.txt' "#708: POSIX class in an ordinary grep -> allowed"
assert_ok "tr -d '[:space:]' < in.txt > out.txt" "#708: POSIX class in an ordinary tr -> allowed"

# 6b. THE SAME CLASSES REACHED THROUGH THE STRUCTURED WALK, which never goes near the
# abandoned-scan probe: a heredoc the parser CAN read hands the walk a whole operand, and
# the pattern is tested there instead. Found by generating class spellings and EXECUTING
# each one -- 70 of 162 ran the helper, and these were the ones the probe-side fix did not
# reach, which is why the reconciliation lives in _glob_helper rather than only in the probe.
#
# An escaped `]` as a member is pinned here too: only a BARE `]` closes the class.
for hcls in "lease_slo[[:alpha:]' '].py" "lease_slo[[:space:]t].py" "lease_slo[[.t.]' '].py" "lease_slo[\\]\\ t].py"
do
    assert_block "sh <<'EOF'
python3 $LIB/$hcls
EOF" "#708: class through a parseable heredoc: $hcls -> BLOCK"
done
assert_block "eval 'python3 $LIB/lease_slo[\\]\\ t].py'" \
    "#708: an escaped close-bracket is a member, not the terminator -> BLOCK"

# 6c. WHICH `]` CLOSES THE CLASS, AND WHERE A SPAN MAY REACH -- neither is decidable from
# text the shell has not finished with, so both are answered both ways rather than guessed.
# All three rows below were measured RUNNING the helper while the classifier allowed them;
# the first two were raised by codex in review, the third came out of the generator.
#
#   - a `]` the QUOTING makes literal is a member the shell keeps, and a scan that stops at
#     the first one cuts the class short;
#   - a stray `[` in a comment or in prose is no opener at all, and a span free to cross
#     newlines lets it swallow the line holding the real class;
#   - a class that legitimately spans a newline needs exactly that freedom.
assert_block "cd $LIB
eval 'python3 lease_slo[\"x] \"t].py'" \
    "#708: a quoted close-bracket is a member, not the terminator -> BLOCK"
assert_block "cd $LIB
# [
eval \"python3 lease_slo[\\\"x t\\\"].py\"" \
    "#708: a stray opener on an earlier line must not swallow the class -> BLOCK"

# The shell negates a class with `^` OR `!`; fnmatch reads only `!` that way and takes a
# leading `^` for an ordinary member, so this expanded onto the helper while the pattern
# here matched nothing. Raised by codex in review.
assert_block "cd $LIB
eval \"python3 lease_slo[^a' '].py\"" \
    "#708: caret negation reads as negation, not as a member -> BLOCK"

# 6d. A CLOSING BRACKET IN THE MIDDLE. A word can hold a quoted `]` member AND a second
# class after it, so neither the first `]` nor the last one is the terminator the shell
# used -- the readings have to walk a few of them. Measured running; codex in review.
assert_block "cd $LIB
eval 'python3 lease_sl[\"x] \"o][t].py'" \
    "#708: a close-bracket between two classes -> BLOCK"

# A NEGATED class whose only member is the whitespace. Deleting the member is right, but it
# leaves `[!]`, which fnmatch reads as literal text rather than as a class -- so the pattern
# stopped matching the very helper the shell expands it onto. What survives the deletion is
# `?`: one character, unconstrained. Both spellings of negation are pinned. Codex in review.
assert_block "cd $LIB
eval 'python3 lease_slo[!\\ ].py'" \
    "#708: negated class emptied by the deletion still matches -> BLOCK"
assert_block "cd $LIB
eval 'python3 lease_slo[^\\ ].py'" \
    "#708: the caret-negated twin of the same shape -> BLOCK"

# 6e. WHERE THE CLASS BEGINS AND ENDS, when the text gives no honest answer. Quote removal
# happens BEFORE globbing, so a `]` the quoting makes literal is a member the shell keeps,
# and a `[` the quoting makes literal is no opener at all. Both rows measured RUNNING the
# helper; codex in review, one per reading it defeated.
#
# The first needs the terminator search to walk PAST several quoted `]` members. The second
# needs the opener to be the `[` NEAREST the class, not the leftmost one on the line -- an
# assignment holding a quoted `[` otherwise swallows everything after it.
assert_block "cd $LIB
eval 'python3 lease_sl[\"x] y] z] \"o][t].py'" \
    "#708: several quoted close-brackets before the real terminator -> BLOCK"
assert_block "cd $LIB
eval \"X='[' python3 lease_slo[' 't].py\"" \
    "#708: a stray opener in an assignment must not swallow the class -> BLOCK"

# 6f. A WHITESPACE THAT WAS A RANGE ENDPOINT. Deleting a member is safe; deleting an
# ENDPOINT is not. `[<space>-u]` is the range from space to `u` and covers the helper's `t`,
# but drop the space and `[-u]` covers nothing -- so the rewrite that closes #708 was itself
# changing what a class means. Raised by codex in review, measured running. The fix is the
# `?` reading asked beside it: a bracket expression matches exactly ONE character, so `?`
# says the same thing without rewriting any member at all.
for rcls in "lease_slo[' '-u].py" "lease_slo[' '-z].py"
do
    assert_block "eval \"python3 $LIB/$rcls\"" \
        "#708: whitespace as a range ENDPOINT, not a member: $rcls -> BLOCK"
done

# A class carrying many quoted `]` members. The depth here is bounded and the bound is
# documented in _class_variants; the row below pins the part that is covered. The two-class
# terminator shape is asserted separately in 6h, and the multi-class over-block it forced is
# stated at the end of that section.
#
# NOT asserted, and named so the absence reads as a decision: a word combining TWO classes
# that each carry quoted `]` members needs a DIFFERENT terminator choice per class, and a
# reading applies one choice to the whole string, so covering it means combining choices per
# class, which is exponential in the number of classes. Measured running; codex raised it in
# review. Left in the residual _class_variants documents rather than half-covered: the
# helpers are safe by construction since #519, and this is the last-resort probe for text
# nothing could parse -- such a word is answered by the prefix fallback instead (see
# _count_classes) rather than read precisely.

__DEEP="lease_sl["
__DEEP+='"x] '
for _i in 1 2 3 4 5 6 7 8 9 10; do __DEEP+='y] '; done
__DEEP+='o"][t].py'
assert_block "cd $LIB
eval 'python3 $__DEEP'" \
    "#708: ten quoted close-brackets before the real terminator -> BLOCK"

# 6g. THE OTHER DIRECTION: a class that CANNOT reach a helper must still be allowed. Closing
# #708 means rewriting classes so fnmatch reads them as the shell does, and every draft that
# rewrote them loosely started inventing matches -- widening a class to "one character,
# whichever" said `[a]` could match the helper's `t`. That is #573's failure mode from the
# inside, and codex raised it in review; these rows are the guard against it coming back.
#
# The rewrite resolves a class to the members it can actually match, so both directions are
# decided by the same resolution rather than by a heuristic per shape.
assert_ok "python3 $LIB/lease_slo[a].py"          "#708: a class with no matching member -> allowed"
assert_ok "python3 $LIB/lease_slo[abc].py"        "#708: several members, none matching -> allowed"
assert_ok "python3 $LIB/lease_slo[a-b].py"        "#708: a RANGE that spans no matching member -> allowed"
assert_ok "python3 $LIB/lease_slo[[:digit:]].py"  "#708: a POSIX class the helper name cannot contain -> allowed"
assert_ok "python3 junk]lease_slo[a].py"          "#708: literal text before the class is not dropped -> allowed"

# And its twin, to keep the pair honest: alphabetic DOES cover the helper's `t`, so this one
# expands onto the helper and must block. Measured by execution, the same as every row above:
# `[[:alpha:]]` ran the stub helper, `[[:digit:]]` and `[a-b]` did not.
assert_block "python3 $LIB/lease_slo[[:alpha:]].py" \
    "#708: a POSIX class that DOES cover the helper character -> BLOCK"

# 6h. TWO classes in one operand, each needing its OWN terminator, and a class carrying many
# quoted `]` members. The terminator is chosen per class -- extended only while the class so
# far resolves to nothing any helper name contains -- so the two do not have to agree. Both
# measured running; codex raised each against a version that chose once for the whole string.
assert_block "cd $LIB
python3 lease_sl[\"x] o\"][\"x] y] t\"].py" \
    "#708: two classes, each with its own terminator -> BLOCK"

# ...and the over-block that pairs with it, which is DELIBERATE and was not always. Two
# adjacent complete classes are two character positions: `[a][t]` cannot expand onto a single
# `t`, bash expands it to nothing, and an earlier jump across the `]` claimed otherwise --
# codex raised that as a false positive and the jump was refused.
#
# The refusal then turned out to be a bypass. Quote removal runs BEFORE globbing, so
# `[\"x][o\"]` is ONE class whose members include a literal `[`, and bash expands it straight
# onto the helper; codex reproduced that running, two rounds later. The opener cannot be
# classified after the quotes are gone, so BOTH readings are asked (see _skip_closers) and
# the merging one blocks here. The cost is this row: an operand that already spells the
# helper's stem and then writes two adjacent classes is refused even though it expands to
# nothing. That is the standing trade of this change -- over-block bounded to operands that
# already spell a helper stem, in exchange for closing a spelling that RUNS.
assert_block "python3 $LIB/lease_slo[a][t].py" \
    "#708: adjacent classes -> BLOCK (accepted over-block; the merging reading is required)"

# The over-block really is bounded to that shape: a stem that spells nothing is still allowed
# with the merging reading available.
assert_ok "python3 $LIB/notahelper[a][t].py" \
    "#708: adjacent classes on a non-helper stem -> allowed"
# ...and the point at which that over-block widened, stated rather than quietly re-scoped.
# Every reading dimension is chosen once per WORD, which equals per class only while there is
# ONE class; with two they are coupled, and codex expanded three different words onto the
# helper where no single combination reads both classes. A cross product over classes is the
# honest model and a budgeted one would only move the edge, so a multi-class word is no longer
# read by these dimensions at all -- it is answered by the prefix fallback. The cost is that
# the over-block now covers ANY multi-class word on a helper stem, not just the merging pair:
# `[a][b]` matches nothing and is refused anyway. Still bounded to operands that already spell
# a helper's stem, which is why the non-helper row above still passes.
assert_block "python3 $LIB/lease_slo[a][b].py" \
    "#708: two classes on a helper stem -> BLOCK (over-block; the dimensions cannot read two)"

# 7. GENERATED matrix, crossing the quote style, the body and the delivery shape. The
# hand-picked rows above are the shapes somebody thought of, and every draft was broken by a
# combination nobody had; codex asked for this in review. Every spelling below is a bracket
# class aimed at the helper, so BLOCK is the right answer for each whether or not a given
# shell would run that particular one -- the probe is fail-CLOSED by construction and a
# variant only ever adds candidate patterns, never removes one.
_SQ="'"
for _q in "$_SQ" "$__DQ"; do
    if [[ "$_q" == "$_SQ" ]]; then _opp="$__DQ"; else _opp="$_SQ"; fi
    for _body in " t" "x t" "x${_opp}y t" "${_opp} t"; do
        _cls="lease_slo[${_q}${_body}${_q}].py"
        _esc="${_cls//$__DQ/\\$__DQ}"
        assert_block "eval \"python3 $LIB/$_esc\"" \
            "#708 generated: eval, quote=$_q body=[$_body] -> BLOCK"
        assert_block "printf '%s' \"python3 $LIB/$_esc\" | sh" \
            "#708 generated: piped, quote=$_q body=[$_body] -> BLOCK"
    done
done

# The BARE space -- the issue's own repro line -- blocks too, and it is pinned with the
# caveat said out loud: measured, that spelling runs the helper in NONE of the five shells,
# because eval'd text is word-split BEFORE it is globbed, so the shell never assembles the
# pattern. It is fail-closed generosity rather than the mechanism's target. Pinned rather
# than left silent because the issue's repro line is what a reader will try first.
assert_block "eval \"python3 $LIB/lease_slo[ t].py\"" \
    "#708: bare space, incidental fail-closed block -> BLOCK"

# THE #573 RELEASE RULE, reaching this code path from the other side, and the reason the fix
# DELETES a class member rather than making the class ATOMIC. A bracket-aware word BOUNDARY
# joins the link below into ONE pattern matching every string that ends in a class member --
# the helper name ends in `y`, and `my` supplies it -- which is #573 reopened on the exact
# shape #573 was reported for, and it was measured doing so. Deleting the space inside a
# class joins nothing: the whitespace OUTSIDE it still separates words, so this body still
# splits where it always did.
assert_ok 'gh pr create --body "see **[my link](http://example.com/x)** for details"' \
    "#708/#573: bold markdown link in a PR body -> allowed"
assert_ok 'gh pr create --body "the [a b] case, [z-a] ranges and a - [ ] checklist"' \
    "#708/#573: bracketed prose with spaces in a PR body -> allowed"

# 8-9. Two reader defects found in review. BOTH are invisible end to end -- the union of
# readings and the fail-CLOSED fallbacks mask them, so an `assert_block`/`assert_ok` row
# passes identically with and without the fix and pins NOTHING. Verified: the reversed-range
# spelling blocks either way. So each is pinned where it is actually observable, at the
# reader, with one assertion per mechanism.
assert_unit() { # <python-expr-returning-bool> <label>
    if python3 -c "
import importlib.util, shlex, sys
spec = importlib.util.spec_from_file_location('mc', '$CLASSIFIER')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if ($1) else 1)
" < /dev/null 2>/dev/null; then
        ok "$2"
    else
        no "$2" "reader-level invariant does not hold"
    fi
}

# A REVERSED span matches nothing on its own, but the shell keeps parsing the REST of the
# class -- `[a-zw-v]` still reaches the helper's `t` through the leading `a-z`. Returning the
# empty set on the reversed span DISCARDED every member an earlier span had already
# collected, which is the fail-OPEN direction (fewer members = fewer blocks). Raised by
# cursor in review.
assert_unit "len(m._resolve_members('a-zw-v')) > 0" \
    "#708: a reversed span must not discard members an earlier span collected"

# `\"` and `\\` are the ONLY escapes shlex honours inside a double-quoted word. Reading a
# backslash before any other character as an escape made `_dequote_lex` disagree with the
# lexer it is checked against, and a disagreement drops the raw pass for the WHOLE segment.
# Raised by cursor and codex both.
assert_unit "m._dequote_lex('\"a\\\\\"b\"') == shlex.split('\"a\\\\\"b\"')[0]" \
    "#708: _dequote_lex must resolve a double-quote escape exactly as shlex does"

# 10. A round-2 reader defect: the reversed-span fallback (`_resolve_members`) skipped a
# FIXED 3 characters past a reversed range's `lo-` prefix, even when the endpoint it had
# just resolved (`_span_endpoint`) was an escape (`\t`, 2 chars) or a collating/equivalence
# element (`[.t.]`, 5+ chars). The endpoint's own trailing characters were left for the next
# loop pass to read as ordinary MEMBERS -- widening the POSITIVE reading with a character
# that was never a member on its own. `_class_members` negates that reading for a `[!...]`
# class, so the wrongly-added member narrowed what the negated class was read as reaching --
# real bash's own `[!z-\ta]` still matches `t` (the reversed span matches nothing either
# way; verified running bash), but the pre-fix reader excluded `t` from the negated set.
# Raised by cursor in review.
assert_unit "'t' in m._class_members('z-\\\\ta', True)" \
    "#708 round 2: a reversed span's escaped upper endpoint must not leak into the negated reading"

# 11. A round-2 finding, directly observable end to end (no masking): the raw pass for a
# segment is dropped whenever `_strip_redirs` disagreed between the dequoted token list and
# the raw one -- but a quoted redirect-looking argument (`">"`) answers `_is_redir`
# differently on EACH list by construction (the raw spelling still carries its quote marks,
# the dequoted one does not), which is not a genuine pairing break. Dropping the raw pass
# fell through to the whole-segment `_bracket_prefix_hit` fallback, which BLOCKed on a LATER
# argument that only mentions the helper's shape -- the script actually executed is a
# different, harmless file. Raised by codex in review.
assert_ok "python3 $LIB/safe[a].py \">\" ignored 'lease_slo[\"x\"]t.py'" \
    "#708 round 2: a quoted redirect-looking argument must not drop the raw pass -> allowed"

# 12. A round-4 finding, directly observable end to end: an incomplete POSIX sub-expression
# opener (`[:`, `[.`, `[=` with no matching closer) made the terminator scan ABANDON the
# whole class instead of reading those characters as ordinary members and continuing to look
# for the class's own `]` -- bash itself reads `[^[[=]` as a negated class of the ordinary
# members `{[, =}`, and _resolve_members already gets that right for a class BODY once its
# boundary is known. The two scanners that decide where the boundary IS
# (_squeeze_span_classes, _count_classes) gave up instead: _count_classes reporting zero
# classes routed the word past every multi-class guard, and _class_variants never produced a
# matching rewrite, so a command bash expands straight onto the helper read as a plain miss.
# Raised by codex in review.
assert_block "python3 $LIB/lease_slo[^[[=].py" \
    "#708 round 4: an incomplete POSIX sub-expression opener is an ordinary member, not an abandoned class"

# 13. A round-4 finding, masked end to end the same way 8-9 were: _glob_helper asks
# _deep_affordable(word) a second time to decide whether the search it just ran was
# exhaustive, but by then _class_variants has already DEBITED the budget for that exact
# word -- so a word that WAS affordable, and got the full deep search it paid for, can fail
# the same question once it is asked again against the post-charge balance. That routed a
# fully-searched precise miss (`<stem>[a].py`) through the fail-closed prefix fallback and
# over-blocked it. Fixed by resolving affordability ONCE, before the charge, and reusing
# that answer instead of re-asking the budget. Raised by cursor and codex both, from the
# same call. `__setitem__` returns None so `None or expr` reduces to `expr`, keeping this a
# single expression the way assert_unit requires.
assert_unit "(m._deep_budget.__setitem__(0, len('lease_slo[a].py')) or m._glob_helper('lease_slo[a].py')) is None" \
    "#708 round 4: a word must not price itself out of its own already-paid-for deep search"

echo "── F. what EXECUTES must BLOCK (property, #708) ──"
# The discipline the sections above are written to, made mechanical. Every row here is a
# command that is actually RUN in a throwaway directory holding a STUB helper: if the shell
# expanded it onto the stub, the classifier must block it. A command that runs while the
# classifier allows it is precisely the bug #708 reported, and the one every rejected draft
# still had.
#
# It executes a stub -- never this repo's helper. The stub is a temp file that prints a
# marker, the commands name it by a RELATIVE path, and the whole tree is removed after.
# Spellings that the shell does NOT expand onto the stub assert nothing: what they do is a
# shell behaviour this suite does not own (the same call the FD-redirect note above makes).
_F_TOTAL=0
_F_RAN=0
# ONE trap for BOTH section temp dirs, armed before either exists. Two separate
# `trap ... EXIT` statements do not compose -- the second REPLACES the first, so arming one
# per section silently left the FIRST dir to leak on an interrupt, which is the whole thing
# the trap is for. The body is evaluated when the trap FIRES, so naming `$_G_DIR` here while
# it is still unset is fine, and `rm -rf ""` is a no-op.
# Cleanup hangs off EXIT alone, and INT/TERM EXIT rather than just cleaning up.
# A handler on INT/TERM that returns without exiting SWALLOWS the signal: bash runs
# the handler and then carries on with the next command, so the suite kept running
# after a TERM. That is how `scripts/ci/run-shell-tests.sh` enforces its per-test
# timeout (`_portable_timeout` sends TERM), so the previous single-trap form quietly
# made this suite unkillable by its own timeout -- a regression introduced by the
# leak fix that added the trap in the first place. Measured both ways on a loop of
# short commands, which is this suite's shape: cleanup-only stayed ALIVE after TERM;
# exiting handlers terminated AND still ran the EXIT cleanup. Codex caught it.
#
# Exiting also reaches EXIT, so the dirs are still removed on every path.
trap 'rm -rf "${_F_DIR:-}" "${_G_DIR:-}"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
_F_DIR="$(mktemp -d)" || { no "#708 property: mktemp -d" "could not create a temp dir"; _F_DIR=""; }
# An EMPTY _F_DIR would make every path below absolute -- the stub would be written to
# /hooks/... and the commands would run against the real tree. Refuse rather than guess.
if [[ -z "$_F_DIR" || ! -d "$_F_DIR" ]]; then
    no "#708 property: temp dir" "mktemp -d gave no usable directory; section F skipped"
else
mkdir -p "$_F_DIR/$LIB"
printf 'print("STUB_RAN")\n' > "$_F_DIR/$LIB/lease_slot.py"

_f_runs() { # <command> -> 0 if the shell ran the stub
    local out
    out="$(cd "$_F_DIR" && bash -c "$1" 2>/dev/null)" || true
    [[ "$out" == *STUB_RAN* ]]
}

f_case() { # <command> <label>
    _F_TOTAL=$((_F_TOTAL + 1))
    if _f_runs "$1"; then
        _F_RAN=$((_F_RAN + 1))
        assert_block "$1" "#708 property: RUNS the stub -> must BLOCK :: $2"
    fi
}

_F_SQ="'"
_F_DQ='"'
for _f_q in "$_F_SQ" "$_F_DQ"; do
    if [[ "$_f_q" == "$_F_SQ" ]]; then _f_opp="$_F_DQ"; else _f_opp="$_F_SQ"; fi
    for _f_body in " t" "x t" "x${_f_opp}y t" "${_f_opp} t" "]${_f_q} ${_f_q}t"; do
        _f_cls="lease_slo[${_f_q}${_f_body}${_f_q}].py"
        _f_esc="${_f_cls//$_F_DQ/\\$_F_DQ}"
        f_case "eval \"python3 $LIB/$_f_esc\"" "eval, quote=$_f_q body=[$_f_body]"
        f_case "printf '%s' \"python3 $LIB/$_f_esc\" | sh" "pipe, quote=$_f_q body=[$_f_body]"
    done
done
# the unquoted shapes, plus the two classes that decide the other direction
for _f_bare in "lease_slo[\\ t].py" "lease_slo[[:alpha:]].py" "lease_slo[[:digit:]].py" "lease_slo[a-b].py" "lease_slo[a].py"; do
    f_case "python3 $LIB/$_f_bare" "bare: $_f_bare"
done

rm -rf "$_F_DIR"
fi
printf '  ..    %d generated, %d expanded onto the stub and were required to block\n' \
    "$_F_TOTAL" "$_F_RAN"
# A generator that stopped executing anything would asserts nothing and pass silently, so
# require that it still reaches the stub at all.
if [[ "$_F_RAN" -ge 8 ]]; then
    ok "#708 property: the generator still reaches the helper ($_F_RAN cases)"
else
    no "#708 property: the generator still reaches the helper" "only $_F_RAN executed -- the fixtures stopped exercising the shell"
fi

echo "── G. an ABANDONED search is not a MISS (#708, exhaustion) ──"
# The budgets in _class_variants bound how much SEARCHING happens. They used to bound the
# ANSWER with it: a class carrying more quoted `]` members than the search looks at ran out
# of readings and reported "no helper" for a command the shell expands straight onto one.
# Codex raised it twice at high confidence and both shapes were reproduced RUNNING, which is
# what these rows re-run. The fix is _bracket_prefix_hit: whatever a class turns out to mean,
# a bracket expression matches exactly ONE character, so the word can only expand to
# something starting with the literal text before its `[` -- a superset of every reading the
# abandoned search would have produced, and one that needs no terminator at all.
#
# Same stub-in-a-temp-directory discipline as section F: each row is RUN, and a row the shell
# does not actually expand onto the stub asserts nothing rather than passing quietly.
_G_DIR="$(mktemp -d)"
if [[ -z "$_G_DIR" || ! -d "$_G_DIR" ]]; then
    no "#708 exhaustion: fixture setup" "mktemp -d failed -- cannot verify by execution"
else
    mkdir -p "$_G_DIR/$LIB"
    printf 'print("STUB_RAN")\n' > "$_G_DIR/$LIB/lease_slot.py"

    _G_RAN=0
    g_case() { # <command> <label>
        local out
        out="$(cd "$_G_DIR" && bash -c "$1" 2>/dev/null)" || true
        if [[ "$out" == *STUB_RAN* ]]; then
            _G_RAN=$((_G_RAN + 1))
            assert_block "$1" "#708 exhaustion: RUNS the stub -> must BLOCK :: $2"
        else
            # Unlike section F, which generates spellings and accepts that some do not
            # expand, every row here is hand-built to reach the stub. One that does not is a
            # broken fixture asserting nothing, not a shell behaviour -- codex found exactly
            # that in a row whose tail had been mistyped, where the aggregate count below
            # still passed on the strength of its neighbours.
            no "#708 exhaustion: $2" "fixture never reached the stub -- it asserts nothing"
        fi
    }

    # (a) the class carries N quoted `]` members before its real terminator. 10 is inside
    #     the search, 40 and 80 are past it -- the point of the row is that the answer no
    #     longer changes at the boundary.
    for _g_n in 10 40 80; do
        _g_word="lease_sl[\"x] "
        for ((_g_i = 0; _g_i < _g_n; _g_i++)); do _g_word+='y] '; done
        _g_word+='o"][t].py'
        g_case "eval 'python3 $LIB/$_g_word'" "$_g_n quoted close-brackets before the terminator"
    done

    # (b) the class OPENS the basename, so there is no literal stem to weigh. The path
    #     separator still stands before it, which is what keeps this readable as an operand
    #     rather than as prose -- skipping it outright was the bypass codex found next.
    for _g_n in 10 65; do
        _g_word='["x] '
        for ((_g_i = 0; _g_i < _g_n; _g_i++)); do _g_word+='y] '; done
        _g_word+='l"x]ease_slot.py'
        g_case "eval 'python3 $LIB/$_g_word'" "class opens the basename, $_g_n members"
    done


    # (c) the class sits in a DIRECTORY component. A helper is matched on its BASENAME, so
    #     `/` moves the anchor: reading only the run's first bracket asked about
    #     `gate-script*` and never asked about the basename at all. Codex found it the round
    #     after the candidate cap came out, which is why every segment is asked now.
    _g_cls='["x] '
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_cls+='y] '; done
    _g_cls+='o"][t].py'
    g_case "eval 'python3 hooks/gate-script[s]/lib/lease_sl$_g_cls'" \
        "class in a directory component hides the basename anchor"
    g_case "eval 'python3 hook[s]/gate-script[s]/lib/lease_sl$_g_cls'" \
        "two directory classes before the basename"


    # (d) a QUOTED `[` is a literal MEMBER of the class it sits in. Quote removal runs before
    #     globbing, so by the time a pattern is matched a quoted opener and a real one are
    #     the same character -- `[\"x][o\"]t.py` is ONE class to bash, not two. The
    #     terminator search used to refuse to cross any `[` at all, which is what made this
    #     run. It is now asked BOTH ways: see _skip_closers, and see the adjacent-classes row
    #     above for the over-block that pays for it.
    g_case "cd $LIB; python3 lease_sl[\"x][o\"]t.py" \
        "quoted [ as a literal member of the class"
    g_case "cd $LIB; python3 lease_sl[\"][o\"]t.py" \
        "quoted ] then a literal ["

    # (e) the #573 prose release is for STRUCTURELESS text only. At a structured call site the
    #     word is a resolved interpreter OPERAND, where a class opening the word is not prose
    #     and releasing it is simply a hole -- codex walked an exhausted operand through it.
    _g_word='["x] '
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_word+='y] '; done
    _g_word+='l"x]ease_slot.py'
    g_case "cd $LIB; python3 $_g_word" \
        "exhausted operand opening with a class is not prose"


    # (f) the operand PADDED past the depth budget with syntax the shell removes. The budget
    #     is a bound on searching, and the caller that spends it has to be able to SEE that it
    #     ran out -- _glob_helper could not, so a structured operand grown past
    #     _CLASS_DEEP_MAX_LEN with empty quote pairs quietly dropped to the base reading, and
    #     the base reading stops at the first quoted `]`. Codex, one round after the same bug
    #     was fixed in the probe: the depth decision now has a single definition
    #     (_deep_affordable) precisely so two callers cannot read it differently again.
    _g_pad=""
    for ((_g_i = 0; _g_i < 2200; _g_i++)); do _g_pad+="''"; done
    g_case "python3 $LIB/lease_sl[\"a] \"o][t].py$_g_pad" \
        "operand padded past the depth budget with quotes the shell removes"


    # (g) a quoted whitespace that is a RANGE ENDPOINT, delivered EVERY way. Section 6f
    #     already pinned this class -- but only behind `eval`, and that turned out to be the
    #     one delivery that read it correctly. A range needs its `-` beside its endpoints, and
    #     skipping quotes in passing left `[' '-u]` as three members instead of the range
    #     space..u that covers the helper's `t`; only the DEQUOTED reading saw the range, and
    #     that reading is asked at one call site. So the same class blocked behind `eval` and
    #     RAN behind `| sh`. Quote removal now happens before the body is parsed, which is
    #     the order the shell does it in, and every delivery lands on the same answer.
    #
    #     An eval-only row standing in for a family is exactly how this hid, so all three
    #     deliveries are pinned here rather than one.
    for _g_ep in "-u" "-z"; do
        _g_rng="lease_slo[' '$_g_ep].py"
        g_case "eval \"python3 $LIB/$_g_rng\"" "range endpoint via eval: $_g_ep"
        g_case "printf '%s' \"python3 $LIB/$_g_rng\" | sh" "range endpoint via pipe: $_g_ep"
        g_case "echo \"python3 $LIB/$_g_rng\" | bash" "range endpoint via echo|bash: $_g_ep"
    done


    # (h) TWO classes needing DIFFERENT readings. Every dimension above -- which `]` closes,
    #     whether to cross a `[`, `!` as negator, `-` as range operator -- is chosen once per
    #     WORD, which is the same as per class only while there is one class. Codex found all
    #     three couplings in a single round and each expanded onto the helper:
    #       - the first class needs the crossing terminator, the two after it the default
    #       - one class QUOTES its `!`, the next uses it to negate
    #       - one class quotes its `-`, the next uses it as a range operator
    #     No single combination reads both, and a budgeted cross product over classes would
    #     only move the edge, so a multi-class word is answered by the prefix fallback
    #     instead. See _count_classes, and the over-block row in section E that this widened.
    g_case "cd $LIB; python3 lea[\"x][s\"]e_[s][l]ot.py" \
        "two classes: crossing terminator, then the default"
    g_case "cd $LIB; python3 lease_sl[\"!\"o][!a].py" \
        "two classes: quoted ! then a negating !"
    g_case "cd $LIB; python3 lease_sl[p\"-\"o][s-u].py" \
        "two classes: quoted - then a range -"


    # (i) a POSIX sub-expression whose closing `]` is QUOTED. This is not the digit class and
    #     bash does not read it as one: the quoted `]` stops `:]` from closing the
    #     sub-expression, so the body is a plain member list that holds `t`. Both obvious
    #     readings are wrong -- the span walk looks for `:]` in text still carrying its
    #     quotes and abandons the class, while removing the quotes first turns it back INTO
    #     the digit class, which matches nothing. The question is asked of the RAW text,
    #     before the tokenizer removes what the answer depends on. Codex, measured running.
    g_case "cd $LIB; python3 lease_slo[[:digit:\"]\"].py" \
        "POSIX sub-expression with a quoted closing bracket"

    # (j) a word opening with a class inside an EVAL payload. #573's release is for PROSE,
    #     and an eval payload reaches the probe as structureless text without being prose.
    #     The word BEFORE the class is what tells them apart.
    _g_ev='["x] '
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_ev+='y] '; done
    _g_ev+='l"x]ease_slot.py'
    g_case "cd $LIB; eval 'python3 $_g_ev'" \
        "eval payload opening with a class is not prose"


    # (k) the interpreter hidden behind a REDIRECT or a FLAG OPERAND. What separates an
    #     operand from prose is whether an interpreter owns the word, and reading only the
    #     word immediately before it is not that test: `2>/dev/null`, `-W ignore`, `-X dev`
    #     and `--check-hash-based-pycs default` all overwrite it with something harmless, and
    #     each released a payload that RUNS. Codex found all four in one round. The walk back
    #     now skips flags, words that follow a flag, and anything carrying a redirect.
    _g_own='["x] '
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_own+='y] '; done
    _g_own+='l"x]ease_slot.py'
    for _g_pre in "2>/dev/null" "-W ignore" "-X dev" "--check-hash-based-pycs default" "-I 2>/dev/null"; do
        g_case "cd $LIB; eval 'python3 $_g_pre $_g_own'" \
            "interpreter behind '$_g_pre' still owns the operand"
    done


    # (l) the interpreter spelled so a RAW scan cannot see it. An earlier draft decided
    #     "operand or prose?" by looking backwards through raw text for an interpreter, and
    #     a releasing test computed from raw text fails OPEN once for every way of hiding
    #     the thing it looks for: a quoted name, an escaped name, `${IFS}` in place of the
    #     space, and -- separately -- more redirects than its lookback bound. Codex found
    #     four in one round and three in the next.
    #
    #     The test is gone. What is being RUN is now decided where it can be decided
    #     honestly: the walk's own `pyi`, which already resolves these spellings, and the
    #     evidence rule reads only the word. These rows pin the spellings that broke it.
    _g_q="py\"thon\"3"
    _g_e="p\\ython3"
    _g_w="lease_slo[[:digit:\"]\"].py"
    g_case "cd $LIB; $_g_q $_g_w"       "interpreter with a quoted name"
    g_case "cd $LIB; $_g_e $_g_w"       "interpreter with an escaped name"
    g_case "cd $LIB; python3\${IFS}$_g_w" "interpreter separated by \${IFS}"

    _g_many='["x] '
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_many+='y] '; done
    _g_many+='l"x]ease_slot.py'
    _g_red=""
    for ((_g_i = 0; _g_i < 12; _g_i++)); do _g_red+="2>/dev/null "; done
    g_case "cd $LIB; eval 'python3 $_g_red$_g_many'" \
        "twelve redirects between the interpreter and the glob"


    # (m) a word built almost ENTIRELY of one-character classes. It supplies two literal
    #     characters and eleven classes, and counting only the literals released it -- but a
    #     class stands for exactly one character, so eleven of them pin a LENGTH, which #573
    #     already settled is evidence. Codex measured it running.
    g_case "cd $LIB; python3 l[e][a][s][e][_][s][l][o][t][.][p]y" \
        "a word made of one-character classes"
    g_case "cd $LIB; python3 l[e][a][s][e][_][s][l][o][[:digit:\"]\"][.][p]y" \
        "the same, with one malformed POSIX class among them"


    # (n) option OPERANDS between the interpreter and the glob. The raw spelling is now
    #     carried into the walk rather than sniffed beside it, so which word is the executed
    #     operand is decided once, by the code whose job that already is -- `-W ignore` and
    #     `-X dev` are consumed by the walk's own option handling instead of being mistaken
    #     for the script. Two earlier drafts reconstructed that decision and codex broke both.
    _g_gl="lease_slo[[:digit:\"]\"].py"
    for _g_opt in "" "-W ignore" "-X dev" "--check-hash-based-pycs default" "-I" "-W ignore -X dev"; do
        g_case "cd $LIB; python3 $_g_opt $_g_gl" \
            "option operand '$_g_opt' before the glob"
    done


    # (o) the operand spelled so a VALUE lookup cannot find its raw form. The raw spelling is
    #     paired with the lexer's own token by POSITION and the pairing is verified word by
    #     word; an earlier draft paired them by comparing values with the quotes stripped,
    #     which ignored backslash escapes and collapsed duplicates -- so a backslash in the
    #     stem hid the operand, and repeating the word in a harmless spelling first handed
    #     back the harmless one. Both codex, both measured running.
    _g_qd="lease_slo[[:digit:\"]\"].py"
    _g_pl="lease_slo[[:digit:]].py"
    g_case "cd $LIB; python3 lease_s\\lo[[:digit:\"]\"].py" \
        "a backslash escape inside the stem"
    g_case "cd $LIB; python3 -W $_g_pl $_g_qd" \
        "the harmless spelling of the same word first"


    # (p) the class joined across whitespace by a BACKSLASH rather than a quote. What makes
    #     the whitespace after a `[` a MEMBER is quoting OR escaping, and the test for it
    #     read only quotes -- an incompleteness on the fail-open side, even though this shape
    #     blocks through another reading anyway. Pinned so the reading it currently relies on
    #     cannot quietly become the only one.
    _g_bs="[x"
    for ((_g_i = 0; _g_i < 40; _g_i++)); do _g_bs+="\\]\\ y"; done
    _g_bs+="\\ l]ease_slot.py"
    g_case "cd $LIB; python3 $_g_bs"      "class joined by escaped whitespace"
    g_case "eval 'python3 $LIB/$_g_bs'"   "the same, behind eval"


    # (q) an UNRELATED argument that made the raw pairing disagree with the lexer. The raw
    #     spelling is the only thing that can answer a quoted `]` inside a class, and any
    #     disagreement anywhere in the segment dropped the whole list -- silently, and for
    #     the segment, not the token. So one decoy argument next to the payload turned a
    #     BLOCK into an allow. Two independent triggers: whitespace the splitter counted and
    #     the lexer does not (VT, FF, NBSP, ideographic space -- str.isspace() is wider than
    #     shlex's), and a backslash inside a DOUBLE-quoted run. Both reproduced running.
    #
    #     Both are fixed at the splitter, but the row that matters is the invariant: a
    #     dropped pairing now fails CLOSED, so no decoy can make the answer weaker.
    _g_qg="lease_slo[[:digit:\"]\"].py"
    for _g_dec in "a$(printf '\xc2\xa0')b" "a$(printf '\x0b')b" "a$(printf '\x0c')b" "a\\\\b"; do
        g_case "cd $LIB; python3 $_g_qg $_g_dec" \
            "a decoy argument must not weaken the verdict"
    done

    # (r) the deep reading is a per-COMMAND resource. Every size bound measures ONE string,
    #     and a command can repeat an affordable string: at the structured call sites the
    #     word-count term is vacuously 1, so ten segments each holding one 4KB bracket word
    #     cost 21.96s against a 5s hook budget. It is charged in bytes now, and running out
    #     drops to the base reading AND routes through the fallback -- exhaustion is not a
    #     miss. Timing lives in section H; this row pins that the ANSWER is still right.
    _g_big="["
    for ((_g_i = 0; _g_i < 83; _g_i++)); do _g_big+="a-z"; done
    _g_big+="\"]]]\""
    g_case "python3 $_g_big ; python3 $_g_big ; python3 $LIB/lease_slo[' 't].py" \
        "a costly word repeated across segments"


    # (s) the budget is a RESOURCE, so what matters is the state it is in when a word
    #     arrives -- not whether that word is affordable in isolation. Two ways it was
    #     loose: a word costing more than what is LEFT was still admitted (the check asked
    #     whether anything remained, not whether this fit, so it overdrew by its own
    #     length), and an EXPLICIT deep= -- which the abandoned-scan probe settles once for
    #     a whole family -- never consulted the budget at all. Neither reached the hook's 5s
    #     budget in measurement, but a bound that does not mean what it says is one shape
    #     away from doing so. Drain first, then hand it the expensive word: the answer must
    #     still be right, which is what refusing-into-the-fallback buys.
    _g_sm="["; for ((_g_i = 0; _g_i < 20; _g_i++)); do _g_sm+="a-z"; done; _g_sm+="\"]]]\""
    _g_bg="["; for ((_g_i = 0; _g_i < 1360; _g_i++)); do _g_bg+="a-z"; done; _g_bg+="\"]]]\""
    _g_drain=""
    for ((_g_i = 0; _g_i < 20; _g_i++)); do _g_drain+="python3 $_g_sm ; "; done
    g_case "$_g_drain python3 $_g_bg ; python3 $LIB/lease_slo[' 't].py" \
        "an oversized word arriving on a nearly-spent budget"


    # (t) #708's own family, one round later. The reported bug was a QUOTED space inside a
    #     class; this is an ESCAPED one acting as a range ENDPOINT. Quote removal happens
    #     before globbing, so `[\\ -u]` reaches the matcher as `[ -u]` -- a span from space
    #     to `u` covering the helper's `t` -- while the reader took `\\ ` as an isolated
    #     member and resolved {space, -, u}. It RAN and answered OK. The escape is now read
    #     BOTH ways, member and endpoint, which is the same add-never-substitute rule every
    #     other reading here follows. The unescaped `[ -u]` spelling stays allowed because
    #     bash does not expand it onto anything -- precision, not just blocking.
    g_case "eval 'python3 $LIB/lease_slo[\\ -u].py'" \
        "an escaped space as the LOW endpoint of a range"
    g_case "eval \"python3 $LIB/lease_slo[\\ -u].py\"" \
        "the same, delivered through double quotes"
    g_case "cd $LIB; python3 lease_slo[a-\\u].py" \
        "an escaped char as the HIGH endpoint"


    # (u) an endpoint is not always one character of TEXT. POSIX spells a collating element
    #     `[.a.]` and an equivalence class `[=a=]`, and the shell accepts either side of a
    #     `-` -- so `[[.a.]-[.z.]]` is a RANGE covering the helper's `t`, while the reader
    #     recorded only `a` and `z` and answered OK. Same shape as (t): a class element read
    #     ONLY as a standalone member. One reader now answers "what character does this
    #     endpoint denote" for all three spellings -- escape, collating, equivalence -- so
    #     the next spelling in this family is covered by construction rather than by a row.
    #
    #     `[a-[.z.]]` is the case that survived the first fix: its PLAIN reading is reversed
    #     (`[` sorts below `a`), and the reversed answer is the empty class, which discarded
    #     the span the endpoint reader had just resolved correctly.
    for _g_cls in "[[.a.]-[.z.]]" "[[.a.]-z]" "[a-[.z.]]" "[[.t.]]" "[[=t=]]"; do
        g_case "cd $LIB; python3 lease_slo$_g_cls.py" \
            "a collating or equivalence element as a class member or endpoint"
    done
    g_case "eval 'python3 $LIB/lease_slo[[.a.]-[.z.]].py'" \
        "the same, delivered through eval"

    rm -rf "$_G_DIR"

    # The other direction, and the reason (b) is not simply "block every bracket after a
    # slash": a `[` that opens the WORD carries no path, `?*` matches every string that
    # exists, and blocking on that is #573's report with a different wildcard. These are
    # long enough to exhaust the search, so they exercise the fallback rather than the
    # precise path.
    _G_MANY=""
    for ((_g_i = 0; _g_i < 80; _g_i++)); do _G_MANY+="] "; done
    assert_ok "gh pr create --body 'see [link](http://x) and [other](http://y) $_G_MANY'" \
        "#708 exhaustion: markdown links in a long body -> allowed"
    assert_ok "gh issue comment 5 --body 'array [0] and [1] $_G_MANY'" \
        "#708 exhaustion: bracket indexes in a long body -> allowed"
    assert_ok "cat a/b[0]/c.txt $_G_MANY" \
        "#708 exhaustion: a bracket in a directory that spells nothing -> allowed"
    assert_ok "python3 $LIB/lease_slo[[:digit:]].py" \
        "#708: the GENUINE POSIX digit class is still allowed"
    # The quote-in-class rule weighs only the text before the class, so a one-character stem
    # would name a helper about as specifically as a bare wildcard -- #573's objection. What
    # releases it is that no interpreter stands in front of it.
    assert_ok "awk '{ a[\$1 \" \" \$2]++ } END { for (k in a) print k }' f" \
        "#708: a quote inside an awk subscript -> allowed"
    assert_ok "tr -d '[:space:]' < in.txt > out.txt" \
        "#708: a quoted POSIX class as a whole argument -> allowed"
    assert_ok "echo 'lease_slo[\"x\"]t.py'" \
        "#708: a helper-shaped glob ECHOED as data -> allowed"
    assert_ok "grep -r 'lease_slo[\"x\"]t.py' ." \
        "#708: the same shape SEARCHED for as data -> allowed"
    assert_ok "gh pr create --body 'we changed lease_slo[\"x\"]t.py today'" \
        "#708: the same shape quoted in a PR body -> allowed"
    # ...and the same shape handed to a SAFE program as an ARGUMENT. The raw quote-in-class
    # question can only be asked of text the tokenizer has not dequoted yet, and two drafts
    # of that guard asked it too early: once before the walk had chosen anything (which
    # blocked `echo`), and once as soon as an interpreter was merely present (which blocked
    # these three). It now waits for the interpreter FIRST non-flag operand, so a glob that
    # arrives second is data, exactly as the read/mention contract has always had it.
    assert_ok "python3 safe.py 'lease_slo[\"x\"]t.py'" \
        "#708: a helper-shaped glob as an argument to another script -> allowed"
    assert_ok "python3 -c 'print(1)' 'lease_slo[\"x\"]t.py'" \
        "#708: the same as an argument to a -c program -> allowed"
    assert_ok "python3 -I -m json.tool 'lease_slo[\"x\"]t.py'" \
        "#708: the same as an argument to an isolated -m module -> allowed"
    # ...including when the executed script ITSELF carries a class. The guard used to pair
    # "the first operand has a bracket" with a quote search over the whole segment, which
    # combined syntax from two unrelated arguments and blocked this.
    assert_ok "python3 safe[a].py 'lease_slo[\"x\"]t.py'" \
        "#708: bracketed safe script, helper-shaped glob as its argv -> allowed"
    # A tail taken from the far end of the TEXT is only paired with an earlier stem when a
    # quote could make them ONE shell word -- which is #708 itself. Without that condition it
    # joined `lease_s` from one word to `lot.py` from five words later and invented a helper
    # name no part of the text contains. Codex measured it on a heredoc this file allowed.
    assert_ok "cat <<'EOF'
it isn't
lease_s[x]junk a[b] c[d] d[e] junk[y]lot.py
EOF" \
        "#708: unrelated bracketed words do not lend each other a tail -> allowed"
    assert_ok "echo lease_s[x]junk a[b] junk[y]lot.py" \
        "#708: the same words plainly echoed -> allowed"
    assert_ok "echo a[b]\\ c[d]\\ junk" \
        "#708: escaped spaces around ordinary brackets -> allowed"
    assert_ok "ls my\\ file[0].txt" \
        "#708: an escaped space in an ordinary filename -> allowed"

    if [[ "$_G_RAN" -ge 58 ]]; then
        ok "#708 exhaustion: the fixtures still reach the helper ($_G_RAN cases)"
    else
        no "#708 exhaustion: the fixtures still reach the helper" \
           "only $_G_RAN executed -- the shapes stopped exercising the shell"
    fi
fi

echo "── H. answering AT ALL is the invariant (#708, hook timeout) ──"
# This classifier is registered as a PreToolUse hook with a 5s timeout, and on expiry it is
# killed with NO decision on stdout -- which the harness reads as ALLOW. So a shape that
# merely makes it SLOW is a bypass with extra steps, and "it blocks" is only half the
# assertion. The reading family is spent per bracket-bearing word and every variant yields
# its own words again, so cost multiplies by word COUNT, not by input size.
#
# The hole this pins was not at the extremes, which were already bounded and fast, but just
# INSIDE every bound: 20 bracket words parked in front of a deep class sat two closers under
# _CLASS_DEEP_MAX_CLOSERS, took the full reading, and measured 4.18s -- inside the hook's
# timeout by less than a second, on one machine, on one day. _CLASS_DEEP_MAX_WORDS is the
# bound that caught it, and the same peak now measures 0.82s.
#
# The budget asserted here is the HOOK's own 5s rather than the measurement: a tighter number
# would fail on a slower machine and teach the next reader to raise it, and the invariant is
# not "fast" -- it is that an answer arrives at all.
#
# `timeout` is not on the default macOS PATH, so the budget is enforced from python, which
# also kills the child rather than leaving the suite hanging on the very shape being pinned.
h_answers_within() { # <seconds> <command> <label>
    local got
    got="$(python3 - "$CLASSIFIER" "$1" "$2" <<'PY' 2>/dev/null || printf 'ERROR'
import json, subprocess, sys
chk, budget, cmd = sys.argv[1], float(sys.argv[2]), sys.argv[3]
payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
try:
    r = subprocess.run([sys.executable, "-I", chk], input=payload,
                       capture_output=True, text=True, timeout=budget)
except subprocess.TimeoutExpired:
    print("TIMEOUT")
else:
    print((r.stdout.strip() or "EMPTY").splitlines()[0])
PY
)"
    case "$got" in
        TIMEOUT) no "$3" "no decision within ${1}s -- a killed hook emits nothing, which reads as ALLOW" ;;
        EMPTY|ERROR|"") no "$3" "got=${got:-<empty>} -- an empty decision reads as ALLOW" ;;
        *) ok "$3" ;;
    esac
}

_H_PARK=""
for ((_h_i = 0; _h_i < 20; _h_i++)); do _H_PARK+="v${_h_i}=[a${_h_i}] "; done
_H_CLS='["x] '
for ((_h_i = 0; _h_i < 40; _h_i++)); do _H_CLS+='y] '; done
_H_CLS+='o"][t].py'
_H_MANY=""
for ((_h_i = 0; _h_i < 800; _h_i++)); do _H_MANY+="[a] "; done

h_answers_within 5 "eval '$_H_PARK ; python3 $LIB/lease_sl$_H_CLS'" \
    "#708 timeout: 20 bracket words in front of a deep class still answers"
h_answers_within 5 "eval \"echo $_H_MANY\"" \
    "#708 timeout: 800 bracket words still answers"

# and that shape must still reach the RIGHT answer, not merely reach one
assert_block "eval '$_H_PARK ; python3 $LIB/lease_sl$_H_CLS'" \
    "#708 timeout: the parked-decoy shape still BLOCKS"

# The SAME decoys with no whitespace between them. A budget has to be spent in the unit the
# work is done in: the scan splits on shell operators as well as whitespace, so counting only
# whitespace words made `v0=[a0];v1=[a1];...` look like ONE word while every decoy still got
# its own deep reading. Measured at 16.65s -- more than three times the hook timeout it was
# added to respect, and past the timeout there is no decision at all. Codex, the round after
# the word bound went in. Each separator is checked because each one splits.
# A FEW words, each carrying many quoted `]`. The word bound alone does not catch this --
# these stay inside it -- because cost is words TIMES the search each word pays for, and the
# probe pays it twice over (once dequoted, once raw). Two such words spent 3.98s of the 5s
# budget, and codex clocked the pair with a marker-write tail at 5.42s: past the timeout the
# hook is killed, emits nothing, and the `rm` it was gating is allowed. What fixed it was
# removing duplicated work rather than tightening a bound -- a word taken from an
# ALREADY-reconciled variant has nothing left for a second search to find. Same shapes now
# measure 0.19s.
_H_DEEP=""
for ((_h_i = 0; _h_i < 2; _h_i++)); do
    _H_DEEP+="w${_h_i}[\"x] "
    for ((_h_j = 0; _h_j < 8; _h_j++)); do _H_DEEP+='y] '; done
    _H_DEEP+='o"][t].py '
done
h_answers_within 5 "eval \"$_H_DEEP ; rm reviewed-commits.local\"" \
    "#708 timeout: two deep bracket words plus a marker-write tail still answers"

# ONE class body, long. The three depth bounds measure the TEXT -- its size, its closers,
# its bracket words -- and a single body slips inside all of them: 4,084 bytes carrying five
# closers in one bracket word measured 6.68s, past the hook timeout, because cost is
# quadratic in body length and the terminator search re-resolves the whole span per
# candidate. Same class of hole as the word bound was added for, reached by a different
# dimension; _CLASS_BODY_MAX is the term that closes it, and refusing to resolve widens to
# the whole helper alphabet rather than narrowing to nothing.
# Built with a plain loop rather than $(printf ... $(seq ...)) -- the nested substitution
# masks its inner return value (shellcheck SC2312).
_H_PAD=""
for ((_h_j = 0; _h_j < 1015; _h_j++)); do _H_PAD+="a"; done
_H_BIG="zz[q]"
for ((_h_i = 0; _h_i < 4; _h_i++)); do _H_BIG+="$_H_PAD]"; done
_H_BIG+=".zz"
h_answers_within 5 "eval 'echo $_H_BIG'" \
    "#708 timeout: one 4KB class body inside every other bound still answers"

# The same costly word repeated across SEGMENTS. Every depth bound above measures a single
# string, and each of these words satisfies all of them -- what was unbounded was how many
# times a command may pay. Ten of them measured 21.96s, four times the hook budget, and past
# the timeout there is no decision at all. _DEEP_MAX_BYTES makes the allowance a per-command
# resource, and the cost stops moving with the segment count.
_H_BIGW="["
for ((_h_i = 0; _h_i < 83; _h_i++)); do _H_BIGW+="a-z"; done
_H_BIGW+="\"]]]\""
_H_CHAIN=""
for ((_h_i = 0; _h_i < 10; _h_i++)); do _H_CHAIN+="python3 $_H_BIGW ; "; done
h_answers_within 5 "$_H_CHAIN python3 $LIB/lease_slo[' 't].py" \
    "#708 timeout: ten costly bracket words across segments still answers"
assert_block "$_H_CHAIN python3 $LIB/lease_slo[' 't].py" \
    "#708 timeout: and still reaches the right answer"

for _h_sep in ";" "&" "|"; do
    _H_TIGHT=""
    for ((_h_i = 0; _h_i < 20; _h_i++)); do _H_TIGHT+="v${_h_i}=[a${_h_i}]${_h_sep}"; done
    h_answers_within 5 "eval '$_H_TIGHT""python3 $LIB/lease_sl$_H_CLS'" \
        "#708 timeout: 20 decoys separated by '$_h_sep' and no whitespace still answers"
    assert_block "eval '$_H_TIGHT""python3 $LIB/lease_sl$_H_CLS'" \
        "#708 timeout: the '$_h_sep'-separated decoy shape still BLOCKS"
done

echo
echo "════ marker-glob-specificity: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
