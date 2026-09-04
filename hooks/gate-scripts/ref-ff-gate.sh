#!/usr/bin/env bash
# PreToolUse hook: gate a FAST-FORWARD of the protected branch (issue #779)
#
# THE BYPASS. `git pull --ff-only`, and any `git merge` that resolves to a
# fast-forward (including `--no-commit`), move the protected branch to commits
# litmus never reviewed. A fast-forward creates NO commit object, so nothing in
# the commit-oriented machinery ever observes it: pre-commit-gate.sh matches
# `git commit` and never fires, no review marker is armed, and litmus's only
# merge-shaped token (PASS-MERGE, run-review-loop.sh) is gated on `MERGE_HEAD`,
# which a fast-forward does not create. This gate is the missing observation
# point, and $STATE_DIR/ref-ff-authorized.local is the missing marker form.
#
# AUTHORIZATION — ONE way past, and deliberately only one: AN OID-BOUND MARKER,
# on a `git merge --ff-only <oid>`.
#   $STATE_DIR/ref-ff-authorized.local containing exactly
#      `PASS-FF refs/heads/<branch> <oid>` — binding repo (by file location, as
#      every marker here does), ref and oid, which is what #779 asks for and what
#      the `^PASS-MERGE-[0-9]+$` token it compares against could not do.
#   WHICH BRANCH IS PROTECTED is discovered, in this order: every remote's HEAD,
#   `init.defaultBranch`, then the conventional names (main, master, trunk,
#   develop, development, default) that exist locally. A project whose protected
#   branch is none of those — `release`, with no <remote>/HEAD — cannot be
#   inferred, so the operator names it, one per line, in
#   $STATE_DIR/ref-ff-protected.local — which is also the durable answer for such
#   a branch, since a remote's HEAD can be deleted by a later command and the
#   declaration cannot (it is forge-guarded). With nothing discovered and nothing
#   declared the gate BLOCKS: it cannot tell what is protected, and that is the
#   failure case. An EMPTY declaration file is how an operator says their repo has
#   no protected branch — a statement the file's absence does not make.
#   When the protected branch has NO remote-tracking ref (a local-only repo, or a
#   deleted remote) the pull arm cannot hold either, so every fast-forward onto it
#   needs the marker. That is deliberate, not an oversight: keying an exit-0 on
#   the repo's shape would be a fail-OPEN reachable by deleting a remote.
#   Marker minting is OPERATOR-side on purpose: the pipeline has no legitimate
#   automated fast-forward-to-unreviewed flow (work lands via `gh pr merge`), so
#   an automatic minter would be machinery with no caller.
#
# SCOPE — deliberately only the fast-forward class:
#   IN   `git merge <ref>` that fast-forwards HEAD (`--ff-only`, `--no-commit`,
#        the default `--ff`), and `git pull` on the protected branch.
#   OUT  a merge that produces a COMMIT (`--no-ff`, a real three-way merge, and
#        `merge -s ours` laundering) — #622 / #782; `--squash`, whose `git commit`
#        pre-commit-gate already owns; ref CREATION at unreachable content — #781;
#        `rebase` / `am` — #783.
#   ALSO #780 ZERO-old force/delete (`branch -f`, `checkout -B`, `update-ref`).
#   ALIASES are handled, not conceded: one defined on the COMMAND LINE (`-c
#   alias.m=merge`, or indirectly via `-c include.path=…`) makes the operation
#   unresolvable, and one defined in a config FILE is resolved here against
#   `git config --get alias.<name>` — the parser reports the names it does not
#   recognize and this gate looks each up. A `!`-prefixed shell alias is refused
#   outright, since its body is outside any command-string parser.
#   RESIDUAL, named rather than left to be found: a colon refspec that writes a
#   ref with no checkout is the same ref-writing primitive reached by a different
#   subcommand, and is NOT covered here — it belongs with #780/#781's ref-writing
#   class. It has two reaches. Writing the protected ref itself (`git fetch .
#   HEAD:main`, `git push . HEAD:main`) moves the branch without a merge at all.
#   Writing the REMOTE-TRACKING ref (`git fetch <remote> <unreviewed>:refs/remotes/
#   <remote>/<protected>`) forges a remote-tracking ref. Neither can be refused
#   from here. The second no longer authorizes anything — the path that trusted it
#   was deleted — and in the pull arm the same ref is only a precondition, where
#   poisoning it can at most let through a pull whose content still comes from the
#   real remote.
#   CLOSED for the marker route, downstream execution. The gate authorizes ONE
#   ref move and cannot see what git itself runs afterwards. `git merge` invokes
#   `post-merge`, and with `core.hooksPath` pointing inside the working tree the
#   content the fast-forward just landed can BE that hook and move the ref again
#   immediately. Refusing an in-tree hooksPath was once considered and rejected
#   as too noisy (`.githooks/` is a common layout) -- that judgement was WRONG and
#   is no longer what this file does. The marker route now asks git which
#   directory it will run hooks from and refuses when the answer lands in the
#   working tree; see the block near the marker check for how, and ADR 0050 for
#   what remains open. The command's own resolution of `git` is still a residual:
#   ambient PATH, BASH_ENV and exported shell functions belong to the session
#   shell, not to this gate, which the contained launch (`#!/bin/bash -p`)
#   hardens only for ITSELF.
#   RESIDUAL, the runner's deadline. The hook runs under a 10s outer timeout
#   whose expiry is NOT a decision -- the runner kills the process before
#   anything reaches stdout, so a gate that runs long is a gate that is not
#   there. The bounds in this file (payload size, remote listing bytes and
#   count, declaration length) keep the work short, and each was added because
#   an unbounded read was reachable from repo-controlled state, but none of them
#   bounds a single git call that HANGS.
#   A self-deadline was BUILT and then REMOVED from this branch, deliberately;
#   the reasoning is recorded in ADR 0050 so it is not reproposed blind. In
#   short: it is a property of all seven gates, not of this one, so fixing it
#   here would be both partial and duplicated; and it is a process killer inside
#   a security gate, which review found four separate defects in -- one of them
#   a bash-4-only construct that aborted this gate on EVERY command under the
#   /bin/bash 3.2 the registration actually names. It belongs with the launcher,
#   next to #777, with its own review. The `/bin/bash` execution test in
#   tests/test-ref-ff-gate.sh is what that round left behind, and it stays.
#   RESIDUAL, non-regression: every operation these residuals permit was permitted
#   before this gate existed. They bound what it ADDS; none of them weakens a case
#   it does block, and each needs an actor who already has arbitrary shell.
#
# THREAT MODEL. In scope is the ROUTINE or accidental bypass — the merge or pull
# someone reaches for because it is the obvious next command. Out of scope is the
# deliberate evader with shell access, who does not need any of the shapes above:
# an interpreter payload (`bash -c`, `python3 -c`), a script file, a dispatcher
# (`xargs`, `find -exec`), or config planted by an EARLIER, separately-gated
# command all defeat any command-string parser, and closing one member of that
# class buys nothing because the next is a line away. Those are ACCEPTED
# RESIDUALS, the same ones every gate in this directory carries (see the THREAT
# MODEL block in lib/gitcmd_detect.py, and that module's docstring). Against such
# an actor this gate provides a RECORD, not a barrier: every authorization it
# grants is logged. Against the routine case — the one that actually happens — it
# is the observation point that did not exist.
#
# MECHANISM NOTE. #779 names git's `reference-transaction` hook as the observation
# point. That layer needs a git-hook INSTALLER, which does not exist on main and
# arrives with #622; building one here would duplicate that work. This gate closes
# the bypass at the layer that does exist — the PreToolUse Bash hook every other
# busdriver gate uses — against the vector that matters today (the agent's own
# Bash calls). Migrating enforcement into the ref hook once #622 lands is a
# follow-up, not a prerequisite. See docs/adr/0050-ref-fast-forward-gate.md.
#
# Fail-CLOSED: errors block (user preference: stuck > skipped review).
# Skip: $STATE_DIR/skip-litmus.local — the same gitignored, operator-created file
#       the other review gates honour; this is a review gate, not a new hatch.

# `-f` matters as much as the others here. Several loops iterate an unquoted
# word list on purpose (the parser hands back space-separated names), and with
# globbing on, a WORD FROM THE COMMAND is expanded against the working directory:
# a repo containing a file named `merge` turns `git m*` into an alias candidate
# `m*` that expands to `merge`, so the loop compares a name the command never
# used. Nothing in this gate wants a glob; every pattern match here is `case` or
# `[[ ]]`, and neither is affected.
set -euf -o pipefail
# ── Harness-portable root/state resolution (mirrors pre-commit-gate.sh) ──
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'printf "{\"decision\":\"block\",\"reason\":\"Ref fast-forward gate error — blocking as precaution. If stuck, create '"$STATE_DIR"'/skip-litmus.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper (same three tiers as pre-commit-gate.sh) ─────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    elif command -v python3 &>/dev/null; then
        printf '%s' "$1" | python3 -I -c 'import json,sys; sys.stdout.write(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
        printf '\n'
    else
        local escaped
        escaped=$(printf '%s' "$1" | tr -d '\042\134' | tr '\n\r\t' '   ' | tr -d '\000-\037')
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── Shared repo-dir resolver + skip-file provenance check ─────────────
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# Read git config as close to the way the GATED COMMAND will read it as this hook
# can. sanitized-gate.sh points GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM at
# /dev/null so a hostile config cannot steer the hook — but the gated command runs
# with no such override, so every value used to PREDICT git's behaviour (aliases,
# branch.<n>.remote and .merge, pull.ff/merge.ff, @{upstream}) has to come from
# the files git will actually read. Undoing those two overrides is what makes a
# global `alias.m = merge` visible to the gate as well as to git. These are
# read-only queries; none of them executes a hook, filter or helper.
#
# RESIDUAL, inherited and NOT closed here: the contained launch also replaces HOME
# with the passwd home and does not forward XDG_CONFIG_HOME (ADR 0049 residual R3,
# tracked in #777). When the session HOME or XDG_CONFIG_HOME differs from the
# passwd home, git's global config file is a DIFFERENT file for the command than
# for this gate, and no amount of unsetting here reaches it. This helper closes
# the gap the GATE creates, not the one the LAUNCHER does; the latter is a
# platform limit #777 owns, and one this gate is instructed not to touch.
#
# The same limit covers ambient GIT_DIR, GIT_WORK_TREE, GIT_NAMESPACE,
# GIT_OBJECT_DIRECTORY and GIT_ALTERNATE_OBJECT_DIRECTORIES. Any of them makes the
# command act on a different repository, namespace or object graph than the one
# this gate resolved from the hook payload's cwd — and since the launcher clears
# them before the gate starts, the gate cannot see that it happened, let alone
# refuse it. Closing it means the LAUNCHER passing a trusted "ambient git scope was
# set" flag, which is contained-launch.sh, shared by every gate in this directory,
# and #777/ADR 0049's to change. Note what that scope means: this is not a gap in
# THIS gate but in the repo resolution EVERY gate here performs — pre-commit-gate.sh
# reads its repo the same way — so the fix belongs where it is shared, and a merge
# redirected that way was equally unobserved before this gate existed.
#
# The same sentence covers the GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n /
# GIT_CONFIG_VALUE_n family: the launcher strips it, so those settings are not
# merely overridden here, they are INVISIBLE — nothing this function does can read
# a value it was never given. Two of the three ways that mattered are closed
# elsewhere rather than here, by not relying on a predicted value at all:
#   - a pull must carry the LITERAL `--ff-only`, because git ranks command-line
#     options above the `-c` this family behaves as, so the restriction holds
#     whatever the environment says (see the pull arm);
#   - a git word that resolves to nothing blocks, so an env-defined `alias.m =
#     merge` cannot slip through as an unrecognized word (see the alias arm).
# What REMAINS is (a) a hidden `merge.ff=false`, which turns a marker-authorized
# fast-forward into a merge COMMIT — the #622 / #782 shape, not a fast-forward
# this gate claims to have vouched for — and (b) an env-REDEFINED benign alias:
# the gate resolves `alias.st` to `status` from the config it can read while the
# command runs a merge. (b) is unclosable by construction, since the gate's own
# environment is `env -i`'d before it starts.
# NON-REGRESSION, which is the measure that matters here: both were possible
# before this gate existed and neither is made easier by it. They bound what the
# gate ADDS; no case it does block is weakened by them.
git_real() {   # <git args...>
    env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM git -C "$REPO_DIR" "$@"
}

# Ancestry, with the error case separated from the answer. `merge-base
# --is-ancestor` exits 1 for "no" and >1 for "the query failed", and `!` collapses
# the two — which matters because EVERY caller here reaches an `exit 0` on one of
# the branches. The genuine-octopus test negated four of these at once, so any one
# of them failing read as "not an ancestor" four times over and let the merge
# through unevaluated. An unanswerable query is not an answer; it blocks.
is_ancestor() {   # <a> <b> → 0 yes, 1 no; BLOCKS if git could not decide
    local _rc=0
    git_real merge-base --is-ancestor "$1" "$2" 2>/dev/null || _rc=$?
    if [ "$_rc" -gt 1 ]; then
        block_emit "Ref fast-forward gate: git could not decide whether '$1' is an ancestor of '$2' (git merge-base exited $_rc rather than answering), so the gate cannot tell what this command would do to the protected branch. Blocking as precaution (fail-closed)."
        exit 0
    fi
    return "$_rc"
}

