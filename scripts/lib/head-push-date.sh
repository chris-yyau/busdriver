# shellcheck shell=bash
# scripts/lib/head-push-date.sh — bounded HEAD_PUSH_DATE resolution (#624).
#
# CRITICAL: source this file (`. head-push-date.sh`); do NOT execute it — a child
# bash cannot export results back to the parent.
#
# HEAD_PUSH_DATE is the SOLE Tier-F +1 freshness anchor (#189). This library fetches
# ONE page of repo events (per_page=100, NO --paginate). If the PushEvent for HEAD
# is not in that window, resolve_head_push_date returns empty — fail-closed.
# HEAD_CHECKS_DATE (#269) is permitted ONLY when the bounded page shows a
# lifetime-scoped new-branch CreateEvent for this ref. A bounded miss (truncated
# event window) must NOT use the check-suite fallback — the suite timestamp can
# predate the PR-head push (#624 Codex P1). Truncation cannot forge that evidence:
# the feed is ordered newest-first, so a CreateEvent old enough to have aged off the
# page takes every later PushEvent for its ref with it.
#
# KNOWN RESIDUAL — read before trusting this gate. It bounds the anchor by BRANCH
# CREATION, not by the current push, and it cannot distinguish "no PushEvent exists"
# from "the PushEvent has not propagated yet": the events API is delivery-lagged
# (GitHub documents 30s-6h). So for a branch whose page still shows only its
# CreateEvent, a suite stamped between branch creation and a just-landed push can
# still anchor an ack posted before that push. Closing it needs a push-anchored
# signal this API pair does not provide — NOT a wider event page, and NOT a time
# heuristic. Do not describe this gate as proving the current HEAD was the
# branch-creating push; it does not.
#
# Keep in sync: scripts/fetch-pr-state.sh, agents/pr-grinder.md Step 6.5,
# skills/pr-grind/references/completion.md COMPLETION re-query.

# Single-page bound (#624). Do NOT add --paginate without revisiting fail-closed bounds.
HEAD_PUSH_DATE_EVENTS_PER_PAGE=100

# Jq filter for a SINGLE-PAGE events array (GitHub returns `[event, ...]`).
# shellcheck disable=SC2016  # jq filter literal, not shell expansion
HEAD_PUSH_DATE_JQ_FILTER='[.[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty'

# True when the bounded page shows this branch was created (CreateEvent) and no
# PushEvent for this ref appears AFTER that creation — the new-branch / CreateEvent
# case, where no PushEvent will ever exist for HEAD.
#
# `>=`, not `>`: event timestamps are second-granularity, so a push can share the
# creation second and must still count as a real push. The ref-creating push emits no
# PushEvent of its own (verified against the live API), so this cannot veto the
# legitimate new-branch case.
#
# LIFETIME-SCOPED: both legs key off the LATEST CreateEvent for the ref, so a branch
# that was deleted and recreated is judged on its CURRENT lifetime only. Counting a
# PushEvent from a previous lifetime would leave a genuinely-new branch ineligible
# until that stale event aged off the page. The floor below uses the same latest
# CreateEvent, so the two clauses agree on which lifetime is in scope.
#
# ASYMMETRIC BY DESIGN — do not "unify" the two legs onto one variable:
# CreateEvent.payload.ref is the BARE branch name ($branch) and needs
# ref_type=="branch" (a tag CreateEvent carries the same ref shape and must NOT
# authorize the fallback); PushEvent.payload.ref is the FULL ref ($ref).
# shellcheck disable=SC2016  # jq filter literal, not shell expansion
HEAD_PUSH_CREATE_EVENT_JQ_FILTER='([.[]? | select(.type=="CreateEvent" and .payload.ref_type=="branch" and .payload.ref==$branch)] | sort_by(.created_at) | last) as $ce | ($ce != null) and ([.[]? | select(.type=="PushEvent" and .payload.ref==$ref and .created_at >= $ce.created_at)] | length == 0)'

# Latest CreateEvent created_at for this branch — the floor for HEAD_CHECKS_DATE.
# LATEST (not earliest) on purpose: if the branch was deleted and recreated, only the
# CURRENT lifetime may anchor it, which is what discards a previous-lifetime suite.
# shellcheck disable=SC2016  # jq filter literal, not shell expansion
HEAD_PUSH_CREATE_DATE_JQ_FILTER='[.[]? | select(.type=="CreateEvent" and .payload.ref_type=="branch" and .payload.ref==$branch)] | sort_by(.created_at) | last | .created_at // empty'

