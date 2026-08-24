#!/usr/bin/env bash
# Regression for #542: litmus severity taxonomy must match review-output.schema.json
# (high|medium|low). The builtin-fallback prompt and metrics writer must not drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_METRICS="$ROOT/skills/litmus/scripts/lib/log-metrics.sh"
SKILL="$ROOT/skills/litmus/SKILL.md"
REPORT="$ROOT/scripts/litmus-metrics-report.sh"

pass=0
fail=0

assert() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

assert_not() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL: $name"
    fail=$((fail + 1))
  else
    echo "PASS: $name"
    pass=$((pass + 1))
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export BUSDRIVER_STATE_DIR="$TMP"
export LITMUS_METRICS_FILE="$TMP/review-metrics.jsonl"
# shellcheck source=/dev/null
source "$LOG_METRICS"

json='{"status":"FAIL","issues":[{"severity":"high","file":"a.py","line":1},{"severity":"medium","file":"b.py","line":2},{"severity":"low","file":"c.py","line":3}]}'
log_review_metrics "FAIL" "3" "1" "commit" "test" "$json"

metrics_line=$(tail -1 "$TMP/review-metrics.jsonl")

has_severity_critical() {
  jq -e 'has("severity") and (.severity | has("critical"))' <<<"$1" >/dev/null 2>&1
}

severity_keys_match() {
  jq -e '.severity | keys | sort == ["high","low","medium"]' <<<"$1" >/dev/null
}

severity_counts_match() {
  jq -e '.severity.high == 1 and .severity.medium == 1 and .severity.low == 1' <<<"$1" >/dev/null
}

assert_not "log-metrics omits severity.critical" has_severity_critical "$metrics_line"

assert "log-metrics severity keys are high|medium|low only" severity_keys_match "$metrics_line"

assert "log-metrics counts high/medium/low correctly" severity_counts_match "$metrics_line"

fallback_block=$(sed -n '/## Builtin Fallback (Exit Code 3)/,/^## /p' "$SKILL")

assert "SKILL.md fallback JSON format uses high|medium|low" \
  grep -q 'high|medium|low' <<<"$fallback_block"

assert_not "SKILL.md fallback JSON format has no CRITICAL|HIGH|MEDIUM|LOW" \
  grep -q 'CRITICAL|HIGH|MEDIUM|LOW' <<<"$fallback_block"

assert "SKILL.md fallback blocking parse is fail-closed on non-low severities" \
  grep -q 'not exactly `low`' <<<"$fallback_block"

assert "SKILL.md fallback blocking parse treats unrecognized severities as blocking" \
  grep -q 'Unrecognized or out-of-enum severities count as blocking' <<<"$fallback_block"

assert_not "SKILL.md fallback blocking parse has no CRITICAL/HIGH/MEDIUM prose" \
  grep -q 'CRITICAL/HIGH/MEDIUM' <<<"$fallback_block"

report_has_dashboard_labels_in() {
  local f="$1"
  grep -q 'HIGH:' "$f" && grep -q 'MEDIUM:' "$f" && grep -q 'LOW:' "$f"
}

report_has_dashboard_labels() {
  report_has_dashboard_labels_in "$REPORT"
}

assert_not "litmus-metrics-report does not aggregate severity.critical" \
  grep -q 'severity\.critical' "$REPORT"

assert "litmus-metrics-report dashboard labels include HIGH/MEDIUM/LOW" \
  report_has_dashboard_labels

fixture_missing_medium="$TMP/fixture-missing-medium.txt"
printf '%s\n' '  HIGH: 1' '  LOW: 1' >"$fixture_missing_medium"

assert_not "dashboard label helper fails closed when MEDIUM label absent" \
  report_has_dashboard_labels_in "$fixture_missing_medium"

assert_not "litmus-metrics-report dashboard has no CRITICAL label" \
  grep -q 'CRITICAL:' "$REPORT"

sample="$TMP/sample-metrics.jsonl"
printf '%s\n' "$metrics_line" >"$sample"
export LITMUS_METRICS_FILE="$sample"
dashboard=$(bash "$REPORT" 2>/dev/null || true)

assert "litmus-metrics-report renders HIGH count" grep -q 'HIGH: 1' <<<"$dashboard"
assert "litmus-metrics-report renders MEDIUM count" grep -q 'MEDIUM: 1' <<<"$dashboard"
assert "litmus-metrics-report renders LOW count" grep -q 'LOW: 1' <<<"$dashboard"
assert_not "litmus-metrics-report renders no CRITICAL line" grep -q 'CRITICAL:' <<<"$dashboard"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
