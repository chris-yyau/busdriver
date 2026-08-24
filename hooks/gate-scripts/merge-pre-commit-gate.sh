#!/bin/bash -p
# Native Git pre-commit hook: validate litmus when completing a merge via commit (#622).
#
# Covers `git merge --no-commit` / conflict-resolved merges finished with `git commit`,
# where pre-merge-commit does not run. Non-merge commits exit 0 immediately.

set -euo pipefail
unset BASH_ENV ENV
export PATH=/usr/bin:/bin

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"

REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -z "$REPO_DIR" ]] && exit 0

MERGE_HEAD=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
if [[ -z "$MERGE_HEAD" || ! -f "$MERGE_HEAD" ]]; then
    exit 0
fi

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
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$_SCRIPT_DIR/lib/resolve-repo-dir.sh"
# shellcheck source=lib/validate-staged-litmus-marker.sh disable=SC1091
source "$_SCRIPT_DIR/lib/validate-staged-litmus-marker.sh"

if ! gate_validate_staged_litmus_marker "$REPO_DIR" "$STATE_DIR"; then
    printf '%s\n' "$GATE_VALIDATE_REASON" >&2
    exit 1
fi
exit 0