# $1 = events JSON (single-page array), $2 = branch name
head_push_create_date_from_events_json() {
  local events_json="$1" branch="${2:-}"
  [[ -z "$branch" ]] && { echo ""; return 0; }
  printf '%s' "$events_json" | jq -r --arg branch "$branch" \
    "$HEAD_PUSH_CREATE_DATE_JQ_FILTER" 2>/dev/null || echo ""
}

# Earliest check suite for $sha created AT or AFTER the branch-creation floor.
# Companion to apply_head_checks_floor: that one can only BLANK the already-selected
# scalar, which throws away a valid later suite and stales a legitimate new branch
# (#743 Codex P2). This re-selects from the full set instead.
#
# This is a SEPARATE expression from the #271 selector on purpose — that one must stay
# byte-identical because tests/test-check-suite-anchor-271.sh awk-extracts it and runs
# it with only `--arg sha`. Like #271 it does NOT filter on head_branch.
# Empty floor ⇒ empty result: the caller stays fail-closed rather than silently
# reverting to an unfloored pick.
# shellcheck disable=SC2016  # jq filter literal, not shell expansion
HEAD_CHECKS_AFTER_FLOOR_JQ_FILTER='[.[].check_suites[]? | select(.head_sha==$sha) | .created_at] | map(select(. != null and . != "" and . >= $floor)) | sort | .[0] // empty'

# $1 = check-suites JSON, $2 = full 40-char OID, $3 = floor (branch CreateEvent date)
head_checks_date_after_floor_from_suites_json() {
  local suites_json="$1" full_sha="$2" floor="${3:-}"
  [[ -z "$floor" ]] && { echo ""; return 0; }
  printf '%s' "$suites_json" | jq -rs --arg sha "$full_sha" --arg floor "$floor" \
    "$HEAD_CHECKS_AFTER_FLOOR_JQ_FILTER" 2>/dev/null || echo ""
}

# Discard a check-suite anchor that predates this branch's creation (#624 R2).
# The #271 check-suite jq filter is SHA-bound only and picks the EARLIEST suite, so a
# deleted-and-recreated branch can select a suite from its previous lifetime — older
# than the ref itself, hence older than any ack for the current HEAD. A suite created
# before the branch existed cannot anchor a push to that branch, so it is dropped.
#
# Deliberately a SHELL post-check, never a jq arg: tests/test-check-suite-anchor-271.sh
# awk-extracts that filter verbatim and runs it with ONLY --arg sha, so any added jq
# variable breaks it with a compile error. Both values are same-format Zulu ISO8601 from
# the same API, so a lexicographic compare is a valid time compare. Strict `<` — equal
# survives, and there is NO tolerance window: any slack would also admit genuinely
# pre-branch suites, and the observed margin here is +2s (suite AFTER CreateEvent).
# No-ops when either value is empty — notably fork PRs, which have no CreateEvent in the
# base feed and must NOT be blanked (that is the #271-class fail-close this avoids).
apply_head_checks_floor() {
  [[ -n "${HEAD_CHECKS_DATE:-}" && -n "${HEAD_PUSH_CREATE_DATE:-}" ]] || return 0
  if [[ "$HEAD_CHECKS_DATE" < "$HEAD_PUSH_CREATE_DATE" ]]; then
    HEAD_CHECKS_DATE=""
  fi
}

# $1 = events JSON (single-page array), $2 = full 40-char OID, $3 = branch name
head_push_date_from_events_json() {
  local events_json="$1" full_sha="$2" branch="${3:-}"
  local ref="refs/heads/${branch}"
  printf '%s' "$events_json" | jq -r --arg head "$full_sha" --arg ref "$ref" \
    "$HEAD_PUSH_DATE_JQ_FILTER" 2>/dev/null || echo ""
}

