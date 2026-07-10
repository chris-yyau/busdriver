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

# FAIL-CLOSED: unresolvable root => cannot confirm a per-repo opt-in => not opted
# in (never a bare "." fallback, which could read an unrelated dir's file).
if [[ -n "$MAIN_ROOT" && -f "${MAIN_ROOT%/}/${STATE_DIR}/${FILE}" ]]; then
    echo 1
    exit 0
fi

echo 0
exit 0
