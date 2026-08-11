#!/usr/bin/env bash
# tests/test-grind-set-member.sh - behavioral tests for the Rail A consumer.
#
# The presence table below is mirrored row-for-row from ADR 0036 / section 4 of
# the design. It is the one place the gate can silently drift back to fail-OPEN,
# which is precisely #620's failure mode, so every row is asserted.
#
# shellcheck disable=SC2329  # all test_* functions invoked dynamically via declare -F
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/grind-set-member.sh"

SANDBOX_ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

REPO=$(mktemp -d "$SANDBOX_ROOT/repo.XXXXXX") || { echo "FAIL: mktemp -d failed"; exit 1; }
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit -q --allow-empty -m "chore: base"
C1=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m "fix: grind one"
C2=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m "feat: author work"
C3=$(git -C "$REPO" rev-parse HEAD)
ABSENT=0000000000000000000000000000000000000042
ALLZERO=0000000000000000000000000000000000000000

# run <expected_rc> <args...>
#
# Records the first mismatch in RUN_FAILED rather than relying on the caller to
# chain every invocation: a test body whose non-final `run` call fails would
# otherwise return the LAST call's status and report PASS. That masked two real
# malformed-separator cases during development.
RUN_FAILED=0
run() {
    local want="$1"; shift
    local rc
    bash "$SCRIPT" "$@" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "  expected rc $want, got $rc for: $*"
        RUN_FAILED=1
        return 1
    fi
}

# --- membership ---------------------------------------------------------------

test_member_of_durable_set() {
    run 0 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$C2"
}

test_non_member_is_author_written() {
    run 1 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$C3"
}

test_member_of_prior_attempts_only() {
    run 0 -C "$REPO" --prior "commit=$C2" "$C2"
}

test_union_is_not_prior_attempts_alone() {
    # The #620 defect asserted at the consumer: empty PRIOR_ATTEMPTS (a fresh
    # invocation) must still attribute a prior invocation's commit.
    run 0 -C "$REPO" --shas "$C2" --status ok --head "$C3" --prior "" "$C2"
}

test_prior_attempts_none_sentinel_is_not_a_member() {
    run 1 -C "$REPO" --shas none --status ok --head "$C3" --prior "commit=none" "$C3"
}

test_prior_attempts_unresolvable_is_dropped_not_bailed() {
    # Inherited fail-OPEN behavior (agents/pr-grinder.md:300), kept for
    # backward compatibility - unlike GRIND_SHAS, which is strict.
    run 1 -C "$REPO" --prior "commit=$ABSENT" "$C3"
    run 0 -C "$REPO" --prior "commit=$ABSENT,commit=$C2" "$C2"
}

test_short_sha_blamed_input_normalizes() {
    run 0 -C "$REPO" --shas "$C2" --status ok --head "$C3" "${C2:0:8}"
}

test_porcelain_header_line_is_accepted() {
    # `git blame --porcelain | head -1` yields "<sha> <orig> <final> <count>",
    # not a bare SHA. A caller forwarding the whole line must not get a
    # guaranteed non-match and a permanently inert gate.
    run 0 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$C2 1 1 3"
}

test_all_zero_blame_sha_is_author_written() {
    # Not-yet-committed line: no provenance. Must exit 1, and must not reach
    # rev-parse (which is fatal on the all-zero SHA), so no rc 3.
    run 1 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$ALLZERO"
}

test_contract_violation_outranks_the_all_zero_verdict() {
    # The all-zero marker exits 1 ("author-written"). If that early return ran
    # before the contract fields were validated, a broken contract would be
    # reported as a clean verdict - fail-OPEN, and invisible.
    local zero="$ALLZERO"
    run 3 -C "$REPO" --shas "" --status ok --head "$C3" "$zero"
    run 3 -C "$REPO" --shas "$C2" --status unavailable --head "$C3" "$zero"
    run 3 -C "$REPO" --shas "$C2" "$zero"
    run 3 -C "$REPO" --shas "$C2,,$C1" --status ok --head "$C3" "$zero"
    # ...and with a VALID contract, the marker still means author-written.
    run 1 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$zero"
}

test_unresolvable_blamed_sha_bails() {
    run 3 -C "$REPO" --shas "$C2" --status ok --head "$C3" "$ABSENT"
}

# --- presence table (exhaustive) ----------------------------------------------

test_both_fields_absent_is_pre_contract_no_bail() {
    run 1 -C "$REPO" "$C2"
    run 0 -C "$REPO" --prior "commit=$C2" "$C2"
}

test_shas_present_without_status_bails() {
    run 3 -C "$REPO" --shas "$C2" "$C2"
}

test_status_present_without_shas_bails() {
    run 3 -C "$REPO" --status ok --head "$C3" "$C2"
}

test_status_unavailable_bails() {
    run 3 -C "$REPO" --shas "$C2" --status unavailable --head "$C3" "$C2"
    run 3 -C "$REPO" --shas none --status unavailable --head "$C3" "$C2"
}

test_unknown_status_bails() {
    run 3 -C "$REPO" --shas "$C2" --status OK --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "$C2" --status "" --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "$C2" --status yes --head "$C3" "$C2"
}

