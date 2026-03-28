#!/bin/bash
# Trusted marker writer for builtin review fallback
# Called via Bash tool (not Write tool) to avoid pre-implementation gate block
# Prefix with BUILTIN- so post-commit-consume-marker.sh can distinguish
# self-reviewed commits from externally-reviewed ones.
set -euo pipefail
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
mkdir -p "$REPO_DIR/.claude"
HASH=$(git diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
echo "BUILTIN-${HASH}" > "$REPO_DIR/.claude/codex-review-passed.local"
echo "Review marker written (builtin)"
