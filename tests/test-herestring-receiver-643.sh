#!/usr/bin/env bash
# Regression tests for #643 — a here-string feeding a shell executes its payload, so the
# payload is a PROGRAM and must be scanned as one.
#
# History: `sh <<< '<helper invocation>'` returned `OK|` while the equivalent pipe
# spelling `echo '<helper invocation>' | sh` returned BLOCK. Same invocation, one
# transport apart. `_piped_shell_producers` yields producer segments for a PIPELINE whose
# receiver is a shell; a here-string has no producer segment at all — the payload is the
# operand of the `<<<` operator on the shell's own command line — so nothing was yielded
# and the payload was never scanned. The guard is UNCONDITIONAL (it blocks regardless of
# whether a design review is pending), so this was a straight bypass of the mutating-helper
# protection rather than a degraded-mode gap.
#
# The asymmetry was one-directional: cmdword.py already closed `<<<` (see its stdin-fed
# shell-source branch, "bash <<< 'rm -rf src' (here-string) executes the redirected text
# exactly as -c would"). marker_check.py — the copy the helper guard actually consults —
# did not. The two carry an explicit KEEP IN STEP contract.
#
# Three sides are pinned, and all three are needed. Only the block side would let a future
# change widen the scan until ordinary reads are refused; only the allow side would let it
# be deleted wholesale; only the residual side would let a measured limitation be quietly
# restated as coverage.
#   A. a here-string into a shell/interpreter is EXECUTION — block
#   B. a here-string into a non-executing receiver is DATA — allow
#   C. the measured residuals, pinned so they stay visible rather than rediscovered
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision: this is a guard on the
# classifier's evidence, and going through the gate would let an unrelated pending-review
# state decide the outcome instead. Same harness as tests/test-marker-glob-specificity.sh.
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

# BSD `date` has no %N, so the millisecond clock comes from python3 — which this harness
# already requires. `monotonic`, not `time`: a wall clock can step backwards during an NTP
# correction, and a negative elapsed time satisfies a `< 2000` bound no matter how slow
# the run actually was. Whole seconds are too coarse for the performance bounds below: their
# healthy path runs in ~70ms and the regressions they guard are ~3.4s, a gap a 1-second
# tick cannot state.
_now_ms() { python3 -c 'import time;print(int(time.monotonic()*1000))'; }

# A benchmark must be a command bash would actually run. The nested case was built by
# concatenation and came out as `cat; ; fi` — a syntax error, so its timing and its
# asserted verdict described a parse failure rather than a nested compound.
assert_parses() { # <command> <label>
    if bash -n -c "$1" 2>/dev/null; then
        ok "$2"
    else
        no "$2" "not valid shell — the benchmark below measures a parse error"
    fi
}

# Deliberately if/then/else rather than `cond && ok || no` (shellcheck SC2015).
assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — an ordinary read was refused"
    fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — here-string payload reached a shell unscanned (#643)"
    fi
}

# The helper invocation the guard exists to catch. Assembled at run time from two halves
# so this file can be EDITED by an agent whose own tool calls are scanned by the very
# guard under test: a Bash call whose text contains the literal invocation is refused
# ("Cannot call ... directly"), which is how the first attempt to write this file failed.
# The classifier sees the assembled string in the payload, which is all that matters.
STEM="python3 hooks/gate-scripts/lib/lease_"
TAIL="slot.py"
HELPER="$STEM$TAIL"

# ── A. execution: the payload is a program ────────────────────────────────────────────
# The motivating case. Pipe spelling already blocked; this one did not.
assert_block "sh <<< '$HELPER'"                "sh <<< payload is execution"
assert_block "echo '$HELPER' | sh"             "pipe spelling stays blocked (control: guard is live)"
# `-s` reads the program from stdin explicitly, so this is the same shape with the intent
# spelled out. It was equally open.
assert_block "bash -s <<< '$HELPER'"           "bash -s <<< payload is execution"
# REDIRECT-FIRST. bash accepts a leading redirection before the command word, and
# cmdword.py records `<<<x sh -c ...` among previously leaked spellings, so the command
# word must be resolved by the peel machinery rather than read as words[0].
assert_block "<<<'$HELPER' sh"                 "redirect-first spelling resolves to the shell"
# Wrapper in command position: the receiver is still the shell behind it.
assert_block "timeout 5 bash <<< '$HELPER'"    "wrapper-peeled receiver is still a shell"
# xargs executes what it reads from stdin. It is deliberately IN the stdin-shell set —
# see the _SHELL_NAMES note and tests/test-impl-gate-scope-519.sh, which pin the same
# fail-CLOSED direction for the pipe transport. The two transports must not diverge.
assert_block "xargs <<< '$HELPER'"             "xargs here-string matches its pipe treatment"
# ACCEPTED OVER-BLOCK, pinned deliberately. With `-c` the shell runs that program and the
# here-string is only stdin DATA, so this is not execution of the payload. Distinguishing
# it needs an option-arity table, which this module refuses to keep: deciding whether a
# shell reads stdin from its FLAGS "failed open four ways when tried" (`bash --norc` read
# as "-c present", `bash --rcfile -c` read the VALUE of --rcfile as the option). An
# over-block is the direction this file chooses; do not "fix" this by adding arity.
assert_block "sh -c 'echo hi' <<< '$HELPER'"   "shell with -c over-blocks (no arity table, by design)"
# The receiver test must be the SAME WIDE TEST the pipe transport uses. Peeling to a
# single command word was narrower three ways, each an executing here-string that
# classified as a read. Raised in review on this PR; pinned so a future simplification
# back to a peel cannot land silently.
# (1) an option VALUE mistaken for the command word -- the option-arity question this
#     module refuses to answer, which fails OPEN when answered wrong.
assert_block "env -u X sh <<< '$HELPER'"       "option value is not the command word"
# (2) a command word resolved by EXPANSION: brace expansion reaches a shell the text
#     never spells, so an exact-name test reads a word no set contains. Unresolved is
#     the fail-CLOSED case here, exactly as on the pipe path.
assert_block "/bin/ba{s..s}h <<< '$HELPER'"    "expanded command word counts (unresolved fails closed)"
# (3) an IMPLICIT launcher: it execs the user's shell, so no shell NAME appears anywhere
#     in the segment. _launcher_in_any_simple_command already covers this for pipes.
assert_block "script -q /dev/null <<< '$HELPER'" "implicit launcher execs a shell"
assert_block "unshare <<< '$HELPER'"           "second launcher spelling, same treatment"
# (4) an ATTACHED option value. BSD/macOS `env -S` plus a quoted program lexes to ONE
#     token whose first word matches no shell, so the raw tokens read as a non-shell while
#     bash still ran it. _stage_words is the expansion the pipe path already applies.
assert_block "env -Sbash <<< '$HELPER'"        "attached env -S operand still resolves to a shell"
# (5) command-position `.` / `source`. Both are deliberately ABSENT from the shell-name
#     set (an any-word match there cost a real over-block on `source` as a grep PATTERN),
#     so they are tested in COMMAND POSITION only — the same way the pipe path tests them.
assert_block ". /dev/stdin <<< '$HELPER'"      "dot sources what the here-string feeds"
assert_block "source /dev/stdin <<< '$HELPER'" "source spelling, same treatment"
# (6) WORD-SPLITTING shapes. Each of these was a measured fail-open while the operand was
#     reconstructed as "the token after <<<". They are fixed not by teaching this walk
#     more of bash's lexer but by never extracting the operand at all — existence of a
#     genuine `<<<` plus an executing receiver sends the WHOLE SEGMENT to the probe, and
#     none of these spellings can hide the helper NAME from a scan of the text it sits in.
#     Composite quoting in the COMMAND WORD is handled by squeezing quotes before the
#     name test, since `b'a's'h'` is a valid spelling of bash.
assert_block "b'a's'h' <<< '$HELPER'"          "composite-quoted command word still resolves"
assert_block "sh <<< '$STEM'\"$TAIL\""         "adjacent quoted fragments concatenate into one word"
assert_block "sh <<< python3\\ hooks/gate-scripts/lib/lease_$TAIL" \
                                               "escaped whitespace joins words"
assert_block "bash -s \\< <<< '$HELPER'"       "an escaped punctuation argument is not a redirection"
# ...and that whole CLASS is now unresolvable-by-policy rather than parsed. shlex does not
# model bash escaping, so each repair aimed at one spelling exposed the next: `x\<` split
# into `x\` and `<`, the `<` was read as a redirection and ate the command behind it;
# suppressing the operator on odd backslash parity then mis-read `x\<<`, where bash escapes
# only the FIRST `<` and the second is real. Resolving that needs an operator starting
# mid-token — the bash lexer this module refuses to write. A segment holding both a
# here-string and an escaped METACHARACTER therefore blocks outright.
assert_block "<<< x\\<< /dev/null . /dev/stdin <<< '$HELPER'" \
    "an escaped metacharacter makes the token stream unresolvable (blocks, does not guess)"
