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
    # APPEND-form assignment prefix. `A+=1 git commit` runs the commit exactly like
    # `A=1 git commit`, but the assignment regex was `^\w+=` — no `+` — so the
    # assignment stayed in argv, argv[0] was not `git`, and the command went
    # UNDETECTED in every gate sharing this detector. Fail-open, found via #505.
    'A+=1 git commit -m x',
    'A+=1 B=2 git commit',               # mixed append + plain prefixes
    'env A+=1 git commit',               # append form behind a wrapper
    'A[0]=1 git commit -m x',            # INDEXED assignment word
    'A[0]+=1 git commit -m x',           # indexed + append
    'A[foo[0]]=1 git commit -m x',       # NESTED subscript — must not stop at first ]
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
    # -cO and -Oc are identical to bash (verified — both run the payload), so
    # the position of c in the cluster must not change the result.
    'bash -cO extglob "git commit"',
    # zsh's -O takes NO value (bash's does) — option arity is PER-SHELL, which
    # is why no single arity model is used. Verified: this runs the payload.
    'zsh -cO "git commit" placeholder',
    # bash accepts '+' as an option sign and `case c` ignores the sign.
    'bash +c "git commit"',              # verified: really executes
    'bash +lc "git commit"',             # clustered, plus sign
    # A command string that references positional params can EXECUTE the
    # interpreter's own arguments — they are not inert. Verified against bash:
    #   bash -c '$0' 'echo RAN'           -> RAN
    #   bash -c 'eval "$1"' _ 'echo RAN'  -> RAN
    """bash -c '$0' 'git commit'""",
    """bash -c 'eval "$1"' _ 'git commit'""",
    """bash -c '"$@"' _ 'git commit'""",
    # Other verified routes from a command string to its own arguments. Scanning
    # the whole tail covers these without enumerating them.
    """bash -c 'eval "${!#}"' _ 'git commit'""",
    """bash -c 'eval "$BASH_ARGV"' _ 'git commit'""",
    """zsh -c 'eval "$argv[1]"' _ 'git commit'""",
    # Backslash-newline line continuations. bash removes them during lexing, so
    # all of these run a real commit (verified: `git \<newline>commit -m x` in a
    # script produces a commit). shlex does NOT remove them — it leaves a literal
    # newline glued to the next word ('\ncommit'), which matched no subcommand,
    # so every one of these evaded the commit/PR/merge gates.
    'git \\\ncommit -m x',               # continuation between exe and subcommand
    'git \\\n  commit -m x',             # continuation + leading indent
    'git commit \\\n-m x',               # continuation before a flag
    'git \\\ncommit \\\n-m \\\nx',       # several continuations
    'echo hi && git \\\ncommit -m x',    # continuation in a chained segment
    'bash -c "git \\\ncommit -m x"',     # continuation inside an interpreter payload
    'env FOO="bar" \\\ngit commit -m x',  # continuation after a double-quoted value
    # A continuation can split the `$(` of a substitution or the `-c` of a
    # payload, so stripping must happen BEFORE extraction, not just before
    # segment splitting. Verified: both of these really execute the commit.
    'echo $\\\n(git commit -m x)',       # continuation inside the $( token
    'echo "$\\\n(git commit -m x)"',     # same, inside double quotes
    'bash -\\\nc "git commit -m x"',     # continuation splitting the -c option
    # Nested substitution whose inner `$(` is split by a continuation. Stripping
    # unconditionally (no quote-state machine) rejoins `$(` so the recursive
    # substitution scan still finds the inner commit. Verified: commits in bash.
    'echo "$(echo x ; $\\\n(git commit -m x))"',
    # Process substitutions <(...) / >(...) run their body like $(...). The
    # extractor skipped them, so a commit inside one evaded every gate.
    # Verified: `cat <(git commit)` and `diff <(git commit) <(:)` really commit.
    # `>(...)` runs async (may race the shell exit) — detecting it is the
    # fail-CLOSED direction regardless, since it CAN execute.
    'cat <(git commit -m x)',            # input process substitution
    'diff <(git commit -m x) <(echo)',   # commit in one of two process subs
    'tee >(git commit -m x)',            # output process substitution
    'cat <( git commit )',               # spaced body
    'cat <(echo hi; git commit)',        # multi-command body
    'cat =(git commit -m x)',            # zsh =() process substitution (executes)
    'cat =( git commit )',               # zsh =() spaced body
    'foo; =(git commit -m x)',           # =( at a word boundary after an operator
    '=(git commit -m x)',                # =( at start of command (word boundary)
]

# ── LINE-CONTINUATION FALSE POSITIVES (deliberate, fail-CLOSED — do NOT "fix").
# Backslash-newline is stripped unconditionally, so bash's two literal-data
# exemptions (single-quoted spans, quoted heredoc bodies) get over-joined. That
# text is never executed by bash, so the worst case is the gate OVER-firing on
# inert data — the safe direction. Modeling the exemptions needs a full shell
# parser whose failure mode is fail-OPEN. Pinned so the tradeoff stays visible.
#   cat <<'EOF' / git \<newline>commit / EOF   heredoc data misread as a commit
CONTINUATION_ACCEPTED_FP = [
    # Process substitutions are scanned unconditionally, so a <()/>() body inside
    # double quotes — which bash/zsh keep literal — over-fires. Fail-CLOSED and
    # deliberate: a double-quote state machine to suppress it instead fails OPEN
    # on an unbalanced quote in a comment (verified). Pinned so the tradeoff shows.
    'echo "<(git commit)"',
    'echo ">(git commit)"',
]

# ── KNOWN PRE-EXISTING MISS (fail-OPEN, NOT introduced here). `_command_substitutions`
# tracks single quotes only, so an apostrophe in an inner double-quoted value (or an
# unbalanced quote in a comment/heredoc) can suppress a later $()/process sub. This
# exists on main today for $() and is a substitution-parser limitation distinct from
# process-sub coverage; left for its own change rather than a double-quote state
# machine (which trades this fail-OPEN for a worse one). Pinned asserting the current
# False so a real fix flips it loudly.
COMMIT_KNOWN_MISS = [
    'echo "$(echo "it\'s" ; $(git commit -m e))"',
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
    # Continuation-adjacent forms bash does NOT continue. Pinned so the removal
    # above cannot over-reach into strings the shell keeps literal.
    'echo git \\\ncommit',               # prose across a continuation
    'echo "git \\\ncommit"',             # continuation inside a quoted string
    "echo 'git \\\ncommit'",             # single quotes: bash keeps both chars
    'echo a\\\\\ngit log',               # escaped backslash, then a REAL newline
    # Plain redirects are NOT process substitutions — the '>'/'<' must be
    # followed immediately by '(' to be a process sub. These must stay allowed.
    'echo git commit > out.txt',         # redirect to a file, not >(...)
    '2>/dev/null git log',               # fd redirect prefix
    'git log < input.txt',               # input redirect from a file
    # `name=(...)` is an array assignment, not a process substitution — its
    # contents are NOT executed (verified in bash and zsh). The word-boundary
    # guard on =( skips every assignment form.
    'x=(git commit -m x)',               # array assignment
    'arr=(a b c)',                       # array assignment, no command
    'foo_bar=(git commit)',              # identifier with '_' before =
    'x+=(git commit -m x)',              # append assignment ('+' before =)
    'a[0]=(git commit -m x)',            # subscripted assignment (']' before =)
    # `name=(...)` in ARGUMENT position (after a command word) is NOT a process
    # substitution and does NOT execute — verified inert in real zsh AND bash.
    # The alnum-before-'=' skip is therefore correct here, not a fail-open.
    'cat x=(git commit -m x)',           # verified inert in zsh + bash
    'echo foo x=(git commit -m x)',      # verified inert in zsh + bash
]

# ── ACCEPTED FALSE POSITIVES (deliberate — do NOT "fix" by adding an arity
# model; see _interpreter_payloads). These DO fire the gate even though bash
# executes no commit. Suppressing them needs per-shell option arity, whose
# failure mode is fail-OPEN — strictly worse than an over-firing gate.
#   bash script.sh -lc "git commit"        -lc is script.sh's own argument
#   bash deploy.sh -c "git commit -m x"    same class
#   bash -c "echo ok" placeholder "git commit"   trailing args are $0/$N
# Asserted as-is so the behavior is pinned and a future change is visible.
COMMIT_ACCEPTED_FP = [
    'bash script.sh -lc "git commit"',
    'bash deploy.sh -c "git commit -m x"',
    'bash -c "echo ok" placeholder "git commit"',
]

for c in COMMIT_YES:
    check(f"commit+ {c!r}", g.git_commit(c)[0], True)
for c in COMMIT_NO:
    check(f"commit- {c!r}", g.git_commit(c)[0], False)
for c in COMMIT_ACCEPTED_FP:
    check(f"commit~ (accepted FP) {c!r}", g.git_commit(c)[0], True)
for c in CONTINUATION_ACCEPTED_FP:
    check(f"commit~ (continuation FP) {c!r}", g.git_commit(c)[0], True)
for c in COMMIT_KNOWN_MISS:
    check(f"commit~ (known pre-existing miss) {c!r}", g.git_commit(c)[0], False)

# ── OPERAND-TAKING WRAPPERS (#641) ───────────────────────────────────
# `timeout`, `flock` and `ionice` were absent from _WRAPPERS, so a
# commit or merge behind any of them reached NO gate at all — a fail-OPEN in
# three fail-CLOSED gates (pre-commit, pre-PR, pre-merge), not a stall.
#
# Of these, only `timeout` and `flock` take a non-option OPERAND before the
# command word (a duration, a lockfile), so adding their name is not enough:
# the walk has to get PAST the operand. It does that by skipping bare
# non-target words while an operand-taking wrapper is open — never by counting
# them. `_OPERAND_WRAPPERS` is a membership set with no arity data, which is
# why `timeout -s TERM 5 …` resolves without anyone teaching the walk what
# `-s` means. (`ionice` is recognised too but takes only options — see
# `_SCOPED_WRAPPERS` below.)
#
# `xargs` is NOT in that set — see the known-miss block below for why modelling
# it lexically produced wrong answers rather than merely incomplete ones.
# Do NOT "fix" any row below by introducing per-wrapper offsets; that ladder is
# the #587/#593 non-goal and ADR 0032:368 declines it for the same family.
WRAPPER_OPERAND_LIVE = [
    'timeout 5 git commit -m x',
    'timeout -s TERM 5 git commit -m x',      # option + its value + duration
    'timeout --signal=TERM 5 git commit',     # attached option value
    'timeout 5.5s git commit -m x',           # non-integer duration
    'flock /tmp/l git commit -m x',
    'flock -x /tmp/l git commit -m x',
    'flock -w 10 /tmp/l git commit -m x',     # two operands before the command
    'ionice -c3 git commit -m x',
    '/usr/bin/timeout 5 git commit',          # absolute-path wrapper
    'timeout 5 nice -n 5 git commit',         # plain wrapper nested inside
    'nice -n 5 timeout 5 git commit',         # …and the other order
    'timeout 5 git -C /other commit -m x',    # -C behind the wrapper
    'cd /other && timeout 5 git commit -m x',
    "sudo timeout 5 git commit -m x",
]
for c in WRAPPER_OPERAND_LIVE:
    check(f"wrap641+ {c!r}", g.git_commit(c)[0], True)

WRAPPER_OPERAND_NO = [
    'timeout 30 git fetch origin',            # real git, different subcommand
    'timeout 5 npm test',                     # no target at all
    'flock /tmp/l ls',
    'xargs -0 rm -f',
    'env FOO git commit -m x',                # env is NOT operand-taking: bash
                                              # execs `FOO` and the commit never
                                              # runs, so detecting it would be a
                                              # false positive, not a catch
    "grep 'timeout 5 git commit' notes.txt",  # prose in a quoted operand
    "echo 'timeout 5 git commit'",
    'printf timeout 5 git commit',            # printf is not a wrapper
]
for c in WRAPPER_OPERAND_NO:
    check(f"wrap641- {c!r}", g.git_commit(c)[0], False)

# Accepted over-block, fail-CLOSED direction and deliberately pinned: a bare
# word inside an operand-taking wrapper is indistinguishable from its operand,
# so a commit spelled as data behind one reads as live. Priced at zero on a
# 31,381-command corpus — the shape does not occur.
WRAPPER_OPERAND_ACCEPTED_FP = [
    'timeout 5 echo git commit',
]
for c in WRAPPER_OPERAND_ACCEPTED_FP:
    check(f"wrap641~ (accepted FP) {c!r}", g.git_commit(c)[0], True)

# gh side: the pre-merge gate shares the walk, and the PR NUMBER must survive.
check("wrap641+ gh merge behind timeout",
      g.gh_pr('timeout 5 gh pr merge 1', 'merge')[0], True)
check("wrap641+ gh merge behind flock",
      g.gh_pr('flock /tmp/l gh pr merge 1', 'merge')[0], True)
check("wrap641+ gh merge PR number survives the wrapper",
      g.gh_pr('timeout 5 gh pr merge 7', 'merge')[2], '7')

# ── #593 bar 1: NO MIS-SCOPING ───────────────────────────────────────
# A detection whose target_dir / -C authority differs from the untorn command
# is strictly worse than the miss it replaces (#593). Assert the WHOLE TUPLE,
# never just the boolean — a boolean-only test passes on a mis-scoped hit.
SCOPE_PAIRS = [
    ('cd /other && timeout 5 git commit -m x', 'cd /other && git commit -m x'),
    ('cd /other && flock /tmp/l git commit -m x', 'cd /other && git commit -m x'),
    ('timeout 5 git -C /other commit -m x', 'git -C /other commit -m x'),
    ('flock /tmp/l git -C /other commit -m x', 'git -C /other commit -m x'),
]
for wrapped, plain in SCOPE_PAIRS:
    check(f"wrap641= scope {wrapped!r}", g.git_commit(wrapped), g.git_commit(plain))
check("wrap641= scope gh merge behind a wrapper",
      g.gh_pr('cd /other && timeout 5 gh pr merge 7', 'merge'),
      g.gh_pr('cd /other && gh pr merge 7', 'merge'))

# The operand walk is scoped to the git/gh callers. Handing it to the
# cd/pushd/popd caller would report a directory change that a SUBPROCESS
# wrapper never performed in this shell — a mis-scope, not a catch.
check("wrap641= timeout does not manufacture a cd",
      g.effective_cwd('timeout 5 cd /other', ''), ('', True))
check("wrap641= flock does not manufacture a cd",
      g.effective_cwd('flock /tmp/l cd /other', ''), ('', True))

# Nested route: payload extraction re-runs this same walk, so the fix reaches
# an interpreter payload for free. Pinned so a future refactor cannot quietly
# lose it.
check("wrap641+ nested bash -c payload",
      g.git_commit("bash -c 'timeout 5 git commit -m x'")[0], True)
check("wrap641+ nested sh -c payload",
      g.git_commit('sh -c "flock /tmp/l git commit -m x"')[0], True)
check("wrap641+ nested gh merge payload",
      g.gh_pr("bash -c 'timeout 5 gh pr merge 1'", 'merge')[0], True)

# ...and the OTHER ordering, which is a different code path and was missed by
# the first draft of this change: the wrapper sits OUTSIDE the interpreter, so
# it is INTERPRETER DISCOVERY that has to walk the operand, not the git/gh scan.
# `timeout 5 bash -c "git commit"` stopped the discovery walk on `5`, argv[0]
# was not an interpreter, and the payload was never extracted (verified: it
# runs). Note the asymmetry that hid it — `xargs -0 bash -c …` was ALREADY
# detected, because `-0` is an option and leaves `bash` in command position;
# only the operand-bearing spellings broke.
WRAPPER_OUTSIDE_INTERPRETER = [
    'timeout 5 bash -c "git commit -m x"',
    'timeout -s TERM 5 bash -c "git commit -m x"',
    'flock /tmp/l bash -c "git commit -m x"',
    'flock -w 10 /tmp/l sh -c "git commit -m x"',
    'ionice -c3 bash -c "git commit -m x"',
]
for c in WRAPPER_OUTSIDE_INTERPRETER:
    check(f"wrap641+ outside-interp {c!r}", g.git_commit(c)[0], True)
check("wrap641+ outside-interp gh merge",
      g.gh_pr('timeout 5 bash -c "gh pr merge 1"', 'merge')[0], True)
check("wrap641+ outside-interp gh merge via sh",
      g.gh_pr('flock /tmp/l sh -c "gh pr merge 1"', 'merge')[0], True)

