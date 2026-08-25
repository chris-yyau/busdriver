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
import fnmatch, json, posixpath, re, shlex, string

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


def _bind_loop_vars(toks, simple_vars):
    # `for NAME in W...` / `select NAME in W...` bind NAME to each word of the list in
    # turn, so a marker named in the HEADER reaches a dangerous position in the BODY as
    # "$NAME" -- `for f in <marker>; do rm -f "$f"; done` (#638). The body is a separate
    # simple command and simple_vars persists across them, so recording the binding here
    # is all that the delete AND the redirect/tee/indirect-verb forge paths need; neither
    # `for` nor the header itself is a dangerous position, which is why _RESERVED_SH is
    # left alone.
    #
    # Space-JOINED, not concatenated: _match_marker substring-matches, and a separator
    # stops two adjacent list words assembling a basename that neither of them contains.
    #
    # LITERAL list words only, deliberately. A name the shell assembles at RUNTIME -- a
    # glob (`for f in .claude/*.local`), a positional parameter (`set -- <marker>`), a
    # function argument, `${f%x}`, a command substitution -- is the ADR 0006
    # runtime-name-synthesis residual already documented in _writes_marker: the value
    # never appears in the command text, so no static scan can see it, and anything able
    # to do it can `python3 -c` the write directly. The shape closed here is the ORDINARY
    # loop an agent writes without meaning to bypass anything, which is what #638 hit.
    # Leading RESERVED words are skipped with the list this module already keeps for
    # exactly that ("reserved words that PRECEDE a command"): `! for …`, `{ for …; }` and
    # `if for …; then` are the same literal loop with a prefix, and matching only toks[0]
    # let all three past. `function NAME {` is skipped too: it is the ksh spelling of
    # `NAME() {`, which already skips because `)` and `{` are reserved, so leaving it out
    # made one of two spellings of the SAME wrapper a bypass. `coproc NAME` is the only
    # other construct in the language that puts a NAME between a keyword and a compound
    # command, and `coproc` alone was already reserved -- so its optional NAME is the last
    # member of this family, not the next of infinitely many. The `for`/`select` guard
    # keeps the UNNAMED `coproc for f in …` (a loop AS the coprocess command) recognized:
    # `for` matches the NAME pattern, and eating it would have re-opened that shape.
    i = 0
    while i < len(toks):
        if (toks[i] == "coproc" and i + 1 < len(toks)
                and toks[i + 1] not in ("for", "select")
                and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", toks[i + 1])):
            i += 2                    # coproc's optional NAME -- a bash identifier
        elif (toks[i] == "function" and i + 1 < len(toks)
                and re.fullmatch(_FUNC_NAME, toks[i + 1])):
            # NO for/select exclusion here, unlike coproc above: `function` REQUIRES a name,
            # so `function for { … }` can only be a function literally named `for` (bash
            # accepts and runs it) -- never a loop as the wrapped command. Excluding those
            # two words left that spelling unskipped and the header unseen.
            # `function`'s NAME follows bash's broader function-name grammar (any word
            # free of the metacharacters that would end it, not just a plain identifier
            # -- `function x-y { … }` is valid bash), so it reuses _FUNC_NAME rather than
            # the identifier-only pattern coproc's NAME is held to. See _FUNC_NAME's
            # definition below for the KEEP IN STEP note with cmdword._FUNC_NAME.
            i += 2                    # the wrapper's optional NAME
        elif toks[i] in _RESERVED_SH:
            # The RAW token, not its basename: a reserved word is never path-qualified, so
            # `_bn` made an ordinary external command named `/tmp/if` read as shell syntax
            # and over-blocked a command that establishes no loop binding at all.
            i += 1
        else:
            break
    if (len(toks) > i + 3 and toks[i] in ("for", "select") and toks[i + 2] == "in"
            and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", toks[i + 1])):
        # APPEND, never overwrite: the loop body is a separate segment, so a destructive
        # write would ERASE a marker the variable already held and open a shape the plain
        # assignment path used to catch -- `f=<marker>; (for f in safe; do :; done);
        # rm -f "$f"`, where the subshell rebinding does not reach the parent at all.
        # Keeping both values over-approximates in the fail-CLOSED direction.
        name = toks[i + 1]
        prev = simple_vars.get(name, "")
        simple_vars[name] = (prev + " " + " ".join(toks[i + 3:])).strip()


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
# No split or variant here is a tokenizer or claims to be; the probe only ever yields more
# candidate patterns to test, so it can add a block and never remove one.
_OPERATOR_SPLIT_RE = re.compile(r"[\s;&|()<>]+")
# A VARIANT of the text for the same probe -- not a third split -- and the one that answers a
# SPACE inside the bracket expression (#708). Both splits above treat whitespace as a word
# boundary, so `lease_slo[\ t].py` -- a class whose members are a space and a `t` -- reaches
# fnmatch as two half-patterns and matches the helper nowhere, while the shell globs the whole
# word onto it. A whitespace inside a class is a MEMBER, so DELETING it leaves `[t]`, a pattern
# the existing splits already handle, and the class still matches the helper because the `t`
# survives.
#
# READ THIS BEFORE "FIXING" IT TO BE QUOTE-AWARE. Two quote-aware drafts were written and both
# were broken by codex in review: a quote-ADJACENCY boundary misses a space sitting inside a
# quoted run but next to neither quote, and a stateful left-to-right scanner is poisoned by any
# quote the shell never opened -- an apostrophe in a heredoc body or a comment -- while a
# scanner that resynchronises per line loses a run that legitimately spans one. Every one of
# those spellings was measured RUNNING the helper. The quoting is a hard question and this
# variant does not ask it: whatever the quoting, the whitespace that makes the class match is
# between a `[` and a `]`, so deleting it there closes all of them at once.
#
# Finding the `]` is the whole of the remaining difficulty, and a lazy `[^]]*` gets it
# wrong in two ways codex raised in review, both measured RUNNING the helper: a `]` is a
# literal MEMBER when it comes first (`[]...]`, and after a leading `!` or `^`), it is a
# member again when BACKSLASHED anywhere, and the `]` closing a POSIX class
# (`[[:space:]...]`) does not close the enclosing one. So the
# scan below follows the shell's own bracket grammar. It also visits each character a
# bounded number of times, where the regex rescanned the suffix from every `[` and so
# went quadratic on a run of unclosed brackets -- measured at 0.08s for 32k of them, well
# inside the gate's budget, but linear costs nothing to have.
#
# This is NOT the bracket-ATOMIC word boundary, which reopens #573 and was measured doing so.
# That draft made the class a unit and JOINED it to its neighbours, turning a bold markdown
# link in a PR body into one pattern matching every string that ends in a class member -- the
# helper name ends in `y`, and `my` supplies it. Deleting a member joins nothing: the
# whitespace OUTSIDE the class still separates words exactly as before, so that same PR body
# still splits where it always did and still matches the helper nowhere. Verified against
# #573's verbatim report, which section A of tests/test-marker-glob-specificity.sh pins.
# Both of those readings now happen in _class_members, which resolves a class to the
# characters it can match rather than rewriting it with a regex; the two regexes that
# used to sit here went with it.
# What each POSIX class stands for, spelled as members fnmatch can read. Deleting the
# sub-expression outright was the first attempt and it was wrong in the other direction:
# `[[:alpha:] ]` matches the helper ON the alpha member, so removing it left `[]`, which
# matches nothing. Raised by codex in review. The ranges are narrowed to the characters a
# helper name can hold, so this widens the pattern no further than it has to; an unknown
# or non-portable class name falls back to all of them, which is the fail-CLOSED side.
_POSIX_MEMBERS = {
    "alpha": set(string.ascii_letters),
    "alnum": set(string.ascii_letters + string.digits),
    "lower": set(string.ascii_lowercase),
    "upper": set(string.ascii_uppercase),
    "digit": set(string.digits),
    "xdigit": set(string.hexdigits),
    "word": set(string.ascii_letters + string.digits + "_"),
    "space": set(string.whitespace),
    "blank": set(" \t"),
    "punct": set(string.punctuation),
    "print": set(string.printable),
    "graph": set(string.printable) - set(string.whitespace),
}
# How many `]` to try as the terminator of one class, and how many distinct rewrites to
# hand back. Both are BUDGETS, and the residual they leave is stated in _class_variants:
# this probe is the last-resort scan for text nothing could parse, not a shell. Each
# extra reading is another whole pass plus its shell variants, so the cap is what keeps
# an adversarial command from buying unbounded work.
_CLOSE_CANDIDATES = 32
_CLASS_VARIANT_CAP = 160
_CLASS_DEEP_MAX_LEN = 4096
_CLASS_DEEP_MAX_CLOSERS = 64
# Bracket-bearing WORDS the full reading family may be spent on. Length and closer count
# bound how big the text is; this bounds the thing that actually MULTIPLIES, because the
# family is spent per word and every variant yields its own words again. Without it the cost
# peaked just UNDER the other two bounds -- 20 bracket words in front of a deep class sat at
# 62 closers, missed the closer bound by two, and took 4.18s against a hook registered with a
# 5s timeout, which on expiry is killed with NO decision on stdout and reads as allow. The
# extremes were already fast; the hole was the shape that stayed just inside every bound.
#
# COUNTED THE WAY THE SCAN SPLITS, which is on operators as well as whitespace. Counting
# `text.split()` alone made `v0=[a0];v1=[a1];...` a single word while the scan below still
# handed every one of those decoys its own deep reading -- 20 of them measured 16.65s, three
# times the timeout it was added to respect. A budget has to be spent in the same unit the
# work is done in; codex found the mismatch the round after the bound went in.
_CLASS_DEEP_MAX_WORDS = 4
# The longest class BODY that is resolved rather than refused. Bounds the one dimension the
# three above do not: they measure the TEXT, and this measures a single class inside it.
# Comfortably past any real bracket expression -- the helper names are 13 characters and the
# widest legitimate class in the fixtures is a POSIX name -- so this refuses only bodies built
# to be expensive. See _class_members for why refusing widens instead of narrowing.
_CLASS_BODY_MAX = 256
# Total BYTES of text the full reading family may be spent on across ONE command. The three
# bounds above measure a single string, and every one of them is satisfied by a word that is
# individually affordable -- so a command can simply repeat it. `_glob_helper` is asked per
# WORD at the structured call sites, where the word-count term is vacuously 1, and the number
# of those calls is bounded only by the token budget: ten segments each holding one 4KB
# bracket word measured 21.96s against a hook registered with a 5s timeout, where a killed
# hook emits no decision and the caller reads ALLOW. Measured after the budget: the same
# ten segments cost 1.50s and the figure no longer moves with the segment count, which
# is the property that matters -- an attacker cannot buy more by repeating.
#
# Running out is not a miss: _deep_affordable then answers False for every later word, which
# drops it to the base reading AND routes it through _bracket_prefix_hit, exactly as the
# size bounds do. Charged in bytes because a pass over the text is what the depth buys.
_DEEP_MAX_BYTES = 2048
_deep_budget = [0]
# Quote characters, replaced by a barrier that cannot take part in class syntax. See
# _class_members for why the quotes are read BOTH as removed and as barriers.
_QUOTE_BARRIER = re.compile("['" + chr(34) + "]")
# A quote INSIDE a bracket expression. Every reading in _class_variants rewrites a class it
# can delimit, and a quote in the body is exactly the case where the delimiting itself is in
# question: `[[:digit:"]"]` is not the POSIX digit class, because the quoted `]` stops `:]`
# from closing the sub-expression -- so the body is a plain member list holding `t`, and bash
# expands it onto the helper. The span walk cannot see that: it looks for `:]` in text the
# quoting has not been removed from, does not find it, and abandons the class. Removing the
# quotes first turns the same word back INTO the digit class, which matches nothing. Neither
# reading is the shell's, and the shell's needs quoting the walk no longer has.
#
# So a class body carrying a quote is not settled here at all -- _glob_helper answers it
# through _bracket_prefix_hit, on the same grounds as a multi-class word. `[^]]*` cannot
# cross a `]`, so this asks about the BODY and not about quotes elsewhere in the word:
# `grep '[[:alpha:] ]'` quotes the whole argument and is untouched.
# The shortest literal stem that counts as evidence on its own. Below it, see the note in
# _bracket_prefix_hit: a one-character prefix names a helper about as specifically as a bare
# wildcard does, which is the objection #573 was filed over.
_STEM_MIN_EVIDENCE = 3
# Ceiling on the class count that feeds the evidence sum. The sum only has to clear
# _STEM_MIN_EVIDENCE, so counting further buys nothing and a payload full of brackets should
# not be able to buy work with them.
_CLASS_COUNT_MAX = 8
# Characters shlex(punctuation_chars=True) breaks out as tokens of their own, so the
# quote-preserving splitter above agrees with it about where words end.
_PUNCT_TOKENS = frozenset("();<>|&")
# The lexer's whitespace, which is NOT str.isspace(): a vertical tab, a form feed, a NBSP or
# an ideographic space is whitespace to Python and an ordinary character to shlex. Splitting
# on the wider set made the two disagree over any argument containing one, which dropped the
# raw pass for the whole segment -- a decoy argument away from a bypass.
_LEX_WHITESPACE = frozenset(" \t\r\n")
# What can make the whitespace after a `[` a MEMBER rather than a separator, and so make
# two runs one shell word. A quote is the #708 spelling; a BACKSLASH does it just as well
# (`[x\\]\\ y\\ l]<tail>`), and leaving the escape out was an incompleteness on the
# fail-open side even though that shape happens to block through another reading.
_JOINS_WORDS_RE = re.compile("['" + chr(34) + chr(92) + chr(92) + "]")
_CLASS_QUOTE_RE = re.compile(r"\[[^]]*['" + chr(34) + "]")
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


# WHERE THIS PARSER IS TESTED, because the interactions below -- quotes, escapes, ranges,
# POSIX sub-expressions, which `[` opens and which `]` closes, and the search budgets -- are
# too combinatorial for example rows to cover on their own, and codex said so in review.
# tests/test-marker-glob-specificity.sh section F is a PROPERTY test rather than a fixture
# list: it generates class spellings, RUNS each one in a temp directory holding a stub helper,
# and requires every spelling the shell actually expanded onto that stub to be one this file
# blocks. A command that runs while the classifier allows it is the bug #708 reported, so the
# property is the bug's own negation. Section E carries the hand-picked shapes that discipline
# turned up, each row labelled with the draft it falsified, and tests/test-impl-gate-scope-519.sh
# seeds 3,000 payloads through the same execute-then-classify pairing.


def _class_members(body, negated, literal_hyphen=False):
    """The characters a bracket expression's BODY can match, narrowed to _HELPER_ALPHABET.

    Resolving the members is what makes this exact in BOTH directions, and both directions
    were review findings. Deleting the whitespace (#708) is right when the space is a MEMBER
    and wrong when it is a RANGE ENDPOINT -- `[<space>-u]` covers the helper's `t` and `[-u]`
    covers nothing. Widening the whole class to `?` fixed that and broke the other way, since
    `[a-b]` and `[[:digit:]]` then "matched" a helper they cannot reach. Both raised by codex.

    So nothing is guessed: ranges are expanded, POSIX classes are expanded, quotes are
    dropped as the syntax they are, and whitespace is dropped as a member no filename holds.
    Narrowing to the helper alphabet keeps the result small and is why an unresolvable class
    can still say "matches nothing" instead of "matches anything".
    """
    # A bound on the BODY, which is the one dimension _deep_affordable does not measure.
    # Cost is quadratic in body length -- the terminator search hands the whole intervening
    # span to this function once per candidate, across the whole combination space -- so a
    # SINGLE class body can be expensive while sitting inside every other budget: 4,084 bytes
    # with five closers and one bracket word measured 6.68s against a hook registered with a
    # 5s timeout, where a killed hook emits no decision and the caller reads ALLOW. That is
    # the same shape _CLASS_DEEP_MAX_WORDS was added for, reached through body length.
    #
    # Refusing to resolve widens to the WHOLE alphabet rather than narrowing to nothing, and
    # the difference is the whole point: an unresolved class must match a helper character,
    # not fail to. Returning here also lands BEFORE the negation below -- a negated over-long
    # class would otherwise compute `_HELPER_ALPHABET - _HELPER_ALPHABET` and match nothing,
    # which is the fail-OPEN side of exactly this decision.
    if len(body) > _CLASS_BODY_MAX:
        return set(_HELPER_ALPHABET)
    # TWO readings of the quotes, unioned, because neither one is right on its own and the
    # quoting that would decide it is gone by the time a pattern is matched.
    #
    #   - REMOVED, as the shell removes them before globbing. A range needs its `-` beside
    #     its endpoints, so `[' '-u]` is the range space..u -- which covers the helper's `t`
    #     -- and reading the quotes as three separate members missed it entirely.
    #   - BARRIERS, because a quoted character cannot take part in the SYNTAX around it.
    #     `[[:digit:"]"]` looks like the POSIX digit class and is not one: the quoted `]`
    #     stops `:]` from closing the sub-expression, so the body is a plain member list that
    #     includes `t`, and bash expands it onto the helper. Removing the quotes first turns
    #     it back into the digit class and matches nothing.
    #
    # Each reading is a real spelling that RUNS, codex found them one round apart, and the
    # union is what lets both be true without choosing. Unioning is safe for the same reason
    # every other reading here is added rather than substituted: it can only widen. The
    # barrier character is one no helper name holds, so it drops out with the alphabet.
    r1 = _resolve_members(body.replace("'", "").replace(chr(34), ""), literal_hyphen)
    r2 = _resolve_members(_QUOTE_BARRIER.sub(chr(1), body), literal_hyphen)
    if negated:
        # negate EACH reading and union the results. Negating the union instead intersects
        # the complements, which is NARROWER -- the fail-open direction.
        return (_HELPER_ALPHABET - r1) | (_HELPER_ALPHABET - r2)
    return r1 | r2


def _span_endpoint(body, p):
    """The single character a range endpoint at `p` denotes, and where it ends.

    An endpoint is not always one character of TEXT, which is the whole trouble. Quote
    removal leaves an escaped member behind (`[\\ -u]` reaches the matcher as `[ -u]`), and
    POSIX spells a collating element `[.a.]` and an equivalence class `[=a=]` -- and the
    shell accepts every one of those on either side of a `-`. Reading them only as
    standalone MEMBERS is what let `[\\ -u]` and `[[.a.]-[.z.]]` expand onto the helper
    while this file answered OK; codex found them one round apart.

    Returns (None, p) when `p` does not begin a single-character endpoint -- an unbalanced
    subexpression, a multi-character collating element, a `]` or a `-` -- so every caller
    can simply skip the span rather than guess at one.
    """
    n = len(body)
    if p >= n:
        return None, p
    if body[p] == chr(92) and p + 1 < n:
        return body[p + 1], p + 2
    if body[p] == "[" and p + 1 < n and body[p + 1] in ".=":
        k = body.find(body[p + 1] + "]", p + 2)
        if k >= 0 and k - (p + 2) == 1:
            return body[p + 2], k + 2
        return None, p
    if body[p] in "]-":
        return None, p
    return body[p], p + 1


def _resolve_members(body, literal_hyphen=False):
    """One reading of a class body, as the set of helper characters it can match."""
    out, i, n = set(), 0, len(body)
    while i < n:
        c = body[i]
        if literal_hyphen and c == "-":
            # the hyphen itself is the member under this reading
            out.add(c)
            i += 1
            continue
        if c == chr(92) and i + 1 < n:   # an escaped member
            esc = body[i + 1]
            out.add(esc)
            # ...and it may ALSO be a range ENDPOINT. Quote removal happens BEFORE globbing,
            # so `[\ -u]` reaches the matcher as `[ -u]` -- a span from space to `u` that
            # covers the helper's `t`. Reading the escape only as an isolated member saw
            # {space, -, u} and missed the span entirely:
            # `eval 'python3 <lib>/<stem>[\ -u].py'` RAN while this answered OK. #708's own
            # family -- the reported bug was a quoted space in a class, this is an escaped
            # one acting as an endpoint. ADDED rather than substituted, like every other
            # reading here, so it can only widen.
            if not literal_hyphen and i + 2 < n and body[i + 2] == "-":
                hi, _ = _span_endpoint(body, i + 3)
                if hi is not None and ord(esc) <= ord(hi):
                    out |= {ch for ch in _HELPER_ALPHABET
                            if ord(esc) <= ord(ch) <= ord(hi)}
            i += 2
            continue
        if c == "[" and i + 1 < n and body[i + 1] in ":.=":
            k = body.find(body[i + 1] + "]", i + 2)
            if k < 0:
                i += 1
                continue
            name = body[i + 2:k]
            if body[i + 1] == ":":
                out |= _POSIX_MEMBERS.get(name, _HELPER_ALPHABET)
            else:
                out |= set(name)
                # `[[.a.]-[.z.]]` is a RANGE whose endpoints happen to be spelled as
                # collating elements, and the shell reads it as one -- it expanded onto the
                # helper's `t` while only `a` and `z` were recorded here. A named class
                # (`[:alpha:]`) is not an endpoint, so only `.` and `=` qualify.
                if (not literal_hyphen and len(name) == 1
                        and k + 2 < n and body[k + 2] == "-"):
                    hi, _ = _span_endpoint(body, k + 3)
                    if hi is not None and ord(name) <= ord(hi):
                        out |= {ch for ch in _HELPER_ALPHABET
                                if ord(name) <= ord(ch) <= ord(hi)}
            i = k + 2
            continue
        if (not literal_hyphen and i + 2 < n and body[i + 1] == "-"
                and body[i + 2] not in ("]",)):
            lo, hi = c, body[i + 2]
            # The upper endpoint can be escaped too (`[a-\u]`), and quote removal drops that
            # backslash exactly as it drops the lower one's -- so the span may also run to
            # the character BEHIND the escape. ADDED as a second span, not substituted for
            # the first: reading the backslash itself as the endpoint is what this line
            # already did, and re-pointing it LOST members -- ` -\ ` spans space..backslash,
            # which covers `.`. A differential over 7,385 bodies caught that, which is the
            # whole reason readings here are only ever added. Advancement is left alone, so
            # the escaped character is simply re-scanned as an ordinary member.
            hi2, e2 = _span_endpoint(body, i + 2)
            if hi2 is not None and hi2 != hi and ord(lo) <= ord(hi2):
                out |= {ch for ch in _HELPER_ALPHABET
                        if ord(lo) <= ord(ch) <= ord(hi2)}
                if ord(lo) > ord(hi):
                    # The PLAIN reading is reversed -- in `[a-[.z.]]` the `[` that starts
                    # the collating element sorts below `a` -- and the reversed answer
                    # below is `set()`, the empty class. Falling into it would DISCARD the
                    # span just added, which is how this spelling still ran the helper
                    # after the endpoint reader already resolved it correctly. The
                    # subexpression reading is a real span the shell honours, so take it
                    # and step past the endpoint it ends at.
                    i = e2
                    continue
            if ord(lo) <= ord(hi):
                out |= {ch for ch in _HELPER_ALPHABET if ord(lo) <= ord(ch) <= ord(hi)}
                i += 3
                continue
            # REVERSED: this span alone matches nothing under the syntax reading, but the
            # shell keeps parsing the REST of the class rather than abandoning the whole
            # bracket expression -- `[a-zw-v]` still matches the helper's `t` via the
            # leading `a-z`, and `[q-p5]` still matches the literal `5` that follows,
            # both verified running bash. `return set()` here wiped `out`, discarding
            # every member a PRIOR span in this same class had already collected -- a
            # fail-OPEN miss (a command bash expands is read as OK) that Cursor found in
            # review. Skip just this span, keep what's already collected, and continue.
            # Reading the endpoints as two ordinary members instead said `[u-t]` could
            # reach the helper's `t` and blocked a command bash does not expand -- which
            # is why that reading is the OTHER variant rather than this one's fallback.
            #
            # SKIP THE WHOLE ENDPOINT, not a fixed 3 characters. `hi2`/`e2` above already
            # answered how far this endpoint's OWN spelling runs -- 2 for an escape
            # (`\t`), 5+ for a collating or equivalence element (`[.t.]`) -- and reaching
            # here with `hi2 is not None` means that answer is still valid; only the
            # comparison against `lo` decided this span was reversed, not the endpoint's
            # length. A fixed `+= 3` left the escape/collating element's OWN trailing
            # characters (`t` in `\t`, or `.t.]` in `[.t.]`) unconsumed, so the next loop
            # pass read them as ordinary MEMBERS -- widening `out` with characters that
            # were never a member on their own, which is the fail-OPEN direction one
            # level up: `_class_members` negates this SET, so a wrongly-added member
            # narrows what a negated class `[!...]` is read as reaching. Cursor found this
            # negated on a class ending `-\t]` reading `t` as reached in the POSITIVE
            # class and therefore NOT reached once negated, though bash's own `[!...]`
            # still matches `t` (the reversed span matches nothing either way). Falling
            # back to `i + 3` only when `hi2` is None (a bare `-` right after the first,
            # which `_span_endpoint` cannot resolve) preserves the original single-character
            # advance for every case that was already correct.
            i = e2 if hi2 is not None else i + 3
            continue
        out.add(c)
        i += 1
    out = {ch for ch in out if not ch.isspace()}
    return out & _HELPER_ALPHABET


def _squeeze_one_class(cls, literal_bang=False, literal_hyphen=False):
    """One bracket expression, rewritten as the members it can actually match.

    fnmatch and the shell do not read a class the same way -- a POSIX sub-expression is
    literal text to fnmatch, only `!` negates for it, and a `]` member has to come first --
    and on top of that #708's whitespace has to go. Rather than patch each disagreement,
    _class_members resolves the class to a SET and this rebuilds it in the one spelling
    fnmatch always reads correctly. See _class_members for why that is exact both ways.

    A class that can match nothing in a helper name is rewritten to a character no helper
    name contains, so the pattern stops matching rather than becoming a wildcard.
    """
    if len(cls) < 2 or cls[0] != "[" or cls[-1] != "]":
        return cls
    body = cls[1:-1]
    # `!`, `^` and `-` are class SYNTAX or ordinary MEMBERS depending on whether the shell
    # saw them quoted -- and by the time a class reaches here, the shell-variant it came from
    # has already removed the quoting that said which. `['!'t]`, `[\!t]` and `[u'-'t]` all
    # expand onto the helper while their unquoted twins `[!t]` and `[u-t]` expand nowhere,
    # and the two are the same characters by then. Codex found each of those in turn.
    #
    # So both readings are asked rather than one being guessed -- and they are asked
    # INDEPENDENTLY, because the two questions are independent: `['!'a-z]` has a literal `!`
    # AND a genuine `a-z` range, so a single flag covering both answered neither (the plain
    # reading negated the range, the literal one dissolved it). Codex caught that conflation.
    # See _class_variants.
    #
    # ACCEPTED OVER-BLOCK, named rather than discovered later: the literal reading also says
    # `[!t]` and `[u-t]` could reach a helper, so those now block although no shell expands
    # them. It is the same trade the #640 rows record, bounded the same way -- it costs only
    # operands already spelling out a helper's own stem -- and it is the fail-CLOSED side of
    # a question the text genuinely cannot answer.
    negated = body[:1] in ("!", "^") and not literal_bang
    if negated:
        body = body[1:]
    members = _class_members(body, negated, literal_hyphen)
    if not members:
        return chr(0)
    ordered = "".join(sorted(members))
    return "[" + ordered + "]"


def _deep_affordable(s):
    """Can the full reading family be spent on `s` without risking the hook's 5s timeout?

    Defined ONCE and asked by everything that needs it. It used to be written out separately
    at each site, and they drifted: _glob_helper never asked at all, so a structured operand
    padded past _CLASS_DEEP_MAX_LEN silently dropped to the base reading and reported a clean
    miss -- the same exhaustion-is-not-a-miss bug as _bracket_prefix_hit's, reappearing at a
    caller that could not see the budget. Codex found it. A shared predicate is the fix that
    keeps it from coming back a third time.

    Four terms, each measured rather than guessed, and each catching a shape the others let
    through: total SIZE, closer COUNT, how many bracket-bearing WORDS the family would be
    spent on -- counted the way the scan splits, on operators as well as whitespace -- and
    what is LEFT of the per-command byte budget.

    That last one is the only one that is not a property of `s`, and it is here because the
    other three are not: they ask whether ONE string is affordable, and a command can repeat
    an affordable string. At the structured call sites the question is asked per WORD, where
    the word term is vacuously 1, so nothing bounded the total until the budget did.
    """
    if _deep_budget[0] < len(s):
        return False
    if len(s) > _CLASS_DEEP_MAX_LEN or s.count("]") > _CLASS_DEEP_MAX_CLOSERS:
        return False
    return sum(1 for w in _OPERATOR_SPLIT_RE.split(s)
               if "[" in w) <= _CLASS_DEEP_MAX_WORDS


def _class_variants(s, deep=None):
    """`s` rewritten so fnmatch reads its bracket expressions the way the shell does -- in
    every reading that unquoted text does not settle. Deduped, and never including `s`.

    FOUR questions about a class are undecidable here, and they all have the same root:
    quote removal happens BEFORE globbing, so by the time a pattern is matched the quoting
    that made a character literal is gone. A `]` the quoting kept (`["x] "t]`) is a member,
    a stray `[` in a comment or in prose is no opener at all, and neither can be recognised
    from the text that survives. Each question is answered BOTH ways rather than guessed:

      - which `[` OPENS the class: the leftmost one, or the one NEAREST the terminator. A
        stray `[` -- in an assignment, in a comment, in prose -- is no opener at all, and a
        leftmost-only reading lets it swallow the real class. Pairing each `]` with the
        nearest `[` before it settles that however many strays there are.
      - which `]` CLOSES it: the one the grammar finds, or one of the next
        _CLOSE_CANDIDATES along. Quote removal happens BEFORE globbing, so a `]` the quoting
        makes literal (`[\"x] \"t]`) is a member the shell keeps and the grammar cannot see
        as one -- and a later class can follow in the same word (`[\"x] \"o][t]`).
      - spans confined to a line, or free to cross newlines. A quoted run may legitimately
        cross one; a stray `[` on an unrelated line must not reach across.
      - whether the terminator search may step over a `[`. Quote removal runs BEFORE
        globbing, so a quoted opener is a literal MEMBER of the class it sits in and is
        indistinguishable here from one that opens a new class. `["x][o"]` is the first
        and `[a][t]` is the second. See _skip_closers.

    EXHAUSTION IS NOT A MISS. The budgets here bound how much SEARCHING is done, and they
    used to bound the answer with it: a class carrying more than _CLOSE_CANDIDATES quoted `]`
    members, or text past _CLASS_DEEP_MAX_LEN or _CLASS_DEEP_MAX_CLOSERS, ran out of readings
    and reported no helper for a command the shell expands straight onto one. Codex raised it
    at confidence 100 and it was reproduced RUNNING. Callers now answer an exhausted search
    through _bracket_prefix_hit instead, which needs no terminator at all -- read it for why a
    word's literal stem is a sound superset of every reading this search would have found.
    Measured after that change: the whole family blocks, 10 through 80 quoted members, and
    the padded shapes get FASTER because the fallback answers without the search.

    So the budget now buys only time, which is what it was for -- it stops an adversary
    buying unbounded work from a gate with a 5s allowance. Measured at 0.07s for 8,000
    alternating `[x]` against 0.12s at HEAD, and 0.14s for the 800 `[a]` words in 3.2KB that
    an earlier draft spent 9.1s on; an unbounded draft took 6.1s.

    Note the depth is spent PER CLASS, not once for the whole string: _extend_to_useful picks
    each class's terminator locally, so two classes in one operand can take different ones.
    Choosing once globally was an earlier design and it left exactly that shape open.

    The bound is NAMED and measured rather than tuned until the last reviewer ran out of
    ideas, because every finite search has an outside and pretending otherwise is how this
    ended up rewritten five times. What is left outside is no longer the SIZE of a class --
    that is answered by the fallback above -- but PROVENANCE: quote removal happens before
    globbing, so after it a `!`, `^`, `-` or `]` is genuinely ambiguous between syntax and
    member, and a spelling that exploits that reads differently here without ever exhausting
    anything. That residual is accepted. This is the LAST-RESORT probe for text nothing could
    parse, it is defence in depth, and the helpers have been safe by construction since #519.

    AND A QUOTE INSIDE THE BODY puts the delimiting itself in question, which is prior to
    every reading below -- see _CLASS_QUOTE_RE. Those words are not read here either.

    ALL FOUR ARE CHOSEN PER WORD, which is only the same as per class while the word holds
    ONE class. With two, the choices are coupled and no single combination reads both -- the
    first class may need the crossing terminator while the next needs the default, or one may
    quote the `!` that the next uses to negate. A cross product over classes is the honest
    model and a budgeted one would just move the edge, so a multi-class word is not settled
    here at all: _glob_helper answers it through _bracket_prefix_hit, which needs no reading.
    See _count_classes. Codex found all three couplings in one round, each measured running.

    None of the four has to be right on its own. The probe blocks if ANY reading matches,
    which is the same monotonicity the splits have: a variant only ever adds a candidate
    pattern, so this can add a block and never remove one. That is also what makes a reading
    safe to ADD and dangerous to CHANGE -- the quoted-opener case had to become a dimension
    rather than a loosening, because `close` counts closers and crossing changed where every
    index LANDS, which silently removed the reading that caught two classes each needing
    their own terminator. Every combination here exists because the one before it was
    measured RUNNING the helper -- the stray opener, the quoted `]`, the class spanning a
    newline and the quoted `[` all came out of review or the generator.
    """
    # `deep` spends the terminator search, and it is spent ONLY where it is affordable.
    # Each candidate is a whole pass over the text, so asking all of them once per candidate
    # WORD is what made this expensive: profiled at 40,005 calls and 1.9M passes -- 6.1s --
    # on 8,000 alternating `[x]` piped to a shell, against 0.12s at HEAD. Codex raised the
    # cost in review. Callers that already hold one extracted word pass deep=False: the
    # ambiguity the search exists for is WHERE THE TEXT SPLITS, which a whole word has
    # already settled. Left to itself the depth is chosen by size, and the base reading
    # always runs -- what a large input loses is extra terminators, never the scan.
    if "[" not in s or "]" not in s:
        return []
    if deep is None:
        deep = _deep_affordable(s)
    if deep:
        # Charged where the work is actually done, so the same word cannot be paid for twice
        # by the predicate being asked about it twice -- and re-checked here, because the
        # budget is the one term in _deep_affordable that is not a property of `s`. An
        # EXPLICIT deep= never consults it: the abandoned-scan probe settles the question
        # once for a whole family of variants, so without this the family would charge
        # without ever checking. Refusing costs nothing that matters -- it drops to the base
        # reading AND routes through _bracket_prefix_hit, the same fail-CLOSED answer every
        # other exhausted bound gives.
        if _deep_budget[0] < len(s):
            deep = False
        else:
            _deep_budget[0] -= len(s)
    out = []
    for perline in (False, True) if deep else (False,):
        for nearest in (False, True) if deep else (False,):
            for close in range(_CLOSE_CANDIDATES if deep else 1):
                for cross in (False, True) if deep else (False,):
                    for bang in (False, True):
                        for hyphen in (False, True):
                            v = _squeeze_bracket_ws(
                                s, close, perline, nearest,
                                lambda c, b=bang, h=hyphen: _squeeze_one_class(c, b, h),
                                cross)
                            if v != s and v not in out:
                                out.append(v)
                                if len(out) >= _CLASS_VARIANT_CAP:
                                    return out
    return out


def _squeeze_bracket_ws(s, close=0, perline=False, nearest=False, rewrite=None,
                        cross=False):
    """`s` with every bracket expression put through _squeeze_one_class.

    See _class_variants for what `close`, `perline` and `nearest` decide, why every answer
    is asked, and what the budget leaves behind. An unterminated `[` ends the scan: there is
    no class, so there is nothing to rewrite.
    """
    span = _nearest_span_classes if nearest else _squeeze_span_classes
    rewrite = rewrite or _squeeze_one_class
    if not perline:
        return span(s, close, rewrite, cross)
    return "".join(span(line, close, rewrite, cross) for line in s.splitlines(True))


def _extend_to_useful(s, a, j, rewrite):
    """Push the terminator past `]` members the QUOTING made literal -- per class, locally.

    A class is extended only while it resolves to NOTHING a helper name contains, which is
    what a prematurely-cut class looks like: `[\"x]` holds only `x`, and no guarded helper
    has one. `[\"x] o\"]` holds `o`, so the extension stops there. Deciding this per class
    rather than by one global choice is what lets two classes in the same operand take
    DIFFERENT terminators -- `[\"x] o\"][\"x] y] t\"]` needs exactly that, and codex used it
    against every version that chose once for the whole string.

    It never crosses a `[`, and unlike _skip_closers it must not. This extension is the
    DEFAULT terminator for every class in the operand -- it is not one reading among several,
    so widening it REPLACES a reading rather than adding one. Measured: crossing here made
    `<stem>["x] o"]["x] y] t"]`, two classes each needing a different terminator, stop
    blocking, because the first class swallowed the second's opener and neither landed. The
    quoted-opener case that motivates crossing is answered in _skip_closers instead, where it
    IS one reading among several and can only add.
    """
    for _ in range(_CLOSE_CANDIDATES):
        if rewrite(s[a:j + 1]) != chr(0):
            return j
        nxt = s.find("]", j + 1)
        if nxt < 0 or "[" in s[j + 1:nxt]:
            return j
        j = nxt
    return j


def _skip_closers(s, j, close, cross=False):
    """`close` further `]` along from `j`, as far as there are. `cross` steps over a `[`.

    The jump exists for a `]` the QUOTING made a member. Whether it may pass an OPENER is
    the thing that cannot be decided here, so it is asked both ways rather than answered:

      - not crossing reads `<stem>[a][t].py` as the two classes bash sees. Bash cannot put
        two characters in one position, so it expands to nothing and this must not block.
      - crossing reads `<stem>["x][o"]t.py` as the ONE class bash sees, whose members
        include a literal `[` -- quote removal runs before globbing, so by the time a pattern
        is matched a quoted opener and a real one are the same character. Bash expands that
        onto the helper. Codex reproduced it running.

    Both are real spellings and neither reading covers the other, which is why this is a
    DIMENSION and not a fix. Making it one was the second attempt: dropping the refusal
    outright looked additive and was not, because `close` counts closers and crossing changes
    where every index LANDS -- the reading that caught two classes each needing their own
    terminator stopped being reachable at all, and its regression row caught that.
    """
    for _ in range(close):
        nxt = s.find("]", j + 1)
        if nxt < 0 or (not cross and "[" in s[j + 1:nxt]):
            break
        j = nxt
    return j


def _nearest_span_classes(s, close, rewrite, cross=False):
    """_squeeze_span_classes, but each `]` is paired with the NEAREST `[` before it.

    The reading that survives a stray opener: `X='[' python3 <helper>[' 't].py` puts a `[`
    in an assignment, and pairing from the left hands the whole line to it. Measured running
    the helper; codex in review.
    """
    out, i, n = [], 0, len(s)
    while i < n:
        j = s.find("]", i)
        if j < 0:
            break
        # Neither end may be a POSIX / collating sub-expression's own bracket: `[:digit:]`
        # inside `[[:digit:]]` is a MEMBER LIST, not a class, and pairing its brackets read
        # the digits as the class -- which blocked `<helper-stem>[[:digit:]].py`, an operand
        # that cannot expand onto a helper at all. Codex raised the false positive in review.
        while 0 < j < len(s) and s[j - 1] in ":.=" and s.rfind("[", i, j) >= 0 \
                and s[s.rfind("[", i, j) + 1:s.rfind("[", i, j) + 2] in ":.=":
            nxt = s.find("]", j + 1)
            if nxt < 0:
                break
            j = nxt
        j = _skip_closers(s, j, close, cross)
        a = s.rfind("[", i, j)
        while a >= 0 and s[a + 1:a + 2] in ":.=":
            a = s.rfind("[", i, a)
        if a < 0:
            # No opener for this `]`, so it is ordinary text -- and it has to be EMITTED.
            # Dropping it rewrote `junk]<helper>[a].py` into `<helper>?.py` and blocked an
            # operand whose literal prefix is what stopped it naming the helper. Codex in
            # review; a deletion here invents matches rather than finding them.
            out.append(s[i:j + 1])
            i = j + 1
            continue
        out.append(s[i:a])
        out.append(rewrite(s[a:j + 1]))
        i = j + 1
    out.append(s[i:])
    return "".join(out)


def _squeeze_span_classes(s, close, rewrite, cross=False):
    """One span of _squeeze_bracket_ws -- the whole text, or a single line of it."""
    out, i, n = [], 0, len(s)
    while i < n:
        a = s.find("[", i)
        if a < 0:
            break
        j = a + 1
        if j < n and s[j] in "!^":          # a negated class
            j += 1
        if j < n and s[j] == "]":           # a `]` FIRST is a member, not the terminator
            j += 1
        while j < n and s[j] != "]":
            # A BACKSLASHED character is a member, `]` included -- only a bare one closes the
            # class. Measured running the helper before this line existed; codex in review.
            if s[j] == chr(92) and j + 1 < n:
                j += 2
                continue
            # [:alpha:] [.x.] [=x=] -- the inner `]` belongs to the sub-expression. NO
            # closer at all is not an abandoned class: bash reads an unterminated
            # `[:`/`[.`/`[=` as ordinary members and keeps scanning for the class's own
            # `]`, which is what _resolve_members already does for the class BODY -- this
            # boundary scan was abandoning the whole class instead, reporting no class at
            # all for `<stem>[^[[=].py`, which bash expands onto the helper. Codex found it
            # running.
            if s[j] == "[" and j + 1 < n and s[j + 1] in ":.=":
                k = s.find(s[j + 1] + "]", j + 2)
                if k >= 0:
                    j = k + 2
                    continue
            j += 1
        if j >= n or s[j] != "]":
            break
        j = _extend_to_useful(s, a, j, rewrite)
        j = _skip_closers(s, j, close, cross)
        out.append(s[i:a])
        out.append(rewrite(s[a:j + 1]))
        i = j + 1
    out.append(s[i:])
    return "".join(out)


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


def _strip_redirs_kept(toks):
    """Indices of `toks` that `_strip_redirs` would KEEP, in order.

    Split out so a caller holding a SECOND list that lines up positionally with `toks` --
    the raw, still-quoted spelling of the same tokens -- can filter it identically instead
    of re-deciding redirect-ness against its own text. Re-deciding is what broke: `_is_redir`
    reads a token by VALUE, and a raw token still carries its quote marks (`'">"'`) where the
    dequoted one does not (`>`), so a quoted redirect-looking argument reads as an operator on
    one list and an ordinary word on the other -- not a genuine disagreement about which
    tokens survive, just two different spellings of the same decision answering differently.
    Deciding ONCE, on the dequoted list where `_is_redir` is meant to be asked, and applying
    the same indices to the raw list keeps both filtered lists the same length by
    construction. Codex found the asymmetry: `python3 safe[a].py ">" ignored
    'lease_slo["x"]t.py'` diverged in length here, which dropped the raw pass and fell through
    to the whole-segment `_bracket_prefix_hit` fallback, BLOCKing on an unrelated later
    argument that only mentions the helper's shape.
    """
    out, skip = [], False
    for i, t in enumerate(toks):
        if skip:
            skip = False
            continue
        if _is_redir(t):
            skip = True          # the following token is this redirect TARGET, not a verb
            continue
        out.append(i)
    return out


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
    kept = _strip_redirs_kept(toks)
    return [toks[i] for i in kept]


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
    # A loop binding a plain NAME=VALUE walk cannot see (#638), recorded before the token
    # walk so the body segment that follows resolves "$NAME" through simple_vars.
    _bind_loop_vars(toks, simple_vars)
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
    # `for NAME` / `select NAME` may place a real (unescaped) newline before `in` --
    # `for f\nin <marker>; do rm -f "$f"; done` is accepted by bash exactly like the
    # single-line form, and the newline-to-separator rule below would otherwise split it
    # into a bare `for f` plus `in ...`, hiding the header from _bind_loop_vars and
    # un-blocking the marker-delete-via-loop-variable shape #638 closed.
    #
    # The NAME may be QUOTED or ESCAPED -- for 'f', for "f", for \\f, for f'' all
    # dequote to the same variable and bash accepts each. Only this regex was narrower
    # than the binder behind it: on a SINGLE line all four already blocked, because
    # shlex dequotes before _bind_loop_vars sees the token. So the class tolerates those
    # bytes and nothing else changes -- this regex only decides WHETHER to rejoin the
    # header; extracting the name stays with shlex, so no dequoting is modelled here.
    # What may follow `in` is an ALLOW-list, not a deny-list. `\b` matched between `n`
    # and `=`, so `in=<marker>`, `in+=<marker>` and `in[0]=<marker>` were all read as
    # loop headers; rejoining then deleted the newline BEFORE them -- a real command
    # separator -- which hid the assignment and turned a marker write from BLOCK into
    # OK. Excluding characters one at a time just moves the hole (`=` -> `+=` -> `[`),
    # so this states the only things that can follow the KEYWORD instead: whitespace,
    # a `;` (the empty-list `for f in; do …`), or end of input. Anything else means the
    # token is not `in` and nothing is rejoined.
    # A COMMENT may sit in the gap too -- `for f # note<newline>in <marker>; …` and
    # `for f<newline># note<newline>in <marker>; …` are both valid bash, so the gap
    # accepts an optional `#...` on each line it spans. Without that the header split
    # again and the same delete walked through.
    #
    # Ordered AFTER _defuse_comments, deliberately. Run BEFORE it, this rejoin also
    # matches a `for NAME` sitting inside a comment and deletes the newline that ENDS
    # that comment -- `for x # for f<newline>in a; do touch <marker>; done` folded the
    # whole command onto the comment line, so defusing then swallowed the real write
    # and the classifier returned OK. Note what defusing does and does NOT do: it
    # BLANKS the separators inside a comment and keeps every other byte, so the
    # `for`/`in` words in a comment DO still reach this regex. Running after it is
    # what makes rejoining them harmless -- the comment's extent is already fixed, so
    # folding the line can no longer pull live code into it.
    norm = re.sub(r"\b(for|select)"
                  r"([ \t]+[A-Za-z_'\"\\][A-Za-z0-9_'\"\\]*)"
                  r"(?:[ \t]*(?:#[^\n]*)?\n)+[ \t]*(in)(?=[ \t;\n]|$)",
                  r"\1\2 \3", norm)
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

# Every character any guarded helper name contains. A class is only ever asked whether it
# can reach one of THOSE, so resolving its members against this stays small and exact --
# and a class that reaches none of them can be said to match nothing, which is what keeps
# `[a-b]` and `[[:digit:]]` from being read as evidence.
_HELPER_ALPHABET = set("".join(_MUTATING_HELPERS))

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


def _glob_helper(word, deep=None):
    """The helper FILE a GLOB operand can expand to, or None.

    The shell resolves `lease_slo?.py` against the filesystem, so the question is not
    whether the literal spelling names a helper -- it never does -- but whether the
    PATTERN can. Asking that directly beats searching the command text for a helper
    stem, which a single wildcard in the middle of the name defeats.

    Asked of the word as written AND of its class-squeezed form (#708), because fnmatch and
    the shell do not read a bracket expression the same way: a whitespace MEMBER is legal to
    the shell and splits nothing here, but `[[:alpha:]t]` is a POSIX class to the shell and
    a run of literal characters to fnmatch, so the pattern the operand really stands for
    matched nowhere. _squeeze_bracket_ws is what reconciles the two. Asked here rather than
    only in _abandoned_scan_probe because the STRUCTURED walk reaches this with a whole
    operand -- a heredoc payload the parser could read, say -- and never goes near the probe.
    Found by generating class spellings and EXECUTING each one, after codex had raised the
    same disagreement twice from the probe side.
    """
    seen = set()
    # Resolved BEFORE _class_variants can charge the deep budget, and reused below instead
    # of asked again afterward. Asking again re-tests the SAME word's length against the
    # budget the call just DEBITED for it, so a word that was affordable -- and got the full
    # deep search it paid for -- can price itself out of its own answer once the charge
    # lands, over-blocking a precise miss like `<stem>[a].py`. Cursor and Codex both raised
    # this from the same post-charge recheck in review.
    was_affordable = deep if deep is not None else _deep_affordable(word)
    variants = _class_variants(word, deep)
    for cand in [_bn(word)] + [_bn(v) for v in variants]:
        if cand in seen:
            continue
        seen.add(cand)
        try:
            pat = re.compile(fnmatch.translate(cand))
        except (re.error, TypeError):
            return _MUTATING_HELPERS[0]      # unparseable pattern: fail closed
        hit = next((h for h in _MUTATING_HELPERS if pat.match(h)), None)
        if hit:
            return hit
    # A search that hit a budget has not cleared this word -- see _bracket_prefix_hit.
    #
    # An EXPLICIT deep=False is not a budget: a caller passing it has settled the split
    # itself, and treating that as exhaustion would answer every probe word through the
    # fallback and start over-blocking the precise cases (`<stem>[a].py`) this change works to
    # keep. An INTERNAL one is, which is the case codex found -- a structured operand padded
    # past _CLASS_DEEP_MAX_LEN with quotes the shell removes drops to the base reading, and
    # the base reading stops at the first quoted `]`. Verified at the function: the padded
    # word returned None where the same word unpadded returned the helper.
    if (len(variants) >= _CLASS_VARIANT_CAP
            or word.count("]") > _CLOSE_CANDIDATES
            or (deep is None and not was_affordable)
            or _count_classes(word) >= 2
            or _CLASS_QUOTE_RE.search(word)):
        return _bracket_prefix_hit(word)
    return None


# Quote removal happens BEFORE globbing, so these characters are syntax the shell has
# already dropped by the time a pattern is matched. A stem read with them still in it is a
# stem the shell never sees: `lease_\\s\\l` and `lease_"sl"` both reach the filesystem as
# `lease_sl`. Codex found the escaped spelling walking straight through the fallback below.
_STEM_SYNTAX = {ord(c): None for c in "'" + chr(34) + chr(92)}


def _raw_words(text):
    """`text` split into shell WORDS with the quoting left in.

    Same word boundaries the posix lexer finds -- quoted whitespace joins, a backslash
    joins -- but the quotes and escapes survive, which is the whole point: they are what
    decides a bracket class, and the lexer that resolves the operand has already thrown them
    away. shlex cannot do this: asked for non-posix mode it keeps the quotes but stops
    treating quoted whitespace as part of the word, so `["x] y] l"x]<tail>` came back as four
    tokens where the shell sees one, and no pairing was possible at all.
    """
    out, cur, q, started = [], "", "", False
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if q:
            # Inside DOUBLE quotes a backslash still escapes, which is how the lexer reads
            # it; inside single quotes nothing does. Missing this made the splitter disagree
            # with the lexer on `"a\\b"` and `"a\"b"` -- and a disagreement DROPPED the
            # raw pass, which was a bypass rather than a lost refinement. See below.
            if ch == chr(92) and q == chr(34) and i + 1 < n:
                cur += ch + text[i + 1]
                i += 2
                continue
            cur += ch
            if ch == q:
                q = ""
            i += 1
            continue
        if ch in ("'", chr(34)):
            q, cur, started = ch, cur + ch, True
            i += 1
            continue
        if ch == chr(92) and i + 1 < n:
            cur, started = cur + ch + text[i + 1], True
            i += 2
            continue
        if ch in _PUNCT_TOKENS:
            if started:
                out.append(cur)
            cur, started = "", False
            j = i
            while j < n and text[j] in _PUNCT_TOKENS:
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if ch in _LEX_WHITESPACE:
            if started:
                out.append(cur)
            cur, started = "", False
            i += 1
            continue
        cur, started = cur + ch, True
        i += 1
    if started:
        out.append(cur)
    return out


def _dequote_lex(word):
    """`word` with its quoting resolved, the way the LEXER resolves it.

    Named apart from the older _dequote above, which only strips quote CHARACTERS and is
    what the indirection scan and the probe's dequoted reading are written against. Defining
    a second `_dequote` shadowed that one and silently re-pointed three unrelated call sites
    at these stricter semantics.
    """
    out, q, i, n = "", "", 0, len(word)
    while i < n:
        ch = word[i]
        if q:
            # Inside a double quote, a backslash escapes only a quote or itself --
            # `shlex` (what the raw/lexed comparison is checked against) leaves a
            # backslash before any OTHER character, including `$` and a backtick,
            # untouched and literal. Without this, `\"` inside a double-quoted word
            # was read as an ordinary character, so the very next `"` closed the
            # quote early -- splitting `"quoted \"value\""` into extra tokens the
            # raw pass never sees, which false-triggers the whole-segment
            # raw_dropped fallback. Cursor/Codex in review.
            if (q == chr(34) and ch == chr(92) and i + 1 < n
                    and word[i + 1] in (chr(34), chr(92))):
                out += word[i + 1]
                i += 2
                continue
            if ch == q:
                q = ""
            else:
                out += ch
            i += 1
            continue
        if ch in ("'", chr(34)):
            q = ch
            i += 1
            continue
        if ch == chr(92) and i + 1 < n:
            out += word[i + 1]
            i += 2
            continue
        out += ch
        i += 1
    return out


def _count_classes(s, stop=2):
    """How many bracket expressions the GRAMMAR finds in `s`, counting no further than `stop`.

    Asked for ONE thing: whether a word holds more than one class. Every reading dimension in
    _class_variants -- which `]` closes, whether to cross a `[`, `!` as negator, `-` as range
    -- is chosen ONCE PER WORD, and that is only equivalent to choosing per class while there
    IS one class. With two, the readings are coupled: codex expanded `lea["x][s"]e_[s][l]ot.py`
    onto the helper, where the first class needs the crossing reading and the two after it need
    the default, and did the same for `!` and for `-` with one class quoting the operator and
    the next using it. Enumerating per class instead is a cross product, and a budgeted cross
    product would only move the edge, so a multi-class word is treated as what it is -- not
    settled by these readings -- and answered by _bracket_prefix_hit, which needs no reading
    at all. Both directions were measured running.

    It follows the same grammar the span walkers do, which is why it must count CLASSES rather
    than `[` characters: `[[:digit:]]` holds two openers and is one class, and counting
    characters would have blocked it -- a row this suite pins as allowed.
    """
    n, i, count = len(s), 0, 0
    while i < n:
        a = s.find("[", i)
        if a < 0:
            break
        j = a + 1
        if j < n and s[j] in "!^":
            j += 1
        if j < n and s[j] == "]":
            j += 1
        while j < n and s[j] != "]":
            if s[j] == chr(92) and j + 1 < n:
                j += 2
                continue
            # Same terminator-abandonment bug as _squeeze_span_classes, same fix: an
            # unterminated `[:`/`[.`/`[=` is an ordinary member here too, not a reason to
            # give up on the class. Without this, `<stem>[^[[=].py` counted zero classes,
            # which routed it past the multi-class fallback and every other guard below --
            # a fail-OPEN miss, not just an under-count.
            if s[j] == "[" and j + 1 < n and s[j + 1] in ":.=":
                k = s.find(s[j + 1] + "]", j + 2)
                if k >= 0:
                    j = k + 2
                    continue
            j += 1
        if j >= n or s[j] != "]":
            break
        count += 1
        if count >= stop:
            return count
        i = j + 1
    return count


def _bracket_prefix_hit(text):
    """The helper a bracketed word could reach under ANY reading of its class, or None.

    Reached ONLY where the terminator search was ABANDONED rather than finished -- the
    budgets in _class_variants. This file already settles what an abandoned scan means, at
    _HELPER_MAX_TOKENS: a scan that ran out has not found "no helper", it has found nothing
    at all, and nothing at all is the fail-CLOSED case. The class search was the one budget
    still reporting exhaustion as a clean miss, so a class carrying more quoted `]` members
    than _CLOSE_CANDIDATES bought an allow. Raised by codex at confidence 100.

    The answer is an over-approximation rather than a wider search, because widening only
    moves the same edge further out. A bracket expression matches EXACTLY ONE character and
    everything past the opener is then arbitrary, so whatever the class turns out to mean,
    the word can only expand to something starting with the LITERAL text before its first
    `[`. Asking that literal + `*` is therefore a superset of every reading the abandoned
    search would have produced -- sound by construction, and it needs no terminator at all.

    ONLY THE FIRST `[` of each path SEGMENT is asked, and that is what makes this O(n)
    rather than a budgeted search that could fail open again. Within one anchor, a later
    class yields a LONGER prefix, and a longer prefix at the same anchor is a NARROWER
    pattern -- `a*` already covers `a[x]b*` -- so the first one subsumes every other. The
    same argument covers an escaped `\\[` that is no opener at all: reading it as one
    shortens the prefix, and shorter at this anchor is wider. There is therefore no candidate
    budget here to exhaust. An earlier draft capped the candidates and codex broke it in one
    round, by parking 64 harmless bracket words in front of the real one -- the identical
    fail-open this function exists to close, one level up.

    SEGMENT, not run, because `/` MOVES THE ANCHOR. A helper is matched on its basename, so
    the prefix that matters is the one beginning after the last separator -- and a class in a
    DIRECTORY component supplies a first `[` that answers about a different anchor entirely.
    Asking only the run's first bracket read `hooks/gate-script[s]/lib/<helper-glob>` as a
    question about `gate-script*` and never asked about the basename at all, which codex
    found in the round after the cap came out. Every segment is asked instead of just the
    last, which also covers a `/` that quoting put INSIDE a class: whichever way the shell
    reads that, one of the segments carries the real anchor.

    What it costs is precision, in the one direction that is safe to lose it: the fallback
    blocks any exhausted word whose literal stem already spells the front of a helper name.
    That is the same bounded over-block the rest of this change accepts, and it cannot reach
    ordinary prose, which does not spell one.

    The #573 release rule is kept: a candidate of nothing but `*` matches every string that
    exists, so it is evidence of nothing and is let go. Everything else is decided by HOW MUCH
    LITERAL the word supplies, from both ends -- see the note at the test itself.

    That release applies to EVERY caller, and deliberately so -- an earlier draft scoped it
    to the structureless ones and the scoping is gone. What makes it safe without scoping is
    that it is no longer a judgement about context: reaching it needs the stem, the tail and
    the class count together to total less than _STEM_MIN_EVIDENCE, which leaves a word too
    short to spell a helper name whoever is asking. The version that DID need scoping was the
    one that released on an empty stem alone, and it was a hole at the structured sites
    exactly as a reviewer said; it is not what this code does now.

    Runs are taken BOTH ways the probe takes them, on whitespace and on shell operators,
    because `foo;<helper-glob>` is one whitespace run and two commands.

    IT ANSWERS ABOUT A WORD, NOT ABOUT A COMMAND. Whether the word is being RUN is decided
    by the callers, which is the only place it can be decided honestly: _helper_invoked knows
    what is in command position, and this function is looking at structureless text. Asking
    the question here -- "does an interpreter stand in front of it?" -- was tried and is what
    the note at the evidence test describes; keeping the two separate is the fix.
    """
    # The literal tail of the WHOLE text, not just of one run. A class holding quoted
    # whitespace spans runs -- that is #708 itself -- so the `[` and the helper tail land in
    # different ones and neither is evidence alone: `eval 'python3 ["x] y] ... l"x]<tail>'`
    # leaves the opener in the first run and `<tail>` in the last. Under every reading the
    # class ends at SOME `]`, so the text after the LAST one is literal, and it is cut at the
    # next whitespace so a whole PR body cannot be swept in behind one bracket.
    _e = text.rfind("]")
    gtail = ""
    if _e >= 0:
        gtail = text[_e + 1:].split(None, 1)[0] if text[_e + 1:].split(None, 1) else ""
        gtail = gtail.translate(_STEM_SYNTAX)
    seen = set()
    for runs in (text.split(), _OPERATOR_SPLIT_RE.split(text)):
        for run in runs:
            if "[" not in run:
                continue
            for seg in run.split("/"):
                k = seg.find("[")
                if k < 0:
                    continue
                # The literal TAIL as well as the literal stem. Whatever the class turns out
                # to mean it cannot extend past the LAST `]` in the segment, so the text
                # after it is literal under every reading -- the same argument as the stem,
                # run from the other end. Taking both is what let the context heuristic go.
                e = seg.rfind("]")
                stem = seg[:k].translate(_STEM_SYNTAX)
                tail = seg[e + 1:].translate(_STEM_SYNTAX) if e > k else ""
                # A CLASS is evidence as well as a literal, because each one stands for
                # exactly ONE character and so pins a LENGTH. `l[e][a][s][e][_][s][l][o][.]
                # [p]y` supplies two literal characters and eleven classes, and it is the
                # eleven that make `l*y` a statement about a thirteen-character name rather
                # than about anything starting with `l` -- #573 settled that a run of `?`
                # the length of a helper name IS evidence, for the same reason. Counting
                # only the literals released this word, and bash expands it onto the helper;
                # codex measured it. Prose stays released because a bracket or two with
                # nothing literal around it still totals less than the threshold, and an
                # all-`*` candidate is let go regardless.
                _n = _count_classes(seg, _CLASS_COUNT_MAX)
                # TOO LITTLE LITERAL TO BE EVIDENCE is the objection #573 was reported
                # for, and it has to be answered here too. `awk '{ a[$1 " " $2]++ }'` offers
                # the stem `a` and no tail at all, and `a*` names a helper about as
                # specifically as a bare wildcard does -- a false block on ordinary array
                # indexing, caught by the over-block matrix. A markdown link offers no stem
                # and the tail `(url)`, which is plenty of literal and matches no helper.
                #
                # An EARLIER draft asked instead whether an interpreter stood in front of the
                # word, and that was a releasing test computed from raw text -- so every way
                # of hiding the interpreter was a bypass, and codex found four in one round
                # (a redirect, a flag operand, a quote-obfuscated name, `${IFS}`) and three
                # more in the next. A releasing predicate that cannot be computed reliably
                # fails OPEN by construction. This one reads only the word itself.
                # `gtail` comes from the far end of the TEXT, so pairing it with this run's
                # stem is only legitimate when the two could be one shell word -- which needs
                # quoted whitespace inside the class. Without that test it invented helper
                # names out of unrelated prose, joining `lease_s` from one word to `lot.py`
                # from another five words later; codex measured that on a heredoc this file
                # used to allow. A quote in the class region is the evidence that the
                # whitespace after it may be a MEMBER rather than a separator, which is #708
                # itself; absent it, the run stands alone and only its own tail counts.
                _joins = bool(_JOINS_WORDS_RE.search(seg[k:]))
                for lit in ((tail, gtail) if _joins else (tail,)):
                    if len(stem) + len(lit) + _n < _STEM_MIN_EVIDENCE:
                        continue
                    cand = stem + "*" + lit
                    if cand in seen or all(c == "*" for c in cand):
                        continue
                    seen.add(cand)
                    try:
                        pat = re.compile(fnmatch.translate(cand))
                    except (re.error, TypeError):
                        return _MUTATING_HELPERS[0]   # unparseable pattern: fail closed
                    hit = next((h for h in _MUTATING_HELPERS if pat.match(h)), None)
                    if hit:
                        return hit
    return None


def _glob_helper_targeted(word, deep=None):
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
    return _glob_helper(word, deep)


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
# answered in COMMAND POSITION by `_CMDPOS_INTERP_RE` (#565) -- the bare names `lldb`/`gdb`
# are in the exact-name set and unaffected.
# The numeric requirement is what keeps the rest safe to ask
# of every word: `python3-report` is ordinary hyphenated data, and matching it read a word
# `grep` merely searches for as an interpreter.
#
# A MULTIARCH name (`perl5.36-x86_64-linux-gnu`) is still deliberately NOT matched here --
# its suffix is non-numeric, so any pattern loose enough to accept it also accepts the
# hyphenated data above. It is answered in COMMAND POSITION instead, by
# `_CMDPOS_INTERP_RE` below (#565).
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

# Receiver spellings that are receivers ONLY in COMMAND POSITION (#565). Both wear a shape
# ordinary data also wears -- a MULTIARCH name carries the platform triplet on the versioned
# name itself (`/usr/bin/perl5.36-x86_64-linux-gnu`) and a DASH-VERSIONED debugger
# (`lldb-19`, `gdb-14`) is spelt exactly like the argument of an ordinary grep -- so neither
# can join the any-word patterns above. Command position is what makes both safe: data never
# lands there. Two-or-more dash components are REQUIRED on the multiarch branch, which keeps
# `python3-config` -- a real command that does NOT read a program from stdin -- out of it.
# The bare `lldb`/`gdb` stay in `_SHELL_NAMES` and are unaffected.
# See cmdword._CMDPOS_INTERP_RE for the fuller note, and `_runs_cmdpos_receiver` for the walk
# that decides the position. KEEP IN STEP WITH cmdword._CMDPOS_INTERP_RE.
# OUT OF SCOPE here: the HERE-STRING transport (`<name> <<< '<payload>'`) does not ask this
# predicate. `<<<` is a redirection rather than a pipeline, and THIS file's here-string path
# already answers the bare and version-qualified names through `_is_shell_name` -- it is the
# TWIN that recognizes only `_SHELLS` there, a pre-existing desync this change neither widens
# nor narrows. The class below is missed by both, consistently. Closing it means broadening
# cmdword to the whole receiver family rather than to this class alone.
# KEEP IN STEP WITH cmdword._CMDPOS_INTERP_RE.
_CMDPOS_INTERP_RE = re.compile(
    r"(?:python[0-9]+(?:\.[0-9]+)*t?"
    r"|(?:perl|ruby|node|tclsh|wish|lua|php)[0-9]+(?:\.[0-9]+)*)"
    r"-[0-9A-Za-z_]+(?:-[0-9A-Za-z_]+)+"
    # ...and `gdb-multiarch`, the one non-numeric dash suffix these two ship: a real Debian
    # binary that reads GDB commands from stdin exactly as bare `gdb` does. Named rather
    # than pattern-matched, because a general non-numeric dash suffix is precisely the shape
    # ordinary data wears.
    r"|(?:lldb|gdb)-(?:[0-9]+(?:\.[0-9]+)*|multiarch)")

# WRAPPERS whose first POSITIONAL word is an operand rather than the command they run
# (`flock <file> <cmd>`, `chroot <newroot> <cmd>`, `su`/`runuser <user>`, `script
# <typefile>`), so the walk's run must survive it exactly as it survives a value option's
# operand. See cmdword._OPERAND_WRAPPERS for why the set is deliberately small.
# KEEP IN STEP WITH cmdword._OPERAND_WRAPPERS.
_OPERAND_WRAPPERS = ("flock", "chroot", "su", "runuser", "script", "timeout")


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


def _runs_cmdpos_receiver(words):
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
    KEEP IN STEP WITH cmdword._runs_cmdpos_receiver.
    """
    # Each reading is (skip_next, prev_opt, wrapper_operand, opts_ended, runs):
    #   skip_next        -- a bare redirection operator took the next token as its target
    #   prev_opt         -- an option is outstanding and may still claim an operand
    #   wrapper_operand  -- a NAMED wrapper's own positional is still outstanding
    #   opts_ended       -- a `--` in THIS command turned every later dash-word into data
    #   runs             -- the next plain word could still be the program
    states = {(False, False, False, False, True)}
    for w in words:
        m = _REDIR_PREFIX_RE.match(w)
        b = _bn(w)
        # `_skippable` also matches ANY dash word, which this must not inherit: past a `--`
        # the dash branch above no longer fires, so a PATH command spelt `-read-only` would
        # be skipped as an operand and its argument promoted to command position -- a block
        # the twin does not make, because its `_NUMERIC_RE` never matched a dash word.
        # A long option whose value is ATTACHED cannot claim a separate operand,
        # so it must not keep command position alive past the real program:
        # `env --unset=FOO grep lldb-19` promoted grep's argument and falsely blocked.
        _attached_value = w.startswith("--") and "=" in w
        _operandish = _ASSIGN_RE.match(w) or (_skippable(w) and not w.startswith("-"))
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
                if w != "--" or oend:
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
                    nxt.add((m.group(0) == w, popt, True, oend, runs))   # ...a redirection
                if w == "--" and not oend:
                    nxt.add((False, False, True, True, runs))      # ...the end of options
                elif w.startswith("-") and not oend:
                    nxt.add((False, not _attached_value, True, oend, runs))   # ...another option
                continue
            if m:                     # a BARE operator takes the next token as its target
                nxt.add((m.group(0) == w, popt, wop, oend, runs))
                if popt:
                    # ...or the OPTION's operand, quoting having been erased by the lexer:
                    # `env -C '>' <name>` changes into a directory called `>` and runs the
                    # interpreter, while the redirection reading alone swallowed it.
                    nxt.add((False, False, wop, oend, runs))
                continue
            if w == "--" and not oend:
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
            if w.startswith("-") and not oend:
                nxt.add((False, not _attached_value, wop, oend, runs))
                continue
            if _operandish:           # an assignment prefix, or a bare numeric operand
                nxt.add((False, False, wop, oend, runs))
                continue
            if b in _TEST_OPEN_SH:
                if popt:
                    # ...unless an option is outstanding, in which case this is its OPERAND
                    # and not a test at all: `env -u '[' lldb-19` unsets a variable named
                    # `[` and runs the debugger. Dropping the reading emptied the set here.
                    nxt.add((False, False, wop, oend, runs))
                continue              # otherwise a test expression runs no command
            # PREAMBLE NAMES -- wrappers, reserved words and MULTI-CALL DISPATCHERS, whose
            # applet is the real command (`busybox env <name>` runs the interpreter). Only
            # when no option operand is outstanding: `env -u timeout <name>` names a wrapper
            # in `-u`'s DATA, and reading that as a nested wrapper opened a positional slot
            # the receiver fell into.
            # `coproc` is EXCLUDED from the reserved words here, unlike everywhere else in
            # this file: bash runs a coprocess on its OWN pipes, so the pipeline's stdin
            # never reaches it and `printf <payload> | coproc lldb-19` is not fed. Treating
            # it as transparent preamble blocked that, while the twin -- whose `_RESERVED`
            # has never held `coproc` -- allowed it. KEEP IN STEP WITH cmdword._RESERVED.
            if (b in _WRAPPER_CMDS or b in _CMD_PREFIX_WORDS
                    or (b in _RESERVED_SH and b != "coproc")):
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
    exits. KEEP IN STEP WITH cmdword._cmdpos_receiver_in_any_simple_command.
    """
    _segs, _ok = _split_simple_commands(text)
    if not _ok:
        return True
    for _s in _segs:
        _t = _lexed_toks(_s)
        if _t is None:
            return True
        if _runs_cmdpos_receiver(_strip_time_prefix(_t)):
            return True
    return False

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


def _lexed_toks(text):
    """RAW tokens of `text` with the QUOTING RESOLVED, or None when it will not lex.

    Split out of `_lexed_words` for the POSITIONAL callers. `_stage_words` peels an
    attached option value into a word of its own, which is what the any-word name tests
    want and exactly what a command-position walk must not see: `--label=lldb-19` would
    hand `_runs_cmdpos_receiver` a bare `lldb-19` with nothing in front of it, turning an
    option's DATA into a program.
    """
    try:
        _l = shlex.shlex(text, posix=True, punctuation_chars=True)
        _l.whitespace_split = True
        _l.commenters = ""
        return list(_l)
    except ValueError:
        return None                       # unlexable: the caller chooses its own fallback


def _lexed_words(text):
    """Words of `text` with the QUOTING RESOLVED, falling back to a raw split.

    A raw split leaves the quote characters attached, so a quoted name matches no set --
    the fail-open this exists to close. KEEP IN STEP WITH cmdword, whose executed-operand
    loop lexes for the same reason.
    """
    _t = _lexed_toks(text)
    return text.split() if _t is None else list(_stage_words(_t))


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
                # ...and the same command-position-only rule for the interpreter
                # spellings that wear a data shape (`perl5.36-x86_64-linux-gnu`,
                # `lldb-19`). Asked of the WALK rather than of `cw`, because `cw` lands on
                # a wrapper option's operand -- see `_runs_cmdpos_receiver`.
                # KEEP IN STEP WITH cmdword._may_read_program_from_stdin.
                if (cw and _bn(cw) in (".", "source")) \
                   or _runs_cmdpos_receiver(_strip_time_prefix(toks)) \
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
                           or _runs_cmdpos_receiver(_strip_time_prefix(_bt)) \
                           or _leads_with_launcher(_bt, _bw) \
                           or any(_is_shell_name(_bn(w))
                                  for _p in _bprogs for w in _lexed_words(_p)) \
                           or any(_cmdpos_receiver_in_any_simple_command(_p)
                                  for _p in _bprogs) \
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
                    # BOTH name questions, not just the any-word one:
                    # `perl5.36-x86_64-linux-@(gnu)` resolves to a command-position
                    # receiver. KEEP IN STEP WITH cmdword.
                    if _dtoks is None \
                       or any(_is_shell_name(_bn(w)) for w in _stage_words(_dtoks)) \
                       or _runs_cmdpos_receiver(_strip_time_prefix(_dtoks)):
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
                   or any(_cmdpos_receiver_in_any_simple_command(p) for p in _progs) \
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

    And ask both splits a SECOND time, of a VARIANT of the text with the whitespace deleted
    from inside every bracket expression (#708). Whitespace is the only word boundary those
    two splits know, so a space that is a MEMBER of a bracket class cuts a pattern the shell
    globs onto the helper in half. Deleting the member leaves a class they already handle,
    and it joins nothing, so it is not the bracket-atomic boundary that reopens #573 -- see
    _class_members, which also lists the quote-aware drafts this replaced and how each broke.
    The probe stays monotone because a variant, like a split, only ever adds candidates.

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
    # One decision for the whole scan, not one per candidate: a short command gets the full
    # reading family on every word it yields, while a payload built to be expensive gets the
    # base reading only. Deciding it here keeps the cost tied to what arrived rather than to
    # how many words fell out of it. Raised by codex in review -- twice, and the second time
    # is why LENGTH alone is not the measure: 800 `[a]` words fit in 3.2KB and still cost 9.1s,
    # because the depth is spent per bracketed word. Bracket DENSITY is the term that catches
    # that shape, so all three bounds are applied.
    #
    # Dropping to the base reading is now a loss of PRECISION rather than of coverage, which
    # is what makes the third bound affordable enough to set this low: since exhaustion began
    # answering through _bracket_prefix_hit, a scan that declines the deep reading still
    # blocks, it just blocks on a wider pattern. Before that it would have been a bypass, and
    # tightening the bound would have opened one.
    _deep = _deep_affordable(text)
    # Words off the ORIGINAL text get the full reading family; words off a text that has
    # ALREADY been reconciled do not. Re-running the terminator search on those was pure
    # duplication -- the class in a derived word has been rewritten to the one spelling
    # fnmatch reads correctly, so there is nothing left for a second search to find -- and it
    # multiplied the cost by the variant count. Measured: two bracket words carrying eight
    # quoted `]` each cost 3.98s of the hook's 5s budget, and the probe runs TWICE (dequoted
    # and raw), which is how codex clocked 5.42s and no decision at all. The same shapes now
    # measure well under a second. Codex suggested this in the first round; it took until the
    # word bound was in place to see that it was the multiplier, not the bound.
    families = ([(v, _deep) for v in _shell_variants(text)]
                + [(x, False) for v in _class_variants(text) for x in _shell_variants(v)])
    hit = next((h for v, d in families
                for w in v.split() + _OPERATOR_SPLIT_RE.split(v)
                if any(c in w for c in "*?[")
                for h in [_glob_helper_targeted(w, d)] if h), None)
    if hit:
        return hit
    # The whole-text search carries the same budgets as the per-word one, and it is the one
    # an adversary actually spends: quoting puts whitespace INSIDE a class, so reassembling
    # the word is what the terminator search is for, and exhausting it used to answer
    # "no helper" for a command the shell expands straight onto one.
    if not _deep or text.count("]") > _CLOSE_CANDIDATES:
        return _bracket_prefix_hit(text)
    return None


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
        _deep_budget[0] = _DEEP_MAX_BYTES
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
        # ...and the RAW command too, which is not the same question since #708. `_dq` has
        # already deleted the quoting, so a class whose whitespace the quoting was holding
        # -- `eval "python3 <lib>/lease_slo[' 't].py"`, which every one of bash, sh, zsh, dash and
        # ksh runs -- arrived here as a bare space the whitespace split had already cut in
        # two. Asked as well as, never instead of: the dequoted copy is what joins a name
        # split across adjacent quoted runs, and this is a union like the splits it feeds.
        _hit = _abandoned_scan_probe(_dq) or _abandoned_scan_probe(cmd)
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
            # The SAME words with their quoting intact. Quote removal is what decides a
            # bracket class -- `<stem>[[:digit:"]"].py` dequotes to the POSIX digit class,
            # which matches nothing, while bash reads the quoted `]` as a MEMBER, making the
            # body a plain list that holds `t` and expanding it onto the helper. So the
            # dequoted token cannot answer, and the raw one can. Two earlier drafts asked
            # this OUTSIDE the walk -- once of the whole command, once as soon as an
            # interpreter appeared -- and both broke the read/mention contract, reporting
            # `echo '<helper-glob>'` and then `python3 safe.py '<helper-glob>'` as
            # invocations. Carrying the raw spelling INTO the walk means command position is
            # decided once, by the code that already does it, instead of guessed twice.
            # Verified rather than assumed: the pairing counts only if every raw word
            # dequotes to exactly the token the lexer produced, in order. A splitter that
            # disagreed with the lexer would otherwise pair the wrong words silently, which
            # is worse than not pairing at all -- so a mismatch drops the raw pass entirely
            # and nothing is claimed from it.
            raw_toks = _raw_words(segtext)
            raw_dropped = [_dequote_lex(_r) for _r in raw_toks] != toks
            if raw_dropped:
                raw_toks = []
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
        _kept = None if _wrapped else _strip_redirs_kept(toks)
        _scan_toks = toks if _wrapped else [toks[i] for i in _kept]
        # The raw list put through the SAME indices _strip_redirs_kept chose from the
        # DEQUOTED list, not re-stripped independently -- so index i means the same token
        # in both by construction. Re-stripping independently was the first attempt, and
        # it is not a mapping at all: _is_redir reads a token by VALUE, and a raw token
        # still carries its quote marks where the dequoted one does not, so a quoted
        # redirect-looking argument (`">"`) answers _is_redir differently on each list --
        # not a genuine disagreement, just the same decision asked twice in two spellings.
        # `python3 safe[a].py ">" ignored 'lease_slo["x"]t.py'` diverged in length here,
        # which dropped the raw pass and fell to the whole-segment `_bracket_prefix_hit`
        # fallback, BLOCKing on a later argument that only mentions the helper's shape.
        # Codex found it. `raw_toks` is only ever [] (already dropped above) or the same
        # length as `toks` by the time this runs, so `_kept`'s indices are valid for both.
        if not raw_toks:
            _raw_scan = None
            raw_dropped = True
        else:
            _raw_scan = raw_toks if _wrapped else [raw_toks[i] for i in _kept]
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
                # A DROPPED pairing is not a clean pass. The raw spelling is the only
                # thing that can answer a quoted `]` inside a class, so losing it silently
                # left the very shape it was added for allowed -- and it was one decoy
                # argument away, since any disagreement anywhere in the segment drops the
                # whole list. Same rule as every other abandoned scan in this file: what it
                # could not read, it must not report as absent.
                _raw_w = _raw_scan[j] if _raw_scan is not None else w
                hit = (_glob_helper(w)
                       or (_raw_w != w and _glob_helper(_raw_w))
                       or (raw_dropped and _bracket_prefix_hit(segtext))
                       or _names_helper(_whole))
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
