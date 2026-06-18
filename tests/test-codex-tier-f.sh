#!/usr/bin/env bash
# tests/test-codex-tier-f.sh
#
# Verifies scripts/ack-ledger.sh Tier F — the Codex-only reaction tier that
# lets the merge gate WAIT for chatgpt-codex-connector without deadlocking.
#
# Background: Codex has no SHA-keyed clean signal. On a findings-free review it
# removes its 👀 (eyes) reaction and adds a 👍 (+1) reaction on the PR body —
# no /reviews APPROVED entry, no check-run, no commit-status (empirically
# verified on Dive-And-Dev/chrisyau.me PR #142 clean / PR #140 findings). Tier F
# reads the 👍 as a HEAD-ack when its created_at postdates HEAD_PUSH_DATE (the push
# event time); fails closed to `stale` when no push anchor exists (#189);
# an engaged-but-not-fresh Codex (👀, or a 👍 from before the last push) is
# `stale` so the gate waits. Codex's findings path is acked/blocked by the
# existing Tiers A (inline threads) and B (/reviews on HEAD), NOT by Tier F.

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
HEAD_SHA="abc12345"
HEAD_DATE="2026-06-06T16:12:23Z"          # HEAD commit time
FRESH="2026-06-06T16:24:36Z"              # 👍 AFTER HEAD (PR #142 real timing)
STALE_TS="2026-06-06T16:00:00Z"           # 👍 BEFORE HEAD (pre-push)
COMMITTER_AFTER_PUSH="2026-06-06T16:30:00Z" # committer LATER than push (HEAD_DATE 16:12) and the +1 (FRESH 16:24); discriminates push-only anchor from max() (#189)

# --- Resolved-thread push-anchored freshness fixtures (#186/#187) ---
# The resolved-Codex-thread ack (Tier A.2) is keyed to the PUSH timestamp only
# (never the backdatable committer date) and to a RESOLVER-AUTHORED resolution
# comment. Out-of-scope-acknowledged dismissals: the worker (operator) posts a
# reply then resolves, so resolvedBy == the reply author and that comment's
# createdAt ≈ resolution time. Codex itself authored the original finding
# (comments.nodes[0]); the resolver is the operator.
RESOLVER="chris-yyau"                       # operator who resolves out-of-scope threads
RESOLVE_PUSH="2026-06-06T16:12:23Z"         # HEAD_PUSH_DATE anchor (push event time)
RESOLVE_AFTER="2026-06-06T16:24:36Z"        # resolver reply AFTER push → fresh → ack
RESOLVE_BEFORE="2026-06-06T16:00:00Z"       # resolver reply BEFORE push → stale resolution
RESOLVE_TRAILING="2026-06-06T16:30:00Z"     # non-resolver comment AFTER the resolver reply

# Build a resolved+non-outdated Codex thread node.
#   $1 = resolvedBy login   $2 = resolver-reply createdAt
#   $3 = (optional) a Codex bot re-engagement reply createdAt (Codex's follow-up after resolver disposition)
# comments(first:1) carries Codex's original finding (owner-identity match);
# resolutionComments(last:10) carries the reply trail used for freshness.
mk_codex_resolved() {
  local rb="$1" reply="$2" other="${3:-}"
  local nodes="{\"author\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"createdAt\":\"$STALE_TS\"},{\"author\":{\"login\":\"$rb\"},\"createdAt\":\"$reply\"}"
  if [ -n "$other" ]; then
    nodes="$nodes,{\"author\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"createdAt\":\"$other\"}"
  fi
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"resolvedBy":{"login":"%s"},"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"%s"}]},"resolutionComments":{"nodes":[%s]}}]}}}}}' "$rb" "$STALE_TS" "$nodes"
}

# Empty fixtures for every non-reaction source so Tiers A–E fall through and
# Tier F is the only path that can fire.
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_REVIEWS='[]'
EMPTY_COMMENTS='{"comments":[]}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_STATUSES='[]'

