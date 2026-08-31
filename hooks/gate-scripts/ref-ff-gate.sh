#!/usr/bin/env bash
# PreToolUse hook: gate a FAST-FORWARD of the protected branch (issue #779),
# and its CREATION at unreviewed content (issue #781)
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
# SCOPE — the fast-forward class, and the creation class beside it:
#   IN   `git merge <ref>` that fast-forwards HEAD (`--ff-only`, `--no-commit`,
#        the default `--ff`), and `git pull` on the protected branch.
#   IN   CREATING a protected branch that does not exist, at content no existing
#        protected branch already carries (#781) — whatever spelling reaches it,
#        because the gate matches the NAME as a command word rather than parsing
#        six creation grammars. Its authorization is a `PASS-CREATE` line in the
#        same marker file, spent on the one shape `git branch <name> <oid>`; see
#        the creation_check block below for the rule and what it costs. The
#        INITIAL COMMIT — the other shape #781 names — is `git commit`, which
#        pre-commit-gate.sh already blocks (measured), so it is observed at this
#        layer and this gate stays out of its way.
#   OUT  a merge that produces a COMMIT (`--no-ff`, a real three-way merge, and
#        `merge -s ours` laundering) — #622 / #782; `--squash`, whose `git commit`
#        pre-commit-gate already owns; force-updates of a branch that EXISTS,
#        `update-ref`/`branch -f` — #780; `rebase` / `am` — #783.
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
    from gitcmd_detect import (git_ref_op, git_ref_create,
                               REF_OP_UNRESOLVABLE, REF_OP_FF_PREFIX)
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
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
        print('')
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
    # #781. Read from the SAME parse, so the creation check can never disagree
    # with the merge/pull one about what the command says, and so the gate pays
    # one interpreter start rather than two on every git command it now sees.
    (c_name, c_oid, c_toks, c_opts, c_opaque, c_exe, c_symref,
     c_fetchspec, c_unreadable, c_fetching, c_pushing) = git_ref_create(cmd)
    if any(chr(10) in v or chr(13) in v
           for v in [c_name, c_oid] + c_toks + c_opts):
        raise ValueError('newline in an emitted creation field')
    print(c_name)
    print(c_oid)
    # SPACE-JOINED, which is safe precisely because git_ref_create drops every
    # word containing whitespace: a ref name cannot hold any.
    print(' '.join(c_toks))
    print(' '.join(c_opts))
    print(c_opaque)
    print('1' if c_exe else '0')
    print('1' if c_symref else '0')
    print('1' if c_fetchspec else '0')
    print('1' if c_unreadable else '0')
    print('1' if c_fetching else '0')
    print('1' if c_pushing else '0')
except Exception:
    for _ in range(23):
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
CREATE_NAME=$(echo "$PARSE_RESULT" | sed -n '13p')
CREATE_OID=$(echo "$PARSE_RESULT" | sed -n '14p')
CREATE_TOKS=$(echo "$PARSE_RESULT" | sed -n '15p')
CREATE_OPTS=$(echo "$PARSE_RESULT" | sed -n '16p')
CREATE_OPAQUE=$(echo "$PARSE_RESULT" | sed -n '17p')
CREATE_GITEXE=$(echo "$PARSE_RESULT" | sed -n '18p')
CREATE_SYMREF=$(echo "$PARSE_RESULT" | sed -n '19p')
CREATE_FETCHSPEC=$(echo "$PARSE_RESULT" | sed -n '20p')
CREATE_UNREADABLE=$(echo "$PARSE_RESULT" | sed -n '21p')
CREATE_FETCHING=$(echo "$PARSE_RESULT" | sed -n '22p')
CREATE_PUSHING=$(echo "$PARSE_RESULT" | sed -n '23p')

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
# Genuinely not in a git repo → no ref can move (git fails on its own).
[ "$GATE_RESOLVE_STATUS" = "outside-repo" ] && exit 0
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
# ALIAS_CANDIDATES, not UNKNOWN_CANDIDATES (which is the subset of it that
# resolves to nothing). The #781 shapes are ORDINARY git commands -- `git branch
# main <oid>`, `git checkout -b master <oid>`, `git update-ref refs/heads/develop
# <oid>` -- so KIND is empty and every word resolves; both tests above were empty
# for them and the gate exited before it ever learned which names are protected.
# ALIAS_CANDIDATES holds every subcommand outside the read-only set, which is
# the class the creation check below scans. A command of only read-only
# subcommands (`git log main`) still exits here, unexamined and free.
IS_REFOP=0
if [ -n "$KIND" ] || [ -n "$UNKNOWN_CANDIDATES" ]; then
    IS_REFOP=1
fi
if [ "$IS_REFOP" = "0" ] && [ -z "$ALIAS_CANDIDATES" ] \
   && [ "$CREATE_GITEXE" != "1" ]; then
    exit 0
fi

# ── Skip override (same anti-self-bypass shape as the sibling gates) ──
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-litmus.local"
if [ -f "$SKIP_FILE" ] \
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
# The same names WITHOUT the existence filter below. A branch that does not
# exist cannot be fast-forwarded, so the merge/pull arms have no use for it --
# but it is exactly what a CREATION lands on (#781), and filtering it out is why
# `git branch master <unreviewed>` in a repo that has only `main` was invisible
# to this gate. Discovery and declaration both feed it, so the two sets can
# never drift apart.
PROTECTED_NAMES=""
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
    case " $PROTECTED_NAMES " in *" $_b "*) ;; *) PROTECTED_NAMES="$PROTECTED_NAMES $_b" ;; esac
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
        case " $PROTECTED_NAMES " in *" $_b "*) ;; *) PROTECTED_NAMES="$PROTECTED_NAMES $_b" ;; esac
        # DEFERRED, not relaxed. A declared name that does not exist is still a
        # typo for the merge/pull arms and still blocks them below -- but it is
        # ALSO the precise case #781 guards (a protected ref that is not there
        # yet, about to be created at unreviewed content), and this gate now runs
        # on every non-read-only git command. Refusing here would have turned one
        # mistyped line into a block on `git add`, `git commit` and every other
        # ordinary command in the repo. The creation check reads the name; the
        # refusal fires where it always did.
        if ! git_real show-ref --verify --quiet "refs/heads/$_b" 2>/dev/null; then
            [ "$IS_REFOP" = "1" ] || continue
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
# HEAD is a ref write, the #780/#781 class this gate does not observe — and an
# actor who can make one can equally run `git update-ref refs/heads/<branch>
# <oid>`, which moves the branch outright in one command. Discovery's mutability
# hands that actor nothing they did not already have.

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
# Merge/pull only. An empty set means no protected branch EXISTS, which for a
# fast-forward is the failure case -- but for a creation it is ordinary: a fresh
# `git init` has no branches at all, and routing `git add` through this refusal
# would block every command in such a repo. The creation check runs on
# PROTECTED_NAMES, which the conventional names keep non-empty regardless.
if [ -z "$PROTECTED_SET" ] && [ "$IS_REFOP" = "1" ]; then
    if [ "$DECLARED" = "1" ] && [ "$DECL_LISTED" -gt 0 ]; then
        block_emit "BLOCKED: $STATE_DIR/ref-ff-protected.local names $DECL_LISTED branch(es), but none of them exists in ${REPO_DIR:-.} — so the gate is guarding nothing while the file says otherwise, which is what a typo looks like. A file that names NO branch is the deliberate 'this repository has none'; a file that names branches which do not exist is not.

