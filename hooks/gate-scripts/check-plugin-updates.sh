#!/usr/bin/env bash
# SessionStart hook: detect if plugin updates need attention.
# Minimal detection only — the agent does all the work.
set -e

NEEDS_AGENT=false
REASONS=()

# ── 1. Patcher alert (cache version changed, patches applied/failed) ───
ALERT_FILE="$HOME/.claude/homunculus/.plugin-update-alert"
if [ -f "$ALERT_FILE" ]; then
  rm -f "$ALERT_FILE"
  REASONS+=("Plugin cache updated")
  NEEDS_AGENT=true
fi

# ── 2. ECC upstream has new commits ────────────────────────────────────
ECC_MARKETPLACE="$HOME/.claude/plugins/marketplaces/everything-claude-code"
if [ -d "$ECC_MARKETPLACE/.git" ]; then
  cd "$ECC_MARKETPLACE"
  git fetch origin --quiet 2>/dev/null || true
  BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
  if [ "$BEHIND" -gt 0 ] 2>/dev/null; then
    REASONS+=("ECC upstream ${BEHIND} commits ahead")
    NEEDS_AGENT=true
  fi
fi

# ── 3. Emit ────────────────────────────────────────────────────────────
[ "$NEEDS_AGENT" = false ] && exit 0

REASON_STR=$(IFS='; '; echo "${REASONS[*]}")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<update-alert>\n${REASON_STR}.\nDo NOT act now. Present to user AFTER current task completes.\n\nWhen user explicitly says 'update plugins' or 'sync ecc', use ultrathink reasoning:\n1. Pull ECC upstream: cd ~/.claude/plugins/marketplaces/everything-claude-code && git pull --ff-only origin main\n2. Run patcher: bash ~/.claude/hooks/patch-plugin-overrides.sh (check for fork-custom-files conflicts in output)\n3. Diff new/removed/renamed skills and agents between fork and upstream\n4. Update orchestrator SKILL.md Non-Pipeline Tasks table (single rows only, NO skill descriptions)\n5. Update domain-supplements.md for language-specific skills\n6. If new {lang}-reviewer or {lang}-build-resolver agents added, update Phase 4 DISPATCH rules\n7. Check new skills for security concerns (git clone, npm install, external URLs) — apply review-first hardening if needed, add to .fork-custom-files\n8. Update MANIFEST.md fork-edit entries if upstream merged our fixes\n9. Check patch anchors still match upstream (observe.sh entrypoint, hooks.json patterns)\n10. Run codex review, then commit and push\n</update-alert>"
  }
}
EOF
