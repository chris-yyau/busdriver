#!/usr/bin/env bash
# Regression tests for blueprint-review state management.
#
# Guards against the high_issues_history YAML serialization bug where
# jq's default pretty-print produced multi-line array output that
# update_state_field could only partially overwrite, leaving orphan
# YAML lines that broke the trajectory check.
#
# Usage: bash tests/test-blueprint-review-state.sh
# Exit:  0 if all pass, 1 if any fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/skills/blueprint-review/scripts/lib/state_management.sh"

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n        expected: %q\n        actual:   %q\n" \
      "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local name="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if [[ "$condition" == "true" ]]; then
    printf "  PASS  %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  FAIL  %s\n" "$name"
    FAIL=$((FAIL + 1))
  fi
}

# ── Sandbox setup ─────────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"

mkdir -p .claude "docs/reviews/test-slug"
echo "test-slug" > .claude/current-design-review.local

STATE_FILE="docs/reviews/test-slug/state.md"

# shellcheck source=/dev/null
source "$LIB"

write_state() { cat > "$STATE_FILE"; }

# Read the raw YAML line for a field (preserves quoting, no quote-stripping).
read_field_raw() {
  awk -v f="$1" '
    /^---$/ { in_yaml = !in_yaml; next }
    in_yaml && $0 ~ "^" f ":" { print; exit }
  ' "$STATE_FILE"
}

# Count lines inside frontmatter that look like orphan continuation
# (don't start with a key, comment, blank, or ---).
count_orphan_lines() {
  awk '
    /^---$/ { yaml_count++; next }
    yaml_count == 1 {
      if ($0 == "" || $0 ~ /^#/ || $0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:/) next
      print
    }
  ' "$STATE_FILE" | wc -l | tr -d ' '
}

# ── append_high_history: single-line invariant ────────────────────────
echo "── append_high_history single-line invariant ────────────────"

write_state <<'EOF'
---
active: true
high_issues_history: "[]"
early_stopped: ""
---
body
EOF

append_high_history 1
assert_eq "first append produces single-line JSON-as-string" \
  'high_issues_history: "[1]"' "$(read_field_raw high_issues_history)"
assert_eq "no orphan lines after first append" "0" "$(count_orphan_lines)"

append_high_history 2
assert_eq "second append accumulates" \
  'high_issues_history: "[1,2]"' "$(read_field_raw high_issues_history)"

append_high_history 3
assert_eq "third append accumulates" \
  'high_issues_history: "[1,2,3]"' "$(read_field_raw high_issues_history)"
assert_eq "still single-line and no orphans" "0" "$(count_orphan_lines)"

# ── Pre-existing multi-line corruption: salvage what we can ───────────
echo "── multi-line corruption repair (salvageable prefix) ────────"

write_state <<'EOF'
---
active: true
high_issues_history: "[2]"
  1
]"
early_stopped: ""
---
body
EOF

# get_state_field returns "[2]" (parses), so we recover [2] and append 4 → [2,4].
append_high_history 4
assert_eq "corrupt state with parseable prefix recovers" \
  'high_issues_history: "[2,4]"' "$(read_field_raw high_issues_history)"
assert_eq "orphan tail is cleaned up" "0" "$(count_orphan_lines)"
assert_true "early_stopped field still present after repair" \
  "$([[ "$(read_field_raw early_stopped)" == 'early_stopped: ""' ]] && echo true || echo false)"

# ── Pre-existing corruption with unparseable prefix: reset cleanly ────
echo "── corruption with unparseable prefix → reset to [] ─────────"

write_state <<'EOF'
---
active: true
high_issues_history: "["
  1
]"
early_stopped: ""
---
body
EOF

# get_state_field returns "[" — invalid JSON. New code resets to [] and appends.
STDERR_FILE="$SANDBOX/stderr.log"
append_high_history 5 2> "$STDERR_FILE"
assert_eq "unparseable prefix resets to [] then appends" \
  'high_issues_history: "[5]"' "$(read_field_raw high_issues_history)"
assert_true "warning printed to stderr on corruption" \
  "$(grep -qi corrupt "$STDERR_FILE" && echo true || echo false)"
assert_eq "orphan tail cleaned up" "0" "$(count_orphan_lines)"

# ── check_no_progress: exit codes ─────────────────────────────────────
echo "── check_no_progress trajectory logic ───────────────────────"

run_check() {
  set +e
  check_no_progress "$1" "${2:-1}" 2>/dev/null
  local rc=$?
  set -e
  echo "$rc"
}

assert_eq "[1,2] (HIGH didn't decrease) → exit 0 (no progress)" "0" \
  "$(run_check '[1,2]')"
assert_eq "[2,1] (HIGH decreased) → exit 1 (progressing)" "1" \
  "$(run_check '[2,1]')"
assert_eq "[1] (insufficient data) → exit 1" "1" \
  "$(run_check '[1]')"
assert_eq "[] (empty) → exit 1" "1" \
  "$(run_check '[]')"

# ── check_no_progress: parse error fails loud ─────────────────────────
echo "── check_no_progress on corrupt input ───────────────────────"

set +e
STDERR=$(check_no_progress "[1," 1 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "corrupt JSON → exit 2 (distinguishable from progress)" "2" "$RC"
assert_true "warning printed to stderr on corrupt JSON" \
  "$(echo "$STDERR" | grep -qi corrupt && echo true || echo false)"

# ── check_no_progress: python injection is neutralized ────────────────
echo "── check_no_progress python injection guard ────────────────"

# A historical-style state.md attack would embed python that closes the
# triple-single-quoted heredoc. Pre-fix, this would execute arbitrary code.
# Post-fix, the value is passed via env var and cannot escape the source.
INJECTION_FILE="$SANDBOX/injection-marker.txt"
rm -f "$INJECTION_FILE"
PAYLOAD="''' + __import__('os').system('touch ${INJECTION_FILE}') + '''"
set +e
STDERR=$(check_no_progress "$PAYLOAD" 1 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "injection payload → treated as corrupt JSON (exit 2)" "2" "$RC"
assert_true "injection did not execute (no marker file)" \
  "$([[ ! -e "$INJECTION_FILE" ]] && echo true || echo false)"

# Non-numeric window must not reach python — guard fires early.
set +e
STDERR=$(check_no_progress "[1,2]" "1; import os" 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "non-numeric window → exit 2, never reaches python" "2" "$RC"
assert_true "stderr warns about positive-integer window guard" \
  "$(echo "$STDERR" | grep -qiE 'positive|numeric' && echo true || echo false)"

# window=0 must be rejected — would otherwise produce a degenerate
# h[-1:] slice (single element compared to itself → always "no progress"),
# firing auto-stop on a single-iteration run.
set +e
STDERR=$(check_no_progress "[1,2,3]" "0" 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "window=0 → exit 2 (rejected as non-positive)" "2" "$RC"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "── Summary ──────────────────────────────────────────────────"
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
[[ $FAIL -eq 0 ]]