# Read or remove a file in $STATE_DIR with NO symlink anywhere in the path.
#
# `[ -L ]` on the leaf is not enough and `[ -f ]` is worse: both resolve the path
# through every intermediate component, so a symlinked `$STATE_DIR` — or a
# symlinked component when it is nested — makes the test describe one file while
# the read, and the marker's removal, land on another. The state dir is
# repo-relative and therefore repo-influenced, so every component is walked from
# the CWD with dir_fd + O_NOFOLLOW, the same containment lib/audit_append.py
# applies to its writes.
#
# It does NOT reuse that module's open_state_dir(), and the difference matters
# twice: that walker CREATES missing components, because an appender must, and it
# reports a missing directory the same way it reports a symlinked one. A reader
# must do neither — creating `.claude` in every repo a merge happens in is a side
# effect the gate has no business having, and folding "absent" into "unsafe" made
# an ordinary repo with no state dir refuse every merge.
#
# Prints the file's contents on stdout. Exit 0 = read it, 1 = it is not there
# (including no state dir at all), 2 = the path is unsafe, the file is not a
# regular file, or it is larger than the gate will parse — every caller treats 2
# as a refusal.
state_file() {   # <read|unlink> <basename>
    # PYTHONSAFEPATH because this runs with the CWD set to the repository: with
    # `-c` the interpreter would otherwise put that directory first on sys.path
    # and import a repo-controlled os.py/stat.py from it. -I would also do it,
    # but -I implies -E and this payload needs PYTHONPATH for the gate's lib.
    # The payload scrubs sys.path itself as well, because PYTHONSAFEPATH is
    # honoured only from python 3.11 and an older one would ignore it silently.
    local _lib
    _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
    (cd "$REPO_DIR" 2>/dev/null && PYTHONSAFEPATH=1 PYTHONPATH="$_lib" python3 -S -c "
import sys
# BEFORE anything shadowable is imported. sys itself is built in, so it cannot
# be. This is the half that does not depend on the interpreter's version -
# PYTHONSAFEPATH is only honoured from 3.11, and on an older python the CWD
# would still be sys.path[0] here, with the CWD being the repository.
sys.path[:] = [q for q in sys.path if q not in ('', '.')]
import os, stat
mode, state_dir, name = sys.argv[1], sys.argv[2], sys.argv[3]
if '/' in name or name in ('.', '..') or state_dir.startswith('/'):
    raise SystemExit(2)
parts = [q for q in state_dir.split('/') if q and q != '.']
if any(q == '..' for q in parts):
    raise SystemExit(2)
dfd = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
try:
    for part in parts:
        try:
            nfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=dfd)
        except FileNotFoundError:
            raise SystemExit(1)       # no state dir: the file is simply absent
        except OSError:
            raise SystemExit(2)       # symlinked, or not a directory
        os.close(dfd)
        dfd = nfd
    if mode == 'unlink':
        try:
            os.unlink(name, dir_fd=dfd)
        except FileNotFoundError:
            raise SystemExit(1)
        except OSError:
            raise SystemExit(2)
        raise SystemExit(0)
    try:
        # O_NONBLOCK, or opening a FIFO here BLOCKS until a writer appears — the
        # 10s hook budget then kills the gate with no decision emitted, which is
        # a way through it rather than a hang. The flag makes the open return so
        # the regular-file test below can refuse.
        ffd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                      dir_fd=dfd)
    except FileNotFoundError:
        raise SystemExit(1)
    except OSError:
        raise SystemExit(2)           # a symlink at the leaf lands here
    try:
        if not stat.S_ISREG(os.fstat(ffd).st_mode):
            raise SystemExit(2)
        # LIMIT + 1, then refuse. A single fixed-size read silently TRUNCATED a
        # larger file, and truncation is not a parse error: 64 KiB of blank lines
        # followed by a real declaration read back as a file naming no branch,
        # which is how an operator says the repo has none — so an oversized file
        # disabled the gate instead of being rejected by it.
        limit = 1 << 16
        chunks, total = [], 0
        while total <= limit:
            chunk = os.read(ffd, limit + 1 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > limit:
            raise SystemExit(2)
        # These bytes cross back through a command substitution, and bash DISCARDS
        # NUL. A declaration of nothing but NULs therefore arrived as an empty
        # string — indistinguishable from the empty file that deliberately says
        # this repo has no protected branch, so it switched the gate off.
        if b'\0' in b''.join(chunks):
            raise SystemExit(2)
    finally:
        os.close(ffd)
    sys.stdout.buffer.write(b''.join(chunks))
    raise SystemExit(0)
finally:
    os.close(dfd)
" "$1" "$STATE_DIR" "$2" 2>/dev/null)
}

# Durable audit of every authorization this gate grants. Delegates to
# lib/audit_append.py for the same reason pre-merge-gate.sh does: a shell `>>`
# follows symlinks at every path component, and $STATE_DIR is repo-relative and
# therefore repo-influenced. An authorization that leaves no record is
# indistinguishable afterwards from a ref move the gate never saw, so a failed
# append BLOCKS.
audit_ref_ff() {   # <branch> <oid> <via>
    local _branch="$1" _oid="$2" _via="$3" _lib
    _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
    if ! (cd "$REPO_DIR" 2>/dev/null && PYTHONSAFEPATH=1 PYTHONPATH="$_lib" python3 -S -c "
import sys
_gatelib = [q for q in sys.path if q.endswith('gate-scripts/lib')]
sys.path[:] = [q for q in sys.path
               if q not in ('', '.') and q not in _gatelib] + _gatelib
from audit_append import append
import json, time
# BUILT here, not interpolated by the shell: a ref name may legally contain a
# double quote, and printf-ing it into a JSON template produced a malformed line
# that the appender stores verbatim — it checks durable bytes, not syntax — so
# the gate would have consumed a marker against an unparseable record.
rec = json.dumps({'ts': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  'event': 'ref-ff-authorized', 'gate': 'ref-ff',
                  'branch': sys.argv[2], 'oid': sys.argv[3],
                  'via': sys.argv[4]},
                 separators=(',', ':'))
raise SystemExit(0 if append(sys.argv[1], rec) else 1)
" "$STATE_DIR" "$_branch" "$_oid" "$_via" 2>/dev/null); then
        block_emit "Ref fast-forward gate: the fast-forward was authorized, but the authorization record could not be durably written to ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/bypass-log.jsonl. Blocking as precaution — an authorized ref move that leaves no record is indistinguishable afterwards from one the gate never saw. The write is refused when any path component is a symlink or not a directory, when the log is not a plain writable file, or when it ends in a torn line. Repair it and retry."
        exit 0
    fi
}

if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. All review gates require python3 for JSON parsing and command detection. Install python3 to restore gate enforcement. Escape hatch: $STATE_DIR/skip-litmus.local"
    exit 0
fi

# NOT `|| true`. Swallowing a read failure turned "the gate could not see the
# command" into "the gate saw nothing to do", and the exit that followed was a
# silent fail-OPEN — at the harness level too, since a non-blocking exit lets the
# Bash call through. The hook fires only on the Bash matcher, so a real dispatch
# is never empty; an empty payload means the same thing as a failed read.
if ! HOOK_DATA=$(cat 2>/dev/null) || [ -z "$HOOK_DATA" ]; then
    block_emit "Ref fast-forward gate: the hook payload could not be read from stdin, so the gate cannot tell whether this command moves a protected ref. Blocking as precaution (fail-closed)."
    exit 0
fi

# The hook has a 10s budget, and its expiry is NOT a block — the runner kills the
# process before anything can emit a decision, so a payload large enough to keep
# the parser busy is a way THROUGH the gate rather than a denial of service. The
# parser's cost tracks the command length, and the only length available before
# parsing is the payload's, so bound that. 64 KiB is far above any real Bash
# command and far below anything that could exhaust the budget.
if [ "${#HOOK_DATA}" -gt 65536 ]; then
    block_emit "Ref fast-forward gate: the hook payload is ${#HOOK_DATA} bytes, past the 64 KiB this gate will parse inside its 10s budget. A parse that outruns the budget is killed without emitting a decision, which would let the command through unexamined, so an oversized payload is refused instead. Split the command."
    exit 0
fi

# Pre-filter on the TOOL NAME only. A content pre-filter (…*git*merge*…) is what
# the sibling gates use, but it reads the payload as raw text while the shell
# reads it as TOKENS, and the two disagree: `g''it merge topic` runs a merge and
# contains no contiguous "git", so a content filter exits before the parser ever
# sees it. Splitting a word is free, so no substring test survives it. The parser
# below tokenizes properly (shlex joins the adjacent quotes back into `git`), so
# the filter's whole job here is to skip non-Bash tools; everything else is the
# parser's to decide. Cost is one python startup per Bash call, which the
# pre-implementation gate already pays on this same matcher.
case "$HOOK_DATA" in
    *\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Positional, newline-delimited protocol — identical framing rules to
# pre-commit-gate.sh, including its refusal of any emitted field containing a
# newline (which would shift every field after it and forge the frame).
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | PYTHONSAFEPATH=1 PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json
    from gitcmd_detect import (git_ref_op, REF_OP_UNRESOLVABLE,
                               REF_OP_FF_PREFIX, git_zero_old_ref_op)
    d = json.load(sys.stdin)
    def noop():
        # kind, target_dir, cwd, untrusted_cd, then a REAL operand count.
        for _i in range(4):
            print('')
        print(0)
        print('')
        print('')
        print('0')
        print(0)
        print('0')
        print('')
        print('')
        print('')   # ZERO_OLD_OPS (#780)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        noop()
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    kind, target_dir, ops, untrusted_cd, n_ops, ref_writer, aliases = git_ref_op(
        cmd, with_untrusted_cd=True)
    zero_ops, zero_target_dir, zero_untrusted = git_zero_old_ref_op(
        cmd, with_untrusted_cd=True, hook_cwd=cwd)
    if zero_ops:
        if zero_target_dir and not target_dir:
            target_dir = zero_target_dir
        if zero_untrusted:
            untrusted_cd = zero_untrusted
    # The pull's fast-forward mode rides along as a sentinel operand; split out
    # here so the operand count stays a count of REAL operands.
    ff_mode = ''
    for _o in ops:
        if _o.startswith(REF_OP_FF_PREFIX):
            ff_mode = _o[len(REF_OP_FF_PREFIX):]
    ops = [o for o in ops if not o.startswith(REF_OP_FF_PREFIX)]
    fields = [target_dir, cwd, untrusted_cd] + list(ops[:2])
    if any(not isinstance(v, str) or chr(10) in v or chr(13) in v for v in fields):
        raise ValueError('non-string or newline in an emitted field')
    print(kind)
    print(target_dir)
    print(cwd)
    print(untrusted_cd)
    print(len(ops))
    print(ops[0] if len(ops) > 0 else '')
    print(ops[1] if len(ops) > 1 else '')
    # Over EVERY operand, not just the two emitted. A live substitution is
    # tokenized into several words, so it inflates the operand COUNT as well
    # as hiding a value — a 'git merge' whose target is a substitution
    # arrives as two operands and
    # would otherwise take the octopus-merge exit below, which is a fail-OPEN
    # on the very shape the sentinel exists to stop.
    print('1' if any(o == REF_OP_UNRESOLVABLE for o in ops) else '0')
    print(n_ops)
    print('1' if ref_writer else '0')
    print(' '.join(aliases))
    print(ff_mode)
    _zparts = []
    for _zk, _zn in zero_ops:
        if not isinstance(_zk, str) or not isinstance(_zn, str):
            continue
        if chr(10) in _zk or chr(13) in _zk or chr(10) in _zn or chr(13) in _zn:
            raise ValueError('newline in zero-old field')
        if ' ' in _zk or ' ' in _zn or ':' in _zk or ':' in _zn:
            _zparts.append('force:')  # unreadable → empty name
        else:
            _zparts.append(_zk + ':' + _zn)
    print(' '.join(_zparts))
except Exception:
    for _ in range(13):
        print('error' if _ == 0 else '')
" 2>/dev/null) || PARSE_RESULT=""

KIND=$(echo "$PARSE_RESULT" | sed -n '1p')
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '3p')
UNTRUSTED_CD=$(echo "$PARSE_RESULT" | sed -n '4p')
NOPS=$(echo "$PARSE_RESULT" | sed -n '5p')
OP1=$(echo "$PARSE_RESULT" | sed -n '6p')
OP2=$(echo "$PARSE_RESULT" | sed -n '7p')
UNRESOLVABLE=$(echo "$PARSE_RESULT" | sed -n '8p')
NOPERATIONS=$(echo "$PARSE_RESULT" | sed -n '9p')
REF_WRITER=$(echo "$PARSE_RESULT" | sed -n '10p')
ALIAS_CANDIDATES=$(echo "$PARSE_RESULT" | sed -n '11p')
FF_MODE=$(echo "$PARSE_RESULT" | sed -n '12p')
ZERO_OLD_OPS=$(echo "$PARSE_RESULT" | sed -n '13p')

