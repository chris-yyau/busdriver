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

# Self-resolver (dogfood-friendly): when invoked from inside a busdriver source
# checkout, re-exec the working-tree copy of this script instead of running
# whatever the caller resolved (typically `$CLAUDE_PLUGIN_ROOT/scripts/ack-
# ledger.sh` from the plugin cache). This eliminates the asymmetry where an
# in-flight ack-ledger fix in the working tree coexists with the stale cached
# plugin version on the same workstation — the failure mode behind the PR #79
# (script extraction) and PR #139 (Case 3 regex anchoring) dogfood incidents
# (see project memory pr-grind-cubic-skips-merge-commits).
#
# Detection is a no-op (continue with the calling script's body) when ANY of:
#   (a) BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 (operator escape hatch)
#   (b) CWD is not in a git repo (`git rev-parse --show-toplevel` fails)
#   (c) git remote origin URL doesn't end in `busdriver(\.git)?$`
#   (d) working-tree `scripts/ack-ledger.sh` doesn't exist (defensive)
#   (e) self-path already references the working-tree path via the `-ef`
#       inode-equality test (recursion guard — handles symlinked checkouts
#       where the logical paths differ but resolve to the same directory)
#
# CWD-routing semantics: detection is based on git's CWD-resolved toplevel,
# not the script's BASH_SOURCE-resolved location. If a user has multiple
# busdriver checkouts and runs the cached script from CWD inside checkout A
# while wanting to test the cached version's behavior, the resolver will
# route to checkout A's working tree (NOT the cache). Set BUSDRIVER_DISABLE_
# ACK_SELF_RESOLVE=1 in the parent shell to force cache execution.
#
# Fail-CLOSED on any unexpected error: the if-chain only fires when every
# predicate succeeds, so partial detection failures (e.g., git installed but
# CWD outside any repo) fall through to the calling script's logic. `exec`
# preserves "$@" and exported env vars (FETCH_OK, ALL_THREADS, ALL_REVIEWS,
# ALL_COMMENTS, ALL_CHECK_RUNS, HEAD_SHA) automatically.
#
# Why detection runs at script top: the resolver is a permanent forward-fix.
# Once shipped in vN.M, all vN.M+ caches carry the resolver, so any future
# ack-ledger dogfood (modifying this file in the busdriver source repo and
# running pr-grind on the fix's PR) auto-routes to the working-tree copy
# without operator intervention. The CURRENT dogfood session that ships the
# resolver itself still needs the operator override (working-tree-path
# substitution in the dispatcher COMPLETION block) — by design; the resolver
# can only fix incidents that occur AFTER it lands.
if [ "${BUSDRIVER_DISABLE_ACK_SELF_RESOLVE:-0}" != "1" ] && \
   _self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) && \
   _git_root=$(git rev-parse --show-toplevel 2>/dev/null) && \
   _remote=$(git -C "$_git_root" remote get-url origin 2>/dev/null) && \
   printf '%s' "$_remote" | grep -qE '[/:]busdriver(\.git)?$' && \
   [ -f "$_git_root/scripts/ack-ledger.sh" ] && \
   [ -d "$_git_root/scripts" ] && \
   ! [ "$_self_dir" -ef "$_git_root/scripts" ]; then
  exec bash "$_git_root/scripts/ack-ledger.sh" "$@"
fi
unset _self_dir _git_root _remote

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
# Otherwise (posted on an older commit, no HEAD signal yet) → stale, subject to
# the three-case downgrade block below (Cases 1/2/3 may downgrade to `none`
# when ever_approved==0 and a specific positive signal matches).
if [ -z "$commit_id" ] && [ -z "$body_sha" ]; then echo "none"; exit 0; fi

