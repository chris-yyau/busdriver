#!/usr/bin/env bash
# tests/test-codex-clean-comment-tier.sh
#
# Verifies scripts/ack-ledger.sh Tier G (#690) — the Codex clean-verdict ISSUE
# COMMENT ack.
#
# Background: Codex's own footer promises "If Codex has suggestions, it will
# comment; otherwise it will react with 👍". On 2026-08-17 that promise broke on
# two PRs within the same hour: PR #687 and PR #688 each got a findings-free
# review delivered as an issue COMMENT naming the reviewed SHA, with NO 👍 and
# the 👀 left in place. That shape acked through no tier at all (not a review →
# not B; no thread → not A; no check-run/status → not D/E; no reaction → not F),
# so `ack-ledger.sh` returned `stale` forever, both PRs burned their nudge budget,
# and both merged only under an operator `skip-pr-grind.local`.
#
# Every body below is a VERBATIM capture from those two PRs (fetched via
# `gh api repos/chris-yyau/busdriver/issues/{687,688}/comments`), not a
# paraphrase — the two clean verdicts differ in their tail ("🚀" vs "Swish!"),
# which is exactly why the matcher anchors on the stable prefix and reads the SHA
# from the "**Reviewed commit:**" line rather than pinning the whole line.

set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

if [ ! -f "$ACK_SCRIPT" ]; then
  fail "ack-ledger.sh missing at $ACK_SCRIPT"
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

CODEX="chatgpt-codex-connector"
HEAD_SHA="bd532d84"                                          # 8-char HEAD (PR #688's final head)
CLEAN_SHA="bd532d8462"                                       # as Codex writes it: 10 chars
OTHER_SHA="2ff0484bb9"                                       # PR #688's PREVIOUS head
FULL_HEAD="bd532d8462fdb27e388940076aa9dc0e4e07c3d1"         # 40-char form, as it appears in blob URLs

# Codex's footer — present on BOTH shapes, so it can never be what discriminates.
FOOTER=$'\n\n<details> <summary>ℹ️ About Codex in GitHub</summary>\n<br/>\n\n[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). Reviews are triggered when you\n- Open a pull request for review\n- Mark a draft as ready\n- Comment "@codex review".\n\nIf Codex has suggestions, it will comment; otherwise it will react with 👍.\n</details>'

