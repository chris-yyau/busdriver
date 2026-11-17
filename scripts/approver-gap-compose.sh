#!/usr/bin/env bash
# scripts/approver-gap-compose.sh — compose approver-gap-detect.sh's inputs from `gh api`
# and run it, for pr-grind's Completion "Approver-Gap Detection". Read-only: it queries
# GitHub and the main checkout's .claude/ opt-in files; it writes nothing and merges nothing.
#
# Usage: approver-gap-compose.sh <PR> <OWNER> <REPO> <WORKTREE_DIR> <ADMIN_FLAG_PASSED>
#   WORKTREE_DIR       the absolute Step 0 worktree (the checkout itself with NO_WORKTREE=1).
#   ADMIN_FLAG_PASSED  literal 0 or 1: whether --admin-on-approver-gap was passed. An
#                      argument, not an env fallback: bash exports do not survive across
#                      Claude Bash tool calls, so `${ADMIN_FLAG_PASSED:-0}` would always
#                      resolve to 0 and silently neutralize the flag.
# Prints approver-gap-detect.sh's JSON decision on stdout (a surface-decision JSON when the
# detector itself fails) and exits 0. Bad arguments exit 2 and an unreadable review list
# exits 1, both with nothing on stdout; the
# caller treats any non-zero exit or empty output as surface-decision, so a failure here
# can never authorize a merge.
#
# Why a script (#1078): this was a ~210-line inline fence. Its `case ... in ''|*[!0-9]*)`
# normalizers sit in a multi-line command with comments and `$(...)`, the shape in which
# marker_check's #776 case-pattern release deliberately stays off, so the helper guard
# refused the fence as "Cannot call lease_slot.py directly". As a script its body is not
# a typed command. The admin merge itself stays a typed command in completion.md, where
# the pre-merge gate sees it.
# No `set -u`: the inline block this was moved from ran without it, and its body (plus the
# libraries it sources) is unchanged.

if [ "$#" -ne 5 ]; then
  echo "usage: approver-gap-compose.sh <PR> <OWNER> <REPO> <WORKTREE_DIR> <ADMIN_FLAG_PASSED>" >&2
  exit 2
