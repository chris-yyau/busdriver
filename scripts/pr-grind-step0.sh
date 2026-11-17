#!/usr/bin/env bash
# scripts/pr-grind-step0.sh — pr-grind's Step 0 (skills/pr-grind/SKILL.md, "Step 0: Create
# Ephemeral Worktree"): the base-branch guard, the one contained `gh pr view`, the fork
# refusal, the PR home-repository identity (#890), worktree resolution (#421), the
# grind-provenance base floor (ADR 0036) and the solo-admin opt-in snapshot.
#
# Usage: pr-grind-step0.sh <PR_NUMBER> [<PR_INVOCATION_URL>]
#   PR_NUMBER          digits, no leading zero.
#   PR_INVOCATION_URL  only when the PR was named by URL (#890): the argument VERBATIM, never
#                      normalized. Its shape is checked by scripts/pr-head-identity.sh alone;
#                      a URL containing `'` is refused here (START already bails on it).
# Runs at the CALLER's cwd, the session checkout: the baseref skip file is read there and
# scripts/resolve-pr-worktree.sh resolves the repository from it. The `cd` into the
# resolved worktree below lasts only for this process.
# Prints the cross-block records the dispatcher must remember literally: PR_BRANCH=, the
# three PR_HEAD_* lines, `pr-grind-mode: no-worktree` (when the resolver fell back
# in-place), WORKTREE_DIR= and BASE_SHA=.
# Exit 0: proceed. Exit 1: a hard BAIL (reason printed) — do not proceed to any later step.
# Exit 2: bad arguments; nothing printed on stdout.
#
# Why a script (#1078): inline, this ~305-line block's `case` glob patterns (`/*`,
# `''|*[!0-9]*`) sat in a multi-line command with comments and `$(...)`, the shape in which
# marker_check's #776 case-pattern release deliberately stays off, so the helper guard
# refused the block as "Cannot call lease_slot.py directly". As a script its body is not a
# typed command, so the guard never reads it.
# No `set -u`/`-e`: the inline block this was moved from ran without them, and its body is
# unchanged apart from the arguments.

usage() {
  echo "usage: pr-grind-step0.sh <PR_NUMBER> [<PR_INVOCATION_URL>]" >&2
  exit 2
}
{ [ "$#" -ge 1 ] && [ "$#" -le 2 ]; } || usage
PR_NUMBER="$1"
case "$PR_NUMBER" in ''|0*|*[!0-9]*) echo "pr-grind-step0: PR_NUMBER must be digits with no leading zero: '$PR_NUMBER'" >&2; exit 2 ;; esac
INVOCATION_URL_GIVEN=0
PR_INVOCATION_URL=""
if [ "$#" -eq 2 ]; then
  INVOCATION_URL_GIVEN=1
  PR_INVOCATION_URL="$2"
  case "$PR_INVOCATION_URL" in *"'"*) echo "pr-grind-step0: unrecognised PR argument (the URL contains a single quote)" >&2; exit 2 ;; esac
fi
# The plugin this script ships in, so every sibling script it calls is the same version.
if ! CLAUDE_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); then  # before any cd: BASH_SOURCE may be relative
  # Not an argument problem, so exit 1 (BAIL), never exit 2 (re-substitute and re-run).
  echo "❌ pr-grind-step0: could not derive the plugin root from '${BASH_SOURCE[0]}'. Not proceeding."
  exit 1
fi

# Capture pr-grind invocation start time BEFORE any other operation. The
# solo-admin opt-in freshness check (snapshot writer near the end of this
# script) anchors against this timestamp, not NOW_EPOCH at snapshot time —
# otherwise a slow `gh pr view` / `git worktree add` could push elapsed
# time past 30s and let an opt-in file created mid-invocation satisfy the
# anti-self-bypass gate it's supposed to defeat.
INVOCATION_START_EPOCH=$(date +%s)

