#!/usr/bin/env bash
# PostToolUse hook: consume PR review marker after a successful `gh pr create`
#
# Deferred consumption: PreToolUse (pre-pr-gate.sh) validates the PR review
# marker (.claude/pr-review-passed.local) against the current base..HEAD diff
# and approves PR creation, but does NOT delete it on the hash-match path.
# This hook runs AFTER `gh pr create` completes and consumes the marker only
# if a PR was actually created.
#
# Why: If consumed in PreToolUse and `gh pr create` then fails (missing
# --body-file, network blip, bad --base, auth expiry), the marker is lost —
# forcing a full 6-agent re-review of unchanged code. This mirrors the
# deferred-consumption pattern already used by post-commit-consume-marker.sh
# for the commit gate.
#
# Success detection (positive-only, biased toward preserving the marker):
#   - exit code known   → require exit code 0 AND a PR URL
#   - exit code unknown → require a PR URL AND no known failure signature
# A failed `gh pr create` can still print a URL — notably the "already exists"
# diagnostic echoes the existing PR's URL on its own line — so a URL alone is
# never treated as proof of success. When success is not confirmed the marker
# is preserved, which is the safe direction: the marker is the SHA-256 of the
# reviewed diff and only ever re-authorizes that identical diff, and any new
# commit changes the hash and invalidates it on the next gate check.

set -euo pipefail
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if the hook data can't contain a Bash gh pr create call
case "$HOOK_DATA" in
    *\"Bash\"*gh*pr*create*) ;;
    *gh*pr*create*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse command, confirm gh pr create, detect PR-URL success in the output,
# and extract the target directory for worktree-aware marker lookup.
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re, os
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

    # Walk command segments to confirm gh pr create and track cd target dir
    segments = re.split(r'&&|\|\||[;\n|]', cmd)
    target_dir = ''
    is_pr_create = False
    for seg in segments:
        seg = seg.strip()
        cd_m = re.match(r'cd\s+(.*)', seg)
        if cd_m:
            raw = cd_m.group(1).strip().strip('\042\047')
            target_dir = os.path.expanduser(raw)
            continue
        # Strip leading env var assignments (e.g. SKIP_LITMUS=1 gh pr create)
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'gh\s+pr\s+create\b', seg):
            is_pr_create = True
            break

    if not is_pr_create:
        sys.exit(0)

    # Extract the exit code if the harness provided one (authoritative).
    exit_code = None
    if isinstance(out, dict):
        for k in ('exit_code', 'exitCode', 'returncode', 'returnCode', 'code'):
            if out.get(k) is not None:
                exit_code = out[k]
                break

    # A PR URL in the output is necessary but not sufficient: a failed
    # gh pr create can still print one (e.g. the 'already exists' diagnostic).
    # A URL is always required. When an exit code is known it must also be 0;
    # when unknown, additionally require the absence of any failure signature.
    has_pr_url = bool(re.search(r'https://github\.com/[^/]+/[^/]+/pull/\d+', output_text))
    failure_sig = bool(re.search(
        r'already exists|could not|failed to|create failed|GraphQL|HTTP [45][0-9][0-9]|must first be pushed|no commits between|^error:|^fatal:',
        output_text, re.IGNORECASE | re.MULTILINE))
    if exit_code is not None:
        try:
            succeeded = (int(exit_code) == 0) and has_pr_url
        except (TypeError, ValueError):
            succeeded = has_pr_url and not failure_sig
    else:
        succeeded = has_pr_url and not failure_sig

    print('yes' if succeeded else 'no')
    print(target_dir)
except Exception:
    pass
" 2>/dev/null || true)

PR_CREATED=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')

# Only consume if a PR was actually created
[ "$PR_CREATED" != "yes" ] && exit 0

# Resolve to git repo root (handles worktrees, subdirs)
REPO_DIR=$(git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${TARGET_DIR:-.}")

# Consume the PR review marker — PR creation confirmed successful
PR_MARKER="$REPO_DIR/.claude/pr-review-passed.local"
[ -f "$PR_MARKER" ] && rm -f "$PR_MARKER"

exit 0
