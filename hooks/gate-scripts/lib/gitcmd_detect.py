"""Shared git/gh command detection for busdriver enforcement gates.

Single source of truth for the command-word detection that was previously
mirrored (and drifting) across pre-commit / pre-pr / post-commit / post-pr /
post-merge-confirm gate scripts. Each gate's `python3 -c` block imports this
module via PYTHONPATH instead of re-implementing the parser.

Design invariants:
  * FAIL-CLOSED — when the command word is ambiguous the detectors err toward
    RECOGNIZING a git/gh invocation (so a gate blocks) rather than missing one
    (which would fail open and skip review).
  * Wrapper-aware — 'command', 'env', 'sudo', absolute-path wrappers
    (/usr/bin/env), wrapper options (env -i, sudo -u nobody, sudo -n) are all
    stripped to reach the real command word, WITHOUT per-wrapper option grammar
    and without ever skipping the git/gh executable token itself.
  * Quote-aware — top-level operator splitting and tokenization honor single/
    double quotes and backslash escapes, so `printf 'x; gh pr create URL'` is a
    single printf (not a synthetic create) and `'git' commit` / "/usr/bin/git"
    are recognized.

Stdlib only (re, os, shlex) so it is importable from a bare `python3 -c`.

KNOWN LIMITATIONS (a static command-string parser is a speed-bump against
casual/accidental bypass, NOT a sandbox — a determined actor with shell access
can always evade it, e.g. a script file or `python -c "subprocess.run(...)"`).
Deliberately NOT handled (tracked as a scoped follow-up):
  * Multiple protected operations in ONE command that target DIFFERENT repos
    (`cd /a && git commit; cd /b && git commit`) — the first match is returned,
    so only the first repo's marker is checked. Full coverage needs the GATE to
    validate every operation's repo, not just the detector.
  * cwd of a command-substitution / interpreter payload after a preceding `cd`
    (`cd /other && echo "$(git commit)"`) — nested chunks report target_dir=''
    (the process cwd), missing the `/other` scope.
  * Process substitution `<(...)` / `>(...)`, here-strings, and dispatchers like
    `xargs` / `find -exec` are not traced.
These are fail-OPEN residuals accepted for the current threat model (stopping the
agent from ROUTINE unreviewed commits). Revisit if the gate must resist a
deliberate evader.
"""
import os
import re
import shlex

# Command wrappers that transparently precede the real command. Basename-matched
# so absolute-path forms (/usr/bin/env, /usr/bin/sudo) count too.
_WRAPPERS = frozenset((
    'command', 'env', 'sudo', 'doas', 'nohup', 'nice', 'time',
    'builtin', 'exec', 'stdbuf', 'setsid',
))

# Compound-command keywords that can precede a real command inside one segment
# (`then git commit`, `do gh pr merge 1`). Stripped so the command word behind
# them is still reached. 'in' is deliberately ABSENT: in `for x in 1` the word
# after it is a list item, not a command.
_SHELL_KEYWORDS = frozenset((
    'if', 'then', 'elif', 'else', 'fi', 'while', 'until', 'for', 'do', 'done',
    'case', 'esac', 'select', 'function',
    # `coproc git commit` launches the command (asynchronously) — the keyword is
    # not the executable.
    'coproc',
))


def _is_ansi_c_dollar(cmd, i):
    r"""True if the quote at cmd[i] opens an ANSI-C string `$'...'`.

    Requires a '$' immediately before it that is not itself ESCAPED: in
    `printf %s \$'x\'` the dollar is a literal, so this is an ordinary quote in
    which `\'` does NOT escape — treating it as ANSI-C kept the string open past
    its real end and swallowed the next line's live command (fail-OPEN,
    verified). An odd number of preceding backslashes means the '$' is escaped.
    """
    if i == 0 or cmd[i - 1] != '$':
        return False
    j = i - 2
    backslashes = 0
    while j >= 0 and cmd[j] == '\\':
        backslashes += 1
        j -= 1
    return backslashes % 2 == 0


def strip_continuations(cmd):
    r"""Remove backslash-newline line continuations, as bash does when lexing.

    bash deletes backslash-newline BEFORE any parsing, so every downstream reader
    — command substitution, interpreter payloads, segment splitting — must see the
    joined text or it reads a different command than the shell runs. Verified
    against real bash: `git \<newline>commit -m x` commits, and `echo $\<newline>(git
    commit)` commits (the continuation splits the `$(` token itself, which is why
    stripping inside the segment splitter alone was not enough).

    We strip UNCONDITIONALLY — no quote or heredoc tracking — except that a
    doubled backslash is an escaped backslash followed by a REAL newline command
    separator, so its newline is kept (verified). This deliberately over-strips
    the two contexts where bash keeps backslash-newline literal — single-quoted
    spans and quoted heredoc bodies (`<<'EOF'`) — but that text is DATA bash never
    executes, so mis-joining it can only make the detector OVER-fire on inert text
    (a fail-CLOSED false positive), never miss an executed command. An earlier
    quote-state machine that tried to honor those exemptions instead mis-tracked
    the quoting reset inside `$(...)` and let real nested-substitution evasions
    through (fail-OPEN) — strictly worse for a gate. So: bias to stripping, and
    stay fail-closed. Consuming two chars after any non-newline backslash also
    makes odd/even backslash runs (`\\\<newline>` = literal `\` then a real
    continuation) fall out correctly.
    """
    out = []
    i = 0
    n = len(cmd)
    while i < n:
        c = cmd[i]
        if c == '\\' and i + 1 < n:
            if cmd[i + 1] == '\n':
                i += 2          # line continuation — bash removes both chars
                continue
            out.append(c)
            out.append(cmd[i + 1])
            i += 2              # consume the escaped char so \\ cannot continue
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def split_segments(cmd):
    """Split a command line into (operator_before, segment) pairs. Splits on
    top-level &&, ||, ;, |, &, and newline, honoring quotes/escapes so an
    operator inside quotes is not a separator. operator_before is the shell
    operator that precedes each segment ('' for the first) — callers use it to
    tell whether a `cd` actually gated the following command (only '&&' does).
    A lone '&' is the background operator; both '&&' and '&' terminate the
    current top-level command so `true & git commit` does not hide the commit.
    Line continuations are stripped first (see strip_continuations), so
    `git \\<newline>commit` is seen as the `git commit` it runs as."""
    cmd = strip_continuations(cmd)
    out = []
    buf = []
    op = ''
    quote = None
    ansi_c = False
    i = 0
    n = len(cmd)

    def flush(next_op):
        out.append((op, ''.join(buf).strip()))
        return next_op

    while i < n:
        c = cmd[i]
        if quote is not None:
            buf.append(c)
            # Backslash escapes apply inside "..." and inside ANSI-C $'...',
            # where \' is a LITERAL quote. Without the ansi_c case the scanner
            # ends the string one quote early and then re-opens on the closing
            # quote, so everything after it — including a live command on the
            # next line — is swallowed as quoted text (fail-OPEN, verified).
            if c == '\\' and (quote == '"' or ansi_c) and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
                ansi_c = False
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            ansi_c = c == "'" and _is_ansi_c_dollar(cmd, i)
            buf.append(c)
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            buf.append(c)
            buf.append(cmd[i + 1])
            i += 2
            continue
        if c in (';', '\n'):
            op = flush(';')
            buf = []
            i += 1
            continue
        if c == '|':
            double = i + 1 < n and cmd[i + 1] == '|'
            op = flush('||' if double else '|')
            buf = []
            i += 2 if double else 1
            continue
        if c == '&':
            double = i + 1 < n and cmd[i + 1] == '&'
            op = flush('&&' if double else '&')
            buf = []
            i += 2 if double else 1
            continue
        buf.append(c)
        i += 1
    out.append((op, ''.join(buf).strip()))
    return out


