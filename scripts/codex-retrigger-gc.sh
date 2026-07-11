#!/usr/bin/env bash
# scripts/codex-retrigger-gc.sh — prune a merged PR's codex-retrigger idempotency
# markers (issue #327).
#
# WHY: codex-retrigger.sh writes a one-shot marker per (PR, HEAD) and NEVER
# deletes it — per-HEAD granularity × zero GC = unbounded accumulation of tiny
# gitignored `.local` files. Once a PR merges, ALL of its per-HEAD markers are
# dead. pr-grind's COMPLETION calls this after a confirmed merge to prune them.
#
# STATE-DIR RESOLUTION — a TRUE mirror of codex-retrigger.sh:69, which writes
# `${BUSDRIVER_STATE_DIR:-.claude}/...` **relative to its invocation CWD**. Both
# codex-retrigger and this GC are invoked inside `( cd "$WORKTREE_DIR"; ... )`, so
# resolving the state dir the identical CWD-relative way targets the exact dir the
# markers live in — in --no-worktree mode that is the repo root, in worktree mode
# the ephemeral worktree, and for an absolute BUSDRIVER_STATE_DIR that path
# verbatim. This deletes the markers regardless of whether the worktree is later
# removed, so it also covers the auto-admin merge path (which removes no worktree).
#
# CONTRACT — best-effort, ALWAYS exit 0: a failed prune must never affect merge
# success. Bad/empty PR → clean no-op.
#   Usage:  codex-retrigger-gc.sh <pr-number>
set -u

PR="${1:-}"

# Digit-validate PR (argument-injection guard, consistent with codex-retrigger.sh:62).
case "$PR" in
    '' | *[!0-9]*)
        echo "ℹ️  codex-retrigger-gc: non-numeric PR '$PR'; nothing to prune." >&2
        exit 0 ;;
esac

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

# DESTRUCTIVE-op containment (#325 / ADR 0016 gate-env surface): resolve the state dir
# to an absolute path anchored at CWD, then REFUSE any target outside this worktree. The
# caller always `cd`s into $WORKTREE_DIR first and codex-retrigger.sh writes CWD-relative
# (default `.claude` under the worktree), so a legit prune always passes; this blocks a
# committable settings.json from redirecting BUSDRIVER_STATE_DIR to another repo's dir and
# having the GC delete ITS Codex markers (which would re-enable a duplicate retrigger).
_CWD="$(pwd -P)"
# Canonicalize the state dir to its PHYSICAL path (cd + pwd -P resolves symlinks such as
# macOS /var→/private/var, so the containment prefix check is exact). A non-existent
# state dir simply has no markers to prune.
if ! STATE_DIR="$(cd "$STATE_DIR" 2>/dev/null && pwd -P)"; then
    exit 0
fi
case "$STATE_DIR/" in
    "$_CWD"/*) : ;;
    *)
        echo "ℹ️  codex-retrigger-gc: state dir '$STATE_DIR' is outside the worktree ('$_CWD'); skipping prune." >&2
        exit 0 ;;
esac

# Pure-bash prune (no `find`, so no GNU-vs-BSD `-maxdepth`/`-delete` portability
# question). `nullglob` makes a zero-match glob expand to nothing (no literal-pattern
# rm), the glob is depth-1 by construction (no recursion), and the trailing `-` after
# ${PR} keeps pr1 from matching pr10. Best-effort; a failed prune never blocks merge.
shopt -s nullglob
for _marker in "$STATE_DIR"/.pr-grind-codex-retriggered-pr"${PR}"-*.local; do
    if [ -f "$_marker" ]; then rm -f "$_marker" 2>/dev/null || true; fi
done
shopt -u nullglob

exit 0
