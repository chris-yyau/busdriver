"""Command classifier for the pre-implementation gate (extracted from
pre-implementation-gate.sh, #557).

This program used to be passed inline as a single `python3 -I -c` argument. At
133043 bytes it crossed the Linux MAX_ARG_STRLEN cap of 131072 bytes per argv
element, so execve failed with E2BIG, python never started, and the gate's
fallback substituted an ALLOW -- a silent bypass on Linux only (macOS has no
per-argument cap). Living in a file removes that ceiling entirely.

Reads the hook payload as JSON on stdin; prints one `ACTION|TARGET` line.
Keep in step with lib/cmdword.py -- the same rules exist in both.
"""
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import fnmatch, json, posixpath, re, shlex

_SQ = chr(39)
_DQ = chr(34)


def _bn(t):
    return t.rsplit("/", 1)[-1]


def _refs(tok):
    # Shell variable names referenced in a token: $name and ${name}.
    return re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", tok)


def _match_marker(tok, markers, simple_vars):
    # Substring match WITHIN the token: robust to wrappers that leave the marker
    # name embedded — parameter expansion (${V:-...}), ANSI-C quoting, path
    # concatenation. Also resolves a write performed through a shell variable
    # assigned earlier in the SAME command (m=.../marker; rm "$m") via
    # simple_vars. Precision is preserved by only calling this on STRUCTURALLY
    # dangerous positions (a redirect target, or a word in an rm/tee segment),
    # so a marker merely mentioned in an unrelated quoted argument or read
    # command is still allowed.
    for mf in markers:
        if _bn(mf) in tok:
            return mf
    for name in _refs(tok):
        val = simple_vars.get(name, "")
        for mf in markers:
            if _bn(mf) in val:
                return mf
    return None


def _is_redir(t):
    # A redirect operator token: pure punctuation that includes < or > (so >, >>,
    # <, <<, <<<, >|, >&, <&, <> all qualify). Bare ; | & ( ) are NOT redirects:
    # after quote-aware segmentation (below) they only reach here as quoted or
    # escaped LITERAL operands, so they must read as words, never operators. This
    # is the fix for the quoted-separator bypass (rm ; .file with a quoted or
    # escaped semicolon) — the old purity test treated ANY pure-punctuation token
    # as an operator, so shlex-stripped quoting let a marker delete masquerade as
    # a separate command.
    return len(t) > 0 and all(c in "<>|&" for c in t) and ("<" in t or ">" in t)


def _split_with_ops(s):
    # _split_simple_commands, but each segment carries the operator RUN that preceded it,
    # so a pipe-fed stage can be told from a `||` one. Consecutive operator characters
    # join into a single run only when no segment text sits between them, which is exactly
    # what separates `a || b` from `a | ; b`.
    # KEEP IN STEP WITH cmdword._split_with_ops.
    pairs, buf, op = [], [], []
    in_s = in_d = esc = False
    # Did the PREVIOUS character open a redirect -- an unquoted, unescaped `<` or `>`? State,
    # not inference: buf[-1] cannot say whether it was escaped, and bash runs
    # `printf <payload> \<|bash` as a real pipeline because the escaped `<` is an argument.
    redir = False
    xglob = 0                             # open EXTGLOB parens -- see the branch below
    for _i, ch in enumerate(s):
        if esc:
            buf.append(ch)
            esc = redir = False
        elif in_s:
            buf.append(ch)
            if ch == _SQ:
                in_s = False
            redir = False
        elif in_d:
            buf.append(ch)
            if ch == "\\":
                esc = True
            elif ch == _DQ:
                in_d = False
            redir = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
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
            # its output twin was handled, splitting the segment mid-redirect so the producer
            # of `printf <payload> <&0 | bash` became the bare `0`. Keyed on the REDIRECT
            # CHARACTER, so the next spelling cannot reintroduce the asymmetry.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == "&" and s[_i + 1:_i + 2] == ">":
            # `&>` / `&>>` redirect BOTH streams -- the `&` belongs to the redirect, not to
            # the pipeline. Read as a control operator it cut the segment in two and threw
            # the real producer away: `printf <payload> &>/dev/stdout | bash` kept only the
            # `>/dev/stdout` half. KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == "(" and buf and buf[-1] in "+*?@!":
            # EXTGLOB, not a group: with `shopt -s extglob`, `+(s)`, `*(…)`, `?(…)`, `@(…)`
            # and `!(…)` are pathname patterns, so `/bin/ba+(s)h` expands to `/bin/bash`.
            # Split on the paren, the receiver command word came apart and the shell name
            # vanished. The lead character is what distinguishes them, and it is finite.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            xglob += 1
            redir = False
        elif xglob and ch in ";|&":
            # INSIDE a pattern, every control character is pattern text: `@(s|z)` holds a
            # real `|` that separates alternatives, not pipeline stages. Keeping the parens
            # while still splitting on that `|` left the receiver in pieces again. KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == ")" and xglob:
            # its matching close -- kept with it, or the command word still comes apart on
            # the other half of the pattern.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            xglob -= 1
            redir = False
        elif ch in ";|&()":
            if buf or not op:
                pairs.append(("".join(op), "".join(buf)))
                buf, op = [], [ch]
            else:
                op.append(ch)
            redir = False
        else:
            buf.append(ch)
            redir = ch in "<>"
    pairs.append(("".join(op), "".join(buf)))
    return pairs, not (in_s or in_d or esc)


def _split_simple_commands(s):
    # Split into simple-command segments on UNQUOTED, UNESCAPED control operators
    # (; | & and grouping parens) with an explicit quote/escape state machine.
    # This MUST happen before shlex: posix shlex strips quoting, which makes a
    # quoted/escaped separator indistinguishable from a real one and lets a marker
    # delete slip into a "different" command (rm ; .file). Clobber >| and dup >&
    # embed | / & but are part of the redirect, so a | or & directly after > is
    # kept attached rather than treated as a split. Returns (segments, ok); ok is
    # False on an unterminated quote or dangling escape so the caller fails closed.
    # Clobber >| and dup >& embed | / & but are part of the redirect, so a | or & directly
    # after > is kept attached rather than treated as a split -- see _split_with_ops,
    # which does the scanning for both.
    pairs, ok = _split_with_ops(s)
    return [seg for _op, seg in pairs], ok


# Commands that RUN the command that follows them. Open-ended by nature: a launcher not
# listed here is treated as an ordinary command, so its payload is judged by the strict
# rule. That is a known limit of an allowlist, not a claim of completeness -- see the
# RESIDUAL note in _scan_segment. Platform launchers are included because they are
# ordinary, discoverable commands rather than obfuscation.
# KEEP IN STEP WITH cmdword._WRAPPERS -- a launcher missing from either list is a hole
# in that half. `watch` was missing from both: `watch --exec rm -rf src` resolved its
# command word to `watch` and read as a plain observation.
_WRAPPER_CMDS = ("sudo", "doas", "su", "runuser", "env", "nohup", "timeout", "nice",
                 "ionice", "setsid", "stdbuf", "unbuffer", "command", "builtin", "exec",
                 "xargs", "caffeinate", "chroot", "arch", "torify", "proxychains",
                 "proxychains4", "watch", "flock", "script")
