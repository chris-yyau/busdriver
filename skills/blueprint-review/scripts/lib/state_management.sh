#!/bin/bash
# State management for blueprint-review
# Uses YAML frontmatter pattern from litmus

# Intentional pipeline patterns: command-substitution-in-pipeline is used
# throughout for log/yaml inspection where the inner command's exit code
# is not load-bearing. Disabling SC2312 keeps the noise out of CI without
# masking real signal (we still want SC2155, SC2034, etc.).
# shellcheck disable=SC2312

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

# Derive a slug from the design file name for namespacing review outputs
# e.g. "docs/plans/2026-03-10-analytics-redesign.md" → "analytics-redesign"
get_review_slug() {
  local design_file="$1"
  local base
  base=$(basename "$design_file" .md)
  # Strip leading date prefix (YYYY-MM-DD-). Uses sed because bash parameter
  # expansion patterns can't express bounded-count quantifiers cleanly without
  # extglob and an over-broad glob; sed regex is more legible here.
  # shellcheck disable=SC2001
  echo "$base" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//'
}

# Get the review output directory for the current review
# Reads the slug from the pointer file written by init
get_review_dir() {
  local pointer_file="$STATE_DIR/current-design-review.local"
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
  local max_iterations="${2:-5}"

  # Derive slug and create namespaced directory
  local slug
  slug=$(get_review_slug "$design_file")
  local review_dir="docs/reviews/$slug"
  mkdir -p "$review_dir"

  # Write pointer so other scripts find the current review
  mkdir -p "$STATE_DIR"
  echo "$slug" > "$STATE_DIR/current-design-review.local"

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
grok_status: ""
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
# Trajectory of plan_blocking_medium across iterations — used for early-stop check
# when state is medium_issues_remaining (HIGH already resolved but MEDIUMs persist)
medium_issues_history: "[]"

# Coverage provenance (reviewer fulfillment honesty — see DESIGN-blueprint-review-coverage-provenance)
coverage_status: ""
fulfilled_lens_count: 0
reviewer_1_requested: ""
reviewer_1_actual: ""
reviewer_1_fulfilled: ""
reviewer_1_reason: ""
reviewer_2_requested: ""
reviewer_2_actual: ""
reviewer_2_fulfilled: ""
reviewer_2_reason: ""
reviewer_3_requested: ""
reviewer_3_actual: ""
reviewer_3_fulfilled: ""
reviewer_3_reason: ""
coverage_history: "[]"
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
  local state_file
  state_file=$(get_state_file)

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
  local state_file
  state_file=$(get_state_file)

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
  local current
  current=$(get_state_field "iteration")
  local next=$((current + 1))
  update_state_field "iteration" "$next"
  update_state_field "last_review_timestamp" "\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
}

# Check if max iterations reached
is_max_iterations_reached() {
  local current max
  current=$(get_state_field "iteration")
  max=$(get_state_field "max_iterations")

  [[ $current -ge $max ]]
}

