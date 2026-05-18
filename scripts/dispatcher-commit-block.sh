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

# --- Routing: RESULT_STATUS validation + non-fix-round shortcuts ---
# Known Residual #4 — the script is the single defensive entry point.
# SKILL.md routes only fix-rounds (needs_more + staged) here, but the
# script must self-validate: bail on unknown statuses, pass-through on
# clean (worker acks authoritative, no recompute), refresh acks only on
# wait-rounds (needs_more + clean index).
emit_success_no_commit() {
    jq -nc --arg acks "$1" \
        '{status:"success", result_commit_sha:"none", result_reviewer_acks:$acks}'
    exit 0
}

case "$RESULT_STATUS" in
    clean)
        emit_success_no_commit "${RESULT_REVIEWER_ACKS:-greptile-apps=none,cubic-dev-ai=none,coderabbitai=none,copilot-pull-request-reviewer=none}"
        ;;
    needs_more)
        if git diff --cached --quiet 2>/dev/null; then
            # shellcheck disable=SC1090
            if ! . "$FETCH_PR_STATE_SCRIPT" "$PR_NUMBER" 2>/dev/null \
                || [[ "${FETCH_OK:-0}" != "1" ]]; then
                emit_bail "judgment" "wait-round: post-push GitHub-state fetch failed; cannot refresh acks"
            fi
            wait_bots=(greptile-apps cubic-dev-ai coderabbitai copilot-pull-request-reviewer)
            export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA
            wait_entries=()
            for bot in "${wait_bots[@]}"; do
                ack=$(bash "$ACK_SCRIPT" "$bot" 2>/dev/null || echo "stale")
                wait_entries+=("${bot}=${ack}")
            done
            emit_success_no_commit "$(IFS=,; echo "${wait_entries[*]}")"
        fi
        ;;
    bail)
        emit_bail "judgment" "worker bail status routed through commit-block; SKILL.md should route bail directly"
        ;;
    *)
        emit_bail "judgment" "unrecognized RESULT_STATUS=${RESULT_STATUS}"
        ;;
esac

# Run dir for per-invocation artifacts (litmus output capture, etc.).
RUN_DIR=$(mktemp -d -t dispatcher-XXXXXX) || \
    emit_bail "env" "dispatcher-commit-block: mktemp failed"
trap 'rm -rf "$RUN_DIR"' EXIT

# --- Step 1: Read RESULT_FIXES (worker's intent) ---
# RESULT_FIXES is injected by the parent dispatcher.

# --- Step 2: Snapshot worker's staged content for litmus-auto-fix detection ---
# Match the marker writer's hash form exactly: bare `git diff --cached`, no
# `--binary`. The litmus marker is validated later by re-running the same form.
PRE_LITMUS_DIFF_SHA=$(git diff --cached | hash_stdin) || \
    emit_bail "env" "failed to hash pre-litmus staged diff"
PRE_LITMUS_PATHS=$(git diff --cached --name-only | sort) || \
    emit_bail "env" "failed to list pre-litmus staged paths"

# --- Step 3: Initialize litmus loop ---
bash "$LITMUS_SCRIPTS/init-review-loop.sh" || \
    emit_bail "judgment" "litmus init-review-loop.sh failed"

# --- Step 4: Invoke litmus (capture stdout + exit code) ---
# Litmus's inner loop owns review iteration. The dispatcher invokes it once per
# fix-round and bails on any non-PASS terminal status.
LITMUS_OUT="$RUN_DIR/litmus.out"

# LITMUS_SHORTCIRCUIT_DISABLED=1 is load-bearing for the pr-grind commit path:
# small staged diffs must still receive external review rather than the local
# hash-only short-circuit used by interactive litmus flows.
LITMUS_EXIT=0
set +e
LITMUS_SHORTCIRCUIT_DISABLED=1 bash "$LITMUS_SCRIPTS/run-review-loop.sh" > "$LITMUS_OUT" 2>&1
LITMUS_EXIT=$?
set -e