# Reserved words that PRECEDE a command. Without these, `if touch <marker>; then :; fi`
# and `{ touch <marker>; }` pick `if` / `{` as the command word and are allowed.
_RESERVED_SH = ("if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                "esac", "coproc", "{", "}", "!", ")", "(")
# Test-expression openers: everything after is an OPERAND, never a command, so a read
# such as `[ -f <marker> ]` must not be read as an invocation.
_TEST_OPEN_SH = ("[[", "[")
# A verb embedded INSIDE one operand — `env -S "touch <marker>"` keeps the whole program
# in a single token, so basename equality never matches it. Only consulted in the
# wrapper regime, which already tolerates over-blocking.
# time/script/flock are listed as VERBS, not wrappers, even though they also run a
# following command: each can write a file ITSELF via a flag or operand
# (`time -o <log> true`, `script <log>`, `flock <log> cmd`). Treating them as pure
# wrappers meant the conservative scan looked for a verb in the payload, found none, and
# allowed a direct overwrite of the protected audit log. As verbs they block whenever a
# marker is also an operand, which is exactly the condition that matters here — and they
# are deliberately NOT in cmdword.py _MOD_VERBS, where there is no marker requirement and
# `time npm test` would become a false positive.
_INDIRECT_CMDS = ("touch", "cp", "mv", "ln", "install", "truncate", "unlink",
                  "rmdir", "dd", "time", "script", "flock")
# Interpreter operands naming a DESCRIPTOR rather than a file on disk: `-` (the
# documented stdin spelling) and the /dev and /proc descriptor directories. Matched as
# a family, not as a list of spellings -- a list covered descriptor 0 only, and
# `exec 3<helper.py; python3 /dev/fd/3` reads the same program through descriptor 3.
# What any of them carries is decided elsewhere in the command, so none can be resolved
# by looking at the operand.
# Leading slashes are `/+` because POSIX keeps exactly two of them meaningful, so
# normpath("//dev/fd/0") stays "//dev/fd/0" while opening the same descriptor.
# The /proc arm matches any process directory (`self`, `thread-self`, a pid, a
# task path), because listing the ones that exist is the enumeration this file keeps
# losing: `self` and a pid were listed, and `thread-self` reached the same descriptor.
_FD_SCRIPT_RE = re.compile(
    r"^(?:-|/+dev/stdin|/+dev/fd/[0-9]+"
    r"|/+proc/[^/]+/(?:task/[^/]+/)?fd/[0-9]+)$")
# A token this scanner cannot resolve to a filename: the shell rewrites it before the
# interpreter sees it. Variable and command substitution (`FD=/dev/fd/0; python3
# "$FD"`) and PATHNAME EXPANSION (`/dev/f?/0`) both land on a descriptor at run time
# while reading here as an ordinary path.
_UNRESOLVED_OPERAND_RE = re.compile(r"[$`*?\[]")
# The same question asked of a COMMAND WORD rather than a filename operand, so brace
# expansion joins the set: `| /bin/{ba,z}sh` resolves to a shell the text never spells.
# KEEP IN STEP WITH cmdword._UNRESOLVED_CW_CHARS.
# An EXTGLOB group, resolved to the text it wraps: shlex splits `/bin/ba+(s)h` into five
# tokens so the command word reads as `ba+`, while bash expands it to `/bin/bash`.
# `!( )` is excluded and cannot be included -- it matches everything EXCEPT its
# contents, so resolving it to the inner text yields the one harmless-looking spelling.
# A negation is unresolvable, and unresolvable fails CLOSED.
# KEEP IN STEP WITH cmdword._EXTGLOB_RE / _EXTGLOB_NEG_RE.
_EXTGLOB_RE = re.compile(r"[+@*?]\(([^()]*)\)")
# Unresolvable: a NEGATION, or an ALTERNATION. `!(x)` matches all but its contents and
# `@(s|z)` names two things, so resolving either to its inner text picks one spelling --
# for `ba@(s|z)h` the harmless-looking one. KEEP IN STEP WITH cmdword._EXTGLOB_NEG_RE.
# The BODY of a command substitution, either spelling. A substitution is executed by
# definition, so an unresolved command word inside one is an unresolved command word.
# KEEP IN STEP WITH cmdword._SUBST_BODY_RE.
_SUBST_BODY_RE = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
_EXTGLOB_NEG_RE = re.compile(r"!\([^()]*\)|[+@*?!]\([^()]*\|[^()]*\)")
# `~` is here because a tilde can produce the RECEIVER, not just a payload:
# `HOME=/bin/bash bash -c '~ <<< "<helper>"'` runs the helper -- verified by running it --
# while the receiver predicate saw the literal word `~` and no disjunct matched. The
# payload-side handling added earlier does not reach this, because it is only consulted
# once a receiver has been recognised. An unresolved command word already fails closed
# here (that is what catches `/bin/ba{s..s}h`), so the fix is to admit that a tilde makes
# one unresolved. KEEP IN STEP WITH cmdword._UNRESOLVED_CW_CHARS.
_UNRESOLVED_CW_RE = re.compile(r"[$`*?\[{(~]")  # `(` is extglob: ba+(s)h expands to bash
# A SECOND way to cut the text into candidate words for the structureless glob probe in
# _abandoned_scan_probe -- the operator characters the shell separates on before it globs,
# because a whitespace-only split left `lease_slo?.py;` as the pattern and matched the
# helper nowhere (#640). It is asked ALONGSIDE the whitespace split, never instead of it:
# an operator character is legal INSIDE a bracket expression, so this cuts `lease_slo[;t].py`
# in half and on its own would have traded one bypass for another (raised by codex on #640).
# Neither split is a tokenizer or claims to be; the union only ever yields more candidate
# patterns to test, so it can add a block and never remove one.
_OPERATOR_SPLIT_RE = re.compile(r"[\s;&|()<>]+")
# A module operand spelled as a plain importable name. Anything else -- an escape, a
# brace, a leftover expansion -- is a name the shell will rewrite, and the operand this
# walk sees has already lost some of that syntax, so testing for the UNRESOLVED
# characters alone missed `-m lease_\x73lot` once the `$` had been stripped.
_PLAIN_MODULE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
# PROCESS SUBSTITUTION hands its reader a generated descriptor, so `python3 <(cat
# .../lease_slot.py)` runs the helper through /dev/fd/N. The segment splitter dismantles
# `<(...)` before the interpreter-operand walk can see it, so this pairing is decided on
# the raw text instead. The interpreter test keeps an ordinary read out of it: `diff
# <(cat .../lease_slot.py) old.py` compares the file, it does not execute it.
_PROC_SUBST_RE = re.compile(r"[<>]\(")
_INTERP_RE = re.compile(r"(?:^|[\s;&|(])(?:python[0-9.]*|(?:ba|da|k|mk|z|a)?sh)\b")
# rm and tee are included HERE even though the scan above matches them by basename:
# when a wrapper embeds the whole program in one token (env -S "rm -f <log>"), basename
# equality never sees the verb, so the embedded form needs them too.
# MUST cover every name in _INDIRECT_CMDS. time/script/flock were listed there and
# omitted here, so the one shape this regex exists for -- the whole program inside a
# single token -- let `env -S "script <log>"` through both checks.
_INDIRECT_VERBS_RE = (r"(?:touch|cp|mv|ln|install|truncate|unlink|rmdir|dd|rm|tee"
                      r"|time|script|flock)")
# `=` is a separator too: env accepts the long form --split-string=<program>, which puts
# the verb immediately after the equals sign rather than after whitespace.
_INDIRECT_EMBEDDED = re.compile(r"(?:^|[\s;&|/=])" + _INDIRECT_VERBS_RE + r"(?:\s|$)")
# The ATTACHED spelling of env -S glues the program to the flag letters, so the token
# reads as -Stouch <marker> and the verb is preceded by a letter rather than whitespace.
# Non-greedy so the flag cluster is consumed but the verb is not -- a greedy strip eats
# the verb along with the flag and matches nothing.
_INDIRECT_ATTACHED = re.compile(r"^-[A-Za-z]*?" + _INDIRECT_VERBS_RE + r"(?:\s|$)")


def _dequote(w):
    return w.replace(chr(34), "").replace(chr(39), "")


# What may FOLLOW a `$` and still be an expansion: a name character, or one of bash's
# special parameters (`$?`, `$@`, `$*`, `$#`, `$!`, `$$`, `$-`, `$0`-`$9`). A lone trailing
# `$` is literal text, so a following character is required.
_PARAM_START = frozenset("abcdefghijklmnopqrstuvwxyz"
                         "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                         "0123456789_?@*#!$-")


def _reserved_word(w, raw=None):
    # Is this word shell GRAMMAR? Bash recognises a reserved word before quote removal and
    # matches it EXACTLY, so `'fi'`, `f\i` and `./fi` are ordinary external commands that
    # merely spell one -- the redirection behind them attaches to that command, not to a
    # compound. Deciding this on the basename of the DECODED word called all three syntax.
    #
    # With no raw spelling to judge (callers that never captured one), the wider basename
    # reading is kept: absent the information, this module over-blocks rather than guess.
    if raw is None:
        return _bn(w) in _RESERVED_SH
    return w in _RESERVED_SH and not any(c in raw for c in ("'", chr(34), "\\"))


def _bare_assign(raw):
    # Bash reads a word as an assignment only when the name AND the `=` are unquoted, so
    # `FOO"="bar` and `"FOO"=bar` are command words naming a program called `FOO=bar`,
    # while `FOO=b"a"r` is still an assignment -- the value may be quoted freely. Judge on
    # the raw text up to and including the first `=`; with nothing to judge, stay wide.
    if raw is None or "=" not in raw:
        return True
    return not any(c in raw[:raw.index("=") + 1] for c in ("'", chr(34), "\\"))


def _skippable(w, raw=None):
    # A leading assignment, a flag, a bare numeric wrapper operand (timeout 5 ...), or the
    # separated `$IFS` token.
    #
    # THE `$IFS` CASE IS THE PRICE OF SEPARATING IT. `_quote_aware_rewrites` stops erasing
    # that expansion so the evidence survives for the payload tests, but separating it
    # injects a real TOKEN, and a token in front of a command word takes its place:
    # `${IFS}touch .claude/skip-litmus.local` normalized to ` $IFS touch ...`, the peels
    # returned `$IFS` as the command word, and the marker-write verb behind it was never
    # seen -- `touch` alone blocks, that spelling returned OK. Found by the PR security
    # backstop, not by the lead.
    #
    # Stepping over it here restores every command-position caller at once (`_peel_wrappers`,
    # `_first_word`, `_starts_with_wrapper`) while leaving the token in the text, which is
    # what the payload tests read. Exact match: normalization emits this one spelling, and
    # `_inner_expands` scans raw text for the `$` rather than matching tokens, so nothing
    # downstream loses the expansion by our stepping over it.
    if w == chr(36) + "IFS" and (raw is None
                                 or not any(c in raw for c in ("'", chr(34), "\\"))):
        # BARE where the caller has the spelling, by the same rule as everything else here:
        # normalization only ever separates an UNQUOTED occurrence, so a quoted token was
        # written that way and is an ordinary command whose NAME happens to be those
        # characters, with whatever follows it as ARGUMENTS.
        #
        # RESIDUAL, an OVER-block, measured and accepted. The marker scanner calls the peel
        # WITHOUT raws -- its tokenizer erased the quoting long before -- so there `raw is
        # None` and the quoted spellings are skipped too: a command literally NAMED with
        # those characters, carrying a marker write as its argument, is refused although it
        # runs no verb. Raised in review. The alternative is threading raw spellings through
        # that scanner's tokenizer, a different subsystem from #643, and it would risk the
        # fail-open this skip exists to close. With no spelling to judge, skipping is the
        # fail-CLOSED answer, which is the direction this module always takes.
        return True
    if _ASSIGN_RE.match(w) is not None:
        return _bare_assign(raw)
    return (w.startswith("-")
            or re.match(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$", w) is not None)


def _peel_wrappers(words, raws=None):
    # First word that actually EXECUTES: skip leading assignments, flags, bare numeric
    # wrapper operands, and wrapper commands themselves. Returns None when nothing
    # survives, so the caller falls back to its raw first word.
    #
    # `raws` is the as-written spelling of each word, and it is what makes the grammar
    # skips agree with bash. Without it, a caller that had carefully checked `'then'` was
    # BARE before stepping over it handed the quote-squeezed words here, where the skip ran
    # again on the basename and stepped over it anyway -- so `'then' . /dev/stdin <<< P`
    # and `FOO"="bar . /dev/stdin <<< P` promoted a `.` that sources nothing and were
    # refused. Wrapper COMMANDS stay basename-matched on purpose: `'env' sh` really does
    # exec a shell, because quoting changes a word's grammar, not what a program does.
    for _i, w in enumerate(words):
        _r = None if raws is None else raws[_i]
        if _skippable(w, _r) or _bn(w) in _WRAPPER_CMDS or _reserved_word(w, _r):
            continue
        if _bn(w) in _TEST_OPEN_SH:
            return None
        return w
    return None


def _strip_time_prefix(words, raws=None):
    """Peel a leading bare `time [-p]` keyword, for callers asking only what a stage
    ACTUALLY RUNS.

    `time` is a bash RESERVED WORD prefixing a pipeline without changing what executes --
    `time source /dev/stdin` still runs `source`, and `_peel_wrappers` did not see past it
    because `time` returned unpeeled: `A write piped through time source /dev/stdin can
    bypass the producer scan` (cubic, #562), verified -- the command-position `.`/`source`
    test below asked of the unpeeled word "time", never reaching "source".

    NOT folded into `_WRAPPER_CMDS`/`_RESERVED_SH` themselves: `_peel_wrappers` is also
    the walk that finds `time`'s OWN command word for the audit-log-overwrite check
    (`_INDIRECT_CMDS` treats `time -o <log> true` as a VERB precisely because `time` can
    write a file itself -- see the comment above `_INDIRECT_CMDS`), and skipping `time`
    there would hide that write. This peel is scoped to the stdin-producer callers that do
    not share that concern.

    NOT index 0 only. A compound stage keeps its introducer, and `_peel_wrappers` skips
    `_RESERVED_SH` on its way in -- so `{ time source /dev/stdin; }` left the peel looking
    at `{`, finding no `time`, and the peel it was supposed to perform never happened:
    `_peel_wrappers` then skipped `{`, stopped at `time`, and the command-position test
    asked of `time` instead of `source`. A fail-OPEN, and the introducer set is large
    (`{`, `if`, `while`, `until`, ...). Walk the same leading tokens `_peel_wrappers`
    does, and remove `time` wherever it actually sits.

    No cmdword twin: `time` is already a member of `cmdword._RESERVED`, which its
    `_effective_command_word` skips, so the sibling resolves `time source /dev/stdin` to
    `source` without a peel. The asymmetry is the audit-log concern above, not an
    oversight -- do not "restore" a peel there.

    EXACT `time`, not its basename: `/usr/bin/time` is a PROGRAM, not the keyword, and it
    cannot run the `source` builtin at all -- peeling it read a harmless producer as a
    receiver. And peeled in a LOOP: bash accepts `time time source /dev/stdin`, where
    removing one keyword just promotes the next to command word.

    RESIDUAL, an OVER-block: `'time' source /dev/stdin` and `\\time source /dev/stdin`
    quote the word, which makes it the external program rather than the keyword -- but
    shlex has already erased the quoting by the time these tokens arrive, so both peel and
    read as receivers. Telling them apart needs raw-token quoting metadata threaded
    through the lexer, for a pair of commands that are INERT either way (the external
    `time` cannot run the `source` builtin). Fail-CLOSED on an inert spelling is the cheap
    side of that trade, and it is the same answer `/usr/bin/time source` already gets.
    """
    rest, i = list(words), 0
    # SOURCE INDEX of every surviving token, deleted in lockstep with `rest` so a caller
    # holding the parallel raw spellings can follow the same peel. Without it those raws
    # had to be dropped past this point, which silently restored the decoded-basename
    # grammar rules inside `_peel_wrappers`: `time 'then' . /dev/stdin <<< P` read the
    # quoted external `then` as syntax again, promoted the `.` behind it, and refused an
    # ordinary read -- the exact over-block the exact/bare rules exist to stop.
    keep = list(range(len(rest)))
    seen_assign = False

    def _bare_at(k):
        # Same rule as `_cmd_position`'s `_bare`, applied where the peel actually happens.
        # Carrying the spellings this far and then matching `time` on the DECODED word left
        # the peel recognising a keyword bash never saw: verified against real bash,
        # `FOO=bar 'time' echo HI` runs the EXTERNAL time (it prints the /usr/bin/time
        # format), and `time '-p' echo HI` answers `-p: command not found`, so the quoted
        # option is a command word too. With no spellings to judge, every word reads as
        # bare, which is the behaviour the one-argument callers already had.
        if raws is None:
            return True
        return not any(c in raws[keep[k]] for c in ("'", chr(34), "\\"))
    # ONE walk, not "reserved words, then times": bash allows an introducer BETWEEN timed
    # pipelines (`time ! time source ...`, `time { time source ...; }`), so two sequential
    # loops peel the first keyword and leave the second as the command word.
    #
    # LEADING REDIRECTIONS are dropped on the way, which fixes more than `time`:
    # `_peel_wrappers` does not step over them, so `2>/dev/null source /dev/stdin` resolved
    # to `>` and read as harmless -- with or without a `time` in front. cmdword's
    # `_effective_command_word` has always skipped them (`_REDIR_RE`), so this is the twin
    # catching up rather than a new rule. Same bare-vs-attached operand rule as
    # `_starts_with_wrapper`: a bare operator takes the FOLLOWING token as its target.
    while i < len(rest):
        # AN ASSIGNMENT ENDS KEYWORD RECOGNITION. `time` is reserved only in
        # pipeline-prefix position; once an assignment word has been walked past, bash is
        # parsing a SIMPLE COMMAND and the next word is its NAME. Measured, not reasoned:
        # `time echo HI` prints the keyword's `real 0m0.000s`, `FOO=bar time echo HI`
        # prints /usr/bin/time's `0.00 real 0.00 user 0.00 sys`, and
        # `time FOO=bar time echo HI` prints BOTH -- outer keyword, inner program. Peeling
        # the second one promoted the `.` behind it and refused an ordinary read.
        # Reserved INTRODUCERS are different and still allowed to precede it: `{` or `then`
        # opens a new command, which is why `{ time source /dev/stdin; }` must still peel.
        if rest[i] == "time" and _bare_at(i) and not seen_assign:
            del rest[i], keep[i]
            if i < len(rest) and rest[i] == "-p" and _bare_at(i):
                del rest[i], keep[i]
            continue
        m = _REDIR_PREFIX_RE.match(rest[i])
        if m:
            attached = m.group(0) != rest[i]
            del rest[i], keep[i]
            if not attached and i < len(rest):
                del rest[i], keep[i]
            continue
        if _ASSIGN_RE.match(rest[i]) is not None:
            seen_assign = True
            i += 1
            continue
        if _skippable(rest[i]) or _bn(rest[i]) in _RESERVED_SH:
            # `_skippable` covers the BARE fd of `2 > /dev/null`, which shlex hands over as
            # its own token -- without it the walk stopped on the `2` and never reached the
            # operator. Same two predicates `_starts_with_wrapper` uses, so both walks agree
            # on what a command PREFIX is. Stepped over, not deleted: they are harmless
            # where they sit, and `_peel_wrappers` skips them again anyway.
            i += 1
            continue
        break
    if raws is None:
        return rest
    return rest, [raws[k] for k in keep]


def _first_word(words):
    # The first word in COMMAND position, ignoring leading assignments/flags/numeric
    # wrapper operands. Reserved words are NOT skipped here: callers that care about a
    # specific keyword (coproc) need to see it exactly where it sits.
    for w in words:
        if _skippable(w):
            continue
        return _bn(w)
    return ""


# A leading redirection, ATTACHED or bare, with an optional leading fd: `<`, `2>`, `>>`,
# `</dev/null`, `2>&1`. KEEP IN STEP WITH cmdword._REDIR_RE.
#
# Needed because the two copies of this scan tokenize DIFFERENTLY. cmdword uses a plain
# shlex, so `</dev/null` survives as ONE token and only this regex can see it. This file
# uses punctuation_chars=True, which splits it into `<` + `/dev/null` -- so here the
# operator is visible to _is_redir but its OPERAND is what lands in command position. Both
# halves have to be handled, and handling only one is what left the guard open twice.
# Every COMPLETE redirection operator, longest-first so `<<<` is not read as `<`. The
# first version matched a single leading `<` only, so a here-string `<<< data` looked
# like an ATTACHED redirect whose own text was `<`, its operand was never skipped, and
# `data` became the command word -- the same regime failure this regex exists to stop.
_REDIR_PREFIX_RE = re.compile(r"^(?:[0-9]+|&)?(?:<<<|<<-?|<>|<&|>>|>\||>&|<|>)")
# Same alternation, UNANCHORED, for finding an operator part-way through a shlex token.
# `_REDIR_PREFIX_RE` is `^`-anchored, and `pattern.match(s, pos)` does not move a `^`.
#
# TWO forms, because the file-descriptor prefix is only a prefix at the START of a word.
# One regex carrying the optional `[0-9]+|&` everywhere ate the last character of a
# command NAME: bash reads `source2<<< P` as the command `source2` redirected by `<<<`,
# while `2<<<` matched as an fd redirection and left `source` in command position, so an
# ordinary read was refused as a `source`. Same for `bash2`, `xargs2`, `/tmp/bash2`.
_REDIR_AT_RE = re.compile(r"(?:[0-9]+|&)?(?:<<<|<<-?|<>|<&|>>|>\||>&|<|>)")
# `&>` and `&>>` are single operators and, unlike a numeric descriptor, they apply MID-WORD
# too: bash ends the word at the `&`, so `sh&>out <<< P` runs `sh` with the here-string as
# its program. Leaving the `&` in the name reconstructed the receiver as `sh&`, which
# matches no shell, and the payload executed while the classifier returned OK.
_REDIR_BARE_RE = re.compile(r"(?:&>>|&>|<<<|<<-?|<>|<&|>>|>\||>&|<|>)")
_BT = chr(96)                       # backtick, spelled out to survive markdown quoting
# Bash's word separators, spelled out. `str.isspace()` is UNICODE-aware and bash is not:
# it treats U+00A0 and friends as ordinary characters, so a no-break space inside a
# here-string operand split the word, promoted its tail to command position, and hid the
# `.` that sourced the payload. Carriage return, form feed and vertical tab are ordinary
# to bash too, and leaving them inside a word keeps the operand grouped -- the direction
# that blocks.
_SH_BLANK = " \t\n"


def _strip_redirs(toks):
    """Drop redirect operators AND the operand each one consumes.

    Filtering on _is_redir alone removed the operator and left the TARGET behind, so
    `</dev/null sudo -u root python3 .../lease_slot.py` reduced to
    `[/dev/null, sudo, ...]`. The basename of `/dev/null` is `null`, which is not a
    wrapper, so the wrapper regime was never selected, the launcher was then peeled to its
    OWN operand, and the interpreter behind it was never located -- the UNCONDITIONAL
    helper guard measured ALLOW for the sudo, script and flock forms alike.

    A leading file descriptor (`2` in `2>&1`) stays, and is already _skippable.
    """
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if _is_redir(t):
            skip = True          # the following token is this redirect TARGET, not a verb
            continue
        out.append(t)
    return out


def _starts_with_wrapper(words):
    # Is the COMMAND-POSITION word a wrapper? Position matters: a wrapper name appearing
    # only as an ARGUMENT to a read (grep sudo <marker>) must not change the decision.
    #
    # A LEADING REDIRECTION has to be stepped over first. `</dev/null` is not pure
    # punctuation, so _is_redir does not strip it and it arrived here as a word whose
    # basename is `null` -- not a wrapper, so this returned False, the conservative
    # all-token regime was never selected, and the launcher preamble was then peeled up to
    # its OWN operand. That allowed the UNCONDITIONAL helper guard to be walked past:
    # `</dev/null script -q /dev/null python3 .../lease_slot.py` and the sudo and flock
    # forms all measured ALLOW. Same defect as cmdword._starts_with_wrapper, and it has to
    # be fixed in BOTH copies -- fixing only the library left this one open, because this
    # is the copy the helper guard consults.
    skip_next = False
    for w in words:
        if skip_next:
            skip_next = False
            continue
        m = _REDIR_PREFIX_RE.match(w)
        if m:
            # A BARE operator takes the FOLLOWING token as its target (`< in.txt cmd`);
            # an attached one (`</dev/null`) carries its own. Without this the target
            # became the command word and the answer was False all the same.
            skip_next = m.group(0) == w
            continue
        if _skippable(w) or _bn(w) in _RESERVED_SH:
            continue
        if _bn(w) in _TEST_OPEN_SH:
            return False
        return _bn(w) in _WRAPPER_CMDS
    return False


def _scan_segment(segtext, markers, simple_vars, flags=None):
    # Tokenize ONE already-separated simple command and decide block/allow.
    # commenters is cleared because the newline->";" normalization (in
    # _writes_marker) leaves a "#" with no terminating newline, so default shlex
    # comment handling would swallow the rest of the line and hide a trailing
    # marker delete. simple_vars is owned by the caller and persists across
    # segments, so an assignment in one segment resolves a $var use in a later one
    # (m=...; rm "$m"); it is updated in order as tokens are walked.
    try:
        lex = shlex.shlex(segtext, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError:
        # Unparseable segment (e.g. unbalanced quote): a segment that does not
        # even mention a marker basename cannot be a forge (allow); otherwise fail
        # CLOSED (block).
        #
        # This is the SECOND could-not-parse path (the first is the ok=False branch
        # in _writes_marker). Both must report the same TRUTH, or the #365 fix only
        # half-lands: a hit here would still assert "you tried to write a marker"
        # when all we really know is that the text could not be parsed. Signalled via
        # `flags` rather than the return value because this function has several
        # return sites and only one caller — widening them all would be a bigger,
        # riskier diff than an out-param for a message-only distinction.
        if flags is not None:
            flags["unparseable"] = True
        return next((mf for mf in markers if _bn(mf) in segtext), None)
    seg = []
    seg_words = []   # command-position candidates: redirect operators/targets excluded
    seg_has_cmd = False
    seg_cmd_word = None  # first real command word (redirect ops/targets excluded)
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        # A lone file-descriptor digit binding a redirect (2>/dev/null, 1>&2) is
        # PART of the redirect, not a command word — skip it so it cannot masquerade
        # as the command word (2>/dev/null touch <marker>) (#290 PR review). Safe
        # even when the digit is really an echo arg (echo 2 >f): the command word
        # is already captured, and a digit is never a marker basename.
        if t.isdigit() and i + 1 < n and _is_redir(toks[i + 1]):
            i += 1
            continue
        if _is_redir(t):
            if ">" in t:  # write redirect; next word is its target
                # STEP OVER a separated `$IFS` first. Separating that expansion instead of
                # erasing it (see `_quote_aware_rewrites`) injects a real token, and this
                # branch takes the NEXT token as the redirect target -- so
                # `>${IFS}<marker>` normalized to `> $IFS <marker>`, the target read as
                # `$IFS`, matched no marker, and the marker itself fell through the main
                # loop as an ordinary word with no write verb in front of it. The command
                # forged the marker and classified OK. Bash really does expand here: a
                # redirection word is expanded, so `>$IFS<marker>` writes the marker.
                #
                # The command-position skip in `_skippable` does not reach this: a redirect
                # target is deliberately NOT a command word, so it never goes through the
                # peels. Found by the PR security backstop, which also noted the gap was
                # invisible because the new fixtures covered only command position.
                _j = i + 1
                while _j < n and toks[_j] == chr(36) + "IFS":
                    _j += 1
                if _j < n and not _is_redir(toks[_j]):
                    nxt = toks[_j]
                    m = _match_marker(nxt, markers, simple_vars)
                    if m:
                        return m
                    # A redirect target is NOT a command word: leave seg_has_cmd
                    # unset so a bare name=value in a redirect-only simple command
                    # (> /dev/null m=.../marker) is still recorded as an assignment
                    # and a later rm "$m" resolves to the marker.
                    seg.append(nxt)
                    i = _j + 1
                    continue
                i = _j
                continue
            # "<" read redirect; skip operator AND its source (a read, not a write)
            i += 2 if (i + 1 < n and not _is_redir(toks[i + 1])) else 1
            continue
        # Leading name=value tokens (before the command word) are real shell
        # assignments; once a non-assignment word appears, later name=value tokens
        # are arguments, not assignments. Both NAME=VALUE and bash/zsh NAME+=VALUE
        # (append) are tracked — kept consistent with the +=-aware command-word skip
        # below. Otherwise `M+=.claude/skip-litmus.local ; touch "$M"` would leave M
        # unrecorded and the indirect marker write would slip through (#290 PR review).
        assign_m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$", t, re.DOTALL) if not seg_has_cmd else None
        if assign_m:
            name, plus, val = assign_m.group(1), assign_m.group(2), assign_m.group(3)
            simple_vars[name] = (simple_vars.get(name, "") + val) if plus else val
        else:
            # First non-assignment word to reach here is the command word. Redirect
            # operators AND their targets never reach this branch (handled+continued
            # above), so a leading redirect (>/dev/null touch <marker>) cannot masquerade
            # as the command word (#290 PR review — cursor/codex/devin).
            if not seg_has_cmd:
                seg_cmd_word = t
            seg_has_cmd = True
        seg.append(t)
        seg_words.append(t)
        i += 1
    # A bare rm/tee co-occurring with a marker operand in THIS simple command is a
    # delete / tee-write of the marker. Scanning ALL words (not a pinned command
    # position) means wrapper preambles (sudo/env/nohup/timeout, with flags or
    # leading assignments) cannot hide the rm/tee.
    if any(_bn(w) in ("rm", "tee") for w in seg):
        for w in seg:
            m = _match_marker(w, markers, simple_vars)
            if m:
                return m
    # #290 indirect-write verbs (touch/cp/mv/ln/install) that FORGE the skip/marker
    # file. Unlike rm/tee, these are matched ONLY in COMMAND-WORD position (the
    # first token after any leading name=value assignments), NOT scanned across all
    # words — otherwise a marker READ whose args merely contain one of these words
    # (grep touch <marker>, cat <marker> | grep cp) would be misread as a write.
    # This closes the realistic self-bypass — a bare `touch .claude/skip-litmus.local`,
    # incl. `touch -t` backdating that also defeats the pre-commit 30s age heuristic
    # — while a wrapper-hidden `sudo touch <marker>` and the eval class stay in the
    # ADR 0006 residual (a cooperative agent uses none of those to skip its own gate).
    # seg_cmd_word is captured in the token loop, so leading assignments (NAME=/NAME+=)
    # AND leading redirects (>/dev/null touch <marker>) are already excluded — a naive
    # first-non-assignment scan of seg would mis-pick the redirect target as the verb.
    # Peel wrapper preambles before deciding the verb. Matching the RAW first word let
    # `command rmdir <slot>` and `env truncate <log>` slip past this check, while the
    # wrapper-aware classifier downstream still called them modifications — and the F9
    # state-directory exemption then allowed them. A spent lease slot could therefore be
    # removed and reclaimed without bound, and the protected audit log destroyed.
    # #519: the indirect-write verbs. touch/cp/mv/ln/install come from #290 (the
    # realistic threat is a cooperative agent taking the easy path); truncate/unlink/
    # rmdir/dd were added once the lease ledger and bypass-log.jsonl became gate state,
    # since rmdir on a spent slot resets the 20-use ceiling and truncate/dd erase the
    # audit trail. A residual that is the EASIEST path is not a residual.
    # ── Does this simple command RUN an indirect-write verb? ──────────────────
    # One conservative rule rather than a patch per shape. Chasing each variant found a
    # new one every round (coproc with an optional NAME, sudo before find, a verb
    # embedded in an -exec payload), which is the segment-split arms race this file
    # already warns about.
    #
    # CONSERVATIVE regime when the command executes something it does not name directly:
    # a wrapper in command position, a coproc or function DEFINITION in command position
    # (coproc takes an optional NAME, and a function body executes when the name is later
    # called -- `function f { touch <marker>; }; f`), or find (which runs its own
    # commands). All three are anchored on POSITION -- an any-occurrence test blocked
    # `echo coproc touch <marker>` and `echo find -delete <marker>`, where the marker is
    # only data, breaking the read/mention contract this check exists to preserve.
    # There, EVERY word is checked -- by basename equality, by embedded-verb regex on the
    # dequoted word, and for the -delete action. That cannot fail open; it only
    # over-blocks a wrapped read, which is the right direction for a marker guard.
    #
    # RESIDUAL, deliberately NOT chased: a verb assembled at RUNTIME rather than written
    # literally -- `V=truncate env -S "${V} -s 0 <log>"`, globs, brace expansion. That is
    # the ADR 0006 execute-a-string/computed-name class: the value exists only in the
    # executing shell, so no static scan can see it, and anything able to do it can also
    # `python3 -c` the write directly. Blocking a subset is theater against that actor.
    # The literal spellings above are closed because they are ONE TOKEN away from an
    # ordinary command; this one is not.
    #
    # STRICT regime otherwise: the command word alone decides, so a verb appearing only
    # as an ARGUMENT to a read (grep touch <marker>, echo find -delete <marker>) stays
    # allowed. That read-only contract is the whole point of the position check.
    _INDIRECT = _INDIRECT_CMDS
    _peeled = _peel_wrappers(seg_words)
    # Tested on the PEELED word as well as the first: a reserved word can sit in front
    # of the definition (`if true; then function f { touch <marker>; }; f; fi`), and
    # _first_word then reports `then`, which is neither a wrapper nor a definition.
    # _peel_wrappers already skips reserved words, so it reaches the real introducer.
    _conservative = (_starts_with_wrapper(seg_words)
                     or _first_word(seg_words) in ("coproc", "function")
                     or _bn(_peeled or "") in ("coproc", "function", "find"))
    if _conservative:
        verb_present = (any(_bn(w) in _INDIRECT for w in seg_words)
                        or any(_INDIRECT_EMBEDDED.search(_dequote(w))
                               or _INDIRECT_ATTACHED.match(_dequote(w))
                               for w in seg_words)
                        or any(w == "-delete" for w in seg_words))
    else:
        cmd_word = _peeled if _peeled is not None else seg_cmd_word
        verb_present = cmd_word is not None and _bn(cmd_word) in _INDIRECT
    if verb_present:
        for w in seg:
            m = _match_marker(w, markers, simple_vars)
            if m:
                return m
    return None


def _defuse_comments(s):
    # Blank the SEPARATOR characters inside shell comments, quote-aware, leaving every other
    # byte -- and the newlines that end the comments -- in place. A comment runs from an
    # unquoted `#` in word position to the end of its LINE and can contain `;`, so a comment
    # reaching the splitter intact turns `printf <payload> | #  ; ignored` + newline + `bash`
    # into a comment segment plus a bare `ignored` that reads as a real command and ends the
    # pipeline one stage before its shell.
    #
    # DEFUSING rather than DELETING: deleting was tried and moved 14 real commands from block
    # to ALLOW, because a comment holding an apostrophe had been making the whole command
    # unparseable, which is the fail-CLOSED path. Blanking in place keeps every byte.
    # QUOTES are blanked too: bash ignores quoting inside a comment, so leaving them
    # let a comment change the quote state of everything after it -- two balanced ones
    # wrap a write in apparent quotes, one unbalanced one hid a redirect write.
    # KEEP IN STEP WITH cmdword._defuse_comments.
    # WORD POSITION as explicit state, not read back off the previous output character:
    # that character does not say whether it was escaped or quoted, and two spellings turn
    # on exactly that. `)` can close a substitution INSIDE the current word, so
    # `echo $(true)#x` is one word; an ESCAPED space is an ordinary character, so
    # `echo foo\ #notcomment` is one word too. Both read as comments and blanked the real
    # separator that followed. `(` does open word position.
    out, in_s, in_d, esc = [], False, False, False
    word = True
    group = []          # one bit per open paren: subshell (delimits) or substitution
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if esc:
            out.append(ch); esc = False; word = False
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
            out.append(ch); esc = True; word = False
        elif ch == _SQ:
            out.append(ch); in_s = True; word = False
        elif ch == _DQ:
            out.append(ch); in_d = True; word = False
        elif ch == "#" and out and out[-1] == ")":
            # AMBIGUOUS and deliberately not guessed at: whether this `)` delimited a command
            # depends on what its `(` opened, and bash has four answers -- a SUBSHELL and a
            # case PATTERN delimit, a SUBSTITUTION and a FUNCTION HEADER do not. Three review
            # rounds each closed one spelling and opened another. Left exactly as it stands
            # and flagged, so the caller falls back to the unconditional probe.
            # KEEP IN STEP WITH cmdword._defuse_comments.
            _paren_hash_ambiguous[0] = True
            out.append(ch)
            word = False
        elif ch == "#" and word:
            while i < n and s[i] != "\n":
                out.append(" " if s[i] in ";&|()" + _SQ + _DQ else s[i])
                i += 1
            continue
        elif ch == "(":
            out.append(ch)
            # WHICH kind of paren: a bare `(` in word position opens a SUBSHELL whose `)`
            # ends a command, so `(true)# x` is a comment; a `$(` opens a SUBSTITUTION whose
            # `)` sits mid-word, so `echo $(true)#x` is not. Both were fail-opens in
            # successive rounds. KEEP IN STEP WITH cmdword._defuse_comments.
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


# Named, because two places must agree on it: `_quote_aware_rewrites` SEPARATES this
# expansion -- surrounding it with spaces rather than erasing it -- and anything asking
# "was something unresolvable here" has to find it still standing. An earlier version did
# erase it, and the evidence went with it. A second literal copy is how the two would
# drift apart again.
_IFS_RE = re.compile(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])")


def _quote_aware_rewrites(text):
    # Two rewrites that must both respect quoting, done in ONE pass because they need the
    # same state and a second scanner is a second place to get it wrong.
    #
    # 1. Drop the `$` of `$'...'` and `$"..."`, but ONLY where that `$` is not itself
    #    quoted.
    # A blind `.replace("$'", "'")` also ate the dollar out of `'$'P`, which is three
    # characters the shell CONCATENATES into the word `$P` -- so a payload the inner shell
    # would expand arrived here with no `$` left to notice, and
    # `export P='<helper>'; sh <<< '$'P` classified OK.
    #
    #    Fixed here rather than by flagging the pattern command-wide, which is the shape
    #    that had just been taken out for `$IFS`: one occurrence anywhere would again make
    #    every transport in the command unresolvable and over-block unrelated reads.
    #
    #    The `$"` form is RECORDED as it is dropped, because it is locale translation and
    #    its result is not statically known -- a payload of `$"harmless"` would otherwise
    #    look perfectly resolvable and not widen. It cannot simply be left in place: the
    #    command word `$"bash"` then resolves to `$bash` instead of `bash`, and a real shell
    #    receiver stops being recognised, which is a worse hole than the one being closed.
    #    So the drop stays and `_locale_string` carries the fact instead.
    #
    # 2. SEPARATE `$IFS`/`${IFS}` -- but only where it is live, meaning unquoted and
    #    unescaped. A blind substitution also rewrote a PROTECTED one: `sh <<< 'echo
    #    \$IFS'` became `echo \ $IFS `, which the expansion detector then read as live and
    #    blocked. Inside quotes nothing is separated and nothing needs to be: `"${IFS}"`
    #    does not word-split, so there is no glued token to break apart, and the expansion
    #    is still standing for the detector to see.
    out, i, n = [], 0, len(text)
    in_s = in_d = False
    while i < n:
        c = text[i]
        if not in_s and not in_d and c == chr(36) and i + 1 < n and text[i + 1] in (_SQ, _DQ):
            if text[i + 1] == _DQ:
                _locale_string[0] = True
            i += 1                      # drop the dollar; the quote below opens the string
            continue
        if not in_s and not in_d:
            _m = _IFS_RE.match(text, i)
            if _m:
                out.append(" " + chr(36) + "IFS ")
                i = _m.end()
                continue
        if c == chr(92) and not in_s:
            # A backslash quotes the next character, `$` included, so `\$'x'` is a literal
            # dollar beside an ordinary quoted string -- not an ANSI-C opener.
            out.append(c)
            if i + 1 < n:
                out.append(text[i + 1])
            i += 2
            continue
        if c == _SQ and not in_d:
            in_s = not in_s
        elif c == _DQ and not in_s:
            in_d = not in_d
        out.append(c)
        i += 1
    return "".join(out)


def _norm_for_scan(cmd):
    # Pre-tokenization normalization shared by the marker scan and the helper guard, so
    # the two cannot disagree on what a token is.
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    # Bash removes an unquoted backslash-newline (line continuation) before execution;
    # mirror that BEFORE splitting on newlines so a marker write or basename split
    # across a continuation is rejoined, not broken into pieces.
    norm = norm.replace(chr(92) + chr(10), "")
    # Comments are defused BEFORE the newlines that end them become separators.
    norm = _defuse_comments(norm)
    norm = norm.replace("\n", " ; ")
    # Bash ANSI-C ($...) and locale quoting: shlex does not model the leading $, so
    # strip that prefix and let the quote tokenize to the literal path. (Escape
    # SEQUENCES such as \x6c remain undecodable by shlex and stay out of scope per the
    # residual note above.)
    norm = _quote_aware_rewrites(norm)
    # ${IFS}/$IFS expand to whitespace -- a classic field-splitting obfuscation
    # (rm${IFS}<marker>); normalize to a separator so the command word and redirect
    # operands are recognized rather than glued into one token.
    # `$IFS` is SEPARATED rather than erased, and quote-awarely -- both done in the pass
    # above. Erasing it destroyed the evidence that anything unresolvable had been there,
    # so a payload of `"$IFS"` looked like a payload of `" "`.
    return norm


_MUTATING_HELPERS = ("lease_slot.py", "audit_append.py")

# Bound the WIDTH of the helper scan. KEEP IN STEP WITH cmdword._MAX_SCAN_TOKENS, which
# carries the full reasoning. The short version: the -c scan is O(tokens^2) because it
# refuses the per-flag arity table, and this hook is registered with a 5s timeout that on
# expiry kills it with NO decision on stdout -- which the harness reads as allow. Measured
# before this bound existed, 128KB of padding cost 34s here. Tokens rather than bytes, so
# a legitimately long single-token payload is untouched. Charged cumulatively across every
# segment and recursion level.
#
# Exhaustion fails CLOSED, via _HELPER_UNSCANNED. An earlier version degraded to the
# substring probe instead, arguing that any command big enough to exhaust this budget also
# exhausts the cmdword budget, where exhaustion blocks. That argument does not hold, and
# the gap it left was measured: this guard is UNCONDITIONAL, while the cmdword budget only
# decides is_file_mod, which blocks solely WHILE a design review is pending. With nothing
# pending the two do not overlap, so 4001 filler flags followed by `-m lease_slot` was
# ALLOWED. A scan that was abandoned has not found "no helper" -- it has found nothing at
# all, and nothing at all is the fail-CLOSED case.
_HELPER_MAX_TOKENS = 4000
_helper_budget = [0]
# Set by _defuse_comments on a `)#`, whose meaning it refuses to guess. Read by
# _helper_invoked, which answers it by fail-CLOSED probe.
_paren_hash_ambiguous = [False]
# Did this command contain a LOCALE string? `$"..."` is gettext translation, so its result
# is not statically known -- and the `$` is dropped during normalization (see
# `_quote_aware_rewrites`), which leaves the segment looking perfectly resolvable. Recorded
# per command rather than per segment because the evidence is gone by the time segments
# exist, and command-wide is affordable HERE where it was not for `$IFS`: an unrelated
# `$IFS` is common enough that a command-wide flag demonstrably over-blocked a real read,
# whereas a benign command carrying `$"..."` AND naming a mutating helper AND feeding a
# shell on stdin is not a shape that occurs.
_locale_string = [False]
# Total BYTES of watch suffix candidates materialized per scan. The cost of that
# expansion is copying, not token count, so it is bounded in the unit it actually spends.
# Exceeding it forces _helper_budget negative, which fails CLOSED -- see _exec_payloads.
_WATCH_MAX_PAYLOAD_BYTES = 1 << 20
# The same helpers as MODULE names. `python3 -m lease_slot` runs the file without
# ever naming it, and `-m` was on the list of flags whose operand gets skipped.
_MUTATING_MODULES = tuple(h[:-3] for h in _MUTATING_HELPERS)

# Modules that CONSUME a following path as data rather than executing it, keyed by the
# first dotted component. Deliberately an allowlist and deliberately short: the inverse
# list (modules that RUN their argument -- cProfile, profile, pdb, trace, timeit, runpy,
# ...) fails OPEN on the one nobody enumerated, and stdlib gains modules. Anything absent
# here is assumed to execute what follows, so an unlisted read-only module costs a false
# block, not a bypass. Add to this list when one shows up; never add to its inverse.
_READONLY_MODULES = frozenset((
    "json",        # json.tool pretty-prints its operand
    "tokenize", "ast", "dis", "pydoc", "pyclbr", "inspect",
    "py_compile", "compileall",   # compile to bytecode; they do not run module level
    "base64", "gzip", "zipfile", "tarfile", "hashlib", "mimetypes",
))

# Isolated-mode flags. `-I` implies `-P` and `-E`; `-P` alone is enough for the question
# asked below, since it is the one that drops the CWD from sys.path.
_ISOLATED_RE = re.compile(r"^-[A-Za-z]*[IP]")


def _readonly_module_trusted(mod, words):
    """Is the READ-ONLY reputation of this -m module actually trustworthy here?

    The name alone is not evidence. For -m, CPython puts the CURRENT DIRECTORY on
    sys.path, and this gate runs with its CWD inside the repository it is gating -- so a
    repo-root `json/` package shadows the stdlib and `python3 -m json.tool <helper>`
    executes whatever the repo says json.tool is. PYTHONPATH does the same from the
    environment. Trusting the spelling is the exact shape ADR 0016 / #325 rejected:
    consent authenticated by content that the gated party controls.

    So the allowlist counts only when the interpreter runs ISOLATED, which is what
    actually removes the CWD -- and, for -I, the environment -- from the module search
    path. A bare `python3 -m json.tool <helper>` is now treated as unknown and scanned,
    which costs a false block on a genuine read. That is recoverable through the skip
    lease; the alternative is not.
    """
    if _bn(mod).split(".")[0] not in _READONLY_MODULES:
        return False
    return any(_ISOLATED_RE.match(t) for t in words)

# Sentinel for a scan that was ABANDONED rather than completed. Not a helper name: it
# means the walk ran out of budget or the command was too large to walk, so this file
# cannot say whether a helper runs. The caller blocks on it, through its OWN action so
# the operator gets an accurate message instead of being told to stop calling a script
# named after a sentinel. Plain ASCII with no pipe: it crosses into shell through a
# pipe-delimited line, and a NUL would be dropped or truncate the field.
_HELPER_UNSCANNED = "UNSCANNABLE"


def _helper_substring(text):
    """Cheap probe: does `text` NAME a mutating helper anywhere, file OR module spelling?

    Every fallback in this file that abandons the structured walk lands here, so the
    MODULE spelling has to be covered: `python3 -m lease_slot` never writes the string
    `lease_slot.py`, so probing the FILE names alone read a real invocation as absent.
    That is the gap a padded command walked through once the token budget cut the walk
    short -- measured ALLOW with nothing pending, against an UNCONDITIONAL guard.

    The module stems subsume the file names (`lease_slot` is a substring of
    `lease_slot.py`), so one pass over the stems answers both spellings.
    """
    return next((m + ".py" for m in _MUTATING_MODULES if m in text), None)


def _module_helper(mod):
    """The helper FILE this `-m` module operand runs, or None. Dotted paths resolve to
    their last component, since `-m gate.lib.audit_append` runs the same file."""
    if not mod:
        return None
    stem = _bn(mod).split(".")[-1]
    return stem + ".py" if stem in _MUTATING_MODULES else None


def _glob_helper(word):
    """The helper FILE a GLOB operand can expand to, or None.

    The shell resolves `lease_slo?.py` against the filesystem, so the question is not
    whether the literal spelling names a helper -- it never does -- but whether the
    PATTERN can. Asking that directly beats searching the command text for a helper
    stem, which a single wildcard in the middle of the name defeats.
    """
    try:
        pat = re.compile(fnmatch.translate(_bn(word)))
    except (re.error, TypeError):
        return _MUTATING_HELPERS[0]      # unparseable pattern: fail closed
    return next((h for h in _MUTATING_HELPERS if pat.match(h)), None)


def _glob_helper_targeted(word):
    """The helper this glob names SPECIFICALLY, or None -- _glob_helper minus the
    patterns that spell nothing at all.

    #573. `**` is a valid fnmatch pattern that matches `lease_slot.py`, and it is also
    what a markdown bold marker collapses to once the quote-flattening above has turned a
    PR body into pseudo-shell. So a `gh pr create` whose description contained `**` was
    refused for "calling lease_slot.py" -- a script the command spells nowhere, named by a
    guard whose only evidence was a wildcard. Two independent operator reports, one of
    them costing a skip-litmus token on the retry.

    The discriminator is the narrowest one that answers the report: a pattern of NOTHING
    BUT `*` matches every string that exists, so it distinguishes the helper from nothing
    and is evidence of nothing. `lease_slo?.py` is a pattern ABOUT the helper -- the
    wildcard stands in for one character of a name the rest of the pattern writes out --
    and stays evidence, as does every other pattern.

    FOUR WIDER DRAFTS WERE BROKEN IN REVIEW, three by codex and one by the backstop, and
    the shape of the failures is why the rule ended up this severe. Each sounded principled
    and each admitted a pattern that still aimed:
      - "does it also match a decoy filename (main.py, README.md)?" `[lm][ea][ai]*.py`
        matches the decoy AND `lease_slot.py`. Any "also matches a KNOWN X" test falls to
        unioning alternatives into the character classes.
      - "does it carry no ALPHANUMERIC character?" `?????_????.??*` carries none, yet `_`
        and `.` are literals at the exact offsets of `lease_slot.py`. `str.isalnum` is the
        wrong question: a literal ANYWHERE disqualifies, and `_`, `.`, `-` are literals
        that happen not to be alphanumeric.
      - the same test applied to `_bn(word)`. `<libdir>/*` has basename `*`, and the
        directory that gets discarded is a literal naming the folder both helpers live in.
      - "nothing but `*` and `?`, with at least one `*`." Each `?` imposes a minimum
        length, so `?????????????*` selects by the length of `lease_slot.py`. Narrower than
        everything is still narrower.
    Every one of those was an attempt to say "this pattern is too vague to count" with a
    rule wider than the vagueness it was licensing. Matching EVERY string is the only
    version of that claim with nothing left over to argue about.

    KNOWN over-block left standing: `*.py`, `*_*` and `*?*` in prose all still block. Only
    the pure `*` run is released. That is the reported shape; every attempt to widen past
    it has bought a bypass.

    SCOPE, and why this is not a general loosening of _glob_helper: this is used by
    _abandoned_scan_probe ONLY. At the structured call sites (the `python3 -` operand and
    the runner-module walk) the word is a resolved command OPERAND, where a bare `*` is a
    real invocation vector -- `python3 *` in the helper directory runs one -- so those keep
    asking _glob_helper directly. Measured, post-change: `cd <libdir> && python3 *`,
    `python3 *.py`, `python3 **`, `python3 ?????????????` and `python3 -m cProfile <lib>/*`
    all still block, because the interpreter is in command position and the walk reaches
    the operand.

    RESIDUAL, accepted and deliberate: a bare `*` run reaching an interpreter where nothing
    can see it as an operand -- `eval "cd <libdir> && python3 *"`, or the same inside a
    heredoc too broken to segment. It selects the helper only by also selecting every
    sibling file of whatever directory it lands in, and it cannot say which directory that
    is: the moment it names one, the path characters are literals and it is not released.
    Singling a helper out therefore needs a mechanism OUTSIDE the token -- a `cd`,
    `GLOBIGNORE`, a pruned directory -- so the residual is "an unparseable command may run a
    bare glob", which is where it already stood. careful-guard declines this trade
    at `_matches_tok` (issue #585), and the two are not the same call: THAT loop reads
    every token as a candidate command WORD, where `/bin/*` really is a command name, while
    this one reads structureless text in which a token is as likely to be prose. Everything
    else is unaffected -- a targeted glob still blocks in both shapes (`eval "python3
    lease_slo?.py"`, and the same inside a broken heredoc), the literal-name probe in
    _names_helper is untouched, and this guard is defence in depth over helpers that are
    safe by construction (#519): lease_slot.py reads the skip-file mtime itself and
    audit_append.py builds its record from fixed fields.
    """
    # The WHOLE word, NOT _bn(word): taking the basename first released `<libdir>/*`,
    # whose discarded directory is a literal naming the folder both helpers live in.
    if word and all(c == "*" for c in word):
        return None
    return _glob_helper(word)


# A function definition, an alias definition, or eval can re-point a command name, so a
# helper sitting in an operand may be what actually runs. See _helper_invoked.
#
# A function NAME is any word free of the metacharacters that would end it: bash accepts
# f-x, f.x and my:fn, none of which an identifier charset matches, and all of which run.
# The keyword branch requires the KEYWORD in command position and a name, NOT a brace --
# a function body is any compound command, so `function f while ...; do ...; done` and
# `function f [[ ... ]]` both define one. Command position is what keeps the branch from
# firing on the ordinary word (grep function file), and it is structural rather than a
# guess about the body. KEEP IN STEP WITH cmdword._FUNC_NAME / _FUNC_DEF_RE /
# _INDIRECTION_RE, which carry the corpus measurements behind this shape.
# Words that OPEN and CLOSE a compound command. A compound command is ONE pipeline stage no
# matter how many separators sit inside it, so an `if`/`for`/`while` receiver runs the piped
# program while its internal separator looked like the end of the pipeline. Braces were only
# the first spelling of that family, not the family. Counted as whole WORDS.
# KEEP IN STEP WITH cmdword._GROUP_OPEN / _GROUP_CLOSE.
_GROUP_OPEN = ("{", "if", "for", "while", "until", "case", "select")
_GROUP_CLOSE = ("}", "fi", "done", "esac")
# Words in command position that are NOT commands. The leading-run walk steps OVER them, or
# a nested opener behind one goes uncounted while its closer still closes.
# ...and the PIPELINE PREFIXES `time`, `time -p` and `!`, which bash allows in front of a
# compound command and which otherwise stopped the walk before its opener.
_GROUP_CONNECT = ("then", "do", "else", "elif", "time", "-p", "!")

# COMMAND POSITION, derived from the compound-command keyword sets rather than hand-listed,
# because a hand-listed subset is how `if function f { bash; }; then ...` slipped: `then`,
# `do` and `else` were listed while `if`, `while`, `until`, `!` and `time` were not. Anything
# that can precede a command WITHOUT being one belongs here, and those sets already enumerate
# it for the depth walk -- so they are the single source. The trailing repetition covers
# stacked prefixes (`time -p function f { ... }`, `! if ...`).
# KEEP IN STEP WITH cmdword._CMD_POS.
_CMD_POS_LEAD = (r"(?:\b(?:"
                 + "|".join(sorted(w for w in set(_GROUP_OPEN) | set(_GROUP_CONNECT)
                                   if w.isalpha()))
                 + r")\b|!|(?<![\w-])-p\b)")
# ONE prefix, not a repeated group: the repetition was redundant (a single preceding prefix
# already establishes command position, and `-p` and `!` are themselves alternatives) and
# CATASTROPHIC -- 4,000 valid `!` prefixes took 5.4s against a 5s hook timeout that fails
# open. KEEP IN STEP WITH cmdword._CMD_POS.
_CMD_POS = r"(?:^|[\n;&|(){}]|" + _CMD_POS_LEAD + r")\s*"
# The `name()` form cannot sit behind a group CLOSER or a pipeline prefix, so it takes
# openers and reserved words only. KEEP IN STEP WITH cmdword._CMD_POS_WORDS.
_CMD_POS_WORDS = (r"\b(?:"
                  + "|".join(sorted(w for w in set(_GROUP_OPEN) | set(_GROUP_CONNECT)
                                    if w.isalpha()))
                  + r")\b")

_FUNC_NAME = r"[^\s;&|()<>{}]+"
_INDIRECTION_RE = re.compile(
    r"(?:^|[\n;&|{()]\s*|" + _CMD_POS_WORDS + r"\s*)" + _FUNC_NAME + r"\s*\(\s*\)"
    r"|" + _CMD_POS + r"function\s+" + _FUNC_NAME
    # `hash -p PATH NAME` binds NAME to PATH for the rest of the shell -- the same
    # re-pointing `alias` does. NO PREFIX GRAMMAR: modelling what bash allows in front of a
    # builtin (`FOO=x`, `A+=x`, any number, a leading redirection, `builtin`, `command --`,
    # `command -p`) cost three review rounds and left a new prefix open each time, while
    # dropping the anchor measured ZERO further over-blocks. BOUNDED repetition, because the
    # unbounded form backtracked catastrophically -- 7.2s on a valid 59KB command against a
    # 5s hook timeout that fails OPEN, so the regex WAS the fail-open.
    # KEEP IN STEP WITH cmdword._HASH_REMAP.
    # NO OPTION SEARCH either: unbounded it backtracked at 7.2s against a 5s hook timeout,
    # and bounded to 120 characters it was defeated by 121 spaces. Any CHARACTER bound is
    # a guess. The word alone costs 69. KEEP IN STEP WITH cmdword._HASH_REMAP.
    + r"|\bhash\b"
    # A bash ALIAS NAME is not an identifier -- `alias 1x=bash` is valid and runs -- so the
    # branch takes the same word shape the function branches use, plus the end-of-options
    # form. KEEP IN STEP WITH cmdword, whose eval/alias branch matches the WORD and so never
    # had this narrowing.
    + r"|(?:^|[\n;&|(]|\s)\s*alias\s+(?:--\s+)?" + _FUNC_NAME
    # A redirection may follow a command name immediately, so `eval</dev/null <definition>`
    # runs eval while a whitespace-only suffix does not match it. The suffix is widened to
    # the redirect characters rather than to a bare word boundary: a match HERE enables
    # the wholesale helper-name scan, so `\beval\b` would block an innocent
    # `cat docs/eval.md <helper>` and break the read-versus-mention contract. cmdword can
    # afford the bare boundary because a match there only widens WHICH TEXT is scanned.
    # That asymmetry is deliberate; do not "sync" it away.
    #
    # RESIDUAL, and a deliberate over-block: this layer sees TEXT, not a parsed command
    # word, so `cat eval</dev/null <helper>` -- where eval is an ARGUMENT that happens to
    # be followed by a redirect -- matches too. Telling the two apart needs the command
    # word, which is a different layer. An over-block is the safe direction and the shape
    # is contrived; it is pinned in the suite so the choice stays visible. The redirect
    # family is complete -- `<`, `>`, `&>` and `&>>` -- because MISSING one is the unsafe
    # direction, and `&>` was missing.
    + r"|(?:^|[;&|(]|\s)\s*eval(?=\s|$|[<>]|&>>?)"
    # `BASH_CMDS` is the hash table exposed as a writable array: assigning to it binds a
    # NAME to a path exactly as `hash -p` does, without naming the builtin.
    # KEEP IN STEP WITH cmdword._BASH_CMDS_RE.
    + r"|\bBASH_CMDS\s*\[")


def _exec_payloads(words):
    # SCOPE, because the KEEP IN STEP notes further down have been misread in BOTH
    # directions: this feeds the HELPER guard only -- can this command reach
    # lease_slot.py or audit_append. It is NOT the file-mod classifier, which has
    # exactly ONE implementation, cmdword.is_file_mod, imported below.
    #
    # The distinction that matters when editing either file:
    #   - a new file-mod VERB belongs in cmdword._MOD_VERBS alone. It needs no twin
    #     here, because whether a command WRITES is not a question this function asks.
    #   - a new RUNNER -- anything that hands a payload to a shell -- belongs in BOTH,
    #     for different reasons: cmdword so the payload is classified for writes, here
    #     so the payload is searched for a helper. Teaching only one of them leaves the
    #     other blind. That is not hypothetical: `watch` with a quoted payload was added
    #     to cmdword first and reached the helper guard unseen until the branch below
    #     was added.
    #
    # The KEEP IN STEP notes pin the dedup, budget and tokenization details this
    # function shares with cmdword._executed_operands -- never the operand set, which
    # answers a different question and is deliberately wider (no exemption list, any
    # index).
    #
    # Sub-programs this simple command hands to something else to RUN: a find -exec
    # payload (already tokens) and an executed STRING (env -S / a shell -c), which has
    # to be re-tokenized. Without following these, the helper guard only saw the top
    # level, so `find . -exec python3 .../lease_slot.py .claude fake 1 ;` and the same
    # payload inside env -S reached the helper unblocked.
    # A shell/env introducer is matched at ANY index, deliberately, and there is NO
    # exemption list. Requiring command position means knowing where the wrapper preamble
    # ends, which means knowing which wrapper flags take an operand -- and every
    # approximation of that is a fail-open: consuming one operand per flag eats the `find`
    # in `sudo -E find . -exec ...` (-E is boolean), leaving the payload unscanned, and
    # the same holds for `env -i` and `sudo -n`.
    #
    # Exempting commands that "only print their arguments" was tried and REMOVED. Every
    # entry turned out to be another way to execute: `less "+!<cmd>"` runs a shell,
    # `alias echo=eval` re-points the name, a function definition shadows it outright.
    # Patching the list per spelling is the arms race this file exists to avoid, and an
    # exemption in a security detector has to be justified rather than assumed -- so the
    # list is gone and the scan is unconditional.
    #
    # The price is a documented over-block: `echo -exec sh -c "... lease_slot.py ..."`
    # prints a string and is read as an invocation. That is the fail-CLOSED direction on a
    # command nobody writes, and both helpers are safe by construction anyway (lease_slot
    # reads the mtime itself under a lock; audit_append has no writing CLI), so this
    # detector is defence in depth rather than the thing holding the line.
    # Deduped ON INSERT. KEEP IN STEP WITH cmdword._executed_operands, which carries the
    # reasoning: deduping at the END still materializes every duplicate first, and the
    # no-break rescan builds them quadratically -- measured near 203 MiB for a 65KB input
    # whose TIME was already bounded by the token budget.
    tok_payloads, str_payloads = [], []
    _seen_t, _seen_s = set(), set()

    def _add_tok(payload):
        _k = tuple(payload)
        if _k not in _seen_t:
            _seen_t.add(_k)
            tok_payloads.append(payload)

    def _add_str(payload):
        if payload not in _seen_s:
            _seen_s.add(payload)
            str_payloads.append(payload)
    # `-exec` is a find PREDICATE, so it only introduces a payload when some earlier word
    # in the segment is `find`. Treating it as a general convention read the -exec in
    # `bash -c "printf ..." -- -exec sh -c "..."` -- a print -- as an invocation.
    _seen_find = False
    # Only the FIRST watch word is expanded; see the branch below for why.
    _seen_watch = False
    # Payload tokens are NOT re-read as predicates. Restarting the scan inside a payload
    # emitted an overlapping suffix for every `-exec`-looking operand, so N of them cost
    # O(N^2): 1,900 measured 11.0s here, past the 5s hook timeout -- and a timed-out hook
    # writes no decision, which the harness reads as ALLOW. KEEP IN STEP WITH cmdword.
    _skip_to = 0
    for i, w in enumerate(words):
        if i < _skip_to:
            continue
        # `less "+!<cmd>"` / `more "+!<cmd>"`: the pager runs the rest as a shell command.
        # A startup-command operand is an executed STRING wherever it appears, so it is
        # matched by its own shape rather than by knowing which pagers accept it.
        if w.startswith("+!") and len(w) > 2:
            _add_str(w[2:])
        # ANY earlier token, not command position. Resolving command position needs the
        # end of the wrapper preamble, which needs per-flag arity -- and every
        # approximation of that was a fail-open (see above). So this over-blocks a read
        # that happens to name both, e.g. `printf "%s" find -exec <helper> ";"`. Accepted:
        # fail-CLOSED on a contrived string beats a miss on `sudo -u root find -exec`.
        if _bn(w) == "find":
            _seen_find = True
        if _seen_find and w in ("-exec", "-execdir", "-ok", "-okdir"):
            payload, _j = [], i + 1
            while _j < len(words):
                w2 = words[_j]
                # `+` terminates only in the `{} +` form -- anywhere else it is an
                # ordinary operand, and treating it as a terminator TRUNCATED the
                # payload: `-exec /usr/bin/time -o + unshare ;` kept only `time -o`
                # and the launcher behind it was never seen. KEEP IN STEP WITH cmdword.
                if w2 == ";" or (w2 == "+" and payload and payload[-1] == "{}"):
                    break
                payload.append(w2)
                _j += 1
            if payload:
                _add_tok(payload)
            _skip_to = _j + 1
            continue
        base = _bn(w)
        if base == "env":
            for j in range(i + 1, len(words)):
                t2 = words[j]
                if t2.startswith("--split-string="):
                    _add_str(t2.split("=", 1)[1]); break
                if t2 in ("-S", "--split-string") and j + 1 < len(words):
                    _add_str(words[j + 1]); break
                if t2.startswith("-S") and len(t2) > 2:
                    _add_str(t2[2:]); break
        elif base == "watch" and not _seen_watch:
            # `watch COMMAND` joins its non-option arguments and runs the result through
            # sh -c, so a QUOTED payload is executed shell SOURCE that arrives here as one
            # word. Without this branch the quoted spelling reached the helper unseen while
            # every other one was caught -- sh -c, env -S, find -exec, and even UNQUOTED
            # watch, whose payload is separate words the scan already reads. That gap was
            # real: the guard is introduced by this change set, so it shipped with a hole in
            # the exact shape it exists to catch.
            #
            # Deliberately NO option-arity table. Locating the command start means knowing
            # which watch flags take a value, and every gap in such a list fails OPEN --
            # procps keeps adding options, and spellings that postdate any list we could
            # write here already broke an earlier draft of the sibling rule in cmdword.
            #
            # EVERYTHING after the watch word goes in as one payload, which the sibling rule
            # in cmdword cannot do. cmdword needs the command START, because whether a
            # command writes depends on which word is the verb; this guard does not -- it
            # searches the payload for a helper at ANY index, per the no-exemption-list
            # design above. The option words just ride along at the front as inert tokens,
            # so no arithmetic is needed to step over them.
            #
            # It goes in as a TOKEN payload, not a string, so the call site requotes it. A
            # bare space-join was tried and is wrong for the reason already documented at
            # the -exec requote: it drops the boundary a quoted token carried, so
            # `watch -- " sh" -c "python3 -I <helper> ..."` re-lexes as `sh -c python3 -I
            # <helper>`, whose -c handler reads only `python3` and never scans the helper
            # demoted to $0/$1.
            #
            # Each token is STRIPPED first. Scanning tokens individually was the first fix
            # here and was itself defeated by `watch -- " python3" -I <helper>`: one word
            # plus a leading space, so a multi-word test skips it while the shell ignores the
            # space and runs it. Padding is attacker-chosen, so it is normalized away rather
            # than matched against a whitespace list.
            # BOTH payload kinds, because the two shapes need opposite handling and each
            # candidate is judged alone anyway. The token payload keeps quoting boundaries
            # so an inner `-c` operand survives; but requoting also stops a payload that is
            # ITSELF one quoted command from being re-lexed, which is the common
            # `watch "python3 <helper> ..."` spelling. So each shell-source token is added
            # as a STRING too. Fixing only one of these swaps which spelling gets through --
            # it was measured in both directions before landing both.
            # The token payload is added only for a real ARGV of two or more words. A lone
            # token is not an argv -- it is one word the shell re-parses -- so requoting it
            # asserts a boundary that does not exist, and the requoted result is a single
            # word whose basename is the tail of the path INSIDE it. That made
            # `watch "grep -n x <helper>"` read as a bare helper invocation and block, while
            # the identical `sh -c "grep -n x <helper>"` correctly allowed. The string
            # branch below already covers the lone-token case faithfully.
            if len(words[i + 1:]) > 1:
                _add_tok([_t.strip() for _t in words[i + 1:]])
            # The JOIN, not the individual arguments. watch really does join its arguments
            # into one sh -c string, so the joined text is the faithful model AND it keeps
            # operand position: `watch grep -n x <helper>` joins back to the read it started
            # as. Adding each argument separately was tried and promotes every atom to
            # command position, so that same read blocked as a bare helper invocation.
            #
            # Joining also needs no test for which arguments are "really" shell source --
            # the detector that failed three times, first missing ` python3` (one word plus
            # a leading space), then missing `>src/file` (one bare word that redirects).
            # Stripping each token first keeps the padding from surviving the join.
            # A SUFFIX from each argument position, as far as the token budget allows, so the
            # command word is covered wherever the options happen to end. Five narrower
            # formulations were measured first and every one of them fixed one spelling and
            # opened the next -- multi-word arguments only missed a space-padded ` python3`;
            # adding a padding test still missed a lone `>src/file`; the whole-argument join
            # missed a payload behind a value-taking option. All three were fail-OPEN, and
            # the common cause is that telling an OPERAND from a COMMAND WORD is precisely
            # what needs the option-arity table this file refuses to keep.
            #
            # So the trade is taken in the other direction, which is the direction this repo
            # already chose: a suffix set resolves the command word without any arity
            # knowledge, at the cost of also promoting operands, so `watch cat <helper>`
            # reads as an invocation and blocks. That is a FALSE BLOCK on a contrived read,
            # against a FAIL-OPEN on a real invocation, in a fail-CLOSED gate -- and it is
            # the same trade already documented two branches up for `echo -exec sh -c
            # <helper>` and for the helper passed as ARGV to another script.
            #
            # Two bounds. Only the FIRST watch word is expanded: doing it per occurrence made
            # `watch watch watch ...` materialize a suffix per token -- O(tokens^2) bytes,
            # measured near 218 MB -- in a hook whose 5s timeout kills it with NO decision on
            # stdout, which the harness reads as ALLOW. A nested watch is still reached, one
            # recursion later, inside an emitted suffix. And the suffix set is charged to
            # the shared token budget, so a long argv cannot outrun it -- and exhausting it
            # blocks rather than quietly searching less.
            _starts = words[i + 1:]
            if _starts:
                # The full join goes in first and unconditionally, so there is always
                # something to scan no matter what the budget does below.
                _add_str(" ".join(_t.strip() for _t in _starts if _t.strip()))
            _bytes_left = _WATCH_MAX_PAYLOAD_BYTES
            for _k in range(1, len(_starts)):
                # Bounded by BYTES, not by a token count and not by a fixed position cap.
                # Each was tried and each was wrong in its own way. A fixed cap stops
                # searching silently -- a fail-OPEN dressed as a limit, walked past by six
                # repeated value-taking options. Charging token COUNT misses that the cost
                # is the copying: one ~8 MiB argument re-joined into ~88 suffixes is ~700 MB
                # against a budget that only ever saw 88 tokens.
                #
                # Running out does NOT quietly stop the search. The budget is forced
                # negative, so every payload already emitted fails CLOSED the moment it is
                # re-entered, exactly as budget exhaustion does everywhere else here.
                # Not-knowing blocks; it never allows.
                _suffix = " ".join(_t.strip() for _t in _starts[_k:] if _t.strip())
                _bytes_left -= len(_suffix)
                if _bytes_left < 0:
                    _helper_budget[0] = -1
                    break
                if _suffix:
                    _add_str(_suffix)
            _seen_watch = True
        # KEEP IN STEP WITH cmdword._DASH_C_RUNNERS. ash and mksh were listed there and
        # missing here, so `ash -c "<helper>"` walked straight past this guard.
        elif base in ("sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "su", "runuser",
                      "flock", "script"):
            for j in range(i + 1, len(words)):
                t2 = words[j]
                if t2.startswith("--"):
                    # getopt_long accepts any UNAMBIGUOUS ABBREVIATION, so a shortened
                    # --command runs exactly what the full spelling runs. Comparing
                    # against the full spelling left every shorter one unread.
                    name, eq, val = t2.partition("=")
                    _LONG_RUN = ("command", "session-command")
                    # su and runuser also execute --session-command, documented as
                    # equivalent to -c, so the abbreviation test covers both spellings.
                    if len(name) > 2 and any(l.startswith(name[2:]) for l in _LONG_RUN):
                        if eq:
                            _add_str(val)
                        elif j + 1 < len(words):
                            _add_str(words[j + 1])
                    continue          # NO break, for the reason given below
                if t2.startswith("-") and not t2.startswith("--") and "c" in t2[1:]:
                    # ATTACHED or separated, and NOT decidable from the spelling: after
                    # dequoting, a bundle whose tail is MORE FLAGS (bash takes the next
                    # word as the program) and a payload written flush against the -c
                    # are both a -c plus a tail. Both candidates are taken; each is
                    # re-classified alone, so a tail that is really a flag letter
                    # classifies as nothing and the extra one only ever adds a block.
                    tail = t2[t2.index("c", 1) + 1:]
                    if tail:
                        _add_str(tail)
                    if j + 1 < len(words):
                        _add_str(words[j + 1])
                    # NO break. Stopping at the first `c` assumed this token IS the -c,
                    # which needs to know whether an EARLIER flag took it as an operand:
                    # a log-file option hands the -c-looking token to itself as a
                    # FILENAME, and stopping there missed the real program behind it.
                    # That arity table is the one this gate refuses to keep, because it
                    # fails OPEN when wrong. Every token that COULD be a -c operand is a
                    # candidate instead; each is judged alone, so a filename is inert.
                    continue
    # Dedupe, order-preserving. KEEP IN STEP WITH cmdword._executed_operands, which
    # carries the full reasoning: dropping the break makes every runner rescan every later
    # c-looking option, so N repeated option pairs yield O(N^2) candidates but only O(N)
    # distinct ones. Each candidate is judged alone and the verdicts are OR-ed, so a
    # repeat can only re-derive the answer, never change it. Unbounded re-derivation here
    # is not merely slow: this hook is registered with a 5s timeout, and a timeout kills
    # it with NO decision on stdout, which the harness reads as allow.
    return tok_payloads, str_payloads


_ESC_RE = re.compile(
    r"\\(?:x([0-9A-Fa-f]{1,2})"      # \xH, \xHH
    r"|u([0-9A-Fa-f]{1,4})"          # \uH .. \uHHHH
    r"|U([0-9A-Fa-f]{1,8})"          # \UH .. \UHHHHHHHH
    r"|0?([0-7]{1,3}))")             # \ooo, \0ooo


def _decode_escapes(text):
    # Decode the ANSI-C escapes bash decodes, at bash digit widths. Python
    # `unicode_escape` codec is NOT a stand-in: it demands exactly four digits after
    # \u and eight after \U, so bash short forms survived it unchanged and a module
    # name spelled lease_$-quoted-\u73-lot read as an unrelated string. Over-decoding
    # can only make more text match, so it adds blocks and never removes one.
    def _sub(m):
        hexit = m.group(1) or m.group(2) or m.group(3)
        try:
            return chr(int(hexit, 16) if hexit else int(m.group(4), 8))
        except ValueError:
            return ""
    return _ESC_RE.sub(_sub, text)


def _ansi_c(text):
    # ANSI-C quoting as bash resolves it: escapes decoded, the dollar prefix dropped.
    # shlex knows
    # nothing of ANSI-C quoting, so EVERY token it hands back may still be encoded --
    # the interpreter name, the option letter, the operand. Resolving the whole command
    # text before it is tokenized is what makes the token comparisons downstream see
    # what bash will see, instead of only the operands one call site remembered to decode.
    return _decode_escapes(text).replace("$" + chr(39), chr(39))


_WS_RUN_RE = re.compile(r"\s{2,}")


def _collapse_ws(m):
    # A whitespace run becomes exactly ONE character. That much is the PERFORMANCE
    # requirement described at the call site, and it applies to every run: _INDIRECTION_RE's
    # `\s*` sits behind an alternation, so the engine retries it from every offset inside a
    # long run.
    #
    # WHICH character is a separate, correctness question, and `\s` is wider than bash's
    # idea of a blank. Bash separates words on space, tab and newline only -- exactly
    # `_SH_BLANK` -- so a carriage return, vertical tab, form feed or Unicode space sits
    # INSIDE a word. Rewriting a run of those to a space manufactured a word boundary bash
    # never makes, splitting one command word into two and refusing ordinary commands.
    # Returning the run's OWN character keeps the collapse (one character, no backtracking)
    # without inventing the separator. The single-character case never reaches here: the
    # pattern requires a run of two or more, which is why one no-break space was already
    # handled correctly and this went unnoticed.
    run = m.group(0)
    if chr(10) in run:
        return chr(10)
    if any(c in _SH_BLANK for c in run):
        return " "
    return run[0]


def _shell_variants(text):
    # The text as written, and as the shell will have rewritten it before running it.
    # Quoting, escaping, the ANSI-C `$` prefix and a backslash-newline continuation are
    # removed before the command word is resolved; ANSI-C escapes are DECODED, so a
    # hex-escaped module name resolves to lease_slot. Additive: any variant blocks.
    out = [text, _decode_escapes(text)]
    for base in list(out):
        sq = base.replace(chr(92) + chr(10), "")
        for _ch in (chr(39), chr(34), chr(92), "$"):
            sq = sq.replace(_ch, "")
        out.append(sq)
    # COLLAPSE every whitespace run, in EVERY variant. This is a PERFORMANCE requirement,
    # not tidying, and it belongs to the whole list rather than to the stripped copies:
    # _INDIRECTION_RE's `\s*` sits behind an alternation, so the engine retries it from
    # every start position and a long run costs O(run^2). Two different commands reach it.
    #   `echo <20000 empty quoted arguments>` -- the run is CREATED here, by removing the
    #     quote characters, and measured 980ms for one search of one stripped variant
    #     against 6ms for the same search of the raw text.
    #   `echo a<20000 spaces>b` -- the run is WRITTEN OUT, so it is in `text` itself and
    #     collapsing only the stripped copies left it: 4.34s at 20KB and 16.4s at 40KB,
    #     both returning OK. Raised by codex on this change, and it is the sharper of the
    #     two -- the first at least ended in BLOCK_UNSCANNABLE once it finished.
    # Either way the hook's 5s timeout writes no decision, which reads as ALLOW, so a slow
    # scanner is itself a fail-open -- the same reason the token budget exists.
    # PRE-EXISTING, measured as such: 4.65s and 4.60s for the first shape at the merge-base
    # and on origin/main, neither carrying any of this ticket's changes.
    # A run KEEPS A NEWLINE if it had one. Collapsing to a bare space would be a fail-OPEN:
    # _INDIRECTION_RE reads `\n` as a command separator in `[\n;&|{()]`, so `  \n  eval`
    # losing its newline loses the match. Nothing else here distinguishes one separator
    # from many -- `\s*` matches either, a substring test never spans a run, and both
    # splits in _abandoned_scan_probe treat a run as one break -- which is also what bash
    # does once quote removal is over and IFS splitting runs.
    # cmdword's copy of this function is deliberately NOT changed with it: measured on the
    # same input, its `_has_indirection` takes 27ms, because its own _INDIRECTION_RE leads
    # with a `\b(?:eval|alias)\b` alternation rather than a separator followed by `\s*`.
    # There is nothing to keep in step until that pattern grows one.
    return [_WS_RUN_RE.sub(_collapse_ws, _v) for _v in out]


# Shells that run a program fed to them on STDIN -- a SUPERSET of the -c runner list above,
# and separate from it on purpose: that list drives RECURSION into a -c operand, while this
# one answers only "could this consume stdin as a program". csh/tcsh/fish belong here (each
# verified executing a piped program) without dragging their -c semantics along.
# KEEP IN STEP WITH cmdword._STDIN_SHELLS.
# RESIDUAL: an ENUMERATION, so a shell nobody listed still reads as a non-shell. The family
# does not close; adding a name is free, so add rather than argue when one is found.
# The last six are not shells, but they read a PROGRAM from stdin exactly as one does --
# `printf <program> | python3` runs it -- and this list answers only that question.
# KEEP IN STEP WITH cmdword._STDIN_SHELLS.
# `lldb` alongside `gdb`: when installed, LLDB treats piped stdin as debugger commands and
# its `platform shell` command runs an arbitrary shell command on the current platform
# (its own built-in help: "Run a shell command on the current platform"). Verified against
# a real `lldb` binary. Raised by Codex on #562. KEEP IN STEP WITH cmdword._STDIN_SHELLS.
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
_SHELL_NAMES = ("sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "csh", "tcsh", "fish",
                "yash", "posh", "bosh", "osh", "oil", "elvish", "xonsh", "nu",
                "python", "python2", "python3", "perl", "ruby", "node",
                "tclsh", "wish", "lua", "php",
                "awk", "gawk", "mawk", "nawk",
                "sqlite3", "ed", "ex", "psql", "gdb", "lldb",
                "jshell", "sftp",
                "xargs", "make")
# `source` is deliberately ABSENT, unlike the rest of this set. It is handled in COMMAND
# POSITION ONLY, alongside `.` below -- an any-word match here cost a real over-block
# (`printf 'rm -rf src' | grep source` blocked on the bare word `source` appearing as a
# grep PATTERN, not a command). Raised by Codex on #562, verified. `xargs` stays IN this
# set despite Codex raising the same "default command is harmless echo" argument for it:
# `printf 'rm -rf src' | xargs` is PINNED to block by
# tests/test-impl-gate-scope-519.sh ("xargs executes what it reads from stdin") and its
# 3000-command property fixture, which both treat this as the deliberate fail-CLOSED
# direction this module chooses throughout -- narrowing it here would regress a decision
# the suite already locked in, not fix a bug. KEEP IN STEP WITH cmdword._STDIN_SHELLS.


# A name this set already knows, wearing a version suffix: `python3.12` is python3. Without
# this the two classifiers DESYNC -- cmdword blocks a helper payload piped to python3.12
# while this guard returned OK for the identical command, which is the keep-in-step defect
# this pair exists to avoid. UNANCHORED so the attached-option-bundle check can use search
# (`env -iSpython3.12`); whole-name callers use fullmatch.
# EXTENDED beyond python: `/usr/bin/perl5.38.2` and `/usr/bin/tclsh8.6` are equally real,
# packaged executable names that this exact-name set does not match. Raised by Codex on
# #562 as a fresh case beyond the python fix; verified against real `perl5.38.2` and
# `tclsh8.6` binaries. Covers the interpreter names above that ship version-qualified
# spellings in practice (python/perl/ruby/node/lua/php/tclsh/wish) -- `wish` ships beside
# `tclsh` from the same Tcl/Tk package and is version-qualified the same way
# (`/usr/bin/wish8.5`), so omitting it left exactly the bypass its sibling closes.
# ATTACHED versions only (`python3.12`, `python3.13t` -- the free-threaded build wears a
# trailing `t`). This pattern is asked of EVERY WORD in a stage, so it may only accept
# shapes ordinary data never has: an interpreter name glued to digits is one, a
# DASH-separated version is not. `lldb-19` and `gdb-14` are real packaged spellings, but
# `grep lldb-19` is an equally real grep, so they belong to the command-position class
# tracked in #565 -- the bare names `lldb`/`gdb` are in the exact-name set and unaffected.
# The numeric requirement is what keeps the rest safe to ask
# of every word: `python3-report` is ordinary hyphenated data, and matching it read a word
# `grep` merely searches for as an interpreter.
#
# KNOWN RESIDUAL (#565): a MULTIARCH name carries the platform triplet on the versioned
# name itself (`perl5.36-x86_64-linux-gnu`), which this deliberately does not match -- see
# the fuller note on cmdword._VERSIONED_INTERP_RE.
# KEEP IN STEP WITH cmdword._VERSIONED_INTERP_RE / cmdword._is_stdin_shell.
_VERSIONED_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)$")

# The same names for the ATTACHED-bundle question -- does a dash-word END WITH an
# interpreter (`env -iSpython3.12`) -- which is a SEARCH, not a whole-name match. The
# dash-separated version is deliberately absent here: `--label=issue-lldb-19` ends with
# one, and searching for it turned an option's DATA into a receiver.
# KEEP IN STEP WITH cmdword._ATTACHED_INTERP_RE.
_ATTACHED_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)$")


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





def _is_shell_name(name):
    """Exact shell/interpreter name, or a version-qualified spelling of one."""
    return name in _SHELL_NAMES or bool(_VERSIONED_INTERP_RE.fullmatch(name))
# LAUNCHERS that exec a shell when given NO program operand, so a pipe feeds that shell.
# Matched in COMMAND POSITION only -- these are ordinary words, and the any-word test would
# flip `grep script`. KEEP IN STEP WITH cmdword._LAUNCHER_SHELLS.
_LAUNCHER_SHELLS = ("script", "su", "runuser", "chroot", "unshare", "nsenter",
                    "newgrp", "sg")
# Words that sit BEFORE the command without being it -- an assignment prefix, or a keyword
# bash allows ahead of a command. Skipped when looking for a launcher, because `FOO=1
# unshare` and `time script` put one in command position just as a bare `unshare` does.
# The _starts_with_wrapper helper here does NOT skip `time`, which is why the walk handles
# that word explicitly rather than leaning on the helper. KEEP IN STEP WITH cmdword.
# busybox/toybox are MULTI-CALL DISPATCHERS -- the applet after them is the real
# command, and the busybox unshare applet execs a shell with no program operand.
# KEEP IN STEP WITH cmdword._CMD_PREFIX_WORDS.
_CMD_PREFIX_WORDS = ("time", "command", "exec", "nohup", "builtin", "!",
                     "busybox", "toybox")
# A redirection may sit AHEAD of the command word: `2>/dev/null unshare` runs unshare.
# `_REDIR_PREFIX_RE` above is REUSED rather than re-spelled -- a second copy would shadow
# the one every other walk here consults. punctuation_chars lexing splits the fd number
# off its operator, so `2>/dev/null` arrives as `2`, `>`, `/dev/null`.
# A COMPOUND stage hands the pipe to the command INSIDE it: `| { unshare; }`. Reserved
# words count in COMMAND POSITION ONLY. Splitting into simple commands is the CALLER task,
# over the RAW text, because splitting from tokens is quote-blind -- shlex erases the
# difference between a separator `;` and an operand one. KEEP IN STEP WITH cmdword.
_COMPOUND_WORDS = _GROUP_OPEN + _GROUP_CLOSE + _GROUP_CONNECT
# An assignment prefix needs a valid IDENTIFIER before the `=`. KEEP IN STEP WITH cmdword.
# ONE definition, used by `_skippable`/`_strip_time_prefix` above as well as here. A
# second, narrower copy was briefly added beside `_skippable`; because both bound at
# import time the later one silently won, so editing the earlier one would have had no
# effect at all. The subscript form is deliberate -- bash treats `a[0]=1` as an assignment
# prefix too.
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*(?:\[[^]]*\])?\+?=")
# Openers whose next word is a variable or a subject. KEEP IN STEP WITH cmdword.
_GROUP_HEADERS = ("for", "select", "case")
# sudo/doas shell MODES start a shell with no command operand. The flag is matched rather
# than the absence of an operand, which would need option arity, and only inside the
# wrapper OWN option run -- otherwise `sudo grep -i needle` blocked. A bundle counts only
# when every letter is a no-argument flag. KEEP IN STEP WITH cmdword.
_SHELL_MODE_WRAPPERS = ("sudo", "doas")
_SHELL_MODE_LONG = ("--shell", "--login")
_SHELL_MODE_NOARG = "AbEHKknPSsVvilL"


def _has_shell_mode_flag(toks):
    """A sudo/doas shell-mode flag among these words. No option run, no value skipping,
    no arity -- scoping it to the wrapper own option run needed to know which options take
    a VALUE (`sudo -u root -s`, `sudo --user root --shell` both hid the flag behind an
    operand). The whole-stage scan is the regime a wrapper already selects here, and its
    price is the same: a word in the WRAPPED command data reads as the flag.
    KEEP IN STEP WITH cmdword.
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
    """A sudo/doas shell mode anywhere in this stage. KEEP IN STEP WITH cmdword."""
    return (any(_bn(w) in _SHELL_MODE_WRAPPERS for w in words)
            and _has_shell_mode_flag(words))


def _leads_with_launcher(toks, words):
    """Is a no-command shell LAUNCHER what this stage actually runs?
    Command position only, so `grep script` is untouched. An OPTION in command position
    has unknowable arity (`/usr/bin/time -o FILE unshare`), so it marks the stage
    UNRESOLVED and the whole stage is asked instead. KEEP IN STEP WITH cmdword.
    """
    i, n = 0, len(toks)
    at_start = True
    unresolved = False
    first_cmd = None
    while i < n:
        t = toks[i]
        b = _bn(t)
        if not at_start:
            i += 1
            continue
        if t in _GROUP_HEADERS:
            # A header names a VARIABLE or a SUBJECT, not a command: `for script in a`.
            # KEEP IN STEP WITH cmdword.
            return False
        if t in _COMPOUND_WORDS or b in _CMD_PREFIX_WORDS:
            i += 1
            continue
        if _ASSIGN_RE.match(t):
            i += 1
            continue
        j = i + 1 if (t.isdigit() and i + 1 < n
                      and _REDIR_PREFIX_RE.match(toks[i + 1])) else i
        m = _REDIR_PREFIX_RE.match(toks[j])
        if m:
            i = j + 1 + (m.end() == len(toks[j]))
            continue
        if t.startswith("-") and t != "-":
            unresolved = True
            i += 1
            continue
        if b in _LAUNCHER_SHELLS:
            return True
        if b in _SHELL_MODE_WRAPPERS and _has_shell_mode_flag(toks[i + 1:]):
            return True
        # An UNRESOLVED command word cannot be ruled out, and a prefix hides it from the
        # peeled word: `busybox "$APPLET"` peels to busybox. KEEP IN STEP WITH cmdword.
        if _UNRESOLVED_CW_RE.search(t):
            return True
        if first_cmd is None:
            first_cmd = i
        at_start = False
        i += 1
    if unresolved:
        # An UNRESOLVED word cannot be ruled out either: the command word is already
        # unlocatable, so an expansion is what runs. KEEP IN STEP WITH cmdword.
        return (any(_bn(w) in _LAUNCHER_SHELLS for w in words)
                or any(_UNRESOLVED_CW_RE.search(w) for w in words)
                or _shell_mode_launch(words))
    # From the command word, not from the front -- this copy of _starts_with_wrapper does
    # not model `time`, so `time env -i script` answered no. KEEP IN STEP WITH cmdword.
    rest = toks if first_cmd is None else toks[first_cmd:]
    return bool(_starts_with_wrapper(rest)) and (
        any(_bn(w) in _LAUNCHER_SHELLS for w in words)
        # ...and a NESTED shell mode: `env -i sudo -s` leads with a wrapper.
        or _shell_mode_launch(words))


def _lexed_words(text):
    """Words of `text` with the QUOTING RESOLVED, falling back to a raw split.

    A raw split leaves the quote characters attached, so a quoted name matches no set --
    the fail-open this exists to close. KEEP IN STEP WITH cmdword, whose executed-operand
    loop lexes for the same reason.
    """
    try:
        _l = shlex.shlex(text, posix=True, punctuation_chars=True)
        _l.whitespace_split = True
        _l.commenters = ""
        return list(_stage_words(list(_l)))
    except ValueError:
        return text.split()


def _launcher_in_any_simple_command(text):
    """Does any simple command in this text LEAD with a launcher?
    Quote-aware split over the raw text; unsplittable or unlexable fails CLOSED. Each
    command is judged against its OWN lexed words -- one flattened list let a wrapper in
    one command pair with a launcher-shaped operand in another, and a raw split leaves the
    quote characters attached to a quoted name. KEEP IN STEP WITH cmdword.
    """
    segs, ok = _split_simple_commands(text)
    if not ok:
        return True
    for s in segs:
        try:
            _sl = shlex.shlex(s, posix=True, punctuation_chars=True)
            _sl.whitespace_split = True
            _sl.commenters = ""
            _st = list(_sl)
        except ValueError:
            return True
        if _leads_with_launcher(_st, list(_stage_words(_st))):
            return True
    return False


# Compound-command keyword sets -- see the definitions above _FUNC_NAME.


def _group_delta(words):
    # How much this segment opens or closes, counting only the LEADING run: a compound
    # keyword is one only in command position, and segments are already split on separators.
    # Counting the keyword ANYWHERE was measured far wider, because `if`, `for` and `done`
    # are ordinary words in ordinary commands and a stray one opened a depth nothing closed.
    # KEEP IN STEP WITH cmdword._group_delta.
    delta = 0
    for w in words:
        if w in _GROUP_CONNECT:
            continue
        if w in _GROUP_OPEN:
            delta += 1
        elif w in _GROUP_CLOSE:
            delta -= 1
        else:
            break
    return delta


def _carries_no_command(segtext):
    # A stage holding no command at all: empty, or only a comment. _norm_for_scan turns a
    # NEWLINE into a separator, so an ordinary pipeline broken across lines arrives as a pipe
    # feeding an empty stage followed by a separator -- and reading that as the end of the
    # pipeline dropped the fed state one stage before the receiver.
    # KEEP IN STEP WITH cmdword._carries_no_command.
    stripped = segtext.strip()
    return stripped == "" or stripped.startswith("#")


def _stage_words(toks):
    # Every word a stage could resolve to a command NAME. Whitespace-splitting each token is
    # not enough: an option can carry its value ATTACHED, and BSD/macOS `env -S` + a quoted
    # program lexes to ONE token whose first word matches no shell. General rather than
    # env-specific -- drop the leading dashes and one option letter, and take everything past
    # a long option separator. Over-generating is free here.
    # KEEP IN STEP WITH cmdword._stage_words.
    for t in toks:
        forms = [t]
        # A COMMAND SUBSTITUTION inside an argument inherits the pipeline stdin, so
        # `printf <payload> | echo "$(bash)"` runs the payload while the stage command word
        # is `echo`. Splitting the substitution punctuation into whitespace hands the body to
        # the SAME shell-name test the stage gets. KEEP IN STEP WITH cmdword._stage_words.
        if "$(" in t or chr(96) in t or "(" in t:
            forms.append(t.replace("$(", " ").replace(chr(96), " ")
                          .replace("(", " ").replace(")", " "))
        if t.startswith("-"):
            forms.append(t.lstrip("-")[1:])
            forms.append(t.partition("=")[2])
        for f in forms:
            for w in f.split():
                yield w


def _outer_removal(text):
    # The bytes a receiving shell actually GETS: the outer shell's quote removal, applied.
    # This is the half a plain "strip every quote and backslash" squeeze got wrong in both
    # directions -- it deleted backslashes that single quotes preserve, and it joined
    # `'$'P` correctly only by accident.
    out, i, n = [], 0, len(text)
    in_s = in_d = False
    while i < n:
        c = text[i]
        if in_s:
            # Single quotes preserve EVERYTHING, backslash included, so `'\$P'` reaches
            # the receiver with its backslash intact. That is faithfully what it GETS;
            # whether the backslash still protects anything by the time it is parsed is
            # `_inner_expands`'s question, and its answer is no -- an escape survives one
            # parse and a payload can be parsed again.
            if c == _SQ:
                in_s = False
            else:
                out.append(c)
            i += 1
        elif c == chr(92):
            # Inside double quotes a backslash is special only before these four; outside
            # quotes it always quotes the next character.
            if in_d and (i + 1 >= n or text[i + 1] not in (chr(36), _DQ, chr(92), _BT)):
                out.append(c)
                i += 1
            elif i + 1 < n:
                out.append(text[i + 1])
                i += 2
            else:
                i += 1
        elif c == _SQ and not in_d:
            in_s = True
            i += 1
        elif c == _DQ and not in_s:
            in_d = not in_d
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _inner_expands(text):
    # Given what the inner shell RECEIVES, could it expand anything?
    #
    # A TERMINATOR, not a model, and it took three attempts to find the only version that
    # actually terminates. Every rung of the ladder was a fail-open found after the one
    # before it shipped: single quotes were modelled, then a literal quote inside DOUBLE
    # quotes made `"'" ; $P ; echo "'"` look inert and skipped a live `$P`; then only the
    # BACKSLASH was honoured, and that broke too, because a backslash neutralizes an
    # expansion for exactly ONE parse and a payload can be parsed more than once --
    # `sh <<< 'sh -c \$P'` hands the inner shell `sh -c $P`, whose own nested shell
    # expands it and runs the helper.
    #
    # There is no depth at which this stops, so nothing about the payload's quoting or
    # escaping is trusted at all: a `$` that could begin an expansion, or a backtick, is
    # LIVE. That is the answer this file already reached for the same shape in
    # `_herestring_shell_payloads` -- keep the precision on the BLOCK side, stop trusting
    # the ALLOW side -- and unlike the three attempts above it cannot acquire a new rung,
    # because no quoting construct anywhere can turn "there is a dollar here" into "there
    # is not".
    #
    # The cost is an OVER-BLOCK, the direction this module accepts, and it needs BOTH
    # halves: a payload carrying a `$` or a backtick AND a command naming a mutating helper
    # somewhere in its text. Review flagged the escaped spelling as a false positive while
    # it was still believed inert; it is knowingly kept, because the alternative is the
    # unbounded ladder above.
    #
    # `_outer_removal` still runs first, and still earns its keep: quoting CONCATENATES, so
    # `'$'P` is three characters the outer shell joins into `$P` that no scan of the raw
    # text would see.
    inner = _outer_removal(text)
    i, n = 0, len(inner)
    while i < n:
        c = inner[i]
        if c == _BT:
            return True
        if c == chr(36) and i + 1 < n and (inner[i + 1] in _PARAM_START
                                           or inner[i + 1] in "{("):
            return True
        if c == "~":
            # TILDE EXPANSION is an expansion too, and it is not spelled with a dollar.
            # `HOME='<helper>'; sh <<< ~` executes the helper -- verified by running it --
            # and the operand carries no `$` at all, so every test here answered "nothing
            # unresolvable" and the payload went unscanned. The piped spelling
            # (`printf %s ~ | sh`) had it identically.
            #
            # ANY tilde, with no position test. The first attempt allowed one after a blank
            # or an `=`/`:` only, on the reasoning that a trailing `~` in a backup filename
            # is ordinary text -- and review immediately produced two more positions bash
            # also expands from: `sh<<<~`, where the tilde follows the redirection operator,
            # and `{~,}`, where brace expansion manufactures a word-leading tilde behind a
            # `{`. Enumerating word boundaries is the ladder this function exists to refuse,
            # and it is the same refusal the dollar above already makes: over-block rather
            # than maintain a list of positions that is only ever one review round from
            # incomplete. The cost needs BOTH halves -- a `~` anywhere in the payload AND a
            # command naming a helper somewhere in its text.
            return True
        i += 1
    return False


# NOT WIRED INTO `saw_exp`. A bare `$NAME` was briefly flagged there so that an
# unresolvable payload would be noticed, and it broke a documented contract: `saw_exp`
# drives the no-receiver TERMINATOR, whose reason is that the scan may mis-decide where a
# structured expansion ENDS and let a word escape it. A bare parameter opens no nesting
# level, so there is no boundary to get wrong -- and feeding it in made
# `P='<helper>'; cat <<< "$P"` block, although `cat` executes nothing and the file promises
# a non-executing receiver is never probed. The payload question is asked directly below
# instead, where it belongs.
def _text_unresolvable(text):
    # Does this text contain anything whose VALUE is not statically visible? Used by both
    # stdin transports to decide when a per-stage or per-segment view is too narrow to
    # answer with, so the search has to widen to the whole command.
    # TWO-LEVEL, unlike every other expansion test in this file, and deliberately so.
    # Everywhere else the question is what the OUTER shell expands. Here the text becomes
    # the PROGRAM a second shell parses, so the outer shell's quoting decides only what
    # that shell RECEIVES, and the inner shell's quoting decides what it then expands.
    # Verified by running it: `export P='<helper>'; sh <<< '$P'` prints nothing from the
    # outer shell and executes the helper in the inner one, and it classified OK.
    if _locale_string[0]:
        # A locale string ANYWHERE in this command: what it translates to is not visible
        # here, so no payload in the command can be called statically known. See
        # `_locale_string` for why command-wide is the right grain for this one and was the
        # wrong grain for `$IFS`.
        return True
    # Outer quote removal FIRST, because quoting CONCATENATES: `'$'P` is three characters
    # the outer shell joins into `$P`, which a scan of the raw text would never see. What
    # it does NOT buy is a judgement about escaping -- `_inner_expands` deliberately trusts
    # none, since an escape survives only one parse. See its own note.
    if _inner_expands(text):
        return True
    _r = _shell_pieces(text)
    return _r is None or _r[1]


def _piped_shell_producers(pairs):
    # Text feeding each pipeline stage that might be a shell reading its PROGRAM from
    # stdin. `bash -c "<helper> ..."` was blocked while `printf "<helper> ..." | bash` was
    # allowed -- the same invocation, one transport apart. What the producer WRITES is not
    # recoverable by parsing (a split printf assembles the name from operands that are each
    # inert), so the producer text is handed to the wider name probe instead.
    #
    # The stage test is deliberately WIDE and carries no option-arity table: deciding
    # whether a shell reads stdin from its FLAGS is the arity question this file refuses to
    # answer, and it failed open four ways when tried (`bash --norc` read as "-c present",
    # `bash --rcfile -c` read the VALUE of --rcfile as the option). The pipeline structure
    # already says the stage is fed; all that is left is whether it might be a shell. So a
    # shell name anywhere counts, tokens are re-split on whitespace (a quoted `env -S`
    # operand arrives as ONE token), and a command word carrying an expansion or a glob
    # counts too -- the shell expands /bin/[b]ash onto bash, and a literal-name test reads a
    # command word that no set contains.
    #
    # GROUPING IS TRANSPARENT. This splitter breaks on parens and on every `;`, so a
    # grouped producer, a parenthesised receiver, and a receiver whose group holds its own
    # separator all hide behind an apparent pipeline boundary -- each measured as an
    # executing write that classified as a read. A group DEPTH is tracked instead: only a
    # separator at depth 0 starts a new pipeline. Braces are counted as whole WORDS, so
    # a ${VAR} reference is not read as a group.
    #
    # ONE producer per pipeline, from its LAST candidate stage: every earlier candidate
    # produces a PREFIX of that text, so the probe sees the same thing either way, and
    # building one per stage is O(stages^2) bytes -- the shape that put the watch scan
    # above near 218 MB inside a hook whose timeout reads as allow.
    # KEEP IN STEP WITH cmdword._piped_shell_producers.
    # TWO depths, each clamped at zero, never one sum: a `case` pattern terminator is a bare
    # `)` with no opener, so a single counter let it cancel the `case` keyword depth and the
    # `;;` behind it then discarded the producer.
    out, start, last, fed, bare = [], 0, None, False, False
    pdepth = kdepth = 0
    for i, (op, seg) in enumerate(pairs):
        pdepth = max(0, pdepth + op.count("(") - op.count(")"))
        depth = pdepth + kdepth
        # A PIPE FEEDS AT ANY DEPTH, and this test comes FIRST. Folding it into the
        # in-a-group branch meant a pipeline written wholly inside a group had its pipe
        # ignored and its shell never seen as fed. Depth suppresses only the SEPARATOR.
        # Brace counting is therefore loose-but-safe: an over-count only stops a separator
        # from resetting, which WIDENS the producer, and can never hide a pipe.
        # Grouping punctuation joins the run when no segment text separates it, so a
        # valid `cmd ||(sub)` arrived as `||(` and read as a pipe. Parens carry no
        # pipeline meaning here. KEEP IN STEP WITH cmdword._is_pipe.
        if op.replace("(", "").replace(")", "") in ("|", "|&"):
            fed = True
        elif (op and all(ch in "()" for ch in op)) or depth > 0:
            pass                          # grouping: does not terminate the pipeline
        elif fed and bare:
            pass                          # a normalized newline/comment between | and the shell
        else:
            if last is not None:
                out.append((" ;" + chr(10)).join(p[1] for p in pairs[start:last]))
            start, last, fed = i, None, False
        _words = seg.split()
        bare = _carries_no_command(seg)
        if fed:
            try:
                lex = shlex.shlex(seg, posix=True, punctuation_chars=True)
                lex.whitespace_split = True
                lex.commenters = ""
                toks = list(lex)
            except ValueError:
                toks = None               # unparseable stage: assume the worst
            _sw = None if toks is None else list(_stage_words(toks))
            # The third disjunct is the option BUNDLE with its value attached: peeling one
            # option letter leaves `Sbash`, and peeling a fixed number never terminates
            # because the caller chooses the bundle length. endswith is O(names), not O(len^2).
            # CHARGE FIRST. _exec_payloads below is the same potentially quadratic walk
            # the budget at the end of _helper_invoked exists to bound, and this loop
            # reached it once per stage without paying. A permitted 64,004-character
            # command (`: | ` then `env ` sixteen thousand times) took 5.4s -- past the
            # hook timeout, and a timed-out hook writes NO decision, which the harness
            # reads as ALLOW. Overrunning the budget leaves it negative, so the charge at
            # the end of _helper_invoked fails CLOSED on the very first segment.
            _helper_budget[0] -= len(toks) if toks is not None else len(seg.split())
            if _helper_budget[0] < 0:
                break
            if toks is None or any(_is_shell_name(_bn(w)) for w in _sw) \
               or any(w.startswith("-") and (any(w.endswith(n) for n in _SHELL_NAMES) or _ATTACHED_INTERP_RE.search(w))
                      for w in _sw) \
               or (any(_bn(w) in _ENV_NAMES for w in _sw)
                   and any(_env_names_split_string(w) for w in _sw)):
                last = i
            else:
                # A stage can RUN a shell without ever NAMING one in command position:
                # `env -S"$A"` hands its operand to execvp, and _peel_wrappers skips
                # `-S$A` as an option and returns None, so the command word alone can
                # never see it. The operands this stage EXECUTES are therefore asked the
                # same two questions the stage itself was. KEEP IN STEP WITH
                # cmdword._may_read_program_from_stdin, whose _executed_operands loop
                # this mirrors -- the gate lacking it was a live fail-OPEN.
                cw = _peel_wrappers(_strip_time_prefix(toks))
                # `.` and `source` are the two POSIX/bash spellings of the same builtin, and
                # `. /dev/stdin` / `source /dev/stdin` both run the piped text. Command
                # position ONLY: a bare `.` is an ordinary argument (`find . -name x`) and a
                # bare `source` is an ordinary word (`grep source` names it as a PATTERN, not
                # a command) -- putting either in _SHELL_NAMES, matched against every word,
                # cost 100 over-blocks for `.` and a further over-block for `source`
                # (`printf 'rm -rf src' | grep source`, raised by Codex on #562). KEEP IN
                # STEP WITH cmdword._may_read_program_from_stdin.
                # Same rule for LAUNCHERS that exec a shell with no program operand, so the
                # pipe feeds that shell. Command position ONLY, for the same reason as `.`:
                # these are ordinary words and any-word matching would flip `grep script`.
                # KEEP IN STEP WITH cmdword._LAUNCHER_SHELLS.
                # NOT asked of the PEELED command word: `script`, `su`, `runuser` and
                # `chroot` are themselves wrappers, so peeling steps past them. Ask the
                # LEADING token, plus the whole wrapper run when one leads (for
                # `env -i script`). KEEP IN STEP WITH cmdword.
                if (cw and _bn(cw) in (".", "source")) \
                   or _launcher_in_any_simple_command(seg):
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                # A SUBSTITUTION is executed, so an unresolved word inside one is an
                # unresolved command word. KEEP IN STEP WITH cmdword.
                _sub_unres = False
                _flat_dollar = 0
                for _m in _SUBST_BODY_RE.finditer(seg):
                    # Only the `$(` spelling counts, because only `$(` openers are counted
                    # below -- a shared counter let an unrelated backtick substitution pay
                    # for a `$(` opener, so a nested `$( ( . /dev/stdin ) )` read as fully
                    # resolved. KEEP IN STEP WITH cmdword.
                    _flat_dollar += _m.group(1) is not None
                    _body = _m.group(1) or _m.group(2) or ""
                    # A body is a COMPOUND command, so it is SPLIT and every segment gets the
                    # receiver questions the stage got, not a weaker one asked of the body as
                    # a whole: `$(. /dev/stdin)` runs the piped payload while the outer command
                    # word is `echo`, and `$(true; . /dev/stdin)` hides the `.` behind a
                    # harmless first command that _peel_wrappers would read instead.
                    # KEEP IN STEP WITH cmdword.
                    _bsegs, _bok = _split_simple_commands(_body)
                    if not _bok or _UNRESOLVED_CW_RE.search(_body):
                        _sub_unres = True
                        break
                    for _bseg in _bsegs:
                        _bt = None
                        try:
                            _bl = shlex.shlex(_bseg, posix=True, punctuation_chars=True)
                            _bl.whitespace_split = True
                            _bl.commenters = ""
                            _bt = list(_bl)
                        except ValueError:
                            _bt = None
                        _bw = [] if _bt is None else list(_stage_words(_bt))
                        _bcw = None if _bt is None else _peel_wrappers(_strip_time_prefix(_bt))
                        # The LAUNCHER question belongs here too: `$(unshare)` runs inside
                        # the pipeline, so it inherits the stdin the outer `echo` never
                        # reads and the payload reaches the shell it execs. Asking only
                        # _SHELL_NAMES and `.` left that open. KEEP IN STEP WITH cmdword.
                        # A body can also EXECUTE an operand of its own, and
                        # _stage_words re-splits on whitespace, which leaves the quote
                        # characters attached: `env -S "env -i <quoted launcher>"` inside
                        # a substitution read as no launcher at all. The payloads are
                        # extracted and lexed instead. KEEP IN STEP WITH cmdword, whose
                        # _executed_operands loop covers the same ground.
                        _btp, _bsp = _exec_payloads(_bt) if _bt is not None else ([], [])
                        _bprogs = [" ".join(shlex.quote(_x) for _x in _p)
                                   for _p in _btp] + list(_bsp)
                        if _bt is None \
                           or any(_is_shell_name(_bn(w)) for w in _bw) \
                           or (_bcw and _bn(_bcw) in (".", "source")) \
                           or _leads_with_launcher(_bt, _bw) \
                           or any(_is_shell_name(_bn(w))
                                  for _p in _bprogs for w in _lexed_words(_p)) \
                           or any(_launcher_in_any_simple_command(_p)
                                  for _p in _bprogs):
                            _sub_unres = True
                            break
                    if _sub_unres:
                        break
                # NESTED substitutions have inner parens the flat pattern cannot cross, so
                # counting openers against matches is how this notices it cannot read the
                # text. Unresolved fails CLOSED. KEEP IN STEP WITH cmdword.
                if seg.count("$(") > _flat_dollar:
                    _sub_unres = True
                # UNBALANCED parens break the flat extraction without nesting anything: a
                # `case` PATTERN closes it early, so `$(case x in x) $SHELL;; esac)` yields
                # the body `case x in x` and the `$SHELL` receiver behind it is never seen.
                # Which `)` bash treats as the close is context-sensitive, so this refuses to
                # resolve it rather than model it. Scoped to substitution-bearing stages, so
                # an ordinary `case` pays nothing. KEEP IN STEP WITH cmdword.
                # KNOWN BYPASS, same as cmdword: the count is QUOTE-BLIND, so an inert
                # `echo "("` re-balances it and the truncation is exploitable again. An
                # `esac` NAME tripwire was tried and reverted -- segments split on `;`
                # first, so `esac` never lands in the `$(` segment. Recorded in ADR 0032
                # with the rest of the residual family. KEEP IN STEP WITH cmdword.
                if "$(" in seg and seg.count("(") != seg.count(")"):
                    _sub_unres = True
                if _sub_unres:
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                # The EXTGLOB spelling, resolved, in front of the same name test.
                if _EXTGLOB_NEG_RE.search(seg):
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                _deglob = _EXTGLOB_RE.sub(r"\1", seg)
                if _EXTGLOB_RE.search(_deglob) or _EXTGLOB_NEG_RE.search(_deglob):
                    # NESTED: `ba@(+(s))h` still holds a group after the inner one resolves,
                    # and iterating to a fixed point is a slower guess at a grammar. Same
                    # exit the negation and the alternation take -- unresolved, fail CLOSED.
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                if _deglob != seg:
                    _dtoks = None
                    try:
                        _dlex = shlex.shlex(_deglob, posix=True, punctuation_chars=True)
                        _dlex.whitespace_split = True
                        _dlex.commenters = ""
                        _dtoks = list(_dlex)
                    except ValueError:
                        _dtoks = None
                    if _dtoks is None or any(_is_shell_name(_bn(w))
                                             for w in _stage_words(_dtoks)):
                        last = i
                        kdepth = max(0, kdepth + _group_delta(_words))
                        continue
                _tokp, _strp = _exec_payloads(toks)
                # REQUOTED, not space-joined: a token payload carries real argv
                # boundaries, so `-exec grep "foo; unshare" ;` must not re-read as two
                # commands. KEEP IN STEP WITH cmdword, which requotes for the same reason.
                _progs = [" ".join(shlex.quote(_x) for _x in p)
                          for p in _tokp] + list(_strp)
                # A WRAPPER hides the real program among its operands, and peeling can land
                # on the wrong word: `env -u X /bin/[b]ash` peels to `X`, the operand of
                # `-u`, so the globbed receiver behind it is never tested. Asking the whole
                # stage is the arity-free answer, scoped to wrapper-led stages because
                # asking it of EVERY stage measured 8.63% against ZERO for this.
                # KEEP IN STEP WITH cmdword._may_read_program_from_stdin.
                if (cw and _UNRESOLVED_CW_RE.search(cw)) \
                   or (_starts_with_wrapper(toks)
                       and any(_UNRESOLVED_CW_RE.search(w) for w in _sw)) \
                   or any(_UNRESOLVED_CW_RE.search(p) for p in _progs) \
                   or any(_is_shell_name(_bn(w))
                          for p in _progs for w in _lexed_words(p)) \
                   or any(_launcher_in_any_simple_command(p) for p in _progs):
                    last = i
        kdepth = max(0, kdepth + _group_delta(_words))
    if last is not None:
        out.append((" ;" + chr(10)).join(p[1] for p in pairs[start:last]))
    return out


def _shell_pieces(text):
    """Split one segment into bash WORDS and redirection OPERATORS, or None.

    shlex is not used here. It was, in four configurations, and each one broke on a
    different spelling -- every failure measured, either as an executing here-string that
    classified as a read or as an ordinary read refused:

      punctuation_chars=True   splits operators from flush text but BREAKS QUOTE STATE:
                               `x'<'` lexed to `x'`, `<`, `' . /dev/stdin <<< '`, so the
                               command behind the operand vanished into a token.
      punctuation_chars=False  keeps that quote intact but leaves the operator attached, so
                               `cat<<< '<helper>'` emitted `cat<<<` as a command word and
                               refused an ordinary read.
      both, blocking on either fail-closed, but inherits every over-block of the looser
                               one -- the `cat<<<` refusal above.
      either one, plus a quote-aware operator split afterwards
                               still loses a quote that OPENS MID-WORD and spans a space:
                               `x'a b'` lexes to `x'a` and `b'`, so only half the operand
                               was skipped and `b` took command position, hiding the `.`
                               that sources the payload.

    That last one is not a configuration problem: non-posix shlex simply does not carry
    quote state across whitespace, so no amount of post-processing recovers the word. The
    scan below does the whole job in one pass -- quotes, escapes, word breaks and operators
    -- which is the same three-state walk `_split_with_ops` and `_norm_for_scan` already
    run in this file, at a finer granularity. Bash's own rules, so the failures above close
    together rather than in sequence.

    Adjacency needs no reconstruction as a result: a bash word is whatever the scan
    accumulates between unquoted word breaks, so `'b''a''s''h'` is ONE piece and `ba s h`
    is three, with no run-joining heuristic to tune. An earlier version had to rebuild that
    from a token list and could not: a capped join was bypassable with free padding (`a`,
    twelve empty quoted fragments, then `w` and `k` never assembled `awk` inside the
    window), and an uncapped one joined across whitespace and refused `cat ba s h`.

    Returns ((pieces, opened_an_expansion), or None when quoting or an expansion is
    unterminated -- the caller treats that as unresolvable and blocks. The flag is reported
    from HERE, quote-aware, rather than re-derived by the caller: a substring test for
    `${`/`$(`/`<(` cannot tell an active expansion from the same characters written inside
    single quotes, and it over-blocked ordinary data reads such as
    `cat <<< '<helper> literal $('`.
    """
    pieces, buf, start, stack, saw_exp = [], [], -1, [], [False]
    in_s = in_d = esc = False
    i, n = 0, len(text)

    def _open(at, quoted):
        # Does an expansion START here? Returns the characters consumed, 0 if not, and
        # pushes the level it opens. STRUCTURED forms only -- a bare `$NAME` is not tracked
        # here at all. It was, briefly, and that was wrong twice over: it corrupted the scan
        # (callers read a nonzero return as "a level was opened" and adjust quote state on
        # it, so reporting consumption with no entry to close left a double-quoted string
        # unterminated) and it fed the wrong question, since `saw_exp` drives the
        # no-receiver terminator, whose concern is a mis-decided expansion BOUNDARY and a
        # bare parameter has none. Whether a payload is statically known is asked by
        # `_text_unresolvable` instead. ONE routine, called from the ordinary state, from
        # inside double quotes, and from inside another expansion -- the three had separate
        # copies and the copies disagreed: only the outer one knew that `$((` opens TWICE,
        # so an arithmetic expansion NESTED in a command substitution pushed one level and
        # its `))` popped the substitution as well, leaking the rest of the operand.
        # `quoted` is the double-quote state to restore when this level closes.
        def _inh():
            # Effective double-quote state INSIDE the innermost open frame. Each frame
            # carries it, so this never walks.
            return stack[-1][2] if stack else False

        c = text[at]
        if c == _BT:
            # BACKTICKS are a command substitution too, and they were not tracked at all --
            # their spaces and operators reached the outer tokenizer, which is the same
            # leak this scan exists to stop. They do not nest, so the next unquoted
            # backtick closes.
            stack.append((_BT, quoted, False))
            saw_exp[0] = True
            return 1
        if c in "<>" and at + 1 < n and text[at + 1] == "(":
            # PROCESS SUBSTITUTION. `<(cmd)` is one word to bash, and the `<` is not a
            # redirection -- reading it as one took `(cmd` for the target and let the rest
            # of the operand tokenize as outer text. Tested BEFORE the redirection regex
            # below, which would otherwise match the `<`.
            #
            # NOT INSIDE DOUBLE QUOTES, unlike `$(` and backticks: bash does not perform
            # process substitution there, so `"x<(y"` is literal text. Opening a level for
            # it pushed a `)` the string never closes, and a later quoted `)` anywhere in
            # the command closed it instead -- swallowing the command in between.
            # `A="x<(y" . /dev/stdin <<< P ")"` sources the payload and returned OK.
            #
            # EFFECTIVE quoting, not the caller's local flag. A PARAMETER expansion is not
            # a fresh quoting context -- `"${x:-a<(b}"` is inside double quotes all the way
            # through -- but opening its frame clears `in_d`, and the nested call passes
            # that cleared value down. So a literal `<(` in a parameter word read as a
            # process substitution again, and a later quoted `)}` drained the false level:
            # the real `<<<` was absorbed into a redirection operand, no here-string was
            # reported, and the payload went unscanned. That was the THIRD spelling of this
            # one bug, after the bare `(` inside `$( )` and the quoted `<(` above.
            #
            # A COMMAND substitution IS a fresh context (`$(printf "a b")` re-quotes
            # inside), so only `${` frames inherit -- see the push above, which records the
            # answer per frame. Two perf shapes were measured on the way to that: walking
            # the stack in FRONT of this character test made every character O(depth)
            # (13000 nested frames: 0.01s -> 2.2s), and walking it behind the test still
            # left O(depth x occurrences) for a word full of literal `<(` (depth 6000:
            # 1.03s, extrapolating to ~2.3s at the 65536-byte ceiling). Both matter because
            # a timed-out hook writes no decision, which reads as ALLOW.
            if not (quoted or _inh()):
                stack.append((")", quoted, False))
                saw_exp[0] = True
                return 2
        if c == "$" and at + 1 < n and text[at + 1] == "[":
            # `$[...]` is bash's LEGACY arithmetic form. It was only ever named in the
            # substring list the terminator used to consult; once that flag came from the
            # scan itself, the scan had to know the form too.
            stack.append(("]", quoted, False))
            saw_exp[0] = True
            return 2
        if c == "$" and at + 1 < n and text[at + 1] in "{(":
            # A PARAMETER expansion inherits the enclosing quoting; a COMMAND
            # substitution starts a fresh context. Recorded per frame at push time so the
            # `<(` test below is O(1): walking the stack for each occurrence instead was
            # O(depth x occurrences), measured 1.03s at depth 6000 and extrapolating to
            # ~2.3s at the 65536-byte scan ceiling -- inside a hook whose timeout writes no
            # decision and therefore ALLOWS.
            stack.append(("}" if text[at + 1] == "{" else ")", quoted,
                          (quoted or _inh()) if text[at + 1] == "{" else False))
            saw_exp[0] = True
            if text[at + 1] == "(" and at + 2 < n and text[at + 2] == "(":
                stack.append((")", False, False))
                return 3
            return 2
        return 0

    def _flush():
        if buf:
            pieces.append((False, "".join(buf), start))
            del buf[:]

    while i < n:
        ch = text[i]
        if esc:
            buf.append(ch)
            esc = False
        elif in_s:
            buf.append(ch)
            # ANSI-C QUOTING is UNRESOLVABLE here, so it blocks. Inside `$'...'` a backslash
            # escapes and an escaped quote does NOT end the string; inside plain `'...'` it
            # does. The difference is the `$`, and `_norm_for_scan` has already dropped it
            # upstream -- deliberately, because the shlex-based callers cannot model it. So
            # by the time this scan runs, `$'x\'y'` and `'x\'` `y'` are the same bytes.
            # Guessing was measured: reading it as a plain quote ended the string early,
            # left the rest of the command inside apparent quotes, and made a REAL `<<<`
            # after it look quoted -- the segment was skipped and
            # `bash -s $'x\'y' <<< '<helper>' \'` ran the payload while returning OK.
            # A backslash immediately before a closing quote is therefore treated as
            # unresolvable. The over-block it costs is a payload ending in a backslash.
            if ch == "\\" and i + 1 < n and text[i + 1] == _SQ:
                return None
            if ch == _SQ:
                in_s = False
        elif in_d:
            buf.append(ch)
            # EXPANSIONS ARE STILL ACTIVE INSIDE DOUBLE QUOTES, and the substitution has
            # its own quoting context: `"$(printf "a b")"` is one word, but ending the
            # outer quote at the INNER one resumed outer tokenizing mid-expansion. The
            # entry records the quote state to restore when the level closes.
            _k = _open(i, True)
            if _k:
                buf.extend(text[i + 1:i + _k])
                in_d = False
                i += _k - 1
            elif ch == "\\":
                esc = True
            elif ch == _DQ:
                in_d = False
        elif ch in ("\\", _SQ, _DQ):
            if not buf:
                start = i
            buf.append(ch)
            esc, in_s, in_d = ch == "\\", ch == _SQ, ch == _DQ
        elif stack:
            # INSIDE AN EXPANSION nothing is a word break and nothing is an operator.
            # `${x:-a b > y}` is ONE redirection operand to bash, but scanning it flat
            # ended the word at the space, promoted `b` to command position, read the `>`
            # as a real redirection and skipped `y}` as its target -- so the `.` that
            # sources the payload was never in command position and the here-string ran
            # unscanned. Nesting is counted rather than parsed: `${`/`$(` open, the
            # matching brace or paren closes, and `$((` simply opens twice. Getting the
            # depth wrong can only join MORE text into one word, which keeps a following
            # command in its own position.
            #
            # ONLY `$(` and `${` open a level. Treating every bare `(`/`{` as nesting was
            # wrong twice over: bash permits a LITERAL brace inside an expansion, so
            # `$(printf {)` pushed a level the real `)` then could not close -- and a later
            # `}` elsewhere in the command could drain it, resuming outer tokenizing at the
            # wrong place rather than failing closed. "Over-grouping only blocks" was an
            # overclaim; the fix is to count what the shell counts.
            buf.append(ch)
            # CLOSE BEFORE OPEN, because a backtick is its own closer.
            if ch == stack[-1][0]:
                in_d = stack.pop()[1]
            else:
                _k = _open(i, in_d)
                if _k:
                    buf.extend(text[i + 1:i + _k])
                    in_d = False
                    i += _k - 1
        elif ch == "#" and not buf:
            # A COMMENT runs from an unquoted `#` in WORD POSITION to the end of the line,
            # and bash lexes nothing inside it. `_defuse_comments` upstream blanks only the
            # SEPARATOR characters there and deliberately leaves every other byte in place,
            # so a `<<<` inside a comment still arrives here intact -- and read as an
            # operator it turned `bash -c true # <<< '<helper>'`, which runs no here-string
            # at all, into a shell receiving one. An empty `buf` is word position: it is
            # also what holds after a separator and after an operator, which is exactly
            # where bash starts a word.
            _nl = text.find("\n", i)
            i = n if _nl < 0 else _nl
            continue
        elif ch in _SH_BLANK:
            # An ESCAPED space never reaches here -- it is consumed by the branch above --
            # so `'x'\ y` stays one word, exactly as bash reads it. Reconstructing that
            # from a token list needed a backslash-parity rule; the scan gets it free.
            _flush()
        else:
            # The fd-prefixed operator form only where a word can START. Carrying the
            # optional `[0-9]+|&` everywhere ate the last character of a command NAME:
            # bash reads `source2<<< P` as the command `source2` redirected by `<<<`, but
            # `2<<<` matched as an fd redirection and left `source` in command position,
            # refusing an ordinary read as a `source`. Same for `bash2`, `/tmp/bash2`.
            _k = _open(i, False)
            if _k:
                if not buf:
                    start = i
                buf.extend(text[i:i + _k])
                i += _k
                continue
            m = (_REDIR_AT_RE if not buf else _REDIR_BARE_RE).match(text, i)
            if m:
                _flush()
                pieces.append((True, m.group(0), i))
                i = m.end()
                continue
            if not buf:
                start = i
            buf.append(ch)
        i += 1
    if in_s or in_d or esc or stack:
        return None            # unterminated quoting or expansion: unresolvable, block
    _flush()
    return pieces, saw_exp[0]


def _walk_words(text):
    # The command WORDS of a segment, redirections and their operands stepped over.
    # Returns (words, decoded words, raw pieces, ok) -- the three lists are PARALLEL, so a
    # caller can ask for a word's decoded name or its as-written spelling by index.
    # Shared by the per-segment path and the compound widening --
    # they each had their own copy of this walk, and a copy that drifts is what the
    # unified receiver predicate exists to stop.
    _r = _shell_pieces(text)
    if _r is None:
        return [], [], [], False
    pieces = _r[0]
    words, dwords, raws, skip_next = [], [], [], False
    for is_op, t, _i in pieces:
        # Redirections are stepped over while locating command words, because bash accepts
        # them BEFORE the command: `<<<'<helper>' sh` is a real spelling, and reading
        # words[0] would resolve the command word to the operator.
        if is_op:
            skip_next = True
            continue
        if skip_next:
            # The operand is ONE piece, because the scan already grouped the whole word --
            # `<<< 'lease_'"slot.py" . /dev/stdin` no longer arrives in fragments whose
            # tail would take command position and hide the `.` that sources the payload.
            skip_next = False
            continue
        # Quoting AND ESCAPES squeezed, not just outer-stripped: `b'a's'h'` and `b\a\s\h`
        # are both valid command-word spellings of bash, and an outer-strip left each
        # matching no name. Same squeeze the helper probe applies to its own text.
        sq = t.replace("'", "").replace('"', "").replace("\\", "")
        words.append(sq)
        # ANSI-C ESCAPES ARE DECODED TOO, as an ADDITIONAL word. Squeezing backslashes
        # away resolves `b\a\s\h`, where each one escapes a letter that is already
        # itself -- but not `$'\x62ash'`, where bash DECODES `\x62` to `b`. Stripping
        # there left `x62ash`, which matches no shell, and the here-string executed bash
        # while the classifier called it a read. (`_norm_for_scan` has already dropped the
        # `$`, so nothing downstream can tell the two spellings apart by shape.)
        # BOTH forms are kept rather than one replaced: decoding alone breaks the first
        # case, since `\a` is a real escape (BEL) and `b\a\s\h` stops resolving to bash.
        # Additive, the same rule `_shell_variants` states -- over-decoding can only make
        # more text match, so it adds blocks and never removes one. Extras are returned
        # SEPARATELY because they must not shift command position or make a reserved-only
        # segment look like it carries a command.
        # PARALLEL, one decoded entry per word, not a bag of extras. Command position is a
        # POSITION, and `.`/`source` are recognised only there -- they are deliberately
        # absent from _SHELL_NAMES, because an any-word match over-blocked the bare word
        # `source` used as a grep pattern. Appending decoded forms to the end of one list
        # therefore could not reach that test at all, and `$'\x2e' /dev/stdin <<< P`
        # sourced the payload while classifying as a read. Keeping the lists aligned lets
        # the caller ask for command position in BOTH spellings.
        dec = sq
        if "\\" in t:
            # Quotes squeezed, BACKSLASHES NOT: after decoding, a surviving backslash is
            # DATA, not an escape. `$'\x62a\x5csh'` is `ba\sh` to bash -- no shell at all
            # -- and stripping the decoded `\` collapsed it to `bash` and refused a read.
            dec = _decode_escapes(t).replace("'", "").replace('"', "")
        dwords.append(dec)
        raws.append(t)
    return words, dwords, raws, True


def _herestring_words(text):
    # (here-string present?, command words, ok). The operator must be a REAL one: a quoted
    # `<<<` is an ARGUMENT, and reading it as an operator broke both directions --
    # `echo '<<<' '<helper>' sh` carries no here-string and over-blocked, while
    # `bash -s '<<<' <<< '<helper>'` had the quoted operand taken for the operator,
    # consuming the real one so the payload was never scanned. The scan settles it: a
    # quoted operator is inside a word piece and never becomes an operator piece.
    _r = _shell_pieces(text)
    if _r is None:
        return False, [], [], [], False
    pieces = _r[0]
    if not any(op and "<<<" in txt for op, txt, _ in pieces):
        return False, [], [], [], True
    words, dwords, raws, ok = _walk_words(text)
    return True, words, dwords, raws, ok


def _cmd_position(words, raws=None):
    # The word in COMMAND position: wrappers and reserved syntax peeled, falling back to
    # the raw first word when nothing survives the peel. One copy, because the compound
    # caller needs the same derivation per segment and a second copy of a one-line rule
    # is what let the two receiver predicates drift apart in the first place.
    #
    # `time` is peeled with _strip_time_prefix, the SAME peel the stdin-producer callers
    # use (#562), not a local filter. It is a shell KEYWORD absent from both _WRAPPER_CMDS
    # and _RESERVED_SH, so the bare peel returned `time` itself and the command-position
    # `.`/`source` test never reached the dot: `time . /dev/stdin <<< '<helper>'` sourced
    # the payload and classified as a read. Reusing that peel also keeps the two
    # distinctions it already makes and a `!= "time"` filter threw away -- the bare
    # keyword is peeled, `/usr/bin/time` (which cannot source anything) is not, and a
    # compound introducer such as `then` or `{` does not hide the `time` behind it.
    # ...but only in PIPELINE-PREFIX position. `_strip_time_prefix` walks the same leading
    # tokens `_peel_wrappers` does, which includes wrapper COMMANDS -- and after one of
    # those, `time` is an external program, not the keyword. `env time . /dev/stdin <<< P`
    # runs `env`, so nothing sources the payload, but peeling the `time` promoted the `.`
    # to command position and refused a data-only read. Reserved syntax may still precede
    # it: a compound arrives as `then time source /dev/stdin`, which the helper's own
    # not-index-0 rule exists for. Whether the word is the KEYWORD or a path such as
    # `/usr/bin/time` stays the helper's call.
    # ...and only when the word is BARE. Bash recognises a reserved word before quote
    # removal, so `'time'` and `t\ime` are the external program, not the keyword -- the dot
    # behind them is an argument and sources nothing. The walk has already squeezed quotes
    # and backslashes out of `words`, so the raw piece is what says which it was.
    def _bare(k):
        # Quote removal happens AFTER bash decides grammar, and the walk has already
        # squeezed quotes and backslashes out of `words`, so the raw piece is the only
        # thing left that says whether a word was written bare.
        return raws is None or not any(c in raws[k] for c in ("'", '"', "\\"))

    # The reserved-word skip needs the same test as the `time` peel below it. `'then'` is
    # an ordinary external command, not shell syntax, so skipping it walked past a real
    # command word, stripped the `time` behind it, and promoted a `.` that sources nothing.
    # EXACT words, not basenames: reserved words are syntax the shell recognises literally,
    # so `./then` is a path to an executable named `then` and `./time` is a program, not
    # the keyword. Matching on the basename treated both as grammar, walked past a real
    # command word, and promoted a `.` that sources nothing.
    _j = 0
    while _j < len(words) and words[_j] in _RESERVED_SH and _bare(_j):
        _j += 1
    # The spellings travel THROUGH the peel, not up to it. `_strip_time_prefix` removes
    # tokens, so it reports which survived and the raws are filtered the same way; dropping
    # them here instead restored the basename reading for everything behind a `time`.
    _w, _r = words, raws
    if _j < len(words) and words[_j] == "time" and _bare(_j):
        if raws is None:
            _w = words[:_j] + _strip_time_prefix(words[_j:])
        else:
            _tw, _tr = _strip_time_prefix(words[_j:], raws[_j:])
            _w, _r = words[:_j] + _tw, raws[:_j] + _tr
    return _peel_wrappers(_w, _r) or (_w[0] if _w else None)


def _cmd_candidates(words, dwords, raws=None):
    # The command-position word, in both spellings. POSITION is decided on the RAW words
    # and only the NAME is compared decoded, because bash resolves shell grammar BEFORE it
    # expands: `$'\x74ime'` is not the `time` keyword, it is a command whose name happens
    # to expand to `time`. Running the peel over the decoded list gave decoded words
    # grammar semantics and stripped that `time`, promoting the `.` behind it and refusing
    # a data-only read. The index is recovered by lookup rather than threaded through --
    # `_cmd_position` always returns an element of `words`, and equal words decode equally,
    # so a duplicate resolving to an earlier index yields the same candidate.
    w0 = _cmd_position(words, raws)
    if w0 is None:
        return []
    try:
        k = words.index(w0)
    except ValueError:
        return [w0]
    return [w0] if dwords[k] == w0 else [w0, dwords[k]]


def _herestring_receiver(cw_words, text, cmd_words=None):
    # Does anything here EXECUTE what a here-string feeds it? ONE predicate, called
    # from both the per-segment walk and the compound widening below. The two began as
    # separate copies and had already diverged: the compound copy tested only staged
    # names and launchers, so a fragmented name, an attached option bundle, an
    # unresolved command word and command-position `.`/`source` each RAN the payload
    # from inside a compound while classifying as a read. Divergence between two copies
    # of one rule is what the `KEEP IN STEP WITH ...` notes elsewhere in this file are
    # paying for; a single callee costs nothing to keep in step.
    #
    # `text` is what the launcher disjunct reads, and it is deliberately NOT the same
    # string for the two callers: the per-segment call passes the joined COMMAND WORDS,
    # never the segment, because the here-string PAYLOAD is in the segment and a payload
    # naming an interpreter made `cat <<< '...'` look like it had a shell receiver. The
    # compound call passes the RAW join of every segment, payload included. That is a
    # real asymmetry, not a symmetry -- only the WORD list is assembled redirection-aware.
    # It is left as-is because it can only ever over-block: a payload that names a
    # launcher inside an otherwise data-only compound blocks a read. Same accepted
    # direction as the `-c` and unlexable cases above, and narrowing it means deciding
    # which text in a compound is payload, which is the operand reconstruction this walk
    # refuses on purpose.
    #
    # `cmd_words` is the COMMAND-POSITION words, one per segment, and the compound caller
    # must pass its own. Deriving them here from the flat word list cannot work for a
    # compound: `_peel_wrappers` returns the first EXECUTING word of the whole list, so
    # `if true; then . /dev/stdin; fi <<< '<helper>'` resolved to `true` and the `.` that
    # sources the payload was never in command position at all. Measured: it allowed.
    # The receiver test is the SAME WIDE TEST the pipe transport uses, not a peel to a
    # single command word. Peeling was narrower three ways, each measured as an
    # executing here-string that classified as a read:
    #   `env -u X sh <<< ...`      -- the peel skips `env` and `-u`, then takes the
    #                                 option VALUE `X` for the command word. That is
    #                                 the option-arity question this file refuses to
    #                                 answer, and answering it wrong fails OPEN.
    #   `/bin/ba{s..s}h <<< ...`   -- brace expansion resolves to a shell the text
    #                                 never spells, so an exact-name test reads a
    #                                 command word no set contains.
    #   `script -q /dev/null <<< ...` -- an implicit launcher execs the user's shell
    #                                 with no shell NAME anywhere in the segment.
    # So: a shell name ANYWHERE in the non-redirection words counts, an UNRESOLVED
    # command word counts (fail closed -- it may expand onto a shell), and a launcher
    # counts. Same three disjuncts, same helpers, same order as the producer walk
    # above. Keeping the two transports on one test is the point: any narrowing here
    # lets a here-string through that the identical pipe spelling blocks.
    # This also subsumes the `xargs` case -- it is in the stdin-shell set, and the
    # any-word test never consumed it as a wrapper the way the peel did.
    # _stage_words, not the raw tokens: an option can carry its value ATTACHED and
    # BSD/macOS `env -S` plus a quoted program lexes to ONE token whose first word
    # matches no shell, so `env -Sbash <<< '<helper>'` executed while reading as a
    # non-shell. This is the same expansion the producer walk applies to a piped stage.
    _sw = list(_stage_words(cw_words))
    # Command position for `.` and `source`. Both are deliberately ABSENT from
    # _SHELL_NAMES -- an any-word match there cost a real over-block on the bare word
    # `source` appearing as a grep PATTERN -- so they are tested HERE, in command
    # position only, exactly as the pipe path tests them. `. /dev/stdin <<< '<helper>'`
    # sources what the here-string feeds.
    if cmd_words is None:
        cmd_words = [_cmd_position(cw_words)]
    # The ATTACHED OPTION BUNDLE, copied from the producer disjunct rather than
    # approximated: peeling one option letter off `-iSbash` leaves `Sbash`, and
    # peeling a fixed number never terminates because the caller chooses the bundle
    # length, so the test is an endswith over the names. `env -iSbash <<< ...` ran
    # bash while the pipe spelling of the same thing already blocked.
    return bool(
        any(_is_shell_name(_bn(w)) for w in _sw)
        or any(w.startswith("-")
               and (any(w.endswith(n) for n in _SHELL_NAMES)
                    or _ATTACHED_INTERP_RE.search(w))
               for w in _sw)
        or any(_UNRESOLVED_CW_RE.search(w) for w in _sw)
        or any(w is not None and _bn(w) in (".", "source") for w in cmd_words)
        or _launcher_in_any_simple_command(text))


def _herestring_shell_payloads(pairs):
    # A here-string feeding a shell runs its operand, so that operand is a PROGRAM.
    # `sh <<< '<helper>'` executed while returning OK, and the equivalent pipe spelling
    # `echo '<helper>' | sh` blocked -- the same invocation, one transport apart (#643).
    # _piped_shell_producers only yields text for a PIPELINE stage; a here-string has no
    # producer segment at all, because the payload is the operand of `<<<` on the shell's
    # own command line, so nothing was yielded and the payload was never scanned. The
    # guard is UNCONDITIONAL, so that was a straight bypass, not a degraded-mode gap.
    #
    # The asymmetry ran one way only: cmdword already closed `<<<` in its stdin-fed
    # shell-source branch; this copy -- the one the helper guard consults -- had not.
    # KEEP IN STEP WITH cmdword._piped_shell_producers and that branch.
    #
    # Predicate is _is_shell_name, the WIDE set the pipe transport already uses, NOT
    # cmdword's narrower _SHELLS. A here-string is the same stdin transport as a pipe, so
    # the two must not diverge: `xargs` is in that set deliberately (see the _SHELL_NAMES
    # note and tests/test-impl-gate-scope-519.sh, which pin the same fail-CLOSED direction
    # for the pipe), and narrowing here would let one transport allow what the other blocks.
    #
    # No option-arity table, so `sh -c 'prog' <<< '<helper>'` OVER-blocks: with -c the
    # here-string is only stdin data. Deciding that needs to know whether a shell reads
    # stdin from its FLAGS, which is the question this file refuses to answer -- it failed
    # open four ways when tried (`bash --norc` read as "-c present", `bash --rcfile -c`
    # read the VALUE of --rcfile as the option). The over-block is the chosen direction.
    out = []
    # The compound answer is a property of the WHOLE command, not of a segment, so it is
    # computed AT MOST ONCE and the widening happens once. Recomputing it per reserved-only
    # segment re-lexed everything each time: 1,000 data-only compounds took ~23s, past the
    # 5s hook timeout that writes no decision and therefore reads as ALLOW.
    #
    # WHOLE COMMAND, NOT THE OWNING COMPOUND'S SPAN. Limiting the scan to the segments a
    # here-string can actually reach is more precise, and it was built and measured: match
    # the opener on a typed stack, scan only `pairs[opener:closer]`. It is not here because
    # it bought precision and paid in the two failure classes this module refuses:
    #   FAIL-OPEN. Deciding structure from words needs to know COMMAND POSITION, and this
    #     walk has none. In `if sh; then echo if; fi <<< '<helper>'` the ARGUMENT `if`
    #     pushes a false opener, `fi` pops it, the span closes short of `sh`, and the
    #     payload ran while the classifier said OK. Fixing that is the parser this module
    #     refuses everywhere else.
    #   QUADRATIC. Each closer rebuilds its own span, and nested compounds make spans grow
    #     with depth: 150 nested data-only compounds took 1.05s and 300 took 3.36s, heading
    #     straight through the 5s timeout that reads as ALLOW. Per-segment lex memoization
    #     does not help -- the cost is in the spans, not the lexes.
    # Scanning everything is O(1) amortized and its failure direction is an over-block:
    # `echo sh; if true; then cat; fi <<< '<helper>'` refuses a data-only read because of
    # the unrelated `sh` in front. That is the direction this module accepts throughout.
    _compound_receiver = None
    # Computed ONCE, over the WHOLE command rather than per segment: `_split_with_ops` does
    # not track expansions, so a `;`, `|` or `&` written inside one is taken for a command
    # separator and the expansion is torn across segments -- after which the piece carrying
    # the here-string holds no opener at all. `< ${BASH:-a;b|c&d} . /dev/stdin <<< P` is
    # exactly that shape, and a per-segment test missed it.
    # LAZY, both of them. A command with no here-string must charge NOTHING: the prefilter
    # below exists because tokenizing every segment cost 4.37s on a 60000-token payload
    # against a 3.5s budget -- and that budget exists because the hook's 5s timeout writes
    # no decision, which reads as ALLOW, so a slow scanner is itself a fail-open. Joining
    # the command and scanning it eagerly put that cost back for every command in the repo.
    _lazy = {}

    def _cmd_expansion():
        # (whole-command text, does it OPEN an expansion?), computed at most once.
        #
        # QUOTE-AWARE, from the scan itself rather than a substring search: a substring test
        # cannot tell an active expansion from the same characters inside single quotes, and
        # it over-blocked `cat <<< '<helper> literal $('`, a plain data read where bash
        # expands nothing. Unresolvable text counts as an expansion -- that is the
        # fail-closed answer anyway.
        if not _lazy:
            # Rejoined on a NEWLINE, not on " ; ". Both are separators to bash, but only
            # the newline ENDS A COMMENT, and `_norm_for_scan` has already turned the
            # command's own newlines into " ; " before this walk ever sees it. Joining on
            # " ; " therefore hands `_shell_pieces` a single line whose first `#` runs to
            # the end of everything -- and `_shell_pieces` tracks comments, so it lexed
            # nothing after it and reported no expansion. Measured:
            # `# p<newline>< ${BASH:-a;b|c&d} . /dev/stdin <<< '<helper>'` returned OK|
            # with the " ; " join and BLOCK_MARKER_SCRIPT without the comment -- a
            # one-line preface disarming the terminator. Raised by codex on this change.
            # `_defuse_comments` does not cover this: it deliberately blanks only the
            # SEPARATOR characters inside a comment and leaves the `#` itself in place.
            _t = chr(10).join(_s2 for _o2, _s2 in pairs)
            _r0 = _shell_pieces(_t)
            _lazy["t"] = _t
            # No IFS special case is needed HERE any more, but NOT because this scan
            # flags it: `_open` tracks only STRUCTURED expansions, and normalization emits
            # the BARE `$IFS`, which sets no flag. What changed is that the expansion is
            # separated rather than erased, so it is still standing for
            # `_inner_expands`/`_text_unresolvable` -- which scan raw text for a `$` -- to
            # find. While it was erased, `IFS='<helper>'; sh <<< "$IFS"` read as a payload
            # of `" "`. The no-receiver terminator here does not widen on a bare `$IFS`,
            # and does not need to: a separated token cannot glue a receiver out of view,
            # which is the only thing this terminator guards against.
            _lazy["e"] = True if _r0 is None else _r0[1]
        return _lazy["t"], _lazy["e"]
    for _op, seg in pairs:
        # CHARGE NOTHING when there is no here-string. Tokenizing every segment to look
        # for one cost 4.37s on the 60000-token payload in tests/test-impl-gate-scope-519.sh
        # against its 3.5s budget -- and that budget exists because the hook's 5s timeout
        # reads as ALLOW, so a slow scanner is itself a fail-open. The operator cannot be
        # spelled any other way (no expansion produces `<<<`, and shlex would have to run
        # to find one), so a raw substring test is exact here, not a heuristic.
        # Line continuations need no handling here: the only caller builds `pairs` from
        # _split_with_ops(_norm_for_scan(cmd)), and _norm_for_scan has already removed
        # every backslash-newline -- measured, `sh <<\` + newline + `< 'x'` arrives as
        # `sh <<< 'x'`. An explicit strip here was redundant and cost a scan of every
        # segment ahead of the cheap prefilter below.
        if "<<<" not in seg:
            continue
        _has_hs, cw_words, _dwords, _raws, _ok = _herestring_words(seg)
        _extras = [d for w, d in zip(cw_words, _dwords) if d != w]
        if not _ok:
            # FAIL CLOSED, and accept the over-block. Provenance is unknown here, and
            # deciding it without a lexer means writing one: a quote-state scan was tried
            # and review walked it straight onto the ladder this module refuses -- escaped
            # quotes inside double quotes, then comments, each rung a new fail-open. Both
            # blanket answers were measured instead, and only one is survivable:
            #   skip   -> `bash -s <<< '<helper>' a'<<<'` executes the payload UNSCANNED.
            #   append -> `echo a'<<<' <path>` blocks although it carries no here-string.
            # The over-block is what this module accepts throughout (see the `-c` case).
            # The population is narrow: input the OUTER split accepted but shlex rejected.
            # A genuinely unparseable command never arrives here -- _split_with_ops returns
            # ok=False and _helper_invoked probes the whole command instead.
            #
            # THE WHOLE COMMAND, not this segment. Unresolvable here usually means the OUTER
            # split already cut in the wrong place: `_split_with_ops` does not track
            # expansions, so a `;`, `|` or `&` written INSIDE one is taken for a command
            # separator and the operand is torn across segments. The piece holding the
            # opener is the one that arrives unterminated, and probing only that piece
            # scanned a fragment with no helper name in it while the receiver sat in a later
            # segment: `<<< ${x:-a;b|c&d} . /dev/stdin <<< P` sourced the payload and
            # returned OK. Widening to the command is the same fail-closed answer the
            # compound path gives.
            out.append(_cmd_expansion()[0])
            break
        if not _has_hs:
            continue          # every `<<<` here is quoted: an argument, not a redirection
        # AN EXPANSION MAKES "NO RECEIVER" MEAN "UNKNOWN", NOT "SAFE". This TERMINATES a
        # ladder rather than climbing it. Every leak in this walk has the same shape: the
        # scan mis-decides where an expansion ends, a word or operator escapes it, and the
        # command that would have been in receiver position is hidden. Review found one per
        # round -- `${}`, `$()`, `$(())` nested inside `$()`, backticks, `$[`, a `(` group
        # inside `$()` -- and each fix exposed the next construct, which is exactly the
        # unbounded problem this file refuses elsewhere.
        #
        # So the scan's precision is kept for the BLOCK side, where it earns its keep (it
        # is what stops `cat ba s h` and `cat<<<` from over-blocking), and its ALLOW side is
        # no longer trusted alone: if the segment opens a structured expansion at all and
        # the receiver test came back empty, the whole command is probed instead. No future
        # expansion syntax can turn that into a fail-open, because the answer no longer
        # depends on parsing the expansion correctly.
        #
        # The over-block it costs is narrow and needs BOTH halves: a command that opens an
        # expansion AND names a mutating helper somewhere in its text, e.g.
        # `cat <<< "$(date) <helper>"`. A payload with an expansion and no helper name is
        # unaffected, and so is a helper-naming payload with no expansion.

        # THE OPERAND IS NEVER RECONSTRUCTED. Taking it to be "the token after `<<<`" put
        # this walk on a ladder of bash word-splitting rules, each rung a measured
        # fail-open: adjacent quoted fragments concatenate into one word, escaped
        # whitespace joins words (`<<< a\ b`), and an escaped punctuation argument (`\<`)
        # lexes as separate tokens whose `<` was taken for a redirection that then consumed
        # the real `<<<`. Reproducing bash's lexer to settle those is the unbounded problem
        # this module refuses elsewhere.
        #
        # So the operand is not extracted at all. Existence of a genuine bare `<<<` plus a
        # receiver that executes its stdin is enough: the payload is SOMEWHERE in this
        # segment, so the whole segment goes to the probe. Every spelling above collapses,
        # because none can hide the helper NAME from a scan of the text containing it.
        # Widening to the segment also subsumes the unresolved-operand case
        # (`sh <<< "$VAR"`), which the caller previously widened by hand.
        #
        # This does not widen who is affected: a segment whose receiver does not execute
        # stdin is never probed at all, so `cat <<< 'prose naming the helper'` reads as data.
        # EVERY operand in the segment, not just the last: modelling "last redirect wins"
        # buys nothing here, and any-hit-blocks is the fail-closed reading.
        # COMPOUND COMMANDS. A redirection can attach to a whole compound, so in
        # `if true; then sh; fi <<< '<helper>'` the shell that consumes stdin is in an
        # EARLIER segment and the segment holding `<<<` has only `fi`. When the words left
        # here are nothing but reserved syntax -- or NONE at all, which is how a
        # parenthesised receiver arrives, because `(sh) <<< '<helper>'` puts the parens in
        # the operator and leaves this segment wordless -- the receiver is elsewhere and
        # this segment cannot answer the question. Requiring a NONEMPTY word list was
        # exactly that bypass: the subshell spelling executed the payload and returned OK.
        # EXACT and BARE, the same rule `_cmd_position` applies: `echo sh; 'fi' <<< P` and
        # `echo sh; ./fi <<< P` run an external command named `fi`, so the here-string is
        # attached to THAT command and there is no compound to widen to. Reading them as
        # syntax widened to the whole command, where the unrelated `sh` blocked the read.
        _only_reserved = all(_reserved_word(w, r) for w, r in zip(cw_words, _raws))
        if _only_reserved:
            # Ask the SAME question of the whole command rather than widening blind: an
            # unconditional widen blocked `if true; then cat; fi <<< '<helper>'`, where the
            # enclosed command only reads the payload as data. Same predicate, same
            # redirection-aware walk, over every segment -- and never a raw split, because
            # that would include the here-string PAYLOAD and a payload naming an
            # interpreter made a `cat` receiver look like a shell.
            if _compound_receiver is False:
                continue
            if _compound_receiver is None:
                _allw, _allcw = [], []
                # SEPARATED, not space-joined. The operator run `_o2` is not carried on
                # the segment text, so joining with a space erased every command boundary
                # -- and the launcher disjunct re-splits this text with
                # `_split_simple_commands` before testing COMMAND POSITION. With the
                # boundaries gone the segments merged into one simple command, the first
                # word won command position, and a launcher behind it was never seen:
                # `if true; then unshare; fi <<< P` peeled `if`, stopped at `true`, and
                # returned OK while unshare exec'd a shell on the payload. Launchers are
                # deliberately absent from _SHELL_NAMES, so no other disjunct catches them.
                # The payload emitted below already used `" ; "`; these two now agree.
                _alltext = (" ;" + chr(10)).join(_s2 for _o2, _s2 in pairs)
                for _o2, _s2 in pairs:
                    # `_walk_words` regardless of whether THIS segment holds the operator:
                    # the receiver is in a different segment, which is the whole reason
                    # the scan widened.
                    _segw, _segd, _segr, _ok2 = _walk_words(_s2)
                    if not _ok2:
                        _allw, _allcw = ["sh"], []   # unlexable inside: fail closed
                        break
                    _allw.extend(_segw + [d for w, d in zip(_segw, _segd) if d != w])
                    _allcw.extend(_cmd_candidates(_segw, _segd, _segr))
                _compound_receiver = _herestring_receiver(_allw, _alltext, _allcw)
            if not _compound_receiver:
                _t, _e = _cmd_expansion()
                if not _e:
                    continue
                out.append(_t)
                break
            # ONCE, then stop. Appending the whole command per reserved-only segment is
            # quadratic: 1,000 small compounds took 8.88s, past the 5s hook timeout -- and
            # a timed-out hook writes no decision, which reads as ALLOW. Widening once
            # already covers every segment, so there is nothing left for a second copy to
            # find and the loop can end here.
            out.append((" ;" + chr(10)).join(_s2 for _o2, _s2 in pairs))
            break
        if _herestring_receiver(cw_words + _extras, " ".join(cw_words + _extras),
                                _cmd_candidates(cw_words, _dwords, _raws)):
            # A CONFIRMED receiver widens on an expansion too, exactly as the `else` branch
            # below does. The note further down -- that an unresolvable operand needs no
            # special case because "the scan already covers the text it sits in" -- is true
            # only WITHIN a segment. It reasoned from `sh <<< "$VAR" # <helper>`, where the
            # name shares the segment, and missed that an earlier segment of the SAME
            # command can hold the value: `P='<helper>'; sh <<< "$P"` probed only
            # `sh <<< "$P"`, found no name, and returned OK while sh executed the helper.
            # That is a bypass of an UNCONDITIONAL guard, the same class as #643 itself.
            #
            # The documented `-` / /dev/fd/N residual is untouched and still correct: what
            # a variable holds from OUTSIDE the command is not statically visible, so a
            # bare `sh <<< "$VAR"` naming the helper nowhere still allows. What changes is
            # only that the search for the name now covers the whole command it was
            # assigned in. Once, then stop, for the quadratic reason given above.
            # THIS SEGMENT, not `_e`. `_cmd_expansion` answers for the WHOLE command, which
            # is right for the no-receiver branch below (nothing there identifies a segment
            # to blame) and wrong here: an unrelated `echo "$X"` elsewhere made a confirmed
            # receiver widen and turned a benign `cat <helper>` into a block. The segment
            # holding the here-string is exactly what decides whether ITS payload is known.
            #
            # And the question is what the RECEIVING shell gets. This receiver executes the
            # payload, so the operand is source code a second shell parses and expands
            # again -- outer quoting says nothing about it.
            _t, _e = _cmd_expansion()
            if _text_unresolvable(seg):
                out.append(_t)
                break
            out.append(seg)
        else:
            _t, _e = _cmd_expansion()
            if _e or _locale_string[0]:
                # `_locale_string` as well, because translation can produce the RECEIVER
                # and not only the payload. With a catalog mapping it, `$"runner" <<< P`
                # execs a shell while this segment shows the ordinary-looking word
                # `runner` -- the `$` having been dropped during normalization -- and no
                # disjunct matches. The payload-side check does not reach it: that runs
                # only after a receiver has been recognised, which is exactly what fails
                # here.
                out.append(_t)
                break
    return out


def _names_helper(text):
    # Which mutating helper does this text NAME, quotes resolved? A raw substring test
    # is defeated by quote concatenation -- the shell runs `lease_"slot.py"`, but the
    # text holds no contiguous `lease_slot.py` -- which is the same defeat that made
    # the rest of this detector tokenize. Tokenizing first resolves it; the substring
    # test stays as the backstop, since it is WIDER and only ever adds a block.
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        hit = next((t for t in lex if _bn(t) in _MUTATING_HELPERS), None)
        if hit:
            return _bn(hit)
    except ValueError:
        pass
    hit = next((h for h in _MUTATING_HELPERS
                for v in _shell_variants(text) if h in v), None)
    if hit:
        return hit
    # SQUEEZED backstop: the shell joins a name across ANSI-C quoting
    # (`lease_$'slot.py'`), which shlex does not implement, and across PATHNAME
    # EXPANSION (`lease_slo[t].py`), which no static reader can evaluate. Dropping the
    # quoting and glob characters can only make more text match, never less, so it
    # adds blocks and never removes one.
    squeezed = text
    for _ch in ("$", chr(39), chr(34), "*", "?", "[", "]"):
        squeezed = squeezed.replace(_ch, "")
    return _helper_substring(squeezed)


def _abandoned_scan_probe(text):
    """Widest cheap probe for a helper NAME, for the paths where the walk cannot run.

    _names_helper alone is not enough. Its squeezed backstop DELETES glob characters, so
    `lease_slo[t].py` collapses to `lease_slot.py` and hits, while `lease_slo?.py`
    collapses to `lease_slo.py` and misses: the `?` stands FOR a character rather than
    beside one, and deleting it removes the very character that has to be there. So each
    whitespace-separated word is also asked, as a PATTERN, whether the shell could expand
    it onto a helper -- which is the question _glob_helper already answers for the
    parseable path.

    _glob_helper_TARGETED, though, not _glob_helper: this text has no structure, so a word
    here is as likely to be prose as an operand, and a pattern that matches every filename
    ever written says nothing about the helper (#573). See that docstring for the residual
    that buys.

    Over the SHELL VARIANTS, not the raw text: splitting `echo 'python3 lease_slo?.py'`
    leaves the quote glued to the word, so the pattern read as `lease_slo?.py'` and matched
    the helper nowhere -- a piped payload naming a globbed helper measured ALLOW (#640).
    The substring backstop in _names_helper already asks the variants; this tail was the one
    path that did not. `text` is itself a variant, so this only ever adds a match.

    And cut on the OPERATORS as well as on whitespace, which is the same defect one
    character further along: the shell separates `lease_slo?.py;` into a word and a `;`
    before it globs, while a whitespace-only split hands fnmatch a pattern with the
    terminator still in it -- so `;`, `&&`, `(`, `)` and a redirect each restored the bypass
    the quote fix closed. BOTH splits are asked, never the operator one alone: an operator
    character is legal inside a bracket expression, so cutting there halves
    `lease_slo[;t].py` -- a pattern that DID block -- and the swap would have been a wash.
    Testing the union is what makes this monotone. Both raised by codex on #640.

    ACCEPTED OVER-BLOCK, and it is the ticket's own trade rather than a new cost: a payload
    that merely QUOTES a globbed helper name as data -- `echo "printf '%s' 'lease_slo?.py'" | sh`,
    which only prints it -- now blocks. Nothing static can tell print from run once the text
    is inside an opaque payload, which is why this probe is the widest one and reads its
    input as structureless. Measured against the pre-#640 classifier, the LITERAL spelling
    of that same payload already blocked; only the glob spelling walked through. So this
    aligns the two rather than opening a class, and the #573 release rule is what keeps a
    wildcard in ordinary prose from paying for it. Raised by codex on #640.
    """
    hit = _names_helper(text)
    if hit:
        return hit
    return next((h for v in _shell_variants(text)
                 for w in v.split() + _OPERATOR_SPLIT_RE.split(v)
                 if any(c in w for c in "*?[")
                 for h in [_glob_helper_targeted(w)] if h), None)


def _helper_invoked(cmd, _depth=0, _full=None):
    # Which gate-state helper does this command RUN, if any? Token-level, per simple
    # command -- a raw substring test over the whole string was defeated two ways:
    # quote concatenation (lease_"slot.py" contains no matching substring, yet the shell
    # runs it), and a trailing `; : --self-check` that satisfied a whole-string exemption
    # while the FIRST segment mutated the real ledger. Segmenting and tokenizing makes
    # both spellings resolve to the same token, and scopes the exemption to the segment
    # that actually carries it.
    # RESIDUAL, same class the verb scan above declares out of scope: a name the shell
    # ASSEMBLES at run time. Quote concatenation, ANSI-C quoting and globbing are
    # squeezed out below because that is cheap; a brace RANGE is not
    # (`lease_slo{t..t}.py` yields the name only by expanding it), and neither is a name
    # built from variables. It reaches the `-m` operand on the same terms: an
    # unresolvable operand is answered by searching the command for a helper STEM, which
    # finds `M=lease_slot` but not `A=lease; B=slot; python3 -m "${A}_${B}"` or
    # `-m lease_{slot,x}`. Closing one spelling would not close the class -- the same
    # actor writes `python3 -c "$(cat lease_slo{t..t}.py)"`, where the name is equally
    # invisible -- so this stays documented rather than half-chased. See ADR 0006.
    #
    # The command as the OPERATOR typed it. A payload is re-entered on its own, so the
    # stdin check below -- which needs the redirect that feeds the payload, and that
    # redirect lives OUTSIDE it -- has to read the outer text, not this fragment.
    _whole = cmd if _full is None else _full
    if _depth == 0:
        _helper_budget[0] = _HELPER_MAX_TOKENS
        _paren_hash_ambiguous[0] = False
        _locale_string[0] = False
    if _PROC_SUBST_RE.search(_whole) and _INTERP_RE.search(_whole):
        hit = _names_helper(_whole)
        if hit:
            return hit
    if _depth > 3:
        # Fail CLOSED, for the same reason the token budget does. This was left returning
        # the bare probe when the other two abandonment paths were converted, which is an
        # inconsistency an attacker only has to find once: four nested `sh -c` layers
        # around a GLOBBED helper name (`lease_slo[t].py`) reach here, match no literal
        # stem, and measured ALLOW against the unconditional guard. Depth exhaustion is
        # not "no helper found" any more than budget exhaustion is.
        return _helper_substring(cmd) or _HELPER_UNSCANNED
    # Bash resolves ANSI-C quoting BEFORE it resolves the command word, so any token can
    # reach shlex still encoded -- not just the operand. A hex-escaped SWITCH resolves to
    # -m, and a scan for a literal `m` in the option token missed it entirely.
    # Re-entering on the resolved text puts every downstream comparison on what bash will
    # actually see; additive, so it can only add a block.
    _resolved = _ansi_c(cmd)
    if _resolved != cmd:
        hit = _helper_invoked(_resolved, _depth + 1, _full=_ansi_c(_whole))
        if hit:
            return hit
    # A COMMAND SUBSTITUTION runs before the command that consumes its output, so the
    # consumer being harmless proves nothing: `echo "$(... lease_slot.py ...)"` claims a
    # slot and logs a sanctioned-bypass event, then prints the slot number. Flatten the
    # substitution markers into separators and re-scan, so the body is judged as the
    # command it is. Deliberately crude rather than a second parser: dropping quotes and
    # turning `$(`/backtick/`)` into `;` can only ADD segments, so it errs toward
    # blocking. The one over-block it admits is a command that both substitutes AND names
    # a helper in the same breath, e.g. echo "see $(ls) lease_slot.py".
    if _depth <= 2 and ("$(" in cmd or chr(96) in cmd):
        # Quotes are removed, NOT replaced with a space: the shell CONCATENATES adjacent
        # quoted runs, so `lease_"slot.py"` is one word and spacing it out unmatched it.
        _flat = cmd.replace(chr(34), "").replace(chr(39), "")
        _flat = (_flat.replace("$(", " ; ").replace(chr(96), " ; ")
                      .replace(")", " ; "))
        _hit = _helper_invoked(_flat, _depth + 1, _full=_whole)
        if _hit:
            return _hit
    # INDIRECTION WITHDRAWS THE MENTION CONTRACT. Normally a helper NAMED in an operand
    # is data -- that is what keeps `cat .../lease_slot.py` and `echo lease_slot.py`
    # allowed. But a command that defines a function, defines an alias, or calls eval can
    # re-point a name so an operand becomes the thing that runs:
    #   echo() { "$@"; }; echo sh -c "<payload>"
    #   shopt -s expand_aliases; alias echo=eval; echo "<payload>"
    # Rather than model the rebinding (or keep an exemption list and lose to the next
    # spelling), the contract is dropped WHOLESALE for such a command and every token is
    # examined. It only ever blocks more, and only for commands that asked for it by
    # introducing indirection in the first place.
    # Matched on a DEQUOTED copy: the shell concatenates adjacent quoted runs, so
    # `ev"al" "<payload>"` runs eval while the raw text contains no contiguous `eval`.
    # Both the trigger AND the search run on the dequoted copy. Dequoting only one of
    # them left `eval "... lease_""slot.py ..."` -- eval detected, helper name split
    # across two quoted runs and therefore not found in the raw text.
    # ...and against the NORMALIZED copy as well, where a backslash-newline continuation has
    # been rejoined and `${IFS}` restored to whitespace. `ha\<newline>sh -p ...` and
    # `hash${IFS}-p${IFS}...` are indirection that the raw text spells neither of.
    # KEEP IN STEP WITH cmdword._has_indirection.
    _dq = _dequote(cmd)
    # _shell_variants, not just _dequote: the shell strips ESCAPES before it resolves a
    # command word, so `h\a\s\h -p ...` runs the builtin while neither the raw text nor the
    # dequoted copy spells it. cmdword._has_indirection already asked the variants; this
    # copy asked only the dequoted text, which is the same defect one layer down.
    # KEEP IN STEP WITH cmdword._has_indirection.
    if any(_INDIRECTION_RE.search(_v)
           for _text in (cmd, _norm_for_scan(cmd))
           for _v in _shell_variants(_text)):
        # _abandoned_scan_probe, NOT the plain substring test: it also squeezes quoting and
        # GLOB characters, so an indirect receiver carrying a globbed helper name
        # (`eval "$A"` fed `lease_slo[t].py`) is caught. The substring test saw no literal
        # name and allowed it -- and this guard is UNCONDITIONAL, so that was a live hole.
        _hit = _abandoned_scan_probe(_dq)
        if _hit:
            return _hit
    _pairs, ok = _split_with_ops(_norm_for_scan(cmd))
    # `)#` -- the comment defuser could not tell whether that paren delimited a command and
    # said so instead of guessing. Unresolved is the fail-CLOSED case, the same as an
    # unparseable command below, so the squeezed probe answers it.
    if _paren_hash_ambiguous[0]:
        _hit = _abandoned_scan_probe(cmd)
        if _hit:
            return _hit
    segs = [_s for _op, _s in _pairs]
    if ok:
        # A shell on the RECEIVING end of a pipe runs whatever the producer wrote, and the
        # walk below can only see that payload as data. Same condition and same reason as
        # cmdword._piped_shell_producers -- keep the two in step.
        if _locale_string[0]:
            # A LOCALE STRING ANYWHERE, probed once before either transport. Translation can
            # produce the RECEIVER, and both transports find their receiver by looking at
            # words: the here-string branch sees the ordinary-looking `runner` (the `$` was
            # dropped during normalization) and the piped branch never yields a stage for it
            # at all, so neither reaches the payload test that already knows about locale
            # strings. Widening here covers both, and covers the ones neither branch models.
            #
            # Unconditional rather than transport-gated on purpose: the cost is the same
            # trade already accepted for locale strings -- it needs a `$"..."` AND a helper
            # named somewhere in the command -- and gating it on a transport this scan can
            # RECOGNISE is exactly the assumption that failed here.
            _hit = _abandoned_scan_probe(cmd)
            if _hit:
                return _hit
        for _prod in _piped_shell_producers(_pairs):
            # _abandoned_scan_probe, NOT the plain _names_helper: the probe also squeezes
            # GLOB characters, so a payload naming `lease_slo?.py` -- which the shell
            # expands to the helper while the text names none literally -- is caught. The
            # sibling call sites already used the probe; this one did not, and a glob in a
            # PIPED payload walked through.
            _hit = _abandoned_scan_probe(_prod)
            if _hit:
                return _hit
            # SAME WIDENING AS THE HERE-STRING SIDE, and for the same reason: a producer
            # whose text is unresolvable cannot be answered from the PIPELINE alone,
            # because the value can be assigned in an earlier pipeline of the same command.
            # `P='<helper>'; echo "$P" | sh` executes the helper, and the producer text for
            # that pipeline is only `echo "$P"` -- the assignment is behind a `;`, so it is
            # a different pipeline and never part of the producer.
            #
            # Fixed alongside the here-string spelling deliberately. Review found only that
            # one, but the two are the same defect one transport apart -- this file's own
            # comment calls them "same reason, different transport" -- and closing a single
            # spelling of a class it can already demonstrate is the mistake this module
            # documents elsewhere. Once, then stop, for the quadratic reason given below.
            if _text_unresolvable(_prod):
                _hit = _abandoned_scan_probe(cmd)
                if _hit:
                    return _hit
                break
        # Same reason as the producer loop above, different transport: a here-string
        # operand feeding a shell IS the program (#643).
        for _hs in _herestring_shell_payloads(_pairs):
            # `_hs` is the whole SEGMENT, not a reconstructed operand -- see the
            # generator. An unresolvable operand no longer relies on the scan happening
            # to cover the text it sits in -- that reasoning held only WITHIN a segment and
            # was the bypass fixed above; the payload test widens instead. What no widening
            # can reach is what the VARIABLE holds, which is the `-` / /dev/fd/N
            # branch's own documented residual -- what stdin carries is not statically
            # visible -- so a bare `sh <<< "$VAR"` naming the helper nowhere still allows.
            _hit = _abandoned_scan_probe(_hs)
            if _hit:
                return _hit
    if not ok:
        # Unparseable -- most often a Bash-VALID heredoc whose BODY contains an
        # apostrophe, which this segmenter models as shell source (a known limitation the
        # block message below names). Probed with _names_helper, not the plain substring:
        # it also squeezes quoting and GLOB characters, so `lease_slo[t].py` -- which the
        # shell expands to a helper while naming none literally -- is caught here.
        #
        # NOT fail-closed, deliberately, and this is the one abandonment path where that
        # is right. The others (budget, oversize, depth) are reached only by shapes with
        # no honest form. This one is reached by a heredoc carrying prose,
        # which is ordinary; blocking every heredoc containing an apostrophe trades a
        # narrow bypass for a constant, benign failure. The squeezed probe closes the
        # bypass without that cost. Residual: a name assembled at RUN time still escapes,
        # which is the accepted ADR 0006 limitation, not a new one.
        return _abandoned_scan_probe(cmd)
    for segtext in segs:
        try:
            lex = shlex.shlex(segtext, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = ""
            toks = list(lex)
        except ValueError:
            # Unbalanced quoting inside ONE segment: same reasoning and same probe as the
            # segmenter above -- squeezed, so a globbed helper name is still caught.
            return _abandoned_scan_probe(segtext)
        # Charge before scanning: the O(tokens^2) walk below is what this bounds.
        _helper_budget[0] -= len(toks)
        if _helper_budget[0] < 0:
            # Fail CLOSED. The earlier version returned only the substring probe, on the
            # reasoning that the cmdword budget blocks the same shape anyway -- and that
            # reasoning was WRONG in the one way that matters. This guard is
            # UNCONDITIONAL: it blocks whether or not a design review is pending. The
            # cmdword budget only decides is_file_mod, which blocks solely WHILE a review
            # is pending. So with nothing pending the two do not overlap at all, and a
            # command of 4001 filler flags followed by `-m lease_slot` measured ALLOW.
            # Abandoning the scan cannot report "no helper" -- it can only report that it
            # does not know, and not-knowing blocks here.
            return _helper_substring(cmd) or _HELPER_UNSCANNED
        # Follow sub-programs FIRST: a payload handed to find -exec, env -S or a shell
        # -c is executed just as surely as the top level, and looking only at the top
        # level let `find . -exec python3 .../lease_slot.py .claude fake 1 ;` through.
        # WHICH token list, decided once and used for both scans below. Stripping is only
        # safe in the command-position regime. After shlex has dequoted, a literal `>`
        # handed to a wrapper as an OPERAND is byte-identical to a redirect operator --
        # the case _is_redir warns about above -- so _strip_redirs would drop it AND the
        # token after it. That is the interpreter: `env -u ">" python3 .../lease_slot.py`
        # runs the helper and measured ALLOW. The wrapper regime scans EVERY token and so
        # needs no stripping at all; the command-position regime needs it, because there a
        # redirect TARGET left in place (</dev/null -> /dev/null) becomes the command
        # word and hides the interpreter behind it. Two different failures, one on each
        # side, which is why the choice is conditional rather than either one alone.
        _wrapped = _starts_with_wrapper(toks)
        _scan_toks = toks if _wrapped else _strip_redirs(toks)
        _tokp, _strp = _exec_payloads(_scan_toks)
        for _p in _tokp:
            # shlex.quote per token, NOT a bare join. A bare join loses the boundary a
            # quoted token carried, so `-exec sh -c "python3 -I .../lease_slot.py ..."`
            # re-lexed as `sh -c python3 -I .../lease_slot.py ...` -- and the -c handler
            # then reads only `python3` as the program, with the helper demoted to $0/$1
            # and never scanned. Requoting round-trips the token list exactly.
            _hit = _helper_invoked(" ".join(shlex.quote(_t) for _t in _p),
                                   _depth + 1, _full=_whole)
            if _hit:
                return _hit
        for _p in _strp:
            _hit = _helper_invoked(_p, _depth + 1, _full=_whole)
            if _hit:
                return _hit
        # The helper must be EXECUTED, not merely named. Naming one is an ordinary read
        # -- `cat .../lease_slot.py`, `git diff -- .../audit_append.py`,
        # `echo lease_slot.py`, `python3 safe.py lease_slot.py` -- and blocking those
        # contradicts the read/mention contract the rest of this detector maintains.
        words = _scan_toks
        # Locate the interpreter. Two regimes, same reasoning as the verb scan above: a
        # wrapper can carry flags that take an OPERAND (`env -u FOO python3 ...`,
        # `sudo -u root python3 ...`), so peeling to the first non-flag word picks the
        # operand and misses the interpreter behind it. When the segment STARTS with a
        # wrapper, look for the interpreter anywhere; otherwise require it in command
        # position, which is what keeps `echo python3 lease_slot.py` a mention.
        pyi = None
        if _wrapped:
            pyi = next((i for i, t in enumerate(words)
                        if _bn(t).startswith("python")), None)
        else:
            cw = _peel_wrappers(words)
            if cw is not None and _bn(cw).startswith("python"):
                pyi = words.index(cw)
            elif cw is not None and _bn(cw) in _MUTATING_HELPERS:
                # The script itself is the command word (executable bit set).
                i = words.index(cw)
                if not (i + 1 < len(words) and words[i + 1] == "--self-check"):
                    return _bn(cw)
                continue
        if pyi is None:
            continue
        # The EXECUTED script is the interpreter first non-flag argument. Anything later
        # is that script own argument, so `python3 safe.py lease_slot.py` runs safe.py,
        # and `python3 -c ... # lease_slot.py` runs a -c program.
        script = None
        j = pyi + 1
        while j < len(words):
            w = words[j]
            # Normalized first: `/dev/fd/./0`, `/dev//fd/0` and `/dev/fd/../fd/0` all
            # open descriptor 0, and matching the canonical spelling alone let each of
            # them read as an ordinary script name.
            if (_FD_SCRIPT_RE.match(posixpath.normpath(w))
                    or _UNRESOLVED_OPERAND_RE.search(w)):
                # The PROGRAM comes from stdin, so it is not an argument at all and the
                # operand walk picked the next plain operand as the script:
                # `python3 - .claude 20 0 3600 < .../lease_slot.py` ran the helper while
                # the parser judged `.claude`. What stdin carries is not statically
                # visible -- it arrives by redirect, by pipe from an earlier segment, or
                # by heredoc -- so the WHOLE command is searched, not this segment.
                # That over-blocks a contrived `python3 - lease_slot.py </dev/null`,
                # where the helper is only an argument and stdin is empty. Accepted:
                # `python3 -` is an execution context, not a mention, and enumerating
                # the empty-stdin spellings is the allowlist this file keeps deleting.
                hit = _glob_helper(w) or _names_helper(_whole)
                if hit:
                    return hit
                break
            if w.startswith("-"):
                # A flag that takes an operand consumes the next word (-c PROG, -m MOD).
                # `-m MODULE` runs the helper without ever naming the FILE, and `-m`
                # was on the list of flags whose operand is skipped as an option value.
                # Matched inside a short-flag CLUSTER, the same way the -c handler
                # reads its program: CPython accepts `-Bm mod` and `-Bmmod`, so
                # anchoring on a leading `-m` caught only the simplest spelling.
                # `--` ends option parsing: the NEXT word is the script, and a word that
                # merely looks like an option is a filename from here on.
                if w == "--":
                    script = words[j + 1] if j + 1 < len(words) else None
                    break
                if w == "--module" and j + 1 < len(words):
                    if _module_helper(words[j + 1]):
                        return _module_helper(words[j + 1])
                    if not _PLAIN_MODULE_RE.match(words[j + 1]):
                        stem = next((m for m in _MUTATING_MODULES
                                     for v in _shell_variants(_whole) if m in v), None)
                        if stem:
                            return stem + ".py"
                    break
                if w.startswith("--"):
                    j += 2 if w == "--check-hash-based-pycs" else 1
                    continue
                # A short-option CLUSTER is consumed left to right, and the FIRST
                # option taking an operand swallows the cluster remainder -- or the
                # next word when the cluster ends there. Testing for an `m` ANYWHERE
                # read `-Wm` (which is `-W m`) as a module switch, then skipped the
                # script word that followed it as if it were the module name.
                k = next((i for i, ch in enumerate(w[1:]) if ch in "cmWXQ"), None)
                if k is None:
                    j += 1
                    continue
                tail = w[2 + k:]
                if w[1 + k] == "m":
                    mod = tail if tail else (words[j + 1] if j + 1 < len(words) else "")
                    if _module_helper(mod):
                        return _module_helper(mod)
                    # An operand the shell rewrites (`M=lease_slot; python3 -m "$M"`)
                    # names its module only at run time, so the whole command is
                    # searched for a helper STEM -- the module spelling, which carries
                    # no `.py` for _names_helper to find.
                    if not _PLAIN_MODULE_RE.match(mod):
                        stem = next((m for m in _MUTATING_MODULES
                                     for v in _shell_variants(_whole) if m in v), None)
                        if stem:
                            return stem + ".py"
                if w[1 + k] in ("c", "m"):
                    # CPython STOPS parsing options at -c and -m; everything after is
                    # argv for the program it already chose. Walking on read the next
                    # operand as a second module or as a script, so `python3 -m json.tool
                    # lease_slot.py` -- which only READS the helper -- was blocked.
                    #
                    # But stopping OUTRIGHT was a fail-open: several stdlib modules take a
                    # SCRIPT PATH and run it. `python3 -m cProfile <helper>.py .claude 20
                    # 0 3600` executes the helper -- claiming a real lease slot and
                    # minting a skip-review-consumed event -- while this walk classified
                    # only `cProfile` and allowed it. Confirmed for cProfile, profile,
                    # pdb, trace, timeit and runpy, which is already too many spellings to
                    # chase one at a time.
                    #
                    # So the question is INVERTED, the way it is everywhere else in this
                    # file: an executes-its-argument list fails OPEN on the module nobody
                    # thought of, while a READS-ONLY list fails CLOSED on it. Only the
                    # handful of modules that provably just read their operand let the
                    # walk stop; for anything else the remaining words are still searched
                    # for a protected helper. The cost of being wrong is a false block on
                    # an unlisted read-only module, which is the safe direction and is
                    # cleared by adding it to the list.
                    # Both spellings of "the helper", because a runner module accepts
                    # both. _glob_helper resolves a FILE operand, including the expanded
                    # forms `lease_slo[t].py` and `lease_slot*.py` -- an equality test on
                    # the literal spelling never matches those while the command still
                    # runs the helper, and the direct-script path below already resolves
                    # operands this way. _module_helper resolves a MODULE operand:
                    # `python3 -m cProfile -m lease_slot` hands cProfile its OWN -m, which
                    # runs the helper as __main__ without the name ever carrying `.py`.
                    #
                    # EVERY later word is scanned, with no stop. A stop at the first `.py`
                    # operand was tried, to spare the one false positive where the helper
                    # is merely argv to another profiled script -- and it was a bad trade:
                    # an option operand can itself end in `.py`, so `-o out.py <helper>`
                    # broke at out.py while cProfile still executed the helper. That
                    # exchanged a false BLOCK for a fail-OPEN. Any narrowing here needs
                    # per-option arity, the table this file refuses everywhere because it
                    # fails open wherever it is wrong. The residual false positive is
                    # deliberate and recoverable through the skip lease.
                    if w[1 + k] == "m" and not _readonly_module_trusted(mod, words):
                        for later in words[j + 1:]:
                            _g = _glob_helper(later) or _module_helper(later)
                            if _g:
                                return _g
                    break
                j += 1 if tail else 2
                continue
            script = w
            break
        if script is None or _bn(script) not in _MUTATING_HELPERS:
            continue
        # Exempt ONLY the exact `<helper> --self-check` shape: the flag must be the
        # helper FIRST argument. A looser any-token test was satisfied by a trailing
        # `# --self-check`, which bash treats as a comment but this parser (with
        # commenters disabled) tokenizes -- so the real, mutating invocation ran.
        if j + 1 < len(words) and words[j + 1] == "--self-check":
            continue
        return _bn(script)
    return None


def _writes_marker(cmd, markers):
    # Decide block/allow by SEGMENTING then TOKENIZING the command instead of
    # regex: a marker basename that is a redirect (>) target or a tee/rm operand
    # is a write/forge attempt -> block; a marker that appears only as a read
    # (cat / [ -f ] / < input) or a quoted string literal in an unrelated command
    # is allowed.
    #
    # Out of scope (accepted defense-in-depth residual, ADR 0006 — the real
    # anti-forge boundary is the trusted writers plus diff-hash binding, and
    # Claude is the trusted dispatcher). The detector stops the DIRECT, common
    # forms — redirect/tee/rm/touch/cp/mv/ln/install to a marker, plus quoting, ${IFS}, same-command
    # variable, line-continuation, and ANSI-C-prefix obfuscation of them. It does
    # NOT try to stop a dispatcher that runs an ARBITRARY STRING OR PROGRAM; that
    # is an unbounded class, all equivalent to eval, and is left to the diff-hash
    # backstop:
    #   - execute-a-string: eval, sh/bash/zsh/dash -c "...", and interpreter
    #     evaluation (python -c, perl -e, ruby -e, node -e, awk, xargs,
    #     find -exec/-delete)
    #   - command substitution: backticks and $(...)
    #   - indirect writers NOT enumerated as command words: other copy/convert tools
    #     (cp/mv/ln/install ARE blocked — see #290 below; truncate/unlink/rmdir/dd
    #     joined them in #519 once the lease ledger and audit log became gate state)
    #   - runtime name synthesis: pathname globbing (* ? [ ]) and brace expansion
    #     ({a,b}) that expand to the marker (rm ...loca?, tee ...loca{l,})
    #   - environment / nested / computed shell variables, ANSI-C escape
    #     SEQUENCES (\x6c-style), and the nested single-quote idiom (which trips
    #     the segmenter into its fail-closed substring fallback)
    # These are one tier against a HOSTILE dispatcher: one that can eval can forge
    # the marker directly, so blocking a subset is theater against that actor.
    # #290 extended the blocked verbs (rm/tee → +touch/cp/mv/ln/install as command
    # words) anyway, because the realistic threat is an accidental/lazy self-bypass
    # by a COOPERATIVE agent (a bare `touch .claude/skip-litmus.local`); blocking the
    # bare-command indirect-write forms removes the easy path and forces any bypass
    # to be a deliberate eval-forge a cooperative agent will not build. A human touch
    # typed in a real terminal is unaffected — this hook only sees the Claude tool
    # calls. See #227 and the ADR 0006 residual addendum.
    #
    # #519 CLOSED the wrapper-hidden half of that residual (`sudo touch <marker>`,
    # `command rmdir <slot>`, `env truncate <log>`): the command word is now chosen
    # after peeling wrapper preambles. The residual was tolerable while the only
    # wrapper-reachable targets were markers a cooperative agent had no reason to
    # forge; it stopped being tolerable once the skip LEASE ledger and the bypass
    # audit log became gate state, since those two shapes reset the use ceiling and
    # erase the trail respectively. A residual that is the EASIEST path is not a
    # residual. The execute-a-string class (eval, sh -c, python -c) is UNCHANGED and
    # remains the documented residual.
    norm = _norm_for_scan(cmd)
    # Returns (marker_or_None, unparseable). `unparseable` is TRUE only for the
    # fail-CLOSED raw-substring path below, where the command could not be parsed
    # at all and a marker WRITE is therefore indistinguishable from a mere MENTION.
    # It changes NO decision -- both paths block -- it only lets the caller emit an
    # accurate diagnostic instead of asserting a write that may not exist (#365).
    segs, ok = _split_simple_commands(norm)
    if not ok:
        # Unterminated quote / dangling escape: fail CLOSED via raw substring.
        return (next((mf for mf in markers if _bn(mf) in cmd), None), True)
    # simple_vars persists across segments so a cross-segment assignment
    # (m=.../marker ; rm "$m") resolves; updated in order, so a write sees the
    # value assigned BEFORE it and a later reassignment cannot mask it.
    simple_vars = {}
    flags = {"unparseable": False}
    for segtext in segs:
        # Reset per segment: the flag must describe the segment that PRODUCED the
        # hit, not some earlier one. Shared across the loop it would report
        # "could not parse" for a genuine forge that merely FOLLOWED an unparseable
        # segment — and that error runs the wrong way, telling the operator "nothing
        # was necessarily being written" about a real write attempt. A security
        # message may overstate; it must not understate.
        #
        # Defensive, not known-reachable: _split_simple_commands splits only on
        # UNQUOTED separators, so each segment inherits balanced quote parity and the
        # shlex ValueError below has nothing to reject — a real imbalance trips the
        # whole-command ok=False path first. The reset costs one assignment and holds
        # the invariant if the two parsers ever drift apart.
        flags["unparseable"] = False
        hit = _scan_segment(segtext, markers, simple_vars, flags)
        if hit:
            return (hit, flags["unparseable"])
    return (None, False)


try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)

    MARKER_FILES = [
        "litmus-passed.local",
        "pr-review-passed.local",
        # Dual-voice PR artifacts — writable ONLY by run-review-loop.sh: the
        # backstop verdict via --run-backstop (a captured claude -p dispatch → an
        # internal writer; no public writer subcommand — removes the easy #350 retype
        # forge, though a Bash-holding dispatcher can still fabricate: accepted ADR
        # 0006 residual), the Codex-lead verdict inline on an actual Codex PASS.
        # Direct Write/Edit/MultiEdit/shell-redirect/rm against them is blocked so
        # the hash re-derivation in the writer cannot be bypassed by a file forge.
        # (Keystone for ADR 0006; .local.json suffix matched as a substring.)
        "pr-codex-lead.local.json",
        "pr-backstop-verdict.local.json",
        "skip-litmus.local",
        "skip-design-review.local",
        # #519 — the skip LEASE ledger. Its per-use slots are what bound the bypass to
        # 20 writes, so it is gate state exactly like the skip file itself. Unprotected,
        # the ceiling is trivially resettable BY the agent it constrains: the gate grants
        # a use for `rm -rf .claude/.skip-design-review-lease.d`, that command erases
        # every slot, and the next write starts again at slot 1 — an unbounded lease
        # that merely looks bounded. (No apostrophes in this block: it is a
        # single-quoted shell string, so one would terminate the Python source.)
        # Listed here so the unconditional forge guard
        # (which runs before the F9 $STATE_DIR rm/mkdir exemption could allow it) blocks
        # the delete outright. The cleanup done by this gate is script code, not a
        # tool call, so it is unaffected.
        ".skip-design-review-lease.d",
        # #519 — the bypass audit log. Hardening the APPEND is worth nothing if the
        # FILE can be erased for free: writes under $STATE_DIR classify as SAFE and a
        # bare rm of a $STATE_DIR path hits the F9 exemption, so a session could delete
        # bypass-log.jsonl without even spending a lease use, wiping every recorded
        # bypass — and the next use simply recreates the file and is granted. The whole
        # design-clear/lease story is detection rather than prevention, which only holds
        # while the record survives. Reads (cat/grep) are unaffected: the forge detector
        # blocks only redirect/tee/rm/touch/cp/mv/ln/install positions.
        "bypass-log.jsonl",
        "reviewed-commits.local",
        "design-review-needed.local",
    ]

    if tool in ("Write", "Edit", "MultiEdit"):
        fp = inp.get("file_path", inp.get("filePath", ""))
        for mf in MARKER_FILES:
            if mf in fp:
                print("BLOCK_MARKER|" + mf)
                sys.exit(0)

    elif tool == "Bash":
        cmd = inp.get("command", "")
        # #519 helpers that MUTATE gate state (lease slots, the audit log). They are
        # internal to this gate, which runs them as a subprocess -- never as a Claude
        # Bash tool call -- so a Bash call naming them is either a mistake or a bypass.
        # DEFENCE IN DEPTH, not the only defence. The helpers are also safe by
        # construction now: lease_slot.py reads the skip file mtime ITSELF rather than
        # accepting it (a caller-supplied mtime was forgeable, and a fabricated one
        # prunes the genuine slots and resets the ceiling), and audit_append.py builds
        # its record from fixed fields rather than accepting arbitrary JSON. That
        # matters because neither command has to name a protected path or a
        # modification verb, so nothing else in this detector would notice it — and
        # guessing every invocation spelling is the arms race this file already warns
        # about. Same treatment as the marker writer below.
        # --self-check is exempt: it runs entirely in a temp dir, mutates no real state,
        # and the test suite invokes it through Bash.
        # Oversized commands skip the full walk, which is what the 5s hook timeout cannot
        # afford; a substring probe stays cheap at any length. But NOT scanning is not the
        # same as finding nothing, and the note that used to sit here -- that a command
        # this large is independently called BASH_MOD by the classifier below -- does not
        # rescue it: BASH_MOD only blocks WHILE a design review is pending, and this guard
        # is unconditional. So an unscannable command fails CLOSED here too.
        _blocked_helper = (_helper_invoked(cmd) if len(cmd) <= 65536
                           else (_helper_substring(cmd) or _HELPER_UNSCANNED))
        if _blocked_helper == _HELPER_UNSCANNED:
            print("BLOCK_UNSCANNABLE|")
            sys.exit(0)
        if _blocked_helper:
            print("BLOCK_MARKER_SCRIPT|" + _blocked_helper)
            sys.exit(0)
        # Block direct invocation of the marker writer UNLESS called via
        # the canonical litmus plugin path. The script validates internally that
        # a builtin review was actually triggered (checks handoff file existence).
        # Without this allowlist, builtin fallback (exit 3) creates a catch-22:
        # SKILL.md tells Claude to call the script, but the gate blocks it.
        if "write-review-marker" in cmd:
            if re.search(r"(?:ba)?sh\s+.*litmus/scripts/write-review-marker", cmd):
                print("OK|")
            else:
                print("BLOCK_MARKER_SCRIPT|write-review-marker.sh")
            sys.exit(0)
        # Block shell redirects / tee / rm TARGETING marker files. ALWAYS
        # tokenizes (see _writes_marker) rather than pre-filtering on the raw
        # command, because shell quote concatenation can assemble a marker
        # filename that no contiguous raw substring contains. Quoted, wrapped,
        # and multi-operand targets are caught without false-positiving benign
        # commands that merely mention a marker name in a non-write position.
        hit, unparseable = _writes_marker(cmd, MARKER_FILES)
        if hit:
            print(("BLOCK_MARKER_UNPARSED|" if unparseable else "BLOCK_MARKER|") + hit)
            sys.exit(0)

    print("OK|")
except Exception as _e:
    # Fail CLOSED (#557). This handler used to print OK|, which means ALLOW, so ANY
    # exception in the classifier silently permitted every gated command. A scan that
    # crashed has not found "no marker" -- it has found nothing at all, and nothing at
    # all is the fail-CLOSED case (the same argument the token budget already makes).
    # Only the class name is emitted: the message can contain a pipe, which would be
    # read as a field separator by the shell split in the caller.
    print("BLOCK_CLASSIFIER_ERROR|" + type(_e).__name__)
# The caller applies the same reasoning to the cases this handler cannot reach --
# python never starting, or dying before the handler runs, or exiting without a
# verdict. See the allowlist in pre-implementation-gate.sh: anything that is not a
# recognized verdict blocks, because a classifier that answered nothing has not
# answered "no".
