"""Token-level file-modification classifier for the pre-implementation gate (#519 item 4).

WHY THIS EXISTS
The gate used to decide "does this Bash command modify files?" by running regexes
(r"\\bmv\\s", r"\\brm\\s", ...) against the RAW command string. `re.search` matches
anywhere, including inside quoted operands, so three read-only commands were blocked
in a single session:

    grep -nE 'rm |mv |truncate' script.sh    # the SEARCH PATTERN contains "rm "/"mv "
    bash -c 'echo "T3 (mv FAILS): ..."'      # an ECHO LABEL contains "mv "
    mv() { ...; }                            # a shell FUNCTION NAME

That matters beyond annoyance: the workaround is to reword until the regex stops
matching, which trains exactly the bypass reflex the gate exists to suppress.

WHAT CHANGES
Segment the command on unquoted control operators, tokenize each segment with shlex,
then compare token BASENAMES for EQUALITY against the verb set. A verb that appears
only inside a quoted string survives tokenization as ONE token (`rm |mv |truncate`),
which equals no verb. A verb in a real argument position is its own token and still
matches — so `sudo rm -rf src`, `env FOO=1 rm x`, and `nohup mv a b` stay blocked.
Scanning ALL tokens rather than a pinned command-word position is deliberate and
mirrors _scan_segment's rm/tee handling in pre-implementation-gate.sh: a wrapper
preamble must not be able to hide the verb.

FAILURE MODE IS TODAY'S BEHAVIOR, NOT MORE BLOCKING
On an unparseable command (unbalanced quote, dangling escape — the common shape is an
apostrophe in heredoc prose, see #365) this falls back to the original regexes. The
regexes are strictly WIDER than the token scan, so the fallback blocks at least as
much as before: fail-CLOSED is preserved, and a parse failure can never make this
change over-block relative to the code it replaces.

NOT SHARED WITH THE MARKER-FORGE DETECTOR
pre-implementation-gate.sh carries its own inline copy of _split_simple_commands for
the anti-forge guard. That detector answers a different question (does any token in
this segment NAME a gate marker), is the ADR 0006 security boundary, and has its own
regression suite. Unifying them would mean a large diff across that boundary to remove
a duplication that currently costs nothing. Unify if they ever need to change together
— not speculatively.
"""

import re
import shlex

_SQ = chr(39)
_DQ = chr(34)

# The original patterns, kept verbatim as the unparseable-command fallback.
FILE_MOD_PATTERNS = [
    r"\bsed\s+-i",
    r"\btee\s",
    r"\bpatch\s",
    r"\bcp\s",
    r"\bmv\s",
    r"\brm\s",
    r"\bln\s",
    r"\binstall\s",
    # #519 additions must appear here too. This list is the UNPARSEABLE-command
    # fallback, so a verb missing from it fails OPEN on exactly the inputs the token
    # scan cannot judge — e.g. `dd if=/dev/zero of=src/x <<EOF` with an apostrophe in
    # the heredoc body would parse-fail and then classify as read-only.
    r"\btruncate\s",
    r"\bunlink\s",
    r"\brmdir\s",
    r"\bdd\s",
    # `git` WHOLE, not per-subcommand: this list stands in for the token classifier
    # when a command cannot be parsed, so it has to be WIDER than that classifier --
    # which blocks `git clean -fd`, `git restore .` and every unknown subcommand.
    r"\bgit\s",
    # A verb at END OF STRING (`echo hi | xargs rm`) and find -delete. The `\s` in
    # every pattern above requires something to follow the verb, and -delete names
    # no verb at all, so the classifier blocked both while this list allowed them.
    r"\b(?:tee|patch|cp|mv|rm|ln|install|truncate|unlink|rmdir|dd)$",
    r"-delete\b",
]

# Verbs that modify files by themselves. `sed` is absent — it only modifies with -i,
# and is handled separately below so a read-only `sed -n ...` stays allowed.
# truncate/unlink were in NEITHER the old regexes nor the first cut of this module, so
# `truncate -s 0 f` classified as a read. Token equality makes them safe to add: the
# `grep -nE 'rm |mv |truncate'` case from #519 keeps its pattern as ONE token.
_MOD_VERBS = frozenset(("tee", "patch", "cp", "mv", "rm", "ln", "install",
                        "truncate", "unlink", "rmdir", "dd"))

