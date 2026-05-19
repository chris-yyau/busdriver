#!/usr/bin/env bash
# PostToolUse hook: confirm or release the pre-merge bypass claim after
# `gh pr merge` has run.
#
# Lifecycle (paired with pre-merge-gate.sh "deferred consumption" path):
#   1. PreToolUse (pre-merge-gate.sh) — sees a valid skip-pr-grind.local,
#      writes .claude/.merge-bypass-pending.local, leaves the skip file in
#      place, allows the bash command to run.
#   2. Bash executes `gh pr merge ...`.
#   3. PostToolUse (this script) — reads tool_output:
#        - on confirmed success → consume the skip file (rm) + remove pending
#          file + log skip-pr-grind-consumed (the historical event name).
#        - on confirmed failure → leave the skip file (still valid for next
#          attempt) + remove pending file + log skip-pr-grind-released.
#        - on ambiguous output (no clear success/failure signal) → treat as
#          failure for safety (leave skip file) and log released-ambiguous.
#
# Why deferred consumption: before this hook existed, pre-merge-gate.sh
# deleted the skip file eagerly. If `gh pr merge` then failed at the GitHub
# API layer (branch not up to date, merge conflict, permissions), the
# operator had to re-touch the skip file and wait 30s again — wasted
# ceremony for a downstream failure they had nothing to do with.
#
# Stale-pending cleanup: if .merge-bypass-pending.local is older than
# 5 minutes when we see ANY bash call, we force-cleanup. That covers the
# pathological case where the gate-pass tool result somehow never reaches
# this hook (e.g., session crash mid-merge, hook timeout).

set -euo pipefail
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: only process Bash tool calls
case "$HOOK_DATA" in
    *\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Resolve repo root (handle worktrees + subdir cd).
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
PENDING_FILE="$REPO_DIR/.claude/.merge-bypass-pending.local"
SKIP_FILE="$REPO_DIR/.claude/skip-pr-grind.local"
LOG_FILE="$REPO_DIR/.claude/bypass-log.jsonl"

# Stale-pending cleanup (5 min). Runs on every Bash post-call so a crashed
# session does not leave a permanent stale claim.
if [ -f "$PENDING_FILE" ]; then
    _PMTIME=$(stat -f %m "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=$(stat -c %Y "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=""
    if [ -n "$_PMTIME" ]; then
        _PAGE=$(( $(date +%s) - _PMTIME ))
        if [ "$_PAGE" -gt 300 ]; then
            rm -f "$PENDING_FILE"
            printf '{"ts":"%s","event":"merge-bypass-stale-cleanup","gate":"post-merge","age_sec":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_PAGE" \
                >> "$LOG_FILE" 2>/dev/null || true
            exit 0
        fi
    fi
fi

# Narrow to `gh pr merge` specifically — only that command can consume the
# bypass token we wrote at PreToolUse. Any other Bash call that fires the
# PostToolUse hook (including a `gh pr view` that happens between gate and
# real merge) must leave the pending file alone.
case "$HOOK_DATA" in
    *gh*pr*merge*) ;;
    *) exit 0 ;;
esac

# No pending claim → nothing to confirm/release. Exit silently.
[ ! -f "$PENDING_FILE" ] && exit 0

# Parse tool_output: gh pr merge success/failure signals.
PARSE=$(printf '%s' "$HOOK_DATA" | python3 -c "
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
    # Must contain 'gh pr merge' (allow flags between gh/pr/merge tokens)
    if not re.search(r'\bgh\s+pr\s+merge\b', cmd):
        sys.exit(0)

    out = d.get('tool_output', d.get('toolOutput', {}))
    if isinstance(out, dict):
        output_text = out.get('output', '')
        if 'exit_code' in out:
            exit_code = out.get('exit_code')
        elif 'exitCode' in out:
            exit_code = out.get('exitCode')
        else:
            exit_code = None
    elif isinstance(out, str):
        output_text = out
        exit_code = None
    else:
        output_text = ''
        exit_code = None

    # Success signals (gh pr merge confirmed-merged or auto-queued):
    success_patterns = [
        r'Squashed and merged',
        r'Merged pull request',
        r'Rebased and merged',
        r'merge[d]? pull request',
        r'set to auto-merge when',
        r'Pull request .* will be automatically merged',
        r'enabled auto-merge',
    ]
    # Failure signals (gh pr merge could not complete):
    failure_patterns = [
        r'not mergeable',
        r'^error:',
        r'^fatal:',
        r'GraphQL:',
        r'X Pull request',
        r'failed to merge',
        r'merge conflict',
        r'required status check',
        r'CHECKS_FAILED',
        r'cannot be merged',
    ]

    has_success = any(re.search(p, output_text, re.MULTILINE) for p in success_patterns)
    has_failure = any(re.search(p, output_text, re.MULTILINE) for p in failure_patterns)

    # Exit code takes priority when present
    if exit_code is not None:
        try:
            ec = int(exit_code)
            if ec == 0 and not has_failure:
                print('success')
                sys.exit(0)
            if ec != 0:
                print('failure')
                sys.exit(0)
        except (ValueError, TypeError):
            pass

    if has_success and not has_failure:
        print('success')
    elif has_failure:
        print('failure')
    else:
        # No clear signal — fail-safe (preserve skip file, log ambiguous)
        print('ambiguous')
except Exception:
    pass
" 2>/dev/null || true)

# Read pending-file context for telemetry (best-effort).
CLAIMED_AT=""
MERGE_PR=""
if [ -f "$PENDING_FILE" ]; then
    CLAIMED_AT=$(grep -E '^claimed_at=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
    MERGE_PR=$(grep -E '^merge_pr=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
fi

case "$PARSE" in
    success)
        # Consume skip file + clear pending claim. Log final consumption.
        rm -f "$SKIP_FILE" "$PENDING_FILE"
        mkdir -p "$REPO_DIR/.claude"
        printf '{"ts":"%s","event":"skip-pr-grind-consumed","gate":"post-merge","pr":"%s","claimed_at":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" \
            >> "$LOG_FILE" 2>/dev/null || true
        ;;
    failure)
        # Release the claim: leave skip file alone so the operator can retry
        # without re-touching it.
        rm -f "$PENDING_FILE"
        mkdir -p "$REPO_DIR/.claude"
        printf '{"ts":"%s","event":"skip-pr-grind-released","gate":"post-merge","pr":"%s","reason":"merge-failed","claimed_at":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" \
            >> "$LOG_FILE" 2>/dev/null || true
        ;;
    *)
        # Ambiguous output: prefer fail-safe (leave skip file). Same release
        # behaviour as the failure path, but with a different event so the
        # bypass log surfaces output-parsing gaps for future tuning.
        rm -f "$PENDING_FILE"
        mkdir -p "$REPO_DIR/.claude"
        printf '{"ts":"%s","event":"skip-pr-grind-released-ambiguous","gate":"post-merge","pr":"%s","claimed_at":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" \
            >> "$LOG_FILE" 2>/dev/null || true
        ;;
esac

exit 0