def _tokenize(seg):
    """Tokenize a segment honoring quotes, with surrounding quotes stripped from
    each token. Falls back to a quote-stripping whitespace split when the
    segment cannot be lexed (e.g. unbalanced quotes) — fail-closed toward still
    finding the command word."""
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return [t.strip('\047\042') for t in seg.split()]


def _is_exe(tok, name):
    """True if tok is the executable `name` or an absolute/relative path to it."""
    return tok == name or tok.endswith('/' + name)


def _command_argv(seg, target):
    """Return the argv beginning at the command word, after stripping a leading
    run of launcher tokens: env-assignments, wrapper words (basename-matched),
    wrapper dash-options, and a SINGLE option-argument after a dash-option — but
    NEVER the `target` executable token (fail-closed: a no-arg option like
    `sudo -n` must not swallow the real command). `target` is the executable
    basename we must not skip (e.g. 'git' or 'gh')."""
    toks = _tokenize(seg)
    # Strip leading subshell '(' / brace-group '{' punctuation so grouped
    # commands like (git commit) or { git commit; } expose their command word.
    while toks:
        head = toks[0].lstrip('({')
        if head == toks[0]:
            break
        if head:
            toks = [head] + toks[1:]
            break
        toks = toks[1:]
    i = 0
    saw_wrap = False
    prev_dash = False
    case_state = None
    while i < len(toks):
        t = toks[i]
        base = t.rsplit('/', 1)[-1]
        is_target = base == target
        if re.match(r'^\w+=', t):
            i += 1
            prev_dash = False
        elif t == '!':
            # pipeline negation — the command still runs
            i += 1
            prev_dash = False
        elif (t.endswith(')') and not t.startswith('(') and not is_target
              and len(toks) > i + 1 and case_state != 'subject'):
            # `case` branch pattern label — `x)` in `case x in x) git commit;;`.
            # It heads its own segment for EVERY branch (';;' splits), not just
            # the first, so matching the label shape covers them all without
            # tracking case-statement state. An unquoted command word can never
            # end in ')', so this cannot swallow a real command.
            # A label may legally CONTAIN a paren once quoted or escaped
            # (`a\(b)`), so only a leading '(' is excluded here — that form is a
            # group and is handled by the grouping branch below.
            # Consuming the label ENDS the subject run: without this the
            # subject-skipping branch below keeps eating the branch BODY. The
            # detection paths pass a target and are saved by its `not is_target`
            # guard, but the target='' path (interpreter/eval discovery) is not
            # — it returned [] for `case x in x) bash -c …`, hiding the payload.
            case_state = None
            i += 1
            prev_dash = False
        elif base in _SHELL_KEYWORDS and not is_target:
            # Compound-command keyword introducing a real command in the SAME
            # segment: `if git commit`, `then gh pr merge 1`, `do git commit`.
            # Segment splitting cuts on ';' and newline, so the keyword lands at
            # the head of the segment and would otherwise BE read as the command
            # word — a fail-OPEN miss for every gate (verified: all of
            # `if true; then gh pr merge 1; fi`, `if gh pr merge 1; then :; fi`
            # and `for x in 1; do gh pr merge "$x"; done` really do run the
            # merge). Never skipped when the token IS the target executable, so
            # a program legitimately named e.g. `do` cannot hide one.
            if base == 'case':
                case_state = 'subject'
            i += 1
            prev_dash = False
            # `coproc` takes a NAME only in the form `coproc NAME <compound>`;
            # in `coproc bash -c '…'` the very next token IS the command, so an
            # unconditional skip hid it (fail-OPEN regression). Require the
            # name-then-compound shape before skipping.
            # The compound may open with '{' / '(' OR with a KEYWORD
            # (`coproc JOB if git commit; then :; fi`) — accept both shapes.
            _named_coproc = (base == 'coproc' and i + 1 < len(toks)
                             and re.match(r'^[A-Za-z_]\w*$', toks[i] if i < len(toks) else '')
                             and (toks[i + 1][:1] in ('{', '(')
                                  or toks[i + 1].rsplit('/', 1)[-1] in _SHELL_KEYWORDS))
            if ((base == 'function' or _named_coproc) and i < len(toks)
                    and toks[i].rsplit('/', 1)[-1] != target):
                # `function f { git commit; }` and `coproc NAME { git commit; }`
                # — the declaration/coproc NAME follows the keyword and would
                # otherwise be read as the command word, hiding the body
                # (verified: `function f { gh pr merge 1; }; f` runs the merge
                # but counted 0). The POSIX form `f() { … }` is already covered:
                # `f()` matches the label-shape rule. Skipping the body's
                # commands is fail-CLOSED — a declared-but-never-called function
                # only over-fires.
                i += 1
        elif case_state and not is_target:
            # The case SUBJECT and first pattern label, which share a segment
            # with the branch body: `case <subject> in <label>) git commit;;`.
            # Later branches head their own segment (';;' splits) and are caught
            # by the label-shape rule above; only the first needs this state.
            #
            # The two phases must be distinguished by the `in` keyword, not by
            # "first token ending in ')'": a subject can itself end in ')'
            # (`case "$(printf x)" in x) …`), which ended subject-tracking early
            # and left `in` as the detected command word — fail-OPEN (verified).
            if case_state == 'subject':
                if base == 'in':
                    case_state = 'label'
            elif t.endswith(')'):
                case_state = None
            i += 1
            prev_dash = False
        elif re.match(r'^[A-Za-z_]\w*\(\)\{?$', t) and len(toks) > i + 1:
            # POSIX function definition whose name, parens and brace fused into
            # one token: `f(){ git commit; }` (no space) tokenizes as `f(){`, so
            # the label-shape rule (which needs a trailing ')') missed it and the
            # token was read as the executable, hiding the body (fail-OPEN).
            i += 1
            prev_dash = False
        elif t[:1] in ('(', '{'):
            # Grouping punctuation reached AFTER a keyword was skipped:
            # `if (git commit); then` / `if { git commit; }; then`. The pre-loop
            # strip only sees the segment's first token, so a group opened
            # behind a keyword kept the command word hidden — fail-OPEN
            # (verified). Strip here too and re-examine the same position.
            stripped = t.lstrip('({')
            if stripped:
                toks = toks[:i] + [stripped] + toks[i + 1:]
            else:
                toks = toks[:i] + toks[i + 1:]
            prev_dash = False
        elif re.match(r'^(\d*[<>]{1,2}|&>{1,2})', t):
            # redirection prefix (>, >>, 2>, &>, N<, >file, 2>/dev/null, ...).
            # A bare operator token ('>', '2>') consumes the target filename
            # that follows; a fused token ('>file', '2>&1') is self-contained.
            i += 1
            prev_dash = False
            if re.match(r'^(\d*[<>]{1,2}|&>{1,2})$', t) and i < len(toks):
                i += 1
        elif base in _WRAPPERS:
            saw_wrap = True
            i += 1
            prev_dash = False
        elif saw_wrap and t.startswith('-'):
            i += 1
            prev_dash = True
        elif saw_wrap and prev_dash and not is_target:
            # a single option-ARGUMENT to the preceding wrapper option
            i += 1
            prev_dash = False
        else:
            break
    return toks[i:]


def _cd_target(seg):
    """If seg is `cd <dir>`, return the quote-stripped, ~-expanded target; else
    None. The raw segment (not the tokenized form) is used so command-
    substitution idioms like cd "$(git rev-parse --show-toplevel)" survive for
    the downstream repo resolver."""
    m = re.match(r'cd\s+(.*)', seg.lstrip('({ \t'))
    if not m:
        return None
    return os.path.expanduser(m.group(1).strip().strip('\047\042'))


