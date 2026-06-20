#!/usr/bin/env bash
# Tests for pre-implementation-gate.sh marker-file forge protection.
#
# Regression focus (PR #225, Codex finding): a SINGLE-QUOTED redirect target
#   printf ... > '.claude/pr-codex-lead.local.json'
# must be BLOCKED. The detector strips single-quoted substrings before the
# redirect search; checking only the stripped form removed the quoted path and
# let a quoted forge through as OK. The fix searches BOTH the raw and the
# stripped command, so a quoted redirect target is caught while an unrelated
# quoted mention (no redirect) still passes.
#
# Usage: bash tests/test-pre-implementation-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
GATE="$(pwd)/hooks/gate-scripts/pre-implementation-gate.sh"

# Pin the state dir and ensure no design review is pending, so the unconditional
# marker-protection block is what we exercise (it runs before the design gate).
export BUSDRIVER_STATE_DIR=.claude

PASS=0; FAIL=0
ok() { if [ "$1" = "$2" ]; then echo "  PASS  $3"; PASS=$((PASS+1)); else echo "  FAIL  $3 (got '$1' want '$2')"; FAIL=$((FAIL+1)); fi; }

# Feed a Bash command to the gate as a PreToolUse payload; echo block|allow.
# The command is JSON-encoded via python3 so quotes/redirects survive intact.
decide() {
  local cmd="$1" payload out
  payload=$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')
  out=$(printf '%s' "$payload" | bash "$GATE" 2>/dev/null)
  printf '%s' "$out" | grep -q '"block"' && echo block || echo allow
}

MARK=".claude/pr-codex-lead.local.json"

echo "== 1. quoted redirect to marker is blocked (regression) =="
ok "$(decide "printf 'x' > '$MARK'")" "block" "quoted '> marker' blocked"

echo "== 2. unquoted redirect to marker is blocked =="
ok "$(decide "printf 'x' > $MARK")" "block" "unquoted '> marker' blocked"

echo "== 3. tee to a quoted marker is blocked =="
ok "$(decide "echo x | tee '$MARK'")" "block" "quoted tee marker blocked"

echo "== 4. quoted rm of marker is blocked =="
ok "$(decide "rm -f '$MARK'")" "block" "quoted rm marker blocked"

echo "== 5. backstop artifact via quoted redirect is blocked =="
ok "$(decide "printf '{}' > '.claude/pr-backstop-verdict.local.json'")" "block" "quoted backstop redirect blocked"

echo "== 6. read-only check of a marker is allowed =="
ok "$(decide "[ -f $MARK ] && echo present")" "allow" "read-only marker check allowed"

echo "== 7. unrelated command is allowed =="
ok "$(decide "ls -la /tmp")" "allow" "unrelated command allowed"

echo ""
echo "  ── $PASS/$((PASS+FAIL)) passed ──"
[ "$FAIL" -eq 0 ]