# Commands whose behaviour is decided by a SUBCOMMAND rather than by the command word.
#
# THE LIST IS OF READS, NOT OF WRITES. Listing the writing subcommands was tried and is
# an allowlist in a fail-CLOSED gate: anything unrecognised reads as safe, so a shell
# alias (`git -c alias.nuke="!rm -rf src" nuke`), an external `git-<helper>` on PATH, and
# a redirection token landing where the subcommand was expected all sailed through.
# Inverted, the unknown case blocks, which is the direction this gate exists to fail in.
# The cost is that a genuinely read-only subcommand missing from the list over-blocks --
# visible, and fixed by adding one name.
#
# THE OPTION LISTS ARE OF INERT OPTIONS, FOR THE SAME REASON. Listing the dangerous ones
# was tried too, and every round of review found another: `--output`, then `-c`, then
# `--paginate`, then `--textconv` and `--filters`, then the joined short `-ccore.x=y` that
# no exact match catches. Git's exec surface is config-driven and unbounded -- pager,
# external diff, textconv, clean/smudge filters, aliases, difftool, credential and ssh
# helpers -- so no list of dangerous spellings can ever be finished. Listing what is INERT
# terminates: an unrecognised option means the command is not cleared, and a genuinely
# harmless option missing from the list over-blocks visibly and is fixed by adding a name.
#
# The lists are split by REGION because the same spelling means different things either
# side of the subcommand: `-p` before it is `--paginate` (runs the configured pager),
# after it is `--patch`; `-c` before it injects config, after it is `git grep --count`.
#
# BOUNDARY, accepted deliberately: this judges what the COMMAND does, not what the
# repository is ALREADY configured to do. A clean/smudge filter in .gitattributes, a
# pre-commit hook, an fsmonitor hook or a `core.pager` in .git/config all run programs
# during a nominally read subcommand, and no option inspection sees them. Blocking every
# git command instead would take `git status` and `git diff` away for the whole time a
# review is pending without closing the class -- any program on the line could equally
# be a wrapper for a configured hook. What keeps this a boundary rather than a hole is
# that ARRANGING that configuration is itself a write this gate blocks: `git config` is
# not a read, and writing .gitattributes, .git/config or .git/hooks/* is a file
# modification by redirect or by verb.
#
# `argflags` are the global options taking a SEPARATE operand, so the operand is not
# mistaken for the subcommand (`git -C repo rm x`).
_DISPATCHERS = {
    "git": {
        "reads": frozenset((
            # Inspection.
            "status", "log", "show", "blame", "annotate", "grep", "shortlog",
            "reflog", "whatchanged", "describe", "cherry", "range-diff",
            "diff", "diff-tree", "diff-index",
            "ls-files", "ls-tree", "ls-remote", "cat-file", "for-each-ref",
            "count-objects", "rev-parse", "rev-list", "merge-base", "name-rev",
            "symbolic-ref", "var", "help", "version", "fsck",
            "verify-pack", "verify-commit", "verify-tag",
            "check-ignore", "check-attr", "check-ref-format", "check-mailmap",
            # Ref/index/remote plumbing that does not touch working-tree FILES, which is
            # the only thing this classifier judges.
            "add", "commit", "push", "fetch", "remote", "branch", "tag",
            "gc", "prune", "repack", "maintenance", "notes", "update-ref",
            # NOT `init`: `git init src/generated` creates a directory tree and files
            # under a path it takes as a plain operand.
            # NOT `config`, `bundle` or `archive`: each takes a destination path as a
            # plain operand (`git config --file src/x k v`, `git bundle create src/x`),
            # so they write working-tree files without matching any writeflag. A read
            # subcommand has to be read-only in EVERY mode, not just its common one.
            # NOT `difftool`/`mergetool` either: running a configured external program IS
            # what they are for, so no flag inspection can make them read-only.
        )),
        # Global options that neither name a program nor write a file. NOT `-c`,
        # `--config-env`, `--exec-path`, `-p`/`--paginate`.
        "globalopts": frozenset((
            "-C", "--git-dir", "--work-tree", "--namespace", "--no-pager", "-P",
            "--bare", "--no-replace-objects", "--no-optional-locks",
            "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
            "--icase-pathspecs", "--version", "--help",
        )),
        # Subcommand options that only shape or select output. NOT `-o`/`--output`
        # (writes a file), NOT `--ext-diff`/`--textconv`/`--filters`/`--extcmd`/`--tool`/
        # `--exec`/`--upload-pack`/`--receive-pack`/`-O` (each runs a configured program).
        "subopts": frozenset((
            # Shaping.
            "-p", "--patch", "-u", "--stat", "--numstat", "--shortstat", "--dirstat",
            "--summary", "--raw", "--name-only", "--name-status", "--oneline",
            "--graph", "--decorate", "--no-decorate", "--abbrev", "--abbrev-commit",
            "--no-abbrev-commit", "--pretty", "--format", "--date", "--color",
            "--no-color", "--column", "--porcelain", "-s", "--short", "--long",
            "-b", "--branch", "-v", "--verbose", "-q", "--quiet", "-z", "--null",
            "--word-diff", "--unified", "-U", "--no-prefix", "--src-prefix",
            "--dst-prefix", "--show-signature", "--stat-width", "--full-index",
            # Selection.
            "--cached", "--staged", "--merged", "--no-merged", "-a", "--all",
            "--follow", "-n", "--max-count", "--skip", "--since", "--until",
            "--author", "--committer", "--grep", "--reverse", "--first-parent",
            "--merges", "--no-merges", "--diff-filter", "--relative", "-M",
            "--find-renames", "-C", "--find-copies", "-w", "--ignore-all-space",
            "--ignore-space-change", "--ignore-blank-lines", "-R", "--exit-code",
            "-i", "--ignore-case", "-E", "--extended-regexp", "-F", "--fixed-strings",
            "-l", "--list", "--line-number", "--count", "-c", "-h", "-r", "-t",
            "-d", "-D", "--delete", "--contains", "--points-at", "--sort",
            "--show-current", "--show-toplevel", "--git-path", "--abbrev-ref",
            "--verify", "--symbolic", "--symbolic-full-name", "--show-prefix",
            "--is-inside-work-tree", "--is-bare-repository", "--sq", "--default",
            "-e", "--batch", "--batch-check", "--stdin",
            # NEITHER `--no-index` NOR `--no-ext-diff` is listed, deliberately.
            #
            # Both were added during PR #548 to clear a false block on
            # `git diff --no-index a b`, and the attempt walked down three rungs before
            # being abandoned: `--no-index` alone still lets a configured
            # `diff.external` driver run, so it was gated behind a co-required
            # `--no-ext-diff` -- and `--no-ext-diff` disables only EXTERNAL DRIVERS,
            # while git additionally enables TEXTCONV by default for no-index diffs, so
            # repository attributes plus a configured `diff.<driver>.textconv` still
            # execute an external command (builtin/diff.c). Each fix uncovered the next
            # escape hatch in the same feature.
            #
            # A false block on a read costs one lease use and is recoverable; a
            # classifier that calls an arbitrary-command path read-only is not. Whoever
            # revisits this needs to enumerate EVERY git mechanism that can execute a
            # configured program from a diff -- external drivers, textconv, and any
            # future sibling -- not just the one the last report named. Tracked as a
            # follow-up rather than guessed at again here.
            # Ref/index/remote operations that this classifier already calls reads.
            "-m", "--message", "--amend", "--no-edit", "--allow-empty", "--no-verify",
            "-A", "--update", "-f", "--force", "--force-with-lease", "--set-upstream",
            "--tags", "--prune", "--dry-run", "--depth", "--recurse-submodules",
            "--no-ff", "--ff-only", "--track", "--no-track", "-S", "--gpg-sign",
        )),
        "argflags": frozenset((
            "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
            "--super-prefix", "--config-env",
        )),
    },
}
# Interpreters that EXECUTE a string operand. Tokenizing reduces `bash -c 'rm -rf src'`
# to the single token `rm -rf src`, which equals no verb — so without recursing into the
# operand this classifier would ALLOW a real write that the old regexes caught. That is
# a fail-open, and it is the one direction this change must never move in. The operand
# is real shell source, so it is re-classified as shell source.
#
# Gated on the command word being a SHELL, deliberately: `-c` means "execute this
# string" only for a shell. `grep -c 'rm ' f` is a COUNT flag, and recursing there would
# resurrect exactly the quoted-operand false positive this module exists to remove.
_SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "mksh", "ash"))
# su/runuser also take `-c <program>` and hand it to a shell, so their operand is
# executable text too. Kept separate from _SHELLS because they are wrappers first.
# flock and script belong here for the SAME reason and were missed when they were added
# as wrappers: a wrapper entry only covers the argv form. util-linux spells the other
# half `flock FILE -c 'rm -rf src'` and `script -c 'rm -rf src' /dev/null`, where the
# whole command is ONE token that equals no verb -- so closing the argv form alone left
# the string form open. Any launcher added to _WRAPPERS must be checked for a -c form.
_DASH_C_RUNNERS = _SHELLS | frozenset(("su", "runuser", "flock", "script"))
# Bound the recursion. Depth is only reached by genuinely nested `bash -c 'bash -c ...'`
# or nested substitutions; the cap stops a hand-crafted bomb from stalling a PreToolUse
# hook. Hitting the cap returns the regex verdict (wider), never "allow".
_MAX_DEPTH = 4

# Bound the WIDTH, the sibling of the depth cap above and for the same reason. The -c scan
# is O(tokens^2) by construction: it refuses the per-flag arity table (that table fails
# OPEN when wrong), so every runner rescans every later c-looking option. Deduping the
# candidates removes the repeated RE-classification but not the rescan, and the residual
# still crosses the hook timeout -- 100KB of `sh -cx` pairs takes ~7s against a 5s
# PreToolUse timeout, and a timeout kills the hook with NO decision on stdout, which the
# harness reads as allow. Budgeting tokens rather than bytes is what keeps a legitimately
# long command safe: a 20KB `python3 -c '<script>'` is THREE tokens, because the script is
# one quoted word; only thousands of SEPARATE words reach this bound. Charged cumulatively
# across every segment and every recursion level, so many small segments cannot sum past
# it the way a per-segment cap allowed.
#
# Exhaustion returns True (BLOCK), and deliberately NOT the regex verdict the depth cap
# returns. The depth cap is reachable by honest nesting, so degrading to a wider verdict
# fits. 4000 separate words in one command is not honest shape, and "wider" is not "safe"
# here: the padding is attacker-chosen, so a payload spelled to miss the regexes and
# padded past the budget would be waved through. Blocking is the only branch that cannot
# be aimed. Worst measured cost at this bound is ~0.35s, a 14x margin under the timeout.
_MAX_SCAN_TOKENS = 4000

# And bound the raw SIZE, because the token budget alone does not terminate the attack --
# it only reprices it. Below the token bound the remaining cost is linear (normalize,
# tokenize, regex), so padding still buys time without ever reaching the token cap. One
# O(1) length test closes that, and it has to come FIRST -- every later bound charges for
# work already done. 64K is ~250x the longest command this repo has ever issued.
#
# CHARACTERS, not bytes, and the name says so. Every cost this bounds is per-character:
# Python strings index by character, so shlex, the regexes and the segment walk all scale
# with len(), and a 4-byte character costs exactly what a 1-byte one costs here. Bytes are
# the right unit only for the pre-parse guard in pre-implementation-gate.sh, whose cost is
# JSON decoding of the raw payload -- it uses wc -c for exactly that reason. Naming this
# one BYTES while comparing len() invited the conclusion that multi-byte padding slips
# past a 4x wider door than intended; worst measured shape at this bound is 0.7s.
_MAX_CMD_CHARS = 65536

