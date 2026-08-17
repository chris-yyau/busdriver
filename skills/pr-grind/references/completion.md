<!-- Extracted verbatim from SKILL.md. Read this file when the dispatcher loop
     exits with RESULT_STATUS=clean, or via the ADR 0012 max-wait downgrade
     path. It is the tail of SKILL.md and MUST be concatenated after it when
     asserting on document order (see tests/test-pr-grind-codex-wiring.sh). -->

## Completion (post-loop, dispatcher only)

**All of these must be true before declaring done:**
1. Subagent returned `RESULT_STATUS=clean`
2. All required CI checks passing (build, lint, test)
3. All automated reviewers completed (CodeRabbit, Cubic, Greptile, etc.). Codex (`chatgpt-codex-connector`) has no GitHub check, but it IS waited on via `ack-ledger.sh` Tiers F and G: its 👍 reaction or its clean-verdict comment naming HEAD (#690) — clean — or findings on HEAD (Tiers A/B) must ack the current HEAD, surfaced as `RESULT_CODEX_ACK` and re-checked in the COMPLETION gate's `FRESH_ACKS` scan. A `stale` Codex blocks completion just like a stale registered bot; its findings are additionally triaged via Step 2.6 enumeration.
4. No unresolved actionable comments from any source
5. No new comments arrived after your last push (wait for the full cycle)
6. Advisory check issues either fixed or noted as beyond PR scope
7. **Reviewer ack ledger**: every registered bot (Cubic, CodeRabbit, Greptile) is either `<HEAD-short-SHA>` or `none` in `RESULT_REVIEWER_ACKS`. Any `stale` entry blocks completion — the bot finished its check but hasn't re-reviewed HEAD yet, and merging now would race ahead of its findings. (`none` here can mean "bot doesn't operate on this repo" OR "bot's only reviews are infra-error/rate-limit markers that cannot self-recover" OR "bot only posted a non-actionable PR-overview summary on an older commit" OR "bot acknowledged HEAD via a check-run with conclusion=skipped and non-actionable body (e.g., cubic-dev-ai on merge commits)" — all four cases are non-gating; see `scripts/ack-ledger.sh`'s downgrade Cases 1, 2, and 3. Note: Tier E (commit-statuses API) does NOT produce `none` — a `success` status returns HEAD-ack, and a `pending`/`failure`/`error` status returns `stale` to block on the live reviewer signal.) Codex is gated too, but tracked in its own `RESULT_CODEX_ACK` field (Tier F 👍 reaction), not in `RESULT_REVIEWER_ACKS` — a `stale` Codex blocks completion identically; `none` (never reacted/reviewed on this PR) is non-gating.

**Re-query the ack ledger fresh (REQUIRED — defense in depth against late posts between subagent return and merge time):**

The dispatcher must re-run the same `scripts/ack-ledger.sh` lookup the worker used in Step 6.5, against all live ack-ledger sources (review threads, `/reviews`, issue comments, check-runs, and commit statuses), with HEAD recomputed against the current branch state. Just re-parsing `$RESULT_REVIEWER_ACKS` would only validate the worker's snapshot — it can't catch a bot that finished re-reviewing in the seconds between subagent return and merge.

The `<PR_NUMBER>`, `<owner>`, `<repo>` placeholders below follow the same template-substitution convention as `<PR_NUMBER>` elsewhere in this Completion section — Claude substitutes the literal owner / repo / PR-number values at run time before executing the bash. `<DOWNGRADED_BOTS>` follows the same convention: if COMPLETION was reached via the ADR 0012 wait-round downgrade path (ON_LOOP_EXHAUSTED step 5), Claude substitutes the comma-separated released-login list computed there; on the normal `RESULT_STATUS=clean` path (no downgrade involved) it substitutes the empty string.