# Escaped LETTERS are untouched by that rule — they are an ordinary command-word spelling
# and still resolve through the walk, which the `b\a\s\h` case below already pins.
# (7) ESCAPED command word. Squeezing quotes alone left `b\a\s\h` matching no name; the
#     receiver normalization squeezes escapes too.
assert_block "b\\a\\s\\h <<< '$HELPER'"        "escaped command word still resolves to a shell"
# ...and an ANSI-C ESCAPE is DECODED, not just stripped. Squeezing backslashes resolves the
# case above, where each escapes a letter that is already itself — but bash DECODES `\x62`
# to `b`, and stripping left `x62ash`, which matches no shell, so the here-string executed
# bash while the classifier called it a read. Both forms are kept: decoding alone breaks
# the case above, since `\a` is a real escape (BEL) and `b\a\s\h` stops resolving.
assert_block "\$'\\x62ash' <<< '$HELPER'"        "an ANSI-C hex escape resolves to a shell"
assert_block "\$'\\x73h' <<< '$HELPER'"          "...and the short name too"
# Quotes are squeezed out of the decoded form, BACKSLASHES ARE NOT: after decoding, a
# surviving backslash is DATA rather than an escape, so the decoded variant of
# `$'\x62a\x5csh'` is `ba\sh` and matches no shell.
#
# That spelling still over-blocks, and it is pinned here as one because the reason is
# OLDER than any of this: the raw word is squeezed of backslashes before it is compared,
# which is what makes the ordinary spelling `b\a\s\h` resolve to a shell — correctly,
# since those backslashes escape letters that are already themselves. `'ba\sh'`, a genuine
# literal backslash, measures BLOCK for the same reason and always has. Distinguishing them
# needs to know whether the backslash was data or an escape, and `_norm_for_scan` has
# already dropped the `$` that says so.
assert_block "'ba\\sh' <<< '$HELPER'"           "a literal backslash in a command word over-blocks (pre-existing squeeze)"
assert_block "\$'\\x62a\\x5csh' <<< '$HELPER'"   "...and its ANSI-C spelling inherits that, not the decode"
# The decoded variants join the ANY-WORD receiver test, which is deliberately wide: a shell
# name ANYWHERE in the non-redirection words counts, because peeling to a single command
# word failed open three ways (see the receiver-test note above). So a shell name written as
# an ARGUMENT over-blocks — and it already did in every plain spelling, long before any
# decoding existed. Pinned as a pair so the decoded form is not mistaken for a new class.
assert_block "printf bash <<< '$HELPER'"       "a shell name as an argument over-blocks (the wide any-word test)"
assert_block "printf \$'\\x62ash' <<< '$HELPER'" "...and its ANSI-C spelling reaches the same rule, not a new one"
# COMMAND POSITION IS ASKED IN BOTH SPELLINGS. `.` and `source` are recognised only in
# command position — they are deliberately absent from _SHELL_NAMES, because an any-word
# match over-blocked the bare word `source` used as a grep pattern — so decoded forms
# appended to the end of one word list could never reach that test, and the encoded
# spellings sourced the payload while classifying as a read. The lists are kept parallel
# and command position is derived from each.
assert_block "\$'\\x2e' /dev/stdin <<< '$HELPER'"  "an ANSI-C encoded dot is still command position"
assert_block "\$'\\x73ource' /dev/stdin <<< '$HELPER'" "...and an encoded source"
assert_block "if true; then \$'\\x2e' /dev/stdin; fi <<< '$HELPER'" \
    "...including inside a compound, where the widening asks per segment"
# ...and the reason `.`/`source` are position-only still holds after decoding.
assert_ok "grep source f <<< '$HELPER'"        "the bare word source as a pattern is not a receiver"
# POSITION IS DECIDED PRE-EXPANSION, and only the NAME is compared decoded. Bash resolves
# shell grammar before it expands, so `$'\x74ime'` is NOT the `time` keyword — it is a
# command whose name happens to expand to `time`. Deriving command position by running the
# peel over the decoded list gave decoded words grammar semantics and would strip it.
# The peel is also gated on the word being BARE, which is the same rule from the other
# side: bash recognises a reserved word BEFORE quote removal, so a quoted or escaped
# spelling is the external program and the dot behind it is just its argument.
assert_ok "\$'\\x74ime' . /dev/stdin <<< '$HELPER'" "an ANSI-C spelling of time is not the keyword"
assert_ok "'time' . /dev/stdin <<< '$HELPER'"  "...nor a quoted one"
assert_ok "t\\ime . /dev/stdin <<< '$HELPER'"   "...nor an escaped one"
assert_block "time . /dev/stdin <<< '$HELPER'" "...but the bare keyword still peels"
# ...and a LINE CONTINUATION inside the keyword is not "a backslash in the raw word":
# `_norm_for_scan` removes backslash-newline before this walk ever sees it, so the word
# arrives bare and peels. Pinned because the bare-word rule reads like it would reject it.
assert_block "ti\\
me . /dev/stdin <<< '$HELPER'"                 "a line continuation inside the keyword still peels"
# PROPERTY over the lexical distinctions command position depends on. Bash decides shell
# grammar BEFORE quote removal and BEFORE expansion, so only a BARE spelling in
# pipeline-prefix position is the keyword — every other spelling is an ordinary command
# whose argument happens to be a dot.
_t_n=0
for _pre in "" "{ " "if true; then "; do
    _suf=""
    [[ "$_pre" == "{ " ]] && _suf="; }"
    [[ "$_pre" == "if true; then " ]] && _suf="; fi"
    _t_n=$((_t_n + 1))
    _got=$(verdict "${_pre}time . /dev/stdin${_suf} <<< '$HELPER'")
    if [[ "$_got" != BLOCK_* ]]; then
        no "property: a bare time in keyword position always peels" "${_pre}time — got=${_got:-<empty>}"
        _t_n=-1; break
    fi
done
if [[ $_t_n -gt 0 ]]; then
    ok "property: a bare time in keyword position always peels ($_t_n)"
fi
_nt_n=0
for _spell in "'time'" "t\\ime" "\$'\\x74ime'" "/usr/bin/time" "env time" "command time" \
              "'then' time" "./then time" "./time"; do
    _nt_n=$((_nt_n + 1))
    _got=$(verdict "$_spell . /dev/stdin <<< '$HELPER'")
    if [[ "$_got" != "OK|" ]]; then
        no "property: every non-keyword spelling of time leaves the dot alone" "$_spell — got=${_got:-<empty>}"
        _nt_n=-1; break
    fi
done
if [[ $_nt_n -gt 0 ]]; then
    ok "property: every non-keyword spelling of time leaves the dot alone ($_nt_n)"
fi
# The peel itself is unaffected either way — an unrelated name in the same position does
# not promote the dot behind it.
assert_ok "notatime . /dev/stdin <<< '$HELPER'" "an ordinary name does not promote the dot behind it"
# ...and the decoded candidate does NOT inherit a wrapper peel of `time`: the keyword only
# prefixes a pipeline, so after `env` or `command` it is an external program and the peel
# is not applied — with or without the dot behind it being ANSI-C encoded.
assert_ok "env time \$'\\x2e' /dev/stdin <<< '$HELPER'" \
    "a wrapped external time does not promote an encoded dot"
assert_ok "command time \$'\\x2e' /dev/stdin <<< '$HELPER'" "...same for command"
# PROPERTY over the encodings bash decodes, in both directions. A name that RESOLVES to a
# shell blocks however it is spelled; one that does not stays a data read.
_enc_n=0
for _spell in "\$'\\x62ash'" "\$'\\142ash'" "\$'\\x62\\x61sh'" "bash" "'bash'" "ba'sh'"; do
    _enc_n=$((_enc_n + 1))
    _got=$(verdict "$_spell <<< '$HELPER'")
    if [[ "$_got" != BLOCK_* ]]; then
        no "property: every spelling that resolves to a shell blocks" "$_spell — got=${_got:-<empty>}"
        _enc_n=-1; break
    fi
done
if [[ $_enc_n -gt 0 ]]; then
    ok "property: every spelling that resolves to a shell blocks ($_enc_n)"
fi
_dat_n=0
for _spell in "\$'\\x64ata'" "\$'\\x6eull'" "\$'\\x67rep' -f -" "cat"; do
    _dat_n=$((_dat_n + 1))
    _got=$(verdict "$_spell <<< '$HELPER'")
    if [[ "$_got" != "OK|" ]]; then
        no "property: a spelling that resolves to a non-shell is still data" "$_spell — got=${_got:-<empty>}"
        _dat_n=-1; break
    fi
