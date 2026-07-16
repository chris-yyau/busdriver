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


def split_segments(cmd):
    """Split a command line into (operator_before, segment) pairs. Splits on
    top-level &&, ||, ;, |, &, and newline, honoring quotes/escapes so an
    operator inside quotes is not a separator. operator_before is the shell
    operator that precedes each segment ('' for the first) — callers use it to
    tell whether a `cd` actually gated the following command (only '&&' does).
    A lone '&' is the background operator; both '&&' and '&' terminate the
    current top-level command so `true & git commit` does not hide the commit."""
    out = []
    buf = []
    op = ''
    quote = None
    i = 0
    n = len(cmd)

    def flush(next_op):
        out.append((op, ''.join(buf).strip()))
        return next_op

    while i < n:
        c = cmd[i]
        if quote is not None:
            buf.append(c)
            if c == '\\' and quote == '"' and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
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


def _command_substitutions(cmd):
    """Return the inner command strings of every EXECUTING substitution —
    $(...) and backticks — including nested ones. Single quotes suppress
    substitution (their contents are skipped); double quotes do not."""
    subs = []
    i = 0
    n = len(cmd)
    sq = False
    while i < n:
        c = cmd[i]
        if sq:
            if c == "'":
                sq = False
            i += 1
            continue
        if c == "'":
            sq = True
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            i += 2
            continue
        if c == '$' and i + 1 < n and cmd[i + 1] == '(':
            depth = 1
            j = i + 2
            start = j
            iq = None  # quote state INSIDE the substitution, so a quoted ')' or
            #            '(' does not mis-balance the depth counter.
            while j < n and depth > 0:
                cj = cmd[j]
                if iq is not None:
                    if cj == '\\' and iq == '"' and j + 1 < n:
                        j += 2
                        continue
                    if cj == iq:
                        iq = None
                    j += 1
                    continue
                if cj in ('"', "'"):
                    iq = cj
                elif cj == '(':
                    depth += 1
                elif cj == ')':
                    depth -= 1
                j += 1
            inner = cmd[start:j - 1] if depth == 0 else cmd[start:]
            subs.append(inner)
            subs.extend(_command_substitutions(inner))
            i = j
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


def _shell_payloads(cmd):
    """Strings an interpreter/eval will itself execute — `bash -c '<s>'`,
    `sh -c '<s>'`, `eval '<s>' '<t>'`, etc. — for recursive scanning."""
    out = []
    for _op, seg in split_segments(cmd):
        argv = _command_argv(seg, '')  # '' = no exe guard, just strip launchers
        if not argv:
            continue
        base = argv[0].rsplit('/', 1)[-1]
        if base in _INTERPRETERS:
            # Find the option token that turns on "read the command string",
            # then treat EVERY later argv as a candidate payload.
            #
            # `c` may be CLUSTERED with other short options and may carry any
            # option SIGN. Verified against real bash/sh: `-lc`, `-ec`, `-xc`,
            # `-cl`, `-ce` (c not last), and `+c` / `+lc` (plus sign) ALL
            # execute the payload. Matching only a bare '-c' let every one of
            # these hide it from the gates.
            #
            # Do NOT try to pick WHICH argv holds the command string: an option
            # inside the same cluster can consume an argument and shift it.
            # Both verified to really execute:
            #   bash --rcfile -custom -c "git commit"   # payload at argv[3]
            #   bash -Oc extglob "git commit"           # -O eats extglob
            # Guessing an index makes a wrong guess a MISS (fail OPEN), so take
            # everything after the candidate instead. A wrong guess then only
            # scans an extra inert chunk — the fail-closed direction — and no
            # option-arity table is needed. Fan-out stays bounded by the
            # _all_chunks depth cap.
            for k in range(1, len(argv)):
                tok = argv[k]
                if (tok[:1] in ('-', '+')
                        and not tok.startswith(('--', '++'))
                        and 'c' in tok[1:]):
                    out.extend(argv[k + 1:])
                    break
        elif base == 'eval':
            out.append(' '.join(argv[1:]))
    return out


def _all_chunks(cmd, _depth=0):
    """cmd plus every string the shell will additionally execute — command
    substitutions and interpreter/eval payloads — recursively (depth-bounded)."""
    chunks = [cmd]
    if _depth < 6:
        for extra in _command_substitutions(cmd) + _shell_payloads(cmd):
            if extra:
                chunks.extend(_all_chunks(extra, _depth + 1))
    return chunks


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


def _scan_gh(chunk, subcommand, allow_cd):
    """Scan one command chunk for `gh pr <subcommand>`; return the result tuple
    or None. allow_cd=False for substitution bodies (subshell cwd untrusted)."""
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
        # Reach 'pr <subcommand>' past any gh global flags and their values.
        rest = argv[1:]
        j = 0
        prev_flag = False
        matched = False
        while j < len(rest):
            a = rest[j]
            if a == 'pr' and rest[j + 1:j + 2] == [subcommand]:
                matched = True
                break
            if a.startswith('-'):
                prev_flag = True
                j += 1
            elif prev_flag:
                prev_flag = False
                j += 1
            else:
                break
        if not matched:
            pending_cd = None
            continue
        target_dir = _trusted_cd(pending_cd, op) if allow_cd else ''
        pr_num = ''
        # The PR number is the first bare integer that is NOT a flag's value.
        # Skip flags; for gh-pr-merge value-taking flags also skip their separate
        # value, so `gh pr merge --subject 123 5` resolves 5 (not the subject),
        # while `gh pr merge --squash 5` (boolean flag) still resolves 5.
        value_flags = {'-b', '--body', '-F', '--body-file', '-t', '--subject',
                       '-R', '--repo', '--match-head-commit', '--author-email'}
        skip_val = False
        for x in rest[j + 2:]:
            if skip_val:
                skip_val = False
                continue
            if x.startswith('-'):
                if '=' not in x and x in value_flags:
                    skip_val = True
                continue
            if re.match(r'^\d+$', x):
                pr_num = x
                break
        return True, target_dir, pr_num
    return None


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
