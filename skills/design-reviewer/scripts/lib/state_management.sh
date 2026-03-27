#!/bin/bash
# State management for design-reviewer
# Uses YAML frontmatter pattern from codex-reviewer

set -euo pipefail

# Derive a slug from the design file name for namespacing review outputs
# e.g. "docs/plans/2026-03-10-analytics-redesign.md" → "analytics-redesign"
get_review_slug() {
  local design_file="$1"
  local base
  base=$(basename "$design_file" .md)
  # Strip leading date prefix (YYYY-MM-DD-)
  echo "$base" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//'
}

# Get the review output directory for the current review
# Reads the slug from the pointer file written by init
get_review_dir() {
  local pointer_file=".claude/current-design-review.local"
  if [[ -f "$pointer_file" ]]; then
    local slug
    slug=$(cat "$pointer_file" 2>/dev/null)
    if [[ -n "$slug" ]]; then
      echo "docs/reviews/$slug"
      return
    fi
  fi
  # Fallback: flat directory (backward compat)
  echo "docs/reviews"
}

# Get a review output file path (e.g. get_review_file "gemini.json")
get_review_file() {
  local name="$1"
  echo "$(get_review_dir)/$name"
}

# Get the state file path
get_state_file() {
  echo "$(get_review_dir)/state.md"
}

# Initialize state file
init_state_file() {
  local design_file="$1"
  local max_iterations="${2:-5}"

  # Derive slug and create namespaced directory
  local slug
  slug=$(get_review_slug "$design_file")
  local review_dir="docs/reviews/$slug"
  mkdir -p "$review_dir"

  # Write pointer so other scripts find the current review
  mkdir -p .claude
  echo "$slug" > ".claude/current-design-review.local"

  local state_file="$review_dir/state.md"

  cat > "$state_file" <<EOF
---
active: true
iteration: 1
max_iterations: $max_iterations
started_at: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
design_file: "$design_file"
status: "IN_PROGRESS"
last_review_timestamp: ""

# Review results
gemini_status: ""
codex_status: ""
claude_status: ""

# Progress model (replaces binary FAIL/PASS)
progress_status: ""
high_issues: 0
medium_issues: 0
low_issues: 0
---

# Design Review State

Claude is the arbiter. Convergence = Claude's verdict.

## Current Status

Waiting for first review iteration...
EOF

  echo "$state_file"
}