if [ "$KIND" = "error" ]; then
    block_emit "Ref fast-forward gate: failed to parse tool input for a command matching the git merge/pull pattern. Blocking as precaution (fail-closed). If stuck, create $STATE_DIR/skip-litmus.local in your terminal."
    exit 0
fi
# BEFORE the no-op exit below, not after it. The operand count frames every branch
# from here on, and on a real frame it is ALWAYS numeric — `0` for a command with
# no merge in it. So a non-numeric value is not "nothing to do", it is "the parser
# never answered": the Python handler covers what it can catch, but a status it
# cannot catch (no interpreter, an import failure, the process killed) leaves this
# variable empty, and an empty KIND then read as a clean no-op and exited 0. That
# ordering was the whole fail-open; the check itself was already here.
# Counting the frame's LINES cannot do this job — the trailing fields are legally
# empty and command substitution strips them, so a correct frame arrives short.
case "$NOPS" in
    ''|*[!0-9]*)
        block_emit "Ref fast-forward gate: the command parser did not return a readable frame, so the gate cannot tell whether this command moves a protected ref. Blocking as precaution (fail-closed)."
        exit 0 ;;
esac
# Any operand the parser refused to resolve poisons the WHOLE invocation — the
# ref it names is unknown AND the operand count it inflates is wrong — so this
# must be decided before either the merge or the pull branch reads those fields.
# One command, several merge/pull operations: only the FIRST is described by the
# fields above, so evaluating it would wave the rest through — and the opener can
# be a deliberate no-op chosen for exactly that (`git merge HEAD && git merge
# feature`). Refuse the whole command rather than authorize a part of it. This is
# where the gate departs from pre-commit-gate.sh's accepted first-match residual:
# there every match is still a `git commit` the marker check covers.
case "$NOPERATIONS" in
    ''|*[!0-9]*)
        block_emit "Ref fast-forward gate: unreadable operation count from the command parser. Blocking as precaution (fail-closed)."
        exit 0 ;;
esac
if [ "$NOPERATIONS" -gt 1 ]; then
    block_emit "Ref fast-forward gate: this command carries $NOPERATIONS separate git merge/pull operations. The gate scopes one operation at a time, so authorizing this would leave the others unexamined — and the first can be a no-op that passes while a later one fast-forwards the protected branch to unreviewed content. Run them as separate commands. Blocking as precaution (fail-closed)."
    exit 0
fi
case "$REF_WRITER" in
    0|1) ;;
    *) block_emit "Ref fast-forward gate: unreadable ref-writer flag from the command parser. Blocking as precaution (fail-closed)."; exit 0 ;;
esac
if [ "$UNRESOLVABLE" = "1" ]; then
    block_emit "Ref fast-forward gate: an operand of this git merge/pull cannot be resolved statically (it uses a substitution or variable), so the gate cannot tell what content the protected branch would move to. Resolve it first (git rev-parse it, then name the ref or oid literally). Blocking as precaution (fail-closed)."
    exit 0
fi

gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD" "$UNTRUSTED_CD"
if [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ]; then
    block_emit "Ref fast-forward gate: the command's cd target cannot be resolved statically. Either it uses a substitution or variable (cd \"\$(...)\", cd \$DIR, cd -, a glob), or it is a plain 'cd <dir>' that is NOT '&&'-joined to the git merge/pull and resolves to a DIFFERENT repo than the session cwd -- so the gate cannot tell which repo's protected branch would move. Run it from the repo root, join the cd with '&&' (cd /repo && git merge X), use git -C /repo, or use cd \"\$(git rev-parse --show-toplevel)\" which the gate recognizes. Blocking as precaution (fail-closed)."
    exit 0
fi
# Genuinely not in a git repo → no ref can move (git fails on its own) — but that
# rationale only covers a REAL subcommand. Since #812 the anchor can be a literal
# `git -C` the COMMAND chose, so this exit became reachable with an agent-picked
# target, and a `!`-shell alias resolved there is not a git operation at all: with
# a global `alias.zz = !git -C /session merge feature`, `git -C /any-non-repo zz`
# runs the merge in the SESSION repo while git never fails here. Defer the exit
# until the builtin filter below has ruled the words out; an unresolved one blocks.
# (A BARE repo answers exit-0 `false` to --is-inside-work-tree, so it resolves
# `proceed` and never reached this line — only a directory outside every repo did.)
OUTSIDE_REPO=0
[ "$GATE_RESOLVE_STATUS" = "outside-repo" ] && OUTSIDE_REPO=1
REPO_DIR="$GATE_REPO_DIR"

# Block messages are text an operator PASTES, so anything interpolated into a
# command line there has to be a single safely-quoted word first — and it cannot
# be quoted inline, because these messages are themselves double-quoted strings.
# Every input here is attacker-influenceable: the repo path and state dir come
# from the hook payload, and git accepts a branch or remote name containing
# quotes, semicolons and dollar signs (it refuses spaces, control characters, a
# leading dash, `..`, `@{` and a trailing dot or .lock — not those).
printf -v Q_REPO '%q' "${REPO_DIR:-.}"
printf -v Q_STATE '%q' "$STATE_DIR"

# Every git subcommand word the parser did not recognize arrives in
# ALIAS_CANDIDATES, `commit` and `add` included. Reduce it to the words that
# resolve to NOTHING here and now — those are the only ones that could still
# become a merge — before deciding this command concerns the gate at all.
# Otherwise `git status && git commit` walked into protected-branch discovery and
# could be refused by the empty-set or remote-count checks, which have nothing to
# do with it. BUILT-INS only, deliberately not `,alias`: an alias's current value
# proves nothing when a companion command can rewrite it first.
UNKNOWN_CANDIDATES=""
ALIAS_HIT=""
ALIAS_HIT_CAND=""
if [ -n "$ALIAS_CANDIDATES" ]; then
    _KNOWN_CMDS=$(git_real --list-cmds=main,others 2>/dev/null) || _KNOWN_CMDS=""
    for _cand in $ALIAS_CANDIDATES; do
        if [ -n "$_KNOWN_CMDS" ] && printf '%s\n' "$_KNOWN_CMDS" | grep -Fqx -- "$_cand"; then
            continue
        fi
        UNKNOWN_CANDIDATES="$UNKNOWN_CANDIDATES $_cand"
    done
fi
# Everything below keys off whether the anchor was chosen by the COMMAND, which
# is what $TARGET_DIR being non-empty means: the parser fills it from a literal
# `git -C` or a trusted `cd`, and leaves it empty when the gate is to anchor on
# the session cwd itself.
#
# Why that has to be distinguished: the gate reads its CONSENT artifacts —
# `skip-litmus.local`, `ref-ff-protected.local` — from $REPO_DIR, but a resolved
# alias's EFFECT is not confined to $REPO_DIR, because a `!`-shell alias runs an
# arbitrary command and can name any repository. While the anchor was always the
# session cwd those were the same repo, so consent covered effect. A
# command-chosen anchor separates them: `git -C /any-other-worktree zz` would
# spend THAT repo's skip file — the routine, per-worktree, operator-created
# escape hatch — and exit before the alias refusals ever run, while the alias
# fast-forwards a protected ref somewhere else entirely.
#
# Qualified by UNKNOWN_CANDIDATES, not by an empty $KIND. Keying on $KIND was the
# first shape and it had a hole: `git -C /x merge HEAD && git -C /x zz feature`
# carries a literal (no-op) merge, so KIND is `merge`, and the unresolved `zz`
# rode through behind it. Keying on $TARGET_DIR ALONE is the opposite error — it
# would stop honouring the skip file for an ordinary `cd /repo && git merge
# feature`, which is exactly what the operator armed it for. The unresolved word
# is the thing consent cannot cover, so its presence is the right qualifier, and
# it must be the post-filter set: ALIAS_CANDIDATES still holds `add`/`commit`.
CMD_CHOSEN_ANCHOR=0
if [ -n "$TARGET_DIR" ] && { [ -z "$KIND" ] || [ -n "$UNKNOWN_CANDIDATES" ]; }; then
    CMD_CHOSEN_ANCHOR=1
    # ...unless the directory it named IS the session's own, where consent and
    # effect do not actually diverge. Without this the operator's escape hatch
    # silently depended on whether they typed a redundant absolute `-C`: that
    # command and the bare one from the same shell would disagree about whether
    # the skip file works.
    #
    # The test is LEXICAL — the `-C` operand as written against the payload cwd
    # as written — and deliberately not the equality of the two RESOLVED repo
    # roots this first shipped with. Resolution reads the filesystem, and the
    # filesystem is not stable across the gap between this read and git's own
    # chdir: `ln -sfn /elsewhere /link && git -C /link <word>` resolves into the
    # session repo HERE, clears the anchor, and spends this repo's skip file or
    # empty declaration — while git, chdir-ing after the retarget, resolves the
    # `!`-alias in /elsewhere and can fast-forward a protected ref there. A
    # string comparison cannot be moved by anything the command does first.
    # It also answers for a BARE repository, where both `--show-toplevel` calls
    # fail and the old comparison could never fire at all — so `git -C /bare
    # merge HEAD && git -C /bare zz` stopped honouring the very override the
    # equivalent bare-form command was given.
    #
    # Fails CLOSED on anything it cannot match exactly: a trailing slash, or any
    # other spelling of the same directory, keeps the anchor command-chosen.
    #
    # The exemption is for the LONE command that names its own cwd. It is refused
    # when the invocation carries a companion, because the retarget the lexical
    # test was chosen to survive can equally be aimed at the cwd's OWN pathname:
    # `mv /repo /repo.bak && ln -s /elsewhere /repo && git -C /repo <word>`
    # matches HOOK_CWD as a string, would clear the anchor, and would spend THIS
    # repo's skip file — while git, chdir-ing after the rename, resolves the
    # `!`-alias in /elsewhere. There IS a static test for that: REF_WRITER is
    # `_has_companion_command`, "anything besides the git op and a plain cd",
    # already computed for this very command, and the rename+symlink shape cannot
    # be spelled without companion segments. (The earlier note here said no such
    # test existed on this side; it does, so the residual is closed rather than
    # named.) A lone `git -C <own cwd> <word>` — the shape the exemption exists
    # for — carries no companion and is unaffected.
    if [ "$REF_WRITER" = "0" ] && [ -n "$HOOK_CWD" ] && [ "$TARGET_DIR" = "$HOOK_CWD" ]; then
        CMD_CHOSEN_ANCHOR=0
    fi
fi
if [ "$OUTSIDE_REPO" = "1" ]; then
    # Anchor the gate derived ITSELF → the original unconditional exit, unchanged:
    # genuinely not in a git repo, so no ref can move and git fails on its own.
    # Kept, rather than folded into the refusal below, because that refusal is a
    # BLOCK and this shape reaches it in ordinary use: run from a directory
    # outside every repo, a global alias (`git lg -1` from /tmp) is not in
    # --list-cmds and so lands in UNKNOWN_CANDIDATES. #812 never touched that
    # shape, and it has no escape hatch here — a skip file inside a non-repo
    # directory is not a thing the tooling describes.
    #
    # STANDING RESIDUAL, named deliberately and NOT introduced here: this exit was
    # UNCONDITIONAL before #812, so a global `alias.zz = !git -C /protected merge
    # feature` run as `git zz` from a non-repo cwd has always passed. Closing it
    # means blocking every non-builtin git word in every directory outside a
    # repository, with no escape hatch reachable there — a broad over-block of the
    # exact kind #812 was filed about, and a change to behaviour this issue does
    # not touch. It belongs in its own issue, with its own cost discussion. What
    # #812 must not do is make it WORSE, and the branch below is what stops the
    # new command-chosen anchor from reaching it.
    [ "$CMD_CHOSEN_ANCHOR" = "1" ] || exit 0
    # `--list-cmds` needs no repository, so the filter above is still authoritative
    # here: every word it recognised is a real git subcommand, which genuinely
    # cannot move a ref from outside a work tree. A word it did NOT recognise can
    # still be a `!`-shell alias that operates somewhere else entirely, and this is
    # the one place that could wave it through, so it fails CLOSED instead.
    [ -z "$UNKNOWN_CANDIDATES" ] && exit 0
    block_emit "Ref fast-forward gate:$UNKNOWN_CANDIDATES resolves to no git subcommand, and ${REPO_DIR:-.} is not a work tree — so the gate cannot rule out that it is a '!'-shell alias, which git runs from outside a repository just as happily and can move a protected ref in ANOTHER one. Run the underlying 'git merge' / 'git pull' directly, from the repository it targets.

There is no skip file for this one: the target is not a work tree, so no $STATE_DIR/skip-litmus.local can live there, and a command-chosen anchor does not spend another repository's. Run it as its own call, without the 'git -C ${REPO_DIR:-.}' or the leading 'cd' that pointed the gate there — whichever this command used — so the gate anchors on the session directory itself. Blocking as precaution (fail-closed)."
    exit 0