```bash
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
# ADR 0012: comma-separated logins released by the bounded stale-ack downgrade
# (empty on the normal clean path — see the template-substitution note above).
DOWNGRADED_BOTS="<DOWNGRADED_BOTS>"
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# One-shot fetches — same four sources as worker's Step 6.5.
# FETCH_OK tracks failure; fail-CLOSED to `stale` on any source failure.
FETCH_OK=1
ALL_THREADS=$(gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
    repository(owner:$owner,name:$repo) {
      pullRequest(number:$pr) {
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
ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
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
# --paginate + slurp (jq -rs) so the PushEvent for HEAD is found even when it lands
# on a later events page; without pagination a HEAD push beyond the first page yields
# empty. Best-effort; exports empty on failure or no match, in which case Tier F fails
# CLOSED to stale (no committer fallback — the committer date is backdatable, #189).
# HEAD_COMMITTED_DATE is fetched best-effort and NOT gated on FETCH_OK (nothing reads it).
HEAD_FULL_SHA=$(git rev-parse HEAD)
# Branch filter prevents anchoring on a PushEvent from a different branch that
# shares the same tip SHA. fetch-pr-state.sh uses the same guard; keep in sync.
PR_BRANCH=$(gh pr view "$PR" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
_ref="refs/heads/${PR_BRANCH:-}"
HEAD_PUSH_DATE=$(gh api --paginate "repos/$OWNER/$REPO/events?per_page=100" 2>/dev/null \
  | jq -rs --arg head "$HEAD_FULL_SHA" --arg ref "$_ref" \
    '[.[]? | .[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty' 2>/dev/null || echo "")
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
if [ -z "$HEAD_PUSH_DATE" ] && [ -n "${PR_BRANCH:-}" ] && [ -n "${HEAD_FULL_SHA:-}" ]; then
  HEAD_CHECKS_DATE=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_FULL_SHA/check-suites" 2>/dev/null \
    | jq -rs --arg sha "$HEAD_FULL_SHA" \
      '[.[].check_suites[]? | select(.head_sha==$sha) | .created_at] | map(select(. != null and . != "")) | sort | .[0] // empty' 2>/dev/null || echo "")
fi

# Per-bot ack — same single-sourced algorithm as the worker's Step 6.5 in
# agents/pr-grinder.md. Both sites invoke scripts/ack-ledger.sh; algorithm
# edits live in that one file.
# Tier D carry-forward across message-only force-pushes: widen the HEAD-scoped
# check-runs with any content-identical predecessor's check-runs before the ledger
# runs (additive, best-effort, git-proven; no-op under ACK_CONTENT_IDENTITY=0; Tier E
# statuses are NOT widened). Keep in sync with scripts/fetch-pr-state.sh,
# agents/pr-grinder.md, and the worker mirror above.
PR_NUMBER="$PR"; AUGMENT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/augment-equiv-acks.sh"
[ -f "$AUGMENT_SCRIPT" ] && . "$AUGMENT_SCRIPT"
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA HEAD_FULL_SHA
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
# Codex (chatgpt-codex-connector) is appended as a fourth gated reviewer here:
# its Tier-F 👍 reaction is the authoritative clean signal, and a `stale` value
# (still reviewing, or hasn't re-acked HEAD after the last push) must block the
# merge exactly like a stale registered bot. It is NOT in RESULT_REVIEWER_ACKS
# (the three SHA-keyed bots feeding Invariant 3) — only in this final gate scan.
FRESH_ACKS="cubic-dev-ai=$(bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null || echo stale),coderabbitai=$(bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo stale),greptile-apps=$(bash "$ACK_SCRIPT" greptile-apps 2>/dev/null || echo stale),chatgpt-codex-connector=$(bash "$ACK_SCRIPT" chatgpt-codex-connector 2>/dev/null || echo stale)"
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
    CODEX_LG_STATUSES="$ALL_STATUSES";     CODEX_LG_THREADS="$ALL_THREADS"
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
      ALL_STATUSES="$CODEX_LG_STATUSES";     ALL_THREADS="$CODEX_LG_THREADS"
      FETCH_OK=1
      export ALL_REACTIONS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_THREADS FETCH_OK
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
  ALL_COMMENTS=$(gh pr view "$PR" --comments --json comments 2>/dev/null) || FETCH_OK=0
  ALL_CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" 2>/dev/null) || FETCH_OK=0
  ALL_STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null) || FETCH_OK=0
  ALL_THREADS=$(gh api graphql --paginate -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String) {
      repository(owner:$owner,name:$repo) {
        pullRequest(number:$pr) {
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
      CODEX_LG_STATUSES="$ALL_STATUSES";     CODEX_LG_THREADS="$ALL_THREADS"
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
  # ack-ledger.sh's contract is exactly three outputs: `none`, `stale`, or the
  # CURRENT $HEAD_SHA. Match that contract literally — anything else (empty, an
  # error string, a stray hex value, a SHA that is not this HEAD) becomes `stale`
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
  FRESH_ACKS="cubic-dev-ai=$(bash "$ACK_SCRIPT" cubic-dev-ai 2>/dev/null || echo stale),coderabbitai=$(bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo stale),greptile-apps=$(bash "$ACK_SCRIPT" greptile-apps 2>/dev/null || echo stale),chatgpt-codex-connector=${CODEX_REGRACE}"
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
    FRESH_ACKS="cubic-dev-ai=stale,coderabbitai=stale,greptile-apps=stale,chatgpt-codex-connector=stale"
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
STALE_BOTS=$(echo "$FRESH_ACKS" | tr ',' '\n' | awk -F= -v downgraded="$REVALIDATED_DOWNGRADE" '
  BEGIN { n = split(downgraded, arr, ","); for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1 }
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
```

**Verify checks are green (REQUIRED — do NOT skip, even if subagent said clean):**
```bash
GH_EXIT=0
CHECKS_RAW=$(gh pr checks <PR_NUMBER> 2>&1) || GH_EXIT=$?
# A genuine `gh pr checks` row carries a KNOWN status token (pass/fail/pending/...)
# as its OWN tab-separated column, never as a loose substring. A CLI error line
# like "failed to connect to api.github.com" contains "fail" but is not a status
# column — a plain `grep -qE "pass|fail|pending"` misclassifies that error text
# as valid check output (Codex finding on #522), masking a real `gh` failure.
if [ "$GH_EXIT" -ne 0 ] && ! printf '%s\n' "$CHECKS_RAW" | awk -F'\t' 'NF>=2 { s=tolower($2); gsub(/^[ \t]+|[ \t]+$/,"",s); if (s ~ /^(pass|fail|failure|pending|queued|in_progress|expected|cancel|cancelled|skipping|neutral)$/) f=1 } END{exit !f}'; then
  echo "❌ gh pr checks failed (exit $GH_EXIT). Resolve CLI/auth issues."
  exit 1
fi
# Lock-aware filter — scripts/relevant-check-status.sh (issue #154). Pass the
# repo-ROOT DIR (reads .github/required-checks.lock), NOT the repo name.
# Fail-CLOSED: any error → conservative blocking "1 0 all 0".
REPO_DIR=$(git rev-parse --show-toplevel)
COUNTS=$(printf '%s\n' "$CHECKS_RAW" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/relevant-check-status.sh" "$REPO_DIR" 2>/dev/null || printf '1 0 all 0\n')
read -r FAILED PENDING MODE KEPT <<<"$COUNTS"
# Guards (mirror the gate): empty/garbled output → blocking; and green requires
# no failures AND nothing pending AND at least one relevant check ran. KEPT=0 in
# required mode means a required check never posted (no evidence) — the gate's
# KEPT>0 bootstrap guard refuses that, so the clean marker must too.
if [ -z "${MODE:-}" ] || [ -z "${FAILED:-}" ] || [ -z "${KEPT:-}" ]; then FAILED=1; fi
if [ "${FAILED:-1}" -gt 0 ] || [ "${PENDING:-1}" -gt 0 ] || [ "${KEPT:-0}" -eq 0 ]; then
  echo "❌ BLOCKED: cannot declare PR clean (failed=${FAILED} pending=${PENDING} kept=${KEPT} mode=${MODE})."
  printf '%s\n' "$COUNTS" | tail -n +2
  exit 1
fi
```

