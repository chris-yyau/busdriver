#!/bin/bash
# Shared validation functions for codex-reviewer scripts
# Provides centralized error handling and validation

# Validate we're in a git repository
validate_git_repo() {
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not a git repository" >&2
    echo "" >&2
    echo "   Expected: A valid git repository" >&2
    echo "   Location: $(pwd)" >&2
    echo "" >&2
    echo "   To initialize a git repository:" >&2
    echo "   1. Run: git init" >&2
    echo "   2. Add files: git add ." >&2
    echo "   3. Create initial commit: git commit -m 'Initial commit'" >&2
    return 1
  fi
  return 0
}

# Validate codex CLI is installed
validate_codex_installed() {
  if ! command -v codex &> /dev/null; then
    echo "❌ Error: codex CLI not found" >&2
    echo "" >&2
    echo "   Expected: codex command available in PATH" >&2
    echo "   Current PATH: $PATH" >&2
    echo "" >&2
    echo "   To install codex:" >&2
    echo "   1. Check installation instructions for your system" >&2
    echo "   2. Verify installation: which codex" >&2
    echo "   3. Check version: codex --version" >&2
    return 1
  fi
  return 0
}

# Validate state file exists
validate_state_file() {
  local state_file="${1:-.claude/codex-review-state.md}"

  if [ ! -f "$state_file" ]; then
    echo "❌ Error: State file not found" >&2
    echo "" >&2
    echo "   Expected: $state_file" >&2
    echo "   Location: $(pwd)" >&2
    echo "" >&2
    echo "   To initialize the review loop:" >&2
    echo "   1. Run: bash scripts/init-review-loop.sh" >&2
    echo "   2. This will create the state file" >&2
    echo "   3. Then run: bash scripts/run-review-loop.sh" >&2
    return 1
  fi
  return 0
}

# Validate JSON is well-formed
validate_json() {
  local json="$1"

  if ! echo "$json" | jq . > /dev/null 2>&1; then
    echo "❌ Error: Invalid JSON output from codex" >&2
    echo "" >&2
    echo "   Expected: Valid JSON with {\"status\": \"PASS\" or \"FAIL\", \"issues\": [...]}" >&2
    echo "   Received: $json" >&2
    echo "" >&2
    echo "   Troubleshooting:" >&2
    echo "   1. Check if output contains non-JSON text" >&2
    echo "   2. Look for markdown code blocks (\`\`\`json)" >&2
    echo "   3. Verify codex is returning properly formatted JSON" >&2
    echo "   4. See references/troubleshooting.md for JSON parsing issues" >&2
    return 1
  fi
  return 0
}

# Extract YAML value from frontmatter
# Usage: get_yaml_value "key" "file.md"
get_yaml_value() {
  local key="$1"
  local file="$2"

  # Extract value between --- markers
  # This is a simple implementation - for complex YAML, consider using yq
  sed -n '/^---$/,/^---$/p' "$file" | \
    grep "^${key}:" | \
    sed "s/^${key}:[[:space:]]*//" | \
    tr -d '"' | \
    head -1
}

# Update YAML value in frontmatter
# Usage: set_yaml_value "key" "value" "file.md"
set_yaml_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  # Create temp file
  local temp_file="${file}.tmp"

  # Extract frontmatter, update value, write back
  # NOTE: Uses ENVIRON instead of -v for 'value' because awk -v interprets
  # C escape sequences (\n, \t, \\). JSON from codex reviewer often contains
  # literal \n in descriptions, which awk -v converts to real newlines,
  # causing "newline in string" errors and exit code 2.
  _AWK_VALUE="$value" awk -v key="$key" '
    BEGIN { in_fm = 0; updated = 0; value = ENVIRON["_AWK_VALUE"] }
    /^---$/ {
      in_fm++;
      print;
      next
    }
    in_fm == 1 && $0 ~ "^" key ":" {
      print key ": " value;
      updated = 1;
      next
    }
    { print }
    END { if (updated == 0 && in_fm > 0) print key ": " value }
  ' "$file" > "$temp_file"

  # Replace original with updated
  mv "$temp_file" "$file"
}

# Check if there are uncommitted changes
has_uncommitted_changes() {
  # Check if there are any staged or unstaged changes
  if ! git diff --quiet HEAD 2>/dev/null; then
    return 0  # Has changes
  fi
  return 1  # No changes
}

# Display helpful error message for no changes
error_no_changes() {
  echo "❌ Error: No uncommitted changes detected" >&2
  echo "" >&2
  echo "   Expected: Staged or unstaged changes in git" >&2
  echo "" >&2
  echo "   To stage changes:" >&2
  echo "   1. View changes: git status" >&2
  echo "   2. Stage all: git add -A" >&2
  echo "   3. Or stage specific files: git add <file>" >&2
  echo "" >&2
  echo "   Current status:" >&2
  git status --short >&2
  return 1
}

# Get normalized project path for changelog storage
# Converts /Volumes/Work/Projects/my-app → Volumes-Work-Projects-my-app
get_normalized_project_path() {
  local project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  echo "$project_root" | sed 's|^/||' | tr '/' '-'
}
