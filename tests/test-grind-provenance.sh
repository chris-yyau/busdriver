#!/usr/bin/env bash
# tests/test-grind-provenance.sh - the producer -> consumer seam (Rail A / ADR 0036).
#
# The other two suites test each half against HAND-WRITTEN values on the other
# side. This one runs the real producer's output straight into the real
# consumer's input, which is where a rendering drift would hide: the consumer
# BAILs env on a trailing comma, embedded whitespace, uppercase hex, or a short
# OID, so any drift in how `--context` renders the list turns into a hard BAIL
# before every dispatch.
#
# NOTE ON NAMING: the reviewed design listed this file as "Rail A's acceptance
# test" covering producer wiring via golden greps. Those greps now live in
# tests/test-grind-provenance-gate.sh, declared as drift guards; the executable
# acceptance weight is here plus test_grind_c in
# tests/test-dispatcher-commit-block.sh (dispatcher's real commit message ->
# scanner). See ADR 0036, "Two prose seams become executable scripts".
#
# shellcheck disable=SC2329  # all test_* functions invoked dynamically via declare -F
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCER="$REPO_ROOT/scripts/grind-pr-commits.sh"
CONSUMER="$REPO_ROOT/scripts/grind-set-member.sh"

SANDBOX_ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

new_repo() {
    local dir
    dir=$(mktemp -d "$SANDBOX_ROOT/repo.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }
    # Every step checked: a silently failed setup leaves a directory that is not
    # a repo, and later asserts can pass for the wrong reason.
    git -C "$dir" init -q -b main || return 1
    git -C "$dir" config user.email t@example.com || return 1
    git -C "$dir" config user.name Test || return 1
    git -C "$dir" commit -q --allow-empty -m "chore: base" || return 1
    printf '%s' "$dir"
}

commit_msg() {
    # `|| return 1` is load-bearing: without it a failed commit falls through to
    # rev-parse, which SUCCEEDS by returning the PREVIOUS commit. Two fixture
    # commits could then collapse to one SHA and the test still pass.
    git -C "$1" commit -q --allow-empty -F - <<< "$2" || return 1
    git -C "$1" rev-parse HEAD
}

# Run the producer in --context mode and split its two lines the way the
# dispatcher is instructed to: verbatim, no reformatting.
produce() {
    local repo="$1" pr="$2" base="$3" head="$4" out
    out=$(bash "$PRODUCER" --context -C "$repo" "$pr" "$base" "$head") || return 1
    CTX_SHAS=$(printf '%s\n' "$out" | sed -n 's/^GRIND_SHAS=//p')
    CTX_STATUS=$(printf '%s\n' "$out" | sed -n 's/^GRIND_SHAS_STATUS=//p')
}

test_gate_fires_on_prior_invocation_commit() {
    # THE #620 defect, end to end. A branch whose history already contains a
    # grind commit from an EARLIER invocation, dispatched with an empty
    # PRIOR_ATTEMPTS (which is how every re-invocation starts). Before Rail A the
    # comparison set was empty here and the gate could not fire.
    local r base prior_grind author head
    r=$(new_repo) || return 1
    base=$(git -C "$r" rev-parse HEAD)
    prior_grind=$(commit_msg "$r" $'fix: address PR #617 feedback\n\nfrom a previous invocation\n\nGrind-PR: 617') || return 1
    author=$(commit_msg "$r" $'feat: author work\n\nhand written') || return 1
    head=$(git -C "$r" rev-parse HEAD)

    produce "$r" 617 "$base" "$head" || { echo "producer failed"; return 1; }
    [ "$CTX_STATUS" = "ok" ] || { echo "status was '$CTX_STATUS'"; return 1; }

    # --prior "" models the empty PRIOR_ATTEMPTS of a fresh invocation.
    local rc
    bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" --prior "" "$prior_grind"
    rc=$?
    [ "$rc" -eq 0 ] || {
        echo "prior-invocation grind commit was NOT attributed (rc $rc, shas='$CTX_SHAS')"
        return 1
    }
    bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" --prior "" "$author"
    rc=$?
    [ "$rc" -eq 1 ] || {
        echo "author commit was misattributed as grind-written (rc $rc)"
        return 1
    }
}

test_producer_rendering_survives_consumer_validation_multi_sha() {
    # Comma joining is the drift risk: a trailing comma, a space after the
    # comma, or an abbreviated OID all BAIL env at the consumer.
    local r base a b head
    r=$(new_repo) || return 1
    base=$(git -C "$r" rev-parse HEAD)
    a=$(commit_msg "$r" $'fix: a\n\nGrind-PR: 617') || return 1
    b=$(commit_msg "$r" $'fix: b\n\nGrind-PR: 617') || return 1
    commit_msg "$r" 'feat: author work' >/dev/null || return 1
    head=$(git -C "$r" rev-parse HEAD)

    produce "$r" 617 "$base" "$head" || { echo "producer failed"; return 1; }
    local sha
    for sha in "$a" "$b"; do
        bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" "$sha" || {
            echo "consumer rejected producer output for $sha (shas='$CTX_SHAS')"
            return 1
        }
    done
}

