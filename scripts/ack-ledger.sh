#!/usr/bin/env bash
# scripts/ack-ledger.sh — canonical per-bot ack computation for pr-grind.
#
# Single source of truth for the four-tier ack ledger algorithm. Replaces
# three previously inlined function definitions that had to be kept in
# byte-for-byte lockstep:
#   - agents/pr-grinder.md   Step 6.5      ack_for_bot()
#   - skills/pr-grind/SKILL.md Step 6.5    inline_ack_for_bot()
#   - skills/pr-grind/SKILL.md Completion  dispatcher_ack_for_bot()
# Ledger changes now touch one file. Cross-site comments at the call sites
# point here for traceability.
#
# Caller responsibilities (BEFORE invoking):
#   1. Compute HEAD_SHA via `git rev-parse HEAD | cut -c1-8`.
#   2. Set FETCH_OK=1, then perform the four gh-API fetches that each
#      tag FETCH_OK=0 on failure (ALL_THREADS via graphql, ALL_REVIEWS,
#      ALL_COMMENTS, ALL_CHECK_RUNS). The fetch block itself stays in
#      the markdown call sites — only the per-bot algorithm lives here.
#   3. `export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA`
#      so this subprocess inherits them.
#   4. Pass the bot login as $1.
#
# Output: exactly one of <8-char-sha> | none | stale on stdout.
# Always exits 0 on success; caller treats stdout as authoritative.
#
# Caller fail-CLOSED contract: wrap every invocation with
#   `$(bash "$ACK_SCRIPT" <bot> 2>/dev/null || echo stale)`
# so that script-resolution failures (missing path during plugin upgrade —
# the dogfooding scenario in PR #79 — bash invocation errors, etc.) collapse
# to `stale` instead of an empty string. Without the `|| echo stale` guard,
# command substitution silently expands to "" on non-zero exit, the downstream
# `awk -F= '$2=="stale"'` filter finds no match, STALE_BOTS becomes empty,
# and the merge gate is bypassed — the exact fail-OPEN regression FETCH_OK
# was introduced to prevent.

login="$1"

# Fail-CLOSED: any source-fetch failure → mark stale (Greptile P1 — fail-OPEN
# regression where API failures silently became `none` and didn't gate)
if [ "$FETCH_OK" -eq 0 ]; then echo "stale"; exit 0; fi

# (A) Source 2: are there unresolved+non-outdated threads from this bot?
# Bots like Copilot post their findings as inline threads. If unresolved+
# non-outdated, those are real findings to address → stale.
# If only DISPOSED threads exist (outdated by code change OR explicitly
# resolved by bot or operator), the bot's prior findings are no longer
# actionable → effectively acked. Operator-resolved threads count too:
# the pr-grind out-of-scope-acknowledged workflow (see agents/pr-grinder.md
# Step 3) has the worker resolve threads after either spawning a follow-up
# issue or posting an audit-only rebuttal, and that disposition must clear
# the stale signal so the merge gate doesn't block forever on a thread the
# operator already closed. The discipline rails that keep operators from
# abusing this escalation live in the dispatcher (Invariant 4: cumulative
# caps of ≤5 dismissals and ≤3 spawned issues per grind), not here — this
# script is a thread-state classifier, not a usage gate.
# jq -s slurps paginated graphql output (multiple JSON docs → single array)
unresolved=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.[].data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
    | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null || echo 0)
if [ "$unresolved" -gt 0 ]; then echo "stale"; exit 0; fi
disposed=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.[].data.repository.pullRequest.reviewThreads.nodes[]
    | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
    | select(.isOutdated == true or .isResolved == true)] | length' 2>/dev/null || echo 0)
if [ "$disposed" -gt 0 ]; then echo "$HEAD_SHA"; exit 0; fi

# (B) /reviews: did the bot explicitly submit a review on HEAD?
commit_id=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.[] | .[] | select(.user.login == $login or .user.login == $login_bot)] | last | .commit_id // empty' 2>/dev/null || echo "")
if [ -n "$commit_id" ] && [ "${commit_id:0:8}" = "$HEAD_SHA" ]; then echo "${commit_id:0:8}"; exit 0; fi

# (C) Issue-comment body SHA: bots like Greptile update a single comment with
# a "Last reviewed commit: [sha](.../commit/<sha>)" link instead of submitting
# a new /reviews entry per commit. Parse the body for the most recent commit/<sha>
# link and treat it as authoritative if it matches HEAD.
body_sha=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.comments[] | select(.author.login == $login or .author.login == $login_bot)] | last | .body // empty' 2>/dev/null \
  | grep -oE 'commit/[a-f0-9]{7,40}' | sed 's|.*/||' | tail -1 | cut -c1-8)
if [ -n "$body_sha" ] && [ "$body_sha" = "$HEAD_SHA" ]; then echo "$body_sha"; exit 0; fi

