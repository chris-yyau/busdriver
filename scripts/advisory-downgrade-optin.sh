#!/usr/bin/env bash
# scripts/advisory-downgrade-optin.sh — resolve whether ADR 0012's bounded
# advisory-bot stale-ack timeout downgrade is opted in for THIS repo.
#
# WHY: ADR 0012's opt-in was per-repo only (`<repo>/.claude/pr-grind-advisory-
# downgrade.local`). A solo operator who wants the affordance on every one of
# their repos had to drop the file into each checkout. This resolver adds a
# GLOBAL opt-in (`$HOME/.claude/pr-grind-advisory-downgrade.local`) so a single
# file switches it on everywhere, while the per-repo file still works unchanged.
# Either present => opted in. The switch is safe because it does NOT open the
# gate: advisory-stale-downgrade.sh still re-checks CI_GREEN + LITMUS_GREEN +
# 0-findings + no-live-signal and never touches merge authority. See ADR 0012.
#
# OPERATOR-CONSENT BOUNDARY (ADR 0012: "a repo-controlled config cannot enable
# it"). A PR author who could get a marker accepted as consent could self-enable
# the downgrade for their own PR when the operator grinds it. So EITHER marker is
# accepted only when it is a non-symlink REGULAR file, in a non-symlink state dir,
# and — if it lives inside a git work tree — is NOT repo-controlled (its state dir
# is not a gitlink, and the marker is in neither the index nor HEAD's tree). The
# global file normally lives outside any repo ($HOME/.claude) and is operator space
# by construction; the in-repo check only matters for the exotic case where the
# global dir itself sits inside a repo (e.g. a dotfiles repo rooted at $HOME).
#
# CONTRACT — prints exactly `1` (opted in) or `0` (not) to stdout; always exit 0.
#   The value lives in STDOUT (mirrors advisory-stale-downgrade.sh), so the
#   pr-grind caller consumes it as `OPTIN=$(… advisory-downgrade-optin.sh)`.
#   FAIL-CLOSED: this opt-in RELAXES a gate, so any ambiguity prints `0`. For the
#   per-repo path, an unresolvable/unqueryable repo or ANY git error rejects (a
#   git error is NEVER read as "untracked => enable"). For the global path, a
#   marker that is NOT inside a repo is operator consent (the normal case); it is
#   rejected only when it IS inside a repo AND provably repo-controlled.
#
# Env:
#   BUSDRIVER_STATE_DIR        per-repo state dir name (default `.claude`).
#   BUSDRIVER_GLOBAL_STATE_DIR global state dir (default `$HOME/.claude`).
#   BUSDRIVER_MAIN_ROOT        test seam — overrides the git-derived main-repo
#                              root so the per-repo lookup needs no real checkout.
set -u

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
FILE="pr-grind-advisory-downgrade.local"

# Return 0 (== "repo-controlled, REJECT") iff the marker <path>, which lives inside
# the git work tree rooted at <root>, is: in a gitlink/submodule state dir (mode
# 160000), OR present in the index, OR present in HEAD's tree. FAIL-CLOSED: any git
# error returns 0 (reject). Returns 1 only when provably none of these hold.
_repo_controlled() {   # <marker_path> <repo_root>
    local path="$1" root="$2" rel dir_rel stage tracked
    rel="${path#"${root%/}"/}"
    dir_rel=$(dirname "$rel")
    # State dir is a gitlink/submodule — the parent index can't see a marker
    # embedded inside it as tracked, so reject the whole subtree.
    stage=$(git -C "$root" ls-files --stage -- "$dir_rel" 2>/dev/null) || return 0
    grep -q '^160000 ' <<<"$stage" && return 0
    # In the index (e.g. a `git add -f` of the gitignored marker).
    tracked=$(git -C "$root" ls-files -- "$rel" 2>/dev/null) || return 0
    [[ -n "$tracked" ]] && return 0
    # In HEAD's tree (committed then de-indexed with `git rm --cached` — still a
    # repo-originated marker). Only meaningful when HEAD exists (a fresh repo with
    # no commits has nothing committed).
    if git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null && return 0
    fi
    return 1
}

# --- Global opt-in (repo-independent operator consent) — checked first so it holds
#     even when the repo root can't be resolved. ---
# `${HOME:-}` guards `set -u`; leave GLOBAL_BASE empty (skip the global check) when
# neither BUSDRIVER_GLOBAL_STATE_DIR nor HOME is set — never collapse the default to
# a root-level `/.claude` that a container/system env could hold.
GLOBAL_BASE="${BUSDRIVER_GLOBAL_STATE_DIR:-}"
if [[ -z "$GLOBAL_BASE" && -n "${HOME:-}" ]]; then
    GLOBAL_BASE="${HOME%/}/.claude"
fi
if [[ -n "$GLOBAL_BASE" ]]; then
    gpath="${GLOBAL_BASE%/}/${FILE}"
    if [[ -f "$gpath" && ! -L "$gpath" && ! -L "${GLOBAL_BASE%/}" ]]; then
        # Normally $HOME/.claude is outside any repo => operator consent. If it DOES
        # resolve inside a git work tree (dotfiles repo rooted at $HOME, or a global
        # dir pointed into a repo), apply the same repo-controlled rejection so a PR
        # to THAT repo cannot add the global marker and self-enable.
        groot=$(git -C "${GLOBAL_BASE%/}" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -z "$groot" ]]; then
            echo 1; exit 0            # not inside a repo => operator consent
        elif ! _repo_controlled "$gpath" "$groot"; then
            echo 1; exit 0            # inside a repo but provably not repo-controlled
        fi
        # else: repo-controlled global marker => reject; fall through to per-repo.
    fi
fi

# --- Per-repo opt-in. Resolve the MAIN repo root (--git-common-dir's parent is the
#     main-repo root in BOTH worktree and plain-clone modes). Must be a queryable
#     repo; FAIL-CLOSED otherwise. ---
MAIN_ROOT="${BUSDRIVER_MAIN_ROOT:-}"
if [[ -z "$MAIN_ROOT" ]]; then
    GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$GCD" in /*) MAIN_ROOT="$(dirname "$GCD")" ;; esac
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
