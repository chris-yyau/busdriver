#!/usr/bin/env bash
# PreToolUse hook: deterministic `@codex review` nudge on `gh pr merge`.
#
# WHY: the ADR 0013 `none`-nudge (post `@codex review` when Codex never engaged
# on a PR that a Codex-active repo expects it to) was PROSE — a bash block buried
# in skills/pr-grind/SKILL.md's COMPLETION section that only fires if the grinding
# agent executes it verbatim. It therefore SILENTLY no-ops on every merge path
# that reaches "clean" without running that block: the pre-merge gate's
# bootstrap-merge bypass (gate-modifying PRs), skip-pr-grind bypasses, worktree
# `--admin` squashes, and any run where the agent shortcut to the marker. The
# ONLY deterministic enforcement (pre-merge-gate.sh) checks a pr-grind-clean
# marker + green CI and never verifies the nudge ran. This hook makes the nudge
# fire on the merge-INTENT event instead of agent prose — the one deterministic
# point that is post-CI-settle AND pre-merge — so it catches exactly the cases
# the SKILL prose misses.
#
# SCOPE — pure trigger. The MECHANISM (force-on/active policy, one-shot-per-
# (PR,HEAD) marker, the actual `gh pr comment`, opt-out, phrase override) is the
# existing scripts/codex-nudge-if-expected.sh → codex-retrigger.sh chain,
# delegated to unchanged. This hook adds two things they lack at merge time:
#   1. the deterministic firing point (a PreToolUse hook on `gh pr merge`), and
#   2. the `none` GUARD — the wrapper nudges whenever the repo is active, so
#      without this check it would post a redundant `@codex review` on EVERY
#      merge of a PR Codex already reviewed. We nudge ONLY when Codex has zero
#      engagement (no review, no reaction) on the PR — matching the SKILL's
#      `CODEX_DONE == "none"` policy. `stale` Codex is handled elsewhere (the
#      in-loop retrigger, ADR 0005); we must not double-fire on it here.
#
# TARGET SAFETY (the load-bearing invariant) — we do NOT try to reconstruct gh's
# full repo/PR/host resolution from the command string; that surface (global vs
# subcommand `-R`, GH_REPO/GH_HOST, PR URLs, branch names, GHE hosts) is too large
# to replicate without eventually nudging the WRONG PR. Instead we FIRE ONLY WHEN
# the merge provably targets THIS repo — the one the command runs in:
#   (a) parse rejects (→ skip) any per-command override we can't neutralize: a
#       `-R`/`--repo` flag anywhere in the invocation, an inline `GH_REPO=`/
#       `GH_HOST=` assignment, or a non-numeric positional (branch / PR URL);
#   (b) we DELEGATE resolution to gh (`gh pr view [<num>] --json number,headRefOid,
#       url`) in the merge's own cwd + env, then REQUIRE the resolved
#       host/owner/repo to EQUAL the cwd repo's `origin` (github.com only). Any
#       divergence — inherited GH_REPO/GH_HOST, a cross-repo/cross-host URL — fails
#       the equality check and skips.
# Because the fire path is gated on target == cwd repo, the force-on marker and the
# delegate's one-shot dedup marker (both anchored on the cwd repo) are ALWAYS the
# target repo's own — never repo A's consent triggering a nudge on repo B. Anything
# not covered here is still covered by the SKILL-prose nudge.
#
# NON-GATING — this hook NEVER blocks a merge. It emits NOTHING to stdout and
# always exits 0 (approve). A bug here cannot break merges; the worst failure is
# a missed or (bounded, deduped) redundant nudge. FAIL-SAFE = SKIP: on any parse/
# query error we exit 0 WITHOUT posting, so we never emit a spurious `@codex
# review` (the inverse of the security gates, which fail-CLOSED to a block — a
# nudge that fails closed would spam comments).
#
# Runs under lib/sanitized-gate.sh (ADR 0016 env containment), like the gates.
# PR_GRIND_CODEX_RETRIGGER (kill switch), BUSDRIVER_STATE_DIR, and GH_REPO/GH_HOST
# are re-imported through the hooks.json `env -i` line: unlike the review gates,
# disabling or re-targeting a NUDGE is not a merge/review bypass, so passing them
# is safe — and GH_REPO/GH_HOST let `gh pr view` resolve as the merge will, which
# the target==cwd equality check below then confirms (or rejects) anyway.
set -u

