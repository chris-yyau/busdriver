#!/bin/bash
# Main codex review loop script
# Reads state, runs review, parses results, updates state, handles iteration logic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
STATE_FILE=".claude/codex-review-state.md"

# Source validation library
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"

# Source iteration history library
# shellcheck source=lib/iteration-history.sh
source "$SCRIPT_DIR/lib/iteration-history.sh"

# Determine review mode from state file or env var
REVIEW_MODE="${CODEX_REVIEW_MODE:-commit}"

# Validate prerequisites
echo "🔍 Validating prerequisites..."
validate_git_repo || exit 1

# Resolve review CLI (fail-closed on missing/unsupported binary)
RESOLVED_CLI=$(validate_review_cli 2>/dev/null) || {
  validate_review_cli >&2
  rm -f "$STATE_FILE" 2>/dev/null
  exit 1
}

echo "   Review CLI: $RESOLVED_CLI"

validate_state_file "$STATE_FILE" || exit 1

# Check for changes based on review mode
# Also read review_mode from state file if set (overrides env var)
if [ -f "$STATE_FILE" ]; then
  STATE_MODE=$(get_yaml_value "review_mode" "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$STATE_MODE" ] && [ "$STATE_MODE" != "null" ] && REVIEW_MODE="$STATE_MODE"
fi

if [ "$REVIEW_MODE" = "pr" ]; then
  # PR mode guard: reject none/builtin — PR review requires external CLI
  if [ "$RESOLVED_CLI" = "builtin" ] || [ "$RESOLVED_CLI" = "none" ]; then
    echo "❌ Error: PR review requires an external review CLI" >&2
    echo "" >&2
    echo "   BUSDRIVER_REVIEW_CLI=$RESOLVED_CLI is not supported in PR mode." >&2
    echo "   PR deep review needs an independent external reviewer." >&2
    echo "   Set BUSDRIVER_REVIEW_CLI=auto or install codex/gemini." >&2
    rm -f "$STATE_FILE" 2>/dev/null
    exit 1
  fi

  # PR mode: check for branch diff against base
  PR_BASE_BRANCH="${CODEX_PR_BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")}"
  if git diff --quiet "${PR_BASE_BRANCH}...HEAD" 2>/dev/null; then
    echo "❌ No changes between ${PR_BASE_BRANCH} and HEAD" >&2
    exit 1
  fi
else
  # Commit mode: handle 'none' (must be after PR mode guard above)
  if [ "$RESOLVED_CLI" = "none" ]; then
    echo "⚠️  BUSDRIVER_REVIEW_CLI=none — review gate disabled" >&2
    echo "   Commits will pass without code review." >&2
    echo "" >&2
    mkdir -p .claude
    echo "SKIPPED-NONE-$(date +%s)" > ".claude/codex-review-passed.local"
    printf '{"ts":"%s","event":"review-skipped-none","gate":"pre-commit"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null
    exit 0
  fi

  # Commit mode: check for staged changes
  # Detect merge in progress — merge resolutions have all files staged
  # as part of the merge state, making git diff --cached appear empty
  # when conflicts are resolved by keeping our code.
  if git rev-parse MERGE_HEAD >/dev/null 2>&1; then
    if git diff --cached --quiet 2>/dev/null; then
      # Merge keeps our already-reviewed code unchanged — auto-pass
      echo "ℹ️  Merge commit detected with no changes relative to HEAD"
      echo "   Resolution keeps already-reviewed code — auto-passing review"
      echo ""
      mkdir -p .claude
      echo "PASS-MERGE-$(date +%s)" > ".claude/codex-review-passed.local"
      clear_iteration_history
      rm -f "$STATE_FILE" 2>/dev/null
      exit 0
    fi
    echo "ℹ️  Merge commit detected — reviewing merge resolution changes"
    # Fall through to review the changes introduced by the merge
  else
    if git diff --cached --quiet 2>/dev/null; then
      if ! has_uncommitted_changes; then
        error_no_changes
        exit 1
      fi
      echo "⚠️  No staged changes found. Stage files first: git add <files>" >&2
      exit 1
    fi
  fi
