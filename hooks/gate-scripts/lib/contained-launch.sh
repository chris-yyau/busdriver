#!/bin/bash -p
# Contained-gate first hop — issue #713, docs/adr/0049-hook-exec-form-launch-boundary.md
#
# Registered as a hook's `command`, with the whole contained invocation in `args`:
#
#   command: ${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/contained-launch.sh
#   args:    <closed|open> PATH=/usr/bin:/bin [NAME=value ...] /bin/bash <wrapper> <operands...>
#
# It exists to close two residuals ADR 0049 first shipped as accepted (R7 and R8). Both are
# about what happens when the launch itself goes wrong, which is exactly where a security
# gate must not quietly allow.
#
# ── R7: the first hop must fail CLOSED with no arguments ────────────────────────────
# Registrations used to name `/usr/bin/env` as `command` and put everything in `args`. A
# client that accepts the hook but ignores `args` then runs `env` with no operands, and
# bare `env` EXITS 0 AND PRINTS THE ENVIRONMENT: an allow on every gate plus a per-event
# environment dump. There is no shipped minimum-version control to prevent that
# (`requiredMinimumVersion` is enforced only from managed policy settings), so the defence
# has to be the binary named in `command` — hence this script, whose argc-0 behaviour is
# `exit 2` and nothing on stdout.
#
# ── R8: a launch failure must become a BLOCK, not an allow ──────────────────────────
# Shell-form registrations carried a `|| exit 2` tail that turned a missing or unreadable
# wrapper (bash exits 127) into a block. Exec form has no shell, so the tail could not be
# transcribed and 127 became an ALLOW — only exit 2 blocks. The disposition argument
# restores that conversion here, inside the process that already knows which way the gate
# is supposed to fail.
#
# ── Why a bash first hop is safe here, when the design first rejected one ───────────
# The original objection was that bash imports exported shell functions from the
# environment — `BASH_FUNC_exec%%=() { … }` overrides the `exec` BUILTIN — and honours
# SHELLOPTS, BASH_ENV and ENV, all of which a committed .claude/settings.json `env` block
# can set. That is true of a plain `#!/bin/bash`. It is NOT true under `-p`: privileged
# mode makes bash ignore SHELLOPTS/BASHOPTS, skip BASH_ENV and ENV, and refuse to import
# functions from the environment. Measured, all three, in both directions.
#
# So this script runs BEFORE `env -i` yet is already immune to the class `env -i` exists to
# strip. It uses builtins and absolute paths only — no PATH lookup happens anywhere in it,
# so a hostile PATH has nothing to steer. Loader variables (LD_PRELOAD, DYLD_*) remain
# residual R2, unchanged: /bin/bash is SIP-protected on macOS exactly as /usr/bin/env was,
# so the first-hop exposure is the same binary class it always was.
#
# Keep this file tiny and dependency-free. It is the outermost trusted thing in the gate
# path; every line here runs with the caller's environment still intact.

set -u

# R7. No arguments at all is the args-ignoring-client shape. Fail CLOSED and say why on
# stderr — never on stdout, which is where a decision document would go, and never the
# environment, which is what bare `env` used to dump.
if [[ "$#" -eq 0 ]]; then
    printf '%s\n' \
        'contained-launch: invoked with no arguments — refusing to run a gate uncontained.' \
        'This means the client honoured the hook "command" but dropped its "args"; the' \
        'whole contained invocation lives there. Failing CLOSED (exit 2). See #713.' >&2
    exit 2
fi

disposition="$1"
shift

case "$disposition" in
    closed|open) ;;
    *)
        printf '%s\n' \
            "contained-launch: unknown disposition '$disposition' — failing CLOSED (exit 2)." >&2
        exit 2
        ;;
esac

# Everything after the disposition is the contained invocation itself: the assignments that
# survive `env -i`, then the interpreter, the wrapper and its operands. An empty tail cannot
# launch anything, so it is a wiring bug, and a wiring bug in a gate is a block.
if [[ "$#" -eq 0 ]]; then
    printf '%s\n' 'contained-launch: no command to run — failing CLOSED (exit 2).' >&2
    exit 2
fi

