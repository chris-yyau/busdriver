#!/usr/bin/env bash
# PostToolUse hook: confirm or release the pre-merge bypass claim after
# `gh pr merge` has run.
#
# Lifecycle (paired with pre-merge-gate.sh "deferred consumption" path):
#   1. PreToolUse (pre-merge-gate.sh) — sees a valid skip-pr-grind.local
#      (≥30s old, <1h), records its mtime + the merge PR number into
#      $STATE_DIR/.merge-bypass-pending.local, leaves the skip file alone,
#      allows the bash command to run.
#   2. Bash executes `gh pr merge ...`.
#   3. PostToolUse (this script) — reads tool_output and the pending claim.
#      Re-validates the skip file (must still exist, mtime must match the
#      claim, age must still satisfy the 30s anti-self-bypass at the time
#      of confirmation, and the PR number parsed from the command must
#      match the claimed PR). On confirmed success → consume skip + clear
#      pending. On any other outcome → release the pending claim and
#      preserve the skip file so the operator can retry without a re-touch.
#
# Status taxonomy (all logged to bypass-log.jsonl):
#   skip-pr-grind-consumed                — gh pr merge confirmed-merged, all
#                                           validations passed; skip file deleted
#   skip-pr-grind-released                — gh pr merge failed; skip preserved
#   skip-pr-grind-released-auto-queued    — gh pr merge --auto enabled
#                                           auto-merge but did not merge yet;
#                                           skip preserved for the eventual real
#                                           merge attempt
#   skip-pr-grind-released-ambiguous      — tool_output matched neither success
#                                           nor failure patterns; fail-safe
#   skip-pr-grind-released-tampered       — skip file disappeared, mtime
#                                           changed, or was <30s old at
#                                           confirmation time
#   skip-pr-grind-released-mismatch       — PR number parsed from the bash
#                                           command did not match the claim
#   skip-pr-grind-released-malformed      — pending file contents failed
#                                           structural validation
#   merge-bypass-stale-cleanup            — pending claim older than 5 minutes
#                                           was force-cleaned (session crash
#                                           recovery — only fires on Bash calls
#                                           that are NOT gh pr merge to avoid
#                                           swallowing real merge processing)
#
# Why deferred consumption: before this hook existed, pre-merge-gate.sh
# deleted the skip file eagerly at PreToolUse. If `gh pr merge` then failed
# at the GitHub API layer (branch not up to date, merge conflict, branch
# protection refusal), the operator had to re-touch the skip file and wait
# 30s again — wasted ceremony for a downstream failure they had nothing to
# do with. The new lifecycle moves the deletion to PostToolUse where the
# actual outcome is known.
#
# Why this scope is pre-merge-only: pre-commit-gate.sh and pre-pr-gate.sh
# do not need the same treatment because `git commit` and `gh pr create`
# fail locally before any remote side-effect — a downstream-failure window
# does not exist. `gh pr merge` is unique in that the local command can
# succeed while the GitHub API refuses to merge.

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: set by opencode adapter; CLAUDE_PLUGIN_ROOT by Claude Code.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: .opencode for opencode, .claude for Claude Code (default).
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: only process Bash tool calls
case "$HOOK_DATA" in
    *\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Shared repo-dir resolver — keep PENDING_FILE/SKIP_FILE lookup cwd-anchored,
# consistent with the pre-merge gate, so the toplevel form
# cd "$(git rev-parse --show-toplevel)" resolves the bypass files in the real
# repo instead of a junk literal path.
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# Determine whether this Bash call is the gh pr merge we may have claimed
# against, and extract the target directory (mirrors pre-merge-gate.sh's
# cd-prefix resolution so REPO_DIR is anchored to the operator's intended
# repo, not the hook process CWD — which diverges when the command is
# `cd <dir> && gh pr merge ...`). The narrower test must run before
# stale-cleanup so that a slow operator (>5 min between claim and merge)
# doesn't lose merge processing to opportunistic cleanup.
_PRE_PARSE=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json, re, os
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        print('false'); print(''); print(''); sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')
    is_merge = bool(re.search(r'\bgh\s+pr\s+merge\b', cmd))
    target_dir = ''
    for seg in re.split(r'&&|\|\||[;\n|]', cmd):
        seg = seg.strip()
        # Stop before the merge segment: a trailing cd after gh pr merge
        # must not redirect PENDING_FILE/SKIP_FILE to the wrong repository.
        if re.match(r'gh\s+pr\s+merge\b', seg):
            break
        cd_m = re.match(r'cd\s+(.*)', seg)
        if cd_m:
            raw = cd_m.group(1).strip().strip('\042\047')
            target_dir = os.path.expanduser(raw)
    print('true' if is_merge else 'false')
    print(target_dir)
    print(cwd)
