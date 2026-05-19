#!/usr/bin/env bash
# tests/test-litmus-terminal-status.sh — fixture-driven, no production backdoor.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/litmus/scripts/run-review-loop.sh"

# Use a sandbox temp dir; copy the script + needed lib files
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

cd "$SANDBOX"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
mkdir -p .claude skills/litmus/scripts/lib scripts/lib
cp "$SCRIPT" skills/litmus/scripts/run-review-loop.sh
cp -r "$REPO_ROOT"/skills/litmus/scripts/lib/* skills/litmus/scripts/lib/ 2>/dev/null || true
cp -r "$REPO_ROOT"/scripts/lib/* scripts/lib/ 2>/dev/null || true

# Fixture 1: state.md with frontmatter but empty required field values
# → triggers the "missing iteration or max_iterations" setup_error exit.
#
# The state file must include the iteration: and max_iterations: keys with
# empty values rather than omitting them entirely, because run-review-loop.sh
# runs under set -euo pipefail and get_yaml_value's internal grep pipeline
# exits non-zero when a key is absent, causing the script to exit before
# reaching the write_terminal_status call.
#
# Stage a file so the script passes the "no staged changes" guard and
# reaches the YAML state-reading section.
echo "dummy" > file.txt
git add file.txt
printf -- '---\nactive: true\niteration: \nmax_iterations: \ncompletion_promise: null\nreview_mode: commit\n---\n' > .claude/litmus-state.md
bash skills/litmus/scripts/run-review-loop.sh 2>/dev/null || true
# shellcheck disable=SC2312  # $(cat ...) only invoked on FAIL branch for diagnostic
grep -q 'terminal_status:.*"setup_error"' .claude/litmus-state.md \
    || { echo "FAIL: setup_error not written ($(cat .claude/litmus-state.md))"; exit 1; }

# ────────────────────────────────────────────────────────────
# Fixture 2 helpers — mock-CLI harness for litmus integration tests.
# ────────────────────────────────────────────────────────────
# Strategy: drop a fake `gemini` script into a temp dir, prepend it to
# PATH, and set BUSDRIVER_REVIEW_CLI=gemini. The mock reads stdin (the
# prompt — discarded) and prints a deterministic JSON FAIL verdict so
# every iteration produces the same issue fingerprint. SAST, smart
# context, docs context, and markdown checks are all disabled to keep
# the fixture hermetic and fast.

# Build the mock CLI. Each invocation prints the same JSON FAIL verdict.
create_mock_gemini() {
    local bindir="$1"
    mkdir -p "$bindir"
    # IMPORTANT: emit JSON on a SINGLE line. The merger (merge-findings.py)
    # reads inputs line-by-line — multi-line pretty-printed JSON would be
    # split across lines and each line attempted as separate JSON, silently
    # dropping the verdict.
    cat > "$bindir/gemini" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock gemini for litmus integration testing.
# Drains stdin so upstream printf does not SIGPIPE, then emits a fixed
# single-line JSON FAIL verdict. Output identity across calls is what
# trips compute_issue_fingerprint → is_stalled.
cat > /dev/null
printf '%s\n' '{"status":"FAIL","issues":[{"file":"test_target.txt","line":1,"severity":"high","category":"bug","description":"deterministic stall-test issue (fixture-driven, no LLM)","suggestion":"no-op for test","confidence":95}]}'
MOCK_EOF
    chmod +x "$bindir/gemini"
}

# Set up an isolated sandbox per fixture. Sets SANDBOX2 / BINDIR2 for the
# caller; teardown_fixture2_sandbox cleans up.
setup_fixture2_sandbox() {
    SANDBOX2=$(mktemp -d)
    BINDIR2=$(mktemp -d)
    cd "$SANDBOX2"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    mkdir -p .claude skills/litmus/scripts/lib scripts/lib
    cp "$SCRIPT" skills/litmus/scripts/run-review-loop.sh
    cp "$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh" skills/litmus/scripts/init-review-loop.sh
    cp -r "$REPO_ROOT"/skills/litmus/scripts/lib/* skills/litmus/scripts/lib/ 2>/dev/null || true
    cp -r "$REPO_ROOT"/scripts/lib/* scripts/lib/ 2>/dev/null || true
    # Initial commit so `git diff --cached` has a base; then stage a
    # target file whose diff the script "reviews".
    echo "base" > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    echo "test content" > test_target.txt
    git add test_target.txt
    create_mock_gemini "$BINDIR2"
}

teardown_fixture2_sandbox() {
    cd /
    rm -rf "$SANDBOX2" "$BINDIR2"
    unset SANDBOX2 BINDIR2
}

# Run run-review-loop.sh with the mock CLI in scope. Disables SAST,
# smart-context, docs-context, and markdown so the only signal reaching
# the merge step is the mock LLM verdict.
run_fixture2_review_loop() {
    PATH="$BINDIR2:$PATH" \
    BUSDRIVER_REVIEW_CLI=gemini \
    LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_CONTEXT=1 \
    LITMUS_SKIP_MARKDOWN=1 \
    LITMUS_DOCS_CONTEXT=0 \
    LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash skills/litmus/scripts/run-review-loop.sh
}

# ────────────────────────────────────────────────────────────
# Fixture 2a: review_findings path
# Single iteration, mock returns FAIL with one issue, no prior history.
# Expected: exit 1, state file gains terminal_status: "review_findings".
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

set +e
run_fixture2_review_loop >/dev/null 2>&1
loop_exit=$?
set -e

if [ "$loop_exit" -ne 1 ]; then
    echo "FAIL Fixture 2a: expected exit 1, got $loop_exit"
    teardown_fixture2_sandbox
    exit 1
fi
if ! grep -q 'terminal_status:.*"review_findings"' .claude/litmus-state.md; then
    echo "FAIL Fixture 2a: terminal_status review_findings not written"
    cat .claude/litmus-state.md
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2b: stall path
# Two iterations with identical FAIL output — compute_issue_fingerprint
# hashes high/medium issues, so iter2's fingerprint matches iter1's
# saved history and trips is_stalled. Expected: iter1 exits 1
# (review_findings, history saved); iter2 exits 1 with stall.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

set +e
run_fixture2_review_loop >/dev/null 2>&1
iter1_exit=$?
set -e
if [ "$iter1_exit" -ne 1 ]; then
    echo "FAIL Fixture 2b iter1: expected exit 1, got $iter1_exit"
    teardown_fixture2_sandbox
    exit 1
fi

set +e
run_fixture2_review_loop >/dev/null 2>&1
iter2_exit=$?
set -e
if [ "$iter2_exit" -ne 1 ]; then
    echo "FAIL Fixture 2b iter2: expected exit 1, got $iter2_exit"
    teardown_fixture2_sandbox
    exit 1
fi
if ! grep -q 'terminal_status:.*"stall"' .claude/litmus-state.md; then
    echo "FAIL Fixture 2b: terminal_status stall not written after iter2"
    cat .claude/litmus-state.md
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

echo "All litmus terminal-status tests passed (Fixture 1, 2a, 2b)"
