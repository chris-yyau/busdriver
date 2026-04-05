#!/usr/bin/env bash
#
# log-metrics.sh — Append litmus review outcomes to a persistent JSONL log.
#
# Called from run-review-loop.sh after merge-findings determines the final verdict.
# Accumulates data over time so you can answer: "what's litmus's recall rate?"
#
# Usage (sourced):
#   source "$SCRIPT_DIR/lib/log-metrics.sh"
#   log_review_metrics "$status" "$issue_count" "$iteration" "$mode" "$cli" "$json_output"
#
# Output: appends one JSON line to .claude/review-metrics.jsonl
#

METRICS_FILE="${LITMUS_METRICS_FILE:-.claude/review-metrics.jsonl}"

log_review_metrics() {
  local status="${1:-UNKNOWN}"
  local issue_count="${2:-0}"
  local iteration="${3:-1}"
  local mode="${4:-commit}"       # commit | pr
  local cli="${5:-unknown}"       # codex | claude | etc
  local json_output="${6:-{}}"

  mkdir -p "$(dirname "$METRICS_FILE")"

  # Extract severity breakdown from the full JSON output
  local sev_critical sev_high sev_medium sev_low
  sev_critical=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "CRITICAL")] | length' 2>/dev/null || echo 0)
  sev_high=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "HIGH")] | length' 2>/dev/null || echo 0)
  sev_medium=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "MEDIUM")] | length' 2>/dev/null || echo 0)
  sev_low=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "LOW")] | length' 2>/dev/null || echo 0)

  # Get commit context
  local commit_sha branch_name
  commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  branch_name=$(git branch --show-current 2>/dev/null || echo "unknown")

  # Diff size (lines changed)
  local diff_lines
  if [[ "$mode" == "pr" ]]; then
    diff_lines=$(git diff "${LITMUS_PR_BASE:-origin/main}...HEAD" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  else
    diff_lines=$(git diff --cached --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  fi

  # Build the metrics entry
  printf '{"ts":"%s","status":"%s","issues":%d,"iteration":%d,"mode":"%s","cli":"%s","severity":{"critical":%d,"high":%d,"medium":%d,"low":%d},"commit":"%s","branch":"%s","diff_lines":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$status" \
    "$issue_count" \
    "$iteration" \
    "$mode" \
    "$cli" \
    "$sev_critical" \
    "$sev_high" \
    "$sev_medium" \
    "$sev_low" \
    "$commit_sha" \
    "$branch_name" \
    "${diff_lines:-0}" \
    >> "$METRICS_FILE" 2>/dev/null || true
}
