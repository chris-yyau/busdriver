#!/usr/bin/env bash
# Unit tests for the shared git/gh command detector (lib/gitcmd_detect.py).
#
# This is the SINGLE canonical spec for the command-word detection that every
# gate now shares. It exercises the combination matrix the mirrored parsers
# repeatedly failed on: command wrappers, absolute-path wrappers, wrapper
# options (arg-taking and no-arg), env-assignments, quoting, whitespace, and
# prose. The per-gate suites (test-pre-commit-gate.sh, test-pre-pr-gate.sh,
# test-pre-merge-gate.sh) drive the real gate scripts end-to-end; this one
# pins the detector logic directly.
#
# Usage: bash tests/test-gitcmd-detect.sh   (exit 0 all pass, 1 any fail)
set -euo pipefail
cd "$(dirname "$0")/.."

LIB_DIR="$(pwd)/hooks/gate-scripts/lib"

PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import gitcmd_detect as g

fails = 0

def check(label, got, exp):
    global fails
    ok = got == exp
    if not ok:
        fails += 1
    print(f"  {'PASS' if ok else 'FAIL'}  {label:52} exp={exp} got={got}")

# ── git commit: positives (must be recognized → gate blocks) ──────────
COMMIT_YES = [
    'git commit -m x',
    'git commit',
    'command git commit -m x',
    'env FOO=1 git commit',
    'env -i FOO=1 git commit',           # env option
    '/usr/bin/git commit',               # absolute-path exe
    '/usr/bin/env -i git commit',        # absolute-path wrapper
    'sudo -u nobody git commit',         # arg-taking option
    'sudo -n git commit',                # no-arg option (must not eat git)
    'sudo -S git commit',                # no-arg option
    'time -p git commit',
    'command -- git commit',
    'nice -n 10 git commit',
    'env -u git commit',                 # fail-closed: git-exec not skipped
    "'git' commit -m x",                 # quoted executable
    '"/usr/bin/git" commit',             # quoted abs-path executable
    'git  commit',                       # extra whitespace
    'cd /tmp && git commit -m x',        # cd-prefixed
    'true & git commit -m x',            # lone & background operator
    'sleep 1 & git commit',              # background op, real commit follows
    'git --git-dir /r/.git --work-tree /r commit',  # global value-options
    'git --namespace ns commit',         # global value-option
    'git -c user.name=x commit',         # -c name=value then subcommand
    'false && cd /repo; git commit',     # short-circuited cd, commit still runs
    '(git commit -m x)',                 # subshell grouping
    '{ git commit -m x; }',              # brace group
    '( git commit )',                    # spaced subshell
    '! git commit -m x',                 # pipeline negation (command runs)
    '>/tmp/out git commit -m x',         # fused redirection prefix
    '> /tmp/o git commit',               # bare redirection + target
    '2>/dev/null git commit',            # fd redirection prefix
    'echo "$(git commit -m x)"',         # executing command substitution
    'x=$(git commit)',                   # assignment substitution
    '`git commit`',                      # backtick substitution
    "bash -c 'git commit -m x'",         # interpreter payload
    'sudo bash -c "git commit"',         # wrapped interpreter
    "sh -c 'git commit'",                # sh -c payload
    "echo \"$(printf ')'; git commit -m x)\"",  # quoted ) inside substitution
    # Clustered -c: bash/sh take the NEXT argv as the command string wherever
    # `c` sits in the cluster. Matching only a bare '-c' let these evade every
    # gate. Verified against real bash/sh — all of these do execute the payload.
    "bash -lc 'git commit -m x'",        # c last in cluster
    "bash -cl 'git commit -m x'",        # c NOT last — still the command string
    "bash -ec 'git commit'",
    "bash -xc 'git commit'",
    "sh -ec 'git commit'",
    "zsh -lc 'git commit'",
    "sudo bash -lc 'git commit'",        # wrapped + clustered
    'bash --norc -c "git commit"',       # long option walked past, then -c
    # An arg-taking option can carry a value that itself looks like a clustered
    # -c. Verified to really execute, so the scan must not stop at the first
    # candidate and skip the REAL payload.
    'bash --rcfile -custom -c "git commit"',
    'bash --rcfile -c -c "git commit"',  # option value is literally -c
    'bash -O extglob -c "git commit"',   # short option with a separate argument
    # An arg-taking option INSIDE the cluster shifts the command string further
    # along (-O eats extglob, so the payload is argv[3]) — verified to execute.
    'bash -Oc extglob "git commit"',
    # bash accepts '+' as an option sign and `case c` ignores the sign.
    'bash +c "git commit"',              # verified: really executes
    'bash +lc "git commit"',             # clustered, plus sign
]
# ── git commit: negatives (must NOT be recognized → gate allows) ──────
COMMIT_NO = [
    'echo please git commit later',      # prose
    'git log --grep=commit',             # different subcommand
    'printf gitcommit',
    'gitfoo commit',                     # not the git executable
    "printf 'x; git commit'",            # quoted ; is not a separator
    'echo "run git commit"',
    '> git commit',                      # redirect stdout to file 'git', runs 'commit'
    "echo '$(git commit)'",              # single quotes suppress the substitution
    "bash -c 'echo hi'",                 # interpreter payload is not a commit
    "bash -lc 'echo hi'",                # clustered -c, still not a commit
    'bash script.sh',                    # no -c → no payload to scan
    'bash -s',                           # short option without c
    'bash -Oc extglob "echo hi"',        # payload scanned, but not a commit
    # An operand ENDS the option section, so a later `-c`-looking token is the
    # SCRIPT's own argument, not bash's. Verified against real bash:
    #   bash script.sh -lc 'echo PAYLOAD'
    #     -> "script ran with args: -lc echo PAYLOAD"  (payload NOT executed)
    # Treating it as a payload would block a command that never commits.
    'bash script.sh -lc "git commit"',
    'bash deploy.sh -c "git commit -m x"',
]