def _trusted_cd(pending_cd, op):
    """A pending cd is the repo scope ONLY if it was the segment immediately
    before this command AND joined by '&&' (so it ran and its success gated the
    command). Behind any other operator, or after an intervening command, the cd
    may not have executed (e.g. `false && cd /x; git commit`) — fall back to ''
    (process CWD) rather than trust a marker in the wrong repository."""
    return pending_cd if (pending_cd is not None and op == '&&') else ''


def _is_sub_opener(cmd, i, n):
    """True iff an EXECUTING substitution opener begins at cmd[i] — all require an
    immediate '(':
        $(       command substitution
        <(  >(   process substitution
        =(       zsh process substitution — but ONLY at a word boundary;
                 `name=(...)` / `name+=(...)` / `arr[i]=(...)` is an array
                 assignment whose contents do NOT execute (verified).
    Detection is UNCONDITIONAL with respect to double quotes: bash/zsh DO suppress
    <()/>()/=() inside "...", so scanning them there only ever OVER-fires on inert
    text (fail-CLOSED). Tracking a double-quote state to honor that suppression
    instead gets poisoned by an unbalanced quote in a comment/heredoc and MISSES a
    live process sub (fail-OPEN, verified) — strictly worse for a gate (mirrors the
    strip_continuations tradeoff). The immediate '(' also separates a process sub
    from a plain '>'/'<' redirect (a redirect is followed by a filename or space).
    Split out of _command_substitutions purely to reduce its branch count."""
    if not (i + 1 < n and cmd[i + 1] == '('):
        return False
    c = cmd[i]
    if c in ('$', '<', '>'):
        return True
    if c == '=':
        prev = cmd[i - 1] if i > 0 else ''
        # zsh =() process sub UNLESS prev could continue an assignment target: an
        # identifier char, '+' (name+=), or ']' (arr[i]=). Everything else
        # (whitespace, ';', '|', start, a control operator, ...) is a word boundary
        # ⇒ process sub. Stated as the skip-set so the allow-set need not enumerate
        # every operator. NB: tuple membership, not `in '_+]'` — `'' in '_+]'` is
        # True in Python (empty substring), which would wrongly skip a
        # start-of-string `=(...)`.
        return not (prev.isalnum() or prev in ('_', '+', ']'))
    return False


def _scan_balanced_sub(cmd, i, n):
    """Given a substitution opener at cmd[i] (with '(' at cmd[i+1]), scan to the
    matching ')' — honoring inner quotes so a quoted paren cannot mis-balance the
    depth counter — and return (inner, next_i). Split out of _command_substitutions
    to bound its complexity; behavior unchanged."""
    depth = 1
    j = i + 2
    start = j
    iq = None  # quote state INSIDE the substitution, so a quoted ')' or
    #            '(' does not mis-balance the depth counter.
    iq_ansi = False
    while j < n and depth > 0:
        cj = cmd[j]
        if iq is not None:
            # ANSI-C $'...' escapes apply here too — closing this state
            # at an escaped quote mis-balanced the depth counter and
            # truncated the extracted substitution, dropping a live
            # command that followed inside it (fail-OPEN, verified).
            if cj == '\\' and (iq == '"' or iq_ansi) and j + 1 < n:
                j += 2
                continue
            if cj == iq:
                iq = None
                iq_ansi = False
            j += 1
            continue
        if cj in ('"', "'"):
            iq = cj
            iq_ansi = cj == "'" and _is_ansi_c_dollar(cmd, j)
        elif cj == '(':
            depth += 1
        elif cj == ')':
            depth -= 1
        j += 1
    inner = cmd[start:j - 1] if depth == 0 else cmd[start:]
    return inner, j


def _command_substitutions(cmd):
    """Return the inner command strings of every EXECUTING substitution —
    $(...), backticks, and process substitutions <(...) / >(...) / =(...) —
    including nested ones. Process substitutions run their body just like $(...)
    (verified: `cat <(git commit)` commits, `cat <(rm -rf x)` deletes, and zsh
    `cat =(git commit)` commits), so a body-scanning gate must see them or they
    read as inert.

    Single quotes suppress every substitution (their contents are skipped).
    Process substitutions are detected UNCONDITIONALLY inside double quotes: the
    shells suppress them there, so over-scanning inert double-quoted text only
    ever fails CLOSED, whereas a double-quote state machine gets poisoned by an
    unbalanced quote in a comment and fails OPEN (verified). `name=(...)` is an
    array assignment, not a process substitution, so =( counts only at a word
    boundary."""
    subs = []
    i = 0
    n = len(cmd)
    sq = False   # inside single quotes: all substitution suppressed
    sq_ansi = False   # ...and that span is an ANSI-C $'...', where \' is literal
    while i < n:
        c = cmd[i]
        if sq:
            # Honor ANSI-C escapes here too. Without this the extractor ends the
            # string one quote early, re-opens on the real closing quote, and
            # then suppresses a LATER genuine substitution as if it were quoted
            # — `printf %s $'a\'b'; echo "$(gh pr merge 1)"` counted 0
            # (fail-OPEN, verified). split_segments and _split_inert_heredocs
            # already track this; this extractor was the remaining gap.
            if c == '\\' and sq_ansi and i + 1 < n:
                i += 2
                continue
            if c == "'":
                sq = False
                sq_ansi = False
            i += 1
            continue
        if c == "'":
            sq = True
            sq_ansi = _is_ansi_c_dollar(cmd, i)
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if _is_sub_opener(cmd, i, n):
            inner, i = _scan_balanced_sub(cmd, i, n)
            subs.append(inner)
            # NOTE: deliberately NOT recursing here. `_all_chunks` — the sole
            # caller — already re-extracts each returned chunk, so recursing too
            # yielded every nested substitution TWICE. That made
            # `echo $(echo $(gh pr merge 1))` count 2 and the pre-merge gate
            # reject one real merge as a chained multi-merge (verified). Note a
            # plain de-dupe would be WRONG in the other direction: two sibling
            # `$(gh pr merge 1)` substitutions are two REAL merges with
            # identical text and must still count 2.
            continue
        if c == '`':
            j = i + 1
            start = j
            while j < n and cmd[j] != '`':
                if cmd[j] == '\\' and j + 1 < n:
                    j += 2
                    continue
                j += 1
            subs.append(cmd[start:j])
            i = j + 1
            continue
        i += 1
    return subs


_INTERPRETERS = frozenset(('sh', 'bash', 'zsh', 'dash', 'ksh', 'ash'))

# Commands that EXECUTE a heredoc body rather than consuming it as data. The
# `source` / `.` builtins run `/dev/stdin`, so `source /dev/stdin <<'EOF'` really
# executes the body (verified) — treating it as inert was fail-OPEN.
# `eval` is deliberately ABSENT: it evaluates its ARGUMENTS and does not read
# commands from stdin, so `eval <<'EOF'` runs nothing (verified) and counting its
# body was a false-positive block. eval's arguments are still scanned, via
# _shell_payloads. `source` / `.` DO stay: they run /dev/stdin (verified).
_BODY_EXECUTORS = _INTERPRETERS | {'source', '.'}

# `<<` or `<<-` followed by a QUOTED delimiter: <<'EOF', <<"EOF", <<\EOF.
#
# `(?<!<)` rejects the third `<` of a HERE-STRING (`cat <<<'EOF'`), which is a
# one-line construct with no terminator: treating it as a heredoc made the
# scanner swallow the entire rest of the command hunting a terminator that never
# comes, discarding any live command after it — fail-OPEN (verified).
#
# The trailing lookahead requires the delimiter token to END here. bash allows
# delimiters assembled from several quoting runs (`<<'EO'F`, `<<\EOF-X`), where
# a partial match infers the WRONG terminator and again swallows live text. Not
# matching leaves the region in the scanned command string — fail-CLOSED, at
# worst an over-fire on inert prose.
_HEREDOC_QUOTED = re.compile(
    r'(?<!<)<<-?[ \t]*(?:\'([^\']*)\'|"([^"]*)"|\\(\w+))(?=[\s;|&<>)]|$)')


