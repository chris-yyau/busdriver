#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/sast-runner.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Valid merge
result=$(_sast_merge_json '[{"a":1}]' '[{"b":2}]')
count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$count" = "2" ] && ok "Valid merge: 2 items" || fail "Valid merge: expected 2, got $count"

# Malformed input should produce a specific stderr warning (not silent, not a crash)
stderr_output=$(_sast_merge_json 'NOT_JSON' '[]' 2>&1 1>/dev/null || true)
if echo "$stderr_output" | grep -q "WARNING: Failed to parse SAST output line"; then
  ok "Malformed input produces expected WARNING message"
else
  fail "Malformed input does not produce expected WARNING (got: $stderr_output)"
fi

# Verify the merge still produces valid JSON output (not a crash)
stdout_output=$(_sast_merge_json 'NOT_JSON' '[{"a":1}]' 2>/dev/null)
count=$(echo "$stdout_output" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$count" = "1" ] && ok "Merge recovers gracefully (1 valid item)" || fail "Merge did not recover (got $count items)"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
