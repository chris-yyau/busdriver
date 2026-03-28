#!/bin/bash
# Validation helpers for design-reviewer
# Borrowed from codex-reviewer pattern

set -euo pipefail

# Check if a file exists and is readable
validate_file_exists() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Error: File not found: $file" >&2
    return 1
  fi
  if [[ ! -r "$file" ]]; then
    echo "Error: File not readable: $file" >&2
    return 1
  fi
  return 0
}

# Check if file is empty
validate_file_not_empty() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo "Error: File is empty: $file" >&2
    return 1
  fi
  return 0
}

# Validate JSON format
validate_json() {
  local json_string="$1"
  if ! echo "$json_string" | jq empty 2>/dev/null; then
    echo "Error: Invalid JSON format" >&2
    return 1
  fi
  return 0
}

# Validate JSON file
validate_json_file() {
  local file="$1"
  validate_file_exists "$file" || return 1
  validate_file_not_empty "$file" || return 1

  if ! jq empty "$file" 2>/dev/null; then
    echo "Error: Invalid JSON in file: $file" >&2
    return 1
  fi
  return 0
}

# Extract JSON from markdown code blocks if wrapped
extract_json_from_markdown() {
  local input="$1"

  # Check if wrapped in markdown code blocks
  if echo "$input" | grep -q '```json'; then
    echo "$input" | sed -n '/```json/,/```/p' | sed '1d;$d'
  elif echo "$input" | grep -q '```'; then
    echo "$input" | sed -n '/```/,/```/p' | sed '1d;$d'
  else
    echo "$input"
  fi
}

# Validate CLI is available
# DEPRECATED: Use is_cli_available() from scripts/lib/resolve-cli.sh instead.
# Kept as backward-compatible wrapper.
validate_cli_available() {
  local cli_name="$1"
  if ! command -v "$cli_name" &> /dev/null; then
    echo "Error: $cli_name CLI not found. Please install it first." >&2
    return 1
  fi
  return 0
}

# Create default JSON structure for failed review
create_error_json() {
  local reviewer="$1"
  local error_message="$2"

  cat <<EOF
{
  "status": "ERROR",
  "reviewer_id": "$reviewer",
  "review_duration_ms": 0,
  "error": "$error_message",
  "issues": [],
  "metadata": {
    "total_sections_reviewed": 0,
    "review_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }
}
EOF
}

# Validate review output has required fields
validate_review_output() {
  local json="$1"
  local reviewer="$2"

  # Check for required fields
  local required_fields=("status" "reviewer_id" "issues")
  for field in "${required_fields[@]}"; do
    if ! echo "$json" | jq -e ".$field" > /dev/null 2>&1; then
      echo "Error: Missing required field '$field' in $reviewer review output" >&2
      return 1
    fi
  done

  # Validate issues array structure
  local issues_count=$(echo "$json" | jq '.issues | length')
  for ((i=0; i<issues_count; i++)); do
    local issue=$(echo "$json" | jq ".issues[$i]")

    # Check required issue fields
    local issue_fields=("section" "severity" "confidence" "category" "description" "suggestion")
    for field in "${issue_fields[@]}"; do
      if ! echo "$issue" | jq -e ".$field" > /dev/null 2>&1; then
        echo "Warning: Issue $i missing field '$field' in $reviewer review" >&2
      fi
    done

    # Validate confidence is between 0.0 and 1.0
    local confidence=$(echo "$issue" | jq -r '.confidence // 0')
    if ! awk -v c="$confidence" 'BEGIN { exit !(c >= 0.0 && c <= 1.0) }'; then
      echo "Warning: Issue $i has invalid confidence value: $confidence (must be 0.0-1.0)" >&2
    fi
  done

  return 0
}

# Log message with timestamp
log_message() {
  local level="$1"
  shift
  local message="$@"
  echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] [$level] $message"
}

# Log info message
log_info() {
  log_message "INFO" "$@"
}

# Log warning message
log_warning() {
  log_message "WARN" "$@"
}

# Log error message
log_error() {
  log_message "ERROR" "$@"
}