except Exception:
    print('false'); print(''); print('')
" 2>/dev/null || true)
is_gh_pr_merge=$(printf '%s' "$_PRE_PARSE" | sed -n '1p')
_TARGET_DIR=$(printf '%s' "$_PRE_PARSE" | sed -n '2p')
_HOOK_CWD=$(printf '%s' "$_PRE_PARSE" | sed -n '3p')
[ -z "$is_gh_pr_merge" ] && is_gh_pr_merge=false

# Resolve repo root: cwd-anchored (mirrors pre-merge-gate.sh) so the toplevel
# cd "$(git rev-parse --show-toplevel)" form resolves the bypass files in the
# real repo; the lenient resolver falls back to the cwd/process git root.
REPO_DIR=$(gate_repo_dir_lenient "$_TARGET_DIR" "$_HOOK_CWD")
PENDING_FILE="$REPO_DIR/$STATE_DIR/.merge-bypass-pending.local"
SKIP_FILE="$REPO_DIR/$STATE_DIR/skip-pr-grind.local"
LOG_FILE="$REPO_DIR/$STATE_DIR/bypass-log.jsonl"

mkdir -p "$REPO_DIR/$STATE_DIR" 2>/dev/null || true

log_event() {
    # Args: event_name [reason]. Other fields read from CLAIMED_* globals.
    local event="$1" reason="${2:-}"
    if [ -n "$reason" ]; then
        printf '{"ts":"%s","event":"%s","gate":"post-merge","pr":"%s","claimed_at":"%s","reason":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" \
            "${CLAIMED_MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" "$reason" \
            >> "$LOG_FILE" 2>/dev/null || true
    else
        printf '{"ts":"%s","event":"%s","gate":"post-merge","pr":"%s","claimed_at":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" \
            "${CLAIMED_MERGE_PR:-unknown}" "${CLAIMED_AT:-unknown}" \
            >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Initialize claimed_* in this scope so log_event can be called pre-load.
CLAIMED_AT=""
CLAIMED_MERGE_PR=""
CLAIMED_SKIP_MTIME=""

# ── Stale-pending cleanup ────────────────────────────────────────────
# Only fires when the current Bash call is NOT gh pr merge — otherwise we
# would clean up a pending claim that the current call is about to
# confirm/release, leaving the skip file silently valid as an undetected
# bypass for up to ~58 more minutes (the pre-gate's 1-hour FILE_AGE expiry).
if [ "$is_gh_pr_merge" = "false" ] && [ -f "$PENDING_FILE" ]; then
    _PMTIME=$(stat -f %m "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=$(stat -c %Y "$PENDING_FILE" 2>/dev/null) \
        || _PMTIME=""
    if [ -n "$_PMTIME" ]; then
        _PENDING_AGE=$(( $(date +%s) - _PMTIME ))
        if [ "$_PENDING_AGE" -gt 300 ]; then
            rm -f "$PENDING_FILE"
            printf '{"ts":"%s","event":"merge-bypass-stale-cleanup","gate":"post-merge","age_sec":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_PENDING_AGE" \
                >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
fi

# If this Bash call is not gh pr merge, we are done — stale-cleanup above
# was the only legitimate action.
[ "$is_gh_pr_merge" = "false" ] && exit 0

# No pending claim → nothing for us to confirm/release. Exit silently.
[ ! -f "$PENDING_FILE" ] && exit 0

# Load claim context.
CLAIMED_AT=$(grep -E '^claimed_at=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
CLAIMED_MERGE_PR=$(grep -E '^merge_pr=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")
CLAIMED_SKIP_MTIME=$(grep -E '^skip_mtime=' "$PENDING_FILE" 2>/dev/null | head -1 | cut -d= -f2- || echo "")

# Validate claim structure before trusting any of it. The bypass log is the
# user's only audit trail; if we let unvalidated fields flow into JSONL we
# enable log-injection attacks via a forged pending file. Validate every
# field that gets logged.
_CLAIM_MALFORMED=false

# skip_mtime: required, numeric only.
case "$CLAIMED_SKIP_MTIME" in
    ''|*[!0-9]*) _CLAIM_MALFORMED=true ;;
esac

# merge_pr: numeric, or the literal "unknown" sentinel (auto-detect path).
case "$CLAIMED_MERGE_PR" in
    ''|unknown) : ;;
    *[!0-9]*) _CLAIM_MALFORMED=true ;;
esac

# claimed_at: strict ISO-8601 UTC, exactly as pre-merge-gate.sh produces via
# `date -u +%Y-%m-%dT%H:%M:%SZ`. Anything else (control chars, JSON
# fragments, attempted log-injection payloads) is rejected. Note: we
# deliberately DO NOT log the claimed_at value when releasing-malformed,
# because the malformed value is exactly what an attacker would inject.
case "$CLAIMED_AT" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) : ;;
    *) _CLAIM_MALFORMED=true ;;
