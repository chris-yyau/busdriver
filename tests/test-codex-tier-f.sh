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

# --- Test 8: findings COMMENTED /reviews on HEAD → HEAD_SHA via Tier B ---
# Codex's FINDINGS path is SHA-keyed (commit_id == HEAD) and acks through the
# existing Tier B, not Tier F. ACK_EMIT_TIER must report B, not F.
CODEX_REVIEW_HEAD='[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","commit_id":"abc12345ef","body":"### 💡 Codex Review"}]'
got=$(FETCH_OK=1 ACK_EMIT_TIER=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$CODEX_REVIEW_HEAD" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction 'eyes' "$FRESH")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "${HEAD_SHA}:B" ]; then
  ok "findings COMMENTED /reviews on HEAD → '${HEAD_SHA}:B' (Tier B, not F)"
else
  fail "findings on HEAD expected '${HEAD_SHA}:B', got '$got'"
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

# --- Test 12: DISPOSED Codex thread + stale 👍 → stale (Tier A exclusion) ---
# Regression for the HIGH finding: a resolved/outdated Codex thread from an
# older commit must NOT ack a new HEAD via Tier A. Codex is excluded from the
# Tier-A disposed→ack branch and falls through to Tier F, which sees only a
# stale 👍 → stale (waits for a fresh re-review).
CODEX_DISPOSED='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_DISPOSED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$STALE_TS")" HEAD_COMMITTED_DATE="$HEAD_DATE" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
if [ "$got" = "stale" ]; then
  ok "disposed Codex thread + stale 👍 → stale (Tier A disposed-ack excludes Codex)"
else
  fail "disposed Codex thread + stale 👍 expected 'stale', got '$got'"
fi

# --- Test 12b: same DISPOSED thread for a REGISTERED bot still acks (no regression) ---
# The Tier-A exclusion is Codex-only; cursor's disposed thread must still ack HEAD.
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

# --- Test 13: DISPOSED Codex thread + fresh 👍 → HEAD_SHA (findings addressed + clean re-review) ---
# Codex raised findings on an older commit, they were fixed (thread resolved),
# and Codex re-reviewed the new HEAD clean (fresh 👍). Tier A excluded → Tier F
# acks on the fresh reaction.
got=$(FETCH_OK=1 \
  ALL_THREADS="$CODEX_DISPOSED" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
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
