#!/bin/bash -p
# Native Git pre-merge-commit hook: block merge commits without litmus review (#622).
#
# Git invokes this after a conflict-free merge is staged and before the merge
# commit object is created. The staged diff is real, so marker hash comparison
# is meaningful — unlike PreToolUse command-string parsing.
#
# Install: scripts/install-git-hooks.sh (or symlink as .git/hooks/pre-merge-commit).
# Fail-CLOSED: any validation error aborts the merge commit (exit 1).
#
# PATH is pinned before any command lookup so an attacker-controlled PATH on
# `env PATH=… /usr/bin/git merge` cannot supply shim bash/git/sha256sum.

set -euo pipefail
unset BASH_ENV ENV
export PATH=/usr/bin:/bin

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"

REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$REPO_DIR" ]]; then
    printf 'pre-merge-commit gate: not inside a git repository\n' >&2
    exit 1
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
