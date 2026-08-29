#!/usr/bin/env bash
# tests/test-dispatcher-commit-block.sh - scaffolding + helpers.
# Full scenario tests are added across later implementation phases.
#
# shellcheck disable=SC2329  # all test_* functions invoked dynamically via declare -F
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the index-only premise test (test_q) can be re-run against a
# deliberately-broken copy to prove it fails — see that test's header.
SCRIPT="${DISPATCHER_COMMIT_BLOCK:-$REPO_ROOT/scripts/dispatcher-commit-block.sh}"

fail_test() {
    echo "FAIL: $1"
    return 1
}

assert_json() {
    local json="$1"
    local expr="$2"

    printf '%s\n' "$json" | jq -e "$expr" >/dev/null
}

write_default_plugin_root() {
    mkdir -p "$plugin_root/scripts/lib" "$plugin_root/skills/litmus/scripts/lib"

    ln -s "$REPO_ROOT/scripts/lib/bail-envelope.sh" "$plugin_root/scripts/lib/bail-envelope.sh"
    ln -s "$REPO_ROOT/scripts/lib/staged-diff-hash.sh" "$plugin_root/scripts/lib/staged-diff-hash.sh"
    ln -s "$REPO_ROOT/scripts/lib/dispatcher-proc-state.sh" \
        "$plugin_root/scripts/lib/dispatcher-proc-state.sh"
    ln -s "$REPO_ROOT/scripts/lib/exclusion-integrity.sh" \
        "$plugin_root/scripts/lib/exclusion-integrity.sh"
    ln -s "$REPO_ROOT/scripts/ack-ledger.sh" "$plugin_root/scripts/ack-ledger.sh"
    # Real exclusion logic — dispatcher sources this to re-verify excluded-only
    # PASS-EXCLUDED markers (#278).
    ln -s "$REPO_ROOT/skills/litmus/scripts/lib/exclude-generated.sh" \
        "$plugin_root/skills/litmus/scripts/lib/exclude-generated.sh"
    # Real lock primitive — the dispatcher and run-review-loop.sh must contend on the
    # same one, so stubbing it would test nothing.
    ln -s "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" \
        "$plugin_root/skills/litmus/scripts/lib/review-lock.sh"

    cat > "$plugin_root/scripts/fetch-pr-state.sh" <<'EOF'
FETCH_OK=1
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)
HEAD_FULL_SHA=$(git rev-parse HEAD)
ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
ALL_REVIEWS='[]'
ALL_COMMENTS='{"comments":[]}'
ALL_CHECK_RUNS='{"check_runs":[]}'
ALL_STATUSES='[]'
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS ALL_STATUSES HEAD_SHA HEAD_FULL_SHA
return 0
EOF

    # Mirrors the two parts of the real init-review-loop.sh contract this script
    # depends on (#569): it REFUSES while a state file says `active: true`, and
    # `--force` is the documented override. Logged separately from
    # DISPATCHER_EVENT_LOG so the litmus-before-commit ordering assertions stay
    # about litmus and commit only.
    cat > "$plugin_root/skills/litmus/scripts/init-review-loop.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${INIT_EVENT_LOG:-}" ]; then
    printf 'init:%s\n' "$*" >> "$INIT_EVENT_LOG"
fi
# Stand in for the failures that have nothing to do with the active-state guard —
# not a git repo, bad arguments, an unwritable state dir. --force is not their remedy.
if [ "${INIT_ALWAYS_FAILS:-0}" = "1" ]; then
    exit 1
fi
for _arg in "$@"; do
    [ "$_arg" = "--force" ] && exit 0
done
_state="${BUSDRIVER_STATE_DIR:-.claude}/litmus-state.md"
if [ -f "$_state" ] && grep -q '^active: true' "$_state"; then
    exit 1
fi
exit 0
EOF
    chmod +x "$plugin_root/skills/litmus/scripts/init-review-loop.sh"

    cat > "$plugin_root/skills/litmus/scripts/run-review-loop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

hash_staged_diff() {
    if command -v sha256sum >/dev/null 2>&1; then
        git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none | sha256sum | cut -d' ' -f1
    else
        git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none | shasum -a 256 | cut -d' ' -f1
    fi
}

write_marker() {
    mkdir -p .claude
    hash_staged_diff > .claude/litmus-passed.local
}

if [ -n "${DISPATCHER_EVENT_LOG:-}" ]; then
    printf 'litmus:%s\n' "$(git rev-parse HEAD)" >> "$DISPATCHER_EVENT_LOG"
fi

case "${LITMUS_MODE:-pass}" in
    pass)
        write_marker
        ;;
    review_findings)
        # Shape matches what the real script leaves behind on FAIL: the state file
        # SURVIVES with active: true (only PASS deletes it), and the blocking issues
        # are rendered to stdout as "  [severity] file:line - description".
        mkdir -p .claude
        printf 'active: true\nreview_status: "FAIL"\nterminal_status: review_findings\n' \
            > .claude/litmus-state.md
        printf 'FAIL - Issues found\n'
        printf 'Issues:\n'
        printf '  [high] scripts/foo.sh:42 - unvalidated counter aborts before block_emit\n'
        printf '  [medium] scripts/foo.sh:88 - unquoted expansion in the retry path\n'
        exit 1
        ;;
    stall)
        mkdir -p .claude
        printf 'terminal_status: stall\n' > .claude/litmus-state.md
        printf 'STALL DETECTED\n'
        exit 1
        ;;
    max_iterations)
        mkdir -p .claude
        printf 'terminal_status: max_iterations\n' > .claude/litmus-state.md
        printf 'Max iterations reached\n'
        exit 1
        ;;
    infra_failure)
        mkdir -p .claude
        printf 'terminal_status: infra_failure\n' > .claude/litmus-state.md
        printf 'transport broke before review completed\n'
        exit 1
        ;;
    terminal_preferred)
        mkdir -p .claude
        printf 'terminal_status: stall\n' > .claude/litmus-state.md
        printf 'Max iterations reached\nFAIL - Issues found\n'
        exit 1
        ;;
    autofix_inplace)
        printf 'litmus auto-fixed\n' >> file.txt
        git add file.txt
        write_marker
        ;;
    skipped)
        mkdir -p .claude
        printf 'SKIPPED-NONE test marker\n' > .claude/litmus-passed.local
        ;;
    nonhex)
        mkdir -p .claude
        printf 'not-a-sha\n' > .claude/litmus-passed.local
        ;;
    excluded_pass)
        # #278: excluded-only commit-mode auto-pass writes PASS-EXCLUDED-<epoch>
        # (no reviewer, no diff hash). Consumer re-verifies all-excluded.
        mkdir -p .claude
        printf 'PASS-EXCLUDED-%s\n' "$(date +%s)" > .claude/litmus-passed.local
        ;;
    *)
        printf 'unknown LITMUS_MODE=%s\n' "${LITMUS_MODE:-}" >&2
        exit 97
        ;;
esac
EOF
    chmod +x "$plugin_root/skills/litmus/scripts/run-review-loop.sh"
}

write_default_shims() {
    cat > "$shimdir/gh" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
    chmod +x "$shimdir/gh"

    cat > "$shimdir/npx" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
    chmod +x "$shimdir/npx"
}

make_dispatcher_fixture() {
    # Self-checking contract: all callers must declare these names with `local`
    # before invoking this function. Without `local`, the variables would silently
    # leak into the parent shell and corrupt subsequent tests.
    : "${sandbox?make_dispatcher_fixture caller must declare: local sandbox}"
    : "${plugin_root?make_dispatcher_fixture caller must declare: local plugin_root}"
    : "${shimdir?make_dispatcher_fixture caller must declare: local shimdir}"
    : "${remote?make_dispatcher_fixture caller must declare: local remote}"
    : "${original_dir?make_dispatcher_fixture caller must declare: local original_dir}"
    : "${initial_sha?make_dispatcher_fixture caller must declare: local initial_sha}"

    original_dir="$PWD"
    sandbox=$(mktemp -d)
    plugin_root=$(mktemp -d)
    shimdir=$(mktemp -d)
    remote=$(mktemp -d)

    write_default_plugin_root
    write_default_shims

    git init -q "$sandbox"
    git -C "$sandbox" checkout -q -b main
    git -C "$sandbox" config user.email test@example.com
    git -C "$sandbox" config user.name "Test User"
    git -C "$sandbox" config commit.gpgsign false
    git -C "$sandbox" config core.hooksPath .git/hooks
    printf 'base\n' > "$sandbox/file.txt"
    git -C "$sandbox" add file.txt
    git -C "$sandbox" commit --no-gpg-sign -qm initial
    initial_sha=$(git -C "$sandbox" rev-parse HEAD)

    git init --bare -q "$remote"
    git -C "$sandbox" remote add origin "$remote"
    git -C "$sandbox" push -q -u origin main

    printf 'changed\n' > "$sandbox/file.txt"
    git -C "$sandbox" add file.txt
}