<EXTREMELY-IMPORTANT>
**CRITICAL: the marker write and `gh pr merge` MUST be TWO SEPARATE Bash tool calls.** Not chained with `&&`/`;`/`|`, not a heredoc that runs both, not a single multi-line command, not a single Bash call that just happens to contain both lines. Two distinct tool calls — first call writes the marker and exits; second call invokes `gh pr merge`. This applies identically to the default-merge block AND the `--admin-on-approver-gap` auto-admin-merge block below — both consume the same marker; the gate fires on both invocation paths.

**Why a single call deadlocks.** `hooks/gate-scripts/pre-merge-gate.sh` is a PreToolUse hook — it fires BEFORE the bash command executes, scans the command argv string for `gh pr merge`, and reads `.claude/pr-grind-clean.local` from disk at that moment. If the marker `echo` lives in the same tool call, the hook samples the filesystem *before* the echo runs, finds no marker, and blocks the entire tool call — NONE of the bash executes, the marker is never written, and the operator sees a misleading "pr-grind has not declared this PR clean" error after pr-grind just finished successfully. This is a TOCTOU between the hook's filesystem read at tool-invocation time and the marker write at bash-execution time inside the same tool call. Splitting into two tool calls separates the two events: the first tool call completes (marker on disk, hook didn't fire), then the hook fires on the second call's `gh pr merge` and sees the marker the first call left behind.

**Confirmed recurrences:** PR #93 (2026-05-12) — the deadlock the PR-#94 callout was first written for. PR #95 (2026-05-13) — recurred *despite* the prior callout because the previous prose was easy to skim past on a top-down read. The "CRITICAL" headline above is the current attempt to make the contract unmissable; do not soften it back into a paragraph.

**The contract:** marker write completes → next Bash call runs the merge. Do NOT inline-combine, even if the chain "looks natural" while you're reading this section.
</EXTREMELY-IMPORTANT>

**Write the pr-grind-clean marker (REQUIRED). Run this as its own Bash tool call. ⚠ Unlike most other blocks in this completion specification, do NOT `cd "$WORKTREE_DIR"` first — run it at the AMBIENT session cwd.**

The pre-merge gate anchors its marker lookup (`REPO_DIR`) on the hook's `cwd` — the Claude **session's launch dir** — refining to a `cd` target only for a statically-parseable single-line `cd <path> && …` merge form (`hooks/gate-scripts/lib/resolve-repo-dir.sh`). The default merge below is a **bare** `gh pr merge`, so the gate anchors on the **session cwd**. That is exactly the directory the Bash tool lands in when a block does **not** `cd` (the "CWD Reset Across Bash Calls" invariant) — so `git rev-parse --show-toplevel` at the ambient cwd resolves to the very repo root the gate will read. This is the whole fix: writing the marker to any *other* root (the grind worktree, or the main-repo root) is what lets the two diverge. The bug it closes: if this block first `cd`s into a checkout that is NOT the session cwd — e.g. the grind resolved `WORKTREE_DIR` to a linked sibling worktree while you invoked `/pr-grind <PR>` from the main checkout — the marker lands in the worktree while the gate still reads the session cwd, and the merge blocks with "pr-grind has not declared this PR clean" right after a clean grind.
```bash
# NO `cd` above this line — the ambient cwd must stay the session cwd (= gate anchor).
REPO_ROOT=$(git rev-parse --show-toplevel)
mkdir -p "$REPO_ROOT/.claude"
# The marker asserts "<PR> AT THIS COMMIT is clean" — the SHA is load-bearing,
# not decoration (#505). It MUST be REVIEWED_HEAD (the same value already
# substituted into `--match-head-commit` below, #427): the commit the ack ledger
# actually classified against. Do NOT re-query `gh pr view --json headRefOid`
# here — that re-derives HEAD at marker-write time, so a push landing between
# classification and this line would stamp a NEW, UNREVIEWED commit as clean and
# the gate would then faithfully authorize it. Re-deriving launders exactly the
# commit #505 exists to catch. (`git rev-parse HEAD` is wrong for a second
# reason: this block runs at the ambient session cwd, routinely on another branch.)
REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
if [ "${#REVIEWED_HEAD}" -ne 40 ]; then
  echo "ABORT: REVIEWED_HEAD is not a full 40-char SHA — marker NOT written. Do not merge; re-run /pr-grind." >&2
  exit 1
fi
printf '%s %s\n' "<PR_NUMBER>" "$REVIEWED_HEAD" > "$REPO_ROOT/.claude/pr-grind-clean.local"
rm -f "$REPO_ROOT/.claude/pr-pending-grind.local"
```

**Branch-Currency Detection (run BEFORE approver-gap):**

After CI is green and bots ack HEAD, GitHub may still reject the merge because branch protection requires the head branch to be up-to-date with the base. This is a different structural gap from approver-count: it surfaces as `mergeStateStatus=BEHIND` and the raw failure is `Pull request is not mergeable: the head branch is not up to date with the base branch`. Detect it up front so the operator sees a tailored decision message instead of a raw `gh pr merge` failure.

