#!/usr/bin/env bash
# scripts/pr-head-identity.sh — derive the PR's home repository tuple from GitHub's
# PR object for pr-grind Step 0 (#890). The dispatcher binds its push destination to
# this tuple, so it must come from GitHub, never from origin config.
#
#   Usage:  gh pr view <N> --json ...,url,headRepositoryOwner,headRepository \
#             | pr-head-identity.sh --pr-number <N> [--invocation-url <URL>]
#
#   stdout (exit 0): exactly three lines, lowercase
#     PR_HEAD_HOST=<host>
#     PR_HEAD_OWNER=<owner>
#     PR_HEAD_NAME=<name>
#   failure (exit 1): one `pr-head-identity: <reason>` line on stderr, no stdout.
#
# The fork check is `jq -e '.isCrossRepository == false'`: only the JSON boolean
# false passes. Never `// empty` / `// false` — jq's `//` treats false as absent
# (see skills/pr-grind/SKILL.md, the Step 0 fork-refuse caveat).
#
# bash-3.2-safe. Tests feed fixture JSON on stdin; this script never calls gh.

set -uo pipefail

fail() {
    printf 'pr-head-identity: %s\n' "$1" >&2
    exit 1
}

# shellcheck source=/dev/null
if ! . "$(dirname "${BASH_SOURCE[0]}")/lib/push-dest-id.sh" 2>/dev/null \
    || ! declare -F _bd890_pr_identity_valid >/dev/null; then
    fail "cannot source push-dest-id.sh"
fi

pr_number="" invocation_url="" have_invocation=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --pr-number) [ "$#" -ge 2 ] || fail "--pr-number needs a value"; pr_number=$2; shift 2 ;;
        --invocation-url) [ "$#" -ge 2 ] || fail "--invocation-url needs a value"
                          invocation_url=$2; have_invocation=1; shift 2 ;;
        *) fail "unknown argument" ;;
    esac
done
case $pr_number in ''|*[!0123456789]*|0*) fail "--pr-number must match ^[1-9][0-9]*\$" ;; esac

# Parses https://HOST[:443]/OWNER/REPO/pull/N[/] into _u_host/_u_owner/_u_repo/_u_num.
# $2 = 1 for the strict invocation shape: no port at all.
parse_pr_url() {
    local url=$1 strict=$2 rest auth path
    _u_host="" _u_owner="" _u_repo="" _u_num=""
    case $url in https://*) ;; *) return 1 ;; esac
    case $url in *'?'*|*'#'*|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;; esac
    rest=${url#https://}
    auth=${rest%%/*}
    [ "$auth" != "$rest" ] || return 1
    path=${rest#*/}
    case $auth in
        *:*) [ "$strict" -eq 0 ] && [ "${auth#*:}" = 443 ] || return 1
             auth=${auth%%:*} ;;
    esac
    path=${path%/}
    _u_owner=${path%%/*}; path=${path#*/}
    _u_repo=${path%%/*};  path=${path#*/}
    case $path in pull/*) path=${path#pull/} ;; *) return 1 ;; esac
    case $path in ''|*/*|*[!0123456789]*|0*) return 1 ;; esac
    case $_u_repo in *.git) return 1 ;; esac
    _u_host=$auth
    _u_num=$path
    _bd890_pr_identity_valid "$_u_host" "$_u_owner" "$_u_repo"
}

meta=$(cat) || fail "cannot read PR metadata on stdin"
printf '%s' "$meta" | jq -e 'type == "object"' >/dev/null 2>&1 || fail "PR metadata is not a JSON object"

printf '%s' "$meta" | jq -e '.isCrossRepository == false' >/dev/null 2>&1 \
    || fail "isCrossRepository is not the JSON boolean false (fork or malformed)"

pr_url=$(printf '%s' "$meta" | jq -er '.url | strings') || fail "missing .url"
parse_pr_url "$pr_url" 0 || fail "malformed .url"
[ "$_u_num" = "$pr_number" ] || fail ".url PR number does not match --pr-number"
host=$(_bd890_lc "$_u_host") owner=$(_bd890_lc "$_u_owner") name=$(_bd890_lc "$_u_repo")

json_owner=$(printf '%s' "$meta" | jq -er '.headRepositoryOwner.login | strings') \
    || fail "missing .headRepositoryOwner.login"
json_name=$(printf '%s' "$meta" | jq -er '.headRepository.name | strings') \
    || fail "missing .headRepository.name"
[ "$(_bd890_lc "$json_owner")" = "$owner" ] || fail "head repository owner does not match .url"
[ "$(_bd890_lc "$json_name")" = "$name" ] || fail "head repository name does not match .url"

if [ "$have_invocation" -eq 1 ]; then
    parse_pr_url "$invocation_url" 1 || fail "malformed invocation URL"
    if ! { [ "$(_bd890_lc "$_u_host")" = "$host" ] && [ "$(_bd890_lc "$_u_owner")" = "$owner" ] \
        && [ "$(_bd890_lc "$_u_repo")" = "$name" ] && [ "$_u_num" = "$pr_number" ]; }; then
        fail "invocation URL does not match the PR"
    fi
fi

printf 'PR_HEAD_HOST=%s\nPR_HEAD_OWNER=%s\nPR_HEAD_NAME=%s\n' "$host" "$owner" "$name"