# Base-branch guard — refuse to grind a PR whose base is not one of the
# canonical trunks unless the operator explicitly opted in (stacked-PR
# workflows, long-lived feature integration branches). A non-trunk base
# can cause pr-grind to merge "successfully" into a closed-PR branch
# while leaving main untouched — a silent failure (state=MERGED still
# returned by the GitHub API) that costs a recovery cycle to detect.
#
# Two escape hatches (matching the busdriver gate convention):
#   1. File:    .claude/skip-baseref-check.local (touched in the user's terminal)
#   2. Env var: PR_GRIND_ALLOW_NON_MAIN_BASE=1 (exported in the PARENT shell
#              BEFORE launching claude — inline `PR_GRIND_ALLOW_NON_MAIN_BASE=1
#              claude` does NOT work because hooks fire before inline env applies,
#              same caveat as SKIP_LITMUS).
#
# Capture stderr so auth/network errors are surfaced in the bail message
# instead of being swallowed by `2>/dev/null`.
#
# ONE contained query answers every Step 0 PR read (#890): base, head, fork flag
# and the PR's home repository. Two separate `gh` calls could be answered for
# different repositories. GH_HOST/GH_REPO are pinned only inside this subshell
# (same containment as the Codex nudge), so Step 0 is github.com-only: a PR on
# another host fails here and BAILs before any worktree exists.
BASE_BRANCH_ERR=$(mktemp)
PR_META=$( export GH_HOST=github.com; unset GH_REPO; gh pr view "$PR_NUMBER" --json baseRefName,headRefName,headRefOid,isCrossRepository,url,headRepositoryOwner,headRepository 2>"$BASE_BRANCH_ERR" ) || PR_META=""
BASE_BRANCH=$(printf '%s' "$PR_META" | jq -r '.baseRefName // empty' 2>/dev/null || true)
# Normalize: strip CR/whitespace/control chars defensively. Use sed first
# to remove full ANSI escape sequences (ESC + printable tail like `[0m`)
# before tr strips any remaining control bytes; tr alone only removes the
# ESC byte (0x1B) and leaves the printable remnants attached to the value.
BASE_BRANCH=$(printf '%s' "$BASE_BRANCH" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '[:space:][:cntrl:]')

if [ -f ".claude/skip-baseref-check.local" ] || [ "${PR_GRIND_ALLOW_NON_MAIN_BASE:-0}" = "1" ]; then
  BASEREF_BYPASS=1
else
  BASEREF_BYPASS=0
fi

# CRITICAL: if the case block below exits non-zero, the dispatcher MUST treat
# this as a hard BAIL — surface the error to the user and HALT pr-grind. Do
# NOT proceed to the worktree creation below or any subsequent step. This is
# the same exit-1 contract used by the worktree-add failure path further down.
case "$BASE_BRANCH" in
  main|master|develop) ;;  # canonical trunks — proceed
  "")
    echo "❌ Could not resolve baseRefName for PR $PR_NUMBER."
    if [ -s "$BASE_BRANCH_ERR" ]; then
      echo "   gh stderr: $(tr -d '\r' < "$BASE_BRANCH_ERR" | head -c 400)"
    fi
    echo "   Check 'gh pr view $PR_NUMBER' and network/auth."
    rm -f "$BASE_BRANCH_ERR"
    exit 1
    ;;
  *)
    if [ "$BASEREF_BYPASS" != "1" ]; then
      echo "❌ PR $PR_NUMBER targets '$BASE_BRANCH', not a canonical trunk (main/master/develop)."
      echo "   Merging into a non-trunk branch can land the PR on a closed or stale base"
      echo "   while still returning state=MERGED — a silent failure mode (precedent: PR #122)."
      echo "   If this is intentional (stacked PR, long-lived feature branch), either:"
      echo "     - In your terminal: touch .claude/skip-baseref-check.local"
      echo "     - Or in the PARENT shell BEFORE launching claude: export PR_GRIND_ALLOW_NON_MAIN_BASE=1"
      echo "       (inline 'PR_GRIND_ALLOW_NON_MAIN_BASE=1 claude' does NOT work — same rule as SKIP_LITMUS)"
      rm -f "$BASE_BRANCH_ERR"
      exit 1
    fi
    echo "⚠️  PR $PR_NUMBER targets '$BASE_BRANCH' (non-canonical) — proceeding via baseref bypass."
    ;;
