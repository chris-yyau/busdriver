#!/usr/bin/env bash
# tests/test-grind-provenance-gate.sh - drift guards over the two prose surfaces
# of Rail A (ADR 0036): skills/pr-grind/SKILL.md and agents/pr-grinder.md.
#
# HONEST CEILING, stated the same way tests/test-pr-grind-codex-wiring.sh:5-11
# states it: these are golden greps. They prove WIRING and ORDERING, not runtime
# behavior. They exist because both documents are agent-executed prose, so the
# only thing that can stop a future edit from silently re-inerting the gate is an
# assertion that the load-bearing sentences are still there.
#
# The behavioral weight of Rail A sits in three fixture-backed suites:
#   tests/test-grind-pr-commits.sh        - the producer's predicate
#   tests/test-grind-set-member.sh        - the consumer's validation + membership
#   tests/test-dispatcher-commit-block.sh - writer/reader agreement on real commits
#
# shellcheck disable=SC2329  # all test_* functions invoked dynamically via declare -F
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_ROOT/skills/pr-grind/SKILL.md"
AGENT="$REPO_ROOT/agents/pr-grinder.md"

want() {
    local file="$1" pattern="$2" label="$3"
    grep -q -- "$pattern" "$file" || {
        echo "  missing in ${file#"$REPO_ROOT"/}: $label"
        return 1
    }
}

reject() {
    local file="$1" pattern="$2" label="$3"
    grep -q -- "$pattern" "$file" && {
        echo "  still present in ${file#"$REPO_ROOT"/}: $label"
        return 1
    }
    return 0
}

test_round_1_impossibility_sentence_removed() {
    # The single sentence whose survival would silently re-inert the gate for
    # every re-invocation - #620's exact defect.
    reject "$AGENT" 'this gate can never fire' \
        "the round-1 impossibility sentence"
}

test_grind_set_defined_as_union_not_prior_attempts_alone() {
    want "$AGENT" 'GRIND_SET = {resolved PRIOR_ATTEMPTS commit= values}' \
        "the GRIND_SET union definition" || return 1
    want "$AGENT" 'validated GRIND_SHAS entries' \
        "the durable half of the union"
}

test_grind_shas_validation_is_strict_and_bails() {
    # The fail direction. If this drifts back to the inherited fail-OPEN rule, a
    # corrupted durable set degrades silently to today's inert gate while
    # GRIND_SHAS_STATUS still reads ok.
    want "$AGENT" 'GRIND_SHAS` is \*\*strict\*\*' \
        "the strictness declaration" || return 1
    want "$AGENT" 'any violation BAILs `env`' \
        "the BAIL-on-violation rule" || return 1
    want "$AGENT" 'keeps the inherited fail-OPEN behavior' \
        "the deliberate PRIOR_ATTEMPTS/GRIND_SHAS asymmetry"
}

test_consumer_delegates_to_the_helper() {
    # The prose must route through the tested script rather than restating the
    # presence table, which is where a hand-rolled reimplementation would drift.
    want "$AGENT" 'scripts/grind-set-member.sh' \
        "the grind-set-member.sh delegation" || return 1
    want "$AGENT" 'exit 3 → BAIL' \
        "the helper's exit-3 contract"
}

test_blame_sha_extraction_documented() {
    # The old comment claimed this pipeline yields a bare SHA. It yields a
    # porcelain header line; an implementer comparing it raw gets a guaranteed
    # non-match and a permanently inert gate.
    reject "$AGENT" 'head -1   # → full SHA' \
        "the wrong '# → full SHA' comment" || return 1
    want "$AGENT" 'porcelain HEADER LINE' \
        "the corrected blame-output shape" || return 1
    want "$AGENT" 'all-zero blamed SHA is author-written' \
        "the all-zero skip"
}

test_bail_reason_covers_prior_invocation_attribution() {
    want "$AGENT" 'prior invocation — round labels unavailable' \
        "the cross-invocation bail-reason rule"
}

