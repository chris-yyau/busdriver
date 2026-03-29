#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/docs-context.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Create a temp repo with a README and a source file
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cd "$TMPDIR_TEST"
git init -q
mkdir -p src

cat > README.md << 'EOF'
# My Project
Has 5 scanners. The processor module handles all input parsing.
EOF

cat > src/processor.sh << 'EOF'
process_data() { echo "done"; }
EOF

git add .
git -c commit.gpgsign=false -c user.name=test -c user.email=test@test.com commit -q -m "init"

# Modify processor
echo 'new_func() { echo "new"; }' >> src/processor.sh
git add src/processor.sh

# Collect docs context
OUTPUT=$(collect_docs_context "src/processor.sh" "$(git diff --cached)")

# Verify the output contains structured verification instructions
if echo "$OUTPUT" | grep -Eqi "verify.*claim|cross-reference|check.*accuracy"; then
  ok "Docs context includes verification instructions"
else
  fail "Docs context missing verification instructions"
fi

# Verify it found the README reference
if echo "$OUTPUT" | grep -q "README.md"; then
  ok "Found README.md referencing changed code"
else
  fail "Did not find README.md reference"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
