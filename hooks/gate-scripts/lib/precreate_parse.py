#!/usr/bin/env python3
"""precreate_parse.py — parser for codex-nudge-precreate.sh (issue #473).

Reads a PostToolUse hook payload (JSON) on stdin. Emits NOTHING (skip) unless the
Bash tool call is a SUCCESSFUL, LONE `gh pr create`, in which case it prints:

    line 1 : yes
    line 2 : json.dumps(target_dir)   # cd-&&-prefix dir gh_pr captured, or ""
    line 3 : json.dumps(cwd)          # payload cwd
    line 4+: lowercased owner/repo/number keys for every github.com PR URL printed

Lives as a FILE (not an inline `python3 -c`) like the sibling nudge_parse.py: the
create-integrity logic needs `$(`, backticks and `${` as literals, which a bash
double-quoted `-c "…"` string would mangle as command substitution / expansion.

It deliberately imports ONLY from gitcmd_detect (gh_pr, split_segments,
strip_continuations) — importing nudge_parse would run that module's unguarded
main(), which reads stdin and would swallow this hook's payload. The two tiny
helpers it needs (assign-name / sensitive-env) are inlined below. strip_comments is
intentionally NOT used: skipping it is fail-safe — a `#`-commented shell operator
just makes lone_create over-reject (a MISS), never a mistarget.

LONE-CREATE integrity: a PostToolUse hook reads POST-command shell state, so a
compound that moves cwd/origin/branch around the create (`… && cd B`,
`git remote set-url … && gh pr create`, `-R other/repo`, a substitution) would let
the caller's later `gh pr view` resolve a DIFFERENT repo. We therefore emit `yes`
ONLY when the create is the command's ONE real statement — only a plain
`cd <literal>` and non-sensitive assignments may precede it, NOTHING may execute
after it, and the create segment carries no `-R`/`--repo`, no substitution, and no
sensitive (GH_/GIT_/PATH/CDPATH) env — so the post-command cwd/origin the hook reads
IS the create's. Any other shape is a fail-safe MISS (the premerge nudge backstops
it). Quote-aware throughout (shared split_segments / shlex).
"""
import sys
import re
import json
import shlex

# Drop CWD from sys.path (a bare `python3 file.py` prepends the script's dir; also
# guard '' / '.') so a repo-planted gitcmd_detect.py / shadowed stdlib cannot run in
# the hook. The gate lib dir is passed on PYTHONPATH.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]

_ASSIGN_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\+?=')


def _assign_name(tok):
    m = _ASSIGN_RE.match(tok)
    return m.group(1) if m else ''


def _is_sensitive_name(name):
    # PATH/CDPATH re-point command/cd resolution; GH_*/GIT_* re-point gh/git remotes.
    return (name == 'PATH' or name == 'CDPATH'
            or name.startswith('GH_') or name.startswith('GIT_'))


def _skip():
    sys.exit(0)


