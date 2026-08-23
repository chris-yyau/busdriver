#!/usr/bin/env bash
# test-head-push-date-bounded.sh — #624 bounded HEAD_PUSH_DATE probe regression.
#
# Shared mechanism: scripts/lib/head-push-date.sh (single-page events fetch, no
# --paginate). Missing PushEvent in the bounded window → empty HEAD_PUSH_DATE →
# existing SHA-bound earliest check-suite fallback; never committer date (#189).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/head-push-date.sh"
FIXTURES="$SCRIPT_DIR/fixtures/head-push-date"
FETCH_PR_STATE="$REPO_ROOT/scripts/fetch-pr-state.sh"
ACK_SCRIPT="$REPO_ROOT/scripts/ack-ledger.sh"
GH_MOCK="$SCRIPT_DIR/fixtures/gh-mock-head-push-bounded"

# shellcheck source=../scripts/lib/head-push-date.sh disable=SC1091
. "$LIB"

pass=0
fail=0
check() {
  local name="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then echo "PASS: $name"; pass=$((pass + 1))
  else echo "FAIL: $name — expected [$expected] got [$got]"; fail=$((fail + 1)); fi
}

FULL_SHA="abcdef1234567890abcdef1234567890abcdef12"
BRANCH="feat/test-branch"
HEAD_SHA="${FULL_SHA:0:8}"
FRESH="2026-06-06T16:24:36Z"
COMMITTER="2026-06-06T16:30:00Z"
CODEX="chatgpt-codex-connector"
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_REVIEWS='[]'
EMPTY_COMMENTS='{"comments":[]}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_STATUSES='[]'

mk_reaction() {
  printf '[{"content":"%s","created_at":"%s","user":{"login":"chatgpt-codex-connector[bot]"}}]' "$1" "$2"
}

# --- Tier F fail-closed: empty push + committer date + fresh 👍 → stale (#189) ---
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$COMMITTER" \
  HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
check "empty HEAD_PUSH_DATE + committer date → stale (no committer fallback)" "stale" "$got"

# --- Tier F fallback path: empty push + HEAD_CHECKS_DATE + fresh 👍 → HEAD_SHA (#269) ---
got=$(FETCH_OK=1 \
  ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$EMPTY_REVIEWS" ALL_COMMENTS="$EMPTY_COMMENTS" \
  ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" ALL_STATUSES="$EMPTY_STATUSES" \
  ALL_REACTIONS="$(mk_reaction '+1' "$FRESH")" HEAD_COMMITTED_DATE="$COMMITTER" \
  HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="2026-06-06T16:12:23Z" HEAD_SHA="$HEAD_SHA" \
  bash "$ACK_SCRIPT" "$CODEX" 2>/dev/null)
check "empty HEAD_PUSH_DATE + check-suite anchor → HEAD_SHA" "$HEAD_SHA" "$got"

# --- Fixture extraction: push on bounded page 1 ---
events_on_page1=$(cat "$FIXTURES/events-push-on-page1.json")
got=$(head_push_date_from_events_json "$events_on_page1" "$FULL_SHA" "$BRANCH")
check "push on page 1 → HEAD_PUSH_DATE" "2026-08-10T12:00:00Z" "$got"

# --- Fixture: no matching PushEvent in bounded window → empty ---
events_outside=$(cat "$FIXTURES/events-push-outside-window.json")
got=$(head_push_date_from_events_json "$events_outside" "$FULL_SHA" "$BRANCH")
check "push outside bounded window → empty" "" "$got"

# --- Production jq filter is the shared library constant (drift guard) ---
lib_filter=$(awk -F"'" '/^HEAD_PUSH_DATE_JQ_FILTER=/{print $2; exit}' "$LIB")
if [[ -z "$lib_filter" ]]; then
  echo "FAIL: could not read HEAD_PUSH_DATE_JQ_FILTER from $LIB"
  fail=$((fail + 1))
else
  got=$(printf '%s' "$events_on_page1" | jq -r --arg head "$FULL_SHA" --arg ref "refs/heads/$BRANCH" "$lib_filter")
  check "library jq filter matches fixture extraction" "2026-08-10T12:00:00Z" "$got"
fi

# --- Bounded gh fetch: no --paginate on events API ---
export PATH="$GH_MOCK:$PATH"
export GH_MOCK_EVENTS_FILE="$FIXTURES/events-push-on-page1.json"
got=$(resolve_head_push_date owner repo "$FULL_SHA" "$BRANCH")
unset GH_MOCK_EVENTS_FILE
check "resolve_head_push_date via bounded gh mock" "2026-08-10T12:00:00Z" "$got"

export GH_MOCK_EVENTS_FILE="$FIXTURES/events-push-outside-window.json"
got=$(resolve_head_push_date owner repo "$FULL_SHA" "$BRANCH")
unset GH_MOCK_EVENTS_FILE
check "bounded gh mock, no push in window → empty" "" "$got"

# --- fetch-pr-state.sh uses shared resolver (outside-window fixture) ---
export GH_MOCK_EVENTS_FILE="$FIXTURES/events-push-outside-window.json"
unset FETCH_OK HEAD_PUSH_DATE HEAD_COMMITTED_DATE 2>/dev/null || true
# shellcheck source=/dev/null
. "$FETCH_PR_STATE" 123
unset GH_MOCK_EVENTS_FILE
[[ "$FETCH_OK" = "1" ]] || { echo "FAIL: FETCH_OK not 1 on bounded miss"; fail=$((fail + 1)); }
check "fetch-pr-state bounded miss → empty HEAD_PUSH_DATE" "" "${HEAD_PUSH_DATE:-}"

echo "───────────────────────────────"
echo "Total: $((pass + fail))  Pass: $pass  Fail: $fail"
[[ "$fail" -eq 0 ]]