# Reset by every _depth == 0 entry, so the public entry point is self-contained; the gate
# runs as a one-shot subprocess and the test suite drives it through is_file_mod().
_scan_budget = [0]

# A function-definition header at the start of a command or right after a separator:
# `mv() {`, `rm ( ) {`. Group 1 keeps the leading separator/whitespace so the segment
# structure around it is preserved.
_FUNC_DEF_RE = re.compile(r"(^|[;&|]\s*)[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)")

# Preambles that RUN the command that follows them. Peeling these finds the real verb
# without scanning every token: scanning all tokens catches `sudo rm -rf src` but also
# misreads `grep dd notes.txt` and `echo rmdir`, where the verb is plain data. Peeling
# gets both right, which pinning the command word alone does not.
# Kept in step with _WRAPPER_CMDS in pre-implementation-gate.sh: a launcher missing
# from ONE of the two lists is a fail-open in that half. `coproc` and `function` are
# handled separately below (they are keywords whose command word cannot be located
# reliably).
# KEEP IN STEP WITH the gate's _WRAPPER_CMDS -- a launcher missing from either list is a
# hole in that half. `watch` was missing from both: `watch --exec rm -rf src` resolved its
# command word to `watch` and read as a plain observation, which the raw regex it replaced
# had caught. `flock` and `script` were missing for a REASON THAT DID NOT HOLD: they were
# recorded as omitted to avoid a false positive, but membership here selects the
# conservative all-token regime (see _runs_mod_verb), which needs no per-flag arity and
# leaves `flock lock npm test` allowed -- while their absence made
# `flock /tmp/x.lock rm -rf src` resolve to `flock` and read as read-only, a write the
# raw regex they replaced had caught. A wrapper omitted on a stated rationale is still an
# allowlist entry, and this is the fourth one in this file to have been a fail-open.
#
# The PRICE of membership, uniform and pre-existing: the wrapped regime scans every
# token, so a verb NAME sitting in a wrapped command's data is read as the verb --
# `flock lock grep rm notes.txt` blocks, exactly as `sudo grep rm notes.txt` and
# `timeout 5 grep rm notes.txt` already did. It is not a flock/script quirk and it is not
# fixable by a narrower regime for these two: locating the command word past a launcher
# preamble needs per-flag arity, and that table fails OPEN (see _runs_mod_verb). The
# over-block is the fail-CLOSED side, it is asserted in the tests so it stays deliberate,
# and it costs one `--` or one shell quote to work around.
#
# RESIDUAL, stated rather than half-chased: this is an enumeration, so a launcher nobody
# has listed still resolves to itself and reads as read-only. The family does not close
# (`chpst`, `setpriv`, `eatmydata`, `systemd-run`, `uv run`, `poetry run`, ...), and the
# fail-closed inversion -- treat an UNKNOWN command word as conservative -- is exactly
# the all-token scan #519 removed, because it re-blocks `grep dd notes.txt`. The
# containment is that a launcher only helps an actor who already has Bash, and every
# gated WRITE still needs a lease that is logged. See ADR 0006 for the same call on
# run-time-assembled names.
_WRAPPERS = frozenset(("sudo", "doas", "su", "runuser", "env", "nohup", "timeout",
                       "nice", "ionice", "setsid", "stdbuf", "unbuffer", "command",
                       "builtin", "exec", "xargs", "caffeinate", "chroot", "arch",
                       "torify", "proxychains", "proxychains4", "watch",
                       "flock", "script"))
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# A redirection operator, with or without a leading fd and with or without an attached
# target: `<`, `>`, `2>`, `>>`, `&>`, `</dev/null`.
# Every COMPLETE redirection operator, longest-first so `<<<` is not read as a bare `<`
# (which left the here-string WORD in command position). KEEP IN STEP WITH the gate.
_REDIR_RE = re.compile(r"^(?:[0-9]+|&)?(?:<<<|<<-?|<>|<&|>>|>\||>&|<|>)")

# Raw-text twin of _WRITE_REDIR_RE, for the ONE path that has no tokens to test: the
# depth cap. Matches a WRITE redirection with a target -- `>f`, `>> f`, `2>f`, `&>f`,
# `>|f`, `1<>f` -- and not `>&2` or `2>&1`, which duplicate a descriptor rather than
# naming a file, nor a bare `<` read.
#
# Deliberately NOT anchored to a preceding space or control character. A redirection
# needs no whitespace in front of it: `printf x>src/impl.py` and `printf x 1<>src/impl.py`
# are both ordinary shell, and requiring a leading delimiter let exactly those spellings
# through. `<>` opens the target for READING AND WRITING, so it belongs here despite
# starting with `<`.
#
# Applied only at depth, where there are no exemptions to honor and four nested executed
# strings are already not honest shape -- so the blunt reading is the right one, and an
# incidental `->` inside a payload costing a block is the safe direction.
#
# `>&word` is the trap, and it is why this is spelled as explicit alternatives rather than
# one clever pattern: bash treats `>&` as descriptor duplication ONLY when the target is a
# number or `-`. `printf x >&out` creates a file called out, exactly like `&>out`.
# Excluding every `>&` form as a dup therefore lost three real writes. Verified against
# bash itself -- tests/test-impl-gate-scope-519.sh runs each spelling in a sandbox and
# compares "did a file appear" with this pattern, so the two cannot drift apart silently.
_RAW_WRITE_REDIR_RE = re.compile(
    r"(?:"
    r"[0-9]*>{1,2}\|?(?![&>])\s*[^\s;&|()<>]"          # > f   >> f   >| f   2> f
    r"|&>{1,2}\s*[^\s;&|()<>]"                          # &> f  &>> f
    # `>& f`, but not `>&2` / `>&-`. The "is a descriptor" lookahead must count QUOTE AND
    # BACKSLASH as a boundary, because this pattern runs on the quote-SQUEEZED variants:
    # stripping the quoting from a deeply nested payload leaves `2>&1` butted against the
    # escaping debris, and without these characters in the class the `1` read as the first
    # letter of a filename. Only reachable past the depth cap, so it cost a false BLOCK
    # rather than a miss -- but a rule that reports a descriptor dup as a write is wrong in
    # the direction that erodes trust in the gate.
    r"|[0-9]*>&\s*(?!-?[0-9]*(?:[\s;&|()\\'\"]|$))[^\s;&|()<>]"
    r"|[0-9]*<>\s*[^\s;&|()<>]"                         # <> f  1<> f (opens for WRITING too)
    r")")
# A WRITE redirection, with the target attached or in the next token. The `(?!&)` keeps
# fd duplications (`2>&1`, `>&2`) out: those redirect a stream, they do not open a file.
# `<>` opens for READING AND WRITING and creates the file if absent, so it belongs here
# even though it starts like a read: `exec 3<>src/impl.py; printf PWN >&3` writes through
# a descriptor, and the `>&3` half is indistinguishable from an ordinary fd dup.
_WRITE_REDIR_RE = re.compile(r"^(?:[0-9]*|&)(?:>>|<>|>\|?)(?!&)(.*)$")

# `>&` is the one operator whose meaning depends on its TARGET rather than its spelling:
# bash duplicates a descriptor for `>&2` and `>&-`, and CREATES A FILE for `>&out`. It
# cannot be settled in _WRITE_REDIR_RE because punctuation_chars tokenization splits the
# operator from its target, so `>&2` and `>& out` arrive as the same two-token shape and
# only the second token tells them apart. Handled in _writes_via_redirect instead.
_REDIR_DUP_OP_RE = re.compile(r"^[0-9]*>&$")
_REDIR_DUP_TARGET_RE = re.compile(r"^-?[0-9]*$")
# The joined-numeric option shapes (`-5`, `-n5`, `-U3`, `-M90`). Only these letters are
# decomposed: each takes a numeric argument and names no program.
_NUM_OPT_RE = re.compile(r"^-[nUMC]?[0-9]+$")
# A bare duration/number operand belonging to a wrapper (`timeout 5 rm x`, `nice 10 mv`).
_NUMERIC_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$")
# Shell reserved words and grouping punctuation. These occupy the first token position
# without being the command: `{ rm -rf src; }` and `if true; then rm -rf src; fi` split
# into segments whose first token is `{` or `then`, so stopping there would return a
# non-verb and ALLOW the write behind it.
# Keywords/punctuation that PRECEDE a command — skip them and judge what follows.
_RESERVED = frozenset(("if", "then", "else", "elif", "fi", "do", "done", "esac",
                       "while", "until", "time",
                       "{", "}", "!", ")"))