# Reaction-array fixtures (shape of `gh api repos/{o}/{r}/issues/{n}/reactions`).
mk_reaction() {
  # $1 = content (+1 | eyes), $2 = created_at
  printf '[{"content":"%s","created_at":"%s","user":{"login":"chatgpt-codex-connector[bot]"}}]' "$1" "$2"
}

# Generic Codex run with all non-reaction sources empty.
run_codex() {
  # $1 = ALL_REACTIONS, $2 = HEAD_COMMITTED_DATE, $3 = login (default codex),
  # $4 = ACK_EMIT_TIER (default 0), $5 = HEAD_PUSH_DATE (default empty)
  local login="${3:-$CODEX}" emit="${4:-0}" push="${5:-}"
  FETCH_OK=1 ACK_EMIT_TIER="$emit" \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$1" HEAD_COMMITTED_DATE="$2" HEAD_PUSH_DATE="$push" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$login" 2>/dev/null
}

# --- Test 1: fresh 👍 (created_at > HEAD) → HEAD_SHA (the clean-ack case) ---
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "fresh 👍 (after HEAD commit) → HEAD_SHA (clean ack)"
else
  fail "fresh 👍 expected '$HEAD_SHA', got '$got'"
fi

# --- Test 1b: same case under ACK_EMIT_TIER=1 → SHA:F ---
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "$CODEX" 1 "$HEAD_DATE")
if [ "$got" = "${HEAD_SHA}:F" ]; then
  ok "fresh 👍 under ACK_EMIT_TIER=1 → '${HEAD_SHA}:F'"
else
  fail "fresh 👍 tier-exposed expected '${HEAD_SHA}:F', got '$got'"
fi

# --- Test 2: stale 👍 (created_at < HEAD) → stale (must re-review HEAD) ---
got=$(run_codex "$(mk_reaction '+1' "$STALE_TS")" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")
if [ "$got" = "stale" ]; then
  ok "stale 👍 (before HEAD commit) → stale (engaged, not fresh)"
else
  fail "stale 👍 expected 'stale', got '$got'"
fi

# --- Test 3: 👀 eyes only (no +1) → stale (review in progress) ---
got=$(run_codex "$(mk_reaction 'eyes' "$FRESH")" "$HEAD_DATE")
if [ "$got" = "stale" ]; then
  ok "👀 eyes only → stale (Codex still reviewing)"
else
  fail "👀 eyes only expected 'stale', got '$got'"
fi

# --- Test 4: no reactions ([]) and no reviews → none (not engaged) ---
got=$(run_codex '[]' "$HEAD_DATE")
if [ "$got" = "none" ]; then
  ok "empty reactions [] + no reviews → none (Codex not on this PR)"
else
  fail "empty reactions expected 'none', got '$got'"
fi

# --- Test 5: ALL_REACTIONS unset/empty-string (unupgraded caller) → none ---
# Backward-compat: a caller that never fetched reactions exports "" → Tier F
# no-ops and Codex falls through to the pre-Tier-F `none`.
got=$(run_codex '' "$HEAD_DATE")
if [ "$got" = "none" ]; then
  ok "empty-string ALL_REACTIONS (unupgraded caller) → none (Tier F no-op)"
else
  fail "empty-string ALL_REACTIONS expected 'none', got '$got'"
fi

# --- Test 6: non-Codex bot with a Codex reaction present → reaction ignored ---
# Tier F is login-guarded; cursor must be unaffected by ALL_REACTIONS and
# resolve via its own tiers (none here, since all sources empty).
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "cursor")
if [ "$got" = "none" ]; then
  ok "non-Codex bot (cursor) ignores ALL_REACTIONS → none (Tier F login-guarded)"
else
  fail "cursor with reaction present expected 'none', got '$got'"
fi

# --- Test 7: fresh 👍 BUT an unresolved Codex thread → stale (Tier A wins) ---
# A clean 👍 must NOT override live inline findings. Tier A (unresolved
# threads) short-circuits to stale before control ever reaches Tier F.
CODEX_THREAD='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_THREAD" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "fresh 👍 + unresolved Codex thread → stale (Tier A precedence over F)"
else
  fail "fresh 👍 + unresolved thread expected 'stale', got '$got'"
