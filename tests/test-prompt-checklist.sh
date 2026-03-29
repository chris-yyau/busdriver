#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SCRIPT="$SCRIPT_DIR/skills/codex-reviewer/scripts/init-review-loop.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Extract the two heredoc blocks (PR prompt and commit prompt)
# Block 1 = PR prompt (first <<'EOF' to first EOF), Block 2 = commit prompt
PR_PROMPT=$(awk 'BEGIN{b=0} /<<'\''EOF'\''/{b++; next} /^EOF$/{b++; next} b==1' "$INIT_SCRIPT")
COMMIT_PROMPT=$(awk 'BEGIN{b=0} /<<'\''EOF'\''/{b++; next} /^EOF$/{b++; next} b==3' "$INIT_SCRIPT")

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
