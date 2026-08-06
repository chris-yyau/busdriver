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
# Strategy: drop a fake `agy` script into a temp dir, prepend it to
# PATH, and set BUSDRIVER_REVIEW_CLI=agy. The mock ignores its argv
# prompt and prints a deterministic JSON FAIL verdict so every iteration
# produces the same issue fingerprint. SAST, smart context, docs context,
# and markdown checks are all disabled to keep the fixture hermetic and fast.

# Build the mock CLI. Each invocation prints the same JSON FAIL verdict.
create_mock_agy() {
    local bindir="$1"
    mkdir -p "$bindir"
    # Emit JSON on a SINGLE line. The merger now handles multi-line input
    # too (json.JSONDecoder.raw_decode landed in the same PR as this fixture),
    # but keeping the mock compact matches the historical single-line CLI
    # contract and keeps the fixture's failure modes obvious — if the merger
    # ever regresses to per-line parsing, this fixture still works.
    cat > "$bindir/agy" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock agy for litmus integration testing.
# Drains stdin (the prompt piped to `agy --print /dev/stdin`) so the
# upstream printf does not SIGPIPE, then emits a fixed single-line JSON
# FAIL verdict. Output identity across calls is what trips
# compute_issue_fingerprint → is_stalled.
cat > /dev/null
printf '%s\n' '{"status":"FAIL","issues":[{"file":"test_target.txt","line":1,"severity":"high","category":"bug","description":"deterministic stall-test issue (fixture-driven, no LLM)","suggestion":"no-op for test","confidence":95}]}'
MOCK_EOF
    chmod +x "$bindir/agy"
}

