#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Check that each env var has a case-based numeric guard in its file
check_guard() {
  local file="$1" var_name="$2"
  # Check for the [!0-9] pattern within 3 lines of the variable name
  if grep -A3 "$var_name" "$SCRIPT_DIR/$file" | grep -q '\[!0-9\]'; then
    ok "$var_name has numeric validation in $file"
  else
    fail "$var_name missing numeric validation in $file"
  fi
}

check_guard "skills/codex-reviewer/scripts/run-review-loop.sh" "CODEX_MAX_ENRICHMENT_LINES"
check_guard "skills/codex-reviewer/scripts/lib/docs-context.sh" "CODEX_MAX_DOC_SNIPPETS"
check_guard "skills/codex-reviewer/scripts/lib/smart-context.sh" "CODEX_MAX_CONTEXT_LINES"
check_guard "skills/codex-reviewer/scripts/lib/smart-context.sh" "CODEX_MAX_FUNCTIONS"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
