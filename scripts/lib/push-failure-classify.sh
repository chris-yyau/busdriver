#!/usr/bin/env bash
# scripts/lib/push-failure-classify.sh — classify git-push stderr for dispatcher Step 11 (#890).
# Sourced by dispatcher-commit-block.sh and unit tests. Do not execute directly.
#
# Sets (caller-visible):
#   PUSH_DIAG          — bounded diagnostic string for the bail reason
#   PUSH_BAIL_CATEGORY — env | judgment
#   PUSH_BAIL_PREFIX   — short reason prefix (without trailing diagnostic)

push_failure_build_diag() {
    local push_output="$1"
    local push_status push_remote push_tail
    # Failure-tolerant: under set -euo pipefail, zero-match grep exits 1 and
    # multi-match|head can SIGPIPE.
    push_status=$(printf '%s\n' "$push_output" \
        | grep -E '\[rejected\]|\[remote rejected\]|^fatal:' | head -n 1) || true
    push_remote=$(printf '%s\n' "$push_output" \
        | grep -E '^remote:' | tail -n 2) || true
    push_tail=$(printf '%s\n' "$push_output" \
        | grep -v '^hint:' | tail -n 3) || true
    if [[ -n "$push_status" && -n "$push_remote" ]]; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_DIAG=$(printf '%s\n%s' "$push_remote" "$push_status")
    elif [[ -n "$push_status" ]]; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_DIAG=$push_status
    elif [[ -n "$push_remote" ]]; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_DIAG=$(printf '%s\n%s' "$push_remote" "$push_tail")
    else
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_DIAG=$push_tail
    fi
}

push_failure_classify() {
    local push_output="$1"
    push_failure_build_diag "$push_output"

    # Drain-safe grep (>/dev/null, not -q). Order: history → phrase-level
    # auth/transport → remote-rejected/hook → default. No bare network|timeout.
    if printf '%s\n' "$push_output" | grep -E '\(non-fast-forward\)|\(fetch first\)' >/dev/null; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_CATEGORY="judgment"
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_PREFIX="git push non-fast-forward; local commit preserved"
    elif printf '%s\n' "$push_output" | grep -iE \
        'Authentication failed|could not resolve|Could not read from remote|does not appear to be a git repository|no upstream branch|Permission denied|Permission to .+ denied|Write access to repository not granted|returned error: (401|403)|Connection timed out|Operation timed out|Failed to connect|Connection refused|Repository not found|Could not resolve host' >/dev/null; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_CATEGORY="env"
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_PREFIX="git push auth/network/config"
    elif printf '%s\n' "$push_output" | grep -E '\[remote rejected\]|hook declined' >/dev/null; then
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_CATEGORY="judgment"
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_PREFIX="git push rejected; local commit preserved"
    else
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_CATEGORY="judgment"
        # shellcheck disable=SC2034 # caller-visible contract (see file header)
        PUSH_BAIL_PREFIX="git push failed; local commit preserved"
    fi
}
