#!/usr/bin/env bash
#
# generate-changelog.sh — Generate CHANGELOG.md from conventional commits.
#
# Usage:
#   generate-changelog.sh                     Generate from last tag to HEAD
#   generate-changelog.sh v1.13.0..v1.14.0    Generate for a specific range
#   generate-changelog.sh --full              Generate from all tags
#   generate-changelog.sh --dry-run           Preview without writing
#
set -euo pipefail

CHANGELOG_FILE="${CHANGELOG_FILE:-CHANGELOG.md}"
DRY_RUN=0
RANGE=""
FULL=0

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --full)    FULL=1 ;;
    --help|-h)
      echo "Usage: generate-changelog.sh [RANGE] [--full] [--dry-run]"
      echo ""
      echo "  RANGE      Git range (e.g., v1.13.0..v1.14.0). Default: last tag..HEAD"
      echo "  --full     Generate from all tags"
      echo "  --dry-run  Preview without writing"
      exit 0
      ;;
    *) RANGE="$arg" ;;
  esac
done

# Get all version tags sorted by version
get_tags() {
  git tag -l 'v*' --sort=-version:refname 2>/dev/null
}

# Generate changelog section for a commit range
generate_section() {
  local range="$1"
  local title="$2"
  local date="$3"

  local features fixes refactors docs chores perfs others
  features=""
  fixes=""
  refactors=""
  docs=""
  chores=""
  perfs=""
  others=""

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse conventional commit: type(scope): description
    # Extract type and rest, handling optional (scope)
    local type scope desc entry
    type=$(echo "$line" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .+$/\1/p' || true)
    scope=$(echo "$line" | sed -nE 's/^[a-z]+\(([^)]*)\)!?: .+$/\1/p' || true)
    desc=$(echo "$line" | sed -nE 's/^[a-z]+(\([^)]*\))?!?: (.+)$/\2/p' || true)

    if [[ -n "$type" && -n "$desc" ]]; then
      if [[ -n "$scope" ]]; then
        entry="- **${scope}:** ${desc}"
      else
        entry="- ${desc}"
      fi

      case "$type" in
        feat)     features="${features}${entry}\n" ;;
        fix)      fixes="${fixes}${entry}\n" ;;
        refactor) refactors="${refactors}${entry}\n" ;;
        docs)     docs="${docs}${entry}\n" ;;
        perf)     perfs="${perfs}${entry}\n" ;;
        chore|ci|build|test) chores="${chores}${entry}\n" ;;
        *)        others="${others}${entry}\n" ;;
      esac
    else
      others="${others}- ${line}\n"
    fi
  done < <(git log "$range" --pretty=format:'%s' --no-merges 2>/dev/null)

  # Only output if there are commits
  local has_content=0
  if [[ -n "$features$fixes$refactors$docs$perfs$chores$others" ]]; then has_content=1; fi

  if [[ "$has_content" -eq 0 ]]; then
    return
  fi

  echo "## ${title} (${date})"
  echo ""

  if [[ -n "$features" ]];  then echo "### Features";     echo ""; printf '%b' "$features";  echo ""; fi
  if [[ -n "$fixes" ]];     then echo "### Bug Fixes";     echo ""; printf '%b' "$fixes";     echo ""; fi
  if [[ -n "$refactors" ]]; then echo "### Refactoring";   echo ""; printf '%b' "$refactors"; echo ""; fi
  if [[ -n "$perfs" ]];     then echo "### Performance";   echo ""; printf '%b' "$perfs";     echo ""; fi
  if [[ -n "$docs" ]];      then echo "### Documentation"; echo ""; printf '%b' "$docs";      echo ""; fi
  if [[ -n "$chores" ]];    then echo "### Maintenance";   echo ""; printf '%b' "$chores";    echo ""; fi
  if [[ -n "$others" ]];    then echo "### Other";         echo ""; printf '%b' "$others";    echo ""; fi
}

# Build the changelog content
output=""

if [[ "$FULL" -eq 1 ]]; then
  # Generate for all tags
  output="# Changelog\n\nAll notable changes to this project.\n\n"

  TAGS=($(get_tags))

  # Unreleased section (latest tag to HEAD)
  if [[ ${#TAGS[@]} -gt 0 ]]; then
    UNRELEASED=$(generate_section "${TAGS[0]}..HEAD" "Unreleased" "$(date +%Y-%m-%d)")
    if [[ -n "$UNRELEASED" ]]; then output="${output}${UNRELEASED}\n\n"; fi
  fi

  # Each tag pair
  for ((i=0; i<${#TAGS[@]}-1; i++)); do
    TAG="${TAGS[$i]}"
    PREV_TAG="${TAGS[$((i+1))]}"
    TAG_DATE=$(git log -1 --format='%cs' "$TAG" 2>/dev/null || echo "unknown")
    SECTION=$(generate_section "${PREV_TAG}..${TAG}" "${TAG}" "$TAG_DATE")
    if [[ -n "$SECTION" ]]; then output="${output}${SECTION}\n\n"; fi
  done

  # First tag (from beginning)
  if [[ ${#TAGS[@]} -gt 0 ]]; then
    FIRST_TAG="${TAGS[${#TAGS[@]}-1]}"
    TAG_DATE=$(git log -1 --format='%cs' "$FIRST_TAG" 2>/dev/null || echo "unknown")
    SECTION=$(generate_section "$FIRST_TAG" "$FIRST_TAG" "$TAG_DATE")
    if [[ -n "$SECTION" ]]; then output="${output}${SECTION}\n"; fi
  fi

elif [[ -n "$RANGE" ]]; then
  # Specific range
  output="# Changelog\n\n"
  SECTION=$(generate_section "$RANGE" "$RANGE" "$(date +%Y-%m-%d)")
  output="${output}${SECTION}"

else
  # Default: last tag to HEAD
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -z "$LAST_TAG" ]]; then
    echo "No tags found. Use --full or provide a range." >&2
    exit 1
  fi

  output="# Changelog\n\n"
  SECTION=$(generate_section "${LAST_TAG}..HEAD" "Unreleased" "$(date +%Y-%m-%d)")
  if [[ -n "$SECTION" ]]; then
    output="${output}${SECTION}"
  else
    echo "No new commits since ${LAST_TAG}."
    exit 0
  fi
fi

# Output
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%b' "$output"
else
  printf '%b' "$output" > "$CHANGELOG_FILE"
  echo "Generated $CHANGELOG_FILE ($(wc -l < "$CHANGELOG_FILE" | tr -d ' ') lines)"
fi
