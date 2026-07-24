#!/usr/bin/env bash
# tests/test-ack-ledger-devin.sh
#
# Verifies scripts/ack-ledger.sh handles `devin-ai-integration` (Devin Review)
# correctly as a registered gating bot in the pr-grind ack panel.
#
# Devin is a PLAIN Tier A / Tier B bot (like CodeRabbit) — it needs no
# Devin-specific code in ack-ledger.sh; these tests pin that the generic tiers
# gate it correctly:
#   - actionable findings post as inline review THREADS -> Tier A -> `stale`,
#     with precedence OVER the Tier B clean-ack;
#   - a clean COMMENTED-on-HEAD review -> Tier B HEAD-ack (NOT a deadlock);
#   - a resolved/outdated thread -> Tier A disposed HEAD-ack.
#
# Devin is deliberately OFF Tier E: its `Devin Review` commit-status goes
# pending -> SUCCESS even when the review HAS findings (verified on PRs
# #238/#240/#241), so a status-based ack would be unsafe (Codex P1 on #241).
# HEAD coverage instead comes from the `Devin Review` GitHub check, which
# pr-grind Step 1 waits on. These tests confirm a `success` status never
# rescues an otherwise-stale Devin into a HEAD-ack.

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

HEAD_SHA="abc12345"
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_REVIEWS='[]'
EMPTY_COMMENTS='{"comments":[]}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_STATUSES='[]'
DEVIN_STATUS_SUCCESS='[{"context":"Devin Review","state":"success","created_at":"2026-06-23T06:40:00Z","id":2}]'

run() {
  # $1=login $2=threads $3=reviews $4=statuses
  FETCH_OK=1 \
  ALL_THREADS="$2" \
  ALL_REVIEWS="$3" \
  ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  ALL_STATUSES="$4" \
  HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$1" 2>/dev/null
}

mk_devin_thread() {
  # $1=isResolved $2=isOutdated
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRT_1","isResolved":%s,"isOutdated":%s,"comments":{"nodes":[{"author":{"login":"devin-ai-integration[bot]"}}]}}]}}}}}' "$1" "$2"
}

# Clean COMMENTED /reviews whose commit_id direct-matches HEAD (acks_head 8-char
# prefix, no git). A clean Devin review acks here via Tier B exactly like CodeRabbit.
DEVIN_COMMENTED_HEAD='[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","commit_id":"abc12345","body":"Devin Review: no issues found."}]'

# --- Test 1: unresolved Devin thread -> stale (Tier A findings gate) ---
got=$(run devin-ai-integration "$(mk_devin_thread false false)" "$EMPTY_REVIEWS" "$EMPTY_STATUSES")
if [ "$got" = "stale" ]; then
  ok "unresolved Devin thread -> stale (Tier A findings gate)"
else
  fail "unresolved Devin thread expected 'stale', got '$got'"
fi

# --- Test 2: Tier A precedence — unresolved thread + clean COMMENTED + success status -> stale ---
# The decisive P1-adjacent case: even with a clean-looking COMMENTED /reviews on
# HEAD AND a `success` status, an unresolved finding thread keeps Devin `stale`.
# Tier A runs before Tier B, and Devin is off Tier E, so neither rescues it.
got=$(run devin-ai-integration "$(mk_devin_thread false false)" "$DEVIN_COMMENTED_HEAD" "$DEVIN_STATUS_SUCCESS")
if [ "$got" = "stale" ]; then
  ok "unresolved thread beats clean COMMENTED + success status -> stale (Tier A precedence; off Tier E)"
else
  fail "unresolved thread + clean COMMENTED + success status expected 'stale', got '$got'"
fi

# --- Test 3: clean COMMENTED-on-HEAD -> HEAD_SHA via Tier B (NO deadlock) ---
# Devin is NOT excluded from Tier B (excluding it would deadlock clean reviews on
# `stale` forever). A clean COMMENTED on HEAD acks like CodeRabbit.
got=$(run devin-ai-integration "$EMPTY_THREADS" "$DEVIN_COMMENTED_HEAD" "$EMPTY_STATUSES")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "clean Devin COMMENTED-on-HEAD -> HEAD_SHA (Tier B clean-ack; no deadlock)"
else
  fail "clean Devin COMMENTED-on-HEAD expected '$HEAD_SHA', got '$got'"