Check the spelling against:
  git -C $Q_REPO branch --format='%(refname:short)'"
        exit 0
    fi
    if [ "$DECLARED" = "1" ]; then
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


# The marker file both routes spend, hoisted above the creation check that now
# also reads it. One file, one forge guard, one audit path; the two verbs inside
# it (PASS-FF and PASS-CREATE) authorize different operations and are compared
# whole, so neither is spendable on the other.
MARKER_REL="$STATE_DIR/ref-ff-authorized.local"
MARKER="$REPO_DIR/$MARKER_REL"

# ── #781: CREATING a protected ref at content nothing reviewed ────────
#
# THE BYPASS. A ref that does not exist yet cannot be fast-forwarded, so the
# arms below never look at it -- and creating it lands arbitrary content on a
# protected name with no commit object and no marker anywhere. Two shapes,
# both measured on this branch before the fix:
#   `git branch master <oid>` / `git checkout -b master <oid>` / `git switch -c`
#   / `git update-ref refs/heads/master <oid>` in a repo that has only `main`,
#   where <oid> came from `git commit-tree` and is reachable from nothing;
#   and the same commands re-creating `main` itself in a checkout that does not
#   have it (a single-branch clone, or after the branch was deleted).
# The initial commit -- the other shape issue #781 names -- is NOT in this list:
# it is `git commit`, which pre-commit-gate.sh already blocks (measured), so at
# this layer it is observed. It needs the rule only at the reference-transaction
# layer that arrives with #622, and ADR 0050 records why that layer is not built
# here.
#
# THE RULE, from #781: there is no pre-image to compare a creation against, so
# the only meaningful test is whether the content is ALREADY reachable from an
# existing protected branch. If it is, the creation is inert and is allowed with
# no ceremony -- which is what keeps `git checkout -b develop` off `main`
# ordinary. If it is not, it is landing new content on a protected name and must
# be authorized or refused. A blanket "creation is inert" rule admits both shapes
# above, which is why the reachability condition is load-bearing rather than
# incidental.
#
# WHY THE WHOLE COMMAND IS SCANNED rather than the creating operand parsed:
# `branch`, `checkout -b/-B`, `switch -c/-C`, `update-ref`, `worktree add -b`
# and DWIM `checkout <name>` are six grammars, and reading "the name being
# created" out of any of them mis-parses toward ALLOW -- one separate-value
# option this parser does not know shifts the operand and the gate checks the
# wrong word. Matching every TOKEN over-approximates toward BLOCK instead, since
# whichever operand carries the name is one of the command tokens either way.
# Same move, and the same reason, as _has_companion_command.
#
# WHAT IT COSTS, stated rather than left to be found: a bare word equal to a
# protected-but-absent name blocks whatever it actually meant -- `git commit -m
# develop` on a feature branch, `git fetch origin master` where master is not
# local. Quoting does not help (the parser sees tokens, not quotes), but a
# multi-word message is one token and never matches. That is one re-typed
# command, the same cost the alias and companion rules already accept, and it is
# paid only for the six conventional names plus whatever the operator declared.
creation_check() {
    # A git builtin reached as its own EXECUTABLE names no `git <sub>` pair, so
    # it reports no alias candidate; the flag is what keeps it in scope. Neither
    # does `pull`, which the parser recognizes as a merge/pull rather than
    # reporting as unresolved -- and it carries a fetch phase, so a refspec, an
    # opaque-input shape, or a CONFIGURED destination on it still has to be
    # judged here. A bare `git pull origin` names no destination at all, which is
    # exactly why the fetching test below is on the command word rather than on
    # anything the words spell.
    if [ -z "$ALIAS_CANDIDATES" ] && [ "$CREATE_GITEXE" != "1" ] \
       && [ "$CREATE_FETCHSPEC" != "1" ] && [ -z "$CREATE_OPAQUE" ] \
       && [ "$CREATE_FETCHING" != "1" ] && [ "$CREATE_PUSHING" != "1" ]; then
        return 0
    fi
    # A declaration file that names NO branch is the operator saying this
    # repository has no protected branch — the same statement the merge/pull arm
    # honours below by exiting. Honour it here too, or the conventional names
    # would keep guarding a repo whose operator explicitly said not to.
    if [ "$DECLARED" = "1" ] && [ "$DECL_LISTED" -eq 0 ]; then
        return 0
    fi
    # The names a command can CREATE: protected, and with no local ref. One that
    # exists is a force-update -- #780 -- and deliberately not judged here.
    local _n _absent=""
    for _n in $PROTECTED_NAMES; do
        case " $PROTECTED_SET " in *" $_n "*) continue ;; esac
        _absent="$_absent $_n"
    done
    [ -z "$_absent" ] && return 0
    _absent_names="$_absent"

    # A PUSH writes its destination in ANOTHER repository, which this gate does
    # not guard: that boundary is ADR 0050's, and judging such a push refused
    # `git push origin feature:refs/heads/master` as though it created a local
    # branch. The exception is a push AT this repository, where the ref really
    # does land here -- and that is a CONFIG question (`git push self` with
    # `remote.self.url = .`), not the literal `.` operand a command-string parser
    # can see, which is why it is answered here.
    if [ "$CREATE_PUSHING" = "1" ] && [ "$CREATE_FETCHING" != "1" ]; then
        local _pt _premote="" _at_self=0 _cur_phys _cur_br _gd_phys _cands
        local _cd_phys _mw_phys _wt_trunc=0
        _cur_br=$(git_real symbolic-ref --quiet --short HEAD 2>/dev/null) || _cur_br=""
        _cur_phys=$(cd -- "${REPO_DIR:-.}" 2>/dev/null && pwd -P) || _cur_phys=""
        # A GITDIR path names the same repository as its worktree: `git push
        # .git` and `git push <path>/.git` both land the ref here, and neither
        # resolves to the worktree path.
        _gd_phys=$(git_real rev-parse --absolute-git-dir 2>/dev/null) || _gd_phys=""
        if [ -n "$_gd_phys" ]; then
            _gd_phys=$(cd -- "$_gd_phys" 2>/dev/null && pwd -P) || _gd_phys=""
        fi
        # A LINKED worktree keeps refs/heads/ in the COMMON dir, so a push at the
        # main worktree or at the common dir lands the branch in this
        # repository's ref store just as surely -- and neither path equals this
        # worktree's own `.git/worktrees/<id>` git dir.
        _cd_phys=$(git_real rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _cd_phys=""
        if [ -n "$_cd_phys" ]; then
            _cd_phys=$(cd -- "$_cd_phys" 2>/dev/null && pwd -P) || _cd_phys=""
        fi
        # EVERY worktree, not just the main one: a push from one linked
        # worktree at a SIBLING reaches the same shared ref store. Bounded at 64
        # so a repository with many worktrees cannot spend the gate's budget
        # here; past that the list is treated as unknown, which the boundary
        # below reads as "could not rule this out" rather than as external.
        # NEWLINE-delimited, and compared a whole line at a time: a
        # space-joined list matched `/path/to/my` against a worktree at
        # `/path/to/my project/wt`.
        local _wl _wp _wn=0
        _mw_phys=""
        _wl=$(git_real worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n 65) || _wl=""
        while IFS= read -r _wp; do
            [ -n "$_wp" ] || continue
            _wn=$((_wn + 1))
            # Past 64 the list is TRUNCATED, so it can no longer rule a
            # destination out. Stop reading and say so rather than answer from a
            # list known to be short.
            if [ "$_wn" -gt 64 ]; then _wt_trunc=1; break; fi
            _wp=$(cd -- "$_wp" 2>/dev/null && pwd -P) || continue
            _mw_phys="$_mw_phys$_wp
"
        done <<WLEOF
$_wl
WLEOF
        # `git push --repo=<repository>` names the target inside an OPTION word,
        # where no scan of the command's operands could see it.
        _cands="$CREATE_TOKS"
        for _pt in $CREATE_OPTS; do
            case "$_pt" in *=*) _cands="$_cands ${_pt#*=}" ;; esac
        done
        # The `url.<base>.insteadOf` / `.pushInsteadOf` rewrites, read ONCE:
        # they decide which repository a url actually reaches, so a remote whose
        # configured url points at an external host can still resolve to this
        # one. LOWERCASE keys: git canonicalizes config variable names in its
        # listing whatever the file says, and a mixed-case comparison matched
        # nothing at all.
        local _urc=0 _ucfg=""
        _ucfg=$(git_real config --get-regexp '^url\..*\.(insteadOf|pushInsteadOf)$' 2>/dev/null) || _urc=$?
        if [ "$_urc" -gt 1 ] || [ "${#_ucfg}" -ge 65536 ]; then
            block_emit "BLOCKED: this pushes in ${REPO_DIR:-.} and the gate could not read the repository's url.<base>.insteadOf rewrites (git config exited $_urc, or the listing is past the 64 KiB this gate reads). Those rewrites decide which repository the push actually reaches, so an unreadable one is exactly the case that would hide a push at this repository (issue #781). Blocking as precaution (fail-closed)."
            exit 0
        fi

        # Does this SPELLING of a push destination name this repository? A word
        # can be a remote name, a path, or a url, and each has to be resolved
        # the way git resolves it before the paths can be compared.
        _push_dest_is_self() {
            local _d="$1" _u="" _uline _ukey _uval _ubase _usuf _ulist=""
            local _ubest="" _ubestlen=0 _urest="" _phys _wp
            local _explicit_pushurl=0 _phys1 _phys2
            [ -n "$_d" ] || return 1
            case "$_d" in .) return 0 ;; esac
            # PUSHURL first: git prefers it over url for a push, so reading only
            # url let `url = https://elsewhere/` with `pushurl = .` read as
            # external. A word that is no configured remote is its own url.
            # get-ALL: both keys are multi-valued and git pushes to EVERY url, so
            # one external value must not answer for a sibling naming this
            # repository.
            if _ulist=$(git_real config --get-all "remote.$_d.pushurl" 2>/dev/null); then
                _explicit_pushurl=1
            else
                _ulist=$(git_real config --get-all "remote.$_d.url" 2>/dev/null) \
                    || _ulist="$_d"
            fi
            [ -n "$_ulist" ] || return 1
            while IFS= read -r _u; do
            [ -n "$_u" ] || continue
            _ubest=""; _ubestlen=0; _urest=""
            # Longest matching prefix wins, and for a push a pushInsteadOf match
            # suppresses insteadOf entirely -- git's own rule.
            # Git IGNORES pushInsteadOf for a remote that has an explicit
            # pushurl, so applying it there resolved a destination git does not
            # use -- `pushurl = .` with `url.https://elsewhere/.pushInsteadOf =
            # .` rewrote a self-push into an external one.
            for _usuf in $([ "$_explicit_pushurl" = "1" ] && echo insteadof || echo pushinsteadof insteadof); do
                while IFS= read -r _uline; do
                    [ -z "$_uline" ] && continue
                    _ukey=${_uline%% *}
                    case "$_ukey" in *".$_usuf") ;; *) continue ;; esac
                    # `pushinsteadof` ENDS with `insteadof`, so the second pass
                    # would otherwise read a push rewrite as a plain one.
                    if [ "$_usuf" = insteadof ]; then
                        case "$_ukey" in *.pushinsteadof) continue ;; esac
                    fi
                    _uval=${_uline#* }
                    [ "$_uval" = "$_uline" ] && continue
                    case "$_u" in "$_uval"*) ;; *) continue ;; esac
                    if [ "${#_uval}" -gt "$_ubestlen" ]; then
                        _ubase=${_ukey#url.}
                        _ubest=${_ubase%".$_usuf"}
                        _ubestlen=${#_uval}
                        _urest=${_u#"$_uval"}
                    fi
                done <<CFGEOF
$_ucfg
CFGEOF
                [ -n "$_ubest" ] && break
            done
            [ -n "$_ubest" ] && _u="$_ubest$_urest"
            # `file://` is the same local path spelled as a URL, and a GITDIR
            # path names the same repository as its worktree.
            _u=${_u#file://}
            case "$_u" in */.git) _u=${_u%/.git} ;; esac
            [ -n "$_u" ] || continue
            # The shell expands a leading `~` before git sees the word, while
            # this gate is handed the command UNEXPANDED -- so `git push ~+`
            # resolved as a literal directory named `~+`, failed, and read as an
            # external push. `~` and `~+` are expanded here; `~-` is the shell's
            # OLDPWD and `~user` another account's home, neither of which the
            # gate can know, so those are treated as possibly-here rather than
            # vouched for as elsewhere.
            # shellcheck disable=SC2088  # a LITERAL tilde is the point here:
            # these patterns match the unexpanded word the gate was handed, and
            # $HOME is what they expand it to.
            case "$_u" in
                '~') _u="${HOME:-}" ;;
                '~/'*) _u="${HOME:-}/${_u#'~/'}" ;;
                '~+') _u="${HOOK_CWD:-${REPO_DIR:-.}}" ;;
                '~+/'*) _u="${HOOK_CWD:-${REPO_DIR:-.}}/${_u#'~+/'}" ;;
                '~'*) return 0 ;;
            esac
            [ -n "$_u" ] || continue
            # Both resolutions must SUCCEED. An ordinary `git@host:repo` url is
            # no local path at all, and comparing two empty strings would have
            # called every external remote "this repository".
            # BOTH bases. A relative destination resolves against the shell's
            # directory, which is the payload's cwd and need not be the
            # repository root -- from a nested directory `git push ..` is this
            # repository while `..` from the root is its parent. Trying both
            # over-matches toward BLOCK, which is the direction to miss in.
            _phys1=$(cd -- "${HOOK_CWD:-${REPO_DIR:-.}}" 2>/dev/null && cd -- "$_u" 2>/dev/null && pwd -P) || _phys1=""
            _phys2=$(cd -- "${REPO_DIR:-.}" 2>/dev/null && cd -- "$_u" 2>/dev/null && pwd -P) || _phys2=""
            for _phys in "$_phys1" "$_phys2"; do
                [ -n "$_phys" ] || continue
                { [ -n "$_cur_phys" ] && [ "$_phys" = "$_cur_phys" ]; } && return 0
                { [ -n "$_gd_phys" ] && [ "$_phys" = "$_gd_phys" ]; } && return 0
                { [ -n "$_cd_phys" ] && [ "$_phys" = "$_cd_phys" ]; } && return 0
                # Every linked worktree's ADMIN git dir lives under
                # <common>/worktrees/, and each is a git directory on this same
                # shared ref store -- a whole family no list of worktree ROOTS
                # names, closed by the prefix rather than by enumerating it.
                if [ -n "$_cd_phys" ]; then
                    case "$_phys" in "$_cd_phys"/worktrees/*) return 0 ;; esac
                fi
                while IFS= read -r _wp; do
                    [ -n "$_wp" ] && [ "$_wp" = "$_phys" ] && return 0
                done <<MWEOF
$_mw_phys
MWEOF
            done
            done <<ULEOF
$_ulist
ULEOF
            return 1
        }

        # ANY candidate that names this repository settles it. Stopping at the
        # first word that merely matched a configured remote let `git push
        # --repo=. origin:refs/heads/master` be judged on `origin` -- a refspec
        # half that happens to be a remote name -- and returned as external
        # while git pushed here.
        for _pt in $_cands; do
            if _push_dest_is_self "$_pt"; then
                _premote="$_pt"; _at_self=1; break
            fi
            if [ -z "$_premote" ] \
               && { git_real config --get "remote.$_pt.url" >/dev/null 2>&1 \
                    || git_real config --get "remote.$_pt.pushurl" >/dev/null 2>&1; }; then
                _premote="$_pt"
            fi
        done
        # No word named a destination at all: git's own chain picks one, and the
        # default remote can be this repository just as readily. Treating an
        # unknown target as self instead would refuse the most ordinary command
        # there is.
        if [ "$_at_self" = "0" ] && [ -z "$_premote" ]; then
            _premote=$(git_real config --get "branch.$_cur_br.pushRemote" 2>/dev/null) \
                || _premote=$(git_real config --get remote.pushDefault 2>/dev/null) \
                || _premote=$(git_real config --get "branch.$_cur_br.remote" 2>/dev/null) \
                || _premote="origin"
        fi
        if [ "$_at_self" = "0" ] && [ -n "$_premote" ] \
           && _push_dest_is_self "$_premote"; then
            _at_self=1
        fi
        # A word carrying WHITESPACE is dropped from the candidate list before
        # this runs, so `git push '/path to/this repo' HEAD:refs/heads/master'
        # lost its destination, fell back to the default remote, and returned as
        # external -- ahead of the unreadable-word refusal, which sits after the
        # name match and so never ran. Standing the early return down hands such
        # a command to that refusal, which still fires only once a protected name
        # is matched, so an ordinary quoted word costs nothing.
        # ...and the same stand-down when the worktree listing was truncated:
        # a destination this gate could not enumerate is not one it may vouch for
        # as elsewhere.
        if [ "$_at_self" = "0" ] && [ "$CREATE_UNREADABLE" != "1" ] \
           && [ "$_wt_trunc" != "1" ]; then
            return 0
        fi
        # A self-push with NO refspec in the command takes its destination from
        # `push.default`, which is four more places a protected name can be
        # named without appearing in any word. `remote.<n>.push` overrides it and
        # is read by the configured scan below; this covers the rest.
        # `push` specifically, not `send-pack`: the latter takes its ref updates
        # over the protocol, which the opaque refusal below owns and states
        # better than a guess at push.default would.
        local _has_spec=0 _is_push=0 _tleaf
        for _pt in $_cands; do
            # A colon ANYWHERE was read as "a refspec was supplied", so `git push
            # file://<path>` skipped push.default over the colon in its own URL.
            # The destination word is not a refspec; anything else carrying a
            # colon is.
            # A URL is not a refspec either, whatever colons it carries. The
            # destination word is excluded by name, but `--repo=file://<path>`
            # also leaves its unsplit spelling among the candidates while the
            # word that resolved as the destination is the split one.
            if [ "$_pt" != "$_premote" ]; then
                case "$_pt" in
                    *://*) ;;
                    *:*) _has_spec=1 ;;
                esac
            fi
            # A git builtin reached as its own executable can be PATH-qualified,
            # and `/usr/libexec/git-core/git-push` equals neither spelling.
            _tleaf=${_pt##*/}
            case "$_tleaf" in push|git-push) _is_push=1 ;; esac
        done
        case "$_has_spec$_is_push" in
            01)
                if ! git_real config --get "remote.$_premote.push" >/dev/null 2>&1; then
                    local _pd _pdst=""
                    _pd=$(git_real config --get push.default 2>/dev/null) || _pd="simple"
                    case "$_pd" in
                        upstream|tracking)
                            _pdst=$(git_real config --get "branch.$_cur_br.merge" 2>/dev/null) || _pdst="" ;;
                        matching|nothing)
                            # `matching` pushes only branches that exist on BOTH
                            # sides, and for a self-push both sides are this
                            # repository, so it creates nothing. `nothing` errors.
                            _pdst="" ;;
                        *)
                            [ -n "$_cur_br" ] && _pdst="refs/heads/$_cur_br" ;;
                    esac
                    _pdst=${_pdst#refs/heads/}
                    if [ -n "$_pdst" ]; then
                        case " $_absent " in
                            *" $_pdst "*)
                                block_emit "BLOCKED: this pushes at THIS repository ('$_premote'), and with no refspec on the command line its destination comes from push.default — here, the protected branch '$_pdst', which does not exist in ${REPO_DIR:-.} yet. No word of the command names it, so nothing about the content it would land can be reviewed (issue #781). Name the refspec, or land the work through a PR (/litmus, then /pr-grind). Blocking as precaution (fail-closed)."
                                exit 0 ;;
                        esac
                    fi
                fi ;;
            *) ;;
        esac
    fi

    # A FETCH need not carry a refspec at all: `remote.<name>.fetch` supplies
    # one, so a configured destination under refs/heads/ creates a local branch
    # with no word in the command naming it. Read from the config this gate can
    # see -- which can only ADD refusals, never remove one, so the usual caveat
    # about config the gate cannot see costs nothing here.
    if [ "$CREATE_FETCHING" = "1" ] || [ "$CREATE_PUSHING" = "1" ]; then
            local _cfg="" _crc=0 _cline _cdst _cpre _cname_leaf
            local _rscope="" _ro _rt _rn
            # WHICH remote's refspecs git will actually apply. Reading every
            # remote's over-blocked: an unused `remote.backup.fetch` refused an
            # ordinary `git fetch origin`, and another remote's unused push
            # mapping refused a self-push. Empty means "could not narrow it" and
            # keeps the every-remote scan, so every uncertainty stays fail-closed.
            if [ "$CREATE_PUSHING" = "1" ] && [ "$CREATE_FETCHING" != "1" ]; then
                # A push reaches here only past the at-self return above, so the
                # remote resolved there is the one git uses.
                _rscope="$_premote"
            elif [ "$CREATE_FETCHING" = "1" ] && [ "$CREATE_PUSHING" != "1" ]; then
                # `--all` and `--multiple` fetch from several remotes, and git
                # accepts unambiguous abbreviations of both, so any option
                # starting `--a`/`--m` stands the narrowing down rather than
                # guessing which one it is.
                for _ro in $CREATE_OPTS; do
                    case "$_ro" in --a*|--m*) _rscope="ALL"; break ;; esac
                done
                case " $CREATE_TOKS " in
                    *" remote "*) _rscope="ALL" ;;
                esac
                if [ "$_rscope" != "ALL" ]; then
                    for _rt in $CREATE_TOKS; do
                        # A remotes GROUP names several remotes in one word and
                        # is no remote itself.
                        if git_real config --get "remotes.$_rt" >/dev/null 2>&1; then
                            _rscope="ALL"; break
                        fi
                        if git_real config --get "remote.$_rt.url" >/dev/null 2>&1 \
                           || git_real config --get "remote.$_rt.fetch" >/dev/null 2>&1; then
                            _rscope="$_rscope $_rt"
                        fi
                    done
                fi
                if [ "$_rscope" = "ALL" ]; then
                    _rscope=""
                elif [ -z "$_rscope" ]; then
                    # No remote named: git fetches from the branch's remote, or
                    # origin.
                    _rn=$(git_real symbolic-ref --quiet --short HEAD 2>/dev/null) || _rn=""
                    _rscope=$(git_real config --get "branch.$_rn.remote" 2>/dev/null) \
                        || _rscope="origin"
                fi
            fi
            _cfg=$(git_real config --get-regexp '^remote\..*\.(fetch|push)$' 2>/dev/null) || _crc=$?
            # 1 is "no such key", which is the ordinary answer; anything else is
            # a config this gate could not read, and it decides where a fetch
            # writes.
            if [ "$_crc" -gt 1 ] || [ "${#_cfg}" -ge 65536 ]; then
                block_emit "BLOCKED: this command fetches or pushes in ${REPO_DIR:-.}, and the gate could not read the repository's configured refspecs (git config exited $_crc, or the listing is past the 64 KiB this gate reads). A configured destination under refs/heads/ creates a local branch with no word in the command naming it, so an unreadable configuration is exactly the case that would hide it. Blocking as precaution (fail-closed)."
                exit 0
            fi
            while IFS= read -r _cline; do
                [ -z "$_cline" ] && continue
                case "$_cline" in *:*) ;; *) continue ;; esac
                # Only the key this OPERATION actually reads. An unused
                # `remote.self.push` must not refuse a fetch, and an unrelated
                # remote's fetch mapping must not refuse a push.
                case "${_cline%% *}" in
                    *.fetch) [ "$CREATE_FETCHING" = "1" ] || continue ;;
                    *.push)  [ "$CREATE_PUSHING" = "1" ] || continue ;;
                    *) continue ;;
                esac
                # ...and only the REMOTE it will apply. An empty scope is the
                # could-not-narrow case and reads every line, as before.
                if [ -n "$_rscope" ]; then
                    _rn=${_cline%% *}
                    _rn=${_rn#remote.}
                    _rn=${_rn%.fetch}
                    _rn=${_rn%.push}
                    case " $_rscope " in *" $_rn "*) ;; *) continue ;; esac
                fi
                _cdst=${_cline##*:}
                _cdst=${_cdst#+}
                # Can this destination land under refs/heads/? Asked precisely
                # rather than as "anything but refs/remotes/ and refs/tags/",
                # which over-blocked: refs/notes/, refs/replace/ and any other
                # namespace cannot become a branch. Three ways it can -- under
                # refs/heads/, no refs/ prefix at all (git completes it to
                # refs/heads/<name>), or a wildcard whose literal prefix is short
                # enough to reach refs/heads/ (`refs/*` can, `refs/notes/*`
                # cannot).
                case "$_cdst" in
                    refs/heads/*) ;;
                    refs/*)
                        _cpre=${_cdst%%\**}
                        # Constant on the left ON PURPOSE: the question is
                        # whether refs/heads/ starts with the pattern's literal
                        # prefix, so the prefix is the PATTERN and the fixed
                        # namespace is the word.
                        # shellcheck disable=SC2194
                        case "refs/heads/" in
                            "$_cpre"*) ;;
                            *) continue ;;
                        esac ;;
                    *) ;;
                esac
                # ...and it has to be able to reach a protected name that is
                # ABSENT. An ordinary `remote.<n>.push = HEAD:refs/heads/main`
                # in a repo that HAS main writes nothing new, and refusing it
                # would be the same over-block the namespace test above exists
                # to avoid. A wildcard is the exception: it can expand into any
                # name, so nothing here can tell what it would create.
                case "$_cdst" in
                    *\**) ;;
                    *)
                        _cname_leaf=${_cdst#refs/heads/}
                        case " $_absent " in
                            *" $_cname_leaf "*) ;;
                            *) continue ;;
                        esac ;;
                esac
                block_emit "BLOCKED: this command fetches in ${REPO_DIR:-.} under a configured refspec (remote.<name>.fetch or .push) whose destination is '$_cdst' — it lands under refs/heads/, and it names or can expand into a protected branch ($_PROT_NAME_LIST) that does not exist here yet. No word in the command names it, and its content comes from the REMOTE repository, which nothing local can authenticate (the same reason 'git pull' onto a protected branch is refused outright, issue #779). Point the refspec at the remote-tracking namespace, which writes no local branch:
  git -C $Q_REPO config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
Blocking as precaution (fail-closed)."
                exit 0
            done <<EOF
$_cfg
EOF
    fi


    # A command carrying a literal merge/pull otherwise belongs entirely to the
    # arms below, which already refuse any companion beside it -- so a creation
    # cannot ride along, and leaving it to them keeps #779's refusals speaking
    # for themselves. The exception is a colon REFSPEC, because `git pull`
    # carries a fetch phase: `git pull . topic:refs/heads/master` on an
    # UNPROTECTED branch creates the protected branch during that phase, and the
    # fast-forward arm then exits because the current branch is not protected.
    #
    # An OPAQUE shape needs no exception, and that is a fact about the shapes
    # rather than an oversight. A single command cannot be both `git merge` and
    # `git fast-import`, or both `git merge` and `git update-ref --stdin`, so an
    # opaque shape beside a literal merge/pull is always a COMPANION -- which the
    # arm below refuses outright, blocking the same command with the message
    # #779 wrote for it. The one opaque shape a merge/pull can carry ALONE is a
    # wildcard refspec, and that sets CREATE_FETCHSPEC too, so it does not take
    # this return.
    if [ -n "$KIND" ] && [ "$CREATE_FETCHSPEC" != "1" ]; then
        return 0
    fi

    # `git update-ref --stdin` takes its ref names from DATA -- `printf 'create
    # refs/heads/master <oid>' | git update-ref --stdin` names the branch inside a
    # quoted word this parser reports as one opaque token. There is nothing to
    # match, and the companion refusal below cannot help because it runs only
    # AFTER a match. So the shape is refused wherever a protected name could be
    # created; a scripted batch of ref updates is not a routine command, and the
    # named alternative costs one line each.
    if [ "$CREATE_OPAQUE" = "stdin" ] || [ "$CREATE_OPAQUE" = "stream" ]; then
        block_emit "BLOCKED: this command writes refs from INPUT the gate cannot read — 'git update-ref'/'git fetch' with '--stdin' (any accepted abbreviation) or '-z', or a 'git fast-import' stream carrying its own reset commands. It therefore cannot tell whether one of those writes CREATES a protected branch ($_PROT_NAME_LIST) at content no review gate has seen (issue #781). Name each ref update on the command line instead:
  git update-ref refs/heads/<branch> <oid>
Blocking as precaution (fail-closed)."
        exit 0
    fi
    if [ "$CREATE_OPAQUE" = "wildcard" ]; then
        block_emit "BLOCKED: this command carries a refspec whose DESTINATION is a wildcard that can expand into refs/heads/, in a repo where a protected branch ($_PROT_NAME_LIST) does not exist yet — so it can CREATE one at content no review gate has seen while naming it nowhere the gate can read (issue #781). Name the refs you mean:
  git fetch <remote> <branch>
(A destination under refs/remotes/ or refs/tags/ writes no local branch and is not refused.) Blocking as precaution (fail-closed)."
        exit 0
    fi

    # MATCHED here, not in the parser: the parser does not know which names
    # are protected, and a set-membership test needs no grammar.
    local _t _matched=""
    _matched_all=""
    for _t in $CREATE_TOKS; do
        case " $_absent " in
            *" $_t "*)
                [ -z "$_matched" ] && _matched="$_t"
                _matched_all="$_matched_all $_t" ;;
        esac
    done
    # THE IMPLICIT DESTINATION. On an UNBORN branch, HEAD is a symbolic ref to a
    # branch that does not exist, and every ref writer that goes THROUGH HEAD
    # creates it while naming it nowhere: `git update-ref HEAD <oid>` and
    # `git reset <oid>` both land content on the protected branch with no
    # protected word in the command at all. HEAD names it, so HEAD is read.
    local _head_sym=""
    _head_sym=$(git_real symbolic-ref --quiet --short HEAD 2>/dev/null) || _head_sym=""
    if [ -n "$_head_sym" ]; then
        case " $_absent " in
            *" $_head_sym "*)
                [ -z "$_matched" ] && _matched="$_head_sym"
                case " $_matched_all " in
                    *" $_head_sym "*) ;;
                    *) _matched_all="$_matched_all $_head_sym" ;;
                esac ;;
        esac
    fi
    # ATTACHED to an option word, which carries no word of its own:
    # `git checkout -bmaster <oid>`, `-Bmaster`, `switch -cmaster`, a clustered
    # `-qbmaster` and `--create=master` all create `master`. Tested as a SUFFIX
    # rather than against a table of which options take an attached value —
    # over-matching here BLOCKS (`--no-main` would), which is the safe direction,
    # and no option table can go stale.
    local _o
    for _o in $CREATE_OPTS; do
        for _t in $_absent; do
            case "$_o" in
                *"$_t")
                    [ -z "$_matched" ] && _matched="$_t"
                    case " $_matched_all " in
                        *" $_t "*) ;;
                        *) _matched_all="$_matched_all $_t" ;;
                    esac ;;
            esac
        done
    done
    [ -z "$_matched" ] && return 0

    # TWO WAYS the ref's content is not any word of the command, and the
    # reachability proof below cannot see either. A SYMBOLIC ref points at a
    # NAME: `git symbolic-ref refs/heads/master refs/heads/staging` against an
    # absent `staging` passes every reachability test today, and the `git
    # update-ref refs/heads/staging <unreviewed>` that follows names no protected
    # branch at all. `git notes --ref=refs/heads/master add -m x HEAD`
    # SYNTHESIZES a notes commit and points the ref at it, so the object did not
    # exist when the gate looked. Refuse the shape rather than vouch for content
    # the command has not produced yet.
    if [ "$CREATE_SYMREF" = "1" ]; then
        block_emit "BLOCKED: this command would point the protected branch '$_matched' at content the gate cannot see, in ${REPO_DIR:-.} where it does not exist yet — a SYMBOLIC ref, which carries whatever its target holds LATER (and the command that then writes that target names no protected branch at all), or a 'git notes' write, which SYNTHESIZES the commit it points the ref at. Neither is any word of this command, so nothing about it can be reviewed now (issue #781). Point the branch at a commit that already exists:
  git branch $_matched <full object id>
Blocking as precaution (fail-closed)."
        exit 0
    fi

    # A FETCH resolves its refspec source in the REMOTE repository, so the word
    # that looks vouchable here is not the content git will land: `git fetch evil
    # main:refs/heads/master` passes a local `main` reachable from a protected
    # branch while landing `evil`'s. Authenticating a remote source is what ADR
    # 0050 already rejected as unachievable — the fast-forward arm refuses `git
    # pull` outright for exactly this reason — so this refuses too.
    if [ "$CREATE_FETCHSPEC" = "1" ]; then
        block_emit "BLOCKED: this fetch would CREATE the protected branch '$_matched' in ${REPO_DIR:-.} from a refspec whose SOURCE is resolved in the REMOTE repository — so the word naming it here is not the content git would land, and no local check can authenticate where it came from (the same reason 'git pull' onto a protected branch is refused outright, issue #779). Fetch into the remote-tracking namespace and land the work through a PR:
  git fetch <remote>
Blocking as precaution (fail-closed)."
        exit 0
    fi
    # A word carrying whitespace cannot be a ref NAME — which is why it is not
    # matched — but it can be a REVISION (`:/unreviewed subject` finds a commit
    # by its message), so it can be the start point, and skipping it left a
    # vouched HEAD as the only evidence. Refuse rather than vouch on a list known
    # to be incomplete. Nothing fires until a protected name is matched, so an
    # ordinary quoted commit message costs nothing.
    if [ "$CREATE_UNREADABLE" = "1" ]; then
        block_emit "BLOCKED: this command would create the protected branch '$_matched' in ${REPO_DIR:-.}, and it carries a word the gate cannot read as a ref name (it contains whitespace). Git still accepts such a word as a REVISION, so it may be the start point, and the gate will not vouch for a creation on a list of candidates it knows is incomplete (issue #781). Name the start point as a full object id:
  git branch $_matched <full object id>
Blocking as precaution (fail-closed)."
        exit 0
    fi

    # Every word below costs two short git calls inside the 10s budget, whose
    # expiry emits no decision at all -- so a command naming more ref-plausible
    # words than this is REFUSED rather than half-examined, the same shape as the
    # remote-listing and declaration bounds above. The bound is applied here and
    # not in the parser, because a parser-side cap would silently drop a word
    # from the MATCH above and read as "names nothing protected".
    local _ntok
    _ntok=$(printf '%s' "$CREATE_TOKS" | wc -w | tr -d ' ')
    if [ "$_ntok" -gt 16 ]; then
        block_emit "BLOCKED: this command names the protected branch '$_matched', which does not exist in ${REPO_DIR:-.} yet, and carries more candidate start points than the gate resolves inside its 10s budget. It cannot show that every one of them is already reachable from a protected branch, and a walk that outruns the budget is killed without emitting a decision. Run the creation on its own. Blocking as precaution (fail-closed)."
        exit 0
    fi
    # A companion command makes every answer below a pre-command value: it can
    # move HEAD, write the very oid being vouched for, or create the ref itself.
    # Same rule, and the same reason, as the merge arm's.
    if [ "$REF_WRITER" = "1" ]; then
        block_emit "BLOCKED: this command runs something else ALONGSIDE a reference to '$_matched', a protected branch that does not exist in ${REPO_DIR:-.} yet. The gate reads HEAD and resolves every start point BEFORE the command runs, so a companion command can move what it checked -- or create the ref outright -- after it has already looked (issue #781).

Run the parts as SEPARATE calls, so the gate sees the start point at its final value. (A leading 'cd' is fine -- it only scopes the command.)"
        exit 0
    fi

    # INERT? Every start point the command could use -- HEAD, every ref-plausible
    # word in it, and (git's DWIM start point) every remote-tracking ref whose
    # full path suffix matches a matched name -- already reachable from a
    # protected branch that EXISTS. Then whatever this creates is content those
    # branches already carry, and no review was skipped.
    #
    # ONE rev-list over ALL of them, not one per oid. `rev-list <oids...> --not
    # <protected refs>` prints nothing exactly when EVERY oid is reachable from
    # the set, and the first thing it does print IS an unvouched commit -- which
    # is the answer AND the oid for the block message. Seventeen graph walks
    # inside a 10s budget whose expiry emits no decision was a way through the
    # gate; this is one.
    local _cands="" _oid _obj
    for _t in HEAD $CREATE_TOKS; do
        _oid=$(git_real rev-parse --verify --quiet "${_t}^{commit}" 2>/dev/null) || _oid=""
        if [ -z "$_oid" ]; then
            # `A...B` IS a start point -- measured: `git branch <name> f1...f2`,
            # `checkout -b` and `switch -c` all create the branch at the MERGE
            # BASE -- but it names two revisions, so `rev-parse <tok>^{commit}`
            # refuses to reduce it and the word was skipped as if it named
            # nothing. Skipping is the ALLOW direction, so an unreviewed merge
            # base rode past a vouched HEAD. Refuse rather than resolve it: this
            # spelling is not a routine creation, and one full object id costs a
            # single re-typed command.
            case "$_t" in
                :/*)
                    # `:/text` finds a commit by its MESSAGE, and `^{commit}`
                    # cannot be appended to it -- git reads the suffix as part of
                    # the search text, resolution fails, and the word was skipped
                    # as naming nothing. Skipping is the ALLOW direction, so a
                    # commit reachable only from an unprotected ref rode past a
                    # vouched HEAD. Refused rather than resolved, like the range
                    # spelling below.
                    block_emit "BLOCKED: this command would create the protected branch '$_matched' in ${REPO_DIR:-.} from '$_t', which finds a commit by its MESSAGE rather than naming one — the gate cannot reduce it to a single object without re-running git's search, and it will not vouch for a start point it has not resolved (issue #781). Name the commit itself:
  git rev-list -1 '$_t'
  git branch $_matched <that object id>
Blocking as precaution (fail-closed)."
                    exit 0 ;;
                *...*)
                    block_emit "BLOCKED: this command would create the protected branch '$_matched' in ${REPO_DIR:-.} from '$_t', which names a RANGE rather than one commit — git resolves it to the merge base, and the gate will not vouch for a start point it cannot reduce to a single object (issue #781). Name the commit itself:
  git merge-base <a> <b>
  git branch $_matched <that object id>
Blocking as precaution (fail-closed)."
                    exit 0 ;;
            esac
            # A ref does NOT have to point at a commit. `git update-ref
            # refs/heads/master <blob oid>` creates the protected branch at a
            # blob, and peeling to `^{commit}` failed on it -- so the word was
            # skipped as naming nothing, which is the ALLOW direction, and the
            # reachability proof vouched for HEAD alone. An object that EXISTS
            # and is not a commit has no ancestry to check, so it can never be
            # shown reachable: refuse it.
            _obj=$(git_real rev-parse --verify --quiet "${_t}^{object}" 2>/dev/null) || _obj=""
            if [ -n "$_obj" ]; then
                block_emit "BLOCKED: this command would create the protected branch '$_matched' in ${REPO_DIR:-.} at $_obj, which is an object but NOT a commit — a ref may point at a blob or a tree, and such an object has no ancestry, so nothing can show it is content a protected branch already carries (issue #781). Point the branch at a commit:
  git branch $_matched <full object id of a commit>
Blocking as precaution (fail-closed)."
                exit 0
            fi
            continue
        fi
        case " $_cands " in *" $_oid "*) ;; *) _cands="$_cands $_oid" ;; esac
    done
    # GIT'S DWIM START POINT, which is NOT one of the words above. `git checkout
    # main` / `git switch main` with no local `main` creates it from
    # refs/remotes/<remote>/main -- and a bare `main` does NOT resolve to that ref
    # (rev-parse's DWIM list reaches refs/remotes/<name>, never
    # refs/remotes/<remote>/<name>), so the word above resolved to nothing, was
    # skipped, and only HEAD was vouched for. In a repo whose protected branch is
    # `develop`, HEAD sits on reviewed content while the created `main` lands
    # whatever the remote-tracking ref holds -- a fail-OPEN on the very shape the
    # second half of #781 names.
    # ONE listing rather than a lookup per (remote, word), and git's own STATUS is
    # the answer: a producer failure read as an empty list would omit exactly the
    # unreviewed oid this exists to find, so it blocks. `--count` bounds the walk
    # inside git rather than by closing a pipe on it, which is what makes the
    # status trustworthy.
    local _rtlist="" _rtrc=0 _rtref _rtoid _rtn
    _rtlist=$(git_real for-each-ref --count=512 --format='%(refname) %(objectname)' refs/remotes/ 2>/dev/null) || _rtrc=$?
    if [ "$_rtrc" -ne 0 ] || [ "${#_rtlist}" -ge 65536 ]; then
        block_emit "BLOCKED: this command names the protected branch '$_matched', which does not exist in ${REPO_DIR:-.} yet, and the gate could not read the repository's remote-tracking refs (git for-each-ref exited $_rtrc, or the listing is past the 64 KiB this gate reads). Git creates such a branch from refs/remotes/<remote>/$_matched when no start point is given, so an unreadable listing is exactly the case that would hide what it lands. Blocking as precaution (fail-closed)."
        exit 0
    fi
    # shellcheck disable=SC2310  # no match IS the zero answer
    _rtn=$(printf '%s' "$_rtlist" | grep -c '^') || _rtn=0
    if [ "$_rtn" -ge 512 ]; then
        block_emit "BLOCKED: this command names the protected branch '$_matched', which does not exist in ${REPO_DIR:-.} yet, and the repository has more remote-tracking refs than the gate enumerates (512). It cannot rule out that one of them is the refs/remotes/<remote>/$_matched git would create the branch from. Blocking as precaution (fail-closed)."
        exit 0
    fi
    while read -r _rtref _rtoid; do
        [ -z "$_rtref" ] && continue
        # By the WHOLE name as a path suffix, never `${_rtref##*/}`: a protected
        # `release/main` lives at refs/remotes/origin/release/main, whose last
        # component is `main`, so the branch the DWIM would create was never
        # vouched for. A suffix can also over-match, which only ADDS oids that
        # must be reachable -- the BLOCKING direction.
        for _t in $_matched_all; do
            case "$_rtref" in
                */"$_t")
                    case " $_cands " in
                        *" $_rtoid "*) ;;
                        *) _cands="$_cands $_rtoid" ;;
                    esac ;;
            esac
        done
    done <<EOF
$_rtlist
EOF
    # Nothing resolvable at all -- a fresh repo with no commits, say. Nothing can
    # be landed by a command whose every start point is unresolvable, so there is
    # nothing to vouch for.
    [ -z "$_cands" ] && return 0
    local _not_refs="" _b
    for _b in $PROTECTED_SET; do _not_refs="$_not_refs refs/heads/$_b"; done
    local _unvouched="" _rc=0
    # shellcheck disable=SC2086  # deliberate word split of both ref lists
    _unvouched=$(git_real rev-list --max-count=1 $_cands --not $_not_refs 2>/dev/null) || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        block_emit "Ref gate: git could not decide whether the start points of this command are already reachable from a protected branch in ${REPO_DIR:-.} (git rev-list exited $_rc rather than answering), so the gate cannot tell whether creating '$_matched' would land unreviewed content. Blocking as precaution (fail-closed)."
        exit 0
    fi
    [ -z "$_unvouched" ] && return 0

    authorize_create_or_block "$_matched" "$CREATE_NAME" "$CREATE_OID" "$_unvouched"
}

# The marker route for a creation. It shares state_file, the anti-self-bypass
# window, the forge guard, the audit append and the single-use consume with the
# fast-forward route above; what it does NOT share is that route's --ff-only
# requirement (there is no merge to constrain) and its core.hooksPath refusal
# (`git branch` runs no hook -- which is also why `git branch` is the one shape
# this route authorizes, rather than `checkout -b`, whose post-checkout hook
# would put the landed content one step from execution).
authorize_create_or_block() {   # <matched> <canon name> <canon oid word> <unvouched oid>
    local matched="$1" cname="$2" cspec="$3" unvouched="$4"
    local _q_marker _q_line _q_name
    printf -v _q_marker '%q' "$MARKER"
    # ONE exact shape is authorizable, and it is an ALLOWLIST -- a creation
    # spelling this does not recognize gets no route rather than a guessed one,
    # so a shape missed here fails CLOSED.
    case " $_absent_names " in
        *" $cname "*) ;;
        *) cname="" ;;   # the shape names something else; no marker route
    esac
    if [ -z "$cname" ]; then
        printf -v _q_name '%q' "$matched"
        block_emit "BLOCKED: this would CREATE the protected branch '$matched' in ${REPO_DIR:-.} at content no review gate has seen -- $unvouched is reachable from no protected branch here. A creation makes no commit object, so nothing in the commit-oriented machinery observes it, exactly like the fast-forward in issue #779 (issue #781).

Ordinary work does not need this. Either use a name that is not protected here ($_PROT_NAME_LIST), or start the branch from content a protected branch already carries -- the gate allows that with no ceremony.

To land new work, open a PR and merge it (/litmus, then /pr-grind).

If this exact creation is what the user wants, the gate authorizes ONE shape, so that it can bind an authorization to an object id git will not resolve again:
  git branch $_q_name <full object id>
Re-run it that way and the block message will print the exact line to write."
        exit 0
    fi
    printf -v _q_name '%q' "$cname"
    local oid=""
    oid=$(git_real rev-parse --verify --quiet "${cspec}^{commit}" 2>/dev/null) || oid=""
    if [ -z "$oid" ]; then
        block_emit "BLOCKED: this would create the protected branch '$cname' in ${REPO_DIR:-.}, but the gate cannot resolve its start point '$cspec' to a commit, so it cannot tell what content the branch would carry (issue #781). Blocking as precaution (fail-closed)."
        exit 0
    fi
    # "Resolves to itself" is an equality, not a length -- the merge arm states
    # the reasoning at length. A symbolic word is looked up again when the
    # command runs, so an authorization bound to it would not bind the ref move.
    local _spec_lc _oid_lc
    _spec_lc=$(printf '%s' "$cspec" | tr '[:upper:]' '[:lower:]')
    _oid_lc=$(printf '%s' "$oid" | tr '[:upper:]' '[:lower:]')

    local _mrc=0 _mraw="" _mcontent
    _mraw=$(state_file read 'ref-ff-authorized.local' && printf X) || _mrc=$?
    _mcontent="${_mraw%X}"
    _mcontent="${_mcontent%$'\n'}"
    if [ "$_mrc" -eq 2 ]; then
        block_emit "BLOCKED: $MARKER_REL could not be read safely -- it is a symlink, sits behind a symlinked path component, or is not a regular file. The authorization token is honoured only as a regular file the operator wrote in place."
        exit 0
    fi
    if [ "$_spec_lc" != "$_oid_lc" ]; then
        if [ "$_mrc" -eq 0 ]; then
            block_emit "BLOCKED: a $MARKER_REL marker is present, but this creation names '$cspec' -- a symbolic ref that git resolves again when the command runs, so the authorization could not be bound to the ref it produces. Name the object id instead, which resolves to itself:
  git branch $_q_name $oid
The marker must then read: PASS-CREATE refs/heads/$cname $oid"
            exit 0
        fi
    fi
    local expected="PASS-CREATE refs/heads/$cname $oid"
    printf -v _q_line '%q' "$expected"
    if [ "$_mrc" -eq 0 ] && [ "$_spec_lc" = "$_oid_lc" ] \
       && ! gate_skip_file_repo_controlled "$REPO_DIR" "$MARKER_REL"; then
        local age=999 mtime=""
        mtime=$(stat -f %m "$MARKER" 2>/dev/null) \
            || mtime=$(stat -c %Y "$MARKER" 2>/dev/null) \
            || mtime=""
        [ -n "$mtime" ] && age=$(( $(date +%s) - mtime ))
        if [ "$age" -lt 30 ]; then
            block_emit "BLOCKED: $MARKER_REL was created moments ago (likely self-bypass). Do NOT create $MARKER yourself. If the user wants to authorize this creation, they should create the file manually in their terminal."
            exit 0
        fi
        # Whole-file compare, never a per-line grep, and never a PASS-FF line:
        # the two verbs authorize different operations and a token minted for one
        # must not be spendable on the other.
        if [ "$_mcontent" = "$expected" ]; then
            audit_ref_ff "$cname" "$oid" "marker-create"
            if ! state_file unlink 'ref-ff-authorized.local' >/dev/null 2>&1; then
                block_emit "BLOCKED: the authorization in $MARKER_REL matched, but the gate could not CONSUME it -- the file could not be removed (a read-only state directory, or the entry is no longer a plain file). It is single-use by design, and leaving it in place would authorize every later creation too, so the command is refused rather than run against a token that stays live. Remove the file and re-authorize."
                exit 0
            fi
            exit 0
        fi
    fi
    block_emit "BLOCKED: this would CREATE the protected branch '$cname' in ${REPO_DIR:-.} at $oid, which is reachable from no protected branch here -- content no review gate has seen. A creation makes no commit object, so nothing in the commit-oriented machinery observes it, exactly like the fast-forward in issue #779 (issue #781).

To land new work, open a PR and merge it (/litmus, then /pr-grind). Starting the branch from content a protected branch already carries needs no authorization at all.

If the user really wants this exact creation, they can authorize it in their own terminal -- one ref, one oid, single use:
  echo $_q_line > $_q_marker
  git branch $_q_name $oid
Every use is recorded in ${REPO_DIR:+$REPO_DIR/}$STATE_DIR/bypass-log.jsonl."
    exit 0
}

_PROT_NAME_LIST=${PROTECTED_NAMES# }
_absent_names=""
_matched_all=""
creation_check
# Everything below is about a merge or a pull. A command that is neither has
# been fully judged by the creation check.
[ "$IS_REFOP" = "1" ] || exit 0



if [ "$REF_WRITER" = "1" ] && [ -n "$KIND" ]; then
    block_emit "BLOCKED: this command runs something else ALONGSIDE a merge/pull, in a repo with a protected branch ($_PROT_LIST). The gate resolves the merge target and reads git config before the command runs, so any other command in the same invocation can replace what it checked — including which branch is checked out ('git switch main && git merge <oid>') — 'git branch -f topic <oid> && git merge topic' is the shape, 'git fetch' counts because it moves FETCH_HEAD and the remote-tracking refs, and so does anything that can run a configured helper or change git's environment. The gate does not try to tell those apart from a harmless 'git status'.

Run the parts as SEPARATE calls, so the gate sees the target at its final value:
  git fetch <remote> <ref>
  git merge --ff-only <oid>
(A leading 'cd' is fine — it only scopes the command.)"
    exit 0
fi

# Detached HEAD moves no branch ref; a merge onto any OTHER branch is ordinary
# feature work that the commit/PR gates already cover on its way to main.
CURRENT=$(git_real symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT=""
[ -z "$CURRENT" ] && exit 0
# PROTECTED_NAMES, not PROTECTED_SET. An UNBORN protected branch is absent from
# the set of branches that EXIST, so a repo where some OTHER protected branch
# exists passed the empty-set safeguard and then found no protected current ref
# to match -- and `git pull <remote> <branch>` populated the unborn protected
# branch from remote content, which is precisely what this gate refuses
# everywhere else. It is still the protected branch when it has no commits yet.
case " $PROTECTED_NAMES " in *" $CURRENT "*) ;; *) exit 0 ;; esac
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
