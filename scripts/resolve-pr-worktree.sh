#!/usr/bin/env bash
# scripts/resolve-pr-worktree.sh — resolve the working directory pr-grind will
# run in, fail-CLOSED on any branch mismatch (issue #421).
#
# WHY: Step 0 used to infer "the branch is already checked out HERE" from the
# failure of `git worktree add`. That error actually means "checked out
# SOMEWHERE". When the PR branch was held by a *different* worktree, the old
# fallback set WORKTREE_DIR to the repo root — whatever branch that happened to
# be on, typically `main`. Every downstream step honors the CWD contract, so the
# grind read `main`'s HEAD for the ack ledger, anchored Tier-F freshness to the
# wrong commit, and pushed fix commits straight onto `main`, bypassing the PR.
# Silent and fail-OPEN: nothing compared the resolved dir's branch to the PR head.
#
# CONTRACT — stdout is a machine-read wire format, one `KEY=value` per line, and
# the dispatcher scans for these exact strings (shell vars don't survive across
# Claude tool calls, so stdout IS the cross-block source of truth):
#
#   pr-grind-mode: no-worktree   (in-place fallback only — dispatcher MUST then
#                                 propagate NO_WORKTREE=1 to every later block)
#   WORKTREE_DIR=<abs path>      (always, on success)
#
#   Usage:  resolve-pr-worktree.sh <pr-number> <pr-branch> <pr-head-sha>
#   exit 0 = resolved, WORKTREE_DIR is on <pr-branch> AT <pr-head-sha>
#   exit 1 = BAIL (diagnostic on stderr; caller must NOT proceed)
#
# The assertion at the end runs unconditionally, in BOTH worktree and in-place
# modes. It is the load-bearing guard: it catches this bug class even if the
# three-way split above ever grows a fourth case.
#
# It checks the branch name AND the head SHA. Name alone is not sufficient — a
# stale or wholly unrelated LOCAL branch that merely shares the PR head's name
# would satisfy it, which is routine for fork PRs and for a local branch that
# never fetched the PR's latest push. Comparing SHAs is what makes "this is the
# revision the PR is actually at" true rather than merely plausible.

set -uo pipefail

PR_NUMBER="${1:-}"
PR_BRANCH="${2:-}"
PR_HEAD_SHA="${3:-}"

if [ -z "$PR_NUMBER" ] || [ -z "$PR_BRANCH" ] || [ -z "$PR_HEAD_SHA" ]; then
  echo "❌ usage: resolve-pr-worktree.sh <pr-number> <pr-branch> <pr-head-sha>" >&2
  exit 1
fi

# PR_NUMBER is interpolated into WORKTREE_DIR, and the assertion's cleanup path
# runs `git worktree remove --force` against that directory. A value containing
# `/` or `..` would redirect both outside the intended sibling location, so the
# destructive call must never see a non-numeric one. Digits only, fail-CLOSED.
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "❌ pr-number must be digits only, got '$(printf '%s' "$PR_NUMBER" | tr -cd '[:print:]')'." >&2
    exit 1
    ;;
esac

# Likewise the head SHA: it is only ever compared, never interpolated into a
# path, but constraining it to hex keeps the comparison meaningful.
case "$PR_HEAD_SHA" in
  *[!0-9a-fA-F]*)
    echo "❌ pr-head-sha must be hexadecimal." >&2
    exit 1
    ;;
esac

# `tr -cd '[:print:]\n\t'` strips every non-printable byte — kills CSI, OSC, and
# any other terminal-control sequence in one pass. Used instead of sed because
# BSD sed (macOS default) does not support the `\x1B` hex escape. Applied to
# anything that came from git or from the GitHub-API-supplied branch name.
sanitize() { printf '%s' "$1" | tr -cd '[:print:]\n\t'; }
SAFE_BRANCH=$(sanitize "$PR_BRANCH")

# Normalize a path for comparison. Returns empty on an unresolvable path, which
# the callers below treat as "cannot prove equal" → BAIL.
canon() { (cd "$1" 2>/dev/null && pwd -P) || true; }

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
  echo "❌ git rev-parse --show-toplevel failed — not in a git repo, or the repo root is unresolvable." >&2
  exit 1
fi
REPO_ROOT=$(canon "$REPO_ROOT")

