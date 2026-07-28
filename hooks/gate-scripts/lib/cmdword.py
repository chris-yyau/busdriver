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
]

# Verbs that modify files by themselves. `sed` is absent — it only modifies with -i,
# and is handled separately below so a read-only `sed -n ...` stays allowed.
_MOD_VERBS = frozenset(("tee", "patch", "cp", "mv", "rm", "ln", "install"))

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
# Bound the recursion. Depth is only reached by genuinely nested `bash -c 'bash -c ...'`
# or nested substitutions; the cap stops a hand-crafted bomb from stalling a PreToolUse
# hook. Hitting the cap returns the regex verdict (wider), never "allow".
_MAX_DEPTH = 4


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
    return re.sub(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])", " ", norm)


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
    """Token operands this simple command hands to a shell to EXECUTE."""
    out = []
    for i, t in enumerate(toks):
        base = _basename(t)
        if base in _SHELLS:
            # The program follows the flag bundle CONTAINING `c` — not only a bare `-c`
            # or a bundle ENDING in c. Bash and sh happily execute `bash -cl 'rm x'` and
            # `sh -ce 'rm x'`, so anchoring on the last letter misses live write paths.
            # Any single-dash bundle with a `c` in it consumes the next word as the
            # command string; `--`-prefixed long options never do.
            for j in range(i + 1, len(toks) - 1):
                t2 = toks[j]
                if t2.startswith("-") and not t2.startswith("--") and "c" in t2[1:]:
                    out.append(toks[j + 1])
                    break
        elif base == "eval":
            # eval concatenates its operands and executes the result.
            if i + 1 < len(toks):
                out.append(" ".join(toks[i + 1:]))
        elif base == "env":
            # `env -S "rm -rf x"` splits its string operand into an argv and runs it,
            # so the operand is executable text just like `sh -c`. Both the separated
            # (`-S`, `cmd`) and attached (`-Srm -rf x`) spellings occur.
            for j in range(i + 1, len(toks)):
                t2 = toks[j]
                if t2 == "-S" and j + 1 < len(toks):
                    out.append(toks[j + 1])
                    break
                if t2.startswith("-S") and len(t2) > 2:
                    out.append(t2[2:])
                    break
    return out


def _segment_is_mod(toks):
    """True iff this simple command's tokens contain a file-modifying verb."""
    names = [_basename(t) for t in toks]
    if any(n in _MOD_VERBS for n in names):
        return True
    # sed modifies only in-place, so require BOTH the verb and an -i flag. The flag
    # must come AFTER the sed token: in `grep -i sed notes.txt` the -i belongs to
    # grep and sed is its search string, which is read-only. Checking order rather
    # than command-word position keeps `sudo sed -i ...` blocked. `-i` may carry a
    # suffix (BSD `sed -i ''`, GNU `sed -i.bak`) or be bundled (`-ni`), so match any
    # leading-dash token whose flag letters include i.
    if "sed" in names:
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
        'bash -c \'echo "T3 (mv FAILS): ..."\'',
        "ls -la",
        "sed -n '1,10p' file.txt",
        "grep -i sed notes.txt",
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
