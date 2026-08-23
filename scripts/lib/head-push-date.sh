# shellcheck shell=bash
# scripts/lib/head-push-date.sh — bounded HEAD_PUSH_DATE resolution (#624).
#
# CRITICAL: source this file (`. head-push-date.sh`); do NOT execute it — a child
# bash cannot export results back to the parent.
#
# HEAD_PUSH_DATE is the SOLE Tier-F +1 freshness anchor (#189). This library fetches
# ONE page of repo events (per_page=100, NO --paginate). If the PushEvent for HEAD
# is not in that window, resolve_head_push_date returns empty — fail-closed. Callers
# then fall back to HEAD_CHECKS_DATE (#269); never the committer date (#186/#189).
#
# Keep in sync: scripts/fetch-pr-state.sh, agents/pr-grinder.md Step 6.5,
# skills/pr-grind/references/completion.md COMPLETION re-query.

# Single-page bound (#624). Do NOT add --paginate without revisiting fail-closed bounds.
HEAD_PUSH_DATE_EVENTS_PER_PAGE=100

# Jq filter for a SINGLE-PAGE events array (GitHub returns `[event, ...]`).
# shellcheck disable=SC2016  # jq filter literal, not shell expansion
HEAD_PUSH_DATE_JQ_FILTER='[.[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty'

# $1 = events JSON (single-page array), $2 = full 40-char OID, $3 = branch name
head_push_date_from_events_json() {
  local events_json="$1" full_sha="$2" branch="${3:-}"
  local ref="refs/heads/${branch}"
  printf '%s' "$events_json" | jq -r --arg head "$full_sha" --arg ref "$ref" \
    "$HEAD_PUSH_DATE_JQ_FILTER" 2>/dev/null || echo ""
}

# $1 = owner, $2 = repo, $3 = full 40-char OID, $4 = branch name
resolve_head_push_date() {
  local owner="$1" repo="$2" full_sha="$3" branch="${4:-}"
  local events_json
  events_json=$(gh api "repos/$owner/$repo/events?per_page=${HEAD_PUSH_DATE_EVENTS_PER_PAGE}" 2>/dev/null) || {
    echo ""
    return 0
  }
  head_push_date_from_events_json "$events_json" "$full_sha" "$branch"
}