# $1 = events JSON (single-page array), $2 = branch name, $3 = 1 when the PR is
# cross-repository (fork). Emits 1 when check-suite fallback is eligible, 0 otherwise.
#
# CROSS-REPO (fork) PRs are NOT APPLICABLE to this gate. The events feed we query is
# the BASE repo's (owner/name come from `gh repo view`), and it can never contain a
# CreateEvent or PushEvent for a branch that lives in the fork — so both clauses below
# are vacuously unsatisfiable. Denying the fallback there would make EVERY fork PR
# permanently stale: a #271-class fail-CLOSED regression strictly wider than the
# bounded-miss hole this gate closes (#271 fail-opened the head_branch filter for
# exactly this population). We therefore preserve the pre-#624 #269/#271 behaviour for
# forks. This is a scoped, deliberate residual, NOT a general fail-open: same-repo PRs
# — every PR this repo actually receives — keep the strict CreateEvent proof below.
head_push_checks_fallback_eligible_from_events_json() {
  local events_json="$1" branch="${2:-}" cross_repo="${3:-0}"
  local ref="refs/heads/${branch}"
  if [[ -z "$branch" ]]; then
    echo "0"
    return 0
  fi
  if [[ "$cross_repo" == "1" ]]; then
    echo "1"
    return 0
  fi
  if printf '%s' "$events_json" | jq -e --arg ref "$ref" --arg branch "$branch" \
    "$HEAD_PUSH_CREATE_EVENT_JQ_FILTER" >/dev/null 2>&1; then
    echo "1"
  else
    echo "0"
  fi
}

# Fetch one bounded events page. Sets HEAD_PUSH_EVENTS_JSON on success.
_fetch_head_push_events_page() {
  local owner="$1" repo="$2"
  HEAD_PUSH_EVENTS_JSON=$(gh api "repos/$owner/$repo/events?per_page=${HEAD_PUSH_DATE_EVENTS_PER_PAGE}" 2>/dev/null) || {
    HEAD_PUSH_EVENTS_JSON=""
    return 1
  }
  return 0
}

# $1 = owner, $2 = repo, $3 = full 40-char OID, $4 = branch name
resolve_head_push_date() {
  local owner="$1" repo="$2" full_sha="$3" branch="${4:-}"
  local events_json
  if ! _fetch_head_push_events_page "$owner" "$repo"; then
    echo ""
    return 0
  fi
  events_json="$HEAD_PUSH_EVENTS_JSON"
  head_push_date_from_events_json "$events_json" "$full_sha" "$branch"
}

# $1 = owner, $2 = repo, $3 = full 40-char OID, $4 = branch name,
# $5 = 1 when the PR is cross-repository (fork) — see the eligibility helper above.
# Sets HEAD_PUSH_DATE and HEAD_PUSH_CHECKS_FALLBACK_OK (0|1) for callers.
# shellcheck disable=SC2034  # both globals are set for the caller via the source/export contract
resolve_head_push_date_with_fallback_gate() {
  local owner="$1" repo="$2" full_sha="$3" branch="${4:-}" cross_repo="${5:-0}"
  local events_json push_date
  HEAD_PUSH_DATE=""
  HEAD_PUSH_CHECKS_FALLBACK_OK=0
  HEAD_PUSH_CREATE_DATE=""
  # Cross-repo (fork) PRs short-circuit BEFORE the fetch: these are the BASE repo's
  # events, which can never witness a branch living in the fork, so nothing in that
  # response can inform this decision. Ordering it after the fetch would let a
  # transient base-repo failure or rate-limit stale every fork PR — reinstating the
  # #271-class fail-close the exemption exists to prevent. No floor either (see below).
  if [[ "$cross_repo" == "1" ]]; then
    HEAD_PUSH_CHECKS_FALLBACK_OK=1
    return 0
  fi
  if ! _fetch_head_push_events_page "$owner" "$repo"; then
    return 0
  fi
  events_json="$HEAD_PUSH_EVENTS_JSON"
  push_date=$(head_push_date_from_events_json "$events_json" "$full_sha" "$branch")
  if [[ -n "$push_date" ]]; then
    HEAD_PUSH_DATE="$push_date"
    return 0
  fi
  local eligible
  eligible=$(head_push_checks_fallback_eligible_from_events_json "$events_json" "$branch" "$cross_repo")
  if [[ "$eligible" == "1" ]]; then
    HEAD_PUSH_CHECKS_FALLBACK_OK=1
    HEAD_PUSH_CREATE_DATE=$(head_push_create_date_from_events_json "$events_json" "$branch")
  fi
  return 0
}