esac

if [ "$_CLAIM_MALFORMED" = "true" ]; then
    rm -f "$PENDING_FILE"
    # Suppress every unvalidated field that would flow into the JSONL log.
    # Either field can carry an attacker payload; resetting both to
    # 'unknown' guarantees the malformed-event log line cannot be used to
    # inject JSON keys or break the framing of the bypass-log.jsonl.
    CLAIMED_AT="unknown"
    CLAIMED_MERGE_PR="unknown"
    log_event "skip-pr-grind-released-malformed" "pending-file-failed-structural-validation"
    exit 0
fi

# Parse the bash command + tool_output. Output two newline-separated values:
#   line 1: status   (success | auto_queued | failure | ambiguous)
#   line 2: extracted PR number (empty if not present in the command)
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
    if not re.search(r'\bgh\s+pr\s+merge\b', cmd):
        sys.exit(0)

    # Re-extract PR number from cmd (mirrors pre-merge-gate.sh logic).
    pr_num = ''
    for seg in re.split(r'&&|\|\||[;\n|]', cmd):
        seg = seg.strip()
        while re.match(r'^\w+=\S*\s', seg):
            seg = re.sub(r'^\w+=\S*\s+', '', seg, count=1)
        if re.match(r'gh\s+pr\s+merge\b', seg):
            args = re.split(r'\s+', seg)
            for a in args[3:]:  # skip 'gh', 'pr', 'merge'
                if a.startswith('-'):
                    break
                if re.match(r'^\d+$', a):
                    pr_num = a
                    break
            break

    out = d.get('tool_output', d.get('toolOutput', {}))
    if isinstance(out, dict):
        output_text = out.get('output', '')
        ec = out.get('exit_code', out.get('exitCode'))
    elif isinstance(out, str):
        output_text = out
        ec = None
    else:
        output_text = ''
        ec = None

    # AUTO-QUEUED: --auto enabled auto-merge but the PR is not yet merged.
    # The skip file must NOT be consumed (the merge has not happened).
    auto_queued_patterns = [
        r'set to auto-merge when',
        r'will be automatically merged',
        r'enabled auto-merge',
        r'Pull request .* will be merged when',
    ]
    has_auto_queued = any(re.search(p, output_text, re.MULTILINE) for p in auto_queued_patterns)

    # CONFIRMED SUCCESS: the PR is actually merged.
    success_patterns = [
        r'Squashed and merged pull request',
        r'Merged pull request',
        r'Rebased and merged pull request',
        r'\bmerged pull request #\d+',
    ]
    has_success = any(re.search(p, output_text, re.MULTILINE | re.IGNORECASE) for p in success_patterns)

    # FAILURE: explicit refusal or error.
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
    has_failure = any(re.search(p, output_text, re.MULTILINE) for p in failure_patterns)

    # Decision order:
    #   1. Explicit failure pattern wins (even if exit-code says 0; gh can
    #      print warnings on a non-fatal stderr path).
    #   2. Auto-queued without confirmed-merge → release, preserve skip.
    #      (auto-queued AND confirmed-merge is impossible in practice — gh
    #      either queues OR merges, not both — but if it ever happens,
    #      success wins.)
    #   3. Confirmed-merge pattern → success.
    #   4. Fall back to exit code: 0 with no patterns → ambiguous (fail-safe).
    #      Non-zero → failure.
    if has_failure:
        status = 'failure'
    elif has_auto_queued and not has_success:
        status = 'auto_queued'
    elif has_success:
        status = 'success'
    else:
        if ec is not None:
            try:
                status = 'ambiguous' if int(ec) == 0 else 'failure'
            except (ValueError, TypeError):
                status = 'ambiguous'
        else:
            status = 'ambiguous'

    print(status)
    print(pr_num)
