#!/usr/bin/env bash
# scripts/approver-gap-admin.sh — the two halves of pr-grind's approver-gap auto-admin merge
# (skills/pr-grind/references/completion.md, decision `auto-admin-merge`). The merge itself
# is NOT here: `gh pr merge --admin` stays a typed command between the two calls, where the
# pre-merge gate sees it.
#
# Usage:
#   approver-gap-admin.sh authorize <PR> <OWNER> <REPO> <WORKTREE_DIR> <ADMIN_FLAG_PASSED>
#     Re-runs scripts/approver-gap-compose.sh in this process, verifies the decision is
#     `auto-admin-merge` with trigger `flag` or `solo-admin-auto`, and appends the
#     bypass-log entry. Exit 0 only then; any other outcome exits 1 BEFORE the merge, and
#     the caller must not merge.
#   approver-gap-admin.sh settle <PR> <WORKTREE_DIR>
#     After the merge attempt: confirms MERGED via `gh pr view` (3 tries), removes the
#     clean marker if it did not land (exit 1), drains the spent marker and GCs the
#     codex-retrigger markers if it did (exit 0).
# Bad arguments exit 2.
#
# Why a script (#1078): inline, this block's `case ... in ''|*[!0-9]*)` validators sat in a
# multi-line command with comments and `$(...)`, the shape in which marker_check's #776
# case-pattern release deliberately stays off, so the helper guard refused the block. The
# decision used to cross from the detection fence to this one through shell scope (the
# "same-call-scope contract"); `authorize` now computes it itself, so no Bash-call split
# can hand the merge a stale or empty decision.
# No `set -u`: the inline block this was moved from ran without it, and its body (plus the
# libraries it sources) is unchanged.

usage() {
  echo "usage: approver-gap-admin.sh authorize <PR> <OWNER> <REPO> <WORKTREE_DIR> <ADMIN_FLAG_PASSED>" >&2
  echo "       approver-gap-admin.sh settle <PR> <WORKTREE_DIR>" >&2
  exit 2
}
MODE="${1:-}"
case "$MODE" in
  authorize) [ "$#" -eq 6 ] || usage; PR="$2"; OWNER="$3"; REPO="$4"; WORKTREE_DIR="$5"; ADMIN_FLAG_PASSED="$6" ;;
  settle)    [ "$#" -eq 3 ] || usage; PR="$2"; WORKTREE_DIR="$3" ;;
  *) usage ;;
