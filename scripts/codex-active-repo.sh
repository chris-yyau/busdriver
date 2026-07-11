#!/usr/bin/env bash
# scripts/codex-active-repo.sh — is Codex (chatgpt-codex-connector) an ACTIVE
# reviewer on this repo? Auto-detect signal for the pr-grind `none`-nudge
# (ADR 0013 revision, issue #320).
#
# WHY: ADR 0013 gated the `none`-nudge behind a manual per-repo opt-in file that
# was trivial to never set (silent no-op). This replaces the file as the DEFAULT
# trigger with proven history: a repo where Codex reviewed/reacted on recent PRs
# is a repo where a silent `none` is a real gap worth nudging. The opt-in file
# remains only as a force-ON cold-start override.
#
# ONE bounded GraphQL call over the last N recently-updated CLOSED-or-MERGED PRs.
# ACTIVE iff Codex authored any review OR left any reaction (a CLEAN Codex leaves
# only a Tier-F 👍 reaction and posts NO review — ADR 0002 / ack-ledger.sh:291 —
# so reviews-only detection would miss exactly the healthy repos; we scan both).
# Login is matched bare OR `[bot]`-suffixed, mirroring ack-ledger.sh:292,312-314
# (the GitHub API returns either form).
#
# CONTRACT — fail-SAFE to INACTIVE: exit 1 on any gh/jq/query failure or bad
# input, printing a stderr diagnostic so a transient outage is distinguishable
# from a genuinely-idle repo (the caller keeps merge non-gating either way).
#   Usage:  codex-active-repo.sh <owner/repo>
#   exit 0 = active ; exit 1 = inactive / unknown.
#
# Env:
#   PR_GRIND_CODEX_ACTIVE_WINDOW  PRs scanned (default 10; empty/non-numeric/<1
#                                 → 10; clamped to GraphQL's 1..100 `first:` bound)
#   PR_GRIND_CODEX_RETRIGGER=0    global kill switch — short-circuits to inactive
#                                 with NO network call (a disabled repo must not
#                                 pay a GraphQL round-trip).
set -u

REPO="${1:-}"

# Kill switch FIRST — before any network call.
if [ "${PR_GRIND_CODEX_RETRIGGER:-1}" = "0" ]; then
    echo "ℹ️  codex-active-repo: PR_GRIND_CODEX_RETRIGGER=0; treating repo as inactive (no query)." >&2
    exit 1
fi

# Validate owner/repo: exactly owner/name, GitHub's conservative charset. Reject
# anything else before it reaches gh (argument-injection guard).
case "$REPO" in
    */*/* | /* | */ ) REPO="" ;;
esac
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
if [ -z "$OWNER" ] || [ -z "$NAME" ] || [ "$OWNER" = "$REPO" ] \
   || printf '%s' "$OWNER$NAME" | LC_ALL=C grep -q '[^A-Za-z0-9._-]'; then
    echo "ℹ️  codex-active-repo: detection unavailable (bad owner/repo '$REPO'); treating repo as inactive." >&2
    exit 1
fi

command -v gh >/dev/null 2>&1 || {
    echo "ℹ️  codex-active-repo: detection unavailable (gh not found); treating repo as inactive." >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "ℹ️  codex-active-repo: detection unavailable (jq not found); treating repo as inactive." >&2
    exit 1
}

# Window: default 10; empty/non-numeric/<1 → 10; clamp to GraphQL's 1..100 bound
# (an out-of-range `first:` errors the query, which the fail-safe would then
# misread as inactive).
N="${PR_GRIND_CODEX_ACTIVE_WINDOW:-10}"
case "$N" in '' | *[!0-9]*) N=10 ;; esac
N=$((10#$N))                 # canonicalize (strip leading zeros; no octal) → clean JSON int
[ "$N" -lt 1 ] && N=10
[ "$N" -gt 100 ] && N=100

# ponytail: single-call ceiling — first:100 reviews + first:100 reactions per PR (the
# GraphQL single-page max). Full --paginate is overkill for an ACTIVITY heuristic: Codex
# only needs to appear in ONE of the N recent PRs to count active, and it reviews/reacts
# early, so a miss needs >100 others ahead of it on EVERY scanned PR. Upgrade to paginate
# only if a real active repo is ever misclassified inactive despite this.
# shellcheck disable=SC2016  # $owner/$name/$n are GraphQL variables, not shell vars.
RESP=$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$n:Int!){
      repository(owner:$owner,name:$name){
        pullRequests(first:$n, states:[CLOSED,MERGED], orderBy:{field:UPDATED_AT,direction:DESC}){
          nodes {
            reviews(first:100){ nodes { author { login } } }
            reactions(first:100){ nodes { user { login } } }
          }
        }
      }
    }' -f owner="$OWNER" -f name="$NAME" -F n="$N" 2>/dev/null) || {
    echo "ℹ️  codex-active-repo: detection unavailable (GraphQL query failed); treating repo as inactive." >&2
    exit 1
}

# ACTIVE iff Codex (bare OR [bot]-suffixed login) authored any review or left any
# reaction across the scanned PRs.
# STRICT structural guard, then count. Map ANY shape anomaly in a partial/errored
# response (that gh still exited 0 on) to "ERR" → diagnostic, so nothing is silently
# discarded as "genuine inactivity":
#   - top-level pullRequests.nodes must be an array, AND
#   - every PR node's reviews.nodes and reactions.nodes must be arrays
#     (GitHub returns non-null connections — [] for empty — so this never false-trips
#     on a real response; a null there means the payload is broken).
# A valid, fully-typed response counts normally: 0 matches is a real inactive result
# and stays silent (no diagnostic).
HIT=$(printf '%s' "$RESP" | jq -r \
    --arg l "chatgpt-codex-connector" --arg lb "chatgpt-codex-connector[bot]" '
    (.data.repository.pullRequests.nodes) as $n
    | if (has("errors") and .errors != null and .errors != []) then "ERR"   # ONLY absent/null/[] are clean; any other errors value (array, object, bool, …) → unavailable
      elif ($n | type) != "array" then "ERR"
      elif any($n[]; (.reviews.nodes | type) != "array" or (.reactions.nodes | type) != "array") then "ERR"
      else [ $n[] | ( .reviews.nodes[].author.login, .reactions.nodes[].user.login )
             | select(. == $l or . == $lb) ] | length
      end' 2>/dev/null) || HIT="ERR"

case "$HIT" in
    '' | ERR | *[!0-9]*)
        echo "ℹ️  codex-active-repo: detection unavailable (unparseable/partial GraphQL response); treating repo as inactive." >&2
        exit 1 ;;
esac

[ "$HIT" -gt 0 ] && exit 0   # active
exit 1                       # valid response, no Codex review/reaction → genuine inactive
