#!/usr/bin/env bash
# test-head-push-date-bounded.sh — #624 bounded HEAD_PUSH_DATE probe regression.
#
# Shared mechanism: scripts/lib/head-push-date.sh (single-page events fetch, no
# --paginate). Missing PushEvent in the bounded window → empty HEAD_PUSH_DATE, and
# the SHA-bound earliest check-suite fallback is then permitted ONLY for a qualifying
# lifetime-scoped branch CreateEvent, or for a cross-repository (fork) PR whose branch
# the base repo's feed can never witness. Never the committer date (#189).
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

# --- Floor must not discard a VALID post-creation suite (#743 Codex P2) ---
# The #271 selector picks the EARLIEST suite for the SHA. If that one predates branch
# creation, blanking the scalar throws away a later, perfectly valid suite and stales a
# legitimate new branch. Filter the whole set against the floor, then take the earliest
# ELIGIBLE one. The #271 jq filter itself stays byte-identical (its test awk-extracts it
# and runs it with only --arg sha), so this is a second, separate expression.
suites_mixed='{"check_suites":[
  {"head_sha":"'"$FULL_SHA"'","created_at":"2026-08-10T09:00:00Z"},
  {"head_sha":"'"$FULL_SHA"'","created_at":"2026-08-10T11:00:05Z"},
  {"head_sha":"'"$FULL_SHA"'","created_at":"2026-08-10T12:00:00Z"},
  {"head_sha":"0000000000000000000000000000000000000009","created_at":"2026-08-10T11:00:01Z"}
]}'
got=$(head_checks_date_after_floor_from_suites_json "$suites_mixed" "$FULL_SHA" "2026-08-10T11:00:00Z")
check "floor retry → earliest suite AT/AFTER branch creation" "2026-08-10T11:00:05Z" "$got"
# Boundary: a suite stamped in the SAME second as branch creation is eligible (`>=`),
# matching apply_head_checks_floor's strict `<` where equal also survives.
suites_at_floor='{"check_suites":[
  {"head_sha":"'"$FULL_SHA"'","created_at":"2026-08-10T11:00:00Z"},
  {"head_sha":"'"$FULL_SHA"'","created_at":"2026-08-10T12:00:00Z"}
]}'
got=$(head_checks_date_after_floor_from_suites_json "$suites_at_floor" "$FULL_SHA" "2026-08-10T11:00:00Z")
check "floor retry → suite exactly AT creation is eligible (>=, not >)" "2026-08-10T11:00:00Z" "$got"
got=$(head_checks_date_after_floor_from_suites_json "$suites_mixed" "$FULL_SHA" "2026-08-10T13:00:00Z")
check "floor retry → empty when every suite predates creation" "" "$got"
got=$(head_checks_date_after_floor_from_suites_json "$suites_mixed" "$FULL_SHA" "")
check "floor retry → empty floor yields empty (caller keeps fail-closed)" "" "$got"

# Drift guard: every consumer must perform the floor retry, not just blank the scalar.
missing=""
for f in "$REPO_ROOT/scripts/fetch-pr-state.sh" \
         "$REPO_ROOT/agents/pr-grinder.md" \
         "$REPO_ROOT/skills/pr-grind/references/completion.md"; do
  grep -q 'head_checks_date_after_floor_from_suites_json' "$f" || missing="$missing $(basename "$f")"
done
check "all three consumers perform the floor retry" "" "$missing"

