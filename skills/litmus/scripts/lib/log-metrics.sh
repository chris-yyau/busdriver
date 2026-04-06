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
  local json_output="${6:-"{}"}"

  mkdir -p "$(dirname "$METRICS_FILE")"

  # Extract severity breakdown — litmus schema uses lowercase: high/medium/low (no critical)
  local sev_critical sev_high sev_medium sev_low
  sev_critical=0
  sev_high=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "high")] | length' 2>/dev/null || echo 0)
  sev_medium=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "medium")] | length' 2>/dev/null || echo 0)
  sev_low=$(echo "$json_output" | jq '[.issues[]? | select(.severity == "low")] | length' 2>/dev/null || echo 0)

  # Get commit context
  local commit_sha branch_name
  commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  branch_name=$(git branch --show-current 2>/dev/null || echo "unknown")

  # Normalize PR base (match run-review-loop.sh normalization)
  local pr_base="${LITMUS_PR_BASE:-origin/main}"
  if [[ "$mode" == "pr" && -n "${LITMUS_PR_BASE:-}" && "$pr_base" != origin/* ]]; then
    pr_base="origin/${pr_base}"
  fi

  # Diff size (lines changed) — match both singular and plural forms from git stat
  # shellcheck disable=SC2312
  local diff_lines
  if [[ "$mode" == "pr" ]]; then
    diff_lines=$(git diff "${pr_base}...HEAD" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion[s]?|[0-9]+ deletion[s]?' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  else
    diff_lines=$(git diff --cached --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion[s]?|[0-9]+ deletion[s]?' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo 0)
  fi

  # Use jq to build JSON safely (handles escaping of branch names, etc.)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "$status" \
    --argjson issues "$issue_count" \
    --argjson iteration "$iteration" \
    --arg mode "$mode" \
    --arg cli "$cli" \
    --argjson sev_c "$sev_critical" \
    --argjson sev_h "$sev_high" \
    --argjson sev_m "$sev_medium" \
    --argjson sev_l "$sev_low" \
    --arg commit "$commit_sha" \
    --arg branch "$branch_name" \
    --argjson diff_lines "${diff_lines:-0}" \
    -c '{ts:$ts,status:$status,issues:$issues,iteration:$iteration,mode:$mode,cli:$cli,severity:{critical:$sev_c,high:$sev_h,medium:$sev_m,low:$sev_l},commit:$commit,branch:$branch,diff_lines:$diff_lines}' \
    >> "$METRICS_FILE" 2>/dev/null || true
}
