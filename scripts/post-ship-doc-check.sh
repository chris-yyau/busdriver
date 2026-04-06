#!/usr/bin/env bash
#
# post-ship-doc-check.sh — Identify docs that may need updating after code changes.
#
# Compares code changes against documentation to surface stale docs.
# Does NOT auto-update docs — reports what might need attention.
#
# Usage:
#   post-ship-doc-check.sh                    Check HEAD vs last tag
#   post-ship-doc-check.sh <range>            Check specific range
#   post-ship-doc-check.sh --since-commit SHA Check since a specific commit
#
set -euo pipefail

RANGE=""
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet|-q) QUIET=1 ;;
    --help|-h)
      echo "Usage: post-ship-doc-check.sh [RANGE | --since-commit SHA] [--quiet]"
      exit 0
      ;;
    --since-commit)
      shift
      RANGE="${1:-HEAD~1}..HEAD"
      ;;
    *) RANGE="$1" ;;
  esac
  shift
done

# Default range: last tag to HEAD
if [[ -z "$RANGE" ]]; then
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -n "$LAST_TAG" ]]; then
    RANGE="${LAST_TAG}..HEAD"
  else
    RANGE="HEAD~5..HEAD"
  fi
fi

# Collect changed files in the range
CHANGED_FILES=$(git diff --name-only "$RANGE" 2>/dev/null || true)
if [[ -z "$CHANGED_FILES" ]]; then
  if [[ "$QUIET" -eq 0 ]]; then echo "No changes in range $RANGE."; fi
  exit 0
fi

STALE_DOCS=()
NOTES=()

# --- Rule 1: SKILL.md freshness ---
# If any file under skills/<name>/scripts/ changed, check skills/<name>/SKILL.md
SEEN_SKILLS=""
while IFS= read -r file; do
  if [[ "$file" =~ ^skills/([^/]+)/scripts/ ]]; then
    skill_name="${BASH_REMATCH[1]}"
    # Deduplicate: only flag each skill once
    if echo "$SEEN_SKILLS" | grep -q "^${skill_name}$" 2>/dev/null; then continue; fi
    SEEN_SKILLS="${SEEN_SKILLS}${skill_name}\n"
    skill_md="skills/${skill_name}/SKILL.md"
    if [[ -f "$skill_md" ]]; then
      if ! echo "$CHANGED_FILES" | grep -q "^${skill_md}$"; then
        STALE_DOCS+=("$skill_md")
        NOTES+=("Script changes in skills/${skill_name}/scripts/ without SKILL.md update")
      fi
    fi
  fi
done <<< "$CHANGED_FILES"

# --- Rule 2: README.md freshness ---
# If plugin.json, marketplace.json, or package.json changed, flag README
if echo "$CHANGED_FILES" | grep -qE '(plugin\.json|marketplace\.json|package\.json)'; then
  if ! echo "$CHANGED_FILES" | grep -q '^README.md$'; then
    if [[ -f "README.md" ]]; then
      STALE_DOCS+=("README.md")
      NOTES+=("Manifest files changed — README.md may need version/feature updates")
    fi
  fi
fi

# --- Rule 3: Hook script changes → hooks.json docs ---
if echo "$CHANGED_FILES" | grep -qE '^hooks/'; then
  if ! echo "$CHANGED_FILES" | grep -q '^hooks/hooks.json$'; then
    if [[ -f "hooks/hooks.json" ]]; then
      STALE_DOCS+=("hooks/hooks.json")
      NOTES+=("Hook scripts changed — hooks.json may need configuration updates")
    fi
  fi
fi

# --- Rule 4: Orchestrator freshness ---
# If new skills or agents were added/removed, orchestrator may need updating
NEW_SKILLS=$(echo "$CHANGED_FILES" | grep -E '^skills/[^/]+/SKILL\.md$' | sed 's|skills/||;s|/SKILL.md||' || true)
if [[ -n "$NEW_SKILLS" ]]; then
  ORCHESTRATOR="skills/orchestrator/SKILL.md"
  if [[ -f "$ORCHESTRATOR" ]]; then
    while IFS= read -r skill; do
      if ! grep -q "$skill" "$ORCHESTRATOR" 2>/dev/null; then
        STALE_DOCS+=("$ORCHESTRATOR")
        NOTES+=("Skill '$skill' SKILL.md changed but not referenced in orchestrator")
        break  # Only flag once
      fi
    done <<< "$NEW_SKILLS"
  fi
fi

# --- Rule 5: Supplement/reference doc freshness ---
# If supplements changed, check MANIFEST.md
if echo "$CHANGED_FILES" | grep -qE '^skills/supplements/'; then
  if ! echo "$CHANGED_FILES" | grep -q '^skills/supplements/MANIFEST.md$'; then
    if [[ -f "skills/supplements/MANIFEST.md" ]]; then
      STALE_DOCS+=("skills/supplements/MANIFEST.md")
      NOTES+=("Supplements changed — MANIFEST.md may need updating")
    fi
  fi
fi

# --- Rule 6: Script reference docs ---
# If litmus scripts changed, check script-reference.md
if echo "$CHANGED_FILES" | grep -qE '^skills/litmus/scripts/'; then
  REF_DOC="skills/litmus/references/script-reference.md"
  if [[ -f "$REF_DOC" ]]; then
    if ! echo "$CHANGED_FILES" | grep -q "^${REF_DOC}$"; then
      STALE_DOCS+=("$REF_DOC")
      NOTES+=("Litmus scripts changed — script-reference.md may be stale")
    fi
  fi
fi

# --- Output ---
if [[ ${#STALE_DOCS[@]} -eq 0 ]]; then
  if [[ "$QUIET" -eq 0 ]]; then
    echo "Doc sync check: all clear (${RANGE})"
  fi
  exit 0
fi

if [[ "$QUIET" -eq 0 ]]; then
  echo "Doc Sync Check (${RANGE})"
  echo "========================="
  echo ""
  echo "${#STALE_DOCS[@]} doc(s) may need attention:"
  echo ""
  for i in "${!STALE_DOCS[@]}"; do
    echo "  ${STALE_DOCS[$i]}"
    echo "    → ${NOTES[$i]}"
  done
  echo ""
  echo "Review these docs and update if the code changes affect their content."
else
  # Quiet mode: just list files
  printf '%s\n' "${STALE_DOCS[@]}" | sort -u
fi

exit 0
