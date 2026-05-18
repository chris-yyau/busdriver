#!/usr/bin/env bash
# tests/test-dispatcher-commit-block.sh - scaffolding + helpers.
# Full scenario tests are added across later implementation phases.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatcher-commit-block.sh"

todo() {
    echo "TODO: $1 not implemented"
    return 1
}

reveal_dispatcher_bug() {
    echo "[reveals dispatcher bug] $1"
    return 1
}

assert_json() {
    local json="$1"
    local expr="$2"

    printf '%s\n' "$json" | jq -e "$expr" >/dev/null
}

write_default_plugin_root() {
    mkdir -p "$plugin_root/scripts/lib" "$plugin_root/skills/litmus/scripts"

    ln -s "$REPO_ROOT/scripts/lib/bail-envelope.sh" "$plugin_root/scripts/lib/bail-envelope.sh"
    ln -s "$REPO_ROOT/scripts/lib/staged-diff-hash.sh" "$plugin_root/scripts/lib/staged-diff-hash.sh"
    ln -s "$REPO_ROOT/scripts/lib/copilot-touched-lines.py" "$plugin_root/scripts/lib/copilot-touched-lines.py"
    ln -s "$REPO_ROOT/scripts/ack-ledger.sh" "$plugin_root/scripts/ack-ledger.sh"
    ln -s "$REPO_ROOT/scripts/copilot-auto-resolve-eligibility.sh" "$plugin_root/scripts/copilot-auto-resolve-eligibility.sh"

    cat > "$plugin_root/scripts/fetch-pr-state.sh" <<'EOF'
FETCH_OK=1
HEAD_SHA=$(git rev-parse HEAD | cut -c1-8)
ALL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
ALL_REVIEWS='[]'
ALL_COMMENTS='{"comments":[]}'
ALL_CHECK_RUNS='{"check_runs":[]}'
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA
return 0
EOF

    cat > "$plugin_root/skills/litmus/scripts/init-review-loop.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$plugin_root/skills/litmus/scripts/init-review-loop.sh"

    cat > "$plugin_root/skills/litmus/scripts/run-review-loop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

hash_staged_diff() {
    if command -v sha256sum >/dev/null 2>&1; then
        git diff --cached | sha256sum | cut -d' ' -f1
    else
        git diff --cached | shasum -a 256 | cut -d' ' -f1
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
        mkdir -p .claude
        printf 'terminal_status: review_findings\n' > .claude/litmus-state.md
        printf 'FAIL - Issues found\n'
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

    if [ -n "${litmus_mode+x}" ]; then env_args+=("LITMUS_MODE=$litmus_mode"); fi
    if [ -n "${no_worktree+x}" ]; then env_args+=("NO_WORKTREE=$no_worktree"); fi
    if [ -n "${pre_dispatch_baseline+x}" ]; then env_args+=("PRE_DISPATCH_BASELINE=$pre_dispatch_baseline"); fi
    if [ -n "${copilot_auto_resolve+x}" ]; then env_args+=("COPILOT_AUTO_RESOLVE=$copilot_auto_resolve"); fi
    if [ -n "${copilot_fetch_json+x}" ]; then env_args+=("COPILOT_FETCH_JSON=$copilot_fetch_json"); fi
    if [ -n "${gh_event_log+x}" ]; then env_args+=("GH_EVENT_LOG=$gh_event_log"); fi
    if [ -n "${dispatcher_event_log+x}" ]; then env_args+=("DISPATCHER_EVENT_LOG=$dispatcher_event_log"); fi
    if [ -n "${result_reviewer_acks+x}" ]; then env_args+=("RESULT_REVIEWER_ACKS=$result_reviewer_acks"); fi

    set +e
    dispatcher_output=$(env "${env_args[@]}" bash "$SCRIPT" 2>&1)
    dispatcher_exit=$?
    set -e
    dispatcher_json=$(printf '%s\n' "$dispatcher_output" | tail -n 1)
}

# Helper: run script with controlled env; capture last JSON line.
run_dispatcher() {
    "$SCRIPT" 2>&1 | tail -n 1
}

# t1: missing required env -> bail with judgment.
result=$(WORKTREE_DIR= CLAUDE_PLUGIN_ROOT= PR_NUMBER= RESULT_STATUS= RESULT_FIXES= run_dispatcher || true)
echo "$result" | jq -e '.bail_category == "judgment"' >/dev/null \
    || { echo "FAIL t1: $result"; exit 1; }

test_a_litmus_before_commit() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
test_g_inline_subagent_parity() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
        echo "test_g inline-style invocation failed: $dispatcher_output"
        return 1
    }
    assert_json "$first_json" '.status == "success"' &&
        assert_json "$dispatcher_json" '.status == "success"'
}
test_h_litmus_stall() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    run_dispatcher_capture needs_more "none"

    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.status == "success"
         and .result_commit_sha == "none"
         and (.result_reviewer_acks | contains("greptile-apps=none"))' >/dev/null; then
        return 0
    fi

    reveal_dispatcher_bug "test_m wait-round no-staged path should return result_commit_sha=none with refreshed acks; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_n_clean_path_acks() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
    local dispatcher_output dispatcher_exit dispatcher_json before_sha after_sha
    local result_reviewer_acks
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    git -C "$sandbox" commit --no-gpg-sign -qm "consume staged fixture"
    git -C "$sandbox" push -q
    before_sha=$(git -C "$sandbox" rev-parse HEAD)
    result_reviewer_acks='greptile-apps=abc12345,cubic-dev-ai=none,coderabbitai=none,copilot-pull-request-reviewer=none'
    run_dispatcher_capture clean "none"
    after_sha=$(git -C "$sandbox" rev-parse HEAD)

    if printf '%s\n' "$dispatcher_json" | jq -e \
        --arg acks "$result_reviewer_acks" '.status == "success" and .result_reviewer_acks == $acks' >/dev/null &&
        [ "$after_sha" = "$before_sha" ]; then
        return 0
    fi

    reveal_dispatcher_bug "test_n clean path should inherit worker RESULT_REVIEWER_ACKS without committing/recomputing; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_o_copilot_env_invocation() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
    local dispatcher_output dispatcher_exit dispatcher_json copilot_auto_resolve
    local copilot_fetch_json gh_event_log
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    gh_event_log="$sandbox/gh-events.log"
    copilot_fetch_json=$(jq -nc \
        --arg base "$initial_sha" \
        --arg stale "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        '{
            data: {repository: {pullRequest: {
                baseRefOid: $base,
                reviews: {nodes: [{author: {login: "copilot-pull-request-reviewer"}, commit: {oid: $stale}}]},
                reviewThreads: {nodes: [{
                    id: "thread1",
                    isResolved: false,
                    isOutdated: false,
                    path: "file.txt",
                    line: 1,
                    comments: {nodes: [{author: {login: "copilot-pull-request-reviewer"}}]}
                }]}
            }}}
        }')
    cat > "$shimdir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_EVENT_LOG:-/dev/null}"

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
    printf 'owner/repo\n'
    exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
    args="$*"
    case "$args" in
        *addPullRequestReviewThreadReply*)
            printf '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"comment1"}}}}\n'
            ;;
        *resolveReviewThread*)
            printf '{"data":{"resolveReviewThread":{"thread":{"id":"thread1"}}}}\n'
            ;;
        *)
            printf '%s\n' "$COPILOT_FETCH_JSON"
            ;;
    esac
    exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
    chmod +x "$shimdir/gh"

    copilot_auto_resolve=1
    run_dispatcher_capture

    assert_json "$dispatcher_json" '.status == "success"' || {
        echo "test_o dispatcher output: $dispatcher_output"
        return 1
    }
    grep -q 'addPullRequestReviewThreadReply' "$gh_event_log" &&
        grep -q 'resolveReviewThread' "$gh_event_log"
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
    local sandbox plugin_root shimdir remote original_dir initial_sha
    local dispatcher_output dispatcher_exit dispatcher_json
    make_dispatcher_fixture
    trap 'cd "$original_dir"; rm -rf "$sandbox" "$plugin_root" "$shimdir" "$remote"' RETURN

    run_dispatcher_capture unexpected_status "add test coverage"

    if printf '%s\n' "$dispatcher_json" | jq -e \
        '.bail_category == "judgment"
         and (.bail_reason | contains("unrecognized RESULT_STATUS=unexpected_status"))' >/dev/null; then
        return 0
    fi

    reveal_dispatcher_bug "test_q unrecognized RESULT_STATUS should bail before commit; got exit=$dispatcher_exit json=$dispatcher_json"
}
test_r_marker_validation() {
    local sandbox plugin_root shimdir remote original_dir initial_sha
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
test_s_bail_envelope_roundtrip() { todo "test_s"; }
test_t_terminal_status_preferred() { todo "test_t"; }

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