# Set up an isolated sandbox per fixture. Sets SANDBOX2 / BINDIR2 for the
# caller; teardown_fixture2_sandbox cleans up.
# SANDBOX2 and BINDIR2 are also registered with the EXIT trap so unexpected
# failures between setup and teardown (set -e exits, missing cp targets, etc.)
# do not leak temp directories.
setup_fixture2_sandbox() {
    SANDBOX2=$(mktemp -d)
    BINDIR2=$(mktemp -d)
    trap 'rm -rf "$SANDBOX"; [[ -n "${SANDBOX2:-}" ]] && rm -rf "$SANDBOX2"; [[ -n "${BINDIR2:-}" ]] && rm -rf "$BINDIR2"' EXIT
    cd "$SANDBOX2"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    mkdir -p .claude skills/litmus/scripts/lib skills/blueprint-review/scripts/lib scripts/lib
    cp "$SCRIPT" skills/litmus/scripts/run-review-loop.sh
    cp "$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh" skills/litmus/scripts/init-review-loop.sh
    cp -r "$REPO_ROOT"/skills/litmus/scripts/lib/* skills/litmus/scripts/lib/ 2>/dev/null || true
    cp -r "$REPO_ROOT"/scripts/lib/* scripts/lib/ 2>/dev/null || true
    # Issue #120: copy the JSON extractor into the sandbox so the EXTRACTOR
    # candidate loop in run-review-loop.sh finds extract_review_json.py via
    # CLAUDE_PLUGIN_ROOT instead of falling through to
    # $HOME/.claude/plugins/marketplaces/busdriver/... which would make the
    # test non-hermetic (passes on dev host, may fall back to
    # parse-narrative.py on clean machines and silently produce PASS).
    cp "$REPO_ROOT/skills/blueprint-review/scripts/lib/extract_review_json.py" \
        skills/blueprint-review/scripts/lib/extract_review_json.py
    # Initial commit so `git diff --cached` has a base; then stage a
    # target file whose diff the script "reviews".
    echo "base" > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    echo "test content" > test_target.txt
    git add test_target.txt
    create_mock_agy "$BINDIR2"
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
    BUSDRIVER_REVIEW_CLI=agy \
    CLAUDE_PLUGIN_ROOT="$SANDBOX2" \
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

# ────────────────────────────────────────────────────────────
# Fixture 2c-order: the clear must precede the SETUP steps, not merely the reviewer.
# Until the field is gone, a resumed live review still advertises the previous run's
# outcome, so a concurrent reader classifies it as finished. Setup is quick but not
# instant (CLI resolution, git and diff checks), and every setup exit path writes its
# own terminal_status — which means the ordering leaves no runtime trace to assert on.
# Pin it in the source instead: a test beats prose for an invariant that would
# otherwise survive only as a comment.
# ────────────────────────────────────────────────────────────
clear_line=$(grep -n '^clear_terminal_status$' "$SCRIPT" | head -n 1 | cut -d: -f1)
gitrepo_line=$(grep -n '^validate_git_repo' "$SCRIPT" | head -n 1 | cut -d: -f1)
cli_line=$(grep -n 'validate_review_cli' "$SCRIPT" | head -n 1 | cut -d: -f1)
if [ -z "$clear_line" ] || [ -z "$gitrepo_line" ] || [ -z "$cli_line" ]; then
    echo "FAIL Fixture 2c-order: could not locate clear/setup call sites"
    exit 1
fi
if [ "$clear_line" -ge "$gitrepo_line" ] || [ "$clear_line" -ge "$cli_line" ]; then
    echo "FAIL Fixture 2c-order: clear_terminal_status (line $clear_line) must precede"
    echo "  validate_git_repo (line $gitrepo_line) and validate_review_cli (line $cli_line)"
    exit 1
fi

# ────────────────────────────────────────────────────────────
# Fixture 2c: terminal_status is CLEARED when a run starts (#569).
# A resumed loop must not carry the previous iteration's terminal_status while the
# next review is in flight — a reader that treats the field as proof of a finished
# run would classify a LIVE review as stale and force-reset it. Iteration 1 leaves
# review_findings; the mock CLI for iteration 2 snapshots the state file at the
# moment it is invoked, which is mid-run.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

set +e
run_fixture2_review_loop >/dev/null 2>&1
set -e
grep -q 'terminal_status:.*"review_findings"' .claude/litmus-state.md || {
    echo "FAIL Fixture 2c: setup — iter1 did not leave review_findings"
    teardown_fixture2_sandbox
    exit 1
}

# Replace the mock with one that records the state file as the reviewer sees it.
MIDRUN_SNAPSHOT="$SANDBOX2/midrun-state.txt"
cat > "$BINDIR2/agy" <<MOCK_EOF
#!/usr/bin/env bash
cat > /dev/null
cp "$SANDBOX2/.claude/litmus-state.md" "$MIDRUN_SNAPSHOT"
printf '%s\n' '{"status":"PASS","issues":[]}'
MOCK_EOF
chmod +x "$BINDIR2/agy"

set +e
run_fixture2_review_loop >/dev/null 2>&1
set -e

if [ ! -f "$MIDRUN_SNAPSHOT" ]; then
    echo "FAIL Fixture 2c: mock never ran — no mid-run snapshot"
    teardown_fixture2_sandbox
    exit 1
fi
if grep -q '^terminal_status:' "$MIDRUN_SNAPSHOT"; then
    echo "FAIL Fixture 2c: terminal_status still present mid-run (not cleared at start)"
    cat "$MIDRUN_SNAPSHOT"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2d: the TOO_LARGE (exit 2) path records a terminal_status (#569).
# It is the one non-PASS exit that used to leave the state file behind with none,
# so every later reader had to treat a finished run as possibly-live and refuse.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

# Force the size gate rather than generating a huge diff: one staged file already
# exists from the fixture, so a ceiling of 0 weighted lines trips it deterministically.
set +e
PATH="$BINDIR2:$PATH" \
BUSDRIVER_REVIEW_CLI=agy \
CLAUDE_PLUGIN_ROOT="$SANDBOX2" \
LITMUS_SKIP_SAST=1 \
LITMUS_SKIP_CONTEXT=1 \
LITMUS_SKIP_MARKDOWN=1 \
LITMUS_DOCS_CONTEXT=0 \
LITMUS_SHORTCIRCUIT_DISABLED=1 \
LITMUS_MAX_WEIGHTED_LINES=0 \
LITMUS_MAX_WEIGHTED_LINES_SINGLE_FILE=0 \
    bash skills/litmus/scripts/run-review-loop.sh >/dev/null 2>&1
toolarge_exit=$?
set -e

if [ "$toolarge_exit" -ne 2 ]; then
    echo "FAIL Fixture 2d: expected exit 2 (TOO_LARGE), got $toolarge_exit"
    teardown_fixture2_sandbox
    exit 1
fi
if ! grep -q 'terminal_status:.*"too_large"' .claude/litmus-state.md; then
    echo "FAIL Fixture 2d: terminal_status too_large not written"
    cat .claude/litmus-state.md
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2e: the review lock is what makes any other reader's classification safe.
# run-review-loop.sh must refuse to start while a LIVE owner holds it — two reviews
# share one state file. And it must reclaim a lock whose owner is dead, or one killed
# run wedges every later one.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

# Assert on whether the REVIEWER RAN, not on the exit code: a lock refusal and an
# ordinary FAIL verdict both exit 1, so an exit-code assertion cannot tell them apart
# and would pass with the lock check deleted. The mock drops a sentinel when invoked.
RAN_SENTINEL="$SANDBOX2/reviewer-ran"
cat > "$BINDIR2/agy" <<MOCK_EOF
#!/usr/bin/env bash
cat > /dev/null
touch "$RAN_SENTINEL"
printf '%s\n' '{"status":"FAIL","issues":[{"file":"test_target.txt","line":1,"severity":"high","category":"bug","description":"lock fixture issue","suggestion":"no-op","confidence":95}]}'
MOCK_EOF
chmod +x "$BINDIR2/agy"

sleep 60 &
live_holder=$!
ln -s "pid-$live_holder" .claude/litmus-review.lock

set +e
run_fixture2_review_loop >/dev/null 2>&1
set -e
kill "$live_holder" 2>/dev/null || true

if [ -e "$RAN_SENTINEL" ]; then
    echo "FAIL Fixture 2e: review ran while a live owner held the lock"
    teardown_fixture2_sandbox
    exit 1
fi
if [ ! -L .claude/litmus-review.lock ]; then
    echo "FAIL Fixture 2e: refusing to start released a lock it does not own"
    teardown_fixture2_sandbox
    exit 1
fi

# Same lock, now owned by a dead pid. An orphan is NOT auto-reclaimed: no shell
# reclaim is race-free (see lib/review-lock.sh), so the run refuses, leaves the lock
# alone, and tells the operator to unlink it. Refusing here is the fail-CLOSED trade —
# a rare visible stall after a SIGKILL, instead of silent double-review corruption.
#
# A REAPED pid (spawn + wait, as this used to do) is not a guaranteed-dead value —
# the OS can hand that pid to a brand-new process before this assertion runs, and on
# a busy host the test would then report a lock-implementation defect that does not
# exist. Search for a pid that fails `kill -0` instead; skip the orphan half if none
# can be found (should not happen on any real host, but fail toward "skip", not
# toward "false failure").
dead_holder=""
for _candidate in 999999 999998 999997 999996 999995; do
    if ! kill -0 "$_candidate" 2>/dev/null; then
        dead_holder="$_candidate"
        break
    fi
done
rm -f .claude/litmus-review.lock "$RAN_SENTINEL"
if [ -z "$dead_holder" ]; then
    echo "SKIP Fixture 2e: could not find a pid that fails kill -0; skipping orphan-lock assertion"
else
    ln -s "pid-$dead_holder" .claude/litmus-review.lock
fi

if [ -n "$dead_holder" ]; then
    set +e
    orphan_stderr=$(run_fixture2_review_loop 2>&1 >/dev/null)
    set -e

    if [ -e "$RAN_SENTINEL" ]; then
        echo "FAIL Fixture 2e: review ran despite an orphaned lock"
        teardown_fixture2_sandbox
        exit 1
    fi
    if [ ! -L .claude/litmus-review.lock ]; then
        echo "FAIL Fixture 2e: refusing on an orphan removed a lock it does not own"
        teardown_fixture2_sandbox
        exit 1
    fi
    case "$orphan_stderr" in
        *"not running"*"rm -f"*) ;;
        *)
            echo "FAIL Fixture 2e: orphan refusal must name the dead owner and the remedy"
            printf '%s\n' "$orphan_stderr"
            teardown_fixture2_sandbox
            exit 1
            ;;
    esac
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2f: --auto-pr-review must take the lock BEFORE it force-inits.
# That branch runs `init-review-loop.sh --force` and then re-execs, so acquiring the
# lock after it would let an auto-PR invocation reset litmus-state.md out from under a
# review that already owns the lock — failing only once the damage was done.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

# A distinctive marker in the state file: if the force-init ran, it is gone.
printf 'AUTO_PR_FIXTURE_SENTINEL\n' >> .claude/litmus-state.md

sleep 60 &
autopr_holder=$!
ln -s "pid-$autopr_holder" .claude/litmus-review.lock

set +e
PATH="$BINDIR2:$PATH" \
BUSDRIVER_REVIEW_CLI=agy \
CLAUDE_PLUGIN_ROOT="$SANDBOX2" \
LITMUS_SKIP_SAST=1 LITMUS_SKIP_CONTEXT=1 LITMUS_SKIP_MARKDOWN=1 \
LITMUS_DOCS_CONTEXT=0 LITMUS_SHORTCIRCUIT_DISABLED=1 \
    bash skills/litmus/scripts/run-review-loop.sh --auto-pr-review >/dev/null 2>&1
set -e
kill "$autopr_holder" 2>/dev/null || true

if ! grep -q 'AUTO_PR_FIXTURE_SENTINEL' .claude/litmus-state.md; then
    echo "FAIL Fixture 2f: --auto-pr-review force-initialized the state file while another review held the lock"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2g: init-review-loop.sh is a WRITER of litmus-state.md, so it takes the lock
# too — a mutual-exclusion contract some writers opt out of is not a contract. And a
# caller that already holds the lock must be able to shell out to it without
# deadlocking against itself, via the exported owner pid.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null
printf 'INIT_LOCK_FIXTURE_SENTINEL\n' >> .claude/litmus-state.md

sleep 60 &
init_holder=$!
init_token="pid-$init_holder-fixture2g"
ln -s "$init_token" .claude/litmus-review.lock

set +e
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh --force >/dev/null 2>&1
init_locked_exit=$?
set -e

if [ "$init_locked_exit" -eq 0 ]; then
    echo "FAIL Fixture 2g: init --force ran while another review held the lock"
    kill "$init_holder" 2>/dev/null || true
    teardown_fixture2_sandbox
    exit 1
fi
if ! grep -q 'INIT_LOCK_FIXTURE_SENTINEL' .claude/litmus-state.md; then
    echo "FAIL Fixture 2g: init --force rewrote the state file despite the lock"
    kill "$init_holder" 2>/dev/null || true
    teardown_fixture2_sandbox
    exit 1
fi

# Same lock, but now we declare ourselves its owner the way a holding parent does.
# init must proceed — and must NOT release a lock it merely inherited.
set +e
PATH="$BINDIR2:$PATH" BUSDRIVER_REVIEW_LOCK_OWNER="$init_token" \
    bash skills/litmus/scripts/init-review-loop.sh --force >/dev/null 2>&1
init_inherited_exit=$?
set -e
kill "$init_holder" 2>/dev/null || true

if [ "$init_inherited_exit" -ne 0 ]; then
    echo "FAIL Fixture 2g: init deadlocked against a lock it inherited (exit $init_inherited_exit)"
    teardown_fixture2_sandbox
    exit 1
fi
if [ ! -L .claude/litmus-review.lock ]; then
    echo "FAIL Fixture 2g: init released a lock it only inherited — the parent still holds it"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2h: a lock PATH that is a directory must not be acquirable.
# `ln -s TARGET DEST` follows DEST when it is a directory — it creates DEST/TARGET and
# exits 0 — so without an explicit check every acquirer reports success and the mutex is
# silently absent rather than merely broken. This is the worst failure a lock can have:
# it looks like it is working.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null

RAN_SENTINEL2="$SANDBOX2/reviewer-ran-2"
cat > "$BINDIR2/agy" <<MOCK_EOF
#!/usr/bin/env bash
cat > /dev/null
touch "$RAN_SENTINEL2"
printf '%s\n' '{"status":"PASS","issues":[]}'
MOCK_EOF
chmod +x "$BINDIR2/agy"

mkdir -p .claude/litmus-review.lock

set +e
run_fixture2_review_loop >/dev/null 2>&1
set -e

if [ -e "$RAN_SENTINEL2" ]; then
    echo "FAIL Fixture 2h: review ran with a directory as the lock path — ln -s followed it"
    teardown_fixture2_sandbox
    exit 1
fi
# `[ -e dir/glob* ]` does NOT expand as a test (shellcheck SC2144) — it silently
# checks a literal path and always passes, which is how this assertion first shipped
# doing nothing. Count real entries instead.
lock_dir_entries=$(find .claude/litmus-review.lock -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
if [ "$lock_dir_entries" != "0" ]; then
    echo "FAIL Fixture 2h: ln -s followed the directory and created an entry inside it"
    find .claude/litmus-review.lock -mindepth 1
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2i: the lock is taken before EVERY subcommand branch, not just the review
# path. --write-pr-marker calls write_terminal_status on its failure paths, so a lock
# acquired after it would let a concurrent marker-writing invocation mutate
# litmus-state.md while another review owns it. "Every writer takes the lock" has to
# mean every entry point.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/
PATH="$BINDIR2:$PATH" bash skills/litmus/scripts/init-review-loop.sh >/dev/null
printf 'WRITE_PR_MARKER_FIXTURE_SENTINEL\n' >> .claude/litmus-state.md
state_before=$(cat .claude/litmus-state.md)

sleep 60 &
marker_holder=$!
ln -s "pid-$marker_holder" .claude/litmus-review.lock

set +e
PATH="$BINDIR2:$PATH" CLAUDE_PLUGIN_ROOT="$SANDBOX2" \
    bash skills/litmus/scripts/run-review-loop.sh --write-pr-marker >/dev/null 2>&1
marker_exit=$?
set -e
kill "$marker_holder" 2>/dev/null || true

if [ "$marker_exit" -eq 0 ]; then
    echo "FAIL Fixture 2i: --write-pr-marker succeeded while another review held the lock"
    teardown_fixture2_sandbox
    exit 1
fi
if [ "$(cat .claude/litmus-state.md)" != "$state_before" ]; then
    echo "FAIL Fixture 2i: --write-pr-marker mutated litmus-state.md while another review held the lock"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2j: ownership propagates unchanged down a chain.
#
# Scope: 2g and 2j exercise the token MECHANISM — inheritance and propagation — which
# is the observable contract. They cannot demonstrate why a bare pid is an insufficient
# credential: that needs two live processes sharing one pid (subshells, separate PID
# namespaces over a shared state dir, or a reused orphan pid), none of which a local
# fixture can stage. The token is adopted on that reasoning, not on a test.
# A process that acquired by INHERITANCE does not own the lock — its parent does — so
# re-exporting its own pid would make a grandchild compare against a non-owner and
# reject the real holder's lock, deadlocking the very chain the export exists to allow.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/

real_owner="pid-4242424-fixture2j"
ln -s "$real_owner" .claude/litmus-review.lock

exported=$(
    BUSDRIVER_STATE_DIR=.claude
    export BUSDRIVER_STATE_DIR
    # shellcheck source=/dev/null
    . skills/litmus/scripts/lib/review-lock.sh
    # Stand in for a child that acquired by inheritance: it holds nothing itself.
    BUSDRIVER_REVIEW_LOCK_OWNER="$real_owner"
    export BUSDRIVER_REVIEW_LOCK_OWNER
    review_lock_export_owner
    printf '%s' "$BUSDRIVER_REVIEW_LOCK_OWNER"
)

if [ "$exported" != "$real_owner" ]; then
    echo "FAIL Fixture 2j: inherited owner re-exported as '$exported', expected '$real_owner'"
    echo "  (a grandchild would compare against a non-owner and reject the real lock)"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2k: pins the rc contract — an unwritable state dir is rc=2 (environment),
# a held lock in a valid dir is rc=1 (contention). Telling the operator to remove a
# lock that does not exist is the failure this distinction prevents.
#
# Scope, stated honestly: this pins the CONTRACT, not the mechanism behind it. The
# classifier has been an inference from a failed `ln`, then a `-d && -w` permission
# check, and now a symlink probe at a unique sibling path — and all three return these
# same two codes for these two cases. They diverge only under rapid contention, or on
# a filesystem that reports a directory writable while rejecting symlinks; neither can
# be staged deterministically here. The probe is defensible on reasoning (exercising
# the capability cannot be fooled the way inferring it can), and this fixture guards
# the contract that reasoning lives under.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/

# chmod cannot restrict root, so this half is meaningless in a root-run container
# (which CI images often are) — review_lock_acquire would simply succeed and return 0.
# Skip rather than fail: a test that cannot hold its precondition is not evidence.
if [ "$(id -u)" = "0" ]; then
    echo "  (Fixture 2k: skipping the unwritable-dir half — running as root, chmod does not bind)"
else
    mkdir -p unwritable-state
    chmod 500 unwritable-state
    rc_unwritable=0
    (
        BUSDRIVER_STATE_DIR=unwritable-state
        export BUSDRIVER_STATE_DIR
        # shellcheck source=/dev/null
        . skills/litmus/scripts/lib/review-lock.sh
        review_lock_acquire
    ) || rc_unwritable=$?
    chmod 700 unwritable-state

    if [ "$rc_unwritable" -ne 2 ]; then
        echo "FAIL Fixture 2k: unwritable state dir returned $rc_unwritable, expected 2 (environment)"
        teardown_fixture2_sandbox
        exit 1
    fi
fi

# A writable dir whose lock is held is contention (1), never environment (2).
rc_contended=0
ln -s "pid-4242424" .claude/litmus-review.lock
(
    BUSDRIVER_STATE_DIR=.claude
    export BUSDRIVER_STATE_DIR
    # shellcheck source=/dev/null
    . skills/litmus/scripts/lib/review-lock.sh
    review_lock_acquire
) || rc_contended=$?
if [ "$rc_contended" -ne 1 ]; then
    echo "FAIL Fixture 2k: contended lock in a valid dir returned $rc_contended, expected 1"
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

# ────────────────────────────────────────────────────────────
# Fixture 2l: clear_terminal_status must agree with the reader the rest of the script
# uses. get_yaml_value takes the FIRST declaration, so on a file with `active: true`
# followed by `active: false` the loop proceeds on true — and this function must clear
# on that same true, or a stale terminal_status survives the whole run.
#
# The first draft of this fixture eval'd the function body alone, without sourcing
# validation.sh. get_yaml_value was then undefined, the `|| echo ""` fallback returned
# empty, and the function declined to clear — so the fixture passed on a missing
# function rather than on the logic. Source the real reader.
# ────────────────────────────────────────────────────────────
setup_fixture2_sandbox
cp "$REPO_ROOT/skills/litmus/scripts/lib/review-lock.sh" skills/litmus/scripts/lib/

{
    printf -- '---\n'
    printf 'active: true\n'
    printf 'terminal_status: "review_findings"\n'
    printf 'active: false\n'
    printf -- '---\n'
} > .claude/litmus-state.md

(
    STATE_DIR=.claude
    # shellcheck disable=SC2034  # consumed by the clear_terminal_status body eval'd below
    STATE_FILE=.claude/litmus-state.md
    export BUSDRIVER_STATE_DIR="$STATE_DIR"
    # shellcheck source=/dev/null
    . skills/litmus/scripts/lib/validation.sh
    eval "$(sed -n '/^clear_terminal_status() {/,/^}/p' skills/litmus/scripts/run-review-loop.sh)"
    clear_terminal_status
)

if grep -q '^terminal_status:' .claude/litmus-state.md; then
    echo "FAIL Fixture 2l: did not clear terminal_status although get_yaml_value reads active as true"
    cat .claude/litmus-state.md
    teardown_fixture2_sandbox
    exit 1
fi
teardown_fixture2_sandbox

echo "All litmus terminal-status tests passed (Fixture 1, 2a, 2b, 2c, 2d, 2e, 2f, 2g, 2h, 2i, 2j, 2k, 2l)"