fi

echo "✅ Prerequisites validated"
echo ""

# Read state from file
echo "📖 Reading state..."
ITERATION=$(get_yaml_value "iteration" "$STATE_FILE")
MAX_ITER=$(get_yaml_value "max_iterations" "$STATE_FILE")
ACTIVE=$(get_yaml_value "active" "$STATE_FILE")
COMPLETION_PROMISE=$(get_yaml_value "completion_promise" "$STATE_FILE")

# Validate state values
if [ -z "$ITERATION" ] || [ -z "$MAX_ITER" ]; then
  echo "❌ Error: Invalid state file - missing iteration or max_iterations" >&2
  exit 1
fi

echo "   Loop iteration: $ITERATION / $MAX_ITER"
echo ""

# Check if loop is active
if [ "$ACTIVE" != "true" ]; then
  echo "ℹ️  Review loop is not active"
  echo "   Status: Completed or stopped"
  exit 0
fi

# Check iteration limit
if [ "$ITERATION" -gt "$MAX_ITER" ]; then
  echo "❌ Max iterations ($MAX_ITER) reached" >&2
  echo "" >&2
  echo "   The review loop has hit the maximum iteration limit." >&2
  echo "   This usually indicates:" >&2
  echo "   - Complex changes requiring design discussion" >&2
  echo "   - Fixes introducing new issues" >&2
  echo "   - Changes too large (>300 lines)" >&2
  echo "" >&2
  echo "   Options:" >&2
  echo "   1. Review remaining issues manually" >&2
  echo "   2. Break changes into smaller commits" >&2
  echo "   3. Reset counter to continue (advanced)" >&2
  echo "" >&2
  echo "   See references/troubleshooting.md for guidance" >&2
  set_yaml_value "active" "false" "$STATE_FILE"
  exit 1
fi

# Extract prompt from state file (content after frontmatter)
echo "📝 Loading review prompt..."
PROMPT=$(sed -n '/^---$/,/^---$/!p' "$STATE_FILE" | sed '1d')

# Source auto-generated file exclusion (hardcoded defaults + .claude/review-exclude)
# shellcheck source=lib/exclude-generated.sh
source "$SCRIPT_DIR/lib/exclude-generated.sh"

# Source SAST, smart context, docs context, and markdown checker
# shellcheck source=lib/sast-runner.sh
source "$SCRIPT_DIR/lib/sast-runner.sh"
# shellcheck source=lib/smart-context.sh
source "$SCRIPT_DIR/lib/smart-context.sh"
# shellcheck source=lib/docs-context.sh
source "$SCRIPT_DIR/lib/docs-context.sh"
# shellcheck source=lib/markdown-checker.sh
source "$SCRIPT_DIR/lib/markdown-checker.sh"

