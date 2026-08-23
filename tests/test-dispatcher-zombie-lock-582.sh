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

# Block until $1 is STOPPED. Staging a zombie has a strict ORDER: only a stopped parent
# cannot run its SIGCHLD handler, so the child must be killed strictly AFTER the holder
# has stopped. Timing the two with a short-lived child races the scheduler — the child
# can exit and be reaped first, and the case then asserts on a pid that no longer
# exists. Waiting for the observed state removes the race instead of narrowing it.
await_stopped() {
    local _p="$1" _w=0 _st=""
    while :; do
        _st=$(ps -o state= -p "$_p" 2>/dev/null) || _st=""
        _st="${_st//[[:space:]]/}"
        [[ "$_st" == T* ]] && return 0
        sleep 0.05
        _w=$((_w + 1))
        [[ "$_w" -lt 60 ]] || fail "holder $_p never reached stopped state"
    done
}

tmpdir=$(mktemp -d)
live_pid=""
zombie_parent=""
zombie_child=""
mix_parent=""
mix_child=""
_cleanup_582() {
    local _p
    # Order matters. A holder is deliberately STOPPED while it owns a zombie, so killing
    # it first would orphan that zombie onto PID 1 — precisely the leak this file exists
    # to characterize. Resume every holder so it can reap, kill the children, let the
    # reaps land, and only then kill the holders. A child is NOT this script's child, so
    # `wait` could never reap it here; the holder has to.
    for _p in "$zombie_parent" "$mix_parent"; do
        [[ -n "$_p" ]] || continue
        kill -CONT "$_p" 2>/dev/null || true
    done
    for _p in "$zombie_child" "$mix_child"; do
        [[ -n "$_p" ]] || continue
        kill -KILL "$_p" 2>/dev/null || true
    done
    [[ -n "$zombie_child$mix_child" ]] && sleep 0.2
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
# Holding a REAL zombie and still reaping it are in tension, and the two obvious
# holders each give up one half. A live bash parent reaps its background children from
# its SIGCHLD handler — it does so even while blocked in `read` — so any
# poll-for-a-trigger holder destroys the zombie before it can be observed. `exec sleep`
# keeps the zombie but leaves nobody able to reap it, so killing the holder orphans it
# onto PID 1, and a non-reaping container PID 1 (issue #582's own scenario) keeps it
# forever. A STOPPED bash gives both: stopped, it cannot run its SIGCHLD handler, so the
# child stays a zombie; SIGCONT below makes it reap on resume, before we kill it.
z_reap_ack="$tmpdir/zombie-reap.ack"
bash -c 'sleep 120 & c=$!; echo "$c" > '"$child_pid_file"'; kill -STOP $$; wait "$c" 2>/dev/null || true; : > '"$z_reap_ack"'; exec sleep 120' &
zombie_parent=$!
waited=0
while [[ ! -s "$child_pid_file" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "zombie child pid file never appeared"
done
zombie_child=$(cat "$child_pid_file")
await_stopped "$zombie_parent"
kill -KILL "$zombie_child" 2>/dev/null || true
waited=0
while _dispatcher_pid_alive "$zombie_child"; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "child never became zombie (platform reaps too fast)"
done
kill -0 "$zombie_child" 2>/dev/null || fail "zombie child must still answer kill -0"
_dispatcher_pid_alive "$zombie_child" && fail "zombie direct child must not classify as alive"
pass "direct-child zombie classification"
# Resume the holder so it reaps BEFORE we kill it — nothing is orphaned onto PID 1.
kill -CONT "$zombie_parent" 2>/dev/null || true
waited=0
while [[ ! -f "$z_reap_ack" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "zombie child reap never acked"
done
kill -0 "$zombie_child" 2>/dev/null && fail "reaped zombie child must no longer exist"
# Reaped — forget the pid so cleanup can never signal whatever later reuses it.
zombie_child=""
kill -KILL "$zombie_parent" 2>/dev/null || true
wait "$zombie_parent" 2>/dev/null || true
zombie_parent=""

# --- 3) live-descendant fail-closed: zombie child but live parent => group exists ---
set -m
mix_pid_file="$tmpdir/mix-child.pid"
reap_ack="$tmpdir/reap.ack"
# Same STOP/CONT holder as case 2, and for the same reason: a holder that polls for a
# trigger reaps its child from its own SIGCHLD handler, so the descendant would be
# fully GONE rather than a zombie and both this case and case 4 would assert nothing.
bash -c 'sleep 120 & c=$!; echo "$c" > '"$mix_pid_file"'; kill -STOP $$; wait "$c" 2>/dev/null || true; : > '"$reap_ack"'; exec sleep 120' &
mix_parent=$!
waited=0
while [[ ! -s "$mix_pid_file" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "mixed-group child pid file never appeared"
done
mix_child=$(cat "$mix_pid_file")
await_stopped "$mix_parent"
kill -KILL "$mix_child" 2>/dev/null || true
waited=0
while _dispatcher_pid_alive "$mix_child"; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "mixed-group child never became zombie"
done
kill -0 "$mix_child" 2>/dev/null || fail "mixed-group child must still answer kill -0 (must be a zombie, not reaped)"
_dispatcher_pid_alive "$mix_child" && fail "zombie descendant must not classify as alive"
kill -0 "-$mix_parent" 2>/dev/null || fail "group with live parent must still exist (fail-closed)"
pass "live-descendant fail-closed"

# --- 4) child-only group reaping: owner reaps zombie child; group stays until leader exits ---
kill -CONT "$mix_parent" 2>/dev/null || true
waited=0
while [[ ! -f "$reap_ack" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 40 ]] || fail "child reap never acked"
done
kill -0 "$mix_child" 2>/dev/null && fail "reaped zombie descendant must no longer exist"
# Reaped — forget the pid so cleanup can never signal whatever later reuses it.
mix_child=""
kill -0 "-$mix_parent" 2>/dev/null || fail "reaping zombie child must not remove group while parent lives"
pass "child-only group reaping"
kill -KILL "$mix_parent" 2>/dev/null || true
wait "$mix_parent" 2>/dev/null || true
mix_parent=""
set +m

echo "All issue #582 zombie-lock regression checks passed"