# Three-case downgrade — all gated by `ever_approved == 0` so a bot that has
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
  # Case 3: check-run skipped on HEAD + COMMENTED state + non-actionable body
  # — bot saw HEAD via a check-run but its conclusion is `skipped`. Canonical
  # case: cubic-dev-ai on merge commits. After `gh pr update-branch` creates
  # a merge commit, cubic emits a check-run with conclusion=skipped on the
  # merge commit's SHA while its only `success` check-run stays anchored to
  # the pre-merge commit. Tier D above (which requires conclusion=success)
  # doesn't match HEAD, the downgrade block runs, and without this case it
  # falls through to `echo stale` (cubic posts a "No issues found" COMMENTED
  # review body that matches neither Case 1's error patterns nor Case 2's
  # PR-overview regex), deadlocking invariant 2 indefinitely.
  #
  # Four-predicate guard:
  # (a) Same ever_approved==0 outer guard as Cases 1 and 2 — a bot with prior
  #     APPROVED / DISMISSED / CHANGES_REQUESTED never reaches this block, so
  #     the [CHANGES_REQUESTED, skipped-HEAD] history correctly stays `stale`.
  # (b) last_state == COMMENTED — implies the bot has at least one /reviews
  #     entry whose body we can inspect. Rules out body_sha-only bots (e.g.,
  #     a hypothetical Greptile variant that posts findings as issue-comment
  #     bodies with body-SHA-reference links but no /reviews entries). For
  #     such bots `last_state` is empty and `last_body` is empty — without
  #     this guard, Case 3 would fire on the empty body and silently
  #     downgrade actionable issue-comment findings to `none`. Mirrors
  #     Case 2 which already requires COMMENTED state.
  # (c) body_sha is empty — rules out bots whose actionable content lives in
  #     issue-comment bodies referenced via body-SHA links, including mixed
  #     shapes where a non-actionable /reviews body coexists with actionable
  #     issue-comment content.
  # (d) Positive-signal body guard — only downgrade when last review body is
  #     empty OR CONTAINS a known non-actionable phrase as a substring. Without
  #     (d), a bot with an actionable COMMENTED finding ("please fix line 47")
  #     plus a later skipped-HEAD check-run would silently downgrade to `none`,
  #     discarding the actionable signal. Mirrors Case 2's PR-overview guard
  #     for the same risk shape.
  #
  #     Substring match (not anchored `^...$`) is required to handle real-world
  #     bot bodies that wrap the phrase in markdown and footers. Canonical
  #     example (cubic-dev-ai, observed PR #137): `**No issues found** across
  #     1 file\n\n<sub>[Re-trigger cubic](...)</sub>\n\n<!-- cubic:* -->`.
  #     Newlines are normalized to spaces on line 123 before this regex runs.
  #
  #     Accepted false-negative: a body like "no issues found but please fix X"
  #     would match the substring and downgrade to `none`, discarding the
  #     actionable "but" clause. We accept this because guards (a)/(b)/(c)
  #     above (ever_approved==0, COMMENTED state, no body_sha) make accidental
  #     matches on actionable-finding bodies rare in practice, and Tier A's
  #     unresolved-thread check above catches the inline-comment variant.
  #
  # The skipped-check-run jq query filters by HEAD inside the predicate (not
  # `last | head_sha` then bash-side check). This is pagination-order
  # resilient: if the slurped check-runs array contains both a HEAD-skipped
  # entry and a stale-skipped entry in any order, the predicate still matches
  # the HEAD entry. The bash-side check becomes a count > 0 test.
  #
  # Mapping to `none` (not HEAD_SHA) preserves the semantic distinction:
  # "bot acknowledged HEAD via check-run but declined to review" is not the
  # same as "bot approved HEAD". Same precedent as Case 1.
  #
  # Reachability: bots with zero review history (no /reviews entry, no body
  # SHA reference) exit via line 98 with `none` before reaching this block.
  # Case 3 only applies to bots that have at least one prior /reviews entry
  # in COMMENTED state.
  check_run_skipped_head_count=$(printf '%s' "$ALL_CHECK_RUNS" | jq -rs --arg login "$login" --arg head8 "$HEAD_SHA" \
    '[.[].check_runs[] | select(.app.slug == $login) | select(.conclusion == "skipped") | select((.head_sha[0:8]) == $head8)] | length' 2>/dev/null || echo 0)
  if [ "$check_run_skipped_head_count" -gt 0 ] && [ "$last_state" = "COMMENTED" ] && [ -z "$body_sha" ] && \
     { [ -z "$last_body" ] || \
       printf '%s' "$last_body" | grep -qiE '(no issues? found|no concerns|all good|looks good|lgtm|nothing to (add|report)\b)'; }; then
    echo "none"; exit 0
  fi
fi

echo "stale"