# coproc takes an OPTIONAL name, so its command word cannot be located reliably — force
# the conservative all-token scan. Anchored on command POSITION so a mention stays a
# mention (`echo coproc rm x` is data).
#
# `function` is deliberately NOT here: its NAME is data but its BODY is code, so an
# all-token scan would block `function mv { echo harmless; }` — one of the three #519
# false positives. It is handled by scanning the tokens AFTER the name instead.
_OPAQUE_INTRO = frozenset(("coproc",))
# Test-expression openers. Everything inside is an OPERAND, never a command, so these
# terminate the search instead of being skipped — skipping `[[` made `[[ rm = value ]]`
# and `[[ -f rm ]]` resolve to `rm` and classify as writes, recreating the very
# false-positive class this parser removes.
_TEST_OPEN = frozenset(("[[", "["))
# Keywords that introduce a NAME or a WORD rather than a command. The token after these
# is data, so skipping only the keyword misreads `function mv { ... }`, `for rm in a b`,
# and `case rm in ...` as invocations of mv/rm. Skip the keyword AND its operand.
_NAME_INTRO = frozenset(("function", "for", "select", "case"))


def _split_simple_commands(s):
    """Split into simple-command segments on UNQUOTED, UNESCAPED control operators.

    Copied from the anti-forge detector in pre-implementation-gate.sh, where the
    reasoning is documented at length: this MUST happen before shlex, because posix
    shlex strips quoting and would make a quoted separator indistinguishable from a
    real one. Returns (segments, ok); ok is False on an unterminated quote or dangling
    escape so the caller can fall back rather than trust a half-parse.
    """
    segs, buf = [], []
    in_s = in_d = esc = False
    for ch in s:
        if esc:
            buf.append(ch)
            esc = False
        elif in_s:
            buf.append(ch)
            if ch == _SQ:
                in_s = False
        elif in_d:
            buf.append(ch)
            if ch == "\\":
                esc = True
            elif ch == _DQ:
                in_d = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
        elif ch == _SQ:
            buf.append(ch)
            in_s = True
        elif ch == _DQ:
            buf.append(ch)
            in_d = True
        elif ch in "|&" and buf and buf[-1] == ">":
            buf.append(ch)  # >| (clobber) or >& (dup) -> part of the redirect
        elif ch in ";|&()":
            segs.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    segs.append("".join(buf))
    return segs, not (in_s or in_d or esc)


def _normalize(cmd):
    """Apply the same pre-tokenization normalization the anti-forge detector uses, so
    the two agree on what a 'token' is: line continuations rejoined, newlines treated
    as command separators, ANSI-C/locale quote prefixes dropped so shlex sees the
    quote, and ${IFS} field-splitting obfuscation restored to real whitespace."""
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    norm = norm.replace(chr(92) + chr(10), "").replace("\n", " ; ")
    norm = norm.replace("$" + _SQ, _SQ).replace("$" + _DQ, _DQ)
    norm = re.sub(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])", " ", norm)
    # Drop shell FUNCTION-DEFINITION headers (`mv() {`, `rm ( ) {`). _split_simple_commands
    # splits on parens, so `mv() { echo harmless; }` leaves a bare `mv` segment that reads
    # as an invocation — the third #519 false positive (a probe defining functions named
    # `mv` and `[`), which this module claimed to fix but did not.
    #
    # Not a fail-open: a definition does not RUN the body, and removing only the
    # `name()` header leaves that body in place to be classified anyway. What is dropped
    # is a NAME, never a verb in command position — `rm x` is an invocation and has no
    # parens, so it cannot be laundered into this shape.
    return _FUNC_DEF_RE.sub(r"\1", norm)


def _basename(tok):
    return tok.rsplit("/", 1)[-1]


def _subst_end(s, start):
    """Index of the `)` closing the `$(` whose `(` is at s[start], or -1 if unterminated.

    Parenthesis counting MUST be quote-aware. A naive depth counter is fooled by a paren
    inside a quoted string — `echo "$(printf '('; rm x)"` leaves depth stuck above zero,
    the body is never extracted, and the `rm x` inside it is never classified. A quoted
    `)` ends extraction early with the same effect. Both are fail-opens.
    """
    i, n, depth = start, len(s), 0
    in_s = in_d = False
    while i < n:
        ch = s[i]
        if in_s:
            if ch == _SQ:
                in_s = False
        elif in_d:
            if ch == "\\":
                i += 1
            elif ch == _DQ:
                in_d = False
        elif ch == "\\":
            i += 1
        elif ch == _SQ:
            in_s = True
        elif ch == _DQ:
            in_d = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _command_substitutions(s):
    """(bodies, ok) for `$(...)` and backtick substitutions, which execute wherever they
    appear — including inside double quotes, so `echo "$(rm -rf src)"` is a real write.

    Single-quoted regions are skipped: no substitution happens there, and treating them
    as code would re-break `grep -nE 'rm |mv '`. `ok` is False on an unterminated
    substitution so the caller can fall back to the wider regexes instead of guessing.
    """
    out, i, n = [], 0, len(s)
    in_d = False
    while i < n:
        ch = s[i]
        if ch == "\\":
            i += 2
            continue
        # A single quote is LITERAL inside double quotes — it opens no inert region
        # there. Treating it as one made `echo "'$(rm x)'"` skip past a substitution
        # that really executes, so the rm was never classified: a fail-open.
        if ch == _SQ and not in_d:          # inert region — skip to its close
            j = s.find(_SQ, i + 1)
            if j < 0:
                return out, False           # unterminated → let the caller fall back
            i = j + 1
            continue
        if ch == _DQ:
            in_d = not in_d
            i += 1
            continue
        if ch == "$" and i + 1 < n and s[i + 1] == "(":
            j = _subst_end(s, i + 1)
            if j < 0:
                return out, False
            out.append(s[i + 2:j])
            i = j + 1
            continue
        if ch == "`":
            j = s.find("`", i + 1)
            if j < 0:
                return out, False
            out.append(s[i + 1:j])
            i = j + 1
            continue
        i += 1
    return out, True