def _consume_heredoc(cmd, i, m, line_start):
    """Consume ONE quoted-delimiter heredoc whose opener matched at cmd[i:] (m).

    Returns (chunks, payload, next_i): `chunks` are text pieces to append to the
    scanned output, `payload` is a live body to keep as an extra chunk (or None
    when the body is inert / no terminator), and `next_i` is where the caller
    resumes. Split out of _split_inert_heredocs purely to bound that function's
    complexity; the behavior — including every fail-OPEN/CLOSED argument in the
    inline comments — is unchanged."""
    chunks = []
    # Pick the group that MATCHED, not the first truthy one: `<<''` is a
    # valid empty delimiter (terminated by the first blank line), and
    # or-chaining turned that matched '' into None, so the terminator was
    # never found and everything after it — including a live merge — was
    # discarded as body. Fail-OPEN (verified).
    delim = next(gr for gr in m.groups() if gr is not None)
    strip_tabs = cmd[i:i + 3].startswith('<<-')
    chunks.append(m.group(0))
    # Body starts after the rest of the current line; the line's remainder
    # (other redirections, further args) stays in the scanned text.
    nl = cmd.find('\n', m.end())
    if nl == -1:
        return chunks, None, m.end()
    # ACCEPTED OVER-FIRE: only the FIRST opener on a line is consumed, so a
    # second quoted heredoc's body (`cat <<'A' <<'B'`) is still scanned as
    # commands and can produce a false-positive block. Consuming the extra
    # openers was tried and REVERTED — matching them needs quote- and
    # comment-awareness this scanner does not have, and getting it wrong
    # loses live text: a fake opener in a comment (`cat <<'A' # <<'B'`) and
    # an UNQUOTED opener earlier on the line both made the scanner discard a
    # body bash really executes (fail-OPEN, verified). An over-fire only
    # blocks; discarding live text is a bypass.
    chunks.append(cmd[m.end():nl + 1])
    body_start = nl + 1
    end = None
    term_end = None
    j = body_start
    while j <= len(cmd):
        eol = cmd.find('\n', j)
        line = cmd[j:] if eol == -1 else cmd[j:eol]
        if (line.lstrip('\t') if strip_tabs else line) == delim:
            end = j
            term_end = len(cmd) if eol == -1 else eol
            break
        if eol == -1:
            break
        j = eol + 1
    if end is None:
        # NO terminator line — so this was never a real heredoc. Something
        # that merely LOOKS like an opener (inside a comment, inside an
        # ANSI-C `$'...'` string, a construct this scanner mis-lexes) would
        # otherwise swallow the entire rest of the command as "body",
        # discarding any live command after it — the one genuinely new
        # fail-OPEN surface heredoc stripping introduces (verified).
        # Emitting the text unchanged keeps it in the scanned string, so an
        # unrecognized opener costs at most an over-fire on inert prose.
        chunks.append(cmd[body_start:])
        return chunks, None, len(cmd)
    body = cmd[body_start:end]
    # A body an interpreter will run is NOT inert — keep it as a live chunk.
    # Test EVERY command on the logical line, not just the one owning the
    # redirection: the consumer can sit before it (`true; bash <<'EOF'`) or
    # AFTER it, downstream of a pipe (`cat <<'EOF' | bash`), which really
    # does execute the body (verified). Any interpreter on the line ⇒ keep
    # the body — fail-CLOSED, since an unnecessary extra chunk can only
    # over-fire on inert text, while missing one lets a merge through.
    # Deliberately a LOOSE word scan rather than command-word parsing. The
    # consumer can hide behind an assignment and a substitution opener
    # (`x=$(bash <<'EOF'`), where _command_argv sees only the assignment and
    # reported no interpreter, dropping a body bash really runs (fail-OPEN,
    # verified). Splitting the opener line on shell punctuation and matching
    # ANY word covers those shapes without parsing a truncated construct.
    # Over-matching (a mere FILENAME called `bash`) only keeps an inert body
    # as an extra chunk — an over-fire, the safe direction. Note this reads
    # the OPENER line only, never the body, so heredoc PROSE is unaffected.
    line_text = cmd[line_start:nl]
    words = re.split(r'[\s;|&()`$=<>]+', line_text)
    # Strip shell quoting from each word before matching: `'bash'`,
    # `"bash"`, `\bash` and `/bin/"bash"` are all the bash executable, and a
    # raw comparison recognized none of them, discarding a body bash really
    # runs (fail-OPEN, verified).
    # Keep the body when the consumer CANNOT BE RESOLVED statically — a
    # command word built from a variable or substitution (`runner=bash;
    # "$runner" <<'EOF'`) really does execute it (verified: two merges ran,
    # counted 0). Dropping an unresolved consumer's body is the discard this
    # change introduces, and it reaches `careful-guard.sh` too, which reuses
    # _all_chunks — a destructive command behind `$runner` would have gone
    # unseen. Unresolvable ⇒ keep ⇒ fail-CLOSED. Prose openers name a literal
    # command (`gh issue comment … --body-file - <<'EOF'`) and are unaffected.
    # Look at the COMMAND WORD of each segment on the opener line, not the
    # split words: '$' is one of the split delimiters above, so a `$` never
    # survives into `words` and this check silently never fired. Testing the
    # command word (rather than the whole line) keeps a prose opener that
    # merely has a variable ARGUMENT — `gh issue comment "$NUM"
    # --body-file - <<'EOF'` — correctly inert, which is the #426 case.
    def _consumer_words(seg):
        # Two candidate command words for the opener segment, differing only
        # in how a WRAPPER OPTION's arity is guessed. Arity is genuinely
        # ambiguous statically — `env -i "$runner"` (no-arg -i) and
        # `env -u FOO "$runner"` (value-taking -u) put the real command word
        # in different places, and either single guess MISSES one (fail-OPEN,
        # both verified against bash + the old substring guard). Checking
        # BOTH is fail-CLOSED: one guess always lands on the real consumer, so
        # a dynamic one is never missed. When there is no wrapper the two
        # agree on the command word, so an ARGUMENT like `$NUM` in
        # `gh issue comment "$NUM" …` does not falsely mark an inert body
        # live (the #426 case). Tokenizing (not whitespace-split) also skips
        # redirections and quoted assignment values that otherwise posed as
        # the command word.
        words = []
        for t in _tokenize(seg):        # A: wrapper options treated as no-arg
            if (re.match(r'^\w+=', t) or t.startswith('-')
                    or re.match(r'^(\d*[<>]{1,2}|&>{1,2})', t)
                    or t.rsplit('/', 1)[-1] in _WRAPPERS):
                continue
            words.append(t)
            break
        argv = _command_argv(seg, '')   # B: wrapper option treated as arg-taking
        if argv:
            words.append(argv[0])
        return words

    dynamic = any('$' in w or '`' in w
                  for _op, seg in split_segments(line_text)
                  for w in _consumer_words(seg))
    payload = None
    if dynamic or any(w.replace('\\', '').replace('"', '').replace("'", '')
                      .rsplit('/', 1)[-1] in _BODY_EXECUTORS
                      for w in words if w):
        payload = body
    # The terminator line is shell SYNTAX, not a command — dropping it (rather
    # than emitting it back into the scanned text) stops a delimiter that happens
    # to be named like a gated command (`cat <<'gh pr merge 1'`) registering as a
    # real invocation, a false-positive block. Quoted delimiters may legally
    # contain spaces.
    return chunks, payload, term_end