run_dispatcher_capture() {
    local result_status="${1:-needs_more}"
    local result_fixes="${2:-add test coverage}"
    local allow_commitlint="${allow_no_commitlint:-1}"
    local -a env_args=(
        "PATH=$shimdir:$PATH"
        "WORKTREE_DIR=$sandbox"
        "CLAUDE_PLUGIN_ROOT=$plugin_root"
        "PR_NUMBER=${pr_number:-1}"
        "RESULT_STATUS=$result_status"
        "RESULT_FIXES=$result_fixes"
        "BUSDRIVER_ALLOW_NO_COMMITLINT=$allow_commitlint"
    )

    if [[ -n "${litmus_mode+x}" ]]; then env_args+=("LITMUS_MODE=$litmus_mode"); fi
    if [[ -n "${no_worktree+x}" ]]; then env_args+=("NO_WORKTREE=$no_worktree"); fi
    if [[ -n "${pre_dispatch_baseline+x}" ]]; then env_args+=("PRE_DISPATCH_BASELINE=$pre_dispatch_baseline"); fi
    if [[ -n "${gh_event_log+x}" ]]; then env_args+=("GH_EVENT_LOG=$gh_event_log"); fi
    if [[ -n "${dispatcher_event_log+x}" ]]; then env_args+=("DISPATCHER_EVENT_LOG=$dispatcher_event_log"); fi
    if [[ -n "${init_event_log+x}" ]]; then env_args+=("INIT_EVENT_LOG=$init_event_log"); fi
    if [[ -n "${init_always_fails+x}" ]]; then env_args+=("INIT_ALWAYS_FAILS=$init_always_fails"); fi
    if [[ -n "${result_reviewer_acks+x}" ]]; then env_args+=("RESULT_REVIEWER_ACKS=$result_reviewer_acks"); fi
    if [[ -n "${result_ack_tiers+x}" ]]; then env_args+=("RESULT_ACK_TIERS=$result_ack_tiers"); fi
    if [[ -n "${prior_commit_sha+x}" ]]; then env_args+=("PRIOR_COMMIT_SHA=$prior_commit_sha"); fi

    set +e
    dispatcher_output=$(env "${env_args[@]}" bash "$SCRIPT" 2>&1)
    dispatcher_exit=$?
    set -e
    dispatcher_json=$(printf '%s\n' "$dispatcher_output" | tail -n 1)
}

# Helper: run script with controlled env; capture last JSON line.
# `bash "$SCRIPT"`, never a bare `"$SCRIPT"`: since SCRIPT became overridable
# (DISPATCHER_COMMIT_BLOCK, #683) it routinely points at a doctored copy built
# by a `> /tmp/broken.sh` redirect, which lands at mode 0644. Executing that
# directly dies with `Permission denied` in t1 — before test_q, the very test
# the override exists to exercise, ever runs. Every other call site already
# used `bash`; this one was the odd one out. Keep them consistent.
run_dispatcher() {
    bash "$SCRIPT" 2>&1 | tail -n 1
}

# t1: missing required env -> bail with env (not judgment; missing vars are env failures).
# Also assert exit code == 1 (bail envelope contract; 0 is success envelope only).
t1_exit=0
# shellcheck disable=SC2310  # || true is the intentional exit-code capture pattern
result=$(WORKTREE_DIR="" CLAUDE_PLUGIN_ROOT="" PR_NUMBER="" RESULT_STATUS="" RESULT_FIXES="" run_dispatcher || true)
# shellcheck disable=SC2310
WORKTREE_DIR="" CLAUDE_PLUGIN_ROOT="" PR_NUMBER="" RESULT_STATUS="" RESULT_FIXES="" \
    bash "$SCRIPT" >/dev/null 2>&1 || t1_exit=$?
{ echo "$result" | jq -e '.bail_category == "env"' >/dev/null && [ "$t1_exit" -eq 1 ]; } \
    || { echo "FAIL t1: exit=$t1_exit result=$result"; exit 1; }

test_a_litmus_before_commit() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json dispatcher_event_log
    local first_event second_event
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    dispatcher_event_log="$sandbox/events.log"
    cat > "$sandbox/.git/hooks/pre-commit" <<EOF
#!/usr/bin/env bash
printf 'precommit:%s\n' "\$(git rev-parse HEAD)" >> "$dispatcher_event_log"
EOF
    chmod +x "$sandbox/.git/hooks/pre-commit"

    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_a dispatcher output: $dispatcher_output"
        return 1
    }

    first_event=$(sed -n '1p' "$dispatcher_event_log")
    second_event=$(sed -n '2p' "$dispatcher_event_log")
    [ "$first_event" = "litmus:$initial_sha" ] || {
        echo "test_a expected litmus first, got: $first_event"
        return 1
    }
    [ "$second_event" = "precommit:$initial_sha" ] || {
        echo "test_a expected precommit second, got: $second_event"
        return 1
    }
}
test_b_litmus_fail_to_pass() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=review_findings
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_b expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("review_findings"))'
}
test_c_marker_consumed() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    cat > "$sandbox/.git/hooks/post-commit" <<'EOF'
#!/usr/bin/env bash
rm -f .claude/litmus-passed.local
EOF
    chmod +x "$sandbox/.git/hooks/post-commit"

    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_c dispatcher output: $dispatcher_output"
        return 1
    }
    [ ! -f "$sandbox/.claude/litmus-passed.local" ] || {
        echo "test_c expected post-commit hook to consume litmus marker"
        return 1
    }
}
test_d_commitlint_bails() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json allow_no_commitlint
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    cat > "$shimdir/npx" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--no-install" ] && [ "$2" = "commitlint" ] && [ "${3:-}" = "--version" ]; then
    printf 'commitlint 0.0.0-test\n'
    exit 0
fi
if [ "$1" = "--no-install" ] && [ "$2" = "commitlint" ]; then
    printf 'commitlint fixture failure\n' >&2
    exit 1
fi
exit 127
EOF
    chmod +x "$shimdir/npx"

    allow_no_commitlint=0
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_d expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("commitlint pre-flight failed"))'
}
test_e_autofix_trailer_inplace() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode message
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=autofix_inplace
    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_e dispatcher output: $dispatcher_output"
        return 1
    }
    message=$(git -C "$sandbox" log -1 --format=%B)
    printf '%s\n' "$message" | grep -q 'Litmus-Auto-Fix: content-only-edits'
}
test_f_adversarial_result_fixes() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json before_count after_count message
    local result_fixes
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    before_count=$(git -C "$sandbox" rev-list --count HEAD)
    result_fixes='$(git commit -m pwned) && echo unsafe; RESULT_STATUS: clean'
    run_dispatcher_capture needs_more "$result_fixes"

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_f dispatcher output: $dispatcher_output"
        return 1
    }
    after_count=$(git -C "$sandbox" rev-list --count HEAD)
    [ "$after_count" -eq "$((before_count + 1))" ] || {
        echo "test_f expected exactly one dispatcher commit; before=$before_count after=$after_count"
        return 1
    }
    message=$(git -C "$sandbox" log -1 --format=%B)
    printf '%s\n' "$message" | grep -Fq '$(git commit -m pwned)'
}
test_g_no_worktree_subagent_parity() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json first_json first_exit
    local no_worktree pre_dispatch_baseline

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    run_dispatcher_capture
    first_json="$dispatcher_json"
    first_exit="$dispatcher_exit"
    rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    no_worktree=1
    pre_dispatch_baseline='[]'
    run_dispatcher_capture

    [ "$first_exit" -eq 0 ] || {
        echo "test_g subagent-style invocation failed: $first_json"
        return 1
    }
    [ "$dispatcher_exit" -eq 0 ] || {
        echo "test_g no-worktree invocation failed: $dispatcher_output"
        return 1
    }
    assert_json "$first_json" '.status == "success"' &&
        assert_json "$dispatcher_json" '.status == "success"'
}
test_h_litmus_stall() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=stall
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_h expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("litmus exit 1 (stall)"))'
}
test_i_litmus_max_iter() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=max_iterations
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_i expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("litmus exit 1 (max_iterations)"))'
}
test_j_litmus_infra_fail() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=infra_failure
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_j expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("litmus exit 1 (infra_failure)"))'
}
test_k_push_failure() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json before_sha after_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    before_sha=$(git -C "$sandbox" rev-parse HEAD)
    git -C "$sandbox" remote set-url origin "$sandbox/missing-remote.git"
    run_dispatcher_capture
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_k expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    [ "$after_sha" != "$before_sha" ] || {
        echo "test_k expected local commit to be preserved after push failure"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("git push failed"))'
}
test_l_fix_round_classifier() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json head_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    run_dispatcher_capture
    head_sha=$(git -C "$sandbox" rev-parse HEAD)

    printf '%s\n' "$dispatcher_json" | jq -e \
        --arg sha "$head_sha" '.status == "success" and .result_commit_sha == $sha' >/dev/null || {
            echo "test_l expected fix-round success envelope with HEAD sha; output=$dispatcher_output"
            return 1
        }
}
test_m_wait_round_classifier() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    run_dispatcher_capture needs_more "none"

    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.status == "success"
         and .result_commit_sha == "none"
         and .result_reviewer_acks == "cubic-dev-ai=none,coderabbitai=none,greptile-apps=none"
         and .result_ack_tiers == "cubic-dev-ai=none,coderabbitai=none,greptile-apps=none"' >/dev/null; then
        return 0
    fi

    fail_test "test_m wait-round no-staged path should return result_commit_sha=none with refreshed acks (cubic/coderabbit/greptile) and all-none tiers; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_668_reinvoked_fix_round_reports_landed_sha() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json head_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Round 1 (the real fix-round): the commit block commits + pushes the staged
    # fix (Grind-PR trailer stamped) and emits the real-SHA envelope.
    run_dispatcher_capture
    head_sha=$(git -C "$sandbox" rev-parse HEAD)
    printf '%s\n' "$dispatcher_json" | jq -e \
        --arg sha "$head_sha" '.status == "success" and .result_commit_sha == $sha' >/dev/null || {
            echo "test_668 round-1 envelope should carry the fix SHA; output=$dispatcher_output"
            return 1
        }

    # Round 1 RE-INVOCATION (the #668 shape): the dispatcher lost the first
    # envelope, re-routes the same fix-round, and the commit block now finds a
    # CLEAN index (the fix was consumed) with the Grind-PR commit at HEAD. It
    # must report the LANDED SHA — not "none", which would mislabel the round
    # as a wait-round and starve the dispatcher's --max-fix budget.
    run_dispatcher_capture
    if printf '%s\n' "$dispatcher_json" | jq -e \
        --arg sha "$head_sha" '.status == "success" and .result_commit_sha == $sha' >/dev/null; then
        return 0
    fi
    got_sha=$(printf '%s' "$dispatcher_json" | jq -r '.result_commit_sha // "?"' 2>/dev/null || echo "?")
    fail_test "test_668 re-invoked fix-round should report the landed SHA $head_sha, got result_commit_sha=$got_sha json=$dispatcher_json"
}
test_668_prior_sha_not_double_counted() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json head_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Round 1: the real fix-round lands (commit with Grind-PR trailer).
    run_dispatcher_capture
    head_sha=$(git -C "$sandbox" rev-parse HEAD)

    # Round 2, clean no-op shape: the dispatcher ALREADY recorded head_sha as
    # last round's commit (PRIOR_COMMIT_SHA) and re-routes a needs_more round
    # with RESULT_FIXES populated while HEAD is STILL the round-1 fix. The
    # wait branch must report "none" — reporting head_sha again would
    # double-count fix_round and exhaust --max-fix prematurely.
    prior_commit_sha="$head_sha" run_dispatcher_capture
    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.status == "success" and .result_commit_sha == "none"' >/dev/null; then
        return 0
    fi
    got_sha=$(printf '%s' "$dispatcher_json" | jq -r '.result_commit_sha // "?"' 2>/dev/null || echo "?")
    fail_test "test_668 PRIOR_COMMIT_SHA == HEAD must stay result_commit_sha=none (no double count), got $got_sha json=$dispatcher_json"
}
test_668_no_false_positive_without_grind_trailer() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # The inverse of the #668 re-invocation: a clean index with RESULT_FIXES
    # populated but NO Grind-PR commit at HEAD. History DOES carry a Grind-PR
    # commit (a previous round's fix), so the predicate must match HEAD only —
    # a history-wide grep would false-positive on the old round and mislabel
    # this wait-round as a landed fix.
    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    printf 'prev\n' > "$sandbox/prev.txt"
    git -C "$sandbox" add prev.txt
    git -C "$sandbox" commit --no-gpg-sign -qm "fix: address PR #1 feedback

