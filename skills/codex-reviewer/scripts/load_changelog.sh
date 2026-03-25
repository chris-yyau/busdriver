#!/bin/bash
# Load and format recent changelog entries for review prompt
# Provides context about recent changes to help avoid redundant issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Source validation library
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"

# Get number of entries to load (default: 3)
LIMIT="${CODEX_CHANGELOG_LIMIT:-3}"

# Validate we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  # Silent skip - return empty string
  echo ""
  exit 0
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
  # Silent skip - return empty string
  echo ""
  exit 0
fi

# Get normalized project path
PROJECT_PATH=$(get_normalized_project_path)
HISTORY_FILE="$HOME/.claude/projects/$PROJECT_PATH/codex-context/task-history.jsonl"

# If history file doesn't exist, return empty string
if [ ! -f "$HISTORY_FILE" ]; then
  echo ""
  exit 0
fi

# Read last N lines and reverse (newest first)
# Use tail -r on macOS, tac on Linux
if tail -r /dev/null >/dev/null 2>&1; then
  # macOS
  ENTRIES=$(tail -n "$LIMIT" "$HISTORY_FILE" 2>/dev/null | tail -r || echo "")
else
  # Linux
  ENTRIES=$(tail -n "$LIMIT" "$HISTORY_FILE" 2>/dev/null | tac || echo "")
fi

# If no entries, return empty string
if [ -z "$ENTRIES" ]; then
  echo ""
  exit 0
fi

# Start output with header
echo "RECENT CHANGES:"
echo ""

# Format each entry
echo "$ENTRIES" | while IFS= read -r line; do
  # Parse JSON fields
  TIMESTAMP=$(echo "$line" | jq -r '.timestamp' 2>/dev/null || echo "")
  COMMIT_MSG=$(echo "$line" | jq -r '.commitMessage' 2>/dev/null | head -1 || echo "")
  ITERATIONS=$(echo "$line" | jq -r '.reviewIterations' 2>/dev/null || echo "0")
  FILES=$(echo "$line" | jq -r '.changedFiles | join(", ")' 2>/dev/null || echo "")
  ADDED=$(echo "$line" | jq -r '.totalLinesChanged.added' 2>/dev/null || echo "0")
  DELETED=$(echo "$line" | jq -r '.totalLinesChanged.deleted' 2>/dev/null || echo "0")
  SUMMARY=$(echo "$line" | jq -r '.diffSummary' 2>/dev/null || echo "")
  COMMIT=$(echo "$line" | jq -r '.commit' 2>/dev/null | cut -c1-12 || echo "")

  # Skip if essential fields are missing
  if [ -z "$TIMESTAMP" ] || [ -z "$COMMIT_MSG" ]; then
    continue
  fi

  # Format timestamp (extract date and time)
  DATE=$(echo "$TIMESTAMP" | cut -d'T' -f1 || echo "")
  TIME=$(echo "$TIMESTAMP" | cut -d'T' -f2 | cut -d':' -f1,2 || echo "")

  # Calculate issues count (placeholder - not stored yet, will be 0)
  ISSUES=0

  # Output formatted entry
  echo "[$DATE $TIME] $COMMIT_MSG ($ITERATIONS iterations)"
  echo "  Files: $FILES"
  echo "  Changes: +$ADDED -$DELETED lines"
  if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "$COMMIT_MSG" ]; then
    echo "  Summary: $SUMMARY"
  fi
  echo "  Commit: $COMMIT"
  echo ""
done

exit 0