# (D) check-runs: did the bot register a passing check-run on HEAD? Some bots
# (CodeRabbit free-plan, GitGuardian, etc.) emit a check-run instead of a
# /reviews entry. The check is keyed on the head_sha of the commit, so a
# passing check_run.head_sha == HEAD_SHA means the bot has acked HEAD.
# jq -s slurps the paginated `gh api --paginate` stream (one JSON object per
# page) into a single array, then `.[].check_runs[]` flattens across pages.
# Without --paginate + slurp, busy PRs whose check-runs exceed GitHub's
# 30-result default would silently truncate and Tier D would miss the bot's
# HEAD check-run, mis-classifying as `none` (Greptile P2 / Cubic P2).
check_run_head=$(printf '%s' "$ALL_CHECK_RUNS" | jq -rs --arg login "$login" \
  '[.[].check_runs[] | select(.app.slug == $login) | select(.conclusion == "success")] | last | .head_sha // empty' 2>/dev/null || echo "")
if [ -n "$check_run_head" ] && [ "${check_run_head:0:8}" = "$HEAD_SHA" ]; then echo "${check_run_head:0:8}"; exit 0; fi

# No HEAD-ack signal anywhere. Did the bot post on this PR at all?
# If never (no /reviews entry, no body SHA reference) → bot doesn't operate here → none.
# Otherwise (posted on an older commit, no HEAD signal yet) → stale.
if [ -z "$commit_id" ] && [ -z "$body_sha" ]; then echo "none"; exit 0; fi

# Two-case downgrade — both gated by `ever_approved == 0` so a bot that has
# ever approved, had an approval dismissed, or previously requested changes
# is never silently bypassed.
# DISMISSED counts as "ever approved" because a dismissed approval is still
# a historical signal the bot genuinely approved at some point.
# CHANGES_REQUESTED counts because a bot that raised findings in a review
# body (not as inline threads) must preserve its `stale` signal even if a
# later COMMENTED review on a stale commit would otherwise trigger Case 2.
# Without CHANGES_REQUESTED in this set, the history pattern
# [CHANGES_REQUESTED(commit A), COMMENTED(commit B)] leaves ever_approved==0
# and last_state=="COMMENTED" — Case 2 would downgrade to `none` and silently
# discard the prior request for changes. The shared `ever_approved>0` guard
# also closes a potential admin-edit body-injection attack on review bodies.
#
# Note: the FETCH_OK guard at the top already returns `stale` on any
# source-fetch failure, so this block only runs on successful fetches.
{ read -r ever_approved; read -r last_state; read -r last_body; } < <(
  printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[ .[] | .[] | select(.user.login == $login or .user.login == $login_bot) ]
     | ( (map(select(.state == "APPROVED" or .state == "DISMISSED" or .state == "CHANGES_REQUESTED")) | length),
         (last | .state // ""),
         (last | .body // "" | gsub("\n"; " ")) )' 2>/dev/null \
  || printf '0\n\n\n'
)
if [ "$ever_approved" -eq 0 ]; then
  # Case 1: infra-error / rate-limit — Copilot's "encountered an error and
  # was unable to review" review object is the canonical case. GitHub leaves
  # it frozen on the SHA where it errored, never updates commit_id on later
  # pushes, and there's no gh-CLI surface to clear it (DELETE only works on
  # pending reviews; requested_reviewers POST 422s for Copilot). Treating
  # those as `stale` blocks the merge gate forever; downgrade to `none` so
  # the loop surfaces the situation to the operator instead of looping in
  # vain.
  if printf '%s' "$last_body" | grep -qiE 'encountered an error|rate.?limit|unable to review|try again by re-requesting'; then
    echo "none"; exit 0
  fi
  # Case 2: one-and-done COMMENTED — bot reviewed a prior commit with a
  # non-actionable PR-overview summary (state=COMMENTED, not APPROVED/
  # CHANGES_REQUESTED), then never re-fired despite HEAD advancing. Canonical
  # Copilot pattern: it posts a PR-overview summary on the initial commit and
  # doesn't auto-trigger on later non-force pushes; the re-request API 422s
  # so the operator has no recourse. By the time we reach this block we know:
  # (1) FETCH_OK=1, (2) no unresolved threads from this bot (Tier A would
  # have returned `stale` at the top), (3) `commit_id` is non-empty AND its
  # 8-char prefix != HEAD_SHA (Tier B would have returned the SHA otherwise),
  # (4) ever_approved==0 AND no prior CHANGES_REQUESTED (the guard above
  # now includes CHANGES_REQUESTED so a [CHANGES_REQUESTED, COMMENTED]
  # history correctly stays `stale`).
  #
  # Positive-signal guard: only downgrade when the body contains a PR-overview
  # marker ("## PR Overview", "## Pull request overview", or "PR overview
  # summary"). This prevents any bot that uses COMMENTED state for substantive
  # findings (i.e., a bot that neither uses CHANGES_REQUESTED nor posts inline
  # threads) from being silently bypassed — without this guard, any such bot
  # posting actionable content in a COMMENTED-only review would be incorrectly
  # downgraded to `none` once HEAD advances past the reviewed commit.
  if [ "$last_state" = "COMMENTED" ] && \
     printf '%s' "$last_body" | grep -qiE '## (PR|Pull request) overview|PR overview summary'; then
    echo "none"; exit 0
  fi
fi

echo "stale"