previous round's landed fix

Grind-PR: 1"
    git -C "$sandbox" push -q
    printf 'current\n' > "$sandbox/file.txt"
    git -C "$sandbox" add file.txt
    git -C "$sandbox" commit --no-gpg-sign -qm "plain round commit without trailer"
    git -C "$sandbox" push -q
    run_dispatcher_capture needs_more "fix something"
    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.status == "success" and .result_commit_sha == "none"' >/dev/null; then
        return 0
    fi
    got_sha=$(printf '%s' "$dispatcher_json" | jq -r '.result_commit_sha // "?"' 2>/dev/null || echo "?")
    fail_test "test_668 clean index without a Grind-PR commit must stay result_commit_sha=none, got $got_sha json=$dispatcher_json"
}
test_n_clean_path_acks() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json before_sha after_sha
    local result_reviewer_acks
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    before_sha=$(git -C "$sandbox" rev-parse HEAD)
    result_reviewer_acks='cubic-dev-ai=abc12345,coderabbitai=none,greptile-apps=none'
    run_dispatcher_capture clean "none"
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    if printf '%s\n' "$dispatcher_json" | jq -e \
        --arg acks "$result_reviewer_acks" '.status == "success" and .result_reviewer_acks == $acks' >/dev/null &&
        [ "$after_sha" = "$before_sha" ]; then
        return 0
    fi

    fail_test "test_n clean path should inherit worker RESULT_REVIEWER_ACKS without committing/recomputing; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_n2_clean_path_missing_acks_bails() {
    # Negative: clean + RESULT_REVIEWER_ACKS absent -> dispatcher must bail (judgment),
    # not silently synthesise all-"none" defaults and declare success.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q

    # Invoke clean path WITHOUT setting result_reviewer_acks (variable unset so
    # run_dispatcher_capture omits the env var entirely — simulates worker that
    # emitted RESULT_STATUS=clean but omitted RESULT_REVIEWER_ACKS).
    unset result_reviewer_acks
    run_dispatcher_capture clean "none"

    if [ "$dispatcher_exit" -eq 1 ] && \
        printf '%s\n' "$dispatcher_json" | jq -e \
            '.bail_category == "judgment" and (.bail_reason | contains("RESULT_REVIEWER_ACKS"))' >/dev/null; then
        return 0
    fi

    fail_test "test_n2 clean path with missing RESULT_REVIEWER_ACKS should bail judgment; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_o_clean_path_preserves_tiers() {
    # ADR 0001 regression: the clean pass-through must PRESERVE the worker's
    # RESULT_ACK_TIERS verbatim so a bodyless D/E ack survives to Invariant 3 —
    # it must NOT erase the tiers to all-`none` (the bug that fail-closed-bailed
    # a legitimate clean cubic-dev-ai=<sha> tier=D ack). The wait-round path resets;
    # the clean pass-through does not.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json before_sha after_sha
    local result_reviewer_acks result_ack_tiers
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    before_sha=$(git -C "$sandbox" rev-parse HEAD)
    result_reviewer_acks='cubic-dev-ai=abc12345,coderabbitai=none,greptile-apps=none'
    result_ack_tiers='cubic-dev-ai=D,coderabbitai=none,greptile-apps=none'
    run_dispatcher_capture clean "none"
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.status == "success"
         and (.result_ack_tiers | contains("cubic-dev-ai=D"))' >/dev/null &&
        [ "$after_sha" = "$before_sha" ]; then
        return 0
    fi

    fail_test "test_o clean path must preserve worker RESULT_ACK_TIERS (cubic-dev-ai=D), not erase to none; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_p_pre_dispatch_baseline() {
    local sandbox
    local original_dir
    original_dir="$PWD"
    sandbox=$(mktemp -d)
    trap 'cd "$original_dir"; rm -rf "$sandbox"' RETURN

    cd "$sandbox"
    git init -q
    echo "a" > a.txt
    git add a.txt
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit --no-gpg-sign -qm initial
    echo "b" > b.txt
    git add b.txt

    result=$(WORKTREE_DIR="$sandbox" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
        PR_NUMBER=1 RESULT_STATUS=needs_more RESULT_FIXES="test" \
        NO_WORKTREE=1 PRE_DISPATCH_BASELINE='["b.txt"]' \
        bash "$SCRIPT" 2>&1 | tail -n 1)

    echo "$result" | jq -e '.bail_category == "judgment" and (.bail_reason | contains("clean index"))' >/dev/null
}

test_q_routing_unrecognized() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    run_dispatcher_capture unexpected_status "add test coverage"

    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.bail_category == "judgment"
         and (.bail_reason | contains("unrecognized RESULT_STATUS=unexpected_status"))' >/dev/null; then
        return 0
    fi

    fail_test "test_q unrecognized RESULT_STATUS should bail before commit; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_r_marker_validation() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    local skipped_json skipped_exit

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    litmus_mode=skipped
    run_dispatcher_capture
    skipped_json="$dispatcher_json"
    skipped_exit="$dispatcher_exit"
    rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    litmus_mode=nonhex
    run_dispatcher_capture

    [ "$skipped_exit" -eq 1 ] &&
        assert_json "$skipped_json" \
            '.bail_category == "judgment" and (.bail_reason | contains("external review marker rejected"))' &&
        [ "$dispatcher_exit" -eq 1 ] &&
        assert_json "$dispatcher_json" \
            '.bail_category == "judgment" and (.bail_reason | contains("not a valid 64-char SHA-256"))'
}

# #278: excluded-only PASS-EXCLUDED-<epoch> marker is accepted (and the diff
# committed) when the entire staged diff is review-excluded.
test_r2_excluded_only_marker_accepted() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode after_sha

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    # Reset the fixture's non-excluded staged file.txt; stage ONLY a nested
    # *.min.js (matches the hardcoded default exclusion **/*.min.js).
    git -C "$sandbox" reset -q --hard HEAD
    mkdir -p "$sandbox/pkg"
    printf 'var x=1\n' > "$sandbox/pkg/vendor.min.js"
    git -C "$sandbox" add pkg/vendor.min.js
    litmus_mode=excluded_pass
    run_dispatcher_capture
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    [[ "$dispatcher_exit" -eq 0 ]] || return 1
    # shellcheck disable=SC2310  # assert_json is a plain jq wrapper; the runner checks the return
    assert_json "$dispatcher_json" '.status == "success"' || return 1
    [[ "$after_sha" != "$initial_sha" ]]
}

# #278 no-escape: a PASS-EXCLUDED marker must NOT certify a diff that contains
# non-excluded content — the dispatcher re-verifies and bails.
test_r3_excluded_marker_rejects_nonexcluded() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    # Fixture leaves the non-excluded file.txt staged; forcing an excluded-only
    # marker must be rejected.
    litmus_mode=excluded_pass
    run_dispatcher_capture

    [[ "$dispatcher_exit" -eq 1 ]] || return 1
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("non-excluded content"))'
}