def _executed_operands(toks):
    """Token operands this simple command hands to a shell to EXECUTE.

    The runner must appear in the PREAMBLE — the leading run of assignments, flags,
    wrappers and runners — not anywhere in the token list. Once a real command word is
    reached, everything after it is that command's data: `echo su -c "rm x"` and
    `echo runuser --command="rm x" root` print text, they do not execute it, and an
    any-position scan turned both into blocked writes.
    """
    # Deduped ON INSERT, not at the end. Collecting first and deduping after still
    # MATERIALIZES every duplicate: dropping the break makes each runner rescan every
    # later c-looking option, so N repeated pairs build O(N^2) entries before the set
    # ever sees them -- a 65,008-character, 4,000-token input peaked near 203 MiB even
    # though the token budget bounded the TIME. The membership test is the same test,
    # moved to where it stops the growth instead of tidying up after it.
    out, _seen = [], set()

    def _add(cand):
        if cand not in _seen:
            _seen.add(cand)
            out.append(cand)

    # When the command STARTS with a wrapper, do not stop at the first non-wrapper word:
    # a wrapper flag can take an operand (`sudo -u root bash -c "rm x"`), so breaking at
    # `root` never reaches the `bash -c` behind it, and the conservative token scan does
    # not catch it either because `rm x` is one token. In that regime scan every token —
    # over-blocking a wrapped read is the safe direction. Unwrapped commands keep the
    # strict preamble-only walk, which is what keeps `echo su -c "rm x"` allowed.
    scan_all = _starts_with_wrapper(toks)
    i, n = 0, len(toks)
    skip_next = False
    while i < n:
        t = toks[i]
        if skip_next:
            skip_next = False
            i += 1
            continue
        # A LEADING REDIRECTION is legal shell and sits in the preamble, so it must be
        # stepped over here exactly as _starts_with_wrapper and _effective_command_word
        # step over it. Without this the walk fell through to the `break` below, treating
        # `<` as a real command word and stopping BEFORE the runner behind it:
        # `</dev/null bash -c "rm -rf src"` yielded NO operands at all, so the -c payload
        # was never classified. Nothing downstream caught it either -- a READ redirection
        # does not trip the write-redirect check, and `bash` is a runner rather than a
        # wrapper, so _starts_with_wrapper had already returned False. One leading
        # character disabled the only inspection that reads an executed payload. Same
        # family as the _effective_command_word and _starts_with_wrapper cases: seven
        # spellings leaked, including `2>/dev/null eval ...`, `<<<x sh -c ...` and the
        # numeric-fd form `3</dev/null bash -c ...`.
        #
        # The target skip is suppressed under scan_all: that regime means "inspect every
        # token" precisely because a wrapper flag can take an operand, so consuming a
        # token as a redirection target there could step OVER a runner. Skipping the
        # operator alone is enough, and never narrows the wrapped scan.
        m = _REDIR_RE.match(t)
        if m:
            skip_next = (not scan_all) and m.group(0) == t
            i += 1
            continue
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            i += 1
            continue
        base = _basename(t)
        # Reserved words and grouping occupy the preamble without being the command, so
        # `{ sh -c "rm x"` must not stop at `{` — a function body reaches this shape.
        if base in _RESERVED:
            i += 1
            continue
        if base in _DASH_C_RUNNERS:
            # The program follows the flag bundle CONTAINING `c`, or a long
            # --command form. NOT --rcfile: that names a FILE to source, not inline
            # source, so treating its value as a program was simply wrong.
            for j in range(i + 1, n):
                t2 = toks[j]
                if t2.startswith("--"):
                    # getopt_long accepts any UNAMBIGUOUS ABBREVIATION, so `--com=PROG`
                    # and `--c PROG` run exactly what `--command PROG` runs. Comparing
                    # against the full spelling left every shorter one unread. NOT
                    # --rcfile: that names a FILE to source, not inline source, and
                    # `"command".startswith("rcfile")` is false, so it stays excluded.
                    name, eq, val = t2.partition("=")
                    _LONG_RUN = ("command", "session-command")
                    # su and runuser also execute --session-command, documented as
                    # equivalent to -c, so the abbreviation test covers both spellings.
                    if len(name) > 2 and any(l.startswith(name[2:]) for l in _LONG_RUN):
                        if eq:
                            _add(val)
                        else:
                            k = j + 1
                            # `bash -c -- 'rm -rf src'` consumes a bare `--` as the
                            # getopt end-of-options marker BEFORE the command string,
                            # not as the string itself -- verified against the real
                            # binary (`bash -c -- 'echo x'` runs `echo x`, not `--`).
                            # Adding toks[j+1] unconditionally classified the inert
                            # `--` and never reached the real payload one token later.
                            if k < n and toks[k] == "--":
                                k += 1
                            if k < n:
                                _add(toks[k])
                    continue          # NO break, for the reason given below
                if t2.startswith("-") and not t2.startswith("--") and "c" in t2[1:]:
                    # ATTACHED or separated -- and, unlike the -m walk, NOT decidable
                    # from the spelling. After dequoting, `bash -cl 'rm x'` (bash reads
                    # the tail as MORE FLAGS and takes the next word) and
                    # `sh -c'rm -rf src'` (program attached) are both `-c` plus a tail.
                    # So both candidates are taken: each is re-classified on its own, a
                    # tail that is really a flag letter classifies as nothing, and the
                    # extra candidate can therefore only ever add a block.
                    tail = t2[t2.index("c", 1) + 1:]
                    if tail:
                        _add(tail)
                    k = j + 1
                    # Same `--` end-of-options skip as the long-option form above.
                    if k < n and toks[k] == "--":
                        k += 1
                    if k < n:
                        _add(toks[k])
                    # NO break. Stopping at the first `c` assumed this token IS the -c,
                    # which needs to know whether an EARLIER flag consumed it as an
                    # operand -- `script -O -cfoo -c PROG` hands `-cfoo` to -O as a
                    # filename, and stopping there missed the real PROG behind it. That
                    # arity table is the one this module refuses to keep (it fails OPEN
                    # when wrong), so the question is inverted instead: every token that
                    # COULD be a -c operand becomes a candidate, each is classified on
                    # its own, and one that is really a filename classifies as nothing.
                    continue
                # Stdin-fed shell source: with no -c/--command operand and no script
                # FILE operand, a shell reads its script from STDIN -- so
                # `bash <<< 'rm -rf src'` (here-string) executes the redirected text
                # exactly as -c would. The old raw regexes caught the literal `rm`;
                # tokenizing without this branch classified nothing, because the outer
                # walk's generic redirect-skip treats the operator's target as an inert
                # redirection operand and steps past it.
                #
                # Scoped to `<<<` alone, and to genuine shells (not su/runuser/flock/
                # script, whose stdin behavior under this shape is not verified here).
                # KNOWN RESIDUAL, pinned so it stays visible rather than rediscovered:
                # `bash <<EOF` / `bash << EOF` (real heredoc) is NOT covered by this
                # branch -- the delimiter word sits where the payload would, and the
                # actual heredoc BODY is not this token's target, so re-classifying
                # `toks[j + 1]` here would only ever inspect the delimiter, never the
                # body. Closing that shape needs heredoc-body extraction this module
                # does not attempt.
                if base in _SHELLS and t2 == "<<<":
                    if j + 1 < n:
                        _add(toks[j + 1])
                    continue
            i += 1
            continue
        if base == "eval":
            if i + 1 < n:
                _add(" ".join(toks[i + 1:]))
            i += 1
            continue
        if base == "env":
            # `env -S <program>` splits its operand into an argv and runs it. Both the
            # separated (-S, prog), attached (-Sprog) and long (--split-string=prog)
            # spellings occur.
            for j in range(i + 1, n):
                t2 = toks[j]
                if t2.startswith("--split-string="):
                    _add(t2.split("=", 1)[1])
                    break
                # The two-argument long form is equally valid and was omitted, so the
                # program stayed one token and matched no verb.
                if t2 == "--split-string" and j + 1 < n:
                    _add(toks[j + 1])
                    break
                if t2 == "-S" and j + 1 < n:
                    _add(toks[j + 1])
                    break
                if t2.startswith("-S") and len(t2) > 2:
                    _add(t2[2:])
                    break
            i += 1
            continue
        if base in _WRAPPERS:
            i += 1
            continue
        if scan_all:
            i += 1
            continue
        break          # a real command word: everything after it is data
    # Dedupe, order-preserving. Dropping the break above made every runner rescan every
    # later c-looking option, so a command repeating one option pair N times yields O(N^2)
    # candidates -- but only O(N) DISTINCT ones. Each candidate is classified on its own
    # and the verdicts are OR-ed, so a repeat can never change the answer, only re-derive
    # it: 800 `-O sh -O -cecho` pairs cost 4.9s of pure recopying, past the 5s PreToolUse
    # timeout that kills the hook WITHOUT a decision on stdout -- a fail-OPEN reachable
    # from the command string alone. Same verdict, without the re-derivation.
    return out