# Read YAML frontmatter field
get_state_field() {
  local field="$1"
  local state_file=$(get_state_file)

  if [[ ! -f "$state_file" ]]; then
    echo ""
    return 1
  fi

  # Extract YAML frontmatter and parse field
  awk -v field="$field" '
    /^---$/ { in_yaml = !in_yaml; next }
    in_yaml && $0 ~ "^" field ":" {
      sub("^" field ": *", "")
      gsub(/"/, "")
      print
      exit
    }
  ' "$state_file"
}

# Update YAML frontmatter field
update_state_field() {
  local field="$1"
  local value="$2"
  local state_file=$(get_state_file)

  if [[ ! -f "$state_file" ]]; then
    echo "Error: State file not found: $state_file" >&2
    return 1
  fi

  # Create temp file
  local temp_file="${state_file}.tmp"

  # Update field in YAML frontmatter
  # NOTE: Uses ENVIRON for 'value' because awk -v interprets C escape sequences
  # (\n, \t, \\), which breaks when values contain JSON with literal backslashes.
  _AWK_VALUE="$value" awk -v field="$field" '
    BEGIN { value = ENVIRON["_AWK_VALUE"] }
    /^---$/ {
      yaml_count++
      print
      next
    }
    yaml_count == 1 && $0 ~ "^" field ":" {
      print field ": " value
      next
    }
    { print }
  ' "$state_file" > "$temp_file"

  mv "$temp_file" "$state_file"
}

# Increment iteration counter
increment_iteration() {
  local current=$(get_state_field "iteration")
  local next=$((current + 1))
  update_state_field "iteration" "$next"
  update_state_field "last_review_timestamp" "\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
}

# Check if max iterations reached
is_max_iterations_reached() {
  local current=$(get_state_field "iteration")
  local max=$(get_state_field "max_iterations")

  [[ $current -ge $max ]]
}

# Update review statuses
update_review_statuses() {
  local gemini_status="$1"
  local codex_status="$2"
  local claude_status="$3"

  update_state_field "gemini_status" "\"$gemini_status\""
  update_state_field "codex_status" "\"$codex_status\""
  update_state_field "claude_status" "\"$claude_status\""
}

# Check convergence — Claude is the arbiter (Critic #4)
# PASS = progress_status is "passed" or "low_issues_only"
check_convergence() {
  local progress=$(get_state_field "progress_status")
  [[ "$progress" == "passed" || "$progress" == "low_issues_only" ]]
}

# Check if an active review exists and whether it's stale
# Returns 0 if stale (safe to clean), 1 if active with progress, 2 if no active review
#
# F10 fix: also checks time-based staleness. A review with progress that hasn't
# been touched in DESIGN_REVIEW_STALE_HOURS (default: 2) is considered stale.
# This prevents previous-session reviews from blocking new reviews indefinitely.
check_existing_review() {
  local pointer_file=".claude/current-design-review.local"
  if [[ ! -f "$pointer_file" ]]; then
    return 2  # No active review
  fi

  local slug
  slug=$(cat "$pointer_file" 2>/dev/null)
  if [[ -z "$slug" ]]; then
    return 2
  fi

  local state_file="docs/reviews/$slug/state.md"
  if [[ ! -f "$state_file" ]]; then
    # Pointer exists but state file is gone — orphaned pointer
    return 0
  fi

  local active
  active=$(awk '/^---$/ { in_yaml = !in_yaml; next } in_yaml && /^active:/ { sub("^active: *", ""); gsub(/"/, ""); print; exit }' "$state_file")
  if [[ "$active" != "true" ]]; then
    return 2  # Review already completed
  fi

  local last_ts
  last_ts=$(awk '/^---$/ { in_yaml = !in_yaml; next } in_yaml && /^last_review_timestamp:/ { sub("^last_review_timestamp: *", ""); gsub(/"/, ""); print; exit }' "$state_file")
  if [[ -z "$last_ts" ]]; then
    return 0  # Never completed an iteration — stale
  fi

  # F10: Time-based staleness check — a review from a previous session
  # (older than DESIGN_REVIEW_STALE_HOURS) is stale even if it has progress.
  local stale_hours="${DESIGN_REVIEW_STALE_HOURS:-2}"
  if command -v python3 &>/dev/null; then
    local is_time_stale
    is_time_stale=$(python3 -c "
from datetime import datetime, timezone, timedelta
try:
    ts = '$last_ts'
    for fmt in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%d'):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            break
        except ValueError:
            continue
    else:
        print('FRESH')
        exit()
    age = datetime.now(timezone.utc) - dt
    print('STALE' if age > timedelta(hours=$stale_hours) else 'FRESH')
except Exception:
    print('FRESH')
" 2>/dev/null || echo "FRESH")
    if [[ "$is_time_stale" == "STALE" ]]; then
      return 0  # Stale by time — safe to clean
    fi
  fi

  return 1  # Active with progress
}

# Clean up stale review state
cleanup_stale_review() {
  local pointer_file=".claude/current-design-review.local"
  if [[ ! -f "$pointer_file" ]]; then
    return
  fi

  local slug
  slug=$(cat "$pointer_file" 2>/dev/null)

  # Mark state as inactive if it exists
  local state_file="docs/reviews/$slug/state.md"
  if [[ -f "$state_file" ]]; then
    local temp_file="${state_file}.tmp"
    awk '/^---$/ { yaml_count++ } yaml_count == 1 && /^active:/ { print "active: false"; next } yaml_count == 1 && /^status:/ { print "status: \"ABANDONED\""; next } { print }' "$state_file" > "$temp_file"
    mv "$temp_file" "$state_file"
  fi

  rm -f "$pointer_file"
}

# Mark review as complete
mark_review_complete() {
  local final_status="$1"  # PASS or FAIL
  update_state_field "status" "\"$final_status\""
  update_state_field "active" "false"
}

# Append to state file body
append_to_state() {
  local content="$1"
  local state_file=$(get_state_file)

  echo -e "\n$content" >> "$state_file"
}

# Get current iteration
get_current_iteration() {
  get_state_field "iteration"
}

# Get max iterations
get_max_iterations() {
  get_state_field "max_iterations"
}

# Get design file path
get_design_file() {
  get_state_field "design_file"
}
