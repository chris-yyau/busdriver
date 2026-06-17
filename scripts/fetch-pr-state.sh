# shellcheck shell=bash
# shellcheck disable=SC2034  # ALL_THREADS/ALL_REVIEWS/ALL_CHECK_RUNS/ALL_STATUSES/ALL_REACTIONS/HEAD_COMMITTED_DATE/HEAD_PUSH_DATE exported to parent via `source`
# scripts/fetch-pr-state.sh — sourced helper; populates parent-shell env vars.
#
# CRITICAL: source this file (`. fetch-pr-state.sh <pr_number>`); do NOT execute
# it (`bash fetch-pr-state.sh`). A child bash cannot export env back to parent.
# See Known Residual #1 of inversion design spec.
#
# Why a function wrapper (vs top-level statements):
#   The caller may invoke under `set -euo pipefail`. Top-level `local` is invalid
#   Bash; only valid inside a function. Function-wrap also gives us a clean
#   early-return path on bad input without aborting the parent shell.
#
# Variables set in parent shell on success:
#   FETCH_OK=1
#   ALL_THREADS, ALL_REVIEWS, ALL_COMMENTS, ALL_CHECK_RUNS, ALL_STATUSES,
#   ALL_REACTIONS                                          (JSON blobs;
#                                                           shapes match
#                                                           scripts/ack-ledger.sh
#                                                           jq selectors)
#   HEAD_SHA             (8-char prefix of HEAD)
#   HEAD_COMMITTED_DATE  (ISO-8601 committer date of HEAD)
#   HEAD_PUSH_DATE       (ISO-8601 push-event timestamp of HEAD; best-effort,
#                         empty when the events API has no matching PushEvent)
#
# Shapes (mirrored from agents/pr-grinder.md Step 6.5 fetch block):
#   ALL_REVIEWS    : output of `gh api --paginate repos/{owner}/{repo}/pulls/{n}/reviews`
#                    (array of {user:{login}, commit_id, ...})
#   ALL_COMMENTS   : output of `gh pr view {n} --comments --json comments`
#                    (object {comments: [{author:{login}, body}, ...]})
#   ALL_CHECK_RUNS : output of `gh api --paginate repos/.../commits/{sha}/check-runs`
#                    (stream of pages, each {check_runs: [{app:{slug}, conclusion, head_sha}, ...]})
#   ALL_STATUSES   : output of `gh api --paginate repos/.../commits/{sha}/statuses`
#                    (stream of pages, each an array of {context, state, created_at, ...});
#                    consumed by Tier E for legacy commit-statuses bots (CodeRabbit
#                    free-tier on private repos)
#   ALL_THREADS    : output of `gh api graphql --paginate` reviewThreads query
#                    (stream of pages, each {data:{...reviewThreads:{nodes:[...]}}};
#                     each thread carries resolvedBy{login}, first comment
#                     author{login}+createdAt, and resolutionComments
#                     (last:10 author{login}+createdAt). ack-ledger.sh Tier A's
#                     Codex resolved-non-outdated ack requires the thread's LAST
#                     comment to be resolver-authored and newer than HEAD_PUSH_DATE,
#                     failing CLOSED when the push date is absent (#186/#187)
#   ALL_REACTIONS  : output of `gh api --paginate repos/.../issues/{n}/reactions`
#                    (stream of pages, each an array of {content, user:{login},
#                     created_at, ...}); consumed by Tier F for Codex's 👍 ack
#
# Fail-CLOSED: any subcommand failure → FETCH_OK=0; remaining vars stay at
# their pre-call values (empty if first invocation).