for c in COMMIT_YES:
    check(f"commit+ {c!r}", g.git_commit(c)[0], True)
for c in COMMIT_NO:
    check(f"commit- {c!r}", g.git_commit(c)[0], False)

# ── gh pr create ──────────────────────────────────────────────────────
CREATE_YES = [
    'gh pr create --fill',
    'command gh pr create',
    'gh  pr create',                     # double space
    '/usr/bin/gh pr create',
    '/usr/bin/env -i gh pr create',
    'sudo -u nobody gh pr create',
    'sudo -n gh pr create',
    'env -i FOO=1 gh pr create',
    "'gh' pr create",                    # quoted executable
    'cd /r && gh pr create',
    'true & gh pr create',               # lone & background operator
    'gh --repo owner/repo pr create',    # gh global flag (separate value)
    'gh -R o/r pr create',               # short global flag (separate value)
    'gh --hostname github.com pr create',  # value-taking global flag
    'gh --repo=owner/repo pr create',    # attached '=' value
    'gh -Rowner/repo pr create',         # short attached value
    '(gh pr create --fill)',             # subshell grouping
    '{ gh pr create; }',                 # brace group
    '! gh pr create',                    # pipeline negation
    '>/tmp/o gh pr create',              # redirection prefix
    'result=$(gh pr create --fill)',     # assignment substitution
    'echo "$(gh pr create)"',            # executing substitution
    "sh -c 'gh pr create --fill'",       # interpreter payload
    "eval 'gh pr create'",               # eval payload
]
CREATE_NO = [
    'echo run gh pr create when ready',  # prose
    'gh pr list',
    "printf 'x; gh pr create https://github.com/o/r/pull/1'",  # quoted ; bypass
]
for c in CREATE_YES:
    check(f"create+ {c!r}", g.gh_pr(c, 'create')[0], True)
for c in CREATE_NO:
    check(f"create- {c!r}", g.gh_pr(c, 'create')[0], False)