# Ensure grok_status field exists in the YAML frontmatter.
# Required because update_state_field cannot insert missing keys — it only
# rewrites lines that already match `^field:`. State files written before
# grok was added as reviewer_3 (2026-05-26) lack this field; without
# insertion, update_review_statuses would silently no-op on grok_status
# for any resumed review started before the upgrade. Inserted before
# `claude_status:` which has existed in every state.md version.
_ensure_grok_status_field() {
  local state_file
  state_file=$(get_state_file)
  if [[ ! -f "$state_file" ]]; then
    return 0
  fi
  if grep -q '^grok_status:' "$state_file"; then
    return 0
  fi
  local temp_file="${state_file}.tmp"
  awk '
    /^---$/ { yaml_count++ }
    yaml_count == 1 && !inserted && /^claude_status:/ {
      print "grok_status: \"\""
      inserted = 1
    }
    { print }
  ' "$state_file" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# Update review statuses
update_review_statuses() {
  local agy_status="$1"
  local codex_status="$2"
  local claude_status="$3"
  # grok_status added 2026-05-26 as 4th positional arg for blueprint-review
  # reviewer_3. Default empty (state field not written) for backward compat
  # with callers that haven't migrated; the loop passes "unavailable" when
  # grok is not configured/installed.
  local grok_status="${4:-}"

  _ensure_grok_status_field
  update_state_field "agy_status" "\"$agy_status\""
  update_state_field "codex_status" "\"$codex_status\""
  update_state_field "claude_status" "\"$claude_status\""
  [[ -n "$grok_status" ]] && update_state_field "grok_status" "\"$grok_status\""
}

# Check convergence — Claude is the arbiter (Critic #4)
# PASS = progress_status is "passed" or "low_issues_only"
check_convergence() {
  local progress
  progress=$(get_state_field "progress_status")
  [[ "$progress" == "passed" || "$progress" == "low_issues_only" ]]
}

# Check if an active review exists and whether it's stale
# Returns 0 if stale (safe to clean), 1 if active with progress, 2 if no active review
#
# F10 fix: also checks time-based staleness. A review with progress that hasn't
# been touched in DESIGN_REVIEW_STALE_HOURS (default: 2) is considered stale.
# This prevents previous-session reviews from blocking new reviews indefinitely.
check_existing_review() {
  local pointer_file="$STATE_DIR/current-design-review.local"
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
  local pointer_file="$STATE_DIR/current-design-review.local"
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
  local state_file
  state_file=$(get_state_file)

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

# Ensure medium_issues_history field exists in the YAML frontmatter.
# Required because update_state_field cannot insert missing keys — it only
# rewrites lines that already match `^field:`. State files written before
# v3.2 lack this field; without insertion, append_medium_history would
# silently no-op on mid-flight pre-upgrade reviews and the MEDIUM trajectory
# early-stop would never activate. Inserted before `early_stopped:` (a
# sibling that has existed in every state.md version).
_ensure_medium_history_field() {
  local state_file
  state_file=$(get_state_file)
  if [[ ! -f "$state_file" ]]; then
    return 0
  fi
  if grep -q '^medium_issues_history:' "$state_file"; then
    return 0
  fi
  local temp_file="${state_file}.tmp"
  awk '
    /^---$/ { yaml_count++ }
    yaml_count == 1 && !inserted && /^early_stopped:/ {
      print "medium_issues_history: \"[]\""
      inserted = 1
    }
    { print }
  ' "$state_file" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# Append a plan-blocking-medium count to the trajectory history (JSON array stored as YAML string).
# Used by trajectory-aware early-stop logic when HIGH is resolved but MEDIUMs persist
# (progress_status == medium_issues_remaining). Mirrors append_high_history.
append_medium_history() {
  local count="$1"
  _ensure_medium_history_field
  local current
  current=$(get_state_field "medium_issues_history")
  if [[ -z "$current" || "$current" == '""' ]]; then
    current="[]"
  elif command -v jq &>/dev/null && ! echo "$current" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "warning: medium_issues_history was corrupt ($current); resetting to []" >&2
    current="[]"
  fi
  local updated
  if command -v jq &>/dev/null; then
    updated=$(echo "$current" | jq -c --argjson c "$count" '. + [$c]' 2>/dev/null || echo "[$count]")
  else
    if [[ "$current" == "[]" ]]; then
      updated="[$count]"
    elif [[ "$current" =~ ^\[.*\]$ ]]; then
      updated="${current%]}, $count]"
    else
      echo "warning: medium_issues_history was corrupt ($current); resetting to []" >&2
      updated="[$count]"
    fi
  fi
  updated="${updated//$'\n'/}"
  update_state_field "medium_issues_history" "\"$updated\""
}

# Get the plan-blocking-medium trajectory history as JSON array.
get_medium_history() {
  local hist
  hist=$(get_state_field "medium_issues_history")
  if [[ -z "$hist" || "$hist" == '""' ]]; then
    echo "[]"
  else
    echo "$hist"
  fi
}

# ── Coverage provenance (reviewer fulfillment honesty) ──────────
# Lazily insert the coverage block into a (possibly legacy) state.md.
# Idempotent; sentinel = coverage_status. Mirrors _ensure_medium_history_field.
_ensure_coverage_fields() {
  local state_file
  state_file=$(get_state_file)
  if [[ ! -f "$state_file" ]]; then
    return 0
  fi
  if grep -q '^coverage_status:' "$state_file"; then
    return 0
  fi
  local temp_file="${state_file}.tmp"
  awk '
    /^---$/ { yaml_count++ }
    yaml_count == 1 && !inserted && /^early_stopped:/ {
      print "coverage_status: \"\""
      print "fulfilled_lens_count: 0"
      print "reviewer_1_requested: \"\""
      print "reviewer_1_actual: \"\""
      print "reviewer_1_fulfilled: \"\""
      print "reviewer_1_reason: \"\""
      print "reviewer_2_requested: \"\""
      print "reviewer_2_actual: \"\""
      print "reviewer_2_fulfilled: \"\""
      print "reviewer_2_reason: \"\""
      print "reviewer_3_requested: \"\""
      print "reviewer_3_actual: \"\""
      print "reviewer_3_fulfilled: \"\""
      print "reviewer_3_reason: \"\""
      print "coverage_history: \"[]\""
      inserted = 1
    }
    { print }
  ' "$state_file" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# update_coverage_slot <n> <requested> <actual> <fulfilled> <reason>
# Persist one reviewer slot's provenance. At dispatch time only requested/actual/
# resolve-reason are known (fulfilled left ""); the derivation step calls again
# with the finalized fulfilled/reason.
update_coverage_slot() {
  local n="$1" requested="$2" actual="$3" fulfilled="$4" reason="$5"
  _ensure_coverage_fields
  update_state_field "reviewer_${n}_requested" "\"$requested\""
  update_state_field "reviewer_${n}_actual" "\"$actual\""
  update_state_field "reviewer_${n}_fulfilled" "\"$fulfilled\""
  update_state_field "reviewer_${n}_reason" "\"$reason\""
}

# Recompute fulfilled_lens_count + coverage_status from the three fulfilled fields.
recompute_coverage_status() {
  _ensure_coverage_fields
  local n count=0 f
  for n in 1 2 3; do
    f=$(get_state_field "reviewer_${n}_fulfilled")
    [[ "$f" == "true" ]] && count=$((count + 1))
  done
  update_state_field "fulfilled_lens_count" "$count"
  if [[ "$count" -eq 3 ]]; then
    update_state_field "coverage_status" "\"FULL\""
  else
    update_state_field "coverage_status" "\"DEGRADED\""
  fi
}

# append_coverage_history <count> — per-ITERATION fulfilled_lens_count within this
# review (mirrors append_medium_history serialization discipline). Cross-review
# history is the trend file (append_coverage_trend), NOT this field.
append_coverage_history() {
  local count="$1"
  _ensure_coverage_fields
  local current
  current=$(get_state_field "coverage_history")
  if [[ -z "$current" || "$current" == '""' ]]; then
    current="[]"
  elif command -v jq &>/dev/null && ! echo "$current" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "warning: coverage_history was corrupt ($current); resetting to []" >&2
    current="[]"
  fi
  local updated
  if command -v jq &>/dev/null; then
    updated=$(echo "$current" | jq -c --argjson c "$count" '. + [$c]' 2>/dev/null || echo "[$count]")
  else
    if [[ "$current" == "[]" ]]; then
      updated="[$count]"
    elif [[ "$current" =~ ^\[.*\]$ ]]; then
      updated="${current%]}, $count]"
    else
      echo "warning: coverage_history was corrupt ($current); resetting to []" >&2
      updated="[$count]"
    fi
  fi
  updated="${updated//$'\n'/}"
  update_state_field "coverage_history" "\"$updated\""
}

# append_coverage_trend <slug> <fulfilled_lens_count>
# ONE JSONL line per COMPLETED review → .claude/blueprint-coverage-trend.local
# (gitignored). Cross-review history for the chronic-degradation check.
append_coverage_trend() {
  local slug="$1" count="$2"
  local trend_file="$STATE_DIR/blueprint-coverage-trend.local"
  mkdir -p "$STATE_DIR"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Build the JSONL line with python3 so a slug containing quotes/backslashes/
  # newlines cannot corrupt the trend file. Values passed via env (not argv) to
  # avoid any shell-quoting concerns. count is coerced to int (default 0).
  if ! _CT_TS="$ts" _CT_SLUG="$slug" _CT_COUNT="$count" python3 -c '
import json, os
print(json.dumps({
    "ts": os.environ["_CT_TS"],
    "slug": os.environ["_CT_SLUG"],
    "fulfilled_lens_count": int(os.environ.get("_CT_COUNT") or 0),
}, separators=(",", ":")))
' >> "$trend_file" 2>/dev/null; then
    # Fallback if python3 is unavailable: strip characters that would break JSONL.
    local safe_slug
    safe_slug=$(printf '%s' "$slug" | tr -d '"\\\n\r')
    printf '{"ts":"%s","slug":"%s","fulfilled_lens_count":%s}\n' "$ts" "$safe_slug" "$count" >> "$trend_file"
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
    sys.stderr.write("warning: issues_history is corrupt (" + str(e) + "); skipping trajectory check\n")
    sys.exit(2)
if not isinstance(h, list) or len(h) < window + 1:
    sys.exit(1)
recent = h[-(window + 1):]
if recent[-1] < recent[0]:
    sys.exit(1)
sys.exit(0)
'
}