fi

# --- Test 8: Codex findings COMMENTED /reviews on HEAD → stale (excluded from Tier B) ---
# A Codex /reviews entry is ALWAYS a findings post (Codex 👍s when clean), so it
# must NOT be a clean HEAD-ack — Codex is excluded from Tier B and falls through
# to the downgrade block → stale, so the worker triages. No reaction in the
# fixture, isolating the Tier-B-exclusion → downgrade → stale path (not the
# eyes-override).
CODEX_REVIEW_HEAD='[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","commit_id":"abc12345ef","body":"### 💡 Codex Review"}]'
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$CODEX_REVIEW_HEAD" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "Codex COMMENTED /reviews on HEAD → stale (excluded from Tier B; findings need triage)"
else
  fail "Codex COMMENTED /reviews on HEAD expected 'stale', got '$got'"
fi

# --- Test 8b: registered bot COMMENTED /reviews on HEAD → HEAD_SHA via Tier B (no regression) ---
# The Tier-B exclusion is Codex-only; cursor's /reviews entry on HEAD still acks.
CURSOR_REVIEW_HEAD='[{"user":{"login":"cursor[bot]"},"state":"COMMENTED","commit_id":"abc12345ef","body":"reviewed"}]'
got=$(FETCH_OK=1 ACK_EMIT_TIER=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$CURSOR_REVIEW_HEAD" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" cursor 2>/dev/null)
if [ "$got" = "${HEAD_SHA}:B" ]; then
  ok "registered bot COMMENTED /reviews on HEAD → '${HEAD_SHA}:B' (Tier B exclusion is Codex-only)"
else
  fail "cursor COMMENTED /reviews on HEAD expected '${HEAD_SHA}:B', got '$got'"
fi

# --- Test 9: fresh-looking 👍 but no HEAD_PUSH_DATE → stale (#189 fail-CLOSED) ---
# With no server-stamped push anchor there is no trustworthy freshness proof, so the
# +1 path fails CLOSED to stale — the committer date is NOT consulted (#189). Here
# both HEAD_COMMITTED_DATE and HEAD_PUSH_DATE are empty (run_codex's push arg omitted).
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "")
if [ "$got" = "stale" ]; then
  ok "fresh 👍 but no HEAD_PUSH_DATE → stale (#189 fail-CLOSED; committer date not consulted)"
else
  fail "fresh 👍 + no push anchor expected 'stale', got '$got'"
fi

