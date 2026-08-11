#!/usr/bin/env bash
# tests/test-grind-pr-commits.sh - behavioral tests for the Rail A producer.
#
# Real fixture repos, real git output. The helper owns the grind-written
# predicate, so it owns most of Rail A's coverage.
#
# shellcheck disable=SC2329  # all test_* functions invoked dynamically via declare -F
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/grind-pr-commits.sh"

SANDBOX_ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

# Build a fixture repo with one base commit. Echoes the repo path.
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

# commit_msg <repo> <message>  - one empty commit carrying an exact message.
commit_msg() {
    # `|| return 1` is load-bearing: without it a failed commit falls through to
    # rev-parse, which SUCCEEDS by returning the PREVIOUS commit. Two fixture
    # commits could then collapse to one SHA and the test still pass.
    git -C "$1" commit -q --allow-empty -F - <<< "$2" || return 1
    git -C "$1" rev-parse HEAD
}

test_emits_one_sha_per_line_no_commit_header() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    local a b out
    a=$(commit_msg "$r" $'fix: something\n\nbody\n\nGrind-PR: 617') || return 1
    b=$(commit_msg "$r" $'fix: other\n\nbody\n\nGrind-PR: 617') || return 1
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)") || {
        echo "expected rc 0"; return 1; }
    # `git rev-list --format=%H` emits a "commit <sha>" header AND the sha,
    # doubling every count. Two commits must be exactly two lines.
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ] || {
        echo "expected 2 lines, got: $out"; return 1; }
    printf '%s\n' "$out" | grep -qxF "$a" && printf '%s\n' "$out" | grep -qxF "$b"
}

test_empty_set_is_rc0_and_empty_output() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" "feat: author work" >/dev/null || return 1
    local out rc
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)"); rc=$?
    [ "$rc" -eq 0 ] || { echo "expected rc 0, got $rc"; return 1; }
    [ -z "$out" ] || { echo "expected empty output, got: $out"; return 1; }
}

test_git_failure_exits_3_not_empty_set() {
    # A non-repo directory must be a scan failure, never rc 0 + empty output.
    local d; d=$(mktemp -d "$SANDBOX_ROOT/notrepo.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }
    local out rc
    out=$(bash "$SCRIPT" -C "$d" 617 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>/dev/null); rc=$?
    [ "$rc" -eq 3 ] || { echo "expected rc 3, got $rc (out=$out)"; return 1; }
}

test_unresolvable_base_or_head_exits_3() {
    local r; r=$(new_repo) || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local rc
    bash "$SCRIPT" -C "$r" 617 0000000000000000000000000000000000000042 "$head" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || { echo "absent base: expected rc 3, got $rc"; return 1; }
    bash "$SCRIPT" -C "$r" 617 "$head" 0000000000000000000000000000000000000042 >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || { echo "absent head: expected rc 3, got $rc"; return 1; }
}

test_unrelated_base_and_head_exits_3() {
    # `git rev-list A..B` is rc 0 for ANY pair. When base is not an ancestor of
    # head, trunk history re-enters the range and squash commits carrying
    # Grind-PR: lines come with it - the false-BAIL vector range scoping claims
    # to close. Refuse the wrong-shaped range instead of scanning it.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    git -C "$r" checkout -q --orphan unrelated
    git -C "$r" commit -q --allow-empty -m "chore: unrelated root"
    local other; other=$(git -C "$r" rev-parse HEAD)
    local rc
    bash "$SCRIPT" -C "$r" 617 "$base" "$other" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 3 ] || { echo "expected rc 3 for unrelated base, got $rc"; return 1; }
}

test_shallow_repo_exits_3() {
    local r; r=$(new_repo) || return 1
    commit_msg "$r" $'fix: x\n\nGrind-PR: 617' >/dev/null || return 1
    local sh; sh=$(mktemp -d "$SANDBOX_ROOT/shallow.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }
    rm -rf "$sh"
    git clone -q --depth 1 "file://$r" "$sh" 2>/dev/null || { echo "SKIP: shallow clone unavailable"; return 0; }
    local head; head=$(git -C "$sh" rev-parse HEAD)
    local rc
    bash "$SCRIPT" -C "$sh" 617 "$head" "$head" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 3 ] || { echo "expected rc 3 for shallow repo, got $rc"; return 1; }
}

