#!/usr/bin/env bash
# Portable process-state helpers for dispatcher signal/lock safety (#582).
# Sourced by scripts/dispatcher-commit-block.sh.

# Read one process's scheduler state (first character is what matters: Z = zombie).
# Returns 1 on ambiguity (ps missing, empty, or pid not found while kill -0 still
# succeeds — pid reuse or a race). Callers treat ambiguity fail-CLOSED as alive.
_dispatcher_proc_state() {
    local _pid="$1" _st=""
    case "$_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _st=$(ps -o state= -p "$_pid" 2>/dev/null | awk 'NF{print $1; exit}' || true)
    if [[ -z "$_st" ]]; then
        _st=$(ps -o stat= -p "$_pid" 2>/dev/null | awk 'NF{print $1; exit}' || true)
    fi
    [[ -n "$_st" ]] || return 1
    printf '%s' "$_st"
}

# True when a pid is still running (not exited, not a waitable zombie). Zombies answer
# kill -0 but cannot write state — treating them as dead is what prevents a wedged lock.
_dispatcher_pid_alive() {
    local _pid="$1" _st=""
    if ! kill -0 "$_pid" 2>/dev/null; then
        return 1
    fi
    _st=$(_dispatcher_proc_state "$_pid") || return 0
    case "$_st" in
        Z*|z*) return 1 ;;
        *) return 0 ;;
    esac
}