# --- Test 10: FETCH_OK=0 → stale (fail-CLOSED) even with a fresh 👍 ---
got=$(FETCH_OK=0 ACK_EMIT_TIER=0 \
  ALL_THREADS='' ALL_REVIEWS='' ALL_COMMENTS='' ALL_CHECK_RUNS='' ALL_STATUSES='' \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "FETCH_OK=0 → stale (fail-CLOSED, fresh 👍 ignored)"
else
  fail "FETCH_OK=0 expected 'stale', got '$got'"
fi

# --- Test 11: 👀 eyes + a fresh-looking 👍 → stale (eyes-override) ---
# The eyes-override is timestamp-independent: if Codex is actively re-reviewing
# (👀 present) it must block even if a 👍 (possibly a leftover) looks fresh.
EYES_PLUS_FRESH=$(printf '[{"content":"eyes","created_at":"%s","user":{"login":"chatgpt-codex-connector[bot]"}},{"content":"+1","created_at":"%s","user":{"login":"chatgpt-codex-connector[bot]"}}]' "$FRESH" "$FRESH")
got=$(run_codex "$EYES_PLUS_FRESH" "$HEAD_DATE")
if [ "$got" = "stale" ]; then
  ok "👀 + fresh-looking 👍 → stale (eyes-override beats reaction timestamp)"
else
  fail "👀 + fresh 👍 expected 'stale' (eyes-override), got '$got'"
fi

# --- Test 12: RESOLVED current-head Codex thread → HEAD_SHA (#187 out-of-scope clear) ---
# A Codex thread the worker resolved on the CURRENT head (out-of-scope-acknowledged
# dismissal — no code push, so no new commit to trigger a fresh 👍) must CLEAR via
# Tier A.2, or Codex stays stale until --max-wait bails. Under the push-anchored
# design (#186/#187), it acks iff: HEAD_PUSH_DATE present AND the resolver-authored
# resolution comment is newer than the push. Here the operator (resolvedBy) posted a
# reply at RESOLVE_AFTER (16:24) > the push anchor (16:12) → ack. A stale 👍 in the
# fixture confirms the resolved thread acks on its own (no fresh reaction needed);
# eyes-override does not fire (no 👀).
CODEX_RESOLVED_CURRENT="$(mk_codex_resolved "$RESOLVER" "$RESOLVE_AFTER")"
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_CURRENT" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$STALE_TS")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved current-head Codex thread (push present, resolver reply after push) → HEAD_SHA (#187 clears)"
else
  fail "resolved current-head Codex thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 12a: OUTDATED-only Codex thread → stale (must NOT ack new HEAD) ---
# A Codex finding from superseded code (HEAD advanced past it) must not clear —
# Codex has to re-review the new HEAD. No fresh 👍, no 👀 → stale.
CODEX_OUTDATED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_OUTDATED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "outdated-only Codex thread → stale (superseded code must not ack new HEAD)"
else
  fail "outdated-only Codex thread expected 'stale', got '$got'"
fi

# --- Test 12c: resolved current-head Codex thread BUT 👀 present → stale (eyes beats Tier A.2) ---
# The hoisted eyes-override must win: if Codex is mid-reviewing a newer push, a
# resolved older-thread must NOT ack ahead of the in-progress review.
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_CURRENT" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction 'eyes' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved current-head thread + 👀 → stale (hoisted eyes-override beats Tier A.2)"
else
  fail "resolved current-head thread + 👀 expected 'stale', got '$got'"
fi

# --- Test 12d: MIXED — resolved-current + outdated Codex threads → stale (outdated precedence) ---
# A resolved-current thread would ack on its own (Test 12), but a coexisting
# OUTDATED thread means Codex is behind on HEAD and must re-review. The outdated
# check runs first, so the mixed state stays stale (no premature ack).
CODEX_MIXED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}},{"isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_MIXED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "mixed resolved-current + outdated Codex threads → stale (outdated takes precedence)"
else
  fail "mixed resolved-current + outdated expected 'stale', got '$got'"
fi

# --- Test 12e: OUTDATED thread + fresh 👍 → HEAD_SHA (deadlock fix; fresh 👍 beats outdated) ---
# The normal fix flow: Codex flagged commit X, worker fixed + pushed Y, Codex
# re-reviewed Y clean (fresh 👍). GitHub keeps the X thread as OUTDATED forever.
# The fresh 👍 must clear it — otherwise the outdated thread keeps the PR stale
# until --max-wait on every PR that ever had a Codex finding (the permanent
# deadlock Codex + cubic flagged on PR #185). Fresh-👍 is checked before outdated.
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_OUTDATED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "outdated thread + fresh 👍 → HEAD_SHA (fresh 👍 clears the retained-outdated deadlock)"
else
  fail "outdated thread + fresh 👍 expected '$HEAD_SHA' (deadlock fix), got '$got'"
fi

# --- Test 12b: same RESOLVED thread for a REGISTERED bot still acks (no regression) ---
# Non-Codex bots ack on any disposed thread (the original Tier A.2 behavior).
CURSOR_DISPOSED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"cursor[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CURSOR_DISPOSED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" cursor 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "disposed thread for registered bot (cursor) → HEAD_SHA (exclusion is Codex-only)"
else
  fail "disposed cursor thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 13: resolved current-head Codex thread + fresh 👍 → HEAD_SHA ---
# Findings addressed (thread resolved on current head) AND Codex re-reviewed
# clean (fresh 👍). Either signal alone acks; together they unambiguously do.
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_CURRENT" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "disposed Codex thread + fresh 👍 → HEAD_SHA (Tier F acks the clean re-review)"
else
  fail "disposed Codex thread + fresh 👍 expected '$HEAD_SHA', got '$got'"
fi

# --- Test 14: paginated reactions, Codex 👍 on page 2 → HEAD_SHA (pagination) ---
# Regression for the MEDIUM finding: with >30 PR-body reactions, --paginate
# yields a STREAM of arrays. Tier F's `jq -rs` must slurp+flatten so Codex's
# reaction on a later page is found. Simulated here as two concatenated arrays
# (the shape `gh api --paginate` emits); the human reactions are page 1.
PAGE1='[{"content":"+1","created_at":"2026-06-06T16:20:00Z","user":{"login":"alice"}},{"content":"heart","created_at":"2026-06-06T16:21:00Z","user":{"login":"bob"}}]'
PAGE2=$(mk_reaction '+1' "$FRESH")
PAGINATED=$(printf '%s\n%s' "$PAGE1" "$PAGE2")
got=$(run_codex "$PAGINATED" "$HEAD_DATE" "$CODEX" 0 "$HEAD_DATE")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "paginated reactions, Codex 👍 on page 2 → HEAD_SHA (jq -rs slurps the stream)"
else
  fail "paginated reactions expected '$HEAD_SHA' (pagination handled), got '$got'"
fi

# --- Test 15: HEAD_PUSH_DATE later than HEAD_COMMITTED_DATE → blocks stale 👍 ---
# Force-push scenario: commit committer date is old (pre-dates a prior Codex 👍)
# but the push event timestamp (HEAD_PUSH_DATE) is newer. Tier F must use the
# push timestamp as the freshness anchor — the 👍 predates the push, so stale.
OLD_COMMIT_DATE="2026-06-01T00:00:00Z"  # old backdated committer date
STALE_PLUS1="2026-06-02T00:00:00Z"       # 👍 after commit date but before push
PUSH_DATE="2026-06-03T00:00:00Z"          # push event date (most recent anchor)
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$STALE_PLUS1")" \
  HEAD_COMMITTED_DATE="$OLD_COMMIT_DATE" HEAD_PUSH_DATE="$PUSH_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "👍 predates HEAD_PUSH_DATE → stale (force-push protection via push anchor)"
else
  fail "force-push protection expected 'stale' (👍 predates push), got '$got'"
fi

# --- Test 16: HEAD_PUSH_DATE provided, fresh 👍 after push → HEAD_SHA ---
# Same push timestamp setup, but the 👍 arrived AFTER the push → ack.
FRESH_PLUS1="2026-06-04T00:00:00Z"  # after PUSH_DATE
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH_PLUS1")" \
  HEAD_COMMITTED_DATE="$OLD_COMMIT_DATE" HEAD_PUSH_DATE="$PUSH_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "👍 after HEAD_PUSH_DATE → HEAD_SHA (fresh ack anchored to push timestamp)"
else
  fail "fresh 👍 after push expected '$HEAD_SHA', got '$got'"
fi

# --- Test 18: resolved-current Codex thread with createdAt BEFORE anchor → stale ---
# The P1 Codex finding (PR #185, line 236): a resolved non-outdated thread from a
# prior commit can survive a HEAD advance without going isOutdated when the diff
# hunk is outside the changed file. The freshness guard filters the stale thread
# from the positive-ack path (no false HEAD ack). But Codex DID engage on an
# older commit — the resolved thread is evidence of prior engagement. The correct
# signal is `stale` (Codex must re-review HEAD), NOT `none` (Codex absent from PR).
# Returning `none` was a fail-OPEN bug: the gate would treat Codex as not-engaged
# and allow merge without a fresh Codex re-review (Cursor finding, PR #185).
# With HEAD_PUSH_DATE absent, the unified (3) block's first guard returns `stale`
# immediately (fail-CLOSED) — no anchor exists, so nothing can be proven fresh.
CODEX_RESOLVED_STALE='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"2026-06-06T16:00:00Z"}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_STALE" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved thread createdAt BEFORE anchor (no reactions) → stale (engaged on older commit; fail-CLOSED)"
else
  fail "resolved thread before anchor + no reactions expected 'stale', got '$got'"
fi

# --- Test 18b: resolved thread BEFORE anchor but stale 👍 present → stale ---
# Same pre-anchor thread, but Codex has reacted with a stale 👍 (also pre-anchor).
# The thread is filtered out (false ack blocked), and the stale reaction engages
# Codex without acking HEAD → stale (waiting for fresh re-review signal).
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_STALE" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$STALE_TS")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved thread BEFORE anchor + stale 👍 → stale (engaged but not fresh; guard blocks thread ack)"
else
  fail "resolved thread before anchor + stale 👍 expected 'stale', got '$got'"