# ── Read the PreToolUse payload once ───────────────────────────────────
HOOK_DATA=$(cat 2>/dev/null || true)
[[ -z "$HOOK_DATA" ]] && exit 0

# Fast pre-filter: bail on anything that can't be a `gh pr merge` before paying
# for python/gh. Match `pr`…`merge` WITHOUT requiring a literal adjacent `gh`, so
# quoted/escaped executable forms (g"h" pr merge, g\h pr merge) still reach the
# quote-aware detector; the `pr`+`merge` subcommand tokens are what the caller
# always writes unquoted. Still a near-no-op for the vast majority of Bash calls.
case "$HOOK_DATA" in
    *pr*merge*) ;;
    *) exit 0 ;;
esac

# Kill switch — PR_GRIND_CODEX_RETRIGGER=0 disables the whole nudge chain (the
# delegate honors it too, but short-circuit here to skip all network work).
[[ "${PR_GRIND_CODEX_RETRIGGER:-1}" == "0" ]] && exit 0

command -v python3 >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$DIR/../../scripts"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$DIR/lib/resolve-repo-dir.sh"

# ── Parse via the shared, quote/wrapper-aware detector ─────────────────
# gh_pr confirms a REAL `gh pr merge` (defeats decoys/quoting/wrappers). A second,
# segment-scoped shlex pass inspects ONLY the gh COMMAND-WORD segment (so an
# `echo gh pr merge -R x` decoy cannot inject) and marks UNSAFE any per-command
# override we cannot neutralize: a `-R`/`--repo` flag (global — before `pr` — OR
# after `merge`), an inline `GH_REPO=`/`GH_HOST=` assignment, or a non-numeric
# positional (branch name / PR URL). Only a bare numeric PR (or none = current
# branch) is safe. On ANY parse error we emit nothing → skip (non-gating).
PARSE=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$DIR/lib" python3 -S -c "
import sys
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json, re, shlex
    from gitcmd_detect import gh_pr, split_segments
    d = json.load(sys.stdin)
    if d.get('tool_name', d.get('toolName', '')) != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    is_merge, target_dir, _pr = gh_pr(cmd, 'merge')
    if not is_merge:
        sys.exit(0)
    # gh pr merge flags that consume a following value (must not be read as the PR);
    # both long and short forms (short forms per gh pr merge --help).
    VALFLAGS = {'--author-email', '-A', '--body', '-b', '--body-file', '-F',
                '--match-head-commit', '--subject', '-t'}
    def is_repo_flag(t):
        return t in ('-R', '--repo') or t.startswith('--repo=') or (t.startswith('-R') and len(t) > 2)
    # Fire ONLY on the tightest canonical shape, because ANY preceding command or
    # non-trivial control flow can mutate the state a static hook can't see. Required:
    #   * the ONLY shell operators are '' (single command) and '&&' — any ';', '|',
    #     '||', '&' makes the runtime state (which cd wins, what ran) undecidable;
    #   * exactly ONE segment invoking the LITERAL executable 'gh' (not /tmp/gh, not
    #     a wrapper) as 'gh pr merge';
    #   * every OTHER segment is a bare literal 'cd' (honored only via the &&-cd form
    #     gh_pr captures into target_dir — see the has_cd/target_dir guard below);
    #   * NO env-assignment prefix anywhere (GIT_DIR=, GH_REPO=, anything can redirect);
    #   * NO gh pr non-merge prefix (checkout re-points the branch!), NO shell
    #     expansion, NO -R. Everything else -> UNSAFE (skip); SKILL prose still covers it.
    found = False; positional = ''; unsafe = False; merge_count = 0; has_cd = False
    for op, seg in split_segments(cmd):
        if op not in ('', '&&'):
            unsafe = True            # ';', '|', '||', '&' -> runtime state undecidable
        if not seg.strip():
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            unsafe = True; continue
        if not toks:
            continue
        i = 0
        while i < len(toks) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[i]):
            unsafe = True; i += 1    # ANY env-assignment prefix (GIT_DIR=, GH_REPO=, ...) -> skip
        if i >= len(toks):
            continue                 # nothing but assignments (already marked unsafe if any)
        tok = toks[i]                # LITERAL executable token — no basename, no wrapper
        if tok == 'cd':
            has_cd = True; continue  # honored only via the target_dir guard after the loop
        if tok != 'gh':
            unsafe = True; continue  # /tmp/gh, a wrapper, or an arbitrary command -> skip
        rest = toks[i + 1:]
        if 'pr' not in rest:
            unsafe = True; continue  # gh NON-pr subcommand (repo/config/auth ...) -> skip
        pri = rest.index('pr')
        after = rest[pri + 1:]
        if not after or after[0] != 'merge':
            unsafe = True; continue  # gh pr <non-merge> (checkout mutates the branch!) -> skip
        merge_count += 1; found = True
        if any(is_repo_flag(g) for g in rest[:pri]):   # global -R before the subcommand
            unsafe = True
        # Any shell expansion in the invocation (a variable, command substitution, or
        # backtick) is opaque to a static parser and could expand to a repo override
        # or positional at runtime. Fail-safe: skip when the segment contains one.
        if chr(36) in seg or chr(96) in seg:
            unsafe = True
        margs = after[1:]; j = 0
        while j < len(margs):
            t = margs[j]
            if is_repo_flag(t):
                unsafe = True
                j += 2 if t in ('-R', '--repo') else 1
                continue
            if t in VALFLAGS:
                j += 2; continue
            if t.startswith('-'):
                j += 1; continue
            if not positional:
                positional = t
            j += 1
    if not found or merge_count != 1:   # zero/unparsed, or multiple merges in one call
        unsafe = True
    if has_cd and not target_dir:       # a cd NOT captured as the merge's and-and prefix
        unsafe = True                   # (e.g. 'cd B; gh pr merge') -> REPO_DIR would be wrong
    if positional and not re.match(r'^[0-9]+$', positional):
        unsafe = True             # branch name / PR URL → skip
    print('yes')
    print(target_dir)
    print(positional)
    print('1' if unsafe else '')
    print(cwd)