# ── TARGET-SHAPED OPERANDS ───────────────────────────────────────────
# The operand a wrapper takes can itself look like the executable, and the
# `not is_target` guard that protects a real command word then stops the walk on
# it: `flock /tmp/git git commit -m x` produced argv ['/tmp/git','git','commit',…]
# so the SUBCOMMAND read as `git`, not `commit`, and the commit ran unseen. Same
# shape for `xargs -E git` (the EOF-marker operand is protected from the
# option-argument branch by its own `not is_target` guard, so it lands here too).
#
# Not a regression — main misses all of these as well — but it was this change's
# own blind spot, and an operand an attacker names is a poor place to have one.
# The rule is local and arity-free: while an operand wrapper is open, a
# target-shaped token IMMEDIATELY FOLLOWED by another target-shaped token is the
# operand. Do NOT "fix" a row here by teaching the walk which wrappers take
# paths.
TARGET_SHAPED_OPERAND = [
    'flock /tmp/git git commit -m x',
    'flock git git commit -m x',              # bare, no directory
    'flock -x /tmp/git git commit -m x',
    'flock -w 10 /tmp/git git commit -m x',
    'timeout 5 /usr/bin/git git commit -m x',  # absolute-path operand
]
for c in TARGET_SHAPED_OPERAND:
    check(f"wrap641+ shaped-operand {c!r}", g.git_commit(c)[0], True)
check("wrap641+ shaped-operand gh lockfile",
      g.gh_pr('flock /tmp/gh gh pr merge 1', 'merge')[0], True)
check("wrap641+ shaped-operand gh keeps PR number",
      g.gh_pr('flock /tmp/gh gh pr merge 9', 'merge')[2], '9')

# The skip fires ONLY on a run of target-shaped tokens, so it can never swallow
# a real command word. These pin that boundary.
check("wrap641- shaped-operand does not eat a lone command word",
      g.git_commit('timeout 5 git commit -m git')[0], True)
check("wrap641- a later target token is not a run",
      g.git_commit('timeout 5 git log -- git')[0], False)
check("wrap641- outside an operand wrapper nothing changes",
      g.git_commit('git git commit -m x')[0], False)
check("wrap641= shaped-operand scope matches untorn",
      g.git_commit('cd /other && flock /tmp/git git commit -m x'),
      g.git_commit('cd /other && git commit -m x'))

# ── ...BUT NOT WITH ANYTHING BETWEEN THEM (documented miss) ───────────
# Insert ANY valid token between the target-shaped operand and the executable —
# a second wrapper, a redirection, `env` — and the adjacency rule no longer
# fires. These are MISSES, asserted as such, and they are misses on main too.
#
# A candidate-window fallback that covered them was built and REVERTED. It
# worked, but it was rung N+1: it generated a fresh defect in each of three
# consecutive review rounds — a repo-override scan that had not kept up, an
# option VALUE spelled like a wrapper arming it, an ordinary `git log -1 -- git
# commit` reported as a commit — and #593 non-goal 4 says to prefer the
# documented miss over that ladder. The reverted approach is described in the
# PR body for whoever picks this up.
#
# Verified EXECUTING on this host in the forms whose binaries exist:
#   timeout 5 nice -n 5 echo …   -> runs
#   timeout 5 >/tmp/f echo …     -> runs (redirection between wrapper and cmd)
# `flock` is absent on this host; its operand grammar is documented and the
# parser does not depend on the binary existing.
OPERAND_THEN_ANYTHING_MISS = [
    'flock /tmp/git nice -n 5 git commit -m x',    # wrapper between
    'flock /tmp/git env git commit -m x',          # another wrapper
    'flock /tmp/git >/tmp/o git commit -m x',      # redirection between
    'flock /tmp/git 2>/dev/null git commit -m x',  # fd redirection
    'timeout 5 /tmp/git nice -n 5 git commit -m x',
]
for c in OPERAND_THEN_ANYTHING_MISS:
    check(f"wrap641~ (miss) operand-then-any {c!r}", g.git_commit(c)[0], False)
check("wrap641~ (miss) operand-then-any gh",
      g.gh_pr('flock /tmp/gh nice -n 5 gh pr merge 1', 'merge')[0], False)

# The ordinary spellings keep REAL scope — no stall, no guessed directory.
check("wrap641= ordinary spelling keeps REAL scope",
      g.git_commit('cd /other && timeout 5 git commit -m x')[1], '/other')
check("wrap641= ordinary spelling is not a torn stall",
      g.git_commit('cd /other && timeout 5 git commit -m x',
                   with_untrusted_cd=True)[3] == g._TORN_SCOPE, False)

# The operand rule needs an `_OPERAND_WRAPPERS` name in the PREFIX to arm at
# all. Without one the walk stops on the first bare word, so an ordinary
# argument VALUE is never read as a command word. These two pin that boundary:
# `echo git commit` never latches an operand wrapper, and `nice` is a plain
# `_WRAPPERS` member (not `_OPERAND_WRAPPERS`), so `/tmp/git` ends the walk.
check("wrap641- fallback needs an operand wrapper",
      g.git_commit('echo git commit')[0], False)
check("wrap641- fallback does not fire behind a plain wrapper",
      g.git_commit('nice -n 5 /tmp/git git commit -m x')[0], False)

# ── KNOWN MISSES, pinned rather than chased (ADR 0006 residual class) ──
# No token scan can reach either of these, and both are asserted as MISSES so a
# future change that closes them is visible rather than silent.
#
#   `printf git | xargs -I{} {} commit -m x`  — the command word is `{}` and the
#   executable arrives on STDIN. Verified to really run `git commit`. This is
#   the run-time-assembled-name class ADR 0006 accepts; closing it needs data-
#   flow, not parsing.
#
#   `flock /tmp/l -c "git commit"` — flock's OWN -c hands a string to a shell
#   without naming an interpreter, so discovery has no target to stop on. Same
#   shape as `env -S`, which needed its own extractor; this one has not been
#   reported and is not built here.
WRAPPER_KNOWN_MISS = [
    'printf git | xargs -I{} {} commit -m x',
    'echo git | xargs -n1 -I@ @ commit -m x',
    'flock /tmp/l -c "git commit -m x"',
    # `xargs` is not modelled as a wrapper AT ALL, so even its literal spellings
    # are misses. That is deliberate and is the narrower of two bad options.
    # xargs BUILDS a command line: argv comes from stdin and the result may run
    # zero or many times, so modelling it lexically produced answers that were
    # WRONG rather than merely incomplete —
    #   printf '%s\n' --repo other/repo | xargs gh pr merge 1
    #       reported merge=True with override=False, i.e. the gate would have
    #       validated the CURRENT repo while gh merged another;
    #   xargs -n1 gh pr merge
    #       reported gh_pr_count=1 for a command that can perform several, which
    #       is the number the pre-merge gate reads to refuse a multi-PR merge.
    # Catching `xargs -0 git commit` while `printf commit | xargs git` sails past
    # buys one spelling at the price of a confident wrong answer on others.
    'xargs -0 git commit -m x',
    'xargs -I{} git commit -m x',
    'xargs -0 bash -c "git commit -m x"',
    'printf 1 | xargs -E git git commit -m x',
    'printf commit | xargs git',
]
for c in WRAPPER_KNOWN_MISS:
    check(f"wrap641~ (known miss, ADR 0006) {c!r}", g.git_commit(c)[0], False)
check("wrap641~ (known miss) assembled gh via xargs",
      g.gh_pr('printf gh | xargs -I{} {} pr merge 1', 'merge')[0], False)
check("wrap641~ (known miss) literal gh behind xargs",
      g.gh_pr('xargs -0 gh pr merge 1', 'merge')[0], False)
# The reason xargs is excluded, asserted rather than only argued: a wrong ANSWER
# is worse than a miss. If a future change models xargs lexically, these two are
# the rows that should force it to answer for the repo-override and count paths.
check("wrap641~ xargs stdin cannot supply a repo override",
      g.gh_pr_repo_override(
          "printf '%s\\n' --repo other/repo | xargs gh pr merge 1", 'merge'),
      False)
check("wrap641~ xargs repeat-invocation is not counted as one",
      g.gh_pr_count('xargs -n1 gh pr merge', 'merge'), 0)

# An option VALUE spelled like a wrapper is not a wrapper. The fallback's gate
# comes from the walk's own report, not from a token scan that cannot tell the
# two apart — `env -u timeout echo git commit` runs only `echo`.
OPTION_VALUE_NAMED_LIKE_WRAPPER = [
    'env -u timeout echo git commit',
    'sudo -u timeout echo git commit',
    'env -u flock echo git commit',
]
for c in OPTION_VALUE_NAMED_LIKE_WRAPPER:
    check(f"wrap641- option-value {c!r}", g.git_commit(c)[0], False)
check("wrap641- option-value gh",
      g.gh_pr('env -u timeout echo gh pr merge 1', 'merge')[0], False)

# A REAL executable with a non-commit subcommand ends the matter. Trailing words
# that merely spell `git commit` are arguments, not another invocation — the
# reverted fallback read them as one and reported a commit for a `git log`.
check("wrap641- git log with trailing commit words",
      g.git_commit('timeout 5 git log -1 -- git commit')[0], False)
check("wrap641- gh issue view with trailing merge words",
      g.gh_pr('timeout 5 gh issue view gh pr merge 1', 'merge')[0], False)

# Structural: the set carries names only. If a future change gives it offsets,
# counts, or per-flag knowledge, this is the assertion that should fail first.
check("wrap641= _OPERAND_WRAPPERS is a bare name set",
      sorted(g._OPERAND_WRAPPERS), ['flock', 'timeout'])
check("wrap641= _SCOPED_WRAPPERS is a bare name set",
      sorted(g._SCOPED_WRAPPERS), ['ionice'])
check("wrap641= the two wrapper sets are disjoint",
      sorted(g._OPERAND_WRAPPERS & g._SCOPED_WRAPPERS), [])

# ── A WRAPPER WITH NO BARE OPERAND MUST NOT LATCH THE OPERAND RULE ────
# `ionice` takes only options (`-c3`, `-c 3`), never a bare operand before the
# command. Latching the operand rule for it let the walk step over an ordinary
# command word and land on an ARGUMENT, so `ionice echo git commit` — which only
# prints — read as a commit. That is not the `timeout 5 echo git commit`
# ambiguity (there, the skipped word really could be the duration); it was
# simply the wrong grammar, so `ionice` lives in `_SCOPED_WRAPPERS` instead:
# recognised as a wrapper, but it does not open an operand run.
SCOPED_WRAPPER_NO_OPERAND = [
    'ionice echo git commit',
    'ionice -c 3 echo git commit',       # detached option value
    'ionice echo gh pr merge 1',
]
for c in SCOPED_WRAPPER_NO_OPERAND:
    check(f"wrap641- scoped-wrapper {c!r}", g.git_commit(c)[0], False)
check("wrap641- scoped-wrapper gh",
      g.gh_pr('ionice echo gh pr merge 1', 'merge')[0], False)
# ...while its DIRECT forms still resolve, which is the point of listing it.
for c in ['ionice git commit -m x', 'ionice -c3 git commit -m x']:
    check(f"wrap641+ scoped-wrapper direct {c!r}", g.git_commit(c)[0], True)
check("wrap641+ scoped-wrapper direct gh",
      g.gh_pr('ionice -c3 gh pr merge 1', 'merge')[0], True)

# `ionice -c3 echo git commit` is STILL a detection, and that is the file's
# PRE-EXISTING attached-option ambiguity, not this change's operand rule: an
# option whose value is attached leaves `prev_dash` set, so the next bare word is
# read as the option's argument and the walk continues past it. Every wrapper
# already in _WRAPPERS behaves identically on main — asserted here so the class
# is visible and `ionice` is not mistaken for a new defect.
for c in ['sudo -n echo git commit',
          'nice -n5 echo git commit',
          'stdbuf -oL echo git commit',
          'env -i echo git commit']:
    check(f"wrap641~ (pre-existing attached-option FP) {c!r}",
          g.git_commit(c)[0], True)
check("wrap641~ ionice joins that same pre-existing class",
      g.git_commit('ionice -c3 echo git commit')[0], True)

# ── ATTACHED SCOPED-WRAPPER OPTION FOLLOWED BY AN OPERAND WRAPPER ─────
# `ionice -c3` is an attached option -- self-contained, no separate value --
# but the generic option-argument rule cannot tell that from a DETACHED option
# awaiting its value, and read `timeout`/`flock` as `-c3`'s argument. That
# skipped the wrapper branch entirely, so `saw_operand_wrap` never latched and
# the walk broke on the wrapper's own operand (`5`, `/tmp/l`) -- a fail-OPEN
# in three fail-CLOSED gates (cubic finding, PR #650): `argv[0]` came back as
# the operand itself, never `git`/`gh`.
SCOPED_ATTACHED_THEN_OPERAND_MISS = [
    'ionice -c3 timeout 5 git commit -m x',
    'ionice -c3 flock /tmp/l git commit -m x',
]
for c in SCOPED_ATTACHED_THEN_OPERAND_MISS:
    check(f"wrap641~ (miss) scoped-attached-then-operand {c!r}",
          g.git_commit(c)[0], False)
check("wrap641~ (miss) scoped-attached-then-operand gh",
      g.gh_pr('ionice -c3 timeout 5 gh pr merge 1', 'merge')[0], False)

# The fix for the rows above was IMPLEMENTED AND REVERTED in review (PR #650),
# and this is the row that killed it. Excluding wrapper-named tokens from the
# option-argument branch rests on "a scoped wrapper takes options only, so
# nothing after its dash-option can be a detached VALUE" — which is false:
# `ionice -c 3` takes exactly that. With the exclusion in place,
# `ionice -c timeout echo git commit` — where `timeout` IS `-c`'s value and only
# `echo` runs — reported a commit. That is a wrong ANSWER traded for a miss, and
# separating the two needs ionice's option arity: the ladder #587/#593 exist to
# stop climbing. Do NOT re-attempt without an arity model.
check("wrap641- detached scoped-option value is not a wrapper",
      g.git_commit('ionice -c timeout echo git commit')[0], False)
check("wrap641- detached scoped-option value, gh",
      g.gh_pr('ionice -c timeout echo gh pr merge 1', 'merge')[0], False)
# The detached spelling where the value is NOT wrapper-shaped still resolves —
# `-c` takes `3`, prev_dash clears, and `timeout` is then a real wrapper.
check("wrap641+ detached scoped option then operand wrapper",
      g.git_commit('ionice -c 3 timeout 5 git commit -m x')[0], True)
# A wrapper-shaped word genuinely spelled as an OPTION'S VALUE must stay a value.
for c in ['env -u timeout echo git commit',
          'sudo -u timeout echo git commit',
          'env -u flock echo git commit']:
    check(f"wrap641- option-value stays a value {c!r}", g.git_commit(c)[0], False)

# A REDIRECTION-SHAPED TOKEN IN THE PREFIX FAILS CLOSED, and the position
# question is not asked. `_tokenize` drops quote provenance, so after
# tokenization a quoted `>` handed to an option and a real redirection operator
# are the SAME token. Both orderings were built and both mis-scoped a real merge:
#   redirection-first      `env -u ">" GH_REPO=other/repo gh pr merge 1` read the
#                          QUOTED `>` as an operator and swallowed the assignment
#                          as its filename.
#   option-argument-first  `env -i > /dev/null env GH_REPO=other/repo gh pr
#                          merge 1` read a REAL detached redirection as `-i`'s
#                          value, then returned False on `/dev/null`.
# Each reported "no override" for a merge that really does retarget another repo
# — the wrong-repo validation of #593 bar 1, strictly worse than a stall. Both
# collapse into one fail-closed branch (Codex findings, PR #650).
for c in ['env -u ">" GH_REPO=other/repo gh pr merge 1',
          'env -u "2>" GH_REPO=other/repo gh pr merge 1',
          'env -i > /dev/null env GH_REPO=other/repo gh pr merge 1',
          'env -i 2> /dev/null env GH_REPO=other/repo gh pr merge 1']:
    check(f"wrap641= redirection-shaped prefix token fails closed {c!r}",
          g.gh_pr_repo_override(c, 'merge'), True)
# ...and real leading redirections still reach the selector.
for c in ['>/dev/null timeout 5 env GH_REPO=o/r gh pr merge 1',
          '> /dev/null env GH_REPO=o/r gh pr merge 1']:
    check(f"wrap641= leading redirection still scanned {c!r}",
          g.gh_pr_repo_override(c, 'merge'), True)
# ACCEPTED OVER-REPORT, pinned so the trade stays visible. A merge with NO
# selector at all now reports one when a redirection stands BEFORE the command
# word. That is the price of not asking the position question, and it is the
# direction this file always takes — a visible stall beats a silent wrong-repo
# validation.
#
# PRICED, not assumed: two-way diff against origin/main over 32,617 recorded
# agent commands = 4 changed, all this branch. The ORDINARY spelling is
# unaffected (the row below pins it), so the flips are not live redirections in
# front of a real command — every one traced to a heredoc OPENER left in a
# continuation-split segment, or to literal prose in a heredoc PR body
# (`cd <path> && <cmd>`, where `<cmd>` reads as a `<` redirection). That is the
# #639 family, widened here rather than introduced. Measured live cost: one
# `gh pr create` out of 257 recorded.
for c in ['>/dev/null gh pr merge 1',
          '> /dev/null gh pr merge 1']:
    check(f"wrap641~ (accepted) redirected merge, no selector {c!r}",
          g.gh_pr_repo_override(c, 'merge'), True)