# --- Fork exemption must not depend on the base-repo events request succeeding ---
# The base feed is irrelevant to a fork PR, so a failed/rate-limited fetch of it must
# not decide the fork's freshness. If the exemption ran only AFTER a successful fetch,
# a transient base-repo API failure would stale every fork PR — the same #271-class
# fail-close the exemption exists to prevent.
_orig_fetch_fn=$(declare -f _fetch_head_push_events_page)
# shellcheck disable=SC2034  # stub mirrors the real helper's output-global contract
_fetch_head_push_events_page() { HEAD_PUSH_EVENTS_JSON=""; return 1; }
unset HEAD_PUSH_DATE HEAD_PUSH_CHECKS_FALLBACK_OK HEAD_PUSH_CREATE_DATE 2>/dev/null || true
resolve_head_push_date_with_fallback_gate owner repo "$FULL_SHA" "$BRANCH" 1
check "cross-repo + FAILED events fetch → fallback still eligible" "1" "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}"
check "cross-repo + FAILED events fetch → still no floor" "" "${HEAD_PUSH_CREATE_DATE:-}"
unset HEAD_PUSH_DATE HEAD_PUSH_CHECKS_FALLBACK_OK HEAD_PUSH_CREATE_DATE 2>/dev/null || true
resolve_head_push_date_with_fallback_gate owner repo "$FULL_SHA" "$BRANCH" 0
check "same-repo + FAILED events fetch → fail-CLOSED" "0" "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}"
eval "$_orig_fetch_fn"
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

# --- Mock hardening (#748 / ADR 0047): activity arm first + positive argv ---
# A branch literally named `events` must hit the activity arm (argv contract) and
# must NOT create the events sentinel — proving path-token matching, not substring.
_mock_sent=$(mktemp -d)
export PATH="$GH_MOCK:$PATH"
export GH_MOCK_ACTIVITY_SENTINEL="$_mock_sent/activity"
export GH_MOCK_EVENTS_SENTINEL="$_mock_sent/events"
rm -f "$GH_MOCK_ACTIVITY_SENTINEL" "$GH_MOCK_EVENTS_SENTINEL"
_act_out=$(gh api "repos/owner/repo/activity" -X GET \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/events -f per_page=2 -f direction=desc 2>/dev/null) || _act_out="ERR"
check "activity arm + branch named events → empty array (route-on default)" "[]" "$_act_out"
if [[ -f "$GH_MOCK_ACTIVITY_SENTINEL" ]]; then
  check "activity unset-file records invocation sentinel" "1" "1"
else
  check "activity unset-file records invocation sentinel" "1" "0"
fi
if [[ ! -e "$GH_MOCK_EVENTS_SENTINEL" ]]; then
  check "activity call does not create events sentinel" "1" "1"
else
  check "activity call does not create events sentinel" "1" "0"
fi
# Positive argv: omitting per_page=2 must fail (negatives alone are insufficient).
if ! gh api "repos/owner/repo/activity" -X GET \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/events -f direction=desc >/dev/null 2>&1; then
  check "activity argv rejects missing per_page=2" "1" "1"
else
  check "activity argv rejects missing per_page=2" "1" "0"
fi
# Endpoint-token matching: an /events fetch for branch `activity` must NOT be
# classified as the activity arm (flattened-$* false positive).
_ev_out=$(gh api "repos/owner/repo/events?per_page=100" 2>/dev/null) || _ev_out="ERR"
check "events fetch for any branch stays on events arm" "[]" "$_ev_out"
# Substring-in-joined-args is not enough: a bogus -H value must not satisfy the
# API-version positive check.
if ! gh api "repos/owner/repo/activity" -X GET \
  -H 'Bogus: X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/events -f per_page=2 -f direction=desc >/dev/null 2>&1; then
  check "activity argv rejects forged API-version header value" "1" "1"
else
  check "activity argv rejects forged API-version header value" "1" "0"
fi
# Flag ordering: `-X GET` before the path must still hit the activity arm.
_act_ord=$(gh api -X GET "repos/owner/repo/activity" \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/feat/x -f per_page=2 -f direction=desc 2>/dev/null) || _act_ord="ERR"
check "activity arm tolerates -X GET before path" "[]" "$_act_ord"
# Equals-form pagination must be rejected on both legs.
if ! gh api "repos/owner/repo/activity" -X GET --paginate=true \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/feat/x -f per_page=2 -f direction=desc >/dev/null 2>&1; then
  check "activity argv rejects --paginate=true" "1" "1"