# #278/#252 no-escape: an excluded-only marker must not certify a staged
# DELETION of the (self-excluded) exclusion policy file. git ls-files would miss
# it (index-only); the pathspec --cached diff catches the deletion.
test_r5_excluded_marker_rejects_policy_deletion() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    git -C "$sandbox" reset -q --hard HEAD
    # Commit a policy that excludes ITSELF (so its own churn is filtered out of
    # the non-excluded check and only the #252 policy guard can catch it).
    mkdir -p "$sandbox/.claude"
    printf '.claude/review-exclude\n**/*.min.js\n' > "$sandbox/.claude/review-exclude"
    git -C "$sandbox" add .claude/review-exclude
    git -C "$sandbox" commit --no-gpg-sign -qm "add self-excluding review policy"
    # Stage its DELETION (--cached keeps the worktree copy so build_exclude_args
    # still reads the self-exclusion pattern), plus an excluded min.js.
    git -C "$sandbox" rm -q --cached .claude/review-exclude
    mkdir -p "$sandbox/pkg"; printf 'var x=1\n' > "$sandbox/pkg/vendor.min.js"
    git -C "$sandbox" add pkg/vendor.min.js
    litmus_mode=excluded_pass
    run_dispatcher_capture

    [[ "$dispatcher_exit" -eq 1 ]] || return 1
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("exclusion policy"))'
}
# #281 no-escape: an excluded-only marker must not be trusted when a policy path
# COMPONENT (.claude) is a committed gitlink/submodule (mode 160000). A gitlink is
# not a symlink, so the -L guard misses it; and `git status -- .claude/review-exclude`
# does not descend into a submodule (its dirty bytes surface only as `M .claude`),
# so the committed-clean check is blind to divergent review-exclude bytes read
# through it. The dispatcher must reject the gitlink component outright, before the
# (blind) committed-clean status check.
test_r6_excluded_marker_rejects_gitlink_policy_component() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    git -C "$sandbox" reset -q --hard HEAD
    # Commit .claude as a GITLINK (mode 160000) instead of a normal tree. Git cannot
    # hold both a gitlink at .claude AND a tracked child under it, so clear any
    # indexed .claude/* first — the current fixture tracks only file.txt, but this
    # keeps the setup correct if the fixture ever starts tracking .claude/*.
    git -C "$sandbox" rm -r -q --cached --ignore-unmatch .claude 2>/dev/null || true
    mkdir -p "$sandbox/.claude"
    # Physical review-exclude stays present (untracked inside the gitlink dir) so
    # build_exclude_args COULD still read it — but the guard must bail before that.
    # cacheinfo needs a real object sha; initial_sha is a committed sha in-repo.
    printf '.claude/review-exclude\n**/*.min.js\n' > "$sandbox/.claude/review-exclude"
    git -C "$sandbox" update-index --add --cacheinfo "160000,$initial_sha,.claude"
    git -C "$sandbox" commit --no-gpg-sign -qm "add .claude gitlink"
    # Stage an excluded-only diff so nothing else bails first.
    mkdir -p "$sandbox/pkg"; printf 'var x=1\n' > "$sandbox/pkg/vendor.min.js"
    git -C "$sandbox" add pkg/vendor.min.js
    litmus_mode=excluded_pass
    run_dispatcher_capture

    [[ "$dispatcher_exit" -eq 1 ]] || return 1
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("gitlink"))'
}
# #282 no-false-positive: a NORMAL directory prefix (.claude) that contains a
# gitlink DESCENDANT sorted before review-exclude must NOT be treated as a gitlink.
# The exact-match probe ($2==prefix) looks for an index entry whose path IS the
# prefix; a normal dir has only descendant entries, so it never matches 160000.
# (A first-row `ls-files` read would wrongly pick the submodule child's mode.)
test_r7_gitlink_sibling_does_not_false_positive() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode after_sha

    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN
    git -C "$sandbox" reset -q --hard HEAD
    # .claude stays a NORMAL dir: commit a self-excluding review-exclude AND a gitlink
    # SIBLING (.claude/aaa-sub, mode 160000) whose path sorts BEFORE review-exclude,
    # so a first-row ls-files read would see 160000 and falsely bail. update-index
    # cacheinfo needs a real object sha; initial_sha is a committed sha in-repo.
    mkdir -p "$sandbox/.claude"
    printf '.claude/review-exclude\n**/*.min.js\n' > "$sandbox/.claude/review-exclude"
    git -C "$sandbox" add .claude/review-exclude
    git -C "$sandbox" update-index --add --cacheinfo "160000,$initial_sha,.claude/aaa-sub"
    git -C "$sandbox" commit --no-gpg-sign -qm "normal .claude with gitlink sibling"
    # Excluded-only staged diff → must PASS (no false gitlink bail on the .claude dir).
    mkdir -p "$sandbox/pkg"; printf 'var x=1\n' > "$sandbox/pkg/vendor.min.js"
    git -C "$sandbox" add pkg/vendor.min.js
    litmus_mode=excluded_pass
    run_dispatcher_capture
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    [[ "$dispatcher_exit" -eq 0 ]] || return 1
    # shellcheck disable=SC2310
    assert_json "$dispatcher_json" '.status == "success"' || return 1
    [[ "$after_sha" != "$initial_sha" ]]
}
test_s_bail_envelope_roundtrip() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode bail_json empty_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=review_findings
    run_dispatcher_capture

    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/lib/bail-envelope.sh"
    bail_json=$(printf '%s\n' "$dispatcher_output" | parse_bail_envelope)
    empty_json=$(printf '%s\n' 'no envelope here' | parse_bail_envelope)

    [ "$dispatcher_exit" -eq 1 ] &&
        [ "$bail_json" = "$dispatcher_json" ] &&
        [ -z "$empty_json" ] &&
        assert_json "$bail_json" \
            '.bail_category == "judgment" and (.bail_reason | contains("review_findings"))'
}
test_t_terminal_status_preferred() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=terminal_preferred
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_t expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment"
         and (.bail_reason | contains("litmus exit 1 (stall)"))
         and (.bail_reason | contains("max_iterations") | not)'
}
test_u_no_orphaned_commit_on_env_bail() {
    # Regression for #114: when commitlint is missing AND
    # BUSDRIVER_ALLOW_NO_COMMITLINT is not set to "1" (the harness passes "0"
    # in this test, matching the dispatcher's `!= "1"` predicate), the env-bail
    # MUST fire BEFORE `git commit`. The pre-fix order (commit then validate)
    # left an orphaned local commit when this path bailed; a subsequent retry
    # with the bypass set would see no staged changes and take the wait-round
    # path, missing the orphaned commit entirely.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json allow_no_commitlint
    local post_bail_head
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Simulate "commitlint binary unavailable": npx exists on PATH but
    # `npx --no-install commitlint --version` exits non-zero — the dispatcher
    # treats this as the unavailable branch and gates on BUSDRIVER_ALLOW_NO_COMMITLINT.
    cat > "$shimdir/npx" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$shimdir/npx"

    allow_no_commitlint=0
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_u expected dispatcher bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "env"
         and (.bail_reason | contains("commitlint unavailable"))' || {
        echo "test_u dispatcher_json: $dispatcher_json"
        return 1
    }

    # The regression assertion: HEAD must equal initial_sha — no orphaned commit.
    post_bail_head=$(git -C "$sandbox" rev-parse HEAD)
    [ "$post_bail_head" = "$initial_sha" ] || {
        echo "test_u expected HEAD unchanged after env-bail; initial=$initial_sha post=$post_bail_head"
        return 1
    }
}

# --- #569: stale litmus state must not wedge the block ---

# test_v: a state file left behind by an EARLIER non-PASS review (active: true) is
# stale by construction once no reviewer is running. The block must discard it and
# proceed, not bail "litmus init-review-loop.sh failed" on every later invocation.
test_v_stale_litmus_state_is_forced() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json init_event_log
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    init_event_log="$sandbox/init-events.log"
    mkdir -p "$sandbox/.claude"
    printf 'active: true\nreview_status: "FAIL"\nterminal_status: review_findings\n' \
        > "$sandbox/.claude/litmus-state.md"

    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_v expected success despite stale state; output: $dispatcher_output"
        return 1
    }
    grep -q -- '--force' "$init_event_log" || {
        echo "test_v expected init-review-loop.sh --force; log: $(cat "$init_event_log")"
        return 1
    }
}

# test_x: a FAIL bail must carry the findings. "operator must address them manually"
# with no findings attached pointed at nothing — litmus keeps no parseable copy.
test_x_review_findings_bail_carries_findings() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    litmus_mode=review_findings
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_x expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment"
         and (.bail_reason | contains("review_findings"))
         and (.bail_reason | contains("[high] scripts/foo.sh:42"))
         and (.bail_reason | contains("[medium] scripts/foo.sh:88"))' || {
        echo "test_x dispatcher_json: $dispatcher_json"
        return 1
    }
}

# test_ab: an active state file with NO terminal_status is a review that was killed
# before it could record one — or, the case that matters, an interactive /litmus that
# has run init and not yet run the loop. There is no process for pgrep to see, so
# forcing here would erase a review somebody is about to run.
test_ab_active_without_terminal_status_bails() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Exactly what init-review-loop.sh writes before run-review-loop.sh is invoked.
    mkdir -p "$sandbox/.claude"
    printf 'active: true\niteration: 1\nreview_mode: "commit"\nreview_status: "PENDING"\n' \
        > "$sandbox/.claude/litmus-state.md"

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_ab expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("no recognized terminal_status"))' || {
        echo "test_ab dispatcher_json: $dispatcher_json"
        return 1
    }
    # The lock must not be left behind by the bail — that would wedge the next round.
    # -L, and the real path. `litmus-dispatch.lock` was the name of a deleted mkdir-based
    # draft, so this assertion used to check a path that never exists and passed
    # unconditionally. And -e follows the link: the lock is DELIBERATELY a dangling
    # symlink (target "pid-<n>" names no file), so -e reports false while the symlink is
    # still sitting there. Only -L sees it.
    [ ! -L "$sandbox/.claude/litmus-review.lock" ] || {
        echo "test_ab: lock leaked on bail"
        return 1
    }
}

# test_ac: an unrecognized terminal_status value is not evidence a run finished.
# Matching on the mere PRESENCE of a `terminal_status:` line would let empty, null, or
# corrupted state authorize --force — a fail-open on the one check standing between
# this script and overwriting a live review.
test_ac_unrecognized_terminal_status_bails() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    mkdir -p "$sandbox/.claude"
    printf 'active: true\nreview_status: "PENDING"\nterminal_status: ""\n' \
        > "$sandbox/.claude/litmus-state.md"

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_ac expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("no recognized terminal_status"))' || {
        echo "test_ac dispatcher_json: $dispatcher_json"
        return 1
    }
}