# Anchor the ephemeral worktree beside the REPO ROOT, not beside $PWD. The old
# `cd .. && pwd -P` was CWD-relative and only coincided with this when pr-grind
# was invoked from the repo root.
WORKTREE_DIR="$(dirname "$REPO_ROOT")/pr-grind-${PR_NUMBER}"

WT_OUT=$(LANG=C LC_ALL=C git worktree add "$WORKTREE_DIR" "$PR_BRANCH" 2>&1)
WT_EXIT=$?

if [ "$WT_EXIT" -eq 0 ]; then
  MODE="worktree"
elif printf '%s' "$WT_OUT" | grep -qE "already (used by worktree|checked out) at"; then
  # git names the holder, in one of two phrasings depending on version:
  #   fatal: '<branch>' is already used by worktree at '<path>'   (newer)
  #   fatal: '<branch>' is already checked out at '<path>'        (older)
  # Matching only the newer form sent a perfectly ordinary in-place case down
  # the unclassified-fatal branch on older git.
  # `sed -nE`, not BRE: BSD sed (the macOS default) does not support `\|`
  # alternation in a basic regex — it matches nothing and every in-place case
  # degrades into an "<unparseable> holder" bail.
  HOLDER=$(printf '%s' "$WT_OUT" \
    | sed -nE "s/.*already (used by worktree|checked out) at '(.*)'.*/\2/p" \
    | head -1)
  HOLDER_CANON=$(canon "$HOLDER")

  if [ -n "$HOLDER_CANON" ] && [ "$HOLDER_CANON" = "$REPO_ROOT" ]; then
    # Case 1: the branch is checked out in THIS repo — the genuine in-place case,
    # and the common one when grinding the branch you just pushed.
    echo "ℹ️  Branch $SAFE_BRANCH is already checked out here — falling back to in-place mode (--no-worktree)."
    echo "pr-grind-mode: no-worktree"
    WORKTREE_DIR="$REPO_ROOT"
    MODE="in-place"
  else
    # Case 2: held by a DIFFERENT worktree. Never fall back to the repo root —
    # that is the #421 bug. An unusable worktree is the failure case, not the
    # happy path; BAIL and name the holder so the operator can free it.
    echo "❌ Branch $SAFE_BRANCH is checked out in another worktree: $(sanitize "${HOLDER:-<unparseable>}")" >&2
    echo "   Refusing to fall back to the repo root ($REPO_ROOT) — that would grind the wrong branch (#421)." >&2
    echo "   Free the branch (\`git worktree remove\`, or unlock it) and re-run, or run pr-grind from that worktree." >&2
    exit 1
  fi
else
  echo "❌ git worktree add failed: $(sanitize "$WT_OUT")" >&2
  exit 1
fi

# Load-bearing assertion — unconditional, both modes. Cleans up a worktree it
# created before bailing; in-place mode owns no dir to clean.
bail_assert() {
  echo "❌ $1" >&2
  echo "   Dir: $WORKTREE_DIR (mode: $MODE). Refusing to grind the wrong revision (#421)." >&2
  [ "$MODE" = "worktree" ] && git worktree remove "$WORKTREE_DIR" --force 2>/dev/null
  exit 1
}

# Branch name. A detached HEAD yields "HEAD", which is not a branch, so it fails
# closed here too.
WT_BRANCH=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || WT_BRANCH=""
if [ "$WT_BRANCH" != "$PR_BRANCH" ]; then
  bail_assert "Resolved WORKTREE_DIR is on '$(sanitize "${WT_BRANCH:-<unresolvable>}")' but PR #${PR_NUMBER} head is '$SAFE_BRANCH'."
fi

# Head SHA. The name matching is not enough on its own — a stale or unrelated
# local branch of the same name (routine for fork PRs, or a branch that never
# fetched the PR's latest push) would otherwise sail through and the grind would
# read, commit, and push against the wrong revision.
WT_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null) || WT_SHA=""
if [ "$WT_SHA" != "$PR_HEAD_SHA" ]; then
  bail_assert "Local '$SAFE_BRANCH' is at $(sanitize "${WT_SHA:-<unresolvable>}") but PR #${PR_NUMBER} head is $(sanitize "$PR_HEAD_SHA") — fetch or push so they agree."
fi

echo "WORKTREE_DIR=$WORKTREE_DIR"
