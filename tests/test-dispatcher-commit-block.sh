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
test_e_autofix_trailer_inplace() { todo "test_e"; }
test_f_adversarial_result_fixes() { todo "test_f"; }
test_g_inline_subagent_parity() { todo "test_g"; }
test_h_litmus_stall() { todo "test_h"; }
test_i_litmus_max_iter() { todo "test_i"; }
test_j_litmus_infra_fail() { todo "test_j"; }
test_k_push_failure() { todo "test_k"; }
test_l_fix_round_classifier() { todo "test_l"; }
test_m_wait_round_classifier() { todo "test_m"; }
test_n_clean_path_acks() { todo "test_n"; }
test_o_copilot_env_invocation() { todo "test_o"; }

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

test_q_routing_unrecognized() { todo "test_q"; }
test_r_marker_validation() { todo "test_r"; }
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
