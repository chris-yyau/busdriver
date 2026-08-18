#!/usr/bin/env bash
# scripts/ack-ledger.sh — canonical per-bot ack computation for pr-grind.
#
# Single source of truth for the five-tier ack ledger algorithm. Replaces
# three previously inlined function definitions that had to be kept in
# byte-for-byte lockstep:
#   - agents/pr-grinder.md   Step 6.5      ack_for_bot()
#   - skills/pr-grind/SKILL.md Step 6.5    inline_ack_for_bot()
#   - skills/pr-grind/references/completion.md  dispatcher_ack_for_bot()
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
# suffixed ":<tier>" where <tier> is the letter A–G of the tier that produced
# the ack (A=inline threads — non-Codex disposed thread, or Codex resolved-current
# thread proven via the push-anchored resolver-last-comment signal (A.2); B=/reviews
# on HEAD, C=issue-comment body
# SHA, D=check-run success, E=commit-status success, F=Codex 👍 reaction newer
# than HEAD_PUSH_DATE — the push event time; fails closed when absent, #189;
# G=Codex clean-verdict issue comment whose "**Reviewed commit:**" line names
# HEAD — SHA-keyed, so no timestamp anchor, #690).
# `none`/`stale` are NEVER
# suffixed. Default (env unset) output is byte-for-byte unchanged, so existing
# callers that compare the value to HEAD_SHA or to `stale` are unaffected. The
# dispatcher's Invariant 3 uses tiers D/E (bodyless structured acks) to exempt a
# HEAD-acked bot from the n_total>=1 coverage gate — see ADR 0001 and
# skills/pr-grind/SKILL.md. Soundness: tier order is A→E for non-Codex bots, and
# A.1→G→F→A.2→C→D→E for Codex (Tiers F and G are Codex-only; B is excluded for
# Codex; G evaluates early — immediately after the live-thread check and before
# the eyes-override — because a comment-form verdict leaves the 👀 in place, and
# a Codex comment that G declined then blocks every tier below it, so a leftover
# 👍 cannot ack past a comment-form finding, #690),
# returning at the first HEAD-ack, and Tier A returns
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
# $1 = 8-char SHA, $2 = tier letter (A–G). Centralizes the suffix so all six
# HEAD-ack exit points stay consistent. Default output is byte-identical to the
# pre-tier contract; only opt-in callers see the suffix.
emit_head_ack() {
  if [ "${ACK_EMIT_TIER:-0}" = "1" ]; then
    printf '%s:%s\n' "$1" "$2"
  else
    printf '%s\n' "$1"
  fi
}

# num_or <value> <fallback> — echo <value> when it is a bare non-negative integer,
# else <fallback>. Every count in this file comes from `jq ... || echo N`, and jq
# can also SUCCEED with empty output on a schema drift, which leaves `[ "$x" -gt 0 ]`
# a bash error (rc=2, "integer expected") that a script without `set -e` sails
# straight past — the fail-OPEN shape #364 hit on FETCH_OK. Callers pass the
# FAIL-CLOSED value as <fallback>: the count that makes the tier block.
num_or() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# json_shape_ok <payload> <jq-predicate> — echo 1 when <payload> slurps to a
# NON-EMPTY stream whose every record satisfies <jq-predicate>, else 0 (including
# on any jq error). Existence-testing a source variable is not enough to trust it:
# `null`, `{}` and `oops` are all non-empty strings, and `jq -rs` turns each into
# a stream that yields zero records with exit status 0 — so an UNREAD source
# reports exactly what a genuinely quiet one reports. Callers that draw a
# conclusion from a count of zero must confirm the shape first.
#
# The predicate has to reach the FIELDS the count indexes, not just the outer
# container: `[{}]` is a perfectly good array whose records match no login and
# carry no timestamp, so a container-only check would still hand back a vacuous
# zero — and neither does `.user: {}`, which passes an outer `has("user")` while
# `.user.login` reads null and the record silently drops out of the count.
#
# Require PRESENCE, not a value, on the identity fields, and distinguish the two
# ways a field can be "missing": `user: null` / `author: null` is what GitHub
# legitimately emits for a DELETED account, so it must parse (the record simply
# is not Codex's and drops out of the count on its own merits); `user: {}` or an
# absent key is drift, and blocks. Demanding a non-null author instead would fail
# this tier CLOSED forever on any PR a deleted account ever touched — a worse bug
# than the drift it guards. Presence is the line to draw because every field named
# here is one GitHub always emits for the shape being queried.
#
# Timestamps are the exception that DOES get a type check, because the comparisons
# they feed are lexicographic: jq sorts every number before every string, so a
# numeric `created_at` would silently read as older than any ISO-8601 date and the
# at-or-after guards would count zero. String or null (the `// "9999"` default
# handles null); anything else is drift.
# <jq-predicate> is an internal constant, never caller data.
# `$ts` is bound for predicates that validate a GitHub timestamp: exactly the
# UTC 'Z' ISO-8601 form every GitHub API emits. Type alone is not enough — the
# comparisons downstream are lexicographic, and the string "0" is a perfectly
# good string that sorts before every real date.
#
# The calendar fields are RANGE-BOUND, not just digit-counted. `9999-99-99T99:99:99Z`
# has the right shape and sorts after every real date, which is precisely the value
# that would suppress an at-or-after guard — so a positional check alone reproduces
# the bug it is meant to close. (Feb 30th still passes; the goal is to bound the
# ORDERING, not to implement a calendar.)
GH_TS_RE='^20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'