fi

# --- Test 4: resolved Devin thread -> HEAD_SHA (Tier A disposed ack) ---
got=$(run devin-ai-integration "$(mk_devin_thread true false)" "$EMPTY_REVIEWS" "$EMPTY_STATUSES")
if [ "$got" = "$HEAD_SHA" ]; then
  ok "resolved Devin thread -> HEAD_SHA (Tier A disposed ack)"
else
  fail "resolved Devin thread expected '$HEAD_SHA', got '$got'"
fi

# --- Test 5: success status ALONE (no /reviews, no thread) -> none (off Tier E) ---
# Confirms the `Devin Review` success status is NOT itself an ack — Devin is off
# Tier E, so a bare status with no review/thread is non-gating `none`.
got=$(run devin-ai-integration "$EMPTY_THREADS" "$EMPTY_REVIEWS" "$DEVIN_STATUS_SUCCESS")
if [ "$got" = "none" ]; then
  ok "Devin success status alone -> none (off Tier E; status is not an ack)"
else
  fail "Devin success status alone expected 'none', got '$got'"
fi

# --- Issue #489: review-once-at-create bots strand a clean ANCESTOR review ---
# Devin/cursor review only the PR-create commit; after a fix-round push their
# clean COMMENTED review is pinned to a superseded SHA. Case 4 releases it to
# `none` (non-gating) instead of deadlocking Invariant 2 on `stale` forever.

# Devin's clean one-and-done COMMENTED review, commit_id on an ANCESTOR (does NOT
# match HEAD). Case 4 releases ONLY when the normalized body EXACTLY matches a
# known Devin clean template (fail-CLOSED anchored whitelist — ADR 0027 / #489).
DEVIN_COMMENTED_ANCESTOR='[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","commit_id":"ae578624","body":"✅ Devin Review: No Issues Found"}]'
# Body-ONLY finding: clean phrase present but extra prose follows. The fail-open
# a substring/denylist could not catch — must stay stale.
DEVIN_COMMENTED_BODY_FINDING='[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","commit_id":"ae578624","body":"No issues found. Critical: unsanitized input enables SQL injection."}]'
# CHANGES_REQUESTED on the ancestor — a real finding channel (ever_approved>0).
DEVIN_CHANGES_REQUESTED='[{"user":{"login":"devin-ai-integration[bot]"},"state":"CHANGES_REQUESTED","commit_id":"ae578624","body":"Please fix the null deref on line 47."}]'

# --- Test 6: Devin clean template on ancestor -> none (Case 4, no deadlock) ---
got=$(run devin-ai-integration "$EMPTY_THREADS" "$DEVIN_COMMENTED_ANCESTOR" "$EMPTY_STATUSES")
if [[ "$got" == "none" ]]; then
  ok "Devin clean template-on-ancestor -> none (#489 Case 4; no stale deadlock)"
else
  fail "Devin clean template-on-ancestor expected 'none', got '$got'"
fi

# --- Test 7: Devin BODY-ONLY finding on ancestor -> stale (fail-closed) ---
# A finding placed only in the summary (no thread, no CHANGES_REQUESTED) leaves
# residual text after normalization, so the anchored whitelist does NOT match.
got=$(run devin-ai-integration "$EMPTY_THREADS" "$DEVIN_COMMENTED_BODY_FINDING" "$EMPTY_STATUSES")
if [[ "$got" == "stale" ]]; then
  ok "Devin body-only finding-on-ancestor -> stale (#489 Case 4 anchored whitelist, no fail-open)"
else
  fail "Devin body-only finding-on-ancestor expected 'stale', got '$got'"
fi

