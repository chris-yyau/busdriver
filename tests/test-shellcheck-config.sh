#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAST_RUNNER="$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/sast-runner.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Verify the sast-runner passes --enable flag or sources a .shellcheckrc
if grep -qE '(--enable|shellcheckrc|CODEX_SHELLCHECK_ENABLE)' "$SAST_RUNNER"; then
  ok "ShellCheck runner has enable/config support"
else
  fail "ShellCheck runner missing enable/config support"
fi

# Verify severity mapping includes all ShellCheck levels
for level in error warning info style; do
  if grep -q "'$level'" "$SAST_RUNNER"; then
    ok "ShellCheck severity map includes: $level"
  else
    fail "ShellCheck severity map missing: $level"
  fi
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
