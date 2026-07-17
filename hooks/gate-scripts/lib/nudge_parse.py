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

BACKSLASH = chr(92)   # a single '\' — named to avoid backslash-literal misreads


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
            if c == BACKSLASH and q == '"' and i + 1 < n:
                out.append(s[i + 1])
                prev = s[i + 1]
                i += 2
                continue
            if c == q:
                q = None
            prev = c
            i += 1
            continue
        if c == BACKSLASH and i + 1 < n:       # unquoted escape: the escaped char is a
            out.append(c)                       # literal part of the current word, so what
            out.append(s[i + 1])                # follows is NOT a word start — a '#' after
            prev = 'x'                          # \<space> is mid-word, never a comment.
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
# env vars that re-target git/gh; a merge influenced by any is un-nudgeable. Match
# by PREFIX so the whole GH_*/GIT_* families are covered — GH_REPO/GH_HOST, GIT_DIR/
# GIT_WORK_TREE, and Git's env-config injection (GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n/
# GIT_CONFIG_VALUE_n, GIT_CONFIG_GLOBAL/SYSTEM, …) which can rewrite remote.origin.url
# — plus PATH. The real merge blocks assign only NO_WORKTREE/MERGE_STATE/LOG_*/attempt,
# none GH_/GIT_-prefixed, so this never false-trips them.
def is_sensitive_name(name):
    return name == 'PATH' or name.startswith('GH_') or name.startswith('GIT_')


# assignment-name matcher: NAME= or NAME+= (Bash append). group(1) is the bare NAME.
ASSIGN_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\+?=')


def assign_name(tok):
    # name of a `NAME=…` / `NAME+=…` token (append), else ''.
    m = ASSIGN_RE.match(tok)
    return m.group(1) if m else ''
# MERGE-FIRST invariant: nothing may EXECUTE before the merge except pure
# non-sensitive assignments and a single captured `cd &&` prefix. This is
# complete-by-construction — we do NOT try to denylist re-targeting commands
# (a denylist can never be complete: `printf > .git/config`, `cp evil .git/config`,
# `sed -i`, an interpreter one-liner, … all re-point origin), we simply reject ANY
# real command word before the merge. The pr-grind DEFAULT block (and skip-bypass
# merges) are merge-first (only `NO_WORKTREE=<0|1>` precedes the merge), so they
# nudge; the ADMIN approver-gap block writes its bypass-log jq BEFORE the merge and
# is therefore skipped here — covered by the SKILL-prose nudge instead (ADR 0013).
# reserved/control-flow words that PREFIX a real command word (then cd /x ; do gh …);
# strip them so the command word analysed is the real one, not the keyword hiding a
# re-targeter behind it.
RESERVED = {'if', 'then', 'else', 'elif', 'fi', 'while', 'until', 'for', 'do',
            'done', 'case', 'esac', '{', '}', '!', '(', ')', 'time'}
# command substitutions ($(...) / `...`) BEFORE the merge can run a re-targeter that
# the top-level command word hides (echo "$(git remote set-url …)"). Scan their
# CONTENT for a re-target word or a sensitive assignment. The real blocks' only
# pre-merge substitution is $(printf … | jq …) — no such word — so this never trips.
# the merge segment is rejected if it contains ANY char outside this literal set —
# a complete guard against every shell expansion injecting extra args (see use site).
MERGE_SEG_UNSAFE_RE = re.compile(r'[^A-Za-z0-9 \t_./:=@-]')
SUBST_RE = re.compile(r'\$\(([^()]*)\)|`([^`]*)`')
RETARGET_WORD_RE = re.compile(
    r'\b(gh|git|cd|pushd|popd|chdir|source|eval|exec|bash|sh|zsh|ssh|env|sudo'
    r'|xargs|nohup|command|builtin|trap)\b')


def is_repo_flag(t):
    return t in ('-R', '--repo') or t.startswith('--repo=') or (t.startswith('-R') and len(t) > 2)