check("wrap641- trailing redirection is not a prefix",
      g.gh_pr_repo_override('gh pr merge 1 >/dev/null', 'merge'), False)

check("wrap641= xargs is NOT modelled as a wrapper",
      'xargs' in (g._OPERAND_WRAPPERS | g._SCOPED_WRAPPERS | g._WRAPPERS), False)
# DISJOINT from _WRAPPERS, deliberately. _WRAPPERS is read by the cd/pushd/popd
# walk and two other scans, so putting these names in it leaked outside this
# change's git/gh-only scope: `ionice -c3 echo cd /other; git commit` began
# reporting `/other` as untrusted_cd (main reports ''), a new false stall for a
# subprocess that cannot change the parent shell's directory. If a future change
# merges the sets, one of these two rows is the one that should fail.
check("wrap641= operand wrappers stay OUT of _WRAPPERS",
      sorted(g._OPERAND_WRAPPERS & g._WRAPPERS), [])
check("wrap641= scoped wrappers stay OUT of _WRAPPERS",
      sorted(g._SCOPED_WRAPPERS & g._WRAPPERS), [])
check("wrap641- subprocess wrapper manufactures no untrusted cd",
      g.git_commit('ionice -c3 echo cd /other; git commit -m x',
                   with_untrusted_cd=True)[3], '')
check("wrap641- xargs manufactures no untrusted cd",
      g.git_commit('printf x | xargs -0 echo cd /other; git commit -m x',
                   with_untrusted_cd=True)[3], '')

# ── THE REPO-OVERRIDE SELECTOR MUST KEEP UP WITH THE WALK ────────────
# Detecting a merge the override scan cannot see is WORSE than not detecting it:
# the gate then validates the CURRENT repo's marker while gh merges another.
# Before this row, `timeout 5 env GH_REPO=other/repo gh pr merge 1` reported
# merge=True / override=False — a mis-scope this change itself introduced by
# teaching one walk about operand wrappers and not the other (#593 bar 1). The
# scan now reports an operand-wrapper prefix UNRESOLVABLE and fails CLOSED
# instead (see the fail-closed rows below), so the two walks cannot drift
# apart again by omission — no bound is derived at all.
OVERRIDE_SEEN = [
    'timeout 5 env GH_REPO=other/repo gh pr merge 1',
    'flock /tmp/l env GH_REPO=other/repo gh pr merge 1',
    'ionice -c3 env GH_HOST=example.com gh pr merge 1',
    'env GH_REPO=other/repo gh pr merge 1',          # unwrapped, unchanged
    # #641 follow-up: `--` is an option TERMINATOR, not an option whose value
    # follows. Treating it as an ordinary dash option let the NEXT token be
    # swallowed as `--`'s "argument", so this never reached the operand-
    # wrapper fail-closed arm and fell through to `return False` on `5` --
    # reporting NO override for a merge that really does retarget
    # `other/repo` (Codex finding, PR #650).
    'env -- timeout 5 env GH_REPO=other/repo gh pr merge 1',
    # A leading redirection is punctuation, not a command word -- fused
    # (`>/dev/null`) and detached (`> /dev/null`) forms both left the scan
    # falling through to `return False` on the operator itself before this
    # fix, reporting NO override for a merge that really does retarget
    # `other/repo` (cubic-dev-ai + Codex finding, PR #650).
    '>/dev/null timeout 5 env GH_REPO=other/repo gh pr merge 1',
    '> /dev/null timeout 5 env GH_REPO=other/repo gh pr merge 1',
]
for c in OVERRIDE_SEEN:
    check(f"wrap641= override seen {c!r}", g.gh_pr_repo_override(c, 'merge'), True)
# ACCEPTED OVER-REPORT, and the reason the whole family is here. This scan has
# no target to stop on, so it cannot step over `timeout 5` / `flock /tmp/l` the
# way the command-word walk can. Three drafts tried to DERIVE a bound from
# `_command_argv` and each was defeated one spelling at a time — a target-shaped
# lockfile that stopped it early, a segment with no `gh` whose bound ran to
# end-of-segment, then a nested `bash -c "gh pr merge 1"` with no `gh` token in
# the outer segment to bound with. Answering "where does the prefix end behind
# an operand wrapper" is the position question the walk itself declined; so this
# reports the prefix UNRESOLVABLE and fails CLOSED.
#
# Consequence, asserted so it stays deliberate: any segment carrying an operand
# wrapper reports a possible override, and the gate stalls on a command it could
# once have scoped. The alternative is a SILENT wrong-repo validation — the gate
# anchoring the current repo while gh merges another — which is strictly worse.
# Priced on the corpus in the PR body.
OPERAND_WRAPPER_UNRESOLVABLE = [
    'timeout 5 gh pr merge 1',
    'timeout 5 gh pr merge 1 --body "GH_REPO=other/repo"',
    'timeout 5 echo GH_REPO=other/repo; gh pr merge 1',
    'flock GH_HOST=example.com gh pr merge 1',
    # the one that matters: nested, so the outer segment has no `gh` at all
    'timeout 5 env GH_REPO=other/repo bash -c "gh pr merge 1"',
]
for c in OPERAND_WRAPPER_UNRESOLVABLE:
    check(f"wrap641~ (fail-closed) unresolvable prefix {c!r}",
          g.gh_pr_repo_override(c, 'merge'), True)
# A target-shaped lockfile is why the derived-bound drafts failed in the first
# place: a bound that stopped on it ended early and the override went unseen
# while `_iter_gh` read the merge behind it. The fail-closed arm above covers
# this shape without deriving a bound at all.
check("wrap641= override seen behind a target-shaped lockfile",
      g.gh_pr_repo_override(
          'flock /tmp/git env GH_REPO=other/repo gh pr merge 1', 'merge'), True)
# WITHOUT an operand wrapper the scan is unchanged from before this PR. These
# pin that the fail-closed rule is scoped to the unresolvable case and has not
# become a blanket over-report.
UNWRAPPED_SELECTOR_UNCHANGED = [
    ('env GH_REPO=other/repo gh pr merge 1', True),
    ('gh pr merge 1', False),
    ('gh pr merge 1 --body "GH_REPO=o/r"', False),
    ('echo GH_REPO=o/r; gh pr merge 1', False),
    ('nice -n 5 gh pr merge 1', False),
]
for c, want in UNWRAPPED_SELECTOR_UNCHANGED:
    check(f"wrap641= unwrapped selector {c!r}",
          g.gh_pr_repo_override(c, 'merge'), want)

# ── COMPOUND-COMMAND KEYWORDS (fail-OPEN) ────────────────────────────
# Segment splitting cuts on ';', so a compound keyword lands at the head of the
# segment and USED TO BE READ AS THE COMMAND WORD — hiding the real command from
# every gate. Each of these was verified against real bash (stub on PATH) to
# actually run the command, and each was missed before.
KEYWORD_LIVE = [
    'if true; then git commit -m x; fi',
    'if git commit -m x; then :; fi',
    'for f in a; do git commit -m x; done',
    'while :; do git commit -m x; done',
    'until git commit -m x; do :; done',
    'if false; then :; else git commit -m x; fi',
    'if false; then :; elif git commit -m x; then :; fi',
    'case x in x) git commit -m x;; esac',
    'case x in (x) git commit -m x;; esac',      # optional leading '('
    'case x in a) :;; b) git commit -m x;; esac',  # later branch
    "case 'a(b' in x) :;; a\\(b) git commit;; esac",  # label containing '('
    'case "$(printf x)" in x) git commit;; esac',  # subject itself ends in ')'
    'coproc git commit -m x',
    'coproc NAMED { git commit -m x; }',
    "coproc bash -c 'git commit -m x'",           # UNNAMED: next token is the cmd
]
for c in KEYWORD_LIVE:
    check(f"keyword+ {c!r}", g.git_commit(c)[0], True)
# 'in' must NOT be stripped — its operand is a list item, not a command.
check("keyword- for-list operand is not a command",
      g.git_commit('for x in git; do echo "$x"; done')[0], False)
# A `for`/`select` loop VARIABLE named after a wrapper was walked as if it
# OPENED that wrapper, landing on the loop's word list and reporting a commit
# that never runs -- the words are just strings assigned to the variable one
# at a time (a FALSE POSITIVE, i.e. fail-CLOSED: the gate stalls a command that
# performs no commit. The safe direction, not a fail-OPEN -- fixed anyway;
# verified; Codex finding, PR #650).
check("keyword- for-loop variable shaped like a wrapper name is not a wrapper",
      g.git_commit('for timeout in git commit; do echo "$timeout"; done')[0], False)
check("keyword- select-loop variable shaped like a wrapper name is not a wrapper",
      g.git_commit('select flock in git commit; do echo "$flock"; done')[0], False)
# The wrapper name is still detected as a WRAPPER once it stops being the
# declared loop variable -- confirms the skip is positional, not a blanket
# name exemption.
check("keyword+ for-loop body still detects a real wrapper",
      g.git_commit('for timeout in x; do timeout 5 git commit; done')[0], True)

# ── GROUPING BEHIND A KEYWORD (fail-OPEN) ────────────────────────────
# The pre-loop grouping strip only sees a segment's FIRST token, so a group
# opened behind a keyword kept the command word hidden.
GROUPED_LIVE = [
    'if (git commit -m x); then :; fi',
    'if { git commit -m x; }; then :; fi',
    'while (git commit -m x); do :; done',
    'function f { git commit -m x; }; f',
    'f() { git commit -m x; }; f',
    'f(){ git commit -m x; }; f',                 # no space: fuses to one token
    'coproc JOB if git commit -m x; then :; fi',  # named coproc, keyword compound
]
for c in GROUPED_LIVE:
    check(f"grouped+ {c!r}", g.git_commit(c)[0], True)
# The case-label skip must END the subject run, or the branch BODY gets eaten.
# The detection paths are saved by their `not is_target` guard; the target=''
# path (interpreter/eval payload discovery) is not, so it is asserted directly.
check("keyword+ case branch body reached on target='' path",
      g._command_argv('case x in x) bash -c z', ''), ['bash', '-c', 'z'])
check("keyword+ commit inside a case-branch bash -c",
      g.git_commit('case x in x) bash -c "git commit -m x";; esac')[0], True)

# ── ANSI-C $'...' QUOTING (fail-OPEN) ────────────────────────────────
# `\'` is a LITERAL quote inside $'...', so the string ends at the FINAL quote.
# Treating it as an ordinary quote ended the string one quote early, re-opened on
# the real closing quote, and swallowed the next line's live command. All three
# quote scanners (segment splitter, substitution extractor, and their nested
# state) must agree, or the desync resurfaces in whichever one lags.
check("ansi-c+ command after $'...' with escaped quote",
      g.git_commit("printf %s $'a\\'b'\ngit commit -m x")[0], True)
check("ansi-c+ substitution after an ANSI-C string",
      g.git_commit("printf %s $'a\\'b'; echo \"$(git commit -m x)\"")[0], True)
check("ansi-c+ ANSI-C inside a NESTED substitution",
      g.git_commit("echo \"$(printf %s $'a\\')b'; git commit -m x)\"")[0], True)
# An ESCAPED dollar leaves an ORDINARY quote, where \' does not escape — so the
# string ends there and the next line is live. Both directions must hold.
check("ansi-c+ escaped dollar is not ANSI-C",
      g.git_commit("printf %s \\$'x\\'\ngit commit -m x")[0], True)

# ── env -S / --split-string (fail-OPEN) ──────────────────────────────
# `env -S "<whole command>"` packs a command into ONE argument that env then
# splits and executes. The generic wrapper walk consumed it as an ordinary
# option-argument, so the command word inside was never seen at all.
ENV_SPLIT_LIVE = [
    'env -S "git commit -m x"',
    'env --split-string="git commit -m x"',
    'env --split-string "git commit -m x"',
    'env -S"git commit -m x"',                  # BSD/macOS attached form
    'env -iS"git commit -m x"',                 # S later in the cluster
    'command env -S "git commit -m x"',         # behind a launcher prefix
    'X=1 env -S "git commit -m x"',             # behind an assignment
    '/usr/bin/env -S "git commit -m x"',        # absolute path
]
for c in ENV_SPLIT_LIVE:
    check(f"env-S+ {c!r}", g.git_commit(c)[0], True)

# ── QUOTED-DELIMITER HEREDOC BODIES ARE DATA (issue #426) ─────────────
# bash expands nothing inside <<'EOF' / <<"EOF" / <<\EOF, so prose quoting a
# gated command there must not fire. UNQUOTED <<EOF still expands $(...) and is
# still scanned; a body fed to an interpreter still executes and is still
# scanned. Both directions pinned — the exemption must not become a bypass.
HEREDOC_INERT = [
    "cat <<'EOF'\ngit commit -m x\nEOF",
    'cat <<"EOF"\ngit commit -m x\nEOF',
    "cat <<\\EOF\ngit commit -m x\nEOF",
    "cat <<-'EOF'\n\tgit commit -m x\n\tEOF",
    "cat <<'EOF'\ngit \\\ncommit\nEOF",              # was an accepted FP
    # Backticks inside a QUOTED heredoc are literal — bash expands nothing.
    "gh issue comment 426 --body-file - <<'EOF'\nrun `git commit` first\nEOF",
]
HEREDOC_LIVE = [
    "cat <<EOF\n$(git commit -m x)\nEOF",            # unquoted: expands
    "cat <<EOF\n`git commit -m x`\nEOF",             # unquoted: backticks expand
    "bash <<'EOF'\ngit commit -m x\nEOF",            # interpreter executes body
    "sh <<'EOF'\ngit commit -m x\nEOF",
    "cat <<'EOF'\ninert\nEOF\ngit commit -m x",      # live command AFTER the body
    # An opener inside quotes is NOT a heredoc, so nothing is stripped and the
    # following line stays a live command — the exemption cannot be faked into
    # swallowing real text.
    "echo \"<<'EOF'\"\ngit commit -m x\nEOF",
]
for c in HEREDOC_INERT:
    check(f"heredoc- (inert data) {c!r}", g.git_commit(c)[0], False)
for c in HEREDOC_LIVE:
    check(f"heredoc+ (executes) {c!r}", g.git_commit(c)[0], True)

# ── gh_pr_count: merges counted by COMMAND WORD, not substring (#426) ──
COUNT_CASES = [
    ('gh pr merge 5 --squash', 1),
    ('gh pr merge 5 && gh pr merge 6', 2),
    ('bash -c "gh pr merge 1 && gh pr merge 2"', 2),   # wrapper still counted
    ('eval "gh pr merge 1; gh pr merge 2"', 2),
    ('echo "$(gh pr merge 3)"', 1),                     # substitution executes
    ('(gh pr merge 1); (gh pr merge 2)', 2),
    # NOT a false positive — verified against real bash: a backtick inside
    # DOUBLE quotes expands, so this really does run `gh pr merge`. Counting it
    # is correct; the inert form of the same prose is the single-quoted one below.
    ('gh issue close 426 --comment "registered on `gh pr merge`"', 1),
    # ── the issue #426 false positives ──
    ("gh issue close 426 --comment 'registered on `gh pr merge`'", 0),
    ('gh pr comment 5 --body "run gh pr merge then gh pr merge again"', 0),
    ('gh pr view 5 --json title', 0),
    ("gh issue comment 1 --body-file - <<'EOF'\n| gh pr merge | env gh pr merge |\n"
     "| /usr/bin/gh pr merge | gh  pr  merge |\nEOF", 0),
    ('for v in "gh pr merge 1" "gh pr merge 2"; do echo "$v" | ./gate.sh; done', 0),
]
for c, n in COUNT_CASES:
    check(f"merge_count {c!r}", g.gh_pr_count(c, 'merge'), n)

# ── HEREDOC OPENER MUST BE A COMPLETE, REAL HEREDOC (fail-OPEN regression) ──
# Each of these really runs the merge (verified against real bash). Each used to
# count 0: the scanner mistook the construct for a heredoc, then swallowed the
# rest of the command hunting a terminator that never arrives. A construct we
# cannot parse confidently must stay IN the scanned text, not be discarded.
HEREDOC_NOT_INERT = [
    "cat <<<'EOF'\ngh pr merge 1",              # here-string: no terminator
    "cat <<'EOF' | bash\ngh pr merge 1\nEOF",   # consumer is downstream of a pipe
    "cat <<'EO'F\ninert\nEOF\ngh pr merge 1",   # split-quoted delimiter
    "cat <<\\EOF-X\ninert\nEOF-X\ngh pr merge 1",  # escaped delimiter with suffix
]
HEREDOC_NOT_INERT = HEREDOC_NOT_INERT + [
    # `<<''` is a valid EMPTY delimiter, terminated by the first blank line.
    "cat <<''\ninert\n\ngh pr merge 1",
]
for c in HEREDOC_NOT_INERT:
    check(f"heredoc-open {c!r}", g.gh_pr_count(c, 'merge') > 0, True)

