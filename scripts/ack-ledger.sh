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
#      of the push event that landed HEAD_SHA on the branch and is the PREFERRED
#      freshness anchor for Tier F's +1 (👍) ack: a +1 acks HEAD only when it
#      postdates the anchor. HEAD_CHECKS_DATE (UTC ISO-8601, #269) is the earliest
#      check-SUITE created_at for HEAD_SHA, used ONLY as a fallback anchor when
#      HEAD_PUSH_DATE is empty — the new-branch case where the first push CREATED the ref
#      (GitHub emits a CreateEvent, not a PushEvent, so no PushEvent exists). GitHub stamps
#      the suite created_at when HEAD is pushed and it is queried per-SHA
#      (commits/<HEAD>/check-suites), so it is SHA-BOUND and — unlike a check-RUN started_at
#      or the committer date — NOT client/app-settable. Both anchors are GitHub
#      server-stamped (never the backdatable committer date), so the fallback preserves the
#      #186/#189 anti-backdating posture; the +1 path FAILS CLOSED (→ stale) only when BOTH
#      are absent — mirroring the resolved-thread path below.
#      HEAD_COMMITTED_DATE
#      (HEAD's `commit.committer.date`, UTC ISO-8601) is RETAINED in the input
#      contract (still accepted/exported, best-effort) but is NO LONGER a Tier-F
#      freshness anchor and does not gate FETCH_OK: the git committer date is
#      client-stamped and backdatable, so it must not gate an automated merge ack.
#      NOTE — the Codex RESOLVED-thread ack (Tier A.2, below) shares this contract: it
#      anchors on the same HEAD_PUSH_DATE || HEAD_CHECKS_DATE resolution (never the
#      backdatable committer date) and FAILS CLOSED (→ stale) when BOTH are absent
#      (#186/#269). It also requires
#      ALL_THREADS to carry, per thread, `resolvedBy { login }` and a
#      `resolutionComments: comments(last:10) { nodes { author { login } createdAt } }`
#      alias (the resolver-authored resolution-time signal for #187). Callers that
#      omit those fields get no resolved-thread ack → stale (additive, safe).
#   3. `export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_SHA`
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
# Content-identity carry-forward (the SHA-anchored tiers B, C, D): a bot ack
# recorded against SHA_old still HEAD-acks when SHA_old is git-provably
# content-identical to HEAD_SHA — same tree AND same parents, i.e. a message-only
# `git commit --amend` + force-push (commitlint fix, DCO sign-off, GPG re-sign,
# message typo). See acks_head() below for the full rationale and threat model.
# This is timestamp-FREE (proven from git object hashes, not backdatable date
# claims) and fails CLOSED. Without it, a fresh SHA with zero code delta makes
# every SHA-anchored tier miss and the gate poll-then-bail at --max-wait every
# time (the bots won't re-post acks when there is nothing new to re-review).
# Tier D (check-runs) is fetched HEAD-scoped, so the pre-amend check-run is invisible
# HERE; its carry-forward is completed by the caller-side scripts/augment-equiv-acks.sh,
# which appends the content-identical predecessor's check-runs BEFORE this ledger runs
# (this ledger then re-proves identity via acks_head — defense in depth). Tier E
# (commit-status) is NOT carried forward (a status carries no SHA to re-prove, and an
# appended predecessor success could override a HEAD pending/failure); it stays
# correct on its own HEAD-scoped fetch. The Codex tiers (A.2 / F) are timestamp/
# reaction-anchored (#186/#189) and not carried forward. Disable carry-forward with
# ACK_CONTENT_IDENTITY=0.
#
# Tier exposure (opt-in via ACK_EMIT_TIER=1): when set, a HEAD-ack SHA is
# suffixed ":<tier>" where <tier> is the letter A–F of the tier that produced
# the ack (A=inline threads — non-Codex disposed thread, or Codex resolved-current
# thread proven via the push-anchored resolver-last-comment signal (A.2); B=/reviews
# on HEAD, C=issue-comment body
# SHA, D=check-run success, E=commit-status success, F=Codex 👍 reaction newer
# than HEAD_PUSH_DATE — the push event time; fails closed when absent, #189).
# `none`/`stale` are NEVER
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
# HEAD_PUSH_DATE, HEAD_CHECKS_DATE, HEAD_SHA)
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