def subst_has_retargeter(seg):
    for m in SUBST_RE.finditer(seg):
        inner = m.group(1) or m.group(2) or ''
        if RETARGET_WORD_RE.search(inner):
            return True
        for tok in inner.split():
            if is_sensitive_name(assign_name(tok)):
                return True
    return False


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
    # PASS 1 — parse each segment into a position-INDEPENDENT record. Merge-intrinsic
    # faults (count, -R, $-operand, non-numeric PR) set `unsafe` here because they are
    # about the merge itself, not about ordering.
    #   rec = dict(op, cw, base, is_cd, is_merge, sensitive, subst_rt)
    recs = []
    for idx, (op, seg) in enumerate(segs):
        rec = {'op': op, 'cw': '', 'base': '', 'is_cd': False, 'is_merge': False,
               'sensitive': False, 'subst_rt': subst_has_retargeter(seg),
               'opens_loop': False, 'has_done': False}
        if not seg.strip():
            recs.append(rec)
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            unsafe = True
            recs.append(rec)
            continue
        if not toks:
            recs.append(rec)
            continue
        # Loop bookkeeping (BEFORE reserved-stripping hides the opener). A segment
        # whose first non-assignment token opens a loop, and any `done`, let PASS 2
        # decide whether the merge sits inside a loop body/condition (re-runs).
        _k = 0
        while _k < len(toks) and ASSIGN_RE.match(toks[_k]):
            _k += 1
        if _k < len(toks) and toks[_k] in ('for', 'while', 'until'):
            rec['opens_loop'] = True
        if 'done' in toks:
            rec['has_done'] = True
        # INTERLEAVE assignment- and reserved-word-stripping: a reserved word can be
        # followed by more assignments (`then GH_REPO=evil`) and vice-versa, so keep
        # consuming BOTH until neither — else an assignment hidden behind `then` would
        # be read as the command word and never flagged sensitive.
        i = 0
        while i < len(toks):
            if ASSIGN_RE.match(toks[i]):
                if is_sensitive_name(assign_name(toks[i])):
                    rec['sensitive'] = True
                i += 1
            elif toks[i] in RESERVED:
                i += 1
            else:
                break
        cw = toks[i] if i < len(toks) else ''     # '' → pure assignment/keyword-only segment
        base = cw.rsplit('/', 1)[-1] if cw else ''   # basename: /usr/bin/git → git
        rest = toks[i + 1:] if i < len(toks) else []
        # export/declare/env of a sensitive var — BARE name (`export GH_REPO`),
        # NAME=val, or NAME+=val append (`export GH_REPO+=x`); check every form.
        if base in ('export', 'declare', 'typeset', 'local', 'readonly', 'env'):
            if any(is_sensitive_name(assign_name(a) or a) for a in rest):
                rec['sensitive'] = True
        rec['cw'] = cw
        rec['base'] = base
        rec['is_cd'] = (base == 'cd')
        if cw == 'gh' and 'pr' in rest:
            pri = rest.index('pr')
            after = rest[pri + 1:]
            if any(is_repo_flag(g) for g in rest[:pri]):   # global -R before subcommand
                unsafe = True
            if after and after[0] == 'merge':
                rec['is_merge'] = True
                merge_count += 1
                merge_index = idx
                # The merge segment must be plain literal tokens — a real
                # `gh pr merge <num> --squash --delete-branch [--admin]` uses only
                # [A-Za-z0-9 _./:=@-]. ALLOWLIST those chars and reject anything else:
                # that closes EVERY shell expansion at once (shlex shows one token but
                # Bash expands it into extra args, e.g. an injected --repo) — variable/
                # command substitution ($…/`…`), process substitution <(…)/>(…), brace
                # {a,--repo=evil}, and pathname/glob *?[]! — without enumerating them.
                if MERGE_SEG_UNSAFE_RE.search(seg):
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
        recs.append(rec)

    if merge_count != 1:
        unsafe = True

    # LOOP guard: a merge inside a loop body/condition re-runs, so segments AFTER it
    # (which the merge-first rule treats as harmless) execute BEFORE the next
    # iteration's merge and can re-point origin (`while gh pr merge; do cd /x; done`,
    # `for i in 1 2; do gh pr merge; cd /x; done`). Walk loop nesting: a segment that
    # opens for/while/until enters a loop scope until its matching `done`. The merge is
    # unsafe if it sits at depth > 0, or its OWN segment opened a loop (it's the
    # condition). The real DEFAULT block's retry loop is entirely AFTER the merge
    # (depth 0 at the merge), so it stays safe.
    if merge_index >= 0:
        depth = 0
        for idx, rec in enumerate(recs):
            if idx == merge_index:
                if depth > 0 or rec['opens_loop']:
                    unsafe = True
                break
            if rec['opens_loop']:
                depth += 1
            if rec['has_done']:
                depth = max(0, depth - 1)

    # PASS 2 — POSITION-AWARE. Only what runs BEFORE (or joins concurrently with) the
    # merge can re-point it; segments wholly AFTER a sequential merge are ignored (a
    # trailing `GH_REPO=x true` or `echo | tee log` must NOT suppress the nudge).
    if merge_index >= 0:
        # The merge's captured &&-prefix cd (gh_pr → target_dir) is the ONLY cd allowed
        # before the merge; it must be the nearest non-empty preceding segment via '&&'.
        prev_nonempty = -1
        for idx, rec in enumerate(recs):
            if idx < merge_index and rec['cw'] != '':
                prev_nonempty = idx
        captured_cd_idx = -1
        if target_dir and prev_nonempty >= 0:
            if recs[prev_nonempty]['is_cd'] and recs[merge_index]['op'] == '&&':
                captured_cd_idx = prev_nonempty
        # Concurrency that INVOLVES the merge (merge backgrounded/piped, or piped INTO):
        # the merge's own incoming op, or the immediately-following segment's op, is
        # '&'/'|'. A '|'/'&' wholly among post-merge segments does not involve the merge.
        if recs[merge_index]['op'] in ('&', '|'):
            unsafe = True
        if merge_index + 1 < len(recs) and recs[merge_index + 1]['op'] in ('&', '|'):
            unsafe = True
        for idx, rec in enumerate(recs):
            if idx > merge_index:
                break                                      # after-merge → cannot re-target
            if idx == merge_index:
                if rec['sensitive']:
                    unsafe = True                          # inline sensitive prefix ON the merge
                continue
            # MERGE-FIRST: before the merge, allow ONLY the captured cd prefix and
            # pure non-sensitive assignments / reserved-only segments (cw == '').
            # A sensitive assignment, a $(retargeter), or ANY real command word →
            # skip (complete: no need to enumerate which commands re-target).
            if idx == captured_cd_idx:
                continue
            if rec['sensitive'] or rec['subst_rt'] or rec['cw'] != '':
                unsafe = True

    print('yes')
    print(target_dir)
    print(positional)
    print('1' if unsafe else '')
    print(cwd)


try:
    main()
except Exception:
    pass
