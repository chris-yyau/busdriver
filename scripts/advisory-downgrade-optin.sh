#!/usr/bin/env bash
# scripts/advisory-downgrade-optin.sh — resolve whether ADR 0012's bounded
# advisory-bot stale-ack timeout downgrade is opted in for THIS repo.
#
# WHY: ADR 0012's opt-in was per-repo only (`<repo>/.claude/pr-grind-advisory-
# downgrade.local`). A solo operator who wants the affordance on every one of
# their repos had to drop the file into each checkout. This resolver adds a
# GLOBAL opt-in (`$HOME/.claude/pr-grind-advisory-downgrade.local`) so a single
# file switches it on everywhere, while the per-repo file still works unchanged.
# Either present => opted in. The global switch is safe because it does NOT open
# the gate: advisory-stale-downgrade.sh still re-checks CI_GREEN + LITMUS_GREEN +
# 0-findings + no-live-signal and never touches merge authority. See ADR 0012.
#
# CONTRACT — prints exactly `1` (opted in) or `0` (not) to stdout; always exit 0.
#   The value lives in STDOUT (mirrors advisory-stale-downgrade.sh), so the
#   pr-grind caller consumes it as `OPTIN=$(… advisory-downgrade-optin.sh)`.
#   FAIL-CLOSED: this opt-in RELAXES a gate, so any ambiguity prints `0` (stay
#   strict / BAIL). Concretely: an unresolvable main-repo root with no global
#   file => `0`. A present global file => `1` regardless of root (repo-independent
#   standing consent). Only a provably-present per-repo OR global file => `1`.
#
# Env:
#   BUSDRIVER_STATE_DIR        per-repo state dir name (default `.claude`).
#   BUSDRIVER_GLOBAL_STATE_DIR global state dir (default `$HOME/.claude`).
#   BUSDRIVER_MAIN_ROOT        test seam — overrides the git-derived main-repo
#                              root so the per-repo lookup needs no real checkout.
set -u

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
FILE="pr-grind-advisory-downgrade.local"

# Resolve the GLOBAL state dir. Explicit BUSDRIVER_GLOBAL_STATE_DIR wins; else
# default to $HOME/.claude — but ONLY when HOME is actually set. If neither is
# available the global root is UNRESOLVABLE: leave GLOBAL_BASE empty and skip the
# global check entirely. Fail-closed — never let an unset HOME collapse the default
# to a root-level `/.claude`, which a container/system env could hold and thereby
# relax the gate without the operator's global consent. (`${HOME:-}` also guards
# `set -u` from aborting nonzero without printing `0`.)
GLOBAL_BASE="${BUSDRIVER_GLOBAL_STATE_DIR:-}"
if [[ -z "$GLOBAL_BASE" && -n "${HOME:-}" ]]; then
    GLOBAL_BASE="${HOME%/}/.claude"
fi

# Global opt-in is repo-independent standing consent — check it first, so it holds
# even when the repo root can't be resolved.
if [[ -n "$GLOBAL_BASE" && -f "${GLOBAL_BASE%/}/${FILE}" ]]; then
    echo 1
    exit 0
fi

# Per-repo opt-in. Resolve the MAIN repo root (--git-common-dir's parent is the
# main-repo root in BOTH worktree and plain-clone modes — the same resolver the
# rest of the pr-grind opt-in ecosystem uses). BUSDRIVER_MAIN_ROOT short-circuits
# it for tests.
MAIN_ROOT="${BUSDRIVER_MAIN_ROOT:-}"
if [[ -z "$MAIN_ROOT" ]]; then
    GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    case "$GCD" in /*) MAIN_ROOT="$(dirname "$GCD")" ;; esac
fi

# ADR 0012 boundary: the per-repo opt-in is OPERATOR consent — "a repo-controlled
# config cannot enable it." A PR author who could get the marker accepted as
# consent could self-enable the downgrade for their own PR when the operator
# grinds it. So the marker must be a non-symlink REGULAR file, in a non-symlink,
# non-gitlink state dir, that is NOT present in the index. FAIL-CLOSED throughout:
# an unresolvable/unqueryable repo, ANY git error, or any of these conditions unmet
# falls through to the terminal `echo 0`. A git error is NEVER read as "untracked
# => enable" (that would be fail-OPEN).
#
# The index (`ls-files`) is the tracked-file authority: a marker committed on the
# branch is in the index after checkout, and a `git add -f` of the gitignored
# marker is in the index too — both are caught here. (No separate HEAD-tree probe:
# `git cat-file -e HEAD:<path>` cannot distinguish a benign "not in tree" from a
# fatal error, so it can't honor this fail-closed contract, and it adds nothing the
# index check doesn't already cover.)
_per_repo_optin() {
    [[ -n "$MAIN_ROOT" ]] || return 1
    local dir="${MAIN_ROOT%/}/${STATE_DIR}" rel="${STATE_DIR}/${FILE}" path stage tracked
    path="${dir}/${FILE}"
    # Regular file, and neither it nor the state dir is a symlink.
    [[ -f "$path" && ! -L "$path" && ! -L "$dir" ]] || return 1
    # Must be a queryable git repo — else operator consent is unprovable. Every
    # git query below fails CLOSED (reject) on a nonzero/error exit.
    git -C "$MAIN_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 1
    # State dir must not be a gitlink/submodule (mode 160000): a PR could embed the
    # marker inside a submodule so the parent index can't see it as tracked.
    stage=$(git -C "$MAIN_ROOT" ls-files --stage -- "$STATE_DIR" 2>/dev/null) || return 1
    grep -q '^160000 ' <<<"$stage" && return 1
    # Present in the index => repo-controlled. `ls-files` prints the path iff
    # tracked, exits 0 either way, nonzero only on a fatal error (=> fail-CLOSED
    # via `|| return 1`).
    tracked=$(git -C "$MAIN_ROOT" ls-files -- "$rel" 2>/dev/null) || return 1
    [[ -n "$tracked" ]] && return 1
    return 0
}
if _per_repo_optin; then
    echo 1
    exit 0
fi

echo 0
exit 0