fi

# --- Test 19: resolved thread, committer date newer than finding BUT push date absent → stale (#186) ---
# The exact #186 fail-OPEN that the push-anchored design closes. CODEX_RESOLVED_FRESH's
# first-comment createdAt (16:24) is NEWER than HEAD_COMMITTED_DATE (16:12) — under the
# OLD design that newer-than-committer-date signal falsely acked HEAD. The committer
# date is backdatable (force-push an old commit), so it must never gate a resolved-thread
# ack. With HEAD_PUSH_DATE absent there is no trustworthy anchor → fail-CLOSED to stale.
CODEX_RESOLVED_FRESH='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"2026-06-06T16:24:36Z"}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_FRESH" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved thread, committer-date-newer but push date absent → stale (#186: committer date not trusted)"
else
  fail "resolved thread, push date absent expected 'stale' (#186 fail-CLOSED), got '$got'"
fi

# --- Test 19b: a NON-resolver comment is the thread's LAST comment → stale (last-comment rule) ---
# Codex deep-review finding: freshness must require the thread's LAST comment to be the
# resolver's, not just "some resolver comment exists after the push". Here resolvedBy
# (the operator) replied at 16:00, then Codex itself re-engaged with a comment at 16:24
# (AFTER the push) — so the thread's last activity is a non-resolver comment. The thread
# is not settled at the resolver's disposition → stale.
CODEX_RESOLVED_AUTHOR=$(mk_codex_resolved "$RESOLVER" "$RESOLVE_BEFORE" "$RESOLVE_AFTER")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_AUTHOR" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolver reply pre-push + non-resolver reply post-push → stale (author-identity guard)"
else
  fail "non-resolver reply must not freshen; expected 'stale', got '$got'"
