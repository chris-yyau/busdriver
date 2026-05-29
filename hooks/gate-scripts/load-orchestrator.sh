#!/usr/bin/env bash
# SessionStart hook: inject orchestrator skill into Claude's context
# Mirrors the superpowers session-start.sh hookSpecificOutput pattern
# Also: gate dependency health check, memory staleness enforcement, instinct loading

set -euo pipefail

# ── Ensure common tool paths are available (non-login shell fallback) ─────
# Hook commands may run in non-login shells where homebrew/nix paths are absent.
for _dir in /opt/homebrew/bin /usr/local/bin /opt/pkg/env/active/bin; do
    if [ -d "$_dir" ] && [[ ":$PATH:" != *":$_dir:"* ]]; then
        export PATH="$_dir:$PATH"
    fi
done

# ── Skip for internal observer sessions ───────────────────────────────────
# The ECC observer spawns `claude --model haiku` subprocesses for analysis.
# Those subprocesses trigger SessionStart hooks including this one.
# Loading the full orchestrator context into a haiku subprocess is wasteful
# and can cause the model to attempt starting another observer (recursion).
if [ "${CLAUDE_HOMUNCULUS_INTERNAL:-}" = "1" ]; then
    exit 0
fi

# ── Gate dependency health check ──────────────────────────────────────────
# Gate hooks now fail-CLOSED when python3 is missing (block_emit via printf).
# jq is optional — block_emit falls back to printf when jq is absent.
# This check runs once at session start and warns if deps are absent.
GATE_HEALTH_WARNINGS=""
if ! command -v python3 &>/dev/null; then
    # python3 is missing — this script itself depends on python3 for JSON output,
    # so we must emit the warning as raw hookSpecificOutput JSON using printf.
    # Note: gate hooks fail-CLOSED (block via printf) when python3 is missing,
    # so gates are NOT silently disabled — they block ALL gated actions.
    # shellcheck disable=SC2016 # Intentional: literal \n escape sequences, not shell expansions
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"## CRITICAL: python3 not found\\n\\nAll review gates (litmus, blueprint-review, pre-implementation, pre-commit) will BLOCK every gated action because gate hooks fail-CLOSED without python3. Gates cannot parse tool input to determine if the action is actually a commit — so they block everything as a precaution.\\n\\n**Install python3 immediately to restore normal gate operation.** Until then, use `.claude/skip-litmus.local` or `.claude/skip-design-review.local` to bypass individual blocked actions."}}\n'
    exit 0
fi
if ! command -v jq &>/dev/null; then
    GATE_HEALTH_WARNINGS="${GATE_HEALTH_WARNINGS}\n**WARNING: jq not found.** Gate hooks use a printf fallback to emit block decisions — enforcement still works but JSON output may be less robust with special characters. Install jq for reliable gate output.\n\n\`brew install jq\` or \`apt-get install jq\`"
fi
if ! command -v codex &>/dev/null; then
    GATE_HEALTH_WARNINGS="${GATE_HEALTH_WARNINGS}\n**WARNING: codex CLI not found.** Litmus will run in DEGRADED mode (marker-only, no automated review). Install codex CLI for full code review enforcement.\n\n\`npm install -g @openai/codex\`"
fi

# ── Design review state cleanup (F10 fix, updated F11) ────────────────────
# Check for stale design-review-needed.local.md from previous sessions.
# Validates entries (removes resolved ones) but does NOT auto-expire stale state.
# Stale reviews persist until explicitly completed or manually skipped.
DESIGN_STATE=".claude/design-review-needed.local.md"
DESIGN_CLEANUP_MSG=""
HOOK_LIB_DIR="$(cd "$(dirname "$0")" && pwd)/lib"
if [ -f "$DESIGN_STATE" ]; then
    DESIGN_CLEANUP_MSG=$(python3 "$HOOK_LIB_DIR/design_cleanup.py" 2>/dev/null || true)
fi

# Resolve orchestrator SKILL.md — prefer plugin location, fall back to legacy
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md" ]; then
    SKILL_FILE="${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md"
elif [ -f "${HOME}/.claude/skills/orchestrator/SKILL.md" ]; then
    SKILL_FILE="${HOME}/.claude/skills/orchestrator/SKILL.md"
else
    SKILL_FILE="${CLAUDE_PLUGIN_ROOT:-${HOME}/.claude}/skills/orchestrator/SKILL.md"
fi

# Read orchestrator content
content=$(cat "$SKILL_FILE" 2>&1 || echo "Error: orchestrator SKILL.md not found at ${SKILL_FILE}")

# ── Lean mode (opt-in) ────────────────────────────────────────────────────
# BUSDRIVER_ORCHESTRATOR_LEAN=1 injects a minimal router pointer instead of the
# full skill body (~3KB less context/session). A/B vehicle for measuring the
# routing-quality tradeoff before any permanent trim. Default (unset): full skill.
if [ "${BUSDRIVER_ORCHESTRATOR_LEAN:-}" = "1" ]; then
    content="# Master Orchestrator (lean mode)