test_producer_call_documented_before_dispatch() {
    want "$SKILL" 'BEFORE the Agent dispatch, EVERY round' \
        "the pre-dispatch placement of the producer" || return 1
    want "$SKILL" 'grind-pr-commits.sh" --context' \
        "the --context producer call" || return 1
    # The call must be ordered above the dispatch line, not merely present.
    local producer_line dispatch_line
    producer_line=$(grep -n 'grind-pr-commits.sh" --context' "$SKILL" | head -1 | cut -d: -f1)
    dispatch_line=$(grep -n 'Agent(subagent_type="pr-grinder"' "$SKILL" | head -1 | cut -d: -f1)
    [ -n "$producer_line" ] && [ -n "$dispatch_line" ] || {
        echo "  could not locate both the producer call and the dispatch line"
        return 1
    }
    [ "$producer_line" -lt "$dispatch_line" ] || {
        echo "  producer call (line $producer_line) is not before dispatch (line $dispatch_line)"
        return 1
    }
}

test_producer_failure_bails_before_dispatch() {
    want "$SKILL" 'BAIL `env` BEFORE dispatching' \
        "the pre-dispatch BAIL on scan failure" || return 1
    want "$SKILL" 'Never pipe this call; never count its lines yourself' \
        "the no-pipeline / no-wc rule"
}

test_certified_set_is_bound_to_a_head_snapshot() {
    # Without GRIND_HEAD_SHA a concurrent same-PR grind can advance the shared
    # worktree between the scan and the blame, putting its commit in neither
    # GRIND_SHAS nor PRIOR_ATTEMPTS - findings on it read as author-written and
    # the gate is inert again.
    want "$SKILL" 'GRIND_HEAD_SHA=<full OID>' \
        "GRIND_HEAD_SHA in the worker context block" || return 1
    want "$SKILL" 'All THREE fields travel' \
        "the travel-together rule" || return 1
    want "$AGENT" -- '--head "<GRIND_HEAD_SHA verbatim>"' \
        "the --head argument in the worker's helper call"
}

test_context_block_carries_grind_shas() {
    want "$SKILL" 'GRIND_SHAS=<full-sha,full-sha,\.\.\. or "none">' \
        "GRIND_SHAS in the worker context block" || return 1
    want "$SKILL" 'GRIND_SHAS_STATUS=ok' \
        "GRIND_SHAS_STATUS in the worker context block"
}

test_base_fetch_is_forced_and_pr_scoped() {
    want "$SKILL" '+refs/heads/\${BASE_BRANCH}:refs/bd-grind/<PR_NUMBER>/base-\$\$' \
        "the forced, PR-scoped base refspec"
}

test_base_fetch_is_after_worktree_dir_exists() {
    # The fetch snippet uses the worktree. Placed with BASE_BRANCH resolution
    # ~70 lines earlier, WORKTREE_DIR does not exist yet and the block runs
    # `git -C ""` - fatal on every invocation, before round 1.
    local cd_line fetch_line
    cd_line=$(grep -n 'cd "\$WORKTREE_DIR" || { echo "❌ cd to' "$SKILL" | head -1 | cut -d: -f1)
    fetch_line=$(grep -n 'refs/bd-grind/<PR_NUMBER>/base-\$\$' "$SKILL" | head -1 | cut -d: -f1)
    [ -n "$cd_line" ] && [ -n "$fetch_line" ] || {
        echo "  could not locate both the cd and the base fetch"
        return 1
    }
    [ "$fetch_line" -gt "$cd_line" ] || {
        echo "  base fetch (line $fetch_line) precedes the cd into WORKTREE_DIR (line $cd_line)"
        return 1
    }
}

test_base_ref_is_deleted_in_the_same_block() {
    # Deleting it here is what removes the COMPLETION/BAIL cleanup row - which
    # would otherwise be skipped entirely under NO_WORKTREE=1, the most common
    # in-place mode, and leak the ref.
    want "$SKILL" 'git update-ref -d "refs/bd-grind/<PR_NUMBER>/base-\$\$"' \
        "the in-block scratch-ref deletion"
}

test_base_sha_is_a_cross_block_literal() {
    want "$SKILL" 'echo "BASE_SHA=\$BASE_SHA"' \
        "the BASE_SHA cross-block record" || return 1
    want "$SKILL" 'template-substitute it' \
        "the substitution instruction for BASE_SHA"
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
