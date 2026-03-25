#!/bin/bash
# Suggests how to split a large staged diff into logical commit groups
# Groups files by directory structure as a heuristic for feature/module boundaries
# Called by run-review-loop.sh when diff exceeds size thresholds
#
# macOS-compatible: no declare -A (requires bash 4+, macOS ships 3.2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source auto-generated file exclusion
# shellcheck source=lib/exclude-generated.sh
source "$SCRIPT_DIR/lib/exclude-generated.sh"

echo "=== STAGED FILES ==="
echo ""

TOTAL_LINES=0
TOTAL_ADDS=0
TOTAL_REMOVES=0
# Collect directory groups using temp files (bash 3.2 compatible)
TMPDIR_GROUPS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GROUPS"' EXIT

TOTAL_WEIGHTED=0
while IFS= read -r file; do
  # Count added and removed lines separately
  NUMSTAT=$(git diff --cached --numstat -- "$file" 2>/dev/null)
  ADDED=$(echo "$NUMSTAT" | awk '{print $1}')
  REMOVED=$(echo "$NUMSTAT" | awk '{print $2}')
  ADDED=${ADDED:-0}; REMOVED=${REMOVED:-0}
  # Handle binary files (numstat shows - -)
  [ "$ADDED" = "-" ] && ADDED=0
  [ "$REMOVED" = "-" ] && REMOVED=0
  LINES=$((ADDED + REMOVED))
  TOTAL_LINES=$((TOTAL_LINES + LINES))
  TOTAL_ADDS=$((TOTAL_ADDS + ADDED))
  TOTAL_REMOVES=$((TOTAL_REMOVES + REMOVED))

  # Extract directory group (first two path components)
  DIR=$(dirname "$file")
  if [ "$DIR" = "." ]; then
    DIR="(root)"
  else
    DIR=$(echo "$DIR" | cut -d'/' -f1-2)
  fi

  # Use filesystem as associative storage (bash 3.2 safe)
  SAFE_DIR=$(echo "$DIR" | tr '/' '_')
  echo "  $file (+$ADDED -$REMOVED)" >> "$TMPDIR_GROUPS/$SAFE_DIR.files"

  # Accumulate raw adds/removes per group (compute weighted at display time to avoid per-file truncation)
  if [ -f "$TMPDIR_GROUPS/$SAFE_DIR.adds" ]; then
    PREV_A=$(cat "$TMPDIR_GROUPS/$SAFE_DIR.adds")
    PREV_R=$(cat "$TMPDIR_GROUPS/$SAFE_DIR.removes")
    echo $((PREV_A + ADDED)) > "$TMPDIR_GROUPS/$SAFE_DIR.adds"
    echo $((PREV_R + REMOVED)) > "$TMPDIR_GROUPS/$SAFE_DIR.removes"
  else
    echo "$ADDED" > "$TMPDIR_GROUPS/$SAFE_DIR.adds"
    echo "$REMOVED" > "$TMPDIR_GROUPS/$SAFE_DIR.removes"
    echo "$DIR" > "$TMPDIR_GROUPS/$SAFE_DIR.name"
  fi

  echo "  $file (+$ADDED -$REMOVED)"
done < <(git diff --cached --name-only -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")

echo ""
FILE_COUNT=$(git diff --cached --name-only -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" | wc -l | tr -d ' ')
TOTAL_WEIGHTED=$((TOTAL_ADDS + TOTAL_REMOVES / 4))
echo "Total: $TOTAL_LINES raw lines (+$TOTAL_ADDS -$TOTAL_REMOVES, weighted: $TOTAL_WEIGHTED) across $FILE_COUNT files"
echo ""

echo "=== SUGGESTED GROUPS ==="
echo ""

GROUP_NUM=1
for ADDS_FILE in "$TMPDIR_GROUPS"/*.adds; do
  [ -f "$ADDS_FILE" ] || continue
  BASE=$(basename "$ADDS_FILE" .adds)
  DIR_NAME=$(cat "$TMPDIR_GROUPS/$BASE.name")
  GRP_ADDS=$(cat "$ADDS_FILE")
  GRP_REMOVES=$(cat "$TMPDIR_GROUPS/$BASE.removes")
  GRP_WEIGHTED=$((GRP_ADDS + GRP_REMOVES / 4))
  echo "Group $GROUP_NUM: $DIR_NAME (+$GRP_ADDS -$GRP_REMOVES, weighted: $GRP_WEIGHTED)"
  cat "$TMPDIR_GROUPS/$BASE.files"
  echo ""
  GROUP_NUM=$((GROUP_NUM + 1))
done

echo "=== INSTRUCTIONS ==="
echo ""
echo "To split this commit:"
echo "  1. git reset HEAD              # Unstage all files"
echo "  2. For each group above:"
echo "     a. git add <files>           # Stage one group"
echo "     b. Run init + review loop    # Review that group"
echo "     c. git commit -m '...'       # Commit after PASS"
echo "  3. Repeat until all groups are committed"
echo ""
echo "Adjust groups as needed - these are suggestions based on directory structure."
echo "Prefer grouping by feature or logical change over strict directory boundaries."
