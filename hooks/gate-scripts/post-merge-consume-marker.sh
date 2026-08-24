#!/bin/bash -p
# Native Git post-merge hook: consume litmus marker only with a pending claim (#622).
# Fast-forward merges never run pre-merge-commit, so no claim → no consume.

set -euo pipefail
unset BASH_ENV ENV
export PATH=/usr/bin:/bin

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac

REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -z "$REPO_DIR" ]] && exit 0

_GATE_SRC="${BASH_SOURCE[0]}"
_dir=$(dirname "$_GATE_SRC")
_base=$(basename "$_GATE_SRC")
while [[ -L "$_dir/$_base" ]]; do
    _link=$(readlink "$_dir/$_base")
    case "$_link" in
        /*) _GATE_SRC="$_link" ;;
        *) _GATE_SRC="$_dir/$_link" ;;
    esac
    _dir=$(dirname "$_GATE_SRC")
    _base=$(basename "$_GATE_SRC")
done
_SCRIPT_DIR=$(cd "$_dir" && pwd)
# shellcheck source=lib/validate-staged-litmus-marker.sh disable=SC1091
source "$_SCRIPT_DIR/lib/validate-staged-litmus-marker.sh"

gate_merge_consume_if_pending "$REPO_DIR" "$STATE_DIR" "post-merge"
exit 0