def _split_inert_heredocs(cmd):
    r"""Separate QUOTED-delimiter heredoc bodies from the command text.

    bash performs NO expansion inside a quoted-delimiter heredoc (<<'EOF',
    <<"EOF", <<\EOF), so the body is pure DATA — prose that quotes a gated
    command there must not trip the gate (issue #426: writing an issue comment
    ABOUT the merge gate blocked on the merge gate). An UNQUOTED `<<EOF` body
    does expand `$(...)`, so it is left in the text and scanned as before.

    Returns (cmd_without_inert_bodies, [bodies an interpreter will execute]).
    `bash <<'EOF'` / `eval` DO run their quoted body, so those bodies are handed
    back as extra chunks rather than dropped — dropping them would fail OPEN.

    The `<<` opener is only honored outside quotes, so `echo "<<'EOF'"` cannot
    be used to make the scanner discard live text that follows.
    """
    out = []
    payloads = []
    i = 0
    n = len(cmd)
    quote = None
    ansi_c = False
    line_start = 0
    while i < n:
        c = cmd[i]
        if quote is not None:
            out.append(c)
            # ANSI-C $'...' honors \' as a literal quote — see split_segments.
            if c == '\\' and (quote == '"' or ansi_c) and i + 1 < n:
                out.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
                ansi_c = False
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            ansi_c = c == "'" and _is_ansi_c_dollar(cmd, i)
            out.append(c)
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            out.append(c)
            out.append(cmd[i + 1])
            i += 2
            continue
        if c == '\n':
            out.append(c)
            i += 1
            line_start = i
            continue
        if c == '#' and (i == 0 or cmd[i - 1] in ' \t\n;|&('):
            # A shell COMMENT runs to end of line and opens no heredoc. Without
            # this, `: # <<'EOF'` was read as a real opener and — when some later
            # line happened to match the delimiter — the live commands between
            # them were removed as inert body (fail-OPEN, verified). The comment
            # text itself is copied through: it is inert, so at worst it
            # over-fires, which is the safe direction.
            eol = cmd.find('\n', i)
            if eol == -1:
                out.append(cmd[i:])
                break
            out.append(cmd[i:eol])
            i = eol
            continue
        m = _HEREDOC_QUOTED.match(cmd, i) if c == '<' else None
        if m and re.search(r'(?<!<)<<-?[ \t]*[^\s\'"\\<]', cmd[line_start:i]):
            # An UNQUOTED heredoc opened earlier on this line. Its body comes
            # FIRST, so the text after the line is not this heredoc's body and
            # the delimiters cannot be associated by position alone. Consuming it
            # anyway discarded a live command out of the unquoted body — which
            # bash DOES expand and execute (fail-OPEN, verified). Leave the whole
            # region in the scanned text instead.
            m = None
        if not m:
            out.append(c)
            i += 1
            continue
        chunks, payload, i = _consume_heredoc(cmd, i, m, line_start)
        out.extend(chunks)
        if payload is not None:
            payloads.append(payload)
    return ''.join(out), payloads



def _interpreter_payloads(argv):
    """Strings an interpreter argv may execute (`bash -c '<s>'`), fail-CLOSED.

    Find the first sign-prefixed token containing `c`, then return EVERY later
    argv as a candidate. Behaviors verified against real bash/sh/zsh:

      -c / -lc / -ec / -xc / -cl / -ce   all execute the payload — `c` may sit
          anywhere in the cluster, so match on membership, not position.
      +c / +lc                           bash accepts '+' as an option sign and
          ignores the sign when matching `c`.
      -Oc extglob / -cO extglob          an option in the SAME cluster can eat a
          value, shifting the command string further along.
      --rcfile -custom -c "<s>"          an option VALUE can itself look like a
          clustered `-c`.
      zsh -cO "<s>" placeholder          zsh's `-O` takes NO value, unlike
          bash's — option arity is PER-SHELL.

    Returning the whole tail rather than one computed index is deliberate. To
    pick a single index you must model option arity, and arity differs per
    interpreter (bash `-O` consumes a value; zsh `-O` does not), so a
    bash-shaped model MISSES on zsh — fail-OPEN. The tail also covers every way
    a command string can reach its own arguments without enumerating them:
    `$0`, `$1`, `$@`, `${!#}`, `$BASH_ARGV`, `$argv[1]` — all verified to
    execute the trailing argument. Scanning an extra inert token is the
    fail-CLOSED direction; missing a real one is not.

    ACCEPTED RESIDUALS (deliberate — see the module docstring):

    1. False positive on a script's OWN arguments. `bash script.sh -lc "git
       commit"` passes `-lc` to script.sh and executes nothing, but `-lc` is
       matched here anyway, so the gate fires on a command that never commits.
       Suppressing it requires the per-shell arity model above, whose failure
       mode is fail-OPEN. An over-firing gate is the safe direction for a
       warn/block gate; the operator can still proceed.
    2. Dynamically constructed payloads are UNDECIDABLE and NOT covered.
       `bash -c "$(printf '...' | base64 -d)"` is verified to execute, and no
       static scan can decide it. This gate stops CARELESS commits, not a
       determined operator — who already has `--no-verify` and the skip file.
       Do not try to close this class; it cannot be closed.
    """
    for k in range(1, len(argv)):
        if _is_c_option(argv[k]):
            return argv[k + 1:]
    return []


def _is_c_option(tok):
    """True iff `tok` is a sign-prefixed short-option cluster containing `c`
    (e.g. `-c`, `-lc`, `+c`) rather than a long option (`--foo`, `++foo`).

    Extracted from `_interpreter_payloads` as a named predicate purely to
    reduce that function's branch count (CodeScene "Complex Conditional");
    behavior is unchanged."""
    return (tok[:1] in ('-', '+') and not tok.startswith(('--', '++'))
            and 'c' in tok[1:])


def _env_split_string_payloads(seg):
    r"""Commands packed into an `env -S` / `env --split-string=` argument.

    `env -S "gh pr merge 1"` puts a WHOLE command in one argument, which env then
    splits and executes (verified). Must be read from the RAW tokens: the generic
    wrapper walk in `_command_argv` strips `env`, then consumes the packed string
    as an ordinary option-argument, so the command word inside was never seen at
    all — the argv came back empty and the segment was skipped (fail-OPEN).
    """
    toks = _tokenize(seg)
    # `env` need not be token zero: `command env -S …`, `X=1 env -S …`,
    # `/usr/bin/env -S …` all reach it behind launcher prefixes, and anchoring on
    # token zero missed every one of them (fail-OPEN, verified). Scan from the
    # first `env` token instead; a stray later `env` argument only over-scans.
    start = next((k for k, t in enumerate(toks)
                  if t.rsplit('/', 1)[-1] == 'env'), None)
    if start is None:
        return []
    out = []
    # env options that take a SEPARATE value. Without this the walk mistook that
    # value for the utility and stopped early, so `env -u FOO -S '<cmd>'` never
    # reached the -S and the packed command went uncounted (fail-OPEN).
    # -P is the macOS utility-search-path option; omitting it stopped the walk
    # on its value and the -S payload was never reached (fail-OPEN).
    value_opts = {'-u', '--unset', '-C', '--chdir', '-P', '-a', '--argv0'}
    skip_value = False
    for k, a in enumerate(toks[start + 1:], start=start + 1):
        if skip_value:
            skip_value = False
            continue
        # env's own options END at `--` or at the first non-option word (the
        # utility). Scanning past that read the UTILITY's arguments as env
        # options, so `env -- printf '%s' -S '<cmd>'` — which only prints prose
        # — was extracted as an executable payload and blocked.
        if a == '--' or not a.startswith('-'):
            break
        if a in value_opts:
            skip_value = True
            continue
        payload = _env_S_payload(a, toks, k)
        if payload is not None:
            out.append(payload)
    return out