except Exception:
    pass
" 2>/dev/null || true)

IS_MERGE=$(printf '%s' "$PARSE" | sed -n '1p')
TARGET_DIR=$(printf '%s' "$PARSE" | sed -n '2p')
POSITIONAL=$(printf '%s' "$PARSE" | sed -n '3p')
UNSAFE=$(printf '%s' "$PARSE" | sed -n '4p')
HOOK_CWD=$(printf '%s' "$PARSE" | sed -n '5p')

[[ "$IS_MERGE" == "yes" ]] || exit 0
[[ -n "$UNSAFE" ]] && exit 0      # per-command override we can't neutralize → skip

# INHERITED GH_REPO/GH_HOST re-target the merge to a repo/host our default-host gh
# calls (and the delegate's `gh pr comment -R owner/repo`) would NOT match. They are
# passed through the env -i line ONLY so we can detect them here: if either is set,
# skip; otherwise clear them so EVERY gh call — ours and the delegate's — resolves
# the same single default host, keeping resolution and the comment target consistent.
[[ -n "${GH_REPO:-}" || -n "${GH_HOST:-}" ]] && exit 0
unset GH_REPO GH_HOST

# ── Resolve the repo dir the merge runs in ─────────────────────────────
gate_resolve_repo_dir "$TARGET_DIR" "$HOOK_CWD"
[[ "$GATE_RESOLVE_STATUS" == "proceed" ]] || exit 0
REPO_DIR="$GATE_REPO_DIR"

# cwd repo canonical host/owner/repo from origin (offline). github.com only —
# a non-github origin (GHE) is skipped: the delegate's `gh pr comment` uses the
# default host, so we only act where that host is correct.
CWD_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
CWD_CANON=$(printf '%s' "$CWD_URL" | sed -E 's#^git@#https://#; s#^https?://##; s#:#/#; s#\.git/?$##; s#/+$##')
case "$CWD_CANON" in github.com/*/*) : ;; *) exit 0 ;; esac
case "$CWD_CANON" in github.com/*/*/*) exit 0 ;; esac   # more than owner/repo → reject
SLUG="${CWD_CANON#github.com/}"
OWNER="${SLUG%%/*}"; NAME="${SLUG#*/}"
[[ -n "$OWNER" && -n "$NAME" ]] || exit 0
printf '%s' "$OWNER$NAME" | LC_ALL=C grep -q '[^A-Za-z0-9._-]' && exit 0

