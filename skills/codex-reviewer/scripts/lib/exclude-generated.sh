#!/bin/bash
# Shared exclusion logic for auto-generated files
# Sources: hardcoded defaults + project-level .claude/review-exclude

# Hardcoded defaults for universally auto-generated files
# Patterns use ** prefix to match at any depth (monorepo/nested package support)
_DEFAULT_EXCLUDE=(
  "**/package-lock.json"
  "**/yarn.lock"
  "**/pnpm-lock.yaml"
  "**/bun.lockb"
  "**/Gemfile.lock"
  "**/Pipfile.lock"
  "**/poetry.lock"
  "**/composer.lock"
  "**/Cargo.lock"
  "**/go.sum"
  "**/*.min.js"
  "**/*.min.css"
  "**/*.map"
)

# Build git pathspec exclusion args into REVIEW_EXCLUDE_ARGS array
# Usage: source this file, then use "${REVIEW_EXCLUDE_ARGS[@]}" in git diff commands
#   git diff --cached --name-only -- . "${REVIEW_EXCLUDE_ARGS[@]}"
build_exclude_args() {
  local project_exclude=()
  # Resolve .claude/review-exclude relative to git repo root (not CWD)
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local review_exclude_file="$repo_root/.claude/review-exclude"

  if [ -f "$review_exclude_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      project_exclude+=("$line")
    done < "$review_exclude_file"
  fi

  REVIEW_EXCLUDE_ARGS=()
  # ${arr[@]+...} guards against "unbound variable" when array is empty under set -u
  local all_exclude=("${_DEFAULT_EXCLUDE[@]}" ${project_exclude[@]+"${project_exclude[@]}"})
  for pattern in "${all_exclude[@]}"; do
    REVIEW_EXCLUDE_ARGS+=(":(exclude)$pattern")
  done
}

# Call on source
build_exclude_args