def _env_S_payload(a, toks, k):
    """The command string packed into an `env` split-string option `a` at index
    `k`, or None when `a` is not such an option (or its payload is absent). Forms:
    `--split-string=<cmd>`, a short-option cluster containing S (`-S<cmd>` /
    `-iS<cmd>` attached, or `-S` with the payload in the NEXT token), and
    `--split-string <cmd>`. Split out of _env_split_string_payloads purely to
    reduce its complexity; behavior unchanged."""
    if a.startswith('--split-string='):
        return a.split('=', 1)[1]
    if a.startswith('-') and not a.startswith('--') and 'S' in a[1:]:
        # Short-option cluster containing S. The payload is either ATTACHED
        # (everything after the S — `env -S"cmd"` tokenizes to `-Scmd`, and
        # `env -iS"cmd"` to `-iScmd`, so S need not be first) or the NEXT
        # token when the cluster ends at the S. Reading only the next token
        # for an attached form skipped the payload entirely (fail-OPEN).
        attached = a[a.index('S', 1) + 1:]
        if attached:
            return attached
        return toks[k + 1] if k + 1 < len(toks) else None
    if a == '--split-string' and k + 1 < len(toks):
        return toks[k + 1]
    return None


def _shell_payloads(cmd):
    """Strings an interpreter/eval will itself execute — `bash -c '<s>'`,
    `sh -c '<s>'`, `eval '<s>' '<t>'`, etc. — for recursive scanning."""
    out = []
    for _op, seg in split_segments(cmd):
        out.extend(_env_split_string_payloads(seg))
        argv = _command_argv(seg, '')  # '' = no exe guard, just strip launchers
        if not argv:
            continue
        base = argv[0].rsplit('/', 1)[-1]
        if base in _INTERPRETERS:
            out.extend(_interpreter_payloads(argv))
        elif base == 'eval':
            out.append(' '.join(argv[1:]))
    return out


def _all_chunks(cmd, _depth=0, _truncated=None):
    """cmd plus every string the shell will additionally execute — command
    substitutions and interpreter/eval payloads — recursively (depth-bounded).

    Continuations are stripped BEFORE extraction: a continuation can split the
    `$(` of a substitution, and an extractor reading the raw text would miss the
    substitution entirely (verified — `echo $\\<newline>(git commit)` commits).

    `_truncated`, when a list is passed, collects a marker if recursion stops at
    the depth bound with extras STILL unexpanded (#377). It is reported from
    inside this traversal on purpose: a parallel re-implementation of the walk
    silently drifts from the real depth accounting, which is exactly how the
    first two attempts at this signal went wrong."""
    cmd = strip_continuations(cmd)
    cmd, heredoc_payloads = _split_inert_heredocs(cmd)
    chunks = [cmd]
    if _depth < 6:
        # ACCEPTED OVER-COUNT: a substitution the parent shell expands is counted
        # both as its own chunk and again inside the interpreter payload, so
        # `bash -c "echo $(gh pr merge 1)"` counts 2 though bash runs it once.
        # Removing the parent-extracted spans from the payload was tried and
        # REVERTED: identical substitution text in an independently
        # single-quoted payload then got erased too, so
        # `bash -c 'echo $(gh pr merge 1)'; echo "$(gh pr merge 1)"` — two REAL
        # merges — counted 1 and slipped past the multi-merge guard (verified).
        # An over-count only BLOCKS; an under-count is a bypass. Keep the
        # over-count.
        for extra in (_command_substitutions(cmd) + _shell_payloads(cmd)
                      + heredoc_payloads):
            if extra:
                chunks.extend(_all_chunks(extra, _depth + 1, _truncated))
    elif _truncated is not None and (_command_substitutions(cmd)
                                     or _shell_payloads(cmd) or heredoc_payloads):
        # Depth cap reached with more to expand — record it so counters can fail
        # closed rather than silently report "nothing here".
        _truncated.append(True)
    return chunks


def chunks_and_truncation(cmd):
    """(chunks, truncated) from ONE traversal — the honest "could not fully
    analyze" signal (#377), for callers that must not clear what they could not
    read. `truncated` is True exactly when `_all_chunks` hit its depth bound
    with payloads left unexpanded, so it cannot disagree with what was scanned.

    One walk, not two — but not free: passing the collector makes `_all_chunks`
    run its extractors at each depth-boundary node (to see whether anything was
    left unexpanded), which the untracked path (`_truncated=None`) skips. The
    common case is fast — `unsafe()` short-circuits the moment truncation is seen
    (measured 0.07s even at 30 levels). Only a payload crafted to sit JUST under
    the boundary pushes the probe into `_all_chunks`' exponential over-count
    (#426's, not new here) — ~3s at 24 levels. That cost lands ONLY on this
    advisory path, and careful-guard WALL-TIME-BOUNDS it with a 3s SIGALRM that
    turns a slow scan into a warn (the safe direction) rather than a hung
    PreToolUse hook. The fail-CLOSED gates pass no collector and pay nothing."""
    flag = []
    return _all_chunks(cmd, 0, flag), bool(flag)


def extraction_truncated(cmd):
    """Truncation alone, for callers that do not need the chunks."""
    return chunks_and_truncation(cmd)[1]


def _scan_commit(chunk, allow_cd):
    """Scan one command chunk for a real `git commit`; return the result tuple
    or None. allow_cd=False for substitution bodies (subshell cwd is untrusted)."""
    pending_cd = None
    for op, seg in split_segments(chunk):
        cd = _cd_target(seg)
        if cd is not None:
            pending_cd = cd
            continue
        argv = _command_argv(seg, 'git')
        if not argv or not _is_exe(argv[0], 'git'):
            pending_cd = None
            continue
        # subcommand = first non-flag token after git. git global options that
        # take a SEPARATE value token must have that value skipped, or it is
        # mistaken for the subcommand (git --git-dir /d --work-tree /r commit).
        skip = False
        sub = None
        sub_idx = len(argv)
        for i, a in enumerate(argv[1:], start=1):
            if skip:
                skip = False
                continue
            if a in ('-C', '-c', '--git-dir', '--work-tree', '--namespace',
                     '--super-prefix', '--config-env'):
                skip = True
                continue
            if a.startswith('-'):
                continue
            sub = a
            sub_idx = i
            break
        if sub != 'commit':
            pending_cd = None
            continue
        base = _trusted_cd(pending_cd, op) if allow_cd else ''
        if allow_cd:
            # git applies every GLOBAL -C in order; a relative value resolves from
            # the directory established so far (cd base, then each preceding -C).
            # Only pre-subcommand -C changes directory; `git commit -C <ref>` (after
            # the subcommand) is the reuse-message flag, not a cd — so bound the
            # walk to sub_idx or it mis-scopes the marker check to the wrong repo.
            k = 0
            while k < sub_idx:
                if argv[k] == '-C' and k + 1 < sub_idx:
                    v = os.path.expanduser(argv[k + 1])
                    if os.path.isabs(v):
                        base = v
                    elif base:
                        base = os.path.join(base, v)
                    else:
                        base = v
                    k += 2
                else:
                    k += 1
        target_dir = base
        opt_words = argv[:argv.index('--')] if '--' in argv else argv
        is_amend = '--amend' in opt_words
        return True, target_dir, is_amend
    return None