esac
case "$PR" in ''|*[!0-9]*) echo "approver-gap-admin: PR must be a number: '$PR'" >&2; exit 2 ;; esac
case "$WORKTREE_DIR" in /*) ;; *) echo "approver-gap-admin: WORKTREE_DIR must be absolute: '$WORKTREE_DIR'" >&2; exit 2 ;; esac
CLAUDE_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2  # before any cd: BASH_SOURCE may be relative
# No cd: like the inline block this replaces, both modes run at the CALLER's cwd, the
# session checkout. `settle` must: the clean marker and the pre-merge gate are anchored
# there (completion.md, "Write the pr-grind-clean marker"), so its invalidate/drain have to
# resolve the same root. WORKTREE_DIR is used only where the worktree is meant: the
# composer, the audit entry's HEAD and main-repo root, and the codex-retrigger GC.
[ -d "$WORKTREE_DIR" ] || { echo "approver-gap-admin: no such worktree: '$WORKTREE_DIR'" >&2; exit 2; }

if [ "$MODE" = authorize ]; then
# The decision, computed here rather than carried in from another Bash call. An empty
# result fails the authorization gate below.
GAP_DECISION_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-compose.sh" "$PR" "$OWNER" "$REPO" "$WORKTREE_DIR" "$ADMIN_FLAG_PASSED") || GAP_DECISION_JSON=""
# The typed merge that follows runs in THIS cwd (the session checkout -- see the No-cd note
# above), and gh resolves its repository from it. Refuse unless that is the repository this
# decision was made for: otherwise a drifted cwd would merge another repository's
# same-numbered PR under this authorization. Same resolution gh pr merge uses.
AMBIENT_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || AMBIENT_REPO=""
if [ "$(printf '%s' "$AMBIENT_REPO" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$OWNER/$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "❌ approver-gap auto-admin: this call's cwd resolves to '${AMBIENT_REPO:-<none>}', not '$OWNER/$REPO' — run it from the session checkout; aborting before bypass-log + merge"; exit 1
fi
# BRANCH / AUTHOR for the audit entry: derived here (via `gh -R "$OWNER/$REPO"`, never
# CWD-based repo inference), never inherited -- an exported value is not evidence. The
# audit trail is load-bearing, so an unresolved field refuses the merge rather than
# logging it empty.
BRANCH=$(gh -R "$OWNER/$REPO" pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null) || BRANCH=""
AUTHOR=$(gh -R "$OWNER/$REPO" pr view "$PR" --json author -q .author.login 2>/dev/null) || AUTHOR=""
if [ -z "$BRANCH" ] || [ -z "$AUTHOR" ]; then
  echo "❌ approver-gap auto-admin: could not resolve the PR's base branch and author for the bypass log — aborting before bypass-log + merge"; exit 1
fi
# The audit log lives in the MAIN repo's .claude/, as every other bypass-log writer and
# reader resolves it: --git-common-dir's parent is the main root in worktree and
# --no-worktree mode alike. A linked worktree's own .claude/ is deleted with it.
_GCD=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _GCD=""
case "$_GCD" in
  /*) REPO_ROOT=$(dirname "$_GCD") ;;
  *) echo "❌ approver-gap auto-admin: cannot resolve the main repo root from '$WORKTREE_DIR' — aborting before bypass-log + merge"; exit 1 ;;
esac
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The PR head the worktree holds, not the session checkout's (routinely another branch).
HEAD_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD | cut -c1-8)

# Fail-CLOSED authorization gate. $GAP_DECISION_JSON must be in scope from
# the parent approver-gap detection call AND contain a valid auto-admin-merge
# decision with a known trigger. Empty / malformed / wrong-decision / unknown-
# trigger inputs ABORT before the merge — the bypass-log entry and `gh pr
# merge --admin` only run on a verified authorization.
if [ -z "${GAP_DECISION_JSON:-}" ]; then
  echo "❌ approver-gap auto-admin: GAP_DECISION_JSON empty (the composer produced no decision) — aborting before bypass-log + merge"; exit 1
fi
GAP_DECISION_FOR_MERGE=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.decision // "missing"' 2>/dev/null || echo "parse-error")
GAP_TRIGGER_FOR_MERGE=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.trigger // "missing"' 2>/dev/null || echo "parse-error")
if [ "$GAP_DECISION_FOR_MERGE" != "auto-admin-merge" ]; then
  echo "❌ approver-gap auto-admin: detector decision is '$GAP_DECISION_FOR_MERGE', not 'auto-admin-merge' — aborting before bypass-log + merge"; exit 1
fi
case "$GAP_TRIGGER_FOR_MERGE" in
  flag|solo-admin-auto) ;;
  *) echo "❌ approver-gap auto-admin: detector trigger is '$GAP_TRIGGER_FOR_MERGE', not 'flag' or 'solo-admin-auto' — aborting before bypass-log + merge"; exit 1 ;;
esac

# After the authorization gate, the remaining jq reads are pulling forensic
# metadata from a known-valid JSON object — defaults via `// X` are
# appropriate here (those fields may legitimately be missing if the detector
# is upgraded incrementally; the merge is already authorized).
AUTHOR_PERM=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.author_perm // "read"' 2>/dev/null || echo "read")
REQUIRED_APPROVALS=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.required_approving_review_count // 0' 2>/dev/null || echo 0)
case "$REQUIRED_APPROVALS" in ''|*[!0-9]*) REQUIRED_APPROVALS=0 ;; esac
HUMAN_APPROVALS=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.human_approvals // 0' 2>/dev/null || echo 0)
case "$HUMAN_APPROVALS" in ''|*[!0-9]*) HUMAN_APPROVALS=0 ;; esac
# Trigger-derived fields: forensics depends on knowing WHY the bypass fired.
# `event` distinguishes explicit-flag from structural sole-admin in audits;
# human_admin_count records the structural assumption at decision time so a
# later audit can detect if the repo's admin roster changed post-merge.
# LOG_TRIGGER is the already-validated value from the authorization gate.
LOG_TRIGGER="$GAP_TRIGGER_FOR_MERGE"
LOG_HUMAN_ADMIN_COUNT=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.human_admin_count // 0' 2>/dev/null || echo 0)
case "$LOG_HUMAN_ADMIN_COUNT" in ''|*[!0-9]*) LOG_HUMAN_ADMIN_COUNT=0 ;; esac
case "$LOG_TRIGGER" in
  solo-admin-auto) LOG_EVENT="pr-grind-admin-on-approver-gap-solo-admin-auto" ;;
  flag)            LOG_EVENT="pr-grind-admin-on-approver-gap" ;;
  *)               LOG_EVENT="pr-grind-admin-on-approver-gap" ;;
esac
# Validate $PR is numeric before passing to --argjson — defense in depth so a
# `gh pr view` failure upstream (returning empty string or "null") can't cause
# jq to abort the log composition with "Invalid numeric literal". The audit
# trail is load-bearing; silently dropping the entry defeats the
# audit_workflow_present eligibility gate.
case "$PR" in
  ''|*[!0-9]*)
    echo "❌ approver-gap admin escalation: invalid PR number '$PR' — aborting before bypass-log + merge"; exit 1 ;;
esac
mkdir -p "$REPO_ROOT/.claude"
jq -c -n \
  --arg ts "$TS" \
  --arg event "$LOG_EVENT" \
  --arg trigger "$LOG_TRIGGER" \
  --argjson pr "$PR" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg author "$AUTHOR" \
  --arg author_perm "$AUTHOR_PERM" \
  --argjson required "$REQUIRED_APPROVALS" \
  --argjson approvals "$HUMAN_APPROVALS" \
  --argjson human_admin_count "$LOG_HUMAN_ADMIN_COUNT" \
  --arg head_sha "$HEAD_SHA" \
  '{ts:$ts, event:$event, trigger:$trigger, pr:$pr, owner:$owner, repo:$repo, branch:$branch, author:$author, author_perm:$author_perm, required_approving_review_count:$required, human_approvals:$approvals, human_admin_count:$human_admin_count, head_sha:$head_sha}' \
  >> "$REPO_ROOT/.claude/bypass-log.jsonl" || { echo "❌ failed to append bypass-log entry; aborting admin merge"; exit 1; }

echo "approver-gap auto-admin: authorized (trigger=$LOG_TRIGGER) and logged to bypass-log.jsonl; run the typed admin merge next."
exit 0
fi

# settle
# Verify via authoritative source — `gh pr merge --delete-branch` can
# exit non-zero on a post-merge local worktree-checkout conflict (e.g.,
# "main is already used by worktree at ...") even after the remote merge
# succeeded. Trust `gh pr view --json state` instead. See the
# default-merge block below for the full failure-mode walkthrough.
# Retry up to 3 times with 2s backoff. Two real failure modes the retry
# absorbs: (1) the worktree-checkout conflict above makes `gh pr merge`
# exit non-zero even though the remote merge succeeded — the next `gh pr
# view` may briefly still see state=OPEN; (2) transient post-merge
# replication lag in the GitHub API (queried via gh). The retry is idempotent (read-only poll).
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=$(gh pr view "$PR" --json state -q .state 2>/dev/null || echo "")
  [ "$MERGE_STATE" = "MERGED" ] && break
  [ "$attempt" -lt 3 ] && sleep 2
done
if [ "$MERGE_STATE" != "MERGED" ]; then
  echo "❌ approver-gap admin merge: PR #$PR not merged after 3 attempts (state=$MERGE_STATE); bypass-log entry was written but merge did not land."
  # Invalidate the clean marker (#427 P1 gap, PR #429 review). --match-head-commit
  # correctly rejected because HEAD moved after classification, but a stale
  # pr-grind-clean.local left on disk would let a subsequent PLAIN `gh pr merge`
  # (no head guard) sail through pre-merge-gate.sh, which only re-checks CI on a
  # fresh same-PR marker — silently merging the newly pushed, unclassified head.
  # Remove it so any retry is forced back through a full grind round.
  MARKER_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$MARKER_REPO_ROOT" ] && rm -f "$MARKER_REPO_ROOT/.claude/pr-grind-clean.local"
  exit 1
fi
# Consume the clean marker this merge spent (#842) — same drain as the default merge
# block, keyed on $PR.
MARKER_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
MARKER_PR=""
[ -n "$MARKER_REPO_ROOT" ] && read -r MARKER_PR _ 2>/dev/null <"$MARKER_REPO_ROOT/.claude/pr-grind-clean.local" || true
if [ "$MARKER_PR" = "$PR" ]; then
  ( cd "$MARKER_REPO_ROOT" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/design-clear.sh" --skip pr-grind-clean.local --yes >/dev/null ) \
    || echo "⚠️  could not drain the spent clean marker; run: design-clear.sh --skip pr-grind-clean.local"
fi
# GC the merged PR's codex-retrigger idempotency markers (#327). Runs from
# $WORKTREE_DIR — the CWD codex-retrigger wrote them relative to — so they are
# pruned even though this admin-merge path removes no worktree. Best-effort;
# a failed prune must never affect merge success.
( cd "$WORKTREE_DIR" || exit 0; bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "$PR" ) || true