esac
rm -f "$BASE_BRANCH_ERR"

# Same PR_META as the base read above — no second gh call.
PR_BRANCH=$(printf '%s' "$PR_META" | jq -r '.headRefName // empty')
PR_HEAD_SHA=$(printf '%s' "$PR_META" | jq -r '.headRefOid // empty')
# NOT `// empty` here: jq's `//` treats `false` as absent just like `null`, so
# the alternative would fire on every SAME-REPO PR (isCrossRepository=false) and
# hard-exit the common path. Read the field raw and validate it as a boolean.
PR_IS_FORK=$(printf '%s' "$PR_META" | jq -r '.isCrossRepository')
if [ -z "$PR_BRANCH" ] || [ -z "$PR_HEAD_SHA" ]; then
  echo "❌ could not resolve PR head ref/oid for $PR_NUMBER — not proceeding."
  exit 1
fi
case "$PR_IS_FORK" in
  true|false) ;;
  *) echo "❌ isCrossRepository for $PR_NUMBER was '$PR_IS_FORK', not a boolean — not proceeding."; exit 1 ;;
esac
# Cross-block record for the envelope wrapper's BD890 PR BRANCH END heredoc: copy
# the value after `PR_BRANCH=` verbatim (shell vars do not survive Bash calls).
printf 'PR_BRANCH=%s\n' "$PR_BRANCH"

# FORK PRs ARE NOT SUPPORTED — refuse before touching anything. This is a hard
# stop, not a limitation to route around.
#
# `headRefName` is chosen by the PR's source repository and is NOT
# repository-qualified: a fork can name its branch `main`. Any path that maps
# that name onto a LOCAL ref is the wrong-branch class #421 exists to prevent.
# Skipping the fetch is NOT sufficient — a fork branch named `main` whose head
# merely happens to equal the local `main` SHA would satisfy the resolver's
# assertion, take in-place mode, and let grind commits push to the UPSTREAM
# branch instead of the fork.
#
# Nor is this a real capability loss: a grind must push its fix commits to the
# PR head, which requires write access to the fork — access this flow never had.
# "Supporting" fork PRs here could only ever mean pushing somewhere wrong.
if [ "$PR_IS_FORK" = "true" ]; then
  echo "❌ PR $PR_NUMBER is from a fork. pr-grind cannot grind fork PRs: it would"
  echo "   need push access to the fork's head branch, and a fork-chosen branch"
  echo "   name must never be resolved against a local ref (#421)."
  echo "   Review the PR manually, or ask the author to push to a branch in this repo."
  exit 1
fi

# PR home repository (#890). The dispatcher pushes only to an origin whose
# effective push URL IS this repository, so the tuple must come from GitHub's PR
# object — never from origin config, which the checkout controls. The helper is
# the only parser (no inline jq of identity fields) and fails closed. The form
# follows START's "Resolve PR #" record, which the dispatcher passes as the
# argument count: a URL invocation passes PR_INVOCATION_URL verbatim as the
# second argument (never normalized here — the helper is the only shape
# validator, so even an empty one reaches it and is refused there);
# `/pr-grind <N>` and auto-detect pass the number alone.
if [ "$INVOCATION_URL_GIVEN" = 1 ]; then
  PR_HEAD_IDENTITY=$(printf '%s' "$PR_META" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number "$PR_NUMBER" --invocation-url "$PR_INVOCATION_URL") || PR_HEAD_IDENTITY=""
