#!/bin/bash
# Initialize codex review loop state file
# Follows Ralph Loop pattern for robust state management

set -euo pipefail

# Parse arguments
FORCE=false
POSITIONAL_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        *) POSITIONAL_ARGS+=("$arg") ;;
    esac
done
MAX_ITERATIONS="${POSITIONAL_ARGS[0]:-10}"
COMPLETION_PROMISE="${POSITIONAL_ARGS[1]:-null}"

# Validate max iterations
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERATIONS" -lt 1 ]; then
    echo "❌ Error: MAX_ITERATIONS must be a positive integer" >&2
    echo "   Usage: $0 [--force] [max_iterations] [completion_promise]" >&2
    echo "   Example: $0 10" >&2
    echo "   Example: $0 10 \"REVIEW PASSED\"" >&2
    exit 1
fi

# Source iteration history library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/iteration-history.sh
source "$SCRIPT_DIR/lib/iteration-history.sh"

# Guard: prevent re-init while a review loop is active
STATE_FILE=".claude/codex-review-state.md"
if [ "$FORCE" != "true" ] && [ -f "$STATE_FILE" ]; then
    # Source validation library for get_yaml_value
    # shellcheck source=lib/validation.sh
    source "$SCRIPT_DIR/lib/validation.sh"
    EXISTING_ACTIVE=$(get_yaml_value "active" "$STATE_FILE" 2>/dev/null || echo "false")
    if [ "$EXISTING_ACTIVE" = "true" ]; then
        EXISTING_ITER=$(get_yaml_value "iteration" "$STATE_FILE" 2>/dev/null || echo "?")
        EXISTING_MAX=$(get_yaml_value "max_iterations" "$STATE_FILE" 2>/dev/null || echo "?")
        echo "⚠️  Active review loop already exists (iteration $EXISTING_ITER/$EXISTING_MAX)" >&2
        echo "   Re-initializing would reset the iteration counter!" >&2
        echo "" >&2
        echo "   To continue the existing loop:" >&2
        echo "     bash $SCRIPT_DIR/run-review-loop.sh" >&2
        echo "" >&2
        echo "   To force re-init (resets counter):" >&2
        echo "     $0 --force $MAX_ITERATIONS" >&2
        exit 1
    fi
fi

# Clear any previous iteration history
clear_iteration_history

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not a git repository" >&2
    echo "   Run this script from within a git repository" >&2
    exit 1
fi

# Create .claude directory if it doesn't exist
mkdir -p .claude

# Get current timestamp in ISO 8601 format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine review mode (commit vs PR)
REVIEW_MODE="${CODEX_REVIEW_MODE:-commit}"

# Detect base branch for PR mode
if [ "$REVIEW_MODE" = "pr" ]; then
  PR_BASE_BRANCH="${CODEX_PR_BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")}"
fi

# Create state file with YAML frontmatter
if [ "$REVIEW_MODE" = "pr" ]; then
cat > .claude/codex-review-state.md <<'EOF'
---
active: true
iteration: 1
max_iterations: MAX_ITERATIONS_PLACEHOLDER
completion_promise: COMPLETION_PROMISE_PLACEHOLDER
review_mode: "pr"
review_status: "PENDING"
started_at: "TIMESTAMP_PLACEHOLDER"
last_result: null
---

You are a code reviewer. Review the following FULL BRANCH DIFF (base..HEAD). This is an aggregate review of all changes on this branch before PR creation.

CHANGELOG FROM PREVIOUS TASK:
{{PREV_CHANGELOG}}

BRANCH CHANGES TO REVIEW:
{{STAGED_DIFF}}

{{ITERATION_HISTORY}}

Check for:
- Security: dangerous functions (eval, exec), SQL injection, XSS, command injection, path traversal, SSRF
- Bugs: null/undefined errors, race conditions, off-by-one errors, infinite loops
- Performance: N+1 queries, unnecessary re-renders, memory leaks, blocking operations
- Maintainability: code duplication, unclear naming, missing error handling
- Cross-commit issues: inconsistent changes across files, partial refactors, broken dependencies
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW severity if no property-based tests exist (Hypothesis, fast-check, testing/quick). Advisory only, not blocking.