# --- Step 5: Litmus disambiguation + marker validation ---
# Branch on exit code first. Exit 1 is the multi-mode FAIL family and needs
# terminal_status/stdout disambiguation.
case "$LITMUS_EXIT" in
    0)
        # PASS - proceed to marker validation below.
        ;;
    2)
        emit_bail "judgment" "litmus exit 2: review budget exceeded (TOO LARGE); worker's diff is unreviewable"
        ;;
    3)
        emit_bail "judgment" "litmus exit 3: review infrastructure unavailable (BUILTIN fallback only); dispatcher requires external CLI"
        ;;
    124)
        emit_bail "judgment" "litmus exit 124: timeout (21-min cap reached); diff convergence not achieved within time budget"
        ;;
    1)
        LITMUS_STATUS=""
        if [ -f "$LITMUS_STATE_FILE" ]; then
            LITMUS_STATUS=$(grep -E '^terminal_status:' "$LITMUS_STATE_FILE" 2>/dev/null \
                | sed -E 's/^terminal_status:[[:space:]]*"?([^"]+)"?.*$/\1/' \
                | tail -n 1 || true)
        fi

        # Fallback to stdout marker matching if the structured field is absent.
        if [ -z "$LITMUS_STATUS" ]; then
            if grep -q "STALL DETECTED" "$LITMUS_OUT"; then
                LITMUS_STATUS="stall"
            elif grep -q "Max iterations" "$LITMUS_OUT"; then
                LITMUS_STATUS="max_iterations"
            elif grep -q "FAIL - Issues found" "$LITMUS_OUT"; then
                LITMUS_STATUS="review_findings"
            else
                LITMUS_STATUS="infra_failure"
            fi
        fi

        case "$LITMUS_STATUS" in
            review_findings)
                emit_bail "judgment" "litmus review_findings - dispatcher-side fix loop not yet implemented; operator must address inline"
                ;;
            stall|max_iterations|infra_failure|setup_error)
                emit_bail "judgment" "litmus exit 1 (${LITMUS_STATUS})"
                ;;
            *)
                emit_bail "judgment" "litmus exit 1: unrecognized terminal_status '$LITMUS_STATUS'"
                ;;
        esac
        ;;
    *)
        emit_bail "judgment" "litmus unrecognized exit code: $LITMUS_EXIT"
        ;;
esac

# The dispatcher must recompute and verify the marker hash itself; the
# pre-commit gate is defense-in-depth, not the only verifier.
LITMUS_MARKER=".claude/litmus-passed.local"
if [ ! -f "$LITMUS_MARKER" ]; then
    emit_bail "judgment" "litmus PASS but marker file $LITMUS_MARKER missing"
fi
MARKER_CONTENT=$(head -n 1 "$LITMUS_MARKER")

case "$MARKER_CONTENT" in
    SKIPPED-NONE*|DEGRADED*|BUILTIN-*)
        emit_bail "judgment" "external review marker rejected ($MARKER_CONTENT); pr-grind requires real external-CLI review-PASS"
        ;;
esac

if ! [[ "$MARKER_CONTENT" =~ ^[0-9a-f]{64}$ ]]; then
    emit_bail "judgment" "marker is not a valid 64-char SHA-256 hex string: '$MARKER_CONTENT'"
fi

EXPECTED_HASH=$(git diff --cached | hash_stdin) || \
    emit_bail "env" "failed to hash post-litmus staged diff"
if [ "$MARKER_CONTENT" != "$EXPECTED_HASH" ]; then
    emit_bail "judgment" "marker/staged-diff hash mismatch (marker=$MARKER_CONTENT vs computed=$EXPECTED_HASH); marker may be stale or the staged diff was mutated post-PASS"
fi

# --- Step 6: Commit message composition + commit-type derivation ---
POST_LITMUS_DIFF_SHA=$(git diff --cached | hash_stdin) || \
    emit_bail "env" "failed to hash post-litmus staged diff for commit message"
POST_LITMUS_PATHS=$(git diff --cached --name-only | sort) || \
    emit_bail "env" "failed to list post-litmus staged paths"

# Derive commit type from RESULT_FIXES without adding a protocol tag.
RESULT_COMMIT_TYPE="fix"
case "$RESULT_FIXES" in
    *"add test"*|*"test coverage"*)                   RESULT_COMMIT_TYPE="test" ;;
    *"update doc"*|*"docs"*|*"comment"*|*"README"*)   RESULT_COMMIT_TYPE="docs" ;;
    *"refactor"*|*"rename"*|*"extract"*|*"simplify"*) RESULT_COMMIT_TYPE="refactor" ;;
    *"perf"*|*"optimization"*)                        RESULT_COMMIT_TYPE="perf" ;;
    *"chore"*|*"bump"*|*"upgrade"*|*"version"*)       RESULT_COMMIT_TYPE="chore" ;;