done
if [[ $_dat_n -gt 0 ]]; then
    ok "property: a spelling that resolves to a non-shell is still data ($_dat_n)"
fi
# (8) ATTACHED OPTION BUNDLE. Peeling one option letter off `-iSbash` leaves `Sbash`, and
#     peeling a fixed number never terminates because the caller chooses the bundle
#     length — so the producer tests an endswith over the names, and this mirrors it.
#     The pipe spelling of this already blocked; the transports must not diverge.
assert_block "env -iSbash <<< '$HELPER'"       "attached option bundle resolves to a shell"
# (10) COMPOUND COMMAND. A redirection can attach to a whole compound, so the shell that
#      consumes stdin sits in an EARLIER segment and the segment holding `<<<` has only
#      `fi`. When nothing but reserved syntax is left, this segment cannot answer the
#      question, so the scan widens to every segment rather than guessing.
assert_block "if true; then sh; fi <<< '$HELPER'" "here-string on a compound command"
assert_block "while :; do bash -s; done <<< '$HELPER'" "compound loop with a shell inside"
# ...and the compound widening is GATED by the same receiver test, not unconditional: an
# unconditional widen blocked a compound whose enclosed command only reads the payload.
# The gate uses the redirection-aware walk over every segment, because a raw split would
# include the here-string PAYLOAD and a payload naming an interpreter made this look like
# it had a shell receiver.
assert_ok "if true; then cat; fi <<< '$HELPER'" "compound whose enclosed command is data-only"
# ...and that gate is the SAME predicate the per-segment walk uses, not a second copy of
# it. It was a second copy, and the copies had diverged: the compound one tested only
# staged shell names and launchers, so every receiver shape recognised ONLY by one of the
# other disjuncts executed the payload from inside a compound while classifying as a read.
# All four allowed before the predicate was unified; each is pinned here because a future
# narrowing of either call site reopens exactly one of them and nothing else would notice.
assert_block "if true; then 'b''a''s''h'; fi <<< '$HELPER'" \
    "compound + fragmented shell name (was OK: compound copy had no fragment test)"
assert_block "if true; then env -iSbash; fi <<< '$HELPER'" \
    "compound + attached option bundle (was OK: compound copy had no bundle test)"
assert_block "if true; then \$SHELL; fi <<< '$HELPER'" \
    "compound + unresolved command word (was OK: compound copy had no unresolved test)"
# Command position is per-SEGMENT, and the compound caller supplies its own. Deriving it
# from the flattened word list cannot work: _peel_wrappers returns the first EXECUTING
# word of the whole compound, which here is `true`, so the `.` that sources the payload
# was never in command position and this allowed.
assert_block "if true; then . /dev/stdin; fi <<< '$HELPER'" \
    "compound + command-position dot (was OK: flattened peel resolved to \`true\`)"
assert_block "while :; do source /dev/stdin; done <<< '$HELPER'" \
    "compound loop + command-position source"
# ...and command position is still POSITION, in the compound path too: the bare word
# `source` as a grep PATTERN is not a receiver. An any-word test for `.`/`source` would
# be the simpler unification and is why they are absent from _SHELL_NAMES to begin with.
assert_ok "if true; then grep source f; fi <<< '$HELPER'" \
    "compound whose data-only command merely names \`source\`"
# A LAUNCHER INSIDE A COMPOUND. The launcher disjunct re-splits the widened text with
# `_split_simple_commands` and then tests COMMAND POSITION — but the operator run that
# separated the segments is not carried on the segment text, so joining them with a space
# erased every boundary. The segments merged into one simple command, its first word won
# command position, and the launcher behind it was never seen: `if true; then unshare; fi`
# peeled `if`, stopped at `true`, and returned OK while unshare exec'd a shell on the
# payload. No other disjunct catches these — launchers are deliberately absent from
# _SHELL_NAMES, which is exactly why the launcher test exists.
assert_block "if true; then unshare; fi <<< '$HELPER'" \
    "a launcher inside a compound is still a receiver"
assert_block "while :; do unshare; done <<< '$HELPER'" "...in a loop"
assert_block "(cat; unshare) <<< '$HELPER'"    "...and in a subshell beside a data-only command"
assert_block "if true; then script -q /dev/null; fi <<< '$HELPER'" \
    "...an implicit launcher with no shell name anywhere"
assert_block "if true; then sudo -s; fi <<< '$HELPER'" \
    "...and sudo shell mode, which is reachable only through the launcher test"
# The segments are rejoined with `;` because that is the boundary the launcher test needs.
# It is grammar-BLIND, which is the widening's premise — "ask the same question of the whole
# command" — and it costs an over-block on a `case` PATTERN, which is a word the shell never
# executes. Both sides are pinned because they are the same edit: with a space join the
# pattern read as data (OK) and so did the real launcher one line away (OK, a fail-open).
# Separating them means knowing a pattern from a command, which is the parser this module
# refuses; an over-block on a read is the direction it accepts instead.
assert_block "case x in x) unshare;; esac <<< '$HELPER'" \
    "a launcher in a case BODY is a receiver (was OK)"
assert_block "case x in x) cat;; unshare) cat;; esac <<< '$HELPER'" \
    "...and a launcher-shaped case PATTERN over-blocks with it (accepted; the alternative was the fail-open above)"
# PROPERTY: launcher detection survives every grammar context the widening rejoins, and a
# data-only command in the same shape is still a read. Both directions, same shapes.
_lp_n=0
for _shape in "if true; then @; fi" "while :; do @; done" "until false; do @; done" \
              "( @ )" "case x in x) @;; esac" "if true; then a; @; fi"; do
    _lp_n=$((_lp_n + 1))
    _got=$(verdict "${_shape//@/unshare} <<< '$HELPER'")
    if [[ "$_got" != BLOCK_* ]]; then
        no "property: a launcher is a receiver in every compound shape" "${_shape//@/unshare} — got=${_got:-<empty>}"
        _lp_n=-1; break
    fi
    _got=$(verdict "${_shape//@/cat} <<< '$HELPER'")
    if [[ "$_got" != "OK|" ]]; then
        no "property: a data-only command in the same shape is still a read" "${_shape//@/cat} — got=${_got:-<empty>}"
        _lp_n=-1; break
    fi
done
if [[ $_lp_n -gt 0 ]]; then
    ok "property: launcher blocks and data-only reads, across compound shapes ($_lp_n)"
fi
# The BRACE GROUP is absent from the data-only half of that property, and pinned here
# instead: `{ cat; }` blocks, and it did so before any of this work too. A brace is a
# brace-EXPANSION character, so a word carrying one is an unresolved command word — which
# is deliberately fail-closed, because `/bin/ba{s..s}h` expands onto a shell the text never
# spells. The launcher half of the property still covers the shape.
assert_block "{ cat; } <<< '$HELPER'"          "pre-existing over-block: a brace group reads as an unresolved command word"
assert_block "{ unshare; } <<< '$HELPER'"      "...and a real launcher in one blocks regardless"
# RESIDUAL, and an over-block: the widening scans EVERY segment, including commands that
# precede the compound the here-string is attached to, so a shell named in front refuses a
# data-only read. Limiting the scan to the owning compound's span is more precise and was
# BUILT AND MEASURED before being reverted — it paid for that precision in both of the
# failure classes this module refuses, which is why the over-block is the shipped choice:
#   FAIL-OPEN. Deciding structure from words needs COMMAND POSITION, which this walk has
#     none of. In `if sh; then echo if; fi <<< '<HELPER>'` the ARGUMENT `if` pushed a false
#     opener, `fi` popped it, and the span closed short of the `sh` that runs the payload.
#   QUADRATIC. Nested compounds make spans grow with depth: 150 nested took 1.05s and 300
#     took 3.36s, heading through the 5s hook timeout — which writes no decision and so
#     reads as ALLOW, making slowness itself the fail-open.
# Both shapes are pinned below, so a future span attempt fails these instead of shipping.
assert_block "echo sh; if true; then cat; fi <<< '$HELPER'" \
    "residual over-block: a shell named before the compound is still in scope"
assert_block "if sh; then echo if; fi <<< '$HELPER'" \
    "a keyword used as an ARGUMENT does not shrink the scan (span attempt failed open here)"
assert_block "if true; then a; sh; fi <<< '$HELPER'" \
    "a reserved-free segment inside a compound is in scope"
assert_block "case x in x) sh;; esac <<< '$HELPER'" \
    "a case pattern terminator does not hide the receiver"