# A Codex comment that is an un-clearable INFRA NOTICE, not a review. Codex posts
# `To use Codex here, [create an environment for this repo](…)` on a repo it has
# no environment for; it is not a verdict, not a finding, and — critically — the
# nudge cannot clear it, because Codex genuinely cannot review the PR until an
# operator configures the environment. Every Codex-comment query below filters
# these out, so a repo in that state falls through to the `none` early-return
# (non-gating) instead of blocking on a review that will never arrive.
#
# This is the same call `ack-ledger.sh` already makes for review objects at
# Case 1 / Case 1b (`infra_error_re`, `_fresh_rate_limit_notice`) — an infra
# marker the bot cannot self-clear downgrades rather than staling forever. Those
# cases live in the downgrade block far below, which the Codex comment branches
# (added for #690) return long before reaching, so the exemption has to be
# applied here or the precedent silently does not cover comment-form Codex.
#
# START-ANCHORED and notice-specific, exactly as Case 1b is: this filter REMOVES
# evidence from a merge gate, so it must never match findings prose that merely
# discusses environments. Same reasoning as Tier G's own template anchor.
CODEX_NOTICE_RE='^To use Codex here,'

json_shape_ok() {
  printf '%s' "$1" \
    | jq -rs --arg ts "$GH_TS_RE" \
        "if (length > 0 and all($2)) then \"1\" else \"0\" end" 2>/dev/null || echo 0
}

