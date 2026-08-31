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
import fnmatch
import shlex

# Command wrappers that transparently precede the real command. Basename-matched
# so absolute-path forms (/usr/bin/env, /usr/bin/sudo) count too.
_WRAPPERS = frozenset((
    'command', 'env', 'sudo', 'doas', 'nohup', 'nice', 'time',
    'builtin', 'exec', 'stdbuf', 'setsid',
))

# Wrappers that take a non-option OPERAND before the command word: a duration
# (`timeout 5 CMD`) or a lockfile (`flock /tmp/l CMD`). `ionice` is NOT one of
# these -- it is option-only (`-c3`, `-c 3`) and needs no operand rule, so it
# lives in `_SCOPED_WRAPPERS` below instead. See its own note there for why
# latching the operand rule for it produced a verified false detection.
#
# `xargs` is DELIBERATELY ABSENT although #641 names it, and NO xargs spelling is
# modelled -- not the stdin-assembled one, and not the literal `xargs -0 git
# commit` either. It is not a lexical wrapper at all: it BUILDS the command line,
# taking argv from stdin and re-running the result zero or many times. Modelling
# it as one produced answers that were wrong rather than merely incomplete --
# `printf '%s\n' --repo other/repo | xargs gh pr merge 1` reported merge=True
# with override=False, so the gate would validate the CURRENT repo while gh
# merged another, and `xargs -n1 gh pr merge` reported gh_pr_count=1 for a
# command that can perform several, which is the number the pre-merge gate reads
# to refuse a multi-PR merge. Detecting only the spelling that happens to name
# `git` statically, while `printf commit | xargs git` sails past, buys coverage
# of one shape at the price of a confident wrong answer on others. Left as a
# documented miss and pinned in tests/test-gitcmd-detect.sh instead.
#
# This is a MEMBERSHIP set, deliberately NOT an arity table -- it carries no
# counts, offsets, or per-flag knowledge, which is the ladder #587/#593 exist to
# stop climbing (#593 non-goal 4) and which ADR 0032:368 already declines for
# `unshare -- CMD` / `chroot -- NEWROOT CMD` / `script -c CMD`. The rule it
# enables is uniform: inside one of these wrappers, a bare word that is NOT the
# target does not end the walk. `timeout -s TERM 5 git commit` therefore
# resolves without anyone teaching the walk what `-s` means.
#
# `xargs` is out of scope entirely -- see its own note above, and the known-miss
# rows in tests/test-gitcmd-detect.sh. So is `flock`'s own `-c` option, which
# hands a string to a shell without naming an interpreter, and a run-time
# ASSEMBLED command name (`printf git | xargs -I{} {} commit -m x`, where the
# command word is `{}` and the executable arrives on stdin -- verified to really
# run `git commit`), which is the residual ADR 0006 accepts and cmdword restates
# at its own _WRAPPERS note.
#
# DELIBERATELY NOT MEMBERS OF `_WRAPPERS`, and recognised only when the caller
# passes `wrapper_operands=True`. `_WRAPPERS` is read by the cd/pushd/popd walk
# and by two other scans, so widening it leaked straight out of this change's
# stated git/gh-only scope: with these names in it,
# `ionice -c3 echo cd /other; git commit` and
# `printf x | xargs -0 echo cd /other; git commit` began reporting `/other` as
# untrusted_cd (measured against main, which reports ''), a NEW false stall for
# a subprocess that cannot change the parent shell's directory. A separate set
# consulted only on the git/gh path keeps the blast radius where the scope says
# it is. (`timeout` did not show the same leak — its numeric operand stops that
# walk — which is exactly why membership, not observation, has to be the rule.)
#
# Scoped to the git/gh detection call sites via `wrapper_operands=True`, never to
# the cd/pushd/popd caller: walking past a bare word there would report a `cd`
# that a subprocess wrapper never performed in this shell, and a MIS-SCOPED
# detection is strictly worse than the miss it replaces (#593 bar 1).
_OPERAND_WRAPPERS = frozenset(('timeout', 'flock'))

# Recognised as wrappers on the same call sites, but they take NO bare operand
# before the command word -- everything they accept is an option (`ionice -c3`,
# `ionice -c 3`). They therefore must NOT latch the operand rule: doing so let
# the walk step over an ordinary command word and land on an ARGUMENT, so
# `ionice -c3 echo git commit` -- which only prints -- read as a commit
# (verified). Unlike the `timeout 5 echo git commit` over-block, which is a real
# ambiguity between an operand and a command word, this one was purely the wrong
# grammar: there is no operand to be ambiguous with.
#
# Kept out of `_WRAPPERS` for the same reason as `_OPERAND_WRAPPERS` -- that set
# is read by the cd/pushd/popd walk, where a subprocess wrapper must not
# manufacture a directory change.
_SCOPED_WRAPPERS = frozenset(('ionice',))

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
        out.append((op, ''.join(buf).strip(' \t\n')))
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
    out.append((op, ''.join(buf).strip(' \t\n')))
    return out


def _tokenize(seg):
    """Tokenize a segment honoring quotes, with surrounding quotes stripped from
    each token. Falls back to a quote-stripping whitespace split when the
    segment cannot be lexed (e.g. unbalanced quotes) — fail-closed toward still
    finding the command word.

    Excludes CR from shlex's whitespace set (coderabbit #511). shlex's default
    whitespace is ' \\t\\r\\n', so `shlex.split` silently treats an UNQUOTED raw
    CR the same as a space: `git -C /repo<CR> commit` tokenizes to `-C /repo`
    with the CR simply dropped as a separator, instead of `-C` `/repo<CR>` --
    hiding it from every caller that validates the RETURNED token (e.g.
    `_reject_crlf` on a `git -C` operand at the top of this file) even though
    bash's own IFS does not include CR, so bash keeps `/repo<CR>` as ONE word
    and scopes git to a directory the gate never saw. An unquoted LF never
    reaches this function -- `split_segments` above already treats a bare `\\n`
    as a segment terminator -- so only `\\r` needs excluding here; a QUOTED
    CR/LF (`"/repo<CR>sub"`) was already preserved correctly by shlex, since
    whitespace only splits OUTSIDE quotes."""
    try:
        lex = shlex.shlex(seg, posix=True)
        lex.whitespace = ' \t\n'
        lex.whitespace_split = True
        lex.commenters = ''
        return list(lex)
    except ValueError:
        return [t.strip('\047\042') for t in seg.split()]


def _is_exe(tok, name):
    """True if tok is the executable `name` or an absolute/relative path to it."""
    return tok == name or tok.endswith('/' + name)


def _is_target_word(word, targets):
    """True iff basename `word` names one of the protected `targets`.

    Also matches the ANSI-C spelling of a protected BUILTIN: `$'pushd'` / `$'cd'`
    survive tokenization as `$pushd` / `$cd`, and bash still runs the builtin. Without
    stripping, the guard did not recognise them as the target, so
    `command -p $'pushd' /other` consumed the command word as the wrapper option's
    argument and reported no cd -- fail-OPEN.

    `$'pushd'` and a VARIABLE named `pushd` are byte-identical after tokenization, so
    this necessarily also matches `pushd=echo; $pushd /other`, where nothing moves.
    That direction is chosen deliberately: matching over-blocks (a visible, rewordable
    stall), while not matching lets a real ANSI-C-spelled builtin through unrecorded.
    Fail-CLOSED, consistent with the `$'cd'` handling `_cd_target_loose` has always
    had. A variable whose NAME is not a target (`$cmd`) still does not match, and
    _ANSIC_BUILTINS deliberately excludes `git`/`gh` (see its comment).

    Extracted from _command_argv -- which spelled this twice, once inline and once
    expanded inside the declared-name guard -- purely to reduce its branch count
    (CodeScene "Complex Method", #510); behavior unchanged."""
    stripped = word.lstrip('$')
    return word in targets or (stripped in targets
                               and stripped in _ANSIC_BUILTINS)


def _is_case_label(t, is_target, toks, i, case_state):
    """True iff `t` is a `case` branch PATTERN LABEL -- `x)` in
    `case x in x) git commit;;`.

    It heads its own segment for EVERY branch (';;' splits), not just the first, so
    matching the label shape covers them all without tracking case-statement state. An
    unquoted command word can never end in ')', so this cannot swallow a real command.
    A label may legally CONTAIN a paren once quoted or escaped (`a\\(b)`), so only a
    LEADING '(' is excluded -- that form is a group, handled by the grouping arm.

    Extracted from _command_argv as a named predicate purely to reduce its branch
    count (CodeScene "Complex Conditional", #510); behavior unchanged."""
    return (t.endswith(')') and not t.startswith('(') and not is_target
            and len(toks) > i + 1 and case_state != 'subject')


def _skips_declared_name(toks, i, base, targets):
    """True iff `toks[i]` is a DECLARED NAME to skip past rather than the command word
    -- `function f { git commit; }`, `coproc NAME { git commit; }`, or the loop
    variable of `for NAME in ...` / `select NAME in ...`.

    The name follows the keyword and would otherwise be read as the command word,
    hiding the body (verified: `function f { gh pr merge 1; }; f` runs the merge but
    counted 0). The POSIX form `f() { … }` is already covered: `f()` matches the
    label-shape rule. Skipping the body's commands is fail-CLOSED -- a
    declared-but-never-called function only over-fires.

    `coproc` takes a NAME only in the form `coproc NAME <compound>`; in
    `coproc bash -c '…'` the very next token IS the command, so an unconditional skip
    hid it (fail-OPEN regression). Require the name-then-compound shape, whose
    compound may open with '{' / '(' OR with a KEYWORD (`coproc JOB if git commit;
    then :; fi`) -- both shapes are accepted.

    `for`/`select` bind their loop variable in the SAME position, and a variable
    named after a wrapper (`for timeout in git commit; do echo "$timeout"; done`)
    was walked as if it OPENED that wrapper, landing on the loop's word LIST and
    reporting a commit that never runs -- the words are just strings the loop
    assigns to `$timeout` one at a time (a FALSE POSITIVE, i.e. fail-CLOSED: the
    gate stalls a command that performs no commit. Still worth fixing, but it is
    the safe direction, not the fail-OPEN this walk mostly guards against;
    verified; Codex finding, PR #650). Guarded by the identifier shape so the C-style `for (( i=0; ...))` form,
    whose next token is `((` and not a name, is left to the normal walk instead of
    being skipped on a guess.

    Never skips the target executable itself, so a program legitimately named e.g.
    `f` cannot hide one. Split out of _command_argv purely to reduce its complexity
    (#510); behavior unchanged (the conjuncts are all pure, so hoisting the bounds and
    target guards ahead of the shape test only short-circuits earlier).

    The `coproc` shape test is further split into `_is_coproc_declared_name`,
    purely to keep this function's own complexity under CodeScene's threshold
    after the `for`/`select` branch was added (PR #650); behavior unchanged."""
    if i >= len(toks) or _is_target_word(toks[i].rsplit('/', 1)[-1], targets):
        return False
    if base == 'function':
        return True
    if base in ('for', 'select'):
        return bool(re.match(r'^[A-Za-z_]\w*$', toks[i]))
    return base == 'coproc' and _is_coproc_declared_name(toks, i)


def _is_coproc_declared_name(toks, i):
    """True iff `toks[i]` is a `coproc NAME <compound>` declared name -- see
    `_skips_declared_name`'s docstring for the shape this guards against.

    Extracted purely to reduce `_skips_declared_name`'s cyclomatic complexity
    (CodeScene "Complex Method", PR #650); behavior unchanged."""
    return bool(i + 1 < len(toks)
                and re.match(r'^[A-Za-z_]\w*$', toks[i])
                and (toks[i + 1][:1] in ('{', '(')
                     or toks[i + 1].rsplit('/', 1)[-1] in _SHELL_KEYWORDS))


def _next_case_state(case_state, base, t):
    """The case-statement state after consuming token `t`.

    The case SUBJECT and first pattern label share a segment with the branch body:
    `case <subject> in <label>) git commit;;`. Later branches head their own segment
    (';;' splits) and are caught by the label-shape rule; only the first needs state.

    The two phases must be distinguished by the `in` keyword, not by "first token
    ending in ')'": a subject can itself end in ')' (`case "$(printf x)" in x) …`),
    which ended subject-tracking early and left `in` as the detected command word --
    fail-OPEN (verified).

    Split out of _command_argv purely to reduce its complexity (#510); behavior
    unchanged."""
    if case_state == 'subject':
        return 'label' if base == 'in' else 'subject'
    return None if t.endswith(')') else case_state


_REDIR_RE = re.compile(r'^(\d*[<>]{1,2}|&>{1,2})')
_REDIR_BARE_RE = re.compile(r'^(\d*[<>]{1,2}|&>{1,2})$')


def _redirection_span(t, toks, i):
    """How many tokens a redirection at `toks[i]` occupies: 2 when `t` is a BARE
    operator ('>', '2>') that consumes the target FILENAME after it, else 1 (a fused
    token like '>file' / '2>&1' is self-contained).

    Split out of _command_argv purely to reduce its complexity (#510); behavior
    unchanged."""
    return 2 if _REDIR_BARE_RE.match(t) and i + 1 < len(toks) else 1


def _strip_leading_groups(toks, raw_toks):
    """Strip leading subshell '(' / brace-group '{' punctuation from the segment's
    FIRST token, so grouped commands like `(git commit)` or `{ git commit; }` expose
    their command word. Returns the new (toks, raw_toks).

    Split out of _command_argv purely to reduce its complexity (#510); behavior
    unchanged."""
    while toks:
        head = toks[0].lstrip('({')
        if head == toks[0]:
            break
        if head:
            return [head] + toks[1:], raw_toks   # content edit -- position preserved
        toks = toks[1:]
        if raw_toks is not None:
            raw_toks = raw_toks[1:]
    return toks, raw_toks


def _strip_group_punct(toks, raw_toks, i):
    """Strip grouping punctuation from `toks[i]`, returning the new (toks, raw_toks).

    Grouping reached AFTER a keyword was skipped: `if (git commit); then` /
    `if { git commit; }; then`. The pre-loop strip only sees the segment's FIRST
    token, so a group opened behind a keyword kept the command word hidden --
    fail-OPEN (verified). The caller re-examines the same position.

    Split out of _command_argv purely to reduce its complexity (#510); behavior
    unchanged -- including that a content-only edit preserves the position (so
    raw_toks stays aligned untouched), while a whole-token deletion must drop the
    matching raw entry too."""
    stripped = toks[i].lstrip('({')
    if stripped:
        return toks[:i] + [stripped] + toks[i + 1:], raw_toks   # position preserved
    toks = toks[:i] + toks[i + 1:]
    if raw_toks is not None:
        raw_toks = raw_toks[:i] + raw_toks[i + 1:]
    return toks, raw_toks


def _command_argv(seg, target, with_raw=False, wrapper_operands=False):
    """Return the argv beginning at the command word, after stripping a leading
    run of launcher tokens: env-assignments, wrapper words (basename-matched),
    wrapper dash-options, and a SINGLE option-argument after a dash-option — but
    NEVER the `target` executable token (fail-closed: a no-arg option like
    `sudo -n` must not swallow the real command). `target` is the executable
    basename we must not skip (e.g. 'git' or 'gh'), or a TUPLE of them when a
    caller recognises several command words -- `_cd_target_loose` protects
    cd/pushd/popd, since protecting only 'cd' let `command -p pushd /other`
    consume `pushd` as the option's argument and report no directory change."""
    targets = (target,) if isinstance(target, str) else tuple(target)
    # NOTE: no `command -v NAME` shortcut here, deliberately. Such a query only
    # PRINTS a resolution, so recognising it would avoid one false block --
    # `command -v pushd; git commit`, which now reports an unknowable cd and stalls.
    # But `command` is not reliably the builtin: a shell function
    # (`command() { shift; "$@"; }`) or an executable (`./command`) can override it,
    # and both really do run their arguments. Any shortcut that returns "nothing
    # executed" therefore HIDES a real commit or merge from the gate -- trading a
    # visible, rewordable stall for a silent bypass, which is backwards here. The
    # over-block is the accepted cost; see the gate_classify_target boundary.
    toks = _tokenize(seg)
    # Original per-token spellings, carried alongside and mutated IN LOCKSTEP with
    # `toks`. An INDEX into `toks` cannot be handed to a caller: the branches below
    # DELETE tokens, so a position in the returned argv no longer names the same
    # token in the untouched stream -- and the deletions happen mid-stream, so no
    # single offset can correct for them. Carrying the spellings keeps `raw_argv[j]`
    # the spelling of `argv[j]` by construction. None when the raw stream cannot be
    # aligned at all (see _raw_tokens); callers then fail CLOSED.
    # Only when the caller asked: _raw_tokens re-lexes the segment, so computing
    # it unconditionally made every ordinary _command_argv call ~2x slower.
    #
    # It is deliberately NOT consulted for an assignment VALUE. An earlier draft
    # did exactly that -- raw tokens carry quote provenance, so `X=$((1` (a real
    # tear) could be told from `X="("` (a paren that is data) by BALANCING
    # delimiters on the raw spelling. That scanner was reverted: it has to be
    # context-SENSITIVE where bash is, and two review rounds produced five
    # verified bypasses in it, more than the single bug it fixed. The span is
    # not rejoined at all now; a torn value merely SIGNALS that the walk may be
    # lost, and the any-position scans that follow need no span. See
    # _torn_assignment, plus its two consumers: _shell_payloads for the nested
    # route and _torn_direct_hits for the direct one.
    raw_toks = _raw_tokens(seg) if with_raw else None
    toks, raw_toks = _strip_leading_groups(toks, raw_toks)
    i = 0
    saw_wrap = False
    saw_env = False
    saw_operand_wrap = False
    opts_done = False
    prev_dash = False
    case_state = None
    while i < len(toks):
        t = toks[i]
        base = t.rsplit('/', 1)[-1]
        is_target = _is_target_word(base, targets)
        # Covers the APPEND (`A+=1`) and INDEXED (`A[0]=1`, `A[0]+=1`) forms as well
        # as plain `A=1`. Bash runs `A+=1 git commit` and `A[0]+=1 git commit` exactly
        # like `A=1 git commit`; with the old `^\w+=` the assignment stayed in argv,
        # argv[0] was not the target executable, and the whole command went undetected
        # — a fail-OPEN in every gate sharing this detector (pre-commit, pre-pr,
        # pre-merge). Found via #505.
        if _ASSIGN_TOK_RE.match(t):
            # ONE token, and that is the whole of it. A VALUE can tear across
            # tokens -- shlex splits at whitespace with no idea a substitution is
            # open, so `X=$((1 + 2)) bash -c "rm -rf /etc"` arrives as `X=$((1` /
            # `+` / `2))` / `bash` / ... and advancing by one leaves `+` in the
            # command slot, where the walk breaks. This branch does NOT try to
            # rejoin that span: an earlier draft consumed it by BALANCING
            # delimiters on the raw token, and that scanner was reverted after
            # producing five verified bypasses of its own (see the raw_toks note
            # above). The tear is handled downstream instead -- `_torn_assignment`
            # notices the walk may be lost, and two scans that need no span at
            # all pick it up: `_shell_payloads` for a payload an interpreter runs,
            # `_torn_direct_hits` for a `git`/`gh` the walk lost outright (#593).
            i += 1
            prev_dash = False
        elif t == '!':
            # pipeline negation — the command still runs
            i += 1
            prev_dash = False
        elif _is_case_label(t, is_target, toks, i, case_state):
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
            if _skips_declared_name(toks, i, base, targets):
                i += 1
        elif case_state and not is_target:
            case_state = _next_case_state(case_state, base, t)
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
            # Strip it and re-examine the SAME position — see _strip_group_punct.
            toks, raw_toks = _strip_group_punct(toks, raw_toks, i)
            prev_dash = False
        elif _REDIR_RE.match(t):
            # redirection prefix (>, >>, 2>, &>, N<, >file, 2>/dev/null, ...)
            i += _redirection_span(t, toks, i)
            prev_dash = False
        elif (saw_wrap and prev_dash and not is_target
                and (t == '--' or not t.startswith('-'))):
            # BEFORE the wrapper branch: this token is the ARGUMENT of the
            # preceding wrapper option, whatever it is named. Letting the
            # wrapper branch claim it first cleared `saw_env`, so
            # `env -u command A-B=1 git commit` read `A-B=1` as argv[0] and the
            # git commit behind it never reached the gate (verified: it runs).
            # `not is_target` still protects the executable we must never
            # swallow, so a real `git`/`gh` cannot be eaten as an option value.
            #
            # ...and an OPTION is not an option's argument, with `--` the one
            # exception. Without the exclusion, STACKED options collapsed:
            # `env -i -u FOO bash -c '<s>'` read `-u` as the value of `-i`, so
            # both readings stopped on the readable word `FOO`, the any-position
            # fallback stayed gated off, and the payload was missed -- a
            # fail-OPEN this branch INTRODUCED, since the pre-change walk
            # detected that command (verified against main).
            # `--` is exempt because it is a legitimate operand: `env -u -- -i
            # bash -c '<s>'` really does run the child (verified), and reading
            # its `--` as the option TERMINATOR instead left `-i` looking like
            # the command word and missed the payload -- the same fail-OPEN, one
            # spelling over. Reading 1 still loses `bash` to `-i` there; the
            # PROTECTED second reading is what recovers it, which is exactly the
            # union this ambiguity is handled by everywhere else in this walk.
            #
            # A wrapper-NAMED token here stays the option's argument, and
            # `ionice -c3 timeout 5 git commit` is therefore a MISS. Excluding
            # wrapper names from this branch was tried in review (PR #650) and
            # reverted: it rests on "a scoped wrapper takes options only, so
            # nothing after its dash-option can be a detached VALUE", which is
            # false -- `ionice -c 3` takes exactly that. The exclusion turned
            # `ionice -c timeout echo git commit`, where `timeout` IS `-c`'s
            # value and only `echo` runs, into a reported commit: a wrong ANSWER
            # traded for a miss. Separating the two needs ionice's option arity,
            # which is the ladder #587/#593 exist to stop climbing, so the miss
            # stays and is pinned in tests/test-gitcmd-detect.sh.
            i += 1
            prev_dash = False
        elif (base in _WRAPPERS
                or (wrapper_operands
                    and (base in _OPERAND_WRAPPERS or base in _SCOPED_WRAPPERS))):
            saw_wrap = True
            # Only env(1) itself takes `name=value` OPERANDS. Tracked separately
            # from saw_wrap so the loose assignment rule below cannot fire after
            # an unrelated wrapper: bash does NOT run `command A-B=1 bash -c
            # '<s>'` (it tries to execute `A-B=1` and exits 127, verified), so
            # treating that operand as an assignment and walking on to the child
            # payload over-warns on a command that never runs one.
            # Set unconditionally, not only on the way UP: the rule belongs to
            # the wrapper currently being parsed, so consuming a NEW wrapper as
            # env's utility must also END env's operand run. Leaving it latched
            # let `env command A-B=1 bash -c '<s>'` read `A-B=1` as an
            # assignment and walk on to the payload, although `command` exits
            # 127 there and the child never runs (verified).
            saw_env = base == 'env'
            # Latched, not reset per wrapper: the operand run belongs to the
            # OUTERMOST operand-taking wrapper still open, and `timeout 5 nice
            # -n 5 git commit` stacks a plain wrapper inside one. Clearing it on
            # the inner `nice` would put `5` back in command position, which is
            # the miss this whole change removes.
            saw_operand_wrap = saw_operand_wrap or base in _OPERAND_WRAPPERS
            # Belongs to the CURRENT (innermost) wrapper, like saw_env -- reset
            # on every new wrapper token, not latched. A `_SCOPED_WRAPPERS`
            # member opens no operand run, but it can take a detached option
            # value (`ionice -c 3`) -- keep option-argument handling
            # conservative. A nested wrapper restarts its own option parsing,
            # so a new wrapper OPENED INSIDE a scoped one (`ionice -c3 sudo
            # timeout 5 git commit`) must end the outer wrapper's option run.
            opts_done = False   # a new wrapper restarts option parsing
            i += 1
            prev_dash = False
        elif saw_wrap and not opts_done and t.startswith('-'):
            i += 1
            # `--` ENDS the wrapper's option processing, so everything after it
            # is an OPERAND. Two ways that mattered, and clearing only the first
            # left the second: the option-ARGUMENT branch above swallowed the
            # real utility (`env -- printf A-B=1 bash -c '<s>'` read `printf` as
            # `--`'s value, so argv[0] became `bash` and a payload came out of a
            # command that only PRINTS), and this branch kept reading later
            # dash-prefixed operands as options (`env -- -i bash -c '<s>'`, where
            # env tries to EXECUTE `-i` and exits 127, so nothing runs). Both are
            # false positives in three fail-CLOSED gates. Operand parsing itself
            # continues, so a `name=value` after `--` is still an assignment.
            if t == '--':
                opts_done, prev_dash = True, False
            else:
                prev_dash = True
        elif saw_env and not is_target and _ENV_ASSIGN_TOK_RE.match(t):
            # An environment assignment by env(1) rules rather than bash ones.
            # `_ASSIGN_TOK_RE` above requires a valid shell identifier, which is
            # right for a bash assignment PREFIX but too strict for a wrapper
            # operand: env(1) adds any `name=value` operand to the environment
            # and treats the FIRST operand without an `=` as the utility, with
            # no identifier rule on `name`. Bash itself exports functions under
            # names that are not identifiers -- `BASH_FUNC_mktemp%%=() { ... }`
            # -- so `env "BASH_FUNC_mktemp%%=() { echo /etc; }" bash -c '<s>'`
            # left that operand looking like the command word, argv[0] was not
            # an interpreter, and the `-c` payload was never extracted: the same
            # fail-OPEN class as the ambiguous-arity one, reached by a different
            # route. Ground truth: that command really does make `mktemp -d`
            # return /etc inside the child. Found while grinding PR #555.
            # Scoped to `saw_wrap` and guarded by `not is_target`, so a bash
            # assignment prefix keeps the stricter identifier rule and a target
            # executable can never be consumed as an assignment.
            #
            # Consumed the SAME way as a bash assignment prefix -- one token, no
            # span. An env(1) operand can carry a whitespace-bearing expansion
            # too, and `env A-B=$((1 + 2)) bash -c '<s>'` really does run the
            # child (verified), so advancing one token leaves `+` in the command
            # slot and the walk breaks there. As above, that tear is not rejoined
            # here: `_torn_assignment` matches this looser spelling as well, so
            # the fallbacks recover without one -- _shell_payloads the payload,
            # _torn_direct_hits a directly-torn `git`/`gh` (#593).
            i += 1
            prev_dash = False
        elif (wrapper_operands and saw_operand_wrap and is_target
                and i + 1 < len(toks)
                and _is_target_word(toks[i + 1].rsplit('/', 1)[-1], targets)):
            # #641, second round. A wrapper OPERAND can itself be target-SHAPED,
            # and the `not is_target` guard below then stops the walk on it:
            # `flock /tmp/git git commit -m x` returned argv
            # ['/tmp/git', 'git', 'commit', …], so argv[1] read as the subcommand
            # was `git`, not `commit`, and the commit ran unseen. `flock git git
            # commit` and `xargs -E git git commit` are the same shape (the `-E`
            # EOF-marker operand is protected from the option-argument branch by
            # its own `not is_target` guard, so it lands here too).
            #
            # NOT a regression -- main misses all of these as well, since it does
            # not know these wrappers at all -- but it is the fix's own blind
            # spot, and an operand an attacker names is a poor place to have one.
            #
            # The rule is local and needs no arity: while an operand wrapper is
            # open, a target-shaped token IMMEDIATELY FOLLOWED by another
            # target-shaped token is the operand, not the executable. It is the
            # lesson `_torn_direct_hits` records one route over -- the first
            # match is not necessarily the real one -- in the cheapest form that
            # covers this route, because a run of target-shaped tokens is exactly
            # what "operand that looks like the executable" produces.
            #
            # It cannot swallow a real command word: the token is skipped ONLY
            # when another target-shaped token follows it, and that successor is
            # then what the walk lands on. `timeout 5 git commit -m git` is
            # untouched (its second `git` does not follow the first), and outside
            # an operand wrapper nothing changes at all.
            i += 1
            prev_dash = False
        elif wrapper_operands and saw_operand_wrap and not is_target:
            # #641. Inside timeout/flock (the only `_OPERAND_WRAPPERS` members)
            # a bare word is the WRAPPER'S OPERAND -- a duration, a lockfile --
            # not the command word, so it must not end the walk. Skipping
            # forward to the target instead of counting how many operands to
            # drop is what keeps this free of an arity table: `timeout -s TERM
            # 5 git commit` resolves without the walk knowing that `-s` takes a
            # value. (`ionice` takes no bare operand at all -- see
            # `_SCOPED_WRAPPERS` -- and `xargs` is not modelled as a wrapper;
            # neither reaches `saw_operand_wrap`, so neither reaches this arm.)
            #
            # `not is_target` is the fail-CLOSED guard: the executable we are
            # hunting can never be consumed as an operand, so this branch can
            # only ever move the walk TOWARD a detection, never past one.
            #
            # When the segment holds no target at all the walk runs to the end
            # and returns [], which is the same verdict as today (the old walk
            # stopped on the operand, and argv[0] was not `git`/`gh` either) --
            # so this cannot turn a current detection into a miss.
            #
            # Accepted cost, fail-CLOSED direction: `timeout 5 echo git commit`
            # now reads as a commit. Priced at zero on a 31,381-command corpus
            # (see the PR body); the shape is rare enough not to appear at all.
            i += 1
            prev_dash = False
        else:
            break
    if with_raw:
        return toks[i:], (raw_toks[i:] if raw_toks is not None else None)
    return toks[i:]