<CONVERGENCE_RULES>
- Do NOT re-report issues from previous iterations that have been fixed
- Focus on verifying fixes from previous iterations first
- Only report NEW issues not seen in any previous iteration
- If all previous issues are fixed and no new issues found, return PASS
- Maximum 3 new issues per iteration to ensure convergence
- Only report issues present in the BRANCH CHANGES above
</CONVERGENCE_RULES>

<CRITICAL_INSTRUCTION>
After your analysis, you MUST execute this final step:

Step 1: Think through the issues (optional)
Step 2: OUTPUT EXACTLY THIS FORMAT:

If issues found:
{"status":"FAIL","issues":[{"file":"path","line":N,"severity":"high|medium|low","category":"security|bug|performance|maintainability","description":"...","suggestion":"..."}]}

If no issues:
{"status":"PASS","issues":[]}

Rules:
- Status "FAIL" = any high/medium severity issues
- Status "PASS" = zero issues OR only low severity
- The JSON must be the absolute LAST line of your response
- No text after the JSON closing brace
</CRITICAL_INSTRUCTION>
EOF
else
cat > .claude/codex-review-state.md <<'EOF'
---
active: true
iteration: 1
max_iterations: MAX_ITERATIONS_PLACEHOLDER
completion_promise: COMPLETION_PROMISE_PLACEHOLDER
review_mode: "commit"
review_status: "PENDING"
started_at: "TIMESTAMP_PLACEHOLDER"
last_result: null
---

You are a code reviewer. Review ONLY the following staged changes (git diff --cached output). Do NOT review unstaged or untracked files.

CHANGELOG FROM PREVIOUS TASK:
{{PREV_CHANGELOG}}

STAGED CHANGES TO REVIEW:
{{STAGED_DIFF}}

{{ITERATION_HISTORY}}

Check for:
- Security: dangerous functions (eval, exec), SQL injection, XSS, command injection, path traversal, SSRF
- Bugs: null/undefined errors, race conditions, off-by-one errors, infinite loops
- Performance: N+1 queries, unnecessary re-renders, memory leaks, blocking operations
- Maintainability: code duplication, unclear naming, missing error handling
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW severity if no property-based tests exist (Hypothesis, fast-check, testing/quick). Advisory only, not blocking.

<CONVERGENCE_RULES>
- Do NOT re-report issues from previous iterations that have been fixed
- Focus on verifying fixes from previous iterations first
- Only report NEW issues not seen in any previous iteration
- If all previous issues are fixed and no new issues found, return PASS
- Maximum 3 new issues per iteration to ensure convergence
- Only report issues present in the STAGED CHANGES above
</CONVERGENCE_RULES>

<CRITICAL_INSTRUCTION>
After your analysis, you MUST execute this final step:

Step 1: Think through the issues (optional)
Step 2: OUTPUT EXACTLY THIS FORMAT:

If issues found:
{"status":"FAIL","issues":[{"file":"path","line":N,"severity":"high|medium|low","category":"security|bug|performance|maintainability","description":"...","suggestion":"..."}]}

If no issues:
{"status":"PASS","issues":[]}

Rules:
- Status "FAIL" = any high/medium severity issues
- Status "PASS" = zero issues OR only low severity
- The JSON must be the absolute LAST line of your response
- No text after the JSON closing brace
</CRITICAL_INSTRUCTION>
EOF
fi

# Replace placeholders
sed -i.tmp "s/MAX_ITERATIONS_PLACEHOLDER/$MAX_ITERATIONS/" .claude/codex-review-state.md
sed -i.tmp "s/COMPLETION_PROMISE_PLACEHOLDER/$COMPLETION_PROMISE/" .claude/codex-review-state.md
sed -i.tmp "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/" .claude/codex-review-state.md
rm -f .claude/codex-review-state.md.tmp

# Success message
echo "✅ Review loop initialized"
echo ""
echo "   State file: .claude/codex-review-state.md"
echo "   Max iterations: $MAX_ITERATIONS"
if [ "$COMPLETION_PROMISE" != "null" ]; then
    echo "   Completion promise: $COMPLETION_PROMISE"
fi
echo ""
echo "Next steps:"
echo "   1. Run: bash scripts/run-review-loop.sh"
echo "   2. Fix any issues found"
echo "   3. Loop continues automatically until PASS"
echo ""