# --- Verbatim bodies -------------------------------------------------------
# PR #688's clean verdict (2026-08-17T18:11:54Z).
CLEAN_688="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"**Reviewed commit:** \`$CLEAN_SHA\`$FOOTER"
# PR #687's clean verdict (2026-08-17T17:43:20Z) — SAME prefix, DIFFERENT tail.
CLEAN_687="Codex Review: Didn't find any major issues. :rocket:"$'\n\n'"**Reviewed commit:** \`$CLEAN_SHA\`$FOOTER"
# A clean verdict for the PREVIOUS head — must not carry forward past a push.
CLEAN_OLD="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"**Reviewed commit:** \`$OTHER_SHA\`$FOOTER"
# PR #688's FINDINGS comment (2026-08-17T17:36:38Z), which embeds a 40-char SHA in
# a blob permalink. This is the reason the SHA is read only from the
# "**Reviewed commit:**" line: a body-wide hex scan would ack an open P2.
FINDINGS_688=$'\n### 💡 Codex Review\n\n'"https://github.com/chris-yyau/busdriver/blob/$FULL_HEAD/tests/test-dispatcher-commit-block.sh#L1826-L1827"$'\n**<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow?style=flat)</sub></sub>  Assert the staged path'"'"$'s worktree copy survives**\n\nThe claim that all non-index changes remain in the working tree omits the deliberately divergent `staged.txt` copy.'"$FOOTER"
# The clean sentence QUOTED inside a findings body — the diff being reviewed can
# contain any text, so the match must be start-anchored.
QUOTED_CLEAN=$'\n### 💡 Codex Review\n\nThe test asserts the reviewer said "Codex Review: Didn'"'"$'t find any major issues." — that string is user data.\n\n**Reviewed commit:** `'"$CLEAN_SHA"'`'"$FOOTER"
# Right template, SHA present but not in the recognised line form.
CLEAN_NO_SHA_LINE="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"Reviewed $CLEAN_SHA just now.$FOOTER"

# --- Source fixtures -------------------------------------------------------
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_REVIEWS='[]'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_STATUSES='[]'
NO_REACTIONS='[]'

# Timeline, all from PR #688's real sequence. HEAD landed at PUSH_AT; everything
# named *_AFTER postdates it.
PUSH_AT="2026-08-17T17:44:05Z"
BEFORE_PUSH="2026-08-17T17:36:38Z"   # #688's comment-form P2, on the PREVIOUS head
AFTER_PUSH="2026-08-17T18:11:54Z"    # #688's clean verdict on HEAD
LATE="2026-08-17T18:30:00Z"          # anything published after the verdict

# Codex's 👀. PR #687's real ordering: eyes at 17:39:45Z, clean verdicts at
# 17:43:20Z and 17:50:56Z — the eyes are the RESIDUE of the review that produced
# the verdict, not evidence of one in flight.
EYES_BEFORE_VERDICT='[{"content":"eyes","created_at":"2026-08-17T17:39:45Z","user":{"login":"chatgpt-codex-connector[bot]"}}]'
EYES_AFTER_VERDICT='[{"content":"eyes","created_at":"2026-08-17T18:20:00Z","user":{"login":"chatgpt-codex-connector[bot]"}}]'
FRESH_PLUS1='[{"content":"+1","created_at":"2026-08-17T17:50:00Z","user":{"login":"chatgpt-codex-connector[bot]"}}]'
# A +1 published AFTER a post-push finding comment — the exact re-review-then-
# clean sequence Codex flagged on PR #693 round 4: a finding at AFTER_PUSH
# followed by a LATER clean reaction with no new comment.
LATER_PLUS1=$(jq -nc --arg at "$LATE" \
  '[{content:"+1", created_at:$at, user:{login:"chatgpt-codex-connector[bot]"}}]')

# A Codex thread in a given (isResolved, isOutdated) state.
mk_codex_thread() {
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"2026-08-17T15:30:14Z"}]}}]}}}}}' "$1" "$2"
}
OUTDATED_THREAD=$(mk_codex_thread false true)     # superseded finding — the #688 blocker
UNRESOLVED_THREAD=$(mk_codex_thread false false)  # LIVE finding on this HEAD

# Build the `gh pr view --json comments` payload. Note gh returns the BARE login
# (`chatgpt-codex-connector`) while the REST API returns the `[bot]` suffix; the
# ledger matches both, so the fixtures below exercise the bare form.
# mk_comments <login> <createdAt> <body> [<createdAt> <body> ...] — the
# `gh pr view --json comments` payload shape, oldest first.
mk_comments() {
  local login="$1"; shift
  # `_nwise` is an undocumented private jq builtin, present in jq 1.7 but
  # REMOVED in jq 1.8 (replaced by the documented `nwise`). Use a
  # range-based pairing instead so this fixture builder works on every jq
  # this repo's CI may run (CodeRabbit finding on PR #693).
  jq -nc --arg login "$login" \
    '($ARGS.positional) as $a
     | {comments: [range(0; ($a | length); 2)
        | {author: {login: $login}, createdAt: $a[.], body: $a[. + 1]}]}' \
    --args "$@"
}

run_ledger() {
  # $1 = ALL_COMMENTS, $2 = ALL_THREADS, $3 = ALL_REACTIONS,
  # $4 = login (default codex), $5 = ACK_EMIT_TIER (default 0),
  # $6 = HEAD_PUSH_DATE (default PUSH_AT; an explicit "" means no push anchor).
  # HEAD_CHECKS_DATE is pinned empty so an exported value cannot become an anchor.
  # ACK_CONTENT_IDENTITY=0: OTHER_SHA ("2ff0484bb9") is a real former head of
  # PR #688 and may exist as a git object in the clone running this suite,
  # which would let acks_head's content-identity path (tree+parent comparison)
  # decide Test 4 instead of the SHA-equality rule it asserts. Pin it off so
  # these fixtures exercise SHA equality only, independent of ambient repo state.
  FETCH_OK=1 ACK_EMIT_TIER="${5:-0}" ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="$2" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$1" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$3" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="${6-$PUSH_AT}" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "${4:-$CODEX}" 2>/dev/null
}

# --- Test 1: the #688 verdict, nothing else → HEAD-ack --------------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean-verdict comment naming HEAD → HEAD_SHA"
else
  fail "clean-verdict comment expected '$HEAD_SHA', got '$got'"
fi

# --- Test 1b: same case tier-exposed → SHA:G ------------------------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1)
if [ "$got" = "${HEAD_SHA}:G" ]; then
  ok "clean-verdict comment under ACK_EMIT_TIER=1 → '${HEAD_SHA}:G'"
else
  fail "tier-exposed clean verdict expected '${HEAD_SHA}:G', got '$got'"
fi

# --- Test 2: PR #687's tail (":rocket:") acks identically ------------------
# The two observed clean verdicts differ after the prefix. A whitelist keyed on
# the whole line would have matched one PR and missed the other.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_687")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict with the OTHER observed tail → HEAD_SHA (tail is free text)"
else
  fail "':rocket:' tail expected '$HEAD_SHA', got '$got'"
fi

# --- Test 3: THE headline negative — findings body embedding HEAD's SHA ----
# #688's real P2 comment carries the 40-char HEAD SHA inside a blob permalink. A
# body-wide hex scan would ack a comment with an unaddressed finding in it.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$FINDINGS_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "findings comment embedding HEAD's SHA in a blob URL → stale (no body-wide hex scan)"
else
  fail "findings-with-blob-URL expected 'stale', got '$got'"
fi

# --- Test 4: clean verdict naming the PREVIOUS head → stale ---------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_OLD")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean verdict naming the pre-push SHA → stale (SHA equality is the freshness proof)"
else
  fail "pre-push clean verdict expected 'stale', got '$got'"
fi

# --- Test 5: #687 repro — clean verdict + lingering 👀 → ack ---------------
# Comment-form completion does NOT remove the eyes. Tier G must therefore sit
# ABOVE the eyes-override, or it never fires in the case it exists to fix.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$EYES_BEFORE_VERDICT")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict + lingering 👀 → HEAD_SHA (#687 repro; Tier G precedes the eyes-override)"
else
  fail "#687 repro expected '$HEAD_SHA', got '$got'"
fi

# --- Test 6: #688 repro — clean verdict + outdated Codex threads → ack -----
# The outdated short-circuit fires forever once any Codex thread goes outdated.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$OUTDATED_THREAD" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict + outdated threads → HEAD_SHA (#688 repro)"
else
  fail "#688 repro expected '$HEAD_SHA', got '$got'"
fi

# --- Test 7: A.1 precedence — clean verdict + LIVE thread → stale ---------
# Codex can re-review the same commit after a nudge and file a finding. A live
# unresolved+non-outdated thread must outrank any clean comment.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$UNRESOLVED_THREAD" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean verdict + LIVE unresolved thread → stale (Tier A.1 outranks Tier G)"
else
  fail "A.1 precedence expected 'stale', got '$got'"
fi

# --- Test 8: LAST comment wins — clean verdict THEN findings → stale ------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$LATE" "$FINDINGS_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean verdict followed by findings → stale (last Codex comment wins)"
else
  fail "clean-then-findings expected 'stale', got '$got'"
fi

# --- Test 8b: findings THEN clean verdict → ack (the real #688 sequence) --
got=$(run_ledger "$(mk_comments "$CODEX" "$BEFORE_PUSH" "$FINDINGS_688" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "findings followed by clean verdict → HEAD_SHA (Codex re-reviewed and is satisfied)"
else
  fail "findings-then-clean expected '$HEAD_SHA', got '$got'"
fi

# --- Test 9: the clean sentence QUOTED inside a findings body → stale -----
# The reviewed diff is attacker-adjacent text: Codex quotes it back. Only a
# start-anchored match is safe.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$QUOTED_CLEAN")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean sentence quoted mid-body → stale (match is start-anchored)"
else
  fail "quoted-clean-sentence expected 'stale', got '$got'"
fi

# --- Test 10: right template, no recognised SHA line → stale --------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_NO_SHA_LINE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean template without a '**Reviewed commit:**' line → stale (fail-CLOSED)"
else
  fail "template-without-SHA-line expected 'stale', got '$got'"
fi

# --- Test 11: non-Codex bot posting the same body → tier is a no-op -------
# Tier G is Codex-only. The clean body carries no `commit/<sha>` LINK, so Tier C
# finds nothing either and the bot falls through to `none`, exactly as before.
got=$(run_ledger "$(mk_comments "cubic-dev-ai" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS" "cubic-dev-ai")
if [ "$got" = "none" ]; then
  ok "non-Codex bot with the same body → none (Tier G is a strict Codex-only no-op)"
else
  fail "non-Codex same-body expected 'none', got '$got'"
fi

# --- Test 12: caller that fetches no comments at all → unchanged ----------
# ALL_COMMENTS empty (an unupgraded caller) must not crash or ack.
got=$(run_ledger "" "$OUTDATED_THREAD" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "empty ALL_COMMENTS → stale (tier is inert for unupgraded callers)"
else
  fail "empty ALL_COMMENTS expected 'stale', got '$got'"
fi

# --- Test 13: fresh 👍 + a LATER comment-form finding → stale ------------
# Reaction and comment are separate objects: publishing a finding does not
# retract an earlier +1. If the comment check ran below Tier F, that leftover 👍
# would ack HEAD and the gate would merge past the finding.
got=$(run_ledger "$(mk_comments "$CODEX" "$LATE" "$FINDINGS_688")" "$EMPTY_THREADS" "$FRESH_PLUS1")
if [ "$got" = "stale" ]; then
  ok "fresh 👍 + later comment-form finding → stale (post-anchor comment outranks Tier F)"
else
  fail "👍-then-finding expected 'stale', got '$got'"
fi

# --- Test 14: PRE-push finding + fresh 👍 → HEAD_SHA (no new deadlock) ----
# The mirror of Test 13. A findings comment from before the push is about
# superseded code — the comment-form twin of an outdated thread — and must not
# veto the 👍 that answered it, or every commented PR would deadlock forever.
got=$(run_ledger "$(mk_comments "$CODEX" "$BEFORE_PUSH" "$FINDINGS_688")" "$EMPTY_THREADS" "$FRESH_PLUS1")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "pre-push finding + fresh 👍 → HEAD_SHA (superseded comments do not veto Tier F)"
else
  fail "pre-push-finding + 👍 expected '$HEAD_SHA', got '$got'"
fi

# --- Test 14b: POST-push finding SUPERSEDED by a LATER 👍 → HEAD_SHA -------
# Codex's own P2 on PR #693 round 4: the mirror of Test 13/14 for a finding
# comment that postdates the PUSH (not just an earlier finding). A finding at
# AFTER_PUSH followed by a still-later clean reaction (no new comment) means
# Codex re-reviewed the unchanged HEAD and superseded its own finding; the
# veto at (0) must compare against that fresher +1, not just $anchor_date, or
# nudging Codex into a clean reaction could never clear the gate.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$FINDINGS_688")" "$EMPTY_THREADS" "$LATER_PLUS1")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "post-push finding + LATER 👍 → HEAD_SHA (fresher reaction supersedes the finding, #693 Codex P2)"
else
  fail "post-push-finding + later 👍 expected '$HEAD_SHA', got '$got'"
fi

# Test 13 above (fresh 👍 THEN a later finding → stale) is the other half of
# this pair and already proves the veto threshold does not simply disable
# itself once any +1 exists — it still blocks a finding NEWER than the +1.

# --- Test 15: clean verdict + a 👀 created AFTER it → stale ---------------
# Codex started ANOTHER review of this same HEAD after publishing the verdict;
# that review may yet file a finding, so the old verdict must not ack.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$EYES_AFTER_VERDICT")
if [ "$got" = "stale" ]; then
  ok "clean verdict + 👀 newer than the verdict → stale (re-review in flight)"
else
  fail "eyes-after-verdict expected 'stale', got '$got'"
fi

# --- Test 16: clean verdict with NO createdAt → stale (fail-CLOSED) -------
# The verdict's timestamp is the reference point for Test 15's check, so a
# payload shape that omits it cannot ack.
NO_TS_COMMENTS=$(jq -nc --arg login "$CODEX" --arg body "$CLEAN_688" \
  '{comments:[{author:{login:$login}, body:$body}]}')
got=$(run_ledger "$NO_TS_COMMENTS" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "clean verdict with no createdAt → stale (fail-CLOSED, no reference point)"
else
  fail "verdict-without-timestamp expected 'stale', got '$got'"
fi

# --- Test 17: malformed ALL_COMMENTS under FETCH_OK=1 → stale ------------
# FETCH_OK=1 asserts the fetch succeeded, so unreadable JSON is a BROKEN
# snapshot, not an absent one. It must not degrade to "Codex said nothing".
got=$(run_ledger '{"comments":[{"author":' "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "malformed ALL_COMMENTS + FETCH_OK=1 → stale (broken snapshot fails CLOSED)"
else
  fail "malformed comments expected 'stale', got '$got'"
fi

# --- Test 18: malformed ALL_THREADS cannot let a clean verdict through ----
# Tier G's A.1 precedence is only as good as the query that proves no live
# thread exists. A jq failure there must block, not count zero.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" '{"data":{"repository":' "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "malformed ALL_THREADS + clean verdict → stale (A.1 precedence fails CLOSED)"
else
  fail "malformed threads expected 'stale', got '$got'"
fi

# --- Test 19: a third and fourth observed tail still ack -----------------
# PR #687 alone produced four distinct tails in one day (":rocket:", "Breezy!",
# ":rocket:", "Bravo."). The tail carries no meaning; only the prefix does.
for tail_variant in "Breezy!" "Bravo." "" "🚀"; do
  body="Codex Review: Didn't find any major issues. ${tail_variant}"$'\n\n'"**Reviewed commit:** \`$CLEAN_SHA\`$FOOTER"
  got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$body")" "$EMPTY_THREADS" "$NO_REACTIONS")
  if [ "$got" = "$HEAD_SHA" ]; then
    ok "clean verdict tail '${tail_variant}' → HEAD_SHA"
  else
    fail "tail '${tail_variant}' expected '$HEAD_SHA', got '$got'"
  fi
done

# --- Test 20: clean verdict + a LATER Codex /reviews entry → stale -------
# A Codex review is always a findings post, and a body-only one opens no inline
# thread — so Tier A.1 would not have caught it and the verdict must decline.
LATER_REVIEW=$(jq -nc --arg login "${CODEX}[bot]" --arg at "$LATE" \
  '[{user:{login:$login}, submitted_at:$at, state:"COMMENTED", commit_id:"bd532d8462fdb27e388940076aa9dc0e4e07c3d1"}]')
got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "clean verdict + later Codex /reviews entry → stale (body-only findings review)"
else
  fail "verdict-then-review expected 'stale', got '$got'"
fi

# --- Test 21: 👀 in the SAME SECOND as the verdict → stale ---------------
# GitHub timestamps are second-resolution, so a re-review kicked off inside the
# verdict's own second compares EQUAL. A tie is the ambiguous case; it declines.
SAME_SECOND_EYES=$(jq -nc --arg login "${CODEX}[bot]" --arg at "$AFTER_PUSH" \
  '[{content:"eyes", created_at:$at, user:{login:$login}}]')
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$SAME_SECOND_EYES")
if [ "$got" = "stale" ]; then
  ok "👀 in the same second as the verdict → stale (>= not >, second-resolution tie)"
else
  fail "same-second eyes expected 'stale', got '$got'"
fi

# --- Test 22: schema-drifted ALL_COMMENTS (valid JSON, wrong shape) ------
# `.comments[]?` swallows a drift as silently as a null, so a payload that parses
# but has no `comments` array would read as "Codex said nothing" → none.
got=$(run_ledger '{"nodes":[]}' "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "schema-drifted ALL_COMMENTS ({\"nodes\":[]}) → stale (shape is validated, not just syntax)"
else
  fail "schema-drifted comments expected 'stale', got '$got'"
fi

# --- Test 23: a proof source ABSENT (not empty-but-present) → stale ------
# `jq -rs` over an empty ALL_REACTIONS/ALL_REVIEWS returns a valid 0, and the A.1
# threads query does too — so a partial caller would collect vacuous "nothing
# newer, nothing live" answers. Absence of a source is not proof of absence.
# The `null` / `{}` rows go further: those are non-empty strings that parse
# cleanly and still yield zero records, so an existence test alone would let an
# unread source pose as a quiet one.
DRIFT_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{}]}}}}}'
# Booleans present, but the comments the liveness query reads are gone.
NODELESS_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false}]}}}}}'
# A LIVE thread whose first comment carries no author key at all: the liveness
# query keys on comments.nodes[0].author.login, so it would count zero.
NULL_LOGIN_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":null}}]}}]}}}}}'
EMPTY_AUTHOR_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{}}]}}]}}}}}'
AUTHORLESS_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{}]}}]}}}}}'
for missing in THREADS REVIEWS REACTIONS THREADS=null REVIEWS=null 'REACTIONS={}' 'THREADS={}' \
               'REVIEWS=[{}]' 'REACTIONS=[{}]' "THREADS=$DRIFT_THREADS" \
               'REVIEWS=[{"submitted_at":"2026-08-17T18:30:00Z","user":{}}]' \
               'REACTIONS=[{"content":"eyes","created_at":"2026-08-17T18:30:00Z","user":{}}]' \
               "THREADS=$NODELESS_THREADS" "THREADS=$AUTHORLESS_THREADS" \
               "THREADS=$EMPTY_AUTHOR_THREADS" \
               'REVIEWS=[{"submitted_at":0,"user":{"login":"chatgpt-codex-connector[bot]"}}]' \
               'REACTIONS=[{"content":"eyes","created_at":0,"user":{"login":"chatgpt-codex-connector[bot]"}}]' \
               'REACTIONS=[{"content":"eyes","created_at":"0","user":{"login":"chatgpt-codex-connector[bot]"}}]' \
               'REVIEWS=[{"submitted_at":"0","user":{"login":"chatgpt-codex-connector[bot]"}}]' \
               'REACTIONS=[{"content":{},"created_at":"2026-08-17T18:30:00Z","user":{"login":"x"}}]' \
               'REACTIONS=[{"content":"eyes","created_at":"2026-08-17T18:30:00Z","user":{"login":null}}]' \
               "THREADS=$NULL_LOGIN_THREADS"; do
  t="$EMPTY_THREADS"; r="$EMPTY_REVIEWS"; x="$NO_REACTIONS"
  drift="${missing#*=}"; [ "$drift" = "$missing" ] && drift=""
  case "${missing%%=*}" in
    THREADS)   t="$drift" ;;
    REVIEWS)   r="$drift" ;;
    REACTIONS) x="$drift" ;;
  esac
  got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
    ALL_THREADS="$t" ALL_REVIEWS="$r" \
    ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
    ALL_REACTIONS="$x" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" HEAD_CHECKS_DATE="" \
    bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
  if [ "$got" = "stale" ]; then
    ok "clean verdict, ALL_${missing%%=*} unreadable as '${drift:-<absent>}' → stale (an unread source proves nothing)"
  else
    fail "ALL_${missing%%=*} as '${drift:-<absent>}' expected 'stale', got '$got'"
  fi
done

# --- Test 23b: a malformed verdict timestamp → stale --------------------
# codex_clean_at is the REFERENCE POINT for the at-or-after guards, and the
# comparison is lexicographic: "zzzz" sorts after every real date, silently
# suppressing the activity those guards exist to find.
JUNK_TS_COMMENTS=$(jq -nc --arg login "$CODEX" --arg body "$CLEAN_688" \
  '{comments:[{author:{login:$login}, createdAt:"zzzz", body:$body}]}')
got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" ALL_COMMENTS="$JUNK_TS_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "verdict with a malformed createdAt → stale (reference point must be a real timestamp)"
else
  fail "junk verdict timestamp expected 'stale', got '$got'"
fi

# --- Test 23c: calendar-out-of-range verdict timestamp → stale ----------
# `9999-99-99T99:99:99Z` is positionally well-formed and sorts after every real
# date — exactly the value that would suppress the at-or-after guards.
for junk in "zzzz" "9999-99-99T99:99:99Z" "1970-01-01T00:00:00"; do
  jc=$(jq -nc --arg login "$CODEX" --arg body "$CLEAN_688" --arg at "$junk" \
    '{comments:[{author:{login:$login}, createdAt:$at, body:$body}]}')
  got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
    ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" ALL_COMMENTS="$jc" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
    ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" HEAD_CHECKS_DATE="" \
    bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
  if [ "$got" = "stale" ]; then
    ok "verdict timestamp '$junk' → stale (range-bound, not just digit-counted)"
  else
    fail "verdict timestamp '$junk' expected 'stale', got '$got'"
  fi
done

# --- Test 23d: a malformed LATER comment cannot hide behind the filter --
# `.author.login` drops an unattributable record, so a drifted comment published
# after the verdict would leave the verdict looking like the latest word.
DRIFT_LATER=$(jq -nc --arg login "$CODEX" --arg body "$CLEAN_688" --arg at "$AFTER_PUSH" \
  '{comments:[{author:{login:$login}, createdAt:$at, body:$body},
              {author:{}, createdAt:"2026-08-17T18:30:00Z", body:"..."}]}')
got=$(run_ledger "$DRIFT_LATER" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "drifted later comment → stale (ALL_COMMENTS is shape-validated too)"
else
  fail "drifted later comment expected 'stale', got '$got'"
fi

# --- Test 23e: drifted comment cannot hide from the post-anchor VETO ----
# The veto at (0) filters on .author.login and compares .createdAt too, so a
# drifted record must block there as well — not only on the Tier G ack path. Here
# the last Codex comment is a findings body (Tier G declines outright), a fresh 👍
# is present, and the drifted record is what the veto would have to see.
VETO_DRIFT=$(jq -nc --arg login "$CODEX" --arg body "$FINDINGS_688" \
  '{comments:[{author:{}, createdAt:"2026-08-17T18:30:00Z", body:"finding"},
              {author:{login:$login}, createdAt:"2026-08-17T17:36:38Z", body:$body}]}')
got=$(run_ledger "$VETO_DRIFT" "$EMPTY_THREADS" "$FRESH_PLUS1")
if [ "$got" = "stale" ]; then
  ok "drifted comment + fresh 👍 → stale (veto path inherits the shape check)"
else
  fail "veto-path drift expected 'stale', got '$got'"
fi

# --- Test 23f: two Codex comments in the SAME SECOND → stale ------------
# jq's sort is stable, so a tie falls back to document order — the very thing
# timestamp-sorting exists to stop trusting. GitHub stamps to the second, so a
# finding and a clean verdict can genuinely tie; which is "latest" is then not
# knowable from the payload. Both orderings must decline.
for order in clean-first findings-first; do
  if [ "$order" = "clean-first" ]; then
    tie=$(jq -nc --arg login "$CODEX" --arg c "$CLEAN_688" --arg f "$FINDINGS_688" --arg at "$AFTER_PUSH" \
      '{comments:[{author:{login:$login},createdAt:$at,body:$c},
                  {author:{login:$login},createdAt:$at,body:$f}]}')
  else
    tie=$(jq -nc --arg login "$CODEX" --arg c "$CLEAN_688" --arg f "$FINDINGS_688" --arg at "$AFTER_PUSH" \
      '{comments:[{author:{login:$login},createdAt:$at,body:$f},
                  {author:{login:$login},createdAt:$at,body:$c}]}')
  fi
  got=$(run_ledger "$tie" "$EMPTY_THREADS" "$NO_REACTIONS")
  if [ "$got" = "stale" ]; then
    ok "same-second clean+findings ($order) → stale (tie is unresolvable, so decline)"
  else
    fail "same-second tie ($order) expected 'stale', got '$got'"
  fi
done

# --- Test 23g: document order must not decide the verdict ---------------
# The clean verdict is NEWER but listed FIRST; a bare `last` would read the
# older findings comment, and the reverse payload would ack when it must not.
OUT_OF_ORDER=$(jq -nc --arg login "$CODEX" --arg c "$CLEAN_688" --arg f "$FINDINGS_688" \
  --arg new "$AFTER_PUSH" --arg old "$BEFORE_PUSH" \
  '{comments:[{author:{login:$login},createdAt:$new,body:$c},
              {author:{login:$login},createdAt:$old,body:$f}]}')
got=$(run_ledger "$OUT_OF_ORDER" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "newest verdict listed first → HEAD_SHA (selection is by timestamp, not order)"
else
  fail "out-of-order newest-first expected '$HEAD_SHA', got '$got'"
fi

REVERSED=$(jq -nc --arg login "$CODEX" --arg c "$CLEAN_688" --arg f "$FINDINGS_688" \
  --arg new "$LATE" --arg old "$AFTER_PUSH" \
  '{comments:[{author:{login:$login},createdAt:$new,body:$f},
              {author:{login:$login},createdAt:$old,body:$c}]}')
got=$(run_ledger "$REVERSED" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "newer findings listed first → stale (older clean verdict cannot supersede it)"
else
  fail "out-of-order findings-newest expected 'stale', got '$got'"
fi

# --- Test 23h: a Codex INFRA NOTICE is not engagement --------------------
# Verbatim from PR #693 itself, where this fix dogfooded its own bug: Codex has
# no environment for the repo, so it posts a notice instead of reviewing. The
# nudge cannot clear it — Codex genuinely cannot review until an operator acts —
# so counting it as engagement blocks the gate forever. `ack-ledger.sh` already
# downgrades un-clearable infra markers for review OBJECTS (Case 1 / 1b); the
# comment branches return long before that block, so they filter it themselves.
CODEX_NOTICE="To use Codex here, [create an environment for this repo](https://chatgpt.com/codex/cloud/settings/environments)."
got=$(run_ledger "$(mk_comments "$CODEX" "$BEFORE_PUSH" "$CODEX_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "none" ]; then
  ok "Codex infra notice alone → none (non-gating; the nudge cannot clear it)"
else
  fail "Codex infra notice expected 'none', got '$got'"
fi

# ...including when it lands AFTER the push, where the veto would otherwise fire.
got=$(run_ledger "$(mk_comments "$CODEX" "$LATE" "$CODEX_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "none" ]; then
  ok "post-anchor Codex infra notice → none (veto path filters it too)"
else
  fail "post-anchor infra notice expected 'none', got '$got'"
fi

# ...and it must not mask a real verdict by becoming the newest comment.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$LATE" "$CODEX_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict + later infra notice → HEAD_SHA (notice does not mask the verdict)"
else
  fail "verdict-then-notice expected '$HEAD_SHA', got '$got'"
fi

# ...but a REAL finding is still engagement, notice or no notice.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CODEX_NOTICE" "$LATE" "$FINDINGS_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "infra notice + later real finding → stale (filter is notice-only, not blanket)"
else
  fail "notice-then-finding expected 'stale', got '$got'"
fi

# --- Test 23i: a Codex USAGE-LIMIT NOTICE is not engagement ------------
# Verbatim from jikdak PR #351 (2026-09-20; also chrisyau.me #338 and
# diveanddev.com #46 the same hour): Codex is out of review credits, so it posts
# a quota notice instead of reviewing. Same class as 23h — the nudge cannot
# clear it, only the operator topping up can — so it must read `none`, not
# `stale`, or the gate blocks until someone touches skip-pr-grind.local.
CODEX_QUOTA_NOTICE="You have reached your Codex usage limits for code reviews. You can see your limits in the [Codex usage dashboard](https://chatgpt.com/codex/cloud/settings/usage).
To continue using code reviews, add credits to your account and enable them for code reviews in your [settings](https://chatgpt.com/codex/cloud/settings/code-review)."
got=$(run_ledger "$(mk_comments "$CODEX" "$BEFORE_PUSH" "$CODEX_QUOTA_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "none" ]; then
  ok "Codex usage-limit notice alone → none (non-gating; only the operator can clear it)"
else
  fail "Codex usage-limit notice expected 'none', got '$got'"
fi

# Codex posted it TWICE within seconds on every affected PR — two notices are still none.
got=$(run_ledger "$(mk_comments "$CODEX" "$LATE" "$CODEX_QUOTA_NOTICE" "$LATE" "$CODEX_QUOTA_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "none" ]; then
  ok "two post-anchor usage-limit notices → none (veto path filters them too)"
else
  fail "duplicate post-anchor usage-limit notices expected 'none', got '$got'"
fi

# ...and it must not mask a real verdict by becoming the newest comment.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$LATE" "$CODEX_QUOTA_NOTICE")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict + later usage-limit notice → HEAD_SHA (notice does not mask the verdict)"
else
  fail "verdict-then-quota-notice expected '$HEAD_SHA', got '$got'"
fi

# ...but a REAL finding is still engagement.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CODEX_QUOTA_NOTICE" "$LATE" "$FINDINGS_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "usage-limit notice + later real finding → stale (filter is notice-only, not blanket)"
else
  fail "quota-notice-then-finding expected 'stale', got '$got'"
fi

# The anchor is the full first sentence: the verbatim sentence embedded mid-body
# is still engagement — an unanchored regression would filter it to `none`.
got=$(run_ledger "$(mk_comments "$CODEX" "$LATE" "Heads-up: You have reached your Codex usage limits for code reviews. Will retry tomorrow.")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "prose mentioning usage limits mid-sentence → stale (start-anchored, not a keyword match)"
else
  fail "mid-sentence usage-limit prose expected 'stale', got '$got'"
fi

# --- Test 24: deleted-account shapes still ack --------------------------
# `user: null` / `author: null` is what GitHub emits for a deleted account, and
# it is NOT drift. Rejecting it would fail Tier G closed forever on any PR one of
# them ever touched — a worse bug than the drift the shape checks guard against.
GHOST_REACTIONS='[{"content":"heart","created_at":"2026-08-17T17:00:00Z","user":null}]'
GHOST_REVIEWS='[{"submitted_at":"2026-08-17T17:00:00Z","user":null,"state":"COMMENTED"}]'
GHOST_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":true,"comments":{"nodes":[{"author":null,"createdAt":"2026-08-17T15:00:00Z"}]}}]}}}}}'
got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="$GHOST_THREADS" ALL_REVIEWS="$GHOST_REVIEWS" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$GHOST_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "deleted-account records (user/author null) → HEAD_SHA (null is a real shape, not drift)"
else
  fail "ghost-account records expected '$HEAD_SHA', got '$got'"
fi

# ===========================================================================
# #904 — Codex Security Review (SR) comments.
# Observed on Dive-And-Dev/jikdak #446 and #447 (2026-09-30): verdict → a
# separate SR comment ~14-18s later → 👍. The SR became the last Codex comment,
# so Tier G never saw the verdict; both PRs read `stale` with both anchors empty.
# The clean SR body below is the full #446 capture with the SHA rewritten and the
# task id replaced; nothing else is changed.
# ===========================================================================
SR_AT="2026-08-17T18:12:08Z"       # verdict (AFTER_PUSH) + 14s, as on #446
PLUS1_AT="2026-08-17T18:12:12Z"    # SR + 4s, as on #446
SR_FOOTER=$'<details> <summary>ℹ️ About Codex security reviews in GitHub</summary>\n<br/>\n\nThis is an experimental Codex feature. Security reviews are triggered when:\n- You comment "@codex security review"\n- A regular code review gets triggered (for example, "@codex review" or when a PR is opened), and you’re opted in so security review runs alongside code review\n\nOnce complete, Codex will leave suggestions, or a comment if no findings are found.\n\n\n</details>'
SR_HEAD=$'### 🛡️ Codex Security Review · _Automatically triggered_'
SR_CLEAN_LINE='Security review completed. No security issues were found in this pull request.'
SR_LINKS=$'[View security finding report](https://chatgpt.com/codex/cloud/tasks/task_e_0000)\n\n_Only the user who started this review can view the report in Codex._\n\n'
mk_sr_clean() { printf '%s' "$SR_HEAD"$'\n\n'"$SR_CLEAN_LINE"$'\n\n'"**Reviewed commit:** \`$1\`"$'\n\n'"$SR_LINKS$SR_FOOTER"; }
# No findings SR has ever been observed; this shape is assumed. Anything that is
# not exactly the clean shape must be treated as a finding, so the exact wording
# here does not matter — only that it is not the clean shape.
mk_sr_findings() { printf '%s' "$SR_HEAD"$'\n\n'"Security review completed. 1 security issue was found in this pull request."$'\n\n'"**Reviewed commit:** \`$1\`"$'\n\n'"$SR_LINKS$SR_FOOTER"; }
mk_plus1() { jq -nc --arg at "$1" '[{content:"+1", created_at:$at, user:{login:"chatgpt-codex-connector[bot]"}}]'; }
expect() { if [ "$3" = "$2" ]; then ok "$1"; else fail "$1: expected '$2', got '$3'"; fi; }

SR_OK=$(mk_sr_clean "$CLEAN_SHA")
SR_BAD=$(mk_sr_findings "$CLEAN_SHA")
expect "#904 fixture: clean SR carries exactly one Reviewed-commit line" "1" \
  "$(printf '%s\n' "$SR_OK" | grep -c '^\*\*Reviewed commit:\*\*')"

# --- #446 replay: the headline. Both anchors empty, so Tier F cannot rescue it.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK")" \
  "$EMPTY_THREADS" "$(mk_plus1 "$PLUS1_AT")" "$CODEX" 1 "")
expect "#904 #446 replay: verdict → clean SR → 👍, no anchors → G" "${HEAD_SHA}:G" "$got"

# --- non-clean SRs keep the tier closed when they are the latest comment ------
OTHER_SR=$(mk_sr_clean "$OTHER_SHA")
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$OTHER_SR")" "$EMPTY_THREADS" "$NO_REACTIONS")
expect "#904 clean SR naming ANOTHER commit as latest comment → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_BAD")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 findings SR after the verdict → stale" "stale" "$got"
NOT_FIRST="$SR_HEAD"$'\n\nNote: an earlier run timed out.\n\n'"$SR_CLEAN_LINE"$'\n\n'"**Reviewed commit:** \`$CLEAN_SHA\`"$'\n\n'"$SR_LINKS$SR_FOOTER"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$NOT_FIRST")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 clean sentence not first after the header → stale" "stale" "$got"
CRLF_SR=$(printf '%s' "$SR_OK" | sed 's/$/\r/')
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$CRLF_SR")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 CRLF SR → stale" "stale" "$got"
NO_SHA_SR="$SR_HEAD"$'\n\n'"$SR_CLEAN_LINE"$'\n\n'"$SR_LINKS$SR_FOOTER"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$NO_SHA_SR")" "$EMPTY_THREADS" "$NO_REACTIONS")
expect "#904 SR with no Reviewed-commit line, after the anchor → stale" "stale" "$got"
TWO_SHA_SR="$SR_OK"$'\n\n'"**Reviewed commit:** \`$OTHER_SHA\`"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$TWO_SHA_SR")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 SR with a second Reviewed-commit line naming another SHA → stale" "stale" "$got"
# Deferred finding (arbiter, run 2abf90c6): the clean check must be the WHOLE
# shape, not a prefix — a findings SR keeping the clean opening must not pass.
APPENDED="$SR_HEAD"$'\n\n'"$SR_CLEAN_LINE"$'\n\n'"**Reviewed commit:** \`$CLEAN_SHA\`"$'\n\n### P1 Badge  Token logged in plaintext\n\n'"$SR_LINKS$SR_FOOTER"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$APPENDED")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 clean opening + appended finding → stale (whole-shape match)" "stale" "$got"

# Litmus finding: the clean shape must be anchored at BOTH ends. Mutation check —
# insert a finding line after EVERY line of the clean body (header … </details>,
# so inside the footer and after it too); every variant must read stale.
SR_LINE_COUNT=$(printf '%s\n' "$SR_OK" | wc -l)
mut_fail=0
for ((i = 1; i <= SR_LINE_COUNT; i++)); do
  MUT=$(printf '%s\n' "$SR_OK" | awk -v n="$i" '{print} NR == n {print "### P1 Badge  Token logged in plaintext"}')
  got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$MUT")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
  [ "$got" = "stale" ] || { mut_fail=$((mut_fail + 1)); echo "  mutation after line $i → '$got'"; }
done
expect "#904 finding inserted after each of the $SR_LINE_COUNT clean-SR lines → stale every time" "0" "$mut_fail"
# Litmus finding: text riding on an EXISTING line (not a new one) — the header
# is pinned exactly, so appending or prepending to it must also read stale.
for MUT in "$SR_HEAD — P1: Token logged in plaintext"$'\n'"${SR_OK#*$'\n'}" \
           "### P1: Token logged in plaintext; ${SR_OK#\#\#\# }"; do
  got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$MUT")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
  expect "#904 finding text on the SR header line → stale" "stale" "$got"
done
# …and the unmutated body with a trailing newline still acks. Passed as "$SR_OK"$'\n'
# directly: `$(printf '%s\n' …)` would strip the newline it adds.
NL_COMMENTS=$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK"$'\n')
expect "#904 fixture: trailing-newline SR body really ends in a newline" "true" \
  "$(jq -r '.comments[1].body | endswith("\n")' <<<"$NL_COMMENTS")"
got=$(run_ledger "$NL_COMMENTS" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 clean SR with a trailing newline → G (only whitespace is loose at the end)" "${HEAD_SHA}:G" "$got"

# --- the existing Tier G guards still hold with a clean SR in the mix ---------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK" "$LATE" "$FINDINGS_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
expect "#904 verdict → clean SR → findings comment → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK")" "$EMPTY_THREADS" "$EYES_AFTER_VERDICT" "$CODEX" 0 "")
expect "#904 verdict + clean SR + 👀 after both → stale" "stale" "$got"
got=$(FETCH_OK=1 ACK_CONTENT_IDENTITY=0 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
expect "#904 verdict + clean SR + later Codex /reviews entry → stale" "stale" "$got"

# --- same-second ties ------------------------------------------------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$AFTER_PUSH" "$SR_OK")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 verdict + clean SR in the same second → G" "${HEAD_SHA}:G" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$AFTER_PUSH" "$SR_OK" "$AFTER_PUSH" "$SR_OK")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 verdict + two clean SRs, all in the same second → G" "${HEAD_SHA}:G" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK" "$SR_AT" "$SR_BAD")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 clean SR tied with a findings SR (both for HEAD) → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$AFTER_PUSH" "$SR_BAD")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 verdict + findings SR in the same second → stale" "stale" "$got"

# --- (b): the order-independent, terminal security veto --------------------
EARLY_SR_AT="2026-08-17T18:00:00Z"
got=$(run_ledger "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$SR_BAD" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 (b) findings SR for HEAD BEFORE the clean verdict → stale" "stale" "$got"
# The production order with a push anchor: before #904, (0) slid its threshold to
# the 👍 and Tier F acked past the findings SR.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_BAD")" \
  "$EMPTY_THREADS" "$(mk_plus1 "$PLUS1_AT")")
expect "#904 (b) anchored: verdict → findings SR → 👍 → stale (not F)" "stale" "$got"
# Deferred finding (arbiter, run 2abf90c6): a leading blank line (as Codex's
# real findings comments carry — see FINDINGS_688) must not hide an SR.
LEADING_BLANK=$'\n'"$SR_BAD"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$LEADING_BLANK")" \
  "$EMPTY_THREADS" "$(mk_plus1 "$PLUS1_AT")")
expect "#904 (b) findings SR opening with a blank line, then 👍 → stale" "stale" "$got"
# Litmus finding: the #979 receipt-marker line, already skipped for verdicts,
# must not hide an SR either — else the findings SR escapes (b) and F acks.
MARKED_BAD=$'<!-- codex-review-receipt:v1 -->\n\n'"$SR_BAD"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$MARKED_BAD")" \
  "$EMPTY_THREADS" "$(mk_plus1 "$PLUS1_AT")")
expect "#904 (b) findings SR behind a receipt-marker line, then 👍 → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" $'<!-- codex-review-receipt:v1 -->\r\n\r\n'"$SR_BAD")" \
  "$EMPTY_THREADS" "$(mk_plus1 "$PLUS1_AT")")
expect "#904 (b) findings SR behind a CRLF receipt-marker line, then 👍 → stale" "stale" "$got"
# A comment line with visible text is skipped too (detection feeds a veto, so
# looser fails closed): the SR is detected, is not clean, and blocks.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" $'<!-- x --> note\n'"$SR_OK")" \
  "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 0 "")
expect "#904 comment-plus-text line before a clean SR → stale (an SR, not clean)" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$SR_BAD" "$SR_AT" "$SR_OK" "$LATE" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 (b) findings SR → later clean SR for HEAD → verdict → G" "${HEAD_SHA}:G" "$got"
OLD_BAD=$(mk_sr_findings "$OTHER_SHA")
got=$(run_ledger "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$OLD_BAD" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 (b) findings SR naming only an older commit, then verdict → clean SR → G" "${HEAD_SHA}:G" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$BEFORE_PUSH" "$NO_SHA_SR" "$AFTER_PUSH" "$CLEAN_688" "$SR_AT" "$SR_OK")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1)
expect "#904 (b) unparseable SR from before the push, then verdict → clean SR → G" "${HEAD_SHA}:G" "$got"

# --- (c): the post-anchor veto ignores a clean SR for HEAD ------------------
FRESH_AT="2026-08-17T17:50:00Z"; SR_AFTER_PLUS1="2026-08-17T17:55:00Z"
got=$(run_ledger "$(mk_comments "$CODEX" "$SR_AFTER_PLUS1" "$SR_OK")" "$EMPTY_THREADS" "$(mk_plus1 "$FRESH_AT")" "$CODEX" 1)
expect "#904 (c) anchored, no verdict comment, 👍 then clean SR → F" "${HEAD_SHA}:F" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$SR_AFTER_PLUS1" "$SR_BAD")" "$EMPTY_THREADS" "$(mk_plus1 "$FRESH_AT")")
expect "#904 (c) same, but the SR after the 👍 reports findings → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$SR_AT" "$SR_OK")" "$EMPTY_THREADS" "$NO_REACTIONS")
expect "#904 only a clean SR (no verdict, no 👍) → stale (engagement, not none)" "stale" "$got"

# --- content identity: real git objects in a throwaway repo -----------------
SR_TMP=$(mktemp -d)
trap 'rm -rf "$SR_TMP"' EXIT
SR_TMP=$(cd "$SR_TMP" && pwd -P)   # physical path: git reports one (macOS /var -> /private/var)
# Prove a fixture repo is disposable before mutating it: inside this run's mktemp
# root, and owning its own .git. Abort rather than touch anything else.
assert_disposable() {
  case "$1/" in "$SR_TMP/"*) ;; *) echo "FAIL: fixture $1 is outside $SR_TMP"; exit 1 ;; esac
  { [ "$(git -C "$1" rev-parse --absolute-git-dir)" = "$1/.git" ] \
    && [ "$(git -C "$1" rev-parse --show-toplevel)" = "$1" ]; } \
    || { echo "FAIL: fixture $1 does not own its git dir"; exit 1; }
}
git -C "$SR_TMP" init -q
assert_disposable "$SR_TMP"
git -C "$SR_TMP" config user.email t@example.com
git -C "$SR_TMP" config user.name tester
git -C "$SR_TMP" config commit.gpgsign false
printf 'x\n' > "$SR_TMP/f"
git -C "$SR_TMP" add f
git -C "$SR_TMP" commit -qm "feat: one"
PRED_FULL=$(git -C "$SR_TMP" rev-parse HEAD)
git -C "$SR_TMP" commit -q --amend -m "feat: one (reworded)"
AMEND_FULL=$(git -C "$SR_TMP" rev-parse HEAD)
PRED10="${PRED_FULL:0:10}"
run_in_repo() {
  # $1 = ALL_COMMENTS; ACK_CONTENT_IDENTITY on, HEAD = the amended commit.
  ( cd "$SR_TMP" && FETCH_OK=1 ACK_EMIT_TIER=1 ACK_CONTENT_IDENTITY=1 \
    ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$1" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
    ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="${AMEND_FULL:0:8}" HEAD_FULL_SHA="$AMEND_FULL" \
    HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null )
}
PRED_VERDICT="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"**Reviewed commit:** \`$PRED10\`$FOOTER"
AMEND_VERDICT="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"**Reviewed commit:** \`${AMEND_FULL:0:10}\`$FOOTER"
got=$(run_in_repo "$(mk_comments "$CODEX" "$AFTER_PUSH" "$PRED_VERDICT" "$SR_AT" "$(mk_sr_clean "$PRED10")")")
expect "#904 amend: verdict + clean SR name the predecessor, HEAD is a message-only amend → G" "${AMEND_FULL:0:8}:G" "$got"
got=$(run_in_repo "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "$PRED10")" "$AFTER_PUSH" "$AMEND_VERDICT")")
expect "#904 amend: findings SR names the predecessor, then a clean verdict for HEAD → stale" "stale" "$got"
# Deferred finding (arbiter, run 2abf90c6): a SHA whose object is NOT in this clone
# cannot be proven to be another commit — it must be treated as concerning HEAD.
got=$(run_in_repo "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "0123456789")" "$AFTER_PUSH" "$AMEND_VERDICT")")
expect "#904 findings SR naming an object missing from the clone, then clean verdict → stale" "stale" "$got"
# A genuinely different commit (different tree) present in the clone IS provably
# another commit: its findings SR concerns superseded code, so (b) ignores it.
OTHER_FULL=$(git -C "$SR_TMP" commit-tree "$(git -C "$SR_TMP" mktree </dev/null)" -m "chore: unrelated")
got=$(run_in_repo "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "${OTHER_FULL:0:10}")" "$AFTER_PUSH" "$AMEND_VERDICT" "$SR_AT" "$(mk_sr_clean "${AMEND_FULL:0:10}")")")
expect "#904 findings SR naming a PROVABLY different commit, then verdict → clean SR → G" "${AMEND_FULL:0:8}:G" "$got"
# PR-mode litmus finding: acks_head's "no" is not a proof of difference. A git
# that reports EQUAL trees but cannot read parents leaves identity undecided —
# the SHA must count as concerning HEAD, not as "another commit".
STUB_BIN="$SR_TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"rev-parse --verify --quiet"*"^{commit}"*) echo 1111111111111111111111111111111111111111; exit 0 ;;
  *"rev-parse --verify --quiet"*"^{tree}"*) echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904; exit 0 ;;
  *"cat-file commit"*) exit 1 ;;
  *"cat-file -e"*) exit 0 ;;   # objects "present" — presence alone must not prove difference
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/git"
got=$( cd "$SR_TMP" && PATH="$STUB_BIN:$PATH" FETCH_OK=1 ACK_EMIT_TIER=1 ACK_CONTENT_IDENTITY=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "abcdef0123")" "$AFTER_PUSH" "$CLEAN_688")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" ALL_REACTIONS="$NO_REACTIONS" \
  HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null )
expect "#904 equal trees but unreadable parents → identity undecided → findings SR vetoes → stale" "stale" "$got"
# Litmus finding: a TREE object's SHA resolves under ^{tree} too. A findings SR
# naming a tree (here the empty tree, present in the throwaway repo) is not
# "another commit" — it must stay a veto.
EMPTY_TREE=$(git -C "$SR_TMP" mktree </dev/null)
got=$(run_in_repo "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "${EMPTY_TREE:0:10}")" "$AFTER_PUSH" "$AMEND_VERDICT")")
expect "#904 findings SR naming a TREE object (not a commit) → stale" "stale" "$got"
# PR-mode litmus finding: `git show --format=%P` is not the stored parent list —
# a shallow boundary hides HEAD's parents, and log.showSignature prepends gpg
# output. Either made a message-only predecessor read as "provably other" and
# dropped its findings SR. Separate repo: .git/shallow affects the whole repo.
SH_REPO="$SR_TMP/shallow-repo"
git init -q "$SH_REPO"
assert_disposable "$SH_REPO"
git -C "$SH_REPO" config user.email t@example.com
git -C "$SH_REPO" config user.name tester
git -C "$SH_REPO" config commit.gpgsign false
printf 'x\n' > "$SH_REPO/f"
git -C "$SH_REPO" add f
git -C "$SH_REPO" commit -qm "feat: base"
printf 'y\n' > "$SH_REPO/f"
git -C "$SH_REPO" commit -qam "feat: change"
SH_PRED=$(git -C "$SH_REPO" rev-parse HEAD)
SH_BASE=$(git -C "$SH_REPO" rev-parse HEAD^)
git -C "$SH_REPO" commit -q --amend -m "feat: change (reworded)"
SH_HEAD=$(git -C "$SH_REPO" rev-parse HEAD)
# Same tree, same parent as HEAD, carrying a (bogus) signature header.
SH_SIGNED=$(printf 'tree %s\nparent %s\nauthor t <t@example.com> 1 +0000\ncommitter t <t@example.com> 1 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n\nfeat: change (signed)\n' \
  "$(git -C "$SH_REPO" rev-parse "$SH_HEAD^{tree}")" "$SH_BASE" | git -C "$SH_REPO" hash-object -t commit -w --stdin)
SH_VERDICT="Codex Review: Didn't find any major issues. Swish!"$'\n\n'"**Reviewed commit:** \`${SH_HEAD:0:10}\`$FOOTER"
run_sh_comments() {
  # $1 = ALL_COMMENTS; any further args are env assignments for the ledger.
  local comments="$1"; shift
  ( cd "$SH_REPO" && env "$@" FETCH_OK=1 ACK_EMIT_TIER=1 ACK_CONTENT_IDENTITY=1 \
    ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$comments" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" ALL_REACTIONS="$NO_REACTIONS" \
    HEAD_SHA="${SH_HEAD:0:8}" HEAD_FULL_SHA="$SH_HEAD" \
    HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null )
}
run_in_sh_repo() {
  # $1 = findings-SR SHA, then the verdict for HEAD; further args go to run_sh_comments.
  local sha="$1"; shift
  run_sh_comments "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "${sha:0:10}")" "$AFTER_PUSH" "$SH_VERDICT")" "$@"
}
got=$(run_in_sh_repo "$SH_SIGNED" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=log.showSignature GIT_CONFIG_VALUE_0=true)
expect "#904 findings SR names a signed same-tree/same-parent predecessor, log.showSignature on → stale" "stale" "$got"
printf '%s\n' "$SH_HEAD" > "$SH_REPO/.git/shallow"
got=$(run_in_sh_repo "$SH_PRED")
expect "#904 findings SR names the predecessor, HEAD is a shallow boundary → stale" "stale" "$got"
# Arbiter finding (run 3b104891): acks_head itself read `%P`, so a same-tree twin
# with a DIFFERENT real parent read as parentless like HEAD when both are shallow
# boundaries, and acked. A clean SR naming the twin then cleared HEAD's findings SR.
SH_TWIN=$(git -C "$SH_REPO" commit-tree "$(git -C "$SH_REPO" rev-parse "$SH_HEAD^{tree}")" -p "$SH_PRED" -m "feat: change (twin)")
printf '%s\n%s\n' "$SH_HEAD" "$SH_TWIN" > "$SH_REPO/.git/shallow"
got=$(run_sh_comments "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "${SH_HEAD:0:10}")" "$AFTER_PUSH" "$SH_VERDICT" "$SR_AT" "$(mk_sr_clean "${SH_TWIN:0:10}")")")
expect "#904 findings SR for HEAD, clean SR names a same-tree twin with another parent, both shallow → stale" "stale" "$got"
got=$(run_ledger "$(mk_comments "$CODEX" "$EARLY_SR_AT" "$(mk_sr_findings "0123456789")" "$AFTER_PUSH" "$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS" "$CODEX" 1 "")
expect "#904 same with ACK_CONTENT_IDENTITY=0 (direct match only) → G (another commit)" "${HEAD_SHA}:G" "$got"

# --- Test 25: receipt-marker line before the verdict (#979) --------------
# Verbatim shape from PR #976 (2026-10-15T18:53:23Z): Codex now opens the clean
# verdict with an HTML-comment marker line, which defeated the start anchor.
RECEIPT_CLEAN=$'<!-- codex-review-receipt:v1 -->\n\n'"$CLEAN_688"
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" "$RECEIPT_CLEAN")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean verdict behind a leading receipt-marker line → HEAD_SHA (#979)"
else
  fail "receipt-marker clean verdict expected '$HEAD_SHA', got '$got'"
fi

# --- Test 25b: a marker line does not unlock a findings body -------------
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" $'<!-- codex-review-receipt:v1 -->\n'"$QUOTED_CLEAN")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "receipt marker + findings body quoting the clean sentence → stale (anchor still holds)"
else
  fail "receipt marker + findings body expected 'stale', got '$got'"
fi

# --- Test 25c: only WHOLE-LINE comments are skipped ----------------------
# Visible text on the marker line means the verdict is not the first thing shown.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" $'<!-- x --> note\n'"$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "comment marker followed by visible text on the same line → stale"
else
  fail "comment-plus-text first line expected 'stale', got '$got'"
fi

# --- Test 25d: an abruptly-closed comment is visible text ----------------
# HTML closes `<!-->` immediately, so the rest of the line renders.
got=$(run_ledger "$(mk_comments "$CODEX" "$AFTER_PUSH" $'<!--> P1: unresolved finding -->\n'"$CLEAN_688")" "$EMPTY_THREADS" "$NO_REACTIONS")
if [ "$got" = "stale" ]; then
  ok "abruptly-closed '<!-->' line is not skipped → stale"
else
  fail "abruptly-closed comment line expected 'stale', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