# acks_head <candidate_sha> — returns 0 (true) when a bot's ack recorded against
# <candidate_sha> still covers the current HEAD ($HEAD_SHA), via EITHER:
#   (1) DIRECT MATCH — <candidate_sha>'s 8-char prefix == $HEAD_SHA. This is the
#       pre-fix behavior and short-circuits BEFORE any git call, so the common
#       (no-force-push) path is byte-for-byte identical and git-free.
#   (2) CONTENT IDENTITY — git PROVES <candidate_sha> has the SAME tree AND the
#       SAME parent set as $HEAD_SHA. That is exactly a message-only
#       `git commit --amend` + force-push (commitlint header fix, DCO sign-off,
#       GPG re-sign, commit-message typo): identical reviewable bytes against an
#       identical base, only the SHA (and commit metadata) changed. A bot that
#       acked <candidate_sha> reviewed the byte-for-byte code now at HEAD, so its
#       ack carries forward. Without this, a fresh SHA with zero code delta makes
#       every SHA-anchored tier (B/C/D) miss; the bots won't re-post acks (nothing
#       to re-review), and the gate polls then bails at --max-wait every time.
#
# WHY THIS DOES NOT WEAKEN THE GATE'S ANTI-BACKDATING POSTURE (#186/#189):
#   The timestamp tiers distrust committer/push dates because they are CLAIMS an
#   attacker can backdate. Content identity is not a claim — it is proven from
#   git object hashes: the tree SHA is a Merkle hash of the full snapshot, and
#   the parents are pinned. An attacker cannot present a different-but-"identical"
#   tree without a SHA collision. The only fields free to differ are commit
#   metadata (message / author / dates / signature) — none of which is code a
#   reviewer bot gates on. Parent-pinning REJECTS rebases (a changed base => the
#   reviewed diff differs => fall through to the bot's normal `stale`), confining
#   carry-forward to the exact amend-without-rebase class.
#
# FAILS CLOSED: empty/malformed (non-hex) candidate, git unavailable, either
#   object missing from the LOCAL repo (fresh clone / gc'd old SHA), or any
#   tree/parent mismatch => return 1, so the caller keeps its pre-fix code path
#   (=> `stale`). Set ACK_CONTENT_IDENTITY=0 to disable carry-forward (kill switch).
acks_head() {
  local cand ref _ah_cand_tree _ah_head_tree _ah_cand_par _ah_head_par
  cand="${1:-}"
  [ -n "$cand" ] || return 1
  # Sanitize FIRST: a commit SHA is hex, 7–64 chars (40 for SHA-1, 64 for SHA-256
  # repos). The candidate is derived from bot-controlled API payloads, so reject
  # anything else BEFORE it reaches git — a value like `-O` or `--upload-pack=...`
  # would otherwise be an argument-injection vector into `git rev-parse`/`git show`.
  # A non-hex value can never equal the hex $HEAD_SHA either, so this cannot reject
  # a legitimate direct match.
  case "$cand" in *[!0-9A-Fa-f]*) return 1 ;; esac
  { [ "${#cand}" -ge 7 ] && [ "${#cand}" -le 64 ]; } || return 1
  # (1) Direct match — old behavior, NO git. Common case exits here.
  [ "${cand:0:8}" = "$HEAD_SHA" ] && return 0
  # (2) Content identity — opt-out + git-availability gates, then prove it.
  [ "${ACK_CONTENT_IDENTITY:-1}" = "1" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  # Resolve both to tree objects present in the LOCAL repo; absent => fail-closed.
  # Anchor on the FULL head OID ($HEAD_FULL_SHA, exported by fetch-pr-state.sh)
  # when available, so the proof never hinges on 8-char-prefix uniqueness in a
  # large repo; fall back to the 8-char $HEAD_SHA (still fail-closed if unresolvable).
  # Either way the reference is the SHA the gate is evaluating, NOT live `HEAD`,
  # so a concurrent checkout move can't shift it.
  ref="${HEAD_FULL_SHA:-$HEAD_SHA}"
  _ah_cand_tree=$(git rev-parse --verify --quiet "${cand}^{tree}" 2>/dev/null) || return 1
  _ah_head_tree=$(git rev-parse --verify --quiet "${ref}^{tree}" 2>/dev/null) || return 1
  [ -n "$_ah_cand_tree" ] && [ "$_ah_cand_tree" = "$_ah_head_tree" ] || return 1
  # Pin the base too: identical tree AND identical parents == amend-without-rebase.
  # `%P` yields the space-joined parent hashes (EMPTY for a root commit) — do NOT
  # use `rev-list --parents | cut -f2-`, which echoes the whole line back when a
  # commit is parentless (no delimiter), falsely making a root commit look like
  # its own parent.
  _ah_cand_par=$(git show -s --format=%P "$cand" 2>/dev/null) || return 1
  _ah_head_par=$(git show -s --format=%P "$ref" 2>/dev/null) || return 1
  [ "$_ah_cand_par" = "$_ah_head_par" ]
}

