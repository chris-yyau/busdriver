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
    PARSED=$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json
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

# ── Normalize paths for comparison ───────────────────────────────────
# Strip trailing slashes, collapse . and .. segments
#
# LEXICAL on purpose (see UPGRADE below). realpath would additionally close a
# symlink-laundering gap — a symlinked docs/specs -> src reads as a docs path
# here — but it CANNOT land until the `*.claude/*` arm below is repo-anchored:
# realpath makes every path absolute, and busdriver homes worktrees at
# <main>/.claude/worktrees/<name>/, so every absolute path in a worktree session
# would match `*.claude/*` and be exempted — turning the freeze into a no-op
# instead of closing a hole. (Verified: swapping in realpath alone fails 9 of
# this file's own scope assertions for exactly that reason.)
# UPGRADE: anchor `*.claude/*` to a repo-relative path (as
# pre-implementation-gate.sh does via gate_marker_relpath / ADR-E), THEN switch
# this to realpath in the same change. Both belong in one PR — that arm is
# already a live fail-open independent of symlinks.
normalize() {
    local p="$1"
    p="${p%/}"
    # Resolve . and .. via python3 if available (stdin to avoid injection), else basic strip
    if command -v python3 &>/dev/null; then
        p=$(printf '%s' "$p" | python3 -I -c 'import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import os.path
print(os.path.normpath(sys.stdin.read()))' 2>/dev/null || echo "$p")
    fi
    echo "$p"
}

NORM_SCOPE=$(normalize "$ALLOWED_SCOPE")
NORM_FILE=$(normalize "$FILE_PATH")

# ── Always allow writes to infrastructure paths ──────────────────────
# Matched against the NORMALIZED path. Against the raw path,
# `docs/specs/../../src/impl.sh` matches the docs glob but resolves to
# `src/impl.sh` — the exemption would hand an impl write a free pass.
#
# The docs/ arms require `docs` to START a path segment — a bare `*docs/specs/*`
# also matches `notdocs/specs/runtime.sh`, which is not a docs dir at all. Kept
# segment-start rather than repo-root-anchored so nested docs (packages/foo/docs/
# specs/) still resolve — check-design-document.sh arms reviews for those, so a
# narrower exemption here would refuse the write that answers the review. See
# pre-implementation-gate.sh for the full rationale; both gates share this shape.
FILE_LOWER=$(echo "$NORM_FILE" | tr '[:upper:]' '[:lower:]')
case "$FILE_LOWER" in
    # FAIL-CLOSED: normalize() returns its input unchanged when python3 is absent,
    # so a surviving `..` segment means traversal was NOT resolved. Grant no
    # exemption — fall through to the scope check rather than trust the glob.
    ../*|*/../*|*/..) ;;
    *.claude/*) exit 0 ;;
    *claude.md|*notes.md) exit 0 ;;
esac

# ── docs/ arms ────────────────────────────────────────────────────────
# Matched LEXICALLY (NORM_FILE), like the paired detector. Two known residuals,
# both SHARED with the pre-existing docs/plans and docs/reviews arms rather than new
# to docs/specs, and both needing the same repo-relative anchoring to fix:
#   1. A symlinked docs/specs -> src reads as a docs path. Not reachable through the
#      gated toolset — `ln` is a FILE_MOD command, so creating that symlink is itself
#      blocked. Resolving physically is NOT the fix: it diverges from the LEXICAL
#      detector (a legitimately symlinked docs dir would arm a review and then be
#      refused the write answering it) and it makes every path absolute, which trips
#      residual 2 and the `*.claude/*` arm above — verified, that turns the freeze
#      into a no-op and fails 9 of this file's own scope assertions.
#   2. A checkout under an ancestor named docs/specs (e.g. /srv/docs/specs/proj/)
#      matches every target. Same class as `*.claude/*` matching every file in a
#      worktree homed at <main>/.claude/worktrees/<name>/ — already a live fail-open
#      today, independent of this change.
# UPGRADE: anchor these arms to a repo-relative path (as pre-implementation-gate.sh
# does via gate_marker_relpath / ADR-E) in one change; that closes 1 and 2 together
# and lets the docs and `.claude` arms share a single resolver.
case "$FILE_LOWER" in
    docs/plans/*|*/docs/plans/*) exit 0 ;;
    docs/specs/*|*/docs/specs/*) exit 0 ;;
    docs/reviews/*|*/docs/reviews/*) exit 0 ;;
esac

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