# test_ad: --force exists only to override the active-state guard, so it must not be
# reached when that guard never fires. On the common path (no state file) the plain
# init succeeds and no force is involved — which is what keeps the force's overwrite
# window off every ordinary round.
test_ad_no_force_when_plain_init_succeeds() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json init_event_log
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    init_event_log="$sandbox/init-events.log"
    # No pre-existing state file: init-review-loop.sh has nothing to refuse over.

    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_ad expected success; output: $dispatcher_output"
        return 1
    }
    if grep -q -- '--force' "$init_event_log"; then
        echo "test_ad: --force used even though the plain init succeeded"
        cat "$init_event_log"
        return 1
    fi
}

# test_ae: a review lock held by a LIVE owner must stop the dispatcher before it
# classifies anything. This is what makes the terminal_status read meaningful — without
# it the classification is check-then-act and can be invalidated before the force lands.
test_ae_live_review_lock_bails() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json holder_pid
    make_dispatcher_fixture
    holder_pid=""
    trap 'kill "$holder_pid" 2>/dev/null || true; cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    sleep 60 &
    holder_pid=$!
    mkdir -p "$sandbox/.claude"
    ln -s "pid-$holder_pid" "$sandbox/.claude/litmus-review.lock"

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_ae expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    # "(running)" with the parens, not "running": the orphan message says "not running",
    # which contains it — a loose match here would pass on the wrong branch entirely.
    assert_json "$dispatcher_json" \
        '.bail_category == "env" and (.bail_reason | contains("(running)"))' || {
        echo "test_ae dispatcher_json: $dispatcher_json"
        return 1
    }
    # A live owner's lock must survive our bail — releasing only ever unlinks our own.
    [ -L "$sandbox/.claude/litmus-review.lock" ] || {
        echo "test_ae: bail released a lock it does not own"
        return 1
    }
}

# test_af: a lock orphaned by a SIGKILLed run is NOT auto-reclaimed — no shell reclaim
# is race-free (see lib/review-lock.sh), so the block bails and names the remedy rather
# than racing for it. The bail must also leave the orphan in place: a reclaim disguised
# as cleanup is the same race by another name.
test_af_orphaned_review_lock_bails_with_remedy() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json dead_pid _candidate
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # A REAPED pid is not a guaranteed-dead value — the OS can hand it to a brand-new
    # process before this test's assertions run, and on a busy host that reports a
    # lock-implementation defect that does not exist. Search for a pid that fails
    # `kill -0` instead.
    dead_pid=""
    for _candidate in 999999 999998 999997 999996 999995; do
        if ! kill -0 "$_candidate" 2>/dev/null; then
            dead_pid="$_candidate"
            break
        fi
    done
    if [ -z "$dead_pid" ]; then
        echo "test_af: SKIP — could not find a pid that fails kill -0"
        return 0
    fi

    mkdir -p "$sandbox/.claude"
    ln -s "pid-$dead_pid" "$sandbox/.claude/litmus-review.lock"

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_af expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "env"
         and (.bail_reason | contains("not running"))
         and (.bail_reason | contains("orphan"))' || {
        echo "test_af dispatcher_json: $dispatcher_json"
        return 1
    }
    [ -L "$sandbox/.claude/litmus-review.lock" ] || {
        echo "test_af: bail removed the orphan instead of reporting it"
        return 1
    }
}

# test_ag: BUSDRIVER_STATE_DIR is repo-injectable. The dispatcher must normalize it with
# the same rule run-review-loop.sh uses — if they disagree, this script classifies and
# initializes one state file while the reviewer consumes another.
test_ag_unsafe_state_dir_normalized() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json escape_dir escape_parent
    make_dispatcher_fixture
    # `../escape` resolves against the sandbox's PARENT, and `mktemp -d` puts the sandbox
    # straight into the shared TMPDIR — so the escape target would be a FIXED path
    # (/tmp/escape) this test can neither own nor safely clean. Snapshotting its
    # pre-existence does NOT fix that: another process can create the path after the
    # snapshot and still lose its data to the RETURN trap's `rm -rf`, and no probe can
    # close a race whose whole problem is that the path is shared.
    #
    # So don't share it. Re-root the sandbox under a private mktemp parent, and the
    # traversal lands somewhere only this test can reach — ownership by construction,
    # no snapshot, no conditional assertion, and a cleanup that can only ever delete
    # this test's own tree. `WORKTREE_DIR` is read from `$sandbox` at capture time and
    # the origin remote is an absolute path elsewhere, so the move is invisible to the
    # dispatcher.
    escape_parent=$(mktemp -d)
    mv "$sandbox" "$escape_parent/repo"
    sandbox="$escape_parent/repo"
    escape_dir="$escape_parent/escape"
    trap 'cd "$original_dir"; rm -rf "$escape_parent" "$plugin_root" "$shimdir" "$remote"' RETURN

    # A traversal value. Both sides must collapse it to `.claude`; the marker the
    # reviewer writes there is what the dispatcher then has to find.
    export BUSDRIVER_STATE_DIR="../escape"
    run_dispatcher_capture
    unset BUSDRIVER_STATE_DIR

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_ag expected success with normalized state dir; output: $dispatcher_output"
        return 1
    }
    # Unconditional — the private parent means nothing but this run can put anything
    # here. `-L` as well as `-e`, because `-e` follows symlinks and would read a
    # dangling one as absent.
    if [ -e "$escape_dir" ] || [ -L "$escape_dir" ]; then
        echo "test_ag: traversal state dir was honoured — created $escape_dir"
        return 1
    fi
}

# test_ah: classify → init → review must be ONE transaction. The block holds the lock
# across all of it and hands ownership to the reviewer by export, rather than releasing
# and letting it re-acquire — a release would open a window for another invocation to
# take the lock and replace the state just initialized.
test_ah_lock_held_through_review() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json lock_probe
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    lock_probe="$sandbox/lock-during-review.txt"
    # Record the lock as the REVIEWER sees it — i.e. mid-transaction.
    cat > "$plugin_root/skills/litmus/scripts/run-review-loop.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'owner=%s\n' "\$(readlink .claude/litmus-review.lock 2>/dev/null || echo NONE)"
  printf 'exported=%s\n' "\${BUSDRIVER_REVIEW_LOCK_OWNER:-NONE}"
} > "$lock_probe"
mkdir -p .claude
# Same shape as the default fixture above (and as staged-diff-hash.sh): pick the hash
# utility with \`command -v\` rather than a \`sha256sum || shasum\` pipe. pre-pr-gate.sh
# rejects that pipe outright — a partially-consuming failure hashes only the remainder
# and collapses distinct diffs onto one digest — so a fixture guarding marker binding
# must not itself be built out of it (CodeRabbit, PR #795).
if command -v sha256sum >/dev/null 2>&1; then
  git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none | sha256sum | cut -d' ' -f1 > .claude/litmus-passed.local
else
  git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none | shasum -a 256 | cut -d' ' -f1 > .claude/litmus-passed.local
fi
EOF
    chmod +x "$plugin_root/skills/litmus/scripts/run-review-loop.sh"

    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_ah expected success; output: $dispatcher_output"
        return 1
    }
    # Compare the two recorded VALUES rather than grepping for patterns. `grep -qv
    # 'exported=NONE'` on this two-line probe always succeeded — the `owner=` line
    # satisfies the inverted match regardless of what `exported=` says — so the
    # handoff could break silently. Extract both and require they name the same pid.
    local probe_owner probe_exported
    probe_owner=$(sed -n 's/^owner=//p' "$lock_probe")
    probe_exported=$(sed -n 's/^exported=//p' "$lock_probe")
    [ -n "$probe_owner" ] || {
        echo "test_ah: lock was not held while the reviewer ran"
        cat "$lock_probe"
        return 1
    }
    [ "$probe_exported" = "$probe_owner" ] || {
        echo "test_ah: exported owner '$probe_exported' != lock owner '$probe_owner'"
        cat "$lock_probe"
        return 1
    }
    # And it must be released once the block exits. -L, not -e: the lock is a dangling
    # symlink by design, so -e follows the missing target and reports false even while
    # the link remains — an assertion that cannot fail is not an assertion.
    [ ! -L "$sandbox/.claude/litmus-review.lock" ] || {
        echo "test_ah: lock survived the block's exit"
        return 1
    }
}

# test_ai: --force is the documented answer to exactly ONE refusal — the active-state
# guard. When init fails for any other reason (not a git repo, bad args, unwritable
# state dir) there is no active state to explain it, and forcing would paper over the
# real error with an unrelated remedy.
test_ai_no_force_when_state_does_not_explain_failure() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json init_event_log init_always_fails
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    init_event_log="$sandbox/init-events.log"
    init_always_fails=1
    # No state file at all: nothing here is an active-state refusal.

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_ai expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("does not explain"))' || {
        echo "test_ai dispatcher_json: $dispatcher_json"
        return 1
    }
    if grep -q -- '--force' "$init_event_log"; then
        echo "test_ai: --force attempted against a failure it cannot remedy"
        cat "$init_event_log"
        return 1
    fi
}