# _fresh_rate_limit_notice — true (0) iff the bot's CANONICAL-LATEST issue comment
# is a fresh (strictly post-anchor) CodeRabbit rate-limit NOTICE. Single source of
# truth shared by Tier E's non-success guard (#294) and the Case 1b downgrade, so a
# rate-limited bot is classified identically whether it surfaced via a legacy
# commit-status or only via issue comments. Self-contained: reads $login,
# $ALL_COMMENTS, and the push/checks anchor globals.
#
# Guards (all must hold) keep this from ever reading findings prose as a notice:
#   - notice-only regex ($rate_notice_re) — the exact review-limit wording, NOT the
#     broader review-object infra_error_re (Codex P2s, PR #292).
#   - canonical-latest only (max createdAt) — an older stale notice can't win while
#     the bot's current comment is an actionable finding.
#   - anchor-freshness — the comment must postdate the push that landed HEAD
#     (HEAD_PUSH_DATE || HEAD_CHECKS_DATE, #269); the same server-stamped,
#     non-backdatable signals used elsewhere. Fail CLOSED (return 1) when neither
#     anchor is present — an unanchored notice cannot be proven current.
# Callers additionally gate on ever_approved==0 (a bot that ever approved is never
# silently downgraded).
_fresh_rate_limit_notice() {
  local anchor rate_notice_re
  anchor="${HEAD_PUSH_DATE:-}"
  [ -z "$anchor" ] && anchor="${HEAD_CHECKS_DATE:-}"
  [ -n "$anchor" ] || return 1
  rate_notice_re='review limit reached|reached your [^.]{0,40}review limit|try again by re-requesting'
  printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" --arg anchor "$anchor" \
    '[.comments[] | select(.author.login == $login or .author.login == $login_bot)]
     | sort_by(.createdAt) | last
     | select(. != null and .createdAt > $anchor)
     | .body // empty' 2>/dev/null \
    | grep -qiE "$rate_notice_re"
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
  # Effective freshness anchor (#269): prefer HEAD_PUSH_DATE (push event) unchanged;
  # fall back to HEAD_CHECKS_DATE (earliest check-SUITE created_at for HEAD_SHA) ONLY when
  # HEAD_PUSH_DATE is empty — the new-branch case where the first push CREATED the ref so
  # GitHub emitted a CreateEvent, not a PushEvent, and a genuine fresh 👍 would otherwise
  # fail-close forever. The suite created_at is GitHub-stamped on push AND SHA-bound (queried
  # per-SHA), so — like the push anchor and unlike the committer date — it is not client/app-
  # settable and keeps the #186/#189 posture. Used by BOTH the +1 path (Tier F) and the
  # resolved-thread path (Tier A.2) below; fails CLOSED to stale only when BOTH are empty.
  anchor_date="${HEAD_PUSH_DATE:-}"
  [ -z "$anchor_date" ] && anchor_date="${HEAD_CHECKS_DATE:-}"
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
  # Freshness anchor: $anchor_date (HEAD_PUSH_DATE, or HEAD_CHECKS_DATE fallback for a
  # brand-new branch, #269) — NEVER the git committer date. The committer date is
  # client-stamped and backdatable: force-push an old commit whose committer date predates
  # a leftover +1 and that +1 would look "fresh" → a false HEAD-ack on un-re-reviewed code
  # (#189). So a +1 acks ONLY when a server-stamped anchor exists AND the +1 postdates it.
  # When $anchor_date is absent (fork head, events API delayed / aged-out >90d / capped
  # >300 events, and no check-suite either) there is no trustworthy anchor → DO NOT ack;
  # fall through to stale (fail-CLOSED). This matches the resolved-thread sibling below
  # (#186) — uniform fail-closed, no committer fallback, no sentinel. The hoisted
  # eyes-override above and Tier A.2 (anchored resolved-current) cover the active-re-review
  # and out-of-scope-clear cases; a genuinely outdated finding with no anchor SHOULD wait
  # for re-review (operator-visible --max-wait), which is correct, not a regression.
  if [[ -n "$codex_plus1" && -n "$anchor_date" && "$codex_plus1" > "$anchor_date" ]]; then
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
  #     (i)  SERVER-STAMPED ANCHOR ONLY. This path anchors on $anchor_date — the push
  #          that landed HEAD (HEAD_PUSH_DATE), or the earliest check-SUITE created_at for
  #          HEAD_SHA (HEAD_CHECKS_DATE, #269 — SHA-bound, GitHub-stamped) — NEVER
  #          max(committer, push). The committer date is attacker-controllable —
  #          force-push an older commit with a backdated committer date and a stale
  #          resolution looks newer than HEAD — so it must not gate a resolved-thread
  #          ack; both anchor sources are GitHub server-stamped, so the fallback keeps
  #          that posture. When $anchor_date is empty (fork head, events API
  #          delay/aged-out with no check-suite, or an unupgraded caller) there is no
  #          trustworthy anchor → DO NOT ack; exit stale (fail-CLOSED). This REVERSES
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
  #          Timestamp contract: createdAt and $anchor_date are both GitHub-emitted
  #          UTC 'Z'-form ISO-8601, so lexicographic > is a correct time comparison.
  #          resolutionComments uses comments(last:10): a resolver reply evicted from
  #          that window (>10 trailing comments) yields no match → stale (fail-CLOSED).
  #          A caller that omits resolvedBy/resolutionComments → no match → stale (safe).
  #     ALL-OR-STALE: the ack fires only when EVERY resolved+non-outdated Codex thread
  #     is proven fresh. If even one is unproven it forces stale — a stale resolved
  #     thread must never be masked by a fresh sibling (mirrors the (2) outdated
  #     precedence). A thread is "proven fresh" iff $anchor_date is present, resolvedBy
  #     is set and is not the finding bot, and the thread's LAST comment is resolver-
  #     authored and strictly newer than $anchor_date.
  codex_resolved_any=$(printf '%s' "$ALL_THREADS" | jq -rs \
    --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == $login or .comments.nodes[0].author.login == $login_bot)
      | select(.isResolved == true and .isOutdated == false)
    ] | length' 2>/dev/null || echo 0)
  if [ "${codex_resolved_any:-0}" -gt 0 ]; then
    # (The outer `codex_resolved_any > 0` guard already closed PR #185's fail-OPEN-to-
    # `none` — a resolved Codex thread can no longer fall through to the `none` early-
    # return.) Here: no anchor (neither push nor check-suite) → nothing can be proven
    # fresh → stale (#186/#269 fail-CLOSED).
    if [ -z "$anchor_date" ]; then echo "stale"; exit 0; fi
    # Count resolved+non-outdated threads that are NOT proven fresh (the negation of the
    # freshness predicate). Any > 0 → stale, so one stale resolution blocks the whole ack.
    # Fail-CLOSED on jq error: this query indexes resolvedBy/resolutionComments, which the
    # codex_resolved_any count does NOT — so malformed thread JSON (e.g. resolvedBy not an
    # object) could break ONLY this query. Defaulting its error case to codex_resolved_any
    # (which is > 0 here) forces stale instead of a false ack, preserving the file's
    # fail-CLOSED-on-error invariant.
    codex_resolved_unproven=$(printf '%s' "$ALL_THREADS" | jq -rs \
      --arg login "$login" --arg login_bot "${login}[bot]" \
      --arg push "$anchor_date" \
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
if [ -n "$commit_id" ] && acks_head "$commit_id" && [ "$login" != "chatgpt-codex-connector" ]; then emit_head_ack "$HEAD_SHA" B; exit 0; fi

# (C) Issue-comment body SHA: bots like Greptile update a single comment with
# a "Last reviewed commit: [sha](.../commit/<sha>)" link instead of submitting
# a new /reviews entry per commit. Parse the body for the most recent commit/<sha>
# link and treat it as authoritative if it matches HEAD.
body_sha=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
  '[.comments[] | select(.author.login == $login or .author.login == $login_bot)] | last | .body // empty' 2>/dev/null \
  | grep -oE 'commit/[0-9a-fA-F]{7,64}' | sed 's|.*/||' | tail -1)
