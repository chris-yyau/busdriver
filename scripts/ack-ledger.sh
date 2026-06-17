#!/usr/bin/env bash
# scripts/ack-ledger.sh — canonical per-bot ack computation for pr-grind.
#
# Single source of truth for the five-tier ack ledger algorithm. Replaces
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
#   2. Set FETCH_OK=1, then perform the gh-API fetches that each tag
#      FETCH_OK=0 on failure (ALL_THREADS via graphql, ALL_REVIEWS,
#      ALL_COMMENTS, ALL_CHECK_RUNS, ALL_STATUSES, ALL_REACTIONS,
#      HEAD_COMMITTED_DATE, and optionally HEAD_PUSH_DATE). The fetch block
#      itself stays in the markdown call sites — only the per-bot algorithm
#      lives here. ALL_STATUSES is the legacy commit-statuses API consumed by
#      Tier E (CodeRabbit free-tier on private repos). ALL_REACTIONS
#      (issue-level reactions JSON array) feeds Tier F — the Codex-only reaction
#      tier; it is empty for callers that haven't been upgraded to fetch it, and
#      Tier F no-ops in that case. HEAD_PUSH_DATE (UTC ISO-8601) is the timestamp
#      of the push event that landed HEAD_SHA on the branch and is the SOLE
#      freshness anchor for Tier F's +1 (👍) ack: a +1 acks HEAD only when it
#      postdates HEAD_PUSH_DATE, and FAILS CLOSED (→ stale) when HEAD_PUSH_DATE is
#      absent (#189) — mirroring the resolved-thread path below. HEAD_COMMITTED_DATE
#      (HEAD's `commit.committer.date`, UTC ISO-8601) is RETAINED in the input
#      contract (still accepted/exported, best-effort) but is NO LONGER a Tier-F
#      freshness anchor and does not gate FETCH_OK: the git committer date is
#      client-stamped and backdatable, so it must not gate an automated merge ack.
#      NOTE — the Codex RESOLVED-thread ack (Tier A.2, below) shares this contract: it
#      anchors on HEAD_PUSH_DATE ALONE (never the backdatable committer date) and
#      FAILS CLOSED (→ stale) when HEAD_PUSH_DATE is absent (#186). It also requires
#      ALL_THREADS to carry, per thread, `resolvedBy { login }` and a
#      `resolutionComments: comments(last:10) { nodes { author { login } createdAt } }`
#      alias (the resolver-authored resolution-time signal for #187). Callers that
#      omit those fields get no resolved-thread ack → stale (additive, safe).
#   3. `export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_SHA`
#      so this subprocess inherits them. A caller that hasn't been upgraded
#      to fetch ALL_STATUSES will export empty for that var — Tier E sees
#      the empty input, skips silently, and the script falls through to
#      pre-Tier-E semantics. Backward-compat is additive (same pattern as
#      RESULT_ISSUES_SPAWNED on the worker contract).
#   4. Pass the bot login as $1.
#
# Output: exactly one of <8-char-sha> | none | stale on stdout.
# Always exits 0 on success; caller treats stdout as authoritative.
#
# Tier exposure (opt-in via ACK_EMIT_TIER=1): when set, a HEAD-ack SHA is
# suffixed ":<tier>" where <tier> is the letter A–F of the tier that produced
# the ack (A=inline threads — non-Codex disposed thread, or Codex resolved-current
# thread proven via the push-anchored resolver-last-comment signal (A.2); B=/reviews
# on HEAD, C=issue-comment body
# SHA, D=check-run success, E=commit-status success, F=Codex 👍 reaction newer
# than HEAD's commit). `none`/`stale` are NEVER
# suffixed. Default (env unset) output is byte-for-byte unchanged, so existing
# callers that compare the value to HEAD_SHA or to `stale` are unaffected. The
# dispatcher's Invariant 3 uses tiers D/E (bodyless structured acks) to exempt a
# HEAD-acked bot from the n_total>=1 coverage gate — see ADR 0001 and
# skills/pr-grind/SKILL.md. Soundness: tier order is A→F (A→E for non-Codex bots;
# Tier F is Codex-only), returning at the first HEAD-ack, and Tier A returns
# `stale`/Tier-A-ack on any Source-2 thread, so reaching D/E proves zero live
# Source-2 inline threads.
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
# Graceful degradation on detection failure: the if-chain only fires when
# every predicate succeeds, so partial detection failures (e.g., git
# installed but CWD outside any repo) silently fall through to the calling
# script's body. The merge gate's overall fail-CLOSED posture (which lives
# in the FETCH_OK guard below and the dispatcher's `|| echo stale` wrapper
# at every call site) is preserved — the resolver layer is path-routing
# only, not gate logic. An operator cannot directly observe whether the
# resolver fired vs no-op'd; set BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 if
# you need to force the caller's intended path. `exec` preserves "$@" and
# exported env vars (FETCH_OK, ALL_THREADS, ALL_REVIEWS, ALL_COMMENTS,
# ALL_CHECK_RUNS, ALL_STATUSES, ALL_REACTIONS, HEAD_COMMITTED_DATE,
# HEAD_PUSH_DATE, HEAD_SHA)
# automatically across the process replacement.
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
   printf '%s' "$_remote" | grep -qE '(^|[@/])github\.com[:/]chris-yyau/busdriver(\.git)?$' && \
   [ -d "$_git_root/scripts" ] && \
   [ -f "$_git_root/scripts/ack-ledger.sh" ] && \
   ! [ "$_self_dir" -ef "$_git_root/scripts" ]; then
  exec bash "$_git_root/scripts/ack-ledger.sh" "$@"