def git_commit(cmd):
    """Detect a real `git commit` invocation via command-word analysis.

    Returns (is_commit: bool, target_dir: str, is_amend: bool). target_dir is
    the cd/`git -C` target that scopes the repo (cd trusted only when it '&&'-
    gates the commit — see _trusted_cd); is_amend is True only when --amend
    appears in the option portion (before any `--` pathspec separator). Command
    substitutions ($(...), backticks) are scanned too — they EXECUTE their inner
    command — but their subshell cwd makes target_dir untrusted (returned '')."""
    chunks = _all_chunks(cmd)
    r = _scan_commit(chunks[0], True)
    if r:
        return r
    for chunk in chunks[1:]:
        r = _scan_commit(chunk, False)
        if r:
            return r
    return False, '', False


def _gh_find_pr_sub(rest, subcommand):
    """Index in `rest` (argv after `gh`) of the `pr` token immediately followed by
    `subcommand`, reached past gh global flags and their values, or None. Split out
    of _iter_gh purely to reduce its complexity; behavior unchanged."""
    j = 0
    prev_flag = False
    while j < len(rest):
        a = rest[j]
        if a == 'pr' and rest[j + 1:j + 2] == [subcommand]:
            return j
        if a.startswith('-'):
            prev_flag = True
            j += 1
        elif prev_flag:
            prev_flag = False
            j += 1
        else:
            break
    return None


def _gh_pr_number(tokens):
    """The PR number of a `gh pr <subcommand>` invocation: the first bare integer
    in `tokens` that is NOT a value-taking flag's value, or ''. Skip flags; for the
    gh-pr-merge value-taking flags also skip their separate value, so
    `gh pr merge --subject 123 5` resolves 5 (not the subject), while
    `gh pr merge --squash 5` (boolean flag) still resolves 5. Split out of _iter_gh
    purely to reduce its complexity; behavior unchanged."""
    value_flags = {'-b', '--body', '-F', '--body-file', '-t', '--subject',
                   '-R', '--repo', '--match-head-commit', '--author-email'}
    skip_val = False
    for x in tokens:
        if skip_val:
            skip_val = False
            continue
        if x.startswith('-'):
            if '=' not in x and x in value_flags:
                skip_val = True
            continue
        if re.match(r'^\d+$', x):
            return x
    return ''


def _iter_gh(chunk, subcommand, allow_cd):
    """Yield one result tuple per `gh pr <subcommand>` command word in `chunk`.
    allow_cd=False for substitution bodies (subshell cwd untrusted)."""
    pending_cd = None
    for op, seg in split_segments(chunk):
        cd = _cd_target(seg)
        if cd is not None:
            pending_cd = cd
            continue
        argv = _command_argv(seg, 'gh')
        if not argv or not _is_exe(argv[0], 'gh'):
            pending_cd = None
            continue
        rest = argv[1:]
        j = _gh_find_pr_sub(rest, subcommand)
        if j is None:
            pending_cd = None
            continue
        target_dir = _trusted_cd(pending_cd, op) if allow_cd else ''
        pr_num = _gh_pr_number(rest[j + 2:])
        yield True, target_dir, pr_num
        pending_cd = None


def _scan_gh(chunk, subcommand, allow_cd):
    """First `gh pr <subcommand>` in `chunk`, or None."""
    return next(_iter_gh(chunk, subcommand, allow_cd), None)


def gh_pr_count(cmd, subcommand):
    """Count every `gh pr <subcommand>` COMMAND WORD the shell would run,
    across the command plus every substitution / interpreter payload.

    Used by the pre-merge gate's multi-merge guard. Counting command words
    rather than substring occurrences is what keeps prose that merely QUOTES
    the merge command — an issue comment, a --body, a test fixture's input
    string — from reading as N chained merges (issue #426), while still
    catching `bash -c "gh pr merge 1 && gh pr merge 2"` (the payload is a
    scanned chunk, and its merges are real command words)."""
    truncated = []
    chunks = _all_chunks(cmd, 0, truncated)
    count = sum(len(list(_iter_gh(c, subcommand, False))) for c in chunks)
    if truncated:
        # Recursion hit the depth cap, so a merge nested deeper than it expands
        # would score 0 — and the substring guard this replaced DID block those.
        # Restore that floor for this corner only: a raw occurrence count. Prose
        # never sits seven interpreter payloads deep, so the #426 false positive
        # does not come back, and the gate stays fail-CLOSED on what it cannot
        # fully parse.
        # Strip shell quoting first: the shell normalizes `g"h" p"r" merge` to a
        # real invocation, and a literal-only regex found nothing there — leaving
        # the fallback reporting 0 on exactly the input it exists to catch.
        # Drop the `$` of an ANSI-C `$'...'` too, or the normalization leaves
        # `$gh $pr merge` and the fallback reports 0 on the very input it is for.
        flat = re.sub(r'\$(?=[\'"])', '', cmd)
        flat = re.sub(r'[\'"\\]', '', flat)
        count = max(count, len(re.findall(
            r'\bgh\s+pr\s+' + re.escape(subcommand) + r'\b', flat)))
    return count


def gh_pr(cmd, subcommand):
    """Detect a real `gh pr <subcommand>` (create/merge) via command-word
    analysis. Returns (present: bool, target_dir: str, pr_num: str). gh global
    flags before the subcommand (gh --repo owner/repo pr create, gh --hostname h
    pr merge 5) are skipped, including a single value token after each flag. cd
    trust is operator-aware; command substitutions ($(...), backticks) are
    scanned (subshell cwd → target_dir '')."""
    chunks = _all_chunks(cmd)
    r = _scan_gh(chunks[0], subcommand, True)
    if r:
        return r
    for chunk in chunks[1:]:
        r = _scan_gh(chunk, subcommand, False)
        if r:
            return r
    return False, '', ''


# ── Effective cwd of a file-write in a Bash command (#347 item 2) ──────────────
# The design-review marker gates must anchor on the directory a write LANDS in, not
# the payload cwd, when the command changes directory inline (`cd /repo && > f`).
# The prior gates were cd-blind: the read gate anchored on the payload cwd and the
# detector armed against the process cwd, so `cd /pending-repo && > src/impl.sh`
# checked/armed the WRONG repo (design §2/§9, confirmed HIGH in #346).
#
# effective_cwd() resolves a leading single ABSOLUTE PLAIN-LITERAL `cd` and is BEST-EFFORT
# (the second tuple element is always True): a shape it cannot resolve falls back to the
# payload cwd — the pre-existing cd-blind anchor — so the result is never WORSE than before,
# only better in the confident case (see the effective_cwd docstring and ADR 0021). It is NOT
# a fail-closed contract. The constraints mirror ADR 0018's standalone-cd rule (the
# merge-time nudge parser): an absolute, `..`-free literal resolves identically under bash's
# default logical `cd` and the downstream `git -C`, while a relative operand is subject to
# CDPATH and a `..` diverges through symlinks.
_CD_UNSAFE_RE = re.compile(r'[$`*?\[\]{}~\s]')
_ASSIGN_LEAD_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\+?=')


def _abs_cd_target(target):
    """Return an ABSOLUTE plain-literal `cd` operand we can trust, else ''. Only
    absolute literals are resolved: a RELATIVE operand is subject to CDPATH (which can
    send `cd sub` outside the payload cwd), so it is left to the best-effort payload
    anchor instead. Rejects '..' (diverges through symlinks under logical vs physical
    cd) and any shell-expansion/glob/whitespace metachar."""
    if (target and target.startswith('/')
            and '..' not in target.split('/')
            and not _CD_UNSAFE_RE.search(target)):
        return target
    return ''