fi
if [ -z "$KIND" ] && [ -z "$UNKNOWN_CANDIDATES" ] && [ -z "$ZERO_OLD_OPS" ]; then
    exit 0
fi

# ── Skip override (same anti-self-bypass shape as the sibling gates) ──
# NOT honoured on a command-chosen anchor: the operator armed this file for the
# repository they were working in, and a `git -C <that repo> <word>` issued from
# elsewhere would spend it while the alias acts on a DIFFERENT repository. Consent
# is per-repo (`tests/…: a marker in ANOTHER repo does not authorize this one`),
# so a command that picks its own anchor cannot be the one to redeem it. The
# operator's escape hatch is unchanged wherever they actually are — run the
# command from that repo and the anchor is the gate's own again.
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-litmus.local"
if [ "$CMD_CHOSEN_ANCHOR" != "1" ] && [ -f "$SKIP_FILE" ] \
   && ! gate_skip_file_repo_controlled "$REPO_DIR" "$STATE_DIR/skip-litmus.local"; then
    SKIP_AGE=999
    _SKIP_MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null) \
        || _SKIP_MTIME=$(stat -c %Y "$SKIP_FILE" 2>/dev/null) \
        || _SKIP_MTIME=""
    [ -n "$_SKIP_MTIME" ] && SKIP_AGE=$(( $(date +%s) - _SKIP_MTIME ))
    if [ "$SKIP_AGE" -lt 30 ]; then
        rm -f -- "$SKIP_FILE"
        block_emit "BLOCKED: skip-litmus.local was created moments ago (likely self-bypass). Do NOT create ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/skip-litmus.local yourself. If the user wants to skip, they should create the file manually in their terminal."
        exit 0
    fi
    # A VALID skip file is passed through read-only: it is shared with the
    # commit/PR gates, and spending it here would silently shorten the review
    # window the operator armed for those. (Only the self-bypass branch above
    # deletes, matching pre-commit-gate.sh and pre-merge-gate.sh — a fresh
    # self-created file must not survive as a free probe.)
    exit 0
fi

# ── Which branch is protected, and which ref its pulls must come from ──
# The default branch, resolved from origin/HEAD and falling back to the
# conventional names. When no default branch exists at all there is no protected
# ref to guard, so there is nothing for this gate to enforce.
# ── Resolve config-defined aliases ────────────────────────────────────
# The one part of the alias problem a command-string parser cannot answer: an
# alias in a config FILE (`git config alias.m merge`, then `git m topic`) is
# nowhere in the command. The gate CAN answer it, because it has the repo — so
# the parser reports every subcommand it did not recognize and each is resolved
# here. Real subcommands land in that list too and simply have no alias entry,
# which is why no list of git's own subcommands has to be maintained.
if [ -n "$ALIAS_CANDIDATES" ]; then
    # More candidates than the parser reports means the command names more git
    # subcommands than this gate will resolve; refuse rather than check a subset.
    if [ "$(printf '%s' "$ALIAS_CANDIDATES" | wc -w | tr -d ' ')" -gt 5 ]; then
        block_emit "Ref fast-forward gate: this command names more unrecognized git subcommands than the gate resolves aliases for, so it cannot rule out that one of them is an alias for merge or pull. Blocking as precaution (fail-closed)."
        exit 0
    fi
    # Git IGNORES an alias that shadows a built-in, so `alias.commit = merge`
    # leaves `git commit` running the built-in. Refusing on such an entry would
    # block ordinary commands for a setting git never honours.
    _BUILTIN_CMDS=$(git_real --list-cmds=main,others 2>/dev/null) || _BUILTIN_CMDS=""
    for _cand in $ALIAS_CANDIDATES; do
        if [ -n "$_BUILTIN_CMDS" ] && printf '%s\n' "$_BUILTIN_CMDS" | grep -Fqx -- "$_cand"; then
            continue
        fi
        # Git expands an ordinary alias whose value names ANOTHER alias, so a
        # chain has to be followed: with alias.m=n and alias.n='merge --ff-only',
        # `git m topic` merges. Bounded, and loop-guarded, so a cycle or a chain
        # too long to follow fails CLOSED rather than looping or falling through.
        _name="$_cand"; _seen=""; _expansion=""; _hit=""
        for _hop in 1 2 3 4 5; do
            _expansion=$(git_real config --get "alias.$_name" 2>/dev/null) || _expansion=""
            [ -z "$_expansion" ] && break
            case "$_expansion" in
                # A `!`-prefixed alias runs an arbitrary shell command; its
                # contents are outside this parser, so it can never be cleared.
                '!'*) _hit="$_expansion"; break ;;
            esac
            # Git splits an expansion on ANY whitespace, so the first WORD is what
            # runs — matching only a literal space missed `merge<TAB>--ff-only`.
            # Git tokenizes an expansion on ANY whitespace, newlines included, so
            # the first WORD can sit on the second line. `read` stops at the first
            # newline and returned an empty word for `\nmerge --ff-only`.
            read -r _first _rest <<<"$(printf '%s' "$_expansion" | tr '\n\r\t' '   ')" || true
            # Git applies its OWN quote and backslash processing to an expansion,
            # so `'merge' --ff-only`, `m''erge …` and `m\\e\\r\\g\\e …` all run
            # `merge`. Comparing the raw word matched none of them and then
            # followed a non-existent alias, allowing the command. Stripping the
            # quoting characters is what makes the comparison see what git sees.
            _first=$(printf '%s' "$_first" | tr -d "'\"\\\\")
            case "$_first" in
                merge|pull) _hit="$_expansion"; break ;;
                # #780 ZERO-old alias bodies (branch -f / checkout -B / update-ref)
                branch|checkout|switch|update-ref|symbolic-ref) _hit="$_expansion"; break ;;
                # Git applies leading GLOBAL options from an expansion before the
                # subcommand — `-c color.ui=false merge --ff-only` runs a merge.
                # Following `alias.-c` found nothing and allowed the command; and
                # a `-c` here is the same config override the gate refuses on a
                # command line, so an expansion starting with one is unresolvable.
                -*) _hit="$_expansion"; break ;;
            esac
            case " $_seen " in *" $_first "*) _hit="$_expansion"; break ;; esac
            _seen="$_seen $_first"
            _name="$_first"
            [ "$_hop" = "5" ] && _hit="$_expansion"
        done
        # A resolved-and-harmless alias is NOT recorded as safe, and that was
        # tried. With file config `alias.lg = log` and an ambient
        # `GIT_CONFIG_KEY_n=alias.lg` / `VALUE_n=merge`, the gate reads the file
        # value, calls it benign, and the command runs the env one — the same
        # invisible-config gap the pull arm was deleted for. On a protected branch
        # the cost of over-blocking a word like `lg` is one re-typed command;
        # the cost of trusting a config view the command does not share is the
        # gate. Off the protected branch nothing here fires at all.
        [ -z "$_hit" ] && continue
        # NOT refused here. This runs before the protected branch is known, so
        # refusing on the spot blocked `git m feature` on a FEATURE branch — an
        # alias reaching merge is ordinary work anywhere else. Recorded, and
        # refused beside the other shape refusals, which are placed to answer the
        # question a companion command makes unanswerable.
        ALIAS_HIT_CAND="$_cand"
        ALIAS_HIT="$_hit"
        break
    done
fi

# A SET, not a single name. `refs/remotes/origin/HEAD` is an ordinary local ref
# that `git remote set-head origin feature` rewrites, so reading the default
# branch from it alone let an earlier command re-point it and make every later
# merge onto main fall through the "not the protected branch" exit. The
# conventional names are therefore always in the set when they exist locally, so
# re-pointing origin/HEAD can only ADD to what is protected, never remove.
PROTECTED_SET=""
_CANDIDATES=""
# Discovery spawns one `git symbolic-ref` per remote, inside a 10s hook budget
# whose expiry is NOT a block — the runner kills the process before anything can
# emit a decision, so an unbounded loop here is a way THROUGH the gate, the same
# shape as the oversized-payload case above. Remotes are repo-controlled and cost
# nothing to add. Count first, and refuse rather than start a walk that might not
# finish: 64 is far past any real remote list and far short of a budget problem.
# `head` so the READ is bounded too, not only the walk it guards: reading an
# unbounded list to find out it is unbounded spends the same budget the check
# exists to protect.
# ONE bound, on BYTES, and the name count is taken from what it read. A line
# bound alone says nothing about how much there is to read -- ten names of
# 100 KiB each are ten lines and a megabyte -- and chaining a second `head` to
# add one is worse than useless: whichever of the two fills first closes the
# pipe on the other, so the pipeline reports 141 and the generic ERR block fires
# instead of the message that explains what to do. 64 KiB holds any real remote
# list many times over; reaching it, or counting more than 64 names inside it,
# is the same answer: a listing this gate will not walk.
# The `|| true` is load-bearing under `pipefail`. head closing the pipe kills
# git with SIGPIPE on exactly the oversized list this guards against, and a
# failed pipeline would fall through to a zero count and wave that case
# through -- a fail-OPEN reachable by adding remotes. Swallowing git's status
# keeps the answer head's: what was read is what is judged.
# shellcheck disable=SC2310  # git's status is deliberately not the answer here
_RLIST=$( { git_real remote 2>/dev/null || true; } | head -c 65536 && printf X)
_RLIST="${_RLIST%X}"
# grep -c counts lines; a listing of none exits nonzero, which is the count 0.
# shellcheck disable=SC2310  # no match IS the zero answer
_NREMOTES=$(printf '%s' "$_RLIST" | grep -c '^') || _NREMOTES=0
_RBYTES=$(printf '%s' "$_RLIST" | wc -c | tr -d ' ')
if [ "$_NREMOTES" -gt 64 ] || [ "$_RBYTES" -ge 65536 ]; then
    block_emit "Ref fast-forward gate: ${REPO_DIR:-.} has a remote listing this gate cannot examine inside its 10s budget — $_NREMOTES names in $_RBYTES bytes read, past the 64 this gate can examine (and past the 64 KiB it will read to count them). Discovery reads each remote's published HEAD to learn which branch is protected, and a walk that outruns the budget is killed without emitting a decision — which would let the command through unexamined. Name the protected branches directly instead, one per line:
  echo main > $Q_STATE/ref-ff-protected.local"
    exit 0
fi
# EVERY remote's HEAD, not just origin's: a repo whose remote is named `upstream`
# has no refs/remotes/origin/HEAD at all, and reading only that one left the set
# empty and the gate disabled — a fail-OPEN on the very branch it exists to guard.
# The SNAPSHOT the count was taken from, not a second `git remote`. Two reads are
# two lists: the one that was measured and found small, and the one actually
# walked. Walking a list nobody bounded is the budget hole the count exists to
# close, whatever moved the config in between.
while IFS= read -r _r; do
    [ -z "$_r" ] && continue
    # Strip the REMOTE'S OWN name, not "everything up to the first slash": a
    # remote may legally be named `team/origin`, whose short HEAD is
    # `team/origin/release` — cutting one component left `origin/release`, which
    # matches no local branch, so that protected branch silently dropped out.
    _h=$(git_real symbolic-ref --short "refs/remotes/$_r/HEAD" 2>/dev/null) || _h=""
    _h=${_h#"$_r/"}
    [ -n "$_h" ] && _CANDIDATES="$_CANDIDATES $_h"
done <<EOF
$_RLIST
EOF
# The repo's configured default, and the conventional names. `trunk`/`develop`
# are as much a default branch as `main`, and omitting them disabled the gate
# for every repo that uses one.
_INIT_DEFAULT=$(git_real config --get init.defaultBranch 2>/dev/null) || _INIT_DEFAULT=""
for _b in $_CANDIDATES "$_INIT_DEFAULT" main master trunk develop development default; do
    [ -z "$_b" ] && continue
    git_real show-ref --verify --quiet "refs/heads/$_b" 2>/dev/null || continue
    case " $PROTECTED_SET " in *" $_b "*) continue ;; esac
    PROTECTED_SET="$PROTECTED_SET $_b"
done
# No protected branch exists at all → nothing for this gate to enforce.
# Last resort for a project whose protected branch is none of the discoverable
# ones (`release`, say, with no <remote>/HEAD and a different init.defaultBranch).
# The gate cannot infer that name, so the operator names it: one branch per line
# in $STATE_DIR/ref-ff-protected.local, gitignored like every other .local.
# DECLARED is "the operator wrote the file"; DECL_LISTED is "the file names at
# least one branch". They differ on the case that matters: a file naming only
# `releaze` leaves the set empty exactly like an empty file does, but it is a TYPO
# — the operator meant to protect something — where an empty file is a deliberate
# "this repository has none". Treating both as the statement let one mistyped
# character disable the gate silently.
DECLARED=0
DECL_LISTED=0
# Read through the O_NOFOLLOW walker, never through the path. A symlink anywhere
# in $STATE_DIR — not only at the leaf — otherwise made the test describe one file
# and the read take another. Status 2 is "unsafe or unreadable", which is a
# refusal: this file decides what the gate guards, and one naming no branch turns
# the gate off, so an unreadable one must not be treated as absent.
_DECL_RC=0
_DECL_CONTENT=$(state_file read ref-ff-protected.local) || _DECL_RC=$?
if [ "$_DECL_RC" -eq 2 ]; then
    block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local could not be read safely — it is a symlink, sits behind a symlinked path component, or is not a regular file. This file decides which branches this gate guards, and a file naming none turns the gate off, so it is honoured only as a regular file the operator wrote in place. Replace it with the file itself."
    exit 0
