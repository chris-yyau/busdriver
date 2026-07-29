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
]

# Verbs that modify files by themselves. `sed` is absent — it only modifies with -i,
# and is handled separately below so a read-only `sed -n ...` stays allowed.
# truncate/unlink were in NEITHER the old regexes nor the first cut of this module, so
# `truncate -s 0 f` classified as a read. Token equality makes them safe to add: the
# `grep -nE 'rm |mv |truncate'` case from #519 keeps its pattern as ONE token.
_MOD_VERBS = frozenset(("tee", "patch", "cp", "mv", "rm", "ln", "install",
                        "truncate", "unlink", "rmdir", "dd"))

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
_DASH_C_RUNNERS = _SHELLS | frozenset(("su", "runuser"))
# Bound the recursion. Depth is only reached by genuinely nested `bash -c 'bash -c ...'`
# or nested substitutions; the cap stops a hand-crafted bomb from stalling a PreToolUse
# hook. Hitting the cap returns the regex verdict (wider), never "allow".
_MAX_DEPTH = 4

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
# reliably), and `time`/`script`/`flock` are absent on purpose — they are self-writing
# verbs in the forge detector, but there the marker operand is also required, whereas
# here `time npm test` would become a false positive.
_WRAPPERS = frozenset(("sudo", "doas", "su", "runuser", "env", "nohup", "timeout",
                       "nice", "ionice", "setsid", "stdbuf", "unbuffer", "command",
                       "builtin", "exec", "xargs", "caffeinate", "chroot", "arch",
                       "torify", "proxychains", "proxychains4"))
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
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
    out = []
    # When the command STARTS with a wrapper, do not stop at the first non-wrapper word:
    # a wrapper flag can take an operand (`sudo -u root bash -c "rm x"`), so breaking at
    # `root` never reaches the `bash -c` behind it, and the conservative token scan does
    # not catch it either because `rm x` is one token. In that regime scan every token —
    # over-blocking a wrapped read is the safe direction. Unwrapped commands keep the
    # strict preamble-only walk, which is what keeps `echo su -c "rm x"` allowed.
    scan_all = _starts_with_wrapper(toks)
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            i += 1
            continue
        base = _basename(t)
        if base in _DASH_C_RUNNERS:
            # The program follows the flag bundle CONTAINING `c`, or a long
            # --command form. NOT --rcfile: that names a FILE to source, not inline
            # source, so treating its value as a program was simply wrong.
            for j in range(i + 1, n):
                t2 = toks[j]
                if t2.startswith("--command="):
                    out.append(t2.split("=", 1)[1])
                    break
                if t2 == "--command" and j + 1 < n:
                    out.append(toks[j + 1])
                    break
                if (t2.startswith("-") and not t2.startswith("--")
                        and "c" in t2[1:] and j + 1 < n):
                    out.append(toks[j + 1])
                    break
            i += 1
            continue
        if base == "eval":
            if i + 1 < n:
                out.append(" ".join(toks[i + 1:]))
            i += 1
            continue
        if base == "env":
            # `env -S <program>` splits its operand into an argv and runs it. Both the
            # separated (-S, prog), attached (-Sprog) and long (--split-string=prog)
            # spellings occur.
            for j in range(i + 1, n):
                t2 = toks[j]
                if t2.startswith("--split-string="):
                    out.append(t2.split("=", 1)[1])
                    break
                if t2 == "-S" and j + 1 < n:
                    out.append(toks[j + 1])
                    break
                if t2.startswith("-S") and len(t2) > 2:
                    out.append(t2[2:])
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
    return out


def _first_word(toks):
    """First token in COMMAND position: assignments, flags, numeric operands and shell
    reserved words are skipped, so `then coproc rm x` and `{ coproc rm x` both report
    `coproc`. coproc/function are NOT in _RESERVED, so they are reported exactly where
    they sit, while a mere mention (`echo coproc rm x`) still reports `echo`."""
    for t in toks:
        if _ASSIGN_RE.match(t) or t.startswith("-") or _NUMERIC_RE.match(t):
            continue
        b = _basename(t)
        if b in _RESERVED:
            continue
        if b in _TEST_OPEN:
            return ""
        return b
    return ""


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


def _runs_mod_verb(toks):
    """Two-regime verdict for a token list that is itself a command.

    Wrapper (or opaque intro) present -> scan EVERY token, because a wrapper flag can
    take an operand and enumerating which flags do is a table that fails OPEN.
    Otherwise -> the command word alone, so data operands stay data.

    Shared by the segment check, the find -exec payload and the function body.
    """
    if _starts_with_wrapper(toks) or _first_word(toks) in _OPAQUE_INTRO:
        return any(_basename(t) in _MOD_VERBS for t in toks)
    return _effective_command_word(toks) in _MOD_VERBS


def _segment_is_mod(toks):
    """True iff this simple command RUNS a file-modifying verb."""
    names = [_basename(t) for t in toks]
    cw = _effective_command_word(toks)
    # `find` is deliberately NOT a conservative trigger: forcing the all-token scan for
    # it made read-only `find . -name rm` and `find . -exec echo rm {} +` classify as
    # writes. It gets its own block below.
    wrapped = _starts_with_wrapper(toks) or _first_word(toks) in _OPAQUE_INTRO
    if wrapped:
        if any(n in _MOD_VERBS for n in names):
            return True
    elif cw in _MOD_VERBS:
        return True
    # `function NAME { body }`: the NAME is data, the BODY is code (it executes when the
    # name is called later). Judged by command word so `function f { echo rm; }` -- which
    # only prints the word -- stays allowed.
    if _first_word(toks) == "function":
        after_name = toks[2:] if len(toks) > 2 else []
        if after_name and _runs_mod_verb(after_name):
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
                if payload and _runs_mod_verb(payload):
                    return True
    # sed modifies only in-place, and the -i must come AFTER the sed token: in
    # `grep -i sed notes.txt` the -i belongs to grep and sed is its search string.
    # Anchored on command position so `echo sed -i` is not a write.
    if cw == "sed" or (wrapped and "sed" in names):
        after = toks[names.index("sed") + 1:]
        return any(re.match(r"^-[A-Za-z]*i", t) for t in after)
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
    if _depth >= _MAX_DEPTH:
        return _regex_fallback(cmd)
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
        if _segment_is_mod(toks):
            return True
        for prog in _executed_operands(toks):
            if is_file_mod(prog, _depth + 1):
                return True
    return False


def _regex_fallback(cmd):
    return any(re.search(p, cmd) for p in FILE_MOD_PATTERNS)


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
        "env --split-string='rm x'",
    ]
    for c in allowed:
        assert not is_file_mod(c), "should be allowed: " + c
    for c in blocked:
        assert is_file_mod(c), "should be blocked: " + c
    # Unparseable (apostrophe in prose) falls back to the regexes, never to "allow".
    unbalanced = "git commit -m \"the operator's skip file\" && rm x"
    assert is_file_mod(unbalanced), "unparseable + rm must fall back to blocking"
    # ...and a fallback on a command with no verb still allows, matching pre-#519.
    assert not is_file_mod("git commit -m \"the operator's skip file\"")
    print("cmdword self-check OK")


if __name__ == "__main__":
    _demo()