fi

# --- Test 19c: resolver reply BEFORE push → stale (#186 stale resolution, push present) ---
# Push anchor IS present (16:12) but the resolver resolved on an earlier commit:
# their reply is dated 16:00 < push → the resolution predates HEAD → stale.
CODEX_RESOLVED_OLDREPLY=$(mk_codex_resolved "$RESOLVER" "$RESOLVE_BEFORE")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_OLDREPLY" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolver reply before push (resolution predates HEAD) → stale (#186 common case)"
else
  fail "resolver reply before push expected 'stale', got '$got'"
fi

# --- Test 19d: resolver reply AFTER push, but a LATER non-resolver comment → stale (tightening) ---
# THE case the deep-review tightening closes. The resolver's reply (16:24) IS newer than
# the push (16:12) — under the old max()-over-resolver-comments logic this would have
# ACKed. But Codex (a non-resolver) then commented at 16:30, so the thread's last activity
# is NOT the resolver's disposition → stale. Closes the "later activity re-freshens a
# resolution" residual fail-OPEN.
CODEX_RESOLVED_TRAILING=$(mk_codex_resolved "$RESOLVER" "$RESOLVE_AFTER" "$RESOLVE_TRAILING")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_TRAILING" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolver reply fresh but trailing non-resolver comment → stale (last-comment tightening)"
else
  fail "trailing non-resolver comment must block ack; expected 'stale', got '$got'"