# A NON-EMPTY tail is not enough, and getting this wrong reopens R7 through the side door.
# `env -i NAME=value` with no utility after the assignments does NOT fail: env applies the
# assignments, PRINTS THE RESULTING ENVIRONMENT and exits 0 — the exact behaviour that made
# bare `/usr/bin/env` unusable as `command`. So a client (or a bad edit) that drops the tail
# only PARTIALLY, keeping the disposition and some assignments, would otherwise get an allow
# plus an environment dump out of the very hop added to prevent that. Require a real program
# to run, and require it absolute: a relative one would be resolved by a PATH lookup inside
# the sterile child, which is a name we do not control.
utility=''
utility_operands=0
first_operand=''
for arg in "$@"; do
    if [[ -n "$utility" ]]; then
        [[ "$utility_operands" -eq 0 ]] && first_operand="$arg"
        utility_operands=$((utility_operands + 1))
        continue
    fi
    case "$arg" in
        [A-Za-z_]*=*) continue ;;
        *) utility="$arg" ;;
    esac
done
if [[ -z "$utility" ]]; then
    printf '%s\n' \
        'contained-launch: the argument list is only assignments — no program to run.' \
        'env would print the environment and exit 0 here; failing CLOSED (exit 2). See #713.' >&2
    exit 2