def _first_word_index(toks):
    """Index of the first token in COMMAND position, or None. Same preamble walk as
    `_first_word` (assignments, flags, numeric operands, redirections and shell
    reserved words are skipped) but returns WHERE the word sits rather than the word
    itself, so a caller that needs to slice past a preamble it does not control the
    length of (e.g. the NAME after `function`) does not have to assume position 0."""
    skip_next = False
    for idx, t in enumerate(toks):
        if skip_next:
            skip_next = False
            continue
        m = _REDIR_RE.match(t)
        if m:
            skip_next = m.group(0) == t   # a BARE operator takes the next token as target
            continue
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            continue
        b = _basename(t)
        if b in _RESERVED:
            continue
        if b in _TEST_OPEN:
            return None
        return idx
    return None


def _first_word(toks):
    """First token in COMMAND position: assignments, flags, numeric operands and shell
    reserved words are skipped, so `then coproc rm x` and `{ coproc rm x` both report
    `coproc`. coproc/function are NOT in _RESERVED, so they are reported exactly where
    they sit, while a mere mention (`echo coproc rm x`) still reports `echo`.

    A LEADING REDIRECTION is stepped over for the same reason as in the three sibling
    walks: without it `</dev/null coproc rm -rf src` reported `<`, the _OPAQUE_INTRO test
    missed, the conservative all-token regime was never selected, and the write ran. Both
    callers use this only to WIDEN the scan, so an extra name here can only add a block.
    A mention is still safe: the walk returns at the first real command word, so
    `grep -n "<" notes.txt` reports `grep` and never reaches the operand."""
    idx = _first_word_index(toks)
    return _basename(toks[idx]) if idx is not None else ""


def _starts_with_wrapper(toks):
    """Does this simple command BEGIN with a wrapper (after assignments/flags/keywords)?

    Position matters: scanning every token for a wrapper name meant `grep sudo rm` and
    `printf sudo rm` flipped to the conservative all-token scan and blocked, which is the
    same false-positive class #519 exists to remove.
    """
    skip_next = False
    for t in toks:
        if skip_next:
            skip_next = False
            continue
        # A LEADING REDIRECTION is legal shell and must be stepped over here for the same
        # reason _effective_command_word steps over it -- but the consequence of missing
        # it is the opposite and worse. There, resolving the command word to `<` allowed
        # the write behind it. HERE, `<` is simply not a wrapper name, so the answer was
        # False: the conservative all-token regime was never selected, and the launcher
        # was then peeled by _effective_command_word, which stops at the launcher's OWN
        # operand. `</dev/null sudo -u root rm -rf src` resolved to `root` and
        # `</dev/null script -q /dev/null rm -rf src` to `null` -- both read as read-only
        # while executing rm. One leading character disabled the regime that exists
        # precisely because a launcher preamble cannot be peeled without an arity table.
        #
        # Only the two callers of this function decide the REGIME, so an extra True here
        # can only widen the scan, never narrow it -- the fail-CLOSED direction.
        m = _REDIR_RE.match(t)
        if m:
            skip_next = m.group(0) == t   # a BARE operator takes the next token as target
            continue
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            continue
        b = _basename(t)
        if b in _TEST_OPEN:
            return False              # a test expression wraps nothing
        if b in _NAME_INTRO:
            skip_next = True
            continue
        if b in _RESERVED:
            continue
        return b in _WRAPPERS
    return False


def _effective_command_word(toks):
    """The verb this simple command RUNS, with the preamble peeled.

    Skips leading assignments, flags, reserved words, grouping punctuation, wrappers and
    bare numeric operands; keywords that introduce a NAME consume their operand too.
    Returns None if nothing executes.

    Only consulted for WRAPPER-FREE commands (see _runs_mod_verb): peeling a wrapper
    preamble precisely would mean knowing which of its flags take an operand
    (`sudo -u root rm -rf src` must not stop at `root`), and getting that table wrong
    fails OPEN.
    """
    skip_next = False
    for t in toks:
        if skip_next:
            skip_next = False
            continue
        # A LEADING REDIRECTION is legal shell: `</dev/null git clean -fd` runs git.
        # Resolving the command word to `<` classified it as an unknown non-verb and
        # allowed the write behind it. A BARE operator takes the next token as its
        # target; an attached one (`</dev/null`) does not.
        m = _REDIR_RE.match(t)
        if m:
            skip_next = m.group(0) == t
            continue
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            continue
        b = _basename(t)
        if b in _TEST_OPEN:
            return None               # a test expression runs no command
        if b in _NAME_INTRO:
            skip_next = True          # the following token is a NAME, not a command
            continue
        if b in _RESERVED or b in _WRAPPERS:
            continue
        return b
    return None


def _sed_inplace(toks):
    """`sed -i` edits in place, in the short-bundle spelling (`-i`, `-i.bak`) or the
    GNU long spelling (`--in-place`, `--in-place=SUFFIX`, and any unambiguous
    getopt_long abbreviation such as `--in-pl`). The -i must come AFTER the sed
    token: in `grep -i sed notes.txt` the -i belongs to grep and sed is its search
    string."""
    names = [_basename(t) for t in toks]
    if "sed" not in names:
        return False
    after = toks[names.index("sed") + 1:]
    for t in after:
        if re.match(r"^-[A-Za-z]*i", t):
            return True
        if t.startswith("--"):
            name = t.partition("=")[0][2:]
            # Guard the abbreviation to a minimum length so this stays anchored on
            # "in-place" specifically rather than matching every long flag that
            # happens to start with the same first couple of letters.
            if len(name) >= 3 and "in-place".startswith(name):
                return True
    return False


def _payload_is_mod(toks, depth):
    """Full verdict for a token list that is itself a command — used for the find -exec
    payload and a function body.

    _runs_mod_verb alone checks only DIRECT verbs, so it missed both an executed shell
    operand (`-exec sh -c "rm \"$1\"" _ {} ;`) and the sed -i rule
    (`-exec sudo sed -i "s/a/b/" {} ;`). The old raw regexes caught the embedded `rm `
    and `sed -i`, so leaving those out was a fail-open regression.
    """
    if _runs_mod_verb(toks):
        return True
    if _sed_inplace(toks):
        return True
    for prog in _executed_operands(toks):
        if is_file_mod(prog, depth + 1):
            return True
    return False


def _runs_mod_verb(toks):
    """Two-regime verdict for a token list that is itself a command.

    Wrapper (or opaque intro) present -> scan EVERY token, because a wrapper flag can
    take an operand and enumerating which flags do is a table that fails OPEN.
    Otherwise -> the command word alone, so data operands stay data.

    Shared by the segment check, the find -exec payload and the function body.
    """
    names = [_basename(t) for t in toks]
    if _starts_with_wrapper(toks) or _first_word(toks) in _OPAQUE_INTRO:
        if any(n in _MOD_VERBS for n in names):
            return True
        # A dispatcher behind a wrapper (`sudo git clean -fd`, `env git stash`) cannot use
        # the positional lookup below, because locating the command word past a wrapper
        # preamble needs per-flag arity and every approximation of that fails OPEN. The
        # wrapped regime is already "scan every token", so the subcommand is matched the
        # same way. This lives HERE and only here -- _segment_is_mod and _payload_is_mod
        # both route through this function, and a second copy is how the two regimes
        # drifted apart before (`find . -exec sudo git clean -fd ;` was allowed).
        # ...and a dispatcher is judged by the SAME positional rule as below. Scanning
        # for a read-subcommand name anywhere was wrong twice over: a pathspec supplies
        # one (`sudo git clean -fd status` looked safe) and writeflags never applied
        # (`sudo git diff --output=src/x`). Locating `git` by basename and reading
        # forward needs no wrapper-flag arity, so it works under a preamble too.
        applies, writes = _dispatcher_verdict(toks)
        return applies and writes
    word = _effective_command_word(toks)
    if word in _MOD_VERBS:
        return True
    # SUBCOMMAND DISPATCHERS. `git rm src/x` and `git mv a b` really do delete and rename
    # working-tree files, but the verb sits one token in, so a command-word test reads it
    # as data and allows it -- a fail-open against the raw regexes this replaced, which
    # matched the literal `rm `. The verb is looked up at its actual POSITION rather than
    # by scanning every token, so `git log --grep rm` and `git diff -- rm.py` stay reads.
    # Gated on the COMMAND WORD being the dispatcher, unlike the wrapped branch: with no
    # wrapper, a `git` token elsewhere is an operand (`echo git clean`), and judging it
    # would resurrect the mention-as-invocation false positive.
    if _basename(word or "") in _DISPATCHERS:
        applies, writes = _dispatcher_verdict(toks)
        return applies and writes
    return False


