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
[[ -z "$INPUT" ]] && exit 0

# ── Fail CLOSED when python3 is unavailable ──────────────────────────
# A freeze is active (checked above) but without python3 we cannot parse the
# tool input to learn the target path. Every sibling gate blocks in this state;
# freeze-guard must too, or it silently fails OPEN and lets out-of-scope edits
# through. The matcher is Write|Edit|MultiEdit only, so blocking here never
# touches Bash — `rm .claude/freeze-scope.local` still unfreezes.
if ! command -v python3 &>/dev/null; then
    block_emit "FREEZE/GUARD: python3 not found — cannot verify the edit target while a freeze is active, so this write is blocked (fail-closed).

Allowed scope: $ALLOWED_SCOPE

Install python3 to restore scope checking, or unfreeze via Bash: rm .claude/freeze-scope.local"
    exit 0
fi

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
    if not fp and tool == "MultiEdit":
        # MultiEdit carries file_path at the top level in the common case;
        # fall back to the first edits[] entry, mirroring the sibling hooks
        # (post-edit-accumulator.js, gateguard-fact-force.js) that handle
        # the same MultiEdit shape.
        edits = inp.get("edits", [])
        if isinstance(edits, list) and edits and isinstance(edits[0], dict):
            fp = edits[0].get("file_path", edits[0].get("filePath", ""))
    print(tool + "|" + fp)
except Exception:
    print("|")
' 2>/dev/null || echo "|")
    TOOL_NAME="${PARSED%%|*}"
    FILE_PATH="${PARSED#*|}"
fi

# Only gate Write, Edit, and MultiEdit tools
case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

# No file path → approve
[ -z "$FILE_PATH" ] && exit 0

# ── Always allow writes to infrastructure paths ──────────────────────
FILE_LOWER=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
case "$FILE_LOWER" in
    *.claude/*) exit 0 ;;
    *claude.md|*notes.md) exit 0 ;;
    *docs/plans/*|*docs/specs/*|*docs/reviews/*) exit 0 ;;
esac

# ── Normalize paths for comparison ───────────────────────────────────
# Strip trailing slashes, collapse . and .. segments
normalize() {
    local p="$1"
    p="${p%/}"
    # Resolve . and .. via python3 if available (stdin to avoid injection), else basic strip
    if command -v python3 &>/dev/null; then
        p=$(printf '%s' "$p" | python3 -c 'import sys, os.path; print(os.path.normpath(sys.stdin.read()))' 2>/dev/null || echo "$p")
    fi
    echo "$p"
}

NORM_SCOPE=$(normalize "$ALLOWED_SCOPE")
NORM_FILE=$(normalize "$FILE_PATH")

# Check if file is within allowed scope
# Match: exact scope path OR scope path followed by / (directory boundary)
# Only match at the START of the path — prevents /tmp/src/auth/ from matching scope src/auth
if [[ "$NORM_FILE" == "$NORM_SCOPE" ]] || [[ "$NORM_FILE" == "$NORM_SCOPE"/* ]]; then
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
