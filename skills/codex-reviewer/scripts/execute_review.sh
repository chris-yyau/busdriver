#!/bin/bash
# Execute Codex code review with changelog injection
# Returns structured JSON output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Load changelog from previous tasks for context
PREV_CHANGELOG=$(bash "$SCRIPT_DIR/load_changelog.sh" 2>/dev/null || echo "")

# Read prompt template
PROMPT_TEMPLATE=$(cat "$SKILL_DIR/prompt_template.txt")

# Substitute changelog variable
FINAL_PROMPT="${PROMPT_TEMPLATE/\{\{PREV_CHANGELOG\}\}/$PREV_CHANGELOG}"

# Execute codex review
# Note: codex CLI will automatically detect uncommitted changes
codex review "$FINAL_PROMPT"