fi
unset _self_dir _git_root _remote

login="$1"

# Emit a HEAD-ack: bare SHA by default, or "<sha>:<tier>" when ACK_EMIT_TIER=1.
# $1 = 8-char SHA, $2 = tier letter (A–E). Centralizes the suffix so all five
# HEAD-ack exit points stay consistent. Default output is byte-identical to the
# pre-tier contract; only opt-in callers see the suffix.
emit_head_ack() {
  if [ "${ACK_EMIT_TIER:-0}" = "1" ]; then
    printf '%s:%s\n' "$1" "$2"
  else
    printf '%s\n' "$1"
  fi
}

# Fail-CLOSED: any source-fetch failure → mark stale (Greptile P1 — fail-OPEN
# regression where API failures silently became `none` and didn't gate)
if [ "$FETCH_OK" -eq 0 ]; then echo "stale"; exit 0; fi

# Codex eyes-override (HOISTED above every tier): a current 👀 reaction means
# Codex is actively (re-)reviewing HEAD → stale, regardless of any thread/review
# state below. Codex re-adds 👀 whenever HEAD advances, so this is the robust,
# timestamp-independent guard for the re-review race — and it MUST run before
# Tier A so a resolved-current-head thread (Tier A.2) cannot ack while Codex is
# still mid-review of a newer push. Codex-only and guarded on non-empty
# ALL_REACTIONS, so it is a strict no-op for every other login and for callers
# not yet upgraded to fetch reactions.
if [ "$login" = "chatgpt-codex-connector" ] && [ -n "$ALL_REACTIONS" ]; then
  codex_eyes=$(printf '%s' "$ALL_REACTIONS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot) | select(.content == "eyes")] | length' 2>/dev/null || echo 0)
  if [ "${codex_eyes:-0}" -gt 0 ]; then echo "stale"; exit 0; fi
fi

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
# Non-Codex bots: any DISPOSED thread (resolved OR outdated) acks HEAD — the
# bot's prior findings are no longer actionable.
# Codex: only a RESOLVED + NON-OUTDATED thread acks (a finding the worker
# addressed/dismissed ON THE CURRENT HEAD). The out-of-scope-acknowledged
# workflow resolves a thread WITHOUT a code push, so there's no new commit to
# trigger a fresh Codex 👍 — without this branch that dismissal would leave
# Codex `stale` until `--max-wait` bails (the deadlock Codex's own review of
# this PR flagged). An OUTDATED-only Codex thread is from superseded code (HEAD
# advanced past it) and must NOT ack — Codex has to re-review the new HEAD,
# caught as `stale` and cleared later by a fresh 👍 (Tier F) or a new
# resolved-current-head thread. The hoisted eyes-override above guarantees Codex
# is not mid-review when this acks.
if [ "$login" = "chatgpt-codex-connector" ]; then
  # Consolidated Codex resolution; precedence order is load-bearing. Tier A.1
  # above (unresolved+non-outdated → stale) already ran login-agnostically, so a
  # LIVE finding has blocked.
  # (1) FRESH 👍 FIRST — a +1 newer than HEAD means Codex re-reviewed the CURRENT
  #     HEAD and is satisfied → ack. Checked before the OUTDATED short-circuit
  #     because GitHub retains outdated threads FOREVER once code changes: a
  #     single past Codex finding would otherwise keep the PR `stale` until
  #     --max-wait even after a clean re-review (permanent deadlock — flagged by
  #     Codex + cubic on PR #185). sort_by created_at — reactions API ordering
  #     is not guaranteed.
  codex_plus1=$(printf '%s' "$ALL_REACTIONS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot) | select(.content == "+1")] | sort_by(.created_at) | last | .created_at // empty' 2>/dev/null || echo "")
  # Freshness anchor: HEAD_PUSH_DATE (push event timestamp) ALONE — NEVER the git
  # committer date. The committer date is client-stamped and backdatable: force-push
  # an old commit whose committer date predates a leftover +1 and that +1 would look
  # "fresh" → a false HEAD-ack on un-re-reviewed code (#189). So a +1 acks ONLY when a
  # server-stamped push anchor exists AND the +1 postdates it. When HEAD_PUSH_DATE is
  # absent (fork head, events API delayed / aged-out >90d / capped >300 events) there
  # is no trustworthy anchor → DO NOT ack; fall through to stale (fail-CLOSED). This
  # matches the resolved-thread sibling below (#186) — uniform fail-closed, no
  # committer fallback, no sentinel. The hoisted eyes-override above and Tier A.2
  # (push-anchored resolved-current) cover the active-re-review and out-of-scope-clear
  # cases; a genuinely outdated finding with no push anchor SHOULD wait for re-review
  # (operator-visible --max-wait), which is correct, not a regression.
  if [[ -n "$codex_plus1" && -n "${HEAD_PUSH_DATE:-}" && "$codex_plus1" > "${HEAD_PUSH_DATE}" ]]; then
    emit_head_ack "$HEAD_SHA" F; exit 0
  fi
  # (2) OUTDATED thread (no fresh 👍) — Codex reviewed superseded code and must
  #     re-review the new HEAD → stale (engaged, not none). Precedes the
  #     resolved-current ack so a MIXED state (resolved-current + outdated) stays
  #     stale.
  codex_outdated=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isOutdated == true)] | length' 2>/dev/null || echo 0)
  if [ "${codex_outdated:-0}" -gt 0 ]; then echo "stale"; exit 0; fi
  # (3) RESOLVED + non-outdated thread — a finding the worker addressed/dismissed
  #     on the CURRENT head (out-of-scope-acknowledged workflow resolves WITHOUT a
  #     push → no new commit to trigger a fresh 👍). Acking this is the only way the
  #     out-of-scope flow clears, but a resolved thread carries NO API resolution
  #     timestamp (GraphQL exposes resolvedBy but not resolvedAt; there is no
  #     thread-resolution event in the GraphQL timeline union or REST timeline —
  #     verified 2026-06-17). So freshness is PROVEN from the only two pollable
  #     signals, and we FAIL-CLOSED when they are absent (#186):
  #
  #     (i)  PUSH-TIME ANCHOR ONLY. This path anchors on HEAD_PUSH_DATE (the push
  #          that landed HEAD), NEVER max(committer, push). The committer date is
  #          attacker-controllable — force-push an older commit with a backdated
  #          committer date and a stale resolution looks newer than HEAD — so it must
  #          not gate a resolved-thread ack. When HEAD_PUSH_DATE is empty (fork head,
  #          events API delay/aged-out, or an unupgraded caller) there is no trustworthy
  #          anchor → DO NOT ack; exit stale (fail-CLOSED). This intentionally REVERSES
  #          the old "empty anchor ⇒ ack" backward-compat: on a P1 merge gate a
  #          frequent fail-CLOSED stall the operator can see beats a narrow silent
  #          fail-OPEN (council 2026-06-17; see ~/.claude/notes/lesson-council-2026-
  #          06-17-resolved-ack-fail-closed.md).
  #     (ii) RESOLVER-AUTHORED, LAST-COMMENT RESOLUTION SIGNAL. Freshness requires the
  #          thread's LAST comment (chronologically) to be authored by resolvedBy AND
  #          to postdate the push — the "reply-then-resolve, nothing after" pattern
  #          pr-grind's out-of-scope workflow produces. This is deliberately stricter
  #          than the first comment (Codex's finding time, the #187 false-stale bug)
  #          and than max() over all resolver comments (which let later unrelated
  #          activity re-freshen a stale resolution — a residual fail-OPEN caught in PR
  #          deep review). Requiring the LAST comment to be the resolver's means any
  #          activity AFTER the resolution (a Codex re-engagement, a third-party reply)
  #          drops the ack to stale. The finding bot itself is excluded as resolver — in
  #          both the bare ($login) and [bot]-suffixed ($login_bot) login forms — so the
  #          Codex App cannot self-clear a thread it filed.
  #          THREAT MODEL / RESIDUAL: this proves an *operator disposition that is the
  #          thread's latest state on the current HEAD* — it does NOT prove Codex
  #          re-reviewed HEAD (no API exposes that without a fresh 👍). The gate guards
  #          against ACCIDENTAL merge past an un-re-reviewed finding (resolve on commit
  #          A, push unrelated B, walk away → last comment predates B → stale). A
  #          DELIBERATE post-push operator comment on the resolved thread can still
  #          freshen it; that is a conscious act by the merge-authority holder, accepted
  #          here. The Codex-authored re-review signals remain Tier F (fresh 👍) and the
  #          eyes-override. (Council 2026-06-17 + PR deep-review tightening.)
  #          Timestamp contract: createdAt and HEAD_PUSH_DATE are both GitHub-emitted
  #          UTC 'Z'-form ISO-8601, so lexicographic > is a correct time comparison.
  #          resolutionComments uses comments(last:10): a resolver reply evicted from
  #          that window (>10 trailing comments) yields no match → stale (fail-CLOSED).
  #          A caller that omits resolvedBy/resolutionComments → no match → stale (safe).
  #     ALL-OR-STALE: the ack fires only when EVERY resolved+non-outdated Codex thread
  #     is proven fresh. If even one is unproven it forces stale — a stale resolved
  #     thread must never be masked by a fresh sibling (mirrors the (2) outdated
  #     precedence). A thread is "proven fresh" iff HEAD_PUSH_DATE is present, resolvedBy
  #     is set and is not the finding bot, and the thread's LAST comment is resolver-
  #     authored and strictly newer than HEAD_PUSH_DATE.
  codex_resolved_any=$(printf '%s' "$ALL_THREADS" | jq -rs \
    --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isResolved == true and .isOutdated == false)
    ] | length' 2>/dev/null || echo 0)
  if [ "${codex_resolved_any:-0}" -gt 0 ]; then
    # (The outer `codex_resolved_any > 0` guard already closed PR #185's fail-OPEN-to-
    # `none` — a resolved Codex thread can no longer fall through to the `none` early-
    # return.) Here: no push anchor → nothing can be proven fresh → stale (#186 fail-CLOSED).
    if [ -z "${HEAD_PUSH_DATE:-}" ]; then echo "stale"; exit 0; fi
    # Count resolved+non-outdated threads that are NOT proven fresh (the negation of the
    # freshness predicate). Any > 0 → stale, so one stale resolution blocks the whole ack.
    # Fail-CLOSED on jq error: this query indexes resolvedBy/resolutionComments, which the
    # codex_resolved_any count does NOT — so malformed thread JSON (e.g. resolvedBy not an
    # object) could break ONLY this query. Defaulting its error case to codex_resolved_any
    # (which is > 0 here) forces stale instead of a false ack, preserving the file's
    # fail-CLOSED-on-error invariant.
    codex_resolved_unproven=$(printf '%s' "$ALL_THREADS" | jq -rs \
      --arg login "$login" --arg login_bot "${login}[bot]" \
      --arg push "$HEAD_PUSH_DATE" \
      '[.[].data.repository.pullRequest.reviewThreads.nodes[]
        | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
        | select(.isResolved == true and .isOutdated == false)
        | (.resolvedBy.login // "") as $rb
        | ((.resolutionComments.nodes // []) | sort_by(.createdAt) | last) as $lastc
        | select($rb == "" or $rb == $login or $rb == $login_bot
                 or $lastc == null or $lastc.author.login != $rb or ($lastc.createdAt <= $push))
      ] | length' 2>/dev/null || echo "$codex_resolved_any")
    if [ "${codex_resolved_unproven:-0}" -gt 0 ]; then echo "stale"; exit 0; fi
    # Every resolved+non-outdated thread is proven fresh → ack.
    emit_head_ack "$HEAD_SHA" A; exit 0
  fi
  # (4) ENGAGED (a stale 👍 from before the last push, or any other reaction) but
  #     no fresh ack and no actionable threads → stale (waits for re-review). No
  #     reaction AND no threads → fall through to Tier B / the `none` early-return.
  codex_reacted=$(printf '%s' "$ALL_REACTIONS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot)] | length' 2>/dev/null || echo 0)
  if [ "${codex_reacted:-0}" -gt 0 ]; then echo "stale"; exit 0; fi
else
  disposed=$(printf '%s' "$ALL_THREADS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isOutdated == true or .isResolved == true)] | length' 2>/dev/null || echo 0)
  if [ "$disposed" -gt 0 ]; then emit_head_ack "$HEAD_SHA" A; exit 0; fi
fi

# (B) /reviews: did the bot explicitly submit a review on HEAD?
commit_id=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.[] | .[] | select(.user.login == $login or .user.login == $login_bot)] | last | .commit_id // empty' 2>/dev/null || echo "")
# Codex exception (same family as Tier A's disposed branch): a Codex /reviews
# entry is ALWAYS a COMMENTED findings post — Codex reacts with 👍 when it has
# NO suggestions and only opens a review when it DOES (per OpenAI's integration).
# Treating that as a clean HEAD-ack would merge past untriaged findings, so Codex
# is excluded here and falls through to the downgrade block → `stale` (block
# until the worker triages and Codex re-reviews clean). Codex's only positive ack
# is the Tier F 👍. `commit_id` is still computed above for that downgrade block.
if [ -n "$commit_id" ] && [ "${commit_id:0:8}" = "$HEAD_SHA" ] && [ "$login" != "chatgpt-codex-connector" ]; then emit_head_ack "${commit_id:0:8}" B; exit 0; fi

# (C) Issue-comment body SHA: bots like Greptile update a single comment with
# a "Last reviewed commit: [sha](.../commit/<sha>)" link instead of submitting
# a new /reviews entry per commit. Parse the body for the most recent commit/<sha>
# link and treat it as authoritative if it matches HEAD.
body_sha=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.comments[] | select(.author.login == $login or .author.login == $login_bot)] | last | .body // empty' 2>/dev/null \
  | grep -oE 'commit/[a-f0-9]{7,40}' | sed 's|.*/||' | tail -1 | cut -c1-8)
if [ -n "$body_sha" ] && [ "$body_sha" = "$HEAD_SHA" ]; then emit_head_ack "$body_sha" C; exit 0; fi

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
if [ -n "$check_run_head" ] && [ "${check_run_head:0:8}" = "$HEAD_SHA" ]; then emit_head_ack "${check_run_head:0:8}" D; exit 0; fi

# (E) /commits/{sha}/statuses: bots using the legacy commit-statuses API.
# CodeRabbit free-tier on private repos posts here instead of registering a
# check-run, so Tier D's app.slug match misses them entirely (the previous
# failure mode that forced admin-merge on PR #160). The login → status-context
# mapping is explicit because context strings are vendor-defined and don't
# follow a derivable slug convention. Statuses are inherently for HEAD_SHA
# (the fetch URL is /commits/$HEAD_SHA/statuses), so a success state IS a
# HEAD-ack — no separate SHA comparison needed.
#
# Latest-wins selection: bots emit `pending → success` (or `pending → failure`)
# during review. Primary sort key is `created_at`; secondary key is `id`
# (status IDs are monotonically increasing). The id tiebreaker matters because
# GitHub timestamps are second-resolution — two statuses posted in the same
# second would otherwise rely on stable-sort input order, which `gh api
# --paginate` does not guarantee. A bot whose latest state is `success` exits
# here with HEAD-ack. A bot whose latest state is non-empty non-success
# (`pending`/`failure`/`error`) exits here with `stale` (live signal must
# gate the merge). Only when there's no matching status entry at all (the
# bot has a mapped context but `last | .state` returns empty) does Tier E
# fall through to the next checks; whether the script then lands on `none`
# or `stale` depends on the bot's /reviews history.
#
# `.[]?` (with the safe-iteration operator) on the outer slurped array tolerates
# pages whose top-level is null/missing (defensive against any future
# `gh api --paginate` shape drift); the inner `.[]?` skips empty/non-array
# pages. The pattern matches Tier D's defensive style.
#
# Add bots that post via commit-statuses (no check-run registered) to the
# case below. The default arm (`*) status_context=""`) plus the `-n` guard
# makes any unmapped login a no-op — safe-by-default for additions.
#
# Empty input guard: in-flight upgrades where a caller hasn't been updated
# to fetch ALL_STATUSES export an empty string. The `-n` check makes Tier E
# a no-op in that case, preserving pre-Tier-E semantics for unupgraded callers.
status_context=""
case "$login" in
  coderabbitai) status_context="CodeRabbit" ;;
esac
if [[ -n "$status_context" && -n "$ALL_STATUSES" ]]; then
  status_state=$(printf '%s' "$ALL_STATUSES" | jq -rs --arg ctx "$status_context" \
    '[.[]? | .[]? | select(.context == $ctx)] | sort_by(.created_at, .id) | last | .state // empty' 2>/dev/null || echo "")
  if [[ "$status_state" == "success" ]]; then emit_head_ack "${HEAD_SHA:0:8}" E; exit 0; fi
  # Non-success states (pending, failure, error) mean the bot HAS signaled
  # something about HEAD — it's either mid-review or actively flagging.
  # Without this branch, a statuses-only bot in pending/failure state would
  # fall through to the empty-commit_id `none` early-return below and the
  # gate would silently treat the live signal as "bot doesn't operate here".
  # Emit `stale` so the merge gate correctly blocks. A bot WITH /reviews
  # history that's also in pending state still falls through to the
  # downgrade block (which handles the existing one-and-done semantics) —
  # the explicit `-n` check on $status_state means an empty/missing status
  # context for a different bot doesn't trip this branch.
  if [[ -n "$status_state" ]]; then echo "stale"; exit 0; fi
fi

# (F) Codex reactions are resolved in the CONSOLIDATED Codex block under Tier A
# above (fresh 👍 → ack, outdated → stale, resolved-current → ack, engaged →
# stale), gated by the hoisted 👀 eyes-override at the top. There is no separate
# Codex tier here — a Codex login that reaches this point fell through with no
# reaction and no actionable thread, so it lands on the `none`/downgrade logic
# below exactly like a bot that never posted.

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
  #     Newlines are normalized to spaces by the `gsub("\n"; " ")` in the
  #     read block above (where `last_body` is assigned) before this regex
  #     runs. Semantic anchor — absolute line shifts when resolver/comment
  #     blocks are added.
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
  # SHA reference) exit via the empty-commit_id/empty-body_sha early-return
  # between Tier D and this downgrade block with `none` before reaching here.
  # Case 3 only applies to bots that have at least one prior /reviews entry
  # in COMMENTED state. Citing the semantic anchor instead of an absolute
  # line number — the line shifts when resolver/comment blocks are added
  # (same brittle-line-number trap fixed in Tests 18 and 25's docstrings).
  check_run_skipped_head_count=$(printf '%s' "$ALL_CHECK_RUNS" | jq -rs --arg login "$login" --arg head8 "$HEAD_SHA" \
    '[.[].check_runs[] | select(.app.slug == $login) | select(.conclusion == "skipped") | select((.head_sha[0:8]) == $head8)] | length' 2>/dev/null || echo 0)
  if [ "$check_run_skipped_head_count" -gt 0 ] && [ "$last_state" = "COMMENTED" ] && [ -z "$body_sha" ] && \
     { [ -z "$last_body" ] || \
       printf '%s' "$last_body" | grep -qiE '(no issues? found|no concerns|all good|looks good|lgtm|nothing to (add|report)\b)'; }; then
    echo "none"; exit 0
  fi
fi

echo "stale"