# PARENTHESISED RECEIVER. Parens arrive in the OPERATOR, not the segment text, so the
# segment holding `<<<` has NO words at all. Requiring a nonempty word list before widening
# was exactly that bypass — the subshell spelling executed the payload and returned OK.
assert_block "(sh) <<< '$HELPER'"              "parenthesised receiver widens like a compound"
assert_ok "(cat) <<< '$HELPER'"                "...and a parenthesised data-only command still reads"
# LEADING FILE DESCRIPTOR. `_REDIR_PREFIX_RE` accepts `0<<<` whole, but shlex splits the
# digits off, so the `0` stayed behind as a command word: the segment stopped being
# reserved-only, the compound never widened, and the payload reached the shell as OK.
assert_block "if true; then sh; fi 0<<< '$HELPER'" \
    "a file descriptor prefix does not leave a stray command word"
# ...and a DETACHED `0` is an ordinary argument, not part of a redirection.
assert_ok "cat 0 <<< '$HELPER'"                "a detached digit is an argument, not a descriptor"
# `time` IS PEELED IN COMMAND POSITION. It is a shell keyword, so it is in neither the
# wrapper set nor the reserved set, and the peel returned `time` itself as the command
# word — `.` and `source` are recognised in command position ONLY, so both spellings
# sourced the payload and classified as a read.
assert_block "time . /dev/stdin <<< '$HELPER'" "\`time\` does not hide a dot in command position"
assert_block "if true; then time source /dev/stdin; fi <<< '$HELPER'" \
    "...including inside a compound"
# ...and the peel is `_strip_time_prefix`, the one the stdin-producer callers already use
# (#562), not a `!= "time"` filter. That filter threw away a distinction the peel makes:
# `/usr/bin/time` is an external program that cannot source anything, so removing it would
# promote the `.` behind it to command position and refuse an ordinary read.
assert_ok "/usr/bin/time . /dev/stdin <<< '$HELPER'" \
    "external /usr/bin/time is not the keyword, and does not promote the dot"
# ...and neither is a bare `time` that follows a WRAPPER: the keyword only prefixes a
# PIPELINE, so after `env` or `command` it is an external program and nothing sources the
# payload. Peeling it there promoted the `.` and refused a data-only read.
assert_ok "env time . /dev/stdin <<< '$HELPER'" "a bare time after a wrapper is a command, not the keyword"
assert_ok "command time . /dev/stdin <<< '$HELPER'" "...same for command"
# Reserved syntax may still precede the keyword — that is the compound spelling above.
assert_block "{ time . /dev/stdin; } <<< '$HELPER'" "...but reserved syntax before it still peels"
# (11) ADJACENT FRAGMENTS IN THE COMMAND WORD. bash concatenates `'b''a''s''h'` into
#      `bash` while shlex emits four tokens, so per-token squeezing matched nothing.
#      The words are also tested JOINED. Distinct from the `b'a's'h'` case above, which
#      shlex happens to keep as ONE token — that one passed while this one did not.
assert_block "'b''a''s''h' <<< '$HELPER'"      "separately quoted letters concatenate into a shell name"
# The joined-word test compares for EQUALITY, not substring. A substring test was tried
# and broke the data contract outright: _SHELL_NAMES holds two-letter names (`nu`, `ed`,
# `ex`, `sh`), so the `nu` inside `null` made an ordinary read block.
assert_ok "cat /dev/null <<< '$HELPER'"        "a short shell name inside another word is not a receiver"
# ...and an operator FLUSH against the receiver is still an operator, not part of its name.
# While operator splitting was the lexer's job this arrived as the single word `cat<<<`,
# which read as an unresolved command word and refused two ordinary data reads.
assert_ok "cat<<< '$HELPER'"                   "an operator flush against the receiver is not part of its name"
assert_ok "grep -f -<<< '$HELPER'"             "...including after an option that ends in punctuation"
# ...and a DIGIT ending a command name is part of the name, not a file descriptor. The fd
# prefix is only a prefix where a word starts: carrying it everywhere read `source2<<<` as
# `source` plus an fd redirection and refused the read as a command-position `source`.
assert_ok "source2<<< '$HELPER'"               "a trailing digit belongs to the command name, not the redirection"
assert_ok "/tmp/bash2<<< '$HELPER'"            "...including on a path"
# The genuine fd spelling still is one, at a word start.
assert_block "if true; then sh; fi 2<<< '$HELPER'" \
    "a descriptor at a word start is still a redirection"
# `&>` and `&>>` are single operators that apply MID-WORD — bash ends the word at the `&`.
# Leaving it attached reconstructed the receiver as `sh&`, which matches no shell name.
assert_block "sh&>out <<< '$HELPER'"           "a combined &> does not stay attached to the receiver name"
assert_block "bash&>>out <<< '$HELPER'"        "...and neither does &>>"
# A QUOTE THAT OPENS MID-WORD AND SPANS A SPACE. This is why the walk stopped using shlex
# for grouping as well as for operators: non-posix shlex does not carry quote state across
# whitespace, so `x'a b'` came back as `x'a` and `b'`. Only half the operand was skipped,
# `b` took command position, and the `.` that sources the payload was never tested.
assert_block "<<< x'a b' . /dev/stdin <<< '$HELPER'" \
    "a quote opening mid-word groups the whole operand (single)"
assert_block "<<< x\"a b\" . /dev/stdin <<< '$HELPER'" \
    "...and the double-quoted form"
# ...and the same grouping must not swallow a data payload's spaces into a receiver.
assert_ok "cat <<< 'a b $HELPER'"              "a quoted payload with spaces is still data"
# WORD SEPARATORS ARE BASH'S, NOT PYTHON'S. `str.isspace()` is Unicode-aware and bash is
# not: a no-break space is an ordinary character to the shell, so this is one operand —
# but it split the word, promoted the tail to command position, and hid the `.`.
# ANSI-C QUOTING is unresolvable here and therefore blocks. Inside `$'...'` a backslash
# escapes and an escaped quote does NOT end the string; inside plain `'...'` it does. The
# `$` that tells them apart is dropped by `_norm_for_scan` upstream — deliberately, for the
# shlex-based callers — so this scan sees identical bytes. Guessing was measured: reading it
# as a plain quote ended the string early, left the rest of the command inside apparent
# quotes, made the REAL `<<<` look quoted, and the segment was skipped with the payload
# unscanned. The over-block this costs is a payload ending in a backslash.
assert_block "bash -s \$'x\\'y' <<< '$HELPER' \\'" \
    "an ambiguous ANSI-C quote blocks rather than ending the string early"
# COMMENTS. `_defuse_comments` upstream blanks only the SEPARATOR characters inside a
# comment and deliberately leaves every other byte, so a `<<<` written in one arrives here
# intact. Read as an operator it turned a command that runs no here-string into a shell
# receiving one. A `#` mid-word is NOT a comment, and a comment after a real here-string
# does not undo it.
assert_ok "bash -c true # <<< '$HELPER'"       "a here-string inside a comment is not a here-string"
assert_block "sh a#b <<< '$HELPER'"            "a mid-word # is an ordinary character"
assert_block "sh <<< '$HELPER' # comment"      "a trailing comment does not undo a real here-string"
_nbsp=$(printf '\u00a0')
assert_block "<<< x${_nbsp}y . /dev/stdin <<< '$HELPER'" \
    "a no-break space does not split a here-string operand"
# ...and the join must be over CONTIGUOUS RUNS, not the whole word list: joining
# everything only recognises a fragmented shell with no arguments (`'b''a''s''h' -s`
# joins to `bash-s` and matched nothing), and a fragmented name need not be first.
assert_block "'b''a''s''h' -s <<< '$HELPER'"   "fragmented shell name with an argument"
assert_block "env 'b''a''s''h' <<< '$HELPER'"  "fragmented shell name after a wrapper"
# ...and adjacency comes from the RAW TEXT, not from a run of shlex tokens. Two attempts to
# infer it from the token list alone failed in OPPOSITE directions, and both are pinned
# here because either one is reintroduced by "simplifying" the walk back onto tokens.
#   A CAPPED RUN WAS THE BYPASS. Empty quoted fragments are free padding and the caller
#   chooses how many, so any fixed window is a spelling instruction: at a 10-token cap,
#   twelve `''` between `'s'` and `'h'` pushed the `h` out of every window and the
#   here-string ran a shell while the classifier returned OK. Raising the cap only moves
#   it, which is why the cap is gone rather than larger — 40 is here to say so.
# Built with a loop rather than `printf ... $(seq ...)`: the nested substitution masks
# seq's return value (SC2312), and this file is shellcheck-clean by policy.
_pad12=""; _pad40=""
for _n in $(seq 1 40); do
    _pad40="$_pad40''"
    if [[ $_n -le 12 ]]; then _pad12="$_pad12''"; fi