**The detection is scoped narrowly:** only `mergeStateStatus=BEHIND` qualifies. Other mergeStateStatus values (`BLOCKED`, `DIRTY`, `UNSTABLE`, `UNKNOWN`) surface via their existing paths (approver-gap detection, failing-required-checks, merge-conflict, etc.). Branch-currency is the specific case where the PR is functionally ready BUT lags behind base; the fix is "incorporate base into the PR branch," which has three legitimate paths.

```bash
PR=<PR_NUMBER>
MERGE_STATE_STATUS=$(gh pr view "$PR" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo "")
case "$MERGE_STATE_STATUS" in
  BEHIND)
    # Surface decision with three operator options below; do NOT auto-pick.
    # Excluded from MAX_FIX/MAX_WAIT accounting — nothing to fix, nothing to wait for.
    # pr-grind BAILs with RESULT_BAIL_CATEGORY=policy (same enum as approver-gap;
    # `policy` covers all dispatcher-emitted structural-blocker bails).
    ;;
  CLEAN|UNSTABLE|HAS_HOOKS|"")
    # Pass through — proceed to Approver-Gap Detection below.
    # UNSTABLE = advisory check failing (e.g., CodeScene); not branch-currency.
    # Empty (mergeStateStatus query failed) = degrade-to-attempt; the merge
    # will surface its own error if base-currency is actually the blocker.
    ;;
  *)
    # BLOCKED / DIRTY / etc. — surface via existing approver-gap or
    # failing-checks paths. Do not BAIL here; let the downstream
    # detection blocks handle their specific cases.
    ;;
esac
echo "MERGE_STATE_STATUS=$MERGE_STATE_STATUS"
```

**Decision tree** (based on `MERGE_STATE_STATUS`):

- **`CLEAN` / `UNSTABLE` / `HAS_HOOKS` / empty** → fall through to Approver-Gap Detection below.
- **`BEHIND`** → BAIL with `RESULT_BAIL_CATEGORY=policy` and surface the operator-decision message (template below). Excluded from MAX_FIX/MAX_WAIT accounting — nothing to fix, nothing to wait for.
- **`BLOCKED` / `DIRTY` / other** → fall through; handled by approver-gap or failing-checks paths.

**Operator-decision message template** (rendered to stdout on BAIL when `MERGE_STATE_STATUS=BEHIND`). Two variants keyed on `AUDIT_WORKFLOW_PRESENT` — same conditional framing as the approver-gap path:

**When `AUDIT_WORKFLOW_PRESENT=1`:**

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but base branch (<base>) has advanced since the PR branched. Branch protection
requires the head branch to be up-to-date with the base before merge.

Options:
  [update-merge]  gh pr update-branch <PR_NUMBER>
                    # creates a merge commit bringing base into the PR branch.
                    # No force-push, so no SHA is *rewritten* — but HEAD MOVES
                    # to the merge commit, so every HEAD-pinned ack strands on
                    # the parent until its bot re-reviews the new HEAD. Triggers
                    # a CI re-run + bot re-review; plan for 1-2 additional
                    # wait-rounds. Cleanest correctness path when bots re-review
                    # merge commits.
                    # Merge-commit-skipping bots: cubic-dev-ai skips reviewing
                    # merge commits (check-run conclusion=skipped) and Ack-ledger
                    # Case 3 maps that to `none`, so [update-merge] converges
                    # (cubic shows `none`, not HEAD-acked, in the final ledger).
                    # cursor (Bugbot) and devin-ai-integration were DROPPED from
                    # the ack registry (ADR 0035) — both were review-once-at-create
                    # bots whose stranded clean reviews previously needed the
                    # Case-4 devin whitelist (ADR 0027, now removed); they no
                    # longer gate the ledger. For any registered bot lacking a
                    # Case-3 downgrade that strands stale, the ADR 0012 opt-in
                    # `.claude/pr-grind-advisory-downgrade.local` makes the stranded
                    # ack ELIGIBLE for a stale→none downgrade at --max-wait
                    # exhaustion, and only when every ADR 0012 fail-closed
                    # precondition holds (CI + litmus green; the bot enumerated a
                    # body with 0 findings — a 0/0:none bot is refused; no
                    # re-engagement) — NOT a guarantee. If correctly refused, that
                    # path still dead-ends in a manual skip-pr-grind.local.
                    # If a positive cubic HEAD-ack matters (e.g., for audit), use
                    # [update-rebase] instead — it forces a fresh review at the
                    # cost of 3-5 wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                    # head guard (#427). <REVIEWED_HEAD> is substituted by the
                    # dispatcher — same convention as <PR_NUMBER> — with the
                    # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                    # that re-derives at merge time and blesses a post-
                    # classification commit, defeating the guard.
                    # admin-merge bypasses the up-to-date requirement.
                    # Defensible when the PR is small + conflict-free and
                    # the base advance was unrelated. Runs outside pr-grind
                    # and writes NO entry to .claude/bypass-log.jsonl. Same
                    # audit posture as the approver-gap [admin] command path.
                    # verify: gh pr view <PR_NUMBER> --json state -q .state
                    # (retry up to 3x with 2s backoff — `gh pr merge
                    #  --delete-branch` can exit non-zero on a worktree-
                    #  checkout conflict even after the remote merge succeeded;
                    #  trust the API state, not the merge exit code)
  [wait]          exit; manually update later
