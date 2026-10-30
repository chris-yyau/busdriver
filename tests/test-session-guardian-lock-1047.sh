#!/usr/bin/env bash
# tests/test-session-guardian-lock-1047.sh
# #1047: session-guardian.sh's cooldown lock is claimed with Python's os.mkdir, which fails
# with EEXIST, because uutils mkdir(1) also reports success when a racing process created
# the directory first. The race itself cannot be forced here; these rows pin that the
# claim still refuses a held lock, and still takes and releases a free one.
set -euo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/continuous-learning-v2/agents/session-guardian.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/last-run.log"
run_guard() {
    rc=0
    err=$(cd "$TMP" && OBSERVER_LAST_RUN_LOG="$LOG" OBSERVER_ACTIVE_HOURS_START=0 \
        OBSERVER_ACTIVE_HOURS_END=0 OBSERVER_MAX_IDLE_SECONDS=0 OBSERVER_INTERVAL_SECONDS=300 \
        PROJECT_DIR="$TMP" bash "$SCRIPT" 2>&1 >/dev/null) || rc=$?
}

# A held lock: the cycle is skipped and the holder's lock is left alone.
mkdir "$LOG.lock"
run_guard
if [[ "$rc" -eq 1 && "$err" == *"locked by concurrent process"* && -d "$LOG.lock" ]]; then
    ok "held lock skips the cycle and is not removed"
else
    fail "held lock: rc=$rc err='$err'"
fi
rmdir "$LOG.lock"

# A free lock: the cycle proceeds and the lock is released afterwards.
run_guard
if [[ "$rc" -eq 0 && ! -e "$LOG.lock" ]]; then
    ok "free lock is claimed and released"
else
    fail "free lock: rc=$rc err='$err' lock_left=$([[ -e "$LOG.lock" ]] && echo yes || echo no)"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
