#!/usr/bin/env bash
# SessionEnd hook: auto-commit and push ~/.claude config changes
#
# Commits auto-generated pipeline state (instincts, observations, dispatch logs,
# plugin metadata) and pushes to origin. Only commits whitelisted paths.
# Non-auto-generated files are left untouched for manual review.
#
# Fail-open: errors never block exit.

set -euo pipefail
trap 'exit 0' ERR

# Consume stdin
cat > /dev/null 2>&1 || true

CLAUDE_DIR="${HOME}/.claude"

# Only run if we're in the ~/.claude repo
cd "$CLAUDE_DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree &>/dev/null || exit 0

# Auto-generated file patterns — machine-written, not human-written
AUTO_GEN_PATHS=(
    "homunculus/"
    "memory/"
    "metrics/"
    "plugins/blocklist.json"
    "plugins/config.json"
    "plugins/install-counts-cache.json"
    "plugins/installed_plugins.json"
    "plugins/known_marketplaces.json"
    "scripts/auto-backup.log"
    "session-aliases.json"
    ".claude/bypass-log.jsonl"
    "bypass-log.jsonl"
)

# Unstage only auto-generated paths to ensure a clean slate for them,
# without touching any user-staged files outside these paths
for pattern in "${AUTO_GEN_PATHS[@]}"; do
    git reset HEAD -- "$pattern" --quiet 2>/dev/null || true
done

# Stage only auto-generated files (including deletions via -A)
for pattern in "${AUTO_GEN_PATHS[@]}"; do
    # git add -A handles additions, modifications, AND deletions
    git add -A "$pattern" 2>/dev/null || true
done

# Verify ONLY auto-generated files are staged — abort if anything else crept in
while IFS= read -r staged_file; do
    [ -z "$staged_file" ] && continue
    is_auto=false
    for pattern in "${AUTO_GEN_PATHS[@]}"; do
        case "$pattern" in
            */) case "$staged_file" in ${pattern}*) is_auto=true; break ;; esac ;;
            *)  [ "$staged_file" = "$pattern" ] && is_auto=true && break ;;
        esac
    done
    if [ "$is_auto" = false ]; then
        # Non-auto-generated file is staged — unstage only auto-gen paths, leave user's index intact
        for p in "${AUTO_GEN_PATHS[@]}"; do
            git reset HEAD -- "$p" --quiet 2>/dev/null || true
        done
        exit 0
    fi
done < <(git diff --cached --name-only 2>/dev/null)

# Check if anything was actually staged
if git diff --cached --quiet 2>/dev/null; then
    exit 0  # Nothing to commit
fi

# Commit with a standard message
git commit -m "chore: auto-sync pipeline state

Auto-committed by SessionEnd hook: instincts, observations, dispatch logs, and plugin metadata." \
    2>/dev/null || exit 0

# Push to origin (fail silently — network issues shouldn't block exit)
git push origin HEAD 2>/dev/null || true

exit 0