def _reject_crlf(target, what):
    """Fail CLOSED on a CR/LF-bearing directory target.

    Every gate emits `target_dir` through a positional, newline-delimited
    protocol, so a value carrying a CR or LF SHIFTS the fields after it and lands
    a different flag on the wrong line. Both derivations of that value -- a `cd`
    argument and `git -C` -- route through here, and the gates each wrap their
    parse in `except Exception` → fail-CLOSED block, so raising blocks in ALL of
    them. Validating in one caller is the special-case that leaves the siblings
    exposed. No legitimate directory target contains a newline.
    """
    if re.search(r'[\r\n]', target):
        raise ValueError('CR/LF in %s' % what)
    return target


def _may_be_substitution(operand):
    """True iff `operand` carries a character that could OPEN a live substitution.

    Extracted from _mask_literal_substitution as a named predicate purely to reduce
    that function's branch count (CodeScene "Complex Conditional", #510); behavior
    unchanged (this is the De Morgan complement of its former early-return test)."""
    return bool(operand) and ('$' in operand or '`' in operand)


def _glob_expands(active):
    """True iff `active` holds pathname expansion bash will actually perform.

    The metacharacter alone is not the expansion. Bash leaves an UNMATCHED `[`
    literal, and `(` opens an extglob group only behind one of `?*+@!` — so
    `--message [` and `--message (` are ordinary one-word arguments, and flagging
    every occurrence blocked them. `*` and `?` need no partner and always match.
    """
    if '*' in active or '?' in active:
        return True
    # The LAST closer is found once. Searching the remainder per opening character
    # is quadratic on a word full of unmatched brackets, and this runs inside a
    # 10s budget.
    # The last closer of each kind, found ONCE. A `[` needs some `]` after it and
    # an extglob `(` needs some `)`; searching the remainder per opening character
    # is quadratic on a word of nothing but openers, inside a 10s budget.
    #
    # For brackets that IS the whole rule. Narrower ones were tried — requiring a
    # non-empty class, rejecting a reversed range — on the reasoning that `[]`,
    # `[!]` and `[z-a]` match nothing. MEASURED on bash 3.2 with `shopt -s
    # nullglob`, all three expand to ZERO words, exactly like `*` and `?`:
    #     []  argc=0     [!]  argc=0     [z-a]  argc=0
    #     [   argc=1     (    argc=1     {a..}  argc=1
    # "Matches nothing" is not "is not a glob": an unmatched pattern REMOVES its
    # word, changing the operand count as surely as an extra match would. Only a
    # `[` with no `]` after it is literal.
    last_bracket = active.rfind(']')
    last_paren = active.rfind(')')
    for i, c in enumerate(active):
        if c == '[' and last_bracket > i:
            return True
        if c == '(' and i and active[i - 1] in '?*+@!' and last_paren > i:
            return True
    return False


_INT_RE = re.compile(r'[+-]?[0-9]+')


def _is_brace_sequence(body):
    """True iff `body` is a bash brace SEQUENCE: `{1..5}`, `{a..z}`, `{1..9..2}`.

    Bash expands only integer-to-integer and single-ASCII-letter ranges, with an
    optional integer increment. `{ab..cd}`, `{1..x}`, `{1..3..x}`, `{--1..2}` and
    `{é..ê}` all stay literal — measured, argc=1 each — and accepting any `..`
    between non-empty endpoints refused every one of them.
    """
    parts = body.split('..')
    if len(parts) not in (2, 3):
        return False
    lo, hi = parts[0], parts[1]

    # ASCII, at most ONE sign: `lstrip('-+')` accepted `--1`, which bash leaves
    # literal, and `isdigit()` accepts non-ASCII digits bash does not.
    def _int(v):
        return bool(_INT_RE.fullmatch(v))

    if len(parts) == 3 and not _int(parts[2]):
        return False
    if _int(lo) and _int(hi):
        return True
    return (len(lo) == 1 and len(hi) == 1 and lo.isascii() and hi.isascii()
            and lo.isalpha() and hi.isalpha())


def _brace_expands(active):
    """True iff `active` contains a brace EXPANSION rather than literal braces.

    The rule, not a pattern: a `{...}` group expands when its OWN nesting depth
    holds a `,` or a `..`. Two flat regexes were tried and each missed the next
    nesting — `{note,{B}}` and `{{A},B}` both expand, and neither matches a
    pattern written for `{[^{}]*,[^{}]*}`. Depth-tracking ends that class instead
    of extending it, and it keeps `@{upstream}` literal, which no ref-name test
    could afford to lose.
    """
    open_at = []                       # per open brace: (index, comma?, `..` index)
    i, n = 0, len(active)
    while i < n:
        c = active[i]
        if c == '{':
            if open_at:
                open_at[-1][3] = True  # the parent now holds a nested brace
            open_at.append([i, False, None, False])
        elif c == '}':
            if open_at:
                start, comma, dots, nested = open_at.pop()
                if comma:
                    return True
                # A sequence has single-token endpoints, so a frame containing a
                # nested brace is never one. Skipping it also keeps this linear:
                # slicing and splitting every frame's body made a word like
                # `{..{..{..x}}}` quadratic inside a bounded budget.
                if nested:
                    pass               # NOT `continue`: the index advances below
                # A SEQUENCE needs valid endpoints: bash leaves `{a..}`, `{..b}`
                # and `{ab..cd}` literal, and accepting any closed group with a
                # `..` blocked them. `{,a}` by contrast really does expand, so the
                # comma form above takes no such check.
                elif dots is not None and _is_brace_sequence(active[start + 1:i]):
                    return True
        elif open_at:
            if c == ',':
                open_at[-1][1] = True
            elif c == '.' and i + 1 < n and active[i + 1] == '.':
                open_at[-1][2] = i
                i += 1
        i += 1
    return False


def _quoted_multiword(raw, i):
    """True iff the expansion at `raw[i]` yields MORE THAN ONE word even inside
    double quotes.

    The `@` forms do: `"$@"`, `"${@}"`, `"${@:2}"`, `"${arr[@]}"`. So does EVERY
    `${!...}` indirection, including the plain-looking `"${!name}"` — its target
    is chosen at run time, and `name='arr[@]'` makes it an array expansion. The
    gate cannot see that value, so it does not guess: `"$*"` joins on IFS and
    scalar forms are one word, but an indirection is treated as plural.

    `[@]` counts ONLY as the parameter's own subscript. A pattern that looked for
    it anywhere flagged `"${MSG:-note[@]}"`, which is one word whatever MSG holds.

    Indexed rather than sliced: this runs at every `$` inside a quoted token, and
    slicing the remainder each time made a token full of dollar signs quadratic —
    a 64 KiB word is bounded, but copying it thousands of times is not free, and
    the gate has a 10s budget to answer in.
    """
    n = len(raw)
    if raw.startswith('$@', i):
        return True
    if not raw.startswith('${', i):
        return False
    j = i + 2
    # `${!}` is the braced spelling of `$!`, the last background PID — a special
    # parameter, not an indirection, and always one word.
    if raw.startswith('${!}', i):
        return False
    if j < n and raw[j] == '!':
        # `${!P*}` and `${!arr[*]}` join on IFS inside double quotes — one word,
        # like `"$*"`. Every other indirection is plural or picks its target at
        # run time (`name='arr[@]'` makes `"${!name}"` an array), so it is not.
        j += 1
        # `${!#}` indirects through `$#`, a count — always exactly one positional
        # parameter, so one word.
        if raw.startswith('#}', j):
            return False
        name = j
        while j < n and (raw[j].isalnum() or raw[j] == '_'):
            j += 1
        if j > name and (raw.startswith('[*]', j) or raw.startswith('*}', j)):
            return False
        return True
    if j < n and raw[j] == '@':
        return True                    # ${@}, ${@:2}
    name = j
    while j < n and (raw[j].isalnum() or raw[j] == '_'):
        j += 1
    return j > name and raw.startswith('[@]', j)   # ${arr[@]}


# Stands in for material bash will NOT expand — a quoted run, or an escaped
# character — so that what surrounded it does not become adjacent. Deleting it
# outright turned the literal `{a."".b}` into `{a..b}` and reported a sequence.
# Any character outside every grammar this module inspects will do.
_INERT = '\x01'


def _active_spelling(raw):
    """(active, splits_inside_quotes, command_substitution) for a RAW spelling.

    `active` is the part bash will still expand: unquoted and unescaped. Neither
    "raw == token" nor _quoted_literal answers that. The first calls a PARTIALLY
    quoted word safe — `{--ff-only,--no-edit}""` differs from its token while bash
    expands the bare braces in front of the empty quotes. The second calls
    anything short of one enclosing pair unsafe, which flags the ordinary
    `--message "*"` and `--message \\*`.

    `splits_inside_quotes` is the exception to "quoted means one word" — see
    _quoted_multiword.

    `$'...'` and `$"..."` are QUOTE OPENERS, not substitutions; reading their `$`
    as active flagged the perfectly ordinary `--message $'note'`.

    `command_substitution` is `$(...)` or a backtick reached OUTSIDE single quotes,
    where bash runs it — `'$(echo note)'` is a literal message and must not be
    confused with one.

    `None` raw (stream unavailable or unaligned -- see _raw_tokens) yields
    (None, False, False), and callers read that as "assume active", the
    fail-CLOSED direction.
    """
    if raw is None:
        return None, False, False
    out = []
    multi = False
    cmdsub = False
    i, n, quote = 0, len(raw), None
    while i < n:
        c = raw[i]
        # Inside ordinary single quotes a backslash is literal; everywhere else —
        # unquoted, double-quoted, and inside $'...' — it escapes the next
        # character. Treating $'...' as plain single quoting closed it at the
        # ESCAPED quote in `$'a\\''$MODE`, then opened a fictitious quote at the
        # real one, hiding an unquoted $MODE behind what looked like a quoted tail.
        if quote != "'" and c == '\\':
            if quote is None:
                out.append(_INERT)
            i += 2
            continue
        if quote is None and c == '$' and i + 1 < n and raw[i + 1] in '\'"':
            # $'...' is ANSI-C quoting, its own state. $"..." is locale
            # translation, which then behaves exactly like double quotes — so it
            # keeps the double-quote state, expansions and all.
            quote = "$'" if raw[i + 1] == "'" else '"'
            i += 2
            continue
        if quote is None and c in '\'"':
            quote = c
            i += 1
            continue
        if quote is not None and c == quote[-1]:
            quote = None
            out.append(_INERT)
            i += 1
            continue
        # BOTH single-quote states: bash runs no substitution inside `'...'` or
        # inside `$'...'` either, so `$'`x`'` is a literal message.
        if quote not in ("'", "$'"):
            # `$((1+2))` is arithmetic expansion: one word, and it runs nothing.
            # Matching the `$(` prefix refused it along with the real thing.
            if raw.startswith('$((', i):
                # Arithmetic: one numeric word, and it runs nothing. Masked out
                # entirely — leaving its `$` in `active` made the generic
                # substitution branch call the unquoted `$((1+2))` a split.
                # Parentheses inside a nested parameter expansion are TEXT:
                # `$((${X:-"("}))` opens nothing and `${Y:+")"}` closes nothing.
                # Counting raw characters let a quoted `)` satisfy an outstanding
                # depth and skip past the real end of the expansion, swallowing a
                # trailing unquoted `$MSG` with it. Only unquoted parens count.
                depth, k, q2 = 0, i + 1, None
                while k < n:
                    ck = raw[k]
                    if q2 != "'" and ck == '\\':
                        k += 2
                        continue
                    if q2 is None and ck in '\'"':
                        q2 = ck
                    elif q2 is not None and ck == q2:
                        q2 = None
                    elif q2 is None:
                        if ck == '(':
                            depth += 1
                        elif ck == ')':
                            depth -= 1
                            if depth == 0:
                                break
                    k += 1
                if k >= n:
                    # Never balanced. Parentheses inside a nested parameter
                    # expansion — `$((${X:-"("}))` — are text, not arithmetic
                    # syntax, so the count can run past the end; skipping to it
                    # swallowed a trailing unquoted `$MSG` with it. Unreadable is
                    # not one word.
                    cmdsub = True
                    break
                # QUOTED arithmetic is one word; UNQUOTED is not. Its result is
                # a field like any other and undergoes IFS splitting, so with
                # `IFS=1` the innocuous `$((212))` becomes the two words `2` and
                # `2` — a second merge head. Masking both alike made the unquoted
                # form look inert. `$` here re-enters the splitting branch below;
                # inside quotes nothing is emitted, which is the one-word answer.
                if quote is None:
                    out.append('$')
                i = k + 1
                continue
            if c == '`' or (c == '$' and raw.startswith('$(', i)):
                cmdsub = True
        if quote == '"' and c == '$' and _quoted_multiword(raw, i):
            multi = True
        if quote is None:
            out.append(c)
        i += 1
    return ''.join(out), multi, cmdsub


def _word_may_split(token, raw=None):
    """True iff `token` could expand into a different NUMBER of words.

    Every operand of a merge is a head, so a token the parser discards — or reads
    as ONE operand — must be one word, or the operand COUNT it thought it saw is
    wrong, and a marker minted for the head it saw authorizes the commit it did
    not. All of these produce extra heads with `MSG='note B'`, a matching
    directory entry, or two positional parameters: `--message $MSG`,
    `--message=$MSG`, `--message {note,B}`, `--message {A..B}`, `--message *`,
    `--message @(x)` under extglob, and `--message "$@"`.

    This is a WORD-COUNT question, not the value question `_may_be_substitution`
    answers, and the two differ on quoting. `"$MSG"` hides its value but is always
    one word; `{a,b}` splits while carrying no substitution character at all. So
    an operand needs both tests and a discarded option token needs only this one.
    """
    # A COMMAND SUBSTITUTION ends the analysis, wherever it sits. Its body is a
    # complete shell command, quotes included, so a scanner with one quote state
    # cannot find where it ends: in
    # `--message="$(x='"')"$MSG"$(y='"')"` the inner quotes close the outer one and
    # the scanner reads the trailing `$MSG` as quoted, reporting a one-word value
    # for a word bash expands into several. Tracking nested substitution contexts
    # would mean writing a bash parser here; refusing the construct costs a merge
    # option nobody spells this way.
    active, multi, cmdsub = _active_spelling(raw)
    if multi or cmdsub:
        return True
    if active is None:
        active = token or ''
    if not active:
        return False
    if '$' in active or '`' in active:
        return True                    # unquoted: splits on IFS
    return _brace_expands(active) or _glob_expands(active)


def _spelled_live(operand, raw_spelling):
    """True iff `raw_spelling` is a spelling bash actually RUNS the substitution for
    -- the bare operand, or its exactly-double-quoted form.

    Extracted from _mask_literal_substitution as a named predicate purely to reduce
    that function's branch count (#510); behavior unchanged. Every literal spelling
    (single quotes, adjacent-quote concatenation, backslash escapes) differs from
    both, and an unavailable spelling (None) proves nothing -- fail CLOSED."""
    return (raw_spelling is not None
            and raw_spelling in (operand, '"' + operand + '"'))


def _mask_literal_substitution(operand, raw_spelling):
    """Re-quote an operand that was SINGLE-quoted in `seg`, so a LITERAL path is
    never mistaken downstream for a live command substitution.

    Tokenization discards quoting, so `cd "$(git rev-parse --show-toplevel)"` (the
    substitution RUNS, yielding the cwd's own repo root -- the idiom
    gate_classify_target recognises and exempts) and `cd '$(git rev-parse
    --show-toplevel)'` (bash enters a LITERAL directory of that name, which may be a
    symlink into another repo) arrive downstream as the SAME string. Only the first
    may be treated as the idiom. Restoring the quotes makes the second fail the
    anchored idiom regex and fall to the '$'-is-unresolvable arm, i.e. BLOCK.

    Two shapes were tried and rejected before this one:

    * A filesystem check for whether the literal directory exists. The gated command
      can create it itself (`ln -s /other '$(...)'; git -C '$(...)' commit`), so it
      scoped the gate by state the gated party controls.
    * A substring search for "'<operand>'" in the raw text. It recognised exactly one
      spelling, and shell has many: `'$('"'"'git rev-parse --show-toplevel)'` and
      `\\$\\(git\\ rev-parse\\ --show-toplevel\\)` both tokenize to the bare idiom
      while containing no such substring. Enumerating quotings is the whack-a-mole
      the loose-cd parser already learned to avoid.

    Instead ask the tokenizer. shlex(posix=False) preserves each token's ORIGINAL
    spelling, so the operand is a live substitution only if it appears there either
    double-quoted as one token, or unquoted as a contiguous run of plain tokens.
    Every literal spelling -- single quotes, adjacent-quote concatenation, backslash
    escapes -- fails both tests, because posix=False keeps the very characters that
    made it a literal. Fail-CLOSED: unbalanced quoting cannot be tokenized at all, so
    it too is treated as not-live."""
    if not _may_be_substitution(operand):
        return operand
    # `raw_spelling` is the ORIGINAL text of THIS argument. Bash runs the
    # substitution only for the bare or exactly-double-quoted spelling; every literal
    # spelling (single quotes, adjacent-quote concatenation, backslash escapes)
    # differs from both, and an unavailable spelling proves nothing. Fail CLOSED.
    if _spelled_live(operand, raw_spelling):
        return operand
    return "'" + operand + "'"


def _raw_tokens(seg):
    """Original per-token spellings, aligned 1:1 with `_tokenize(seg)`, or None when
    they cannot be aligned.

    shlex(posix=False) keeps the characters that made a token a literal, which is the
    only reliable way to tell `"$(...)"` (bash runs it) from `'$(...)'` (a literal
    directory of that name) after posix tokenization has erased the difference. A
    differing token count means adjacent-quote concatenation or escaping restructured
    the segment, so positions no longer correspond -- callers must fail CLOSED."""
    try:
        raw = shlex.split(seg, posix=False)
    except ValueError:
        return None
    return raw if len(raw) == len(_tokenize(seg)) else None


def _cd_target(seg):
    """If seg is `cd <dir>`, return the quote-stripped, ~-expanded target; else
    None. The raw segment (not the tokenized form) is used so command-
    substitution idioms like cd "$(git rev-parse --show-toplevel)" survive for
    the downstream repo resolver.

    Raises ValueError when the target carries a CR or LF.

    Both halves are load-bearing. Without DOTALL, `(.*)` stopped at the first
    newline, so `cd "/safe<LF>other" && gh pr merge 31` produced the TRUNCATED
    target `/safe`: the gate then resolved markers against `/safe` while bash ran
    the merge from the distinct `/safe<LF>other` repo. But merely capturing the
    rest is worse on its own — every gate prints `target_dir` through a positional,
    newline-delimited protocol, so a CR/LF-bearing value SHIFTS the fields after it
    and lands a different flag on the wrong line.

    Rejecting here, in the shared detector, is what makes that safe for all of
    them at once: pre-commit, pre-pr and pre-merge each wrap their parse in
    `except Exception` → fail-CLOSED block, so this raise blocks in every gate
    rather than only the one that remembered to check. (Validating in a single
    caller is the special-case that leaves its siblings exposed.) No legitimate
    target contains a newline, so no valid input reaches this path."""
    m = re.match(r'cd\s+(.*)', seg.lstrip('({ \t'), re.S)
    if not m:
        return None
    # Validate CR/LF on the RAW captured group, before any whitespace
    # normalization. str.strip() treats \r as whitespace and silently
    # removes a trailing CR, which would make _reject_crlf() see a clean
    # value even though bash still executes `cd /repo<CR>` against a
    # DIFFERENT (CR-suffixed) directory than the one the gate just
    # approved the marker for. Checking pre-strip closes that gap.
    raw = m.group(1)
    _reject_crlf(raw, 'cd target')
    raw_arg = raw.strip()
    return _mask_literal_substitution(
        os.path.expanduser(raw_arg.strip('\047\042')), raw_arg)


# Builtins whose ANSI-C spelling (`$'cd'` -> `$cd`) must still be recognised as
# the command word. Deliberately NOT `git`/`gh`: those are external executables
# reached through wrappers, and treating a wrapper ARGUMENT named `$git` as the
# protected target stopped it being consumed -- `env -u $git git commit` then
# started argv at `$git`, matched no executable, and went UNDETECTED (fail-OPEN).
_ANSIC_BUILTINS = ('cd', 'pushd', 'popd')

_CD_LEAD_WORDS = ('if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', 'time')