# ts_ok <string> — 1 when <string> is a GitHub timestamp by the same rule.
ts_ok() {
  printf '%s' "$1" | jq -Rr --arg ts "$GH_TS_RE" \
    'if test($ts) then "1" else "0" end' 2>/dev/null || echo 0
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
# truth shared by Tier E's status guard (#294 non-success + #353 success) and the
# Case 1b downgrade, so a rate-limited bot is classified identically whether it
# surfaced via a legacy commit-status — in ANY state, since a rate-limited bot may
# report `success` while saying it never started — or only via issue comments.
# Self-contained: reads $login,
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
# Notice signatures. CodeRabbit emits two observed shapes:
#   (A) "Review limit reached" / "you've reached your PR review limit"   (#292, #353)
#   (B) "Rate limit exceeded. Please try again by re-requesting a review." (#292)
#
# (A) is self-identifying — the wording exists only in the notice.
#
# (B) is not: both halves are ordinary prose about rate-limiting code. The head
# (`rate limit exceeded`) was already dropped as a lone signal — it matched "handle
# the rate limit exceeded response" (Codex P2, PR #292). The tail ("try again by
# re-requesting") is likewise ordinary advice. So (B) requires BOTH, body-scoped.
#
# ── Why body-scoped, and not tighter ──────────────────────────────────────────────
# This predicate CANNOT be made exact: prose does not reliably self-identify. So the
# question is which error to prefer, and the two directions are NOT symmetric.
#
#   MISS (notice read as a review)  → HEAD-ack. This IS the #353 fail-open: the
#     ledger asserts a review that never happened. UNSAFE.
#   FALSE POSITIVE (finding read as a notice):
#     - ever_approved==0 → `none`. Both `none` and a HEAD-ack are NON-gating
#       (skills/pr-grind/SKILL.md: "`stale` and `none` ack values do NOT trigger this
#       gate"), so the merge outcome is IDENTICAL — only the ledger label differs.
#     - ever_approved>0  → `stale`. Blocks. Strictly SAFER.
#   And a false positive cannot bury an actionable finding: unresolved non-outdated
#   threads exit `stale` at Tier A, far above Tier E (pinned by test 353.13).
#
# ⇒ Recall is safety-critical; precision is nearly free. Prefer the looser matcher.
#
# Tightening was tried and rejected on evidence. Anchoring (B) to a single callout
# line ("[!WARNING] Rate limit exceeded…") missed the CANONICAL GitHub alert, whose
# marker sits on its own line:
#     > [!WARNING]
#     > Rate limit exceeded. Please try again by re-requesting a review.
# — i.e. the tightening reintroduced #353 for the (B) variant to avoid a false
# positive that is provably benign. Body-scoped greps match either rendering, since
# each succeeds if ANY line matches. See test 353.14 (multi-line) and 353.10
# (accepted, benign false positive).
_NOTICE_SELF_RE='review limit reached|reached your [^.]{0,40}review limit'
_NOTICE_RETRY_RE='try again by re-requesting'
_NOTICE_QUOTA_RE='rate.?limit exceeded'

# _body_is_rate_limit_notice <body> — true iff the body is a rate-limit NOTICE.
# Body-scoped by design (see above): each grep succeeds if ANY line matches, so a
# notice split across lines — the canonical GitHub alert shape — still pairs.
_body_is_rate_limit_notice() {
  printf '%s' "$1" | grep -qiE "$_NOTICE_SELF_RE" && return 0
  printf '%s' "$1" | grep -qiE "$_NOTICE_RETRY_RE" \
    && printf '%s' "$1" | grep -qiE "$_NOTICE_QUOTA_RE"
}

# _rate_limit_anchor — the freshness anchor, or empty when neither signal exists.
_rate_limit_anchor() {
  local anchor
  anchor="${HEAD_PUSH_DATE:-}"
  [ -z "$anchor" ] && anchor="${HEAD_CHECKS_DATE:-}"
  printf '%s' "$anchor"
}

# _latest_comment_is_notice <anchor> — does the bot's CANONICAL-LATEST issue comment
# match the notice-only regex? A non-empty <anchor> additionally requires the comment
# to strictly postdate it; an empty <anchor> checks the latest comment regardless of
# age (freshness UNPROVEN — see _unprovable_rate_limit_notice).
#
# TRI-STATE (#364) — the third state is the point:
#   0 = yes, the latest comment is a rate-limit notice
#   1 = clean negative: the source was READ and says otherwise (not a notice, no
#       comments from this bot, or none postdating the anchor)
#   2 = UNDECIDABLE: the notice question could not be answered — jq failed (malformed
#       or shape-drifted payload) or ALL_COMMENTS is absent. A matcher error may also
#       surface here, since grep exits 2 on error and _body_is_rate_limit_notice's
#       status is this function's status; that is BEST-EFFORT, not an invariant — a
#       first-grep error followed by a clean negative from the (B) pair still reads
#       as 1. Unreachable in practice (all three greps run the same tool over the
#       same stdin with constant patterns, so an error in one implies an error in
#       all), and harmless either way: the wider reading is the safe one, because an
#       errored matcher has not proven the body is a review any more than an
#       unreadable one has.
# Collapsing 2 into 1 was #353's shape one layer in: on Tier E's `success` arm the
# fall-through terminal is a HEAD-ack, so an unreadable payload silently re-asserted
# "this bot reviewed HEAD". FETCH_OK guards fetch-level failure; it says nothing about
# a body that arrived and then failed to parse. Callers whose fall-through terminal is
# already `stale` (the non-success arm, Case 1b) may keep treating any non-zero as
# false — for them 1 and 2 are the same fail-CLOSED direction.
_latest_comment_is_notice() {
  local body
  [ -n "$ALL_COMMENTS" ] || return 2
  body=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" --arg anchor "${1:-}" \
    '[.comments[] | select(.author.login == $login or .author.login == $login_bot)]
     | sort_by(.createdAt) | last
     | select(. != null)
     | select($anchor == "" or .createdAt > $anchor)
     | .body // empty' 2>/dev/null) || return 2
  [ -n "$body" ] || return 1
  _body_is_rate_limit_notice "$body"
}

_fresh_rate_limit_notice() {
  local anchor
  anchor="$(_rate_limit_anchor)"
  [ -n "$anchor" ] || return 1
  _latest_comment_is_notice "$anchor"
}

# _unprovable_rate_limit_notice — true iff Tier E's `success` status cannot be taken
# as proof this bot reviewed HEAD. That is EITHER of the two unprovables enumerated
# below: an undecidable comments source (#364, anchor or not), or an anchorless
# canonical-latest notice (#353). Narrow companion to _fresh_rate_limit_notice for
# the one caller whose "closed" direction differs: Tier E's `success` arm.
#
# _fresh_rate_limit_notice returns false without an anchor, which is fail-CLOSED
# only where the fall-through terminal is `stale`. On the success arm the terminal
# is a HEAD-ack, so the same false would assert "this bot reviewed HEAD" on the
# strength of a status the bot's own latest comment contradicts — fail-OPEN.
# Without an anchor we can prove neither that the notice is current NOR that a
# review happened; withholding the ack (→ `stale`) is the only honest answer.
#
# Deliberately NOT used when an anchor exists: there, freshness is decidable, and a
# pre-anchor notice is a spent notice from an earlier round that must not revoke the
# current HEAD's genuine review.
#
# TWO independent unprovables, resolved on one parse (#364 added the first):
#   (1) The comments source is UNDECIDABLE (rc=2). Unprovable REGARDLESS of the anchor:
#       freshness only matters once the body can be read at all, so this is checked
#       BEFORE the anchor short-circuit — the anchor-present path is exactly the one
#       that reached emit_head_ack with a garbled payload.
#   (2) No anchor AND the canonical-latest comment IS a notice (#353): freshness is
#       unprovable, so a review is unprovable too.
# A clean negative (rc=1) is the genuine ack, and so is rc=0 WITH an anchor — there
# _fresh_rate_limit_notice above already ruled the notice spent.
_unprovable_rate_limit_notice() {
  local rc
  _latest_comment_is_notice ""; rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ -n "$(_rate_limit_anchor)" ] && return 1
  return "$rc"
}

# Fail-CLOSED: any source-fetch failure → mark stale (Greptile P1 — fail-OPEN
# regression where API failures silently became `none` and didn't gate).
#
# The test is `!= "1"`, NOT `-eq 0` (#364): the caller must EXPLICITLY assert a good
# fetch, and every other value — unset, empty, non-numeric — fails closed. `-eq 0` is
# an arithmetic test, so an unset/empty FETCH_OK made `[ "" -eq 0 ]` a bash ERROR
# ("integer expected", rc=2) rather than a true condition. With no `set -e` the script
# continued past the guard, read the empty ALL_* sources, and returned `none` for EVERY
# bot — the guard failed OPEN in precisely the case where the caller's state is most
# obviously broken. Observed live during #361's grind: a 0-byte env file zeroed every
# source, and a genuine Tier-B HEAD-ack was reported as `none` (non-gating).
if [[ "${FETCH_OK:-0}" != "1" ]]; then echo "stale"; exit 0; fi

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
    | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null || echo 1)