# Capture diff for scope control (excluding auto-generated files)
if [ "$REVIEW_MODE" = "pr" ]; then
  echo "📋 Capturing branch diff (${PR_BASE_BRANCH}...HEAD)..."
  ALL_STAGED_FILES=$(git diff --name-only "${PR_BASE_BRANCH}...HEAD")
  STAGED_DIFF=$(git diff --no-color "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
  FILTERED_FILES=$(git diff --name-only "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
else
  echo "📋 Capturing staged changes..."
  ALL_STAGED_FILES=$(git diff --cached --name-only)
  STAGED_DIFF=$(git diff --cached --no-color -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
  FILTERED_FILES=$(git diff --cached --name-only -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
fi

# Detect what was excluded
EXCLUDED_FILES=""
if [ -n "$ALL_STAGED_FILES" ] && [ -n "$FILTERED_FILES" ]; then
  EXCLUDED_FILES=$(comm -23 <(echo "$ALL_STAGED_FILES" | sort) <(echo "$FILTERED_FILES" | sort))
elif [ -n "$ALL_STAGED_FILES" ]; then
  EXCLUDED_FILES="$ALL_STAGED_FILES"
fi

if [ -n "$EXCLUDED_FILES" ]; then
  EXCLUDED_COUNT=$(echo "$EXCLUDED_FILES" | wc -l | tr -d ' ')
  echo "   Excluded $EXCLUDED_COUNT auto-generated file(s):"
  echo "$EXCLUDED_FILES" | while IFS= read -r f; do echo "     - $f"; done
fi

# If all staged files were excluded, auto-pass
if [ -z "$STAGED_DIFF" ]; then
  if [ -n "$ALL_STAGED_FILES" ]; then
    echo ""
    echo "✅ All staged files are auto-generated — skipping review"
    echo ""
    # Write review-passed marker (same mechanism as normal PASS — pre-commit gate
    # accepts marker existence without hash verification due to TOCTOU constraints)
    mkdir -p .claude
    echo "PASS-$(date +%s)" > ".claude/codex-review-passed.local"
    # Clean up state file and iteration history
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null
    exit 0
  fi
  echo "❌ No staged changes to review" >&2
  echo "   Stage your changes first: git add <files>" >&2
  exit 1
fi
STAGED_FILE_COUNT=$(echo "$FILTERED_FILES" | wc -l | tr -d ' ')
STAGED_DIFF_LINES=$(echo "$STAGED_DIFF" | wc -l | tr -d ' ')
# Weighted line count: additions cost 1x, deletions cost 0.25x
# Rationale: deleted code needs minimal review ("is the delete correct?")
# while new code needs deep analysis for bugs, security, and correctness.
# Use git diff --numstat for reliable counting (avoids grep -c exit code issues
# and edge cases like lines starting with ++ or --)
ADDITION_LINES=0
DELETION_LINES=0
while IFS=$'\t' read -r added removed _file; do
  [ "$added" = "-" ] && added=0   # binary files
  [ "$removed" = "-" ] && removed=0
  ADDITION_LINES=$((ADDITION_LINES + added))
  DELETION_LINES=$((DELETION_LINES + removed))
done < <(if [ "$REVIEW_MODE" = "pr" ]; then git diff --numstat "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; else git diff --cached --numstat -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; fi)
WEIGHTED_LINES=$(( ADDITION_LINES + DELETION_LINES / 4 ))
echo "   Staged files: $STAGED_FILE_COUNT"
echo "   Diff lines: $STAGED_DIFF_LINES (added: $ADDITION_LINES, removed: $DELETION_LINES, weighted: $WEIGHTED_LINES)"

# Check if diff is too large for a single review (commit mode only)
# PR mode skips the size check — PR diffs are inherently larger (aggregate of
# all commits) and blocking review on the largest diffs defeats the purpose of
# the safety net. The REVIEW_TIMEOUT (default 30min, configurable via CODEX_REVIEW_TIMEOUT) handles runaway reviews.
# Council decision 2026-03-21: per-commit and PR size checks serve different
# purposes — fix independently. PR size check was structurally broken.
#
# Per-commit thresholds:
#   Primary metric: weighted lines (additions + deletions/4)
#   Safety ceiling: total raw lines > 2000 regardless of weighting
#   Single-file diffs get a higher threshold since they can't be split further
#   Override: CODEX_MAX_WEIGHTED_LINES env var (per-project tuning)
if [ "$REVIEW_MODE" = "pr" ]; then
  # PR mode: soft warning only — large PR diffs may be slow or hit context limits,
  # but blocking them defeats the safety net. The REVIEW_TIMEOUT (default 30min) handles
  # truly runaway reviews. Warn so the user knows to expect a longer wait.
  if [ "$WEIGHTED_LINES" -gt 2000 ]; then
    echo ""
    echo "⚠️  Large PR diff ($WEIGHTED_LINES weighted lines) — review may be slow or hit context limits"
    echo "   Consider splitting into smaller PRs if review times out (${REVIEW_TIMEOUT:-600}s limit)"
  fi
else
  # Commit mode: hard size gate with env var override
  MAX_WEIGHTED_LINES="${CODEX_MAX_WEIGHTED_LINES:-800}"
  # Validate env var is numeric — fall back to default if not
  case "$MAX_WEIGHTED_LINES" in
    ''|*[!0-9]*) echo "⚠️  CODEX_MAX_WEIGHTED_LINES='$MAX_WEIGHTED_LINES' is not numeric, using default 800"; MAX_WEIGHTED_LINES=800 ;;
  esac
  MAX_WEIGHTED_LINES_SINGLE_FILE=2000
  MAX_TOTAL_LINES_CEILING=2000
  MAX_STAGED_FILES="${CODEX_MAX_STAGED_FILES:-8}"
  EFFECTIVE_MAX=$MAX_WEIGHTED_LINES
  if [ "$STAGED_FILE_COUNT" -eq 1 ]; then
    EFFECTIVE_MAX=$MAX_WEIGHTED_LINES_SINGLE_FILE
  fi
  TOO_LARGE=false
  TOO_LARGE_REASON=""
  if [ "$WEIGHTED_LINES" -gt "$EFFECTIVE_MAX" ]; then
    TOO_LARGE=true
    TOO_LARGE_REASON="weighted lines ($WEIGHTED_LINES) > $EFFECTIVE_MAX"
  elif [ "$((ADDITION_LINES + DELETION_LINES))" -gt "$MAX_TOTAL_LINES_CEILING" ]; then
    TOO_LARGE=true
    TOO_LARGE_REASON="total changed lines ($((ADDITION_LINES + DELETION_LINES))) > $MAX_TOTAL_LINES_CEILING ceiling"
  elif [ "$STAGED_FILE_COUNT" -gt "$MAX_STAGED_FILES" ]; then
    TOO_LARGE=true
    TOO_LARGE_REASON="file count ($STAGED_FILE_COUNT) > $MAX_STAGED_FILES"
  fi
  if [ "$TOO_LARGE" = true ]; then
    echo ""
    echo "⚠️  Diff too large for single review ($TOO_LARGE_REASON)"
    echo "   Thresholds: weighted >$EFFECTIVE_MAX OR total >$MAX_TOTAL_LINES_CEILING OR files >$MAX_STAGED_FILES"
    echo "   Override: CODEX_MAX_WEIGHTED_LINES=$((WEIGHTED_LINES + 100)) or CODEX_MAX_STAGED_FILES=$((STAGED_FILE_COUNT + 2)) to raise"
    echo ""
    # Run suggest-split helper to show grouping advice (only useful for multi-file diffs)
    if [ "$STAGED_FILE_COUNT" -gt 1 ]; then
      bash "$SCRIPT_DIR/suggest-split.sh"
      echo ""
    fi
    echo "EXIT_CODE=2 (TOO_LARGE: split into smaller commits before reviewing)"
    exit 2
  fi
fi

# Run SAST scan on changed files (deterministic, runs before LLM)
echo ""
echo "🔒 Running static analysis..."
SAST_FINDINGS=$(run_sast_scan "$FILTERED_FILES")
SAST_COUNT=$(echo "$SAST_FINDINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# Run markdown checks if .md files are staged
MARKDOWN_FINDINGS=$(run_markdown_checks "$FILTERED_FILES")
MD_COUNT=$(echo "$MARKDOWN_FINDINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# Collect smart context (callers, importers of changed code)
echo ""
echo "🔎 Collecting cross-file context..."
SMART_CONTEXT_OUTPUT=$(collect_smart_context "$STAGED_DIFF" "$FILTERED_FILES")

# Collect docs context (doc files referencing changed code + extracted symbols)
DOCS_CONTEXT_OUTPUT=$(collect_docs_context "$FILTERED_FILES" "$STAGED_DIFF")

# Load previous changelog for context continuity
PREV_CHANGELOG=$("$SCRIPT_DIR/load_changelog.sh" 2>/dev/null || echo "")

# Load iteration history for convergence
ITER_HISTORY=$(load_iteration_history)

# Substitute all placeholders into the prompt
FINAL_PROMPT="${PROMPT/\{\{PREV_CHANGELOG\}\}/$PREV_CHANGELOG}"
FINAL_PROMPT="${FINAL_PROMPT/\{\{STAGED_DIFF\}\}/$STAGED_DIFF}"
FINAL_PROMPT="${FINAL_PROMPT/\{\{ITERATION_HISTORY\}\}/$ITER_HISTORY}"

# Inject SAST pre-check results
SAST_PRECHECK_TEXT=""
if [ "$SAST_COUNT" -gt 0 ]; then
  SAST_PRECHECK_TEXT="## SAST Pre-Check Results (deterministic — these are confirmed findings)
The following issues were found by static analysis tools. These are NOT hallucinations — they are real findings from automated scanners. Include them in your output as-is.
$(echo "$SAST_FINDINGS" | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    print(f'- [{f[\"severity\"].upper()}] {f[\"file\"]}:{f[\"line\"]} — {f[\"description\"]}')
")"
fi
FINAL_PROMPT="${FINAL_PROMPT/\{\{SAST_PRECHECK\}\}/$SAST_PRECHECK_TEXT}"

# Budget cap for enrichment context (prevent prompt bloat)
MAX_ENRICHMENT_LINES="${CODEX_MAX_ENRICHMENT_LINES:-100}"
case "$MAX_ENRICHMENT_LINES" in
  ''|*[!0-9]*) echo "⚠️  CODEX_MAX_ENRICHMENT_LINES='$MAX_ENRICHMENT_LINES' is not numeric, using default 100" >&2; MAX_ENRICHMENT_LINES=100 ;;
esac
if [ -n "$SMART_CONTEXT_OUTPUT" ]; then
  SMART_CONTEXT_OUTPUT=$(echo "$SMART_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi
if [ -n "$DOCS_CONTEXT_OUTPUT" ]; then
  DOCS_CONTEXT_OUTPUT=$(echo "$DOCS_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi

# Inject smart context
FINAL_PROMPT="${FINAL_PROMPT/\{\{SMART_CONTEXT\}\}/$SMART_CONTEXT_OUTPUT}"

# Inject docs context
FINAL_PROMPT="${FINAL_PROMPT/\{\{DOCS_CONTEXT\}\}/$DOCS_CONTEXT_OUTPUT}"

# Run review via resolved CLI
echo "🔬 Running $RESOLVED_CLI review (loop attempt $ITERATION/$MAX_ITER)..."
echo ""

REVIEW_TIMEOUT="${CODEX_REVIEW_TIMEOUT:-1200}"  # 20 minutes default, configurable via env var
set +e
REVIEW_OUTPUT=$(execute_review "$RESOLVED_CLI" "$FINAL_PROMPT" "$REVIEW_TIMEOUT")
REVIEW_EXIT=$?
set -e

if [ "$RESOLVED_CLI" = "builtin" ] && [ "$REVIEW_EXIT" -eq 3 ] && [ "$REVIEW_OUTPUT" = "BUILTIN_FALLBACK" ]; then
  # Builtin fallback — write prompt to temp file for SKILL agent dispatch
  BUILTIN_PROMPT_FILE=$(mktemp -t busdriver-review-XXXXXX)
  chmod 600 "$BUILTIN_PROMPT_FILE"
  printf '%s' "$FINAL_PROMPT" > "$BUILTIN_PROMPT_FILE"
  mkdir -p .claude
  echo "$BUILTIN_PROMPT_FILE" > ".claude/builtin-review-prompt-path.local"
  echo "ℹ️  No external review CLI available — using built-in agent review" >&2
  echo "   Prompt saved to $BUILTIN_PROMPT_FILE" >&2
  echo "   The codex-reviewer skill will dispatch the code-reviewer agent." >&2
  clear_iteration_history
  rm -f "$STATE_FILE" 2>/dev/null
  exit 3
elif [ "$REVIEW_EXIT" -eq 124 ]; then
  echo "❌ Error: $RESOLVED_CLI review timed out after ${REVIEW_TIMEOUT}s" >&2
  echo "" >&2
  echo "   The review took too long. This usually means the diff is too complex." >&2
  echo "   Try splitting into smaller commits." >&2
  echo "" >&2
  bash "$SCRIPT_DIR/suggest-split.sh" >&2
  exit 124
elif [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "❌ Error: $RESOLVED_CLI review failed (exit code $REVIEW_EXIT)" >&2
  echo "" >&2
  echo "   Output:" >&2
  echo "$REVIEW_OUTPUT" >&2
  exit 1
fi

echo "✅ Review completed"
echo ""

# Parse result
echo "📊 Parsing results..."
echo ""
echo "   Debug: Saving raw $RESOLVED_CLI output..."
echo "$REVIEW_OUTPUT" > /tmp/codex-raw-output.txt
echo "   Saved to: /tmp/codex-raw-output.txt (CLI: $RESOLVED_CLI)"
echo ""

# Extract JSON from output using shared robust parser
# Handles reasoning mode, interleaved exec outputs, unmatched braces in code
# Resolve extractor — prefer plugin location, fall back to legacy
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/skills/design-reviewer/scripts/lib/extract_review_json.py" ]; then
    EXTRACTOR="${CLAUDE_PLUGIN_ROOT}/skills/design-reviewer/scripts/lib/extract_review_json.py"
else
    EXTRACTOR="$HOME/.claude/skills/design-reviewer/scripts/lib/extract_review_json.py"
fi
set +e
JSON_OUTPUT=$(echo "$REVIEW_OUTPUT" | python3 "$EXTRACTOR" -)
EXTRACT_EXIT=$?
set -e

# If Python extraction failed, try parsing narrative output
if [ -z "$JSON_OUTPUT" ]; then
  echo "   No JSON found, attempting to parse narrative output..." >&2
  set +e
  JSON_OUTPUT=$(echo "$REVIEW_OUTPUT" | python3 "$SCRIPT_DIR/lib/parse-narrative.py" 2>&1)
  PARSE_EXIT=$?
  set -e

  if [ $PARSE_EXIT -ne 0 ] || [ -z "$JSON_OUTPUT" ]; then
    echo "⚠️  Warning: Could not parse review output" >&2
    echo "" >&2
    echo "   Codex returned narrative feedback that couldn't be parsed." >&2
    echo "   Review output:" >&2
    echo "$REVIEW_OUTPUT" >&2
    echo "" >&2
    echo "   See references/troubleshooting.md for handling narrative output" >&2
    exit 1
  fi

  echo "   ✓ Successfully parsed narrative to JSON" >&2
fi

# Validate JSON
validate_json "$JSON_OUTPUT" || exit 1

# Extract status
REVIEW_STATUS=$(echo "$JSON_OUTPUT" | jq -r '.status')
ISSUE_COUNT=$(echo "$JSON_OUTPUT" | jq -r '.issues | length')

echo "   LLM status: $REVIEW_STATUS"
echo "   LLM issues found: $ISSUE_COUNT"
echo ""

# Merge SAST + markdown + LLM findings
MERGER="$SCRIPT_DIR/lib/merge-findings.py"
if [ -f "$MERGER" ] && { [ "$SAST_COUNT" -gt 0 ] || [ "$MD_COUNT" -gt 0 ]; }; then
  echo "📊 Merging SAST + markdown + LLM findings..."
  # Use stdin instead of argv to avoid ARG_MAX limits on large SAST output
  MERGED_OUTPUT=$(printf '%s\n%s\n%s\n' "$SAST_FINDINGS" "$MARKDOWN_FINDINGS" "$JSON_OUTPUT" | python3 "$MERGER" 2>/dev/null) || MERGED_OUTPUT=""
  if [ -n "$MERGED_OUTPUT" ]; then
    JSON_OUTPUT="$MERGED_OUTPUT"
    REVIEW_STATUS=$(echo "$JSON_OUTPUT" | jq -r '.status')
    ISSUE_COUNT=$(echo "$JSON_OUTPUT" | jq -r '.issues | length')
    echo "   Merged status: $REVIEW_STATUS ($ISSUE_COUNT total issues)"
    echo ""
  else
    # Merger failed — fail-closed, don't silently pass
    echo "⚠️  Findings merger failed — fail-closed" >&2
    REVIEW_STATUS="FAIL"
  fi
fi

# Check for completion promise
if [ "$COMPLETION_PROMISE" != "null" ] && [ -n "$COMPLETION_PROMISE" ]; then
  if echo "$REVIEW_OUTPUT" | grep -q "<promise>$COMPLETION_PROMISE</promise>"; then
    echo "✅ Completion promise detected: $COMPLETION_PROMISE"
    echo ""

    # Clear iteration history and clean up temporary files
    clear_iteration_history
    echo "🧹 Cleaning up temporary files..."
    rm -f "$STATE_FILE" 2>/dev/null
    rm -f /tmp/codex-iteration.txt 2>/dev/null

    echo "🎉 Review loop completed successfully!"
    exit 0
  fi
fi

# Update state file
set_yaml_value "iteration" "$((ITERATION + 1))" "$STATE_FILE"
set_yaml_value "review_status" "\"$REVIEW_STATUS\"" "$STATE_FILE"

# Save last result (escape quotes for YAML)
ESCAPED_JSON=$(echo "$JSON_OUTPUT" | sed 's/"/\\"/g')
set_yaml_value "last_result" "\"$ESCAPED_JSON\"" "$STATE_FILE"

# Display results
if [ "$REVIEW_STATUS" = "PASS" ]; then
  echo "✅ PASS - No issues found (or only low severity)"
  echo ""

  # Clear iteration history on success
  clear_iteration_history

  # Write review-passed marker for the appropriate gate
  mkdir -p .claude
  if [ "$REVIEW_MODE" = "pr" ]; then
    # PR mode: marker writing depends on whether deep review is enabled.
    # CODEX_PR_FAST=1 skips multi-agent review — write marker immediately.
    # Otherwise, the SKILL.md multi-agent deep review (Step 2) must run after
    # this script passes. The marker is written by Claude after the 5-agent
    # review completes. Writing it here would short-circuit the deep review.
    if [ "${CODEX_PR_FAST:-0}" = "1" ]; then
      git diff "${PR_BASE_BRANCH}...HEAD" 2>/dev/null | shasum -a 256 | cut -d' ' -f1 > ".claude/pr-review-passed.local"
      mkdir -p .claude
      printf '{"ts":"%s","event":"pr-fast-bypass","gate":"pre-pr"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
      echo "   ⚠️  CODEX_PR_FAST=1 — skipped multi-agent deep review (logged)"
    else
      echo "   ℹ️  Codex CLI pass complete. Multi-agent deep review pending (Step 2)."
    fi
  else
    # Commit mode: write commit marker for pre-commit gate
    git diff --cached 2>/dev/null | shasum -a 256 | cut -d' ' -f1 > ".claude/codex-review-passed.local"
  fi

  # Clean up temporary files
  echo "🧹 Cleaning up temporary files..."
  rm -f "$STATE_FILE" 2>/dev/null
  rm -f /tmp/codex-iteration.txt 2>/dev/null
  echo "   ✓ Removed state file"
  echo "   ✓ Removed iteration counter"
  echo "   ✓ Cleared iteration history"
  echo ""

  echo "Next steps:"
  echo "   1. Run tests: npm test (or appropriate test command)"
  echo "   2. Commit: git commit -m 'Your message'"
  echo "   3. (Optional) Save changelog: bash scripts/save_changelog.sh"
  echo ""
  exit 0
else
  echo "❌ FAIL - Issues found that need fixing"
  echo ""

  # Save this iteration's issues for next pass
  append_iteration_history "$ITERATION" "$JSON_OUTPUT"

  echo "Issues:"
  echo "$JSON_OUTPUT" | jq -r '.issues[] | "  [\(.severity)] \(.file):\(.line) - \(.description)"'
  echo ""
  echo "Next steps:"
  echo "   1. Fix the issues listed above"
  echo "   2. Stage changes: git add <files>"
  echo "   3. Run review again: bash scripts/run-review-loop.sh"
  echo "   4. Loop continues automatically until PASS"
  echo ""
  exit 1
fi