# The directory-stack builtins. Unlike `cd` they accept `-n` (change the stack
# without changing the directory), and `popd`'s destination is a stack entry.
_CD_STACK_BUILTINS = ('pushd', 'popd')


def _raw_spelling(raw_argv, idx):
    """The ORIGINAL spelling of `argv[idx]`, or None when the raw stream is
    unavailable or too short -- callers then fail CLOSED (see _raw_tokens).

    raw_argv is aligned with argv by construction, so this is THIS operand's own
    spelling. Position matters: a segment-wide search was satisfied by a decoy copy
    elsewhere (a comment, another argument) while the real operand stayed quoted --
    and an offset into the argv could not survive the token deletions _command_argv
    performs.

    Extracted from _cd_target_loose and _scan_commit -- which carried identical
    inline copies -- purely to reduce their branch counts (#510); behavior
    unchanged."""
    if raw_argv is None or idx >= len(raw_argv):
        return None
    return raw_argv[idx]


def _is_cd_option(a, opts_done):
    """True iff argv word `a` is an OPTION of a cd/pushd/popd invocation rather than
    its operand: before any `--`, dash-prefixed, and not the bare `-` (which IS the
    OLDPWD operand).

    Extracted from _cd_target_loose as a named predicate purely to reduce its branch
    count (CodeScene "Complex Conditional", #510); behavior unchanged."""
    return not opts_done and a.startswith('-') and len(a) > 1 and a != '-'


def _cd_operand_index(argv, cmd0):
    """(index of the first OPERAND in `argv`, no_chdir) for a cd/pushd/popd argv; the
    index is None when there is no operand at all.

    `-n` suppresses the directory change for BOTH stack builtins (`pushd -n /other`
    only pushes onto the stack; `popd -n` only drops an entry), so recording them
    would block a commit whose cwd never moved. It counts ONLY in option position: a
    scan of the whole argv also matched it as an OPERAND or a redirection target
    (`pushd -- -n`, `pushd /other > -n`) and reported "no cd" while the shell really
    moved -- fail-OPEN. So this walk stops treating tokens as options at `--` or at
    the first operand, and `-n` is honoured only before that point. `cd` has no `-n`,
    hence the cmd0 guard.

    Split out of _cd_target_loose purely to reduce its complexity (CodeScene "Complex
    Method" / "Bumpy Road Ahead", #510); behavior unchanged."""
    no_chdir = False
    opts_done = False
    for j, a in enumerate(argv[1:], start=1):
        if not opts_done and a == '--':
            opts_done = True
            continue
        if _is_cd_option(a, opts_done):
            if a == '-n' and cmd0 in _CD_STACK_BUILTINS:
                no_chdir = True
            continue            # cd options (-L/-P/-e/-@); '-' IS the OLDPWD operand
        return j, no_chdir
    return None, no_chdir


def _loose_cd_destination(cmd0, operand, raw_spelling):
    """The recorded destination for `cmd0`'s first operand, or AMBIGUOUS_CD when it
    is not statically knowable.

    Split out of _cd_target_loose purely to reduce its complexity (#510); behavior
    unchanged."""
    if cmd0 == 'popd':
        return AMBIGUOUS_CD   # destination is a stack entry, not this operand
    if operand.startswith('~'):
        # `cd ~` expands to $HOME but `cd "~"` / `cd \~` is a LITERAL directory
        # named '~'. Tokenization has already discarded which one this was, so
        # the destination is genuinely unknown -> fail CLOSED rather than guess
        # (the strict detector's expanduser only feeds the pre-existing trusted
        # path and is left alone).
        return AMBIGUOUS_CD
    return _mask_literal_substitution(operand, raw_spelling)


def _cd_target_loose(seg):
    """The operand of a `cd` that changes the CURRENT shell's directory, else None.

    Delegates command-word resolution to _command_argv — the SAME tokenizer that
    finds `git`/`gh` — so it inherits, rather than re-implements, that function's
    handling of env assignments, `builtin`/`command`/`time` wrappers and their
    options, `--` end-of-options, leading redirections, reserved words
    (`if cd /x; then …`), `case` branch labels, and quoted command words. An earlier
    hand-rolled prefix-stripper here leaked a new shape on every review round; this
    has one source of truth.

    Used ONLY to accumulate operands for the untrusted channel, never for
    _trusted_cd: a keyword- or case-guarded cd may be CONDITIONAL, so it must never
    be TRUSTED as the repo scope — but it may well have RUN, so it must be SEEN.
    The strict _cd_target is untouched, so the trusted path is byte-identical.

    A `cd` with no usable operand (bare `cd`, `cd --`) goes to $HOME, a destination
    this parser cannot know, so it reports AMBIGUOUS_CD and the caller fails CLOSED.

    `pushd`/`popd` ARE recognised (see below) — they move the current shell just as
    `cd` does.

    RESIDUAL, deliberately — a DYNAMIC command word. `cmd=cd; $cmd /other-repo` really
    does change the directory, and no static parser can know what `$cmd` holds. Closing
    it means treating EVERY `$VAR <operand>` as a possible cd, which blocks the ordinary
    `$EDITOR file; git commit` and `$PYTHON x.py; git commit` — an unacceptable
    false-block rate to buy an exotic bypass. Behaviour here is identical to the
    pre-`untrusted_cd` parser (verified against origin/main), so this is a gap the
    channel does not close, not one it opens. Pinned by a test so the decision is
    explicit rather than accidental.

    Also RESIDUAL: forms only an executing shell can see — a `cd` inside a FUNCTION
    body invoked later, `(cd x)` subshells — and DECODED
    obfuscation of the command word, e.g. `$'\\x63\\x64' /other` or `$'c\\144'`.
    The literal `$'cd'` spelling is caught above; decoding arbitrary ANSI-C escapes
    (and variable indirection behind them) is the same "truly exotic obfuscation"
    that ADR 0024 already places out of scope for the merge gate's override
    detection, and it is the boundary gate_classify_target states as well: close the
    common and accidental skips, do not reimplement a shell. None of these shapes is
    more exposed than before this function existed — each one already defeated the
    strict detector that has always fed the trusted path.
    """
    argv, raw_argv = _command_argv(seg, ('cd', 'pushd', 'popd'), with_raw=True)
    # `$'cd'` (ANSI-C quoting) survives tokenization as `$cd`; bash still runs the
    # builtin. Strip ONE leading '$' so that spelling is seen, while a genuine
    # variable command word (`$cmd`) still does not match.
    if not argv:
        return None
    cmd0 = argv[0].lstrip('$')
    # `pushd DIR` changes the CURRENT shell's directory exactly like `cd DIR`, and
    # `popd` returns to a stack entry this parser cannot know. Both reported '' --
    # the same value as "no cd at all" -- so `pushd /other-repo; git commit` landed
    # the commit in /other-repo while the gate validated the SESSION repo's marker.
    # They are recorded here (seen, never trusted) like every other loose cd; popd
    # and a bare pushd (which SWAPS the top two stack entries) have no statically
    # knowable destination, so they report AMBIGUOUS_CD and the caller fails CLOSED.
    if cmd0 not in ('cd',) + _CD_STACK_BUILTINS:
        return None
    j, no_chdir = _cd_operand_index(argv, cmd0)
    # `-n` means nothing moved -- with or without an operand.
    if no_chdir:
        return None
    # No operand: bare `cd` goes to $HOME, bare `pushd` SWAPS the top two stack
    # entries, bare `popd` pops one -- none of them statically knowable.
    if j is None:
        return AMBIGUOUS_CD
    # Decided here, where `-n` has been seen if and only if it was a real option.
    return _loose_cd_destination(cmd0, argv[j], _raw_spelling(raw_argv, j))


def _trusted_cd(pending_cd, op):
    """A pending cd is the repo scope ONLY if it was the segment immediately
    before this command AND joined by '&&' (so it ran and its success gated the
    command). Behind any other operator, or after an intervening command, the cd
    may not have executed (e.g. `false && cd /x; git commit`) — fall back to ''
    (process CWD) rather than trust a marker in the wrong repository."""
    return pending_cd if (pending_cd is not None and op == '&&') else ''


AMBIGUOUS_CD = '-ambiguous-cd-operands'

# Operators under which a `cd` segment is guaranteed to be REACHED. Bash groups
# '&&'/'||' left-to-right at equal precedence, so in `A || cd /x && commit` the shell
# runs (A || cd) && commit -- the commit can execute with the cd SKIPPED. An adjacent
# '&&' is therefore proof only when the cd was itself unconditional or '&&'-gated.
_CD_REACHED_OPS = ('', ';', '&&')


def _cd_authoritative(target_dir, pending_cd_op, cds):
    """True iff `target_dir` fixes the repo on its own, so an unconfirmed cd need not
    be reported alongside it.

    All three conjuncts are load-bearing. The target must be ABSOLUTE -- `cd /other;
    cd sub && commit` runs in /other/sub, and a RELATIVE target is resolved by
    git/bash against the RUNTIME cwd but by the gate against the payload cwd, so the
    two would silently disagree. The cd must have been REACHED (_CD_REACHED_OPS), so
    an adjacent '&&' really is proof it ran. And the strict regex's value must AGREE
    with the TOKENIZED operand: `cd "~" && commit` enters a LITERAL '~' dir though the
    regex expands it to $HOME, and `cd /other >/dev/null && commit` leaves the
    redirection inside the raw value. In each mismatch the raw value is the
    untrustworthy one.

    Extracted from _iter_gh and _scan_commit -- which spelled the same predicate two
    different ways -- purely to reduce their branch counts (CodeScene "Complex
    Conditional", #510). Behavior is unchanged in both: _scan_commit's former
    `trusted_cd = base if pending_cd_op in _CD_REACHED_OPS else ''` followed by
    `trusted_cd.startswith('/')` is exactly this conjunction, since '' is never
    absolute."""
    return (target_dir.startswith('/') and pending_cd_op in _CD_REACHED_OPS
            and bool(cds) and cds[-1] == target_dir)


def _record_cds(seg, cds):
    """Append `seg`'s LOOSE cd operand to `cds` (the untrusted channel) and return its
    STRICT cd target, or None when `seg` is not a plain `cd`.

    The untrusted channel always records the TOKENIZED operand: the strict regex keeps
    everything after `cd `, so `cd /x >/dev/null` would otherwise be compared as the
    literal path `/x >/dev/null` -- a string an attacker can create as a symlink into
    the session repo while bash strips the redirection and moves somewhere else
    entirely. The strict form alone feeds the TRUSTED path.

    Extracted from _scan_commit and _iter_gh -- which carried identical copies -- purely
    to reduce their branch counts (CodeScene "Complex Method", #510); behavior
    unchanged in both."""
    loose_cd = _cd_target_loose(seg)
    if loose_cd is not None:
        cds.append(loose_cd)      # seen but never trusted -- _cd_target_loose
    return _cd_target(seg)


def _untrusted_cd(cds):
    """The cd destination that may be in effect when the command runs, else ''.

    Reported OUT OF BAND — deliberately NOT folded into target_dir. target_dir is
    a PATH field, so encoding "unconfirmed" into it via a sentinel prefix is
    in-band signalling: a real directory can be named to imitate the sentinel, and
    since any target containing '$' is classified unresolvable (→ BLOCK),
    overloading the field silently DOWNGRADED `cd '$untrusted-cd:x' && git commit`
    from block to proceed. A separate field cannot be forged by a path.

    Why callers need it at all: '' alone conflates "no cd" with "a cd whose
    execution I could not confirm", and both readings are wrong in a reachable
    case —

      * trust it  -> `false && cd /x; git commit` runs in the ORIGINAL cwd while
                     the gate would check /x's markers.
      * ignore it -> `cd /x`<newline>`git commit` — the cd succeeds, which is the
                     common shape — runs in /x while the gate checks cwd. Marker
                     existence is the sole check, and both the marker and the skip
                     file are $REPO_DIR-scoped, so a fresh marker or a live
                     skip-*.local in the SESSION repo authorizes an UNREVIEWED
                     commit in /x. A gate bypass, not a mis-addressed message.

    So the operand is surfaced verbatim and each MARKER-SCOPED gate decides: it
    proceeds only when the cd provably cannot leave the cwd repo, and blocks
    otherwise. Non-gating consumers keep unpacking 3-tuples and see no change.

    ADJACENCY IS THE WRONG RULE HERE. _trusted_cd requires the cd to be the
    IMMEDIATELY preceding segment, because only then does '&&' prove it ran. The
    untrusted channel asks the opposite question — "might the cwd have moved?" — and
    an intervening command does NOT undo a cd, so `cd /other; :; git commit` still
    runs in /other. Callers therefore pass EVERY cd operand seen before the command.

    Nor is the operator a shortcut: in `cd /other; : && git commit` the '&&' joins
    the NO-OP to the commit and says nothing about the cd, so keying off `op` here
    would wrongly report "no cd". Suppression is decided by the caller instead, and
    only for an ABSOLUTE resolved target — which fixes the repo by itself.

    AND THE LAST cd IS NOT NECESSARILY THE ONE THAT RAN. Conditionals break lexical
    order: in `cd /other || cd /session; git commit` the second cd executes only if
    the first FAILED, so the command may run in either. When the operands are not
    all identical we cannot say which took effect, so we return AMBIGUOUS_CD — a
    leading-dash token that gate_classify_target rules unresolvable, making the
    resolver fail CLOSED. It is never a valid absolute path, so it cannot be
    mistaken for one."""
    if not cds:
        return ''
    return cds[-1] if len(set(cds)) == 1 else AMBIGUOUS_CD


def _all_cds(chunk):
    """Every `cd` operand in `chunk`, in order — keyword-prefixed ones included
    (_cd_target_loose), since this feeds the untrusted channel only."""
    return [c for _op, seg in split_segments(chunk)
            for c in (_cd_target_loose(seg),) if c is not None]