test_counts_trailer_commits_for_this_pr() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    local a; a=$(commit_msg "$r" $'fix: address PR #617 feedback\n\nfixed it\n\nGrind-PR: 617') || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ "$out" = "$a" ] || { echo "expected $a, got: $out"; return 1; }
}

test_ignores_foreign_pr_trailer() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'fix: other pr\n\nGrind-PR: 999' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "expected empty, got: $out"; return 1; }
}

test_pr_number_prefix_collision() {
    # --grep is line-anchored but not end-anchored: '^Grind-PR: 61' matches
    # 'Grind-PR: 617'.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'fix: x\n\nGrind-PR: 617' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 61 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "PR 61 must not match Grind-PR: 617, got: $out"; return 1; }
}

test_out_of_range_commit_not_counted() {
    # The false-BAIL guard: a commit carrying this PR's own trailer that is
    # already on the base (as a merged squash on main would be) is outside
    # base..head and must never be attributed.
    local r; r=$(new_repo) || return 1
    commit_msg "$r" $'chore: squash of an earlier merge\n\nGrind-PR: 617' >/dev/null || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" "feat: author work" >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "out-of-range commit was counted: $out"; return 1; }
}

test_transitional_subject_arm_counts() {
    # Regression for the %x00-in-$() defect: command substitution discards the
    # NUL, concatenating <sha><subject> so the arm can never fire.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    local a; a=$(commit_msg "$r" $'fix: address PR #617 feedback\n\nno trailer here') || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ "$out" = "$a" ] || { echo "subject arm did not fire; got: $out"; return 1; }
}

test_subject_arm_ignores_body_match() {
    # --grep would match the body; the subject arm must not.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'feat: author work\n\nquoting the grind: fix: address PR #617 feedback' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "body match was counted: $out"; return 1; }
}

test_trailer_and_subject_on_same_commit_counted_once() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'fix: address PR #617 feedback\n\nboth arms\n\nGrind-PR: 617' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || {
        echo "expected 1 deduped line, got: $out"; return 1; }
}

test_malformed_trailer_not_counted() {
    # 'grind-pr:617' passes git's own trailer parser but is NOT what the scanner
    # matches. It must not be counted here - preventing its creation is the
    # commit-block verifier's job (ADR 0036 section 2).
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'chore: x\n\ngrind-pr:617' >/dev/null || return 1
    commit_msg "$r" $'chore: y\n\nGrind-PR:617' >/dev/null || return 1
    commit_msg "$r" $'chore: z\n\n Grind-PR: 617' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "malformed trailers were counted: $out"; return 1; }
}

test_non_numeric_pr_number_exits_2() {
    local r; r=$(new_repo) || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local rc
    for bad in "abc" "" "61a" "0617" "0" "-1"; do
        bash "$SCRIPT" -C "$r" "$bad" "$head" "$head" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 2 ] || { echo "PR '$bad': expected rc 2, got $rc"; return 1; }
    done
}

test_runs_from_foreign_cwd_via_dash_C() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    local a; a=$(commit_msg "$r" $'fix: x\n\nGrind-PR: 617') || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local out
    out=$(cd "$SANDBOX_ROOT" && bash "$SCRIPT" -C "$r" 617 "$base" "$head")
    [ "$out" = "$a" ] || { echo "foreign-CWD run failed: $out"; return 1; }
}

test_missing_dash_C_exits_2() {
    local r; r=$(new_repo) || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local rc
    bash "$SCRIPT" 617 "$head" "$head" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] || { echo "expected rc 2 without -C, got $rc"; return 1; }
}

test_context_mode_empty_set_renders_none_not_one() {
    # `helper | wc -l` on empty output returns 1. --context exists so that
    # off-by-one cannot be reintroduced by a caller.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" "feat: author work" >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" --context -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    local head; head=$(git -C "$r" rev-parse HEAD)
    [ "$out" = "GRIND_SHAS=none"$'\n'"GRIND_SHAS_STATUS=ok"$'\n'"GRIND_HEAD_SHA=$head" ] || {
        echo "expected none/ok/head, got: $out"; return 1; }
}