def _dispatcher_verdict(toks):
    """(is a dispatcher command, does it write) for the first dispatcher named in toks.

    The subcommand is located POSITIONALLY -- the first operand after the dispatcher that
    is neither a global option nor the operand of one -- so a pathspec that happens to
    share a subcommand name cannot vouch for the command.
    """
    for name, spec in _DISPATCHERS.items():
        i = next((k for k, t in enumerate(toks)
                  if not _ASSIGN_RE.match(t) and _basename(t) == name), None)
        if i is None:
            continue
        # An ASSIGNMENT PREFIX is a second config channel with the same reach as `-c`:
        # `GIT_EXTERNAL_DIFF="rm -rf src" git diff` runs it. Naming the dangerous
        # variables would be an allowlist of safe ones, so any assignment counts.
        if any(_ASSIGN_RE.match(t) for t in toks[:i]):
            return True, True
        sub, gopts, sargs = _dispatch_regions(toks, name, i)
        # Everything after a bare `--` is a pathspec, however option-shaped it looks.
        if "--" in sargs:
            sargs = sargs[:sargs.index("--")]
        # Options are cleared in THEIR OWN REGION, and only if they are recognised as
        # inert. One list scanned over every token conflated the global `-c key=val`
        # with the subcommand `git grep -c` and read `git diff -- --tool` as an option.
        if not _all_inert(gopts, spec["globalopts"]):
            return True, True
        if not sub:
            return True, False        # bare `git` prints usage
        if sub not in spec["reads"]:
            return True, True         # unknown/aliased/writing subcommand -> fail closed
        return True, not _all_inert(sargs, spec["subopts"])
    return False, False


def _all_inert(toks, inert):
    """True iff every OPTION-shaped token is recognised as inert.

    An option is cleared in three shapes: bare (`--stat`), attached-value
    (`--pretty=oneline`) and joined-numeric (`-n5`, `-U3`). Any other joined short is
    NOT decomposed, because deciding that `-Orm` is `-O rm` needs per-letter arity that
    git does not expose; unrecognised means not cleared, which is the safe direction.
    A token carrying an expansion never matches, so `git diff --ext${EMPTY}-diff` is not
    cleared either. A token that is WHOLLY an expansion is not option-shaped and is read
    as an operand -- indistinguishable from `git diff "$FILE"`, which must stay a read.
    Documented residual, not an oversight.
    """
    return all(t.split("=", 1)[0] in inert or _NUM_OPT_RE.match(t)
               for t in toks if t.startswith("-"))


def _dispatch_regions(toks, name, i):
    """(subcommand, global option tokens, subcommand tokens), splitting at `toks[i]`.

    The subcommand is located POSITIONALLY -- the first operand after the dispatcher that
    is neither a global option nor the operand of one -- so a pathspec that happens to
    share a subcommand name cannot vouch for the command. Matched on BASENAME, so
    `/usr/bin/git rm x` resolves. Operands of global options are dropped from the
    returned globals: `git -C "$repo" status` must not read as an unresolvable option.
    """
    argflags = _DISPATCHERS[name]["argflags"]
    gopts, skip = [], False
    for j in range(i + 1, len(toks)):
        t = toks[j]
        if skip:
            skip = False              # this token is the operand of the previous flag
            continue
        if t in argflags:
            gopts.append(t)
            skip = True               # separated form: `-C repo`, `--git-dir repo/.git`
            continue
        if t.startswith("-"):
            gopts.append(t)           # a bare switch, or the attached `--git-dir=repo`
            continue
        return _basename(t), gopts, list(toks[j + 1:])
    return "", gopts, []


def _segment_is_mod(toks, depth=0):
    """True iff this simple command RUNS a file-modifying verb."""
    names = [_basename(t) for t in toks]
    cw = _effective_command_word(toks)
    # `find` is deliberately NOT a conservative trigger: forcing the all-token scan for
    # it made read-only `find . -name rm` and `find . -exec echo rm {} +` classify as
    # writes. It gets its own block below.
    wrapped = _starts_with_wrapper(toks) or _first_word(toks) in _OPAQUE_INTRO
    # Both regimes live in _runs_mod_verb; this used to re-implement them inline and the
    # copies drifted. _payload_is_mod calls the same function, so a find -exec payload and
    # a top-level command are judged identically.
    if _runs_mod_verb(toks):
        return True
    # `function NAME { body }`: the NAME is data, the BODY is code (it executes when the
    # name is called later). Judged by command word so `function f { echo rm; }` -- which
    # only prints the word -- stays allowed.
    if _first_word(toks) == "function":
        # `toks[2:]` assumed `function` sits at toks[0] and the NAME follows it
        # immediately at toks[1] -- but _first_word tolerates a preamble (leading
        # redirections, assignments, flags, reserved words), so a segment like
        # `if true; then function mv { echo harmless; }; fi` puts `function` deeper
        # in the token list. Slicing from a fixed index then started ON the NAME
        # instead of past it, scanning the name itself as code. Locate the real
        # index instead of assuming position 0.
        fn_idx = _first_word_index(toks)
        after_name = (toks[fn_idx + 2:]
                      if fn_idx is not None and len(toks) > fn_idx + 2 else [])
        if after_name and _payload_is_mod(after_name, depth):
            return True
    # find runs its own commands: -delete writes by itself, -exec/-execdir/-ok take a
    # command. The payload goes through _runs_mod_verb so a WRAPPED payload
    # (`-exec sudo -u root rm {} ;`) is caught and a DATA operand (`-exec echo rm {} +`)
    # is not.
    if cw == "find" or (wrapped and "find" in names):
        if "-delete" in names:
            return True
        for i, t in enumerate(toks):
            if t in ("-exec", "-execdir", "-ok", "-okdir"):
                payload = []
                for t2 in toks[i + 1:]:
                    if t2 in (";", "+"):
                        break
                    payload.append(t2)
                if payload and _payload_is_mod(payload, depth):
                    return True
    # sed modifies only in-place, and the -i must come AFTER the sed token: in
    # `grep -i sed notes.txt` the -i belongs to grep and sed is its search string.
    # Anchored on command position so `echo sed -i` is not a write.
    if cw == "sed" or (wrapped and "sed" in names):
        return _sed_inplace(toks)
    return False


