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
if [ "$#" -eq 0 ]; then
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
if [ "$#" -eq 0 ]; then
    printf '%s\n' 'contained-launch: no command to run — failing CLOSED (exit 2).' >&2
    exit 2
fi

/usr/bin/env -i "$@"
rc=$?

# 0 and 2 are the wrapper's own answers and pass through untouched: allow, and block.
# Anything else is a launch or runtime failure that never produced a decision — 127 for a
# missing wrapper, 126 for one that is not executable, 1 for a wrapper that refused its own
# arguments. The registration says which way that resolves.
case "$rc" in
    0|2) exit "$rc" ;;
esac

if [ "$disposition" = open ]; then
    exit 0
fi
exit 2
