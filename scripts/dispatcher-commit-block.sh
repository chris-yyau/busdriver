#!/usr/bin/env bash
# scripts/dispatcher-commit-block.sh - orchestrated dispatcher commit block for
# the pr-grind commit-ownership inversion. Invoked once per fix-round.
#
# Inputs (required env vars; parent dispatcher injects):
#   WORKTREE_DIR            - absolute path to worktree (cwd inside script)
#   CLAUDE_PLUGIN_ROOT      - busdriver plugin root
#   PR_NUMBER               - GitHub PR number
#   RESULT_STATUS           - "needs_more" | "clean" | "bail" (from worker)
#   RESULT_FIXES            - worker's intent statement (string)
#
# Inputs (optional env vars; default 0/empty):
#   COPILOT_AUTO_RESOLVE    - "1" enables Copilot resolve handling
#   NO_WORKTREE             - "1" inline / no-worktree mode
#   PRE_DISPATCH_BASELINE   - JSON array of paths staged before worker dispatch
#   BUSDRIVER_ALLOW_NO_COMMITLINT - "1" allows missing local commitlint
#
# Outputs (stdout):
#   Exactly one structured JSON line, either:
#   - Success: {"status":"success","result_commit_sha":"<sha>","result_reviewer_acks":"login=value,..."}
#   - Bail:    {"bail_category":"judgment|env|budget|policy","bail_reason":"<string>"}
#
# Exit code:
#   0 on success envelope; 1 on bail envelope; 2 on internal failure.

set -uo pipefail

emit_bootstrap_bail() {
    local category="${1:-judgment}"
    local reason="${2:-dispatcher-commit-block bootstrap failure}"

    jq -nc --arg c "$category" --arg r "$reason" \
        '{bail_category: $c, bail_reason: $r}'
    exit 1
}

# Required env var check must run before sourcing helpers from
# CLAUDE_PLUGIN_ROOT, because the missing-env contract itself is testable.
for var in WORKTREE_DIR CLAUDE_PLUGIN_ROOT PR_NUMBER RESULT_STATUS RESULT_FIXES; do
    if [ -z "${!var:-}" ]; then
        emit_bootstrap_bail "judgment" "dispatcher-commit-block: missing required env var $var"
    fi
done

# Resolve script lib paths.
SCRIPT_LIB="${CLAUDE_PLUGIN_ROOT}/scripts/lib"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/bail-envelope.sh" || \
    emit_bootstrap_bail "env" "dispatcher-commit-block: failed to source bail-envelope.sh"
# shellcheck source=/dev/null
. "$SCRIPT_LIB/staged-diff-hash.sh" || \
    emit_bail "env" "dispatcher-commit-block: failed to source staged-diff-hash.sh"

HUNK_PARSER="$SCRIPT_LIB/copilot-touched-lines.py"
FETCH_PR_STATE_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/fetch-pr-state.sh"
ACK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/ack-ledger.sh"
COPILOT_ELIG_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/copilot-auto-resolve-eligibility.sh"
LITMUS_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/skills/litmus/scripts"
LITMUS_STATE_FILE=".claude/litmus-state.md"

cd "$WORKTREE_DIR" || \
    emit_bail "judgment" "dispatcher-commit-block: cd to WORKTREE_DIR ($WORKTREE_DIR) failed"

# Pre-dispatch baseline guard (NO_WORKTREE mode only).
# Parent dispatcher must ensure `git diff --cached --quiet` before worker
# dispatch. This defense-in-depth check rejects any known pre-dispatch staged
# paths because the shared index cannot attribute them to worker intent.
if [ "${NO_WORKTREE:-0}" = "1" ]; then
    if [ -n "${PRE_DISPATCH_BASELINE:-}" ]; then
        baseline_count=$(printf '%s' "$PRE_DISPATCH_BASELINE" | jq -r 'length' 2>/dev/null || echo invalid)
        case "$baseline_count" in
            ''|*[!0-9]*)
                emit_bail "judgment" "inline mode received invalid PRE_DISPATCH_BASELINE JSON"
                ;;
        esac

        if [ "$baseline_count" -gt 0 ]; then
            emit_bail "judgment" "inline mode requires clean index before worker dispatch; baseline had $baseline_count staged paths"
        fi
    fi
fi

# Run dir for per-invocation artifacts (litmus output capture, etc.).
RUN_DIR=$(mktemp -d -t dispatcher-XXXXXX) || \
    emit_bail "env" "dispatcher-commit-block: mktemp failed"
trap 'rm -rf "$RUN_DIR"' EXIT

# Steps 1-12 are filled in by the remaining Phase 3 tasks.

# Placeholder success envelope. Task 3.10 replaces this with post-push state
# synthesis and authoritative ack-ledger output.
jq -nc \
    --arg sha "${RESULT_COMMIT_SHA:-none}" \
    --arg acks "${RESULT_REVIEWER_ACKS:-}" \
    '{status:"success", result_commit_sha:$sha, result_reviewer_acks:$acks}'
