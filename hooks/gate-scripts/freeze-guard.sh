#!/usr/bin/env bash
# PreToolUse hook: restrict Write/Edit to a single directory during debugging
#
# When .claude/freeze-scope.local exists, blocks Write/Edit operations
# targeting files outside the allowed directory. This prevents agents from
# accidentally modifying unrelated files during focused debugging sessions.
#
# State file format (.claude/freeze-scope.local):
#   Line 1: absolute or relative path to allowed directory
#
# Activate: echo "src/auth" > .claude/freeze-scope.local
# Deactivate: rm .claude/freeze-scope.local
#
# The systematic-debugging skill auto-activates this when entering Phase 1.

set -euo pipefail

FREEZE_FILE=".claude/freeze-scope.local"

# No freeze active → approve immediately
[ ! -f "$FREEZE_FILE" ] && exit 0

# Read allowed scope
ALLOWED_SCOPE=$(head -1 "$FREEZE_FILE" 2>/dev/null || true)
[ -z "$ALLOWED_SCOPE" ] && exit 0

# ── Block emission helper ────────────────────────────────────────────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    else
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/"/\\"/g' | head -c 2000)
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# ── Parse tool name and file path ────────────────────────────────────
TOOL_NAME=""
FILE_PATH=""
if command -v python3 &>/dev/null; then
    PARSED=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    fp = inp.get("file_path", inp.get("filePath", ""))
    print(tool + "|" + fp)
except Exception:
    print("|")
' 2>/dev/null || echo "|")
    TOOL_NAME="${PARSED%%|*}"
    FILE_PATH="${PARSED#*|}"
fi

# Only gate Write and Edit tools
case "$TOOL_NAME" in
    Write|Edit) ;;
    *) exit 0 ;;
esac

# No file path → approve
[ -z "$FILE_PATH" ] && exit 0

# ── Always allow writes to infrastructure paths ──────────────────────
FILE_LOWER=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
case "$FILE_LOWER" in
    *.claude/*) exit 0 ;;
    *claude.md|*notes.md) exit 0 ;;
    *docs/plans/*|*docs/reviews/*|*docs/superpowers/*) exit 0 ;;
esac

# ── Normalize paths for comparison ───────────────────────────────────
# Strip trailing slashes, resolve . and ..
normalize() {
    local p="$1"
    # If relative, keep relative for comparison
    p="${p%/}"
    echo "$p"
}

NORM_SCOPE=$(normalize "$ALLOWED_SCOPE")
NORM_FILE=$(normalize "$FILE_PATH")

# Check if file is within allowed scope
# Match: file starts with scope path (directory prefix match)
if [[ "$NORM_FILE" == "$NORM_SCOPE"* ]] || [[ "$NORM_FILE" == */"$NORM_SCOPE"* ]]; then
    exit 0
fi

# ── Block: file is outside frozen scope ──────────────────────────────
REASON="FREEZE/GUARD: Edit blocked — file is outside the investigation scope.

Allowed scope: $ALLOWED_SCOPE
Blocked file:  $FILE_PATH

During debugging, edits are restricted to the investigation directory to prevent
accidental changes to unrelated code. This is enforced by .claude/freeze-scope.local.

To expand scope: echo \"new/path\" > .claude/freeze-scope.local
To unfreeze:     rm .claude/freeze-scope.local"

block_emit "$REASON"
