#!/bin/bash
# Collect documentation context for changed files.
# Finds README, SKILL.md, docs/ files that mention changed modules/functions.
#
# Usage: source this file, then call collect_docs_context "$files_list" "$diff"
# Output: Formatted doc snippets on stdout for prompt injection.
#
# Environment:
#   CODEX_SKIP_DOCS_CONTEXT=1   — skip docs context collection
#   CODEX_MAX_DOC_SNIPPETS=5    — max doc snippets to include (default: 5)

set -euo pipefail

# Escape regex metacharacters for safe grep -E interpolation
_docs_escape_regex() {
  printf '%s' "$1" | sed 's/[.+*?^${}()|[\]\\]/\\&/g'
}

# Find doc files that mention a changed file or its functions
_find_referencing_docs() {
  local search_term="$1"
  local max_snippets="${CODEX_MAX_DOC_SNIPPETS:-5}"
  case "$max_snippets" in
    ''|*[!0-9]*) max_snippets=5 ;;
  esac
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  local escaped_term
  escaped_term=$(_docs_escape_regex "$search_term")

  grep -rln --include='*.md' \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir='.claude' \
    -F "$search_term" "$repo_root" 2>/dev/null | \
    grep -vE 'CHANGELOG|changelog|node_modules|\.claude/' | \
    head -n "$max_snippets" || true
}

# Extract relevant section from a doc file around a search term
_extract_doc_section() {
  local doc_file="$1"
  local search_term="$2"

  local line_nums
  line_nums=$(grep -nF "$search_term" "$doc_file" 2>/dev/null | head -3 | cut -d: -f1) || true
  [ -z "$line_nums" ] && return

  while IFS= read -r line_num; do
    local start=$((line_num - 5))
    [ "$start" -lt 1 ] && start=1
    local end=$((line_num + 5))
    sed -n "${start},${end}p" "$doc_file" 2>/dev/null
    echo "..."
  done <<< "$line_nums"
}

# Main entry point
# Args: $1 = newline-separated changed file paths, $2 = staged diff (optional, for symbol extraction)
# Output: Formatted doc context on stdout
collect_docs_context() {
  local files_list="$1"
  local diff_content="${2:-}"

  if [ "${CODEX_SKIP_DOCS_CONTEXT:-0}" = "1" ]; then
    return
  fi

  [ -z "$files_list" ] && return

  # Build search terms: basenames + extracted symbols from diff
  local search_terms=""

  while IFS= read -r changed_file; do
    [ -z "$changed_file" ] && continue
    local basename_no_ext
    basename_no_ext=$(basename "$changed_file" | sed 's/\.[^.]*$//')
    [ ${#basename_no_ext} -le 3 ] && continue
    echo "$basename_no_ext" | grep -qE '^(index|main|app|test|spec|utils|lib|src)$' && continue
    search_terms+="$basename_no_ext"$'\n'
  done <<< "$(echo "$files_list" | head -n 10)"

  # Add extracted function/symbol names from diff (reuses smart-context extraction)
  if [ -n "$diff_content" ] && type _extract_changed_functions &>/dev/null; then
    local symbols
    symbols=$(_extract_changed_functions "$diff_content" 2>/dev/null)
    [ -n "$symbols" ] && search_terms+="$symbols"$'\n'
  fi

  # Deduplicate search terms
  search_terms=$(echo "$search_terms" | sort -u | head -n 15)
  [ -z "$search_terms" ] && return

  local context=""
  local found=0
  local found_docs=0

  while IFS= read -r term; do
    [ -z "$term" ] && continue

    local referencing_docs
    referencing_docs=$(_find_referencing_docs "$term")
    [ -z "$referencing_docs" ] && continue

    while IFS= read -r doc_file; do
      [ -z "$doc_file" ] && continue

      local section
      section=$(_extract_doc_section "$doc_file" "$term")
      if [ -n "$section" ]; then
        if [ "$found_docs" -eq 0 ]; then
          context+="## Documentation Cross-Reference (verify accuracy of each claim)
The following doc files reference the changed code. For each snippet:
1. Identify every factual claim (counts, names, behavior descriptions)
2. Cross-reference each claim against the actual code in the diff
3. Flag any stale counts, wrong function names, or mismatched examples

"
          found_docs=1
        fi
        # Use a fence that the excerpt cannot close (~~~~ instead of ```)
        context+="### \`${doc_file}\` mentions \`${term}\`
~~~~
$section
~~~~

"
        found=$((found + 1))
      fi
    done <<< "$referencing_docs"
  done <<< "$search_terms"

  if [ "$found" -gt 0 ]; then
    echo "   Docs: found $found doc reference(s) to changed code" >&2
    echo "$context"
    echo ""
    echo "## End of Documentation Context"
  fi
}

# If run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if ! git rev-parse --git-dir &>/dev/null; then
    exit 0
  fi
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
  collect_docs_context "$STAGED_FILES"
fi