```

**When `AUDIT_WORKFLOW_PRESENT=0`**, demote `[admin]` to last position and prepend a no-audit-trail warning (consistent with the approver-gap path):

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but base branch (<base>) has advanced since the PR branched. Branch protection
requires the head branch to be up-to-date with the base before merge.
⚠️  This repo has NO bypass-audit.yml — an admin-merge here would leave NO
audit trail. Strongly consider [update-merge] or [update-rebase].

Options:
  [update-merge]  gh pr update-branch <PR_NUMBER>
                    # creates a merge commit bringing base into the PR branch.
                    # No force-push, so no SHA is *rewritten* — but HEAD MOVES
                    # to the merge commit, so every HEAD-pinned ack strands on
                    # the parent until its bot re-reviews the new HEAD. Triggers
                    # a CI re-run + bot re-review; plan for 1-2 additional
                    # wait-rounds. Cleanest correctness path when bots re-review
                    # merge commits.
                    # Merge-commit-skipping bots: cubic-dev-ai skips reviewing
                    # merge commits (check-run conclusion=skipped) and Ack-ledger
                    # Case 3 maps that to `none`, so [update-merge] converges
                    # (cubic shows `none`, not HEAD-acked, in the final ledger).
                    # cursor (Bugbot) and devin-ai-integration were DROPPED from
                    # the ack registry (ADR 0035) — both were review-once-at-create
                    # bots whose stranded clean reviews previously needed the
                    # Case-4 devin whitelist (ADR 0027, now removed); they no
                    # longer gate the ledger. For any registered bot lacking a
                    # Case-3 downgrade that strands stale, the ADR 0012 opt-in
                    # `.claude/pr-grind-advisory-downgrade.local` makes the stranded
                    # ack ELIGIBLE for a stale→none downgrade at --max-wait
                    # exhaustion, and only when every ADR 0012 fail-closed
                    # precondition holds (CI + litmus green; the bot enumerated a
                    # body with 0 findings — a 0/0:none bot is refused; no
                    # re-engagement) — NOT a guarantee. If correctly refused, that
                    # path still dead-ends in a manual skip-pr-grind.local.
                    # If a positive cubic HEAD-ack matters (e.g., for audit), use
                    # [update-rebase] instead — it forces a fresh review at the
                    # cost of 3-5 wait-rounds.
  [update-rebase] gh pr update-branch <PR_NUMBER> --rebase
                    # rebases PR onto base. Force-push, rewrites published
                    # SHAs, invalidates ack-ledger entries (all bots stale).
                    # Triggers full re-review cycle. Cleaner history but
                    # reignites grind — 3-5 rounds likely. Pick when bot
                    # configurations dislike merge commits OR when the PR
                    # history matters for downstream reviewers.
  [wait]          exit; manually update later
  [admin]         gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                    # head guard (#427). <REVIEWED_HEAD> is substituted by the
                    # dispatcher — same convention as <PR_NUMBER> — with the
                    # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                    # that re-derives at merge time and blesses a post-
                    # classification commit, defeating the guard.
                    (no audit trail — proceed only with explicit operator authorization)
                    # verify: gh pr view <PR_NUMBER> --json state -q .state
                    # (retry up to 3x with 2s backoff — trust the API state,
                    #  not the merge exit code)
```

After the operator picks `[update-merge]` or `[update-rebase]`, pr-grind should be re-invoked on the same PR — the new HEAD will trigger fresh bot reviews and (probably) a short wait-round sequence to convergence. After `[admin]`, the PR is merged; pr-grind exits clean.

**Approver-Gap Detection (run BEFORE the merge attempt):**

After CI is green, threads are resolved, and bot acks are HEAD, GitHub may still reject the merge because branch protection demands `required_approving_review_count >= 1` human APPROVED reviews the author cannot self-provide. The dispatcher detects this structural gap up front so the operator sees a tailored decision message instead of a raw `gh pr merge` failure.

**The detection is scoped narrowly:** only the `required_approving_review_count` axis qualifies, and only when CI is green AND every required status check has passed. Other branch-protection failures (failing required checks, missing required signatures, etc.) are NOT approver-gap bails — they surface via their existing paths.

The detection algorithm lives at `scripts/approver-gap-detect.sh` (single source of truth, same factoring pattern as `scripts/ack-ledger.sh`). Callers compose the inputs from `gh api`, export them, and switch on the script's JSON decision:

```bash
PR=<PR_NUMBER>
# Mirror $PR into $PR_NUMBER as a shell variable so the OPTIN_SNAPSHOT path
# below can use `${PR_NUMBER}` consistently with Step 0's writer template.
# Without this, `${PR_NUMBER}` expands to empty in this fresh shell (each
# Bash tool call has fresh shell state) and the detector looks for
# `.pr-grind-solo-opt-in-snapshot-.local`, silently disabling solo-admin
# auto-detect even when Step 0 wrote the correct per-PR snapshot.
PR_NUMBER="$PR"
OWNER=<owner>
REPO=<repo>
# WORKTREE_DIR is propagated from Step 0 (see "WORKTREE_DIR=$WORKTREE_DIR"
# marker line). Required here because the solo-admin opt-in resolution below
# uses `git -C "$WORKTREE_DIR"` to derive MAIN_REPO_ROOT_FOR_OPTIN — a plain
# `git rev-parse` is CWD-sensitive, and CWD does not reliably persist across
# Claude Bash tool calls (see EXTREMELY-IMPORTANT block near top). If CWD has
# drifted to another repo checkout when Completion runs, a bare `git rev-parse`
# could read another repo's opt-in/snapshot for the same PR number, enabling
# unintended auto-merge or silently missing the target repo's valid opt-in.
WORKTREE_DIR=<absolute path from Step 0>

BRANCH=$(gh pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null || echo "")
AUTHOR=$(gh pr view "$PR" --json author -q .author.login 2>/dev/null || echo "")

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
PR_REVIEWS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" 2>/dev/null || echo "")
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
# --admin-on-approver-gap flag from the pr-grind invocation. Off by default.
# Template-substituted by the dispatcher (Claude) at run time — the literal
# 0 or 1 is written into the script before bash sees it. See "Resolve
# flag-to-state translations" in START for the producer site. The reason
# this is NOT `${ADMIN_FLAG_PASSED:-0}` is that bash exports do not survive
# across Claude Bash tool calls (each call gets a fresh shell), so the
# fallback would always resolve to 0 regardless of what the operator
# passed — silently neutralizing --admin-on-approver-gap.
ADMIN_FLAG_PASSED=<0|1 — see "Resolve flag-to-state translations" in START>

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
GAP_DECISION=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.decision' 2>/dev/null || echo surface-decision)
GAP_TRIGGER=$(printf '%s' "$GAP_DECISION_JSON" | jq -r '.trigger // "none"' 2>/dev/null || echo none)
```

