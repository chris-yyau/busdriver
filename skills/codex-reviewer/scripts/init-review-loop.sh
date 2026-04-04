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
  PR_BASE_BRANCH="${CODEX_PR_BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")}"
  # Auto-prefix origin/ if user provided a bare branch name (e.g. CODEX_PR_BASE=main → origin/main)
  if [[ -n "${CODEX_PR_BASE:-}" && "$PR_BASE_BRANCH" != */* ]]; then
    PR_BASE_BRANCH="origin/${PR_BASE_BRANCH}"
  fi
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

Review the following FULL BRANCH DIFF (base..HEAD) for bugs, security issues, performance problems, and maintainability.

{{SAST_PRECHECK}}

<diff>
{{STAGED_DIFF}}
</diff>

<cross_file_context>
{{SMART_CONTEXT}}
</cross_file_context>

<docs_context>
{{DOCS_CONTEXT}}
</docs_context>

<changelog>
{{PREV_CHANGELOG}}
</changelog>

<iteration_history>
{{ITERATION_HISTORY}}
</iteration_history>

<output_contract>
You MUST output a single JSON object conforming to this schema. No markdown, no commentary, no text before or after.

Schema:
{
  "status": "PASS" or "FAIL",
  "issues": [
    {
      "file": "path/to/file.ext",
      "line": 42,
      "severity": "high" | "medium" | "low",
      "category": "security" | "bug" | "performance" | "maintainability",
      "description": "Clear description referencing the actual code",
      "suggestion": "Concrete fix with code example when possible",
      "confidence": 85
    }
  ]
}

Field rules:
- status: "FAIL" if ANY high or medium severity issue exists. "PASS" otherwise.
- file: relative path from repo root. Must match a file in the diff.
- line: integer line number. Use 0 only for file-level issues.
- severity: "high" = bugs, security vulns, data loss. "medium" = perf, error handling. "low" = style, naming.
- category: exactly one of "security", "bug", "performance", "maintainability".
- description: specific, referencing the actual code. Not generic advice.
- suggestion: concrete fix. Not "consider fixing" — show what to change.
- confidence: integer 0-100. How certain this is a real issue, not a false positive. Required.
</output_contract>

<grounding_rules>
- Only report issues in the CHANGED code shown in the diff. Do not report pre-existing issues.
- Every finding must reference a specific file and line from the diff.
- Do not report issues that linters or type checkers would catch (formatting, unused imports).
- Do not re-report issues from the iteration_history that have already been fixed.
- Maximum 10 issues per review. Prioritize by severity, then confidence.
- If all previous issues are fixed and no new issues found, return {"status": "PASS", "issues": []}.
- Maximum 3 new issues per iteration to ensure convergence.
- When reviewing shell scripts, check: unquoted variables, missing error handling, unsafe temp files, local outside functions, shasum vs sha256sum portability, mktemp -t portability, CWD/path safety, cleanup ordering before early exits, timeout fail-open, boolean normalization.
- When reviewing documentation, verify: factual claims match code, examples are correct, counts match reality, no stale references.
- When reviewing cross-commit changes, check: inconsistent naming, partial refactors, broken dependencies.
- When reviewing CI/CD workflows (.github/workflows/*.yml, .gitlab-ci.yml):
  - Flag `paths` + `paths-ignore` on the same trigger (GitHub Actions ignores one silently).
  - Flag `${{ }}` expressions inside `run:` blocks — use `env:` intermediary to prevent expression injection.
  - Flag `curl | sh`, `curl | sudo sh`, or `wget | sh` patterns — supply chain risk. Pin to a commit SHA or use a versioned action.
  - Flag unpinned `pip install`, `npm install -g`, or `gem install` without version pins in CI steps.
  - Flag action `uses:` references without SHA pins (e.g., `actions/checkout@v4` instead of `actions/checkout@<sha>`).
  - Flag missing top-level `permissions: {}` — workflows should use least-privilege with job-level permissions.
  - Flag conditional skip logic (`grep -q` / `if [ -f ... ]`) that can be bypassed by non-functional references or empty files.
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW if no property-based tests exist. Advisory only.
</grounding_rules>
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

Review the following staged changes (git diff --cached) for bugs, security issues, performance problems, and maintainability. Do NOT review unstaged or untracked files.

{{SAST_PRECHECK}}

<diff>
{{STAGED_DIFF}}
</diff>

<cross_file_context>
{{SMART_CONTEXT}}
</cross_file_context>

<docs_context>
{{DOCS_CONTEXT}}
</docs_context>

<changelog>
{{PREV_CHANGELOG}}
</changelog>

<iteration_history>
{{ITERATION_HISTORY}}
</iteration_history>

<output_contract>
You MUST output a single JSON object conforming to this schema. No markdown, no commentary, no text before or after.

Schema:
{
  "status": "PASS" or "FAIL",
  "issues": [
    {
      "file": "path/to/file.ext",
      "line": 42,
      "severity": "high" | "medium" | "low",
      "category": "security" | "bug" | "performance" | "maintainability",
      "description": "Clear description referencing the actual code",
      "suggestion": "Concrete fix with code example when possible",
      "confidence": 85
    }
  ]
}

Field rules:
- status: "FAIL" if ANY high or medium severity issue exists. "PASS" otherwise.
- file: relative path from repo root. Must match a file in the diff.
- line: integer line number. Use 0 only for file-level issues.
- severity: "high" = bugs, security vulns, data loss. "medium" = perf, error handling. "low" = style, naming.
- category: exactly one of "security", "bug", "performance", "maintainability".
- description: specific, referencing the actual code. Not generic advice.
- suggestion: concrete fix. Not "consider fixing" — show what to change.
- confidence: integer 0-100. How certain this is a real issue, not a false positive. Required.
</output_contract>

<grounding_rules>
- Only report issues in the CHANGED code shown in the diff. Do not report pre-existing issues.
- Every finding must reference a specific file and line from the diff.
- Do not report issues that linters or type checkers would catch (formatting, unused imports).
- Do not re-report issues from the iteration_history that have already been fixed.
- Maximum 10 issues per review. Prioritize by severity, then confidence.
- If all previous issues are fixed and no new issues found, return {"status": "PASS", "issues": []}.
- Maximum 3 new issues per iteration to ensure convergence.
- When reviewing shell scripts, check: unquoted variables, missing error handling, unsafe temp files, local outside functions, shasum vs sha256sum portability, mktemp -t portability, CWD/path safety, cleanup ordering before early exits, timeout fail-open, boolean normalization.
- When reviewing documentation, verify: factual claims match code, examples are correct, counts match reality, no stale references.
- When reviewing CI/CD workflows (.github/workflows/*.yml, .gitlab-ci.yml):
  - Flag `paths` + `paths-ignore` on the same trigger (GitHub Actions ignores one silently).
  - Flag `${{ }}` expressions inside `run:` blocks — use `env:` intermediary to prevent expression injection.
  - Flag `curl | sh`, `curl | sudo sh`, or `wget | sh` patterns — supply chain risk. Pin to a commit SHA or use a versioned action.
  - Flag unpinned `pip install`, `npm install -g`, or `gem install` without version pins in CI steps.
  - Flag action `uses:` references without SHA pins (e.g., `actions/checkout@v4` instead of `actions/checkout@<sha>`).
  - Flag missing top-level `permissions: {}` — workflows should use least-privilege with job-level permissions.
  - Flag conditional skip logic (`grep -q` / `if [ -f ... ]`) that can be bypassed by non-functional references or empty files.
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW if no property-based tests exist. Advisory only.
</grounding_rules>
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