fi
if [ "$_DECL_RC" -eq 0 ]; then
    # Held to the SAME standard as the authorization marker, and for a stronger
    # reason. This file can say "no protected branch" (by naming none), so a
    # repository that could supply it could switch the gate off by committing an
    # empty one — consent authenticated by CONTENT, which is repo-injectable, when
    # this repo's own rule is to authenticate it by LOCATION. Treating it as
    # absent would be quieter but wrong: an operator's real file and an injected
    # one would then behave identically from the outside. Refuse loudly instead.
    if gate_skip_file_repo_controlled "$REPO_DIR" "$STATE_DIR/ref-ff-protected.local"; then
        block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local is repo-controlled — it is tracked in the index or HEAD, reached through a gitlink, or is a symlink. This file decides which branches this gate guards, and a file that names none turns the gate off, so a repository that can supply it can disable its own enforcement. It is only honoured as an untracked, non-symlink regular file the operator wrote.

Untrack it and write it locally instead:
  git -C $Q_REPO rm --cached $Q_STATE/ref-ff-protected.local
  echo <branch> > $Q_STATE/ref-ff-protected.local"
        exit 0
    fi
    DECLARED=1
    # `|| [ -n "$_b" ]` because a file whose LAST line has no trailing newline
    # leaves that line in $_b with read returning non-zero — the loop would drop
    # it. When that dropped line is the only declaration, $PROTECTED_SET stays
    # empty and the gate exits 0 on the branch it was written to guard.
    while IFS= read -r _b || [ -n "$_b" ]; do
        # A CRLF file would otherwise declare `release<CR>`, which matches no
        # branch name — silently disabling the very fallback it was written for.
        _b=${_b%$'\r'}
        # NO comment syntax, deliberately. `#release` is a perfectly valid branch
        # name (git only forbids a leading `-`, `..`, and a handful of characters),
        # so treating `#` as a comment silently dropped a branch an operator had
        # declared in the documented one-per-line format. Blank lines are skipped
        # because they carry no name; everything else is a name, and one that does
        # not resolve now blocks rather than vanishing.
        case "$_b" in '') continue ;; esac
        DECL_LISTED=$((DECL_LISTED + 1))
        # Bounded for the same reason the remote walk is: one `git show-ref` per
        # line, inside a 10s budget whose expiry emits no decision, over a file
        # whose length nothing else constrains. 64 names is far past any real
        # policy.
        if [ "$DECL_LISTED" -gt 64 ]; then
            block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local lists more than 64 branches. Each one costs a git lookup inside this gate's 10s budget, and a walk that outruns the budget is killed without emitting a decision — which would let the command through unexamined. Keep the list to the branches that are actually protected."
            exit 0
        fi
        # Same existence test discovery applies to its own candidates — but the
        # consequence is the opposite. A DISCOVERED name that does not exist is a
        # guess that missed, and skipping it is right. A DECLARED one is the
        # operator saying "guard this", so a name that resolves to nothing is a
        # typo, and the gate must say so rather than quietly guard less than was
        # asked. Deferring that to the empty-set check was not enough: in a repo
        # that also has `main`, the set is non-empty and `releaze` vanished
        # silently, which is exactly the case an operator would not notice.
        if ! git_real show-ref --verify --quiet "refs/heads/$_b" 2>/dev/null; then
            block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local declares '$_b' as a protected branch, but no such branch exists in ${REPO_DIR:-.}. The gate will not quietly guard less than was declared — a name that resolves to nothing is a typo, not a narrower policy.

Check it against:
  git -C $Q_REPO branch --format='%(refname:short)'
(Remove the line if that branch is gone for good. An EMPTY file is how you say this repository has no protected branch.)"
            exit 0
        fi
        case " $PROTECTED_SET " in *" $_b "*) continue ;; esac
        PROTECTED_SET="$PROTECTED_SET $_b"
    done <<EOF
$_DECL_CONTENT
EOF
fi
# DISCOVERY IS BEST-EFFORT, and the conventional names are what make it durable.
# refs/remotes/<r>/HEAD and init.defaultBranch are both writable by a separate
# command (`git remote set-head origin -d` deletes the first), so a branch known
# ONLY through them can be dropped from this set by an earlier call. For
# main/master/trunk/develop/development/default that does not matter — the name
# list is in this file and no repository state can reach it. For any other name it
# does, and the answer is the operator declaration read just below: it is
# forge-guarded (marker_check.py), so no tool call can remove it, which the remote
# HEAD it replaces is not. A project whose protected branch is not a conventional
# name should declare it rather than rely on discovery.
# The same non-regression bound as the other residuals applies: deleting a remote
# HEAD is a ref write. #780 covers ZERO-old force/delete of protected names;
# creation-at-unreachable-content remains #781.

_PROT_LIST=${PROTECTED_SET# }

# An empty set used to exit 0 — the gate's one documented non-fail-closed point,
# and the place every mutable-discovery finding landed: delete the remote HEAD a
# non-conventional default was found through and the set empties, so the branch
# stops being guarded. It is now a BLOCK, which removes that lever entirely.
# The escape is the same declaration file, and its EXISTENCE is the operator's
# statement: a file listing branches names them, and a file that names none (empty,
# or comments only) says "this repository has no protected branch" deliberately.
# Absence of the file is not that statement — it is the gate having nothing to go
# on, which is the failure case, not the happy path.
if [ -z "$PROTECTED_SET" ]; then
    if [ "$DECLARED" = "1" ] && [ "$DECL_LISTED" -gt 0 ]; then
        block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local names $DECL_LISTED branch(es), but none of them exists in ${REPO_DIR:-.} — so the gate is guarding nothing while the file says otherwise, which is what a typo looks like. A file that names NO branch is the deliberate 'this repository has none'; a file that names branches which do not exist is not.

Check the spelling against:
  git -C $Q_REPO branch --format='%(refname:short)'"
        exit 0
    fi
    # The empty declaration is the other per-repo consent artifact, and it is
    # withheld from a command-chosen anchor for the same reason as the skip file:
    # "this repository has no protected branch" is a statement about THAT
    # repository, and a `!`-shell alias resolved there acts on whichever one its
    # body names. Refused with its own message rather than falling through to the
    # "cannot identify a protected branch" one below — the operator DID answer
    # that question, and #812 is itself a report of a block explaining the wrong
    # thing.
    if [ "$DECLARED" = "1" ]; then
        if [ "$CMD_CHOSEN_ANCHOR" != "1" ]; then
            exit 0
        fi
        block_emit "BLOCKED:$UNKNOWN_CANDIDATES resolves to no git subcommand, and this command chose its own anchor with 'git -C ${REPO_DIR:-.}'. That repository's $STATE_DIR/ref-ff-protected.local declares it has no protected branch — but an unresolved word there can be a '!'-shell alias, which runs an arbitrary command and can fast-forward a protected ref in a DIFFERENT repository, one this declaration says nothing about. Run the underlying 'git merge' / 'git pull' directly, from the repository it targets. Blocking as precaution (fail-closed)."
        exit 0
    fi
    if [ -n "$ZERO_OLD_OPS" ] && [ -z "$KIND" ]; then
        block_emit "BLOCKED: this command force-updates or deletes a branch ref (issue #780), and the gate cannot identify a protected branch in ${REPO_DIR:-.} — none of main, master, trunk, develop, development or default exists locally, no remote publishes a HEAD, and init.defaultBranch names nothing that exists. It therefore cannot tell whether the target is protected.

Say which branches are protected, one per line, in their own terminal:
  echo release > $Q_STATE/ref-ff-protected.local

If this repository genuinely has no protected branch, say THAT — an empty file is the deliberate statement, and the gate then stays out of the way:
  : > $Q_STATE/ref-ff-protected.local"
        exit 0
    fi
    block_emit "BLOCKED: this command runs a git merge/pull, and the gate cannot identify a protected branch in ${REPO_DIR:-.} — none of main, master, trunk, develop, development or default exists locally, no remote publishes a HEAD, and init.defaultBranch names nothing that exists. It therefore cannot tell whether this would fast-forward a protected ref, which creates no commit object and so passes every other review gate unseen (issue #779).

Say which branches are protected, one per line, in their own terminal:
  echo release > $Q_STATE/ref-ff-protected.local

If this repository genuinely has no protected branch, say THAT — an empty file is the deliberate statement, and the gate then stays out of the way:
  : > $Q_STATE/ref-ff-protected.local"
    exit 0
fi

# The gate resolves its target BEFORE the command runs, so ANY other command in
# the same invocation can replace what was checked: `git branch -f topic
# <unreviewed> && git merge topic` passes the no-op exit further down, then moves
# `topic` and fast-forwards to the unchecked oid. Enumerating which companions are
# dangerous was tried and abandoned — `git config`, `git fast-import`, `git
# difftool`, `git grep --open-files-in-pager=<cmd>`, `unset HOME`, a shell script
# — so the rule is now the class: anything but a scoping `cd`.
# Checked BEFORE the current branch is read, and deliberately so: a companion
# can change WHICH branch is checked out. `git switch main && git merge
# <unreviewed>` was read as ordinary feature work — HEAD said `feature` when the
# gate looked — and fast-forwarded main a moment later. The branch the gate can
# see is a pre-command value, so it cannot qualify this rule; the ordinary
# `git fetch … && git merge …` therefore needs two calls on any branch now.
# An unknown git word could still become a merge. Two ways, and the gate can tell
# neither from a typo: another command in the same call can define
# `alias.<word> = merge` before it runs, and an alias set through the
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n family is stripped from this gate's
# environment (#325 / ADR 0016) and still live for the command. Refusing a word
# that resolves to nothing costs almost nothing — one that is neither a builtin,
# nor a git-* on PATH, nor a config alias is one git itself would reject.
refuse_alias_hit() {
    [ -z "$ALIAS_HIT" ] && return 0
    block_emit "Ref fast-forward gate: '$ALIAS_HIT_CAND' is a git alias reaching '$ALIAS_HIT', so this command performs a merge or pull under a name the gate cannot verify statically. Run the underlying 'git merge' / 'git pull' directly, so the gate can see the ref and oid it would move '${PROTECTED:-the protected branch}' to. Blocking as precaution (fail-closed)."
    exit 0
}

refuse_unknown_candidates() {
    local _cand
    for _cand in $UNKNOWN_CANDIDATES; do
        block_emit "BLOCKED: '$_cand' resolves to neither a git command nor a git alias that this gate can see, in a repo with a protected branch ($_PROT_LIST). Two things make it one anyway, and the gate cannot tell them apart from a typo: another command in the same call can define 'alias.$_cand = merge' before it runs, and an alias set through GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n in the session environment is stripped from this gate's environment but not from the command's. Either way it could fast-forward the protected branch after the gate has already looked. Use the underlying 'git merge' / 'git pull' directly, and run any companion as a SEPARATE call. Blocking as precaution (fail-closed)."
        exit 0
    done
}

# `git config alias.m merge && git switch main && git m feature` has NO literal
# merge/pull, so the refusal below does not apply; the alias does not exist when
# the gate looks it up; and the branch-scoped check further down saw the FEATURE
# branch and exited. The command then created the alias, switched, and
# fast-forwarded main. A companion means the branch the gate can see proves
# nothing, so the unknown-word refusal has to run here too — while the
# no-companion case stays below, where it does not over-block ordinary work.
# Branch-INDEPENDENT, and not qualified by $REF_WRITER either. Both were tried
# and both are unsound, because what this gate can see of an alias is its first
# word in the config it can read — never its body, and never a value the
# environment supplied:
#   - a COMPANION can rewrite the alias, or switch branch, before it runs;
#   - with no companion, an ambient GIT_CONFIG_KEY_n can still replace
#     `alias.m = merge` with a `!`-shell alias whose body is
#     `git switch main && git merge feature`, so a gate that exited because HEAD
#     said `feature` watched main move a moment later.
# The branch HEAD names at dispatch therefore proves nothing about the branch the
# command will move. The cost is over-blocking a non-built-in git word anywhere in
# a repo that HAS a protected branch, which is one re-typed command; the cost of
# the alternative is the gate. Nothing fires in a repo with none.
refuse_alias_hit
if [ -z "$KIND" ] && [ -n "$UNKNOWN_CANDIDATES" ]; then
    refuse_unknown_candidates
fi


if [ "$REF_WRITER" = "1" ] && [ -n "$KIND" ]; then
    block_emit "BLOCKED: this command runs something else ALONGSIDE a merge/pull, in a repo with a protected branch ($_PROT_LIST). The gate resolves the merge target and reads git config before the command runs, so any other command in the same invocation can replace what it checked — including which branch is checked out ('git switch main && git merge <oid>') — 'git branch -f topic <oid> && git merge topic' is the shape, 'git fetch' counts because it moves FETCH_HEAD and the remote-tracking refs, and so does anything that can run a configured helper or change git's environment. The gate does not try to tell those apart from a harmless 'git status'.

Run the parts as SEPARATE calls, so the gate sees the target at its final value:
  git fetch <remote> <ref>
  git merge --ff-only <oid>
(A leading 'cd' is fine — it only scopes the command.)"
    exit 0
fi

# #780 ZERO-old-oid
if [ -n "$ZERO_OLD_OPS" ]; then
    for _zo_pair in $ZERO_OLD_OPS; do
        _zo_kind="${_zo_pair%%:*}"
        _zo_name="${_zo_pair#*:}"
        if [ -z "$_zo_name" ]; then
            # Default-deref / unresolved ZERO-old blocks as a FORCE-UPDATE of an
            # UNKNOWN ref: porcelain force carries no old-oid CAS, and the name is
            # deliberately not resolved here (a `branch -f <symref>` DEREFERENCES,
            # so `-f alias` moves refs/heads/main -- measured; and every way to
            # rule that out is a pre-command probe this gate refuses to trust).
            block_emit "BLOCKED: this force-updates a branch ref with no old-oid precondition (branch -f / checkout -B / switch -C / a default-deref update-ref), and the gate cannot tell WHICH ref moves -- a porcelain force names a branch that may be a symbolic ref, and 'git branch -f <symref>' moves what it points AT, so this cannot be ruled out as a force-update of a protected branch (issue #780).

Use a form that states the precondition, which the gate can check:
  git update-ref refs/heads/<branch> <new-oid> <expected-old-oid>
Or, if you are the operator and this is deliberate, the usual override in your own terminal:
  touch $Q_STATE/skip-litmus.local"
            exit 0
        fi
        case " $PROTECTED_SET " in *" $_zo_name "*) ;; *)
            # Name absent from PROTECTED_SET at discovery cannot authorize a
            # named ZERO-old force/delete. Remotes and init.defaultBranch
            # can appear or change under the check (same create-after-check
            # / redirect TOCTOU as an absent conventional name). Do not
            # trust discovery-time absence of remotes or a conventional
            # init.defaultBranch. Existing DECLARED=1 continue unchanged.
            case "$_zo_name" in
                main|master|trunk|develop|development|default)
                    if [ "$_zo_kind" = "delete" ]; then
                        block_emit "BLOCKED: this would DELETE the protected branch '$_zo_name' (issue #780)."
                    else
                        block_emit "BLOCKED: this would FORCE-UPDATE the protected branch '$_zo_name' with no old-oid precondition (branch -f / checkout -B / update-ref without <oldvalue>) (issue #780)."
                    fi
                    exit 0
                    ;;
            esac
            if [ "$DECLARED" = "1" ]; then
                continue
            fi
            if [ "$_zo_kind" = "delete" ]; then
                block_emit "BLOCKED: this would DELETE the protected branch '$_zo_name' (issue #780)."
            else
                block_emit "BLOCKED: this would FORCE-UPDATE the protected branch '$_zo_name' with no old-oid precondition (branch -f / checkout -B / update-ref without <oldvalue>) (issue #780)."
            fi
            exit 0
            ;;
        esac
        if [ "$_zo_kind" = "delete" ]; then
            block_emit "BLOCKED: this would DELETE the protected branch '$_zo_name' (issue #780)."
            exit 0
        fi
        # PROTECTED_SET only contains refs discovered as present. A ZERO-old
        # force against one is therefore a force-update (or a TOCTOU recreate
        # after a concurrent delete). Do not re-probe with rev-parse — that
        # race would authorize argv that can still overwrite the protected ref.
        block_emit "BLOCKED: this would FORCE-UPDATE the protected branch '$_zo_name' with no old-oid precondition (branch -f / checkout -B / update-ref without <oldvalue>) (issue #780)."
        exit 0
    done
