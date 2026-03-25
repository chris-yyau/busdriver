#!/usr/bin/env bash
# PostToolUse hook: consume codex review marker after successful git commit
#
# Deferred consumption: PreToolUse (pre-commit-gate.sh) validates the marker
# and approves the commit, but does NOT delete it. This hook runs AFTER the
# git commit completes and consumes the marker only if the commit succeeded.
#
# Why: If consumed in PreToolUse and the commit then fails (gitleaks, git
# hooks, merge conflict, nothing to commit), the marker is lost — forcing
# a full re-review for unchanged code.
#
# Success detection: checks for git's "[branch hash]" pattern OR absence of
# known failure patterns (handles --quiet mode). Marker is preserved only
# when tool_output contains explicit failure indicators.

set -euo pipefail
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if not a git commit via Bash tool
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse command, detect git commit, check output for success pattern,
# and extract target directory for worktree-aware marker lookup.
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | python3 -c "
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

    # Extract tool output text
    out = d.get('tool_output', d.get('toolOutput', {}))
    if isinstance(out, dict):
        output_text = out.get('output', '')
    elif isinstance(out, str):
        output_text = out
    else:
        output_text = ''

    # Walk command segments to find git commit and track cd/git -C
    segments = re.split(r'&&|\|\||[;\n|]', cmd)
    target_dir = ''
    is_commit = False
    for seg in segments:
        seg = seg.strip()
        cd_m = re.match(r'cd\s+(.*)', seg)
        if cd_m:
            target_dir = cd_m.group(1).strip().strip('\042\047')
            continue
        # Strip leading env var assignments
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'git\b', seg):
            words = seg.split()
            skip_next = False
            for w in words[1:]:
                if skip_next:
                    skip_next = False
                    continue
                if w in ('-C', '-c'):
                    skip_next = True
                    continue
                if w.startswith('-'):
                    continue
                is_commit = (w == 'commit')
                break
            if is_commit:
                c_m = re.search(r'-C\s+(\S+)', seg)
                if c_m:
                    target_dir = c_m.group(1).strip('\042\047')
                break

    if not is_commit:
        sys.exit(0)

    # Detect commit success using two strategies:
    # 1. Positive: git's default '[branch hash] message' output
    # 2. Negative: absence of known failure patterns (handles --quiet)
    # A commit that produces no output and no error is still a success.
    has_success_pattern = bool(re.search(r'\[[\w/.* -]+ [a-f0-9]+\]', output_text))
    failure_patterns = [
        r'nothing to commit',
        r'nothing added to commit',
        r'no changes added to commit',
        r'Aborting commit',
        r'^error:',
        r'^fatal:',
        r'hook .* failed',
    ]
    has_failure = any(re.search(p, output_text, re.MULTILINE) for p in failure_patterns)
    succeeded = has_success_pattern or (not has_failure)

    print('yes' if succeeded else 'no')
    print(target_dir)
except Exception:
    pass
" 2>/dev/null || true)

COMMIT_SUCCEEDED=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')

# Only consume if commit actually succeeded
[ "$COMMIT_SUCCEEDED" != "yes" ] && exit 0

# Resolve to git repo root (handles worktrees, subdirs)
REPO_DIR=$(git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${TARGET_DIR:-.}")

# Consume the marker — commit confirmed successful
MARKER="$REPO_DIR/.claude/codex-review-passed.local"
if [ -f "$MARKER" ]; then
    rm -f "$MARKER"

    # ── Track reviewed commit SHA for smart PR gate ───────────────────
    # Append the new commit's SHA to reviewed-commits.local so the PR
    # gate can verify all base..HEAD commits were per-commit reviewed
    # without requiring a redundant full-branch re-review.
    COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$COMMIT_SHA" ]; then
        mkdir -p "$REPO_DIR/.claude"
        echo "$COMMIT_SHA" >> "$REPO_DIR/.claude/reviewed-commits.local"
    fi
fi

# Reset circuit breaker (block counter)
rm -f ".claude/.gate-block-count.local" 2>/dev/null || true

exit 0