done
assert_block "'s'${_pad12}'h' <<< '$HELPER'" \
    "empty fragments do not push a shell name out of reach (was OK at a 10-token cap)"
assert_block "'s'${_pad40}'h' <<< '$HELPER'" \
    "...and no larger cap is hiding behind it either"
#   AN UNCAPPED RUN OVER-BLOCKS. Joining every neighbouring token invents words bash never
#   forms, because whitespace is exactly what the token list discarded.
assert_ok "cat ba s h <<< '$HELPER'" \
    "separate arguments are not fragments of one command word"

# PERFORMANCE IS A CORRECTNESS PROPERTY HERE: the hook's timeout writes no decision, which
# reads as ALLOW, so a slow scanner is itself a fail-open.
#
# THE BOUND IS 2s, NOT THE 5s HOOK TIMEOUT, and it is measured in MILLISECONDS. The 5s
# expiry is why speed matters here, but it is useless as a threshold: every regression
# these two cases exist to catch lands under it — the span-limited widening took 3.36s on
# the nested input below and would have passed a 5s assertion unchanged. The bound sits
# below the measured regressions and far above the healthy path, which classifies both
# inputs in 0.07s. Whole-second `date` was also too coarse to state that gap: the healthy
# disjoint case straddled a second boundary and reported 1s.
#
# BOTH BOUNDS ASSERT THE VERDICT, not just the clock. They did not, and both were VACUOUS
# because of it: sized at 1000 compounds they blew the classifier's own 4000-token budget,
# returned BLOCK_UNSCANNABLE in 0.0s without ever reaching the widening path, and passed a
# time-only assertion while measuring nothing. A benchmark that certifies a bail-out is
# worse than no benchmark. Both are now sized UNDER that budget so the path actually runs,
# and both require OK — the verdict these inputs must produce.
#
# (a) DISJOINT compounds. Widening once appended the whole command PER reserved-only
#     segment, which is quadratic: measured at 8.88s before the answer was widened once
#     and memoized.
_big=""
for _i in $(seq 1 400); do _big="$_big; if true; then cat; fi <<< 'x'"; done
# `cat`, NOT `sh`: the positive path stops at the first receiver it finds, so a benchmark
# built on `sh` exercises one scan and misses the slow path entirely. The NEGATIVE path is
# the quadratic one — it was ~23s before the compound answer was memoized.
assert_parses "${_big#; }" "the disjoint benchmark is valid shell"
_t0=$(_now_ms)
_got=$(verdict "${_big#; }")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "OK|" ]]; then
    ok "400 disjoint data-only compounds classify OK in under 2s ($((_t1 - _t0))ms)"
else
    no "400 disjoint data-only compounds classify OK in under 2s" "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
# (b) NESTED compounds — a different shape, and the one that killed the span-limited
#     widening. Scanning only the owning compound's span is more precise, but each closer
#     then rebuilds its own span and spans grow with nesting depth: THIS input took 3.36s
#     under it, against 0.07s for the whole-command answer that shipped. The bound is a
#     regression guard on that revert, not a restatement of the disjoint case above.
_nest="cat"
for _i in $(seq 1 300); do _nest="if true; then $_nest; fi <<< 'x'"; done
assert_parses "$_nest" "the nested benchmark is valid shell"
_t0=$(_now_ms)
_got=$(verdict "$_nest")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "OK|" ]]; then
    ok "300 nested data-only compounds classify OK in under 2s ($((_t1 - _t0))ms; 3360ms under span-limited widening)"
else
    no "300 nested data-only compounds classify OK in under 2s" "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
# (9) LINE CONTINUATION. bash removes an unquoted backslash-newline BEFORE it recognises
#     operators, so both the operator and the receiver name can be split across lines and
#     lexed as unrelated fragments. Raised by the deep PR-mode pass.
assert_block "sh <<\\
< '$HELPER'"                                   "operator split by a line continuation"
assert_block "ba\\
sh <<< '$HELPER'"                              "receiver name split by a line continuation"

# ADJACENT FRAGMENTS IN THE OPERAND. bash concatenates `'x'\"bash\"` into ONE redirection
# target while shlex emits two tokens, so skipping a single token left the stray `\"bash\"`
# among the command words and `cat` read as a shell. This was an ACCEPTED OVER-BLOCK for a
# while, because the obvious repair — absorb any quoted token following an operand — could
# not tell the adjacent FRAGMENT `'x'\"bash\"` from the separate WORD `'x' 'bash'`, so it
# swallowed the real receiver and traded the over-block for a FAIL-OPEN.
# Measuring adjacency in the RAW TEXT tells them apart, so the whole operand run is skipped
# and BOTH sides are now correct. Both are pinned, because a repair that fixes only the
# first one is the fail-open this note is about.
assert_ok "cat <<< '$HELPER; '\"bash\""        "an adjacent fragment of the operand is not a command word"
assert_block "<<< '$HELPER' sh"                "...and a SEPARATE word after the operand still is"
assert_block "<<< '$HELPER'\"; \" . /dev/stdin" \
    "...and a fragmented operand does not hide the dot behind it"
# ...and the operand run stops at an OPERATOR, not only at whitespace. A metacharacter
# delimits without needing whitespace, so a second redirection can sit flush against the
# first one's operand; extending the run over it swallowed the operator, promoted the
# redirection TARGET to command position, and hid the dot that sources the payload.
assert_block "<<<x< /dev/null . /dev/stdin <<< '$HELPER'" \
    "a flush second redirection is an operator, not more operand"
# INSIDE AN EXPANSION nothing is a word break and nothing is an operator. `${x:-a b > y}`
# is ONE operand to bash, but scanned flat the word ended at the space, `b` took command
# position, the `>` read as a real redirection and `y}` as its target — so the `.` that
# sources the payload was never in command position and the here-string ran unscanned.
assert_block "<<< \${x:-a b > y} . /dev/stdin <<< '$HELPER'" \
    "a parameter expansion is one operand, spaces and operators included"
assert_block "<<< \$(echo a b) . /dev/stdin <<< '$HELPER'" "...a command substitution too"
assert_block "<<< \$((1 + 2)) . /dev/stdin <<< '$HELPER'"  "...and arithmetic, which opens twice"
# An UNTERMINATED expansion is unresolvable and blocks, like unterminated quoting.
assert_block "<<< \${x:-a . /dev/stdin <<< '$HELPER'" "an unterminated expansion blocks"
# ...and the closer is only recognised where the shell would recognise it. The escape and
# quote states are handled BEFORE the expansion state, so an escaped or quoted delimiter is
# consumed as ordinary text and never pops the nesting — otherwise the scan would resume
# outer-shell tokenizing mid-expansion and hide the receiver behind it.
assert_block "<<< \$(printf \\) a b > y) . /dev/stdin <<< '$HELPER'" \
    "an escaped delimiter does not close a command substitution"
assert_block "<<< \$(printf ')' a b > y) . /dev/stdin <<< '$HELPER'" \
    "...nor a quoted one"
assert_block "<<< \$(case x in x) cat;; esac) . /dev/stdin <<< '$HELPER'" \
    "...and a case pattern inside one still leaves the receiver visible"
# The ORDER of the scan's states is what guarantees that, and it is asserted here because
# it reads as an implementation detail: the escape and quote branches sit ABOVE the
# expansion branch, so an escaped or quoted delimiter is consumed as text and never reaches
# the pop. A brace form is included because `}` and `)` take different paths in.
assert_block "<<< \${x:-\\} a b > y} . /dev/stdin <<< '$HELPER'" \
    "an escaped brace does not close a parameter expansion"
assert_block "<<< \${x:-'}' a b > y} . /dev/stdin <<< '$HELPER'" \
    "...nor a quoted one"
# A literal brace inside an expansion pushes a level that never closes. That is not a
# bypass: an unterminated stack is unresolvable, and unresolvable blocks.
# Only `$(` and `${` open a level. Treating every bare `(`/`{` as nesting was wrong twice:
# bash permits a LITERAL brace inside an expansion, so `$(printf {)` pushed a level the real
# `)` could not close — and a later `}` elsewhere in the command could DRAIN that level,
# resuming outer tokenizing at the wrong place rather than failing closed.
assert_block "<<< \$(printf {) . /dev/stdin <<< '$HELPER'" \
    "a literal brace inside an expansion is not a nesting level"
assert_block "<<< \$(printf {) . /dev/stdin <<< '$HELPER'; case x in x}x) true;; esac" \
    "...and a later delimiter cannot drain one to hide the receiver"
assert_block "<<< \$(echo \$(echo a) b) . /dev/stdin <<< '$HELPER'" \
    "a genuinely nested substitution still closes at the right paren"
