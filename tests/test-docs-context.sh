#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/skills/litmus/scripts/lib/docs-context.sh"

# collect_docs_context is opt-in (LITMUS_DOCS_CONTEXT=1, default off — docs-context.sh:68).
# The positive-path assertions below exercise the enabled behavior, so turn it on.
export LITMUS_DOCS_CONTEXT=1

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

# Default-off contract: with the flag unset, the collector must be silent
# (docs-context.sh returns early). Run in a subshell so the export above is undone.
DEFAULT_OFF_OUTPUT=$(unset LITMUS_DOCS_CONTEXT; collect_docs_context "src/processor.sh" "$(git diff --cached)")
if [[ -z "$DEFAULT_OFF_OUTPUT" ]]; then
  ok "Collector is silent when LITMUS_DOCS_CONTEXT is unset (default off)"
else
  fail "Collector emitted output with LITMUS_DOCS_CONTEXT unset (should be silent)"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
