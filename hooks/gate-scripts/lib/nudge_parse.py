#!/usr/bin/env python3
"""Parse a Bash PreToolUse payload (stdin JSON) for codex-nudge-premerge.sh.

Prints 5 lines to stdout (empty on non-Bash / non-merge / parse error → hook skips):
    1: 'yes'                 (a real `gh pr merge` is present)
    2: target_dir            (cd-&&-prefix dir captured by gh_pr, or '')
    3: positional            (the merge's PR number, or '')
    4: '1' if UNSAFE else '' (skip signal)
    5: cwd                   (the payload cwd)

Lives as a FILE (not an inline `python3 -c "…"`) so no bash double-quote escaping
layer can corrupt backslashes/backticks in the source. Loaded via PYTHONPATH by the
hook. See codex-nudge-premerge.sh for the full loosening rationale (ADR 0013).
"""
import sys
import json
import re
import shlex

sys.path[:] = [p for p in sys.path if p not in ('', '.')]
from gitcmd_detect import gh_pr, split_segments, strip_continuations  # noqa: E402


def strip_comments(s):
    # Remove shell comments: an unquoted '#' that begins a token (start, or after
    # whitespace/newline/metachar) through end-of-line. Quote-aware; an unquoted
    # backslash escapes the next char (so \# is a literal '#', not a comment). Line
    # continuations (backslash-newline) are removed FIRST by strip_continuations,
    # matching Bash's own order, so a continued word is joined before comment
    # analysis. Kills commented `gh pr merge` decoys and comments embedding operators.
    s = strip_continuations(s)
    out = []
    q = None
    prev = ''
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if q is not None:
            out.append(c)
            if c == '\\' and q == '"' and i + 1 < n:
                out.append(s[i + 1])
                prev = s[i + 1]
                i += 2
                continue
            if c == q:
                q = None
            prev = c
            i += 1
            continue
        if c == '\\' and i + 1 < n:            # unquoted escape: \# is a literal '#'
            out.append(c)
            out.append(s[i + 1])
            prev = s[i + 1]
            i += 2
            continue
        if c in ('"', "'"):
            q = c
            out.append(c)
            prev = c
            i += 1
            continue
        if c == '#' and (prev in ('', ' ', '\t', '\n', ';', '&', '|', '(', ')', '<', '>')):
            while i < n and s[i] != '\n':
                i += 1
            continue
        out.append(c)
        prev = c
        i += 1
    return ''.join(out)


# gh pr merge flags that consume a following value (must not be read as the PR).
VALFLAGS = {'--author-email', '-A', '--body', '-b', '--body-file', '-F',
            '--match-head-commit', '--subject', '-t'}