assert_block "( { <<< \$(printf {) . /dev/stdin <<< '$HELPER'; } )" \
    "...and the same inside grouping"
# A COMMAND SUBSTITUTION IN OPERAND POSITION IS NOT A RECEIVER, and this is measured
# against bash rather than reasoned about: expansion happens BEFORE the command's
# redirections are applied, so the substitution inherits the SHELL's stdin, never the
# here-string. Verified directly —
#   bash -c 'printf "[%s]" "$(cat)" <<< hello' </dev/null   -> []
#   printf fromstdin | bash -c 'printf "[%s]" "$(cat)" <<< hello' -> [fromstdin]
# — so a shell named inside an operand substitution cannot execute the payload.
assert_ok "true <<< \"$HELPER\" <<< \$(bash)" \
    "a substitution in operand position does not receive the here-string"
# ...and anywhere OTHER than operand position it is an unresolved command word, which is
# fail-closed for exactly the reason this file gives: an expansion may resolve onto a shell.
assert_block "cat <<< '$HELPER' \$(bash)"       "...but a substitution as a WORD is unresolved, and blocks"
# A `case` pattern's `)` does close the scanner's expansion level early — bash would not —
# but that is not what decides these. The SAME over-block happens with no `case` anywhere:
# a substitution sitting in a word is an unresolved command word, which is fail-closed
# because an expansion may resolve onto a shell. Both are pinned so the pair stays visible.
assert_block "true <<< \$(case x in x) bash;; esac) <<< '$HELPER'" \
    "a shell inside a substitution over-blocks (accepted)"
assert_block "true <<< \$(echo bash) <<< '$HELPER'" \
    "...and identically with no case pattern, so the early close is not the cause"
# Expansions stay active INSIDE DOUBLE QUOTES, and a substitution carries its own quoting
# context: `"$(printf "a b")"` is one word, and ending the outer quote at the INNER one
# resumed outer tokenizing mid-expansion.
assert_block "<<< \"\$(printf \"a b > y\")\" . /dev/stdin <<< '$HELPER'" \
    "a substitution inside double quotes keeps its own quoting context"
assert_block "<<< \"\${x:-a b}\" . /dev/stdin <<< '$HELPER'" "...and a quoted parameter expansion"
# The opener routine is SHARED by all three states — ordinary, inside double quotes, and
# inside another expansion. They had separate copies and the copies disagreed: only the
# outer one knew `$((` opens TWICE, so an arithmetic expansion nested in a command
# substitution pushed one level and its `))` popped the substitution too. Backticks were
# not tracked at all, so their spaces and operators reached the outer tokenizer.
#
# PROPERTY — the invariant behind every case above: tokenization never exposes a word or an
# operator from INSIDE an expansion. Each operand below is ONE word to bash however much
# whitespace, punctuation or quoting it contains, so the `.` after it is always the command
# and the final here-string is always sourced. If any spelling leaks, the `.` stops being
# in command position and this returns OK.
_xp_n=0
for _x in "\${x:-a b > y}" "\$(printf \"a b > y\")" "\$((1 + 2))" "\$(echo \$(echo a) b)" \
          "\"\$(printf \"a b\")\"" "\${x:-'}'}" "\$(printf {)" "\${x:-a;b|c&d}" \
          "\$(echo a | grep b)" "\"\${x:-a b}\"" \
          "\$(echo \$((1 + 2)) a b > y)" "\`echo a b > y\`" "\"\`echo a b\`\"" \
          "\`echo \$(echo a) b\`"; do
    _xp_n=$((_xp_n + 1))
    _got=$(verdict "<<< $_x . /dev/stdin <<< '$HELPER'")
    if [[ "$_got" != BLOCK_* ]]; then
        no "property: no word or operator escapes an expansion" "<<< $_x — got=${_got:-<empty>}"
        _xp_n=-1; break
    fi
done
if [[ $_xp_n -gt 0 ]]; then
    ok "property: no word or operator escapes an expansion ($_xp_n)"
fi
# ...and the same expansions in a DATA payload are still read as data.
_xd_n=0
for _x in "\$(echo hi)" "\${x:-a b}" "\$((1 + 2))" "\`echo hi\`"; do
    _xd_n=$((_xd_n + 1))
    _got=$(verdict "cat <<< \"$_x\"")
    if [[ "$_got" != "OK|" ]]; then
        no "property: an expansion in a data payload is still a read" "cat <<< $_x — got=${_got:-<empty>}"
        _xd_n=-1; break
    fi
done
if [[ $_xd_n -gt 0 ]]; then
    ok "property: an expansion in a data payload is still a read ($_xd_n)"
fi
# THE TERMINATOR behind that property, asserted directly. Every leak in this walk had one
# shape — the scan mis-decides where an expansion ends, a word or operator escapes it, and
# the command that would have been in receiver position is hidden. Review found one per
# round (`${}`, `$()`, `$(())` nested in `$()`, backticks, `$[`, a `(` group inside `$()`),
# and each fix exposed the next construct. So the scan's ALLOW side is no longer trusted on
# its own: if the command opens a structured expansion ANYWHERE and the receiver test came
# back empty, the whole command is probed instead. No future expansion syntax can turn that
# into a fail-open, because the answer stops depending on parsing the expansion correctly.
# The check is whole-COMMAND because `_split_with_ops` tears an expansion containing `;`,
# `|` or `&` across segments, leaving the here-string segment with no opener in it.
_term_n=0
for _cmd in "<<< \$[1 + 2 > 0] . /dev/stdin <<< '$HELPER'" \
            "< \${BASH:-a;b|c&d} . /dev/stdin <<< '$HELPER'" \
            "<<< \"\$( (echo); printf \"a b > y\" )\" . /dev/stdin <<< '$HELPER'" \
            "cat <<< \"\$(date) $HELPER\""; do
    _term_n=$((_term_n + 1))
    _got=$(verdict "$_cmd")
    if [[ "$_got" != BLOCK_* ]]; then
        no "property: an expansion downgrades \"no receiver\" to \"unknown\"" "$_cmd — got=${_got:-<empty>}"
        _term_n=-1; break
    fi
done
if [[ $_term_n -gt 0 ]]; then
    ok "property: an expansion downgrades \"no receiver\" to \"unknown\" ($_term_n)"
fi
# ...and the over-block it costs needs BOTH halves. Either one alone still reads as data.
assert_ok "cat <<< \"\$(echo hi)\""             "an expansion with no helper named is still a read"
assert_ok "cat <<< '$HELPER'"                  "a helper named with no expansion is still a read"
# ...and the "is there an expansion" test is QUOTE-AWARE, taken from the scan rather than
# from a substring search. A substring test cannot tell an active expansion from the same
# characters written inside single quotes, and it widened a plain data read where bash
# expands nothing at all.
assert_ok "cat <<< '$HELPER literal \$('"       "a literal \$( inside single quotes is not an expansion"
assert_ok "cat <<< '$HELPER literal \`'"        "...nor a literal backtick"
# ...and a COMMENT LINE in front of the command does not disarm the terminator. The
# terminator asks its question of the whole command, which it rebuilds by rejoining the
# segments -- and `_norm_for_scan` has already turned the command's own newlines into
# " ; " by then, so rejoining on " ; " too produced ONE LINE. `_shell_pieces` tracks
# comments, so the first `#` then ran to the end of everything and the scan reported no
# expansion at all: a one-line preface turned a BLOCK into an OK. Rejoining on a newline
# restores the line boundary the comment needs. Raised by codex on this change.
assert_block "# preface
< \${BASH:-a;b|c&d} . /dev/stdin <<< '$HELPER'" \
    "a comment line does not swallow the rest of the expansion scan"
# ...and it does not go the other way either: the comment must not manufacture an
# expansion where the command has none, or every prefaced data read would over-block.
assert_ok "# preface
cat <<< '$HELPER literal \$('" \
    "...and a comment line does not over-block a prefaced data read"
