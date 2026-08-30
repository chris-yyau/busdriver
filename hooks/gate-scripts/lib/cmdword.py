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
_BQ = chr(96)

# The original patterns, kept as the unparseable-command fallback.
FILE_MOD_PATTERNS = [
    # `sed` WHOLE, not just the `-i` spelling, for the same reason `git` below is
    # whole: this list stands in for the classifier, so it has to be WIDER than it.
    # The classifier blocks `sed -f -- -i file` (the `--` is -f's script operand, so
    # the `-i` behind it writes in place) and every other arrangement that puts -i
    # somewhere `\bsed\s+-i` cannot see. A narrower fallback is a fail-OPEN on exactly
    # the damaged-installation path this list exists for, and the self-check asserts
    # the superset relation rather than trusting this comment.
    r"\bsed\s",
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

# Set by _defuse_comments when it meets a `#` immediately after a `)` -- see there.
# Read and cleared by is_file_mod, which answers the ambiguity by fail-CLOSED fallback
# rather than by a fourth guess about what the paren was.
_paren_hash_ambiguous = [False]

# A shell function NAME is any word free of the metacharacters that would end it -- bash
# accepts `f-x`, `f.x`, `my:fn`, none of which an identifier charset matches, and all of
# which run. The charset below is stated as the exclusion so it cannot drift behind the
# next punctuation someone puts in a function name; over-matching only ever widens a
# fail-CLOSED test. Quotes and `$` are deliberately left INSIDE it (so `function "f" {`
# and `function $n {` match) and it therefore contains no quote character -- the gate's
# twin lives inside a single-quoted shell block where an apostrophe would end the program.
# Words that OPEN and CLOSE a compound command. A compound command is ONE pipeline stage no
# matter how many separators live inside it, so `printf 'rm -rf src' | if true; then bash; fi`
# and `... | for x in 1; do bash; done` both run the piped program -- verified -- while their
# internal `;` looked like the end of the pipeline. `{`/`}` are the same idea and were the
# first spelling found; braces alone were not the family. Counted as whole WORDS, so
# `"${VAR}"` and a file named `done` are not read as grouping.
_GROUP_OPEN = frozenset(("{", "if", "for", "while", "until", "case", "select"))
_GROUP_CLOSE = frozenset(("}", "fi", "done", "esac"))
# Words that occupy command position without being a command, so the leading-run walk must
# step OVER them to reach a nested opener behind one.
# ...and the PIPELINE PREFIXES, for the same reason: bash allows `time`, `time -p` and `!`
# in front of a compound command, and stopping on one left `time if true; then ...; fi | bash`
# counting no opener while its `fi` still closed.
_GROUP_CONNECT = frozenset(("then", "do", "else", "elif", "time", "-p", "!"))

# COMMAND POSITION, derived from the compound-command keyword sets rather than hand-listed,
# because a hand-listed subset is exactly how `if function f { bash; }; then ...` slipped:
# `then`, `do` and `else` were listed while `if`, `while`, `until`, `!` and `time` were not.
# Anything that can precede a command WITHOUT being one belongs here, and the two sets
# already enumerate that for the depth walk -- so they are the single source, and adding a
# keyword to them extends this too. The trailing repetition covers stacked prefixes
# (`time -p function f { ... }`, `! if ...`).
_CMD_POS_LEAD = (r"(?:\b(?:"
                 + "|".join(sorted(w for w in _GROUP_OPEN | _GROUP_CONNECT if w.isalpha()))
                 + r")\b|!|(?<![\w-])-p\b)")
# ONE prefix, not a repeated group. The `(?:\s*LEAD)*` this used to carry was redundant --
# any single preceding prefix already establishes command position, and `-p` and `!` are
# themselves LEAD alternatives, so `time -p function f` and `! if ...` still match -- and
# it was CATASTROPHIC: 4,000 valid `!` prefixes took 5.4s, past the 5s hook timeout whose
# failure mode is ALLOW. A regex that is correct but too slow is indistinguishable from a
# regex that is wrong, at this boundary.
_CMD_POS = r"(?:^|[\n;&|(){}]|" + _CMD_POS_LEAD + r")\s*"
# The same idea for the `name()` form, which cannot sit behind a group CLOSER or a
# pipeline prefix -- `} f(){` and `! f(){` are not definitions, and admitting them cost
# extra over-blocks and closed nothing. Openers, the case-pattern terminator, and reserved
# words only.
_CMD_POS_WORDS = (r"\b(?:"
                  + "|".join(sorted(w for w in _GROUP_OPEN | _GROUP_CONNECT if w.isalpha()))
                  + r")\b")

_FUNC_NAME = r"[^\s;&|()<>{}]+"

# A function-definition header in COMMAND POSITION: `mv() {`, `rm ( ) {`, and the same
# behind a reserved word, a group opener, or a case PATTERN terminator -- the bare `)`
# of `case x in x) f(){ bash; };; esac` puts the next word in command position just as
# `;` does. `if true; then f(){ bash; }; ...` and
# `{ f(){ bash; }; ... }` define one just as a leading `;` would, and anchoring on separators
# alone missed every such spelling. Shares _CMD_POS_WORDS with the keyword form so the two
# cannot drift apart again. Group 1 keeps the
# whole leading prefix, so the `\1` substitution in _normalize still preserves the segment
# structure around the header it strips.
_FUNC_DEF_RE = re.compile(r"(^|[\n;&|{()]\s*|" + _CMD_POS_WORDS + r"\s*)"
                          + _FUNC_NAME + r"\s*\(\s*\)")

# Constructs that let a NAME stand for something other than itself, IN THIS COMMAND.
# `source` is deliberately absent: it costs 162 over-blocks against the 85 the rest of this
# rule costs, and it does not close the family it belongs to -- a function can equally arrive
# from ~/.bashrc or an exported environment function, neither of which any command text
# reveals. A definition made OUTSIDE the command is the ADR 0006 residual, stated not chased.
# The `function` KEYWORD form defines a function without any `()`, so _FUNC_DEF_RE alone
# missed `function f { bash; }`. Matched against the QUOTE-SQUEEZED copies too, because the
# shell concatenates adjacent quoted runs -- `ev"al" ...` runs eval while the raw text holds
# no contiguous `eval`. The keyword branch requires only the KEYWORD and a name, not a `{`:
# a function body is any compound command, so `function f (( ... ))` and `function f [[ ... ]]`
# define one just as `function f { ... }` does, and enumerating the body shapes is the same
# arity guess this module refuses elsewhere. `function` followed by a word is already a
# definition; the body shape adds nothing.
#
# What the branch DOES require is that the keyword sit in COMMAND POSITION, because
# `function` is also an ordinary word: matching it anywhere costs 95 over-blocks against
# a real 34,758-command corpus (`grep function file | ...`), and this anchor brings that
# to 33 while closing every shape above. That is a STRUCTURAL restriction, not a guess
# about the body -- the shell decides command position, and the separators are finite.
# KEEP IN STEP WITH the gate's _INDIRECTION_RE.
# `hash -p PATH NAME` binds NAME to PATH for the rest of the shell, which is the same
# re-pointing `alias` does. NO PREFIX GRAMMAR AND NO OPTION SEARCH -- both were written,
# both were defeated repeatedly, and both were DELETED rather than refined again.
#
# The prefix went first. Anchoring on command position meant modelling everything bash
# allows in front of a builtin -- `FOO=x`, `A+=x`, any number of them, a leading
# redirection, `builtin`, `command`, `command --`, `command -p` -- and three consecutive
# review rounds each closed one and left the next. Removing the anchor measured ZERO
# further over-blocks: the grammar had been buying bypasses and nothing else.
#
# The `-p` search went the same way. Unbounded it backtracked catastrophically -- 7.2s on a
# valid 59KB command against a 5s hook timeout whose failure mode is ALLOW, so the REGEX was
# the fail-open. Bounded to 120 characters it was defeated by 121 spaces, because bash
# ignores horizontal whitespace. Any bound in CHARACTERS is a guess at how far an option may
# sit from its verb. Matching the word alone costs 69 over-blocks (1,509 against 1,440 at the round it was measured,
# measured on the same corpus), has no bound to defeat and nothing to backtrack.
# `\b` keeps `hashlib` out; `git hash-object` is in, and is part of that 69.
_HASH_REMAP = r"\bhash\b"
# `BASH_CMDS` is the hash table itself, exposed as a writable associative array: assigning
# to it binds a NAME to a path exactly as `hash -p` does, without ever naming the builtin.
# Verified executing. The subscript is not parsed -- an assignment to this array at all is
# the signal, and there is no read-only spelling of it worth distinguishing.
_BASH_CMDS_RE = r"\bBASH_CMDS\s*\["
_INDIRECTION_RE = re.compile(r"\b(?:eval|alias)\b"
                             r"|" + _CMD_POS + r"function\s+" + _FUNC_NAME
                             + r"|" + _HASH_REMAP
                             + r"|" + _BASH_CMDS_RE)


def _has_indirection(cmd):
    """Does this command let a NAME stand for something other than itself?"""
    # BOTH the raw text and the NORMALIZED text. The pipeline walk runs on the normalized
    # copy, where a backslash-newline continuation has been rejoined and `${IFS}` restored to
    # whitespace -- so `ha\<newline>sh -p ...` and `hash${IFS}-p${IFS}...` are indirection the
    # walk can see while the raw text spells neither. Asking only the raw text left both
    # open; asking both cannot subtract a match and measured no further cost.
    return any(_INDIRECTION_RE.search(v) or _FUNC_DEF_RE.search(v)
               for text in (cmd, _normalize(cmd))
               for v in _shell_variants(text))


# NOT CLOSED, deliberately: a producer that ASSEMBLES its payload rather than stating it --
# `P='rm -rf src'; printf '%s' "$P" | bash`, and the split-operand `printf '%s%s' r
# 'm -rf src' | bash` the issue itself calls unrecoverable. A rule keyed on "the producer
# expands a variable this command assigns" was written and measured: it closes the first
# spelling and costs 386 over-blocks (1.1% of a real 34,758-command corpus), while leaving
# the second -- and every runtime-assembled spelling -- open. Closing the CLASS needs an
# interpreter, not a tokenizer. Stated as an ADR 0006 residual instead. See ADR 0032.

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


def _split_with_ops(s):
    """Split into simple-command segments, each paired with the operator run before it.

    Copied from the anti-forge detector in pre-implementation-gate.sh, where the
    reasoning is documented at length: this MUST happen before shlex, because posix
    shlex strips quoting and would make a quoted separator indistinguishable from a
    real one. Returns (pairs, ok); ok is False on an unterminated quote or dangling
    escape so the caller can fall back rather than trust a half-parse.

    The operator is kept as a RUN rather than a single character so `|` can be told from
    `||`: one feeds a segment its stdin, the other feeds it nothing. Consecutive operator
    characters join into one run only when no segment text sits between them, which is
    exactly the difference between `a || b` (run `||`) and `a | ; b`.
    """
    pairs, buf, op = [], [], []
    in_s = in_d = esc = in_b = False
    # Did the PREVIOUS character open a redirect -- an unquoted, unescaped `<` or `>`?
    # Tracked rather than read back off buf[-1], because the buffer cannot tell an
    # OPERATOR `<` from a literal one: bash runs `printf <payload> \<|bash` as a real
    # pipeline, since the escaped `<` is an argument and the `|` that follows is the pipe.
    # The inferred version glued that `|` into the segment and lost the pipeline entirely.
    redir = False
    xglob = 0                             # open EXTGLOB parens -- see the branch below
    for _i, ch in enumerate(s):
        _nxt = s[_i + 1:_i + 2]
        if esc:
            buf.append(ch)
            esc = redir = False
        elif in_s:
            buf.append(ch)
            if ch == _SQ:
                in_s = False
            redir = False
        elif in_b:
            # A BACKTICK SUBSTITUTION is one word of the stage it sits in, however many
            # control operators its body holds: bash runs `printf <payload> | echo `true &&
            # bash`` as a TWO-stage pipeline, and the nested shell inherits the pipe. Read
            # as outer separators, that `&&` ended the pipeline before the receiver was
            # reached and the producer was discarded -- verified executing (#563). Tracked
            # as STATE, exactly like the two quote states above and for the same reason: the
            # buffer cannot say whether a character it already emitted was inside a span.
            # The body still gets classified as code -- `_command_substitutions` extracts it
            # and recurses -- so making it opaque HERE removes no block.
            buf.append(ch)
            if ch == "\\":
                esc = True                # in_b survives the escape: only `esc` is consumed
            elif ch == _BQ:
                # ...and back into the double quotes if that is where the span opened:
                # `in_d` is never cleared by the branch below, so there is no state to
                # restore here.
                in_b = False
            redir = False
        elif in_d:
            buf.append(ch)
            if ch == "\\":
                esc = True
            elif ch == _BQ:
                # A backtick INSIDE double quotes still opens a substitution -- bash runs
                # `echo "`echo "x && cat"; bash`"`, and the quotes inside the body belong to
                # the body's own command, not to the outer string. Checked BEFORE `in_d`
                # above so the inner span wins; `in_d` is deliberately left True, so closing
                # the span returns to the string with no saved-state bookkeeping. Ordered
                # after `in_d` in the first cut of #563, this branch was unreachable from a
                # quoted context: the body's second `"` read as the outer string's CLOSE,
                # the `&&` behind it split the stage, and the producer was discarded again
                # -- verified executing.
                in_b = True
            elif ch == _DQ:
                in_d = False
            redir = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
            redir = False
        elif ch == _BQ:
            buf.append(ch)
            in_b = True
            redir = False
        elif ch == _SQ:
            buf.append(ch)
            in_s = True
            redir = False
        elif ch == _DQ:
            buf.append(ch)
            in_d = True
            redir = False
        elif ch in "|&" and redir:
            # `>|` (clobber), `>&` and `<&` (descriptor duplication). `<&` was missed while
            # its output twin was handled, and it splits the segment mid-redirect: the
            # producer of `printf <payload> <&0 | bash` became the bare `0`. Keyed on the
            # REDIRECT CHARACTER rather than on a list of operators, so the next spelling
            # cannot reintroduce the asymmetry.
            buf.append(ch)
            redir = False
        elif ch == "(" and buf and buf[-1] in "+*?@!":
            # EXTGLOB, not a group: with `shopt -s extglob`, `+(s)`, `*(…)`, `?(…)`, `@(…)`
            # and `!(…)` are pathname patterns, so `/bin/ba+(s)h` expands to `/bin/bash`.
            # Split on the paren, the receiver command word came apart and the shell name
            # vanished. The lead character is what distinguishes them, and it is finite.
            buf.append(ch)
            xglob += 1
            redir = False
        elif xglob and ch in ";|&":
            # INSIDE a pattern, every control character is pattern text: `@(s|z)` holds a
            # real `|` that separates alternatives, not pipeline stages. Keeping the parens
            # while still splitting on that `|` left the receiver in pieces again.
            buf.append(ch)
            redir = False
        elif ch == ")" and xglob:
            # its matching close -- kept with it, or the command word still comes apart on
            # the other half of the pattern.
            buf.append(ch)
            xglob -= 1
            redir = False
        elif ch == "&" and _nxt == ">":
            # `&>` / `&>>` redirect BOTH streams -- the `&` belongs to the redirect, not to
            # the pipeline. Read as a control operator it cuts the segment in two and throws
            # the real producer away. KEEP IN STEP WITH the gate's _split_with_ops, which
            # carried this while this copy did not.
            buf.append(ch)
            redir = False
        elif ch in ";|&()":
            if buf or not op:
                pairs.append(("".join(op), "".join(buf)))
                buf, op = [], [ch]
            else:
                op.append(ch)           # the run continues: ||, &&, |&
            redir = False
        else:
            buf.append(ch)
            redir = ch in "<>"
    pairs.append(("".join(op), "".join(buf)))
    # An unterminated backtick joins the unterminated quote and the dangling escape: the
    # caller falls back to the wider raw scan rather than trusting a half-parse.
    return pairs, not (in_s or in_d or esc or in_b)


def _split_simple_commands(s):
    """The segments alone, for callers that do not care what separated them."""
    pairs, ok = _split_with_ops(s)
    return [seg for _op, seg in pairs], ok


def _is_pipe(op):
    """Does this operator run FEED the segment after it? `|` and bash's `|&` do; `||`,
    `&&`, `;` and grouping do not."""
    # GROUPING punctuation joins the run when no segment text separates it, so a valid
    # `cmd ||(sub)` arrives as `||(` and read as a pipe -- an over-block the spaced
    # `|| (sub)` never had. Parens carry no pipeline meaning here (the depth walk
    # owns them), so they are dropped before the test rather than special-cased.
    bare = op.replace("(", "").replace(")", "")
    return bare in ("|", "|&")


def _lex(text):
    """Tokenize one segment the way this module does everywhere else, or None."""
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        return list(lex)
    except ValueError:
        return None


# Shells that run a program fed to them on STDIN. A SUPERSET of _SHELLS, and kept separate
# from it deliberately: _SHELLS answers "does `-c` mean execute-this-string", which is a
# claim about option semantics this module acts on by RECURSING into the operand. This set
# answers only "could this consume stdin as a program", which is a weaker claim with a
# cheaper failure mode -- so csh/tcsh/fish belong here without dragging their -c handling,
# their `<<<` handling, or their wrapper semantics along with them. Verified by running
# each: `printf 'echo X\n' | csh` executes.
# RESIDUAL, stated rather than pretended away: this is an ENUMERATION, so a shell nobody has
# listed still reads as a non-shell. The family does not close (yash, posh, bosh, osh, oil,
# elvish, xonsh, nu are here; the next one will not be). Same call as ADR 0006 -- an unlisted
# name only helps an actor who already has Bash, and every gated write still needs a logged
# lease. Adding a name is free, so add rather than argue when one is found.
# The last six are not shells at all, but they RUN A PROGRAM READ FROM STDIN exactly as a
# shell does -- `printf <program> | python3` runs it, and so do perl, ruby and node --
# and that is the only question this set answers. Kept separate from _SHELLS for the
# reason below: _SHELLS asserts that `-c` means execute-this-string, which is a claim
# this module ACTS on by recursing into the operand, and none of these inherit it.
# Measured at 95 further over-blocks. KEEP IN STEP WITH the gate's _SHELL_NAMES.
# `source` is deliberately ABSENT, unlike the rest of this set. It is handled in COMMAND
# POSITION ONLY, alongside `.` below -- an any-word match here cost a real over-block
# (`printf 'rm -rf src' | grep source` blocked on the bare word `source` appearing as a
# grep PATTERN, not a command). Raised by Codex on #562, verified. `xargs` stays IN this
# set despite Codex raising the same "default command is harmless echo" argument for it:
# `printf 'rm -rf src' | xargs` is PINNED to block by tests/test-impl-gate-scope-519.sh
# ("xargs executes what it reads from stdin") and its 3000-command property fixture, which
# both treat this as the deliberate fail-CLOSED direction this module chooses throughout
# (an unlisted or defaulted receiver blocks rather than reads clean) -- narrowing it here
# would regress a decision the suite already locked in, not fix a bug. KEEP IN STEP WITH
# marker_check._SHELL_NAMES.
# `lldb` alongside `gdb`: when installed, LLDB treats piped stdin as debugger commands and
# its `platform shell` command runs an arbitrary shell command on the current platform
# (its own built-in help: "Run a shell command on the current platform"). Verified against
# a real `lldb` binary (`printf 'platform shell touch <marker>\nquit\n' | lldb` executes
# the marker touch). Raised by Codex on #562. KEEP IN STEP WITH marker_check._SHELL_NAMES.
# `jshell` and `sftp` join the debuggers as programs whose stdin IS a command language:
# `jshell -s -` documents `-` as standard input and runs the Java snippets it reads, and
# `sftp -b -` reads its batch commands from stdin, where `!cmd` runs a LOCAL shell command.
# Both raised by Codex on #562 against real binaries. Bare names, so they are answered
# wherever a receiver is asked -- `sftp` without `-b` still reads stdin as commands when
# stdin is not a tty, so the name rather than the flag is the honest condition.
#
# KNOWN RESIDUAL, PRE-EXISTING and not specific to these two names: the producer scan reads
# the payload as SHELL TEXT. Every non-shell interpreter in this set takes a payload in its
# OWN language, and that language's write idioms are invisible to shell regexes --
# `import os; os.remove(x) | python3`, `require("fs").unlinkSync(x) | node` and
# `new java.io.File(x).delete(); | jshell` all measure False, and measured False identically
# at af82155, before this change. So adding a name here buys the SHELL-payload and
# literal-helper cases, not the language ones. Closing those means treating a stdin-fed
# non-shell interpreter as OPAQUE and failing closed, which would block every
# `printf ... | python3` -- a policy change with a blast radius that deserves its own
# change and its own decision, not a quiet ride-along here.
_STDIN_SHELLS = _SHELLS | frozenset(("csh", "tcsh", "fish", "yash", "posh", "bosh",
                                     "osh", "oil", "elvish", "xonsh", "nu",
                                     "python", "python2", "python3",
                                     "perl", "ruby", "node",
                                     "tclsh", "wish", "lua", "php",
                                     "awk", "gawk", "mawk", "nawk",
                                     "sqlite3", "ed", "ex", "psql", "gdb", "lldb",
                                     "jshell", "sftp",
                                     "xargs", "make"))

# VERSION-QUALIFIED spellings of the interpreters above: `/usr/bin/python3.12` is a real
# executable name (`python3.12 --help` documents stdin as a program source, `[-c cmd |
# -m mod | file | -]`), so `printf 'os.system(...)' | python3.12` runs it, and the exact-name
# set above does not match it. Raised by Codex on #562, verified against a real
# `python3.12` binary. A name this exact-name set already knows, wearing a version suffix,
# not a new interpreter family -- the same scope marker_check.py's sibling `_INTERP_RE`
# already carries (`python[0-9.]*`).
# EXTENDED beyond python: `/usr/bin/perl5.38.2` and `/usr/bin/tclsh8.6` are equally real,
# packaged executable names, and `is_file_mod` returned False for a piped write payload fed
# to either -- verified against real `perl5.38.2` and `tclsh8.6` binaries. Raised by Codex
# on #562 as a fresh case beyond the python fix. Covers the interpreter names above that
# ship version-qualified spellings in practice (python/perl/ruby/node/lua/php/tclsh/wish);
# the shell family (bash/zsh/csh/...) is not extended here because those are not commonly
# packaged with a numeric suffix in PATH. `wish` ships beside `tclsh` from the same Tcl/Tk
# package and is version-qualified the same way (`/usr/bin/wish8.5`), so omitting it left
# exactly the bypass its sibling closes.
# UNANCHORED on purpose: the attached-option-bundle check below asks whether a dash-word
# ENDS WITH an interpreter name (`env -iSpython3.12`), which needs a search rather than a
# whole-string match. Callers wanting the whole-name question use fullmatch.
# ATTACHED versions only (`python3.12`, `python3.13t` -- the free-threaded build wears a
# trailing `t`). This pattern is asked of EVERY WORD in a stage, so it may only accept
# shapes ordinary data never has: an interpreter name glued to digits is one, a
# DASH-separated version is not. `lldb-19` and `gdb-14` are real packaged spellings, but
# `grep lldb-19` is an equally real grep, so they belong to the command-position class
# answered in COMMAND POSITION by `_CMDPOS_INTERP_RE` (#565) -- the bare names `lldb`/`gdb`
# are in the exact-name set and unaffected.
# The numeric requirement is what keeps the rest safe to ask
# of every word: `python3-report` and `python3-report-final-copy` are ordinary hyphenated
# data, and matching them read a word `grep` merely searches for as an interpreter.
#
# A MULTIARCH name (`perl5.36-x86_64-linux-gnu`) is still deliberately NOT matched here --
# its suffix is non-numeric, so any pattern loose enough to accept it also accepts the
# hyphenated data above. It is answered in COMMAND POSITION instead, by
# `_CMDPOS_INTERP_RE` below (#565).
# KEEP IN STEP WITH marker_check._VERSIONED_INTERP_RE.
_VERSIONED_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)$")