# ── Delegate resolution to gh, then REQUIRE resolved target == cwd repo ──
# `gh pr view` resolves exactly the PR the merge targets (honoring the inherited
# env we passed through). We then compare its canonical url to the cwd origin: any
# divergence (inherited GH_REPO/GH_HOST, a cross-repo/cross-host URL) → skip.
if [[ -n "$POSITIONAL" ]]; then
    PRJSON=$( (cd "$REPO_DIR" 2>/dev/null && gh pr view "$POSITIONAL" --json number,headRefOid,url 2>/dev/null) || true)
else
    PRJSON=$( (cd "$REPO_DIR" 2>/dev/null && gh pr view --json number,headRefOid,url 2>/dev/null) || true)
fi
[[ -n "$PRJSON" ]] || exit 0
PR=$(printf '%s' "$PRJSON" | jq -r '.number // empty' 2>/dev/null) || exit 0
HEAD_SHA=$(printf '%s' "$PRJSON" | jq -r '.headRefOid // empty' 2>/dev/null) || exit 0
URL=$(printf '%s' "$PRJSON" | jq -r '.url // empty' 2>/dev/null) || exit 0
case "$PR" in ''|*[!0-9]*) exit 0 ;; esac
case "$HEAD_SHA" in ''|*[!0-9A-Fa-f]*) exit 0 ;; esac

# Canonical host/owner/repo of the resolved PR (strip scheme + `/pull/N`). Compare
# case-INSENSITIVELY: GitHub owner/repo are case-insensitive, and the origin may
# carry user-entered casing that differs from gh's canonical form.
VIEW_CANON=$(printf '%s' "$URL" | sed -E 's#^https?://##; s#/pull/[0-9]+/?$##; s#/+$##')
CWD_LC=$(printf '%s' "$CWD_CANON" | tr '[:upper:]' '[:lower:]')
VIEW_LC=$(printf '%s' "$VIEW_CANON" | tr '[:upper:]' '[:lower:]')
[[ "$VIEW_LC" == "$CWD_LC" ]] || exit 0           # target != cwd repo → skip (fail-safe)

# ── Active-or-force-on gate (skips the none-check on idle repos) ────────
# Resolve the force-on marker EXACTLY where the delegate (codex-nudge-if-expected.sh)
# does — the MAIN repo root (git-common-dir's parent, so it holds from a linked
# worktree) under a hardcoded `.claude` — so this pre-filter and the delegate agree
# on whether force-on is active. (STATE_DIR is intentionally NOT used here.)
FORCEON=0
_GCD=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
case "$_GCD" in
    /*) [[ -f "$(dirname "$_GCD")/.claude/pr-grind-codex-expected.local" ]] && FORCEON=1 ;;
esac
ACTIVE=0
if bash "$SCRIPTS/codex-active-repo.sh" "$OWNER/$NAME" >/dev/null 2>&1; then ACTIVE=1; fi
[[ "$FORCEON" == "1" || "$ACTIVE" == "1" ]] || exit 0

# ── `none`-guard: nudge ONLY when Codex has ZERO engagement on this PR ──
# Paginate FULLY (--paginate), never a single 100-item page, so engagement beyond
# the first page is never missed — a false `none` would post a redundant nudge.
# ANY fetch error → exit 0, no post. Bare + [bot]-suffixed login (per ADR 0002).
REVIEW_LOGINS=$(gh api --paginate "repos/$OWNER/$NAME/pulls/$PR/reviews" --jq '.[].user.login' 2>/dev/null) || exit 0
REACTION_LOGINS=$(gh api --paginate "repos/$OWNER/$NAME/issues/$PR/reactions" --jq '.[].user.login' 2>/dev/null) || exit 0
if printf '%s\n%s\n' "$REVIEW_LOGINS" "$REACTION_LOGINS" \
   | grep -qxE 'chatgpt-codex-connector(\[bot\])?'; then
    exit 0                            # Codex already engaged → not `none` → no nudge
fi

# ── Delegate the one-shot post ─────────────────────────────────────────
# cd into the repo dir (== the resolved target repo, verified above) so the
# wrapper's force-on root and codex-retrigger's per-(PR,HEAD) marker are anchored
# on the PR's own repo (shared with the SKILL path's marker → at most one `@codex
# review` per HEAD across both). Route all delegate output to stderr so this hook's
# stdout stays empty (approve). `|| true` so a failed nudge can never affect merge.
( cd "$REPO_DIR" 2>/dev/null || exit 0
  bash "$SCRIPTS/codex-nudge-if-expected.sh" "$PR" "$HEAD_SHA" "$OWNER/$NAME" "$ACTIVE" ) 1>&2 || true
exit 0