# `x<(y` as a separate WORD still blocks, and did before any of this: a `(` makes a command
# word unresolved, which is fail-closed because an expansion may resolve onto a shell.
assert_block "cat <<< '$HELPER' 'x<(y'"        "pre-existing: a paren in a word is an unresolved command word"
# ...and the cost of reaching that scan is BOUNDED, which is a CORRECTNESS property here
# for the reason the benchmarks above already state: the hook's 5s timeout writes no
# decision, which reads as ALLOW, so a slow classifier is itself a fail-open.
#
# The shape that broke it, raised by codex on this change: `echo <20000 empty quoted
# arguments>` -- a valid 60KB command. _shell_variants strips the quote characters to model
# what bash resolves, which turns those arguments into a 20001-character run of spaces, and
# _INDIRECTION_RE's `\s*` backtracks across that run from every start position. ONE search
# of ONE such variant measured 980ms against 6ms for the same search of the raw text, and
# the guard asks for the variants eleven times: 4.05s total, 3.97s of it inside those
# searches, straight through the timeout. The verdict at the end was BLOCK_UNSCANNABLE --
# fail-closed -- but a verdict that arrives after the hook has given up is not a verdict.
#
# PRE-EXISTING, and measured as such rather than assumed: the same input took 4.11s at the
# merge-base and 4.97s on origin/main, both without any of this ticket's changes. Collapsing
# each whitespace run in the stripped variant (keeping a newline if the run had one, since
# _INDIRECTION_RE reads `\n` as a separator) removes the backtracking without changing a
# single verdict -- 4.58s to 0.16s here, and every case below classifies as it did before.
#
# BOTH SIDES ASSERT THE VERDICT, not just the clock, for the reason given at those
# benchmarks: a time-only assertion passes just as happily on a bail-out that measured
# nothing. And the sizes sit either side of the classifier's 4000-token budget WITH MARGIN
# -- 1000 filler words still classify, 2000 are already refused -- so neither case is one
# tuning change away from silently swapping which path it measures.
#
# What this does NOT claim: that the whole-command expansion scan is lazy. Laziness is real
# (the answer is computed at most once, and only when a segment reaches the fallback) but it
# is not observable on a clock, because no command under the token budget is slow enough to
# separate the two. Asserting it here would be a vacuous bound.
_filler() { python3 -c 'import sys;print(" ".join("a%d" % i for i in range(int(sys.argv[1]))))' "$1"; }
_scan_cmd="cat <<< 'x' ; echo \$(a) $(_filler 700)"
assert_parses "$_scan_cmd" "the bounded-scan benchmark is valid shell"
_t0=$(_now_ms)
_got=$(verdict "$_scan_cmd")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "OK|" ]]; then
    ok "a 700-word command reaching the expansion scan classifies OK in under 2s ($((_t1 - _t0))ms)"
else
    no "a 700-word command reaching the expansion scan classifies OK in under 2s" \
        "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
_over_cmd="cat <<< 'x' ; echo \$(a) $(_filler 5000)"
_t0=$(_now_ms)
_got=$(verdict "$_over_cmd")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "BLOCK_UNSCANNABLE|" ]]; then
    ok "...and one past the token budget is refused fail-closed, still fast ($((_t1 - _t0))ms)"
else
    no "...and one past the token budget is refused fail-closed, still fast" \
        "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
# The quote-run case itself. 20000 rather than the 15000 codex measured: the bound has to
# sit clear of BOTH sides, and 15000 took 2.3s before the fix against a 2s bound -- too
# close to call a regression. 20000 took 4.58s before and 0.16s after.
_quote_cmd="echo $(python3 -c 'print("'"''"' " * 20000)')"
assert_parses "$_quote_cmd" "the quote-run benchmark is valid shell"
_t0=$(_now_ms)
_got=$(verdict "$_quote_cmd")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "BLOCK_UNSCANNABLE|" ]]; then
    ok "20000 empty quoted arguments classify in under 2s ($((_t1 - _t0))ms; 4580ms before the run collapse)"
else
    no "20000 empty quoted arguments classify in under 2s" "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
# ...and the run WRITTEN OUT, not created by stripping quotes, which is the sharper half:
# the collapse first landed on the stripped variants only, and `echo a<20000 spaces>b` --
# whose run is in the text as typed -- still took 4.34s at 20KB and 16.4s at 40KB. Worse
# than the case above, because it ends in OK rather than BLOCK_UNSCANNABLE, so the slow
# path and the verdict point the same way. Raised by codex on this change. The bound is
# asserted at 40000, where the pre-fix cost was 16.4s against 0.08s after -- no ambiguity
# about which side of a 2s line either sits on.
_ws_cmd="echo a$(python3 -c 'print(" " * 40000)')b"
_t0=$(_now_ms)
_got=$(verdict "$_ws_cmd")
_t1=$(_now_ms)
if [[ $((_t1 - _t0)) -lt 2000 && "$_got" == "OK|" ]]; then
    ok "a 40000-character literal whitespace run classifies OK in under 2s ($((_t1 - _t0))ms; 16400ms before the collapse)"
else
    no "a 40000-character literal whitespace run classifies OK in under 2s" \
        "took $((_t1 - _t0))ms, got=${_got:-<empty>}"
fi
# PROCESS SUBSTITUTION is an expansion too: `<(cmd)` is one word and its `<` is NOT a
# redirection. Read as one, `(cmd` became the target and the rest of the operand tokenized
# as outer text. It is tested before the redirection regex, and a plain `<` still redirects.
assert_block "<<< <(printf x) . /dev/stdin <<< '$HELPER'" \
    "a process substitution is one word, not a redirection"
assert_block "<<< >(cat) . /dev/stdin <<< '$HELPER'" "...the output form too"
assert_ok "cat <(echo hi) <<< 'plain'"         "...and it does not make an ordinary read block"
assert_ok "cat < /dev/null <<< 'plain'"        "a plain < is still a redirection"
# ...and NOT inside double quotes, unlike `$(` and backticks: bash performs no process
# substitution there, so `"x<(y"` is literal text. Opening a level for it pushed a `)` the
# string never closes, and a later quoted `)` anywhere in the command closed it instead —
# swallowing the command in between, which is how the dot below went missing.
assert_block "A=\"x<(y\" . /dev/stdin <<< '$HELPER' \")\"" \
    "a quoted <( is literal text, not a process substitution"
assert_block "<<< \$(cat <(echo a) b > y) . /dev/stdin <<< '$HELPER'" \
    "...but an unquoted one nested in a substitution still groups"
# `time` after a wrapper is an external command, at every depth — the peel is gated on
# pipeline-prefix position, so a second `time` behind `env` is never treated as a keyword.
assert_ok "time env time . /dev/stdin <<< '$HELPER'" \
    "a second time behind a wrapper is not peeled as a keyword"
# PROPERTY over the class those three cases sample. The operand walk and the operator test
# now disagree about a token in three different ways — whitespace, adjacency, and escaping
# — and each disagreement hides the COMMAND behind the operand rather than the operand
# itself. So: whatever the operand is spelled like, a `.`/`source` that follows it is still
# in command position and still sources the here-string payload. Every combination blocks.
_prop_n=0
for _operand in "'x'" "'x'\"y\"" "x" "x\\<" "'x'\\ y" "x'<'"; do
    for _cmd in ". /dev/stdin" "source /dev/stdin"; do
        _prop_n=$((_prop_n + 1))
        _got=$(verdict "<<< $_operand $_cmd <<< '$HELPER'")
        if [[ "$_got" != BLOCK_* ]]; then
            no "property: operand spelling never hides the command behind it" \
                "<<< $_operand $_cmd — got=${_got:-<empty>}"
            _prop_n=-1
            break 2
        fi
    done
done
if [[ $_prop_n -gt 0 ]]; then
    ok "property: operand spelling never hides the command behind it ($_prop_n)"
fi
# THE SAME PROPERTY FROM THE ALLOW SIDE, over quoting and escape spellings of the payload.
# This is the direction that actually broke: the escaped-metacharacter terminator above was
# first written quote-BLIND, so a backslash inside single quotes — where bash treats it as
# literal data — was read as an active escape and `cat` stopped being a data receiver. A
# block-side matrix cannot catch that; only asserting the allow contract can.
_prop_ok=0
for _payload in "'$HELPER'" "\"$HELPER\"" "'$HELPER \\;'" "'$HELPER'\"; x\"" "'$HELPER \\< \\| \\&'" "'$HELPER'\\ x"; do
    for _recv in "cat" "cat /dev/null" "grep -f -"; do
        _prop_ok=$((_prop_ok + 1))
        _got=$(verdict "$_recv <<< $_payload")
        if [[ "$_got" != "OK|" ]]; then
            no "property: a non-executing receiver reads any payload spelling as data" \
                "$_recv <<< $_payload — got=${_got:-<empty>}"
            _prop_ok=-1
            break 2
        fi
    done
done
if [[ $_prop_ok -gt 0 ]]; then
    ok "property: a non-executing receiver reads any payload spelling as data ($_prop_ok)"
fi
# The fail-open that absorption caused, pinned so it cannot return.
assert_block "sh <<< '$HELPER' 'bash'"         "a separately quoted receiver after the operand is not part of it"
assert_block "env <<< '$HELPER' 'bash'"        "same through a wrapper"