# The same names for the ATTACHED-bundle question -- does a dash-word END WITH an
# interpreter (`env -iSpython3.12`) -- which is a SEARCH, not a whole-name match. The
# dash-separated version is deliberately absent here: `--label=issue-lldb-19` ends with
# one, and searching for it turned an option's DATA into a receiver. A whole name can
# afford the dash because nothing precedes it; a suffix search cannot.
# KEEP IN STEP WITH marker_check._ATTACHED_INTERP_RE.
_ATTACHED_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)$")

# Receiver spellings that are receivers ONLY in COMMAND POSITION (#565). Both wear a shape
# ordinary data also wears, so neither can join the any-word patterns above:
#   * MULTIARCH -- the platform triplet rides on the versioned name itself
#     (`/usr/bin/perl5.36-x86_64-linux-gnu`, a real Debian spelling). Its suffix is
#     non-numeric, so an any-word pattern admitting it also admits `python3-report-final-copy`,
#     a word `grep` merely searches for. Two-or-more dash components are REQUIRED, which is
#     what keeps `python3-config` -- a real command that does NOT read a program from stdin --
#     out of it.
#   * DASH-VERSIONED DEBUGGERS -- `lldb-19`, `gdb-14` are real packaged names, but
#     `grep lldb-19` is an equally real grep and `--label=lldb-19` an equally real option
#     value. The bare `lldb`/`gdb` stay in the exact-name set and are unaffected.
# Command position is what makes both safe: data never lands there. The walk that decides
# it is `_runs_cmdpos_receiver`, which every receiver site asks.
# ACCEPTED RESIDUALS, both the same trade this module makes throughout -- over-block rather
# than miss -- and both confined to COMMAND POSITION, where the allow controls do not live:
#   * an option's own OPERAND is indistinguishable from a program without an arity table, so
#     `sudo -u lldb-19 grep x` -- a user account named like a packaged debugger -- over-blocks.
#   * the multiarch branch tests the SHAPE, not an arch/os/abi enumeration, which #562 rejected
#     for failing OPEN on every triplet it did not list. So a command literally named
#     `python3-report-final-copy` over-blocks -- while `grep python3-report-final-copy`, the
#     control the issue names, is data position and unaffected.
#   * a SHORT option carrying an attached value is indistinguishable from a bundle of flags:
#     `sudo -uroot grep lldb-19` claims nothing further, but `sudo -nu root <name>` is `-n`
#     plus `-u root` and does. The `--long=value` spelling IS unambiguous and is handled, so
#     only the short form pays. Fail CLOSED: the first over-blocks so the second cannot slip.
# Fully qualified names only, so `perl-5.36-x86_64-linux-gnu` (no attached version) is not
# matched; no such name ships. KEEP IN STEP WITH marker_check._CMDPOS_INTERP_RE.
# OUT OF SCOPE here: the HERE-STRING transport (`<name> <<< '<payload>'`) does not ask this
# predicate, and deliberately so. `<<<` is a redirection rather than a pipeline, and THIS
# file's `<<<` handling recognizes only `_SHELLS` -- verified against HEAD, where `lldb <<<`,
# `gdb <<<`, `python3 <<<` and `perl5.38.2 <<<` all measure False, so the gap covers the
# whole receiver family and predates this change. (The twin does NOT share it: marker_check's
# here-string path asks `_is_shell_name`, so it already answers the bare and version-qualified
# names -- a PRE-EXISTING desync, and one this change neither widens nor narrows. The class
# below is missed by BOTH, consistently.) Closing it means broadening this file to the bare
# `_STDIN_SHELLS` names too, which is a family-wide change rather than a #565 one; covering
# the dash-versioned `lldb-19 <<<` while the bare `lldb <<<` stayed open would be a worse
# inconsistency than the uniform gap. Tracked for its own change, not half-landed here.
_CMDPOS_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)"
    r"-[0-9A-Za-z_]+(?:-[0-9A-Za-z_]+)+"
    # ...and `gdb-multiarch`, the one non-numeric dash suffix these two ship: a real Debian
    # binary that reads GDB commands from stdin exactly as bare `gdb` does. Named rather
    # than pattern-matched, because a general non-numeric dash suffix is precisely the shape
    # ordinary data wears.
    r"|(?:lldb|gdb)-(?:[0-9]+(?:\.[0-9]+)*|multiarch)")

# WRAPPERS whose first POSITIONAL word is an operand rather than the command they run:
# `flock <file|dir> <cmd>`, `chroot <newroot> <cmd>`, `su`/`runuser <user>`, `script
# <typefile>`. To `_runs_cmdpos_receiver` that operand is the same could-have-been-eaten
# shape a value option's operand has, so the run must survive it -- without this,
# `flock /tmp/l perl5.36-x86_64-linux-gnu` spent its candidate on the LOCK FILE and read
# the interpreter behind it as data. Deliberately SMALL and only these: a wrapper wrongly
# listed here keeps the run alive one word too long and over-blocks, while one MISSING is
# the pre-#565 answer. `timeout <duration>` needs no entry -- its operand is numeric, which
# the walk already steps over -- but `timeout` is listed anyway, because GNU timeout also
# accepts `infinity`, `inf` and `1e9`, which are ordinary words to that test.
# KEEP IN STEP WITH marker_check._OPERAND_WRAPPERS.
_OPERAND_WRAPPERS = frozenset(("flock", "chroot", "su", "runuser", "script",
                               "timeout"))



# `env` under BOTH its spellings: Homebrew installs GNU coreutils with a `g` prefix, so
# `genv -S` on macOS is the same command with the same re-parsing semantics.
# KEEP IN STEP WITH the twin.
_ENV_NAMES = frozenset(("env", "genv"))


def _env_names_split_string(w):
    """Does this `env` option word carry `-S` / `--split-string`, in ANY spelling?

    CONTENTS are deliberately not examined. env RE-PARSES a split-string operand as a
    fresh argument vector, and that result can be another env option word, to any depth
    (`-S "-i -S '-iSlldb-19'"`). Every attempt to answer "does the operand name a shell"
    had to unwrap one more layer than the last -- across attached bundles, separated
    operands, abbreviated long options, and shell quoting, each of which erases a boundary
    the next layer needs. So the ANSWER is the presence of the option: `env -S` hands the
    rest to execvp with this pipe still on stdin, and what it hands over is not
    reliably knowable from the un-run text. The residual is an over-block on an env -S
    running something inert, which is the direction this module chooses everywhere else.

    Env's SHORT options are still parsed rather than pattern-matched, because `u` and `C`
    take the remainder of the word as their OWN operand -- an `S` inside one is data, and
    matching it read `env -uFOOSlldb-19 grep x`, which merely unsets a variable, as a
    receiver. Long options may be ABBREVIATED to any unambiguous prefix, attached or
    separated. KEEP IN STEP WITH the twin.
    """
    _name = w.partition("=")[0]
    if _name.startswith("--") and len(_name) > 2 and "split-string".startswith(_name[2:]):
        return True
    if w == "-S":
        return True
    if not w.startswith("-") or w.startswith("--"):
        return False
    for c in w[1:]:
        if c == "S":
            return True
        if c in ("u", "C"):
            return False               # the rest is THIS option's operand
        if c not in ("i", "0", "v"):
            return False               # not an env option bundle
    return False





def _is_stdin_shell(name):
    """Does this basename read a program from stdin -- exactly, or version-qualified?"""
    return name in _STDIN_SHELLS or bool(_VERSIONED_INTERP_RE.fullmatch(name))


