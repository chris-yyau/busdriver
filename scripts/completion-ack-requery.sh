#!/usr/bin/env bash
# scripts/completion-ack-requery.sh — pr-grind COMPLETION's fresh re-query of the
# reviewer ack ledger (skills/pr-grind/references/completion.md, "Re-query the ack
# ledger fresh"). Read-only toward GitHub except the bounded `@codex review` nudge it
# has always posted; it merges nothing and writes no clean marker.
#
# Usage: completion-ack-requery.sh <PR> <OWNER> <REPO> <WORKTREE_DIR> [<DOWNGRADED_BOTS>]
#   WORKTREE_DIR    the absolute Step 0 worktree (the checkout itself with NO_WORKTREE=1).
#                   The script runs from there: HEAD, the main-repo root and the
#                   codex-retrigger markers are all derived from that checkout.
#   DOWNGRADED_BOTS comma-separated logins released by the ADR 0012 downgrade, or
#                   empty on the normal clean path.
# Exit 0: every gated ack is fresh (prints the ADR 0064 line when Kody's skip needs the
# waiver step). Exit 1: a stale ack blocks the merge (printed). Exit 2: bad arguments.
#
# Why a script (#1078): this was a ~540-line inline fence. Its `case` glob patterns
# (`/*`, `''|*[!0-9]*`) sit in a multi-line command with comments and `$(...)`, the shape
# in which marker_check's #776 case-pattern release deliberately stays off, so the
# helper guard refused the fence as "Cannot call lease_slot.py directly". As a script
# its body is not a typed command, so the guard never reads it.
# No `set -u`: the inline block this was moved from ran without it, and its body (plus the
# libraries it sources) is unchanged.

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: completion-ack-requery.sh <PR> <OWNER> <REPO> <WORKTREE_DIR> [<DOWNGRADED_BOTS>]" >&2
  exit 2