esac

set +e
{
    printf '%s: address PR #%s feedback\n' "$RESULT_COMMIT_TYPE" "$PR_NUMBER"
    printf '\n%s\n' "$RESULT_FIXES"
    if [ "$POST_LITMUS_DIFF_SHA" != "$PRE_LITMUS_DIFF_SHA" ]; then
        added_paths=$(comm -13 \
            <(printf '%s\n' "$PRE_LITMUS_PATHS") \
            <(printf '%s\n' "$POST_LITMUS_PATHS") \
            | tr '\n' ' ' \
            | sed 's/ $//')
        printf '\nLitmus-Auto-Fix: %s\n' "${added_paths:-content-only-edits}"
    fi
} | git commit -F -
GIT_COMMIT_EXIT=$?
set -e

if [ "$GIT_COMMIT_EXIT" != "0" ]; then
    emit_bail "judgment" "git commit failed (exit $GIT_COMMIT_EXIT)"
fi

# --- Step 7: Pre-commit gate + post-commit hook ---
# The repository hooks run as part of `git commit`; the post-commit hook consumes
# the litmus marker after the pre-commit gate accepts it.

# --- Step 8: Local commitlint pre-flight with missing-binary policy ---
if command -v npx >/dev/null 2>&1 && npx --no-install commitlint --version >/dev/null 2>&1; then
    if ! git log -1 --format=%B | npx --no-install commitlint; then
        emit_bail "judgment" "commitlint pre-flight failed on HEAD; amend locally and re-grind"
    fi
else
    if [ "${BUSDRIVER_ALLOW_NO_COMMITLINT:-0}" != "1" ]; then
        emit_bail "env" "local commitlint unavailable; install as devDep or set BUSDRIVER_ALLOW_NO_COMMITLINT=1 to proceed"
    fi
fi

# --- Step 9: Pre-push SHA synthesis ---
NEW_COMMIT_SHA=$(git rev-parse HEAD) || \
    emit_bail "env" "failed to resolve HEAD after dispatcher commit"
RESULT_COMMIT_SHA="$NEW_COMMIT_SHA"

# --- Step 10: Checked push ---
set +e
push_output=$(git push 2>&1)
push_exit=$?
set -e

if [ "$push_exit" != "0" ]; then
    case "$push_output" in
        *Authentication*|*"could not resolve"*|*network*|*timeout*)
            emit_bail "env" "git push auth/network: $(printf '%s\n' "$push_output" | tail -n 3)"
            ;;
        *non-fast-forward*|*rejected*|*history*)
            emit_bail "judgment" "git push non-fast-forward; local commit preserved"
            ;;
        *)
            emit_bail "judgment" "git push failed: $(printf '%s\n' "$push_output" | tail -n 3)"
            ;;
    esac
fi