if [ -n "$body_sha" ] && acks_head "$body_sha"; then emit_head_ack "$HEAD_SHA" C; exit 0; fi

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
if [ -n "$check_run_head" ] && acks_head "$check_run_head"; then emit_head_ack "$HEAD_SHA" D; exit 0; fi

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
#
# ever_approved / last_state / last_body are read HERE (hoisted above Tier E for
# #294) so Tier E's non-success guard below and the Case 1b downgrade block share
# one parse. Rationale for the APPROVED/DISMISSED/CHANGES_REQUESTED classification
# set is documented at the "Three-case downgrade" comment below, where these vars
# are consumed. The FETCH_OK guard at the top already returned `stale` on any
# source-fetch failure, so this parse only runs on successful fetches.
{ read -r ever_approved; read -r last_state; read -r last_body; } < <(
  printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[ .[] | .[] | select(.user.login == $login or .user.login == $login_bot) ]
     | ( (map(select(.state == "APPROVED" or .state == "DISMISSED" or .state == "CHANGES_REQUESTED")) | length),
         (last | .state // ""),
         (last | .body // "" | gsub("\n"; " ")) )' 2>/dev/null \
  || printf '0\n\n\n'
)

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
  #
  # #294 exemption: a rate-limited CodeRabbit posts its "review limit reached"
  # NOTICE as an issue comment while its legacy commit-status for HEAD is
  # non-success (pending/failure/error). Without this guard the non-success
  # `stale` short-circuits BEFORE the Case 1b issue-comment scan can run, so the
  # bot stays `stale` forever and pr-grind waits for a review the rate-limited
  # bot cannot deliver — the exact case Case 1b exists to downgrade. Fall through
  # to the downgrade block ONLY when the bot never approved (ever_approved==0) AND
  # its canonical-latest issue comment is a proven-fresh rate-limit notice — the
  # identical guards Case 1b already applies, so this cannot reclassify findings
  # prose. Every other non-success state still gates (`stale`).
  if [[ -n "$status_state" ]]; then
    if [ "$ever_approved" -eq 0 ] && _fresh_rate_limit_notice; then
      : # fall through → Case 1b downgrade block emits `none`
    else
      echo "stale"; exit 0
    fi
  fi
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
# ever_approved / last_state / last_body were parsed above Tier E (hoisted for
# the #294 non-success guard); they are consumed here unchanged.
if [ "$ever_approved" -eq 0 ]; then
  # TWO separate regexes for two different surfaces — deliberately NOT shared.
  # Case 1 scans a bot's last /reviews OBJECT body, where a review-object infra
  # error is canonical (Copilot's "encountered an error and was unable to
  # review"). Case 1b scans a bot's latest ISSUE COMMENT, which is also where a
  # bot posts actionable FINDINGS prose — so it must match ONLY the shape of a
  # rate-limit NOTICE, never generic review-object phrases. Sharing one regex
  # let review-object phrases ("unable to review", "encountered an error") leak
  # into the issue-comment scan and match findings like "Users are unable to
  # review invoices after this change" (three successive Codex P2s on PR #292).
  #
  # Case 1 (/reviews body): the ORIGINAL broad review-object infra-error set,
  # including bare `rate.?limit`. A frozen /reviews infra-error object ("Rate
  # limited. Please try later", Copilot's "encountered an error and was unable
  # to review") is a review OBJECT that errored, not findings prose, so the
  # broad match is safe and desirable here — narrowing it would let an
  # un-clearable infra-error body fall through to `stale` and wait forever
  # (fifth Codex P2 on PR #292). This is the pre-split behavior, unchanged;
  # only Case 1b (issue comments) needs the strict notice-only regex below.
  infra_error_re='encountered an error|rate.?limit|unable to review|try again by re-requesting'
  # Case 1b (issue comment): CodeRabbit rate-limit-NOTICE wording ONLY. Scoped to
  # the specific phrases CodeRabbit's review-limit notice emits — "Review limit
  # reached", "reached your … review limit", "try again by re-requesting" — none
  # of which appears in normal findings prose. The generic `rate limit
  # exceeded|reached` alternative was deliberately dropped: it added no coverage
  # of the real notice (which uses the review-limit wording above) yet matched
  # findings like "handle the rate limit exceeded response" (fourth Codex P2 on
  # PR #292). Case 1b exists specifically for CodeRabbit's issue-comment notices
  # (44/47 of the Jun–Jul 2026 events), so notice-specific wording is correct,
  # not over-fitting. The regex itself lives in _fresh_rate_limit_notice().
  # Case 1: infra-error / rate-limit — Copilot's "encountered an error and
  # was unable to review" review object is the canonical case. GitHub leaves
  # it frozen on the SHA where it errored, never updates commit_id on later
  # pushes, and there's no gh-CLI surface to clear it (DELETE only works on
  # pending reviews; requested_reviewers POST 422s for Copilot). Treating
  # those as `stale` blocks the merge gate forever; downgrade to `none` so
  # the loop surfaces the situation to the operator instead of looping in
  # vain.
  if printf '%s' "$last_body" | grep -qiE "$infra_error_re"; then
    echo "none"; exit 0
  fi
  # Case 1b: issue-comment infra-error / rate-limit — CodeRabbit posts its
  # rate-limit notices as ISSUE COMMENTS, not /reviews bodies (44 of 47 limit
  # events observed Jun–Jul 2026 were issue comments), so `last_body` above
  # never sees them and the ledger loops in vain (each wait-round costs ~15 min
  # and risks a max-wait bail) for a review the rate-limited bot will not
  # deliver.
  #
  # The detection (canonical-latest issue comment, notice-only regex, strict
  # post-anchor freshness, fail-closed when unanchored) lives in
  # _fresh_rate_limit_notice() so Tier E's #294 non-success guard and this Case 1b
  # downgrade classify a rate-limited bot identically. Same ever_approved==0 outer
  # guard as Case 1. Also reachable via fall-through from Tier E when CodeRabbit's
  # legacy commit-status for HEAD is non-success (#294).
  if _fresh_rate_limit_notice; then
    echo "none"; exit 0
  fi
  # Case 2: one-and-done COMMENTED — bot reviewed a prior commit with a
  # non-actionable PR-overview summary (state=COMMENTED, not APPROVED/
  # CHANGES_REQUESTED), then never re-fired despite HEAD advancing. Canonical
  # Copilot pattern: it posts a PR-overview summary on the initial commit and
  # doesn't auto-trigger on later non-force pushes; the re-request API 422s
  # so the operator has no recourse. By the time we reach this block we know:
  # (1) FETCH_OK=1, (2) no unresolved threads from this bot (Tier A would
  # have returned `stale` at the top), (3) `commit_id` is non-empty AND
  # `acks_head(commit_id)` is false — it neither 8-char-matches HEAD_SHA nor is
  # content-identical to HEAD (Tier B would have returned the SHA otherwise),
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