**Decision tree** (based on `GAP_DECISION`):

- **`no-gap`** → fall through to the normal `gh pr merge` path below.
- **`surface-decision`** → BAIL with `RESULT_BAIL_CATEGORY=policy` and surface the operator-decision message (template below). Excluded from MAX_FIX/MAX_WAIT accounting. The `audit_workflow_present` field in the JSON controls whether `[admin]` appears as the first/default option.
- **`auto-admin-merge`** → log to `.claude/bypass-log.jsonl` and run `gh pr merge <PR> --squash --delete-branch --admin`. Two triggers can reach this decision: `trigger=flag` (operator passed `--admin-on-approver-gap` per-invocation) or `trigger=solo-admin-auto` (operator placed `.claude/pr-grind-auto-admin-solo.local` AND remains the sole human admin — see the "Solo-admin auto-detect" composer above). Both require the baseline gates: CI/bots clean (asserted by caller) AND author has admin/maintain AND `bypass-audit.yml` exists. Fail-CLOSED on any missing condition. The caller selects the bypass-log `event` value from `GAP_TRIGGER` so explicit vs. structural bypasses are distinguishable in forensics.

**Bypass-log format** (append-only JSONL; gitignored under `.claude/`):

```bash
# Same-call-scope contract: this block executes INSIDE the auto-admin-merge
# branch of the approver-gap detection bash call above, so PR / OWNER /
# REPO / BRANCH / AUTHOR / GAP_DECISION_JSON are all in scope from that
# parent block. Defense-in-depth re-derivations below cover the
# single-call-shared-shell case:
#   - PR / OWNER / REPO: re-template-substituted by the dispatcher (Claude)
#     so the values match the parent block's substitutions even if the
#     dispatcher chooses to split this into its own Bash tool call.
#   - BRANCH / AUTHOR: re-derived via `gh -R "$OWNER/$REPO"` (NOT bare
#     `gh pr view`, which resolves the repo from CWD — in a CWD-drift
#     scenario it could record a different repo's PR with the same number
#     while the audit log says this OWNER/REPO).
#   - REPO_ROOT: recomputed locally because the marker-write block above
#     runs as its own Bash tool call (see the EXTREMELY-IMPORTANT block
#     before the marker-write subsection) and its variables don't survive
#     into a subsequent call.
# Three fields live ONLY inside the script's emitted JSON (.author_perm,
# .required_approving_review_count, .human_approvals — see
# scripts/approver-gap-detect.sh "Output"); extract them from
# $GAP_DECISION_JSON before composing the log line. $GAP_DECISION_JSON
# itself is NOT re-derivable here; it must remain in shell scope from the
# parent approver-gap detection call. If the dispatcher splits this into
# a separate Bash call and $GAP_DECISION_JSON is empty, the authorization
# gate below aborts (see next paragraph) — the merge does NOT run.
#
# Fail-CLOSED on missing/malformed $GAP_DECISION_JSON: this block is the
# `auto-admin-merge` branch, and that branch is only legal if the detector
# emitted `decision=auto-admin-merge` AND `trigger in {flag,solo-admin-auto}`.
# Treating either as missing/unverifiable as a license to proceed would
# convert the authorization input into a fail-OPEN trust boundary —
# wrong even though the merge command runs next. Verify the detector
# decision is in scope and consistent before logging + merging.
PR=<PR_NUMBER>
OWNER=<owner>
REPO=<repo>
# Preserve any already-in-scope BRANCH / AUTHOR from the parent
# approver-gap detection call. Only re-derive (via `gh -R "$OWNER/$REPO"`
# to avoid CWD-based repo inference) if they're empty AND the gh call
# succeeds — a transient gh failure must NOT overwrite a known-good value
# with empty string, which would weaken the bypass-log audit trail.
if [ -z "${BRANCH:-}" ]; then
  GH_BRANCH=$(gh -R "$OWNER/$REPO" pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null)
  [ -n "$GH_BRANCH" ] && BRANCH="$GH_BRANCH"
fi
if [ -z "${AUTHOR:-}" ]; then
  GH_AUTHOR=$(gh -R "$OWNER/$REPO" pr view "$PR" --json author -q .author.login 2>/dev/null)
  [ -n "$GH_AUTHOR" ] && AUTHOR="$GH_AUTHOR"
fi
REPO_ROOT=$(git rev-parse --show-toplevel)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)

# Fail-CLOSED authorization gate. $GAP_DECISION_JSON must be in scope from
# the parent approver-gap detection call AND contain a valid auto-admin-merge
# decision with a known trigger. Empty / malformed / wrong-decision / unknown-
# trigger inputs ABORT before the merge — the bypass-log entry and `gh pr
# merge --admin` only run on a verified authorization.
if [ -z "${GAP_DECISION_JSON:-}" ]; then
  echo "❌ approver-gap auto-admin: GAP_DECISION_JSON empty (split-call broke same-call-scope contract) — aborting before bypass-log + merge"; exit 1
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
# --match-head-commit closes the check-then-merge race (#427): GitHub itself
# refuses the merge unless the PR head still equals the SHA every ack/CI
# classification was made against.
#
# REVIEWED_HEAD is template-substituted by the dispatcher — the literal 40-char
# HEAD_FULL_SHA captured in the classification block (see "HEAD_FULL_SHA=$(git
# rev-parse HEAD)" there) is written here before bash executes. Same idiom as
# NO_WORKTREE / ADMIN_FLAG_PASSED below, and for the same reason: bash exports
# do not survive across Claude Bash tool calls.
#
# Do NOT substitute `$(git rev-parse HEAD)` and do NOT use `$HEAD_SHA` (that one
# is the truncated 8-char display form). Re-deriving HEAD *here* would defeat the
# whole guard — it blesses whatever local HEAD is at merge time, including a
# commit that landed after classification, so the guard would then only catch
# remote-only pushes rather than closing the check-then-merge race.
REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
gh pr merge "$PR" --squash --delete-branch --admin --match-head-commit "$REVIEWED_HEAD" || true
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
# GC the merged PR's codex-retrigger idempotency markers (#327). Runs from
# $WORKTREE_DIR — the CWD codex-retrigger wrote them relative to — so they are
# pruned even though this admin-merge path removes no worktree. Best-effort;
# a failed prune must never affect merge success.
( cd "$WORKTREE_DIR" || exit 0; bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "$PR" ) || true
```

**Operator-decision message template** (rendered to stdout on BAIL; `[admin]` is omitted when no audit workflow exists). Placeholders: `{REQUIRED_COUNT}` is the branch-protection rule's `required_approving_review_count` (from `$GAP_DECISION_JSON`); `<PR_NUMBER>` is the PR number — distinct values, distinct placeholders so the rendering layer doesn't conflate them:

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but branch protection requires {REQUIRED_COUNT} human APPROVED review(s) the
author cannot self-provide. Project has bypass-audit.yml — note: the [admin]
command below runs outside pr-grind and writes NO entry to
.claude/bypass-log.jsonl. For a logged merge, re-invoke with
--admin-on-approver-gap instead (bypass-audit.yml audits direct pushes only;
it does not detect gh pr merge --admin regardless of path).

Options:
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                   # head guard (#427). <REVIEWED_HEAD> is substituted by the
                   # dispatcher — same convention as <PR_NUMBER> — with the
                   # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                   # that re-derives at merge time and blesses a post-
                   # classification commit, defeating the guard.
                   # verify: gh pr view <PR_NUMBER> --json state -q .state
                   # (retry up to 3x with 2s backoff — the GitHub API (queried
                   #  via gh) can briefly return state=OPEN due to post-merge
                   #  replication lag, and `gh pr merge --delete-branch` can
                   #  exit non-zero on a worktree-checkout conflict even after
                   #  the remote merge succeeded; trust the API state, not the
                   #  merge exit code)
  [wait]         exit; wait for a human reviewer
  [add-reviewer] gh pr edit <PR_NUMBER> --add-reviewer <user>; exit
```

