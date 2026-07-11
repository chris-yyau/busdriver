#!/usr/bin/env bash
# scripts/advisory-downgrade-optin.sh — resolve whether ADR 0012's bounded
# advisory-bot stale-ack timeout downgrade is opted in for THIS repo.
#
# Opt-in is a PER-REPO file: <main-root>/<STATE_DIR>/pr-grind-advisory-downgrade.local.
# To opt in across many repos, the operator drops that file into each with a trusted loop,
# or runs scripts/enable-advisory-downgrade.py (issue #326 — explicit repo paths only;
# writes via openat + O_NOFOLLOW; delegates acceptance back to THIS resolver). There is
# deliberately NO global env-var / global-file
# switch: an env var can be set by a repo's committed .claude/settings.json (Claude Code
# applies its `env` block) and a global marker file is likewise repo-injectable — either
# would let the PR being graded enable its OWN downgrade, violating ADR 0012's "a
# repo-controlled config cannot enable it." A per-repo file the operator places
# (untracked, gitignored) keeps consent operator-owned. See ADR 0012 + the 2026-07-10
# council (unanimous: per-repo file + one-shot helper, no global consent surface).
#
# The marker is accepted as OPERATOR consent only when it is a non-symlink REGULAR file,
# in a non-symlink / non-gitlink state dir, that is NOT repo-controlled (present in
# neither the index nor HEAD's tree). Every git query fails CLOSED (reject) on error — a
# git error is NEVER read as "untracked => enable".
#
# CONTRACT — prints exactly `1` (opted in) or `0` (not) to stdout; always exit 0.
#   FAIL-CLOSED: an unresolvable/unqueryable repo or any git error prints `0`.
#
# Env:
#   BUSDRIVER_STATE_DIR   per-repo state dir name (default `.claude`).
# The main-repo root is derived PURELY from git (CWD) — there is deliberately no env
# override, because a committed `.claude/settings.json` `env` block can set arbitrary
# env vars, and a repo-supplied override must never point the resolver at another
# checkout's marker. Tests exercise it by running from inside a fixture repo.
set -u

# Neutralize repo-supplied git-environment injection: a committed `.claude/settings.json`
# `env` block could set GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_INDEX_FILE / config
# overrides to redirect our git queries at another checkout and self-enable the downgrade.
# Unset the documented repo-discovery + config vars so every git command below discovers
# the repo purely from CWD (which the SKILL pins to the PR's own worktree).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT 2>/dev/null || true

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
FILE="pr-grind-advisory-downgrade.local"