# UNPARSEABLE COMMAND. An unterminated quote is handled OUTSIDE this walk: _split_with_ops
# returns ok=False and _helper_invoked probes the WHOLE command instead. Verified directly
# rather than assumed — an earlier version of this file asserted the same command as
# evidence that the walk's own ValueError branch fails closed, which was VACUOUS: the
# command never reaches that branch. It is kept as a real assertion about the outer path.
assert_block "sh <<< '$HELPER"                 "an unparseable command is probed whole (outer path)"

# INNER LEXER FAILURE still fails CLOSED — but this pair no longer reaches it. Adjacent
# quoting like a'<<<' is VALID and only `punctuation_chars=True` choked on it; once
# operator splitting moved out of the lexer and into the quote-aware `_shell_pieces`, the
# lexer keeps the one job it does correctly and this parses. Both spellings stay pinned,
# because they are the pair a future change trades against each other: skipping an
# unlexable segment let the first execute UNSCANNED, and appending it blocked the second,
# which carries no here-string at all. Getting the quoting right is what makes both right.
assert_ok "echo a'<<<' $HELPER"                "a quoted <<< beside adjacent quoting is no here-string"
assert_block "bash -s <<< '$HELPER' a'<<<'"    "a real here-string beside a quoted decoy still blocks"

# UNRESOLVABLE OPERAND. The scanner cannot see what \$VAR holds, so the operand cannot be
# scanned on its own. Treated exactly as the existing `-` / /dev/fd/N branch treats a
# descriptor it cannot resolve: widen the scan to the WHOLE command. Here the helper is
# named elsewhere in the same command, so the widened scan finds it.
assert_block "sh <<< \"\$VAR\" # $HELPER"      "unresolvable operand widens the scan to the whole command"

# ── B. data: the receiver does not execute its stdin ──────────────────────────────────
# `cat` writes its input out; the payload is prose that happens to name the helper.
assert_ok "cat <<< 'prose mentioning $HELPER'" "here-string into a non-executing receiver is data"
# The operator is ordinary text here, not a redirection. Non-regression for #573: a
# generic pattern in structureless text is not evidence.
assert_ok "echo 'a <<< b is a here-string'"    "the operator named in prose is not a redirection"
# A QUOTED `<<<` is an ARGUMENT, not an operator. posix shlex strips the quotes that say
# so, and an early version of this fix read the argument as a redirection and blocked a
# command carrying no here-string at all. Raised in review on this PR. The fix takes the
# EXISTENCE of a bare operator from `_shell_pieces`, whose own quote-aware scan knows
# which `<<<` was written bare without needing the quotes stripped off it first.
assert_ok "echo '<<<' '$HELPER' sh"            "a quoted <<< argument is not a here-string"

# PROPERTY: a quoted redirection-shaped ARGUMENT must never change the verdict of a
# segment that also carries a REAL here-string. Fixed examples missed this: an early fix
# tested only whether SOME bare `<<<` existed, so a quoted `'<<<'` earlier in the segment
# was taken for the operator and CONSUMED the real one as its target — the payload
# scanned was `<<<` and the helper went unseen. Both orderings and several operator
# shapes are combined here because the bug was positional, not shape-specific.
_prop_pass=0
_prop_fail=0
for _q in "'<<<'" "'>'" "'<'" "'>>'" "'2>'"; do
    for _tmpl in "bash -s %s <<< '%s'" "bash -s <<< '%s2' %s" "env -u %s bash <<< '%s'"; do
        case "$_tmpl" in
            *"%s2"*) _cmd="bash -s <<< '$HELPER' $_q" ;;
            "env"*)  _cmd="env -u $_q bash <<< '$HELPER'" ;;
            *)       _cmd="bash -s $_q <<< '$HELPER'" ;;
        esac
        # Invoked separately rather than inside the test, so the command's own return
        # value is not masked (shellcheck SC2312).
        _got="$(verdict "$_cmd")"
        if [[ "$_got" == BLOCK_* ]]; then
            _prop_pass=$((_prop_pass + 1))
        else
            _prop_fail=$((_prop_fail + 1))
            printf '    quoted-operator bypass: %s\n' "$_cmd"
        fi
    done
done
if [[ "$_prop_fail" -eq 0 ]]; then
    ok "property: a quoted redirection-shaped argument never hides a real here-string ($_prop_pass)"
else
    no "property: a quoted redirection-shaped argument never hides a real here-string" \
       "$_prop_fail of $((_prop_pass + _prop_fail)) combinations allowed"
fi

# ── C. measured residuals ─────────────────────────────────────────────────────────────
# Bare unresolvable operand with the helper named NOWHERE in the command. The widened
# scan finds nothing, so this allows — and that is correct, not a gap: it is the same
# answer the `-` / /dev/fd/N branch gives, whose own comment states the reason ("what
# stdin carries is not statically visible -- it arrives by redirect, by pipe from an
# earlier segment, or by heredoc"). Blocking it would require refusing every command with
# an unresolved variable anywhere near a shell. Pinned so the residual stays visible.
assert_ok "sh <<< \"\$VAR\""                   "bare unresolvable operand allows (documented residual)"
# REAL HEREDOC, measured here rather than assumed. cmdword.py records `bash <<EOF` as a
# KNOWN RESIDUAL its tokenizer cannot reach, because there the delimiter word sits where
# the payload would. This file is different and the difference is measured: the
# newline->";" normalization in _writes_marker turns the heredoc BODY into ordinary
# segments, so the body is scanned and this blocks today. Pinned as the observed
# behaviour of THIS module — do not copy the sibling's residual wording across.
assert_block "sh <<EOF
$HELPER
EOF" "real heredoc body is scanned by this module (differs from cmdword's residual)"

# -- D. grammar is EXACT and BARE, not a basename ------------------------------------
# Bash decides which words are syntax BEFORE quote removal, and matches them literally.
# Both halves of this were being decided on the basename of the DECODED word, which
# called three different things the same: the keyword, a quoted program that spells it,
# and a path that ends in it. Each pair below is the same word bare (syntax, still
# blocked) and dressed (an ordinary external command, and now allowed).
#
# These are OVER-blocks, so every one of them allows something that was refused. That is
# the direction this module normally refuses to move in, so each is paired with the bare
# spelling it must NOT loosen -- and all eight were run against the parent commit, where
# the four allows fail and the four blocks are unchanged.

# The wrapper peel re-skipped reserved words on the basename, undoing the raw-aware
# check its own caller had just made.
assert_ok    "'then' . /dev/stdin <<< '$HELPER'" \
    "a QUOTED reserved word is an external command, so the dot behind it sources nothing"
assert_block "then . /dev/stdin <<< '$HELPER'" \
    "...but the BARE keyword still hides a real dot (the pair that must not loosen)"

# Assignment recognition has the same before-quote-removal rule: the name and the `=`
# must both be unquoted, while the VALUE may be quoted freely.
assert_ok    "FOO\"=\"bar . /dev/stdin <<< '$HELPER'" \
    "a quoted = is not an assignment, it names a program called FOO=bar"
assert_block "FOO=bar . /dev/stdin <<< '$HELPER'" \
    "a real assignment is still stepped over to reach the dot"
assert_block "FOO=b\"a\"r . /dev/stdin <<< '$HELPER'" \
    "a quoted VALUE leaves it an assignment (only the name and = decide)"

# The compound-widening trigger read `'fi'` and `./fi` as syntax, widened to the whole
# command, and let an unrelated `sh` in an earlier segment block a data-only read.
assert_ok    "echo sh; 'fi' <<< '$HELPER'" \
    "a quoted fi is an external command, so there is no compound to widen to"
assert_ok    "echo sh; ./fi <<< '$HELPER'" \
    "a PATH ending in fi is a program, not a compound terminator"
assert_block "if true; then sh; fi <<< '$HELPER'" \
    "the real compound still widens and finds the shell (the pair that must not loosen)"

# ...and the spellings must survive the `time` peel, not stop at it. `_strip_time_prefix`
# REMOVES tokens, so an index-parallel raw list stops lining up unless it is filtered the
# same way. Dropping it there instead silently restored the basename reading for every
# word behind a `time` -- the fix above, undone one line later.
assert_ok    "time 'then' . /dev/stdin <<< '$HELPER'" \
    "a quoted reserved word behind time is still an external command"
assert_ok    "time FOO\"=\"bar . /dev/stdin <<< '$HELPER'" \
    "...and a quoted = behind time is still not an assignment"
assert_block "time then . /dev/stdin <<< '$HELPER'" \
    "the bare keyword behind time still hides a real dot"
assert_block "time FOO=bar . /dev/stdin <<< '$HELPER'" \
    "...as does a real assignment (the pair that must not loosen)"

printf '\n%s: %d passed, %d failed\n' "$(basename "${BASH_SOURCE[0]}")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
