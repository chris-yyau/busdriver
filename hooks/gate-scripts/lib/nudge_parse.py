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
    # CDPATH re-points a RELATIVE `cd` operand to a directory outside the payload cwd,
    # so a `CDPATH=/other cd leaf` would run the merge somewhere the resolver can't
    # predict — treat it as sensitive (defense-in-depth; the absolute-cd rule below is
    # the primary guard, since CDPATH is ignored for absolute operands).
    return (name == 'PATH' or name == 'CDPATH'
            or name.startswith('GH_') or name.startswith('GIT_'))


# assignment-name matcher: NAME= or NAME+= (Bash append). group(1) is the bare NAME.
ASSIGN_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\+?=')


def assign_name(tok):
    # name of a `NAME=…` / `NAME+=…` token (append), else ''.
    m = ASSIGN_RE.match(tok)
    return m.group(1) if m else ''
# MERGE-FIRST invariant: nothing may EXECUTE before the merge except pure
# non-sensitive assignments, a captured `cd &&` prefix, and (ADR 0018) a standalone
# PLAIN-LITERAL `cd <path>` whose target is handed to the hook's downstream
# gh-pr-view==cwd-origin equality guard. This is complete-by-construction — we do NOT
# try to denylist re-targeting commands
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
# #427 carve-out: pr-grind's own trusted merge templates pass the classified head SHA
# as `--match-head-commit "$REVIEWED_HEAD"` — a double-quoted SIMPLE variable
# reference, not a command/process substitution. Quoting prevents word-splitting and
# globbing, so this form expands to exactly ONE argument and cannot hide extra flags
# (unlike `$(...)`/brace/glob forms, which the allowlist above still rejects). Scoped
# to the flag name (not any VALFLAG) and to a bare `$IDENT` — no braces, no nesting,
# no command substitution — so it stays a narrow exception to the "reject everything"
# rule rather than a general re-opening of expansion syntax on the merge segment.
SAFE_MATCH_HEAD_RE = re.compile(
    r'--match-head-commit(?:\s+|=)"\$[A-Za-z_][A-Za-z0-9_]*"')
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
               'opens_loop': False, 'has_done': False,
               'cd_literal': False, 'cd_target': '', 'subshell': False,
               'had_reserved': False}
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
        # Subshell grouping: a bare '(' / ')' token opens/closes a SUBSHELL, whose cwd
        # is scoped to the group — `( cd /x ) ; merge` leaves the parent cwd (and the
        # merge) untouched. A merge-first `cd` inside such a group cannot be trusted to
        # set the merge's runtime cwd, so PASS 2 rejects any pre-merge segment carrying
        # one. (`$(…)` / `<(…)` keep the '(' inside a single token — never a bare '(' —
        # so this flags only real subshell grouping, not substitutions.)
        rec['subshell'] = any(t in ('(', ')') for t in toks)
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
                rec['had_reserved'] = True   # cd behind `then`/`do`/… may be CONDITIONAL
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
        # A standalone `cd` (';'/newline-separated, NOT the &&-captured prefix that
        # gh_pr already trusts) is a SAFE merge-first prefix ONLY when its target is a
        # single ABSOLUTE PLAIN-LITERAL path: exactly one operand, starting with '/',
        # not a flag, and free of any shell-expansion metachar ($ / backtick / glob /
        # brace / ~) per the same allowlist the merge segment uses. ABSOLUTE is
        # load-bearing: a relative operand is subject to CDPATH (which can resolve it
        # OUTSIDE the payload cwd) and to composition with an earlier cd, so the
        # resolver could not reliably predict the merge's runtime cwd; an absolute path
        # ignores CDPATH and resolves identically to the downstream repo resolver. A
        # `cd "$(git rev-parse …)"`, `cd $VAR`, or relative `cd leaf` is NOT accepted
        # here (still covered by the &&-capture path when &&-joined, or the SKILL-prose
        # nudge). Capturing the literal absolute target lets PASS 2 hand the merge's
        # runtime cwd to the hook, whose gh-pr-view==origin equality is the actual
        # wrong-repo guard (ADR 0018).
        # Reject a `..` component: Bash's default LOGICAL `cd` cancels `..` textually
        # (`/repo-a/link/..` → `/repo-a`) while the downstream `git -C` resolves it
        # PHYSICALLY through symlinks (`link` → `/repo-b/…` → `/repo-b`), so the two can
        # land in different repos. A `..`-free absolute path resolves identically under
        # both. (A bare `..` inside a filename like `a..b` is harmless but also rejected
        # — conservative and never a real worktree path.)
        if rec['is_cd'] and not rec['had_reserved'] \
                and len(rest) == 1 and rest[0].startswith('/') \
                and '..' not in rest[0] \
                and not MERGE_SEG_UNSAFE_RE.search(rest[0]):
            rec['cd_literal'] = True
            rec['cd_target'] = rest[0]
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
                # #427: strip the one pre-approved carve-out (a quoted simple $VAR after
                # --match-head-commit) BEFORE applying the allowlist, so pr-grind's own
                # trusted head-guard templates still nudge while any OTHER expansion
                # anywhere else in the segment remains caught.
                if MERGE_SEG_UNSAFE_RE.search(SAFE_MATCH_HEAD_RE.sub('', seg)):
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
        # SUCCESS-COMPOSITION: a trusted merge-first cd only sets the merge's cwd when
        # the merge is reached by SEQUENTIAL, success-composing operators (';'/newline
        # or '&&'). A '||' before the merge makes the merge run ONLY IF a prior step
        # FAILED — `cd /repo-b || gh pr merge` runs the merge in the ORIGINAL cwd (or
        # not at all if the cd succeeded) while target_dir says /repo-b. '&'/'|' break
        # cwd inheritance the same way. Reject any such operator anywhere from the first
        # prefix segment through the merge, so the standalone-cd target is trusted only
        # when it truly is the merge's runtime cwd (ADR 0018). ('&&' and ';'/newline are
        # the only operators that keep the cd and merge in one sequential cwd chain.)
        for _i in range(1, merge_index + 1):
            if recs[_i]['op'] in ('||', '|', '&'):
                unsafe = True
                break
        # A SINGLE builtin `cd` before the merge is statically composable: it resolves
        # against the payload cwd exactly as the downstream repo resolver does. TWO or
        # more cannot be composed without knowing the starting cwd — a later relative
        # `cd .` would be mis-resolved against the payload cwd instead of the earlier
        # target — so ANY multi-cd prefix is rejected (ADR 0018). Count the `cd`
        # BUILTIN by command word (cw == 'cd'); an external `/tmp/cd` cannot change the
        # shell's cwd and is handled as an ordinary command word below.
        pre_merge_cd_total = sum(
            1 for i, rc in enumerate(recs) if i < merge_index and rc['cw'] == 'cd')
        if pre_merge_cd_total > 1:
            unsafe = True
        standalone_cd = ''      # the single plain-literal `cd` before a non-&&-captured merge
        for idx, rec in enumerate(recs):
            if idx > merge_index:
                break                                      # after-merge → cannot re-target
            if idx == merge_index:
                if rec['sensitive']:
                    unsafe = True                          # inline sensitive prefix ON the merge
                continue
            # MERGE-FIRST: before the merge, allow ONLY the captured cd prefix, a
            # standalone PLAIN-LITERAL `cd` (its target handed to the hook's
            # gh-pr-view==origin equality guard — ADR 0018), and pure non-sensitive
            # assignments / reserved-only segments (cw == ''). A sensitive assignment,
            # a $(retargeter), or ANY other real command word → skip (complete: no
            # need to enumerate which commands re-target).
            # A subshell-grouped pre-merge segment (`( cd /x )`) cannot set the merge's
            # cwd — reject BEFORE the captured-cd allowance so `( cd /x ) && merge`
            # (which gh_pr would otherwise trust) is skipped too.
            if rec['subshell']:
                unsafe = True
                continue
            if idx == captured_cd_idx:
                continue
            # Standalone literal cd is safe ONLY when the command word is the `cd`
            # BUILTIN (cw == 'cd', not an external `/tmp/cd`) AND the segment carries no
            # sensitive assignment or $(retargeter) — e.g. `X="$(git remote set-url …)"
            # cd .` must NOT be trusted just because it ends in a literal cd.
            if rec['cw'] == 'cd' and rec['cd_literal'] \
                    and not rec['subst_rt'] and not rec['sensitive']:
                standalone_cd = rec['cd_target']           # single cd → the merge's runtime cwd
                continue
            if rec['sensitive'] or rec['subst_rt'] or rec['cw'] != '':
                unsafe = True
        # When gh_pr did NOT capture an &&-prefix cd, the merge runs in the single
        # standalone literal cd (if any) — surface it so the hook resolves the repo
        # the merge actually targets, not the payload cwd.
        if not target_dir and standalone_cd:
            target_dir = standalone_cd

    print('yes')
    print(target_dir)
    print(positional)
    print('1' if unsafe else '')
    print(cwd)


try:
    main()
except Exception:
    pass