fi

# Detached HEAD moves no branch ref; a merge onto any OTHER branch is ordinary
# feature work that the commit/PR gates already cover on its way to main.
# #780 shapes handled above; exit when this command has no merge/pull.
if [ -z "$KIND" ]; then
    exit 0
fi
CURRENT=$(git_real symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT=""
[ -z "$CURRENT" ] && exit 0
case " $PROTECTED_SET " in *" $CURRENT "*) ;; *) exit 0 ;; esac
PROTECTED="$CURRENT"

# Placed AFTER the protected-branch determination, unlike the companion refusal
# above. This one is about a word that names no command — nothing about it can
# change which branch is checked out, so on a feature branch, or in a repo with
# no protected branch, `git m topic` is somebody else's business and blocking it
# was pure over-block. The companion rule still runs first and still runs
# branch-independently, which is what covers `git switch main && git m topic`.
# When there is NO literal merge/pull, a companion only matters if the command
# could still TURN something into one: a candidate that is neither a git command
# nor an alias TODAY is exactly what `git config alias.m merge && git m feature`
# looks like at gate time — the lookup above found nothing because the alias does
# not exist yet. A candidate that IS a real git command (`git status && git
# commit`) is none of this gate's business.


REMOTE=$(git_real config --get "branch.$PROTECTED.remote" 2>/dev/null) || REMOTE=""
[ -z "$REMOTE" ] && REMOTE="origin"

printf -v Q_PROT '%q' "$PROTECTED"
printf -v Q_REMOTE '%q' "$REMOTE"

MARKER_REL="$STATE_DIR/ref-ff-authorized.local"
MARKER="$REPO_DIR/$MARKER_REL"

