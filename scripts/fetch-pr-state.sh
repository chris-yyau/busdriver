# shellcheck shell=bash
# shellcheck disable=SC2034  # ALL_THREADS/ALL_REVIEWS/ALL_CHECK_RUNS exported to parent via `source`
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
#   ALL_THREADS, ALL_REVIEWS, ALL_COMMENTS, ALL_CHECK_RUNS  (JSON blobs;
#                                                            shapes match
#                                                            scripts/ack-ledger.sh
#                                                            jq selectors)
#   HEAD_SHA  (8-char prefix of HEAD)
#
# Shapes (mirrored from agents/pr-grinder.md Step 6.5 fetch block):
#   ALL_REVIEWS    : output of `gh api --paginate repos/{owner}/{repo}/pulls/{n}/reviews`
#                    (array of {user:{login}, commit_id, ...})
#   ALL_COMMENTS   : output of `gh pr view {n} --comments --json comments`
#                    (object {comments: [{author:{login}, body}, ...]})
#   ALL_CHECK_RUNS : output of `gh api --paginate repos/.../commits/{sha}/check-runs`
#                    (stream of pages, each {check_runs: [{app:{slug}, conclusion, head_sha}, ...]})
#   ALL_THREADS    : output of `gh api graphql --paginate` reviewThreads query
#                    (stream of pages, each {data:{...reviewThreads:{nodes:[...]}}})
#
# Fail-CLOSED: any subcommand failure → FETCH_OK=0; remaining vars stay at
# their pre-call values (empty if first invocation).

_fetch_pr_state() {
    local pr_number="${1:-}"
    if [[ -z "$pr_number" ]]; then
        FETCH_OK=0
        return 0
    fi

    FETCH_OK=1

    local nwo owner name
    nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || { FETCH_OK=0; return 0; }
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
                  nodes{id isResolved isOutdated path line
                        comments(first:1){nodes{author{login}}}}
                  pageInfo{hasNextPage endCursor}
                }
              }
            }
          }' 2>/dev/null) && ALL_THREADS="$_tmp" || FETCH_OK=0

    _tmp=$(gh api --paginate "repos/$owner/$name/pulls/$pr_number/reviews" 2>/dev/null) \
        && ALL_REVIEWS="$_tmp" || FETCH_OK=0
    _tmp=$(gh pr view "$pr_number" --comments --json comments 2>/dev/null) \
        && ALL_COMMENTS="$_tmp" || FETCH_OK=0

    # HEAD_SHA pipeline: cut always exits 0, so pipefail cannot catch gh failure
    # here. Capture into a temp var and treat empty output as failure.
    local _sha
    _sha=$(gh pr view "$pr_number" --json headRefOid -q '.headRefOid' 2>/dev/null | cut -c1-8) || true
    if [[ -n "$_sha" ]]; then
        HEAD_SHA="$_sha"
        _tmp=$(gh api --paginate "repos/$owner/$name/commits/$HEAD_SHA/check-runs" 2>/dev/null) \
            && ALL_CHECK_RUNS="$_tmp" || FETCH_OK=0
    else
        FETCH_OK=0  # gh pr view --json headRefOid failed or returned empty
    fi

    # Export so child processes (e.g. scripts/ack-ledger.sh run as bash child)
    # can read these without the caller needing a separate export step.
    export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA

    return 0
}

# Call the function with positional arg passed at source time.
# (The `source FILE arg1 arg2` form makes $1, $2 available inside FILE.)
_fetch_pr_state "${1:-}"