# ── A LOOK-ALIKE OPENER MUST NOT SWALLOW LIVE TEXT (fail-OPEN regression) ──
# Heredoc stripping is the one genuinely new discard surface in this change, so
# an opener that turns out NOT to be a real heredoc (no terminator line: inside
# a comment, inside an ANSI-C $'...' string) must leave the text in place. Each
# of these really runs the merge; each counted 0 before.
LOOKALIKE_OPENER = [
    ": # <<'EOF'\ngh pr merge 1",
    # ...and the harder variant, where a later line DOES match the delimiter, so
    # the unterminated-opener fallback does not save it: a comment opens no
    # heredoc at all.
    ": # <<'EOF'\ngh pr merge 1\nEOF",
    "printf %s $'x\\' <<\\EOF y'\ngh pr merge 1",
    "case 'a(b' in x) :;; a\\(b) gh pr merge 1;; esac",
]
for c in LOOKALIKE_OPENER:
    check(f"lookalike+ {c!r}", g.gh_pr_count(c, 'merge'), 1)
# ANSI-C \' is a LITERAL quote, so the string ends at the FINAL quote and the
# next line is a live command — the scanner must not desync by one quote.
check("ansi-c+ commit after $'...' with escaped quote",
      g.git_commit("printf %s $'a\\'b'\ngit commit -m x")[0], True)
# An ESCAPED dollar leaves an ordinary quote, where \' does NOT escape — so the
# string ends at that quote and the next line is live.
check("ansi-c+ escaped dollar is not ANSI-C",
      g.gh_pr_count("printf %s \\$'x\\'\ngh pr merge 1", 'merge'), 1)

# A case SUBJECT may itself end in ')' — the subject/label phases are separated
# by the `in` keyword, not by the first ')'-ending token.
check("case+ subject ending in ) does not end subject phase",
      g.gh_pr_count('case "$(printf x)" in x) gh pr merge 1;; esac', 'merge'), 1)