# Authorize by the oid-bound marker, or block. Only reached once the operation is
# known to be a fast-forward of the protected branch to content that remote
# the pull arm does not already cover.
authorize_or_block() {   # <target_oid> <operand as written>
    local oid="$1" spec="$2" expected="PASS-FF refs/heads/$PROTECTED $1"
    local age=999 mtime content
    # These two lines end up in a command the operator is invited to paste, and
    # both halves are attacker-influenceable: git accepts a branch name
    # containing quotes, semicolons and `${...}` (only a leading `-`, `..` and a
    # short list of characters are refused), and the marker path is built from the
    # hook payload's cwd. Interpolated raw, a branch called
    # `x';touch${IFS}/tmp/pwn;#` closed the quoted string and appended a command.
    # printf %q renders both as one safely-quoted word.
    local _q_line _q_marker
    printf -v _q_line '%q' "PASS-FF refs/heads/$PROTECTED $1"
    printf -v _q_marker '%q' "$MARKER"
    local _mrc=0 _mcontent _mraw
    # ONE read. The marker sits at a mutable path, so a second read is a second
    # file: deciding on content from one and shape from the other would honour a
    # marker that never existed as a whole.
    # The trailing X is what makes one read enough. Command substitution strips
    # EVERY trailing newline, so the expected line followed by a run of blank
    # ones would arrive here identical to the expected line and a whole-file
    # compare would honour it. A sentinel byte after the content means nothing
    # of the file's own is at the end to be stripped.
    _mraw=$(state_file read ref-ff-authorized.local && printf X) || _mrc=$?
    _mcontent="${_mraw%X}"
    # Exactly ONE trailing newline is allowed - the one a text editor leaves.
    # A second survives this and fails the compare, which is the point.
    _mcontent="${_mcontent%$'\n'}"
    if [ "$_mrc" -eq 2 ]; then
        block_emit "BLOCKED: $MARKER_REL could not be read safely — it is a symlink, sits behind a symlinked path component, or is not a regular file. The authorization token is honoured only as a regular file the operator wrote in place."
        exit 0
    fi
    # The marker authorizes ONE oid, but the gate reached that oid by resolving a
    # SYMBOLIC operand, and git resolves it again when the command runs. Nothing
    # in this command can move it in between (a companion command is refused), yet
    # an outside process still could — and then the ref move would not be the one
    # audited. So a marker is honoured only for an operand that resolves to
    # ITSELF: a full object id. That makes the authorization bind what git will
    # actually use.
    #
    # RESIDUAL, and the standing one every PreToolUse gate in this directory
    # carries: the gate runs BEFORE the command, so it describes the repository as
    # it is at dispatch. Binding the operand to an object id fixes the SOURCE of
    # the fast-forward; the DESTINATION is HEAD, read here and re-read by git a
    # moment later, and an outside process could move HEAD in between so the
    # marker minted for one branch is spent on another. Nothing in this command
    # can do it — a companion is refused outright — so it takes a concurrent
    # writer. Closing it needs the decision made where git performs the ref update,
    # which is the `reference-transaction` hook #779 names and which needs a
    # git-hook installer this branch must not add (it belongs to #622). That is the
    # ADR 0050 deviation, recorded there rather than implied here; the marker form
    # defined here is what such a hook would consume unchanged.
    # The property wanted is "git resolves this operand to ITSELF", and that is an
    # equality — not a length. Testing for 40 or 64 hex characters encoded a guess
    # about the repository's hash algorithm and was wrong in both directions: a
    # 64-hex BRANCH NAME in a SHA-1 repo, or a 40-hex ref or abbreviation in a
    # SHA-256 one, passed the length test while git still resolved it symbolically,
    # so the marker bound something git would look up again. Comparing the operand
    # to the oid it resolved to answers the actual question, at any length.
    local _spec_lc _oid_lc
    _spec_lc=$(printf '%s' "$spec" | tr '[:upper:]' '[:lower:]')
    _oid_lc=$(printf '%s' "$oid" | tr '[:upper:]' '[:lower:]')
    if [ "$_spec_lc" != "$_oid_lc" ]; then
        if [ "$_mrc" -eq 0 ]; then
            block_emit "BLOCKED: a $MARKER_REL marker is present, but this merge names '$spec' — a symbolic ref that git resolves again when the command runs, so the authorization could not be bound to the ref move it produces. Name the object id instead, which resolves to itself:
  git merge --ff-only $oid
The marker must then read: PASS-FF refs/heads/$PROTECTED $oid"
            exit 0
        fi
    fi
    # The LITERAL flag, for the reason the pull arm states at length: git reads the
    # GIT_CONFIG_COUNT family as `-c`, the contained launch strips that family from
    # this gate and not from the command, and a command-line option outranks `-c`.
    # Without the flag, a `merge.ff=false` this gate cannot see turns the
    # fast-forward the operator authorized into a merge COMMIT — a different
    # operation, on the protected branch, spending a marker minted for something
    # else. With it, git enforces fast-forward-or-fail at run time and the marker
    # can only be spent on what it names. The config-visible spellings are still
    # checked above; this covers the ones no query here can reach.
    if [ "$_mrc" -eq 0 ] && [ "$FF_MODE" != "--ff-only" ]; then
        block_emit "BLOCKED: a $MARKER_REL marker is present, but this merge does not carry --ff-only, so the gate cannot bind the authorization to a fast-forward. Configuration this gate cannot read (the GIT_CONFIG_COUNT family is stripped from its environment and not from yours) could turn it into a merge commit instead — a different operation, spending a marker minted for this one. The flag makes git enforce it:
  git merge --ff-only $oid"
        exit 0
    fi
    if [ "$_mrc" -eq 0 ] \
       && ! gate_skip_file_repo_controlled "$REPO_DIR" "$MARKER_REL"; then
        mtime=$(stat -f %m "$MARKER" 2>/dev/null) \
            || mtime=$(stat -c %Y "$MARKER" 2>/dev/null) \
            || mtime=""
        [ -n "$mtime" ] && age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt 30 ]; then
            block_emit "BLOCKED: $MARKER_REL was created moments ago (likely self-bypass). Do NOT create $MARKER yourself. If the user wants to authorize this fast-forward, they should create the file manually in their terminal."
            exit 0
        fi
        # Whole-file compare, not a per-line grep: a marker whose FIRST line is
        # well-formed and whose second line is anything else must NOT be honoured
        # (the multi-line-token lesson pinned for PASS-MERGE in
        # tests/test-pre-commit-gate.sh).
        content="$_mcontent"
        if [ "$content" = "$expected" ]; then
            # AN IN-TREE core.hooksPath REFUSES THE ROUTE. `git merge` runs
            # `post-merge` immediately, so a hooks directory inside the working
            # tree means the content this merge checks out can BE the hook that
            # runs -- needing no shell access at all, only control of the incoming
            # content, which is precisely what this gate exists to distrust.
            #
            # This started as the narrow check "block only if the merge CHANGES
            # something under that path", and that check was abandoned rather
            # than extended. Deciding what git will execute means resolving what
            # git will reach, and one review round produced four separate ways to
            # miss it: a path equal to the repo root matched no `<root>/*` prefix;
            # a relative path needed joining; `.githooks -> hooks` made a diff on
            # the configured spelling see nothing; a DANGLING link (the target
            # arrives with the merge) resolved to nothing at all; a nested
            # `.githooks/post-merge -> ../scripts/post-merge` moved the real file
            # outside the directory entirely; and the paths went to `git diff` as
            # PATHSPECS, where a directory honestly named `:(exclude).githooks`
            # inverts the test. Every fix found the next hole, which is the
            # signature of an enumeration that cannot be completed -- the same
            # signature that retired the remote-provenance and pull routes above.
            #
            # So the rule is the class: hooks directory in the tree, no marker
            # route. It costs an operator with `.githooks/` one config change or
            # one PR, and it needs no diff -- which also removes the fail-OPEN
            # that a `git diff` error would otherwise have introduced.
            # The rule is stated POSITIVELY, because the negative form kept
            # leaking: only a hooksPath that RESOLVES, and resolves OUTSIDE the
            # working tree, is safe. Anything else refuses the route.
            #
            # "Unresolvable" has to land on the refusing side, and that is not
            # theoretical: an absolute `/tmp/hooks -> <repo>/future-hooks` that
            # dangles today resolves INTO the tree the moment this merge creates
            # `future-hooks`, and a spelling test would have called it outside.
            # A path that cannot be resolved cannot be proven outside.
            #
            # WHAT THIS CHECK IS, EXACTLY. It closes the routine, config-visible
            # case: a hooks directory the gate can see resolving into the working
            # tree. It is NOT a proof that nothing executes, and the difference is
            # worth stating because the narrow version of this check leaked
            # repeatedly before it was widened to the rule above.
            #
            # Still open, and NOT closable here:
            #   - the DEFAULT `.git/hooks/post-merge` when it is itself a symlink
            #     to a tracked file: hooksPath is unset, so nothing above fires,
            #     and the merge replaces the file git is about to run;
            #   - a hooksPath outside the tree that CONTAINS such a symlink;
            #   - a spelling whose ANCESTOR is a symlink, or which reaches the
            #     tree through `..`, so the final component is not itself a link;
            #   - an ambient GIT_CONFIG_KEY_n=core.hooksPath, invisible to this
            #     gate and live for the command (ADR 0049 R3 / #777).
            #
            # Chasing those means resolving every path git might execute from,
            # through arbitrary symlinks, at a layer that runs BEFORE the command
            # -- the same uncompletable enumeration that retired the
            # remote-provenance and pull routes. The layer that can decide it is
            # git's own `reference-transaction` hook, which sees the ref update
            # after git has resolved everything; ADR 0050 records that as the
            # follow-up once #622 lands an installer. Non-regression holds
            # meanwhile: every one of those was equally possible before this gate
            # existed, and each needs a hook symlink planted in advance.
            # WHICH FILE WILL GIT EXECUTE. `git merge` runs `post-merge` the
            # moment it completes, so if that file lives in the WORKING TREE the
            # content this fast-forward checks out can BE the hook that then runs
            # -- one authorization, two actions, and needing no shell access at
            # all, only control of the incoming content.
            #
            # Asked as a path question and answered with realpath, because every
            # spelling-based version leaked. Earlier rounds produced: a path equal
            # to the repo root matching no `<root>/*` prefix; a relative path
            # needing joining; `.githooks -> hooks` hiding the change from a diff
            # on the configured spelling; a DANGLING link whose target the merge
            # itself creates; a nested `.githooks/post-merge -> ../scripts/...`
            # moving the real file out of the directory; an ANCESTOR component
            # being a link; and pathspec syntax like `:(exclude)`. realpath
            # resolves all of them at once, and resolves partially through a
            # dangling link, which is what catches the not-yet-created target.
            #
            # Containment is "inside the worktree but NOT inside the git dir":
            # `.git/hooks/post-merge` as a regular file is ordinary and safe, the
            # merge cannot touch it; the same name as a SYMLINK into the tree is
            # the documented escalation and is refused.
            # `set -euf` is in force, and BOTH of these are expected to fail in
            # ordinary use: rev-parse outside a repository, and `config --get`
            # for an unset core.hooksPath - which is the common case. Their
            # status is the answer here, not an error, so errexit is exactly
            # what must not apply; each is handled on the spot below.
            # The COMMON dir, not --absolute-git-dir: in a linked worktree the
            # latter is <common>/worktrees/<name>, while the hooks git runs live
            # in <common> itself. Everything the merge cannot rewrite sits under
            # the common dir, including that per-worktree directory, so it is
            # the right root for the exemption.
            # shellcheck disable=SC2310  # status is consumed, not masked
            _gitdir=$(git_real rev-parse --git-common-dir 2>/dev/null) || _gitdir=""
            # git's OWN answer for which directory it will run hooks from. It
            # honours core.hooksPath (measured) and it is correct in a linked
            # worktree, where composing <git dir>/hooks by hand names a path that
            # does not exist - which then looks safely outside the tree while the
            # real shared hook, possibly a symlink into it, is never inspected.
            # shellcheck disable=SC2310  # an empty result is handled below
            _hookdir=$(git_real rev-parse --git-path hooks 2>/dev/null) || _hookdir=""
            _hp_set=0
            # shellcheck disable=SC2310  # a nonzero status IS the unset answer
            _hp=$(git_real config --get core.hooksPath 2>/dev/null) || _hp_set=1
            if [[ "$_hp_set" == "0" ]] && [[ -z "$_hp" ]]; then
                # SET to the empty string is not the same as unset, and git does
                # not fall back to the default hooks directory for it. Whatever it
                # does mean, this gate cannot name the file git will run.
                block_emit "BLOCKED: core.hooksPath is set to an EMPTY value, so the gate cannot name the post-merge hook git would run for this merge, and cannot show that it lives outside the working tree. Unset it, or point it at a directory outside the tree:
  git -C $Q_REPO config --unset core.hooksPath"
                exit 0
            fi
            # Command substitution strips EVERY trailing newline, so a value
            # spelled `/outside/hooks\n` in the config arrives here as
            # `/outside/hooks` - a different name, and possibly an absent one,
            # while git runs the hook under the real newline-suffixed path. Do
            # not try to carry the newline through; count them in the raw value
            # and refuse. `-z` so git terminates with NUL rather than adding a
            # newline of its own, and the count is of the VALUE's own bytes.
            # shellcheck disable=SC2310  # a nonzero status means unset, handled above
            _hp_nl=$(git_real config -z --get core.hooksPath 2>/dev/null | tr -d '\000' | wc -l) || _hp_nl=0
            if [[ "${_hp_nl//[[:space:]]/}" != "0" ]]; then
                block_emit "BLOCKED: core.hooksPath contains a NEWLINE, so the gate cannot name the post-merge hook git would run for this merge, and cannot show that it lives outside the working tree. A hooks path with a newline in it is refused rather than guessed at. Set it to a plain path outside the tree, or unset it:
  git -C $Q_REPO config --unset core.hooksPath"
                exit 0
            fi
            # -I, not just -S: with `-c` the interpreter puts the CURRENT
            # DIRECTORY first on sys.path, and that directory is the repository
            # this merge is about. A tracked unicodedata.py would then be
            # imported and run here - measured: it returns whatever it likes
            # from normalize(), which is enough to fold every path together and
            # make the check pass. -I drops that entry (it also implies -E/-s,
            # which costs nothing: this payload reads no PYTHONPATH).
            _hp_verdict=$(python3 -I -S -c "
import os, sys, unicodedata
repo, hookdir, gitdir = sys.argv[1], sys.argv[2], sys.argv[3]
if not repo or not gitdir or not hookdir:
    print('block'); raise SystemExit(0)
def absol(p):
    # git may answer relatively (it runs with -C at the worktree root, and a
    # relative core.hooksPath is rooted at the top of the working tree).
    return p if os.path.isabs(p) else os.path.join(repo, p)
base = absol(hookdir)
repo_r = os.path.realpath(repo)
git_r = os.path.realpath(absol(gitdir))
def ident(p):
    # dev+inode is the filesystem's own answer to are-these-the-same-directory,
    # and unlike a name it survives every aliasing scheme. It is EXACT, so it is
    # safe in both directions - it can neither over- nor under-match.
    try:
        st = os.stat(p)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)
repo_id = ident(repo_r)
git_id = ident(git_r)
def under_id(p, root_id):
    # Climb by identity rather than by name: realpath resolves symlinks but does
    # NOT collapse a macOS firmlink, so /Volumes/Work and
    # /System/Volumes/Data/Volumes/Work keep different spellings while sharing
    # one dev+inode (measured). A hooksPath written in the alternate spelling
    # would otherwise read as safely outside the tree it is actually inside.
    # A path that does not exist yet climbs to the nearest ancestor that does,
    # which is the right answer: this merge is what would create it.
    # RESIDUAL, stated rather than half-closed: this climbs to the worktree
    # ROOT, so a second mount of an in-tree SUBDIRECTORY (a bind mount of
    # <repo>/.githooks at /mnt/hooks) shares that subdirectory's inode and never
    # the root's, and reads as outside. Finding it would mean scanning the tree
    # for a matching inode on every check. It sits with the ambient-environment
    # residuals in ADR 0050: it is machine state the gate cannot see, not
    # something the incoming content can arrange.
    if root_id is None:
        return False
    cur = os.path.realpath(p)
    for _ in range(4096):
        if ident(cur) == root_id:
            return True
        parent = os.path.dirname(cur)
        if parent == cur:
            # The filesystem root, reached without meeting the root asked about.
            # That IS the answer: the path is not under it.
            return False
        cur = parent
    # The bound ran out, so this climb decided nothing, and undecided means
    # inside. Belt and braces rather than a hole being closed: the caller walks
    # EVERY component from the filesystem root down, so the shallowest in-tree
    # one -- the worktree root itself -- is reached after a climb of zero and
    # refuses long before depth matters. Measured: with the bound at 256 and
    # this answer inverted, a 300-component in-tree hooksPath still refuses.
    # An undecidable climb must still not read as proof of being outside.
    return True
    return False
def strict(p, root):
    # rstrip so a root of / does not build the prefix //, which matched nothing
    # and classified every path as outside the worktree.
    return p == root or p.startswith(root.rstrip(os.sep) + os.sep)
def fold(p):
    # macOS compares filenames case-insensitively AND treats the canonically
    # equivalent NFC and NFD spellings as the same file; neither is equal as a
    # Python string. casefold, not lower: lower leaves the Greek final sigma
    # distinct from the medial one, which the filesystem does not. NFC again
    # afterwards because casefolding can denormalize what it folds.
    return unicodedata.normalize('NFC', unicodedata.normalize('NFC', p).casefold())
def loose(p, root):
    # Used ONLY where over-matching REFUSES -- deciding inside-the-worktree, and
    # the git-dir-ancestor guard. Never for the git-dir exemption, where
    # over-matching would EXEMPT a distinct path: on a case-sensitive volume
    # /repo/.GIT/hooks is not /repo/.git, and folding them together would wave a
    # tracked hook through.
    return strict(p, root) or strict(fold(p), fold(root))
dot_git = os.path.join(repo_r, '.git')
def gitdir_beyond_reach():
    # The exemption says a hook living in the git dir is safe because the merge
    # cannot write there. That is true in exactly two shapes. Outside the
    # worktree: nothing checked out can reach it. Or the reserved name .git,
    # which git will never check content into. A git dir INSIDE the worktree
    # under any other name -- a separate common dir at <worktree>/control, say
    # -- is ordinary tracked space, and this very merge can land
    # control/hooks/post-merge in it.
    if not (loose(git_r, repo_r) or under_id(git_r, repo_id)):
        return True
    # By NAME, and only by name. What makes .git safe is that git refuses to
    # track a path spelled that way -- nothing about the directory it happens to
    # be. An identity test here reads through a .git SYMLINK and would declare
    # the ordinary in-tree directory behind it reserved, which is the bypass
    # this branch exists to close.
    # EXACT, not folded: on a case-sensitive volume .GIT is an ordinary tracked
    # directory that git will happily check content into, and folding it onto
    # .git would hand it the reservation. The other way round costs only a
    # refusal on a repo whose git dir is spelled unusually, which is the safe
    # direction to be wrong in.
    return git_r == dot_git
if loose(repo_r, git_r) or under_id(repo_r, git_id) or not gitdir_beyond_reach():
    # The exemption below rests on the git dir being somewhere the merge does
    # not check out into. If the git dir IS the worktree, or an ANCESTOR of it
    # (core.worktree, or a separately-located git dir), then every tracked path
    # is inside it too and the exemption would swallow the whole check. That
    # layout cannot be proven safe here, so it refuses.
    # loose(), not strict(): here over-matching REFUSES, so the case/Unicode
    # fold is the safe direction. realpath resolves symlinks but keeps the
    # spelling it was given, so on a case-insensitive volume a git dir recorded
    # as /x/GD and a worktree resolving to /x/gd/wt are the SAME directory and
    # differ only as Python strings. Missing that ancestry would then let a
    # hooksPath spelled with the git dir's casing take the exemption and wave a
    # tracked in-tree post-merge hook through.
    print('block'); raise SystemExit(0)
