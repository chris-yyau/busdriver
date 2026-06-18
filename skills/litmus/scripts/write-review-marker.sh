#!/bin/bash
# Trusted marker writer for builtin review fallback
# Called via Bash tool (not Write tool) to avoid pre-implementation gate block
# Prefix with BUILTIN- so post-commit-consume-marker.sh can distinguish
# self-reviewed commits from externally-reviewed ones.
#
# Defense-in-depth: validates that run-review-loop.sh actually triggered
# the builtin fallback by checking for the handoff file it creates (exit 3).
# The handoff file is consumed after use (single-use token).
set -euo pipefail
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Validate builtin review was triggered — handoff file is created by
# run-review-loop.sh at exit code 3 (line 495). Without this, the script
# could be called to forge a marker without any review having occurred.
HANDOFF_FILE="$REPO_DIR/$STATE_DIR/builtin-review-prompt-path.local"
if [ ! -f "$HANDOFF_FILE" ]; then
    echo "ERROR: No builtin review handoff found — marker cannot be written." >&2
    echo "       This script should only be called after run-review-loop.sh exits with code 3." >&2
    exit 1
fi

# Consume the handoff file (single-use token)
rm -f "$HANDOFF_FILE"

mkdir -p "$REPO_DIR/$STATE_DIR"
HASH=$(git diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)
echo "BUILTIN-${HASH}" > "$REPO_DIR/$STATE_DIR/litmus-passed.local"
echo "Review marker written (builtin)"
