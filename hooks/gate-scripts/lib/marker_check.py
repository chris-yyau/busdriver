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
_UNRESOLVED_CW_RE = re.compile(r"[$`*?\[{(]")   # `(` is extglob: ba+(s)h expands to bash
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


def _skippable(w):
    # A leading assignment, a flag, or a bare numeric wrapper operand (timeout 5 ...).
    return (re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", w) is not None
            or w.startswith("-")
            or re.match(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$", w) is not None)


def _peel_wrappers(words):
    # First word that actually EXECUTES: skip leading assignments, flags, bare numeric
    # wrapper operands, and wrapper commands themselves. Returns None when nothing
    # survives, so the caller falls back to its raw first word.
    for w in words:
        if _skippable(w) or _bn(w) in _WRAPPER_CMDS or _bn(w) in _RESERVED_SH:
            continue
        if _bn(w) in _TEST_OPEN_SH:
            return None
        return w
    return None


def _strip_time_prefix(words):
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
        if rest[i] == "time":
            del rest[i]
            if i < len(rest) and rest[i] == "-p":
                del rest[i]
            continue
        m = _REDIR_PREFIX_RE.match(rest[i])
        if m:
            attached = m.group(0) != rest[i]
            del rest[i]
            if not attached and i < len(rest):
                del rest[i]
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
    return rest


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
                if i + 1 < n and not _is_redir(toks[i + 1]):
                    nxt = toks[i + 1]
                    m = _match_marker(nxt, markers, simple_vars)
                    if m:
                        return m
                    # A redirect target is NOT a command word: leave seg_has_cmd
                    # unset so a bare name=value in a redirect-only simple command
                    # (> /dev/null m=.../marker) is still recorded as an assignment
                    # and a later rm "$m" resolves to the marker.
                    seg.append(nxt)
                    i += 2
                    continue
                i += 1
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
    norm = norm.replace("$" + _SQ, _SQ).replace("$" + _DQ, _DQ)
    # ${IFS}/$IFS expand to whitespace -- a classic field-splitting obfuscation
    # (rm${IFS}<marker>); normalize to a separator so the command word and redirect
    # operands are recognized rather than glued into one token.
    return re.sub(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])", " ", norm)


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
    return out


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


# How deep a nest of extglob groups is resolved before the text is called unresolvable.
# Bounded rather than looped to convergence: the input is attacker-chosen and this runs
# under a hook timeout that kills the check with NO decision, which reads as allow.
# Exceeding it is NOT covered by the command-word comparison -- a nest deeper than this
# survives every pass unchanged, so the two spellings agree; the trailing-`@`/`+` test on
# the command word is what catches those, and a fixture pins it.
_EXTGLOB_PASSES = 4


def _lex_seg(text):
    # The lexer configuration this scan already uses: posix, so quotes resolve;
    # punctuation_chars, so `<<<` separates from the word it touches;
    # whitespace_split; and commenters off, because the newline->";" normalization
    # leaves a `#` with no terminating newline to end it.
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def _herestring_shell_payloads(pairs, whole):
    # A here-string feeding a shell RUNS its operand, so that operand is a PROGRAM (#643).
    # `sh <<< '<helper>'` classified OK while `echo '<helper>' | sh` blocked -- the same
    # invocation, one transport apart. `_piped_shell_producers` yields the text feeding a
    # pipeline STAGE; a here-string has no producer stage, because the payload is the
    # operand of `<<<` on the receiver's own command line. Nothing was yielded, so the
    # payload was never scanned as a program.
    #
    # NO cmdword TWIN IS NEEDED, checked rather than assumed: its stdin-fed shell-source
    # branch (`base in _SHELLS and t2 == "<<<"`) already classifies this shape, which is why
    # the asymmetry was one-directional -- the sibling closed `<<<` and the copy the helper
    # guard actually consults did not.
    #
    # ROUTING ONLY. Everything here is an existing part: the receiver question is the one
    # `_peel_wrappers`/`_is_shell_name` already answer, and what is yielded goes to the same
    # `_abandoned_scan_probe` the pipe producers are handed to. No new model of the language.
    #
    # NINE RESIDUALS, measured and accepted as out of scope for #643 rather than assumed
    # away. Each is a place where this routing differs from the pipe path it feeds:
    #
    #   1. The receiver and the `<<<` must land in the SAME split segment, so a redirection
    #      attached to a COMPOUND command is separated from the shell inside it --
    #      `(sh) <<< P`, `{ sh; } <<< P` and `if true; then sh; fi <<< P` all read OK.
    #      Associating a redirection with an enclosed receiver is compound-command modelling,
    #      which this file's history says to stop short of rather than climb.
    #
    #   3. A here-string bound to a NON-ZERO descriptor (`sh 3<<< P`) is scanned anyway,
    #      and a later `<<<` or `</dev/null` that overrides an earlier operand does not
    #      un-scan it. Both OVER-block. A descriptor guard was tried and removed: after
    #      `shlex` the operand `3` in `bash -s 3 <<< P` is indistinguishable from the fd in
    #      `sh 3<<< P` -- adjacency is gone -- so the guard turned an over-block into a
    #      FAIL-OPEN, which is the trade this file never makes. Deciding which redirection
    #      wins is redirection-order modelling, the same class as residual 1.
    #
    #   2. The receiver test here is the shell-name one in COMMAND POSITION. The pipe
    #      path's is wider -- it also reaches an applet multiplexer (`busybox sh`,
    #      `toybox sh`), where the command word is the multiplexer and the shell is its
    #      first operand, and `. /dev/stdin` -- but it is 48 lines inline inside
    #      `_piped_shell_producers`, entangled with that loop's budget charging and its
    #      `_executed_operands` mirror. Sharing it means extracting and re-plumbing a hot
    #      path with a second caller in `cmdword`, which is its own change, not this one.
    #      (A receiver behind a WRAPPER is not in this set: it is unresolved, and the
    #      unresolved answer below covers it without naming a single flag.)
    #
    #   5. An OVER-block that falls out of that same answer: a NON-executing receiver
    #      behind a wrapper is unresolved too, so `timeout 5 cat <<< '<helper text>'` is
    #      refused. The unwrapped spelling, which is #573's actual shape, still reads.
    #
    #   6. An OVER-block held in COMMON with the pipe path: an interpreter taking its
    #      program from a flag or an operand (`bash -c ':' <<< P`, `sh script <<< P`) still
    #      has its here-string scanned as source. Whether a shell reads stdin from its FLAGS
    #      is the arity question `_piped_shell_producers` states it refuses, and all three
    #      spellings block identically through a PIPE today -- measured, so this is parity.
    #
    #   8. An OVER-block: a `<<<` written inside a COMMENT is still read as an operator.
    #      `_defuse_comments` blanks separators and quotes inside a comment and keeps every
    #      other byte ON PURPOSE (deleting moved 14 real commands to allow), so the operator
    #      survives it. Ending a segment at `#` instead is comment modelling, and it would
    #      hide a payload written after one -- the fail-OPEN direction.
    #
    #   9. An OVER-block, the price of taking whole-command text whenever the command
    #      carries an expansion ANYWHERE: normalization has already erased the expansion
    #      from the segment that would prove it relevant (`sh <<< :$IFS` arrives as
    #      `sh <<< :`), so the choice cannot be made segment-locally without provenance
    #      this scan does not keep. An unrelated `cat "$X/<helper>"` beside a harmless
    #      here-string is refused.
    #
    #   7. A gap in the SHARED probe rather than in this routing: an extglob-spelled helper
    #      PATH (`lease_slo@(x|t).py`) is unresolved everywhere -- measured OK through a
    #      pipe, through `-c`, and as a direct invocation. Expanding alternations belongs to
    #      `_abandoned_scan_probe` and every caller, not here. The `?` spelling resolves.
    #
    #   4. A LITERAL `<<<` argument (`sh '<<<' P`) is read as the operator, because the
    #      lexer dequotes before this sees the token -- see the paragraph below. It
    #      OVER-blocks, and the guard that would fix it is residual 3's.
    #
    # 1, 2 and 7 are FAIL-OPENS; 3, 4, 5, 6, 8 and 9 OVER-block, which is the trade this file makes. None
    # is a regression: every one of them reads OK on `origin/main` too, because on main
    # this whole path does not exist. This change strictly reduces the fail-open set.
    #
    # `<<<` arrives as its OWN token from the lexer already used below -- attached
    # (`sh<<<x`), spaced, and fd-prefixed (`sh 0<<< x`) spellings all separate. Quoted
    # PROSE is out of this path because the quotes carry other words in the same token
    # (`echo 'use <<< like this'`, #573's case) -- NOT because quoting is visible: the
    # lexer is posix, so a bare `sh '<<<' P` dequotes to exactly `<<<` and is read as the
    # operator it is spelled like. That OVER-blocks a literal `<<<` argument (residual 4);
    # telling the two apart needs raw spans and quote state, which is the adjacency
    # modelling residual 3 records as having turned an over-block into a fail-open.
    seen_whole = False
    for _op, seg in pairs:
        if "<<<" not in seg:
            continue
        if seen_whole:
            return
        # EXTGLOB, asked of the COMMAND WORD and nothing else. The lexer treats `(` as
        # punctuation, so `/bin/@(sh)` reaches the command word as `/bin/@` -- neither a
        # shell nor unresolvable -- while bash expands it and runs the payload. Resolving
        # the group changes that word; resolving a group somewhere else does not. So peel
        # BOTH spellings and compare: a command word that moves under the rewrite was
        # spelled with a group and is unresolved (an alternation or a negation names more
        # than the text it wraps, and a nested group survives one pass), while
        # `echo '@(x|y)' <<< 'prose'` peels to `echo` either way and stays a read. Asking
        # the region instead refused exactly that command, and asking it with quote
        # provenance is the quote-state model this file does not keep.
        # To a FIXED POINT, bounded: one `sub` pass resolves one level, so `/bin/@(@(sh))`
        # comes back as `/bin/@(sh)` -- still truncated at the `(`, and still equal to the
        # unrewritten command word, which read as "no group here" and let it through.
        # A nest DEEPER than the bound survives the passes unchanged, so the comparison
        # below cannot see it either; the trailing-`@`/`+`/`!` test on the command word is
        # what catches that, and the fixture for it is in the suite because the first
        # spelling of this comment claimed the bound was harmless and the test said
        # otherwise. `!` is on that list for a second reason: `_EXTGLOB_RE` deliberately
        # EXCLUDES a negation (resolving `!(z)` to its contents yields the one spelling it
        # cannot match), so `/bin/b!(z)sh` is never rewritten at all and the truncated
        # command word is the only trace of it left.
        _flat = seg
        for _ in range(_EXTGLOB_PASSES):
            _next = _EXTGLOB_RE.sub(r"\1", _flat)
            if _next == _flat:
                break
            _flat = _next
        try:
            toks = _lex_seg(_flat)
            _otoks = toks if _flat == seg else _lex_seg(seg)
        except ValueError:
            # An unparseable segment is already probed by the caller's own fail-closed
            # path; guessing at one here would only duplicate it.
            continue
        if "<<<" not in toks:
            continue
        # COMMAND POSITION, not "a shell name anywhere". The wide test the pipe path uses
        # is safe there because a pipeline STAGE's words ARE the command; here the operand
        # and the arguments sit in the same segment, so any mention of an interpreter read
        # as the receiver -- `echo sh <<< P` merely redirects stdin to `echo`. Ordinary
        # commands that MENTION an interpreter are reads, which is the contract the rest of
        # this file keeps.
        cw = _peel_wrappers(_strip_time_prefix(_strip_redirs(toks)))
        if _otoks is not toks \
                and _peel_wrappers(_strip_time_prefix(_strip_redirs(_otoks))) != cw:
            seen_whole = True
            yield whole
            return
        if cw is None:
            # NOTHING survived the peel, which is not "no receiver": `shlex` has already
            # removed quoting, so a quoted operand that LOOKS like an operator is stripped
            # as one and takes the receiver with it (`env -u '>' sh <<< P`).
            _runs = _starts_with_wrapper(toks)
        elif not cw.strip() or any(_c.isspace() for _c in cw) or "\\" in cw \
                or cw[-1:] in ("+", "@", "!") or _UNRESOLVED_CW_RE.search(cw):
            # A receiver the text does not SPELL. `"$S"`, `"${IFS}sh"`, `{ba,z}sh`,
            # `/bin/[b]ash`, an undecoded escape: each names a shell after the shell
            # expands it and names nothing to `_is_shell_name` before. Unresolved is not
            # `no`. The COMMAND-WORD regex, not the operand one -- the wider set (`{`, `(`)
            # is why it already exists.
            _runs = True
        else:
            # ...or a WRAPPER in command position that the peel could not see past.
            # `_peel_wrappers` skips a FLAG but not the operand a flag CONSUMES, so
            # `env -u FOO bash <<< P` peels to `FOO`. WHICH flags take an operand is the
            # per-flag arity table this file refuses to keep -- it failed open four ways
            # when tried. So do not answer it: unresolved behind a wrapper is unresolved.
            _runs = _is_shell_name(_bn(cw)) or _starts_with_wrapper(toks)
        if _runs:
            # WHICH text the probe is handed. Never the operand alone: normalization
            # rewrites operands out of recognition (a `$IFS` concatenation, an ANSI-C
            # escape, a value assigned earlier in the command), and scanning them made
            # every such rewrite a bypass, one spelling at a time.
            #
            # So: the SEGMENT, which holds the receiver and its operand together -- unless
            # the original command carries an EXPANSION anywhere, in which case the segment
            # view is exactly what cannot be trusted and the whole command is searched
            # instead. That is the answer the `-` / `/dev/fd/N` interpreter branch already
            # gives to the same question. Handing over the whole command UNCONDITIONALLY
            # was tried and over-blocked ordinary work: `sh <<< ':'` beside a `cat` of the
            # helper is two unrelated commands, and each of them alone reads.
            if _UNRESOLVED_OPERAND_RE.search(whole):
                # ONCE per command: the probe's answer cannot differ between occurrences,
                # and yielding it per segment made a command holding a thousand
                # `sh <<< "$X"` stages rescan the whole text a thousand times -- ~6.3s,
                # past the hook timeout, and a timed-out hook writes NO decision, which the
                # harness reads as ALLOW. A DoS on the check is a fail-open.
                seen_whole = True
                yield whole
                return
            yield seg



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
                out.append(" ; ".join(p[1] for p in pairs[start:last]))
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
        out.append(" ; ".join(p[1] for p in pairs[start:last]))
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


# A QUOTED heredoc opener -- `<<'D'`, `<<"D"`, `<<\D`, and the `<<-` spellings of each.
# KEEP IN STEP WITH gitcmd_detect._HEREDOC_QUOTED, which carries the reasoning for both
# guards: `(?<!<)` keeps a here-STRING out (`<<<` has its own path, #643), and the trailing
# lookahead requires the delimiter token to END here, so a delimiter assembled from several
# quoting runs (`<<'EO'F`) is not half-matched onto the wrong terminator. Copied rather than
# imported: this file runs under `python3 -I`, where the script directory is off sys.path
# and a sibling import raises ModuleNotFoundError -- which this gate reports as
# BLOCK_CLASSIFIER_ERROR on EVERY Bash call. Spelled through _SQ/_DQ because no code here
# carries a literal quote; the sibling's `[^\']` is the same class.
_HEREDOC_QUOTED = re.compile(
    r"(?<!<)<<-?[ \t]*(?:"
    + _SQ + r"([^" + _SQ + r"]*)" + _SQ + r"|"     # <<'D'
    + _DQ + r"([^" + _DQ + r"]*)" + _DQ + r"|"     # <<"D"
    + r"\\(\w+))(?=[\s;|&<>)]|$)")                 # <<\D


# A quote WEDGED BETWEEN TWO WORD CHARACTERS, which is the apostrophe of ordinary prose:
# `it's`, `the library's`. Deleting one cannot change where a word begins or ends, because
# by construction no whitespace is adjacent to it -- it can only JOIN two word characters,
# which is what the shell itself does to `a'b'c`. Every OTHER quote is left alone.
_PROSE_QUOTE = re.compile(r"(?<=\w)[" + _SQ + _DQ + r"](?=\w)")

# ANY heredoc redirect operator, quoted delimiter or not, `<<<` excluded. Used only to
# count how many share the opener's line -- see the ownership guard below.
_HEREDOC_OP = re.compile(r"(?<!<)<<-?(?!<)")


def _squeeze_quoted_heredocs(cmd):
    """Drop the PROSE apostrophes from every quoted heredoc BODY.

    The outer shell does no quote processing at all inside `<<'DELIM'` -- an apostrophe
    there is a letter, not an opener. The segmenter models the body as shell source anyway
    (which is what lets a body that RUNS something still be walked), so the apostrophe reads
    as an unterminated quote, the whole command comes back unparseable, and the caller falls
    to the structureless probe -- which then finds a helper NAME in ordinary prose and blocks
    a command that invokes nothing (#639).

    Three choices here are load-bearing. Each was measured; each has a fixture.

    EXACTLY ONE quote character in the body, and it must be WEDGED between two word
    characters. That is the ONLY deletion that is boundary-safe, and the bound is not
    cosmetic -- two wider drafts were refuted by codex on this change, each verified against
    HEAD:

      - delete every quote: `python3 "/tmp/path with space/<helper>"` becomes three words,
        the script operand reads as `/tmp/path`, and the helper is demoted to an argument.
      - delete every WEDGED quote: a wedged pair still quotes the whitespace BETWEEN it, so
        `sh -c X'x=1 python3 <helper> Z'Y` -- one word to bash, an executed payload -- comes
        apart the same way.

    A LONE quote delimits nothing: there is no run for its removal to disturb, and being
    wedged means no whitespace sits beside it either, so no word can split and no command
    word can move. Anything more is undecidable from text -- three prose apostrophes and
    that `sh -c` payload are the SAME SHAPE (all wedged, whitespace between them), which is
    the wall the parked #639 design hit from the other side.

    RESIDUAL, honest and measured: only an ODD number of quotes reaches here at all (an even
    number pairs up and the command already parses), so this fixes the reported N=1 body and
    leaves N=3, 5, ... over-blocking. Fail-CLOSED, and not the reported shape.

    RESIDUAL, same direction: "logical line" means backslash-newline only. Bash also
    continues a command after `|`, `&&`, an open group and a multiline string, and after any
    of those the real body starts further down than this walks. Two consequences, and only
    one of them is real. The one that happens: that line's own text is read as body, its
    quotes lift the count above one, and the command is REFUSED -- an over-block. The one
    repeatedly proposed and repeatedly NOT reproduced: a decoy terminator inside such a
    continuation letting the squeeze rewrite live syntax and hide an invocation. Every
    construction tried (`cat <<'EOF' | echo "x`, `bash <<'D' |` with a decoy `D`) blocks on
    this classifier exactly as it blocks on HEAD, because the text the squeeze would have to
    rewrite is a quoted run that bash then executes as one bogus command word, not as the
    helper. Recorded as unproven rather than closed: modelling the rest of that grammar is
    the shell parser this file has repeatedly declined to become, and the parked #639 design
    is the record of where that road ends.

    NEVER the BACKSLASH. `_norm_for_scan` rejoins a backslash-newline continuation, so
    deleting backslashes FIRST splits the name the shell assembles across that continuation
    into two commands and it is never seen. Also raised by codex, also verified against HEAD.

    SQUEEZED, not EXCISED. #639 proposed dropping the body when the consumer is not an
    interpreter. Four drafts of that predicate were each refuted by measurement --
    `cat(){ bash /dev/stdin; }; cat <<'EOF'` runs its body, and ANY name can be a shell
    function, so "positively proven non-executing data sink" is not decidable from text.
    Squeezing needs no such predicate: the body is still segmented and walked, whoever
    consumes it.

    EXACTLY ONE quoted heredoc in the whole command, which is why this is a single pass and
    not a loop. Deleting a quote shifts the parity of the ENTIRE command, so a SECOND
    heredoc's prose apostrophe -- correctly left in place, because that body was not
    squeezed -- stops being odd-one-out and pairs with a third across the live shell between
    them, hiding it as quoted data. Measured: five heredocs carrying one apostrophe each,
    with a real invocation between bodies 2 and 3; `bash -n` valid, HEAD blocking, and both
    the looping draft AND a stop-after-the-first-squeeze draft returning OK. Raised by codex
    on this change and reproduced before fixing. One heredoc has no such interaction: the
    opener's own two quotes balance, so removing the body's lone quote leaves every other
    quote in the command paired exactly as it already was.

    Called ONLY on the retry path below, never on a command that already parsed. Every other
    exit is a refusal, and refusing is free -- the command stays unparseable and the caller
    probes it exactly as it does today.
    """
    # Openers are matched against the COMMENT-DEFUSED copy, which blanks the quotes inside
    # a comment byte-for-byte -- so offsets still index `cmd`, while `# <<'FAKE'` no longer
    # looks like syntax. Every `return cmd` below is a refusal: the command stays
    # unparseable and the caller probes it exactly as it does today.
    scan = _defuse_comments(cmd)
    ms = list(_HEREDOC_QUOTED.finditer(scan))
    # ONE heredoc in the whole command, counted BOTH ways: exactly one quoted delimiter this
    # can read, and exactly one heredoc operator of any spelling. The second count is what
    # makes the first sound -- `_HEREDOC_QUOTED` deliberately refuses a delimiter assembled
    # from several quoting runs (`<<'E'2`), and an unquoted `<<U` it cannot see at all, so
    # counting only its own matches let two further heredocs hide beside the one it matched
    # and reopened the parity bypass below. Raised by codex in the PR pass. Counting every
    # operator also subsumes the per-line ownership question: one operator in the command is
    # necessarily the only one on its line, so `3<<U 4<<'N'` is refused here.
    # The operator count runs AFTER the body is located, below -- inside the body a `<<` is
    # prose, not an operator, and counting it there refused every command whose body merely
    # writes one. "The library's <helper> documents x << 1." stayed blocked while the same
    # sentence without the `<<` was fixed: this branch re-breaking its own bug. Raised by
    # codex and reproduced.
    if not ms:
        return cmd
    m = ms[0]
    # An opener inside a STRING is not syntax either. Crude and per-alphabet, which is the
    # fail-CLOSED direction -- an opener this cannot vouch for is left alone.
    # RESIDUAL, reported and deliberately NOT chased: an ESCAPED quote counts here too, so a
    # prefix such as `echo it\'s;` reads as odd parity and refuses a recovery it could have
    # allowed. That is an over-block. Teaching this to skip escapes would loosen the one
    # guard standing between a false opener inside a string and a deleted quote -- the
    # direction every fail-open in this change came from -- for a shape nobody reported.
    if any(scan[:m.start()].count(_q) % 2 for _q in (_SQ, _DQ)):
        return cmd
    nl = scan.find("\n", m.end())
    if nl == -1:
        return cmd
    # The body starts after the opener's LOGICAL line. Bash removes a backslash-newline
    # before it reads redirections, so a continued opener pushes the body down; taking the
    # first physical newline instead pulls the continuation's own text INTO the body, and a
    # continuation carrying balanced quotes (`cat <<'EOF' \` / `"notes file.md"`) then lifts
    # the count below above one and refuses to recover an ordinary command.
    # Only an ODD run of backslashes continues: with `\\` the first escapes the second and
    # the newline still ends the line, and treating that as a continuation skipped the body's
    # first line instead. All three spellings raised by codex across the PR passes -- the
    # last of them after this walk had been deleted as unfireable, which it is not: the
    # mutation that missed it used a continuation line carrying no quotes.
    while nl > 0:
        k = nl
        while k > 0 and scan[k - 1] == chr(92):
            k -= 1
        if (nl - k) % 2 == 0:
            break
        nl = scan.find("\n", nl + 1)
        if nl == -1:
            return cmd
    tabs = "\t*" if scan[m.start():m.start() + 3].startswith("<<-") else ""
    delim = re.escape(next(g for g in m.groups() if g is not None))
    term = re.compile("^" + tabs + delim + "$", re.M).search(scan, nl + 1)
    if not term:
        return cmd
    # ONE heredoc in the command, counted OUTSIDE the body now that the body is known --
    # everything between the opener's line and the terminator is data, where `<<` is prose.
    # Counted as OPERATORS rather than as `_HEREDOC_QUOTED` matches, because that pattern
    # deliberately refuses a delimiter assembled from several quoting runs (`<<'E'2`) and
    # cannot see an unquoted `<<U` at all, so counting only its own matches let two further
    # heredocs hide beside the one it matched and reopened the parity bypass. Over a
    # continuation-JOINED copy, since bash removes a backslash-newline before it tokenizes
    # and `<\<D` is a real operator the raw text never spells. Each of these three was a
    # separate codex finding; joining and operator-counting only ever refuse MORE.
    # BOTH counts run out here, for the same reason: a body documenting `<<\END` produced a
    # second `_HEREDOC_QUOTED` match and a body writing `x << 1` a second operator, and either
    # one refused the recovery -- #639's false block, rebuilt out of the guard meant to make
    # the fix safe. The opener is `ms[0]`, which is sound because a match inside the body can
    # only come after it. Both raised by codex, one round apart.
    if sum(1 for x in ms if not (nl + 1 <= x.start() < term.start())) != 1:
        return cmd
    outside = (scan[:nl + 1] + scan[term.start():]).replace(chr(92) + "\n", "")
    if len(_HEREDOC_OP.findall(outside)) != 1:
        return cmd
    body = cmd[nl + 1:term.start()]
    # EXACTLY ONE quote character in the body -- see the docstring. The sub then fires only
    # if it is also WEDGED; an unwedged lone quote leaves the body untouched.
    if sum(body.count(_q) for _q in (_SQ, _DQ)) != 1:
        return cmd
    return cmd[:nl + 1] + _PROSE_QUOTE.sub("", body) + cmd[term.start():]


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
    if not ok:
        # RETRY, once, with the quoting dropped from every quoted heredoc body. The body of
        # a `<<'DELIM'` is literal to the outer shell, so an apostrophe in prose there is
        # the segmenter's own limitation rather than a broken command -- and abandoning to
        # the structureless probe over it blocks `cat > notes.md <<'EOF'` whose body merely
        # NAMES a helper, which is a command operators write repeatedly (#639).
        # Recovering the structure is what fixes it: the walk below then reads that name as
        # the operand it is, exactly as it already does for the identical command without
        # the apostrophe. A body that RUNS a helper still blocks -- the name reaches the
        # walk as a COMMAND WORD, which is the same evidence the parseable spelling uses.
        # Only reached when the plain parse FAILED, so no command that parses today changes.
        _sq = _squeeze_quoted_heredocs(cmd)
        if _sq != cmd:
            _pairs, ok = _split_with_ops(_norm_for_scan(_sq))
            if ok:
                # Both, or the walk reads one command and the whole-command answers below
                # read another: `_whole` is what the unresolvable-operand and marker tails
                # search, and it carries the same body.
                cmd, _whole = _sq, _squeeze_quoted_heredocs(_whole)
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
        # A here-string receiver runs its operand for the same reason a piped receiver runs
        # what the producer wrote, and both are answered by the same probe (#643).
        # `_whole`, NOT `cmd`: on recursion `cmd` is a FRAGMENT, and the unresolvable-operand
        # answer below searches the whole command for the helper. Passing the fragment made
        # `VAR='<helper>' sh -c 'sh <<< "$VAR"'` classify OK -- the nested scan saw the
        # unresolved operand but not the assignment, which lives only in the outer command.
        # Same variable every sibling call site here already threads through for this reason.
        for _prod in _herestring_shell_payloads(_pairs, _whole):
            _hit = _abandoned_scan_probe(_prod)
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