fi

# --- Test 19e: resolvedBy is the finding bot itself → stale (self-clear exclusion) ---
# A thread cannot be cleared by the bot that filed it. Even with a fresh, after-push
# "resolver" comment, resolvedBy == the Codex login is excluded ($rb != finding bot) → stale.
CODEX_RESOLVED_SELFBOT=$(mk_codex_resolved "chatgpt-codex-connector[bot]" "$RESOLVE_AFTER")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_SELFBOT" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolvedBy == finding bot → stale (self-clear exclusion)"
else
  fail "finding-bot self-resolve must not ack; expected 'stale', got '$got'"
fi

# --- Test 19e2: resolvedBy is the BARE finding-bot login (no [bot] suffix) → stale ---
# GitHub may return the bot's login bare ("chatgpt-codex-connector") or [bot]-suffixed,
# so the exclusion checks both ($rb == $login OR $rb == $login_bot). This pins the bare
# arm so it is not dead code: a bare-login self-resolve must still fail CLOSED → stale.
CODEX_RESOLVED_SELFBARE=$(mk_codex_resolved "chatgpt-codex-connector" "$RESOLVE_AFTER")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_SELFBARE" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolvedBy == bare finding-bot login → stale (bare-form self-clear exclusion)"
else
  fail "bare finding-bot self-resolve must not ack; expected 'stale', got '$got'"
fi

# --- Test 19f: TWO resolved threads — one fresh, one stale → stale (all-or-stale) ---
# A fresh resolved thread must NOT mask a stale one. Node 1 is proven fresh (resolver
# reply 16:24 > push 16:12); node 2 is stale (resolver reply 16:00 <= push). The ack
# fires only when EVERY resolved+non-outdated Codex thread is fresh, so this → stale.
_mk_codex_node() { # $1 = resolver-reply createdAt
  printf '{"isResolved":true,"isOutdated":false,"resolvedBy":{"login":"%s"},"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"%s"}]},"resolutionComments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"},"createdAt":"%s"},{"author":{"login":"%s"},"createdAt":"%s"}]}}' \
    "$RESOLVER" "$STALE_TS" "$STALE_TS" "$RESOLVER" "$1"
}
CODEX_RESOLVED_MIXED="{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$(_mk_codex_node "$RESOLVE_AFTER"),$(_mk_codex_node "$RESOLVE_BEFORE")]}}}}}"
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_MIXED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "mixed fresh + stale resolved threads → stale (all-or-stale, no masking)"
else
  fail "stale resolved thread must not be masked by a fresh one; expected 'stale', got '$got'"
fi

# --- Test 19g: resolver reply timestamp EQUAL to push timestamp → stale (boundary condition) ---
# The freshness check requires strictly greater than ($lastc.createdAt > $push),
# so a resolver reply at exactly the push time must not ack (the <= arm catches it).
CODEX_RESOLVED_BOUNDARY="{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[$(_mk_codex_node "$RESOLVE_PUSH")]}}}}}"
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_BOUNDARY" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="$RESOLVE_PUSH" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolver reply == push timestamp → stale (boundary: freshness requires strictly >)"
else
  fail "resolver reply == push timestamp expected 'stale' (boundary), got '$got'"
fi