except Exception:
    pass
" 2>/dev/null || true)

PARSE_STATUS=$(echo "$PARSE" | sed -n '1p')
PARSE_PR=$(echo "$PARSE" | sed -n '2p')

# Helpers — kept in this scope so they can access CLAIMED_* and log_event.
release_claim_preserving_skip() {
    # Args: event_name reason
    rm -f "$PENDING_FILE"
    log_event "$1" "$2"
}

consume_bypass() {
    rm -f "$SKIP_FILE" "$PENDING_FILE"
    log_event "skip-pr-grind-consumed"
}

case "$PARSE_STATUS" in
    success)
        # Pre-consumption validations (defense-in-depth against forgery,
        # tampering, and cross-PR token reuse). Any failure → release the
        # claim without consuming the skip file.
        #
        # Validation order matters: cheap checks first (existence), then
        # mtime tamper, then age re-check (re-applies the 30s anti-self-
        # bypass at the moment of consumption — not just at gate entry),
        # then PR equality.

        if [ ! -f "$SKIP_FILE" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-file-missing-at-confirm"
            exit 0
        fi

        _CURRENT_SKIP_MTIME=$(stat -f %m "$SKIP_FILE" 2>/dev/null \
            || stat -c %Y "$SKIP_FILE" 2>/dev/null \
            || echo "")
        if [ -z "$_CURRENT_SKIP_MTIME" ] \
            || [ "$_CURRENT_SKIP_MTIME" != "$CLAIMED_SKIP_MTIME" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-mtime-changed-between-claim-and-confirm"
            exit 0
        fi

        _SKIP_AGE=$(( $(date +%s) - _CURRENT_SKIP_MTIME ))
        if [ "$_SKIP_AGE" -lt 30 ]; then
            release_claim_preserving_skip "skip-pr-grind-released-tampered" \
                "skip-file-younger-than-30s-at-confirm"
            exit 0
        fi

        # PR equality: require BOTH sides to be concretely known and equal.
        # If either side is missing or unknown, we cannot prove the consumed
        # bypass authorizes the merged PR — preserve the skip file rather
        # than risk a cross-PR token reuse via the auto-detect path
        # (`gh pr merge` with no explicit number relies on the current
        # branch to pick a PR, and that branch can change between gate and
        # confirm without the gate noticing).
        if [ -z "$PARSE_PR" ] \
            || [ -z "$CLAIMED_MERGE_PR" ] \
            || [ "$CLAIMED_MERGE_PR" = "unknown" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-mismatch" \
                "pr-not-explicitly-known-on-claim-or-cmd-side"
            exit 0
        fi
        if [ "$PARSE_PR" != "$CLAIMED_MERGE_PR" ]; then
            release_claim_preserving_skip "skip-pr-grind-released-mismatch" \
                "claimed-pr-${CLAIMED_MERGE_PR}-but-cmd-merged-pr-${PARSE_PR}"
            exit 0
        fi

        consume_bypass
        ;;
    auto_queued)
        # gh pr merge --auto enabled auto-merge but the PR has not actually
        # merged yet (CI may still be running). Releasing the claim and
        # preserving the skip file means: the next attempt to merge (when
        # CI completes) will re-enter pre-merge-gate.sh, write a fresh
        # claim, and either consume (on real success) or release (if the
        # eventual auto-merge fails).
        release_claim_preserving_skip "skip-pr-grind-released-auto-queued" \
            "auto-merge-queued-not-yet-confirmed"
        ;;
    failure)
        release_claim_preserving_skip "skip-pr-grind-released" "merge-failed"
        ;;
    *)
        # Ambiguous output: fail-safe — release pending, preserve skip so
        # the operator can retry without a re-touch. Distinguished from the
        # plain failure path so the bypass log surfaces output-parsing gaps
        # for future tuning.
        release_claim_preserving_skip "skip-pr-grind-released-ambiguous" \
            "tool-output-matched-no-known-pattern"
        ;;
esac

exit 0
