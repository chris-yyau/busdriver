"""Fixture data for cmdword.py's `_demo()` self-check (#519 item 4).

Split out of cmdword.py so the classifier module itself stays under CodeScene's
Lines-of-Code health threshold: these ~90 lines are pure string-literal test
fixtures with no control flow of their own, imported lazily by `_demo()` only
(never by the production import path `from cmdword import is_file_mod`), so
this file's presence or absence cannot affect the gate's classification logic
-- only `python3 hooks/gate-scripts/lib/cmdword.py` (the self-check entry
point) needs it importable.
"""

# Commands the classifier must ALLOW (read-only, or a verb name appearing only
# as plain data / a defined function name -- the #519 false-positive class).
DEMO_ALLOWED = [
    "grep -nE 'rm |mv |truncate' script.sh",
    # Verbs as plain DATA in a read-only command — the class that made an
    # all-token scan untenable.
    "grep dd notes.txt",
    "echo rmdir",
    "echo cp this line",
    "git log --oneline | grep rm",
    # Keywords that introduce a NAME, and wrapper names used as plain data.
    "function mv { echo harmless; }",
    "for rm in a b; do echo hi; done",
    "case rm in x) echo hi;; esac",
    "grep sudo rm",
    "printf sudo rm",
    "echo find -delete",
    "echo sed -i",
    # Test-expression operands are data, never commands.
    "[[ rm = value ]]",
    "[[ -f rm ]]",
    "[ -f rm ]",
    # #519 false positive 3: a probe DEFINING functions named mv / [.
    "mv() { echo harmless; }",
    "rm () { echo harmless; }",
    "mv() { echo hi; } ; ls",
    'bash -c \'echo "T3 (mv FAILS): ..."\'',
    "ls -la",
    "sed -n '1,10p' file.txt",
    "grep -i sed notes.txt",
    "echo 'cp this line'",
    "git log --oneline | head -20",
    # The other side of the `watch` branch: recursing its payload must not turn a
    # read-only monitor into a write. `watch` as plain DATA stays inert too.
    "watch -d ls -la",
    "watch 'git status'",
    "watch -n 5 df -h",
    "echo watch rm -rf src",
]

# Commands the classifier must BLOCK (real writes, including ones reached only
# through a runner, wrapper, dispatcher, or embedded shell string).
DEMO_BLOCKED = [
    "rm -rf src",
    "sudo rm -rf src",
    "env FOO=1 rm x",
    "nohup mv a b",
    "sed -i 's/a/b/' f",
    "sed -i.bak 's/a/b/' f",
    "cat x | tee out.txt",
    "cp a b",
    "ls && rm x",
    "echo hi > f ; mv f g",
    "xargs rm < list.txt",
    # Executed-string operands — these are the shapes tokenization alone would
    # reduce to inert single tokens. Each was a live fail-open before recursion.
    "bash -c 'rm -rf src'",
    "sh -c \"rm -rf src\"",
    "sudo bash -c 'rm x'",
    "bash -lc 'rm x'",
    "eval 'rm -rf src'",
    'echo "$(rm -rf src)"',
    "echo `rm -rf src`",
    "bash -c 'bash -c \"rm x\"'",
    # Quote-aware paren matching: a `(` inside quotes must not unbalance the scan.
    "echo \"$(printf '('; rm x)\"",
    "echo \"$(printf ')'; rm x)\"",
    # Flag bundles that still execute a command string.
    "bash -cl 'rm x'",
    "sh -ce 'rm x'",
    # A single quote is literal INSIDE double quotes, so this substitution runs.
    "echo \"'$(rm x)'\"",
    # env -S splits its operand into an argv and executes it.
    "env -S 'rm -rf x'",
    "env -S'rm -rf x'",
    "truncate -s 0 notes.txt",
    "unlink notes.txt",
    "rmdir stale.d",
    "dd if=/dev/null of=notes.txt",
    "find . -exec rm {} ;",
    "find . -delete",
    "timeout 5 rm x",
    "echo hi | xargs rm",
    # Wrapper flag operands and shell reserved words: stopping the peel at the
    # first plausible token returned `root`, `{` and `then` here, allowing the write.
    "sudo -u root rm -rf src",
    "{ rm -rf src; }",
    "if true; then rm -rf src; fi",
    "sudo sed -i 's/a/b/' f",
    # Launchers/keywords that run a following command. Each was a fail-open while
    # the list here was narrower than the forge detector's.
    "coproc rm src/x",
    "caffeinate rm src/x",
    "su -c 'rm src/x'",
    "function f { rm src/x; }; f",
    "find . -exec sudo rm {} ;",
    "runuser --command='rm src/x' root",
    # coproc behind a reserved word, and a WRAPPED -exec payload.
    "if true; then coproc rm x; fi",
    "{ coproc rm x; }",
    "function f { coproc rm x; }; f",
    "find . -exec sudo -u root rm {} ;",
    "sudo env -S 'rm x'",
    "sudo -u root bash -c 'rm x'",
    # An -exec payload can run a shell, or be an in-place sed.
    'find . -exec sh -c \'rm "$1"\' _ {} ;',
    "find . -exec sudo sed -i 's/a/b/' {} ;",
    'function f { sh -c "rm x"; }',
    '{ sh -c "rm x"; }',
    "env --split-string='rm x'",
    "env --split-string 'rm -rf src'",
    # `watch` joins its non-option arguments and runs them through sh -c, so the
    # QUOTED spelling arrives as one token that matches no verb name -- the shape a
    # token scan alone cannot see. The option spellings below are the regression that
    # matters: the payload must be found WITHOUT locating the command start, because
    # every attempt to locate it needs an option-arity table and each gap in that
    # table fails OPEN. --shotsdir and --equexit are the ones that broke the first
    # draft; the point is that an option this list has never heard of behaves the same.
    "watch 'rm -f src/file'",
    "watch rm -f src/file",
    "watch -n 1 'rm -f src/file'",
    "watch -n1 'rm -f src/file'",
    "watch -dn 1 'rm -f src/file'",
    "watch --interval=1 'rm -f src/file'",
    "watch --shotsdir logs 'rm -f src/file'",
    "watch -s logs 'rm -f src/file'",
    "watch --equexit 5 'rm -f src/file'",
    "watch --some-future-option val 'rm -f src/file'",
    "watch --shotsdir logs 'git clean -fd'",
    "watch -s logs 'find . -delete'",
    # -x/--exec bypasses the shell; scanning the payload anyway is the documented
    # over-read, and it must keep blocking.
    "watch -x rm -f src/file",
    # `--` is NOT honoured as sed's option terminator, because deciding whether it is
    # an option operand needs the same arity table. Here it IS -f's operand, so the
    # `-i` behind it is a live in-place write.
    "sed -f -- -i file",
]
