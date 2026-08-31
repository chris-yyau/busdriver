#!/bin/bash -p
# prepare-commit-msg: bind MERGE_HEAD into the pending merge claim (#622).
set -euo pipefail
unset BASH_ENV ENV
export PATH=/usr/bin:/bin
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -z "$REPO_DIR" ]] && exit 0
MERGE_HEAD=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
[[ -z "$MERGE_HEAD" || ! -f "$MERGE_HEAD" ]] && exit 0
_GATE_SRC="${BASH_SOURCE[0]}"
_dir=$(dirname "$_GATE_SRC"); _base=$(basename "$_GATE_SRC")
while [[ -L "$_dir/$_base" ]]; do
  _link=$(readlink "$_dir/$_base")
  case "$_link" in /*) _GATE_SRC="$_link" ;; *) _GATE_SRC="$_dir/$_link" ;; esac
  _dir=$(dirname "$_GATE_SRC"); _base=$(basename "$_GATE_SRC")
done
_SCRIPT_DIR=$(cd "$_dir" && pwd)
# shellcheck source=lib/validate-staged-litmus-marker.sh disable=SC1091
source "$_SCRIPT_DIR/lib/validate-staged-litmus-marker.sh"
BUSDRIVER_MERGE_HEAD=$(git -C "$REPO_DIR" rev-parse -q --verify 'MERGE_HEAD^{commit}' 2>/dev/null || true)
if [[ ! "$BUSDRIVER_MERGE_HEAD" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  BUSDRIVER_MERGE_HEAD=$(head -1 "$MERGE_HEAD" 2>/dev/null | tr -d '[:space:]' || true)
fi
if [[ "$BUSDRIVER_MERGE_HEAD" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then export BUSDRIVER_MERGE_HEAD
else unset BUSDRIVER_MERGE_HEAD; fi
if ! gate_merge_bind_pending_heads "$REPO_DIR" "$STATE_DIR" 2>/dev/null \
  && ! (cd "$REPO_DIR" && python3 -I -S -c "import sys; sys.path.insert(0, sys.argv[1]); from merge_pending import bind_pending_merge_heads; raise SystemExit(0 if bind_pending_merge_heads('.', sys.argv[2]) else 1)" "$_SCRIPT_DIR/lib" "$STATE_DIR"); then
  printf 'merge prepare-commit-msg gate: could not bind merge parents; aborting.\n' >&2
  exit 1
fi
exit 0
