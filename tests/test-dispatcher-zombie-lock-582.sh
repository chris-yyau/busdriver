#!/usr/bin/env bash
# Issue #582 regression: kill -0 treats zombies as alive, wedging litmus-review.lock.
# One deterministic harness covering:
#   1) live control (fail-closed: running process => alive)
#   2) direct-child zombie classification (kill -0 succeeds, helper says dead)
#   3) live-descendant fail-closed (kernel still sees the group while parent lives)
#   4) child-only group reaping (owner reaps zombie child; group stays until leader exits)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROC_LIB="$REPO_ROOT/scripts/lib/dispatcher-proc-state.sh"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

# shellcheck source=/dev/null
. "$PROC_LIB"

tmpdir=$(mktemp -d)
live_pid=""
zombie_parent=""
mix_parent=""
_cleanup_582() {
    local _p
    for _p in "$live_pid" "$zombie_parent" "$mix_parent"; do
        [[ -n "$_p" ]] || continue
        kill -KILL "$_p" 2>/dev/null || true
        wait "$_p" 2>/dev/null || true
    done
    rm -rf "$tmpdir"
}
trap '_cleanup_582' EXIT

# --- 1) live control: a running sleep is alive ---
sleep 300 &
live_pid=$!
_dispatcher_pid_alive "$live_pid" || fail "live sleep must classify as alive"
pass "live descendant control"

# --- 2) direct-child zombie: holder keeps unreaped exited child (kill -0 vs helper) ---
child_pid_file="$tmpdir/child.pid"
bash -c 'sleep 0.01 & c=$!; echo "$c" > '"$child_pid_file"'; exec sleep 120' &
zombie_parent=$!
waited=0
while [[ ! -s "$child_pid_file" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "zombie child pid file never appeared"
done
zombie_child=$(cat "$child_pid_file")
waited=0
while _dispatcher_pid_alive "$zombie_child"; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "child never became zombie (platform reaps too fast)"
done
kill -0 "$zombie_child" 2>/dev/null || fail "zombie child must still answer kill -0"
_dispatcher_pid_alive "$zombie_child" && fail "zombie direct child must not classify as alive"
pass "direct-child zombie classification"
kill -KILL "$zombie_parent" 2>/dev/null || true
wait "$zombie_parent" 2>/dev/null || true
zombie_parent=""

# --- 3) live-descendant fail-closed: zombie child but live parent => group exists ---
set -m
mix_pid_file="$tmpdir/mix-child.pid"
reap_trigger="$tmpdir/reap.trigger"
reap_ack="$tmpdir/reap.ack"
bash -c 'sleep 0.01 & c=$!; echo "$c" > '"$mix_pid_file"'; while [[ ! -f '"$reap_trigger"' ]]; do sleep 0.05; done; wait "$c" 2>/dev/null || true; : > '"$reap_ack"'; exec sleep 120' &
mix_parent=$!
waited=0
while [[ ! -s "$mix_pid_file" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "mixed-group child pid file never appeared"
done
mix_child=$(cat "$mix_pid_file")
waited=0
while _dispatcher_pid_alive "$mix_child"; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "mixed-group child never became zombie"
done
_dispatcher_pid_alive "$mix_child" && fail "zombie descendant must not classify as alive"
kill -0 "-$mix_parent" 2>/dev/null || fail "group with live parent must still exist (fail-closed)"
pass "live-descendant fail-closed"

# --- 4) child-only group reaping: owner reaps zombie child; group stays until leader exits ---
: > "$reap_trigger"
waited=0
while [[ ! -f "$reap_ack" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "child reap never acked"
done
kill -0 "-$mix_parent" 2>/dev/null || fail "reaping zombie child must not remove group while parent lives"
pass "child-only group reaping"
kill -KILL "$mix_parent" 2>/dev/null || true
wait "$mix_parent" 2>/dev/null || true
mix_parent=""
set +m

echo "All issue #582 zombie-lock regression checks passed"
