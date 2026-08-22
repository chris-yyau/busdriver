#!/usr/bin/env bash
# Regression test for #643 -- a here-string feeding a shell executes its operand, so the
# operand is a PROGRAM and must be scanned as one.
#
# `sh <<< '<helper>'` returned OK while the equivalent pipe spelling
# `echo '<helper>' | sh` returned BLOCK -- the same invocation, one transport apart.
# `_piped_shell_producers` yields the text feeding a pipeline STAGE; a here-string has no
# producer stage, because the payload is the operand of `<<<` on the receiver's own
# command line, so nothing was yielded and the payload was never scanned. The guard is
# UNCONDITIONAL (it blocks whether or not a review is pending), so this was a straight
# bypass of the mutating-helper protection rather than a degraded-mode gap.
#
# These are the issue's acceptance cases and nothing else. Both directions are pinned:
# only the block side would let a later change widen the scan until ordinary reads are
# refused, and only the allow side would let it be deleted wholesale.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() { # <command> -> the verdict line, or ERROR
    local payload out
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    # CAPTURED, not streamed: a crashing classifier prints a verdict-shaped prefix and
    # THEN exits nonzero, so appending ERROR to what already reached stdout would leave
    # a string a `BLOCK_*` glob still accepts. On a nonzero exit the partial output is
    # DISCARDED and the verdict is exactly ERROR, matching neither assertion.
    if out=$(python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf 'ERROR'
    fi
}

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
    # BLOCK_CLASSIFIER_ERROR is NOT a pass: a caught exception prints it and exits
    # SUCCESSFULLY, so a bare `BLOCK_*` glob would accept a classifier that crashed on
    # every fixture. It fails closed in production, which is why it is a correct VERDICT
    # and an unacceptable TEST RESULT -- the suite exists to prove a rule fired.
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then
        no "$2" "got=$got — the classifier raised; the rule under test never ran"
    elif [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — here-string payload reached a shell unscanned (#643)"
    fi
}

# Assembled from fragments so this file does not itself read as an invocation of the
# protected helper to the very gate it is testing.
STEM="python3 hooks/gate-scripts/lib/lease_"
TAIL="slot.py"
HELPER="$STEM$TAIL"

# -- A. a here-string into a shell is EXECUTION ---------------------------------------
assert_block "sh <<< '$HELPER'"        "sh <<< payload is execution"
assert_block "echo '$HELPER' | sh"     "pipe spelling stays blocked (control: the guard is live)"
assert_block "bash -s <<< '$HELPER'"   "bash -s <<< payload is execution"
assert_block "<<<'$HELPER' sh"         "redirect-first spelling still resolves to the shell"
assert_block "sh<<<'$HELPER'"          "operator attached to the command word"
assert_block "timeout 5 sh <<< '$HELPER'" "a wrapper in front does not hide the receiver"
# The receiver is asked in COMMAND POSITION. A wider test -- a shell name anywhere in the
# segment, as the pipe path uses -- is safe THERE because a pipeline stage's words are the
# command, but here the operand and the arguments share the segment, so it read every
# mention of an interpreter as a receiver. Section D pins what that costs.
assert_ok    "echo sh <<< '$HELPER'"      "a shell name as DATA is not a receiver"
assert_ok    "echo '<<<' '$HELPER' sh" "a dequoted <<< is read as the operator, but echo is no receiver"
assert_block "sh 0<<< '$HELPER'"          "operator behind a file descriptor"
# Redirections apply left to right and the LAST stdin one wins, so reading only the first
# `<<<` classified the payload that never runs and allowed the one that does.
assert_block "sh <<< : <<< \"$HELPER\""  "a later here-string operand is not missed"
# A receiver the text does not SPELL is the same question as an unresolvable operand, one
# word to the left: `$S` names no shell, so asking `_is_shell_name` was a fail-open. Same
# answer, same regex, same whole-command search.
assert_block "S=sh; \"\$S\" <<< '$HELPER'"  "a receiver behind an expansion fails closed"
assert_block "/bin/[b]ash <<< '$HELPER'"    "...and one behind a glob"
# The COMMAND-WORD question, so the command-word regex: brace expansion and an extglob
# group both name a shell the text never spells, and neither is in the operand set.
assert_block "/bin/{ba,z}sh <<< '$HELPER'"  "...behind a brace expansion"
assert_block "/bin/@(sh) <<< '$HELPER'"     "...and behind an extglob group"
# The negation/alternation arm of that same pair: `@(s|z)` names two spellings, so
# resolving it to its contents would pick the harmless-looking one. Unresolvable, closed.
assert_block "/bin/ba@(s|z)h <<< '$HELPER'" "...an alternation is unresolvable, not resolved"
# One `sub` pass resolves one level, so what survives a pass is unresolvable too.
assert_block "/bin/@(@(sh)) <<< '$HELPER'"  "...and a nested group is not half-resolved"
# Resolution is bounded, and exceeding the bound is not a miss: the command word still
# differs from its unrewritten spelling, which is what counts as unresolved.
assert_block "/bin/@(@(@(@(@(sh))))) <<< '$HELPER'" "...nor one nested past the pass limit"
# A NEGATION is never rewritten (resolving it to its contents yields the one spelling it
# cannot match), so the truncated command word is the only trace of it left.
assert_block "/bin/b!(z)sh <<< '$HELPER'"   "...nor a negated group"
# A WRAPPER whose flag eats its operand hides the receiver from the peel. Which flags do
# that is the arity table this file refuses to keep, so an unresolved receiver behind a
# wrapper is answered like every other unresolved case: search the whole command.
assert_block "env -u FOO bash <<< '$HELPER'"              "a wrapper flag operand does not hide the receiver"
assert_block "timeout --signal TERM 5 bash <<< '$HELPER'" "...in the long-option spelling too"
# Normalization rewrites \$IFS to a separator before this path sees it, so the operand
# arrives blank (quoted) or missing entirely (unquoted). Blank is unresolved, not absent.
assert_block "IFS='$HELPER'; bash <<< \"\$IFS\""  "an operand normalization emptied fails closed"
assert_block "IFS='$HELPER'; bash <<< \$IFS"      "...and one it removed outright"
assert_block "IFS=sh; \"\$IFS\" <<< '$HELPER'"    "...and a RECEIVER it emptied the same way"
# The ANSI-C prefix is stripped before this path sees the text, but only NUMERIC escapes
# are decoded, so a named whitespace escape arrives looking like ordinary characters.
assert_block "IFS='$HELPER'; sh <<< \$'\\n'\$IFS" "an undecoded escape is not a resolved operand"
# ...and the extglob fallback asks about the RECEIVER region only: an unresolvable group
# inside the payload says nothing about who runs it.
assert_ok    "echo '$HELPER'; cat <<< 'echo @(x|y)'" "a group in the payload of a read is not a receiver"
assert_block "<<<'$HELPER' /bin/ba@(s|z)h"          "...but the redirect-first spelling still resolves"
assert_block "IFS=ba; \"\${IFS}sh\" <<< '$HELPER'"  "a receiver assembled out of \$IFS is not spelled"
# The payload is read from the ORIGINAL segment, never the deglobbed one: resolving a group
# to the text it wraps DELETES the alternative that matched, so the rewrite must not reach
# the operand. The `?` spelling below is the one the shared probe can resolve.
assert_block "bash <<< '${STEM}slo?.py .claude fake 1'" "a globbed helper name in the payload still blocks"
# Quoting is gone by the time the redirection strip runs, so a quoted operand that LOOKS
# like an operator takes the receiver with it and the peel comes back empty. Empty is
# unresolved, and unresolved behind a wrapper is answered whole.
assert_block "env -u '>' sh <<< '$HELPER'"  "a quoted operator operand does not hide the receiver"
# The payload is never read from the operand, so a value CONCATENATED onto one cannot hide
# in the part normalization rewrote: the whole command is what gets probed.
assert_block "IFS=';$HELPER .claude fake 1'; sh <<< :\$IFS" \
    "an operand assembled by concatenation is still covered"
# ...and the extglob question is asked of the COMMAND WORD only. A group in an ARGUMENT
# leaves the receiver where it was, so an ordinary read stays a read.
assert_ok    "echo '@(x|y)' <<< 'prose $HELPER'" "a group in an argument is not a receiver"
# What the probe is handed is the SEGMENT, not the command, while nothing in the command
# is expanded: an unrelated read standing beside a here-string is still a read.
HELPER_PATH="hooks/gate-scripts/lib/lease_${TAIL}"
assert_ok    "sh <<< ':' ; cat $HELPER_PATH"  "a read beside a harmless here-string is not blocked"
assert_ok    "cat $HELPER_PATH ; sh <<< ':'"  "...in either order"
assert_block "sh <<< ':' ; sh <<< '$HELPER'"  "...but a second receiver is still examined"

# -- B. a here-string into a non-executing receiver is DATA ---------------------------
assert_ok    "cat <<< 'prose mentioning $HELPER'"  "cat <<< prose is data, not execution"
# NOT "...including behind a wrapper": a wrapper in command position means the receiver
# could not be resolved without a per-flag arity table, so it fails closed. Section D pins
# what that costs; the unwrapped spelling above is the one that matters for #573.
assert_ok    "cat <<< 'hello world'"                   "...and ordinary prose naming nothing"
# `<<<` written inside quotes is PROSE, and the lexer keeps it inside one token, so it
# never reaches the here-string path at all. Pinned because this is #573's shape.
assert_ok    "echo 'use <<< like this'"                "a quoted <<< is text, not an operator (#573)"

# -- C. an unresolvable operand fails CLOSED ------------------------------------------
# The operand is rewritten before the shell sees it, so what runs is not visible here --
# and the payload is re-parsed by that shell anyway, which is why a quoted `$VAR` is no
# more resolvable than an unquoted one. Same answer the `-` / `/dev/fd/N` interpreter
# branch already gives: search the WHOLE command rather than the operand.
assert_block "VAR='$HELPER'; sh <<< \"\$VAR\""  "an unresolvable operand is answered by the whole command"
assert_block "VAR='$HELPER'; sh <<< '\$VAR'"    "...in the single-quoted spelling too, which the inner shell expands"
# RESIDUAL, the same one the `-` branch carries: a value from OUTSIDE the command names
# nothing here, so there is nothing to find. Pinned so it stays measured, not assumed.
assert_ok    "sh <<< \"\$VAR\""   "residual: a value from outside the command is invisible"

# -- D. the measured RESIDUALS, pinned so they stay visible ---------------------------
# Both are cases where this routing is narrower than the pipe path it feeds, both are
# fail-opens, and NEITHER is a regression: each reads OK on origin/main too, because on
# main this path does not exist at all. Recorded as out of scope for #643 rather than
# assumed away -- an `assert_ok` here would make a known gap look like required
# behaviour, so the failure text says what a BLOCK would mean instead.
residual_block() { # <command> <label> -- an accepted OVER-block, pinned as measured
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then
        ok "RESIDUAL over-block (accepted): $2"
    else
        no "RESIDUAL over-block: $2" "got=${got:-<empty>} — narrowed since; check it did not become a fail-open, then delete this fixture"
    fi
}
residual() { # <command> <label> -- passes on OK, and says so when the gap closes
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "RESIDUAL (still open): $2"
    elif [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then
        no "RESIDUAL: $2" "got=$got — this residual is now CLOSED; delete the fixture and its note rather than restoring the OK"
    else
        no "RESIDUAL: $2" "got=${got:-<empty>} — neither the pinned residual nor a block"
    fi
}
# 1. the receiver and the `<<<` must land in the same split segment, so a redirection
#    attached to a compound command is separated from the shell inside it.
residual "(sh) <<< '$HELPER'"              "a redirection on a subshell group"
residual "{ sh; } <<< '$HELPER'"           "...on a brace group"
residual "if true; then sh; fi <<< '$HELPER'" "...on a compound command"
# 2. the receiver test here is the shell-NAME one; the pipe path's is wider, but it is
#    48 lines inline inside `_piped_shell_producers` and shared with cmdword.
# 3. an OVER-block: a here-string on a non-zero descriptor is scanned anyway, and a later
#    operand that overrides an earlier one does not un-scan it. A descriptor guard was
#    tried and removed -- after shlex, the operand `3` in `bash -s 3 <<< P` cannot be told
#    from the fd in `sh 3<<< P`, so the guard turned an over-block into a FAIL-OPEN.
residual_block "sh 3<<< '$HELPER'"         "a non-zero descriptor is scanned anyway"
residual_block "bash <<< '$HELPER' <<< ':'" "an overridden operand is not un-scanned"
residual "busybox sh <<< '$HELPER'"        "an applet multiplexer receiver"
# ...and the same shape for a wrapper this scanner's shared name set does not carry:
# `genv` is GNU env under a prefix. Membership of that set is every caller's question.
residual "genv -i sh <<< '$HELPER'"        "a wrapper name outside the shared set"
# ...and the same shape again where the shell is an OPERAND of a command that runs it:
# the receiver here is `find`, and its `-exec` child inherits the redirected stdin.
residual "find . -prune -exec sh \\; <<< '$HELPER'" "a shell run as another command's operand"
residual "toybox sh <<< '$HELPER'"         "...and the toybox spelling"
# `env -S 'bash -s'` is CLOSED, and not by naming `-S`: `env` is a wrapper, so an
# unresolved receiver behind it is searched whole. Pinned as a block for that reason.
assert_block "env -S 'bash -s' <<< '$HELPER'"  "an env -S operand receiver"
residual ". /dev/stdin <<< '$HELPER'"      "a dot-source receiver"
# 4. an OVER-block: the lexer is posix, so it dequotes before this path sees the token and
#    a literal `'<<<'` argument is indistinguishable from the operator. Same guard as 3.
residual_block "sh '<<<' '$HELPER'"        "a literal <<< argument reads as the operator"
# 5. an OVER-block, the price of the wrapper answer above: a NON-executing receiver behind
#    a wrapper is unresolved too, so prose naming the helper is refused there.
residual_block "timeout 5 cat <<< 'prose $HELPER'" "prose behind a wrapper is refused"
# 6. an OVER-block held in COMMON with the pipe path: an interpreter that takes its program
#    from a flag or an operand still gets its here-string scanned as source. Deciding
#    otherwise means reading per-flag arity, which is the question this file refuses. All
#    three spellings below block identically through a PIPE on origin/main -- measured, not
#    assumed -- so this is parity, not a new refusal.
residual_block "bash -c ':' <<< '$HELPER'"      "an interpreter whose program came from -c"
residual_block "sh safe-script <<< '$HELPER'"   "...or from an operand"
residual_block "python3 -c 'pass' <<< '$HELPER'" "...in the python spelling"
# 7. a gap in the SHARED probe, not in this routing: an extglob-spelled helper path is
#    unresolved everywhere -- measured OK through a pipe, through `-c`, and as a DIRECT
#    invocation on this same tree. Fixing it means teaching `_abandoned_scan_probe` to
#    expand alternations, which is every caller's change, not this one.
residual "bash -O extglob <<< '${STEM}slo@(x|t).py .claude fake 1'" "an extglob-spelled helper path"
# 8. an OVER-block: a `<<<` written inside a COMMENT is still read as an operator. The
#    file's own `_defuse_comments` blanks separators and quotes inside a comment but keeps
#    every other byte on purpose (deleting moved 14 real commands to allow), so the
#    operator survives. Ending the segment at a `#` instead is comment modelling, and it
#    would hide a real payload written after one -- the fail-open direction.
residual_block "sh -c ':' # <<< lease_${TAIL}" "a <<< inside a comment reads as an operator"
# 9. an OVER-block, the price of choosing whole-command text whenever the command carries
#    an expansion ANYWHERE: normalization has already erased the expansion from the
#    segment that would prove it relevant (`sh <<< :\$IFS` arrives as `sh <<< :`), so the
#    choice cannot be made segment-locally without the provenance this scan does not keep.
residual_block "sh <<< ':' ; X=hooks/gate-scripts/lib; cat \"\$X/lease_${TAIL}\"" \
    "an expansion in an unrelated command widens the probe"

# The nested-fragment case is NOT a residual -- it is closed. The unresolvable-operand
# answer searches the whole command, and on recursion that has to be the ORIGINAL
# command: passing the fragment lost an assignment living only in the outer one.
assert_block "VAR='$HELPER' sh -c 'sh <<< \\\"\$VAR\\\"'" \
    "a nested fragment still sees the outer assignment"

# -- E. the scan stays inside the hook's budget ---------------------------------------
# A hook killed by its timeout writes NO decision, and the harness reads that as ALLOW --
# so a slow scan is a fail-open, not a slow pass. An earlier version searched the whole
# command once per segment and took ~6.3s on this input. Generous bound: the point is to
# catch a return to quadratic, not to pin a number.
perf_case() { # <segment> <label> -- 1000 of them, scanned within the budget
    local cmd="" i start elapsed
    for ((i = 0; i < 1000; i++)); do cmd+="$1 ; "; done
    start=$(date +%s)
    verdict "$cmd" >/dev/null
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -le 3 ]]; then
        ok "1000x $2 scan in ${elapsed}s (budget 3s)"
    else
        no "1000x $2" "took ${elapsed}s — a scan past the hook timeout reads as ALLOW"
    fi
}
# Both sides of the segment/whole choice: the expansion path probes the whole command once,
# the plain path probes each segment, and neither may become quadratic.
# shellcheck disable=SC2016  # the `$X` must reach the classifier unexpanded
perf_case 'sh <<< "$X"' "expansion (whole-command path)"
perf_case 'sh <<< y'    "plain (per-segment path)"

printf '\n%s: %d passed, %d failed\n' "$(basename "${BASH_SOURCE[0]}")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