test_context_mode_renders_comma_list_without_trailing_comma() {
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'fix: a\n\nGrind-PR: 617' >/dev/null || return 1
    commit_msg "$r" $'fix: b\n\nGrind-PR: 617' >/dev/null || return 1
    local out shas
    out=$(bash "$SCRIPT" --context -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    shas=$(printf '%s\n' "$out" | sed -n 's/^GRIND_SHAS=//p')
    printf '%s\n' "$shas" | grep -Eqx '[0-9a-f]{40},[0-9a-f]{40}' || {
        echo "bad GRIND_SHAS rendering: '$shas'"; return 1; }
    printf '%s\n' "$out" | grep -qx 'GRIND_SHAS_STATUS=ok'
}

test_shadowed_git_does_not_fail_open() {
    # bash imports `BASH_FUNC_<name>%%` env entries as shell functions, and this
    # repo's gate env is repo-injectable (#325 / ADR 0016). Stub `git` AND the
    # builtins the in-script cleanup depends on, so the cleanup itself is
    # defeated.
    #
    # The invariant under test is the PROPERTY, not any one mechanism: the scan
    # must never report an empty set as if it had succeeded. Failing closed
    # (rc 3, canary) and returning the correct set (the `command` builtin
    # bypassing the shadow) are both fine. `GRIND_SHAS=none` + `STATUS=ok` +
    # exit 0, with a real grind commit sitting in range, is the fail-OPEN this
    # guards — and it is what the unhardened script actually did.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    local g; g=$(commit_msg "$r" $'fix: x\n\nGrind-PR: 617') || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local out rc
    out=$(
        git()     { :; }
        unset()   { :; }
        declare() { :; }
        export -f git
        export -f unset
        # shellcheck disable=SC2316  # exporting a FUNCTION named declare is the point
        export -f declare
        bash "$SCRIPT" --context -C "$r" 617 "$base" "$head" 2>&1
    ); rc=$?

    [ "$rc" -ne 3 ] || return 0          # failed closed — acceptable
    [ "$rc" -eq 0 ] || { echo "unexpected rc $rc under shadowing: $out"; return 1; }
    printf '%s\n' "$out" | grep -qxF "GRIND_SHAS=$g" || {
        echo "FAIL-OPEN: shadowed git yielded '$out' instead of the real set"
        return 1
    }
}

test_body_quoted_trailer_not_counted() {
    # --grep matches any line, including body prose. An author commit quoting an
    # exact `Grind-PR: N` line mid-body must NOT be attributed to the grind:
    # that would false-BAIL on the author's own code. The trailer parser is the
    # second predicate that excludes it.
    local r; r=$(new_repo) || return 1
    local base; base=$(git -C "$r" rev-parse HEAD)
    commit_msg "$r" $'feat: author work\n\nquoting a prior commit below:\n\nGrind-PR: 617\n\n...and then more prose, so it is not the last paragraph.' >/dev/null || return 1
    local out
    out=$(bash "$SCRIPT" -C "$r" 617 "$base" "$(git -C "$r" rev-parse HEAD)")
    [ -z "$out" ] || { echo "body-quoted trailer was counted: $out"; return 1; }
}

test_symbolic_or_abbreviated_ref_exits_2() {
    # The snapshot-binding contract: base/head must already be full OIDs, or the
    # scan can read a different commit than the worker blames.
    local r; r=$(new_repo) || return 1
    local head; head=$(git -C "$r" rev-parse HEAD)
    local rc bad
    # No `${head^^}` — that is a bash 4 expansion and macOS ships /bin/bash 3.2,
    # where it aborts the suite with "bad substitution". A literal uppercase OID
    # exercises the same rejection path.
    for bad in HEAD main "${head:0:12}" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
        bash "$SCRIPT" -C "$r" 617 "$head" "$bad" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 2 ] || { echo "head '$bad': expected rc 2, got $rc"; return 1; }
        bash "$SCRIPT" -C "$r" 617 "$bad" "$head" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 2 ] || { echo "base '$bad': expected rc 2, got $rc"; return 1; }
    done
}

test_context_mode_scan_failure_still_exits_3_with_no_fields() {
    local d; d=$(mktemp -d "$SANDBOX_ROOT/notrepo2.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }
    local out rc
    out=$(bash "$SCRIPT" --context -C "$d" 617 \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2>/dev/null); rc=$?
    [ "$rc" -eq 3 ] || { echo "expected rc 3, got $rc"; return 1; }
    [ -z "$out" ] || { echo "scan failure must emit no context fields, got: $out"; return 1; }
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