test_none_with_ok_is_a_valid_empty_set() {
    run 1 -C "$REPO" --shas none --status ok --head "$C3" "$C2"
}

test_empty_or_whitespace_shas_with_ok_bails() {
    run 3 -C "$REPO" --shas "" --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "   " --status ok --head "$C3" "$C2"
}

test_malformed_separators_bail() {
    run 3 -C "$REPO" --shas "$C2," --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas ",$C2" --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "$C2,,$C1" --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "$C2 $C1" --status ok --head "$C3" "$C2"
}

test_short_token_bails() {
    # A shortened OID in the certified set is a broken contract, not something
    # to helpfully expand: the producer emits full OIDs only.
    run 3 -C "$REPO" --shas "${C2:0:8}" --status ok --head "$C3" "$C2"
}

test_non_hex_token_bails() {
    run 3 -C "$REPO" --shas "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" --status ok --head "$C3" "$C2"
}

test_glob_token_does_not_expand_to_a_valid_oid() {
    # The comma list is split with an unquoted `set --`, which globs as well as
    # word-splits. Without `set -f`, forty `?` characters expand against the
    # working directory, so a file named after a real commit OID would let a
    # non-hex token pass strict validation.
    local decoy="$SANDBOX_ROOT/decoy"
    mkdir -p "$decoy"
    : > "$decoy/$C2"
    local rc
    (cd "$decoy" && bash "$SCRIPT" -C "$REPO" \
        --shas "????????????????????????????????????????" --status ok "$C2") >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 3 ] || { echo "glob token expanded instead of BAILing (rc $rc)"; return 1; }
}

test_annotated_tag_oid_token_bails() {
    # `^{commit}` PEELS, so a tag OID verifies while naming a different object.
    # Accepting it would store the unpeeled tag OID, which can never match a
    # blamed commit - a silent non-membership hiding a malformed certified set.
    git -C "$REPO" tag -a -m "release" v-test "$C2" 2>/dev/null
    local tag_oid
    tag_oid=$(git -C "$REPO" rev-parse v-test)
    [ "$tag_oid" != "$C2" ] || { echo "fixture: tag did not create an annotated object"; return 1; }
    run 3 -C "$REPO" --shas "$tag_oid" --status ok --head "$C3" "$C2"
}

test_short_all_zero_input_is_not_the_uncommitted_marker() {
    # Only a FULL-WIDTH all-zero OID is blame's not-yet-committed marker. "0" or
    # "00" is malformed input and must fail validation, not be waved through as
    # author-written.
    run 3 -C "$REPO" --shas "$C2" --status ok --head "$C3" "0"
    run 3 -C "$REPO" --shas "$C2" --status ok --head "$C3" "00000000"
}

test_unresolvable_token_bails() {
    # Full-width, valid hex, but not a commit here. Strict: BAIL, never drop.
    run 3 -C "$REPO" --shas "$ABSENT" --status ok --head "$C3" "$C2"
    run 3 -C "$REPO" --shas "$C2,$ABSENT" --status ok --head "$C3" "$C2"
}

# --- the certified set is bound to the HEAD it was derived at ------------------

test_stale_certified_set_bails() {
    # pr-grind supports concurrent runs, so another invocation can advance the
    # shared worktree between the dispatcher's scan and this blame. Its new
    # commit is in neither GRIND_SHAS nor this invocation's PRIOR_ATTEMPTS, so
    # findings on it would read as author-written - silently re-inerting the
    # gate. A stale snapshot must BAIL, not answer.
    run 3 -C "$REPO" --shas "$C2" --status ok --head "$C1" "$C2"
    run 3 -C "$REPO" --shas none --status ok --head "$C2" "$C2"
}

test_certified_set_without_head_bails() {
    run 3 -C "$REPO" --shas "$C2" --status ok "$C2"
    run 3 -C "$REPO" --shas none --status ok "$C2"
}

test_head_without_certified_set_bails() {
    run 3 -C "$REPO" --head "$C3" "$C2"
    run 3 -C "$REPO" --head "$C3" --prior "commit=$C2" "$C2"
}

test_prior_attempts_only_needs_no_head() {
    # The inherited path is unchanged: PRIOR_ATTEMPTS carries no snapshot claim,
    # so it neither needs nor accepts one.
    run 0 -C "$REPO" --prior "commit=$C2" "$C2"
}

# --- usage --------------------------------------------------------------------

test_missing_dash_C_is_usage_error() {
    run 2 --shas none --status ok --head "$C3" "$C2"
}

test_missing_blamed_sha_is_usage_error() {
    run 2 -C "$REPO" --shas none --status ok --head "$C3"
}

test_runs_from_foreign_cwd() {
    local rc
    (cd "$SANDBOX_ROOT" && bash "$SCRIPT" -C "$REPO" --shas "$C2" --status ok --head "$C3" "$C2") >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo "foreign-CWD run: expected rc 0, got $rc"; return 1; }
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
    RUN_FAILED=0
    if "$t" && [ "$RUN_FAILED" -eq 0 ]; then
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