Feature work follows the 6-phase pipeline — do NOT use EnterPlanMode for it. INVOKE \`busdriver:brainstorming\` (Phase 1, vague idea) or \`busdriver:writing-plans\` (Phase 2, clear requirements); Phases 3–6 auto-execute after plan review passes.

Gates are hook-enforced and CANNOT be bypassed by Claude: pre-commit (litmus), pre-PR (litmus deep), pre-implementation (design review), pre-merge (pr-grind), freeze. Skip only via \`.claude/skip-*.local\` files the user creates in their own terminal.

**Full routing, gates table, phase detail, domain detection, and emergency gate recovery:** Read \`${SKILL_FILE}\` now if the task is non-trivial or you are unsure which skill applies."
fi

# Append design review cleanup message if any
if [ -n "$DESIGN_CLEANUP_MSG" ]; then
    content="${content}

<!-- BEGIN DESIGN REVIEW CLEANUP -->
## Design Review State (SessionStart)
${DESIGN_CLEANUP_MSG}
<!-- END DESIGN REVIEW CLEANUP -->"
fi

# Append gate health warnings if any dependencies are missing
if [ -n "$GATE_HEALTH_WARNINGS" ]; then
    content="${content}

<!-- BEGIN GATE HEALTH CHECK -->
## Gate Health Check (SessionStart)
$(printf '%b' "$GATE_HEALTH_WARNINGS")

**Action required:** Install missing dependencies before proceeding. Without them, review gates provide NO enforcement — commits and implementation bypass all quality checks.
<!-- END GATE HEALTH CHECK -->"
fi

# ── Notes staleness + Instinct loading (parallelized) ─────────────────────
# Run both python3 scripts in parallel to reduce SessionStart latency.
# notes_staleness.py: scans ~/.claude/notes/ for stale last_validated dates.
# load_instincts.py: loads reflection system instincts.
NOTES_TMP=$(mktemp) || NOTES_TMP=""
INSTINCT_TMP=$(mktemp) || INSTINCT_TMP=""
# shellcheck disable=SC2064 # Intentional: expand paths now, not at trap time
trap "rm -f '$NOTES_TMP' '$INSTINCT_TMP'" EXIT

MEMORY_DIR="${HOME}/.claude/notes"
# Portable timeout: macOS lacks GNU timeout; fall back to bare python3
_run_with_timeout() {
    if command -v timeout &>/dev/null; then
        timeout "$@"
    else
        # Drop the timeout arg, run the command directly
        shift
        "$@"
    fi
}

if [ -d "$MEMORY_DIR" ] && [ -n "$NOTES_TMP" ]; then
    MEMORY_DIR_PY="$MEMORY_DIR" _run_with_timeout 5 python3 "$HOOK_LIB_DIR/notes_staleness.py" > "$NOTES_TMP" 2>/dev/null &
    NOTES_PID=$!
else
    NOTES_PID=""
fi

if [ -n "$INSTINCT_TMP" ]; then
    _run_with_timeout 5 python3 "$HOOK_LIB_DIR/load_instincts.py" > "$INSTINCT_TMP" 2>/dev/null &
    INSTINCT_PID=$!
else
    INSTINCT_PID=""
fi

# Wait for background processes — log failures but don't abort (set -e safe)
if [ -n "$NOTES_PID" ]; then
    if ! wait "$NOTES_PID" 2>/dev/null; then
        echo "[load-orchestrator] notes_staleness.py failed or timed out" >&2
    fi
fi
if [ -n "$INSTINCT_PID" ]; then
    if ! wait "$INSTINCT_PID" 2>/dev/null; then
        echo "[load-orchestrator] load_instincts.py failed or timed out" >&2
    fi
fi

staleness_output=""
[ -n "$NOTES_TMP" ] && [ -s "$NOTES_TMP" ] && staleness_output=$(cat "$NOTES_TMP")
instinct_output=""
[ -n "$INSTINCT_TMP" ] && [ -s "$INSTINCT_TMP" ] && instinct_output=$(cat "$INSTINCT_TMP")

if [ -n "$staleness_output" ]; then
    content="${content}

<!-- BEGIN NOTES STALENESS -->
${staleness_output}
<!-- END NOTES STALENESS -->"
fi

if [ -n "$instinct_output" ]; then
    content="${content}

<!-- BEGIN INSTINCTS -->
${instinct_output}
<!-- END INSTINCTS -->"
fi

# Output context injection as JSON — use python3 json.dumps for safe escaping
printf '%s' "$content" | python3 -c "
import sys, json
content = sys.stdin.read()
output = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': content
    }
}
print(json.dumps(output))
"

exit 0
