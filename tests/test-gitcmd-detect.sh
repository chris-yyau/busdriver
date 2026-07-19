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
    "cat <<'EOF'\ngit \\\ncommit\nEOF",
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