# Fail CLOSED on a broken count. This query is Tier G's proof that no LIVE finding
# exists on HEAD (#690), so a jq error or schema drift resolving to 0 would let a
# clean comment ack past a live thread the ledger simply failed to read.
unresolved=$(num_or "$unresolved" 1)
if [ "$unresolved" -gt 0 ]; then echo "stale"; exit 0; fi

# (G) Codex clean-verdict COMMENT (#690). Codex's own footer promises "If Codex
# has suggestions, it will comment; otherwise it will react with 👍" — but
# observed live on PR #687 AND PR #688 (2026-08-17, within the same hour), a
# findings-free review can instead arrive as an ISSUE COMMENT naming the SHA it
# reviewed, with no 👍 anywhere and the 👀 left in place. That shape acks through
# NO existing tier: it is not a review (Tier B), opens no thread (Tier A), writes
# no check-run or status (D/E), and carries no reaction (F) — so Codex read
# `stale` forever once its earlier threads went outdated. Both PRs exhausted
# their nudge budget and merged only under an operator skip file.
#
# Freshness here is the SHA ITSELF, not a timestamp: the body names the commit
# Codex reviewed, so no push anchor is consulted and none is needed. Same proof
# shape as Tiers B and C — and, exactly like them, the comparison is `acks_head`,
# which accepts the named SHA OR an ADR 0004 content-identical predecessor (same
# tree AND same parents). So a message-only `--amend` of a reviewed commit does
# carry the verdict forward. That is the settled repo-wide reading of "reviewed"
# (nothing reviewable changed), not an oversight specific to this tier; if it is
# ever revisited it must be revisited for B and C in the same change.
#
# Placement is load-bearing in BOTH directions:
#   BELOW Tier A.1 — a live unresolved+non-outdated Codex thread on this HEAD
#     must always block, even when a clean comment also names HEAD (Codex can
#     re-review the same commit after a nudge and file a finding).
#   ABOVE the eyes-override — comment-form completion does NOT remove the 👀
#     (observed on #687: the eyes from 17:39:45Z outlived clean verdicts at
#     17:43:20Z and 17:50:56Z), so an eyes-first order would swallow this ack in
#     exactly the case it exists to fix. What the eyes-override is really
#     approximating is "a review started after the last thing I know about", so
#     this tier keeps that property PRECISELY instead of ordering around it: it
#     declines when a 👀 is newer than the verdict itself, which is the genuine
#     re-review-in-flight case, while a 👀 that predates the verdict is just the
#     residue of the review that produced it.
#
# Fail-CLOSED matching, three independent narrowings — a findings comment must
# never reach the ack:
#   (i)   LAST Codex comment only (Tier C's semantics). A clean verdict FOLLOWED
#         by a findings comment is not an ack; scanning every comment would let a
#         superseded clean verdict outvote the finding that replaced it.
#   (ii)  The clean TEMPLATE, anchored at the START of the body. Codex's findings
#         comments open "### 💡 Codex Review" and can QUOTE arbitrary text from
#         the diff, so an unanchored search is forgeable by the reviewed code
#         itself. Only the stable prefix is matched: the tail varies ("🚀" on
#         #687, "Swish!" on #688), so pinning the whole line would have matched
#         one PR and missed the other.
#   (iii) The SHA is read ONLY from the "**Reviewed commit:** `<sha>`" line, never
#         by a body-wide hex scan. #688's findings comment embeds HEAD's own SHA
#         in a blob permalink (github.com/.../blob/<sha>/path#L1-L2), so a generic
#         scan would have acked a comment carrying an unaddressed P2 finding.
# Anything else from Codex falls through unchanged → the tiers below, then stale.
# Codex-only and guarded on non-empty ALL_COMMENTS: a strict no-op for every
# other login and for callers not yet upgraded to fetch comments.
if [ "$login" = "chatgpt-codex-connector" ] && [ -n "$ALL_COMMENTS" ]; then
  # A non-empty ALL_COMMENTS this file cannot READ is a BROKEN snapshot, not an
  # absent one: FETCH_OK=1 asserted the fetch succeeded. Validate the SHAPE, not
  # just the syntax — every query below uses `.comments[]?`, whose `?` swallows a
  # schema drift as silently as it swallows a null, so a payload like
  # `{"nodes":[]}` would parse cleanly, yield no comments, and read as "Codex said
  # nothing" (→ `none`, non-gating). The empty string is reserved for the caller
  # that never fetched comments at all, and is guarded above.
  # Validated down to the FIELDS the queries index, and validated HERE rather than
  # at the ack — the post-anchor veto at (0) filters on .author.login and compares
  # .createdAt too, so a drifted record like {"author":{},...} would vanish from
  # its count and let a leftover 👍 ack past an unread comment-form finding.
  # shellcheck disable=SC2016  # single-quoted jq program: the $ts below is a jq
  # variable (bound via --arg in json_shape_ok), not a shell expansion.
  codex_comments_ok=$(json_shape_ok "$ALL_COMMENTS" '(.comments | type) == "array"
    and (.comments | all(has("author")
           and (.author == null
                or ((.author | type) == "object" and (.author.login | type) == "string"))
           and (.createdAt | type) == "string" and (.createdAt | test($ts))
           and (.body | type) == "string"))')
  if [ "$codex_comments_ok" != "1" ]; then echo "stale"; exit 0; fi
  # "The last Codex comment" must be decided by TIMESTAMP, never by document
  # order: `gh pr view --json comments` guarantees no ordering, so a bare `last`
  # would let an older clean verdict supersede a newer, still-live finding
  # (Greptile P2 / CodeRabbit, PR #693).
  #
  # `sort_by(.createdAt) | last` alone does not finish the job, though. jq's sort
  # is STABLE, so comments sharing a timestamp keep their input order — and
  # GitHub timestamps are second-resolution, so a finding and a clean verdict
  # posted in the same second are genuinely tied and `last` silently reverts to
  # the array order this query exists to stop trusting. There is no tiebreaker
  # available worth trusting either: gh exposes the GraphQL node id, which is not
  # monotonic. So a tie is UNRESOLVABLE, and unresolvable means decline —
  # `codex_max_at` is the maximum timestamp (well-defined regardless of order),
  # and the verdict is read only when exactly ONE Codex comment carries it.
  codex_max_at=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    --arg notice "$CODEX_NOTICE_RE" \
    '[.comments[]? | select(.author.login == $login or .author.login == $login_bot)
      | select(((.body // "") | test($notice)) | not) | .createdAt]
     | if length == 0 then empty else max end' 2>/dev/null || echo "")
  codex_max_tie=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    --arg at "$codex_max_at" --arg notice "$CODEX_NOTICE_RE" \
    '[.comments[]? | select(.author.login == $login or .author.login == $login_bot)
      | select(((.body // "") | test($notice)) | not)
      | select(.createdAt == $at)] | length' 2>/dev/null || echo 1)
  codex_last_comment=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    --arg at "$codex_max_at" --arg notice "$CODEX_NOTICE_RE" \
    '[.comments[]? | select(.author.login == $login or .author.login == $login_bot)
      | select(((.body // "") | test($notice)) | not)
      | select(.createdAt == $at)] | last | .body // empty' 2>/dev/null || echo "")
  if [ -n "$codex_max_at" ] && [ "$(num_or "$codex_max_tie" 2)" -ne 1 ]; then
    # Two Codex comments in the same second: which one is "latest" is not knowable
    # from the payload. Decline rather than pick, then fall through to the veto at
    # (0), which is a COUNT and so is immune to the ambiguity.
    codex_last_comment=""
  fi
  case "$codex_last_comment" in
    "Codex Review: Didn't find any major issues."*)
      # Line-anchored extraction; tail -1 keeps the last such line if a future
      # template ever repeats it. No match (renamed label, SHA unbackticked,
      # findings body) → empty → no ack → fall through to stale.
      # shellcheck disable=SC2016  # single-quoted sed program: the backreference
      # \1 is sed syntax, not a shell expansion.
      codex_clean_sha=$(printf '%s' "$codex_last_comment" \
        | sed -n 's/^\*\*Reviewed commit:\*\*[[:space:]]*`\([0-9a-fA-F]\{7,64\}\)`.*/\1/p' | tail -1)
      # When the verdict was published. Required, not best-effort: it is the
      # reference point for the re-review check below, so a payload without it
      # (an old caller shape) cannot ack.
      codex_clean_at="$codex_max_at"
      # It is a REFERENCE POINT, so its form matters as much as its presence: the
      # comparisons below are lexicographic, and a junk value like "zzzz" sorts
      # after every real date, which would silently suppress the very activity
      # those comparisons exist to find. Anything that is not GitHub's UTC 'Z'
      # ISO-8601 is discarded, and the `-n` guard below then declines the ack.
      [ "$(ts_ok "$codex_clean_at")" = "1" ] || codex_clean_at=""
      # ANY Codex activity AT OR AFTER the verdict means Codex is not done with
      # this HEAD, so the verdict must not ack. Two shapes count, and both are
      # checked because either alone leaves a hole:
      #   👀 at-or-after — Codex started ANOTHER review of this same HEAD after
      #     publishing the verdict, and it may yet file a finding.
      #   a /reviews entry at-or-after — a Codex review is ALWAYS a findings post
      #     (see the Tier B exclusion below), and a body-only one opens no inline
      #     thread, so Tier A.1 would not have caught it.
      # The comparison is `>=`, not `>`: GitHub timestamps have one-second
      # resolution, and a re-review kicked off inside the verdict's own second
      # would compare EQUAL and slip through a strict `>`. A tie is exactly the
      # ambiguous case, so it declines.
      # Reactions carry `created_at` and reviews `submitted_at` (REST underscore
      # form) against the comment's `createdAt` (GraphQL camel form) — all are
      # GitHub-emitted UTC 'Z' ISO-8601, so lexicographic comparison is a correct
      # time comparison. A record missing its timestamp sorts as "9999", i.e.
      # newer than everything → declines.
      codex_eyes_after=$(printf '%s' "$ALL_REACTIONS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
        --arg at "$codex_clean_at" \
        '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot)
          | select(.content == "eyes") | select((.created_at // "9999") >= $at)] | length' 2>/dev/null || echo 1)
      codex_reviews_after=$(printf '%s' "$ALL_REVIEWS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
        --arg at "$codex_clean_at" \
        '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot)
          | select((.submitted_at // "9999") >= $at)] | length' 2>/dev/null || echo 1)
      # An UNREAD proof source is not a proof of absence. Every check above
      # concludes from a count of ZERO — no live thread, no newer 👀, no newer
      # review — and `jq -rs` reports zero just as readily for a source that is
      # missing (`""`), null, or shape-drifted as for one that is genuinely
      # quiet, with exit status 0 the whole way, so neither `|| echo 1` nor
      # num_or ever fires. Without this, Tier G is the one tier whose guards a
      # partial or broken caller can silently switch off. Confirm each source
      # actually parsed into the shape its query indexes; anything else declines
      # here and falls through to (0)/(5) → stale.
      # shellcheck disable=SC2016  # every json_shape_ok call below is a single-quoted
      # jq program (jq's own `$ts`, bound via --arg inside json_shape_ok); none of
      # these are shell expansions. Directive covers the whole continued `if`.
      if [ -n "$codex_clean_sha" ] && [ -n "$codex_clean_at" ] \
         && [ "$(json_shape_ok "$ALL_THREADS" '(.data.repository.pullRequest.reviewThreads.nodes | type) == "array"
                 and (.data.repository.pullRequest.reviewThreads.nodes
                      | all((.isResolved | type) == "boolean" and (.isOutdated | type) == "boolean"
                            and ((.comments.nodes | type) == "array")
                            and ((.comments.nodes | length) > 0)
                            and (.comments.nodes[0] | has("author"))
                            and (.comments.nodes[0].author == null
                                 or ((.comments.nodes[0].author | type) == "object"
                                     and (.comments.nodes[0].author.login | type) == "string"))))')" = "1" ] \
         && [ "$(json_shape_ok "$ALL_REVIEWS" 'type == "array"
                 and all((.submitted_at == null
                          or ((.submitted_at | type) == "string" and (.submitted_at | test($ts))))
                         and has("submitted_at") and has("user")
                         and (.user == null
                              or ((.user | type) == "object" and (.user.login | type) == "string")))')" = "1" ] \
         && [ "$(json_shape_ok "$ALL_REACTIONS" 'type == "array"
                 and all((.created_at == null
                          or ((.created_at | type) == "string" and (.created_at | test($ts))))
                         and (.content | type) == "string" and has("created_at") and has("user")
                         and (.user == null
                              or ((.user | type) == "object" and (.user.login | type) == "string")))')" = "1" ] \
         && [ "$(num_or "$codex_eyes_after" 1)" -eq 0 ] \
         && [ "$(num_or "$codex_reviews_after" 1)" -eq 0 ] \
         && acks_head "$codex_clean_sha"; then
        emit_head_ack "$HEAD_SHA" G; exit 0
      fi
      ;;
  esac
fi

# Codex eyes-override (HOISTED above every tier below it): a current 👀 reaction
# means Codex is actively (re-)reviewing HEAD → stale, regardless of any
# thread/review state below. Codex re-adds 👀 whenever HEAD advances, so this is
# the robust, timestamp-independent guard for the re-review race — and it MUST
# run before Tier A.2 so a resolved-current-head thread cannot ack while Codex is
# still mid-review of a newer push. It sits below Tier A.1 and Tier G (#690):
# A.1 also exits `stale`, so that order is output-neutral; Tier G must precede it
# because a comment-form verdict leaves the 👀 behind. Codex-only and guarded on
# non-empty ALL_REACTIONS, so it is a strict no-op for every other login and for
# callers not yet upgraded to fetch reactions.
if [ "$login" = "chatgpt-codex-connector" ] && [ -n "$ALL_REACTIONS" ]; then
  codex_eyes=$(printf '%s' "$ALL_REACTIONS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
    '[.[]? | .[]? | select(.user.login == $login or .user.login == $login_bot) | select(.content == "eyes")] | length' 2>/dev/null || echo 1)
  if [ "$(num_or "$codex_eyes" 1)" -gt 0 ]; then echo "stale"; exit 0; fi
fi

# Non-Codex bots: any DISPOSED thread (resolved OR outdated) acks HEAD — the
# bot's prior findings are no longer actionable.
# Codex: only a RESOLVED + NON-OUTDATED thread acks (a finding the worker
# addressed/dismissed ON THE CURRENT HEAD). The out-of-scope-acknowledged
# workflow resolves a thread WITHOUT a code push, so there's no new commit to
# trigger a fresh Codex 👍 — without this branch that dismissal would leave
# Codex `stale` until `--max-wait` bails (the deadlock Codex's own review of
# this PR flagged). An OUTDATED-only Codex thread is from superseded code (HEAD
# advanced past it) and must NOT ack — Codex has to re-review the new HEAD,
# caught as `stale` and cleared later by a fresh 👍 (Tier F), a clean-verdict
# comment naming the new HEAD (Tier G, #690), or a new resolved-current-head
# thread. The hoisted eyes-override above guarantees Codex
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
  # (0) A POST-ANCHOR COMMENT THAT TIER G DECLINED BLOCKS EVERYTHING BELOW (#690).
  #     Since the mechanism switch, a Codex finding routinely arrives as an issue
  #     COMMENT with no thread and no review — PR #688's P2 at 17:36:38Z did. If
  #     that check sat at the BOTTOM of this block, a 👍 left over from an earlier
  #     clean pass would satisfy Tier F first and the gate would merge past the
  #     finding: reaction and comment are separate objects, so publishing a finding
  #     does not retract a prior +1. Reaching here means Tier G already looked at
  #     the last comment and refused it — so whatever Codex has said about the
  #     current head is NOT a clean verdict on it, and nothing below may ack.
  #     Scoped to comments that POSTDATE $anchor_date so the block cannot deadlock:
  #     a findings comment from BEFORE the last push is about superseded code (the
  #     comment-form twin of the outdated-thread case at (2)) and must not veto the
  #     fresh 👍 that answered it. Fail-CLOSED in three ways — an empty anchor makes
  #     every comment post-anchor, a comment with no createdAt sorts as "9999", and
  #     a jq error counts 1 — because each of those is a snapshot we cannot reason
  #     about, on a merge gate.
  if [ -n "$ALL_COMMENTS" ]; then
    codex_comments_after=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
      --arg anchor "$anchor_date" --arg notice "$CODEX_NOTICE_RE" \
      '[.comments[]? | select(.author.login == $login or .author.login == $login_bot)
        | select(((.body // "") | test($notice)) | not)
        | select((.createdAt // "9999") >= $anchor)] | length' 2>/dev/null || echo 1)
    if [ "$(num_or "$codex_comments_after" 1)" -gt 0 ]; then echo "stale"; exit 0; fi
  fi
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
  # (5) ENGAGED VIA COMMENT (#690). A Codex-authored issue comment is engagement
  #     exactly as a reaction is, and since the mechanism switch it is the shape
  #     Codex actually uses. (0) above already blocked on any comment that
  #     postdates the anchor, so what lands here is a PRE-anchor comment with no
  #     ack from any tier: Codex spoke about superseded code and has not spoken
  #     since. Without this branch that falls through to the `none` early-return
  #     and is NON-GATING — a PR where Codex only ever comments would be mergeable
  #     with no Codex verdict on HEAD at all, which is exactly the `none`-means-
  #     "not on this PR" misreading the field cannot afford. `stale` is right:
  #     Codex IS on this PR, and it owes HEAD a verdict.
  #     Cost of the strict reading: an off-topic Codex comment (a Q&A reply to
  #     "@codex address that feedback") also holds the gate until Codex re-reviews
  #     clean. That is the correct direction to be wrong in on a merge gate, and
  #     --max-wait remains the operator-visible backstop.
  codex_commented=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg login "$login" --arg login_bot "${login}[bot]" \
    --arg notice "$CODEX_NOTICE_RE" \
    '[.comments[]? | select(.author.login == $login or .author.login == $login_bot)
      | select(((.body // "") | test($notice)) | not)] | length' 2>/dev/null || echo 1)
  if [ -n "$ALL_COMMENTS" ] && [ "$(num_or "$codex_commented" 1)" -gt 0 ]; then echo "stale"; exit 0; fi
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
# until the worker triages and Codex re-reviews clean). Codex's positive acks are
# the Tier F 👍 and the Tier G clean-verdict comment (#690) — never a /reviews
# entry. `commit_id` is still computed above for that downgrade block.
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
# greptile-apps exclusion: its `Greptile Review` check goes conclusion=success
# even WITH open findings (observed on PR #174), so a success check-run does NOT
# prove clean — unlike cubic/coderabbit, whose Tier-D check is clean-only. A
# bodyless Tier-D ack here would carry n_total==0 and trip Invariant 3's ADR-0001
# D/E exemption (auto-PASS), and because the check-run is published SEPARATELY
# from the review object with no read-after-write ordering, it can be observed
# green while the findings review is not yet visible — a merge-past-findings
# fail-OPEN (flagged in PR review). Fail-CLOSED: greptile's HEAD-ack must come
# from the review object itself — Tier A inline threads (findings → stale) or the
# Tier B bodyless /reviews commit_id (atomic with any threads); a clean summary
# issue-comment enumerates as an artifact (n_total≥1, normal gating). A
# check-run-ONLY clean run falls through to `none` (non-gating) rather than
# fabricating a bodyless clean ack. Promote to Tier-D-eligible only after a
# clean greptile run proves its check is clean-only. Mirrors the Codex Tier-B guard.
if [ -n "$check_run_head" ] && acks_head "$check_run_head" && [ "$login" != "greptile-apps" ]; then emit_head_ack "$HEAD_SHA" D; exit 0; fi

# (E) /commits/{sha}/statuses: bots using the legacy commit-statuses API.
# CodeRabbit free-tier on private repos posts here instead of registering a
# check-run, so Tier D's app.slug match misses them entirely (the previous
# failure mode that forced admin-merge on PR #160). The login → status-context
# mapping is explicit because context strings are vendor-defined and don't
# follow a derivable slug convention. Statuses are inherently for HEAD_SHA
# (the fetch URL is /commits/$HEAD_SHA/statuses), so a success state is a
# HEAD-ack — no separate SHA comparison needed — EXCEPT when the bot itself
# says it never reviewed (#353 rate-limit exemption below). The status proves
# WHICH commit the bot reported on, never THAT it reviewed.
#
# Latest-wins selection: bots emit `pending → success` (or `pending → failure`)
# during review. Primary sort key is `created_at`; secondary key is `id`
# (status IDs are monotonically increasing). The id tiebreaker matters because
# GitHub timestamps are second-resolution — two statuses posted in the same
# second would otherwise rely on stable-sort input order, which `gh api
# --paginate` does not guarantee. A bot whose latest state is `success` exits
# here with HEAD-ack. A bot whose latest state is non-empty non-success
# (`pending`/`failure`/`error`) exits here with `stale` (live signal must
# gate the merge). Both terminals are preceded by the rate-limit exemption
# (#294/#353): a never-approved bot with a proven-fresh "couldn't start this
# review" notice falls through to the Case 1b downgrade → `none` regardless of
# which state it reported. Only when there's no matching status entry at all
# (the bot has a mapped context but `last | .state` returns empty) does Tier E
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
  # Rate-limit exemption is checked BEFORE either terminal, so it covers every
  # state the bot can report (#294 = non-success, #353 = success).
  #
  # #294 (non-success): a rate-limited CodeRabbit posts its "review limit
  # reached" NOTICE as an issue comment while its legacy commit-status for HEAD
  # is pending/failure/error. A non-success `stale` short-circuiting before the
  # Case 1b issue-comment scan leaves the bot `stale` forever, and pr-grind waits
  # for a review the rate-limited bot cannot deliver. Fail-CLOSED (over-blocks).
  #
  # #353 (success): the fail-OPEN twin, and why this guard sits above BOTH arms.
  # A rate-limited CodeRabbit emits context=CodeRabbit state=success
  # ("Review completed") on the SAME HEAD whose comment body says "we couldn't
  # start this review" (evidence: chris-yyau/helmet PR #81, HEAD 3bbcd8df). The
  # status is not a review verdict — it is the bot reporting that its run
  # finished, including when the run did nothing. Taking `success` as a HEAD-ack
  # silently converts "not reviewed" into "reviewed, no findings": the ledger
  # HEAD-acks, `clean` is reached, and pr-grind's completion output claims all
  # reviewers finished with no actionable findings when the bot never started.
  #
  # The notice gate is the one Case 1b already applies: a proven-fresh,
  # canonical-latest, notice-only rate-limit comment strictly postdating the HEAD
  # anchor. It cannot reclassify findings prose.
  #
  # ever_approved does NOT gate the exemption — it only picks the terminal. The
  # guard exists so a bot with history is never silently BYPASSED, and bypass here
  # means `none`. A bot that reviewed an earlier commit (APPROVED / DISMISSED /
  # CHANGES_REQUESTED) and was then rate-limited on HEAD has NOT reviewed HEAD, so
  # `stale` is the honest terminal — it preserves the earlier findings and blocks.
  # Gating the exemption itself on ever_approved==0 would send exactly that bot
  # down the success arm to a HEAD-ack, i.e. fail-OPEN on the highest-risk subset
  # (a bot with unresolved findings). `stale` is emitted explicitly rather than by
  # fall-through: the `-z commit_id && -z body_sha` early-return below would turn a
  # history-bearing bot into `none` if its reviews carry no commit_id.
  #
  # `none`, not `stale`, is the ever_approved==0 target: `stale` would block on a
  # review that cannot arrive until quota resets (the #294 dead-end), while `none`
  # keeps the PR moving and records honestly that the bot contributed nothing.
  #
  # Non-success states (pending, failure, error) otherwise mean the bot HAS
  # signaled something about HEAD — mid-review or actively flagging. Without the
  # `stale` arm, a statuses-only bot in pending/failure would fall through to the
  # empty-commit_id `none` early-return below and the gate would silently treat
  # the live signal as "bot doesn't operate here". A bot WITH /reviews history
  # that's also pending still falls through to the downgrade block (existing
  # one-and-done semantics). The `-n` check on $status_state means an empty or
  # missing status context for a different bot doesn't trip either arm.
  if [[ -n "$status_state" ]]; then
    if _fresh_rate_limit_notice; then
      # Bot's own latest word: it did not review HEAD. Its status is not a verdict.
      if [[ "$ever_approved" -eq 0 ]]; then
        : # fall through → Case 1b downgrade block emits `none`
      else
        echo "stale"; exit 0
      fi
    elif [[ "$status_state" == "success" ]]; then
      # Anchorless notice: freshness unprovable, so a review is unprovable too (#353).
      if _unprovable_rate_limit_notice; then echo "stale"; exit 0; fi
      emit_head_ack "${HEAD_SHA:0:8}" E; exit 0
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
     { [[ -z "$last_body" ]] || \
       printf '%s' "$last_body" | grep -qiE '(no issues? found|no concerns|all good|looks good|lgtm|nothing to (add|report)\b)'; }; then
    echo "none"; exit 0
  fi
fi

echo "stale"