# `source` / `.` run /dev/stdin, so their heredoc body is NOT inert.
for _exe in ('source', '.'):
    check(f"heredoc+ {_exe} /dev/stdin executes body",
          g.gh_pr_count(f"{_exe} /dev/stdin <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)

# ── COUNT ACCURACY: must match what bash really runs, in BOTH directions ──
# Over-counting is not "safely fail-closed" here: the pre-merge gate rejects
# count>1 as a chained multi-merge, so double-counting one real merge blocks a
# legitimate merge. Under-counting lets a second merge through ungated. The two
# nested/sibling cases pin the boundary — identical chunk TEXT is not proof of a
# duplicate, so this cannot be fixed by de-duping chunks.
COUNT_EXACT = [
    ('echo $(echo $(gh pr merge 1))', 1),           # nested: extracted once
    ('echo $(gh pr merge 1) $(gh pr merge 2)', 2),  # siblings: two real merges
    ('echo $(gh pr merge 1) $(gh pr merge 1)', 2),  # ...even with identical text
    ("printf %s $'a\\'b'; echo \"$(gh pr merge 1)\"", 1),
    ('function f { gh pr merge 1; }; f', 1),
    ('f() { gh pr merge 1; }; f', 1),
]
for c, n in COUNT_EXACT:
    check(f"count-exact {c!r}", g.gh_pr_count(c, 'merge'), n)
check("count-exact git commit in a function body",
      g.git_commit('function f { git commit -m x; }; f')[0], True)
check("count-exact named coproc body",
      g.gh_pr_count('coproc NAMED { gh pr merge 1; }', 'merge'), 1)
# `env -S "<whole command>"` — env splits and executes the packed string.
for _s in ('env -S "gh pr merge 1"', 'env --split-string="gh pr merge 1"'):
    check(f"count-exact {_s!r}", g.gh_pr_count(_s, 'merge'), 1)
check("count-exact env -S git commit",
      g.git_commit('env -S "git commit -m x"')[0], True)
# `env` sits behind launcher prefixes too — anchoring on token zero missed these.
for _s in ('command env -S "gh pr merge 1"', 'X=1 env -S "gh pr merge 1"',
           '/usr/bin/env -S "gh pr merge 1"'):
    check(f"count-exact {_s!r}", g.gh_pr_count(_s, 'merge'), 1)
# `coproc` takes a NAME only in `coproc NAME <compound>`; otherwise the next
# token IS the command and must not be skipped as a name.
check("count-exact unnamed coproc runs its command",
      g.gh_pr_count("coproc bash -c 'gh pr merge 1'", 'merge'), 1)
check("count-exact time is a wrapper, not the exe",
      g.gh_pr_count('time gh pr merge 1', 'merge'), 1)
# ANSI-C escapes must be honored by the NESTED substitution scanner too, or its
# depth counter mis-balances and truncates the extracted command.
check("count-exact ANSI-C inside a nested substitution",
      g.gh_pr_count("echo \"$(printf %s $'a\\')b'; gh pr merge 1)\"", 'merge'), 1)
# `env -S` can pack the INTERPRETER that runs a heredoc body.
check("count-exact env -S bash heredoc body executes",
      g.gh_pr_count("env -S bash <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
# BSD/macOS attached form tokenizes to one `-Sgh pr merge 1`.
check("count-exact attached env -S form",
      g.gh_pr_count('env -S"gh pr merge 1"', 'merge'), 1)
# ACCEPTED OVER-COUNT (fail-CLOSED, deliberate — do NOT "fix"). A substitution
# the parent shell expands is counted once as its own chunk and again inside the
# interpreter payload, so this scores 2 though bash runs the merge ONCE
# (re-measured by writing the command to a FILE — an earlier revision of this
# test wrongly claimed twice, an artifact of an extra shell layer in the
# harness). Stripping the parent-extracted span from the payload was tried and
# REVERTED: it also erased identical substitution text in an independently
# single-quoted payload, so the two-REAL-merge case below counted 1 and slipped
# past the multi-merge guard. An over-count only BLOCKS; an under-count is a
# bypass.
check("count~ accepted over-count in interpreter arg",
      g.gh_pr_count('bash -c "echo $(gh pr merge 1)"', 'merge'), 2)
check("count-exact $() in a single-quoted interpreter arg",
      g.gh_pr_count("bash -c 'echo $(gh pr merge 1)'", 'merge'), 1)
# Two REAL merges with IDENTICAL substitution text must still count 2 — this is
# the case the reverted optimization broke.
check("count-exact identical text, two real merges",
      g.gh_pr_count("bash -c 'echo $(gh pr merge 1)'; echo \"$(gh pr merge 1)\"", 'merge'), 2)
check("count-exact chained merges inside bash -c",
      g.gh_pr_count('bash -c "gh pr merge 1 && gh pr merge 2"', 'merge'), 2)
# An interpreter can hide behind an assignment + substitution opener, or be
# spelled with quotes — the opener-line scan must see through both.
check("heredoc+ interpreter behind an assignment/substitution",
      g.gh_pr_count("x=$(bash <<'EOF'\ngh pr merge 1\nEOF\n)", 'merge'), 1)
check("heredoc+ quoted interpreter name",
      g.gh_pr_count("'bash' <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
# A quoted delimiter may legally be NAMED like a gated command; the terminator
# line is syntax, not an invocation.
check("heredoc- delimiter named like the command is not one",
      g.gh_pr_count("cat <<'gh pr merge 1'\ninert\ngh pr merge 1", 'merge'), 0)
# ACCEPTED OVER-FIRE (fail-CLOSED, deliberate — do NOT "fix"). Only the FIRST
# opener on a line is consumed, so a second quoted heredoc's body is still
# scanned and can block. Consuming the extras was tried and REVERTED: matching
# them needs quote/comment awareness this scanner lacks, and the two cases below
# show what getting it wrong costs — live text discarded, which is a bypass.
check("heredoc~ accepted over-fire on a multi-opener line",
      g.gh_pr_count("cat <<'A' <<'B'\ninert\nA\ngh pr merge 1\nB", 'merge'), 1)
# A fake opener inside a COMMENT opens nothing, so the merge between the two
# delimiter lines is live and must be counted.
check("heredoc+ fake opener in a comment does not swallow live text",
      g.gh_pr_count("cat <<'A' # <<'B'\ninert\nA\ngh pr merge 1\nB", 'merge'), 1)
# An UNQUOTED opener earlier on the line takes the FIRST body, so the quoted
# delimiter cannot be associated by position — the region stays scanned.
check("heredoc+ unquoted opener before a quoted one keeps live text",
      g.gh_pr_count("cat <<U <<'Q'\n$(gh pr merge 1)\nU\ninert\nQ", 'merge'), 1)
# `eval` evaluates ARGUMENTS, not stdin — its heredoc body runs nothing.
check("heredoc- eval does not execute a heredoc body",
      g.gh_pr_count("eval <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 0)

# ── HEREDOC CONSUMER x OPERATOR MATRIX (fail-OPEN regression) ─────────
# Whether a quoted heredoc body is inert depends on the CONSUMER of the
# redirection, which must be read from the segment owning it — not the whole
# physical line. `true; bash <<'EOF'` and `cat x | bash <<'EOF'` both execute.
for prefix in ('', 'true; ', 'cat /dev/null | ', 'false || ', 'true && '):
    # `eval` is False: it evaluates ARGUMENTS and never reads stdin, so its
    # heredoc body runs nothing (verified) — counting it was a false block.
    for consumer, live in (('bash', True), ('sh', True), ('source /dev/stdin', True),
                           ('eval', False), ('cat', False),
                           ('gh issue comment 1 --body-file -', False)):
        cmd = f"{prefix}{consumer} <<'EOF'\ngh pr merge 1\nEOF"
        check(f"heredoc[{prefix or 'bare'}|{consumer.split()[0]}]",
              g.gh_pr_count(cmd, 'merge') > 0, live)

# ── UNRESOLVED HEREDOC CONSUMER MUST KEEP THE BODY (fail-OPEN) ───────
# A command word built from a variable really does execute the body, and the
# opener-line scan cannot resolve it. Unresolvable ⇒ keep ⇒ fail-CLOSED. This
# also reaches careful-guard.sh, which reuses _all_chunks — a destructive
# command behind `$runner` would otherwise go unseen.
check("heredoc+ variable interpreter keeps the body",
      g.gh_pr_count("runner=bash\n\"$runner\" <<'EOF'\ngh pr merge 1\ngh pr merge 2\nEOF", 'merge'), 2)
check("heredoc+ careful-guard sees rm behind a variable interpreter",
      any('rm -rf' in c
          for c in g._all_chunks("runner=bash\n\"$runner\" <<'EOF'\nrm -rf /\nEOF")), True)
# ...but a variable ARGUMENT on an otherwise literal opener stays inert, or the
# #426 false positive comes straight back for any templated comment.
check("heredoc- variable argument does not make the body live",
      g.gh_pr_count("gh issue comment \"$NUM\" --body-file - <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 0)
check("heredoc- genuinely inert body stays dropped for careful-guard",
      any('rm -rf' in c for c in g._all_chunks("cat <<'EOF'\nrm -rf /\nEOF")), False)

# ── env OPTION SCAN STOPS AT THE UTILITY (false positive) ────────────
# env's own options end at `--` or the first non-option word. Scanning past it
# read the UTILITY's arguments as env options.
check("env-S- prose after `env -- printf` is not a payload",
      g.gh_pr_count("env -- printf '%s' -S 'gh pr merge 1'", 'merge'), 0)
check("env-S+ the real split-string form still works",
      g.gh_pr_count('env -S "gh pr merge 1"', 'merge'), 1)

# ── DEPTH-CAP FLOOR (must be PROVEN to fire) ─────────────────────────
# _all_chunks stops expanding at depth 6. Where it truncates, gh_pr_count falls
# back to a raw occurrence count so the gate stays fail-CLOSED on what it could
# not fully parse — the substring guard this replaced did block those.
#
# NESTED SUBSTITUTIONS are the witness. Naive `bash -c` nesting is NOT: past two
# levels the escaping means bash does not execute it either (verified — detector
# and bash both go to 0), so it never reaches the cap and the branch stays dead.
# These assertions pin that the truncation flag really fires AND that the
# fallback is load-bearing (the per-chunk count alone is 0 here), so a refactor
# that silently breaks the wiring fails loudly instead of failing open.
_deep = 'gh pr merge 1'
for _ in range(8):
    _deep = 'echo $(' + _deep + ')'
_trunc = []
_chunks = g._all_chunks(_deep, 0, _trunc)
check("depth+ truncation flag fires at the cap", bool(_trunc), True)
check("depth+ per-chunk count alone is 0 (fallback is load-bearing)",
      sum(len(list(g._iter_gh(c, 'merge', False))) for c in _chunks), 0)
check("depth+ fail-closed floor still counts the merge",
      g.gh_pr_count(_deep, 'merge'), 1)
# Shallow nesting must NOT take the fallback path.
check("depth- shallow nesting counted normally",
      g.gh_pr_count('echo $(echo $(gh pr merge 1))', 'merge'), 1)

# An env-ASSIGNMENT prefix is not the command word: `X=$Y cat <<'EOF'` is still
# an inert `cat`, or templated openers regain the #426 false positive.
check("heredoc- env-assignment prefix does not make the body live",
      g.gh_pr_count("X=$Y cat <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 0)

# ── LAUNCHER PREFIXES MUST NOT HIDE A DYNAMIC CONSUMER ───────────────
# The command word has to be reached through wrappers and redirections, not
# just assignments — `command "$runner" <<'EOF'` reported `command`, marked the
# body inert, and dropped a merge that executes.
check("heredoc+ wrapper before a variable interpreter",
      g.gh_pr_count("runner=bash\ncommand \"$runner\" <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)

# ── env OPTIONS WITH SEPARATE VALUES ─────────────────────────────────
# `-u FOO` consumes FOO, which is not the utility; stopping there never reached
# the -S and let the packed command through.
check("env-S+ value-taking option before -S",
      g.gh_pr_count("env -u FOO -S 'gh pr merge 1'", 'merge'), 1)

# ── DEPTH FALLBACK SEES QUOTED SPELLINGS ─────────────────────────────
# The shell normalizes `g"h" p"r" merge`; a literal-only regex reported 0 on
# exactly the deeply-nested input the fallback exists to catch.
_dq = 'g"h" p"r" merge 1'
for _ in range(8):
    _dq = 'echo $(' + _dq + ')'
check("depth+ fallback sees a quoted executable spelling",
      g.gh_pr_count(_dq, 'merge'), 1)

# ── LAUNCHER-OPTION AND env-ARITY EDGE CASES ─────────────────────────
# A wrapper's no-arg option must not swallow the dynamic command word after it,
# and env's own value-taking options must not be mistaken for the utility.
check("heredoc+ env -i before a variable interpreter",
      g.gh_pr_count("runner=/bin/sh\nenv -i \"$runner\" <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
check("env-S+ -P (utility search path) before -S",
      g.gh_pr_count("env -P /opt/homebrew/bin -S 'gh pr merge 1'", 'merge'), 1)
# The depth fallback normalizes ANSI-C spellings too, or `$'gh' $'pr' merge`
# survives as `$gh $pr merge` and reports 0.
_ansi = "$'gh' $'pr' merge 2"
for _ in range(8):
    _ansi = 'echo $(' + _ansi + ')'
check("depth+ fallback sees an ANSI-C executable spelling",
      g.gh_pr_count(_ansi, 'merge'), 1)

# ── PARITY WITH THE SUBSTRING GUARD THIS REPLACED ────────────────────
# These shapes were caught INCIDENTALLY by the old substring count, so losing
# them would be a real regression rather than an inherited gap. The command word
# must be reached through redirections and quoted assignment VALUES, and env's
# --argv0 takes a separate argument.
check("heredoc+ redirection before a variable interpreter",
      g.gh_pr_count("runner=bash\n</dev/null \"$runner\" <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
check("heredoc+ quoted assignment value before a variable interpreter",
      g.gh_pr_count("runner=bash\nX=\"a b\" \"$runner\" <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
check("env-S+ --argv0 value before -S",
      g.gh_pr_count("env -a ignored -S 'gh pr merge 1'", 'merge'), 1)

# ── WRAPPER-OPTION ARITY IS AMBIGUOUS — CHECK BOTH READINGS ──────────
# `env -i "$runner"` (no-arg -i) and `env -u FOO "$runner"` (value-taking -u)
# put the command word in different places; either single arity guess misses
# one (both were caught by the old substring guard, so a real regression).
# Checking both candidate command words is fail-CLOSED without modeling env's
# option grammar — and does NOT reintroduce the #426 false positive, because
# both readings agree on the command word when there is no wrapper.
check("heredoc+ env value-option before a variable interpreter",
      g.gh_pr_count("runner=bash\nenv -u FOO \"$runner\" <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 1)
check("heredoc- variable ARGUMENT still does not make the body live",
      g.gh_pr_count("gh issue comment \"$NUM\" --body-file - <<'EOF'\ngh pr merge 1\nEOF", 'merge'), 0)

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
    'gh \\\npr create --fill',           # line continuation before subcommand
    'gh pr \\\ncreate --fill',           # continuation before the verb
    'cat <(gh pr create --fill)',        # process substitution runs the create
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
# An unconfirmed cd is reported OUT OF BAND (opt-in 4th element) so target_dir stays
# a pure path field -- folding a sentinel into it would be forgeable by a real
# directory and would downgrade the '$'-in-target BLOCK. Default stays a 3-tuple, so
# the non-gating nudge parsers are untouched. Resolver matrix:
# tests/test-gate-untrusted-cd.sh.
check("untrusted_cd absent by default (3-tuple)", len(g.git_commit('cd /tmp/r; git commit')), 3)
check("untrusted_cd opt-in (semicolon)", g.git_commit('cd /tmp/r; git commit', with_untrusted_cd=True)[3], '/tmp/r')
check("untrusted_cd opt-in (newline)", g.git_commit('cd /tmp/r\ngit commit', with_untrusted_cd=True)[3], '/tmp/r')
check("untrusted_cd empty when '&&'-trusted", g.git_commit('cd /tmp/r && git commit', with_untrusted_cd=True)[3], '')
check("untrusted_cd empty when no cd", g.git_commit('git commit', with_untrusted_cd=True)[3], '')
check("untrusted_cd empty on no match", g.git_commit('ls', with_untrusted_cd=True)[3], '')
# `git -C` already scoped the repo authoritatively -- do not also report a stale
# pending operand the caller might second-guess it with.
check("untrusted_cd suppressed by git -C", g.git_commit('cd /tmp/r; git -C /other commit', with_untrusted_cd=True)[3], '')
# ...but ONLY when that -C is AUTHORITATIVE. Tokenization discards the tilde's
# quoting, so `git -C "~"` is a LITERAL RELATIVE dir git resolves against the runtime
# cwd (/other/~), even though expanduser makes target_dir look absolute here.
# Suppressing the payload's cd on "target_dir starts with /" therefore aimed the gate
# at $HOME while the commit landed elsewhere -- and blanked untrusted_cd, so nothing
# blocked. Pin both halves plus the arity the 5th internal element must not leak.
check("tilde -C alone emits a blocking token",
      g.git_commit('git -C "~" commit', with_untrusted_cd=True)[3], '-tilde-c-operand')
check("tilde -C with a path too",
      g.git_commit('git -C ~/sub commit', with_untrusted_cd=True)[3], '-tilde-c-operand')
check("tilde -C does NOT suppress a payload cd",
      g.git_commit('eval \'cd /other\'; git -C "~" commit', with_untrusted_cd=True)[3],
      '-ambiguous-cd-operands')
# A LATER absolute -C re-establishes authority; an EARLIER one does not survive a
# later tilde (git resolves the literal '~' against /session, not $HOME).
check("later absolute -C wins (no false block)",
      g.git_commit('git -C "~" -C /session commit', with_untrusted_cd=True)[3], '')
check("earlier absolute -C does not survive a tilde",
      g.git_commit('git -C /session -C "~" commit', with_untrusted_cd=True)[3], '-tilde-c-operand')
check("absolute -C still suppresses payload cd",
      g.git_commit("eval 'cd /other'; git -C /session commit", with_untrusted_cd=True)[3], '')
check("authoritative flag does not leak into the tuple",
      len(g.git_commit('git -C "~" commit', with_untrusted_cd=True)), 4)
check("tilde -C keeps the 3-tuple default",
      len(g.git_commit('git -C "~" commit')), 3)
# A `-C` inside a payload is not resolved for scoping, but silence there was not
# neutral: it returned the same ('', '') as "no cd at all", so the gate anchored on
# the session cwd while git committed in the -C target. It must BLOCK instead.
# `_command_argv` DELETES leading/embedded grouping tokens, so an INDEX into the
# argv it returns does not name the same token in the untouched stream -- and the
# deletions are mid-stream, so no single offset corrects for them. It now carries the
# aligned raw spellings instead. The shape below is the one that got through: two
# brace groups shift the stream by 2, landing the spelling check on a double-quoted
# REDIRECTION TARGET decoy, so the single-quoted operand was read as the live idiom
# and the gate proceeded on the session cwd while bash cd'd into a literal directory.
# A brace group runs in the CURRENT shell, so the cd really does take effect.
# `pushd DIR` moves the CURRENT shell exactly like `cd DIR`, and `popd` returns to a
# stack entry no static parser can know. Both reported '' -- byte-identical to "no cd
# at all" -- so `pushd /other-repo; git commit` committed in /other-repo while the
# gate validated the SESSION repo's marker. Recorded now, seen but never trusted.
check("pushd is recorded like cd",
      g.git_commit('pushd /other-repo; git commit -m x', with_untrusted_cd=True)[3], '/other-repo')
check("pushd behind && is still untrusted",
      g.git_commit('pushd /other-repo && git commit -m x', with_untrusted_cd=True)[3], '/other-repo')
check("popd has no knowable destination",
      g.git_commit('popd; git commit -m x', with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
check("bare pushd swaps the stack -- also unknowable",
      g.git_commit('pushd; git commit -m x', with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
# ...and a commit with no directory change at all must stay clean.
# _command_argv protects the `target` token from being eaten as a wrapper option's
# argument. It took ONE name, so protecting 'cd' left `command -p pushd /other` and
# `time -p pushd /other` consuming `pushd` as the option value -- argv became just
# ['/other'], the loose channel saw no command word, and untrusted_cd came back
# empty. It now takes a tuple, so all three builtins are protected.
check("command -p does not swallow pushd",
      g.git_commit('command -p pushd /other; git commit', with_untrusted_cd=True)[3], '/other')
check("time -p does not swallow pushd",
      g.git_commit('time -p pushd /other; git commit', with_untrusted_cd=True)[3], '/other')
check("wrapper does not swallow popd",
      g.git_commit('command -p popd; git commit', with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
check("wrapper still does not swallow cd",
      g.git_commit('command -p cd /other; git commit', with_untrusted_cd=True)[3], '/other')
# The multi-target change must not make a wrapped COMMIT look like a cd.
# `-n` suppresses the directory change for BOTH stack builtins -- but ONLY as an
# OPTION. A scan of the whole argv also matched it as an operand or a redirection
# target, reporting "no cd" while the shell really moved (fail-OPEN), so the walk
# stops treating tokens as options at `--` or at the first operand.
check("-n option suppresses pushd",
      g.git_commit('pushd -n /other; git commit', with_untrusted_cd=True)[3], '')
check("-n option suppresses popd",
      g.git_commit('popd -n; git commit', with_untrusted_cd=True)[3], '')
check("-n after -- is an OPERAND, not the option",
      g.git_commit('pushd -- -n; git commit', with_untrusted_cd=True)[3], '-n')
check("-n as a redirection target is not the option",
      g.git_commit('pushd /other > -n; git commit', with_untrusted_cd=True)[3], '/other')
# A rotation operand DOES move, to a stack entry no static parser can name. It is
# reported verbatim and the RESOLVER blocks it (relative operand) -- what must not
# happen is it coming back clean.
check("pushd rotation is not reported clean",
      g.git_commit('pushd +1; git commit', with_untrusted_cd=True)[3], '+1')
check("popd rotation is unknowable",
      g.git_commit('popd +1; git commit', with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
# `command -v NAME` / `-V NAME` only PRINT a resolution; nothing executes. Protecting
# pushd as a target name made the query look like an executed bare pushd.
# ANSI-C quoting survives tokenization with the leading `$` attached (`$\'pushd\'` ->
# `$pushd`), and bash still runs the builtin. The target guard compared the raw token,
# so `command -p $\'pushd\' /other` consumed the command word as the wrapper option\'s
# argument and reported no directory change -- fail-OPEN. Same gap applied to `cd`.
# The ANSI-C leniency is scoped to the cd BUILTINS. Applying it to `git`/`gh` made a
# wrapper ARGUMENT named `$git` look like the protected executable, so it was not
# consumed: argv started at `$git`, matched no executable, and the commit went
# UNDETECTED. Same for `$gh` and the merge detector.
check("a wrapper argument named $git is still consumed",
      g.git_commit('env -u $git git commit')[0], True)
check("a wrapper argument named $gh is still consumed",
      g.gh_pr('env -u $gh gh pr merge 1', 'merge')[0], True)
check("ANSI-C $pushd behind a wrapper is still a target",
      g.git_commit("command -p $\'pushd\' /other; git commit", with_untrusted_cd=True)[3], '/other')
check("ANSI-C $cd behind a wrapper is still a target",
      g.git_commit("command -p $\'cd\' /other; git commit", with_untrusted_cd=True)[3], '/other')
check("ANSI-C $popd is still unknowable",
      g.git_commit("$\'popd\'; git commit", with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
# A DYNAMIC command word is an ACCEPTED residual, not an oversight: `cmd=cd;
# $cmd /other` really moves the shell, but closing it means treating every
# `$VAR <operand>` as a possible cd, which blocks ordinary `$EDITOR file; git commit`.
# Behaviour matches the pre-untrusted_cd parser, so the channel does not open this gap.
# Pinned so the trade-off is explicit and cannot be changed silently either way.
check("a dynamic command word is an accepted residual",
      g.git_commit('$cmd /other; git commit', with_untrusted_cd=True)[3], '')
# The query scan MUST stay bounded to the leading wrapper run. Scanning the whole
# token list also matched a `command -v` sitting AFTER an interpreter payload, so
# the target='' discovery path returned [] and hid a real commit -- fail-OPEN.
check("a trailing query does not hide an interpreter payload",
      g.git_commit('bash -c "git commit" command -v')[0], True)
check("a trailing query does not hide a preceding cd",
      g.git_commit('cd /other; bash -c "git commit" command -v', with_untrusted_cd=True)[3], '/other')
# bash accepts clustered and repeated options, so these are queries too and must not
# be read as an executed bare pushd (which would block a commit that never moved).
# The query scan has to walk past the SAME prefixes the main parser strips, or a
# redirection / keyword / group in front of the query made it look like an executed
# bare pushd and blocked a commit that never moved.
# There is deliberately NO `command -v NAME` shortcut. Such a query only PRINTS a
# resolution, so recognising it would avoid one false block -- but `command` is not
# reliably the builtin: a shell FUNCTION or an executable `./command` can override it
# and really does run its arguments. A shortcut that returns "nothing executed"
# therefore HIDES a real commit or merge. These pin that detection survives every
# override form, and that the query itself over-blocks rather than fails open.
check("a function override of command still runs the commit",
      g.git_commit('command() { shift; "$@"; }; command -v git commit')[0], True)
check("an executable ./command still runs the commit",
      g.git_commit('./command -v git commit')[0], True)
check("a redirection target named -v hides nothing",
      g.git_commit('command > -v git commit')[0], True)
check("...and hides no merge either",
      g.gh_pr('command > -v gh pr merge 1', 'merge')[0], True)
check("a genuine query over-blocks (accepted, never fails open)",
      g.git_commit('command -v pushd; git commit', with_untrusted_cd=True)[3], '-ambiguous-cd-operands')
check("wrapped commit with no cd stays clean",
      g.git_commit('command -p git commit', with_untrusted_cd=True)[3], '')
check("no cd/pushd stays clean",
      g.git_commit('git commit -m x', with_untrusted_cd=True)[3], '')
check("brace-shifted decoy does not vouch for a quoted cd",
      g.git_commit('{ { > "$(git rev-parse --show-toplevel)" cd \'$(git rev-parse --show-toplevel)\'; }; }; git commit -m x',
                   with_untrusted_cd=True)[3],
      "'$(git rev-parse --show-toplevel)'")
check("brace-shifted decoy does not vouch for a quoted -C",
      g.git_commit('{ { > "$(git rev-parse --show-toplevel)" git -C \'$(git rev-parse --show-toplevel)\' commit; }; }',
                   with_untrusted_cd=True)[1],
      "'$(git rev-parse --show-toplevel)'")
# ...and a genuinely live operand inside a brace group must NOT be masked.
check("live -C inside a brace group stays live",
      g.git_commit('{ git -C "$(git rev-parse --show-toplevel)" commit; }',
                   with_untrusted_cd=True)[1],
      '$(git rev-parse --show-toplevel)')
# gh_pr still suppresses the nested fold on `target_dir.startswith("/")`, the test the
# commit path abandoned as unsound. It is not exploitable there only because _iter_gh
# INDEPENDENTLY requires cds[-1] == target_dir, which an expanduser'd tilde fails. That
# invariant lives in a different function from the test depending on it, so pin it here:
# if the agreement check is ever loosened, this fails instead of silently fail-opening.
check("gh: tilde cd still blocks despite the absolute-looking target",
      g.gh_pr('eval \'cd /other\'; cd "~" && gh pr create', 'create', with_untrusted_cd=True)[3],
      '-ambiguous-cd-operands')
check("nested -C blocks (eval, tilde)",
      g.git_commit('eval \'git -C "~" commit\'', with_untrusted_cd=True)[3], '-nested-c-operand')
check("nested -C blocks (bash -c, absolute)",
      g.git_commit("bash -c 'git -C /other commit'", with_untrusted_cd=True)[3], '-nested-c-operand')
check("nested -C folds in with an outer cd",
      g.git_commit("cd /other; bash -c 'git -C /session commit'", with_untrusted_cd=True)[3],
      '-ambiguous-cd-operands')
# ...and a payload with NO -C must stay clean, or the token is just a blanket block.
check("nested commit without -C stays clean",
      g.git_commit("bash -c 'git commit'", with_untrusted_cd=True)[3], '')
# `git commit -C HEAD` is the reuse-message flag, AFTER the subcommand -- the walk is
# bounded by sub_idx, so it must not be mistaken for a directory change.
check("commit -C HEAD is not a -C operand",
      g.git_commit('git commit -C HEAD', with_untrusted_cd=True)[3], '')
# '~+'/'~-' are bash-only ($PWD/$OLDPWD); expanduser leaves them RELATIVE, so they
# skipped the authority-revoking branch and an earlier trusted cd kept authority --
# `cd /repo && git -C ~+ commit` scoped to a nonexistent /repo/~+ with an EMPTY
# untrusted_cd while bash committed in /repo. Every tilde form must revoke it.
check("~+ revokes an earlier cd's authority",
      g.git_commit('cd /repo && git -C ~+ commit', with_untrusted_cd=True)[3], '-tilde-c-operand')
check("~- revokes an earlier cd's authority",
      g.git_commit('cd /repo && git -C ~- commit', with_untrusted_cd=True)[3], '-tilde-c-operand')
check("cd && commit with no -C stays clean",
      g.git_commit('cd /repo && git commit', with_untrusted_cd=True)[3], '')
check("cd && absolute -C stays clean",
      g.git_commit('cd /repo && git -C /other commit', with_untrusted_cd=True)[3], '')
check("gh_pr untrusted_cd opt-in", g.gh_pr('cd /tmp/r; gh pr merge 5', 'merge', with_untrusted_cd=True)[3], '/tmp/r')
check("gh_pr 3-tuple by default", len(g.gh_pr('cd /tmp/r; gh pr merge 5', 'merge')), 3)
check("gh_pr untrusted_cd empty on '&&'", g.gh_pr('cd /tmp/r && gh pr merge 5', 'merge', with_untrusted_cd=True)[3], '')
check("git -C target_dir", g.git_commit('git -C /tmp/r commit')[1], '/tmp/r')
# A newline inside a quoted cd target must NOT be silently truncated away: callers
# reject a CR/LF-bearing target, and a truncated one gave them nothing to reject
# while bash still ran from the real (different) directory.
def _raises(fn):
    try:
        fn(); return False
    except ValueError:
        return True
check("cd target with LF raises (fail-closed)", _raises(lambda: g._cd_target('cd "/safe\nother"')), True)
# split_segments must not strip a trailing CR either — bash keeps it and cds into a
# DIFFERENT directory, so stripping it here hid the whole attack from _cd_target.
check("segment keeps trailing CR", _raises(
    lambda: g._cd_target(g.split_segments('cd /reviewed\r && gh pr merge 31')[0][1])), True)
check("cd target with CR raises (fail-closed)", _raises(lambda: g._cd_target('cd "/safe\rother"')), True)
# Trailing, UNQUOTED CR/LF: str.strip() treats \r/\n as whitespace and would
# silently drop a trailing CR before the check ever ran if the check ran on
# the already-stripped value — the gate would then approve the marker for
# the CR-less path while bash actually `cd`s into the distinct CR-suffixed
# directory. Checking the raw captured group before stripping closes this
# (cubic P1, PR #511).
check("cd target with trailing unquoted CR raises (fail-closed)", _raises(lambda: g._cd_target('cd /safe\r')), True)
check("cd target with trailing unquoted LF raises (fail-closed)", _raises(lambda: g._cd_target('cd /safe\n')), True)
check("ordinary cd target still resolves", g._cd_target('cd /tmp/r'), '/tmp/r')
# `git -C` is the OTHER derivation of target_dir and must reject identically.
check("git -C target with LF raises", _raises(lambda: g.git_commit('git -C "/safe\nother" commit')), True)
check("git -C target with CR raises", _raises(lambda: g.git_commit('git -C "/safe\rother" commit')), True)
# UNQUOTED trailing CR on a `-C` operand: shlex's default whitespace is
# ' \t\r\n', so `shlex.split` silently treats a raw CR the same as a space --
# `-C /safe<CR> commit` tokenized to `-C /safe` `commit` with the CR just
# dropped as a separator, instead of `-C` `/safe<CR>` -- hiding it from
# `_reject_crlf` entirely (the "RAW operand" comment above that call was only
# true after tokenization, not after shlex had already eaten the CR). Bash's
# own IFS does not include CR, so bash keeps `/safe<CR>` as ONE word and
# scopes git to a directory the gate never validated (coderabbit #511).
check("git -C target with UNQUOTED trailing CR raises (fail-closed)",
      _raises(lambda: g.git_commit('git -C /safe\r commit')), True)
check("git -C target with UNQUOTED embedded CR raises (fail-closed)",
      _raises(lambda: g.git_commit('git -C /safe\rother commit')), True)
# ...and the ordinary (no CR/LF) unquoted case must still resolve normally --
# excluding \r from shlex's whitespace must not break plain `-C` parsing.
check("git -C target with no CR/LF still resolves",
      g.git_commit('git -C /safe commit')[1], '/safe')
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

# ── gh_pr_repo_override: cross-repo selector on a merge (#505) ────────
# Two scopes on purpose — flag form is argv-scoped, env form is whole-command.
# See the docstring; the asymmetry is the whole point of the function.
OVERRIDE_YES = [
    'gh pr merge 31 --squash -R other/repo',        # separate -R
    'gh pr merge 31 --squash -Rother/repo',         # attached -R
    'gh pr merge 31 --squash --repo other/repo',    # separate --repo
    'gh pr merge 31 --squash --repo=other/repo',    # = form
    'gh -R other/repo pr merge 31',                 # gh GLOBAL flag really retargets
    'GH_REPO=other/repo gh pr merge 31',            # bare env assignment
    'GH_HOST=ghe.corp gh pr merge 31',              # host selector too
    'env "GH_REPO=other/repo" gh pr merge 31',      # quoted → no whitespace before it
    '(GH_REPO=other/repo gh pr merge 31)',          # grouped → `(` before it
    "GH_REPO=other/repo bash -c 'gh pr merge 31'",  # merge lands in a NESTED chunk
    "bash -c 'gh -R other/repo pr merge 31'",       # flag form inside a payload
    # The shell reassembles a name split by quoting or escaping; both of these
    # really export GH_REPO, so a regex over RAW text would miss them.
    'env GH_RE"PO"=other/repo gh pr merge 31',      # quote-split name
    'env GH_RE\\PO=other/repo gh pr merge 31',      # backslash-split name
    "GH_REPO''=other/repo gh pr merge 31",          # empty quotes inside the name
    'GH_RE\\\nPO=other/repo gh pr merge 31',        # continuation-split name
    'GH_REPO+=other/repo gh pr merge 31',           # append form EXPORTS when unset
    'GH_HOST+=ghe.corp gh pr merge 31',
    # pflag shorthand CLUSTERS — gh accepts these and they really set --repo.
    'gh pr merge 31 -sRother/repo',                 # R mid-cluster, attached value
    'gh pr merge 31 -sR other/repo',                # R last, separate value
    'gh pr merge 31 -adR other/repo',               # several bools then R
    'if GH_REPO=other/repo gh pr merge 31; then :; fi',   # behind a shell keyword
    'env -u FOO GH_REPO=other/repo gh pr merge 31',      # after a wrapper option ARG
    '! GH_REPO=other/repo gh pr merge 31',               # pipeline negation still runs
    # `export` puts it in the CHILD's environment, so it reaches a later segment.
    'export GH_REPO=other/repo; gh pr merge 31',
    'export GH_REPO=other/repo && gh pr merge 31',
    'declare -x GH_HOST=ghe.corp; gh pr merge 31',
    'GH_REPO=other/repo; export GH_REPO; gh pr merge 31',   # exported a step apart
    'export GH_REPO; GH_REPO=other/repo; gh pr merge 31',   # ...and in either order
    'if export GH_REPO=other/repo; then gh pr merge 31; fi',  # export not leading
    "bash -c 'f(){ local -x GH_REPO=other/repo; gh pr merge 31; }; f'",  # local -x
    # Deliberate OVER-blocks: neither actually exports, but distinguishing them means
    # interpreting the command. Fail-CLOSED is the correct residue here.
    'declare GH_REPO=other/repo; gh pr merge 31',
    'export -n GH_REPO=other/repo; gh pr merge 31',
    # A BARE assignment in another segment. It looks inert — a shell variable the
    # child never sees — but bash preserves the export attribute across
    # re-assignment, so if the caller's shell already exported GH_REPO this DOES
    # retarget the merge. That is ambient state no parse can see, so it fails closed.
    'GH_REPO=other/repo; gh pr merge 31',
    'GH_REPO=other/repo gh pr view 31 && gh pr merge 31',
    # A PR URL carries its own owner/repo — a positional selector, no flag involved.
    'gh pr merge https://github.com/other/repo/pull/31',
    'gh pr merge https://github.com/other/repo/pull/31 --squash --admin',
]
OVERRIDE_NO = [
    'gh pr merge 31 --squash',                      # plain merge
    'gh pr merge 31 --squash --admin --delete-branch',
    # THE regression case: pr-grind's auto-admin block runs a `-R` view and an
    # unselected merge in ONE call. A whole-command test blocks this and pr-grind
    # can never merge — that is why the flag form is argv-scoped.
    'gh -R "$OWNER/$REPO" pr view 31 --json mergeStateStatus && gh pr merge 31 --squash --admin',
    'gh pr view 31 -R other/repo && gh pr merge 31',  # selector on the VIEW only
    'MY_GH_REPO=other/repo gh pr merge 31',         # word-char before it → not ours
    'GH_REPO=other/repo gh pr view 31',             # no merge at all → nothing to steer
    'GH_REPO=other/repo git commit -m x',           # not gh
    # An R inside a value-taking shorthand's ATTACHED VALUE is not a selector:
    # pflag stops cluster-scanning at -t/-b/-F, so these are subjects/bodies.
    'gh pr merge 31 -tRefactor',                    # subject "Refactor"
    'gh pr merge 31 -stReview --squash',            # -s bool, then -t value "Review"
    'gh pr merge 31 -bReported by R',               # body containing R
    'gh pr merge 31 --squash --delete-branch',      # long bools only
    # A value-taking flag's SEPARATE operand is not a selector either — consuming it
    # is what stops `--subject -R` from false-blocking a legitimate merge.
    'gh pr merge 31 --subject -R',                  # -R is the subject VALUE
    'gh pr merge 31 -t -R --squash',                # short form, same shape
    'gh pr merge 31 --body-file -R',
    # Inert look-alikes: text that merely CONTAINS an assignment exports nothing.
    "gh pr merge 31 --body 'Document GH_REPO=owner/repo'",
    "gh pr merge 31 --subject 'set GH_HOST=ghe.corp first'",
    # Prose that BEGINS with the assignment: still one argument token, and a real
    # assignment word never contains unquoted whitespace.
    "gh pr merge 31 --body 'GH_REPO=owner/repo is the default'",
    "echo 'GH_REPO=owner/repo is the default' && gh pr merge 31",
    # -A/--author-email takes a value; an R inside that email is not a selector.
    'gh pr merge 31 -AfooR@example.com',
    'gh pr merge 31 -A foo@example.com --squash',
    # Cluster ENDING in a value-taking shorthand: the next token is that value.
    'gh pr merge 31 -st -R',                        # -s bool, -t subject "-R"
    'gh pr merge 31 -db -R',                        # -d bool, -b body "-R"
]
for c in OVERRIDE_YES:
    check(f"override+ {c!r}", g.gh_pr_repo_override(c, 'merge'), True)
for c in OVERRIDE_NO:
    check(f"override- {c!r}", g.gh_pr_repo_override(c, 'merge'), False)

# ── gh_pr_auto_merge: --auto QUEUES the merge past the gate's check (#505) ──
# pflag accepts `--auto=<bool>` for booleans, so an exact-token match alone let
# `--auto=true` through. False spellings genuinely disable auto and must NOT
# match; an unrecognized value fails CLOSED (gh would reject it anyway).
AUTO_YES = [
    'gh pr merge 31 --auto',
    'gh pr merge 31 --auto=true', 'gh pr merge 31 --auto=1',
    'gh pr merge 31 --auto=t', 'gh pr merge 31 --auto=True',
    'gh pr merge 31 --auto=TRUE',
    'gh pr merge 31 --auto=bogus',          # unparseable → fail CLOSED
    'gh pr merge 31 --squash --auto --delete-branch',
    "bash -c 'gh pr merge 31 --auto'",      # nested payload
]
AUTO_NO = [
    'gh pr merge 31 --squash',
    'gh pr merge 31 --auto=false', 'gh pr merge 31 --auto=0',
    'gh pr merge 31 --auto=f', 'gh pr merge 31 --auto=False',
    'gh pr merge 31 --auto=FALSE',
    'gh pr merge 31 --disable-auto',        # a DIFFERENT flag, not a prefix match
    'gh pr view 31 --auto && gh pr merge 31',   # flag is on the VIEW, not the merge
    "gh pr merge 31 --body 'use --auto next time'",  # inert prose in an operand
]
# Deliberate OVER-blocks: a `--auto` inside a bash COMMENT is inert, but shlex has
# already stripped quoting by the time we see the token, so a comment `#` cannot be
# told apart from a legitimate hash-prefixed ARGUMENT. Skipping at `#` was tried and
# reverted — `gh pr merge '#feature' --auto` would then hide a live flag (fail-OPEN).
# A false block is visible and reworded; a bypass is not.
AUTO_OVERBLOCK = [
    'gh pr merge 31 --squash # do not use --auto',
    "gh pr merge '#feature' --auto",     # the case that makes skipping unsafe
]
for c in AUTO_OVERBLOCK:
    check(f"auto-overblock {c!r}", g.gh_pr_auto_merge(c, 'merge'), True)
for c in AUTO_YES:
    check(f"auto+ {c!r}", g.gh_pr_auto_merge(c, 'merge'), True)
for c in AUTO_NO:
    check(f"auto- {c!r}", g.gh_pr_auto_merge(c, 'merge'), False)

# Property sweep: the env form must survive every quoting/grouping/wrapper shape,
# since an assignment is ambient and reaches the merge however it is nested.
for _q in ('', '"', "'"):
    for _tpl in ('{a} gh pr merge 31',
                 '({a} gh pr merge 31)',
                 '{{ {a} gh pr merge 31; }}',
                 'env {a} gh pr merge 31',
                 "{a} bash -c 'gh pr merge 31'"):
        _c = _tpl.format(a=f'{_q}GH_REPO=other/repo{_q}')
        check(f"gen override+ {_c!r}", g.gh_pr_repo_override(_c, 'merge'), True)

# ── NESTED route: a payload reached past an assignment value that TORE ───────
# shlex splits at whitespace with no idea a substitution is open, so the walk
# stops on the debris and never reaches the interpreter. Every positive below is
# verified to execute the commit inside the child.
for _c in ('X=$((1 + 2)) bash -c "git commit -m x"',
           'X=${foo:-a b} bash -c "git commit -m x"',
           'X=$(printf x y) bash -c "git commit -m x"',
           'X=<(printf x y) bash -c "git commit -m x"',
           'env A-B=$((1 + 2)) bash -c "git commit -m x"',
           'env "BASH_FUNC_x%%=() { echo /etc; }" bash -c "git commit -m x"',
           'env -u x X=$(printf x y) bash -c "git commit -m x"',
           'ba{s..s}h -c "git commit -m x"',
           '/bin/@(ba)sh -c "git commit -m x"'):
    check(f"torn-nested+ {_c!r}", g.git_commit(_c)[0], True)
# ...and a walk that read a real command word is BELIEVED, so these stay silent.
# A lone CLOSER is tear debris, not a command name; `:` and `[` are real names.
for _c in ('echo bash -c "git commit"',
           "printf '%s' bash -c 'git commit'",
           "X=$(printf x y) echo -c 'git commit'",     # `y)` is debris, not a shell
           "X=${foo:-a b} echo -c 'git commit'",       # `b}` likewise
           ': git commit',
           # `&&` splits into a separate segment (split_segments), so a payload
           # in the SECOND segment can never make the `[` row load-bearing --
           # same-segment placement is required for a misclassified `[` to
           # actually flip this row (verified: dropping `[` from
           # _READABLE_NAME leaves the `&&`-split form False either way).
           '[ -f x ] -c "git commit"',
           "printf '%s' 'X=$(x)' bash -c 'git commit'"):
    check(f"torn-nested- {_c!r}", g.git_commit(_c)[0], False)
# #589: a QUOTED glob-shaped word that resolves to NO interpreter is not the sh
# stand-in. Both halves are required, and neither is about position -- see
# _fallback_interpreter_name. QUOTED, because bash performs no pathname
# expansion inside quotes, so the word can only name a file literally called
# `*.py`; the raw spelling comes from _raw_tokens, and an unavailable or
# unaligned raw stream narrows nothing (fail CLOSED). UNRESOLVED, because a glob
# that DOES fnmatch an interpreter still reaches a shell, so it stays
# fail-closed in command position and everywhere else.
check("589- torn printf operand '*.py' is not a shell",
      g.git_commit("X=$(printf x y) printf '%s' '*.py' -c 'git commit -m x'")[0],
      False)
check("589+ glob-shaped command word still names a shell",
      g.git_commit('/bin/ba?h -c "git commit -m x"')[0], True)
check("589+ quoted glob-shaped command pathname stays fail-closed",
      g.git_commit("'./b*sh' -c 'git commit -m x'")[0], True)
# EVERY interpreter, not just bash. A glob that RESOLVES must survive the #589
# narrowing, and the one that made this sweep necessary is `sh` itself: a `?`
# form of `sh` fnmatches the real `sh`, so _interpreter_name returns the same
# string it uses for the unresolved stand-in. A name-equality test could not
# tell them apart and silently dropped `/bin/?h -c 'git commit -m x'`, which
# runs. Generated per interpreter so a newly added shell cannot miss coverage.
for _i in sorted(g._INTERPRETERS):
    _forms = ['/bin/' + _i[0] + '?' + _i[2:] if len(_i) > 2 else '/bin/' + _i[0] + '?',
              '/bin/' + _i[0] + '*',                      # star, not just `?`
              '/bin/*' + _i[-1],                          # leading star
              # BRACKET CLASS -- fnmatch has no POSIX classes, so this matches
              # NOTHING here while bash expands it to the real binary and runs
              # it. The suppression must not fire on a bracket for exactly that
              # reason; see _fallback_interpreter_name.
              '/bin/' + _i[0] + '[[:alpha:]]' + _i[2:] if len(_i) > 2
              else '/bin/' + _i[0] + '[[:alpha:]]',
              # `bash -O nocaseglob` expands this to the real binary; fnmatchcase
              # refuses it, so the resolution test must be case-insensitive.
              '/bin/' + (_i[0] + '?' + _i[2:] if len(_i) > 2
                         else _i[0] + '?').upper()]
    for _g in _forms:
        check(f"589+ glob {_g!r} stays fail-closed ({_i})",
              g.git_commit(f"{_g} -c 'git commit -m x'")[0], True)
# A bracket that resolves to nothing under fnmatch is still refused, even when
# the word names no interpreter at all -- the class could expand to one.
# QUOTE PROVENANCE is what separates #589's data from a real glob, and it is the
# half `tok` alone cannot supply (shlex strips quotes). Quoted: bash performs no
# pathname expansion, so the word can only name a file literally called `*.py`.
# UNQUOTED: the glob expands to whatever is on disk, so a `shell.py` symlink to
# bash really does run the commit -- fail-CLOSED, both in command position and
# as an operand.
check("589+ UNQUOTED glob command word stays fail-closed",
      g.git_commit("X=$(printf x y) ./*.py -c 'git commit -m x'")[0], True)
check("589+ UNQUOTED glob operand stays fail-closed",
      g.git_commit("X=$(printf x y) printf %s ./*.py -c 'git commit -m x'")[0], True)
check("589- double-quoted glob operand is not a shell",
      g.git_commit('X=$(printf x y) printf %s "*.py" -c \'git commit -m x\'')[0],
      False)
# THE FAIL-OPEN BOUNDARY: the narrowing consumes quote provenance, so it is only
# ever as safe as `_raw_tokens`. That helper returns None when the raw and posix
# token streams do not align 1:1 -- adjacent-quote concatenation, a bare suffix
# on a quoted word, an empty-quote splice -- and _quoted_literal(None) is False,
# so the scan narrows NOTHING and the glob is promoted as before. Every row below
# is TORN (an aligned, non-torn segment never reaches the fallback at all, so it
# would test nothing) and every row must stay DETECTED.
for _c in ("X=$(printf x y) printf %s '*'\".py\" -c 'git commit -m x'",
           "X=$(printf x y) printf %s '*'.py -c 'git commit -m x'",
           "X=$(printf x y) printf %s ''*.py -c 'git commit -m x'"):
    check(f"589+ unaligned raw stream narrows nothing {_c[24:44]!r}",
          g.git_commit(_c)[0], True)
# An ESCAPED glob is a literal to bash too, but the raw spelling carries no
# quote, so it is not narrowed. Over-block, which is the safe direction; pinned
# so a future "improvement" that reads the escape has to face this row.
check("589+ escaped glob is not a quoted literal (over-block)",
      g.git_commit("X=$(printf x y) printf %s \\*.py -c 'git commit -m x'")[0],
      True)
# The provenance helper itself, at the boundary values the rows above depend on.
check("_quoted_literal(None) is False (fail-closed)", g._quoted_literal(None), False)
check("_quoted_literal single-quoted", g._quoted_literal("'*.py'"), True)
check("_quoted_literal double-quoted", g._quoted_literal('"*.py"'), True)
check("_quoted_literal concatenated is False", g._quoted_literal("'*'\".py\""), False)
check("_quoted_literal bare is False", g._quoted_literal('*.py'), False)
# PROPERTY SWEEP: quoting x concatenation x escaping x alignment.
#
# The invariant, stated once: the #589 narrowing fires IF AND ONLY IF the raw
# token stream aligns 1:1 with the posix one AND this token's own raw spelling
# is a single fully-quoted word. A bare glob, an escape, a concatenation, or a
# splice that breaks alignment must all leave the token fail-CLOSED.
#
# Expectations are HAND-WRITTEN from bash semantics, NOT derived from
# `_raw_tokens`/`_quoted_literal`. Deriving them from the production helpers is
# a tautology: a helper that wrongly accepted an unquoted or unaligned spelling
# would move the expectation and the verdict together, and the regression would
# still pass. The oracle below is the independent half of the test.
#
# `narrowed` is True only where bash itself performs no pathname expansion on a
# SINGLE whole word: one quote pair around the entire token. Concatenation,
# a bare suffix, an empty-quote splice and a backslash escape are all False --
# some are literals to bash too, but the scan cannot prove it from one aligned
# raw token, so the only safe answer is fail-CLOSED.
_SPELLINGS = (
    ("*.py",           False),   # bare glob -- really expands
    ("'*.py'",         True),    # single-quoted whole word
    ('"*.py"',         True),    # double-quoted whole word
    ("'*'\".py\"",     False),   # adjacent-quote concatenation
    ("'*'.py",         False),   # quoted prefix, bare suffix
    ("''*.py",         False),   # empty-quote splice
    ("\\*.py",         False),   # backslash escape
    ("'*.'py",         False),   # quoted prefix, bare tail
    ('"*"\'.py\'',     False),   # mixed-quote concatenation
)
for _sp, _narrowed in _SPELLINGS:
    # OPERAND position: assert the full biconditional against the oracle.
    _seg = f"X=$(printf x y) printf %s {_sp} -c 'git commit -m x'"
    check(f"589 prop operand {_sp!r} -> {'narrowed' if _narrowed else 'fail-closed'}",
          g.git_commit(_seg)[0], not _narrowed)
    # COMMAND position: assert only the fail-CLOSED half. A fully-quoted glob AS
    # the command word is the residual exclusion (see ADR 0045 Consequences), and
    # pinning it would pin a fail-open as expected -- so that combination is
    # deliberately left unasserted rather than fossilised.
    if not _narrowed:
        _cseg = f"X=$(printf x y) {_sp} -c 'git commit -m x'"
        check(f"589 prop cmd-word {_sp!r} stays fail-closed",
              g.git_commit(_cseg)[0], True)
    # Cross-check the PROVENANCE HELPERS against the same independent oracle, so
    # a helper that drifts is caught here rather than silently agreeing with a
    # derived expectation. This is an equality between two independently-obtained
    # values, not a restatement of one of them.
    _rawtoks = g._raw_tokens(_seg)
    _idx = next((_i for _i, _t in enumerate(g.toks_once(_seg))
                 if any(_c in _t for _c in '*?')), None)
    check(f"589 prov {_sp!r} raw/posix alignment + quote verdict",
          bool(_rawtoks is not None and _idx is not None
               and g._quoted_literal(_rawtoks[_idx])),
          _narrowed)
check("589+ bracket-class operand stays fail-closed",
      g.git_commit("X=$(printf x y) printf '%s' '[[:alpha:]]*' -c 'git commit -m x'")[0],
      True)
# The interpreter that a POSITIONAL narrowing would have suppressed. `./+` is
# unreadable as a command word, so the walk cannot vouch for it and the scan
# runs; if `./+` is a dispatcher (`exec "$@"`) the commit really does run. The
# branch that gated the scan on the walk's index returned False here. Fail-CLOSED
# is the only answer an unreadable command word can have.
check("589+ interpreter behind an unreadable command word stays fail-closed",
      g.git_commit("./+ bash -c 'git commit -m x'")[0], True)
# ACCEPTED-CURRENT, not a desired result. `bash` here is a printf ARGUMENT and
# nothing commits -- but after a tear the debris has destroyed argv position, so
# this is token-for-token indistinguishable from the `X=$(printf x y) bash -c
# '<s>'` row above, which DOES commit. Separating them needs the `$(`-span
# rebuild this file reverted after five verified bypasses. Pre-existing on main;
# costs a visible stall, never a bypass.
#
# RETIREMENT CONDITION: this row may flip to False only when every
# `torn-nested+` row above still returns True under the same change. Narrowing
# by command-word position does NOT qualify -- it fails six of them (measured).
# See docs/adr/0045-torn-assignment-any-position-recovery.md.
check("torn-nested~ (accepted-current) interpreter-named operand after a tear",
      g.git_commit("X=$(printf x y) printf '%s' bash -c 'git commit -m x'")[0],
      True)
# `.` (source) is a real command name with no word character, like `:` and `[`
# above. Misclassifying it as unreadable sent `. /dev/null bash -c 'git
# commit'` into the any-position fallback scan, which extracted `bash -c
# 'git commit'` as a live payload though the sourced (empty) /dev/null never
# runs its positional arguments (verified: bash/-c/git/commit are just $1..$4
# to a no-op sourced script). cubic-dev-ai #587.
check("readable-name~ (fixed) '. /dev/null bash -c git commit' does not run",
      g.git_commit(". /dev/null bash -c 'git commit'")[0], False)
# WAS an accepted limit (#587), now CLOSED (#593). The DIRECT route is recovered
# by _torn_direct_hits: `X=$(printf x y) git commit` really does run the commit
# (verified) and is now detected. What unblocked it was giving up on deriving
# scope rather than synthesizing an argv -- recovery reports the command with an
# unresolvable scope token, so the gates stall instead of acting on a guess.
_TORN_SCOPE = g._TORN_SCOPE
check("torn-direct (#593) sentinel value pinned", _TORN_SCOPE, '?torn-assignment')
for _c in ('X=$(printf x y) git commit -m x',      # #593 headline
           'X=$((1 + 2)) git commit -m x',         # arithmetic form
           'X=${foo:-a b} git commit -m x',        # brace form
           'A=1 X=$(printf x y) git commit -m x',  # tear at token 1, not token 0
           'X=$( gh pr list ) git commit -m x',    # decoy: bare gh before real git
           'X=$(printf x y) git -C /tmp commit',   # subcommand not adjacent to git
           'X=$(printf x y) /usr/bin/git commit'): # path-qualified target
    check(f"torn-direct (#593) detected {_c!r}", g.git_commit(_c)[0], True)
    # Scope MUST be reported unresolvable. An empty untrusted_cd here makes
    # resolve-repo-dir.sh ANCHOR the cwd repo and `proceed` (verified by
    # mutation), which would approve a torn commit against the wrong repo's
    # marker -- the one way this recovery could fail OPEN.
    check(f"torn-direct (#593) unresolvable {_c!r}",
          g.git_commit(_c, with_untrusted_cd=True)[3], _TORN_SCOPE)

# The same tear hides `gh pr merge` / `gh pr create` from the pre-merge and
# pre-PR gates; both are recovered through the same helper and the same
# _gh_find_pr_sub the normal path uses.
for _c, _sub in (('X=$(printf x y) gh pr merge 1', 'merge'),
                 ('X=$(printf x y) gh pr create', 'create')):
    check(f"torn-direct (#593) gh {_sub} {_c!r}", g.gh_pr(_c, _sub)[0], True)
    check(f"torn-direct (#593) gh {_sub} unresolvable {_c!r}",
          g.gh_pr(_c, _sub, with_untrusted_cd=True)[3], _TORN_SCOPE)

# The FALSE-POSITIVE floor. Recovery is subcommand-aware, which is what keeps it
# off these: a tear destroys argv position, so a rule that fired on "torn AND git
# present" would newly block all four of them (verified). Measured against 29,277
# recorded agent commands, the recovery newly detects ONE command -- an
# investigation probe that PRINTS `git commit` rather than running it -- so the
# delta on real workflow commands is ZERO, #587's own bar.
for _c in ('X=$(printf a b) git status',
           'X=${foo:-a b} git diff',
           'X=$(printf a b) git commit-graph write',   # plumbing, not `commit`
           'X=$(printf a b) git log --grep commit'):   # `commit` is an option value
    check(f"torn-direct (#593) no-FP {_c!r}", g.git_commit(_c)[0], False)

# PROPERTY sweep across the axes hand-picked rows kept missing. The product of
# {tear spelling} x {prefix position} x {target spelling} is what surfaced the
# fail-open where the torn VALUE contributes its own `git` token ahead of the
# real one: `X=$(printf git x) git commit` put a `git` in the command slot, the
# walk read `x)` as the subcommand, and the commit ran unseen (verified against
# bash -- the commit lands).
#
# 23 of the 24 prefix/tear combinations really do commit, each confirmed by
# running it against a scratch repo. The ONE that does not is
# `env X=${foo:-a b} git commit`: with `foo` unset the value splits, so env(1)
# takes the bare `b` as the utility to run and never reaches git. It is detected
# anyway -- the same accepted over-block as the echo-debris class, costing a
# visible stall and never a bypass -- so it is swept here rather than carved out,
# with the asymmetry recorded instead of papered over.
_TEARS = ('$(printf x y)', '$((1 + 2))', '${foo:-a b}', '$(printf git x)',
          '`printf x y`', '<(printf x y)')
_PREFIXES = ('X={t} ', 'A=1 X={t} ', 'X={t} Y={t} ', 'env X={t} ')
_GITS = ('git', '/usr/bin/git')
for _tear in _TEARS:
    for _pre in _PREFIXES:
        for _git in _GITS:
            _c = _pre.format(t=_tear) + _git + ' commit -m x'
            check(f"torn-direct (#593) sweep {_c!r}", g.git_commit(_c)[0], True)
            check(f"torn-direct (#593) sweep-scope {_c!r}",
                  g.git_commit(_c, with_untrusted_cd=True)[3], _TORN_SCOPE)
# Same sweep for the two gh subcommands, including the value-contributes-`gh`
# shape that hid `gh pr merge` from the pre-merge gate.
for _tear in ('$(printf x y)', '$(printf gh x)', '$((1 + 2))'):
    for _sub in ('merge', 'create'):
        _c = f'X={_tear} gh pr {_sub} 1'
        check(f"torn-direct (#593) gh sweep {_c!r}", g.gh_pr(_c, _sub)[0], True)

# The debris spells a COMPLETE command, so the ordinary walk "succeeds" and would
# report the CWD as scope -- while bash commits somewhere else entirely. Verified
# against two scratch repos: the commit lands in the `-C` directory and the cwd
# repo gets nothing, so a gate trusting that scope validates the wrong repo's
# marker. This is why recovery runs BEFORE the walk rather than only after it
# fails, and why a tear forces the unresolvable scope even on an apparent match.
check("torn-direct (#593) debris spells a command, scope must not be cwd",
      g.git_commit('X=$(printf git commit x) git -C /tmp commit -m x',
                   with_untrusted_cd=True)[3], _TORN_SCOPE)
check("torn-direct (#593) debris spells gh pr merge, scope must not be cwd",
      g.gh_pr('X=$(printf gh pr merge x) env GH_REPO=other/repo gh pr merge 1',
              'merge', with_untrusted_cd=True)[3], _TORN_SCOPE)
# One result per command word: recovery must not ALSO fall through to the normal
# walk, or gh_pr_count double-counts and the pre-merge gate's multi-PR refusal
# reads an inflated number.
check("torn-direct (#593) recovery does not double-count",
      g.gh_pr_count('X=$(printf x y) gh pr merge 1', 'merge'), 1)

# The sentinel must SURVIVE the nested-payload fold. _gh_scan_nested used to
# rebuild this field from the cd list alone, discarding the scanner's verdict, so
# a torn command inside `bash -c` came back with an EMPTY scope and the gate
# anchored the cwd repo while the payload targeted another (verified). The git
# sibling always folded r[3] in; these pin that the two now agree.
for _c, _sub in (("bash -c 'X=$(printf x y) gh pr merge 1'", 'merge'),
                 ("bash -c 'X=$(printf x y) gh pr create'", 'create'),
                 ("bash -c 'X=$(printf gh pr merge x) env GH_REPO=o/r gh pr merge 1'",
                  'merge')):
    check(f"torn-direct (#593) nested keeps scope {_c!r}",
          g.gh_pr(_c, _sub, with_untrusted_cd=True)[3], _TORN_SCOPE)
check("torn-direct (#593) nested git keeps scope",
      g.git_commit("bash -c 'X=$(printf x y) git commit -m x'",
                   with_untrusted_cd=True)[3], _TORN_SCOPE)
# ...and must NOT appear on untorn nested/cd forms, which keep their real scope.
check("torn-direct (#593) untorn cd keeps trusted scope",
      g.gh_pr('cd /other && gh pr merge 1', 'merge', with_untrusted_cd=True)[1],
      '/other')
check("torn-direct (#593) untorn gh no sentinel",
      g.gh_pr('gh pr merge 1', 'merge', with_untrusted_cd=True)[3], '')

# PROPERTY-BASED generation, on top of the fixed sweep above. The sweep can only
# cover combinations someone thought to list, which is exactly how the first
# fail-open survived hand-picked rows. This composes the axes randomly instead --
# quoting, wrapper words, substitution spelling, extra assignments, token
# boundaries -- and asserts the two invariants that must hold for EVERY torn
# command carrying a real `git commit` tail:
#     (1) it is detected, and
#     (2) its scope is unresolvable, never a fabricated directory.
# Not every generated combination actually reaches git -- `env X=${foo:-a b} …`
# splits and env(1) runs the bare `b` instead -- and those are asserted detected
# too, under the same accepted over-block documented above: a visible stall is
# the safe direction here, a fabricated scope is not.
# Seeded, so a failure is reproducible and CI does not flap.
import random as _rnd
_r = _rnd.Random(20260811)
_TEAR_ATOMS = ('$(printf x y)', '$((1 + 2))', '${foo:-a b}', '`printf x y`',
               '<(printf x y)', '$(printf git x)', '$(printf git commit x)',
               '$(echo a b)', '${bar:-git commit}')
_WRAPPERS = ('', 'env ', 'command ', 'nice -n 5 ', 'env -i ', 'sudo -n ')
_ASSIGNS = ('', 'A=1 ', "Q='a b' ", 'A+=1 ', 'A[0]=1 ')
_TAILS = ('git commit -m x', 'git commit --amend', '/usr/bin/git commit -m x',
          'git -C /tmp commit -m x', 'git -c user.name=x commit -m x')
for _i in range(400):
    _cmd = (_r.choice(_WRAPPERS) + _r.choice(_ASSIGNS)
            + 'X=' + _r.choice(_TEAR_ATOMS) + ' '
            + (('Y=' + _r.choice(_TEAR_ATOMS) + ' ') if _r.random() < 0.3 else '')
            + _r.choice(_TAILS))
    _res = g.git_commit(_cmd, with_untrusted_cd=True)
    check(f"torn-direct (#593) property[{_i}] detected {_cmd!r}", _res[0], True)
    check(f"torn-direct (#593) property[{_i}] unresolvable {_cmd!r}",
          _res[3], _TORN_SCOPE)

# Torn-direct amend-ness is read from the OPTION portion only (#634 cubic
# review), matching the untorn scan path's `opt_words` derivation: a literal
# `--amend` pathspec token after `--` must NOT flip is_amend, and a real
# `--amend` before `--` must still be detected.
check("torn-direct (#593) amend pathspec-scoped not flagged",
      g.git_commit("X=$(printf x y) git commit -m m -- --amend",
                   with_untrusted_cd=True)[2], False)
check("torn-direct (#593) amend before -- still detected",
      g.git_commit("X=$(printf x y) git commit --amend -- f",
                   with_untrusted_cd=True)[2], True)

# UNIFORM RULE (#634): a tear means the scope is unknowable, with no exemption.
# `_torn_assignment` is presence-based, so an INTACT `TAG=$(git describe)` reads
# as torn and these stall. That over-fire was reviewed hard, and an exemption --
# "if the only `git` is the one the walk stopped on, nothing was hidden, so trust
# the walk" -- was tried and REMOVED: its premise fails whenever the landing is
# itself inside the substitution, and four shapes defeated it (dynamic command
# word, interpreter payload, real command in a later segment, forged in-token
# close), each reporting a cd scope for a commit running elsewhere. Guarding them
# one at a time is the per-case table #587 exists to stop building. These pin the
# accepted cost so the exemption is not reintroduced.
for _c in ('cd /tmp && X=$(true) git commit -m x',
           'X=$(true) git -C /tmp commit -m x',
           'cd /tmp && TAG=$(git describe) git commit -m x',
           'cd /tmp && D=$(date +%s) git commit -m x',
           'cd /tmp && X=${HOME} git commit -m x',
           'cd /tmp && H="$(git rev-parse HEAD)" git commit -m x'):
    check(f"torn-direct (#634) tear ⇒ unknowable scope {_c!r}",
          g.git_commit(_c, with_untrusted_cd=True)[3], _TORN_SCOPE)
# The four shapes that killed the exemption. Each must stay blocked; a future
# re-introduction would flip these to a cd scope while the commit runs elsewhere.
for _c in ('G=git; cd /tmp && X=$(printf git commit x) $G -C /x commit -m x',
           'cd /tmp && X=$(printf git commit x) bash -c "git -C /x commit -m x"',
           'cd /tmp && X=$(printf git commit x) true; git -C /x commit -m x',
           'X=$(printf git commit x) git -C /tmp commit -m x'):
    check(f"torn-direct (#634) exemption-killer stays blocked {_c!r}",
          g.git_commit(_c, with_untrusted_cd=True)[3], _TORN_SCOPE)


# DIRECTION LOCK. Every command below was a silent fail-OPEN on main — verified
# against the pre-#593 path, all NOT-DETECTED, so the commit ran unseen by all
# three gates. That is the #593 bug. They must now be DETECTED with an
# unresolvable scope (a visible stall). The failure this pins is a future
# "optimization" that widens the walk_index exemption until these resolve to the
# CWD instead — which would silently restore the fail-open, since the gate would
# then validate the current repo's marker for a commit whose repo is unknown.
# `$( date )` is in the list deliberately: it carries no inner git at all, and
# was ALSO missed before, so its stall is likewise a gain and not collateral.
for _c in ('cd /tmp && TAG=$(git describe --tags) git commit -m x',
           'cd /tmp && H=$(git rev-parse HEAD) git commit -m x',
           'cd /tmp && BR=$(git rev-parse --abbrev-ref HEAD) git commit -m x',
           'cd /tmp && U=$(git config user.name) git commit -m x',
           'cd /tmp && X=<(git rev-parse HEAD) git commit -m x',
           'cd /tmp && TAG=$( git describe ) git commit -m x',
           'cd /tmp && TAG=$( date ) git commit -m x'):
    check(f"torn-direct (#634) tearing substitution detected {_c!r}",
          g.git_commit(_c)[0], True)
    check(f"torn-direct (#634) tearing substitution stalls {_c!r}",
          g.git_commit(_c, with_untrusted_cd=True)[3], _TORN_SCOPE)
# Amend-ness across a TORN stream. Each candidate's window is bounded by the
# next candidate and the results OR-ed, so a `--` inside DEBRIS cannot truncate
# the scan and hide a real amendment (#634), while a genuine post-`--` pathspec
# still reads as a pathspec rather than the flag.
check("torn-direct (#634) debris `--` does not hide a real amend",
      g.git_commit('X=$(printf git commit -- x) git commit --amend')[2], True)
check("torn-direct (#634) torn amend still detected",
      g.git_commit('X=$(printf x y) git commit --amend')[2], True)
check("torn-direct (#634) post-`--` amend is a pathspec, not the flag",
      g.git_commit('X=$(printf x y) git commit -m m -- --amend')[2], False)
# Windows are bounded at the next COMMIT start, not the next `git` TOKEN: an
# argument value can be the word `git`, and cutting there truncated the window
# before the real flag.
check("torn-direct (#634) `-m git` argument does not truncate the amend window",
      g.git_commit('X=$(printf x y) git commit -m git --amend')[2], True)

# A DYNAMIC command word is one of the shapes that DEFEATED the removed
# exemption attempt (see gitcmd_detect.py `_torn_direct_hits`): it would have
# claimed the walk's landing IS the executed command, and `$G` can be
# anything. In `X=$(printf git commit x) $G -C /x commit` the only literal
# `git` is substitution debris while `$G` runs the real commit in /x. The
# uniform rule reports it unresolvable instead.
check("torn-direct (#634) dynamic command word reports _TORN_SCOPE",
      g.git_commit('G=git; cd /tmp && X=$(printf git commit x) $G -C /x commit -m x',
                   with_untrusted_cd=True)[3], _TORN_SCOPE)
# An interpreter payload is another shape that defeated the removed exemption:
# `X=$(printf git commit x) bash -c "git -C /x commit"` has every token static
# while the real commit executes in /x.
check("torn-direct (#634) interpreter payload reports _TORN_SCOPE",
      g.git_commit('cd /tmp && X=$(printf git commit x) bash -c "git -C /x commit -m x"',
                   with_untrusted_cd=True)[3], _TORN_SCOPE)
check("torn-direct (#634) interpreter payload reports _TORN_SCOPE (gh)",
      g.gh_pr('cd /tmp && X=$(printf gh pr merge x) bash -c "gh pr merge 1"',
              'merge', with_untrusted_cd=True)[3], _TORN_SCOPE)
# gh_pr_count feeds the pre-merge gate's multi-PR refusal, so the torn recovery
# must yield ONCE per segment (#634 review). A segment IS one command, so every
# candidate past the first is debris -- either tear content or an argument
# VALUE -- and yielding it turns a single merge into a spurious multi-PR block.
# Yielding all candidates reported 2 for both of the next two cases.
check("torn-direct (#634) `gh` inside an argument value does not inflate the count",
      g.gh_pr_count('X=$(printf x y) gh pr merge 1 --body gh pr merge 2',
                     'merge'), 1)
check("torn-direct (#634) `gh pr merge` inside the TEAR does not inflate the count",
      g.gh_pr_count('X=$(printf gh pr merge x) gh pr merge 1', 'merge'), 1)
# ...while genuinely separate invocations, which need separate SEGMENTS, still
# both count. This one passes under either policy; it is here so the pair above
# cannot be "fixed" by disabling torn recovery wholesale.
check("torn-direct (#634) two torn merges in two segments count 2",
      g.gh_pr_count('X=$(printf gh) gh pr merge 1; Y=$(printf gh) gh pr merge 2',
                     'merge'), 2)
# The plain dynamic form (no tear) stays undetected — a separate, pre-existing
# limit of this parser, pinned so the two are never conflated.
check("dynamic command word alone is undetected (pre-existing limit)",
      g.git_commit('G=git; cd /tmp && $G commit -m x')[0], False)

# The documented ESCAPE must stay clean, or the workaround rots unnoticed.
# QUOTING is NOT an escape and is pinned as such above: `H="$(…)"` collapses to
# one token but still carries `$(`, which is all `_torn_assignment` reads.
# Splitting leaves the cd UNTRUSTED (the `;` does not '&&'-gate the commit), so
# untrusted_cd is the operand '/tmp' rather than empty — the resolver then proves
# same-repo or blocks. What matters for the escape is only that it is not the
# torn sentinel, which no amount of repo-proving can clear.
check("torn-direct (#634) splitting the segment escapes the stall",
      g.git_commit('cd /tmp && H=$(git rev-parse HEAD); git commit -m x',
                   with_untrusted_cd=True)[3] == _TORN_SCOPE, False)

# Untorn forms must be UNTOUCHED -- same verdict AND same scope as before, so the
# recovery cannot quietly convert a resolvable commit into a stall.
check("torn-direct (#593) untorn keeps scope",
      g.git_commit('git -C /tmp commit -m x', with_untrusted_cd=True)[1], '/tmp')
for _c in ("X=1 git commit -m x", "X='a b' git commit -m x"):
    check(f"torn-direct (#593) untorn no sentinel {_c!r}",
          g.git_commit(_c, with_untrusted_cd=True)[3], '')

# `--` ENDS a wrapper's option processing, so the token after it is an OPERAND,
# never an option argument. Leaving the arity guess on swallowed the real
# utility: `env -- printf A-B=1 bash -c '<s>'` read `printf` as `--`'s value, so
# argv[0] became `bash` and a payload came out of a command that only PRINTS
# (verified) -- a false positive in three fail-CLOSED gates.
for _c in ('env -- printf A-B=1 bash -c "git commit"',
           'env -- A=1 printf bash -c "git commit"',
           # ...and a dash-prefixed OPERAND after `--` is not an option either:
           # env tries to EXECUTE `-i` and fails ("No such file or directory",
           # verified), so nothing behind it runs.
           'env -- -i bash -c "git commit"'):
    check(f"dashdash- {_c!r}", g.git_commit(_c)[0], False)
# ...while an operand that really IS the utility still resolves, and assignment
# operands after `--` keep working -- only the arity guess was dropped.
for _c in ('env -- bash -c "git commit"',
           'env -- A=1 bash -c "git commit"'):
    check(f"dashdash+ {_c!r}", g.git_commit(_c)[0], True)

# ACCEPTED OVER-WARN, pinned so the trade stays visible: `_torn_assignment` asks
# whether a value contains substitution syntax AT ALL, reading the DEQUOTED
# token, so a quoted literal opener reads as a tear. `X="$(" echo bash -c ...`
# is therefore recovered and reports a commit that only `echo` prints. Restoring
# quote provenance means the delimiter counting this file abandoned after it
# produced five verified bypasses -- more defects than the bug it fixed. The
# direction of harm decides it: this over-warn stalls a gate VISIBLY, where the
# alternative reading lets an unreviewed commit through SILENTLY.
check('quoted-opener~ (accepted) X="$(" echo bash -c',
      g.git_commit('X="$(" echo bash -c "git commit"')[0], True)

# An EXPANSION can be the command word even though it contains an `=`. The env(1)
# operand rule is the loose `^[^=]+=`, with no identifier rule, so it also matched
# `${X:=bash}` and skipped it as an assignment -- while bash, with X unset,
# expands it to bash and runs the payload (verified). Only a loose match this
# scan can READ is skipped now; an unreadable one stays a candidate.
check("assign-default expansion is a command word",
      g.git_commit('${X:=bash} -c "git commit -m x"')[0], True)

# ACCEPTED OVER-WARN, the FAMILY -- pinned so the trade stays visible rather than
# being rediscovered one member at a time. Present in this change's first draft
# and unchanged by any hardening since; both are verified to execute NOTHING:
#   env -u bash -c 'echo RAN'                 -> env prints its usage
#   command -p X=$(true) echo bash -c 'echo RAN' -> "command not found: X="
# Both still report a commit, for two reasons the file has already settled:
#   1. wrapper-option arity is undecidable statically, so BOTH readings are taken
#      and unioned -- the reading that protects `bash` from being eaten by `-i`
#      is the same one that mistakes `-u`'s argument for the utility;
#   2. `_torn_assignment` asks only whether a value contains substitution syntax,
#      because counting delimiters needs quote provenance shlex has dropped.
# Answering either precisely means the delimiter/arity grammar this file
# abandoned after two review rounds produced five verified bypasses in it -- more
# defects than the single bug it fixed. The direction of harm settles it: these
# stall a gate VISIBLY on shapes that do not occur in practice (measured: zero
# newly-tripped fail-CLOSED gates across 29,563 recorded agent commands), where
# the precise-parsing alternative lets an unreviewed commit through SILENTLY.
for _c in ('env -u bash -c "git commit"',
           'command -p X=$(true) echo bash -c "git commit"'):
    check(f"nonexec-prefix~ (accepted) {_c!r}", g.git_commit(_c)[0], True)

# An OPTION is not an option's ARGUMENT. Stacked wrapper options collapsed
# without that: `env -i -u FOO bash -c '<s>'` read `-u` as the value of `-i`, so
# both readings stopped on the readable word `FOO`, the any-position fallback
# stayed gated off, and the payload was missed. Verified against main, which
# DOES detect this -- the option-argument branch introduced the fail-OPEN, so
# this is a regression guard, not a new capability.
for _c in ('env -i -u FOO bash -c "git commit -m x"',
           'env -i -u FOO -u BAR bash -c "git commit -m x"',
           'sudo -n -u nobody bash -c "git commit -m x"',
           # `--` is the ONE dash-token that is a legitimate option ARGUMENT:
           # `env -u -- -i bash -c '<s>'` really does run the child (verified),
           # and reading its `--` as the option terminator left `-i` looking
           # like the command word -- the same fail-OPEN, one spelling over.
           'env -u -- -i bash -c "git commit -m x"'):
    check(f"stacked-opt+ {_c!r}", g.git_commit(_c)[0], True)
# ...while a `--` that really IS the terminator still ends option parsing, so
# env tries to EXECUTE `-i` and nothing behind it runs.
check('stacked-opt- env -- -i is a terminator',
      g.git_commit('env -- -i bash -c "git commit"')[0], False)
# The DUAL, pinned because it is the same undecidable position. `-x` here is
# `-u`'s OPERAND -- a variable literally named `-x` -- so only echo runs
# (verified: it prints `git commit -m x`). Reading it as an operand instead
# would fix this over-warn and reopen the `env -i -u FOO` fail-OPEN above: the
# same token, and no reading answers both. main reports it too, so this is
# neither new nor a regression, and over-detection is the direction this file
# has always taken -- a stuck session beats a skipped review.
check("stacked-opt~ (accepted, matches main) env -u -x echo",
      g.git_commit('env -u -x echo git commit -m x')[0], True)

# A real executable name may carry punctuation the debris test rejects. `c++` and
# `g++` are ordinary programs, so calling their argv[0] unreadable said the walk
# was lost and recovered a payload that the compiler never runs. `+` is in the
# name class now, but a token made ONLY of punctuation is still refused -- a bare
# `+` is precisely the debris shlex leaves when it tears `X=$((1 + 2))`, and the
# fallback gate depends on rejecting it.
for _c in ('c++ bash -c "git commit"',
           'g++ bash -c "git commit"',
           '/usr/bin/c++ bash -c "git commit"'):
    check(f"readable-name- {_c!r}", g.git_commit(_c)[0], False)
for _t, _want in ((':', True), ('[', True), ('.', True), ('c++', True), ('/usr/bin/c++', True),
                  ('+', False), ('2))', False), ('b}', False), ('y)', False),
                  ('-', False), ('--', False), ('..', False)):
    check(f"readable-name unit {_t!r}", bool(g._READABLE_NAME.match(_t)), _want)

# KNOWN LIMIT: an `eval` behind speculative debris is missed. The subset
# argument that justifies keeping only the earliest candidate holds for an
# interpreter but NOT for eval, which joins every following token into one
# payload -- so with `foo` unset the first command below runs the commit unseen.
# Promoting the first LITERAL `eval` as a second candidate was tried and
# REVERTED: `eval` is an ordinary ARGUMENT too, and the second command below
# then reported a commit that printf only PRINTS (verified: it prints
# `evalecho RAN`). The miss is pre-existing on main; the false block would have
# been new, and a new false block in three fail-CLOSED gates is worse.
check("eval~ (known limit) speculative shadows literal",
      g.git_commit('X=$(printf %s $foo bar baz) eval "git commit -m x"')[0], False)
check("eval- an eval ARGUMENT is not a command word",
      g.git_commit('X=$(printf %s $foo bar baz) printf %s eval "git commit -m x"')[0], False)

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