def _runs_cmdpos_receiver(toks):
    """Does this simple command RUN a command-position-only receiver (#565)?

    The two questions the sites used to ask separately -- "which word runs" and "is that
    word a receiver" -- asked together, so a new receiver class is added to
    `_CMDPOS_INTERP_RE` once instead of site by site.

    A WRAPPER preamble is the whole difficulty, and it is answered WITHOUT an option-arity
    table -- the table this module refuses to keep, because every gap in one fails OPEN.
    A one-guess walk cannot do it: `_effective_command_word("sudo -u root <name>")` stops at
    `root`, the operand of `-u`, while `sudo grep lldb-19` must stop at `grep`. Every
    single-guess rule tried here bought one shape and lost another -- an option's operand
    versus a wrapper's positional, a flag versus a value option, a lock file versus a
    redirection -- because each of those pairs is genuinely indistinguishable in un-run text.

    So this does not guess. It carries the SET of readings the preamble still permits, one
    per way the tokens so far could have been parsed, and asks each of them whether THIS word
    is the program. A word is a receiver if ANY surviving reading says it runs -- ambiguity
    resolves toward blocking, as it does everywhere else in this module. The set is bounded
    by the four flags below, so it can never exceed a handful of entries and the walk stays
    linear.

    What keeps the allow controls intact is that most preambles are NOT ambiguous. `sudo grep
    lldb-19` admits exactly one reading, in which `grep` runs and the debugger name behind it
    is its data. Ambiguity appears only where an arity is genuinely unknown, and there it
    costs precision rather than safety.

    ACCEPTED OVER-BLOCK, the price of refusing to guess: an operand-taking wrapper carrying a
    FLAG (`flock -n /tmp/l grep lldb-19`) reads `-n` as possibly consuming the lock file, so
    the program may be one word further along and `lldb-19` is asked. Blocking a `-n` flock
    whose grep pattern is spelt like a packaged debugger is the direction this module chooses
    throughout.
    KEEP IN STEP WITH marker_check._runs_cmdpos_receiver.
    """
    # Each reading is (skip_next, prev_opt, wrapper_operand, opts_ended, runs):
    #   skip_next        -- a bare redirection operator took the next token as its target
    #   prev_opt         -- an option is outstanding and may still claim an operand
    #   wrapper_operand  -- a NAMED wrapper's own positional is still outstanding
    #   opts_ended       -- a `--` in THIS command turned every later dash-word into data
    #   runs             -- the next plain word could still be the program
    states = {(False, False, False, False, True)}
    for t in toks:
        m = _REDIR_RE.match(t)
        b = _basename(t)
        # A long option whose value is ATTACHED cannot claim a separate operand,
        # so it must not keep command position alive past the real program:
        # `env --unset=FOO grep lldb-19` promoted grep's argument and falsely blocked.
        _attached_value = t.startswith("--") and "=" in t
        _operandish = _ASSIGN_RE.match(t) or _NUMERIC_RE.match(t)
        nxt = set()
        for skip, popt, wop, oend, runs in states:
            if skip:
                nxt.add((False, popt, wop, oend, runs))
                continue
            if wop:
                # A wrapper's outstanding positional absorbs THIS token under every reading,
                # whatever it is spelt like -- a lock file may be called `time`, `-n` or `>`.
                # So the token is never the program here; the only question is what it
                # settles, and each answer that the text permits becomes its own reading.
                if t != "--" or oend:
                    # ...the positional. A `--` can only be it once the options have ALREADY
                    # ended -- while they are still open getopt consumes the `--` itself as
                    # the terminator, before the wrapper's operand is read, so letting it
                    # satisfy the slot made `flock -- lldb-19 grep x` read the LOCK FILE as
                    # the program and falsely block. Past a first `--` the word is ordinary
                    # again, so `flock -- -- lldb-19` locks a file called `--` and runs the
                    # debugger. (When an option is outstanding, `--` can still be ITS
                    # operand -- that reading is added just below.)
                    nxt.add((False, popt, False, oend, runs))
                if popt:
                    nxt.add((False, False, True, oend, runs))      # ...the option's operand
                if m:
                    nxt.add((m.group(0) == t, popt, True, oend, runs))   # ...a redirection
                if t == "--" and not oend:
                    nxt.add((False, False, True, True, runs))      # ...the end of options
                elif t.startswith("-") and not oend:
                    nxt.add((False, not _attached_value, True, oend, runs))   # ...another option
                continue
            if m:                     # a BARE operator takes the next token as its target
                nxt.add((m.group(0) == t, popt, wop, oend, runs))
                if popt:
                    # ...or the OPTION's operand, quoting having been erased by the lexer:
                    # `env -C '>' <name>` changes into a directory called `>` and runs the
                    # interpreter, while the redirection reading alone swallowed it.
                    nxt.add((False, False, wop, oend, runs))
                continue
            if t == "--" and not oend:
                # END OF OPTIONS, for the command that carried it -- and only the FIRST one:
                # once the options have ended a second `--` is an ordinary word, so
                # `flock -- -- lldb-19` locks a file called `--` and runs the debugger.
                # It claims no operand of its own, and a nested command re-opens parsing.
                nxt.add((False, False, wop, True, runs))
                if popt:
                    # ...or the OUTSTANDING OPTION's operand, a variable or file literally
                    # named `--`: `env -u -- -i lldb-19` unsets `--`, reads `-i`, and runs
                    # the debugger. Options are still parsing under that reading.
                    nxt.add((False, False, wop, oend, runs))
                continue
            if t.startswith("-") and not oend:
                nxt.add((False, not _attached_value, wop, oend, runs))
                continue
            if _operandish:           # an assignment prefix, or a bare numeric operand
                nxt.add((False, False, wop, oend, runs))
                continue
            if b in _TEST_OPEN:
                if popt:
                    # ...unless an option is outstanding, in which case this is its OPERAND
                    # and not a test at all: `env -u '[' lldb-19` unsets a variable named
                    # `[` and runs the debugger. Dropping the reading emptied the set here.
                    nxt.add((False, False, wop, oend, runs))
                continue              # otherwise a test expression runs no command
            # PREAMBLE NAMES -- wrappers, reserved words and MULTI-CALL DISPATCHERS, whose
            # applet is the real command (`busybox env <name>` runs the interpreter).
            # `_ENV_NAMES` is asked ALONGSIDE `_WRAPPERS`, which holds `env` but not the
            # Homebrew GNU spelling `genv`: without it `genv lldb-19` spent the run on
            # `genv` as an ordinary program and allowed the piped interpreter behind it.
            # Asked here rather than by widening `_WRAPPERS`, so no other site's reading
            # of that set moves. Raised by Cursor Bugbot on #766.
            if (b in _RESERVED or b in _WRAPPERS or b in _CMD_PREFIX_WORDS
                    or b in _ENV_NAMES):
                # The NESTED-COMMAND reading: this name is the wrapper, reserved word or
                # dispatcher it looks like, and a nested command re-opens option parsing.
                nxt.add((False, False, b in _OPERAND_WRAPPERS, False, runs))
                if not popt:
                    continue          # unambiguous -- nothing outstanding could claim it
                # ...else fall through as well. With an option outstanding the word may be
                # its DATA instead (`env -u timeout <name>`), and the option may equally
                # have been a FLAG that claims nothing (`env -i flock /tmp/l <name>`), so
                # both readings have to survive.
            if not runs:
                continue              # past the program under this reading: it is data
            if _CMDPOS_INTERP_RE.fullmatch(b):
                return True
            # ...not the program, so the program is behind us -- unless an option could have
            # claimed this word, in which case it may still be ahead.
            nxt.add((False, False, wop, oend, popt))
        if not nxt:
            return False              # no reading survives: nothing here runs a receiver
        states = nxt
    return False


def _cmdpos_receiver_in_any_simple_command(text):
    """`_runs_cmdpos_receiver` asked of EVERY simple command in this text.

    An executed operand is a whole PROGRAM, not one command: `flock /tmp/l -c 'true; sudo
    -u root perl5.36-x86_64-linux-gnu'` puts the receiver in the SECOND command, and a walk
    handed the operand's flat token stream stops at `true`. Same split-then-ask shape
    `_launcher_in_any_simple_command` already uses beside it, with the same fail-CLOSED
    exits -- text this cannot split or lex has not been read, and unread blocks.
    KEEP IN STEP WITH marker_check._cmdpos_receiver_in_any_simple_command.
    """
    segs, ok = _split_simple_commands(text)
    if not ok:
        return True
    for s in segs:
        t = _lex(s)
        if t is None:
            return True
        if _runs_cmdpos_receiver(t):
            return True
    return False

# LAUNCHERS that exec a shell when given NO program operand, so a pipe feeds that shell:
# util-linux `script`, and `su` / `runuser` / `chroot` / `unshare` / `nsenter`, all of which
# drop to `$SHELL` absent a command. Raised by Codex on #562 (verified there against
# `script -q /dev/null`; NOT reproducible on macOS, where `script` wants a tty and hangs,
# so the payload survived) and completed by the pre-commit review, which pointed out that
# `runuser` is already modelled beside `su` in `_WRAPPERS`.
#
# Deliberately NOT in `_STDIN_SHELLS`: that set is matched against EVERY word in the stage,
# and these are ordinary English words, so `echo x | grep script` would flip from allow to
# block. This is the same reasoning that keeps `.` out of it -- putting `.` in the any-word
# set cost 100 over-blocks. Tested in COMMAND POSITION only, which is the only position
# where the launcher actually launches anything.
_LAUNCHER_SHELLS = frozenset(("script", "su", "runuser", "chroot", "unshare",
                              "nsenter", "newgrp", "sg"))
# RESIDUAL, stated rather than pretended away, exactly as for `_STDIN_SHELLS`: this is
# an ENUMERATION and the family does not close. `newgrp`/`sg` were added a round after
# the first six, by a reviewer naming them rather than by any rule deriving them.
# Adding a name is free and costs nothing outside command position, so add rather than
# argue when one is found. Containment is the same as ADR 0006: an unlisted name only
# helps an actor who already holds Bash, and every gated write still needs a logged lease.
# Words that sit BEFORE the command without being it. An assignment prefix is any
# `NAME=value` token; the rest are keyword prefixes bash allows ahead of a command. They are
# skipped when looking for the launcher, because `FOO=1 unshare` and `time script` both put
# a launcher in command position just as surely as a bare `unshare` does.
# `busybox`/`toybox` are MULTI-CALL DISPATCHERS: the applet name after them is the real
# command, and busybox's own unshare applet execs $SHELL when given no program, so
# `busybox unshare` launches a shell exactly as a bare `unshare` does. Modelled as a
# prefix rather than a launcher, so `busybox grep script` still reads as grep.
_CMD_PREFIX_WORDS = frozenset(("time", "command", "exec", "nohup", "builtin", "!",
                               "busybox", "toybox"))
# A REDIRECTION may sit anywhere in a simple command, including AHEAD of the command word
# (`2>/dev/null unshare` runs unshare), so the walk below steps over both halves of one.
# `_REDIR_RE` above is REUSED rather than re-spelled: a second redirection expression in
# this file would shadow it for every other parser walk, which is exactly the fail-open a
# review round caught here. Note `_lex` runs shlex with punctuation_chars, so an fd number
# is lexed APART from its operator -- `2>/dev/null` arrives as `2`, `>`, `/dev/null`, and
# the bare digit is not a redirection by itself.
# A COMPOUND stage hands the pipe to the command INSIDE it -- `| { unshare; }` and
# `| if unshare; then :; fi` both do -- so the walk has to see past the introducer. The
# reserved words are the same sets the grouping rules already use, and they count in
# COMMAND POSITION ONLY: the rule that keeps `grep -n done log` allowed applies here too,
# so `| grep for script` does not read `script` as a command.
#
# Splitting into simple commands is done by the CALLER, on the raw text, because doing it
# from tokens is quote-blind: shlex erases the difference between a `;` that separates
# commands and one that is an operand, so `| grep \; unshare` read `unshare` as a command
# word and over-blocked.
_COMPOUND_WORDS = _GROUP_OPEN | _GROUP_CLOSE | _GROUP_CONNECT
# An assignment prefix needs a valid IDENTIFIER before the `=`. Testing for a bare `=`
# anywhere read `./foo=bar unshare` as a prefix and then took `unshare` for the command.
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*(?:\[[^]]*\])?\+?=")
# Compound openers whose next word is a VARIABLE or a SUBJECT rather than a command.
_GROUP_HEADERS = frozenset(("for", "select", "case"))
# `sudo` and `doas` are WRAPPERS, not launchers -- except in their shell modes, where a
# flag and no command operand start a shell that then reads the pipe (`sudo -s`, `sudo -i`,
# `sudo --shell`, `doas -s`). Proving there is no command operand needs the option-arity
# table this module refuses, so the FLAG is what is matched. Only the lowercase letters
# count: `-S` reads the PASSWORD from stdin, which consumes the pipe as data rather than as
# a program, and the uppercase flags carry no shell mode.
_SHELL_MODE_WRAPPERS = frozenset(("sudo", "doas"))
# The flag is matched in the wrapper OWN option run only -- the run ends at the first word
# that is not an option, so `sudo grep -i needle` never offers grep option to this test.
# A BUNDLE counts only when every letter in it is a no-argument flag (`-ns`); a letter that
# takes a VALUE means the rest of the token is that value, and reading `-ualice` as flags
# blocked an ordinary `sudo -ualice grep needle`. That list is short, closed and documented
# in the sudo and doas manuals, and being wrong about a letter costs a MISS on an exotic
# spelling rather than a block on an ordinary one.
#
_SHELL_MODE_LONG = frozenset(("--shell", "--login"))
_SHELL_MODE_NOARG = frozenset("AbEHKknPSsVvilL")


def _has_shell_mode_flag(toks):
    """Is a sudo/doas SHELL-MODE flag among these words?

    No option run, no value skipping, no arity: every word is asked. Scoping it to the
    wrapper own option run needed to know which options take a VALUE -- `sudo -u root -s`
    hid the flag behind an operand, and `sudo --user root --shell` hid it behind a long
    one -- and every attempt to model that was another row of the table this module
    refuses. The whole-stage scan is the same regime a wrapper already selects everywhere
    else here, with the same documented price: a word in the WRAPPED command data reads as
    the flag, so `sudo grep -i needle` blocks exactly as `sudo grep rm notes.txt` already
    did. A BUNDLE counts only when every letter is a no-argument flag, so `-ualice` is
    `-u` with its value attached rather than five flags.
    """
    for t in toks:
        if t.startswith("--"):
            # getopt_long accepts any unambiguous ABBREVIATION, so `--shel` selects
            # `--shell`. Every prefix is matched rather than the full spelling; an
            # abbreviation too short to be unambiguous is rejected by sudo itself, so
            # matching it costs a block on an invocation that would not have run.
            if len(t) > 2 and any(n.startswith(t) for n in _SHELL_MODE_LONG):
                return True
            continue
        if len(t) < 2 or not t.startswith("-"):
            continue
        # A BUNDLE is read left to right and stops at the first flag that takes a VALUE,
        # because the rest of the token is that value. `-su root` is `-s -u root` and
        # counts; `-ualice` is `-u` with its value attached and does not.
        for _n, c in enumerate(t[1:]):
            if c in "si":
                return True
            if c not in _SHELL_MODE_NOARG:
                break
    return False


def _shell_mode_launch(words):
    """A sudo/doas shell mode anywhere in this stage, wrapper-led or nested."""
    return (any(_basename(w) in _SHELL_MODE_WRAPPERS for w in words)
            and _has_shell_mode_flag(words))


def _launcher_in_any_simple_command(text):
    """Does any simple command in this text LEAD with a launcher?

    The split is over the raw text and is quote-aware, so an operand that merely spells a
    separator is not one. Unsplittable or unlexable text fails CLOSED, the same call the
    substitution bodies make.

    Each command is judged against its OWN words, LEXED. Sharing one flattened word list
    across the whole text let a wrapper in one command pair with a launcher-shaped data
    operand in another (`env true ; grep unshare notes`), and lexing matters because a raw
    split leaves the quote characters attached to a quoted name, which no set holds.
    """
    segs, ok = _split_simple_commands(text)
    if not ok:
        return True
    for s in segs:
        t = _lex(s)
        if t is None:
            return True
        if _leads_with_launcher(t, list(_stage_words(t))):
            return True
    return False


def _leads_with_launcher(toks, words):
    """Is a no-command shell LAUNCHER the thing this stage actually runs?

    Command position only, so `grep script` is untouched. Prefixes are stepped over; the
    first real command word decides. When that word is a WRAPPER it can hide the launcher
    among its operands (`env -i script -q /dev/null`), which is the one case that has to
    look at the whole stage -- the same shape `_starts_with_wrapper` is used for elsewhere.

    An OPTION reached in command position is where the arity question the module refuses
    to answer would come back: an unknown option may or may not swallow the word after it,
    so `/usr/bin/time -o timing.out unshare` has NO locatable command word without a table
    saying `-o` takes a value. Skipping the option and reading `timing.out` as the command
    is a fail-OPEN. So an option in command position marks the stage UNRESOLVED and the
    whole stage is asked instead -- the same arity-free move already made for wrappers,
    with the same known cost: `| time -p grep -c su` over-blocks on the English word.
    `-p` itself is exempt because it is already modelled as `time`'s grouping connector.
    """
    i, n = 0, len(toks)
    at_start = True                       # in COMMAND POSITION of some simple command
    unresolved = False
    first_cmd = None                      # index of the first real command word seen
    while i < n:
        t = toks[i]
        b = _basename(t)
        if not at_start:                  # operands of a command already found not to be
            i += 1                        # a launcher -- `grep script` is not `script`
            continue
        if t in _GROUP_HEADERS:
            # A HEADER, not a command: `for script in a`, `select unshare in a`,
            # `case script in`. The word after it is a variable or a subject, and reading
            # it as a command word blocked ordinary loops over launcher-shaped names. The
            # body is its own segment (`do grep x`), so nothing is lost by stopping here.
            return False
        if t in _COMPOUND_WORDS or b in _CMD_PREFIX_WORDS:
            i += 1
            continue
        if _ASSIGN_RE.match(t):
            i += 1                        # assignment prefix: `FOO=1 unshare`
            continue
        j = i + 1 if (t.isdigit() and i + 1 < n and _REDIR_RE.match(toks[i + 1])) else i
        m = _REDIR_RE.match(toks[j])
        if m:                             # `2` `>` `/dev/null`, or a bare `>` `file`
            i = j + 1 + (m.end() == len(toks[j]))
            continue
        if t.startswith("-") and t != "-":
            unresolved = True             # unknown arity: `/usr/bin/time -o FILE unshare`
            i += 1
            continue
        if b in _LAUNCHER_SHELLS:
            return True
        if b in _SHELL_MODE_WRAPPERS and _has_shell_mode_flag(toks[i + 1:]):
            return True
        # An UNRESOLVED command word cannot be ruled out. It matters HERE and not only at
        # the stage level because a prefix hides it from the peeled command word:
        # `busybox "$APPLET"` peels to `busybox`, which is resolved and harmless, while
        # the applet BusyBox actually dispatches is the word this walk is standing on.
        if any(ch in t for ch in _UNRESOLVED_CW_CHARS):
            return True
        if first_cmd is None:
            first_cmd = i
        at_start = False
        i += 1
    if unresolved:
        # An UNRESOLVED word among the candidates cannot be ruled out either -- the
        # command word is already unlocatable here, so `time -o /dev/null "$APPLET"`
        # offers no literal name to test and the expansion is the thing that runs.
        return (any(_basename(w) in _LAUNCHER_SHELLS for w in words)
                or any(ch in w for w in words for ch in _UNRESOLVED_CW_CHARS)
                or _shell_mode_launch(words))
    # The wrapper fallback is asked of the tokens FROM the command word, not from the
    # front: `time env -i script` puts a prefix ahead of the wrapper, and a
    # _starts_with_wrapper that does not model `time` reads `time` and answers no.
    rest = toks if first_cmd is None else toks[first_cmd:]
    return bool(_starts_with_wrapper(rest)) and (
        any(_basename(w) in _LAUNCHER_SHELLS for w in words)
        # ...and a NESTED shell mode: `env -i sudo -s` leads with a wrapper, so the real
        # program is among its operands and the flag is there too.
        or _shell_mode_launch(words))