# --- Test 7b: non-ASCII body-only findings -> stale (no complement-strip fail-open) ---
# A finding in a non-Latin script must not be normalized away into the whitelist.
mk_devin_body() {
  printf '[{"user":{"login":"devin-ai-integration[bot]"},"state":"COMMENTED","commit_id":"ae578624","body":%s}]' "$1"
}
nonascii_bodies=(
  '"No issues found. 存在严重漏洞"'
  '"No issues found. Критическая уязвимость"'
  '"✅ Devin Review: No Issues Found — но исправьте SQL-инъекцию"'
)
nonascii_fail=0
for b in "${nonascii_bodies[@]}"; do
  got=$(run devin-ai-integration "$EMPTY_THREADS" "$(mk_devin_body "$b")" "$EMPTY_STATUSES")
  [[ "$got" == "stale" ]] || { fail "non-ASCII suffix body expected 'stale', got '$got' for $b"; nonascii_fail=1; }
done
[[ "$nonascii_fail" -eq 0 ]] && ok "non-ASCII body-only findings -> stale (#489 anchored match, no complement-strip)"

# --- Test 7c: decorated clean templates -> none (markdown/emoji tolerated) ---
clean_variants=(
  '"✅ Devin Review: No Issues Found"'
  '"**No issues found**"'
  '"no issues found."'
  '"No issues found!"'
)
clean_ok=0
for b in "${clean_variants[@]}"; do
  got=$(run devin-ai-integration "$EMPTY_THREADS" "$(mk_devin_body "$b")" "$EMPTY_STATUSES")
  [[ "$got" == "none" ]] || { fail "decorated clean template expected 'none', got '$got' for $b"; clean_ok=1; }
done
[[ "$clean_ok" -eq 0 ]] && ok "decorated clean templates -> none (#489 whitelist tolerates markdown/emoji)"

# --- Test 8: Devin finding as an UNRESOLVED THREAD -> stale (Tier A gates it) ---
# Even with a clean summary on the ancestor, an open thread keeps Devin `stale`
# — Case 4 never overrides Tier A.
DEVIN_OPEN_THREAD=$(mk_devin_thread false false)
got=$(run devin-ai-integration "$DEVIN_OPEN_THREAD" "$DEVIN_COMMENTED_ANCESTOR" "$EMPTY_STATUSES")
if [[ "$got" == "stale" ]]; then
  ok "Devin unresolved thread + clean ancestor summary -> stale (#489 Tier A gates findings)"
else
  fail "Devin unresolved thread + clean ancestor summary expected 'stale', got '$got'"
fi

# --- Test 9: Devin CHANGES_REQUESTED on ancestor -> stale (ever_approved>0) ---
got=$(run devin-ai-integration "$EMPTY_THREADS" "$DEVIN_CHANGES_REQUESTED" "$EMPTY_STATUSES")
if [[ "$got" == "stale" ]]; then
  ok "Devin CHANGES_REQUESTED-on-ancestor -> stale (#489 Case 4 skipped; findings preserved)"
else
  fail "Devin CHANGES_REQUESTED-on-ancestor expected 'stale', got '$got'"
fi

# --- Test 10: cursor is NOT in Case 4 (fail-closed on unconfirmed template) ---
# cursor's clean-body string is unconfirmed, so a cursor COMMENTED ancestor review
# is deliberately left `stale`, never guessed into `none`.
CURSOR_COMMENTED_ANCESTOR='[{"user":{"login":"cursor[bot]"},"state":"COMMENTED","commit_id":"ae578624","body":"No issues found."}]'
got=$(run cursor "$EMPTY_THREADS" "$CURSOR_COMMENTED_ANCESTOR" "$EMPTY_STATUSES")
if [[ "$got" == "stale" ]]; then
  ok "cursor clean COMMENTED-on-ancestor -> stale (#489 Case 4 is devin-only, fail-closed)"
else
  fail "cursor clean COMMENTED-on-ancestor expected 'stale', got '$got'"
fi

# --- Test 11: a NON-review-once bot with a matching clean body -> stale ---
# Case 4 is login-gated to devin: another bot's identical clean body must not release.
CODERABBIT_COMMENTED_ANCESTOR='[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"ae578624","body":"No issues found"}]'
got=$(run coderabbitai "$EMPTY_THREADS" "$CODERABBIT_COMMENTED_ANCESTOR" "$EMPTY_STATUSES")
if [[ "$got" == "stale" ]]; then
  ok "coderabbitai matching clean body -> stale (#489 Case 4 is login-gated)"
else
  fail "coderabbitai matching clean body expected 'stale', got '$got'"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]] && exit 0 || exit 1