fi
case "$utility" in
    /*) ;;
    *)
        printf '%s\n' \
            "contained-launch: refusing a non-absolute program '$utility' — it would be" \
            'resolved by a PATH lookup in the sterile child. Failing CLOSED (exit 2).' >&2
        exit 2
        ;;
esac

# Absolute is necessary and not sufficient, and this is the third way review found into the
# same room. Every rule below constrains the FIRST OPERAND, on the assumption that the program
# being launched is the interpreter that would read it. Nothing said the program had to BE the
# interpreter — so `/usr/bin/env /bin/bash -s` passes all of them: `/usr/bin/env` is absolute,
# `/bin/bash` is an unimpeachable first operand, and the inner `env` then runs `bash -s`, which
# reads the payload from stdin and exits 0. Measured: the file was created and the gate
# allowed. Chaining is unbounded, so no amount of operand inspection catches the general case.
#
# The answer is that the program is not a free parameter. This script's own contract — the
# header above, `hooks.json`, and the validator that pins it — names exactly one interpreter,
# and all 17 contained registrations use it. Pinning it here makes that contract executable
# instead of merely written down, and collapses every nesting shape into one refusal.
if [[ "$utility" != /bin/bash ]]; then
    printf '%s\n' \
        "contained-launch: refusing to run '$utility' — the contained launch contract names" \
        '/bin/bash as the interpreter, and a different program can nest one (env /bin/bash -s' \
        'reads the hook payload as source). Failing CLOSED (exit 2). See #713.' >&2
    exit 2
fi

# The program must be followed by at least one operand, and this is the sharpest of the three
# checks. Every real registration passes the wrapper path after `/bin/bash`, so a tail
# truncated to end exactly at `/bin/bash` leaves bash with NO script — and a bash with no
# script operand and a non-tty stdin READS ITS SOURCE FROM STDIN. Stdin here is the hook
# payload: attacker-influenced JSON, whose command substitutions bash would then execute.
# Measured before this guard existed: a payload containing `$(touch …)` created the file, and
# bash exited 0 afterwards, so the gate ALSO allowed. Code execution and a bypass from the
# same truncation. Anything short of a complete argv fails CLOSED here instead.
if [[ "$utility_operands" -eq 0 ]]; then
    printf '%s\n' \
        "contained-launch: '$utility' was given no operands — the argument list is truncated." \
        'An interpreter with no script reads its source from stdin, which is the hook payload.' \
        'Failing CLOSED (exit 2) without running anything. See #713.' >&2
    exit 2
fi

# Arity alone is not enough either, and this is the same hole one door further in. The check
# above only asks whether SOMETHING follows the interpreter; `/bin/bash --`, `/bin/bash -s`
# and `/bin/bash -i` each satisfy it with exactly one operand and still leave bash reading
# its source FROM STDIN — the hook payload again. So does `/bin/bash /dev/stdin`, which is
# absolute and would pass any path-shape rule. Measured, all four: a payload containing
# `$(touch …)` created the file and bash exited 0, i.e. code execution AND an allow, the
# very pair the truncation guard exists to prevent.
#
# Three rules, in the order they can fire:
#   1. the operand must be ABSOLUTE       — rejects --, -s, -c, -i and every other option
#   2. it must not reach a descriptor     — rejects /dev/stdin, /dev/fd/N, /proc/N/fd/N AND
#                                            every other spelling of the same file
#   3. if it EXISTS it must be a regular file — rejects a directory, fifo or device node
#
# Rule 3 is deliberately conditional on existence. A MISSING wrapper must keep reaching bash
# so it still becomes a 127 and the DISPOSITION still decides it, exactly as R8 specifies.
# Hardening this to a flat `-f` would quietly convert a missing wrapper on the two `open`
# rows from allow to block — a policy change smuggled in as a containment fix. Containment
# is unaffected either way: nothing has been executed at this point, so the rules below
# choose an exit status, never whether the payload runs.
case "$first_operand" in
    /*) ;;
    *)
        printf '%s\n' \
            "contained-launch: refusing '$utility' operand '$first_operand' — it is not an" \
            'absolute path, so it is an option, and an interpreter given only options reads' \
            'its source from stdin (the hook payload). Failing CLOSED (exit 2). See #713.' >&2
        exit 2
        ;;
esac
# Rule 2 cannot be a list of literal spellings, and the first draft of it was exactly that.
# `case` compares STRINGS, so `/dev/stdin` was refused while `/dev/./stdin`, `/dev//stdin`,
# `/dev/../dev/stdin` and `/dev/fd/../fd/0` all name the SAME descriptor and sailed straight
# past. Measured, each of them: a payload containing `$(touch …)` created the file and bash
# exited 0 — the original bug back intact, wearing a different spelling. Enumerating spellings
# is unwinnable; there are infinitely many.
#
# So refuse the SHAPE rather than the name, in two steps that need no path normalizer:
#   a. collapse repeated slashes (a plugin root with a trailing slash is ordinary, and `//`
#      changes nothing about which file is named), then
#   b. refuse any remaining `.` or `..` SEGMENT outright. No wrapper needs one, so refusing is
#      both cheaper and safer than resolving them — a normalizer has to be exactly right to be
#      a boundary, and this has to be right only about what a canonical path looks like.
#
# What survives is canonical, so a prefix test decides it. That test covers the whole `/dev`
# and `/proc` TREES rather than the three descriptor names: nothing belonging to a gate lives
# under either, and a rule about the tree does not need revisiting when a new alias for
# descriptor 0 appears.
canonical_operand="$first_operand"
while [[ "$canonical_operand" == *//* ]]; do
    canonical_operand="${canonical_operand//\/\///}"
done
case "$canonical_operand/" in
    */./*|*/../*)
        printf '%s\n' \
            "contained-launch: refusing '$first_operand' — it carries a '.' or '..' segment, so" \
            'the file it names cannot be read off the path. A wrapper path is always canonical;' \
            'failing CLOSED (exit 2) rather than resolving it. See #713.' >&2
        exit 2
        ;;
esac
case "$canonical_operand" in
    /dev|/proc|/dev/*|/proc/*)
        printf '%s\n' \
            "contained-launch: refusing '$first_operand' — it is under /dev or /proc, where the" \
            'only readable "scripts" are file descriptors, and descriptor 0 is the hook payload.' \
            'Failing CLOSED (exit 2). See #713.' >&2
        exit 2
        ;;
esac

# A lexical rule alone is still only half of it, and review caught the other half the same way
# it caught the spellings: by trying it. The regular-file test below FOLLOWS symlinks while
# everything above reads the path as text, so an alias reaches the descriptor without ever
# spelling it. Both shapes measured executing the payload and exiting 0 — a symlinked FINAL
# component (`/tmp/wrapper -> /dev/stdin`) and a symlinked DIRECTORY component
# (`/tmp/d -> /dev`, then `/tmp/d/stdin`). So the tree test has to be applied to the file the
# kernel would open, not to the string.
#
# The two components are handled differently because resolving them costs differently. A
# symlinked final component is simply REFUSED: chasing the chain needs `readlink`, which is an
# external binary at a path that varies by platform, and this script's whole safety argument is
# that it runs builtins and absolute paths only. Nothing in a plugin tree needs the wrapper
# itself to be a symlink (checked: none is). The directory is RESOLVED instead, with `cd -P` +
# `pwd -P`, both builtins — and with an absolute operand, so CDPATH is never consulted.
#
# A directory that cannot be entered leaves the physical path unknown, and that deliberately
# does NOT refuse: an unreachable directory means the wrapper cannot exist either, so bash
# still gets its 127 and the disposition still decides it, which is R8's contract. There is no
# descriptor to reach through a directory that is not there.
if [[ -L "$first_operand" ]]; then
    printf '%s\n' \
        "contained-launch: refusing '$first_operand' — it is a symlink, so the path checked" \
        'and the file opened need not be the same file. Failing CLOSED (exit 2). See #713.' >&2
    exit 2
fi
operand_dir="${canonical_operand%/*}"
[[ -z "$operand_dir" ]] && operand_dir=/
physical_dir="$(cd -P -- "$operand_dir" 2>/dev/null && pwd -P)"
if [[ -n "$physical_dir" ]]; then
    case "$physical_dir" in
        /dev|/proc|/dev/*|/proc/*)
            printf '%s\n' \
                "contained-launch: refusing '$first_operand' — its directory resolves to" \
                "'$physical_dir', inside /dev or /proc. An alias does not make a descriptor a" \
                'script. Failing CLOSED (exit 2). See #713.' >&2
            exit 2
            ;;
    esac
fi
if [[ -e "$first_operand" && ! -f "$first_operand" ]]; then
    printf '%s\n' \
        "contained-launch: refusing '$first_operand' — it exists but is not a regular file," \
        'so it cannot be the wrapper script. Failing CLOSED (exit 2). See #713.' >&2
    exit 2
fi

# Trusted ambient-git-scope sentinel for gates that strip GIT_* from probes
# (#780). Do not forward the raw values — only whether any were set pre-env -i.
_bd_git_scope=0
[[ -n "${GIT_DIR+x}" || -n "${GIT_WORK_TREE+x}" || -n "${GIT_COMMON_DIR+x}" \
    || -n "${GIT_NAMESPACE+x}" || -n "${GIT_INDEX_FILE+x}" ]] && _bd_git_scope=1
if [[ "$_bd_git_scope" -eq 1 ]]; then
    /usr/bin/env -i BUSDRIVER_GIT_SCOPE_PRESENT=1 "$@"
else
    /usr/bin/env -i "$@"
fi
rc=$?

# This reproduces the shell-form tails EXACTLY, which is the point — the disposition replaces
# a tail, it does not redesign one.
#
#   `… || exit 0`  (the two GateGuard rows)  =>  rc 0 stays 0, ANY non-zero becomes 0
#   `… || exit 2`  (everything else)         =>  rc 0 stays 0, ANY non-zero becomes 2
#
# Note what the `open` rule does NOT do: it does not pass a 2 through. That is deliberate, and
# it is exactly what `|| exit 0` did — this is a restoration, not a new policy. Exit 2 is not
# reliably a decision here: bash returns 2 for its own usage and syntax failures.
#
# The case worth being explicit about is `sanitized-node.sh` refusing a MALFORMED argument
# list: it deliberately fails CLOSED even under `--fail-open`, emitting exit 2 *and*
# `{"decision":"block"}` on stdout. Converting the status does not lose that block — the
# legacy top-level `decision` field is honoured on PreToolUse (measured under exec form; see
# the probe table in ADR 0049), and these rows carry their deny on stdout rather than in the
# status anyway (tests/test-gateguard-containment.sh asserts both halves: the JSON is emitted,
# and the status is 0). So the forced-CLOSED contract survives on the channel that actually
# carries it, and the status conversion stays faithful to the tail it replaced.
if [[ "$rc" -eq 0 ]]; then
    exit 0
fi
if [[ "$disposition" == open ]]; then
    exit 0
fi
exit 2