# test_aj: trailing garbage must not parse as a valid state. A value expression ending
# in `.*$` swallows it — `terminal_status: "review_findings"x` reads as the recognized
# value and authorizes --force against state that is by definition malformed.
test_aj_trailing_garbage_is_not_valid_state() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json init_event_log init_always_fails
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    init_event_log="$sandbox/init-events.log"
    # The plain init must REFUSE, or the classification block is never reached and this
    # asserts nothing — the stub's own `^active: true` match does not fire on the
    # malformed line below, which is exactly why the first draft of this test passed
    # against a parser that accepted the garbage.
    init_always_fails=1
    mkdir -p "$sandbox/.claude"
    # Three malformations that each defeated a different parser generation:
    #   1. valid line FOLLOWED by a malformed duplicate — filtering-then-tail skips the
    #      garbage and resurrects the earlier valid value, though last-key-wins makes
    #      the garbage the one in effect;
    #   2. trailing content — a value expression ending in `.*$` swallows it;
    #   3. unbalanced quotes — `"?…"?` accepts them, the two quotes being independent.
    {
        printf 'active: true\n'
        printf 'terminal_status: review_findings\n'
        printf 'active: "true"JUNK\n'
        printf 'terminal_status: "review_findings"JUNK\n'
        printf 'active: "true\n'
        printf 'terminal_status: review_findings"\n'
    } > "$sandbox/.claude/litmus-state.md"

    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_aj expected bail on malformed state, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    # A lax parser reads these as active=true / terminal=review_findings and runs
    # --force; the strict one yields empty values and bails as unexplained.
    assert_json "$dispatcher_json" \
        '.bail_category == "judgment" and (.bail_reason | contains("does not explain"))' || {
        echo "test_aj dispatcher_json: $dispatcher_json"
        return 1
    }
    if grep -q -- '--force' "$init_event_log"; then
        echo "test_aj: --force authorized by malformed state"
        cat "$init_event_log"
        return 1
    fi
}

# test_ak: the lock is held for the LIFETIME of the review, including under a signal.
# If TERM reaches only the dispatcher, a foreground reviewer keeps writing
# litmus-state.md while the EXIT trap drops the lock — and the next invocation acquires
# one that guards nothing. The reviewer must be stopped before the lock is released.
test_ak_signal_stops_reviewer_before_releasing_lock() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_pid child_pid_file grandchild_pid_file waited child_pid grandchild_pid
    local dispatcher_status
    make_dispatcher_fixture
    dispatcher_pid=""
    # KILL, not TERM: these fixtures ignore TERM on purpose, so a TERM-based cleanup
    # would leave them running for their full sleep and bleed into later tests. Routed
    # through a function that always returns 0 — a RETURN trap ending on a failed kill
    # (already-dead pid) propagates under `set -e` and aborts the entire suite.
    _ak_cleanup() {
        local f pid
        if [ -n "$dispatcher_pid" ]; then
            kill -KILL "$dispatcher_pid" 2>/dev/null || true
        fi
        for f in "$sandbox/child.pid" "$sandbox/grandchild.pid"; do
            [ -s "$f" ] || continue
            pid=$(cat "$f" 2>/dev/null) || continue
            if [ -n "$pid" ]; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        cd "$original_dir" || return 0
        rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"
        return 0
    }
    trap '_ak_cleanup' RETURN

    child_pid_file="$sandbox/child.pid"
    grandchild_pid_file="$sandbox/grandchild.pid"
    # Assert on LIVENESS, not on a marker a slow child would not have written yet
    # either — a timing window that cannot distinguish the two outcomes proves nothing.
    # INIT is the child under test, not the reviewer: it runs first, and covering only
    # the reviewer is precisely the gap that shipped last round.
    # The grandchild stands in for codex/git, which a kill of the immediate shell alone
    # leaves running. All three assertions discriminate: reverting a call site to
    # foreground kills the first, swapping the group kill for a bare-pid kill kills the
    # grandchild check, and dropping the release kills the third.
    #
    # NOT covered here: a signal recorded after a fast child has already exited, where
    # the PGID probe fails for "already gone" rather than "no group". The handler
    # distinguishes those via a liveness snapshot taken before it signals; staging it
    # needs the signal to land inside a window this fixture cannot open deterministically
    # (it deliberately keeps the child alive). The neighbouring invariant IS covered —
    # test_ah asserts a clean run leaves no lock behind.
    #
    # The grandchild check was inert until the SIG_IGN inheritance bug was fixed —
    # `trap '' SIG` left the child with TERM ignored, so it ran to completion and
    # everything looked dead by the time the unbounded wait returned. Two defects
    # hiding each other is the reason the wait below is bounded.
    # The grandchild IGNORES TERM. `wait` covers only the direct child, so a descendant
    # that refuses to die outlives it — and without escalation the lock is released
    # while it is still running. This is the shape of a real reviewer: codex and git
    # both install their own signal handling.
    # BOTH the direct child and the grandchild ignore TERM. Only the grandchild ignoring
    # it left the direct child dying promptly, so a blocking `wait` on it still
    # returned — and an unbounded wait against a TERM-ignoring DIRECT child (which hangs
    # the dispatcher forever holding the lock) went unnoticed.
    cat > "$plugin_root/skills/litmus/scripts/init-review-loop.sh" <<EOF
#!/usr/bin/env bash
trap "" TERM
bash -c 'trap "" TERM; sleep 30' &
echo \$! > "$grandchild_pid_file"
echo \$\$ > "$child_pid_file"
wait
EOF
    chmod +x "$plugin_root/skills/litmus/scripts/init-review-loop.sh"

    env "PATH=$shimdir:$PATH" "WORKTREE_DIR=$sandbox" "CLAUDE_PLUGIN_ROOT=$plugin_root" \
        "PR_NUMBER=1" "RESULT_STATUS=needs_more" "RESULT_FIXES=signal test" \
        "BUSDRIVER_ALLOW_NO_COMMITLINT=1" \
        bash "$SCRIPT" >/dev/null 2>&1 &
    dispatcher_pid=$!

    waited=0
    until [ -s "$child_pid_file" ] && [ -s "$grandchild_pid_file" ]; do
        sleep 0.2
        waited=$((waited + 1))
        [ "$waited" -lt 50 ] || { echo "test_ak: init child never started"; return 1; }
    done
    child_pid=$(cat "$child_pid_file")
    grandchild_pid=$(cat "$grandchild_pid_file")

    # HUP, not INT: a non-interactive shell sets SIGINT to IGNORE for background jobs,
    # and a signal ignored at entry cannot be trapped — so an INT here would test
    # nothing. HUP carries no such rule and exercises the non-default exit mapping.
    kill -HUP "$dispatcher_pid" 2>/dev/null || true
    # BOUNDED wait. An unbounded `wait` blocks until the dispatcher exits — which, if
    # the signal never reached the child, means waiting out the child's natural
    # completion and then finding everything dead. The test would then pass on a
    # timeout rather than on the behaviour under test, which is how the SIG_IGN
    # inheritance bug slipped through this very test.
    waited=0
    while kill -0 "$dispatcher_pid" 2>/dev/null; do
        sleep 0.2
        waited=$((waited + 1))
        [ "$waited" -lt 60 ] || {
            echo "test_ak: dispatcher still alive 12s after HUP — the signal did not take"
            kill -KILL "$dispatcher_pid" 2>/dev/null || true
            return 1
        }
    done
    dispatcher_status=0
    wait "$dispatcher_pid" 2>/dev/null || dispatcher_status=$?
    dispatcher_pid=""
    sleep 0.3
    # 128+SIGHUP (129), not a blanket 143 — an exit status that names the wrong
    # signal misleads whoever reads it.
    [ "$dispatcher_status" = "129" ] || {
        echo "test_ak: expected exit 129 for SIGHUP, got $dispatcher_status"
        return 1
    }

    kill -0 "$child_pid" 2>/dev/null && {
        echo "test_ak: init child (pid $child_pid) outlived the signalled dispatcher"
        kill -KILL "$child_pid" 2>/dev/null || true
        return 1
    }
    kill -0 "$grandchild_pid" 2>/dev/null && {
        echo "test_ak: GRANDCHILD (pid $grandchild_pid) survived — the kill reached only the immediate shell"
        kill -KILL "$grandchild_pid" 2>/dev/null || true
        return 1
    }
    [ ! -L "$sandbox/.claude/litmus-review.lock" ] || {
        echo "test_ak: lock still held after the dispatcher exited"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Rail A - durable grind provenance (ADR 0036). The dispatcher commit block is
# the sole commit path, so it is the only place the Grind-PR: trailer can be
# stamped and the only place its survival through the repo's hooks can be
# verified.
# ---------------------------------------------------------------------------

GRIND_HELPER="$REPO_ROOT/scripts/grind-pr-commits.sh"

# A commit-msg hook that mangles the trailer. $1 is the message file.
write_commit_msg_hook() {
    local body="$1"
    cat > "$sandbox/.git/hooks/commit-msg" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$sandbox/.git/hooks/commit-msg"
}

test_grind_a_trailer_parses_as_a_real_trailer() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json parsed
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Multi-line RESULT_FIXES is the shape that makes a bare append land inside
    # the body paragraph, where git's trailer-ratio rule stops recognizing it.
    # A grep substring check cannot detect that; only the parser can.
    run_dispatcher_capture needs_more $'fixed the parser\nalso fixed the guard\nand the retry path'

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_grind_a dispatcher output: $dispatcher_output"
        return 1
    }
    parsed=$(git -C "$sandbox" log -1 --format='%(trailers:key=Grind-PR,valueonly=true)')
    [ "$parsed" = "1" ] || {
        echo "test_grind_a: Grind-PR did not parse as a trailer (got '$parsed')"
        git -C "$sandbox" log -1 --format=%B
        return 1
    }
}

test_grind_b_trailer_parses_on_the_litmus_autofix_path() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode parsed message
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # The litmus path appends Litmus-Auto-Fix: with its own blank separator, so
    # this fixture exercises the other of the two message shapes.
    litmus_mode=autofix_inplace
    run_dispatcher_capture needs_more $'fixed one thing\nfixed another'

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_grind_b dispatcher output: $dispatcher_output"
        return 1
    }
    message=$(git -C "$sandbox" log -1 --format=%B)
    printf '%s\n' "$message" | grep -q 'Litmus-Auto-Fix:' || {
        echo "test_grind_b: fixture did not take the litmus path"
        return 1
    }
    parsed=$(git -C "$sandbox" log -1 --format='%(trailers:key=Grind-PR,valueonly=true)')
    [ "$parsed" = "1" ] || {
        echo "test_grind_b: Grind-PR did not parse as a trailer (got '$parsed')"
        printf '%s\n' "$message"
        return 1
    }
}

