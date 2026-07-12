#!/usr/bin/env bash
# PostToolUse hook: consume PR review marker after a successful `gh pr create`
#
# Deferred consumption: PreToolUse (pre-pr-gate.sh) validates the PR review
# marker ($STATE_DIR/pr-review-passed.local) against the current base..HEAD diff
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
#   - require a PR URL in the output (host-agnostic — github.com or GHES)
#   - require NO known failure signature, honored even when exit code is 0
#     (a compound command like `gh pr create --fill || true` exits 0 even when
#     gh failed and only printed the "already exists: <url>" diagnostic, so the
#     exit code alone cannot be trusted — the failure signature still must clear)
#   - require exit code 0 when the harness reports one
# A failed `gh pr create` can still print a URL — notably the "already exists"
# diagnostic echoes the existing PR's URL on its own line — so a URL alone is
# never treated as proof of success. When success is not confirmed the marker
# is preserved, which is the safe direction: the marker is the SHA-256 of the
# reviewed diff and only ever re-authorizes that identical diff, and any new
# commit changes the hash and invalidates it on the next gate check.

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: plugin-root override; falls back to CLAUDE_PLUGIN_ROOT.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) and
# re-export so every gate writes/consumes markers from the same state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if the hook data can't contain a Bash gh pr create call
case "$HOOK_DATA" in
    *\"Bash\"*gh*pr*create*) ;;
    *gh*pr*create*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Shared repo-dir resolver — keep marker lookup cwd-anchored, consistent with
# the pre-PR gate, so the toplevel form cd "$(git rev-parse --show-toplevel)"
# consumes its marker in the real repo instead of a junk literal path.
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# Parse command, confirm gh pr create, detect PR-URL success in the output,
# and extract the target directory for worktree-aware marker lookup.
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a repo-
# controlled gitcmd_detect.py or shadowed stdlib (json.py) cannot run in the gate.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json, re
    from gitcmd_detect import gh_pr
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
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

    # Confirm a real gh pr create via the shared command-word detector.
    is_pr_create, target_dir, _pr = gh_pr(cmd, 'create')

    if not is_pr_create:
        sys.exit(0)

    # Extract the exit code if the harness provided one (authoritative).
    exit_code = None
    if isinstance(out, dict):
        for k in ('exit_code', 'exitCode', 'returncode', 'returnCode', 'code'):
            if out.get(k) is not None:
                exit_code = out[k]
                break

    # PR URL — host-agnostic (github.com OR GitHub Enterprise / custom hosts),
    # so a successful PR creation on GHES is not misclassified and left
    # unconsumed by a hardcoded github.com match.
    has_pr_url = bool(re.search(r'https?://[^/\s]+/[^/\s]+/[^/\s]+/pull/\d+', output_text))
    # Failure signatures are honored UNCONDITIONALLY — including when exit code
    # is 0 — because a compound command can mask gh's real exit status (e.g.
    # 'gh pr create --fill || true' exits 0 even when gh failed and only printed
    # the 'already exists: <url>' diagnostic). Without this, exit 0 + URL would
    # wrongly consume the marker.
    failure_sig = bool(re.search(
        r'already exists|could not|failed to|create failed|GraphQL|HTTP [45][0-9][0-9]|must first be pushed|no commits between|^error:|^fatal:',
        output_text, re.IGNORECASE | re.MULTILINE))
    # Exit code, when the harness reports one, must be 0; unknown/unparseable
    # falls back to the URL + failure-signature signals above.
    if exit_code is not None:
        try:
            exit_ok = int(exit_code) == 0
        except (TypeError, ValueError):
            exit_ok = True
    else:
        exit_ok = True
    succeeded = has_pr_url and exit_ok and not failure_sig

    print('yes' if succeeded else 'no')
    print(target_dir)
    print(cwd)
except Exception:
    pass
" 2>/dev/null || true)

PR_CREATED=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '3p')

# Only consume if a PR was actually created
[ "$PR_CREATED" != "yes" ] && exit 0

# Resolve to git repo root (cwd-anchored, consistent with the pre-PR gate so the
# toplevel cd "$(git rev-parse --show-toplevel)" form consumes the marker in the
# real repo, not a junk literal path; handles worktrees, subdirs).
REPO_DIR=$(gate_repo_dir_lenient "$TARGET_DIR" "$HOOK_CWD")

# Consume the PR review marker — PR creation confirmed successful.
# Also remove the two diff-bound dual-voice artifacts so a later PR on a changed
# diff cannot be authorized by a leftover PASS (max-age guards them too, but
# eager cleanup keeps the state dir honest). Only runs after `gh pr create`
# succeeded; a failed gh leaves all three in place for a retry.
PR_MARKER="$REPO_DIR/$STATE_DIR/pr-review-passed.local"
[ -f "$PR_MARKER" ] && rm -f "$PR_MARKER"
rm -f "$REPO_DIR/$STATE_DIR/pr-codex-lead.local.json" \
      "$REPO_DIR/$STATE_DIR/pr-backstop-verdict.local.json" 2>/dev/null || true

exit 0
