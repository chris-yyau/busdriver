#!/usr/bin/env bash
# Test: mcp-health-check resolves MCP config from the hook PAYLOAD cwd, not
# process.cwd() (#351).
#
# WHY it matters: under sanitized-node.sh the hook runs from `/` (its cd / neutral-cwd
# step), so process.cwd() no longer points at the repo. If config were resolved from
# process.cwd(), every project-scoped MCP server would silently become "No config
# found → skip probe" — the health gate would go dark. The hook now reads `cwd` from
# the PreToolUse JSON instead. This test pins that: same process.cwd(), config found
# ONLY when the payload carries the right cwd.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/scripts/hooks/mcp-health-check.js"
PASS=0; FAIL=0
assert() { if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONFIG_DIR="$TMP/repo"; OTHER_DIR="$TMP/elsewhere"; HOME_DIR="$TMP/home"
mkdir -p "$CONFIG_DIR" "$OTHER_DIR" "$HOME_DIR"
# An http server on port 1 (ECONNREFUSED, no network, instant) — a resolved config
# means the hook PROBES it, finds it unreachable, and BLOCKS (exit 2). An unresolved
# config means "skip probe" (exit 0). Exit code is the discriminator.
printf '{"mcpServers":{"testsrv":{"type":"http","url":"http://127.0.0.1:1/"}}}' > "$CONFIG_DIR/.claude.json"

run() {  # run <payload-cwd-json-fragment>  → prints exit code; always launched from OTHER_DIR
  local frag="$1"
  ( cd "$OTHER_DIR" \
    && printf '{"tool_name":"mcp__testsrv__ping"%s}' "$frag" \
       | HOME="$HOME_DIR" CLAUDE_HOOK_EVENT_NAME=PreToolUse \
         ECC_MCP_HEALTH_STATE_PATH="$TMP/state-$RANDOM.json" \
         node "$HOOK" >/dev/null 2>&1 )
  printf '%s' "$?"
}

# Case A: payload cwd points at the config dir → config resolves → probe fails → block (2).
rc_a="$(run ",\"cwd\":\"$CONFIG_DIR\"")"
if [[ "$rc_a" == "2" ]]; then assert 0 "payload cwd=<config dir>: config resolved, unreachable server blocks (exit 2, got $rc_a)"
else assert 1 "payload cwd=<config dir>: config resolved, unreachable server blocks (exit 2, got $rc_a)"; fi

# Case B: no payload cwd → falls back to process.cwd()=OTHER_DIR (no config) → skip (0).
# Proves the resolution keys off the PAYLOAD cwd, not the process cwd.
rc_b="$(run "")"
if [[ "$rc_b" == "0" ]]; then assert 0 "no payload cwd: falls back to process.cwd() (no config there), skips probe (exit 0, got $rc_b)"
else assert 1 "no payload cwd: falls back to process.cwd() (no config there), skips probe (exit 0, got $rc_b)"; fi

# Case C: a RELATIVE payload cwd must be REJECTED (absolute-only guard). Run from the
# PARENT of the config dir and pass the config dir's basename as a relative cwd: with the
# guard, "repo" is rejected → fall back to process.cwd()=$TMP (no config) → skip (0).
# WITHOUT the guard, path.join would resolve "repo/.claude.json" against $TMP and FIND the
# config → block (2). So exit 0 is the proof the relative value was refused.
rc_c="$( cd "$TMP" \
  && printf '{"tool_name":"mcp__testsrv__ping","cwd":"repo"}' \
     | HOME="$HOME_DIR" CLAUDE_HOOK_EVENT_NAME=PreToolUse ECC_MCP_HEALTH_STATE_PATH="$TMP/state-c.json" \
       node "$HOOK" >/dev/null 2>&1; printf '%s' "$?" )"
if [[ "$rc_c" == "0" ]]; then assert 0 "relative payload cwd rejected by absolute-only guard, skips probe (exit 0, got $rc_c)"
else assert 1 "relative payload cwd rejected by absolute-only guard, skips probe (exit 0, got $rc_c)"; fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL MCP-HEALTH PAYLOAD-CWD ASSERTIONS PASSED"