# Characters that mean a command word is not what it LOOKS like. `$` is expansion
# (`| $SHELL`), the BACKTICK is the older substitution spelling (`| `printf bash``, which
# really does run bash), and the glob characters matter for the same reason they do in the
# helper guard: the shell expands `/bin/[b]ash` onto bash, so a literal-name test reads a
# command word that no set contains and calls it a non-shell.
# An EXTGLOB group, resolved to the text it wraps. shlex splits `/bin/ba+(s)h` into five
# tokens, so the command word reads as `ba+` and no shell name survives -- but bash
# expands it to `/bin/bash` and runs it. Substituting the group away puts the resolved
# spelling in front of the SAME name test, rather than adding a second rule.
#
# `!( )` is NOT in this set, and cannot be: it matches everything EXCEPT its contents,
# so `ba!(x)h` expands to `bash` among others and resolving it to the inner text gives
# `baxh` -- the one spelling that would read as harmless. A negation is unresolvable,
# and unresolvable is the fail-CLOSED case, handled separately below.
_EXTGLOB_RE = re.compile(r"[+@*?]\(([^()]*)\)")
# UNRESOLVABLE extglob: a negation, or an ALTERNATION. `!(x)` matches everything except
# its contents, and `@(s|z)` names two things at once -- resolving either to its inner
# text picks one spelling, and for `ba@(s|z)h` that is `bas|zh`, the harmless-looking
# one. Naming more than one thing is exactly the unresolved case, which fails CLOSED.
# The BODY of a command substitution, either spelling. A substitution is executed by
# definition, so an unresolved command word inside one is an unresolved command word --
# `| echo "$($SHELL)"` runs whatever $SHELL names, on the pipeline stdin, while the stage
# command word is `echo`. The shell-NAME test already saw literal names here; this is the
# same question asked of the spellings that resolve at run time. Costs 52 over-blocks,
# including the nested-substitution fail-closed below.
_SUBST_BODY_RE = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
_EXTGLOB_NEG_RE = re.compile(r"!\([^()]*\)|[+@*?!]\([^()]*\|[^()]*\)")

_UNRESOLVED_CW_CHARS = "$*?[{(" + chr(96)  # `(` is extglob: `ba+(s)h` expands to `bash`

# Compound-command keyword sets -- see the definitions above _FUNC_NAME.


def _group_delta(words):
    """How much this segment opens or closes, counting only the LEADING run.

    A compound keyword is one only in command position, and segments are already split on
    separators, so the openers/closers of a segment are exactly its leading words -- `{ if
    true` opens twice, `fi` closes once. Counting the keyword ANYWHERE instead was measured
    at 1,161 over-blocks against the 1,105 this shape costs at its own round, because `if`, `for` and `done` are
    ordinary words in ordinary commands (`grep -n done log`) and a stray one opened a depth
    nothing closed. Both figures are against the same corpus, but they are a HISTORICAL
    PAIR -- taken at the round the alternative was measured, not against the final code.
    1,561 was the total at the last round that could be measured; the launcher names added
    afterwards (see `_LAUNCHER_SHELLS`) are explicitly UNMEASURED, so no figure in this file
    describes the shipped classifier exactly. ADR 0032's trajectory table says which round
    produced which number and supersedes anything quoted here.

    CONNECTORS are stepped over rather than ended on. `then`, `do`, `else` and `elif` sit in
    command position without being commands, so stopping at them made the walk asymmetric:
    the inner `if` of `if true; then if true; then ...; fi; fi` went uncounted while its `fi`
    still closed, driving the depth to zero a whole compound early.
    """
    delta = 0
    for w in words:
        if w in _GROUP_CONNECT:
            continue                      # in command position, but not a command
        if w in _GROUP_OPEN:
            delta += 1
        elif w in _GROUP_CLOSE:
            delta -= 1
        else:
            break                         # past the preamble; the rest is this command's data
    return delta


def _carries_no_command(segtext):
    """True for a stage that holds no command at all: empty, or only a comment.

    `_normalize` turns a NEWLINE into `;`, so `printf 'rm -rf src' |` + newline + `bash` --
    one ordinary pipeline, and one bash accepts -- arrives here as a `|` feeding an empty
    stage, then a `;` before the shell. Reading that `;` as the end of the pipeline dropped
    the fed state one stage before the receiver. A comment after the pipe does the same.
    """
    stripped = segtext.strip()
    return stripped == "" or stripped.startswith("#")


def _find_exec_positions(toks):
    """Indices of every -exec/-execdir/-ok/-okdir TOKEN in `toks`. Returned as a set so
    callers get O(1) membership, not another O(n) scan per lookup -- see the O(N^2) note
    where this is walked below.

    DELIBERATELY token presence, not find-expression parsing. `find . -name -exec` does
    pass the literal word `-exec` as -name's filename PATTERN, so counting it as a
    predicate over-blocks -- cubic raised exactly that on #562. Two successive attempts
    to be precise about it BOTH turned the over-block into a fail-OPEN, each found by a
    later reviewer:

      1. "not preceded by a string primary" -- `find . -name -name -exec unshare ';'`,
         where the first -name eats the second and the -exec IS real.
      2. left-to-right consuming each KNOWN string primary's operand -- `find . -printf
         -name -exec unshare ';'`, where the unlisted -printf eats -name, so the walk
         reaches -name as a primary and lets it eat the real -exec.

    (2) is the general shape: any operand-taking primary missing from the table puts a
    listed primary NAME into data position, and the residual flips from over-block to
    bypass. Getting it right needs find's whole primary/arity table across GNU and BSD,
    re-verified as find grows -- an unbounded enumeration guarding a security boundary,
    where every gap is a hole rather than a nuisance.

    And it buys almost nothing, because the caller does not stop here. Below the depth
    cap the payload after each position is EXTRACTED and judged on its own contents, so
    a trailing `-exec` (a pattern, with nothing after it) is allowed for having no
    payload -- no grammar needed. Only AT the cap, where no payload is examined at all,
    does presence decide, and there over-blocking is the whole point. KEEP IT.
    """
    return frozenset(i for i, t in enumerate(toks)
                     if t in ("-exec", "-execdir", "-ok", "-okdir"))


def _may_read_program_from_stdin(segtext, _depth=0):
    """Could this pipeline stage be a shell, running whatever the producer wrote?

    Deliberately WIDE, and free of any option-arity table. Deciding this from the flags
    -- is there a `-c`? does `-s` mean stdin? -- is the arity question this module refuses
    to answer, and it failed OPEN four different ways when tried (`bash --norc` read as
    "-c is present", `bash --rcfile -c` read the option's VALUE as the option). It is not
    needed: the pipeline STRUCTURE already says the stage is being fed, so the only
    remaining question is whether the thing being fed might be a shell.

    So: a shell name anywhere in the stage counts, tokens are re-split on whitespace first
    (`env -S 'bash -s'` arrives as ONE token), and a command word carrying an expansion or a
    glob (`| $SHELL`, `| /bin/[b]ash`) counts too. This only decides whether to ALSO scan the
    producer, so a false positive costs precision on one command while a false negative is a
    fail-OPEN.
    """
    toks = _lex(segtext)
    if toks is None:
        return True                       # unparseable stage: assume the worst
    words = list(_stage_words(toks))
    if any(_is_stdin_shell(_basename(w)) for w in words):
        return True
    # An option BUNDLE with its value attached. `env -iS'bash -s'` lexes to `-iSbash -s`,
    # whose first word is `-iSbash`: peeling ONE option letter leaves `Sbash`, and peeling a
    # fixed number never terminates, because the bundle length is the caller's to choose.
    # Asking whether a dash-word ENDS WITH a shell name is O(names) instead of O(length^2),
    # which matters in a file that has already been bitten twice by quadratic scans.
    # The version-qualified spelling has to be asked here too, not only on the ordinary-word
    # path above: `env -iSpython3.12` bundles the interpreter into a dash-word, and an
    # exact-suffix test alone answers False for it while `env -iSpython3` answers True.
    if any(w.startswith("-")
           and (any(w.endswith(n) for n in _STDIN_SHELLS) or _ATTACHED_INTERP_RE.search(w))
           for w in words):
        return True
    # ...and the same bundle taken APART, for the spelling neither path above reaches.
    # `_stage_words` pre-splits a leading `-S<program>` into its own word, so a bare
    # `-Slldb-19` is already answered -- but not `-iSlldb-19`, where the S sits inside the
    # bundle; and the suffix search is deliberately dash-free, because an option's own data
    # ends with `-lldb-19` too (see `_ATTACHED_INTERP_RE`). So pull the split-string operand
    # out by parsing env's options and ask it the ordinary whole-name question.
    # KEEP IN STEP WITH marker_check.
    # The operand is LEXED, not `str.split()`: `env -S` evaluates quoting, so `-iS\'lldb"-19"\'`
    # runs `lldb-19` while a raw split yields the literal `lldb"-19"` and matches nothing.
    # Unlexable fails CLOSED, as everywhere else here.
    # PRESENCE of the name and of the option, each asked of the whole stage -- deliberately
    # NOT "is env the command word, and is this option its own". That narrowing was tried
    # and withdrawn: locating env's own option run means knowing which env options take a
    # SEPARATE operand (`-u FOO`, `-C DIR`, `--argv0 X`), which wrapper preamble precedes it
    # (`sudo -u root env -S ...` stops at `root`), and how leading redirections shift it --
    # and each gap in that knowledge is a fail-OPEN, three of which review found in one
    # pass. What it bought was the contrived over-block below. Cross-product, and accept it.
    if any(_basename(w) in _ENV_NAMES for w in words) \
       and any(_env_names_split_string(w) for w in words):
        return True
    # A stage can RUN a shell without naming one in command position: `eval "$A"` resolves to
    # bash at run time, and its command word is `eval`. So the operands this stage EXECUTES
    # are asked the same two questions the stage itself was.
    for prog in _executed_operands(toks):
        if any(ch in prog for ch in _UNRESOLVED_CW_CHARS):
            return True
        # LEXED, not split: `env -S "env -i 'bash'"` splits into the word `'bash'`, whose
        # quotes are part of the string, so the name test missed it. The lexer resolves
        # the quoting the shell would; a lex failure falls back to the raw split, which is
        # the wider of the two.
        _pt = _lex(prog)
        _pw = prog.split() if _pt is None else list(_stage_words(_pt))
        if any(_is_stdin_shell(_basename(w)) for w in _pw):
            return True
        # ...and the command-position-only class, which the any-word test above cannot see.
        # An executed operand IS a program, so every simple command in it gets the same walk
        # the stage gets: `env -S 'sudo -u root perl5.36-x86_64-linux-gnu'` runs the
        # interpreter on this pipe, and so does a `-c 'true; <name>'` two commands along.
        if _cmdpos_receiver_in_any_simple_command(prog):
            return True
        # ...and the LAUNCHER question, which the first cut asked only of the stage.
        # `find . -maxdepth 0 -exec unshare \;` does not read stdin itself, so the pipe
        # is still unread when `unshare` execs a shell and that shell runs the payload.
        if _launcher_in_any_simple_command(prog):
            return True
    # No `time` peel here, unlike marker_check: `time` is already in `_RESERVED`, which
    # `_effective_command_word` skips, so `time source /dev/stdin` resolves to `source`
    # on its own. The twin needs an explicit peel only because ITS walk must keep seeing
    # `time` as a write-capable verb for the audit-log check -- see the note there.
    cw = _effective_command_word(toks)
    # `.` and `source` are the two POSIX/bash spellings of the same builtin, and
    # `. /dev/stdin` / `source /dev/stdin` both run the piped text. Both are tested in
    # COMMAND POSITION only, unlike every other name in `_STDIN_SHELLS`: a bare `.` is an
    # ordinary argument (`find . -name x`) and a bare `source` is an ordinary word
    # (`grep source` names it as a PATTERN, not a command) -- putting either in the
    # any-word name set cost 100 over-blocks for `.` and a further over-block for `source`
    # (`printf 'rm -rf src' | grep source`, raised by Codex on #562), for a shape that is
    # always a command word when it means anything.
    if cw and _basename(cw) in (".", "source"):
        return True
    # ...and the same command-position-only rule for the interpreter spellings that wear a
    # data shape (`perl5.36-x86_64-linux-gnu`, `lldb-19`). Asked of the WALK rather than of
    # `cw`, because `cw` lands on a wrapper option's operand -- see `_runs_cmdpos_receiver`.
    if _runs_cmdpos_receiver(toks):
        return True
    # Same command-position-only rule, same reason: a LAUNCHER with no program operand execs
    # a shell that then reads this pipe. `grep script` is unaffected because `script` is not
    # in command position there.
    #
    # It canNOT be asked of the PEELED command word, which is the trap the first cut fell
    # into: `script`, `su`, `runuser` and `chroot` are themselves in `_WRAPPERS`, so peeling
    # steps straight past them and `| su` read as harmless. So ask the LEADING token, plus
    # the whole wrapper run when one leads -- the same shape `_starts_with_wrapper` already
    # uses for unresolved words, and for the same reason: a wrapper hides the real program
    # among its operands. `env -i script -q /dev/null` is why the second half is needed.
    #
    # Testing `toks[0]` alone was the first cut and it was wrong twice over: an ASSIGNMENT
    # prefix (`FOO=1 unshare`) and a `time`/`exec`/`nohup` prefix both push the launcher off
    # the front, and `unshare`/`nsenter` are not in `_WRAPPERS`, so neither branch fired.
    # Walk the command-PREFIX run instead -- assignments and those keywords are prefixes,
    # not commands -- and stop at the first real command word.
    if _launcher_in_any_simple_command(segtext):
        return True
    # find hands `-exec` a command of its OWN to run, and find does not read stdin itself,
    # so the pipe is still unread when that command execs a shell. The payload gets the
    # same receiver questions the stage got -- the any-word shell test already saw
    # `-exec bash ;`, but a LAUNCHER is command-position-only and was invisible there.
    # Gated on `find` being named, exactly as the write-verb walk gates its own -exec
    # extraction, so no other command pays for the scan.
    # Anchored on find being the COMMAND, not merely a word in the stage: `grep -e find
    # -e -exec -e unshare` names all three as PATTERNS and executes none of them. Same
    # anchor the write-verb -exec extraction uses, for the same reason.
    _fcw = _basename(cw) if cw else ""
    _is_find_exec = (_fcw == "find"
                     or (_starts_with_wrapper(toks)
                         and any(_basename(w) == "find" for w in words))
                     # ...and through a MULTI-CALL dispatcher, whose find applet is the
                     # same find: `busybox find . -exec unshare ;`.
                     or (_fcw in ("busybox", "toybox")
                         and any(_basename(w) == "find" for w in words)))
    # `_is_find_exec` says only that the command IS find, not that it carries an execution
    # predicate. Returning True at the cap on that alone turned a benign four-deep
    # `find . -name x` -- which has no payload to examine -- into a block. Require an
    # actual exec predicate, so the fail-closed answer covers only genuinely unexamined
    # payloads.
    #
    # `_find_exec_positions` answers that by TOKEN PRESENCE, not by parsing find's
    # expression grammar -- see its docstring for why the two attempts to be precise
    # about `find . -name -exec` (where `-exec` is a filename pattern, not a predicate)
    # both became fail-OPENs. The residual is an over-block on a file literally named
    # `-exec`, which is the direction this module chooses everywhere else.
    _find_exec_pos = _find_exec_positions(toks) if _is_find_exec else frozenset()
    if _is_find_exec and _depth >= 4 and _find_exec_pos:
        # DEPTH-CAPPED, and not silently skipped. The condition below used to gate on
        # `_depth < 4` alone, so reaching the cap fell through this branch entirely --
        # unlike the substitution recursion further down, which already fails CLOSED
        # at its own cap. A `find -exec` payload nested this deep is UNEXAMINED, not
        # checked-and-clean, so it gets the same fail-closed answer.
        return True
    if _is_find_exec and _depth < 4:
        # INDEX-controlled, so a payload is never rescanned as predicates. Restarting the
        # search from the token after each `-exec` re-read every operand of the payload
        # just collected, so N `-exec`-looking OPERANDS cost O(N^2): a 1,400-operand
        # command measured 6.04s, past the 5s hook timeout -- and a timed-out hook writes
        # no decision, which the harness reads as ALLOW. Advance past the terminator.
        # `_find_exec_pos` membership is a SET lookup, so this stays O(1) per token and
        # does not reopen that cost.
        _fi, _fn = 0, len(toks)
        while _fi < _fn:
            if _fi in _find_exec_pos:
                _payload, _fj = [], _fi + 1
                while _fj < _fn:
                    _ft2 = toks[_fj]
                    if _ft2 == ";" or (_ft2 == "+" and _payload
                                       and _payload[-1] == "{}"):
                        break
                    _payload.append(_ft2)
                    _fj += 1
                # REQUOTED, not space-joined: find execs the payload directly, so its
                # argv boundaries are real and punctuation inside an operand is literal.
                # A bare join turned `-exec grep "foo; unshare" ;` into two commands and
                # blocked on grep data.
                if _payload and _may_read_program_from_stdin(
                        " ".join(shlex.quote(_p) for _p in _payload), _depth + 1):
                    return True
                _fi = _fj + 1
                continue
            _fi += 1
    if cw and any(ch in cw for ch in _UNRESOLVED_CW_CHARS):
        return True
    # A WRAPPER hides the real program among its operands, and peeling it can land on the
    # wrong word: `env -u X /bin/[b]ash` peels to `X` -- the operand of `-u` -- so the
    # globbed receiver behind it was never tested. Asking the whole stage instead is the
    # arity-free answer, and it is scoped to wrapper-led stages because asking it of EVERY
    # stage costs 8.63% (worse than the option the issue rejected) while this costs ZERO:
    # 1,440 either way, measured. A glob in an ordinary argument (`grep foo *.py`) is
    # untouched; a glob in a wrapper's operands is exactly the thing that runs.
    if _starts_with_wrapper(toks) and any(
            any(ch in w for ch in _UNRESOLVED_CW_CHARS) for w in words):
        return True
    # Last: the extglob spelling, resolved. Guarded by the substitution actually changing
    # something, so this cannot recurse -- `_EXTGLOB_RE` only ever shortens the text.
    _flat_dollar = 0
    for _m in _SUBST_BODY_RE.finditer(segtext):
        # Only the `$(` spelling is counted, because only `$(` openers are counted below.
        # A shared counter let an unrelated backtick substitution pay for a `$(` opener --
        # one backtick match plus one `$(` opener reached one-for-one and read as fully
        # resolved, while the nested `$( ( . /dev/stdin ) )` the flat pattern could not
        # cross ran the piped payload.
        _flat_dollar += _m.group(1) is not None
        _body = _m.group(1) or _m.group(2) or ""
        # The body is a COMPOUND command, so it gets the same treatment the outer command
        # got: SPLIT, then every segment asked. Asking the body as one stage reads only its
        # first command word, and `$(true; . /dev/stdin)` hides the `.` behind a harmless
        # `true` -- verified running the piped payload in real bash. The unresolved-character
        # test alone is likewise too weak, because `. /dev/stdin` is a literal name this
        # function knows and the outer stage (`echo`) does not. Recursion terminates because
        # a segment is no longer than the body and the body is strictly shorter than the text
        # it came from (the parens are gone); the depth cap is belt-and-braces, and reaching
        # it means a nest this cannot read, which is the fail-CLOSED case.
        if _depth >= 4:
            return True
        _segs, _split_ok = _split_simple_commands(_body)
        if not _split_ok:
            return True                   # unsplittable body: assume the worst
        if any(_may_read_program_from_stdin(_s, _depth + 1) for _s in _segs):
            return True
        if any(ch in _body for ch in _UNRESOLVED_CW_CHARS):
            return True
    # NESTED, and not guessed at: `$( ($SHELL) )` has inner parens the flat pattern cannot
    # cross, so counting openers against matches is how this notices it cannot read the
    # text. Same exit as nested extglob -- unresolved fails CLOSED. The regex is also blind
    # to QUOTING, so an inert `echo '$($SHELL)'` reads as a receiver; that is an over-block
    # in the safe direction, and making it quote-aware means a second parser here.
    if segtext.count("$(") > _flat_dollar:
        return True
    # UNBALANCED, and not guessed at either. The flat pattern assumes the first `)` closes
    # the substitution, and a `case` PATTERN breaks that assumption without nesting anything:
    # `$(case x in x) $SHELL;; esac)` extracts the body `case x in x` and never sees the
    # `$SHELL` receiver behind it -- verified running the piped payload in real bash. Which
    # `)` bash treats as a close is context-sensitive (a depth counter reads the case pattern
    # as the close too, and lands on the same wrong body), so this is the third construct the
    # module refuses to resolve rather than model: when the parens in a substitution-bearing
    # stage do not balance, the extraction above cannot be trusted and unresolved fails
    # CLOSED. Scoped to stages that actually HOLD a substitution, because an ordinary `case`
    # is not relying on the extraction and pays nothing.
    # Scoped to `$(` alone, NOT backticks: a paren cannot terminate a backtick substitution,
    # so an imbalance says nothing about how a backtick body was extracted, and including
    # them only over-blocked (``| echo "`date` ("`` was read as a receiver for no reason).
    # KNOWN BYPASS, left open deliberately: the count is QUOTE-BLIND, so an inert `(` inside
    # the body re-balances it -- `$(case x in x) echo "("; . /dev/stdin;; esac)` counts equal
    # and is NOT caught. A `case`/`esac` NAME tripwire was tried and reverted: segments are
    # split on `;` before this runs, so `esac` lands in a different segment than the `$(` and
    # the tripwire never fires on the very shape it was written for. Making the count
    # quote-aware means a second parser here. This rule is kept because it costs zero measured
    # over-blocks and does catch the unquoted spelling; the quoted one is recorded with the
    # rest of the residual family in ADR 0032 rather than chased with a fourth refinement.
    if "$(" in segtext and segtext.count("(") != segtext.count(")"):
        return True
    if _EXTGLOB_NEG_RE.search(segtext):
        return True                       # a negated pattern names anything: fail closed
    deglob = _EXTGLOB_RE.sub(r"\1", segtext)
    if _EXTGLOB_RE.search(deglob) or _EXTGLOB_NEG_RE.search(deglob):
        # NESTED, and one substitution pass does not reach it: `ba@(+(s))h` still holds a
        # group after the inner one is resolved. Iterating to a fixed point is just a slower
        # guess at a grammar, so this takes the same exit the negation and the alternation
        # take -- unresolved, and unresolved fails CLOSED.
        return True
    if deglob != segtext:
        toks = _lex(deglob)
        if toks is None:
            return True
        # BOTH name questions, not just the any-word one: `perl5.36-x86_64-linux-@(gnu)`
        # resolves to a command-position receiver, and the unresolved-character test above
        # never fired because shlex left `@` on the command word and `@` is not one.
        return (any(_is_stdin_shell(_basename(w)) for w in _stage_words(toks))
                or _runs_cmdpos_receiver(toks))
    return False


