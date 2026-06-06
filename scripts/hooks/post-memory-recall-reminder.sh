#!/usr/bin/env bash
# PostToolUse Hook — Memory-Recall Reminder (verify-before-assert reflex)
#
# Fires after a claude-mem memory *read* (search / get_observations / timeline /
# context / corpus query). Injects a terse reminder that recalled memory is a
# stale-by-default LEAD, not ground truth — confirm load-bearing facts against a
# primary source before asserting, or hedge the uncertainty explicitly.
#
# Pairs with the "Verify Before Asserting" clause in
# rules/common/investigate-before-acting.md.
#
# Non-blocking, fail-open. Emits PostToolUse additionalContext and never errors.
# Invoked via run-with-flags-shell.sh (profiles: standard,strict) so lean/minimal
# mode omits it and ECC_DISABLED_HOOKS=post:memory-recall-reminder can turn it off.
# $1 is the hook phase ("post") passed by the wrapper; unused here.

set -euo pipefail
trap 'exit 0' ERR

INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# Extract tool_name robustly (mirrors the parsing in check-design-document.sh)
TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', d.get('toolName', '')))
except Exception:
    print('')
" 2>/dev/null || true)

# Only fire on memory *read* tools — never on writes (add/record/build/prime/rebuild),
# which carry no recalled-fact risk.
case "$TOOL_NAME" in
  mcp__plugin_claude-mem_mcp-search__search|\
  mcp__plugin_claude-mem_mcp-search__smart_search|\
  mcp__plugin_claude-mem_mcp-search__memory_search|\
  mcp__plugin_claude-mem_mcp-search__observation_search|\
  mcp__plugin_claude-mem_mcp-search__get_observations|\
  mcp__plugin_claude-mem_mcp-search__timeline|\
  mcp__plugin_claude-mem_mcp-search__memory_context|\
  mcp__plugin_claude-mem_mcp-search__observation_context|\
  mcp__plugin_claude-mem_mcp-search__smart_outline|\
  mcp__plugin_claude-mem_mcp-search__smart_unfold|\
  mcp__plugin_claude-mem_mcp-search__query_corpus)
    ;;
  *)
    exit 0
    ;;
esac

REMINDER='Memory recall is a stale-by-default LEAD, not ground truth. Before asserting any recalled fact as current — repo/system state, what "we already did", counts or metrics, config/gate behavior, external API/version — confirm it against a primary source THIS session (git/Read/run/gh/measure), or hedge explicitly ("from memory, unverified"). Full taxonomy: rules/common/investigate-before-acting.md -> Verify Before Asserting.'

# Emit as PostToolUse additionalContext (surfaces to the model, non-blocking).
# Build JSON via python3 so the reminder text is escaped correctly.
printf '%s' "$REMINDER" | python3 -c "
import sys, json
print(json.dumps({
  'hookSpecificOutput': {
    'hookEventName': 'PostToolUse',
    'additionalContext': sys.stdin.read()
  }
}))
" 2>/dev/null || true

exit 0