test_producer_none_survives_consumer_validation() {
    # The empty set must round-trip as a valid empty durable set, NOT as a
    # contract violation - the difference between "no grind commits yet" and
    # "every grind BAILs".
    local r base head
    r=$(new_repo) || return 1
    base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" 'feat: author work' >/dev/null || return 1
    head=$(git -C "$r" rev-parse HEAD)

    produce "$r" 617 "$base" "$head" || { echo "producer failed"; return 1; }
    [ "$CTX_SHAS" = "none" ] || { echo "expected none, got '$CTX_SHAS'"; return 1; }

    local rc
    bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" "$head"
    rc=$?
    [ "$rc" -eq 1 ] || {
        echo "empty durable set did not classify as author-written (rc $rc)"
        return 1
    }
}

test_union_prefers_neither_source_exclusively() {
    # One commit known only to the durable set, one known only to
    # PRIOR_ATTEMPTS: both must be members. A consumer that read either source
    # alone would pass half of this.
    local r base durable inprogress head
    r=$(new_repo) || return 1
    base=$(git -C "$r" rev-parse HEAD)
    durable=$(commit_msg "$r" $'fix: address PR #617 feedback\n\nprior invocation\n\nGrind-PR: 617') || return 1
    # A commit with no marker at all, known only because this invocation pushed
    # it and recorded it in PRIOR_ATTEMPTS.
    inprogress=$(commit_msg "$r" $'chore: unmarked but recorded in PRIOR_ATTEMPTS') || return 1
    head=$(git -C "$r" rev-parse HEAD)

    produce "$r" 617 "$base" "$head" || { echo "producer failed"; return 1; }
    printf '%s\n' "$CTX_SHAS" | grep -qF "$inprogress" && {
        echo "fixture invalid: the unmarked commit is in the durable set"
        return 1
    }
    bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" \
        --prior "commit=$inprogress" "$durable" || {
        echo "durable-only commit not attributed"; return 1; }
    bash "$CONSUMER" -C "$r" --shas "$CTX_SHAS" --status "$CTX_STATUS" \
        --prior "commit=$inprogress" "$inprogress" || {
        echo "PRIOR_ATTEMPTS-only commit not attributed"; return 1; }
}

# Discover FIRST, with the pipeline's own status checked. `for t in $(...)`
# throws that status away, so a discovery pipeline that emits a PARTIAL list and
# then fails would run a subset and still let the suite exit green. The
# `discovered` counter below then catches the empty case.
tests_list=$(declare -F | awk '/test_/{print $3}' | sort)
discovery_rc=$?
[ "$discovery_rc" -eq 0 ] || {
    echo "FAIL: test discovery pipeline failed (exit $discovery_rc)"
    exit 1
}

failed=0
discovered=0
for t in $tests_list; do
    discovered=$((discovered + 1))
    if "$t"; then
        echo "PASS: $t"
    else
        echo "FAIL: $t"
        failed=1
    fi
done

[ "$discovered" -gt 0 ] || {
    echo "FAIL: test discovery produced ZERO tests - the suite asserted nothing"
    exit 1
}
exit "$failed"