def _stage_words(toks):
    """Every word this stage could resolve to a command NAME.

    Whitespace-splitting each token is not enough, because an option can carry its value
    ATTACHED: BSD/macOS `env -S'bash -s'` lexes to the single token `-Sbash -s`, whose first
    word is `-Sbash` and matches no shell. That is the third attached-operand miss in this
    family, so the peel is general rather than env-specific -- drop the leading dashes and
    one option letter, and take everything past a long option's `=`. Over-generating here
    is free: these words only decide whether to ALSO scan the producer.
    """
    for t in toks:
        forms = [t]
        # A COMMAND SUBSTITUTION inside an argument inherits the pipeline stdin, so
        # `printf <payload> | echo "$(bash)"` runs the payload while the stage command word
        # is `echo`. Splitting the substitution punctuation into whitespace hands the body
        # to the SAME shell-name test the stage itself gets, rather than adding a second
        # rule -- so a substitution counts only when it actually names a shell.
        if "$(" in t or chr(96) in t or "(" in t:
            forms.append(t.replace("$(", " ").replace(chr(96), " ")
                          .replace("(", " ").replace(")", " "))
        if t.startswith("-"):
            forms.append(t.lstrip("-")[1:])       # value glued behind a short option
            forms.append(t.partition("=")[2])     # ...or behind a long one
        for f in forms:
            for w in f.split():
                yield w


def _piped_shell_producers(pairs):
    """Text feeding each pipeline stage that might be a shell.

    A shell given neither `-c` nor a script operand runs whatever stdin produced, so
    `printf 'rm -f src/impl.py' | bash` performs the write even though NO segment holds a
    verb in command position: the payload is quoted DATA to printf, and the bash stage has
    no operand at all. The `<<<` transport was closed by an operand branch a pipe never
    reaches, and the pre-#519 raw regex caught this one -- so leaving it is a REGRESSION of
    this module, not a gap inherited from it.

    What the producer WRITES is not recoverable by parsing (`printf '%s%s' r 'm -rf src'`
    assembles the verb from two individually inert operands), so the answer is not a better
    parse but the older, wider one: hand the producer text to the raw regexes. Scoping the
    scan to the PRODUCER rather than to the whole command is what keeps it cheap --
    measured over 34,758 real commands, scanning the whole command on any shell name
    over-blocked 2,693 of them (7.7%, mostly `bash tests/foo.sh` beside an unrelated `git`)
    while the producer scan over-blocks 1,561 (4.49%). Both figures are against the SAME
    corpus and the SAME code -- the LAST MEASURABLE commit, not the shipped one (see the
    launcher note above and ADR 0032); ADR 0032 carries the full table and the per-rule
    isolation, and any number quoted here must match it.

    RESIDUAL, inherited rather than introduced: the raw scan misses a verb the producer
    assembles from separate operands, and it always did. `bash < payload.sh` carries no
    producer text at all, and the pre-#519 regex could not see that file either.

    GROUPING IS TRANSPARENT, and getting that wrong was a live fail-open in two successive
    cuts of this function. The splitter breaks on `(`, `)` and on every `;`, so the payload
    -- or the shell -- can sit behind what merely LOOKS like a pipeline boundary:
    `(printf 'rm -rf src') | bash`, `{ printf 'rm -rf src'; } | bash`,
    `printf 'rm -rf src' | (bash)`, `printf 'rm -rf src' | { :; bash; }` and its
    parenthesised twin were each measured executing the write while classifying as a read.

    So a GROUP DEPTH is tracked, and inside a group a separator separates nothing that
    matters here: only a `;`/`&`/`&&`/`||` at depth 0 starts a new pipeline. Counting `{`
    and `}` as whole WORDS is what keeps `"${VAR}"` from being read as a group. This
    subsumes the narrower "a segment that is only `}`" rule that closed the producer half
    but left the receiver half open.

    Widening the producer to the whole command prefix would close the same family without
    any of this, and was measured mid-development at 559 over-blocks (1.61%) against 43 for
    the pipeline scope at that same commit, because a multi-line command drags every earlier
    line into the scan. The scope decision is what that comparison settled; the LAST MEASURED
    total for the pipeline scope is 1,561, the rest being the grouping, indirection and newline rules
    afterwards (isolated in ADR 0032).

    ONE producer per pipeline, from its LAST candidate stage. Every earlier candidate's
    producer is a prefix of that one, so the regexes see the same text either way -- and
    building them all is O(stages^2) BYTES, which is how the `watch` scan above reached
    218 MB inside a hook whose timeout reads as allow. Pipelines partition the command, so
    the emitted slices are disjoint and this stays linear.
    

    RESIDUAL, deliberate, and an OVER-block: inside a `case` a `|` separates PATTERN
    ALTERNATIVES rather than pipeline stages, so `case foo in 'rm -rf src'|bash) :;; esac`
    reads as a pipe feeding `bash` and the quoted pattern is raw-scanned. Closing it needs
    case-pattern state -- where the `in` ended, where the `)` closes -- and getting THAT
    wrong in the other direction turns a real pipe into an inert pattern, which is a
    fail-OPEN. An over-block is the safe error and this one is narrow: it needs a pattern
    that BOTH contains a write verb AND names a shell in an alternative, so ordinary
    `case x in a|b)` and `case $x in *.py|*.sh)` are untouched -- both verified. Pinned in
    the suite so the trade stays visible rather than being rediscovered as a bug.
    """
    # TWO depths, each clamped at zero, never one sum. A `case` pattern terminator is a bare
    # `)` with no opener -- `case x in x) printf 'rm -rf src';; esac | bash` -- so a single
    # counter let that `)` cancel the `case` keyword's depth, and the `;;` behind it then
    # discarded the producer. Kept apart, an unmatched `)` clamps its own counter at zero and
    # cannot reach into the keyword one.
    out, start, last, fed, bare = [], 0, None, False, False
    pdepth = kdepth = 0
    for i, (op, seg) in enumerate(pairs):
        pdepth = max(0, pdepth + op.count("(") - op.count(")"))
        depth = pdepth + kdepth
        # A PIPE FEEDS AT ANY DEPTH, and this test has to come first. Folding it into the
        # in-a-group branch meant a pipeline written entirely inside a group --
        # `(printf 'rm -rf src' | bash)`, `{ printf 'rm -rf src' | bash; }` -- had its pipe
        # ignored, so the shell was never seen as fed. Depth suppresses only the SEPARATOR,
        # which is the single thing it is there for.
        if _is_pipe(op):
            fed = True
        elif (op and all(ch in "()" for ch in op)) or depth > 0:
            pass                          # grouping: does not terminate the pipeline
        elif fed and bare:
            pass                          # a normalized newline/comment between | and the shell
        else:                             # `;`, `&`, `&&`, `||` start a new pipeline
            if last is not None:
                out.append(" ; ".join(p[1] for p in pairs[start:last]))
            start, last, fed = i, None, False
        if fed:
            # CHARGE FIRST. _may_read_program_from_stdin walks the operands this stage
            # EXECUTES, which is the same potentially quadratic walk the budget charged at
            # the end of is_file_mod exists to bound -- and this loop reached it once per
            # stage without paying. A 60,004-character command took about 3.8s, and the
            # hook it backs has a 5s timeout after which NO decision is written, which the
            # harness reads as ALLOW. Overrunning leaves the budget negative, so the charge
            # downstream fails CLOSED. The gate copy already charged here.
            _scan_budget[0] -= len(seg.split())
            if _scan_budget[0] < 0:
                break
            if _may_read_program_from_stdin(seg):
                last = i
        bare = _carries_no_command(seg)
        # Counted loosely, and safe BECAUSE of the ordering above. A literal `{` argument
        # (`echo { ; printf ... | bash`) leaves a depth this reader never closes, but with
        # the pipe branch first the only consequence is that a separator stops resetting --
        # which WIDENS the producer. Depth can never hide a pipe, so an over-count costs
        # precision and never opens a hole; the clamp keeps a stray `}` from going negative.
        words = seg.split()
        kdepth = max(0, kdepth + _group_delta(words))
    if last is not None:
        out.append(" ; ".join(p[1] for p in pairs[start:last]))
    return out