test_grind_c_real_commit_message_is_selected_by_the_scanner() {
    # THE acceptance test for durable provenance: the only assertion that the
    # writer (this script's composition path) and the reader
    # (grind-pr-commits.sh) agree on one contract rather than two that merely
    # look alike. Run in both message shapes.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json litmus_mode
    local head_sha scanned
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    run_dispatcher_capture needs_more $'first fix\nsecond fix'
    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_grind_c (no-litmus) output: $dispatcher_output"
        return 1
    }
    head_sha=$(git -C "$sandbox" rev-parse HEAD)
    scanned=$(bash "$GRIND_HELPER" -C "$sandbox" 1 "$initial_sha" "$head_sha") || {
        echo "test_grind_c: scanner exited non-zero"
        return 1
    }
    printf '%s\n' "$scanned" | grep -qxF "$head_sha" || {
        echo "test_grind_c: scanner did not select the no-litmus commit"
        git -C "$sandbox" log -1 --format=%B
        return 1
    }

    # Second round, litmus shape, on top of the first.
    printf 'changed again\n' > "$sandbox/file.txt"
    git -C "$sandbox" add file.txt
    litmus_mode=autofix_inplace
    run_dispatcher_capture needs_more $'third fix\nfourth fix'
    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_grind_c (litmus) output: $dispatcher_output"
        return 1
    }
    head_sha=$(git -C "$sandbox" rev-parse HEAD)
    scanned=$(bash "$GRIND_HELPER" -C "$sandbox" 1 "$initial_sha" "$head_sha") || {
        echo "test_grind_c: scanner exited non-zero on round 2"
        return 1
    }
    printf '%s\n' "$scanned" | grep -qxF "$head_sha" || {
        echo "test_grind_c: scanner did not select the litmus-path commit"
        git -C "$sandbox" log -1 --format=%B
        return 1
    }
    [ "$(printf '%s\n' "$scanned" | wc -l | tr -d ' ')" = "2" ] || {
        echo "test_grind_c: expected both grind commits in the set, got: $scanned"
        return 1
    }
}

test_grind_d_trailer_deleted_by_hook_emits_env_bail() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    write_commit_msg_hook 'grep -v "^Grind-PR:" "$1" > "$1.tmp" && mv "$1.tmp" "$1"'
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_grind_d expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    # Assert a PARSEABLE envelope, not merely a non-zero exit: errexit is armed
    # at the verification point, so a bare pipeline would kill the script and
    # produce exit 1 with no envelope - which a status-only assertion would
    # happily accept.
    assert_json "$dispatcher_json" '.bail_category == "env"' || {
        echo "test_grind_d: no parseable env bail envelope; output=$dispatcher_output"
        return 1
    }
}

test_grind_e_trailer_normalized_by_hook_emits_env_bail() {
    # The silent fail-open this check exists for: 'grind-pr:1' PASSES git's
    # trailer parser (returns 1) and is matched ZERO times by the scanner.
    # Without this test the verification is parser-only and fails open.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json new_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    write_commit_msg_hook \
        'sed "s/^Grind-PR: \([0-9]*\)$/grind-pr:\1/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"'
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_grind_e expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" '.bail_category == "env"' || {
        echo "test_grind_e: no parseable env bail envelope; output=$dispatcher_output"
        return 1
    }
    # Confirm the fixture really did produce the parser-passing/scanner-missing
    # form - otherwise this test would pass for the wrong reason.
    new_sha=$(git -C "$sandbox" rev-parse HEAD)
    [ "$(git -C "$sandbox" log -1 --format='%(trailers:key=Grind-PR,valueonly=true)' "$new_sha")" = "1" ] || {
        echo "test_grind_e: fixture did not produce a parser-passing normalized trailer"
        return 1
    }
    # ...and that the scanner's trailer predicate misses it. Asserted against
    # arm 1 specifically, not the whole helper: the transitional subject arm
    # legitimately still selects this commit by its `fix: address PR #1
    # feedback` subject, which is exactly why the durability guarantee cannot
    # rest on the subject and why the trailer must be verified at write time.
    [ -z "$(git -C "$sandbox" rev-list --grep='^Grind-PR: 1$' "$initial_sha..$new_sha")" ] || {
        echo "test_grind_e: the trailer scan unexpectedly matched the normalized form"
        return 1
    }
}

test_grind_e2_body_moved_trailer_emits_env_bail() {
    # The two-different-occurrences bypass: a hook that MOVES `Grind-PR: N` into
    # the body and appends `grind-pr:N` as the real trailer satisfies both an
    # exact-bytes-anywhere-in-%B check AND a case-insensitive parsed-key check,
    # while the scanner - which requires the exact line inside the parsed trailer
    # block - matches it zero times. Verification must bind on the scanner's
    # predicate, so this has to BAIL.
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json new_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Strip the real trailer, re-insert the EXACT line mid-body (followed by
    # prose so it is not the final paragraph), then append a normalized trailer.
    write_commit_msg_hook '
grep -v "^Grind-PR: " "$1" > "$1.tmp"
printf "\nGrind-PR: 1\n" >> "$1.tmp"
printf "trailing prose keeps the line out of the trailer block\n" >> "$1.tmp"
printf "\ngrind-pr:1\n" >> "$1.tmp"
mv "$1.tmp" "$1"'
    run_dispatcher_capture

    [ "$dispatcher_exit" -eq 1 ] || {
        echo "test_grind_e2 expected bail, exit=$dispatcher_exit output=$dispatcher_output"
        return 1
    }
    assert_json "$dispatcher_json" '.bail_category == "env"' || {
        echo "test_grind_e2: no parseable env bail envelope; output=$dispatcher_output"
        return 1
    }
    # Confirm the fixture really produced the bypass shape, not just any failure.
    # Both halves of the bypass must be present, or this test passes for the
    # wrong reason: the EXACT line lives in %B, and the parsed trailer block
    # contains only the normalized form.
    new_sha=$(git -C "$sandbox" rev-parse HEAD)
    git -C "$sandbox" log -1 --format=%B "$new_sha" | grep -qx 'Grind-PR: 1' || {
        echo "test_grind_e2: fixture lacks the exact line in the body"
        git -C "$sandbox" log -1 --format=%B "$new_sha"
        return 1
    }
    # Accept either rendering. Measured on git 2.55.0 the raw bytes are
    # preserved (`grind-pr:1`), but the fixture's job is only to confirm the
    # block holds the NORMALIZED key rather than the exact line - pinning the
    # spacing would make this test a hostage to a formatting detail it is not
    # about.
    git -C "$sandbox" log -1 --format='%(trailers)' "$new_sha" \
        | grep -qxE 'grind-pr: ?1' || {
        echo "test_grind_e2: fixture lacks the normalized trailer in the block"
        git -C "$sandbox" log -1 --format='%(trailers)' "$new_sha"
        return 1
    }
    [ "$(git -C "$remote" rev-parse main)" = "$initial_sha" ] || {
        echo "test_grind_e2: the unattributable commit reached the remote"
        return 1
    }
}

test_grind_f_verification_bail_names_unpushed_commit() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json new_sha reason
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    write_commit_msg_hook 'grep -v "^Grind-PR:" "$1" > "$1.tmp" && mv "$1.tmp" "$1"'
    run_dispatcher_capture

    new_sha=$(git -C "$sandbox" rev-parse HEAD)
    reason=$(printf '%s\n' "$dispatcher_json" | jq -r '.bail_reason // ""')

    # The recovery contract: the operator must be able to act on the message
    # alone. It names the SHA, the local-unpushed state, and the cause.
    case "$reason" in
        *"$new_sha"*) : ;;
        *) echo "test_grind_f: bail_reason omits the commit SHA: $reason"; return 1 ;;
    esac
    case "$reason" in
        *UNPUSHED*) : ;;
        *) echo "test_grind_f: bail_reason omits the unpushed state: $reason"; return 1 ;;
    esac
    case "$reason" in
        *commit-msg*) : ;;
        *) echo "test_grind_f: bail_reason omits the cause: $reason"; return 1 ;;
    esac

    # And the commit really is unpushed - the BAIL fires before Step 11.
    [ "$new_sha" != "$initial_sha" ] || {
        echo "test_grind_f: fixture never committed"; return 1; }
    [ "$(git -C "$remote" rev-parse main)" = "$initial_sha" ] || {
        echo "test_grind_f: the malformed commit reached the remote"
        return 1
    }
}

test_grind_g_non_numeric_pr_number_rejected() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json pr_number bad
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # ':57' checked non-emptiness only. '0617' is the dangerous one: it would
    # stamp a trailer that a later '617' scan silently misses.
    for bad in "abc" "0617" "0" "61a" "-1"; do
        pr_number="$bad"
        run_dispatcher_capture
        [ "$dispatcher_exit" -eq 1 ] || {
            echo "test_grind_g: PR '$bad' was accepted (exit $dispatcher_exit)"
            return 1
        }
        assert_json "$dispatcher_json" \
            '.bail_category == "env" and (.bail_reason | contains("PR_NUMBER"))' || {
            echo "test_grind_g: PR '$bad' produced: $dispatcher_json"
            return 1
        }
    done
    [ "$(git -C "$sandbox" rev-parse HEAD)" = "$initial_sha" ] || {
        echo "test_grind_g: a rejected PR number still produced a commit"
        return 1
    }
}