_fetch_pr_state() {
    local pr_number="${1:-}"
    if [[ -z "$pr_number" ]]; then
        FETCH_OK=0
        # Export immediately so child processes always see FETCH_OK even on
        # early-return paths (Cubic P2: export must not be deferred to
        # success-only path at end of function).
        export FETCH_OK
        return 0
    fi

    FETCH_OK=1

    local nwo owner name
    nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || { FETCH_OK=0; export FETCH_OK; return 0; }
    owner="${nwo%/*}"
    name="${nwo#*/}"

    # Use temporary locals so a gh failure does not clobber the parent-shell
    # exported vars with empty strings (documented contract: "remaining vars
    # stay at their pre-call values" on failure).
    local _tmp

    # shellcheck disable=SC2016  # gh GraphQL needs literal $var refs, not shell expansion
    _tmp=$(gh api graphql --paginate \
        -F number="$pr_number" -F owner="$owner" -F name="$name" \
        -f query='query($number:Int!,$owner:String!,$name:String!,$endCursor:String){
            repository(owner:$owner,name:$name){
              pullRequest(number:$number){
                reviewThreads(first:100,after:$endCursor){
                  nodes{id isResolved isOutdated path line resolvedBy{login}
                        comments(first:1){nodes{author{login} createdAt}}
                        resolutionComments: comments(last:10){nodes{author{login} createdAt}}}
                  pageInfo{hasNextPage endCursor}
                }
              }
            }
          }' 2>/dev/null) && ALL_THREADS="$_tmp" || FETCH_OK=0

    _tmp=$(gh api --paginate "repos/$owner/$name/pulls/$pr_number/reviews" 2>/dev/null) \
        && ALL_REVIEWS="$_tmp" || FETCH_OK=0
    _tmp=$(gh pr view "$pr_number" --comments --json comments 2>/dev/null) \
        && ALL_COMMENTS="$_tmp" || FETCH_OK=0
    # Source 7: issue-level reactions — Codex's clean-review signal is a 👍
    # reaction (ack-ledger.sh Tier F), not a SHA-keyed structured ack.
    # --paginate so the reaction isn't missed behind >30 human PR-body reactions.
    _tmp=$(gh api --paginate "repos/$owner/$name/issues/$pr_number/reactions" 2>/dev/null) \
        && ALL_REACTIONS="$_tmp" || FETCH_OK=0

    # HEAD_SHA pipeline: cut always exits 0, so pipefail cannot catch gh failure
    # here. Capture into a temp var and treat empty output as failure.
    # Capture the FULL head OID: HEAD_SHA is the 8-char prefix used for the
    # commit endpoints, but HEAD_PUSH_DATE matches against PushEvent.payload.head
    # which is a 40-char SHA, so the events lookup needs the untruncated value.
    # Also capture headRefName in the same call for branch-scoped PushEvent lookup
    # (Cubic P2: branch-agnostic payload.head match can pick up the wrong PushEvent
    # if two branches share the same tip SHA; filtering by payload.ref = refs/heads/<branch>
    # eliminates the ambiguity).
    local _full_sha _sha _pr_json _pr_branch
    _pr_json=$(gh pr view "$pr_number" --json headRefOid,headRefName 2>/dev/null) || true
    _full_sha=$(printf '%s' "$_pr_json" | jq -r '.headRefOid // empty' 2>/dev/null) || true
    _pr_branch=$(printf '%s' "$_pr_json" | jq -r '.headRefName // empty' 2>/dev/null) || true
    _sha=$(printf '%s' "$_full_sha" | cut -c1-8)
    if [[ -n "$_sha" ]]; then
        HEAD_SHA="$_sha"
        _tmp=$(gh api --paginate "repos/$owner/$name/commits/$HEAD_SHA/check-runs" 2>/dev/null) \
            && ALL_CHECK_RUNS="$_tmp" || FETCH_OK=0
        _tmp=$(gh api --paginate "repos/$owner/$name/commits/$HEAD_SHA/statuses" 2>/dev/null) \
            && ALL_STATUSES="$_tmp" || FETCH_OK=0
        # Freshness anchors for ack-ledger.sh Tier F (Codex 👍) and the Tier A
        # Codex resolved-non-outdated thread guard. Without HEAD_COMMITTED_DATE the
        # guard's `$anchor == ""` fallthrough would treat any resolved non-outdated
        # Codex thread as a HEAD ack — the exact false-ack case the guard prevents.
        _tmp=$(gh api "repos/$owner/$name/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null) \
            && HEAD_COMMITTED_DATE="$_tmp" || FETCH_OK=0
        # HEAD_PUSH_DATE is best-effort (events API caps at ~300 events / ~90 days);
        # an empty result is a legitimate fallback to HEAD_COMMITTED_DATE and must
        # NOT trip FETCH_OK. --paginate + slurp so a HEAD push on a later events
        # page is still found; match on the full OID since payload.head is 40-char.
        # Branch filter (payload.ref == refs/heads/<branch>) prevents picking up a
        # PushEvent from a different branch that happens to share the same tip SHA.
        local _ref="refs/heads/${_pr_branch:-}"
        HEAD_PUSH_DATE=$(gh api --paginate "repos/$owner/$name/events?per_page=100" 2>/dev/null \
            | jq -rs --arg head "$_full_sha" --arg ref "$_ref" \
                '[.[]? | .[]? | select(.type=="PushEvent" and .payload.head==$head and (if $ref != "refs/heads/" then .payload.ref==$ref else false end))] | sort_by(.created_at) | last | .created_at // empty' \
                2>/dev/null || echo "")
    else
        FETCH_OK=0  # gh pr view --json headRefOid failed or returned empty
    fi

    # Export so child processes (e.g. scripts/ack-ledger.sh run as bash child)
    # can read these without the caller needing a separate export step.
    export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES \
        ALL_REACTIONS HEAD_COMMITTED_DATE HEAD_PUSH_DATE HEAD_SHA

    return 0
}

# Call the function with positional arg passed at source time.
# (The `source FILE arg1 arg2` form makes $1, $2 available inside FILE.)
_fetch_pr_state "${1:-}"