def _defuse_comments(s):
    """Blank the SEPARATOR characters inside shell comments, quote-aware, leaving all other
    text -- and the newlines that end the comments -- exactly where they were.

    A comment runs from an unquoted `#` in word position to the end of its LINE, and it can
    contain anything, including `;`. _normalize rewrites newlines to `;` a moment later, so
    a comment reaching the splitter intact arrives as ordinary segments: `printf <payload> |
    # ; ignored` + newline + `bash` split into a comment segment AND a bare `ignored`, which
    read as a real command and ended the pipeline one stage before its shell.

    DEFUSING rather than DELETING is the whole point, and deleting was tried first: it moved
    14 real commands from block to ALLOW, because a comment holding an apostrophe (`# the
    caller's copy`) had been making the whole command unparseable, and unparseable is the
    fail-CLOSED path. Removing the comment removed the apostrophe, the command parsed, and
    the gate honestly allowed it. A change to a fail-closed classifier may only ever ADD
    blocks; blanking in place keeps every byte of length and every scannable word where the
    raw regexes already saw them.

    QUOTES inside the comment are blanked too, and that is the one thing keeping them would
    cost: bash ignores quoting in a comment entirely, so a comment holding an apostrophe
    changes the quote state of everything AFTER it. Two of them balance -- `# '` + newline +
    `rm -rf src` + newline + `# '` -- and the write in between reads as quoted text; one of
    them unbalances, and `# the caller's copy` + newline + `cat > src/impl.py` measured
    ALLOW at the gate for exactly that reason. Both are fail-OPENS, and both close here.

    Word position matters -- bash treats `a#b` and `sed 's#a#b#'` as ordinary text, so a `#`
    only opens a comment after whitespace, a separator, or at the start of the command. It
    is tracked as explicit STATE rather than read back off the previous output character,
    because that character does not say whether it was escaped or quoted, and two spellings
    turn on exactly that: `)` can close a substitution INSIDE the current word, so
    `echo $(true)#x` is one word; and an ESCAPED space is an ordinary character, so
    `echo foo\\ #notcomment` is one word too. Both were read as comments, and both blanked
    the real separator that followed.
    """
    out, in_s, in_d, esc = [], False, False, False
    word = True                           # a `#` HERE would open a comment
    group = []                            # one bit per open paren: subshell or substitution
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if esc:
            out.append(ch)
            esc = False
            word = False
        elif in_s:
            out.append(ch)
            if ch == _SQ:
                in_s = False
            word = False
        elif in_d:
            out.append(ch)
            if ch == chr(92):
                esc = True
            elif ch == _DQ:
                in_d = False
            word = False
        elif ch == chr(92):
            out.append(ch)
            esc = True
            word = False
        elif ch == _SQ:
            out.append(ch)
            in_s = True
            word = False
        elif ch == _DQ:
            out.append(ch)
            in_d = True
            word = False
        elif ch == "#" and out and out[-1] == ")":
            # AMBIGUOUS, and deliberately not guessed at. Whether this `)` delimited a
            # command -- making the `#` a comment -- depends on what its `(` opened, and
            # bash has four answers: a SUBSHELL and a case PATTERN delimit, a SUBSTITUTION
            # and a FUNCTION HEADER do not. Three successive review rounds each closed one
            # spelling and opened another, which is the signature of a question that should
            # not be answered by refinement. So it is not answered: the text is left exactly
            # as it stands, and the command is flagged for the raw whole-command scan, which
            # is the fail-CLOSED reading. One command in a 34,758-command corpus contains
            # this shape at all, so the precision cost is nil.
            _paren_hash_ambiguous[0] = True
            out.append(ch)
            word = False
        elif ch == "#" and word:
            while i < n and s[i] != "\n":
                out.append(" " if s[i] in ";&|()" + _SQ + _DQ else s[i])
                i += 1
            continue                      # the newline itself stays: it is the separator
        elif ch == "(":
            out.append(ch)
            # WHICH kind of paren, because their closers differ. A bare `(` in word position
            # opens a SUBSHELL, and its `)` ends a command -- so `(true)# x` really is a
            # comment. A `$(` (or one inside a word) opens a SUBSTITUTION, and its `)` sits
            # mid-word -- so `echo $(true)#x` is not. One bit per paren is enough, and both
            # spellings were fail-opens in successive rounds: first `)` always delimited,
            # then `)` never did.
            group.append(word and not (len(out) > 1 and out[-2] == "$"))
            word = True
        elif ch == ")":
            out.append(ch)
            word = group.pop() if group else False
        else:
            out.append(ch)
            word = ch in " \t\n;&|"
        i += 1
    return "".join(out)


def _normalize(cmd):
    """Apply the same pre-tokenization normalization the anti-forge detector uses, so
    the two agree on what a 'token' is: line continuations rejoined, separators inside
    COMMENTS blanked while the newlines ending them still exist, newlines treated as
    command separators,
    ANSI-C/locale quote prefixes dropped so shlex sees the quote, and ${IFS}
    field-splitting obfuscation restored to real whitespace."""
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    norm = norm.replace(chr(92) + chr(10), "")
    norm = _defuse_comments(norm)  # BEFORE newlines become separators -- see the docstring
    norm = norm.replace("\n", " ; ")
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


def _process_substitutions(s):
    """(in_bodies, out_bodies, ok) for the `<(...)` and `>(...)` process substitutions in s.

    Split by DIRECTION, because the two run the transport opposite ways and the producer
    scan needs to know which end is which:

      `<(BODY)`  BODY's stdout becomes a file the OUTER command reads -- so BODY is the
                 producer and the outer command may be the receiver.
      `>(BODY)`  the OUTER command writes into BODY's stdin -- so the outer command is the
                 producer and BODY may be the receiver.

    Both were verified executing (#563): `bash < <(printf 'rm -rf src')` and
    `printf 'rm -rf src' > >(bash)` each performed the removal while `is_file_mod`
    answered False, because `_piped_shell_producers` recognises only `|` and `|&` as
    feeding a stage. `bash <(printf ...)` -- the substitution as a script OPERAND rather
    than through a redirect -- runs it too, so this does not ask for a redirect character.

    QUOTING IS NOT MODELLED, and that is deliberate. A process substitution does not happen
    inside quotes, so an earlier cut skipped quoted regions -- and one global double-quote
    state cannot do that, because quoting RESTARTS inside a `$(...)` body: two valid quoted
    substitutions on either side made the scanner skip the real substitution between them
    and still report success, a fail-OPEN verified executing. Tracking it properly needs a
    stack of quoting contexts, which is the parser this module twice refuses to build. So
    the detector OVER-detects: an inert `<(rm -rf q)` inside a string is reported too. That
    costs a whole-command raw scan on a command that ALSO names a shell somewhere, which is
    narrow, rare, and the direction this module chooses everywhere else.

    `ok` is always True. An unterminated `<(` used to return False and hand the caller the
    whole-command scan, and an unterminated one inside an inert quoted operand is ordinary
    text -- `grep -n 'rm -rf src <(' notes.txt` blocked on it. It is recorded as a BODILESS
    entry instead, and the walk STOPS there: that is enough to say a substitution is present,
    so the receiver tests still run, while re-scanning the suffix for every later opener was
    quadratic (12,000 of them measured 5.76s against a 5s hook timeout).
    """
    ins, outs, i, n = [], [], 0, len(s)
    while i < n:
        ch = s[i]
        if ch == chr(92):                 # a backslash escapes the next character
            i += 2
            continue
        # EVERY adjacent `<(`/`>(` counts -- no quote state, and no word-boundary test in
        # front of it. Both guards were written, both for precision, and both opened holes:
        # the word-boundary one skipped `> "">(bash)` and `> $E>(bash)`, which bash feeds by
        # concatenating an empty expansion; the quote one is described in the docstring.
        if ch in "<>" and i + 1 < n and s[i + 1] == "(":
            j = _subst_end(s, i + 1)       # quote-aware paren match, shared with `$(`
            if j < 0:
                # NO BODY, but still a substitution as far as this detector is concerned.
                # Returning `ok = False` here handed the caller the whole-command scan, and
                # an unmatched `<(` inside an inert quoted operand is ordinary text:
                # `grep -n 'rm -rf src <(' notes.txt` went from allow to block. Recording it
                # bodiless keeps the RECEIVER tests running -- so a real substitution whose
                # end this cannot find still blocks when a receiver is named -- while a grep
                # pattern that merely contains the characters does not.
                # ...and STOP. Continuing re-ran `_subst_end` over the remaining suffix for
                # every later opener, which is quadratic: 12,000 `<(` sequences inside one
                # quoted operand measured 5.76s against the hook's 5s timeout, and a
                # timed-out hook writes no decision the harness reads as ALLOW. Nothing is
                # lost by stopping -- the bodies only feed the candidate stage list, which
                # already carries the whole command and its own segments, and one bodiless
                # entry is enough to say a substitution is present.
                (ins if ch == "<" else outs).append("")
                break
            (ins if ch == "<" else outs).append(s[i + 2:j])
            i = j + 1
            continue
        i += 1
    return ins, outs, True


# A SECOND allowance of the same size, NOT a share of `_scan_budget`. The candidate walk
# below covers the whole command, and `is_file_mod`'s own per-segment walk then covers it
# again, so charging both against one counter silently HALVED the documented 4,000-token
# limit for any command holding a `<(`: a benign 2,004-token
# `grep -f <(echo pat) file0.txt ... file1999.txt` flipped from allow to BLOCK, with the
# charge buying nothing (the walk emitted no producer) and the later walk failing closed on
# a budget it had not spent. Two bounded walks are still bounded, and the branch runs only
# when a process substitution is present: a 65KB substitution-heavy command measures 0.33s
# against the hook's 5s timeout.
_psub_budget = [_MAX_SCAN_TOKENS]

# Every `_STDIN_SHELLS` name, for the quote-blind candidate test in `_procsub_producers`.
#
# The boundary is NOT `\b`, which treats a filename suffix as a word: `\bsh\b` matches
# `notes.sh` and `\bbash\b` matches `bash.log`, and this repo is full of `.sh` operands --
# `grep -n 'rm -rf src' notes.sh <(echo pat)` went from allow to block on that alone, which
# is precisely the quoted-operand false positive #519 exists to have removed. A `.` and a
# `-` therefore JOIN the word characters here, while `/` does not, so `/bin/bash` still
# matches and `notes.sh` does not.
#
# Quote-blind on purpose: resolving quoting is what the lexed path already does, and what
# adversarial quoting defeats.
_STDIN_SHELL_RE = re.compile(r"(?<![A-Za-z0-9_.:@=+#-])(?:"
                             + "|".join(sorted(map(re.escape, _STDIN_SHELLS)))
                             + r")(?![A-Za-z0-9_.\-/:@=+#])")

# The VERSION-QUALIFIED interpreter family, for the same scan. `_ATTACHED_INTERP_RE` is
# END-ANCHORED because it is asked of one WORD, so searching it across a whole command
# matched nothing and `/usr/bin/perl5.34` -- a real packaged executable that runs a program
# read from stdin -- walked through. DERIVED from that pattern rather than restated, so the
# two cannot drift: the trailing `$` is dropped and the same boundary the set above uses is
# put around it.
assert _ATTACHED_INTERP_RE.pattern.endswith("$")
_VERSIONED_INTERP_SCAN_RE = re.compile(r"(?<![A-Za-z0-9_.:@=+#-])"
                                       + _ATTACHED_INTERP_RE.pattern[:-1]
                                       + r"(?![A-Za-z0-9_.\-/:@=+#])")


# COMMAND POSITION, spelled STRUCTURALLY rather than by lexing. The word that follows a
# pipeline or grouping operator is the next command word, and that is true of the raw text
# whatever the quoting does to a lexer -- which is the whole point, because adversarial
# quoting is exactly the thing that takes the lexed answer away.
#
# This is what makes the command-position-only receiver classes askable quote-blind. Asked
# as ANY word they are the test this ADR measured at 100 over-blocks for `.` alone and
# rejected; asked HERE they keep the anchor that made them safe: `grep -n 'rm -rf src'
# <(printf source)` puts `printf` in command position, not `source`, and stays allowed.
# `(`, `)`, `{` and `}` are separators here, so a command WORD built by an expansion is torn
# in half -- `ba{s..s}h` into `ba` and `s..s`, `{s..s}ource` into `s..s` and `ource`. That is
# deliberate and answered INSIDE the walk, not here: only the walk knows whether the torn
# word was in command position. See the cut check and the run-tail check below.
_CMDPOS_RUN_RE = re.compile(r"(?:^|[;&|(){}\n])([^;&|(){}\n]*)")
# `>&`, `<&`, `>|` and `&>` -- the spellings whose `&`/`|` belongs to the redirect rather
# than to the pipeline. Folded to a bare operator before the run walk; see the note there.
# ESCAPED redirect characters are NOT folded: a `\>` is a literal argument, so the `|`
# after it is a REAL pipeline operator and folding it away destroyed the boundary --
# `printf <payload> \> | source /dev/stdin` then hid its receiver. Same lesson the
# splitter learned for `printf <payload> \<|bash`.
_REDIR_FOLD_RE = re.compile(r"(?<!\\)([<>])[&|]|(?<!\\)&(?=>)")


def _redir_fold(m):
    return m.group(1) or ""


# A BRACE EXPANSION opening a command word. `ba{s..s}h` is caught by the cut check -- the
# run ends with `ba` glued to the brace -- but a command word that BEGINS with one leaves
# nothing attached for that check to see, and the run regex hands the walk `s..s` and
# `ource` as two ordinary runs holding no receiver name. `{b..b}ash` survives only because
# `bash` is in the quote-blind name scan; `source` is command-position-only and deliberately
# outside it, so behind the quote pads `| {s..s}ource /dev/stdin` was a verified fail-OPEN.
#
# Spelled narrowly on purpose, because `{` also opens a GROUP COMMAND: an expansion has no
# whitespace and carries a `,` or a `..`, so `; { cat file; }` does not match and a
# read-only group is not refused.
# A BRACE EXPANSION is FOLDED OUT of the text before the run walk, exactly as a redirect
# operator is. A command word that BEGINS with one -- `{s..s}ource`, which bash expands to
# `source` -- leaves nothing attached in front of the brace for the cut check to see, and
# the run regex hands the walk `s..s` and `ource`, neither of them a name. `{b..b}ash` hid
# that for a while, because `bash` is in the quote-blind name scan and blocks wherever it
# sits; `source` is command-position-only by design, so behind the quote pads nothing else
# could answer and it was a verified fail-OPEN.
#
# Folding rather than a second command-position test, and that IS the lesson of the round:
# asking "is this empty run a command position?" needed a guard for a closer, then a guard
# for the group-command `{`, then a guard for a closer that ends an expansion inside a
# PREFIX -- four rounds, each fixing the previous one's opposite defect, which is this
# document's own signal to stop refining. An expansion is not a boundary at all; it is part
# of the word around it. Replaced by `*` -- already in `_UNRESOLVED_CW_CHARS` -- the word
# stays ONE word and the ordinary walk decides it: unresolvable in command position, an
# operand anywhere else. `X=$(true) {source,/dev/stdin}` blocks, `grep -n 'rm -rf src'
# {a,b}file <(echo pat)` does not, and neither needed a rule of its own.
# What ENDS a candidate span, unescaped: WHITESPACE, because an expansion is part of one
# word and a word ends there (`| X={a,b source /dev/stdin }` is an assignment prefix and
# then a receiver, and swallowing the spaces ate it); and a RUN SEPARATOR, because folding
# one away deletes a real pipeline boundary -- `printf <payload>{a,|bash>x}` is a pipe into
# a shell, and the redirect makes `bash` a genuine command name rather than `bash}`.
#
# Aborting a span does NOT take back the `*` already written for its opener, and that is
# what lets both halves hold at once. A QUOTED separator (`{s,";"x}ource`) is a stop here --
# telling it from a real one is the lexed question this walk exists because it cannot ask --
# but the word keeps its `*`, stays unresolvable, and blocks in command position anyway.
_BRACE_FOLD_STOP = frozenset(" \t\n\r;&|()")
# The characters that DELIMIT the `{` reserved word, i.e. that make it a GROUP command
# rather than the first character of a word.
_BRACE_FOLD_DELIM = frozenset(" \t\n\r<>;&|()")


def _fold_brace_expansions(text):
    """Replace each brace EXPANSION with `*`, leaving group commands and operators alone.

    ONE left-to-right pass, deliberately: the regex spelling of this -- an opening brace, two
    lazy non-space runs and a closing brace --
    carries two overlapping lazy scans and was measured at 6.29s on a 4.5KB command of
    stacked `({` and `a,` -- past the hook's 5s timeout, which writes no decision and reads
    as ALLOW, so it was a bypass rather than a slowdown. Bounding the scans would have made
    a long expansion the bypass instead.

    A GROUP command is excluded by the same fact bash uses to tell them apart: `{` must be
    delimited to be the reserved word, so whitespace and the operators that delimit it end
    a candidate span. `;`, `&`, `|` and the parens are on that list for a second reason too
    -- they are run separators, and folding across one would erase a pipeline boundary, the
    mistake the redirect fold already learned from an escaped redirect character.

    The OUTERMOST opener pairs with the FIRST close, which is what makes one pass enough for
    a nested word: `{X=,{b..b}ash}` folds to `*ash}`, still one unresolvable word.
    """
    if "{" not in text:
        return text
    out = []
    open_i = open_out = -1                 # source index of the opener, and its slot in `out`
    esc = False
    for i, ch in enumerate(text):
        if esc:
            # A BACKSLASH-ESCAPED character is data, never an operator -- the same fact the
            # redirect fold learned from `\>`. So an escaped space or `;` stays INSIDE the
            # span, and an escaped `}` does not close it.
            esc = False
            out.append(ch)
            continue
        if ch == chr(92):
            esc = True
        elif ch in _BRACE_FOLD_STOP:
            open_i = -1
        elif ch == "{":
            # ...and a GROUP command is left alone. Bash's own rule: `{` is the reserved
            # word only when what follows DELIMITS it, so `{ cat file; }` and `{>&1 x; }`
            # are groups -- real separators the walk must keep seeing as such -- while
            # `{a,b}` is the first character of a WORD.
            #
            # A word-opening `{` is replaced even when no close is ever found. It is not a
            # boundary either way, and the run regex splits on it: `| X={a,b source
            # /dev/stdin }` handed the walk a run STARTING at `a,b`, which it read as the
            # command and stopped there, never reaching the receiver behind it.
            # EVERY word-opening `{` is replaced, not only the one that opens the span.
            # A nested one emitted verbatim survives an ABORTED span as a run separator,
            # and `| X={a{b source /dev/stdin }` -- one brace deeper than the shape above,
            # and live under real bash -- split into `X=*a` and `b source ...`, so the walk
            # read `b` as the command. Inside a span that does fold, the extra `*` is
            # discarded with the rest of it. Do not make this conditional again: it is what
            # keeps an aborted span's word whole, which is the only thing standing behind
            # the quoting shapes this walk cannot lex.
            nxt = text[i + 1:i + 2]
            if nxt and nxt not in _BRACE_FOLD_DELIM:
                if open_i < 0:
                    open_i, open_out = i, len(out)
                out.append("*")
                continue
        elif ch == "}" and open_i >= 0:
            body = text[open_i + 1:i]
            if "," in body or ".." in body:
                del out[open_out:]         # the span was emitted verbatim; take it back
                out.append("*")
                open_i = -1
                continue
            open_i = -1
        out.append(ch)
    return "".join(out)