# --- Test 20: resolved thread + fresh resolver reply BUT empty push anchor → stale (#186 settling check) ---
# THE settling check for the fail-CLOSED design. Even a perfect resolver reply newer
# than every other signal does NOT ack when HEAD_PUSH_DATE is absent (fork head, aged-out
# events). On a P1 merge gate, a visible stall beats a silent fail-OPEN. This deliberately
# reverses the prior "empty anchor ⇒ ack" backward-compat (council 2026-06-17).
CODEX_RESOLVED_FRESHREPLY=$(mk_codex_resolved "$RESOLVER" "$RESOLVE_AFTER")
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_FRESHREPLY" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "fresh resolver reply + empty push anchor → stale (#186 fail-CLOSED settling check)"
else
  fail "empty push anchor expected 'stale' (#186 fail-CLOSED), got '$got'"
fi

# --- Test 18c: resolved Codex thread + NO reactions + empty push anchor → stale (fail-CLOSED) ---
# The P1 safety bug (Cursor finding, PR #185): a resolved+non-outdated Codex thread that
# does NOT prove current-HEAD freshness must land on `stale`, not `none`. Under the
# push-anchored design that proof is unavailable here: HEAD_PUSH_DATE is empty, so the
# unified (3) block — entered because a resolved+non-outdated Codex thread exists — hits
# its empty-push-date guard and returns stale immediately. Before the original fix the
# fall-through returned `none`, treating Codex as absent from the PR (fail-OPEN).
# CODEX_RESOLVED_STALE is defined above (legacy-shape fixture: no resolvedBy/resolutionComments).
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_STALE" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved pre-anchor thread + no reactions → stale (fail-CLOSED: Codex engaged on older commit)"
else
  fail "resolved pre-anchor thread + no reactions expected 'stale' (not 'none'), got '$got'"
fi

# --- Test 18d: resolved Codex thread + no reactions + empty push anchor → stale (#186 fail-CLOSED) ---
# Reversal of the old backward-compat pass-all. With no HEAD_PUSH_DATE there is no
# trustworthy anchor and no resolver-authored resolution proof, so the resolved-thread
# the (3) block's empty-push-date guard returns stale. Old callers that never export a push date
# now fail CLOSED on a P1 merge gate rather than acking unconditionally (council 2026-06-17).
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_STALE" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "resolved thread + empty push anchor → stale (#186 fail-CLOSED; reverses old pass-all backward-compat)"
else
  fail "resolved thread + empty push anchor expected 'stale' (#186 fail-CLOSED), got '$got'"
fi

# --- Test 17: fresh-looking +1 but empty HEAD_PUSH_DATE → stale (#189 fail-CLOSED) ---
# The git committer date is client-stamped and backdatable, so it must NOT anchor
# a +1 ack. With no server-stamped push anchor there is no trustworthy freshness
# proof → fail-CLOSED to stale (mirrors the resolved-thread path, #186). This
# inverts the prior backward-compat fallback that #189 identified as a fail-OPEN:
# a leftover +1 newer than a backdated committer date could falsely ack HEAD.
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_PUSH_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "fresh +1 but empty HEAD_PUSH_DATE → stale (#189 fail-CLOSED; committer date not trusted)"
else
  fail "empty push + fresh +1 expected 'stale' (#189), got '$got'"
fi

# --- Test 17b: committer date LATER than push, +1 between them → HEAD_SHA (anchor is push, NOT max) ---
# With committer (COMMITTER_AFTER_PUSH, 16:30) > push (HEAD_DATE, 16:12) and the +1
# (FRESH, 16:24) between them: max() would anchor on the committer date and return
# stale, while push-only anchors on the push event and acks. Proves the committer
# date is no longer consulted even when present and later (#189).
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="$COMMITTER_AFTER_PUSH" HEAD_PUSH_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "committer later than push, +1 after push → HEAD_SHA (anchor is push-only, not max; #189)"
else
  fail "push-only discriminator expected '$HEAD_SHA', got '$got'"
fi

# --- Test 17c: empty committer date, push present, fresh +1 → HEAD_SHA (push alone suffices) ---
# Proves the +1 ack needs ONLY the push anchor — no committer date at all. A regression
# that re-required HEAD_COMMITTED_DATE would fail here (committer is empty), while the
# push-only contract correctly acks since FRESH (16:24) > push (HEAD_DATE 16:12). (#189)
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" \
  HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "empty committer + push present + fresh +1 → HEAD_SHA (push anchor alone suffices; #189)"
else
  fail "push-alone positive guard expected '$HEAD_SHA', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
