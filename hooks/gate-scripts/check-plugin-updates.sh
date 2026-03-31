#!/usr/bin/env bash
# SessionStart hook: detect if plugin updates need attention.
# Minimal detection only — the agent does all the work.
set -e

NEEDS_AGENT=false
REASONS=()

# ── 1. ECC upstream has new commits ────────────────────────────────────
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

# ── 2. Emit ────────────────────────────────────────────────────────────
[ "$NEEDS_AGENT" = false ] && exit 0

REASON_STR=$(IFS='; '; echo "${REASONS[*]}")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<update-alert>\n${REASON_STR}.\nDo NOT act now. Present to user AFTER current task completes.\n\nWhen user explicitly says 'update plugins' or 'sync ecc', use ultrathink reasoning:\n1. Pull ECC upstream: cd ~/.claude/plugins/marketplaces/everything-claude-code && git pull --ff-only origin main\n2. Diff new/removed/renamed skills and agents between fork and upstream\n3. Update orchestrator SKILL.md Non-Pipeline Tasks table (single rows only, NO skill descriptions)\n4. Update domain-supplements.md for language-specific skills\n5. If new {lang}-reviewer or {lang}-build-resolver agents added, update Phase 4 DISPATCH rules\n6. Check new skills for security concerns (git clone, npm install, external URLs) — apply review-first hardening if needed, add to .fork-custom-files\n7. Update MANIFEST.md fork-edit entries if upstream merged our fixes\n8. Check patch anchors still match upstream (observe.sh entrypoint, hooks.json patterns)\n9. Run codex review, then commit and push\n</update-alert>"
  }
}
EOF