def is_file_mod(cmd, _depth=0):
    """Does this Bash command explicitly modify files?

    Tokenizes when it can and falls back to the original regexes when it cannot, so a
    parse failure degrades to the pre-#519 decision rather than to a new over-block.
    Strings the command hands to a shell — `bash -c`, `eval`, `$(...)`, backticks — are
    re-classified as shell source, because tokenization alone would reduce them to inert
    single tokens and ALLOW writes the old regexes caught.
    """
    if not cmd:
        return False
    if len(cmd) > _MAX_CMD_CHARS:
        return True                       # fail CLOSED -- see _MAX_CMD_CHARS
    if _depth == 0:
        _scan_budget[0] = _MAX_SCAN_TOKENS
    if _depth >= _MAX_DEPTH:
        # _regex_fallback is VERB patterns only, so it cannot see a redirect-only write --
        # and the cap returns before the tokenized pass that would have run
        # _writes_via_redirect. Nesting executed strings past the cap therefore hid
        # `printf x > src/impl.py` behind three `sh -c` layers: the caller strips
        # single-quoted text before its own redirect check (so a literal `jq .x > 0` is
        # not a write), which is exactly where a payload lives, and the depth fallback
        # then found no listed verb. Both halves of the verdict have to survive the cap,
        # not just the verb half.
        #
        # Depth-gated for the same reason as the token-level check below: at depth there
        # are no redirect EXEMPTIONS to honor (the caller owns those, and /dev/null and
        # friends never reach here), so this is deliberately the blunt rule. Reaching it
        # at all means four nested executed strings, which is not honest shape.
        if _regex_fallback(cmd):
            return True
        return any(_RAW_WRITE_REDIR_RE.search(v) for v in _shell_variants(cmd))
    # Bash decodes the escapes in `$'...'` and drops the `$` BEFORE it resolves the
    # command word, so `g$'\x69't clean -fd` runs git. shlex knows nothing of ANSI-C
    # quoting and handed back `g$\x69t`, a token that equals no verb, so the tokenized
    # path allowed it while only the fallback saw it. Classify the resolved spelling as
    # well; it is additive, so it can only add a block.
    resolved = _ansi_c(cmd)
    if resolved != cmd and is_file_mod(resolved, _depth + 1):
        return True
    # Command substitutions execute regardless of where they sit in the command.
    bodies, subst_ok = _command_substitutions(cmd)
    if not subst_ok:
        return _regex_fallback(cmd)
    for body in bodies:
        if is_file_mod(body, _depth + 1):
            return True
    segs, ok = _split_simple_commands(_normalize(cmd))
    if not ok:
        return _regex_fallback(cmd)
    for segtext in segs:
        try:
            lex = shlex.shlex(segtext, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            # The newline->";" normalization above leaves a "#" with no terminating
            # newline; default comment handling would swallow the rest of the segment
            # and hide a trailing verb.
            lex.commenters = ""
            toks = list(lex)
        except ValueError:
            # This one segment is unparseable. Decide the WHOLE command by the regex
            # fallback rather than silently dropping the segment — dropping it is the
            # only outcome here that could be a fail-OPEN.
            return _regex_fallback(cmd)
        # Charge before scanning: the O(tokens^2) walk is what this bounds.
        _scan_budget[0] -= len(toks)
        if _scan_budget[0] < 0:
            return True                   # fail CLOSED -- see _MAX_SCAN_TOKENS
        if _segment_is_mod(toks, _depth):
            return True
        # A REDIRECT inside an executed string writes just as surely as a verb does.
        # The caller checks redirects on the raw command, but it strips single-quoted
        # text first (so a literal `jq .x > 0` is not a write), which is exactly the
        # text a payload lives in: `bash -c 'printf x > src/impl.py'` survived both
        # checks. Only applied at depth, because at the top level the caller's own
        # check already runs -- and it carries exemptions this one does not know about.
        if _depth and _writes_via_redirect(toks):
            return True
        for prog in _executed_operands(toks):
            if is_file_mod(prog, _depth + 1):
                return True
    return False


def _writes_via_redirect(toks):
    """True iff a write redirection in this simple command targets a real file.

    `/dev/null` and fd duplications (`2>&1`, `>&2`) are not file writes; everything
    else is, including the clobber form `>|` and the append form `>>`.
    """
    for k, t in enumerate(toks):
        nxt = toks[k + 1] if k + 1 < len(toks) else ""
        # Decided by the TARGET: `>&2` and `>&-` duplicate or close a descriptor, while
        # `>&out` creates a file exactly as `&>out` does. The raw depth-cap twin was
        # corrected for this first; leaving the token path behind would have left the two
        # siblings disagreeing about one spelling at different depths, which is how they
        # drifted apart before. Not a live fail-open when found -- the gate carries its
        # own redirect check and blocked `printf x >&src/impl.py` at the top level either
        # way -- so this is a consistency fix, and it can only add blocks.
        if _REDIR_DUP_OP_RE.match(t):
            if nxt and not _REDIR_DUP_TARGET_RE.match(nxt) and nxt != "/dev/null":
                return True
            continue
        m = _WRITE_REDIR_RE.match(t)
        if not m:
            continue
        target = m.group(1) or nxt
        if target and target != "/dev/null":
            return True
    return False


def _regex_fallback(cmd):
    """The raw patterns, run on the command AND on a quote-squeezed copy of it.

    This path exists for commands that will not tokenize, so the quote structure it is
    handed is by definition broken -- and `g"it" clean -fd` and `g\\it clean -fd` are both
    valid commands whose verb no contiguous pattern matches. Quoting, escaping, the
    ANSI-C `$` prefix and a backslash-newline continuation are all removed by the shell
    before it resolves the command word, so removing them here reproduces what bash will
    run. It can only make more text match, so it adds blocks and never removes one.
    """
    return any(any(re.search(p, v) for v in _shell_variants(cmd))
               for p in FILE_MOD_PATTERNS)


_ESC_RE = re.compile(
    r"\\(?:x([0-9A-Fa-f]{1,2})"      # \xH, \xHH
    r"|u([0-9A-Fa-f]{1,4})"          # \uH .. \uHHHH
    r"|U([0-9A-Fa-f]{1,8})"          # \UH .. \UHHHHHHHH
    r"|0?([0-7]{1,3}))")             # \ooo, \0ooo


def _decode_escapes(text):
    """Decode the ANSI-C escapes bash decodes, at bash's digit widths.

    Python's `unicode_escape` codec is NOT a stand-in: it demands exactly four digits
    after `\\u` and eight after `\\U`, so bash's short forms -- `g$'\\u69't` is `git` --
    survived it unchanged and the fallback never saw the verb. Over-decoding here can
    only make more text match, so it adds blocks and never removes one.
    """
    def _sub(m):
        hexit = m.group(1) or m.group(2) or m.group(3)
        try:
            return chr(int(hexit, 16) if hexit else int(m.group(4), 8))
        except ValueError:
            return ""
    return _ESC_RE.sub(_sub, text)


def _ansi_c(text):
    """`$'...'` as bash resolves it: escapes decoded, the `$` prefix dropped."""
    return _decode_escapes(text).replace("$" + _SQ, _SQ)


def _shell_variants(text):
    """The text as written, and as the shell will have rewritten it before running it.

    Quoting, escaping, the ANSI-C `$` prefix and a backslash-newline continuation are
    all removed by the shell before it resolves the command word; ANSI-C escapes are
    DECODED by it, so `g$'\\x69't` is `git`. Every variant is additive -- matching any of
    them blocks -- so this only ever adds a block.
    """
    out = [text, _decode_escapes(text)]
    for base in list(out):
        squeezed = base.replace(chr(92) + chr(10), "")
        for _ch in (_SQ, _DQ, chr(92), "$"):
            squeezed = squeezed.replace(_ch, "")
        out.append(squeezed)
    return out


def _demo():
    """Self-check: the #519 false positives must be allowed, real writes still caught."""
    allowed = [
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
        "echo 'cp this line'",
        "git log --oneline | head -20",
    ]
    blocked = [
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
    ]
    for c in allowed:
        assert not is_file_mod(c), "should be allowed: " + c
    # The GIT cases are here so the superset assertion below actually exercises the
    # git fallback pattern: without them, deleting it left this self-check passing.
    blocked = blocked + [
        "git clean -fd",
        "git restore .",
        "git switch main",
        "git some-unknown-subcmd",
        "git checkout -- src/x",
    ]
    for c in blocked:
        assert is_file_mod(c), "should be blocked: " + c
        # THE FALLBACK MUST BE WIDER, asserted rather than claimed in prose. It stands in
        # for this classifier whenever a command will not parse -- and, in the gate, when
        # this module will not import at all -- so anything the classifier blocks it must
        # block too. It silently was not: no verb pattern matched `git clean -fd`,
        # `git restore .` or `git switch main`, which made a damaged installation of a
        # fail-CLOSED gate fail OPEN.
        assert _regex_fallback(c), "fallback narrower than the classifier: " + c
    # Unparseable (apostrophe in prose) falls back to the regexes, never to "allow".
    unbalanced = "git commit -m \"the operator's skip file\" && rm x"
    assert is_file_mod(unbalanced), "unparseable + rm must fall back to blocking"
    # ...and a fallback on a command with no verb still allows, matching pre-#519.
    assert not is_file_mod("git commit -m \"the operator's skip file\"")
    print("cmdword self-check OK")


if __name__ == "__main__":
    _demo()
