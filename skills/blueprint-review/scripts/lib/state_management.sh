#!/bin/bash
# State management for blueprint-review
# Uses YAML frontmatter pattern from litmus

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

# Get a review output file path (e.g. get_review_file "agy.json")
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
  local max_iterations="${2:-3}"

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
agy_status: ""
codex_status: ""
claude_status: ""

# Progress model (replaces binary FAIL/PASS)
progress_status: ""
high_issues: 0
medium_issues: 0
low_issues: 0

# Category-aware blocking counts (excludes TDD-discoverable + scope-expansion findings)
plan_blocking_high: 0
plan_blocking_medium: 0
deferred_issues: 0

# Trajectory of plan_blocking_high across iterations — used for early-stop check
high_issues_history: "[]"
early_stopped: ""
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
  #
  # `skipping` consumes orphan continuation lines left over from a prior
  # multi-line value (e.g. pre-fix pretty-printed JSON). It resets at the next
  # frontmatter delimiter, key, blank line, or comment.
  _AWK_VALUE="$value" awk -v field="$field" '
    BEGIN { value = ENVIRON["_AWK_VALUE"] }
    /^---$/ {
      yaml_count++
      skipping = 0
      print
      next
    }
    yaml_count == 1 && $0 ~ "^" field ":" {
      print field ": " value
      skipping = 1
      next
    }
    yaml_count == 1 && skipping {
      if ($0 == "" || $0 ~ /^#/ || $0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:/) {
        skipping = 0
        print
        next
      }
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
  local agy_status="$1"
  local codex_status="$2"
  local claude_status="$3"

  update_state_field "agy_status" "\"$agy_status\""
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
  #
  # last_ts and stale_hours are passed via env vars — NOT interpolated into
  # the python source string — so a state.md value containing `'` or python
  # fragments cannot escape the python -c body and execute arbitrary code.
  local stale_hours="${DESIGN_REVIEW_STALE_HOURS:-2}"
  # Accept what python float() would parse: signed decimals (including the
  # bare-leading-dot form `.5` and bare-trailing-dot form `2.`) and
  # scientific notation. Pre-fix this validator did not exist and the value
  # flowed straight into a python -c source string — a literal `import os; …`
  # payload would have executed. Rejecting only "definitely-not-a-number"
  # keeps the injection door shut without breaking unusual-but-valid configs
  # (`+2`, `.5`, `2.`, `1e2`, etc.).
  if ! [[ "$stale_hours" =~ ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
    # Bad config — return 1 = "active with progress". Caller treats this as
    # "do not clean", which is the safe path: a misconfigured environment
    # variable should never cause cleanup logic to clobber an in-progress
    # review. The user sees the warning on stderr and fixes the config.
    echo "warning: DESIGN_REVIEW_STALE_HOURS must be numeric (got: $stale_hours); skipping staleness check" >&2
    return 1
  fi
  if command -v python3 &>/dev/null; then
    local is_time_stale
    is_time_stale=$(_CER_LAST_TS="$last_ts" _CER_STALE_HOURS="$stale_hours" python3 -c '
from datetime import datetime, timezone, timedelta
import os
try:
    ts = os.environ["_CER_LAST_TS"]
    stale_hours = float(os.environ["_CER_STALE_HOURS"])
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            break
        except ValueError:
            continue
    else:
        print("FRESH")
        exit()
    age = datetime.now(timezone.utc) - dt
    print("STALE" if age > timedelta(hours=stale_hours) else "FRESH")
except Exception:
    print("FRESH")
' 2>/dev/null || echo "FRESH")
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

# Append a plan-blocking-high count to the trajectory history (JSON array stored as YAML string).
# Used by trajectory-aware early-stop logic to detect unconverging loops.
#
# NOTE: The state field is named `high_issues_history` (not `plan_blocking_high_history`)
# for backward compat with already-initialized state.md files. The values stored are
# plan-blocking HIGH counts, NOT raw HIGH counts — see Phase 4 in run-design-review-loop.sh.
append_high_history() {
  local count="$1"
  local current
  current=$(get_state_field "high_issues_history")
  # Reset to [] for empty, missing, or unparseable values. get_state_field strips
  # quotes via gsub, so a healthy field comes back as a bare JSON array (e.g. `[1,2]`).
  # A corrupt field may come back truncated (e.g. `[` from a multi-line value);
  # validate before passing to jq so we recover instead of silently losing history.
  if [[ -z "$current" || "$current" == '""' ]]; then
    current="[]"
  elif command -v jq &>/dev/null && ! echo "$current" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "warning: high_issues_history was corrupt ($current); resetting to []" >&2
    current="[]"
  fi
  local updated
  if command -v jq &>/dev/null; then
    # -c (compact) is REQUIRED — jq pretty-prints by default, which would emit
    # a multi-line array. update_state_field is line-based and can't safely write
    # multi-line values, so the result must be single-line.
    updated=$(echo "$current" | jq -c --argjson c "$count" '. + [$c]' 2>/dev/null || echo "[$count]")
  else
    # Fallback: simple string concatenation (jq absent on this host).
    # Without jq we can't fully validate JSON, so apply a minimal well-formedness
    # guard — must start with [ AND end with ] — and reset to [] otherwise.
    # Without this, a truncated value like "[" (the corruption this PR repairs)
    # would yield "[, $count]" via ${current%]} (no-op when no trailing ]),
    # which is invalid JSON and gets written back to state.md.
    if [[ "$current" == "[]" ]]; then
      updated="[$count]"
    elif [[ "$current" =~ ^\[.*\]$ ]]; then
      updated="${current%]}, $count]"
    else
      echo "warning: high_issues_history was corrupt ($current); resetting to []" >&2
      updated="[$count]"
    fi
  fi
  # Belt-and-suspenders: collapse any stray newlines so the YAML write stays
  # single-line even if a future change reintroduces pretty-printed input.
  updated="${updated//$'\n'/}"
  # Wrap in quotes so YAML parses it as a string, not a sequence
  update_state_field "high_issues_history" "\"$updated\""
}

# Get the plan-blocking-high trajectory history as JSON array.
get_high_history() {
  local hist
  hist=$(get_state_field "high_issues_history")
  if [[ -z "$hist" || "$hist" == '""' ]]; then
    echo "[]"
  else
    echo "$hist"
  fi
}

# Trajectory check.
# Exit codes:
#   0 — no progress (auto-stop is safe to fire)
#   1 — still progressing OR not enough data yet
#   2 — corrupt history (could not parse JSON); warning emitted to stderr
# The caller (`&& check_no_progress`) treats any non-zero as "don't auto-stop",
# so exit 2 is fail-safe but distinguishable when looking at logs.
#
# History and window are passed via environment variables — NOT interpolated
# into the python source — so a state.md value containing `'''` or python
# fragments cannot escape the heredoc and execute arbitrary code.
check_no_progress() {
  local history="$1"
  local window="${2:-1}"
  # Reject 0 and non-numerics. window=0 would produce a degenerate slice
  # (h[-1:] — single element compared to itself, always "no progress"),
  # firing auto-stop on a single iteration.
  if ! [[ "$window" =~ ^[1-9][0-9]*$ ]]; then
    echo "warning: check_no_progress window must be a positive integer (got: $window)" >&2
    return 2
  fi
  _CNP_HISTORY="$history" _CNP_WINDOW="$window" python3 -c '
import json, os, sys
window = int(os.environ["_CNP_WINDOW"])
try:
    h = json.loads(os.environ["_CNP_HISTORY"])
except (ValueError, json.JSONDecodeError) as e:
    sys.stderr.write("warning: high_issues_history is corrupt (" + str(e) + "); skipping trajectory check\n")
    sys.exit(2)
if not isinstance(h, list) or len(h) < window + 1:
    sys.exit(1)
recent = h[-(window + 1):]
if recent[-1] < recent[0]:
    sys.exit(1)
sys.exit(0)
'
}