# test_q: the INDEX-ONLY premise, proven behaviourally (#683).
#
# The #678 wait-round guard in agents/pr-grinder.md gates the Codex nudge on
# `git diff --cached --quiet` ALONE, and that is only correct because this
# script commits the index and nothing else. If it ever staged working-tree
# content, a round the worker classified as a wait-round would actually push,
# and the nudge would fire on a fix-round.
#
# That premise was previously pinned by a regex over the script's text. Four
# review rounds each found another lexical evasion — compound commands, wrapper
# binaries, shell keyword positions, unlisted git global options, `git rm`/`mv`,
# `commit -a`/`--include`/pathspec, comment-vs-continuation ordering, and
# `bash -c "…"` nesting. A regex cannot decide this; the shell can. So the
# premise is asserted by OBSERVING the commit, which no lexical trick evades.
#
# To prove this test fails when the premise breaks (it must, or it certifies
# nothing), run it against a doctored copy:
#   awk '/^printf .* \| git commit -F -/{print "git add -A"} {print}' \
#     scripts/dispatcher-commit-block.sh > /tmp/broken.sh
#   DISPATCHER_COMMIT_BLOCK=/tmp/broken.sh bash tests/test-dispatcher-commit-block.sh
#
# awk, not sed: BSD sed (macOS) rejects the one-line `i text` form this used to
# use, so the documented command failed on the maintainer's own platform — a
# reproduction that does not run proves nothing. The anchor is deliberately the
# full `printf ... | git commit -F -` line, not a bare `git commit -F -`, which
# also matches a COMMENT above it and would inject a second stray `git add -A`.
# The redirect leaves /tmp/broken.sh at mode 0644; that is fine, because every
# call site runs it as `bash "$SCRIPT"` (see run_dispatcher).
test_q_index_only_premise() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json committed committed_blob
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Build all the states the premise distinguishes. The fixture leaves
    # file.txt staged; unstage it so it becomes the tracked-but-UNSTAGED case.
    git -C "$sandbox" reset -q
    printf 'staged\n' > "$sandbox/staged.txt"
    git -C "$sandbox" add staged.txt          # (1) staged      -> MUST be committed
    # ...then make the WORKING TREE copy of that same path diverge from what was
    # staged. Checking path NAMES alone is not enough: `git commit --only
    # staged.txt` (or a bare pathspec) commits this path's working-tree blob
    # instead of its staged blob — same name, wrong content — and would sail
    # through a names-only assertion while breaking the premise outright.
    printf 'WORKTREE-ONLY\n' > "$sandbox/staged.txt"
    printf 'untracked\n' > "$sandbox/untracked.txt"   # (2) untracked -> must NOT be
    # (3) file.txt is tracked, modified, unstaged  -> must NOT be committed

    run_dispatcher_capture

    printf '%s\n' "$dispatcher_json" | jq -e '.status == "success"' >/dev/null || {
        echo "test_q: expected a fix-round success envelope; got exit=$dispatcher_exit json=$dispatcher_json"
        return 1
    }

    committed=$(git -C "$sandbox" show --name-only --pretty=format: HEAD | sed '/^$/d' | sort | tr '\n' ' ')
    [[ "$committed" = "staged.txt " ]] || {
        echo "test_q: commit must contain ONLY the staged path; got: [$committed]"
        return 1
    }
    # CONTENT, not just the name: the committed blob must be what was STAGED.
    committed_blob=$(git -C "$sandbox" show HEAD:staged.txt)
    [[ "$committed_blob" = "staged" ]] || {
        echo "test_q: committed blob must be the STAGED content, not the working tree's; got: [$committed_blob]"
        return 1
    }
    # ...and the WORKING-TREE copy of that same path must still hold the
    # divergent edit. Committing the right blob is only half the premise: a
    # block that commits the staged blob and then restores the path (`git
    # checkout -- staged.txt`) or deletes it satisfies every assertion above
    # while silently destroying the user's uncommitted work. file.txt and
    # untracked.txt are both checked for exact survival below; staged.txt was
    # the one dirty fixture with no such check (Codex finding on PR #688).
    [[ -f "$sandbox/staged.txt" ]] || {
        echo "test_q: the staged path's working-tree copy vanished"
        return 1
    }
    [[ "$(cat "$sandbox/staged.txt")" = "WORKTREE-ONLY" ]] || {
        echo "test_q: the staged path's working-tree edit was discarded; got: [$(cat "$sandbox/staged.txt")]"
        return 1
    }
    # The non-index changes must still be sitting in the working tree —
    # proving they were not swept in and then cleaned up.
    if git -C "$sandbox" diff --quiet -- file.txt; then
        echo "test_q: the unstaged tracked modification was consumed by the commit"
        return 1
    fi
    # `diff --quiet` only proves file.txt DIFFERS from HEAD — a destructive
    # regression that deletes file.txt or overwrites it with different
    # content still leaves that diff nonzero, so the check above would pass
    # despite the tracked fixture not actually surviving intact. Assert the
    # exact content directly, mirroring test_r's fix for the same weakness
    # (CodeRabbit + Codex finding on PR #688).
    [[ -f "$sandbox/file.txt" ]] || {
        echo "test_q: the tracked file vanished"
        return 1
    }
    [[ "$(cat "$sandbox/file.txt")" = "changed" ]] || {
        echo "test_q: the tracked file's content changed unexpectedly"
        return 1
    }
    [[ -f "$sandbox/untracked.txt" ]] || {
        echo "test_q: untracked file vanished"
        return 1
    }
    # Existence alone doesn't prove the untracked file survived intact — it
    # could have been truncated or overwritten. Assert the exact content
    # (same rationale as test_r's fix for the same weakness).
    [[ "$(cat "$sandbox/untracked.txt")" = "untracked" ]] || {
        echo "test_q: untracked file's content changed"
        return 1
    }
    git -C "$sandbox" ls-files --error-unmatch untracked.txt >/dev/null 2>&1 && {
        echo "test_q: untracked file became tracked — the block staged it"
        return 1
    }
    return 0
}

# test_r: the WAIT-ROUND half of the same premise (#683).
#
# test_q above proves a fix-round commits only the index — but it stages
# something first, so it only ever exercises the fix-round branch. The wait-round
# guard's correctness rests on the OTHER branch: with an EMPTY index and dirty
# working tree, the block must classify a wait-round (`result_commit_sha: none`),
# stage nothing, and leave HEAD where it was. A regression that staged only when
# `git diff --cached --quiet` succeeds would slip past test_q entirely and turn a
# real wait-round into a push — precisely the failure #678's guard exists to
# prevent. So assert that branch directly.
test_r_wait_round_stages_nothing() {
    local sandbox="" plugin_root="" shimdir="" remote="" original_dir="" initial_sha=""
    local dispatcher_output dispatcher_exit dispatcher_json before_sha after_sha
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    # Drain the fixture's staged change so the index is genuinely EMPTY.
    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    before_sha=$(git -C "$sandbox" rev-parse HEAD)

    # Dirty working tree, clean index — the exact wait-round shape.
    printf 'unstaged edit\n' > "$sandbox/file.txt"      # tracked, modified, UNSTAGED
    printf 'untracked\n' > "$sandbox/untracked.txt"     # untracked

    run_dispatcher_capture needs_more "none"

    printf '%s\n' "$dispatcher_json" | jq -e '.status == "success" and .result_commit_sha == "none"' >/dev/null || {
        echo "test_r: dirty tree + empty index must classify a WAIT-round; got exit=$dispatcher_exit json=$dispatcher_json"
        return 1
    }
    after_sha=$(git -C "$sandbox" rev-parse HEAD)
    [[ "$before_sha" = "$after_sha" ]] || {
        echo "test_r: a wait-round moved HEAD ($before_sha -> $after_sha) — it committed something"
        return 1
    }
    git -C "$sandbox" diff --cached --quiet || {
        echo "test_r: a wait-round left content STAGED: $(git -C "$sandbox" diff --cached --name-only | tr '\n' ' ')"
        return 1
    }
    if git -C "$sandbox" diff --quiet -- file.txt; then
        echo "test_r: the unstaged tracked modification disappeared on a wait-round"
        return 1
    fi
    # `diff --quiet` only proves file.txt DIFFERS from HEAD — a destructive
    # regression that deletes file.txt or overwrites it with different
    # content still leaves that diff nonzero, so the check above would pass
    # despite the tracked fixture not actually surviving intact. Assert the
    # exact content directly (CodeRabbit + Codex finding on PR #688).
    [[ -f "$sandbox/file.txt" ]] || {
        echo "test_r: the tracked file vanished on a wait-round"
        return 1
    }
    [[ "$(cat "$sandbox/file.txt")" = "unstaged edit" ]] || {
        echo "test_r: the tracked file's content changed on a wait-round"
        return 1
    }
    # Assert the file SURVIVES (and is unmodified) before checking it stayed
    # untracked — `ls-files --error-unmatch` alone returns nonzero both when
    # the path is untracked AND when it no longer exists at all, so it can't
    # distinguish "correctly untracked" from "destructively removed" (Codex
    # finding on PR #688).
    [[ -f "$sandbox/untracked.txt" ]] || {
        echo "test_r: untracked file vanished on a wait-round"
        return 1
    }
    [[ "$(cat "$sandbox/untracked.txt")" = "untracked" ]] || {
        echo "test_r: untracked file's content changed on a wait-round"
        return 1
    }
    git -C "$sandbox" ls-files --error-unmatch untracked.txt >/dev/null 2>&1 && {
        echo "test_r: untracked file became tracked on a wait-round"
        return 1
    }
    return 0
}

failed=0
for t in $(declare -F | awk '/test_/{print $3}' | sort); do
    if "$t"; then
        echo "PASS: $t"
    else
        echo "FAIL: $t"
        failed=1
    fi
done

if [ "$failed" = 1 ]; then
    echo "(Expected: t1 and implemented tests pass; placeholder test_* cases fail until Phase 6.)"
fi
exit "$failed"