When `AUDIT_WORKFLOW_PRESENT=0`, omit `[admin]` from the first/default position and prepend a stronger warning that no audit trail exists:

```text
pr-grind: PR is functionally clean (CI green, bots ack HEAD, threads resolved)
but branch protection requires {REQUIRED_COUNT} human APPROVED review(s) the
author cannot self-provide. ⚠️  This repo has NO bypass-audit.yml — an
admin-merge here would leave NO audit trail. Strongly consider [add-reviewer]
or [wait].

Options:
  [wait]         exit; wait for a human reviewer
  [add-reviewer] gh pr edit <PR_NUMBER> --add-reviewer <user>; exit
  [admin]        gh pr merge <PR_NUMBER> --squash --delete-branch --admin --match-head-commit <REVIEWED_HEAD>
                   # head guard (#427). <REVIEWED_HEAD> is substituted by the
                   # dispatcher — same convention as <PR_NUMBER> — with the
                   # classified HEAD_FULL_SHA. Do NOT emit $(git rev-parse HEAD):
                   # that re-derives at merge time and blesses a post-
                   # classification commit, defeating the guard.
                   (no audit trail — proceed only with explicit operator authorization)
                   # verify: gh pr view <PR_NUMBER> --json state -q .state
                   # (retry up to 3x with 2s backoff — the GitHub API (queried
                   #  via gh) can briefly return state=OPEN due to post-merge
                   #  replication lag, and `gh pr merge --delete-branch` can
                   #  exit non-zero on a worktree-checkout conflict even after
                   #  the remote merge succeeded; trust the API state, not the
                   #  merge exit code)
```

<EXTREMELY-IMPORTANT>
**DO NOT use `gh pr merge` exit code as merge authority.** The retry block below MUST be run as-written; do NOT simplify it to `if gh pr merge ...; then ... else "Merge failed" fi` — that drift makes the dispatcher misread a SUCCESSFUL remote merge as a failure. The failure mode is post-merge local-cleanup: `gh pr merge --delete-branch` runs `git fetch && git checkout <base>` locally after the API merge, and on a multi-worktree setup where the base branch is already checked out elsewhere, that local step exits non-zero with `fatal: 'main' is already used by worktree at ...` AFTER the remote PR is already merged. Trusting the exit code makes pr-grind print "preserving worktree for inspection" while the PR is in fact merged on GitHub — a misleading state that leads operators to re-attempt the merge (failing with "PR already merged"), think the first attempt failed, and waste a session debugging a non-bug.

**Confirmed recurrences:** PR #98 (2026-05-13) — the original failure that motivated the retry block. PR #102 (2026-05-18) — recurred *despite* the comment-buried explanation because the prose was easy to skim past while writing dispatcher code. This headline callout is the current attempt to make the contract unmissable; do not soften it back into a comment.

**The contract:** `gh pr merge ... || true` (do not fail on non-zero exit) → `gh pr view --json state` with 3-attempt 2s-backoff retry as the authoritative source. Use the block below verbatim.
</EXTREMELY-IMPORTANT>