# --- Step 11: Copilot stale-thread auto-resolve ---
if [ "${COPILOT_AUTO_RESOLVE:-0}" = "1" ]; then
    nwo=$(gh repo view --json nameWithOwner -q '.nameWithOwner') || \
        emit_bail "judgment" "Copilot auto-resolve: gh repo view failed"
    owner="${nwo%/*}"
    name="${nwo#*/}"

    # shellcheck disable=SC2016
    COPILOT_FETCH=$(gh api graphql \
        -F number="$PR_NUMBER" -F owner="$owner" -F name="$name" \
        -f query='query($number:Int!,$owner:String!,$name:String!){
            repository(owner:$owner,name:$name){
              pullRequest(number:$number){
                baseRefOid
                reviews(first:100){nodes{author{login} commit{oid}}}
                reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:1){nodes{author{login}}}}}
              }
            }
          }' 2>/dev/null) || emit_bail "judgment" "Copilot GraphQL fetch failed"

    COPILOT_COMMIT_ID=$(printf '%s' "$COPILOT_FETCH" | jq -r '
        [.data.repository.pullRequest.reviews.nodes[]
         | select(.author.login == "copilot-pull-request-reviewer"
               or .author.login == "copilot-pull-request-reviewer[bot]")]
        | last | .commit.oid // empty') || \
        emit_bail "judgment" "Copilot review commit extraction failed"

    if [ -n "$COPILOT_COMMIT_ID" ] && ! git merge-base --is-ancestor "$COPILOT_COMMIT_ID" HEAD 2>/dev/null; then
        FORCE_PUSH_DETECTED=1
    else
        FORCE_PUSH_DETECTED=0
    fi
    export FORCE_PUSH_DETECTED RESULT_FIXES RESULT_COMMIT_SHA

    COPILOT_THREADS_JSON=$(printf '%s' "$COPILOT_FETCH" | jq -c '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.comments.nodes[0].author.login == "copilot-pull-request-reviewer"
               or .comments.nodes[0].author.login == "copilot-pull-request-reviewer[bot]")
         | select(.isResolved == false and .isOutdated == false)
         | {threadId: .id, path: .path, line: .line}]') || \
        emit_bail "judgment" "Copilot thread extraction failed"
    export COPILOT_THREADS_JSON

    BASE_OID=$(printf '%s' "$COPILOT_FETCH" | jq -r '.data.repository.pullRequest.baseRefOid // empty') || \
        emit_bail "judgment" "Copilot base OID extraction failed"
    if [ -z "$BASE_OID" ]; then
        emit_bail "judgment" "Copilot base OID missing from GraphQL response"
    fi

    HEAD_TOUCHED_LINES_JSON=$(git diff "$BASE_OID..HEAD" -U0 2>/dev/null | python3 "$HUNK_PARSER") || \
        emit_bail "judgment" "Copilot touched-line parsing failed"
    export HEAD_TOUCHED_LINES_JSON

    ELIG_JSON=$(bash "$COPILOT_ELIG_SCRIPT") || \
        emit_bail "judgment" "Copilot eligibility helper failed"
    if [ "$(printf '%s' "$ELIG_JSON" | jq -r '.decision')" = "resolve" ]; then
        while IFS= read -r thread; do
            tid=$(printf '%s' "$thread" | jq -r '.threadId') || \
                emit_bail "judgment" "Copilot thread id extraction failed"
            # shellcheck disable=SC2016
            gh api graphql -F threadId="$tid" -F body="Addressed in $NEW_COMMIT_SHA" \
                -f query='mutation($threadId:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId,body:$body}){comment{id}}}' >/dev/null || \
                emit_bail "judgment" "Copilot thread reply failed"
            # shellcheck disable=SC2016
            gh api graphql -F threadId="$tid" \
                -f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{id}}}' >/dev/null || \
                emit_bail "judgment" "Copilot thread resolve failed"
        done < <(printf '%s' "$COPILOT_THREADS_JSON" | jq -c '.[]')
    fi
fi

# --- Step 12: Post-push GitHub state synthesis ---
# shellcheck disable=SC1090
if ! . "$FETCH_PR_STATE_SCRIPT" "$PR_NUMBER"; then
    emit_bail "judgment" "post-push GitHub-state helper failed"
fi

if [ "${FETCH_OK:-0}" != "1" ]; then
    emit_bail "judgment" "post-push GitHub-state fetch failed; ack ledger cannot be computed"
fi

REGISTERED_ACK_BOTS=(greptile-apps cubic-dev-ai coderabbitai copilot-pull-request-reviewer)
export FETCH_OK ALL_THREADS ALL_REVIEWS ALL_COMMENTS ALL_CHECK_RUNS HEAD_SHA

reviewer_ack_entries=()
for bot in "${REGISTERED_ACK_BOTS[@]}"; do
    ack=$(bash "$ACK_SCRIPT" "$bot" 2>/dev/null || echo "stale")
    reviewer_ack_entries+=("${bot}=${ack}")
done
RESULT_REVIEWER_ACKS=$(IFS=,; echo "${reviewer_ack_entries[*]}")

jq -nc \
    --arg sha "$RESULT_COMMIT_SHA" \
    --arg acks "$RESULT_REVIEWER_ACKS" \
    '{status:"success", result_commit_sha:$sha, result_reviewer_acks:$acks}'
