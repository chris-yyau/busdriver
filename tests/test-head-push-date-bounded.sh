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
got=$(head_push_checks_fallback_eligible_from_events_json "$events_outside" "$BRANCH")
check "push outside bounded window → check-suite fallback ineligible" "0" "$got"
got=$(head_push_checks_fallback_eligible_from_events_json "$events_outside" "$BRANCH" 0)
check "same-repo bounded miss (explicit not-cross-repo) → ineligible" "0" "$got"

# --- Fork / cross-repository PR (#271-class regression guard) ---
# For a cross-repo PR the events feed we query is the BASE repo's, which can never
# contain a CreateEvent or PushEvent for a branch that lives in the fork. Denying the
# fallback there would make EVERY fork PR permanently stale — strictly worse than the
# bounded-miss hole this gate closes. The #624 gate is therefore NOT APPLICABLE to a
# cross-repo PR: preserve the pre-#624 #269/#271 behaviour. Same fixture, only the flag differs.
got=$(head_push_checks_fallback_eligible_from_events_json "$events_outside" "$BRANCH" 1)
check "cross-repo (fork) PR → fallback stays eligible (no #271-class fail-close)" "1" "$got"

# --- Fixture: CreateEvent for branch, no PushEvent on ref → fallback eligible ---
events_create=$(cat "$FIXTURES/events-create-branch-no-push.json")
got=$(head_push_date_from_events_json "$events_create" "$FULL_SHA" "$BRANCH")
check "CreateEvent branch, no push on ref → empty HEAD_PUSH_DATE" "" "$got"
got=$(head_push_checks_fallback_eligible_from_events_json "$events_create" "$BRANCH")
check "CreateEvent branch, no push on ref → check-suite fallback eligible" "1" "$got"
# Negatives on the SAME fixture — CreateEvent.payload.ref is the bare branch name,
# so eligibility must match on the name AND require ref_type=="branch".
got=$(head_push_checks_fallback_eligible_from_events_json "$events_create" "other/branch")
check "CreateEvent for a different branch → fallback ineligible" "0" "$got"
got=$(head_push_checks_fallback_eligible_from_events_json "$events_create" "release/tag-only")
check "CreateEvent ref_type=tag (not branch) → fallback ineligible" "0" "$got"

# --- Production jq filter is the shared library constant (drift guard) ---
lib_filter=$(awk -F"'" '/^HEAD_PUSH_DATE_JQ_FILTER=/{print $2; exit}' "$LIB")
if [[ -z "$lib_filter" ]]; then
  echo "FAIL: could not read HEAD_PUSH_DATE_JQ_FILTER from $LIB"
  fail=$((fail + 1))
else
  got=$(printf '%s' "$events_on_page1" | jq -r --arg head "$FULL_SHA" --arg ref "refs/heads/$BRANCH" "$lib_filter")
  check "library jq filter matches fixture extraction" "2026-08-10T12:00:00Z" "$got"
fi

# --- Floor: a check suite predating branch creation cannot anchor this branch (R2) ---
# The bounded gate proves the new-branch case, but the EARLIEST-suite pick (#271's
# `sort | .[0]`, deliberately unchanged) can still select a suite from a PREVIOUS
# lifetime of a deleted-and-recreated branch. A suite created before the branch existed
# definitionally cannot anchor a push to it, so it is discarded. Enforced by ONE shared
# helper so the three consumers cannot drift.
events_create=$(cat "$FIXTURES/events-create-branch-no-push.json")
got=$(head_push_create_date_from_events_json "$events_create" "$BRANCH")
check "CreateEvent date extracted for floor" "2026-08-10T11:00:00Z" "$got"
got=$(head_push_create_date_from_events_json "$events_create" "other/branch")
check "CreateEvent date empty for a different branch" "" "$got"
# Recycled branch: deleted and recreated, so the page holds TWO CreateEvents for it.
# Only the CURRENT lifetime may anchor — taking the earlier one would let a suite from
# the previous lifetime clear the floor, which is the whole R2 hole.
events_recycled='[
  {"type":"CreateEvent","created_at":"2026-08-01T00:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"DeleteEvent","created_at":"2026-08-05T00:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"CreateEvent","created_at":"2026-08-10T11:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}}
]'
got=$(head_push_create_date_from_events_json "$events_recycled" "$BRANCH")
check "recycled branch → floor uses the LATEST CreateEvent (current lifetime)" "2026-08-10T11:00:00Z" "$got"

# The classifier must judge the SAME lifetime the floor does. A push belonging to the
# PREVIOUS lifetime must not veto the current CreateEvent-only case, or a recreated
# branch stays stale until that stale event ages off the bounded page.
events_recycled_push='[
  {"type":"CreateEvent","created_at":"2026-08-01T00:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"PushEvent","created_at":"2026-08-02T00:00:00Z","payload":{"head":"1111111111111111111111111111111111111111","ref":"refs/heads/feat/test-branch"}},
  {"type":"DeleteEvent","created_at":"2026-08-05T00:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"CreateEvent","created_at":"2026-08-10T11:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}}
]'
got=$(head_push_checks_fallback_eligible_from_events_json "$events_recycled_push" "$BRANCH")
check "previous-lifetime PushEvent does not veto current CreateEvent case" "1" "$got"

