#!/bin/bash
# Save changelog after successful commit
# Provides context continuity for future review sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Source validation library
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"

# Validate we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  # Silent skip - not an error if not in git repo
  exit 0
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
  echo "⚠️  Warning: jq not installed, skipping changelog" >&2
  echo "   Install jq to enable changelog: brew install jq (macOS) or apt-get install jq (Linux)" >&2
  exit 0
fi

echo "💾 Saving changelog..."

# Get latest commit info
COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "")
TIMESTAMP=$(git log -1 --pretty=%cI 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get changed files as JSON array
CHANGED_FILES=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | jq -R . | jq -s . || echo '[]')

# Get diff stats (lines added/deleted)
STATS=$(git show --stat --format="" HEAD 2>/dev/null | tail -1 || echo "")
ADDED=$(echo "$STATS" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' 2>/dev/null || echo "0")
DELETED=$(echo "$STATS" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' 2>/dev/null || echo "0")

# Get diff summary (first line of commit message, truncated)
DIFF_SUMMARY=$(echo "$COMMIT_MSG" | head -1 | cut -c1-200)

# Get review iterations from state file (if exists)
STATE_FILE=".claude/codex-review-state.md"
ITERATIONS=0
if [ -f "$STATE_FILE" ]; then
  # Extract iteration value from YAML frontmatter
  ITERATIONS=$(get_yaml_value "iteration" "$STATE_FILE" 2>/dev/null || echo "1")
  # Subtract 1 since iteration is incremented after completion
  ITERATIONS=$((ITERATIONS - 1))
  # Ensure non-negative
  if [ "$ITERATIONS" -lt 0 ]; then
    ITERATIONS=0
  fi
fi

# Get task ID from environment if available
TASK_ID="${CURRENT_TASK_ID:-null}"

# Build JSON entry (compact format for JSONL)
ENTRY=$(jq -cn \
  --arg timestamp "$TIMESTAMP" \
  --arg taskId "$TASK_ID" \
  --arg commit "$COMMIT_SHA" \
  --arg commitMessage "$COMMIT_MSG" \
  --argjson changedFiles "$CHANGED_FILES" \
  --arg diffSummary "$DIFF_SUMMARY" \
  --argjson reviewIterations "$ITERATIONS" \
  --argjson added "$ADDED" \
  --argjson deleted "$DELETED" \
  '{
    timestamp: $timestamp,
    taskId: ($taskId | if . == "null" then null else . end),
    commit: $commit,
    commitMessage: $commitMessage,
    changedFiles: $changedFiles,
    diffSummary: $diffSummary,
    reviewIterations: $reviewIterations,
    totalLinesChanged: {
      added: $added,
      deleted: $deleted
    }
  }') || {
  echo "⚠️  Warning: Failed to build changelog JSON, skipping" >&2
  exit 0
}

# Get normalized project path for storage location
PROJECT_PATH=$(get_normalized_project_path)
CONTEXT_DIR="$HOME/.claude/projects/$PROJECT_PATH/codex-context"

# Ensure directory exists
mkdir -p "$CONTEXT_DIR" 2>/dev/null || {
  echo "⚠️  Warning: Could not create changelog directory" >&2
  echo "   Location: $CONTEXT_DIR" >&2
  echo "   Impact: Changelog not saved (review workflow continues)" >&2
  exit 0
}

# Append to task history
echo "$ENTRY" >> "$CONTEXT_DIR/task-history.jsonl" 2>/dev/null || {
  echo "⚠️  Warning: Failed to append to task history" >&2
  echo "   File: $CONTEXT_DIR/task-history.jsonl" >&2
  exit 0
}

# Update last task (for quick access)
echo "$ENTRY" > "$CONTEXT_DIR/last-task.json" 2>/dev/null || {
  echo "⚠️  Warning: Failed to update last task" >&2
  echo "   File: $CONTEXT_DIR/last-task.json" >&2
  exit 0
}

echo "✅ Changelog saved"
echo "   Location: $CONTEXT_DIR"
echo "   Commit: ${COMMIT_SHA:0:12}"
echo "   Changes: +$ADDED -$DELETED lines"
echo "   Review iterations: $ITERATIONS"
echo ""