_CMDPOS_RECEIVERS = frozenset(("source", ".")) | _LAUNCHER_SHELLS

# RESIDUAL over-block, stated: the separator class is quote-blind, so punctuation inside a
# quoted OPERAND reads as a boundary and the word behind it as a command --
# `grep -n "rm -rf src; $file" <(echo pat)` and `grep -n "rm -rf src | source" <(echo pat)`
# both block. Telling a quoted `;` from a real one is the lexed question, and being defeated
# at it is the entire reason this walk exists; a second quote parser here would be defeated
# the same way. The shape needs a write verb inside a quoted pattern, punctuation inside that
# same pattern, AND a process substitution in the command, so it is narrow -- and it is the
# direction this module chooses. Pinned in the grid.


def _cmdpos_receiver_in_raw(text):
    """Does a command-POSITION word in this raw text name a receiver, or resolve at run time?

    Quote-blind and lexer-free, for the shapes where the lexer has been defeated. Three
    questions, all of them ones the lexed path already asks of a stage's first word: is it a
    command-position-only receiver name (`source`, `.`, a launcher), is it a dash-versioned
    interpreter, or is it UNRESOLVABLE -- built by an expansion or a glob, like
    `b$(printf as)h`, `$SHELL` or `/bin/ba[s]h`, where no spelling of the command contains a
    name at all.

    The expansion test is why this is anchored rather than asked of the whole command: a `$`
    ANYWHERE selected the whole-command scan and blocked
    `grep -n "rm -rf src" "$file" "<(x)"`, where the variable is an operand. In command
    position it is the program.

    Command position is a RUN, not the token after the operator -- bash allows assignments,
    redirections, prefix words, wrappers and reserved words in front of the real command --
    so the run is walked and the first word that is none of those is the answer.
    """
    # EXTGLOB first, because the run regex cannot see it: `(` is a separator here, so
    # `/bin/ba+(s)h` -- which bash expands to a real shell before a command word exists --
    # is split before `_UNRESOLVED_CW_CHARS` can be asked of it. The opener is a finite
    # two-character shape, and an ordinary operand carrying one is rare enough that refusing
    # the whole text costs a raw scan on a command that also holds a substitution.
    # A `&` or `|` that BELONGS TO A REDIRECTION is not a command separator. The run regex
    # splits on both characters unconditionally, so `| 2>&1 source /dev/stdin` broke into a
    # run ending `2>` and a run starting `1 source`: the pending target was lost, the walk
    # took `1` for the command word and never reached `source`. `>|` split the same way.
    # Behind the quote pads -- where the lexed candidate path is already defeated and the
    # command-position names are deliberately outside the quote-blind name scan -- that is a
    # fail-OPEN, verified.
    #
    # Normalised rather than parsed: the descriptor-duplication and clobber forms are folded
    # to a bare redirect (`2>&1` -> `2>1`, `>|` -> `>`, `&>` -> `>`), which is all this walk
    # needs -- it only has to recognise the word as a REDIRECTION so the prefix run
    # continues past it. `>>` carries no `&`/`|` and is untouched.
    text = _REDIR_FOLD_RE.sub(_redir_fold, text)
    # ...and a BRACE EXPANSION is not a boundary either -- it is part of the word around it.
    # Folded to `*` so `{s..s}ource` stays ONE unresolvable word; see `_fold_brace_expansions`.
    text = _fold_brace_expansions(text)
    for _m in _CMDPOS_RUN_RE.finditer(text):
        # Does this run end because an EXPANSION character was glued to its last word?
        # `(` and `{` are separators to the run regex, so `ba{s..s}h` and `/bin/ba+(s)h` --
        # which bash expands to a real program before a command word exists -- are cut in
        # half and `_UNRESOLVED_CW_CHARS` never sees them. Asked HERE rather than over the
        # text, because only the walk knows whether the truncated word was in COMMAND
        # POSITION: an anchored regex over the whole command made `grep -n 'rm -rf src'
        # file{1,2} <(echo pat)` a receiver, and an unanchored one made every operand one.
        # TUPLE membership, not `in "({"`: an empty slice is a substring of every string, so
        # a run ending at end-of-text read as `cut` and its last word as a truncated command.
        _cut = (text[_m.end():_m.end() + 1] in ("(", "{")
                and _m.group(1) and not _m.group(1)[-1].isspace())
        _skip_target = _seen_prefix = False
        _words = _m.group(1).split()
        # BY INDEX, not by identity. `w is _last_word` looked right and was not: CPython
        # interns short strings, so a leading `!` and a trailing `!` are the SAME object and
        # the cut check fired on the wrong word -- `! grep -n 'rm -rf src' !{a,b} <(echo pat)`
        # matched on the leading `!` prefix and blocked a read-only grep.
        _last_i = len(_words) - 1
        for _i, w in enumerate(_words):
            # A BACKSLASH counts with the quotes: bash joins `X=foo\ bar` into ONE
            # assignment word, and whitespace-splitting cuts it in two exactly as a quoted
            # value is cut. Same exit, same reason -- knowing where the word really ends is
            # the lexed question this walk exists because it cannot ask.
            _quoted = _DQ in w or _SQ in w or chr(92) in w
            if _skip_target:
                # the operand of a BARE redirection operator, which is a filename and never
                # the command: `| > /dev/null source /dev/stdin` put `/dev/null` where the
                # walk was looking and it stopped there.
                _skip_target = False
                if _quoted:
                    return True               # `> "/tmp/a b"` -- see the note below
                continue
            if _REDIR_RE.fullmatch(w):
                # NO CUT CHECK HERE. A process substitution ends its own run in a bare `<`
                # or `>` followed by `(` BY CONSTRUCTION, so testing it here fired on every
                # such command -- `grep -n 'rm -rf src' file{1,2} <(echo pat)` included. A
                # redirect operator is never a truncated command word.
                _skip_target = _seen_prefix = True
                continue
            _bare = re.split(r"[<>]", w, maxsplit=1)[0]        # `command>/dev/null` is a prefix too
            if (_ASSIGN_RE.match(w) or _REDIR_RE.match(w)
                    or _basename(_bare) in _CMD_PREFIX_WORDS
                    or w in _CMD_PREFIX_WORDS
                    # ...and WRAPPERS, which the lexed path peels for the same reason:
                    # `| env source /dev/stdin` puts `env` where a prefix word would be, and
                    # the generated grid caught it.
                    or (_basename(_bare) in _WRAPPERS | _ENV_NAMES
                        # ...but an OPERAND-taking wrapper is not steppable: `flock FILE
                        # CMD` and `chroot ROOT CMD` put a positional operand between the
                        # wrapper and the command, so the walk stopped on the operand and
                        # never reached the receiver. Which wrappers take one, and how many,
                        # is the arity table this module refuses to build -- so the run is
                        # refused instead, the same move made for an option in command
                        # position.
                        and _basename(_bare) not in _OPERAND_WRAPPERS)
                    # ...and the RESERVED words that open or connect a compound command:
                    # `| if true; then source /dev/stdin; fi` splits on the `;`, so the run
                    # holding the receiver begins with `then`. Derived from the keyword sets
                    # rather than hand-listed, so adding a keyword extends both walks.
                    or w in _COMPOUND_WORDS):
                # A QUOTE INSIDE THE PREFIX RUN makes it unresolved, and that is the exit
                # rather than a fix: whitespace-splitting cuts a quoted value in two
                # (`X="a b" source /dev/stdin`), and a parity counter over both quote kinds
                # was tried and defeated at once by `X="'a b'"`, whose aggregate parity is
                # even while the value still spans two fragments. Knowing which quote is
                # open is the LEXED question, and being defeated at it is why this walk
                # exists. Scoped to words already identified as PREFIX, because the run
                # regex splits on `(` and leaves quote fragments of ordinary operands
                # behind -- `grep -n 'rm -rf src <(' notes.txt` yields a bare `'` run, and
                # refusing on that blocked a read-only grep.
                if _quoted:
                    return True
                if (_cut and _i == _last_i
                        and not _ASSIGN_RE.match(w) and not _REDIR_RE.match(w)):
                    # ...and the CUT check belongs here too, not only past the branches. A
                    # truncated command word can look like a prefix: `/tmp/only-shell/!(nope)`
                    # is cut to `/tmp/only-shell/!`, whose basename `!` IS a prefix word, so
                    # the walk continued past it and never asked whether the run ended in an
                    # expansion. With extglob on, bash resolves that word to whatever the
                    # directory holds.
                    #
                    # NOT for an ASSIGNMENT or a REDIRECTION, though. Neither is ever the
                    # command word, so an expansion in its value or target says nothing
                    # about what runs: `X=foo{a,b} grep -n 'rm -rf src' <(echo pat)` and
                    # `</tmp/${name} grep -n 'rm -rf src' <(echo pat)` are read-only greps,
                    # and firing here blocked both. A truncated command word never starts
                    # with `<` or `>`, so the exemption cannot hide one. The command is
                    # whatever follows, and the walk goes on to ask about that.
                    return True
                _seen_prefix = True
                continue
            if _basename(re.split(r"[<>]", w, maxsplit=1)[0]) in _OPERAND_WRAPPERS:
                return True               # see the operand-wrapper note above
            if _seen_prefix and w.startswith("-"):
                # AN OPTION IN COMMAND POSITION marks the run unresolved rather than being
                # stepped over. Stepping over it is only sound when it takes no value:
                # `env -u X $SHELL` put `X` -- the operand of `-u` -- where the command word
                # goes, and the walk read it as the program. Deciding which options take a
                # value is the arity table this module refuses to build, and it fails OPEN
                # when wrong; the same move is already made for an option before a launcher.
                return True
            # UNRESOLVABLE, on the same set the lexed path uses rather than a subset of it:
            # `$` and a backtick were asked for, and `/bin/ba[s]h` -- a GLOB that bash
            # expands to a real shell before a command word exists -- was not. `(` cannot
            # reach here, since the run regex treats it as a separator.
            if any(ch in w for ch in _UNRESOLVED_CW_CHARS):
                return True
            # ...with any ATTACHED redirect cut off first. A redirection needs no
            # whitespace, so `source</dev/stdin` and `lldb-19</dev/stdin` arrive as ONE
            # word and the name test saw the redirect glued to the receiver.
            b = _basename(re.split(r"[<>]", w, maxsplit=1)[0])
            if b in _CMDPOS_RECEIVERS or _CMDPOS_INTERP_RE.fullmatch(b):
                return True
            if _cut and _i == _last_i:
                return True               # the command word ran into an expansion
            break
    return False



def _any_reads_program_from_stdin(texts, seen):
    """Might any of these stages run a program it reads from stdin?

    CHARGED before each call, for the reason `_piped_shell_producers` records at its own
    charge site: the walk behind this question is the potentially quadratic one, and a hook
    that overruns its 5s timeout writes NO decision, which the harness reads as ALLOW.
    Exhaustion answers True, so an unfinished scan widens rather than narrows; the caller
    turns an exhausted walk into the whole-command scan, which is the same best-effort exit
    this module already takes for an unreadable command.

    THE CALLER CHARGES, once, for the whole command. Charging per text here double-counted
    twice over -- a substitution body is normally already one of the segments, and the
    segments PARTITION the very command that is also passed as a stage, so a 2,004-token
    command spent about 4,008 against a 4,000 budget. Every text handed here comes out of
    ONE command, so one charge for that command bounds them all; `seen` still keeps the walk
    from repeating on identical text, which is the cost the charge exists to bound.
    """
    for t in texts:
        if t in seen:
            if seen[t]:
                return True
            continue
        seen[t] = _may_read_program_from_stdin(t)
        if seen[t]:
            return True
    return False


