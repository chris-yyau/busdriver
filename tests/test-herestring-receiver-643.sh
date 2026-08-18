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
# (7) ESCAPED command word. Squeezing quotes alone left `b\a\s\h` matching no name; the
#     receiver normalization squeezes escapes too.
assert_block "b\\a\\s\\h <<< '$HELPER'"        "escaped command word still resolves to a shell"
# (8) ATTACHED OPTION BUNDLE. Peeling one option letter off `-iSbash` leaves `Sbash`, and
#     peeling a fixed number never terminates because the caller chooses the bundle
#     length — so the producer tests an endswith over the names, and this mirrors it.
#     The pipe spelling of this already blocked; the transports must not diverge.
assert_block "env -iSbash <<< '$HELPER'"       "attached option bundle resolves to a shell"

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
# EXISTENCE of a bare operator from a non-posix pass, which keeps quotes on the token.
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

printf '\n%s: %d passed, %d failed\n' "$(basename "${BASH_SOURCE[0]}")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