else
  check "activity argv rejects --paginate=true" "1" "0"
fi
if ! gh api --paginate=true "repos/owner/repo/events?per_page=100" >/dev/null 2>&1; then
  check "events argv rejects --paginate=true" "1" "1"
else
  check "events argv rejects --paginate=true" "1" "0"
fi
# Without the `api` subcommand, real `gh` rejects the invocation — the mock must
# not route a bare activity path (Codex P2 on #764).
_no_api=$(gh "repos/owner/repo/activity" -X GET \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/feat/x -f per_page=2 -f direction=desc 2>/dev/null) || _no_api="ERR"
check "activity path without api subcommand is not routed" "{}" "$_no_api"
# A trailing `api` token must not unlock the activity arm either.
_trail_api=$(gh "repos/owner/repo/activity" -X GET \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -f ref=refs/heads/feat/x -f per_page=2 -f direction=desc api 2>/dev/null) || _trail_api="ERR"
check "trailing api token does not unlock activity arm" "{}" "$_trail_api"
# Quoted branch names must not break the parameterized PR JSON.
_pr_json=$(GH_MOCK_HEAD_REF_NAME='feat/"quoted"' GH_MOCK_IS_CROSS_REPOSITORY=true \
  gh pr view 1 --json headRefOid,headRefName,isCrossRepository 2>/dev/null) || _pr_json=""
_pr_branch=$(printf '%s' "$_pr_json" | jq -r '.headRefName // empty')
_pr_cross=$(printf '%s' "$_pr_json" | jq -r 'if .isCrossRepository == true then "1" else "0" end')
check "PR JSON survives quoted branch name" 'feat/"quoted"' "$_pr_branch"
check "PR JSON coerces isCrossRepository=true" "1" "$_pr_cross"
unset GH_MOCK_ACTIVITY_SENTINEL GH_MOCK_EVENTS_SENTINEL
rm -rf "$_mock_sent"

# --- Cross-repo fetch-pr-state e2e (ADR 0047 Testing §8) — lands first ---
# Must supply a non-empty check-suites fixture: the mock defaults to
# {"check_suites":[]} which would leave HEAD_CHECKS_DATE empty for the wrong reason.
export GH_MOCK_IS_CROSS_REPOSITORY=true
export GH_MOCK_CHECK_SUITES_FILE="$FIXTURES/check-suites-for-head.json"
export GH_MOCK_EVENTS_FILE="$FIXTURES/events-push-outside-window.json"
unset FETCH_OK HEAD_PUSH_DATE HEAD_CHECKS_DATE HEAD_COMMITTED_DATE \
  HEAD_PUSH_CHECKS_FALLBACK_OK HEAD_PUSH_CREATE_DATE 2>/dev/null || true
# shellcheck source=/dev/null
. "$FETCH_PR_STATE" 123
unset GH_MOCK_IS_CROSS_REPOSITORY GH_MOCK_CHECK_SUITES_FILE GH_MOCK_EVENTS_FILE
[[ "$FETCH_OK" = "1" ]] || { echo "FAIL: FETCH_OK not 1 on cross-repo e2e"; fail=$((fail + 1)); }
check "cross-repo e2e → fallback eligible" "1" "${HEAD_PUSH_CHECKS_FALLBACK_OK:-0}"
check "cross-repo e2e → HEAD_CHECKS_DATE from suites fixture" "2026-08-10T11:00:05Z" "${HEAD_CHECKS_DATE:-}"
check "cross-repo e2e → no CreateEvent floor from base feed" "" "${HEAD_PUSH_CREATE_DATE:-}"

echo "───────────────────────────────"
echo "Total: $((pass + fail))  Pass: $pass  Fail: $fail"
[[ "$fail" -eq 0 ]]
