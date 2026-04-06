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

  local -a features=() fixes=() refactors=() docs=() chores=() perfs=() others=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse conventional commit: type(scope): description
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
        feat)     features+=("$entry") ;;
        fix)      fixes+=("$entry") ;;
        refactor) refactors+=("$entry") ;;
        docs)     docs+=("$entry") ;;
        perf)     perfs+=("$entry") ;;
        chore|ci|build|test) chores+=("$entry") ;;
        *)        others+=("$entry") ;;
      esac
    else
      others+=("- ${line}")
    fi
  done < <(git log "$range" --pretty=format:'%s' --no-merges 2>/dev/null || true)

  # Only output if there are commits
  local total=$(( ${#features[@]} + ${#fixes[@]} + ${#refactors[@]} + ${#docs[@]} + ${#perfs[@]} + ${#chores[@]} + ${#others[@]} ))
  if [[ "$total" -eq 0 ]]; then
    return
  fi

  echo "## ${title} (${date})"
  echo ""

  # Helper to print a section — uses printf '%s\n' which does NOT interpret backslashes
  _print_section() {
    local heading="$1"; shift
    if [[ $# -gt 0 ]]; then
      echo "### ${heading}"
      echo ""
      printf '%s\n' "$@"
      echo ""
    fi
  }

  if [[ ${#features[@]} -gt 0 ]];  then _print_section "Features"     "${features[@]}"; fi
  if [[ ${#fixes[@]} -gt 0 ]];     then _print_section "Bug Fixes"    "${fixes[@]}"; fi
  if [[ ${#refactors[@]} -gt 0 ]]; then _print_section "Refactoring"  "${refactors[@]}"; fi
  if [[ ${#perfs[@]} -gt 0 ]];     then _print_section "Performance"  "${perfs[@]}"; fi
  if [[ ${#docs[@]} -gt 0 ]];      then _print_section "Documentation" "${docs[@]}"; fi
  if [[ ${#chores[@]} -gt 0 ]];    then _print_section "Maintenance"  "${chores[@]}"; fi
  if [[ ${#others[@]} -gt 0 ]];    then _print_section "Other"        "${others[@]}"; fi
}

# Build the changelog content
NL=$'\n'
output=""

if [[ "$FULL" -eq 1 ]]; then
  # Generate for all tags
  output="# Changelog${NL}${NL}All notable changes to this project.${NL}${NL}"

  mapfile -t TAGS < <(get_tags)

  if [[ ${#TAGS[@]} -eq 0 ]]; then
    # No version tags yet: treat the whole history as Unreleased
    SECTION=$(generate_section "HEAD" "Unreleased" "$(date +%Y-%m-%d)")
    if [[ -n "$SECTION" ]]; then output="${output}${SECTION}${NL}"; fi
  else
    # Unreleased section (latest tag to HEAD)
    UNRELEASED=$(generate_section "${TAGS[0]}..HEAD" "Unreleased" "$(date +%Y-%m-%d)")
    if [[ -n "$UNRELEASED" ]]; then output="${output}${UNRELEASED}${NL}${NL}"; fi

    # Each tag pair
    for ((i=0; i<${#TAGS[@]}-1; i++)); do
      TAG="${TAGS[$i]}"
      PREV_TAG="${TAGS[$((i+1))]}"
      TAG_DATE=$(git log -1 --format='%cs' "$TAG" 2>/dev/null || echo "unknown")
      SECTION=$(generate_section "${PREV_TAG}..${TAG}" "${TAG}" "$TAG_DATE")
      if [[ -n "$SECTION" ]]; then output="${output}${SECTION}${NL}${NL}"; fi
    done

    # First tag (from beginning)
    FIRST_TAG="${TAGS[${#TAGS[@]}-1]}"
    TAG_DATE=$(git log -1 --format='%cs' "$FIRST_TAG" 2>/dev/null || echo "unknown")
    SECTION=$(generate_section "$FIRST_TAG" "$FIRST_TAG" "$TAG_DATE")
    if [[ -n "$SECTION" ]]; then output="${output}${SECTION}${NL}"; fi
  fi

elif [[ -n "$RANGE" ]]; then
  # Specific range
  SECTION=$(generate_section "$RANGE" "$RANGE" "$(date +%Y-%m-%d)")
  if [[ -z "$SECTION" ]]; then
    echo "No commits in range ${RANGE}."
    exit 0
  fi
  output="# Changelog${NL}${NL}${SECTION}"

else
  # Default: last tag to HEAD
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -z "$LAST_TAG" ]]; then
    echo "No tags found. Use --full or provide a range." >&2
    exit 1
  fi

  output="# Changelog${NL}${NL}"
  SECTION=$(generate_section "${LAST_TAG}..HEAD" "Unreleased" "$(date +%Y-%m-%d)")
  if [[ -n "$SECTION" ]]; then
    output="${output}${SECTION}"
  else
    echo "No new commits since ${LAST_TAG}."
    exit 0
  fi
fi

# Output — uses %s to avoid interpreting backslashes in commit messages
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s' "$output"
else
  printf '%s' "$output" > "$CHANGELOG_FILE"
  LINE_COUNT=$(wc -l < "$CHANGELOG_FILE" | tr -d ' ')
  echo "Generated $CHANGELOG_FILE ($LINE_COUNT lines)"
fi