**Default: merge, then clean up the worktree (skip cleanup with `--no-worktree`). Run this as its own Bash tool call — DO NOT prefix it with the marker-write block above; see the `<EXTREMELY-IMPORTANT>` block immediately preceding "Write the pr-grind-clean marker" for why:**
```bash
# NO_WORKTREE template-substituted by the dispatcher at run time — the
# literal 0 or 1 from "Resolve flag-to-state translations" in START is
# written here before bash executes. Do NOT use `${NO_WORKTREE:-0}`:
# bash exports do not survive across Claude Bash tool calls, so the
# fallback always resolves to 0 and the cleanup branch always runs
# (wrong when Step 0's auto-fallback engaged or --no-worktree was passed).
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
# --match-head-commit closes the check-then-merge race (#427). REVIEWED_HEAD is
# template-substituted with the literal 40-char HEAD_FULL_SHA from the
# classification block — NOT re-derived here; see the auto-admin block above for
# why re-deriving at merge time defeats the guard.
REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
gh pr merge <PR_NUMBER> --squash --delete-branch --match-head-commit "$REVIEWED_HEAD" || true
# Verify via authoritative source — `gh pr merge` exit code is unreliable
# when --delete-branch hits a post-merge worktree-checkout conflict (the
# remote merge has already SUCCEEDED, but gh tries to update the local
# main-branch checkout and fails when main is checked out in another
# worktree). The "main is already used by worktree at ..." error makes gh
# exit non-zero AFTER the remote PR is already merged. Trusting the exit
# code would make the dispatcher think the merge failed and either retry
# (no-op — PR is already merged) or bail with stale state. The merge
# state on GitHub is the authoritative source. Empirical: surfaced
# during PR #98's grind (2026-05-13).
# Retry up to 3 times with 2s backoff. Two real failure modes the retry
# absorbs: (1) the worktree-checkout conflict above makes `gh pr merge`
# exit non-zero even though the remote merge succeeded — the next `gh pr
# view` may briefly still see state=OPEN; (2) transient post-merge
# replication lag in the GitHub API (queried via gh). The retry is idempotent (read-only poll).
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=$(gh pr view <PR_NUMBER> --json state -q .state 2>/dev/null || echo "")
  [ "$MERGE_STATE" = "MERGED" ] && break
  [ "$attempt" -lt 3 ] && sleep 2
done
if [ "$MERGE_STATE" != "MERGED" ]; then
  echo "❌ PR #<PR_NUMBER> not merged after 3 attempts (state=$MERGE_STATE); preserving worktree for inspection."
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
# GC the merged PR's codex-retrigger idempotency markers (#327), from $WORKTREE_DIR
# (the CWD codex-retrigger wrote them relative to) BEFORE any worktree removal below,
# so a skipped/failed removal never leaks them. Best-effort. NOTE: this block uses the
# <PR_NUMBER> template literal (Claude substitutes it), NOT the $PR shell var.
( cd "$WORKTREE_DIR" || exit 0; bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "<PR_NUMBER>" ) || true
# Only return to a separate worktree and remove the ephemeral one if Step 0
# actually created it. With --no-worktree we ran in-place — there is no
# separate worktree to leave or remove.
if [ "$NO_WORKTREE" != "1" ]; then
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**If `--no-merge`: write marker to the repo root of the worktree the user will merge from, clean up, report ready (also `--no-worktree`-aware):**
```bash
# NO_WORKTREE template-substituted same as Default-merge block above —
# `${NO_WORKTREE:-0}` would silently default to 0 across Bash tool calls
# and the wrong cleanup branch would fire.
NO_WORKTREE=<0|1 — see "Resolve flag-to-state translations" in START>
# When --no-worktree, the dispatcher already runs in the user's worktree, so
# the marker target is the same repo root we're in — no cross-worktree copy.
if [ "$NO_WORKTREE" = "1" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
  mkdir -p "$REPO_ROOT/.claude"
  # Same `<PR> <REVIEWED_HEAD>` contract as the marker-write block above (#505): the
  # CLASSIFIED head (REVIEWED_HEAD), never a fresh headRefOid query.
  REVIEWED_HEAD=<full 40-char SHA — the HEAD_FULL_SHA from the classification block>
  if [ "${#REVIEWED_HEAD}" -ne 40 ]; then
    echo "ABORT: REVIEWED_HEAD is not a full 40-char SHA — marker NOT written. Do not merge; re-run /pr-grind." >&2
    exit 1
  fi
  printf '%s %s\n' "<PR_NUMBER>" "$REVIEWED_HEAD" > "$REPO_ROOT/.claude/pr-grind-clean.local"
  rm -f "$REPO_ROOT/.claude/pr-pending-grind.local"
else
  ORIGINAL_REPO_ROOT=$(git -C <original-worktree-path> rev-parse --show-toplevel)
  mkdir -p "$ORIGINAL_REPO_ROOT/.claude"
  cp .claude/pr-grind-clean.local "$ORIGINAL_REPO_ROOT/.claude/pr-grind-clean.local"
  rm -f "$ORIGINAL_REPO_ROOT/.claude/pr-pending-grind.local"
  cd <original-worktree-path>
  git worktree remove "../pr-grind-<PR_NUMBER>" --force 2>/dev/null || true
fi
```

**Output (both modes):**
```text
## PR Grind Complete

PR #<N> is clean after <rounds> round(s).
- Model: Sonnet
- CI: all required checks passing
- Automated reviewers: all completed, no actionable findings
- Advisory checks: [fixed | N failing — noted as beyond PR scope]
- Human comments: all addressed
- Worktree cleaned up.
```

**Default:** append `- Merged.`

**With `--no-merge`:** append `- Ready for merge.`

