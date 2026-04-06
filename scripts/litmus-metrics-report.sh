#!/usr/bin/env bash
#
# litmus-metrics-report.sh — Analyze persistent litmus review metrics.
#
# Usage:
#   litmus-metrics-report.sh              Show summary dashboard
#   litmus-metrics-report.sh --recent N   Show last N entries
#   litmus-metrics-report.sh --raw        Dump raw JSONL
#
set -euo pipefail

METRICS_FILE="${LITMUS_METRICS_FILE:-.claude/review-metrics.jsonl}"

if [[ ! -f "$METRICS_FILE" ]]; then
  echo "No metrics data yet. Metrics are recorded automatically by litmus reviews."
  echo "File: $METRICS_FILE"
  exit 0
fi

TOTAL=$(wc -l < "$METRICS_FILE" | tr -d ' ')

case "${1:-}" in
  --raw)
    cat "$METRICS_FILE"
    exit 0
    ;;
  --recent)
    N="${2:-10}"
    tail -"$N" "$METRICS_FILE" | jq -r '"[\(.ts)] \(.status) | \(.mode) | issues:\(.issues) iter:\(.iteration) | \(.commit) \(.branch)"'
    exit 0
    ;;
  --help|-h)
    echo "Usage: litmus-metrics-report.sh [--recent N | --raw | --help]"
    exit 0
    ;;
esac

echo "Litmus Review Metrics"
echo "====================="
echo ""

# Pass/fail rates — use jq -s for reliable counting
PASS_COUNT=$(jq -s '[.[] | select(.status == "PASS")] | length' "$METRICS_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$(jq -s '[.[] | select(.status == "FAIL")] | length' "$METRICS_FILE" 2>/dev/null || echo 0)

echo "Total reviews: $TOTAL"
echo "  PASS: $PASS_COUNT"
echo "  FAIL: $FAIL_COUNT"
if [[ "$TOTAL" -gt 0 ]]; then
  PASS_RATE=$((PASS_COUNT * 100 / TOTAL))
  echo "  Pass rate: ${PASS_RATE}%"
fi
echo ""

# Mode breakdown
COMMIT_COUNT=$(jq -s '[.[] | select(.mode == "commit")] | length' "$METRICS_FILE" 2>/dev/null || echo 0)
PR_COUNT=$(jq -s '[.[] | select(.mode == "pr")] | length' "$METRICS_FILE" 2>/dev/null || echo 0)
echo "By mode:"
echo "  Commit reviews: $COMMIT_COUNT"
echo "  PR reviews: $PR_COUNT"
echo ""

# Severity distribution (across all reviews)
echo "Severity distribution (total across all reviews):"
jq -s '{ critical: ([.[].severity.critical] | add // 0), high: ([.[].severity.high] | add // 0), medium: ([.[].severity.medium] | add // 0), low: ([.[].severity.low] | add // 0) }' "$METRICS_FILE" 2>/dev/null | jq -r '"  CRITICAL: \(.critical)\n  HIGH: \(.high)\n  MEDIUM: \(.medium)\n  LOW: \(.low)"' 2>/dev/null || echo "  (unable to parse severity data)"
echo ""

# Average iterations to pass
AVG_ITER=$(jq -s '[.[] | select(.status == "PASS") | .iteration] | if length > 0 then (add / length * 10 | round / 10) else 0 end' "$METRICS_FILE" 2>/dev/null || echo "N/A")
echo "Average iterations to PASS: $AVG_ITER"
echo ""

# Recent 5
echo "Recent reviews:"
tail -5 "$METRICS_FILE" | jq -r '"  [\(.ts | split("T")[0])] \(.status) | \(.mode) | issues:\(.issues) iter:\(.iteration) | \(.commit) \(.branch)"' 2>/dev/null || echo "  (unable to parse recent entries)"