def refuse(p):
    # The worktree ROOT itself is every in-tree path's ancestor and git cannot
    # replace it, so reaching it is not by itself a finding; anything strictly
    # below it is content this merge can rewrite.
    # By name only, for the same reason the git-dir exemption is: an identity
    # test follows symlinks, and a tracked .jump pointing AT the worktree root
    # would inherit the root's un-replaceability while being, itself,
    # ordinary tracked space this merge can turn into a directory of its own.
    if fold(p) == fold(repo_r):
        return False
    inside = loose(p, repo_r) or under_id(p, repo_id)
    # The exemption is decided on the path's OWN LOCATION, by name only. Neither
    # the case fold nor the identity climb belongs here: both would EXEMPT a
    # distinct path, and over-matching in this direction is a bypass rather than
    # a false alarm. The fold, because on a case-sensitive volume /repo/.GIT is
    # its own tracked path. The identity climb, because it resolves the
    # candidate first -- a tracked /repo/.githooks symlinked at .git/hooks lives
    # in the WORKTREE, and this merge can replace it with a directory of its own.
    exempt = strict(p, git_r)
    return inside and not exempt
# EVERY COMPONENT, judged where it LIVES before it is followed. Resolving the
# whole parent chain first was wrong: with core.hooksPath=.links/current/hooks
# and a tracked .links pointing outside today, the resolved path looks safely
# external, and this very merge can replace .links with an in-tree directory
# holding post-merge. So each component is checked against the worktree in the
# canonical spelling of its own parent, and only then followed -- which also
# lands the resolved endpoint, catching a link whose target the merge creates.
parts = os.path.join(base, 'post-merge').split(os.sep)
cur = os.sep
for comp in parts:
    if not comp or comp == os.curdir:
        continue
    cand = os.path.join(cur, comp)
    try:
        # realpath is non-strict and leaves a symlink LOOP unresolved, returning
        # a spelling that can look safely outside. stat raises ELOOP on one, so
        # an entry that cannot be stat'ed for any reason other than absence is
        # not provably outside.
        os.stat(cand)
    except FileNotFoundError:
        pass
    except OSError:
        print('block'); raise SystemExit(0)
    res = os.path.realpath(cand)
    # A pardir component names no entry of its own; only where it lands counts.
    if comp != os.pardir and refuse(cand):
        print('block'); raise SystemExit(0)
    if refuse(res):
        print('block'); raise SystemExit(0)
    cur = res
print('ok')
" "$REPO_DIR" "$_hookdir" "$_gitdir" 2>/dev/null) || _hp_verdict="block"
            if [[ "$_hp_verdict" != "ok" ]]; then
                block_emit "BLOCKED: the post-merge hook git would run for this merge resolves INSIDE the working tree (core.hooksPath is '$_hp'; empty means the default hooks directory). git runs that hook the moment the merge completes, so this fast-forward could land the very file that then executes - a second, unreviewed action the authorization does not cover, and one needing no shell access at all, only control of the incoming content.

Resolution follows symlinks at every level, so a link in the hooks directory, a link to a tracked file, or one whose target this merge creates all count. A hook file that lives in the git directory itself is fine - the merge cannot touch it.

Point core.hooksPath at a directory outside the working tree, or land the change through a PR:
  git -C $Q_REPO config core.hooksPath <path outside the repo>"
                exit 0
            fi
            audit_ref_ff "$PROTECTED" "$oid" "marker"
            # Consumed HERE, not in a PostToolUse hook: single-use is the point,
            # and a fast-forward that then fails locally must not leave a live
            # authorization behind for whatever runs next. The cost is a re-touch
            # after a failed merge, which is the safe direction.
            # NOT `|| true`. Consumption is what makes the token single-use, so
            # an unlink that failed — a read-only state dir, an immutable flag,
            # the entry swapped for a directory — leaves a LIVE authorization
            # behind and every later merge spends it again. The audit record is
            # already written at this point, so refusing here costs a re-touch and
            # keeps the "one ref, one oid, single use" promise the block messages
            # make.
            if ! state_file unlink ref-ff-authorized.local >/dev/null 2>&1; then
                block_emit "BLOCKED: the authorization in $MARKER_REL matched, but the gate could not CONSUME it — the file could not be removed (a read-only state directory, or the entry is no longer a plain file). It is single-use by design, and leaving it in place would authorize every later fast-forward too, so the merge is refused rather than run against a token that stays live. Remove the file and re-authorize."
                exit 0
            fi
            exit 0
        fi
    fi
    block_emit "BLOCKED: this would FAST-FORWARD the protected branch '$PROTECTED' to $oid. A fast-forward creates no commit object, so no other review gate would see it (issue #779), and a direct merge carries no evidence of where the content came from — 'git merge $REMOTE/$PROTECTED' included, because that ref is local and any fetch refspec can write it.

To land new work, open a PR and merge it (/litmus, then /pr-grind). To advance this checkout afterwards, fetch and then authorize the exact commit — 'git pull' is refused for the same reason, since the commit it would land does not exist here yet.

If the user really wants this exact fast-forward, they can authorize it in their own terminal — one ref, one oid, single use:
  echo $_q_line > $_q_marker
  git merge --ff-only $oid
Every use is recorded in ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/bypass-log.jsonl."
    exit 0
}

if [ "$KIND" = "merge" ]; then
    # More than one operand LOOKS like an octopus merge, which always produces a
    # merge COMMIT and so falls outside this gate's class — but "looks like" is
    # not good enough to exit on, because a separate-value option this parser does
    # not know about leaves its VALUE in the operand list and fakes the same
    # shape. `git merge --cleanup strip feature` was exactly that: two operands,
    # read as an octopus, allowed — while git performed a one-head merge that
    # fast-forwards. So prove it instead: a real octopus has every operand
    # resolving to a commit. Anything else is a parse the gate got wrong, and it
    # blocks. Three or more heads is rare enough that the gate refuses rather than
    # widening the emitted-operand protocol to carry them.
    if [ "$NOPS" -gt 2 ]; then
        block_emit "Ref fast-forward gate: this merge names $NOPS operands. The gate reads at most two, so it cannot confirm every one of them is a merge head rather than an option value it failed to recognize. Blocking as precaution (fail-closed)."
        exit 0
    fi
    if [ "$NOPS" -eq 2 ]; then
        _O1=$(git_real rev-parse --verify --quiet "${OP1}^{commit}" 2>/dev/null) || _O1=""
        _O2=$(git_real rev-parse --verify --quiet "${OP2}^{commit}" 2>/dev/null) || _O2=""
        if [ -n "$_O1" ] && [ -n "$_O2" ]; then
            # Git REDUCES the head list before choosing a merge shape: duplicates
            # and heads already reachable from another head (or from HEAD) drop
            # out, so `git merge HEAD topic` and `git merge topic topic` collapse
            # to one head and fast-forward. Two operands are only genuinely an
            # octopus when neither reduces away; anything else is refused, since
            # the gate would otherwise exit on a merge that does move the ref.
            if [ "$_O1" != "$_O2" ] \
               && ! is_ancestor "$_O1" "$_O2" \
               && ! is_ancestor "$_O2" "$_O1" \
               && ! is_ancestor "$_O1" HEAD \
               && ! is_ancestor "$_O2" HEAD; then
                exit 0   # genuine octopus merge — a merge commit, never an FF
            fi
            block_emit "BLOCKED: this merge names two heads ('$OP1', '$OP2'), but one of them is reachable from the other or from '$PROTECTED', so git reduces the list and the merge can still FAST-FORWARD the protected branch. The gate does not evaluate that shape as an octopus. Merge the one head you mean, naming its object id."
            exit 0
        fi
        block_emit "Ref fast-forward gate: this merge names two operands ('$OP1', '$OP2') but they do not both resolve to commits, so it is not an octopus merge — most likely one of them is the value of an option the gate did not recognize, leaving the real merge target unread. Blocking as precaution (fail-closed)."
        exit 0
    fi
    # A bare `git merge` merges the branch's upstream (merge.defaultToUpstream).
    SPEC="$OP1"
    [ -z "$SPEC" ] && SPEC='@{upstream}'
    case "$SPEC" in
        -*)
            block_emit "Ref fast-forward gate: the merge target cannot be resolved statically (it uses a substitution or variable, or the command parser could not read it). The gate cannot tell what content '$PROTECTED' would move to. Blocking as precaution (fail-closed)."
            exit 0 ;;
    esac
    TARGET_OID=$(git_real rev-parse --verify --quiet "${SPEC}^{commit}" 2>/dev/null) || TARGET_OID=""
    if [ -z "$TARGET_OID" ]; then
        block_emit "Ref fast-forward gate: cannot resolve the merge target '$SPEC' to a commit in $REPO_DIR, so the gate cannot tell whether it would fast-forward the protected branch '$PROTECTED'. Blocking as precaution (fail-closed)."
        exit 0
    fi
    HEAD_OID=$(git_real rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || HEAD_OID=""
    if [ -n "$HEAD_OID" ]; then
        # Already at the target — no ref moves.
        [ "$TARGET_OID" = "$HEAD_OID" ] && exit 0
        # Not a fast-forward: the merge produces a COMMIT, the separate class
        # tracked as #622 / #782. Out of scope here by decision — but only on a
        # real answer, which is what is_ancestor guarantees.
        if ! is_ancestor "$HEAD_OID" "$TARGET_OID"; then
            exit 0
        fi
    fi
    # An ANNOTATED TAG operand makes git create a merge commit even when the
    # ancestry would allow a fast-forward (git-merge documents this), so the
    # ancestry answer above does not describe what git will do. Out of this gate's
    # class, and refused rather than authorized.
    if [ "$(git_real cat-file -t "$SPEC" 2>/dev/null || echo '')" = "tag" ]; then
        block_emit "BLOCKED: '$SPEC' is an ANNOTATED TAG. Git builds a merge commit for one even when a fast-forward would be possible, so this is not the fast-forward shape the gate evaluates, and nothing here vouches for the new commit it would put on '$PROTECTED' (#622 / #782).

Merge the commit the tag points at, by object id: git merge $TARGET_OID"
        exit 0
    fi

    # There is deliberately NO `merge.ff` / `branch.<p>.mergeOptions` read here any
    # more. It used to refuse the merge when configuration would turn the
    # fast-forward into a merge commit — but that was the gate predicting the
    # command's behaviour from configuration it may not share (the GIT_CONFIG_COUNT
    # family is stripped from this environment and not from the command's), which
    # is the same mistake the pull arm was deleted for. The marker route now
    # requires a literal `--ff-only`, which git ranks above every configuration
    # source, so git enforces fast-forward-or-fail itself and there is nothing left
    # to predict. Shape refusals stay — an annotated tag, an octopus, a diverged
    # branch, a companion command are facts about the command, not about config.
    # The ONLY route. "Reachable from refs/remotes/<remote>/<protected>" was once
    # accepted as proof that content had come through the PR pipeline; it was
    # deleted because that voucher is a local ref any `git fetch <remote>
    # <unreviewed>:refs/remotes/<remote>/<protected>` can plant, and nothing local
    # distinguishes a planted one.
    authorize_or_block "$TARGET_OID" "$SPEC"
fi

if [ "$KIND" = "pull" ]; then
    # A pull on a protected branch is refused OUTRIGHT, and that is the whole rule.
    # It has no marker route because it cannot have one: the commit it will land
    # does not exist locally when this gate runs, so nothing can bind an
    # authorization to it.
    #
    # Every attempt to authorize a pull by its SOURCE was built, tested and
    # removed, because each read an input the gated party controls — the failure
    # this repository's gate-design rules name first. In order: the remote NAME
    # (branch.<p>.remote, chosen by this repo); the remote's published HEAD (a fork
    # publishes the same one — measured on git 2.55, `git remote add fork <url> &&
    # git fetch fork` creates fork/HEAD -> fork/main by itself); and an
    # operator-declared canonical URL in a non-repo-controlled file, which came
    # closest and still fails, because `url.<x>.insteadOf` set through the
    # GIT_CONFIG_COUNT family rewrites the transport underneath a URL that
    # compares equal — and that family is stripped from this gate's environment,
    # not from the command's, so the gate cannot even see it. A committed
    # `settings.json` env block reaches session environment (#325), so this is not
    # merely the earlier-command class; the input is repo-reachable.
    #
    # What is left is the marker route, and it is the only one whose guarantee
    # survives an environment the gate cannot read: a full object id resolves to
    # itself, a command-line `--ff-only` outranks every configuration source git
    # has, and no fetch means no URL to rewrite. So the gate authorizes nothing it
    # has to predict.
    block_emit "BLOCKED: 'git pull' would fast-forward the protected branch '$PROTECTED' to a commit that does not exist locally yet, so nothing can authorize it in advance — and where that commit comes from is decided by configuration and environment this gate cannot see (a URL can be rewritten by 'url.<x>.insteadOf' set in the environment, which is stripped from the gate and not from your command). A fast-forward creates no commit object, so no other review gate would see the result either (issue #779).

Fetch first, then authorize the exact commit — the gate can bind to an object id, and 'git merge --ff-only <oid>' is enforced by git itself:
  git fetch $Q_REMOTE $Q_PROT
  git rev-parse FETCH_HEAD
  # the operator writes, in their own terminal:
  #   the operator writes the line PASS-FF refs/heads/$PROTECTED <that oid>
  #   into $Q_STATE/ref-ff-authorized.local
  git merge --ff-only <that oid>

To land new work, open a PR and merge it (/litmus, then /pr-grind)."
    exit 0
fi