def effective_cwd(cmd, payload_cwd):
    """Return (cwd, ok) — the directory a file-write in `cmd` runs in, given the
    shell starts in `payload_cwd`. The anchor only needs to identify the WRITE's
    REPOSITORY (the gate keys markers on the git-common-dir), not the exact subdir.

    BEST-EFFORT (not fail-closed): the second tuple element is always True — a caller
    never blocks on this. When the write's cwd cannot be resolved confidently, it returns
    the PAYLOAD cwd, i.e. the pre-existing cd-blind anchor, so the result is never WORSE
    than before this parser existed. It only IMPROVES the confident case:

      * No `cd` → payload_cwd (behavior unchanged).
      * A single builtin `cd` (optionally `builtin`/`command`-wrapped) to an ABSOLUTE
        plain literal, reached before any real command word via ''/';'/newline/'&&' → the
        target, but ONLY when it is a searchable DIRECTORY (`isdir` AND `os.access` X_OK —
        both, since X_OK alone passes an executable file like `cd /bin/ls`): a `cd` into a
        missing, non-searchable, or non-directory target fails, leaving the
        write in the prior cwd (`;`) or short-circuiting it (`&&`), so the prior cwd is
        kept. Absolute-only is deliberate — a RELATIVE operand is subject to CDPATH
        (`cd sub` can land outside the payload cwd), so it is left to the payload anchor
        rather than mis-resolved.
      * ANY ambiguous shape — relative/opaque target, >1 cd, a cd AFTER a real command, a
        cd behind '||'/'|'/'&', a subshell-grouped cd, or a stray `cd` token inside
        `if`/`while`/a group → falls back to payload_cwd.

    Statically resolving every shell cd is undecidable (a `cd` in a function/alias, an
    interpreter one-liner, `xargs`, ambient CDPATH…); those stay the ADR 0006
    hostile-dispatcher residual. The design-review gate is cooperative-mis-fire
    protection, so a best-effort accuracy bump is the right posture — see ADR 0021."""
    cwd = payload_cwd
    seen_cd = False
    seen_cmd = False
    for op, seg in split_segments(cmd):
        done, cwd, seen_cd, seen_cmd = _cwd_step(
            op, seg, cwd, payload_cwd, seen_cd, seen_cmd)
        if done is not None:
            return done
    return cwd, True


def _cwd_step(op, seg, cwd, payload_cwd, seen_cd, seen_cmd):
    """One segment of effective_cwd's scan. Returns
    (done, cwd, seen_cd, seen_cmd): `done` is a resolved (cwd, True) tuple to
    return IMMEDIATELY (best-effort give-up or final), or None to keep scanning
    with the (possibly updated) cwd/seen_* state. Split out of effective_cwd purely
    to bound its complexity; the semantics are unchanged (see that docstring)."""
    # '&' is NOT like '||'/'|': it BACKGROUNDS the preceding list in a subshell, so its
    # `cd` never moved the FOREGROUND shell — the write after '&' runs in payload_cwd
    # regardless of seen_cmd (`cd /x && true & > f` writes in payload, not /x). Give up
    # unconditionally, else we'd anchor to the wrong repo (a real fail-open).
    if seen_cd and op == '&':
        return (payload_cwd, True), cwd, seen_cd, seen_cmd
    # '||'/'|' after a cd need care. If a command has ALREADY run in the cd's target
    # (seen_cmd), the cd stuck (it moved this same shell) and this branch runs there
    # too — `cd /x && false || w` leaves the write in /x — so keep the resolved cwd. If
    # the operator is DIRECTLY after the cd (no intervening command), the cd's own
    # success gates it — `cd /x || w` runs the write only if the cd FAILED, i.e. in
    # payload — so payload.
    if seen_cd and op in ('||', '|'):
        return ((cwd if seen_cmd else payload_cwd), True), cwd, seen_cd, seen_cmd
    if not seg:
        return None, cwd, seen_cd, seen_cmd
    toks = _tokenize(seg)
    if not toks:
        return None, cwd, seen_cd, seen_cmd
    # A bare '(' / ')' token is real subshell grouping (substitutions keep their
    # paren inside one token), so this flags only true grouping.
    subshell = any(t in ('(', ')') for t in toks)
    i = 0
    while i < len(toks) and _ASSIGN_LEAD_RE.match(toks[i]):
        i += 1  # skip leading NAME=val / NAME+=val assignments to the command word
    # `builtin cd /x` / `command cd /x` are the only wrappers that still move the
    # PARENT shell's cwd (env/sudo/nice/… fork a child). Strip a run of them (EXACT
    # tokens — a path-qualified `/x/command` is an external program, not the builtin)
    # so the real `cd` is reached — else `builtin cd /pending && <write>` fast-allows.
    while i < len(toks) and toks[i] in ('builtin', 'command'):
        i += 1
    cw = toks[i] if i < len(toks) else ''
    # The cd command word must be EXACTLY `cd` — a path-qualified `/tmp/cd` is an
    # EXTERNAL executable that runs in a child process and CANNOT change the parent
    # shell's cwd, so trusting its operand would anchor the gate on a dir the write
    # never entered (`/tmp/cd /clean && sed` writes in payload_cwd). Not-exactly-`cd`
    # paths fall through to the stray-`cd`-token check below (endswith('/cd')).
    is_cd = (cw == 'cd')
    # A `cd` that is NOT the clean command word we handle below — inside a conditional
    # (`if cd /x; then …`), a loop, a group, or a path-qualified external — changes (or
    # fails to change) the cwd in a way we cannot attribute. Detect ANY stray `cd`-ish
    # token and give up. (`cd` as a mere argument, e.g. `grep cd f`, only reaches a
    # FILE-MODIFYING block for the rare command that both file-mods and carries a bare
    # `cd` word; accepted conservative over-block.)
    handled_cd_idx = i if is_cd else -1
    for k, t in enumerate(toks):
        if k == handled_cd_idx:
            continue
        if t == 'cd' or t.endswith('/cd'):
            return (payload_cwd, True), cwd, seen_cd, seen_cmd   # give up → cd-blind anchor
    if is_cd:
        if seen_cd or seen_cmd or subshell or op not in ('', '&&', ';'):
            return (payload_cwd, True), cwd, seen_cd, seen_cmd   # give up → cd-blind anchor
        # Require EXACTLY one operand — `cd /a b` / bare `cd` are ambiguous.
        rest = toks[i + 1:]
        if len(rest) != 1:
            return (payload_cwd, True), cwd, seen_cd, seen_cmd   # give up → cd-blind anchor
        target = _abs_cd_target(rest[0])
        if not target:
            return (payload_cwd, True), cwd, seen_cd, seen_cmd   # relative/opaque → payload
        # Trust the absolute target only if bash could actually ENTER it: it must be a
        # DIRECTORY (isdir) AND searchable (os.access X_OK). Both are needed — isdir
        # alone passes an unsearchable dir (cd fails), and X_OK alone passes an
        # executable regular file like `cd /bin/ls` (cd fails, "not a directory"). A
        # `cd` that fails leaves the write in the PRIOR cwd (`;`/newline) or
        # short-circuits it (`&&`), so keeping the prior cwd is correct either way —
        # closing `cd /missing ; write`, `cd /unsearchable ; write`, and `cd /file ; write`.
        cwd = target if (os.path.isdir(target) and os.access(target, os.X_OK)) else cwd
        seen_cd = True
    elif cw == '':
        return None, cwd, seen_cd, seen_cmd  # pure assignment / empty segment — no cwd change
    else:
        seen_cmd = True  # a real command word; a LATER cd can no longer compose
    return None, cwd, seen_cd, seen_cmd


if __name__ == '__main__':
    # Debug/test CLI (the gate consumers import effective_cwd directly). Reads the
    # command from stdin; prints the best-effort resolved cwd (never fails — the
    # second tuple element is always True). exit 0 always, 2 = bad usage.
    import sys as _sys
    if _sys.argv[1:2] == ['effective-cwd']:
        _sys.stdout.write(effective_cwd(_sys.stdin.read(),
                                        _sys.argv[2] if len(_sys.argv) > 2 else '')[0])
        _sys.exit(0)
    _sys.exit(2)