fi
PR="$1"
OWNER="$2"
REPO="$3"
WORKTREE_DIR="$4"
ADMIN_FLAG_PASSED="$5"
case "$PR" in ''|*[!0-9]*) echo "approver-gap-compose: PR must be a number: '$PR'" >&2; exit 2 ;; esac
[ -n "$OWNER" ] && [ -n "$REPO" ] || { echo "approver-gap-compose: OWNER and REPO must be non-empty" >&2; exit 2; }
case "$WORKTREE_DIR" in /*) ;; *) echo "approver-gap-compose: WORKTREE_DIR must be absolute: '$WORKTREE_DIR'" >&2; exit 2 ;; esac
case "$ADMIN_FLAG_PASSED" in 0|1) ;; *) echo "approver-gap-compose: ADMIN_FLAG_PASSED must be 0 or 1: '$ADMIN_FLAG_PASSED'" >&2; exit 2 ;; esac
# The plugin this script ships in, so the detector it runs is the same version.
CLAUDE_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2  # before any cd: BASH_SOURCE may be relative
# Mirror $PR into $PR_NUMBER as a shell variable so the OPTIN_SNAPSHOT path
# below can use `${PR_NUMBER}` consistently with Step 0's writer template.
# Without this, `${PR_NUMBER}` expands to empty in this fresh shell (each
# Bash tool call has fresh shell state) and the detector looks for
# `.pr-grind-solo-opt-in-snapshot-.local`, silently disabling solo-admin
# auto-detect even when Step 0 wrote the correct per-PR snapshot.
PR_NUMBER="$PR"
# WORKTREE_DIR (argument 4) is the Step 0 worktree. Required here because the solo-admin opt-in resolution below
# uses `git -C "$WORKTREE_DIR"` to derive MAIN_REPO_ROOT_FOR_OPTIN — a plain
# `git rev-parse` is CWD-sensitive, and CWD does not reliably persist across
# Claude Bash tool calls (see EXTREMELY-IMPORTANT block near top). If CWD has
# drifted to another repo checkout when Completion runs, a bare `git rev-parse`
# could read another repo's opt-in/snapshot for the same PR number, enabling
# unintended auto-merge or silently missing the target repo's valid opt-in.

# -R pins both lookups to $OWNER/$REPO, so neither the CWD nor the Step 0 worktree still
# being on disk decides the repository (a composer failure reads as surface-decision).
BRANCH=$(gh -R "$OWNER/$REPO" pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null || echo "")
AUTHOR=$(gh -R "$OWNER/$REPO" pr view "$PR" --json author -q .author.login 2>/dev/null || echo "")

# Compose the input JSON blobs / status flags the detection script consumes
# (see scripts/approver-gap-detect.sh header for the contract). Empty/missing
# inputs degrade the decision toward "surface-decision" or "no-gap"; the
# script NEVER auto-escalates without complete inputs.
BRANCH_RULES_JSON=""
CLASSIC_PROTECTION_JSON=""
if [ -n "$BRANCH" ]; then
  BRANCH_ENCODED=$(printf '%s' "$BRANCH" | jq -sRr @uri)
  BRANCH_RULES_JSON=$(gh api "repos/$OWNER/$REPO/rules/branches/$BRANCH_ENCODED" 2>/dev/null || echo "")
  # Classic branch protection — the detector reads the required-review count from
  # BOTH rulesets AND classic protection (max), because a repo can enforce the
  # approver requirement via either mechanism. MUST be the PARENT endpoint
  # /branches/<b>/protection: its .required_pull_request_reviews is ground truth,
  # whereas the /required_pull_request_reviews SUB-endpoint phantom-reports
  # count=1 even when unenforced (would manufacture a false approver gap).
  CLASSIC_PROTECTION_JSON=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH_ENCODED/protection" 2>/dev/null || echo "")
fi
# --paginate: reviews come oldest-first, 30 per page, so a busy PR's APPROVED
# review can sit past page 1. A failure on any page exits 1 (the caller then
# surfaces the decision): the detector reads missing reviews as zero approvals,
# which could authorize an admin bypass the PR does not need. Each review is cut
# to the fields the detector reads, so a long history stays under the
# per-string exec limit when it is exported below.
PR_REVIEWS_TMP=$(mktemp -t pr-grind-reviews.XXXXXXXX) || exit 1
if ! gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate >"$PR_REVIEWS_TMP" 2>/dev/null \
   || ! PR_REVIEWS_JSON=$(jq -sc '[.[][] | {user: {login: .user.login, type: .user.type}, state, submitted_at}]' "$PR_REVIEWS_TMP" 2>/dev/null); then
  rm -f "$PR_REVIEWS_TMP"
  echo "approver-gap-compose: could not read every page of PR reviews" >&2
  exit 1
fi
rm -f "$PR_REVIEWS_TMP"
AUTHOR_PERM_JSON=""
if [ -n "$AUTHOR" ]; then
  AUTHOR_PERM_JSON=$(gh api "repos/$OWNER/$REPO/collaborators/$AUTHOR/permission" 2>/dev/null || echo "")
fi
AUDIT_WORKFLOW_PRESENT=0
if gh api "repos/$OWNER/$REPO/contents/.github/workflows/bypass-audit.yml" >/dev/null 2>&1; then
  AUDIT_WORKFLOW_PRESENT=1
fi
# Caller asserts CI/bots clean: the Completion path runs this script only
# after the `gh pr checks` verification + `scripts/ack-ledger.sh` re-query
# both pass. If either fails earlier, the script is not invoked at all.
CI_AND_BOTS_CLEAN=1

# Solo-admin auto-detect (per-repo opt-in). The .local file is the operator's
# durable consent for this repo — when present AND the structural sole-admin
# check still holds, the detector treats it as equivalent to passing
# --admin-on-approver-gap, but logs with a distinct event for forensics. The
# count is computed via gh api so the script can verify the assumption is
# STILL TRUE at merge time (a contractor added since the opt-in invalidates
# it). Fail-CLOSED: any gh failure leaves HUMAN_ADMIN_COUNT=0, which the
# script treats as "unknown" and refuses to auto-escalate.
#
# Anti-self-bypass: opt-in fires ONLY when the Step 0 snapshot file
# `.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local` exists AND its
# recorded mtime matches the opt-in file's current mtime. Step 0 writes
# the snapshot only when the opt-in file was already ≥30s old at pr-grind
# invocation start (NOT at Completion time — a slow pr-grind run can
# easily exceed 30s, so checking at Completion would defeat the freshness
# gate). A mid-run touch/replace produces a snapshot/current-mtime
# mismatch → opt-in invalidated. The snapshot path is per-PR so concurrent
# pr-grind runs on different PRs don't collide on shared state. Both the
# opt-in file and the snapshot live in the MAIN repo's .claude/ (not the
# ephemeral worktree's). See Step 0's snapshot writer for the producer side.
# Resolve MAIN_REPO_ROOT via `git -C "$WORKTREE_DIR"` (NOT bare `git rev-parse`)
# to anchor against the dispatcher's known worktree path rather than current
# CWD. CWD drift between Bash tool calls would otherwise let this block read
# another repo's opt-in/snapshot for the same PR number. WORKTREE_DIR
# correctly resolves to the main-repo .git/ via --git-common-dir in both
# worktree mode (linked worktree → shared .git/) and --no-worktree mode
# (WORKTREE_DIR == main repo, --git-common-dir → .git/).
#
# Two-step resolve so a failed `git -C` doesn't pass `dirname ""` ⇒ "."
# silently through the non-empty check below and reintroduce the wrong-repo
# read this whole resolver exists to prevent. Require an absolute path
# (leading slash) before accepting MAIN_REPO_ROOT_FOR_OPTIN.
MAIN_REPO_ROOT_FOR_OPTIN=""
if [ -n "$WORKTREE_DIR" ]; then
  GIT_COMMON_DIR=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$GIT_COMMON_DIR" ]; then
    CANDIDATE=$(dirname "$GIT_COMMON_DIR")
    case "$CANDIDATE" in
      /*) MAIN_REPO_ROOT_FOR_OPTIN="$CANDIDATE" ;;
      *)  : ;;   # reject anything not absolute (defends against dirname returning ".")
    esac
  fi
fi
SOLO_ADMIN_OPT_IN=0
if [ -n "$MAIN_REPO_ROOT_FOR_OPTIN" ]; then
  OPTIN_FILE="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/pr-grind-auto-admin-solo.local"
  # Per-PR snapshot path — must match Step 0's snapshot writer exactly.
  # Step 0 uses ${PR_NUMBER} as the template placeholder; use the same name
  # here so a future change that treats these as actual shell variables rather
  # than dispatcher-substituted literals cannot silently diverge the two paths.
  OPTIN_SNAPSHOT="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local"
  if [ -f "$OPTIN_FILE" ] && [ -f "$OPTIN_SNAPSHOT" ]; then
    CURRENT_MTIME=$(stat -c %Y "$OPTIN_FILE" 2>/dev/null || stat -f %m "$OPTIN_FILE" 2>/dev/null || echo 0)
    SNAPSHOT_MTIME=$(head -n1 "$OPTIN_SNAPSHOT" 2>/dev/null | tr -dc '0-9')
    # Snapshot FILE mtime (filesystem) — must be ≥30s AFTER opt-in mtime.
    # Defends against the naive forge where an autonomous run creates both
    # files with the same fresh mtime: opt-in.mtime == snapshot-content,
    # which would otherwise pass the content-match check below. By
    # requiring `snapshot.fs_mtime - opt-in.mtime >= 30`, a same-NOW forge
    # has diff=0 and fails. Step 0's legitimate write produces
    # diff >= 30 (Step 0 only snapshots opt-in files already ≥30s old,
    # and the snapshot is written ~now relative to the opt-in mtime).
    # NOTE: `touch -t` backdating of the opt-in file by a sophisticated
    # attacker still bypasses this — defeating that requires file
    # birth-time (btime) checks which aren't portable across macOS/Linux.
    # The threat model already assumes attacker has same-user write access
    # in which case `gh pr merge --admin` is directly accessible too;
    # this is defense-in-depth, not a security boundary.
    SNAPSHOT_FILE_MTIME=$(stat -c %Y "$OPTIN_SNAPSHOT" 2>/dev/null || stat -f %m "$OPTIN_SNAPSHOT" 2>/dev/null || echo 0)
    case "$CURRENT_MTIME" in ''|*[!0-9]*) CURRENT_MTIME=0 ;; esac
    case "$SNAPSHOT_MTIME" in '') SNAPSHOT_MTIME=0 ;; esac
    case "$SNAPSHOT_FILE_MTIME" in ''|*[!0-9]*) SNAPSHOT_FILE_MTIME=0 ;; esac
    SNAPSHOT_VS_OPTIN_DIFF=$((SNAPSHOT_FILE_MTIME - CURRENT_MTIME))
    if [ "$SNAPSHOT_MTIME" -gt 0 ] \
       && [ "$CURRENT_MTIME" = "$SNAPSHOT_MTIME" ] \
       && [ "$SNAPSHOT_VS_OPTIN_DIFF" -ge 30 ]; then
      SOLO_ADMIN_OPT_IN=1
    fi
  fi
fi
HUMAN_ADMIN_COUNT=0
AUTHOR_IS_SOLE_ADMIN=0
if [ "$SOLO_ADMIN_OPT_IN" = "1" ]; then
  # Only spend the API call(s) when the opt-in file exists — no point
  # paginating collaborators on every pr-grind run.
  #
  # Count humans with PR-APPROVAL capability, not just admins. Anyone with
  # write/maintain/admin permission (i.e., `permissions.push == true`) can
  # submit an APPROVED review under default branch protection. Filtering
  # only `permission=admin` would let the solo-admin trigger fire even when
  # another human collaborator with maintain/write could approve, which
  # contradicts the "no other human can approve" promise. Query all
  # collaborators (no permission filter) and select those whose
  # `permissions.push` is true.
  #
  # Variable kept as HUMAN_ADMIN_COUNT for backward-compat with
  # approver-gap-detect.sh's input contract; the semantic is now "count of
  # humans with PR-approval capability". The script doc + log field
  # `human_admin_count` carries the same semantic.
  # `gh api --paginate` emits one JSON array per page (e.g.
  # `[page1]\n[page2]`), NOT a single merged array. Need to slurp all
  # pages and concatenate into one array; without this, downstream
  # `jq '.[]'` consumers below would only iterate the first page on
  # repos with >30 collaborators and the numeric guard would normalize
  # the resulting multi-line "0\n1" to 0.
  #
  # Capture to a tmpfile + check gh's exit code BEFORE jq. A naive
  # `gh ... | jq -s 'add // []'` pipeline without pipefail (which we
  # cannot enable globally inside a larger SKILL.md template) would let
  # jq succeed over PARTIAL pages when gh fails on a later page (rate
  # limit, transient network) — yielding an incomplete collaborator list
  # that could miss a write-capable human on an unfetched page and
  # wrongly satisfy HUMAN_ADMIN_COUNT=1. Fail-CLOSED on any gh failure.
  COLLABORATORS_TMP=$(mktemp -t pr-grind-collab.XXXXXXXX)
  if gh api "repos/$OWNER/$REPO/collaborators?affiliation=all" --paginate >"$COLLABORATORS_TMP" 2>/dev/null; then
    COLLABORATORS_JSON=$(jq -s 'add // []' "$COLLABORATORS_TMP" 2>/dev/null || echo "[]")
  else
    COLLABORATORS_JSON="[]"
  fi
  rm -f "$COLLABORATORS_TMP"
  # Parse count and first login in a single jq pass — avoids filtering
  # COLLABORATORS_JSON twice with identical predicates, eliminating a second
  # jq-failure window that could leave SOLE_APPROVER_LOGIN empty and
  # silently prevent auto-merge even when the structural check should pass.
  APPROVERS_RESULT=$(printf '%s' "$COLLABORATORS_JSON" \
    | jq -r '[.[]
        | select((.type // "User") == "User"
                 and ((.login // "") | endswith("[bot]") | not)
                 and ((.permissions.push // false) == true))
        | .login]
      | { count: length, first: (.[0] // "") }
      | "\(.count) \(.first)"' 2>/dev/null || echo "0 ")
  HUMAN_ADMIN_COUNT="${APPROVERS_RESULT%% *}"
  SOLE_APPROVER_LOGIN="${APPROVERS_RESULT#* }"
  case "$HUMAN_ADMIN_COUNT" in ''|*[!0-9]*) HUMAN_ADMIN_COUNT=0 ;; esac
  if [ "$HUMAN_ADMIN_COUNT" = "1" ] && [ -n "$AUTHOR" ]; then
    if [ "$SOLE_APPROVER_LOGIN" = "$AUTHOR" ]; then
      AUTHOR_IS_SOLE_ADMIN=1
    fi
  fi
fi

export BRANCH_RULES_JSON CLASSIC_PROTECTION_JSON PR_REVIEWS_JSON AUTHOR_PERM_JSON \
       AUDIT_WORKFLOW_PRESENT CI_AND_BOTS_CLEAN ADMIN_FLAG_PASSED \
       SOLO_ADMIN_OPT_IN HUMAN_ADMIN_COUNT AUTHOR_IS_SOLE_ADMIN

GAP_DECISION_JSON=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-detect.sh" 2>/dev/null \
  || echo '{"decision":"surface-decision","trigger":"none","reason":"approver-gap detector failed; require operator decision"}')
printf '%s\n' "$GAP_DECISION_JSON"