# ── gh pr merge (command-word; distinct from pre-merge's multi-merge count) ──
MERGE_YES = ['gh pr merge 5', 'command gh pr merge 5', 'gh  pr  merge 5',
             'sudo -n gh pr merge 5', 'true & gh pr merge 5',
             "eval 'gh pr merge 5'", "bash -c 'gh pr merge 7'"]
MERGE_NO = ['echo gh pr merge 31', "printf 'x; gh pr merge 5'"]
for c in MERGE_YES:
    check(f"merge+ {c!r}", g.gh_pr(c, 'merge')[0], True)
for c in MERGE_NO:
    check(f"merge- {c!r}", g.gh_pr(c, 'merge')[0], False)

# ── target_dir / is_amend / pr_num extraction ─────────────────────────
check("cd target_dir (&&-gated)", g.git_commit('cd /tmp/r && git commit')[1], '/tmp/r')
check("cd NOT trusted (short-circuit)", g.git_commit('false && cd /tmp/r; git commit')[1], '')
check("cd NOT trusted (semicolon)", g.git_commit('cd /tmp/r; git commit')[1], '')
check("git -C target_dir", g.git_commit('git -C /tmp/r commit')[1], '/tmp/r')
check("cd + relative -C", g.git_commit('cd /repoA && git -C nested commit')[1], '/repoA/nested')
check("sequential -C", g.git_commit('git -C /repoA -C nested commit')[1], '/repoA/nested')
check("commit -C is reuse-msg not cd", g.git_commit('git commit -C HEAD')[1], '')
check("cd + commit -C reuse (not HEAD)", g.git_commit('cd /repoA && git commit -C HEAD')[1], '/repoA')
check("merge pr_num past global flag", g.gh_pr('gh --repo o/r pr merge 7', 'merge')[2], '7')
check("is_amend true", g.git_commit('git commit --amend --no-edit')[2], True)
check("is_amend flag-order", g.git_commit("git commit -m 'x' --amend")[2], True)
check("is_amend pathspec-scoped", g.git_commit('git commit --allow-empty -- --amend')[2], False)
check("merge pr_num", g.gh_pr('command gh pr merge 5 --squash', 'merge')[2], '5')
check("merge pr_num flag-first", g.gh_pr('gh pr merge --squash 5', 'merge')[2], '5')
check("merge pr_num after -R flag", g.gh_pr('gh pr merge -R owner/repo 5', 'merge')[2], '5')
check("merge pr_num skips value-flag arg", g.gh_pr('gh pr merge --subject 123 5', 'merge')[2], '5')

# ── Property-based: {leading operators} × {wrappers} × git-commit should ALL
#    detect; the same form as an ARGUMENT to a non-git command must NOT. ──────
import itertools
LEADS = ['', 'true && ', 'true & ', 'cd /tmp && ', 'ls; ', 'a=b ']
WRAPS = ['', 'command ', 'env FOO=1 ', 'sudo -n ', 'sudo -u nobody ',
         '/usr/bin/env -i ', 'nice -n 5 ', 'time -p ']
for lead, wrap in itertools.product(LEADS, WRAPS):
    pos = f"{lead}{wrap}git commit -m x"
    check(f"gen commit+ {pos!r}", g.git_commit(pos)[0], True)
    neg = f"echo {wrap}git commit"   # git commit as echo's argument, not a command
    check(f"gen commit- {neg!r}", g.git_commit(neg)[0], False)
    posc = f"{lead}{wrap}gh pr create --fill"
    check(f"gen create+ {posc!r}", g.gh_pr(posc, 'create')[0], True)

print()
print(f"  {'ALL PASS' if fails == 0 else str(fails) + ' FAILED'}")
raise SystemExit(1 if fails else 0)
PY
rc=$?
echo ""
if [[ "$rc" -eq 0 ]]; then echo "── test-gitcmd-detect: all passed ──"; else echo "── test-gitcmd-detect: FAILED ──"; fi
exit "$rc"