def lone_create(command, gh_pr, split_segments, strip_continuations):
    """True iff `command` is a single `gh pr create` whose pre/post shell state the
    hook can trust. Fail-safe: any doubt → False (→ the hook skips)."""
    try:
        pairs = split_segments(strip_continuations(command))
    except Exception:
        return False
    segs = [(op, s) for op, s in pairs if s.strip()]
    if not segs:
        return False
    cpos = [i for i, (op, s) in enumerate(segs) if gh_pr(s, 'create')[0]]
    if len(cpos) != 1:                       # exactly one create statement
        return False
    ci = cpos[0]
    if ci != len(segs) - 1:                  # NOTHING executes after the create
        return False
    if segs[ci][0] in ('|', '&'):            # create not piped/backgrounded into
        return False
    for j in range(ci):                      # only cd<literal>/assignments precede
        op, s = segs[j]
        if op in ('|', '&'):
            return False
        try:
            toks = shlex.split(s)
        except ValueError:
            return False
        k = 0
        while k < len(toks) and _assign_name(toks[k]):
            if _is_sensitive_name(_assign_name(toks[k])):
                return False
            k += 1
        rest = toks[k:]
        if rest and not (rest[0] in ('cd', 'pushd') and len(rest) == 2
                         and not rest[1].startswith('-')):
            return False
    cs = segs[ci][1]                         # create segment: no substitution/expansion
    if '$(' in cs or '`' in cs or '${' in cs:
        return False
    try:
        ctoks = shlex.split(cs)
    except ValueError:
        return False
    # The create must be a DIRECT `gh` invocation. gh_pr recurses INTO `bash -c '…'`,
    # `sh -c`, `eval`, `env`, `xargs`, `sudo`, … to find the create — but such a
    # wrapper can hide a whole compound (`bash -c 'gh pr create; git remote set-url …;
    # printf <other-url>'`) that split_segments cannot see (it is one quoted arg). So
    # require the command word (first token after non-sensitive assignments) to be
    # `gh` (bare or path-suffixed); any wrapper → fail-safe MISS.
    w = 0
    while w < len(ctoks) and _assign_name(ctoks[w]):
        if _is_sensitive_name(_assign_name(ctoks[w])):
            return False
        w += 1
    if w >= len(ctoks):
        return False
    cw = ctoks[w]
    if not (cw == 'gh' or cw.endswith('/gh')):
        return False
    for t in ctoks[w:]:                      # no -R/--repo (creates in another repo)
        if t in ('-R', '--repo') or t.startswith('--repo=') or (t.startswith('-R') and len(t) > 2):
            return False
    return True


def main():
    try:
        from gitcmd_detect import gh_pr, split_segments, strip_continuations
    except Exception:
        _skip()

    try:
        d = json.load(sys.stdin)
    except Exception:
        _skip()

    if d.get('tool_name', d.get('toolName', '')) != 'Bash':
        _skip()
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except Exception:
            _skip()
    cmd = inp.get('command', '') if isinstance(inp, dict) else ''

    present, target_dir, _pr = gh_pr(cmd, 'create')
    if not present:
        _skip()
    if not lone_create(cmd, gh_pr, split_segments, strip_continuations):
        _skip()

    def texts(obj):
        if isinstance(obj, str):
            return [obj]
        if isinstance(obj, dict):
            return [obj[k] for k in ('output', 'stdout', 'stderr') if isinstance(obj.get(k), str)]
        return []
    containers = [d.get('tool_response'), d.get('toolResponse'),
                  d.get('tool_output'), d.get('toolOutput')]
    output_text = '\n'.join(t for c in containers for t in texts(c))

    # Exit code (authoritative when reported); a compound '… || true' masks it, so an
    # ABSENT code falls back to URL + failure-signature. STRICT ASCII decimal only.
    exit_code = None
    for c in containers:
        if isinstance(c, dict):
            for k in ('exit_code', 'exitCode', 'returncode', 'returnCode', 'code'):
                if c.get(k) is not None:
                    exit_code = c[k]
                    break
        if exit_code is not None:
            break
    if exit_code is None:
        exit_ok = True
    elif isinstance(exit_code, bool):
        exit_ok = False
    elif isinstance(exit_code, int):
        exit_ok = exit_code == 0
    elif isinstance(exit_code, str) and re.fullmatch(r'-?[0-9]+', exit_code.strip()):
        exit_ok = int(exit_code.strip()) == 0
    else:
        exit_ok = False

    # 'GraphQL:' (with the colon) matches gh's error format but NOT a repo/owner
    # literally named graphql in a printed URL.
    failure_sig = bool(re.search(
        r'already exists|could not|failed to|create failed|GraphQL:|HTTP [45][0-9][0-9]|must first be pushed|no commits between|^error:|^fatal:',
        output_text, re.IGNORECASE | re.MULTILINE))
    urls = re.findall(r'https?://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)', output_text)
    if not (urls and exit_ok and not failure_sig):
        _skip()

    out = ['yes', json.dumps(target_dir), json.dumps(cwd)]
    seen = set()
    for o, r, n in urls:
        key = (o + '/' + r + '/' + n).lower()
        if key not in seen:
            seen.add(key)
            out.append(key)
    sys.stdout.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)   # fail-safe: any unexpected error → emit nothing (skip)
