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
# reads the 👍 as a HEAD-ack when its created_at postdates HEAD's commit time;
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
  # $4 = ACK_EMIT_TIER (default 0)
  local login="${3:-$CODEX}" emit="${4:-0}"
  FETCH_OK=1 ACK_EMIT_TIER="$emit" \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$1" HEAD_COMMITTED_DATE="$2" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$login" 2>/dev/null
}

# --- Test 1: fresh 👍 (created_at > HEAD) → HEAD_SHA (the clean-ack case) ---
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "fresh 👍 (after HEAD commit) → HEAD_SHA (clean ack)"
else
  fail "fresh 👍 expected '$HEAD_SHA', got '$got'"
fi

# --- Test 1b: same case under ACK_EMIT_TIER=1 → SHA:F ---
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "$HEAD_DATE" "$CODEX" 1)
if [ "$got" = "${HEAD_SHA}:F" ]; then
  ok "fresh 👍 under ACK_EMIT_TIER=1 → '${HEAD_SHA}:F'"
else
  fail "fresh 👍 tier-exposed expected '${HEAD_SHA}:F', got '$got'"
fi

# --- Test 2: stale 👍 (created_at < HEAD) → stale (must re-review HEAD) ---
got=$(run_codex "$(mk_reaction '+1' "$STALE_TS")" "$HEAD_DATE")
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

# --- Test 9: fresh-looking 👍 but HEAD_COMMITTED_DATE empty → stale ---
# Without a HEAD commit time we cannot prove freshness; pin the date-guard so a
# missing committedDate degrades to wait, never to a false ack.
got=$(run_codex "$(mk_reaction '+1' "$FRESH")" "")
if [ "$got" = "stale" ]; then
  ok "fresh 👍 but empty HEAD_COMMITTED_DATE → stale (cannot confirm fresh)"
else
  fail "fresh 👍 + empty head-date expected 'stale', got '$got'"
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

# --- Test 12: RESOLVED current-head Codex thread → HEAD_SHA (out-of-scope clear) ---
# A Codex thread the worker resolved on the CURRENT head (the out-of-scope-
# acknowledged dismissal — no code push, so no new commit to trigger a fresh
# 👍) must CLEAR via Tier A.2, or Codex would stay stale until --max-wait bails.
# A stale 👍 in the fixture confirms the resolved thread acks on its own (no
# fresh reaction needed). Eyes-override does not fire (no 👀).
CODEX_RESOLVED_CURRENT='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_RESOLVED_CURRENT" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$STALE_TS")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved current-head Codex thread → HEAD_SHA (Tier A.2 clears out-of-scope dismissal)"
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
  ALL_REACTIONS="$(mk_reaction 'eyes' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
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
  ALL_REACTIONS='[]' HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "mixed resolved-current + outdated Codex threads → stale (outdated takes precedence)"
else
  fail "mixed resolved-current + outdated expected 'stale', got '$got'"
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
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
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
got=$(run_codex "$PAGINATED" "$HEAD_DATE")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "paginated reactions, Codex 👍 on page 2 → HEAD_SHA (jq -rs slurps the stream)"
else
  fail "paginated reactions expected '$HEAD_SHA' (pagination handled), got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
