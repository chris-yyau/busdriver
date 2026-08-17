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
  jq -nc --arg login "$login" \
    '{comments: [$ARGS.positional | _nwise(2) | {author: {login: $login}, createdAt: .[0], body: .[1]}]}' \
    --args "$@"
}

run_ledger() {
  # $1 = ALL_COMMENTS, $2 = ALL_THREADS, $3 = ALL_REACTIONS,
  # $4 = login (default codex), $5 = ACK_EMIT_TIER (default 0)
  FETCH_OK=1 ACK_EMIT_TIER="${5:-0}" \
  ALL_THREADS="$2" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$1" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$3" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
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
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
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
  got=$(FETCH_OK=1 \
    ALL_THREADS="$t" ALL_REVIEWS="$r" \
    ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
    ALL_REACTIONS="$x" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
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
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" ALL_COMMENTS="$JUNK_TS_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
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
  got=$(FETCH_OK=1 \
    ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$LATER_REVIEW" ALL_COMMENTS="$jc" \
    ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
    ALL_REACTIONS="$NO_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
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

# --- Test 24: deleted-account shapes still ack --------------------------
# `user: null` / `author: null` is what GitHub emits for a deleted account, and
# it is NOT drift. Rejecting it would fail Tier G closed forever on any PR one of
# them ever touched — a worse bug than the drift the shape checks guard against.
GHOST_REACTIONS='[{"content":"heart","created_at":"2026-08-17T17:00:00Z","user":null}]'
GHOST_REVIEWS='[{"submitted_at":"2026-08-17T17:00:00Z","user":null,"state":"COMMENTED"}]'
GHOST_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":true,"comments":{"nodes":[{"author":null,"createdAt":"2026-08-17T15:00:00Z"}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$GHOST_THREADS" ALL_REVIEWS="$GHOST_REVIEWS" \
  ALL_COMMENTS="$(mk_comments "$CODEX" "$AFTER_PUSH" "$CLEAN_688")" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$GHOST_REACTIONS" HEAD_SHA="$HEAD_SHA" HEAD_PUSH_DATE="$PUSH_AT" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "deleted-account records (user/author null) → HEAD_SHA (null is a real shape, not drift)"
else
  fail "ghost-account records expected '$HEAD_SHA', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
