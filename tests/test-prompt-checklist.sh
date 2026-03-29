#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SCRIPT="$SCRIPT_DIR/skills/codex-reviewer/scripts/init-review-loop.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Split the file at the 'else' between PR and commit heredocs
# PR prompt is in the first cat block, commit prompt is in the second
PR_PROMPT=$(sed -n '/^if \[ "\$REVIEW_MODE" = "pr" \]/,/^else$/p' "$INIT_SCRIPT")
COMMIT_PROMPT=$(sed -n '/^else$/,/^fi$/p' "$INIT_SCRIPT")

# Shell-specific checks must be in BOTH commit and PR prompts
CHECKS=(
  "local.*outside.*function"
  "CWD|REPO_DIR|absolute.*path|relative.*path"
  "shasum.*sha256sum|portability"
  "stale.*cleanup|cleanup.*ordering"
  "fail-open.*timeout|timeout.*fail"
  "boolean.*normalization|true.*false.*yes.*no"
  "factual.*claim|claim.*code"
  "count.*match|number.*match"
  "example.*match|stale.*example"
)

for check in "${CHECKS[@]}"; do
  for section in "PR" "COMMIT"; do
    if [ "$section" = "PR" ]; then
      text="$PR_PROMPT"
    else
      text="$COMMIT_PROMPT"
    fi
    if echo "$text" | grep -qiE "$check"; then
      ok "$section prompt contains: $check"
    else
      fail "$section prompt missing: $check"
    fi
  done
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
