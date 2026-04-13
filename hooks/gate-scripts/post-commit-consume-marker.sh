#!/usr/bin/env bash
# PostToolUse hook: consume codex review marker after successful git commit
#
# Deferred consumption: PreToolUse (pre-commit-gate.sh) validates the marker
# and approves the commit, but does NOT delete it. This hook runs AFTER the
# git commit completes and consumes the marker only if the commit succeeded.
#
# Why: If consumed in PreToolUse and the commit then fails (git hooks,
# merge conflict, nothing to commit, errors), the marker is lost — forcing
# a full re-review for unchanged code.
#
# Success detection: checks for git's "[branch hash]" pattern OR absence of
# known failure patterns (handles --quiet mode). Marker is preserved only
# when tool_output contains explicit failure indicators.

set -euo pipefail
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if not a Bash tool call involving git
case "$HOOK_DATA" in
    *\"Bash\"*git*) ;;
    *git*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# ── Rebase/amend detection: invalidate reviewed-commits on SHA change ──
# Rebasing or amending changes commit SHAs, making the tracking file stale.
# Only fires after confirming this is a Bash tool call (not Write/Edit with
# "git rebase" in file content). Uses the raw Bash command text.
case "$HOOK_DATA" in
    *git*rebase*|*git*commit*--amend*)
        REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
        REVIEWED_FILE="$REPO_DIR/.claude/reviewed-commits.local"
        if [ -f "$REVIEWED_FILE" ]; then
            rm -f "$REVIEWED_FILE"
        fi
        ;;
esac

# Narrow to git commit specifically (not rebase-only or other git commands)
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
MARKER="$REPO_DIR/.claude/litmus-passed.local"
if [ -f "$MARKER" ]; then
    MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")
    rm -f "$MARKER"

    # SKIPPED-NONE: not reviewed at all — exclude from reviewed-commits.local
    if echo "$MARKER_CONTENT" | grep -q "^SKIPPED-NONE"; then
        # Already logged by litmus run-review-loop.sh, but duplicate here
        # so post-commit bypass-log is a complete record of every commit
        COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
        printf '{"ts":"%s","event":"review-skipped-none","gate":"post-commit","sha":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT_SHA:-unknown}" \
            >> "$REPO_DIR/.claude/bypass-log.jsonl" 2>/dev/null || true
        # Reset circuit breaker and exit — do not track as reviewed
        rm -f "$REPO_DIR/.claude/.gate-block-count.local" 2>/dev/null || true
        exit 0
    fi

    # BUILTIN: self-reviewed by Claude — exclude from reviewed-commits.local
    # Rationale: The PR gate smart path (pre-pr-gate.sh) skips multi-voice
    # PR review when all commits are in reviewed-commits.local. Builtin
    # self-review should NOT qualify for this shortcut — the PR deep review
    # is the real guard against self-review gaps.
    if echo "$MARKER_CONTENT" | grep -q "^BUILTIN-"; then
        # Log for audit visibility — builtin acceptance was previously silent
        COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
        printf '{"ts":"%s","event":"builtin-review-accepted","gate":"post-commit","sha":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT_SHA:-unknown}" \
            >> "$REPO_DIR/.claude/bypass-log.jsonl" 2>/dev/null || true
        # Reset circuit breaker and exit — do not track as reviewed
        rm -f "$REPO_DIR/.claude/.gate-block-count.local" 2>/dev/null || true
        exit 0
    fi

    # ── Track reviewed commit SHA for smart PR gate ───────────────────
    # Append the new commit's SHA with branch context to reviewed-commits.local
    # so the PR gate can verify all base..HEAD commits were per-commit reviewed
    # without requiring a redundant full-branch re-review.
    # Format: "branch:sha" — branch-scoped to prevent cross-branch carry-over
    # (e.g., a SHA reviewed on branch A shouldn't count on branch B after cherry-pick)
    COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
    CURRENT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "detached")
    if [ -n "$COMMIT_SHA" ] && [ "$CURRENT_BRANCH" != "detached" ]; then
        mkdir -p "$REPO_DIR/.claude"
        echo "${CURRENT_BRANCH}:${COMMIT_SHA}" >> "$REPO_DIR/.claude/reviewed-commits.local"
    fi
else
    # ── Unreviewed commit detection ──────────────────────────────────
    # No marker found after a successful commit. This means the PreToolUse
    # gate (pre-commit-gate.sh) did not block the commit — either because
    # hooks failed to fire (intermittent Claude Code platform issue) or
    # a skip file was consumed by the gate (already logged separately).
    # Log for audit visibility so the gap is not silent.
    #
    # Suppressed when:
    #   - skip-review-consumed was logged in the last 120s (gate ran, used skip file)
    #   - ~/.claude repo with only auto-generated files (gate bypasses by design)
    _SUPPRESS=false

    # Check if a skip was recently consumed (skip file is deleted by the gate
    # before commit runs, so we check the bypass log instead).
    # Compare timestamps to avoid stale entries suppressing real warnings.
    if [ -f "$REPO_DIR/.claude/bypass-log.jsonl" ]; then
        _CUTOFF=$(date -u -v-120S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _CUTOFF=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _CUTOFF=""
        if [ -n "$_CUTOFF" ]; then
            _LAST_SKIP_TS=$(tail -5 "$REPO_DIR/.claude/bypass-log.jsonl" \
                | grep '"event":"skip-review-consumed"' \
                | tail -1 \
                | python3 -c "import sys,json; print(json.loads(sys.stdin.readline()).get('ts',''))" 2>/dev/null \
                || true)
            # ISO timestamps are lexicographically ordered — string compare works
            if [ -n "$_LAST_SKIP_TS" ] && [[ "$_LAST_SKIP_TS" > "$_CUTOFF" ]]; then
                _SUPPRESS=true
            fi
        fi
    fi

    # ~/.claude repo: only suppress if all staged files were auto-generated
    # (mirrors the scoped bypass in pre-commit-gate.sh)
    if [ "$REPO_DIR" = "$HOME/.claude" ]; then
        _SUPPRESS=true
    fi

    if [ "$_SUPPRESS" = false ]; then
        COMMIT_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
        mkdir -p "$REPO_DIR/.claude"
        printf '{"ts":"%s","event":"unreviewed-commit","gate":"post-commit","sha":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT_SHA:-unknown}" \
            >> "$REPO_DIR/.claude/bypass-log.jsonl" 2>/dev/null || true
        echo "⚠️  Commit ${COMMIT_SHA:0:7} was not reviewed by litmus (PreToolUse gate did not fire)." >&2
    fi
fi

# Reset circuit breaker (block counter)
rm -f "$REPO_DIR/.claude/.gate-block-count.local" 2>/dev/null || true

exit 0