else
  PR_HEAD_IDENTITY=$(printf '%s' "$PR_META" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-head-identity.sh" --pr-number "$PR_NUMBER") || PR_HEAD_IDENTITY=""
fi
if [ -z "$PR_HEAD_IDENTITY" ]; then
  echo "❌ could not establish PR $PR_NUMBER's home repository from GitHub (see pr-head-identity above) — not proceeding."
  exit 1
fi
# Relay the three lines (same stdout contract as WORKTREE_DIR): the fix-round
# dispatcher invocation template-substitutes them as literals.
printf '%s\n' "$PR_HEAD_IDENTITY"

# Same-repo from here. Reconcile the local branch with the PR head BEFORE
# resolving, so the ordinary "someone pushed to the PR" case proceeds instead of
# bailing. Belt-and-braces: never fetch into the base branch, so a malformed
# same-repo case cannot reach the fetch either.
if [ "$PR_BRANCH" != "$BASE_BRANCH" ]; then
  # Fast-forward only — note the absence of a leading `+`. A divergent local
  # branch must NOT be silently rewritten; the fetch fails, the SHA assertion
  # bails, and the operator decides. Same outcome when the branch is currently
  # checked out, which git refuses to update via fetch. The branch name is one
  # argv element to git, never shell-evaluated, so a hostile name containing
  # `$(...)`, backticks, `;` or `|` cannot execute anything.
  git fetch -q origin "refs/heads/${PR_BRANCH}:refs/heads/${PR_BRANCH}" 2>/dev/null || true
fi

# Resolve the grind's working directory. The resolver (#421) owns the three-way
# split — branch free / checked out HERE / held by ANOTHER worktree — and BAILs
# fail-CLOSED on the third rather than silently pointing the grind at the repo
# root's branch. It also asserts unconditionally, in BOTH modes, that the
# resolved dir is on `$PR_BRANCH` AND at `$PR_HEAD_SHA` — name alone would let a
# stale or unrelated same-named local branch through (fork PRs especially).
#
# Its stdout is the cross-block source of truth (shell vars don't survive across
# Claude tool calls): `pr-grind-mode: no-worktree` when it fell back in-place,
# and always a final `WORKTREE_DIR=<abs path>`.
RESOLVE_OUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-pr-worktree.sh" "$PR_NUMBER" "$PR_BRANCH" "$PR_HEAD_SHA" 2>&1)
RESOLVE_EXIT=$?
printf '%s\n' "$RESOLVE_OUT"
if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo "❌ Step 0 worktree resolution failed — see above. Not proceeding."
  exit 1
fi

if printf '%s' "$RESOLVE_OUT" | grep -q '^pr-grind-mode: no-worktree$'; then
  # shellcheck disable=SC2034  # kept from the inline block; the dispatcher reads the printed marker, not this
  NO_WORKTREE=1
fi
WORKTREE_DIR=$(printf '%s' "$RESOLVE_OUT" | grep '^WORKTREE_DIR=' | tail -1 | sed 's/^WORKTREE_DIR=//')
if [ -z "$WORKTREE_DIR" ]; then
  echo "❌ resolver exited 0 but emitted no WORKTREE_DIR — refusing to guess."
  exit 1
fi
cd "$WORKTREE_DIR" || { echo "❌ cd to '$WORKTREE_DIR' failed — cannot proceed."; exit 1; }

# --- Durable grind provenance: resolve the base floor ONCE (Rail A / ADR 0036) ---
# Deliberately HERE, after the resolver produced WORKTREE_DIR and after the `cd`
# above — not up with BASE_BRANCH resolution ~70 lines earlier, where
# WORKTREE_DIR does not exist yet and a `git -C ""` would be fatal on every
# single invocation.
#
# Why not `gh pr view --json baseRefOid`: it does not materialize the object
# locally (the only other fetch, above, fetches the PR head only), so
# `git rev-list <missing-sha>..HEAD` fails rc 128 and hard-BAILs every grind.
# It is also frozen at PR creation, not the live base tip.
# Why not `origin/<base>`: commonly stale in this repo specifically —
# semantic-release pushes a release commit to main after every merge.
#
# The `+` force refspec is load-bearing: fast-forward enforcement applies to
# custom namespaces too, so without it a base retarget or force-push would
# reject the fetch, leave the OLD value in place, and turn a scratch pointer
# into a permanent BAIL with no self-healing path. Forcing is safe because the
# ref names no work and protects no history: it is read once, immediately, and
# deleted in this same script.
#
# The `-$$` suffix is what makes it race-free — NOT the deletion. Linked
# worktrees share the common dir's refs and pr-grind explicitly contemplates
# concurrent runs, so PR-scoping alone still lets two grinds on the SAME PR
# interleave: one deletes the ref between the other's fetch and its merge-base,
# causing a spurious provenance-unavailable bail. A per-invocation name removes
# the shared object outright. The deletion is cleanup, and living in this same
# script is why there is no COMPLETION/BAIL cleanup row to forget.
git fetch --no-tags -q origin \
  "+refs/heads/${BASE_BRANCH}:refs/bd-grind/$PR_NUMBER/base-$$" || {
  echo "❌ Step 0 could not fetch base branch '$BASE_BRANCH' — grind provenance unavailable."
  exit 1
}
# The floor is the MERGE BASE, not the fetched tip. The live tip is not an
# ancestor of the PR head the moment the base branch advances after the branch
# diverged — the routine `mergeStateStatus=BEHIND` case here — and
# grind-pr-commits.sh refuses a non-ancestor range, so using the tip directly
# would BAIL before every dispatch on ordinary behind-but-valid PRs.
#
# The merge base is an ancestor of HEAD by construction, and `merge-base..HEAD`
# is exactly this branch's own commits: it still excludes the trunk squash
# commits whose concatenated bodies carry Grind-PR: lines, which is the whole
# point of scoping the range.
BASE_SHA=$(git merge-base "refs/bd-grind/$PR_NUMBER/base-$$" HEAD) || {
  # Delete on the FAILURE path too. Cleaning up only on success means every
  # failed invocation leaves a hidden ref pinning objects indefinitely — and the
  # comment above promises same-script cleanup, so this branch has to honour it.
  git update-ref -d "refs/bd-grind/$PR_NUMBER/base-$$" \
    || echo "⚠️  also could not delete scratch ref refs/bd-grind/$PR_NUMBER/base-$$ — remove it manually"
  echo "❌ Step 0 could not find a merge base between '$BASE_BRANCH' and the PR head"
  echo "   (unrelated histories?) — grind provenance unavailable."
  exit 1
}
# Scratch pointer, already consumed. A failure to delete does not invalidate
# BASE_SHA, so it must not abort the grind — but it is not swallowed either:
# a silent `|| true` here is how leaked refs go unnoticed.
git update-ref -d "refs/bd-grind/$PR_NUMBER/base-$$" \
  || echo "⚠️  could not delete scratch ref refs/bd-grind/$PR_NUMBER/base-$$ — remove it manually"
# Cross-block record. Shell state does NOT survive across Claude Bash tool calls,
# so Claude MUST remember this literal 40-hex value and template-substitute it
# into every downstream block, exactly as it already does for WORKTREE_DIR and
# NO_WORKTREE (see SKILL.md's substitution convention). Do NOT write
# `$BASE_SHA` in a later block — it resolves to empty in a fresh shell.
echo "BASE_SHA=$BASE_SHA"

# Snapshot the solo-admin opt-in file at pr-grind INVOCATION TIME, so the
# anti-self-bypass freshness check anchors to "≥30s old at invocation start"
# rather than "at Completion time". A pr-grind run can last minutes; without
# this snapshot, an autonomous agent could `touch` the file at the start of
# a slow run and have it satisfy the 30s threshold by the time the Completion
# merge block runs. The snapshot lives in the MAIN repo's .claude/ (not the
# worktree's), because the operator's opt-in file is in the main repo and
# .claude/*.local is gitignored / not copied into ephemeral worktrees.
# `git rev-parse --git-common-dir` returns the SHARED .git/ across worktrees,
# whose parent is the main repo root.
#
# Per-PR snapshot path: includes ${PR_NUMBER} so two concurrent pr-grind
# runs on DIFFERENT PRs cannot race on a single shared snapshot file. A
# same-PR concurrent run is a degenerate case (operator running pr-grind
# twice on the same PR simultaneously) and accepts last-writer-wins.
# Snapshot is written 0600 to prevent other local users from reading the
# mtime token (defense in depth — the threat model already assumes
# attacker has same-user write access, in which case this is marginal).
# Step 0 has already `cd`-ed into the worktree at this point (or, in
# --no-worktree mode, into the repo root). A bare `git rev-parse` here
# would work but is CWD-sensitive; `git -C "$WORKTREE_DIR"` is explicit
# and matches the symmetric Completion-side resolver. Two-step resolve +
# absolute-path check defends against `dirname ""` returning "." on a
# failed rev-parse, which would otherwise leak the CWD path through.
MAIN_REPO_ROOT_FOR_OPTIN=""
GIT_COMMON_DIR=$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$GIT_COMMON_DIR" ]; then
  CANDIDATE=$(dirname "$GIT_COMMON_DIR")
  case "$CANDIDATE" in
    /*) MAIN_REPO_ROOT_FOR_OPTIN="$CANDIDATE" ;;
    *)  : ;;
  esac
fi
if [ -n "$MAIN_REPO_ROOT_FOR_OPTIN" ] && [ -d "$MAIN_REPO_ROOT_FOR_OPTIN/.claude" ]; then
  SOLO_OPTIN_FILE="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/pr-grind-auto-admin-solo.local"
  SOLO_OPTIN_SNAPSHOT="$MAIN_REPO_ROOT_FOR_OPTIN/.claude/.pr-grind-solo-opt-in-snapshot-${PR_NUMBER}.local"
  # Always clear any prior per-PR snapshot — fresh run, fresh truth.
  rm -f "$SOLO_OPTIN_SNAPSHOT"
  if [ -f "$SOLO_OPTIN_FILE" ]; then
    OPTIN_MTIME=$(stat -c %Y "$SOLO_OPTIN_FILE" 2>/dev/null || stat -f %m "$SOLO_OPTIN_FILE" 2>/dev/null || echo 0)
    case "$OPTIN_MTIME" in ''|*[!0-9]*) OPTIN_MTIME=0 ;; esac
    if [ "$OPTIN_MTIME" -eq 0 ]; then
      echo "⚠️  stat failed on $SOLO_OPTIN_FILE — cannot verify age, solo-admin auto-detect will NOT fire this run." >&2
    else
      # Anchor freshness check against INVOCATION_START_EPOCH (captured at
      # the very top of Step 0), NOT a fresh `date +%s` here. Otherwise
      # earlier Step 0 work (gh pr view, git worktree add) that takes ≥30s
      # would let an opt-in file created mid-invocation pass the gate.
      OPTIN_AGE_AT_START=$((INVOCATION_START_EPOCH - OPTIN_MTIME))
      if [ "$OPTIN_AGE_AT_START" -ge 30 ]; then
        if printf '%s\n' "$OPTIN_MTIME" > "$SOLO_OPTIN_SNAPSHOT"; then
          chmod 600 "$SOLO_OPTIN_SNAPSHOT" 2>/dev/null
          echo "ℹ️  pr-grind-auto-admin-solo.local snapshotted (age-at-invocation=${OPTIN_AGE_AT_START}s, PR #${PR_NUMBER}) — solo-admin auto-detect armed for this run."
        else
          echo "⚠️  snapshot write failed for $SOLO_OPTIN_SNAPSHOT (disk full or permission denied?) — solo-admin auto-detect will NOT fire this run." >&2
          rm -f "$SOLO_OPTIN_SNAPSHOT"
        fi
      else
        echo "⚠️  pr-grind-auto-admin-solo.local exists but was too fresh at pr-grind invocation start (age=${OPTIN_AGE_AT_START}s, required ≥30s) — solo-admin auto-detect will NOT fire this run. If you just touched the file, wait 30s and rerun pr-grind." >&2
      fi
    fi
  fi
fi