fi
PR="$1"
OWNER="$2"
REPO="$3"
WORKTREE_DIR="$4"
# ADR 0012: comma-separated logins released by the bounded stale-ack downgrade
# (empty on the normal clean path).
DOWNGRADED_BOTS="${5:-}"
case "$PR" in ''|*[!0-9]*) echo "completion-ack-requery: PR must be a number: '$PR'" >&2; exit 2 ;; esac
case "$WORKTREE_DIR" in /*) ;; *) echo "completion-ack-requery: WORKTREE_DIR must be absolute: '$WORKTREE_DIR'" >&2; exit 2 ;; esac
# The plugin this script ships in, so every sibling script it calls is the same version.
CLAUDE_PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2  # before any cd: BASH_SOURCE may be relative
cd "$WORKTREE_DIR" || { echo "completion-ack-requery: cannot cd to '$WORKTREE_DIR'" >&2; exit 2; }
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches — same four sources as worker's Step 6.5.
# FETCH_OK tracks failure; fail-CLOSED to `stale` on any source failure.
FETCH_OK=1
# GitHub's clock right BEFORE the threads query (Tier K settle window, ADR 0058).
THREADS_FETCHED_AT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/github-server-now.sh" 2>/dev/null) || THREADS_FETCHED_AT=""
# shellcheck disable=SC2016  # gh GraphQL needs literal $var refs, not shell expansion
ALL_THREADS=$(gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$pr) {
        number author{__typename login resourcePath}
        reviewThreads(first:100, after:$endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved isOutdated
            resolvedBy { login }
            comments(first:1) { nodes { author { login } createdAt } }
            resolutionComments: comments(last:10) { nodes { author { login } createdAt } }
          }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
ALL_COMMENTS=$(gh pr view "$PR" --json comments 2>/dev/null) || FETCH_OK=0
# Source 5: check-runs on HEAD — same as worker/Step 6.5 fetch above.
# (Despite "same four sources" wording elsewhere — that count refers to
# findings sources; ack-ledger reads six sources: 1-4 above plus check-runs
# and commit statuses.)
ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0
# Source 6: commit statuses on HEAD — same as worker/Step 6.5 fetch above.
ALL_STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || FETCH_OK=0
# Source 7: issue-level reactions + HEAD push time for Codex's Tier-F gate
# (👍 reaction). --paginate so Codex's reaction isn't missed behind >30 human
# PR-body reactions (Tier F slurps the page stream).
ALL_REACTIONS=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/reactions" 2>/dev/null) || FETCH_OK=0
HEAD_COMMITTED_DATE=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null || echo "")
# HEAD_PUSH_DATE: push event timestamp — the SOLE Tier-F +1 freshness anchor.
# Bounded to one events page (#624); PushEvent not in window → empty → Tier F fails
# CLOSED to stale (no committer fallback — the committer date is backdatable, #189).
# HEAD_COMMITTED_DATE is fetched best-effort and NOT gated on FETCH_OK (nothing reads it).
HEAD_FULL_SHA=$(git rev-parse HEAD)
# ONE gh pr view for both fields — this runs on a hot polling path.
# Fork PRs: $OWNER/$REPO is the BASE repo, whose events feed can never witness a branch
# living in the fork, so the #624 CreateEvent gate is not applicable there — without this
# every fork PR would stale forever (#271-class). Unknown ⇒ 0 (strict same-repo path).
PR_VIEW_JSON=$(gh pr view "$PR" --json headRefName,isCrossRepository 2>/dev/null || echo '{}')
PR_BRANCH=$(printf '%s' "$PR_VIEW_JSON" | jq -r '.headRefName // empty' 2>/dev/null || echo "")
PR_CROSS_REPO=$(printf '%s' "$PR_VIEW_JSON" | jq -r 'if .isCrossRepository == true then "1" else "0" end' 2>/dev/null || echo "0")
HEAD_PUSH_LIB="${CLAUDE_PLUGIN_ROOT}/scripts/lib/head-push-date.sh"
# shellcheck source=scripts/lib/head-push-date.sh disable=SC1091
[ -f "$HEAD_PUSH_LIB" ] && . "$HEAD_PUSH_LIB"
HEAD_PUSH_CHECKS_FALLBACK_OK=0
resolve_head_push_date_with_fallback_gate "$OWNER" "$REPO" "$HEAD_FULL_SHA" "$PR_BRANCH" "${PR_CROSS_REPO:-0}"
HEAD_PUSH_DATE="${HEAD_PUSH_DATE:-}"
# HEAD_CHECKS_DATE (#269): SHA-bound fallback freshness anchor. HEAD_PUSH_DATE
# (PushEvent) is preferred, but it is empty for a brand-new branch whose FIRST push CREATED
# the ref (GitHub emits a CreateEvent, not a PushEvent) — a genuine fresh Codex 👍 then
# fail-closes to stale forever. Fall back to the earliest check-SUITE created_at stamped for
# THIS HEAD SHA. Do NOT also filter on head_branch (#271): GitHub emits ONE check_suite per
# commit SHA GLOBALLY (docs), so the suite's head_branch is whatever branch the SHA was FIRST
# pushed to — which may differ from this PR branch, or be null (forks) — and filtering it out
# would drop the only suite and fail-close a fresh ack to stale forever. The endpoint is
# already SHA-scoped and created_at is content-bound; the EARLIEST is the most conservative
# (older = fail-closed). Unlike a check-RUN started_at or the committer date, the suite
# created_at is NOT app/client-settable (preserves #186/#189). No suite (no CI yet, fork ns)
# → empty → ack-ledger fails closed.
HEAD_CHECKS_DATE=""
# Fail-CLOSED (litmus, PR #280): require PR_BRANCH known before using this fallback,
# EVEN THOUGH the jq filter above is SHA-only. GitHub emits per-(SHA,ref) check-suites
# (a `refs/pull/N/head` suite can carry an older created_at than the real PR-head push),
# so a SHA-only lookup run with the branch UNKNOWN could anchor Codex-ack freshness on a
# backdated suite and accept a stale 👍 / resolved thread as fresh. When PR_BRANCH is empty
# (transient `gh pr view` failure, deleted/fork branch) we cannot confirm the suite belongs
# to this PR — fail closed to stale rather than risk a backdated ack. Deliberate, not dead code.
if [ -z "$HEAD_PUSH_DATE" ] && [ "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}" = "1" ] && [ -n "${PR_BRANCH:-}" ] && [ -n "${HEAD_FULL_SHA:-}" ]; then
  SUITES_JSON=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_FULL_SHA/check-suites" 2>/dev/null || echo "")
  HEAD_CHECKS_DATE=$(printf '%s' "$SUITES_JSON" \
    | jq -rs --arg sha "$HEAD_FULL_SHA" \
      '[.[].check_suites[]? | select(.head_sha==$sha) | .created_at] | map(select(. != null and . != "")) | sort | .[0] // empty' 2>/dev/null || echo "")
  # Drop a suite predating this branch's creation (#624 R2). Shared helpers so the three
  # consumers cannot drift; no-op when either date is empty (e.g. a fork PR).
  apply_head_checks_floor
  # ...but do not lose a VALID post-creation suite with it (#743 Codex P2): re-select the
  # earliest suite AT/AFTER the floor from the same response.
  if [ -z "$HEAD_CHECKS_DATE" ] && [ -n "${HEAD_PUSH_CREATE_DATE:-}" ]; then
    HEAD_CHECKS_DATE=$(head_checks_date_after_floor_from_suites_json \
      "$SUITES_JSON" "$HEAD_FULL_SHA" "$HEAD_PUSH_CREATE_DATE")
  fi
fi

# Per-bot ack — same single-sourced algorithm as the worker's Step 6.5 in
# agents/pr-grinder.md. Both sites invoke scripts/ack-ledger.sh; algorithm
# edits live in that one file.
# Tier D carry-forward across message-only force-pushes: widen the HEAD-scoped
# check-runs with any content-identical predecessor's check-runs before the ledger
# runs (additive, best-effort, git-proven; no-op under ACK_CONTENT_IDENTITY=0; Tier E
# statuses are NOT widened). Keep in sync with scripts/fetch-pr-state.sh,
# agents/pr-grinder.md, and the worker mirror above.
# shellcheck disable=SC2034  # PR_NUMBER is read by the sourced augment-equiv-acks.sh
PR_NUMBER="$PR"; AUGMENT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/augment-equiv-acks.sh"
# shellcheck source=scripts/augment-equiv-acks.sh disable=SC1091
[ -f "$AUGMENT_SCRIPT" ] && . "$AUGMENT_SCRIPT"
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA HEAD_FULL_SHA THREADS_FETCHED_AT
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
# Codex (chatgpt-codex-connector) is appended as a second gated reviewer here:
# its Tier-F 👍 reaction is the authoritative clean signal, and a `stale` value
# (still reviewing, or hasn't re-acked HEAD after the last push) must block the
# merge exactly like a stale registered bot. It is NOT in RESULT_REVIEWER_ACKS
# (the registered bots feeding Invariant 3) — only in this final gate scan.
FRESH_ACKS="kody-ai=$(bash "$ACK_SCRIPT" kody-ai 2>/dev/null || echo stale),chatgpt-codex-connector=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo stale)"
# Codex first-engagement grace. If Codex resolved to `none` — zero reaction/
# review on the PR — it may simply not have posted its initial 👀 on a just-
# pushed HEAD yet; without this a Codex-ONLY repo (no registered bots forcing
# wait-rounds) could merge in the gap before Codex starts. Re-poll on a bounded
# DEADLINE, early-exiting the instant Codex engages. This rarely fires: COMPLETION
# is reached only after the loop has converged, by which point an active Codex has
# long since engaged (ack is a SHA/stale, not `none`) — so on repos where Codex
# runs there is no wait here.
# Set PR_GRIND_CODEX_GRACE_SECS=0 on repos that do not use Codex to skip the
# wait entirely. Bounded by design; never an unbounded hang.
#
# DEADLINE SIZING (2026-07-19, issue #420) — the old default was a SINGLE blind
# 20s sleep. Measured `@codex review` → Codex-review latency on this repo was
# 3m37s / 4m58s / 6m36s / 7m27s (PRs #412/#419/#409/#390): ~15x the grace. The
# re-poll therefore ALWAYS observed `none` and fell through, merging seconds
# before the review landed (#419 merged 5s after its own nudge; the review
# arrived 5min later, on a closed PR). The default is now a 480s deadline polled
# every 30s, so a fast Codex costs ~30s and a slow one is still caught.
# This grace handles ONLY the `none` case (Codex never engaged). The `stale` case —
# Codex reviewed but won't re-ack an UNCHANGED HEAD — is handled earlier, in the
# LOOP, by the bounded codex-retrigger (ADR 0005 + #673, scripts/codex-retrigger.sh):
# COMPLETION is unreachable while Codex is `stale` (Invariant 2 blocks `clean`), so
# the recovery for `stale` must live in the wait-round, not here.
CODEX_DONE=$(printf '%s' "$FRESH_ACKS" | tr ',' '\n' | awk -F= '$1=="chatgpt-codex-connector"{print $2}')
CODEX_GRACE="${PR_GRIND_CODEX_GRACE_SECS:-480}"
CODEX_POLL="${PR_GRIND_CODEX_POLL_SECS:-30}"
# Sanitize both: non-numeric/empty → default. A bad value must not make the
# arithmetic below error out (this block runs without `set -e`) or spin hot.
# The `10#` canonicalization is load-bearing, not cosmetic: `0480` passes the
# all-digits test but `$(( ))` reads a leading zero as OCTAL, and digits 8/9 then
# abort the whole COMPLETION shell with "value too great for base". Same guard
# codex-active-repo.sh applies to its window.
case "$CODEX_GRACE" in '' | *[!0-9]*) CODEX_GRACE=480 ;; esac
case "$CODEX_POLL"  in '' | *[!0-9]*) CODEX_POLL=30  ;; esac
CODEX_GRACE=$((10#$CODEX_GRACE))
CODEX_POLL=$((10#$CODEX_POLL))
[ "$CODEX_POLL" -lt 1 ] && CODEX_POLL=30
# ADR 0013 revision (#320): the `none`-nudge + the missing-Codex warning now fire
# when the repo is PROVEN Codex-active (auto-detect over recent reviews/reactions)
# OR the force-on opt-in file is present — no longer gated on the manual marker.
# Detection is DECOUPLED from grace>0 so PR_GRIND_CODEX_GRACE_SECS=0 still disables
# the WAIT+nudge but leaves the warning intact. CODEX_REGRACE defaults to CODEX_DONE
# so the grace=0 path has a defined value (this block runs without `set -u`).
CODEX_REGRACE="$CODEX_DONE"
CODEX_REPO_ACTIVE=0
if [ "$CODEX_DONE" = "none" ]; then
  # Auto-detect whether Codex is an active reviewer on THIS repo. Skip the GraphQL
  # call entirely when the nudge is kill-switched off (PR_GRIND_CODEX_RETRIGGER=0) —
  # a disabled repo pays no network round-trip and gets no warning. Stdout is
  # discarded; the detector's stderr diagnostic still reaches the transcript.
  # Detection here is INDEPENDENT of the clean-path hoist's own probe (issue #467). We do
  # NOT reuse the hoist's one-shot nudge marker to short-circuit this: marker presence means
  # "a nudge was posted" (force-on OR active), which is NOT the same as "historically active"
  # — CODEX_REPO_ACTIVE gates the "engaged on recent PRs" warning and the full-grace wait, so
  # deriving it from the marker would emit a false warning for force-on repos and would honor
  # a marker written before the kill switch was set. So COMPLETION re-derives active-ness from
  # scratch. The accepted consequence: on a clean `none` round a Codex-active/force-on repo
  # pays ONE extra codex-active probe (the hoist's), on top of this one — a deliberate, bounded
  # tradeoff for firing the nudge before any merge-path shortcut. A Codex-less repo zeros BOTH
  # probes with PR_GRIND_CODEX_RETRIGGER=0 (the same kill switch gates the hoist and this call).
  if [ "${PR_GRIND_CODEX_RETRIGGER:-1}" != "0" ] \
     && bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-active-repo.sh" "$OWNER/$REPO" >/dev/null; then
    CODEX_REPO_ACTIVE=1
  fi
  # Force-on cold-start opt-in — a repo where Codex IS expected but has no history
  # yet, so auto-detect reads inactive. This MUST resolve the marker byte-identically
  # to codex-nudge-if-expected.sh:60-64, or the wrapper posts the force-on nudge while
  # this gate caps the wait at 20s and recreates the very race being closed. So:
  # resolve from $WORKTREE_DIR (the wrapper's CWD, not the possibly-drifted ambient
  # one), honor BUSDRIVER_MAIN_ROOT, and use a LITERAL `.claude` — the wrapper does
  # NOT honor BUSDRIVER_STATE_DIR here, and reading a different dir than the wrapper
  # is exactly the mismatch. Fail-SAFE: unresolvable → 0 → short wait, never long.
  # Deliberately NOT gated on PR_GRIND_CODEX_RETRIGGER, so the force-on marker keeps
  # working under the kill switch.
  #
  # Be precise about what that does and does not buy, because two review rounds
  # pulled in opposite directions here. PR_GRIND_CODEX_RETRIGGER=0 ALREADY suppresses
  # auto-detection above (deliberately — a switched-off repo pays no GraphQL
  # round-trip), so with the switch on and NO force-on marker the wait is the 20s
  # courtesy one even if Codex would have auto-reviewed. That coupling is inherited,
  # not introduced here, and it is the documented semantic of a switch named "kill":
  # the operator turned the Codex integration off. The marker is the escape hatch —
  # an operator who wants nudges off but the full wait ON drops
  # .claude/pr-grind-codex-expected.local and gets exactly that. Decoupling further
  # would mean detecting on every switched-off repo, which is the network cost the
  # switch exists to avoid.
  CODEX_EXPECTED=$( cd "$WORKTREE_DIR" 2>/dev/null || { echo 0; exit 0; }
    _MR="${BUSDRIVER_MAIN_ROOT:-}"
    if [ -z "$_MR" ]; then
      _G=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
      case "$_G" in /*) _MR="$(dirname "$_G")" ;; esac
    fi
    if [ -n "$_MR" ] && [ -f "${_MR}/.claude/pr-grind-codex-expected.local" ]; then
      echo 1; else echo 0; fi )
  case "$CODEX_EXPECTED" in 1) : ;; *) CODEX_EXPECTED=0 ;; esac
  if [ "${CODEX_GRACE}" -gt 0 ] 2>/dev/null; then
  # `none`-nudge (one-shot per (PR,HEAD)) — ADR 0013 (as revised). Idempotent BACKSTOP:
  # the clean-path hoist in the LOOP (issue #467) already posted this the instant the
  # round converged, so on the normal path the shared one-shot marker makes this call a
  # no-op. It still runs here to (a) cover COMPLETION reached via the ADR 0012 downgrade
  # path (which bypasses the clean-path hoist) and (b) seed the grace re-poll below with
  # a guaranteed-posted nudge. Post `@codex review` AFTER CI has settled (COMPLETION is
  # post-convergence) so we never race normal auto-trigger latency, then let the bounded
  # grace re-poll below observe the result. The wrapper nudges on force-on OR the auto-detect bit, passed
  # POSITIONALLY as $CODEX_REPO_ACTIVE (arg #4) — NOT an env var, which a committed
  # .claude/settings.json env block could inject (#325 / ADR 0016). Absent both it is
  # a no-op (non-gating `none`, exactly as before). Shared one-shot marker → at most
  # one nudge per HEAD across the stale AND none paths. Fall-through on non-engagement
  # is bounded; NEVER a hang. Opt out entirely with PR_GRIND_CODEX_RETRIGGER=0.
  #
  # The subshell `cd`s into $WORKTREE_DIR FIRST (template-substituted Step 0 worktree
  # path; the repo root under --no-worktree), exactly like the LOOP's stale-retrigger
  # call site. Load-bearing (PR #306): (1) the wrapper's force-on opt-in root is
  # CWD-derived, so a drifted COMPLETION CWD ("CWD Reset Across Bash Calls") would read
  # another repo's consent; and (2) the delegated codex-retrigger marker is CWD-relative,
  # so a drift would post a DUPLICATE nudge. `cd || exit 0` aborts on a bad worktree
  # path; the outer `|| true` keeps a failed nudge from ever staling the gate.
  ( cd "$WORKTREE_DIR" || exit 0
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-nudge-if-expected.sh" "$PR" "$HEAD_FULL_SHA" "$OWNER/$REPO" "$CODEX_REPO_ACTIVE" ) || true
  # WAIT SIZING (#420). The 480s deadline is for repos where Codex is genuinely
  # expected — PROVEN-ACTIVE or FORCE-ON. A repo with no Codex at all must NOT
  # start waiting 8 minutes on every merge merely because it read `none`; it keeps
  # the historical short courtesy wait. (Raising the default without this gate
  # would have imposed the full deadline on every Codex-less repo — caught in
  # review.) The NUDGE above is unaffected: the wrapper applies the same
  # force-on/active policy itself and is a no-op absent both.
  CODEX_WAIT="$CODEX_GRACE"
  if [ "$CODEX_REPO_ACTIVE" != "1" ] && [ "$CODEX_EXPECTED" != "1" ]; then
    [ "$CODEX_WAIT" -gt 20 ] && CODEX_WAIT=20
  fi
  # The interval must never exceed the deadline, else the first sleep alone
  # overshoots it (POLL=3600 against a 480s deadline would block for an hour).
  [ "$CODEX_POLL" -gt "$CODEX_WAIT" ] && CODEX_POLL="$CODEX_WAIT"
  echo "ℹ️  Codex shows no engagement on HEAD; polling every ${CODEX_POLL}s up to ${CODEX_WAIT}s for first engagement…"
  # Bounded poll, NOT a blind sleep. Deadline computed ONCE up front so a slow
  # refresh inside the body can never extend the SLEEP budget past CODEX_WAIT, and
  # each sleep is clamped to the REMAINING time so a non-divisible interval cannot
  # overrun it either. Single exit test, at the top.
  #
  # CEILING, stated precisely (do not upgrade this to "never hangs"): CODEX_WAIT
  # bounds the SLEEP budget, not total wall time. The six `gh` fetches per iteration
  # carry no explicit timeout, so a hung request stalls here — exactly as it would at
  # every other unguarded `gh` fetch in COMPLETION (this block adds no new exposure,
  # it just repeats an existing one up to CODEX_WAIT/CODEX_POLL times). The behavioral
  # test covers the sleep arithmetic only; it cannot exercise a hung fetch. If gh
  # hangs become real, wrap these in `timeout`/`gtimeout` here AND at the other
  # COMPLETION fetches — piecemeal is not worth it.
  # ponytail: re-fetches all 6 sources per iteration (worst case 480/30 = 16
  # rounds x 6 calls); only runs on the rare Codex-`none`-but-expected gap, so
  # the simple version wins. Narrow to reactions+reviews inside the loop if the
  # API cost ever shows up.
  CODEX_DEADLINE=$(( $(date +%s) + CODEX_WAIT ))
  # Last verdict computed from a COMPLETE (FETCH_OK=1) snapshot. Seeded from
  # CODEX_REGRACE (== CODEX_DONE == "none", the only value that gets us into this
  # loop). Updated below ONLY when a poll's fetch succeeds, so a fetch failure
  # never overwrites the last trustworthy observation.
  CODEX_LAST_GOOD_VERDICT="$CODEX_REGRACE"
  # ...and the PAYLOADS that verdict was computed from. Restoring the verdict
  # alone is not enough: the three NON-Codex reviewers are recomputed after this
  # loop from these same six variables plus FETCH_OK, so a failed final poll
  # would leave them holding the incomplete snapshot and fail every one of them
  # closed to `stale` — blocking the merge for exactly the transient reason the
  # last-good fallback exists to absorb. CODEX_LG_OK stays 0 until a COMPLETE
  # snapshot is observed; without one there is nothing trustworthy to restore
  # and the deadline branch correctly leaves FETCH_OK=0 (fail-CLOSED).
  CODEX_LG_OK=0
  if [ "$FETCH_OK" = "1" ]; then
    CODEX_LG_OK=1
    CODEX_LG_REACTIONS="$ALL_REACTIONS";   CODEX_LG_REVIEWS="$ALL_REVIEWS"
    CODEX_LG_COMMENTS="$ALL_COMMENTS";     CODEX_LG_CHECK_RUNS="$ALL_CHECK_RUNS"
    CODEX_LG_STATUSES="$ALL_STATUSES";     CODEX_LG_THREADS="$ALL_THREADS"; CODEX_LG_THREADS_FETCHED_AT="$THREADS_FETCHED_AT"
  fi
  while :; do
  _CODEX_REM=$(( CODEX_DEADLINE - $(date +%s) ))
  if [ "$_CODEX_REM" -le 0 ]; then
    echo "ℹ️  Codex did not engage within ${CODEX_WAIT}s; proceeding."
    # Greptile P1: if the LAST poll ended with a fetch error (FETCH_OK=0),
    # CODEX_REGRACE currently holds ack-ledger's fail-closed `stale` fallback for
    # an incomplete snapshot — a transient-error artifact, not a real finding.
    # Deadline exhaustion should fall back to the last COMPLETE observation
    # instead, so a quota-dead/silent Codex plus a transient final fetch failure
    # reads `none` (non-gating) rather than blocking the merge on a snapshot we
    # already know was incomplete.
    # Restore the verdict AND the payloads it came from, then clear FETCH_OK so
    # the post-loop recomputation of the other three reviewers reads a snapshot
    # that is actually complete. Only when a complete snapshot was ever seen
    # (CODEX_LG_OK=1); otherwise leave FETCH_OK=0 and fail CLOSED.
    if [ "$FETCH_OK" != "1" ] && [ "$CODEX_LG_OK" = "1" ]; then
      CODEX_REGRACE="$CODEX_LAST_GOOD_VERDICT"
      ALL_REACTIONS="$CODEX_LG_REACTIONS";   ALL_REVIEWS="$CODEX_LG_REVIEWS"
      ALL_COMMENTS="$CODEX_LG_COMMENTS";     ALL_CHECK_RUNS="$CODEX_LG_CHECK_RUNS"
      ALL_STATUSES="$CODEX_LG_STATUSES";     ALL_THREADS="$CODEX_LG_THREADS"; THREADS_FETCHED_AT="$CODEX_LG_THREADS_FETCHED_AT"
      FETCH_OK=1
      export ALL_REACTIONS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_THREADS THREADS_FETCHED_AT FETCH_OK
    fi
    break
  fi
  if [ "$_CODEX_REM" -lt "$CODEX_POLL" ]; then sleep "$_CODEX_REM"; else sleep "$CODEX_POLL"; fi
  # Fresh FETCH_OK per poll. It is sticky-on-failure by design elsewhere, but across
  # a multi-round wait that would make ONE transient error condemn every later poll,
  # so each iteration is judged on its own snapshot. The value that survives the loop
  # is the LAST poll's, which is what the ledger below is entitled to trust.
  FETCH_OK=1
  # Refresh ALL Codex-relevant sources, not just reactions: during the grace
  # Codex may post FINDINGS (inline threads → Tier A, or a /reviews entry whose
  # commit_id is HEAD → Tier B), not only a clean 👍. Refreshing reactions alone
  # would leave ack-ledger reading the stale pre-sleep threads/reviews and miss
  # findings that arrived in the window — passing the gate with untriaged Codex
  # findings. Tiers C/D/E don't apply to Codex itself, BUT the ADR 0012 downgrade
  # re-validation below reads ALL six sources for the NON-Codex downgraded bots;
  # a registered bot could post a comment/check-run/status during this same sleep,
  # so those three are refreshed too — otherwise the revalidator would scan a
  # pre-sleep snapshot and suppress a bot that re-engaged in the window (fail-open).
  ALL_REACTIONS=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR/reactions" 2>/dev/null) || FETCH_OK=0
  ALL_REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null) || FETCH_OK=0
  ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0
  ALL_STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || FETCH_OK=0
  THREADS_FETCHED_AT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/github-server-now.sh" 2>/dev/null) || THREADS_FETCHED_AT=""
  # shellcheck disable=SC2016  # gh GraphQL needs literal $var refs, not shell expansion
  ALL_THREADS=$(gh api graphql --paginate -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
      repository(owner:$owner,name:$repo) {
        pullRequest(number:$pr) {
          number author{__typename login resourcePath}
          reviewThreads(first:100, after:$endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              isResolved isOutdated
              resolvedBy { login }
              comments(first:1) { nodes { author { login } createdAt } }
              resolutionComments: comments(last:10) { nodes { author { login } createdAt } }
            }
          }
        }
      }
    }
  ' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" 2>/dev/null) || FETCH_OK=0
  # After the THREADS_FETCHED_AT stamp: Tier K reads Kody's unposted-findings
  # comment from this snapshot, so it must be no older than the stamp (#1059).
  ALL_COMMENTS=$(gh pr view "$PR" --json comments 2>/dev/null) || FETCH_OK=0
  export ALL_REACTIONS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_THREADS FETCH_OK
  CODEX_REGRACE=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo stale)
    # Codex engaged → stop polling immediately (a fast Codex costs one interval).
    # Otherwise loop; the top-of-loop deadline test ends it and falls through to
    # the missing-Codex warning + merge (non-gating, exactly as before).
    #
    # FETCH_OK is required: a transient failure in ANY refresh above makes
    # ack-ledger return `stale`, which is `!= none` and would otherwise be read as
    # ENGAGEMENT — exiting the poll on a fetch glitch and blocking completion on a
    # snapshot we know is incomplete, when a later poll would likely have recovered.
    # Only a verdict from a COMPLETE snapshot may end the wait. (FETCH_OK is reset
    # per-iteration at the top of the loop, so one bad poll does not poison the rest.)
    # Record this poll's verdict as the last-good observation whenever its fetch
    # was complete — including a complete "none" (Codex still hasn't engaged) —
    # so the deadline-exit fallback above always has the most recent trustworthy
    # value, not just the pre-loop seed.
    if [ "$FETCH_OK" = "1" ]; then
      CODEX_LAST_GOOD_VERDICT="$CODEX_REGRACE"
      CODEX_LG_OK=1
      CODEX_LG_REACTIONS="$ALL_REACTIONS";   CODEX_LG_REVIEWS="$ALL_REVIEWS"
      CODEX_LG_COMMENTS="$ALL_COMMENTS";     CODEX_LG_CHECK_RUNS="$ALL_CHECK_RUNS"
      CODEX_LG_STATUSES="$ALL_STATUSES";     CODEX_LG_THREADS="$ALL_THREADS"; CODEX_LG_THREADS_FETCHED_AT="$THREADS_FETCHED_AT"
    fi
    [ "$CODEX_REGRACE" != "none" ] && [ "$FETCH_OK" = "1" ] && break
  done
  # Re-apply the Tier-D content-identity widening ONCE, here — not per interval.
  # The refreshes above REPLACED ALL_CHECK_RUNS with the raw HEAD-scoped payload,
  # discarding the augmentation augment-equiv-acks.sh added before the ledger ran;
  # without re-sourcing, a valid metadata-only force-push loses its carried-forward
  # Tier-D acks and the recomputation below turns them `stale`, blocking a merge
  # that should pass. It belongs outside the loop because the in-loop verdict
  # classifies ONLY Codex, which has no Tier D — running it per interval would add
  # a repo view, a timeline GraphQL call and possible fetches to all 16 rounds for
  # a value nothing in the loop reads. The full ledger below is its only consumer.
  # shellcheck source=scripts/augment-equiv-acks.sh disable=SC1091
  [ -f "$AUGMENT_SCRIPT" ] && . "$AUGMENT_SCRIPT"
  export ALL_CHECK_RUNS FETCH_OK
  # Recompute the ENTIRE ledger on the post-wait sources — not just Codex.
  # The loop refreshes all six payloads, but the old code re-folded ONLY the Codex
  # entry, leaving the three registered bots at their pre-wait values. Over the old
  # 20s sleep that gap was narrow; at a 480s deadline it is wide enough for a bot to
  # post CHANGES_REQUESTED (or a finding with no inline thread) during the window
  # while FRESH_ACKS still carries its stale-but-passing SHA — authorizing the merge
  # on data known to be out of date. Recomputing all six closes it: any bot that
  # re-engaged now reads `stale` and blocks below, exactly as on the normal path.
  # Same fail-CLOSED `|| echo stale` as the original computation.
  # Normalize the Codex verdict before it is folded in. CODEX_REGRACE is already
  # seeded from CODEX_DONE above, so it cannot currently be empty — this is
  # belt-and-braces against a future edit that moves or drops that seed: an EMPTY
  # value would render as `chatgpt-codex-connector=` and match neither the `none`
  # nor the `stale` check, slipping through as an unclassified ack. Anything not a
  # recognized verdict becomes `stale` (fail-CLOSED, blocks).
  # This normalization is Codex-only. kody-ai is validated by the STALE_BOTS
  # allow-list below (it may also read the ADR 0064 waiver token
  # `skipped-unlicensed`); routing it through this `case` would turn the waiver
  # into `stale`. For Codex, ack-ledger.sh's contract is exactly three outputs:
  # `none`, `stale`, or the CURRENT $HEAD_SHA. Match that contract literally —
  # anything else (empty, an error string, a stray hex value, a SHA that is not this HEAD) becomes `stale`
  # and blocks, because the gate below blocks only on the literal `stale`.
  # Two wrong ways to write this, both tried and rejected in review:
  #   - a `?*` arm, or any "looks like hex" test, accepts arbitrary output → fail-OPEN;
  #   - a 40-char length test rejects every REAL ack (HEAD_SHA is
  #     `git rev-parse HEAD | cut -c1-8`, 8 chars) → blocks every Codex merge.
  # Equality with $HEAD_SHA is both, correctly: nothing else can pass.
  case "$CODEX_REGRACE" in
    none | stale | "$HEAD_SHA") : ;;
    *) CODEX_REGRACE=stale ;;
  esac
  FRESH_ACKS="kody-ai=$(bash "$ACK_SCRIPT" kody-ai 2>/dev/null || echo stale),chatgpt-codex-connector=${CODEX_REGRACE}"
  # HEAD-MOVED GUARD (fail-CLOSED). Everything above classifies acks against
  # HEAD_SHA captured BEFORE the wait, but the later `gh pr merge` targets whatever
  # the PR points at NOW. A push landing during the window would therefore carry
  # the old commit's acks onto a new, unreviewed head. The old 20s sleep made that
  # a narrow race; a 480s deadline makes it reachable, so this change owns it.
  # On ANY divergence — or an unresolvable/failed lookup — mark every ack `stale`
  # so the existing stale-ack check blocks the merge and the loop re-converges on
  # the new HEAD. Never proceeds on doubt.
  #
  # RESIDUAL, stated honestly (issue #427): this NARROWS the race, it does not
  # close it. The check is non-atomic — a push can still land after this lookup
  # returns and before the merge executes, and no amount of re-checking here fixes
  # that. The real closure is server-side, passing the reviewed SHA to the merge's
  # `--match-head-commit`, which makes GitHub itself refuse a moved head. That
  # touches the merge invocations in several blocks and is tracked separately in
  # #427; do NOT read this guard as making the merge atomic.
  CODEX_HEAD_NOW=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
  if [ -z "$CODEX_HEAD_NOW" ] || [ "$CODEX_HEAD_NOW" != "$HEAD_FULL_SHA" ]; then
    _CODEX_HEAD_DISPLAY="${CODEX_HEAD_NOW:0:8}"
    [ -z "$CODEX_HEAD_NOW" ] && _CODEX_HEAD_DISPLAY="<lookup failed>"
    echo "⚠️  HEAD moved during the Codex wait (was ${HEAD_FULL_SHA:0:8}, now ${_CODEX_HEAD_DISPLAY}) — invalidating acks; the loop must re-converge on the new HEAD."
    FRESH_ACKS="kody-ai=stale,chatgpt-codex-connector=stale"
  fi
  fi
  # Missing-Codex warning (#320 secondary ask): Codex is HISTORICALLY active here but
  # still `none` at merge. Gated on CODEX_REPO_ACTIVE (already forced to 0 by the kill
  # switch), so the "engaged on recent PRs" claim is true and a force-on cold-start
  # repo with NO history gets no warning. "engaged" (not "reviewed") — a clean Codex
  # leaves only a Tier-F reaction, no review. Non-gating: surface the gap, then merge.
  if [ "$CODEX_REGRACE" = "none" ] && [ "$CODEX_REPO_ACTIVE" = "1" ]; then
    echo "⚠️  Codex (chatgpt-codex-connector) has engaged on recent PRs of this repo (review and/or reaction) but did not engage on this PR — merging without a Codex review (the nudge may have been skipped, disabled, or failed)."
  fi
fi
# ADR 0012 (litmus HIGH fix): a login in DOWNGRADED_BOTS was released at
# --max-wait exhaustion, but it can RE-ENGAGE between that decision and this
# merge — a new unresolved thread, a CHANGES_REQUESTED review, or (Codex) a
# current 👀 reaction. FRESH_ACKS above would then correctly read `stale`;
# blindly suppressing every DOWNGRADED_BOTS login would defeat this
# defense-in-depth re-query and merge past a live review. Re-VALIDATE each
# downgraded login against the FRESH sources just fetched, re-running the SAME
# advisory-stale-downgrade.sh predicate (scripts/advisory-downgrade-revalidate.sh).
# Only logins that STILL pass on fresh data are suppressed; a re-engaged bot
# fails the fresh predicate, drops out of REVALIDATED_DOWNGRADE, stays in
# STALE_BOTS, and blocks. Fail-CLOSED: on any error — or FETCH_OK≠1, meaning a
# fresh source failed to fetch so re-engagement can't be proven — the script
# echoes empty → nothing suppressed → the merge blocks on the still-`stale` acks.
REVALIDATED_DOWNGRADE=""
if [ -n "$DOWNGRADED_BOTS" ]; then
  # Resolve the MAIN repo root for the audit log — NOT `git rev-parse --show-toplevel`.
  # In default (worktree) mode --show-toplevel is the ephemeral worktree, but the
  # exhaustion path writes bypass-log.jsonl to the MAIN repo's .claude/ (state .local
  # files are not copied into worktrees). `--git-common-dir`'s parent is the main repo
  # root in BOTH worktree and --no-worktree modes — the same resolver the opt-in/audit
  # write uses. Fail-CLOSED: if it can't resolve to an absolute path, BYPASS_LOG points
  # at a nonexistent file → the revalidator reads a missing log → suppresses nothing →
  # downgraded bots stay `stale` and block (never a fail-open).
  _MAIN_ROOT=""
  _GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$_GCD" in /*) _MAIN_ROOT=$(dirname "$_GCD") ;; esac
  # Pass the FULL 40-char sha, not the 8-char $HEAD_SHA (#682). This is the join
  # key against the logged downgrade event, and the revalidator compares over the
  # shorter of the two sides: full-vs-full is an exact 40-char match, while the
  # 8-char form would cap every comparison at a prefix even when the event carries
  # the full sha. Short still joins (that is what #682 fixed) — this just stops
  # COMPLETION from being the side that throws the precision away.
  REVALIDATED_DOWNGRADE=$(DOWNGRADED_BOTS="$DOWNGRADED_BOTS" FETCH_OK="$FETCH_OK" \
    ALL_THREADS="$ALL_THREADS" ALL_REVIEWS="$ALL_REVIEWS" ALL_REACTIONS="$ALL_REACTIONS" \
    ALL_COMMENTS="$ALL_COMMENTS" ALL_CHECK_RUNS="$ALL_CHECK_RUNS" ALL_STATUSES="$ALL_STATUSES" \
    HEAD_SHA="$HEAD_FULL_SHA" \
    BYPASS_LOG="${_MAIN_ROOT}/${BUSDRIVER_STATE_DIR:-.claude}/bypass-log.jsonl" \
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/advisory-downgrade-revalidate.sh" || echo "")
  # stderr is deliberately NOT discarded (#682). `$( )` captures stdout only, so the
  # revalidator's per-bot drop reasons print for the operator without contaminating
  # REVALIDATED_DOWNGRADE. Every refusal path here is otherwise silent — an empty
  # result reads identically whether the bot re-engaged, the audit log was missing,
  # or the head_sha never joined. #682 was exactly that: a form mismatch presented as
  # "the bot must have re-engaged" and cost a live diagnosis to tell apart.
  if [ "$REVALIDATED_DOWNGRADE" != "$DOWNGRADED_BOTS" ]; then
    echo "⚠️  ADR 0012: a downgraded bot re-engaged before merge — only re-validated release(s) suppressed: '${REVALIDATED_DOWNGRADE:-<none>}' (was '$DOWNGRADED_BOTS'). Re-engaged bot(s) stay stale and block."
  fi
fi
# kody-ai is an exact allow-list: the current HEAD_SHA (a Tier K ack) or the
# ADR 0064 waiver token `skipped-unlicensed` (a waiver, not an ack). Anything
# else — stale, none, empty, a stray SHA, an extra `=` field — blocks, and a
# downgrade never releases it. Two fields and string compares only ("x" $2), so
# awk's numeric coercion cannot equate `012345678` with `12345678`.
STALE_BOTS=$(echo "$FRESH_ACKS" | tr ',' '\n' | awk -F= -v downgraded="$REVALIDATED_DOWNGRADE" -v head="$HEAD_SHA" '
  BEGIN { n = split(downgraded, arr, ","); for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1 }
  $1 == "kody-ai" {
    ok = (NF == 2 && ((head != "" && ("x" $2) == ("x" head)) || ("x" $2) == "xskipped-unlicensed"))
    if (!ok) print $1
    next
  }
  $2 == "stale" && !($1 in skip) { print $1 }
')
if [ -n "$STALE_BOTS" ]; then
  echo "❌ BLOCKED: AI reviewer(s) with stale ack at merge time: $STALE_BOTS"
  echo "   Re-run the loop or wait for the bot(s) to ack HEAD ($HEAD_SHA)."
  echo "   (chatgpt-codex-connector stale = Codex still reviewing / no 👍 newer than HEAD.)"
  exit 1
fi
# Surface the release to the operator (never silent — see ADR 0012). This is
# forensic visibility only; it does NOT get written into the bare-PR-number
# clean marker (see the marker note in "All of these must be true" above).
if [ -n "$DOWNGRADED_BOTS" ]; then
  echo "ℹ️  ADR 0012: advisory-bot stale ack(s) timeout-downgraded to none for this merge: $DOWNGRADED_BOTS"
  echo "   (logged to bypass-log.jsonl — see docs/adr/0012-advisory-bot-stale-timeout-downgrade.md)"
fi
# ADR 0064: a skipped-unlicensed Kody run is not a review. This fence decides
# nothing more; the waiver step below grants it only for a documentation-only PR.
case ",$FRESH_ACKS," in
  *,kody-ai=skipped-unlicensed,*)
    echo "ADR 0064: kody-ai skipped for licensing; run the waiver step before any clean marker." ;;
esac
# The SHA every ack above was classified against: the dispatcher carries this line forward
# as REVIEWED_HEAD (--match-head-commit and the clean marker), never re-deriving it.
echo "HEAD_FULL_SHA=$HEAD_FULL_SHA"