# ...but a push AFTER the current creation is a real push: fallback denied.
events_created_then_push='[
  {"type":"CreateEvent","created_at":"2026-08-10T11:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"PushEvent","created_at":"2026-08-10T12:00:00Z","payload":{"head":"2222222222222222222222222222222222222222","ref":"refs/heads/feat/test-branch"}}
]'
got=$(head_push_checks_fallback_eligible_from_events_json "$events_created_then_push" "$BRANCH")
check "push AFTER current creation → fallback denied" "0" "$got"

# Event timestamps are second-granularity, so a push can share the creation second.
# A strict `>` would ignore it and authorize the fallback; the comparison must be `>=`.
# (The ref-creating push itself emits NO PushEvent — verified against the live API —
# so `>=` cannot veto the legitimate new-branch case.)
events_same_second='[
  {"type":"CreateEvent","created_at":"2026-08-10T11:00:00Z","payload":{"ref":"feat/test-branch","ref_type":"branch"}},
  {"type":"PushEvent","created_at":"2026-08-10T11:00:00Z","payload":{"head":"3333333333333333333333333333333333333333","ref":"refs/heads/feat/test-branch"}}
]'
got=$(head_push_checks_fallback_eligible_from_events_json "$events_same_second" "$BRANCH")
check "push in the SAME second as creation → fallback denied" "0" "$got"


HEAD_CHECKS_DATE="2026-08-10T09:00:00Z" HEAD_PUSH_CREATE_DATE="2026-08-10T11:00:00Z"
apply_head_checks_floor
check "suite BEFORE branch creation → anchor discarded" "" "$HEAD_CHECKS_DATE"

HEAD_CHECKS_DATE="2026-08-10T11:00:02Z" HEAD_PUSH_CREATE_DATE="2026-08-10T11:00:00Z"
apply_head_checks_floor
check "suite AFTER branch creation → anchor kept" "2026-08-10T11:00:02Z" "$HEAD_CHECKS_DATE"

# Equal timestamps survive: strict `<` only, no tolerance window (observed margin is
# +2s in this repo; a tolerance would also admit genuinely pre-branch suites).
HEAD_CHECKS_DATE="2026-08-10T11:00:00Z" HEAD_PUSH_CREATE_DATE="2026-08-10T11:00:00Z"
apply_head_checks_floor
check "suite EQUAL to branch creation → anchor kept (strict <, zero tolerance)" "2026-08-10T11:00:00Z" "$HEAD_CHECKS_DATE"

# Fork PRs have no CreateEvent in the base feed → no floor date → helper must no-op
# rather than blank a legitimate anchor (would re-create the #271-class fail-close).
# shellcheck disable=SC2034  # both are read by apply_head_checks_floor (sourced)
HEAD_CHECKS_DATE="2026-08-10T09:00:00Z" HEAD_PUSH_CREATE_DATE=""
apply_head_checks_floor
check "no CreateEvent date (fork) → floor is a no-op" "2026-08-10T09:00:00Z" "$HEAD_CHECKS_DATE"
unset HEAD_CHECKS_DATE HEAD_PUSH_CREATE_DATE

# Drift guard: the floor is worthless if any consumer forgets to call it.
missing=""
for f in "$REPO_ROOT/scripts/fetch-pr-state.sh" \
         "$REPO_ROOT/agents/pr-grinder.md" \
         "$REPO_ROOT/skills/pr-grind/references/completion.md"; do
  grep -q 'apply_head_checks_floor' "$f" || missing="$missing $(basename "$f")"
done
check "all three consumers call apply_head_checks_floor" "" "$missing"

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

# --- Cross-repo PR must take NO floor from the base repo's events ---
# The base feed can hold a same-NAMED branch that has nothing to do with the fork's
# branch; using its CreateEvent as a floor would discard the fork's valid anchor and
# stale it permanently — the same #271-class fail-close, re-entered through the floor.
export GH_MOCK_EVENTS_FILE="$FIXTURES/events-create-branch-no-push.json"
unset HEAD_PUSH_DATE HEAD_PUSH_CHECKS_FALLBACK_OK HEAD_PUSH_CREATE_DATE 2>/dev/null || true
resolve_head_push_date_with_fallback_gate owner repo "$FULL_SHA" "$BRANCH" 1
unset GH_MOCK_EVENTS_FILE
check "cross-repo → fallback eligible" "1" "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}"
check "cross-repo → NO floor from base-repo events" "" "${HEAD_PUSH_CREATE_DATE:-}"
unset HEAD_PUSH_DATE HEAD_PUSH_CHECKS_FALLBACK_OK HEAD_PUSH_CREATE_DATE 2>/dev/null || true

# --- fetch-pr-state.sh uses shared resolver (outside-window fixture) ---
export GH_MOCK_EVENTS_FILE="$FIXTURES/events-push-outside-window.json"
unset FETCH_OK HEAD_PUSH_DATE HEAD_COMMITTED_DATE HEAD_PUSH_CHECKS_FALLBACK_OK 2>/dev/null || true
# shellcheck source=/dev/null
. "$FETCH_PR_STATE" 123
unset GH_MOCK_EVENTS_FILE
[[ "$FETCH_OK" = "1" ]] || { echo "FAIL: FETCH_OK not 1 on bounded miss"; fail=$((fail + 1)); }
check "fetch-pr-state bounded miss → empty HEAD_PUSH_DATE" "" "${HEAD_PUSH_DATE:-}"
check "fetch-pr-state bounded miss → no HEAD_CHECKS_DATE fallback" "0" "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}"

echo "───────────────────────────────"
echo "Total: $((pass + fail))  Pass: $pass  Fail: $fail"
[[ "$fail" -eq 0 ]]
