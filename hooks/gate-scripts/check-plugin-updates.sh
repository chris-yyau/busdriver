#!/usr/bin/env bash
# SessionStart hook: detect if plugin updates need attention.
# Minimal detection only — the agent does all the work.
set -e

NEEDS_AGENT=false
REASONS=()

# Resolve plugin root BEFORE any cd — used by version pin checks below
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"

# ── 1. ECC upstream has new commits ────────────────────────────────────
ECC_MARKETPLACE="$HOME/.claude/plugins/marketplaces/everything-claude-code"
if [ -d "$ECC_MARKETPLACE/.git" ]; then
  BEHIND=$(git -C "$ECC_MARKETPLACE" fetch origin --quiet 2>/dev/null && git -C "$ECC_MARKETPLACE" rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
  if [ "$BEHIND" -gt 0 ] 2>/dev/null; then
    REASONS+=("ECC upstream ${BEHIND} commits ahead")
    NEEDS_AGENT=true
  fi
fi

# ── 2. Pinned CLI version checks ─────────────────────────────────────
# Only check if codex is the configured review CLI and user hasn't suppressed checks.
if [ "${BUSDRIVER_SKIP_VERSION_CHECK:-0}" != "1" ]; then
  if [ -f "$PLUGIN_ROOT/scripts/lib/resolve-cli.sh" ]; then
    source "$PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
    RESOLVED_CLI=$(resolve_review_cli 2>/dev/null || echo "")
    if [ "$RESOLVED_CLI" = "codex" ] && is_cli_available codex; then
      if ! check_cli_version_pin codex 2>/dev/null; then
        INSTALLED_VER=$(get_cli_version codex | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        REASONS+=("codex CLI version changed: installed=${INSTALLED_VER}, pinned=${BUSDRIVER_CODEX_PINNED_VERSION}. Update BUSDRIVER_CODEX_PINNED_VERSION in resolve-cli.sh after testing")
        NEEDS_AGENT=true
      fi
    fi
  fi
fi

# ── 3. Emit ────────────────────────────────────────────────────────────
[ "$NEEDS_AGENT" = false ] && exit 0

REASON_STR=$(IFS='; '; echo "${REASONS[*]}")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<update-alert>\n${REASON_STR}.\nDo NOT act now. Present to user AFTER current task completes.\n\nWhen user explicitly says 'update plugins' or 'sync ecc', use ultrathink reasoning:\n1. Pull ECC upstream: cd ~/.claude/plugins/marketplaces/everything-claude-code && git pull --ff-only origin main\n2. Diff new/removed/renamed skills and agents between fork and upstream\n3. Update orchestrator SKILL.md Non-Pipeline Tasks table (single rows only, NO skill descriptions)\n4. Update domain-supplements.md for language-specific skills\n5. If new {lang}-reviewer or {lang}-build-resolver agents added, update Phase 4 DISPATCH rules\n6. Check new skills for security concerns (git clone, npm install, external URLs) — apply review-first hardening if needed, add to .fork-custom-files\n7. Update MANIFEST.md fork-edit entries if upstream merged our fixes\n8. Check patch anchors still match upstream (observe.sh entrypoint, hooks.json patterns)\n9. If codex CLI version changed, test review pipeline with new version, then bump BUSDRIVER_CODEX_PINNED_VERSION in resolve-cli.sh\n10. Run codex review, then commit and push\n</update-alert>"
  }
}
EOF