# env vars that re-target git/gh; a merge influenced by any is un-nudgeable.
SENSITIVE = ('GH_REPO', 'GH_HOST', 'GH_ENTERPRISE_TOKEN', 'GIT_DIR',
             'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'PATH')
# command words BEFORE the merge that can re-point where it runs / which repo it
# hits. Everything else pre-merge (jq/mkdir/echo/case/if/for/[/test/…) is benign.
# git is included wholesale (any pre-merge git — git -C x remote set-url, config, …
# — can re-point origin; the real blocks run git only AFTER the merge).
RETARGET_EXE = {'gh', 'git', 'source', '.', 'eval', 'exec', 'bash', 'sh', 'zsh',
                'ssh', 'env', 'sudo', 'xargs', 'nohup', 'time', 'command',
                'builtin', 'trap'}
# reserved/control-flow words that PREFIX a real command word (then cd /x ; do gh …);
# strip them so the command word analysed is the real one, not the keyword hiding a
# re-targeter behind it.
RESERVED = {'if', 'then', 'else', 'elif', 'fi', 'while', 'until', 'for', 'do',
            'done', 'case', 'esac', '{', '}', '!', '(', ')', 'time'}


def is_repo_flag(t):
    return t in ('-R', '--repo') or t.startswith('--repo=') or (t.startswith('-R') and len(t) > 2)


def main():
    d = json.load(sys.stdin)
    if d.get('tool_name', d.get('toolName', '')) != 'Bash':
        return
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = strip_comments(inp.get('command', ''))
    is_merge, target_dir, _pr = gh_pr(cmd, 'merge')
    if not is_merge:
        return

    segs = list(split_segments(cmd))
    positional = ''
    unsafe = False
    merge_count = 0
    merge_index = -1
    parsed = []   # (idx, op, cmdword, is_cd, is_merge, is_retarget)

    for idx, (op, seg) in enumerate(segs):
        # '&' (background) or '|' (pipe) runs neighbours CONCURRENTLY, so an
        # "after the merge" segment could race the merge's repo resolution — the
        # after-merge=safe assumption only holds for sequential joins. Real merge
        # blocks use neither, so ANY '&'/'|' → skip (fail-safe).
        if op in ('&', '|'):
            unsafe = True
        if not seg.strip():
            parsed.append((idx, op, '', False, False, False))
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            unsafe = True
            parsed.append((idx, op, '<unlex>', False, False, False))
            continue
        if not toks:
            parsed.append((idx, op, '', False, False, False))
            continue
        i = 0
        while i < len(toks) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[i]):
            if toks[i].split('=', 1)[0] in SENSITIVE:
                unsafe = True                # sensitive inline/standalone assignment anywhere
            i += 1
        # strip leading reserved/control-flow words so a re-targeter hidden behind
        # then/do/open-brace (e.g. if true; then cd /b; fi) is analysed, not the keyword.
        while i < len(toks) and toks[i] in RESERVED:
            i += 1
        cw = toks[i] if i < len(toks) else ''     # '' → pure assignment/keyword-only segment
        base = cw.rsplit('/', 1)[-1] if cw else ''   # basename: /usr/bin/git → git
        rest = toks[i + 1:] if i < len(toks) else []
        # export/declare/env of a sensitive var (any position)
        if base in ('export', 'declare', 'typeset', 'local', 'readonly', 'env'):
            if any(a.split('=', 1)[0] in SENSITIVE for a in rest if '=' in a):
                unsafe = True
        is_cd = (base == 'cd')
        # any command that can re-point where the merge runs / which repo it hits.
        is_retarget = (base in RETARGET_EXE)
        is_m = False
        if cw == 'gh' and 'pr' in rest:
            pri = rest.index('pr')
            after = rest[pri + 1:]
            if any(is_repo_flag(g) for g in rest[:pri]):   # global -R before subcommand
                unsafe = True
            if after and after[0] == 'merge':
                is_m = True
                merge_count += 1
                merge_index = idx
                if '$' in seg or '`' in seg:              # dynamic operand/flag in the merge seg
                    unsafe = True
                margs = after[1:]
                j = 0
                pos_count = 0
                while j < len(margs):
                    t = margs[j]
                    if is_repo_flag(t):
                        unsafe = True
                        j += 2 if t in ('-R', '--repo') else 1
                        continue
                    if t in VALFLAGS:
                        if j + 1 >= len(margs):
                            unsafe = True
                        j += 2
                        continue
                    if t.startswith('-'):
                        j += 1
                        continue
                    pos_count += 1
                    if pos_count == 1:
                        positional = t
                    j += 1
                if pos_count > 1:
                    unsafe = True
                if positional and not re.match(r'^[0-9]+$', positional):
                    unsafe = True
        parsed.append((idx, op, cw, is_cd, is_m, is_retarget))

    if merge_count != 1:
        unsafe = True

    if merge_index >= 0:
        # The merge's captured &&-prefix cd (gh_pr → target_dir) is the ONLY cd
        # allowed before the merge; it must be the nearest non-empty preceding
        # segment joined by '&&'. Identify it so it is not flagged as a re-target.
        prev_nonempty = -1
        for (idx, op, cw, is_cd, is_m, is_rt) in parsed:
            if idx < merge_index and cw != '':
                prev_nonempty = idx
        captured_cd_idx = -1
        if target_dir and prev_nonempty >= 0:
            pc = parsed[prev_nonempty]
            if pc[3] and parsed[merge_index][1] == '&&':   # is_cd and merge joined by &&
                captured_cd_idx = prev_nonempty
        for (idx, op, cw, is_cd, is_m, is_rt) in parsed:
            if idx >= merge_index or cw == '':
                continue                                   # after-merge / pure-assignment/keyword → ok
            if idx == captured_cd_idx:
                continue                                   # the one allowed cd prefix
            if is_cd:                                      # any other cd before the merge
                unsafe = True
                continue
            if is_rt:                                      # gh/git/source/eval/bash/… before merge
                unsafe = True
                continue

    print('yes')
    print(target_dir)
    print(positional)
    print('1' if unsafe else '')
    print(cwd)


try:
    main()
except Exception:
    pass