def _procsub_producers(pairs, whole, subs):
    """Text feeding a shell across a PROCESS SUBSTITUTION rather than a pipe (#563).

    Same decision as `_piped_shell_producers` and the same fail-closed answer -- hand the
    visible payload to the raw pre-#519 regexes -- for the transport that scan cannot see.
    Nothing here models the language: the receiver question is the one
    `_may_read_program_from_stdin` already answers, and what is yielded goes to the same
    producer loop the pipe path feeds.

    SCOPE, and the over-block it buys. For `<(...)` the candidate test is asked of every
    stage of the command rather than of the stage the substitution is attached to: the
    splitter breaks on `(` and `)`, so a substitution arrives already torn off its own
    stage and binding the two back together means positional bookkeeping the splitter does
    not keep. The cost is that a shell named ANYWHERE in the command puts every `<(...)`
    body under the raw scan -- `sh -c ':' <(printf 'rm -rf src')` blocks. For `>(...)` the
    producer is the WHOLE command, for the same reason and with the same trade, which is
    the shape the indirection rule in `is_file_mod` already takes.

    Process substitutions are RARE, so an ordinary command pays nothing: the candidate walk
    runs only once one is present. `subs` is the caller's already-computed
    `_process_substitutions(whole)`, which it needs anyway for the indirection trigger --
    one walk, not two.
    """
    ins, outs, ok = subs
    if not ok:
        return [whole]                    # unreadable: fail CLOSED, scan it all
    if not (ins or outs):
        # NOTHING to route, so charge nothing and INHERIT nothing. The exhaustion exit below
        # is unconditional otherwise, and `_psub_budget` is reset only at depth 0 -- so once
        # any nested branch exhausted it, every later sibling in the same top-level call was
        # raw-scanned whole for a walk it never ran. Over-blocking only, but it is the same
        # cross-command budget coupling this allowance was split off to remove.
        return []
    # ONE PRODUCER, ONE CANDIDATE, and both are the WHOLE command.
    #
    # The first cut scoped the input direction to the substitution BODIES, which was more
    # precise and depended on `_subst_end` extracting the right body. It does not always: a
    # `case` PATTERN terminator is a bare `)` with no opener, so
    # `bash < <(case x in x) printf 'rm -rf src';; esac)` truncated at `x)` -- verified
    # executing. A paren-balance guard closed that spelling and was re-balanced by an
    # unrelated `(`; scoping the PRODUCER to the whole command fixed the payload half but
    # left the extraction load-bearing for the RECEIVER half, since a truncated body hides
    # the shell inside it from the candidate test.
    #
    # So the extraction is not load-bearing at all now. It answers ONE question -- is there
    # a process substitution here -- where over-reading is free, and both the candidate test
    # and the raw scan are given the whole command, which contains every body whether or not
    # `_subst_end` found its end. The cost is stated plainly: a shell named ANYWHERE in a
    # command carrying a process substitution puts that whole command under the raw scan.
    # That is the trade the indirection rule already makes, it is scoped by rarity (the walk
    # runs only when a substitution is present), and it replaces a guess that was wrong
    # twice in two different halves.
    # THE WHOLE COMMAND *AND* THE BODY STAGES. `whole` is what makes the extraction
    # non-load-bearing -- its any-word shell test sees a receiver the extraction truncated
    # away -- but it cannot answer the COMMAND-POSITION-only names, `.` and `source`, which
    # are only ever asked of a stage's own first word. Handing it alone therefore lost
    # `> >(true; . /dev/stdin)`, where `whole` begins with `printf`. Both, then: the split
    # bodies for the command-position question, `whole` for everything the split may have
    # missed -- and the SPLIT SEGMENTS of the command, which is the third source and the
    # one that does not depend on the extraction at all: the splitter breaks `>(` on the
    # paren, so a receiver inside a body that `_subst_end` truncated away
    # (`> >(case x in x) . /dev/stdin;; esac)`) still arrives here as a segment of its own,
    # in command position, where `.` and `source` are answered. A wrong extraction now costs
    # precision and never soundness.
    # ONE CHARGE, for the whole command, before any of it is walked -- for the reason
    # `_piped_shell_producers` records at its own charge site: the walk behind this question
    # is the potentially quadratic one, and a hook that overruns its 5s timeout writes NO
    # decision, which the harness reads as ALLOW. Everything below is derived from `whole`
    # -- its own partition, and bodies inside it -- so charging per text counted the same
    # bytes two and three times over.
    # STAGES AS WELL AS WORDS. `len(whole.split())` alone is a proxy that ignores shell
    # punctuation, and punctuation is what carries the cost here: a 64KB command of repeated
    # `env;` segments splits into ~16,000 stages, each of which gets the walk -- and it
    # charged FIVE tokens and measured 8.86s against the hook's 5s timeout, which writes no
    # decision and reads as ALLOW. This is the third time in this family that an
    # under-charged scan was a bypass rather than a slowdown; the budget has to track the
    # dimension the work actually grows in.
    # ...and by CHARACTERS, because neither words nor stages bound the LEXER. A 60KB
    # command of repeated `su<a>` fragments is four words and one stage, and it produced
    # ~48,000 tokens and took 14.0s -- past the hook's 5s timeout, which writes no decision
    # and reads as ALLOW. Redirect characters make tokens without making whitespace, so the
    # only measure that tracks all three is the length itself; the divisor is a floor, not a
    # model, chosen so an ordinary 2,000-operand command still fits inside the 4,000 ceiling.
    _psub_budget[0] -= max(len(whole.split()) + len(pairs), len(whole) // 8)
    if _psub_budget[0] < 0:
        return [whole]                    # exhausted: unexamined, not clean
    # A QUOTE-BLIND NAME SCAN, in addition to the lexed stages. Adversarial quoting can
    # make `shlex` pair its quotes differently and swallow the receiver: a matched pair of
    # `: "$(printf '"')"` pads around `cat < <(payload) | bash` left every lexed view of the
    # command without the word `bash`, so both this walk and the pipe scan answered no --
    # verified executing. This test cannot be fooled that way because it never resolves
    # quoting at all; it only ever ADDS a candidate, and it fires only on a command that
    # already carries a process substitution.
    # ...asked of every SHELL VARIANT, not just the text as written. The shell strips
    # quoting and escapes before it resolves a command word, so `b\a\s\h` runs bash while
    # no contiguous `bash` appears -- the same obfuscation `_shell_variants` already exists
    # to answer everywhere else in this module.
    # ...and the VERSION-QUALIFIED spellings, which are a separate set: `_STDIN_SHELLS` is
    # exact names, so `/usr/bin/perl5.34` -- a real packaged executable that runs a program
    # read from stdin -- matched nothing. `_ATTACHED_INTERP_RE` is the same family the lexed
    # path already asks about, and it is unanchored for exactly this kind of search.
    #
    # PROGRAM NAMES ONLY. A quote-blind pass over the COMMAND-POSITION-only classes was
    # written -- `source`, the `. /path` shape, the launchers, the dash-versioned
    # interpreters -- and it closed those receivers behind the pads. It also re-created the
    # any-word test this ADR MEASURED and rejected: those are ordinary English words, and
    # `grep -n 'rm -rf src' <(printf source)`, the `unshare` and `lldb-19` twins, all went
    # from allow to block. The lexed path anchors them to command position for exactly that
    # reason, at a measured cost of 100 over-blocks for `.` alone. `_STDIN_SHELLS` and the
    # version-qualified family are different: the pipe path already matches those as ANY
    # word, so asking them here is consistent rather than a widening.
    # THE SQUEEZED VARIANTS ONLY -- the ones with quoting, escapes and `$` removed, which is
    # what `_shell_variants` produces after its first two entries. Asked of the RAW text as
    # well, a quote or a backslash acts as a name boundary that the shell will delete before
    # it resolves anything: `bash".log"`, `bash\.log` and `python3".12.log"` are ordinary
    # filenames, and each matched, turning read-only commands into blocks. Squeezed, they are
    # `bash.log` and `python3.12.log`, which the boundary correctly refuses -- while the
    # shapes this scan exists for (`b\a\s\h`, a name behind the quote pads) squeeze down to
    # the bare name and still match.
    _variants = _shell_variants(whole)
    if any(_STDIN_SHELL_RE.search(v) or _VERSIONED_INTERP_SCAN_RE.search(v)
           for v in _variants[2:]):
        return [whole]
    # ...and the command-position walk over EVERY variant, squeezed and not. The name half
    # of it wants the squeezed text for the same reason the scan above does; the EXPANSION
    # half wants the raw, because squeezing deletes the `$` that is the whole signal --
    # `b$(printf as)h` squeezes to `b(printf as)h` and names nothing. Both are cheap, so
    # both are asked rather than choosing.
    if any(_cmdpos_receiver_in_raw(v) for v in _variants):
        return [whole]
    # ADVERSARIAL QUOTING, and how it is answered. A command can be built so `shlex` pairs
    # its quotes differently -- a matched pair of `: "$(printf '"')"` pads is the shape --
    # and every LEXED view then loses the receiver. Two quote-blind answers were written for
    # it and both were withdrawn on measurement, because each asked a command-position
    # question of the WHOLE command:
    #
    #   any `$` or backtick anywhere   ->  blocked `grep -n "rm -rf src" "$file" "<(x)"`
    #   any `source`/launcher anywhere ->  blocked `grep -n 'rm -rf src' <(printf source)`
    #
    # A `$` and the word `source` are ordinary anywhere else in a command; they mean
    # RECEIVER only in command position, which is exactly what the lexer was providing and
    # what the quoting takes away. So the anchor was rebuilt WITHOUT the lexer:
    # `_cmdpos_receiver_in_raw` walks the word after every pipeline and grouping operator --
    # true of the raw text whatever the quoting does to a lexer -- and asks the three
    # questions the lexed path asks of a stage's first word. Both faces close, and every one
    # of those over-blocks stays allowed, because in each the word in question is an operand
    # rather than a command.
    #
    # The rule this keeps re-deriving: when a test is safe only in COMMAND POSITION, do not
    # widen it to any position -- rebuild the position test in whatever terms still work.
    _stages = [whole] + [seg for _op, seg in pairs]
    for _body in ins + outs:
        _bsegs, _bok = _split_simple_commands(_body)
        if not _bok:
            return [whole]                # unsplittable body: fail CLOSED, scan it all
        _stages.extend(_bsegs)
    out, seen = [], {}
    if _any_reads_program_from_stdin(_stages, seen):
        out.append(whole)
    return out


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
        if base == "watch":
            # `watch COMMAND` joins every remaining non-option argument with a single
            # space and runs the result through `sh -c` (procps-ng behavior, and true
            # of every non-`--exec` invocation, quoted or not) -- so `watch 'rm -f
            # src/file'` executes `rm -f src/file` as SHELL SOURCE, not as one opaque
            # word. The generic scan_all path below only re-checks each TOKEN against
            # _MOD_VERBS, which is exactly right for `watch rm -f src/file` (three
            # tokens, `rm` matches directly) but blind to the quoted-string spelling,
            # where shlex hands back one token (`"rm -f src/file"`) that matches no
            # verb name at all. Recursing through is_file_mod (the same path every
            # other runner in this function uses) re-tokenizes that string and catches
            # the embedded verb either way.
            #
            # `--exec`/`-x` bypasses the shell (execvp on the raw argv), so treating
            # its payload the same way is a deliberate over-read, not an exact model:
            # shell metacharacters in an --exec argument are literal there but would be
            # re-interpreted here. That is the safe direction for this module -- an
            # over-block, never a miss.
            #
            # ONLY multi-word tokens are recursed, and there is deliberately NO
            # option-arity table. Locating the command start means knowing which watch
            # flags take a value, and every approximation of that fails OPEN: the first
            # draft of this branch skipped one token per flag bar -n/--interval, and any
            # OTHER value-taking option (procps keeps adding them -- --equexit and
            # --shotsdir postdate that list) shifts the start, so the payload joined from
            # the wrong index and went unclassified. Whitespace needs no such table. A
            # single-word option value (`-n 5`, `--shotsdir logs`) carries none, so it is
            # inert here, and `watch` is in _WRAPPERS, so the generic all-token scan below
            # judges every bare word anyway -- which is what already caught the unquoted
            # `watch rm -f src/file`. The gap this closes is exactly the quoted spelling,
            # where shlex returns ONE token matching no verb name.
            #
            # Price: `watch grep 'rm -rf' f` over-blocks. watch does not preserve those
            # quotes -- it joins its arguments and re-parses, so what actually runs is a
            # read-only grep -- but judging the fragment alone is the fail-CLOSED
            # direction, and that shape is far rarer than the payload it protects.
            # EVERY argument, unconditionally. Not multi-word ones, not padded ones, not
            # ones bearing shell metacharacters -- every one. watch joins its arguments and
            # runs the result through sh -c, so there is no such thing as an inert argument
            # here, and any test for which tokens are "really" shell source is a detector
            # that fails OPEN on the spelling it has not met yet. Three drafts of this line
            # proved that: a multi-word test missed `watch -- " python3" ...` (one word plus
            # a leading space), and adding a padding test still missed `watch ">src/file"`
            # (one bare word that is a redirect). Recursing everything ends the sequence
            # rather than extending it.
            #
            # The cost is bounded and the direction is safe: each candidate is judged alone,
            # so an option value or a filename simply classifies as nothing, and a bare verb
            # was already caught by the all-token scan below.
            for t2 in toks[i + 1:]:
                _add(t2)
            # ...and the JOIN, because the operator can split one command ACROSS arguments.
            # `watch ">" src/file` is two inert-looking tokens that watch concatenates into
            # a redirect, so neither one classifies alone while the pair truncates the file.
            # Per-argument recursion and the join each catch what the other misses.
            _joined = " ".join(t2.strip() for t2 in toks[i + 1:] if t2.strip())
            if _joined:
                _add(_joined)
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
        # NO `--` terminator handling here, deliberately. Honouring it needs to know
        # whether the `--` is itself the operand of an earlier value-taking option:
        # `sed -f -- -i file` reads its script from a file named `--`, so the `-i`
        # AFTER it is a live in-place write. Stopping the scan at the first `--` reads
        # that as a filename and allows the write, and the option set that would make
        # the distinction (-e, -f, -l, --expression, --file, --line-length, and
        # whatever a BSD or future GNU sed adds) is the arity table this module refuses
        # to keep -- every gap in it fails OPEN. The cost of leaving `--` unhandled is a
        # read-only `sed -n -- --in` over-blocking on a file literally named `--in`.
        # Over-block versus missed write is not a close call.
        if re.match(r"^-[A-Za-z]*i", t):
            return True
        if t.startswith("--"):
            name = t.partition("=")[0][2:]
            # GNU getopt_long accepts ANY non-empty unambiguous prefix of a long
            # option -- there is no minimum-length floor, and no way to disable
            # this in getopt_long itself. `--in-place` has no other GNU sed long
            # option sharing its prefix (verified: --binary, --debug, --expression,
            # --file, --follow-symlinks, --help, --line-length, --posix,
            # --quiet/--silent, --regexp-extended, --separate, --sandbox,
            # --unbuffered, --version, --zero-terminated -- none start with "i"),
            # so `--i` and `--in` are unambiguous and sed itself treats them as
            # --in-place. A `len(name) >= 3` floor excluded exactly those two
            # spellings and classified `sed --i file` as read-only.
            if name and "in-place".startswith(name):
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
                    # `+` terminates only after `{}`; elsewhere it is an operand, and
                    # breaking on it truncated the payload (`-o + unshare`).
                    if t2 == ";" or (t2 == "+" and payload and payload[-1] == "{}"):
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
        _psub_budget[0] = _MAX_SCAN_TOKENS
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
        # RESIDUAL, stated: this is verb patterns only, so a redirect-only write behind an
        # unparseable command (`printf 'echo x > src/impl.py' | bash` with an unterminated
        # backtick) is not seen -- the producer scan that would see it is skipped whenever a
        # parser bails. Adding the redirect half here was tried twice and withdrawn both
        # times: raw, it read an INERT redirect inside a comment as a write (this path runs
        # BEFORE comment defusing, and a comment's stray apostrophe is often what made the
        # command unparseable in the first place); gated on `#` being absent, the gate became
        # a bypass primitive -- append a quoted `#` and the redirect half switches off.
        # Deciding which `#` opens a comment needs the quote state that is by definition
        # broken here. Refusing to guess is the same exit `)#` already takes.
        return _regex_fallback(cmd)
    for body in bodies:
        if is_file_mod(body, _depth + 1):
            return True
    _paren_hash_ambiguous[0] = False
    _norm = _normalize(cmd)
    pairs, ok = _split_with_ops(_norm)
    if not ok:
        return _regex_fallback(cmd)      # same residual as the substitution path above
    # `)#` -- the comment defuser could not tell whether that paren delimited a command, so
    # it refused to guess and said so. Unresolved is the fail-CLOSED case here exactly as it
    # is for an unparseable command above: fall back to the raw whole-command scan.
    if _paren_hash_ambiguous[0]:
        if _regex_fallback(cmd):
            return True
        if any(_RAW_WRITE_REDIR_RE.search(v) for v in _shell_variants(cmd)):
            return True
    # A shell on the RECEIVING end of a pipe executes what the producer wrote, and this
    # scan can only see that payload as data. Degrade to the pre-#519 raw scan over the
    # producer -- see _piped_shell_producers for why the pipe is not modelled instead.
    #
    # BOTH halves of the verdict, exactly as the depth cap above learned to do: the verb
    # regexes cannot see a redirect-only write, so `printf 'echo x > src/impl.py' | bash`
    # performed the write and classified as a read. The caller's own redirect check does not
    # cover it either -- it strips single-quoted text first, which is where a payload lives.
    # ...and the same verdict for a shell fed across a PROCESS SUBSTITUTION rather than a
    # pipe, which the scan above recognises only `|`/`|&` as (#563).
    _psub = _process_substitutions(_norm)
    _psub_present = any(_psub[:2])
    _producers = _piped_shell_producers(pairs) + _procsub_producers(pairs, _norm, _psub)
    for producer in _producers:
        if _regex_fallback(producer):
            return True
        if any(_RAW_WRITE_REDIR_RE.search(v) for v in _shell_variants(producer)):
            return True
    # INDIRECTION WITHDRAWS THE STAGE CONTRACT, the same way it does in the helper guard.
    # A NAME can stand for either end of the transport: `f(){ bash; }; printf <payload> | f`
    # hides the shell, and `g(){ printf <payload>; }; g | bash` hides the payload -- and the
    # definition sits in a DIFFERENT pipeline from the use, so no producer slice contains it.
    # Rather than resolve functions and aliases (and lose to the next spelling), a command
    # that BOTH introduces indirection AND feeds a candidate stage is scanned whole.
    # Keyed on ANY pipe, not on a candidate stage: the whole point is that the receiver may
    # be a NAME (`... | f`), which no candidate test can recognise as a shell.
    #
    # ...and on any PROCESS SUBSTITUTION for the same reason, which the first cut of #563
    # left out: a substitution is a transport with no `|` in it, so keying this on the pipe
    # alone let indirection hide either end of it. Both spellings were verified executing
    # while `is_file_mod` answered False -- `f(){ printf 'rm -rf src'; }; bash < <(f)` (the
    # producer handed to the regexes is the bare name `f`) and
    # `f(){ bash; }; printf 'rm -rf src' > >(f)` (`f` is not recognised as a shell) -- while
    # their pipe twin `f(){ printf 'rm -rf src'; }; f | bash` already blocked through this
    # very rule. The transport changed; the reason the rule exists did not.
    if (any(_is_pipe(_o) for _o, _ in pairs) or _psub_present) and _has_indirection(cmd):
        if _regex_fallback(cmd):
            return True
        if any(_RAW_WRITE_REDIR_RE.search(v) for v in _shell_variants(cmd)):
            return True
    for _op, segtext in pairs:
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
            #
            # Same residual as the two paths above: verb patterns only.
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
    """Self-check: the #519 false positives must be allowed, real writes still caught.

    Fixture data (the `allowed`/`blocked` command lists) lives in the sibling
    cmdword_demo_fixtures.py, imported HERE rather than at module scope, so the
    production import path (`from cmdword import is_file_mod`) never depends on
    that file's presence -- only running this self-check does. Moved out after
    CodeScene flagged this module's Lines-of-Code health (#548 review): the ~90
    lines of literal fixture strings counted toward the file's LOC threshold
    without being classifier logic, so relocating them (pure data, no behavior
    change) addresses the metric without touching anything the gate evaluates.
    """
    import os
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from cmdword_demo_fixtures import DEMO_ALLOWED, DEMO_BLOCKED
    allowed = DEMO_ALLOWED
    blocked = DEMO_BLOCKED
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