def _nested_cds(chunks):
    """The cd operands that can be in effect for a match found INSIDE a nested chunk
    (`bash -c '...'`, `$(...)`).

    ORDER IS DELIBERATELY NOT MODELLED HERE. Inside the main chunk, segments are a
    flat ordered list, so the scanner can say exactly which cds precede the command.
    Across interpreter payloads it cannot: locating the payload inside its parent by
    substring picks inert text just as happily as the segment that runs it
    (`echo 'git commit'; cd /x; bash -c 'git commit'`), and payloads nest
    arbitrarily deep. Ordering them faithfully means reimplementing the shell, which
    this module deliberately does not do.

    So we take EVERY cd in the whole command and let the caller's "all operands
    identical" rule decide. That is order-INDEPENDENT and therefore sound: if every
    cd names the same directory, the command runs there whichever ones executed and
    in whatever order; if they differ, the destination is genuinely unknown and the
    caller fails CLOSED.

    The accepted cost is a false block on a nested command whose only cd runs AFTER
    it (`bash -c 'git commit; cd /other'`). That is the fail-CLOSED direction, the
    shape is rare, and `&&` or `git -C` clears it.

    A `-C` inside a payload (`bash -c 'git -C /other commit'`) is still not honoured
    for SCOPING — the walk resolves targets only under allow_cd, and teaching it to
    resolve them inside payloads would change how nested operations are scoped, a
    wider change than this fix. But silence there was NOT the fail-CLOSED direction it
    was once described as: an unresolved nested `-C` returned the same ('', '') as "no
    cd at all", so the gate anchored on the session cwd while git committed in the -C
    target. _scan_commit now raises a '-nested-c-operand' token for it, so the case
    BLOCKS instead of proceeding; `cd /repo && git commit` clears it."""
    return [c for chunk in chunks for c in _all_cds(chunk)]


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
    Split out of _command_substitutions purely to reduce its branch count.

    `$((` is DELIBERATELY read as a substitution opener too, though it is usually
    arithmetic. The two are genuinely ambiguous in this position: `$( (cmd) )` is a
    command substitution wrapping a subshell and is spelled `$((cmd))` when written
    without the space, so a rule that skipped every `$((` would stop scanning a
    real command body. Counting arithmetic as a substitution only ever OVER-counts,
    and this module's standing tradeoff applies -- an over-count BLOCKS, an
    under-count is a bypass. The visible cost is that arithmetic inside a merge
    option value reads as a companion command and is refused; `--message` has no
    effect on a fast-forward in the first place, so nothing real is lost.
    """
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
            if (_ASSIGN_TOK_RE.match(t) or t.startswith('-')   # append/indexed forms
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


def _norm_cmd_word(tok):
    """The command word reduced to a basename, with a leading `$` dropped."""
    return tok.lstrip('$').rsplit('/', 1)[-1]


def _interpreter_name(tok):
    """The interpreter this token may name, or None. Canonical, never the token.

    Canonical because the caller puts the result in argv[0] and the payload
    reader re-tests membership literally, so the token's own spelling would fail
    the very test that selected it.

    THREE ways to qualify, and the third is the one that terminates:

      bash                 named outright
      /bin/ba?h            a GLOB reaching the real binary - the literal names
                           are matched against the token read as a pattern
      b$'a'sh, $'ba\\u0073h'  UNREADABLE - shlex hands back `b$ash` and
                           `$ba\\u0073h`, and bash runs both as bash

    The third case is deliberately NOT decoded. Decoding means enumerating how a
    name can be spelled - `$'...'` concatenation, `\\x`, `\\0`, `\\u`, `\\U`, the
    next one after that - which is the ladder this file exists to stop climbing.
    So a command word this scan cannot READ is treated as possibly-an-interpreter
    instead, the same inversion careful-guard applies at command position: an
    unreadable command word is refused rather than guessed.

    The stand-in name is `sh` because _interpreter_payloads is shell-AGNOSTIC -
    it returns the whole tail after the first `c`-cluster precisely so it never
    has to model per-shell option arity - so which shell it is does not change
    what gets scanned.
    """
    name = _norm_cmd_word(tok)
    if name in _INTERPRETERS:
        return name
    if any(ch in name for ch in '*?['):
        for i in _INTERPRETERS:
            if fnmatch.fnmatchcase(i, name):
                return i
        # fnmatch is not bash: it has no POSIX bracket CLASSES, so
        # `/bin/ba[[:alpha:]]h` expands to /bin/bash for the shell and to
        # nothing here. Teaching it the class grammar is the ladder one more
        # time, so an unresolved GLOB is refused exactly like an unreadable
        # word - it might name a shell, and this scan cannot say it does not.
        return 'sh'
    if _unreadable_word(tok):
        return 'sh'                     # unreadable - refuse, do not decode
    return None


def _unreadable_word(tok):
    """True iff this command word cannot be resolved statically.

    Brace expansion belongs here with the substitutions and globs: bash expands
    `ba{s..s}h` to `bash` and runs it (verified), and no reading of the literal
    token says so. Left out of the first cut, which is exactly the shape the
    refusal exists to cover -- a name this scan cannot READ is refused, not
    guessed. Deciding whether a brace really expands (a `,` or `..` inside, and
    unquoted -- provenance shlex has already dropped) is the grammar this file
    stopped enumerating, so PRESENCE of a brace is enough.

    Parens are here for extglob, whose `+(`/`@(`/`!(` prefixes carry neither `*`
    nor `?`: with the option set, `/bin/@(ba)sh` expands to /bin/bash and runs
    (verified under `bash -O extglob`). Listing the five prefixes would be the
    ladder again -- and whether extglob is even ENABLED is runtime state this
    scan cannot see -- so the paren itself is the signal.

    OPENERS only, which is why `]` was never in this set either. A lone CLOSER
    is what a tear LEAVES: shlex splits `X=${foo:-a b}` into `X=${foo:-a` / `b}`
    and `X=$(printf x y)` into `X=$(printf` / `x` / `y)`, so reading `b}`/`y)`
    as unreadable command words made the debris its own stand-in shell and any
    later `-c` its option -- `X=$(printf x y) echo -c 'git commit'` then blocked
    a commit bash never runs. An expansion that really names a command carries
    its opener; debris carries only the tail.
    """
    return '$' in tok or '`' in tok or any(c in tok for c in '*?[{(')


def _torn_assignment(toks, upto=None):
    """True iff a token read as an assignment opens something it does not close.

    ONE token, no span. `X=$(printf` carries an opener with no closer, so the
    walk that consumed it as a complete assignment cannot have found the real
    command word - whatever it landed on next is debris. Deliberately blind to
    WHERE the value ends: computing that is the delimiter grammar this file
    stopped enumerating, and the answer here only decides whether to look again.

    `upto` bounds the scan to the PREFIX the walk actually crossed. Scanning the
    whole segment read ARGUMENTS as assignments, so
    `printf '%s\n' 'X=$(x)' bash -c 'git commit'` tripped the fallback and the
    gate blocked a commit that printf only PRINTS (verified: it prints). Over-
    firing is the safe direction for an advisory warning but NOT here - these
    payloads also feed three fail-CLOSED gates, where a false positive is a
    stalled session. Debris can only appear at or before the token the walk
    stopped on, so bounding there loses no real tear.
    """
    for tok in toks[:upto]:
        if not _ASSIGN_TOK_RE.match(tok) and not _ENV_ASSIGN_TOK_RE.match(tok):
            continue
        value = tok.partition('=')[2]
        # PRESENCE, not balance. Counting delimiters was the last piece of
        # grammar left in here and it failed the same way everything else did:
        # shlex removes quote provenance, so a QUOTED literal closer cancels a
        # live opener and the counts balance on a token that is still torn.
        # `X=$(printf")" x y) bash -c ...` arrives as `X=$(printf)` - balanced,
        # apparently complete, and bash runs the payload behind it (verified).
        #
        # So the question is weakened until it cannot be wrong: does this value
        # contain substitution syntax AT ALL? If it does, the walk may have been
        # torn, and looking again is cheap. This can only over-fire, and
        # over-firing costs one extra scan of a segment.
        # Process substitution belongs with the rest: `X=<(printf x y)` tears the
        # same way and bash runs the command behind it (verified). It carries no
        # `$`, so the substitution list had to name it.
        if any(o in value for o in ('$(', '${', '$[', '`', '<(', '>(')):
            return True
    return False


# The scope value the DIRECT-route torn recovery reports instead of a derived
# directory. Non-empty and non-absolute, which is what resolve-repo-dir.sh needs
# to reach `block-unresolvable`; the leading `?` also fails gate_classify_target
# outright, so both of that resolver's rejection paths agree. It is deliberately
# NOT a directory: recovery knows a command is hidden, never where it would run,
# and an empty value here would ANCHOR the cwd repo and approve it (verified) --
# the one way this recovery could fail OPEN.
_TORN_SCOPE = '?torn-assignment'


def _torn_direct_hits(seg, target, argv):
    """Yield every `target` token in a segment whose walk hit a torn assignment.

    The DIRECT-route companion to the fallback in _shell_payloads: same trigger
    (`_torn_assignment`), same any-position scan, same refusal to rebuild the
    span. Yields `(toks, index)` per candidate for the caller to read a
    subcommand from, and simply stops iterating when there is no tear -- so an
    untorn segment costs one `_torn_assignment` scan and nothing else.

    `argv` is the caller's ALREADY-COMPUTED `_command_argv(seg, target)`. It is
    a parameter rather than a second call because both callers have it in hand
    and this runs on every git/gh segment, the overwhelming majority of which
    are untorn: recomputing it duplicated the command-word walk on the hot path.

    What makes this safe to add where the pinned note below once said it was
    not: it never derives scope. The blocker was that closing the direct route
    means synthesizing an argv for a scanner that reads `target_dir`, `-C`
    authority and cd trust from argv POSITION -- positions the debris does not
    have. So recovery reports `_TORN_SCOPE` instead of guessing, and the three
    fail-CLOSED gates stall on an unresolvable repo rather than acting on a
    fabricated one.

    Gated more narrowly than the nested route's three disjuncts: ONLY a real
    tear recovers here. A walk that merely landed on some other readable name is
    an ordinary different command, not debris, and recovering there would read
    every argument as a command word.

    EVERY occurrence is yielded, and the caller must try them all. Stopping at
    the first was a verified fail-OPEN: in `X=$(printf git x) git commit -m x`
    the torn VALUE contributes its own `git` token ahead of the real one, so the
    first hit reads `x)` as the subcommand and the scan gives up while bash goes
    on to run the commit (verified: the commit lands). The same shape hides
    `gh pr merge` behind `X=$(printf gh x)`.
    """
    toks = toks_once(seg)
    # By ARITHMETIC, for the reason spelled out at the _shell_payloads gate: argv
    # is a SUFFIX of this same list, so the difference is the command word's
    # index even when the walk dropped leading group punctuation. Searching by
    # value instead matched an earlier equal token and scanned a prefix too short
    # to contain the tear -- the fail-OPEN that bound exists to avoid.
    upto = (len(toks) - len(argv) + 1) if argv else None
    if not _torn_assignment(toks, upto):
        return
    # Basename-matched via _is_exe, so `/usr/bin/git commit` behind a tear is not
    # a hole. Position is irrelevant to the SCAN by design: the debris destroyed
    # argv positions, so it asks only whether the executable appears at all and
    # lets the caller read the subcommand.
    cands = [k for k, tok in enumerate(toks) if _is_exe(tok, target)]
    # NO EXEMPTION HERE, and the attempt to build one is worth recording so it is
    # not retried. #634 review flagged that `_torn_assignment` is presence-based,
    # so an INTACT `TAG=$(git describe) git commit` trips it and stalls. The fix
    # tried was: if every occurrence of the target is the index the walk stopped
    # at, the tear hid nothing, so trust the walk. Its premise -- "the walk's
    # landing IS the executed command word" -- is false exactly when the landing
    # is itself inside the substitution, and four separate shapes were verified
    # to defeat it, each reporting the cd's scope for a commit that runs
    # elsewhere:
    #     X=$(printf git commit x) $G -C /x commit        (dynamic command word)
    #     X=$(printf git commit x) bash -c "git -C /x …"  (interpreter payload)
    #     X=$(printf git commit x) true; git -C /x commit (real command later)
    #     X=$(printf")" git commit x) true                (forged in-token close)
    # Guarding each -- staticness, then _shell_payloads, then in-token balance --
    # closed them one at a time while the next kept arriving, which is the
    # per-case table #587 exists to stop building. Deciding whether the landing
    # sits inside the substitution IS the boundary problem, and the boundary is
    # forgeable through a quoted closer (this file reverted that scanner after
    # five verified bypasses). So the rule stays uniform: a tear means the scope
    # is unknowable, full stop.
    #
    # That is correct, and it is a safety GAIN rather than an over-block: the
    # whole `VAR=$(<multi-word git/gh cmd>) git commit` family was a silent
    # fail-OPEN on main (verified against the pre-#593 path -- every one of
    # `$(git describe --tags)`, `$(git rev-parse HEAD)`, `$(git config
    # user.name)`, `<(git rev-parse HEAD)`, `$( git describe )` and even
    # `$( date )` returned NOT-DETECTED, so the commit ran unseen by all three
    # gates). This is the #593 bug itself, not collateral damage from fixing it.
    # It now reports DETECTED with an unresolvable scope, so the gate stalls.
    #
    # Escapes for the stall, verified clean: SPLIT the segment
    # (`H=$(git rev-parse HEAD); git commit`) so the assignment is its own
    # statement. Quoting alone does NOT help -- `H="$(git rev-parse HEAD)"`
    # collapses to one token but still carries `$(`, which is all
    # `_torn_assignment` looks at.
    for k in cands:
        yield toks, k


def toks_once(seg, _cache={}):  # noqa: B006 - deliberate per-scan memo, see below
    """_tokenize(seg) memoised for the length of one scan.

    The any-position walk below asks for the same token list repeatedly; the
    quadratic suffix-rebuild it replaces measured 4.58s on a 2,400-token
    segment, past the guard 3s alarm, and re-lexing per token would restore it.
    """
    got = _cache.get(seg)
    if got is None:
        if len(_cache) > 256:
            _cache.clear()
        try:
            got = _tokenize(seg)
        except Exception:               # noqa: BLE001 - fail CLOSED, never []
            # An empty list would gate the any-position scan OFF for this
            # segment, hiding a payload behind it. _tokenize already handles
            # ValueError internally; this only covers an unexpected failure,
            # so degrade to the same quote-stripping split _tokenize itself
            # falls back to rather than silently disabling the scan.
            got = [t.strip('\047\042') for t in seg.split()]
        _cache[seg] = got
    return got

def _quoted_literal(raw):
    """True iff this RAW spelling wraps the whole token in one pair of quotes.

    Both quote styles count: bash performs pathname expansion on neither, so the
    glob characters inside are literal filename characters either way. `None`
    (raw stream unavailable or unaligned -- see _raw_tokens) is False, which is
    the fail-CLOSED answer.
    """
    return (raw is not None and len(raw) > 1
            and raw[0] == raw[-1] and raw[0] in '\047\042'
            and raw[0] not in raw[1:-1])


def _fallback_interpreter_name(tok, raw=None):
    """`_interpreter_name` for the any-position scan, with ONE narrowing: a
    glob-shaped word that did NOT resolve to a real interpreter is not the `sh`
    stand-in (#589).

    That is the whole of #589. `_interpreter_name` fnmatches a glob-shaped token
    against `_INTERPRETERS` first, so `/bin/ba?h` and `'./b*sh'` still resolve to
    `bash` and stay fail-CLOSED; only the fall-through — a word that matches no
    interpreter at all, like `'*.py'` — stops being promoted.

    QUOTED ONLY, which is the load-bearing half and why `raw` is threaded in.
    shlex strips quotes, so `tok` alone cannot tell `'*.py'` (data: bash performs
    no pathname expansion inside quotes, so it can only name a file literally
    called `*.py`) from `./*.py` (a real glob, which expands to whatever is on
    disk). Narrowing on `tok` alone therefore suppressed the UNQUOTED form too —
    and `X=$(printf x y) ./*.py -c 'git commit -m x'` runs bash whenever the
    glob catches a shell, e.g. a `shell.py` symlink. That is a bypass, not the
    documented literal-file exclusion. `_raw_tokens` carries the spelling
    verbatim; an unavailable or unaligned raw stream makes `_quoted_literal`
    False, so the narrowing simply does not apply — fail CLOSED.

    The test is RESOLUTION, not the returned name. `name == 'sh'` cannot express
    it: `_interpreter_name` answers `sh` both for the stand-in it invents when a
    glob reaches nothing AND for a glob that genuinely resolves to the real
    `sh` -- `/bin/?h` fnmatches `sh`, so comparing names suppressed a shell that
    actually runs, and `/bin/?h -c 'git commit -m x'` went undetected. Asking
    whether the returned interpreter itself still matches the pattern separates
    them: a resolved glob matches (`bash` vs `ba?h`, `sh` vs `?h`), the stand-in
    does not (`sh` vs `*.py`).

    The whole rule rests on "fnmatch found nothing, so bash finds nothing", and
    that premise holds for ONLY `*` and `?` on a plain word. Every construct
    where the two disagree is excluded rather than modelled, because modelling
    them is the ladder this file exists to stop climbing:

      [        no POSIX bracket CLASSES in fnmatch, so `/bin/ba[[:alpha:]]h`
               expands to /bin/bash for the shell and to nothing here
      $ `      an expansion resolves BEFORE globbing; `b$a*sh` may reach bash
      { (      brace expansion and extglob, per _unreadable_word
      \\        an escape fnmatch does not honour the way the shell does

    Case is handled rather than excluded: the resolution test lowercases both
    sides, because `bash -O nocaseglob` expands `/bin/B?SH` to /bin/bash while
    `fnmatchcase` refuses it — suppressing on that non-match was a bypass. Any
    interpreter the pattern could reach in ANY case blocks the narrowing, which
    is the fail-CLOSED direction. This honours the `return 'sh'` refusal
    `_interpreter_name` documents instead of undoing it.

    Narrowed to words whose ONLY unreadable feature is the glob. `_unreadable_word`
    is true for `$`, a backtick, a brace and a paren as well, so gating on it
    wholesale would have disabled this rule entirely -- every glob is unreadable
    by that test. Requiring the absence of the others keeps `b$a*sh` a
    fail-CLOSED stand-in: the shell expands `$a` before globbing and may well
    reach `bash`, so it is not an unresolved glob literal. #589 is about glob
    literals; it does not re-open the unreadable-word hole.
    """
    name = _interpreter_name(tok)
    word = _norm_cmd_word(tok)
    if name is None:
        return name
    if not _quoted_literal(raw):
        # Unquoted `./*.py` really globs and reaches a shell when expansion catches one.
        return name
    if word in _INTERPRETERS:
        # A literal interpreter name is not a glob.
        return name
    if not re.search(r'[*?]', word):
        # Only `*` and `?` are where fnmatch and bash agree.
        return name
    if re.search(r'[\[$`{(\\]', tok):
        # fnmatch has no POSIX bracket classes; `$`, backtick, brace, paren, and
        # backslash all resolve before globbing.
        return name
    if any(fnmatch.fnmatchcase(i.lower(), word.lower()) for i in _INTERPRETERS):
        # A resolving glob still names a shell; `bash -O nocaseglob` expands `/bin/B?SH`.
        return name
    return None


def _shell_payloads(cmd):
    """Strings an interpreter/eval will itself execute — `bash -c '<s>'`,
    `sh -c '<s>'`, `eval '<s>' '<t>'`, etc. — for recursive scanning."""
    out = []
    for _op, seg in split_segments(cmd):
        out.extend(_env_split_string_payloads(seg))
        # TWO readings of the launcher run, for the reason _consumer_words
        # spells out above: wrapper-option arity is genuinely ambiguous
        # statically. `env -i bash -c '<s>'` has a NO-ARG option, while
        # `env -u FOO bash -c '<s>'` has a value-taking one, and a single
        # reading must guess. The '' reading guesses "takes a value", so on
        # `env -i bash -c ...` it consumed `bash` as the argument of `-i`,
        # argv[0] became `-c`, no interpreter was recognised, and the payload
        # was never extracted at all -- so `env -i bash -c 'rm -rf /etc'`
        # scanned as if it contained no rm. That is fail-OPEN, and it is what
        # the `target` parameter of _command_argv exists to prevent: naming the
        # interpreters protects them from being swallowed by a preceding
        # option. Read BOTH ways and union the results, which is fail-CLOSED:
        # one reading always lands on the real interpreter.
        # Duplicates are possible when the two readings agree; they are deduped
        # only to avoid rescanning the same string, never for correctness --
        # _all_chunks already documents that an over-count merely blocks while
        # an under-count is a bypass.
        seen = set()
        _first_reading = _command_argv(seg, '')
        readings = [_first_reading,
                    # #641: the operand walk belongs on THIS reading too, or a
                    # wrapper sitting OUTSIDE the interpreter hides the payload:
                    # `timeout 5 bash -c "git commit"` stopped the walk on `5`,
                    # argv[0] was not an interpreter, and the `-c` string was
                    # never extracted (verified: the command runs). Note the
                    # asymmetry that made this easy to miss -- `xargs -0 bash -c
                    # …` was already detected, because `-0` is an OPTION and
                    # leaves `bash` in command position; only the operand-bearing
                    # spellings broke.
                    #
                    # Safe here and NOT on `_first_reading` above, which passes
                    # target='': with no target to protect, the operand branch
                    # would step over every bare word to the end of the segment
                    # and return [], losing discovery entirely. This reading
                    # names real targets, so `not is_target` stops it on the
                    # interpreter.
                    _command_argv(seg, tuple(_INTERPRETERS) + ('eval',),
                                  wrapper_operands=True)]
        # ...plus a GRAMMAR-FREE reading: every interpreter token, wherever it
        # sits. This is the terminating move (PR #555, 2026-08-06 council).
        #
        # Locating the command word means deciding where an assignment VALUE
        # ends, and shlex tears `X=$((1 + 2))` into `X=$((1` / `+` / `2))`
        # without knowing a substitution is open. Rebuilding that span by
        # counting delimiters was tried and abandoned: it has to be
        # context-SENSITIVE where bash is, so `(` is structure in `$((`, data in
        # `${x:-(}`, and there is always one more context (`$[1 + 2]`,
        # `${x[(e)]}`). Two review rounds produced five verified bypasses in
        # that scanner alone - more defects than the single bug it fixed.
        #
        # So the position question is not answered, it is DROPPED. An
        # interpreter names itself; scanning for the name needs no grammar and
        # has no next case to enumerate. The residual failure surface moves down
        # to shlex tokenization itself, which no span heuristic could reach.
        #
        # SCOPE: this recovery covers the NESTED route (a payload an interpreter
        # runs). The DIRECT route was missed here - `X=$(printf x y) git commit`
        # really does run - and that hole is now CLOSED by `_torn_direct_hits`,
        # which #593 tracked separately.
        #
        # The blocker recorded here was real and is why the fix took the shape it
        # did: closing the direct route looked like it meant synthesizing an argv
        # for a scanner that derives `target_dir`, `-C` authority and cd trust
        # from argv POSITION - positions the debris does not have. The way out
        # was to stop trying to derive scope at all. Recovery reports `True` with
        # `_TORN_SCOPE`, and the three fail-CLOSED gates stall on an unresolvable
        # repo instead of acting on a fabricated one, so none of the marker-
        # scoping logic is asked a question the debris cannot answer.
        #
        # The target FUSED into the assignment token - `X=$(git commit -m x) ls`
        # - needs nothing from the scan: `_all_chunks` already lifts substitution
        # bodies out as their own chunks and scans them (verified detected, both
        # `$(...)` and backtick spellings, git and gh). It is listed here only
        # because it looks like the same hole and is not.
        #
        # ACCEPTED COST, measured the way #587 measured its own: against 29,277
        # recorded agent commands, the direct recovery newly detects exactly ONE,
        # and that one is a probe typed while investigating #593 -
        # `bash -c 'X=$(printf x y) echo git commit'`, which PRINTS `git commit`
        # (verified) rather than running it. So the class is real: after a tear,
        # an `echo`/`printf` ARGUMENT is indistinguishable from a command word,
        # because the debris is exactly what destroyed argv position. It costs a
        # visible stall, never a bypass. Telling the two apart means reading
        # command position back out of the debris - the span rebuild that was
        # reverted for producing five verified bypasses of its own - so the
        # over-block stays. On real workflow commands the delta is ZERO.
        #
        # WHAT THAT CORPUS DOES NOT PROVE, recorded because trusting it too far
        # already cost one round: it is one operator's recorded history, so a
        # command shape absent from it is NOT thereby rare in bash. The #634
        # review caught exactly that -- an over-fire on `TAG=$(git describe) git
        # commit`, an entirely ordinary form, which the sweep scored as zero
        # regressions because that history simply never used it. A zero here
        # means "no observed regression in this sample", never "no such class".
        # Reason about the class as well as counting the sample.
        #
        # MEASURED COST, because "over-extraction is the safe direction" is
        # true only for the advisory guard - these payloads also feed three
        # FAIL-CLOSED gates, where a false positive is a stalled session. Run
        # against 29,563 recorded agent commands, diffed against the previous
        # implementation: 361 commands (1.22%) yield an extra payload, the
        # number that would NEWLY trip a fail-closed gate is ZERO, and - the
        # measurement that actually prices this for the operator - the advisory
        # guard\x27s prompt rate is UNCHANGED: 27 of 1,200 sampled commands
        # before and after. The extra payloads are inert; they get scanned and
        # contain nothing worth warning about.
        # (Ungated it was 61; the gate below halves the over-read as well as
        # closing the echo/printf false positives.)
        # Quoted runs stay single shlex tokens, so a `bash -c "git commit"`
        # sitting inside an argument never fires; only a real, separate-token
        # interpreter run does, which is what keeps that population narrow.
        #
        # GATED, so it is a fallback and not a second opinion. It runs when the
        # conservative walk cannot have read the command word: either it landed
        # on nothing, or on a token no command is named (`+`, `2))` - the debris
        # shlex leaves when it tears an assignment), or the walk CONSUMED an
        # assignment whose own token opens a substitution that does not close in
        # it. That last signal is what a shape test alone could not give:
        # `X=$(printf x y) bash -c "git commit"` leaves the perfectly
        # name-shaped `x` in the command slot, and bash runs the commit.
        #
        # Note it is a ONE-TOKEN openness test, not a span: it asks only whether
        # this token starts something it does not finish, never where the value
        # ends. Over-firing is the safe direction, so `X=${x:-(}` (balanced in
        # bash, unbalanced to a paren count) merely scans twice.
        # The tear can only lie in the prefix the walk crossed, so the scan stops
        # at the token it stopped on - see _torn_assignment. By ARITHMETIC, not
        # by locating argv[0]'s value: _command_argv returns a SUFFIX of this
        # same token list, so `len(toks) - len(argv)` is the command word's
        # index even when the walk dropped leading group punctuation (both strip
        # helpers only delete tokens ahead of it or edit one in place, and a
        # deletion shifts both lengths together). Searching by value picked the
        # FIRST equal token instead of the occurrence the walk used, so
        # `env -u x X=$(printf x y) bash -c '<s>'` matched the earlier option
        # ARGUMENT `x`, scanned a prefix too short to contain the tear, and the
        # payload was missed - the fail-OPEN this bound exists to avoid.
        upto = (len(toks_once(seg)) - len(_first_reading) + 1
                if _first_reading else None)
        torn = _torn_assignment(toks_once(seg), upto)
        if not _first_reading or not _READABLE_NAME.match(_first_reading[0]) \
                or torn:
            toks = toks_once(seg)
            # NO POSITIONAL NARROWING HERE, and the attempt is recorded so it is
            # not retried. #589's review round asked for exactly that: once the
            # walk returns a suffix, `len(toks) - len(argv)` is the command
            # word's index, so "only that index may name an interpreter" reads
            # like a free precision win. It is not. The index is trustworthy
            # only when the walk READ a command word, and this branch is
            # reached precisely when it did not -- the walk landed on nothing,
            # on debris no command is named, or the segment TORE. Narrowing to
            # that index is therefore narrowing to a token the tear already
            # invalidated, and it is fail-OPEN twice over:
            #
            #   * Gated on the index alone, these six all stop being detected,
            #     and every one is verified to run the commit in the child
            #     (they are the `torn-nested+` rows in tests/):
            #         X=$((1 + 2)) bash -c "git commit -m x"
            #         X=${foo:-a b} bash -c "git commit -m x"
            #         X=$(printf x y) bash -c "git commit -m x"
            #         X=<(printf x y) bash -c "git commit -m x"
            #         env A-B=$((1 + 2)) bash -c "git commit -m x"
            #         env -u x X=$(printf x y) bash -c "git commit -m x"
            #     Measured: 10 of 1,808 spec checks fail, the six above plus the
            #     two `(accepted)` rows and two `eval` rows.
            #   * Gated on the index only when the segment is NOT torn, it still
            #     suppressed a later interpreter behind an unreadable command
            #     word: `./+ bash -c 'git commit -m x'` went DETECTED -> not
            #     detected against main (`./+` may be a dispatcher running
            #     `exec "$@"`). That spelling shipped briefly on this branch and
            #     is what this comment exists to stop coming back.
            #
            # The reviewer's own reproducer -- `X=$(printf x y) printf '%s' bash
            # -c 'git commit -m x'`, where `bash` is a printf ARGUMENT -- stays
            # DETECTED, deliberately. Telling it apart from the third row above
            # means knowing where `$(` closes, which is the span rebuild this
            # file reverted after five verified bypasses (a quoted closer,
            # `X=$(printf ")" x) bash -c '<s>'`, forges the boundary). It is the
            # same accepted echo/printf-argument-after-tear cost the block above
            # already prices, it is pre-existing on main rather than new here,
            # and it costs a visible stall, never a bypass. Pinned as
            # `torn-nested~ (accepted-current)` in tests/test-gitcmd-detect.sh
            # with the condition under which it may be retired; see
            # docs/adr/0045-torn-assignment-any-position-recovery.md.
            # Quote provenance for the #589 narrowing, aligned 1:1 with `toks`.
            # Unavailable or unaligned -> None, and _quoted_literal then refuses
            # to narrow anything (fail CLOSED). The length re-check covers the
            # case where toks_once fell back to its own split on a _tokenize
            # failure, which _raw_tokens cannot know about.
            try:
                _raws = _raw_tokens(seg)
            except Exception:           # noqa: BLE001 - fail CLOSED, never narrow
                _raws = None
            if _raws is not None and len(_raws) != len(toks):
                _raws = None
            first_interp = first_eval = -1
            canon = {}
            for k, tok in enumerate(toks):
                # An assignment is never a command word, so it is never the
                # interpreter. Without this the torn token that TRIPPED the gate
                # was itself read as the stand-in shell -- it contains a `$`, so
                # `_interpreter_name` refused it -- and any later `-c` became its
                # option: `X=$(printf x y) echo -c 'git commit'` extracted a
                # payload and a fail-CLOSED gate blocked a commit bash never
                # runs (verified: it prints `-c git commit`). Both spellings,
                # because an env(1) operand is an assignment by env's rules and
                # is equally not a command word.
                # The env(1) spelling is the LOOSE one (`^[^=]+=`, no identifier
                # rule), so it also matches an EXPANSION that merely contains an
                # `=`: `${X:=bash} -c '<s>'` runs bash when X is unset
                # (verified), and skipping it hid the payload. Only skip a loose
                # match this scan can READ -- an unreadable token stays a
                # candidate, which is the fail-CLOSED direction. The strict bash
                # form needs no such guard: `^\w+=` cannot match `${...}`.
                if _ASSIGN_TOK_RE.match(tok) or (
                        _ENV_ASSIGN_TOK_RE.match(tok) and not _unreadable_word(tok)):
                    continue
                name = _fallback_interpreter_name(
                    tok, _raws[k] if _raws is not None else None)
                if name is not None and first_interp < 0:
                    first_interp, canon[k] = k, name
                # BOTH, not elif. An unreadable word resolves to the `sh`
                # stand-in, which used to consume the token and leave the eval
                # branch unreachable - so `$'eval' "git commit"` produced no
                # payload while bash ran the commit (verified). Unreadable means
                # unreadable: it may be a shell OR eval, and the two are read
                # differently (eval executes its ARGUMENTS, a shell its `-c`
                # payload), so both readings are offered.
                if first_eval < 0 and (_norm_cmd_word(tok) == 'eval'
                                       or name == 'sh' and _unreadable_word(tok)):
                    first_eval = k
                # KNOWN LIMIT, deliberately not closed here. The subset argument
                # below does not hold for eval - an eval reading joins every
                # following token into one payload, so an earlier SPECULATIVE
                # candidate PREPENDS debris rather than containing a later real
                # `eval`. With `foo` unset,
                # `X=$(printf %s $foo bar baz) eval "git commit"` therefore runs
                # the commit unseen. Promoting the first LITERAL `eval` as a
                # second candidate was tried and reverted: `eval` is a perfectly
                # ordinary ARGUMENT, so `X=$(...) printf %s eval "git commit"`
                # then reported a commit that printf only PRINTS (verified).
                # Telling those apart is the command-word position question this
                # scan exists to avoid answering. The miss is pre-existing on
                # main; the false block would have been new, and a new false
                # block in three fail-CLOSED gates is the worse of the two.
                if first_interp >= 0 and first_eval >= 0:
                    break
            # ONLY the earliest of each, which is exact rather than a cap FOR AN
            # INTERPRETER: _interpreter_payloads returns every token after the
            # first `c`-cluster at or past its start, so a later candidate's
            # payloads are a SUBSET of the earliest one's. Taking all of them
            # re-scanned overlapping tails and measured 5.37s on 9,600 `bash x`
            # pairs, past the guard 3s alarm.
            for k, canon_default in ((first_interp, None),
                                     (first_eval, 'eval')):
                if k >= 0:
                    head = canon[k] if canon_default is None else canon_default
                    readings.append([head] + toks[k + 1:])
        for argv in readings:
            if not argv:
                continue
            base = argv[0].rsplit('/', 1)[-1]
            if base in _INTERPRETERS:
                found = _interpreter_payloads(argv)
            elif base == 'eval':
                found = [' '.join(argv[1:])]
            else:
                continue
            for payload in found:
                if payload not in seen:
                    seen.add(payload)
                    out.append(payload)
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


# git GLOBAL options that take a SEPARATE value token. The value must be skipped, or
# it is mistaken for the subcommand (`git --git-dir /d --work-tree /r commit`).
_GIT_VALUE_OPTS = ('-C', '-c', '--git-dir', '--work-tree', '--namespace',
                   '--super-prefix', '--config-env')


def _git_subcommand(argv):
    """(subcommand, its index) for a `git` argv -- the first non-flag token after
    `git`, with each global option's SEPARATE value skipped. (None, len(argv)) when
    there is no subcommand at all.

    Split out of _scan_commit purely to reduce its complexity (CodeScene "Complex
    Method", #510); behavior unchanged."""
    skip = False
    for i, a in enumerate(argv[1:], start=1):
        if skip:
            skip = False
            continue
        if a in _GIT_VALUE_OPTS:
            skip = True
            continue
        if a.startswith('-'):
            continue
        return a, i
    return None, len(argv)


def _resolve_c_operand(raw, base, authoritative, tilde_c):
    """Fold ONE global `git -C <raw>` into (base, authoritative, tilde_c).

    EVERY tilde form invalidates authority, not just the ones expanduser resolves.
    '~'/'~user' come back absolute and are handled by the isabs arm, but the
    shell-only '~+' and '~-' (bash: $PWD / $OLDPWD) stay RELATIVE here, so they fell
    through to the join and left an earlier trusted cd's authority intact -- `cd /repo
    && git -C ~+ commit` scoped the gate to a nonexistent /repo/~+ with an EMPTY
    untrusted_cd while bash committed in /repo. Bash resolves all of these from
    runtime state we do not have, so none of them may be authoritative.

    An absolute `-C` fixes the repo on its own, whatever any preceding cd did -- but
    only when it really is absolute. Tokenization has discarded the tilde's quoting,
    so `git -C "~"` is a LITERAL RELATIVE dir that git resolves against the runtime
    cwd (`/other/~`) even though expanduser turned it into an absolute $HOME here. A
    later tilde operand must also INVALIDATE authority an earlier absolute `-C`
    established (`-C /session -C "~"` resolves against /session at runtime, not
    $HOME).

    Split out of _scan_commit purely to reduce its complexity (#510); behavior
    unchanged."""
    v = os.path.expanduser(raw)
    if raw.startswith('~'):
        tilde_c = True
        authoritative = False
    if os.path.isabs(v):
        return v, not raw.startswith('~'), tilde_c
    if base:
        return os.path.join(base, v), authoritative, tilde_c
    return v, authoritative, tilde_c


def _apply_global_c(argv, raw_argv, sub_idx, base, authoritative, allow_cd):
    """Resolve every PRE-SUBCOMMAND global `git -C`, returning
    (base, authoritative, tilde_c, nested_c).

    git applies every global `-C` in order; a relative value resolves from the
    directory established so far (the cd base, then each preceding `-C`). Only
    pre-subcommand `-C` changes directory -- `git commit -C <ref>` (AFTER the
    subcommand) is the reuse-message flag, not a cd -- so the walk is bounded by
    `sub_idx` or it mis-scopes the marker check to the wrong repo.

    `tilde_c` is set by any tilde operand and `nested_c` by a `-C` seen in a NESTED
    chunk; the caller turns each into an out-of-band blocking token (see
    _commit_untrusted).

    Split out of _scan_commit purely to reduce its complexity (CodeScene "Complex
    Method" / "Bumpy Road Ahead", #510); behavior unchanged."""
    tilde_c = False
    nested_c = False
    k = 0
    while k < sub_idx:
        if argv[k] != '-C' or k + 1 >= sub_idx:
            k += 1
            continue
        # raw_argv is aligned with argv, so this is THIS operand's own spelling --
        # not a lookalike elsewhere in the segment. Tokenized once per segment
        # (inside _command_argv), so N `-C` operands stay linear rather than
        # re-lexing the segment N times.
        #
        # Same fail-CLOSED rule as _cd_target: `git -C` is the OTHER way a
        # target_dir is derived, and every gate prints it through a positional
        # newline-delimited protocol (#511). Validate the RAW operand, before
        # _mask_literal_substitution's re-quoting, so a CR/LF cannot hide behind
        # either the quoted or the masked spelling.
        rk = k + 1
        _reject_crlf(argv[rk], 'git -C target')
        raw = _mask_literal_substitution(argv[rk], _raw_spelling(raw_argv, rk))
        if allow_cd:
            base, authoritative, tilde_c = _resolve_c_operand(
                raw, base, authoritative, tilde_c)
        else:
            # Nested chunk: this scanner deliberately does NOT honour `-C` for
            # SCOPING (that would change how nested operations resolve -- out of
            # scope here). But staying silent is not neutral: it returned the same
            # ('', '') as "no cd at all", so the gate anchored on the session cwd
            # while git committed in the `-C` target. Record its presence so the
            # caller can BLOCK.
            nested_c = True
        k += 2
    return base, authoritative, tilde_c, nested_c


def _commit_untrusted(cds, allow_cd, authoritative, tilde_c, nested_c):
    """The unconfirmed-cd field for a `git commit` match.

    Report the unconfirmed cd unless the target is AUTHORITATIVE: either an
    adjacent-and-reachable '&&' proved the cd ran, or an absolute `git -C` fixed the
    repo regardless. An absolute target_dir alone is NOT enough -- it may itself have
    come from an unproven cd (`cd /a || cd /b && commit`).

    A tilde `-C` makes target_dir itself a LIE, with or without any cd to report:
    tokenization has already discarded the quoting, so we cannot tell `git -C ~` (git
    really does get $HOME) from `git -C "~"` (git gets a LITERAL relative '~',
    resolved against the runtime cwd). expanduser commits to the first reading, so the
    gate would validate $HOME's marker while the commit lands in <cwd>/~. Since the
    two are indistinguishable here, emit a leading-dash token: gate_classify_target()
    rules any '-*' operand unresolvable, so the resolver BLOCKS. Fail-CLOSED, and
    never a real absolute path that could be mistaken for one. `nested_c` gets the
    same out-of-band blocking token, for a `-C` this scanner saw but did not resolve.

    Split out of _scan_commit purely to reduce its complexity (#510); behavior
    unchanged."""
    if authoritative:
        return ''
    if tilde_c:
        return '-tilde-c-operand'
    if nested_c:
        return '-nested-c-operand'
    return _untrusted_cd(cds) if allow_cd else ''


def _scan_commit(chunk, allow_cd):
    """Scan one command chunk for a real `git commit`; return the result tuple
    or None. allow_cd=False for substitution bodies (subshell cwd is untrusted)."""
    pending_cd = None
    pending_cd_op = ''
    # EVERY cd seen, never reset by intervening commands — see _untrusted_cd.
    cds = []
    for op, seg in split_segments(chunk):
        cd = _record_cds(seg, cds)
        if cd is not None:
            pending_cd = cd           # strict form only: feeds the TRUSTED path
            pending_cd_op = op
            continue
        argv, raw_argv = _command_argv(seg, 'git', with_raw=True,
                                       wrapper_operands=True)
        # #593. A tear anywhere in the prefix makes EVERY argv position in this
        # segment untrustworthy -- including a walk that appears to have
        # succeeded -- so recovery runs FIRST and its unresolvable scope wins.
        # Two verified fail-opens forced that ordering, both of which a
        # "only when the walk found nothing" gate let through:
        #   `X=$(printf git x) git commit`            - the torn VALUE supplies a
        #     `git` ahead of the real one, so the walk lands on it, reads `x)` as
        #     the subcommand, and the commit behind it runs unseen.
        #   `X=$(printf git commit x) git -C /tmp commit`
        #                                             - the debris spells a whole
        #     `git commit`, so the walk "matches" and reports the CWD scope while
        #     bash commits in /tmp (verified: the commit lands in /tmp, and the
        #     cwd repo gets nothing). The gate would have validated the wrong
        #     repo's marker.
        # _torn_direct_hits yields nothing when there is no tear, so an untorn
        # command keeps the ordinary walk and its real, resolvable scope.
        # Collected rather than short-circuited so amend-ness can be read across
        # EVERY candidate window (see below); the first match still decides that
        # a commit is present.
        _hits = list(_torn_direct_hits(seg, 'git', argv))
        # LINEAR, not quadratic (#634). Reading each candidate's subcommand from
        # its full suffix copied the tail once per candidate, and the amend pass
        # then re-scanned every start per hit: a 12k-candidate segment measured
        # ~2.25s against this file's 3s guard alarm, which a large Bash command
        # could ride into a stalled hook. Each candidate is bounded by the NEXT
        # one instead, so the slices partition the segment rather than stacking.
        _all = _hits[0][0] if _hits else ()
        _starts = [_k for _t, _k in _hits]
        _commit_starts = []
        for _i, _k in enumerate(_starts):
            _end = _starts[_i + 1] if _i + 1 < len(_starts) else len(_all)
            if _git_subcommand(_all[_k:_end])[0] == 'commit':
                _commit_starts.append(_k)
        if _commit_starts:
            # Amend-ness reads the OPTION portion only, matching the normal
            # path's `opt_words` split below (#634 cubic review): a `--amend`
            # after the `--` pathspec separator is a literal pathspec token, not
            # the flag, so a torn `... -- --amend` must not report an amendment.
            #
            # Each candidate is bounded by the NEXT candidate rather than
            # running to end-of-segment, and the result is OR-ed across all of
            # them. Taking the first candidate's whole suffix under-reported
            # (#634): in `X=$(printf git commit -- x) git commit --amend` the
            # `--` inside the DEBRIS truncated the scan, so the real outer
            # amendment read as False. Bounding each window at the next
            # candidate keeps one invocation's options from being read through
            # another's debris, without locating where any argv actually ENDS --
            # that is the span rebuild this file abandoned. OR-ing is the
            # fail-safe direction for the residual ambiguity: over-reporting an
            # amendment costs a stricter check, under-reporting hides one.
            # Bounded at the next COMMIT start, not the next target token: an
            # ordinary argument VALUE can be the word `git` (`git commit -m git
            # --amend`), and cutting there truncated the window before the real
            # `--amend` (#634). Only a candidate that actually reads as a commit
            # can begin another invocation.
            _amend = False
            for _i, _k in enumerate(_commit_starts):
                _end = (_commit_starts[_i + 1]
                        if _i + 1 < len(_commit_starts) else len(_all))
                _window = _all[_k:_end]
                _opt_words = (_window[:_window.index('--')]
                              if '--' in _window else _window)
                if '--amend' in _opt_words:
                    _amend = True
            return (True, '', _amend, _TORN_SCOPE, False)
        if not argv or not _is_exe(argv[0], 'git'):
            pending_cd = None
            continue
        sub, sub_idx = _git_subcommand(argv)
        if sub != 'commit':
            pending_cd = None
            continue
        base = _trusted_cd(pending_cd, op) if allow_cd else ''
        base, authoritative, tilde_c, nested_c = _apply_global_c(
            argv, raw_argv, sub_idx, base,
            _cd_authoritative(base, pending_cd_op, cds), allow_cd)
        opt_words = argv[:argv.index('--')] if '--' in argv else argv
        # `authoritative` is surfaced as a 5th element for git_commit's nested-payload
        # suppression, which must NOT re-derive it from target_dir (see there). This
        # scanner is private and both call sites re-pack a 4-tuple, so no caller sees it.
        return (True, base, '--amend' in opt_words,
                _commit_untrusted(cds, allow_cd, authoritative, tilde_c, nested_c),
                authoritative)
    return None


def git_commit(cmd, with_untrusted_cd=False):
    """Detect a real `git commit` invocation via command-word analysis.

    Returns (is_commit: bool, target_dir: str, is_amend: bool), plus a 4th element
    (untrusted_cd: str) when with_untrusted_cd=True — the cd operand that did NOT
    '&&'-gate the commit, for the marker-scoped gates to prove confinement (see
    _untrusted_cd). Default stays a 3-tuple so every existing caller is unaffected.
    target_dir is
    the cd/`git -C` target that scopes the repo (cd trusted only when it '&&'-
    gates the commit — see _trusted_cd); is_amend is True only when --amend
    appears in the option portion (before any `--` pathspec separator). Command
    substitutions ($(...), backticks) are scanned too — they EXECUTE their inner
    command — but their subshell cwd makes target_dir untrusted (returned '')."""
    chunks = _all_chunks(cmd)
    r = _scan_commit(chunks[0], True)
    if r:
        # A CURRENT-SHELL payload (`eval 'cd /other'`, `source`) changes the cwd of
        # the very chunk we matched in, so its cds count for a main-chunk match too.
        # We cannot tell those apart from a subshell `bash -c` payload here, so all
        # nested chunks are folded in: over-blocking a subshell cd is fail-CLOSED,
        # missing an eval cd is not.
        # An AUTHORITATIVE target (an absolute `git -C` whose quoting survived, or an
        # '&&'-proved absolute cd) fixes the repo no matter what any payload did, so
        # it is never overridden. Testing `target_dir.startswith('/')` instead is NOT
        # equivalent and was fooled by `eval 'cd /other'; git -C "~" commit`:
        # expanduser makes the operand look absolute here, while bash treats the
        # quoted tilde as a LITERAL relative dir resolved against the payload's cwd
        # (/other/~). That discarded the nested cd AND left untrusted_cd blank, so the
        # gate inspected $HOME while the commit landed elsewhere. _scan_commit already
        # computes the honest flag; use it rather than re-deriving a weaker one.
        nested = [] if r[4] else [c for chunk in chunks[1:] for c in _all_cds(chunk)]
        # Re-pack to the 4-tuple contract unconditionally — r is 5 long here.
        r = (r[0], r[1], r[2],
             _untrusted_cd(([r[3]] if r[3] else []) + nested) if nested else r[3])
    if not r:
        for chunk in chunks[1:]:
            r = _scan_commit(chunk, False)
            if r:
                # Every cd in the whole command, order-independent -- _nested_cds.
                # r[3] carries any blocking token the nested scan raised (an
                # unresolved `-C`); fold it in rather than overwrite it.
                r = (r[0], r[1], r[2],
                     _untrusted_cd(([r[3]] if r[3] else []) + _nested_cds(chunks)))
                break
    if not r:
        r = (False, '', False, '')
    return r if with_untrusted_cd else r[:3]


# ── Ref-moving git subcommands that create NO commit object (#779) ───────────
# A fast-forward moves a branch ref without producing a commit, so nothing in the
# commit-oriented gates ever sees it. These two subcommands are the shapes that
# reach it from an agent's Bash call.
_REF_OP_SUBS = frozenset(('merge', 'pull'))

# `git merge` / `git pull` options that consume a SEPARATE value token, which
# would otherwise be read as the first operand. The list is a FALSE-POSITIVE
# reducer, never a boundary: an option missing from it leaves its value in the
# operand list, where it either fails to resolve as a commit (merge), fails the
# remote-provenance test (pull), or trips the operand-count refusal — all of which
# BLOCK. Erring by omission is therefore fail-CLOSED.
#
# MEASURED, not recalled: this is the set `git merge -h` and `git pull -h` show
# taking a SEPARATE value (git 2.55.0). Options whose value is attached-optional
# (`--log[=<n>]`, `-S[<key-id>]`, `--signoff[=…]`, `--recurse-submodules[=…]`)
# are correctly absent — they are a single `-`-leading token the operand scan
# already skips. `-j/--jobs[=<n>]` is in that group and was WRONGLY listed here
# once: `git pull --jobs 4 origin` makes git read `4` as the remote and `origin`
# as the refspec, while skipping `4` made the gate validate `origin`'s provenance
# for a pull from somewhere else. Attached-optional options belong nowhere near
# this set.
# Attached-value forms (`--strategy=ours`, `-S<keyid>`) need no entry: they are a
# single `-`-leading token the operand scan already skips.
_REF_OP_VALUE_OPTS = frozenset((
    '-m', '--message', '-F', '--file', '-s', '--strategy',
    '-X', '--strategy-option', '--into-name', '--cleanup',
    '--upload-pack', '-o', '--server-option', '--depth', '--deepen',
    '--shallow-since', '--shallow-exclude', '--negotiation-tip',
    '--negotiation-restrict', '--negotiation-include', '--filter',
    '--refmap', '--submodule-prefix',
))

# `git merge` forms that move no branch ref BY FAST-FORWARD, so they fall outside
# #779's class and this detector reports nothing for them:
#   --abort/--continue/--quit  in-progress-merge controls, no new merge started
#   --squash                   stages a tree, ref untouched — the `git commit`
#                              that must follow is pre-commit-gate's to gate
#   --no-ff                    forces a MERGE COMMIT; a commit object exists, which
#                              is the separate class filed as #622 / #782
_MERGE_CONTROL_OPTS = frozenset(('--abort', '--continue', '--quit'))
# git's parse-options generates a `--no-` form for each of these, and it really
# does cancel them: `git merge --abort --no-abort --ff-only feature` reaches the
# merge (verified, git 2.55.0 — it fails on "No remote for the current branch",
# i.e. past option parsing). So the controls are LAST-WINS per flag like the ff
# and squash families, not one-way exits. There is no `--no-ff-only`.
_MERGE_CONTROL_NEG = frozenset('--no-' + o[2:] for o in _MERGE_CONTROL_OPTS)

# The two families that decide whether a merge can fast-forward at all. Both are
# LAST-WINS in git, so neither may be read as a one-way exit: `git merge --no-ff
# --ff-only x` fast-forwards, and `git merge --squash --no-squash x` is an
# ordinary merge again. Reading only the first occurrence reported "no operation"
# for both and waved them straight past the gate.
_MERGE_FF_OPTS = frozenset(('--ff', '--no-ff', '--ff-only'))
_MERGE_SQUASH_OPTS = frozenset(('--squash', '--no-squash'))

# PRE-SUBCOMMAND git global options that move the repo, the work tree, or the
# CONFIG the gate reads — everything in _GIT_VALUE_OPTS except `-C`, which
# _apply_global_c resolves properly. The gate evaluates the CWD repo's refs and
# `branch.<protected>.merge`, so any of these makes its answer describe a
# different repository than the one git will operate on:
#   git --git-dir=/other/.git --work-tree=/other merge feature
#   git -c branch.main.merge=refs/heads/feature pull origin
# Neither is resolvable from the command string, so both fail CLOSED.
_GIT_SCOPE_OPTS = frozenset(o for o in _GIT_VALUE_OPTS if o != '-C')

# Git subcommands that CANNOT write a ref or rewrite config. Everything else is
# treated as a potential writer — a DENYLIST of safe names rather than an
# allowlist of dangerous ones, because the dangerous set has no closed
# enumeration: an allowlist that named branch/checkout/reset/update-ref still
# missed `fast-import`, and would have missed the next one too. Inverting it
# makes the omission direction fail-CLOSED.
#
# Why this matters: the gate resolves its merge target at PreToolUse time, so any
# command that moves that target before the merge runs defeats the check
# (`git branch -f topic <unreviewed> && git merge topic`;
# `git config branch.main.merge … && git pull origin`). `fetch` is a writer too —
# it moves FETCH_HEAD and the remote-tracking refs — so the honest advice is to
# run the fetch and the merge as SEPARATE commands, which is what the gate says.
#
# `symbolic-ref` is deliberately NOT here: with a value it writes. Neither is
# `difftool`, which exists to run a CONFIGURED external command and can therefore
# write anything. The remaining members can still reach `core.pager`, which is
# configurable too — but only with a TTY, which a Bash tool call does not have,
# and setting it needs a `git config` this gate already refuses in the same
# command. That residual is named in ref-ff-gate.sh's header.
# A ref written WITHOUT a git subcommand at all (`echo <sha> > .git/refs/…`, a
# python script) is outside any command-word parser — the standing residual this
# module's docstring names, not something a bigger list could close.
_REF_SAFE_SUBS = frozenset((
    'blame', 'cat-file', 'check-ignore', 'check-mailmap', 'cherry',
    'count-objects', 'describe', 'diff', 'diff-files', 'diff-index',
    'diff-tree', 'for-each-ref', 'grep', 'help', 'log',
    'ls-files', 'ls-remote', 'ls-tree', 'merge-base', 'name-rev', 'rev-list',
    'rev-parse', 'shortlog', 'show', 'show-branch', 'show-ref', 'status',
    'var', 'verify-commit', 'verify-pack', 'verify-tag', 'version', 'whatchanged',
))

# Environment assignments that redirect the repo, the work tree, or the config
# git reads. `_command_argv` STRIPS assignment prefixes to reach the command word,
# so without this they were invisible and the gate validated the cwd repo while
# git operated elsewhere — and GIT_CONFIG_KEY_0=alias.m defines an alias the same
# way `-c` does. Unlike _REF_SAFE_SUBS this IS an enumeration, because git's
# scope/config environment is a closed documented set: matching every GIT_* would
# drag in GIT_AUTHOR_NAME and refuse ordinary commands for nothing.
_GIT_SCOPE_ENV_RE = re.compile(
    r'^(?:GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_NAMESPACE|GIT_INDEX_FILE'
    r'|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES'
    r'|GIT_CEILING_DIRECTORIES|GIT_DISCOVERY_ACROSS_FILESYSTEM'
    r'|GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_NOSYSTEM'
    r'|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_VALUE_[0-9]+'
    r'|GIT_CONFIG_PARAMETERS'
    # Object-graph and ancestry semantics: replace refs and grafts change
    # WHICH commits are reachable, so the gate's is-ancestor answer and
    # git's can differ on the same two oids.
    r'|GIT_NO_REPLACE_OBJECTS|GIT_REPLACE_REF_BASE|GIT_SHALLOW_FILE'
    r'|GIT_GRAFT_FILE'
    # What git EXECUTES: the transport helper decides which objects a pull
    # actually brings back, and PATH/GIT_EXEC_PATH decide which git runs.
    r'|GIT_EXEC_PATH|GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND'
    r'|GIT_ASKPASS|GIT_EXTERNAL_DIFF|PATH'
    # The transport's trust boundary: a proxy or a disabled certificate check
    # decides which server actually answers for `origin`, which is the whole
    # basis of the pull path's provenance rule.
    r'|GIT_SSL_[A-Z_]+|HTTPS?_PROXY|ALL_PROXY|NO_PROXY'
    r'|https?_proxy|all_proxy|no_proxy'
    # CDPATH changes where a RELATIVE `cd` lands, and a cd is what establishes
    # the repo the gate then inspects: `CDPATH=/other cd repo && git merge x`
    # enters /other/repo while the resolver reads `repo` from the cwd.
    r'|CDPATH'
    # HOME and XDG_CONFIG_HOME select which config FILES git reads, so they can
    # supply branch.<n>.merge or an alias just as GIT_CONFIG_* can.
    r'|HOME|XDG_CONFIG_HOME)\+?=')

# _command_argv walks PAST wrappers to reach the command word, discarding their
# options — so `env -C /other git merge topic` arrived looking like an ordinary
# merge in the caller's repo, and `env -u HOME git pull origin` like an ordinary
# pull while git read a different global config than the gate did. Resolving them
# would mean re-implementing each wrapper's grammar, so an unaccounted wrapper
# option makes the operation unresolvable instead — fail CLOSED. See
# _is_wrapper_chdir_opt for why that test is an inversion rather than a list.
# Wrappers that run git as ANOTHER USER, which changes HOME and therefore which
# global config, aliases and credentials git reads — a different answer from the
# one the gate computed, with no option needed to trigger it (`sudo git merge`).
# Basename-matched, like _WRAPPERS.
_IDENTITY_WRAPPERS = frozenset(('sudo', 'doas', 'su', 'runuser', 'setpriv'))

# Debris `split_segments` leaves when it splits a redirection on its operators:
# `git merge x 2>&1` yields a second segment of just `1`. Counting that as a
# companion command blocked an ordinary redirected merge.
_REDIR_ARTIFACT_RE = re.compile(r'^(?:\d+|[<>&|]+|\d*[<>]{1,2}&?\d*)$')

# At most this many unrecognized subcommands are reported for alias resolution.
# A command naming more than a handful is not a shape the gate needs to serve
# precisely, and an unbounded list would be an unbounded number of `git config`
# lookups inside a hook budget.
REF_OP_MAX_ALIAS_CANDIDATES = 5


def _is_git_scope_opt(tok):
    """True for a PRE-SUBCOMMAND git global option the gate cannot account for.

    Any of them, not an enumeration. Naming the ones that redirect the repo or
    the config (`--git-dir`, `-c`) left the ones that change git's SEMANTICS —
    `--no-replace-objects` alters which commits are reachable, so the gate's
    ancestry answer and git's can differ — and every attached spelling
    (`-c<key>=<value>`, `-C<path>`) had to be spelled out separately. Inverting it
    makes the omission direction fail-CLOSED and needs no list at all.

    A bare `-C` is the sole exemption: _apply_global_c resolves that one properly,
    and its VALUE is skipped by the caller's pairing, not by this predicate."""
    return tok.startswith('-') and tok != '-C' and tok != '-'

# Emitted in place of an operand the gate must not resolve. Leading-dash so that
# any caller which routes it through gate_classify_target() also rules it
# unresolvable rather than treating it as a ref name.
REF_OP_UNRESOLVABLE = '-unresolvable-ref-operand'

# Appended to a pull's operands as `-ff-mode=<--ff|--no-ff|--ff-only>`, carrying
# which fast-forward mode the command asked for. Leading-dash for the same reason
# as REF_OP_UNRESOLVABLE — no ref resolver will mistake it for a name. The gate
# needs both ends: `--no-ff` means the result is a merge COMMIT, and `--ff-only`
# is what lets it authorize a pull whose post-fetch oid it cannot see.
REF_OP_FF_PREFIX = '-ff-mode='


_REF_OP_VALUE_LONG = tuple(o for o in _REF_OP_VALUE_OPTS if o.startswith('--'))
_REF_OP_VALUE_SHORT = frozenset(
    o for o in _REF_OP_VALUE_OPTS if len(o) == 2 and not o.startswith('--'))

# Every long state option, for the same prefix matching. Git abbreviates these as
# freely as it does the value-taking ones, and an exact-match test left a latched
# flag in place: `git merge --squash --no-sq feature` is `--no-squash`, i.e. an
# ordinary merge, but read as an unrecognized flag it stayed "out of scope" and
# was allowed. The negated control forms are included because git generates them.
_MERGE_STATE_LONG = tuple(sorted(
    set(_MERGE_FF_OPTS) | set(_MERGE_SQUASH_OPTS)
    | set(_MERGE_CONTROL_OPTS) | set(_MERGE_CONTROL_NEG)))


def _resolve_state_opt(tok):
    """The state option `tok` names, following unambiguous abbreviation, or ''."""
    if tok in _MERGE_STATE_LONG:
        return tok
    if not tok.startswith('--') or '=' in tok:
        return ''
    hits = [o for o in _MERGE_STATE_LONG if o.startswith(tok)]
    return hits[0] if len(hits) == 1 else ''


# Short options whose argument is OPTIONAL and, when present, ATTACHED. In a
# cluster they make the remainder unreadable: everything after the letter is its
# value, or none of it is, and the command string does not say which.
_REF_OP_OPTARG_SHORT = frozenset(('-S', '-r'))


def _ambiguous_short_cluster(tok):
    """True for a short-option cluster whose reading is not decidable here."""
    if not tok.startswith('-') or tok.startswith('--') or len(tok) <= 2:
        return False
    return any('-' + ch in _REF_OP_OPTARG_SHORT for ch in tok[1:])


def _takes_separate_value(tok):
    """True when `tok` consumes the NEXT token as its value.

    Git accepts any unambiguous ABBREVIATION of a long option, so an exact-token
    set is evadable: `git merge --into reviewed-name feature` is `--into-name`,
    and reading `reviewed-name` as an operand turned a one-head merge into what
    looked like an octopus. A `--`-prefixed token that uniquely prefixes one
    value-taking long option is treated as that option.

    Abbreviations of the OUT-OF-SCOPE families (`--sq` for `--squash`, `--no-f`
    for `--no-ff`) deliberately get no such treatment: unrecognized, they leave
    the invocation IN scope, so the gate evaluates it instead of dismissing it —
    the fail-closed direction."""
    if tok in _REF_OP_VALUE_OPTS:
        return True
    if tok.startswith('--'):
        if '=' in tok:
            return False
        return len([o for o in _REF_OP_VALUE_LONG if o.startswith(tok)]) == 1
    # A CLUSTER of short options: git reads `-vm reviewed` as `-v -m reviewed`,
    # so the cluster consumes the next token whenever a value-taking letter is
    # LAST. Anywhere else the rest of the cluster is that option's attached value
    # (`-mfoo`), and nothing separate is consumed.
    if tok.startswith('-') and len(tok) > 2:
        body = tok[1:]
        for idx, ch in enumerate(body):
            if '-' + ch in _REF_OP_VALUE_SHORT:
                return idx == len(body) - 1
    return False


def _alias_candidates(chunks):
    """Subcommand names in the command that could be config-defined aliases.

    A parser cannot see an alias that lives in a config FILE (`git config
    alias.m merge`, then `git m topic`), but the GATE can: it has the repo and can
    ask `git config --get alias.<name>`. So the detector reports every subcommand
    it does not recognize as read-only or as a merge/pull, and the gate resolves
    them. Real subcommands land here too (`commit`, `push`); they simply have no
    alias entry, so they cost one lookup and nothing else — which is why no list
    of git's own subcommands has to be maintained.

    Names are word-shaped by construction; any carrying whitespace or CR/LF is
    dropped rather than risking the gate's line-delimited protocol. Sorted for a
    stable emission, and capped — see REF_OP_MAX_ALIAS_CANDIDATES."""
    out = set()
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            argv = _command_argv(seg, 'git', wrapper_operands=True)
            if not argv or not _is_exe(argv[0], 'git'):
                continue
            sub = _git_subcommand(argv)[0]
            if sub is None or sub in _REF_SAFE_SUBS or sub in _REF_OP_SUBS:
                continue
            if re.search(r'\s', sub):
                continue
            out.add(sub)
    return sorted(out)[:REF_OP_MAX_ALIAS_CANDIDATES + 1]


# Commands whose OPERANDS are environment names or assignments, so the whole
# segment has to be read rather than just its leading prefix.
# Verbs whose effect OUTLIVES their own segment — `export GIT_DIR=… && git merge`
# reaches the merge. Split from the PREFIX forms (`env X=1 cmd`, `X=1 cmd`), whose
# assignment applies to that one command only: treating both as whole-command
# blocked `HOME=/tmp git status && git merge topic`, where HOME never reaches the
# merge at all.
_ENV_PERSIST_VERBS = frozenset(('export', 'unset', 'declare', 'typeset',
                                'local', 'readonly', 'setenv', 'set'))



def _env_assignment_toks(seg):
    """The tokens of `seg` that are genuinely environment assignments.

    Reading EVERY token was wrong in the other direction: `git merge PATH=reviewed`
    merges a ref legitimately named `PATH=reviewed`, and matching it as an
    assignment blocked that merge outright. A bash assignment prefix is the
    LEADING run of assignment-shaped words; only for the env verbs does the rest
    of the segment carry them too."""
    toks = toks_once(seg)
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if _ASSIGN_TOK_RE.match(t) or _ENV_ASSIGN_TOK_RE.match(t):
            out.append(t)
            i += 1
            continue
        base = _bn_tok(t)
        if base in _ENV_PERSIST_VERBS:
            # `export`/`unset` take NAMES or assignments as operands, so the whole
            # segment is environment. `env` deliberately does NOT: its operands
            # after the utility name belong to that utility, and reading them all
            # made `env git merge PATH=reviewed` treat a legitimate ref as an
            # assignment. It falls through to the wrapper branch instead.
            return toks
        if base in _WRAPPERS or base in _OPERAND_WRAPPERS or t.startswith('-'):
            # A wrapper or one of its options — `command env GIT_DIR=… git merge`
            # is still an assignment prefix, and stopping at `command` hid it.
            i += 1
            continue
        break      # the command word: anything after it is an operand
    return out


def _seg_env_scope(seg):
    """True when THIS segment's own command carries a scope/config assignment
    prefix (`GIT_DIR=… git merge x`, `env -i git merge x`)."""
    return any(_GIT_SCOPE_ENV_RE.match(t) for t in _env_assignment_toks(seg))


def _has_scope_change(chunks):
    """True when the command moves the repo the gate would query.

    _alias_candidates reports NAMES only, with no scope attached, and the gate
    resolves them against one repository. `cd /other && git m topic` and
    `git -C /other m topic` would send it to the wrong one — where a repo-local
    `alias.m = merge` is invisible — so a scoped command is refused instead."""
    for chunk in chunks:
        if _all_cds(chunk):
            return True
        for _op, seg in split_segments(chunk):
            argv = _command_argv(seg, 'git', wrapper_operands=True)
            if argv and _is_exe(argv[0], 'git') \
               and '-C' in argv[1:_git_subcommand(argv)[1]]:
                return True
    return False


def _has_git_scope_env(chunks):
    """True when a scope/config assignment OUTLIVES its own segment.

    Only the persisting forms: `export GIT_DIR=/other/.git && git merge topic`
    reaches the merge, and so does a bare `GIT_DIR=/x` statement. A PREFIX
    assignment binds one command, so it is checked per-segment by _seg_env_scope
    instead — reading it whole-command blocked `HOME=/tmp git status && git merge
    topic`, where HOME never reaches the merge."""
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            toks = toks_once(seg)
            if not toks:
                continue
            persists = (_bn_tok(toks[0]) in _ENV_PERSIST_VERBS
                        or all(_ASSIGN_TOK_RE.match(t) for t in toks))
            if persists and _seg_env_scope(seg):
                return True
    return False


def _has_ref_op_candidate(chunks):
    """True when the command carries a git invocation that IS, or could be aliased
    to, a merge or a pull.

    Anything not provably read-only counts, because an alias can put a merge
    behind any name. Paired with _has_git_scope_env this is what keeps the
    fail-closed refusal off ordinary inspection: `GIT_DIR=/other git log` stays
    allowed, `GIT_CONFIG_KEY_0=alias.m … git m topic` does not."""
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            argv = _command_argv(seg, 'git', wrapper_operands=True)
            if argv and _is_exe(argv[0], 'git') \
               and _git_subcommand(argv)[0] not in _REF_SAFE_SUBS:
                return True
    return False


def _has_unaccounted_global(argv, sub_idx):
    """True when the pre-subcommand globals contain anything but a bare `-C`.

    Walks the option region pairing `-C` with its value so the path operand is
    not itself read as an option — `git -C /repo merge x` must stay resolvable,
    which is the whole point of the exemption."""
    k = 1
    while k < sub_idx:
        if argv[k] == '-C':
            k += 2
            continue
        if _is_git_scope_opt(argv[k]):
            return True
        k += 1
    return False


def _bn_tok(tok):
    """Basename of a possibly-path-spelled command word (/usr/bin/sudo -> sudo)."""
    return tok.rsplit('/', 1)[-1]


def _is_wrapper_chdir_opt(tok):
    """True for anything in a wrapper prefix the gate cannot account for.

    ANY option, not an enumeration — the same inversion as
    _has_unaccounted_global, and for the same reason. Naming the dangerous ones
    (`env -C`, `env -u`, `env -i`, `sudo -H`, `command -p`) meant also naming
    every spelling of each: attached (`-C/other`), long (`--chdir=/other`), and
    GNU's unambiguous ABBREVIATIONS (`--chd=/other`, `--igno`, `--uns=HOME`).
    Each round closed one and left the next. A wrapper option this gate has not
    reasoned about is unresolvable, full stop; the cost is an over-strict block on
    a harmless `nice -n 5`, which does not appear before a protected-branch merge.

    Identity wrappers are matched by NAME too: `sudo git merge` needs no option to
    give git a different HOME, and therefore different config and aliases."""
    if _bn_tok(tok) in _IDENTITY_WRAPPERS:
        return True
    return tok.startswith('-') and tok != '-'


def _wrapper_chdir_in_prefix(seg, argv):
    """True when a chdir-ing wrapper option precedes the git command word.

    argv is a SUFFIX of the segment's tokens, so the difference in length is the
    command word's index — the same arithmetic _torn_direct_hits relies on. Erring
    by one token includes a neighbour, which is the fail-CLOSED direction."""
    if not argv:
        return False
    toks = toks_once(seg)
    return any(_is_wrapper_chdir_opt(t)
               for t in toks[:max(0, len(toks) - len(argv))])


def _ref_op_operands(argv, raw_argv, sub_idx, sub):
    """(operands, in_scope) for the argv of a `git merge` / `git pull`.

    in_scope is False for a merge form that cannot fast-forward a ref: an
    in-progress-merge control (_MERGE_CONTROL_OPTS), a squash, or a forced merge
    commit. The ff and squash families are read LAST-WINS, exactly as git applies
    them, so a later flag can put an invocation back in scope — see
    _MERGE_FF_OPTS. Operands are the non-flag words after the subcommand, with
    each known separate-value option's value skipped.

    An operand that could OPEN a live substitution is replaced by
    REF_OP_UNRESOLVABLE. Unlike the `cd`/`-C` targets, no literal-vs-live
    distinction is drawn here: a ref genuinely named `$(x)` does not occur, so
    treating BOTH spellings as unresolvable costs nothing and removes the
    quote-reconstruction surface entirely. CR/LF is rejected outright for the same
    positional-protocol reason as _reject_crlf's other callers — the gate prints
    these operands as lines."""
    ops = []
    skip = False
    ff = ''
    squash = False
    controls = set()
    unknown_long = False
    end_of_opts = False
    for i in range(sub_idx + 1, len(argv)):
        a = argv[i]
        _raw_i = _raw_spelling(raw_argv, i)
        # BEFORE any option handling, because every branch below that recognizes
        # an option ends in `continue` — and a discarded token that can become
        # more than one word takes the operand COUNT with it. The separate-value
        # form is not the only one: `--message=$MSG` and `-m$MSG` carry the value
        # attached, and `--message {note,B}` splits through brace expansion with
        # no substitution character at all. Each turns a one-head merge into two
        # heads git reduces, so a marker minted for the head the parser saw
        # authorizes the commit it did not.
        # A redirection is removed by the SHELL before git sees the command, so it
        # is checked BEFORE the pending-value skip. `git merge -m >/dev/null x`
        # gives git `-m x`, not `-m >/dev/null`; consuming the redirection as the
        # value made `x` look like the merge head while git merged @{upstream}.
        # Which token is the value is not readable here, so neither is assumed.
        if skip and _raw_i is not None and _raw_i == a and _REDIR_RE.match(a):
            ops.append(REF_OP_UNRESOLVABLE)
            skip = False
            continue
        if skip:
            skip = False
            # A value that may be a substitution is not one word. Skipped
            # silently, `git merge --ff-only --message $MSG A` looked like a
            # one-head merge of A, while `MSG='note B'` makes git see the heads
            # B and A, reduce them to B, and fast-forward there — spending a
            # marker minted for A on a commit nobody authorized. Poison the
            # invocation instead: the operand list is no longer knowable.
            if _word_may_split(a, _raw_i):
                ops.append(REF_OP_UNRESOLVABLE)
            continue
        # AFTER the pending-value branch above, which consumes an option's value
        # whatever it is spelled like. Running first, this read the literal value
        # `-$MSG` of `--message` as an option NAME and poisoned an out-of-scope
        # merge that was never in question.
        # `_word_may_split` asks whether the word COUNT can change. An option has a
        # second way to betray the parser: `--"$MODE"` and `--$'ff-only'` stay one
        # word while becoming a DIFFERENT OPTION — with MODE=ff-only bash hands git
        # a later `--ff-only`, and the merge this parser reported out of scope
        # fast-forwards. Only the name matters, so the test stops at the first
        # `=`: `--message=$MSG` names `--message` whatever the value expands to.
        # The NAME stops where the value starts, in both spellings. Splitting
        # only on `=` left a short option's ATTACHED value inside the name, so
        # `-m"$MSG"` — a static `-m` with a quoted one-word value — read as a
        # dynamic option and blocked an ordinary non-fast-forward merge. The
        # attached form is recognised only for the short options this parser
        # knows TAKE a value; anything else keeps the whole token as its name,
        # so `-v$X`, where the expansion could add option letters, still counts.
        _optname = a.split('=', 1)[0]
        if len(a) > 2 and a[1] != '-' and a[:2] in _REF_OP_VALUE_SHORT:
            _optname = a[:2]
        if not end_of_opts and a.startswith('-') and a != '-' \
           and (_word_may_split(a, _raw_i) or _may_be_substitution(_optname)):
            ops.append(REF_OP_UNRESOLVABLE)
            skip = False
            continue
        # Shell syntax vs. a ref that merely LOOKS like it. Tokenization has
        # erased quoting, so `git merge '#topic'` and `git merge '>topic'` arrive
        # identical to a comment and a redirection — and dropping them left NO
        # operand, which makes the gate resolve @{upstream} instead of the ref git
        # will actually merge. Ask the raw spelling: quoted means it is a ref.
        _raw = _raw_i
        if _raw is None:
            # Spellings could not be aligned, so quoted and bare are
            # indistinguishable here. Neither reading may be assumed.
            ops.append(REF_OP_UNRESOLVABLE)
            continue
        if _raw == a:
            if a.startswith('#'):
                break      # the rest of the segment is a comment, not operands
            if _REDIR_RE.match(a):
                # A redirection, plus its target when that is a separate token.
                skip = bool(_REDIR_BARE_RE.match(a))
                continue
        if end_of_opts:
            # Past `--` every word is a ref, whatever it is spelled like: a
            # lightweight tag really can be named `--no-ff`, and reading it as
            # the OPTION reported the merge out of scope.
            _reject_crlf(a, 'git ref operand')
            # A ref may legally be spelled like the fast-forward METADATA the
            # emitter appends to this same list, and after `--` git accepts it.
            # `git merge -- -ff-mode=--ff-only` then had its only operand stripped
            # as metadata and read as a bare merge of @{upstream}. Sharing a
            # namespace is the bug; refusing the collision is the fix, and a ref
            # actually named that is pathological.
            ops.append(REF_OP_UNRESOLVABLE
                       if (_may_be_substitution(a) or _word_may_split(a, _raw_i)
                           or a.startswith(REF_OP_FF_PREFIX))
                       else a)
            continue
        if a == '--':
            end_of_opts = True
            continue
        if _ambiguous_short_cluster(a):
            # A cluster carrying an option whose argument is OPTIONAL and
            # attached: `git merge -Sm reviewed` is `-S` signing with key `m`,
            # leaving `reviewed` as the head — but read letter-by-letter the
            # trailing `m` is `-m` and swallows it. The two readings disagree
            # about the merge target, so neither is used.
            ops.append(REF_OP_UNRESOLVABLE)
            continue
        if _takes_separate_value(a):
            skip = True
            continue
        state = _resolve_state_opt(a)
        if state in _MERGE_CONTROL_OPTS:
            controls.add(state)
            continue
        if state in _MERGE_CONTROL_NEG:
            controls.discard('--' + state[len('--no-'):])
            continue
        if state in _MERGE_FF_OPTS:
            ff = state
            continue
        if state in _MERGE_SQUASH_OPTS:
            squash = (state == '--squash')
            continue
        if a.startswith('-') and a != '-':
            # An AMBIGUOUS abbreviation of a state option — a `--` token with no
            # attached value that prefixes more than one of them, which
            # _resolve_state_opt therefore refused to resolve. The latch it might
            # have set can no longer be trusted, so drop it and let the gate
            # evaluate the merge: an over-strict block rather than a missed one.
            # Scoped to that case on purpose. Setting it for EVERY unrecognized
            # long option cancelled correct state on ordinary commands —
            # `git merge --squash --no-commit x` and `--no-ff --strategy=ours x`
            # are not fast-forwards and must stay out of scope.
            if a.startswith('--') and '=' not in a \
               and any(o.startswith(a) for o in _MERGE_STATE_LONG):
                unknown_long = True
            continue
        _reject_crlf(a, 'git ref operand')
        ops.append(REF_OP_UNRESOLVABLE
                   if (_may_be_substitution(a) or _word_may_split(a, _raw_i)
                       or a.startswith(REF_OP_FF_PREFIX))
                   else a)
    # MERGE only. A `pull` with --squash or --no-ff still FETCHES, so it still
    # moves FETCH_HEAD and the remote-tracking refs — dropping it from the
    # operation set let `git pull --squash origin feature && git merge
    # origin/feature` authorize the merge against the value the pull was about to
    # replace. Those flags change what a pull does with the content it fetched,
    # never whether it fetches.
    # ...and only when every operand was readable. The out-of-scope exit reports
    # NO operation, which discards the unresolvable sentinel with it: `git merge
    # --no-ff $MODE feature` looked like a plain merge-commit shape, while an
    # ambient `MODE=--ff-only` is applied LAST by git and fast-forwards the
    # protected branch. An option this parser could not read may be the one that
    # decides the shape, so the shape is not decided here.
    if sub == 'merge' and REF_OP_UNRESOLVABLE not in ops and not unknown_long \
       and (controls or squash or ff == '--no-ff'):
        return [], False
    # A PULL stays in scope whatever its ff mode (it still fetches, see above),
    # but the gate has to KNOW that mode: `--no-ff` makes the result a merge
    # commit, and `--ff-only` is the only form whose outcome the gate can vouch
    # for without seeing the post-fetch oid.
    return ops, ((REF_OP_FF_PREFIX + ff) if ff else True)


# ── THREAT MODEL for the ref-op detector (#779) ──────────────────────────────
# The SAME boundary this module's docstring sets for git_commit and gh_pr, restated
# here because the ref-op surface invites the question repeatedly.
#
# IN SCOPE — the routine or accidental bypass. An agent (or a person) reaches for
# `git merge feature` / `git pull` on the protected branch because it is the
# obvious next command, not to defeat anything. Everything the detector and gate
# do is aimed here, and the bar is that no ordinary spelling of that operation
# slips past: option abbreviations, negated flags, `--`, quote-splitting, `-C`,
# a companion command, a config-file alias.
#
# OUT OF SCOPE — the deliberate evader with shell access, who can always win
# against a command-string parser and does not need any of these shapes to do it:
# an interpreter payload (`bash -c`, `python3 -c subprocess.run`), a script file,
# a dispatcher (`xargs`, `find -exec`), process substitution, or repo/global
# config planted by an EARLIER, separately-gated command. Closing individual
# members of that class buys nothing — the next member is always one line away —
# so they are ACCEPTED RESIDUALS, identically to the ones the module docstring
# already lists. What the gate provides against such an actor is a record, not a
# barrier: every authorization it grants is logged.
#
# The practical rule when a new finding arrives: reachable by a command someone
# would type WITHOUT meaning to bypass the gate → fix it. Requires deliberate
# evasion → it is answered by this boundary, not by more code. And prefer a fix
# that REMOVES an enumeration (as _has_companion_command replaced a denylist of
# ref-writing subcommands) over one that extends a list — only the former shrinks
# the surface the next reader has to check.
# ─────────────────────────────────────────────────────────────────────────────


def _iter_ref_op(chunk, allow_cd):
    """Yield one result tuple per `git merge` / `git pull` command word in `chunk`.
    allow_cd=False for substitution bodies (subshell cwd untrusted).

    A near-mirror of _scan_commit — read the reasoning for cd trust, torn-assignment
    recovery and global `-C` resolution there; the only differences are the
    subcommand set and that operands are collected instead of amend-ness.

    EVERY match is yielded, not just the first, because unlike `git commit` the
    operations in one command are not interchangeable: `git merge HEAD && git merge
    feature` opens with a NO-OP that the gate rightly allows, and stopping there
    let the second one fast-forward the protected branch unseen. The gate counts
    what this yields and refuses a command carrying more than one (see
    git_ref_op's n_ops); the first match still supplies the scope and operands."""
    pending_cd = None
    pending_cd_op = ''
    # EVERY cd seen, never reset by intervening commands — see _untrusted_cd.
    cds = []
    for op, seg in split_segments(chunk):
        cd = _record_cds(seg, cds)
        if cd is not None:
            pending_cd = cd           # strict form only: feeds the TRUSTED path
            pending_cd_op = op
            continue
        argv, raw_argv = _command_argv(seg, 'git', with_raw=True,
                                       wrapper_operands=True)
        # Recovery FIRST, with the same ordering, windowing and rationale as
        # _scan_commit: a tear anywhere in the prefix makes every argv POSITION
        # untrustworthy, so neither the repo scope nor the operands can be read.
        # Report _TORN_SCOPE and an unresolvable operand; the gate then stalls
        # rather than acting on a fabricated repo or ref.
        _hits = list(_torn_direct_hits(seg, 'git', argv))
        _all = _hits[0][0] if _hits else ()
        _starts = [_k for _t, _k in _hits]
        for _i, _k in enumerate(_starts):
            _end = _starts[_i + 1] if _i + 1 < len(_starts) else len(_all)
            _sub = _git_subcommand(_all[_k:_end])[0]
            if _sub in _REF_OP_SUBS:
                yield (_sub, '', [REF_OP_UNRESOLVABLE], _TORN_SCOPE, False)
                _torn = True
                break
        else:
            _torn = False
        if _torn:
            pending_cd = None
            continue
        if argv and _bn_tok(argv[0]) in _IDENTITY_WRAPPERS \
           and any(_is_exe(t, 'git') for t in argv[1:]):
            # `_command_argv` walks past the wrappers IT knows; runuser, setpriv
            # and su are not among them, so `setpriv --no-new-privs git merge
            # topic` never reached the prefix check and produced NO operation at
            # all — a fail-OPEN, not an over-block. Their grammars are not
            # re-implemented here, so a git command behind one is unresolvable.
            yield ('merge', '', [REF_OP_UNRESOLVABLE], '', False)
            pending_cd = None
            continue
        if not argv or not _is_exe(argv[0], 'git'):
            pending_cd = None
            continue
        sub, sub_idx = _git_subcommand(argv)
        if sub not in _REF_OP_SUBS:
            # A config override ON THIS COMMAND LINE can spell a merge or a pull
            # under any name, so an unrecognized subcommand there is unresolvable
            # rather than absent. The test is the SAME scope-option set used for
            # recognized subcommands, not an `alias.`-key match: `-c
            # include.path=/tmp/aliases` defines the alias INDIRECTLY, and so does
            # any --git-dir/--config-env pointing at a config that does. The kind
            # is nominal: the gate refuses on the unresolvable operand before it
            # ever branches on kind.
            if sub is not None and sub not in _REF_SAFE_SUBS and (
                    _has_unaccounted_global(argv, sub_idx)
                    or _wrapper_chdir_in_prefix(seg, argv)
                    or _seg_env_scope(seg)):
                yield ('merge', '', [REF_OP_UNRESOLVABLE], '', False)
            pending_cd = None
            continue
        ops, in_scope = _ref_op_operands(argv, raw_argv, sub_idx, sub)
        if not in_scope:
            pending_cd = None
            continue
        if isinstance(in_scope, str) and in_scope.startswith(REF_OP_FF_PREFIX):
            ops = list(ops) + [in_scope]
        # A pre-subcommand global — or a GIT_* environment assignment — that
        # redirects the repo or rewrites the config the gate is about to read
        # makes every answer it computes describe the WRONG repository. Report it
        # as unresolvable rather than resolving the cwd's refs and calling that an
        # authorization. Both option spellings are checked (`--git-dir /d` and
        # `--git-dir=/d`), and the env form is read from the raw segment because
        # _command_argv has already stripped it out of argv.
        if _has_unaccounted_global(argv, sub_idx) \
           or _wrapper_chdir_in_prefix(seg, argv) or _seg_env_scope(seg):
            ops = [REF_OP_UNRESOLVABLE]
        base = _trusted_cd(pending_cd, op) if allow_cd else ''
        base, authoritative, tilde_c, nested_c = _apply_global_c(
            argv, raw_argv, sub_idx, base,
            _cd_authoritative(base, pending_cd_op, cds), allow_cd)
        # 5th element is git_ref_op's nested-payload suppression flag, exactly as
        # in _scan_commit; no caller outside this module sees it.
        yield (sub, base, ops,
               _commit_untrusted(cds, allow_cd, authoritative, tilde_c, nested_c),
               authoritative)
        pending_cd = None


def _scan_ref_op(chunk, allow_cd):
    """First `git merge` / `git pull` in `chunk`, or None."""
    return next(_iter_ref_op(chunk, allow_cd), None)


def _count_ref_ops(chunks):
    """How many `git merge` / `git pull` operations the whole command carries.

    Counted over the same chunks and with the same allow_cd split as the scan, so
    a command whose only match sits in a substitution body is counted once, not
    twice. The gate refuses anything above 1 — see _iter_ref_op."""
    return (len(list(_iter_ref_op(chunks[0], True)))
            + sum(len(list(_iter_ref_op(c, False))) for c in chunks[1:]))


def _has_companion_command(chunks):
    """True when the command runs anything BESIDES the merge/pull and `cd`.

    Replaces an enumeration of ref-writing subcommands, which could not be
    completed: `git branch -f`, `git config`, `git fast-import`, `git difftool`,
    `git grep --open-files-in-pager=<cmd>`, `unset HOME`, a shell script, a
    python one-liner — each arrived as a fresh instance of ONE fact. The gate
    resolves its merge target and reads git config at PreToolUse time, so ANY
    other command in the same invocation can replace what it checked before the
    merge runs. Asking "is there another command at all" answers the class, and
    is both smaller and complete where a denylist was neither.

    `cd` is the sole exemption: it only scopes the command that follows, and the
    resolver already accounts for it. Nested chunks count too — a substitution
    body executes.

    The cost is that `git status && git merge origin/main` must be split into two
    calls ON THE PROTECTED BRANCH. That is the same advice the gate already gives
    for fetch-then-merge, and it applies nowhere else."""
    n = 0
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            if not seg.strip():
                continue
            if _record_cds(seg, []) is not None and not _seg_env_scope(seg):
                # A plain `cd` only scopes the command that follows. One carrying
                # a scope assignment (CDPATH) does more than that, so it does not
                # get the exemption.
                continue
            _t = toks_once(seg)
            if not _t or all(_REDIR_ARTIFACT_RE.match(x) for x in _t):
                continue   # redirection debris, not a command
            n += 1
            if n > 1:
                return True
    return False


# What GIT refuses in a ref name, not what Python calls whitespace. `\s` matches
# U+00A0 and friends, which `git check-ref-format` ACCEPTS -- so a protected
# branch containing one was dropped from the word list and never matched, a
# fail-OPEN reachable by declaring such a name. ASCII space, the control range
# and DEL are the characters git actually rejects.
_REF_CREATE_IMPLAUSIBLE_RE = re.compile(r'[ \x00-\x1f\x7f]')

# A ref-writing git command reached as its own executable rather than as a
# subcommand word: `$(git --exec-path)/git-branch master <oid>` runs the same
# builtin while naming no `git <sub>` the alias scan can report.
_REF_CREATE_GIT_EXE_RE = re.compile(r'^git-[a-z][a-z0-9-]*$')


def git_ref_create(cmd):
    """The ref-plausible WORDS of a command, and its one authorizable creation
    shape (#781).

    THE CLASS, NOT A GRAMMAR. `git branch`, `checkout -b/-B`, `switch -c/-C`,
    `update-ref`, `worktree add -b` and DWIM `checkout <name>` all create a ref,
    each with its own option grammar, and extracting "the name being created"
    from any of them mis-parses toward ALLOW: one separate-value option this
    module does not know about shifts the operand and the gate checks the wrong
    word. Reporting EVERY word instead over-approximates toward BLOCK -- whichever
    operand carries the name, it IS one of these words -- so the gate can decide
    by set membership against the protected names it discovers, with no grammar
    here to get wrong. Same move, and the same fail-closed reason, as
    _has_companion_command.

    Returns (canon_name, canon_oid, tokens, opts, opaque, git_exe, symref,
             fetch_spec, unreadable):
      canon_name  set only when the WHOLE command is exactly the one authorizable
                  creation shape, `git branch <name> <start>` (a leading plain
                  `cd` aside, which only scopes it). Anything else leaves it '',
                  and the gate then offers no marker route -- recognizing one
                  exact shape is an allowlist, so a shape this misses fails
                  CLOSED. `refs/heads/<name>` is reported as `<name>`.
      canon_oid   that shape's start-point word, for the gate to bind a marker to
                  once it has checked the word resolves to itself.
      tokens      every word that could name a ref, deduplicated and in command
                  order, each with any `refs/heads/` prefix already stripped. A
                  word carrying whitespace or a control character is dropped (git
                  accepts neither in a ref name) and so is a `-`-leading one (no
                  option is a start point). The gate matches protected names
                  against this list and resolves it to prove a creation inert;
                  it is NOT capped here, because a cap would silently drop a name
                  from the MATCH -- the gate bounds its own resolving loop and
                  refuses rather than examining a subset.
      opts        the `-`-leading words, which are NOT start points but CAN carry
                  the created name ATTACHED: `git checkout -bmaster <oid>`,
                  `-Bmaster`, `switch -cmaster`, a clustered `-qbmaster`, and
                  `--create=master` all create `master` while emitting no
                  `master` word of their own. Dropping them outright was a
                  fail-OPEN. The gate tests each protected name as a SUFFIX of
                  these, which over-matches (`--no-main` would too) in the
                  blocking direction and needs no table of which git options take
                  an attached value.
      opaque      why this command writes refs the word scan cannot name, or ''
                  when it does not. Two values, both refused outright wherever a
                  protected name could be created, because there is nothing to
                  match against:
                    'stdin'    `git update-ref` or `git fetch` with
                               `--stdin`/`-z` -- ANY accepted abbreviation of
                               `--stdin`, since git takes them all -- reads its
                               ref names from data (`printf 'create
                               refs/heads/master <oid>' | git update-ref --stdin`
                               names the ref inside one quoted word).
                    'stream'   `git fast-import`, whose stream carries its own
                               `reset refs/heads/<name>` commands, and the push
                               plumbing that takes ref updates over its protocol
                               rather than as words: `git send-pack --stdin` and
                               any `git receive-pack`.
                    'wildcard' a refspec whose DESTINATION carries a `*` and is
                               not under refs/remotes/ or refs/tags/, so it can
                               expand to refs/heads/<anything>: `git fetch origin
                               'refs/heads/*:refs/heads/*'` creates every absent
                               branch and names none of them. The ordinary
                               `+refs/heads/*:refs/remotes/origin/*` writes no
                               local branch and is not refused.
      symref      True when the command runs `git symbolic-ref`. A symbolic ref
                  points at a NAME, so a protected branch created as one carries
                  whatever its target holds LATER -- `git symbolic-ref
                  refs/heads/master refs/heads/staging` against an absent
                  `staging` vouches for nothing today, and the `git update-ref
                  refs/heads/staging <unreviewed>` that follows names no
                  protected branch at all. The gate refuses the shape once it
                  names an absent protected branch, rather than trying to vouch
                  for a target that does not exist yet.
      fetch_spec  True when a `fetch` carries a refspec whose destination is not
                  under refs/remotes/ or refs/tags/, so it can write a local
                  branch. Its SOURCE is resolved in the REMOTE repository, which
                  means the word looks vouchable here and is not: `git fetch evil
                  main:refs/heads/master` passes a local `main` that is reachable
                  from a protected branch while git lands `evil`'s `main`.
                  Authenticating a remote source is what ADR 0050 already
                  rejected as unachievable, so the shape is refused once its
                  destination names an absent protected branch.
      unreadable  True when a word was dropped for carrying whitespace. Such a
                  word cannot be a REF NAME, which is why it is not matched — but
                  it can be a REVISION (`git branch master ':/unreviewed
                  subject'` finds a commit by its message), so it can also be the
                  start point, and dropping it left a vouched HEAD as the only
                  evidence. The gate refuses rather than vouching on an
                  incomplete list, and only once a protected name is matched, so
                  an ordinary quoted commit message costs nothing.
      git_exe     True when a word names a git builtin as its own EXECUTABLE
                  (`git-branch`, `.../git-core/git-update-ref`). Such a command
                  contains no `git <subcommand>` pair, so the gate would exit
                  before looking at its words; this is what keeps it looking.
                  Every subcommand test above is run over the same normalization,
                  so `git-update-ref --stdin` and `git-worktree add <path>` reach
                  the same rules their subcommand spellings do.

    RESIDUAL, and the standing one every command-string parser here carries: a
    name reached through a substitution or a variable (`git branch $B <oid>`) is
    not a literal word and is not reported. That is the THREAT MODEL's deliberate
    evader, not the routine command this gate is the observation point for."""
    chunks = _all_chunks(cmd)
    seen = []
    opts = []
    argvs = []
    opaque = ''
    git_exe = False
    symref = False
    fetch_spec = False
    unreadable = False

    def _add(w):
        w = w[len('refs/heads/'):] if w.startswith('refs/heads/') else w
        if w and w not in seen:
            seen.append(w)
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            if not seg.strip():
                continue
            if _record_cds(seg, []) is not None and not _seg_env_scope(seg):
                continue      # a plain `cd` only scopes what follows
            toks = toks_once(seg)
            if not toks or all(_REDIR_ARTIFACT_RE.match(x) for x in toks):
                continue      # redirection debris, not a command
            argvs.append(toks)
            # `git <sub>` and the standalone `git-<sub>` executable are the same
            # builtin, so every subcommand test below runs over the NORMALIZED
            # words: `/path/git-core/git-update-ref --stdin` and `git-worktree
            # add ../master` reach the same rules as their subcommand spellings,
            # and testing the raw words let both walk past.
            ntoks = [(_x.rsplit('/', 1)[-1][4:]
                      if _REF_CREATE_GIT_EXE_RE.match(_x.rsplit('/', 1)[-1])
                      else _x)
                     for _x in toks]
            if 'symbolic-ref' in ntoks:
                symref = True
            if ('fast-import' in ntoks or 'receive-pack' in ntoks
                    or ('send-pack' in ntoks
                        and any(t.startswith('--') and len(t) > 2
                                and '--stdin'.startswith(t) for t in toks))):
                # A fast-import stream carries its own `reset refs/heads/<name>`
                # commands; send-pack --stdin and receive-pack take their ref
                # updates over the push protocol. There is no word to match in
                # any of them, exactly as with update-ref --stdin.
                opaque = opaque or 'stream'
            if ('update-ref' in ntoks or 'fetch' in ntoks) and any(
                    t == '-z' or (t.startswith('--') and len(t) > 2
                                  and '--stdin'.startswith(t))
                    for t in toks):
                # EVERY accepted spelling, not the canonical one. git's
                # parse-options takes any unambiguous long-option prefix, so
                # `--std` and `--stdi` read the same opaque input that `--stdin`
                # does; matching the full word only was a fail-OPEN.
                opaque = opaque or 'stdin'
            # `git worktree add <path>` with no -b/-B/--detach and no commit-ish
            # DERIVES the new branch name from the path's final component, so
            # `git worktree add ../master` creates `master` while the command
            # contains no `master` word. Scoped to this subcommand deliberately:
            # it is the only git command that names a branch after a path, and
            # taking the basename of every `/`-bearing word everywhere would
            # block ordinary `git add config/default`.
            _wt = 'worktree' in ntoks and 'add' in ntoks
            # Git DERIVES a local branch name from a path or a remote-tracking
            # operand in this family too: `worktree add ../master`, and
            # `checkout --track origin/master` / `switch -t origin/master`,
            # each create `master` while the command carries no such word.
            _derive = _wt or 'checkout' in ntoks or 'switch' in ntoks
            for t in toks:
                if _REF_CREATE_IMPLAUSIBLE_RE.search(t):
                    if not t.startswith('-'):
                        unreadable = True
                    continue
                if t == '-' and _derive:
                    # A LONE `-` is not an option to checkout/switch: it is
                    # `@{-1}`, the previous checkout. Dropping it with the other
                    # `-`-leading words left `git checkout -b master -` vouched by
                    # HEAD alone while the branch it creates lands wherever that
                    # previous checkout was.
                    _add('@{-1}')
                    continue
                if t.startswith('-'):
                    if t not in opts:
                        opts.append(t)
                    continue
                if _REF_CREATE_GIT_EXE_RE.match(t.rsplit('/', 1)[-1]):
                    git_exe = True
                _add(t)
                if ':' in t:
                    # A `*` in the DESTINATION half expands to ref names no word
                    # here can spell. refs/remotes/ and refs/tags/ cannot become
                    # a local branch, so the ordinary fetch refspec is untouched.
                    _dst = t.rsplit(':', 1)[-1].lstrip('+')
                    _local_dst = not _dst.startswith(('refs/remotes/',
                                                      'refs/tags/'))
                    if '*' in _dst and _local_dst:
                        opaque = opaque or 'wildcard'
                    if _local_dst and 'fetch' in ntoks:
                        fetch_spec = True
                    # A COLON REFSPEC writes a ref with no checkout:
                    # `git push . HEAD:refs/heads/master` and `git fetch .
                    # feature:refs/heads/master` both CREATE `master`, and the
                    # whole refspec is one word that matches no protected name.
                    # Both halves are reported -- the destination is the name
                    # being created, the source is the content it would carry.
                    # `lstrip('+')` because a refspec may be force-prefixed:
                    # `+<oid>:refs/heads/master` left the SOURCE as `+<oid>`,
                    # which resolves to no commit, so the unreviewed content it
                    # names was skipped and a vouched HEAD made the creation read
                    # as inert.
                    for part in t.split(':'):
                        _add(part.lstrip('+'))
                if _derive:
                    bare = (t[len('refs/heads/'):]
                            if t.startswith('refs/heads/') else t)
                    _add(bare.rstrip('/').rsplit('/', 1)[-1])
    canon_name = canon_oid = ''
    if len(chunks) == 1 and len(argvs) == 1 and len(argvs[0]) == 4:
        a = argvs[0]
        bare = (a[2][len('refs/heads/'):]
                if a[2].startswith('refs/heads/') else a[2])
        if _is_exe(a[0], 'git') and a[1] == 'branch' and bare \
           and not _REF_CREATE_IMPLAUSIBLE_RE.search(a[2]) \
           and not _REF_CREATE_IMPLAUSIBLE_RE.search(a[3]) \
           and not a[3].startswith('-'):
            canon_name, canon_oid = bare, a[3]
    return (canon_name, canon_oid, seen, opts, opaque, git_exe, symref,
            fetch_spec, unreadable)


def git_ref_op(cmd, with_untrusted_cd=False):
    """Detect a `git merge` / `git pull` that can FAST-FORWARD a branch ref (#779).

    Returns (kind, target_dir, operands), plus (untrusted_cd, n_ops, ref_writer)
    when with_untrusted_cd=True — the same contract and the same chunk folding as
    git_commit, extended by the two whole-command facts the gate needs. kind is
    'merge', 'pull', or '' when neither is present.

    n_ops is how many merge/pull operations the WHOLE command carries, and the
    gate blocks above 1. git_commit's "first match wins" residual is tolerable
    because every match there is still a `git commit` the marker check covers;
    here the first operation can be a deliberate no-op (`git merge HEAD`) that
    the gate allows, which would wave the real one through behind it.

    ref_writer is True when the command also carries a ref-writing or
    config-rewriting git subcommand (anything outside _REF_SAFE_SUBS); the gate
    blocks on it, because what it resolves at PreToolUse time would be replaced
    before the merge runs.

    aliases lists the subcommand names the parser did not recognize, for the gate
    to resolve against `git config --get alias.<name>` — the one part of the
    alias problem a command-string parser cannot answer on its own. It is
    populated even when kind is '', which is precisely the config-file-alias
    case.

    A fast-forward creates no commit object, so no commit-oriented gate observes
    it; this is what lets ref-ff-gate.sh see the ref move before it happens."""
    chunks = _all_chunks(cmd)
    # A git scope/config override in the environment makes every repo-derived
    # answer describe the wrong repository — and GIT_CONFIG_KEY_0=alias.m puts a
    # merge behind a name no parser can recognize, so the subcommand word cannot
    # be trusted either. Decided over the WHOLE command (an `export` in an earlier
    # segment reaches the merge) and before the scan, because the scan's own
    # recognition is what the override defeats.
    if with_untrusted_cd and _has_git_scope_env(chunks) \
       and _has_ref_op_candidate(chunks):
        return ('merge', '', [REF_OP_UNRESOLVABLE], '', 1, False, [])
    r = _scan_ref_op(chunks[0], True)
    if r:
        # See git_commit: a CURRENT-SHELL payload changes the cwd of the very chunk
        # we matched in, and an AUTHORITATIVE target is never overridden.
        nested = [] if r[4] else [c for chunk in chunks[1:] for c in _all_cds(chunk)]
        r = (r[0], r[1], r[2],
             _untrusted_cd(([r[3]] if r[3] else []) + nested) if nested else r[3])
    if not r:
        for chunk in chunks[1:]:
            r = _scan_ref_op(chunk, False)
            if r:
                r = (r[0], r[1], r[2],
                     _untrusted_cd(([r[3]] if r[3] else []) + _nested_cds(chunks)))
                break
    if not r:
        r = ('', '', [], '')
    if not with_untrusted_cd:
        return r[:3]
    # Alias candidates are reported even when no literal merge/pull was found:
    # that is exactly the case a config-file alias produces.
    aliases = _alias_candidates(chunks)
    if not r[0]:
        if aliases and _has_scope_change(chunks):
            # The gate resolves alias names against ONE repository; a cd or
            # `git -C` means that may not be the repository git will use.
            return ('merge', '', [REF_OP_UNRESOLVABLE], '', 1, False, aliases)
        # The companion fact matters even with no literal merge/pull: `git config
        # alias.m merge && git m feature` has none at parse time, and the gate's
        # alias lookup finds nothing because the command has not created the
        # alias yet. Reporting the companion is what lets the gate refuse it.
        return r + (0, _has_companion_command(chunks), aliases)
    return r + (_count_ref_ops(chunks), _has_companion_command(chunks), aliases)


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


def _gh_cd_fields(pending_cd, op, pending_cd_op, cds, allow_cd):
    """(target_dir, untrusted_cd) for one `gh pr` match.

    As in _scan_commit: an adjacent '&&' proves the cd ran (target_dir IS that cd
    here -- gh has no `-C`), and an authoritative target fixes the repo alone, so
    there is no unconfirmed cd left to report. allow_cd=False is a substitution body,
    whose subshell cwd is untrusted -- both fields are then empty.

    Split out of _iter_gh purely to reduce its complexity (CodeScene "Complex Method"
    / "Complex Conditional", #510); behavior unchanged (with allow_cd False the old
    code reached _cd_authoritative with target_dir '', which is never absolute)."""
    if not allow_cd:
        return '', ''
    target_dir = _trusted_cd(pending_cd, op)
    if _cd_authoritative(target_dir, pending_cd_op, cds):
        return target_dir, ''
    return target_dir, _untrusted_cd(cds)


def _gh_torn_recovery(seg, argv, subcommand):
    """The recovered PR number for a torn `gh pr <subcommand>` in `seg`, or None
    if no torn `gh` recovers one. '' is a valid recovered number (no digit
    argument, e.g. current-branch `gh pr merge`); only Python None means "no
    recovery" -- callers must check `is not None`, not truthiness.

    Split out of _iter_gh purely to reduce its complexity (CodeScene "Complex
    Method", #634); behavior unchanged. Same torn-assignment recovery as
    _scan_commit, in the same FIRST position and for the same verified reasons
    (#593) -- both `X=$(printf gh x) gh pr merge 1` and
    `X=$(printf gh pr merge x) env GH_REPO=other/repo gh pr merge 1` put a `gh`
    from inside the torn value where the walk reads it. The two-word
    subcommand is matched by the same _gh_find_pr_sub the normal path uses, so
    no second spelling of `pr <sub>` enters the file.

    LINEAR, not quadratic (#634), same shape as _scan_commit above: each
    candidate window is bounded by the NEXT candidate's start rather than
    running to end-of-segment, so slices partition the segment instead of
    stacking.

    AT MOST ONE result per segment. A segment IS one command -- `;`, `&&` and
    friends are what split_segments splits on -- so two executed
    `gh pr merge` invocations can never share one. Every candidate past the
    first is therefore debris (tear content, or an argument VALUE as in
    `gh pr merge 1 --body "gh pr merge 2"`), and returning it would inflate
    gh_pr_count, which the pre-merge gate reads to refuse multi-PR merges.
    Verified: yielding all candidates reported 2 for both of those
    single-merge shapes."""
    _gh_hits = list(_torn_direct_hits(seg, 'gh', argv))
    _gh_all = _gh_hits[0][0] if _gh_hits else ()
    _gh_starts = [_k for _t, _k in _gh_hits]
    for _i, _k in enumerate(_gh_starts):
        _end = (_gh_starts[_i + 1]
                if _i + 1 < len(_gh_starts) else len(_gh_all))
        _rest = _gh_all[_k + 1:_end]
        _j = _gh_find_pr_sub(_rest, subcommand)
        if _j is not None:
            return _gh_pr_number(_rest[_j + 2:])
    return None


def _iter_gh(chunk, subcommand, allow_cd):
    """Yield one result tuple per `gh pr <subcommand>` command word in `chunk`.
    allow_cd=False for substitution bodies (subshell cwd untrusted)."""
    pending_cd = None
    pending_cd_op = ''
    cds = []            # every cd seen, never reset -- see _untrusted_cd
    for op, seg in split_segments(chunk):
        cd = _record_cds(seg, cds)
        if cd is not None:
            pending_cd = cd           # strict form only: feeds the TRUSTED path
            pending_cd_op = op
            continue
        argv = _command_argv(seg, 'gh', wrapper_operands=True)
        # Recovery first, same as _scan_commit -- see _gh_torn_recovery for the
        # tear-detection and single-result rationale. Falling through to the
        # ordinary walk after recovering would yield the SAME invocation twice.
        _number = _gh_torn_recovery(seg, argv, subcommand)
        if _number is not None:
            yield True, '', _number, _TORN_SCOPE
            pending_cd = None
            continue
        if not argv or not _is_exe(argv[0], 'gh'):
            pending_cd = None
            continue
        rest = argv[1:]
        j = _gh_find_pr_sub(rest, subcommand)
        if j is None:
            pending_cd = None
            continue
        target_dir, untrusted = _gh_cd_fields(
            pending_cd, op, pending_cd_op, cds, allow_cd)
        yield True, target_dir, _gh_pr_number(rest[j + 2:]), untrusted
        pending_cd = None


def _scan_gh(chunk, subcommand, allow_cd):
    """First `gh pr <subcommand>` in `chunk`, or None."""
    return next(_iter_gh(chunk, subcommand, allow_cd), None)


# Matched against a TOKEN, not raw text, so it is anchored: shlex has already
# dequoted and joined continuations, so `env GH_RE"PO"=o/r` and `env GH_RE\PO=o/r`
# both arrive here as the single token `GH_REPO=o/r`. `\+?=` matches the append form,
# which EXPORTS the selector when the variable is unset (`GH_REPO+=o/r`).
_GH_ENV_ASSIGN_RE = re.compile(r'^(?:GH_REPO|GH_HOST)\+?=')

# A token that is an assignment WORD (`A=1`, `A+=1`, `A[0]+=1`) rather than a command.
# The subscript is `.*` (greedy), not `[^]]*`: a subscript may itself contain brackets
# (`A[foo[0]]=1`), and stopping at the first `]` left that token in argv, so the
# command after it went undetected by every gate using _command_argv.
_ASSIGN_TOK_RE = re.compile(r'^\w+(?:\[.*\])?\+?=')


# A token that could be the NAME of a command - a bare word or a path. Used only
# to ask whether the conservative walk landed on a command word at all: `+` and
# `2))` (the debris shlex leaves when it tears `X=$((1 + 2))`) are not names, and
# neither is a `NAME=value` operand. Deliberately not a validity check on the
# command - a name this rejects means the walk got lost, nothing more.
# `:` and `[` are real command NAMES (the no-op builtin and test), not debris, so
# rejecting them said "the walk got lost" about a walk that read its command word
# perfectly -- `: git commit` then recovered a commit that only the no-op runs.
# `+` is in the class but a token made ONLY of punctuation is still refused: `c++`
# and `g++` are real executables, while a bare `+` is the debris shlex leaves when
# it tears `X=$((1 + 2))`. The lookahead is what separates them -- a name must
# carry at least one word character -- so widening the class for real compiler
# names cannot also bless the tear debris this gate depends on rejecting. `:`,
# `[` and `.` are spelled out because they are real command names with no word
# character -- `.` is the `source` builtin, and rejecting it as unreadable sent
# `. /dev/null bash -c 'git commit'` (a no-op source; bash/-c/git/commit are
# just $1..$4 the sourced empty script never runs) into the any-position
# fallback scan, which then extracted `bash -c 'git commit'` as a live payload
# and blocked a commit that never happens (verified; cubic-dev-ai #587).
_READABLE_NAME = re.compile(r'^:$|^\[$|^\.$|^(?=.*\w)/?[\w.@:+-]+(?:/[\w.@:+-]+)*$')

# An env(1) `name=value` OPERAND, which carries no shell-identifier rule -- see
# the branch in _command_argv that uses it. Deliberately separate from
# _ASSIGN_TOK_RE: a bash assignment PREFIX must keep the stricter identifier
# form, and only a token following a WRAPPER is read by these looser rules.
# `name` here is any non-empty run of characters up to the first `=`, INCLUDING
# whitespace: env(1) reads its operand after the shell has already removed the
# quotes, so `env 'A B=x' bash -c '<s>'` really does set a variable named `A B`
# and really does run the child (verified). An earlier `[^\s=]+` spelling
# excluded whitespace and therefore stopped the launcher walk at that operand,
# so the payload was never extracted -- the same fail-OPEN one layer down.
_ENV_ASSIGN_TOK_RE = re.compile(r'^[^=]+=')

def _env_selector_in_prefix(seg):
    """True when `seg` carries a `GH_REPO=` / `GH_HOST=` assignment in its PREFIX,
    OR when an operand-taking wrapper makes that prefix unresolvable (fail-CLOSED;
    see the `#641` note in the body below). Callers must read True as "a selector
    may be present", never as a confirmed assignment.

    Two opposed review findings settle the design between them:

    * Reach must be command-WIDE, not "same segment as the merge". Bash preserves a
      variable's export attribute across re-assignment, so if the caller's shell had
      already exported GH_REPO, then `GH_REPO=o/r; gh pr merge 31` really does
      retarget a merge in a LATER segment — and whether it did is ambient state no
      parse can observe. The caller therefore ORs this across every segment.
    * Position must still be the assignment PREFIX. Scanning every token instead made
      ordinary operands look like selectors (`--body 'GH_REPO=o/r'`, `printf %s
      GH_HOST=x`), false-blocking legitimate merges.

    So: scan only the leading run of assignment words, wrappers, options and option
    arguments — the one place the shell accepts an environment assignment — and stop
    at the first real command word. Prefix position, command-wide reach.

    Matching is on TOKENS and rejects any with whitespace, so prose never matches:
    `--body 'Document GH_REPO=owner/repo'` is one argument token, not a prefix.
    """
    # #641. An operand-taking wrapper makes this prefix UNRESOLVABLE, and that is
    # reported rather than guessed. The walk that finds the command word can step
    # over `timeout 5` / `flock /tmp/l`; this scan cannot, because it has no
    # target to stop on -- and once the walk started detecting commands behind
    # those wrappers, a scan that quietly halted on `5` produced the worst
    # possible pair: `timeout 5 env GH_REPO=other/repo gh pr merge 1` read as a
    # merge with NO override, so the gate would validate the CURRENT repo while
    # gh merged another. That is the mis-scoping #593 bar 1 forbids, introduced
    # by detecting a command whose selector scan had not kept up.
    #
    # Three drafts tried to keep up by DERIVING a bound from `_command_argv`, and
    # each was defeated one spelling at a time -- a target-shaped lockfile that
    # stopped the bound early, a segment with no `gh` at all whose bound ran to
    # end-of-segment and read a merely PRINTED assignment, then a nested
    # `bash -c "gh pr merge 1"` whose outer segment has no `gh` token to bound
    # with. That is the same position question the command-word walk itself
    # declined to answer, and the same ladder #587/#593 exist to stop climbing.
    #
    # So: unresolvable prefix -> fail CLOSED. Cost is an over-report (the gate
    # stalls on a command it could have scoped), which is the direction this repo
    # chooses everywhere; the alternative is a silent wrong-repo validation.
    prev_dash = False
    toks = list(_tokenize(seg))
    j = 0
    while j < len(toks):
        t = toks[j]
        # Strip subshell / brace-group punctuation, as _command_argv does, so
        # `(GH_REPO=o/r gh …)` and `{ GH_REPO=o/r gh …; }` expose the assignment.
        t = t.lstrip('({')
        if not t:
            j += 1
            continue
        if _REDIR_RE.match(t):
            # A redirection-shaped token in the prefix is UNRESOLVABLE, so it is
            # reported rather than classified -- the same move the operand-wrapper
            # arm below already makes, for the same reason.
            #
            # `_tokenize` drops quote provenance, so after tokenization a quoted
            # `>` handed to an option and a real redirection operator are the SAME
            # token. Both orderings were built and both mis-scoped a real merge:
            #
            #   redirection-first    `env -u ">" GH_REPO=other/repo gh pr merge 1`
            #                        reads the QUOTED `>` as an operator and
            #                        swallows the assignment as its filename.
            #   option-argument-first `env -i > /dev/null env GH_REPO=other/repo
            #                        gh pr merge 1` reads a REAL detached
            #                        redirection as `-i`'s value, then hits
            #                        `/dev/null` and returns False.
            #
            # Each reports "no override" for a merge that really does retarget
            # another repo -- the wrong-repo validation of #593 bar 1, which is
            # strictly worse than a stall. The position question has no answer at
            # this layer, so it is not asked (verified; Codex findings, PR #650).
            #
            # PRICED, not assumed. Two-way diff against origin/main over 32,617
            # recorded agent commands: 4 changed, all of them this branch. The
            # ordinary trailing form (`gh pr merge 1 >/dev/null`) is untouched --
            # it returns False on `gh` long before reaching any redirection --
            # so the flips are NOT live redirections in front of a real command.
            # Every one traced back to text that is not a live redirection at all:
            #   * a heredoc OPENER (`<<PROMPT`) left in a continuation-split
            #     segment whose real command word was split off, and
            #   * literal PROSE inside a heredoc PR body (`cd <path> && <cmd>`),
            #     where `<cmd>` reads as `<` redirecting into a file named `cmd`.
            # That is the #639 family (prose inside an unparseable heredoc), which
            # this branch WIDENS rather than introduces. Measured live cost: one
            # `gh pr create` over 257 recorded, which stalls VISIBLY. The
            # alternative is a silent wrong-repo validation, so the direction is
            # the one this repo takes everywhere -- but the residue is real and
            # belongs with #639, not with a cleverer reading of this position.
            return True
        if _GH_ENV_ASSIGN_RE.match(t) and not _WS_RE.search(t):
            return True
        if _ASSIGN_TOK_RE.match(t):
            prev_dash = False
            j += 1
            continue
        if t.startswith('-'):
            # `--` is an option TERMINATOR, not an option whose value follows --
            # `_command_argv`'s own wrapper-option branch makes the same call
            # (`if t == '--': opts_done, prev_dash = True, False`). Treating it
            # as an ordinary dash option let the NEXT token be swallowed as
            # `--`'s "argument": `env -- timeout 5 env GH_REPO=other/repo gh pr
            # merge 1` then never reached the operand-wrapper fail-closed arm
            # below, and the scan fell through to `return False` on `5` --
            # reporting NO override for a merge that really does retarget
            # `other/repo`, the exact mis-scope this function exists to
            # prevent (verified; Codex finding, PR #650).
            prev_dash = t != '--'
            j += 1
            continue
        if prev_dash:
            prev_dash = False       # a wrapper option's ARGUMENT (`env -u FOO …`)
            j += 1
            continue
        # `!` is pipeline negation — the command still runs, so it is not the
        # command word. _command_argv skips it too; diverging here fails OPEN.
        if (t == '!' or t in _SHELL_KEYWORDS
                or t.rsplit('/', 1)[-1] in _WRAPPERS
                # A scoped wrapper takes no bare operand, so it leaves the prefix
                # RESOLVABLE -- step over it like any other wrapper rather than
                # failing closed. `ionice -c3 env GH_REPO=o/r gh pr merge 1` must
                # still find the selector.
                or t.rsplit('/', 1)[-1] in _SCOPED_WRAPPERS):
            j += 1
            continue
        if t.rsplit('/', 1)[-1] in _OPERAND_WRAPPERS:
            # Unresolvable from here on -- see the note above. Fail CLOSED.
            return True
        return False        # a real command word — the assignment prefix is over
    return False


# Words that can put a variable in the CHILD's environment. `local -x` exports too
# (inside a function), as do declare/typeset.
_EXPORT_WORDS = frozenset(('export', 'declare', 'typeset', 'local'))


def _names_gh_selector(tok):
    """True iff `tok` names GH_REPO/GH_HOST -- either as an assignment word
    (`GH_REPO=o/r`, `GH_REPO+=o/r`) or as the bare NAME (`export GH_REPO`, which
    exports a value assigned a step earlier).

    Extracted from _exports_selector as a named predicate purely to reduce that
    function's branch count (CodeScene "Complex Conditional", #513); behavior
    unchanged."""
    return bool(_GH_ENV_ASSIGN_RE.match(tok)) or tok in ('GH_REPO', 'GH_HOST')


def _exports_selector(seg):
    """True iff `seg` is an `export`/`declare -x`/`typeset -x` of GH_REPO/GH_HOST.

    Distinct from a bare assignment PREFIX, and the distinction is the shell's, not
    ours: `GH_REPO=o/r; gh pr merge 31` sets a shell variable the child never sees,
    while `export GH_REPO=o/r; gh pr merge 31` puts it in the child's environment.
    Only the exported form reaches a merge in a LATER segment.

    DELIBERATELY COARSE, and it is the end of a line of hardening rather than a step
    in it. Any export-family word plus any mention of the selector counts -- the word
    need not lead the segment (`if export GH_REPO=o/r; then …`), and the name may be
    exported a step apart from its assignment (`GH_REPO=o/r; export GH_REPO; …`).
    Modelling those precisely means tracking shell variable state, which is
    interpreting a command this hook never runs. So the residue is spent on the SAFE
    side: `declare GH_REPO=o/r` and `export -n GH_REPO=o/r` do NOT export, yet both
    return True here and produce a FALSE BLOCK. That is fail-CLOSED and the operator
    can reword; the opposite error authorizes a cross-repo merge. See ADR 0030.
    """
    toks = [t.lstrip('({') for t in _tokenize(seg)]
    toks = [t for t in toks if t]
    if not any(t.rsplit('/', 1)[-1] in _EXPORT_WORDS for t in toks):
        return False
    return any(_names_gh_selector(t) for t in toks)

# Shorthands on `gh pr merge` that CONSUME a value: -R/--repo, -b/--body,
# -F/--body-file, -t/--subject. Under pflag, the rest of a cluster after one of
# these is that flag's VALUE, not more shorthands -- so `-tRelease` is subject
# "Release", NOT a repo selector. Scanning past them would false-block on any
# attached value containing an R.
_GH_VALUE_SHORTHANDS = frozenset('bFtA')

# A PR argument given as a URL rather than a number — it carries its own owner/repo.
_GH_PR_URL_RE = re.compile(r'^(?:https?://|git@|ssh://)', re.I)

_WS_RE = re.compile(r'\s')

# The same flags in the forms that take their value as the NEXT token. Their operand
# must be skipped, or `gh pr merge 31 --subject -R` reads the subject VALUE `-R` as a
# repo selector and false-blocks a legitimate merge.
_GH_VALUE_FLAGS = frozenset({
    '-b', '--body', '-F', '--body-file', '-t', '--subject',
    '-A', '--author-email', '--match-head-commit',
})


def _is_shorthand_cluster(tok):
    """True iff `tok` is a SINGLE-dash pflag shorthand cluster with a body (`-sR`,
    `-R`) rather than a long option (`--repo`), a bare `-`, or a non-option word.

    Extracted from _cluster_scan as a named predicate purely to reduce that
    function's branch count (CodeScene "Complex Conditional", #513); behavior
    unchanged."""
    return tok.startswith('-') and not tok.startswith('--') and len(tok) >= 2


def _cluster_scan(tok):
    """Classify a single-dash pflag shorthand cluster.

    Returns 'repo' if it really carries `-R`, 'value' if it ENDS in a value-taking
    shorthand with no attached value (so the NEXT token is that value and must be
    consumed -- `-st -R` is subject "-R", not a repo selector), else None.

    gh uses spf13/pflag, which accepts clustered shorthands: `gh pr merge 31
    -sRother/repo` and `-sR other/repo` both set --repo. Matching only `-R` or
    `tok.startswith('-R')` missed every cluster where R was not first. pflag scans a
    cluster left to right and stops at the first value-taking shorthand, so this does
    the same -- anything after one of those, in the same token, is a value.
    """
    if not _is_shorthand_cluster(tok):
        return None
    body = tok[1:]
    for idx, ch in enumerate(body):
        if ch == 'R':
            return 'repo'
        if ch in _GH_VALUE_SHORTHANDS:
            # Last char => the value is the next TOKEN; otherwise it is attached here.
            return 'value' if idx == len(body) - 1 else None
    return None


def _gh_scan_tokens(rest):
    """Yield each word of a `gh pr` argv that is NOT consumed as a preceding flag's
    VALUE.

    `gh pr merge 31 --subject -R` must read `-R` as the subject's VALUE, not a repo
    selector, or a legitimate merge false-blocks; likewise `-st -R`, a cluster ENDING
    in a value-taking shorthand. Both shapes -- a `_GH_VALUE_FLAGS` word and a
    `_cluster_scan` 'value' cluster -- are skipped here.

    Extracted from gh_pr_repo_override and gh_pr_auto_merge, which carried identical
    skip loops, purely to reduce their complexity and nesting depth (CodeScene
    "Complex Method" / "Bumpy Road Ahead" / "Deep Nested Complexity", #513). Behavior
    is unchanged in both: the value-taking words are now YIELDED before being marked
    (rather than `continue`d past), which is inert because no `_GH_VALUE_FLAGS` word
    matches any selector test either caller applies -- none is `-R`/`--repo`, none
    matches _GH_PR_URL_RE, none is `--auto`, and each single-dash one classifies as
    'value', never 'repo'."""
    skip_value = False
    for tok in rest:
        if skip_value:
            skip_value = False
            continue        # this token is the previous flag's VALUE
        yield tok
        if tok in _GH_VALUE_FLAGS or _cluster_scan(tok) == 'value':
            skip_value = True


def _argv_selects_other_repo(rest):
    """True iff a `gh pr` argv (the words after `gh`) carries a repo/host selector.

    Split out of gh_pr_repo_override purely to reduce its complexity and nesting
    depth (#513); behavior unchanged."""
    for tok in _gh_scan_tokens(rest):
        if tok in ('-R', '--repo') or tok.startswith('--repo='):
            return True
        if _GH_PR_URL_RE.match(tok):
            # `gh pr merge https://github.com/other/repo/pull/31` selects the
            # repo positionally — same effect as -R, no flag involved. A URL
            # for THIS repo is over-blocked; that is fail-CLOSED and rare
            # (the normal form is a bare PR number).
            return True
        if _cluster_scan(tok) == 'repo':
            return True
    return False


def _iter_segments(cmd):
    """Yield every segment of `cmd` and of every string the shell will ADDITIONALLY
    execute (substitutions, interpreter payloads).

    Extracted purely to flatten the chunk-by-segment nesting in gh_pr_repo_override /
    gh_pr_auto_merge (CodeScene "Deep Nested Complexity", #513); behavior unchanged.
    The segment OPERATOR is dropped because neither caller consults it."""
    for chunk in _all_chunks(cmd):
        for _op, seg in split_segments(chunk):
            yield seg


def _gh_pr_argv(seg, subcommand):
    """The argv AFTER `gh` for a real `gh pr <subcommand>` invocation in `seg`, else
    None.

    Split out of gh_pr_repo_override / gh_pr_auto_merge purely to reduce their branch
    count and nesting depth (#513); behavior unchanged."""
    argv = _command_argv(seg, 'gh', wrapper_operands=True)
    if not argv or not _is_exe(argv[0], 'gh'):
        return None
    rest = argv[1:]
    if _gh_find_pr_sub(rest, subcommand) is None:
        return None
    return rest


def gh_pr_repo_override(cmd, subcommand):
    """True iff a command containing a real `gh pr <subcommand>` invocation steers it
    at another repo/host. The two selector forms get DIFFERENT scopes, because they
    have different reach:

    * **Flag form** (`-R` / `-Rowner/repo` / `--repo` / `--repo=...`) -- scoped to the
      matching invocation's OWN argv, gh global flags before `pr` included (since
      `gh -R x pr merge 5` really does retarget). It cannot reach a sibling command,
      so a wider scope would only produce false blocks. ADR 0024's coarse
      whole-command substring test is right for its non-gating advisory but wrong as
      a gate: pr-grind's own auto-admin merge runs `gh -R "$OWNER/$REPO" pr view` and
      `gh pr merge --admin` inside ONE Bash call, so a whole-command test rejects the
      entire call and the merge never runs (reproduced in-tree before this was added).

    * **Env form** (`GH_REPO=` / `GH_HOST=`) -- scoped to the WHOLE command. An
      assignment is ambient: it survives quoting (`env "GH_REPO=o/r" gh …`), grouping
      (`(GH_REPO=o/r gh …)`), and interpreter wrapping (`GH_REPO=o/r bash -c 'gh pr
      merge 31'`, where the merge lands in a nested chunk the assignment's segment
      never contains). Segment-scoping it missed all three. Widening is safe for the
      pr-grind case above, which uses the flag form -- no in-tree command shape puts a
      literal `GH_REPO=`/`GH_HOST=` in a merge-bearing call.

    Detection is incomplete by nature -- a GH_REPO exported by an EARLIER Bash call,
    or a selector assembled by shell expansion (`sel=R; gh pr merge 31 -"$sel" o/r`),
    is invisible to a hook that never runs the command. That is acceptable HERE, and
    only here, because the direction of failure is safe: a miss returns to the
    pre-existing behaviour (the gate validates REPO_DIR's PR, as it always did), while
    a hit blocks. Defense-in-depth against the literal form -- never a boundary.
    Contrast the head-pin requirement, which was reverted precisely because a miss
    there would have failed OPEN.
    """
    found = False
    env_selector = False
    for seg in _iter_segments(cmd):
        # Command-wide, not segment-scoped: see _env_selector_in_prefix. An
        # assignment anywhere may reach a merge anywhere, and which one it
        # reaches depends on ambient export state the hook cannot observe.
        if _env_selector_in_prefix(seg) or _exports_selector(seg):
            env_selector = True
        rest = _gh_pr_argv(seg, subcommand)
        if rest is None:
            continue
        found = True
        if _argv_selects_other_repo(rest):
            return True
    # Env form last, and only once we know there IS such an invocation to steer --
    # otherwise a bare `GH_REPO=o/r gh pr view 5` would report a merge override.
    #
    # Both forms are token-based: tokenization has already dequoted and joined line
    # continuations, so every literal spelling the shell reassembles -- `env
    # GH_RE"PO"=o/r`, `env GH_RE\PO=o/r`, `GH_RE\<newline>PO=o/r` -- reaches the
    # matcher as one `GH_REPO=o/r` token, without a text-normalization pass that
    # would also match inert prose.
    return found and env_selector


# pflag's ParseBool FALSE spellings. `--auto=false` genuinely disables auto-merge, so
# blocking it would be a pure false block; anything NOT here fails CLOSED (gh rejects
# an unrecognized value outright, so treating it as auto costs nothing, while guessing
# the other way would hand over a bypass primitive).
_PFLAG_FALSE = ('0', 'f', 'F', 'false', 'FALSE', 'False')


def _is_auto_flag(tok):
    """True iff `tok` turns auto-merge ON -- bare `--auto`, or `--auto=<true-ish>`.

    Extracted from gh_pr_auto_merge as a named predicate purely to reduce its branch
    count and nesting depth (#513); behavior unchanged. `--disable-auto` is a
    DIFFERENT flag name under pflag (full-name match, not prefix), so it is left
    alone."""
    if tok == '--auto':
        return True
    return (tok.startswith('--auto=')
            and tok[len('--auto='):] not in _PFLAG_FALSE)


def gh_pr_auto_merge(cmd, subcommand):
    """True iff a real `gh pr <subcommand>` invocation carries `--auto`.

    `--auto` is a boolean flag with no short form, but pflag DOES accept the
    `--auto=<bool>` assignment form for booleans, so an exact-token match alone
    missed `gh pr merge 31 --auto=true` and let the queued merge through. Both
    spellings are matched. `--auto=false` (and pflag's other false spellings)
    genuinely disables auto-merge and is NOT matched -- blocking it would be a
    pure false block. An UNRECOGNIZED value fails CLOSED: gh rejects it
    outright, so treating it as auto costs nothing, while guessing the other
    way would hand over a bypass primitive. `--disable-auto` is a DIFFERENT
    flag name under pflag (full-name match, not prefix), so it is left alone.

    Scoped to the matching invocation's OWN argv, same as the flag form of
    `gh_pr_repo_override` above and for the same reason: `--auto` cannot
    reach a sibling command in the same Bash call, so a wider scope would
    only produce false blocks (e.g. a `gh pr view` earlier in the call whose
    unrelated text happens to contain the substring).

    Detection is incomplete by nature -- an evasion invisible to this
    tokenizer (shell expansion building the flag, a wrapper script) is not
    caught. That is acceptable here, and asymmetric with the reverted
    `--match-head-commit`-presence requirement in a load-bearing way: a miss
    on a REQUIRED flag fails OPEN (the merge proceeds unpinned, looking
    identical to a compliant one); a miss on a flag we REJECT fails safe (the
    merge proceeds exactly as it would have before this guard existed --
    never worse than the pre-existing behavior). See ADR 0030 Residual risk.
    """
    for seg in _iter_segments(cmd):
        rest = _gh_pr_argv(seg, subcommand)
        if rest is None:
            continue
        # NOTE: no `#`-comment skip here, deliberately. _tokenize retains
        # comments, so `gh pr merge 31 --squash # do not use --auto`
        # false-BLOCKS. Stopping the scan at a `#` token was tried and
        # REVERTED: shlex has already removed quoting, so a legitimate
        # hash-prefixed ARGUMENT is indistinguishable from a comment --
        # `gh pr merge '#feature' --auto` would stop the scan and hide a
        # live `--auto`, turning a false block into a fail-OPEN bypass.
        # Unknowable ⇒ keep the false block: it is visible and the
        # operator can reword; the bypass would not be.
        if any(_is_auto_flag(tok) for tok in _gh_scan_tokens(rest)):
            return True
    return False


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


def _gh_fold_main(r, chunks):
    """Fold every nested chunk's cds into a MAIN-chunk `gh pr` match.

    Split out of gh_pr purely to reduce its complexity (CodeScene "Complex Method" /
    "Bumpy Road Ahead", #510); behavior unchanged."""
    # An ABSOLUTE target (an absolute `git -C`, or an '&&'-proved absolute cd) fixes
    # the repo no matter what any payload did, so it is never overridden.
    if r[1].startswith('/'):
        return r
    # Current-shell payload cds count for a main-chunk match too -- see git_commit.
    nested = [c for chunk in chunks[1:] for c in _all_cds(chunk)]
    if not nested:
        return r
    return (r[0], r[1], r[2], _untrusted_cd(([r[3]] if r[3] else []) + nested))


def _gh_scan_nested(chunks, subcommand):
    """First `gh pr <subcommand>` found in a NESTED chunk, or None.

    Split out of gh_pr purely to reduce its complexity (#510); behavior unchanged."""
    for chunk in chunks[1:]:
        r = _scan_gh(chunk, subcommand, False)
        if r:
            # Every cd in the whole command, order-independent -- _nested_cds.
            # `r[3]` is CARRIED, not discarded: rebuilding this field purely from
            # _nested_cds dropped the scanner's own verdict, which since #593 can
            # be `_TORN_SCOPE` -- so `bash -c 'X=$(printf x y) gh pr merge 1'`
            # came back with an EMPTY untrusted scope and the gate anchored the
            # cwd repo (verified) while the nested merge targeted another. The
            # git sibling at _fold_main already folds `r[3]` in exactly this way;
            # this makes the two agree rather than special-casing one.
            return (r[0], r[1], r[2],
                    _untrusted_cd(([r[3]] if r[3] else []) + _nested_cds(chunks)))
    return None


def gh_pr(cmd, subcommand, with_untrusted_cd=False):
    """Detect a real `gh pr <subcommand>` (create/merge) via command-word
    analysis. Returns (present: bool, target_dir: str, pr_num: str), plus a 4th
    element (untrusted_cd: str) when with_untrusted_cd=True — see _untrusted_cd and
    git_commit. Default stays a 3-tuple so every existing caller is unaffected. gh global
    flags before the subcommand (gh --repo owner/repo pr create, gh --hostname h
    pr merge 5) are skipped, including a single value token after each flag. cd
    trust is operator-aware; command substitutions ($(...), backticks) are
    scanned (subshell cwd → target_dir '')."""
    chunks = _all_chunks(cmd)
    r = _scan_gh(chunks[0], subcommand, True)
    r = _gh_fold_main(r, chunks) if r else _gh_scan_nested(chunks, subcommand)
    if not r:
        r = (False, '', '', '')
    return r if with_untrusted_cd else r[:3]


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