# BUSDRIVER_STATE_DIR is itself repo-injectable (a committed `.claude/settings.json` `env`
# block can set arbitrary env vars). A MULTI-COMPONENT value like `alias/.claude` — with
# `alias` a tracked symlink into a tracked dir — would slip a repo-controlled marker past
# the final-component symlink checks below while `_repo_controlled` queries the lexical
# path. Require a plain single dir NAME; anything else (traversal / slash / empty) fails
# CLOSED.
case "$STATE_DIR" in ''|.|..|*/*) echo 0; exit 0 ;; esac

# Return 0 (== "repo-controlled, REJECT") iff the marker <path>, inside the git work
# tree rooted at <root>, is: in a gitlink/submodule state dir (mode 160000), OR present
# in the index, OR present in HEAD's tree. FAIL-CLOSED: any git error returns 0 (reject).
# Returns 1 only when provably none hold.
_repo_controlled() {   # <marker_path> <repo_root>
    local path="$1" root="$2" rel dir_rel stage tracked
    rel="${path#"${root%/}"/}"
    dir_rel=$(dirname "$rel")
    stage=$(git -C "$root" ls-files --stage -- "$dir_rel" 2>/dev/null) || return 0
    grep -q '^160000 ' <<<"$stage" && return 0
    tracked=$(git -C "$root" ls-files -- "$rel" 2>/dev/null) || return 0
    [[ -n "$tracked" ]] && return 0
    # Is <rel> in HEAD's tree? `ls-tree` distinguishes the three outcomes `cat-file -e`
    # conflates: rc==0+entry → present (repo-controlled); rc==0+empty → trees readable,
    # marker absent (not repo-controlled); rc!=0 → a tree/subtree on the path is unreadable
    # (root OR nested corruption) or the repo is unborn. `HEAD^{tree}` only proves the ROOT
    # tree exists, so it misses a corrupt nested subtree — ls-tree does not. (Mirror of
    # gate_skip_file_repo_controlled in hooks/gate-scripts/lib/resolve-repo-dir.sh — keep in sync.)
    local head_entry rc
    head_entry=$(git -C "$root" ls-tree HEAD -- "$rel" 2>/dev/null); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        [[ -n "$head_entry" ]] && return 0              # in HEAD's tree → repo-controlled
        return 1                                        # readable trees, marker absent → not repo-controlled
    fi
    # ls-tree errored: corrupt tree object, or unborn HEAD. `rev-parse --verify HEAD` is 0
    # for a dangling/corrupt ref but 1 for unborn — splitting corrupt (fail CLOSED) from
    # unborn (not repo-controlled).
    git -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 && return 0   # corrupt tree → fail CLOSED (reject)
    return 1                                                                # unborn repo → not repo-controlled
}

# Resolve the MAIN repo root from CWD's git dir (--git-common-dir's parent is the
# main-repo root in BOTH worktree and plain-clone modes). Must be a queryable repo;
# FAIL-CLOSED otherwise.
# The MAIN work-tree root is where the operator's gitignored `.local` lives. For a linked
# worktree that is NOT this (ephemeral pr-grind) worktree — `git worktree add` does not copy
# gitignored files — so resolve it via `git worktree list`, whose FIRST entry is always the
# main worktree. Robust across linked worktrees and submodules. FAIL-CLOSED: not a repo
# => empty => `0` below.
# Capture git's output AND status first (a mid-stream git failure must fail CLOSED, not
# leave a partial root): `|| WT=""` discards any partial output on a nonzero git exit.
WT=$(git worktree list --porcelain 2>/dev/null) || WT=""
MAIN_ROOT=$(printf '%s\n' "$WT" | awk '/^worktree /{print substr($0, 10); exit}')
# `--separate-git-dir` quirk: for a main worktree created with
# `git init --separate-git-dir`, the porcelain `worktree` line reports the
# SEPARATE GIT DIR, not the checkout — and git stores no reverse pointer
# (core.worktree is empty), so the gitdir path cannot be mapped back to the
# checkout. `--is-inside-work-tree` prints `false` with EXIT 0 on such a gitdir,
# so compare the printed value, not the exit status.
_is_wt=$(git -C "$MAIN_ROOT" rev-parse --is-inside-work-tree 2>/dev/null || true)
if [[ -n "$MAIN_ROOT" && "$_is_wt" != "true" ]]; then
    # Recover the checkout via the current work-tree toplevel ONLY when we ARE the
    # main worktree (in-place run) — i.e. git-dir == git-common-dir. From a LINKED
    # worktree the separate-git-dir main checkout is unreachable, and trusting the
    # linked worktree's toplevel would FAIL OPEN on a marker planted there (the
    # consent must come from the main checkout). So fail CLOSED (empty => `0`) then.
    _gd=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
    _gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [[ -n "$_gd" && "$_gd" == "$_gcd" ]]; then
        MAIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || MAIN_ROOT=""
    else
        MAIN_ROOT=""
    fi
fi
if [[ -n "$MAIN_ROOT" ]]; then
    ppath="${MAIN_ROOT%/}/${STATE_DIR}/${FILE}"
    pdir="${MAIN_ROOT%/}/${STATE_DIR}"
    if [[ -f "$ppath" && ! -L "$ppath" && ! -L "$pdir" ]] \
       && git -C "$MAIN_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
       && ! _repo_controlled "$ppath" "$MAIN_ROOT"; then
        echo 1
        exit 0
    fi
fi

echo 0
exit 0
