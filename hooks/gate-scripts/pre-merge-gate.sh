#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr merge` on pr-grind completion
#
# Blocks PR merge until pr-grind has declared the PR clean.
# This ensures reviewer feedback is addressed before merge,
# regardless of which skill the agent loaded.
#
# Fail-CLOSED: errors block merge (user preference: stuck > skipped grind)
# Skip: .claude/skip-pr-grind.local or SKIP_PR_GRIND=1

set -euo pipefail
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-merge gate error — blocking as precaution. If stuck, create .claude/skip-pr-grind.local in your terminal.\"}\n"; exit 0' ERR

# ── Block emission helper ─────────────────────────────────────────────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    else
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/"/\\"/g' | head -c 2000)
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── python3 pre-check ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    block_emit "CRITICAL: python3 not found. Pre-merge gate requires python3 for JSON parsing. Install python3 to restore gate enforcement."
    exit 0
fi

# Consume stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if hook data doesn't look like it could contain gh pr merge
case "$HOOK_DATA" in
    *\"Bash\"*gh\ pr\ merge*) ;;
    *gh\ pr\ merge*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse tool name and command, verify gh pr merge
IS_GH_PR_MERGE=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    segments = re.split(r'&&|\|\||[;\n|]', cmd)
    for seg in segments:
        seg = seg.strip()
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'gh\s+pr\s+merge\b', seg):
            print('yes')
            break
except Exception:
    print('error')
" 2>/dev/null || true)

[ -z "$IS_GH_PR_MERGE" ] && exit 0

# Fail-closed: parser error after fast pre-filter matched → block as precaution
if [ "$IS_GH_PR_MERGE" = "error" ]; then
    block_emit "Pre-merge gate: failed to parse tool input for command matching gh pr merge pattern. Blocking as precaution (fail-closed). If stuck, create .claude/skip-pr-grind.local in your terminal."
    exit 0
fi

[ "$IS_GH_PR_MERGE" != "yes" ] && exit 0

# ── Skip overrides ────────────────────────────────────────────────────

# Env var override
if [ "${SKIP_PR_GRIND:-}" = "1" ]; then
    echo '{"decision":"approve"}' >&2 2>/dev/null || true
    exit 0
fi

# File-based skip (shared pattern with litmus)
if [ -f ".claude/skip-pr-grind.local" ]; then
    FILE_AGE=999
    _MTIME=$(stat -f %m ".claude/skip-pr-grind.local" 2>/dev/null) \
        || _MTIME=$(stat -c %Y ".claude/skip-pr-grind.local" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))

    if [ "$FILE_AGE" -lt 3600 ]; then
        exit 0
    else
        rm -f ".claude/skip-pr-grind.local"
    fi
fi

# ── Check for pr-grind-clean marker ──────────────────────────────────
# pr-grind writes .claude/pr-grind-clean.local when it declares a PR clean.
# Marker expires after 2 hours (stale marker from a different PR session).
if [ -f ".claude/pr-grind-clean.local" ]; then
    MARKER_AGE=99999
    _MTIME=$(stat -f %m ".claude/pr-grind-clean.local" 2>/dev/null) \
        || _MTIME=$(stat -c %Y ".claude/pr-grind-clean.local" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && MARKER_AGE=$(( $(date +%s) - _MTIME ))

    if [ "$MARKER_AGE" -lt 7200 ]; then
        # Marker is fresh — pr-grind completed recently
        exit 0
    else
        # Stale marker — remove and require fresh grind
        rm -f ".claude/pr-grind-clean.local"
    fi
fi

# ── BLOCK: no pr-grind-clean marker found ────────────────────────────
block_emit "Pre-merge gate: pr-grind has not declared this PR clean. Run \`/pr-grind\` to address reviewer feedback before merging. Escape hatch: create .claude/skip-pr-grind.local in your terminal."
exit 0
